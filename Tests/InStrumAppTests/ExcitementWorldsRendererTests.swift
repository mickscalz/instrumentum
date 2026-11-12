import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Excitement drawn in Moonlit Lake, Golden Hour Beach, Coast Road and Aurora Fjord (Fire & Neon spec §5.5, §12, §13; plan
/// Task 6): a big moment changes the frame, every surprise draws and ends within its time, the world gathers and then
/// releases, a hammered minute stays inside the flash limiter (and under gentle visuals never flashes), and no buffers
/// are made per frame.
@MainActor
final class ExcitementWorldsRendererTests: XCTestCase {
    // MARK: - Helpers

    /// A frozen night over Melbourne on the previews' fixed date (each world holds its own light: the beach golden
    /// hour, the road blue hour, the fjord deep night; the lake follows this sky, with the moon up in its view).
    nonisolated static func sky(hour: Double = 22, phase: Double = 0.55) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    nonisolated static func chord(_ strength: Float, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: false, isDrop: drop)
    }

    /// The moon well up and lit (for the owl, which crosses it only then).
    nonisolated static func moonUp(_ s: inout SkyState) {
        s.moon.altitude = max(s.moon.altitude, 25)
        s.moonLit = max(s.moonLit, 0.8)
    }

    /// What each frame hands the world, and how it is drawn.
    struct Plan {
        var energy: Float = 0.3
        var tension: (Int) -> Float = { _ in 0 }
        var moments: [Int: BigMoment] = [:]
        var surprises: [Int: WorldSurprise] = [:]
        var gentle = false
        var reduceMotion = false
        var values: [String: ParamValue] = [:]
        var quality = QualityLevel.high
        var width = 640, height = 360
        var capture = true
        var skyEdit: ((inout SkyState) -> Void)?
    }

    struct Shot<F, R> {
        var image: CGImage?
        var renderer: R
        var frame: F
        var params: ParameterSet
    }

    /// Steps a world at 60 fps for `seconds` and renders the last frame. The director runs the Living Sky for it; the
    /// world itself is stepped here so the test chooses its Excitement (as the volcano's tests do): `energy` and the
    /// tension throughout, a moment on its frame, a surprise on its frame. `each` sees every frame after the renderer's
    /// update.
    static func shoot<M: ThemeModel & SkyAware & ExcitementAware, R: ThemeRenderer>(
        _ type: M.Type, seconds: Double, sky: SkySettings, plan: Plan, make: (MTLDevice) -> R?,
        update: (R, M.Frame, ParameterSet, QualityLevel, Bool, CGSize) -> Void,
        each: ((Int, R, M.Frame) -> Void)? = nil) throws -> Shot<M.Frame, R> {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(make(device))
        let d = SceneDirector(themeID: M.id, state: ThemeState(values: plan.values), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        var model = M()
        let size = CGSize(width: plan.width, height: plan.height)
        let n = max(1, Int((seconds * 60).rounded()))
        var last: M.Frame?
        for i in 1...n {
            let t = Double(i) / 60
            elapsed = t
            _ = d.step(dt: 1.0 / 60, t: t, quality: plan.quality)
            if var s = d.lastSky {
                plan.skyEdit?(&s)
                model.setSky(s)
            }
            var e = ExcitementFrame()
            e.energy = plan.energy
            e.visualEnergy = plan.reduceMotion ? min(plan.energy, 0.5) : plan.energy
            e.tension = plan.tension(i)
            e.reduceMotion = plan.reduceMotion
            e.gentle = plan.gentle
            if let m = plan.moments[i] {
                e.moment = m
                e.drop = m.isDrop ? 1 : 0
            }
            e.surprise = plan.surprises[i]
            model.setExcitement(e)
            let f = model.step(dt: 1.0 / 60, params: d.parameters, roles: RoleValues(), inputs: InputFrame(), quality: plan.quality)
            update(r, f, d.parameters, plan.quality, plan.gentle, size)
            each?(i, r, f)
            last = f
        }
        let frame = try XCTUnwrap(last)
        var image: CGImage?
        if plan.capture {
            let preview = try XCTUnwrap(PreviewRenderer(width: plan.width, height: plan.height))
            image = preview.capture(r)
        }
        return Shot(image: image, renderer: r, frame: frame, params: d.parameters)
    }

    static func lake(_ seconds: Double, _ plan: Plan = Plan(), sky: SkySettings = ExcitementWorldsRendererTests.sky(),
                     each: ((Int, MoonlitLakeRenderer, LakeFrame) -> Void)? = nil) throws -> Shot<LakeFrame, MoonlitLakeRenderer> {
        try shoot(MoonlitLakeModel.self, seconds: seconds, sky: sky, plan: plan, make: { MoonlitLakeRenderer(device: $0) },
                  update: { r, f, p, q, g, size in r.update(f, params: p, quality: q, gentle: g, dt: 1.0 / 60, size: size) }, each: each)
    }

    static func beach(_ seconds: Double, _ plan: Plan = Plan(), sky: SkySettings = ExcitementWorldsRendererTests.sky(hour: 13),
                      each: ((Int, GoldenHourBeachRenderer, BeachFrame) -> Void)? = nil) throws -> Shot<BeachFrame, GoldenHourBeachRenderer> {
        try shoot(GoldenHourBeachModel.self, seconds: seconds, sky: sky, plan: plan, make: { GoldenHourBeachRenderer(device: $0) },
                  update: { r, f, p, q, g, size in r.update(f, params: p, quality: q, gentle: g, dt: 1.0 / 60, size: size) }, each: each)
    }

    static func road(_ seconds: Double, _ plan: Plan = Plan(), sky: SkySettings = ExcitementWorldsRendererTests.sky(hour: 13),
                     each: ((Int, CoastRoadRenderer, RoadFrame) -> Void)? = nil) throws -> Shot<RoadFrame, CoastRoadRenderer> {
        try shoot(CoastRoadModel.self, seconds: seconds, sky: sky, plan: plan, make: { CoastRoadRenderer(device: $0) },
                  update: { r, f, p, q, g, size in r.update(f, params: p, quality: q, gentle: g, dt: 1.0 / 60, size: size) }, each: each)
    }

    static func fjord(_ seconds: Double, _ plan: Plan = Plan(), sky: SkySettings = ExcitementWorldsRendererTests.sky(phase: 0.1),
                      each: ((Int, AuroraFjordRenderer, FjordFrame) -> Void)? = nil) throws -> Shot<FjordFrame, AuroraFjordRenderer> {
        try shoot(AuroraFjordModel.self, seconds: seconds, sky: sky, plan: plan, make: { AuroraFjordRenderer(device: $0) },
                  update: { r, f, p, q, g, size in r.update(f, params: p, quality: q, gentle: g, dt: 1.0 / 60, size: size) }, each: each)
    }

    /// The share of pixels whose luminance differs by more than 2% of full scale between two frames (a moment's change
    /// visible to the eye, dark night scenes included).
    static func changed(_ a: CGImage, _ b: CGImage) -> Double {
        let la = FramePatch.luminance(a), lb = FramePatch.luminance(b)
        guard la.count == lb.count, !la.isEmpty else { return 0 }
        var n = 0
        for i in 0..<la.count where abs(la[i] - lb[i]) > 0.02 { n += 1 }
        return Double(n) / Double(la.count)
    }

    /// Moments every quarter second, a drop every two, Energy and tension full.
    static func hammer() -> [Int: BigMoment] {
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 15, to: 3600, by: 15) { moments[i] = chord(1, drop: i % 120 == 0) }
        return moments
    }

    // MARK: - testMomentChangesTheFrame: 0.5 s after a moment, at least 2% of the pixels differ

    func testLakeMomentChangesTheFrame() throws {
        let calm = try Self.lake(2)
        let burst = try Self.lake(2, Plan(moments: [90: Self.chord(1)]))
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(burst.image)
        XCTAssertGreaterThan(Self.changed(a, b), 0.02, "the meteor burst, mirrored in the lake")
        XCTAssertGreaterThanOrEqual(burst.renderer.worldMeteorsShown, 3)
        XCTAssertEqual(calm.renderer.worldMeteorsShown, 0)
    }

    func testBeachMomentChangesTheFrame() throws {
        let calm = try Self.beach(2)
        let fireworks = try Self.beach(2, Plan(moments: [90: Self.chord(1)]))
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(fireworks.image)
        XCTAssertGreaterThan(Self.changed(a, b), 0.02, "fireworks down the beach")
        XCTAssertGreaterThan(fireworks.renderer.starCount, 20)
        XCTAssertGreaterThan(fireworks.renderer.burstsReflected, 0, "mirrored on the sea and the wet sand")
        XCTAssertEqual(calm.renderer.sparkCount, 0)
    }

    func testRoadMomentChangesTheFrame() throws {
        let calm = try Self.road(2)
        let sweep = try Self.road(2, Plan(moments: [90: Self.chord(1)]))
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(sweep.image)
        XCTAssertGreaterThan(Self.changed(a, b), 0.02, "the lighthouse's beam sweeping round")
        XCTAssertGreaterThan(sweep.renderer.beamOut, 0.5)
        XCTAssertLessThan(calm.renderer.beamOut, 0.3)
    }

    func testFjordMomentChangesTheFrame() throws {
        let calm = try Self.fjord(2)
        let surge = try Self.fjord(2, Plan(moments: [90: Self.chord(1)]))
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(surge.image)
        XCTAssertGreaterThan(Self.changed(a, b), 0.02, "the aurora surging")
        XCTAssertGreaterThan(surge.renderer.surgeOut, 0.8)
        XCTAssertEqual(calm.renderer.surgeOut, 0)
        let later = try Self.fjord(3, Plan(moments: [90: Self.chord(1)]))
        XCTAssertGreaterThan(later.renderer.coronaOut, 0.5, "and its corona overhead")
    }

    // MARK: - testSurprisesAllPlay: each draws, and ends within its time

    func testLakeSurprisesAllPlay() throws {
        for kind in LakeSurprise.Kind.allCases {
            let seconds = Double(LakeSurprise.duration(kind)) + 0.6
            var drew = false
            var plan = Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 11)], width: 160, height: 90, capture: false)
            if kind == .owl { plan.skyEdit = Self.moonUp }
            let shot = try Self.lake(seconds, plan) { i, r, f in
                guard i > 10, i < 10 + 120 else { return }
                switch kind {
                case .fireball: if r.worldMeteorsShown > 0 { drew = true }
                case .owl: if r.owlDrawn { drew = true }
                case .fish: if !f.rings.isEmpty, r.rippleCount > 0 { drew = true }
                }
            }
            XCTAssertTrue(drew, "\(kind)")
            XCTAssertTrue(shot.frame.surprises.isEmpty, "\(kind) ends within its time")
            XCTAssertFalse(shot.renderer.owlDrawn)
        }
    }

    func testBeachSurprisesAllPlay() throws {
        let sunset: (inout SkyState) -> Void = { $0.sun.altitude = -0.6 }   // the sun's last sliver on the horizon
        for kind in BeachSurprise.Kind.allCases {
            let seconds = Double(BeachSurprise.duration(kind)) + 0.6
            var drew = false
            var plan = Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 5)], width: 160, height: 90, capture: false)
            if kind == .greenFlash { plan.skyEdit = sunset }
            let shot = try Self.beach(seconds, plan) { i, r, _ in
                guard i > 10 else { return }
                switch kind {
                case .dolphins: if r.dolphinsDrawn > 0 { drew = true }
                case .kite: if r.kiteDrawn { drew = true }
                case .greenFlash: if r.greenFlashOut > 0.5 { drew = true }
                }
            }
            XCTAssertTrue(drew, "\(kind)")
            XCTAssertTrue(shot.frame.surprises.isEmpty, "\(kind) ends within its time")
            XCTAssertEqual(shot.renderer.dolphinsDrawn, 0)
            XCTAssertFalse(shot.renderer.kiteDrawn)
            XCTAssertEqual(shot.renderer.greenFlashOut, 0)
        }
    }

    func testRoadSurprisesAllPlay() throws {
        for kind in RoadSurprise.Kind.allCases {
            let seconds = Double(RoadSurprise.duration(kind)) + 0.6
            var drew = false
            let shot = try Self.road(seconds, Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 9)], width: 160, height: 90,
                                                   capture: false)) { i, r, f in
                guard i > 10 else { return }
                switch kind {
                case .fox: if r.foxDrawn { drew = true }
                case .train: if r.trainOut > 0.3 { drew = true }
                case .shootingStar:
                    let listed = f.surprises.contains { $0.kind == .shootingStar }
                    // As bright as the brightest stars (−2.2): its head a point, its brightness in its streak.
                    if listed, f.sky.meteors.contains(where: { $0.magnitude <= -2.1 }) { drew = true }
                }
            }
            XCTAssertTrue(drew, "\(kind)")
            XCTAssertTrue(shot.frame.surprises.isEmpty, "\(kind) ends within its time")
            XCTAssertFalse(shot.renderer.foxDrawn)
            XCTAssertEqual(shot.renderer.trainOut, 0)
        }
    }

    func testFjordSurprisesAllPlay() throws {
        for kind in FjordSurprise.Kind.allCases {
            let seconds = Double(FjordSurprise.duration(kind)) + 0.6
            var drew = false
            let shot = try Self.fjord(seconds, Plan(surprises: [10: WorldSurprise(index: kind.rawValue, seed: 21)], width: 160, height: 90,
                                                    capture: false)) { i, r, f in
                guard i > 10 else { return }
                switch kind {
                case .fireball: if f.sky.meteors.contains(where: { $0.magnitude <= -5 }) { drew = true }
                case .orca: if r.orcaDrawn { drew = true }
                case .satelliteFlare: if (f.sky.satellites.first?.flare ?? 0) > 0.9 { drew = true }
                }
            }
            XCTAssertTrue(drew, "\(kind)")
            XCTAssertTrue(shot.frame.surprises.isEmpty, "\(kind) ends within its time")
            XCTAssertFalse(shot.renderer.orcaDrawn)
        }
    }

    // MARK: - testBuildThenDrop: tension 0.8 gathers the world; a drop releases it

    func testLakeBuildThenDrop() throws {
        var gathered: Float = 0, calm: Float = 0, lifted: Float = 9
        _ = try Self.lake(5, Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: Self.chord(1, drop: true)], width: 160, height: 90,
                                  capture: false)) { i, r, _ in
            if i == 2 { calm = r.mistOut }
            if i == 178 { gathered = r.mistOut }
            if i > 240 { lifted = min(lifted, r.mistOut) }
        }
        XCTAssertGreaterThan(gathered, calm + 0.1, "the mist gathers")
        XCTAssertLessThan(lifted, 0.3 * gathered, "then lifts all at once")
    }

    func testBeachBuildThenDrop() throws {
        var built: Float = 0, calm: Float = 0, big: Float = 0
        _ = try Self.beach(16, Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: Self.chord(1, drop: true)], width: 160, height: 90,
                                    capture: false)) { i, _, f in
            if i == 2 { calm = f.swellScale }
            if i == 178 { built = f.swellScale }
            if i > 180 {
                let rolling = f.upcoming.map(\.strength).max() ?? 0
                let broke = f.recent.filter { $0.breakTime > f.swellTime - 1 }.map(\.strength).max() ?? 0
                big = max(big, rolling, broke)
            }
        }
        XCTAssertGreaterThan(built, 1.3 * calm, "the swell builds")
        XCTAssertGreaterThanOrEqual(big, 0.95, "then a big wave")
    }

    func testRoadBuildThenDrop() throws {
        var gathering: Float = 0, opened: Float = 0
        _ = try Self.road(5, Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: Self.chord(1, drop: true)], width: 160, height: 90,
                                  capture: false)) { i, r, _ in
            if i == 178 { gathering = r.headlightsOut }
            if i == 280 { opened = r.openOut }
        }
        XCTAssertGreaterThan(gathering, 0.5, "headlights gather round the bend")
        XCTAssertGreaterThan(opened, 0.9, "then the road opens onto the sea")
    }

    func testFjordBuildThenDrop() throws {
        var gathered: Float = 0, surged: Float = 0, corona: Float = 0
        _ = try Self.fjord(5, Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: Self.chord(0.5, drop: true)], width: 160, height: 90,
                                   capture: false)) { i, r, _ in
            if i == 178 { gathered = r.gatherOut }
            if i == 240 { surged = r.surgeOut }
            corona = max(corona, r.coronaOut)
        }
        XCTAssertGreaterThan(gathered, 0.5, "the curtains gather")
        XCTAssertGreaterThan(surged, 0.9, "then the surge, in full at a drop")
        XCTAssertGreaterThan(corona, 0.5)
    }

    // MARK: - Flashes under a hammering, gentle visuals, buffers

    /// Review focus 1: a hammered minute never flashes more than three times a second; gentle visuals never flash.
    /// `flashes`: the plain run must flash at least once (the road's lantern facing you), so the test is not vacuous.
    private func assertHammer(_ name: String, _ run: (Plan, @escaping (Int, Int, Int) -> Void) throws -> Void, flashes: Bool) throws {
        var worst = 0, total = 0
        try run(Plan(energy: 1, tension: { _ in 1 }, moments: Self.hammer(), width: 160, height: 90, capture: false)) { _, recent, sum in
            worst = max(worst, recent)
            total = sum
        }
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond, name)
        XCTAssertLessThanOrEqual(total, 60 * FlashLimiter.maxFlashesPerSecond, name)
        if flashes { XCTAssertGreaterThan(total, 0, "\(name): it did flash") }
        var gentleTotal = 0
        var gentle = Plan(energy: 1, tension: { _ in 1 }, moments: Self.hammer(), width: 160, height: 90, capture: false)
        gentle.gentle = true
        try run(gentle) { _, _, sum in gentleTotal = sum }
        XCTAssertEqual(gentleTotal, 0, "\(name): gentle visuals glow, never flash")
    }

    func testLakeHammeredMinuteStaysInsideTheFlashLimiter() throws {
        try assertHammer("lake", { plan, report in
            _ = try Self.lake(plan.gentle ? 20 : 60, plan) { i, r, _ in report(i, r.flashesInLastSecond, r.flashTotal) }
        }, flashes: false)
    }

    func testBeachHammeredMinuteStaysInsideTheFlashLimiter() throws {
        var allocations: Set<Int> = [], sparks = 0
        try assertHammer("beach", { plan, report in
            _ = try Self.beach(plan.gentle ? 20 : 60, plan) { i, r, _ in
                report(i, r.flashesInLastSecond, r.flashTotal)
                allocations.insert(r.bufferAllocations)
                sparks = max(sparks, r.sparkCount)
            }
        }, flashes: false)
        XCTAssertEqual(allocations, [3], "the ring of three, made once")
        XCTAssertLessThanOrEqual(sparks, GoldenHourBeachRenderer.sparkCapacity)
    }

    func testRoadHammeredMinuteStaysInsideTheFlashLimiter() throws {
        try assertHammer("road", { plan, report in
            _ = try Self.road(plan.gentle ? 20 : 60, plan, sky: Self.sky(hour: 22)) { i, r, _ in
                report(i, r.flashesInLastSecond, r.flashTotal)
            }
        }, flashes: true)
    }

    func testFjordHammeredMinuteStaysInsideTheFlashLimiter() throws {
        try assertHammer("fjord", { plan, report in
            _ = try Self.fjord(plan.gentle ? 20 : 60, plan) { i, r, _ in report(i, r.flashesInLastSecond, r.flashTotal) }
        }, flashes: false)
    }

    /// Gentle visuals: the lantern glimmers instead of blazing, the fireworks' streaks and the surge are dimmer, and the
    /// scene never brightens past a glow.
    func testGentleVisualsGlowInstead() throws {
        var plainFlare: Float = 0, gentleFlare: Float = 0
        _ = try Self.road(4, Plan(moments: [30: Self.chord(1)], width: 160, height: 90, capture: false), sky: Self.sky(hour: 22)) { _, r, _ in
            plainFlare = max(plainFlare, r.flareOut)
        }
        var gentle = Plan(moments: [30: Self.chord(1)], width: 160, height: 90, capture: false)
        gentle.gentle = true
        _ = try Self.road(4, gentle, sky: Self.sky(hour: 22)) { _, r, _ in gentleFlare = max(gentleFlare, r.flareOut) }
        XCTAssertGreaterThan(plainFlare, 0.9)
        XCTAssertLessThanOrEqual(gentleFlare, 0.2)
        var plainSurge: Float = 0, gentleSurge: Float = 0
        _ = try Self.fjord(2, Plan(moments: [30: Self.chord(1)], width: 160, height: 90, capture: false)) { _, r, _ in
            plainSurge = max(plainSurge, r.surgeOut)
        }
        _ = try Self.fjord(2, gentle) { _, r, _ in gentleSurge = max(gentleSurge, r.surgeOut) }
        XCTAssertLessThanOrEqual(gentleSurge, 0.55 * plainSurge)
    }

    /// Reduce Motion: Energy's dials stop at half (the lake's wind, the fjord's pace).
    func testReduceMotionCapsTheEnergy() throws {
        var calmed = Plan(energy: 1, width: 160, height: 90, capture: false)
        calmed.reduceMotion = true
        let full = try Self.fjord(8, Plan(energy: 1, width: 160, height: 90, capture: false))
        let half = try Self.fjord(8, calmed)
        XCTAssertGreaterThan(full.renderer.paceOut, half.renderer.paceOut + 0.25)
        XCTAssertLessThanOrEqual(half.frame.energy, 0.5)
        let windy = try Self.lake(8, Plan(energy: 1, width: 160, height: 90, capture: false))
        let calm = try Self.lake(8, calmed)
        XCTAssertGreaterThan(windy.frame.windOnWater, calm.frame.windOnWater + 0.1)
    }
}

