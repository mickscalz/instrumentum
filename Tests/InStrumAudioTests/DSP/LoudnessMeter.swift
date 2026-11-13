import Accelerate
import Foundation

/// Loudness for tests: integrated loudness by ITU-R BS.1770-4 for a stereo signal at 48 kHz (LUFS), and an estimate of
/// its true peak (dBTP).
///
/// - Integrated loudness: both channels through the K-weighting pre-filter (the standard's two biquads at 48 kHz: its
///   high shelf, then its high-pass), the mean square of each 400 ms block (blocks 100 ms apart, so they overlap by
///   75%), each block's loudness −0.691 + 10·log10(the sum of its channels' mean squares), the blocks gated at −70 LUFS
///   (absolute) and then 10 LU under the loudness of those left (relative), and the integrated loudness −0.691 +
///   10·log10 of the mean of the gated blocks' channel sums. −∞ for silence (no block above the absolute gate) or a
///   signal shorter than one block.
/// - True peak: the largest magnitude of either channel 4× oversampled: each sample, and three points between it and the
///   next by 32-tap fractional-delay filters (a Hann-windowed sinc), in dB of full scale.
///
/// The same meter as `Tests/InStrumAppTests/LoudnessMeter.swift` (test targets cannot share a file): keep the two alike.
enum LoudnessMeter {
    /// The rate the K-weighting coefficients are for.
    static let sampleRate = 48_000.0
    /// 100 ms: a block's step, and a quarter of a block.
    static let segment = 4800

    /// The K-weighting pre-filter at 48 kHz (BS.1770-4, Tables 1 and 2), each b0, b1, b2, a1, a2 (a0 = 1).
    static let shelf: [Double] = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
    static let highPass: [Double] = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]

    /// The loudness (LUFS) of a mean square summed over the channels.
    static func loudness(_ power: Double) -> Double {
        power > 0 ? -0.691 + 10 * log10(power) : -Double.infinity
    }

    /// The K-weighted signal's sum of squares over each 100 ms of `x` (a last part shorter than 100 ms is left out).
    static func segmentEnergies(_ x: [Float]) -> [Double] {
        let count = x.count / segment
        var out = [Double](repeating: 0, count: count)
        guard count > 0 else { return out }
        let s0 = shelf[0], s1 = shelf[1], s2 = shelf[2], s3 = shelf[3], s4 = shelf[4]
        let h0 = highPass[0], h1 = highPass[1], h2 = highPass[2], h3 = highPass[3], h4 = highPass[4]
        var sx1 = 0.0, sx2 = 0.0, sy1 = 0.0, sy2 = 0.0   // the shelf's state
        var hx1 = 0.0, hx2 = 0.0, hy1 = 0.0, hy2 = 0.0   // the high-pass's
        x.withUnsafeBufferPointer { p in
            for k in 0..<count {
                var sum = 0.0
                for i in (k * segment)..<((k + 1) * segment) {
                    let v = Double(p[i])
                    let a = s0 * v + s1 * sx1 + s2 * sx2 - s3 * sy1 - s4 * sy2
                    sx2 = sx1; sx1 = v; sy2 = sy1; sy1 = a
                    let b = h0 * a + h1 * hx1 + h2 * hx2 - h3 * hy1 - h4 * hy2
                    hx2 = hx1; hx1 = a; hy2 = hy1; hy1 = b
                    sum += b * b
                }
                out[k] = sum
            }
        }
        return out
    }

    /// Integrated loudness (LUFS) of a stereo signal at 48 kHz.
    static func integrated(_ l: [Float], _ r: [Float]) -> Double {
        let left = segmentEnergies(l), right = segmentEnergies(r)
        let n = min(left.count, right.count)
        guard n >= 4 else { return -Double.infinity }
        let blockLength = Double(4 * segment)
        var blocks: [Double] = []
        for j in 0...(n - 4) {
            var sum = 0.0
            for k in j..<(j + 4) { sum += left[k] + right[k] }
            blocks.append(sum / blockLength)
        }
        let absolute = blocks.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return -Double.infinity }
        let relative = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relative }
        guard !gated.isEmpty else { return -Double.infinity }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// Taps in each fractional-delay filter.
    static let taps = 32

    /// The filters that find the points a quarter, a half and three quarters of a sample on (in correlation order: filter
    /// `k` run over x from index n gives x at n + 15 + k/4).
    static let phases: [[Float]] = (1...3).map { (k: Int) -> [Float] in
        (0..<LoudnessMeter.taps).map { (p: Int) -> Float in
            let half = LoudnessMeter.taps / 2
            let d = Double(p - (half - 1)) - Double(k) / 4
            let sinc: Double = abs(d) < 1e-12 ? 1 : sin(Double.pi * d) / (Double.pi * d)
            let u = (d + Double(half)) / Double(LoudnessMeter.taps)
            let window: Double = (u >= 0 && u <= 1) ? 0.5 - 0.5 * cos(2 * Double.pi * u) : 0
            return Float(sinc * window)
        }
    }

    /// The largest magnitude of `x` 4× oversampled.
    static func oversampledPeak(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        let pad = [Float](repeating: 0, count: taps)
        let padded = pad + x + pad
        let n = padded.count - taps + 1
        var y = [Float](repeating: 0, count: n)
        for h in phases {
            vDSP_conv(padded, 1, h, 1, &y, 1, vDSP_Length(n), vDSP_Length(taps))
            var m: Float = 0
            vDSP_maxmgv(y, 1, &m, vDSP_Length(n))
            peak = max(peak, m)
        }
        return peak
    }

    /// The true peak (dBTP) of a stereo signal: −240 for silence.
    static func truePeak(_ l: [Float], _ r: [Float]) -> Double {
        let peak = max(oversampledPeak(l), oversampledPeak(r))
        return 20 * log10(max(Double(peak), 1e-12))
    }
}
