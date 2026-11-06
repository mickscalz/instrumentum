import XCTest
import simd
@testable import InStrumCore

/// Storms Task 6 (spec §3, §6, §7, §8.1, §14; Review focus 5 and 6): anvil crawlers, sheet lightning, the Gust front,
/// Virga, the supercell's stage, Random Beautiful's tables and old saves. The counts and times quoted from "the mirror"
/// were measured on a Python mirror of the machines (the crawler walk and its arrivals, the sheet's arrivals and strokes,
/// the gust front's schedule and its per-front draws: the same streams and arithmetic in doubles) for the seeds used here;
/// every other bound is the spec's, which the machines hold by construction.
final class StormSkyTests: XCTestCase {
    private let zone = TimeZone(identifier: "Australia/Melbourne")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private let fullMoment = BigMoment(kind: .chord, strength: 1, low: false, isDrop: false)

    /// A frozen sky over Melbourne at `hour` (13:00 is day, 23:00 night), the weather picked and settled, seed 1.
    private func sky(_ kind: WeatherKind, hour: Double = 23, seed: UInt64 = 1,
                     _ edit: (inout SkySettings) -> Void = { _ in }) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = kind
        edit(&s)
        let sky = LivingSky(settings: s, seed: seed, homeZone: zone)
        sky.reset(settings: s)
        return sky
    }

    /// Steps `sky` for `seconds` at `dt` (no meteors, so nothing else brightens it), handing each state and its time on.
    @discardableResult
    private func run(_ sky: LivingSky, seconds: Double, dt: Double, hold: SkyHold = .follow, storm: StormInputs = StormInputs(),
                     each: (SkyState, Double) -> Void = { _, _ in }) -> SkyState {
        var st = SkyState()
        let n = max(1, Int((seconds / dt).rounded()))
        for i in 1...n {
            let t = Double(i) * dt
            st = sky.step(now: start.addingTimeInterval(t), dt: dt, hold: hold, meteors: .never, storm: storm)
            each(st, t)
        }
        return st
    }

    /// WCAG's saturated red: red is 80% or more of the light.
    private func isSaturatedRed(_ c: SIMD3<Float>) -> Bool {
        let sum = c.x + c.y + c.z
        return sum > 0 && c.x / sum >= 0.8
    }

    private func degrees(_ v: SIMD3<Float>) -> (azimuth: Double, altitude: Double) {
        var az = atan2(Double(v.x), Double(v.y)) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, asin(Double(min(1, max(-1, v.z)))) * 180 / .pi)
    }

    private func azimuthGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: - Anvil crawlers (spec §6.1)

    /// Only under a storm's anvil with cloud 0.7 or more: none under a clear sky, an overcast one (no storm) or a storm
    /// thinned below 0.7; one every 15–45 s in a supercell's Core stage and every 60–120 s under thunderheads, seeded and
    /// the same at any step size; none at all on Off, called or not; and under a gust front's shelf cloud, from its storm.
    func testCrawlersOnlyUnderStormCloud() throws {
        let quiet: [(String, LivingSky)] = [
            ("clear", sky(.clear, hour: 13) { $0.crawlersMode = .often }),
            ("overcast", sky(.overcast, hour: 13) { $0.crawlersMode = .often }),
            ("a storm thinned to 0.6", sky(.storm, hour: 13) { $0.crawlersMode = .often; $0.cloudScale = 0.6 }),
        ]
        for (name, s) in quiet {
            var lit = 0
            run(s, seconds: 600, dt: 1) { st, _ in lit += st.crawlers.count }
            XCTAssertEqual(lit, 0, name)
            XCTAssertEqual(s.crawlerSky.spawned, 0, name)
        }

        // A supercell's Core (Natural) under an otherwise clear sky: its anvil is always there. The mirror, seed 1: 18 in
        // 10 minutes, the first at 25.00 s, the gaps 17.98–43.80 s (17–23 in 10 minutes over 200 seeds).
        let core = sky(.clear, hour: 13)
        var seen = Set<Double>()
        run(core, seconds: 600, dt: 0.5, storm: StormInputs(supercell: .core)) { st, _ in
            XCTAssertEqual(st.supercell, 1)
            for c in st.crawlers { seen.insert(c.born) }
        }
        let births = core.crawlerSky.births
        XCTAssertEqual(births.count, 18, "the mirror's count")
        XCTAssertEqual(core.crawlerSky.spawned, births.count)
        XCTAssertEqual(births.first ?? 0, 24.9987, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(births.first ?? 99, 45)
        XCTAssertEqual(seen.count, births.count, "every one shows in the sky")
        for (a, b) in zip(births, births.dropFirst()) {
            XCTAssertTrue((15 - 1e-6...45 + 1e-6).contains(b - a), "a gap of \(b - a) s")
        }
        // Seeded: the same sky stepped a second at a time makes the same crawlers at the same instants; another seed others.
        let again = sky(.clear, hour: 13)
        run(again, seconds: 600, dt: 1, storm: StormInputs(supercell: .core))
        XCTAssertEqual(again.crawlerSky.births.count, births.count)
        for (a, b) in zip(again.crawlerSky.births, births) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        let other = sky(.clear, hour: 13, seed: 2)
        run(other, seconds: 600, dt: 1, storm: StormInputs(supercell: .core))
        XCTAssertGreaterThan(abs((other.crawlerSky.births.first ?? 0) - (births.first ?? 0)), 0.01)

        // Thunderheads (not a supercell's core): every 60–120 s. The mirror: 7 in 10 minutes, the first at 80.00 s, the
        // gaps 65.97–95.64 s.
        let heads = sky(.thunderheads, hour: 13)
        run(heads, seconds: 600, dt: 1)
        let slow = heads.crawlerSky.births
        XCTAssertEqual(slow.count, 7, "the mirror's count")
        XCTAssertEqual(slow.first ?? 0, 79.9973, accuracy: 1e-3)
        for (a, b) in zip(slow, slow.dropFirst()) {
            XCTAssertTrue((60 - 1e-6...120 + 1e-6).contains(b - a), "a gap of \(b - a) s")
        }

        // Off: none at all, even in the core with a big moment calling every half second.
        let off = sky(.thunderheads, hour: 13) { $0.crawlersMode = .off }
        run(off, seconds: 120, dt: 0.5, storm: StormInputs(supercell: .core, moment: fullMoment))
        XCTAssertEqual(off.crawlerSky.spawned, 0)

        // A gust front's storm: crawlers on its shelf cloud's anvil, starting within 60° of its bearing.
        let front = sky(.gustFront, hour: 13) { $0.crawlersMode = .often }
        var roots: [Double] = []
        var bearing = 0.0
        run(front, seconds: 600, dt: 0.5) { st, _ in
            bearing = Double(st.gustFront?.bearing ?? 0)
            for c in st.crawlers where c.progress < 0.2 { roots.append(Double(c.segments[0].from.x)) }
        }
        XCTAssertGreaterThan(front.crawlerSky.spawned, 5)
        XCTAssertFalse(roots.isEmpty)
        for r in roots { XCTAssertLessThanOrEqual(azimuthGap(r, bearing), 60 + 1e-3, "rooted at \(r)° for a storm at \(bearing)°") }
    }

    /// Each crawler: 6–14 segments, each 2–6° of the sky, every point in the cloud base band (12–60° up), a channel that
    /// grows from where it began (with forks, as spider lightning has); the leader runs 0 → 1 over 0.5–2 s and the glow
    /// fades linearly over 0.3 s after it, and then it is gone. The mirror: 58 crawlers in 10 minutes for the sky's seed
    /// 1 on Often in a supercell's core; over 20,000 walks every segment 2–6°, every point 12–60°, none ever stuck.
    func testCrawlerGeometry() {
        var machine = AnvilCrawlers(seed: 1 &+ 0xC2A3_71E5)   // the sky's own, for seed 1
        var first: [Double: CrawlerSlot] = [:]
        var watched = 0
        for _ in 0..<60_000 {
            let slots = machine.step(dt: 0.01, mode: .often, eligible: true, core: true)
            for c in slots {
                let age = machine.time - c.born
                let run = Double(c.duration)
                XCTAssertGreaterThanOrEqual(age, 0)
                XCTAssertLessThanOrEqual(age, run + AnvilCrawlers.fadeSeconds + 1e-9, "gone once its glow has faded")
                XCTAssertEqual(Double(c.progress), min(1, age / run), accuracy: 1e-5)
                let glow = age <= run ? 1 : max(0, 1 - (age - run) / 0.3)
                XCTAssertEqual(Double(c.glow), glow, accuracy: 1e-5)
                if first[c.born] == nil { first[c.born] = c }
                watched += 1
            }
        }
        XCTAssertEqual(machine.spawned, 58, "the mirror's count")
        XCTAssertEqual(first.count, machine.spawned, "every crawler seen")
        XCTAssertGreaterThan(watched, 1000)
        var forked = 0
        var widest: Float = 0
        for c in first.values {
            XCTAssertTrue(AnvilCrawlers.segmentCount.contains(c.segments.count), "\(c.segments.count) segments")
            XCTAssertLessThanOrEqual(c.segments.count, AnvilCrawlers.maxSegments)
            XCTAssertTrue((0.5...2.0).contains(Double(c.duration)), "\(c.duration) s")
            XCTAssertTrue((Float(0.15)...Float(0.4)).contains(c.peak), "peak \(c.peak)")
            XCTAssertEqual(c.colour, SIMD3<Float>(0.75, 0.82, 1.0), "a cool blue-white")
            var ends: [SIMD2<Float>] = [c.segments[0].from]
            var farthest: Float = 0
            for (i, seg) in c.segments.enumerated() {
                XCTAssertGreaterThanOrEqual(seg.degrees, 2 - 1e-3, "segment \(i)")
                XCTAssertLessThanOrEqual(seg.degrees, 6 + 1e-3, "segment \(i)")
                for p in [seg.from, seg.to] {
                    XCTAssertGreaterThanOrEqual(p.y, 12 - 1e-3, "in the cloud base band")
                    XCTAssertLessThanOrEqual(p.y, 60 + 1e-3, "in the cloud base band")
                }
                XCTAssertTrue(ends.contains(seg.from), "segment \(i) grows from the channel")
                if i > 0, seg.from != c.segments[i - 1].to { forked += 1 }
                XCTAssertGreaterThanOrEqual(seg.start, 0)
                XCTAssertLessThan(seg.start, seg.end)
                XCTAssertLessThanOrEqual(seg.end, 1)
                XCTAssertEqual(seg.row, SIMD4(seg.from.x, seg.from.y, seg.to.x, seg.to.y))
                XCTAssertEqual(seg.drawn(at: seg.start), 0)
                XCTAssertEqual(seg.drawn(at: (seg.start + seg.end) / 2), 0.5, accuracy: 1e-3)
                XCTAssertEqual(seg.drawn(at: seg.end), 1)
                ends.append(seg.to)
                farthest = max(farthest, seg.end)
            }
            XCTAssertEqual(farthest, 1, accuracy: 1e-6, "the farthest tip is reached as the crawl ends")
            let azimuths = c.segments.flatMap { [$0.from.x, $0.to.x] }
            widest = max(widest, (azimuths.max() ?? 0) - (azimuths.min() ?? 0))
        }
        XCTAssertGreaterThan(forked, 0, "spider lightning branches")
        XCTAssertGreaterThan(widest, 20, "and some crawl a long way across the sky")
    }

    /// Never brighter than 0.4 of the sky's luminance (a big moment at full strength calls one at 0.4); and only a
    /// crawler brighter than 0.25 costs the sky's flash limiter a flash: forced to 0.24 they cost nothing, to 0.26 or 0.4
    /// exactly one each.
    func testCrawlerBrightnessBounded() {
        let busy = sky(.thunderheads, hour: 13) { $0.crawlersMode = .often }
        var brightest: Float = 0
        var called = 0
        for i in 1...7200 {
            let st = busy.step(now: start.addingTimeInterval(Double(i) / 60), dt: 1.0 / 60, meteors: .never,
                               storm: StormInputs(moment: i % 150 == 0 ? fullMoment : nil))
            for c in st.crawlers {
                XCTAssertLessThanOrEqual(c.brightness, AnvilCrawlers.brightest)
                XCTAssertLessThanOrEqual(c.brightness, c.peak)
                XCTAssertGreaterThanOrEqual(c.brightness, 0)
                brightest = max(brightest, c.brightness)
                if c.called { called += 1 }
            }
            XCTAssertLessThanOrEqual(st.stormFlash, 0.4)
            XCTAssertEqual(st.stormFlash, st.crawlers.map(\.brightness).max() ?? 0, accuracy: 1e-6, "the brightest of them")
        }
        XCTAssertGreaterThan(brightest, 0.39, "a full-strength call is at 0.4")
        XCTAssertGreaterThan(called, 0)
        XCTAssertEqual(AnvilCrawlers.costs, FlashLimiter.flashRise)

        let cases: [(Float, Bool)] = [(0.24, false), (0.26, true), (0.4, true)]
        for (peak, costs) in cases {
            let s = sky(.thunderheads, hour: 13) { $0.crawlersMode = .often }
            s.crawlerSky.forcePeak = peak
            var lit: Float = 0
            run(s, seconds: 120, dt: 1.0 / 60, storm: StormInputs(supercell: .core)) { st, _ in lit = max(lit, st.stormFlash) }
            XCTAssertGreaterThan(s.crawlerSky.spawned, 3, "peak \(peak)")
            XCTAssertEqual(lit, peak, accuracy: 1e-3, "nothing held back")
            XCTAssertEqual(s.flashLimiter.total, costs ? s.crawlerSky.spawned : 0, "peak \(peak)")
        }
    }

    // MARK: - Sheet lightning (spec §6.2)

    /// At dusk or by night, with a far storm (a world's, or a supercell's) or a dry storm in this sky (thunderheads, dry
    /// lightning, virga); not under a clear or overcast sky, nor a rainy storm overhead (that is real lightning), nor by
    /// day, nor on Off. Natural: every 8–30 s (the mirror, seed 1: 32 in 10 minutes, the first at 22.62 s, the gaps
    /// 10.45–29.84 s), each within ±15° of its storm's bearing.
    func testSheetLightningOnlyWithFarStormsOrDryStorm() {
        func flashes(_ kind: WeatherKind, hour: Double, hold: SkyHold = .follow, storm: StormInputs = StormInputs(),
                     mode: SkyExtraMode = .often) -> Int {
            let s = sky(kind, hour: hour) { $0.sheetMode = mode; $0.crawlersMode = .off }
            run(s, seconds: 300, dt: 0.5, hold: hold, storm: storm)
            return s.sheetSky.spawned
        }
        XCTAssertGreaterThan(flashes(.thunderheads, hour: 23), 10)
        XCTAssertGreaterThan(flashes(.dryLightning, hour: 23), 10)
        XCTAssertGreaterThan(flashes(.virga, hour: 23), 10)
        XCTAssertGreaterThan(flashes(.clear, hour: 23, storm: StormInputs(farStorm: 1)), 10, "a far storm on a clear night")
        XCTAssertGreaterThan(flashes(.clear, hour: 23, storm: StormInputs(supercell: .approach)), 10, "a supercell is a far storm")
        XCTAssertGreaterThan(flashes(.thunderheads, hour: 13, hold: .blueHour), 10, "at dusk (the sun 6° down)")
        XCTAssertEqual(flashes(.clear, hour: 23), 0)
        XCTAssertEqual(flashes(.overcast, hour: 23), 0)
        XCTAssertEqual(flashes(.storm, hour: 23), 0, "a storm overhead throws real lightning")
        XCTAssertEqual(flashes(.clear, hour: 23, storm: StormInputs(farStorm: 0.4)), 0, "only a far storm, not a hint of one")
        XCTAssertEqual(flashes(.thunderheads, hour: 13), 0, "not by day")
        XCTAssertEqual(flashes(.thunderheads, hour: 13, hold: .goldenHour), 0)
        XCTAssertEqual(flashes(.clear, hour: 13, storm: StormInputs(farStorm: 1)), 0)
        XCTAssertEqual(flashes(.thunderheads, hour: 23, mode: .off), 0)

        let s = sky(.thunderheads, hour: 23)
        var azimuths: [Double] = []
        run(s, seconds: 600, dt: 0.5) { st, _ in for f in st.sheet { azimuths.append(Double(f.azimuth)) } }
        let births = s.sheetSky.births
        XCTAssertEqual(births.count, 32, "the mirror's count")
        XCTAssertEqual(births.first ?? 0, 22.6168, accuracy: 1e-3)
        for (a, b) in zip(births, births.dropFirst()) {
            XCTAssertTrue((8 - 1e-6...30 + 1e-6).contains(b - a), "a gap of \(b - a) s")
        }
        XCTAssertEqual(s.sheetSky.bearing, 196.44, accuracy: 0.01, "the mirror's bearing for this storm")
        XCTAssertFalse(azimuths.isEmpty)
        for a in azimuths { XCTAssertLessThanOrEqual(azimuthGap(a, s.sheetSky.bearing), 15 + 1e-3) }
    }

    /// Never brighter than 0.2 (Often, with a big moment at full strength calling one every 2.5 s, for three minutes):
    /// the rim's glow at its centre on the horizon is its brightness and falls away up the sky and to the sides; the
    /// limiter sees it (the storm light carries it) but never counts a flash. Each flash 0.1–0.3 s, 10–25° wide, 3–6° up,
    /// warm white, its strokes within 0…1.
    func testSheetBrightnessNeverExceedsPointTwo() {
        let s = sky(.thunderheads, hour: 23) { $0.sheetMode = .often; $0.crawlersMode = .off }
        var brightest: Float = 0, counted: Float = 0
        var called = 0
        for i in 1...5400 {
            let st = s.step(now: start.addingTimeInterval(Double(i) / 30), dt: 1.0 / 30, meteors: .never,
                            storm: StormInputs(moment: i % 75 == 0 ? fullMoment : nil))
            for f in st.sheet {
                XCTAssertLessThanOrEqual(f.brightness, SheetLightning.brightest)
                XCTAssertTrue((0...1).contains(f.level))
                XCTAssertTrue((0.1 - 1e-6...0.3 + 1e-6).contains(Double(f.duration)))
                XCTAssertTrue((10 - 1e-4...25 + 1e-4).contains(Double(f.width)))
                XCTAssertTrue((3 - 1e-4...6 + 1e-4).contains(Double(f.height)))
                XCTAssertTrue((0.5 - 1e-6...1 + 1e-6).contains(Double(f.strength)))
                XCTAssertEqual(f.colour, SheetLightning.colour)
                XCTAssertEqual(f.glow(azimuth: f.azimuth, altitude: 0), f.brightness, accuracy: 1e-6)
                XCTAssertLessThan(f.glow(azimuth: f.azimuth, altitude: f.height), 0.14 * f.brightness + 1e-6, "e⁻² at its top")
                XCTAssertEqual(f.glow(azimuth: f.azimuth + f.width / 2 + 0.01, altitude: 0), 0, "a raised cosine across its width")
                XCTAssertEqual(f.glow(azimuth: f.azimuth, altitude: -1), 0, "nothing below the horizon")
                brightest = max(brightest, f.brightness)
                if f.called { called += 1 }
            }
            XCTAssertLessThanOrEqual(st.stormFlash, SheetLightning.brightest)
            counted = max(counted, st.stormFlash)
        }
        XCTAssertGreaterThan(brightest, 0.15)
        XCTAssertGreaterThan(called, 0)
        XCTAssertGreaterThan(s.sheetSky.spawned, 50)
        XCTAssertEqual(counted, brightest, accuracy: 1e-6, "the limiter sees it")
        XCTAssertEqual(s.flashLimiter.total, 0, "and it never costs a flash")
        XCTAssertFalse(isSaturatedRed(SheetLightning.colour))
    }

    /// With cloud over you, each flash lights the nearest cloud cell from inside: the cell of the cloud deck (the cloud
    /// layer's own, at rest) that holds the point right above the glow at its azimuth, so its centre is the nearest of all
    /// the cells' to it; seen low on the flash's side of the sky; brightened by 1 + 1.5 × the flash's level. Under a clear
    /// sky (a far storm with no cloud over you) only the rim glows.
    func testSheetLightsTheNearestCloudCell() {
        let s = sky(.thunderheads, hour: 23) { $0.sheetMode = .often; $0.crawlersMode = .off }
        var checked = 0, lit = 0
        run(s, seconds: 300, dt: 1.0 / 30) { st, _ in
            for f in st.sheet {
                let point = SheetLightning.deck(AnvilCrawlers.enu(Double(f.azimuth), Double(f.height) + SheetLightning.deckAbove))
                let cell = SheetLightning.cell(containing: point)
                XCTAssertEqual(Double(f.cell.x), cell.x, accuracy: 1e-4)
                XCTAssertEqual(Double(f.cell.y), cell.y, accuracy: 1e-4)
                XCTAssertLessThanOrEqual(abs(point.x - cell.x), 0.5)
                XCTAssertLessThanOrEqual(abs(point.y - cell.y), 0.5)
                let near = simd_distance(point, cell)
                for dx in -1...1 {
                    for dy in -1...1 where dx != 0 || dy != 0 {
                        XCTAssertGreaterThanOrEqual(simd_distance(point, cell + SIMD2(Double(dx), Double(dy))), near - 1e-9,
                                                    "no other cell is nearer")
                    }
                }
                let back = SheetLightning.deck(SIMD3(Double(f.cellDirection.x), Double(f.cellDirection.y), Double(f.cellDirection.z)))
                XCTAssertEqual(back.x, cell.x, accuracy: 1e-3)
                XCTAssertEqual(back.y, cell.y, accuracy: 1e-3)
                let seen = degrees(f.cellDirection)
                XCTAssertLessThanOrEqual(azimuthGap(seen.azimuth, Double(f.azimuth)), 15, "on the flash's side of the sky")
                XCTAssertTrue((2...12).contains(seen.altitude), "low over the glow: \(seen.altitude)°")
                XCTAssertEqual(f.cellGain, 1 + 1.5 * f.level, accuracy: 1e-5)
                if f.cellGain > 1.5 { lit += 1 }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 150)   // the mirror: 276 frames of 300 s at 30 fps, 100 lit past 1.5
        XCTAssertGreaterThan(lit, 30)

        let bare = sky(.clear, hour: 23) { $0.sheetMode = .often }
        var rim = 0
        run(bare, seconds: 120, dt: 1.0 / 30, storm: StormInputs(farStorm: 1)) { st, _ in
            for f in st.sheet {
                XCTAssertEqual(f.cellGain, 1, "no cloud over you to light")
                if f.brightness > 0 { rim += 1 }
            }
        }
        XCTAssertGreaterThan(rim, 10, "the rim still glows")

        // The deck is the cloud layer's: straight up is its centre, the horizon 10.08 cells out; and back again.
        XCTAssertEqual(simd_length(SheetLightning.deck(SIMD3(0, 0, 1))), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_length(SheetLightning.deck(SIMD3(1, 0, 0))), 1.21 / 0.12, accuracy: 1e-9)
        for (az, alt) in [(0.0, 5.0), (90, 30), (200, 60), (315, 85)] {
            let d = AnvilCrawlers.enu(az, alt)
            let back = SheetLightning.direction(deck: SheetLightning.deck(d))
            XCTAssertLessThan(simd_distance(back, d), 1e-9, "\(az)°, \(alt)°")
        }
    }

    // MARK: - The Gust front (spec §7.1)

    /// Picked, 3 minutes by default: Approach (the shelf cloud rising, inflow gusts toward the storm, no rain) until a
    /// third; the Hit at exactly a third, the dust wall crossing in 10–20 s, the wind turning to 1 and the outflow with it
    /// by 60% of the crossing, the warmth graded down 8% as the wall passes, still no rain; the Rain at exactly two
    /// thirds, the first drops (0.2) and then 0.6 by five sixths, holding. The mirror, seed 1: the wall crosses in
    /// 18.84 s, stands 9.80° tall, and comes from 204.45°. The sound: the roar on the wind rises 12 dB over the Hit; the
    /// rain on dust rises through the Hit before a drop has fallen.
    func testGustFrontStages() throws {
        let s = sky(.gustFront, hour: 13)
        var states: [(t: Double, st: SkyState)] = []
        run(s, seconds: 240, dt: 0.25) { st, t in states.append((t, st)) }
        let g0 = try XCTUnwrap(states.first?.st.gustFront)
        XCTAssertEqual(g0.crossSeconds, 18.8365, accuracy: 1e-3)
        XCTAssertEqual(g0.dustHeight, 9.797, accuracy: 1e-3)
        XCTAssertEqual(g0.bearing, 204.45, accuracy: 0.01)
        XCTAssertEqual(g0.duration, 180, "3 minutes by default")
        let cross = g0.crossSeconds
        XCTAssertTrue((10...20).contains(cross))
        XCTAssertTrue((8...15).contains(g0.dustHeight))
        var firstHit: Double?, firstRain: Double?
        var lastFront: Float = 0
        for (t, st) in states {
            let g = try XCTUnwrap(st.gustFront, "at \(t) s")
            XCTAssertEqual(g.elapsed, t, accuracy: 1e-9)
            XCTAssertEqual(g.amount, 1)
            XCTAssertEqual(g.crossSeconds, cross, "drawn once a front")
            XCTAssertEqual(st.outflow, g.outflow, accuracy: 1e-5)
            XCTAssertEqual(st.warmthGrade, g.warmth, accuracy: 1e-6)
            XCTAssertEqual(st.cloudCover, g.cloud, accuracy: 1e-5)
            XCTAssertEqual(st.rain, g.rain, accuracy: 1e-5)
            XCTAssertEqual(st.mist, g.mist, accuracy: 1e-5)
            XCTAssertEqual(st.wind, g.wind, accuracy: 1e-5)
            XCTAssertGreaterThanOrEqual(g.dustFront, lastFront, "the wall only moves on")
            lastFront = g.dustFront
            if t < 60 {
                XCTAssertEqual(g.stage, .approach, "at \(t) s")
                XCTAssertEqual(st.rain, 0)
                XCTAssertEqual(g.outflow, 0)
                XCTAssertGreaterThan(g.inflow, 0, "the inflow blows toward the storm")
                XCTAssertEqual(g.dustFront, 0)
                XCTAssertEqual(g.warmth, 0)
                XCTAssertLessThanOrEqual(st.wind, 0.45 + 1e-5)
            } else if t < 120 {
                if firstHit == nil { firstHit = t }
                XCTAssertEqual(g.stage, .hit, "at \(t) s")
                XCTAssertEqual(st.rain, 0, "no rain through the Hit (\(t) s)")
                XCTAssertEqual(Double(g.dustFront), min(1, (t - 60) / cross), accuracy: 1e-5)
                if t >= 60 + 0.6 * cross {
                    XCTAssertEqual(st.wind, 1, accuracy: 1e-6, "at \(t) s")
                    XCTAssertEqual(g.outflow, 1, accuracy: 1e-6)
                    XCTAssertEqual(g.inflow, 0, accuracy: 1e-6, "the wind has turned")
                }
                if t >= 60 + cross { XCTAssertEqual(st.warmthGrade, -0.08, accuracy: 1e-6, "at \(t) s") }
            } else {
                if firstRain == nil { firstRain = t }
                XCTAssertEqual(g.stage, .rain, "at \(t) s")
                if t >= 124 { XCTAssertGreaterThanOrEqual(st.rain, 0.2 - 1e-5, "the first drops (\(t) s)") }
                if t >= 150 { XCTAssertEqual(st.rain, 0.6, accuracy: 1e-5, "at \(t) s") }
                XCTAssertEqual(st.warmthGrade, -0.08, accuracy: 1e-6, "the cold holds")
            }
        }
        XCTAssertEqual(firstHit ?? 0, 60, accuracy: 1e-9, "the Hit at a third")
        XCTAssertEqual(firstRain ?? 0, 120, accuracy: 1e-9, "the Rain at two thirds")
        XCTAssertGreaterThan(states.last?.st.wetness ?? 0, 0.1, "and the ground gets wet")
        func at(_ t: Double) -> SkyState { states[Int((t / 0.25).rounded()) - 1].st }
        XCTAssertLessThan(at(10).cloudCover, at(55).cloudCover, "the shelf cloud comes over")
        XCTAssertGreaterThan(at(60 + cross / 2).gustFront?.dust ?? 0, 0.9, "the dust wall")

        // The roar on the wind: 0.2 through the Approach, 0.8 once the wall has passed (12.04 dB), never falling as it
        // crosses; the rain on dust 0 in the Approach, 0.7 at the end of the Hit while still dry, 0.3 in the rain.
        let quiet = try XCTUnwrap(WeatherAmbience.gustRoar(at(30)))
        let loud = try XCTUnwrap(WeatherAmbience.gustRoar(at(100)))
        XCTAssertEqual(quiet, 0.2, accuracy: 1e-9)
        XCTAssertEqual(20 * log10(loud / quiet), 12.04, accuracy: 0.05)
        var roar = 0.0
        for t in stride(from: 60.0, through: 60 + cross, by: 0.25) {
            let r = try XCTUnwrap(WeatherAmbience.gustRoar(at(t)))
            XCTAssertGreaterThanOrEqual(r, roar - 1e-12)
            roar = r
        }
        XCTAssertEqual(WeatherAmbience.rainOnDust(at(30)) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(at(119.75).rain, 0)
        XCTAssertGreaterThan(WeatherAmbience.rainOnDust(at(119.75)) ?? 0, 0.69, "the smell of rain before the rain")
        XCTAssertEqual(WeatherAmbience.rainOnDust(at(200)) ?? -1, 0.3, accuracy: 1e-6)
        // A world hears it: the coast road's wind roars, and the rain on dust is set.
        var road = CoastRoadModel()
        road.setSky(at(100))
        let params = ParameterSet(specs: CoastRoadModel.parameters, macroTargets: CoastRoadModel.macroTargets)
        let scene = road.step(dt: 1.0 / 30, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience
        XCTAssertGreaterThanOrEqual(scene.level(.wind), 0.8 - 1e-9)
        XCTAssertGreaterThan(scene.level(.rainOnDust), 0.3)

        // Other lengths (Advanced 60–600 s, clamped): the stages at their thirds.
        for (d, hit, rain) in [(60.0, 20.0, 40.0), (600, 200, 400), (30, 20, 40), (9000, 200, 400)] {
            XCTAssertEqual(WorldWeather.gustFront(elapsed: hit - 0.01, duration: d).stage, .approach, "\(d) s")
            XCTAssertEqual(WorldWeather.gustFront(elapsed: hit, duration: d).stage, .hit, "\(d) s")
            XCTAssertEqual(WorldWeather.gustFront(elapsed: rain - 0.01, duration: d).stage, .hit, "\(d) s")
            XCTAssertEqual(WorldWeather.gustFront(elapsed: rain, duration: d).stage, .rain, "\(d) s")
        }
        let quick = sky(.gustFront, hour: 13) { $0.gustFrontSeconds = 60 }
        XCTAssertEqual(run(quick, seconds: 20, dt: 0.25).gustFront?.stage, .hit, "the setting reaches the sky")
        // When it has gone (a clear sky picked), so has its state.
        var clear = s.settings; clear.weather = .clear; clear.pickBlendSeconds = 1
        s.settings = clear
        let after = run(s, seconds: 5, dt: 0.25)
        XCTAssertNil(after.gustFront)
        XCTAssertEqual([after.outflow, after.warmthGrade], [0, 0])
    }

    // MARK: - Virga (spec §7.2)

    /// Rain that never lands: no rain at any step, by day or night, mist 0.6, the streaks at 1, cloud 0.7, the ground
    /// never wet; arriving from rain, the rain gives way to the streaks; and the sound is a dry wind and the smell of rain
    /// on dust, with no rain in any world.
    func testVirgaHasNoRain() {
        let v = WeatherKind.virga.values
        XCTAssertEqual([v.cloud, v.rain, v.snow, v.mist, v.wind, v.gust, v.virga, v.outflow], [0.7, 0, 0, 0.6, 0.4, 0.3, 1, 0])
        XCTAssertFalse(WeatherKind.virga.isWet)
        XCTAssertFalse(WeatherKind.virga.isRough)
        XCTAssertFalse(WeatherKind.virga.flashes)
        for k in WeatherKind.allCases where k != .virga { XCTAssertEqual(k.values.virga, 0, "\(k)") }
        var settled = SkyState()
        for hour in [13.0, 23] {
            let s = sky(.virga, hour: hour)
            settled = run(s, seconds: 600, dt: 1) { st, t in
                XCTAssertEqual(st.rain, 0, "at \(t) s")
                XCTAssertEqual(st.snow, 0)
                XCTAssertEqual(st.virga, 1, accuracy: 1e-6)
                XCTAssertEqual(st.mist, 0.6, accuracy: 1e-5)
                XCTAssertEqual(st.cloudCover, 0.7, accuracy: 1e-5)
                XCTAssertEqual(st.wetness, 0)
                XCTAssertEqual(st.lightning, 0)
                XCTAssertNil(st.gustFront)
            }
        }
        // From rain: as the rain eases off the streaks come in (rain/0.75 + virga = 1 all the way), and then none lands.
        let s = sky(.rain, hour: 13) { $0.pickBlendSeconds = 10 }
        var next = s.settings; next.weather = .virga
        s.settings = next
        let arrived = run(s, seconds: 30, dt: 0.5) { st, _ in
            XCTAssertEqual(st.rain / 0.75 + st.virga, 1, accuracy: 1e-5)
        }
        XCTAssertEqual(arrived.rain, 0)
        XCTAssertEqual(arrived.virga, 1, accuracy: 1e-6)
        // The sound: the dry wind (0.25 + 0.35 × gust) and the petrichor (0.5), and no rain on water or glass anywhere.
        var levels: [AmbienceSource: Double] = [:]
        WeatherAmbience.levels(settled, base: &levels)
        XCTAssertEqual(levels[.rainOnDust] ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(levels[.wind] ?? -1, 0.25 + 0.35 * Double(settled.gust), accuracy: 1e-6)
        XCTAssertNil(levels[.drips], "nothing is wet")
        var road = CoastRoadModel(), lake = MoonlitLakeModel()
        road.setSky(settled); lake.setSky(settled)
        let rp = ParameterSet(specs: CoastRoadModel.parameters, macroTargets: CoastRoadModel.macroTargets)
        let lp = ParameterSet(specs: MoonlitLakeModel.parameters, macroTargets: MoonlitLakeModel.macroTargets)
        let roadScene = road.step(dt: 1.0 / 30, params: rp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience
        let lakeScene = lake.step(dt: 1.0 / 30, params: lp, roles: RoleValues(), inputs: InputFrame(), quality: .high).ambience
        XCTAssertEqual(roadScene.level(.rainOnGlass), 0)
        XCTAssertEqual(lakeScene.level(.rainOnWater), 0)
        XCTAssertEqual(roadScene.level(.rainOnDust), 0.5, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(lakeScene.level(.wind), 0.25 - 1e-9)
        // A cold world has none to fall as snow either.
        let cold = WorldWeather.cold(settled)
        XCTAssertEqual([cold.rain, cold.snow], [0, 0])
    }

    // MARK: - The supercell's stage (spec §8.1)

    /// The picker's Approach, Core and Clearing hold the event's phase at the middle of each third (1/6, 1/2, 5/6); a
    /// change plays forward to it (never back) within a minute; Cycle runs the event a pass every 8 minutes and loops. A
    /// world without a stage has no supercell.
    func testSupercellStageMapping() throws {
        XCTAssertEqual(SupercellStage.allCases.map(\.rawValue), ["Approach", "Core", "Clearing", "Cycle"])
        for (stage, phase) in [(SupercellStage.approach, 1.0 / 6), (.core, 0.5), (.clearing, 5.0 / 6)] {
            XCTAssertEqual(try XCTUnwrap(WorldWeather.supercellPhase(held: stage)), phase, accuracy: 1e-12)
            XCTAssertEqual(SupercellStage.event(at: Float(phase)), stage)
        }
        XCTAssertNil(WorldWeather.supercellPhase(held: .cycle))
        let thirds: [(Float, SupercellStage)] = [(0, .approach), (0.33, .approach), (0.34, .core), (0.66, .core), (0.67, .clearing),
                                                 (0.999, .clearing), (1, .approach), (1.5, .core), (-0.1, .clearing), (.nan, .approach)]
        for (p, stage) in thirds { XCTAssertEqual(SupercellStage.event(at: p), stage, "\(p)") }
        let spec = SupercellStage.spec(default: .core)
        XCTAssertEqual(spec.id, "supercell.stage")
        XCTAssertEqual(spec.defaultValue, .choice("Core"))
        XCTAssertEqual(spec.kind, .choice(["Approach", "Core", "Clearing", "Cycle"]))

        // Held at its Core from the first step (and a supercell is a far storm).
        let s = sky(.clear, hour: 17.5)
        var st = run(s, seconds: 1, dt: 1, storm: StormInputs(supercell: .core))
        XCTAssertEqual(st.supercell, 1)
        XCTAssertEqual(st.supercellPhase, 0.5, accuracy: 1e-6)
        XCTAssertEqual(st.farStorm, 1)
        st = run(s, seconds: 30, dt: 1, storm: StormInputs(supercell: .core))
        XCTAssertEqual(st.supercellPhase, 0.5, accuracy: 1e-6, "and held there")
        // On to Clearing: forward, and there within 20 s (a third of a cycle at a cycle a minute).
        var phases: [Float] = []
        run(s, seconds: 30, dt: 0.5, storm: StormInputs(supercell: .clearing)) { st, _ in phases.append(st.supercellPhase) }
        for (a, b) in zip(phases, phases.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a, "forward only") }
        XCTAssertEqual(phases[39], Float(5.0 / 6), accuracy: 1e-6, "there at 20 s")
        XCTAssertEqual(phases.last ?? 0, Float(5.0 / 6), accuracy: 1e-6, "and held")
        // Back to Approach: forward through the end of the cycle (the next storm comes), never back through the core.
        phases = []
        run(s, seconds: 30, dt: 0.5, storm: StormInputs(supercell: .approach)) { st, _ in phases.append(st.supercellPhase) }
        for p in phases { XCTAssertTrue(p >= Float(5.0 / 6) - 1e-6 || p <= Float(1.0 / 6) + 1e-6, "\(p)") }
        XCTAssertTrue(phases.contains { $0 > 0.9 } && phases.contains { $0 < 0.1 }, "through the wrap")
        XCTAssertEqual(phases.last ?? 0, Float(1.0 / 6), accuracy: 1e-6)
        // The stage goes with the world: no supercell, no phase, no far storm.
        st = run(s, seconds: 1, dt: 1)
        XCTAssertEqual([st.supercell, st.supercellPhase, st.farStorm], [0, 0, 0])

        // Cycle: from the start of Approach, a pass every 8 minutes, Approach → Core → Clearing, and round again.
        let cycle = sky(.clear, hour: 17.5)
        var stages: [SupercellStage] = []
        var cyclePhases: [Float] = []
        run(cycle, seconds: 960, dt: 1, storm: StormInputs(supercell: .cycle)) { st, _ in
            cyclePhases.append(st.supercellPhase)
            let e = SupercellStage.event(at: st.supercellPhase)
            if stages.last != e { stages.append(e) }
        }
        XCTAssertEqual(stages, [.approach, .core, .clearing, .approach, .core, .clearing])
        XCTAssertEqual(cyclePhases[0], 0)
        XCTAssertEqual(cyclePhases[240], 0.5, accuracy: 1e-5, "half way at 4 minutes")
        let lap = abs(cyclePhases[480] - cyclePhases[0])
        XCTAssertLessThan(min(lap, 1 - lap), 1e-5, "round again after 8 minutes")
        XCTAssertTrue(cyclePhases.allSatisfy { $0 >= 0 && $0 < 1 })
        // The pure step: from anywhere, a held stage within a minute; Cycle at the event's pace.
        for from in stride(from: 0.0, to: 1, by: 0.05) {
            for stage in [SupercellStage.approach, .core, .clearing] {
                var p = from
                for _ in 0..<61 { p = WorldWeather.supercellStep(p, stage: stage, dt: 1) }
                XCTAssertEqual(p, try XCTUnwrap(WorldWeather.supercellPhase(held: stage)), accuracy: 1e-12, "\(from) → \(stage)")
            }
        }
        XCTAssertEqual(WorldWeather.supercellStep(0.5, stage: .cycle, dt: 48), 0.6, accuracy: 1e-9, "48 s is a tenth of a pass")
        XCTAssertEqual(WorldWeather.supercellStep(0.75, stage: .cycle, dt: 120), 0, accuracy: 1e-12, "and it loops")
    }

    // MARK: - Random Beautiful's tables (spec §3, §7)

    /// A gust front only where storms already appear (the lake, the beach, the coast road; and Neon Night Drive, Supercell
    /// Sky and Lightning Plains when they come), virga only in dry worlds (the coast road; Lightning Plains); neither in the
    /// shared table, so a world without a table picks exactly as before. Over thousands of spells: the road sees both, the
    /// lake only the gust front, the cabin neither, and Calm never a gust front.
    func testRandomBeautifulTables() {
        let storms: Set<String> = [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SupercellSkyModel.id]
        let dry: Set<String> = [CoastRoadModel.id]
        for (id, _) in ThemeRegistry.all {
            let extras = WorldWeather.randomExtras(for: id)
            XCTAssertEqual(extras[.gustFront] != nil, storms.contains(id), id)
            XCTAssertEqual(extras[.virga] != nil, dry.contains(id), id)
            XCTAssertTrue(Set(extras.keys).isSubset(of: [.gustFront, .virga]), id)
        }
        XCTAssertEqual(WorldWeather.randomExtras(for: "supercell-sky"), [.gustFront: 0.3])
        XCTAssertEqual(WorldWeather.randomExtras(for: "lightning-plains"), [.gustFront: 0.3, .virga: 0.5])
        XCTAssertEqual(WorldWeather.randomExtras(for: "neon-night-drive"), [.gustFront: 0.3])
        XCTAssertEqual(WorldWeather.randomExtras(for: "nowhere"), [:])
        XCTAssertEqual([WeatherKind.gustFront.beautyWeight, WeatherKind.virga.beautyWeight], [0, 0])

        func spells(_ extras: [WeatherKind: Float], calm: Bool = false) -> [WeatherKind: Int] {
            var s = SkySettings(); s.weatherMode = .randomBeautiful; s.spellMinutes = 2; s.randomBlendSeconds = 10; s.calmRandom = calm
            var m = WeatherMachine(settings: s, seed: 11)
            m.extras = extras
            var count: [WeatherKind: Int] = [:]
            var last = m.current
            for _ in 0..<20_000 {
                m.step(dt: 30, settings: s)
                if m.current != last { count[m.current, default: 0] += 1; last = m.current }
            }
            return count
        }
        let road = spells(WorldWeather.randomExtras(for: CoastRoadModel.id))
        XCTAssertGreaterThan(road[.gustFront] ?? 0, 20)
        XCTAssertGreaterThan(road[.virga] ?? 0, 30)
        let lake = spells(WorldWeather.randomExtras(for: MoonlitLakeModel.id))
        XCTAssertGreaterThan(lake[.gustFront] ?? 0, 20)
        XCTAssertNil(lake[.virga])
        let cabin = spells(WorldWeather.randomExtras(for: SnowboundCabinModel.id))
        XCTAssertNil(cabin[.gustFront])
        XCTAssertNil(cabin[.virga])
        XCTAssertEqual(cabin, spells([:]), "a world without a table picks as the shared sky always has")
        let calm = spells(WorldWeather.randomExtras(for: CoastRoadModel.id), calm: true)
        XCTAssertNil(calm[.gustFront], "a gust front is rough")
        XCTAssertGreaterThan(calm[.virga] ?? 0, 30)
        XCTAssertGreaterThan(road.values.reduce(0, +), 4000, "thousands of spells")
    }

    // MARK: - Old saves (Review focus 6)

    /// Settings saved before the Storms load the two Sky extras modes at Natural and the gust front at 180 s, keeping the
    /// rest; weather lists without the two new kinds load; the new kinds and modes decode by name; a mode from a later
    /// build or a typo falls back on its own, the length is clamped; and they survive a round trip.
    func testOldSettingsStillLoad() throws {
        func decode(_ json: String) throws -> SkySettings { try JSONDecoder().decode(SkySettings.self, from: Data(json.utf8)) }
        let old = try decode(#"{"weather":"seaSmoke","weatherMode":"pick","meteorRate":4,"randomExcluded":["rime","seaSmoke"]}"#)
        XCTAssertEqual([old.crawlersMode, old.sheetMode], [.natural, .natural])
        XCTAssertEqual(old.gustFrontSeconds, 180)
        XCTAssertEqual(old.weather, .seaSmoke)
        XCTAssertEqual(old.meteorRate, 4)
        XCTAssertEqual(old.randomExcluded, [.rime, .seaSmoke], "a list saved before the two kinds")
        XCTAssertEqual(try decode(#"{"weather":"gustFront","weatherMode":"pick"}"#).weather, .gustFront)
        XCTAssertEqual(try decode(#"{"weather":"virga"}"#).weather, .virga)
        XCTAssertEqual(try decode(#"{"randomExcluded":["gustFront","virga","hail"]}"#).randomExcluded, [.gustFront, .virga, .hail])
        XCTAssertEqual(try decode(#"{"weather":"tornado","cityID":"tokyo"}"#).weather, .clear, "a kind from a later build")
        let modes = try decode(#"{"crawlers.mode":"Often","sheet.mode":"Off","gustFrontSeconds":420}"#)
        XCTAssertEqual([modes.crawlersMode, modes.sheetMode], [.often, .off])
        XCTAssertEqual(modes.gustFrontSeconds, 420)
        let odd = try decode(#"{"crawlers.mode":"Sometimes","sheet.mode":7,"gustFrontSeconds":9999,"weather":"virga","meteorRate":3}"#)
        XCTAssertEqual([odd.crawlersMode, odd.sheetMode], [.natural, .natural])
        XCTAssertEqual(odd.gustFrontSeconds, 600, "clamped")
        XCTAssertEqual(odd.weather, .virga)
        XCTAssertEqual(odd.meteorRate, 3, "the rest kept")
        XCTAssertEqual(try decode(#"{"gustFrontSeconds":5}"#).gustFrontSeconds, 60)
        XCTAssertEqual(try decode(#"{"gustFrontSeconds":"long"}"#).gustFrontSeconds, 180)
        var s = SkySettings(); s.crawlersMode = .often; s.sheetMode = .off; s.gustFrontSeconds = 240; s.weather = .virga
        s.randomExcluded = [.gustFront]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: data), s)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""crawlers.mode":"Often""#), json)
        XCTAssertTrue(json.contains(#""sheet.mode":"Off""#), json)
        // An old save's sky runs the crawlers on Natural: under thunderheads, the first within 60–120 s.
        var heads = old; heads.timeMode = .frozen; heads.frozenHour = 13; heads.cityID = "melbourne"; heads.weather = .thunderheads
        let sky = LivingSky(settings: heads, seed: 1, homeZone: zone)
        run(sky, seconds: 130, dt: 1)
        XCTAssertEqual(sky.crawlerSky.births.count, 1)
        XCTAssertTrue((60...120).contains(sky.crawlerSky.births.first ?? 0))
    }

    /// A world as Supercell Sky and Lightning Plains will be, with `distance`, the two Sky extras modes and the stage
    /// picker: a state saved before them decodes, every new one reads its default and the rest is kept; values from a
    /// later build or typos fall back; through the director the world's own modes and stage reach the sky. Worlds saved
    /// without them (the lake) read no choice and follow the settings.
    func testOldWorldParametersStillLoad() throws {
        let saved = #"{"values":{"visual":{"choice":{"_0":"Galaxy Warp"}},"glitter":{"number":{"_0":0.9}}},"macros":{"glow":0.25}}"#
        let state = try JSONDecoder().decode(ThemeState.self, from: Data(saved.utf8))
        let params = ParameterSet(specs: StormProbe.parameters, saved: state.values, macros: state.macros)
        assertValidParameters(StormProbe.parameters)
        XCTAssertNil(state.values["distance"])
        XCTAssertEqual(params.number("distance"), 0.3, accuracy: 1e-12)
        XCTAssertEqual(params.choice(SkyExtraMode.crawlersID), "Often")
        XCTAssertEqual(params.choice(SkyExtraMode.sheetID), "Natural")
        XCTAssertEqual(params.choice(SupercellStage.id), "Cycle")
        XCTAssertEqual(params.macros[.glow], 0.25, "the rest is kept")
        let later = ParameterSet(specs: StormProbe.parameters,
                                 saved: ["crawlers.mode": .choice("Sometimes"), "supercell.stage": .choice("Tornado"),
                                         "distance": .number(7), "sheet.mode": .number(2)])
        XCTAssertEqual(later.choice(SkyExtraMode.crawlersID), "Often")
        XCTAssertEqual(later.choice(SkyExtraMode.sheetID), "Natural")
        XCTAssertEqual(later.choice(SupercellStage.id), "Cycle")
        XCTAssertEqual(later.number("distance"), 1, "clamped")

        // Through the director: the world's Often beats the settings' Off, and its supercell cycles.
        let d = SceneDirector(entry: ThemeEntry.make(StormProbe.self), state: state, reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick
        s.weather = .thunderheads; s.crawlersMode = .off
        d.sky.reset(settings: s)
        d.clock = { [start] in start }
        for i in 1...300 { _ = d.step(dt: 1, t: Double(i), quality: .high) }
        XCTAssertGreaterThan(d.sky.crawlerSky.spawned, 0)
        XCTAssertEqual(d.lastSky?.supercell, 1)
        XCTAssertEqual(Double(d.lastSky?.supercellPhase ?? 0), 299.0 / 480, accuracy: 1e-5, "cycling from the start")
        // The lake, saved before them all, has none of them and follows the settings.
        let lake = ThemeRegistry.parameterSet(for: MoonlitLakeModel.id, state: state)
        for id in [SkyExtraMode.crawlersID, SkyExtraMode.sheetID, SupercellStage.id, "distance"] {
            XCTAssertEqual(lake.choice(id), "", id)
        }
    }

    /// A storm world probe: the hero dial `distance`, its own crawlers (Often) and sheet lightning (Natural), and the
    /// supercell's stage (Cycle).
    struct StormProbe: ThemeModel, SkyAware {
        static let id = "storm-probe", displayName = "Storm probe"
        static let parameters: [ParamSpec] = [
            ParamSpec(id: "distance", name: "Distance", group: "Storm", help: "How far away the storm is", kind: .slider(0...1),
                      defaultValue: .number(0.3), hero: true),
            SkyExtraMode.spec(id: SkyExtraMode.crawlersID, name: "Anvil crawlers", help: "Spider lightning under the anvil",
                              default: .often),
            SkyExtraMode.spec(id: SkyExtraMode.sheetID, name: "Sheet lightning", help: "Heat lightning on the rim", default: .natural),
            SupercellStage.spec(default: .cycle),
        ]
        static let macroTargets: [Macro: [(id: String, weight: Double)]] = [:]
        var sky: SkyState?
        init() {}
        mutating func handle(_ e: PerformanceEvent) {}
        mutating func setSky(_ s: SkyState) { sky = s }
        mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SkyState? { sky }
    }

    // MARK: - The flash budget (Review focus 5, the Core half)

    /// The worst case: Excitement's moments on Lots (a hard chord every quarter second: a moment every 2.5 s, each calling a
    /// crawler and a sheet flash), crawlers and sheet lightning on Often, a supercell held at its Core, at night, every
    /// crawler at full brightness, 60 s at 60 fps. The sky's flash limiter never counts more than 3 flashes in any second,
    /// the scene's exposure (checked on its own) never jumps by more than the limit more than 3 times a second, and
    /// nothing is red (the crawlers are blue-white, the sheet warm-white at most 0.2), so no red flash covers anything.
    func testWorstCaseFlashBudget() {
        var excitement = Excitement()
        excitement.settings.moments = .lots
        let s = sky(.thunderheads, hour: 23) { $0.crawlersMode = .often; $0.sheetMode = .often }
        s.crawlerSky.forcePeak = AnvilCrawlers.brightest
        let dt = 1.0 / 60
        var exposure: [Float] = []
        var moments = 0, calledCrawlers = 0, calledSheets = 0, maxRecent = 0
        var red = false
        for i in 1...3600 {
            if i % 15 == 1 {   // a hard low chord every quarter second
                for note in [36, 40, 43] { excitement.noteOn(note, velocity: 1) }
                for note in [36, 40, 43] { excitement.noteOff(note) }
            }
            let frame = excitement.step(dt: dt)
            if frame.moment != nil { moments += 1 }
            let st = s.step(now: start.addingTimeInterval(Double(i) * dt), dt: dt,
                            storm: StormInputs(supercell: .core, moment: frame.moment))
            maxRecent = max(maxRecent, s.flashLimiter.recent)
            exposure.append(1 + st.stormFlash + st.meteorFlash)
            XCTAssertEqual(SupercellStage.event(at: st.supercellPhase), .core)
            for c in st.crawlers {
                red = red || isSaturatedRed(c.colour)
                XCTAssertLessThanOrEqual(c.brightness, AnvilCrawlers.brightest)
                if c.called && c.progress == 0 { calledCrawlers += 1 }
            }
            for f in st.sheet {
                red = red || isSaturatedRed(f.colour)
                XCTAssertLessThanOrEqual(f.brightness, SheetLightning.brightest)
                if f.called && Double(i) * dt - f.born < 0.01 { calledSheets += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(moments, 20, "Lots: a moment every 2.5 s")
        XCTAssertGreaterThan(calledCrawlers, 10)
        XCTAssertGreaterThan(calledSheets, 10)
        XCTAssertGreaterThan(s.flashLimiter.total, 10, "a busy minute")
        XCTAssertLessThanOrEqual(maxRecent, FlashLimiter.maxFlashesPerSecond)
        // The limiter's rules on the exposure the storm light causes, checked on their own.
        let window = Int((FlashLimiter.window / dt).rounded())
        var flashTimes: [Double] = []
        var tooMany = false
        for i in exposure.indices {
            let t = Double(i) * dt
            let lowest = exposure[max(0, i - window)...i].min() ?? 1
            if exposure[i] - lowest > FlashLimiter.flashRise, flashTimes.last.map({ t - $0 > FlashLimiter.window }) ?? true {
                flashTimes.append(t)
            }
            if flashTimes.filter({ t - $0 < 1 }).count > FlashLimiter.maxFlashesPerSecond { tooMany = true }
        }
        XCTAssertFalse(tooMany, "at most \(FlashLimiter.maxFlashesPerSecond) large jumps a second")
        XCTAssertGreaterThan(flashTimes.count, 10)
        XCTAssertFalse(red, "no red flash at all, let alone over 20% of the screen")
        XCTAssertFalse(isSaturatedRed(AnvilCrawlers.colour))
    }
}
