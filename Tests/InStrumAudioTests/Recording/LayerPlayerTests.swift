import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore

/// Audio files and offline renders for the playback tests (Recorder plan Task 3).
enum PlaybackAudio {
    /// Writes a 24-bit stereo WAV, as the stems are (`right` nil: the same on both sides).
    static func writeWAV(_ url: URL, left: [Float], right: [Float]? = nil, rate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let other = right ?? left
        let count = min(left.count, other.count)
        guard count > 0 else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        let channels = buffer.floatChannelData!
        for i in 0..<count {
            channels[0][i] = left[i]
            channels[1][i] = other[i]
        }
        buffer.frameLength = AVAudioFrameCount(count)
        try file.write(from: buffer)
    }

    /// Silence with one sample of `value` at `index`.
    static func click(frames: Int, at index: Int, value: Float) -> [Float] {
        var x = [Float](repeating: 0, count: frames)
        x[index] = value
        return x
    }

    static func sine(hz: Double, seconds: Double, rate: Double, amplitude: Float) -> [Float] {
        let n = Int((seconds * rate).rounded())
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / rate)) }
        return x
    }

    /// A ramp that says where it is: frame `f` holds 0.1 + f / 240 000 (0.1…0.9 over 4 s at 48 kHz), exact enough in
    /// 24 bits to read the frame back within a twentieth of one.
    static func ramp(frames: Int) -> [Float] {
        var x = [Float](repeating: 0, count: frames)
        for i in 0..<frames { x[i] = 0.1 + Float(i) / 240_000 }
        return x
    }

    /// The frame of the ramp a sample came from (silence reads as −24 000).
    static func frame(of value: Float) -> Double { (Double(value) - 0.1) * 240_000 }

    /// `frames` of offline rendering in 512-frame blocks, both channels, and the sample time it began at.
    static func render(_ e: AudioEngine, frames: Int) throws -> (left: [Float], right: [Float], start: Int64) {
        let start = e.engine.manualRenderingSampleTime
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        while left.count < frames {
            let b = try e.renderOffline(frames: AVAudioFrameCount(min(512, frames - left.count)))
            let n = Int(b.frameLength)
            guard n > 0 else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![1], count: n))
        }
        return (left, right, start)
    }

    /// Indices of the samples louder than `threshold`.
    static func loud(_ x: [Float], above threshold: Float) -> [Int] {
        var hits: [Int] = []
        for i in 0..<x.count where abs(x[i]) > threshold { hits.append(i) }
        return hits
    }

    static func peak(_ x: ArraySlice<Float>) -> Float {
        var m: Float = 0
        for v in x { m = max(m, abs(v)) }
        return m
    }

    /// An offline engine at 48 kHz with nothing loaded.
    static func engine() throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true, manualSampleRate: 48_000)
        try e.start()
        return e
    }
}

