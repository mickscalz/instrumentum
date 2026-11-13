import XCTest
@testable import InStrumCore

/// The performance log behind Help > Copy Performance Report. Every expected number was worked out on a Python mirror of
/// `PerformanceLog` that reads the histograms the same way (1 ms buckets, the median and the 95th percentile as the upper
/// edge of the bucket holding that rank).
final class PerformanceLogTests: XCTestCase {
    /// One frame, with everything but the frame time defaulted.
    private func put(_ log: inout PerformanceLog, _ frameTime: Double, world: String = "w", quality: QualityLevel = .lite,
                     gpu: Double = 0, scale: Double = 1, rescued: Bool = false, pixels: (Int, Int) = (1280, 800)) {
        log.record(world: world, quality: quality, frameTime: frameTime, gpuTime: gpu, pixelScale: scale,
                   rescued: rescued, pixels: pixels)
    }

    private func onlyRow(_ log: PerformanceLog, file: StaticString = #filePath, line: UInt = #line) -> PerformanceLog.Row {
        XCTAssertEqual(log.rows.count, 1, file: file, line: line)
        return log.rows[0]
    }

    // MARK: - Median, 95% and worst

    func testMedianAndNinetyFifthFromKnownFrameTimes() {
        // 1.5 ms, 2.5 ms ... 100.5 ms: one frame in each of the buckets 1 to 100.
        var log = PerformanceLog()
        for i in 1...100 { put(&log, Double(i) / 1000 + 0.0005) }
        let row = onlyRow(log)
        XCTAssertEqual(row.frames, 100)
        XCTAssertEqual(row.seconds, 5.1, accuracy: 1e-6)
        XCTAssertEqual(row.typical, 51, "the 50th frame is in bucket 50, whose upper edge is 51 ms")
        XCTAssertEqual(row.p95, 96, "the 95th frame is in bucket 95, whose upper edge is 96 ms")
        XCTAssertEqual(row.worst, 100.5, accuracy: 1e-6)
    }

    func testTheMiddleFrameOfAnOddAndAnEvenNumber() {
        var odd = PerformanceLog()
        for ms in [30.5, 10.5, 20.5] { put(&odd, ms / 1000) }
        XCTAssertEqual(onlyRow(odd).typical, 21, "the middle of three is the 20.5 ms frame")
        var even = PerformanceLog()
        for ms in [10.5, 20.5, 30.5, 40.5] { put(&even, ms / 1000) }
        XCTAssertEqual(onlyRow(even).typical, 21, "the lower of the two middle frames")
        var one = PerformanceLog()
        put(&one, 0.0165)
        XCTAssertEqual(onlyRow(one).typical, 17)
        XCTAssertEqual(onlyRow(one).p95, 17)
    }

    func testSixtyFramesASecondReadsSeventeenMilliseconds() {
        var log = PerformanceLog()
        for _ in 0..<600 { put(&log, 1.0 / 60) }
        let row = onlyRow(log)
        XCTAssertEqual(row.typical, 17)
        XCTAssertEqual(row.p95, 17)
        XCTAssertEqual(row.seconds, 10, accuracy: 1e-6)
    }

    func testAFrameOf200MillisecondsOrMoreStandsForItself() {
        var log = PerformanceLog()
        put(&log, 0.1995)
        XCTAssertEqual(onlyRow(log).typical, 200, "bucket 199's upper edge")
        var slow = PerformanceLog()
        put(&slow, 0.25)
        let row = onlyRow(slow)
        XCTAssertEqual(row.typical, 250, accuracy: 1e-6, "the overflow bucket reads as the worst frame")
        XCTAssertEqual(row.p95, 250, accuracy: 1e-6)
        XCTAssertEqual(row.worst, 250, accuracy: 1e-6)
    }

    func testWorstFrameAndWorstGPUAmongFramesUpToASecond() {
        var log = PerformanceLog()
        put(&log, 0.016, gpu: 0.010)
        put(&log, 0.9, gpu: 0.8)
        put(&log, 0.02, gpu: 0.012)
        put(&log, 3.0, gpu: 2.5)   // a stall: neither its time nor its GPU time counts
        let row = onlyRow(log)
        XCTAssertEqual(row.worst, 900, accuracy: 1e-6)
        XCTAssertEqual(row.gpuWorst, 800, accuracy: 1e-6)
        XCTAssertEqual(row.frames, 3)
    }

