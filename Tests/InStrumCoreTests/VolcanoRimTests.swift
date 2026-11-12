import XCTest
import simd
@testable import InStrumCore

/// Volcano Rim and its second visual, Magma Veins (Fire & Neon spec §8; plan Task 11). Every bound is the spec's or the
/// plan's: the fixed pools (64 cells, 24 blobs, 16 bombs, 400 embers, 4 strokes; 96 veins), 1–3 blobs a low note, a
/// column of 3–6 lake-widths, the lightning's 0.05 → 0.6 a second, the 0.15° shake (none under Reduce Motion).
final class VolcanoRimTests: XCTestCase {
    // MARK: - Helpers

    /// A clear night over Melbourne.
    private func night() -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 250, altitude: -30)
        s.moon = SkyDirection(azimuth: 100, altitude: -20)
        s.hourOfDay = 23
        s.dayOfYear = 320
        s.latitude = -37.8
        s.zenith = SIMD3(0.01, 0.014, 0.035)
        s.horizon = SIMD3(0.02, 0.028, 0.06)
        s.starVisibility = 1
        return s
    }

    private func params(_ values: [String: ParamValue] = [:]) -> ParameterSet {
        ThemeRegistry.parameterSet(for: VolcanoRimModel.id, state: ThemeState(values: values))
    }

    private func model() -> VolcanoRimModel {
        var m = VolcanoRimModel()
        m.mood = .molten
        m.setSky(night())
        return m
    }

    /// Steps `model` for `seconds` at 60 fps and returns the last frame; `each` sees every frame.
    @discardableResult
    private func run(_ model: inout VolcanoRimModel, seconds: Double, _ values: [String: ParamValue] = [:],
                     quality: QualityLevel = .high, each: ((VolcanoFrame) -> Void)? = nil) -> VolcanoFrame {
        let p = params(values)
        let n = max(1, Int((seconds * 60).rounded()))
        var frame: VolcanoFrame?
        for _ in 0..<n {
            let f = model.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: quality)
            each?(f)
            frame = f
        }
        return frame!
    }

    private func excitement(energy: Float = 0, tension: Float = 0, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = energy
        e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
        e.tension = tension
        e.reduceMotion = reduceMotion
        return e
    }

    private func moment(_ strength: Float, drop: Bool = false, energy: Float = 0.5, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = excitement(energy: energy, reduceMotion: reduceMotion)
        e.moment = BigMoment(kind: .chord, strength: strength, low: true, isDrop: drop)
        if drop { e.drop = 1 }
        return e
    }

    private func alive(_ list: [LavaParticle]) -> Int {
        var n = 0
        for b in list where b.alive { n += 1 }
        return n
    }

    private func aliveEmbers(_ list: [Ember]) -> Int {
        var n = 0
        for e in list where e.alive { n += 1 }
        return n
    }

    // MARK: - The world

    func testVolcanoDefaults() throws {
        XCTAssertEqual(VolcanoRimModel.id, "volcano-rim")
        XCTAssertEqual(VolcanoRimModel.displayName, "Volcano Rim")
        XCTAssertEqual(ThemeRegistry.resolve(VolcanoRimModel.id), VolcanoRimModel.id)
        XCTAssertTrue(ThemeRegistry.isWorld(VolcanoRimModel.id))
        let ids = ThemeRegistry.entries.map(\.id)
        let plains = try XCTUnwrap(ids.firstIndex(of: LightningPlainsModel.id))
        XCTAssertEqual(ids[plains + 1], VolcanoRimModel.id, "registered after the plains")
        assertValidParameters(VolcanoRimModel.parameters)
        let specIDs = VolcanoRimModel.parameters.map(\.id)
        XCTAssertEqual(specIDs, ["visual", "activity", "plume", "light.hold", "aurora.mode", "meteors.mode", "keys.show",
                                 "keys.height"])
        XCTAssertEqual(VolcanoRimModel.visuals, ["Lava Lake", "Magma Veins", "Galaxy Warp"])
        XCTAssertEqual(VolcanoRimModel.surpriseCount, 5)
        let p = params()
        XCTAssertEqual(p.choice("visual"), "Lava Lake")
        XCTAssertEqual(p.choice("light.hold"), SkyHold.deepNight.rawValue, "deep night by default")
        // The mood (spec §10).
        let molten = Mood.molten
        XCTAssertEqual(molten.energy, 0.85)
        XCTAssertEqual(molten.warmth, 0.95)
        XCTAssertEqual(molten.brightness, 0.4)
        XCTAssertEqual(molten.space, 0.75)
        XCTAssertEqual(molten.motion, 0.65)
        // The pools (plan Task 11).
        var m = model()
        let f = run(&m, seconds: 0.5)
        XCTAssertEqual(f.cells.count, 64)
        XCTAssertEqual(f.blobs.count, 24)
        XCTAssertEqual(f.bombs.count, 16)
        XCTAssertEqual(f.embers.count, 400)
        XCTAssertEqual(f.strokes.count, 4)
        XCTAssertEqual(f.fountains.count, 2)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertNil(f.veins)
        XCTAssertNil(f.warp)
    }

    // MARK: - Notes

    func testNoteBrightensTheCellWhereItsKeyFalls() {
        var m = model()
        run(&m, seconds: 0.2)
        for note in [UInt8(30), 60, 96] {
            let target = VolcanoCrater.lakePoint(for: note)
            let expected = VolcanoRimModel.nearestCell(target, in: m.cells)
            m.handle(.noteOn(note: note, velocity: 0.9))
            let f = run(&m, seconds: 1.0 / 60)
            var brightest = -1
            var best: Float = -1
            for (k, c) in f.cells.enumerated() where c.glow > best {
                best = c.glow
                brightest = k
            }
            XCTAssertEqual(brightest, expected, "note \(note)")
            XCTAssertGreaterThan(best, 0.5, "note \(note)")
            m.handle(.noteOff(note: note))
            run(&m, seconds: 6)
        }
        // Low notes land on the left of the lake, high on the right, all of them on it.
        let low = VolcanoCrater.lakePoint(for: 24)
        let mid = VolcanoCrater.lakePoint(for: 64)
        let high = VolcanoCrater.lakePoint(for: 104)
        XCTAssertLessThan(low.x, -100)
        XCTAssertGreaterThan(high.x, 100)
        XCTAssertLessThan(abs(mid.x), 40)
        for note in UInt8(21)...UInt8(108) {
            let p = VolcanoCrater.lakePoint(for: note)
            XCTAssertLessThan(simd_length(p), VolcanoCrater.lakeRadius, "note \(note)")
        }
        // The glow fades again.
        let after = run(&m, seconds: 8)
        var most: Float = 0
        for c in after.cells { most = max(most, c.glow) }
        XCTAssertLessThan(most, 0.01)
    }

    func testLowNotesSpitOneToThreeBlobs() {
        var m = model()
        run(&m, seconds: 0.2)
        let before = alive(m.blobs)
        XCTAssertEqual(before, 0)
        m.handle(.noteOn(note: 40, velocity: 1))
        var f = run(&m, seconds: 1.0 / 60)
        let hard = alive(f.blobs)
        XCTAssertEqual(hard, 3, "a hard low note spits three")
        // They fly up and come down again, hot.
        var highest: Float = 0
        f = run(&m, seconds: 1.5, each: { frame in
            for b in frame.blobs where b.alive { highest = max(highest, b.position.z) }
        })
        XCTAssertGreaterThan(highest, 8)
        f = run(&m, seconds: 8)
        XCTAssertEqual(alive(f.blobs), 0, "landed, splashed and gone")
        // A soft one spits one; above C3, none.
        m.handle(.noteOn(note: 36, velocity: 0.15))
        f = run(&m, seconds: 1.0 / 60)
        XCTAssertEqual(alive(f.blobs), 1)
        run(&m, seconds: 8)
        m.handle(.noteOn(note: 48, velocity: 1))
        m.handle(.noteOn(note: 72, velocity: 1))
        f = run(&m, seconds: 1.0 / 60)
        XCTAssertEqual(alive(f.blobs), 0, "C3 and up don't spit")
        // Not under the other visuals.
        var veins = model()
        run(&veins, seconds: 0.2, ["visual": .choice("Magma Veins")])
        veins.handle(.noteOn(note: 30, velocity: 1))
        let v = run(&veins, seconds: 1.0 / 60, ["visual": .choice("Magma Veins")])
        XCTAssertEqual(alive(v.blobs), 0)
    }

    func testHeldTimeBloomsAtOnce() {
        var m = model()
        run(&m, seconds: 0.2)
        let p = params()
        m.handle(.noteOn(note: 33, velocity: 0.9))
        let f = m.step(dt: 0, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        var up: Float = 0
        for b in f.blobs where b.alive { up = max(up, b.position.z) }
        XCTAssertGreaterThan(up, 3, "a blob spat while time is held shows at once, up its arc")
        var lit: Float = 0
        for c in f.cells { lit = max(lit, c.glow) }
        XCTAssertGreaterThan(lit, 0.5)
        // And a moment's column stands at once.
        m.setExcitement(moment(1))
        let g = m.step(dt: 0, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let columnHeight = g.eruption?.height ?? 0
        XCTAssertGreaterThan(columnHeight, 1000)
        // Magma Veins: a vein opened while time is held shows fully grown.
        var veins = MagmaVeins()
        veins.noteOn(60, velocity: 0.8, at: 0)
        veins.step(dt: 0, energy: 0, reaction: 1)
        var reach: Float = 0
        for v in veins.veins where v.alive { reach = max(reach, v.reach) }
        XCTAssertEqual(reach, 1, accuracy: 1e-5)
    }

    // MARK: - The moment and the drop

    func testEruptionScalesWithStrength() throws {
        let width = 2 * VolcanoCrater.lakeRadius
        XCTAssertEqual(Eruption.peak(strength: 0.3), 3 * width, accuracy: 1)
        XCTAssertEqual(Eruption.peak(strength: 1), 6 * width, accuracy: 1)
        XCTAssertLessThan(Eruption.peak(strength: 0.5), Eruption.peak(strength: 0.8))
        XCTAssertEqual(Eruption.bombs(strength: 0.3), 4)
        XCTAssertEqual(Eruption.bombs(strength: 1), 16)
        XCTAssertLessThan(Eruption.bombs(strength: 0.5), Eruption.bombs(strength: 0.9))
        for (strength, bombs) in [(Float(0.35), Eruption.bombs(strength: 0.35)), (Float(1), 16)] {
            var m = model()
            run(&m, seconds: 0.2)
            m.setExcitement(moment(strength))
            var top: Float = 0
            let f = run(&m, seconds: 1.2, each: { frame in top = max(top, frame.eruption?.height ?? 0) })
            let e = try XCTUnwrap(f.eruption)
            XCTAssertEqual(top, Eruption.peak(strength: strength), accuracy: 1, "rises to its peak in 0.8 s")
            XCTAssertEqual(alive(f.bombs), bombs, "strength \(strength)")
            XCTAssertGreaterThan(e.light, 0.5)
            XCTAssertGreaterThan(f.billow, 0.5, "the plume billows")
        }
        // The column rises in 0.8 s.
        let rising = Eruption(age: 0.4, strength: 1)
        XCTAssertLessThan(rising.height, Eruption.peak(strength: 1))
        XCTAssertGreaterThan(rising.height, 0.5 * Eruption.peak(strength: 1))
        // Bombs come down on the far rim.
        var m = model()
        run(&m, seconds: 0.2)
        m.setExcitement(moment(1))
        var landed: [SIMD3<Float>] = []
        run(&m, seconds: 12, each: { frame in
            for b in frame.bombs where b.alive && b.landed == 0 { landed.append(b.position) }
        })
        XCTAssertGreaterThanOrEqual(landed.count, 12)
        for p in landed {
            let r = simd_length(SIMD2(p.x, p.y) - VolcanoCrater.wallCentre)
            XCTAssertGreaterThan(r, VolcanoCrater.benchRadius, "past the bench")
            XCTAssertGreaterThan(p.y, 0, "across the crater")
        }
    }

    func testEruptionsNeverStack() {
        var m = model()
        run(&m, seconds: 0.2)
        m.setExcitement(moment(1))
        run(&m, seconds: 1)
        m.setExcitement(moment(1))
        let f = run(&m, seconds: 1.0 / 60)
        let age = f.eruption?.age ?? 0
        XCTAssertGreaterThan(age, 0.9, "a second moment during the eruption doesn't start another")
    }

    func testDropOpensTheBreach() throws {
        var m = model()
        run(&m, seconds: 0.2)
        var f = run(&m, seconds: 0.5)
        XCTAssertEqual(f.breach, 0)
        XCTAssertNil(f.breachAge)
        // A moment alone doesn't.
        m.setExcitement(moment(0.8))
        f = run(&m, seconds: 1)
        XCTAssertEqual(f.breach, 0)
        run(&m, seconds: 8)
        // The drop does: the new river pours, then crusts over.
        m.setExcitement(moment(1, drop: true))
        f = run(&m, seconds: 1)
        XCTAssertGreaterThan(f.breach, 0.95)
        XCTAssertNotNil(f.breachAge)
        f = run(&m, seconds: 20)
        XCTAssertGreaterThan(f.breach, 0.1)
        XCTAssertLessThan(f.breach, 0.9, "crusting over")
        f = run(&m, seconds: 30)
        XCTAssertEqual(f.breach, 0)
        XCTAssertNil(f.breachAge)
        // The river runs from the lake's margin to the breach in the far wall.
        let start = VolcanoCrater.riverStart
        let end = VolcanoCrater.riverEnd
        XCTAssertEqual(simd_length(start), VolcanoCrater.lakeRadius, accuracy: 0.5)
        XCTAssertGreaterThan(simd_length(end - VolcanoCrater.wallCentre), VolcanoCrater.footRadius)
        XCTAssertGreaterThan(end.y, start.y)
    }

    // MARK: - Energy

    func testEnergyDrivesFountainsRiverEmbersAndLightning() {
        XCTAssertEqual(VolcanoRimModel.lightningRate(energy: 0), 0.05, accuracy: 1e-6)
        XCTAssertEqual(VolcanoRimModel.lightningRate(energy: 1), 0.6, accuracy: 1e-6)
        XCTAssertLessThan(VolcanoRimModel.fountainHeight(energy: 0), VolcanoRimModel.fountainHeight(energy: 1))
        XCTAssertLessThan(VolcanoRimModel.riverFlow(energy: 0), VolcanoRimModel.riverFlow(energy: 1))
        XCTAssertLessThan(VolcanoRimModel.emberRate(energy: 0), VolcanoRimModel.emberRate(energy: 1))
        var results: [(fountain: Float, river: Float, embers: Int, strokes: Int, convection: Float)] = []
        for energy in [Float(0), 1] {
            var m = model()
            m.setExcitement(excitement(energy: energy))
            var fountain: Float = 0, embers = 0, strokes = 0, steps = 0
            let f = run(&m, seconds: 200, each: { frame in
                for ft in frame.fountains { fountain += ft.height }
                embers = max(embers, self.aliveEmbers(frame.embers))
                strokes += frame.ambience.events.filter { $0.source == .plumeThunder }.count
                steps += 1
            })
            results.append((fountain / Float(2 * steps), f.river, embers, strokes, f.convection))
        }
        XCTAssertGreaterThan(results[1].fountain, 3 * results[0].fountain, "fountains climb with Energy")
        XCTAssertGreaterThan(results[1].river, 0.95)
        XCTAssertLessThan(results[0].river, 0.25)
        XCTAssertGreaterThan(results[1].embers, 2 * results[0].embers)
        XCTAssertGreaterThan(results[1].convection, results[0].convection)
        // 0.05 a second over 200 s is about 10 strokes; 0.6 a second about 120.
        XCTAssertGreaterThanOrEqual(results[0].strokes, 2)
        XCTAssertLessThanOrEqual(results[0].strokes, 24)
        XCTAssertGreaterThanOrEqual(results[1].strokes, 80)
        XCTAssertLessThanOrEqual(results[1].strokes, 165)
    }

    func testChordsSpeedTheConvection() {
        let alone = VolcanoRimModel.convection(energy: 0.3, held: 1, activity: 0.5)
        let chord = VolcanoRimModel.convection(energy: 0.3, held: 5, activity: 0.5)
        XCTAssertGreaterThan(chord, alone * 1.3)
        var m = model()
        m.setExcitement(excitement(energy: 0.3))
        let single = run(&m, seconds: 0.5).convection
        for n in [UInt8(48), 52, 55, 59, 62] { m.handle(.noteOn(note: n, velocity: 0.6)) }
        let held = run(&m, seconds: 0.5).convection
        XCTAssertGreaterThan(held, single * 1.3)
    }

    func testTensionSwellsAndBeatsWithThePulse() {
        var m = model()
        m.pulse = InstrumentPulse(bpm: 120, gate: 0.5)
        m.setExcitement(excitement(energy: 0.4, tension: 0.9))
        var beats: [Float] = []
        let f = run(&m, seconds: 2.25, each: { frame in beats.append(frame.beat) })
        XCTAssertEqual(f.swell, 0.9, accuracy: 1e-5)
        var peaks = 0
        for i in 1..<(beats.count - 1) where beats[i] > beats[i - 1] + 0.3 { peaks += 1 }
        XCTAssertEqual(peaks, 4, "a beat each half-second at 120 bpm")
        var calm = model()
        calm.setExcitement(excitement(energy: 0.4, tension: 0))
        var loudest: Float = 0
        run(&calm, seconds: 2, each: { frame in loudest = max(loudest, frame.beat) })
        XCTAssertEqual(loudest, 0, "no tension, no beat")
    }

    // MARK: - Motion and flashes

    func testShakeOnlyOnEruptionAndNeverUnderReduceMotion() {
        var m = model()
        run(&m, seconds: 0.2)
        m.setExcitement(moment(1))
        var most: Float = 0
        run(&m, seconds: 2, each: { frame in most = max(most, simd_length(frame.cameraShake)) })
        XCTAssertGreaterThan(most, 0.05)
        XCTAssertLessThanOrEqual(most, VolcanoRimModel.shakeDegrees * 1.25 + 1e-4)
        var r = model()
        run(&r, seconds: 0.2)
        r.setExcitement(moment(1, reduceMotion: true))
        var any: Float = 0
        run(&r, seconds: 2, each: { frame in any = max(any, simd_length(frame.cameraShake)) })
        XCTAssertEqual(any, 0, "Reduce Motion: no camera shake")
        // A breach without an eruption shakes nothing either way.
        var q = model()
        run(&q, seconds: 0.2)
        var quiet: Float = 0
        run(&q, seconds: 2, each: { frame in quiet = max(quiet, simd_length(frame.cameraShake)) })
        XCTAssertEqual(quiet, 0)
    }

    func testPoolsNeverGrow() {
        for visual in VolcanoRimModel.visuals {
            var m = model()
            var k = 0
            var bad = 0
            run(&m, seconds: 6, ["visual": .choice(visual)], each: { frame in
                if frame.cells.count != 64 || frame.blobs.count != 24 || frame.bombs.count != 16 { bad += 1 }
                if frame.embers.count != 400 || frame.strokes.count != 4 { bad += 1 }
                if let v = frame.veins, v.veins.count != 96 || v.plates.count != MagmaVeins.plateCount { bad += 1 }
            })
            // A flood: 34 notes a frame, a big moment every half second, a drop now and then.
            for i in 0..<360 {
                for j in 0..<34 { m.handle(.noteOn(note: UInt8(21 + (i * 34 + j) % 60), velocity: 1)) }
                if i % 30 == 0 { m.setExcitement(moment(1, drop: i % 120 == 0, energy: 1)) }
                let f = m.step(dt: 1.0 / 60, params: params(["visual": .choice(visual)]), roles: RoleValues(),
                               inputs: InputFrame(), quality: .high)
                if f.cells.count != 64 || f.blobs.count != 24 || f.bombs.count != 16 { bad += 1 }
                if f.embers.count != 400 || f.strokes.count != 4 || f.surprises.count > 5 { bad += 1 }
                if let v = f.veins, v.veins.count != 96 { bad += 1 }
                for j in 0..<34 { m.handle(.noteOff(note: UInt8(21 + (i * 34 + j) % 60))) }
                k += 1
            }
            XCTAssertEqual(bad, 0, visual)
            XCTAssertEqual(k, 360)
        }
    }

    func testCrustNeverJumpsInsideTheLake() {
        // Over five minutes of hard playing the crust drifts, splits at the spreading centre and sinks at the margin, and
        // no plate inside the lake ever jumps: a seed that moves far in one step left from well past the margin and came
        // back on top of another (a split, so its new crack opens out of nothing).
        var m = model()
        m.setExcitement(excitement(energy: 1))
        var previous = m.cells
        var jumps = 0, splits = 0
        run(&m, seconds: 300, each: { frame in
            for (i, c) in frame.cells.enumerated() {
                let moved = simd_length(c.position - previous[i].position)
                guard moved > 3 else { continue }
                jumps += 1
                let from = simd_length(previous[i].position)
                XCTAssertGreaterThan(from, VolcanoCrater.lakeRadius * 1.5)
                var nearest = Float.greatestFiniteMagnitude
                for (j, other) in frame.cells.enumerated() where j != i {
                    nearest = min(nearest, simd_length(other.position - c.position))
                }
                XCTAssertLessThan(nearest, 0.5)
                XCTAssertLessThan(c.birth, 0.01)
                splits += 1
            }
            previous = frame.cells
        })
        XCTAssertGreaterThan(splits, 5, "the crust renews itself")
        XCTAssertEqual(jumps, splits)
    }

    /// Review focus 1: a hammered minute (fff chords at 8 a second, moments on Lots) through the scene director: the
    /// light the world asks for, through a flash limiter as the renderer runs it, never flashes more than three times a
    /// second; eruptions never stack (each starts only once the last has ended); breaches never stack.
    func testHammeredMinuteStaysInsideTheFlashLimiter() throws {
        let d = SceneDirector(themeID: VolcanoRimModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var settings = d.excitementSettings
        settings.moments = .lots
        d.excitementSettings = settings
        var limiter = FlashLimiter()
        var worst = 0, starts: [Double] = [], breaches: [Double] = [], moments = 0
        var lastAge: Float = 99
        var lastBreach: Float = 99
        let chord: [UInt8] = [36, 40, 43, 48]
        for i in 0..<3600 {
            let t = Double(i) / 60
            var events: [PerformanceEvent] = []
            if i % 8 == 0 { for n in chord { events.append(.noteOn(note: n, velocity: 1)) } }
            if i % 8 == 4 { for n in chord { events.append(.noteOff(note: n)) } }
            d.handle(events, at: t)
            let frame = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: .high) as? VolcanoFrame)
            if d.excitementFrame.moment != nil { moments += 1 }
            let limited = limiter.limit(exposure: 1 + 0.9 * frame.flashRequest, sparkle: 1, dt: 1.0 / 60)
            _ = limited
            worst = max(worst, limiter.recent)
            if let e = frame.eruption {
                if e.age < lastAge { starts.append(t) }
                lastAge = e.age
            } else {
                lastAge = 99
            }
            if let b = frame.breachAge {
                if b < lastBreach { breaches.append(t) }
                lastBreach = b
            } else {
                lastBreach = 99
            }
        }
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
        XCTAssertGreaterThan(moments, 5, "it was hammered")
        XCTAssertGreaterThan(starts.count, 2)
        XCTAssertLessThanOrEqual(starts.count, moments)
        for k in 1..<max(1, starts.count) {
            let gap = starts[k] - starts[k - 1]
            XCTAssertGreaterThanOrEqual(gap, Double(Eruption.life) - 0.05, "eruptions never stack")
        }
        for k in 1..<max(1, breaches.count) {
            let gap = breaches[k] - breaches[k - 1]
            XCTAssertGreaterThanOrEqual(gap, 3.9, "breaches never stack")
        }
    }

    // MARK: - Surprises and sound

    func testSurprisesAllPlayAndEnd() {
        for kind in VolcanoSurprise.Kind.allCases {
            var m = model()
            run(&m, seconds: 0.2)
            var e = excitement(energy: 0.4)
            e.surprise = WorldSurprise(index: kind.rawValue, seed: 0xABC + UInt64(kind.rawValue))
            m.setExcitement(e)
            let f = run(&m, seconds: 0.1)
            var found = false
            for s in f.surprises where s.kind == kind { found = true }
            XCTAssertTrue(found, "\(kind)")
            let later = run(&m, seconds: Double(VolcanoSurprise.duration(kind)) + 0.5)
            var still = false
            for s in later.surprises where s.kind == kind { still = true }
            XCTAssertFalse(still, "\(kind) ends")
        }
    }

    /// The volcano family (spec §8.3; plan Task 10): its six sources up and the stand-ins gone; the lake's surge and glow
    /// rising with the convection, tension, Energy, lit cracks, an eruption and a breach; an eruption sends its boom as
    /// late as the lake is far (510 m from the rim: 1.49 s) and the plume's cracks theirs (1.2–2 s, where each stroke is).
    func testVolcanoAmbience() {
        let levels = VolcanoRimModel.levels(night())
        for source: AmbienceSource in [.ventRumble, .lavaHiss, .steamVent, .rockfall, .eruptionBoom, .plumeThunder] {
            XCTAssertGreaterThan(levels[source] ?? 0, 0, "\(source) is up")
        }
        for standIn: AmbienceSource in [.fire, .breeze, .thunderRoll] { XCTAssertNil(levels[standIn], "the stand-in \(standIn) is gone") }
        XCTAssertNotNil(levels[.wind], "the wind over the rim")
        let calm = VolcanoRimModel.lake(convection: 0.35, swell: 0, burst: 0, cells: [], energy: 0, eruption: 0, breach: 0)
        let wild = VolcanoRimModel.lake(convection: 3, swell: 1, burst: 1, cells: [], energy: 1, eruption: 1, breach: 1)
        XCTAssertLessThan(calm.surge, 0.3)
        XCTAssertLessThan(calm.glow, 0.3)
        XCTAssertEqual(wild.surge, 1, accuracy: 1e-9)
        XCTAssertEqual(wild.glow, 1, accuracy: 1e-9)
        var lit = VolcanoRimModel().cells
        for i in 0..<4 { lit[i].glow = 1 }
        let notes = VolcanoRimModel.lake(convection: 0.35, swell: 0, burst: 0, cells: lit, energy: 0, eruption: 0, breach: 0)
        XCTAssertGreaterThan(notes.glow, calm.glow + 0.3, "notes lighting the cracks brighten the hiss")
        XCTAssertEqual(VolcanoRimModel.soundDelay(to: .zero), 1.486, accuracy: 0.005)

        var m = model()
        let before = run(&m, seconds: 0.2)
        m.setExcitement(moment(1))
        let f = run(&m, seconds: 1.0 / 60)
        let boom = f.ambience.events.filter { $0.source == .eruptionBoom }
        XCTAssertEqual(boom.count, 1, "the eruption's boom")
        XCTAssertEqual(boom.first?.delay ?? 0, 1.486, accuracy: 0.005)
        XCTAssertEqual(boom.first?.strength ?? 0, 1, accuracy: 1e-6)
        let cracks = f.ambience.events.filter { $0.source == .plumeThunder }
        XCTAssertGreaterThanOrEqual(cracks.count, 1, "the lightning cluster's first crack")
        for c in cracks {
            XCTAssertTrue((1.2...2.0).contains(c.delay), "a crack \(c.delay) s late")
            XCTAssertTrue((-1...1).contains(c.pan))
        }
        XCTAssertGreaterThan(f.ambience.lakeSurge, before.ambience.lakeSurge + 0.4, "the eruption surges the lake")
        XCTAssertGreaterThan(f.ambience.lakeGlow, before.ambience.lakeGlow + 0.3, "and lights it")
        XCTAssertTrue(f.ambience.thunderQueue.isEmpty, "no storm thunder: the plume's cracks are its own")
        let next = run(&m, seconds: 1.0 / 60)
        XCTAssertTrue(next.ambience.events.filter { $0.source == .eruptionBoom }.isEmpty, "a boom is sent once")
    }

    /// The surprises' sounds (plan Task 10): a rockfall and a steam blast each send their one-shot once, from where on the
    /// wall they are (left or right, as the picture has it), as late as the wall is far (1.2–3 s) and darker the farther.
    func testRockfallAndSteamBlastSoundWhereTheyAre() {
        for kind in [VolcanoSurprise.Kind.rockfall, .steamBlast] {
            let source: AmbienceSource = kind == .rockfall ? .rockfall : .steamVent
            for seed: UInt64 in 1...6 {
                var m = model()
                run(&m, seconds: 0.2)
                var e = excitement(energy: 0.4)
                e.surprise = WorldSurprise(index: kind.rawValue, seed: seed &* 0x9E37 &+ 5)
                m.setExcitement(e)
                let f = run(&m, seconds: 1.0 / 60)
                let sent = f.ambience.events.filter { $0.source == source }
                XCTAssertEqual(sent.count, 1, "\(kind), seed \(seed)")
                guard let one = sent.first, let surprise = f.surprises.first(where: { $0.kind == kind }) else { continue }
                XCTAssertTrue((1.2...3).contains(one.delay), "\(kind): \(one.delay) s late")
                XCTAssertEqual(one.pan < 0, surprise.angle < 0, "\(kind): heard on its side (angle \(surprise.angle), pan \(one.pan))")
                XCTAssertTrue((0...1).contains(one.distance))
                XCTAssertGreaterThan(one.strength, 0.75)
                let later = run(&m, seconds: 1)
                XCTAssertTrue(later.ambience.events.filter { $0.source == source }.isEmpty, "\(kind): sent once")
            }
        }
    }

    // MARK: - Magma Veins

    func testChordsConnectVeins() {
        var v = MagmaVeins()
        v.noteOn(60, velocity: 0.8, at: 1.00)
        v.noteOn(64, velocity: 0.8, at: 1.01)
        v.noteOn(67, velocity: 0.8, at: 1.02)
        v.step(dt: 1.0 / 60, energy: 0.5, reaction: 1)
        var linked = 0
        for vein in v.veins where vein.alive && vein.link != nil { linked += 1 }
        XCTAssertEqual(linked, 2, "the chord's three veins are joined in a chain")
        // A note on its own joins nothing.
        v.noteOn(40, velocity: 0.8, at: 3)
        v.step(dt: 1.0 / 60, energy: 0.5, reaction: 1)
        var lone = 0
        for vein in v.veins where vein.alive && vein.note == 40 && vein.link == nil { lone += 1 }
        XCTAssertEqual(lone, 1)
        // A vein opens at its key's place, low left, high right, and cools to black once let go.
        var low: Float = 1, high: Float = 0
        for vein in v.veins where vein.alive {
            if vein.note == 40 { low = vein.origin }
            if vein.note == 67 { high = vein.origin }
        }
        XCTAssertLessThan(low, high)
        for n in [UInt8(60), 64, 67, 40] { v.noteOff(n) }
        for _ in 0..<(60 * 12) { v.step(dt: 1.0 / 60, energy: 0, reaction: 1) }
        XCTAssertEqual(v.aliveCount, 0)
    }

    func testMomentSplitsThePlates() {
        var v = MagmaVeins()
        XCTAssertEqual(v.split, 0)
        XCTAssertEqual(v.plates.count, MagmaVeins.plateCount)
        v.moment(strength: 0.8, drop: false)
        XCTAssertGreaterThanOrEqual(v.split, 0.8)
        for _ in 0..<(60 * 25) { v.step(dt: 1.0 / 60, energy: 0, reaction: 1) }
        XCTAssertLessThan(v.split, 0.01, "closing again")
        v.moment(strength: 0.3, drop: true)
        XCTAssertEqual(v.split, 1, "the drop splits them all the way")
        // Through the world: the chosen visual carries the veins, and a moment splits its plates.
        var m = model()
        let values: [String: ParamValue] = ["visual": .choice("Magma Veins")]
        run(&m, seconds: 0.2, values)
        for n in [UInt8(48), 55, 60, 64] { m.handle(.noteOn(note: n, velocity: 0.9)) }
        m.setExcitement(moment(0.9))
        let f = run(&m, seconds: 0.2, values)
        let frame = f.veins
        XCTAssertNotNil(frame)
        XCTAssertGreaterThan(frame?.split ?? 0, 0.8)
        var open = 0
        for vein in frame?.veins ?? [] where vein.alive { open += 1 }
        XCTAssertEqual(open, 4)
        XCTAssertNil(f.warp)
    }

    func testVeinPoolNeverGrows() {
        var v = MagmaVeins()
        for i in 0..<400 {
            v.noteOn(UInt8(21 + i % 88), velocity: 1, at: Double(i) * 0.01)
            v.step(dt: 0.01, energy: 1, reaction: 1)
        }
        XCTAssertEqual(v.veins.count, 96)
        XCTAssertLessThanOrEqual(v.aliveCount, 96)
        for vein in v.veins where vein.alive {
            if let l = vein.link { XCTAssertTrue(v.veins[l].alive) }
            let path = vein.path()
            XCTAssertEqual(path.count, 9)
            let branches = vein.branches()
            XCTAssertGreaterThanOrEqual(branches.count, 2)
        }
    }
}
