import XCTest
import simd
@testable import InStrumCore

final class WorldTests: XCTestCase {
    // MARK: - Lake Ripples

    func testRippleAtKeyPosition() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        let key = KeyboardLayout.key(for: 60)!
        let centre = key.x + key.width / 2
        XCTAssertEqual(lake.ripples.first?.x ?? -1, LakeRipples.lakeX(keyCentre: centre), accuracy: 0.01)
        XCTAssertEqual(LakeRipples.lakeX(keyCentre: centre), centre, accuracy: 0.01)
        lake.noteOn(30, velocity: 100, pedal: false, at: 1)
        lake.noteOn(100, velocity: 100, pedal: false, at: 2)
        XCTAssertLessThan(lake.ripples[1].depth, lake.ripples[2].depth, "low notes nearer")
    }

    func testHarderMakesBiggerRipples() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 127, pedal: false, at: 0)
        lake.noteOn(62, velocity: 40, pedal: false, at: 1)
        XCTAssertGreaterThan(lake.ripples[0].strength, 1.5 * lake.ripples[1].strength)
    }

    func testPedalLingers() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        lake.noteOn(62, velocity: 100, pedal: true, at: 1)
        XCTAssertGreaterThanOrEqual(lake.ripples[1].lifetime, 1.5 * lake.ripples[0].lifetime)
    }

    func testHeldNotesRaiseGlitter() {
        var lake = LakeRipples()
        for (i, n) in [60, 64, 67, 72].enumerated() { lake.noteOn(UInt8(n), velocity: 90, pedal: false, at: Double(i) * 0.2) }
        for _ in 0..<60 { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertGreaterThan(lake.glitter, 0.8)
        for n in [60, 64, 67, 72] { lake.noteOff(UInt8(n)) }
        for _ in 0..<180 { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertLessThan(lake.glitter, 0.2)
    }

    func testChordReleasesFireflies() {
        var chord = LakeRipples()
        chord.noteOn(60, velocity: 90, pedal: false, at: 0)
        chord.noteOn(64, velocity: 90, pedal: false, at: 0.015)
        chord.noteOn(67, velocity: 90, pedal: false, at: 0.03)
        chord.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertGreaterThanOrEqual(chord.fireflies.count, 2)
        XCTAssertLessThanOrEqual(chord.fireflies.count, 5)
        var single = LakeRipples()
        for i in 0..<6 { single.noteOn(UInt8(60 + i), velocity: 90, pedal: false, at: Double(i) * 0.2); single.step(dt: 0.2, roles: RoleValues()) }
        XCTAssertEqual(single.fireflies.count, 0)
        // They rise, drift and fade within 4–6 s.
        let start = chord.fireflies.map(\.position.y)
        for _ in 0..<120 { chord.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertGreaterThan(chord.fireflies.map(\.position.y).reduce(0, +), start.reduce(0, +))
        for _ in 0..<(6 * 60) { chord.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertEqual(chord.fireflies.count, 0)
    }

    func testRippleCapAndBudget() {
        var lake = LakeRipples()
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<2000 { lake.noteOn(UInt8(21 + i % 88), velocity: 100, pedal: true, at: Double(i) * 0.001) }
        lake.step(dt: 1.0 / 60, roles: RoleValues())
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThanOrEqual(lake.ripples.count, LakeRipples.cap)
        XCTAssertLessThan(elapsed, 0.1, "2000 notes and a step: no worse than 50 µs a note in a debug build on CI")
        let t0 = CFAbsoluteTimeGetCurrent()
        lake.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, 0.008)
    }

    func testSmoothBudgetKeepsTheStrongestRings() {
        // 40 rings: 32 fresh strong ones, then 8 faint old ones added last.
        var rings: [Ripple] = (0..<32).map { Ripple(x: Float($0) / 32, depth: 0.5, age: 0.2, strength: 1, lifetime: 3) }
        rings += (0..<8).map { Ripple(x: Float($0) / 8, depth: 0.2, age: 2.8, strength: 0.3, lifetime: 3) }
        let kept = LakeRipples.visible(rings, limit: 32)
        XCTAssertEqual(kept.count, 32)
        XCTAssertTrue(kept.allSatisfy { $0.strength == 1 }, "the faint, nearly spent rings are the ones left out")
        XCTAssertEqual(LakeRipples.visible(rings, limit: 64).count, 40)
        // The pick is stable: the same set every frame while nothing changes.
        XCTAssertEqual(LakeRipples.visible(rings, limit: 32), kept)
    }

    func testRipplesFadeAway() {
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        for _ in 0..<(10 * 60) { lake.step(dt: 1.0 / 60, roles: RoleValues()) }
        XCTAssertTrue(lake.ripples.isEmpty)
    }

    // MARK: - Moonlit Lake

    private func lakeFrame(hour: Double, weather: WeatherKind = .clear, notes: [UInt8] = []) -> LakeFrame? {
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        d.mood = .serene
        var frame: LakeFrame?
        for i in 0..<90 {   // three seconds for the sky to settle; the notes land in the last third of a second
            if i == 80 { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: Double(i) / 30) }
            frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LakeFrame
        }
        return frame
    }

    func testLakeIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(MoonlitLakeModel.id), MoonlitLakeModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == MoonlitLakeModel.id && $0.name == "Moonlit Lake" })
        assertValidParameters(MoonlitLakeModel.parameters)
    }

    func testLakeAmbienceFollowsSky() throws {
        let night = try XCTUnwrap(lakeFrame(hour: 23))
        let day = try XCTUnwrap(lakeFrame(hour: 13))
        XCTAssertGreaterThan(night.ambience.level(.crickets), 0.5)
        XCTAssertEqual(day.ambience.level(.crickets), 0)
        XCTAssertGreaterThan(night.ambience.level(.owl), 0)
        XCTAssertEqual(night.ambience.level(.water), 0.8, accuracy: 1e-9)
        let rain = try XCTUnwrap(lakeFrame(hour: 23, weather: .rain))
        XCTAssertGreaterThan(rain.ambience.level(.rainOnWater), 0.6)
        XCTAssertGreaterThan(night.ambience.nightCool, 0)
        XCTAssertEqual(night.ambience.closeness, MoodLook.ambienceCloseness(base: 0.5, .serene), accuracy: 1e-9)
        XCTAssertEqual(night.mood, .serene)
        let dawn = try XCTUnwrap(lakeFrame(hour: 7.1))
        XCTAssertGreaterThan(dawn.ambience.level(.dawnChorus), 0, "birds as the sun comes up")
    }

    func testLakeFrameCarriesRipplesAndKeys() throws {
        let f = try XCTUnwrap(lakeFrame(hour: 22, notes: [60, 64]))
        XCTAssertEqual(f.ripples.count, 2)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue(f.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertLessThan(f.sky.sun.altitude, -6)
    }

    // MARK: - Golden Hour Beach

    private func beachFrames(hour: Double = 13, seconds: Double = 30, notes: [UInt8] = [60, 64, 67], weather: WeatherKind = .clear,
                             state: ThemeState = ThemeState()) -> [BeachFrame] {
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        var frames: [BeachFrame] = []
        for i in 0..<Int(seconds * 30) {
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: Double(i) / 30) }
            if let f = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BeachFrame { frames.append(f) }
        }
        return frames
    }

    func testBeachIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(GoldenHourBeachModel.id), GoldenHourBeachModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == GoldenHourBeachModel.id && $0.name == "Golden Hour Beach" })
        XCTAssertTrue(ThemeRegistry.isWorld(GoldenHourBeachModel.id))
        assertValidParameters(GoldenHourBeachModel.parameters)
        let params = ThemeRegistry.parameterSet(for: GoldenHourBeachModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Golden hour")
        XCTAssertEqual(params.choice("visual"), "Tide Lines")
    }

    func testBeachFrame() throws {
        let frames = beachFrames()
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(frames.count, 900)
        XCTAssertTrue(frames.contains { !$0.lines.isEmpty }, "notes write lines")
        XCTAssertTrue(frames.allSatisfy { (0...1).contains($0.washFront) })
        XCTAssertEqual(last.sky.sun.altitude, 5, accuracy: 1e-6, "held at golden hour although it's 1 pm")
        XCTAssertEqual(last.keys.count, 88)
        // A wave is heard on exactly the frames where one broke.
        var broke = 0
        for (a, b) in zip(frames, frames.dropFirst()) where b.recent.last?.breakTime != a.recent.last?.breakTime { broke += 1 }
        XCTAssertEqual(frames.filter { $0.ambience.wave != nil }.count, broke)
        XCTAssertGreaterThan(broke, 1)
        XCTAssertEqual(last.ambience.level(.gulls), 0, "gulls are off until they pass the ear test")
        XCTAssertEqual(last.ambience.level(.surf), 0.9, accuracy: 1e-9)
        XCTAssertEqual(last.ambience.surfDistance, 0.15, accuracy: 1e-9)
    }

    func testBeachWarpOptionStreaksInstead() throws {
        var state = ThemeState(); state.values["visual"] = .choice("Galaxy Warp")
        let frames = beachFrames(seconds: 3, state: state)
        let last = try XCTUnwrap(frames.last)
        XCTAssertNotNil(last.warp)
        XCTAssertTrue(frames.allSatisfy { $0.lines.isEmpty })
    }

    func testStormySeaIsBigger() throws {
        let calm = try XCTUnwrap(beachFrames(seconds: 2, notes: []).last), storm = try XCTUnwrap(beachFrames(seconds: 2, notes: [], weather: .storm).last)
        XCTAssertGreaterThan(storm.swellScale, calm.swellScale)
    }

    // MARK: - Coast Road

    /// The demo performance on the coast road at 60 fps (frames every step).
    private func roadFrames(seconds: Double = 12, hour: Double = 13, state: ThemeState = ThemeState()) -> [RoadFrame] {
        let d = SceneDirector(themeID: CoastRoadModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        d.sky.reset(settings: s)
        var perf = PerformanceState()
        let script = ScriptedPerformance.demo
        var next = 0
        var frames: [RoadFrame] = []
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            var events: [PerformanceEvent] = []
            while next < script.count, script[next].time <= t { events += perf.apply(script[next].message, at: script[next].time); next += 1 }
            d.handle(events, at: t)
            if let f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? RoadFrame { frames.append(f) }
        }
        return frames
    }

    func testRoadIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(CoastRoadModel.id), CoastRoadModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == CoastRoadModel.id && $0.name == "Coast Road" })
        XCTAssertTrue(ThemeRegistry.isWorld(CoastRoadModel.id))
        assertValidParameters(CoastRoadModel.parameters)
        let params = ThemeRegistry.parameterSet(for: CoastRoadModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Blue hour")
        XCTAssertEqual(params.choice("visual"), "Coast Lights")
    }

    func testRoadFrame() throws {
        let frames = roadFrames()
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(frames.count, 720)
        XCTAssertTrue(frames.contains { !$0.lights.isEmpty }, "notes light passing lights")
        XCTAssertTrue(frames.contains { $0.speed > CoastLights.cruise + 0.02 }, "playing speeds the car up")
        XCTAssertTrue(frames.allSatisfy { $0.speed <= 1 })
        for f in frames {
            XCTAssertEqual(f.ambience.speed, Double(f.speed), accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(f.roll), 1.5 * 0.5 + 1e-9)
            XCTAssertLessThanOrEqual(abs(f.yaw), 2 * 0.5 + 1e-9)
        }
        XCTAssertEqual(last.sky.sun.altitude, -6, accuracy: 1e-6, "held at blue hour although it's 1 pm")
        XCTAssertEqual(last.keys.count, 88)
        XCTAssertGreaterThan(last.distance, 100, "the car travels")
        XCTAssertEqual(last.ambience.level(.road), 0.8, accuracy: 1e-9)
        XCTAssertEqual(last.ambience.surfDistance, 0.9, accuracy: 1e-9)
        XCTAssertGreaterThan(last.ambience.level(.engine), 0)
        // Full sway stays within ±1.5° roll and ±2° yaw, with slow periods.
        let swaying = roadFrames(seconds: 20, state: ThemeState(values: ["sway": .number(1)]))
        XCTAssertLessThanOrEqual(swaying.map { abs($0.roll) }.max() ?? 9, 1.5 + 1e-9)
        XCTAssertLessThanOrEqual(swaying.map { abs($0.yaw) }.max() ?? 9, 2 + 1e-9)
        XCTAssertGreaterThan(swaying.map { abs($0.roll) }.max() ?? 0, 1.2)
        XCTAssertLessThan(zip(swaying, swaying.dropFirst()).map { abs($1.roll - $0.roll) }.max() ?? 9, 0.02, "never jerky")
    }

    func testRoadWarpOptionStreaksInstead() throws {
        let frames = roadFrames(seconds: 3, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(frames.last?.warp)
        XCTAssertTrue(frames.allSatisfy { $0.lights.isEmpty })
    }

    // MARK: - Galaxy Warp

    private func roles(energy: Double) -> RoleValues { var r = RoleValues(); r[.energy] = energy; return r }

    func testNotesLaunchStreaks() {
        var warp = GalaxyWarp()
        warp.noteOn(60, velocity: 120, at: 0)
        let f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame())
        XCTAssertGreaterThanOrEqual(f.streaks.count, 3)
        XCTAssertGreaterThan(f.streaks[0].brightness, 0.8)
        var low = GalaxyWarp(), high = GalaxyWarp()
        low.noteOn(21, velocity: 100, at: 0)
        high.noteOn(108, velocity: 100, at: 0)
        let a = low.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame()).streaks[0].direction
        let b = high.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame()).streaks[0].direction
        XCTAssertGreaterThan(acos(min(1, max(-1, simd_dot(a, b)))), 1.5, "lowest and highest notes fly different ways")
        var soft = GalaxyWarp()
        soft.noteOn(60, velocity: 30, at: 0)
        let s = soft.step(dt: 0.001, roles: RoleValues(), inputs: InputFrame())
        XCTAssertLessThan(s.streaks[0].brightness, f.streaks[0].brightness, "velocity sets brightness")
    }

    func testIntensitySetsWarpSpeed() {
        var warp = GalaxyWarp()
        var f = warp.step(dt: 0, roles: RoleValues(), inputs: InputFrame())
        for _ in 0..<60 { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame()) }
        XCTAssertGreaterThan(f.warpSpeed, 0.8)
        for _ in 0..<(6 * 60) { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 0), inputs: InputFrame()) }
        XCTAssertLessThan(f.warpSpeed, 0.15)
    }

    private func nebula(after notes: [UInt8]) -> WarpFrame {
        var warp = GalaxyWarp()
        for n in notes { warp.noteOn(n, velocity: 90, at: 0) }
        var f = warp.step(dt: 0, roles: RoleValues(), inputs: InputFrame())
        for _ in 0..<60 { f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame()) }
        return f
    }

    func testChordBloomsNebula() {
        let major = nebula(after: [60, 64, 67])
        XCTAssertGreaterThan(major.nebula, 0.5)
        XCTAssertTrue((0.72...0.84).contains(major.nebulaHue), "major is warm violet: \(major.nebulaHue)")
        let minor = nebula(after: [57, 60, 64])
        XCTAssertTrue((0.58...0.68).contains(minor.nebulaHue), "minor is deep blue: \(minor.nebulaHue)")
        let tense = nebula(after: [60, 66, 71])
        XCTAssertTrue((0.85...0.95).contains(tense.nebulaHue), "tense is magenta: \(tense.nebulaHue)")
        XCTAssertLessThan(nebula(after: [60]).nebula, 0.05, "one note is not a chord")
    }

    func testSilenceSettles() {
        var warp = GalaxyWarp()
        for i in 0..<20 { warp.noteOn(UInt8(40 + i), velocity: 110, at: Double(i) * 0.05) }
        var f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame())
        for i in 0..<20 { warp.noteOff(UInt8(40 + i)) }
        for _ in 0..<(8 * 60) { f = warp.step(dt: 1.0 / 60, roles: roles(energy: 0), inputs: InputFrame()) }
        XCTAssertEqual(f.streaks.count, 0)
        XCTAssertLessThan(f.warpSpeed, 0.15)
        XCTAssertLessThan(f.nebula, 0.1)
    }

    func testStreakSpawnsAreRationedPerStep() {
        var warp = GalaxyWarp()
        for i in 0..<400 { warp.noteOn(UInt8(21 + i % 88), velocity: 127, at: Double(i) * 0.0005) }   // a MIDI burst
        let first = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame())
        XCTAssertLessThanOrEqual(first.streaks.count, GalaxyWarp.maxSpawnsPerStep, "a burst can't fill the window in one frame")
        var f = first
        for _ in 0..<20 { f = warp.step(dt: 1.0 / 60, roles: RoleValues(), inputs: InputFrame()) }
        XCTAssertGreaterThan(f.streaks.count, GalaxyWarp.maxSpawnsPerStep, "the rest follow over the next frames")
        XCTAssertLessThanOrEqual(f.streaks.count, GalaxyWarp.cap)
    }

    func testWarpCapAndBudget() {
        var warp = GalaxyWarp()
        for i in 0..<2000 { warp.noteOn(UInt8(21 + i % 88), velocity: 127, at: Double(i) * 0.001) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let f = warp.step(dt: 1.0 / 60, roles: roles(energy: 1), inputs: InputFrame())
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, 0.008)
        XCTAssertLessThanOrEqual(f.streaks.count, GalaxyWarp.cap)
    }

    // MARK: - Spaceship Lounge

    private func loungeFrame(_ s: SkySettings, at now: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> LoungeFrame? {
        let d = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: s)
        d.clock = { now }
        d.mood = .dreamy
        var frame: LoungeFrame?
        for i in 0..<30 { frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LoungeFrame }
        return frame
    }

    func testLoungeIsRegistered() {
        XCTAssertEqual(ThemeRegistry.resolve(SpaceshipLoungeModel.id), SpaceshipLoungeModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == SpaceshipLoungeModel.id && $0.name == "Spaceship Lounge" })
        assertValidParameters(SpaceshipLoungeModel.parameters)
    }

    func testEarthFollowsRealSun() throws {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "london"; s.weatherMode = .pick; s.weather = .clear
        let noon = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"))
        let f = try XCTUnwrap(loungeFrame(s, at: noon))
        XCTAssertEqual(f.sky.subsolar.longitude, -4, accuracy: 1.5)
        // London at noon: the lounge floats over the day side.
        let below = Double(f.earthRotation) * 180 / .pi
        var gap = abs(below - f.sky.subsolar.longitude).truncatingRemainder(dividingBy: 360)
        if gap > 180 { gap = 360 - gap }
        XCTAssertLessThan(gap, 20)
    }

    func testLoungeHasNoWeather() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .rain
        let f = try XCTUnwrap(loungeFrame(s))
        XCTAssertEqual(f.ambience.level(.rainOnGlass), 0)
        XCTAssertEqual(f.ambience.level(.rainOnWater), 0)
        XCTAssertNil(f.ambience.thunder)
        XCTAssertEqual(f.sky.rain, 0)
        XCTAssertEqual(f.sky.cloudCover, 0)
        XCTAssertEqual(f.sky.starVisibility, 1)
        XCTAssertEqual(f.ambience.level(.shipHum), 0.8, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.airFlow), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.chime), 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.ambience.level(.hullTicks), 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.mood, .dreamy)
    }

    func testGalaxyWarpCanRunOnLake() throws {
        XCTAssertTrue(MoonlitLakeModel.visuals.contains("Galaxy Warp"))
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]),
                              reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        d.sky.reset(settings: s)
        d.handle([.noteOn(note: 60, velocity: 0.9), .noteOn(note: 72, velocity: 0.9)], at: 0)
        let f = try XCTUnwrap(d.step(dt: 1.0 / 30, t: 0, quality: .high) as? LakeFrame)
        let warp = try XCTUnwrap(f.warp)
        XCTAssertGreaterThan(warp.streaks.count, 0)
        XCTAssertTrue(f.ripples.isEmpty, "Galaxy Warp replaces the ripples")
        // Lake Ripples (the default) has no warp.
        let r = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        r.handle([.noteOn(note: 60, velocity: 0.9)], at: 0)
        let rf = try XCTUnwrap(r.step(dt: 1.0 / 30, t: 0, quality: .high) as? LakeFrame)
        XCTAssertNil(rf.warp)
        XCTAssertEqual(rf.ripples.count, 1)
    }

    // MARK: - After the rain and blizzards in every outdoor world

    private func scenes(_ sky: SkyState) -> [(String, AmbienceScene)] {
        var lake = MoonlitLakeModel(), beach = GoldenHourBeachModel(), road = CoastRoadModel()
        lake.setSky(sky); beach.setSky(sky); road.setSky(sky)
        let lp = ParameterSet(specs: MoonlitLakeModel.parameters, macroTargets: MoonlitLakeModel.macroTargets)
        let bp = ParameterSet(specs: GoldenHourBeachModel.parameters, macroTargets: GoldenHourBeachModel.macroTargets)
        let rp = ParameterSet(specs: CoastRoadModel.parameters, macroTargets: CoastRoadModel.macroTargets)
        return [("lake", lake.step(dt: 1.0 / 30, params: lp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience),
                ("beach", beach.step(dt: 1.0 / 30, params: bp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience),
                ("road", road.step(dt: 1.0 / 30, params: rp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience)]
    }

    private func daySky() -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: 30); s.hourOfDay = 13
        return s
    }

    func testDripsAfterRainInEveryOutdoorWorld() {
        var afterRain = daySky(); afterRain.wetness = 0.8
        for (name, scene) in scenes(afterRain) {
            XCTAssertEqual(scene.level(.drips), 0.8, accuracy: 1e-6, name)
            XCTAssertEqual(scene.wetness, 0.8, accuracy: 1e-6, name)
        }
        var raining = afterRain; raining.rain = 0.5
        for (name, scene) in scenes(raining) { XCTAssertEqual(scene.level(.drips), 0, name) }
    }

    func testBirdsSingUnderARainbowEverywhereOutdoors() {
        var shower = daySky(); shower.rain = 0.3; shower.rainbow = 1
        for (name, scene) in scenes(shower) { XCTAssertGreaterThanOrEqual(scene.level(.dawnChorus), 0.4 - 1e-9, name) }
        var none = daySky(); none.rain = 0.3
        for (name, scene) in scenes(none) { XCTAssertEqual(scene.level(.dawnChorus), 0, accuracy: 0.0001, "\(name): no bow, no daytime birdsong") }
        var storm = shower; storm.rain = 0.9
        for (name, scene) in scenes(storm) { XCTAssertEqual(scene.level(.dawnChorus), 0, accuracy: 0.0001, "\(name): not in heavy rain") }
    }

    func testBlizzardHowlsEverywhere() {
        var blizzard = daySky(); blizzard.snow = 1; blizzard.gust = 1; blizzard.wind = 1
        for (name, scene) in scenes(blizzard) { XCTAssertGreaterThanOrEqual(scene.level(.wind), 0.95, name) }
    }

    func testRoadSendsWetness() {
        var wet = daySky(); wet.wetness = 0.6
        XCTAssertEqual(scenes(wet).first { $0.0 == "road" }?.1.wetness ?? -1, 0.6, accuracy: 1e-6)
    }

    func testWeatherAmbienceHelper() {
        var levels: [AmbienceSource: Double] = [.wind: 0.2]
        var s = SkyState(); s.wetness = 0.4; s.snow = 1; s.gust = 0.5
        WeatherAmbience.levels(s, base: &levels)
        XCTAssertEqual(levels[.drips] ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(levels[.wind] ?? -1, 0.65, accuracy: 1e-6)
    }

    /// Rime frost hushes the outdoors (spec §5): in rime (the world rimed past 0.3, or rime-frost weather more than 0.3
    /// of the sky) the wind drops to 0.15 at most, and `indoorsLift` (0.15 × min(1, rime / 0.6)) is there for worlds to
    /// muffle their outdoor sources with; a blizzard still howls through, and without rime nothing changes.
    func testRimeMufflesOutdoors() {
        var fog = daySky(); fog.weather = .rime; fog.nextWeather = .rime   // the fog has come; nothing is rimed yet
        var rimed = daySky(); rimed.rime = 0.8                              // the fog has gone; the world stays white
        for (name, sky) in [("fog", fog), ("rimed", rimed)] {
            var levels: [AmbienceSource: Double] = [.wind: 0.6, .breeze: 0.4, .water: 0.8]
            WeatherAmbience.levels(sky, base: &levels)
            XCTAssertEqual(levels[.wind] ?? -1, 0.15, accuracy: 1e-9, name)
            XCTAssertEqual(levels[.breeze] ?? -1, 0.4, accuracy: 1e-9, "\(name): only the wind drops")
            XCTAssertEqual(levels[.water] ?? -1, 0.8, accuracy: 1e-9, name)
            XCTAssertTrue(WeatherAmbience.inRime(sky), name)
        }
        var calm: [AmbienceSource: Double] = [.wind: 0.1, .water: 0.8]
        WeatherAmbience.levels(rimed, base: &calm)
        XCTAssertEqual(calm[.wind] ?? -1, 0.1, accuracy: 1e-9, "a softer wind is left as it is")
        var hush: [AmbienceSource: Double] = [.water: 0.8]
        WeatherAmbience.levels(rimed, base: &hush)
        XCTAssertNil(hush[.wind], "and no wind is added")
        // Not in rime: a light rime, the fog only arriving (its glide still under 0.3), or none at all.
        var light = daySky(); light.rime = 0.25
        var arriving = daySky(); arriving.weather = .clear; arriving.nextWeather = .rime; arriving.weatherBlend = 0.3
        for (name, sky) in [("light", light), ("arriving", arriving), ("clear", daySky())] {
            var levels: [AmbienceSource: Double] = [.wind: 0.6]
            WeatherAmbience.levels(sky, base: &levels)
            XCTAssertEqual(levels[.wind] ?? -1, 0.6, accuracy: 1e-9, name)
        }
        arriving.weatherBlend = 0.6
        XCTAssertTrue(WeatherAmbience.inRime(arriving), "past the glide's 0.3")
        // A blizzard's howl still comes through a rimed world.
        var blizzard = rimed; blizzard.snow = 1; blizzard.gust = 1
        var howl: [AmbienceSource: Double] = [.wind: 0.6]
        WeatherAmbience.levels(blizzard, base: &howl)
        XCTAssertGreaterThanOrEqual(howl[.wind] ?? 0, 0.95)
        // The hush for a world to add to its indoors: 0.15 × min(1, rime / 0.6).
        XCTAssertEqual(WeatherAmbience.indoorsLift(rimed), 0.15, accuracy: 1e-9)
        var half = daySky(); half.rime = 0.3
        XCTAssertEqual(WeatherAmbience.indoorsLift(half), 0.075, accuracy: 1e-6)
        XCTAssertEqual(WeatherAmbience.indoorsLift(fog), 0, "the fog alone has rimed nothing yet")
        XCTAssertEqual(WeatherAmbience.indoorsLift(daySky()), 0)
        var odd = daySky(); odd.rime = .nan
        XCTAssertEqual(WeatherAmbience.indoorsLift(odd), 0)
        // In the worlds: a gale over a rimed lake, beach and road is held down; without the rime it blows.
        var gale = daySky(); gale.wind = 0.9
        for (name, scene) in scenes(gale) { XCTAssertEqual(scene.level(.wind), 0.6, accuracy: 1e-5, name) }
        gale.rime = 1
        for (name, scene) in scenes(gale) { XCTAssertEqual(scene.level(.wind), 0.15, accuracy: 1e-9, "\(name) in rime") }
        // The cabin's wind round the walls drops too (the cold rule keeps the rime).
        var cabin = SnowboundCabinModel()
        cabin.setSky(rimed)
        XCTAssertEqual(cabinStep(&cabin, seconds: 1.0 / 30).ambience.level(.wind), 0.15, accuracy: 1e-9)
    }

    /// Sets 7 & 8 spec §5: under a humid night the crickets rise to at least 0.6 × fireflies.
    func testHumidNightsRaiseTheCrickets() {
        var levels: [AmbienceSource: Double] = [.crickets: 0.2]
        var s = SkyState(); s.fireflies = 0.9
        WeatherAmbience.levels(s, base: &levels)
        XCTAssertEqual(levels[.crickets] ?? -1, 0.54, accuracy: 1e-6)
        var loud: [AmbienceSource: Double] = [.crickets: 0.8]
        WeatherAmbience.levels(s, base: &loud)
        XCTAssertEqual(loud[.crickets] ?? -1, 0.8, accuracy: 1e-6, "never lowers them")
        var faint: [AmbienceSource: Double] = [:]
        s.fireflies = 0.2
        WeatherAmbience.levels(s, base: &faint)
        XCTAssertNil(faint[.crickets], "a few fireflies leave the crickets alone")
    }

    /// Storms (spec §7): the gust front and virga in the worlds. Outdoors (the lake, the beach, the road), a gust front
    /// at its Hit roars on the wind (0.8, 12 dB over the Approach's 0.2) with the rain on dust rising; virga brings a dry
    /// wind and the petrichor and no rain anywhere. The cold worlds have the gust front's rain as snow and virga dry; the
    /// warm reef keeps both; the lounge has no storm at all; the sea is whipped up by the outflow and left be by virga.
    func testStormWeathersInTheWorlds() {
        var front = daySky(); front.weather = .gustFront; front.nextWeather = .gustFront
        front.gustFront = WorldWeather.gustFront(elapsed: 100, duration: 180, cross: 15)
        front.wind = 1; front.outflow = 1; front.warmthGrade = -0.08
        XCTAssertEqual(front.gustFront?.stage, .hit)
        let roar = WeatherAmbience.gustRoar(front) ?? 0
        XCTAssertEqual(roar, 0.8, accuracy: 1e-9)
        for (name, scene) in scenes(front) {
            XCTAssertGreaterThanOrEqual(scene.level(.wind), roar - 1e-9, name)
            XCTAssertEqual(scene.level(.rainOnDust), WeatherAmbience.rainOnDust(front) ?? -1, accuracy: 1e-9, name)
            XCTAssertGreaterThan(scene.level(.rainOnDust), 0.3, name)
        }
        var approach = daySky(); approach.weather = .gustFront; approach.nextWeather = .gustFront
        approach.gustFront = WorldWeather.gustFront(elapsed: 20, duration: 180, cross: 15)
        var calm: [AmbienceSource: Double] = [:]
        WeatherAmbience.levels(approach, base: &calm)
        XCTAssertEqual(calm[.wind] ?? -1, 0.2, accuracy: 1e-9, "the inflow gusts before the Hit")
        XCTAssertNil(calm[.rainOnDust], "no smell of rain yet")
        XCTAssertNil(WeatherAmbience.gustRoar(daySky()))
        XCTAssertNil(WeatherAmbience.rainOnDust(daySky()))
        XCTAssertNil(WeatherAmbience.virgaWind(daySky()))

        // Its Rain in the cold: snow, never rain. Virga in the cold: still dry.
        var rain = front; rain.gustFront = WorldWeather.gustFront(elapsed: 170, duration: 180, cross: 15); rain.rain = 0.6
        let cold = WorldWeather.cold(rain)
        XCTAssertEqual(cold.rain, 0)
        XCTAssertGreaterThanOrEqual(cold.snow, 0.6 - 1e-6)
        var virga = daySky(); virga.weather = .virga; virga.nextWeather = .virga; virga.virga = 1; virga.gust = 0.5
        XCTAssertEqual([WorldWeather.cold(virga).rain, WorldWeather.cold(virga).snow], [0, 0])
        XCTAssertEqual(WorldWeather.warm(front).weather, .gustFront, "the warm reef keeps both")
        XCTAssertEqual(WorldWeather.warm(virga).weather, .virga)

        // Virga outdoors: the dry wind (0.25 + 0.35 × gust) and the petrichor (0.5), no rain on the water or the glass.
        for (name, scene) in scenes(virga) {
            XCTAssertGreaterThanOrEqual(scene.level(.wind), 0.25 + 0.35 * 0.5 - 1e-9, name)
            XCTAssertEqual(scene.level(.rainOnDust), 0.5, accuracy: 1e-9, name)
            XCTAssertEqual(scene.level(.rainOnWater), 0, name)
            XCTAssertEqual(scene.level(.rainOnGlass), 0, name)
        }

        // Space has no storm.
        var stormy = rain
        stormy.crawlers = [CrawlerSlot(segments: [], born: 0, duration: 1, peak: 0.3, brightness: 0.3)]
        stormy.sheet = [SheetSlot(azimuth: 90, width: 20, height: 4, born: 0, duration: 0.2, strength: 1, brightness: 0.2)]
        stormy.stormFlash = 0.3; stormy.virga = 0.5; stormy.farStorm = 1; stormy.supercell = 1; stormy.supercellPhase = 0.5
        let space = SpaceshipLoungeModel.weatherless(stormy)
        XCTAssertTrue(space.crawlers.isEmpty && space.sheet.isEmpty)
        XCTAssertNil(space.gustFront)
        XCTAssertEqual([space.stormFlash, space.outflow, space.warmthGrade, space.virga, space.farStorm, space.supercell,
                        space.supercellPhase], [0, 0, 0, 0, 0, 0, 0])

        // The sea: whipped up by the outflow as by a squall; left be by virga.
        XCTAssertEqual(OceanSwell.weatherScale(front), 1.7, accuracy: 1e-6)
        XCTAssertEqual(OceanSwell.weatherScale(virga), 1, accuracy: 1e-6)
    }

    /// Sets 7 & 8 spec §5: diamond dust is still air: the wind is capped at 0.2.
    func testDiamondDustStillsTheWind() {
        var levels: [AmbienceSource: Double] = [.wind: 0.6]
        var s = SkyState(); s.diamondDust = 1
        WeatherAmbience.levels(s, base: &levels)
        XCTAssertEqual(levels[.wind] ?? -1, 0.2, accuracy: 1e-6)
        var calm: [AmbienceSource: Double] = [.wind: 0.1]
        WeatherAmbience.levels(s, base: &calm)
        XCTAssertEqual(calm[.wind] ?? -1, 0.1, accuracy: 1e-6)
        var none: [AmbienceSource: Double] = [:]
        WeatherAmbience.levels(s, base: &none)
        XCTAssertNil(none[.wind])
    }

    /// Storms spec §9.3: the dry cicadas stop dead 2 s before a close strike. A far strike (2 km or more) lands at once and
    /// leaves them singing; a close one stills them at once and is held until they have been silent 2 s, never sooner (a
    /// second close one asked for meanwhile joins it, the nearer kept); once they are still a close strike lands at once;
    /// they sing again 8 s after the last close strike, and their level follows (nothing while hushed).
    func testCicadaHushHoldsACloseStrike() {
        var hush = CicadaHush()
        let far = hush.strike(atKm: 5), edge = hush.strike(atKm: CicadaHush.closeKm)
        XCTAssertTrue(far, "a far strike lands at once")
        XCTAssertTrue(edge, "2 km is still far")
        XCTAssertFalse(hush.hushed)
        XCTAssertEqual(hush.level(0.8), 0.8)
        let close = hush.strike(atKm: 1.5)
        XCTAssertFalse(close, "a close strike waits for the silence")
        XCTAssertTrue(hush.hushed)
        XCTAssertEqual(hush.level(0.8), 0, "the cicadas' level goes to nothing: the engine stops them dead")
        let dt = 1.0 / 60
        var t = 0.0, landed: Double?, km: Double?, joined = false
        while landed == nil, t < 5 {
            t += dt
            if t >= 0.5, !joined {
                joined = true
                let second = hush.strike(atKm: 0.8)
                XCTAssertFalse(second, "a second close strike joins the first")
            }
            if let k = hush.step(dt: dt) { landed = t; km = k }
        }
        XCTAssertEqual(landed ?? -1, CicadaHush.lead, accuracy: dt + 1e-9, "it lands 2 s after the hush")
        XCTAssertGreaterThanOrEqual(landed ?? 0, CicadaHush.lead - 1e-9, "never sooner")
        XCTAssertEqual(km ?? -1, 0.8, accuracy: 1e-12, "the nearer one")
        XCTAssertNil(hush.held)
        XCTAssertTrue(hush.hushed, "still silent after the strike")
        let atOnce = hush.strike(atKm: 1)
        XCTAssertTrue(atOnce, "once they are still, a close strike lands at once")
        var since = 0.0, sang: Double?, stray = 0
        while sang == nil, since < 20 {
            since += dt
            if hush.step(dt: dt) != nil { stray += 1 }
            if !hush.hushed { sang = since }
        }
        XCTAssertEqual(stray, 0, "nothing else was held")
        XCTAssertEqual(sang ?? -1, CicadaHush.after, accuracy: dt + 1e-9, "they sing again 8 s after the last close strike")
        XCTAssertEqual(hush.level(0.8), 0.8)
        // Nonsense in, nothing out.
        var odd = CicadaHush()
        let nan = odd.strike(atKm: .nan), stepped = odd.step(dt: 1)
        XCTAssertTrue(nan)
        XCTAssertNil(stepped)
        XCTAssertFalse(odd.hushed)
    }

    /// Storms spec §9.3: the windmill turns with the wind, by the engine's own law (AmbienceTests.testWindmillFollowsWind
    /// hears it): still below the cut-in (0.08), 0.75 strokes a second in a gale, evenly between; the gusts drive it on top
    /// of the wind (+0.3 × gust, to 1 at most); the wheel turns 3.29 times a stroke.
    func testWindmillFollowsTheWind() {
        XCTAssertEqual(WeatherAmbience.windmillRate(0), 0)
        XCTAssertEqual(WeatherAmbience.windmillRate(WeatherAmbience.windmillCutIn), 0, "still at the cut-in")
        XCTAssertEqual(WeatherAmbience.windmillRate(1), 0.75, accuracy: 1e-12, "45 a minute in a gale")
        XCTAssertEqual(WeatherAmbience.windmillRate(0.45), 0.75 * 0.37 / 0.92, accuracy: 1e-12)
        XCTAssertEqual(WeatherAmbience.windmillRate(3), 0.75, accuracy: 1e-12, "a gale is a gale")
        XCTAssertEqual(WeatherAmbience.windmillRate(.nan), 0)
        let rates = stride(from: 0.0, through: 1.0, by: 0.05).map { WeatherAmbience.windmillRate($0) }
        XCTAssertEqual(rates, rates.sorted(), "faster the harder the wind")
        var sky = SkyState(); sky.wind = 0.5; sky.gust = 0.5
        XCTAssertEqual(WeatherAmbience.windmillDrive(sky), 0.65, accuracy: 1e-6, "the gusts on top of the wind")
        XCTAssertEqual(WeatherAmbience.windmillRate(sky), WeatherAmbience.windmillRate(0.65), accuracy: 1e-6)
        sky.wind = 0.9; sky.gust = 1
        XCTAssertEqual(WeatherAmbience.windmillDrive(sky), 1)
        sky.wind = .nan; sky.gust = .nan
        XCTAssertEqual(WeatherAmbience.windmillDrive(sky), 0)
        XCTAssertEqual(WeatherAmbience.windmillGear, 3.29, accuracy: 1e-12)
    }
}

// MARK: - Snowbound Cabin

extension WorldTests {
    private func cabinStep(_ model: inout SnowboundCabinModel, seconds: Double, state: ThemeState = ThemeState()) -> CabinFrame {
        let p = ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: state)
        var frame: CabinFrame?
        for _ in 0..<max(1, Int(seconds * 30)) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    private func sky(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testCabinTurnsRainToSnow() {
        var rain = sky(sun: 20, hour: 13); rain.rain = 0.75; rain.weather = .rain; rain.lightning = 0.5; rain.wetness = 0.7
        let cold = SnowboundCabinModel.coldSky(rain)
        XCTAssertEqual(cold.snow, 0.75, accuracy: 1e-6)
        XCTAssertEqual(cold.rain, 0)
        XCTAssertEqual(cold.lightning, 0)
        XCTAssertEqual(cold.wetness, 0)
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        let blizzard = SnowboundCabinModel.coldSky(storm)
        XCTAssertEqual(blizzard.snow, 1)
        XCTAssertEqual(blizzard.wind, 1)
        XCTAssertEqual(blizzard.gust, 1, accuracy: 1e-3, "a storm's gusts become a blizzard's")
        XCTAssertEqual(blizzard.rain, 0)
        XCTAssertEqual(blizzard.weather, .blizzard)
        var drizzle = sky(sun: 20, hour: 13); drizzle.rain = 0.3; drizzle.weather = .drizzle
        XCTAssertEqual(SnowboundCabinModel.coldSky(drizzle).snow, 0.3, accuracy: 1e-6, "drizzle is light snow")
        XCTAssertEqual(SnowboundCabinModel.coldSky(drizzle).weather, .snow)
        var shower = sky(sun: 20, hour: 13); shower.rain = 0.3; shower.rainbow = 1; shower.weather = .sunShower
        XCTAssertEqual(SnowboundCabinModel.coldSky(shower).rainbow, 0, "snow makes no rainbow")
        XCTAssertEqual(SnowboundCabinModel.coldSky(shower).weather, .snow)
    }

    /// The cold-sky rule lives in Core as `WorldWeather.cold`, shared by the cabin (and the fjord).
    func testColdSkySharedByCabin() {
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        storm.fireflies = 0.8; storm.aurora = 0.6; storm.pillar = 0.5
        XCTAssertEqual(SnowboundCabinModel.coldSky(storm), WorldWeather.cold(storm))
        let cold = WorldWeather.cold(storm)
        XCTAssertEqual(cold.weather, .blizzard)
        XCTAssertEqual(cold.fireflies, 0, "no fireflies in the cold")
        XCTAssertEqual(cold.aurora, 0.6, "the aurora and pillars stay")
        XCTAssertEqual(cold.pillar, 0.5)
        var humid = sky(sun: -20, hour: 23); humid.weather = .humid; humid.nextWeather = .humid; humid.fireflies = 1
        XCTAssertEqual(WorldWeather.cold(humid).weather, .clear)
        var dust = sky(sun: -20, hour: 23); dust.weather = .diamondDust; dust.nextWeather = .diamondDust
        XCTAssertEqual(WorldWeather.cold(dust).weather, .diamondDust, "diamond dust is at home in the cold")
        var cabin = SnowboundCabinModel(); cabin.setSky(storm)
        let frame = cabin.step(dt: 1.0 / 60, params: ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: ThemeState()),
                               roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertEqual(frame.sky, cold)
    }

    /// Snow that was rain still frosts the glass, and a storm turned blizzard frosts it hard and whites out with each
    /// gust (final review: the frost vanished whenever the cabin's snow came from rain).
    func testColdSkyKeepsTheFrost() {
        var rain = sky(sun: 20, hour: 13); rain.rain = 0.75; rain.weather = .rain; rain.frost = 0
        XCTAssertGreaterThanOrEqual(SnowboundCabinModel.coldSky(rain).frost, 0.45)
        var storm = sky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.mist = 0.2; storm.weather = .storm; storm.frost = 0
        let blizzard = SnowboundCabinModel.coldSky(storm)
        XCTAssertGreaterThanOrEqual(blizzard.frost, 0.85)
        XCTAssertGreaterThan(blizzard.mist, 0.2 + 0.2, "a gust whites it out")
        var snow = sky(sun: 20, hour: 13); snow.snow = 0.8; snow.weather = .snow; snow.frost = 0.6
        XCTAssertEqual(SnowboundCabinModel.coldSky(snow).frost, 0.6, accuracy: 1e-6, "real snow is left as it is")
    }

    /// A storm turned blizzard comes and goes with the weather's glide, never in one frame (final review: it vanished
    /// in a frame when the storm ended).
    func testCabinStormBlizzardGlides() throws {
        var settings = SkySettings(); settings.timeMode = .frozen; settings.frozenHour = 13; settings.cityID = "melbourne"
        settings.weatherMode = .pick; settings.weather = .storm
        let living = LivingSky(settings: settings, seed: 1, homeZone: try XCTUnwrap(TimeZone(identifier: "Australia/Melbourne")))
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var now = start
        _ = living.step(now: now, dt: 0)
        for _ in 0..<60 { now += 1; _ = living.step(now: now, dt: 1) }
        settings.weather = .clear; living.settings = settings
        var previous = SnowboundCabinModel.coldSky(living.step(now: now, dt: 0))
        var worstSnow: Float = 0, worstWind: Float = 0
        for _ in 0..<(75 * 60) {
            now += 1.0 / 60
            let cold = SnowboundCabinModel.coldSky(living.step(now: now, dt: 1.0 / 60))
            worstSnow = max(worstSnow, abs(cold.snow - previous.snow)); worstWind = max(worstWind, abs(cold.wind - previous.wind))
            previous = cold
        }
        XCTAssertLessThan(worstSnow, 0.05)
        XCTAssertLessThan(worstWind, 0.05)
        XCTAssertLessThan(previous.snow, 0.05, "and the blizzard is over")
    }

    /// A panic (or unplugging the keyboard) with the pedal down lets the pedal go too, so later notes don't stay
    /// "sounding" for ever (final review).
    func testPanicLetsThePedalGo() {
        var cabin = SnowboundCabinModel()
        cabin.setSky(sky(sun: -20, hour: 22))
        cabin.handle(.pedal(down: true, amount: 1))
        cabin.handle(.allNotesOff)
        _ = cabinStep(&cabin, seconds: 0.1)
        cabin.handle(.noteOn(note: 60, velocity: 0.8))
        _ = cabinStep(&cabin, seconds: 0.5)
        cabin.handle(.noteOff(note: 60))
        XCTAssertTrue(cabinStep(&cabin, seconds: 30).patches.isEmpty, "the patch freezes over again")
        var bedroom = BedroomDawnModel()
        bedroom.setSky(bedroomSky(sun: 2, hour: 6.8))
        bedroom.handle(.pedal(down: true, amount: 1))
        bedroom.handle(.allNotesOff)
        _ = bedroomStep(&bedroom, seconds: 0.1)
        bedroom.handle(.noteOn(note: 64, velocity: 0.8))
        _ = bedroomStep(&bedroom, seconds: 1)
        bedroom.handle(.noteOff(note: 64))
        XCTAssertLessThan(bedroomStep(&bedroom, seconds: 30).glow, 0.02, "the morning glow settles")
    }

    func testCabinAmbience() {
        var model = SnowboundCabinModel()
        var s = sky(sun: -20, hour: 22); s.snow = 0.8; s.gust = 0.3
        model.setSky(s)
        let a = cabinStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.fire), 0.7 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(a.level(.wind), 0.25 + 0.3, accuracy: 1e-6)
        XCTAssertEqual(a.level(.rainOnGlass), 0.4 * 0.8, accuracy: 1e-6)
        XCTAssertEqual(a.snowOnGlass, 0.8, accuracy: 1e-6)
        XCTAssertEqual(a.indoors, 1)
        XCTAssertEqual(a.level(.clock), 0)
        XCTAssertEqual(a.level(.surf), 0)
        XCTAssertEqual(a.level(.road), 0)
        XCTAssertEqual(a.wetness, 0)
    }

    func testCabinDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(SnowboundCabinModel.id), SnowboundCabinModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == SnowboundCabinModel.id && $0.name == "Snowbound Cabin Window" })
        XCTAssertTrue(ThemeRegistry.isWorld(SnowboundCabinModel.id))
        assertValidParameters(SnowboundCabinModel.parameters)
        let params = ThemeRegistry.parameterSet(for: SnowboundCabinModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("visual"), "Frost Grow")
        XCTAssertEqual(SnowboundCabinModel.visuals, ["Frost Grow", "Galaxy Warp"])
        XCTAssertEqual(params.number("frost"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("fire"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("condensation"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(params.number("farCabin"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Mood.hushedWarm, Mood(energy: 0.2, warmth: 0.85, brightness: 0.3, space: 0.35, motion: 0.2))
    }

    func testCabinFrameCarriesFrost() {
        var model = SnowboundCabinModel()
        var s = sky(sun: -20, hour: 22); s.frost = 0.3
        model.setSky(s)
        for n: UInt8 in [60, 64, 67] { model.handle(.noteOn(note: n, velocity: 0.7)) }
        let f = cabinStep(&model, seconds: 20)
        XCTAssertGreaterThan(f.frostLevel, 0.3 * 0.6 + 0.05, "above the base while notes are held")
        XCTAssertEqual(f.patches.count, 3)
        XCTAssertNil(f.warp)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue((0...1).contains(f.fireFlicker))
    }

    func testCabinWarpOptionStreaksInstead() {
        var model = SnowboundCabinModel()
        model.setSky(sky(sun: -20, hour: 22))
        model.handle(.noteOn(note: 60, velocity: 0.9))
        let f = cabinStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(f.warp)
        XCTAssertTrue(f.patches.isEmpty, "Galaxy Warp replaces the patches")
    }

    func testFarCabinLightsAtNight() {
        func lit(_ altitude: Double, _ hour: Double) -> Bool {
            var model = SnowboundCabinModel()
            model.setSky(sky(sun: altitude, hour: hour))
            return cabinStep(&model, seconds: 0.1).farCabinLit
        }
        XCTAssertTrue(lit(-20, 22))
        XCTAssertFalse(lit(30, 13))
        XCTAssertFalse(lit(-30, 3), "everyone's asleep")
    }

    func testFireFlickersDeterministically() {
        var a = SnowboundCabinModel(), b = SnowboundCabinModel()
        a.setSky(sky(sun: -20, hour: 22)); b.setSky(sky(sun: -20, hour: 22))
        var values: [Float] = []
        for i in 0..<60 {
            let fa = cabinStep(&a, seconds: 1.0 / 30), fb = cabinStep(&b, seconds: 1.0 / 30)
            XCTAssertEqual(fa.fireFlicker, fb.fireFlicker, "step \(i)")
            values.append(fa.fireFlicker)
        }
        XCTAssertGreaterThan((values.max() ?? 0) - (values.min() ?? 0), 0.05, "it flickers")
    }
}

// MARK: - Bedroom at Dawn

extension WorldTests {
    private func bedroomStep(_ model: inout BedroomDawnModel, seconds: Double, state: ThemeState = ThemeState(),
                             each: ((BedroomFrame) -> Void)? = nil) -> BedroomFrame {
        let p = ThemeRegistry.parameterSet(for: BedroomDawnModel.id, state: state)
        var frame: BedroomFrame?
        for _ in 0..<max(1, Int((seconds * 30).rounded())) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            if let frame { each?(frame) }
        }
        return frame!
    }

    private func bedroomSky(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 90, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testBedroomDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(BedroomDawnModel.id), BedroomDawnModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == BedroomDawnModel.id && $0.name == "Bedroom Window at Dawn" })
        XCTAssertTrue(ThemeRegistry.isWorld(BedroomDawnModel.id))
        assertValidParameters(BedroomDawnModel.parameters)
        let params = ThemeRegistry.parameterSet(for: BedroomDawnModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Pastel dawn")
        XCTAssertEqual(params.choice("visual"), "Curtain Light")
        XCTAssertEqual(BedroomDawnModel.visuals, ["Curtain Light", "Frost Grow", "Galaxy Warp"])
        XCTAssertEqual(params.number("light"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("sway"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("motes"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("fairy"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("frost"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("window.open"), 0, "the window starts closed")
        XCTAssertEqual(Mood.softWaking, Mood(energy: 0.25, warmth: 0.6, brightness: 0.65, space: 0.55, motion: 0.3))
    }

    func testStreetLampHysteresis() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: -5, hour: 5))
        var f = bedroomStep(&model, seconds: 5)
        XCTAssertGreaterThan(f.streetLamp, 0.9, "on in the dark")
        model.setSky(bedroomSky(sun: -2.5, hour: 6))
        f = bedroomStep(&model, seconds: 1)
        XCTAssertGreaterThan(f.streetLamp, 0.9, "still on between −3° and −2°")
        model.setSky(bedroomSky(sun: 1, hour: 6.5))
        f = bedroomStep(&model, seconds: 0.2)
        XCTAssertEqual(f.streetLamp, 0, "off once the sun is above −2°")
        model.setSky(bedroomSky(sun: -2.5, hour: 19))
        f = bedroomStep(&model, seconds: 1)
        XCTAssertEqual(f.streetLamp, 0, "and stays off until below −3°")
        model.setSky(bedroomSky(sun: -4, hour: 19.5))
        var levels: [Float] = []
        _ = bedroomStep(&model, seconds: 4) { levels.append($0.streetLamp) }
        XCTAssertLessThan(levels[15], 0.8, "warming up at 0.5 s")
        XCTAssertGreaterThan(levels.last ?? 0, 0.95, "fully on after about 3 s")
    }

    func testWindowsLightUpAsMorningComes() {
        var model = BedroomDawnModel()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        model.setSky(bedroomSky(sun: -20, hour: 4))
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 0)
        model.setSky(bedroomSky(sun: 5, hour: 7.75))
        XCTAssertGreaterThanOrEqual(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 6)
        model.setSky(bedroomSky(sun: -30, hour: 23.5))
        XCTAssertLessThan(bedroomStep(&model, seconds: 0.1, state: follow).litWindows, 8, "going dark late at night")
    }

    /// Pastel dawn (the set's default hold) keeps it morning whatever the clock says: the dawn chorus sings, the street
    /// is only just waking and the houses are lighting up (final review: an evening session heard no birds, mid-morning
    /// traffic and houses going dark under a frozen dawn).
    func testHeldDawnSoundsLikeMorning() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: 1.5, hour: 20))
        let evening = bedroomStep(&model, seconds: 0.1)
        XCTAssertGreaterThanOrEqual(evening.ambience.level(.dawnChorus), 0.5)
        XCTAssertLessThan(evening.ambience.level(.street), 0.35)
        model.setSky(bedroomSky(sun: 1.5, hour: 23.5))
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1).litWindows, BedroomDawnModel.litWindows(hour: 6.5))
    }

    func testBedroomAmbience() {
        var model = BedroomDawnModel()
        var s = bedroomSky(sun: 5, hour: 6.5); s.wetness = 0.5
        model.setSky(s)
        var a = bedroomStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.kettle), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.clock), 0.15, accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0.7, accuracy: 1e-9, "an old sash window lets the birds through, softly")
        XCTAssertEqual(a.level(.drips), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(a.level(.dawnChorus), 0.3)
        a = bedroomStep(&model, seconds: 0.1, state: ThemeState(values: ["window.open": .bool(true)])).ambience
        XCTAssertEqual(a.indoors, 0.35, accuracy: 1e-9)
        var early = BedroomDawnModel(), late = BedroomDawnModel()
        early.setSky(bedroomSky(sun: -12, hour: 5)); late.setSky(bedroomSky(sun: 28, hour: 9))
        XCTAssertGreaterThan(bedroomStep(&late, seconds: 0.1).ambience.level(.street), bedroomStep(&early, seconds: 0.1).ambience.level(.street))
        var raining = BedroomDawnModel()
        var r = bedroomSky(sun: 10, hour: 8); r.rain = 0.6; r.wetness = 0.4
        raining.setSky(r)
        let ra = bedroomStep(&raining, seconds: 0.1).ambience
        XCTAssertEqual(ra.level(.rainOnGlass), 0.6, accuracy: 1e-6)
        XCTAssertEqual(ra.level(.drips), 0)
    }

    /// Sets 9 & 10 spec §5 (final review): rimed trees and roofs soak up sound, so the street, the breeze and the birds
    /// come through the sash a little more hushed (the window's indoors + WeatherAmbience.indoorsLift), shut or open.
    func testBedroomHushesInRime() {
        var model = BedroomDawnModel()
        var s = bedroomSky(sun: 5, hour: 6.5); s.rime = 1
        model.setSky(s)
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1).ambience.indoors, 0.7 + 0.15, accuracy: 1e-9, "shut")
        let open = ThemeState(values: ["window.open": .bool(true)])
        XCTAssertEqual(bedroomStep(&model, seconds: 0.1, state: open).ambience.indoors, 0.35 + 0.15, accuracy: 1e-9, "open")
    }

    func testCurtainsMoveMoreWithTheWindowOpen() {
        func motion(open: Bool) -> Double {
            var model = BedroomDawnModel()
            var s = bedroomSky(sun: 10, hour: 8); s.wind = 0.4
            model.setSky(s)
            let state = ThemeState(values: ["window.open": .bool(open)])
            _ = bedroomStep(&model, seconds: 2, state: state)
            var total = 0.0
            var previous: [SIMD3<Float>]?
            _ = bedroomStep(&model, seconds: 10, state: state) { f in
                let now = f.curtains.left + f.curtains.right
                if let prev = previous { for (a, b) in zip(now, prev) { total += Double(simd_length(a - b)) } }
                previous = now
            }
            return total
        }
        XCTAssertGreaterThanOrEqual(motion(open: true), 1.5 * motion(open: false))
    }

    func testBedroomFrameCarriesTheCurtains() {
        var model = BedroomDawnModel()
        model.setSky(bedroomSky(sun: 2, hour: 6.8))
        for n: UInt8 in [60, 64, 67, 84] { model.handle(.noteOn(note: n, velocity: 0.8)) }
        let f = bedroomStep(&model, seconds: 2)
        XCTAssertEqual(f.curtains.left.count, 24 * 32)
        XCTAssertEqual(f.curtains.right.count, 24 * 32)
        XCTAssertTrue((f.curtains.left + f.curtains.right).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        XCTAssertGreaterThan(f.glow, 0.3, "held notes raise the morning glow")
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.warp)
        XCTAssertEqual(f.fairy.count, CurtainLight.fairyCount)
    }

    func testBedroomFrostGrowOption() {
        var model = BedroomDawnModel()
        var s = bedroomSky(sun: 2, hour: 6.8); s.frost = 0.6
        model.setSky(s)
        model.handle(.noteOn(note: 64, velocity: 0.8))
        let f = bedroomStep(&model, seconds: 3, state: ThemeState(values: ["visual": .choice("Frost Grow")]))
        XCTAssertEqual(f.patches.count, 1)
        XCTAssertGreaterThan(f.frostLevel, 0.6 * 0.5 * 0.5, "the sky's frost and the setting set the base")
        XCTAssertEqual(f.glow, 0, accuracy: 1e-6, "Curtain Light rests while Frost Grow plays")
    }
}

