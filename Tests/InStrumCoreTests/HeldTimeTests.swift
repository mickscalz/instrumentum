import XCTest
@testable import InStrumCore

/// Small Wins Task 3 (spec §3, §4, §6; Review focus 3 and 6): the director's clock. Held time stops the sky, the weather
/// and the world where they are while notes still arrive, and eases back in; the sleep dim slows the world (not the
/// weather), slides the sun toward night and lowers the exposure; Reduce Motion halves the renderers' dt and keeps Galaxy
/// Warp adrift. Assertions are plain statements over named locals, so the type-checker finishes quickly in CI.
final class HeldTimeTests: XCTestCase {
    static let start = Date(timeIntervalSince1970: 1_793_000_000)
    static let frameDt = 1.0 / 60

    /// A director on a frozen wall clock (quick mode then runs on the steps alone).
    private func director(_ id: String, sky: SkySettings? = nil) -> SceneDirector {
        let d = SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Self.start
        d.clock = { start }
        if let sky { d.sky.reset(settings: sky) }
        return d
    }

    /// Steps `d` on from `t` for `seconds`, `dt` a step, and returns the last frame.
    @discardableResult
    private func run(_ d: SceneDirector, _ t: inout Double, seconds: Double, dt: Double = 1.0 / 60) -> Any {
        var frame: Any = ()
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n {
            t += dt
            frame = d.step(dt: dt, t: t, quality: .lite)
        }
        return frame
    }

    /// A phrase and a chord, all let go by 1.5 s, then the rest of 2 s: the moment held at 2 s has the playing in it.
    private func playTwoSeconds(_ d: SceneDirector, _ t: inout Double) {
        run(d, &t, seconds: 0.5)
        d.handle([.noteOn(note: 60, velocity: 0.8), .noteOn(note: 64, velocity: 0.8), .noteOn(note: 67, velocity: 0.8),
                  .chord(notes: [60, 64, 67])], at: t)
        run(d, &t, seconds: 0.5)
        d.handle([.noteOff(note: 60), .noteOff(note: 64), .noteOff(note: 67)], at: t)
        run(d, &t, seconds: 0.25)
        d.handle([.noteOn(note: 72, velocity: 0.6)], at: t)
        run(d, &t, seconds: 0.25)
        d.handle([.noteOff(note: 72)], at: t)
        run(d, &t, seconds: 0.5)
    }

    func testConstants() {
        XCTAssertEqual(SceneDirector.holdEase, 0.6)
        XCTAssertEqual(SceneDirector.nightAltitude, -14)
        XCTAssertEqual(GalaxyWarp.driftSpeed, 0.1)
        XCTAssertEqual(InputID.reduceMotion.rawValue, "comfort.reduceMotion")
    }

    /// Every theme, held after 2 s: the first held frame is the 60th's (field by field, the ambience aside), and so is the
    /// sky. Nothing in any world or in the sky runs on while time is held.
    func testAHeldSecondChangesNothing() {
        for entry in ThemeRegistry.entries {
            let d = director(entry.id)
            var t = 0.0
            playTwoSeconds(d, &t)
            d.controls.holdRequested = true
            let first = run(d, &t, seconds: Self.frameDt)
            let firstSky = d.lastSky
            let last = run(d, &t, seconds: 59 * Self.frameDt)
            let held = d.holding
            XCTAssertTrue(held, entry.id)
            XCTAssertEqual(d.timeScale, 0, entry.id)
            XCTAssertEqual(d.visualDt, 0, entry.id)
            let diff = Self.firstDifference(first, last, skipping: ["ambience"])
            XCTAssertNil(diff, "\(entry.id): \(diff ?? "")")
            let skyDiff = Self.firstDifference(firstSky as Any, d.lastSky as Any)
            XCTAssertNil(skyDiff, "\(entry.id) sky: \(skyDiff ?? "")")
        }
    }

