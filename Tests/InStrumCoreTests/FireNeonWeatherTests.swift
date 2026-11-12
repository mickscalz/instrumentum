import XCTest
import simd
@testable import InStrumCore

/// Fire & Neon Task 9 (spec §7, §13, §14; Review focus 4 and 5): Ashfall with its embers and its reddened sun and moon,
/// and the Supercell's staged event: its stages, holding its Clearing when picked, moving on in Random, never in Calm
/// random, its lightning; Random Beautiful's tables; old weathers and old saves; the cold rule; the sound.
final class FireNeonWeatherTests: XCTestCase {
    private let zone = TimeZone(identifier: "Australia/Melbourne")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func sky(_ kind: WeatherKind, hour: Double = 13, seed: UInt64 = 1,
                     _ edit: (inout SkySettings) -> Void = { _ in }) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0.5; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = kind
        s.spritesMode = .off; s.satellitesMode = .off; s.crawlersMode = .off; s.sheetMode = .off
        edit(&s)
        let sky = LivingSky(settings: s, seed: seed, homeZone: zone)
        sky.reset(settings: s)
        return sky
    }

    @discardableResult
    private func run(_ sky: LivingSky, seconds: Double, dt: Double, storm: StormInputs = StormInputs(),
                     each: (SkyState, Double) -> Void = { _, _ in }) -> SkyState {
        var st = SkyState()
        let n = max(1, Int((seconds / dt).rounded()))
        for i in 1...n {
            let t = Double(i) * dt
            st = sky.step(now: start.addingTimeInterval(t), dt: dt, meteors: .never, storm: storm)
            each(st, t)
        }
        return st
    }

    // MARK: - Ashfall (spec §7.1)

    /// Its values (cloud 0.55, no rain or snow, mist 0.35, wind 0.25, ash 1), appended after the Storms' two; quiet (not
    /// rough, not wet, no lightning); the ash only in its own kind; the sky carries it.
    func testAshfallValues() {
        XCTAssertEqual(Array(WeatherKind.allCases.suffix(2)), [.ashfall, .supercell], "appended at the end")
        XCTAssertEqual([WeatherKind.ashfall.rawValue, WeatherKind.supercell.rawValue], ["ashfall", "supercell"])
        let a = WeatherKind.ashfall.values
        XCTAssertEqual([a.cloud, a.rain, a.snow, a.mist, a.wind, a.ash], [0.55, 0, 0, 0.35, 0.25, 1])
        XCTAssertEqual([a.halo, a.frost, a.gust, a.fireflies, a.pillar, a.rime, a.steam, a.outflow, a.virga, a.rotation],
                       [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(WeatherKind.ashfall.isRough)
        XCTAssertFalse(WeatherKind.ashfall.isWet)
        XCTAssertFalse(WeatherKind.ashfall.flashes)
        XCTAssertEqual(WeatherKind.ashfall.beautyWeight, 0)
        for k in WeatherKind.allCases where k != .ashfall { XCTAssertEqual(k.values.ash, 0, "\(k)") }
        for k in WeatherKind.allCases where k != .supercell { XCTAssertEqual(k.values.rotation, 0, "\(k)") }
        XCTAssertEqual(WeatherValues.mix(WeatherKind.clear.values, a, 0.25).ash, 0.25, accuracy: 1e-6)
        let st = run(sky(.ashfall), seconds: 1, dt: 1)
        XCTAssertEqual(st.ash, 1, accuracy: 1e-6)
        XCTAssertEqual(st.rain, 0)
        XCTAssertEqual(st.snow, 0, "the ash falls through the snow's path, but it isn't snow")
        XCTAssertEqual(run(sky(.clear), seconds: 1, dt: 1).ash, 0)
    }

    /// Embers rise only where the world is their source (a world flag: Volcano Rim's when it comes); everywhere else the
    /// ash falls alone. Through the director too.
    func testEmbersOnlyWhereTheWorldIsTheirSource() {
        XCTAssertEqual(run(sky(.ashfall), seconds: 1, dt: 1).embers, 0)
        XCTAssertEqual(run(sky(.ashfall), seconds: 1, dt: 1, storm: StormInputs(emberSource: true)).embers, 1, accuracy: 1e-6)
        XCTAssertEqual(run(sky(.clear), seconds: 1, dt: 1, storm: StormInputs(emberSource: true)).embers, 0, "no ash, no embers")
        func embers(_ entry: ThemeEntry) -> Float {
            let d = SceneDirector(entry: entry, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.cityID = "melbourne"; s.weatherMode = .pick
            s.weather = .ashfall
            d.sky.reset(settings: s)
            d.clock = { [start] in start }
            _ = d.step(dt: 1, t: 1, quality: .high)
            return d.lastSky?.embers ?? -1
        }
        XCTAssertEqual(embers(ThemeEntry.make(EmberProbe.self)), 1, accuracy: 1e-6)
        XCTAssertEqual(embers(ThemeEntry.make(SatellitesTests.DarkProbe.self)), 0)
        XCTAssertTrue(EmberProbe.emberSource)
        XCTAssertFalse(MoonlitLakeModel.self is SkyWorldFlags.Type)
    }

    /// The sun and the moon redden and dim through the ash, the more the lower they stand; the sky gets a brown-grey haze
    /// low down and fewer stars; nothing changes without ash.
    func testTheSunAndMoonRedden() {
        XCTAssertEqual(WorldWeather.ashTint(ash: 0, altitude: 10), SIMD3(1, 1, 1))
        for alt in [60.0, 25, 8, 2] {
            let t = WorldWeather.ashTint(ash: 1, altitude: alt)
            XCTAssertLessThan(t.x, 1, "dimmed at \(alt)°")
            XCTAssertGreaterThan(t.x, t.y, "redder at \(alt)°")
            XCTAssertGreaterThan(t.y, t.z)
        }
        let high = WorldWeather.ashTint(ash: 1, altitude: 40), low = WorldWeather.ashTint(ash: 1, altitude: 4)
        XCTAssertGreaterThan(low.x / low.z, high.x / high.z, "redder low down")
        XCTAssertLessThan(low.x, high.x, "and dimmer")
        XCTAssertGreaterThan(WorldWeather.ashTint(ash: 0.5, altitude: 10).z, WorldWeather.ashTint(ash: 1, altitude: 10).z)
        // In the sky: the day's sun and the night's moon.
        let day = run(sky(.ashfall, hour: 16), seconds: 1, dt: 1)
        XCTAssertGreaterThan(day.sun.altitude, 0)
        XCTAssertLessThan(day.sunTint.z, day.sunTint.x)
        XCTAssertLessThan(day.sunTint.x, 1)
        let clear = run(sky(.clear, hour: 16), seconds: 1, dt: 1)
        XCTAssertEqual(clear.sunTint, SIMD3(1, 1, 1))
        func warmth(_ c: SIMD3<Float>) -> Float { c.x / max(c.z, 1e-6) }
        XCTAssertGreaterThan(warmth(day.horizon), warmth(clear.horizon), "a brown-grey haze on the horizon")
        let night = run(sky(.ashfall, hour: 22) { $0.frozenPhase = 0.5 }, seconds: 1, dt: 1)
        if night.moon.altitude > 0 { XCTAssertLessThan(night.moonTint.z, night.moonTint.x) }
        XCTAssertLessThan(night.moonTint.z, 1)
        let clearNight = run(sky(.clear, hour: 22), seconds: 1, dt: 1)
        XCTAssertLessThan(night.starVisibility, clearNight.starVisibility)
    }

    // MARK: - The Supercell (spec §7.2)

    /// Its nominal values (cloud 0.85, rain 0.6, mist 0.15, wind 0.6, gust 0.8, rotation 1); rough (Calm random never
    /// picks it) and wet (after the rain may follow); in no table but its own worlds'. The schedule: Approach to a third,
    /// Core to two thirds, Clearing after; the storm coming from 30 km, overhead in the Core, going; the green at most 12%
    /// and only about the Core; a hail burst in the Core; mammatus as it clears; lightning only in the Core; and the stages
    /// running on into each other with no jump.
    func testSupercellSchedule() {
        let v = WeatherKind.supercell.values
        XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.gust, v.rotation, v.ash], [0.85, 0.6, 0, 0.15, 0.6, 0.8, 1, 0])
        XCTAssertTrue(WeatherKind.supercell.isRough)
        XCTAssertTrue(WeatherKind.supercell.isWet)
        XCTAssertFalse(WeatherKind.supercell.flashes, "its lightning is staged")
        XCTAssertEqual(WeatherKind.supercell.beautyWeight, 0)
        var last = WorldWeather.supercell(phase: 0)
        XCTAssertEqual(last.stage, .approach)
        XCTAssertEqual(last.distanceKm, 30, accuracy: 1e-4)
        var hailMax: Float = 0, greenMax: Float = 0, mamMax: Float = 0
        for i in 1...1000 {
            let p = Double(i) / 1000
            let c = WorldWeather.supercell(phase: p)
            XCTAssertEqual(c.stage, SupercellStage.event(at: min(Float(p), 0.9999)), "\(p)")
            for (a, b, name) in [(c.cloud, last.cloud, "cloud"), (c.rain, last.rain, "rain"), (c.mist, last.mist, "mist"),
                                 (c.wind, last.wind, "wind"), (c.gust, last.gust, "gust"), (c.hail, last.hail, "hail"),
                                 (c.green, last.green, "green"), (c.mammatus, last.mammatus, "mammatus"),
                                 (c.lightning, last.lightning, "lightning")] {
                XCTAssertLessThan(abs(a - b), 0.03, "\(name) jumps at \(p)")
            }
            XCTAssertLessThan(abs(c.distanceKm - last.distanceKm), 0.2, "distance jumps at \(p)")
            XCTAssertLessThan(abs(c.anvilEdgeKm - last.anvilEdgeKm), 0.4, "the anvil's edge jumps at \(p)")
            XCTAssertLessThanOrEqual(c.distanceKm, last.distanceKm + 1e-5, "it comes on and goes, never back")
            XCTAssertTrue((0...SupercellNow.greenest + 1e-6).contains(c.green))
            for x in [c.cloud, c.rain, c.mist, c.wind, c.gust, c.hail, c.mammatus, c.lightning] { XCTAssertTrue((0...1).contains(x)) }
            if c.stage != .core { XCTAssertEqual(c.hail, 0); XCTAssertEqual(c.lightning, 0) }
            if c.stage != .clearing { XCTAssertEqual(c.mammatus, 0) }
            if c.stage == .approach { XCTAssertLessThan(c.rain, 0.06, "a rain-free base") }
            hailMax = max(hailMax, c.hail); greenMax = max(greenMax, c.green); mamMax = max(mamMax, c.mammatus)
            last = c
        }
        XCTAssertGreaterThan(hailMax, 0.9, "a hail burst")
        XCTAssertEqual(greenMax, SupercellNow.greenest, accuracy: 0.005)
        XCTAssertGreaterThan(mamMax, 0.9)
        XCTAssertEqual(WorldWeather.supercell(phase: 0.5).distanceKm, 0, accuracy: 0.01, "overhead mid-Core")
        XCTAssertGreaterThan(WorldWeather.supercell(phase: 0.5).rain, 0.9)
        let held = WorldWeather.supercell(phase: WorldWeather.supercellHeld)
        XCTAssertEqual(held.stage, .clearing)
        XCTAssertEqual(held.rain, 0, accuracy: 1e-6, "the rain gone where it holds")
        XCTAssertLessThan(held.cloud, 0.35, "the stars coming out")
        XCTAssertGreaterThan(held.mammatus, 0.9)
    }

    /// Picked, it runs Approach → Core → Clearing over its 8 minutes from the moment it arrives, holds its Clearing (5/6)
    /// from then on, and its staged weather stands in the sky (rain and hail in the Core); it is a supercell and a far
    /// storm for the rest of the sky; the Advanced length stretches it; picking another weather and back starts it over.
    func testPickedItPlaysOnceAndHoldsItsClearing() {
        let s = sky(.supercell)
        var stages: [SupercellStage] = []
        var firstCore = 0.0, firstClearing = 0.0
        var hail: Float = 0, rainInCore: Float = 0
        run(s, seconds: 1200, dt: 1) { st, t in
            guard let c = st.supercellWeather else { return XCTFail("no supercell at \(t)") }
            XCTAssertEqual(c.amount, 1, accuracy: 1e-6)
            if stages.last != c.stage { stages.append(c.stage) }
            if c.stage == .core, firstCore == 0 { firstCore = t }
            if c.stage == .clearing, firstClearing == 0 { firstClearing = t }
            if c.stage == .core { rainInCore = max(rainInCore, st.rain); hail = max(hail, st.hail) }
            XCTAssertEqual(st.supercell, 1, accuracy: 1e-6)
            XCTAssertEqual(st.farStorm, 1, accuracy: 1e-6, "a supercell is a far storm")
            XCTAssertEqual(Double(st.supercellPhase), Double(c.phase), accuracy: 1e-4)
        }
        XCTAssertEqual(stages, [.approach, .core, .clearing], "once, in order")
        XCTAssertEqual(firstCore, 160, accuracy: 1.5)
        XCTAssertEqual(firstClearing, 320, accuracy: 1.5)
        XCTAssertGreaterThan(rainInCore, 0.9)
        XCTAssertGreaterThan(hail, 0.9)
        let end = s.step(now: start.addingTimeInterval(1201), dt: 1, meteors: .never)
        XCTAssertEqual(Double(end.supercellWeather?.phase ?? 0), WorldWeather.supercellHeld, accuracy: 1e-5, "held")
        XCTAssertEqual(end.rain, 0, accuracy: 1e-5)
        // Five minutes long (the Advanced setting): the Core at 100 s.
        let short = sky(.supercell) { $0.supercellSeconds = 300 }
        var core = 0.0
        run(short, seconds: 200, dt: 1) { st, t in if core == 0, st.supercellWeather?.stage == .core { core = t } }
        XCTAssertEqual(core, 100, accuracy: 1.5)
        // Another weather and back: it starts over, with a new storm (a new bearing and episode).
        var settings = s.settings
        let firstEpisode = end.supercellWeather?.episode ?? 0
        settings.weather = .clear; settings.pickBlendSeconds = 1
        s.settings = settings
        run(s, seconds: 5, dt: 1)
        XCTAssertNil(run(s, seconds: 1, dt: 1).supercellWeather)
        settings.weather = .supercell
        s.settings = settings
        let again = run(s, seconds: 2, dt: 1)
        XCTAssertEqual(again.supercellWeather?.stage, .approach)
        XCTAssertNotEqual(again.supercellWeather?.episode, firstEpisode)
        // The wall cloud turns, the way the hemisphere turns it (Melbourne: clockwise from above, so its angle falls).
        let t0 = run(sky(.supercell), seconds: 10, dt: 1).supercellWeather?.turn ?? 0
        let spin = sky(.supercell)
        let t1 = run(spin, seconds: 30, dt: 1).supercellWeather?.turn ?? 0
        XCTAssertLessThan(t1, t0, "turning")
    }

    /// Its lightning flashes only through its Core, every 3–10 s (never three a second: each one a lone flash), dimmer
    /// in-cloud flicker only as it comes and goes; under the existing flash rules (the world's limiter, gentle's glow, which
    /// the app's tests hold), the sky's own limiter never counts its flicker.
    func testItsLightningPassesTheFlashTest() {
        let s = sky(.supercell)
        var onsets: [(Double, SupercellStage)] = []
        var was: Float = 0
        var limiter = FlashLimiter()
        var maxRecent = 0
        var glowOutsideCore: Float = 0
        run(s, seconds: 480, dt: 1.0 / 30) { st, t in
            if st.lightning > 0.9, was <= 0.9, let c = st.supercellWeather { onsets.append((t, c.stage)) }
            was = st.lightning
            _ = limiter.limit(exposure: 1 + 1.2 * st.lightning, sparkle: 0, dt: 1.0 / 30)
            maxRecent = max(maxRecent, limiter.recent)
            if let c = st.supercellWeather, c.stage != .core { glowOutsideCore = max(glowOutsideCore, c.glow) }
        }
        XCTAssertGreaterThan(onsets.count, 12, "frequent through the Core")
        XCTAssertTrue(onsets.allSatisfy { $0.1 == .core }, "only in the Core")
        for (a, b) in zip(onsets, onsets.dropFirst()) { XCTAssertGreaterThanOrEqual(b.0 - a.0, 3 - 0.05) }
        XCTAssertLessThanOrEqual(maxRecent, FlashLimiter.maxFlashesPerSecond)
        XCTAssertGreaterThan(glowOutsideCore, 0.2, "the distant flicker as it comes and goes")
        XCTAssertEqual(s.flashLimiter.total, 0, "the sky's own limiter: nothing of its counts")
    }

    /// In Random Beautiful it plays its event and moves on: its spell is its length; Calm random never picks it.
    func testRandomItPlaysAndMovesOnAndCalmNeverPicksIt() {
        var s = SkySettings(); s.weatherMode = .randomBeautiful; s.spellMinutes = 2; s.randomBlendSeconds = 10
        var m = WeatherMachine(settings: s, seed: 3)
        m.extras = [.supercell: 50]
        var arrived: Double?, left: Double?
        var t = 0.0
        while t < 20_000, left == nil {
            m.step(dt: 1, settings: s)
            t += 1
            if arrived == nil, m.transitioning, m.next == .supercell { arrived = t }
            if arrived != nil, m.current == .supercell, m.transitioning, m.next != .supercell { left = t }
        }
        let a = try? XCTUnwrap(arrived), l = try? XCTUnwrap(left)
        XCTAssertEqual((l ?? 0) - (a ?? 0), WeatherMachine.supercellSpell(s), accuracy: 2, "its spell is its event")
        var calm = s; calm.calmRandom = true
        var c = WeatherMachine(settings: calm, seed: 3)
        c.extras = [.supercell: 50]
        for _ in 0..<20_000 {
            c.step(dt: 30, settings: calm)
            XCTAssertNotEqual(c.current, .supercell)
            XCTAssertNotEqual(c.next, .supercell)
        }
        // Through the sky: a random one runs to its end (phase 1, still its Clearing), never back into an Approach.
        let r = sky(.clear) { $0.weatherMode = .randomBeautiful; $0.spellMinutes = 2; $0.randomBlendSeconds = 10 }
        var phases: [Float] = []
        run(r, seconds: 6000, dt: 2, storm: StormInputs(randomExtras: [.supercell: 50])) { st, _ in
            if let c = st.supercellWeather { phases.append(c.phase) }
        }
        XCTAssertFalse(phases.isEmpty)
        XCTAssertEqual(phases.max() ?? 0, 1, accuracy: 1e-6, "to its end")
        XCTAssertLessThan(r.step(now: start, dt: 0).supercellPhase, 1)
    }

    // MARK: - Random Beautiful, old weathers and saves, the cold, the sound

    /// Random Beautiful offers Ashfall only at the volcano and the Supercell only at Coast Road, Golden Hour Beach,
    /// Moonlit Lake and Neon Night Drive; over thousands of spells they come there and nowhere else.
    func testRandomBeautifulTables() {
        let cellWorlds: Set<String> = [CoastRoadModel.id, GoldenHourBeachModel.id, MoonlitLakeModel.id, NeonNightDriveModel.id]
        for (id, _) in ThemeRegistry.all {
            let extras = WorldWeather.randomExtras(for: id)
            XCTAssertNil(extras[.ashfall], id)
            XCTAssertEqual(extras[.supercell] != nil, cellWorlds.contains(id), id)
        }
        XCTAssertEqual(WorldWeather.randomExtras(for: "volcano-rim"), [.ashfall: 0.5])
        XCTAssertNil(WorldWeather.randomExtras(for: SupercellSkyModel.id)[.supercell], "its storm is its own")
        XCTAssertNil(WorldWeather.randomExtras(for: LightningPlainsModel.id)[.supercell])
        func spells(_ id: String) -> [WeatherKind: Int] {
            var s = SkySettings(); s.weatherMode = .randomBeautiful; s.spellMinutes = 2; s.randomBlendSeconds = 10
            var m = WeatherMachine(settings: s, seed: 17)
            m.extras = WorldWeather.randomExtras(for: id)
            var count: [WeatherKind: Int] = [:]
            var last = m.current
            for _ in 0..<20_000 {
                m.step(dt: 30, settings: s)
                if m.current != last { count[m.current, default: 0] += 1; last = m.current }
            }
            return count
        }
        XCTAssertGreaterThan(spells("volcano-rim")[.ashfall] ?? 0, 20)
        XCTAssertNil(spells("volcano-rim")[.supercell])
        XCTAssertGreaterThan(spells(GoldenHourBeachModel.id)[.supercell] ?? 0, 10)
        XCTAssertNil(spells(GoldenHourBeachModel.id)[.ashfall])
        let cabin = spells(SnowboundCabinModel.id)
        XCTAssertNil(cabin[.supercell]); XCTAssertNil(cabin[.ashfall])
    }

    /// Old weathers are unchanged (their values, and a world without a table picks exactly as before: the new kinds weigh
    /// nothing); old saves load, the new kinds decode by name, and a kind from a later build still falls back.
    func testOldWeathersUnchangedAndOldSavesLoad() throws {
        for k in WeatherKind.allCases where k != .ashfall && k != .supercell {
            XCTAssertEqual(k.values.ash, 0); XCTAssertEqual(k.values.rotation, 0)
        }
        func decode(_ json: String) throws -> SkySettings { try JSONDecoder().decode(SkySettings.self, from: Data(json.utf8)) }
        let old = try decode(#"{"weather":"virga","weatherMode":"pick","randomExcluded":["gustFront","seaSmoke"],"crawlers.mode":"Often"}"#)
        XCTAssertEqual(old.weather, .virga)
        XCTAssertEqual(old.randomExcluded, [.gustFront, .seaSmoke])
        XCTAssertEqual(old.supercellSeconds, 480)
        XCTAssertEqual(try decode(#"{"weather":"ashfall"}"#).weather, .ashfall)
        XCTAssertEqual(try decode(#"{"weather":"supercell","weatherMode":"pick"}"#).weather, .supercell)
        XCTAssertEqual(try decode(#"{"randomExcluded":["supercell","ashfall","hail"]}"#).randomExcluded, [.supercell, .ashfall, .hail])
        XCTAssertEqual(try decode(#"{"weather":"tornado"}"#).weather, .clear)
        // A sky with neither: no ash, no supercell, its tints plain.
        let st = run(sky(.storm), seconds: 2, dt: 1)
        XCTAssertNil(st.supercellWeather)
        XCTAssertEqual([st.ash, st.embers, st.hail], [0, 0, 0])
        XCTAssertEqual(st.sunTint, SIMD3(1, 1, 1))
    }

    /// The cold worlds: a supercell is a blizzard there (no drawn storm, no hail); ash still falls.
    func testTheColdRule() {
        var s = run(sky(.supercell), seconds: 200, dt: 1)
        XCTAssertNotNil(s.supercellWeather)
        s = WorldWeather.cold(s)
        XCTAssertNil(s.supercellWeather)
        XCTAssertEqual(s.hail, 0)
        XCTAssertEqual(s.weather, .blizzard)
        let ash = WorldWeather.cold(run(sky(.ashfall), seconds: 1, dt: 1))
        XCTAssertEqual(ash.weather, .ashfall)
        XCTAssertEqual(ash.ash, 1, accuracy: 1e-6)
    }

    /// The sound: ash's faint dry hiss and its muffled highs; the supercell's roar through its stages and its hail.
    func testTheSound() {
        var ash = SkyState(); ash.ash = 1
        XCTAssertEqual(WeatherAmbience.ashHiss(ash) ?? 0, 0.22, accuracy: 1e-9)
        XCTAssertNil(WeatherAmbience.ashHiss(SkyState()))
        XCTAssertEqual(WeatherAmbience.indoorsLift(ash), 0.1, accuracy: 1e-9)
        XCTAssertEqual(WeatherAmbience.indoorsLift(SkyState()), 0)
        var levels: [AmbienceSource: Double] = [:]
        WeatherAmbience.levels(ash, base: &levels)
        XCTAssertEqual(levels[.rainOnDust] ?? 0, 0.22, accuracy: 1e-9)
        var cell = SkyState()
        cell.supercellWeather = WorldWeather.supercell(phase: 0.1)
        let approach = WeatherAmbience.supercellRoar(cell) ?? 0
        cell.supercellWeather = WorldWeather.supercell(phase: 0.45)
        let core = WeatherAmbience.supercellRoar(cell) ?? 0
        cell.supercellWeather = WorldWeather.supercell(phase: 0.95)
        let clearing = WeatherAmbience.supercellRoar(cell) ?? 0
        XCTAssertGreaterThan(core, approach)
        XCTAssertGreaterThan(approach, clearing)
        XCTAssertNil(WeatherAmbience.supercellRoar(SkyState()))
        var hail = SkyState(); hail.hail = 1
        levels = [:]
        WeatherAmbience.levels(hail, base: &levels)
        XCTAssertEqual(levels[.hailOnTin] ?? 0, 0.8, accuracy: 1e-9)
    }

    struct EmberProbe: ThemeModel, SkyAware, SkyWorldFlags {
        static let id = "ember-probe", displayName = "Ember probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        static let emberSource = true
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }
}
