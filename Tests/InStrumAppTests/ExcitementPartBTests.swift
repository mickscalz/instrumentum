import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// The seven worlds of Excitement's part B (Fire & Neon spec §5.5; plan Task 7): the Spaceship Lounge, Snowbound Cabin,
/// Bedroom at Dawn, Butterfly Garden, Midnight Steinway, Submarine Window and Great Barrier Reef.
enum PartBWorld: String, CaseIterable {
    case lounge, cabin, bedroom, garden, steinway, submarine, reef

    var themeID: String {
        switch self {
        case .lounge: return SpaceshipLoungeModel.id
        case .cabin: return SnowboundCabinModel.id
        case .bedroom: return BedroomDawnModel.id
        case .garden: return ButterflyGardenModel.id
        case .steinway: return MidnightSteinwayModel.id
        case .submarine: return SubmarineWindowModel.id
        case .reef: return GreatBarrierReefModel.id
        }
    }

    var surpriseCount: Int {
        switch self {
        case .lounge: return SpaceshipLoungeModel.surpriseCount
        case .cabin: return SnowboundCabinModel.surpriseCount
        case .bedroom: return BedroomDawnModel.surpriseCount
        case .garden: return ButterflyGardenModel.surpriseCount
        case .steinway: return MidnightSteinwayModel.surpriseCount
        case .submarine: return SubmarineWindowModel.surpriseCount
        case .reef: return GreatBarrierReefModel.surpriseCount
        }
    }

    /// How long each surprise plays (s).
    var surpriseSeconds: [Float] {
        switch self {
        case .lounge: return SpaceshipLoungeModel.surpriseSeconds
        case .cabin: return SnowboundCabinModel.surpriseSeconds
        case .bedroom: return BedroomDawnModel.surpriseSeconds
        case .garden: return ButterflyGardenModel.surpriseSeconds
        case .steinway: return MidnightSteinwayModel.surpriseSeconds
        case .submarine: return SubmarineWindowModel.surpriseSeconds
        case .reef: return GreatBarrierReefModel.surpriseSeconds
        }
    }

    /// The surprises' names (for the previews' files).
    var surpriseNames: [String] {
        switch self {
        case .lounge: return ["comet", "far-ship", "pulsar"]
        case .cabin: return ["owl", "aurora-edge", "star-break"]
        case .bedroom: return ["sill-bird", "paper-plane", "rainbow"]
        case .garden: return ["hummingbird", "rain-on-glass"]
        case .steinway: return ["motes", "curtain"]
        case .submarine: return ["anglerfish", "squid-cloud", "far-sub"]
        case .reef: return ["manta", "turtle", "reef-shark"]
        }
    }

    /// Frozen Melbourne skies the tests use: night for the lounge and the cabin (the aurora's edge and the star need the
    /// dark), a held pastel dawn in the bedroom (its default), day under the sea.
    var sky: SkySettings? {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenPhase = 0.3; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        switch self {
        case .lounge, .cabin: s.frozenHour = 22
        case .bedroom: s.frozenHour = 13
        case .submarine, .reef: s.frozenHour = 13.5
        case .garden, .steinway: return nil
        }
        return s
    }

    /// The world's settings for the tests: the submarine a little shallower than its default (more light to see by).
    var values: [String: ParamValue] {
        switch self {
        case .submarine: return ["depth": .number(0.12)]
        default: return [:]
        }
    }
}

/// One world stepped at 60 fps with an Excitement the test chooses, and drawn by its renderer, as the canvas does: the
/// director runs the world's Living Sky; the world itself is stepped here.
@MainActor
final class PartBRig {
    let world: PartBWorld
    let director: SceneDirector
    let params: ParameterSet
    let quality: QualityLevel
    let gentle: Bool
    let size: CGSize
    private(set) var frameIndex = 0
    private var elapsed = 0.0

    private var lounge = SpaceshipLoungeModel()
    private var cabin = SnowboundCabinModel()
    private var bedroom = BedroomDawnModel()
    private var garden = ButterflyGardenModel()
    private var steinway = MidnightSteinwayModel()
    private var submarine = SubmarineWindowModel()
    private var reef = GreatBarrierReefModel()

