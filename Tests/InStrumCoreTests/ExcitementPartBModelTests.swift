import XCTest
import simd
@testable import InStrumCore

/// Excitement in the interiors, space and Deep Water (Fire & Neon spec §5.5; plan Task 7), in the models: what
/// `ExcitementPlay` keeps, and each world's moment, surprises and build and drop as its frame carries them.
final class ExcitementPartBModelTests: XCTestCase {
    static func frame(energy: Float = 0.4, tension: Float = 0, drop: Float = 0, moment: BigMoment? = nil,
                      surprise: WorldSurprise? = nil, reduceMotion: Bool = false) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = energy
        e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
        e.tension = tension
        e.drop = drop
        e.moment = moment
        e.surprise = surprise
        e.reduceMotion = reduceMotion
        return e
    }

    static func chord(_ strength: Float = 1, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: false, isDrop: drop)
    }

    static let dt = 1.0 / 60

    // MARK: - ExcitementPlay

    func testAMomentBeginsOnceAndNeverStacks() {
        var play = ExcitementPlay()
        play.step(dt: Self.dt, frame: Self.frame(moment: Self.chord(0.5)), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: [])
        let began = play.momentBegan
        XCTAssertNotNil(began)
        play.step(dt: Self.dt, frame: Self.frame(moment: Self.chord(0.9)), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: [])
        XCTAssertNil(play.momentBegan, "a moment while one plays doesn't begin another")
        let strength = play.moment?.strength ?? 0
        XCTAssertEqual(strength, 0.9, accuracy: 1e-6, "it lifts the one playing")
        for _ in 0..<200 { play.step(dt: Self.dt, frame: Self.frame(), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: []) }
        XCTAssertNil(play.moment, "and it ends")
    }

    func testADropTurnsTheMomentIntoTheRelease() {
        var play = ExcitementPlay()
        play.step(dt: Self.dt, frame: Self.frame(moment: Self.chord(0.6)), momentSeconds: 2, dropSeconds: 4, surpriseSeconds: [])
        for _ in 0..<30 { play.step(dt: Self.dt, frame: Self.frame(), momentSeconds: 2, dropSeconds: 4, surpriseSeconds: []) }
        play.step(dt: Self.dt, frame: Self.frame(drop: 1, moment: Self.chord(1, drop: true)), momentSeconds: 2, dropSeconds: 4,
                  surpriseSeconds: [])
        let m = play.moment
        XCTAssertEqual(m?.isDrop, true)
        let life = m?.duration ?? 0
        XCTAssertGreaterThanOrEqual(life, 2.5, "the release plays on")
    }

    func testTheReleaseIsQuickButNeverInOneFrame() {
        var play = ExcitementPlay()
        for _ in 0..<60 { play.step(dt: Self.dt, frame: Self.frame(tension: 0.8), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: []) }
        play.step(dt: Self.dt, frame: Self.frame(tension: 0), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: [])
        let next = play.tension
        XCTAssertGreaterThan(next, 0.7, "no jump")
        for _ in 0..<60 { play.step(dt: Self.dt, frame: Self.frame(tension: 0), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: []) }
        let later = play.tension
        XCTAssertLessThan(later, 0.05, "released within a second")
    }

    func testSurprisesOneOfAKindInAFixedPool() {
        var play = ExcitementPlay()
        let seconds: [Float] = [5, 5, 5, 5]
        for i in [0, 0, 1, 2, 3] {
            play.step(dt: Self.dt, frame: Self.frame(surprise: WorldSurprise(index: i, seed: 9)), momentSeconds: 2, dropSeconds: 3,
                      surpriseSeconds: seconds)
        }
        let indices = play.surprises.map(\.index)
        XCTAssertEqual(indices, [0, 1, 2], "never two of a kind, at most three")
        play.step(dt: Self.dt, frame: Self.frame(surprise: WorldSurprise(index: 7, seed: 9)), momentSeconds: 2, dropSeconds: 3,
                  surpriseSeconds: seconds)
        XCTAssertNil(play.surpriseBegan, "an index outside the list plays nothing")
    }

    func testHeldTimeMovesNothing() {
        var play = ExcitementPlay()
        play.step(dt: Self.dt, frame: Self.frame(moment: Self.chord(1), surprise: WorldSurprise(index: 0, seed: 1)), momentSeconds: 2,
                  dropSeconds: 3, surpriseSeconds: [4])
        let before = play
        for _ in 0..<30 { play.step(dt: 0, frame: Self.frame(), momentSeconds: 2, dropSeconds: 3, surpriseSeconds: [4]) }
        XCTAssertEqual(play.moment, before.moment)
        XCTAssertEqual(play.surprises, before.surprises)
    }

    // MARK: - The worlds

    func testEveryWorldListsItsSurprises() {
        let lists: [(String, Int, Int)] = [
            ("lounge", SpaceshipLoungeModel.surpriseCount, SpaceshipLoungeModel.surpriseSeconds.count),
            ("cabin", SnowboundCabinModel.surpriseCount, SnowboundCabinModel.surpriseSeconds.count),
            ("bedroom", BedroomDawnModel.surpriseCount, BedroomDawnModel.surpriseSeconds.count),
            ("garden", ButterflyGardenModel.surpriseCount, ButterflyGardenModel.surpriseSeconds.count),
            ("steinway", MidnightSteinwayModel.surpriseCount, MidnightSteinwayModel.surpriseSeconds.count),
            ("submarine", SubmarineWindowModel.surpriseCount, SubmarineWindowModel.surpriseSeconds.count),
            ("reef", GreatBarrierReefModel.surpriseCount, GreatBarrierReefModel.surpriseSeconds.count),
        ]
        for (name, count, timed) in lists { XCTAssertEqual(count, timed, name) }
    }

    /// The director hands each of the seven its Excitement and counts its surprises.
    func testTheDirectorReachesEveryWorld() {
        for id in [SpaceshipLoungeModel.id, SnowboundCabinModel.id, BedroomDawnModel.id, ButterflyGardenModel.id,
                   MidnightSteinwayModel.id, SubmarineWindowModel.id, GreatBarrierReefModel.id] {
            let d = SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            let notes: [UInt8] = [60, 64, 67, 72]
            d.handle(notes.map { PerformanceEvent.noteOn(note: $0, velocity: 1) }, at: 0)
            var fired = false
            for i in 1...30 {
                _ = d.step(dt: Self.dt, t: Double(i) * Self.dt, quality: .high)
                if d.excitementFrame.moment != nil { fired = true }
            }
            XCTAssertTrue(fired, "\(id): a hard chord fires a moment")
        }
    }

    private func params(_ id: String, _ values: [String: ParamValue] = [:]) -> ParameterSet {
        ThemeRegistry.parameterSet(for: id, state: ThemeState(values: values))
    }

    func testTheLoungeJumps() {
        var m = SpaceshipLoungeModel()
        let p = params(SpaceshipLoungeModel.id)
        m.setExcitement(Self.frame(energy: 0.5, moment: Self.chord(1)))
        var fastest: Float = 0, stretched: Float = 0
        for _ in 0..<150 {
            let f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            fastest = max(fastest, f.warp.warpSpeed)
            stretched = max(stretched, f.jump)
            m.setExcitement(Self.frame(energy: 0.5))
        }
        XCTAssertGreaterThan(stretched, 0.9, "the stars stretch")
        XCTAssertGreaterThan(fastest, 1.5)
        let held = SpaceshipLoungeModel.stretch(age: 1.0, hold: SpaceshipLoungeModel.jumpHold)
        let snapped = SpaceshipLoungeModel.stretch(age: SpaceshipLoungeModel.jumpHold + 0.2, hold: SpaceshipLoungeModel.jumpHold)
        XCTAssertGreaterThan(held, 0.99)
        XCTAssertEqual(snapped, 0, accuracy: 1e-6, "then snap back")
        let light = SpaceshipLoungeModel.arrival(age: SpaceshipLoungeModel.jumpHold + 0.15, hold: SpaceshipLoungeModel.jumpHold)
        XCTAssertGreaterThan(light, 0.5, "the arrival's light")
    }

    func testTheCabinRoarsAndTheWindGathers() {
        var m = SnowboundCabinModel()
        let p = params(SnowboundCabinModel.id)
        var sky = SkyState()
        sky.sun = SkyDirection(azimuth: 0, altitude: -30)
        m.setSky(sky)
        m.setExcitement(Self.frame(tension: 0.9))
        var f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let calmWind = sky.wind
        XCTAssertGreaterThan(f.sky.wind, calmWind + 0.3, "the wind rises with tension")
        m.setExcitement(Self.frame(moment: Self.chord(1)))
        for _ in 0..<30 {
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            m.setExcitement(Self.frame())
        }
        XCTAssertGreaterThan(f.roar, 0.9, "the fire roars")
        XCTAssertGreaterThan(f.whirl, 0.5, "the snow whirls")
        XCTAssertGreaterThan(f.sky.snow, 0.3)
        // The aurora's edge and the star need the dark; by day the owl comes instead.
        var day = SkyState()
        day.sun = SkyDirection(azimuth: 0, altitude: 20)
        XCTAssertEqual(SnowboundCabinModel.available(1, sky: day), 0)
        XCTAssertEqual(SnowboundCabinModel.available(2, sky: day), 0)
        XCTAssertEqual(SnowboundCabinModel.available(1, sky: sky), 1)
        m.setExcitement(Self.frame(surprise: WorldSurprise(index: 1, seed: 3)))
        for _ in 0..<300 {
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            m.setExcitement(Self.frame())
        }
        XCTAssertGreaterThan(f.sky.aurora, 0.2, "the aurora's edge, called through the shared sky")
    }

    func testTheBedroomFloods() {
        var m = BedroomDawnModel()
        let p = params(BedroomDawnModel.id)
        var sky = SkyState()
        sky.sun = SkyDirection(azimuth: 90, altitude: 2)
        m.setSky(sky)
        m.setExcitement(Self.frame(moment: Self.chord(1)))
        var flood: Float = 0
        for _ in 0..<90 {
            let f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            flood = max(flood, f.flood)
            m.setExcitement(Self.frame())
        }
        XCTAssertGreaterThan(flood, 0.9, "the light floods in")
        var night = sky
        night.sun = SkyDirection(azimuth: 90, altitude: -20)
        XCTAssertEqual(BedroomDawnModel.available(2, sky: night), 1, "no sun, no rainbow: the paper plane")
        XCTAssertEqual(BedroomDawnModel.available(2, sky: sky), 2)
    }

    func testTheGardenSwarmTakesOff() {
        var m = ButterflyGardenModel()
        let p = params(ButterflyGardenModel.id)
        m.setExcitement(Self.frame())
        let before = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        m.setExcitement(Self.frame(moment: Self.chord(1)))
        var f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        for _ in 0..<30 {
            m.setExcitement(Self.frame())
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let more = f.butterflies.count - before.butterflies.count
        XCTAssertGreaterThanOrEqual(more, 30, "a swarm rises")
        XCTAssertGreaterThan(f.swarm, 0.5)
        XCTAssertGreaterThan(f.momentLight, 0.3)
        let up = f.butterflies.filter { $0.position.y > 0.12 }.count
        XCTAssertGreaterThan(up, 10, "taking off")
    }

    func testTheSteinwaySpotlightBlooms() {
        var m = MidnightSteinwayModel()
        let p = params(MidnightSteinwayModel.id)
        m.setExcitement(Self.frame(moment: Self.chord(1)))
        var spot: Float = 0
        for _ in 0..<60 {
            let f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            spot = max(spot, f.spot)
            m.setExcitement(Self.frame())
        }
        XCTAssertGreaterThan(spot, 0.9)
        m.setExcitement(Self.frame(surprise: WorldSurprise(index: 1, seed: 2)))
        var curtain: Float = 0
        for _ in 0..<180 {
            let f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
            curtain = max(curtain, f.curtain)
            m.setExcitement(Self.frame())
        }
        XCTAssertGreaterThan(curtain, 0.9, "the curtain stirs")
    }

    func testAWhalePassesThePorthole() {
        let start = SubmarineWindowModel.whale(age: 0, life: 13, strength: 1, heading: 1, drop: false)
        let middle = SubmarineWindowModel.whale(age: 6.5, life: 13, strength: 1, heading: 1, drop: false)
        let end = SubmarineWindowModel.whale(age: 12.99, life: 13, strength: 1, heading: 1, drop: false)
        XCTAssertLessThan(start.centre.x, -0.5, "it comes out of the gloom on one side")
        XCTAssertGreaterThan(middle.centre.x, start.centre.x)
        XCTAssertGreaterThan(end.centre.x, 1.5, "and swims on past the other")
        XCTAssertEqual(middle.presence, 1, accuracy: 1e-6)
        XCTAssertLessThan(end.presence, 0.05)
        var m = SubmarineWindowModel()
        let p = params(SubmarineWindowModel.id)
        m.setExcitement(Self.frame(tension: 0.8, moment: Self.chord(1)))
        var f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        XCTAssertEqual(f.dark, 0.8, accuracy: 1e-6, "the dark gathers")
        for _ in 0..<60 {
            m.setExcitement(Self.frame(energy: 1))
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let whale = f.whale?.presence ?? 0
        XCTAssertGreaterThan(whale, 0.9, "a whale passes")
        for _ in 0..<600 {
            m.setExcitement(Self.frame(energy: 1))
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        XCTAssertGreaterThan(f.passers.count, 0, "Energy brings far lights across")
        XCTAssertLessThanOrEqual(f.passers.count, SubmarineWindowModel.passerCap)
    }

    func testTheReefSpawnsAndTheSchoolBursts() {
        var spawning = CoralSpawning()
        for _ in 0..<5 { spawning.burst(strength: 1, quality: .high) }
        let full = spawning.spawn.beads.count
        XCTAssertLessThanOrEqual(full, CoralSpawning.cap(.high), "a fixed pool")
        XCTAssertGreaterThan(full, 200)
        let bright = spawning.spawn.beads.filter { $0.brightness > 0.5 }.count
        XCTAssertGreaterThan(bright, 100, "a burst's bundles catch the light at once")

        var m = GreatBarrierReefModel()
        let p = params(GreatBarrierReefModel.id)
        var sky = SkyState()
        sky.sun = SkyDirection(azimuth: 90, altitude: 40)
        m.setSky(sky)
        func spread(_ f: ReefFrame) -> Float {
            let ps = f.school.positions
            guard !ps.isEmpty else { return 0 }
            let c = ps.reduce(SIMD2<Float>(0, 0), +) / Float(ps.count)
            return ps.map { simd_length($0 - c) }.reduce(0, +) / Float(ps.count)
        }
        var f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        for _ in 0..<120 {
            m.setExcitement(Self.frame(tension: 0))
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let loose = spread(f)
        for _ in 0..<120 {
            m.setExcitement(Self.frame(tension: 1))
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let tight = spread(f)
        XCTAssertLessThan(tight, loose * 0.75, "the school tightens")
        let beads = f.spawn.beads.count
        m.setExcitement(Self.frame(drop: 1, moment: Self.chord(1, drop: true)))
        f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        let burst = f.spawn.beads.count - beads
        XCTAssertGreaterThan(burst, 150, "a spawning burst")
        for k in 1...40 {
            m.setExcitement(Self.frame(drop: 1 - Float(k) / 150))
            f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let burstApart = spread(f)
        XCTAssertGreaterThan(burstApart, loose * 1.3, "then it bursts apart")
        XCTAssertGreaterThan(f.burstHaze, 0.5)
    }

    /// The same performance draws the same worlds (the previews' determinism).
    func testDeterministic() {
        func run() -> [Float] {
            var m = SubmarineWindowModel()
            let p = params(SubmarineWindowModel.id)
            var out: [Float] = []
            for i in 0..<300 {
                m.setExcitement(Self.frame(energy: 1, moment: i == 10 ? Self.chord(1) : nil,
                                           surprise: i == 20 ? WorldSurprise(index: 1, seed: 4) : nil))
                let f = m.step(dt: Self.dt, params: p, roles: RoleValues(), inputs: InputFrame(), quality: .high)
                out.append(f.whale?.centre.x ?? -9)
                out.append(Float(f.passers.count))
            }
            return out
        }
        XCTAssertEqual(run(), run())
    }
}
