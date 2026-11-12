import XCTest
import simd
@testable import InStrumCore

/// Neon Night Drive and its visual, Light Trails, and the windscreen's wipers (Fire & Neon spec §9; plan Task 13). Every
/// bound is the spec's: the speed law 0.25 + 0.55·Energy and the tempo's share, the neon easing to the chord over 0.4 s, a
/// sign for each note, the studs on the arp's steps, tension's tunnel with its lights passing at most 3 a second, the
/// Drop onto the bridge, the five surprises, the wipers' rate following the rain, and a ring of 128 streaks.
final class NeonNightDriveTests: XCTestCase {
    // MARK: - Helpers

    /// Deep night over Melbourne.
    private func night() -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 200, altitude: -35)
        s.moon = SkyDirection(azimuth: 80, altitude: -10)
        s.hourOfDay = 23
        s.dayOfYear = 320
        s.latitude = -37.8
        s.zenith = SIMD3(0.01, 0.014, 0.035)
        s.horizon = SIMD3(0.02, 0.028, 0.06)
        return s
    }

    /// Wired, the set's mood (spec §10).
    private let wired = Mood(energy: 0.9, warmth: 0.3, brightness: 0.8, space: 0.55, motion: 0.95)

    private func params(_ values: [String: ParamValue] = [:]) -> ParameterSet {
        ThemeRegistry.parameterSet(for: NeonNightDriveModel.id, state: ThemeState(values: values))
    }

    private func model() -> NeonNightDriveModel {
        var m = NeonNightDriveModel()
        m.mood = wired
        m.setSky(night())
        return m
    }

    private func excitement(energy: Float = 0, tension: Float = 0, drop: Float = 0, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = energy
        e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
        e.tension = tension
        e.drop = drop
        e.reduceMotion = reduceMotion
        return e
    }

    private func moment(_ strength: Float, energy: Float = 0.5, drop: Bool = false) -> ExcitementFrame {
        var e = excitement(energy: energy, drop: drop ? 1 : 0)
        e.moment = BigMoment(kind: .chord, strength: strength, low: false, isDrop: drop)
        return e
    }

    /// Steps `m` for `seconds` at 60 fps and returns the last frame; `each` sees every frame.
    @discardableResult
    private func run(_ m: inout NeonNightDriveModel, seconds: Double, _ values: [String: ParamValue] = [:],
                     each: ((Int, DriveFrame) -> Void)? = nil) -> DriveFrame {
        let p = params(values)
        let n = max(1, Int((seconds * 60).rounded()))
        var frame: DriveFrame?
        for i in 0..<n {
            let f = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            each?(i, f)
            frame = f
        }
        return frame!
    }

    // MARK: - The world

    func testDriveDefaults() throws {
        XCTAssertEqual(NeonNightDriveModel.id, "neon-night-drive")
        XCTAssertEqual(NeonNightDriveModel.displayName, "Neon Night Drive")
        XCTAssertEqual(ThemeRegistry.resolve(NeonNightDriveModel.id), NeonNightDriveModel.id)
        let listed = ThemeRegistry.all.contains { $0.id == NeonNightDriveModel.id && $0.name == "Neon Night Drive" }
        XCTAssertTrue(listed)
        XCTAssertTrue(ThemeRegistry.isWorld(NeonNightDriveModel.id))
        let ids = ThemeRegistry.all.map(\.id)
        let driveAt = try XCTUnwrap(ids.firstIndex(of: NeonNightDriveModel.id))
        let plainsAt = try XCTUnwrap(ids.firstIndex(of: LightningPlainsModel.id))
        XCTAssertGreaterThan(driveAt, plainsAt, "after the storms")
        assertValidParameters(NeonNightDriveModel.parameters)
        let specIDs = NeonNightDriveModel.parameters.map(\.id)
        XCTAssertEqual(specIDs, ["visual", "light.hold", "meteors.mode", "neon", "rain", "traffic", "trails", "keys.show"])
        XCTAssertEqual(NeonNightDriveModel.visuals, ["Light Trails", "Galaxy Warp"])
        XCTAssertEqual(NeonNightDriveModel.surpriseCount, 5)
        let p = params()
        XCTAssertEqual(p.choice("visual"), "Light Trails")
        XCTAssertEqual(p.choice("light.hold"), SkyHold.deepNight.rawValue, "deep night by default (spec §2)")
        XCTAssertEqual(p.number("rain"), 0.45, accuracy: 1e-9)
        XCTAssertEqual(p.number("neon"), 0.7, accuracy: 1e-9)
        // Random Beautiful may bring a gust front here, as where storms already appear.
        XCTAssertEqual(WorldWeather.randomExtras(for: NeonNightDriveModel.id), [.gustFront: 0.3])
    }

    func testTheDirectorDrivesIt() throws {
        // The director hands the world the instrument's pulse (Chrome Bass's arp at 140), so it flies even at rest.
        let d = SceneDirector(themeID: NeonNightDriveModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.instrumentPulse = InstrumentPulse(bpm: 140, gate: 0.55)
        var last: DriveFrame?
        for i in 1...1200 {
            last = d.step(dt: 1.0 / 60, t: Double(i) / 60, quality: .high) as? DriveFrame
        }
        let f = try XCTUnwrap(last)
        XCTAssertEqual(f.speed, 0.45, accuracy: 0.02, "cruise 0.25 and the tempo's 0.2")
        XCTAssertGreaterThan(f.kmh, 70)
    }

    // MARK: - Speed (spec §9.1)

    func testSpeedFollowsEnergy() {
        for e: Float in [0, 0.5, 1] {
            var m = model()
            m.setExcitement(excitement(energy: e))
            let f = run(&m, seconds: 20)
            let want: Float = 0.25 + 0.55 * e
            XCTAssertEqual(f.speed, want, accuracy: 0.01, "energy \(e)")
        }
        let law = NeonNightDriveModel.targetSpeed(energy: 0.4, pulse: nil)
        XCTAssertEqual(law, 0.47, accuracy: 1e-5)
        // Faster is further and quicker: 50 km/h at 0, 130 at 1.
        XCTAssertEqual(NeonNightDriveModel.metresPerSecond(0) * 3.6, 50, accuracy: 1e-3)
        XCTAssertEqual(NeonNightDriveModel.metresPerSecond(1) * 3.6, 130, accuracy: 1e-3)
        // Reduce Motion caps Energy's look at 0.5.
        var r = model()
        r.setExcitement(excitement(energy: 1, reduceMotion: true))
        let rf = run(&r, seconds: 20)
        XCTAssertEqual(rf.speed, 0.525, accuracy: 0.01)
        XCTAssertEqual(rf.yaw, 0, "no sway under Reduce Motion")
        XCTAssertEqual(rf.roll, 0)
        // It rises quickly and settles slowly.
        var up = model()
        up.setExcitement(excitement(energy: 1))
        let risen = run(&up, seconds: 1.5)
        XCTAssertGreaterThan(risen.speed, 0.7)
        up.setExcitement(excitement(energy: 0))
        let settling = run(&up, seconds: 1.5)
        XCTAssertGreaterThan(settling.speed, 0.4)
    }

    func testSpeedFollowsThePulse() {
        let fast = InstrumentPulse(bpm: 140, gate: 0.55)
        let slow = InstrumentPulse(bpm: 90, gate: 0.55)
        let fastBoost = NeonNightDriveModel.tempoBoost(fast)
        let slowBoost = NeonNightDriveModel.tempoBoost(slow)
        let noBoost = NeonNightDriveModel.tempoBoost(nil)
        XCTAssertEqual(fastBoost, 0.2, accuracy: 1e-5)
        XCTAssertEqual(slowBoost, 0, accuracy: 1e-5)
        XCTAssertEqual(noBoost, 0)
        var m = model()
        m.pulse = fast
        m.setExcitement(excitement(energy: 0.5))
        let f = run(&m, seconds: 20)
        XCTAssertEqual(f.speed, 0.725, accuracy: 0.01, "0.25 + 0.55 × 0.5 + 0.2")
        // Full Energy at 140 BPM: flying, but never past 1 without a moment.
        let top = NeonNightDriveModel.targetSpeed(energy: 1, pulse: fast)
        XCTAssertEqual(top, 1, accuracy: 1e-6)
    }

    // MARK: - The neon (spec §9.1)

    func testNeonEasesToTheChord() {
        var m = model()
        for n: UInt8 in [60, 64, 67] { m.handle(.noteOn(note: n, velocity: 0.7)) }
        let warm = run(&m, seconds: 1)
        XCTAssertGreaterThan(warm.neonWarmth, 0.98, "C major: warm")
        for n: UInt8 in [60, 64, 67] { m.handle(.noteOff(note: n)) }
        for n: UInt8 in [57, 60, 64] { m.handle(.noteOn(note: n, velocity: 0.7)) }
        let early = run(&m, seconds: 0.1)
        XCTAssertGreaterThan(early.neonWarmth, 0.2, "still easing at 0.1 s")
        XCTAssertLessThan(early.neonWarmth, 0.85, "but on its way")
        let settled = run(&m, seconds: 0.3)
        XCTAssertLessThan(settled.neonWarmth, 0.08, "A minor: cool by 0.4 s")
        // Single notes leave the colour where it is.
        for n: UInt8 in [57, 60, 64] { m.handle(.noteOff(note: n)) }
        m.handle(.noteOn(note: 72, velocity: 0.7))
        let single = run(&m, seconds: 1)
        XCTAssertLessThan(single.neonWarmth, 0.08)
        // The palette: warm is magenta, amber and pink; cool is cyan, blue and violet; between, never green.
        let magenta = NeonPalette.colour(slot: 0, warmth: 1)
        XCTAssertGreaterThan(magenta.x, magenta.z)
        XCTAssertGreaterThan(magenta.z, magenta.y)
        let amber = NeonPalette.colour(slot: 1, warmth: 1)
        XCTAssertGreaterThan(amber.x, amber.y)
        XCTAssertGreaterThan(amber.y, amber.z)
        let cyan = NeonPalette.colour(slot: 0, warmth: 0)
        XCTAssertGreaterThan(cyan.z, cyan.x)
        XCTAssertGreaterThan(cyan.y, cyan.x)
        let violet = NeonPalette.colour(slot: 2, warmth: 0)
        XCTAssertGreaterThan(violet.z, violet.x)
        XCTAssertGreaterThan(violet.x, violet.y)
        for slot in 0..<3 {
            let mid = NeonPalette.colour(slot: slot, warmth: 0.5)
            let top = max(mid.x, mid.z)
            XCTAssertLessThan(mid.y, top, "slot \(slot): never through green")
        }
    }

    func testNotesPulseSigns() {
        var m = model()
        m.handle(.noteOn(note: 61, velocity: 0.9))
        let on = run(&m, seconds: 0.2)
        let slot = NeonNightDriveModel.sign(for: 61)
        XCTAssertEqual(on.signs.count, NeonNightDriveModel.signCount)
        XCTAssertGreaterThan(on.signs[slot], 0.9)
        var others: Float = 0
        for i in 0..<NeonNightDriveModel.signCount where i != slot { others = max(others, on.signs[i]) }
        XCTAssertEqual(others, 0, "only its own sign")
        let neighbour = NeonNightDriveModel.sign(for: 62)
        XCTAssertNotEqual(neighbour, slot)
        // A harder note lights its sign brighter.
        var soft = model()
        soft.handle(.noteOn(note: 61, velocity: 0.3))
        let quiet = run(&soft, seconds: 0.2)
        XCTAssertLessThan(quiet.signs[slot], on.signs[slot])
        // Let go, it fades.
        m.handle(.noteOff(note: 61))
        let off = run(&m, seconds: 3)
        XCTAssertLessThan(off.signs[slot], 0.05)
    }

    func testSignsBlinkWithTheArp() {
        // With Chrome Bass's arp running (a low note held, a pulse at 120), a held sign blinks on its sixteenths.
        var m = model()
        m.pulse = InstrumentPulse(bpm: 120, gate: 0.55)
        m.handle(.noteOn(note: 36, velocity: 0.8))
        m.handle(.noteOn(note: 67, velocity: 0.8))
        let slot = NeonNightDriveModel.sign(for: 67)
        var hi: Float = 0, lo: Float = 10
        run(&m, seconds: 1) { i, f in
            guard i >= 30 else { return }
            hi = max(hi, f.signs[slot])
            lo = min(lo, f.signs[slot])
        }
        XCTAssertGreaterThan(hi, lo * 1.3, "it blinks")
        // Without a pulse it holds steady once its attack is over.
        var still = model()
        still.handle(.noteOn(note: 67, velocity: 0.8))
        var top: Float = 0, bottom: Float = 10
        run(&still, seconds: 1) { i, f in
            guard i >= 30 else { return }
            top = max(top, f.signs[slot])
            bottom = min(bottom, f.signs[slot])
        }
        XCTAssertLessThan(top - bottom, 0.01)
    }

    // MARK: - The studs (spec §9.1)

    func testStudsFollowTheArp() {
        // Chrome Bass's arp at 120 BPM steps every 125 ms from the phrase's first note: a stud pulse for each step.
        var m = model()
        m.pulse = InstrumentPulse(bpm: 120, gate: 0.55)
        m.handle(.noteOn(note: 36, velocity: 0.8))
        let f = run(&m, seconds: 1)
        XCTAssertGreaterThanOrEqual(f.studs.count, 8)
        XCTAssertLessThanOrEqual(f.studs.count, 10)
        var aheads: [Float] = []
        for s in f.studs { aheads.append(s.ahead) }
        aheads.sort()
        let step: Float = NeonNightDriveModel.studSpeed * 0.125
        for i in 1..<aheads.count {
            let gap = aheads[i] - aheads[i - 1]
            XCTAssertEqual(gap, step, accuracy: 0.05, "one sixteenth apart")
        }
        var nearest: Float = 1000
        for s in f.studs { nearest = min(nearest, s.ahead) }
        XCTAssertLessThan(nearest, NeonNightDriveModel.studStart - 30, "racing towards you")
        // Let go: the arp stops, and the pulses run out.
        m.handle(.noteOff(note: 36))
        let after = run(&m, seconds: 2)
        XCTAssertTrue(after.studs.isEmpty)
        // Without a pulse every low note sends one, and a high note none.
        var n = model()
        n.handle(.noteOn(note: 40, velocity: 0.8))
        n.handle(.noteOn(note: 72, velocity: 0.8))
        let single = run(&n, seconds: 0.1)
        XCTAssertEqual(single.studs.count, 1)
    }

    // MARK: - Tension and the Drop (spec §9.1, Review focus 1)

    func testTensionClosesInAndBringsTheTunnel() throws {
        var calm = model()
        calm.setExcitement(excitement(energy: 0.6))
        let open = run(&calm, seconds: 12)
        XCTAssertNil(open.tunnel)
        XCTAssertLessThan(open.closeIn, 0.05)
        var m = model()
        m.setExcitement(excitement(energy: 0.6, tension: 0.8))
        let f = run(&m, seconds: 12)
        XCTAssertGreaterThan(f.closeIn, 0.7, "the towers close in")
        let t = try XCTUnwrap(f.tunnel)
        XCTAssertLessThan(t.start, 0, "in it by now")
        XCTAssertGreaterThan(t.end, 0)
        XCTAssertEqual(f.rain, 0, "no rain falls in the tunnel")
        XCTAssertEqual(f.glassRain, 0)
        // Its lights pass no faster than 3 a second, even at the fastest the drop's surge allows.
        let fastest = NeonNightDriveModel.metresPerSecond(1.25)
        let rate = fastest / f.tunnelLightSpacing
        XCTAssertLessThanOrEqual(rate, 3.0001)
        // No drop: as tension fades the tunnel lets you out again.
        m.setExcitement(excitement(energy: 0.6))
        let out = run(&m, seconds: 30)
        XCTAssertNil(out.tunnel)
        XCTAssertNil(out.bridge)
    }

    func testTheDropBurstsOntoTheBridge() throws {
        var m = model()
        m.setExcitement(excitement(energy: 0.7, tension: 0.9))
        let inside = run(&m, seconds: 12)
        let before = try XCTUnwrap(inside.tunnel)
        XCTAssertLessThan(before.start, 0)
        var e = excitement(energy: 0.7, tension: 0.9, drop: 1)
        e.moment = BigMoment(kind: .chord, strength: 1, low: false, isDrop: true)
        m.setExcitement(e)
        let hit = run(&m, seconds: 1.0 / 60)
        let t = try XCTUnwrap(hit.tunnel)
        XCTAssertGreaterThan(t.end, 0)
        XCTAssertLessThanOrEqual(t.end, NeonNightDriveModel.exitAhead + 1, "its mouth just ahead")
        let b = try XCTUnwrap(hit.bridge)
        XCTAssertEqual(b.start, t.end, accuracy: 0.01, "straight out onto the bridge")
        XCTAssertNil(hit.wave, "the signs wait until you burst out")
        XCTAssertNotNil(hit.bloom, "the trails fan out")
        XCTAssertGreaterThan(hit.rainSlow, 0.9, "the rain hangs")
        XCTAssertEqual(hit.parting, 1)
        // The release breathes the city's lights out.
        m.setExcitement(excitement(energy: 0.7, drop: 0.5))
        let mid = run(&m, seconds: 1.0 / 60)
        XCTAssertLessThan(mid.cityLight, 0.7)
        XCTAssertLessThan(mid.rainSlow, 0.9)
        // Out on the bridge in a few seconds, after a surge.
        m.setExcitement(excitement(energy: 0.7))
        var fastest: Float = 0
        var waveOutside = false, waveInside = false
        let out = run(&m, seconds: 3) { _, f in
            fastest = max(fastest, f.speed)
            let inside = f.tunnel.map { $0.start <= 0 && $0.end > 0 } ?? false
            if f.wave != nil { if inside { waveInside = true } else { waveOutside = true } }
        }
        XCTAssertTrue(waveOutside, "every sign fires as you come out")
        XCTAssertFalse(waveInside)
        let ob = try XCTUnwrap(out.bridge)
        XCTAssertLessThan(ob.start, 0, "on the bridge")
        XCTAssertGreaterThan(ob.end, 0)
        let cruise: Float = 0.25 + 0.55 * 0.7
        XCTAssertGreaterThan(fastest, cruise + 0.1, "the speed surges")
        XCTAssertEqual(out.cityLight, 1)
    }

    func testAMomentOnTheStreetPartsTheTowers() throws {
        var m = model()
        m.setExcitement(excitement(energy: 0.5))
        run(&m, seconds: 2)
        m.setExcitement(moment(0.8))
        let hit = run(&m, seconds: 1.0 / 60)
        XCTAssertNil(hit.tunnel)
        let b = try XCTUnwrap(hit.bridge)
        XCTAssertEqual(b.start, NeonNightDriveModel.partAhead, accuracy: 1.5)
        XCTAssertLessThan(hit.parting, 0.1)
        XCTAssertNotNil(hit.wave)
        m.setExcitement(excitement(energy: 0.5))
        let parted = run(&m, seconds: 1)
        XCTAssertEqual(parted.parting, 1)
        // The wave runs out from the road's end: near signs fire first.
        let w = try XCTUnwrap(hit.wave)
        var later = w
        later.age = 0.3
        let near = later.light(at: 0.05)
        let far = later.light(at: 0.9)
        XCTAssertGreaterThan(near, far)
        // Reduce Motion halves it.
        var r = model()
        var rm = moment(1)
        rm.reduceMotion = true
        r.setExcitement(rm)
        let calm = run(&r, seconds: 1.0 / 60)
        let rw = try XCTUnwrap(calm.wave)
        XCTAssertLessThanOrEqual(rw.strength, 0.5)
    }

    // MARK: - Surprises (spec §9.1)

    func testSurprisesAllPlay() throws {
        for index in 0..<NeonNightDriveModel.surpriseCount {
            var m = model()
            m.setExcitement(excitement(energy: 0.5))
            run(&m, seconds: 1)
            var e = excitement(energy: 0.5)
            e.surprise = WorldSurprise(index: index, seed: 0xABC + UInt64(index))
            m.setExcitement(e)
            let f = run(&m, seconds: 0.5)
            switch index {
            case 0:
                let o = try XCTUnwrap(f.overpass, "a railway bridge")
                XCTAssertTrue(o.rail)
                XCTAssertNotNil(o.trainX, "with a train crossing")
            case 1:
                XCTAssertNotNil(f.lightning, "far lightning")
            case 2:
                XCTAssertNotNil(f.deadSign, "a sign flickers")
                let dark = run(&m, seconds: 5)
                XCTAssertEqual(dark.deadLight, 0, "and dies")
            case 3:
                let bar = f.cars.contains { $0.lightBar }
                XCTAssertTrue(bar, "an abstract light bar overtakes")
            default:
                let o = try XCTUnwrap(f.overpass, "a road bridge")
                XCTAssertFalse(o.rail)
            }
            // Each is over within a minute.
            let later = run(&m, seconds: 50)
            XCTAssertNil(later.overpass, "\(index)")
            XCTAssertNil(later.lightning, "\(index)")
            XCTAssertNil(later.deadSign, "\(index)")
            let bar = later.cars.contains { $0.lightBar }
            XCTAssertFalse(bar, "\(index)")
        }
    }

    func testTheRainStopsUnderABridge() {
        var m = model()
        m.setExcitement(excitement(energy: 0.5))
        run(&m, seconds: 1)
        var e = excitement(energy: 0.5)
        e.surprise = WorldSurprise(index: 4, seed: 7)
        m.setExcitement(e)
        var minGlass: Float = 1, minRain: Float = 1
        run(&m, seconds: 12) { _, f in
            minGlass = min(minGlass, f.glassRain)
            minRain = min(minRain, f.rain)
        }
        XCTAssertEqual(minGlass, 0, "under the bridge the glass stays dry")
        XCTAssertGreaterThan(minRain, 0.3, "while it rains either side")
        let after = run(&m, seconds: 5)
        XCTAssertGreaterThan(after.glassRain, 0.3)
    }

    // MARK: - The wipers (spec §9.1)

    func testWipersFollowTheRain() {
        let dry = Wipers.rate(rain: 0)
        let drizzle = Wipers.rate(rain: 0.1)
        let low = Wipers.rate(rain: 0.45)
        let high = Wipers.rate(rain: 1)
        XCTAssertEqual(dry, 0)
        XCTAssertGreaterThan(drizzle, 0)
        XCTAssertLessThan(drizzle, low)
        XCTAssertLessThan(low, high)
        XCTAssertLessThanOrEqual(high, 70)
        // Over a minute of steady rain they sweep at that rate.
        for rain: Float in [0.1, 0.45, 1] {
            var w = Wipers()
            for _ in 0..<3600 { w.step(dt: 1.0 / 60, rain: rain) }
            let want = Wipers.rate(rain: rain)
            XCTAssertEqual(Float(w.sweeps), want, accuracy: 2.5, "rain \(rain)")
        }
        // Dry, they stay parked.
        var parked = Wipers()
        for _ in 0..<600 { parked.step(dt: 1.0 / 60, rain: 0) }
        XCTAssertEqual(parked.sweeps, 0)
        XCTAssertEqual(parked.angle, 0)
        XCTAssertEqual(parked.sinceWiped(0.5), 1000, "never wiped")
        // Just wiped glass is clear: right after a sweep, every angle was wiped within the sweep.
        var w = Wipers()
        var sinceMax: Float = 0
        for _ in 0..<600 { w.step(dt: 1.0 / 60, rain: 0.8) }
        for k in 0...10 {
            let a = Float(k) / 10
            sinceMax = max(sinceMax, w.sinceWiped(a))
        }
        XCTAssertLessThanOrEqual(sinceMax, Wipers.sweepTime(rain: 0.8) + 0.05)
        // Through the world: the Rain dial sets the pace.
        var light = model()
        let lf = run(&light, seconds: 30, ["rain": .number(0.12)])
        var heavy = model()
        let hf = run(&heavy, seconds: 30, ["rain": .number(0.95)])
        XCTAssertGreaterThan(hf.wipers.sweeps, lf.wipers.sweeps + 10)
    }

    // MARK: - Light Trails (spec §9.2)

    func testLightTrailsRingHolds128() {
        var t = LightTrails()
        XCTAssertEqual(t.ringSize, LightTrails.capacity)
        let c = SIMD3<Float>(1, 0.1, 0.5)
        for i in 0..<1000 {
            t.noteOn(UInt8(21 + i % 88), velocity: 0.8, colour: c)
            if i % 10 == 0 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        }
        XCTAssertEqual(t.streaks.count, LightTrails.capacity, "full")
        XCTAssertEqual(t.ringSize, LightTrails.capacity, "and never grown")
        // Through the world, hammered: never more than the ring.
        var m = model()
        var most = 0
        for i in 0..<600 {
            let n = UInt8(21 + (i * 7) % 88)
            m.handle(.noteOn(note: n, velocity: 0.9))
            if i % 3 == 0 { m.handle(.noteOff(note: UInt8(21 + ((i - 30) * 7 + 880) % 88))) }
            let f = m.step(dt: 1.0 / 60, params: params(), roles: RoleValues(), inputs: InputFrame(), quality: .high)
            most = max(most, f.trails.count)
        }
        XCTAssertLessThanOrEqual(most, LightTrails.capacity)
    }

    func testLightTrailsLanesLengthAndLight() throws {
        XCTAssertEqual(LightTrails.lane(for: 30), 0, "the arp's low notes, far left")
        XCTAssertEqual(LightTrails.lane(for: 40), 1)
        XCTAssertEqual(LightTrails.lane(for: 60), 2, "the brass, right")
        XCTAssertEqual(LightTrails.lane(for: 84), 3)
        var t = LightTrails()
        let c = SIMD3<Float>(0.1, 0.8, 1)
        t.noteOn(60, velocity: 0.4, colour: c)
        t.noteOn(76, velocity: 1, colour: c)
        for _ in 0..<30 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        t.noteOff(60)
        for _ in 0..<30 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        let short = try XCTUnwrap(t.streaks.first { $0.note == 60 })
        let long = try XCTUnwrap(t.streaks.first { $0.note == 76 })
        XCTAssertGreaterThan(long.length, short.length + 10, "held longer, longer")
        XCTAssertGreaterThan(long.brightness, short.brightness, "struck harder, brighter")
        XCTAssertEqual(long.colour, c, "in its chord's colour")
        XCTAssertEqual(long.tail, LightTrails.launchAhead, accuracy: 1e-4, "held: still leaving the car")
        // Let go, it chases off and fades.
        t.noteOff(76)
        for _ in 0..<300 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        XCTAssertTrue(t.streaks.isEmpty)
        // A moment fans the interchange out ahead, for its life.
        t.fireBloom(strength: 0.9, seed: 3)
        for _ in 0..<12 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        let bloom = try XCTUnwrap(t.bloom)
        XCTAssertGreaterThan(bloom.light, 0.5)
        XCTAssertLessThan(bloom.at, LightTrails.bloomAhead, "coming towards you")
        for _ in 0..<240 { t.step(dt: 1.0 / 60, metresPerSecond: 25) }
        XCTAssertNil(t.bloom)
    }

    // MARK: - Hold, quiet, pools

    func testNotesBloomAtOnceWhileTimeIsHeld() throws {
        var m = model()
        m.pulse = InstrumentPulse(bpm: 120, gate: 0.55)
        run(&m, seconds: 0.5)
        m.handle(.noteOn(note: 62, velocity: 0.8))
        m.handle(.noteOn(note: 38, velocity: 0.8))
        let held = m.step(dt: 0, params: params(), roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let s = try XCTUnwrap(held.trails.first { $0.note == 62 })
        XCTAssertGreaterThan(s.length, 10, "a streak shows at once")
        let slot = NeonNightDriveModel.sign(for: 62)
        XCTAssertGreaterThan(held.signs[slot], 0.5, "its sign lights at once")
        XCTAssertEqual(held.studs.count, 1, "and the arp's first stud pulse stands on the road")
    }

    func testAQuietKeyboardSettles() {
        var m = model()
        m.pulse = InstrumentPulse(bpm: 120, gate: 0.55)
        m.setExcitement(excitement(energy: 0.9, tension: 0.7))
        for n: UInt8 in [36, 60, 64, 67] { m.handle(.noteOn(note: n, velocity: 0.9)) }
        run(&m, seconds: 2)
        m.handle(.allNotesOff)
        m.setExcitement(excitement())
        let f = run(&m, seconds: 40)
        XCTAssertEqual(f.speed, NeonNightDriveModel.cruise, accuracy: 0.01)
        XCTAssertTrue(f.trails.isEmpty)
        XCTAssertTrue(f.studs.isEmpty)
        var brightest: Float = 0
        for v in f.signs { brightest = max(brightest, v) }
        XCTAssertEqual(brightest, 0)
        XCTAssertNil(f.wave)
        XCTAssertNil(f.tunnel)
        XCTAssertLessThan(f.closeIn, 0.02)
    }

    func testPoolsStayFixedUnderAHammering() {
        var m = model()
        m.pulse = InstrumentPulse(bpm: 170, gate: 0.5)
        var trails = 0, studs = 0, cars = 0, signs = 0
        for i in 0..<1800 {
            for k in 0..<5 { m.handle(.noteOn(note: UInt8(21 + (i * 5 + k * 13) % 88), velocity: 1)) }
            if i % 2 == 1 { m.handle(.allNotesOff) }
            var e = excitement(energy: 1, tension: 1, drop: 1)
            if i % 15 == 0 { e.moment = BigMoment(kind: .chord, strength: 1, low: i % 30 == 0, isDrop: i % 45 == 0) }
            if i % 60 == 0 { e.surprise = WorldSurprise(index: (i / 60) % 5, seed: UInt64(i)) }
            m.setExcitement(e)
            let f = m.step(dt: 1.0 / 60, params: params(["traffic": .number(1)]), roles: RoleValues(), inputs: InputFrame(),
                           quality: .high)
            trails = max(trails, f.trails.count)
            studs = max(studs, f.studs.count)
            cars = max(cars, f.cars.count)
            signs = max(signs, f.signs.count)
            XCTAssertTrue(f.speed.isFinite)
        }
        XCTAssertLessThanOrEqual(trails, LightTrails.capacity)
        XCTAssertLessThanOrEqual(studs, NeonNightDriveModel.studCap)
        XCTAssertLessThanOrEqual(cars, NeonNightDriveModel.carCap)
        XCTAssertEqual(signs, NeonNightDriveModel.signCount)
    }

    func testTheSameNightDrivesTheSame() {
        func drive() -> DriveFrame {
            var m = model()
            m.pulse = InstrumentPulse(bpm: 128, gate: 0.55)
            for i in 0..<600 {
                if i % 20 == 0 { m.handle(.noteOn(note: UInt8(40 + i % 40), velocity: 0.8)) }
                if i % 20 == 10 { m.handle(.noteOff(note: UInt8(40 + (i - 10) % 40))) }
                var e = excitement(energy: 0.6, tension: 0.4)
                if i == 300 { e.moment = BigMoment(kind: .chord, strength: 0.9, low: false, isDrop: false) }
                if i == 120 { e.surprise = WorldSurprise(index: 0, seed: 11) }
                m.setExcitement(e)
                _ = m.step(dt: 1.0 / 60, params: params(), roles: RoleValues(), inputs: InputFrame(), quality: .high)
            }
            return m.step(dt: 1.0 / 60, params: params(), roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let a = drive(), b = drive()
        XCTAssertEqual(a.distance, b.distance)
        XCTAssertEqual(a.trails, b.trails)
        XCTAssertEqual(a.cars, b.cars)
        XCTAssertEqual(a.studs, b.studs)
        XCTAssertEqual(a.overpass, b.overpass)
        XCTAssertEqual(a.bridge, b.bridge)
    }

    func testGalaxyWarpTakesTheNotes() {
        var m = model()
        m.handle(.noteOn(note: 64, velocity: 0.9))
        let f = run(&m, seconds: 0.3, ["visual": .choice("Galaxy Warp")])
        XCTAssertTrue(f.trails.isEmpty, "the notes streak through the sky instead")
        XCTAssertNotNil(f.warp)
        XCTAssertGreaterThan(f.signs[NeonNightDriveModel.sign(for: 64)], 0.5, "but still light their signs")
    }

    // MARK: - Ambience

    func testAmbienceFollowsTheDrive() {
        let s = night()
        let slow = NeonNightDriveModel.levels(s, speed: 0.25, glassRain: 0.5, traffic: 0.5, inTunnel: false)
        let fast = NeonNightDriveModel.levels(s, speed: 1, glassRain: 0.5, traffic: 0.5, inTunnel: false)
        let slowRoad = slow[.road] ?? 0, fastRoad = fast[.road] ?? 0
        let slowEngine = slow[.engine] ?? 0, fastEngine = fast[.engine] ?? 0
        XCTAssertGreaterThan(fastRoad, slowRoad)
        XCTAssertGreaterThan(fastEngine, slowEngine)
        XCTAssertEqual(slow[.rainOnGlass] ?? 0, 0.5, accuracy: 1e-9)
        let busy = NeonNightDriveModel.levels(s, speed: 0.5, glassRain: 0.5, traffic: 1, inTunnel: false)
        let empty = NeonNightDriveModel.levels(s, speed: 0.5, glassRain: 0.5, traffic: 0, inTunnel: false)
        let busyCars = busy[.passingCar] ?? 0, emptyCars = empty[.passingCar] ?? 0
        XCTAssertGreaterThan(busyCars, emptyCars)
        let tunnel = NeonNightDriveModel.levels(s, speed: 0.5, glassRain: 0, traffic: 0.5, inTunnel: true)
        XCTAssertNil(tunnel[.rainOnGlass])
        XCTAssertEqual(tunnel[.street] ?? 0, 0)
        // The frame's scene carries the car's speed.
        var m = model()
        m.setExcitement(excitement(energy: 1))
        let f = run(&m, seconds: 10)
        XCTAssertEqual(f.ambience.speed, Double(f.speed), accuracy: 0.01)
        XCTAssertGreaterThan(f.ambience.level(.road), 0.6)
    }
}
