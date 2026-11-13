import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Supercell Sky (Storms spec §8; plan Task 10): the storm over the wheat at golden hour, drawn in one analytic pass.
@MainActor
final class SupercellSkyRendererTests: XCTestCase {
    // MARK: - Helpers

    /// A frozen evening over Melbourne on the previews' fixed date (the world holds the light at golden hour itself).
    nonisolated static func sky(hour: Double = 18.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0.45; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    /// The Distance dial's value for a distance in km.
    nonisolated static func dial(km: Double) -> ParamValue { .number(1 - km / 30) }

    nonisolated static func chord(_ strength: Float, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: true, isDrop: drop)
    }

    struct CellShot {
        var image: CGImage?
        var renderer: SupercellSkyRenderer
        var frame: SupercellFrame
        var params: ParameterSet
    }

    /// Steps Supercell Sky at 60 fps for `seconds` and renders the last frame. The director runs the Living Sky (and the
    /// picker's stage) for the world; the world itself is stepped here so the tests choose its Excitement: `energy` and
    /// `tension` throughout, a big `moments[i]` on frame `i`, `notes(i)` struck on frame `i`. `edit` changes each frame
    /// before the renderer sees it; `each` sees every frame after the renderer's update.
    static func renderCell(at seconds: Double, stage: SupercellStage = .core, hold: SkyHold = .goldenHour,
                           skyHour: Double = 18.5,
                           values: [String: ParamValue] = [:], quality: QualityLevel = .high, gentle: Bool = false,
                           reduceMotion: Bool = false, energy: Float = 0.4, tension: Float = 0.3,
                           moments: [Int: BigMoment] = [:], notes: ((Int) -> [UInt8])? = nil,
                           width: Int = 640, height: Int = 360, capture: Bool = true,
                           edit: ((Int, inout SupercellFrame) -> Void)? = nil,
                           each: ((Int, SupercellSkyRenderer, SupercellFrame) -> Void)? = nil) throws -> CellShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(SupercellSkyRenderer(device: device))
        var stateValues = values
        stateValues[SupercellStage.id] = .choice(stage.rawValue)
        stateValues["light.hold"] = .choice(hold.rawValue)
        // The sky's own crawlers and sheet lightning are off unless a test asks (they'd spend the flash budget at random).
        if stateValues[SkyExtraMode.crawlersID] == nil { stateValues[SkyExtraMode.crawlersID] = .choice(SkyExtraMode.off.rawValue) }
        if stateValues[SkyExtraMode.sheetID] == nil { stateValues[SkyExtraMode.sheetID] = .choice(SkyExtraMode.off.rawValue) }
        let state = ThemeState(values: stateValues)
        let d = SceneDirector(themeID: SupercellSkyModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky(hour: skyHour))
        d.mood = .stormTense
        var model = SupercellSkyModel()
        model.mood = .stormTense
        let size = CGSize(width: width, height: height)
        let n = max(1, Int((seconds * 60).rounded()))
        var last: SupercellFrame?
        for i in 1...n {
            let t = Double(i) / 60
            elapsed = t
            _ = d.step(dt: 1.0 / 60, t: t, quality: quality)
            if let s = d.lastSky { model.setSky(s) }
            var e = ExcitementFrame()
            e.energy = energy
            e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
            e.tension = tension
            e.reduceMotion = reduceMotion
            if let m = moments[i] {
                e.moment = m
                e.drop = m.isDrop ? 1 : 0
            }
            model.setExcitement(e)
            if let notes {
                for k in notes(i) { model.handle(.noteOn(note: k, velocity: 0.8)) }
            }
            var f = model.step(dt: 1.0 / 60, params: d.parameters, roles: RoleValues(), inputs: InputFrame(), quality: quality)
            edit?(i, &f)
            r.update(f, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
            each?(i, r, f)
            last = f
        }
        let frame = try XCTUnwrap(last)
        var image: CGImage?
        if capture {
            let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
            image = preview.capture(r, exposureScale: d.exposureScale)
        }
        return CellShot(image: image, renderer: r, frame: frame, params: d.parameters)
    }

    /// Chords on the beat and notes between them, so the glows, the pulses and the ripples all show.
    nonisolated static func playing(_ i: Int) -> [UInt8] {
        if i % 45 == 0 { return [41, 48, 57, 60, 64] }
        if i % 15 == 0 { return [UInt8(60 + (i / 15) % 24)] }
        return []
    }