// MARK: - Bioluminescent Bay

extension WorldTests {
    private func bayStep(_ model: inout BioluminescentBayModel, seconds: Double, dt: Double = 1.0 / 30,
                         state: ThemeState = ThemeState()) -> BayFrame {
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: state)
        var frame: BayFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    /// The bay through the director at a frozen hour in Melbourne, following the sky (not held at deep night).
    private func bayFrame(hour: Double, weather: WeatherKind = .clear, hold: SkyHold = .follow) -> BayFrame? {
        var state = ThemeState(); state.values["light.hold"] = .choice(hold.rawValue)
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        d.sky.reset(settings: s)
        var frame: BayFrame?
        for i in 0..<90 {
            if i == 80 { d.handle([.noteOn(note: 60, velocity: 0.8)], at: Double(i) / 30) }
            frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BayFrame
        }
        return frame
    }

    func testBayGlowsOnlyAtNight() throws {
        let noon = try XCTUnwrap(bayFrame(hour: 12))
        XCTAssertGreaterThan(noon.sky.sun.altitude, 20)
        XCTAssertEqual(noon.glowScale, 0, "the plankton needs the dark")
        XCTAssertEqual(noon.patches.count, 1, "the note still lands")
        XCTAssertTrue(noon.patches.allSatisfy { $0.brightness == 0 })
        XCTAssertFalse(noon.lanternLit)
        let night = try XCTUnwrap(bayFrame(hour: 23))
        XCTAssertLessThan(night.sky.sun.altitude, -8)
        XCTAssertEqual(night.glowScale, 1, accuracy: 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(night.patches.first).brightness, 0.6)
        XCTAssertTrue(night.lanternLit)
        // Held at deep night (the default), noon glows too.
        XCTAssertEqual(try XCTUnwrap(bayFrame(hour: 12, hold: .deepNight)).glowScale, 1, accuracy: 0.02)

        // Rain dulls it: ×(1 − 0.6·rain).
        var model = BioluminescentBayModel()
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: -20); s.hourOfDay = 23; s.rain = 0.5
        model.setSky(s)
        XCTAssertEqual(bayStep(&model, seconds: 0.1).glowScale, 0.7, accuracy: 1e-5)
        XCTAssertEqual(BioluminescentBayModel.glowScale(s), 0.7, accuracy: 1e-5)
    }

    func testBayAmbience() {
        var night = BioluminescentBayModel()
        night.mood = .secretGlow
        night.setSky(sky(sun: -20, hour: 23))
        let a = bayStep(&night, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.lapping), 0.7, accuracy: 1e-9)
        XCTAssertEqual(a.level(.water), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.boat), 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.25, accuracy: 1e-9)
        XCTAssertEqual(a.level(.owl), 0.15, accuracy: 1e-9)
        XCTAssertEqual(a.level(.gulls), 0, accuracy: 1e-9)
        XCTAssertEqual(a.level(.surf), 0, "a sheltered cove: no surf")
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.6, .secretGlow), accuracy: 1e-9)
        XCTAssertGreaterThan(a.nightCool, 0)
        XCTAssertNil(a.wave)

        var day = BioluminescentBayModel()
        var d = sky(sun: 40, hour: 13); d.wind = 0.3; d.rain = 0.4
        day.setSky(d)
        let b = bayStep(&day, seconds: 0.1).ambience
        XCTAssertEqual(b.level(.crickets), 0)
        XCTAssertEqual(b.level(.owl), 0)
        XCTAssertEqual(b.level(.gulls), 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.level(.breeze), 0.55, accuracy: 1e-6)
        XCTAssertEqual(b.level(.rainOnWater), 0.4, accuracy: 1e-6)

        // Thunder as the lake: once per strike.
        var storm = BioluminescentBayModel()
        var st = sky(sun: -20, hour: 23); st.lightning = 1
        storm.setSky(st)
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        let first = storm.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let second = storm.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertNotNil(first.ambience.thunder)
        XCTAssertNil(second.ambience.thunder)
    }

    func testBayDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(BioluminescentBayModel.id), BioluminescentBayModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == BioluminescentBayModel.id && $0.name == "Bioluminescent Bay" })
        XCTAssertTrue(ThemeRegistry.isWorld(BioluminescentBayModel.id))
        assertValidParameters(BioluminescentBayModel.parameters)
        let params = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        XCTAssertEqual(BioluminescentBayModel.visuals, ["Glow Wake", "Galaxy Warp"])
        XCTAssertEqual(params.choice("visual"), "Glow Wake")
        XCTAssertEqual(params.choice("light.hold"), "Deep night")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.number("glow"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("lantern"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("lighthouse"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        XCTAssertTrue(BioluminescentBayModel.parameters.first { $0.id == "glow" }?.hero ?? false)
        XCTAssertEqual(Mood.secretGlow, Mood(energy: 0.3, warmth: 0.55, brightness: 0.35, space: 0.7, motion: 0.4))

        // The frame carries the glow, the keys and, with Galaxy Warp, streaks instead.
        var model = BioluminescentBayModel()
        model.setSky(sky(sun: -20, hour: 23))
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let f = bayStep(&model, seconds: 0.5)
        XCTAssertEqual(f.patches.count, 1)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue(f.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertNil(f.warp)
        XCTAssertTrue(f.swellScale > 0 && f.swellScale < 0.2, "a still bay in calm weather")
        let w = bayStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(w.warp)
        XCTAssertTrue(w.patches.isEmpty, "Galaxy Warp replaces the glow")

        // Storms whip the bay up.
        var stormy = BioluminescentBayModel()
        var s = sky(sun: -20, hour: 23); s.weather = .storm; s.nextWeather = .storm
        stormy.setSky(s)
        XCTAssertGreaterThan(bayStep(&stormy, seconds: 0.1).swellScale, 2 * f.swellScale)
    }

    func testLighthouseBlinksEverySixSeconds() {
        var model = BioluminescentBayModel()
        model.setSky(sky(sun: -20, hour: 23))
        let p = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        let dt = 1.0 / 60
        var onsets: [Double] = []
        var litFrames = 0
        var previous: Float = 0
        for i in 1...(19 * 60) {
            let f = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            XCTAssertTrue((0...1).contains(f.lighthouseFlash))
            if f.lighthouseFlash > 0 { litFrames += 1 }
            if f.lighthouseFlash > 0, previous == 0 { onsets.append(Double(i) * dt) }
            previous = f.lighthouseFlash
        }
        XCTAssertEqual(onsets.count, 4, "at 0, 6, 12 and 18 s")
        for (a, b) in zip(onsets, onsets.dropFirst()) { XCTAssertEqual(b - a, 6, accuracy: 0.05) }
        XCTAssertEqual(Double(litFrames) * dt / Double(onsets.count), 0.4, accuracy: 0.05, "each flash lasts 0.4 s")

        // Dark by day, and when the lighthouse is turned off.
        var day = BioluminescentBayModel()
        day.setSky(sky(sun: 30, hour: 13))
        var dayMax: Float = 0
        for _ in 0..<(7 * 60) { dayMax = max(dayMax, day.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high).lighthouseFlash) }
        XCTAssertEqual(dayMax, 0)
        var off = BioluminescentBayModel()
        off.setSky(sky(sun: -20, hour: 23))
        let po = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState(values: ["lighthouse": .number(0)]))
        var offMax: Float = 0
        for _ in 0..<(7 * 60) { offMax = max(offMax, off.step(dt: dt, params: po, roles: RoleValues(), inputs: InputFrame(), quality: .high).lighthouseFlash) }
        XCTAssertEqual(offMax, 0)
    }
}


