import XCTest
@testable import InStrumCore

/// The mix (Recorder spec §4; plan Task 1, global constraints): each stem × its gain, summed at its offset (frames before
/// the start dropped); if the peak passes −1 dBFS (0.891) the whole mix is turned down by one gain to fit, and never up.
/// And the waveform a layer row draws: the peak of each bucket.
final class MixdownTests: XCTestCase {
    private func stem(_ value: Float, count: Int, gain: Float = 1, offset: Int = 0) -> Mixdown.Stem {
        let samples = [Float](repeating: value, count: count)
        return Mixdown.Stem(left: samples, right: samples, gain: gain, offsetFrames: offset)
    }

    private func peak(_ samples: [Float]) -> Float {
        var p: Float = 0
        for v in samples { p = max(p, abs(v)) }
        return p
    }

    func testMixSumsWithGainsAndOffsets() {
        let a = stem(0.25, count: 1000, gain: 1)
        let b = stem(0.25, count: 1000, gain: 0.5, offset: 100)
        let out = Mixdown.mix([a, b])
        let length = out.left.count
        let rightLength = out.right.count
        XCTAssertEqual(length, 1100, "the longest end")
        XCTAssertEqual(rightLength, 1100)
        let onlyA = out.left[50]
        XCTAssertEqual(onlyA, 0.25, accuracy: 1e-6)
        let both = out.left[500]
        XCTAssertEqual(both, 0.375, accuracy: 1e-6)
        let bothRight = out.right[500]
        XCTAssertEqual(bothRight, 0.375, accuracy: 1e-6)
        let onlyB = out.left[1050]
        XCTAssertEqual(onlyB, 0.125, accuracy: 1e-6)
        XCTAssertEqual(out.gain, 1, "well under the ceiling: untouched")

        // The two sides stay apart.
        let leftOnly = Mixdown.Stem(left: [0.5, 0.5], right: [0, 0], gain: 1, offsetFrames: 0)
        let sides = Mixdown.mix([leftOnly])
        let l = sides.left[1]
        let r = sides.right[1]
        XCTAssertEqual(l, 0.5)
        XCTAssertEqual(r, 0)
    }

    func testNegativeOffsetDropsTheLead() {
        let ramp = (0..<1000).map { Float($0) / 1000 }
        let early = Mixdown.Stem(left: ramp, right: ramp, gain: 1, offsetFrames: -100)
        let out = Mixdown.mix([early])
        let length = out.left.count
        XCTAssertEqual(length, 900, "the first 100 frames fall before the start")
        let first = out.left[0]
        XCTAssertEqual(first, 0.1, accuracy: 1e-6)
        let last = out.right[899]
        XCTAssertEqual(last, 0.999, accuracy: 1e-6)

        // With a stem at 0 beside it, the mix still starts at 0.
        let other = stem(0.5, count: 200)
        let both = Mixdown.mix([early, other])
        let bothLength = both.left.count
        XCTAssertEqual(bothLength, 900)
        let start = both.left[0]
        XCTAssertEqual(start, 0.6, accuracy: 1e-6)
        let later = both.left[300]
        XCTAssertEqual(later, 0.4, accuracy: 1e-6)

        // A stem wholly before the start adds nothing.
        let gone = stem(1, count: 3, offset: -10)
        let none = Mixdown.mix([gone])
        let noneLength = none.left.count
        XCTAssertEqual(noneLength, 0)
        XCTAssertEqual(none.gain, 1)
    }

    func testMutedIsGainZero() {
        // A muted layer comes in at gain 0: it adds no sound, no length, and doesn't turn the others down.
        let muted = stem(1, count: 2000, gain: 0)
        let quiet = stem(0.25, count: 500, gain: 1)
        let out = Mixdown.mix([muted, quiet])
        let length = out.left.count
        XCTAssertEqual(length, 500)
        XCTAssertEqual(out.gain, 1)
        let sample = out.left[100]
        XCTAssertEqual(sample, 0.25)
        let alone = Mixdown.mix([quiet])
        XCTAssertEqual(out.left, alone.left)
        XCTAssertEqual(out.right, alone.right)
    }