    /// An anvil crawler laid across the view's upper sky (for frames that need one now).
    nonisolated static func crawler(viewAzimuth: Double) -> CrawlerSlot {
        var segments: [CrawlerSegment] = []
        var at = SIMD2<Float>(Float(viewAzimuth) - 24, 30)
        let steps: [SIMD2<Float>] = [SIMD2(4, 1.5), SIMD2(3.5, -1), SIMD2(4.5, 2), SIMD2(3, -0.5), SIMD2(4, 1),
                                     SIMD2(5, -1.5), SIMD2(3.5, 0.5), SIMD2(4, 1.2)]
        for (k, s) in steps.enumerated() {
            let to = at + s
            let a = Float(k) / Float(steps.count), b = Float(k + 1) / Float(steps.count)
            segments.append(CrawlerSegment(from: at, to: to, start: a, end: b))
            at = to
        }
        return CrawlerSlot(segments: segments, born: 0, duration: 1.2, peak: 0.4, called: true, progress: 0.9, glow: 1,
                           brightness: 0.35)
    }

    // MARK: - The shaders

    func testSupercellShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SupercellSkyShaders.source, options: nil)
        let names = ["cell_vertex", "cell_scene_fragment", "cell_bird_vertex", "cell_bird_fragment", "cell_post_vertex",
                     "cell_post_fragment"]
        for name in names {
            let function = lib.skyFunction(name)
            XCTAssertNotNil(function, name)
        }
        // Built on the Sky kit, with no powers of its own.
        let kit = SkyShaders.common
        let prefixed = SupercellSkyShaders.source.hasPrefix(kit)
        XCTAssertTrue(prefixed)
        let own = String(SupercellSkyShaders.source.dropFirst(kit.count))
        let powers = own.contains("pow(")
        XCTAssertFalse(powers, "squares and powers are written out")
        for call in ["skyRadiance(", "rainbowBow("] {
            let uses = own.contains(call)
            XCTAssertTrue(uses, "uses the kit's \(call)")
        }
        // The Swift rows match the MSL struct byte for byte (the pipeline's own reflection).
        let row = MemoryLayout<SIMD4<Float>>.stride
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.skyFunction("cell_vertex")
        d.fragmentFunction = lib.skyFunction("cell_scene_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        let skyBytes = buffers.first { $0.index == 0 }?.bufferDataSize
        let cellBytes = buffers.first { $0.index == 1 }?.bufferDataSize
        let wantSky = SkyLayer.uniformCount * row
        let wantCell = SupercellSkyRenderer.uniformCount * row
        XCTAssertEqual(skyBytes, wantSky, "SkyU")
        XCTAssertEqual(cellBytes, wantCell, "CellU")
        XCTAssertLessThanOrEqual(wantCell, 4096, "one setFragmentBytes call")
        // The rows' layout, end to end.
        typealias R = SupercellSkyRenderer
        XCTAssertEqual(R.rippleBase, R.rowExtra + 1)
        XCTAssertEqual(R.glowBase, R.rippleBase + R.rippleSlots)
        XCTAssertEqual(R.strikeInfoBase, R.glowBase + R.glowSlots)
        XCTAssertEqual(R.strikeBoxBase, R.strikeInfoBase + R.strikeSlots)
        XCTAssertEqual(R.strikeAtBase, R.strikeBoxBase + R.strikeSlots)
        XCTAssertEqual(R.segBase, R.strikeAtBase + R.strikeSlots)
        XCTAssertEqual(R.crawlInfoBase, R.segBase + R.strikeSlots * R.segsPerStrike)
        XCTAssertEqual(R.crawlBase, R.crawlInfoBase + R.crawlerSlots)
        XCTAssertEqual(R.grassBase, R.crawlBase + R.crawlerSlots * R.segsPerCrawler)
        XCTAssertEqual(R.uniformCount, R.grassBase + R.grassSlots)
        XCTAssertEqual(R.crawlerSlots, AnvilCrawlers.slots)
        XCTAssertEqual(R.segsPerCrawler, AnvilCrawlers.maxSegments)
        XCTAssertEqual(R.rippleSlots, WallCloud.rippleCap)
        let r = try XCTUnwrap(SupercellSkyRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, R.uniformCount)
        // The instances fit setVertexBytes: the 88 posts, the 40 birds.
        let postBytes = 88 * 2 * row
        let birdBytes = StormFlock.count(.high) * 2 * row
        XCTAssertLessThanOrEqual(postBytes, 4096)
        XCTAssertLessThanOrEqual(birdBytes, 4096)
    }

    // MARK: - The look

    private struct LightCase { let name: String; let stage: SupercellStage; let hold: SkyHold; let mean: Double; let variance: Double }

    func testSupercellPreviewIsStructured() throws {
        // CPU reference renders of these frames (the shaders through the MSL shim) measured means 0.38, 0.35, 0.35 and
        // 0.011 and variances 0.031, 0.031, 0.027 and 0.0005: the floors leave room for the real sky, the bloom and the keys.
        let cases = [
            LightCase(name: "approach", stage: .approach, hold: .goldenHour, mean: 0.12, variance: 0.006),
            LightCase(name: "core", stage: .core, hold: .goldenHour, mean: 0.12, variance: 0.006),
            LightCase(name: "clearing", stage: .clearing, hold: .goldenHour, mean: 0.12, variance: 0.006),
            LightCase(name: "night", stage: .core, hold: .deepNight, mean: 0.004, variance: 0.0001),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try Self.renderCell(at: 3, stage: c.stage, hold: c.hold, quality: q, notes: Self.playing)
                let image = try XCTUnwrap(shot.image)
                let s = PreviewRenderer.stats(image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                // The storm stands in the frame, its wall cloud under it.
                let storm = shot.renderer.stormCentreNDC
                let wall = shot.renderer.wallCentreNDC
                XCTAssertLessThan(abs(storm.x), 0.9, "\(q) \(c.name)")
                XCTAssertGreaterThan(storm.y, wall.y, "\(q) \(c.name)")
                let rows = shot.renderer.grassRows.count
                XCTAssertEqual(rows, SupercellSkyRenderer.rowCount(q), "\(q) \(c.name)")
            }
        }
    }

    // MARK: - The wheat and the wind

    func testGrassBendsToTheWindField() throws {
        let shot = try Self.renderCell(at: 1, capture: false)
        let r = shot.renderer
        let wind = shot.frame.wind
        // Every row leans as the wind field blows at its distance (one sample a row).
        XCTAssertEqual(r.grassRows.count, 48)
        for row in r.grassRows {
            let expected = SupercellSkyRenderer.lean(wind.sample(SIMD2(0, row.x)))
            XCTAssertEqual(row.y, expected.x, accuracy: 1e-5)
            XCTAssertEqual(row.z, expected.y, accuracy: 1e-5)
            XCTAssertEqual(row.w, expected.z, accuracy: 1e-5)
        }
        let nearest = r.grassRows[0].x
        let farthest = r.grassRows[47].x
        XCTAssertEqual(nearest, 6, accuracy: 1e-3)
        XCTAssertEqual(farthest, 600, accuracy: 0.05)
        // The law: still air stands it up; a wind from the left leans it right; harder bends it further; a wind toward
        // the camera flattens it most and lays its sheen toward us.
        let still = SupercellSkyRenderer.lean(SIMD2(0, 0))
        XCTAssertEqual(still.x, 0)
        XCTAssertEqual(still.y, 1)
        XCTAssertEqual(still.z, 0)
        let breeze = SupercellSkyRenderer.lean(SIMD2(4, 0))
        let gale = SupercellSkyRenderer.lean(SIMD2(12, 0))
        let fromLeft = SupercellSkyRenderer.lean(SIMD2(-4, 0))
        XCTAssertGreaterThan(breeze.x, 0)
        XCTAssertLessThan(fromLeft.x, 0)
        XCTAssertGreaterThan(gale.x, breeze.x)
        XCTAssertLessThan(gale.y, breeze.y)
        let towardUs = SupercellSkyRenderer.lean(SIMD2(0, -12))
        let awayFromUs = SupercellSkyRenderer.lean(SIMD2(0, 12))
        XCTAssertLessThan(towardUs.y, gale.y)
        XCTAssertGreaterThan(towardUs.z, 0.3)
        XCTAssertEqual(awayFromUs.z, 0)
        // Smooth samples half as many rows.
        let lite = try Self.renderCell(at: 0.5, quality: .lite, capture: false)
        XCTAssertEqual(lite.renderer.grassRows.count, 24)
    }

    func testGustFrontFlattensGrassBehindTheWave() throws {
        // A drop at 1 s sends the gust front from the field's far edge at 15 m/s: 8 s on it is 120 m nearer.
        let shot = try Self.renderCell(at: 9, moments: [60: Self.chord(1, drop: true)], capture: false)
        let wave = try XCTUnwrap(shot.frame.gustWave)
        let front: Float = (1 - wave) * SupercellSkyModel.gustStart
        XCTAssertEqual(front, 180, accuracy: 10)
        var behind: [Float] = [], ahead: [Float] = [], sheenBehind: Float = 0
        for row in shot.renderer.grassRows {
            if row.x > front + 60, row.x < front + 300 {
                behind.append(row.z)
                sheenBehind = max(sheenBehind, row.w)
            }
            if row.x < front - 60 { ahead.append(row.z) }
        }
        XCTAssertFalse(behind.isEmpty)
        XCTAssertFalse(ahead.isEmpty)
        let keptBehind = behind.reduce(0, +) / Float(behind.count)
        let keptAhead = ahead.reduce(0, +) / Float(ahead.count)
        XCTAssertLessThan(keptBehind, keptAhead - 0.2, "flattened where the front has passed, standing where it hasn't")
        XCTAssertGreaterThan(sheenBehind, 0.3, "the flattened wheat shines toward the camera")
        // The shader is told where the front is and raises dust behind it.
        let gust = shot.renderer.uniforms[SupercellSkyRenderer.rowGust]
        XCTAssertEqual(gust.x * 1000, front, accuracy: 1)
        XCTAssertGreaterThan(gust.y, 0)
    }

    // MARK: - Lightning

    func testStrikeIsBlueWhiteAndLimited() throws {
        // Blue-white, never red.
        let colour = SupercellSkyRenderer.strikeColour
        XCTAssertGreaterThanOrEqual(colour.z, colour.y)
        XCTAssertGreaterThanOrEqual(colour.y, colour.x)
        XCTAssertGreaterThan(colour.x, 0.6)
        // A strike 6 km off: its channel is drawn, through the limiter, from the cloud to the ground at the storm's distance.
        var lit = false, drawn = false, worst = 0
        let shot = try Self.renderCell(at: 2, values: ["distance": Self.dial(km: 6)], moments: [120: Self.chord(1)],
                                       each: { i, r, _ in
            if i == 120 {
                lit = r.strikeLight > 0.4
                drawn = r.channelsDrawn
            }
            worst = max(worst, r.flashesInLastSecond)
        })
        XCTAssertTrue(lit)
        XCTAssertTrue(drawn)
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
        let info = shot.renderer.uniforms[SupercellSkyRenderer.strikeInfoBase]
        XCTAssertGreaterThan(info.y, 8, "the channel and its branches")
        XCTAssertEqual(info.z, 0, "a big strike bursts out of the storm's side in the clear air, none of it hidden")
        let at = shot.renderer.uniforms[SupercellSkyRenderer.strikeAtBase]
        let foot = at.w
        let top = at.z
        let fromHorizon = abs(foot - SupercellSkyRenderer.horizonY)
        XCTAssertLessThan(fromHorizon, 0.01, "it comes down on the field 6 km off, at the horizon's foot")
        XCTAssertGreaterThan(top, foot + 0.1)
        // The brightest of it is blue-white on screen.
        let image = try XCTUnwrap(shot.image)
        let box = shot.renderer.uniforms[SupercellSkyRenderer.strikeBoxBase]
        let x0 = Double(box.x), x1 = Double(max(box.z, box.x + 0.01))
        let y0 = Double(box.y), y1 = Double(max(box.w, box.y + 0.01))
        let pixels = FramePatch.pixels(image, x: x0 ... x1, y: y0 ... y1)
        var ranked: [(Double, SIMD3<Double>)] = []
        for p in pixels {
            let total: Double = p.x + p.y + p.z
            ranked.append((total, p))
        }
        ranked.sort { $0.0 > $1.0 }
        let top50 = ranked.prefix(50)
        var sum = SIMD3<Double>(repeating: 0)
        for p in top50 { sum += p.1 }
        let mean = sum / Double(max(1, top50.count))
        XCTAssertGreaterThan(mean.x + mean.y + mean.z, 2.4, "a bright channel")
        XCTAssertGreaterThanOrEqual(mean.z, mean.x - 0.02, "blue-white, not warm")
        // A storm of strikes: one a quarter-second for three seconds, never more than three flashes a second.
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 30, to: 210, by: 15) { moments[i] = Self.chord(1) }
        var most = 0
        _ = try Self.renderCell(at: 3.5, values: ["distance": Self.dial(km: 4)], moments: moments, capture: false,
                                each: { _, r, _ in most = max(most, r.flashesInLastSecond) })
        XCTAssertLessThanOrEqual(most, FlashLimiter.maxFlashesPerSecond)
    }

    func testWorstCaseFlashBudget() throws {
        // Everything at once: a strike every 50 ms overhead, the sky's storm light switching on and off every other frame,
        // chords pulsing the base on every frame. The screen never flashes more than three times a second, nor the base.
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 3, to: 240, by: 3) { moments[i] = Self.chord(1, drop: i % 60 == 0) }
        var flashes = 0, pulses = 0, total = 0
        _ = try Self.renderCell(at: 4, values: ["distance": Self.dial(km: 1)], energy: 1, tension: 1, moments: moments,
                                notes: { _ in [36, 43, 48, 52, 55] }, capture: false,
                                edit: { i, f in
            f.sky.stormFlash = i % 2 == 0 ? 1 : 0
            f.sky.crawlers = [Self.crawler(viewAzimuth: f.viewAzimuth)]
        }, each: { _, r, _ in
            flashes = max(flashes, r.flashesInLastSecond)
            pulses = max(pulses, r.pulseFlashesInLastSecond)
            total = r.flashTotal
        })
        XCTAssertLessThanOrEqual(flashes, FlashLimiter.maxFlashesPerSecond)
        XCTAssertLessThanOrEqual(pulses, FlashLimiter.maxFlashesPerSecond)
        XCTAssertLessThanOrEqual(total, 5 * FlashLimiter.maxFlashesPerSecond)
        XCTAssertGreaterThan(total, 0, "it did flash")
    }

    // MARK: - Settings

    func testSupercellHonoursGentleVisuals() throws {
        var peak: Float = 0, gentlePeak: Float = 0, gentleDrawn = false, glowOnly = true
        _ = try Self.renderCell(at: 2.5, values: ["distance": Self.dial(km: 6)], moments: [120: Self.chord(1)], capture: false,
                                each: { _, r, _ in peak = max(peak, r.strikeLight) })
        _ = try Self.renderCell(at: 2.5, values: ["distance": Self.dial(km: 6)], gentle: true, moments: [120: Self.chord(1)],
                                capture: false, each: { _, r, _ in
            gentlePeak = max(gentlePeak, r.strikeLight)
            gentleDrawn = gentleDrawn || r.channelsDrawn
            let info = r.uniforms[SupercellSkyRenderer.strikeInfoBase]
            if info.x > 0, info.w < 0.5 { glowOnly = false }
        })
        XCTAssertGreaterThan(peak, 0.5)
        XCTAssertGreaterThan(gentlePeak, 0, "a glow inside the cloud")
        XCTAssertLessThanOrEqual(gentlePeak, 0.6 * peak, "halved")
        XCTAssertFalse(gentleDrawn, "no channel under gentle visuals")
        XCTAssertTrue(glowOnly)
    }

    func testSupercellHonoursReduceMotion() throws {
        // A close strike and a drop shake the camera and the storm dollies it back…
        var shook = false, dollied = false
        _ = try Self.renderCell(at: 3, values: ["distance": Self.dial(km: 1)], energy: 1,
                                moments: [60: Self.chord(1), 120: Self.chord(1, drop: true)], capture: false,
                                each: { _, r, _ in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { shook = true }
            if r.uniforms[SupercellSkyRenderer.rowPlace].w > 0 { dollied = true }
        })
        XCTAssertTrue(shook)
        XCTAssertTrue(dollied)
        // …but not under Reduce Motion, which turns the storm no faster than 1 rpm.
        var still = true, fastest: Float = 0
        _ = try Self.renderCell(at: 3, values: ["distance": Self.dial(km: 1)], reduceMotion: true, energy: 1,
                                moments: [60: Self.chord(1), 120: Self.chord(1, drop: true)], capture: false,
                                each: { _, r, f in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { still = false }
            if r.uniforms[SupercellSkyRenderer.rowPlace].w != 0 { still = false }
            fastest = max(fastest, f.rotationRPM)
        })
        XCTAssertTrue(still)
        XCTAssertLessThanOrEqual(fastest, 1.0001)
        // Smooth never shakes, whatever the frame asks.
        var smoothStill = true
        _ = try Self.renderCell(at: 1, quality: .lite, capture: false, edit: { _, f in f.cameraShake = SIMD2(5, -4) },
                                each: { _, r, _ in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { smoothStill = false }
        })
        XCTAssertTrue(smoothStill)
    }

    func testSupercellFramesAnyAspect() throws {
        let sizes: [(Int, Int)] = [(640, 360), (360, 640), (500, 500), (1280, 540)]
        for (w, h) in sizes {
            let shot = try Self.renderCell(at: 1, notes: Self.playing, width: w, height: h)
            let image = try XCTUnwrap(shot.image)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.1, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.004, "\(w)×\(h)")
            let rects = shot.renderer.keyRects
            XCTAssertEqual(rects.count, 88, "\(w)×\(h)")
            for k in rects {
                XCTAssertGreaterThanOrEqual(k.x, -1, "\(w)×\(h)")
                XCTAssertGreaterThanOrEqual(k.y, -1, "\(w)×\(h)")
                XCTAssertLessThanOrEqual(k.z, 1, "\(w)×\(h)")
                XCTAssertLessThanOrEqual(k.w, 1, "\(w)×\(h)")
            }
            let storm = shot.renderer.stormCentreNDC
            XCTAssertLessThan(abs(storm.x), 1, "\(w)×\(h): the storm in the frame")
            XCTAssertLessThan(abs(storm.y), 1, "\(w)×\(h): the storm in the frame")
        }
    }

    func testSupercellBurstStaysInBudget() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            var glows = 0, pulses = 0, ripples = 0, birds = 0, rows = 0, uniforms = 0, captured = 0
            let start = Date()
            _ = try Self.renderCell(at: 1, quality: q, energy: 1, tension: 1, moments: [20: Self.chord(1, drop: true)],
                                    notes: { i in (0..<34).map { k in UInt8(21 + (i * 34 + k) % 88) } }, capture: false,
                                    each: { _, r, f in
                glows = max(glows, f.glows.count)
                pulses = max(pulses, f.pulses.count)
                ripples = max(ripples, f.ripples.count)
                birds = max(birds, r.birdCount)
                rows = max(rows, r.grassRows.count)
                uniforms = max(uniforms, r.uniforms.count)
                if preview.capture(r) != nil { captured += 1 }
            })
            let seconds = Date().timeIntervalSince(start)
            XCTAssertLessThanOrEqual(glows, WallCloud.glowCap, "\(q)")
            XCTAssertLessThanOrEqual(pulses, WallCloud.pulseCap, "\(q)")
            XCTAssertLessThanOrEqual(ripples, WallCloud.rippleCap, "\(q)")
            XCTAssertLessThanOrEqual(birds, StormFlock.count(q), "\(q)")
            XCTAssertEqual(rows, SupercellSkyRenderer.rowCount(q), "\(q)")
            XCTAssertEqual(uniforms, SupercellSkyRenderer.uniformCount, "\(q)")
            XCTAssertEqual(captured, 60, "\(q)")
            XCTAssertLessThan(seconds, 10, "\(q)")
        }
    }
}

