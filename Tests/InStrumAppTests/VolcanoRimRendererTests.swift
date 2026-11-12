import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Volcano Rim and Magma Veins (Fire & Neon spec §8, §12; plan Task 12): the crater at night, its lava lake and plume,
/// drawn in one analytic pass with the sparks, the lightning and the basalt columns over it.
@MainActor
final class VolcanoRimRendererTests: XCTestCase {
    // MARK: - Helpers

    /// A frozen night over Melbourne on the previews' fixed date (the world holds the light at deep night itself).
    nonisolated static func sky(hour: Double = 23) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0.1; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    nonisolated static func chord(_ strength: Float, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: true, isDrop: drop)
    }

    struct VolcanoShot {
        var image: CGImage?
        var renderer: VolcanoRimRenderer
        var frame: VolcanoFrame
        var params: ParameterSet
    }

    /// Steps Volcano Rim at 60 fps for `seconds` and renders the last frame. The director runs the Living Sky for the
    /// world; the world itself is stepped here so the tests choose its Excitement: `energy` and `tension` throughout, a
    /// big `moments[i]` on frame `i`, a surprise on frame `i`, `notes(i)` struck on frame `i` (released 12 frames
    /// later). `edit` changes each frame before the renderer sees it; `each` sees every frame after the renderer's update.
    static func renderVolcano(at seconds: Double, hold: SkyHold = .deepNight, values: [String: ParamValue] = [:],
                              quality: QualityLevel = .high, gentle: Bool = false, reduceMotion: Bool = false,
                              energy: Float = 0.3, tension: Float = 0, moments: [Int: BigMoment] = [:],
                              surprises: [Int: WorldSurprise] = [:], notes: ((Int) -> [UInt8])? = nil,
                              width: Int = 640, height: Int = 360, capture: Bool = true,
                              edit: ((Int, inout VolcanoFrame) -> Void)? = nil,
                              each: ((Int, VolcanoRimRenderer, VolcanoFrame) -> Void)? = nil) throws -> VolcanoShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(VolcanoRimRenderer(device: device))
        var stateValues = values
        stateValues["light.hold"] = .choice(hold.rawValue)
        let state = ThemeState(values: stateValues)
        let d = SceneDirector(themeID: VolcanoRimModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky())
        d.mood = .molten
        var model = VolcanoRimModel()
        model.mood = .molten
        let size = CGSize(width: width, height: height)
        let n = max(1, Int((seconds * 60).rounded()))
        var last: VolcanoFrame?
        var releases: [Int: [UInt8]] = [:]
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
            e.surprise = surprises[i]
            model.setExcitement(e)
            for k in releases[i] ?? [] { model.handle(.noteOff(note: k)) }
            if let notes {
                let struck = notes(i)
                for k in struck { model.handle(.noteOn(note: k, velocity: 0.85)) }
                if !struck.isEmpty { releases[i + 12, default: []] += struck }
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
        return VolcanoShot(image: image, renderer: r, frame: frame, params: d.parameters)
    }

    /// Low notes and chords on the beat, runs between, so the cracks, the spits and the columns all show.
    nonisolated static func playing(_ i: Int) -> [UInt8] {
        if i % 40 == 0 { return [33, 40, 45, 52] }
        if i % 10 == 0 { return [UInt8(55 + (i / 10) % 30)] }
        return []
    }

    /// The share of pixels that differ by more than 4% in luminance between two images.
    static func changed(_ a: CGImage, _ b: CGImage) -> Double {
        let la = FramePatch.luminance(a), lb = FramePatch.luminance(b)
        guard la.count == lb.count, !la.isEmpty else { return 0 }
        var n = 0
        for i in 0..<la.count where abs(la[i] - lb[i]) > 0.04 { n += 1 }
        return Double(n) / Double(la.count)
    }

    // MARK: - The shaders

    func testVolcanoShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: VolcanoRimShaders.source, options: nil)
        let names = ["volcano_vertex", "volcano_scene_fragment", "volcano_spark_vertex", "volcano_spark_fragment",
                     "volcano_bolt_vertex", "volcano_bolt_fragment", "volcano_column_vertex", "volcano_column_fragment"]
        for name in names {
            let function = lib.makeFunction(name: name)
            XCTAssertNotNil(function, name)
        }
        let veins = try device.makeLibrary(source: MagmaVeinsShaders.source, options: nil)
        for name in ["veins_vertex", "veins_crust_fragment", "veins_seg_vertex", "veins_seg_fragment"] {
            let function = veins.makeFunction(name: name)
            XCTAssertNotNil(function, name)
        }
        // Built on the Sky kit, with no powers of their own.
        let kit = SkyShaders.common
        for source in [VolcanoRimShaders.source, MagmaVeinsShaders.source] {
            let prefixed = source.hasPrefix(kit)
            XCTAssertTrue(prefixed)
            let own = String(source.dropFirst(kit.count))
            let powers = own.contains("pow(")
            XCTAssertFalse(powers, "squares and powers are written out")
        }
        let own = String(VolcanoRimShaders.source.dropFirst(kit.count))
        let usesSky = own.contains("skyRadiance(")
        XCTAssertTrue(usesSky, "the real sky, with its stars")
        // The Swift rows match the MSL structs byte for byte (the pipelines' own reflection).
        let row = MemoryLayout<SIMD4<Float>>.stride
        func fragmentBytes(_ library: MTLLibrary, _ v: String, _ f: String, index: Int) throws -> Int? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            var reflection: MTLAutoreleasedRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
            let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
            return buffers.first { $0.index == index }?.bufferDataSize
        }
        let skyBytes = try fragmentBytes(lib, "volcano_vertex", "volcano_scene_fragment", index: 0)
        let volBytes = try fragmentBytes(lib, "volcano_vertex", "volcano_scene_fragment", index: 1)
        let veinBytes = try fragmentBytes(veins, "veins_vertex", "veins_crust_fragment", index: 0)
        XCTAssertEqual(skyBytes, SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(volBytes, VolcanoRimRenderer.uniformCount * row, "VolcanoU")
        XCTAssertEqual(veinBytes, MagmaVeinsRenderer.uniformCount * row, "VeinsU")
        let wantVol = VolcanoRimRenderer.uniformCount * row
        XCTAssertLessThanOrEqual(wantVol, 4096, "one setFragmentBytes call")
        typealias R = VolcanoRimRenderer
        XCTAssertEqual(R.cellABase, R.rowRiverA + 1)
        XCTAssertEqual(R.cellBBase, R.cellABase + VolcanoRimModel.cellCount)
        XCTAssertEqual(R.uniformCount, R.cellBBase + VolcanoRimModel.cellCount)
        XCTAssertEqual(MagmaVeinsRenderer.uniformCount, MagmaVeinsRenderer.plateBase + MagmaVeins.plateCount)
        let r = try XCTUnwrap(VolcanoRimRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, R.uniformCount)
        // The columns fit setVertexBytes.
        let columnBytes = 88 * 2 * row
        XCTAssertLessThanOrEqual(columnBytes, 4096)
    }

    // MARK: - The look

    func testVolcanoPreviewIsStructured() throws {
        for q in [QualityLevel.lite, .high] {
            let shot = try Self.renderVolcano(at: 3, quality: q, notes: Self.playing)
            let image = try XCTUnwrap(shot.image)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q): the lake lights the night")
            XCTAssertGreaterThan(s.variance, 0.004, "\(q)")
            // The lake below the middle, in the frame; the far rim above it.
            let lake = shot.renderer.lakeCentreNDC
            let rim = shot.renderer.rimNDC
            XCTAssertLessThan(abs(lake.x), 0.2, "\(q)")
            XCTAssertLessThan(lake.y, -0.1, "\(q)")
            XCTAssertGreaterThan(lake.y, -0.8, "\(q)")
            XCTAssertGreaterThan(rim.y, lake.y + 0.3, "\(q)")
            // The lake is the brightest thing: its band outshines the sky over the rim.
            let lakeBand = FramePatch.meanRGB(image, x: -0.5 ... 0.5, y: -0.6 ... -0.15)
            let skyBand = FramePatch.meanRGB(image, x: -0.9 ... -0.6, y: 0.7 ... 0.95)
            let lakeLum = 0.2126 * lakeBand.x + 0.7152 * lakeBand.y + 0.0722 * lakeBand.z
            let skyLum = 0.2126 * skyBand.x + 0.7152 * skyBand.y + 0.0722 * skyBand.z
            XCTAssertGreaterThan(lakeLum, 2 * skyLum, "\(q)")
            // Lava light is warm: red over green over blue.
            XCTAssertGreaterThan(lakeBand.x, lakeBand.y, "\(q)")
            XCTAssertGreaterThan(lakeBand.y, lakeBand.z, "\(q)")
        }
    }

    func testMomentChangesTheFrame() throws {
        let calm = try Self.renderVolcano(at: 2.4, energy: 0.4)
        let erupting = try Self.renderVolcano(at: 2.4, energy: 0.4, moments: [84: Self.chord(1)])
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(erupting.image)
        let share = Self.changed(a, b)
        XCTAssertGreaterThan(share, 0.02, "the eruption changes the frame")
        XCTAssertNotNil(erupting.frame.eruption)
        XCTAssertGreaterThan(erupting.renderer.sparkCount, calm.renderer.sparkCount, "bombs in the air")
    }

    func testBreachChangesTheFrame() throws {
        let calm = try Self.renderVolcano(at: 9, energy: 0.4)
        let breach = try Self.renderVolcano(at: 9, energy: 0.4, moments: [60: Self.chord(1, drop: true)])
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(breach.image)
        XCTAssertGreaterThan(breach.frame.breach, 0.8)
        let share = Self.changed(a, b)
        XCTAssertGreaterThan(share, 0.005, "the new river shows")
    }

    // MARK: - Flashes, gentle, Reduce Motion

    /// Review focus 1: a hammered minute (a big moment every quarter second, a drop every two, Energy and tension
    /// full, the lightning at its fastest) never flashes more than three times a second.
    func testHammeredMinuteStaysInsideTheFlashLimiter() throws {
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 15, to: 3600, by: 15) { moments[i] = Self.chord(1, drop: i % 120 == 0) }
        var worst = 0, total = 0
        _ = try Self.renderVolcano(at: 60, energy: 1, tension: 1, moments: moments, notes: { i in i % 8 == 0 ? [36, 40, 43, 48] : [] },
                                   width: 160, height: 90, capture: false, each: { _, r, _ in
            worst = max(worst, r.flashesInLastSecond)
            total = r.flashTotal
        })
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
        XCTAssertGreaterThan(total, 0, "it did flash")
        XCTAssertLessThanOrEqual(total, 60 * FlashLimiter.maxFlashesPerSecond)
    }

    func testGentleVisualsNeverFlash() throws {
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 30, to: 600, by: 45) { moments[i] = Self.chord(1, drop: i == 300) }
        var drawn = false, peak: Float = 0, gentlePeak: Float = 0, total = 0
        _ = try Self.renderVolcano(at: 10, energy: 1, moments: moments, width: 160, height: 90, capture: false,
                                   each: { _, r, _ in peak = max(peak, r.lightningLight) })
        _ = try Self.renderVolcano(at: 10, gentle: true, energy: 1, moments: moments, width: 160, height: 90, capture: false,
                                   each: { _, r, _ in
            drawn = drawn || r.channelsDrawn
            gentlePeak = max(gentlePeak, r.lightningLight)
            total = r.flashTotal
        })
        XCTAssertEqual(total, 0, "gentle visuals: glows, never a flash")
        XCTAssertFalse(drawn, "no lightning channels under gentle visuals")
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertLessThanOrEqual(gentlePeak, 0.6 * peak)
    }

    func testReduceMotionNeverShakes() throws {
        var shook = false
        _ = try Self.renderVolcano(at: 2, moments: [30: Self.chord(1)], width: 160, height: 90, capture: false,
                                   each: { _, r, _ in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { shook = true }
        })
        XCTAssertTrue(shook, "an eruption shakes the ground")
        var still = true
        _ = try Self.renderVolcano(at: 2, reduceMotion: true, moments: [30: Self.chord(1)], width: 160, height: 90,
                                   capture: false, each: { _, r, _ in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { still = false }
        })
        XCTAssertTrue(still, "Reduce Motion: no camera shake")
        var smoothStill = true
        _ = try Self.renderVolcano(at: 1, quality: .lite, width: 160, height: 90, capture: false,
                                   edit: { _, f in f.cameraShake = SIMD2(0.1, -0.1) }, each: { _, r, _ in
            let s = r.shakeApplied
            if s.x != 0 || s.y != 0 { smoothStill = false }
        })
        XCTAssertTrue(smoothStill, "Smooth never shakes")
    }

    // MARK: - Pools and buffers

    func testNoBuffersMadePerFrameAndPoolsHold() throws {
        var allocations: Set<Int> = []
        var veinAllocations: Set<Int> = []
        var sparks = 0, bolts = 0, uniforms: Set<Int> = []
        for visual in VolcanoRimModel.visuals {
            _ = try Self.renderVolcano(at: 3, values: ["visual": .choice(visual)], energy: 1, tension: 1,
                                       moments: [20: Self.chord(1, drop: true), 100: Self.chord(1)],
                                       notes: { i in (0..<34).map { k in UInt8(21 + (i * 34 + k) % 88) } },
                                       width: 160, height: 90, capture: false, each: { _, r, _ in
                allocations.insert(r.bufferAllocations)
                veinAllocations.insert(r.veinsRenderer.bufferAllocations)
                sparks = max(sparks, r.sparkCount)
                bolts = max(bolts, r.boltCount)
                uniforms.insert(r.uniforms.count)
            })
        }
        XCTAssertEqual(allocations, [3], "the ring of three, made once")
        XCTAssertEqual(veinAllocations, [3])
        XCTAssertLessThanOrEqual(sparks, VolcanoRimRenderer.sparkCapacity)
        XCTAssertLessThanOrEqual(bolts, VolcanoRimRenderer.boltCapacity)
        XCTAssertEqual(uniforms, [VolcanoRimRenderer.uniformCount])
    }

    // MARK: - Magma Veins

    func testMagmaVeinsDrawsTheChordAndTheSplit() throws {
        let values: [String: ParamValue] = ["visual": .choice("Magma Veins")]
        let shot = try Self.renderVolcano(at: 1.5, values: values, energy: 0.5, moments: [60: Self.chord(0.9)],
                                          notes: { i in i == 60 ? [48, 55, 60, 64] : [] })
        let r = shot.renderer
        XCTAssertTrue(r.showingVeins)
        XCTAssertGreaterThanOrEqual(r.veinsRenderer.veinsDrawn, 4)
        XCTAssertGreaterThanOrEqual(r.veinsRenderer.linksDrawn, 3, "the chord's veins are joined")
        XCTAssertGreaterThan(r.veinsRenderer.shownSplit, 0.5, "the moment splits the plates")
        let image = try XCTUnwrap(shot.image)
        let s = PreviewRenderer.stats(image)
        XCTAssertGreaterThan(s.meanLuminance, 0.03)
        XCTAssertGreaterThan(s.variance, 0.002)
    }

    // MARK: - Aspect

    func testVolcanoFramesAnyAspect() throws {
        let sizes: [(Int, Int)] = [(640, 360), (360, 640), (500, 500), (1280, 540)]
        for (w, h) in sizes {
            let shot = try Self.renderVolcano(at: 1, notes: Self.playing, width: w, height: h)
            let image = try XCTUnwrap(shot.image)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(w)×\(h)")
            let rects = shot.renderer.keyRects
            XCTAssertEqual(rects.count, 88, "\(w)×\(h)")
            for k in rects {
                XCTAssertGreaterThanOrEqual(k.x, -1.0001, "\(w)×\(h)")
                XCTAssertGreaterThanOrEqual(k.y, -1.0001, "\(w)×\(h)")
                XCTAssertLessThanOrEqual(k.z, 1.0001, "\(w)×\(h)")
                XCTAssertLessThanOrEqual(k.w, 1, "\(w)×\(h)")
            }
            let lake = shot.renderer.lakeCentreNDC
            XCTAssertLessThan(abs(lake.x), 1, "\(w)×\(h): the lake in the frame")
            XCTAssertLessThan(abs(lake.y), 1, "\(w)×\(h): the lake in the frame")
        }
    }

    // MARK: - Surprises

    func testSurprisesAllDraw() throws {
        let rows = [VolcanoRimRenderer.rowFireball, VolcanoRimRenderer.rowRockfall, VolcanoRimRenderer.rowSteam,
                    VolcanoRimRenderer.rowSprites, VolcanoRimRenderer.rowTree]
        for kind in VolcanoSurprise.Kind.allCases {
            var seen = false
            _ = try Self.renderVolcano(at: 1, energy: 0.4, surprises: [10: WorldSurprise(index: kind.rawValue, seed: 77)],
                                       width: 160, height: 90, capture: false, each: { i, r, _ in
                if i > 10, i < 40, r.uniforms[rows[kind.rawValue]].x >= 0 { seen = true }
            })
            XCTAssertTrue(seen, "\(kind)")
        }
    }
}

