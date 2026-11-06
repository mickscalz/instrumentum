import XCTest
import simd
@testable import InStrumCore

/// Supercell Sky and its visual, Wall Cloud (Storms spec §5, §8; plan Task 9). Every bound is the spec's, which the model
/// holds by construction: the rpm law, the bands' spacing, 3 s of thunder a kilometre capped at 12, the gust front's
/// 15 m/s, the flock's 40 (20 on Smooth), the 6 px shake within 2 km, the funnel once an evening.
final class WallCloudTests: XCTestCase {
    // MARK: - Helpers

    /// A summer evening over Melbourne: the sun `altitude` up at `azimuth`, on day `day` at `hour`.
    private func evening(sun altitude: Double = 5, azimuth: Double = 290, hour: Double = 18.5, day: Int = 320) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: azimuth, altitude: altitude)
        s.moon = SkyDirection(azimuth: 100, altitude: -20)
        s.hourOfDay = hour
        s.dayOfYear = day
        s.latitude = -37.8
        s.zenith = SIMD3(0.3, 0.45, 0.75)
        s.horizon = SIMD3(0.9, 0.7, 0.45)
        return s
    }

    private func params(_ values: [String: ParamValue] = [:]) -> ParameterSet {
        ThemeRegistry.parameterSet(for: SupercellSkyModel.id, state: ThemeState(values: values))
    }

    /// Steps `model` for `seconds` at 60 fps and returns the last frame.
    @discardableResult
    private func run(_ model: inout SupercellSkyModel, seconds: Double, _ values: [String: ParamValue] = [:],
                     quality: QualityLevel = .high) -> SupercellFrame {
        let p = params(values)
        let n = max(1, Int((seconds * 60).rounded()))
        var frame: SupercellFrame?
        for _ in 0..<n {
            frame = model.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: quality)
        }
        return frame!
    }

    private func model(_ sky: SkyState? = nil) -> SupercellSkyModel {
        var m = SupercellSkyModel()
        m.mood = .stormTense
        m.setSky(sky ?? evening())
        return m
    }

    private func excitement(energy: Float = 0, tension: Float = 0, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = energy
        e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
        e.tension = tension
        e.reduceMotion = reduceMotion
        return e
    }

    private func moment(_ strength: Float, drop: Bool = false, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = excitement(reduceMotion: reduceMotion)
        e.moment = BigMoment(kind: .chord, strength: strength, low: true, isDrop: drop)
        return e
    }

    /// The Distance dial's value for a distance in km.
    private func dial(km: Double) -> ParamValue { .number(1 - km / 30) }

    private func meanHeight(_ birds: [StormBird]) -> Float {
        var z: Float = 0
        for b in birds { z += b.position.z }
        return birds.isEmpty ? 0 : z / Float(birds.count)
    }

    private func meanVelocity(_ birds: [StormBird]) -> SIMD3<Float> {
        var v = SIMD3<Float>(repeating: 0)
        for b in birds { v += b.velocity }
        return birds.isEmpty ? v : v / Float(birds.count)
    }

    /// The signed turn from one angle to another (radians, −π…π).
    private func turned(from a: Float, to b: Float) -> Float {
        var d = b - a
        while d > Float.pi { d -= 2 * Float.pi }
        while d < -Float.pi { d += 2 * Float.pi }
        return d
    }

    // MARK: - Energy

    /// Spec §8.2: rpm = 0.3 + 1.7 × Energy; Reduce Motion caps the turn at 1 rpm. A southern storm turns clockwise.
    func testRotationFollowsEnergy() {
        let rest = WallCloud.rpm(energy: 0, reduceMotion: false)
        let full = WallCloud.rpm(energy: 1, reduceMotion: false)
        let half = WallCloud.rpm(energy: 0.5, reduceMotion: false)
        let reduced = WallCloud.rpm(energy: 1, reduceMotion: true)
        XCTAssertEqual(rest, 0.3, accuracy: 1e-6)
        XCTAssertEqual(full, 2.0, accuracy: 1e-6)
        XCTAssertEqual(half, 1.15, accuracy: 1e-6)
        XCTAssertEqual(reduced, 1, accuracy: 1e-6)

        var m = model()
        m.setExcitement(excitement(energy: 0))
        let calm = run(&m, seconds: 1)
        XCTAssertEqual(calm.rotationRPM, 0.3, accuracy: 1e-6)
        XCTAssertEqual(calm.spin, -1, "a southern supercell turns clockwise seen from above")
        m.setExcitement(excitement(energy: 1))
        let before = run(&m, seconds: 1.0 / 60).rotation
        let fast = run(&m, seconds: 1)
        XCTAssertEqual(fast.rotationRPM, 2, accuracy: 1e-6)
        let angle = turned(from: before, to: fast.rotation)
        let expected: Float = -2 * 2 * Float.pi / 60
        XCTAssertEqual(angle, expected, accuracy: 0.01, "12° in a second at 2 rpm, clockwise")
        m.setExcitement(excitement(energy: 1, reduceMotion: true))
        let gentle = run(&m, seconds: 0.5)
        XCTAssertLessThanOrEqual(gentle.rotationRPM, 1)
        XCTAssertTrue(gentle.reduceMotion)

        var north = model({ var s = evening(); s.latitude = 40; return s }())
        let up = run(&north, seconds: 0.1)
        XCTAssertEqual(up.spin, 1, "a northern one anticlockwise")
    }

    /// Spec §8.2: the inflow bands tighten with Energy, 12° → 5°, and the inflow blows harder.
    func testInflowTightens() {
        let wide = WallCloud.spacing(tightness: 0)
        let tight = WallCloud.spacing(tightness: 1)
        XCTAssertEqual(wide, 12, accuracy: 1e-6)
        XCTAssertEqual(tight, 5, accuracy: 1e-6)
        var m = model()
        m.setExcitement(excitement(energy: 0))
        let rest = run(&m, seconds: 0.5)
        m.setExcitement(excitement(energy: 1))
        let hard = run(&m, seconds: 0.5)
        XCTAssertEqual(rest.inflowTightness, 0, accuracy: 1e-6)
        XCTAssertEqual(rest.inflowSpacing, 12, accuracy: 1e-5)
        XCTAssertEqual(hard.inflowTightness, 1, accuracy: 1e-6)
        XCTAssertEqual(hard.inflowSpacing, 5, accuracy: 1e-5)
        let slow = simd_length(rest.wind.steady)
        let strong = simd_length(hard.wind.steady)
        XCTAssertGreaterThan(strong, 2 * slow, "the inflow rises")
        XCTAssertGreaterThan(rest.wind.steady.y, 0, "blowing toward the storm")
        XCTAssertGreaterThan(hard.baseDarkness, rest.baseDarkness, "and the base darkens")
    }

    // MARK: - Moments

    /// Spec §3, §8.2: a big moment places a cloud-to-ground strike at the storm's distance and queues its thunder 3 s a
    /// kilometre late, at most 12 s.
    func testStrikeAtTheStormsDistance() throws {
        let ten: [String: ParamValue] = ["distance": dial(km: 10)]
        var m = model()
        run(&m, seconds: 0.5, ten)
        m.setExcitement(moment(0.8))
        let f = run(&m, seconds: 1.0 / 60, ten)
        XCTAssertEqual(f.distanceKm, 10, accuracy: 1e-3)
        XCTAssertEqual(f.strikes.count, 1)
        let strike = try XCTUnwrap(f.strikes.last)
        XCTAssertEqual(strike.distanceKm, 10, accuracy: 1e-3)
        let foot = simd_length(strike.ground)
        XCTAssertEqual(foot, 10, accuracy: 1e-3, "it comes down on the field 10 km off")
        let dip = SupercellSkyModel.horizonDepression(km: strike.distanceKm)
        let expectedDip = Float(atan(1.7 / 10_000.0) * 180 / Double.pi)
        XCTAssertEqual(dip, expectedDip, accuracy: 1e-5, "just under the horizon")
        XCTAssertGreaterThanOrEqual(strike.bearing, -24)
        XCTAssertLessThanOrEqual(strike.bearing, 10)
        XCTAssertGreaterThan(strike.brightness, 0.4, "lit in the frame the moment fires")
        let queued = f.ambience.thunderQueue
        XCTAssertEqual(queued.count, 1)
        let delay = try XCTUnwrap(queued.first).delay
        XCTAssertEqual(delay, 12, accuracy: 1e-9, "30 s, capped at 12")
        let next = run(&m, seconds: 1.0 / 60, ten)
        XCTAssertTrue(next.ambience.thunderQueue.isEmpty, "a one-shot")
        let gone = run(&m, seconds: 0.7, ten)
        XCTAssertTrue(gone.strikes.isEmpty, "a strike is seen for 0.6 s")

        let one: [String: ParamValue] = ["distance": dial(km: 1)]
        var near = model()
        run(&near, seconds: 0.5, one)
        near.setExcitement(moment(0.5))
        let close = run(&near, seconds: 1.0 / 60, one)
        let closeStrike = try XCTUnwrap(close.strikes.last)
        XCTAssertEqual(closeStrike.distanceKm, 1, accuracy: 1e-3)
        let closeDelay = try XCTUnwrap(close.ambience.thunderQueue.first).delay
        XCTAssertEqual(closeDelay, 3, accuracy: 1e-3)
    }

    /// Spec §8.2: the drop is the gust front, a wave crossing the field from the storm to the camera at 15 m/s with the
    /// outflow blowing on behind it.
    func testGustWaveCrossesAtFifteenMetresPerSecond() throws {
        var m = model()
        let quiet = run(&m, seconds: 0.5)
        XCTAssertNil(quiet.gustWave)
        m.setExcitement(moment(1, drop: true))
        var frames: [SupercellFrame] = []
        for _ in 0..<1320 { frames.append(run(&m, seconds: 1.0 / 60)) }   // 22 s
        let first = try XCTUnwrap(frames[0].gustWave)
        XCTAssertLessThan(first, 0.01, "it sets out from the field's far edge")
        let tenSeconds = try XCTUnwrap(frames[599].gustWave)
        XCTAssertEqual(tenSeconds, 0.5, accuracy: 0.003, "150 m of 300 in 10 s")
        let nearly = try XCTUnwrap(frames[1190].gustWave)
        XCTAssertGreaterThan(nearly, 0.98)
        XCTAssertNil(frames[1220].gustWave, "past the camera after 20 s")
        // The wind field carries it: 15 m/s, the crest 150 m off at 10 s, calm ahead of it, the outflow behind.
        let wind = frames[599].wind
        var speed: Float = 0
        for slot in 0..<WindField.maxGusts { if let g = wind.gust(at: slot) { speed = g.speed } }
        XCTAssertEqual(speed, 15)
        let crest = wind.sample(SIMD2(0, 150)).y
        let ahead = wind.sample(SIMD2(0, 60)).y
        let behind = wind.sample(SIMD2(0, 260)).y
        XCTAssertLessThan(crest, -10, "the front blows toward the camera")
        XCTAssertGreaterThan(ahead, 0, "ahead of it the inflow still blows toward the storm")
        XCTAssertLessThan(behind, -10, "behind it the grass stays flat")
        let dust = frames[599].dust
        XCTAssertGreaterThan(dust, 0.5, "dust lifts")
        let hail = frames[60].hailDensity
        XCTAssertGreaterThan(hail, quiet.hailDensity + 0.3, "the hail shaft comes in")
    }

    /// Spec §8.2: the flock sits in the stubble until the first big moment, lifts and wheels, then streams away from the
    /// storm ahead of the front.
    func testFlockLiftsOnFirstMomentAndFleesTheFront() {
        var m = model()
        let quiet = run(&m, seconds: 3)
        let sitting = meanHeight(quiet.flock)
        XCTAssertEqual(sitting, 0, "on the ground")
        let calls = quiet.ambience.level(.birdsFlee)
        XCTAssertEqual(calls, 0)
        m.setExcitement(moment(0.6))
        let lifted = run(&m, seconds: 3)
        let height = meanHeight(lifted.flock)
        XCTAssertGreaterThan(height, 5, "up off the field")
        let calling = lifted.ambience.level(.birdsFlee)
        XCTAssertGreaterThan(calling, 0)
        let wheelingY = meanVelocity(lifted.flock).y
        m.setExcitement(moment(1, drop: true))
        let fleeing = run(&m, seconds: 4)
        let v = meanVelocity(fleeing.flock)
        XCTAssertLessThan(v.y, -8, "streaming toward the camera, away from the storm")
        XCTAssertLessThan(v.y, wheelingY)
        XCTAssertGreaterThan(v.z, 0, "climbing")
        let still = fleeing.ambience.level(.birdsFlee)
        XCTAssertGreaterThan(still, 0)
    }

    /// Spec §8.2: 40 birds, 20 on Smooth, kept inside the world's box.
    func testFlockBounded() {
        var m = model()
        let high = run(&m, seconds: 0.2, quality: .high)
        XCTAssertEqual(high.flock.count, 40)
        let smooth = run(&m, seconds: 0.2, quality: .lite)
        XCTAssertEqual(smooth.flock.count, 20)
        XCTAssertEqual(StormFlock.count(.ultra), 40)
        var f = StormFlock(quality: .high, seed: 3)
        f.lift()
        var inside = true, finite = true
        for i in 0..<3600 {
            if i == 900 { f.flee(awayFromStorm: SIMD2(-0.35, -1)) }
            f.step(dt: 1.0 / 30, energy: 1)
            for b in f.birds {
                let p = b.position
                finite = finite && p.x.isFinite && p.y.isFinite && p.z.isFinite
                let lo = p.x >= StormFlock.lower.x && p.y >= StormFlock.lower.y && p.z >= StormFlock.lower.z
                let hi = p.x <= StormFlock.upper.x && p.y <= StormFlock.upper.y && p.z <= StormFlock.upper.z
                inside = inside && lo && hi
            }
        }
        XCTAssertTrue(finite)
        XCTAssertTrue(inside)
        XCTAssertEqual(f.birds.count, 40)
        XCTAssertEqual(f.state, .grounded, "gone ahead of the front, then back on the field a while later")
    }

    /// Spec §3, §8.2: a strike closer than 2 km shakes the camera (at most 6 px, for 0.4 s); a far one only glows; the
    /// drop shakes it once; Reduce Motion never.
    func testShakeOnlyWhenClose() {
        func most(km: Double, drop: Bool = false, reduce: Bool = false) -> (peak: Float, after: Float) {
            let values: [String: ParamValue] = ["distance": dial(km: km)]
            var m = model()
            m.setExcitement(excitement(reduceMotion: reduce))
            run(&m, seconds: 0.5, values)
            m.setExcitement(moment(1, drop: drop, reduceMotion: reduce))
            var peak: Float = 0
            for _ in 0..<24 {
                let frame = run(&m, seconds: 1.0 / 60, values)
                peak = max(peak, simd_length(frame.cameraShake))
            }
            let after = simd_length(run(&m, seconds: 0.2, values).cameraShake)
            return (peak, after)
        }
        let far = most(km: 10)
        XCTAssertEqual(far.peak, 0, "a far strike only glows")
        let near = most(km: 1)
        XCTAssertGreaterThan(near.peak, 1)
        XCTAssertLessThanOrEqual(near.peak, 6)
        XCTAssertEqual(near.after, 0, "over in 0.4 s")
        let reduced = most(km: 1, reduce: true)
        XCTAssertEqual(reduced.peak, 0, "none under Reduce Motion")
        let drop = most(km: 10, drop: true)
        XCTAssertGreaterThan(drop.peak, 1, "the drop shakes it once")
        XCTAssertLessThanOrEqual(drop.peak, 6)
        let quietDrop = most(km: 10, drop: true, reduce: true)
        XCTAssertEqual(quietDrop.peak, 0)
    }

    // MARK: - Surprises

    /// Spec §5, §17.6: the funnel lowers and lifts in 8–14 s, far, never touching the ground, and once an evening.
    func testFunnelOncePerEvening() {
        var m = model()
        run(&m, seconds: 0.5)
        var e = excitement()
        e.surprise = WorldSurprise(index: 0, seed: 7)
        m.setExcitement(e)
        let first = run(&m, seconds: 1.0 / 60)
        XCTAssertNotNil(first.funnel)
        var deepest: Float = 0
        var lasted = 0.0
        for i in 1...(16 * 60) {
            let f = run(&m, seconds: 1.0 / 60)
            if let funnel = f.funnel { deepest = max(deepest, funnel.reach); lasted = Double(i) / 60 }
        }
        XCTAssertGreaterThan(deepest, 0.4)
        XCTAssertLessThanOrEqual(deepest, StormFunnel.maxReach, "never reaching the ground")
        XCTAssertLessThan(StormFunnel.maxReach, 1)
        XCTAssertGreaterThan(lasted, 7.9)
        XCTAssertLessThanOrEqual(lasted, 14)
        m.setExcitement(e)
        let again = run(&m, seconds: 1.0 / 60)
        XCTAssertNil(again.funnel, "once an evening")
        m.setSky(evening(day: 321))
        m.setExcitement(e)
        let tomorrow = run(&m, seconds: 1.0 / 60)
        XCTAssertNotNil(tomorrow.funnel, "the next evening it may come again")

        // Far only: overhead it never comes (and doesn't use up the evening).
        var close = model()
        let overhead: [String: ParamValue] = ["distance": .number(1)]
        run(&close, seconds: 0.5, overhead)
        close.setExcitement(e)
        let none = run(&close, seconds: 1.0 / 60, overhead)
        XCTAssertNil(none.funnel)
        close.setExcitement(e)
        let later = run(&close, seconds: 1.0 / 60)
        XCTAssertNotNil(later.funnel)
    }

    /// Spec §8.2: in its Clearing, crepuscular rays under the anvil's edge with the sun up, a double rainbow in the rain
    /// with the sun 1°–42° up, the stars behind once it's dark; none of it while the core plays; resting settles into it.
    func testAfterglowOnClearing() {
        let clearing: [String: ParamValue] = ["supercell.stage": .choice("Clearing")]
        var golden = model()
        let lit = run(&golden, seconds: 1, clearing)
        XCTAssertEqual(lit.stage, .clearing)
        XCTAssertEqual(lit.clearing, 1, accuracy: 1e-5)
        XCTAssertGreaterThan(lit.stormRain, 0.2)
        XCTAssertEqual(lit.after.rays, 1, accuracy: 1e-5)
        XCTAssertEqual(lit.after.rainbow, 1, accuracy: 1e-5)
        XCTAssertEqual(lit.after.stars, 0, accuracy: 1e-6)

        var night = model(evening(sun: -20, hour: 22))
        let dark = run(&night, seconds: 1, clearing)
        XCTAssertEqual(dark.after.rays, 0, accuracy: 1e-6)
        XCTAssertEqual(dark.after.rainbow, 0, accuracy: 1e-6)
        XCTAssertEqual(dark.after.stars, 1, accuracy: 1e-5)

        var high = model(evening(sun: 50, hour: 13))
        let noon = run(&high, seconds: 1, clearing)
        XCTAssertEqual(noon.after.rainbow, 0, accuracy: 1e-6, "no bow with the sun past 42°")

        var playing = model()
        playing.setExcitement(excitement(energy: 0.6))
        let core = run(&playing, seconds: 1)
        XCTAssertEqual(core.stage, .core)
        XCTAssertEqual(core.after.rays, 0, accuracy: 1e-6)
        XCTAssertEqual(core.after.rainbow, 0, accuracy: 1e-6)

        var resting = model()
        let early = run(&resting, seconds: 5)
        XCTAssertEqual(early.clearing, 0, accuracy: 1e-6, "not yet")
        let settled = run(&resting, seconds: 40)
        XCTAssertGreaterThan(settled.clearing, 0.8, "resting settles it into its Clearing")
        XCTAssertGreaterThan(settled.after.rays, 0.8)
        XCTAssertGreaterThan(settled.after.rainbow, 0.8)
        XCTAssertGreaterThan(settled.distanceKm, early.distanceKm + 5, "the core draws off")
        resting.handle(.noteOn(note: 60, velocity: 0.8))
        resting.setExcitement(excitement(energy: 0.5))
        let back = run(&resting, seconds: 5)
        XCTAssertLessThan(back.clearing, 0.1, "playing brings the storm back")
    }

    // MARK: - Notes

    /// Spec §8.2: each note sends a glow up the inflow band whose outer end lies nearest its key.
    func testNotesGlowTheNearestInflowBand() throws {
        let lowest = WallCloud.band(for: 21)
        let highest = WallCloud.band(for: 108)
        let middle = WallCloud.band(for: 60)
        XCTAssertEqual(lowest, 0)
        XCTAssertEqual(highest, WallCloud.bandCount - 1)
        XCTAssertEqual(middle, 3)
        var nearest = true
        for key in KeyboardLayout.keys() {
            let x = key.x + 0.5 * key.width
            var best = 0
            var bestGap: Float = 9
            for b in 0..<WallCloud.bandCount {
                let gap = abs(x - (Float(b) + 0.5) / Float(WallCloud.bandCount))
                if gap < bestGap { bestGap = gap; best = b }
            }
            nearest = nearest && best == WallCloud.band(for: key.note)
        }
        XCTAssertTrue(nearest, "every key glows its nearest band")

        var m = model()
        m.handle(.noteOn(note: 21, velocity: 0.9))
        m.handle(.noteOn(note: 108, velocity: 0.9))
        let f = run(&m, seconds: 1.0 / 60)
        XCTAssertEqual(f.glows.count, 2)
        let low = try XCTUnwrap(f.glows.first { $0.band == 0 })
        XCTAssertGreaterThan(low.brightness, 0)
        XCTAssertLessThan(low.progress, 0.05, "it sets out from the band's outer end")
        let high = f.glows.contains { $0.band == WallCloud.bandCount - 1 }
        XCTAssertTrue(high)
        let running = run(&m, seconds: 0.6)
        let half = try XCTUnwrap(running.glows.first).progress
        XCTAssertEqual(half, 0.52, accuracy: 0.03, "up the band into the wall cloud over 1.2 s")
        let done = run(&m, seconds: 1.1)
        XCTAssertTrue(done.glows.isEmpty, "faded into the wall cloud")
        // A chord pulses the base; a run ripples round it.
        for n: UInt8 in [48, 52, 55] { m.handle(.noteOn(note: n, velocity: 0.9)) }
        let chord = run(&m, seconds: 0.1)
        XCTAssertEqual(chord.pulses.count, 1)
        let pulse = try XCTUnwrap(chord.pulses.first).brightness
        XCTAssertGreaterThan(pulse, 0.5)
        for n: UInt8 in [60, 62, 64, 65, 67] {
            m.handle(.noteOn(note: n, velocity: 0.8))
            run(&m, seconds: 0.1)
        }
        let rippling = run(&m, seconds: 0.2)
        XCTAssertEqual(rippling.ripples.count, 1, "one ripple, fed by the run")
        let ripple = try XCTUnwrap(rippling.ripples.first)
        XCTAssertEqual(ripple.direction, 1, "a rising run runs anticlockwise")
        XCTAssertGreaterThan(ripple.strength, 0.5)
    }

    func testBurstIsRationed() {
        var w = WallCloud()
        for i in 0..<2000 { w.noteOn(UInt8(21 + i % 88), velocity: 0.9) }
        var before = 0
        var spawnsOK = true, growthOK = true, capsOK = true
        for _ in 0..<60 {
            w.step(dt: 1.0 / 60, energy: 0.5, tightness: 0.5, reduceMotion: false)
            spawnsOK = spawnsOK && w.lastSpawns <= WallCloud.maxSpawnsPerStep
            growthOK = growthOK && w.glows.count - before <= WallCloud.maxSpawnsPerStep
            capsOK = capsOK && w.glows.count <= WallCloud.glowCap && w.pulses.count <= WallCloud.pulseCap
            before = w.glows.count
        }
        XCTAssertTrue(spawnsOK)
        XCTAssertTrue(growthOK)
        XCTAssertTrue(capsOK)
        XCTAssertGreaterThan(w.glows.count, 0)
        // A long run of chords and runs: the pulses and ripples stay within their caps, every light within 0…1.
        var lightsOK = true
        for i in 0..<600 {
            let base = UInt8(30 + (i * 7) % 60)
            w.noteOn(base, velocity: 1)
            if i % 3 == 0 { w.noteOn(base + 4, velocity: 1); w.noteOn(base + 7, velocity: 1) }
            w.step(dt: 0.05, energy: 1, tightness: 1, reduceMotion: false)
            capsOK = capsOK && w.glows.count <= WallCloud.glowCap && w.pulses.count <= WallCloud.pulseCap
                && w.ripples.count <= WallCloud.rippleCap
            for g in w.glows { lightsOK = lightsOK && g.brightness >= 0 && g.brightness <= 1 }
            for p in w.pulses { lightsOK = lightsOK && p.brightness >= 0 && p.brightness <= 1 }
            for r in w.ripples { lightsOK = lightsOK && r.brightness >= 0 && r.brightness <= 1 }
        }
        XCTAssertTrue(capsOK)
        XCTAssertTrue(lightsOK)
    }

    func testIdsWrap() {
        var w = WallCloud()
        w.nextGlowID = Int.max - 2
        w.nextPulseID = Int.max
        w.nextRippleID = Int.max
        for i in 0..<6 {
            w.noteOn(UInt8(60 + 2 * i), velocity: 0.8)
            w.step(dt: 0.1, energy: 0, tightness: 0, reduceMotion: false)
        }
        let ids = w.glows.map(\.id)
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6)
        let wrapped = ids.contains { $0 < 0 }
        XCTAssertTrue(wrapped)
        let rippleIDs = w.ripples.map(\.id)
        XCTAssertEqual(rippleIDs, [Int.max], "the rising run's one ripple")
        w.noteOn(55, velocity: 0.8)   // the run turns: a new ripple, its id wrapped
        w.step(dt: 0.05, energy: 0, tightness: 0, reduceMotion: false)
        let lastRipple = w.ripples.last?.id
        XCTAssertEqual(lastRipple, Int.min)
        for n: UInt8 in [40, 44, 47] { w.noteOn(n, velocity: 0.8) }
        w.step(dt: 0.2, energy: 0, tightness: 0, reduceMotion: false)
        for n: UInt8 in [41, 45, 48] { w.noteOn(n, velocity: 0.8) }
        w.step(dt: 0.05, energy: 0, tightness: 0, reduceMotion: false)
        let pulseIDs = w.pulses.map(\.id)
        XCTAssertEqual(pulseIDs, [Int.max, Int.min])
    }

    // MARK: - The world

    func testSupercellDefaults() throws {
        XCTAssertEqual(SupercellSkyModel.id, "supercell-sky")
        XCTAssertEqual(SupercellSkyModel.displayName, "Supercell Sky")
        XCTAssertEqual(ThemeRegistry.resolve(SupercellSkyModel.id), SupercellSkyModel.id)
        let listed = ThemeRegistry.all.contains { $0.id == SupercellSkyModel.id && $0.name == "Supercell Sky" }
        XCTAssertTrue(listed)
        XCTAssertTrue(ThemeRegistry.isWorld(SupercellSkyModel.id))
        let ids = ThemeRegistry.entries.map(\.id)
        let reef = try XCTUnwrap(ids.firstIndex(of: GreatBarrierReefModel.id))
        XCTAssertEqual(ids[reef + 1], SupercellSkyModel.id, "registered after the reef")
        assertValidParameters(SupercellSkyModel.parameters)
        let specIDs = SupercellSkyModel.parameters.map(\.id)
        XCTAssertEqual(specIDs, ["visual", "distance", "supercell.stage", "light.hold", "meteors.mode", "crawlers.mode",
                                 "sheet.mode", "keys.show", "keys.height"])
        XCTAssertEqual(SupercellSkyModel.visuals, ["Wall Cloud", "Galaxy Warp"])
        XCTAssertEqual(SupercellSkyModel.surpriseCount, 4)
        let p = params()
        XCTAssertEqual(p.choice("visual"), "Wall Cloud")
        XCTAssertEqual(p.number("distance"), 0.45, accuracy: 1e-9)
        XCTAssertEqual(p.choice(SupercellStage.id), "Core")
        XCTAssertEqual(p.choice("light.hold"), "Golden hour")
        XCTAssertEqual(p.choice("meteors.mode"), "Follow the calendar")
        XCTAssertEqual(p.choice(SkyExtraMode.crawlersID), "Natural")
        XCTAssertEqual(p.choice(SkyExtraMode.sheetID), "Natural")
        XCTAssertEqual(p.number("keys.show"), 1)
        XCTAssertEqual(p.number("keys.height"), 0.12, accuracy: 1e-9)
        let heroes = SupercellSkyModel.parameters.filter(\.hero).map(\.id)
        XCTAssertEqual(heroes, ["distance"])
        let distance = try XCTUnwrap(SupercellSkyModel.parameters.first { $0.id == "distance" })
        XCTAssertEqual(distance.name, "Distance")
        XCTAssertEqual(Mood.stormTense, Mood(energy: 0.7, warmth: 0.35, brightness: 0.5, space: 0.8, motion: 0.9))
        let farthest = SupercellSkyModel.km(dial: 0)
        let overhead = SupercellSkyModel.km(dial: 1)
        XCTAssertEqual(farthest, 30)
        XCTAssertEqual(overhead, 0)
        let extras = WorldWeather.randomExtras(for: SupercellSkyModel.id)
        XCTAssertEqual(extras, [.gustFront: 0.3])

        // A still golden evening: the storm at its Core 16.5 km off, turning slowly, the inflow wide, the flock on the
        // field, the camera facing away from the sun.
        var m = model()
        let still = run(&m, seconds: 1)
        XCTAssertEqual(still.keys.count, 88)
        XCTAssertEqual(still.flock.count, 40)
        XCTAssertTrue(still.strikes.isEmpty)
        XCTAssertNil(still.gustWave)
        XCTAssertNil(still.funnel)
        XCTAssertNil(still.warp)
        XCTAssertEqual(still.stage, .core)
        XCTAssertEqual(still.distanceKm, 16.5, accuracy: 1e-4)
        XCTAssertEqual(still.rotationRPM, 0.3, accuracy: 1e-6)
        XCTAssertEqual(still.inflowSpacing, 12, accuracy: 1e-5)
        XCTAssertEqual(still.viewAzimuth, 138, accuracy: 1e-6, "the sun at 290°: its antipoint at 110°, the camera 28° round")
        XCTAssertLessThanOrEqual(still.greenCast, 0.12)
        XCTAssertGreaterThan(still.greenCast, 0, "green under the core")
        XCTAssertGreaterThan(still.hailDensity, 0.3)
        XCTAssertLessThanOrEqual(still.hailDensity, 1)
        XCTAssertEqual(still.sky.rain, 0, accuracy: 1e-6, "its rain falls 16 km off")
        XCTAssertEqual(still.sky.lightning, 0)
        XCTAssertEqual(still.mood, .stormTense)
        XCTAssertEqual(still.cameraShake, SIMD2<Float>(0, 0))
        // Playing lights its fence post.
        m.handle(.noteOn(note: 60, velocity: 0.9))
        let lit = run(&m, seconds: 0.1)
        let post = try XCTUnwrap(lit.keys.first { $0.key.note == 60 })
        XCTAssertTrue(post.pressed)
        XCTAssertGreaterThan(post.glow, 0.5)
        // Overhead, the core rains on you.
        var over = model()
        let wet = run(&over, seconds: 1, ["distance": .number(1)])
        XCTAssertGreaterThan(wet.sky.rain, 0.4)
        // Galaxy Warp streaks instead; the inflow rests.
        m.handle(.noteOn(note: 72, velocity: 0.9))
        let warped = run(&m, seconds: 0.3, ["visual": .choice("Galaxy Warp")])
        XCTAssertNotNil(warped.warp)
        XCTAssertTrue(warped.glows.isEmpty)
        // Through the director: the sky holds a supercell at the picker's stage.
        let d = SceneDirector(themeID: SupercellSkyModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 18; s.cityID = "melbourne"; s.weatherMode = .pick
        s.weather = .clear
        d.sky.reset(settings: s)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        d.clock = { start }
        var frame: SupercellFrame?
        for i in 1...10 { frame = d.step(dt: 0.1, t: Double(i) * 0.1, quality: .high) as? SupercellFrame }
        let directed = try XCTUnwrap(frame)
        XCTAssertEqual(d.lastSky?.supercell, 1)
        XCTAssertEqual(directed.phase, 0.5, accuracy: 1e-6)
        XCTAssertEqual(directed.sky.sun.altitude, 5, accuracy: 1e-9, "golden hour held")
    }

    /// Spec §8.3: hail on tin follows the hail, the flock's calls only after a moment has lifted it, the inflow's roar
    /// with Energy, the thunder roll always up so the queue plays, and rain on dust before the rain.
    func testSupercellAmbience() {
        let s = evening()
        let lightHail = SupercellSkyModel.levels(s, km: 8, hail: 0.2, energy: 0, tension: 0, clearing: 0, stormRain: 0.6,
                                                 rainHere: 0, outflow: 0, alarm: 0)
        let heavyHail = SupercellSkyModel.levels(s, km: 8, hail: 0.8, energy: 0, tension: 0, clearing: 0, stormRain: 0.6,
                                                 rainHere: 0, outflow: 0, alarm: 0)
        let lightTin = lightHail[.hailOnTin] ?? 0
        let heavyTin = heavyHail[.hailOnTin] ?? 0
        XCTAssertGreaterThan(heavyTin, 3 * lightTin)
        XCTAssertGreaterThan(lightTin, 0)
        let quietRoar = lightHail[.inflowRoar] ?? 0
        let loud = SupercellSkyModel.levels(s, km: 8, hail: 0.2, energy: 1, tension: 0, clearing: 0, stormRain: 0.6,
                                            rainHere: 0, outflow: 0, alarm: 0)
        let loudRoar = loud[.inflowRoar] ?? 0
        XCTAssertGreaterThan(loudRoar, quietRoar + 0.4)
        let roll = lightHail[.thunderRoll] ?? 0
        XCTAssertGreaterThan(roll, 0.5, "the roll is up, so the queue plays")
        let petrichor = lightHail[.rainOnDust] ?? 0
        XCTAssertGreaterThan(petrichor, 0.1, "rain on dust before the rain")
        let birdsQuiet = lightHail[.birdsFlee] ?? 0
        XCTAssertEqual(birdsQuiet, 0)

        // Through the model: the Core's hail is heavier than the Approach's, and the drop's heavier still.
        var approach = model()
        let far = run(&approach, seconds: 1, ["supercell.stage": .choice("Approach")])
        var core = model()
        let near = run(&core, seconds: 1)
        let farTin = far.ambience.level(.hailOnTin)
        let nearTin = near.ambience.level(.hailOnTin)
        XCTAssertGreaterThan(nearTin, farTin)
        let silentFlock = near.ambience.level(.birdsFlee)
        XCTAssertEqual(silentFlock, 0, "no calls before a moment")
        core.setExcitement(moment(0.9, drop: true))
        let dropped = run(&core, seconds: 1)
        let droppedTin = dropped.ambience.level(.hailOnTin)
        XCTAssertGreaterThan(droppedTin, nearTin)
        let fleeingFlock = dropped.ambience.level(.birdsFlee)
        XCTAssertGreaterThan(fleeingFlock, 0, "the flock calls as it flees")
        var played = model()
        played.setExcitement(excitement(energy: 1))
        let roaring = run(&played, seconds: 1)
        let roar = roaring.ambience.level(.inflowRoar)
        let hush = near.ambience.level(.inflowRoar)
        XCTAssertGreaterThan(roar, hush + 0.3)
    }
}
