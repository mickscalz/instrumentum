import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Great Barrier Reef (Set 12's world) with Coral Pulse: the split view at the waterline of a coral cay's lagoon.
@MainActor
final class GreatBarrierReefRendererTests: XCTestCase {
    func testReefShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: GreatBarrierReefShaders.source, options: nil)
        for name in ["reef_vertex", "reef_above_fragment", "reef_below_fragment", "reef_dot_vertex", "reef_dot_fragment",
                     "reef_keys_vertex", "reef_keys_fragment"] {
            XCTAssertNotNil(lib.skyFunction(name), name)
        }
        // Built on the Sky and the Underwater Kit, with no powers of its own.
        let kits = SkyShaders.common + UnderwaterShaders.common
        XCTAssertTrue(GreatBarrierReefShaders.source.hasPrefix(kits))
        let own = String(GreatBarrierReefShaders.source.dropFirst(kits.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        for kit in ["waterView(", "snellWindow(", "caustics(", "lightShafts(", "throughWater(", "waterAdapt(", "skyRadiance("] {
            XCTAssertTrue(own.contains(kit), "uses the kit's \(kit)")
        }
        // The Swift uniform array matches the MSL struct byte for byte in both halves (the pipelines' own reflection).
        let row = MemoryLayout<SIMD4<Float>>.stride
        for fragment in ["reef_above_fragment", "reef_below_fragment"] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction("reef_vertex")
            d.fragmentFunction = lib.skyFunction(fragment)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            var reflection: MTLAutoreleasedRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
            let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
            func size(_ index: Int) -> Int? { buffers.first { $0.index == index }?.bufferDataSize }
            XCTAssertEqual(size(0), SkyLayer.uniformCount * row, "\(fragment): SkyU")
            XCTAssertEqual(size(1), GreatBarrierReefRenderer.uniformCount * row, "\(fragment): ReefU")
        }
        XCTAssertEqual(GreatBarrierReefRenderer.groupBase, GreatBarrierReefRenderer.headerCount)
        XCTAssertEqual(GreatBarrierReefRenderer.hueBase, GreatBarrierReefRenderer.groupBase + CoralPulse.groupCount)
        XCTAssertEqual(GreatBarrierReefRenderer.patchBase, GreatBarrierReefRenderer.hueBase + CoralPulse.groupCount)
        XCTAssertEqual(GreatBarrierReefRenderer.uniformCount, GreatBarrierReefRenderer.patchBase + CoralPulse.cap)
        XCTAssertLessThanOrEqual(GreatBarrierReefRenderer.uniformCount * row, 4096, "one setFragmentBytes call")
        let r = try XCTUnwrap(GreatBarrierReefRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, GreatBarrierReefRenderer.uniformCount)
        XCTAssertEqual(r.bufferAllocations, 3, "the instance buffers are made once, before the first frame")
    }

    /// Frozen skies over Cairns (the reef follows the sky) on the previews' fixed date, late October.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.45) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "cairns"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    /// No shower turns the camera from the east (unless a test asks for one).
    nonisolated static var east: ThemeState { ThemeState(values: ["meteors.mode": .choice(MeteorMode.never.rawValue)]) }

    struct ReefShot {
        var image: CGImage
        var renderer: GreatBarrierReefRenderer
        var frame: ReefFrame
        var params: ParameterSet
        var preview: PreviewRenderer
    }

    /// Steps the reef at 60 fps through the director (notes go down at 0.5 s and stay held, unless `release`) and
    /// renders the frame at `seconds`; `edit` changes each frame before the renderer sees it.
    static func renderReef(notes: [UInt8], velocity: Float = 0.8, release: Bool = false, at seconds: Double,
                           state: ThemeState = GreatBarrierReefRendererTests.east,
                           sky: SkySettings = GreatBarrierReefRendererTests.sky(hour: 10.5),
                           quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                           edit: ((inout ReefFrame) -> Void)? = nil,
                           each: ((GreatBarrierReefRenderer, ReefFrame) -> Void)? = nil) throws -> ReefShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(GreatBarrierReefRenderer(device: device))
        let d = SceneDirector(themeID: GreatBarrierReefModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .reefAlive
        var frame: ReefFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            if i == 33, release, !notes.isEmpty { d.handle(notes.map { .noteOff(note: $0) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? ReefFrame
            if let edit, frame != nil { edit(&frame!) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: d.visualDt, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return ReefShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f, params: d.parameters, preview: preview)
    }

    private struct LightCase { let name: String; let hour: Double; let mean: Double; let variance: Double }

    func testReefPreviewIsStructured() throws {
        // CPU reference renders of these frames (the shaders through the MSL shim) measured means 0.58, 0.38 and 0.11
        // and variances 0.013, 0.035 and 0.010: the floors leave room for the real sky, the bloom and the keys.
        let cases = [
            LightCase(name: "day", hour: 10.5, mean: 0.2, variance: 0.004),
            LightCase(name: "dusk", hour: 18.3, mean: 0.08, variance: 0.003),
            LightCase(name: "night", hour: 22.5, mean: 0.02, variance: 0.0008),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try Self.renderReef(notes: [48, 60, 64, 67, 84], at: 1.2, sky: Self.sky(hour: c.hour), quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(shot.frame.corals.count, 7, "\(q) \(c.name)")
                XCTAssertGreaterThan(shot.renderer.patchCount, 0, "\(q) \(c.name): the notes light their corals in any light")
                XCTAssertGreaterThan(shot.renderer.fishCount, 20, "\(q) \(c.name): the school and the chromis")
                XCTAssertEqual(shot.renderer.snowCount, MarineSnow.count(q), "\(q) \(c.name): marine snow by quality")
            }
        }
    }

    /// Spec §9.1: the water's surface splits the frame at about 45% of its height, the sky over it and the reef under
    /// it; the Waterline dial moves it, from more reef to more sky.
    func testWaterlineSplitsTheFrame() throws {
        let shot = try Self.renderReef(notes: [], at: 1.0)
        let r = shot.renderer
        XCTAssertEqual(shot.frame.waterlineY, 0.45, accuracy: 1e-6)
        XCTAssertEqual(r.waterlineY, -0.1, accuracy: 1e-5, "45% of the frame's height from its bottom edge")
        XCTAssertEqual(abs(r.meniscusY - r.waterlineY), 0, accuracy: 0.03, "a calm lagoon's gentle roll")
        XCTAssertEqual(r.sky.horizonY, r.horizonY)
        XCTAssertEqual(r.horizonY, r.waterlineY + GreatBarrierReefRenderer.horizonLift, accuracy: 1e-5)
        XCTAssertTrue(r.keyTop < r.eyeLevelY && r.eyeLevelY < r.waterlineY && r.waterlineY < r.horizonY && r.horizonY < 1)
        XCTAssertLessThanOrEqual(r.meniscusRange.lowerBound, r.meniscusY)
        XCTAssertGreaterThanOrEqual(r.meniscusRange.upperBound, r.meniscusY)
        // Below the line, clear turquoise water; above it, the sky.
        let water = FramePatch.meanRGB(shot.image, x: -0.9 ... 0.9, y: Double(r.eyeLevelY - 0.1) ... Double(r.eyeLevelY - 0.02))
        let sky = FramePatch.meanRGB(shot.image, x: -0.9 ... 0.9, y: 0.6 ... 0.95)
        XCTAssertGreaterThan(water.y - water.x, 0.15, "turquoise under the surface: \(water)")
        XCTAssertGreaterThan(water.z - water.x, 0.15, "\(water)")
        XCTAssertGreaterThan(sky.z, sky.x, "a blue sky over it: \(sky)")
        XCTAssertGreaterThan((water.y - water.x) - (sky.y - sky.x), 0.1, "the halves differ: water \(water), sky \(sky)")

        // The dial: more reef (the line up at 0.6 of the height) or more sky (down at 0.3).
        let reef = try Self.renderReef(notes: [], at: 1.0, state: ThemeState(values: ["waterline": .number(0),
                                                                                     "meteors.mode": .choice(MeteorMode.never.rawValue)]))
        let open = try Self.renderReef(notes: [], at: 1.0, state: ThemeState(values: ["waterline": .number(1),
                                                                                     "meteors.mode": .choice(MeteorMode.never.rawValue)]))
        XCTAssertEqual(reef.renderer.waterlineY, 0.2, accuracy: 1e-5)
        XCTAssertEqual(open.renderer.waterlineY, -0.4, accuracy: 1e-5)
        let band = FramePatch.meanRGB(reef.image, x: -0.9 ... 0.9, y: 0.0 ... 0.1)
        let skyBand = FramePatch.meanRGB(open.image, x: -0.9 ... 0.9, y: 0.0 ... 0.1)
        XCTAssertGreaterThan((band.y - band.x) - (skyBand.y - skyBand.x), 0.08,
                             "the band over the resting line is water with more reef (\(band)), sky with more sky (\(skyBand))")
    }

    /// Spec §9.1: the lagoon's surface, seen at a grazing angle, mirrors the sky. The mirror samples skyRadiance, so
    /// whatever the sky draws reflects: a low moon ahead lays its reflection and glitter path in the lagoon under it (and
    /// the shooting stars, which the sky draws in skyRadiance, reflect the same way).
    func testMeteorsReflectInTheLagoon() throws {
        func night(moonAltitude: Double) throws -> ReefShot {
            try Self.renderReef(notes: [], at: 1.0, sky: Self.sky(hour: 22.5, phase: 0.5), edit: { f in
                f.sky.moon = SkyDirection(azimuth: f.cameraAzimuth, altitude: moonAltitude)
                f.sky.moonLit = 1
                f.sky.moonPhase = 0.5
            })
        }
        let lit = try night(moonAltitude: 6)
        let dark = try night(moonAltitude: -10)
        let r = lit.renderer
        XCTAssertEqual(lit.frame.cameraAzimuth, 90, accuracy: 1e-6, "facing east over the crest")
        let lagoon = Double(r.waterlineY + 0.04) ... Double(r.horizonY - 0.03)
        let under = FramePatch.brightest(lit.image, x: -0.06 ... 0.06, y: lagoon, share: 0.1)
        let aside = FramePatch.brightest(lit.image, x: 0.55 ... 0.67, y: lagoon, share: 0.1)
        let without = FramePatch.brightest(dark.image, x: -0.06 ... 0.06, y: lagoon, share: 0.1)
        XCTAssertGreaterThan(under, 2 * aside, "the moon's path in the lagoon under it: \(under) vs \(aside) aside")
        XCTAssertGreaterThan(under, 1.5 * without + 0.02, "and only while the moon is up: \(under) vs \(without)")
        // The sky the lagoon mirrors is the sky the shader binds: the whole SkyU (shooting stars and all).
        XCTAssertEqual(r.sky.uniforms.count, SkyLayer.uniformCount)
    }

    /// Spec §9.2: each note opens and lights the polyps of the coral group nearest its key, in the group's colour.
    func testCoralGlowsOnNotes() throws {
        let sky = Self.sky(hour: 22.5, phase: 0.05)
        let lit = try Self.renderReef(notes: [60], velocity: 0.9, at: 1.2, sky: sky)
        let quiet = try Self.renderReef(notes: [], at: 1.2, sky: sky)
        let r = lit.renderer
        XCTAssertEqual(CoralPulse.group(for: 60), 3, "middle C lights the soft corals in the middle")
        XCTAssertGreaterThan(r.coralGlowOut[3], 0.5)
        for g in [0, 1, 2, 4, 5, 6] { XCTAssertLessThan(r.coralGlowOut[g], 0.05, "group \(g) stays dark") }
        XCTAssertEqual(r.patchCount, 1)
        XCTAssertEqual(quiet.renderer.patchCount, 0)
        let top = r.groupTop(3)
        let box = (x: Double(top.x - 0.07) ... Double(top.x + 0.07), y: Double(top.y - 0.14) ... Double(top.y + 0.01))
        let on = FramePatch.meanRGB(lit.image, x: box.x, y: box.y), off = FramePatch.meanRGB(quiet.image, x: box.x, y: box.y)
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        XCTAssertGreaterThan(luma(on), 1.5 * luma(off) + 0.02, "the soft corals glow: \(on) vs \(off)")
        XCTAssertGreaterThan(on.x, on.y, "pink, their own fluorescence: \(on)")
        // Elsewhere on the reef, nothing changes.
        let far = r.groupTop(0)
        let elsewhere = FramePatch.difference(lit.image, quiet.image, x: Double(far.x - 0.06) ... Double(far.x + 0.06),
                                              y: Double(far.y - 0.12) ... Double(far.y))
        XCTAssertLessThan(elsewhere, 0.02, "the brain corals stay as they were")
    }

    func testReefHonoursGentleVisuals() throws {
        var plain = (glow: Float(0), flash: Float(0), wave: Float(0)), gentle = plain
        var plainWeather = false, gentleWeather = false
        _ = try Self.renderReef(notes: [60, 64, 67], velocity: 0.95, at: 1.4, each: { r, _ in
            plain.glow = max(plain.glow, r.coralGlowOut.max() ?? 0)
            plain.flash = max(plain.flash, r.schoolFlashOut); plain.wave = max(plain.wave, r.waveOut)
            plainWeather = r.weather.gentle
        })
        _ = try Self.renderReef(notes: [60, 64, 67], velocity: 0.95, at: 1.4, gentle: true, each: { r, _ in
            gentle.glow = max(gentle.glow, r.coralGlowOut.max() ?? 0)
            gentle.flash = max(gentle.flash, r.schoolFlashOut); gentle.wave = max(gentle.wave, r.waveOut)
            gentleWeather = r.weather.gentle
        })
        XCTAssertGreaterThan(plain.glow, 0.5, "the chord lights the soft corals")
        XCTAssertGreaterThan(plain.flash, 0.2, "an accent flashes the school silver")
        XCTAssertGreaterThan(plain.wave, 0.2, "and sends a colour wave")
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55, "gentle visuals calm the glow")
        XCTAssertLessThanOrEqual(gentle.flash, plain.flash * 0.55, "the school's flash")
        XCTAssertLessThanOrEqual(gentle.wave, plain.wave * 0.55, "and the wave")
        XCTAssertFalse(plainWeather)
        XCTAssertTrue(gentleWeather, "and the weather's lightning")
        // The swell carrying the lens under: the water washes up over the whole frame, or (gentle) only part way.
        let under = try Self.renderReef(notes: [], at: 0.5, edit: { $0.lensUnder = 1 })
        let calm = try Self.renderReef(notes: [], at: 0.5, gentle: true, edit: { $0.lensUnder = 1 })
        XCTAssertGreaterThan(under.renderer.meniscusY, 1, "under the surface")
        XCTAssertLessThan(calm.renderer.meniscusY, 0.45, "gentle: the water rises only part way")
        XCTAssertGreaterThan(calm.renderer.meniscusY, calm.renderer.waterlineY + 0.3)
    }

    func testReefFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try Self.renderReef(notes: [21, 60, 64, 67, 108], at: 1.2, width: w, height: h)
            let r = shot.renderer
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            XCTAssertTrue(r.keyTop < r.eyeLevelY && r.eyeLevelY < r.waterlineY && r.waterlineY < r.horizonY && r.horizonY < 1,
                          "\(w)×\(h): keys, reef, waterline, horizon in order")
            var previous: Float = -1
            for g in 0..<CoralPulse.groupCount {
                let p = r.groupTop(g)
                XCTAssertTrue(abs(p.x) < 0.95 && p.y > r.keyTop && p.y < r.eyeLevelY, "\(w)×\(h): group \(g) at \(p)")
                XCTAssertGreaterThan(p.x, previous, "\(w)×\(h): bass to treble, left to right")
                previous = p.x
            }
            for f in r.fish {
                XCTAssertTrue(abs(f.x) <= 1.05 && f.y > r.keyTop - 0.02 && f.y < r.waterlineY + 0.02, "\(w)×\(h): a fish at \(f)")
            }
            XCTAssertEqual(Set(shot.frame.patches.map(\.group)).count, 3, "\(w)×\(h): low, middle and high notes light three groups")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.004, "\(w)×\(h)")
        }
    }

    func testReefBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(GreatBarrierReefRenderer(device: device))
        // A spawning night (made so: "Tonight"), three hours after sunset, under a burst of 34 notes a frame.
        let state = ThemeState(values: ["spawning": .choice(CoralSpawningSetting.tonight.rawValue), "fish": .number(1)])
        let d = SceneDirector(themeID: GreatBarrierReefModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 21.5))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.9) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? ReefFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.patchCount, GreatBarrierReefRenderer.patchBudget(q))
                XCTAssertLessThanOrEqual(f.patches.count, CoralPulse.cap)
                XCTAssertLessThanOrEqual(r.fishCount, GreatBarrierReefRenderer.fishCapacity)
                XCTAssertLessThanOrEqual(r.beadCount, GreatBarrierReefRenderer.beadBudget(q))
                XCTAssertLessThanOrEqual(r.snowCount, MarineSnow.count(q))
                XCTAssertEqual(r.bufferAllocations, 3, "no buffer made per frame")
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
            XCTAssertGreaterThan(r.beadCount, 0, "\(q): the reef spawns tonight")
        }
        XCTAssertEqual(r.patchCount, GreatBarrierReefRenderer.patchBudget(.high), "a full reef")
        XCTAssertEqual(r.fishCount, GreatBarrierReefRenderer.fishCapacity, "80 in the school, and the chromis")
    }
}

extension WorldPreviewTests {
    func testWriteReefPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let sky = GreatBarrierReefRendererTests.sky
        let east = GreatBarrierReefRendererTests.east
        let shower = ThemeState(values: ["meteors.mode": .choice(MeteorMode.always.rawValue)])
        let spawning = ThemeState(values: ["spawning": .choice(CoralSpawningSetting.tonight.rawValue),
                                           "meteors.mode": .choice(MeteorMode.never.rawValue)])
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("reef-day", sky(10.5, .clear, 0.45), east, .high, 5),
            ("reef-dusk", sky(18.3, .clear, 0.45), east, .high, 5),
            ("reef-night-meteors", sky(22.5, .clear, 0.1), shower, .high, 5),
            ("reef-spawning", sky(21.5, .clear, 0.62), spawning, .high, 5),
            ("reef-storm", sky(14, .storm, 0.45), east, .high, 5),
            ("reef-smooth", sky(10.5, .clear, 0.45), east, .lite, 5),
            ("reef-pulse-t3", sky(11, .clear, 0.45), east, .high, 3),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: GreatBarrierReefModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .reefAlive).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
