import XCTest
import simd
@testable import InStrumCore

/// Lightning Plains and Strike Lines (Storms spec §5, §9; plan Task 11). Each assertion is a plain statement over named
/// locals, so the type-checker finishes quickly in CI.
final class StrikeLinesTests: XCTestCase {
    // MARK: - Helpers

    /// A dry plain at dusk (the sun 4° down in the west), or by night, with a light breeze.
    static func dusk(sun altitude: Double = -4, wind: Float = 0.25, gust: Float = 0.2) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 262, altitude: altitude)
        s.moon = SkyDirection(azimuth: 90, altitude: -20)
        s.hourOfDay = altitude > -10 ? 19.8 : 22.5
        s.latitude = -37.8
        s.hemisphere = -1
        s.wind = wind
        s.gust = gust
        return s
    }

    static func params(_ state: ThemeState = ThemeState()) -> ParameterSet {
        ThemeRegistry.parameterSet(for: LightningPlainsModel.id, state: state)
    }

    /// Steps the plains for `seconds` at `dt`, handing it `excitement` (calm by default) before every step, and calls
    /// `each` with every frame. Returns the last frame.
    @discardableResult
    static func run(_ m: inout LightningPlainsModel, seconds: Double, dt: Double = 1.0 / 60,
                    excitement: ExcitementFrame = .calm, state: ThemeState = ThemeState(),
                    quality: QualityLevel = .high, each: ((PlainsFrame) -> Void)? = nil) -> PlainsFrame {
        let p = params(state)
        let steps = max(1, Int((seconds / dt).rounded()))
        var last: PlainsFrame?
        for _ in 0..<steps {
            m.setExcitement(excitement)
            let f = m.step(dt: dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: quality)
            each?(f)
            last = f
        }
        return last!
    }

    /// A model under a sky, settled for half a second.
    static func plains(_ sky: SkyState = dusk()) -> LightningPlainsModel {
        var m = LightningPlainsModel()
        m.mood = .plainsVast
        m.setSky(sky)
        run(&m, seconds: 0.5)
        return m
    }

    static func moment(drop: Bool, kind: BigMoment.Kind = .chord) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = 0.8
        e.visualEnergy = 0.8
        e.drop = drop ? 1 : 0
        e.moment = BigMoment(kind: kind, strength: 0.9, low: drop, isDrop: drop)
        return e
    }

    static func chord(_ m: inout LightningPlainsModel, _ notes: [UInt8], velocity: Float = 0.7) {
        for n in notes { m.handle(.noteOn(note: n, velocity: velocity)) }
    }

    // MARK: - The repeated note (spec §9.2)

    /// Each strike of the repeated key lands a fork on the horizon at the storm's distance and walks the storm 2% closer:
    /// 50 strikes bring it to 0.98⁵⁰ = 0.364 of where it was. The first three notes are not a repeat yet (the grand's rule:
    /// four strikes at 2 a second or faster), so 53 notes make 50 strikes.
    func testRepeatedNoteWalksTheStormCloser() {
        var m = Self.plains()
        let first = Self.run(&m, seconds: 0.1)
        let start = first.distanceKm
        XCTAssertEqual(start, StrikeLines.farKm, accuracy: 1e-9, "the storm begins 40 km out")
        XCTAssertEqual(first.distance, 0, accuracy: 1e-6)
        var ids = Set<Int>()
        var tooNear = 0, tooFar = 0
        var last = first
        for i in 0..<53 {
            m.instrumentRepeat = i >= 3   // the engine reports the repeat from the fourth strike
            m.handle(.noteOn(note: 57, velocity: 0.7))
            let storm = last.distanceKm
            last = Self.run(&m, seconds: 0.1) { f in
                for fork in f.strikes where fork.kind == .repeated && !ids.contains(fork.id) {
                    ids.insert(fork.id)
                    if fork.km < 0.5 * storm { tooNear += 1 }
                    if fork.km > 1.5 * storm { tooFar += 1 }
                }
            }
            m.handle(.noteOff(note: 57))
            last = Self.run(&m, seconds: 0.3) { f in
                for fork in f.strikes where fork.kind == .repeated { ids.insert(fork.id) }
            }
        }
        let strikes = ids.count
        XCTAssertEqual(strikes, 50, "a strike for every repeat from the fourth note")
        let ratio = last.distanceKm / start
        let law = pow(StrikeLines.strikeStep, 50.0)
        XCTAssertEqual(law, 0.364, accuracy: 0.001)
        XCTAssertEqual(ratio, law, accuracy: 1e-6, "2% closer a strike")
        XCTAssertEqual(tooNear, 0, "each lands at the storm's distance")
        XCTAssertEqual(tooFar, 0, "each lands at the storm's distance")
        XCTAssertGreaterThan(last.distance, first.distance)
        XCTAssertEqual(last.distance, Float(1 - last.distanceKm / 40), accuracy: 1e-6)
    }

    /// A chord forks one strike; a big moment forks three (and not four, when the moment is itself the chord); a crescendo
    /// forks three too. Single notes fork none: they flicker in the towers instead.
    func testChordForksOneStrikeMomentForksThree() {
        var m = Self.plains()
        var chordIDs = Set<Int>(), momentIDs = Set<Int>(), otherIDs = Set<Int>()
        func collect(_ f: PlainsFrame) {
            for fork in f.strikes {
                switch fork.kind {
                case .chord: chordIDs.insert(fork.id)
                case .moment: momentIDs.insert(fork.id)
                default: otherIDs.insert(fork.id)
                }
            }
        }
        // A single note: no fork, a flicker in the tower over its pitch.
        m.handle(.noteOn(note: 72, velocity: 0.8))
        let single = Self.run(&m, seconds: 0.05)
        let flickers = single.towerFlash.count
        XCTAssertEqual(single.strikes.count, 0)
        XCTAssertGreaterThanOrEqual(flickers, 1, "every note lands in the storm")
        m.handle(.noteOff(note: 72))
        Self.run(&m, seconds: 1)
        // A chord with Excitement calm: one fork.
        Self.chord(&m, [48, 52, 55])
        Self.run(&m, seconds: 0.5, each: collect)
        XCTAssertEqual(chordIDs.count, 1, "a chord forks one strike")
        XCTAssertEqual(momentIDs.count, 0)
        for n: UInt8 in [48, 52, 55] { m.handle(.noteOff(note: n)) }
        Self.run(&m, seconds: 1)
        // A hard chord that is a big moment: three forks, no chord fork beside them.
        Self.chord(&m, [60, 64, 67], velocity: 1)
        m.setExcitement(Self.moment(drop: false))
        let p = Self.params()
        let landing = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        collect(landing)
        Self.run(&m, seconds: 0.5, each: collect)
        XCTAssertEqual(momentIDs.count, 3, "a big moment forks three")
        XCTAssertEqual(chordIDs.count, 1, "and the chord it was adds none")
        XCTAssertEqual(otherIDs.count, 0)
        for n: UInt8 in [60, 64, 67] { m.handle(.noteOff(note: n)) }
        Self.run(&m, seconds: 1)
        // A crescendo (no chord): three more.
        m.setExcitement(Self.moment(drop: false, kind: .crescendo))
        collect(m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high))
        Self.run(&m, seconds: 0.5, each: collect)
        XCTAssertEqual(momentIDs.count, 6)
        XCTAssertEqual(chordIDs.count, 1)
        // Every fork has its branches: 4–7 polylines, the first reaching the ground, the rest ending in the air.
        var m2 = Self.plains()
        Self.chord(&m2, [50, 53, 57])
        let forked = Self.run(&m2, seconds: 0.02)
        let fork = forked.strikes.first
        XCTAssertNotNil(fork)
        if let fork {
            let count = fork.branches.count
            XCTAssertGreaterThanOrEqual(count, 4)
            XCTAssertLessThanOrEqual(count, 7)
            let mainEnd = fork.branches[0].last?.y ?? -1
            let mainTop = fork.branches[0].first?.y ?? -1
            XCTAssertEqual(mainEnd, 0, "the main channel reaches the ground")
            XCTAssertEqual(mainTop, 1, "from the cloud base")
            for b in fork.branches.dropFirst() {
                let end = b.last?.y ?? 0
                let points = b.count
                XCTAssertGreaterThan(end, 0.05, "a branch ends in the air")
                XCTAssertGreaterThanOrEqual(points, 2)
            }
            let peak = fork.brightness
            XCTAssertEqual(peak, 1, accuracy: 1e-6, "the flash lands in the frame the moment fires")
        }
    }

    /// Resting lets the storm retreat: after 3 s without a note it walks back out, reaching 40 km 60 s later, never
    /// coming closer on the way.
    func testStormRetreatsWhenResting() {
        var m = Self.plains()
        var building = ExcitementFrame()
        building.energy = 1
        building.visualEnergy = 1
        building.tension = 1
        for i in 0..<30 {
            let note = UInt8(48 + (i * 5) % 24)
            m.handle(.noteOn(note: note, velocity: 0.8))
            Self.run(&m, seconds: 0.25, excitement: building)
            m.handle(.noteOff(note: note))
            Self.run(&m, seconds: 0.25, excitement: building)
        }
        let walked = Self.run(&m, seconds: 0.02)
        let near = walked.distanceKm
        XCTAssertLessThan(near, 20, "energy and tension walk the storm in")
        // The last note went down half a second before `walked`: 2.4 s more is still short of the 3 s that makes a rest.
        let waiting = Self.run(&m, seconds: 2.4)
        XCTAssertEqual(waiting.distanceKm, near, accuracy: 1e-9, "not resting yet")
        var previous = waiting.distanceKm
        var backwards = 0
        let half = Self.run(&m, seconds: 30) { f in
            if f.distanceKm < previous - 1e-9 { backwards += 1 }
            previous = f.distanceKm
        }
        XCTAssertGreaterThan(half.distanceKm, near * 1.5)
        XCTAssertLessThan(half.distanceKm, StrikeLines.farKm - 1)
        let back = Self.run(&m, seconds: 31) { f in
            if f.distanceKm < previous - 1e-9 { backwards += 1 }
            previous = f.distanceKm
        }
        XCTAssertEqual(backwards, 0, "it only ever retreats")
        XCTAssertEqual(back.distanceKm, StrikeLines.farKm, accuracy: 1e-6, "40 km out after 60 s of rest")
        XCTAssertEqual(back.distance, 0, accuracy: 1e-6)
    }

    /// Tension raises the wind in the grass (the wind field's steady flow) and spins the windmill up, by the engine's own
    /// law: the windmill's level in the soundscape is its drive, and the wheel turns 3.29 times a stroke.
    func testTensionSpinsTheWindmill() {
        var calm = Self.plains()
        var tense = Self.plains()
        var e = ExcitementFrame()
        e.tension = 0.9
        e.energy = 0.5
        e.visualEnergy = 0.5
        let a = Self.run(&calm, seconds: 12)
        let b = Self.run(&tense, seconds: 12, excitement: e)
        XCTAssertGreaterThan(b.windmillRPM, a.windmillRPM + 20, "tension spins the windmill")
        let driveA = a.ambience.level(.windmill)
        let driveB = b.ambience.level(.windmill)
        XCTAssertGreaterThan(driveB, driveA + 0.3)
        let skyDrive = WeatherAmbience.windmillDrive(Self.dusk())
        XCTAssertEqual(driveA, skyDrive, accuracy: 1e-6, "calm: the wind drives it")
        XCTAssertEqual(driveB, min(1, skyDrive + 0.55 * 0.9), accuracy: 1e-5)
        let lawB = Float(60 * WeatherAmbience.windmillGear * WeatherAmbience.windmillRate(driveB))
        XCTAssertEqual(b.windmillRPM, lawB, accuracy: lawB * 0.02, "the wheel at the pump's rate")
        let steadyA = simd_length(a.wind.steady)
        let steadyB = simd_length(b.wind.steady)
        XCTAssertGreaterThan(steadyB, steadyA + 5, "tension raises the wind in the grass")
        XCTAssertGreaterThan(b.grassLean, a.grassLean)
        // Still air and no tension: the windmill stands still.
        var still = Self.plains(Self.dusk(wind: 0, gust: 0))
        let s = Self.run(&still, seconds: 8)
        XCTAssertEqual(s.windmillRPM, 0, accuracy: 1e-3)
        let angle0 = s.windmillAngle
        let s2 = Self.run(&still, seconds: 1)
        XCTAssertEqual(s2.windmillAngle, angle0, accuracy: 1e-4)
    }

    // MARK: - The drop: the storm's arrival (spec §5, §9.2)

    /// The drop forces the grand's voice to Morph .8 for the drop's 2.5 s, then lets it go (nil).
    func testDropForcesMorph() {
        var m = Self.plains()
        XCTAssertNil(m.forcedMorph)
        let p = Self.params()
        m.setExcitement(Self.moment(drop: true))
        _ = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let atDrop = m.forcedMorph
        XCTAssertEqual(atDrop ?? -1, 0.8, accuracy: 1e-6)
        Self.run(&m, seconds: 2.4)
        let during = m.forcedMorph
        XCTAssertEqual(during ?? -1, 0.8, accuracy: 1e-6, "for the whole drop")
        Self.run(&m, seconds: 0.2)
        XCTAssertNil(m.forcedMorph, "then the player's pressure again")
        // A moment that is not a drop forces nothing.
        var n = Self.plains()
        n.setExcitement(Self.moment(drop: false))
        _ = n.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertNil(n.forcedMorph)
    }

    /// The drop is the storm's arrival: it walks in to about a kilometre, the rain curtain crosses the view over 2.5 s
    /// and the rain falls on you, the sky is sheet-lit for 2.5 s, and a close strike lands.
    func testDropBringsTheRainCurtain() {
        var m = Self.plains(Self.dusk(sun: -20))   // by night: no cicadas to hush, so the close strike lands at once
        let before = Self.run(&m, seconds: 0.1)
        XCTAssertEqual(before.rainCurtain, 0)
        XCTAssertNil(before.curtainKm)
        XCTAssertEqual(before.sky.rain, 0)
        let p = Self.params()
        m.setExcitement(Self.moment(drop: true))
        let first = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let lit = first.sheetLit
        XCTAssertGreaterThan(lit, 0.5, "the sky goes sheet-lit")
        var progress: Float = first.rainCurtain
        var curtainBack = 0, curtainForward = 0
        var curtainKm = first.curtainKm ?? 99
        var arrivals = Set<Int>()
        let crossed = Self.run(&m, seconds: 2.45) { f in
            if f.rainCurtain < progress { curtainBack += 1 }
            progress = f.rainCurtain
            if let k = f.curtainKm {
                if k > curtainKm + 1e-9 { curtainForward += 1 }
                curtainKm = k
            }
            for fork in f.strikes where fork.kind == .arrival { arrivals.insert(fork.id) }
        }
        XCTAssertEqual(curtainBack, 0, "the curtain only comes on")
        XCTAssertEqual(curtainForward, 0)
        XCTAssertGreaterThan(crossed.rainCurtain, 0.95)
        XCTAssertLessThanOrEqual(crossed.distanceKm, StrikeLines.arrivalKm + 1e-6, "the storm has arrived")
        XCTAssertEqual(arrivals.count, 1, "one close strike")
        let after = Self.run(&m, seconds: 1)
        XCTAssertEqual(after.rainCurtain, 1)
        XCTAssertGreaterThan(after.sky.rain, 0.6, "it rains on you")
        XCTAssertEqual(after.sheetLit, 0, accuracy: 1e-6, "the sheet-lit sky lasts the drop's 2.5 s")
        XCTAssertFalse(after.dry)
        // The rain eases off and the curtain goes; at rest the storm walks back out.
        let later = Self.run(&m, seconds: 62)
        XCTAssertLessThan(later.sky.rain, 0.05)
        XCTAssertEqual(later.rainCurtain, 0)
        XCTAssertGreaterThan(later.distanceKm, 20)
    }

    /// A close strike (under 2 km) shakes the camera once: at most 6 px, over 0.4 s. A far one only glows.
    func testCloseStrikeShakes() {
        var far = Self.plains(Self.dusk(sun: -20))
        far.lines.km = 10
        Self.chord(&far, [55, 59, 62])
        var farShake: Float = 0
        Self.run(&far, seconds: 0.6) { f in farShake = max(farShake, simd_length(f.cameraShake)) }
        XCTAssertEqual(farShake, 0, "a far strike only glows")

        var near = Self.plains(Self.dusk(sun: -20))
        near.lines.km = 1.5
        Self.chord(&near, [55, 59, 62])
        var most: Float = 0
        var forkKm = 99.0
        Self.run(&near, seconds: 0.1) { f in
            most = max(most, simd_length(f.cameraShake))
            if let k = f.strikes.first?.km { forkKm = min(forkKm, k) }
        }
        XCTAssertLessThan(forkKm, CicadaHush.closeKm)
        XCTAssertGreaterThan(most, 1, "a close strike shakes the camera")
        Self.run(&near, seconds: 0.25) { f in most = max(most, simd_length(f.cameraShake)) }
        XCTAssertLessThanOrEqual(most, StrikeLines.shakePixels + 1e-4)
        let settled = Self.run(&near, seconds: 0.1)
        let rest = simd_length(settled.cameraShake)
        XCTAssertEqual(rest, 0, "once, for 0.4 s")
    }

    // MARK: - Surprises (spec §5)

    /// Ball lightning rolls along the far ridge for 10 s (one way, the whole time), then is gone. The other three: a dust
    /// devil crosses through the wind field; the windmill spins up and stops; the petrichor rises 20 s before the rain.
    func testBallLightningSurpriseRollsTheRidge() {
        XCTAssertEqual(LightningPlainsModel.surpriseCount, 4)
        var m = Self.plains()
        var e = ExcitementFrame()
        e.surprise = WorldSurprise(index: 0, seed: 7)
        let p = Self.params()
        m.setExcitement(e)
        let start = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertNotNil(start.ballLightning)
        let from = start.ballLightning?.position ?? -1
        var positions: [Float] = []
        var brightest: Float = 0
        for _ in 0..<19 {
            let f = Self.run(&m, seconds: 0.5)
            if let b = f.ballLightning {
                positions.append(b.position)
                brightest = max(brightest, b.brightness)
            }
        }
        XCTAssertEqual(positions.count, 19, "it rolls for 10 s")
        let end = positions.last ?? from
        let travel = end - from
        XCTAssertGreaterThan(abs(travel), 0.4, "along the ridge")
        var turns = 0
        var previous = from
        for x in positions {
            if (x - previous) * travel <= 0 { turns += 1 }
            previous = x
        }
        XCTAssertEqual(turns, 0, "one way, the whole time")
        XCTAssertGreaterThan(brightest, 0.3)
        let gone = Self.run(&m, seconds: 0.6)
        XCTAssertNil(gone.ballLightning)

        // A dust devil: a vortex in the wind field, crossing the view.
        var d = Self.plains()
        e.surprise = WorldSurprise(index: 1, seed: 3)
        d.setExcitement(e)
        let devil = d.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertEqual(devil.wind.vortexCount, 1)
        let x0 = devil.dustDevil?.centre.x ?? 0
        let later = Self.run(&d, seconds: 8)
        let x1 = later.dustDevil?.centre.x ?? x0
        XCTAssertGreaterThan(abs(x1 - x0), 20, "it crosses the view")

        // The windmill spins up, then stops.
        var w = Self.plains()
        e.surprise = WorldSurprise(index: 2, seed: 5)
        w.setExcitement(e)
        _ = w.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let spun = Self.run(&w, seconds: 7.5)
        XCTAssertGreaterThan(spun.windmillRPM, 100)
        let stopped = Self.run(&w, seconds: 10)
        XCTAssertLessThan(stopped.windmillRPM, 5)

        // The storm's smell: rain on dust rises for 20 s with no rain, then the rain comes.
        var r = Self.plains()
        e.surprise = WorldSurprise(index: 3, seed: 9)
        r.setExcitement(e)
        _ = r.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let smell = Self.run(&r, seconds: 15)
        XCTAssertGreaterThan(smell.ambience.level(.rainOnDust), 0.3)
        XCTAssertEqual(smell.sky.rain, 0, "no rain yet")
        let shower = Self.run(&r, seconds: 15)
        XCTAssertGreaterThan(shower.sky.rain, 0.2, "then it rains")
    }

    /// Under virga the strikes are dry: no rain comes with them, the drop's curtain never reaches the ground, and the
    /// petrichor rises.
    func testVirgaStrikesAreDry() {
        var virga = Self.dusk(sun: -20)
        virga.weather = .virga
        virga.nextWeather = .virga
        virga.virga = 1
        virga.cloudCover = 0.7
        var m = Self.plains(virga)
        Self.chord(&m, [52, 55, 59])
        let chord = Self.run(&m, seconds: 0.05)
        let dry = chord.strikes.first?.dry
        XCTAssertEqual(dry, true)
        XCTAssertTrue(chord.dry)
        let p = Self.params()
        m.setExcitement(Self.moment(drop: true))
        _ = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        var wettest: Float = 0
        var curtain: Float = 0
        let after = Self.run(&m, seconds: 4) { f in
            wettest = max(wettest, f.sky.rain)
            curtain = max(curtain, f.rainCurtain)
        }
        XCTAssertEqual(wettest, 0, "no rain reaches you")
        XCTAssertGreaterThan(curtain, 0.9, "the curtain still crosses, as virga")
        XCTAssertGreaterThanOrEqual(after.ambience.level(.rainOnDust), 0.5, "the petrichor rises")
        // Without virga the same chord brings rain with it.
        var wet = Self.plains(Self.dusk(sun: -20))
        Self.chord(&wet, [52, 55, 59])
        let rainy = Self.run(&wet, seconds: 0.05)
        let wetFork = rainy.strikes.first?.dry
        XCTAssertEqual(wetFork, false)
    }

    // MARK: - Budgets

    /// A burst of 34 notes a frame (repeats, chords and moments every step) never makes more than three forks a step,
    /// eight at once, six tower flashes, the crawler slots for the quality (2 on Smooth) or more thunder than forks.
    func testBurstIsRationed() {
        for q in [QualityLevel.lite, .high] {
            var m = Self.plains(Self.dusk(sun: -20))
            m.instrumentRepeat = true
            let p = Self.params()
            var spawned = m.lines.spawned
            let start = Date()
            for i in 0..<120 {
                for k in 0..<34 { m.handle(.noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.9)) }
                m.handle(.noteOn(note: 60, velocity: 0.9))
                m.setExcitement(Self.moment(drop: i % 40 == 0))
                let f = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: q)
                let made = m.lines.spawned - spawned
                spawned = m.lines.spawned
                let forks = f.strikes.count
                let flashes = f.towerFlash.count
                let crawlers = f.crawlers.count
                let thunder = f.ambience.thunderQueue.count
                let posts = f.postLit.count
                XCTAssertLessThanOrEqual(made, StrikeLines.maxForksPerStep)
                XCTAssertLessThanOrEqual(forks, StrikeLines.cap)
                XCTAssertLessThanOrEqual(flashes, StrikeLines.flashCap)
                XCTAssertLessThanOrEqual(crawlers, StrikeLines.crawlerSlots(q))
                XCTAssertLessThanOrEqual(thunder, StrikeLines.maxForksPerStep)
                XCTAssertLessThanOrEqual(posts, 88)
                if i % 3 == 2 { for k in 0..<34 { m.handle(.noteOff(note: UInt8(21 + ((i - 2) * 34 + k) % 88))) } }
            }
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2, "\(q): 120 steps of a burst")
            XCTAssertEqual(StrikeLines.crawlerSlots(.lite), 2, "Smooth: two crawler slots")
        }
    }

    func testIdsWrap() {
        var m = Self.plains(Self.dusk(sun: -20))
        m.lines.nextID = Int.max - 2
        var ids: [Int] = []
        for k in 0..<5 {
            let base = UInt8(40 + 7 * k)
            Self.chord(&m, [base, base + 4, base + 7])
            m.setExcitement(Self.moment(drop: false))
            let p = Self.params()
            let f = m.step(dt: 1.0 / 60, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            for fork in f.strikes where !ids.contains(fork.id) { ids.append(fork.id) }
            Self.run(&m, seconds: 0.4) { f in
                for fork in f.strikes where !ids.contains(fork.id) { ids.append(fork.id) }
            }
            for n in [base, base + 4, base + 7] { m.handle(.noteOff(note: n)) }
        }
        let unique = Set(ids).count
        XCTAssertGreaterThanOrEqual(ids.count, 12)
        XCTAssertEqual(unique, ids.count)
    }

    // MARK: - Defaults and ambience

    func testPlainsDefaults() throws {
        XCTAssertEqual(LightningPlainsModel.id, "lightning-plains")
        XCTAssertEqual(LightningPlainsModel.displayName, "Lightning Plains")
        XCTAssertEqual(ThemeRegistry.resolve(LightningPlainsModel.id), LightningPlainsModel.id)
        XCTAssertTrue(ThemeRegistry.isWorld(LightningPlainsModel.id))
        let ids = ThemeRegistry.all.map(\.id)
        let plainsAt = try XCTUnwrap(ids.firstIndex(of: LightningPlainsModel.id))
        let reefAt = try XCTUnwrap(ids.firstIndex(of: GreatBarrierReefModel.id))
        XCTAssertGreaterThan(plainsAt, reefAt, "after the reef")
        assertValidParameters(LightningPlainsModel.parameters)
        XCTAssertEqual(LightningPlainsModel.visuals, ["Strike Lines", "Galaxy Warp"])
        let p = Self.params()
        XCTAssertEqual(p.choice("visual"), "Strike Lines")
        XCTAssertEqual(p.choice("light.hold"), SkyHold.blueHour.rawValue, "civil dusk by default")
        XCTAssertEqual(p.choice("meteors.mode"), MeteorMode.follow.rawValue)
        XCTAssertEqual(p.choice(SkyExtraMode.crawlersID), SkyExtraMode.natural.rawValue)
        XCTAssertEqual(p.choice(SkyExtraMode.sheetID), SkyExtraMode.often.rawValue, "sheet lightning often, here")
        XCTAssertEqual(p.number("storm.pull"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.number("grass"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(p.number("keys.show"), 1)
        let pull = try XCTUnwrap(LightningPlainsModel.parameters.first { $0.id == "storm.pull" })
        XCTAssertTrue(pull.hero)
        let sheet = try XCTUnwrap(LightningPlainsModel.parameters.first { $0.id == SkyExtraMode.sheetID })
        XCTAssertEqual(sheet.group, "Sky")
        let plainsVast = Mood(energy: 0.45, warmth: 0.3, brightness: 0.4, space: 1.0, motion: 0.4)
        XCTAssertEqual(Mood.plainsVast, plainsVast)
        XCTAssertTrue(WorldWeather.dryWorlds.contains(LightningPlainsModel.id), "virga in its Random Beautiful")
        XCTAssertTrue(WorldWeather.stormWorlds.contains(LightningPlainsModel.id))

        // A quiet dusk: the storm far out on the western horizon, nothing striking, the fence's 88 posts dark.
        let m0 = Self.plains()
        var m = m0
        let f = Self.run(&m, seconds: 1)
        XCTAssertEqual(f.distanceKm, 40, accuracy: 1e-9)
        XCTAssertEqual(f.strikes.count, 0)
        XCTAssertEqual(f.rainCurtain, 0)
        XCTAssertEqual(f.sheetLit, 0)
        XCTAssertEqual(f.keys.count, 88)
        XCTAssertEqual(f.postLit.count, 0)
        XCTAssertNil(f.warp)
        XCTAssertNil(f.ballLightning)
        XCTAssertNil(m.forcedMorph)
        XCTAssertEqual(f.mood, .plainsVast)
        var sunFromView = (f.sky.sun.azimuth - f.cameraAzimuth).truncatingRemainder(dividingBy: 360)
        if sunFromView < 0 { sunFromView += 360 }
        XCTAssertGreaterThan(sunFromView, 100, "the low sun behind you, over your right shoulder")
        XCTAssertLessThan(sunFromView, 150, "the low sun behind you, over your right shoulder")
        XCTAssertEqual(f.stormBearing, f.cameraAzimuth, accuracy: 1e-9, "the storm stands ahead")
        XCTAssertEqual(f.sky.farStorm, 1, "a storm on the horizon")
        XCTAssertEqual(StrikeLines.towers.count, 5)
        // A note lights its post; Galaxy Warp streaks instead of striking.
        m.handle(.noteOn(note: 60, velocity: 0.8))
        let lit = Self.run(&m, seconds: 0.05)
        let post = lit.postLit.first
        XCTAssertEqual(lit.postLit.count, 1)
        XCTAssertEqual(post?.index, 39)
        XCTAssertGreaterThan(post?.level ?? 0, 0.3)
        let warpState = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        Self.chord(&m, [64, 67, 71])
        let warped = Self.run(&m, seconds: 0.2, state: warpState)
        XCTAssertNotNil(warped.warp)
        XCTAssertEqual(warped.strikes.count, 0)
    }

    /// The plains' soundscape (spec §9.3): the dry cicadas at dusk stop dead before a close strike (held 2 s for the
    /// silence) and sing again after; the windmill follows the wind; the cattle grid and the far truck are there, rare and
    /// far; the thunder of every strike is queued late by its distance.
    func testPlainsAmbience() {
        var m = Self.plains()
        let dusk = Self.run(&m, seconds: 0.5)
        let singing = dusk.ambience.level(.dryCicadas)
        XCTAssertGreaterThan(singing, 0.3, "a dusk chorus")
        XCTAssertEqual(dusk.ambience.level(.windmill), WeatherAmbience.windmillDrive(Self.dusk()), accuracy: 1e-6)
        let truck = dusk.ambience.level(.farTruck)
        let grid = dusk.ambience.level(.cattleGrid)
        XCTAssertGreaterThan(truck, 0)
        XCTAssertLessThanOrEqual(truck, 0.3, "rare and far")
        XCTAssertGreaterThan(grid, 0)
        XCTAssertLessThanOrEqual(grid, 0.3)
        let roll = dusk.ambience.level(.thunderRoll)
        XCTAssertGreaterThan(roll, 0.5, "the thunder roll is up, so the queue plays")
        XCTAssertGreaterThan(dusk.ambience.level(.grassWind), 0)

        // A far strike lands at once, its thunder queued 3 s a kilometre late (capped at 12 s), the cicadas singing on.
        Self.chord(&m, [50, 54, 57])
        let far = Self.run(&m, seconds: 1.0 / 60)
        let farThunder = far.ambience.thunderQueue.first
        XCTAssertEqual(far.strikes.count, 1)
        XCTAssertNotNil(farThunder)
        XCTAssertEqual(farThunder?.delay ?? 0, 12, accuracy: 1e-9, "40 km: capped at 12 s")
        XCTAssertGreaterThan(far.ambience.level(.dryCicadas), 0.3)
        for n: UInt8 in [50, 54, 57] { m.handle(.noteOff(note: n)) }
        Self.run(&m, seconds: 1)

        // A close one: the cicadas stop dead at once, and the strike waits for 2 s of silence.
        m.lines.km = 1.5
        Self.chord(&m, [62, 65, 69])
        var landedAt: Double?
        var t = 0.0
        var quiet = true
        var thunderDelay = -1.0
        Self.run(&m, seconds: 2.5) { f in
            t += 1.0 / 60
            if f.ambience.level(.dryCicadas) > 0 { quiet = false }
            if landedAt == nil, f.strikes.contains(where: { $0.kind == .chord && $0.km < 2 }) {
                landedAt = t
                thunderDelay = f.ambience.thunderQueue.first?.delay ?? -1
            }
        }
        XCTAssertTrue(quiet, "the cicadas stop dead before a close strike")
        XCTAssertEqual(landedAt ?? 0, CicadaHush.lead, accuracy: 2.0 / 60, "it lands after 2 s of silence")
        XCTAssertGreaterThan(thunderDelay, 2.5)
        XCTAssertLessThan(thunderDelay, 6.5, "the thunder late by its distance (3 s a km)")
        let back = Self.run(&m, seconds: 9)
        XCTAssertGreaterThan(back.ambience.level(.dryCicadas), 0.3, "and they sing again")

        // By night the cicadas are gone and the crickets out; the heat shimmer only by day.
        var night = Self.plains(Self.dusk(sun: -25))
        let n = Self.run(&night, seconds: 0.5)
        XCTAssertEqual(n.ambience.level(.dryCicadas), 0)
        XCTAssertGreaterThan(n.ambience.level(.crickets), 0.2)
        XCTAssertEqual(n.ambience.level(.shimmerHum), 0)
        var day = Self.plains(Self.dusk(sun: 35))
        let d = Self.run(&day, seconds: 0.5)
        XCTAssertGreaterThan(d.ambience.level(.shimmerHum), 0.2)
    }
}
