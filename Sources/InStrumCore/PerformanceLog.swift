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
///
/// Real-Mac performance (14 Nov 2026): a second table keeps a world's first `entrySeconds` after each entry apart from its
/// steady frames (typical, 95th and 99th percentile, worst, and how many steady frames ran over 33, 50 and 100 ms), with
/// the canvas's time on the main thread a frame (CPU) and the world and sky's step within it, how many times the world was
/// entered, the worst entry frame (stalls included), and what the app was doing during each stall (in front, in the
/// background with its window showing, or its window hidden, when the Mac stops asking for frames). The first table is
/// as it always was, so old and new reports read alike.
public struct PerformanceLog: Sendable {
    /// What the app was doing during a gap between drawn frames.
    public enum StallCause: Sendable, Equatable {
        /// In front, its window showing: a real freeze.
        case active
        /// In the background, its window still showing (it still draws there).
        case background
        /// Its window hidden for part of the gap (covered, minimised, the app hidden, the screen asleep): the Mac stops
        /// asking for frames, so the gap is a pause, not a freeze.
        case hidden
    }

    /// A gap between drawn frames longer than this (seconds) is a stall, not a frame.
    public static let stallSeconds = 1.0
    /// A world's first seconds after it is entered are its entry, kept apart from its steady frames.
    public static let entrySeconds = 3.0
    /// Histograms kept per key: frame time, GPU time, steady frame time, CPU time and step time.
    static let histogramsPerKey = 5
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

        // The second table (real-Mac performance): steady frames, entries, CPU and the stalls' causes.
        /// How many times the world was entered at this quality (launch included).
        public var entries: Int = 0
        /// Frames from `entrySeconds` after an entry on (stalls are not frames).
        public var steadyFrames: Int = 0
        /// The steady frames' median, 95th and 99th percentile and worst, in ms, read like `typical`.
        public var steadyTypical: Double = 0
        public var steadyP95: Double = 0
        public var steadyP99: Double = 0
        public var steadyWorst: Double = 0
        /// Steady frames longer than 33, 50 and 100 ms.
        public var over33: Int = 0
        public var over50: Int = 0
        public var over100: Int = 0
        /// The canvas's main-thread time for a steady frame (ms, 0.1 ms buckets): median and worst; 0 when unknown.
        public var cpuTypical: Double = 0
        public var cpuWorst: Double = 0
        /// The world and sky's step within it (ms): median; 0 when unknown.
        public var stepTypical: Double = 0
        /// Frames (and stalls) in the first `entrySeconds` after an entry, the longest of them (ms, stalls included) and
        /// the longest CPU time among them (ms).
        public var entryFrames: Int = 0
        public var entryWorst: Double = 0
        public var entryCPUWorst: Double = 0
        /// The stalls by what the app was doing.
        public var stallsActive: Int = 0
        public var stallsBackground: Int = 0
        public var stallsHidden: Int = 0

