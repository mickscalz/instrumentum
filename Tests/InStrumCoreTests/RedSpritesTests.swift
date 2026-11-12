import XCTest
import simd
@testable import InStrumCore

/// Fire & Neon Task 8 (spec §6.1, §13, §14; Review focus 4): red sprites over storms and far storms, their timing, their
/// brightness under the cap, the flash test, the far storms' rate and length, and old saves.
final class RedSpritesTests: XCTestCase {
    private let zone = TimeZone(identifier: "Australia/Melbourne")!
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private let fullMoment = BigMoment(kind: .chord, strength: 1, low: false, isDrop: false)

    /// A frozen sky over Melbourne at `hour` (23:00 is deep night, 13:00 day), the weather picked and settled.
    private func sky(_ kind: WeatherKind, hour: Double = 23, seed: UInt64 = 1,
                     _ edit: (inout SkySettings) -> Void = { _ in }) -> LivingSky {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = kind
        s.crawlersMode = .off; s.sheetMode = .off; s.satellitesMode = .off
        edit(&s)
        let sky = LivingSky(settings: s, seed: seed, homeZone: zone)
        sky.reset(settings: s)
        return sky
    }

    @discardableResult
    private func run(_ sky: LivingSky, seconds: Double, dt: Double, hold: SkyHold = .follow, storm: StormInputs = StormInputs(),
                     each: (SkyState, Double, Int) -> Void = { _, _, _ in }) -> SkyState {
        var st = SkyState()
        let n = max(1, Int((seconds / dt).rounded()))
        for i in 1...n {
            let t = Double(i) * dt
            st = sky.step(now: start.addingTimeInterval(t), dt: dt, hold: hold, meteors: .never, storm: storm)
            each(st, t, i)
        }
        return st
    }

    private func isSaturatedRed(_ c: SIMD3<Float>) -> Bool {
        let sum = c.x + c.y + c.z
        return sum > 0 && c.x / sum >= 0.8
    }

    // MARK: - When (spec §6.1)

    /// Only at night (the sun below −12°) over a storm: this sky's storm, thunderheads or dry lightning, or a far storm
    /// (a world's, or the sky's own); never by day or at dusk, never under a plain cloudy or clear sky, never on Off.
    func testSpritesOnlyAtNightOverStorms() {
        func sprites(_ kind: WeatherKind, hour: Double = 23, hold: SkyHold = .follow, storm: StormInputs = StormInputs(),
                     mode: SkyExtraMode = .often) -> Int {
            let s = sky(kind, hour: hour) { $0.spritesMode = mode }
            var lit = 0
            run(s, seconds: 300, dt: 0.25, hold: hold, storm: storm) { st, _, _ in lit += st.sprites.count }
            XCTAssertEqual(lit > 0, s.spriteSky.spawned > 0, "\(kind): every sprite made shows")
            return s.spriteSky.spawned
        }
        XCTAssertGreaterThan(sprites(.thunderheads), 8)
        XCTAssertGreaterThan(sprites(.storm), 8)
        XCTAssertGreaterThan(sprites(.dryLightning), 8)
        XCTAssertGreaterThan(sprites(.clear, storm: StormInputs(farStorm: 1)), 8, "a far storm on a clear night")
        XCTAssertGreaterThan(sprites(.clear, storm: StormInputs(supercell: .core)), 8, "a supercell is a far storm")
        XCTAssertEqual(sprites(.clear), 0, "no storm anywhere (the sky's own far storm waits hours)")
        XCTAssertEqual(sprites(.overcast), 0)
        XCTAssertEqual(sprites(.rain), 0)
        XCTAssertEqual(sprites(.thunderheads, hour: 13), 0, "not by day")
        XCTAssertEqual(sprites(.thunderheads, hold: .blueHour), 0, "not at dusk (the sun 6° down)")
        XCTAssertEqual(sprites(.clear, hour: 13, storm: StormInputs(farStorm: 1)), 0)
        XCTAssertEqual(sprites(.thunderheads, mode: .off), 0, "Off")
        let called = sky(.thunderheads) { $0.spritesMode = .off }
        run(called, seconds: 30, dt: 0.5, storm: StormInputs(moment: fullMoment))
        XCTAssertEqual(called.spriteSky.spawned, 0, "Off, even called")
        // A big moment calls one at once (at most one a second); Natural keeps to its 20–60 s gaps.
        let natural = sky(.thunderheads) { $0.spritesMode = .natural }
        var first: Double?
        run(natural, seconds: 2, dt: 1.0 / 60, storm: StormInputs(moment: fullMoment)) { st, t, _ in
            if first == nil, !st.sprites.isEmpty { first = t }
        }
        XCTAssertNotNil(first)
        XCTAssertLessThan(first ?? 9, 0.05)
        XCTAssertEqual(natural.spriteSky.spawned, 2, "one a second when called every step")
        var machine = RedSprites(seed: 7)
        var births: [Double] = []
        for _ in 0..<36_000 { _ = machine.step(dt: 0.1, mode: .natural, eligible: true, bearing: 120) }
        births = machine.births
        XCTAssertGreaterThan(births.count, 50)
        for (a, b) in zip(births, births.dropFirst()) { XCTAssertTrue((20 - 1e-6...60 + 1e-6).contains(b - a), "\(b - a)") }
    }

