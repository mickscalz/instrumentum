import XCTest
import simd
@testable import InStrumCore

/// Fire & Neon Task 8 (spec §6.2, §14): satellite passes only while the sky is dark and they are sunlit, fading into the
/// Earth's shadow on the side of the sky away from the sun; flares no brighter than Venus, 2–10 s long; a station once or
/// twice an evening; 4–10 passes an hour after dusk on Natural; a city's skyglow hiding the faint ones; trains. The rates
/// quoted were measured on a Python mirror of the passes' geometry (the same orbits, shadow and brightness, its own
/// random numbers): 7.8 an hour at −7…−9°, 7.3 at −15°, 4.9 at −35°, 2 at −45°; over 200 evenings a station seen once
/// 114 times and twice 86, its first pass at −1.2 … −3.6.
final class SatellitesTests: XCTestCase {
    private let observer = SIMD3<Double>(0, 0, Satellites.earthKm)

    private func sun(_ altitude: Double, azimuth: Double = 260) -> SIMD3<Double> { AnvilCrawlers.enu(azimuth, altitude) }

    /// Steps a machine `seconds` at `dt` with the sun at `altitude(t)`, handing each step's slots on.
    @discardableResult
    private func run(_ m: inout Satellites, seconds: Double, dt: Double, mode: SkyExtraMode = .natural,
                     skyglow: Float? = nil, call: Float? = nil, altitude: (Double) -> Double,
                     each: ([SatelliteSlot], Double, SIMD3<Double>) -> Void = { _, _, _ in }) -> [SatelliteSlot] {
        var slots: [SatelliteSlot] = []
        let n = Int((seconds / dt).rounded())
        for i in 1...n {
            let t = Double(i) * dt
            let s = sun(altitude(t))
            slots = m.step(dt: dt, sun: s, latitude: -37.8, mode: mode, skyglow: skyglow, call: call)
            each(slots, t, s)
        }
        return slots
    }

    private func position(_ t: SatelliteSlot) -> SIMD3<Double> {
        observer + SIMD3<Double>(Double(t.direction.x), Double(t.direction.y), Double(t.direction.z)) * Double(t.rangeKm)
    }

