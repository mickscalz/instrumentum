import Foundation

/// How the picture ran on this Mac, by world and quality, for Help > Copy Performance Report: the owner pastes the
/// report into a chat, so the visuals can be tuned for a machine nobody else sees.
///
/// The canvas records every drawn frame. Per (world, quality) the log keeps fixed storage that never grows with the
/// number of frames: counts, two histograms (frame time and GPU time, in 1 ms buckets from 0 to 199 ms plus one bucket
/// for everything longer), the worst times, the smallest pixel scale, whether the safety net ever stepped in, the last
/// drawable size and the seconds watched. Recording a frame after a key's first allocates nothing.
///
/// A gap between drawn frames over `stallSeconds` is a pause or a freeze, not a frame: it is counted as a stall (and the
/// longest kept) but is not in the histogram, the frame count, the worst times or the seconds watched. Zero, negative and
/// non-finite frame times are ignored altogether (a frame time of exactly 0 is the very first frame); a GPU time that is
/// not above 0 and finite is "unknown" (the frame still counts); a pixel scale that is not above 0 and finite is ignored.
public struct PerformanceLog: Sendable {
    /// A gap between drawn frames longer than this (seconds) is a stall, not a frame.
    public static let stallSeconds = 1.0
    /// The histograms' last bucket holds everything from 200 ms up.
    static let overflowBucket = 200
    /// 1 ms buckets for 0 to 199 ms, plus the overflow bucket.
    static let bucketCount = overflowBucket + 1

    /// One line of the report's table.
    public struct Row: Equatable, Sendable {
        public let world: String
        public let quality: QualityLevel
        /// Frames drawn (stalls are not frames).
        public let frames: Int
        /// Seconds watched: the frame times added up (stalls are not watching).
        public let seconds: Double
        /// The median frame time in ms: the upper edge of the 1 ms bucket holding the middle frame (the worst frame's
        /// time when that frame took 200 ms or more).
        public let typical: Double
        /// The 95th percentile frame time in ms, read the same way.
        public let p95: Double
        /// The longest frame time in ms (among frames of 1 s or less).
        public let worst: Double
        /// The median GPU time in ms, read like `typical`; 0 when no GPU times were recorded.
        public let gpuTypical: Double
        /// The longest GPU time in ms (among frames of 1 s or less); 0 when no GPU times were recorded.
        public let gpuWorst: Double
        /// The smallest share of the quality's pixels drawn (1 = all of them).
        public let minPixelScale: Double
        /// True if the GPU safety net ever stepped in.
        public let rescued: Bool
        /// The last drawable's width and height, in pixels.
        public let pixelsWide: Int
        public let pixelsHigh: Int
        /// Gaps over `stallSeconds`, and the longest of them in seconds.
        public let stalls: Int
        public let longestStall: Double

        /// The last drawable's width and height, in pixels.
        public var pixels: (Int, Int) { (pixelsWide, pixelsHigh) }
    }

    private struct Key: Hashable {
        let world: String
        let quality: QualityLevel
    }

    /// Everything kept for one key. The two histograms are allocated once, with the key's first frame.
    private struct Entry {
        let key: Key
        var frames = 0
        var seconds = 0.0
        var frameHistogram: [Int]
        var gpuFrames = 0
        var gpuHistogram: [Int]
        var worstFrame = 0.0
        var worstGPU = 0.0
        var minPixelScale = Double.infinity
        var rescued = false
        var wide = 0
        var high = 0
        var stalls = 0
        var longestStall = 0.0

        init(key: Key) {
            self.key = key
            frameHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
            gpuHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
        }