    /// Each sprite: lit 80–160 ms then gone within 60 ms more, 1–3 columns, its tendrils' ends 4–9° up, 2–4° tall, within
    /// 6° of its storm's bearing, its brightness 0.015–0.04 at most; the same seed lights the same sprites at any step.
    func testSpriteTimingShapeAndBrightness() {
        var machine = RedSprites(seed: 3)
        let dt = 1.0 / 1000
        var lit: [Int: Double] = [:]          // birth (ms) → time at level ≥ 0.5
        var seen = 0
        for _ in 0..<600_000 {
            let slots = machine.step(dt: dt, mode: .often, eligible: true, bearing: 200)
            for p in slots {
                XCTAssertLessThanOrEqual(p.brightness, RedSprites.brightest)
                XCTAssertTrue((RedSprites.dimmest - 1e-6...RedSprites.brightest + 1e-6).contains(p.peak))
                XCTAssertTrue((1...3).contains(p.columns))
                XCTAssertTrue((4 - 1e-4...9 + 1e-4).contains(Double(p.base)))
                XCTAssertTrue((2 - 1e-4...4 + 1e-4).contains(Double(p.height)))
                var gap = abs(Double(p.azimuth) - 200).truncatingRemainder(dividingBy: 360)
                gap = min(gap, 360 - gap)
                XCTAssertLessThanOrEqual(gap, RedSprites.stray + 1e-3)
                XCTAssertTrue((0.08 - 1e-6...0.16 + 1e-6).contains(Double(p.lit)))
                XCTAssertLessThanOrEqual(machine.time - p.born, Double(p.lit) + RedSprites.fadeSeconds + dt)
                if p.level >= 0.5 { lit[Int((p.born * 1000).rounded()), default: 0] += dt }
                seen += 1
            }
        }
        XCTAssertGreaterThan(lit.count, 25)
        for (_, l) in lit { XCTAssertTrue((0.08 - 0.003...0.16 + 0.03).contains(l), "lit \(l) s") }
        XCTAssertEqual(RedSprites.level(age: 0.1, lit: 0.1), 1, accuracy: 1e-6)
        XCTAssertEqual(RedSprites.level(age: 0.1 + RedSprites.fadeSeconds, lit: 0.1), 0, accuracy: 1e-6)
        XCTAssertEqual(RedSprites.level(age: -0.01, lit: 0.1), 0)
        // Seeded and step-free: the same seed at 1/60 s makes the same births.
        var a = RedSprites(seed: 3), b = RedSprites(seed: 3)
        for _ in 0..<6000 { _ = a.step(dt: 0.05, mode: .often, eligible: true) }
        for _ in 0..<300 { _ = b.step(dt: 1, mode: .often, eligible: true) }
        XCTAssertEqual(a.births.count, b.births.count)
        for (x, y) in zip(a.births, b.births) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        var c = RedSprites(seed: 4)
        for _ in 0..<300 { _ = c.step(dt: 1, mode: .often, eligible: true) }
        XCTAssertNotEqual(c.births.first ?? 0, a.births.first ?? 0, "another seed, other sprites")
        // Through the sky: under the cap after its limiter.
        let s = sky(.thunderheads) { $0.spritesMode = .often }
        run(s, seconds: 120, dt: 1.0 / 60) { st, _, _ in
            for p in st.sprites { XCTAssertLessThanOrEqual(p.brightness, RedSprites.brightest) }
        }
        XCTAssertGreaterThan(s.spriteSky.spawned, 3)
    }