    private(set) var loungeR: SpaceshipLoungeRenderer?
    private(set) var cabinR: SnowboundCabinRenderer?
    private(set) var bedroomR: BedroomDawnRenderer?
    private(set) var gardenR: ButterflyRenderer?
    private(set) var steinwayR: SteinwayRenderer?
    private(set) var submarineR: SubmarineWindowRenderer?
    private(set) var reefR: GreatBarrierReefRenderer?

    private(set) var loungeFrame: LoungeFrame?
    private(set) var cabinFrame: CabinFrame?
    private(set) var bedroomFrame: BedroomFrame?
    private(set) var gardenFrame: GardenFrame?
    private(set) var steinwayFrame: SteinwayFrame?
    private(set) var submarineFrame: SubFrame?
    private(set) var reefFrame: ReefFrame?

    init(_ world: PartBWorld, values extra: [String: ParamValue] = [:], quality: QualityLevel = .high, gentle: Bool = false,
         width: Int = 640, height: Int = 360) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        self.world = world
        self.quality = quality
        self.gentle = gentle
        size = CGSize(width: width, height: height)
        var values = world.values
        for (k, v) in extra { values[k] = v }
        let state = ThemeState(values: values)
        let d = SceneDirector(themeID: world.themeID, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        d.clock = { start }
        if let s = world.sky { d.sky.reset(settings: s) }
        director = d
        params = d.parameters
        switch world {
        case .lounge: loungeR = SpaceshipLoungeRenderer(device: device)
        case .cabin:
            cabinR = SnowboundCabinRenderer(device: device)
            _ = cabinR?.awaitField()
        case .bedroom:
            bedroomR = BedroomDawnRenderer(device: device)
            _ = bedroomR?.awaitField()
        case .garden: gardenR = ButterflyRenderer(device: device)
        case .steinway: steinwayR = SteinwayRenderer(device: device)
        case .submarine: submarineR = SubmarineWindowRenderer(device: device)
        case .reef: reefR = GreatBarrierReefRenderer(device: device)
        }
        XCTAssertNotNil(renderer, "\(world): a renderer")
    }

    var renderer: ThemeRenderer? {
        switch world {
        case .lounge: return loungeR
        case .cabin: return cabinR
        case .bedroom: return bedroomR
        case .garden: return gardenR
        case .steinway: return steinwayR
        case .submarine: return submarineR
        case .reef: return reefR
        }
    }

    /// Excitement as a test hands it to the world for one step.
    nonisolated static func excitement(energy: Float = 0.4, tension: Float = 0, drop: Float = 0, moment: BigMoment? = nil,
                                       surprise: WorldSurprise? = nil, reduceMotion: Bool = false,
                                       gentle: Bool = false) -> ExcitementFrame {
        var e = ExcitementFrame()
        e.energy = energy
        e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
        e.tension = tension
        e.drop = drop
        e.moment = moment
        e.surprise = surprise
        e.reduceMotion = reduceMotion
        e.gentle = gentle
        return e
    }

