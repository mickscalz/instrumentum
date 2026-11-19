import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore

/// The inputs inside the engine (Recorder spec §5.2, §6, §9; plan Task 4, Review focus 2). An offline engine never opens
/// a device: the tests play into an input's capture ring themselves, with made-up devices, and stand in for the device
/// the app really plays to.
@MainActor
final class InputRoutingTests: XCTestCase {
    static let blackHole = InputDevice(id: 0, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", channels: 2)
    static let scarlett = InputDevice(id: 0, uid: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2", name: "Scarlett 2i2 USB", channels: 2)
    static let speakers = "BuiltInSpeakerDevice"
    static let stereo = ChannelChoice(left: 0, right: 1)

    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("InputRoutingTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeEngine() throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        return e
    }

    /// Plays `value` into the slot's input for `blocks` blocks of 512 frames (eight blocks ahead first, as a device a
    /// little ahead of the engine), rendering each: the last sample heard and the input's meter.
    private func play(_ e: AudioEngine, _ slot: InputSlot, value: Float, blocks: Int) throws -> (heard: Float, meter: Float) {
        guard let ring = e.inputCapture(slot)?.ring else {
            XCTFail("no input on \(slot)")
            return (0, 0)
        }
        let block = [Float](repeating: value, count: 512)
        for _ in 0..<8 { ring.write(left: block, right: block, frames: 512) }
        var heard: Float = 0
        for _ in 0..<blocks {
            ring.write(left: block, right: block, frames: 512)
            let out = try e.renderOffline(frames: 512)
            let n = Int(out.frameLength)
            if n > 0 { heard = out.floatChannelData![0][n - 1] }
        }
        return (heard, e.inputPeak(slot))
    }

    /// Spec §7: no input chosen leaves the engine as it was; asking about an input that isn't there is harmless.
    func testNoInputLeavesTheGraphAlone() throws {
        let e = try makeEngine()
        try e.setInput(.liveInput, device: nil, channels: Self.stereo, hearIt: true)
        e.setHearIt(.playAlong, true)
        let attached = e.recordingBusesAttached
        let peak = e.inputPeak(.liveInput)
        let latency = e.inputLatency(.liveInput)
        let howl = e.inputIsTheOutput(.playAlong)
        let device = e.inputDevice(.liveInput)
        XCTAssertFalse(attached)
        XCTAssertEqual(peak, 0)
        XCTAssertNil(latency)
        XCTAssertFalse(howl)
        XCTAssertNil(device)
    }

    /// Review focus 2: the app's output is the device it listens to (BlackHole), so playing it through would howl: it
    /// stays muted (but is still captured, so it records). Once he picks his speakers, it is heard.
    func testPlayThroughIsMutedWhenInputIsTheOutput() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.blackHole.uid
        try e.setInput(.playAlong, device: Self.blackHole, channels: Self.stereo, hearIt: true)
        let howl = e.inputIsTheOutput(.playAlong)
        let muted = try play(e, .playAlong, value: 0.25, blocks: 8)

        e.outputUIDForTests = Self.speakers
        e.setHearIt(.playAlong, true)
        let safe = e.inputIsTheOutput(.playAlong)
        let heard = try play(e, .playAlong, value: 0.25, blocks: 8)
        let attached = e.recordingBusesAttached
        XCTAssertTrue(howl)
        XCTAssertEqual(muted.heard, 0, accuracy: 1e-7, "never played into the device it listens to")
        XCTAssertGreaterThan(muted.meter, 0.2, "still captured, so it still records")
        XCTAssertFalse(safe)
        XCTAssertEqual(heard.heard, 0.25, accuracy: 1e-5)
        XCTAssertTrue(attached)
    }

    /// Hear it off: the input is captured and metered (and so recorded) but not heard. On: heard at its own bus.
    func testHearItOffRecordsWithoutPlayingThrough() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.speakers
        try e.setInput(.liveInput, device: Self.scarlett, channels: Self.stereo, hearIt: false)
        let silent = try play(e, .liveInput, value: 0.5, blocks: 8)
        e.setHearIt(.liveInput, true)
        let heard = try play(e, .liveInput, value: 0.5, blocks: 8)
        e.liveInputVolume = 0.5
        let halved = try play(e, .liveInput, value: 0.5, blocks: 8)
        XCTAssertEqual(silent.heard, 0, accuracy: 1e-7)
        XCTAssertGreaterThan(silent.meter, 0.4)
        XCTAssertEqual(heard.heard, 0.5, accuracy: 1e-5)
        XCTAssertEqual(halved.heard, 0.25, accuracy: 1e-5, "the bus's volume still applies")
    }

