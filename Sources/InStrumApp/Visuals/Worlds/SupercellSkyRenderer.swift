import Metal
import CoreGraphics
import simd
import InStrumCore

/// One stretch of a strike's channel in the storm's frame (km), and whether it is a branch and inside the cloud.
struct SupercellChannelSegment {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var branch: Bool
    var cloud: Bool
}

/// Draws Supercell Sky (Storms spec §8): a wheat field at golden hour with the camera facing away from the low sun, and
/// the supercell filling the sky over it. One full-screen pass draws the sky, the storm and the field
/// (`SupercellSkyShaders`); the rain, Galaxy Warp, the flock and the fence posts (the keys) go over it.
///
/// The storm is placed in kilometres around the camera from the frame's distance; the renderer turns the model's state
/// into the shader's rows: the turn and the inflow, the glows up the bands, the chords' pulse in the base, the runs'
/// ripples, the strikes (their channels drawn here as polylines and projected), the sky's anvil crawlers, the gust
/// front's dust, the wheat's rows leaning with the wind field (one sample a row: 48, 24 on Smooth), the light after the
/// storm. Every flash goes through a `FlashLimiter` (gentle visuals make the strikes glows inside the cloud); the camera
/// shakes and dollies only as the model says (never under Reduce Motion, and never on Smooth). Nothing is allocated per
/// frame: the instances go by `setVertexBytes`.
@MainActor
final class SupercellSkyRenderer: ThemeRenderer {
    // MARK: The shader's rows (MSL `CellU`)
    nonisolated static let rowA = 0, rowCam = 1, rowAxes = 2, rowPlace = 3, rowSpin = 4, rowLook = 5, rowSunCol = 6
    nonisolated static let rowSunL = 7, rowAmb = 8, rowHaze = 9, rowPlay = 10, rowWall = 11, rowShaft = 12, rowGust = 13
    nonisolated static let rowAfter = 14, rowFunnel = 15, rowGlowL = 16, rowDims = 17, rowExtra = 18
    nonisolated static let rippleBase = 19, rippleSlots = 4
    nonisolated static let glowBase = 23, glowSlots = 8
    nonisolated static let strikeInfoBase = 31, strikeBoxBase = 33, strikeAtBase = 35, strikeSlots = 2
    nonisolated static let segBase = 37, segsPerStrike = 24
    nonisolated static let crawlInfoBase = 85, crawlerSlots = 4
    nonisolated static let crawlBase = 89, segsPerCrawler = 16
    nonisolated static let grassBase = 153, grassSlots = 48
    nonisolated static let uniformCount = 201

    // MARK: The view and the storm's shape (km)
    nonisolated static let verticalFOV = 64.0
    nonisolated static let horizonY: Float = -0.5
    nonisolated static let eyeKm: Float = 0.0017
    nonisolated static let baseHeight: Float = 1.3
    nonisolated static let baseRadius: Float = 9.5
    nonisolated static let towerTop: Float = 9.5
    nonisolated static let anvilHeight: Float = 11.5
    nonisolated static let anvilReach: Float = 13
    nonisolated static let wallRadius: Float = 2.4
    nonisolated static let wallBottom: Float = 0.38
    nonisolated static let shaftRadius: Float = 1.8
    /// The gust front's dust: billows this tall (km) rolling off the field along the front (up to 1.3× in places), so a
    /// front crossing the near field lifts dust about the posts' height and the storm stays seen over it.
    nonisolated static let dustHeight: Float = 0.0042
    /// The wheat: blades this tall (m); the rows from 6 m to 600 m out.
    nonisolated static let bladeHeight: Float = 0.75
    nonisolated static let nearestRow: Float = 6
    nonisolated static let rowSpan: Float = 100
    /// The rows of wheat sampled from the wind field: 48, 24 on Smooth.
    nonisolated static func rowCount(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }
    /// A strike's channel: blue-white, never red.
    nonisolated static let strikeColour = SIMD3<Float>(0.78, 0.86, 1.0)

    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let birds, posts: MTLRenderPipelineState
    private var cellU = [SIMD4<Float>](repeating: .zero, count: SupercellSkyRenderer.uniformCount)
    private var birdInstances: [SIMD4<Float>] = []
    private var postInstances: [SIMD4<Float>] = []
    private var view = SIMD4<Float>(16.0 / 9, 0, 0, 0)
    private var postLight = SIMD4<Float>(1, 1, 1, 1)
    private var limiter = FlashLimiter()
    private var pulseLimiter = FlashLimiter()
    private var flow: Float = 0
    private(set) var post = PostSettings()
    /// Layers a timing test skips (0 in the app: everything is drawn), so one run can price each on a slow GPU. The scene's
    /// bits: 1 the tower, 2 the flanking line, 4 the anvil, 8 the wall cloud, 16 the base, 32 the hail and the rain core,
    /// 64 the inflow, the funnel and the dust, 128 the sky, 256 the field, 8192 the wheat, 512 the trees, the silo and the
    /// light after the storm, 1024 the lightning; the renderer's: 2048 the weather, 4096 the flock and the posts.
    var skipLayers: UInt32 = 0

