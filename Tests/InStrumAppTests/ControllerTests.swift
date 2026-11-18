import XCTest
import AudioToolbox
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

/// The DDJ-ERGO as a bank of knobs: its messages move the effects, never play notes, and saved sounds come back.
@MainActor
final class ControllerTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!
    var store: SettingsStore!

    let splice = InstrumentChoice(name: "Splice INSTRUMENT", componentType: kAudioUnitType_MusicDevice,
                                  componentSubType: 0x53504C49, componentManufacturer: 0x53504C43)

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

    /// A knob fully right: its coarse half, then its fine half.
    private func turnFully(_ m: AppModel, status: UInt8, controller: UInt8) {
        m.handleController(bytes: [status, controller, 127], time: 1)
        m.handleController(bytes: [status, controller + 32, 127], time: 1)
        m.syncController()
    }

    func testFX1KnobOneIsTheEcho() {
        let m = makeModel()
        XCTAssertEqual(m.soundFX[.echo], 0)
        turnFully(m, status: 0xB4, controller: 2)
        XCTAssertEqual(m.soundFX[.echo], 1, accuracy: 0.0001)
    }

    func testLeftHighMidLowAreTheTone() {
        let m = makeModel()
        turnFully(m, status: 0xB6, controller: 7)
        turnFully(m, status: 0xB6, controller: 11)
        turnFully(m, status: 0xB6, controller: 15)
        XCTAssertEqual(m.soundFX[.eqHigh], 1, accuracy: 0.0001)
        XCTAssertEqual(m.soundFX[.eqMid], 1, accuracy: 0.0001)
        XCTAssertEqual(m.soundFX[.eqLow], 1, accuracy: 0.0001)
    }

    func testTheControllerNeverPlaysTheInstrument() {
        let m = makeModel()
        m.handleController(bytes: [0x90, 11, 127], time: 1)    // deck A's play button
        m.handleController(bytes: [0xB6, 0, 100], time: 1)     // master volume (a bank select to a synth)
        m.handleController(bytes: [0xB4, 2, 64], time: 1)
        m.syncController()
        XCTAssertTrue(engine.sent.isEmpty)
        XCTAssertTrue(m.drainEvents().isEmpty)
    }

    func testFX1ButtonsSwitchEffects() {
        let m = makeModel()
        m.handleController(bytes: [0x94, 71, 127], time: 1)    // FX1 button 1
        m.syncController()
        XCTAssertFalse(m.soundFX.isOn(.echo))
        m.handleController(bytes: [0x94, 67, 127], time: 1)    // FX1 ON
        m.syncController()
        XCTAssertFalse(m.soundFX.isOn(.all))
        m.handleController(bytes: [0x95, 73, 127], time: 1)    // FX2 button 3: reset
        m.syncController()
        XCTAssertEqual(m.soundFX, SoundFX())
    }

    func testAKnobCanBePointedElsewhere() {
        let m = makeModel()
        m.setControlTarget(DeckControl(.left, .hi), to: .fx(.crush))
        turnFully(m, status: 0xB6, controller: 7)
        XCTAssertEqual(m.soundFX[.crush], 1, accuracy: 0.0001)
        XCTAssertEqual(m.soundFX[.eqHigh], 0.5)
        m.resetControlLayout()
        XCTAssertTrue(m.controlLayout.isDefault)
    }

    func testEffectsAndLayoutAreSaved() {
        let m = makeModel()
        m.setFX(.reverb, to: 0.4)
        m.setControlTarget(DeckControl(.right, .low), to: .ambience)
        m.autosave()
        let again = makeModel()
        XCTAssertEqual(again.soundFX[.reverb], 0.4)
        XCTAssertEqual(again.controlLayout[DeckControl(.right, .low)], .ambience)
    }

    func testOnlyAControllerPluggedInKeepsTheScreenKeys() {
        let m = makeModel()
        m.midiSourcesChanged(names: ["PIONEER DDJ-ERGO"], removed: false)
        XCTAssertTrue(m.controllerConnected)
        XCTAssertTrue(m.showsOnScreenKeyboard)
        m.midiSourcesChanged(names: [], removed: true)
        XCTAssertFalse(m.controllerConnected)
    }

    func testSaveAndBringBackASound() async throws {
        var s = AppSettings.default
        s.instrument = splice
        try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.setFX(.echo, to: 0.6)
        m.saveSound(named: "Wide echo")
        XCTAssertEqual(m.soundPresets.map(\.name), ["Wide echo"])
        XCTAssertEqual(m.soundPresetName, "Wide echo")
        let saved = try XCTUnwrap(m.soundPresets.first)
        XCTAssertEqual(saved.instrument.stateData, Data([1, 2, 3]))
        XCTAssertEqual(saved.fx[.echo], 0.6)

        m.resetFX()
        XCTAssertEqual(m.soundFX[.echo], 0)
        let loadsBefore = engine.loaded.count
        await m.applySound(saved)
        XCTAssertEqual(m.soundFX[.echo], 0.6)
        XCTAssertEqual(engine.loaded.count, loadsBefore + 1)

        m.deleteSound(saved)
        XCTAssertTrue(m.soundPresets.isEmpty)
        XCTAssertNil(m.soundPresetName)
    }

    func testAnUnnamedSoundGetsAName() async throws {
        var s = AppSettings.default
        s.instrument = splice
        try store.save(s)
        let m = makeModel()
        await m.launch(skipPluginInSafeMode: false)
        m.saveSound(named: "  ")
        XCTAssertEqual(m.soundPresets.map(\.name), ["Sound 1"])
    }

    func testThePanelListsEveryTarget() {
        let dials = [ControllerDial(index: 0, name: "Felt"), ControllerDial(index: 1, name: "Glass")]
        let options = ControllerPanel.options(dials: dials, including: .dial(5))
        let names = options.map(\.name)
        XCTAssertTrue(names.contains("Echo"))
        XCTAssertTrue(names.contains("Dial 1 · Felt"))
        XCTAssertTrue(names.contains("Dial 6 · not on this instrument"))
        XCTAssertEqual(names.first, "Nothing")
    }
}