    /// The flash test (spec §13): a clear night under a far storm with sprites on Often and a big moment calling one every
    /// half second, at 60 fps for two minutes: the sky's limiter never counts a flash (sprites and the storm's flicker are
    /// far under its rise), its exposure never jumps by more than the limit more than three times a second, and nothing
    /// is saturated red (the crown is salmon-red, 65% of its light; the tendrils blue-violet).
    func testSpritesPassTheFlashTest() {
        let s = sky(.clear) { $0.spritesMode = .often }
        s.farStorms.forceStart = true
        let dt = 1.0 / 60
        var exposure: [Float] = []
        var sprites = 0
        var flicker: Float = 0
        run(s, seconds: 120, dt: dt, storm: StormInputs(moment: fullMoment)) { st, _, i in
            let lights = st.sprites.reduce(Float(0)) { max($0, $1.brightness) }
            exposure.append(1 + lights + (st.farStormNow?.flicker ?? 0) * FarStormNow.flickerLight)
            sprites += st.sprites.count
            flicker = max(flicker, st.farStormNow?.flicker ?? 0)
            for p in st.sprites { XCTAssertLessThanOrEqual(p.brightness, RedSprites.brightest) }
        }
        XCTAssertGreaterThan(sprites, 100)
        XCTAssertGreaterThan(flicker, 0.3, "the far storm flickers")
        XCTAssertEqual(s.flashLimiter.total, 0, "never a flash")
        let window = Int((FlashLimiter.window / dt).rounded())
        var jumps = 0
        for i in exposure.indices where exposure[i] - (exposure[max(0, i - window)...i].min() ?? 1) > FlashLimiter.flashRise { jumps += 1 }
        XCTAssertEqual(jumps, 0)
        XCTAssertFalse(isSaturatedRed(SpriteSlot.crown))
        XCTAssertFalse(isSaturatedRed(SpriteSlot.tendril))
        XCTAssertLessThan(RedSprites.brightest + FarStormNow.flickerLight, FlashLimiter.flashRise)
    }

    // MARK: - Far storms (spec §6.1)