// MARK: - Aurora Fjord

extension WorldTests {
    private func fjordStep(_ model: inout AuroraFjordModel, seconds: Double, state: ThemeState = ThemeState()) -> FjordFrame {
        let p = ThemeRegistry.parameterSet(for: AuroraFjordModel.id, state: state)
        var frame: FjordFrame?
        for _ in 0..<max(1, Int((seconds * 30).rounded())) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    private func fjordSkyState(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 0, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testFjordTurnsRainToSleetAndStormsToBlizzards() {
        var rain = fjordSkyState(sun: -20, hour: 22); rain.rain = 0.6; rain.weather = .rain; rain.nextWeather = .rain
        rain.lightning = 0.5; rain.wetness = 0.4; rain.fireflies = 0.3
        let sleet = AuroraFjordModel.fjordSky(rain)
        XCTAssertEqual(sleet.rain, 0.3, accuracy: 1e-6, "half the rain stays rain")
        XCTAssertEqual(sleet.snow, 0.3, accuracy: 1e-6, "and half falls as snow")
        XCTAssertEqual(sleet.weather, .sleet)
        XCTAssertEqual(sleet.lightning, 0)
        XCTAssertEqual(sleet.fireflies, 0, "no fireflies in the cold")
        XCTAssertEqual(sleet.wetness, 0.2, accuracy: 1e-6)
        var drizzle = fjordSkyState(sun: 10, hour: 13); drizzle.rain = 0.3; drizzle.weather = .drizzle
        XCTAssertEqual(AuroraFjordModel.fjordSky(drizzle).weather, .sleet)
        XCTAssertEqual(AuroraFjordModel.fjordSky(drizzle).snow, 0.15, accuracy: 1e-6)

        var storm = fjordSkyState(sun: 10, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6; storm.weather = .storm
        storm.lightning = 1
        let blizzard = AuroraFjordModel.fjordSky(storm)
        XCTAssertEqual(blizzard.weather, .blizzard)
        XCTAssertEqual(blizzard.snow, 1)
        XCTAssertEqual(blizzard.rain, 0, "a blizzard, not sleet")
        XCTAssertEqual(blizzard.wind, 1)
        XCTAssertEqual(blizzard.lightning, 0)
        XCTAssertEqual(blizzard.wetness, 0)
        // Half-way out of a storm into rain: part blizzard, part sleet, and every value in range.
        var gliding = storm; gliding.nextWeather = .rain; gliding.weatherBlend = 0.5
        let mid = AuroraFjordModel.fjordSky(gliding)
        XCTAssertEqual(mid.rain, 0.25, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(mid.snow, 0.5)
        XCTAssertEqual(mid.nextWeather, .sleet)
        for v in [mid.rain, mid.snow, mid.wind, mid.gust, mid.mist, mid.frost, mid.wetness] { XCTAssertTrue((0...1).contains(v)) }
        // Snow and diamond dust are left as they are.
        var dust = fjordSkyState(sun: -20, hour: 23); dust.weather = .diamondDust; dust.nextWeather = .diamondDust; dust.pillar = 1
        XCTAssertEqual(AuroraFjordModel.fjordSky(dust).weather, .diamondDust)
        XCTAssertEqual(AuroraFjordModel.fjordSky(dust).pillar, 1)
        // The model shows the fjord's sky.
        var model = AuroraFjordModel(); model.setSky(rain)
        XCTAssertEqual(fjordStep(&model, seconds: 0.1).sky, sleet)
    }

    func testFjordAmbience() {
        var model = AuroraFjordModel()
        var s = fjordSkyState(sun: -20, hour: 22); s.wind = 0.5; s.wetness = 0.4
        model.setSky(s)
        let a = fjordStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.iceGroan), 0.8, accuracy: 1e-6, "the ice groans more at night")
        XCTAssertEqual(a.level(.waterfall), 0.35, accuracy: 1e-9)
        XCTAssertEqual(a.level(.water), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.wind), 0.2 + 0.8 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(a.level(.lapping), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.2, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0)
        XCTAssertEqual(a.level(.owl), 0)
        XCTAssertEqual(a.level(.drips), 0.2, accuracy: 1e-6, "drips after the sleet")
        XCTAssertEqual(a.wetness, 0.2, accuracy: 1e-6)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.45, .neutral), accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0)
        XCTAssertNil(a.thunder, "the cold sky has no lightning")
        var day = AuroraFjordModel()
        day.setSky(fjordSkyState(sun: 20, hour: 13))
        XCTAssertEqual(fjordStep(&day, seconds: 0.1).ambience.level(.iceGroan), 0.5, accuracy: 1e-6)
        var blizzard = AuroraFjordModel()
        var b = fjordSkyState(sun: 10, hour: 13); b.rain = 1; b.weather = .storm; b.gust = 0.6
        blizzard.setSky(b)
        XCTAssertGreaterThanOrEqual(fjordStep(&blizzard, seconds: 0.1).ambience.level(.wind), 0.9, "a blizzard howls")
    }

