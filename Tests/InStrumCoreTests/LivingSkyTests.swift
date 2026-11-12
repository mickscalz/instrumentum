import XCTest
@testable import InStrumCore

final class LivingSkyTests: XCTestCase {
    let melbourneZone = TimeZone(identifier: "Australia/Melbourne")!
    let start = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26

    private func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func testQuickCycleLengthAndMoon() {
        var s = SkySettings(); s.timeMode = .quick; s.dayMinutes = 12; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start
        var state = sky.step(now: now, dt: 0)
        let phase0 = state.moonPhase
        var crossings = 0, prevAlt = state.sun.altitude
        for _ in 0..<720 {   // 12 simulated minutes in 1 s steps
            now = now.addingTimeInterval(1)
            state = sky.step(now: now, dt: 1)
            if (prevAlt < 0) != (state.sun.altitude < 0) { crossings += 1 }
            prevAlt = state.sun.altitude
        }
        XCTAssertEqual(crossings, 2, "one sunrise and one sunset per quick day")
        var advance = state.moonPhase - phase0
        if advance < 0 { advance += 1 }
        XCTAssertEqual(advance, 0.125, accuracy: 0.01)
    }

    func testNightIsDarkDayIsBright() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        s.frozenHour = 2
        let night = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.frozenHour = 13
        let day = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertLessThan(luminance(night.zenith), 0.05, "night \(night.zenith)")
        XCTAssertGreaterThan(luminance(day.zenith), 0.4, "day \(day.zenith)")
        XCTAssertGreaterThan(night.starVisibility, 0.5)
        XCTAssertLessThan(day.starVisibility, 0.05)
        // Golden hour: find the frozen hour where the sun sits near 3°.
        var golden: SkyState?
        for minutes in stride(from: 5 * 60, to: 9 * 60, by: 2) {
            s.frozenHour = Double(minutes) / 60
            let st = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
            if abs(st.sun.altitude - 3) < 0.6 { golden = st; break }
        }
        let g = try XCTUnwrap(golden)
        XCTAssertGreaterThan(g.horizon.x, g.horizon.z * 1.4, "warm horizon \(g.horizon)")
    }

    /// Golden hour holds the sun 5° up whatever the clock says: the light (and the warm horizon) stay put.
    func testGoldenHourHoldsWhateverTheClock() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        for hour in [2.0, 13.0] {
            s.frozenHour = hour
            let st = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0, hold: .goldenHour)
            XCTAssertEqual(st.sun.altitude, 5, accuracy: 1e-9, "at \(hour):00")
            XCTAssertGreaterThan(st.horizon.x, st.horizon.z * 1.4, "warm horizon at \(hour):00")
        }
    }

    func testBlueHourHolds() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        s.frozenHour = 13
        let blue = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0, hold: .blueHour)
        let day = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.frozenHour = 2
        let night = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(blue.sun.altitude, -6, accuracy: 1e-9)
        XCTAssertGreaterThan(luminance(blue.zenith), luminance(night.zenith))
        XCTAssertLessThan(luminance(blue.zenith), luminance(day.zenith))
    }

    func testFollowIsThePlainSky() {
        var s = SkySettings(); s.timeMode = .quick; s.cityID = "melbourne"
        let a = LivingSky(settings: s, seed: 4, homeZone: melbourneZone), b = LivingSky(settings: s, seed: 4, homeZone: melbourneZone)
        var now = start
        for _ in 0..<30 {
            now = now.addingTimeInterval(2)
            XCTAssertEqual(a.step(now: now, dt: 2, hold: .follow), b.step(now: now, dt: 2))
        }
    }

    func testCloudsGreyTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.frozenHour = 13; s.weatherMode = .pick
        s.weather = .clear
        let clear = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.weather = .overcast
        let grey = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        let sat = { (c: SIMD3<Float>) in (max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))) / max(c.x, max(c.y, c.z)) }
        XCTAssertLessThan(sat(grey.zenith), sat(clear.zenith))
        XCTAssertEqual(grey.cloudCover, 0.85, accuracy: 1e-4)
        XCTAssertLessThan(grey.starVisibility, clear.starVisibility + 1e-6)
    }

    func testWeatherTransitionsAreSmooth() {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .pick; s.weather = .clear
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start
        var prev = sky.step(now: now, dt: 0).rain
        XCTAssertEqual(prev, 0)
        s.weather = .rain
        sky.settings = s
        var maxStep: Float = 0, monotonic = true
        for _ in 0..<70 {
            now = now.addingTimeInterval(1)
            let r = sky.step(now: now, dt: 1).rain
            maxStep = max(maxStep, r - prev)
            if r < prev - 1e-6 { monotonic = false }
            prev = r
        }
        XCTAssertTrue(monotonic)
        XCTAssertLessThanOrEqual(maxStep, 0.1, "a picked weather takes hold over 12 s, smoothly")
        XCTAssertGreaterThan(prev, 0.74, "and is fully in by the end of the minute")
        XCTAssertEqual(prev, 0.75, accuracy: 1e-3)
        XCTAssertEqual(sky.step(now: now, dt: 0).weather, .rain)
    }

    /// Kind changes as (time, kind): each new kind starts its 60 s transition at `time`.
    private func weatherRun(seed: UInt64, hours: Double) -> [(Double, WeatherKind)] {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .randomBeautiful
        let sky = LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
        var now = start, t = 0.0, last: WeatherKind?
        var out: [(Double, WeatherKind)] = []
        while t < hours * 3600 {
            let st = sky.step(now: now, dt: 1)
            let target = st.nextWeather
            if target != last { out.append((t, target)); last = target }
            t += 1; now = now.addingTimeInterval(1)
        }
        return out
    }

    func testRandomBeautifulIsDeterministicAndVaried() {
        let a = weatherRun(seed: 7, hours: 6), b = weatherRun(seed: 7, hours: 6)
        XCTAssertEqual(a.map(\.1), b.map(\.1))
        XCTAssertEqual(a.map(\.0), b.map(\.0))
        XCTAssertGreaterThanOrEqual(a.count, 18, "6 h of 5–20 min spells")
        for i in 1..<a.count {
            XCTAssertNotEqual(a[i].1, a[i - 1].1, "no kind twice in a row")
            if i >= 2 {
                let minutes = (a[i].0 - a[i - 1].0) / 60
                XCTAssertTrue((5...20.02).contains(minutes), "spell of \(minutes) min")
            }
        }
        XCTAssertGreaterThanOrEqual(Set(a.map(\.1)).count, 4, "varied")
        XCTAssertNotEqual(weatherRun(seed: 8, hours: 2).map(\.1), weatherRun(seed: 7, hours: 2).map(\.1))
    }

    func testResetStartsSettled() {
        var raining = SkySettings(); raining.weatherMode = .pick; raining.weather = .rain
        let sky = LivingSky(settings: raining, seed: 3, homeZone: melbourneZone)
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .clear
        sky.reset(settings: s)
        let state = sky.step(now: start, dt: 1.0 / 30)
        XCTAssertEqual(state.weather, .clear)
        XCTAssertEqual(state.weatherBlend, 0)
        XCTAssertEqual(state.rain, 0)
        XCTAssertEqual(sky.settings, s)
        // Changing the settings (not resetting) still blends.
        s.weather = .rain
        sky.settings = s
        let blending = sky.step(now: start.addingTimeInterval(1), dt: 1)
        XCTAssertLessThan(blending.rain, 0.2)
    }

    func testStormsFlashLightning() {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .pick; s.weather = .storm
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start, flashes = 0, wasLit = false
        for _ in 0..<(120 * 30) {   // 120 s at 30 fps
            now = now.addingTimeInterval(1.0 / 30)
            let lit = sky.step(now: now, dt: 1.0 / 30).lightning > 0.5
            if lit && !wasLit { flashes += 1 }
            wasLit = lit
        }
        XCTAssertTrue((4...22).contains(flashes), "\(flashes) flashes in 2 min")
    }

    /// Review Focus 5: clocks change, the sky doesn't jump.
    func testDaylightSavingIsInvisible() {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = Date(timeIntervalSince1970: 1_791_043_200 - 120)   // DST starts 2026-10-03T16:00Z (2:00 → 3:00 on Sunday 4 Oct); − 2 min
        var prev = sky.step(now: now, dt: 0)
        var worst = 0.0, hourJump = 0.0
        for _ in 0..<240 {
            now = now.addingTimeInterval(1)
            let st = sky.step(now: now, dt: 1)
            worst = max(worst, abs(st.sun.altitude - prev.sun.altitude))
            hourJump = max(hourJump, abs(st.hourOfDay - prev.hourOfDay))
            prev = st
        }
        XCTAssertLessThan(worst, 0.01)
        XCTAssertGreaterThan(hourJump, 0.9, "the local clock itself did change")
    }

    func testRealTimeFollowsTheCity() {
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "melbourne"
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        let noon = sky.step(now: Date(timeIntervalSince1970: 1_793_152_800), dt: 0)   // 2026-10-28T02:00Z ≈ 13:00 AEDT
        XCTAssertEqual(noon.sun.altitude, Solar.direction(at: Date(timeIntervalSince1970: 1_793_152_800), from: sky.location).altitude, accuracy: 1e-9)
        XCTAssertEqual(noon.hourOfDay, 13, accuracy: 0.01)
        XCTAssertEqual(noon.latitude, -37.8136, accuracy: 1e-6)
    }

    func testUnknownCityFallsBack() {
        var s = SkySettings(); s.cityID = "nowhere"
        XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).location, Cities.city(id: "melbourne")!.point)
        XCTAssertEqual(LivingSky(settings: s, homeZone: TimeZone(identifier: "Etc/UTC")!).location, GeoPoint(latitude: 0, longitude: 0))
    }
}