    /// A note played while time is held still makes its ripple, on the next frame, and then that moment holds too.
    func testNotesStillArriveWhileHeld() throws {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        run(d, &t, seconds: 1)
        d.controls.holdRequested = true
        let before = try XCTUnwrap(run(d, &t, seconds: 0.25) as? LakeFrame)
        d.handle([.noteOn(note: 62, velocity: 0.9)], at: t)
        let after = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? LakeFrame)
        XCTAssertEqual(after.ripples.count, before.ripples.count + 1, "the note's ripple is there at once")
        let later = run(d, &t, seconds: 60 * Self.frameDt)
        let diff = Self.firstDifference(after, later, skipping: ["ambience"])
        XCTAssertNil(diff, diff ?? "")
    }

    /// Let go, time eases back in on a smoothstep over 0.6 s: half speed at +0.3 s, full from +0.6 s, and the world has
    /// gained 0.3 s by then.
    func testReleaseEasesTimeBackIn() throws {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        run(d, &t, seconds: 1)
        d.controls.holdRequested = true
        run(d, &t, seconds: 1)
        d.controls.holdRequested = false
        let released = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? LakeFrame)
        XCTAssertFalse(d.holding)
        XCTAssertEqual(d.timeScale, 0, "the first step let go starts the ease")
        run(d, &t, seconds: 0.3)
        XCTAssertEqual(d.timeScale, 0.5, accuracy: 0.02)
        let eased = try XCTUnwrap(run(d, &t, seconds: 0.3) as? LakeFrame)
        XCTAssertEqual(d.timeScale, 1, accuracy: 1e-6)
        let gained = eased.time - released.time
        XCTAssertEqual(gained, 0.3, accuracy: 0.02)
        let on = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? LakeFrame)
        XCTAssertEqual(d.timeScale, 1)
        XCTAssertEqual(on.time - eased.time, Self.frameDt, accuracy: 1e-9)
    }

    /// Melbourne at sunset in real time, held for 30 minutes: the sun stands still while held, then catches up with the
    /// clock as time eases back in, never more than 0.5° a frame, and from +0.6 s it is where an unheld sky's is.
    func testALongHoldInRealTimeCatchesUpSmoothly() throws {
        var sky = SkySettings()
        sky.timeMode = .realTime
        sky.cityID = "melbourne"
        let d = director(MoonlitLakeModel.id, sky: sky)
        let base = Date(timeIntervalSince1970: 1_793_003_600)   // 10 minutes before sunset (08:43 UT)
        var elapsed = 0.0
        d.clock = { base.addingTimeInterval(elapsed) }
        var t = 0.0
        for _ in 0..<30 {
            t += Self.frameDt
            elapsed += Self.frameDt
            _ = d.step(dt: Self.frameDt, t: t, quality: .lite)
        }
        d.controls.holdRequested = true
        t += Self.frameDt
        elapsed += Self.frameDt
        _ = d.step(dt: Self.frameDt, t: t, quality: .lite)
        let heldSun = try XCTUnwrap(d.lastSky).sun.altitude
        for _ in 0..<180 {   // 30 minutes, ten seconds a step: the world's dt is 0 either way
            t += 10
            elapsed += 10
            _ = d.step(dt: 10, t: t, quality: .lite)
            let sun = try XCTUnwrap(d.lastSky).sun.altitude
            XCTAssertEqual(sun, heldSun, "the sun stands still while time is held")
        }
        d.controls.holdRequested = false
        var previous = heldSun
        var biggest = 0.0
        for i in 1...60 {
            t += Self.frameDt
            elapsed += Self.frameDt
            _ = d.step(dt: Self.frameDt, t: t, quality: .lite)
            let sun = try XCTUnwrap(d.lastSky).sun.altitude
            biggest = max(biggest, abs(sun - previous))
            previous = sun
            if i >= 37 {   // +0.6 s: the first step let go is +0
                let unheld = director(MoonlitLakeModel.id, sky: sky)
                let now = base.addingTimeInterval(elapsed)
                unheld.clock = { now }
                _ = unheld.step(dt: Self.frameDt, t: 0, quality: .lite)
                let trueSun = try XCTUnwrap(unheld.lastSky).sun.altitude
                XCTAssertEqual(sun, trueSun, accuracy: 1e-6, "step \(i)")
            }
        }
        XCTAssertLessThanOrEqual(biggest, 0.5, "no jump")
        XCTAssertLessThan(previous, heldSun - 3, "it caught up with half an hour of sunset")
    }

    /// Quick mode (a 12-minute day) runs on the sky's dt: held for a minute the hour stands still, and a second after
    /// release it has moved on by 0.7 s of sky time (the ease takes 0.3 s of it), 0.0233 h.
    func testQuickModeResumesWhereItStopped() throws {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        run(d, &t, seconds: 1)
        d.controls.holdRequested = true
        run(d, &t, seconds: Self.frameDt)
        let held = try XCTUnwrap(d.lastSky).hourOfDay
        for _ in 0..<600 {
            run(d, &t, seconds: 0.1, dt: 0.1)
            let hour = try XCTUnwrap(d.lastSky).hourOfDay
            XCTAssertEqual(hour, held)
        }
        d.controls.holdRequested = false
        run(d, &t, seconds: 61 * Self.frameDt)   // the first step let go, then a second
        let advanced = try XCTUnwrap(d.lastSky).hourOfDay - held
        XCTAssertEqual(advanced, 0.0233, accuracy: 0.0005)
    }

    /// A world switched to while time is held starts still, and runs once time is let go.
    func testSwitchingWorldsWhileHeld() throws {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        playTwoSeconds(d, &t)
        d.controls.holdRequested = true
        run(d, &t, seconds: 0.5)
        d.switchTheme(to: GoldenHourBeachModel.id, state: ThemeState())
        let first = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? BeachFrame)
        let held = try XCTUnwrap(run(d, &t, seconds: 1) as? BeachFrame)
        let diff = Self.firstDifference(first, held, skipping: ["ambience"])
        XCTAssertNil(diff, diff ?? "")
        d.controls.holdRequested = false
        let running = try XCTUnwrap(run(d, &t, seconds: 1) as? BeachFrame)
        XCTAssertGreaterThan(running.swellTime, held.swellTime, "the beach runs once time is let go")
        XCTAssertNotNil(Self.firstDifference(held, running, skipping: ["ambience"]))
    }

    /// The soft pedal holds the moment while it is down; the setting switches it to the sostenuto pedal, or off.
    func testTheSoftPedalHoldsAndTheSettingSwitchesIt() {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        run(d, &t, seconds: 0.1)
        XCTAssertEqual(d.controls.holdPedal, .soft, "the soft pedal by default")
        d.handle([.control(controller: 67, value: 1)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding, "soft pedal down")
        d.handle([.control(controller: 67, value: 0)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertFalse(d.holding, "soft pedal up")
        d.handle([.control(controller: 67, value: 64.0 / 127)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding, "64 is down")
        d.handle([.control(controller: 67, value: 63.0 / 127)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertFalse(d.holding, "63 is up")

        d.controls.holdPedal = .sostenuto
        d.handle([.control(controller: 66, value: 1)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding, "sostenuto down")
        d.handle([.control(controller: 66, value: 0), .control(controller: 67, value: 1)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertFalse(d.holding, "the soft pedal no longer holds")
        d.handle([.control(controller: 67, value: 0)], at: t)

        d.controls.holdPedal = .off
        d.handle([.control(controller: 66, value: 1), .control(controller: 67, value: 1)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertFalse(d.holding, "no pedal holds the moment")
        d.controls.holdPedal = .soft
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding, "the soft pedal still down once it holds again")
    }

    /// A panic (all notes off) lets the hold pedal go, but not a hold asked for.
    func testPanicLetsTheHoldPedalGo() {
        let d = director(MoonlitLakeModel.id)
        var t = 0.0
        run(d, &t, seconds: 0.1)
        d.handle([.control(controller: 67, value: 1)], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding)
        d.handle([.allNotesOff], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertFalse(d.holding, "the pedal's hold ends")
        d.controls.holdRequested = true
        run(d, &t, seconds: Self.frameDt)
        d.handle([.allNotesOff], at: t)
        run(d, &t, seconds: Self.frameDt)
        XCTAssertTrue(d.holding, "a latched hold stays")
    }

    /// No flashes while time is held: the stormy lake's lightning and the bay's lighthouse hold where they were for 30 s.
    func testFlashesPauseWhileHeld() throws {
        var stormy = SkySettings()
        stormy.weatherMode = .pick
        stormy.weather = .storm
        let lake = director(MoonlitLakeModel.id, sky: stormy)
        var t = 0.0
        var lit: Float = 0
        var tries = 0
        while lit < 0.3, tries < 40 * 60 {
            run(lake, &t, seconds: Self.frameDt)
            lit = try XCTUnwrap(lake.lastSky).lightning
            tries += 1
        }
        XCTAssertGreaterThan(lit, 0.3, "a flash within 40 s")
        lake.controls.holdRequested = true
        run(lake, &t, seconds: Self.frameDt)
        let held = try XCTUnwrap(lake.lastSky).lightning
        XCTAssertGreaterThan(held, 0.1)
        for _ in 0..<300 {
            run(lake, &t, seconds: 0.1, dt: 0.1)
            let now = try XCTUnwrap(lake.lastSky).lightning
            XCTAssertEqual(now, held)
        }

        var night = SkySettings()
        night.timeMode = .frozen
        night.frozenHour = 22
        let bay = director(BioluminescentBayModel.id, sky: night)
        var u = 0.0
        var flash: Float = 0
        tries = 0
        while flash < 0.5, tries < 10 * 60 {
            flash = try XCTUnwrap(run(bay, &u, seconds: Self.frameDt) as? BayFrame).lighthouseFlash
            tries += 1
        }
        XCTAssertGreaterThan(flash, 0.5, "the lighthouse flashes within 10 s")
        bay.controls.holdRequested = true
        let first = try XCTUnwrap(run(bay, &u, seconds: Self.frameDt) as? BayFrame).lighthouseFlash
        for _ in 0..<300 {
            let now = try XCTUnwrap(run(bay, &u, seconds: 0.1, dt: 0.1) as? BayFrame).lighthouseFlash
            XCTAssertEqual(now, first)
        }
        XCTAssertGreaterThan(first, 0.4)
    }

    /// The sleep dim slides the sun toward −14°, never up: Golden hour's 5° at dim 0, ½ and 1; Deep night stays at −30°;
    /// the noon lake at dim 1 is at −14°.
    func testSleepDimSlidesTheHeldSun() throws {
        let dims = [0.0, 0.5, 1.0]
        let golden = [5.0, -4.5, -14.0]
        for (dim, expected) in zip(dims, golden) {
            let beach = director(GoldenHourBeachModel.id)
            beach.controls.sleepDim = dim
            _ = beach.step(dt: Self.frameDt, t: Self.frameDt, quality: .lite)
            let sun = try XCTUnwrap(beach.lastSky).sun.altitude
            XCTAssertEqual(sun, expected, accuracy: 1e-9, "dim \(dim)")
        }
        let bay = director(BioluminescentBayModel.id)
        bay.controls.sleepDim = 1
        _ = bay.step(dt: Self.frameDt, t: Self.frameDt, quality: .lite)
        let deep = try XCTUnwrap(bay.lastSky).sun.altitude
        XCTAssertEqual(deep, -30, accuracy: 1e-9)

        var noon = SkySettings()
        noon.timeMode = .frozen
        noon.frozenHour = 12
        let lake = director(MoonlitLakeModel.id, sky: noon)
        _ = lake.step(dt: Self.frameDt, t: Self.frameDt, quality: .lite)
        let high = try XCTUnwrap(lake.lastSky).sun.altitude
        XCTAssertGreaterThan(high, 20, "noon")
        lake.controls.sleepDim = 1
        _ = lake.step(dt: Self.frameDt, t: 2 * Self.frameDt, quality: .lite)
        let dimmed = try XCTUnwrap(lake.lastSky).sun.altitude
        XCTAssertEqual(dimmed, -14, accuracy: 1e-9)
    }

    /// At dim 1 the world runs at half speed, but the weather keeps its pace: a blend ends on the same step either way.
    func testSleepSlowsTheWorldNotTheWeather() throws {
        var clear = SkySettings()
        clear.weatherMode = .pick
        clear.weather = .clear
        clear.pickBlendSeconds = 2
        var steps: [Int] = []
        for dim in [0.0, 1.0] {
            let d = director(MoonlitLakeModel.id, sky: clear)
            d.controls.sleepDim = dim
            var t = 0.0
            let a = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? LakeFrame)
            let b = try XCTUnwrap(run(d, &t, seconds: Self.frameDt) as? LakeFrame)
            let gained = b.time - a.time
            XCTAssertEqual(gained, (1 - 0.5 * dim) * Self.frameDt, accuracy: 1e-12, "dim \(dim)")
            var rain = clear
            rain.weather = .rain
            d.sky.settings = rain
            var n = 0
            var done = false
            while !done, n < 600 {
                run(d, &t, seconds: Self.frameDt)
                n += 1
                let s = try XCTUnwrap(d.lastSky)
                done = s.weather == .rain && s.weatherBlend == 0
            }
            XCTAssertTrue(done, "dim \(dim): the rain blends in")
            steps.append(n)
        }
        XCTAssertEqual(steps[0], steps[1], "the weather keeps its pace")
    }

    /// The exposure falls a stop at dim 1: exp2(−dim).
    func testExposureFallsAStop() {
        let dims = [0.0, 0.5, 1.0]
        let scales: [Float] = [1, 0.7071, 0.5]
        for (dim, expected) in zip(dims, scales) {
            let d = director(MoonlitLakeModel.id)
            d.controls.sleepDim = dim
            _ = d.step(dt: Self.frameDt, t: Self.frameDt, quality: .lite)
            XCTAssertEqual(d.exposureScale, expected, accuracy: 1e-4, "dim \(dim)")
        }
    }

    /// The renderers' dt at 1/60: plain 1/60; Reduce Motion 1/120; dim 1 1/120; both 1/240; held 0.
    func testVisualDtCombinesEverything() {
        let cases: [(reduce: Bool, dim: Double, hold: Bool, expected: Double)] = [
            (false, 0, false, 1.0 / 60), (true, 0, false, 1.0 / 120), (false, 1, false, 1.0 / 120),
            (true, 1, false, 1.0 / 240), (false, 0, true, 0), (true, 1, true, 0),
        ]
        for c in cases {
            let d = director(SpaceshipLoungeModel.id)
            d.controls.reduceMotion = c.reduce
            d.controls.sleepDim = c.dim
            d.controls.holdRequested = c.hold
            _ = d.step(dt: Self.frameDt, t: Self.frameDt, quality: .lite)
            XCTAssertEqual(d.visualDt, c.expected, accuracy: 1e-12, "\(c)")
        }
    }

    /// The lounge under fortissimo chords every 0.25 s for 3 s: with Reduce Motion Galaxy Warp stays a drift, without it
    /// it warps. The input never reaches the hub, so the mapping editor never lists it.
    func testReduceMotionKeepsGalaxyWarpAdrift() throws {
        var speeds: [Float] = []
        for reduce in [true, false] {
            let d = director(SpaceshipLoungeModel.id)
            d.controls.reduceMotion = reduce
            var t = 0.0
            var fastest: Float = 0
            var last: Float = 0
            for i in 0..<12 {
                let base = UInt8(48 + (i % 4) * 5)
                let chord: [UInt8] = [base, base + 4, base + 7, base + 12]
                var strike: [PerformanceEvent] = chord.map { PerformanceEvent.noteOn(note: $0, velocity: 1) }
                strike.append(.chord(notes: chord))
                d.handle(strike, at: t)
                for _ in 0..<15 {
                    t += Self.frameDt
                    let frame = try XCTUnwrap(d.step(dt: Self.frameDt, t: t, quality: .lite) as? LoungeFrame)
                    fastest = max(fastest, frame.warp.warpSpeed)
                    last = frame.warp.warpSpeed
                }
                let release: [PerformanceEvent] = chord.map { PerformanceEvent.noteOff(note: $0) }
                d.handle(release, at: t)
            }
            if reduce {
                XCTAssertLessThanOrEqual(fastest, GalaxyWarp.driftSpeed + 1e-6, "a drift under Reduce Motion")
            } else {
                XCTAssertGreaterThan(last, 0.5, "a warp without it")
            }
            speeds.append(fastest)
            let listed = d.hub.knownInputs.contains(.reduceMotion)
            XCTAssertFalse(listed, "the hub never hears it")
        }
        XCTAssertEqual(speeds.count, 2)
    }

    // MARK: - Comparing frames

    /// Where two values first differ, walking their fields through `Mirror`, or nil when they match. Numbers compare by
    /// value (±0 alike, NaN matching NaN), SIMD vectors and leaves by their description. Fields named in `skipping` are
    /// left out at any depth.
    static func firstDifference(_ a: Any, _ b: Any, path: String = "frame", skipping: Set<String> = []) -> String? {
        if let x = a as? Double, let y = b as? Double {
            let same = x == y || (x.isNaN && y.isNaN)
            return same ? nil : "\(path): \(x) vs \(y)"
        }
        if let x = a as? Float, let y = b as? Float {
            let same = x == y || (x.isNaN && y.isNaN)
            return same ? nil : "\(path): \(x) vs \(y)"
        }
        let typeName = String(describing: type(of: a))
        let ma = Mirror(reflecting: a)
        let mb = Mirror(reflecting: b)
        if typeName.hasPrefix("SIMD") || ma.children.isEmpty || mb.children.isEmpty {
            let x = String(describing: a)
            let y = String(describing: b)
            return x == y ? nil : "\(path): \(x) vs \(y)"
        }
        let ca = Array(ma.children)
        let cb = Array(mb.children)
        if ca.count != cb.count { return "\(path): \(ca.count) vs \(cb.count) items" }
        for i in 0..<ca.count {
            let label = ca[i].label ?? "[\(i)]"
            if skipping.contains(label) { continue }
            if let d = firstDifference(ca[i].value, cb[i].value, path: path + "." + label, skipping: skipping) { return d }
        }
        return nil
    }
}