    /// Only while the sun is below −6° (none at −3°, none at −5.9°) and only while sunlit: every slot's satellite stands in
    /// sunlight (by the shadow's own test at its place), above the horizon, a unit direction moving across the sky; none
    /// by day through the sky, none on Off.
    func testOnlyWhileDarkAndSunlit() {
        for alt in [-3.0, -5.9] {
            var m = Satellites(seed: 1)
            var shown = 0
            run(&m, seconds: 3 * 3600, dt: 5, mode: .often, altitude: { _ in alt }) { slots, _, _ in shown += slots.count }
            XCTAssertEqual(shown, 0, "the sun \(alt)°")
            XCTAssertGreaterThan(m.spawned, 20, "they cross all the same, unseen")
        }
        var m = Satellites(seed: 1)
        var shown = 0
        run(&m, seconds: 3 * 3600, dt: 2, altitude: { _ in -9 }) { slots, _, s in
            for t in slots {
                shown += 1
                XCTAssertGreaterThan(Satellites.sunlight(at: self.position(t), sun: s).lit, 0)
                XCTAssertGreaterThan(t.light, 0)
                XCTAssertGreaterThan(t.direction.z, -0.02)
                XCTAssertEqual(simd_length(t.direction), 1, accuracy: 1e-4)
                XCTAssertEqual(simd_dot(t.direction, t.tangent), 0, accuracy: 1e-3)
                XCTAssertTrue((300...1300).contains(Double(t.heightKm)))
            }
            XCTAssertLessThanOrEqual(slots.count, Satellites.slots)
        }
        XCTAssertGreaterThan(shown, 1000)
        var off = Satellites(seed: 1)
        shown = 0
        run(&off, seconds: 3600, dt: 5, mode: .off, altitude: { _ in -12 }) { slots, _, _ in shown += slots.count }
        XCTAssertEqual(shown, 0, "Off")
        // Through the sky: none by day.
        var settings = SkySettings(); settings.timeMode = .frozen; settings.frozenHour = 13; settings.cityID = "melbourne"
        settings.weatherMode = .pick; settings.satellitesMode = .often
        let day = LivingSky(settings: settings, seed: 1, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
        var seen = 0
        for i in 1...720 {
            let st = day.step(now: Date(timeIntervalSince1970: 1_793_000_000 + Double(i) * 5), dt: 5, meteors: .never)
            seen += st.satellites.count
        }
        XCTAssertEqual(seen, 0)
    }

    /// At dusk (the sun 8–16° down) a pass fades into the Earth's shadow on the side of the sky away from the sun, over
    /// a second or two (longer where it meets the shadow's edge at a slant), the sunlight on it reddening as it goes.
    func testShadowEntryFallsOnTheAntiSunSide() {
        var entries = 0, fades: [Double] = [], reddened = false
        for alt in [-8.0, -12.0, -16.0] {
            var m = Satellites(seed: 2)
            var last: [Int: (lit: Float, t: Double)] = [:]
            var fadingSince: [Int: Double] = [:]
            run(&m, seconds: 8 * 3600, dt: 0.25, mode: .often, altitude: { _ in alt }) { slots, t, s in
                for slot in slots where slot.kind != .train {
                    if slot.sunlit < 0.95, slot.sunlit > 0.05, let prev = last[slot.id], prev.lit >= 0.95 { fadingSince[slot.id] = prev.t }
                    if slot.redden > 0.3 { reddened = true }
                    if let prev = last[slot.id], prev.lit >= 0.5, slot.sunlit < 0.5 {
                        entries += 1
                        let away = simd_dot(SIMD2(Double(slot.direction.x), Double(slot.direction.y)), SIMD2(s.x, s.y))
                        XCTAssertLessThan(away, 0, "entering the shadow toward the sun, the sun \(alt)°")
                    }
                    if slot.sunlit <= 0.05, let since = fadingSince.removeValue(forKey: slot.id) { fades.append(t - since) }
                    last[slot.id] = (slot.sunlit, t)
                }
            }
        }
        XCTAssertGreaterThan(entries, 20)
        XCTAssertTrue(reddened, "the last sunlight on it reddens")
        XCTAssertGreaterThan(fades.count, 10)
        let median = fades.sorted()[fades.count / 2]
        XCTAssertTrue((0.5...4).contains(median), "fades over \(median) s (5% to 95%)")
        // The shadow's own law: lit toward the sun, dark behind the Earth, the edge softened by the atmosphere's limb.
        let s = sun(-10, azimuth: 270)
        XCTAssertEqual(Satellites.sunlight(at: SIMD3(-3000, 0, 6500), sun: s).lit, 1, "toward the sun")
        XCTAssertEqual(Satellites.sunlight(at: SIMD3(2000, 0, 5000), sun: s).lit, 0, "behind the Earth")
    }

    /// A flare (one pass in ten, or at a big moment's call) brightens and fades over 2–10 s and never outshines Venus.
    func testFlaresPeakNoBrighterThanVenusAndLastTwoToTenSeconds() {
        for heading in stride(from: 0.0, to: 360, by: 45) {
            var m = Satellites(seed: UInt64(heading) + 1)
            m.force(kind: .satellite, elevation: 70, heading: heading, height: 800, flare: true)
            var span = 0.0, brightest: Float = 99, base: Float = 99
            run(&m, seconds: 900, dt: 0.05, altitude: { _ in -10 }) { slots, _, _ in
                for t in slots where t.id == 1 {
                    if t.flare > 0 { span += 0.05; brightest = min(brightest, t.magnitude) } else { base = min(base, t.magnitude) }
                }
            }
            XCTAssertTrue((2 - 0.11...10 + 0.11).contains(span), "a flare of \(span) s")
            XCTAssertGreaterThanOrEqual(brightest, Satellites.venus - 1e-3, "no brighter than Venus")
            XCTAssertLessThan(brightest, -2.5, "but bright")
            XCTAssertGreaterThan(base - brightest, 2, "out of a fainter satellite")
        }
        XCTAssertEqual(SatelliteSlot.light(magnitude: Satellites.venus), Float(pow(10, -0.4 * (-4.6 + 1.44))), accuracy: 1e-3)
        // On Natural, up to about one an hour.
        var m = Satellites(seed: 3)
        var flaring = Set<Int>()
        run(&m, seconds: 40 * 3600, dt: 1, altitude: { _ in -9 }) { slots, _, _ in
            for t in slots where t.flare > 0 { flaring.insert(t.id) }
        }
        XCTAssertGreaterThan(flaring.count, 5)
        XCTAssertLessThanOrEqual(flaring.count, 48, "\(flaring.count) in 40 hours")
        // A big moment flares a pass in view (at most one each 30 s): the flares a called sky has and the same sky uncalled
        // hasn't (a call draws nothing, so the two skies are otherwise the same).
        func flares(call: Float?) -> [Int: Double] {
            var m = Satellites(seed: 4)
            var first: [Int: Double] = [:]
            run(&m, seconds: 1800, dt: 0.5, mode: .often, call: call, altitude: { _ in -9 }) { slots, t, _ in
                for s in slots where s.flare > 0 && first[s.id] == nil { first[s.id] = t }
            }
            return first
        }
        let natural = flares(call: nil), called = flares(call: 1)
        let byCalls = called.filter { natural[$0.key] == nil }.values.sorted()
        XCTAssertGreaterThan(byCalls.count, 3)
        for (a, b) in zip(byCalls, byCalls.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 29.5) }
    }

