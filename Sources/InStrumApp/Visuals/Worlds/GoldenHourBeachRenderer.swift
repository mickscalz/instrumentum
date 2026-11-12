import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Golden Hour Beach: the Living Sky, a headland, the Ocean layer with breaking waves, the wash on the
/// sand, Tide Lines, palms, weather and an amber keyboard.
@MainActor
final class GoldenHourBeachRenderer: ThemeRenderer {
    /// Tide lines sent to the GPU (fewer on Smooth).
    static func lineBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : TideLines.cap }
    /// Shore geometry in metres (matches the shader's constants).
    static let waterline: Float = 11, wetBand: Float = 5, breakLine: Float = 22, waveSpeed: Float = 5
    /// White water rushing in from the break line to the shore (m/s; matches the shader's kBoreSpeed).
    static let boreSpeed: Float = 4.4
    static let cameraHeight: Float = 2.0

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let beach: SkyPipeline
    private let keys: MTLRenderPipelineState
    private var beachU = [SIMD4<Float>](repeating: .zero, count: 7 + 2 * TideLines.cap)
    private var oceanU = [SIMD4<Float>](repeating: .zero, count: 7)   // the beach doesn't travel: travel stays 0
    private var keyInstances: [KeyInstance] = []
    private var aspect: Float = 16.0 / 9
    private var viewAzimuth: Double?
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    private(set) var lineCount = 0
    /// The glitter after the flash limiter (gentle visuals halve it).
    private(set) var glitterOut: Float = 0
    /// How strongly spray glints on the foam (gentle visuals should calm it).
    private(set) var sprayOut: Float = 1
    /// The shader's uniforms (tests read them).
    var oceanUniforms: [SIMD4<Float>] { oceanU }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: GoldenHourBeachShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let b = SkyPipeline(build: { make("beach_vertex", "beach_fragment", storms: $0) }), let k = make("beach_keys_vertex", "beach_keys_fragment") else { return nil }
        sky = s; weather = w; warp = gw; beach = b; keys = k
        sky.verticalFOV = 58
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// Face the low sun over the sea (a little to its left), else the moon while it's up, else out to sea.
    static func targetAzimuth(_ s: SkyState) -> Double {
        if s.sun.altitude > -12, s.sun.altitude < 25 { return s.sun.azimuth - 8 }
        if s.moon.altitude > -5 { return s.moon.azimuth - 8 }
        return SkyLayer.defaultViewAzimuth(latitude: s.latitude)
    }

    /// Where a line in the sand lies (x 0…1 across the keyboard, y 0 waterline … 1 top of the wet sand).
    static func shorePoint(x: Float, y: Float, tanH: Float) -> (s: Float, f: Float) {
        let f = waterline - min(1, max(0, y)) * wetBand
        return ((x - 0.5) * 2 * f * tanH * 0.85, f)
    }

    func update(_ frame: BeachFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))

        let target = Self.targetAzimuth(s)
        if let az = viewAzimuth {
            let diff = (target - az + 540).truncatingRemainder(dividingBy: 360) - 180
            viewAzimuth = az + diff * (1 - exp(-min(dt, 0.1) / 4))
        } else {
            viewAzimuth = target
        }
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let horizonY = keyTop + (1 - keyTop) * 0.4
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizonY
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        // Sea smoke over the sea, from the waterline out to the horizon (spec §6.4).
        let shore = SkyLayer.waterY(out: Self.waterline, height: Self.cameraHeight, horizonY: horizonY, verticalFOV: sky.verticalFOV)
        weather.waterBand = SIMD4(-1, shore, 1, horizonY)
        weather.steamCamera = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizonY))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        showWarp = frame.warp != nil
        limiter.gentle = gentle
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (1 - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, Float(p.number("haze")) * MoodLook.hazeScale(mood) + s.mist)
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let limited = limiter.limit(exposure: exposure, sparkle: Float(p.number("glitter")) * (0.25 + 0.75 * frame.glitter), dt: dt)
        glitterOut = limited.sparkle

        // Tide lines → sand coordinates.
        let lines = TideLines.visible(frame.lines, limit: Self.lineBudget(quality))
        lineCount = lines.count
        for i in 0..<TideLines.cap { beachU[7 + i] = .zero; beachU[7 + TideLines.cap + i] = .zero }
        for (i, l) in lines.enumerated() {
            let pt = Self.shorePoint(x: l.x, y: l.y, tanH: cam.tanH)
            // Traced left to right like a finger drawing it: the stroke grows from its left end.
            let fullHalf = l.length * 0.5 * 2 * pt.f * cam.tanH * 0.85
            let halfLength = fullHalf * l.drawn
            let glow = l.strength * min(1, 0.3 + l.drawn) * (1 - l.washed) * (0.55 + 0.45 * sparkleScale)
            beachU[7 + i] = SIMD4(pt.s - fullHalf + halfLength, pt.f, halfLength, glow)
            beachU[7 + TideLines.cap + i] = SIMD4(l.hue, 0, 0, 0)
        }
        // The next crests (metres beyond the break line) and the white water from the last break.
        var crests = [SIMD4<Float>](repeating: .zero, count: 3)
        for (i, w) in frame.upcoming.prefix(3).enumerated() {
            let ahead = Float(w.breakTime - frame.swellTime) * Self.waveSpeed
            crests[i] = SIMD4(ahead, w.strength, 0, 0)
        }
        // The last two breaks: how long ago and how strong (the shader rolls their white water in from the break
        // line, the older one still fading as the newer arrives).
        var since: Float = -1, lastStrength: Float = 0, since2: Float = -1, strength2: Float = 0
        let broken = frame.recent.filter { frame.swellTime >= $0.breakTime }
        if let last = broken.last { since = Float(min(60, frame.swellTime - last.breakTime)); lastStrength = last.strength }
        if broken.count >= 2 {
            let before = broken[broken.count - 2]
            since2 = Float(min(60, frame.swellTime - before.breakTime)); strength2 = before.strength
        }
        sprayOut = sparkleScale
        beachU[0] = SIMD4(keyTop, sprayOut, limited.sparkle, haze)
        beachU[1] = SIMD4(Float(p.number("palms")), s.wind, Float(lines.count), night)
        beachU[2] = SIMD4(aspect, Self.cameraHeight, since, lastStrength)
        beachU[3] = SIMD4(frame.washFront, frame.foam * sparkleScale, since2, strength2)
        crests[0].z = s.wetness   // after the rain: the whole beach is wet
        beachU[4] = crests[0]; beachU[5] = crests[1]; beachU[6] = crests[2]

        oceanU[0] = frame.swellPhases
        oceanU[1] = lights.sun
        oceanU[2] = SIMD4(lights.sunColor, Float(lights.sun.w) * Float(Self.smooth(15, 2, s.sun.altitude)))
        oceanU[3] = lights.moon
        oceanU[4] = SIMD4(lights.moonColor, limited.sparkle)
        oceanU[5] = SIMD4(frame.swellScale, 0.06 + 0.25 * s.wind, haze, quality == .lite ? 2 : 3)

        // Keys: dark wood along the sand, golden amber where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let light = max(lights.sun.w, lights.moon.w)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.6, bloomThreshold: 0.85,
            dof: quality == .lite ? 0 : 0.2, focusDepth: 0.14,
            grade: 0, grain: 0.02, vignette: 0.25,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.08 * (1 - night),
            time: time, quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        let skyU = sky.uniforms
        e.setRenderPipelineState(beach.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        beachU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        oceanU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        weather.draw(e)

        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