    func testFjordDefaults() {
        XCTAssertEqual(ThemeRegistry.resolve(AuroraFjordModel.id), AuroraFjordModel.id)
        XCTAssertEqual(AuroraFjordModel.id, "aurora-fjord")
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == AuroraFjordModel.id && $0.name == "Aurora Fjord" })
        XCTAssertTrue(ThemeRegistry.isWorld(AuroraFjordModel.id))
        assertValidParameters(AuroraFjordModel.parameters)
        let params = ThemeRegistry.parameterSet(for: AuroraFjordModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("light.hold"), "Deep night")
        XCTAssertEqual(params.choice("aurora.mode"), "Always")
        XCTAssertEqual(params.choice("visual"), "Curtain Lights")
        XCTAssertEqual(AuroraFjordModel.visuals, ["Curtain Lights", "Galaxy Warp"])
        XCTAssertEqual(params.number("floes"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("village"), 0.7, accuracy: 1e-9)
        XCTAssertEqual(params.number("swell"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        XCTAssertTrue(AuroraFjordModel.parameters.first { $0.id == "floes" }?.hero ?? false)
        XCTAssertEqual(Mood.electricAwe, Mood(energy: 0.45, warmth: 0.25, brightness: 0.45, space: 0.95, motion: 0.6))
    }

    func testFjordFrameCarriesRipplesAndFloes() {
        var model = AuroraFjordModel()
        model.setSky(fjordSkyState(sun: -30, hour: 23))
        for n: UInt8 in [60, 67] { model.handle(.noteOn(note: n, velocity: 0.8)) }
        let f = fjordStep(&model, seconds: 2)
        XCTAssertEqual(f.ripples.count, 2)
        XCTAssertTrue((AuroraFjordModel.minFloes...AuroraFjordModel.maxFloes).contains(f.floes.count), "\(f.floes.count)")
        XCTAssertGreaterThan(f.glow, 0.3, "held notes swell the curtain")
        XCTAssertTrue(f.villageLit)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.warp)
        for r in f.ripples { XCTAssertTrue(r.position.isFinite && r.age.isFinite && r.strength.isFinite && r.width.isFinite) }
        for fl in f.floes {
            XCTAssertTrue(fl.x.isFinite && fl.depth.isFinite && fl.size.isFinite && fl.angle.isFinite && fl.drift.isFinite)
            XCTAssertTrue((0...1).contains(fl.x) && (0...1).contains(fl.depth))
        }
        XCTAssertTrue(f.glow.isFinite && f.hueShift.isFinite && f.tensePulse.isFinite)
        // The floes drift, deterministically from a fresh world.
        var again = AuroraFjordModel()
        again.setSky(fjordSkyState(sun: -30, hour: 23))
        XCTAssertEqual(fjordStep(&again, seconds: 2).floes, f.floes)
        XCTAssertNotEqual(fjordStep(&again, seconds: 3).floes, f.floes, "they keep drifting")
        // The setting sets how many: 6 at none, 14 at most.
        var few = AuroraFjordModel(), many = AuroraFjordModel()
        XCTAssertEqual(fjordStep(&few, seconds: 0.1, state: ThemeState(values: ["floes": .number(0)])).floes.count, 6)
        XCTAssertEqual(fjordStep(&many, seconds: 0.1, state: ThemeState(values: ["floes": .number(1)])).floes.count, 14)
        // By day the village is dark; Galaxy Warp streaks instead of rippling.
        var day = AuroraFjordModel()
        day.setSky(fjordSkyState(sun: 20, hour: 13))
        day.handle(.noteOn(note: 60, velocity: 0.9))
        let w = fjordStep(&day, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertFalse(w.villageLit)
        XCTAssertNotNil(w.warp)
        XCTAssertTrue(w.ripples.isEmpty, "Galaxy Warp replaces the ripples")
    }
}

// MARK: - Tea House Snow

extension WorldTests {
    private func teaHouseStep(_ model: inout TeaHouseSnowModel, seconds: Double, state: ThemeState = ThemeState()) -> TeaHouseFrame {
        let p = ThemeRegistry.parameterSet(for: TeaHouseSnowModel.id, state: state)
        var frame: TeaHouseFrame?
        for _ in 0..<max(1, Int((seconds * 30).rounded())) {
            frame = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    private func teaHouseSky(sun altitude: Double, hour: Double) -> SkyState {
        var s = SkyState(); s.sun = SkyDirection(azimuth: 180, altitude: altitude); s.hourOfDay = hour
        return s
    }

    func testTeaHouseDefaults() {
        XCTAssertEqual(TeaHouseSnowModel.id, "tea-house-snow")
        XCTAssertEqual(ThemeRegistry.resolve(TeaHouseSnowModel.id), TeaHouseSnowModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == TeaHouseSnowModel.id && $0.name == "Tea House Snow" })
        XCTAssertTrue(ThemeRegistry.isWorld(TeaHouseSnowModel.id))
        assertValidParameters(TeaHouseSnowModel.parameters)
        XCTAssertEqual(TeaHouseSnowModel.parameters.map(\.id),
                       ["visual", "light.hold", "aurora.mode", "meteors.mode", "screens", "steam", "blossom", "keys.show", "keys.height"])
        let params = ThemeRegistry.parameterSet(for: TeaHouseSnowModel.id, state: ThemeState())
        XCTAssertEqual(TeaHouseSnowModel.visuals, ["Steam Lines", "Frost Grow"])
        XCTAssertEqual(params.choice("visual"), "Steam Lines")
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.number("screens"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("steam"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("blossom"), 0.4, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        func spec(_ id: String) -> ParamSpec? { TeaHouseSnowModel.parameters.first { $0.id == id } }
        XCTAssertEqual(spec("screens")?.name, "Screens open")
        XCTAssertEqual(spec("steam")?.name, "Tea steam")
        XCTAssertEqual(spec("blossom")?.name, "Plum blossom")
        XCTAssertEqual(Set(TeaHouseSnowModel.parameters.filter(\.hero).map(\.id)), ["screens", "steam"])
        XCTAssertEqual(Mood.delicate, Mood(energy: 0.2, warmth: 0.55, brightness: 0.5, space: 0.3, motion: 0.2))

        // The frame carries Steam Lines and the keys.
        var model = TeaHouseSnowModel()
        model.mood = .delicate
        model.setSky(teaHouseSky(sun: -20, hour: 22))
        model.handle(.noteOn(note: 60, velocity: 0.9))
        let f = teaHouseStep(&model, seconds: 0.5)
        XCTAssertEqual(f.wisps.count, 1)
        XCTAssertEqual(f.wisps.first?.note, 60)
        XCTAssertGreaterThan(f.steamGlow, 0.2, "a held note brightens the steam (0.255 by 0.5 s in this mood)")
        XCTAssertEqual(f.lanternFlake?.time ?? -1, 1.0 / 30, accuracy: 1e-9, "a hard note knocks snow off the lantern's cap")
        XCTAssertEqual(f.ribbons, 3, "Tea steam 0.6: three ribbons")
        XCTAssertEqual(f.ribbonPath, SteamLines.straight)
        XCTAssertEqual(f.screensOpen, 0.5, accuracy: 1e-6)
        XCTAssertEqual(f.blossom, 0.4, accuracy: 1e-6)
        XCTAssertTrue(f.patches.isEmpty)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertTrue(f.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertEqual(f.mood, .delicate)
        XCTAssertNil(f.warp, "no Galaxy Warp in the tea house")
        XCTAssertEqual(f.time, 0.5, accuracy: 1e-9)
        // The steam's ribbons follow the setting: a thread at 0, a steaming bowl at 1.
        var thin = TeaHouseSnowModel(), thick = TeaHouseSnowModel()
        XCTAssertEqual(teaHouseStep(&thin, seconds: 0.1, state: ThemeState(values: ["steam": .number(0)])).ribbons, 2)
        XCTAssertEqual(teaHouseStep(&thick, seconds: 0.1, state: ThemeState(values: ["steam": .number(1)])).ribbons, 4)
        var closed = TeaHouseSnowModel()
        XCTAssertEqual(teaHouseStep(&closed, seconds: 0.1, state: ThemeState(values: ["screens": .number(0)])).screensOpen, 0)

        // Frost Grow on the screens' paper instead: notes melt patches in the frost, the steam rests.
        var frosty = TeaHouseSnowModel()
        var cold = teaHouseSky(sun: -20, hour: 22); cold.frost = 0.5
        frosty.setSky(cold)
        frosty.handle(.noteOn(note: 64, velocity: 0.9))
        let g = teaHouseStep(&frosty, seconds: 3, state: ThemeState(values: ["visual": .choice("Frost Grow")]))
        XCTAssertEqual(g.patches.count, 1)
        XCTAssertGreaterThan(g.frostLevel, 0.5 * 0.6 * 0.5, "the cold sky's frost on the paper, and Frost Grow's growth")
        XCTAssertTrue(g.wisps.isEmpty)
        XCTAssertEqual(g.steamGlow, 0)
        XCTAssertEqual(g.puff, .still)
        XCTAssertNil(g.lanternFlake, "the lantern's flake is Steam Lines'")
        XCTAssertEqual(g.ribbons, 3, "the tea still steams")

        // Switching visuals lets held notes go: back on Steam Lines, the wisp is no longer drawn up.
        let back = teaHouseStep(&model, seconds: 0.1, state: ThemeState(values: ["visual": .choice("Frost Grow")]))
        XCTAssertTrue(back.wisps.isEmpty)
        let again = teaHouseStep(&model, seconds: 0.1)
        XCTAssertTrue(again.wisps.allSatisfy { !$0.held })

        // Deterministic: a fresh tea house, the same notes, the same steam.
        func steam() -> TeaHouseFrame {
            var m = TeaHouseSnowModel()
            m.setSky(teaHouseSky(sun: -20, hour: 22))
            for (i, n) in [60, 62, 64, 67, 72].enumerated() {
                m.handle(.noteOn(note: UInt8(n), velocity: 0.5 + 0.1 * Float(i)))
                _ = teaHouseStep(&m, seconds: 0.2)
            }
            return teaHouseStep(&m, seconds: 1)
        }
        let s1 = steam(), s2 = steam()
        XCTAssertEqual(s1.wisps, s2.wisps)
        XCTAssertEqual(s1.ribbonPath, s2.ribbonPath)
        XCTAssertEqual(s1.lanternFlake, s2.lanternFlake)
        XCTAssertNotEqual(s1.ribbonPath, SteamLines.straight, "the run shaped the ribbon")
    }

    func testTeaHouseTurnsRainToSnow() {
        var rain = teaHouseSky(sun: 20, hour: 13); rain.rain = 0.75; rain.weather = .rain; rain.nextWeather = .rain
        rain.lightning = 0.5; rain.wetness = 0.7; rain.fireflies = 0.4; rain.rainbow = 0.5
        var model = TeaHouseSnowModel()
        model.setSky(rain)
        let f = teaHouseStep(&model, seconds: 0.1)
        XCTAssertEqual(f.sky, WorldWeather.cold(rain), "the cabin's cold rule")
        XCTAssertEqual(f.sky.snow, 0.75, accuracy: 1e-6)
        XCTAssertEqual(f.sky.rain, 0)
        XCTAssertEqual(f.sky.lightning, 0)
        XCTAssertEqual(f.sky.wetness, 0)
        XCTAssertEqual(f.sky.rainbow, 0)
        XCTAssertEqual(f.sky.fireflies, 0)
        XCTAssertEqual(f.sky.weather, .snow)
        XCTAssertEqual(f.ambience.wetness, 0)
        XCTAssertNil(f.ambience.thunder)
        XCTAssertEqual(f.ambience.snowOnGlass, 0.75, accuracy: 1e-6, "the rain ticks on the paper as snow")
        XCTAssertEqual(f.ambience.level(.drips), 0, "nothing drips: it never got wet")
        XCTAssertLessThan(f.blossom, 0.4 * 0.3, "the plum's blossoms hide while it snows this hard")

        var storm = teaHouseSky(sun: 20, hour: 13); storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6
        storm.weather = .storm; storm.nextWeather = .storm; storm.lightning = 1
        var stormy = TeaHouseSnowModel()
        stormy.setSky(storm)
        let b = teaHouseStep(&stormy, seconds: 0.1)
        XCTAssertEqual(b.sky.weather, .blizzard)
        XCTAssertEqual(b.sky.snow, 1)
        XCTAssertEqual(b.sky.lightning, 0)
        XCTAssertEqual(b.blossom, 0, "none in a blizzard")
        XCTAssertGreaterThanOrEqual(b.ambience.level(.wind), 0.95, "a blizzard howls round the tea house")

        // Light snow leaves the blossoms; rime frost and diamond dust are at home here.
        var flurry = teaHouseSky(sun: 20, hour: 13); flurry.snow = 0.3; flurry.weather = .flurries; flurry.nextWeather = .flurries
        var light = TeaHouseSnowModel()
        light.setSky(flurry)
        XCTAssertEqual(teaHouseStep(&light, seconds: 0.1).blossom, 0.4, accuracy: 1e-6)
        var fog = teaHouseSky(sun: 5, hour: 8); fog.weather = .rime; fog.nextWeather = .rime; fog.rime = 0.8; fog.mist = 0.85
        var rimed = TeaHouseSnowModel()
        rimed.setSky(fog)
        let r = teaHouseStep(&rimed, seconds: 0.1)
        XCTAssertEqual(r.sky.weather, .rime)
        XCTAssertEqual(r.sky.rime, 0.8, accuracy: 1e-6)
        XCTAssertEqual(TeaHouseSnowModel.blossom(0.4, snow: 0.5), 0.4, accuracy: 1e-6)
        XCTAssertEqual(TeaHouseSnowModel.blossom(0.4, snow: 0.85), 0, accuracy: 1e-6)
        XCTAssertEqual(TeaHouseSnowModel.blossom(.nan, snow: .nan), 0)
    }

    /// Spec §8.1: the kettle 0.35, the paper screens 0.4 × (0.4 + wind), the temple bell 0.5 from dusk and through the
    /// night (0.25 by day), the wind 0.1 + gust, snow ticking on the paper (snow × indoors), birds at dawn 0.2; indoors
    /// 0.8 − 0.5 × screens (and the rime's hush on top); closeness from 0.75.
    func testTeaHouseAmbience() {
        var model = TeaHouseSnowModel()
        model.mood = .delicate
        var s = teaHouseSky(sun: 30, hour: 12); s.snow = 0.8; s.wind = 0.3; s.gust = 0.3
        model.setSky(s)
        let a = teaHouseStep(&model, seconds: 0.1).ambience
        XCTAssertEqual(a.level(.kettle), 0.35, accuracy: 1e-9, "the iron kettle on the brazier")
        XCTAssertEqual(a.level(.paperScreens), 0.4 * (0.4 + 0.3), accuracy: 1e-6)
        XCTAssertEqual(a.level(.wind), 0.1 + 0.3, accuracy: 1e-6)
        XCTAssertEqual(a.indoors, 0.8 - 0.5 * 0.5, accuracy: 1e-9, "the screens half open")
        XCTAssertEqual(a.level(.rainOnGlass), 0.8 * 0.55, accuracy: 1e-6, "snow ticking on the paper")
        XCTAssertEqual(a.snowOnGlass, 0.8, accuracy: 1e-6)
        XCTAssertEqual(a.level(.templeBell), 0.25, accuracy: 1e-9, "the bell by day")
        XCTAssertEqual(a.level(.dawnChorus), 0)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.75, .delicate), accuracy: 1e-9)
        XCTAssertEqual(a.density, MoodLook.ambienceDensity(.delicate), accuracy: 1e-9)
        XCTAssertEqual(a.wetness, 0)
        XCTAssertEqual(a.nightCool, 0)
        for source in [AmbienceSource.fire, .crickets, .owl, .surf, .road, .clock, .lapping] { XCTAssertEqual(a.level(source), 0, "\(source)") }

        // Indoors follows the screens (0.8 closed … 0.3 open), and the snow's ticks on the paper with it.
        for screens in [0.0, 0.25, 1.0] {
            var m = TeaHouseSnowModel()
            m.setSky(s)
            let b = teaHouseStep(&m, seconds: 0.1, state: ThemeState(values: ["screens": .number(screens)])).ambience
            XCTAssertEqual(b.indoors, 0.8 - 0.5 * screens, accuracy: 1e-9, "screens \(screens)")
            XCTAssertEqual(b.level(.rainOnGlass), 0.8 * (0.8 - 0.5 * screens), accuracy: 1e-6, "screens \(screens)")
            XCTAssertEqual(TeaHouseSnowModel.indoors(screens: screens), 0.8 - 0.5 * screens, accuracy: 1e-12)
        }
        // The snow's ticks follow the snow: none without it, half as many at half the snow.
        func ticks(_ snow: Float) -> (Double, Double) {
            var m = TeaHouseSnowModel()
            var snowy = s; snowy.snow = snow
            m.setSky(snowy)
            let a = teaHouseStep(&m, seconds: 0.1).ambience
            return (a.level(.rainOnGlass), a.snowOnGlass)
        }
        XCTAssertEqual(ticks(0).0, 0)
        XCTAssertEqual(ticks(0).1, 0)
        XCTAssertEqual(ticks(0.4).0, 0.5 * ticks(0.8).0, accuracy: 1e-6)
        XCTAssertEqual(ticks(0.4).1, 0.4, accuracy: 1e-6)

        // The bell rings out fuller at dusk and through the night than at noon; birds at dawn.
        func scene(sun: Double, hour: Double) -> AmbienceScene {
            var m = TeaHouseSnowModel()
            m.setSky(teaHouseSky(sun: sun, hour: hour))
            return teaHouseStep(&m, seconds: 0.1).ambience
        }
        let noon = scene(sun: 60, hour: 12), dusk = scene(sun: -3, hour: 18.5), night = scene(sun: -30, hour: 23)
        XCTAssertEqual(noon.level(.templeBell), 0.25, accuracy: 1e-9)
        XCTAssertGreaterThan(dusk.level(.templeBell), noon.level(.templeBell) + 0.2, "louder at dusk")
        XCTAssertEqual(night.level(.templeBell), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scene(sun: 2, hour: 6.5).level(.dawnChorus), 0.2, accuracy: 1e-9)
        XCTAssertEqual(dusk.level(.dawnChorus), 0, "no dawn chorus in the evening")
        XCTAssertEqual(night.level(.dawnChorus), 0)

        // Rime: a rimed garden hushes the outdoors a little more and the wind drops.
        var rimed = s; rimed.rime = 1
        var r = TeaHouseSnowModel()
        r.setSky(rimed)
        let hush = teaHouseStep(&r, seconds: 0.1).ambience
        XCTAssertEqual(hush.indoors, 0.55 + 0.15, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(hush.level(.wind), 0.15 + 1e-9)
        XCTAssertEqual(hush.level(.rainOnGlass), 0.8 * 0.55, accuracy: 1e-6, "the ticks are on the paper: the rime doesn't hush them")
    }
}

// MARK: Zen Rock Garden

extension WorldTests {
    private func gardenStep(_ model: inout ZenRockGardenModel, seconds: Double, dt: Double = 1.0 / 30,
                            state: ThemeState = ThemeState()) -> ZenGardenFrame {
        let p = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: state)
        var frame: ZenGardenFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        return frame!
    }

    /// A sky over the garden: the sun's altitude, the local hour, the day of the year, and the hemisphere (Kyoto's
    /// latitude in the north, Melbourne's in the south).
    private func gardenSky(sun altitude: Double, hour: Double, day: Int = 105, south: Bool = false) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 100, altitude: altitude)
        s.hourOfDay = hour
        s.dayOfYear = day
        s.latitude = south ? -37.81 : 35.01
        s.hemisphere = south ? -1 : 1
        return s
    }

    func testGardenDefaults() throws {
        XCTAssertEqual(ZenRockGardenModel.id, "zen-rock-garden")
        XCTAssertEqual(ThemeRegistry.resolve(ZenRockGardenModel.id), ZenRockGardenModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == ZenRockGardenModel.id && $0.name == "Zen Rock Garden" })
        XCTAssertTrue(ThemeRegistry.isWorld(ZenRockGardenModel.id))
        assertValidParameters(ZenRockGardenModel.parameters)
        let params = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: ThemeState())
        XCTAssertEqual(ZenRockGardenModel.visuals, ["Rake Lines", "Galaxy Warp"])
        XCTAssertEqual(params.choice("visual"), "Rake Lines")
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.number("ridge"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("moss"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.choice("season"), "Follow the date")
        XCTAssertEqual(ZenRockGardenModel.seasons, ["Follow the date", "Spring", "Summer", "Autumn", "Winter"])
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        let ridge = try XCTUnwrap(ZenRockGardenModel.parameters.first { $0.id == "ridge" })
        XCTAssertTrue(ridge.hero)
        XCTAssertEqual(ridge.name, "Rake depth")
        XCTAssertEqual(ZenRockGardenModel.parameters.first { $0.id == "moss" }?.name, "Moss")
        XCTAssertEqual(Mood.orderedCalm, Mood(energy: 0.15, warmth: 0.45, brightness: 0.55, space: 0.5, motion: 0.15))

        // A still garden shows the morning's pattern and has nothing new to upload.
        var model = ZenRockGardenModel()
        model.setSky(gardenSky(sun: 20, hour: 9))
        let still = gardenStep(&model, seconds: 1)
        XCTAssertEqual(still.field.heights.count, RakeField.width * RakeField.height)
        XCTAssertEqual(still.field.heights, RakeLines.morning)
        XCTAssertEqual(still.field.version, 0)
        XCTAssertFalse(still.field.dirty)
        XCTAssertEqual(still.keys.count, 88)
        XCTAssertNil(still.wave)
        XCTAssertNil(still.warp)
        // A note rakes a ring round the tall stone, and the field moves on a version.
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let raked = gardenStep(&model, seconds: 1.0 / 30)
        XCTAssertEqual(raked.rings.count, 1)
        XCTAssertEqual(raked.rings.first?.stone, 2)
        XCTAssertEqual(raked.field.version, 1)
        XCTAssertTrue(raked.field.dirty)
        XCTAssertTrue(raked.keys.contains { $0.key.note == 60 && $0.pressed })
        // Galaxy Warp streaks instead of raking.
        model.handle(.noteOn(note: 67, velocity: 0.8))
        let warped = gardenStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(warped.warp)
        XCTAssertEqual(warped.rings.count, 1, "no new ring")

        // Rain darkens the gravel at once; snow fills the grooves over minutes and melts in the sun.
        var rainy = ZenRockGardenModel()
        var wet = gardenSky(sun: 20, hour: 11)
        wet.rain = 0.8
        wet.wetness = 0.1
        rainy.setSky(wet)
        XCTAssertEqual(gardenStep(&rainy, seconds: 0.1).wetness, 0.48, accuracy: 1e-6)
        var snowy = ZenRockGardenModel()
        var snow = gardenSky(sun: 5, hour: 9, day: 20)
        snow.snow = 1
        snowy.setSky(snow)
        let early = gardenStep(&snowy, seconds: 10, dt: 0.25).snowCover
        XCTAssertTrue(early > 0 && early < 0.1, "\(early)")
        let deep = gardenStep(&snowy, seconds: 600, dt: 0.25).snowCover
        XCTAssertTrue(deep > 0.9 && deep <= 1, "\(deep)")
        snow.snow = 0
        snow.sun = SkyDirection(azimuth: 180, altitude: 30)
        snowy.setSky(snow)
        XCTAssertLessThan(gardenStep(&snowy, seconds: 900, dt: 0.25).snowCover, 0.1, "it melts in the sun")
        // Humid nights bring fireflies over the moss: more moss, more fireflies.
        var humid = gardenSky(sun: -20, hour: 23, day: 200)
        humid.fireflies = 0.8
        var bare = ZenRockGardenModel(), lush = ZenRockGardenModel()
        bare.setSky(humid)
        lush.setSky(humid)
        XCTAssertEqual(gardenStep(&bare, seconds: 0.1, state: ThemeState(values: ["moss": .number(0)])).fireflies, 0.24, accuracy: 1e-6)
        XCTAssertEqual(gardenStep(&lush, seconds: 0.1, state: ThemeState(values: ["moss": .number(1)])).fireflies, 0.8, accuracy: 1e-6)

        // The water-knocker fills and clacks every 15–40 s at a neutral mood, its swing always within 0…1.
        var garden = ZenRockGardenModel()
        garden.setSky(gardenSky(sun: 20, hour: 9))
        let p = ThemeRegistry.parameterSet(for: ZenRockGardenModel.id, state: ThemeState())
        var clacks: [Double] = []
        var previous: Float = 0, lowest: Float = 1, highest: Float = 0
        for i in 1...(200 * 30) {
            let k = garden.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high).knocker
            lowest = min(lowest, k.fill, k.tip, k.clack, k.phase)
            highest = max(highest, k.fill, k.tip, k.clack, k.phase)
            if k.clack > 0, previous == 0 { clacks.append(Double(i) / 30) }
            previous = k.clack
        }
        XCTAssertGreaterThanOrEqual(lowest, 0)
        XCTAssertLessThanOrEqual(highest, 1)
        XCTAssertGreaterThanOrEqual(clacks.count, 4)
        for (a, b) in zip(clacks, clacks.dropFirst()) { XCTAssertTrue((15.8...40.9).contains(b - a), "\(b - a) s between clacks") }
    }

    func testSeasonFollowsTheDateAndHemisphere() throws {
        // 15 January through the real sky: midsummer in Melbourne, midwinter in Kyoto.
        let at = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T03:00:00Z"))
        func frame(_ city: String, season: String = ZenRockGardenModel.followTheDate) -> ZenGardenFrame {
            var settings = SkySettings()
            settings.timeMode = .realTime
            settings.cityID = city
            var model = ZenRockGardenModel()
            model.setSky(LivingSky(settings: settings).step(now: at, dt: 0))
            return gardenStep(&model, seconds: 0.1, state: ThemeState(values: ["season": .choice(season)]))
        }
        let melbourne = frame("melbourne"), kyoto = frame("kyoto")
        XCTAssertEqual(melbourne.sky.dayOfYear, 15)
        XCTAssertEqual(kyoto.sky.dayOfYear, 15)
        XCTAssertEqual(melbourne.sky.hemisphere, -1)
        XCTAssertEqual(kyoto.sky.hemisphere, 1)
        XCTAssertEqual(melbourne.season, .summer)
        XCTAssertEqual(kyoto.season, .winter)
        XCTAssertGreaterThan(melbourne.maple.y, melbourne.maple.x, "a green maple in summer")
        XCTAssertLessThan(kyoto.mapleLeaves, 0.2, "bare in winter")
        // Chosen, the setting decides: autumn in Melbourne's January, and a red maple.
        let autumn = frame("melbourne", season: "Autumn")
        XCTAssertEqual(autumn.season, .autumn)
        XCTAssertGreaterThan(autumn.maple.x, 2 * autumn.maple.y, "red in autumn")
        XCTAssertEqual(frame("kyoto", season: "Summer").season, .summer)

        // The calendar's edges (non-leap day numbers): spring from 1 March, summer from 1 June, autumn from 1
        // September, winter from 1 December; the other way round in the south.
        let north: [(day: Int, season: GardenSeason)] = [(1, .winter), (59, .winter), (60, .spring), (151, .spring),
                                                         (152, .summer), (243, .summer), (244, .autumn), (334, .autumn),
                                                         (335, .winter), (366, .winter)]
        for (day, season) in north {
            XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: day, southern: false), season, "day \(day) in the north")
        }
        let south: [(day: Int, season: GardenSeason)] = [(15, .summer), (60, .autumn), (152, .winter), (244, .spring),
                                                         (308, .spring), (335, .summer)]
        for (day, season) in south {
            XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: day, southern: true), season, "day \(day) in the south")
        }
        XCTAssertEqual(ZenRockGardenModel.season(dayOfYear: 308, southern: false), .autumn, "early November in Kyoto")
        // Through autumn the maple turns from green to gold to red, carrying on from summer's green.
        let green = ZenRockGardenModel.maple(.autumn, progress: 0).colour
        let gold = ZenRockGardenModel.maple(.autumn, progress: 0.35).colour
        let red = ZenRockGardenModel.maple(.autumn, progress: 0.8).colour
        XCTAssertGreaterThan(green.y, green.x)
        XCTAssertGreaterThan(gold.x, green.x)
        XCTAssertGreaterThan(red.x, 2 * red.y)
        XCTAssertLessThan(simd_distance(ZenRockGardenModel.maple(.summer, progress: 1).colour, green), 0.05)
        XCTAssertEqual(ZenRockGardenModel.maple(.autumn, progress: 1).leaves, ZenRockGardenModel.maple(.winter, progress: 0).leaves,
                       accuracy: 1e-6, "the last leaves fall early in winter")
        XCTAssertLessThan(simd_distance(ZenRockGardenModel.maple(.autumn, progress: 1).colour, ZenRockGardenModel.maple(.winter, progress: 0).colour), 1e-6)
        XCTAssertLessThan(ZenRockGardenModel.maple(.winter, progress: 0.5).leaves, 0.2)
    }

    func testGardenAmbience() {
        func scene(_ sky: SkyState, season: String = ZenRockGardenModel.followTheDate, mood: Mood = .neutral) -> AmbienceScene {
            var model = ZenRockGardenModel()
            model.mood = mood
            model.setSky(sky)
            return gardenStep(&model, seconds: 0.1, state: ThemeState(values: ["season": .choice(season)])).ambience
        }
        // A spring morning in Kyoto (mid-April, 07:00, the sun 12° up): the warbler sings by the water-knocker.
        let springMorning = gardenSky(sun: 12, hour: 7, day: 105)
        let a = scene(springMorning, mood: .orderedCalm)
        XCTAssertEqual(a.level(.waterKnocker), 0.6, accuracy: 1e-9)
        XCTAssertEqual(a.level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.breeze), 0.25, accuracy: 1e-9)
        XCTAssertEqual(a.level(.templeBell), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.crickets), 0)
        XCTAssertEqual(a.level(.dawnChorus), 0, accuracy: 1e-9, "the sun is up past the dawn chorus")
        XCTAssertEqual(a.level(.rainOnWater), 0)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.55, .orderedCalm), accuracy: 1e-9)
        XCTAssertEqual(a.density, MoodLook.ambienceDensity(.orderedCalm), accuracy: 1e-9)
        XCTAssertEqual(a.indoors, 0)
        // Summer mornings too, in the north (July) and the south (January).
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 198)).level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 15, south: true)).level(.warbler), 0.5, accuracy: 1e-9)
        // Only then: not in autumn or winter, not in the afternoon, not at night. The knocker, always.
        let quiet: [(name: String, sky: SkyState)] = [
            ("autumn", gardenSky(sun: 12, hour: 7, day: 300)),
            ("winter", gardenSky(sun: 12, hour: 7, day: 15)),
            ("a southern winter", gardenSky(sun: 12, hour: 7, day: 198, south: true)),
            ("a spring afternoon", gardenSky(sun: 40, hour: 15, day: 105)),
            ("a spring night", gardenSky(sun: -20, hour: 23, day: 105)),
        ]
        for (name, sky) in quiet {
            let s = scene(sky)
            XCTAssertEqual(s.level(.warbler), 0, name)
            XCTAssertEqual(s.level(.waterKnocker), 0.6, accuracy: 1e-9, "\(name): the knocker always")
            XCTAssertEqual(s.level(.templeBell), 0.3, accuracy: 1e-9, name)
        }
        // A chosen season decides over the date.
        XCTAssertEqual(scene(gardenSky(sun: 12, hour: 7, day: 300), season: "Spring").level(.warbler), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scene(springMorning, season: "Winter").level(.warbler), 0)
        // Summer nights' crickets; the dawn chorus at first light; rain in the basin, drips after; rime's hush.
        XCTAssertEqual(scene(gardenSky(sun: -20, hour: 23, day: 198)).level(.crickets), 0.4, accuracy: 1e-9)
        XCTAssertEqual(scene(gardenSky(sun: -20, hour: 23, day: 105)).level(.crickets), 0, "crickets are summer's")
        XCTAssertEqual(scene(gardenSky(sun: -1, hour: 5.5, day: 105)).level(.dawnChorus), 0.3, accuracy: 1e-9)
        var rain = gardenSky(sun: 30, hour: 13)
        rain.rain = 0.6
        rain.wind = 0.3
        let r = scene(rain)
        XCTAssertEqual(r.level(.rainOnWater), 0.3, accuracy: 1e-6)
        XCTAssertEqual(r.level(.breeze), 0.55, accuracy: 1e-6)
        XCTAssertEqual(r.level(.drips), 0)
        var after = gardenSky(sun: 30, hour: 13)
        after.wetness = 0.5
        XCTAssertEqual(scene(after).level(.drips), 0.5, accuracy: 1e-6)
        XCTAssertEqual(scene(after).wetness, 0.5, accuracy: 1e-6)
        var rimed = gardenSky(sun: 5, hour: 8)
        rimed.rime = 0.9
        XCTAssertEqual(scene(rimed).indoors, 0.15, accuracy: 1e-9)
    }
}

