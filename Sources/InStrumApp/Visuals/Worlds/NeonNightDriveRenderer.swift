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
    nonisolated static let rowMoon = 78, rowCabin = 79, rowPillars = 80
    /// Each car's cone (`carCone`): the direction to its lights and the cosine past which a ray misses its glow.
    nonisolated static let carConeBase = 81
    /// The view's tiles (`carTiles`: 16 across, 9 up, four to a row): the cars whose cones reach into each; then
    /// (`streakTiles`) the cars whose mirror streaks on the road can show in each.
    nonisolated static let carTileBase = 93, tileColumns = 16, tileRows = 9
    nonisolated static let streakTileBase = 129
    /// The Sky kit's `SkyU` rows for the moon: its direction and phase, then lit fraction, earthshine, radius.
    nonisolated static let skyMoonRow = 6
    nonisolated static let uniformCount = 165
    /// A car's mirror streak on the wet road lies within this bearing (rad) of its light's, seen from the eye: the road's
    /// `roadStreak` reads none past six of its widths sideways (at most 0.0218 rad: |sin| 0.1308).
    nonisolated static let streakBearing: Float = 0.1312

    /// A car's cone for the shader (MSL `carCone`): the unit direction from the eye to the middle of its lights (the
    /// road's frame: x right, y up, z ahead) and the cosine of the angle within which a ray passes nearer to it than its
    /// glow reaches (19.6 m for an oncoming car's headlights, 13.6 for taillights and spray; its face is well inside
    /// that): a ray with |cos| under it reads none of the car. An empty slot is never read (2); a car nearer than its
    /// reach always is (−1).
    /// The ray (the road's frame) through a point of the view (NDC), from the sky's camera rows and the road's axes: the
    /// shader's `driveRay`.
    nonisolated static func tileRay(_ x: Float, _ y: Float, right rt: SIMD4<Float>, up: SIMD4<Float>, forward fw: SIMD4<Float>,
                                    axes ax: SIMD4<Float>) -> SIMD3<Float> {
        let f = SIMD3<Float>(fw.x, fw.y, fw.z), r = SIMD3<Float>(rt.x, rt.y, rt.z), v = SIMD3<Float>(up.x, up.y, up.z)
        let e = simd_normalize(f + r * (x * rt.w) + v * (y * up.w))
        return SIMD3<Float>(e.x * ax.z + e.y * ax.w, e.z, e.x * ax.x + e.y * ax.y)
    }

    private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(min(1, max(-1, simd_dot(a, b)))) }

    nonisolated static func carCone(x: Float, ahead: Float, oncoming: Bool, eye: Float) -> SIMD4<Float> {
        guard ahead > -1e4, x.isFinite, ahead.isFinite else { return SIMD4(0, 0, 0, 2) }
        let c = SIMD3<Float>(x, 0.7 - eye, ahead)
        let len = simd_length(c)
        let reach: Float = oncoming ? 19.6 : 13.6
        guard len > reach else { return SIMD4(0, 0, 0, -1) }
        let n = c / len
        let share = reach / len
        return SIMD4(n.x, n.y, n.z, (1 - share * share).squareRoot())
    }

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
    /// The warm white of a few signs (the third accent; the first two are the other family's, so a warm city keeps a few
    /// cool signs and a cool one a few warm).
    nonisolated static let warmWhite = SIMD3<Float>(1.0, 0.78, 0.5)

    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    let trails: LightTrailsLayer
    let screen: WindscreenLayer
    let reflectCopy: ViewCopy
    private let scene: SkyPipeline
    private let reflect: MTLRenderPipelineState
    /// The wet road's mirror drawn at half resolution (`drive_mirror_fragment`, into `mirrorTarget`), added in at full
    /// resolution (`drive_mirror_compose_fragment`), which hides it behind nearer things pixel by pixel.
    private let mirrorHalf, mirrorCompose: MTLRenderPipelineState
    private let device: MTLDevice
    private var mirrorTarget: MTLTexture?
    /// The mirror's share of the view's width and height: half on High, a quarter on Smooth (it is a blur six or more of
    /// the view's pixels wide, streaked down the road).
    private(set) var mirrorScale: Float = 0.5
    /// The mirror's targets made so far (tests: one a size, never one a frame).
    private(set) var mirrorAllocations = 0
    private var u = [SIMD4<Float>](repeating: .zero, count: NeonNightDriveRenderer.uniformCount)
    /// The cars' cones' half-angles this frame (rad; −1 an empty slot, 4 a car nearer than its reach), and their lights'
    /// bearings from the eye (rad, the road's frame; 100 an empty slot).
    private var carHalf = [Float](repeating: -1, count: NeonNightDriveRenderer.carSlots)
    private var carBearing = [Float](repeating: 100, count: NeonNightDriveRenderer.carSlots)
    private var limiter = FlashLimiter()
    private var limiterStarted = false
    private var showWarp = false
    private(set) var post = PostSettings()
    /// Layers a timing test skips (0 in the app: everything is drawn), so one run can price each on a slow GPU. The scene's
    /// bits: 1 the road's shading, 2 the rows of towers along the road, 4 the downtown, 8 the street below, 16 the cars,
    /// 32 the street lights' glow, 64 the cars' glow, 128 the sky; the renderer's: 256 the wet road's mirror, 512 Light
    /// Trails, 1024 the windscreen's glass, 2048 the cabin, 4096 the weather, 8192 everything after the scene's pass; and
    /// the scene's again: 65536 the facades' windows and walls (a flat dark), 131072 the neon signs, 262144 the parapets
    /// along the road, 524288 the haze over what's hit.
    var skipLayers: UInt32 = 0

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
        let scenePipe = SkyPipeline(program: { program in
            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = lib.skyFunction("drive_vertex", program: program)
            sd.fragmentFunction = lib.skyFunction("drive_scene_fragment", program: program)
            sd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            sd.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: sd)
        })
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = lib.skyFunction("drive_vertex")
        rd.fragmentFunction = lib.skyFunction("drive_reflect_fragment")
        rd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        rd.colorAttachments[0].isBlendingEnabled = true
        rd.colorAttachments[0].sourceRGBBlendFactor = .one
        rd.colorAttachments[0].destinationRGBBlendFactor = .one
        rd.colorAttachments[0].sourceAlphaBlendFactor = .zero
        rd.colorAttachments[0].destinationAlphaBlendFactor = .one
        // The mirror at half resolution (written whole, no blending), and the pass that adds it in at full resolution
        // (additive, as the full-resolution mirror was).
        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.skyFunction("drive_vertex")
        md.fragmentFunction = lib.skyFunction("drive_mirror_fragment")
        md.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        rd.fragmentFunction = lib.skyFunction("drive_mirror_compose_fragment")
        guard let composePipe = try? device.makeRenderPipelineState(descriptor: rd) else { return nil }
        rd.fragmentFunction = lib.skyFunction("drive_reflect_fragment")
        guard let scenePipe, let reflectPipe = try? device.makeRenderPipelineState(descriptor: rd),
              let mirrorPipe = try? device.makeRenderPipelineState(descriptor: md) else { return nil }
        sky = s; weather = w; warp = gw; trails = tl; screen = sc; reflectCopy = rc
        scene = scenePipe; reflect = reflectPipe; mirrorHalf = mirrorPipe; mirrorCompose = composePipe
        self.device = device
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

    /// The neon now: the chord's three colours at the frame's warmth, then the accents (the other family's first and
    /// third colours, and a warm white).
    nonisolated static func palette(warmth: Float) -> [SIMD3<Float>] {
        let w: Float = warmth.isFinite ? min(1, max(0, warmth)) : 0.5
        return [NeonPalette.colour(slot: 0, warmth: w), NeonPalette.colour(slot: 1, warmth: w),
                NeonPalette.colour(slot: 2, warmth: w), NeonPalette.colour(slot: 0, warmth: 1 - w),
                NeonPalette.colour(slot: 2, warmth: 1 - w), warmWhite]
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
        sky.gentle = gentle
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
        // The first frame starts at its exposure (a world appearing doesn't rise from black, which gentle visuals' slower
        // rise would count as a flash).
        limiter.gentle = gentle && limiterStarted
        limiterStarted = true
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: 1, dt: dt)
        limiter.gentle = gentle
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
        let hazeNight: SIMD3<Float> = (SIMD3<Float>(0.010, 0.014, 0.028) + avg * 0.010) * (0.55 + 0.9 * wetRain)
        let hazeDay: SIMD3<Float> = s.horizon * 0.9
        let haze: SIMD3<Float> = hazeNight * night + hazeDay * (1 - night)
        let hazeDistance: Float = 1300 - 500 * wetRain - 300 * Self.unit(s.mist)
        let glowColour: SIMD3<Float> = SIMD3<Float>(0.85, 0.52, 0.58) * 0.5 + avg * 0.5
        let glowStrength: Float = 0.3 * (0.6 + 0.4 * Self.unit(s.cloudCover))

        // The rows.
        let tanV = Float(tan(Double(fov) * .pi / 360))
        let octaves: Float = quality == .lite ? 2 : 3
        mirrorScale = quality == .lite ? 0.25 : 0.5
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
            u[Self.carConeBase + i] = SIMD4(0, 0, 0, 2)
        }
        for (i, c) in frame.cars.prefix(Self.carSlots).enumerated() {
            let x = DriveRoad.laneCentre(c.lane)
            u[Self.carBase + i * 2] = SIMD4(x, c.ahead, c.oncoming ? 1 : 0, Self.unit(c.brake))
            u[Self.carBase + i * 2 + 1] = SIMD4(Float(c.seed % 1000) / 1000, c.lightBar ? 1 : 0, 0, 0)
            u[Self.carConeBase + i] = Self.carCone(x: x, ahead: c.ahead, oncoming: c.oncoming, eye: DriveRoad.eyeHeight)
        }
        fillCarTiles()
        for i in 0..<Self.palRows { u[Self.palBase + i] = SIMD4(pal[i], 0) }
        // The moon, drawn by the drive itself as a dim glow behind the overcast (the Sky kit's disc is hidden in `render`):
        // its direction and how much of it shows (its lit part, none by day or below the horizon).
        let su = sky.uniforms
        let m = su[Self.skyMoonRow], mi = su[Self.skyMoonRow + 1]
        let moonUp: Float = m.z > -0.02 ? 1 : 0
        let lit: Float = Self.unit(mi.x)
        u[Self.rowMoon] = SIMD4(m.x, m.y, m.z, moonUp * night * (0.35 + 0.65 * lit))

        // Light Trails, and the windscreen with its rain, wipers and the keys' strip.
        trails.update(frame, quality: quality, gentle: gentle)
        let wave: Float = waveAge >= 0 ? waveLight * exp(-max(0, waveAge) / 0.6) : 0
        let cabin: SIMD3<Float> = haze * 2.5 + glowColour * glowStrength * 0.5 + avg * (0.08 * wave)
        // The cabin's outline, so the road never mirrors what the pillars hide from you.
        let glass = WindowSpec.windscreen(aspect: aspect)
        if let w = glass.windscreen {
            // (Deep under the dashboard, 0.2 below its lowest point: the glass's most blurred drops look no farther
            // down than 0.19 past the glass's foot, so nothing drawn there is seen.)
            let hiddenBelow = w.dash + min(0, w.dashCurve) - 0.2
            u[Self.rowCabin] = SIMD4(w.dash, w.roof, hiddenBelow + 3, 0)
            u[Self.rowPillars] = SIMD4(w.leftPillar.x, w.leftPillar.y, w.rightPillar.x, w.rightPillar.y)
        }
        screen.update(spec: glass, wipers: frame.wipers, glassRain: frame.glassRain, speed: frame.speed,
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

    /// The cars' tiles: for each of the view's 16 × 9 tiles, the cars (bits) a ray through it can meet, face or glow. A
    /// car whose cone (half-angle α round its axis, or its opposite) is farther from the tile's middle ray than α and the
    /// tile's own reach (its corners' angle from the middle, with a margin) can't be met there: its bit is clear, and the
    /// shader passes it by without reading it. Cars with a cone too wide to tell are in every tile.
    private func fillCarTiles() {
        let su = sky.uniforms
        let rt = su[0], up = su[1], fw = su[2], ax = u[Self.rowAxes]
        for c in 0..<Self.carSlots {
            let w = u[Self.carConeBase + c].w
            carHalf[c] = w > 1.5 ? -1 : (w < 0 ? 4 : acos(min(1, w)))
            let car = u[Self.carBase + c * 2]
            carBearing[c] = car.y > -1e4 ? atan2(car.x, car.y) : 100
        }
        let cw = 2 / Float(Self.tileColumns), ch = 2 / Float(Self.tileRows)
        for ty in 0..<Self.tileRows {
            for tx in 0..<Self.tileColumns {
                let x0 = -1 + cw * Float(tx), y0 = -1 + ch * Float(ty)
                let mid = Self.tileRay(x0 + 0.5 * cw, y0 + 0.5 * ch, right: rt, up: up, forward: fw, axes: ax)
                let a = Self.angle(mid, Self.tileRay(x0, y0, right: rt, up: up, forward: fw, axes: ax))
                let b = Self.angle(mid, Self.tileRay(x0 + cw, y0, right: rt, up: up, forward: fw, axes: ax))
                let c = Self.angle(mid, Self.tileRay(x0, y0 + ch, right: rt, up: up, forward: fw, axes: ax))
                let d = Self.angle(mid, Self.tileRay(x0 + cw, y0 + ch, right: rt, up: up, forward: fw, axes: ax))
                let spread = max(max(a, b), max(c, d)) * 1.05 + 0.002
                var mask: Float = 0
                for k in 0..<Self.carSlots where carHalf[k] >= 0 {
                    let reach = carHalf[k] + spread
                    let cone = u[Self.carConeBase + k]
                    if reach >= 1.5 || abs(simd_dot(mid, SIMD3<Float>(cone.x, cone.y, cone.z))) >= cos(reach) {
                        mask += Float(1 << k)
                    }
                }
                let i = ty * Self.tileColumns + tx
                u[Self.carTileBase + i / 4][i % 4] = mask
                // The streaks: the tile's bearings (its edges' and middle's, from the eye; the view looks ahead, so
                // none wraps), widened by the streaks' reach and a margin.
                var lo: Float = 10, hi: Float = -10
                for (fx, fy) in Self.tileSamples {
                    let r = Self.tileRay(x0 + fx * cw, y0 + fy * ch, right: rt, up: up, forward: fw, axes: ax)
                    let b = atan2(r.x, r.z)
                    lo = min(lo, b); hi = max(hi, b)
                }
                lo -= Self.streakBearing + 0.01
                hi += Self.streakBearing + 0.01
                var streaks: Float = 0
                for k in 0..<Self.carSlots where carBearing[k] < 50 {
                    let b = carBearing[k]
                    if b >= lo && b <= hi { streaks += Float(1 << k) }
                }
                u[Self.streakTileBase + i / 4][i % 4] = streaks
            }
        }
    }

    /// Where a tile's bearings are sampled (shares of its width and height): its corners, its edges' middles, its middle.
    private static let tileSamples: [(Float, Float)] = [(0, 0), (0.5, 0), (1, 0), (0, 0.5), (0.5, 0.5), (1, 0.5),
                                                        (0, 1), (0.5, 1), (1, 1)]

    /// The mirror's target for a scene `width` × `height` at `scale` (made when the size changes, kept).
    private func mirrorTexture(width: Int, height: Int, scale: Float) -> MTLTexture? {
        let w = max(1, Int((Float(width) * scale).rounded(.up))), h = max(1, Int((Float(height) * scale).rounded(.up)))
        if mirrorTarget?.width != w || mirrorTarget?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            mirrorTarget = device.makeTexture(descriptor: d)
            mirrorAllocations += 1
        }
        return mirrorTarget
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)   // the supercell's impostor, before the frame's passes
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let hdr = stack.hdrTarget, let depth = stack.depthTarget,
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        // The Sky kit's moon would be a crisp disc on the overcast: set it below the horizon here (the drive draws its own,
        // dim, behind the cloud, from `rowMoon`).
        var skyU = sky.uniforms
        skyU[Self.skyMoonRow] = SIMD4(0, 0, -1, skyU[Self.skyMoonRow].w)
        e.setRenderPipelineState(scene.state(sky.program))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        u[Self.rowRoad3].w = Float((skipLayers & 0xFF) | ((skipLayers >> 8) & 0xF00))
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        u[Self.rowRoad3].w = 0
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if showWarp { warp.draw(e) }
        if skipLayers & 4096 == 0 { weather.draw(e) }
        e.endEncoding()
        if skipLayers & 8192 != 0 { return }
        // The wet road's and the harbour's mirror of the city (drawn at half resolution first), and Light Trails.
        if let view = reflectCopy.make(from: hdr, commandBuffer: cb) {
            var mirror: MTLTexture?
            if skipLayers & 256 == 0, let target = mirrorTexture(width: hdr.width, height: hdr.height, scale: mirrorScale) {
                let mp = MTLRenderPassDescriptor()
                mp.colorAttachments[0].texture = target
                mp.colorAttachments[0].loadAction = .dontCare
                mp.colorAttachments[0].storeAction = .store
                if let em = cb.makeRenderCommandEncoder(descriptor: mp) {
                    em.setRenderPipelineState(mirrorHalf)
                    skyU.withUnsafeBytes { em.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                    u.withUnsafeBytes { em.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                    em.setFragmentTexture(view, index: 0)
                    em.setFragmentTexture(depth, index: 1)
                    em.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    em.endEncoding()
                    mirror = target
                }
            }
            if let e2 = cb.makeRenderCommandEncoder(descriptor: colourPass(hdr)) {
                if skipLayers & 256 == 0 {
                    skyU.withUnsafeBytes { e2.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                    u.withUnsafeBytes { e2.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                    if let mirror {
                        e2.setRenderPipelineState(mirrorCompose)
                        e2.setFragmentTexture(mirror, index: 0)
                    } else {
                        e2.setRenderPipelineState(reflect)
                        e2.setFragmentTexture(view, index: 0)
                    }
                    e2.setFragmentTexture(depth, index: 1)
                    e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                if skipLayers & 512 == 0 { trails.draw(e2, depth: depth, sky: skyU, drive: u) }
                e2.endEncoding()
            }
        }
        // The windscreen: the rain on the glass and the wipers, then the cabin round it.
        if let view = screen.makeView(from: hdr, commandBuffer: cb), let e3 = cb.makeRenderCommandEncoder(descriptor: colourPass(hdr)) {
            if skipLayers & 1024 == 0 { screen.drawGlass(e3, view: view) }
            if skipLayers & 2048 == 0 { screen.drawCabin(e3, view: view) }
            e3.endEncoding()
        }
    }
}
