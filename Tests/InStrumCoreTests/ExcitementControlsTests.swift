import XCTest
@testable import InStrumCore

/// Excitement's controls (Fire & Neon spec §5, plan Task 5's app part): saved with the app's settings (older saves load
/// with the defaults), and calmed by the director's controls: gentle visuals hold big moments to Some and surprises to
/// Rare, Reduce Motion caps the drawn Energy at half and plays moments at half strength, the sleep fade stops them.
final class ExcitementControlsTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }

    /// Review focus 4: a settings file from before Excitement (Small Wins' fields, no `excitement`) loads with its
    /// defaults (Auto, Some, Rare, build and drop on); a bad value falls back without losing the rest; every value
    /// round-trips.
    func testOldSavesLoadWithTheDefaults() throws {
        let old = #"{"themeID":"coast-road","gentleVisuals":true,"holdPedal":"sostenuto","breath":{"enabled":false}}"#
        try Data(old.utf8).write(to: settingsURL)
        let loaded = SettingsStore(directory: dir).load()
        XCTAssertEqual(loaded.themeID, "coast-road")
        XCTAssertEqual(loaded.holdPedal, .sostenuto)
        XCTAssertEqual(loaded.excitement, ExcitementSettings())
        let defaults = loaded.excitement
        XCTAssertTrue(defaults.autoEnergy)
        XCTAssertEqual(defaults.moments, .some)
        XCTAssertEqual(defaults.surprises, .rare)
        XCTAssertTrue(defaults.buildAndDrop)

        let bad = #"{"themeID":"coast-road","excitement":7}"#
        try Data(bad.utf8).write(to: settingsURL)
        let fixed = SettingsStore(directory: dir).load()
        XCTAssertEqual(fixed.themeID, "coast-road", "the rest of the file still loads")
        XCTAssertEqual(fixed.excitement, ExcitementSettings())

        let partial = #"{"excitement":{"moments":"lots","buildAndDrop":false}}"#
        try Data(partial.utf8).write(to: settingsURL)
        let some = SettingsStore(directory: dir).load().excitement
        XCTAssertEqual(some.moments, .lots)
        XCTAssertFalse(some.buildAndDrop)
        XCTAssertEqual(some.surprises, .rare)
        XCTAssertTrue(some.autoEnergy)

        let store = SettingsStore(directory: dir)
        var s = AppSettings.default
        s.excitement = ExcitementSettings(autoEnergy: false, manualEnergy: 0.25, moments: .off, surprises: .often, buildAndDrop: false)
        try store.save(s)
        let back = store.load()
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.excitement.manualEnergy, 0.25)
    }

    // MARK: - Through the director

    private func director() -> SceneDirector {
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        d.sky.reset(settings: s)
        return d
    }

    /// Hammers fff four-note chords at 8 a second for `seconds` and returns the moments the director handed out.
    private func hammer(_ d: SceneDirector, seconds: Double) -> [BigMoment] {
        var moments: [BigMoment] = []
        let steps = Int(seconds * 60)
        for i in 1...steps {
            let t = Double(i) / 60
            if i % 8 == 0 {
                let chord: [PerformanceEvent] = [36, 40, 43, 48].map { .noteOn(note: $0, velocity: 1) }
                d.handle(chord, at: t)
            }
            if i % 8 == 4 {
                let release: [PerformanceEvent] = [36, 40, 43, 48].map { .noteOff(note: $0) }
                d.handle(release, at: t)
            }
            _ = d.step(dt: 1.0 / 60, t: t, quality: .lite)
            if let m = d.excitementFrame.moment { moments.append(m) }
        }
        return moments
    }

    /// Gentle visuals hold Lots to Some (spec §5): over ten hammered seconds no more moments than Some's cooldown allows.
    func testGentleVisualsHoldBigMomentsToSome() {
        let lots = director()
        var settings = ExcitementSettings()
        settings.moments = .lots
        lots.excitementSettings = settings
        let plain = hammer(lots, seconds: 10).count
        XCTAssertGreaterThanOrEqual(plain, 3, "Lots fires every 2.5 s")
        let gentle = director()
        gentle.excitementSettings = settings
        var controls = SceneControls()
        controls.gentle = true
        gentle.controls = controls
        let held = hammer(gentle, seconds: 10).count
        XCTAssertGreaterThanOrEqual(held, 1)
        XCTAssertLessThanOrEqual(held, 2, "gentle visuals hold Lots to Some")
        XCTAssertEqual(gentle.excitementSettings.moments, .lots, "your own setting is untouched")
    }

    /// Reduce Motion (spec §5): the drawn Energy stops at 0.5 and a moment plays at half its strength; the playing's own
    /// Energy is untouched.
    func testReduceMotionHalvesMomentsAndCapsEnergy() throws {
        let plain = director()
        let full = try XCTUnwrap(hammer(plain, seconds: 1).first)
        let calm = director()
        var controls = SceneControls()
        controls.reduceMotion = true
        calm.controls = controls
        let half = try XCTUnwrap(hammer(calm, seconds: 1).first)
        XCTAssertEqual(half.strength, full.strength * Excitement.reducedMoment, accuracy: 1e-5)
        XCTAssertEqual(half.kind, full.kind)
        XCTAssertEqual(half.low, full.low)
        _ = hammer(calm, seconds: 2)
        let e = calm.excitementFrame
        XCTAssertGreaterThan(e.energy, 0.6, "the playing's own Energy")
        XCTAssertLessThanOrEqual(e.visualEnergy, 0.5, "the world draws at most half")
        XCTAssertTrue(e.reduceMotion)
    }

    /// The sleep fade turns big moments (and surprises) off: Small Wins' dim reaches Excitement through the director.
    func testTheSleepFadeStopsMoments() {
        let d = director()
        var controls = SceneControls()
        controls.sleepDim = 0.3
        d.controls = controls
        XCTAssertTrue(hammer(d, seconds: 4).isEmpty)
    }

    /// The director's controls reach Excitement: big moments Off fire nothing, and Manual holds the Energy at its dial.
    func testTheSettingsReachTheDirector() {
        let off = director()
        var settings = ExcitementSettings()
        settings.moments = .off
        off.excitementSettings = settings
        XCTAssertTrue(hammer(off, seconds: 3).isEmpty)
        let manual = director()
        var held = ExcitementSettings()
        held.autoEnergy = false
        held.manualEnergy = 0.7
        manual.excitementSettings = held
        _ = manual.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .lite)
        XCTAssertEqual(manual.excitementFrame.energy, 0.7, accuracy: 1e-6)
    }
}