    /// On Natural, a far storm comes every 2–4 hours of clear-night viewing (the clock stopping while one stands, and the
    /// first waiting a whole gap), each lasting 5–20 minutes; Often three times as often; none while the night isn't clear
    /// (and a standing one goes); seeded.
    func testFarStormsRateAndLength() {
        func runStorms(seed: UInt64, mode: SkyExtraMode, hours: Double, eligible: (Double) -> Bool = { _ in true })
            -> (starts: [Double], lengths: [Double], machine: FarStorms) {
            var m = FarStorms(seed: seed)
            var starts: [Double] = [], lengths: [Double] = []
            var since: Double?
            let dt = 2.0
            for i in 1...Int(hours * 3600 / dt) {
                let t = Double(i) * dt
                let now = m.step(dt: dt, mode: mode, eligible: eligible(t))
                if let f = now {
                    XCTAssertTrue((0...1).contains(f.amount))
                    XCTAssertTrue((0...1).contains(f.flicker))
                    XCTAssertTrue((Float(FarStorms.distances.lowerBound) - 1e-3...Float(FarStorms.distances.upperBound) + 1e-3)
                        .contains(f.distanceKm))
                    XCTAssertTrue((1.0...4.0).contains(Double(f.top)), "the anvil's top \(f.top)° up")
                    if since == nil { since = t; starts.append(t) }
                } else if let s0 = since {
                    lengths.append(t - s0)
                    since = nil
                }
            }
            return (starts, lengths, m)
        }
        let natural = runStorms(seed: 1, mode: .natural, hours: 400)
        XCTAssertGreaterThanOrEqual(natural.starts.first ?? 0, 7200, "the first waits a whole gap")
        XCTAssertGreaterThan(natural.starts.count, 90)
        XCTAssertLessThan(natural.starts.count, 200)
        for l in natural.lengths { XCTAssertTrue((300 - 4...1200 + 4).contains(l), "a storm of \(l) s") }
        var ends = zip(natural.starts, natural.lengths).map { $0 + $1 }
        for (end, next) in zip(ends, natural.starts.dropFirst()) {
            XCTAssertTrue((7200 - 4...14_400 + 4).contains(next - end), "a gap of \((next - end) / 3600) h")
        }
        let often = runStorms(seed: 1, mode: .often, hours: 100)
        ends = zip(often.starts, often.lengths).map { $0 + $1 }
        for (end, next) in zip(ends, often.starts.dropFirst()) { XCTAssertTrue((2400 - 4...4800 + 4).contains(next - end)) }
        XCTAssertGreaterThan(often.starts.count, 50)
        XCTAssertEqual(runStorms(seed: 1, mode: .natural, hours: 50, eligible: { _ in false }).starts.count, 0)
        XCTAssertEqual(runStorms(seed: 1, mode: .off, hours: 50).starts.count, 0)
        // Seeded.
        XCTAssertEqual(runStorms(seed: 1, mode: .natural, hours: 30).starts, Array(natural.starts.prefix { $0 <= 30 * 3600 }))
        XCTAssertNotEqual(runStorms(seed: 2, mode: .natural, hours: 30).starts, runStorms(seed: 1, mode: .natural, hours: 30).starts)
        // A standing storm goes (over its minute) when the night clouds over.
        let cut = runStorms(seed: 5, mode: .often, hours: 4) { t in t < 5000 || t > 9000 }
        for (s0, l) in zip(cut.starts, cut.lengths) where s0 < 5000 && s0 + l > 5000 { XCTAssertLessThanOrEqual(s0 + l, 5000 + 62) }
        // Its flicker comes in bursts every 1.5–7 s.
        var m = FarStorms(seed: 9)
        m.forceStart = true
        var lastBurst = -1.0, gaps: [Double] = []
        var wasLit = false
        for i in 1...60_000 {
            let f = m.step(dt: 0.01, mode: .natural, eligible: true)
            let lit = (f?.flicker ?? 0) > 0.05
            if lit && !wasLit {
                let t = Double(i) * 0.01
                if lastBurst >= 0, t - lastBurst > 0.6 { gaps.append(t - lastBurst) }
                lastBurst = t
            }
            wasLit = lit
        }
        XCTAssertGreaterThan(gaps.count, 40)
        XCTAssertTrue(gaps.allSatisfy { $0 <= 7.6 }, "\(gaps.max() ?? 0)")
    }

    /// In the sky: a clear night's far storm stands on the horizon at its bearing, is a far storm (the sprites stand over it,
    /// and sheet lightning reads it), carries its episode for staging, and is the sky's alone: not where the world has a far
    /// storm of its own or a supercell, not under cloud.
    func testFarStormInTheSky() {
        let s = sky(.clear) { $0.spritesMode = .natural }
        s.farStorms.forceStart = true
        var st = run(s, seconds: 150, dt: 1)
        let f = st.farStormNow
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.amount ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(st.farStorm, 1, accuracy: 1e-6)
        XCTAssertEqual(st.stormBearing, f?.bearing ?? -1)
        XCTAssertEqual(st.stormEpisode, f?.episode ?? -1)
        XCTAssertGreaterThan(s.spriteSky.spawned, 0, "sprites over it within 90 s of its standing, on Natural")
        st = run(s, seconds: 120, dt: 1)
        for p in st.sprites {
            var gap = abs(Double(p.azimuth - (f?.bearing ?? 0))).truncatingRemainder(dividingBy: 360)
            gap = min(gap, 360 - gap)
            XCTAssertLessThanOrEqual(gap, RedSprites.stray + 1e-3)
        }
        // Not the sky's when the world already has one, nor under cloud.
        let world = sky(.clear)
        world.farStorms.forceStart = true
        st = run(world, seconds: 10, dt: 1, storm: StormInputs(farStorm: 1))
        XCTAssertNil(st.farStormNow)
        let cloudy = sky(.overcast)
        cloudy.farStorms.forceStart = true
        st = run(cloudy, seconds: 10, dt: 1)
        XCTAssertNil(st.farStormNow)
        let day = sky(.clear, hour: 13)
        day.farStorms.forceStart = true
        XCTAssertNil(run(day, seconds: 10, dt: 1).farStormNow)
        // The lounge (space) and the worlds that draw their own storms drop it.
        var raw = st
        raw.farStormNow = FarStormNow(bearing: 10, distanceKm: 250, top: 2, width: 20, amount: 1, episode: 1)
        raw.sprites = [SpriteSlot(azimuth: 10, base: 5, height: 3, columns: 2, spread: 1, shape: 0.5, streamers: 0, seed: 0.3,
                                  born: 0, lit: 0.1, peak: 0.03, level: 1, brightness: 0.03)]
        let space = SpaceshipLoungeModel.weatherless(raw)
        XCTAssertNil(space.farStormNow)
        XCTAssertTrue(space.sprites.isEmpty)
    }

