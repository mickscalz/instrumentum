import XCTest
import simd
@testable import InStrumCore

/// The shared wind field (Storms spec §10, plan Task 1). The bounds were set against a float32 Python mirror of the
/// field (the same hash, noise and constants): the breathing peaks at 0.150 of the steady speed with an RMS of about
/// 0.07, its mean over a 400 m square is within 0.2% of the steady flow, and carried downwind it matches itself
/// 0.5 s later about six times better than it matches itself where it stood.
final class WindFieldTests: XCTestCase {
    private func run(_ f: inout WindField, seconds: Double, dt: Double = 1.0 / 60) {
        for _ in 0..<Int((seconds / dt).rounded()) { f.step(dt: dt) }
    }

    /// Points on a square grid, `n` × `n`, `half` metres either side of the origin.
    private func grid(_ n: Int, _ half: Float) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for j in 0..<n {
            for i in 0..<n {
                let u = Float(i) / Float(n - 1), v = Float(j) / Float(n - 1)
                points.append(SIMD2(-half + 2 * half * u, -half + 2 * half * v))
            }
        }
        return points
    }

    /// Where along a line from `start` heading `heading` a field blows hardest (scanned every 5 cm over `length` m).
    private func crest(_ f: WindField, from start: SIMD2<Float>, heading: SIMD2<Float>, length: Float) -> Float {
        var best: Float = 0, at: Float = 0
        for k in 0...Int(length / 0.05) {
            let s = Float(k) * 0.05
            let m = simd_length(f.sample(start + heading * s))
            if m > best { best = m; at = s }
        }
        return at
    }

    /// The angle between two vectors (degrees), well conditioned near 0° too.
    private func angleDegrees(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        atan2(abs(a.x * b.y - a.y * b.x), simd_dot(a, b)) * 180 / .pi
    }

    /// With the breathing off, the steady flow is the same everywhere, exactly, and follows `set(steady:)` at once.
    /// With it on, every point stays within 15% of the steady speed of it and the field's mean is the steady flow.
    func testSteadyFlowIsUniform() {
        var f = WindField(extent: 200, seed: 1)
        let steady = SIMD2<Float>(6, -2.5)
        f.set(steady: steady)
        f.breathing = 0
        run(&f, seconds: 2)
        for p in grid(17, 300) { XCTAssertEqual(f.sample(p), steady, "at \(p)") }
        f.set(steady: SIMD2(0, 3))
        for p in grid(9, 300) { XCTAssertEqual(f.sample(p), SIMD2(0, 3), "at \(p)") }

        f.set(steady: steady)
        f.breathing = 1
        let speed = simd_length(steady)
        var sum = SIMD2<Float>.zero, spread: Float = 0
        let points = grid(41, 200)
        for p in points {
            let v = f.sample(p)
            XCTAssertLessThanOrEqual(simd_length(v - steady), 0.15 * speed * 1.000_01, "at \(p)")
            spread = max(spread, simd_length(v - steady))
            sum += v
        }
        XCTAssertLessThan(simd_length(sum / Float(points.count) - steady), 0.02 * speed, "it breathes about the steady flow")
        XCTAssertGreaterThan(spread, 0.05 * speed, "and it does breathe")

        // The default field is calm.
        let calm = WindField()
        XCTAssertEqual(calm.sample(SIMD2(12, -40)), .zero)
        XCTAssertEqual(calm.extent, 250)
    }

    /// The crest moves 15 m in 1 s at speed 15, in any direction; with no direction it heads for the field's centre.
    func testGustTravelsAtItsSpeed() {
        var f = WindField(extent: 200, seed: 2)
        f.addGust(from: SIMD2(-120, 0), direction: SIMD2(1, 0), speed: 15, width: 24, strength: 8)
        let start = SIMD2<Float>(-200, 0), east = SIMD2<Float>(1, 0)
        run(&f, seconds: 1)
        let first = crest(f, from: start, heading: east, length: 400) - 200
        XCTAssertEqual(first, -105, accuracy: 0.06, "15 m from where it set out after 1 s")
        run(&f, seconds: 1)
        let second = crest(f, from: start, heading: east, length: 400) - 200
        XCTAssertEqual(second - first, 15, accuracy: 0.06, "15 m in the next second")
        XCTAssertEqual(f.gust(at: 0)?.crest.x ?? 0, -90, accuracy: 0.01)
        XCTAssertEqual(f.gust(at: 0)?.travelled ?? 0, 30, accuracy: 0.01)
        XCTAssertGreaterThan(f.sample(SIMD2(-90, 37)).x, 7.9, "it blows the way it travels")

        // From the north-east with no direction given: it heads for the centre, (−0.6, −0.8), at the same speed.
        var g = WindField(extent: 200, seed: 2)
        let origin = SIMD2<Float>(60, 80)
        g.addGust(from: origin, speed: 15, width: 24, strength: 8)
        let heading = g.gust(at: 0)?.direction ?? .zero
        XCTAssertEqual(heading.x, -0.6, accuracy: 1e-5)
        XCTAssertEqual(heading.y, -0.8, accuracy: 1e-5)
        run(&g, seconds: 1)
        let one = crest(g, from: origin, heading: heading, length: 60)
        run(&g, seconds: 1)
        let two = crest(g, from: origin, heading: heading, length: 60)
        XCTAssertEqual(one, 15, accuracy: 0.06)
        XCTAssertEqual(two - one, 15, accuracy: 0.06)
        let v = g.sample(origin + heading * two)
        XCTAssertLessThan(angleDegrees(v, heading), 0.01)

        // A direction that isn't a unit vector is made one.
        var h = WindField(extent: 200, seed: 2)
        h.addGust(from: .zero, direction: SIMD2(3, 4), speed: 15, width: 24, strength: 8)
        XCTAssertEqual(simd_length(h.gust(at: 0)?.direction ?? .zero), 1, accuracy: 1e-6)
        run(&h, seconds: 2)
        XCTAssertEqual(crest(h, from: .zero, heading: SIMD2(0.6, 0.8), length: 60), 30, accuracy: 0.06)
    }

    /// A gust is a raised cosine front to back: its strength at the crest, half of it a quarter-width either side, zero
    /// from half its width on, the same all along a front. With a span it is a patch, raised-cosine side to side too.
    /// It fades in as it sets out (so a gust born in view never pops) and blows only along its travel.
    func testGustIsRaisedCosine() {
        var f = WindField(extent: 200, seed: 3)
        f.addGust(from: SIMD2(0, -150), direction: SIMD2(0, 1), speed: 10, width: 40, strength: 5)
        for _ in 0..<6 { f.step(dt: 0.5) }   // 3 s exactly: the crest at y = −120, faded in long since (1.5 s)
        XCTAssertEqual(f.gust(at: 0)?.level, 1)
        var peak: Float = 0
        for k in -60...60 {
            let s = Float(k) * 0.5
            for x: Float in [-180, 17, 170] {
                let v = f.sample(SIMD2(x, -120 + s))
                let expected: Float = abs(s) < 20 ? 5 * (0.5 + 0.5 * cos(.pi * s / 20)) : 0
                XCTAssertEqual(v.y, expected, accuracy: 1e-3, "at \(s) m from the crest")
                XCTAssertEqual(v.x, 0, accuracy: 1e-6)
                if abs(s) > 20 { XCTAssertEqual(v, .zero, "nothing outside its width (\(s))") }
                peak = max(peak, v.y)
            }
        }
        XCTAssertEqual(f.sample(SIMD2(17, -120)).y, 5, accuracy: 1e-4, "its strength at the crest")
        XCTAssertEqual(peak, 5, accuracy: 1e-4, "and nowhere stronger")
        XCTAssertEqual(f.sample(SIMD2(17, -110)).y, 2.5, accuracy: 1e-3, "half a quarter-width ahead")
        XCTAssertEqual(f.sample(SIMD2(17, -130)).y, 2.5, accuracy: 1e-3, "and behind")

        // A patch 60 m side to side.
        var p = WindField(extent: 200, seed: 3)
        p.addGust(from: SIMD2(0, -150), direction: SIMD2(0, 1), speed: 10, width: 40, strength: 5, span: 60)
        for _ in 0..<6 { p.step(dt: 0.5) }
        XCTAssertEqual(p.sample(SIMD2(0, -120)).y, 5, accuracy: 1e-4)
        XCTAssertEqual(p.sample(SIMD2(15, -120)).y, 2.5, accuracy: 1e-3)
        XCTAssertEqual(p.sample(SIMD2(-15, -120)).y, 2.5, accuracy: 1e-3)
        XCTAssertEqual(p.sample(SIMD2(30, -120)), .zero)
        XCTAssertEqual(p.sample(SIMD2(-31, -120)), .zero)

        // It fades in over the time its leading half takes to leave the origin (2 s here, held to 1.5 s).
        var q = WindField(extent: 200, seed: 3)
        q.addGust(from: SIMD2(0, -150), direction: SIMD2(0, 1), speed: 10, width: 40, strength: 5)
        var last: Float = -1
        for _ in 0..<4 {
            let g = q.gust(at: 0)!
            let atCrest = q.sample(g.crest).y
            XCTAssertGreaterThan(atCrest, last, "rising")
            XCTAssertLessThanOrEqual(atCrest, 5 * g.level + 1e-5)
            last = atCrest
            q.step(dt: 0.5)
        }
        XCTAssertEqual(last, 5, accuracy: 1e-4, "all of it by 1.5 s")
        var born = WindField()
        born.addGust(from: SIMD2(5, 5), speed: 10, width: 40, strength: 5)
        XCTAssertEqual(born.sample(SIMD2(5, 5)), .zero, "nothing at the moment it sets out")

        // A lull: a negative strength pushes back against its travel.
        var lull = WindField(extent: 200, seed: 3)
        lull.addGust(from: SIMD2(0, -150), direction: SIMD2(0, 1), speed: 10, width: 40, strength: -2)
        for _ in 0..<6 { lull.step(dt: 0.5) }
        XCTAssertEqual(lull.sample(SIMD2(0, -120)).y, -2, accuracy: 1e-4)
    }

    /// A vortex circulates: on rings inside and outside its radius the wind is tangential within 5°, fastest at its
    /// radius (its strength there), calm in its eye and nothing beyond its reach. It drifts, turns either way, and
    /// with an inflow it spirals in.
    func testVortexCirculates() {
        let centre = SIMD2<Float>(20, -10)
        var f = WindField(extent: 200, seed: 4)
        f.addVortex(at: centre, radius: 4, strength: 12, drift: .zero)
        XCTAssertEqual(f.sample(centre + SIMD2(4, 0)), .zero, "it spins up from nothing")
        for _ in 0..<8 { f.step(dt: 0.25) }   // 2 s: spun up (1.5 s)
        var speeds: [Float] = []
        for r: Float in [1, 2, 4, 8, 16, 24] {
            var ring: Float = 0
            for k in 0..<36 {
                let a = Float(k) * 10 * .pi / 180
                let out = SIMD2<Float>(cos(a), sin(a))
                let v = f.sample(centre + out * r)
                XCTAssertLessThan(angleDegrees(v, SIMD2(-out.y, out.x)), 5, "anticlockwise at r \(r), \(k * 10)°")
                ring = max(ring, simd_length(v))
            }
            speeds.append(ring)
        }
        XCTAssertEqual(speeds[2], 12, accuracy: 0.01, "its strength at its radius")
        XCTAssertLessThan(speeds[1], speeds[2])
        XCTAssertLessThan(speeds[3], speeds[2])
        XCTAssertTrue(zip(speeds.dropFirst(2), speeds.dropFirst(3)).allSatisfy { $0 > $1 }, "slower further out")
        XCTAssertEqual(f.sample(centre), .zero, "calm in its eye")
        XCTAssertLessThan(simd_length(f.sample(centre + SIMD2(0.05, 0))), 0.5)
        XCTAssertEqual(f.sample(centre + SIMD2(32.5, 0)), .zero, "nothing beyond eight radii")
        XCTAssertEqual(f.vortex(at: 0)?.reach, 32)

        // Clockwise.
        var cw = WindField(extent: 200, seed: 4)
        cw.addVortex(at: .zero, radius: 4, strength: -12, drift: .zero)
        cw.step(dt: 1); cw.step(dt: 1)
        let north = cw.sample(SIMD2(0, 8))   // north of the eye: clockwise blows east
        XCTAssertLessThan(angleDegrees(north, SIMD2(1, 0)), 5)

        // It drifts: its calm eye goes with it.
        var d = WindField(extent: 200, seed: 4)
        d.addVortex(at: centre, radius: 4, strength: 12, drift: SIMD2(3, 1))
        for _ in 0..<16 { d.step(dt: 0.25) }   // 4 s
        let moved = d.vortex(at: 0)?.centre ?? .zero
        XCTAssertEqual(moved.x, 32, accuracy: 1e-4)
        XCTAssertEqual(moved.y, -6, accuracy: 1e-4)
        XCTAssertLessThan(simd_length(d.sample(moved + SIMD2(0.01, 0))), 0.2)
        XCTAssertGreaterThan(simd_length(d.sample(centre)), 1, "where it was is windy now")

        // An inflow of 0.3 spirals in: inward 0.3 of the swirl everywhere, so the swirl itself is unchanged.
        var s = WindField(extent: 200, seed: 4)
        s.addVortex(at: .zero, radius: 4, strength: 12, drift: .zero, inflow: 0.3)
        for _ in 0..<8 { s.step(dt: 0.25) }
        for k in 0..<12 {
            let a = Float(k) * 30 * .pi / 180
            let out = SIMD2<Float>(cos(a), sin(a))
            let w = s.sample(out * 8)
            let swirl = simd_dot(w, SIMD2(-out.y, out.x)), inward = -simd_dot(w, out)
            XCTAssertEqual(inward / swirl, 0.3, accuracy: 1e-3)
            XCTAssertEqual(swirl, speeds[3], accuracy: 1e-3)
        }
    }

    /// The field is the sum of its parts: the steady flow and its breathing, each gust and each vortex, exactly as
    /// each would blow alone, at every point and every moment.
    func testSuperposition() {
        func make() -> WindField { WindField(extent: 150, seed: 5) }
        var all = make(), still = make(), gusty = make(), swirl = make()
        all.set(steady: SIMD2(4, 1))
        still.set(steady: SIMD2(4, 1))
        all.addGust(from: SIMD2(-100, 20), direction: SIMD2(1, 0.2), speed: 12, width: 30, strength: 6)
        gusty.addGust(from: SIMD2(-100, 20), direction: SIMD2(1, 0.2), speed: 12, width: 30, strength: 6)
        all.addGust(from: SIMD2(0, 100), speed: 8, width: 50, strength: 3, span: 80)
        gusty.addGust(from: SIMD2(0, 100), speed: 8, width: 50, strength: 3, span: 80)
        all.addVortex(at: SIMD2(-20, 0), radius: 5, strength: 9, drift: SIMD2(1, 0.5))
        swirl.addVortex(at: SIMD2(-20, 0), radius: 5, strength: 9, drift: SIMD2(1, 0.5))

        let points = grid(9, 120)
        var gustPeak: Float = 0, swirlPeak: Float = 0, checks = 0
        for frame in 1...600 {
            all.step(dt: 1.0 / 60); still.step(dt: 1.0 / 60); gusty.step(dt: 1.0 / 60); swirl.step(dt: 1.0 / 60)
            guard frame % 60 == 0 else { continue }
            for p in points {
                let parts = still.sample(p) + gusty.sample(p) + swirl.sample(p)
                let whole = all.sample(p)
                XCTAssertEqual(whole.x, parts.x, accuracy: 1e-4, "at \(p), frame \(frame)")
                XCTAssertEqual(whole.y, parts.y, accuracy: 1e-4, "at \(p), frame \(frame)")
                gustPeak = max(gustPeak, simd_length(gusty.sample(p)))
                swirlPeak = max(swirlPeak, simd_length(swirl.sample(p)))
                checks += 1
            }
        }
        XCTAssertEqual(checks, 810)
        XCTAssertGreaterThan(gustPeak, 3, "the gusts crossed the grid")
        XCTAssertGreaterThan(swirlPeak, 3, "and so did the vortex")
        XCTAssertEqual(still.turbulence(at: SIMD2(7, 7)), all.turbulence(at: SIMD2(7, 7)), "one breathing for both")
        XCTAssertEqual(gusty.turbulence(at: SIMD2(7, 7)), .zero, "no steady flow, no breathing")
    }

    /// A gust ends once its crest has passed twice the field's extent downwind (a wide one once its back has left the
    /// field too). A fifth gust replaces the oldest, a free slot is used before any is replaced, and vortices end at
    /// their lifetime or once they have drifted out, a third replacing the oldest.
    func testGustsExpireAndRecycle() {
        var f = WindField(extent: 100, seed: 6)
        f.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 20, width: 20, strength: 5)
        for _ in 0..<30 { f.step(dt: 0.5) }   // 15 s: the crest exactly at 2 × 100 m
        XCTAssertEqual(f.gustCount, 1)
        f.step(dt: 0.5)
        XCTAssertEqual(f.gustCount, 0, "past twice the extent")
        XCTAssertNil(f.gust(at: 0))
        for p in grid(5, 300) { XCTAssertEqual(f.sample(p), .zero) }

        var wide = WindField(extent: 100, seed: 6)
        wide.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 20, width: 300, strength: 5)
        for _ in 0..<32 { wide.step(dt: 0.5) }   // 16 s: the crest at 220 m but its back at 70 m, still in the field
        XCTAssertEqual(wide.gustCount, 1)
        XCTAssertGreaterThan(wide.sample(SIMD2(90, 0)).x, 0)
        for _ in 0..<4 { wide.step(dt: 0.5) }    // 18 s: its back at 110 m
        XCTAssertEqual(wide.gustCount, 0)

        // Oldest first.
        var r = WindField(extent: 100, seed: 6)
        func strengths(_ w: WindField) -> Set<Float> {
            var s = Set<Float>()
            for slot in 0..<WindField.maxGusts { if let g = w.gust(at: slot) { s.insert(g.strength) } }
            return s
        }
        for i in 1...4 {
            r.addGust(from: SIMD2(-100, Float(i) * 10), direction: SIMD2(1, 0), speed: 5, width: 20, strength: Float(i))
            r.step(dt: 0.25)
        }
        XCTAssertEqual(r.gustCount, 4)
        XCTAssertEqual(strengths(r), [1, 2, 3, 4])
        r.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 5, width: 20, strength: 5)
        XCTAssertEqual(r.gustCount, 4)
        XCTAssertEqual(strengths(r), [2, 3, 4, 5], "the oldest made way")
        r.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 5, width: 20, strength: 6)
        XCTAssertEqual(strengths(r), [3, 4, 5, 6])
        XCTAssertEqual(WindField.maxGusts, 4)

        // A free slot first: a fast gust leaves, and the next takes its place without displacing the slow ones.
        var e = WindField(extent: 100, seed: 6)
        e.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 100, width: 20, strength: 9)
        for i in 1...3 { e.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 1, width: 20, strength: Float(i)) }
        for _ in 0..<8 { e.step(dt: 0.5) }   // 4 s: the fast one is 400 m on, gone
        XCTAssertEqual(strengths(e), [1, 2, 3])
        e.addGust(from: SIMD2(-100, 0), direction: SIMD2(1, 0), speed: 5, width: 20, strength: 7)
        XCTAssertEqual(strengths(e), [1, 2, 3, 7])

        // Vortices: drifting out, a lifetime (spinning down before it ends), and the oldest making way.
        var v = WindField(extent: 100, seed: 6)
        v.addVortex(at: .zero, radius: 2, strength: 10, drift: SIMD2(50, 0))
        for _ in 0..<8 { v.step(dt: 0.5) }   // 4 s: exactly 2 × 100 m out
        XCTAssertEqual(v.vortexCount, 1)
        v.step(dt: 0.5)
        XCTAssertEqual(v.vortexCount, 0, "drifted out of the field")

        var life = WindField(extent: 100, seed: 6)
        life.addVortex(at: .zero, radius: 2, strength: 10, drift: .zero, lifetime: 6)
        for _ in 0..<10 { life.step(dt: 0.5) }   // 5 s: spinning down over its last 2
        let fading = life.vortex(at: 0)?.level ?? 0
        XCTAssertGreaterThan(fading, 0)
        XCTAssertLessThan(fading, 1)
        XCTAssertLessThan(simd_length(life.sample(SIMD2(2, 0))), 10)
        life.step(dt: 0.5); life.step(dt: 0.5)
        XCTAssertEqual(life.vortexCount, 0, "ended at its lifetime")

        var three = WindField(extent: 100, seed: 6)
        three.addVortex(at: SIMD2(-10, 0), radius: 2, strength: 1, drift: .zero)
        three.step(dt: 0.25)
        three.addVortex(at: SIMD2(10, 0), radius: 2, strength: 2, drift: .zero)
        three.step(dt: 0.25)
        three.addVortex(at: SIMD2(0, 10), radius: 2, strength: 3, drift: .zero)
        XCTAssertEqual(three.vortexCount, 2)
        let left = Set((0..<WindField.maxVortices).compactMap { three.vortex(at: $0)?.strength })
        XCTAssertEqual(left, [2, 3])
        XCTAssertNil(three.vortex(at: 2))
        XCTAssertNil(three.gust(at: -1))
    }

    /// The breathing is seeded (the same seed, the same breath; another seed, another), never more than 0.15 of the
    /// steady speed (scaled by `breathing`), changes over time at a point, and is carried downwind with the flow.
    func testTurbulenceIsBoundedAndSeeded() {
        var a = WindField(extent: 200, seed: 11), b = WindField(extent: 200, seed: 11), c = WindField(extent: 200, seed: 12)
        let steady = SIMD2<Float>(8, 3), speed = simd_length(steady)
        a.set(steady: steady)
        b.set(steady: steady)
        c.set(steady: steady)
        let points = grid(21, 200)
        var peak: Float = 0, apart: Float = 0, samples = 0
        var atOnePoint: [SIMD2<Float>] = []
        for frame in 1...900 {   // 30 s
            a.step(dt: 1.0 / 30); b.step(dt: 1.0 / 30); c.step(dt: 1.0 / 30)
            guard frame % 30 == 0 else { continue }
            for p in points {
                let t = a.turbulence(at: p)
                XCTAssertLessThanOrEqual(simd_length(t), WindField.breathingDepth * speed * 1.000_01, "at \(p)")
                XCTAssertEqual(t, b.turbulence(at: p), "the same seed breathes the same")
                XCTAssertEqual(a.sample(p), steady + t)
                peak = max(peak, simd_length(t))
                apart += simd_length(t - c.turbulence(at: p))
                samples += 1
            }
            atOnePoint.append(a.turbulence(at: SIMD2(30, -50)))
        }
        XCTAssertEqual(WindField.breathingDepth, 0.15)
        XCTAssertGreaterThan(peak, 0.12 * speed, "it uses its depth")
        XCTAssertGreaterThan(apart / Float(samples), 0.04 * speed, "another seed, another breath")
        let mean = atOnePoint.reduce(SIMD2<Float>.zero, +) / Float(atOnePoint.count)
        let wander = atOnePoint.map { simd_length($0 - mean) }.max() ?? 0
        XCTAssertGreaterThan(wander, 0.04 * speed, "it changes over time where you stand")

        // Carried downwind: 0.5 s on, the breath at p is the breath that was 4 m upwind of it (8 × 0.5 by 3 × 0.5),
        // far more than the breath that was at p.
        var w = WindField(extent: 200, seed: 11)
        w.set(steady: steady)
        for _ in 0..<60 { w.step(dt: 1.0 / 30) }
        let near = grid(41, 150)
        let before = near.map { w.turbulence(at: $0) }
        let upwind = near.map { w.turbulence(at: $0 - steady * 0.5) }
        for _ in 0..<15 { w.step(dt: 1.0 / 30) }
        let after = near.map { w.turbulence(at: $0) }
        let carried = zip(after, upwind).map { simd_length($0 - $1) }.reduce(0, +)
        let stood = zip(after, before).map { simd_length($0 - $1) }.reduce(0, +)
        XCTAssertLessThan(carried, 0.4 * stood, "the pattern rolls downwind with the flow")

        // Its depth: `breathing` scales it, 0 stills it, and it is proportional to the steady speed.
        var half = WindField(extent: 200, seed: 11)
        half.set(steady: steady)
        let full = half.turbulence(at: SIMD2(33, 44))
        XCTAssertGreaterThan(simd_length(full), 0)
        half.breathing = 0.5
        XCTAssertEqual(simd_length(half.turbulence(at: SIMD2(33, 44)) - full * 0.5), 0, accuracy: 1e-6)
        half.breathing = 0
        XCTAssertEqual(half.turbulence(at: SIMD2(33, 44)), .zero)
        half.breathing = 7
        XCTAssertEqual(half.turbulence(at: SIMD2(33, 44)), full, "held to 1")
        var double = WindField(extent: 200, seed: 11)
        double.set(steady: steady * 2)
        XCTAssertEqual(simd_length(double.turbulence(at: SIMD2(33, 44)) - full * 2), 0, accuracy: 1e-5)
        let still = WindField(extent: 200, seed: 11)
        XCTAssertEqual(still.turbulence(at: SIMD2(33, 44)), .zero, "no wind, no breath")
    }

    /// Nothing is allocated after `init`. There is no counting-allocator seam in this target, and Darwin's malloc
    /// statistics count blocks in use, not allocations made, so a temporary allocation would slip past them; instead
    /// the field is held to plain inline data (POD: no arrays, no references), so there is nothing it could allocate,
    /// retain or release when it is copied, stepped or sampled, and a copy shares nothing with the original.
    func testNoAllocationAfterInit() {
        XCTAssertTrue(_isPOD(WindField.self), "plain inline data only")
        XCTAssertTrue(_isPOD(WindField.Gust.self))
        XCTAssertTrue(_isPOD(WindField.Vortex.self))
        XCTAssertLessThanOrEqual(MemoryLayout<WindField>.size, 512, "four gusts, two vortices and the breath, inline")

        var f = WindField(extent: 200, seed: 9)
        f.set(steady: SIMD2(5, 2))
        for i in 0..<4 { f.addGust(from: SIMD2(-150, Float(i) * 20), speed: 12, width: 30, strength: 4, span: 90) }
        f.addVortex(at: SIMD2(-30, 10), radius: 4, strength: 8, drift: SIMD2(1, 0), inflow: 0.2)
        f.addVortex(at: SIMD2(40, -20), radius: 6, strength: -6, drift: SIMD2(0, 1), lifetime: 30)
        run(&f, seconds: 3)

        let frozen = f
        let probe = SIMD2<Float>(-20, 5)
        let before = frozen.sample(probe)
        var sum = SIMD2<Float>.zero
        for i in 0..<10_000 {
            sum += frozen.sample(SIMD2(Float(i % 100) * 3 - 150, Float(i / 100) * 3 - 150))
        }
        XCTAssertTrue(sum.x.isFinite && sum.y.isFinite)
        XCTAssertEqual(frozen, f, "sampling changes nothing")

        f.step(dt: 0.5)
        f.addGust(from: SIMD2(0, 150), speed: 20, width: 40, strength: 10)
        f.set(steady: SIMD2(-3, 0))
        XCTAssertNotEqual(frozen, f)
        XCTAssertEqual(frozen.sample(probe), before, "a copy shares nothing with the original")
    }

    /// Odd inputs (NaN, infinities, huge or negative values) never make the field non-finite or stick it.
    func testOddInputsStayFinite() {
        var f = WindField(extent: .nan, seed: 0)
        XCTAssertEqual(f.extent, 250)
        f.set(steady: SIMD2(.nan, .infinity))
        XCTAssertEqual(f.steady, SIMD2(0, 100))
        f.breathing = .nan
        f.addGust(from: SIMD2(.infinity, -.infinity), direction: SIMD2(.nan, .nan), speed: .nan, width: -5, strength: .infinity, span: .nan)
        f.addGust(from: .zero, speed: 0, width: .infinity, strength: .nan, span: -3)
        f.addGust(from: SIMD2(1e30, 1e30), direction: SIMD2(1e30, -1e30), speed: 1e9, width: 1e9, strength: 1e9)
        f.addVortex(at: SIMD2(.nan, 3), radius: 0, strength: .nan, drift: SIMD2(.infinity, .nan), inflow: 9, lifetime: -1)
        f.addVortex(at: SIMD2(1, 1), radius: .infinity, strength: 1e9, drift: .zero, inflow: .nan, lifetime: .nan)
        let steps: [Double] = [.nan, -1, .infinity, 1e9, 0, 1.0 / 60, 0.25]
        let odd: [SIMD2<Float>] = [SIMD2(.nan, .nan), SIMD2(.infinity, -.infinity), SIMD2(1e30, -1e30), .zero, SIMD2(3, -7)]
        for dt in steps {
            f.step(dt: dt)
            for p in odd {
                let v = f.sample(p)
                XCTAssertTrue(v.x.isFinite && v.y.isFinite, "dt \(dt), p \(p)")
                let t = f.turbulence(at: p)
                XCTAssertTrue(t.x.isFinite && t.y.isFinite)
            }
        }
        for slot in 0..<WindField.maxGusts {
            if let g = f.gust(at: slot) {
                XCTAssertTrue(g.speed >= 0.5 && g.width >= 1 && g.strength.isFinite && g.direction.x.isFinite)
            }
        }
        // A long run with a strong steady flow keeps the breath's carry and phase wrapped and the samples finite.
        var long = WindField(seed: 3)
        long.set(steady: SIMD2(100, -100))
        for _ in 0..<20_000 { long.step(dt: 1) }
        let after = long.sample(SIMD2(17, 23))
        XCTAssertTrue(after.x.isFinite && after.y.isFinite)
        XCTAssertLessThanOrEqual(simd_length(long.turbulence(at: SIMD2(17, 23))), 0.15 * simd_length(long.steady) * 1.000_01)
    }
}
