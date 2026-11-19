import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import InStrumCore

/// The Recorder's playback (Recorder spec §4, §5.1, §7; plan Task 3 and part 2): the play-along track and the earlier
/// layers on one timeline, overdubs that start the layers and a pass on one sample time, and the output's latency.
/// Nothing is made or attached until a track or a layer is loaded: an engine that never plays one has today's graph.
extension AudioEngine {

    /// The track, the layers and their timeline; made on first use (it attaches nothing by itself).
    var transport: Transport {
        if let existing = playback { return existing }
        let made = Transport(audio: self)
        playback = made
        return made
    }

    // MARK: - The play-along track (spec §5.1)

    /// Loads a track to play along with (MP3, M4A/AAC, WAV, AIFF, FLAC, ALAC) in place of any before, and returns its
    /// length in seconds. The file is read, and converted if its rate differs, off the main thread; the player and the
    /// play-along bus are attached on the main thread. A protected, unreadable or empty file is
    /// `AudioEngineError.loadFailed(<its name>)`, and nothing changes.
    @MainActor
    public func loadTrack(_ url: URL) async throws -> Double {
        let rate = renderFormat().sampleRate
        let file = try await Task.detached(priority: .userInitiated) {
            try PlaybackFile.prepare(url, sampleRate: rate)
        }.value
        guard file.frames > 0 else { throw AudioEngineError.loadFailed(url.lastPathComponent) }
        transport.installTrack(file)
        return Double(file.frames) / file.sampleRate
    }

    /// Takes the track out (the play-along is off, or the Mac's sound).
    public func unloadTrack() {
        playback?.unloadTrack()
    }

    /// Plays the track alone from `fromSeconds` (timeline seconds), at the track's speed.
    public func playTrack(fromSeconds: Double) {
        transport.play(from: fromSeconds, rate: transport.rate, track: true, layers: false)
    }

    public func pauseTrack() {
        playback?.pause()
    }

    /// Timeline seconds (as `transportPosition`).
    public var trackPosition: Double { playback?.position ?? 0 }

    // MARK: - Layers (spec §4)

    /// Loads the earlier layers (each with its gain, 0…2, and its offset) in place of any before. The files are read, and
    /// converted if their rate differs, off the main thread; the players are attached on the main thread. One that can't
    /// be read is `AudioEngineError.loadFailed(<its name>)`, and nothing changes.
    @MainActor
    public func loadLayers(_ items: [(url: URL, gain: Float, offsetFrames: Int)]) async throws {
        let rate = renderFormat().sampleRate
        let urls = items.map { $0.url }
        let files = try await Task.detached(priority: .userInitiated) {
            try urls.map { try PlaybackFile.prepare($0, sampleRate: rate) }
        }.value
        var prepared: [(file: PlaybackFile, gain: Float, offsetFrames: Int)] = []
        for (index, item) in items.enumerated() {
            prepared.append((file: files[index], gain: item.gain, offsetFrames: item.offsetFrames))
        }
        transport.installLayers(prepared, sampleRate: rate)
    }

    /// A layer's volume (0…2; 0 when muted), heard at once. `index` is its place in what `loadLayers` was given.
    public func setLayerGain(_ gain: Float, index: Int) {
        playback?.layers?.setGain(gain, index: index)
    }

    /// Starts the earlier layers (and the track, if `withTrack`) from the start, and a pass recording these stems, on one
    /// sample time, which it returns. End the pass with `endRecording()` and the playback with `transportPause()`.
    public func beginOverdub(_ stems: [(kind: StemKind, url: URL)], withTrack: Bool) throws -> Int64 {
        try transport.beginOverdub(stems, withTrack: withTrack)
    }

    /// Plays the layers alone from `fromSeconds` (timeline seconds).
    public func playLayers(fromSeconds: Double) {
        transport.play(from: fromSeconds, rate: transport.rate, track: false, layers: true)
    }

    public func stopLayers() {
        playback?.pause()
    }

    // MARK: - The transport (plan part 2, "One timeline")

    /// Plays the track and the layers together from `seconds` (timeline seconds), the track at `rate` (pitch kept), two
    /// buffers from now. Returns the start's sample time.
    @discardableResult
    public func transportPlay(from seconds: Double, rate: Double) -> Int64 {
        transport.play(from: seconds, rate: rate, track: true, layers: true)
    }

    /// Stops and returns the position it stopped at.
    @discardableResult
    public func transportPause() -> Double {
        playback?.pause() ?? 0
    }

    /// Moves the position; playing, it carries on from there. Does nothing while a pass records.
    public func transportSeek(_ seconds: Double) {
        transport.seek(seconds)
    }

    /// The loop (nil for none); the players follow at once, wrapping on the sample. Does nothing while a pass records.
    public func setTransportLoop(in start: Double?, out end: Double?) {
        transport.setLoop(in: start, out: end)
    }

    /// Timeline seconds (the track's seconds, not real seconds).
    public var transportPosition: Double { playback?.position ?? 0 }

    /// The longer of the track and the layers, in timeline seconds.
    public var transportDuration: Double { playback?.duration ?? 0 }

    /// The track's speed (pitch kept, through a time-pitch on the play-along path only). Ignored while a pass records.
    public func setTrackRate(_ rate: Double) {
        transport.setRate(rate)
    }

    // MARK: - The output's latency (spec §4)

    /// What Core Audio reports for the device really playing: its latency and its stream's, its safety offset, and its
    /// buffer. Zero when rendering offline.
    public func outputLatency() -> RecordingLatency.Device {
        if let injected = playback?.injectedOutputLatency { return injected }
        guard !manualRendering, let device = playingOutputDevice() else {
            return RecordingLatency.Device(latencyFrames: 0, safetyFrames: 0, bufferFrames: 0)
        }
        let scope = kAudioDevicePropertyScopeOutput
        let latency = Self.halFrames(device, kAudioDevicePropertyLatency, scope)
        let safety = Self.halFrames(device, kAudioDevicePropertySafetyOffset, scope)
        let buffer = Self.halFrames(device, kAudioDevicePropertyBufferFrameSize, scope)
        let stream = Self.firstStreamLatency(device, scope)
        return RecordingLatency.Device(latencyFrames: latency + stream, safetyFrames: safety,
                                       bufferFrames: buffer > 0 ? buffer : Int(bufferFrames))
    }

    /// The device the output unit plays to.
    private func playingOutputDevice() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func halFrames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return 0 }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
    }

    private static func firstStreamLatency(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return 0 }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first else { return 0 }
        return halFrames(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
    }
}