    func testGPUTimesAreReadLikeFrameTimesAndOnlyWhenKnown() {
        var log = PerformanceLog()
        put(&log, 0.016)   // no GPU time known
        XCTAssertEqual(onlyRow(log).gpuTypical, 0)
        XCTAssertEqual(onlyRow(log).gpuWorst, 0)
        for _ in 0..<9 { put(&log, 0.016, gpu: 0.0135) }
        put(&log, 0.016, gpu: 0.055)
        let row = onlyRow(log)
        XCTAssertEqual(row.frames, 11)
        XCTAssertEqual(row.gpuTypical, 14, "ten GPU times, the middle in bucket 13")
        XCTAssertEqual(row.gpuWorst, 55, accuracy: 1e-6)
    }

    // MARK: - Keys

    func testSeparateRowsPerWorldAndPerQuality() {
        var log = PerformanceLog()
        for _ in 0..<5 { put(&log, 0.016, world: "a", quality: .lite) }
        for _ in 0..<4 { put(&log, 0.016, world: "a", quality: .high) }
        for _ in 0..<3 { put(&log, 0.016, world: "b", quality: .lite) }
        for _ in 0..<2 { put(&log, 0.016, world: "b", quality: .ultra) }
        XCTAssertEqual(log.rows.count, 4)
        let rows = log.rows
        func frames(_ world: String, _ quality: QualityLevel) -> Int? {
            rows.first(where: { $0.world == world && $0.quality == quality })?.frames
        }
        XCTAssertEqual(frames("a", .lite), 5)
        XCTAssertEqual(frames("a", .high), 4)
        XCTAssertEqual(frames("b", .lite), 3)
        XCTAssertEqual(frames("b", .ultra), 2)
        XCTAssertNil(frames("a", .ultra))
    }

    // MARK: - Stalls

    func testAThreeSecondGapIsAStallAndNotAFrame() {
        var log = PerformanceLog()
        for _ in 0..<10 { put(&log, 0.016) }
        put(&log, 3.0)
        let row = onlyRow(log)
        XCTAssertEqual(row.frames, 10)
        XCTAssertEqual(row.stalls, 1)
        XCTAssertEqual(row.longestStall, 3.0, accuracy: 1e-9)
        XCTAssertEqual(row.worst, 16, accuracy: 1e-6, "the stall is not the worst frame")
        XCTAssertEqual(row.typical, 17)
        XCTAssertEqual(row.p95, 17)
        XCTAssertEqual(row.seconds, 0.16, accuracy: 1e-9, "a pause is not time watched")
    }

    func testTheLongestStallIsKeptAndAFrameOfExactlyASecondIsStillAFrame() {
        var log = PerformanceLog()
        put(&log, 2.5)
        put(&log, 7.25)
        put(&log, 1.5)
        put(&log, 1.0)
        let row = onlyRow(log)
        XCTAssertEqual(row.stalls, 3)
        XCTAssertEqual(row.longestStall, 7.25, accuracy: 1e-9)
        XCTAssertEqual(row.frames, 1, "exactly 1 s is a very slow frame, not a stall")
        XCTAssertEqual(row.worst, 1000, accuracy: 1e-6)
        XCTAssertFalse(log.isEmpty, "a log that has only seen stalls still has its row")
    }

    // MARK: - Values that are ignored

    func testZeroNegativeAndNotANumberFrameTimesAreIgnored() {
        var log = PerformanceLog()
        for bad in [0.0, -0.016, -1, Double.nan, Double.infinity, -Double.infinity] { put(&log, bad) }
        XCTAssertTrue(log.isEmpty)
        XCTAssertTrue(log.rows.isEmpty)
        put(&log, 0.016)
        for bad in [0.0, -0.016, Double.nan, Double.infinity] { put(&log, bad, gpu: 0.01, scale: 0.1, rescued: true, pixels: (1, 1)) }
        let row = onlyRow(log)
        XCTAssertEqual(row.frames, 1)
        XCTAssertEqual(row.stalls, 0)
        XCTAssertEqual(row.minPixelScale, 1, "an ignored frame leaves nothing behind")
        XCTAssertFalse(row.rescued)
        XCTAssertEqual(row.gpuWorst, 0)
        XCTAssertTrue(row.pixels == (1280, 800))
    }

