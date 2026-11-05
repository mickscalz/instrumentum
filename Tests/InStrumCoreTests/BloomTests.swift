import XCTest
@testable import InStrumCore

/// Small Wins §4: while time is held (a step of dt 0), what a note makes starts at its bloom, its first moment at full
/// brightness and shape, and holds there; with time running, nothing changes.
final class BloomTests: XCTestCase {
    private let roles = RoleValues()
    private let gardenParams = ParameterSet(specs: ButterflyGardenModel.parameters,
                                            macroTargets: ButterflyGardenModel.macroTargets)

    private func stepGarden(_ m: inout ButterflyGardenModel, dt: Double) -> GardenFrame {
        m.step(dt: dt, params: gardenParams, roles: roles, inputs: InputFrame(), quality: .high)
    }

    /// A chord's swell one running step in, as the visuals step it: its target decayed (τ `fall`), times the rise
    /// toward it (τ `rise`).
    private func swell(_ target: Double, fall: Double, rise: Double, dt: Double = 1.0 / 60) -> Float {
        Float(target * exp(-dt / fall) * (1 - exp(-dt / rise)))
    }

    func testLakeRipplesBloomWhenTimeIsHeld() throws {
        XCTAssertEqual(LakeRipples.bloomAge, 0.15)
        XCTAssertEqual(LakeRipples.fireflyBloomAge, 0.6)
        var lake = LakeRipples()
        lake.noteOn(60, velocity: 100, pedal: false, at: 0)
        lake.step(dt: 0, roles: roles)
        XCTAssertEqual(lake.ripples.map(\.age), [0.15], "a note's ring starts at its bloom")
        for _ in 0..<60 { lake.step(dt: 0, roles: roles) }
        XCTAssertEqual(lake.ripples.map(\.age), [0.15], "and stays there while time is held")
        lake.step(dt: 0.1, roles: roles)
        XCTAssertEqual(try XCTUnwrap(lake.ripples.first).age, 0.25, accuracy: 1e-6, "then ages on from it")

        // A chord's fireflies start lit.
        var chord = LakeRipples()
        chord.noteOn(60, velocity: 90, pedal: false, at: 0)
        chord.noteOn(64, velocity: 90, pedal: false, at: 0.015)
        chord.noteOn(67, velocity: 90, pedal: false, at: 0.03)
        chord.step(dt: 0, roles: roles)
        XCTAssertTrue((2...5).contains(chord.fireflies.count), "\(chord.fireflies.count)")
        XCTAssertEqual(Set(chord.fireflies.map(\.age)), [0.6])
        XCTAssertEqual(chord.ripples.map(\.age), [0.15, 0.15, 0.15])
        for _ in 0..<60 { chord.step(dt: 0, roles: roles) }
        XCTAssertEqual(Set(chord.fireflies.map(\.age)), [0.6])

        // Only what was born since the last step: a ring from a running step stays where it had got to.
        var early = LakeRipples()
        early.noteOn(60, velocity: 100, pedal: false, at: 0)
        early.step(dt: 1.0 / 60, roles: roles)
        for _ in 0..<10 { early.step(dt: 0, roles: roles) }
        XCTAssertEqual(early.ripples.map(\.age), [Float(1.0 / 60)])
    }

    func testTideLinesAreTracedAtOnce() throws {
        XCTAssertEqual(TideLines.bloomAge, 0.3)
        var tide = TideLines()
        tide.noteOn(60, velocity: 100, pedal: false, at: 0)
        tide.step(dt: 0, washFront: 0, breaks: [], roles: roles)
        let line = try XCTUnwrap(tide.lines.first)
        XCTAssertEqual(line.drawn, 1, "traced at once")
        XCTAssertEqual(line.age, 0.3, "as old as its tracing takes")
        XCTAssertEqual(line.strength, Float(100) / 127 * 1.1, accuracy: 1e-6, "at its full strength")
        XCTAssertEqual(line.washed, 0)
        for _ in 0..<60 { tide.step(dt: 0, washFront: 0, breaks: [], roles: roles) }
        XCTAssertEqual(tide.lines, [line], "and it stays")
    }

