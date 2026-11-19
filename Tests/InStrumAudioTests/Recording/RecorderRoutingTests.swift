import XCTest
import AVFoundation
import AudioToolbox
@testable import InStrumAudio
@testable import InStrumCore

/// The Recorder inside the engine (Recorder spec §3, §7, §9; plan Task 2). Taps don't run in offline rendering, so the
/// stems here are fed what `renderOffline` returns, through `feedOffline`, stamped with the engine's own sample time.
@MainActor
final class RecorderRoutingTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderRoutingTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    let dls = InstrumentChoice(name: "Apple DLS Synth",
                               componentType: kAudioUnitType_MusicDevice,
                               componentSubType: kAudioUnitSubType_DLSSynth,
                               componentManufacturer: kAudioUnitManufacturer_Apple)

    private func makeEngine() async throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        try await e.loadInstrument(dls)
        return e
    }

    /// `frames` of offline rendering in 512-frame blocks (both channels). With `feed`, each block also goes to the
    /// recorder as the instrument stem, stamped with the sample time it was rendered at.
    private func render(_ e: AudioEngine, frames: Int, feed: Bool = false) throws -> (left: [Float], right: [Float]) {
        var left: [Float] = [], right: [Float] = []
        var t = e.engine.manualRenderingSampleTime
        while left.count < frames {
            let b = try e.renderOffline(frames: AVAudioFrameCount(min(512, frames - left.count)))
            let n = Int(b.frameLength)
            guard n > 0 else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![1], count: n))
            if feed { e.feedOffline(b, kind: .instrument, sampleTime: t) }
            t += Int64(n)
        }
        return (left, right)
    }

    private func peak(_ x: [Float]) -> Float {
        var m: Float = 0
        for v in x { m = max(m, abs(v)) }
        return m
    }

    /// Spec §7: with the Recorder idle the engine's graph and sound are exactly as today. Two fresh engines play the
    /// same note; on the second, everything the Recorder keeps is read (which attaches and allocates nothing).
    func testIdleEngineIsBitIdenticalToToday() async throws {
        let today = try await makeEngine()
        today.send([0x90, 60, 110])
        let a = try render(today, frames: 88_200)

        let e = try await makeEngine()
        let attachedBefore = e.recordingBusesAttached
        let recorder = e.recorder
        let volumes = e.playAlongVolume + e.liveInputVolume + e.layersVolume
        e.send([0x90, 60, 110])
        let b = try render(e, frames: 88_200)
        let attachedAfter = e.recordingBusesAttached
        let sameLeft = a.left == b.left
        let sameRight = a.right == b.right
        let heard = peak(b.left)
        let length = b.left.count
        XCTAssertEqual(length, 88_200)
        XCTAssertGreaterThan(heard, 0.01, "the note sounds")
        XCTAssertTrue(sameLeft, "sample for sample")
        XCTAssertTrue(sameRight, "sample for sample")
        XCTAssertFalse(attachedBefore)
        XCTAssertFalse(attachedAfter)
        XCTAssertNil(recorder)
        XCTAssertEqual(volumes, 3)
    }

    /// The instrument stem is the instrument bus, from the pass's start sample time on, within 24-bit quantisation.
    func testInstrumentStemEqualsTheInstrumentBus() async throws {
        let e = try await makeEngine()
        let url = dir.appendingPathComponent("Layer 1 — DLS.wav")
        let t0 = e.engine.manualRenderingSampleTime
        let start = try e.beginRecording([(kind: .instrument, url: url)])
        let recording = e.recorder?.isRecording ?? false
        e.send([0x90, 60, 110])
        let bus = try render(e, frames: 44_100, feed: true)
        let frames = e.endRecording()
        let stem = try RecordedStem(url)
        let lead = Int(start - t0)
        let expected = bus.left.count - lead
        let written = frames[.instrument] ?? -1
        guard stem.left.count == expected else { return XCTFail("the stem has \(stem.left.count) frames, not \(expected)") }
        var worst: Float = 0
        for i in 0..<expected {
            worst = max(worst, abs(stem.left[i] - bus.left[i + lead]))
            worst = max(worst, abs(stem.right[i] - bus.right[i + lead]))
        }
        let heard = peak(stem.left)
        let attached = e.recordingBusesAttached
        XCTAssertTrue(recording)
        XCTAssertEqual(lead, 512, "a pass starts two buffers from now")
        XCTAssertEqual(written, expected)
        XCTAssertEqual(stem.length, Int64(expected))
        XCTAssertTrue(stem.isWAV)
        XCTAssertEqual(stem.bitDepth, 24)
        XCTAssertEqual(stem.channels, 2)
        XCTAssertEqual(stem.sampleRate, 44_100)
        XCTAssertGreaterThan(heard, 0.01, "the note is in the stem")
        XCTAssertLessThanOrEqual(worst, 1.0 / 8_388_608)
        XCTAssertFalse(attached, "recording the instrument needs none of the new buses")
    }

    /// Records a held middle C after a short warm-up (so any volume glide is over): what was heard from the pass's
    /// start on, and the stem.
    private func recordNote(_ e: AudioEngine, _ name: String) throws -> (heard: [Float], stem: RecordedStem) {
        _ = try render(e, frames: 4096)
        let url = dir.appendingPathComponent(name)
        let t0 = e.engine.manualRenderingSampleTime
        let start = try e.beginRecording([(kind: .instrument, url: url)])
        e.send([0x90, 60, 110])
        let heard = try render(e, frames: 44_100, feed: true)
        _ = e.endRecording()
        let lead = min(heard.left.count, max(0, Int(start - t0)))
        let stem = try RecordedStem(url)
        return (Array(heard.left[lead...]), stem)
    }

    /// Spec §3, §8: stems are taken before the master volume and the sleep fade. Offline, `feedOffline` stands where the
    /// tap stands: the rendered output with the two gains the main mixer applies after the instrument bus taken back out.
    func testMasterVolumeAndSleepGainNeverReachAStem() async throws {
        let plain = try await makeEngine()
        let full = try recordNote(plain, "Full.wav")

        let e = try await makeEngine()
        e.masterVolume = 0.1
        e.sleepGain = 0.2
        let quiet = try recordNote(e, "Quiet.wav")

        let heardFull = peak(full.heard), heardQuiet = peak(quiet.heard)
        let stemFull = peak(full.stem.left), stemQuiet = peak(quiet.stem.left)
        let expectedQuiet = heardFull * 0.1 * 0.2
        let master = e.masterVolume, gains = e.busSleepGains
        XCTAssertGreaterThan(heardFull, 0.01, "the note sounds")
        XCTAssertEqual(heardQuiet, expectedQuiet, accuracy: 1e-5, "what is heard takes both gains")
        XCTAssertEqual(stemQuiet, stemFull, accuracy: 1e-5, "the stem takes neither")
        XCTAssertEqual(stemFull, heardFull, accuracy: 1e-5)
        XCTAssertEqual(master, 0.1, accuracy: 1e-6)
        XCTAssertEqual(gains.instrument, 0.2, accuracy: 1e-6)
    }

    /// Spec §3: ambience never reaches the instrument stem. The instrument stem comes from the instrument bus's tap,
    /// and recording ambience as its own stem leaves its route alone: straight to the main mixer, never through the
    /// instrument bus (as `testSoundCharacterIgnoresAmbience`).
    func testAmbienceNeverLeaksIntoTheInstrumentStem() async throws {
        let e = try await makeEngine()
        await e.startAmbience()
        e.setAmbience(AmbienceScene(levels: [.water: 1, .airFlow: 1]))
        let before = e.ambienceFeedsInstrumentBus
        _ = try e.beginRecording([(kind: .instrument, url: dir.appendingPathComponent("Layer 1 — DLS.wav")),
                                  (kind: .ambience, url: dir.appendingPathComponent("Ambience.wav"))])
        _ = try render(e, frames: 4096)
        let during = e.ambienceFeedsInstrumentBus
        let toMixer = e.ambienceFeedsMainMixer
        let frames = e.endRecording()
        let after = e.ambienceFeedsInstrumentBus
        let kinds = Set(frames.keys)
        let attached = e.recordingBusesAttached
        XCTAssertFalse(before)
        XCTAssertFalse(during)
        XCTAssertFalse(after)
        XCTAssertTrue(toMixer)
        XCTAssertEqual(kinds, [.instrument, .ambience], "two separate files")
        XCTAssertFalse(attached)
    }

    /// A source playing `value` on both channels.
    nonisolated private static func constant(_ value: Float, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(frames) { p[i] = value }
            }
            return noErr
        }
    }

    /// The three buses attach on first use, keep their volumes and their sources across a rebuild of the output (as a
    /// device or rate change does), and carry the sleep fade like the instrument's and the ambience's.
    func testBusesSurviveARebuild() async throws {
        let e = try await makeEngine()
        e.liveInputVolume = 0.5
        let attachedByAVolume = e.recordingBusesAttached
        let format = AVAudioFormat(standardFormatWithSampleRate: e.outputSampleRate, channels: 2)!
        let sources = [Self.constant(0.1, format: format), Self.constant(0.01, format: format), Self.constant(0.001, format: format)]
        let buses = [e.playAlongBus, e.liveInputBus, e.layersBus]
        for (source, bus) in zip(sources, buses) {
            e.engine.attach(source)
            e.engine.connect(source, to: bus, format: format)
        }
        let attached = e.recordingBusesAttached
        let before = try render(e, frames: 4096).left.last ?? 0

        e.engine.stop()   // as restartAudio() does, which offline rendering skips
        e.rebuildOutput()
        try e.engine.start()
        let fed = e.recordingBusesFeedMainMixer
        let after = try render(e, frames: 4096).left.last ?? 0
        e.sleepGain = 0.5
        let faded = try render(e, frames: 4096).left.last ?? 0
        let liveVolume = e.liveInputVolume

        XCTAssertFalse(attachedByAVolume, "a volume alone attaches nothing")
        XCTAssertTrue(attached)
        XCTAssertTrue(fed)
        XCTAssertEqual(before, 0.106, accuracy: 1e-5, "0.1 + 0.01 × 0.5 + 0.001")
        XCTAssertEqual(after, 0.106, accuracy: 1e-5)
        XCTAssertEqual(faded, 0.053, accuracy: 1e-5)
        XCTAssertEqual(liveVolume, 0.5)
    }
}