    func testOneGainHeadroom() {
        XCTAssertEqual(Mixdown.ceiling, 0.891)
        let shape: [Float] = [1, 0.5, -1, 0.25, -0.75, 0, 0.125]
        let a = Mixdown.Stem(left: shape, right: shape, gain: 1, offsetFrames: 0)
        let out = Mixdown.mix([a, a])
        let leftPeak = peak(out.left)
        let rightPeak = peak(out.right)
        XCTAssertEqual(leftPeak, 0.891, accuracy: 1e-4, "turned down to −1 dBFS")
        XCTAssertEqual(rightPeak, 0.891, accuracy: 1e-4)
        XCTAssertEqual(out.gain, 0.4455, accuracy: 1e-6)
        // One gain for the whole file: every sample keeps its ratio to every other.
        let reference = out.left[0]
        for i in 0..<shape.count {
            let ratio = out.left[i] / reference
            let expected = shape[i] / shape[0]
            XCTAssertEqual(ratio, expected, accuracy: 1e-6, "sample \(i)")
            let sample = out.left[i]
            let wanted = 2 * shape[i] * 0.4455
            XCTAssertEqual(sample, wanted, accuracy: 1e-6, "sample \(i)")
        }

        // One gain for both sides too: a loud left turns a quiet right down by the same amount.
        let loudLeft = Mixdown.Stem(left: [1, 1], right: [0.1, 0.1], gain: 1, offsetFrames: 0)
        let lopsided = Mixdown.mix([loudLeft, loudLeft])
        let right = lopsided.right[0]
        XCTAssertEqual(lopsided.gain, 0.4455, accuracy: 1e-6)
        XCTAssertEqual(right, 0.0891, accuracy: 1e-6)
    }

    func testQuietMixIsNeverScaledUp() {
        let quiet = Mixdown.Stem(left: [0.1, -0.2, 0.3], right: [0.3, 0.2, 0.1], gain: 1, offsetFrames: 0)
        let out = Mixdown.mix([quiet])
        XCTAssertEqual(out.gain, 1, "never louder than the sum")
        XCTAssertEqual(out.left, [0.1, -0.2, 0.3])
        XCTAssertEqual(out.right, [0.3, 0.2, 0.1])

        let atCeiling = Mixdown.Stem(left: [0.891], right: [-0.891], gain: 1, offsetFrames: 0)
        let edge = Mixdown.mix([atCeiling])
        XCTAssertEqual(edge.gain, 1, "exactly at the ceiling is left alone")
        let edgeSample = edge.left[0]
        XCTAssertEqual(edgeSample, 0.891)

        let empty = Mixdown.mix([])
        let emptyLength = empty.left.count
        XCTAssertEqual(emptyLength, 0)
        XCTAssertEqual(empty.gain, 1)
    }

    func testWaveformBuckets() {
        var samples = [Float](repeating: 0, count: 400)
        samples[10] = 0.5
        samples[150] = -0.8
        samples[399] = 1.5
        let bars = Mixdown.waveform(samples, buckets: 4)
        let count = bars.count
        XCTAssertEqual(count, 4)
        let b0 = bars[0]
        let b1 = bars[1]
        let b2 = bars[2]
        let b3 = bars[3]
        XCTAssertEqual(b0, 0.5, accuracy: 1e-6)
        XCTAssertEqual(b1, 0.8, accuracy: 1e-6, "the peak, whichever way it swings")
        XCTAssertEqual(b2, 0, "silence")
        XCTAssertEqual(b3, 1, "never past full")

        // An uneven split still covers every sample once.
        var ten = [Float](repeating: 0, count: 10)
        ten[2] = 0.2
        ten[5] = 0.5
        ten[9] = 0.9
        let thirds = Mixdown.waveform(ten, buckets: 3)
        XCTAssertEqual(thirds, [0.2, 0.5, 0.9])

        // Fewer samples than buckets: each bucket shows the sample under it.
        let stretched = Mixdown.waveform([0.25, -0.5], buckets: 4)
        XCTAssertEqual(stretched, [0.25, 0.25, 0.5, 0.5])

        let none = Mixdown.waveform(samples, buckets: 0)
        XCTAssertTrue(none.isEmpty)
        let silent = Mixdown.waveform([], buckets: 3)
        XCTAssertEqual(silent, [0, 0, 0])
    }
}
