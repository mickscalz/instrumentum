import XCTest
import simd
@testable import InStrumCore

final class CoralPulseTests: XCTestCase {
    private func run(_ c: inout CoralPulse, seconds: Double, dt: Double = 1.0 / 60, roles: RoleValues = RoleValues()) {
        for _ in 0..<max(1, Int((seconds / dt).rounded())) { c.step(dt: dt, roles: roles) }
    }

    /// Spec §9.2: seven coral groups across the frame, the keyboard in seven stretches of about an octave, bass to
    /// treble from left to right (brain corals, plate and soft corals, staghorn tips). Each note opens and lights a patch
    /// of polyps on the group nearest its key, and on no other, as bright as it was struck (0.4 + 0.6 × velocity); held
    /// (or pedalled) notes keep it glowing, and it fades with τ 2.5 s after release.
    func testNotesLightTheNearestCoralGroup() throws {
        XCTAssertEqual(CoralPulse.groupCount, 7)
        XCTAssertEqual(CoralPulse.groupX.count, 7)
        XCTAssertEqual(CoralPulse.kinds, [.brain, .brain, .plate, .soft, .plate, .staghorn, .staghorn])
        XCTAssertEqual(CoralPulse.groupX.first ?? 0, 0.06 + 0.88 / 14, accuracy: 1e-6)
        XCTAssertEqual(CoralPulse.groupX.last ?? 0, 0.94 - 0.88 / 14, accuracy: 1e-6)
        XCTAssertEqual(CoralPulse.groupX, CoralPulse.groupX.sorted(), "left to right")
        var previous = 0
        for n in UInt8(21)...UInt8(108) {
            let g = CoralPulse.group(for: n), x = CoralPulse.x(for: n)
            let nearest = try XCTUnwrap(CoralPulse.groupX.indices.min(by: {
                abs(CoralPulse.groupX[$0] - x) < abs(CoralPulse.groupX[$1] - x)
            }))
            XCTAssertEqual(g, nearest, "note \(n)")
            XCTAssertGreaterThanOrEqual(g, previous, "note \(n): bass to treble, left to right")
            previous = g
        }
        XCTAssertEqual(([21, 33, 46, 59, 72, 84, 97] as [UInt8]).map { CoralPulse.group(for: $0) }, [0, 1, 2, 3, 4, 5, 6],
                       "where each stretch begins")
        XCTAssertEqual(([32, 45, 58, 71, 83, 96, 108] as [UInt8]).map { CoralPulse.group(for: $0) }, [0, 1, 2, 3, 4, 5, 6],
                       "and ends")
        XCTAssertEqual(CoralPulse.group(for: 60), 3, "middle C lights the soft corals in the middle")
        XCTAssertEqual(CoralPulse.group(for: 0), 0, "below the keyboard: the lowest group")
        XCTAssertEqual(CoralPulse.group(for: 127), 6, "above it: the highest")

        // Each note lights its own group's polyps, and no other group's; each group keeps its own fluorescence.
        let cases: [(note: UInt8, group: Int)] = [(30, 0), (40, 1), (50, 2), (60, 3), (77, 4), (90, 5), (100, 6)]
        for (note, group) in cases {
            var c = CoralPulse()
            c.noteOn(note, velocity: 0.8, at: 0)
            run(&c, seconds: 0.5)
            XCTAssertEqual(c.patches.count, 1)
            let p = try XCTUnwrap(c.patches.first)
            XCTAssertEqual(p.group, group, "note \(note)")
            XCTAssertEqual(p.note, note)
            XCTAssertEqual(p.x, CoralPulse.x(for: note), accuracy: 1e-6)
            XCTAssertEqual(p.y, CoralPulse.groupTop[group] * (0.6 + 0.4 * 0.8), accuracy: 1e-6)
            XCTAssertEqual(p.brightness, 0.88, accuracy: 1e-5)
            XCTAssertTrue(p.held)
            XCTAssertEqual(c.groups.count, 7)
            for g in 0..<7 {
                XCTAssertEqual(c.groups[g].glow, g == group ? 0.88 : 0, accuracy: 1e-5, "note \(note), group \(g)")
                XCTAssertEqual(c.groups[g].hue, CoralPulse.hues[g], accuracy: 1e-6, "no chord, no wave: its own colour")
                XCTAssertEqual(c.groups[g].kind, CoralPulse.kinds[g])
                XCTAssertEqual(c.groups[g].x, CoralPulse.groupX[g])
            }
        }
        // Fluorescent green, orange or pink by group.
        let palette = CoralPulse.hues.map { CoralPulse.rgb(hue: $0) }
        XCTAssertTrue(palette.allSatisfy { $0.max() == 1 }, "fully saturated")
        XCTAssertGreaterThan(palette[0].y, palette[0].x + 0.5, "the bass's brain corals glow green")
        XCTAssertTrue(palette[1].x == 1 && palette[1].y > 0.3 && palette[1].z < 0.1, "orange")
        XCTAssertTrue(palette[3].x == 1 && palette[3].z > 0.3 && palette[3].y < 0.1, "pink")
        XCTAssertEqual(CoralPulse.rgb(hue: 0), SIMD3<Float>(1, 0, 0))
        XCTAssertLessThan(simd_distance(CoralPulse.rgb(hue: 1.0 / 3), SIMD3<Float>(0, 1, 0)), 1e-5)
        XCTAssertLessThan(simd_distance(CoralPulse.rgb(hue: 2.0 / 3), SIMD3<Float>(0, 0, 1)), 1e-5)

        // Brightness follows velocity; two notes on one group glow together (their soft union), never past 1.
        var soft = CoralPulse()
        soft.noteOn(60, velocity: 0, at: 0)
        run(&soft, seconds: 0.1)
        XCTAssertEqual(soft.groups[3].glow, 0.4, accuracy: 1e-5)
        var hard = CoralPulse()
        hard.noteOn(60, velocity: 1, at: 0)
        run(&hard, seconds: 0.1)
        XCTAssertEqual(hard.groups[3].glow, 1, accuracy: 1e-6)
        var two = CoralPulse()
        two.noteOn(60, velocity: 0.8, at: 0)
        two.noteOn(64, velocity: 0.8, at: 0.3)
        run(&two, seconds: 0.5)
        XCTAssertEqual(two.groups[3].glow, 1 - 0.12 * 0.12, accuracy: 1e-5)
        // The mood's reaction brightens it (at most 1).
        var lively = CoralPulse()
        lively.reactionScale = 1.1
        lively.noteOn(60, velocity: 0.5, at: 0)
        run(&lively, seconds: 0.1)
        XCTAssertEqual(lively.patches.first?.brightness ?? 0, 0.7 * 1.1, accuracy: 1e-5)

        // Held, it stays lit; released, it fades with τ 2.5 s (± 10%), and is gone once it has faded.
        var c = CoralPulse()
        c.noteOn(72, velocity: 1, at: 0)
        for _ in 0..<120 {
            c.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertEqual(c.groups[4].glow, 1, accuracy: 1e-6)
        }
        c.noteOff(72)
        run(&c, seconds: 2.5)
        let p = try XCTUnwrap(c.patches.first)
        XCTAssertFalse(p.held)
        XCTAssertGreaterThan(p.brightness, Float(exp(-2.5 / 2.25)))
        XCTAssertLessThan(p.brightness, Float(exp(-2.5 / 2.75)))
        XCTAssertEqual(c.groups[4].glow, p.brightness, accuracy: 1e-6)
        run(&c, seconds: 15)
        XCTAssertTrue(c.patches.isEmpty)
        XCTAssertEqual(c.groups[4].glow, 0)
        // Lingering doubles it (τ 5 s); the pedal keeps a released note lit until it comes up.
        var linger = RoleValues()
        linger[.linger] = 1
        var l = CoralPulse()
        l.noteOn(72, velocity: 1, at: 0)
        run(&l, seconds: 0.5, roles: linger)
        l.noteOff(72)
        run(&l, seconds: 5, roles: linger)
        XCTAssertEqual(l.patches.first?.brightness ?? 0, Float(exp(-1.0)), accuracy: 0.03)
        var pedal = CoralPulse()
        pedal.setPedal(true)
        pedal.noteOn(50, velocity: 0.5, at: 0)
        run(&pedal, seconds: 0.2)
        pedal.noteOff(50)
        run(&pedal, seconds: 5)
        XCTAssertEqual(pedal.groups[2].glow, 0.7, accuracy: 1e-5, "sounding under the pedal")
        pedal.setPedal(false)
        run(&pedal, seconds: 2.5)
        XCTAssertLessThan(pedal.groups[2].glow, 0.7 * 0.5)
        // A panic lets everything go: nothing stays lit.
        var panic = CoralPulse()
        panic.noteOn(60, velocity: 1, at: 0)
        run(&panic, seconds: 0.2)
        panic.allNotesOff()
        run(&panic, seconds: 20)
        XCTAssertTrue(panic.patches.isEmpty)
        XCTAssertTrue(panic.groups.allSatisfy { $0.glow == 0 })
    }

