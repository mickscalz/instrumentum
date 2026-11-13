import XCTest
@testable import InStrumCore

/// The performance report's second table (real-Mac performance, 14 Nov): a world's entries kept apart from its steady
/// frames, the steady frames' 99th percentile and how many ran long, the canvas's main-thread time a frame, and what the
/// app was doing during each stall. Every expected number was worked out by hand from the 1 ms (and 0.1 ms) buckets.
final class PerformanceLogSteadyTests: XCTestCase {
    private func put(_ log: inout PerformanceLog, _ frameTime: Double, world: String = "w", cpu: Double = 0, step: Double = 0,
                     entering: Bool = false, entered: Bool = false, cause: PerformanceLog.StallCause = .active) {
        log.record(world: world, quality: .lite, frameTime: frameTime, gpuTime: 0.004, pixelScale: 1, rescued: false,
                   pixels: (1264, 790), cpuTime: cpu, stepTime: step, entering: entering, entered: entered, stallCause: cause)
    }

    /// A launch, two seconds of entry with a hitch and a stall, a hundred steady frames, then a second entry.
    private func visitLog() -> PerformanceLog {
        var log = PerformanceLog()
        put(&log, 0, entered: true)   // launch: the first frame has no frame time, but it is an entry
        for _ in 0..<100 { put(&log, 0.0165, entering: true) }
        put(&log, 0.8, entering: true)
        put(&log, 2.5, entering: true)
        for _ in 0..<96 { put(&log, 0.0165) }
        for _ in 0..<2 { put(&log, 0.0405) }
        put(&log, 0.0605)
        put(&log, 0.1205)
        put(&log, 0.0165, entered: true)   // back again from another world
        return log
    }

    func testEntriesAreKeptApartFromSteadyFrames() {
        let rows = visitLog().rows
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.entries, 2, "the launch and the return")
        XCTAssertEqual(row.entryFrames, 103, "the entry's frames, its stall and the return's first frame")
        XCTAssertEqual(row.entryWorst, 2500, accuracy: 1e-6, "an entry's stall is its worst")
        XCTAssertEqual(row.steadyFrames, 100)
        XCTAssertEqual(row.steadyTypical, 17)
        XCTAssertEqual(row.steadyP95, 17, "the 95th steady frame is still a 16.5 ms one")
        XCTAssertEqual(row.steadyP99, 61, "the 99th is the 60.5 ms frame")
        XCTAssertEqual(row.steadyWorst, 120.5, accuracy: 1e-6)
        XCTAssertEqual(row.over33, 4)
        XCTAssertEqual(row.over50, 2)
        XCTAssertEqual(row.over100, 1)
        // The first table is as it always was: every frame but the stall.
        XCTAssertEqual(row.frames, 202)
        XCTAssertEqual(row.stalls, 1)
        XCTAssertEqual(row.worst, 800, accuracy: 1e-6, "the entry's hitch is the worst frame of all")
        XCTAssertEqual(row.stallsActive, 1)
    }

    func testTheCanvasTimeAndTheStepAreReadInTenthsOfAMillisecond() {
        var log = PerformanceLog()
        put(&log, 0.0165, cpu: 0.35, step: 0.3, entered: true)   // an entry that built something on the main thread
        for _ in 0..<10 { put(&log, 0.0165, cpu: 0.0024, step: 0.0011) }
        put(&log, 0.0165, cpu: 0.0123, step: 0.002)
        put(&log, 0.0165)   // no time known: not in the CPU columns
        let row = log.rows[0]
        XCTAssertEqual(row.cpuTypical, 2.5, accuracy: 1e-9, "2.4 ms is in the 2.4-2.5 ms bucket")
        XCTAssertEqual(row.cpuWorst, 12.3, accuracy: 1e-9)
        XCTAssertEqual(row.stepTypical, 1.2, accuracy: 1e-9)
        XCTAssertEqual(row.entryCPUWorst, 350, accuracy: 1e-9, "the entry's CPU time is kept apart")
        let lines = log.report(header: []).components(separatedBy: "\n")
        guard let heading = lines.firstIndex(of: PerformanceLog.steadyHeading) else { return XCTFail("no second table") }
        let title = lines[heading + 1], cells = lines[heading + 2]
        XCTAssertTrue(title.hasPrefix("World  Quality  Entries  Typical"), title)
        for (column, text) in [("CPU typ", "2.5 ms"), ("CPU worst", "12.3 ms"), ("Step typ", "1.2 ms"), ("Entry CPU", "350.0 ms"),
                               ("Entries", "1"), ("Entry worst", "17 ms")] {
            guard let at = title.range(of: column) else { XCTFail(column); continue }
            let offset = at.lowerBound.utf16Offset(in: title)
            XCTAssertEqual(String(cells.dropFirst(offset).prefix(text.count)), text, column)
        }
    }

    func testAStallSaysWhatTheAppWasDoing() {
        var log = PerformanceLog()
        put(&log, 0.0165)
        put(&log, 4.1, cause: .active)
        for _ in 0..<2 { put(&log, 9.8, cause: .background) }
        for _ in 0..<3 { put(&log, 30, cause: .hidden) }
        let row = log.rows[0]
        XCTAssertEqual(row.stalls, 6)
        XCTAssertEqual(row.longestStall, 30, accuracy: 1e-9)
        XCTAssertEqual([row.stallsActive, row.stallsBackground, row.stallsHidden], [1, 2, 3])
        XCTAssertTrue(log.report(header: []).contains("1/2/3"))
    }

    func testAWorldSeenOnlyAsItWasEnteredHasNoSteadyFrames() {
        var log = PerformanceLog()
        put(&log, 0.0165, world: "long", entered: true)
        for _ in 0..<300 { put(&log, 0.0165, world: "long") }
        put(&log, 0.0165, world: "brief", entered: true)
        for _ in 0..<20 { put(&log, 0.0165, world: "brief", entering: true) }
        let lines = log.report(header: []).components(separatedBy: "\n")
        guard let heading = lines.firstIndex(of: PerformanceLog.steadyHeading) else { return XCTFail("no second table") }
        XCTAssertTrue(lines[heading + 2].hasPrefix("long "), "the same order as the first table")
        let brief = lines[heading + 3]
        XCTAssertTrue(brief.hasPrefix("brief  Smooth   1        -        -      -      -      0/0/0"), brief)
        XCTAssertTrue(lines.allSatisfy { !$0.hasSuffix(" ") }, "no trailing spaces")
        XCTAssertTrue(log.report(header: []).unicodeScalars.allSatisfy { $0.value < 0x80 }, "ASCII only")
    }

    func testOldStyleFramesAreAllSteadyAndCountNoEntries() {
        var log = PerformanceLog()
        for _ in 0..<10 {
            log.record(world: "w", quality: .high, frameTime: 0.0165, gpuTime: 0.01, pixelScale: 1, rescued: false,
                       pixels: (1280, 800))
        }
        let row = log.rows[0]
        XCTAssertEqual(row.entries, 0)
        XCTAssertEqual(row.entryFrames, 0)
        XCTAssertEqual(row.steadyFrames, 10)
        XCTAssertEqual(row.cpuWorst, 0)
    }
}
