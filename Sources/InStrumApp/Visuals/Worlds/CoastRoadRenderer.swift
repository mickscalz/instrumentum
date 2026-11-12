import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Coast Road: the Living Sky through the passenger window, far headlands, the Ocean layer far below with
/// white water at the cliff base, scrub, guardrail posts and lamps streaming past, Coast Lights, sea fog, the
/// window frame and glass, rain on the glass and a dashboard-amber keyboard.
@MainActor
final class CoastRoadRenderer: ThemeRenderer {
    /// Coast Lights sent to the GPU (fewer on Smooth).
    static func lightBudget(_ q: QualityLevel) -> Int { q == .lite ? 64 : CoastLights.cap }
    /// Light sprites per draw (two float4s each within setVertexBytes' 4 KB).
    static let maxLightInstances = 128
    /// Screen scroll per metre travelled for each layer (aspect units), and the wraps that keep them seamless.
    static let farRate = 0.002, midRate = 0.05, baseRate = 0.012
    static let midWrap = 40.0, baseWrap = 50.0
    static let postSpacing = 2.5, lampSpacing = 40.0
    /// The lamps' layer: screen scroll (aspect units) per metre travelled — the shader's kLampSpacing / lampSpacing.
    static let lampLayerRate = Float(3.3 / lampSpacing)

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let road: SkyPipeline
    private let lights, frame, keys, posts, foxes: MTLRenderPipelineState
    private var roadU = [SIMD4<Float>](repeating: .zero, count: CoastRoadRenderer.uniformCount)
    /// Fire & Neon §5.5: the fox in the scrub, and the lantern's light on the scene through the flash limiter.
    private var foxInstances: [FoxInstance] = []
    private var primed = false
    private var lanternGlow: Float = 0
    private var oceanU = [SIMD4<Float>](repeating: .zero, count: 7)
    private var lightInstances: [SIMD4<Float>] = []
    private var postInstances: [SIMD4<Float>] = []
    private var postColour = SIMD4<Float>(0, 0, 0, 1)
    /// The chord bloom's colour, gliding in RGB toward each new chord's (never sweeping through other hues).
    private var bloomColour: SIMD3<Float>?
    private var keyInstances: [KeyInstance] = []
    private var viewAzimuth: Double?
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    private(set) var lightCount = 0
    /// Lamp glow and chord bloom after the flash limiter (gentle visuals halve them).
    private(set) var lampOut: Float = 0
    private(set) var bloomOut: Float = 0
    /// The posts carrying lamp-lane Coast Lights: (x, head y) in aspect units, one per lamp light.
    private(set) var lampPosts: [SIMD2<Float>] = []
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }
    /// Excitement as drawn (tests read them): the lighthouse's beams and lantern flare, the road opening, the gathering
    /// headlights, the washes on the verge, the fox and the train, the exposure after the flash limiter.
    private(set) var beamOut: Float = 0
    private(set) var flareOut: Float = 0
    private(set) var openOut: Float = 0
    private(set) var headlightsOut: Float = 0
    private(set) var washesDrawn = 0
    private(set) var foxDrawn = false
    private(set) var trainOut: Float = 0
    private(set) var exposureOut: Float = 1
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }
    /// The shader's rows: the six before Fire & Neon, then the lighthouse, the train and headlights, the washes.
    nonisolated static let uniformCount = 11

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }
    /// The shader's FoxInstance.
    private struct FoxInstance { var p: SIMD4<Float>; var q: SIMD4<Float>; var tint: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: CoastRoadShaders.source, options: nil) else { return nil }
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
        guard let r = SkyPipeline(build: { make("road_vertex", "road_fragment", .premultiplied, storms: $0) }),
              let l = make("road_lights_vertex", "road_lights_fragment", .additive, writesDepth: false),
              let f = make("road_vertex", "road_frame_fragment", .premultiplied, writesDepth: false),
              let k = make("road_keys_vertex", "road_keys_fragment", .opaque),
              let pp = make("road_post_vertex", "road_post_fragment", .premultiplied, writesDepth: false),
              let fx = make("road_fox_vertex", "road_fox_fragment", .premultiplied, writesDepth: false) else { return nil }
        sky = s; weather = w; warp = gw; road = r; lights = l; frame = f; keys = k; posts = pp; foxes = fx
        sky.verticalFOV = 50
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// Face the low sun over the sea, else the moon while it's up, else out to sea (the road's curves add yaw): the
    /// model's own rule, so its shooting star is placed where the window looks.
    static func targetAzimuth(_ s: SkyState) -> Double { CoastRoadModel.viewAzimuth(s) }

    /// Lamps light up from dusk (the sun below 2°) and stay lit through the night.
    static func lampLight(sunAltitude: Double) -> Float { Float(smooth(2, -1, sunAltitude)) }

    /// A soft colour for a hue (0…1), shared by Coast Lights and the bloom.
    static func colour(hue: Float, softness: Float = 0.45) -> SIMD3<Float> {
        let h = hue - floor(hue)
        let k = SIMD3<Float>(abs(h * 6 - 3) - 1, 2 - abs(h * 6 - 2), 2 - abs(h * 6 - 4))
        let rgb = simd_clamp(k, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return rgb + (SIMD3<Float>(repeating: 1) - rgb) * softness
    }

    func update(_ frame: RoadFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))

        let target = Self.targetAzimuth(s) + frame.yaw
        if let az = viewAzimuth {
            let diff = (target - az + 540).truncatingRemainder(dividingBy: 360) - 180
            viewAzimuth = az + diff * (1 - exp(-min(dt, 0.1) / 4))
        } else {
            viewAzimuth = target
        }
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let bottom = keyTop + 0.1, top: Float = 0.9
        let horizonY = bottom + (top - bottom) * 0.62
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizonY
        sky.roll = frame.roll
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        // Sea smoke over the sea below the cliffs, inside the window: from the scrub's highest tops (the shader's scrub
        // line, bottom + 0.34 + up to 0.116) to the horizon. It passes right to left with the car, like the sea about
        // 480 m out at the band's middle (spec §6.4).
        let steamCam = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.waterBand = SIMD4(-0.9, bottom + 0.44, 0.9, horizonY)
        weather.steamCamera = steamCam
        let metresPerSecond = (30 + 70 * Double(min(max(frame.speed.isFinite ? frame.speed : 0, 0), 1))) / 3.6
        weather.steamDrift = -Float(metresPerSecond / 480) / max(steamCam.tanH, 0.1)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .glass)
        showWarp = frame.warp != nil
        limiter.gentle = gentle
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (top - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, 0.35 * MoodLook.hazeScale(mood) + s.mist)
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        // The lantern blazing as a beam faces you (and a fireball) lights the scene through the flash limiter; under
        // gentle visuals only ever a glow, eased in.
        let request = Self.unit(frame.flashRequest)
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        if gentle {
            lanternGlow += (min(0.12, 0.4 * request) - lanternGlow) * (dt == 0 ? 1 : 1 - exp(-fdt / 0.8))
        } else {
            lanternGlow = 0.9 * request
        }
        if !primed {
            // The limiter starts from black: settle it on the scene's own exposure first, so arriving is never a flash.
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: exposure, sparkle: 1, dt: 1) }
        }
        let limited = limiter.limit(exposure: exposure * (1 + lanternGlow), sparkle: 0.45 + 0.55 * frame.bloom, dt: dt)
        exposureOut = limited.exposure
        lampOut = Float(p.number("lamps")) * Self.lampLight(sunAltitude: s.sun.altitude) * sparkleScale
        bloomOut = frame.bloom * sparkleScale
        let fog = min(1, Float(p.number("fog")) + 0.8 * s.mist)

        // Scrolls: Double distance → wrapped Float phases, so a night's drive never loses precision or jumps.
        let dist = frame.distance
        let far = Float((dist * Self.farRate).truncatingRemainder(dividingBy: 4096))
        let mid = Float((dist * Self.midRate).truncatingRemainder(dividingBy: Self.midWrap))
        let base = Float((dist * Self.baseRate).truncatingRemainder(dividingBy: Self.baseWrap))
        let postPhase = Float((dist / Self.postSpacing).truncatingRemainder(dividingBy: 1))
        let lampPhase = Float((dist / Self.lampSpacing).truncatingRemainder(dividingBy: 1))
        var since: Float = -1, lastStrength: Float = 0
        if let last = frame.recent.last, frame.swellTime >= last.breakTime {
            since = Float(min(60, frame.swellTime - last.breakTime)); lastStrength = last.strength
        }
        roadU[0] = SIMD4(keyTop, aspect, Float(frame.roll * .pi / 180), haze)
        roadU[1] = SIMD4(far, mid, postPhase, lampPhase)
        roadU[2] = SIMD4(lampOut, night, frame.speed, fog)
        roadU[3] = SIMD4(since, lastStrength, base, s.wind)
        roadU[4] = SIMD4(0.93 * aspect, bottom, top, 0.1)
        // Wet tarmac: how wet, and the road's far edge (where reflections hang from).
        let roadLineY = bottom + 0.06
        roadU[5] = SIMD4(s.wetness, roadLineY, 0, 0)
        fillExcitement(frame, gentle: gentle, aspect: aspect, bottom: bottom)

        // The sea passes by the distance travelled, wrapped to its tile (every swell component and noise repeats
        // over the tile, so there's no seam); the chord bloom tints and brightens the glitter path.
        let tile = OceanTile.wrap(dist)
        let bloomTarget = Self.colour(hue: frame.bloomHue, softness: 0.3)
        let glided = bloomColour.map { $0 + (bloomTarget - $0) * Float(1 - exp(-min(dt, 0.1) / 0.4)) } ?? bloomTarget
        bloomColour = glided
        let b = bloomOut
        oceanU[0] = frame.swellPhases
        oceanU[1] = lights.sun
        oceanU[2] = SIMD4(lights.sunColor + (glided * 1.4 - lights.sunColor) * (0.6 * b), 0)
        oceanU[3] = lights.moon
        oceanU[4] = SIMD4(lights.moonColor + (glided * 1.2 - lights.moonColor) * (0.6 * b), min(1, limited.sparkle))
        oceanU[5] = SIMD4(frame.swellScale, 0.06 + 0.25 * s.wind, haze, quality == .lite ? 2 : 3)
        oceanU[6] = SIMD4(tile, 0, 0, 0)

        // Coast Lights: position by lane and pitch, streaming right to left; trails grow with speed.
        let visible = CoastLights.visible(frame.lights, limit: Self.lightBudget(quality))
        lightCount = visible.count
        lightInstances.removeAll(keepingCapacity: true)
        var reflections: [SIMD4<Float>] = []
        postInstances.removeAll(keepingCapacity: true)
        lampPosts.removeAll(keepingCapacity: true)
        let railY = bottom + 0.2, headY = top - 0.2
        let lightScale = sparkleScale
        for l in visible {
            let y: Float
            switch l.lane {
            case .road: y = bottom + 0.03 + 0.02 * l.height
            case .rail: y = railY - 0.025 + 0.07 * l.height
            case .lamp: y = headY - 0.16 + 0.2 * l.height
            }
            var x = 1.04 - 2.08 * l.x
            if l.lane == .lamp {
                // High notes light lamps of their own, standing on posts and passing with the lamps' layer.
                let postX = aspect + 0.12 - Float(dist - l.spawnDistance) * Self.lampLayerRate
                lampPosts.append(SIMD2(postX, y))
                postInstances.append(SIMD4(postX, y, bottom + 0.3, 0))
                x = (postX + 0.16) / aspect
            }
            // Lamp-head lights glow round; road and rail lights streak with speed.
            let trail = l.trail * (0.08 + 0.5 * frame.speed) * (l.lane == .lamp ? 0.35 : 1)
            let radius: Float = l.lane == .road ? 0.008 : (l.lane == .rail ? 0.011 : 0.014)
            let c = Self.colour(hue: l.hue)
            lightInstances.append(SIMD4(x, y, trail, radius))
            lightInstances.append(SIMD4(c, min(1.5, l.brightness) * lightScale))
            // On a wet road the lights just above it shine back as streaks hanging from the road's edge (a negative
            // radius marks a reflection: stretched 4× down, clipped to the road). The lamps' reflections fall below
            // the window; the road shader streaks their glow instead.
            if s.wetness >= 0.05, y > roadLineY, y - roadLineY < 0.6 {
                let mirrored = roadLineY - (y - roadLineY) * 0.25
                reflections.append(SIMD4(x, mirrored, trail, -radius))
                reflections.append(SIMD4(c, min(1.5, l.brightness) * lightScale * 0.35 * s.wetness))
            }
        }
        // setVertexBytes takes at most 4 KB: 128 instances of two float4s, lights first.
        let room = max(0, Self.maxLightInstances - lightInstances.count / 2)
        lightInstances.append(contentsOf: reflections.prefix(room * 2))

        let lampGlow = SIMD3<Float>(1.0, 0.72, 0.42) * (lampOut * 0.05)
        postColour = SIMD4(s.zenith * 0.02 + s.horizon * 0.01 + lampGlow, 1)

        // Keys: dark plastic in the dashboard, amber where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottomY: Float = -0.995, gap: Float = 0.0015
            let light = max(lights.sun.w, lights.moon.w)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottomY) * 0.62 : bottomY
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.65, bloomThreshold: 0.8,
            dof: quality == .lite ? 0 : 0.15, focusDepth: 0.75,
            grade: 0, grain: 0.025, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) - 0.04 * night,
            time: time, quality: quality)
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    nonisolated static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// The lighthouse, the far train, the headlights on the verge, the road opening and the fox, into the shader's rows.
    private func fillExcitement(_ frame: RoadFrame, gentle: Bool, aspect: Float, bottom: Float) {
        let lightScale: Float = gentle ? 0.6 : 1
        let beam = Self.unit(frame.beamLight) * lightScale
        let off = CoastRoadModel.facing(frame.beamAngle)
        // The lantern's flare as a beam faces you: under gentle visuals a gentle glimmer, never a blaze.
        let flare = exp(-off * off / 0.0016) * (gentle ? 0.15 : 1)
        beamOut = beam
        flareOut = beam > 0.001 ? flare : 0
        let l = CoastRoadModel.lighthouse
        roadU[6] = SIMD4(l.x, l.y, l.z, beam)
        openOut = Self.unit(frame.open)
        roadU[7] = SIMD4(frame.beamAngle.isFinite ? frame.beamAngle : 0, 0, flareOut, openOut)
        headlightsOut = Self.unit(frame.headlights) * lightScale
        trainOut = 0
        if let t = frame.train, t.light > 0.001 {
            trainOut = Self.unit(t.light) * lightScale
            roadU[8] = SIMD4(t.head, t.length, trainOut, headlightsOut)
        } else {
            roadU[8] = SIMD4(0, 0, 0, headlightsOut)
        }
        // The washes: 1 at the window's right edge … 0 at its left (aspect units of the world's frame).
        var rows = [SIMD2<Float>](repeating: SIMD2(-9, 0), count: 3)
        var drawn = 0
        for w in frame.washes.prefix(3) {
            let x = (-0.93 + 1.86 * w.x) * aspect
            rows[drawn] = SIMD2(x, Self.unit(w.light) * lightScale)
            drawn += 1
        }
        washesDrawn = drawn
        roadU[9] = SIMD4(rows[0].x, rows[0].y, rows[1].x, rows[1].y)
        roadU[10] = SIMD4(rows[2].x, rows[2].y, 0, 0)

        // The fox: standing in the scrub as the car passes it, its eyes catching the light at night.
        foxInstances.removeAll(keepingCapacity: true)
        foxDrawn = false
        if let fx = frame.fox, fx.alpha > 0.001 {
            let x = 0.93 * aspect + 0.25 - Float(fx.along * Self.midRate)   // it stands still: the scrub's layer passes it
            if x > -0.93 * aspect - 0.3, x < 0.93 * aspect + 0.3 {
                let s = frame.sky
                let day = Float(Self.smooth(-4, 6, s.sun.altitude))
                let coat = SIMD3<Float>(0.42, 0.19, 0.08) * (0.08 + 0.55 * day) + s.zenith * 0.03
                let eyes = (1 - day) * (gentle ? 0.5 : 1)
                foxInstances.append(FoxInstance(p: SIMD4(x, bottom + 0.235, 0.14, fx.trot), q: SIMD4(Self.unit(fx.alpha), eyes, 0, 0),
                                                 tint: SIMD4(coat, 0)))
                foxDrawn = true
            }
        }
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        let skyU = sky.uniforms
        e.setRenderPipelineState(road.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        roadU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        oceanU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !postInstances.isEmpty {
            e.setRenderPipelineState(posts)
            postInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            roadU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.setFragmentBytes(&postColour, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }   // their rime
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: postInstances.count)
        }

        if !foxInstances.isEmpty {
            e.setRenderPipelineState(foxes)
            foxInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            roadU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: foxInstances.count)
        }

        if !lightInstances.isEmpty {
            e.setRenderPipelineState(lights)
            lightInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            roadU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            roadU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lightInstances.count / 2)
        }

        // Rain and snow on the glass, then the car's frame over them (no weather inside the car).
        weather.draw(e)

        e.setRenderPipelineState(frame)
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        roadU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
