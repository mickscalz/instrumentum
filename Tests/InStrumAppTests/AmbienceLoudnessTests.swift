import XCTest
@testable import InStrumAudio
@testable import InStrumCore

/// Every world's ambience loudness (`LoudnessMeter`: BS.1770-4 integrated, and the true peak), on the scene its ambience
/// demo renders (`DemoRenderTests.ambienceDemo`), as heard at the app's default ambience volume (25%, the ambience bus's
/// gain on the main mixer).
@MainActor
final class AmbienceLoudnessTests: XCTestCase {
    /// The ambience bus's gain at the app's default ambience volume, in dB.
    nonisolated static let volumeDB = 20 * log10(AmbienceSettings().volume)

    /// One world's ambience, measured.
    struct Reading {
        let world: String
        let lufs: Double
        let peak: Double
        var line: String {
            "LOUDNESS ambience \(world): \(String(format: "%.1f", lufs)) LUFS, peak \(String(format: "%.1f", peak)) dBTP"
        }
    }

    /// Every world's ambience demo, each rendered once, `seconds` long (by default the demo's own length).
    static func readings(seconds: Double? = nil) -> [Reading] {
        DemoRenderTests.ambienceDemoNames.map { (name: String) -> Reading in
            let audio = DemoRenderTests.ambienceDemo(name, seconds: seconds ?? DemoRenderTests.ambienceDemoSeconds(name))
            return Reading(world: String(name.dropLast("-ambience".count)),
                           lufs: LoudnessMeter.integrated(audio.l, audio.r) + volumeDB,
                           peak: LoudnessMeter.truePeak(audio.l, audio.r) + volumeDB)
        }
    }

    /// The report: one line each, every world, with the median.
    func testReportAmbienceLoudness() {
        let all = Self.readings()
        for reading in all { print(reading.line) }
        let sorted = all.map(\.lufs).sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        print("LOUDNESS worlds: \(all.count), median \(String(format: "%.2f", median)) LUFS, from \(String(format: "%.1f", sorted.first ?? 0)) to \(String(format: "%.1f", sorted.last ?? 0))")
        print("LOUDNESS ambience table: " + all.map { "\($0.world)=\(String(format: "%.2f", $0.lufs))/\(String(format: "%.2f", $0.peak))" }.joined(separator: " "))
        XCTAssertEqual(all.count, 16)
        XCTAssertTrue(all.allSatisfy { $0.lufs.isFinite }, "every world is heard")
    }
}
