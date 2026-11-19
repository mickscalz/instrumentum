import AVFoundation
import Foundation
import InStrumCore
import os

/// The Recorder's one timeline in the engine (Recorder plan part 2, "One timeline"; spec §4, §5.1). The play-along track
/// and the recorded layers play from one position, started at one sample time, with one loop. The position is in the
/// track's seconds ("timeline seconds"): the track can play at another speed with its pitch kept, through an
/// `AVAudioUnitTimePitch` that sits only on the track's path and only while its speed isn't 1, while the layers, recorded
/// in real time, play in real time (timeline second `p` is the layers' second `p / rate`). At speed 1 the track starts on
/// the same sample as the layers; at another speed it starts within a buffer of them (the time-pitch has a clock of its
/// own), and the stems recorded against it carry the same small difference.
///
/// Everything is made on first use: an engine that never loads a track or a layer has today's graph. Main thread; the
/// play-along stem's tap reads one flag behind a lock.
final class Transport {
    unowned let audio: AudioEngine
    private(set) var track: LayerPlayer?
    private(set) var layers: LayerPlayer?
    private var timePitch: AVAudioUnitTimePitch?
    /// The track plays through the time-pitch (its speed isn't 1).
    private(set) var throughTimePitch = false
    private(set) var rate = 1.0
    /// The loop as asked for (timeline seconds); `activeLoop` is the one the players are following.
    private(set) var loop: (start: Double, end: Double)?
    private var activeLoop: (start: Double, end: Double)?
    private(set) var playing = false
    private var wantsTrack = true, wantsLayers = true
    private var startSample: Int64 = 0
    private var startPosition = 0.0
    private var pausedPosition = 0.0
    /// Tests: the output's latency instead of what Core Audio reports.
    var injectedOutputLatency: RecordingLatency.Device?
    /// True while a pass records the track as the play-along stem: the tap on the track's path feeds it then.
    private let feedsPlayAlongStem = OSAllocatedUnfairLock(initialState: false)
    private var stemTapNode: AVAudioNode?

    /// The speeds the time-pitch is asked for are held here (the app's range is 0.9…1.1).
    static let rateRange: ClosedRange<Double> = 0.5...2

    init(audio: AudioEngine) {
        self.audio = audio
    }

    // MARK: - What is loaded

    /// Puts a prepared track on the play-along bus in place of any before; the transport stops.
    func installTrack(_ file: PlaybackFile) {
        stopForChange()
        if let current = track, current.sampleRate != file.sampleRate { unloadTrack() }
        let player = track ?? LayerPlayer(engine: audio.engine, bus: audio.playAlongBus, sampleRate: file.sampleRate)
        player.install([(file: file, gain: 1, offsetFrames: 0)])
        track = player
        pausedPosition = min(pausedPosition, duration)
    }

    /// Takes the track (and the time-pitch) out of the graph.
    func unloadTrack() {
        stopForChange()
        track = nil   // its player detaches its node
        if let unit = timePitch {
            audio.engine.detach(unit)
            timePitch = nil
        }
        throughTimePitch = false
        pausedPosition = min(pausedPosition, duration)
    }

    /// Puts prepared layers on the layers bus in place of any before; the transport stops. No layers and none before
    /// attaches nothing.
    func installLayers(_ items: [(file: PlaybackFile, gain: Float, offsetFrames: Int)], sampleRate: Double) {
        stopForChange()
        if layers == nil && items.isEmpty { return }
        if let current = layers, current.sampleRate != sampleRate { layers = nil }
        let player = layers ?? LayerPlayer(engine: audio.engine, bus: audio.layersBus, sampleRate: sampleRate)
        player.install(items)
        layers = player
        pausedPosition = min(pausedPosition, duration)
    }

    // MARK: - The timeline

    var trackDuration: Double {
        guard let track else { return 0 }
        return Double(track.durationFrames) / track.sampleRate
    }

    /// The layers' length in timeline seconds.
    var layersDuration: Double {
        guard let layers else { return 0 }
        return Double(layers.durationFrames) / layers.sampleRate * rate
    }

    var duration: Double { max(trackDuration, layersDuration) }

    private var sampleRate: Double {
        layers?.sampleRate ?? track?.sampleRate ?? audio.renderFormat().sampleRate
    }

    /// Timeline seconds: where the play started, plus the engine's clock since then at the track's speed, wrapped by the
    /// loop it follows and held to the end.
    var position: Double {
        guard playing else { return pausedPosition }
        let elapsed = Double(max(0, audio.currentSampleTime - startSample)) / sampleRate
        var p = startPosition + elapsed * rate
        if let loop = activeLoop, startPosition < loop.end, p >= loop.end {
            p = loop.start + (p - loop.end).truncatingRemainder(dividingBy: loop.end - loop.start)
        }
        return min(p, duration)
    }