        mutating func add(frameTime: Double, gpuTime: Double, pixelScale: Double, rescued sawRescue: Bool, pixels: (Int, Int)) {
            if pixelScale.isFinite, pixelScale > 0, pixelScale < minPixelScale { minPixelScale = pixelScale }
            if sawRescue { rescued = true }
            wide = max(0, pixels.0)
            high = max(0, pixels.1)
            if frameTime > PerformanceLog.stallSeconds {
                stalls += 1
                if frameTime > longestStall { longestStall = frameTime }
                return
            }
            frames += 1
            seconds += frameTime
            frameHistogram[PerformanceLog.bucket(forSeconds: frameTime)] += 1
            if frameTime > worstFrame { worstFrame = frameTime }
            if gpuTime.isFinite, gpuTime > 0 {
                gpuFrames += 1
                gpuHistogram[PerformanceLog.bucket(forSeconds: gpuTime)] += 1
                if gpuTime > worstGPU { worstGPU = gpuTime }
            }
        }

        func row() -> Row {
            let worstMs = worstFrame * 1000
            let gpuWorstMs = worstGPU * 1000
            return Row(
                world: key.world, quality: key.quality, frames: frames, seconds: seconds,
                typical: PerformanceLog.upperEdge(frameHistogram, rank: (frames + 1) / 2, worstMs: worstMs),
                p95: PerformanceLog.upperEdge(frameHistogram, rank: (95 * frames + 99) / 100, worstMs: worstMs),
                worst: worstMs,
                gpuTypical: PerformanceLog.upperEdge(gpuHistogram, rank: (gpuFrames + 1) / 2, worstMs: gpuWorstMs),
                gpuWorst: gpuWorstMs,
                minPixelScale: minPixelScale.isFinite ? minPixelScale : 1,
                rescued: rescued, pixelsWide: wide, pixelsHigh: high,
                stalls: stalls, longestStall: longestStall)
        }
    }

    /// Where each key's entry is.
    private var slots: [Key: Int] = [:]
    private var entries: [Entry] = []

    public init() {}

    /// One drawn frame. `frameTime`: seconds since the previous drawn frame (0 for the first). `gpuTime`: seconds the
    /// graphics chip spent on the last finished frame (0 when unknown). `pixels`: the drawable's width and height.
    public mutating func record(world: String, quality: QualityLevel, frameTime: Double, gpuTime: Double,
                                pixelScale: Double, rescued: Bool, pixels: (Int, Int)) {
        guard frameTime.isFinite, frameTime > 0 else { return }
        let key = Key(world: world, quality: quality)
        let slot: Int
        if let found = slots[key] {
            slot = found
        } else {
            slot = entries.count
            slots[key] = slot
            entries.append(Entry(key: key))
        }
        entries[slot].add(frameTime: frameTime, gpuTime: gpuTime, pixelScale: pixelScale, rescued: rescued, pixels: pixels)
    }

    /// True until a frame has been recorded.
    public var isEmpty: Bool { entries.isEmpty }

    /// How many histogram slots the log holds in all (two per key, `bucketCount` each): fixed once a key has its first
    /// frame, however many frames follow.
    var storedHistogramSlots: Int {
        var total = 0
        for entry in entries { total += entry.frameHistogram.count + entry.gpuHistogram.count }
        return total
    }

    /// The report's table rows, most-watched first (ties by world, then quality).
    public var rows: [Row] {
        var out: [Row] = []
        out.reserveCapacity(entries.count)
        for entry in entries { out.append(entry.row()) }
        out.sort { (a: Row, b: Row) -> Bool in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            if a.world != b.world { return a.world < b.world }
            return PerformanceLog.rank(of: a.quality) < PerformanceLog.rank(of: b.quality)
        }
        return out
    }