    func testAnUnusableGPUTimeOrPixelScaleIsIgnoredButTheFrameCounts() {
        var log = PerformanceLog()
        put(&log, 0.016, gpu: .nan, scale: .nan)
        put(&log, 0.016, gpu: -0.01, scale: -0.5)
        put(&log, 0.016, gpu: .infinity, scale: .infinity)
        put(&log, 0.016, gpu: 0, scale: 0)
        let row = onlyRow(log)
        XCTAssertEqual(row.frames, 4)
        XCTAssertEqual(row.gpuTypical, 0)
        XCTAssertEqual(row.gpuWorst, 0)
        XCTAssertEqual(row.minPixelScale, 1)
    }

    // MARK: - What sticks

    func testTheSmallestPixelScaleAndTheSafetyNetAreSticky() {
        var log = PerformanceLog()
        put(&log, 0.016, scale: 1, rescued: false)
        XCTAssertEqual(onlyRow(log).minPixelScale, 1)
        XCTAssertFalse(onlyRow(log).rescued)
        put(&log, 0.016, scale: 0.5, rescued: true)
        put(&log, 0.016, scale: 0.8, rescued: false)
        put(&log, 0.016, scale: 1, rescued: false)
        let row = onlyRow(log)
        XCTAssertEqual(row.minPixelScale, 0.5, accuracy: 1e-12, "it never grows back in the log")
        XCTAssertTrue(row.rescued, "once the net has stepped in, the row says so")
    }

    func testTheLastDrawableSizeIsKept() {
        var log = PerformanceLog()
        put(&log, 0.016, pixels: (1280, 800))
        put(&log, 0.016, pixels: (1600, 1000))
        XCTAssertTrue(onlyRow(log).pixels == (1600, 1000))
        put(&log, 0.016, world: "other", pixels: (640, 400))
        XCTAssertEqual(log.rows.count, 2)
        guard let w = log.rows.first(where: { $0.world == "w" }), let other = log.rows.first(where: { $0.world == "other" }) else {
            return XCTFail("both worlds should have a row")
        }
        XCTAssertTrue(w.pixels == (1600, 1000), "each key keeps its own")
        XCTAssertTrue(other.pixels == (640, 400))
    }

    // MARK: - Order

    func testRowsComeMostWatchedFirstThenByWorldThenQuality() {
        var log = PerformanceLog()
        // The same frames in the same order add up to exactly the same seconds, so these four tie.
        let tied: [(String, QualityLevel)] = [("b", .lite), ("a", .high), ("a", .lite), ("a", .ultra)]
        for (world, quality) in tied {
            for _ in 0..<10 { put(&log, 0.02, world: world, quality: quality) }
        }
        for _ in 0..<30 { put(&log, 0.02, world: "z", quality: .high) }   // the most watched
        for _ in 0..<2 { put(&log, 0.02, world: "a", quality: .high) }    // a little more for one of the tie
        let order = log.rows.map { "\($0.world)-\(PerformanceLog.qualityName($0.quality))" }
        XCTAssertEqual(order, ["z-High", "a-High", "a-Smooth", "a-Ultra", "b-Smooth"])
        let seconds = log.rows.map { $0.seconds }
        XCTAssertEqual(seconds, seconds.sorted(by: >))
    }

    // MARK: - The report

    private static let sampleHeader = ["In Strum Meants performance report", "Build 1.2 (345)"]

    /// The example from the feature's spec, made with 43,200 and 5,600 frames.
    private func sampleLog() -> PerformanceLog {
        var log = PerformanceLog()
        // Twelve minutes of Supercell Sky at Smooth: 600 frames to a round (559 at 16.5 ms, 40 at 23.5 ms, one at 61 ms).
        for _ in 0..<72 {
            for _ in 0..<559 { put(&log, 0.0165, world: "supercell-sky", quality: .lite, gpu: 0.0135) }
            for _ in 0..<40 { put(&log, 0.0235, world: "supercell-sky", quality: .lite, gpu: 0.0135) }
            put(&log, 0.061, world: "supercell-sky", quality: .lite, gpu: 0.055)
        }
        // Three minutes of Volcano Rim at High, the safety net in from the second round: 100 frames to a round (94 at
        // 32.5 ms, five at 40.5 ms, one at 120 ms), then two stalls.
        for round in 0..<56 {
            let scale = round == 0 ? 1.0 : 0.5
            let net = round > 0
            for _ in 0..<94 { put(&log, 0.0325, world: "volcano-rim", quality: .high, gpu: 0.029, scale: scale, rescued: net, pixels: (1600, 1000)) }
            for _ in 0..<5 { put(&log, 0.0405, world: "volcano-rim", quality: .high, gpu: 0.029, scale: scale, rescued: net, pixels: (1600, 1000)) }
            put(&log, 0.120, world: "volcano-rim", quality: .high, gpu: 0.110, scale: scale, rescued: net, pixels: (1600, 1000))
        }
        put(&log, 3.2, world: "volcano-rim", quality: .high, scale: 0.5, rescued: true, pixels: (1600, 1000))
        put(&log, 1.5, world: "volcano-rim", quality: .high, scale: 0.5, rescued: true, pixels: (1600, 1000))
        return log
    }

