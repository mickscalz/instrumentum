import Metal
import CoreGraphics
import simd
import InStrumCore

extension DriveFrame: SkyBearing {}

/// Draws Neon Night Drive (Fire & Neon spec §9): the view from the passenger seat through a rain-beaded windscreen down a
/// wet elevated expressway into a dense neon city at night.
///
/// The passes: the scene (`NeonNightDriveShaders`: the sky, the towers with their windows and wordless neon, the road,
/// its street lights, the traffic, a tunnel, the bridge's harbour, a surprise's overpass and train) with Galaxy Warp and
/// the falling rain over it; then, from a half-resolution copy, the wet road's and the harbour's mirror of the city, and
/// Light Trails (`LightTrailsLayer`); then, from a second copy, the Window Kit's windscreen (`WindscreenLayer`: the drops,
/// the wipers, the cabin with the keys' strip). The renderer turns the frame into the shader's rows. Every flash (the
/// Drop's neon wave, far lightning, the tunnel's lights strobing) goes through one `FlashLimiter`; gentle visuals turn the
/// wave and the lightning into glows and stop the strobe. Nothing is allocated a frame.
@MainActor
final class NeonNightDriveRenderer: ThemeRenderer {
    // MARK: The shader's rows (MSL `DriveU`)
    nonisolated static let rowA = 0, rowAxes = 1, rowMove = 2, rowNeon = 3, rowWave = 4, rowPlay = 5, rowRoute = 6
    nonisolated static let rowRoute2 = 7, rowRain = 8, rowAmb = 9, rowHaze = 10, rowGlow = 11, rowFlash = 12, rowOver = 13
    nonisolated static let rowOver2 = 14, rowBloom = 15, rowDead = 16, rowRoad1 = 17, rowRoad2 = 18, rowRoad3 = 19
    nonisolated static let signBase = 20, signRows = 12
    nonisolated static let studBase = 32, studSlots = 16
    nonisolated static let carBase = 48, carSlots = 12
    nonisolated static let palBase = 72, palRows = 6
    nonisolated static let uniformCount = 78

    // MARK: The view
    /// The way the road runs (degrees from north): the sky's moon and clouds stand where they would.
    nonisolated static let heading = 330.0
    nonisolated static let horizonY: Float = -0.04
    /// The world's coordinates wrap every this many metres (a multiple of every building cell, lamp, dash and stud spacing,
    /// so the city repeats seamlessly; about half an hour at full speed).
    nonisolated static let worldWrap = 61440.0
    /// "None" for a span or an overpass in the shader's rows.
    nonisolated static let farAway: Float = 1e5
    /// The accent neon (lime, warm white, red) beside the chord's palette.
    nonisolated static let accents: [SIMD3<Float>] = [SIMD3(0.35, 1.0, 0.18), SIMD3(1.0, 0.78, 0.5), SIMD3(1.0, 0.07, 0.05)]

    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    let trails: LightTrailsLayer
    let screen: WindscreenLayer
    let reflectCopy: ViewCopy
    private let scene, reflect: MTLRenderPipelineState
    private var u = [SIMD4<Float>](repeating: .zero, count: NeonNightDriveRenderer.uniformCount)
    private var limiter = FlashLimiter()
    private var showWarp = false
    private(set) var post = PostSettings()