/// The GPU time of a Supercell Sky frame at 1280×720 (the scene pass and the finishing passes), printed for the
/// previews job's report (spec: Smooth ≤ 2.5 ms on the target Mac; CI's virtual GPU is far slower, so this only reports).
@MainActor
final class SupercellFrameTimeTests: XCTestCase {
    func testSupercellFrameTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let width = 1280, height = 720
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: width, height: height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        for q in [QualityLevel.lite, .high] {
            let shot = try SupercellSkyRendererTests.renderCell(at: 2, quality: q, notes: SupercellSkyRendererTests.playing,
                                                                width: width, height: height, capture: false)
            var scene: [Double] = [], whole: [Double] = []
            for i in 0..<24 {
                guard let cb = queue.makeCommandBuffer() else { continue }
                shot.renderer.render(stack: stack, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                let sceneMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                guard let cb2 = queue.makeCommandBuffer() else { continue }
                shot.renderer.render(stack: stack, commandBuffer: cb2)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                stack.post(into: pass, commandBuffer: cb2, settings: shot.renderer.post)
                cb2.commit()
                cb2.waitUntilCompleted()
                let wholeMs = (cb2.gpuEndTime - cb2.gpuStartTime) * 1000
                if i >= 4 {
                    scene.append(sceneMs)
                    whole.append(wholeMs)
                }
            }
            scene.sort()
            whole.sort()
            let sceneMedian = scene.isEmpty ? 0 : scene[scene.count / 2]
            let wholeMedian = whole.isEmpty ? 0 : whole[whole.count / 2]
            let label = q == .lite ? "Smooth" : "High"
            print(String(format: "FRAME TIME supercell %@ 1280x720: scene %.2f ms, scene+finish %.2f ms (median of %d)",
                         label, sceneMedian, wholeMedian, scene.count))
            XCTAssertGreaterThan(wholeMedian, 0)
        }
    }