        /// The last drawable's width and height, in pixels.
        public var pixels: (Int, Int) { (pixelsWide, pixelsHigh) }
    }

    fileprivate struct Key: Hashable {
        let world: String
        let quality: QualityLevel
    }

    /// Everything kept for one key. The two histograms are allocated once, with the key's first frame.
    fileprivate struct Entry {
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
        var visits = 0
        var steadyFrames = 0
        var steadyHistogram: [Int]
        var steadyWorst = 0.0
        var over33 = 0, over50 = 0, over100 = 0
        var cpuFrames = 0
        var cpuHistogram: [Int]
        var stepHistogram: [Int]
        var cpuWorst = 0.0
        var entryFrames = 0
        var entryWorst = 0.0
        var entryCPUWorst = 0.0
        var stallsActive = 0, stallsBackground = 0, stallsHidden = 0

        init(key: Key) {
            self.key = key
            frameHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
            gpuHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
            steadyHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
            cpuHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
            stepHistogram = [Int](repeating: 0, count: PerformanceLog.bucketCount)
        }

        mutating func add(frameTime: Double, gpuTime: Double, pixelScale: Double, rescued sawRescue: Bool, pixels: (Int, Int),
                          cpuTime: Double, stepTime: Double, entering: Bool, stallCause: StallCause) {
            if pixelScale.isFinite, pixelScale > 0, pixelScale < minPixelScale { minPixelScale = pixelScale }
            if sawRescue { rescued = true }
            wide = max(0, pixels.0)
            high = max(0, pixels.1)
            let cpu = cpuTime.isFinite && cpuTime > 0 ? cpuTime : 0
            if entering {
                entryFrames += 1
                if frameTime > entryWorst { entryWorst = frameTime }
                if cpu > entryCPUWorst { entryCPUWorst = cpu }
            }
            if frameTime > PerformanceLog.stallSeconds {
                stalls += 1
                if frameTime > longestStall { longestStall = frameTime }
                switch stallCause {
                case .active: stallsActive += 1
                case .background: stallsBackground += 1
                case .hidden: stallsHidden += 1
                }
                return
            }
            frames += 1
            seconds += frameTime
            let bucket = PerformanceLog.bucket(forSeconds: frameTime)
            frameHistogram[bucket] += 1
            if frameTime > worstFrame { worstFrame = frameTime }
            if gpuTime.isFinite, gpuTime > 0 {
                gpuFrames += 1
                gpuHistogram[PerformanceLog.bucket(forSeconds: gpuTime)] += 1
                if gpuTime > worstGPU { worstGPU = gpuTime }
            }
            guard !entering else { return }
            steadyFrames += 1
            steadyHistogram[bucket] += 1
            if frameTime > steadyWorst { steadyWorst = frameTime }
            if frameTime > 0.033 { over33 += 1 }
            if frameTime > 0.050 { over50 += 1 }
            if frameTime > 0.100 { over100 += 1 }
            if cpu > 0 {
                cpuFrames += 1
                cpuHistogram[PerformanceLog.tenthBucket(forSeconds: cpu)] += 1
                if cpu > cpuWorst { cpuWorst = cpu }
                let step = stepTime.isFinite && stepTime > 0 ? stepTime : 0
                stepHistogram[PerformanceLog.tenthBucket(forSeconds: step)] += 1
            }
        }

        func row() -> Row {
            let worstMs = worstFrame * 1000
            let gpuWorstMs = worstGPU * 1000
            var row = Row(
                world: key.world, quality: key.quality, frames: frames, seconds: seconds,
                typical: PerformanceLog.upperEdge(frameHistogram, rank: (frames + 1) / 2, worstMs: worstMs),
                p95: PerformanceLog.upperEdge(frameHistogram, rank: (95 * frames + 99) / 100, worstMs: worstMs),
                worst: worstMs,
                gpuTypical: PerformanceLog.upperEdge(gpuHistogram, rank: (gpuFrames + 1) / 2, worstMs: gpuWorstMs),
                gpuWorst: gpuWorstMs,
                minPixelScale: minPixelScale.isFinite ? minPixelScale : 1,
                rescued: rescued, pixelsWide: wide, pixelsHigh: high,
                stalls: stalls, longestStall: longestStall)
            let steadyWorstMs = steadyWorst * 1000
            row.entries = visits
            row.steadyFrames = steadyFrames
            row.steadyTypical = PerformanceLog.upperEdge(steadyHistogram, rank: (steadyFrames + 1) / 2, worstMs: steadyWorstMs)
            row.steadyP95 = PerformanceLog.upperEdge(steadyHistogram, rank: (95 * steadyFrames + 99) / 100, worstMs: steadyWorstMs)
            row.steadyP99 = PerformanceLog.upperEdge(steadyHistogram, rank: (99 * steadyFrames + 99) / 100, worstMs: steadyWorstMs)
            row.steadyWorst = steadyWorstMs
            row.over33 = over33
            row.over50 = over50
            row.over100 = over100
            let cpuWorstMs = cpuWorst * 1000
            row.cpuTypical = PerformanceLog.upperEdge(cpuHistogram, rank: (cpuFrames + 1) / 2, worstMs: cpuWorstMs * 10) / 10
            row.cpuWorst = cpuWorstMs
            row.stepTypical = PerformanceLog.upperEdge(stepHistogram, rank: (cpuFrames + 1) / 2, worstMs: cpuWorstMs * 10) / 10
            row.entryFrames = entryFrames
            row.entryWorst = entryWorst * 1000
            row.entryCPUWorst = entryCPUWorst * 1000
            row.stallsActive = stallsActive
            row.stallsBackground = stallsBackground
            row.stallsHidden = stallsHidden
            return row
        }
    }

    /// Where each key's entry is.
    private var slots: [Key: Int] = [:]
    private var entries: [Entry] = []

    public init() {}

    /// One drawn frame. `frameTime`: seconds since the previous drawn frame (0 for the first). `gpuTime`: seconds the
    /// graphics chip spent on the last finished frame (0 when unknown). `pixels`: the drawable's width and height.
    /// `cpuTime`: the canvas's seconds on the main thread for this frame, and `stepTime` the world and sky's step within
    /// it (0 when unknown). `entering`: the frame is in the world's first `entrySeconds` after it was entered; `entered`:
    /// it is the first frame of an entry (counted even when its frame time is not, as at launch). `stallCause`: what the
    /// app was doing during the gap before it, should the gap be a stall.
    public mutating func record(world: String, quality: QualityLevel, frameTime: Double, gpuTime: Double,
                                pixelScale: Double, rescued: Bool, pixels: (Int, Int), cpuTime: Double = 0,
                                stepTime: Double = 0, entering: Bool = false, entered: Bool = false,
                                stallCause: StallCause = .active) {
        let usable = frameTime.isFinite && frameTime > 0
        guard usable || entered else { return }
        let key = Key(world: world, quality: quality)
        let slot: Int
        if let found = slots[key] {
            slot = found
        } else {
            slot = entries.count
            slots[key] = slot
            entries.append(Entry(key: key))
        }
        if entered { entries[slot].visits += 1 }
        guard usable else { return }
        entries[slot].add(frameTime: frameTime, gpuTime: gpuTime, pixelScale: pixelScale, rescued: rescued, pixels: pixels,
                          cpuTime: cpuTime, stepTime: stepTime, entering: entering || entered, stallCause: stallCause)
    }

    /// True until a frame has been recorded.
    public var isEmpty: Bool { entries.isEmpty }

    /// How many histogram slots the log holds in all (`histogramsPerKey` per key, `bucketCount` each): fixed once a key
    /// has its first frame, however many frames follow.
    var storedHistogramSlots: Int {
        var total = 0
        for entry in entries {
            total += entry.frameHistogram.count + entry.gpuHistogram.count + entry.steadyHistogram.count
            total += entry.cpuHistogram.count + entry.stepHistogram.count
        }
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
    /// columns), or `No frames drawn yet.` when nothing has been recorded; then a blank line, `steadyHeading`, the second
    /// table (the same rows in the same order) and the `legend`. Ends with a newline; ASCII only.
    public func report(header: [String]) -> String {
        var lines: [String] = []
        for line in header { lines.append(PerformanceLog.asciiOnly(line)) }
        lines.append("")
        let table = rows
        if table.isEmpty {
            lines.append("No frames drawn yet.")
        } else {
            lines += PerformanceLog.aligned([PerformanceLog.columnTitles] + table.map { PerformanceLog.cells(for: $0) })
            lines.append("")
            lines.append(PerformanceLog.steadyHeading)
            lines += PerformanceLog.aligned([PerformanceLog.steadyTitles] + table.map { PerformanceLog.steadyCells(for: $0) })
            lines += PerformanceLog.legend
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A grid's lines, each column padded to its widest cell plus two spaces (the last column not padded).
    static func aligned(_ grid: [[String]]) -> [String] {
        var widths: [Int] = []
        for line in grid {
            for (column, cell) in line.enumerated() {
                if column == widths.count { widths.append(0) }
                widths[column] = max(widths[column], cell.count)
            }
        }
        var out: [String] = []
        for line in grid {
            var text = ""
            for (column, cell) in line.enumerated() {
                text += cell
                if column < line.count - 1 { text += String(repeating: " ", count: widths[column] - cell.count + 2) }
            }
            out.append(text)
        }
        return out
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

    /// The 0.1 ms bucket a CPU time in seconds falls in: 0 for 0 to 0.1 ms and so on, the overflow bucket from 20 ms.
    /// (`upperEdge` then reads tenths of a millisecond.)
    static func tenthBucket(forSeconds seconds: Double) -> Int {
        let tenths = seconds * 10_000 + 1e-6
        return tenths >= Double(overflowBucket) ? overflowBucket : max(0, Int(tenths))
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

    /// The line over the second table.
    static let steadyHeading = "Steady frames (from \(Int(entrySeconds)) s after entering a world), CPU, entries and stalls:"

    static let steadyTitles: [String] = ["World", "Quality", "Entries", "Typical", "95%", "99%", "Worst", "Over 33/50/100",
                                         "CPU typ", "CPU worst", "Step typ", "Entry worst", "Entry CPU", "Stalls act/bg/hid"]

    /// The lines under the second table.
    static let legend: [String] = [
        "Entry: a world's first \(Int(entrySeconds)) s after it is entered (Entry worst includes stalls). Over: steady frames longer than 33, 50, 100 ms.",
        "CPU: the main thread's time for a frame; Step: the world and sky's share of it. Stalls: gaps over 1 s, with the app",
        "in front (act), in the background with its window showing (bg), or its window hidden (hid: the Mac pauses drawing).",
    ]

    /// Tenths of a millisecond, as "2.4 ms".
    private static func tenths(_ value: Double) -> String {
        let t = whole(value * 10, cap: 10_000_000)
        return "\(t / 10).\(t % 10) ms"
    }

    private static func steadyCells(for row: Row) -> [String] {
        var out: [String] = []
        out.append(asciiOnly(row.world))
        out.append(qualityName(row.quality))
        out.append("\(row.entries)")
        let steady = row.steadyFrames > 0
        out.append(steady ? milliseconds(row.steadyTypical) : "-")
        out.append(steady ? milliseconds(row.steadyP95) : "-")
        out.append(steady ? milliseconds(row.steadyP99) : "-")
        out.append(steady ? milliseconds(row.steadyWorst) : "-")
        out.append("\(row.over33)/\(row.over50)/\(row.over100)")
        let cpu = row.cpuWorst > 0
        out.append(cpu ? tenths(row.cpuTypical) : "-")
        out.append(cpu ? tenths(row.cpuWorst) : "-")
        out.append(cpu ? tenths(row.stepTypical) : "-")
        out.append(row.entryFrames > 0 ? milliseconds(row.entryWorst) : "-")
        out.append(row.entryCPUWorst > 0 ? tenths(row.entryCPUWorst) : "-")
        out.append("\(row.stallsActive)/\(row.stallsBackground)/\(row.stallsHidden)")
        return out
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
