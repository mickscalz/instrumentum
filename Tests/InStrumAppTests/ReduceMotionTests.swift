import XCTest
import AppKit
@testable import InStrumApp
@testable import InStrumCore

/// Follow the Mac's Reduce Motion (Small Wins spec §6, Task 9): with the setting on, the Mac's flag makes the visuals
/// gentle and reaches the director, live, and your own Gentle visuals setting never changes.
@MainActor
final class ReduceMotionTests: XCTestCase {
    /// Stands in for the Mac's flag.
    final class FakeReduceMotion: ReduceMotionWatching {
        var isOn: Bool { didSet { onChange?() } }
        var onChange: (() -> Void)?
        init(_ on: Bool = false) { isOn = on }
    }

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

    func testEffectiveGentleUnderEveryCombination() {
        for gentle in [false, true] {
            for follow in [false, true] {
                for flag in [false, true] {
                    let label = "gentle \(gentle), follow \(follow), Reduce Motion \(flag)"
                    let m = makeModel()
                    m.setGentleVisuals(gentle)
                    m.setFollowReduceMotion(follow)
                    m.startWatchingReduceMotion(FakeReduceMotion(flag))
                    XCTAssertEqual(m.effectiveGentleVisuals, gentle || (follow && flag), label)
                    XCTAssertEqual(m.reduceMotionActive, follow && flag, label)
                    XCTAssertEqual(m.sceneControls.reduceMotion, follow && flag, label)
                    XCTAssertEqual(m.gentleVisuals, gentle, "\(label): your own setting is untouched")
                    // And the other way round: the setting changed while the Mac's flag is already being followed.
                    let n = makeModel()
                    n.setGentleVisuals(gentle)
                    n.setFollowReduceMotion(!follow)
                    n.startWatchingReduceMotion(FakeReduceMotion(flag))
                    XCTAssertEqual(n.reduceMotionActive, !follow && flag, "\(label), before")
                    n.setFollowReduceMotion(follow)
                    XCTAssertEqual(n.effectiveGentleVisuals, gentle || (follow && flag), "\(label), set after")
                    XCTAssertEqual(n.sceneControls.reduceMotion, follow && flag, "\(label), set after")
                    XCTAssertEqual(n.gentleVisuals, gentle)
                }
            }
        }
    }

    func testTheNotificationFlipsItLive() {
        let m = makeModel()
        let mac = FakeReduceMotion()
        m.startWatchingReduceMotion(mac)
        XCTAssertFalse(m.reduceMotionActive)
        let before = m.visualsVersion
        mac.isOn = true
        XCTAssertTrue(m.reduceMotionActive)
        XCTAssertTrue(m.sceneControls.reduceMotion)
        XCTAssertTrue(m.effectiveGentleVisuals)
        XCTAssertGreaterThan(m.visualsVersion, before, "the canvas re-reads the visuals")
        let on = m.visualsVersion
        mac.isOn = false
        XCTAssertFalse(m.reduceMotionActive)
        XCTAssertFalse(m.sceneControls.reduceMotion)
        XCTAssertFalse(m.effectiveGentleVisuals)
        XCTAssertGreaterThan(m.visualsVersion, on)
        mac.isOn = true
        m.setFollowReduceMotion(false)
        XCTAssertFalse(m.reduceMotionActive, "switched off in Display: no longer followed")
        XCTAssertFalse(m.sceneControls.reduceMotion)
        // A second watcher replaces the first, which no longer reaches the model.
        let other = FakeReduceMotion(true)
        m.setFollowReduceMotion(true)
        m.startWatchingReduceMotion(other)
        XCTAssertNil(mac.onChange)
        other.isOn = false
        XCTAssertFalse(m.reduceMotionActive)
    }

    func testTheSettingDecodesWithItsDefault() throws {
        XCTAssertTrue(AppSettings().followReduceMotion, "on by default")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"themeID":"moonlit-lake"}"#.utf8))
        XCTAssertTrue(old.followReduceMotion, "settings from before it existed follow the Mac")
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"followReduceMotion":"yes"}"#.utf8))
        XCTAssertTrue(bad.followReduceMotion)
        var off = AppSettings()
        off.followReduceMotion = false
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off)).followReduceMotion)
        let m = makeModel()
        m.setFollowReduceMotion(false)
        XCTAssertFalse(makeModel().followReduceMotion, "saved")
        XCTAssertEqual(SettingsPanel.reduceMotionCaption, "The Mac's Reduce Motion is on, so the visuals move gently.")
    }

    func testTheSystemWatcherReadsTheMac() {
        let mac = SystemReduceMotion()
        XCTAssertEqual(mac.isOn, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let changed = expectation(description: "the Mac's display options changed")
        mac.onChange = { changed.fulfill() }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        wait(for: [changed], timeout: 2)
        // A model following it reads the same flag.
        let m = makeModel()
        m.startWatchingReduceMotion(mac)
        XCTAssertEqual(m.reduceMotionActive, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