    func testGlowWakeDartsBloom() {
        XCTAssertEqual(GlowWake.dartBloomAge, 0.25)
        // A fast run while time is held: eight notes 0.1 s apart on the notes' own clock.
        var g = GlowWake()
        var sent = 0
        for i in 0..<8 {
            g.noteOn(UInt8(60 + 2 * i), velocity: 0.8, at: Double(i) * 0.1)
            g.step(dt: 0, roles: roles)
            sent = max(sent, g.darts.count)
            XCTAssertTrue(g.darts.allSatisfy { $0.age == 0.25 }, "every dart at its bloom: \(g.darts.map(\.age))")
        }
        XCTAssertGreaterThan(sent, 0, "the run sends fish while time is held")
        XCTAssertTrue(g.darts.allSatisfy { abs($0.brightness - $0.strength * (1 - 0.25 / 0.6)) < 1e-6 })
        XCTAssertTrue(g.wakes.allSatisfy { $0.age == 0 && $0.brightness == $0.strength }, "wakes are full at birth")
        XCTAssertTrue(g.patches.allSatisfy { $0.brightness == $0.peak }, "and so are the patches")
    }

    func testSteamWispsRiseAtOnce() throws {
        XCTAssertEqual(SteamLines.puffBloomAge, 0.15)
        var s = SteamLines()
        s.noteOn(60, velocity: 0.5, at: 0)
        s.step(dt: 0, roles: roles)
        let w = try XCTUnwrap(s.wisps.first)
        XCTAssertEqual(w.height, 0.65, accuracy: 1e-6)
        XCTAssertEqual(w.rise, w.height, "risen to its velocity's height at once")
        XCTAssertEqual(w.brightness, w.peak)

        // A chord's puff swells in at once, to its full strength: (0.6 + 0.4 × 0.5) × the mood's reaction.
        var c = SteamLines()
        for (t, n) in zip([0, 0.02, 0.05], [60, 64, 67] as [UInt8]) { c.noteOn(n, velocity: 0.5, at: t) }
        c.step(dt: 0, roles: roles)
        XCTAssertEqual(c.puff.strength, 0.8, accuracy: 1e-6)
        XCTAssertEqual(c.puff.age, 0.15)
        XCTAssertEqual(c.puff.warmth, 1)
        XCTAssertEqual(c.wisps.count, 3)
        XCTAssertTrue(c.wisps.allSatisfy { $0.rise == $0.height })
        let puff = c.puff
        for _ in 0..<60 { c.step(dt: 0, roles: roles) }
        XCTAssertEqual(c.puff, puff, "and it holds")
    }

