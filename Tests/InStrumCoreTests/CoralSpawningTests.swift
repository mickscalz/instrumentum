import XCTest
import simd
@testable import InStrumCore

final class CoralSpawningTests: XCTestCase {
    private let zone = TimeZone(identifier: "Australia/Brisbane")!
    private let cairns = GeoPoint(latitude: -16.9186, longitude: 145.7781)

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// The Living Sky over Cairns, in real time, at `t`.
    private func sky(at t: Date) -> SkyState {
        var s = SkySettings()
        s.timeMode = .realTime
        s.cityID = "cairns"
        s.weatherMode = .pick
        s.weather = .clear
        return LivingSky(settings: s, homeZone: zone).step(now: t, dt: 0)
    }

    /// Sunset on the evening `k` nights after a full moon, on Cairns's calendar (a night runs noon to noon and is named
    /// by its evening: the full moon's own night is 0).
    private func sunset(nights k: Int, after full: Date) throws -> Date {
        let evening = full.addingTimeInterval(-12 * 3600 + Double(k) * 86_400)
        return try XCTUnwrap(Solar.sunset(on: evening, at: cairns, timeZone: zone))
    }

    private var november: Date { Lunar.next(.full, after: date("2026-11-01T00:00:00Z")) }

    /// Spec §9.3: the reef spawns on nights +1…+6 after the October, November and December full moons, from 2.5 to 5
    /// hours after sunset, found with the Living Sky's own moon; never in July; "Tonight" forces it, "Off" never.
    func testSpawningOnlyOnTheRightNights() throws {
        // The November 2026 full moon, found with the Living Sky's own moon: 24 November at 14:55 UT, 00:55 on the 25th
        // in Cairns, so its night is the 24th's.
        let full = november
        XCTAssertEqual(full.timeIntervalSince1970, date("2026-11-24T14:55:21Z").timeIntervalSince1970, accuracy: 120)
        XCTAssertEqual(CoralSpawning.lastFullMoon(before: full.addingTimeInterval(3 * 86_400)).timeIntervalSince1970,
                       full.timeIntervalSince1970, accuracy: 60)
        XCTAssertEqual(CoralSpawning.lastFullMoon(before: full.addingTimeInterval(-86_400)).timeIntervalSince1970,
                       date("2026-10-26T04:13:09Z").timeIntervalSince1970, accuracy: 120, "the day before: October's")
        let hours = [2.5, 3.0, 3.5, 4.0, 4.5, 5.0]
        for k in 1...6 {
            let set = try sunset(nights: k, after: full)
            for h in hours {
                let s = sky(at: set.addingTimeInterval(h * 3600))
                XCTAssertTrue(s.realMoon)
                XCTAssertEqual(s.calendar, set.addingTimeInterval(h * 3600))
                let n = CoralSpawning.night(s)
                XCTAssertEqual(n.night, k, "night +\(k), \(h) h after sunset")
                XCTAssertEqual(n.fullMoonMonth, 11)
                XCTAssertTrue(n.isSpawningNight, "night +\(k), \(h) h after sunset")
                XCTAssertEqual(CoralSpawning.hoursAfterSunset(s) ?? -1, h, accuracy: 0.01, "the sky's sun tells the hours")
                XCTAssertGreaterThan(CoralSpawning.intensity(s, setting: .follow), 0.25, "night +\(k), \(h) h after sunset")
            }
            // The outer reef's nights (+3…+5) are the strongest; in the middle of the hours the intensity is the night's.
            let middle = sky(at: set.addingTimeInterval(3.75 * 3600))
            XCTAssertEqual(CoralSpawning.intensity(middle, setting: .follow), (3...5).contains(k) ? 1 : 0.6, accuracy: 1e-6)
            XCTAssertEqual(CoralSpawning.night(middle).strength, (3...5).contains(k) ? 1 : 0.6)
            // Only in the spawning hours (their 10-minute ramps straddle 2.5 h and 5 h).
            for h in [0.5, 2.0, 2.3, 5.2, 6.0, 9.0, 14.0, 20.0] {
                XCTAssertEqual(CoralSpawning.intensity(sky(at: set.addingTimeInterval(h * 3600)), setting: .follow), 0,
                               "night +\(k), \(h) h after sunset")
            }
        }
        // Night +8 is none, nor +7, nor the full moon's own night.
        for k in [0, 7, 8] {
            let set = try sunset(nights: k, after: full)
            for h in hours {
                let s = sky(at: set.addingTimeInterval(h * 3600))
                XCTAssertFalse(CoralSpawning.night(s).isSpawningNight, "night +\(k)")
                XCTAssertEqual(CoralSpawning.intensity(s, setting: .follow), 0, "night +\(k), \(h) h after sunset")
            }
        }
        // The moon's age alone would miss the last of these nights: after this perigee full moon it runs fast, 21.3–21.4
        // days on night +6 (the age window 15.8–20.8 is for a placed moon). The nights are counted from the real moon.
        let sixth = sky(at: try sunset(nights: 6, after: full).addingTimeInterval(3.75 * 3600))
        XCTAssertGreaterThan(sixth.moonPhase * CoralSpawning.synodicMonth, CoralSpawning.ages.upperBound)
        XCTAssertTrue(CoralSpawning.night(sixth).isSpawningNight)

        // October's and December's full moons too: the inshore reefs a month early, the outer reef with December's.
        for (start, month, strength) in [("2026-10-01T00:00:00Z", 10, Float(0.6)), ("2026-12-01T00:00:00Z", 12, Float(1))] {
            let f = Lunar.next(.full, after: date(start))
            for k in 1...6 {
                let s = sky(at: try sunset(nights: k, after: f).addingTimeInterval(3.75 * 3600))
                XCTAssertEqual(CoralSpawning.night(s).fullMoonMonth, month)
                XCTAssertGreaterThan(CoralSpawning.intensity(s, setting: .follow), 0.5, "\(start) night +\(k)")
            }
            let fourth = sky(at: try sunset(nights: 4, after: f).addingTimeInterval(3.75 * 3600))
            XCTAssertEqual(CoralSpawning.intensity(fourth, setting: .follow), strength, accuracy: 1e-6, start)
            let eighth = sky(at: try sunset(nights: 8, after: f).addingTimeInterval(3.75 * 3600))
            XCTAssertEqual(CoralSpawning.intensity(eighth, setting: .follow), 0, start)
        }
        // July: none. "Tonight" forces it there, in the hours, at full strength; "Off" never, even on the best night.
        let july = Lunar.next(.full, after: date("2026-07-01T00:00:00Z"))
        for k in 1...6 {
            let set = try sunset(nights: k, after: july)
            let s = sky(at: set.addingTimeInterval(3.75 * 3600))
            XCTAssertEqual(CoralSpawning.intensity(s, setting: .follow), 0, "July night +\(k)")
            XCTAssertFalse(CoralSpawning.night(s).isSpawningNight)
            XCTAssertEqual(CoralSpawning.intensity(s, setting: .tonight), 1, accuracy: 1e-6, "July night +\(k), tonight")
            XCTAssertEqual(CoralSpawning.intensity(sky(at: set.addingTimeInterval(1.5 * 3600)), setting: .tonight), 0,
                           "tonight still keeps to the spawning hours")
        }
        let best = sky(at: try sunset(nights: 4, after: full).addingTimeInterval(3.75 * 3600))
        XCTAssertEqual(CoralSpawning.intensity(best, setting: .off), 0)
        XCTAssertEqual(CoralSpawning.intensity(sky(at: try sunset(nights: 8, after: full).addingTimeInterval(3.75 * 3600)),
                                               setting: .tonight), 1, accuracy: 1e-6, "night +8, tonight")

        // With a placed moon (frozen time) the moon's age decides: 15.8–20.8 days. The 27th of November at 22:00.
        func placed(_ phase: Double, hour: Double = 22, on day: String = "2026-11-27T02:00:00Z") -> SkyState {
            var s = SkySettings()
            s.timeMode = .frozen
            s.frozenHour = hour
            s.frozenPhase = phase
            s.cityID = "cairns"
            s.weatherMode = .pick
            s.weather = .clear
            return LivingSky(settings: s, homeZone: zone).step(now: date(day), dt: 0)
        }
        let frozen = placed(0.6)   // 17.7 days
        XCTAssertFalse(frozen.realMoon)
        XCTAssertTrue(CoralSpawning.night(frozen).isSpawningNight)
        XCTAssertEqual(CoralSpawning.night(frozen).night, 3)
        XCTAssertEqual(CoralSpawning.night(frozen).fullMoonMonth, 11)
        XCTAssertEqual(CoralSpawning.hoursAfterSunset(frozen) ?? -1, 3.54, accuracy: 0.05, "the frozen sky's own sun")
        XCTAssertEqual(CoralSpawning.intensity(frozen, setting: .follow), 1, accuracy: 1e-6)
        for phase in [0.5, 0.52, 0.71, 0.75, 0.1] {   // 14.8, 15.4, 21.0, 22.1 and 3.0 days
            XCTAssertEqual(CoralSpawning.intensity(placed(phase), setting: .follow), 0, "phase \(phase)")
        }
        XCTAssertEqual(CoralSpawning.intensity(placed(0.6, on: "2026-07-15T02:00:00Z"), setting: .follow), 0, "July")
        XCTAssertEqual(CoralSpawning.intensity(placed(0.6, hour: 13), setting: .follow), 0, "by day")
        // A held light keeps the clock's hours (its sun is not the clock's): against a sunset 6.06 h after noon (the
        // equinox's sunset hour angle, 90.9°), 22:00 is 3.94 h after sunset.
        var held = frozen
        held.sun.altitude = -30
        XCTAssertEqual(CoralSpawning.hoursAfterSunset(held, held: true) ?? -1, 3.94, accuracy: 0.05)
        XCTAssertGreaterThan(CoralSpawning.intensity(held, setting: .follow, held: true), 0.9)
        held.hourOfDay = 13
        XCTAssertEqual(CoralSpawning.intensity(held, setting: .follow, held: true), 0, "by the clock, not the held sun")

        // Through the world: night +4's frame spawns, night +8's doesn't, nor any with spawning off.
        func frame(_ s: SkyState, setting: CoralSpawningSetting = .follow) -> ReefFrame {
            var model = GreatBarrierReefModel()
            model.setSky(s)
            let p = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id,
                                               state: ThemeState(values: ["spawning": .choice(setting.rawValue)]))
            var f = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            for _ in 0..<29 { f = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high) }
            return f
        }
        let spawning = frame(sky(at: try sunset(nights: 4, after: full).addingTimeInterval(2.75 * 3600)))
        XCTAssertEqual(spawning.spawn.intensity, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(spawning.spawn.beads.count, 300)
        let quiet = frame(sky(at: try sunset(nights: 8, after: full).addingTimeInterval(2.75 * 3600)))
        XCTAssertEqual(quiet.spawn.intensity, 0)
        XCTAssertTrue(quiet.spawn.beads.isEmpty)
        XCTAssertEqual(frame(best, setting: .off).spawn, CoralSpawn.none)
        XCTAssertFalse(frame(sky(at: try sunset(nights: 3, after: july).addingTimeInterval(2.75 * 3600)), setting: .tonight)
                        .spawn.beads.isEmpty, "tonight, in July")
    }

    /// Spec §9.3: the beads rise slowly through the water (0.01–0.03 a second), wobbling, pink, orange and yellow; they
    /// thicken into a snowstorm, then gather into a pinkish slick under the surface, which stays through the spawning
    /// hours and goes with them.
    func testSpawnRisesAndGathers() throws {
        let set = try sunset(nights: 3, after: november)
        let snowstorm = sky(at: set.addingTimeInterval(2.75 * 3600))
        var s = CoralSpawning()
        s.step(dt: 1.0 / 30, sky: snowstorm, setting: .follow, held: false, quality: .high)
        XCTAssertEqual(s.intensity, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(s.beads.count, 500, "arriving mid-snowstorm, the water is already full of spawn")
        XCTAssertLessThan(s.slick, 0.15, "the snowstorm comes first")
        // Follow forty beads: each rises every step at its own pace, 0.01–0.03 water heights a second, wobbling a little.
        var last = Dictionary(uniqueKeysWithValues: s.beads.prefix(40).map { ($0.id, $0.position) })
        var risen = 0, gone = 0
        for _ in 0..<(15 * 30) {
            s.step(dt: 1.0 / 30, sky: snowstorm, setting: .follow, held: false, quality: .high)
            var seen = Set<Int>()
            for b in s.beads {
                guard let p = last[b.id] else { continue }
                seen.insert(b.id)
                let rate = (b.position.y - p.y) * 30
                XCTAssertTrue(rate >= 0.0099 && rate <= 0.0301, "bead \(b.id) rises at \(rate) a second")
                XCTAssertLessThan(abs(b.position.x - p.x), 0.002, "it wobbles, it never jumps")
                last[b.id] = b.position
                risen += 1
            }
            for id in Array(last.keys) where !seen.contains(id) {
                // Gone: it reached the surface and joined the slick.
                XCTAssertGreaterThan(last[id]?.y ?? 0, 0.95, "only at the surface")
                last[id] = nil
                gone += 1
            }
        }
        XCTAssertGreaterThan(risen, 1000)
        XCTAssertGreaterThan(gone, 0, "the highest have reached the surface")
        XCTAssertGreaterThan(s.gathered, 0)
        XCTAssertGreaterThan(s.released, 600, "and new ones keep rising from the corals")
        for b in s.beads {
            XCTAssertTrue(b.position.x >= 0 && b.position.x <= 1)
            XCTAssertTrue(b.position.y >= 0 && b.position.y < 1)
            XCTAssertTrue(b.brightness >= 0 && b.brightness <= 1)
            XCTAssertTrue(b.size >= 1 && b.size <= 2)
            XCTAssertTrue(CoralSpawning.colours.contains(b.colour))
        }
        for colour in CoralSpawning.colours { XCTAssertTrue(s.beads.contains { $0.colour == colour }, "pink, orange and yellow") }
        let near = s.beads.filter { $0.position.y > 0.97 }
        XCTAssertTrue(near.allSatisfy { $0.brightness < 0.55 }, "fading into the slick")
        XCTAssertGreaterThan(s.beads.filter { $0.position.y < 0.5 }.count, 100, "a snowstorm, falling upward")
        let pink = CoralSpawning.colours[0]
        XCTAssertTrue(pink.x == 1 && pink.y < pink.z, "pink")

        // Later in the night the snowstorm has thinned and the slick has gathered under the surface.
        let later = sky(at: set.addingTimeInterval(4.0 * 3600))
        for _ in 0..<(20 * 30) { s.step(dt: 1.0 / 30, sky: later, setting: .follow, held: false, quality: .high) }
        XCTAssertGreaterThan(s.slick, 0.9)
        for _ in 0..<(100 * 4) { s.step(dt: 0.25, sky: later, setting: .follow, held: false, quality: .high) }
        XCTAssertLessThan(s.beads.count, 200, "a trickle now")
        XCTAssertGreaterThan(s.beads.count, 0)
        XCTAssertGreaterThan(s.slick, 0.9, "the slick holds while the spawning hours last")
        // After the hours, the slick goes and the last beads drain up into it; none are released.
        let after = sky(at: set.addingTimeInterval(5.6 * 3600))
        let released = s.released
        for _ in 0..<(100 * 4) { s.step(dt: 0.25, sky: after, setting: .follow, held: false, quality: .high) }
        XCTAssertEqual(s.intensity, 0)
        XCTAssertTrue(s.beads.isEmpty)
        XCTAssertEqual(s.slick, 0)
        XCTAssertEqual(s.released, released)
    }

    /// Spec §9.3: at most 600 beads (300 on Smooth), however long it spawns; deterministic from the seed.
    func testSpawnBounded() throws {
        XCTAssertEqual(CoralSpawning.cap(.lite), 300)
        XCTAssertEqual(CoralSpawning.cap(.high), 600)
        XCTAssertEqual(CoralSpawning.cap(.ultra), 600)
        XCTAssertEqual(CoralSpawning.capacity, 600)
        let set = try sunset(nights: 3, after: november)
        let snowstorm = sky(at: set.addingTimeInterval(2.75 * 3600))
        for q in QualityLevel.allCases {
            var s = CoralSpawning()
            var most = 0
            for _ in 0..<(10 * 60 * 4) {   // ten minutes of a frozen snowstorm, in quarter-second steps
                s.step(dt: 0.25, sky: snowstorm, setting: .follow, held: false, quality: q)
                XCTAssertLessThanOrEqual(s.beads.count, CoralSpawning.cap(q), "\(q)")
                most = max(most, s.beads.count)
            }
            XCTAssertGreaterThan(most, 9 * CoralSpawning.cap(q) / 10, "a full snowstorm (\(q))")
            XCTAssertTrue(s.beads.allSatisfy { $0.position.x.isFinite && $0.position.y >= 0 && $0.position.y < 1 })
        }

        // A whole spawning night on the sky's clock (the sky's 4 hours at 40 times real time): bounded throughout,
        // the snowstorm early, a trickle and the slick after, and nothing left by the end.
        var settings = SkySettings()
        settings.timeMode = .realTime
        settings.cityID = "cairns"
        settings.weatherMode = .pick
        settings.weather = .clear
        let living = LivingSky(settings: settings, homeZone: zone)
        var night = CoralSpawning()
        var peak = 0, peakAt = 0.0, slickest: Float = 0
        for i in 0..<(6 * 3600 / 10) {
            let h = 1.5 + Double(i) * 10 / 3600
            night.step(dt: 0.25, sky: living.step(now: set.addingTimeInterval(h * 3600), dt: 0.25),
                       setting: .follow, held: false, quality: .high)
            XCTAssertLessThanOrEqual(night.beads.count, 600)
            if night.beads.count > peak { peak = night.beads.count; peakAt = h }
            slickest = max(slickest, night.slick)
            if h < 2.4 { XCTAssertTrue(night.beads.isEmpty, "not before the hours") }
        }
        XCTAssertGreaterThan(peak, 100)
        XCTAssertTrue((2.5...3.3).contains(peakAt), "the snowstorm's height comes early: \(peakAt) h after sunset")
        XCTAssertGreaterThan(slickest, 0.5)
        XCTAssertTrue(night.beads.isEmpty)
        XCTAssertEqual(night.slick, 0)

        // Down to Smooth in the middle of a snowstorm: 300 at once (the highest go into the slick).
        var switching = CoralSpawning()
        for _ in 0..<40 { switching.step(dt: 0.25, sky: snowstorm, setting: .follow, held: false, quality: .ultra) }
        XCTAssertGreaterThan(switching.beads.count, 300)
        switching.step(dt: 1.0 / 60, sky: snowstorm, setting: .follow, held: false, quality: .lite)
        XCTAssertLessThanOrEqual(switching.beads.count, 300)

        // Deterministic from the seed.
        func run(seed: UInt64) -> [SpawnBead] {
            var s = CoralSpawning(seed: seed)
            for _ in 0..<120 { s.step(dt: 1.0 / 30, sky: snowstorm, setting: .follow, held: false, quality: .high) }
            return s.beads
        }
        XCTAssertEqual(run(seed: 7), run(seed: 7))
        XCTAssertNotEqual(run(seed: 7), run(seed: 8))

        // Odd inputs stay bounded and finite.
        var odd = CoralSpawning()
        var broken = snowstorm
        broken.sun.altitude = .nan
        broken.hourOfDay = .infinity
        broken.moonPhase = .nan
        for dt in [Double.nan, -1, 1e9, .infinity, 0, 0.25] {
            odd.step(dt: dt, sky: snowstorm, setting: .tonight, held: false, quality: .ultra)
            odd.step(dt: dt, sky: broken, setting: .follow, held: true, quality: .lite)
        }
        XCTAssertLessThanOrEqual(odd.beads.count, 300)
        XCTAssertTrue(odd.beads.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.brightness.isFinite })
        XCTAssertTrue(odd.slick.isFinite && odd.intensity.isFinite)
        XCTAssertEqual(CoralSpawning.intensity(broken, setting: .follow), 0, "a sky with no sun to read has no spawning hours")
        XCTAssertNil(CoralSpawning.hoursAfterSunset(broken))
    }
}