    nonisolated static func chord(_ strength: Float = 1, drop: Bool = false, low: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: low, isDrop: drop)
    }

    /// One step of 1/60 s (or `dt`): the sky, then the world with `e` and `events`, then its renderer.
    func step(_ e: ExcitementFrame, events: [PerformanceEvent] = [], dt: Double = 1.0 / 60) {
        frameIndex += 1
        elapsed += dt
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let now = elapsed
        director.clock = { start.addingTimeInterval(now) }
        if world.sky != nil { _ = director.step(dt: dt, t: elapsed, quality: quality) }
        let sky = director.lastSky
        let roles = RoleValues(), inputs = InputFrame()
        switch world {
        case .lounge:
            if let sky { lounge.setSky(sky) }
            lounge.setExcitement(e)
            for ev in events { lounge.handle(ev) }
            let f = lounge.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            loungeR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            loungeFrame = f
        case .cabin:
            if let sky { cabin.setSky(sky) }
            cabin.setExcitement(e)
            for ev in events { cabin.handle(ev) }
            let f = cabin.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            cabinR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            cabinFrame = f
        case .bedroom:
            if let sky { bedroom.setSky(sky) }
            bedroom.setExcitement(e)
            for ev in events { bedroom.handle(ev) }
            let f = bedroom.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            bedroomR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            bedroomFrame = f
        case .garden:
            garden.setExcitement(e)
            for ev in events { garden.handle(ev) }
            let f = garden.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            gardenR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            gardenFrame = f
        case .steinway:
            steinway.setExcitement(e)
            for ev in events { steinway.handle(ev) }
            let f = steinway.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            steinwayR?.update(f, quality: quality, gentle: gentle, dt: dt)
            steinwayFrame = f
        case .submarine:
            if let sky { submarine.setSky(sky) }
            submarine.setExcitement(e)
            for ev in events { submarine.handle(ev) }
            let f = submarine.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            submarineR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            submarineFrame = f
        case .reef:
            if let sky { reef.setSky(sky) }
            reef.setExcitement(e)
            for ev in events { reef.handle(ev) }
            let f = reef.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
            reefR?.update(f, params: params, quality: quality, gentle: gentle, dt: dt, size: size)
            reefFrame = f
        }
    }

    /// Steps `count` frames with the same Excitement (its moment and surprise, if any, only on the first).
    func run(_ count: Int, _ e: ExcitementFrame) {
        guard count > 0 else { return }
        step(e)
        var calm = e
        calm.moment = nil
        calm.surprise = nil
        for _ in 1..<count { step(calm) }
    }

    /// What the world shows of Excitement now: how gathered it is (tension's look), how strongly its release or its
    /// moment plays, and the surprises playing.
    var readout: (gather: Float, release: Float, surprises: [PlayingSurprise]) {
        switch world {
        case .lounge:
            guard let f = loungeFrame else { return (0, 0, []) }
            return (f.charge, f.jump, f.surprises)
        case .cabin:
            guard let f = cabinFrame else { return (0, 0, []) }
            return (f.gather, max(f.roar, f.gust), f.surprises)
        case .bedroom:
            guard let f = bedroomFrame else { return (0, 0, []) }
            return (f.gather, f.flood, f.surprises)
        case .garden:
            guard let f = gardenFrame else { return (0, 0, []) }
            return (f.gather, f.swarm, f.surprises)
        case .steinway:
            guard let f = steinwayFrame else { return (0, 0, []) }
            return (f.gather, f.spot, f.surprises)
        case .submarine:
            guard let f = submarineFrame else { return (0, 0, []) }
            return (f.dark, f.whale?.presence ?? 0, f.surprises)
        case .reef:
            guard let f = reefFrame else { return (0, 0, []) }
            return (f.gather, max(f.burst, f.burstHaze), f.surprises)
        }
    }

    /// The moment's light as drawn after the world's limiter, and what it asked for (0 for a world whose moment is no
    /// light: the whale).
    var momentLight: (drawn: Float, asked: Float) {
        switch world {
        case .lounge: return (loungeR?.arrivalOut ?? 0, loungeR?.arrivalRequest ?? 0)
        case .cabin: return (cabinR?.roarOut ?? 0, cabinR?.roarRequest ?? 0)
        case .bedroom: return (bedroomR?.floodOut ?? 0, bedroomR?.floodRequest ?? 0)
        case .garden: return (gardenR?.bloomOut ?? 0, gardenR?.bloomRequest ?? 0)
        case .steinway: return (steinwayR?.spotOut ?? 0, steinwayR?.spotRequest ?? 0)
        case .submarine: return (0, 0)
        case .reef: return (reefR?.burstOut ?? 0, reefR?.burstRequest ?? 0)
        }
    }

    var flashes: (recent: Int, total: Int) {
        switch world {
        case .lounge: return (loungeR?.flashesInLastSecond ?? 0, loungeR?.flashTotal ?? 0)
        case .cabin: return (cabinR?.flashesInLastSecond ?? 0, cabinR?.flashTotal ?? 0)
        case .bedroom: return (bedroomR?.flashesInLastSecond ?? 0, bedroomR?.flashTotal ?? 0)
        case .garden: return (gardenR?.flashesInLastSecond ?? 0, gardenR?.flashTotal ?? 0)
        case .steinway: return (steinwayR?.flashesInLastSecond ?? 0, steinwayR?.flashTotal ?? 0)
        case .submarine: return (submarineR?.flashesInLastSecond ?? 0, submarineR?.flashTotal ?? 0)
        case .reef: return (reefR?.flashesInLastSecond ?? 0, reefR?.flashTotal ?? 0)
        }
    }

    func capture(_ preview: PreviewRenderer) -> CGImage? {
        guard let r = renderer else { return nil }
        return preview.capture(r, exposureScale: director.exposureScale)
    }

    /// The share of pixels whose luminance differs by more than 4% between two images.
    nonisolated static func changed(_ a: CGImage, _ b: CGImage) -> Double {
        let la = FramePatch.luminance(a), lb = FramePatch.luminance(b)
        guard la.count == lb.count, !la.isEmpty else { return 0 }
        var n = 0
        for i in 0..<la.count where abs(la[i] - lb[i]) > 0.04 { n += 1 }
        return Double(n) / Double(la.count)
    }
}

