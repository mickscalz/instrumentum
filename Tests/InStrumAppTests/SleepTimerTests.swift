import XCTest
import SwiftUI
import AppKit
@testable import InStrumApp
@testable import InStrumCore

/// The sleep timer in the app (Small Wins spec §3, Task 6; Review focus 4): the moon starts a fade of the sound (the
/// engine's run-time gain, never the saved volumes) and of the light (the director's dim); a key, a pedal or a click
/// during it wakes the world over 3 s; the timer ends Off and is never saved. The ticker's body is called directly on
/// the test's own clock.
@MainActor
final class SleepTimerTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!
    var store: SettingsStore!
    /// The model's sleep clock.
    var now = 0.0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeEngine()
        store = SettingsStore(directory: dir)
        now = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        let m = AppModel(engine: engine, store: store, launchGuard: LaunchGuard(directory: dir),
                         presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
        m.sleepClock = { [weak self] in self?.now ?? 0 }
        m.toastDuration = 60
        return m
    }

    /// Moves the clock to `t` and runs the ticker's body there.
    private func tick(_ m: AppModel, at t: Double) {
        now = t
        m.sleepTick(at: t)
    }

    func testTheTimerFadesTheSoundButNotTheSavedVolumes() throws {
        let m = makeModel()
        m.setVolume(0.6)
        m.setAmbienceVolume(0.4)
        m.setSleepTimer(minutes: 15)
        XCTAssertEqual(m.sleepRemaining, 900)
        XCTAssertNotNil(m.sleepTicker, "the ticker runs while the timer does")
        tick(m, at: 299)
        XCTAssertEqual(engine.sleepGain, 1, "nothing fades before the last ten minutes")
        XCTAssertEqual(m.sceneControls.sleepDim, 0)
        tick(m, at: 600)
        XCTAssertEqual(engine.sleepGain, 0.5005, accuracy: 1e-3)
        XCTAssertEqual(m.sceneControls.sleepDim, 0.5, accuracy: 1e-3)
        XCTAssertEqual(m.sleepRemaining, 300)
        m.autosave()
        let saved = store.load()
        XCTAssertEqual(saved.masterVolume, 0.6, accuracy: 1e-6)
        XCTAssertEqual(saved.ambience.volume, 0.4, accuracy: 1e-9)
        XCTAssertEqual(engine.masterVolume, 0.6, accuracy: 1e-6, "the volume itself is untouched")
        XCTAssertEqual(engine.ambienceVolume, 0.4, accuracy: 1e-6)
    }

    /// The canvas reads the dim from the fade itself on every frame, between the ticker's tenths of a second.
    func testTheLightMovesEveryFrame() {
        let m = makeModel()
        XCTAssertEqual(m.frameSceneControls, m.sceneControls, "no timer: the controls as they are")
        m.setSleepTimer(minutes: 15)
        tick(m, at: 450)
        now = 450.05
        let between = m.frameSceneControls.sleepDim
        var fade = SleepFade()
        fade.start(minutes: 15, at: 0)
        XCTAssertEqual(between, fade.dim(at: 450.05), accuracy: 1e-12, "the fade's dim at this very moment")
        XCTAssertNotEqual(between, m.sceneControls.sleepDim, "not the last tick's")
        XCTAssertEqual(m.frameSceneControls.holdPedal, m.sceneControls.holdPedal)
    }

    func testTheEndIsSilentDimAndOff() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        tick(m, at: 900)
        XCTAssertEqual(engine.sleepGain, 0)
        XCTAssertEqual(m.sceneControls.sleepDim, 1)
        XCTAssertNil(m.sleepRemaining, "the timer turns itself Off")
        XCTAssertFalse(m.sleepTimerRunning)
        XCTAssertNotNil(m.sleepTicker, "still listening for a wake")
        tick(m, at: 1500)
        XCTAssertEqual(engine.sleepGain, 0, "it rests silent")
        XCTAssertEqual(m.sceneControls.sleepDim, 1, "and dim")
    }

    func testANoteWakesTheWorld() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        tick(m, at: 599.9)
        m.handleMIDI(bytes: [0x90, 60, 80], time: 600)
        tick(m, at: 601.5)
        XCTAssertEqual(engine.sleepGain, 0.75, accuracy: 0.01, "half way back, from when the note was played")
        XCTAssertEqual(m.toast?.text, AppModel.awakeText)
        XCTAssertNil(m.sleepRemaining, "the timer is Off")
        tick(m, at: 603.1)
        XCTAssertEqual(engine.sleepGain, 1)
        XCTAssertEqual(m.sceneControls.sleepDim, 0)
        XCTAssertEqual(m.toast?.text, "You're awake.")
        XCTAssertNil(m.sleepRemaining)
        XCTAssertNil(m.sleepTicker, "the ticker stops once there is nothing left to do")
    }

    func testAPedalWakesTheWorld() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        tick(m, at: 700)
        m.handleMIDI(bytes: [0xB0, 64, 127], time: 700.5)
        tick(m, at: 700.6)
        XCTAssertEqual(m.toast?.text, AppModel.awakeText)
        tick(m, at: 704)
        XCTAssertEqual(engine.sleepGain, 1)
    }

    func testAClickWakesItToo() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        tick(m, at: 900)
        XCTAssertEqual(engine.sleepGain, 0)
        m.noteUserActivity(at: 905)
        tick(m, at: 905.1)
        XCTAssertEqual(m.toast?.text, AppModel.awakeText)
        XCTAssertEqual(engine.sleepGain, 0.0333, accuracy: 0.01, "from silence, a thirtieth of the way back")
        tick(m, at: 908.1)
        XCTAssertEqual(engine.sleepGain, 1)
        XCTAssertEqual(m.sceneControls.sleepDim, 0)
    }

    func testPlayingBeforeTheFadeKeepsTheTimer() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        m.handleMIDI(bytes: [0x90, 60, 80], time: 100)
        tick(m, at: 100.1)
        XCTAssertNil(m.toast, "nothing to wake")
        XCTAssertEqual(m.sleepRemaining, 800)
        let label = SleepMenu.label(remaining: m.sleepRemaining ?? 0)
        XCTAssertEqual(label, "14 min")
        tick(m, at: 600)
        XCTAssertEqual(engine.sleepGain, 0.5005, accuracy: 1e-3, "the fade goes ahead")
    }

    func testANewTimeWhileDimGlidesBack() {
        let m = makeModel()
        m.setSleepTimer(minutes: 15)
        tick(m, at: 900)
        now = 901
        m.setSleepTimer(minutes: 30)
        XCTAssertEqual(m.sleepRemaining, 1800)
        XCTAssertNil(m.toast, "a new time is not a wake")
        tick(m, at: 902.5)
        XCTAssertEqual(engine.sleepGain, 0.5, accuracy: 0.01, "gliding back over 3 s")
        tick(m, at: 904.1)
        XCTAssertEqual(engine.sleepGain, 1)
        XCTAssertEqual(m.sceneControls.sleepDim, 0)
        XCTAssertNotNil(m.sleepTicker, "the new timer runs on")
        now = 905
        m.setSleepTimer(minutes: nil)
        XCTAssertNil(m.sleepRemaining)
        XCTAssertNil(m.sleepTicker, "Off")
    }

    func testTheTimerIsNeverSaved() throws {
        let m = makeModel()
        m.setSleepTimer(minutes: 45)
        tick(m, at: 2500)
        m.autosave()
        let url = dir.appendingPathComponent("settings.json")
        let json = try String(contentsOf: url, encoding: .utf8).lowercased()
        XCTAssertFalse(json.contains("sleep"), "no sleep key")
        let fresh = makeModel()
        XCTAssertNil(fresh.sleepRemaining)
        XCTAssertEqual(fresh.sceneControls.sleepDim, 0)
        XCTAssertNil(fresh.sleepTicker)
        XCTAssertEqual(SleepFade.choices, [15, 30, 45, 60, 90])
    }

    func testTheMoonLabel() {
        XCTAssertEqual(SleepMenu.label(remaining: 900), "15 min")
        XCTAssertEqual(SleepMenu.label(remaining: 839), "14 min")
        XCTAssertEqual(SleepMenu.label(remaining: 60), "1 min")
        XCTAssertEqual(SleepMenu.label(remaining: 59), "59 s")
        XCTAssertEqual(SleepMenu.label(remaining: 30), "30 s")
    }
}