    /// The Lounge's frame on the same GPU, for scale (CI's virtual GPU is far from the target Mac's).
    func testLoungeFrameTimeForScale() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let width = 1280, height = 720
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: width, height: height)
        for q in [QualityLevel.lite, .high] {
            let r = try XCTUnwrap(SpaceshipLoungeRenderer(device: device))
            let d = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            let size = CGSize(width: width, height: height)
            for i in 1...60 {
                let t = Double(i) / 60
                if let f = d.step(dt: 1.0 / 60, t: t, quality: q) as? LoungeFrame {
                    r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: size)
                }
            }
            var scene: [Double] = []
            for i in 0..<24 {
                guard let cb = queue.makeCommandBuffer() else { continue }
                r.render(stack: stack, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                if i >= 4 { scene.append(ms) }
            }
            scene.sort()
            let median = scene.isEmpty ? 0 : scene[scene.count / 2]
            let label = q == .lite ? "Smooth" : "High"
            print(String(format: "FRAME TIME lounge %@ 1280x720: scene %.2f ms (median of %d)", label, median, scene.count))
            XCTAssertGreaterThan(median, 0)
        }
    }
}

extension WorldPreviewTests {
    func testWriteSupercellPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        typealias T = SupercellSkyRendererTests
        let playing = T.playing
        func write(_ shot: T.CellShot, _ name: String) throws {
            let image = try XCTUnwrap(shot.image)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        let stages: [(String, SupercellStage, QualityLevel)] = [
            ("supercell-approach", .approach, .high),
            ("supercell-core", .core, .high),
            ("supercell-clearing", .clearing, .high),
            ("supercell-smooth", .core, .lite),
        ]
        for (name, stage, q) in stages {
            try write(try T.renderCell(at: 5, stage: stage, quality: q, notes: playing, width: 1280, height: 720), name)
        }
        // The drop: the gust front 18.5 s out, 22 m off (crossing the near field, so its wave of bent wheat and its dust
        // are seen), the wheat flattened behind it, the hail shaft surging closer.
        try write(try T.renderCell(at: 19.5, energy: 0.9, tension: 0.8, moments: [60: T.chord(1, drop: true)], notes: playing,
                                   width: 1280, height: 720), "supercell-drop")
        // A strike's first return stroke, at the storm's distance.
        try write(try T.renderCell(at: 3, energy: 0.7, moments: [180: T.chord(1)],
                                   notes: playing, width: 1280, height: 720), "supercell-strike-t3")
        // Night: the storm lit from inside, a crawler across the anvil, the next cell flickering on the horizon.
        try write(try T.renderCell(at: 5, hold: .deepNight, notes: playing, width: 1280, height: 720, edit: { _, f in
            f.sky.crawlers = [T.crawler(viewAzimuth: f.viewAzimuth)]
            f.sky.stormFlash = 0.35
            f.farCell = 0.2
        }), "supercell-night-sprites")
    }
}