@MainActor
final class ExcitementPartBTests: XCTestCase {
    typealias Rig = PartBRig

    /// Two rigs stepped alike for `frames` frames, the second given `e` on frame `at` (and calm otherwise); returns their
    /// images.
    private func pair(_ world: PartBWorld, frames: Int, at: Int, _ e: ExcitementFrame, energy: Float = 0.4,
                      tension: Float = 0) throws -> (calm: CGImage, changed: CGImage, rig: Rig) {
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let calm = try Rig(world)
        let moved = try Rig(world)
        let still = Rig.excitement(energy: energy, tension: tension)
        for i in 1...frames {
            calm.step(still)
            moved.step(i == at ? e : still)
        }
        let a = try XCTUnwrap(calm.capture(preview)), b = try XCTUnwrap(moved.capture(preview))
        return (a, b, moved)
    }

    // MARK: - Every world

    func testEveryWorldListsItsSurprises() {
        for w in PartBWorld.allCases {
            let listed = w.surpriseSeconds.count
            XCTAssertEqual(listed, w.surpriseCount, "\(w)")
            XCTAssertEqual(w.surpriseNames.count, w.surpriseCount, "\(w)")
            XCTAssertTrue((2...5).contains(w.surpriseCount), "\(w): spec §5.3 lists 3–5 (the garden and the stage, 2)")
        }
    }

    /// Plan Task 7 (as Task 6): the preview renderer's frame differs by at least 2% of its pixels 0.5 s after a moment.
    func testMomentChangesTheFrame() throws {
        for w in PartBWorld.allCases {
            let shots = try pair(w, frames: 90, at: 60, Rig.excitement(moment: Rig.chord(1)))
            let share = Rig.changed(shots.calm, shots.changed)
            XCTAssertGreaterThan(share, 0.02, "\(w): the moment changes \(share) of the frame")
            let release = shots.rig.readout.release
            XCTAssertGreaterThan(release, 0.3, "\(w): the moment plays")
        }
    }

    /// Each surprise, played in turn, changes the frame, shows in the world's own frame while it plays, and is gone soon
    /// after its time.
    func testSurprisesAllPlay() throws {
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        for w in PartBWorld.allCases {
            for i in 0..<w.surpriseCount {
                let seconds = w.surpriseSeconds[i]
                let mid = 10 + Int(seconds * 0.45 * 60)
                let calm = try Rig(w, width: 320, height: 180)
                let rig = try Rig(w, width: 320, height: 180)
                let still = Rig.excitement()
                for k in 1...mid {
                    calm.step(still)
                    rig.step(k == 10 ? Rig.excitement(surprise: WorldSurprise(index: i, seed: 77)) : still)
                }
                let playing = rig.readout.surprises.map(\.index)
                XCTAssertEqual(playing, [i], "\(w) surprise \(i) plays")
                let a = try XCTUnwrap(calm.capture(preview)), b = try XCTUnwrap(rig.capture(preview))
                let difference = PreviewRenderer.difference(a, b)
                XCTAssertGreaterThan(difference, 0, "\(w) surprise \(i) changes the frame")
                let rest = Int(seconds * 0.55 * 60) + 30
                for _ in 0..<rest { rig.step(still) }
                let after = rig.readout.surprises.count
                XCTAssertEqual(after, 0, "\(w) surprise \(i) ends within its time")
            }
        }
    }