    /// The input gain (−24…+24 dB) moves what is heard and metered; it is held to its range.
    func testInputGain() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.speakers
        try e.setInput(.liveInput, device: Self.scarlett, channels: Self.stereo, hearIt: true)
        e.setInputGain(.liveInput, dB: -6.0206)
        let quieter = try play(e, .liveInput, value: 0.5, blocks: 16)
        e.setInputGain(.liveInput, dB: 60)
        let gain = e.inputCapture(.liveInput)?.gainDB ?? 0
        let louder = try play(e, .liveInput, value: 0.01, blocks: 16)
        XCTAssertEqual(quieter.heard, 0.25, accuracy: 1e-4)
        XCTAssertEqual(gain, 24)
        XCTAssertEqual(louder.heard, 0.01 * 15.8489, accuracy: 1e-3)
    }

    /// Each input records as its own stem (`.playAlong`, `.liveInput`), from what its source node plays: the stem tap's
    /// handler, fed what the tap would deliver (taps don't run offline).
    func testEachInputRecordsAsItsOwnStem() throws {
        let e = try makeEngine()
        let alongURL = dir.appendingPathComponent("Play-along.wav"), liveURL = dir.appendingPathComponent("Layer 1 — Microphone.wav")
        let start = try e.beginRecording([(kind: .playAlong, url: alongURL), (kind: .liveInput, url: liveURL)])
        let format = AVAudioFormat(standardFormatWithSampleRate: e.outputSampleRate, channels: 2)!
        func buffer(_ value: Float) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            b.frameLength = 1024
            for c in 0..<2 { for i in 0..<1024 { b.floatChannelData![c][i] = value } }
            return b
        }
        e.feedInputStem(InputSlot.playAlong.stemKind, buffer(0.5), sampleTime: start)
        e.feedInputStem(InputSlot.liveInput.stemKind, buffer(0.25), sampleTime: start)
        let frames = e.endRecording()
        let along = try RecordedStem(alongURL), live = try RecordedStem(liveURL)
        let alongFrames = frames[.playAlong] ?? 0, liveFrames = frames[.liveInput] ?? 0
        let alongFirst = along.left.first, liveLast = live.right.last
        XCTAssertEqual(alongFrames, 1024)
        XCTAssertEqual(liveFrames, 1024)
        XCTAssertEqual(alongFirst, 0.5)
        XCTAssertEqual(liveLast, 0.25)
    }

    /// Spec §8: an input unplugged mid-capture stops cleanly: the app is told which, and the engine plays on (silence
    /// where the input was).
    func testAnUnpluggedInputStopsCleanly() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.speakers
        var stopped: [InputSlot] = []
        e.onInputStopped = { stopped.append($0) }
        try e.setInput(.liveInput, device: Self.scarlett, channels: Self.stereo, hearIt: true)
        let before = try play(e, .liveInput, value: 0.5, blocks: 8)
        e.inputCapture(.liveInput)?.deviceLost()
        e.inputCapture(.liveInput)?.deviceLost()   // the device's listener and the engine's both notice
        var after: Float = 1
        for _ in 0..<16 {
            let out = try e.renderOffline(frames: 512)
            after = out.floatChannelData![0][Int(out.frameLength) - 1]
        }
        let device = e.inputDevice(.liveInput)
        XCTAssertEqual(before.heard, 0.5, accuracy: 1e-5)
        XCTAssertEqual(stopped, [.liveInput], "told once")
        XCTAssertEqual(after, 0, "the engine plays on, with silence where the input was")
        XCTAssertEqual(device, Self.scarlett, "still chosen: the app decides what to do")
    }

    /// A rebuild of the output (a device or rate change) keeps the inputs and looks at the no-howl rule again: the
    /// output changed to the device the input listens to, so play-through is muted.
    func testInputsFollowARebuild() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.speakers
        try e.setInput(.playAlong, device: Self.blackHole, channels: Self.stereo, hearIt: true)
        let before = try play(e, .playAlong, value: 0.25, blocks: 8)

        e.outputUIDForTests = Self.blackHole.uid   // he chose BlackHole as the app's output in Sound & MIDI
        e.engine.stop()   // as restartAudio() and a device switch do, which offline rendering skips
        e.rebuildOutput()
        try e.engine.start()
        let after = try play(e, .playAlong, value: 0.25, blocks: 8)
        let still = e.inputDevice(.playAlong)
        XCTAssertEqual(before.heard, 0.25, accuracy: 1e-5)
        XCTAssertEqual(after.heard, 0, accuracy: 1e-7)
        XCTAssertGreaterThan(after.meter, 0.2)
        XCTAssertEqual(still, Self.blackHole)
    }

    /// Removing an input takes its nodes out of the engine.
    func testRemovingAnInputDetachesIt() throws {
        let e = try makeEngine()
        e.outputUIDForTests = Self.speakers
        try e.setInput(.liveInput, device: Self.scarlett, channels: Self.stereo, hearIt: true)
        let node = e.inputCapture(.liveInput)?.sourceNode
        let attached = node?.engine != nil
        try e.setInput(.liveInput, device: nil, channels: Self.stereo, hearIt: true)
        let detached = node?.engine == nil
        let gone = e.inputCapture(.liveInput) == nil
        let out = try e.renderOffline(frames: 512)
        let n = Int(out.frameLength)
        XCTAssertTrue(attached)
        XCTAssertTrue(detached)
        XCTAssertTrue(gone)
        XCTAssertEqual(n, 512)
    }
}