    /// A bright station crosses once or twice an evening (the second one orbit later, when it stays lit), its first pass
    /// high and bright: −1 or brighter at its best.
    func testStationOnceOrTwiceAnEvening() {
        var counts: [Int: Int] = [:]
        for seed in 1...30 as ClosedRange<UInt64> {
            var m = Satellites(seed: seed)
            var seen = Set<Int>(), best: Float = 99
            // An evening: the sun from −4° falling a quarter of a degree a minute, for three hours.
            run(&m, seconds: 3 * 3600, dt: 2, altitude: { t in -4 - 0.25 * t / 60 }) { slots, _, _ in
                for t in slots where t.kind == .station { seen.insert(t.id); best = min(best, t.magnitude) }
            }
            XCTAssertTrue((1...2).contains(m.stationTimes.count), "seed \(seed): \(m.stationTimes.count) booked")
            XCTAssertTrue((1...2).contains(seen.count), "seed \(seed): \(seen.count) seen")
            XCTAssertLessThan(best, -1, "seed \(seed)")
            XCTAssertGreaterThan(best, -4.6, "seed \(seed)")
            counts[seen.count, default: 0] += 1
        }
        XCTAssertGreaterThan(counts[1] ?? 0, 3)
        XCTAssertGreaterThan(counts[2] ?? 0, 3)
    }

    /// Natural: 4–10 passes an hour after dusk; Often three times that; far fewer late at night (the shadow climbs).
    func testNaturalRateAfterDusk() {
        func perHour(_ mode: SkyExtraMode, altitude: Double, seed: UInt64 = 5) -> Double {
            var m = Satellites(seed: seed)
            var ids = Set<Int>()
            run(&m, seconds: 12 * 3600, dt: 2, mode: mode, altitude: { _ in altitude }) { slots, _, _ in
                for t in slots where t.kind == .satellite { ids.insert(t.id) }
            }
            return Double(ids.count) / 12
        }
        for seed in [5, 6, 7] as [UInt64] {
            let dusk = perHour(.natural, altitude: -9, seed: seed)
            XCTAssertTrue((4...10).contains(dusk), "\(dusk) an hour after dusk")
        }
        let often = perHour(.often, altitude: -9)
        XCTAssertTrue((12...30).contains(often), "Often: \(often)")
        XCTAssertLessThan(perHour(.natural, altitude: -45), 0.6 * perHour(.natural, altitude: -9), "falling off through the night")
    }

