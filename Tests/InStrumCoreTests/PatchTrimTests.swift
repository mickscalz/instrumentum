import XCTest
@testable import InStrumCore

/// The presets' and the worlds' trims (one loudness across presets and across worlds): a patch saved before trims existed
/// still loads, with none; every trim stays in its range, and every world with an ambience has one.
final class PatchTrimTests: XCTestCase {
    /// A patch saved before the trim existed (no `trimDB`) decodes with 0; one saved now keeps its trim.
    func testAnOldSavedPatchDecodesWithNoTrim() throws {
        let old = #"{"id":"bare-felt","name":"Bare Felt","engine":"feltGlass","values":{"felt":0.7,"glass":0},"creditID":"come-back-to-earth"}"#
        let patch = try JSONDecoder().decode(Patch.self, from: Data(old.utf8))
        XCTAssertEqual(patch.trimDB, 0)
        XCTAssertEqual(patch.id, "bare-felt")
        XCTAssertEqual(patch.name, "Bare Felt")
        XCTAssertEqual(patch.engine, .feltGlass)
        XCTAssertEqual(patch.values, ["felt": 0.7, "glass": 0])
        XCTAssertEqual(patch.creditID, "come-back-to-earth")
        let bare = #"{"id":"x","name":"X","engine":"orbitPad","values":{}}"#
        let plain = try JSONDecoder().decode(Patch.self, from: Data(bare.utf8))
        XCTAssertEqual(plain.trimDB, 0)
        XCTAssertNil(plain.creditID)

        var trimmed = PatchLibrary.all[0]
        trimmed.trimDB = -2.5
        let back = try JSONDecoder().decode(Patch.self, from: JSONEncoder().encode(trimmed))
        XCTAssertEqual(back, trimmed)
        XCTAssertEqual(back.trimDB, -2.5)
    }

    /// A built-in preset is found by its id and engine (a saved instrument state takes its trim from it).
    func testABuiltInIsFoundByItsIDAndEngine() {
        XCTAssertEqual(Patch.builtIn(id: "lullaby", engine: .feltGlass)?.name, "Lullaby")
        XCTAssertNil(Patch.builtIn(id: "lullaby", engine: .orbitPad))
        XCTAssertNil(Patch.builtIn(id: nil, engine: .feltGlass))
    }

    /// Every built-in preset's trim is within ±9 dB, and every world's ambience trim within ±6 dB; every world with an
    /// ambience has one, and a theme without one has none.
    func testTrimsStayInTheirRanges() {
        for patch in PatchLibrary.all {
            XCTAssertTrue(patch.trimDB.isFinite && abs(patch.trimDB) <= 9, "\(patch.id): \(patch.trimDB) dB")
        }
        let worlds = [MoonlitLakeModel.id, SpaceshipLoungeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id,
                      BedroomDawnModel.id, AuroraFjordModel.id, BioluminescentBayModel.id, TeaHouseSnowModel.id, ZenRockGardenModel.id,
                      SubmarineWindowModel.id, GreatBarrierReefModel.id, SupercellSkyModel.id, LightningPlainsModel.id, VolcanoRimModel.id,
                      NeonNightDriveModel.id]
        XCTAssertEqual(Set(AmbienceTrim.byWorld.keys), Set(worlds))
        for world in worlds {
            let trim = AmbienceTrim.db(for: world)
            XCTAssertTrue(trim.isFinite && abs(trim) <= 6, "\(world): \(trim) dB")
        }
        XCTAssertEqual(AmbienceTrim.db(for: MidnightSteinwayModel.id), 0)
        XCTAssertEqual(AmbienceTrim.db(for: ButterflyGardenModel.id), 0)
    }
}
