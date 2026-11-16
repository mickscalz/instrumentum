import XCTest
import AVFoundation
import os
@testable import InStrumAudio
@testable import InStrumCore

/// A stem read back from disk: its samples and its file format.
struct RecordedStem {
    let left: [Float]
    let right: [Float]
    let length: Int64
    let channels: Int
    let bitDepth: Int
    let sampleRate: Double
    /// The file starts "RIFF….WAVE".
    let isWAV: Bool

    init(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        length = file.length
        channels = Int(file.fileFormat.channelCount)
        bitDepth = Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel)
        sampleRate = file.fileFormat.sampleRate
        var l: [Float] = [], r: [Float] = []
        if length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)) {
            try file.read(into: buffer)
            let n = Int(buffer.frameLength)
            l = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
            r = Array(UnsafeBufferPointer(start: buffer.floatChannelData![channels > 1 ? 1 : 0], count: n))
        }
        left = l
        right = r
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 12) ?? Data()
        isWAV = head.count == 12 && head.prefix(4) == Data("RIFF".utf8) && head.suffix(4) == Data("WAVE".utf8)
    }
}

/// The stem recorder (Recorder spec §3, §7; plan Task 2): what it keeps, what it drops, the files it leaves, and that
/// an hour of feeding never overruns its rings.
final class StemRecorderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StemRecorderTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The sample played at sample time `t`: a multiple of 1/8192 (exact in 24 bits) and never zero, so neither silence
    /// nor a frame from the wrong time can pass for it. The right channel carries its negative.
    nonisolated static func value(at t: Int64) -> Float { Float(t % 4096 + 1) / 8192 }

    /// Feeds `frames` frames stamped `sampleTime`, as a tap would.
    nonisolated static func feed(_ r: StemRecorder, _ kind: StemKind, frames: Int, at sampleTime: Int64) {
        var left = [Float](repeating: 0, count: frames), right = left
        for i in 0..<frames {
            left[i] = value(at: sampleTime + Int64(i))
            right[i] = -left[i]
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { rr in
                r.feed(kind, left: l.baseAddress!, right: rr.baseAddress!, frames: frames, sampleTime: sampleTime)
            }
        }
    }

    /// How many frames of `stem` hold the sample played at `start + i` (left and right).
    private func framesInTime(_ stem: RecordedStem, from start: Int64) -> Int {
        var good = 0
        for i in 0..<stem.left.count {
            let v = Self.value(at: start + Int64(i))
            if stem.left[i] == v && stem.right[i] == -v { good += 1 }
        }
        return good
    }

    func testFramesBeforeStartAreDropped() throws {
        let r = StemRecorder(sampleRate: 48_000)
        let url = dir.appendingPathComponent("Layer 1 — Early.wav")
        try r.begin([(kind: .instrument, url: url)], atSampleTime: 1000)
        Self.feed(r, .instrument, frames: 512, at: 0)      // all before the start
        Self.feed(r, .instrument, frames: 1024, at: 512)   // 488 before it, 536 from it on
        let frames = r.end()
        let stem = try RecordedStem(url)
        let written = frames[.instrument]
        let inTime = framesInTime(stem, from: 1000)
        let first = stem.left.first
        let firstExpected = Self.value(at: 1000)
        XCTAssertEqual(written, 536)
        XCTAssertEqual(stem.length, 536)
        XCTAssertEqual(inTime, 536, "frame 0 of the stem is sample time 1000, and every frame follows in order")
        XCTAssertEqual(first, firstExpected)
    }

    func testAGapIsFilledWithSilence() throws {
        let r = StemRecorder(sampleRate: 48_000)
        let url = dir.appendingPathComponent("Layer 1 — Gap.wav")
        try r.begin([(kind: .instrument, url: url)], atSampleTime: 0)
        Self.feed(r, .instrument, frames: 512, at: 0)
        Self.feed(r, .instrument, frames: 512, at: 1024)
        let frames = r.end()
        let stem = try RecordedStem(url)
        let written = frames[.instrument]
        guard stem.left.count == 1536 else { return XCTFail("the stem has \(stem.left.count) frames, not 1536") }
        var silent = 0
        for i in 512..<1024 where stem.left[i] == 0 && stem.right[i] == 0 { silent += 1 }
        let before = stem.left[511], beforeExpected = Self.value(at: 511)
        let after = stem.left[1024], afterExpected = Self.value(at: 1024)
        let last = stem.right[1535], lastExpected = -Self.value(at: 1535)
        XCTAssertEqual(written, 1536)
        XCTAssertEqual(stem.length, 1536)
        XCTAssertEqual(silent, 512)
        XCTAssertEqual(before, beforeExpected)
        XCTAssertEqual(after, afterExpected, "the second buffer lands at its own sample time")
        XCTAssertEqual(last, lastExpected)
    }

    /// Review focus 4: a pass ended while the tap is still feeding, and a recorder let go without `end()`, both leave
    /// closed, readable 24-bit stereo WAVs holding exactly the frames they report.
    func testAStoppedWriterLeavesAReadableFile() throws {
        // end() mid-stream: a tap thread keeps feeding (about 10× real time) through and after the end.
        let rate = 48_000.0
        let r = StemRecorder(sampleRate: rate)
        let instrumentURL = dir.appendingPathComponent("Layer 1 — Mid-stream.wav")
        let liveURL = dir.appendingPathComponent("Layer 2 — Microphone.wav")
        try r.begin([(kind: .instrument, url: instrumentURL), (kind: .liveInput, url: liveURL)], atSampleTime: 0)
        let stop = OSAllocatedUnfairLock(initialState: false)
        let finished = DispatchSemaphore(value: 0)
        let tap = Thread {
            var t: Int64 = 0
            while !stop.withLock({ $0 }) {
                StemRecorderTests.feed(r, .instrument, frames: 512, at: t)
                StemRecorderTests.feed(r, .liveInput, frames: 512, at: t)
                t += 512
                Thread.sleep(forTimeInterval: 0.001)
            }
            finished.signal()
        }
        tap.start()
        Thread.sleep(forTimeInterval: 0.4)
        let wasRecording = r.isRecording
        let frames = r.end()
        let stillRecording = r.isRecording
        Thread.sleep(forTimeInterval: 0.05)   // the tap carries on into a recorder that has stopped
        stop.withLock { $0 = true }
        finished.wait()
        let instrument = try RecordedStem(instrumentURL)
        let live = try RecordedStem(liveURL)
        let instrumentFrames = frames[.instrument] ?? -1
        let liveFrames = frames[.liveInput] ?? -1
        let instrumentInTime = framesInTime(instrument, from: 0)
        let liveInTime = framesInTime(live, from: 0)
        let overruns = r.overruns
        XCTAssertTrue(wasRecording)
        XCTAssertFalse(stillRecording)
        XCTAssertGreaterThan(instrumentFrames, 4800, "a good part of the 0.4 s was kept")
        XCTAssertEqual(instrument.length, Int64(instrumentFrames))
        XCTAssertEqual(live.length, Int64(liveFrames))
        XCTAssertEqual(instrumentInTime, instrumentFrames)
        XCTAssertEqual(liveInTime, liveFrames)
        XCTAssertEqual(overruns, 0)
        XCTAssertTrue(instrument.isWAV)
        XCTAssertEqual(instrument.bitDepth, 24)
        XCTAssertEqual(instrument.channels, 2)
        XCTAssertEqual(instrument.sampleRate, rate)

        // Let go without end(): the files close as the recorder goes.
        let droppedURL = dir.appendingPathComponent("Play-along.wav")
        var dropped: StemRecorder? = StemRecorder(sampleRate: 44_100)
        try dropped?.begin([(kind: .playAlong, url: droppedURL)], atSampleTime: 0)
        for k in 0..<10 { Self.feed(dropped!, .playAlong, frames: 512, at: Int64(k * 512)) }
        dropped = nil
        let playAlong = try RecordedStem(droppedURL)
        let playAlongInTime = framesInTime(playAlong, from: 0)
        XCTAssertTrue(playAlong.isWAV)
        XCTAssertEqual(playAlong.length, 5120)
        XCTAssertEqual(playAlongInTime, 5120)
        XCTAssertEqual(playAlong.sampleRate, 44_100)
        XCTAssertEqual(playAlong.bitDepth, 24)
    }

    func testMetersClockAndState() throws {
        let r = StemRecorder(sampleRate: 48_000)
        let url = dir.appendingPathComponent("Layer 1 — Meter.wav")
        let idle = r.isRecording
        try r.begin([(kind: .instrument, url: url)], atSampleTime: 0)
        var refused: StemRecorder.RecorderError?
        do { try r.begin([(kind: .instrument, url: url)], atSampleTime: 0) } catch { refused = error as? StemRecorder.RecorderError }
        for k in 0..<10 { Self.feed(r, .instrument, frames: 480, at: Int64(k * 480)) }
        Self.feed(r, .ambience, frames: 480, at: 0)   // not in this pass: ignored
        let recording = r.isRecording
        let peak = r.peak(.instrument)
        let peakAgain = r.peak(.instrument)
        let seconds = r.seconds
        let frames = r.end()
        let kinds = Set(frames.keys)
        let ambienceFile = FileManager.default.fileExists(atPath: dir.appendingPathComponent("Ambience.wav").path)
        let afterEnd = r.end()
        XCTAssertFalse(idle)
        XCTAssertEqual(refused, .alreadyRecording, "one pass at a time")
        XCTAssertTrue(recording)
        XCTAssertEqual(peak, Self.value(at: 4095), "the loudest sample fed (4096/8192)")
        XCTAssertEqual(peakAgain, 0, "a meter reading clears it")
        XCTAssertEqual(seconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(kinds, [.instrument])
        XCTAssertFalse(ambienceFile)
        XCTAssertTrue(afterEnd.isEmpty)
    }

    /// An hour of 512-frame buffers fed at up to 25× real time while the writer runs: not one buffer is lost. The app's
    /// 2 s ring gives the writer 2 s of slack at real time; fed 25× faster, the ring here is 60 s, the same 2.4 s of
    /// slack (with the 2 s ring a shared CI machine's writer stalls overran it).
    func testOneHourOfFeedsNeverOverruns() throws {
        let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        if free < 3_000_000_000 { throw XCTSkip("an hour's stem needs 3 GB free; \(free / 1_000_000) MB here") }
        let rate = 48_000.0
        let r = StemRecorder(sampleRate: rate, capacitySeconds: 60)
        let url = dir.appendingPathComponent("Layer 1 — One Hour.wav")
        try r.begin([(kind: .instrument, url: url)], atSampleTime: 0)
        let block = 512
        let total = Int64(3600 * rate)
        var left = [Float](repeating: 0, count: block), right = left
        for i in 0..<block {   // 8 whole cycles per buffer, so it runs on without a seam
            left[i] = 0.5 * sinf(2 * .pi * Float(i) / 64)
            right[i] = -left[i]
        }
        let perStep = Int(0.25 * rate) / block
        var t: Int64 = 0
        while t < total {
            var k = 0
            while k < perStep && t < total {
                let n = Int(min(Int64(block), total - t))
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { rr in
                        r.feed(.instrument, left: l.baseAddress!, right: rr.baseAddress!, frames: n, sampleTime: t)
                    }
                }
                t += Int64(n)
                k += 1
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let overruns = r.overruns
        let seconds = r.seconds
        let frames = r.end()
        let written = frames[.instrument] ?? -1
        let length = try AVAudioFile(forReading: url).length
        XCTAssertEqual(overruns, 0)
        XCTAssertEqual(seconds, 3600, accuracy: 0.001)
        XCTAssertEqual(written, Int(total))
        XCTAssertEqual(length, total)
    }
}