/// The GPU time of a Volcano Rim frame at 1280×720 (the scene pass and the finishing passes), printed for the look
/// job's report (spec §12: ≤ 6 ms at 1 MP on the target Mac; CI's virtual GPU is far slower, so this only reports).
@MainActor
final class VolcanoFrameTimeTests: XCTestCase {
    func testVolcanoFrameTime() throws {
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
            let shot = try VolcanoRimRendererTests.renderVolcano(at: 2, quality: q, energy: 0.8,
                                                                 moments: [100: VolcanoRimRendererTests.chord(1)],
                                                                 notes: VolcanoRimRendererTests.playing,
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
            print(String(format: "FRAME TIME volcano %@ 1280x720: scene %.2f ms, scene+finish %.2f ms (median of %d)",
                         label, sceneMedian, wholeMedian, scene.count))
            XCTAssertGreaterThan(wholeMedian, 0)
        }
    }
}

extension WorldPreviewTests {
    func testWriteVolcanoPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        typealias T = VolcanoRimRendererTests
        func write(_ shot: T.VolcanoShot, _ name: String) throws {
            let image = try XCTUnwrap(shot.image)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Deep night, Energy 0: nobody playing, the lake on its own.
        try write(try T.renderVolcano(at: 6, energy: 0, width: 1280, height: 720), "volcano-night")
        // Energy 1: playing hard, cracks lit across the lake, spits, the fountains high, the embers thick.
        try write(try T.renderVolcano(at: 6, energy: 1, tension: 0.4, notes: T.playing, width: 1280, height: 720),
                  "volcano-energy")
        // Mid-Eruption: the column up, bombs in the air, the lightning cluster, the plume billowing.
        try write(try T.renderVolcano(at: 5.2, energy: 0.8, moments: [240: T.chord(1)], notes: T.playing, width: 1280,
                                      height: 720), "volcano-eruption")
        // After a drop: the breach's new river pouring out across the floor.
        try write(try T.renderVolcano(at: 12, energy: 0.6, moments: [60: T.chord(1, drop: true)], notes: T.playing,
                                      width: 1280, height: 720), "volcano-breach")
        // Smooth.
        try write(try T.renderVolcano(at: 6, quality: .lite, energy: 0.5, notes: T.playing, width: 1280, height: 720),
                  "volcano-smooth")
        // Red sprites over the far storm (a surprise), mid-burst.
        try write(try T.renderVolcano(at: 2.13, energy: 0.3, surprises: [120: WorldSurprise(index: 3, seed: 5)], width: 1280,
                                      height: 720), "volcano-sprites")
        // A rockfall down the inner wall and a steam blast by the other (surprises), mid-way.
        try write(try T.renderVolcano(at: 4.6, energy: 0.4, surprises: [120: WorldSurprise(index: 1, seed: 5),
                                                                         150: WorldSurprise(index: 2, seed: 9)],
                                      width: 1280, height: 720), "volcano-rockfall")
        // Magma Veins: a chord lit, its veins joined.
        try write(try T.renderVolcano(at: 2, values: ["visual": .choice("Magma Veins")], energy: 0.5,
                                      notes: { i in i == 80 ? [45, 52, 57, 60, 64] : (i % 30 == 0 ? [UInt8(62 + (i / 30) % 20)] : []) },
                                      width: 1280, height: 720), "magma-veins")
    }
}