    /// Plan Task 7 (as Task 6): tension 0.8 shows as the world gathering; then a drop gives the release, and the
    /// gathering lets go.
    func testBuildThenDrop() throws {
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        for w in PartBWorld.allCases {
            let calm = try Rig(w, width: 320, height: 180)
            let rig = try Rig(w, width: 320, height: 180)
            calm.run(150, Rig.excitement(energy: 0.5))
            rig.run(150, Rig.excitement(energy: 0.5, tension: 0.8))
            let gathered = rig.readout.gather
            XCTAssertGreaterThan(gathered, 0.7, "\(w): the world gathers with tension")
            let a = try XCTUnwrap(calm.capture(preview)), b = try XCTUnwrap(rig.capture(preview))
            let shown = PreviewRenderer.difference(a, b)
            XCTAssertGreaterThan(shown, 0, "\(w): the gathering shows")
            // The drop: tension snaps to 0, the release envelope falls from 1 over 2.5 s.
            for k in 0..<60 {
                let drop: Float = max(0, 1 - Float(k) / 150)
                rig.step(Rig.excitement(energy: 0.5, tension: 0, drop: drop, moment: k == 0 ? Rig.chord(1, drop: true) : nil))
            }
            let release = rig.readout.release
            let after = rig.readout.gather
            XCTAssertGreaterThan(release, 0.3, "\(w): the release plays")
            XCTAssertLessThan(after, 0.1, "\(w): the gathering lets go")
        }
    }

    // MARK: - Flashes, gentle visuals, Reduce Motion