// MARK: - Sets 5 & 6: blizzard, after the rain, frost, wetness, gusts, halos, pastel dawns

extension LivingSkyTests {
    private func sky(_ kind: WeatherKind, hour: Double = 13, city: String = "melbourne", seed: UInt64 = 1) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = city; s.weatherMode = .pick; s.weather = kind
        return LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
    }

    private func pick(_ sky: LivingSky, _ kind: WeatherKind) {
        var s = sky.settings; s.weather = kind; sky.settings = s
    }

    /// Steps `seconds` of sky in `dt` steps from `now` (or the test's start), calling `each` after every step.
    @discardableResult
    private func run(_ sky: LivingSky, seconds: Double, dt: Double = 1, now: Date? = nil, hold: SkyHold = .follow,
                     each: (SkyState) -> Void = { _ in }) -> SkyState {
        let t0 = now ?? start
        var state = sky.step(now: t0, dt: 0, hold: hold)
        let steps = Int((seconds / dt).rounded())
        for i in 1...max(1, steps) {
            state = sky.step(now: t0.addingTimeInterval(Double(i) * dt), dt: dt, hold: hold)
            each(state)
        }
        return state
    }

    func testNewWeatherValues() {
        XCTAssertEqual(WeatherKind.allCases, [.clear, .lightCloud, .overcast, .mist, .drizzle, .rain, .storm, .snow, .blizzard, .afterRain, .sunShower, .fogBank, .sleet, .monsoon, .hail, .smokeHaze, .iceFog, .thunderheads, .dustStorm, .flurries, .freezingDrizzle, .squall, .dryLightning, .humid, .diamondDust, .rime, .seaSmoke, .gustFront, .virga, .ashfall, .supercell])
        // cloud, rain, snow, mist, wind, halo, frost, gust (spec §6.1)
        let table: [WeatherKind: [Float]] = [
            .clear: [0, 0, 0, 0.1, 0.1, 0, 0.15, 0],
            .lightCloud: [0.35, 0, 0, 0.15, 0.2, 0.7, 0.1, 0.1],
            .overcast: [0.85, 0, 0, 0.25, 0.3, 0, 0.1, 0.1],
            .mist: [0.4, 0, 0, 0.9, 0.05, 0.15, 0.2, 0],
            .drizzle: [0.8, 0.3, 0, 0.4, 0.2, 0, 0, 0.1],
            .rain: [0.9, 0.75, 0, 0.3, 0.4, 0, 0, 0.2],
            .storm: [1, 1, 0, 0.2, 0.9, 0, 0, 0.6],
            .snow: [0.85, 0, 0.8, 0.3, 0.25, 0.2, 0.6, 0.2],
            .blizzard: [1, 0, 1, 0.6, 1, 0, 0.9, 1],
            .afterRain: [0.45, 0, 0, 0.55, 0.1, 0, 0, 0],
            .sunShower: [0.5, 0.3, 0, 0.25, 0.2, 0, 0, 0.1],
            .fogBank: [0.6, 0, 0, 1, 0.05, 0, 0.1, 0],
            .sleet: [0.95, 0.5, 0.5, 0.4, 0.35, 0, 0.2, 0.2],
            .monsoon: [1, 1, 0, 0.45, 0.6, 0, 0, 0.4],
            .hail: [1, 0.7, 0.25, 0.2, 0.5, 0, 0, 0.4],
            .smokeHaze: [0.3, 0, 0, 0.8, 0.1, 0, 0, 0],
            .iceFog: [0.2, 0, 0, 0.7, 0.02, 0.8, 0.8, 0],
            .thunderheads: [0.95, 0, 0, 0.15, 0.3, 0, 0, 0.3],
            .dustStorm: [0.5, 0, 0, 0.9, 0.9, 0, 0, 0.7],
            .flurries: [0.55, 0, 0.3, 0.2, 0.15, 0.2, 0.4, 0.1],
            .freezingDrizzle: [0.85, 0.25, 0, 0.5, 0.15, 0, 0.5, 0],
            .squall: [1, 0.9, 0, 0.3, 1, 0, 0, 1],
            .dryLightning: [0.85, 0, 0, 0.1, 0.5, 0, 0, 0.4],
            .humid: [0.15, 0, 0, 0.35, 0.05, 0, 0, 0],
            .diamondDust: [0.05, 0, 0, 0.2, 0.02, 1, 0.9, 0],
            .rime: [0.3, 0, 0, 0.85, 0.08, 0.2, 1, 0],
            .seaSmoke: [0.1, 0, 0, 0.35, 0.06, 0.3, 0.9, 0],
            .gustFront: [0.9, 0.2, 0, 0.5, 1, 0, 0, 1],
            .virga: [0.7, 0, 0, 0.6, 0.4, 0, 0, 0.3],
            .ashfall: [0.55, 0, 0, 0.35, 0.25, 0, 0, 0],
            .supercell: [0.85, 0.6, 0, 0.15, 0.6, 0, 0, 0.8],
        ]
        for k in WeatherKind.allCases {
            let v = k.values
            XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.halo, v.frost, v.gust], table[k], "\(k)")
        }
        XCTAssertEqual(WeatherKind.blizzard.beautyWeight, 0.3)
        XCTAssertEqual(WeatherKind.afterRain.beautyWeight, 1.5)
        // Sets 7 & 8 (spec §6.1): fireflies and pillars, the two new kinds' weights and flags.
        for k in WeatherKind.allCases where k != .humid && k != .diamondDust {
            XCTAssertEqual([k.values.fireflies, k.values.pillar], [0, 0], "\(k)")
        }
        XCTAssertEqual([WeatherKind.humid.values.fireflies, WeatherKind.humid.values.pillar], [1, 0])
        XCTAssertEqual([WeatherKind.diamondDust.values.fireflies, WeatherKind.diamondDust.values.pillar], [0, 1])
        XCTAssertEqual(WeatherKind.humid.beautyWeight, 1.2)
        XCTAssertEqual(WeatherKind.diamondDust.beautyWeight, 0.5)
        for k in [WeatherKind.humid, .diamondDust] {
            XCTAssertFalse(k.isWet, "\(k)"); XCTAssertFalse(k.isRough, "\(k)"); XCTAssertFalse(k.flashes, "\(k)")
        }
        XCTAssertTrue(WeatherKind.humid.frostFormsOnlyAtNight)
        XCTAssertFalse(WeatherKind.diamondDust.frostFormsOnlyAtNight)
        let half = WeatherValues.mix(WeatherKind.humid.values, WeatherKind.diamondDust.values, 0.5)
        XCTAssertEqual(half.fireflies, 0.5, accuracy: 1e-6)
        XCTAssertEqual(half.pillar, 0.5, accuracy: 1e-6)
    }

    func testFrostOnlyAtNightForClearSkies() {
        XCTAssertEqual(sky(.clear, hour: 13).step(now: start, dt: 0).frost, 0, accuracy: 1e-6)
        XCTAssertEqual(sky(.clear, hour: 2).step(now: start, dt: 0).frost, 0.15, accuracy: 0.01)
        XCTAssertEqual(sky(.snow, hour: 13).step(now: start, dt: 0).frost, 0.6, accuracy: 0.01)
    }

    func testRainbowsNeedSunAndShowerLight() {
        func window(_ alt: Double) -> Float {
            func ss(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
            return ss(1, 6, Float(alt)) * (1 - ss(32, 42, Float(alt)))
        }
        var sawFull = false, sawNone = false
        for hour in [7.0, 9, 11, 13, 15, 17, 19] {
            let st = sky(.sunShower, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.rainbow, window(st.sun.altitude), accuracy: 1e-4, "hour \(hour), sun \(st.sun.altitude)°")
            if st.rainbow > 0.99 { sawFull = true }
            if st.rainbow == 0 { sawNone = true }
        }
        XCTAssertTrue(sawFull, "a sun-shower with a mid-height sun shows the full bow at some hour of the day")
        XCTAssertTrue(sawNone, "and none with the sun too high or down")
        XCTAssertEqual(sky(.sunShower, hour: 2).step(now: start, dt: 0).rainbow, 0, "no bow at night")
        for hour in [9.0, 16] {
            let st = sky(.afterRain, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.rainbow, 0.75 * window(st.sun.altitude), accuracy: 1e-4, "after the rain a fainter bow")
            XCTAssertEqual(sky(.rain, hour: hour).step(now: start, dt: 0).rainbow, 0, "heavy rain under thick cloud: no bow")
            XCTAssertEqual(sky(.clear, hour: hour).step(now: start, dt: 0).rainbow, 0)
        }
    }

    func testAdvancedWeatherTimingSettings() throws {
        var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .pick; s.weather = .clear; s.pickBlendSeconds = 2
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        _ = sky.step(now: start, dt: 0)
        s.weather = .rain; sky.settings = s
        var now = start, last = sky.step(now: now, dt: 0)
        for _ in 0..<4 { now = now.addingTimeInterval(1); last = sky.step(now: now, dt: 1) }
        XCTAssertEqual(last.rain, 0.75, accuracy: 1e-4, "a 2 s pick blend has fully arrived after 4 s")
        let d = SkySettings()
        XCTAssertEqual([d.pickBlendSeconds, d.randomBlendSeconds, d.spellMinutes], [12, 60, 12.5])
        let wild = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"pickBlendSeconds":9999,"randomBlendSeconds":0,"spellMinutes":-4}"#.utf8))
        XCTAssertEqual([wild.pickBlendSeconds, wild.randomBlendSeconds, wild.spellMinutes], [120, 10, 2])
        let old = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"rain"}"#.utf8))
        XCTAssertEqual(old.pickBlendSeconds, 12, "old saved settings get the defaults")
    }

    func testRainbowStrengthSetting() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .sunShower
        var best: Float = 0, dim: Float = 0
        for hour in [8.0, 9, 10, 16, 17] {
            s.frozenHour = hour; s.rainbowStrength = 1
            best = max(best, LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).rainbow)
            s.rainbowStrength = 0.5
            dim = max(dim, LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).rainbow)
            s.rainbowStrength = 0
            XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).rainbow, 0)
        }
        XCTAssertGreaterThan(best, 0.5, "some hour shows a bow")
        XCTAssertEqual(dim, best * 0.5, accuracy: 1e-4, "half strength halves the bow")
    }

    func testAdvancedScalesChangeTheSky() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .mist
        let base = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.mistScale = 0.5; s.windScale = 0; s.haloScale = 0; s.frostScale = 0
        let low = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(low.mist, base.mist * 0.5, accuracy: 1e-4)
        XCTAssertEqual(low.wind, 0); XCTAssertEqual(low.halo, 0); XCTAssertEqual(low.frost, 0)
        s.mistScale = 2
        XCTAssertLessThanOrEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).mist, 1)
        var r = SkySettings(); r.timeMode = .frozen; r.frozenHour = 13; r.cityID = "melbourne"; r.weatherMode = .pick; r.weather = .rain
        let rain1 = LivingSky(settings: r, homeZone: melbourneZone).step(now: start, dt: 0).rain
        r.rainScale = 0.5; r.gustScale = 0
        let rainHalf = LivingSky(settings: r, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(rainHalf.rain, rain1 * 0.5, accuracy: 1e-4)
        XCTAssertEqual(rainHalf.gust, 0)
        let d = SkySettings()
        XCTAssertEqual([d.rainScale, d.snowScale, d.gustScale], [1, 1, 1])
        XCTAssertEqual([d.windScale, d.mistScale, d.haloScale, d.frostScale, d.dryingMinutes, d.rainbowStrength], [1, 1, 1, 1, 8, 1])
    }

    /// Scales above 1 boost (they used to be clamped to 1 along with the value, so Dramatic and Dreamy changed nothing).
    func testAdvancedScalesAboveOneBoost() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .lightCloud
        let base = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertGreaterThan(base.wind, 0.05)
        XCTAssertLessThan(base.wind, 0.5)
        s.windScale = 2; s.cloudScale = 1.3; s.mistScale = 1.5
        let boosted = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(boosted.wind, min(1, base.wind * 2), accuracy: 1e-4)
        XCTAssertEqual(boosted.cloudCover, min(1, base.cloudCover * 1.3), accuracy: 1e-4)
        XCTAssertEqual(boosted.mist, min(1, base.mist * 1.5), accuracy: 1e-4)
        s.windScale = 50
        XCTAssertLessThanOrEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).wind, 1)
    }

    func testCalmRandomWeatherNeverGetsRough() {
        for seed in 1...6 as ClosedRange<UInt64> {
            var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .randomBeautiful; s.calmRandom = true
            let sky = LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
            var now = start
            for _ in 0..<4000 {
                now = now.addingTimeInterval(5)
                let st = sky.step(now: now, dt: 5)
                XCTAssertFalse(st.weather.isRough || st.nextWeather.isRough, "seed \(seed): \(st.weather)")
            }
        }
        XCTAssertTrue(WeatherKind.storm.isRough && !WeatherKind.rain.isRough)
    }

    func testCloudStarAndLightningSettings() {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 1; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .lightCloud
        let base = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        s.cloudScale = 0; s.starScale = 0.5
        let dim = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(dim.cloudCover, 0)
        XCTAssertEqual(dim.starVisibility, base.starVisibility * 0.5, accuracy: 1e-4)
        func flashes(_ freq: Double) -> Int {
            var t = SkySettings(); t.timeMode = .frozen; t.cityID = "melbourne"; t.weatherMode = .pick; t.weather = .storm; t.lightningFrequency = freq
            let sky = LivingSky(settings: t, homeZone: melbourneZone)
            var now = start, n = 0, was: Float = 0
            for _ in 0..<(300 * 30) {
                now = now.addingTimeInterval(1.0 / 30)
                let l = sky.step(now: now, dt: 1.0 / 30).lightning
                if l > 0.9 && was <= 0.9 { n += 1 }
                was = l
            }
            return n
        }
        XCTAssertGreaterThan(flashes(3), 2 * flashes(1) - 4, "triple frequency flashes far more often")
        XCTAssertGreaterThan(flashes(1), flashes(0.25), "and a quarter frequency flashes far less")
    }

    func testEarthshineSetting() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"
        XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).earthshine, 0.04, accuracy: 1e-6)
        s.earthshine = 9
        XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).earthshine, 0.3, accuracy: 1e-6)
    }

    func testMoonAndSunSizeSettings() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"
        XCTAssertEqual(LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0).moonSize, 1)
        s.moonSize = 2; s.sunSize = 99
        let big = LivingSky(settings: s, homeZone: melbourneZone).step(now: start, dt: 0)
        XCTAssertEqual(big.moonSize, 2)
        XCTAssertEqual(big.sunSize, 3, "clamped to 3×")
    }

    func testResetAdvancedKeepsTheChoicesButRestoresTheDials() {
        var s = SkySettings(); s.cityID = "tokyo"; s.weather = .hail; s.weatherMode = .pick; s.frozenHour = 5
        s.windScale = 2; s.moonSize = 3; s.calmRandom = true; s.pickBlendSeconds = 99; s.lightningFrequency = 3
        s.resetAdvanced()
        var d = SkySettings(); d.cityID = "tokyo"; d.weather = .hail; d.weatherMode = .pick; d.frozenHour = 5
        XCTAssertEqual(s, d)
    }

    func testAdvancedPresetsDifferAndStayInRange() throws {
        var seen: [SkySettings] = []
        for p in SkySettings.AdvancedPreset.allCases {
            var s = SkySettings(); s.cityID = "tokyo"; s.applyAdvanced(p)
            XCTAssertEqual(s.cityID, "tokyo")
            XCTAssertNotEqual(s, { var d = SkySettings(); d.cityID = "tokyo"; return d }(), "\(p) changes something")
            let round = try JSONDecoder().decode(SkySettings.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(round, s, "\(p) survives saving and loading unclamped")
            seen.append(s)
        }
        XCTAssertEqual(Set(seen.map { "\($0.windScale)-\($0.mistScale)-\($0.moonSize)" }).count, 3)
        XCTAssertTrue(seen[0].calmRandom && !seen[1].calmRandom)
    }

    func testExcludedWeathersNeverAppearInRandom() throws {
        let banned: [WeatherKind] = [.clear, .lightCloud, .mist, .rain]
        for seed in 1...4 as ClosedRange<UInt64> {
            var s = SkySettings(); s.timeMode = .frozen; s.weatherMode = .randomBeautiful; s.randomExcluded = banned
            let sky = LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
            var now = start
            for _ in 0..<3000 {
                now = now.addingTimeInterval(5)
                let st = sky.step(now: now, dt: 5)
                XCTAssertFalse(banned.contains(st.weather) || banned.contains(st.nextWeather), "seed \(seed): \(st.weather)")
            }
        }
        var s = SkySettings(); s.randomExcluded = [.hail, .squall]
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: JSONEncoder().encode(s)).randomExcluded, [.hail, .squall])
        s.resetAdvanced()
        XCTAssertEqual(s.randomExcluded, [])
    }

    func testDryLightningFlashesWithoutRain() {
        var s = SkySettings(); s.timeMode = .frozen; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .dryLightning
        let sky = LivingSky(settings: s, homeZone: melbourneZone)
        var now = start, flashes = 0, was: Float = 0, rain: Float = 0
        for _ in 0..<(120 * 30) {
            now = now.addingTimeInterval(1.0 / 30)
            let st = sky.step(now: now, dt: 1.0 / 30)
            rain = max(rain, st.rain)
            if st.lightning > 0.9 && was <= 0.9 { flashes += 1 }
            was = st.lightning
        }
        XCTAssertGreaterThanOrEqual(flashes, 3, "a dry thunderstorm still flashes")
        XCTAssertEqual(rain, 0, "and drops no rain")
        XCTAssertTrue(WeatherKind.storm.flashes && WeatherKind.squall.flashes && !WeatherKind.rain.flashes)
    }

    func testRainMeltsFrost() {
        let s = sky(.snow)
        XCTAssertEqual(s.step(now: start, dt: 0).frost, 0.6, accuracy: 0.01)
        pick(s, .rain)
        var biggestDrop: Float = 0, last: Float = 0.6
        let after = run(s, seconds: 65, dt: 1.0 / 30) { st in biggestDrop = max(biggestDrop, last - st.frost); last = st.frost }
        XCTAssertLessThanOrEqual(after.frost, 0.01)
        XCTAssertLessThan(biggestDrop, 0.15, "the frost melts over seconds, never vanishing in one frame")
    }

    func testWetnessRisesInRainAndDriesSlowly() {
        let s = sky(.rain)
        let wet = run(s, seconds: 300)
        XCTAssertGreaterThan(wet.wetness, 0.9)
        pick(s, .clear)
        let dry = run(s, seconds: 540)
        XCTAssertGreaterThan(dry.wetness, 0.30 * wet.wetness, "\(dry.wetness)")
        XCTAssertLessThan(dry.wetness, 0.45 * wet.wetness, "\(dry.wetness)")
        pick(s, .afterRain)
        run(s, seconds: 60)
        var lowest: Float = 1
        run(s, seconds: 600) { lowest = min(lowest, $0.wetness) }
        XCTAssertGreaterThanOrEqual(lowest, 0.85)
    }

    func testSnowDoesNotWet() {
        XCTAssertEqual(run(sky(.snow), seconds: 600).wetness, 0)
    }

    func testGustsComeAndGo() {
        func rises(seed: UInt64) -> [Int] {
            var prev: Float = 0, i = 0, out: [Int] = []
            run(sky(.blizzard, seed: seed), seconds: 120, dt: 1.0 / 30) { st in
                if prev < 0.5 && st.gust >= 0.5 { out.append(i) }
                prev = st.gust; i += 1
            }
            return out
        }
        let a = rises(seed: 7)
        XCTAssertTrue((15...40).contains(a.count), "\(a.count) gusts in 2 minutes")
        XCTAssertEqual(rises(seed: 7), a, "the same seed gives the same gusts")
        XCTAssertEqual(run(sky(.clear), seconds: 30).gust, 0)
    }

    func testBlizzardMistRisesWithGust() {
        var peak: Float = 0, quiet: Float = 1
        run(sky(.blizzard), seconds: 30, dt: 1.0 / 30) { st in
            if st.gust > 0.95 { peak = max(peak, st.mist) }
            if st.gust < 0.01 { quiet = min(quiet, st.mist) }
        }
        XCTAssertGreaterThanOrEqual(peak, 0.85)
        XCTAssertEqual(quiet, 0.6, accuracy: 0.02)
    }

    func testAfterRainFollowsRain() {
        var s = SkySettings(); s.weatherMode = .randomBeautiful
        var m = WeatherMachine(settings: s, seed: 11)
        var prev = m.current, wet = 0, after = 0
        for _ in 0..<2000 {
            m.step(dt: 1300, settings: s)   // one whole spell change per step
            if [.drizzle, .rain, .storm].contains(prev) {
                wet += 1
                if m.current == .afterRain { after += 1 }
            }
            XCTAssertNotEqual(m.current, prev, "never the same weather twice in a row")
            prev = m.current
        }
        XCTAssertGreaterThan(wet, 150)
        let share = Double(after) / Double(wet)
        XCTAssertTrue(share > 0.5 && share < 0.7, "after the rain followed \(share) of wet spells")
    }

    func testHaloFromLightCloud() {
        XCTAssertEqual(sky(.lightCloud).step(now: start, dt: 0).halo, 0.7, accuracy: 1e-4)
        XCTAssertEqual(sky(.clear).step(now: start, dt: 0).halo, 0)
        var s = SkySettings(); s.weatherMode = .randomBeautiful
        var m = WeatherMachine(settings: s, seed: 3)
        var halos: [Float] = []
        for _ in 0..<400 {
            m.step(dt: 1300, settings: s)
            if m.current == .lightCloud { halos.append(LivingSky.halo(m)) }
        }
        XCTAssertGreaterThan(halos.count, 20)
        XCTAssertTrue(halos.allSatisfy { $0 >= 0.5 - 1e-4 && $0 <= 1 + 1e-4 }, "\(halos)")
        XCTAssertGreaterThan(Set(halos).count, 5, "each light-cloud spell rolls its own ice")
        XCTAssertGreaterThan(halos.max() ?? 0, 0.85, "icy spells go past 0.7, where the 46° ring shows (spec §6.3)")
    }

    func testPastelMorningsAboutOneInThree() {
        let melbourne = (0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "melbourne") }
        let count = melbourne.filter { $0 }.count
        XCTAssertTrue((80...120).contains(count), "\(count) pastel mornings in 300")
        XCTAssertEqual((0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "melbourne") }, melbourne)
        XCTAssertNotEqual((0..<300).map { LivingSky.dawnIsPastel(day: $0, cityID: "tokyo") }, melbourne)
    }

    private func pastelDay(zone: TimeZone, city: String) throws -> Date {
        try XCTUnwrap((0..<40).map { start.addingTimeInterval(Double($0) * 86_400) }
            .first { LivingSky.dawnIsPastel(day: LivingSky.localDay($0, zone: zone), cityID: city) })
    }

    func testPastelOnlyInTheMorning() throws {
        let day = try pastelDay(zone: melbourneZone, city: "melbourne")
        XCTAssertGreaterThan(run(sky(.clear, hour: 6.2), seconds: 120, now: day).dawnPastel, 0.99)
        XCTAssertLessThan(run(sky(.clear, hour: 19.8), seconds: 120, now: day).dawnPastel, 0.01)
    }

    func testPastelDawnHold() {
        XCTAssertEqual(SkyHold.pastelDawn.rawValue, "Pastel dawn")
        XCTAssertTrue(SkyHold.pastelDawn.forcesPastel)
        XCTAssertFalse(SkyHold.goldenHour.forcesPastel)
        for hour in [2.0, 13.0, 20.0] {
            let st = run(sky(.clear, hour: hour), seconds: 1, hold: .pastelDawn)
            XCTAssertEqual(st.sun.altitude, 1.5, accuracy: 1e-9)
            XCTAssertEqual(st.dawnPastel, 1)
        }
    }

    func testPastelPaletteIsPastel() {
        let p = SkyPalette.colours(sunAltitude: -2, cloud: 0, mist: 0, moonlight: 0, pastel: 1)
        XCTAssertGreaterThan(p.horizon.x, 0.85, "\(p.horizon)")
        XCTAssertTrue(p.horizon.y > 0.5 && p.horizon.y < 0.72, "\(p.horizon)")
        XCTAssertGreaterThan(p.horizon.z, 0.55, "\(p.horizon)")
        XCTAssertGreaterThan(p.zenith.z, p.zenith.x, "lavender-blue zenith \(p.zenith)")
        XCTAssertGreaterThan(p.zenith.x, p.zenith.y * 0.95, "lavender-blue zenith \(p.zenith)")
        // Outside the dawn window, and at pastel 0, the colours are exactly today's.
        for alt in [-20.0, -12, -6, -2, 0, 3, 6, 12, 25] {
            let today = SkyPalette.colours(sunAltitude: alt, cloud: 0.3, mist: 0.2, moonlight: 0.1)
            let zero = SkyPalette.colours(sunAltitude: alt, cloud: 0.3, mist: 0.2, moonlight: 0.1, pastel: 0)
            XCTAssertEqual(today.zenith, zero.zenith); XCTAssertEqual(today.horizon, zero.horizon)
        }
        for alt in [-20.0, -12, 10, 25] {
            let today = SkyPalette.colours(sunAltitude: alt, cloud: 0, mist: 0, moonlight: 0)
            let pastel = SkyPalette.colours(sunAltitude: alt, cloud: 0, mist: 0, moonlight: 0, pastel: 1)
            XCTAssertEqual(today.zenith, pastel.zenith, "at \(alt)°"); XCTAssertEqual(today.horizon, pastel.horizon, "at \(alt)°")
        }
    }

    /// Dhaka is UTC+6, so UTC's date changes at 06:00 there, in the middle of its dawn. A sky that picked its dawn by
    /// the UTC date would change its mind mid-dawn; the city's own date holds all morning. The Mac is on UTC here, so
    /// the Mac's date can't stand in for the city's either.
    func testPastelChoiceHoldsAllMorning() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Dhaka"))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        var day = cal.startOfDay(for: start)
        // A pastel day after a plain one, so the UTC date (still the day before until 06:00) would say no.
        while !(LivingSky.dawnIsPastel(day: LivingSky.localDay(day, zone: zone), cityID: "dhaka")
                && !LivingSky.dawnIsPastel(day: LivingSky.localDay(day.addingTimeInterval(-86_400), zone: zone), cityID: "dhaka")) {
            day = day.addingTimeInterval(86_400)
        }
        var s = SkySettings(); s.timeMode = .realTime; s.cityID = "dhaka"; s.weatherMode = .pick; s.weather = .clear
        let sky = LivingSky(settings: s, homeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        var now = day.addingTimeInterval(4 * 3600)
        _ = sky.step(now: now, dt: 0)
        var lowest: Float = 1, inWindow = 0, beforeSix = 0
        while now < day.addingTimeInterval(8 * 3600) {
            now = now.addingTimeInterval(10)
            let st = sky.step(now: now, dt: 10)
            if st.sun.altitude > -10 && st.sun.altitude < 8 {
                lowest = min(lowest, st.dawnPastel); inWindow += 1
                if now < day.addingTimeInterval(6 * 3600) { beforeSix += 1 }
            }
        }
        XCTAssertGreaterThan(inWindow, 50)
        XCTAssertGreaterThan(beforeSix, 10, "part of the dawn falls before UTC's midnight")
        XCTAssertGreaterThanOrEqual(lowest, 0.95)
    }

    func testOldSettingsStillLoad() throws {
        let blizzard = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"blizzard","weatherMode":"pick"}"#.utf8))
        XCTAssertEqual(blizzard.weather, .blizzard)
        let unknown = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"aurora","cityID":"tokyo"}"#.utf8))
        XCTAssertEqual(unknown.weather, .clear)
        XCTAssertEqual(unknown.cityID, "tokyo")
        // Sets 7 & 8: the two new weathers decode; settings saved before them load the new dials at their defaults.
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"humid"}"#.utf8)).weather, .humid)
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"diamondDust"}"#.utf8)).weather, .diamondDust)
        XCTAssertEqual(blizzard.constellationLines, 0.35)
        XCTAssertEqual(blizzard.auroraScale, 1)
        let night = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"constellationLines":0.8,"auroraScale":5}"#.utf8))
        XCTAssertEqual(night.constellationLines, 0.8)
        XCTAssertEqual(night.auroraScale, 2, "clamped")
        let bad = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"constellationLines":"lots","weather":"snow"}"#.utf8))
        XCTAssertEqual(bad.constellationLines, 0.35)
        XCTAssertEqual(bad.weather, .snow)
        var round = SkySettings(); round.constellationLines = 0.6; round.auroraScale = 1.4
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: JSONEncoder().encode(round)), round)
        // Sets 9 & 10: rime frost decodes (picked, or left out of random); settings saved before it load the two new
        // dials at their defaults, and wild or wrong values fall back on their own.
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"rime","weatherMode":"pick"}"#.utf8)).weather, .rime)
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"randomExcluded":["rime","hail"]}"#.utf8)).randomExcluded, [.rime, .hail])
        XCTAssertEqual([blizzard.iridescence, blizzard.rimeSpeed], [1, 1])
        XCTAssertEqual([unknown.iridescence, unknown.rimeSpeed], [1, 1])
        let wild = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"iridescence":9,"rimeSpeed":0.01}"#.utf8))
        XCTAssertEqual([wild.iridescence, wild.rimeSpeed], [1.5, 0.25], "clamped")
        let wrong = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"iridescence":"pearly","rimeSpeed":null,"weather":"rime"}"#.utf8))
        XCTAssertEqual([wrong.iridescence, wrong.rimeSpeed], [1, 1])
        XCTAssertEqual(wrong.weather, .rime)
        var extras = SkySettings(); extras.iridescence = 0.3; extras.rimeSpeed = 2.5; extras.weather = .rime
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: JSONEncoder().encode(extras)), extras)
        // Sets 11 & 12 (Review focus 4): settings saved before the meteors load the default rate (2), wild or wrong
        // values fall back on their own, sea smoke decodes, and stored weather lists without it still load.
        XCTAssertEqual(blizzard.meteorRate, 2)
        XCTAssertEqual(unknown.meteorRate, 2)
        XCTAssertEqual(night.meteorRate, 2)
        let showers = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"meteorRate":7.5,"weather":"rime"}"#.utf8))
        XCTAssertEqual(showers.meteorRate, 7.5)
        XCTAssertEqual(showers.weather, .rime)
        let many = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"meteorRate":99,"iridescence":0.4}"#.utf8))
        XCTAssertEqual([many.meteorRate, many.iridescence], [10, 0.4], "clamped to 10; the rest kept")
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"meteorRate":0}"#.utf8)).meteorRate, 0.5, "at least 0.5")
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"meteorRate":"lots","weather":"snow"}"#.utf8)).meteorRate, 2)
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"weather":"seaSmoke","weatherMode":"pick"}"#.utf8)).weather, .seaSmoke)
        let older = try JSONDecoder().decode(SkySettings.self, from: Data(#"{"randomExcluded":["rime","hail","diamondDust"]}"#.utf8))
        XCTAssertEqual(older.randomExcluded, [.rime, .hail, .diamondDust], "a list saved before sea smoke")
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: Data(#"{"randomExcluded":["seaSmoke"]}"#.utf8)).randomExcluded, [.seaSmoke])
        var meteors = SkySettings(); meteors.meteorRate = 6.5; meteors.weather = .seaSmoke; meteors.randomExcluded = [.seaSmoke]
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: JSONEncoder().encode(meteors)), meteors)
    }

    func testTheLoungeHasNoWeather() {
        var st = SkyState(); st.halo = 0.7; st.frost = 0.6; st.wetness = 0.9; st.gust = 1
        let lounge = SpaceshipLoungeModel.weatherless(st)
        XCTAssertEqual([lounge.halo, lounge.frost, lounge.wetness, lounge.gust], [0, 0, 0, 0])
        var night = SkyState(); night.aurora = 1; night.auroraStorm = 0.8; night.fireflies = 1; night.diamondDust = 1; night.pillar = 1
        night.rime = 0.9; night.iridescence = 0.7; night.dayOfYear = 308
        let space = SpaceshipLoungeModel.weatherless(night)
        XCTAssertEqual([space.aurora, space.auroraStorm, space.fireflies, space.diamondDust, space.pillar], [0, 0, 0, 0, 0])
        XCTAssertEqual([space.rime, space.iridescence], [0, 0], "no rime and no iridescent cloud in space")
        XCTAssertEqual(space.dayOfYear, 308, "the calendar carries on")
        // Sets 11 & 12: no sea smoke, and no air for meteors to burn in.
        var shower = SkyState(); shower.steam = 1; shower.meteorFlash = 0.08; shower.meteorRate = 120; shower.solarLongitude = 262.2
        shower.meteors = [Meteor(start: SIMD3(0, 1, 0), end: SIMD3(0, 0, 1), born: 1, duration: 0.5, magnitude: -5)]
        shower.shower = ShowerNow(code: "GEM", name: "Geminids", zhr: 150, radiantAltitude: 60, radiantAzimuth: 90,
                                  daysToPeak: 0, radiantRises: nil, radiantHighest: 87)
        let empty = SpaceshipLoungeModel.weatherless(shower)
        XCTAssertEqual([empty.steam, empty.meteorFlash, empty.meteorRate], [0, 0, 0])
        XCTAssertTrue(empty.meteors.isEmpty)
        XCTAssertNil(empty.shower)
        XCTAssertEqual(empty.solarLongitude, 262.2, "the calendar carries on")
    }
}

