import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// Submarine Window (Set 11's world) with Deep Lights: the sea at the Depth through a brass porthole, the living light
/// and the marine snow in it, and the cabin round it.
@MainActor
final class SubmarineWindowRendererTests: XCTestCase {
    func testSubShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SubmarineWindowShaders.source, options: nil)
        for name in ["sub_full_vertex", "sub_sea_fragment", "sub_sprite_vertex", "sub_sprite_fragment", "sub_cabin_fragment",
                     "sub_keys_vertex", "sub_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(SubmarineWindowShaders.source.dropFirst(SkyShaders.common.count + UnderwaterShaders.common.count))
        XCTAssertTrue(own.contains("struct SubU"), "the world's own source follows the kits'")
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        // The Swift rows match the MSL structs byte for byte (the pipeline's own reflection says so).
        func buffers(_ v: String, _ f: String) throws -> [MTLBufferBinding] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            var reflection: MTLAutoreleasedRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
            return (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        }
        let row = MemoryLayout<SIMD4<Float>>.stride
        let sea = try buffers("sub_full_vertex", "sub_sea_fragment")
        XCTAssertEqual(sea.first(where: { $0.index == 0 })?.bufferDataSize, SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(sea.first(where: { $0.index == 1 })?.bufferDataSize, SubmarineWindowRenderer.uniformCount * row, "SubU")
        let cabin = try buffers("sub_full_vertex", "sub_cabin_fragment")
        XCTAssertEqual(cabin.first(where: { $0.index == 1 })?.bufferDataSize, SubmarineWindowRenderer.uniformCount * row, "SubU")
        XCTAssertEqual(SubmarineWindowRenderer.blipBase + 24, SubmarineWindowRenderer.uniformCount, "the 24 blips last")
        XCTAssertEqual(MemoryLayout<SubmarineWindowRenderer.Sprite>.stride, 32, "a sprite is two float4s")
        let r = try XCTUnwrap(SubmarineWindowRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, SubmarineWindowRenderer.uniformCount)
        XCTAssertEqual(r.bufferAllocations, 3, "the sprites' ring of three, made once")
        // The budget holds the most a frame can send: Ultra's snow, every creature, the shoals, the siphonophores, the
        // bubbles and the fish.
        let most = MarineSnow.capacity + DeepLights.cap + DeepLights.shoalCap * DeepLights.shoalLights
            + DeepLights.siphonophoreCap * 24 + DeepLights.streamCap * SubmarineWindowRenderer.bubblesPerStream
            + SubmarineWindowRenderer.fishCount
        XCTAssertLessThanOrEqual(most, SubmarineWindowRenderer.spriteCapacity)
    }

    /// Frozen Melbourne skies (the equinox's: the sun rises about 7:24 and is 50° up at 13:30); a new moon unless given.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.05) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    nonisolated static func depth(_ d: Double, lamps: Double? = nil, visual: String? = nil) -> ThemeState {
        var values: [String: ParamValue] = ["depth": .number(d)]
        if let lamps { values["lamps"] = .number(lamps) }
        if let visual { values["visual"] = .choice(visual) }
        return ThemeState(values: values)
    }

    struct SubShot {
        var image: CGImage
        var renderer: SubmarineWindowRenderer
        var frame: SubFrame
        var params: ParameterSet
    }

    /// Steps the submarine at 60 fps (notes go down at 0.5 s and stay held, unless `release`) and renders the frame at
    /// `seconds`; `edit` changes each frame before the renderer sees it.
    static func renderSub(notes: [UInt8] = [], velocity: Float = 0.8, release: Bool = false, at seconds: Double,
                          state: ThemeState = SubmarineWindowRendererTests.depth(0.35),
                          sky: SkySettings = SubmarineWindowRendererTests.sky(hour: 13.5),
                          quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                          edit: ((inout SubFrame) -> Void)? = nil,
                          each: ((SubmarineWindowRenderer, SubFrame) -> Void)? = nil) throws -> SubShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(SubmarineWindowRenderer(device: device))
        XCTAssertTrue(r.awaitStars(), "the real stars for Snell's window")
        let d = SceneDirector(themeID: SubmarineWindowModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .deepHush
        var frame: SubFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            if i == 33, release, !notes.isEmpty { d.handle(notes.map { .noteOff(note: $0) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? SubFrame
            if let edit, frame != nil { edit(&frame!) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return SubShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f, params: d.parameters)
    }

    private struct LightCase { let name: String; let state: ThemeState; let sky: SkySettings; let mean: Double; let variance: Double }

    /// Structured at every depth, by day and night, in a storm and in sea smoke: never blank, never flat. The CPU
    /// reference render (the shaders through the MSL shim, 640×360) measured means 0.134 (15 m by day), 0.077 (65 m),
    /// 0.047 (1,000 m), 0.016 (65 m at night), 0.085 (a storm) and 0.105 (sea smoke): the floors leave room for the bloom.
    func testSubPreviewIsStructured() throws {
        let cases = [
            LightCase(name: "15 m, day", state: Self.depth(0), sky: Self.sky(hour: 13.5), mean: 0.05, variance: 0.004),
            LightCase(name: "65 m, day", state: Self.depth(0.35), sky: Self.sky(hour: 13.5), mean: 0.025, variance: 0.0015),
            LightCase(name: "1,000 m, day", state: Self.depth(1, lamps: 0.6), sky: Self.sky(hour: 13.5), mean: 0.012, variance: 0.0008),
            LightCase(name: "15 m, night", state: Self.depth(0), sky: Self.sky(hour: 23, phase: 0.5), mean: 0.004, variance: 0.0002),
            LightCase(name: "65 m, night", state: Self.depth(0.35), sky: Self.sky(hour: 23), mean: 0.004, variance: 0.0002),
            LightCase(name: "storm", state: Self.depth(0.05), sky: Self.sky(hour: 13.5, weather: .storm), mean: 0.02, variance: 0.001),
            LightCase(name: "sea smoke", state: Self.depth(0.04), sky: Self.sky(hour: 8, weather: .seaSmoke), mean: 0.03, variance: 0.002),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try Self.renderSub(notes: [36, 60, 64, 67, 84], at: 1.5, state: c.state, sky: c.sky, quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(shot.renderer.creatureCount, 5, "\(q) \(c.name): every note's creature")
            }
        }
        // The sky is felt: by day in the shallows the glass is far brighter than the cabin's wall round it, and the
        // light from above falls off with depth.
        func glass(_ shot: SubShot) -> Double {
            let c = shot.renderer.frameLayout.centre
            let r: Double = Double(shot.renderer.frameLayout.radius) * 0.5
            let rx: Double = r * 360 / 640
            let x: ClosedRange<Double> = (Double(c.x) - rx)...(Double(c.x) + rx)
            let y: ClosedRange<Double> = (Double(c.y) - r)...(Double(c.y) + r)
            return FramePatch.meanRGB(shot.image, x: x, y: y).sum() / 3
        }
        let shallow = try Self.renderSub(at: 1, state: Self.depth(0)), mid = try Self.renderSub(at: 1, state: Self.depth(0.35))
        let lay = shallow.renderer.frameLayout
        let wallX: Double = Double(lay.centre.x) - Double(lay.outer + 0.1) * 360 / 640
        let wallSpan: ClosedRange<Double> = max(-1, wallX - 0.1)...wallX
        let wall = FramePatch.meanRGB(shallow.image, x: wallSpan, y: -0.2...0.2).sum() / 3
        XCTAssertGreaterThan(glass(shallow), 2 * wall, "the sea lights the porthole: \(glass(shallow)) against the wall's \(wall)")
        XCTAssertGreaterThan(glass(shallow), glass(mid), "dimmer at 65 m")
        XCTAssertGreaterThan(shallow.frame.snellVisible, 0.9, "Snell's window shows at 15 m")
        XCTAssertEqual(mid.frame.snellVisible, 0, "and is gone by 65 m")
    }

    /// Spec §8.2: each note releases a creature into the window, lit where it is: the light around each creature's
    /// sprite is well above the same place with no notes (at night, 65 m down, where only living light shows).
    func testNotesLightCreaturesInTheWindow() throws {
        let night = Self.sky(hour: 23)
        let lit = try Self.renderSub(notes: [36, 60, 84], at: 1.2, sky: night)
        let dark = try Self.renderSub(at: 1.2, sky: night)
        XCTAssertEqual(lit.renderer.creatureCount, 3)
        XCTAssertEqual(lit.frame.creatures.map(\.kind), [.jelly, .combJelly, .speck])
        XCTAssertEqual(dark.renderer.creatureCount, 0)
        XCTAssertGreaterThan(lit.renderer.glowOut, 0.9, "three creatures are far from a flash")
        let aspect = 640.0 / 360
        for c in lit.renderer.creatureSprites {
            let r: Double = Double(c.radius) * 0.4
            let cx = Double(c.centre.x), cy = Double(c.centre.y)
            let x: ClosedRange<Double> = (cx - r / aspect)...(cx + r / aspect)
            let y: ClosedRange<Double> = (cy - r)...(cy + r)
            let on = FramePatch.brightest(lit.image, x: x, y: y, share: 0.2), off = FramePatch.brightest(dark.image, x: x, y: y, share: 0.2)
            XCTAssertGreaterThan(on, off + 0.05, "a creature at \(c.centre): \(off) → \(on)")
        }
        // Each sits inside the glass, as high as its pitch: the bass low, the treble high.
        let ys = lit.renderer.creatureSprites.map { $0.centre.y }
        XCTAssertTrue(ys[0] < ys[1] && ys[1] < ys[2], "\(ys)")
        let lay = lit.renderer.frameLayout
        for c in lit.renderer.creatureSprites {
            let q = (c.centre - lay.centre) * SIMD2(Float(aspect), 1)
            XCTAssertLessThan(simd_length(q), lay.radius, "inside the glass")
        }
    }

    /// Spec §8.1: the outside lamps light a cone of marine snow: with the lamps up, the brightest flecks in the beams
    /// are lit and the lower glass (where the beams reach in) is brighter than with the lamps off, deep down.
    func testLampsLightTheSnow() throws {
        let on = try Self.renderSub(at: 1, state: Self.depth(1, lamps: 1))
        let off = try Self.renderSub(at: 1, state: Self.depth(1, lamps: 0))
        XCTAssertGreaterThan(on.renderer.snowCount, 50, "the snow drifts in the lamps")
        XCTAssertGreaterThan(on.renderer.snowLampPeak, 0.2)
        XCTAssertEqual(off.renderer.snowLampPeak, 0)
        let lay = on.renderer.frameLayout
        let half: Double = Double(lay.radius) * 0.6 * 360 / 640
        let x: ClosedRange<Double> = (Double(lay.centre.x) - half)...(Double(lay.centre.x) + half)
        let y: ClosedRange<Double> = Double(lay.centre.y - lay.radius * 0.85)...Double(lay.centre.y - lay.radius * 0.3)
        let lampLit = FramePatch.meanRGB(on.image, x: x, y: y).sum() / 3, dark = FramePatch.meanRGB(off.image, x: x, y: y).sum() / 3
        XCTAssertGreaterThan(lampLit, dark + 0.01, "the beams and the snow in them: \(dark) → \(lampLit)")
        XCTAssertLessThan(SubmarineWindowRenderer.lampLight(SIMD2(0, 2.5)), 0.1, "the beams fade out far up the glass")
        XCTAssertGreaterThan(SubmarineWindowRenderer.lampLight(SIMD2(-0.75, -0.7)), SubmarineWindowRenderer.lampLight(SIMD2(0.3, 0.8)))
    }

    /// Gentle visuals halve the living light (and the flash limiter halves its rises), and calm the console buttons.
    func testSubHonoursGentleVisuals() throws {
        var plain: Float = 0, gentle: Float = 0
        _ = try Self.renderSub(notes: [55, 60, 64, 67, 72], at: 1.5, sky: Self.sky(hour: 23), each: { r, _ in plain = max(plain, r.glowOut) })
        _ = try Self.renderSub(notes: [55, 60, 64, 67, 72], at: 1.5, sky: Self.sky(hour: 23), gentle: true,
                               each: { r, _ in gentle = max(gentle, r.glowOut) })
        XCTAssertGreaterThan(plain, 0.9)
        XCTAssertLessThanOrEqual(gentle, plain * 0.55, "gentle visuals calm it")
    }

    /// Spec §8.2 and the flash rules: a field of creatures blinking on Blue Depth's arp grid never strobes the window. The
    /// lit area the limiter sees never rises by more than `FlashLimiter.flashRise` within its window more than
    /// `maxFlashesPerSecond` times a second, after the limiter.
    func testDeepLightsBlinkThroughTheFlashLimiter() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(SubmarineWindowRenderer(device: device))
        let d = SceneDirector(themeID: SubmarineWindowModel.id, state: Self.depth(0.35), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 23))
        d.instrumentPulse = InstrumentPulse(bpm: 160, gate: 1)   // the hardest blink there is
        let size = CGSize(width: 320, height: 180)
        var history: [(t: Double, v: Float)] = [], rises: [Double] = []
        var peak: Float = 0
        var most = 0
        var clock = 0.0   // the limiter's own clock: the sum of the frames' dt
        for i in 1...360 {
            let t = Double(i) / 60
            clock += 1.0 / 60
            if i == 6 { d.handle((48...95).map { .noteOn(note: UInt8($0), velocity: 1) }, at: t) }   // 48 comb jellies and specks
            let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: .high) as? SubFrame)
            r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            most = max(most, f.creatures.count)
            let shown = r.livingLevel * r.glowOut
            peak = max(peak, r.livingLevel)
            history.append((clock, shown))
            history.removeAll { clock - $0.t > FlashLimiter.window }
            if let first = history.first, shown - first.v > FlashLimiter.flashRise,
               rises.last.map({ clock - $0 > FlashLimiter.window }) ?? true {
                rises.append(clock)
            }
            let lastSecond = rises.filter { clock - $0 < 1 }.count
            XCTAssertLessThanOrEqual(lastSecond, FlashLimiter.maxFlashesPerSecond, "at \(t) s")
        }
        XCTAssertGreaterThan(peak, 2 * FlashLimiter.flashRise, "the field is big enough to need the limiter")
        XCTAssertGreaterThan(most, 40, "a full window")
    }

    /// Any aspect: the keys stay inside the frame, the porthole and its ring stand clear of the screen's edges and the
    /// console, and the gauge and the sonar sit on screen beside it, never over its ring.
    func testSubFramesAnyAspect() throws {
        for (w, h) in [(640, 360), (864, 360), (360, 360), (480, 360)] {
            let shot = try Self.renderSub(notes: [21, 60, 64, 67, 108], at: 1.2, width: w, height: h)
            let r = shot.renderer
            let aspect = Float(w) / Float(h)
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            let lay = r.frameLayout
            let c = lay.centre * SIMD2(aspect, 1)
            XCTAssertGreaterThan(c.x - lay.outer, -aspect, "\(w)×\(h): the ring clear of the left edge")
            XCTAssertLessThan(c.y + lay.outer, 1, "\(w)×\(h): and the top")
            XCTAssertGreaterThan(c.y - lay.outer, lay.consoleTop, "\(w)×\(h): and the console")
            XCTAssertGreaterThan(lay.consoleTop, keyTop, "\(w)×\(h): the console's edge over the keys")
            XCTAssertGreaterThan(lay.radius, 0.45, "\(w)×\(h): a big round viewport")
            for (name, centre, radius) in [("gauge", lay.gauge, lay.gaugeRadius * 1.18), ("sonar", lay.sonar, lay.sonarRadius * 1.14)] {
                let p = centre * SIMD2(aspect, 1)
                let across: Bool = p.x - radius > -aspect && p.x + radius < aspect
                let upDown: Bool = p.y - radius > lay.consoleTop && p.y + radius < 1
                XCTAssertTrue(across && upDown, "\(w)×\(h): the \(name) on screen at \(p)")
                XCTAssertGreaterThan(simd_length(p - c), lay.outer + radius, "\(w)×\(h): the \(name) clear of the ring")
            }
            XCTAssertGreaterThan(simd_length(lay.gauge * SIMD2(aspect, 1) - lay.sonar * SIMD2(aspect, 1)),
                                 lay.gaugeRadius * 1.18 + lay.sonarRadius * 1.14, "\(w)×\(h): gauge and sonar apart")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.002, "\(w)×\(h)")
        }
    }

    /// A storm of notes: 34 a frame for a second, at both qualities. The creatures, shoals, bells and bubbles stay inside
    /// their caps, the sprites inside the ring's buffers (never a new one), and each frame is quick.
    func testSubBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SubmarineWindowRenderer(device: device))
        let d = SceneDirector(themeID: SubmarineWindowModel.id, state: Self.depth(0.35), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 23))
        for q in [QualityLevel.lite, .high, .ultra] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.95) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? SubFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.creatureCount, SubmarineWindowRenderer.creatureBudget(q))
                XCTAssertLessThanOrEqual(f.creatures.count, DeepLights.cap)
                XCTAssertLessThanOrEqual(f.shoals.count, DeepLights.shoalCap)
                XCTAssertLessThanOrEqual(f.siphonophores.count, DeepLights.siphonophoreCap)
                XCTAssertLessThanOrEqual(f.bubbleStreams.count, DeepLights.streamCap)
                XCTAssertLessThanOrEqual(r.spriteList.count, SubmarineWindowRenderer.spriteCapacity)
                XCTAssertEqual(r.bufferAllocations, 3, "never a buffer per frame")
                XCTAssertLessThanOrEqual(r.glowOut, 1)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.bubbleCount, 0, "the accents raise bubbles")
        XCTAssertGreaterThan(r.shoalLightCount + r.bellCount, 0, "and runs and chords send their shoals and chains")
    }

    /// Notes played while time is held (a step of dt 0) light their creatures at once, at their full glow.
    func testDeepLightsBloomInTheWindowWhileTimeIsHeld() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(SubmarineWindowRenderer(device: device))
        let d = SceneDirector(themeID: SubmarineWindowModel.id, state: Self.depth(0.35), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 23))
        let size = CGSize(width: 320, height: 180)
        for i in 1...30 {
            let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: Double(i) / 60, quality: .high) as? SubFrame)
            r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        }
        d.handle([60, 64, 67].map { .noteOn(note: $0, velocity: 0.8) }, at: 0.5)
        let f = try XCTUnwrap(d.step(dt: 0, t: 0.5, quality: .high) as? SubFrame)
        r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 0, size: size)
        XCTAssertEqual(r.creatureCount, 3)
        XCTAssertTrue(f.creatures.allSatisfy { $0.glow > 0.5 }, "lit at once: \(f.creatures.map(\.glow))")
        XCTAssertTrue(r.creatureSprites.allSatisfy { $0.glow > 0.5 }, "and drawn so")
        XCTAssertEqual(f.siphonophores.first?.level ?? 0, 1, "the chord's siphonophore at its full swell")
    }
}