    /// The sample report, line by line: the first table as it always was, then the second (real-Mac performance). The
    /// sample's frames carry no CPU time and no entries, so every frame is steady and those columns read as dashes; the
    /// GPU's typical frame is repeated beside the CPU's.
    static let sampleReport: [String] = [
        "In Strum Meants performance report",
        "Build 1.2 (345)",
        "",
        "World          Quality  Pixels     Min  Typical  95%    Worst   GPU typ  GPU worst  Scale  Net  Stalls",
        "supercell-sky  Smooth   1280x800   12   17 ms    24 ms  61 ms   14 ms    55 ms      100%   -    0",
        "volcano-rim    High     1600x1000  3    33 ms    41 ms  120 ms  30 ms    110 ms     50%    yes  2 (longest 3.2 s)",
        "",
        "Steady frames (from 3 s after entering a world), CPU, entries and stalls:",
        "World          Quality  Entries  Typical  95%    99%    Worst   Over 33/50/100  GPU typ  CPU typ  CPU worst  Step typ  Entry worst  Entry CPU  Stalls act/bg/hid",
        "supercell-sky  Smooth   0        17 ms    24 ms  24 ms  61 ms   72/72/0         14 ms    -        -          -         -            -          0/0/0",
        "volcano-rim    High     0        33 ms    41 ms  41 ms  120 ms  336/56/56       30 ms    -        -          -         -            -          2/0/0",
    ] + PerformanceLog.legend

    func testTheSampleReportIsExactlyThis() {
        let log = sampleLog()
        let rows = log.rows
        XCTAssertEqual(rows.map { $0.world }, ["supercell-sky", "volcano-rim"])
        XCTAssertEqual(rows[0].frames, 43_200)
        XCTAssertEqual(rows[1].frames, 5_600)
        XCTAssertEqual(rows[1].stalls, 2)
        XCTAssertEqual(rows[1].longestStall, 3.2, accuracy: 1e-9)
        let report = log.report(header: Self.sampleHeader)
        XCTAssertEqual(report, Self.sampleReport.joined(separator: "\n") + "\n")
    }

    func testTheReportHasOneLinePerRowPlusTheHeaderIsAsciiAndEndsWithANewline() {
        let log = sampleLog()
        let report = log.report(header: Self.sampleHeader)
        XCTAssertTrue(report.hasSuffix("\n"))
        XCTAssertFalse(report.hasSuffix("\n\n"))
        XCTAssertTrue(report.unicodeScalars.allSatisfy { $0.value < 0x80 }, "ASCII only")
        var lines = report.components(separatedBy: "\n")
        let last = lines.removeLast()
        XCTAssertEqual(last, "", "nothing after the last newline")
        // the header, a blank line, the title line, one line for each of the two rows; then a blank line, the second
        // table's heading, its title line, a line for each row, and the legend
        XCTAssertEqual(lines.count, Self.sampleHeader.count + 1 + 1 + log.rows.count + 1 + 1 + 1 + log.rows.count
                                    + PerformanceLog.legend.count)
        XCTAssertEqual(Array(lines[0..<Self.sampleHeader.count]), Self.sampleHeader)
        XCTAssertEqual(lines[Self.sampleHeader.count], "")
        XCTAssertTrue(lines[Self.sampleHeader.count + 1].hasPrefix("World "))
        XCTAssertFalse(lines.contains { $0.hasSuffix(" ") }, "no trailing spaces")
    }

