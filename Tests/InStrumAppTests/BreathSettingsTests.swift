import XCTest
@testable import InStrumApp
@testable import InStrumCore

/// Breathing ambience's settings (Small Wins spec §5, Task 8; Review focus 5): the app's own, so applying a set leaves
/// them alone; the switch and the depth reach the director's controls and are saved.
@MainActor
final class BreathSettingsTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeEngine()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        AppModel(engine: engine, store: SettingsStore(directory: dir), launchGuard: LaunchGuard(directory: dir),
                 presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
    }

    func testApplyingASetLeavesBreathingAlone() async {
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setBreath(AmbienceBreathSettings(enabled: false, depth: 0.7))
        await m.applySet("moonlit-lake")
        XCTAssertFalse(m.breathSettings.enabled, "still off")
        XCTAssertEqual(m.breathSettings.depth, 0.7, accuracy: 1e-12)
        XCTAssertFalse(m.sceneControls.breath.enabled)
        XCTAssertFalse(m.isSetModified, "breathing is not part of a set")
        await m.applySet("spaceship-lounge")
        XCTAssertFalse(m.breathSettings.enabled)
        XCTAssertFalse(SettingsStore(directory: dir).load().breath.enabled, "saved off")
    }

    func testTheSwitchAndTheDepthReachTheDirector() {
        let m = makeModel()
        XCTAssertEqual(m.breathSettings, AmbienceBreathSettings(), "on, at depth 1, by default")
        XCTAssertEqual(m.sceneControls.breath, AmbienceBreathSettings())
        m.setBreath(AmbienceBreathSettings(enabled: true, depth: 1.4))
        XCTAssertEqual(m.sceneControls.breath.depth, 1.4, accuracy: 1e-12)
        m.setBreath(AmbienceBreathSettings(enabled: false, depth: 1.4))
        XCTAssertFalse(m.sceneControls.breath.enabled)
        let again = makeModel()
        XCTAssertFalse(again.breathSettings.enabled, "the switch saves at once")
        XCTAssertFalse(again.sceneControls.breath.enabled, "and reaches the director from launch")
        XCTAssertEqual(SkyControls.breathesTitle, "Ambience breathes")
        XCTAssertEqual(SkyControls.depthTitle(1), "Breathing depth 100%")
        XCTAssertEqual(SkyControls.depthTitle(0.555), "Breathing depth 56%")
        XCTAssertEqual(AmbienceBreathSettings.depthRange, 0...1.5)
    }
}