/// The looks run's previews for the four worlds' Excitement (PREVIEW_DIR): mid-moment, mid-surprise, at the build and at
/// the drop, at 1280×720.
@MainActor
final class ExcitementPreviewTests: XCTestCase {
    typealias T = ExcitementWorldsRendererTests

    private func folder() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ image: CGImage?, _ name: String, to url: URL) throws {
        try PreviewRenderer.writePNG(try XCTUnwrap(image), to: url.appendingPathComponent("\(name).png"))
    }

    private func big(_ plan: T.Plan = T.Plan()) -> T.Plan {
        var p = plan
        p.width = 1280
        p.height = 720
        return p
    }

    func testWriteLakeExcitementPreviews() throws {
        let url = try folder()
        try write(try T.lake(2.2, big(T.Plan(energy: 0.6, moments: [90: T.chord(1)]))).image, "excite-lake-burst", to: url)
        try write(try T.lake(1.6, big(T.Plan(surprises: [10: WorldSurprise(index: 0, seed: 11)]))).image, "excite-lake-fireball", to: url)
        var owl = T.Plan(surprises: [10: WorldSurprise(index: 1, seed: 11)])
        owl.skyEdit = T.moonUp
        try write(try T.lake(3.6, big(owl)).image, "excite-lake-owl", to: url)
        try write(try T.lake(1.4, big(T.Plan(surprises: [10: WorldSurprise(index: 2, seed: 11)]))).image, "excite-lake-fish", to: url)
        try write(try T.lake(4.5, big(T.Plan(tension: { _ in 0.9 }))).image, "excite-lake-mist-gathered", to: url)
        try write(try T.lake(5.5, big(T.Plan(tension: { $0 < 240 ? 0.9 : 0 }, moments: [240: T.chord(1, drop: true)]))).image,
                  "excite-lake-drop", to: url)
        try write(try T.lake(6, big(T.Plan(energy: 1))).image, "excite-lake-energy", to: url)
    }

    func testWriteBeachExcitementPreviews() throws {
        let url = try folder()
        try write(try T.beach(3.0, big(T.Plan(energy: 0.6, moments: [90: T.chord(1)]))).image, "excite-beach-fireworks", to: url)
        let dusk = T.Plan(energy: 0.6, moments: [90: T.chord(1)], values: ["light.hold": .choice(SkyHold.blueHour.rawValue)])
        try write(try T.beach(3.0, big(dusk)).image, "excite-beach-fireworks-dusk", to: url)
        try write(try T.beach(6, big(T.Plan(surprises: [10: WorldSurprise(index: 0, seed: 5)]))).image, "excite-beach-dolphins", to: url)
        try write(try T.beach(9, big(T.Plan(surprises: [10: WorldSurprise(index: 1, seed: 5)]))).image, "excite-beach-kite", to: url)
        var flash = T.Plan(surprises: [10: WorldSurprise(index: 2, seed: 5)])
        flash.skyEdit = { $0.sun.altitude = -0.6 }
        try write(try T.beach(1.1, big(flash)).image, "excite-beach-green-flash", to: url)
        try write(try T.beach(6, big(T.Plan(tension: { _ in 0.9 }))).image, "excite-beach-swell", to: url)
        try write(try T.beach(9, big(T.Plan(tension: { $0 < 300 ? 0.9 : 0 }, moments: [300: T.chord(1, drop: true)]))).image,
                  "excite-beach-drop", to: url)
        try write(try T.beach(10, big(T.Plan(energy: 1))).image, "excite-beach-gulls", to: url)
    }

    func testWriteRoadExcitementPreviews() throws {
        let url = try folder()
        try write(try T.road(2.5, big(T.Plan(moments: [90: T.chord(1)]))).image, "excite-road-beam-sweep", to: url)
        try write(try T.road(3.55, big(T.Plan(moments: [90: T.chord(1)]))).image, "excite-road-beam-facing", to: url)
        try write(try T.road(3.55, big(T.Plan(moments: [90: T.chord(1)])), sky: T.sky(hour: 22)).image, "excite-road-beam-night", to: url)
        try write(try T.road(2.4, big(T.Plan(surprises: [10: WorldSurprise(index: 0, seed: 9)])), sky: T.sky(hour: 22)).image,
                  "excite-road-fox", to: url)
        try write(try T.road(10, big(T.Plan(surprises: [10: WorldSurprise(index: 1, seed: 9)]))).image, "excite-road-train", to: url)
        try write(try T.road(0.6, big(T.Plan(surprises: [10: WorldSurprise(index: 2, seed: 9)]))).image, "excite-road-shooting-star", to: url)
        try write(try T.road(4.5, big(T.Plan(tension: { _ in 0.9 })), sky: T.sky(hour: 22)).image, "excite-road-headlights", to: url)
        try write(try T.road(6, big(T.Plan(tension: { $0 < 240 ? 0.9 : 0 }, moments: [240: T.chord(1, drop: true)]))).image,
                  "excite-road-open", to: url)
        try write(try T.road(8, big(T.Plan(energy: 1)), sky: T.sky(hour: 22)).image, "excite-road-traffic", to: url)
    }

    func testWriteFjordExcitementPreviews() throws {
        let url = try folder()
        try write(try T.fjord(2.6, big(T.Plan(moments: [90: T.chord(1)]))).image, "excite-fjord-surge", to: url)
        try write(try T.fjord(3.6, big(T.Plan(moments: [90: T.chord(1)]))).image, "excite-fjord-corona", to: url)
        try write(try T.fjord(1.8, big(T.Plan(surprises: [10: WorldSurprise(index: 0, seed: 21)]))).image, "excite-fjord-fireball", to: url)
        try write(try T.fjord(1.6, big(T.Plan(surprises: [10: WorldSurprise(index: 1, seed: 21)]))).image, "excite-fjord-orca", to: url)
        // Seed 21's flare peaks 13.9 s into its pass.
        try write(try T.fjord(14.05, big(T.Plan(surprises: [10: WorldSurprise(index: 2, seed: 21)]))).image, "excite-fjord-satellite", to: url)
        try write(try T.fjord(4.5, big(T.Plan(tension: { _ in 0.9 }))).image, "excite-fjord-gathered", to: url)
        try write(try T.fjord(5.5, big(T.Plan(tension: { $0 < 240 ? 0.9 : 0 }, moments: [240: T.chord(0.6, drop: true)]))).image,
                  "excite-fjord-drop", to: url)
        try write(try T.fjord(30, big(T.Plan(energy: 1))).image, "excite-fjord-energy", to: url)
    }
}