    func testTheColumnsLineUpWhateverTheWorldNames() {
        var log = PerformanceLog()
        for _ in 0..<10 { put(&log, 0.0165, world: "a-very-long-world-name-indeed", quality: .ultra, pixels: (2560, 1600)) }
        for _ in 0..<5 { put(&log, 0.0165, world: "x", quality: .lite) }
        let lines = log.report(header: []).components(separatedBy: "\n")
        // an empty header gives the blank line, then the title and the rows
        XCTAssertEqual(lines[0], "")
        let title = lines[1], first = lines[2], second = lines[3]
        for word in ["Quality", "Pixels", "Min", "Typical", "95%", "Worst", "GPU typ", "GPU worst", "Scale", "Net", "Stalls"] {
            XCTAssertNotNil(title.range(of: word), word)
        }
        let column = title.range(of: "Quality")!.lowerBound.utf16Offset(in: title)
        XCTAssertEqual(first.dropFirst(column).prefix(5), "Ultra")
        XCTAssertEqual(second.dropFirst(column).prefix(6), "Smooth")
        let pixels = title.range(of: "Pixels")!.lowerBound.utf16Offset(in: title)
        XCTAssertEqual(first.dropFirst(pixels).prefix(9), "2560x1600")
        XCTAssertEqual(second.dropFirst(pixels).prefix(8), "1280x800")
        XCTAssertEqual(first.hasPrefix("a-very-long-world-name-indeed  Ultra"), true)
    }

    func testRowsWithNoGPUTimesAndNoStallsReadAsDashes() {
        var log = PerformanceLog()
        for _ in 0..<10 { put(&log, 0.0165, world: "w") }
        let lines = log.report(header: []).components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "World  Quality  Pixels    Min  Typical  95%    Worst  GPU typ  GPU worst  Scale  Net  Stalls")
        XCTAssertEqual(lines[2], "w      Smooth   1280x800  0    17 ms    17 ms  17 ms  -        -          100%   -    0")
    }

    func testAnEmptyLogSaysNoFramesDrawnYet() {
        let log = PerformanceLog()
        XCTAssertTrue(log.isEmpty)
        XCTAssertTrue(log.rows.isEmpty)
        XCTAssertEqual(log.report(header: ["Head", "Line"]), "Head\nLine\n\nNo frames drawn yet.\n")
        XCTAssertEqual(log.report(header: []), "\nNo frames drawn yet.\n")
    }

    func testNonASCIIInTheHeaderAndTheWorldNameBecomesAQuestionMark() {
        var log = PerformanceLog()
        put(&log, 0.0165, world: "w\u{00FC}rld")
        let report = log.report(header: ["Caf\u{00E9} \u{1F600} tab\there", "line\nbreak"])
        XCTAssertTrue(report.unicodeScalars.allSatisfy { $0.value < 0x80 })
        XCTAssertTrue(report.hasPrefix("Caf? ? tab?here\nline?break\n\n"), report)
        XCTAssertNotNil(report.range(of: "w?rld "))
        XCTAssertEqual(PerformanceLog.asciiOnly("plain ~ text"), "plain ~ text")
        XCTAssertEqual(PerformanceLog.asciiOnly("\u{7F}\u{1F}\u{20}\u{7E}"), "?? ~")
    }

    // MARK: - Fixed storage

    func testRecordingAHundredThousandFramesDoesNotGrowTheStorage() {
        var log = PerformanceLog()
        put(&log, 0.016, world: "a", quality: .lite, gpu: 0.01)
        put(&log, 0.016, world: "b", quality: .high, gpu: 0.01)
        let slots = log.storedHistogramSlots
        XCTAssertEqual(slots, 2 * 5 * PerformanceLog.bucketCount,
                       "two keys; a frame, a GPU, a steady frame, a CPU and a step histogram of 201 buckets each")
        XCTAssertEqual(PerformanceLog.histogramsPerKey, 5)
        XCTAssertEqual(PerformanceLog.bucketCount, 201)
        for i in 0..<100_000 {
            // every kind of frame: fast, slow, past 200 ms, a stall, with and without a GPU time
            let frameTime: Double
            switch i % 5 {
            case 0: frameTime = 0.016
            case 1: frameTime = 0.045
            case 2: frameTime = 0.35
            case 3: frameTime = 2.0
            default: frameTime = 0.0165
            }
            put(&log, frameTime, world: i % 2 == 0 ? "a" : "b", quality: i % 2 == 0 ? .lite : .high,
                gpu: i % 3 == 0 ? 0 : 0.012, scale: 0.5)
        }
        XCTAssertEqual(log.storedHistogramSlots, slots, "the histograms stay the size they were")
        XCTAssertEqual(log.rows.count, 2)
        XCTAssertEqual(log.rows.map { $0.frames + $0.stalls }.reduce(0, +), 100_002)
        XCTAssertEqual(log.rows.map { $0.stalls }.reduce(0, +), 20_000)
    }
}