extension SubmarineWindowRenderer {
    /// Waits (running the main run loop) until the real star texture is built; for previews and tests.
    func awaitStars(timeout: TimeInterval = 5) -> Bool { StarTextureCache.shared.awaitTexture(timeout: timeout) }
}

extension WorldPreviewTests {
    /// Submarine Window's previews: the sunlit shallows, the default 65 m, the midnight zone in the lamps, red night
    /// lighting, a storm and sea smoke from below, Smooth, and Deep Lights at 3 s after the demo's notes.
    func testWriteSubPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let sky = SubmarineWindowRendererTests.sky, depth = SubmarineWindowRendererTests.depth
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("sub-sunlit", sky(13.5, .clear, 0.05), depth(0, nil, nil), .high, 5),
            ("sub-default", sky(13.5, .clear, 0.05), depth(0.35, nil, nil), .high, 5),
            ("sub-midnight", sky(13.5, .clear, 0.05), depth(1, 0.7, nil), .high, 5),
            ("sub-night-red", sky(23, .clear, 0.5), depth(0.35, nil, nil), .high, 5),
            ("sub-storm", sky(13.5, .storm, 0.05), depth(0.04, nil, nil), .high, 5),
            ("sub-sea-smoke", sky(8, .seaSmoke, 0.05), depth(0.03, nil, nil), .high, 5),
            ("sub-smooth", sky(13.5, .clear, 0.05), depth(0.2, nil, nil), .lite, 5),
            ("sub-lights-t3", sky(23, .clear, 0.05), depth(0.5, nil, nil), .high, 3),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: SubmarineWindowModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .deepHush).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}