/// The GPU time of each world's frame mid-moment at 1280×720 (the scene pass, and with the finishing passes), printed for
/// the looks run's report (spec §12: each world's Excitement ≤ 0.5 ms a frame; CI's virtual GPU is far slower, so this
/// only reports, beside the same frame with nothing playing).
@MainActor
final class ExcitementFrameTimeTests: XCTestCase {
    typealias T = ExcitementWorldsRendererTests

    private func time(_ renderer: ThemeRenderer, label: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("No Metal device") }
        let width = 1280, height = 720
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: width, height: height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        var scene: [Double] = [], whole: [Double] = []
        for i in 0..<24 {
            guard let cb = queue.makeCommandBuffer() else { continue }
            renderer.render(stack: stack, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            let sceneMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard let cb2 = queue.makeCommandBuffer() else { continue }
            renderer.render(stack: stack, commandBuffer: cb2)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            stack.post(into: pass, commandBuffer: cb2, settings: renderer.post)
            cb2.commit()
            cb2.waitUntilCompleted()
            if i >= 4 {
                scene.append(sceneMs)
                whole.append((cb2.gpuEndTime - cb2.gpuStartTime) * 1000)
            }
        }
        scene.sort()
        whole.sort()
        let sceneMedian = scene.isEmpty ? 0 : scene[scene.count / 2]
        let wholeMedian = whole.isEmpty ? 0 : whole[whole.count / 2]
        print(String(format: "FRAME TIME %@ 1280x720: scene %.2f ms, scene+finish %.2f ms (median of %d)", label, sceneMedian,
                     wholeMedian, scene.count))
        XCTAssertGreaterThan(wholeMedian, 0)
    }

    private func big(_ plan: T.Plan) -> T.Plan {
        var p = plan
        p.width = 1280
        p.height = 720
        p.capture = false
        return p
    }

    func testExcitementFrameTimes() throws {
        let moment = T.Plan(energy: 0.8, moments: [60: T.chord(1)])
        try time(try T.lake(1.3, big(T.Plan(energy: 0.8))).renderer, label: "lake calm")
        try time(try T.lake(1.3, big(moment)).renderer, label: "lake burst")
        try time(try T.beach(1.6, big(T.Plan(energy: 0.8))).renderer, label: "beach calm")
        try time(try T.beach(1.6, big(moment)).renderer, label: "beach fireworks")
        try time(try T.road(1.6, big(T.Plan(energy: 0.8)), sky: T.sky(hour: 22)).renderer, label: "road calm")
        try time(try T.road(1.6, big(moment), sky: T.sky(hour: 22)).renderer, label: "road beam")
        try time(try T.fjord(2.5, big(T.Plan(energy: 0.8))).renderer, label: "fjord calm")
        try time(try T.fjord(2.5, big(moment)).renderer, label: "fjord surge")
    }
}
