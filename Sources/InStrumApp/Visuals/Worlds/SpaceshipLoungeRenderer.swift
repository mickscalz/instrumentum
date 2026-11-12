import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws the Spaceship Lounge: space through a big window (Earth turning below, the Moon, sun glare, deep
/// stars), Galaxy Warp, the softly lit lounge and a console keyboard.
@MainActor
final class SpaceshipLoungeRenderer: ThemeRenderer {
    /// Space has no weather.
    static let weatherSurface = WeatherSurface.none

    private let device: MTLDevice
    let warp: WarpLayer
    private let space, frame, keys: MTLRenderPipelineState
    private var u = [SIMD4<Float>](repeating: .zero, count: 14)
    private var keyInstances: [KeyInstance] = []
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    /// Streak and field brightness after the flash limiter (gentle visuals halve it).
    private(set) var streakScale: Float = 1

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let w = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: SpaceshipLoungeShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let s = make("lounge_vertex", "lounge_space_fragment", blend: false),
              let f = make("lounge_vertex", "lounge_frame_fragment", blend: true),
              let k = make("lounge_keys_vertex", "lounge_keys_fragment", blend: false) else { return nil }
        self.device = device
        warp = w; space = s; frame = f; keys = k
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// A unit vector from latitude and longitude (degrees), Earth-fixed (x at 0°E, z north).
    static func earthVector(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let la = latitude * .pi / 180, lo = longitude * .pi / 180
        return SIMD3(Float(cos(la) * cos(lo)), Float(cos(la) * sin(lo)), Float(sin(la)))
    }

    /// The star field's frame: looking toward the galactic centre with the band tilted across the window,
    /// turning slowly as the lounge drifts.
    static func starBasis(time: Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let gc = simd_normalize(SIMD3<Float>(-0.0548, -0.8734, -0.4838))
        let ngp = SIMD3<Float>(-0.8676, -0.1981, 0.4560)
        let up0 = simd_normalize(ngp - gc * simd_dot(ngp, gc))
        let right0 = simd_cross(up0, gc)
        let tilt: Float = 0.6, yaw = time * 0.0025
        var right = right0 * cos(tilt) + up0 * sin(tilt)
        let up = up0 * cos(tilt) - right0 * sin(tilt)
        var forward = gc
        // Drift: turn about `up`.
        let f2 = forward * cos(yaw) + right * sin(yaw)
        right = right * cos(yaw) - forward * sin(yaw)
        forward = f2
        return (right, up, forward)
    }

    func update(_ f: LoungeFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(f.time)
        let s = f.sky
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let glow = Float(p.number("interior.glow"))
        let earthSize = Float(p.number("earth.size"))

        // The window and Earth in it.
        let bottom = keyTop + 0.12, top: Float = 0.9
        let halfWidth = 0.93 * aspect
        let radius = 0.9 + 0.9 * earthSize
        let earthTop = bottom + (0.22 + 0.3 * earthSize) * (top - bottom)
        let earthCentre = SIMD2<Float>(-0.1 * aspect, earthTop - radius)

        // Beneath the window: the longitude the model chose, tilted from the city's latitude.
        let lon = Double(f.earthRotation) * 180 / .pi
        let lat = min(60, max(-60, s.latitude * 0.6)) - 25
        let V = Self.earthVector(latitude: lat, longitude: lon)
        let E = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), V))
        let N = simd_cross(V, E)
        let S = Self.earthVector(latitude: s.subsolar.latitude, longitude: s.subsolar.longitude)
        let sView = SIMD3<Float>(simd_dot(S, E), simd_dot(S, N), simd_dot(S, V))
        let sScreen = simd_length(SIMD2(sView.x, sView.y)) > 1e-3 ? simd_normalize(SIMD2(sView.x, sView.y)) : SIMD2<Float>(0, 1)

        // Sunrise on the limb when the sun sits just behind Earth; daylight spilling in when it's behind us.
        let limbPos = earthCentre + sScreen * radius * 1.01
        let sunrise = 2.2 * exp(-pow((sView.z + 0.05) / 0.16, 2))
        let windowCentre = SIMD2<Float>(0, (bottom + top) / 2)
        let veilPos = windowCentre + SIMD2(sScreen.x * halfWidth, sScreen.y * (top - bottom) / 2) * 1.05
        let veil = 0.22 * Float(Self.smooth(0.1, 0.7, Double(sView.z)))
        let moonlit = Float(s.moonLit)

        let (r, up, fwd) = Self.starBasis(time: time)
        u[0] = SIMD4(aspect, time, keyTop, glow)
        u[1] = SIMD4(earthCentre.x, earthCentre.y, radius, quality == .lite ? 2 : 3)
        u[2] = SIMD4(E, 2 * 0.7 / Float(max(1, size.height)))
        u[3] = SIMD4(N, moonlit)
        u[4] = SIMD4(V, 0)
        u[5] = SIMD4(S, 0)
        u[6] = SIMD4(limbPos.x, limbPos.y, 0.02, sunrise)
        u[7] = SIMD4(veilPos.x, veilPos.y, 0.9, veil)
        u[8] = SIMD4(0.55 * aspect, 0.62, 0.055, Float(s.moonPhase))
        u[9] = SIMD4(sScreen.x, sScreen.y, moonlit, 0)
        u[10] = SIMD4(halfWidth, bottom, top, 0.1)
        // Columns of the view → equatorial matrix: the view's right, up and forward in the sky's frame.
        u[11] = SIMD4(r, 0)
        u[12] = SIMD4(up, 0)
        u[13] = SIMD4(fwd, 0)

        // Galaxy Warp streams from just above Earth.
        warp.centre = SIMD2(0.05, min(top - 0.25, earthTop + 0.35))
        let mood = f.mood
        limiter.gentle = gentle
        let limited = limiter.limit(exposure: MoodLook.exposure(mood) * 1.15, sparkle: 1, dt: dt)
        streakScale = limited.sparkle
        warp.update(f.warp, trails: Float(p.number("warp.trails")), nebula: Float(p.number("nebula")), intensity: streakScale,
                    quality: quality, size: size, dt: dt, time: time)

        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottomY: Float = -0.995, gap: Float = 0.0015
            for k in f.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottomY) * 0.62 : bottomY
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, 0)))
            }
        }

        post = PostSettings(
            bloom: 0.7, bloomThreshold: 0.9,
            dof: quality == .lite ? 0 : 0.25, focusDepth: 0.95,
            grade: 0, grain: 0.02, vignette: 0.35,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood),
            time: time, quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(space)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        warp.draw(e)

        e.setRenderPipelineState(frame)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