// MARK: - Sets 7 & 8: the aurora, fireflies, diamond dust and pillars, deep night

extension LivingSkyTests {
    private func frozen(_ kind: WeatherKind, hour: Double, city: String = "melbourne", seed: UInt64 = 1) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = city; s.weatherMode = .pick; s.weather = kind
        return LivingSky(settings: s, seed: seed, homeZone: melbourneZone)
    }

    private func steps(_ sky: LivingSky, seconds: Int, aurora: AuroraMode, hold: SkyHold = .follow, from t0: Date) -> SkyState {
        var st = SkyState()
        for i in 1...seconds { st = sky.step(now: t0.addingTimeInterval(Double(i)), dt: 1, hold: hold, aurora: aurora) }
        return st
    }

    func testAuroraOnlyAtNight() {
        XCTAssertEqual(steps(frozen(.clear, hour: 13, city: "tromso"), seconds: 5, aurora: .always, from: start).aurora, 0, "none by day")
        let night = steps(frozen(.clear, hour: 23, city: "tromso"), seconds: 5, aurora: .always, from: start)
        XCTAssertLessThan(night.sun.altitude, -10)
        XCTAssertGreaterThan(night.aurora, 0.5)
        XCTAssertGreaterThanOrEqual(night.auroraAltitude, 25)
        XCTAssertLessThanOrEqual(night.auroraAltitude, 60)
        XCTAssertEqual(night.hemisphere, 1)
        // Cloud hides it: overcast (cloud 0.85) leaves about a fifth, a storm's full cover a tenth.
        let overcast = steps(frozen(.overcast, hour: 23, city: "tromso"), seconds: 5, aurora: .always, from: start)
        XCTAssertLessThan(overcast.aurora, 0.25 * night.aurora + 0.01)
        XCTAssertLessThan(steps(frozen(.storm, hour: 23, city: "tromso"), seconds: 5, aurora: .always, from: start).aurora, 0.15)
        XCTAssertEqual(steps(frozen(.clear, hour: 23, city: "tromso"), seconds: 5, aurora: .never, from: start).aurora, 0)
        XCTAssertEqual(frozen(.clear, hour: 23).step(now: start, dt: 0).hemisphere, -1, "Melbourne looks south")
    }

    /// Review focus 1: the mode is passed each step, so a world with "Always" leaves no aurora behind it.
    func testAuroraModeIsPerStep() {
        let sky = frozen(.clear, hour: 23)   // Melbourne, seed 1: a quiet Kp (about 1)
        let always = steps(sky, seconds: 30, aurora: .always, from: start)
        XCTAssertLessThan(always.sun.altitude, -10)
        XCTAssertGreaterThan(always.aurora, 0.5)
        XCTAssertTrue(always.auroraAlways, "the sky is told it's for the show (it stands where the world looks)")
        let follow = steps(sky, seconds: 30, aurora: .follow, from: start.addingTimeInterval(30))
        XCTAssertLessThan(follow.aurora, 0.05, "back to the real (quiet) sky at Melbourne")
        XCTAssertFalse(follow.auroraAlways, "and back to the pole")
        XCTAssertLessThan(sky.step(now: start.addingTimeInterval(61), dt: 1).aurora, 0.05, "and the default is follow")
    }

    func testAuroraScaleOnlyInFollow() {
        // Tromsø at night: whatever the seed's Kp, the oval is overhead or close, so follow mode shows it.
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23; s.cityID = "tromso"; s.weatherMode = .pick; s.weather = .clear
        s.auroraScale = 0
        let none = LivingSky(settings: s, homeZone: melbourneZone)
        XCTAssertEqual(steps(none, seconds: 3, aurora: .follow, from: start).aurora, 0)
        XCTAssertGreaterThan(steps(none, seconds: 3, aurora: .always, from: start).aurora, 0.5, "Always ignores the scale")
    }

    func testFirefliesOnlyAtNight() {
        XCTAssertEqual(frozen(.humid, hour: 13).step(now: start, dt: 0).fireflies, 0)
        XCTAssertEqual(frozen(.humid, hour: 2).step(now: start, dt: 0).fireflies, 1, accuracy: 1e-4)
        XCTAssertEqual(frozen(.clear, hour: 2).step(now: start, dt: 0).fireflies, 0)
        XCTAssertEqual(frozen(.humid, hour: 2).step(now: start, dt: 0).frost, 0, "a humid night never frosts")
        let blue = frozen(.humid, hour: 13).step(now: start, dt: 0, hold: .blueHour)   // −6°: half dark
        XCTAssertGreaterThan(blue.fireflies, 0.05)
        XCTAssertLessThan(blue.fireflies, 0.95)
    }

    func testPillarsOnlyWithALowLight() {
        let noon = frozen(.diamondDust, hour: 13).step(now: start, dt: 0)
        XCTAssertGreaterThan(noon.sun.altitude, 30)
        XCTAssertEqual(noon.diamondDust, 1, "the dust glitters any time")
        XCTAssertEqual(noon.pillar, 0, "no pillar under a high sun")
        XCTAssertEqual(frozen(.diamondDust, hour: 13).step(now: start, dt: 0, hold: .goldenHour).pillar, 1, accuracy: 1e-4)
        XCTAssertEqual(frozen(.diamondDust, hour: 2).step(now: start, dt: 0).pillar, 1, accuracy: 1e-4, "the moon's (and lamps') by night")
        XCTAssertEqual(frozen(.clear, hour: 2).step(now: start, dt: 0).pillar, 0)
        XCTAssertGreaterThanOrEqual(noon.halo, 0.99, "diamond dust days show the rings and sundogs")
        XCTAssertEqual(noon.frost, 0.9, accuracy: 0.01)
    }

    func testDeepNightHold() {
        XCTAssertEqual(SkyHold.deepNight.rawValue, "Deep night")
        XCTAssertEqual(SkyHold.deepNight.altitude, -30)
        XCTAssertFalse(SkyHold.deepNight.forcesPastel)
        let st = frozen(.clear, hour: 13).step(now: start, dt: 0, hold: .deepNight)
        XCTAssertEqual(st.sun.altitude, -30, accuracy: 1e-9)
        XCTAssertGreaterThan(st.starVisibility, 0.5)
        XCTAssertLessThan(luminance(st.zenith), 0.05)
    }

    func testConstellationLinesSetting() {
        XCTAssertEqual(frozen(.clear, hour: 2).step(now: start, dt: 0).constellationLines, 0.35, accuracy: 1e-6)
        var s = SkySettings(); s.constellationLines = 1
        XCTAssertEqual(LivingSky(settings: s).step(now: start, dt: 0).constellationLines, 1)
    }

    func testAdvancedNightSkyDefaults() {
        let d = SkySettings()
        XCTAssertEqual([d.constellationLines, d.auroraScale], [0.35, 1])
        let looks: [(SkySettings.AdvancedPreset, [Double])] = [(.gentle, [0.2, 0.7]), (.dramatic, [0.5, 1.6]), (.dreamy, [0.35, 1.0])]
        for (look, expected) in looks {
            var s = SkySettings(); s.constellationLines = 0.9; s.auroraScale = 0.1
            s.applyAdvanced(look)
            XCTAssertEqual([s.constellationLines, s.auroraScale], expected, "\(look)")
            s.resetAdvanced()
            XCTAssertEqual([s.constellationLines, s.auroraScale], [0.35, 1], "Reset after \(look)")
        }
        // Reset restores the night-sky dials from any hand-set value too.
        var hand = SkySettings(); hand.constellationLines = 1; hand.auroraScale = 2
        hand.resetAdvanced()
        XCTAssertEqual(hand, SkySettings())
    }
}

