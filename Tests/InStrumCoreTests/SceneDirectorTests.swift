import XCTest
@testable import InStrumCore

final class SceneDirectorTests: XCTestCase {
    func director(_ id: String = ButterflyGardenModel.id) -> SceneDirector {
        SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
    }

    func testRegistryListsBothThemes() {
        XCTAssertEqual(Array(ThemeRegistry.all.map(\.id).prefix(2)), [MidnightSteinwayModel.id, ButterflyGardenModel.id])
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == MoonlitLakeModel.id })
    }
    func testUnknownThemeFallsBack() {
        XCTAssertEqual(ThemeRegistry.resolve("galaxy-of-the-future"), MidnightSteinwayModel.id)
        XCTAssertEqual(director("nope").themeID, MidnightSteinwayModel.id)
    }
    func testDirectorRoutesEventsToTheme() {
        let d = director()
        d.handle([.noteOn(note: 60, velocity: 0.8)], at: 0)
        let f = d.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .high) as? GardenFrame
        XCTAssertEqual(f?.butterflies.count, 1)
    }
    func testVelocityReachesEnergyRole() {
        let d = director()
        d.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        _ = d.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertGreaterThan(d.lastRoles[.energy], 0.9)
    }
    func testSwitchingThemeWhileHoldingIsClean() {
        let d = director(MidnightSteinwayModel.id)
        d.handle([.pedal(down: true, amount: 1), .noteOn(note: 60, velocity: 0.9), .noteOn(note: 64, velocity: 0.9), .noteOn(note: 67, velocity: 0.9)], at: 0)
        _ = d.step(dt: 0.1, t: 0.1, quality: .high)
        d.switchTheme(to: ButterflyGardenModel.id, state: ThemeState())
        let g = d.step(dt: 1.0 / 60, t: 0.12, quality: .high) as? GardenFrame
        XCTAssertEqual(g?.butterflies.count, 0)
        XCTAssertTrue(g?.keys.allSatisfy { !$0.pressed } ?? false)
        d.switchTheme(to: MidnightSteinwayModel.id, state: ThemeState())
        let s = d.step(dt: 1.0 / 60, t: 0.14, quality: .high) as? SteinwayFrame
        XCTAssertTrue(s?.scene.keys.allSatisfy { !$0.pressed && $0.glow == 0 } ?? false)
    }
    func testThemeStateAppliedOnSwitch() {
        let d = director(MidnightSteinwayModel.id)
        d.switchTheme(to: ButterflyGardenModel.id, state: ThemeState(values: ["time": .choice("Moonlight")], macros: [.speed: 0.5]))
        XCTAssertEqual(d.parameters.choice("time"), "Moonlight")
        XCTAssertEqual(d.parameters.macros[.speed], 0.5)
        XCTAssertEqual(d.themeID, ButterflyGardenModel.id)
    }
    func testMidnightSteinwayParametersValid() { assertValidParameters(MidnightSteinwayModel.parameters) }
    func testSteinwayGlowFollowsVelocity() {
        let d = director(MidnightSteinwayModel.id)
        d.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        let s = d.step(dt: 0, t: 0, quality: .high) as? SteinwayFrame
        XCTAssertEqual(s?.scene.keys.first { $0.key.note == 60 }?.glow ?? 0, 1, accuracy: 0.01)
    }

    func testRegistryKeepsOldThemes() {
        for (id, specs, targets) in [(MidnightSteinwayModel.id, MidnightSteinwayModel.parameters, MidnightSteinwayModel.macroTargets),
                                     (ButterflyGardenModel.id, ButterflyGardenModel.parameters, ButterflyGardenModel.macroTargets)] {
            XCTAssertEqual(ThemeRegistry.resolve(id), id)
            XCTAssertEqual(ThemeRegistry.parameters(for: id).map(\.id), specs.map(\.id))
            XCTAssertEqual(Set(ThemeRegistry.macroTargets(for: id).keys), Set(targets.keys))
            XCTAssertNotNil(ThemeRegistry.all.first { $0.id == id })
        }
        XCTAssertEqual(ThemeRegistry.all.first?.id, MidnightSteinwayModel.id)
        XCTAssertEqual(Set(ThemeRegistry.entries.map(\.id)).count, ThemeRegistry.entries.count, "unique ids")
    }

    /// A model that records what it is given.
    struct Probe: ThemeModel, MoodAware, SkyAware {
        static let id = "probe", displayName = "Probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var mood = Mood.neutral
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> (Mood, SkyState?) {
            (mood, sky)
        }
    }

    func testMoodAndSkyReachModels() {
        let d = SceneDirector(entry: ThemeEntry.make(Probe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"
        d.sky.settings = s
        d.mood = .dreamy
        let f = d.step(dt: 1.0 / 60, t: 0, quality: .high) as? (Mood, SkyState?)
        XCTAssertEqual(f?.0, .dreamy)
        XCTAssertNotNil(f?.1 ?? nil)
        XCTAssertLessThan(f?.1?.sun.altitude ?? 0, 0, "22:00 is night")
    }

    /// A world that holds the light (golden hour by default).
    struct HoldProbe: ThemeModel, SkyAware {
        static let id = "hold-probe", displayName = "Hold probe"
        static let parameters: [ParamSpec] = [SkyHold.spec(default: .goldenHour)]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    func testWorldHoldReachesTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 2; s.cityID = "melbourne"
        let held = SceneDirector(entry: ThemeEntry.make(HoldProbe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        held.sky.settings = s
        _ = held.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertEqual(held.lastSky?.sun.altitude ?? 0, 5, accuracy: 1e-9)
        let lake = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        lake.sky.settings = s
        _ = lake.step(dt: 1.0 / 60, t: 0, quality: .high)
        XCTAssertLessThan(lake.lastSky?.sun.altitude ?? 0, -20, "the lake follows the real 2 am sky")
        XCTAssertEqual(SkyHold.spec(default: .blueHour).defaultValue, .choice("Blue hour"))
        XCTAssertEqual(SkyHold.allCases.map(\.rawValue), ["Follow the sky", "Golden hour", "Blue hour", "Pastel dawn", "Deep night"])
    }

    /// A world that shows the aurora always (as the fjord does).
    struct AuroraProbe: ThemeModel, SkyAware {
        static let id = "aurora-probe", displayName = "Aurora probe"
        static let parameters: [ParamSpec] = [AuroraMode.spec(default: .always)]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    /// The director passes the world's aurora mode each step; worlds without the parameter follow the sky.
    func testDirectorPassesAuroraMode() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        let always = SceneDirector(entry: ThemeEntry.make(AuroraProbe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        always.sky.settings = s
        always.clock = { Date(timeIntervalSince1970: 1_793_000_000) }
        for i in 1...10 { _ = always.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertGreaterThan(always.lastSky?.aurora ?? 0, 0.5, "Always, even over Melbourne")
        let never = SceneDirector(entry: ThemeEntry.make(AuroraProbe.self), state: ThemeState(values: ["aurora.mode": .choice("Never")]),
                                  reaction: ReactionPresets.expressivePianist)
        never.sky.settings = s
        for i in 1...10 { _ = never.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertEqual(never.lastSky?.aurora, 0)
        // The lake has no aurora parameter: it follows Melbourne's quiet sky (the default seed's Kp is low).
        let lake = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        lake.sky.settings = s
        for i in 1...10 { _ = lake.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertLessThan(lake.lastSky?.aurora ?? 1, 0.05)
        XCTAssertEqual(lake.parameters.choice("aurora.mode"), "", "a missing parameter reads as no choice")
    }

    /// A world whose meteors are always on (as a world may choose).
    struct MeteorProbe: ThemeModel, SkyAware {
        static let id = "meteor-probe", displayName = "Meteor probe"
        static let parameters: [ParamSpec] = [MeteorMode.spec(default: .always)]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    /// The director passes the world's meteor mode each step (spec §7.1): "Never" gives no meteors at all; a world
    /// without the parameter follows the calendar; leaving an "Always" world leaves its shower behind.
    func testMeteorModeReachesTheSky() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 21; s.frozenPhase = 0; s.cityID = "tokyo"
        s.weatherMode = .pick; s.weather = .clear; s.meteorRate = 10
        let lull = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-20T03:00:00Z"))   // no shower in the calendar
        func director(_ entry: ThemeEntry, _ state: ThemeState = ThemeState()) -> SceneDirector {
            let d = SceneDirector(entry: entry, state: state, reaction: ReactionPresets.expressivePianist)
            d.sky.reset(settings: s)
            d.clock = { lull }
            return d
        }
        let always = director(ThemeEntry.make(MeteorProbe.self))
        for i in 1...120 { _ = always.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertEqual(always.lastSky?.shower?.code, "ALW")
        XCTAssertGreaterThan(always.lastSky?.meteorRate ?? 0, 100)
        XCTAssertGreaterThan(always.sky.meteorSky.tally[MeteorShowers.alwaysIndex] ?? 0, 0)
        // Never: no meteors, not even sporadic ones.
        let never = director(ThemeEntry.make(MeteorProbe.self), ThemeState(values: ["meteors.mode": .choice("Never")]))
        var any = false
        for i in 1...120 {
            _ = never.step(dt: 1, t: Double(i), quality: .high)
            any = any || !(never.lastSky?.meteors.isEmpty ?? true)
        }
        XCTAssertFalse(any)
        XCTAssertNil(never.lastSky?.shower)
        XCTAssertEqual(never.lastSky?.meteorRate, 0)
        XCTAssertTrue(never.sky.meteorSky.tally.isEmpty)
        // A world without the parameter follows the calendar: this night, only sporadic meteors.
        let plain = director(ThemeEntry.make(Probe.self))
        _ = plain.step(dt: 1, t: 1, quality: .high)
        XCTAssertEqual(plain.parameters.choice("meteors.mode"), "", "a missing parameter reads as no choice")
        XCTAssertNil(plain.lastSky?.shower)
        XCTAssertGreaterThan(plain.lastSky?.meteorRate ?? 0, 0)
        XCTAssertLessThan(plain.lastSky?.meteorRate ?? 999, always.lastSky?.meteorRate ?? 0)
        // Leaving the "Always" world for the lake (which follows the calendar) leaves its shower behind.
        always.switchTheme(to: MoonlitLakeModel.id, state: ThemeState())
        _ = always.step(dt: 1, t: 121, quality: .high)
        XCTAssertEqual(always.parameters.choice("meteors.mode"), "Follow the calendar")
        XCTAssertNil(always.lastSky?.shower)
    }

    /// Small Wins' seams change nothing by default: the renderers step by the frame's own dt, the exposure is
    /// untouched, the report carries the sky and the key, and the ambience is the frame's own with the key on it (a
    /// theme without a soundscape sends silence, with the key).
    func testDefaultControlsChangeNothing() throws {
        let cMajor: [UInt8] = [60, 62, 64, 65, 67, 69, 71, 72] + [55, 59, 62, 65] + [48, 52, 55, 60]
        func playing(_ id: String) -> SceneDirector {
            let d = SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            d.clock = { Date(timeIntervalSince1970: 1_793_000_000) }
            for (i, n) in cMajor.enumerated() {
                d.handle([.noteOn(note: n, velocity: 0.7)], at: Double(i) * 0.25)
                d.handle([.noteOff(note: n)], at: Double(i) * 0.25 + 0.2)
            }
            return d
        }
        let lake = playing(MoonlitLakeModel.id)
        XCTAssertEqual(lake.controls, SceneControls())
        let key = try XCTUnwrap(lake.key)
        XCTAssertEqual(key, AmbienceKey(root: 0, major: true))
        var t = 4.0
        for i in 0..<60 {
            let dt = i % 3 == 2 ? 1.0 / 30 : 1.0 / 60
            t += dt
            let frame = lake.step(dt: dt, t: t, quality: .lite)
            XCTAssertEqual(lake.visualDt, dt)
            XCTAssertEqual(lake.exposureScale, 1)
            XCTAssertFalse(lake.holding)
            XCTAssertNotNil(lake.lastSky)
            XCTAssertEqual(lake.report, SceneReport(holding: false, sky: lake.lastSky, key: key))
            var expected = try XCTUnwrap((frame as? AmbienceProviding)?.ambience)
            expected.key = key
            XCTAssertEqual(lake.ambience(for: frame, at: t), expected)
        }
        XCTAssertGreaterThan(lake.ambience(for: lake.step(dt: 1.0 / 60, t: t, quality: .lite), at: t).level(.water), 0.5)
        let steinway = playing(MidnightSteinwayModel.id)
        let frame = steinway.step(dt: 1.0 / 60, t: 4, quality: .lite)
        XCTAssertEqual(steinway.ambience(for: frame, at: 4), AmbienceScene(key: key))
        XCTAssertEqual(steinway.report, SceneReport(holding: false, sky: nil, key: key))
        XCTAssertEqual(steinway.visualDt, 1.0 / 60)
    }

    /// What a pulse-aware probe saw on its latest step.
    struct PulseSeen: Equatable {
        var pulse: InstrumentPulse?
        var steps: Int
    }

    /// A model that wants the instrument's pulse (as the submarine does), and no sky.
    struct PulseProbe: ThemeModel, PulseAware {
        static let id = "pulse-probe", displayName = "Pulse probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var pulse: InstrumentPulse?
        var steps = 0
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> PulseSeen {
            steps += 1
            return PulseSeen(pulse: pulse, steps: steps)
        }
    }

    /// The director hands the instrument's pulse (spec §7.6) to a pulse-aware model before every step, a world or not:
    /// as it changes and when it goes. Models that don't want it step on as before, and it carries over a world switch to
    /// the submarine, whose creatures then blink on the arp's grid (127.1 ms at 118 BPM).
    func testDirectorHandsThePulseToPulseAwareWorlds() throws {
        let d = SceneDirector(entry: ThemeEntry.make(PulseProbe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        XCTAssertFalse(ThemeEntry.make(PulseProbe.self).make().wantsSky, "it needs no sky")
        let none = try XCTUnwrap(d.step(dt: 1.0 / 60, t: 0, quality: .high) as? PulseSeen)
        XCTAssertNil(none.pulse, "no instrument pulse yet")
        d.instrumentPulse = InstrumentPulse(bpm: 118, gate: 0.6)
        let first = try XCTUnwrap(d.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .high) as? PulseSeen)
        XCTAssertEqual(first.pulse, InstrumentPulse(bpm: 118, gate: 0.6), "handed over before the step that uses it")
        XCTAssertEqual(first.steps, 2)
        d.instrumentPulse = InstrumentPulse(bpm: 100, gate: 0.4)
        XCTAssertEqual(try XCTUnwrap(d.step(dt: 1.0 / 60, t: 2.0 / 60, quality: .high) as? PulseSeen).pulse,
                       InstrumentPulse(bpm: 100, gate: 0.4), "as it changes")
        d.instrumentPulse = nil
        XCTAssertNil(try XCTUnwrap(d.step(dt: 1.0 / 60, t: 3.0 / 60, quality: .high) as? PulseSeen).pulse, "and when it goes")

        // A model that doesn't want it steps on as before.
        let plain = SceneDirector(entry: ThemeEntry.make(Probe.self), state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        plain.instrumentPulse = InstrumentPulse(bpm: 118, gate: 0.6)
        XCTAssertNotNil(plain.step(dt: 1.0 / 60, t: 0, quality: .high) as? (Mood, SkyState?))

        // Over a switch to the submarine: a held C4 blinks on the arp's grid from its note.
        let sub = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        sub.sky.reset(settings: s)
        sub.instrumentPulse = InstrumentPulse(bpm: 118, gate: 0.6)
        sub.switchTheme(to: SubmarineWindowModel.id, state: ThemeState())
        let dt = 0.001
        _ = sub.step(dt: dt, t: dt, quality: .high)
        sub.handle([.noteOn(note: 60, velocity: 0.8)], at: 2 * dt)
        var glow: [(t: Double, g: Float)] = [(dt, 0)]
        for i in 2...600 {
            let f = try XCTUnwrap(sub.step(dt: dt, t: Double(i) * dt, quality: .high) as? SubFrame)
            glow.append((Double(i) * dt, f.creatures.first { $0.note == 60 }?.glow ?? 0))
        }
        let peaks = (1..<(glow.count - 1)).filter { glow[$0].g > glow[$0 - 1].g && glow[$0].g >= glow[$0 + 1].g }.map { glow[$0].t }
        XCTAssertGreaterThanOrEqual(peaks.count, 4)
        XCTAssertEqual(peaks.first ?? 0, 2 * dt, accuracy: 0.002, "from the note")
        for (a, b) in zip(peaks, peaks.dropFirst()) { XCTAssertEqual((b - a) * 1000, 127.1, accuracy: 2) }
    }

    /// A world that chooses its own storm sky (Storms spec §6, §8.1): no crawlers, sheet lightning often, a supercell
    /// held at its Core.
    struct StormSkyProbe: ThemeModel, SkyAware {
        static let id = "storm-sky-probe", displayName = "Storm sky probe"
        static let parameters: [ParamSpec] = [
            SkyExtraMode.spec(id: SkyExtraMode.crawlersID, name: "Anvil crawlers", help: "Spider lightning", default: .off),
            SkyExtraMode.spec(id: SkyExtraMode.sheetID, name: "Sheet lightning", help: "Heat lightning", default: .often),
            SupercellStage.spec(default: .core),
        ]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    /// The director reads the storm sky's world parameters every step (`crawlers.mode`, `sheet.mode`, `supercell.stage`)
    /// and hands on the world's Random Beautiful table: a world without them follows the Sky extras settings and has no
    /// supercell; a world with them wins over the settings; leaving it leaves them behind, and the next world's table
    /// rides along.
    func testStormSkyReachesTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "melbourne"; s.weatherMode = .pick
        s.weather = .thunderheads; s.crawlersMode = .often; s.sheetMode = .off
        let night = Date(timeIntervalSince1970: 1_793_000_000)
        let lake = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        lake.sky.reset(settings: s)
        lake.clock = { night }
        for i in 1...300 { _ = lake.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertGreaterThan(lake.sky.crawlerSky.spawned, 0, "the settings' Often")
        XCTAssertEqual(lake.sky.sheetSky.spawned, 0, "the settings' Off")
        XCTAssertEqual(lake.lastSky?.supercell, 0)
        XCTAssertEqual(lake.parameters.choice(SkyExtraMode.crawlersID), "", "the lake has no parameter of its own")
        XCTAssertEqual(lake.sky.randomExtras, [.gustFront: 0.3], "the lake's table: storms appear there, it isn't dry")

        let probe = SceneDirector(entry: ThemeEntry.make(StormSkyProbe.self), state: ThemeState(),
                                  reaction: ReactionPresets.expressivePianist)
        probe.sky.reset(settings: s)
        probe.clock = { night }
        for i in 1...300 { _ = probe.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertEqual(probe.sky.crawlerSky.spawned, 0, "the world's Off beats the settings' Often")
        XCTAssertGreaterThan(probe.sky.sheetSky.spawned, 0, "the world's Often beats the settings' Off")
        XCTAssertEqual(probe.lastSky?.supercell, 1)
        XCTAssertEqual(probe.lastSky?.supercellPhase ?? 0, 0.5, accuracy: 1e-6, "held at its Core")
        XCTAssertEqual(probe.sky.randomExtras, [:], "no table of its own")
        // Its stage is a parameter like any other: Clearing, and the storm plays on to it.
        probe.parameters.set(SupercellStage.id, .choice("Clearing"))
        for i in 301...360 { _ = probe.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertEqual(probe.lastSky?.supercellPhase ?? 0, Float(5.0 / 6), accuracy: 1e-6)
        // Leaving it for the coast road: no supercell, the settings' crawlers again, and the road's table.
        let before = probe.sky.crawlerSky.spawned
        probe.switchTheme(to: CoastRoadModel.id, state: ThemeState())
        for i in 361...660 { _ = probe.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertEqual(probe.lastSky?.supercell, 0)
        XCTAssertGreaterThan(probe.sky.crawlerSky.spawned, before)
        XCTAssertEqual(probe.sky.randomExtras, [.gustFront: 0.3, .virga: 0.5])
    }

    func testMoodLookIsNeutralAtHalf() {
        let n = Mood.neutral
        XCTAssertEqual(MoodLook.exposure(n), 1, accuracy: 1e-6)
        XCTAssertEqual(MoodLook.warmthOffset(n), 0, accuracy: 1e-6)
        for f in [MoodLook.hazeScale, MoodLook.driftScale, MoodLook.reactionScale, MoodLook.lingerScale] { XCTAssertEqual(f(n), 1, accuracy: 1e-6) }
        XCTAssertEqual(MoodLook.ambienceCloseness(base: 0.5, n), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MoodLook.ambienceDensity(n), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(MoodLook.hazeScale(.serene), MoodLook.hazeScale(n))
        XCTAssertLessThan(MoodLook.reactionScale(.serene), MoodLook.reactionScale(n))
        XCTAssertGreaterThan(MoodLook.driftScale(.dreamy), MoodLook.driftScale(.serene))
        XCTAssertLessThan(MoodLook.ambienceCloseness(base: 0.5, .dreamy), 0.5, "spacious moods sound further away")
        XCTAssertEqual(MoodLook.ambienceCloseness(base: 0.05, .dreamy), 0, accuracy: 1e-9, "clamped")
    }
}