    func testRakeWaveBlooms() throws {
        XCTAssertEqual(RakeLines.waveBloomAge, 0.4)
        var r = RakeLines()
        for (i, n) in ([72, 76, 79] as [UInt8]).enumerated() { r.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        r.step(dt: 0, roles: roles)
        let w = try XCTUnwrap(r.wave)
        XCTAssertEqual(w.age, 0.4)
        XCTAssertEqual(w.offset, RakeLines.waveSpeed * 0.4, accuracy: 1e-6, "its fronts out where 0.4 s takes them")
        XCTAssertEqual(w.strength, 0.9, accuracy: 1e-6)
        let reach = max(w.origin, 1 - w.origin) + RakeLines.waveBand / 2
        XCTAssertEqual(w.brightness, w.strength * (1 - 0.6 * min(1, w.offset / reach)), accuracy: 1e-6,
                       "at full brightness")
        // The gravel its fronts have passed is re-raked fresh (0.85 of the way to 1 + 0.25 × strength of the morning's
        // relief); beyond them it is the morning's still.
        let width = RakeField.width
        let atOrigin = Int(w.origin * Float(width)), beyond = Int((w.origin + 0.1) * Float(width))
        let fresh = 1 + 0.85 * 0.25 * w.strength
        for y in 4...12 {
            let passed = y * width + atOrigin, ahead = y * width + beyond
            XCTAssertEqual(r.field.heights[passed], fresh * RakeLines.morning[passed], accuracy: 1e-5)
            XCTAssertEqual(r.field.heights[ahead], RakeLines.morning[ahead])
        }
        let wave = r.wave, heights = r.field.heights
        for _ in 0..<30 { r.step(dt: 0, roles: roles) }
        XCTAssertEqual(r.wave, wave, "and it holds")
        XCTAssertEqual(r.field.heights, heights)
    }

    func testButterfliesFadeInAtOnce() throws {
        XCTAssertEqual(ButterflyGardenModel.bloomAge, 0.25)
        var m = ButterflyGardenModel()
        m.handle(.noteOn(note: 60, velocity: 0.7))
        let f = stepGarden(&m, dt: 0)
        XCTAssertEqual(try XCTUnwrap(f.butterflies.first).opacity, 1, "faded in at once")
        // Its flower opens far enough to show in full (the renderer draws it at 3 × its openness, at most 1).
        let flower = try XCTUnwrap(f.blooms.first)
        XCTAssertEqual(flower.openness, 1.0 / 3)
        XCTAssertEqual(min(1, flower.openness * 3), 1)
        let again = stepGarden(&m, dt: 0)
        XCTAssertEqual(again.butterflies, f.butterflies)
        XCTAssertEqual(again.blooms, f.blooms)
    }

    /// Deep Lights (the submarine): while time is held a note's creature is lit at its peak at once, a run's lanternfish
    /// shoal starts a fifth of the way across at full brightness, a chord's siphonophore at its full swell, an accent's
    /// bubbles already climbing; one more held step changes none of them. With time running, a shoal and a stream set
    /// off at age 0 and a siphonophore swells in.
    func testDeepLightsBloomWhenTimeIsHeld() throws {
        XCTAssertEqual(DeepLights.shoalBloomAge, 0.3)
        XCTAssertEqual(DeepLights.streamBloomAge, 0.8)
        var deep = DeepLights()
        // A run (an accent at its end), then a chord, on the notes' own clock.
        let run: [(UInt8, Double, Float)] = [(60, 0, 0.7), (62, 0.1, 0.7), (64, 0.2, 0.7), (65, 0.3, 0.95)]
        for (n, t, v) in run {
            deep.noteOn(n, velocity: v, at: t)
            deep.step(dt: 0, roles: roles)
        }
        for (n, t) in zip([67, 71, 74] as [UInt8], [0.6, 0.62, 0.64]) { deep.noteOn(n, velocity: 0.8, at: t) }
        deep.step(dt: 0, roles: roles)
        XCTAssertEqual(deep.shoals.count, 1)
        let shoal = try XCTUnwrap(deep.shoals.first)
        XCTAssertEqual(shoal.contour.count, 4, "the run's last note joined it")
        XCTAssertEqual(shoal.age, DeepLights.shoalBloomAge, "the shoal starts at its bloom")
        XCTAssertEqual(shoal.brightness, shoal.strength, accuracy: 1e-6, "at full brightness")
        let stream = try XCTUnwrap(deep.bubbleStreams.first)
        XCTAssertEqual(stream.age, DeepLights.streamBloomAge, "the accent's bubbles are already rising")
        let chain = try XCTUnwrap(deep.siphonophores.first)
        XCTAssertEqual(chain.level, 1, "the chord's siphonophore at its full swell")
        XCTAssertEqual(chain.brightness, chain.strength, accuracy: 1e-6)
        XCTAssertEqual(deep.creatures.count, 7)
        XCTAssertTrue(deep.creatures.allSatisfy { abs($0.glow - $0.peak) < 1e-6 }, "every creature lit at its peak")
        let held = deep
        for _ in 0..<60 { deep.step(dt: 0, roles: roles) }
        XCTAssertEqual(deep.creatures, held.creatures, "and it all holds")
        XCTAssertEqual(deep.shoals, held.shoals)
        XCTAssertEqual(deep.siphonophores, held.siphonophores)
        XCTAssertEqual(deep.bubbleStreams, held.bubbleStreams)

        // With time running nothing blooms.
        let dt = 1.0 / 60
        var running = DeepLights()
        for (n, t, v) in run {
            running.noteOn(n, velocity: v, at: t)
            running.step(dt: dt, roles: roles)
        }
        XCTAssertTrue(running.shoals.allSatisfy { $0.age < 0.05 }, "\(running.shoals.map(\.age))")
        XCTAssertEqual(try XCTUnwrap(running.bubbleStreams.first).age, 0, "set off at the end of its step")
        for (n, t) in zip([67, 71, 74] as [UInt8], [0.6, 0.62, 0.64]) { running.noteOn(n, velocity: 0.8, at: t) }
        running.step(dt: dt, roles: roles)
        XCTAssertLessThan(try XCTUnwrap(running.siphonophores.first).level, 0.05, "swelling in over a second")
    }

    /// The rule covers the chords' swells too: Glow Wake's pool, Frost Grow's flare and Curtain Lights' tense pulse
    /// bloom at their full strength while time is held, but only for a chord since the last step.
    func testChordSwellsBloomWhenTimeIsHeld() {
        let major: [UInt8] = [60, 64, 67], times = [0, 0.02, 0.05]
        var bay = GlowWake()
        for (n, t) in zip(major, times) { bay.noteOn(n, velocity: 0.8, at: t) }
        bay.step(dt: 0, roles: roles)
        XCTAssertEqual(bay.pool.strength, 0.92, accuracy: 1e-6, "(0.6 + 0.4 × 0.8): the pool's full strength")
        var cabin = FrostGrow()
        for (n, t) in zip(major, times) { cabin.noteOn(n, velocity: 0.8, at: t) }
        cabin.step(dt: 0, baseFrost: 0, roles: roles)
        XCTAssertEqual(cabin.flare, 1, "the fire flares at once")
        var fjord = CurtainLights()
        for (n, t) in zip([60, 61, 66] as [UInt8], [0, 0.01, 0.02]) { fjord.noteOn(n, velocity: 0.7, at: t) }
        fjord.step(dt: 0, roles: roles)
        XCTAssertEqual(fjord.tensePulse, 1, "a tense chord pulses the fringe at once")
        for _ in 0..<60 {
            bay.step(dt: 0, roles: roles)
            cabin.step(dt: 0, baseFrost: 0, roles: roles)
            fjord.step(dt: 0, roles: roles)
        }
        XCTAssertEqual(bay.pool.strength, 0.92, accuracy: 1e-6, "and they hold")
        XCTAssertEqual(cabin.flare, 1)
        XCTAssertEqual(fjord.tensePulse, 1)

        // A chord from a running step stays where its swell had got to.
        var early = GlowWake()
        for (n, t) in zip(major, times) { early.noteOn(n, velocity: 0.8, at: t) }
        early.step(dt: 1.0 / 60, roles: roles)
        let reached = early.pool.strength
        XCTAssertLessThan(reached, 0.2)
        for _ in 0..<60 { early.step(dt: 0, roles: roles) }
        XCTAssertEqual(early.pool.strength, reached)
    }

    /// A run and a chord played while time is held, then one more held step with nothing new: nothing changes.
    func testAHeldStepChangesNothingElse() {
        let run: [(UInt8, Double)] = [(60, 0), (62, 0.1), (64, 0.2), (65, 0.3), (67, 0.4)]
        let notes: [(UInt8, Double)] = run + [(72, 0.6), (76, 0.62), (79, 0.64)]

        var lake = LakeRipples()
        for (n, t) in notes { lake.noteOn(n, velocity: 100, pedal: false, at: t) }
        lake.step(dt: 0, roles: roles)
        let lake0 = lake
        lake.step(dt: 0, roles: roles)
        XCTAssertFalse(lake.fireflies.isEmpty)
        XCTAssertEqual(lake.ripples, lake0.ripples)
        XCTAssertEqual(lake.fireflies, lake0.fireflies)
        XCTAssertEqual(lake.glitter, lake0.glitter)

        var tide = TideLines()
        for (n, t) in notes { tide.noteOn(n, velocity: 100, pedal: false, at: t) }
        tide.step(dt: 0, washFront: 0, breaks: [], roles: roles)
        let tide0 = tide
        tide.step(dt: 0, washFront: 0, breaks: [], roles: roles)
        XCTAssertEqual(tide.lines, tide0.lines)
        XCTAssertEqual(tide.foam, tide0.foam)
        XCTAssertEqual(tide.chordPending, tide0.chordPending)

        var bay = GlowWake()
        for (n, t) in notes { bay.noteOn(n, velocity: 0.8, at: t) }
        bay.step(dt: 0, roles: roles)
        let bay0 = bay
        bay.step(dt: 0, roles: roles)
        XCTAssertFalse(bay.darts.isEmpty)
        XCTAssertEqual(bay.patches, bay0.patches)
        XCTAssertEqual(bay.wakes, bay0.wakes)
        XCTAssertEqual(bay.darts, bay0.darts)
        XCTAssertEqual(bay.pool, bay0.pool)

        var steam = SteamLines()
        for (n, t) in notes { steam.noteOn(n, velocity: 0.8, at: t) }
        steam.step(dt: 0, roles: roles)
        let steam0 = steam
        steam.step(dt: 0, roles: roles)
        XCTAssertEqual(steam.wisps.count, notes.count)
        XCTAssertEqual(steam.wisps, steam0.wisps)
        XCTAssertEqual(steam.ribbonPath, steam0.ribbonPath)
        XCTAssertEqual(steam.glow, steam0.glow)
        XCTAssertEqual(steam.puff, steam0.puff)
        XCTAssertEqual(steam.lanternFlake, steam0.lanternFlake)

        var rake = RakeLines()
        for (n, t) in notes { rake.noteOn(n, velocity: 0.8, at: t) }
        rake.step(dt: 0, roles: roles)
        let rake0 = rake
        rake.step(dt: 0, roles: roles)
        XCTAssertNotNil(rake.wave)
        XCTAssertEqual(rake.field.heights, rake0.field.heights)
        XCTAssertEqual(rake.field.version, rake0.field.version)
        XCTAssertEqual(rake.rings, rake0.rings)
        XCTAssertEqual(rake.strokes, rake0.strokes)
        XCTAssertEqual(rake.wave, rake0.wave)

        var meadow = ButterflyGardenModel()
        for (n, _) in notes { meadow.handle(.noteOn(note: n, velocity: 0.8)) }
        meadow.handle(.chord(notes: [72, 76, 79]))
        let garden0 = stepGarden(&meadow, dt: 0)
        let garden1 = stepGarden(&meadow, dt: 0)
        XCTAssertEqual(garden1.butterflies.count, notes.count)
        XCTAssertEqual(garden1.butterflies, garden0.butterflies)
        XCTAssertEqual(garden1.blooms, garden0.blooms)
        XCTAssertEqual(garden1.keys, garden0.keys)
        XCTAssertEqual(garden1.spiral, garden0.spiral)

        // (Frost Grow's flake glints are the news of one step, so they are left out.)
        var frost = FrostGrow()
        for (n, t) in notes { frost.noteOn(n, velocity: 0.8, at: t) }
        frost.step(dt: 0, baseFrost: 0.2, roles: roles)
        let frost0 = frost
        frost.step(dt: 0, baseFrost: 0.2, roles: roles)
        XCTAssertEqual(frost.level, frost0.level)
        XCTAssertEqual(frost.patches, frost0.patches)
        XCTAssertEqual(frost.flare, frost0.flare)
        XCTAssertEqual(frost.flareWarm, frost0.flareWarm)

        // Six notes, as Curtain Lights starts at most six ripples a step: a run, then a tense chord.
        var fjord = CurtainLights()
        for (n, t) in [(62, 0), (64, 0.1), (65, 0.2), (60, 0.6), (61, 0.61), (66, 0.62)] as [(UInt8, Double)] {
            fjord.noteOn(n, velocity: 0.7, at: t)
        }
        fjord.step(dt: 0, roles: roles)
        let fjord0 = fjord
        fjord.step(dt: 0, roles: roles)
        XCTAssertEqual(fjord.ripples.count, 6)
        XCTAssertEqual(fjord.tensePulse, 1)
        XCTAssertEqual(fjord.ripples, fjord0.ripples)
        XCTAssertEqual(fjord.glow, fjord0.glow)
        XCTAssertEqual(fjord.hueShift, fjord0.hueShift)
        XCTAssertEqual(fjord.tensePulse, fjord0.tensePulse)
    }

    /// With time running nothing blooms: at dt 1/60 a new item is as old, as traced and as swelled as before.
    func testRunningTimeIsUntouched() throws {
        let dt = 1.0 / 60, f = Float(dt)
        let major: [UInt8] = [60, 64, 67], times = [0, 0.02, 0.05]

        var lake = LakeRipples()
        for (n, t) in zip(major, [0, 0.015, 0.03]) { lake.noteOn(n, velocity: 90, pedal: false, at: t) }
        lake.step(dt: dt, roles: roles)
        XCTAssertEqual(lake.ripples.map(\.age), [f, f, f])
        XCTAssertFalse(lake.fireflies.isEmpty)
        XCTAssertTrue(lake.fireflies.allSatisfy { $0.age == f })

        var tide = TideLines()
        tide.noteOn(60, velocity: 100, pedal: false, at: 0)
        tide.step(dt: dt, washFront: 0, breaks: [], roles: roles)
        let line = try XCTUnwrap(tide.lines.first)
        XCTAssertEqual(line.age, f)
        XCTAssertEqual(line.drawn, f / 0.3, accuracy: 1e-7, "traced over 0.3 s")

        // Fish set off at the end of their step (0 s old), and are 1/60 s old a step later.
        var fast = GlowWake()
        for i in 0..<4 {
            fast.noteOn(UInt8(60 + 2 * i), velocity: 0.8, at: Double(i) * 0.1)
            fast.step(dt: i < 3 ? 0.1 : dt, roles: roles)
        }
        XCTAssertFalse(fast.darts.isEmpty)
        XCTAssertTrue(fast.darts.allSatisfy { $0.age == 0 })
        fast.step(dt: dt, roles: roles)
        XCTAssertTrue(fast.darts.allSatisfy { $0.age == f })
        var bay = GlowWake()
        for (n, t) in zip(major, times) { bay.noteOn(n, velocity: 0.8, at: t) }
        bay.step(dt: dt, roles: roles)
        XCTAssertEqual(bay.pool.strength, swell(0.92, fall: 1.5, rise: 0.15), accuracy: 1e-6)

        // Wisps leave the ribbon at the end of their step, not yet risen.
        var steam = SteamLines()
        for (n, t) in zip(major, times) { steam.noteOn(n, velocity: 0.5, at: t) }
        steam.step(dt: dt, roles: roles)
        XCTAssertEqual(steam.wisps.count, 3)
        XCTAssertTrue(steam.wisps.allSatisfy { $0.age == 0 && $0.rise == 0 })
        XCTAssertEqual(steam.puff.age, f)
        XCTAssertEqual(steam.puff.strength, swell(0.8, fall: 1.5, rise: 0.15), accuracy: 1e-6)

        var rake = RakeLines()
        for (i, n) in ([72, 76, 79] as [UInt8]).enumerated() { rake.noteOn(n, velocity: 0.8, at: 0.02 * Double(i)) }
        rake.step(dt: dt, roles: roles)
        let wave = try XCTUnwrap(rake.wave)
        XCTAssertEqual(wave.age, f)
        XCTAssertEqual(wave.offset, RakeLines.waveSpeed * f)
        XCTAssertLessThan(wave.brightness, 0.01, "brightening in over 0.4 s")

        var meadow = ButterflyGardenModel()
        meadow.handle(.noteOn(note: 60, velocity: 0.7))
        let frame = stepGarden(&meadow, dt: dt)
        XCTAssertEqual(try XCTUnwrap(frame.butterflies.first).opacity, 4 * f, accuracy: 1e-6, "fading in over 0.25 s")
        XCTAssertEqual(try XCTUnwrap(frame.blooms.first).openness, 0.05 + 0.6 * f, accuracy: 1e-6, "opening as it does")

        var cabin = FrostGrow()
        for (n, t) in zip(major, times) { cabin.noteOn(n, velocity: 0.8, at: t) }
        cabin.step(dt: dt, baseFrost: 0, roles: roles)
        XCTAssertEqual(cabin.flare, swell(1, fall: 1.5, rise: 0.15), accuracy: 1e-6)

        var fjord = CurtainLights()
        for (n, t) in zip([60, 61, 66] as [UInt8], [0, 0.01, 0.02]) { fjord.noteOn(n, velocity: 0.7, at: t) }
        fjord.step(dt: dt, roles: roles)
        XCTAssertEqual(fjord.tensePulse, swell(1, fall: 0.8, rise: 0.15), accuracy: 1e-6)
    }
}
