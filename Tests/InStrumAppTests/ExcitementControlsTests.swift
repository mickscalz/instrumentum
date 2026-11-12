import XCTest
@testable import InStrumApp
@testable import InStrumCore

/// The Excitement controls in the ✦ Visuals panel and All settings (Fire & Neon spec §5): the model saves them and hands
/// them on through `visualsVersion`, keeps the manual dial in range, and the panel's words say what calms them.
@MainActor
final class ExcitementControlsPanelTests: XCTestCase {
    var dir: URL!
    var store: SettingsStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SettingsStore(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        AppModel(engine: FakeEngine(), store: store, launchGuard: LaunchGuard(directory: dir),
                 presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
    }

    func testTheModelSavesAndHandsThemOn() {
        let m = makeModel()
        XCTAssertEqual(m.excitementSettings, ExcitementSettings(), "a fresh install starts on the defaults")
        let before = m.visualsVersion
        let wanted = ExcitementSettings(autoEnergy: false, manualEnergy: 0.35, moments: .lots, surprises: .off, buildAndDrop: false)
        m.setExcitementSettings(wanted)
        XCTAssertEqual(m.excitementSettings, wanted)
        XCTAssertGreaterThan(m.visualsVersion, before, "the canvas re-reads them")
        m.autosave()
        let again = makeModel()
        XCTAssertEqual(again.excitementSettings, wanted, "saved with the app's settings")
        // The same settings again change nothing; a dial out of range is kept within 0…1.
        let same = m.visualsVersion
        m.setExcitementSettings(wanted)
        XCTAssertEqual(m.visualsVersion, same)
        var loud = wanted
        loud.manualEnergy = 3
        m.setExcitementSettings(loud)
        XCTAssertEqual(m.excitementSettings.manualEnergy, 1)
        loud.manualEnergy = -1
        m.setExcitementSettings(loud)
        XCTAssertEqual(m.excitementSettings.manualEnergy, 0)
    }

    func testThePanelsWords() {
        XCTAssertEqual(ExcitementPanel.title, "Excitement")
        let moments = ExcitementSettings.Moments.allCases.map { ExcitementPanel.name($0) }
        XCTAssertEqual(moments, ["Off", "Some", "Lots"])
        let surprises = ExcitementSettings.Surprises.allCases.map { ExcitementPanel.name($0) }
        XCTAssertEqual(surprises, ["Off", "Rare", "Often"])
        for search in ["", "excitement", "Energy", "big moments", "Surprises", "build and drop", "manual"] {
            XCTAssertTrue(ExcitementPanel.matches(search), search)
        }
        XCTAssertFalse(ExcitementPanel.matches("constellation"))
        XCTAssertEqual(ExcitementPanel.energyLabel(ExcitementSettings()), "Energy: Auto")
        let manual = ExcitementSettings(autoEnergy: false, manualEnergy: 0.42)
        XCTAssertEqual(ExcitementPanel.energyLabel(manual), "Energy: 42%")
        let clamped = ExcitementPanel.updated(ExcitementSettings()) { $0.manualEnergy = 9 }
        XCTAssertEqual(clamped.manualEnergy, 1)
    }

    /// What calms it, in words: nothing by default; gentle visuals name what they hold back (only what is above Some
    /// and Rare); Reduce Motion its half.
    func testTheCaptionSaysWhatCalmsIt() throws {
        let d = ExcitementSettings()
        XCTAssertNil(ExcitementPanel.calmedCaption(d, gentle: false, reduceMotion: false))
        let gentle = try XCTUnwrap(ExcitementPanel.calmedCaption(d, gentle: true, reduceMotion: false))
        XCTAssertEqual(gentle, "Gentle visuals turn the flashes into glows.")
        let lots = ExcitementSettings(moments: .lots, surprises: .often)
        let held = try XCTUnwrap(ExcitementPanel.calmedCaption(lots, gentle: true, reduceMotion: false))
        XCTAssertEqual(held, "Gentle visuals hold big moments to Some and surprises to Rare, and turn the flashes into glows.")
        let reduced = try XCTUnwrap(ExcitementPanel.calmedCaption(d, gentle: false, reduceMotion: true))
        XCTAssertTrue(reduced.contains("half"))
    }
}
