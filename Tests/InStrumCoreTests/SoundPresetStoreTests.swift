import XCTest
@testable import InStrumCore

final class SoundPresetStoreTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSaveListDelete() throws {
        let store = PresetStore(directory: dir)
        XCTAssertEqual(store.sounds(), [])
        let choice = InstrumentChoice(name: "Felt Glass", componentType: 1, componentSubType: 2, componentManufacturer: 3)
        var fx = SoundFX()
        fx[.reverb] = 0.5
        let b = SoundPreset(name: "B side", instrument: choice, patchID: "felt-glass", dials: ["felt": 0.2], fx: fx)
        let a = SoundPreset(name: "A side", instrument: choice)
        try store.save(b)
        try store.save(a)
        XCTAssertEqual(store.sounds(), [a, b])
        var changed = a
        changed.fx[.echo] = 0.4
        try store.save(changed)                      // the same name replaces
        XCTAssertEqual(store.sounds(), [changed, b])
        try store.delete(sound: "A side")
        XCTAssertEqual(store.sounds(), [b])
    }

    func testSettingsCarryEffectsAndLayout() throws {
        var s = AppSettings.default
        s.soundFX[.drive] = 0.25
        s.controlLayout[DeckControl(.right, .hi)] = .ambience
        s.soundPresetName = "A side"
        let store = SettingsStore(directory: dir)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testOlderSettingsLoadNeutral() throws {
        try Data(#"{"themeID":"moonlit-lake"}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SettingsStore(directory: dir).load()
        XCTAssertTrue(s.soundFX.isNeutral)
        XCTAssertTrue(s.controlLayout.isDefault)
        XCTAssertNil(s.soundPresetName)
    }
}