    /// A city's skyglow (a world flag, Neon Night Drive's): only those brighter than magnitude 2 show there; a dark sky
    /// shows the faint ones too. Through the director, a world with the flag hides them; one without shows them.
    func testCitySkyglowHidesTheFaintOnes() {
        var city = Satellites(seed: 8), dark = Satellites(seed: 8)
        var cityShown = 0, faintInDark = 0
        run(&city, seconds: 6 * 3600, dt: 2, mode: .often, skyglow: 2, altitude: { _ in -9 }) { slots, _, _ in
            for t in slots {
                cityShown += 1
                XCTAssertLessThanOrEqual(t.magnitude, 2 + 1e-3, "a \(t.magnitude) in the city")
            }
        }
        run(&dark, seconds: 6 * 3600, dt: 2, mode: .often, altitude: { _ in -9 }) { slots, _, _ in
            faintInDark += slots.filter { $0.magnitude > 2 }.count
        }
        XCTAssertGreaterThan(cityShown, 50, "the bright ones still cross")
        XCTAssertGreaterThan(faintInDark, 500)
        XCTAssertEqual(NeonNightDriveModel.skyglowLimit, 2)
        XCTAssertFalse(MoonlitLakeModel.self is SkyWorldFlags.Type)

        func director(_ entry: ThemeEntry) -> SceneDirector {
            let d = SceneDirector(entry: entry, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 20; s.cityID = "melbourne"; s.weatherMode = .pick
            s.satellitesMode = .often
            d.sky.reset(settings: s)
            let start = Date(timeIntervalSince1970: 1_793_000_000)
            var elapsed = 0.0
            d.clock = { start.addingTimeInterval(elapsed) }
            for i in 1...2400 {
                elapsed = Double(i) * 3
                _ = d.step(dt: 3, t: elapsed, quality: .high)
                for t in d.lastSky?.satellites ?? [] where entry.id == SkyglowProbe.id {
                    XCTAssertLessThanOrEqual(t.magnitude, 2 + 1e-3)
                }
            }
            return d
        }
        _ = director(ThemeEntry.make(SkyglowProbe.self))
        XCTAssertGreaterThan(director(ThemeEntry.make(DarkProbe.self)).sky.satelliteSky.spawned, 10)
    }

    /// A train: one slot, 8–24 evenly spaced members along its track; running into the shadow its leaders go dark first.
    func testTrainsAreALineOfPointsIntoTheShadow() {
        var m = Satellites(seed: 9)
        m.force(kind: .train, elevation: 60, heading: 80, height: 320)
        var sawEdge = false, members = 0
        run(&m, seconds: 900, dt: 0.5, mode: .natural, altitude: { _ in -16 }) { slots, _, _ in
            for t in slots where t.kind == .train {
                members = t.count
                XCTAssertGreaterThan(t.spacing, 0)
                if t.shadowMember >= 0 {
                    sawEdge = true
                    XCTAssertTrue(t.litBehind, "the leaders go into the shadow first")
                    XCTAssertLessThan(t.shadowMember, Float(t.count))
                }
            }
        }
        XCTAssertTrue((8...24).contains(members))
        XCTAssertTrue(sawEdge)
    }

    struct SkyglowProbe: ThemeModel, SkyAware, SkyWorldFlags {
        static let id = "skyglow-probe", displayName = "Skyglow probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        static let skyglowLimit: Float? = 2
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    struct DarkProbe: ThemeModel, SkyAware {
        static let id = "dark-probe", displayName = "Dark probe"
        static let parameters: [ParamSpec] = []
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }
}
