import XCTest
@testable import InStrumAudio

/// The capture ring (Recorder spec §5.2, §6, §9; plan Task 4): an input on its own clock reaches the engine through a
/// small buffer and a gentle resampler that keeps the buffer's level steady, so two clocks never click or run dry.
/// The clocks here are simulated: every write and read carries the time it happens at.
final class CaptureRingTests: XCTestCase {

    /// The sample written at frame `i`: exact in a Float, so a frame read back tells where it came from.
    private static func ramp(_ i: Int) -> Float { Float(i % 1_048_576) / 65_536 }

    /// Every frame comes out once, in order and unchanged, when the two clocks agree; the left and right stay apart.
    func testRingRoundTrip() {
        let ring = CaptureRing(capacityFrames: 4096, targetFrames: 480, writeRate: 48_000)
        let block = 512, period = 512.0 / 48_000
        var inLeft = [Float](repeating: 0, count: block), inRight = inLeft
        var outLeft = inLeft, outRight = inLeft
        var left: [Float] = [], right: [Float] = []
        for k in 0..<40 {
            for i in 0..<block {
                inLeft[i] = Self.ramp(k * block + i)
                inRight[i] = -inLeft[i]
            }
            let t = Double(k) * period
            ring.write(left: inLeft, right: inRight, frames: block, at: t)
            ring.read(left: &outLeft, right: &outRight, frames: block, at: t)
            left.append(contentsOf: outLeft)
            right.append(contentsOf: outRight)
        }
        // The reader waits for its 10 ms, then fades in over 256 frames; from there on every frame is the next one.
        guard let first = left.firstIndex(where: { $0 != 0 }) else { return XCTFail("nothing came out") }
        let from = first + 256
        var outOfOrder = 0, sidesMixed = 0
        for i in from..<(left.count - 1) where left[i + 1] - left[i] != 1.0 / 65_536 { outOfOrder += 1 }
        for i in from..<left.count where right[i] != -left[i] { sidesMixed += 1 }
        let checked = left.count - from
        let fill = ring.fillFrames
        let underruns = ring.underruns, overruns = ring.overruns
        XCTAssertGreaterThan(checked, 15_000)
        XCTAssertEqual(outOfOrder, 0, "each frame is the one after the last")
        XCTAssertEqual(sidesMixed, 0)
        XCTAssertEqual(fill, 480, "the level sits on its target")
        XCTAssertEqual(underruns, 0)
        XCTAssertEqual(overruns, 0)
    }

    /// An empty ring gives silence, not whatever was in the buffer; a writer that stops gives silence once the ring
    /// runs dry, counted once.
    func testUnderrunGivesSilence() {
        let ring = CaptureRing(capacityFrames: 4096, targetFrames: 480, writeRate: 48_000)
        let block = 512, period = 512.0 / 48_000
        var outLeft = [Float](repeating: 9, count: block), outRight = outLeft
        ring.read(left: &outLeft, right: &outRight, frames: block, at: 0)
        var garbage = 0
        for i in 0..<block where outLeft[i] != 0 || outRight[i] != 0 { garbage += 1 }
        let underrunsWhenEmpty = ring.underruns

        let input = [Float](repeating: 0.5, count: block)
        var t = 0.0
        for _ in 0..<10 {
            ring.write(left: input, right: input, frames: block, at: t)
            ring.read(left: &outLeft, right: &outRight, frames: block, at: t)
            t += period
        }
        let playing = outLeft[block - 1]
        var lastBlockSilent = false
        for _ in 0..<4 {   // the writer has stopped (the device was unplugged)
            outLeft = [Float](repeating: 9, count: block)
            outRight = outLeft
            ring.read(left: &outLeft, right: &outRight, frames: block, at: t)
            t += period
            lastBlockSilent = !outLeft.contains { $0 != 0 } && !outRight.contains { $0 != 0 }
        }
        let underruns = ring.underruns
        XCTAssertEqual(garbage, 0, "silence, not garbage")
        XCTAssertEqual(underrunsWhenEmpty, 0, "waiting for the first frames is not an underrun")
        XCTAssertEqual(playing, 0.5)
        XCTAssertTrue(lastBlockSilent)
        XCTAssertEqual(underruns, 1, "running dry is counted once")
    }

    /// What a run did: the fill's range after `settle`, the counters, and (if kept) the left channel read.
    private struct Run {
        var minFill = Int.max
        var maxFill = Int.min
        var underruns = 0
        var overruns = 0
        var output: [Float] = []
    }