/// Layers playing back (Recorder spec §4, §7; plan Task 3): every player starts at one sample time, each with its gain
/// and its offset; a file at another rate is resampled on load; a broken track is refused; and an overdub lands where
/// it was heard.
@MainActor
final class LayerPlayerTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LayerPlayerTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testLayersStartTogether() throws {
        let e = try PlaybackAudio.engine()
        let a = dir.appendingPathComponent("A.wav"), b = dir.appendingPathComponent("B.wav")
        try PlaybackAudio.writeWAV(a, left: PlaybackAudio.click(frames: 9600, at: 4800, value: 0.25), rate: 48_000)
        try PlaybackAudio.writeWAV(b, left: PlaybackAudio.click(frames: 9600, at: 4800, value: 0.5), rate: 48_000)
        let player = LayerPlayer(engine: e.engine, bus: e.layersBus)
        try player.load([(url: a, gain: 1, offsetFrames: 0), (url: b, gain: 1, offsetFrames: 0)])
        let duration = player.durationSeconds
        let idle = player.isPlaying
        let t0 = e.engine.manualRenderingSampleTime
        let start = t0 + 512
        player.start(atSampleTime: start)
        let playing = player.isPlaying
        let head = try PlaybackAudio.render(e, frames: 4_000)
        let midway = player.positionSeconds
        let tail = try PlaybackAudio.render(e, frames: 8_000)
        let atEnd = player.positionSeconds
        let ended = player.isPlaying
        let left = head.left + tail.left, right = head.right + tail.right
        let hits = PlaybackAudio.loud(left, above: 0.01)
        let hitCount = hits.count
        let at = hits.first ?? -1
        let value: Float = at >= 0 ? left[at] : 0
        let rightValue: Float = at >= 0 ? right[at] : 0
        let expected = Int(start - head.start) + 4800
        player.stop()
        let stopped = player.isPlaying
        let after = try PlaybackAudio.render(e, frames: 4096)
        let silence = PlaybackAudio.peak(after.left[...])
        XCTAssertEqual(duration, 0.2, accuracy: 1e-9)
        XCTAssertFalse(idle)
        XCTAssertTrue(playing)
        XCTAssertEqual(hitCount, 1, "both clicks land in one frame")
        XCTAssertEqual(at, expected, "at the sample time asked for")
        XCTAssertEqual(value, 0.75, accuracy: 1e-6, "0.25 + 0.5")
        XCTAssertEqual(rightValue, 0.75, accuracy: 1e-6)
        XCTAssertEqual(midway, Double(4_000 - 512) / 48_000, accuracy: 1e-9)
        XCTAssertEqual(atEnd, 0.2, accuracy: 1e-9, "held at the end")
        XCTAssertFalse(ended, "played to its end")
        XCTAssertFalse(stopped)
        XCTAssertEqual(silence, 0)
    }

    func testOffsetsAndGainsApplyOnPlayback() async throws {
        let e = try PlaybackAudio.engine()
        let a = dir.appendingPathComponent("A.wav"), b = dir.appendingPathComponent("B.wav")
        try PlaybackAudio.writeWAV(a, left: PlaybackAudio.click(frames: 9600, at: 4800, value: 0.5), rate: 48_000)
        try PlaybackAudio.writeWAV(b, left: PlaybackAudio.click(frames: 9600, at: 4800, value: 0.25), rate: 48_000)
        // A moved 10 ms earlier at half volume; B 20 ms later at full.
        try await e.loadLayers([(url: a, gain: 0.5, offsetFrames: -480), (url: b, gain: 1, offsetFrames: 960)])
        let duration = e.transportDuration
        let t0 = e.engine.manualRenderingSampleTime
        e.playLayers(fromSeconds: 0)
        let lead = Int(2 * e.bufferFrames)
        let out = try PlaybackAudio.render(e, frames: 12_000)
        let hits = PlaybackAudio.loud(out.left, above: 0.01)
        let hitCount = hits.count
        let first = hits.first ?? -1, last = hits.last ?? -1
        let firstValue: Float = first >= 0 ? out.left[first] : 0
        let lastValue: Float = last >= 0 ? out.left[last] : 0
        let began = Int(out.start - t0)

        // From 50 ms in: both clicks come 2400 frames sooner.
        e.stopLayers()
        e.playLayers(fromSeconds: 0.05)
        let later = try PlaybackAudio.render(e, frames: 12_000)
        let laterHits = PlaybackAudio.loud(later.left, above: 0.01)
        let laterFirst = laterHits.first ?? -1, laterLast = laterHits.last ?? -1

        // A layer's volume can change while it plays.
        e.stopLayers()
        e.setLayerGain(0, index: 1)
        e.playLayers(fromSeconds: 0)
        let muted = try PlaybackAudio.render(e, frames: 12_000)
        let mutedHits = PlaybackAudio.loud(muted.left, above: 0.01)
        let mutedCount = mutedHits.count
        e.stopLayers()

        XCTAssertEqual(duration, Double(960 + 9600) / 48_000, accuracy: 1e-9, "the latest end")
        XCTAssertEqual(began, 0)
        XCTAssertEqual(hitCount, 2)
        XCTAssertEqual(first, lead + 4800 - 480, "A, 480 frames early")
        XCTAssertEqual(firstValue, 0.25, accuracy: 1e-6, "0.5 at half volume")
        XCTAssertEqual(last, lead + 4800 + 960, "B, 960 frames late")
        XCTAssertEqual(lastValue, 0.25, accuracy: 1e-6)
        XCTAssertEqual(laterFirst, lead + 4800 - 480 - 2400)
        XCTAssertEqual(laterLast, lead + 4800 + 960 - 2400)
        XCTAssertEqual(mutedCount, 1, "B at volume 0")
    }

    func testADifferentRateLayerIsResampled() throws {
        let e = try PlaybackAudio.engine()
        let url = dir.appendingPathComponent("Layer 1 — 44k.wav")
        try PlaybackAudio.writeWAV(url, left: PlaybackAudio.sine(hz: 1000, seconds: 1, rate: 44_100, amplitude: 0.5), rate: 44_100)
        let player = LayerPlayer(engine: e.engine, bus: e.layersBus)
        try player.load([(url: url, gain: 1, offsetFrames: 0)])
        let duration = player.durationSeconds
        let start = e.engine.manualRenderingSampleTime + 512
        player.start(atSampleTime: start)
        let out = try PlaybackAudio.render(e, frames: 72_000)
        let hits = PlaybackAudio.loud(out.left, above: 0.05)
        let first = hits.first ?? 0, last = hits.last ?? 0
        let heardFrames = last - first + 1
        let middle = Array(out.left[(first + 6000)..<(first + 42_000)])
        let pitch = DSPTestKit.fundamental(middle, sampleRate: 48_000, near: 1000)
        let level = PlaybackAudio.peak(out.left[...])
        player.stop()
        XCTAssertEqual(duration, 1, accuracy: 0.001, "one second at 48 kHz")
        XCTAssertEqual(Double(heardFrames), 48_000, accuracy: 48, "heard for one second, within 1 ms")
        XCTAssertEqual(pitch, 1000, accuracy: 1, "still 1 kHz")
        XCTAssertEqual(level, 0.5, accuracy: 0.02)
    }

    func testAProtectedOrBrokenTrackThrows() async throws {
        let e = try PlaybackAudio.engine()
        let broken = dir.appendingPathComponent("Broken.m4a")
        try Data("This is not a song.".utf8).write(to: broken)
        let missing = dir.appendingPathComponent("Missing.mp3")
        var brokenError: AudioEngineError?
        do { _ = try await e.loadTrack(broken) } catch { brokenError = error as? AudioEngineError }
        var missingError: AudioEngineError?
        do { _ = try await e.loadTrack(missing) } catch { missingError = error as? AudioEngineError }
        var layerError: AudioEngineError?
        do { try await e.loadLayers([(url: broken, gain: 1, offsetFrames: 0)]) } catch { layerError = error as? AudioEngineError }
        let player = LayerPlayer(engine: e.engine, bus: e.layersBus)
        var playerError: AudioEngineError?
        do { try player.load([(url: broken, gain: 1, offsetFrames: 0)]) } catch { playerError = error as? AudioEngineError }
        let duration = e.transportDuration
        XCTAssertEqual(brokenError, .loadFailed("Broken.m4a"))
        XCTAssertEqual(missingError, .loadFailed("Missing.mp3"))
        XCTAssertEqual(layerError, .loadFailed("Broken.m4a"))
        XCTAssertEqual(playerError, .loadFailed("Broken.m4a"))
        XCTAssertEqual(duration, 0, "nothing was loaded")
    }

    /// The engine as it was, until a track or a layer is loaded: no players, no time-pitch, none of the buses.
    func testNothingIsAttachedUntilSomethingIsLoaded() async throws {
        let e = try PlaybackAudio.engine()
        let nodesBefore = e.engine.attachedNodes.count
        let start = e.transportPlay(from: 0, rate: 1)
        e.setTrackRate(0.95)
        e.transportSeek(1)
        e.setTransportLoop(in: 0, out: 1)
        let paused = e.transportPause()
        let position = e.transportPosition
        let duration = e.transportDuration
        try await e.loadLayers([])
        let nodesAfter = e.engine.attachedNodes.count
        let attached = e.recordingBusesAttached
        XCTAssertGreaterThan(start, 0)
        XCTAssertEqual(paused, 0)
        XCTAssertEqual(position, 0)
        XCTAssertEqual(duration, 0)
        XCTAssertEqual(nodesAfter, nodesBefore)
        XCTAssertFalse(attached)
    }

    /// Review focus 1: an overdub lines up with what was heard, even 150 ms late (a Bluetooth output). Layer 1 is a click
    /// at 1.000 s. He hears it `latency` after the engine plays it and plays his own click then; the instrument stem
    /// carries it that much later, the layer's offset (from `RecordingLatency`) moves it back, and in the mix the two
    /// clicks are one.
    func testOverdubLandsWithinOneSample() async throws {
        let rate = 48_000.0
        let e = try PlaybackAudio.engine()
        var session = RecordingSession(title: "Clicks", sampleRate: rate, appVersion: "test")
        let first = session.addLayer(kind: .instrument, name: "Click", note: nil)
        let firstURL = dir.appendingPathComponent(first.fileName)
        try PlaybackAudio.writeWAV(firstURL, left: PlaybackAudio.click(frames: 96_000, at: 48_000, value: 0.5), rate: rate)
        session.layers[0].frames = 96_000
        try await e.loadLayers([(url: firstURL, gain: 1, offsetFrames: 0)])
        e.transport.injectedOutputLatency = RecordingLatency.Device(latencyFrames: 7000, safetyFrames: 200, bufferFrames: 0)
        let latency = e.outputLatency()
        let second = session.addLayer(kind: .instrument, name: "Click", note: nil)
        let secondURL = dir.appendingPathComponent(second.fileName)

        let start = try e.beginOverdub([(kind: .instrument, url: secondURL)], withTrack: false)
        var heardAt: Int64?
        var t = e.engine.manualRenderingSampleTime
        while t < start + 104_000 {
            let b = try e.renderOffline(frames: 512)
            let n = Int(b.frameLength)
            guard n > 0 else { break }
            if heardAt == nil {
                for i in 0..<n where abs(b.floatChannelData![0][i]) > 0.1 {
                    heardAt = t + Int64(i)
                    break
                }
            }
            // The instrument bus: silence, and his click when he hears the layer's.
            let stem = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(n))!
            stem.frameLength = AVAudioFrameCount(n)
            stem.floatChannelData![0].update(repeating: 0, count: n)
            stem.floatChannelData![1].update(repeating: 0, count: n)
            if let heard = heardAt {
                let played = heard + Int64(latency.total)
                if played >= t && played < t + Int64(n) {
                    stem.floatChannelData![0][Int(played - t)] = 0.5
                    stem.floatChannelData![1][Int(played - t)] = 0.5
                }
            }
            e.feedOffline(stem, kind: .instrument, sampleTime: t)
            t += Int64(n)
        }
        let frames = e.endRecording()
        _ = e.transportPause()
        session.layers[1].frames = frames[.instrument] ?? 0
        session.layers[1].offsetFrames = RecordingLatency.offsetFrames(kind: .instrument, output: latency, input: nil,
                                                                       captureBufferFrames: 0, nudgeMs: 0, sampleRate: rate)
        _ = try MixRenderer.render(session: session, folder: dir, alsoWAV: true)
        let mix = try RecordedStem(dir.appendingPathComponent("Mix.wav"))
        let clicks = PlaybackAudio.loud(mix.left, above: 0.1)
        let firstClick = clicks.first ?? -1, lastClick = clicks.last ?? -1
        let spread = lastClick - firstClick
        let loudest = PlaybackAudio.peak(mix.left[...])
        let heardOffset = (heardAt ?? 0) - start
        let offset = session.layers[1].offsetFrames
        XCTAssertEqual(latency.total, 7200)
        XCTAssertEqual(heardOffset, 48_000, "the earlier layer starts with the pass, to the sample")
        XCTAssertEqual(offset, -7200)
        XCTAssertFalse(clicks.isEmpty)
        XCTAssertLessThanOrEqual(spread, 1, "both clicks within one sample")
        XCTAssertEqual(firstClick, 48_000)
        XCTAssertEqual(loudest, Mixdown.ceiling, accuracy: 1e-4, "one click of 1.0, turned down to −1 dBFS")
    }
}
