import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Snowbound Cabin Window (spec §8.1, §7.4): the Living Sky and a snowy valley through a three-by-two log
/// window (Galaxy Warp over the sky when chosen), snow outside, the Window Kit's frosted glass with the notes'
/// warm patches, the frame, the fire-lit room with its sill, and ember-amber keys.
///
/// Excitement (Fire & Neon spec §5.5): the fire's roar lights the room through the scene's `FlashLimiter` (a glow under
/// gentle visuals) and the snow whirls past the glass (the weather's snow and wind, the model's, and an eddy of near
/// flakes in the sparks' pool); an owl on the sill and a star through a break in the clouds are drawn in the outside
/// pass; the aurora's edge is the shared sky's. Four uniform rows, a fixed pool of 40 whirling flakes.
final class SnowboundCabinRenderer {
    /// Warm patches sent to the glass (fewer on Smooth).
    static func patchBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }
    static let maxSparks = 36
    /// The near flakes whirling past the glass in a moment (a fixed count, placed afresh each frame).
    static let whirlFlakes = 40
    /// CabinU's rows: 8, the 19 bars, then the owl (two rows), the star and the roar.
    nonisolated static let rowOwl = 27, rowOwl2 = 28, rowStar = 29, rowRoar = 30
    nonisolated static let uniformCount = 31
    static let fieldSeed: UInt64 = 0xCAB1

    /// The window: three panes by two in log wood, filling about 70% of the frame, never wider than about 1.8:1.
    static func window(aspect: Float, keyTop: Float) -> WindowSpec {
        let frameWidth: Float = 0.05
        let bottom = keyTop + 0.2
        let top = min(0.86, 0.97 - frameWidth * aspect)
        let width = min(1.64, 1.8 * (top - bottom) / max(aspect, 0.2))
        return WindowSpec(columns: 3, rows: 2, bar: 0.018, rect: SIMD4(-width / 2, bottom, width / 2, top),
                          material: .logWood, frameWidth: frameWidth)
    }

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    let glass: WindowGlassLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let sparks, room, keys: MTLRenderPipelineState
    private var cabinU = [SIMD4<Float>](repeating: .zero, count: SnowboundCabinRenderer.uniformCount)
    private var keyInstances: [KeyInstance] = []
    private var sparkInstances: [SIMD4<Float>] = []
    private var sparkList: [(x: Float, y: Float, age: Float, life: Float, size: Float)] = []
    private var rng = SeededRandom(seed: 0xCAB1_5)
    private var limiter = FlashLimiter()
    private var quality: QualityLevel = .high
    private(set) var post = PostSettings()
    /// The fire's flare and the glass glints after the flash limiter (gentle visuals halve them).
    private(set) var flareOut: Float = 0
    private(set) var glintOut: Float = 0
    /// Warm patches drawn this frame.
    private(set) var patchCount = 0
    private var primed = false
    private var roarGlow = ExcitementGlow()
    private var whirlClock: Float = 0
    /// Excitement as drawn (tests read them): the roar's light after the limiter and what it asked for, the whirling
    /// flakes drawn, whether the owl and the star are in view.
    private(set) var roarOut: Float = 0
    private(set) var roarRequest: Float = 0
    private(set) var whirlCount = 0
    private(set) var owlShown = false
    private(set) var starShown = false
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }
    /// The shader's rows (tests read them).
    var uniforms: [SIMD4<Float>] { cabinU }
    /// The glass in NDC (x0, y0, x1, y1).
    private(set) var windowRect = SIMD4<Float>(-0.7, -0.5, 0.7, 0.86)
    /// The keys' rectangles in NDC (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let g = WindowGlassLayer(device: device),
              let lib = ShaderCache.library(device, source: SnowboundCabinShaders.source) else { return nil }
        enum Blend { case opaque, premultiplied, additive }
        func make(_ v: String, _ f: String, _ blend: Blend, writesDepth: Bool = true, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            let c = d.colorAttachments[0]!
            switch blend {
            case .opaque: break
            case .premultiplied:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            if !writesDepth { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let sc = SkyPipeline(build: { make("cabin_glass_vertex", "cabin_scene_fragment", .premultiplied, storms: $0) }),
              let sp = make("cabin_spark_vertex", "cabin_spark_fragment", .additive, writesDepth: false),
              let rm = make("cabin_full_vertex", "cabin_room_fragment", .opaque),
              let k = make("cabin_keys_vertex", "cabin_keys_fragment", .opaque) else { return nil }
        sky = s; weather = w; warp = gw; glass = g; scene = sc; sparks = sp; room = rm; keys = k
        sky.verticalFOV = 50
        // The frost grows once, off the main thread; the glass draws a plain fallback until it's ready.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let field = FrostField(seed: Self.fieldSeed, columns: 3, rows: 2, bar: 0.018)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.glass.setField(field) } }
        }
    }

    /// Waits (running the main run loop) until the frost field has grown; for previews and tests.
    @discardableResult
    func awaitField(timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !glass.hasField, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return glass.hasField
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// The fire's colour: a warm orange, deepening toward ember for minor chords and brightening to gold for major.
    static func fireColour(flare: Float, warm: Float) -> SIMD3<Float> {
        let base = SIMD3<Float>(1.0, 0.52, 0.2)
        let ember = SIMD3<Float>(1.0, 0.36, 0.12), gold = SIMD3<Float>(1.0, 0.7, 0.32)
        let tint = ember + (gold - ember) * min(max(warm, 0), 1)
        return base + (tint - base) * min(1, flare)
    }

    func update(_ frame: CabinFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        self.quality = quality
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(min(max(dt, 0), 0.1))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let spec = Self.window(aspect: aspect, keyTop: keyTop)
        windowRect = spec.rect
        let horizonY = spec.rect.y + (spec.rect.w - spec.rect.y) * 0.3

        sky.horizonY = horizonY
        sky.viewAzimuth = nil
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .ground(horizonY: horizonY))
        showWarp = frame.warp != nil
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (spec.rect.w - horizonY) * 0.5)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        // Light: night, the fire (flickering, flared by chords through the limiter), the sun or moon outside.
        let night = Float(1 - Self.smooth(-8, -2, s.sun.altitude))
        let sunUp = Float(Self.smooth(-3, 6, s.sun.altitude))
        let moonUp = Float(Self.smooth(-2, 6, s.moon.altitude)) * Float(s.moonLit)
        limiter.gentle = gentle
        let mood = frame.mood
        let exposure = MoodLook.exposure(mood) * (1 + 0.5 * night) * weather.exposureBoost
        // The roar's light rides on the exposure, through the limiter (primed on the room's own exposure, so arriving is
        // never a flash); under gentle visuals it is a glow.
        if !primed {
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: exposure, sparkle: 1, dt: 1) }
        }
        let request = ExcitementGlow.unit(frame.roar)
        let asked = ExcitementGlow.ask(request, gentle: gentle, scale: 0.2)
        let limited = limiter.limit(exposure: exposure * (1 + asked), sparkle: 1, dt: dt)
        let passed = ExcitementGlow.passed(limited: limited.exposure, base: exposure, asked: asked)
        roarRequest = request
        roarOut = roarGlow.update(request: request, passed: passed, gentle: gentle, dt: dt)
        flareOut = max(min(1, frame.flare) * limited.sparkle, roarOut)
        glintOut = limited.sparkle * (0.6 + 0.4 * flareOut)
        let fireSetting = Float(p.number("fire"))
        let fire = fireSetting * frame.fireFlicker * (1 + 0.6 * roarOut)
        let fireCol = Self.fireColour(flare: flareOut, warm: frame.flareWarm)
        let outside = (s.zenith + s.horizon) * 0.55 + SIMD3<Float>(repeating: 0.25 * sunUp)

        // The glass: frost from Frost Grow with its warm patches (radii from the window's height to its width).
        let glassW = spec.rect.z - spec.rect.x, glassH = spec.rect.w - spec.rect.y
        let toWidth = glassH / max(glassW * aspect, 1e-3)
        let visible = FrostGrow.visible(frame.patches, limit: Self.patchBudget(quality))
        patchCount = visible.count
        let patches = visible.map { GlassPatch(x: $0.x, y: $0.y, radius: $0.radius * toWidth, warmth: $0.warmth) }
        let roomLight = fireCol * (fire * (1 + 0.8 * flareOut) * (0.35 + 0.65 * night))
        glass.update(spec: spec, frost: frame.frostLevel, patches: patches, condensation: Float(p.number("condensation")),
                     wetDrips: 0, snow: s.snow, reflection: SIMD4(fireCol, 0.07 * night * fire),
                     glint: SIMD4(roomLight, max(sunUp, 0.5 * moonUp)), quality: quality, dt: dt,
                     outsideLight: outside, aspect: aspect, sparkle: glintOut)

        // High notes: flakes just outside the glass catch the light near their key, twinkling for under a second.
        for gx in frame.flakeGlints.prefix(12) {
            for _ in 0..<3 where sparkList.count < Self.maxSparks {
                let x = spec.rect.x + glassW * min(max(gx + rng.range(-0.04, 0.04), 0), 1)
                let y = horizonY + (spec.rect.w - horizonY) * rng.range(0.05, 0.9)
                sparkList.append((x, y, 0, rng.range(0.5, 0.9), rng.range(0.008, 0.016)))
            }
        }
        sparkInstances.removeAll(keepingCapacity: true)
        whirlCount = 0
        whirlClock += fdt
        if whirlClock > 3600 { whirlClock -= 3600 }
        let whirl = ExcitementGlow.unit(frame.whirl) * (frame.reduceMotion ? 0.5 : 1)
        if whirl > 0.01 {
            // The eddy: near flakes streaming across the glass on the wind, looping as they go, lit by the fire and the sky.
            let lit: Float = (0.35 + 0.65 * max(night, 0.3)) * limited.sparkle
            let paneTop = spec.rect.w
            for k in 0..<Self.whirlFlakes {
                let fk = Float(k)
                let h1 = Self.hash(fk * 1.37 + 0.11), h2 = Self.hash(fk * 2.71 + 0.53)
                let h3 = Self.hash(fk * 3.19 + 0.97), h4 = Self.hash(fk * 4.43 + 0.29)
                let run = (h2 + whirlClock * (0.35 + 0.45 * h3)).truncatingRemainder(dividingBy: 1)
                let x = spec.rect.x - 0.05 + (glassW + 0.1) * run
                let loop = 0.05 * sin(whirlClock * (2.5 + 2 * h1) + 6.28 * h4)
                let y = horizonY + (paneTop - horizonY) * (0.08 + 0.85 * h4) + loop
                let edges: Float = min(1, run * 8) * min(1, (1 - run) * 8)
                let bright: Float = whirl * lit * (0.4 + 0.6 * h1) * edges
                guard bright > 0.004 else { continue }
                sparkInstances.append(SIMD4(x, y, 0.006 + 0.008 * h3, bright))
                whirlCount += 1
            }
        }
        sparkList = sparkList.compactMap { sp in
            var sp = sp
            sp.age += fdt
            guard sp.age < sp.life else { return nil }
            let k = sp.age / sp.life
            let env = min(1, k * 6) * (1 - k) * (1 - k)
            let bright: Float = env * (0.4 + 0.6 * max(night, 0.3)) * limited.sparkle
            sparkInstances.append(SIMD4(sp.x, sp.y - 0.03 * k, sp.size, bright))
            return sp
        }

        // Uniforms for the outside, the sparks, the room and the keys.
        let farLight: Float = frame.farCabinLit ? Float(p.number("farCabin")) : 0
        let hour = s.hourOfDay
        let smoke: Float = Float(p.number("farCabin")) * (hour >= 1 && hour < 5 ? 0.3 : 1)
        cabinU[0] = SIMD4(keyTop, aspect, horizonY, time)
        cabinU[1] = spec.rect
        cabinU[2] = SIMD4(night, fire, flareOut, frame.flareWarm)
        cabinU[3] = SIMD4(farLight, smoke, s.wind, s.mist)
        let qualityCode: Float = quality == .lite ? 0 : 1
        cabinU[4] = SIMD4(spec.frameWidth, 0.13, qualityCode, limited.sparkle)
        cabinU[5] = SIMD4(outside, s.snow)
        let ft = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let wobble: Float = sin(ft * 11.3) * sin(ft * 4.1 + 1)
        let candle: Float = 0.5 + 0.5 * wobble
        cabinU[6] = SIMD4(fireCol, candle)
        let bars = spec.bars()
        cabinU[7] = SIMD4(Float(min(19, bars.count)), 0, 0, 0)
        for i in 0..<19 { cabinU[8 + i] = i < bars.count ? bars[i] : .zero }
        updateSurprises(frame, spec: spec, horizonY: horizonY, size: size)
        cabinU[Self.rowRoar] = SIMD4(roarOut, whirl, ExcitementGlow.unit(frame.gather), 0)

        // Keys: dark wood-black keys in the firelight, ember amber where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottomY: Float = -0.995, gap: Float = 0.0015
            let light = max(sunUp, 0.4 * moonUp) * 0.3
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottomY) * 0.62 : bottomY
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.5, bloomThreshold: 1.0,
            dof: quality == .lite ? 0 : 0.08, focusDepth: 0.05,
            grade: 0, grain: 0.02, vignette: 0.35,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.06 * night,
            time: time, quality: quality)
    }

    /// A number in 0..<1 from `x` (the shader's own hash, for the whirling flakes' places).
    nonisolated static func hash(_ x: Float) -> Float {
        let v = sin(x * 127.1 + 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    /// The owl's rows (on the drift at the foot of the glass: swooping in from above, perched, turning its head and
    /// blinking, then dropping away) and the star's (high in the window's sky, the cloud parting round it).
    private func updateSurprises(_ frame: CabinFrame, spec: WindowSpec, horizonY: Float, size: CGSize) {
        let glassW = spec.rect.z - spec.rect.x, glassH = spec.rect.w - spec.rect.y
        cabinU[Self.rowOwl] = .zero
        cabinU[Self.rowOwl2] = .zero
        cabinU[Self.rowStar] = SIMD4(0, 0, 0, 2 / Float(max(1, size.height)))
        owlShown = false
        starShown = false
        for s in frame.surprises {
            let age = s.age
            switch s.index {
            case 0:
                let side: Float = s.unit(0) < 0.5 ? -1 : 1
                let arrive = 1 - ExcitementPlay.smooth(0, 0.9, age)
                let leave = ExcitementPlay.smooth(s.duration - 1.2, s.duration, age)
                let perchX: Float = spec.rect.x + glassW * (0.22 + 0.56 * s.unit(1))
                // It settles out of the dark onto the drift (a short drop as it comes in, fading up), and at the end
                // lifts off and is gone into the night the same way: no sliding across the glass.
                let x: Float = perchX + side * (0.04 * leave - 0.03 * arrive)
                let perchY: Float = spec.rect.y + glassH * 0.028
                let y: Float = perchY + glassH * (0.06 * arrive + 0.05 * leave)
                let shown = (1 - arrive) * (1 - leave)
                let height = 0.19 * glassH
                let turn = 0.8 * sin(age * 0.9 + 6.28 * s.unit(2)) * ExcitementPlay.smooth(1.4, 2.2, age)
                func bump(_ at: Float) -> Float { max(0, 1 - abs(age - at) / 0.09) }
                let blink = max(bump(3.1), bump(6.3))
                cabinU[Self.rowOwl] = SIMD4(x, y, height, 1)
                cabinU[Self.rowOwl2] = SIMD4(turn, blink, shown, 0)
                owlShown = true
            case 2:
                let env = ExcitementPlay.envelope(age: age, life: s.duration, rise: 2, fall: 3)
                let x = spec.rect.x + glassW * (0.25 + 0.5 * s.unit(1))
                let y = horizonY + (spec.rect.w - horizonY) * (0.55 + 0.3 * s.unit(2))
                cabinU[Self.rowStar] = SIMD4(x, y, env, 2 / Float(max(1, size.height)))
                starShown = env > 0.01
            default:
                break   // the aurora's edge is the sky's
            }
        }
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)   // the supercell's impostor, before the frame's passes
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              var e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Outside: the sky (and the warp), the valley, sparks by the glass, then the snow falling.
        sky.draw(e)
        if showWarp { warp.draw(e) }
        let skyU = sky.uniforms
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        sky.bindStars(e)
        cabinU.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if !sparkInstances.isEmpty {
            e.setRenderPipelineState(sparks)
            sparkInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            cabinU.withUnsafeBytes {
                e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sparkInstances.count)
        }
        weather.draw(e)

        // High and Ultra: the frost scatters a blurred copy of the view.
        var blur: MTLTexture?
        if quality != .lite, let hdr = stack.hdrTarget {
            e.endEncoding()
            blur = glass.makeBlur(from: hdr, commandBuffer: cb)
            guard let again = stack.scenePassContinuing(), let next = cb.makeRenderCommandEncoder(descriptor: again) else { return }
            e = next
        }
        glass.drawGlass(e, blur: blur)
        glass.drawFrame(e)

        // The room around the window, the sill, then the keys.
        e.setRenderPipelineState(room)
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        cabinU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            cabinU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}

/// Made on any thread (the warm-up makes the worlds' renderers off the main thread, real-Mac performance 14 Nov), drawn on
/// the main thread: the class itself is not tied to the main actor, only its conformance is.
extension SnowboundCabinRenderer: ThemeRenderer {}