// MARK: - Sets 11 & 12: the warm rule, sea smoke's hush, and the meteors in every night-sky world

extension WorldTests {
    /// The warm-world rule (spec §7.5): snow and flurries fall as rain, blizzards become squalls, sleet and hail rain;
    /// frost, rime, diamond dust and its pillars, ice fog and sea smoke never happen (the sea smoke and ice fog a light
    /// haze, and their ice's halos go); fireflies are left alone.
    func testWarmRule() {
        func kind(_ k: WeatherKind, _ edit: (inout SkyState) -> Void = { _ in }) -> SkyState {
            var s = sky(sun: 20, hour: 9); s.weather = k; s.nextWeather = k
            edit(&s)
            return s
        }
        let snow = WorldWeather.warm(kind(.snow) { $0.snow = 0.8; $0.frost = 0.6; $0.halo = 0.2 })
        XCTAssertEqual(snow.weather, .rain)
        XCTAssertEqual(snow.rain, 0.8, accuracy: 1e-6, "snow falls as rain")
        XCTAssertEqual([snow.snow, snow.frost], [0, 0])
        let flurries = WorldWeather.warm(kind(.flurries) { $0.snow = 0.3 })
        XCTAssertEqual(flurries.weather, .rain)
        XCTAssertEqual(flurries.rain, 0.3, accuracy: 1e-6)
        let blizzard = WorldWeather.warm(kind(.blizzard) { $0.snow = 1; $0.wind = 1; $0.gust = 1; $0.mist = 0.6; $0.frost = 0.9 })
        XCTAssertEqual(blizzard.weather, .squall)
        XCTAssertEqual([blizzard.rain, blizzard.snow, blizzard.frost], [1, 0, 0])
        XCTAssertEqual([blizzard.wind, blizzard.gust], [1, 1], "a squall's wind")
        for k in [WeatherKind.sleet, .hail] {
            let w = WorldWeather.warm(kind(k) { $0.rain = 0.5; $0.snow = 0.4 })
            XCTAssertEqual(w.weather, .rain, "\(k)")
            XCTAssertEqual([w.rain, w.snow], [0.5, 0], "\(k)")
        }
        XCTAssertEqual(WorldWeather.warm(kind(.freezingDrizzle) { $0.rain = 0.25; $0.frost = 0.5 }).weather, .drizzle)
        // Sea smoke and ice fog: a light haze, no steam, and the swell of any clear morning.
        let smoke = WorldWeather.warm(kind(.seaSmoke) { $0.steam = 1; $0.mist = 0.35; $0.frost = 0.9; $0.halo = 0.3 })
        XCTAssertEqual(smoke.steam, 0)
        XCTAssertGreaterThanOrEqual(smoke.mist, 0.25)
        XCTAssertEqual(smoke.mist, 0.25, accuracy: 1e-6, "a light morning haze")
        XCTAssertEqual([smoke.frost, smoke.halo], [0, 0])
        XCTAssertEqual(smoke.weather, .clear)
        XCTAssertEqual(OceanSwell.weatherScale(smoke), 1, accuracy: 1e-6)
        let iceFog = WorldWeather.warm(kind(.iceFog) { $0.mist = 0.7; $0.halo = 0.8; $0.frost = 0.8 })
        XCTAssertEqual(iceFog.mist, 0.25, accuracy: 1e-6)
        XCTAssertEqual([iceFog.halo, iceFog.frost], [0, 0])
        // Rime, diamond dust, pillars and frost: none.
        let rime = WorldWeather.warm(kind(.rime) { $0.rime = 0.8; $0.frost = 1; $0.mist = 0.85 })
        XCTAssertEqual([rime.rime, rime.frost], [0, 0])
        XCTAssertEqual(rime.weather, .mist, "fog that never freezes")
        XCTAssertFalse(WeatherAmbience.inRime(rime))
        let dust = WorldWeather.warm(kind(.diamondDust) { $0.diamondDust = 1; $0.pillar = 1; $0.frost = 0.9; $0.halo = 1 })
        XCTAssertEqual([dust.diamondDust, dust.pillar, dust.frost, dust.halo], [0, 0, 0, 0])
        XCTAssertEqual(dust.weather, .clear)
        // Fireflies are left alone; a plain sky is left as it is.
        let humid = WorldWeather.warm(kind(.humid) { $0.fireflies = 0.9; $0.mist = 0.35 })
        XCTAssertEqual(humid.fireflies, 0.9)
        XCTAssertEqual(humid.weather, .humid)
        var clear = kind(.clear) { $0.mist = 0.1; $0.halo = 0.1; $0.wind = 0.1 }
        clear.aurora = 0.4
        XCTAssertEqual(WorldWeather.warm(clear), clear)
        // Half way from a clear morning into sea smoke: no steam, and the haze half come.
        var gliding = kind(.clear) { $0.nextWeather = .seaSmoke; $0.weatherBlend = 0.5; $0.steam = 0.5; $0.mist = 0.2; $0.frost = 0.45 }
        gliding.halo = 0.15
        let half = WorldWeather.warm(gliding)
        XCTAssertEqual(half.steam, 0)
        XCTAssertEqual(half.mist, 0.2 + (0.25 - 0.2) * 0.5, accuracy: 1e-6)
        XCTAssertEqual(half.halo, 0.075, accuracy: 1e-6)
        XCTAssertEqual(half.nextWeather, .clear)
        for v in [half.rain, half.snow, half.mist, half.halo, half.frost] { XCTAssertTrue((0...1).contains(v)) }
    }