    /// The report: the header lines as given, a blank line, then the table (a title line and one line per row, aligned in
    /// columns), or `No frames drawn yet.` when nothing has been recorded. Ends with a newline; ASCII only.
    public func report(header: [String]) -> String {
        var lines: [String] = []
        for line in header { lines.append(PerformanceLog.asciiOnly(line)) }
        lines.append("")
        let table = rows
        if table.isEmpty {
            lines.append("No frames drawn yet.")
        } else {
            var grid: [[String]] = [PerformanceLog.columnTitles]
            for row in table { grid.append(PerformanceLog.cells(for: row)) }
            var widths = [Int](repeating: 0, count: PerformanceLog.columnTitles.count)
            for line in grid {
                for (column, cell) in line.enumerated() { widths[column] = max(widths[column], cell.count) }
            }
            for line in grid {
                var text = ""
                for (column, cell) in line.enumerated() {
                    text += cell
                    if column < line.count - 1 { text += String(repeating: " ", count: widths[column] - cell.count + 2) }
                }
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` with everything outside the printable ASCII range 0x20...0x7E (a tab, a line break, an accent, an emoji)
    /// replaced by "?", one for each Unicode scalar.
    public static func asciiOnly(_ text: String) -> String {
        let characters: [Character] = text.unicodeScalars.map { (scalar: Unicode.Scalar) -> Character in
            (0x20...0x7E).contains(scalar.value) ? Character(scalar) : Character("?")
        }
        return String(characters)
    }

    // MARK: - Reading the histograms

    /// The 1 ms bucket a time in seconds falls in: 0 for 0 to 1 ms, 1 for 1 to 2 ms and so on, the overflow bucket from
    /// 200 ms. A nanosecond of slack keeps 0.016 s, which can come out a hair under 16 ms, from landing a bucket low.
    static func bucket(forSeconds seconds: Double) -> Int {
        let ms = seconds * 1000 + 1e-6
        return ms >= Double(overflowBucket) ? overflowBucket : Int(ms)
    }

    /// The upper edge (ms) of the bucket holding the `rank`-th smallest time (counting from 1); `worstMs` stands in for
    /// the overflow bucket, whose frames are all at least 200 ms. 0 when there is no such time.
    static func upperEdge(_ histogram: [Int], rank: Int, worstMs: Double) -> Double {
        guard rank > 0 else { return 0 }
        var seen = 0
        for (bucket, count) in histogram.enumerated() {
            seen += count
            if seen >= rank {
                return bucket >= overflowBucket ? max(Double(overflowBucket), worstMs) : Double(bucket + 1)
            }
        }
        return worstMs
    }

    // MARK: - The table

    static let columnTitles: [String] = ["World", "Quality", "Pixels", "Min", "Typical", "95%", "Worst",
                                         "GPU typ", "GPU worst", "Scale", "Net", "Stalls"]

    /// The names the report gives the qualities, as the app's quality setting shows them.
    static func qualityName(_ quality: QualityLevel) -> String {
        switch quality {
        case .lite: return "Smooth"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }

    /// Smooth, High, Ultra: the order rows of one world come in.
    private static func rank(of quality: QualityLevel) -> Int {
        switch quality {
        case .lite: return 0
        case .high: return 1
        case .ultra: return 2
        }
    }

    /// A number as a whole, kept within 0...`cap` so a wild value can never trap.
    private static func whole(_ value: Double, cap: Double = 1_000_000_000) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), cap).rounded())
    }

    private static func milliseconds(_ value: Double) -> String {
        "\(whole(value)) ms"
    }

    private static func cells(for row: Row) -> [String] {
        var out: [String] = []
        out.append(asciiOnly(row.world))
        out.append(qualityName(row.quality))
        out.append("\(row.pixelsWide)x\(row.pixelsHigh)")
        out.append("\(whole(row.seconds / 60))")
        out.append(milliseconds(row.typical))
        out.append(milliseconds(row.p95))
        out.append(milliseconds(row.worst))
        out.append(row.gpuTypical > 0 ? milliseconds(row.gpuTypical) : "-")
        out.append(row.gpuWorst > 0 ? milliseconds(row.gpuWorst) : "-")
        out.append("\(whole(row.minPixelScale * 100, cap: 100_000))%")
        out.append(row.rescued ? "yes" : "-")
        if row.stalls == 0 {
            out.append("0")
        } else {
            let tenths = whole(min(row.longestStall, 1_000_000) * 10)
            out.append("\(row.stalls) (longest \(tenths / 10).\(tenths % 10) s)")
        }
        return out
    }
}
