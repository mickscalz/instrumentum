import XCTest
@testable import InStrumAudio
@testable import InStrumCore

/// Every world's ambience loudness (`LoudnessMeter`: BS.1770-4 integrated, and the true peak), on the scene its ambience
/// demo renders (`DemoRenderTests.ambienceDemo`), as heard at the app's default ambience volume (25%, the ambience bus's
/// gain on the main mixer) with the world's trim (`AmbienceTrim`). The trim is a plain gain, there from the first sample
/// (`TrimTests`), so a demo heard with it reads its untrimmed loudness and peak plus the trim exactly.
@MainActor
final class AmbienceLoudnessTests: XCTestCase {
    /// The ambience bus's gain at the app's default ambience volume, in dB.
    nonisolated static let volumeDB = 20 * log10(AmbienceSettings().volume)

    /// One world's ambience, measured.
    struct Reading {
        let world: String
        let trimDB: Double
        let lufs: Double
        let peak: Double
        var line: String {
            "LOUDNESS ambience \(world): \(String(format: "%.1f", lufs)) LUFS, peak \(String(format: "%.1f", peak)) dBTP (trim \(String(format: "%+.1f", trimDB)) dB)"
        }
    }

    /// Every world's ambience demo, each rendered once, `seconds` long (by default the demo's own length), at the default
    /// volume and with the world's trim.
    static func readings(seconds: Double? = nil) -> [Reading] {
        DemoRenderTests.ambienceDemoNames.map { (name: String) -> Reading in
            let audio = DemoRenderTests.ambienceDemo(name, seconds: seconds ?? DemoRenderTests.ambienceDemoSeconds(name))
            let world = String(name.dropLast("-ambience".count))
            let trim = AmbienceTrim.db(for: world)
            return Reading(world: world, trimDB: trim, lufs: LoudnessMeter.integrated(audio.l, audio.r) + volumeDB + trim,
                           peak: LoudnessMeter.truePeak(audio.l, audio.r) + volumeDB + trim)
        }
    }

    /// Each world's ambience loudness before worlds had trims, at the default volume (LUFS; this meter, on CI, 13 Nov 2026).
    nonisolated static let untrimmed: [String: Double] = [
        "moonlit-lake": -30.76, "spaceship-lounge": -35.45, "golden-hour-beach": -33.74, "coast-road": -35.90,
        "snowbound-cabin": -41.64, "bedroom-dawn": -47.32, "aurora-fjord": -37.35, "bioluminescent-bay": -33.41,
        "tea-house-snow": -42.49, "zen-rock-garden": -36.88, "submarine-window": -40.76, "great-barrier-reef": -34.51,
        "supercell-sky": -30.25, "lightning-plains": -33.94, "volcano-rim": -37.47, "neon-night-drive": -38.20,
    ]

    /// The middle of `values` (the mean of the middle two when there is an even number of them).
    nonisolated static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The worlds' one ambience loudness: the median of their untrimmed loudness, so the balance between the instruments
    /// and the ambience is as it was. A world added later is held to it too.
    nonisolated static let target = AmbienceLoudnessTests.median(Array(AmbienceLoudnessTests.untrimmed.values))
    /// How far from the target a world's ambience may sit (LU), and the largest trim a world may have (dB).
    nonisolated static let tolerance = 1.5, clamp = 6.0
    /// The worlds whose trim is held at the clamp short of the target: Bedroom Dawn's demo, heard wholly indoors (the room
    /// itself plays its window at 0.7, or 0.35 open), would need +10.9 dB.
    nonisolated static let heldByClamp: Set<String> = ["bedroom-dawn"]

    /// One loudness: every world's ambience, trimmed, sits within 1.5 LU of the worlds' target at the default volume (one
    /// held by the clamp at least comes nearer, its trim the clamp's). Each is rendered once, and the report prints a line
    /// for each.
    func testEveryWorldsAmbienceSitsAtOneLoudness() {
        let all = Self.readings()
        for reading in all { print(reading.line) }
        let sorted = all.map(\.lufs).sorted()
        print("LOUDNESS worlds: \(all.count), target \(String(format: "%.2f", Self.target)) LUFS, from \(String(format: "%.1f", sorted.first ?? 0)) to \(String(format: "%.1f", sorted.last ?? 0)), median \(String(format: "%.2f", Self.median(sorted)))")
        print("LOUDNESS ambience table: " + all.map { "\($0.world)=\(String(format: "%.2f", $0.lufs))/\(String(format: "%.2f", $0.peak))" }.joined(separator: " "))
        XCTAssertEqual(all.count, DemoRenderTests.ambienceDemoNames.count)
        for reading in all {
            XCTAssertLessThanOrEqual(abs(reading.trimDB), Self.clamp, reading.line)
            let off = abs(reading.lufs - Self.target)
            if Self.heldByClamp.contains(reading.world) {
                let before = abs((Self.untrimmed[reading.world] ?? reading.lufs) - Self.target)
                XCTAssertEqual(abs(reading.trimDB), Self.clamp, reading.line)
                XCTAssertLessThan(off, before, reading.line)
            } else {
                XCTAssertLessThanOrEqual(off, Self.tolerance, reading.line)
            }
        }
    }
}