// MARK: - Sets 9 & 10: rime frost, iridescent clouds, the day of the year

extension LivingSkyTests {
    func testRimeValues() {
        XCTAssertEqual(Array(WeatherKind.allCases[25...26]), [.rime, .seaSmoke],
                       "appended in order (sea smoke after it, then the Storms' two), so every saved weather keeps its meaning")
        let v = WeatherKind.rime.values
        // cloud, rain, snow, mist, wind, halo, frost, gust, rime (spec §6.1)
        XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.halo, v.frost, v.gust, v.rime], [0.3, 0, 0, 0.85, 0.08, 0.2, 1, 0, 1])
        XCTAssertEqual([v.fireflies, v.pillar], [0, 0])
        XCTAssertEqual(WeatherKind.rime.beautyWeight, 0.5)
        XCTAssertFalse(WeatherKind.rime.isWet)
        XCTAssertFalse(WeatherKind.rime.isRough)
        XCTAssertFalse(WeatherKind.rime.flashes)
        XCTAssertFalse(WeatherKind.rime.frostFormsOnlyAtNight, "rime forms any time it is cold and foggy")
        for k in WeatherKind.allCases where k != .rime { XCTAssertEqual(k.values.rime, 0, "\(k)") }
        XCTAssertEqual(WeatherValues.mix(WeatherKind.fogBank.values, v, 0.25).rime, 0.25, accuracy: 1e-6, "it blends like the rest")
        // In the sky: frost on the glass by day as well as by night, a faint halo, and no rain, snow, gusts or lightning.
        for hour in [2.0, 13] {
            let st = sky(.rime, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.frost, 1, accuracy: 1e-4, "at \(hour):00")
            XCTAssertEqual(st.mist, 0.85, accuracy: 1e-4)
            XCTAssertEqual(st.halo, 0.2, accuracy: 1e-4)
            XCTAssertEqual([st.rain, st.snow, st.gust, st.lightning], [0, 0, 0, 0])
        }
        // The cold worlds keep it (a rimed world and all), and the sea lies calm under it.
        var still = SkyState(); still.weather = .rime; still.nextWeather = .rime; still.rime = 0.7
        XCTAssertEqual(WorldWeather.cold(still).weather, .rime)
        XCTAssertEqual(WorldWeather.cold(still).rime, 0.7)
        XCTAssertEqual(AuroraFjordModel.fjordSky(still).weather, .rime)
        XCTAssertEqual(OceanSwell.weatherScale(still), 0.3, accuracy: 1e-6)
    }

    /// Rime builds over 10–20 minutes of freezing fog (τ 12 min), melts within minutes in sun once the fog has gone
    /// (τ 6 min) and lingers in the dark (τ 40 min) (spec §6.2).
    func testRimeBuildsInFogAndMeltsInSun() {
        let morning = sky(.rime, hour: 7)
        XCTAssertEqual(morning.step(now: start, dt: 0).rime, 0, "a new sky starts bare")
        let rimed = run(morning, seconds: 20 * 60)
        XCTAssertGreaterThan(rimed.rime, 0.6, "20 minutes of freezing fog at 07:00")
        XCTAssertLessThan(rimed.rime, 0.9, "built over minutes, not at once")
        // The fog clears and it is 13:00: the sun melts it.
        var noon = morning.settings; noon.frozenHour = 13; noon.weather = .clear; morning.settings = noon
        let sunny = run(morning, seconds: 20 * 60)
        XCTAssertGreaterThan(sunny.sun.altitude, 2)
        XCTAssertLessThan(sunny.rime, 0.2, "20 minutes of sun")
        // At 02:00 it lingers: 40 minutes of fog, then 20 minutes clear.
        let night = sky(.rime, hour: 2)
        let deep = run(night, seconds: 40 * 60)
        XCTAssertGreaterThan(deep.rime, 0.9)
        pick(night, .clear)
        let after = run(night, seconds: 20 * 60)
        XCTAssertLessThan(after.sun.altitude, 2)
        XCTAssertGreaterThan(after.rime, 0.5, "the dark keeps it")
        XCTAssertLessThan(after.rime, deep.rime - 0.2, "but it does go, slowly")
    }

    /// The Advanced "Rime speed" (0.25…4) scales how fast rime builds and how fast it melts (spec §6.4).
    func testRimeSpeedScales() {
        func built(_ speed: Double, minutes: Double) -> Float {
            let s = sky(.rime, hour: 7)
            var tuned = s.settings; tuned.rimeSpeed = speed; s.settings = tuned
            return run(s, seconds: minutes * 60).rime
        }
        for speed in [0.5, 1, 2] {
            XCTAssertEqual(built(speed, minutes: 10), Float(1 - exp(-speed * 600 / 720)), accuracy: 0.01, "\(speed)×")
        }
        XCTAssertEqual(built(99, minutes: 2), Float(1 - exp(-4 * 120.0 / 720)), accuracy: 0.01, "at most 4×")
        XCTAssertEqual(built(0, minutes: 10), Float(1 - exp(-0.25 * 600 / 720)), accuracy: 0.01, "at least a quarter")
        // Melting too: rime it through (4× for 20 minutes), then five minutes of sun at each speed.
        func melted(_ speed: Double) -> Float {
            let s = sky(.rime, hour: 7)
            var tuned = s.settings; tuned.rimeSpeed = 4; s.settings = tuned
            XCTAssertGreaterThan(run(s, seconds: 20 * 60).rime, 0.99)
            tuned.rimeSpeed = speed; tuned.frozenHour = 13; tuned.weather = .clear; s.settings = tuned
            return run(s, seconds: 5 * 60).rime
        }
        for speed in [0.5, 1, 2] {
            XCTAssertEqual(melted(speed), Float(exp(-speed * 300 / 360)), accuracy: 0.03, "\(speed)×")
        }
    }

    /// Review focus 3: six hours of alternating 20-minute fog and clear spells, through quick days and nights at the
    /// fastest rime speed, keep the rime in 0…1 while it builds through and melts away again; a reset clears it.
    func testRimeStaysInRangeForHours() {
        var s = SkySettings(); s.timeMode = .quick; s.dayMinutes = 30; s.cityID = "melbourne"; s.weatherMode = .pick
        s.weather = .rime; s.rimeSpeed = 4
        let sky = LivingSky(settings: s, seed: 5, homeZone: melbourneZone)
        _ = sky.step(now: start, dt: 0)
        var lowest: Float = 1, highest: Float = 0, inRange = true
        for i in 1...(6 * 3600) {
            if i % 1200 == 0 { s.weather = s.weather == .rime ? .clear : .rime; sky.settings = s }
            let rime = sky.step(now: start.addingTimeInterval(Double(i)), dt: 1).rime
            if !(rime.isFinite && rime >= 0 && rime <= 1) { inRange = false }
            highest = max(highest, rime)
            if i > 1200 { lowest = min(lowest, rime) }   // after the first fog
        }
        XCTAssertTrue(inRange)
        XCTAssertGreaterThan(highest, 0.98, "the fog rimes it through")
        XCTAssertLessThan(lowest, 0.02, "and the sun takes it all again")
        sky.reset(settings: s)
        XCTAssertEqual(sky.step(now: start, dt: 0).rime, 0, "a reset sky starts bare")
        // Any step, however long or odd, stays in range.
        XCTAssertEqual(LivingSky.rimeStep(0.5, fog: 1, sunAltitude: 30, speed: 4, dt: 1e9), 1, accuracy: 1e-6)
        XCTAssertEqual(LivingSky.rimeStep(0.5, fog: 0, sunAltitude: 30, speed: 4, dt: 1e9), 0, accuracy: 1e-6)
        XCTAssertEqual(LivingSky.rimeStep(.nan, fog: .nan, sunAltitude: .nan, speed: .nan, dt: 1), 0)
    }

    /// Iridescence at the sky's level (spec §6.3): a picked light cloud gives 0.6 × the setting with the sun 20° up;
    /// none under overcast or a clear sky, on cloud too thin, with the sun below 5° (golden hour sits at 5°) or past 50°.
    func testIridescenceOnlyInThinCloudNearAHighSun() throws {
        let hour = try XCTUnwrap(stride(from: 7.5, to: 11, by: 1.0 / 60).first {
            abs(sky(.lightCloud, hour: $0).step(now: start, dt: 0).sun.altitude - 20) < 0.5
        }, "Melbourne's morning sun passes 20°")
        let thin = sky(.lightCloud, hour: hour).step(now: start, dt: 0)
        XCTAssertEqual(thin.cloudCover, 0.35, accuracy: 1e-4)
        XCTAssertEqual(thin.iridescence, 0.6, accuracy: 1e-4)
        for setting in [0, 0.5, 1.5, 9] {
            let s = sky(.lightCloud, hour: hour)
            var tuned = s.settings; tuned.iridescence = setting; s.settings = tuned
            XCTAssertEqual(s.step(now: start, dt: 0).iridescence, Float(0.6 * min(1.5, setting)), accuracy: 1e-4, "setting \(setting)")
        }
        XCTAssertEqual(sky(.overcast, hour: hour).step(now: start, dt: 0).iridescence, 0, "thick cloud")
        XCTAssertEqual(sky(.clear, hour: hour).step(now: start, dt: 0).iridescence, 0, "no cloud")
        for hold in [SkyHold.goldenHour, .pastelDawn, .blueHour, .deepNight] {
            XCTAssertEqual(sky(.lightCloud, hour: hour).step(now: start, dt: 0, hold: hold).iridescence, 0, "\(hold): the sun below 5°")
        }
        let noon = sky(.lightCloud, hour: 13.4).step(now: start, dt: 0)
        XCTAssertGreaterThan(noon.sun.altitude, 50.5)
        XCTAssertEqual(noon.iridescence, 0, "the sun past 50°")
        // Light cloud thinned below 0.15 by the Advanced cloud dial shows none either.
        let wisps = sky(.lightCloud, hour: hour)
        var w = wisps.settings; w.cloudScale = 0.3; wisps.settings = w
        XCTAssertEqual(wisps.step(now: start, dt: 0).iridescence, 0)
    }

    /// About one random light-cloud spell in two is iridescent, each with its own strength 0.3…1, the rest none; a
    /// picked light cloud is 0.6 (spec §6.3).
    func testRandomIridescenceSpells() {
        var s = SkySettings(); s.weatherMode = .randomBeautiful
        var m = WeatherMachine(settings: s, seed: 3)
        var values: [Float] = []
        for _ in 0..<2000 {
            m.step(dt: 1300, settings: s)   // one whole spell change per step
            if m.current == .lightCloud { values.append(m.iridescence) }
        }
        let shown = values.filter { $0 > 0 }
        XCTAssertGreaterThan(values.count, 100)
        XCTAssertTrue(values.allSatisfy { $0 == 0 || (0.3...1).contains($0) }, "\(values)")
        let share = Double(shown.count) / Double(values.count)
        XCTAssertTrue(share > 0.35 && share < 0.65, "\(share) of the light-cloud spells iridesce")
        XCTAssertGreaterThan(Set(shown).count, 20, "each spell rolls its own")
        XCTAssertGreaterThan(shown.max() ?? 0, 0.9)
        XCTAssertLessThan(shown.min() ?? 1, 0.4)
        // Picked light cloud: 0.6, and switching from random to pick settles it there.
        var p = SkySettings(); p.weatherMode = .pick; p.weather = .lightCloud
        XCTAssertEqual(WeatherMachine(settings: p, seed: 3).iridescence, 0.6)
        m.step(dt: 1, settings: p)
        XCTAssertEqual(m.iridescence, 0.6)
    }

    /// The sky's day of the year is the city's own date (spec §6.2): Melbourne's 4 November 2026 is day 308 from just
    /// after its midnight to just before the next (while UTC's date is still the 3rd, or already the 4th), when Tokyo's
    /// is still the 3rd; frozen mode shows today's, and quick mode turns a new day with every cycle.
    func testDayOfYearFollowsTheCity() throws {
        func day(_ mode: TimeMode, _ city: String, _ iso: String) throws -> Int {
            var s = SkySettings(); s.timeMode = mode; s.cityID = city
            let at = try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
            return LivingSky(settings: s, homeZone: melbourneZone).step(now: at, dt: 0).dayOfYear
        }
        XCTAssertEqual(try day(.realTime, "melbourne", "2026-11-03T13:30:00Z"), 308, "00:30 on the 4th in Melbourne")
        XCTAssertEqual(try day(.realTime, "melbourne", "2026-11-04T12:30:00Z"), 308, "23:30 on the 4th")
        XCTAssertEqual(try day(.realTime, "tokyo", "2026-11-03T13:30:00Z"), 307, "22:30 on the 3rd in Tokyo")
        XCTAssertEqual(try day(.frozen, "melbourne", "2026-11-03T13:30:00Z"), 308, "frozen at any hour: today's date")
        // The calendar arithmetic over leap years and the turn of the year (days counted from 1970-01-01).
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 0), 1)
        XCTAssertEqual(LivingSky.dayOfYear(localDay: -1), 365, "31 December 1969")
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 19_782), 60, "29 February 2024")
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 20_088), 366, "31 December 2024")
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 20_761), 308, "4 November 2026")
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 20_819), 1, "1 January 2027")
        XCTAssertEqual(LivingSky.dayOfYear(localDay: 47_541), 60, "1 March 2100 (no leap day in 2100)")
        // Quick mode from noon on the 4th with a two-minute day: a new day at each quick midnight.
        var q = SkySettings(); q.timeMode = .quick; q.dayMinutes = 2; q.cityID = "melbourne"
        let quick = LivingSky(settings: q, homeZone: melbourneZone)
        let noon = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T01:00:00Z"))
        var days = [quick.step(now: noon, dt: 0).dayOfYear]
        for i in 1...270 {   // two and a quarter cycles
            let d = quick.step(now: noon.addingTimeInterval(Double(i)), dt: 1).dayOfYear
            if d != days.last { days.append(d) }
        }
        XCTAssertEqual(days, [308, 309, 310])
    }

    /// The two new Advanced dials (spec §6.5): their defaults, the one-tap looks and Reset.
    func testAdvancedSkyExtrasDefaults() {
        let d = SkySettings()
        XCTAssertEqual([d.iridescence, d.rimeSpeed], [1, 1])
        let looks: [(SkySettings.AdvancedPreset, [Double])] = [(.gentle, [0.6, 0.7]), (.dramatic, [1.4, 1.5]), (.dreamy, [1.0, 1.0])]
        for (look, expected) in looks {
            var s = SkySettings(); s.iridescence = 0.1; s.rimeSpeed = 3.9
            s.applyAdvanced(look)
            XCTAssertEqual([s.iridescence, s.rimeSpeed], expected, "\(look)")
            s.resetAdvanced()
            XCTAssertEqual([s.iridescence, s.rimeSpeed], [1, 1], "Reset after \(look)")
        }
        var hand = SkySettings(); hand.iridescence = 0; hand.rimeSpeed = 4
        hand.resetAdvanced()
        XCTAssertEqual(hand, SkySettings())
        // Sets 11 & 12 (spec §6.5): the Meteors rate, 2 by default; Gentle 1.5, Dramatic 4, Dreamy 2.5; Reset 2.
        XCTAssertEqual(d.meteorRate, 2)
        let rates: [(SkySettings.AdvancedPreset, Double)] = [(.gentle, 1.5), (.dramatic, 4), (.dreamy, 2.5)]
        for (look, rate) in rates {
            var s = SkySettings(); s.meteorRate = 9
            s.applyAdvanced(look)
            XCTAssertEqual(s.meteorRate, rate, "\(look)")
            s.resetAdvanced()
            XCTAssertEqual(s.meteorRate, 2, "Reset after \(look)")
        }
    }
}

