import Foundation

/// The mix of a recording (Recorder spec §4): each stem × its gain, summed at its offset. If the summed peak passes
/// −1 dBFS the whole mix is turned down by one gain so the peak sits there: never a pumping limiter, never louder than
/// the sum. Pure arithmetic; the audio layer reads the stems and writes the files.
public enum Mixdown {
    /// −1 dBFS.
    public static let ceiling: Float = 0.891

    /// One stem as it goes into the mix: its two sides, its gain (the layer's volume, 0 when muted) and where its first
    /// frame lands (negative is before the start, and those frames are dropped).
    public struct Stem {
        public var left: [Float]
        public var right: [Float]
        public var gain: Float
        public var offsetFrames: Int

        public init(left: [Float], right: [Float], gain: Float = 1, offsetFrames: Int = 0) {
            self.left = left
            self.right = right
            self.gain = gain
            self.offsetFrames = offsetFrames
        }
    }

    /// The stems summed at their offsets, as long as the latest end, then the one-gain rule; `gain` is what the sum was
    /// multiplied by (1 when it already fits). A stem at gain 0 (muted) is left out: no sound and no length.
    public static func mix(_ stems: [Stem]) -> (left: [Float], right: [Float], gain: Float) {
        var length = 0
        for stem in stems where stem.gain != 0 {
            length = max(length, stem.offsetFrames + max(stem.left.count, stem.right.count))
        }
        guard length > 0 else { return ([], [], 1) }
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        for stem in stems where stem.gain != 0 {
            add(stem.left, gain: stem.gain, at: stem.offsetFrames, into: &left)
            add(stem.right, gain: stem.gain, at: stem.offsetFrames, into: &right)
        }
        let peak = max(Self.peak(left), Self.peak(right))
        guard peak > ceiling else { return (left, right, 1) }
        let gain = ceiling / peak
        scale(&left, by: gain)
        scale(&right, by: gain)
        return (left, right, gain)
    }

    /// The peak of each of `buckets` equal runs of samples, 0…1 (a run louder than full scale shows as full). With
    /// fewer samples than buckets, each bucket shows the sample under it.
    public static func waveform(_ samples: [Float], buckets: Int) -> [Float] {
        guard buckets > 0 else { return [] }
        var bars = [Float](repeating: 0, count: buckets)
        let n = samples.count
        guard n > 0 else { return bars }
        samples.withUnsafeBufferPointer { s in
            for b in 0..<buckets {
                let start = b * n / buckets
                let end = min(n, max(start + 1, (b + 1) * n / buckets))
                var p: Float = 0
                for i in start..<end { p = max(p, abs(s[i])) }
                bars[b] = min(p, 1)
            }
        }
        return bars
    }

    /// Adds `source` × `gain` into `mix` from frame `offset`, dropping what falls before 0 or past the end.
    private static func add(_ source: [Float], gain: Float, at offset: Int, into mix: inout [Float]) {
        let first = max(0, -offset)
        guard first < source.count else { return }
        let start = offset + first
        let count = min(source.count - first, mix.count - start)
        guard count > 0 else { return }
        source.withUnsafeBufferPointer { s in
            mix.withUnsafeMutableBufferPointer { m in
                for i in 0..<count { m[start + i] += s[first + i] * gain }
            }
        }
    }

    private static func peak(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { s in
            var p: Float = 0
            for v in s { p = max(p, abs(v)) }
            return p
        }
    }

    private static func scale(_ samples: inout [Float], by gain: Float) {
        samples.withUnsafeMutableBufferPointer { s in
            for i in 0..<s.count { s[i] *= gain }
        }
    }
}
