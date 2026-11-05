import XCTest
@testable import InStrumApp
@testable import InStrumCore

final class SettingsPanelTests: XCTestCase {
    func testHeroSpecsSelectedForPanel() {
        let hero = VisualSettings.heroSpecs(for: ButterflyGardenModel.id)
        XCTAssertFalse(hero.isEmpty)
        XCTAssertTrue(hero.allSatisfy(\.hero))
        let declared = ButterflyGardenModel.parameters.filter(\.hero).map(\.id)
        XCTAssertEqual(hero.map(\.id), declared)
    }
    /// All settings shows the Sky extras group (constellation lines, the aurora, iridescence, rime) only under a real sky:
    /// every world but the lounge (space has its own stars, no lines and no aurora), never the Garden or the Steinway.
    func testNightSkySettingsOnlyUnderARealSky() {
        for id in [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id, BedroomDawnModel.id,
                   AuroraFjordModel.id, BioluminescentBayModel.id, TeaHouseSnowModel.id, ZenRockGardenModel.id] {
            XCTAssertTrue(AllSettingsView.hasNightSky(id), id)
        }
        for id in [ButterflyGardenModel.id, MidnightSteinwayModel.id, SpaceshipLoungeModel.id, "no-such-theme"] {
            XCTAssertFalse(AllSettingsView.hasNightSky(id), id)
        }
    }
    func testValueEditWritesThemeState() {
        var state = ThemeState()
        state = VisualSettings.updated(state, themeID: ButterflyGardenModel.id, id: "rays", to: .number(0.9))
        XCTAssertEqual(state.values["rays"], .number(0.9))
        state = VisualSettings.updated(state, themeID: ButterflyGardenModel.id, id: "time", to: .choice("Not a time"))
        XCTAssertNil(state.values["time"])
    }
    func testMacroEditSnapsNearCentre() {
        var state = ThemeState()
        state = VisualSettings.updatedMacro(state, .speed, to: 0.03)
        XCTAssertEqual(state.macros[.speed] ?? 0, 0)
        state = VisualSettings.updatedMacro(state, .speed, to: 0.6)
        XCTAssertEqual(state.macros[.speed] ?? 0, 0.6, accuracy: 1e-9)
    }
    func testResetThemeClearsEverything() {
        let state = ThemeState(values: ["rays": .number(0.9)], macros: [.glow: 0.4], lookPresetName: "X")
        XCTAssertEqual(VisualSettings.reset(state), ThemeState())
    }
    /// The Advanced group once called "Night sky" is "Sky extras", and searching finds it by any of its five dials.
    func testSkyExtrasGroupIsFoundByItsDials() {
        XCTAssertEqual(SkyExtrasSection.title, "Sky extras")
        for search in ["", "sky extras", "Constellation", "aurora", "Iridescence", "rime", "Rime speed", "night sky", "Meteors"] {
            XCTAssertTrue(SkyExtrasSection.matches(search), search)
        }
        XCTAssertFalse(SkyExtrasSection.matches("ripples"))
    }
    /// Sky extras' Meteors dial (spec §6.5): how many shooting stars as a multiple of a real night, 0.5…10 and 2 by
    /// default; searching finds it as meteors or shooting stars; Reset Advanced puts it back and the looks set it.
    func testAdvancedMeteorsDefaults() {
        let d = SkySettings()
        XCTAssertEqual(d.meteorRate, 2)
        XCTAssertEqual(SkyExtrasSection.meteorRange, 0.5...10)
        XCTAssertTrue(SkyExtrasSection.meteorRange.contains(d.meteorRate))
        XCTAssertEqual(SkyExtrasSection.meteorLabel(d.meteorRate), "Meteors 2.0×")
        XCTAssertEqual(SkyExtrasSection.meteorLabel(0.5), "Meteors 0.5×")
        XCTAssertEqual(SkyExtrasSection.meteorLabel(10), "Meteors 10.0×")
        XCTAssertEqual(SkyExtrasSection.meteorHelp, "How many shooting stars, as a multiple of a real night")
        for search in ["meteor", "Meteors", "shooting stars", "Shooting"] {
            XCTAssertTrue(SkyExtrasSection.matches(search), search)
        }
        var s = SkySettings(); s.meteorRate = 9
        s.resetAdvanced()
        XCTAssertEqual(s.meteorRate, 2, "Reset Advanced")
        s.applyAdvanced(.gentle); XCTAssertEqual(s.meteorRate, 1.5, "Gentle")
        s.applyAdvanced(.dramatic); XCTAssertEqual(s.meteorRate, 4, "Dramatic")
        s.applyAdvanced(.dreamy); XCTAssertEqual(s.meteorRate, 2.5, "Dreamy")
        for look in SkySettings.AdvancedPreset.allCases {
            var t = SkySettings(); t.applyAdvanced(look)
            XCTAssertTrue(SkyExtrasSection.meteorRange.contains(t.meteorRate), look.rawValue)
        }
    }
}
