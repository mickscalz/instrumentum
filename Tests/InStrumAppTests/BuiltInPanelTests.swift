import XCTest
import AVFoundation
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

/// The built-in instrument panel's Arp row (Fire & Neon spec §4.4).
@MainActor
final class BuiltInPanelTests: XCTestCase {
    /// An instrument with an arpeggiator gathers its arp's own dials in one Arp row, in the row's order, and shows each of
    /// its other dials once in the dial list, in its own order: Blue Depth (Blink, Tempo) and Replicant Brass (Arp, Rate,
    /// Tempo, Split) have the row; Magma Bass and every other engine have none, and their dial lists are as before.
    func testTheArpRowGathersTheArpDials() throws {
        var rows: [BuiltInEngine] = []
        for engine in BuiltInEngine.allCases {
            let unit = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: engine), options: [])
            let ids: [String] = (unit.parameterTree?.allParameters ?? []).map { $0.identifier }
            let layout = BuiltInPanel.layout(ids, engine: engine)
            XCTAssertEqual(layout.arp, engine.arpDials, "\(engine): every arp dial is one the engine has, in the row's order")
            if !layout.arp.isEmpty { rows.append(engine) }
            let shown: [String] = ids.filter { !Mood.parameterIdentifiers.contains($0) && $0 != "fineTune" && $0 != "transpose" }
            XCTAssertEqual(layout.dials, shown.filter { !layout.arp.contains($0) }, "\(engine): the rest in the engine's order")
            XCTAssertEqual(layout.dials.count + layout.arp.count, shown.count, "\(engine): every dial shown once")
            XCTAssertTrue(Set(layout.dials).isDisjoint(with: layout.arp), "\(engine)")
        }
        XCTAssertEqual(rows, [.blueDepth, .replicantBrass], "the Arp row for these two only; Magma Bass has no arp")

        // Replicant Brass's row: its menus name every value its dials take.
        let brass = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .replicantBrass), options: [])
        let dials: [AUParameter] = brass.parameterTree?.allParameters ?? []
        let mode = try XCTUnwrap(dials.first { $0.identifier == "arp" })
        let rate = try XCTUnwrap(dials.first { $0.identifier == "rate" })
        let split = try XCTUnwrap(dials.first { $0.identifier == "split" })
        XCTAssertEqual(BuiltInPanel.arpModes, ["Off", "Up", "Down", "Up-down", "Played", "Random"])
        XCTAssertEqual(Int(mode.maxValue), BuiltInPanel.arpModes.count - 1)
        XCTAssertEqual(BuiltInPanel.arpRates, ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32"])
        XCTAssertEqual(Int(rate.maxValue), BuiltInPanel.arpRates.count - 1)
        XCTAssertEqual(BuiltInPanel.arpModes[Int(mode.value)], "Played", "the Replicant preset's mode")
        XCTAssertEqual(BuiltInPanel.arpRates[Int(rate.value)], "1/16")
        XCTAssertEqual(BuiltInPanel.splitName(Double(split.value)), "C3", "Chrome Bass split at C3")
        XCTAssertEqual(Int(split.maxValue), 60, "the split's menu runs E1 to C4")
        XCTAssertEqual(BuiltInPanel.splitName(0), "Off")
        XCTAssertEqual(BuiltInPanel.splitName(27), "Off")
        XCTAssertEqual(BuiltInPanel.splitName(28), "E1")
        XCTAssertEqual(BuiltInPanel.splitName(60), "C4")
        XCTAssertEqual(BuiltInPanel.splitName(61), "C♯4")
    }
}