    /// Review focus 1: a hammered minute (a big moment every quarter second, a drop every two, Energy and tension
    /// full) never flashes more than three times a second, and the moments' light is never drawn brighter than the
    /// limiter let it be.
    func testHammeredMinuteStaysInsideTheFlashLimiter() throws {
        for w in PartBWorld.allCases {
            let rig = try Rig(w, width: 160, height: 90)
            var worst = 0
            var over: Float = 0
            for i in 1...3600 {
                let m: BigMoment? = i % 15 == 0 ? Rig.chord(1, drop: i % 120 == 0) : nil
                let drop: Float = Float(max(0, 150 - i % 120)) / 150
                rig.step(Rig.excitement(energy: 1, tension: 1, drop: drop, moment: m))
                worst = max(worst, rig.flashes.recent)
                let light = rig.momentLight
                over = max(over, light.drawn - light.asked)
            }
            XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond, "\(w)")
            XCTAssertLessThanOrEqual(over, 1e-4, "\(w): drawn within what the limiter passed")
        }
    }

    /// Gentle visuals: the moments are glows, never a flash (none counted after the world has settled).
    func testGentleVisualsNeverFlash() throws {
        for w in PartBWorld.allCases {
            let rig = try Rig(w, gentle: true, width: 160, height: 90)
            rig.run(60, Rig.excitement(energy: 1, gentle: true))
            let settled = rig.flashes.total
            for i in 1...600 {
                let m: BigMoment? = i % 45 == 0 ? Rig.chord(1, drop: i == 300) : nil
                rig.step(Rig.excitement(energy: 1, tension: i < 300 ? 1 : 0, moment: m, gentle: true))
            }
            let total = rig.flashes.total
            XCTAssertEqual(total, settled, "\(w): gentle visuals glow, never flash")
        }
    }

    /// Reduce Motion keeps the lounge's warp adrift: no stretch, however hard the jump; without it the stars stretch.
    func testReduceMotionKeepsTheWarpAdrift() throws {
        var fastest: Float = 0, reducedFastest: Float = 0
        let rig = try Rig(.lounge, width: 160, height: 90)
        let reduced = try Rig(.lounge, width: 160, height: 90)
        for i in 1...120 {
            let m: BigMoment? = i == 20 ? Rig.chord(1) : nil
            rig.step(Rig.excitement(energy: 1, moment: m))
            reduced.step(Rig.excitement(energy: 1, moment: m, reduceMotion: true))
            fastest = max(fastest, rig.loungeR?.warpSpeedDrawn ?? 0)
            reducedFastest = max(reducedFastest, reduced.loungeR?.warpSpeedDrawn ?? 0)
        }
        XCTAssertGreaterThan(fastest, 1.5, "the stars stretch")
        XCTAssertLessThanOrEqual(reducedFastest, 0.11, "Reduce Motion: the warp stays adrift")
    }

    /// Held time (dt 0) holds everything Excitement plays: the frame doesn't move.
    func testHeldTimeHoldsTheMoment() throws {
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        for w in PartBWorld.allCases {
            let rig = try Rig(w, width: 320, height: 180)
            rig.run(30, Rig.excitement(moment: Rig.chord(1), surprise: WorldSurprise(index: 0, seed: 5)))
            rig.step(Rig.excitement(), dt: 0)
            let first = try XCTUnwrap(rig.capture(preview))
            for _ in 0..<30 { rig.step(Rig.excitement(), dt: 0) }
            let held = try XCTUnwrap(rig.capture(preview))
            let moved = PreviewRenderer.difference(first, held)
            XCTAssertLessThan(moved, 1e-4, "\(w): a held moment stands still (\(moved))")
        }
    }

    // MARK: - Pools and buffers

    /// No buffers made per frame: the worlds with rings keep their three, however much plays at once.
    func testNoBuffersMadePerFrame() throws {
        for w in [PartBWorld.submarine, .reef, .bedroom] {
            let rig = try Rig(w, width: 160, height: 90)
            for i in 1...600 {
                let s: WorldSurprise? = i % 100 == 1 ? WorldSurprise(index: (i / 100) % w.surpriseCount, seed: UInt64(i)) : nil
                rig.step(Rig.excitement(energy: 1, tension: 0.5, moment: i % 30 == 0 ? Rig.chord(1) : nil, surprise: s))
            }
            switch w {
            case .submarine:
                XCTAssertEqual(rig.submarineR?.bufferAllocations, 3)
                let sprites = rig.submarineR?.spriteList.count ?? 0
                XCTAssertLessThanOrEqual(sprites, SubmarineWindowRenderer.spriteCapacity)
            case .reef:
                XCTAssertEqual(rig.reefR?.bufferAllocations, 3)
                let beads = rig.reefFrame?.spawn.beads.count ?? 0
                XCTAssertLessThanOrEqual(beads, CoralSpawning.cap(.high))
                let visitors = rig.reefR?.visitorCount ?? 0
                XCTAssertLessThanOrEqual(visitors, GreatBarrierReefRenderer.visitorCapacity)
            default:
                let made = rig.bedroomR?.bufferAllocations ?? 0
                XCTAssertLessThanOrEqual(made, 3)
            }
        }
    }

    /// The shaders still build with their new rows, and the rows' counts match the MSL structs' sizes.
    func testShadersCompileWithTheirRows() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let sources: [(String, String)] = [
            ("lounge", SpaceshipLoungeShaders.source), ("cabin", SnowboundCabinShaders.source),
            ("bedroom", BedroomDawnShaders.source), ("garden", ButterflyShaders.source),
            ("steinway", MidnightSteinwayShaders.source), ("submarine", SubmarineWindowShaders.source),
            ("reef", GreatBarrierReefShaders.source),
        ]
        for (name, source) in sources {
            XCTAssertNoThrow(try device.makeLibrary(source: source, options: nil), name)
        }
        XCTAssertEqual(SubmarineWindowRenderer.blipBase + 24, SubmarineWindowRenderer.uniformCount)
        let lounge = try XCTUnwrap(SpaceshipLoungeRenderer(device: device))
        XCTAssertEqual(lounge.uniforms.count, SpaceshipLoungeRenderer.uniformCount)
        let steinway = try XCTUnwrap(SteinwayRenderer(device: device))
        XCTAssertEqual(steinway.uniforms.count, SteinwayRenderer.uniformCount)
        let rows = SteinwayRenderer.uniformCount * 16
        XCTAssertLessThanOrEqual(rows, 4096, "one setFragmentBytes call")
    }
}