// MARK: - Sets 11 & 12: sea smoke, and the meteors in the sky

extension LivingSkyTests {
    /// Sea smoke (spec §6.1): the table's values, appended at the end, not wet, rough or flashing, and frost all day; the
    /// sky carries its steam, the cold worlds keep it, and the swell lies down to 0.4.
    func testSeaSmokeValues() {
        XCTAssertEqual(WeatherKind.allCases.firstIndex(of: .seaSmoke), 26,
                       "appended after rime (the Storms' two after it), so every saved weather keeps its meaning")
        XCTAssertEqual(WeatherKind.seaSmoke.rawValue, "seaSmoke")
        let v = WeatherKind.seaSmoke.values
        // cloud, rain, snow, mist, wind, halo, frost, gust, steam
        XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.halo, v.frost, v.gust, v.steam], [0.1, 0, 0, 0.35, 0.06, 0.3, 0.9, 0, 1])
        XCTAssertEqual([v.fireflies, v.pillar, v.rime], [0, 0, 0])
        XCTAssertEqual(WeatherKind.seaSmoke.beautyWeight, 0.5)
        XCTAssertFalse(WeatherKind.seaSmoke.isWet)
        XCTAssertFalse(WeatherKind.seaSmoke.isRough)
        XCTAssertFalse(WeatherKind.seaSmoke.flashes)
        XCTAssertFalse(WeatherKind.seaSmoke.frostFormsOnlyAtNight, "the cold is bitter all day")
        for k in WeatherKind.allCases where k != .seaSmoke { XCTAssertEqual(k.values.steam, 0, "\(k)") }
        XCTAssertEqual(WeatherValues.mix(WeatherKind.clear.values, v, 0.5).steam, 0.5, accuracy: 1e-6, "it blends like the rest")
        // In the sky, by day and by night: the steam, frost on the glass, a faint mist and halo; no rain, snow or gusts.
        for hour in [2.0, 8, 13] {
            let st = sky(.seaSmoke, hour: hour).step(now: start, dt: 0)
            XCTAssertEqual(st.steam, 1, accuracy: 1e-6, "at \(hour):00")
            XCTAssertEqual(st.frost, 0.9, accuracy: 1e-4)
            XCTAssertEqual(st.mist, 0.35, accuracy: 1e-4)
            XCTAssertEqual(st.halo, 0.3, accuracy: 1e-4)
            XCTAssertEqual([st.rain, st.snow, st.gust, st.lightning], [0, 0, 0, 0])
        }
        XCTAssertEqual(sky(.clear, hour: 8).step(now: start, dt: 0).steam, 0)
        // It glides in with the weather.
        let arriving = sky(.clear, hour: 7)
        pick(arriving, .seaSmoke)
        var steps: [Float] = []
        run(arriving, seconds: 20) { steps.append($0.steam) }
        XCTAssertTrue(steps.first ?? 1 < 0.2 && (steps.last ?? 0) > 0.99, "\(steps.first ?? -1) → \(steps.last ?? -1)")
        // The cold worlds keep it (it is at home in the cold), and the sea lies still under it.
        var still = SkyState(); still.weather = .seaSmoke; still.nextWeather = .seaSmoke; still.steam = 1
        XCTAssertEqual(WorldWeather.cold(still).weather, .seaSmoke)
        XCTAssertEqual(WorldWeather.cold(still).steam, 1)
        XCTAssertEqual(AuroraFjordModel.fjordSky(still).weather, .seaSmoke)
        XCTAssertEqual(OceanSwell.weatherScale(still), 0.4, accuracy: 1e-6)
    }
}