    /// Sea smoke hushes the outdoors (spec §5): with the steam past 0.3 the wind drops to 0.15 at most, and
    /// `indoorsLift` muffles the outdoor sources (0.15 × min(1, steam / 0.6), or the rime's if that is more); the water
    /// worlds and the still places take it, and a warm world (no steam) is left as it is.
    func testSeaSmokeHushesOutdoors() {
        var smoke = daySky(); smoke.weather = .seaSmoke; smoke.nextWeather = .seaSmoke; smoke.steam = 1
        var levels: [AmbienceSource: Double] = [.wind: 0.6, .breeze: 0.4, .water: 0.8]
        WeatherAmbience.levels(smoke, base: &levels)
        XCTAssertEqual(levels[.wind] ?? -1, 0.15, accuracy: 1e-9)
        XCTAssertEqual(levels[.breeze] ?? -1, 0.4, accuracy: 1e-9, "only the wind drops")
        XCTAssertEqual(levels[.water] ?? -1, 0.8, accuracy: 1e-9)
        XCTAssertTrue(WeatherAmbience.inSeaSmoke(smoke))
        var hush: [AmbienceSource: Double] = [.water: 0.8]
        WeatherAmbience.levels(smoke, base: &hush)
        XCTAssertNil(hush[.wind], "and no wind is added")
        // Thin steam (0.3 or less) leaves the wind as it is.
        var thin = daySky(); thin.steam = 0.3
        XCTAssertFalse(WeatherAmbience.inSeaSmoke(thin))
        var windy: [AmbienceSource: Double] = [.wind: 0.6]
        WeatherAmbience.levels(thin, base: &windy)
        XCTAssertEqual(windy[.wind] ?? -1, 0.6, accuracy: 1e-9)
        // The lift: 0.15 × min(1, steam / 0.6), the rime's if that is more (never the two added).
        XCTAssertEqual(WeatherAmbience.indoorsLift(smoke), 0.15, accuracy: 1e-9)
        XCTAssertEqual(WeatherAmbience.indoorsLift(thin), 0.075, accuracy: 1e-6)
        var both = smoke; both.rime = 0.9
        XCTAssertEqual(WeatherAmbience.indoorsLift(both), 0.15, accuracy: 1e-9)
        var odd = daySky(); odd.steam = .nan
        XCTAssertEqual(WeatherAmbience.indoorsLift(odd), 0)
        XCTAssertFalse(WeatherAmbience.inSeaSmoke(odd))
        // A blizzard's howl still comes through.
        var howling = smoke; howling.snow = 1; howling.gust = 1
        var howl: [AmbienceSource: Double] = [.wind: 0.6]
        WeatherAmbience.levels(howling, base: &howl)
        XCTAssertGreaterThanOrEqual(howl[.wind] ?? 0, 0.95)
        // In the water worlds: a gale over the lake, beach, road, fjord and bay drops, and their outdoors is muffled.
        var gale = smoke; gale.wind = 0.9
        for (name, scene) in scenes(gale) {
            XCTAssertEqual(scene.level(.wind), 0.15, accuracy: 1e-9, name)
            XCTAssertEqual(scene.indoors, 0.15, accuracy: 1e-9, name)
        }
        var fjord = AuroraFjordModel(); fjord.setSky(gale)
        let f = fjordStep(&fjord, seconds: 0.1).ambience
        XCTAssertEqual(f.level(.wind), 0.15, accuracy: 1e-9, "the cold fjord keeps its sea smoke")
        XCTAssertEqual(f.indoors, 0.15, accuracy: 1e-9)
        var bay = BioluminescentBayModel(); bay.setSky(gale)
        let b = bayStep(&bay, seconds: 0.1).ambience
        XCTAssertEqual(b.level(.wind), 0.15, accuracy: 1e-9)
        XCTAssertEqual(b.indoors, 0.15, accuracy: 1e-9)
        var clearGale = daySky(); clearGale.wind = 0.9
        for (name, scene) in scenes(clearGale) {
            XCTAssertEqual(scene.level(.wind), 0.6, accuracy: 1e-5, name)
            XCTAssertEqual(scene.indoors, 0, "\(name): without sea smoke nothing changes")
        }
        // The still places add it to their own indoors.
        var garden = ZenRockGardenModel()
        var morning = gardenSky(sun: 5, hour: 8); morning.steam = 1
        garden.setSky(morning)
        XCTAssertEqual(gardenStep(&garden, seconds: 0.1).ambience.indoors, 0.15, accuracy: 1e-9)
        var teaHouse = TeaHouseSnowModel()
        var cold = teaHouseSky(sun: 5, hour: 8); cold.weather = .seaSmoke; cold.nextWeather = .seaSmoke; cold.steam = 1
        teaHouse.setSky(cold)
        XCTAssertEqual(teaHouseStep(&teaHouse, seconds: 0.1).ambience.indoors, 0.55 + 0.15, accuracy: 1e-9)
        // A warm world has no sea smoke, so no hush.
        let warm = WorldWeather.warm(gale)
        XCTAssertFalse(WeatherAmbience.inSeaSmoke(warm))
        XCTAssertEqual(WeatherAmbience.indoorsLift(warm), 0)
    }

