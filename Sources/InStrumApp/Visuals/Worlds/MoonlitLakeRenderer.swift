import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Moonlit Lake: the Living Sky, ridges and pines, the lake reflecting it all through Lake Ripples,
/// fireflies, weather on the water and a glassy keyboard.
@MainActor
final class MoonlitLakeRenderer: ThemeRenderer {
    /// Ripple wave packets sent to the GPU (fewer on Smooth).
    static func rippleBudget(_ q: QualityLevel) -> Int { q == .lite ? 32 : LakeRipples.cap }

    private let device: MTLDevice
    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let lake: SkyPipeline
    private let glow, keys, owlState: MTLRenderPipelineState
    private var lakeU = [SIMD4<Float>](repeating: .zero, count: 4 + 2 * LakeRipples.cap)
    private var fireflies: [SIMD4<Float>] = []
    private var keyInstances: [KeyInstance] = []
    private var owlInstances: [OwlInstance] = []
    private var aspect: Float = 16.0 / 9
    private var primed = false
    private var fireballGlow: Float = 0
    private var viewAzimuth: Double?
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    private(set) var rippleCount = 0
    /// The glitter and firefly strength after the flash limiter (gentle visuals halve them).
    private(set) var glitterOut: Float = 0
    private(set) var fireflyScale: Float = 1
    /// Where the horizon (the far shore's foot) sits this frame, NDC y.
    private(set) var horizonY: Float = -0.2
    /// Excitement as drawn (tests read them): the exposure after the flash limiter, the mist on the water, how many of
    /// the lake's own meteors the sky shows, and the owl.
    private(set) var exposureOut: Float = 1
    private(set) var mistOut: Float = 0
    private(set) var worldMeteorsShown = 0
    private(set) var owlDrawn = false
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }
    /// The shader's OwlInstance: the quad (NDC), its wingbeat and bank, and its colour and cover.
    private struct OwlInstance { var rect: SIMD4<Float>; var info: SIMD4<Float>; var tint: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: MoonlitLakeShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, additive: Bool, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if additive {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
                d.colorAttachments[1].writeMask = []
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        func premultiplied(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let l = SkyPipeline(build: { make("lake_vertex", "lake_fragment", additive: false, storms: $0) }),
              let g = make("firefly_vertex", "firefly_fragment", additive: true),
              let k = make("lake_keys_vertex", "lake_keys_fragment", additive: false),
              let o = premultiplied("lake_owl_vertex", "lake_owl_fragment") else { return nil }
        self.device = device
        sky = s; weather = w; warp = gw; lake = l; glow = g; keys = k; owlState = o
        sky.verticalFOV = 62
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    nonisolated static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// Face the moon while it's up (a little to its left, so it sits off-centre), else the sun, else the equator: the
    /// model's own rule, so its meteor burst and its owl are placed where the lake looks.
    static func targetAzimuth(_ s: SkyState) -> Double { MoonlitLakeModel.viewAzimuth(s) }

    /// Where a point on the lake (x 0…1 across, depth 0 near … 1 far) lies: forward and sideways distance.
    static func lakePoint(x: Float, depth: Float, tanH: Float) -> (f: Float, s: Float) {
        let f = 4.5 / (1 - 0.88 * min(1, max(0, depth)))
        return (f, (x - 0.5) * 2 * f * tanH * 0.85)
    }

    func update(_ frame: LakeFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time)

        // Camera: pan slowly toward the moon (or sun).
        let target = Self.targetAzimuth(s)
        if let az = viewAzimuth {
            let diff = (target - az + 540).truncatingRemainder(dividingBy: 360) - 180
            viewAzimuth = az + diff * (1 - exp(-min(dt, 0.1) / 4))
        } else {
            viewAzimuth = target
        }
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        // A high moon tilts the view up a little (lower horizon, wider lens) so it stays in the picture.
        let lift = Float(s.moon.altitude > -5 && s.sun.altitude < 2 ? Self.smooth(22, 50, s.moon.altitude) : 0)
        let horizonY = keyTop + (1 - keyTop) * (0.4 - 0.14 * lift)
        self.horizonY = horizonY
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizonY
        sky.verticalFOV = 62 + 10 * Double(lift)
        sky.gentle = gentle
        // Tension gathers the mist (on the water and in the sky, dimming the stars); a drop lifts it all at once.
        let gather = Self.unit(frame.mistGather), lifted = Self.unit(frame.mistLift)
        var shown = s
        shown.mist = min(1, max(0, s.mist.isFinite ? s.mist : 0) + 0.35 * gather) * (1 - 0.9 * lifted)
        sky.update(shown, quality: quality, size: size, time: time)
        worldMeteorsShown = min(frame.worldMeteors, SkyLayer.meteorSlots)
        // Sea smoke rises off the lake: the water from the keys (the near shore) up to the far shore's foot (spec §6.4).
        weather.waterBand = SIMD4(-1, keyTop, 1, horizonY)
        weather.steamCamera = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizonY))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        // Galaxy Warp streams out of the sky above the lake (the ridges and water draw over it).
        showWarp = frame.warp != nil
        limiter.gentle = gentle
        fireflyScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (1 - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: fireflyScale, quality: quality, size: size, dt: dt, time: time)
        }

        // The light on the water: the moon at night, the sun by day.
        let sunAlt = s.sun.altitude, moonAlt = s.moon.altitude
        let night = Float(1 - Self.smooth(-12, -3, sunAlt))
        let dayness = Self.smooth(-6, 2, sunAlt)
        let moonW = s.moonLit * Self.smooth(-3, 6, moonAlt) * (1 - dayness)
        let sunW = Self.smooth(-3, 4, sunAlt)
        let clouds = Double(1 - 0.8 * s.cloudCover)
        let light: SIMD4<Float>, lightColor: SIMD3<Float>
        if sunW * 3 > moonW {
            light = SIMD4(SkyLayer.enu(s.sun), Float(2.5 * sunW * clouds))
            let k = Float(min(1, max(0, sunAlt / 20)))
            let warm = SIMD3<Float>(1, 0.62, 0.35), white = SIMD3<Float>(1, 0.95, 0.85)
            lightColor = (warm + (white - warm) * k) * s.sunTint     // reddened and dimmed through ashfall's haze
        } else {
            light = SIMD4(SkyLayer.enu(s.moon), Float(moonW * clouds))
            lightColor = SIMD3(0.78, 0.85, 1.0) * s.moonTint
        }

        let mood = frame.mood
        let baseMist = min(1, Float(p.number("mist")) * MoodLook.hazeScale(mood) * 0.8 + s.mist)
        let mist = min(1, baseMist * (1 + 1.2 * gather) + 0.3 * gather) * (1 - 0.92 * lifted)
        mistOut = mist
        // Glints and the exposure go through the flash limiter (gentle visuals halve the sparkle). A fireball's light on
        // the lake rides on the exposure: under gentle visuals it is only ever a glow, eased in.
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let request = Self.unit(frame.flashRequest)
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        if gentle {
            fireballGlow += (min(0.12, 0.4 * request) - fireballGlow) * (dt == 0 ? 1 : 1 - exp(-fdt / 0.8))
        } else {
            fireballGlow = 0.9 * request
        }
        limiter.gentle = gentle
        if !primed {
            // The limiter starts from black: settle it on the scene's own exposure first, so arriving is never a flash.
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: exposure, sparkle: 1, dt: 1) }
        }
        let limited = limiter.limit(exposure: exposure * (1 + fireballGlow), sparkle: Float(p.number("glitter")) * (0.25 + 0.75 * frame.glitter), dt: dt)
        exposureOut = limited.exposure
        let glitter = limited.sparkle
        glitterOut = glitter

        // Ripples → wave packets: the notes' rings, and the water's own (a fish rising, Energy's dimples).
        let budget = Self.rippleBudget(quality)
        let ripples = LakeRipples.visible(frame.rings.isEmpty ? frame.ripples : frame.ripples + frame.rings, limit: budget)
        rippleCount = ripples.count
        for i in 0..<LakeRipples.cap { lakeU[4 + i] = .zero; lakeU[4 + LakeRipples.cap + i] = .zero }
        for (i, r) in ripples.enumerated() {
            let a = r.age, life = max(0.1, r.lifetime)
            let left = max(0, 1 - a / life)
            let fade = left * left * Float(Self.smooth(0, 0.08, Double(a)))
            let speed = 0.6 + 0.5 * r.strength
            let radius = speed * a
            let amp = 0.03 * r.strength * fade / (1 + radius).squareRoot()
            let width = 0.18 + 0.22 * radius
            let k = 2 * Float.pi / (0.45 + 0.25 * radius)
            let pt = Self.lakePoint(x: r.x, depth: r.depth, tanH: cam.tanH)
            lakeU[4 + i] = SIMD4(pt.s, pt.f, radius, amp)
            lakeU[4 + LakeRipples.cap + i] = SIMD4(width, k, r.strength * fade, 0)
        }
        lakeU[0] = SIMD4(keyTop, time, glitter, mist)
        lakeU[1] = SIMD4(Float(p.number("reeds")), Self.unit(frame.windOnWater), Float(ripples.count), night)
        lakeU[2] = light
        lakeU[3] = SIMD4(lightColor, MoodLook.driftScale(mood))

        // Fireflies (and their faint reflections), projected through the sky camera.
        fireflies.removeAll(keepingCapacity: true)
        let fwd = simd_normalize(SIMD2(cam.forward.x, cam.forward.y)), rgt = SIMD2(fwd.y, -fwd.x)
        func project(_ q: SIMD3<Float>) -> SIMD3<Float>? {
            let z = simd_dot(q, cam.forward)
            guard z > 0.2 else { return nil }
            return SIMD3(simd_dot(q, cam.right) / (z * cam.tanH), simd_dot(q, cam.up) / (z * cam.tanV), z)
        }
        for f in frame.fireflies {
            let pt = Self.lakePoint(x: f.position.x, depth: f.position.z, tanH: cam.tanH)
            let ground = fwd * pt.f + rgt * pt.s
            let height = 2.5 * f.position.y
            let alive = min(1, f.age / 0.6) * min(1, max(0, f.lifetime - f.age) / 1.2)
            let blink = 0.55 + 0.45 * sin(f.age * 2.3 + f.hue * 50)
            let alpha = alive * blink * fireflyScale
            if let c = project(SIMD3(ground.x, ground.y, height - 1)) {
                fireflies.append(SIMD4(c.x, c.y, min(0.06, max(0.012, 0.2 / c.z)), alpha))
            }
            if let c = project(SIMD3(ground.x, ground.y, -height - 1)) {
                fireflies.append(SIMD4(c.x, c.y, min(0.07, max(0.014, 0.24 / c.z)), alpha * 0.3))
            }
        }

        // The owl crossing the moon (a surprise): a silhouette, its wings spread across the sky, beating then gliding.
        owlInstances.removeAll(keepingCapacity: true)
        owlDrawn = false
        if let o = frame.owl {
            let d = o.direction
            let z = simd_dot(d, cam.forward)
            if z > 0.05 {
                let at = SIMD2<Float>(simd_dot(d, cam.right) / (z * cam.tanH), simd_dot(d, cam.up) / (z * cam.tanV))
                let half = Float(o.span) * 0.5 * .pi / 180 * 1.2
                let hx = half / cam.tanH, hy = half / cam.tanV
                if abs(at.x) < 1 + hx, abs(at.y) < 1 + hy {
                    let flown = o.progress
                    let cover = min(1, flown / 0.06) * min(1, (1 - flown) / 0.06)
                    let bank = 0.18 * sin(flown * 5.3)
                    let ambient = s.zenith * 0.05 + SIMD3<Float>(0.002, 0.002, 0.003)
                    owlInstances.append(OwlInstance(rect: SIMD4(at.x - hx, at.y - hy, at.x + hx, at.y + hy),
                                                    info: SIMD4(o.wing, bank, 0, 0), tint: SIMD4(ambient, cover)))
                    owlDrawn = cover > 0.01
                }
            }
        }

        // Keys: dark glass along the shore, moon-silver where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light.w)))
            }
        }

        post = PostSettings(
            bloom: 0.55, bloomThreshold: 0.9,
            dof: quality == .lite ? 0 : 0.3, focusDepth: 0.25,
            grade: 0, grain: 0.025, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) - 0.1 * night,
            time: time, quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        let skyU = sky.uniforms
        e.setRenderPipelineState(lake.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        lakeU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !fireflies.isEmpty {
            var a = SIMD4<Float>(aspect, 0, 0, 0)
            e.setRenderPipelineState(glow)
            fireflies.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.setVertexBytes(&a, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: fireflies.count)
        }

        if !owlInstances.isEmpty {
            e.setRenderPipelineState(owlState)
            owlInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: owlInstances.count)
        }

        weather.draw(e)

        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