    /// A writer whose clock really runs at `writeRate` (it thinks it runs at `nominalRate`) and a reader at `readRate`,
    /// each in 512-frame blocks, for `seconds` of simulated time, events in time order. With `sineHz` the writer plays
    /// that sine (at its own idea of its rate) and the reader's left channel is kept.
    private func simulate(writeRate: Double, nominalRate: Double, readRate: Double, seconds: Double, target: Int,
                          sineHz: Double? = nil, settle: Double = 1) -> Run {
        let ring = CaptureRing(capacityFrames: 16_384, targetFrames: target, writeRate: nominalRate, readRate: readRate)
        let block = 512
        let writePeriod = Double(block) / writeRate, readPeriod = Double(block) / readRate
        var inLeft = [Float](repeating: 0, count: block), inRight = inLeft
        var outLeft = inLeft, outRight = inLeft
        var run = Run()
        if sineHz != nil { run.output.reserveCapacity(Int(seconds * readRate) + block) }
        var writes = 0, reads = 0, phase = 0.0
        let step = 2 * Double.pi * (sineHz ?? 0) / nominalRate
        while Double(reads) * readPeriod < seconds {
            let tw = Double(writes) * writePeriod, tr = Double(reads) * readPeriod
            if tw <= tr {
                if sineHz != nil {
                    for i in 0..<block {
                        inLeft[i] = Float(0.9 * sin(phase))
                        inRight[i] = inLeft[i]
                        phase += step
                    }
                    phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
                }
                ring.write(left: inLeft, right: inRight, frames: block, at: tw)
                writes += 1
            } else {
                ring.read(left: &outLeft, right: &outRight, frames: block, at: tr)
                reads += 1
                if sineHz != nil { run.output.append(contentsOf: outLeft) }
                if tr >= settle {
                    let fill = ring.fillFrames
                    run.minFill = min(run.minFill, fill)
                    run.maxFill = max(run.maxFill, fill)
                }
            }
        }
        run.underruns = ring.underruns
        run.overruns = ring.overruns
        return run
    }

    /// The frequency of a sine from its rising zero crossings (each placed between its two samples), after `skip`.
    private func frequency(_ x: [Float], rate: Double, skip: Int) -> Double {
        var first = -1.0, last = -1.0, crossings = 0
        for i in max(1, skip)..<x.count where x[i - 1] < 0 && x[i] >= 0 {
            let at = Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1]))
            if first < 0 { first = at }
            last = at
            crossings += 1
        }
        guard crossings > 1, last > first else { return 0 }
        return Double(crossings - 1) * rate / (last - first)
    }

    private func largestJump(_ x: [Float]) -> Float {
        var most: Float = 0
        for i in 1..<x.count { most = max(most, abs(x[i] - x[i - 1])) }
        return most
    }

    /// Spec §9: an hour with the input's clock 200 ppm fast never under- or over-runs, and the level stays within ±3 ms
    /// (144 frames) of its 10 ms target after the first second.
    func testDriftNeverUnderOrOverRuns() {
        let fast = simulate(writeRate: 48_000 * (1 + 200e-6), nominalRate: 48_000, readRate: 48_000, seconds: 3600, target: 480)
        let slow = simulate(writeRate: 48_000 * (1 - 200e-6), nominalRate: 48_000, readRate: 48_000, seconds: 3600, target: 480)
        XCTAssertEqual(fast.underruns, 0)
        XCTAssertEqual(fast.overruns, 0)
        XCTAssertGreaterThanOrEqual(fast.minFill, 480 - 144)
        XCTAssertLessThanOrEqual(fast.maxFill, 480 + 144)
        XCTAssertEqual(slow.underruns, 0)
        XCTAssertEqual(slow.overruns, 0)
        XCTAssertGreaterThanOrEqual(slow.minFill, 480 - 144)
        XCTAssertLessThanOrEqual(slow.maxFill, 480 + 144)
    }

    /// The correction is far too small to hear: a 1 kHz sine through 200 ppm of drift is still 1 kHz (it really is
    /// 1000.2 Hz in the reader's time) and has no click (no step larger than the sine's own, 0.12 at 0.9 amplitude).
    func testDriftCorrectionIsInaudiblySmall() {
        let run = simulate(writeRate: 48_000 * (1 + 200e-6), nominalRate: 48_000, readRate: 48_000, seconds: 20, target: 480,
                           sineHz: 1000)
        let hz = frequency(run.output, rate: 48_000, skip: 48_000)
        let jump = largestJump(run.output)
        XCTAssertEqual(hz, 1000, accuracy: 0.5)
        XCTAssertLessThanOrEqual(jump, 0.2, "no clicks")
        XCTAssertEqual(run.underruns, 0)
        XCTAssertEqual(run.overruns, 0)
    }

    /// An input at 44.1 kHz into a 48 kHz engine: the ring converts the rate, so the sine keeps its pitch.
    func testCaptureResamplesToTheEngineRate() {
        let run = simulate(writeRate: 44_100, nominalRate: 44_100, readRate: 48_000, seconds: 10, target: 441, sineHz: 1000)
        let hz = frequency(run.output, rate: 48_000, skip: 48_000)
        let jump = largestJump(run.output)
        XCTAssertEqual(hz, 1000, accuracy: 1)
        XCTAssertLessThanOrEqual(jump, 0.2)
        XCTAssertEqual(run.underruns, 0)
        XCTAssertEqual(run.overruns, 0)
        XCTAssertGreaterThanOrEqual(run.minFill, 441 - 144)
        XCTAssertLessThanOrEqual(run.maxFill, 441 + 144)
    }
}