    /// Review focus 4: a world's parameters saved before the meteors decode, and the world follows the calendar; every
    /// night-sky world lists the mode (defaulting to follow), the lounge doesn't.
    func testOldWorldParametersStillLoad() throws {
        let saved = #"{"values":{"glitter":{"number":{"_0":0.9}},"visual":{"choice":{"_0":"Galaxy Warp"}}},"macros":{"glow":0.25}}"#
        let state = try JSONDecoder().decode(ThemeState.self, from: Data(saved.utf8))
        XCTAssertNil(state.values["meteors.mode"])
        let lake = ThemeRegistry.parameterSet(for: MoonlitLakeModel.id, state: state)
        XCTAssertEqual(lake.choice("meteors.mode"), MeteorMode.follow.rawValue)
        XCTAssertEqual(lake.baseNumber("glitter"), 0.9, accuracy: 1e-9, "the rest is kept")
        XCTAssertEqual(lake.choice("visual"), "Galaxy Warp")
        XCTAssertEqual(lake.macros[.glow], 0.25)
        XCTAssertTrue(lake.saved["meteors.mode"] == nil, "following is the default: nothing new to save")
        // A value from a later build (or a typo) falls back to follow too.
        let odd = ThemeState(values: ["meteors.mode": .choice("Sometimes")])
        XCTAssertEqual(ThemeRegistry.parameterSet(for: MoonlitLakeModel.id, state: odd).choice("meteors.mode"), "Follow the calendar")
        // Through the director: the decoded lake shows the calendar's sky (here the Geminids).
        let director = SceneDirector(themeID: MoonlitLakeModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 21; s.frozenPhase = 0; s.cityID = "tokyo"
        s.weatherMode = .pick; s.weather = .clear
        director.sky.reset(settings: s)
        let peak = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-14T03:00:00Z"))
        director.clock = { peak }
        _ = director.step(dt: 1.0 / 30, t: 0, quality: .high)
        XCTAssertEqual(director.lastSky?.shower?.code, "GEM")
        XCTAssertGreaterThan(director.lastSky?.meteorRate ?? 0, 0)
        // Every night-sky world offers the mode, following the calendar by default; the lounge doesn't.
        let nightSkies = [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id,
                          BedroomDawnModel.id, AuroraFjordModel.id, BioluminescentBayModel.id, TeaHouseSnowModel.id,
                          ZenRockGardenModel.id]
        for id in nightSkies {
            let params = ThemeRegistry.parameterSet(for: id, state: ThemeState())
            XCTAssertEqual(params.choice("meteors.mode"), "Follow the calendar", id)
            let spec = try XCTUnwrap(ThemeRegistry.parameters(for: id).first { $0.id == "meteors.mode" }, id)
            XCTAssertEqual(spec.group, "Sky", id)
            assertValidParameters(ThemeRegistry.parameters(for: id))
        }
        XCTAssertEqual(ThemeRegistry.parameterSet(for: SpaceshipLoungeModel.id, state: ThemeState()).choice("meteors.mode"), "")
    }
}

// MARK: - Submarine Window

extension WorldTests {
    private func subStep(_ model: inout SubmarineWindowModel, seconds: Double, dt: Double = 1.0 / 30,
                         state: ThemeState = ThemeState(), quality: QualityLevel = .high) -> SubFrame {
        let p = ThemeRegistry.parameterSet(for: SubmarineWindowModel.id, state: state)
        var frame: SubFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: quality)
        }
        return frame!
    }

    /// A sky over the submarine: the sun's altitude and the local hour, and the moon (down, and new, unless given).
    private func subSky(sun altitude: Double, hour: Double, moon: Double = -30, moonLit: Double = 0) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 150, altitude: altitude)
        s.hourOfDay = hour
        s.moon = SkyDirection(azimuth: 210, altitude: moon)
        s.moonLit = moonLit
        return s
    }

    /// The submarine at a Depth dial under a sky, after a moment.
    private func subFrame(depth: Double, sky: SkyState, mood: Mood = .neutral) -> SubFrame {
        var model = SubmarineWindowModel()
        model.mood = mood
        model.setSky(sky)
        return subStep(&model, seconds: 0.1, state: ThemeState(values: ["depth": .number(depth)]))
    }

    /// The Depth dial's place for a depth in metres (the inverse of the log mapping).
    private func subDial(metres: Double) -> Double { log(metres / 15) / log(1000.0 / 15) }

    func testSubDefaults() throws {
        XCTAssertEqual(SubmarineWindowModel.id, "submarine-window")
        XCTAssertEqual(ThemeRegistry.resolve(SubmarineWindowModel.id), SubmarineWindowModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == SubmarineWindowModel.id && $0.name == "Submarine Window" })
        XCTAssertTrue(ThemeRegistry.isWorld(SubmarineWindowModel.id))
        let ids = ThemeRegistry.entries.map(\.id)
        let garden = try XCTUnwrap(ids.firstIndex(of: ZenRockGardenModel.id))
        XCTAssertEqual(ids[garden + 1], SubmarineWindowModel.id, "registered after the garden")
        assertValidParameters(SubmarineWindowModel.parameters)
        XCTAssertEqual(SubmarineWindowModel.parameters.map(\.id),
                       ["visual", "light.hold", "depth", "lamps", "cabin", "sonar", "keys.show", "keys.height"])
        XCTAssertEqual(SubmarineWindowModel.visuals, ["Deep Lights", "Galaxy Warp"])
        let params = ThemeRegistry.parameterSet(for: SubmarineWindowModel.id, state: ThemeState())
        XCTAssertEqual(params.choice("visual"), "Deep Lights")
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("aurora.mode"), "", "no aurora mode under water")
        XCTAssertEqual(params.choice("meteors.mode"), "", "nor a meteor mode: Snell's window shows the sky's own")
        XCTAssertEqual(params.number("depth"), 0.35, accuracy: 1e-9)
        XCTAssertEqual(params.number("lamps"), 0.35, accuracy: 1e-9)
        XCTAssertEqual(params.number("cabin"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.number("sonar"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        let depth = try XCTUnwrap(SubmarineWindowModel.parameters.first { $0.id == "depth" })
        XCTAssertTrue(depth.hero)
        XCTAssertEqual(depth.name, "Depth")
        XCTAssertEqual(SubmarineWindowModel.parameters.filter(\.hero).map(\.id), ["depth"])
        XCTAssertEqual(SubmarineWindowModel.parameters.first { $0.id == "lamps" }?.name, "Outside lamps")
        XCTAssertEqual(SubmarineWindowModel.parameters.first { $0.id == "cabin" }?.name, "Cabin light")
        XCTAssertEqual(SubmarineWindowModel.parameters.first { $0.id == "sonar" }?.name, "Sonar screen")
        XCTAssertEqual(Mood.deepHush, Mood(energy: 0.3, warmth: 0.3, brightness: 0.15, space: 0.9, motion: 0.45))
        let others: [Mood] = [.serene, .dreamy, .warmHaze, .restless, .hushedWarm, .softWaking, .secretGlow, .delicate,
                              .orderedCalm, .electricAwe]
        XCTAssertFalse(others.contains(.deepHush), "a mood of its own")

        // A frame at the default depth: 65 m, nothing played yet, the marine snow by quality, the console's keys.
        var model = SubmarineWindowModel()
        model.mood = .deepHush
        model.setSky(subSky(sun: 30, hour: 11))
        let f = subStep(&model, seconds: 0.5)
        XCTAssertEqual(f.depth, 0.35, accuracy: 1e-6)
        XCTAssertEqual(f.depthMetres, 65.2, accuracy: 0.1)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.warp)
        XCTAssertTrue(f.creatures.isEmpty && f.shoals.isEmpty && f.siphonophores.isEmpty && f.bubbleStreams.isEmpty)
        XCTAssertTrue(f.sonarBlips.isEmpty)
        XCTAssertEqual(f.mood, .deepHush)
        XCTAssertEqual(f.lamps, 0.35, accuracy: 1e-6)
        XCTAssertEqual(f.cabinLight, 0.5, accuracy: 1e-6)
        XCTAssertEqual(f.sonarScreen, 0.6, accuracy: 1e-6)
        XCTAssertEqual(f.time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.snow.live.count, MarineSnow.count(.high))
        XCTAssertEqual(subStep(&model, seconds: 1.0 / 30, quality: .lite).snow.live.count, 150, "Smooth")
        XCTAssertEqual(subStep(&model, seconds: 1.0 / 30, quality: .ultra).snow.live.count, 400)
        XCTAssertTrue(f.snow.live.allSatisfy { (0...1).contains($0.brightness) })
        let lamps = ThemeState(values: ["lamps": .number(0.9), "cabin": .number(0.2), "sonar": .number(1)])
        let lit = subStep(&model, seconds: 1.0 / 30, state: lamps)
        XCTAssertEqual([lit.lamps, lit.cabinLight, lit.sonarScreen], [0.9, 0.2, 1])

        // A note releases a creature and leaves a blip; the console button lights.
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let played = subStep(&model, seconds: 1.0 / 30)
        XCTAssertEqual(played.creatures.count, 1)
        XCTAssertEqual(played.creatures.first?.kind, .combJelly)
        XCTAssertEqual(played.sonarBlips.count, 1)
        XCTAssertTrue(played.keys.contains { $0.key.note == 60 && $0.pressed })
        // Galaxy Warp streaks through the porthole instead; switching lets the held note go.
        model.handle(.noteOn(note: 67, velocity: 0.8))
        let warped = subStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(warped.warp)
        XCTAssertTrue(warped.creatures.isEmpty, "Galaxy Warp replaces the creatures")
        XCTAssertEqual(warped.sonarBlips.count, 2, "the sonar screen is the cabin's, whatever the visual")
        // Through the director: a world under the Living Sky.
        let director = SceneDirector(themeID: SubmarineWindowModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        director.sky.reset(settings: s)
        let viaDirector = try XCTUnwrap(director.step(dt: 1.0 / 30, t: 0, quality: .high) as? SubFrame)
        XCTAssertGreaterThan(viaDirector.sky.sun.altitude, 0)
        XCTAssertEqual(viaDirector.ambience.level(.sonar), 0.5, accuracy: 1e-9)
    }

    /// The Depth dial is logarithmic (spec §8.1): 15 m at 0, the twilight zone's 200 m at 0.62, 1,000 m at 1; the
    /// default 0.35 is about 65 m, half way the geometric mean (122 m), and each tenth of the dial a like factor (×1.52).
    func testDepthMapsLogarithmically() {
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 0), 15, accuracy: 1e-3)
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 0.62), 200, accuracy: 5)
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 1), 1000, accuracy: 0.05)
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 0.35), 65, accuracy: 1, "the default: about 65 m")
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 0.5), Float((15.0 * 1000).squareRoot()), accuracy: 0.05)
        let tenths = (0...10).map { SubmarineWindowModel.depthMetres(dial: Double($0) / 10) }
        let ratios = zip(tenths, tenths.dropFirst()).map { $1 / $0 }
        for r in ratios { XCTAssertEqual(r, 1.5219, accuracy: 1e-3) }
        XCTAssertEqual(subDial(metres: 200), 0.62, accuracy: 0.005, "the twilight zone starts at 0.62")
        XCTAssertEqual(subDial(metres: 40), 0.2335, accuracy: 0.001)
        // Out of range and odd dials stay inside.
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: -1), 15, accuracy: 1e-3)
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: 7), 1000, accuracy: 0.05)
        XCTAssertEqual(SubmarineWindowModel.depthMetres(dial: .nan), SubmarineWindowModel.depthMetres(dial: 0.35))
        // The frame carries both the dial (for the gauge) and the metres.
        let f = subFrame(depth: 0.62, sky: subSky(sun: 30, hour: 11))
        XCTAssertEqual(f.depth, 0.62, accuracy: 1e-6)
        XCTAssertEqual(f.depthMetres, 200, accuracy: 5)
        XCTAssertEqual(subFrame(depth: 1, sky: subSky(sun: 30, hour: 11)).depthMetres, 1000, accuracy: 0.05)
    }

    /// The sky drives the light (spec §8.1): day, dusk dimming, a full moon's faint light, a moonless night's dark, cloud;
    /// and it falls with depth through the clear ocean (the Underwater Kit's Beer–Lambert bands, averaged): about a third
    /// at 15 m by day, a twentieth at the default 65 m, 1.7% at 100 m, a dim glow at 200 m and nothing at 1,000 m.
    func testLightFallsWithDepthAndNight() {
        let noon = subSky(sun: 60, hour: 12), dusk = subSky(sun: -4, hour: 19), night = subSky(sun: -30, hour: 23)
        let moonlit = subSky(sun: -30, hour: 23, moon: 60, moonLit: 1)
        func surface(_ s: SkyState) -> Float {
            let l = SubmarineWindowModel.surfaceLight(s)
            return (l.x + l.y + l.z) / 3
        }
        XCTAssertEqual(surface(noon), 0.92, accuracy: 0.02, "a high sun: nearly the kit's noon")
        XCTAssertGreaterThan(surface(noon), 4 * surface(dusk), "dusk dims it")
        XCTAssertGreaterThan(surface(dusk), 3 * surface(moonlit))
        XCTAssertGreaterThan(surface(moonlit), 5 * surface(night), "a full moon high up lights the shallows")
        XCTAssertLessThan(surface(night), 0.005, "a moonless night: nearly dark")
        var overcast = noon
        overcast.cloudCover = 1
        XCTAssertLessThan(surface(overcast), 0.45 * surface(noon), "cloud dims it")
        let low = SubmarineWindowModel.surfaceLight(subSky(sun: 3, hour: 7))
        XCTAssertGreaterThan(low.x, 1.2 * low.z, "a low sun's light is warmer")

        let white = SIMD3<Float>(repeating: 1)
        XCTAssertEqual(SubmarineWindowModel.lightFromAbove(white, metres: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(SubmarineWindowModel.lightFromAbove(white, metres: 100), 0.0169, accuracy: 0.0005, "about 1% at 100 m")
        let dials: [Double] = [0, 0.2, 0.35, 0.62, 0.8, 1]
        var bySky: [[Float]] = []
        for sky in [noon, dusk, moonlit, night] {
            let frames = dials.map { subFrame(depth: $0, sky: sky) }
            let light = frames.map(\.lightFromAbove)
            for (a, b) in zip(light, light.dropFirst()) { XCTAssertGreaterThan(a, b, "deeper, darker") }
            XCTAssertLessThan(light[5], 1e-9, "the midnight zone: no light from above at all")
            for f in frames { XCTAssertEqual(f.surfaceLight, SubmarineWindowModel.surfaceLight(f.sky)) }
            bySky.append(light)
        }
        for i in dials.indices {
            XCTAssertGreaterThan(bySky[0][i], bySky[1][i], "noon over dusk at \(dials[i])")
            XCTAssertGreaterThan(bySky[1][i], bySky[2][i], "dusk over moonlight at \(dials[i])")
            XCTAssertGreaterThan(bySky[2][i], bySky[3][i], "moonlight over a moonless night at \(dials[i])")
        }
        XCTAssertEqual(bySky[0][0], 0.30, accuracy: 0.02, "15 m by day")
        XCTAssertEqual(bySky[0][2], 0.045, accuracy: 0.005, "the default 65 m")
        XCTAssertEqual(bySky[0][3], 0.00068, accuracy: 0.0001, "200 m: a dim glow")
    }

    /// Snell's window shows only in the shallows (spec §8.1, §7.3): whole down to 20 m, half at 30 m, gone by 40 m. So
    /// does the surface's weather: a storm churning it, rain pocking it, sea smoke turning it milky. There is never frost
    /// (or rime) under water, and no aurora; the sky's own meteors pass through untouched.
    func testSnellWindowOnlyShallow() {
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: 15), 1)
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: 20), 1)
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: 30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: 40), 0)
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: 65), 0)
        XCTAssertEqual(SubmarineWindowModel.shallow(metres: .nan), 0)
        let day = subSky(sun: 40, hour: 13)
        XCTAssertEqual(subFrame(depth: 0, sky: day).snellVisible, 1, "at 15 m: the whole sky in a bright circle")
        XCTAssertEqual(subFrame(depth: subDial(metres: 30), sky: day).snellVisible, 0.5, accuracy: 1e-3)
        XCTAssertEqual(subFrame(depth: subDial(metres: 40), sky: day).snellVisible, 0, accuracy: 1e-4, "gone by 40 m")
        for d in [0.35, 0.62, 1.0] { XCTAssertEqual(subFrame(depth: d, sky: day).snellVisible, 0, "\(d)") }
        let fading = [0.0, 0.1, 0.15, 0.2, subDial(metres: 40)].map { subFrame(depth: $0, sky: day).snellVisible }
        XCTAssertEqual(fading, fading.sorted(by: >), "it fades as the submarine dives")

        // The surface's weather, only in the shallows.
        var storm = subSky(sun: 20, hour: 15)
        storm.weather = .storm; storm.nextWeather = .storm; storm.rain = 1; storm.wind = 0.9; storm.gust = 0.6
        let shallowStorm = subFrame(depth: 0, sky: storm), deepStorm = subFrame(depth: 0.35, sky: storm)
        XCTAssertEqual(shallowStorm.surfaceWaves, 1, accuracy: 1e-5, "a storm churns it")
        XCTAssertEqual(shallowStorm.rainOnSurface, 1, accuracy: 1e-6, "rain pocks it")
        XCTAssertEqual([deepStorm.surfaceWaves, deepStorm.rainOnSurface, deepStorm.milky], [0, 0, 0], "not at 65 m")
        let calm = subFrame(depth: 0, sky: subSky(sun: 20, hour: 15))
        XCTAssertEqual(calm.surfaceWaves, 0.25, accuracy: 1e-5, "a calm sea's gentle swell")
        XCTAssertEqual(calm.rainOnSurface, 0)
        var smoke = subSky(sun: 2, hour: 7)
        smoke.weather = .seaSmoke; smoke.nextWeather = .seaSmoke; smoke.steam = 1; smoke.mist = 0.35; smoke.frost = 0.9
        let milky = subFrame(depth: 0, sky: smoke)
        XCTAssertEqual(milky.milky, 1, accuracy: 1e-6, "sea smoke turns the window milky")
        XCTAssertLessThan(milky.surfaceWaves, 0.15, "in its still air")
        XCTAssertEqual(subFrame(depth: 0.35, sky: smoke).milky, 0)

        // No frost or rime under water, nothing wet, no fireflies and no aurora; the meteors are the sky's own.
        var cold = smoke
        cold.frost = 1; cold.rime = 1; cold.wetness = 0.8; cold.fireflies = 0.5; cold.aurora = 0.8; cold.auroraStorm = 0.5
        let meteor = Meteor(start: SIMD3<Float>(0.1, 0.5, 0.86), end: SIMD3<Float>(0.3, 0.4, 0.87), born: 0, duration: 1,
                            magnitude: -1)
        cold.meteors = [meteor]
        let under = subFrame(depth: 0, sky: cold).sky
        XCTAssertEqual([under.frost, under.rime, under.wetness, under.fireflies, under.aurora, under.auroraStorm], [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(under.meteors, [meteor], "Snell's window shows the sky's own meteors")
        XCTAssertEqual(under.steam, 1)
        XCTAssertEqual(under.sun, cold.sun)
        XCTAssertEqual(SubmarineWindowModel.underwater(day), day, "a plain day's sky passes as it is")
    }

    /// Ship's time (spec §8.1): the cabin keeps the Living Sky's, a dim, cool white by day and red night lighting at night
    /// (0 with the sun above 2° below the horizon … 1 from 8° below), at any depth; held at deep night, red too.
    func testCabinTurnsRedAtNight() throws {
        XCTAssertEqual(subFrame(depth: 0.35, sky: subSky(sun: 30, hour: 11)).cabinNight, 0)
        XCTAssertEqual(subFrame(depth: 0.35, sky: subSky(sun: -1, hour: 18)).cabinNight, 0, "dusk: still the day's light")
        let twilight = subFrame(depth: 0.35, sky: subSky(sun: -5, hour: 19)).cabinNight
        XCTAssertEqual(twilight, 0.5, accuracy: 1e-6, "switching over through twilight")
        XCTAssertEqual(subFrame(depth: 0.35, sky: subSky(sun: -20, hour: 23)).cabinNight, 1)
        for d in [0.0, 1.0] { XCTAssertEqual(subFrame(depth: d, sky: subSky(sun: -20, hour: 1)).cabinNight, 1, "\(d)") }
        let ramp = [2.0, -2, -3, -5, -7, -8, -12].map { subFrame(depth: 0.35, sky: subSky(sun: $0, hour: 19)).cabinNight }
        XCTAssertEqual(ramp, ramp.sorted(), "redder as the sun sinks")
        let director = SceneDirector(themeID: SubmarineWindowModel.id,
                                     state: ThemeState(values: ["light.hold": .choice(SkyHold.deepNight.rawValue)]),
                                     reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 12; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        director.sky.reset(settings: s)
        let held = try XCTUnwrap(director.step(dt: 1.0 / 30, t: 0, quality: .high) as? SubFrame)
        XCTAssertEqual(held.cabinNight, 1, "the light held at deep night at noon: red")
    }

    /// Each note leaves a fading blip on the sonar screen (spec §8.1): at its pitch class round the 12-tick dial (C at the
    /// top, clockwise, π/6 a semitone), further out the higher it is, as bright as its velocity; it fades over one turn of
    /// the sweep (6 s), at most 24 show, whatever the visual; the sweep goes round once every 6 s.
    func testSonarBlipsFollowNotes() throws {
        XCTAssertEqual(SubmarineWindowModel.bearing(for: 60), 0, accuracy: 1e-6)
        XCTAssertEqual(SubmarineWindowModel.bearing(for: 66), .pi, accuracy: 1e-6, "F♯ opposite C")
        XCTAssertEqual(SubmarineWindowModel.bearing(for: 63), .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(SubmarineWindowModel.bearing(for: 48), SubmarineWindowModel.bearing(for: 72), "each octave on one bearing")
        XCTAssertEqual(SubmarineWindowModel.range(for: 21), 0.2, accuracy: 1e-6)
        XCTAssertEqual(SubmarineWindowModel.range(for: 108), 0.95, accuracy: 1e-6)
        var model = SubmarineWindowModel()
        model.setSky(subSky(sun: 20, hour: 10))
        _ = subStep(&model, seconds: 0.1)
        model.handle(.noteOn(note: 54, velocity: 1))
        model.handle(.noteOn(note: 61, velocity: 0.2))
        let f = subStep(&model, seconds: 1.0 / 30)
        XCTAssertEqual(f.sonarBlips.count, 2)
        let a = try XCTUnwrap(f.sonarBlips.first { $0.note == 54 }), b = try XCTUnwrap(f.sonarBlips.first { $0.note == 61 })
        XCTAssertEqual(a.angle, .pi, accuracy: 1e-6, "F♯3 at the F♯ tick")
        XCTAssertEqual(b.angle, 2 * .pi / 12, accuracy: 1e-6, "C♯4 one tick round")
        XCTAssertEqual(a.strength, 1, accuracy: 1e-6)
        XCTAssertEqual(b.strength, 0.3 + 0.7 * 0.2, accuracy: 1e-6)
        XCTAssertLessThan(a.range, b.range, "the lower note nearer the centre")
        XCTAssertEqual(a.age, 0, "fresh on the frame its note arrives")
        XCTAssertEqual(a.brightness, 1, accuracy: 1e-6)
        let later = try XCTUnwrap(subStep(&model, seconds: 3).sonarBlips.first { $0.note == 54 })
        XCTAssertEqual(later.brightness, 0.5, accuracy: 0.02, "half faded half a turn on")
        XCTAssertTrue(subStep(&model, seconds: 3.1).sonarBlips.isEmpty, "gone after a turn")

        XCTAssertEqual(SubmarineWindowModel.sweep(at: 0), 0)
        XCTAssertEqual(SubmarineWindowModel.sweep(at: 1.5), .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(SubmarineWindowModel.sweep(at: 7.5), .pi / 2, accuracy: 1e-5)
        let s0 = subStep(&model, seconds: 1.0 / 30).sonarSweep
        let s3 = subStep(&model, seconds: 3).sonarSweep
        var turned = s3 - s0
        if turned < 0 { turned += 2 * .pi }
        XCTAssertEqual(turned, .pi, accuracy: 0.01, "half a turn in 3 s")

        for i in 0..<40 { model.handle(.noteOn(note: UInt8(40 + i), velocity: 0.7)) }
        let many = subStep(&model, seconds: 1.0 / 30)
        XCTAssertEqual(many.sonarBlips.count, SubmarineWindowModel.blipCap)
        XCTAssertEqual(many.sonarBlips.last?.note, 79, "the latest kept")
        var warped = SubmarineWindowModel()
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        _ = subStep(&warped, seconds: 0.1, state: warp)
        warped.handle(.noteOn(note: 60, velocity: 0.8))
        let w = subStep(&warped, seconds: 1.0 / 30, state: warp)
        XCTAssertEqual(w.sonarBlips.count, 1, "under Galaxy Warp too")
        XCTAssertNotNil(w.warp)
    }

    /// The submarine's soundscape (spec §5, §8.1): its machinery, the sonar (in your key), a bed of bubbles and the hull
    /// settling, creaking more the deeper it dives; a humpback all year, strongest at mid-depth; a reef's shrimp and the
    /// rain's hiss (rain on the water above, muffled by the hull) only in the shallows; all through the hull (indoors 0.85,
    /// and sea smoke above is no hush below), closeness base 0.7; never the air's sounds, nor thunder.
    func testSubAmbience() {
        func scene(_ depth: Double, _ sky: SkyState, mood: Mood = .neutral) -> AmbienceScene {
            subFrame(depth: depth, sky: sky, mood: mood).ambience
        }
        let day = subSky(sun: 30, hour: 11)
        let a = scene(0.35, day, mood: .deepHush)
        XCTAssertEqual(a.level(.shipHum), 0.35, accuracy: 1e-9)
        XCTAssertEqual(a.level(.airFlow), 0.3, accuracy: 1e-9)
        XCTAssertEqual(a.level(.hullTicks), 0.15, accuracy: 1e-9)
        XCTAssertEqual(a.level(.sonar), 0.5, accuracy: 1e-9)
        XCTAssertEqual(a.level(.bubbles), 0.5, accuracy: 1e-9, "a burst is heard through the hull")
        XCTAssertEqual(a.level(.hullCreak), 0.25 + 0.35 * 0.35, accuracy: 1e-6)
        XCTAssertEqual(a.level(.whaleSong), 0.2 + 0.15 * 0.7, accuracy: 1e-6)
        XCTAssertEqual(a.indoors, 0.85, accuracy: 1e-9)
        XCTAssertEqual(a.closeness, MoodLook.ambienceCloseness(base: 0.7, .deepHush), accuracy: 1e-9)
        XCTAssertEqual(a.density, MoodLook.ambienceDensity(.deepHush), accuracy: 1e-9)
        XCTAssertNil(a.thunder)
        XCTAssertNil(a.bubbleBurst)
        XCTAssertNil(a.key, "the canvas hands every scene the key, for the sonar")

        // Creaks rise with depth.
        let creaks = [0.0, 0.35, 0.62, 1].map { scene($0, day).level(.hullCreak) }
        for (x, y) in zip(creaks, creaks.dropFirst()) { XCTAssertLessThan(x, y) }
        XCTAssertEqual(creaks[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(creaks[3], 0.6, accuracy: 1e-9)
        // Whales: all year, strongest at mid-depth.
        let whales = [0.0, 0.25, 0.5, 0.75, 1].map { scene($0, day).level(.whaleSong) }
        XCTAssertEqual(whales[2], 0.35, accuracy: 1e-9)
        XCTAssertEqual(whales[0], 0.2, accuracy: 1e-9)
        XCTAssertEqual(whales[4], 0.2, accuracy: 1e-9)
        XCTAssertLessThan(whales[1], whales[2])
        XCTAssertLessThan(whales[3], whales[2])
        var winter = day, summer = day
        winter.dayOfYear = 15
        summer.dayOfYear = 200
        XCTAssertEqual(scene(0.5, winter).level(.whaleSong), scene(0.5, summer).level(.whaleSong), "all year")
        XCTAssertGreaterThan(scene(0.5, winter).level(.whaleSong), 0)
        // A reef's shrimp and the rain's hiss, only in the shallows.
        var rain = subSky(sun: 20, hour: 15)
        rain.rain = 0.8; rain.weather = .rain; rain.nextWeather = .rain
        let top = scene(0, rain)
        XCTAssertEqual(top.level(.snappingShrimp), 0.3, accuracy: 1e-9)
        XCTAssertEqual(top.level(.rainOnWater), 0.8 * 0.5, accuracy: 1e-6, "rain on the water above, a soft hiss")
        XCTAssertEqual(top.level(.rainOnGlass), 0, "not rain on glass")
        let thirty = scene(subDial(metres: 30), rain)
        XCTAssertGreaterThan(thirty.level(.snappingShrimp), 0)
        XCTAssertLessThan(thirty.level(.snappingShrimp), top.level(.snappingShrimp))
        XCTAssertGreaterThan(thirty.level(.rainOnWater), 0)
        for d in [subDial(metres: 40), 0.35, 0.62, 1] {
            let s = scene(d, rain)
            XCTAssertEqual(s.level(.snappingShrimp), 0, accuracy: 1e-9, "no shrimp at dial \(d)")
            XCTAssertEqual(s.level(.rainOnWater), 0, accuracy: 1e-9, "no hiss at dial \(d)")
        }
        XCTAssertEqual(scene(0, day).level(.rainOnWater), 0, "no rain, no hiss")
        // Sea smoke above is no hush below; the air's sounds never reach the submarine (a blizzard's howl, drips, birds
        // under a rainbow, a humid night's insects), nor does thunder.
        var smoke = subSky(sun: 2, hour: 7)
        smoke.weather = .seaSmoke; smoke.nextWeather = .seaSmoke; smoke.steam = 1
        XCTAssertEqual(scene(0, smoke).indoors, 0.85, accuracy: 1e-9)
        var wild = subSky(sun: 10, hour: 17)
        wild.weather = .storm; wild.nextWeather = .storm
        wild.snow = 1; wild.gust = 1; wild.wind = 1; wild.wetness = 0.8; wild.rainbow = 1; wild.fireflies = 0.9; wild.lightning = 1
        var model = SubmarineWindowModel()
        model.setSky(wild)
        for _ in 0..<3 {
            let s = subStep(&model, seconds: 1.0 / 30, state: ThemeState(values: ["depth": .number(0)])).ambience
            for source in [AmbienceSource.wind, .drips, .dawnChorus, .crickets, .breeze, .rainOnGlass] {
                XCTAssertEqual(s.level(source), 0, "\(source)")
            }
            XCTAssertNil(s.thunder)
            XCTAssertTrue(Set(s.levels.keys).isSubset(of: SubmarineWindowModel.heardAboard))
            XCTAssertTrue(s.levels.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }
}

// MARK: - Great Barrier Reef

extension WorldTests {
    private func reefStep(_ model: inout GreatBarrierReefModel, seconds: Double, dt: Double = 1.0 / 30,
                          state: ThemeState = ThemeState(), quality: QualityLevel = .high) -> ReefFrame {
        let p = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: state)
        var frame: ReefFrame?
        for _ in 0..<max(1, Int((seconds / dt).rounded())) {
            frame = model.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: quality)
        }
        return frame!
    }

    /// A sky over the reef at Cairns's latitude: the sun's altitude (rising in the east before noon, setting in the west
    /// after), the local hour and the day of the year (320: mid-November).
    private func reefSky(sun altitude: Double, hour: Double, day: Int = 320) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: hour < 12 ? 100 : 260, altitude: altitude)
        s.hourOfDay = hour
        s.dayOfYear = day
        s.latitude = -16.92
        s.hemisphere = -1
        s.subsolar = GeoPoint(latitude: -19, longitude: 0)
        return s
    }

    func testReefDefaults() throws {
        XCTAssertEqual(GreatBarrierReefModel.id, "great-barrier-reef")
        XCTAssertEqual(GreatBarrierReefModel.displayName, "Great Barrier Reef")
        XCTAssertEqual(ThemeRegistry.resolve(GreatBarrierReefModel.id), GreatBarrierReefModel.id)
        XCTAssertTrue(ThemeRegistry.all.contains { $0.id == GreatBarrierReefModel.id && $0.name == "Great Barrier Reef" })
        XCTAssertTrue(ThemeRegistry.isWorld(GreatBarrierReefModel.id))
        let ids = ThemeRegistry.all.map(\.id)
        XCTAssertGreaterThan(try XCTUnwrap(ids.firstIndex(of: GreatBarrierReefModel.id)),
                             try XCTUnwrap(ids.firstIndex(of: ZenRockGardenModel.id)), "after the garden")
        assertValidParameters(GreatBarrierReefModel.parameters)
        let params = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState())
        XCTAssertEqual(GreatBarrierReefModel.visuals, ["Coral Pulse", "Galaxy Warp"])
        XCTAssertEqual(params.choice("visual"), "Coral Pulse")
        XCTAssertEqual(params.choice("light.hold"), "Follow the sky")
        XCTAssertEqual(params.choice("aurora.mode"), "Follow the sky")
        XCTAssertEqual(params.choice("meteors.mode"), "Follow the calendar")
        XCTAssertEqual(params.number("fish"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(params.number("waterline"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(params.choice("spawning"), "Follow the calendar")
        XCTAssertEqual(CoralSpawningSetting.allCases.map(\.rawValue), ["Follow the calendar", "Tonight", "Off"])
        XCTAssertEqual(params.number("keys.show"), 1)
        XCTAssertEqual(params.number("keys.height"), 0.12, accuracy: 1e-9)
        let fish = try XCTUnwrap(GreatBarrierReefModel.parameters.first { $0.id == "fish" })
        XCTAssertTrue(fish.hero)
        XCTAssertEqual(fish.name, "Fish")
        let waterline = try XCTUnwrap(GreatBarrierReefModel.parameters.first { $0.id == "waterline" })
        XCTAssertEqual(waterline.name, "Waterline")
        XCTAssertEqual(try XCTUnwrap(ThemeRegistry.parameters(for: GreatBarrierReefModel.id).first { $0.id == "meteors.mode" }).group, "Sky")
        XCTAssertEqual(Mood.reefAlive, Mood(energy: 0.65, warmth: 0.75, brightness: 0.85, space: 0.45, motion: 0.75))
        // A reef saved before the spawning setting (or with one from a later build) follows the calendar.
        let older = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState(values: ["fish": .number(0.9)]))
        XCTAssertEqual(older.choice("spawning"), "Follow the calendar")
        XCTAssertEqual(older.number("fish"), 0.9, accuracy: 1e-9)
        let odd = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState(values: ["spawning": .choice("Sometimes")]))
        XCTAssertEqual(odd.choice("spawning"), "Follow the calendar")
        let tonight = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState(values: ["spawning": .choice("Tonight")]))
        XCTAssertEqual(tonight.choice("spawning"), "Tonight")

        // A still day on the reef: seven corals resting in their own colours, the school cruising, the camera east.
        var model = GreatBarrierReefModel()
        model.mood = .reefAlive
        model.setSky(reefSky(sun: 50, hour: 11))
        let still = reefStep(&model, seconds: 1)
        XCTAssertEqual(still.corals.count, 7)
        XCTAssertEqual(still.corals.map(\.kind), CoralPulse.kinds)
        XCTAssertTrue(still.corals.allSatisfy { $0.glow == 0 })
        XCTAssertEqual(still.corals.map(\.hue), CoralPulse.hues)
        XCTAssertTrue(still.patches.isEmpty)
        XCTAssertNil(still.colourWave)
        XCTAssertEqual(still.school.positions.count, 56)
        XCTAssertEqual(still.waterlineY, 0.45, accuracy: 1e-6)
        XCTAssertEqual(still.cameraAzimuth, 90, accuracy: 1e-9)
        XCTAssertEqual(still.keys.count, 88)
        XCTAssertNil(still.warp)
        XCTAssertEqual(still.spawn, CoralSpawn.none)
        XCTAssertEqual(still.polypsOpen, 0)
        XCTAssertEqual(still.mood, .reefAlive)
        XCTAssertLessThanOrEqual(abs(still.swellLift), 0.012 + 1e-6, "a calm lagoon's gentle roll")
        XCTAssertEqual(still.lensUnder, 0)
        XCTAssertEqual(still.swellScale, 1, accuracy: 1e-6)
        // A note lights its coral and its key; the dials move the waterline and size the school.
        model.handle(.noteOn(note: 60, velocity: 0.8))
        let lit = reefStep(&model, seconds: 0.1, state: ThemeState(values: ["waterline": .number(0), "fish": .number(1)]))
        XCTAssertEqual(lit.patches.count, 1)
        XCTAssertEqual(lit.corals[3].glow, min(1, 0.88 * MoodLook.reactionScale(.reefAlive)), accuracy: 1e-5)
        XCTAssertEqual(lit.corals.filter { $0.glow > 0 }.count, 1)
        XCTAssertTrue(lit.keys.contains { $0.key.note == 60 && $0.pressed })
        XCTAssertEqual(lit.waterlineY, 0.6, accuracy: 1e-6, "more reef")
        XCTAssertEqual(lit.school.positions.count, 80)
        XCTAssertEqual(reefStep(&model, seconds: 0.1, state: ThemeState(values: ["waterline": .number(1)])).waterlineY, 0.3,
                       accuracy: 1e-6, "more sky")
        // A chord sends its colour wave.
        for n: UInt8 in [72, 76, 79] { model.handle(.noteOn(note: n, velocity: 0.8)) }
        let chord = reefStep(&model, seconds: 0.2)
        XCTAssertEqual(chord.colourWave?.quality, .major)
        // Galaxy Warp streaks instead; the reef rests and the school swims on.
        model.handle(.noteOn(note: 84, velocity: 0.8))
        let warped = reefStep(&model, seconds: 0.5, state: ThemeState(values: ["visual": .choice("Galaxy Warp")]))
        XCTAssertNotNil(warped.warp)
        XCTAssertTrue(warped.patches.isEmpty)
        XCTAssertTrue(warped.corals.allSatisfy { $0.glow == 0 })
        XCTAssertNil(warped.colourWave)
        XCTAssertEqual(warped.school.positions.count, 56)
        // At night the polyps open to feed (and the renderer has them glow softly).
        var night = GreatBarrierReefModel()
        night.setSky(reefSky(sun: -20, hour: 21))
        XCTAssertEqual(reefStep(&night, seconds: 0.1).polypsOpen, 1)
        var dusk = GreatBarrierReefModel()
        dusk.setSky(reefSky(sun: -6, hour: 19))
        XCTAssertEqual(reefStep(&dusk, seconds: 0.1).polypsOpen, 0.5, accuracy: 1e-6)
    }

    /// Spec §9.1 and §7.5: it's warm here. Snow falls as rain, blizzards are squalls; never sea smoke (a light morning
    /// haze instead), frost, rime, diamond dust or pillars; and no fireflies, because a cay has none.
    func testReefIsWarm() throws {
        func reef(_ edit: (inout SkyState) -> Void) -> ReefFrame {
            var s = reefSky(sun: 10, hour: 7)
            edit(&s)
            var model = GreatBarrierReefModel()
            model.setSky(s)
            return reefStep(&model, seconds: 0.1)
        }
        let snow = reef { $0.weather = .snow; $0.nextWeather = .snow; $0.snow = 0.7; $0.frost = 0.6 }.sky
        XCTAssertEqual(snow.weather, .rain)
        XCTAssertEqual(snow.rain, 0.7, accuracy: 1e-6, "snow falls as rain")
        XCTAssertEqual([snow.snow, snow.frost], [0, 0])
        let blizzard = reef { $0.weather = .blizzard; $0.nextWeather = .blizzard; $0.snow = 1; $0.wind = 1; $0.gust = 1 }.sky
        XCTAssertEqual(blizzard.weather, .squall)
        XCTAssertEqual(blizzard.rain, 1)
        XCTAssertEqual(blizzard.snow, 0)
        let smoke = reef { $0.weather = .seaSmoke; $0.nextWeather = .seaSmoke; $0.steam = 1; $0.mist = 0.35; $0.frost = 0.9 }
        XCTAssertEqual(smoke.sky.steam, 0, "never sea smoke")
        XCTAssertEqual(smoke.sky.mist, 0.25, accuracy: 1e-6, "a light morning haze")
        XCTAssertEqual(smoke.sky.frost, 0)
        XCTAssertEqual(smoke.sky.weather, .clear)
        XCTAssertEqual(smoke.ambience.indoors, 0, "and none of sea smoke's hush")
        XCTAssertEqual(smoke.swellScale, 1, accuracy: 1e-6, "nor its stillness")
        let rime = reef { $0.weather = .rime; $0.nextWeather = .rime; $0.rime = 0.8; $0.frost = 1; $0.mist = 0.85 }.sky
        XCTAssertEqual([rime.rime, rime.frost], [0, 0])
        XCTAssertEqual(rime.weather, .mist, "fog that never freezes")
        let dust = reef { $0.weather = .diamondDust; $0.nextWeather = .diamondDust; $0.diamondDust = 1; $0.pillar = 1 }.sky
        XCTAssertEqual([dust.diamondDust, dust.pillar], [0, 0])
        // The warm rule leaves fireflies alone; the reef has none (so no humid night's crickets either).
        var humidSky = reefSky(sun: -20, hour: 22)
        humidSky.weather = .humid; humidSky.nextWeather = .humid; humidSky.fireflies = 0.9
        XCTAssertEqual(WorldWeather.warm(humidSky).fireflies, 0.9)
        let humid = reef { $0 = humidSky }
        XCTAssertEqual(humid.sky.fireflies, 0)
        XCTAssertEqual(humid.sky.weather, .humid)
        XCTAssertEqual(humid.ambience.level(.crickets), 0)
        // Rain stays rain, and pocks the lagoon.
        let rain = reef { $0.weather = .rain; $0.nextWeather = .rain; $0.rain = 0.6 }
        XCTAssertEqual(rain.sky.rain, 0.6, accuracy: 1e-6)
        XCTAssertEqual(rain.ambience.level(.rainOnWater), 0.45, accuracy: 1e-6)

        // Through the director: a sea-smoke morning over Cairns is a light haze on the reef.
        var state = ThemeState()
        state.values["light.hold"] = .choice(SkyHold.follow.rawValue)
        let d = SceneDirector(themeID: GreatBarrierReefModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 7; s.cityID = "cairns"; s.weatherMode = .pick; s.weather = .seaSmoke
        d.sky.reset(settings: s)
        var frame: ReefFrame?
        for i in 0..<30 { frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? ReefFrame }
        let f = try XCTUnwrap(frame)
        XCTAssertEqual(d.lastSky?.steam ?? 0, 1, accuracy: 1e-6, "the sky's own sea smoke")
        XCTAssertEqual(f.sky.steam, 0)
        XCTAssertEqual(f.sky.mist, 0.25, accuracy: 1e-6)
        XCTAssertEqual(f.sky.frost, 0)
    }

    /// Spec §9.1: the camera faces east over the reef crest; on a shower night it turns (τ 8 s) to face 60° of azimuth
    /// away from the radiant, where the meteors run long, and back east when the night is over.
    func testReefCameraTurnsAwayFromTheRadiant() throws {
        func showerSky(radiant azimuth: Double, altitude: Double = 40, zhr: Double = 120, sun: Double = -30) -> SkyState {
            var s = reefSky(sun: sun, hour: 1)
            s.shower = ShowerNow(code: "GEM", name: "Geminids", zhr: zhr, radiantAltitude: altitude, radiantAzimuth: azimuth,
                                 daysToPeak: 0, radiantRises: nil, radiantHighest: 50)
            return s
        }
        for radiant in [20.0, 150.0, 200.0, 300.0, 359.0] {
            var model = GreatBarrierReefModel()
            model.setSky(reefSky(sun: -30, hour: 1))
            XCTAssertEqual(reefStep(&model, seconds: 1).cameraAzimuth, 90, accuracy: 1e-9, "east, with no shower")
            model.setSky(showerSky(radiant: radiant))
            var previous = 90.0
            for _ in 0..<(60 * 30) {   // a minute
                let az = reefStep(&model, seconds: 1.0 / 30).cameraAzimuth
                XCTAssertTrue(az >= 0 && az < 360)
                XCTAssertLessThan(abs(GreatBarrierReefModel.turn(from: previous, to: az)), 1, "it turns, it never jumps")
                previous = az
            }
            XCTAssertEqual(abs(GreatBarrierReefModel.turn(from: radiant, to: previous)), 60, accuracy: 5,
                           "the radiant at \(radiant)°: 60° of azimuth from it")
            XCTAssertEqual(abs(GreatBarrierReefModel.turn(from: GreatBarrierReefModel.cameraTarget(showerSky(radiant: radiant)), to: previous)),
                           0, accuracy: 0.5)
            // The night ends: back to the east.
            model.setSky(reefSky(sun: 10, hour: 7))
            XCTAssertEqual(reefStep(&model, seconds: 60).cameraAzimuth, 90, accuracy: 0.5)
        }
        // The side nearer the east: a radiant in the west turns the camera north of east, one in the north-east south of it.
        XCTAssertEqual(GreatBarrierReefModel.cameraTarget(showerSky(radiant: 300)), 0, accuracy: 1e-9)
        XCTAssertEqual(GreatBarrierReefModel.cameraTarget(showerSky(radiant: 20)), 80, accuracy: 1e-9)
        XCTAssertEqual(GreatBarrierReefModel.cameraTarget(showerSky(radiant: 200)), 140, accuracy: 1e-9)
        // τ 8 s: after 8 s a turn is 63% done.
        var model = GreatBarrierReefModel()
        model.setSky(reefSky(sun: -30, hour: 1))
        _ = reefStep(&model, seconds: 1)
        model.setSky(showerSky(radiant: 300))
        XCTAssertEqual(reefStep(&model, seconds: 8).cameraAzimuth, 90 - 90 * (1 - exp(-1)), accuracy: 1)
        // No turn by day, with the radiant below the horizon, or for a shower too weak to matter (ZHR under 10).
        for sky in [showerSky(radiant: 300, sun: 20), showerSky(radiant: 300, altitude: -10), showerSky(radiant: 300, zhr: 5)] {
            XCTAssertEqual(GreatBarrierReefModel.cameraTarget(sky), 90, accuracy: 1e-9)
        }

        // Through the director: "Always a shower" over Cairns has its radiant 80° up in the south, so the camera faces
        // 120° (east-south-east); "Never" leaves it east.
        func director(_ mode: MeteorMode) throws -> ReefFrame {
            var state = ThemeState()
            state.values["meteors.mode"] = .choice(mode.rawValue)
            let d = SceneDirector(themeID: GreatBarrierReefModel.id, state: state, reaction: ReactionPresets.expressivePianist)
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "cairns"; s.weatherMode = .pick; s.weather = .clear
            d.sky.reset(settings: s)
            var frame: ReefFrame?
            for i in 0..<30 { frame = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? ReefFrame }
            return try XCTUnwrap(frame)
        }
        let always = try director(.always)
        let shower = try XCTUnwrap(always.sky.shower)
        XCTAssertEqual(shower.code, "ALW")
        XCTAssertEqual(shower.radiantAzimuth, 180, accuracy: 1e-6)
        XCTAssertEqual(always.cameraAzimuth, 120, accuracy: 1e-6)
        XCTAssertEqual(abs(GreatBarrierReefModel.turn(from: shower.radiantAzimuth, to: always.cameraAzimuth)), 60, accuracy: 5)
        let never = try director(.never)
        XCTAssertNil(never.sky.shower)
        XCTAssertEqual(never.cameraAzimuth, 90, accuracy: 1e-9)
    }

    /// Spec §5 and §9.1: the reef's soundscape. Above the water the far surf on the reef crest, the lapping at the
    /// waterline, the breeze, terns and gulls by day; below it the snapping shrimp by the hour (day 1.0, dusk and dawn
    /// 1.6, night 1.25, through their level), the fish chorus (silent at noon, the dusk drumming building through the late
    /// afternoon and stopping after dusk, a dawn chorus, a few calls at night), the humpbacks from June to October and
    /// the bubbles; rain both above and below; then the weather's. The swell carrying the lens under crossfades the two
    /// by at most 30%.
    func testReefAmbience() throws {
        func scene(_ sky: SkyState, mood: Mood = .neutral) -> AmbienceScene {
            var model = GreatBarrierReefModel()
            model.mood = mood
            model.setSky(sky)
            return reefStep(&model, seconds: 0.1).ambience
        }
        let day = scene(reefSky(sun: 40, hour: 13), mood: .reefAlive)
        XCTAssertEqual(day.level(.surf), 0.3, accuracy: 1e-9)
        XCTAssertEqual(day.level(.lapping), 0.45, accuracy: 1e-9)
        XCTAssertEqual(day.level(.breeze), 0.25, accuracy: 1e-9)
        XCTAssertEqual(day.level(.gulls), 0.15, accuracy: 1e-9)
        XCTAssertEqual(day.level(.snappingShrimp), GreatBarrierReefModel.shrimpLevel, accuracy: 1e-9)
        XCTAssertEqual(day.level(.bubbles), 0.35, accuracy: 1e-9)
        XCTAssertEqual(day.level(.fishChorus), 0)
        XCTAssertEqual(day.level(.whaleSong), 0, "November: the humpbacks have gone south")
        XCTAssertEqual(day.level(.rainOnWater), 0)
        XCTAssertEqual(day.level(.crickets), 0)
        XCTAssertEqual(day.surfDistance, 0.9, accuracy: 1e-9, "the reef crest is far off")
        XCTAssertEqual(day.closeness, MoodLook.ambienceCloseness(base: 0.55, .reefAlive), accuracy: 1e-9)
        XCTAssertEqual(day.density, MoodLook.ambienceDensity(.reefAlive), accuracy: 1e-9)
        XCTAssertEqual(day.indoors, 0)
        XCTAssertNil(day.bubbleBurst)
        XCTAssertNil(day.thunder)
        XCTAssertEqual(scene(reefSky(sun: 80, hour: 12.2)).level(.fishChorus), 0, "silent at noon")

        // The shrimp follow the hour's factors through their level.
        XCTAssertEqual(GreatBarrierReefModel.shrimpFactor(reefSky(sun: 40, hour: 13)), 1, accuracy: 1e-12)
        XCTAssertEqual(GreatBarrierReefModel.shrimpFactor(reefSky(sun: -3, hour: 18.7)), 1.6, accuracy: 1e-12)
        XCTAssertEqual(GreatBarrierReefModel.shrimpFactor(reefSky(sun: -30, hour: 23)), 1.25, accuracy: 1e-12)
        XCTAssertEqual(scene(reefSky(sun: -3, hour: 18.7)).level(.snappingShrimp), GreatBarrierReefModel.shrimpLevel * 1.6, accuracy: 1e-9, "dusk")
        XCTAssertEqual(scene(reefSky(sun: -3, hour: 5.6)).level(.snappingShrimp), GreatBarrierReefModel.shrimpLevel * 1.6, accuracy: 1e-9, "dawn")
        XCTAssertEqual(scene(reefSky(sun: -30, hour: 23)).level(.snappingShrimp), GreatBarrierReefModel.shrimpLevel * 1.25, accuracy: 1e-9, "night")
        XCTAssertEqual(scene(reefSky(sun: 8, hour: 17.5)).level(.snappingShrimp), GreatBarrierReefModel.shrimpLevel * 1.3, accuracy: 1e-9, "gliding into dusk")
        for alt in stride(from: -40.0, through: 60, by: 2.5) {
            let f = GreatBarrierReefModel.shrimpFactor(reefSky(sun: alt, hour: 18))
            XCTAssertTrue(f >= 1 - 1e-12 && f <= 1.6 + 1e-12, "\(alt)°: \(f)")
            XCTAssertLessThanOrEqual(GreatBarrierReefModel.shrimpLevel * f, 1, "the level stays within 0…1")
        }

        // The fish chorus: the dusk drumming builds through the late afternoon, sounds at dusk and stops after it; the
        // dawn chorus; a few calls through the night.
        let afternoon = scene(reefSky(sun: 25, hour: 16)).level(.fishChorus)
        let evening = scene(reefSky(sun: 10, hour: 17.3)).level(.fishChorus)
        let dusk = scene(reefSky(sun: -4, hour: 18.8)).level(.fishChorus)
        XCTAssertTrue(afternoon > 0.05 && afternoon < evening && evening < dusk, "\(afternoon) < \(evening) < \(dusk)")
        XCTAssertEqual(dusk, 0.4, accuracy: 1e-9)
        XCTAssertLessThan(scene(reefSky(sun: -11, hour: 19.6)).level(.fishChorus), 0.05, "it stops abruptly after dusk")
        XCTAssertEqual(scene(reefSky(sun: -30, hour: 23)).level(.fishChorus), 0.15, accuracy: 1e-9, "the night's few calls")
        XCTAssertEqual(scene(reefSky(sun: -2, hour: 5.7)).level(.fishChorus), 0.4, accuracy: 1e-9, "the dawn chorus")
        XCTAssertEqual(scene(reefSky(sun: 20, hour: 8)).level(.fishChorus), 0)

        // The humpbacks: only June to October.
        let season: [(day: Int, singing: Bool)] = [(15, false), (151, false), (152, true), (196, true), (304, true), (305, false), (335, false)]
        for (dayOfYear, singing) in season {
            XCTAssertEqual(scene(reefSky(sun: 30, hour: 14, day: dayOfYear)).level(.whaleSong), singing ? 0.3 : 0, accuracy: 1e-9,
                           "day \(dayOfYear)")
        }
        var leap = reefSky(sun: 30, hour: 14, day: 152)
        leap.calendar = try XCTUnwrap(ISO8601DateFormatter().date(from: "2028-05-31T04:00:00Z"))
        XCTAssertEqual(scene(leap).level(.whaleSong), 0, "the 152nd day of a leap year is still May")

        // Rain pocks the lagoon above and hisses softly below: the one rain-on-water source, 0.5 + 0.25 × rain.
        var rain = reefSky(sun: 30, hour: 14)
        rain.rain = 0.4
        XCTAssertEqual(scene(rain).level(.rainOnWater), 0.3, accuracy: 1e-6)
        // Drips after the rain (the weather's own), and a stiff wind of its own.
        var after = reefSky(sun: 30, hour: 14)
        after.wetness = 0.6
        XCTAssertEqual(scene(after).level(.drips), 0.6, accuracy: 1e-6)
        var windy = reefSky(sun: 30, hour: 14)
        windy.wind = 0.8
        let w = scene(windy)
        XCTAssertEqual(w.level(.breeze), 1, accuracy: 1e-6)
        XCTAssertEqual(w.level(.wind), 0.4, accuracy: 1e-6)
        let night = scene(reefSky(sun: -30, hour: 23))
        XCTAssertEqual(night.level(.gulls), 0)
        XCTAssertGreaterThan(night.nightCool, 0)

        // The lens under: the sources above dip by 30%, those below rise by 30% (at most 1); the rain's two halves
        // crossfade with their sides.
        let base = GreatBarrierReefModel.levels(rain, under: 0), dipped = GreatBarrierReefModel.levels(rain, under: 1)
        XCTAssertEqual(GreatBarrierReefModel.below, [.snappingShrimp, .fishChorus, .whaleSong, .bubbles])
        for (source, level) in base where source != .rainOnWater {
            let expected = GreatBarrierReefModel.below.contains(source) ? min(1, level * 1.3) : level * 0.7
            XCTAssertEqual(dipped[source] ?? -1, expected, accuracy: 1e-9, "\(source)")
        }
        XCTAssertEqual(dipped[.rainOnWater] ?? -1, 0.4 * (0.5 * 0.7 + 0.25 * 1.3), accuracy: 1e-6)
        let duskUnder = min(1, GreatBarrierReefModel.shrimpLevel * 1.6 * 1.3)
        XCTAssertEqual(GreatBarrierReefModel.levels(reefSky(sun: -3, hour: 18.7), under: 1)[.snappingShrimp] ?? -1, duskUnder,
                       accuracy: 1e-12, "lifted under the surface, never past 1")

        // In a storm the swell carries the lens under now and then; every frame's mix stays within those bounds and glides.
        var storm = reefSky(sun: 30, hour: 14)
        storm.weather = .storm; storm.nextWeather = .storm; storm.rain = 0.9; storm.wind = 0.7; storm.cloudCover = 1
        var model = GreatBarrierReefModel()
        model.setSky(storm)
        let p = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState())
        var deepest: Float = 0, underFrames = 0, waves = 0, biggestStep: Float = 0, previous: Float = 0
        var bursts: [Double] = []
        for i in 0..<(60 * 30) {
            let f = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            deepest = max(deepest, f.lensUnder)
            if f.lensUnder > 0.5 { underFrames += 1 }
            biggestStep = max(biggestStep, abs(f.lensUnder - previous))
            previous = f.lensUnder
            if f.ambience.bubbleBurst != nil { bursts.append(Double(i) / 30) }
            if f.ambience.wave != nil { waves += 1 }
            XCTAssertLessThanOrEqual(abs(f.swellLift), 0.09 + 1e-5)
            let calm = GreatBarrierReefModel.levels(f.sky, under: 0)
            for (source, level) in calm where level > 0 && source != .rainOnWater {
                let ratio = f.ambience.level(source) / level
                if GreatBarrierReefModel.below.contains(source) {
                    XCTAssertTrue(ratio >= 1 - 1e-9 && ratio <= 1.3 + 1e-9, "\(source): \(ratio)")
                } else {
                    XCTAssertTrue(ratio >= 0.7 - 1e-9 && ratio <= 1 + 1e-9, "\(source): \(ratio)")
                }
            }
            let mixed = GreatBarrierReefModel.levels(f.sky, under: Double(f.lensUnder))
            XCTAssertEqual(f.ambience.level(.surf), mixed[.surf] ?? -1, accuracy: 1e-5)
        }
        XCTAssertGreaterThan(deepest, 0.9, "the lens dips under")
        XCTAssertGreaterThan(underFrames, 0)
        XCTAssertLessThan(underFrames, 60 * 30 / 2, "now and then")
        XCTAssertLessThan(biggestStep, 0.1, "the crossfade glides")
        XCTAssertFalse(bursts.isEmpty, "a burst of bubbles as it goes under")
        for (a, b) in zip(bursts, bursts.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 4 - 1e-9) }
        XCTAssertGreaterThan(waves, 0, "the swell breaks on the reef crest, far off")
        // In calm weather the lens never goes under, and nothing crossfades.
        var calmReef = GreatBarrierReefModel()
        calmReef.setSky(reefSky(sun: 30, hour: 14))
        for _ in 0..<(60 * 30) {
            let f = calmReef.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            XCTAssertEqual(f.lensUnder, 0)
            XCTAssertNil(f.ambience.bubbleBurst)
            XCTAssertEqual(f.ambience.levels, GreatBarrierReefModel.levels(f.sky, under: 0))
        }
    }
}
