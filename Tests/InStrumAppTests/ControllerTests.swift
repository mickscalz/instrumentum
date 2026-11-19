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

    func testTheGainAndFilterKnobsAreTheEffects() {
        let m = makeModel()
        XCTAssertEqual(m.soundFX[.echo], 0)
        turnFully(m, status: 0xB6, controller: 3)      // left GAIN
        XCTAssertEqual(m.soundFX[.echo], 1, accuracy: 0.0001)
        turnFully(m, status: 0xB6, controller: 4)      // right GAIN
        XCTAssertEqual(m.soundFX[.reverb], 1, accuracy: 0.0001)
        turnFully(m, status: 0xB6, controller: 28)     // right FILTER
        XCTAssertEqual(m.soundFX[.drive], 1, accuracy: 0.0001)
        turnFully(m, status: 0xB6, controller: 27)     // left FILTER
        XCTAssertEqual(m.soundFX[.filter], 1, accuracy: 0.0001)
        turnFully(m, status: 0xB4, controller: 2)      // an effect-box knob is a dial now: no effect moves
        XCTAssertEqual(m.soundFX[.echoTime], FXParam.echoTime.neutral)
    }

    /// Michael's layout (19 Nov): the FX1 group of four, then the FX2 group of four, left to right across the
    /// controller, are the instrument's dials top to bottom in its panel.
    func testTheEightEffectBoxKnobsAreTheInstrumentsDialsInOrder() async throws {
        let unit = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: .orbitPad), options: [])
        engine.unit = unit
        let pad = try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == BuiltInEngine.orbitPad.displayName })
        let m = makeModel()
        await m.choose(pad)
        let all = unit.parameterTree?.allParameters ?? []
        let shown = BuiltInPanel.layout(all.map(\.identifier), engine: .orbitPad).dials
        XCTAssertGreaterThanOrEqual(shown.count, 6)
        XCTAssertEqual(m.controllerDials.count, shown.count)
        // FX1 CONTROL, 1, 2, 3, then FX2 CONTROL, 1, 2, 3: each one's status byte and coarse controller.
        let statuses: [UInt8] = [0xB4, 0xB4, 0xB4, 0xB4, 0xB5, 0xB5, 0xB5, 0xB5]
        let controllers: [UInt8] = [0, 2, 4, 6, 0, 2, 4, 6]
        for index in 0..<min(8, shown.count) {
            let identifier = shown[index]
            let parameter = try XCTUnwrap(all.first { $0.identifier == identifier })
            turnFully(m, status: statuses[index], controller: controllers[index])
            let now = parameter.value
            XCTAssertEqual(now, parameter.maxValue, accuracy: 0.0001, identifier)
        }
        // And only those: the first dial is still where the first knob left it.
        let first = try XCTUnwrap(all.first { $0.identifier == shown[0] })
        XCTAssertEqual(first.value, first.maxValue, accuracy: 0.0001)
    }

    /// Michael's layout (19 Nov): the six HI / MID / LOW knobs are the Feel sliders, top to bottom, left side first.
    func testTheSixHighMidLowKnobsAreTheFeelSliders() {
        let m = makeModel()
        let controllers: [UInt8] = [7, 11, 15, 8, 12, 16]     // left HI, MID, LOW, then right HI, MID, LOW
        let feel: [Macro] = [.intensity, .speed, .density, .glow, .chaos, .temperature]
        for index in 0..<6 {
            turnFully(m, status: 0xB6, controller: controllers[index])
            let now = m.themeState(for: m.themeID).macros[feel[index]] ?? 0
            XCTAssertEqual(now, 1, accuracy: 0.0001, feel[index].rawValue)
        }
        XCTAssertEqual(m.soundFX, SoundFX(), "and the tone is left alone")
    }

    func testTheCrossfaderIsTheTimeOfDayAndTheFadersTheAmbience() {
        let m = makeModel()
        send(m, [0xB6, 31, 64])                        // the crossfader at its middle
        XCTAssertEqual(m.skySettings.timeMode, .frozen)
        XCTAssertEqual(m.skySettings.frozenHour, 23.99 * Double(64 << 7) / 16383, accuracy: 0.001)
        turnFully(m, status: 0xB6, controller: 19)     // left channel fader
        XCTAssertEqual(engine.ambienceVolume, 1, accuracy: 0.0001)
        turnFully(m, status: 0xB6, controller: 21)     // right channel fader
        XCTAssertEqual(m.controlValue(.world(.closeness)) ?? 0, 1, accuracy: 0.0001)
    }

    func testTheControllerNeverPlaysTheInstrument() {
        let m = makeModel()
        m.handleController(bytes: [0x90, 11, 127], time: 1)    // deck A's play button (a note to a synth)
        m.handleController(bytes: [0xB6, 0, 100], time: 1)     // master volume (a bank select to a synth)
        m.handleController(bytes: [0x91, 46, 127], time: 1)    // deck B's first hot cue
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
        XCTAssertNil(m.themeState(for: m.themeID).macros[.intensity], "no longer the Feel slider")
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

    // MARK: - The world, the wheels, the buttons and the keyboard's volume knob

    /// One message from the controller, then the main actor catching up.
    private func send(_ m: AppModel, _ bytes: [UInt8]) {
        m.handleController(bytes: bytes, time: 1)
        m.syncController()
    }

    func testTheSlidersAndHeadphoneKnobsAreTheMood() {
        let m = makeModel()
        turnFully(m, status: 0xB6, controller: 2)      // HEADPHONES VOL
        XCTAssertEqual(m.mood.energy, 1, accuracy: 0.0001)
        turnFully(m, status: 0xB6, controller: 1)      // HEADPHONES MIX
        XCTAssertEqual(m.mood.warmth, 1, accuracy: 0.0001)
        turnFully(m, status: 0xB1, controller: 0)      // right TEMPO slider
        XCTAssertEqual(m.mood.motion, 1, accuracy: 0.0001)
        XCTAssertEqual(m.mood.space, 0.5, accuracy: 0.0001, "untouched")
        XCTAssertEqual(engine.moods.last?.energy ?? 0, 1, accuracy: 0.0001, "the instrument hears the mood too")
    }

    func testMasterKnobIsTheVolume() {
        let m = makeModel()
        send(m, [0xB6, 0, 64])
        XCTAssertEqual(engine.masterVolume, Float(64 << 7) / 16383, accuracy: 0.0001)
    }

    func testAKeyboardsVolumeKnobIsTheAppsVolume() {
        let m = makeModel()
        m.handleMIDI(bytes: [0xB0, 7, 127], time: 1)
        m.syncController()
        XCTAssertEqual(engine.masterVolume, 1, accuracy: 0.0001)
        XCTAssertTrue(engine.sent.isEmpty, "the instrument is never turned down as well")
        m.handleMIDI(bytes: [0xB0, 7, 0], time: 1)
        m.syncController()
        XCTAssertEqual(engine.masterVolume, 0, accuracy: 0.0001)
        m.handleMIDI(bytes: [0xB0, 1, 64], time: 1)    // the mod wheel still plays
        XCTAssertEqual(engine.sent.count, 1)
    }

    func testMuteComesBackAndIsNeverSaved() {
        let m = makeModel()
        m.setVolume(0.6)
        m.perform(.mute)
        XCTAssertEqual(engine.masterVolume, 0)
        XCTAssertNotNil(m.mutedVolume)
        m.autosave()
        XCTAssertEqual(store.load().masterVolume, 0.6, accuracy: 0.0001)
        m.perform(.mute)
        XCTAssertEqual(engine.masterVolume, 0.6, accuracy: 0.0001)
        XCTAssertNil(m.mutedVolume)
        m.perform(.mute)
        m.setVolume(0.3)                               // moving the volume ends a mute
        XCTAssertNil(m.mutedVolume)
    }

    func testRightHotCuesSetTheTimeAndSamplersTheWeather() {
        let m = makeModel()
        send(m, [0x91, 46, 127])                       // right HOT CUE 1
        XCTAssertEqual(m.skySettings.timeMode, .frozen)
        XCTAssertEqual(m.skySettings.frozenHour, 6.75, accuracy: 0.0001)
        send(m, [0x91, 49, 127])                       // right HOT CUE 4
        XCTAssertEqual(m.skySettings.frozenHour, 23.5, accuracy: 0.0001)
        send(m, [0x91, 62, 127])                       // right SAMPLER 2
        XCTAssertEqual(m.skySettings.weather, .rain)
        XCTAssertEqual(m.skySettings.weatherMode, .pick)
        send(m, [0x91, 11, 127])                       // right PLAY
        XCTAssertEqual(m.skySettings.weatherMode, .randomBeautiful)
        send(m, [0x91, 12, 127])                       // right CUE: the clock runs again
        XCTAssertNotEqual(m.skySettings.timeMode, .frozen)
    }

    func testTheBrowserStepsThroughTheWorlds() {
        let m = makeModel()
        let worlds = ThemeRegistry.all.map(\.id)
        let start = worlds.firstIndex(of: m.themeID) ?? 0
        send(m, [0xB6, 64, 1])
        XCTAssertEqual(m.themeID, worlds[(start + 1) % worlds.count])
        send(m, [0xB6, 64, 126])                       // two clicks back
        XCTAssertEqual(m.themeID, worlds[(start - 1 + worlds.count) % worlds.count])
    }

    /// Michael's layout (19 Nov): the right deck's wheel, its top (jog) and its edge (search) alike, is the time of day.
    func testTheRightJogWheelScrubsTheTimeOfDay() {
        let m = makeModel()
        m.perform(.timeMidday)
        m.handleController(bytes: [0xB1, 2, 0], time: 1)       // the top of the wheel
        m.handleController(bytes: [0xB1, 34, 100], time: 1)
        m.syncController()
        let units = 100.0 / 2430 * 8
        let turned = WheelTarget.jogHours(units: units)
        XCTAssertEqual(m.skySettings.frozenHour, 12.5 + turned, accuracy: 0.0001)
        m.handleController(bytes: [0xB1, 1, 0], time: 1)       // its outer edge does the same
        m.handleController(bytes: [0xB1, 33, 100], time: 1)
        m.syncController()
        XCTAssertEqual(m.skySettings.frozenHour, 12.5 + 2 * turned, accuracy: 0.0001)
        m.handleController(bytes: [0xB0, 2, 127], time: 1)     // the left wheel, backwards: the moon
        m.handleController(bytes: [0xB0, 34, 28], time: 1)
        m.syncController()
        let back = -100.0 / 2430 * 8 * WheelTarget.phasePerUnit
        XCTAssertEqual(m.skySettings.frozenPhase, 0.5 + back, accuracy: 0.0001)
    }

    func testAJogWheelStepsAListOnlyOnWholeSteps() {
        let m = makeModel()
        m.setWheelTarget(DeckWheel(.left, .jog), to: .worlds)
        let before = m.themeID
        m.handleController(bytes: [0xB0, 2, 0], time: 1)
        m.handleController(bytes: [0xB0, 34, 100], time: 1)    // a third of a step
        m.syncController()
        XCTAssertEqual(m.themeID, before)
        m.handleController(bytes: [0xB0, 2, 1], time: 1)
        m.handleController(bytes: [0xB0, 34, 100], time: 1)    // 228 more counts: over one step in all
        m.syncController()
        XCTAssertNotEqual(m.themeID, before)
    }

    func testButtonsAndWheelsCanBePointedElsewhereAndAreSaved() {
        let m = makeModel()
        m.setButtonAction(DeckKey(.left, .play), to: .fxReset)
        m.setWheelTarget(DeckWheel(.centre, .browse), to: .volume)
        m.setFX(.echo, to: 0.5)
        send(m, [0x90, 11, 127])
        XCTAssertEqual(m.soundFX, SoundFX())
        m.setVolume(0.5)
        send(m, [0xB6, 64, 2])
        XCTAssertEqual(engine.masterVolume, 0.5 + 2 * Float(WheelTarget.volumePerUnit), accuracy: 0.0001)
        m.autosave()
        let again = makeModel()
        XCTAssertEqual(again.buttonLayout[DeckKey(.left, .play)], .fxReset)
        XCTAssertEqual(again.buttonLayout[DeckWheel(.centre, .browse)], .volume)
        again.resetControlLayout()
        XCTAssertTrue(again.layoutsAreDefault)
    }

    func testWorldKnobsReadBackWhereTheyAre() {
        let m = makeModel()
        m.setControlValue(.world(.wind), to: 1)
        XCTAssertEqual(m.skySettings.windScale, 2, accuracy: 0.0001)
        XCTAssertEqual(m.controlValue(.world(.wind)) ?? 0, 1, accuracy: 0.0001)
        m.setControlValue(.world(.glow), to: 0.75)
        XCTAssertEqual(m.themeState(for: m.themeID).macros[.glow] ?? 0, 0.5, accuracy: 0.0001)
        m.setControlValue(.world(.energy), to: 0.9)
        XCTAssertFalse(m.excitementSettings.autoEnergy)
        XCTAssertEqual(m.excitementSettings.manualEnergy, 0.9, accuracy: 0.0001)
        XCTAssertEqual(m.controlValue(.world(.moodWarmth)) ?? 0, 0.5, accuracy: 0.0001)
    }

    func testThePanelSaysWhatWasLastTouched() {
        let m = makeModel()
        XCTAssertNil(m.controllerLastTouched)
        send(m, [0x90, 12, 127])
        XCTAssertEqual(m.controllerLastTouched, "Left CUE: All notes off")
        XCTAssertEqual(engine.panicCount, 1)
        send(m, [0xB6, 31, 64])
        XCTAssertEqual(m.controllerLastTouched, "Crossfader: Time of day")
        send(m, [0x96, 1, 127])
        XCTAssertEqual(m.controllerLastTouched, "Not mapped: button 1 on channel 7")
    }

    func testEveryActionRunsWithNothingLoaded() {
        let m = makeModel()
        for action in DeckAction.allCases where action != .fullScreen {
            m.perform(action)
        }
        XCTAssertNotNil(m.mutedVolume, "mute was pressed once")
    }

    func testThePanelGroupsTheActions() {
        XCTAssertTrue(ControllerPanel.actions(in: .sky).contains(.weatherStorm))
        XCTAssertTrue(ControllerPanel.actions(in: .playing).contains(.hold))
        var grouped = 0
        for group in DeckAction.Group.allCases { grouped += ControllerPanel.actions(in: group).count }
        XCTAssertEqual(grouped, DeckAction.allCases.count - 1, "every action but Nothing is in one group")
        let names = ControllerPanel.options(dials: [], including: .none).map(\.name)
        XCTAssertTrue(names.contains("Mood: energy"))
        XCTAssertTrue(names.contains("Time of day"))
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
