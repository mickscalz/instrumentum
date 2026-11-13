import XCTest
import InStrumCore
@testable import InStrumApp

/// The top of Help > Copy Performance Report: every line is there, in order, in ASCII, and none names the player or the
/// Mac by its own name. (The table below it is `PerformanceLogTests`'.)
final class PerformanceReportTests: XCTestCase {
    func testTheQualityNamesAreTheOnesTheDisplaySectionShows() {
        XCTAssertEqual(PerformanceReport.qualityName(.lite), "Smooth")
        XCTAssertEqual(PerformanceReport.qualityName(.auto), "Auto")
        XCTAssertEqual(PerformanceReport.qualityName(.high), "High")
        XCTAssertEqual(PerformanceReport.qualityName(.ultra), "Ultra")
    }

    func testRunningTimeIsInWholeMinutes() {
        XCTAssertEqual(PerformanceReport.wholeMinutes(0), 0)
        XCTAssertEqual(PerformanceReport.wholeMinutes(59.9), 0)
        XCTAssertEqual(PerformanceReport.wholeMinutes(60), 1)
        XCTAssertEqual(PerformanceReport.wholeMinutes(754), 12)
        XCTAssertEqual(PerformanceReport.wholeMinutes(-5), 0)
        XCTAssertEqual(PerformanceReport.wholeMinutes(.nan), 0)
    }

    func testTheHeaderHasEveryLineInOrderAndNothingPrivate() {
        let lines = PerformanceReport.header(quality: .lite, gentleVisuals: true, runningSeconds: 754)
        XCTAssertGreaterThanOrEqual(lines.count, 6, "title, build, macOS, Mac, the graphics chips, quality, running time")
        XCTAssertEqual(lines[0], "In Strum Meants performance report")
        XCTAssertTrue(lines[1].hasPrefix("Build "), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("macOS "), lines[2])
        XCTAssertTrue(lines[3].hasPrefix("Mac: "), lines[3])
        for graphics in lines[4..<(lines.count - 2)] {
            XCTAssertTrue(graphics.hasPrefix("Graphics: "), graphics)
        }
        XCTAssertEqual(lines[lines.count - 2], "Quality setting: Smooth, Gentle visuals on")
        XCTAssertEqual(lines[lines.count - 1], "Running for 12 min")

        let off = PerformanceReport.header(quality: .auto, gentleVisuals: false, runningSeconds: 30)
        XCTAssertEqual(off[off.count - 2], "Quality setting: Auto, Gentle visuals off")
        XCTAssertEqual(off[off.count - 1], "Running for 0 min")

        let all = lines.joined(separator: "\n")
        let printable = all.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            (scalar.value >= 0x20 && scalar.value <= 0x7E) || scalar.value == 0x0A
        }
        XCTAssertTrue(printable, "ASCII only, one line each")
        XCTAssertFalse(all.contains("/Users"), "no file path")
        let home = NSHomeDirectory()
        if home.count > 3 { XCTAssertFalse(all.contains(home), "no home folder") }
        let user = NSUserName()
        if user.count >= 4 { XCTAssertFalse(all.contains(user), "no user name") }
    }

    func testTheMacLineNamesTheModelTheProcessorAndTheMemory() {
        let line = PerformanceReport.macLine()
        XCTAssertTrue(line.hasPrefix("Mac: "), line)
        XCTAssertTrue(line.hasSuffix(" GB"), line)
        XCTAssertEqual(line.components(separatedBy: ", ").count >= 3, true, line)
    }
}
