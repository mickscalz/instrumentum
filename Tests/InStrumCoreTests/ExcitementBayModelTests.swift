import XCTest
import simd
@testable import InStrumCore

/// Excitement in Bioluminescent Bay (Fire & Neon spec §5.5), at the model: Energy lifts the plankton, a big moment is a
/// wave of light running in from the bay's mouth to the shore, tension gathers the glow under the surface and a drop
/// breaks it into a brighter wave with sparkles, the surprises (a manta, a turtle, a fireball) play and end within their
/// time, held time freezes it all, and the pools hold. And Coast Road's day moment (the lighthouse is dark by day).
final class ExcitementBayModelTests: XCTestCase {
    typealias W = ExcitementWorldsTests

    /// The bay's night: the lake's sky, facing the pole (the moon up behind the camera's back doesn't matter here).
    static func night() -> SkyState { W.night() }

    static func bay(_ frames: Int, _ plan: W.Plan = W.Plan(), sky: SkyState = night()) -> [BayFrame] {
        var m = BioluminescentBayModel()
        return W.run(&m, sky: sky, frames: frames, plan: plan)
    }

    func testTheBayTakesExcitement() {
        XCTAssertEqual(BioluminescentBayModel.surpriseCount, 3)
        XCTAssertEqual(BioluminescentBayModel.surpriseSeconds.count, 3)
        let box = ThemeRegistry.entry(BioluminescentBayModel.id).make()
        XCTAssertEqual(box.surpriseCount, 3, "the director hands the bay its surprises")
    }

    func testEnergyLiftsThePlankton() {
        let calm = Self.bay(240, W.Plan(energy: 0)), lively = Self.bay(240, W.Plan(energy: 1))
        XCTAssertEqual(calm.last?.energy ?? 1, 0, accuracy: 1e-4)
        XCTAssertGreaterThan(lively.last?.energy ?? 0, 0.9)
        XCTAssertNil(lively.last?.wave, "Energy alone sends no wave")
    }

    /// The wave sets off from the mouth, reaches the waterline in about three seconds, lights the shore as it arrives,
    /// and is gone within its seven seconds.
    func testMomentIsAWaveOfLightAcrossTheBay() throws {
        let frames = Self.bay(600, W.Plan(moments: [10: W.chord(1)]))
        XCTAssertNil(frames[8].wave, "nothing before the moment")
        let start = try XCTUnwrap(frames[11].wave)
        XCTAssertLessThan(start.front, 0.05, "it sets off from the bay's mouth")
        XCTAssertFalse(start.drop)
        let mid = try XCTUnwrap(frames[10 + 90].wave)
        XCTAssertGreaterThan(mid.front, 0.35)
        XCTAssertLessThan(mid.front, 0.75, "half way in after a second and a half")
        XCTAssertGreaterThan(mid.light, 0.9)
        let fronts = frames.compactMap { $0.wave?.front }
        XCTAssertEqual(fronts, fronts.sorted(), "it only ever runs in toward the shore")
        let arrived = try XCTUnwrap(frames[10 + Int(BioluminescentBayModel.waveRun * 60) + 6].wave)
        XCTAssertGreaterThan(arrived.front, 0.99)
        XCTAssertGreaterThan(arrived.shore, 0.6, "the shore lit as it arrives")
        XCTAssertNil(frames[10 + Int(BioluminescentBayModel.momentSeconds * 60) + 5].wave, "gone within its time")
        XCTAssertTrue(frames.allSatisfy { $0.sparkle == 0 }, "no sparkles without a drop")
        // A weaker moment is a dimmer wave (Reduce Motion's half strength among them).
        let weak = Self.bay(200, W.Plan(moments: [10: W.chord(0.3)]))
        XCTAssertLessThan(weak[100].wave?.light ?? 1, 0.45)
    }

