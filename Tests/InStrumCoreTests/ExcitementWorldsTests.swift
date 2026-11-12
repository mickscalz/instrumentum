import XCTest
import simd
@testable import InStrumCore

/// Excitement in Moonlit Lake, Golden Hour Beach, Coast Road and Aurora Fjord (Fire & Neon spec §5.5; plan Task 6), at
/// the models: Energy drives each world's dials, a big moment plays its signature event, every surprise plays and ends
/// within its time, tension gathers the world and a drop releases it, held time freezes it all, and the pools hold.
final class ExcitementWorldsTests: XCTestCase {
    // MARK: - Helpers

    /// A night sky with the moon up toward the north-east (as Melbourne's lake sees it), the meteor clock at `t`.
    static func night(moonUp: Bool = true) -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 250, altitude: -30)
        s.moon = moonUp ? SkyDirection(azimuth: 60, altitude: 25) : SkyDirection(azimuth: 60, altitude: -20)
        s.moonLit = 0.9
        s.moonPhase = 0.55
        s.latitude = -37.8
        s.hemisphere = -1
        s.hourOfDay = 22
        s.starVisibility = 1
        return s
    }

    static func chord(_ strength: Float, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: false, isDrop: drop)
    }

    /// What each step hands the world: Energy and tension throughout, a moment and a surprise on their steps.
    struct Plan {
        var energy: Float = 0.3
        var tension: (Int) -> Float = { _ in 0 }
        var moments: [Int: BigMoment] = [:]
        var surprises: [Int: WorldSurprise] = [:]
        var gentle = false
        var dt = 1.0 / 60
    }

    /// Steps a world `frames` times under `sky` (its meteor clock advanced each step, as the Living Sky's is), handing it
    /// the plan's Excitement; returns every frame.
    static func run<M: ThemeModel & SkyAware & ExcitementAware>(_ model: inout M, sky: SkyState, frames: Int, plan: Plan,
                                                             state: ThemeState = ThemeState()) -> [M.Frame] {
        let params = ThemeRegistry.parameterSet(for: M.id, state: state)
        var s = sky
        var out: [M.Frame] = []
        out.reserveCapacity(frames)
        for i in 1...max(1, frames) {
            s.meteorTime += plan.dt
            model.setSky(s)
            var e = ExcitementFrame()
            e.energy = plan.energy
            e.visualEnergy = plan.energy
            e.tension = plan.tension(i)
            e.gentle = plan.gentle
            if let m = plan.moments[i] {
                e.moment = m
                e.drop = m.isDrop ? 1 : 0
            }
            e.surprise = plan.surprises[i]
            model.setExcitement(e)
            out.append(model.step(dt: plan.dt, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high))
        }
        return out
    }

    // MARK: - Every world

    /// Every world adopts Excitement and lists its three surprises (the director hands it them).
    func testTheFourWorldsTakeExcitement() {
        XCTAssertEqual(MoonlitLakeModel.surpriseCount, 3)
        XCTAssertEqual(GoldenHourBeachModel.surpriseCount, 3)
        XCTAssertEqual(CoastRoadModel.surpriseCount, 3)
        XCTAssertEqual(AuroraFjordModel.surpriseCount, 3)
        let ids = [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, AuroraFjordModel.id]
        for id in ids {
            let box = ThemeRegistry.entry(id).make()
            XCTAssertEqual(box.surpriseCount, 3, id)
        }
    }

    // MARK: - Moonlit Lake

    func testLakeMomentIsAMeteorBurst() throws {
        var lake = MoonlitLakeModel()
        let frames = Self.run(&lake, sky: Self.night(), frames: 760, plan: Plan(moments: [10: Self.chord(1)]))
        let shown = frames.map(\.worldMeteors)
        XCTAssertEqual(shown[8], 0, "nothing before the moment")
        XCTAssertGreaterThanOrEqual(shown[40], 3, "the burst, half a second in")
        XCTAssertLessThanOrEqual(shown.max() ?? 99, WorldMeteors.capacity)
        // They are in the sky the shared layer draws (so the water mirrors them), ahead of the calendar's.
        let mid = frames[40]
        XCTAssertGreaterThanOrEqual(mid.sky.meteors.count, 3)
        XCTAssertLessThanOrEqual(mid.sky.meteors.count, 6)
        // From one radiant: every one of them runs away from the same point.
        let radiants = Set(mid.sky.meteors.map { [$0.radiant.x, $0.radiant.y, $0.radiant.z] })
        XCTAssertEqual(radiants.count, 1)
        let first = try XCTUnwrap(mid.sky.meteors.first)
        let away = simd_dot(first.end, first.radiant) < simd_dot(first.start, first.radiant)
        XCTAssertTrue(away, "it runs away from its radiant")
        // A strong moment's fireballs light the lake (before the limiter); a weak one has none.
        let lakeLight: Float = frames.map(\.flashRequest).max() ?? 0
        XCTAssertGreaterThan(lakeLight, 0.05)
        var weak = MoonlitLakeModel()
        let soft = Self.run(&weak, sky: Self.night(), frames: 240, plan: Plan(moments: [10: Self.chord(0.3)]))
        let softLight: Float = soft.map(\.flashRequest).max() ?? 1
        XCTAssertEqual(softLight, 0)
        let fewest = soft.map(\.worldMeteors).max() ?? 0
        XCTAssertGreaterThanOrEqual(fewest, 2)
        // All gone within the burst's run and their trains (a fireball's lasts eight seconds).
        XCTAssertEqual(frames.last?.worldMeteors, 0)
    }

    func testLakeEnergyStirsTheWater() {
        var calm = MoonlitLakeModel(), stirred = MoonlitLakeModel()
        let a = Self.run(&calm, sky: Self.night(), frames: 300, plan: Plan(energy: 0))
        let b = Self.run(&stirred, sky: Self.night(), frames: 300, plan: Plan(energy: 1))
        let still: Float = a.last?.windOnWater ?? 1
        let ruffled: Float = b.last?.windOnWater ?? 0
        XCTAssertGreaterThan(ruffled, still + 0.25)
        XCTAssertTrue(a.allSatisfy { $0.rings.isEmpty }, "a still lake at rest")
        XCTAssertTrue(b.contains { !$0.rings.isEmpty }, "the water's own dimples")
        XCTAssertTrue(b.allSatisfy { $0.rings.count <= MoonlitLakeModel.ringCount })
    }

    func testLakeSurprisesAllPlayAndEnd() {
        for kind in LakeSurprise.Kind.allCases {
            var lake = MoonlitLakeModel()
            let frames = Self.run(&lake, sky: Self.night(), frames: 600,
                                  plan: Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 11)]))
            let playing = frames[30].surprises.map(\.kind)
            XCTAssertEqual(playing, [kind], "\(kind)")
            let end = 10 + Int(LakeSurprise.duration(kind) * 60) + 2
            XCTAssertTrue(frames[end].surprises.isEmpty, "\(kind) ends within its time")
            switch kind {
            case .fireball: XCTAssertGreaterThan(frames[60].worldMeteors, 0)
            case .owl: XCTAssertNotNil(frames[120].owl)
            case .fish: XCTAssertFalse(frames[60].rings.isEmpty)
            }
            XCTAssertNil(frames[end].owl)
        }
        // With the moon down the owl can't cross it: a fish rises instead.
        var moonless = MoonlitLakeModel()
        let dark = Self.run(&moonless, sky: Self.night(moonUp: false), frames: 60, plan: Plan(surprises: [10: WorldSurprise(index: 1, seed: 3)]))
        let instead: [LakeSurprise.Kind] = dark.last?.surprises.map(\.kind) ?? []
        XCTAssertEqual(instead, [LakeSurprise.Kind.fish])
        XCTAssertNil(dark.last?.owl)
    }

    func testLakeMistGathersThenLifts() throws {
        var lake = MoonlitLakeModel()
        let frames = Self.run(&lake, sky: Self.night(), frames: 480,
                              plan: Plan(tension: { $0 < 240 ? 0.8 : 0 }, moments: [240: Self.chord(1, drop: true)]))
        XCTAssertGreaterThan(frames[235].mistGather, 0.6, "the mist gathers")
        XCTAssertEqual(frames[235].mistLift, 0)
        XCTAssertGreaterThan(frames[300].mistLift, 0.95, "then lifts all at once")
        XCTAssertLessThan(frames[300].mistGather, 0.1)
    }

    // MARK: - Golden Hour Beach

    static func goldenHour() -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 290, altitude: 5)
        s.moon = SkyDirection(azimuth: 90, altitude: -20)
        s.latitude = -37.8
        s.hemisphere = -1
        s.hourOfDay = 19
        return s
    }

    func testBeachMomentIsFireworks() {
        var beach = GoldenHourBeachModel()
        let frames = Self.run(&beach, sky: Self.goldenHour(), frames: 600, plan: Plan(moments: [10: Self.chord(1)]))
        XCTAssertTrue(frames[8].fireworks.isEmpty)
        let burst = frames[40].fireworks
        XCTAssertFalse(burst.isEmpty)
        XCTAssertTrue(burst.contains { $0.sinceBurst >= 0 }, "the first shell has burst by half a second")
        XCTAssertGreaterThan(frames[40].flashRequest, 0.05)
        let most = frames.map { $0.fireworks.count }.max() ?? 0
        XCTAssertGreaterThanOrEqual(most, 6, "a full-strength moment fires nine, most of them in the air at once")
        XCTAssertLessThanOrEqual(most, GoldenHourBeachModel.shellCount)
        XCTAssertTrue(frames.allSatisfy { $0.fireworks.allSatisfy { $0.stars <= FireworkShell.mostStars } })
        XCTAssertTrue(frames.last?.fireworks.isEmpty ?? false, "all spent within ten seconds")
        var weak = GoldenHourBeachModel()
        let few = Self.run(&weak, sky: Self.goldenHour(), frames: 360, plan: Plan(moments: [10: Self.chord(0.3)]))
        let fewest = few.map { $0.fireworks.count }.max() ?? 0
        XCTAssertGreaterThanOrEqual(fewest, 3)
        XCTAssertLessThanOrEqual(fewest, 5)
    }

    func testBeachEnergyRaisesTheSurfAndBringsGulls() {
        var calm = GoldenHourBeachModel(), lively = GoldenHourBeachModel()
        let a = Self.run(&calm, sky: Self.goldenHour(), frames: 600, plan: Plan(energy: 0))
        let b = Self.run(&lively, sky: Self.goldenHour(), frames: 600, plan: Plan(energy: 1))
        let quietSwell: Float = a.last?.swellScale ?? 1
        let livelySwell: Float = b.last?.swellScale ?? 0
        XCTAssertGreaterThan(livelySwell, 1.25 * quietSwell)
        let noGulls: Bool = a.last?.gulls.isEmpty ?? false
        XCTAssertTrue(noGulls)
        let gulls: Int = b.last?.gulls.count ?? 0
        XCTAssertGreaterThanOrEqual(gulls, 4)
        var night = Self.goldenHour()
        night.sun = SkyDirection(azimuth: 290, altitude: -20)
        var dark = GoldenHourBeachModel()
        let nightFrames = Self.run(&dark, sky: night, frames: 600, plan: Plan(energy: 1))
        let noneAtNight: Bool = nightFrames.last?.gulls.isEmpty ?? false
        XCTAssertTrue(noneAtNight, "no gulls at night")
    }

    func testBeachSurprisesAllPlayAndEnd() {
        var setting = Self.goldenHour()
        setting.sun = SkyDirection(azimuth: 290, altitude: -0.6)   // the sun's last sliver on the horizon
        XCTAssertTrue(GoldenHourBeachModel.sunOnTheHorizon(setting))
        XCTAssertFalse(GoldenHourBeachModel.sunOnTheHorizon(Self.goldenHour()))
        for kind in BeachSurprise.Kind.allCases {
            var beach = GoldenHourBeachModel()
            let frames = Self.run(&beach, sky: setting, frames: 1600, plan: Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 5)]))
            XCTAssertEqual(frames[20].surprises.map(\.kind), [kind], "\(kind)")
            let end = 10 + Int(BeachSurprise.duration(kind) * 60) + 2
            XCTAssertTrue(frames[end].surprises.isEmpty, "\(kind) ends within its time")
            switch kind {
            case .dolphins: XCTAssertTrue(frames[10..<end].contains { !$0.dolphins.isEmpty })
            case .kite: XCTAssertNotNil(frames[300].kite)
            case .greenFlash: XCTAssertGreaterThan(frames[60].greenFlash, 0.9)
            }
            let over = frames[end]
            XCTAssertTrue(over.dolphins.isEmpty)
            XCTAssertNil(over.kite)
            XCTAssertEqual(over.greenFlash, 0)
        }
        // At golden hour (the sun 5° up) there is no green flash to see: the pod comes instead.
        var beach = GoldenHourBeachModel()
        let high = Self.run(&beach, sky: Self.goldenHour(), frames: 30, plan: Plan(surprises: [10: WorldSurprise(index: 2, seed: 5)]))
        let instead: [BeachSurprise.Kind] = high.last?.surprises.map(\.kind) ?? []
        XCTAssertEqual(instead, [BeachSurprise.Kind.dolphins])
    }

    func testBeachSwellBuildsThenABigWave() throws {
        var beach = GoldenHourBeachModel()
        let frames = Self.run(&beach, sky: Self.goldenHour(), frames: 60 * 20,
                              plan: Plan(tension: { $0 < 300 ? 0.8 : 0 }, moments: [300: Self.chord(1, drop: true)]))
        let calm = frames[2].swellScale
        XCTAssertGreaterThan(frames[295].swellBuild, 0.6)
        XCTAssertGreaterThan(frames[295].swellScale, 1.35 * calm, "the swell builds")
        // The next wave due at least 2 s after the drop (the swell's clock as the drop arrived) breaks at full strength.
        let due = frames[298].swellTime + 2   // frames[k] is step k + 1: the drop's step is frames[299]
        let after = frames[300...].flatMap { $0.recent }.filter { $0.breakTime >= due }.sorted { $0.breakTime < $1.breakTime }
        let big = try XCTUnwrap(after.first)
        XCTAssertGreaterThanOrEqual(big.strength, 0.99)
    }

    // MARK: - Coast Road

    static func blueHour() -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 280, altitude: -6)
        s.moon = SkyDirection(azimuth: 90, altitude: -20)
        s.latitude = -37.8
        s.hemisphere = -1
        s.hourOfDay = 20.5
        return s
    }

    func testRoadMomentSweepsTheBeamRound() {
        var road = CoastRoadModel()
        let frames = Self.run(&road, sky: Self.blueHour(), frames: 480, plan: Plan(moments: [10: Self.chord(1)]))
        let before = frames[8].beamLight
        XCTAssertGreaterThan(before, 0.1, "the lighthouse is lit from dusk")
        XCTAssertGreaterThan(frames[70].beamLight, 0.85, "the beam swells as it sweeps")
        // A beam comes round to face you about two seconds in, and the lantern flares (before the limiter).
        let facing = frames[60..<200].map { CoastRoadModel.facing($0.beamAngle) }.min() ?? 9
        XCTAssertLessThan(facing, 0.05)
        let lantern: Float = frames[60..<200].map(\.flashRequest).max() ?? 0
        XCTAssertGreaterThan(lantern, 0.2)
        let settled: Float = frames.last?.beamLight ?? 1
        XCTAssertLessThan(settled, 0.3, "and settles again")
        // By day the lighthouse is dark.
        var day = Self.blueHour()
        day.sun = SkyDirection(azimuth: 280, altitude: 30)
        var noon = CoastRoadModel()
        let noonFrames = Self.run(&noon, sky: day, frames: 120, plan: Plan(moments: [10: Self.chord(1)]))
        let noonBeam: Float = noonFrames.map(\.beamLight).max() ?? 1
        XCTAssertEqual(noonBeam, 0)
    }

    func testRoadEnergyPushesTheCarAndBringsTraffic() {
        var calm = CoastRoadModel(), busy = CoastRoadModel()
        let a = Self.run(&calm, sky: Self.blueHour(), frames: 900, plan: Plan(energy: 0))
        let b = Self.run(&busy, sky: Self.blueHour(), frames: 900, plan: Plan(energy: 1))
        let restSpeed: Float = a.last?.speed ?? 1
        let pushedSpeed: Float = b.last?.speed ?? 0
        XCTAssertGreaterThan(pushedSpeed, restSpeed + 0.15)
        XCTAssertTrue(a.allSatisfy { $0.washes.isEmpty }, "no traffic at rest")
        XCTAssertTrue(b.contains { !$0.washes.isEmpty }, "oncoming headlights")
        XCTAssertTrue(b.allSatisfy { $0.washes.count <= CoastRoadModel.washCount })
        let quietCars: Double = a.last?.ambience.level(.passingCar) ?? 1
        let busyCars: Double = b.last?.ambience.level(.passingCar) ?? 0
        XCTAssertGreaterThan(busyCars, quietCars)
        for f in b { XCTAssertEqual(f.ambience.speed, Double(f.speed), accuracy: 1e-6) }
    }

    func testRoadSurprisesAllPlayAndEnd() {
        for kind in RoadSurprise.Kind.allCases {
            var road = CoastRoadModel()
            let frames = Self.run(&road, sky: Self.blueHour(), frames: 1700, plan: Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 9)]))
            XCTAssertEqual(frames[20].surprises.map(\.kind), [kind], "\(kind)")
            let end = 10 + Int(RoadSurprise.duration(kind) * 60) + 2
            XCTAssertTrue(frames[end].surprises.isEmpty, "\(kind) ends within its time")
            switch kind {
            case .fox: XCTAssertNotNil(frames[60].fox)
            case .train: XCTAssertGreaterThan(frames[300].train?.light ?? 0, 0.5)
            case .shootingStar: XCTAssertFalse(frames[30].sky.meteors.isEmpty)
            }
            XCTAssertNil(frames[end].fox)
            XCTAssertNil(frames[end].train)
        }
    }

    func testRoadHeadlightsGatherThenTheRoadOpens() {
        var road = CoastRoadModel()
        let frames = Self.run(&road, sky: Self.blueHour(), frames: 600,
                              plan: Plan(tension: { $0 < 240 ? 0.8 : 0 }, moments: [240: Self.chord(1, drop: true)]))
        XCTAssertGreaterThan(frames[235].headlights, 0.6, "headlights gather round the bend")
        XCTAssertEqual(frames[235].open, 0)
        XCTAssertGreaterThan(frames[330].open, 0.95, "then the road opens onto the sea")
        XCTAssertLessThan(frames[330].headlights, 0.1)
    }

    // MARK: - Aurora Fjord

    static func fjordNight() -> SkyState {
        var s = SkyState()
        s.sun = SkyDirection(azimuth: 0, altitude: -30)
        s.moon = SkyDirection(azimuth: 120, altitude: -10)
        s.latitude = -37.8
        s.hemisphere = -1
        s.hourOfDay = 23
        s.aurora = 0.8
        s.auroraAltitude = 30
        s.starVisibility = 1
        return s
    }

    func testFjordMomentIsAnAuroraSurge() {
        var fjord = AuroraFjordModel()
        let frames = Self.run(&fjord, sky: Self.fjordNight(), frames: 600, plan: Plan(moments: [10: Self.chord(1)]))
        XCTAssertEqual(frames[8].surge, 0)
        XCTAssertGreaterThan(frames[40].surge, 0.8, "the surge, half a second in")
        XCTAssertGreaterThan(frames[120].corona, 0.8, "a corona overhead")
        XCTAssertEqual(frames.last?.surge, 0, "and it settles")
        XCTAssertEqual(frames.last?.corona, 0)
        // A second moment while one plays never stacks a second surge.
        var twice = AuroraFjordModel()
        let both = Self.run(&twice, sky: Self.fjordNight(), frames: 200, plan: Plan(moments: [10: Self.chord(1), 70: Self.chord(1)]))
        XCTAssertLessThan(both[71].surgeAge, both[69].surgeAge + 0.1)
        XCTAssertGreaterThan(both[71].surgeAge, 0.9)
    }

    func testFjordEnergyQuickensAndLiftsTheAurora() {
        var calm = AuroraFjordModel(), lively = AuroraFjordModel()
        let a = Self.run(&calm, sky: Self.fjordNight(), frames: 1800, plan: Plan(energy: 0))
        let b = Self.run(&lively, sky: Self.fjordNight(), frames: 1800, plan: Plan(energy: 1))
        let calmPace: Float = a.last?.auroraPace ?? 0
        let livelyPace: Float = b.last?.auroraPace ?? 0
        let calmLift: Float = a.last?.auroraLift ?? 1
        let livelyLift: Float = b.last?.auroraLift ?? 0
        XCTAssertEqual(calmPace, 1, accuracy: 1e-4)
        XCTAssertGreaterThan(livelyPace, 1.7)
        XCTAssertEqual(calmLift, 0, accuracy: 1e-4)
        XCTAssertGreaterThan(livelyLift, 0.8 * AuroraFjordModel.liftAtFull)
        // A single held note's Energy (about half) lifts it barely at all in the first seconds.
        var held = AuroraFjordModel()
        let early = Self.run(&held, sky: Self.fjordNight(), frames: 120, plan: Plan(energy: 0.55))
        let earlyLift: Float = early.last?.auroraLift ?? 9
        XCTAssertLessThan(earlyLift, 0.2)
    }

    func testFjordSurprisesAllPlayAndEnd() {
        for kind in FjordSurprise.Kind.allCases {
            var fjord = AuroraFjordModel()
            let frames = Self.run(&fjord, sky: Self.fjordNight(), frames: 1800, plan: Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 21)]))
            XCTAssertEqual(frames[20].surprises.map(\.kind), [kind], "\(kind)")
            let end = 10 + Int(FjordSurprise.duration(kind) * 60) + 2
            XCTAssertTrue(frames[end].surprises.isEmpty, "\(kind) ends within its time")
            switch kind {
            case .fireball:
                XCTAssertFalse(frames[60].sky.meteors.isEmpty)
                let fireballLight: Float = frames.map(\.flashRequest).max() ?? 0
                XCTAssertGreaterThan(fireballLight, 0.05)
            case .orca:
                let fins: [Float] = frames[10..<end].map { $0.orca?.fin ?? 0 }
                let highestFin: Float = fins.max() ?? 0
                XCTAssertGreaterThan(highestFin, 0.9)
                let blew = frames[10..<end].contains { ($0.orca?.blowAge ?? -1) >= 0 }
                XCTAssertTrue(blew)
            case .satelliteFlare:
                let flares: [Float] = frames[10..<end].compactMap { $0.sky.satellites.first?.flare }
                let peak: Float = flares.max() ?? 0
                XCTAssertGreaterThan(peak, 0.95)
                let magnitudes: [Float] = frames[10..<end].compactMap { $0.sky.satellites.first?.magnitude }
                let brightest: Float = magnitudes.min() ?? 0
                XCTAssertGreaterThanOrEqual(brightest, Satellites.venus - 1e-4, "never brighter than Venus")
            }
            XCTAssertNil(frames[end].orca)
            XCTAssertTrue(frames[end].sky.satellites.isEmpty)
        }
    }

    func testFjordCurtainsGatherThenSurge() {
        var fjord = AuroraFjordModel()
        let frames = Self.run(&fjord, sky: Self.fjordNight(), frames: 480,
                              plan: Plan(tension: { $0 < 240 ? 0.8 : 0 }, moments: [240: Self.chord(0.4, drop: true)]))
        XCTAssertGreaterThan(frames[235].gather, 0.6, "the curtains gather")
        XCTAssertGreaterThan(frames[300].surge, 0.95, "a drop surges in full, whatever its chord")
        XCTAssertLessThan(frames[300].gather, 0.1)
    }

    // MARK: - Held time, and the sky left alone

    /// Hold the Moment: a world stepped by 0 changes nothing, whatever is playing.
    func testHeldTimeFreezesTheMoments() {
        var lake = MoonlitLakeModel()
        var frames = Self.run(&lake, sky: Self.night(), frames: 40, plan: Plan(moments: [10: Self.chord(1)]))
        let before = frames.last
        var still = Plan()
        still.dt = 0
        frames = Self.run(&lake, sky: Self.night(), frames: 30, plan: still)
        XCTAssertEqual(frames.last?.mistGather, before?.mistGather)
        XCTAssertEqual(frames.last?.rings, before?.rings)
        var fjord = AuroraFjordModel()
        let moving = Self.run(&fjord, sky: Self.fjordNight(), frames: 40, plan: Plan(moments: [10: Self.chord(1)]))
        let held = Self.run(&fjord, sky: Self.fjordNight(), frames: 30, plan: still)
        XCTAssertEqual(held.last?.surgeAge, moving.last?.surgeAge)
        XCTAssertEqual(held.last?.surge, moving.last?.surge)
    }

    /// With nothing playing, a world's sky is the sky it was given (no meteors, satellites or anything else of its own).
    func testAQuietWorldLeavesTheSkyAlone() {
        var lake = MoonlitLakeModel()
        let sky = Self.night()
        let frame = Self.run(&lake, sky: sky, frames: 30, plan: Plan(energy: 0)).last
        XCTAssertEqual(frame?.sky.meteors, sky.meteors)
        var fjord = AuroraFjordModel()
        let fj = Self.run(&fjord, sky: Self.fjordNight(), frames: 30, plan: Plan(energy: 0)).last
        XCTAssertTrue(fj?.sky.satellites.isEmpty ?? false)
        XCTAssertTrue(fj?.sky.meteors.isEmpty ?? false)
    }
}