    /// What was drawn (tests read them): the wave's and the lightning's light after the limiter, the tunnel's strobe (its
    /// amplitude after the limiter, 0 under gentle visuals) and how often its lights pass, the exposure, whether the
    /// camera is in the tunnel, the speed of the falling rain (1 normal, slowed in the drop's release).
    private(set) var waveLight: Float = 0
    private(set) var lightningLight: Float = 0
    private(set) var strobeLight: Float = 0
    private(set) var strobeHz: Float = 0
    private(set) var exposureOut: Float = 1
    private(set) var inTunnel = false
    private(set) var rainSpeed: Float = 1
    /// The flashes the limiter counted: within the last second and in all.
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }
    /// The shader's rows (tests read them).
    var uniforms: [SIMD4<Float>] { u }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let tl = LightTrailsLayer(device: device), let sc = WindscreenLayer(device: device),
              let rc = ViewCopy(device: device),
              let lib = try? device.makeLibrary(source: NeonNightDriveShaders.source, options: nil) else { return nil }
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "drive_vertex")
        sd.fragmentFunction = lib.makeFunction(name: "drive_scene_fragment")
        sd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        sd.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = lib.makeFunction(name: "drive_vertex")
        rd.fragmentFunction = lib.makeFunction(name: "drive_reflect_fragment")
        rd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        rd.colorAttachments[0].isBlendingEnabled = true
        rd.colorAttachments[0].sourceRGBBlendFactor = .one
        rd.colorAttachments[0].destinationRGBBlendFactor = .one
        rd.colorAttachments[0].sourceAlphaBlendFactor = .zero
        rd.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let scenePipe = try? device.makeRenderPipelineState(descriptor: sd),
              let reflectPipe = try? device.makeRenderPipelineState(descriptor: rd) else { return nil }
        sky = s; weather = w; warp = gw; trails = tl; screen = sc; reflectCopy = rc
        scene = scenePipe; reflect = reflectPipe
        sky.verticalFOV = 47
        sky.horizonY = Self.horizonY
        sky.viewAzimuth = Self.heading
    }

    // MARK: - Helpers

    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    private static func span(_ s: DriveSpan?) -> SIMD2<Float> {
        guard let s, s.start.isFinite, s.end.isFinite else { return SIMD2(farAway, farAway) }
        return SIMD2(max(-farAway, min(farAway, s.start)), max(-farAway, min(farAway, s.end)))
    }

    /// The neon now: the chord's three colours at the frame's warmth, then the accents.
    nonisolated static func palette(warmth: Float) -> [SIMD3<Float>] {
        var p: [SIMD3<Float>] = []
        for i in 0..<3 { p.append(NeonPalette.colour(slot: i, warmth: warmth)) }
        return p + accents
    }

    /// The tunnel's strobe on the cabin and the view at `distance` (0…1): the light under each ceiling lamp as it passes.
    nonisolated static func strobeWave(distance: Double, spacing: Float) -> Float {
        let s = Double(max(4, spacing.isFinite ? spacing : 14))
        let phase = Float(distance.truncatingRemainder(dividingBy: s) / s)
        return 0.5 + 0.5 * cos(2 * Float.pi * phase)
    }

    // MARK: - Update

    func update(_ frame: DriveFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        let width = Float(max(1, size.width)), height = Float(max(1, size.height))
        let aspect = width / height
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let reduce = frame.reduceMotion

        // The camera: the road's heading, swaying with its curves (not under Reduce Motion), the lens from the frame.
        sky.viewAzimuth = Self.heading + Double(reduce ? 0 : frame.yaw)
        sky.roll = Double(reduce ? 0 : frame.roll)
        let fov = frame.fov.isFinite ? min(60, max(36, frame.fov)) : 47
        sky.verticalFOV = Double(fov)
        sky.horizonY = Self.horizonY
        sky.update(s, quality: quality, size: size, time: t)
        // The falling rain (none in the tunnel: the frame's sky has none there), slowed while the drop's release hangs it.
        rainSpeed = 1 - 0.85 * Self.unit(frame.rainSlow)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt * Double(rainSpeed), surface: .none)
        showWarp = frame.warp != nil
        if let w = frame.warp {
            warp.centre = SIMD2(0, 0.08)
            warp.update(w, trails: 0.6, nebula: 0.55, intensity: FlashLimiter.sparkleScale(gentle: gentle), quality: quality,
                        size: size, dt: dt, time: t)
        }

        // Flashes, through the limiter: the Drop's wave flaring the city, far lightning, the tunnel's lights strobing.
        let mood = frame.mood
        let base: Float = MoodLook.exposure(mood)
        var waveEnv: Float = 0
        var waveAge: Float = -1
        var waveStrength: Float = 0
        if let w = frame.wave {
            waveAge = w.age
            waveStrength = Self.unit(w.strength)
            waveEnv = waveStrength * (1 - exp(-w.age / 0.08)) * exp(-w.age / 0.6)
        }
        let bolt: Float = Self.unit(frame.lightning?.light ?? 0)
        inTunnel = frame.tunnel.map { $0.start <= 0 && $0.end > 0 } ?? false
        let mps = NeonNightDriveModel.metresPerSecond(frame.speed)
        let spacing = max(4, frame.tunnelLightSpacing.isFinite ? frame.tunnelLightSpacing : 14)
        strobeHz = inTunnel ? mps / spacing : 0
        let strobe: Float = inTunnel && !gentle ? Self.strobeWave(distance: frame.distance, spacing: spacing) : 0
        let asked: Float = gentle ? 0 : 0.28 * waveEnv + 0.45 * bolt + 0.12 * strobe
        limiter.gentle = gentle
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: 1, dt: dt)
        exposureOut = limited.exposure
        let passed: Float = asked > 1e-4 ? Self.unit((limited.exposure / base - 1) / asked) : 1
        // Gentle: the wave is a slow glow on the signs, the lightning a glow in the cloud with no bolt, no strobe.
        waveLight = gentle ? 0.4 * waveStrength : waveStrength * max(passed, 0.35)
        lightningLight = gentle ? 0.3 * bolt : bolt * passed
        strobeLight = gentle ? 0 : strobe * passed
        let rise: Float = gentle ? 0.5 : 0.05

        // The light: night, the sky's ambient, the rain-soaked air glowing with the city, the skyglow on the cloud base.
        let alt = Float(s.sun.altitude.isFinite ? s.sun.altitude : -30)
        let night: Float = 1 - Self.smooth(-12, -3, alt)
        let sunUp: Float = Self.smooth(-2, 8, alt)
        let warmth = Self.unit(frame.neonWarmth)
        let pal = Self.palette(warmth: warmth)
        let avg: SIMD3<Float> = (pal[0] + pal[1] + pal[2]) / 3
        let rain = Self.unit(frame.rain)
        let wetRain: Float = max(rain, Self.unit(frame.glassRain))
        let ambient: SIMD3<Float> = (s.zenith * 0.7 + s.horizon * 0.3) * 0.8
        let hazeNight: SIMD3<Float> = (SIMD3<Float>(0.034, 0.022, 0.03) * 0.8 + avg * 0.012) * (0.55 + 0.9 * wetRain)
        let hazeDay: SIMD3<Float> = s.horizon * 0.9
        let haze: SIMD3<Float> = hazeNight * night + hazeDay * (1 - night)
        let hazeDistance: Float = 1300 - 500 * wetRain - 300 * Self.unit(s.mist)
        let glowColour: SIMD3<Float> = SIMD3<Float>(1.0, 0.48, 0.40) * 0.75 + avg * 0.25
        let glowStrength: Float = 0.3 * (0.6 + 0.4 * Self.unit(s.cloudCover))

        // The rows.
        let tanV = Float(tan(Double(fov) * .pi / 360))
        let octaves: Float = quality == .lite ? 2 : 3
        u[Self.rowA] = SIMD4(aspect, t, octaves, 2 * tanV / height)
        let hd = Float(Self.heading * .pi / 180)
        u[Self.rowAxes] = SIMD4(sin(hd), cos(hd), cos(hd), -sin(hd))
        let wrapped = Float(frame.distance.truncatingRemainder(dividingBy: Self.worldWrap))
        u[Self.rowMove] = SIMD4(wrapped, frame.speed, mps, night)
        u[Self.rowNeon] = SIMD4(warmth, Self.unit(frame.neon), max(0.3, min(1.2, frame.cityLight)), 0)
        u[Self.rowWave] = SIMD4(waveAge, waveLight, strobeLight, rise)
        u[Self.rowPlay] = SIMD4(Self.unit(frame.energy), Self.unit(frame.tension), Self.unit(frame.drop), Self.unit(frame.closeIn))
        let tunnel = Self.span(frame.tunnel), bridge = Self.span(frame.bridge)
        u[Self.rowRoute] = SIMD4(tunnel.x, tunnel.y, bridge.x, bridge.y)
        let offset = Float(frame.distance.truncatingRemainder(dividingBy: Double(spacing)))
        u[Self.rowRoute2] = SIMD4(Self.unit(frame.parting), spacing, offset, 0)
        u[Self.rowRain] = SIMD4(rain, Self.unit(frame.glassRain), Self.unit(s.wetness), Self.unit(frame.rainSlow))
        u[Self.rowAmb] = SIMD4(ambient, sunUp)
        u[Self.rowHaze] = SIMD4(haze, hazeDistance)
        u[Self.rowGlow] = SIMD4(glowColour, glowStrength)
        if let l = frame.lightning {
            u[Self.rowFlash] = SIMD4(lightningLight, max(-1, min(1, l.across)), Float(l.seed % 1000) / 1000, gentle ? 1 : 0)
        } else {
            u[Self.rowFlash] = SIMD4(0, 0, 0, gentle ? 1 : 0)
        }
        if let o = frame.overpass {
            u[Self.rowOver] = SIMD4(o.ahead, o.depth, o.rail ? 1 : 0, o.trainX ?? -Self.farAway)
            u[Self.rowOver2] = SIMD4(o.trainLength, 0, 0, 0)
        } else {
            u[Self.rowOver] = SIMD4(Self.farAway, 0, 0, -Self.farAway)
            u[Self.rowOver2] = .zero
        }
        if let b = frame.bloom {
            u[Self.rowBloom] = SIMD4(b.at, Self.unit(b.light), Float(b.seed % 1000) / 1000, 0)
        } else {
            u[Self.rowBloom] = SIMD4(-1, 0, 0, 0)
        }
        u[Self.rowDead] = SIMD4(frame.deadSign.map { Float($0) } ?? -1, Self.unit(frame.deadLight), 0, 0)
        u[Self.rowRoad1] = SIMD4(DriveRoad.leftParapet, DriveRoad.leftEdge, DriveRoad.medianNear, DriveRoad.medianFar)
        u[Self.rowRoad2] = SIMD4(DriveRoad.farParapet, DriveRoad.parapetHeight, DriveRoad.medianHeight, DriveRoad.laneWidth)
        u[Self.rowRoad3] = SIMD4(DriveRoad.ourLane, DriveRoad.eyeHeight, 0, 0)
        for i in 0..<Self.signRows { u[Self.signBase + i] = .zero }
        for (i, v) in frame.signs.prefix(Self.signRows * 4).enumerated() {
            u[Self.signBase + i / 4][i % 4] = v.isFinite ? min(2, max(0, v)) : 0
        }
        for i in 0..<Self.studSlots { u[Self.studBase + i] = .zero }
        for (i, st) in frame.studs.suffix(Self.studSlots).enumerated() {
            u[Self.studBase + i] = SIMD4(max(0.01, st.ahead), Self.unit(st.brightness), 0, 0)
        }
        for i in 0..<Self.carSlots {
            u[Self.carBase + i * 2] = SIMD4(0, -Self.farAway, 0, 0)
            u[Self.carBase + i * 2 + 1] = .zero
        }
        for (i, c) in frame.cars.prefix(Self.carSlots).enumerated() {
            u[Self.carBase + i * 2] = SIMD4(DriveRoad.laneCentre(c.lane), c.ahead, c.oncoming ? 1 : 0, Self.unit(c.brake))
            u[Self.carBase + i * 2 + 1] = SIMD4(Float(c.seed % 1000) / 1000, c.lightBar ? 1 : 0, 0, 0)
        }
        for i in 0..<Self.palRows { u[Self.palBase + i] = SIMD4(pal[i], 0) }

        // Light Trails, and the windscreen with its rain, wipers and the keys' strip.
        trails.update(frame, quality: quality, gentle: gentle)
        let wave: Float = waveAge >= 0 ? waveLight * exp(-max(0, waveAge) / 0.6) : 0
        let cabin: SIMD3<Float> = haze * 2.5 + glowColour * glowStrength * 0.5 + avg * (0.08 * wave)
        screen.update(spec: .windscreen(aspect: aspect), wipers: frame.wipers, glassRain: frame.glassRain, speed: frame.speed,
                      cabinLight: cabin, strobe: strobeLight, keys: frame.keys, keyColour: pal[0],
                      showKeys: p.number("keys.show") > 0.5, quality: quality, dt: dt, aspect: aspect, time: t)

        post = PostSettings(
            bloom: 0.6, bloomThreshold: 0.9,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.06, vignette: 0.35,
            exposure: limited.exposure * weather.exposureBoost,
            warmth: MoodLook.warmthOffset(mood) + s.warmthGrade,
            time: t, quality: quality)
    }

    // MARK: - Render

    /// A pass over the scene's colour alone (the scene's depth is read as a texture in it).
    private func colourPass(_ hdr: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = hdr
        p.colorAttachments[0].loadAction = .load
        p.colorAttachments[0].storeAction = .store
        return p
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let hdr = stack.hdrTarget, let depth = stack.depthTarget,
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        e.setRenderPipelineState(scene)
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if showWarp { warp.draw(e) }
        weather.draw(e)
        e.endEncoding()
        // The wet road's and the harbour's mirror of the city, and Light Trails.
        if let view = reflectCopy.make(from: hdr, commandBuffer: cb), let e2 = cb.makeRenderCommandEncoder(descriptor: colourPass(hdr)) {
            e2.setRenderPipelineState(reflect)
            skyU.withUnsafeBytes { e2.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            u.withUnsafeBytes { e2.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e2.setFragmentTexture(view, index: 0)
            e2.setFragmentTexture(depth, index: 1)
            e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            trails.draw(e2, depth: depth, sky: skyU, drive: u)
            e2.endEncoding()
        }
        // The windscreen: the rain on the glass and the wipers, then the cabin round it.
        if let view = screen.makeView(from: hdr, commandBuffer: cb), let e3 = cb.makeRenderCommandEncoder(descriptor: colourPass(hdr)) {
            screen.drawGlass(e3, view: view)
            screen.drawCabin(e3, view: view)
            e3.endEncoding()
        }
    }
}