    func testTensionGathersTheGlowAndADropBreaksIt() throws {
        let frames = Self.bay(400, W.Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: W.chord(1, drop: true)]))
        XCTAssertGreaterThan(frames[170].gather, 0.7, "the glow gathers under the surface")
        XCTAssertLessThan(frames[240].gather, 0.1, "then breaks")
        let wave = try XCTUnwrap(frames[181].wave)
        XCTAssertTrue(wave.drop)
        XCTAssertGreaterThanOrEqual(wave.front, BioluminescentBayModel.dropStart - 0.01, "from the gathered glow, mid-bay")
        XCTAssertGreaterThan(frames[200].sparkle, 0.5, "sparkles scattering")
        XCTAssertGreaterThan(frames[180 + Int(BioluminescentBayModel.dropRun * 60) + 6].wave?.shore ?? 0, 0.6)
    }

    func testSurprisesAllPlay() {
        for i in 0..<3 {
            let seconds = BioluminescentBayModel.surpriseSeconds[i]
            let n = 10 + Int(seconds * 60) + 30
            let frames = Self.bay(n, W.Plan(surprises: [10: WorldSurprise(index: i, seed: 11)]))
            XCTAssertEqual(frames[40].surprises.map(\.index), [i], "surprise \(i) plays")
            XCTAssertTrue(frames.last?.surprises.isEmpty ?? false, "surprise \(i) ends within its time")
            if i == 2 {
                // The fireball: in the sky the shared layer draws (and the bay mirrors), lighting the bay.
                XCTAssertGreaterThanOrEqual(frames[40].worldMeteors, 1)
                XCTAssertTrue(frames[40].sky.meteors.contains { $0.magnitude <= -5 })
                XCTAssertGreaterThan(frames.map(\.flashRequest).max() ?? 0, 0.05)
                XCTAssertEqual(frames.last?.worldMeteors, 0)
            }
        }
    }

    func testHeldTimeHoldsTheBay() throws {
        var m = BioluminescentBayModel()
        let params = ThemeRegistry.parameterSet(for: BioluminescentBayModel.id, state: ThemeState())
        m.setSky(Self.night())
        var e = ExcitementFrame()
        e.moment = W.chord(1)
        m.setExcitement(e)
        _ = m.step(dt: 1.0 / 60, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        var held: BayFrame?
        for _ in 0..<60 {
            m.setExcitement(ExcitementFrame())
            held = m.step(dt: 0, params: params, roles: RoleValues(), inputs: InputFrame(), quality: .high)
        }
        let wave = try XCTUnwrap(held?.wave, "held time holds the wave where it is")
        XCTAssertLessThan(wave.front, 0.05)
    }

    func testThePoolsHold() {
        var surprises: [Int: WorldSurprise] = [:]
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 5, to: 3600, by: 7) { surprises[i] = WorldSurprise(index: i % 3, seed: UInt64(i)) }
        for i in stride(from: 15, to: 3600, by: 15) { moments[i] = W.chord(1, drop: i % 120 == 0) }
        let frames = Self.bay(3600, W.Plan(energy: 1, tension: { _ in 1 }, moments: moments, surprises: surprises))
        XCTAssertLessThanOrEqual(frames.map(\.surprises.count).max() ?? 0, ExcitementPlay.surpriseCap)
        XCTAssertLessThanOrEqual(frames.map(\.worldMeteors).max() ?? 0, WorldMeteors.capacity)
        XCTAssertLessThanOrEqual(frames.map(\.sky.meteors.count).max() ?? 0, MeteorSky.slots)
    }

    // MARK: - Coast Road by day

    /// By day the lighthouse is dark: the moment is the sun breaking out, its glitter racing across the sea to the shore,
    /// and a flock of seabirds lifting past the window. Dusk has a little of both; night the lighthouse alone.
    func testRoadDayMomentIsTheSunBreakingOut() throws {
        func road(sunAltitude: Double) -> [RoadFrame] {
            var s = W.night()
            s.sun = SkyDirection(azimuth: 280, altitude: sunAltitude)
            var m = CoastRoadModel()
            let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
            return W.run(&m, sky: s, frames: 480, plan: W.Plan(moments: [10: W.chord(1)]), state: follow)
        }
        let day = road(sunAltitude: 15)
        XCTAssertEqual(day[8].sunBreak, 0)
        XCTAssertGreaterThan(day[100].sunBreak, 0.9, "the sun breaks out")
        XCTAssertEqual(day[100].beamLight, 0, "the lighthouse dark by day")
        let race = day.map(\.glitterRace)
        XCTAssertLessThan(race[20], 0.1, "its glitter sets off from the horizon")
        XCTAssertGreaterThan(race[10 + 60 * 3], 0.99, "and reaches the shore in under three seconds")
        let flock = try XCTUnwrap(day[100].flock)
        XCTAssertGreaterThanOrEqual(flock.count, 6)
        XCTAssertLessThanOrEqual(flock.count, CoastRoadModel.flockMost)
        XCTAssertEqual(day.last?.sunBreak, 0, "over within its time")
        XCTAssertNil(day.last?.flock)
        let night = road(sunAltitude: -20)
        XCTAssertTrue(night.allSatisfy { $0.sunBreak == 0 && $0.flock == nil }, "night is the lighthouse alone")
        XCTAssertGreaterThan(night[100].beamLight, 0.5)
        let dusk = road(sunAltitude: 0.5)
        XCTAssertGreaterThan(dusk[100].sunBreak, 0.2, "dusk has a little of both")
        XCTAssertLessThan(dusk[100].sunBreak, 0.8)
        XCTAssertGreaterThan(dusk[100].beamLight, 0.2)
    }
}