// MARK: - Storms (Sets 17 & 18): the Gust front and Virga, the two Sky extras modes

extension LivingSkyTests {
    /// The two Storms weathers (spec §7): appended at the end (so every saved weather keeps its meaning), their values,
    /// their flags (a gust front ends in rain and is rough; virga is neither), the two new fields only in their own kind,
    /// blending like the rest, and in no world's Random Beautiful unless its table adds them.
    func testStormWeatherValues() {
        XCTAssertEqual(Array(WeatherKind.allCases[27...28]), [.gustFront, .virga], "appended at the end (Fire & Neon's two after)")
        XCTAssertEqual([WeatherKind.gustFront.rawValue, WeatherKind.virga.rawValue], ["gustFront", "virga"])
        let g = WeatherKind.gustFront.values
        // cloud, rain, snow, mist, wind, gust, outflow, virga
        XCTAssertEqual([g.cloud, g.rain, g.snow, g.mist, g.wind, g.gust, g.outflow, g.virga], [0.9, 0.2, 0, 0.5, 1, 1, 1, 0])
        XCTAssertEqual([g.halo, g.frost, g.fireflies, g.pillar, g.rime, g.steam], [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(WeatherKind.gustFront.isWet, "it ends in rain, so after the rain may follow")
        XCTAssertTrue(WeatherKind.gustFront.isRough, "Calm random weather never picks it")
        XCTAssertFalse(WeatherKind.gustFront.flashes, "its lightning is the crawlers on its anvil")
        XCTAssertFalse(WeatherKind.gustFront.frostFormsOnlyAtNight)
        for k in WeatherKind.allCases where k != .gustFront { XCTAssertEqual(k.values.outflow, 0, "\(k)") }
        XCTAssertEqual(WeatherValues.mix(WeatherKind.clear.values, g, 0.5).outflow, 0.5, accuracy: 1e-6)
        XCTAssertEqual(WeatherValues.mix(WeatherKind.clear.values, WeatherKind.virga.values, 0.25).virga, 0.25, accuracy: 1e-6)
        XCTAssertEqual([WeatherKind.gustFront.beautyWeight, WeatherKind.virga.beautyWeight], [0, 0])
        // Settled in the sky: virga's streaks and no rain; the gust front's Approach (its staged weather, not its nominal).
        let virga = sky(.virga).step(now: start, dt: 0)
        XCTAssertEqual([virga.rain, virga.virga, virga.outflow], [0, 1, 0])
        let front = sky(.gustFront, hour: 13).step(now: start, dt: 0)
        XCTAssertEqual(front.gustFront?.stage, .approach)
        XCTAssertEqual(front.rain, 0)
        XCTAssertEqual(front.outflow, 0, "no outflow before the Hit")
        XCTAssertEqual(front.cloudCover, 0.45, accuracy: 1e-5, "the shelf cloud still on the horizon")
        XCTAssertNil(sky(.storm).step(now: start, dt: 0).gustFront)
    }

    /// The two Sky extras modes (Natural) and the gust front's length (180 s) by default (spec §6, §7.1); the one-tap
    /// looks set them (Gentle: Natural, Natural, 300 s; Dramatic: Often, Often, 120 s; Dreamy: Natural, Often, 240 s) and
    /// Reset restores them; the modes' names and their world parameters.
    func testStormExtrasSettings() {
        let d = SkySettings()
        XCTAssertEqual([d.crawlersMode, d.sheetMode], [.natural, .natural])
        XCTAssertEqual(d.gustFrontSeconds, 180)
        let looks: [(SkySettings.AdvancedPreset, SkyExtraMode, SkyExtraMode, Double)] =
            [(.gentle, .natural, .natural, 300), (.dramatic, .often, .often, 120), (.dreamy, .natural, .often, 240)]
        for (look, crawlers, sheet, seconds) in looks {
            var s = SkySettings(); s.crawlersMode = .off; s.sheetMode = .off; s.gustFrontSeconds = 600
            s.applyAdvanced(look)
            XCTAssertEqual([s.crawlersMode, s.sheetMode], [crawlers, sheet], "\(look)")
            XCTAssertEqual(s.gustFrontSeconds, seconds, "\(look)")
            s.resetAdvanced()
            XCTAssertEqual([s.crawlersMode, s.sheetMode], [.natural, .natural], "Reset after \(look)")
            XCTAssertEqual(s.gustFrontSeconds, 180, "Reset after \(look)")
        }
        var hand = SkySettings(); hand.crawlersMode = .often; hand.sheetMode = .off; hand.gustFrontSeconds = 75
        hand.resetAdvanced()
        XCTAssertEqual(hand, SkySettings())
        XCTAssertEqual(SkyExtraMode.allCases.map(\.rawValue), ["Off", "Natural", "Often"])
        XCTAssertEqual([SkyExtraMode.crawlersID, SkyExtraMode.sheetID], ["crawlers.mode", "sheet.mode"])
        let spec = SkyExtraMode.spec(id: SkyExtraMode.crawlersID, name: "Anvil crawlers", help: "Spider lightning", default: .often)
        XCTAssertEqual([spec.id, spec.name, spec.group], ["crawlers.mode", "Anvil crawlers", "Sky"])
        XCTAssertEqual(spec.kind, .choice(["Off", "Natural", "Often"]))
        XCTAssertEqual(spec.defaultValue, .choice("Often"))
    }
}