    /// What was drawn (tests read them): the rows of wheat (distance m, lean across at the tip m, height kept, sheen),
    /// the strikes' light after the limiter and whether their channels were drawn (not under gentle visuals), the shake
    /// applied (NDC), the birds and the posts drawn, the keys' rectangles, where the storm's parts stand on screen.
    private(set) var grassRows: [SIMD4<Float>] = []
    private(set) var strikeLight: Float = 0
    private(set) var channelsDrawn = false
    private(set) var shakeApplied = SIMD2<Float>(0, 0)
    private(set) var birdCount = 0
    private(set) var exposureOut: Float = 1
    private(set) var keyTop: Float = -0.76
    private(set) var wallCentreNDC = SIMD2<Float>(0, 0)
    private(set) var stormCentreNDC = SIMD2<Float>(0, 0)
    /// The flashes the limiters counted: the screen's within the last second and in all, the base's pulses.
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }
    var pulseFlashesInLastSecond: Int { pulseLimiter.recent }
    var keyRects: [SIMD4<Float>] { stride(from: 0, to: postInstances.count, by: 2).map { postInstances[$0] } }
    /// The shader's rows (tests read them).
    var uniforms: [SIMD4<Float>] { cellU }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: SupercellSkyShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, blend: Bool, keepDepth: Bool, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if keepDepth { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let sc = SkyPipeline(build: { make("cell_vertex", "cell_scene_fragment", blend: false, keepDepth: false, storms: $0) }),
              let bd = make("cell_bird_vertex", "cell_bird_fragment", blend: true, keepDepth: true),
              let ps = make("cell_post_vertex", "cell_post_fragment", blend: true, keepDepth: false) else { return nil }
        sky = s; weather = w; warp = gw; scene = sc; birds = bd; posts = ps
        sky.verticalFOV = Self.verticalFOV
        sky.horizonY = Self.horizonY
        birdInstances.reserveCapacity(StormFlock.count(.high) * 2)
        postInstances.reserveCapacity(88 * 2)
        grassRows.reserveCapacity(Self.grassSlots)
    }

    // MARK: - Helpers

    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The storm's centre on the field (km: x across the view, y ahead) at a distance.
    nonisolated static func stormCentre(km: Float) -> SIMD2<Float> {
        let d = km.isFinite ? max(0, km) : 16.5
        return SIMD2(-0.08 * d, d)
    }

    /// The wall cloud's centre: in front of the storm's centre and to its right, never behind the camera.
    nonisolated static func wallCentre(storm c: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(c.x + 2.3, max(c.y - 5.0, 2.5))
    }

    /// The hail shaft's centre: between the wall cloud and the rain core, in front of the core's curtain.
    nonisolated static func shaftCentre(storm c: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(c.x - 2.4, max(c.y - 1.5, 1.0))
    }

    /// The light the low sun throws on the storm (linear rgb, HDR) at an altitude, and how much it is up (0…1).
    nonisolated static func sunlight(altitude: Double) -> (colour: SIMD3<Float>, up: Float) {
        let alt = Float(altitude.isFinite ? altitude : -90)
        let warm = SIMD3<Float>(1.0, 0.56, 0.32), white = SIMD3<Float>(1.0, 0.97, 0.92)
        let rise: Float = min(1, max(0, alt / 25))
        let k: Float = rise * rise
        let up = min(1, max(0, (alt + 2) / 8))
        let colour: SIMD3<Float> = (warm + (white - warm) * k) * (1.45 * up)
        return (colour, up)
    }

    /// The lean of a row of wheat in a wind (m/s): across (m at the tip, right positive), the height it keeps (0…1) and
    /// its sheen (0…1, the flattened wheat facing the camera catching the light).
    nonisolated static func lean(_ w: SIMD2<Float>) -> SIMD3<Float> {
        let wx = w.x.isFinite ? w.x : 0, wy = w.y.isFinite ? w.y : 0
        let speed = (wx * wx + wy * wy).squareRoot()
        guard speed > 1e-4 else { return SIMD3(0, 1, 0) }
        let bend: Float = min(0.85, speed / 16)
        let across: Float = wx / speed, along: Float = wy / speed
        let lean: Float = bladeHeight * bend * across * 1.1
        let keep: Float = 1 - bend * (0.25 + 0.45 * abs(along))
        let sheen: Float = bend * max(0, -along)
        return SIMD3(lean, keep, sheen)
    }

    /// A point in the storm's frame (km: x across the view, y ahead, z up) on screen (NDC), or nil behind the camera.
    private func project(_ p: SIMD3<Float>, origin: SIMD3<Float>, axes: (fwd: SIMD2<Float>, right: SIMD2<Float>),
                         cam: SkyLayer.Camera) -> SIMD2<Float>? {
        let rel = p - origin
        let east: Float = rel.x * axes.right.x + rel.y * axes.fwd.x
        let north: Float = rel.x * axes.right.y + rel.y * axes.fwd.y
        let dir = SIMD3<Float>(east, north, rel.z)
        let depth = simd_dot(dir, cam.forward)
        guard depth > 1e-4 else { return nil }
        let x = simd_dot(dir, cam.right) / (depth * cam.tanH)
        let y = simd_dot(dir, cam.up) / (depth * cam.tanV)
        return SIMD2(x, y)
    }

    // MARK: - Update

    func update(_ frame: SupercellFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        let width = Float(max(1, size.width)), height = Float(max(1, size.height))
        let aspect = width / height
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        let keysShow = p.number("keys.show") > 0.5
        keyTop = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1

        // The sky, seen the camera's way.
        sky.viewAzimuth = frame.viewAzimuth
        sky.horizonY = Self.horizonY
        sky.verticalFOV = Self.verticalFOV
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: t)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .ground(horizonY: Self.horizonY))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        let az = Float(frame.viewAzimuth * .pi / 180)
        let fwd = SIMD2<Float>(sin(az), cos(az)), right = SIMD2<Float>(cos(az), -sin(az))
        showWarp = frame.warp != nil
        if let w = frame.warp {
            warp.centre = SIMD2(0, 0.35)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: FlashLimiter.sparkleScale(gentle: gentle), quality: quality,
                        size: size, dt: dt, time: t)
        }

        // The storm's place.
        let km = frame.distanceKm.isFinite ? max(0, frame.distanceKm) : 16.5
        let centre = Self.stormCentre(km: km)
        let wall = Self.wallCentre(storm: centre)
        // In the drop (the gust front's dust up) the hail shaft surges out toward the camera under the base.
        let surge = Self.unit(frame.dust)
        let shaft = Self.shaftCentre(storm: centre) + SIMD2<Float>(0.8, -4.5) * surge * min(1, km / 10)
        let dollyMetres: Float = frame.cameraDolly.isFinite ? max(0, frame.cameraDolly) : 0
        let dollyKm: Float = dollyMetres / 1000
        let origin = SIMD3<Float>(0, -dollyKm, Self.eyeKm)

        // The light.
        let sun = Self.sunlight(altitude: s.sun.altitude)
        let sunENU = SkyLayer.enu(s.sun)
        let sunLocal = SIMD3<Float>(sunENU.x * right.x + sunENU.y * right.y, sunENU.x * fwd.x + sunENU.y * fwd.y, sunENU.z)
        let night = 1 - Self.smooth(-15, -4, Float(s.sun.altitude))
        let ambient: SIMD3<Float> = (s.zenith * 0.7 + s.horizon * 0.3) * 0.95
        let hazeColour: SIMD3<Float> = s.horizon * 0.55 + s.zenith * 0.25
        let hazeKm: Float = 80 * (1 - 0.4 * Self.unit(s.mist))

        // Flashes, through the limiter: the strikes' light and the sky's storm light (crawlers, sheet lightning) together.
        var strikeRaw: Float = 0
        for strike in frame.strikes { strikeRaw = max(strikeRaw, Self.unit(strike.brightness)) }
        let stormFlash = Self.unit(s.stormFlash)
        let mood = frame.mood
        let base: Float = MoodLook.exposure(mood) * (1 + 0.6 * night)
        let asked: Float = 0.55 * strikeRaw + 0.5 * stormFlash
        limiter.gentle = gentle
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: 1, dt: dt)
        exposureOut = limited.exposure
        // The share of the asked light the limiter let through, halved again under gentle visuals.
        let gentleScale: Float = gentle ? 0.5 : 1
        let passed: Float = asked > 1e-4 ? Self.unit((limited.exposure / base - 1) / asked) : 1
        let share: Float = passed * gentleScale
        strikeLight = strikeRaw * share
        channelsDrawn = !gentle && strikeLight > 0
        var pulseRaw: Float = 0, spread: Float = 0
        for bp in frame.pulses where bp.brightness > pulseRaw {
            pulseRaw = bp.brightness
            spread = bp.spread
        }
        pulseLimiter.gentle = gentle
        let pulse = Self.unit(pulseLimiter.limit(exposure: Self.unit(pulseRaw), sparkle: 1, dt: dt).exposure)

        // The shake (pixels → NDC): never on Smooth.
        let shakePx = quality == .lite ? SIMD2<Float>(0, 0) : frame.cameraShake
        shakeApplied = SIMD2(2 * shakePx.x / width, 2 * shakePx.y / height)
        view = SIMD4(aspect, shakeApplied.x, shakeApplied.y, 0)
        flow += fdt * (0.006 + 0.02 * Self.unit(frame.energy))
        if flow > 1000 { flow -= 1000 }

        // The rows.
        let octaves: Float = quality == .lite ? 2 : 3
        let tanV = Float(tan(Self.verticalFOV * .pi / 360))
        cellU[Self.rowA] = SIMD4(aspect, t, octaves, 2 * tanV / height)
        cellU[Self.rowCam] = SIMD4(shakeApplied.x, shakeApplied.y, keyTop, 2 / height)
        cellU[Self.rowAxes] = SIMD4(fwd.x, fwd.y, right.x, right.y)
        cellU[Self.rowPlace] = SIMD4(centre.x, centre.y, Self.eyeKm, dollyKm)
        let spacing = frame.inflowSpacing * .pi / 180
        cellU[Self.rowSpin] = SIMD4(frame.rotation, frame.spin, spacing, flow)
        cellU[Self.rowLook] = SIMD4(Self.unit(frame.baseDarkness), min(0.12, max(0, frame.greenCast)), Self.unit(frame.hailDensity),
                                    Self.unit(frame.clearing))
        cellU[Self.rowSunCol] = SIMD4(sun.colour, sun.up)
        cellU[Self.rowSunL] = SIMD4(sunLocal, Float(s.sun.altitude))
        cellU[Self.rowAmb] = SIMD4(ambient, night)
        cellU[Self.rowHaze] = SIMD4(hazeColour, hazeKm)
        cellU[Self.rowPlay] = SIMD4(Self.unit(frame.energy), Self.unit(frame.tension), Self.unit(frame.drop), Self.unit(frame.stormRain))
        cellU[Self.rowWall] = SIMD4(wall.x, wall.y, Self.wallRadius, Self.wallBottom)
        cellU[Self.rowShaft] = SIMD4(shaft.x, shaft.y, Self.shaftRadius, Self.unit(frame.stageWeights.x))
        var front: Float = -1
        if let wave = frame.gustWave { front = (1 - Self.unit(wave)) * SupercellSkyModel.gustStart / 1000 }
        else if frame.dust > 0.01 { front = 0.15 }
        let outflow = Self.unit(-frame.wind.sample(.zero).y / SupercellSkyModel.gustStrength)
        cellU[Self.rowGust] = SIMD4(front, Self.unit(frame.dust), Self.dustHeight, outflow)
        let mammatus: Float = 0.3 + 0.6 * Self.unit(frame.clearing)
        cellU[Self.rowAfter] = SIMD4(Self.unit(frame.after.rays), Self.unit(frame.after.rainbow), Self.unit(frame.after.stars), mammatus)
        let flashScale: Float = share
        if let f = frame.funnel {
            cellU[Self.rowFunnel] = SIMD4(Self.unit(f.reach), t * 0.7, 1, flashScale)
        } else {
            cellU[Self.rowFunnel] = SIMD4(0, 0, 0, flashScale)
        }
        cellU[Self.rowGlowL] = SIMD4(stormFlash, min(0.2, max(0, frame.farCell)), pulse, Self.unit(spread))
        cellU[Self.rowDims] = SIMD4(Self.baseHeight, Self.baseRadius, Self.towerTop, Self.anvilHeight)
        let rows = Self.rowCount(quality)
        let mammatusOctaves: Float = quality == .lite ? 1 : 2
        cellU[Self.rowExtra] = SIMD4(Float(rows), mammatusOctaves, Self.bladeHeight, Self.anvilReach)

        // The runs' ripples and the notes' glows (the brightest, in their slots).
        for i in 0..<Self.rippleSlots { cellU[Self.rippleBase + i] = .zero }
        for (i, r) in frame.ripples.suffix(Self.rippleSlots).enumerated() {
            var a = r.angle
            a -= 2 * Float.pi * (a / (2 * Float.pi)).rounded()
            cellU[Self.rippleBase + i] = SIMD4(a, Self.unit(r.brightness), 0, 0)
        }
        for i in 0..<Self.glowSlots { cellU[Self.glowBase + i] = .zero }
        let glows = frame.glows.sorted { $0.brightness > $1.brightness }.prefix(Self.glowSlots)
        for (i, g) in glows.enumerated() {
            cellU[Self.glowBase + i] = SIMD4(Float(g.band), g.progress, Self.unit(g.brightness), 0)
        }

        // The strikes: each channel a jagged polyline from where it leaves the cloud to the ground at the storm's distance,
        // with branches, projected; the segments inside the cloud first (only a faint glow: the cloud hides them), then
        // the bare channel, then the bare branches.
        let axes = (fwd: fwd, right: right)
        for k in 0..<Self.strikeSlots {
            cellU[Self.strikeInfoBase + k] = .zero
            cellU[Self.strikeBoxBase + k] = .zero
            cellU[Self.strikeAtBase + k] = .zero
            for i in 0..<Self.segsPerStrike { cellU[Self.segBase + k * Self.segsPerStrike + i] = .zero }
        }
        let shown = frame.strikes.sorted { $0.brightness > $1.brightness }.prefix(Self.strikeSlots)
        for (k, strike) in shown.enumerated() {
            let light = Self.unit(strike.brightness) * share
            guard light > 0 else { continue }
            let channel = Self.channel(strike)
            var segs: [SIMD4<Float>] = []
            var inCloud = 0, branchStart = 0
            var lo = SIMD2<Float>(9, 9), hi = SIMD2<Float>(-9, -9)
            for pass in 0..<3 {
                for seg in channel {
                    let wanted: Bool
                    if pass == 0 { wanted = seg.cloud }
                    else if pass == 1 { wanted = !seg.branch && !seg.cloud }
                    else { wanted = seg.branch && !seg.cloud }
                    guard wanted, segs.count < Self.segsPerStrike,
                          let a = project(seg.a, origin: origin, axes: axes, cam: cam),
                          let b = project(seg.b, origin: origin, axes: axes, cam: cam) else { continue }
                    segs.append(SIMD4(a.x, a.y, b.x, b.y))
                    lo = simd_min(lo, simd_min(a, b)); hi = simd_max(hi, simd_max(a, b))
                    if pass == 0 { inCloud += 1 }
                }
                if pass == 1 { branchStart = segs.count }
            }
            guard !segs.isEmpty else { continue }
            for (i, seg) in segs.enumerated() { cellU[Self.segBase + k * Self.segsPerStrike + i] = seg }
            let top = project(channel[0].a, origin: origin, axes: axes, cam: cam) ?? SIMD2((lo.x + hi.x) / 2, hi.y)
            cellU[Self.strikeInfoBase + k] = SIMD4(light, Float(segs.count), Float(inCloud), gentle ? 1 : 0)
            cellU[Self.strikeBoxBase + k] = SIMD4(lo.x, lo.y, hi.x, hi.y)
            cellU[Self.strikeAtBase + k] = SIMD4(Float(branchStart), top.x, top.y, lo.y)
        }

        // The sky's anvil crawlers, drawn on the cloud: each segment up to where the leader has reached.
        for k in 0..<Self.crawlerSlots {
            cellU[Self.crawlInfoBase + k] = .zero
            for i in 0..<Self.segsPerCrawler { cellU[Self.crawlBase + k * Self.segsPerCrawler + i] = .zero }
        }
        for (k, c) in s.crawlers.prefix(Self.crawlerSlots).enumerated() {
            var n = 0
            for seg in c.segments.prefix(Self.segsPerCrawler) {
                let drawn = seg.drawn(at: c.progress)
                guard drawn > 0 else { continue }
                let to = seg.from + (seg.to - seg.from) * drawn
                let a = SkyLayer.enu(SkyDirection(azimuth: Double(seg.from.x), altitude: Double(seg.from.y)))
                let b = SkyLayer.enu(SkyDirection(azimuth: Double(to.x), altitude: Double(to.y)))
                let da = simd_dot(a, cam.forward), db = simd_dot(b, cam.forward)
                guard da > 0.05, db > 0.05 else { continue }
                let pa = SIMD2(simd_dot(a, cam.right) / (da * cam.tanH), simd_dot(a, cam.up) / (da * cam.tanV))
                let pb = SIMD2(simd_dot(b, cam.right) / (db * cam.tanH), simd_dot(b, cam.up) / (db * cam.tanV))
                cellU[Self.crawlBase + k * Self.segsPerCrawler + n] = SIMD4(pa.x, pa.y, pb.x, pb.y)
                n += 1
            }
            let light: Float = Self.unit(c.brightness) * (gentle ? 0.5 : 1)
            cellU[Self.crawlInfoBase + k] = SIMD4(n > 0 ? light : 0, Float(n), 0, 0)
        }

        // The wheat: each row leans with the wind field's sample at its distance.
        grassRows.removeAll(keepingCapacity: true)
        for i in 0..<Self.grassSlots {
            guard i < rows else { cellU[Self.grassBase + i] = .zero; continue }
            let f = Float(i) / Float(max(1, rows - 1))
            let d: Float = Self.nearestRow * exp(f * log(Self.rowSpan))
            let l = Self.lean(frame.wind.sample(SIMD2(0, d)))
            let row = SIMD4<Float>(d, l.x, l.y, l.z)
            grassRows.append(row)
            cellU[Self.grassBase + i] = row
        }

        // Where the storm's parts stand on screen (tests).
        stormCentreNDC = project(SIMD3(centre.x, centre.y, Self.baseHeight + 2), origin: origin, axes: axes, cam: cam) ?? .zero
        wallCentreNDC = project(SIMD3(wall.x, wall.y, Self.baseHeight * 0.6), origin: origin, axes: axes, cam: cam) ?? .zero

        // The flock: pale birds lit by the low sun (dark ones at night), a little V each.
        birdInstances.removeAll(keepingCapacity: true)
        let birdLight: Float = 0.06 + 0.8 * sun.up
        for b in frame.flock.prefix(StormFlock.count(.high)) {
            guard b.position.z > 0.3 else { continue }
            let p = SIMD3<Float>(b.position.x / 1000, b.position.y / 1000, b.position.z / 1000)
            let rel = p - origin
            let dist = simd_length(rel) * 1000
            guard dist > 3, let at = project(p, origin: origin, axes: axes, cam: cam), abs(at.x) < 1.2, abs(at.y) < 1.2 else { continue }
            let half: Float = max(0.6 / dist / tanV, 2.4 / height)
            birdInstances.append(SIMD4(at.x, at.y, half, 0))
            birdInstances.append(SIMD4(b.flap, birdLight, 0, 0))
        }
        birdCount = birdInstances.count / 2

        // The fence posts: timber posts for the white keys, steel star pickets for the black, lit white by their notes.
        postInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995
            let picketTop = keyTop - 0.25 * (keyTop - bottom)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99, x1 = -0.995 + (k.key.x + k.key.width) * 1.99
                let y1 = k.key.isBlack ? picketTop : keyTop
                postInstances.append(SIMD4(x0, bottom, x1, y1))
                postInstances.append(SIMD4(k.key.isBlack ? 1 : 0, Self.unit(k.glow), k.pressed ? 1 : 0, 1))
            }
        }
        // Their light: the low sun and the sky, and the lightning's blue-white flash (through the limiter).
        let flashLight: Float = 0.9 * strikeLight + 0.35 * stormFlash * share
        let sunOnPosts: SIMD3<Float> = sun.colour * 0.55
        let skyOnPosts: SIMD3<Float> = ambient * 0.9 + SIMD3<Float>(repeating: 0.02)
        let flashOnPosts: SIMD3<Float> = Self.strikeColour * flashLight
        let timber: SIMD3<Float> = sunOnPosts + skyOnPosts + flashOnPosts
        postLight = SIMD4(timber, 1)

        post = PostSettings(
            bloom: 0.55, bloomThreshold: 0.9,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.015, vignette: 0.3,
            exposure: limited.exposure * weather.exposureBoost,
            warmth: MoodLook.warmthOffset(mood) + s.warmthGrade + 0.04 * sun.up,
            time: t, quality: quality)
    }

    /// A strike's channel in the storm's frame (km), down to the ground where it comes down (at the storm's distance) in
    /// 16 jagged steps, with two or three branches off its upper half. An ordinary strike leaves the base straight above
    /// its foot; a big one (its channel leaving higher) bursts out of the updraft's side facing us, swung toward its
    /// bearing, and arcs down through the clear air in front of the storm. Each segment is marked inside the cloud or
    /// not (the cloud hides those). Seeded by the strike, so it keeps its shape while it is seen.
    nonisolated static func channel(_ s: GroundStrike) -> [SupercellChannelSegment] {
        var rng = SeededRandom(seed: s.seed)
        let g = s.ground
        let top = max(s.topKm, baseHeight)
        let fromSide = top > baseHeight + 0.5
        var start = SIMD3<Float>(g.x + rng.range(-0.4, 0.4), g.y + rng.range(-0.3, 0.3), top)
        if fromSide {
            let c = stormCentre(km: s.distanceKm)
            let lift: Float = max(top - baseHeight - 2.2, 0)
            let axis = SIMD2<Float>(c.x - 0.32 * lift, c.y + 0.12 * lift)
            let up: Float = min(1, max(0, (top - baseHeight) / (anvilHeight - baseHeight)))
            let radius: Float = baseRadius * (1 - 0.58 * up * up.squareRoot()) + 0.5
            let lean: Float = s.bearing < -7 ? -0.35 : 0.35
            let swing: Float = lean + rng.range(-0.3, 0.3)
            let nearest: Float = 0.45 * g.y   // a storm overhead still throws it out in front of us
            start = SIMD3(axis.x + sin(swing) * radius, max(axis.y - cos(swing) * radius, nearest), top)
        }
        let steps = 16
        var points: [SIMD3<Float>] = []
        var wander = SIMD2<Float>(0, 0)
        for i in 0...steps {
            let f = Float(i) / Float(steps)
            // Out from the cloud and down: across most of the way early on, then near straight down to the foot.
            let across: Float = 1 - (1 - f) * (1 - f)
            let line = SIMD2<Float>(start.x + (g.x - start.x) * across, start.y + (g.y - start.y) * across)
            let z: Float = top * (1 - f)
            let held: Float = i == steps ? 0 : 1
            points.append(SIMD3(line.x + wander.x * held, line.y + wander.y * held, z))
            let jag: Float = 0.045 * top + 0.04
            wander.x += rng.range(-jag, jag)
            wander.y += rng.range(-0.3 * jag, 0.3 * jag)
            wander *= 0.85
        }
        var out: [SupercellChannelSegment] = []
        for i in 0..<steps {
            let a = points[i], b = points[i + 1]
            let mid: Float = (a.z + b.z) / 2
            let hidden = !fromSide && mid > baseHeight
            out.append(SupercellChannelSegment(a: a, b: b, branch: false, cloud: hidden))
        }
        let branches = 2 + Int(s.seed % 2)
        for k in 0..<branches {
            let from = points[3 + (k * 3 + Int(s.seed % 3)) % 6]
            var p = from
            let side: Float = rng.unit() < 0.5 ? -1 : 1
            for _ in 0..<3 {
                let q = SIMD3<Float>(p.x + side * rng.range(0.15, 0.45) * top / 4, p.y + rng.range(-0.1, 0.1),
                                     max(0, p.z - rng.range(0.2, 0.5) * top / 4))
                let mid: Float = (p.z + q.z) / 2
                let hidden = !fromSide && mid > baseHeight
                out.append(SupercellChannelSegment(a: p, b: q, branch: true, cloud: hidden))
                p = q
            }
        }
        return out
    }

    // MARK: - Render

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        cellU[Self.crawlInfoBase].w = Float(skipLayers & 0x3FFF)
        cellU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        cellU[Self.crawlInfoBase].w = 0
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if showWarp { warp.draw(e) }
        if skipLayers & 2048 == 0 { weather.draw(e) }
        if skipLayers & 4096 != 0 { e.endEncoding(); return }
        if !birdInstances.isEmpty {
            e.setRenderPipelineState(birds)
            birdInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            var v = view
            e.setVertexBytes(&v, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: birdCount)
        }
        if !postInstances.isEmpty {
            e.setRenderPipelineState(posts)
            postInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            var still = SIMD4<Float>(view.x, 0, 0, 0)   // the posts stand still while the world shakes
            e.setVertexBytes(&still, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            var light = postLight
            e.setFragmentBytes(&light, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: postInstances.count / 2)
        }
        e.endEncoding()
    }
}