    /// A pass is recording: cue, loop, scrub and tempo leave the timeline alone (Recorder plan part 2).
    private var passRecording: Bool { audio.recorder?.isRecording == true }

    private func held(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), duration)
    }

    // MARK: - Play, pause, seek, loop, speed

    /// Plays the track and the layers (as asked) from timeline second `seconds`, at `newRate`, two buffers from now.
    /// Returns the start's sample time.
    @discardableResult
    func play(from seconds: Double, rate newRate: Double, track withTrack: Bool = true, layers withLayers: Bool = true) -> Int64 {
        if passRecording && playing { return startSample }
        if newRate.isFinite { rate = min(max(newRate, Self.rateRange.lowerBound), Self.rateRange.upperBound) }
        let p = held(seconds)
        let lead = 2 * Int64(audio.bufferFrames)
        let plays = cue(from: p, track: withTrack, layers: withLayers, lead: lead, looping: true)
        let start = audio.currentSampleTime + lead
        launch(plays, at: start, from: p)
        wantsTrack = withTrack
        wantsLayers = withLayers
        return start
    }

    /// Stops where it is and returns the position.
    @discardableResult
    func pause() -> Double {
        let p = position
        stopPlayers()
        playing = false
        pausedPosition = p
        return p
    }

    /// Moves the position; playing, it carries on from there.
    func seek(_ seconds: Double) {
        guard !passRecording else { return }
        let p = held(seconds)
        if playing {
            play(from: p, rate: rate, track: wantsTrack, layers: wantsLayers)
        } else {
            pausedPosition = p
        }
    }

    /// The loop, in timeline seconds (nil, or shorter than `TransportState.minLoop`: none). Playing, the players follow
    /// at once: OUT pressed at (or after) the loop's end goes back to its start.
    func setLoop(in start: Double?, out end: Double?) {
        guard !passRecording else { return }
        var asked: (start: Double, end: Double)?
        if let start, let end, start.isFinite, end.isFinite, start >= 0, end - start >= TransportState.minLoop {
            asked = (start: start, end: end)
        }
        let same = asked?.start == loop?.start && asked?.end == loop?.end
        guard !same else { return }
        let p = position
        loop = asked
        guard playing else { return }
        var from = p
        if let asked, p >= asked.end { from = asked.start }
        play(from: from, rate: rate, track: wantsTrack, layers: wantsLayers)
    }

    /// The track's speed, its pitch kept. Playing the track alone through the time-pitch, the change is heard at once;
    /// otherwise the players start again from the position (the layers keep in step).
    func setRate(_ newRate: Double) {
        guard newRate.isFinite else { return }
        let r = min(max(newRate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        guard r != rate else { return }
        guard !(passRecording && playing) else { return }   // stems record against one speed
        guard playing else {
            rate = r
            return
        }
        let p = position
        let layersPlay = wantsLayers && (layers?.durationFrames ?? 0) > 0
        if throughTimePitch, let unit = timePitch, !layersPlay {
            let now = audio.currentSampleTime
            if now > startSample {
                startPosition = p
                startSample = now
            }
            rate = r
            unit.rate = Float(r)
        } else {
            play(from: p, rate: r, track: wantsTrack, layers: wantsLayers)
        }
    }

    /// An overdub (spec §4): the earlier layers, and the track if asked, from the start, at the sample time a new pass
    /// begins recording these stems. With a play-along stem asked for and the track playing, the track is recorded as it
    /// is heard (after the time-pitch, before the play-along volume). Returns the start's sample time.
    func beginOverdub(_ stems: [(kind: StemKind, url: URL)], withTrack: Bool) throws -> Int64 {
        let lead = 2 * Int64(audio.bufferFrames)
        let plays = cue(from: 0, track: withTrack, layers: true, lead: lead, looping: false)
        let start: Int64
        do {
            start = try audio.beginRecording(stems)
        } catch {
            stopPlayers()
            playing = false
            throw error
        }
        launch(plays, at: start, from: 0)
        wantsTrack = withTrack
        wantsLayers = true
        if plays.track && stems.contains(where: { $0.kind == .playAlong }) { installStemTap() }
        return start
    }

    // MARK: - Players

    /// Stops what plays and schedules the track and the layers from timeline second `p` (with the loop, if `looping`),
    /// for a start `lead` frames from now. Returns which of them have something to play.
    private func cue(from p: Double, track withTrack: Bool, layers withLayers: Bool, lead: Int64,
                     looping: Bool) -> (track: Bool, layers: Bool) {
        stopPlayers()
        let loopNow = looping ? loop : nil
        activeLoop = loopNow
        var plays = (track: false, layers: false)
        if withLayers, let layers, layers.durationFrames > 0 {
            let scale = layers.sampleRate / rate
            layers.cue(from: Int((p * scale).rounded()), loop: loopNow.flatMap { Self.frames($0, scale: scale) })
            plays.layers = true
        }
        if withTrack, let track, track.durationFrames > 0 {
            route(throughTimePitch: rate != 1)
            timePitch?.rate = Float(rate)
            let scale = track.sampleRate
            // Through the time-pitch the player starts at once (on the next render) and waits out the lead, in its own
            // frames, which pass at the track's speed.
            let early: Int64 = audio.manualRendering ? 0 : Int64(audio.bufferFrames)
            let delay = throughTimePitch ? Int((Double(max(0, lead - early)) * rate).rounded()) : 0
            track.cue(from: Int((p * scale).rounded()), loop: loopNow.flatMap { Self.frames($0, scale: scale) }, delay: delay)
            plays.track = true
        }
        return plays
    }

    /// Starts what `cue` scheduled at sample time `start` (the track through the time-pitch at once, its lead scheduled).
    private func launch(_ plays: (track: Bool, layers: Bool), at start: Int64, from p: Double) {
        if plays.layers { layers?.play(at: start) }
        if plays.track { track?.play(at: throughTimePitch ? nil : start) }
        playing = true
        startSample = start
        startPosition = p
    }

    private func stopPlayers() {
        removeStemTap()
        track?.stop()
        layers?.stop()
    }

    /// Before the players change: stops (keeping the position) and forgets the loop being followed.
    private func stopForChange() {
        if playing { pause() } else { stopPlayers() }
        activeLoop = nil
    }

    /// A loop in a player's frames (`scale` frames a timeline second); nil when it rounds to nothing.
    private static func frames(_ loop: (start: Double, end: Double), scale: Double) -> Range<Int>? {
        let a = Int((loop.start * scale).rounded()), b = Int((loop.end * scale).rounded())
        return b > a ? a..<b : nil
    }

    /// The track's player straight into the play-along bus (speed 1: on the engine's clock, to the sample) or through the
    /// time-pitch. Only while it is stopped.
    private func route(throughTimePitch wanted: Bool) {
        guard wanted != throughTimePitch, let track, let node = track.nodes.first, let input = track.inputBuses.first else { return }
        let engine = audio.engine
        removeStemTap()
        engine.disconnectNodeOutput(node)
        if wanted {
            let unit: AVAudioUnitTimePitch
            if let existing = timePitch {
                unit = existing
            } else {
                unit = AVAudioUnitTimePitch()
                engine.attach(unit)
                timePitch = unit
            }
            unit.rate = Float(rate)
            engine.connect(unit, to: track.bus, fromBus: 0, toBus: input, format: track.format)
            engine.connect(node, to: unit, fromBus: 0, toBus: 0, format: track.format)
        } else {
            if let unit = timePitch {
                engine.detach(unit)
                timePitch = nil
            }
            engine.connect(node, to: track.bus, fromBus: 0, toBus: input, format: track.format)
        }
        throughTimePitch = wanted
    }

    // MARK: - The play-along stem

    /// A tap on the track's last node (the time-pitch, or its player) hands what is heard to the recorder as the
    /// play-along stem. Taps don't run in offline rendering.
    private func installStemTap() {
        guard !audio.manualRendering, let track else { return }
        let node: AVAudioNode? = throughTimePitch ? timePitch : track.nodes.first
        guard let node else { return }
        removeStemTap()
        let feeds = feedsPlayAlongStem
        feeds.withLock { $0 = true }
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak audio = self.audio] buffer, when in
            guard feeds.withLock({ $0 }), let audio, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0, let recorder = audio.shared.withLockUnchecked({ $0.recorder }) else { return }
            let right = buffer.format.channelCount > 1 ? data[1] : data[0]
            recorder.feed(.playAlong, left: data[0], right: right, frames: n, sampleTime: when.sampleTime)
        }
        stemTapNode = node
    }

    private func removeStemTap() {
        feedsPlayAlongStem.withLock { $0 = false }
        stemTapNode?.removeTap(onBus: 0)
        stemTapNode = nil
    }
}