    /// Spec §9.2: the school darts along the melody. Its leader follows the last 8 melody notes' places across the reef
    /// (higher notes higher in the water) and the fish follow it, turning together; notes struck together don't call
    /// it; an accent flashes it silver. With nothing to follow, it cruises back over the reef. Deterministic.
    func testSchoolFollowsARun() throws {
        var c = CoralPulse()
        run(&c, seconds: 2, dt: 1.0 / 30)
        let idle = c.school
        XCTAssertEqual(idle.positions.count, CoralPulse.schoolSize(fish: 0.6))
        XCTAssertTrue(idle.path.isEmpty)
        XCTAssertLessThan(simd_distance(idle.centre, CoralPulse.cruise(at: 2)), 0.08, "cruising over the reef")

        // A rising run, 0.12 s a note.
        let rising: [UInt8] = [40, 44, 48, 52, 55, 60, 64, 67, 72, 76, 79, 84]
        var t = 2.0
        var spread: Float = 0
        for n in rising {
            c.noteOn(n, velocity: 0.7, at: t)
            for _ in 0..<3 {
                c.step(dt: 0.04, roles: RoleValues())
                t += 0.04
                let xs = c.school.positions.map(\.x)
                spread = max(spread, (xs.max() ?? 0) - (xs.min() ?? 0))
            }
        }
        let school = c.school
        XCTAssertEqual(school.path.count, CoralPulse.pathNotes, "the last 8 notes")
        XCTAssertEqual(school.path, rising.suffix(8).map { CoralPulse.point(for: $0) })
        XCTAssertEqual(school.path.map(\.x), school.path.map(\.x).sorted(), "across the reef, as the run rises")
        XCTAssertEqual(school.path.map(\.y), school.path.map(\.y).sorted(), "and up through the water")
        XCTAssertGreaterThan(cos(school.heading), 0.7, "it swims with the run, to the right")
        XCTAssertLessThan(simd_distance(school.centre, CoralPulse.point(for: 84)), 0.1, "darting along behind the melody")
        XCTAssertGreaterThan(spread, 0.1, "a run stretches the school along its contour")
        run(&c, seconds: 0.4, dt: 1.0 / 30)
        XCTAssertLessThan(simd_distance(c.school.centre, CoralPulse.point(for: 84)), 0.02, "caught up with the last note")
        run(&c, seconds: 0.6, dt: 1.0 / 30)
        XCTAssertTrue(c.school.positions.allSatisfy { simd_distance($0, c.school.centre) < 0.1 }, "together again")
        t += 1

        // Falling back down: it turns together, to the left.
        for n in rising.reversed() {
            c.noteOn(n, velocity: 0.7, at: t)
            for _ in 0..<3 { c.step(dt: 0.04, roles: RoleValues()); t += 0.04 }
        }
        XCTAssertLessThan(cos(c.school.heading), -0.7)
        run(&c, seconds: 0.6, dt: 1.0 / 30)
        XCTAssertLessThan(simd_distance(c.school.centre, CoralPulse.point(for: 40)), 0.02)
        XCTAssertTrue(c.school.positions.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
        t += 0.6

        // Notes struck together (a chord) neither call the school nor break the run: one place, the first note's.
        let before = c.school.path.count
        c.noteOn(91, velocity: 0.7, at: t)
        c.noteOn(95, velocity: 0.7, at: t + 0.01)
        c.noteOn(98, velocity: 0.7, at: t + 0.02)
        XCTAssertEqual(c.school.path.last, CoralPulse.point(for: 91))
        XCTAssertEqual(c.school.path.count, min(CoralPulse.pathNotes, before + 1))

        // An accent flashes the school silver: in within a tenth of a second, out within about a second.
        var a = CoralPulse()
        run(&a, seconds: 0.5)
        XCTAssertEqual(a.school.flash, 0)
        a.noteOn(60, velocity: 0.95, at: 0.5)
        run(&a, seconds: 0.1)
        XCTAssertGreaterThan(a.school.flash, 0.6)
        var peak: Float = 0, fall: Float = 0
        for _ in 0..<60 {
            let f0 = a.school.flash
            a.step(dt: 1.0 / 60, roles: RoleValues())
            peak = max(peak, a.school.flash)
            fall = max(fall, abs(a.school.flash - f0))
        }
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertLessThan(a.school.flash, 0.1)
        XCTAssertLessThan(fall, 0.05, "it fades smoothly")
        var calm = CoralPulse()
        calm.noteOn(60, velocity: 0.6, at: 0)
        run(&calm, seconds: 0.3)
        XCTAssertEqual(calm.school.flash, 0, "no accent, no flash")

        // After the playing stops it eases back onto its cruise.
        run(&c, seconds: 12, dt: 1.0 / 30)
        XCTAssertLessThan(simd_distance(c.school.centre, CoralPulse.cruise(at: t + 12)), 0.08)

        // Deterministic: the same run, the same school.
        func replay() -> School {
            var s = CoralPulse()
            for (i, n) in ([48, 52, 55, 60, 64] as [UInt8]).enumerated() {
                s.noteOn(n, velocity: 0.8, at: Double(i) * 0.1)
                s.step(dt: 0.1, roles: RoleValues())
            }
            return s.school
        }
        XCTAssertEqual(replay(), replay())
        XCTAssertNotEqual(replay(), idle)
    }

    /// Spec §9.2: a chord (three notes within 60 ms) sends a colour wave sweeping the whole reef from its mean place:
    /// warm pinks and oranges for major, blues and violets for minor, a flicker of purple when tense. It never flashes.
    func testChordsSendAColourWave() throws {
        var major = CoralPulse()
        let notes: [UInt8] = [60, 64, 67]
        for (i, n) in notes.enumerated() { major.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        run(&major, seconds: 0.4)
        let w = try XCTUnwrap(major.wave)
        XCTAssertEqual(w.quality, .major)
        XCTAssertEqual(w.hue, CoralPulse.waveHue(for: .major))
        let mean = notes.map { CoralPulse.x(for: $0) }.reduce(0, +) / 3
        XCTAssertEqual(w.x, mean, accuracy: 1e-5, "from the chord's mean place")
        XCTAssertEqual(w.offset, 0.4 * CoralPulse.waveSpeed, accuracy: 1e-3)
        XCTAssertEqual(w.left, mean - w.offset, accuracy: 1e-6)
        XCTAssertEqual(w.right, mean + w.offset, accuracy: 1e-6)
        XCTAssertGreaterThan(w.strength, 0.5)
        XCTAssertTrue(w.phase > 0 && w.phase < 1)
        // Where a front is, the coral takes the wave's colour and brightens (no note lit it); far from both fronts, it
        // keeps its own colour.
        func hueDistance(_ a: Float, _ b: Float) -> Float {
            let d = abs(a - b).truncatingRemainder(dividingBy: 1)
            return min(d, 1 - d)
        }
        let under = try XCTUnwrap((0..<7).min(by: { abs(CoralPulse.groupX[$0] - w.right) < abs(CoralPulse.groupX[$1] - w.right) }))
        XCTAssertEqual(under, 4)
        XCTAssertTrue(major.patches.allSatisfy { $0.group == 3 }, "the chord's own notes light the soft corals")
        XCTAssertLessThan(hueDistance(major.groups[under].hue, w.hue), hueDistance(CoralPulse.hues[under], w.hue) - 0.02)
        XCTAssertGreaterThan(major.groups[under].glow, 0.1, "the wave brightens it as it passes")
        XCTAssertLessThanOrEqual(major.groups[under].glow, 0.3)
        let farthest = try XCTUnwrap((0..<7).max(by: { abs(CoralPulse.groupX[$0] - mean) < abs(CoralPulse.groupX[$1] - mean) }))
        XCTAssertEqual(major.groups[farthest].hue, CoralPulse.hues[farthest], accuracy: 1e-3, "the front hasn't reached it yet")
        XCTAssertEqual(major.groups[farthest].glow, 0, accuracy: 1e-3)
        // It sweeps out across the whole reef, then is gone; its strength stays within 0…1 and never jumps.
        var visited = Set<Int>()
        var biggestStep: Float = 0, last = w.strength
        var frames = 0
        while let wave = major.wave, frames < 600 {
            // Swept: a front has reached or passed it (the groups by the chord were swept before this loop began).
            for g in 0..<7 where abs(CoralPulse.groupX[g] - wave.x) <= wave.offset + CoralPulse.waveWidth {
                visited.insert(g)
            }
            XCTAssertTrue((0...1).contains(wave.strength))
            biggestStep = max(biggestStep, abs(wave.strength - last))
            last = wave.strength
            major.step(dt: 1.0 / 60, roles: RoleValues())
            frames += 1
        }
        XCTAssertNil(major.wave, "gone once it has swept the reef")
        XCTAssertEqual(visited, Set(0..<7), "every group, from the bass to the treble")
        XCTAssertLessThan(Double(frames) / 60, 3, "within a few seconds")
        XCTAssertLessThan(biggestStep, 0.1)
        XCTAssertEqual(major.groups.map(\.hue), CoralPulse.hues, "each coral its own colour again")

        // Minor: blues and violets.
        var minor = CoralPulse()
        for (i, n) in ([57, 60, 64] as [UInt8]).enumerated() { minor.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        run(&minor, seconds: 0.2)
        XCTAssertEqual(minor.wave?.quality, .minor)
        XCTAssertEqual(minor.wave?.hue ?? 0, CoralPulse.waveHue(for: .minor))
        let blue = CoralPulse.rgb(hue: CoralPulse.waveHue(for: .minor))
        XCTAssertTrue(blue.z == 1 && blue.y < 0.2, "blue-violet")
        // Tense: a flicker of purple, never a flash (its strength dips by at most 20% and changes smoothly).
        var tense = CoralPulse()
        for (i, n) in ([60, 66, 71] as [UInt8]).enumerated() { tense.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        run(&tense, seconds: 0.35)
        XCTAssertEqual(tense.wave?.quality, .tense)
        let purple = CoralPulse.rgb(hue: CoralPulse.waveHue(for: .tense))
        XCTAssertTrue(purple.x > 0.6 && purple.z == 1 && purple.y == 0, "purple")
        var dips = 0, previous = tense.wave?.strength ?? 0, falling = false, flickerStep: Float = 0
        while tense.wave != nil {
            tense.step(dt: 1.0 / 60, roles: RoleValues())
            guard let s = tense.wave?.strength else { break }   // its fronts have left the reef
            if s > previous, falling { dips += 1 }
            falling = s < previous
            flickerStep = max(flickerStep, abs(s - previous))
            previous = s
        }
        XCTAssertGreaterThanOrEqual(dips, 2, "it flickers")
        XCTAssertLessThan(flickerStep, 0.1, "smoothly")
        // Warm pinks and oranges for major.
        let warm = CoralPulse.rgb(hue: CoralPulse.waveHue(for: .major))
        XCTAssertTrue(warm.x == 1 && warm.z > 0.1 && warm.y < 0.3, "a warm pink")

        // Not a chord: one note, two, or three spread out as a run.
        var single = CoralPulse()
        single.noteOn(60, velocity: 1, at: 0)
        run(&single, seconds: 0.3)
        XCTAssertNil(single.wave)
        var pair = CoralPulse()
        pair.noteOn(60, velocity: 1, at: 0); pair.noteOn(64, velocity: 1, at: 0.01)
        run(&pair, seconds: 0.3)
        XCTAssertNil(pair.wave)
        var spread = CoralPulse()
        for (i, n) in notes.enumerated() {
            spread.noteOn(n, velocity: 0.8, at: 0.1 * Double(i))
            spread.step(dt: 0.1, roles: RoleValues())
        }
        XCTAssertNil(spread.wave, "a run, not a chord")
    }

    /// Spec §9.2: the Fish dial sets the school's size, from 20 fish to 80.
    func testFishDialSetsTheSchool() {
        XCTAssertEqual(CoralPulse.schoolSizes, 20...80)
        XCTAssertEqual(CoralPulse.schoolSize(fish: 0), 20)
        XCTAssertEqual(CoralPulse.schoolSize(fish: 1), 80)
        XCTAssertEqual(CoralPulse.schoolSize(fish: 0.6), 56, "the default")
        XCTAssertEqual(CoralPulse.schoolSize(fish: 0.5), 50)
        XCTAssertEqual(CoralPulse.schoolSize(fish: -2), 20)
        XCTAssertEqual(CoralPulse.schoolSize(fish: 9), 80)
        XCTAssertEqual(CoralPulse.schoolSize(fish: .nan), 56)
        var previous = 0
        for k in 0...20 {
            let n = CoralPulse.schoolSize(fish: Double(k) / 20)
            XCTAssertGreaterThanOrEqual(n, previous, "more fish as the dial turns up")
            previous = n
        }
        var c = CoralPulse()
        for f in [0.0, 0.25, 0.6, 1.0, 0.1] {
            c.fish = f
            run(&c, seconds: 0.5)
            XCTAssertEqual(c.school.positions.count, CoralPulse.schoolSize(fish: f), "Fish \(f)")
            XCTAssertTrue(c.school.positions.allSatisfy { simd_distance($0, c.school.centre) < 0.15 }, "one school")
        }

        // Through the world: the hero dial sets the frame's school.
        var model = GreatBarrierReefModel()
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 80, altitude: 40)
        s.hourOfDay = 10
        model.setSky(s)
        for (fish, count) in [(0.0, 20), (0.3, 38), (1.0, 80)] {
            let p = ThemeRegistry.parameterSet(for: GreatBarrierReefModel.id, state: ThemeState(values: ["fish": .number(fish)]))
            let f = model.step(dt: 1.0 / 30, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            XCTAssertEqual(f.school.positions.count, count, "Fish \(fish)")
        }
    }

    /// Small Wins §4: while time is held (a step of dt 0), what a note makes starts at its bloom and holds there. Polyp
    /// patches are full at birth; a chord's colour wave runs on to 0.3 s (risen to its full strength, its fronts out);
    /// an accent's silver flash is full at once. With time running, nothing changes.
    func testCoralPulseBloomsWhenTimeIsHeld() throws {
        XCTAssertEqual(CoralPulse.waveBloomAge, 0.3)
        var c = CoralPulse()
        for (i, n) in ([60, 64, 67] as [UInt8]).enumerated() { c.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        c.step(dt: 0, roles: RoleValues())
        XCTAssertEqual(c.patches.count, 3)
        XCTAssertTrue(c.patches.allSatisfy { $0.brightness == $0.peak }, "the polyps lit at once")
        XCTAssertGreaterThanOrEqual(c.groups[3].glow, Float(1 - pow(1 - 0.88, 3)) - 1e-5, "their coral glowing at once")
        let w = try XCTUnwrap(c.wave)
        XCTAssertEqual(w.age, 0.3, accuracy: 1e-7)
        XCTAssertEqual(w.offset, CoralPulse.waveSpeed * 0.3, accuracy: 1e-6, "its fronts out where 0.3 s takes them")
        XCTAssertEqual(w.strength, 0.9 * (1 - 0.6 * w.phase), accuracy: 1e-5, "at its full strength")
        XCTAssertGreaterThan(w.strength, 0.75)
        for _ in 0..<60 { c.step(dt: 0, roles: RoleValues()) }
        XCTAssertEqual(c.wave, w, "and it holds")
        c.step(dt: 0.1, roles: RoleValues())
        XCTAssertEqual(try XCTUnwrap(c.wave).age, 0.4, accuracy: 1e-6, "then runs on from it")

        // Running time is untouched: one 1/60 s step in, the wave has only begun to rise.
        var running = CoralPulse()
        for (i, n) in ([60, 64, 67] as [UInt8]).enumerated() { running.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        running.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertLessThan(try XCTUnwrap(running.wave).strength, 0.05)
        for _ in 0..<10 { running.step(dt: 0, roles: RoleValues()) }
        XCTAssertLessThan(try XCTUnwrap(running.wave).strength, 0.05, "a wave from a running step stays where it had got to")

        // An accent's flash is full at once, and holds.
        var accent = CoralPulse()
        accent.noteOn(72, velocity: 0.95, at: 0)
        accent.step(dt: 0, roles: RoleValues())
        XCTAssertEqual(accent.school.flash, 1, accuracy: 1e-6)
        for _ in 0..<30 { accent.step(dt: 0, roles: RoleValues()) }
        XCTAssertEqual(accent.school.flash, 1, accuracy: 1e-6)
        var soft = CoralPulse()
        soft.noteOn(72, velocity: 0.95, at: 0)
        soft.step(dt: 1.0 / 60, roles: RoleValues())
        XCTAssertLessThan(soft.school.flash, 0.6, "running, it comes in over about 50 ms")
    }

    /// Spec §9.2: at most 64 lit patches, and 12 new ones a step (a burst waits, only the latest 64 kept waiting).
    func testBurstIsRationed() {
        var c = CoralPulse()
        for i in 0..<2000 { c.noteOn(UInt8(21 + i % 88), velocity: 0.9, at: Double(i) * 0.0005) }
        var lit = 0
        for _ in 0..<60 {
            c.step(dt: 1.0 / 60, roles: RoleValues())
            XCTAssertLessThanOrEqual(c.lastSpawns, CoralPulse.maxSpawnsPerStep)
            XCTAssertLessThanOrEqual(c.patches.count, CoralPulse.cap)
            XCTAssertTrue(c.groups.allSatisfy { $0.glow >= 0 && $0.glow <= 1 })
            XCTAssertLessThanOrEqual(c.school.path.count, CoralPulse.pathNotes)
            lit += c.lastSpawns
        }
        XCTAssertEqual(CoralPulse.maxSpawnsPerStep, 12)
        XCTAssertEqual(CoralPulse.cap, 64)
        XCTAssertEqual(lit, 64, "12 a step, and only the latest 64 kept waiting")
        XCTAssertEqual(c.patches.count, CoralPulse.cap)
        XCTAssertNotNil(c.wave, "a burst is a chord too")

        // A full reef lets its dimmest patch go first: the held ones stay.
        var full = CoralPulse()
        for i in 0..<64 { full.noteOn(UInt8(21 + i), velocity: 0.6, at: Double(i)) }
        run(&full, seconds: 0.2)
        for i in stride(from: 0, to: 64, by: 2) { full.noteOff(UInt8(21 + i)) }
        run(&full, seconds: 1)
        full.noteOn(100, velocity: 1, at: 100)
        run(&full, seconds: 0.1)
        XCTAssertEqual(full.patches.count, 64)
        XCTAssertTrue(full.patches.contains { $0.note == 100 })
        XCTAssertEqual(full.patches.filter(\.held).count, 33)
        // The renderer's budget keeps the brightest, in order.
        let shown = CoralPulse.visible(full.patches, limit: 32)
        XCTAssertEqual(shown.count, 32)
        XCTAssertTrue(shown.allSatisfy { $0.held })
        XCTAssertEqual(shown.map(\.id), shown.map(\.id).sorted(), "in their original order")
        XCTAssertEqual(CoralPulse.visible(full.patches, limit: 100).count, full.patches.count)

        // Odd inputs stay finite and inside.
        var odd = CoralPulse()
        odd.reactionScale = .nan
        odd.lingerScale = .infinity
        odd.fish = .nan
        odd.noteOn(60, velocity: .nan, at: .nan)
        odd.noteOn(64, velocity: 7, at: 1)
        for dt in [Double.nan, -1, 1e9, .infinity, 0, 0.25] { odd.step(dt: dt, roles: RoleValues()) }
        XCTAssertTrue(odd.patches.allSatisfy { $0.brightness.isFinite && (0...1).contains($0.brightness) })
        XCTAssertTrue(odd.groups.allSatisfy { $0.glow.isFinite && $0.hue.isFinite })
        XCTAssertTrue(odd.school.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertTrue(odd.school.heading.isFinite && odd.school.flash.isFinite)
    }

    func testIdsWrap() throws {
        var c = CoralPulse()
        c.nextID = Int.max - 2
        c.nextWaveID = Int.max
        for i in 0..<6 {
            c.noteOn(UInt8(60 + i), velocity: 0.5, at: Double(i) * 0.1)
            c.step(dt: 0.1, roles: RoleValues())
        }
        XCTAssertEqual(c.patches.map(\.id), [Int.max - 2, Int.max - 1, Int.max, Int.min, Int.min + 1, Int.min + 2])
        XCTAssertEqual(Set(c.patches.map(\.id)).count, 6)
        // Two chords, two waves: the second's id past Int.max.
        var ids: [Int] = []
        for k in 0..<2 {
            let t = 2 + Double(k)
            for (i, n) in ([72, 76, 79] as [UInt8]).enumerated() { c.noteOn(n, velocity: 0.7, at: t + 0.01 * Double(i)) }
            c.step(dt: 0.1, roles: RoleValues())
            ids.append(try XCTUnwrap(c.wave).id)
        }
        XCTAssertEqual(ids, [Int.max, Int.min])
    }
}