    // MARK: - Old saves (Review focus 4)

    /// Settings saved before the red sprites and the satellites load both at Natural and the Supercell at 8 minutes; the
    /// modes decode by name, a later or mistyped one falls back on its own, the length is clamped, they round-trip, and
    /// the looks and Reset set them.
    func testOldSavesLoadTheModesAsNatural() throws {
        func decode(_ json: String) throws -> SkySettings { try JSONDecoder().decode(SkySettings.self, from: Data(json.utf8)) }
        let old = try decode(#"{"weather":"virga","weatherMode":"pick","crawlers.mode":"Often","meteorRate":3}"#)
        XCTAssertEqual([old.spritesMode, old.satellitesMode], [.natural, .natural])
        XCTAssertEqual(old.supercellSeconds, 480)
        XCTAssertEqual(old.crawlersMode, .often, "the rest kept")
        XCTAssertEqual(old.meteorRate, 3)
        let modes = try decode(#"{"sprites.mode":"Often","satellites.mode":"Off","supercellSeconds":900}"#)
        XCTAssertEqual([modes.spritesMode, modes.satellitesMode], [.often, .off])
        XCTAssertEqual(modes.supercellSeconds, 900)
        let odd = try decode(#"{"sprites.mode":"Sometimes","satellites.mode":3,"supercellSeconds":5}"#)
        XCTAssertEqual([odd.spritesMode, odd.satellitesMode], [.natural, .natural])
        XCTAssertEqual(odd.supercellSeconds, 180, "clamped")
        XCTAssertEqual(try decode(#"{"supercellSeconds":99999}"#).supercellSeconds, 1200)
        var s = SkySettings(); s.spritesMode = .off; s.satellitesMode = .often; s.supercellSeconds = 600
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SkySettings.self, from: data), s)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""sprites.mode":"Off""#), json)
        XCTAssertTrue(json.contains(#""satellites.mode":"Often""#), json)
        XCTAssertEqual([SkyExtraMode.spritesID, SkyExtraMode.satellitesID], ["sprites.mode", "satellites.mode"])
        let looks: [(SkySettings.AdvancedPreset, SkyExtraMode, SkyExtraMode)] =
            [(.gentle, .natural, .natural), (.dramatic, .often, .often), (.dreamy, .natural, .often)]
        for (look, sprites, satellites) in looks {
            var t = SkySettings(); t.spritesMode = .off; t.satellitesMode = .off
            t.applyAdvanced(look)
            XCTAssertEqual([t.spritesMode, t.satellitesMode], [sprites, satellites], "\(look)")
            XCTAssertTrue((180...1200).contains(t.supercellSeconds))
            t.resetAdvanced()
            XCTAssertEqual([t.spritesMode, t.satellitesMode], [.natural, .natural])
            XCTAssertEqual(t.supercellSeconds, 480)
        }
        // An old save's sky runs them at Natural: sprites over thunderheads at night within a minute or so.
        var heads = old; heads.timeMode = .frozen; heads.frozenHour = 23; heads.cityID = "melbourne"; heads.weather = .thunderheads
        let night = LivingSky(settings: heads, seed: 1, homeZone: zone)
        run(night, seconds: 180, dt: 1)
        XCTAssertGreaterThan(night.spriteSky.spawned, 1)
    }
}
