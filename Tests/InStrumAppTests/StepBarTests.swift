import XCTest
import AudioToolbox
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

/// The row under the top bar (sets, worlds, instruments, transpose) and the instrument window's size.
@MainActor
final class StepBarTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!
    var store: SettingsStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeEngine()
        store = SettingsStore(directory: dir)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() -> AppModel {
        AppModel(engine: engine, store: store, launchGuard: LaunchGuard(directory: dir),
                 presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
    }

    func testTransposeOnTheMainPageIsTheInstrumentsOwn() async throws {
        let unit = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .orbitPad), options: [])
        engine.unit = unit
        let pad = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == BuiltInEngine.orbitPad.displayName })
        let m = makeModel()
        XCTAssertNil(m.transpose, "nothing loaded yet")
        await m.choose(pad)
        XCTAssertEqual(m.transpose, 0)
        m.stepTranspose(by: 3)
        XCTAssertEqual(m.transpose, 3)
        let dial = try XCTUnwrap(unit.parameterTree?.allParameters.first { $0.identifier == "transpose" })
        XCTAssertEqual(dial.value, 3, accuracy: 0.0001)
        m.stepTranspose(by: -5)
        XCTAssertEqual(m.transpose, -2)
        m.setTranspose(40)
        XCTAssertEqual(m.transpose, 12, "never more than an octave")
        m.setTranspose(0)
        XCTAssertEqual(m.transpose, 0)
        XCTAssertEqual(m.currentInstrumentName, BuiltInEngine.orbitPad.displayName)
    }

    func testTransposeTextNamesTheCapo() {
        XCTAssertEqual(StepBar.transposeText(0), "0")
        XCTAssertEqual(StepBar.transposeText(3), "+3 · capo 3")
        XCTAssertEqual(StepBar.transposeText(-2), "−2")
        XCTAssertEqual(StepBar.transposeText(nil), "–")
    }

    func testTheBarNamesTheWorldAndFollowsAStep() {
        let m = makeModel()
        let worlds = ThemeRegistry.all
        let start = worlds.firstIndex { $0.id == m.themeID } ?? 0
        XCTAssertEqual(m.currentWorldName, worlds[start].name)
        m.stepWorld(by: 1)
        XCTAssertEqual(m.currentWorldName, worlds[(start + 1) % worlds.count].name)
        m.stepWorld(by: -1)
        XCTAssertEqual(m.currentWorldName, worlds[start].name)
    }

    func testTheSetStepsAndIsNamed() async {
        let m = makeModel()
        let sets = SetLibrary.all
        await m.applySet(sets[0].id)
        XCTAssertEqual(m.currentSetName, sets[0].name)
        m.stepSet(by: 1)
        for _ in 0..<200 where m.activeSetID != sets[1].id { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(m.currentSetName, sets[1].name)
    }

    func testTheInstrumentWindowIsAsTallAsItsPanelOrTheScreen() {
        let fits = BuiltInPanelController.windowSize(panel: CGSize(width: 440, height: 610), room: 730)
        XCTAssertEqual(fits.height, 610)
        XCTAssertEqual(fits.width, 440)
        let tooTall = BuiltInPanelController.windowSize(panel: CGSize(width: 440, height: 900), room: 730)
        XCTAssertEqual(tooTall.height, 730, "the panel scrolls inside")
        XCTAssertEqual(BuiltInPanel.cardSize.height, 240)
    }
}
