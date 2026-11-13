import Metal
import CoreGraphics
import simd
import InStrumCore

extension PlainsFrame: SkyBearing {}

/// Draws Lightning Plains (Storms spec §9): the vast dusk sky over a dry grass plain, nine-tenths of the frame. On the
/// western horizon the storm's line of towers, lit from inside by its flashes and the rim's heat lightning, with the
/// glow of the sunset beneath its dark base and its rain shafts hanging from it; above it the sky deepening to the stars
/// and the Milky Way. Strike Lines' forks and crawlers are analytic segments over the sky. On the plain, back to front:
/// grass rows bending on the wind field (48, 24 on Smooth), the fence whose 88 posts are the keys (the repeated note's
/// post brighter with each repeat), the windmill turning at its rate and the tank on the left, a far ridge on the right,
/// a dust devil now and then, and the rain curtain crossing to you at the drop.
///
/// Every strike's light, the crawlers over 0.25 and the drop's sheet-lit sky go through one `FlashLimiter`; Gentle
/// visuals halve them and draw the strikes as soft glows, keep the camera still and cap the windmill's turning. The
/// instance buffers (a ring of three) are made once.
final class LightningPlainsRenderer {
    /// The view: its vertical field (degrees), the horizon's place (NDC y: the sky is 86% of the frame), the eye's height.
    nonisolated static let verticalFOV = 62.0
    nonisolated static let horizonY: Float = -0.72
    nonisolated static let eyeHeight: Float = 0.8
    /// Grass rows (High, Smooth) from 1.4 m to 420 m, geometrically spaced.
    nonisolated static func grassRows(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }
    nonisolated static let grassNear: Float = 1.4, grassFar: Float = 420
    /// The fence: 88 posts on a line from the first (30 m out, near the left edge) to the last (100 m out, right of the
    /// middle), so it runs away across the plain at any aspect; posts 1.45 m tall and 14 cm thick, three strands of wire.
    nonisolated static let postCount = 88
    nonisolated static let fenceNear: Float = 30, fenceFar: Float = 100
    nonisolated static let fenceLeft: Float = -0.93, fenceRight: Float = 0.86
    nonisolated static let postHeight: Float = 1.45, postWidth: Float = 0.14
    nonisolated static let wireLow: Float = 0.42, wireHigh: Float = 1.14
    /// The windmill and the tank: where they stand across the view (NDC x) and how far out (m).
    nonisolated static let windmillAt = SIMD2<Float>(-0.7, 26)
    nonisolated static let tankAt = SIMD2<Float>(-0.93, 30)
    nonisolated static let windmillHub: Float = 9.2, wheelRadius: Float = 1.7
    /// The far ridge: from 36% of the half-view right of the middle out past the right edge, 2.2° tall, 18 km away.
    nonisolated static let ridgeFrom: Float = 0.36, ridgeTo: Float = 1.3
    nonisolated static let ridgeHeight: Float = 2.2, ridgeKm: Float = 18
    /// The storm's base 1.6 km up, its line 20 km either side, 30 km deep.
    nonisolated static let baseKm = 1.6, lineKm = 20.0, depthKm = 30.0
    /// The forks' and crawlers' segments at most, and the props (grass rows, posts, wires, windmill, tank, devil, curtain).
    nonisolated static let segmentBudget = 512
    nonisolated static let propCapacity = 48 + 88 + 87 + 4
    /// Under Reduce Motion (and Gentle visuals) the windmill turns no faster than this (turns a minute).
    nonisolated static let calmRPM: Float = 30
    nonisolated static let channelColour = SIMD3<Float>(0.78, 0.86, 1.0)
    /// How much each tower drops a rain shaft.
    nonisolated static let shaftWeights: [Float] = [0.3, 0.7, 1, 0.6, 0.2]

    /// The uniform block (MSL `PlainsU`): 12 header rows, the five towers (two rows each), eight lights (two rows each),
    /// four rim slots.
    nonisolated static let uniformCount = 42
    nonisolated static let towerARow = 12, towerBRow = 17, lightARow = 22, lightCRow = 30, rimRow = 38
    nonisolated static let lightSlots = 8, rimSlots = 4

    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let storm, bolts, props: MTLRenderPipelineState
    /// The storm drawn at a reduced resolution (`plains_storm_half_fragment`, into `stormTarget`: half the view's size
    /// on Smooth, 0.7 of it on High) and added in at full resolution (`plains_storm_compose_fragment`), where the nearer
    /// ridge cuts it pixel by pixel.
    private let stormHalf, stormCompose: MTLRenderPipelineState
    private let device: MTLDevice
    private var stormTarget: MTLTexture?
    private(set) var stormScale: Float = 1
    nonisolated static func reducedScale(_ q: QualityLevel) -> Float { q == .lite ? 0.5 : 0.7 }
    /// The storm's targets made so far (tests: one a size, never one a frame).
    private(set) var stormAllocations = 0
    /// The storm's screen bounds (NDC x0, y0, x1, y1) for its own pass; nil when it is out of view.
    private(set) var stormBox: SIMD4<Float>?
    /// Passes a timing test skips (0 in the app: everything is drawn), so one run can price each on a slow GPU: 1 the
    /// scene's sky, canopy, ridge and plain, 2 the storm, 4 the forks and crawlers, 8 the grass, the posts and the props,
    /// 16 the weather.
    var skipLayers: UInt32 = 0
    private var plainsU = [SIMD4<Float>](repeating: .zero, count: LightningPlainsRenderer.uniformCount)
    private var segments: [SIMD4<Float>] = []
    private var propInstances: [SIMD4<Float>] = []
    private struct Prop { var depth: Float; var a, b, c, d: SIMD4<Float> }
    private var propList: [Prop] = []
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private(set) var bufferAllocations = 0
    private var limiter = FlashLimiter()
    private var aspect: Float = 16.0 / 9
    private var size = CGSize(width: 1280, height: 720)
    private var cam: SkyLayer.Camera = (right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 0, 1), forward: SIMD3<Float>(0, 1, 0),
                                       tanH: 1, tanV: 1)
    private var ahead = SIMD3<Float>(0, 1, 0), side = SIMD3<Float>(1, 0, 0)
    private var wheelAngle: Float = 0
    private(set) var post = PostSettings()

    /// What was drawn this frame (tests): segments (forks' and crawlers'), props, grass rows.
    private(set) var segmentCount = 0, forkSegmentCount = 0, crawlerSegmentCount = 0, propCount = 0, grassRowCount = 0
    /// The strikes' light and the drop's sheet-lit sky after the flash limiter (gentle visuals halve them).
    private(set) var strikeOut: Float = 0
    private(set) var sheetOut: Float = 0
    /// The camera's shake as drawn (pixels; none under Gentle visuals or Reduce Motion).
    private(set) var shakeOffset = SIMD2<Float>(0, 0)
    /// The windmill's wheel as drawn (turns a minute).
    private(set) var wheelRPM: Float = 0
    /// Where the rain curtain's foot meets the plain (NDC y), while one crosses.
    private(set) var curtainFootY: Float?
    /// The newest fork's channel and branches as drawn (NDC polylines), and its channel's core width (NDC y).
    private(set) var lastFork: [[SIMD2<Float>]] = []
    private(set) var firstCore: Float = 0
    /// Each post's body (NDC x0, y0, x1, y1) and its glow as drawn.
    private(set) var postRects: [SIMD4<Float>] = []
    private(set) var postGlow = [Float](repeating: 0, count: LightningPlainsRenderer.postCount)
    var keyRects: [SIMD4<Float>] { postRects }
    var uniforms: [SIMD4<Float>] { plainsU }
    var horizonY: Float { Self.horizonY }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = ShaderCache.library(device, source: LightningPlainsShaders.source) else { return nil }
        func make(_ v: String, _ f: String, blend: Int, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if blend > 0 {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = blend == 2 ? .one : .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = blend == 2 ? .one : .oneMinusSourceAlpha
            }
            if blend >= 2 { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        // Blend 1: premultiplied over (with depth); 2: additive (no depth); 3: premultiplied over (no depth).
        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = lib.skyFunction("plains_box_vertex")
        hd.fragmentFunction = lib.skyFunction("plains_storm_half_fragment")
        hd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        guard let sc = SkyPipeline(build: { make("plains_vertex", "plains_scene_fragment", blend: 0, storms: $0) }),
              let st = make("plains_box_vertex", "plains_storm_fragment", blend: 3),
              let sco = make("plains_box_vertex", "plains_storm_compose_fragment", blend: 3),
              let sh = try? device.makeRenderPipelineState(descriptor: hd),
              let bo = make("plains_bolt_vertex", "plains_bolt_fragment", blend: 2),
              let pr = make("plains_prop_vertex", "plains_prop_fragment", blend: 1) else { return nil }
        let row = MemoryLayout<SIMD4<Float>>.stride
        let bytes = Self.segmentBudget * 3 * row + Self.propCapacity * 4 * row
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(buf)
        }
        sky = s; weather = w; warp = gw; scene = sc; storm = st; bolts = bo; props = pr
        stormHalf = sh; stormCompose = sco
        self.device = device
        ring = buffers
        bufferAllocations = buffers.count
        segments.reserveCapacity(Self.segmentBudget * 3)
        propInstances.reserveCapacity(Self.propCapacity * 4)
        propList.reserveCapacity(Self.propCapacity)
        postRects.reserveCapacity(Self.postCount)
        sky.verticalFOV = Self.verticalFOV
        sky.horizonY = Self.horizonY
    }

    // MARK: - Geometry

    nonisolated static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    nonisolated static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard x.isFinite, a != b else { return 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    nonisolated static func wrap(_ a: Double) -> Double { a - 360 * ((a + 180) / 360).rounded(.down) }

    /// East-north-up unit vector of an azimuth and altitude (degrees).
    nonisolated static func enu(azimuth: Double, altitude: Double) -> SIMD3<Float> {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        return SIMD3(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }

    /// The far ridge's top (altitude, degrees) at an offset from the bearing: the shader's `pl_ridgeTop`.
    nonisolated static func ridgeTop(_ th: Float, from: Float, to: Float, height: Float) -> Float {
        let u = (th - from) / max(to - from, 1e-3)
        guard u > 0, u < 1 else { return -1 }
        let rise = smooth(0, 0.1, u) * (1 - smooth(0.88, 1, u))
        let mesa = 0.8 + 0.12 * sin(u * 9 + 1.3) + 0.08 * sin(u * 23 + 0.4) - 0.18 * smooth(0.42, 0.47, u)
        return height * rise * mesa
    }

    /// Where a direction (east-north-up) lands on screen (NDC), or nil behind the camera.
    func ndc(_ v: SIMD3<Float>) -> SIMD2<Float>? {
        let f = simd_dot(v, cam.forward)
        guard f > 1e-5 else { return nil }
        return SIMD2(simd_dot(v, cam.right) / f / cam.tanH, simd_dot(v, cam.up) / f / cam.tanV)
    }

    /// Where a point of the plain lands (NDC): `x` metres across the view (right positive), `z` ahead, `h` up.
    func ground(_ x: Float, _ z: Float, _ h: Float) -> SIMD2<Float>? {
        ndc(side * x + ahead * z + SIMD3<Float>(0, 0, h - Self.eyeHeight))
    }

    /// Where the sky's (azimuth, altitude) lands (NDC).
    func skyPoint(azimuth: Double, altitude: Double) -> SIMD2<Float>? { ndc(Self.enu(azimuth: azimuth, altitude: altitude)) }

    /// How far across the plain (m) a point `z` metres out stands to land at screen x `ndcX` near the horizon (the view is
    /// pitched up, so ground points near the horizon sit a little wider than x × tanH × z).
    func across(_ ndcX: Float, at z: Float) -> Float {
        let pitchCos = (1 - min(1, cam.forward.z * cam.forward.z)).squareRoot()
        return ndcX * cam.tanH * z * pitchCos
    }

    /// Post `i`'s place on the plain (x across, z ahead, metres).
    func postPlace(_ i: Int) -> SIMD2<Float> {
        let s = Float(min(max(i, 0), Self.postCount - 1)) / Float(Self.postCount - 1)
        let p0 = SIMD2<Float>(across(Self.fenceLeft, at: Self.fenceNear), Self.fenceNear)
        let p1 = SIMD2<Float>(across(Self.fenceRight, at: Self.fenceFar), Self.fenceFar)
        return p0 + (p1 - p0) * s
    }

    private func appendSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, core: Float, reach: Float, light: Float, colour: SIMD3<Float>) {
        segments.append(SIMD4(a.x, a.y, b.x, b.y))
        segments.append(SIMD4(core, reach, light, 0))
        segments.append(SIMD4(colour, 0))
    }

    /// The storm's screen bounds (NDC x0, y0, x1, y1, a little wide, clamped to the frame) with it `km` away on
    /// `bearing`: every tower with its puffs and anvil, the shelf, and the lobes' reach; the whole frame if any part of
    /// that region is behind the camera, nil if it is all out of view.
    func stormBounds(km: Double, bearing: Double) -> SIMD4<Float>? {
        let deg = 180 / Double.pi
        let lump = max(0.4, 0.28 * atan(4.5 / km) * deg)
        var left = -atan(Self.lineKm / km) * deg, right = -left, top = 0.0
        for t in StrikeLines.towers {
            let v = StrikeLines.view(t, stormKm: km)
            left = min(left, v.offset - 0.45 * v.anvilHalf - 2.6 * v.halfWidth)
            right = max(right, v.offset + v.anvilHalf + 2.6 * v.halfWidth)
            top = max(top, v.top + 1.2 * v.halfWidth)
        }
        top = min(89, top + 2 * lump)
        let widen = 1 / max(0.05, cos(top / deg))
        left = left * widen - 2 * lump
        right = right * widen + 2 * lump
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for i in 0...8 {
            let f = Double(i) / 8
            let edges = [(left + (right - left) * f, -0.6), (left + (right - left) * f, top),
                         (left, -0.6 + (top + 0.6) * f), (right, -0.6 + (top + 0.6) * f)]
            for (th, alt) in edges {
                guard let q = skyPoint(azimuth: bearing + th, altitude: alt) else { return SIMD4(-1, -1, 1, 1) }
                lo = simd_min(lo, q)
                hi = simd_max(hi, q)
            }
        }
        let margin: Float = 0.04
        let box = SIMD4(max(-1, lo.x - margin), max(-1, lo.y - margin), min(1, hi.x + margin), min(1, hi.y + margin))
        return box.x < box.z && box.y < box.w ? box : nil
    }

    // MARK: - Update

    func update(_ frame: PlainsFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        // The storm's own overcast: its rain curtain closes the sky as it comes (the stars go behind the rain).
        var s = frame.sky
        let overcast = Self.unit(frame.rainCurtain) * 0.85
        if overcast > s.cloudCover { s.cloudCover = overcast }
        // The stars alone over the plains: no constellation lines.
        s.constellationLines = 0
        self.size = size
        aspect = Float(max(1, size.width) / max(1, size.height))
        let height = Float(max(1, size.height))
        let pixel = 2 / height
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))

        // The sky, facing the storm (away from the low sun); the weather falling on the plain.
        sky.viewAzimuth = frame.cameraAzimuth
        sky.horizonY = Self.horizonY
        sky.verticalFOV = Self.verticalFOV
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: t)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .ground(horizonY: Self.horizonY))
        cam = sky.camera(latitude: s.latitude, aspect: aspect)
        let az = Float(frame.cameraAzimuth * .pi / 180)
        ahead = SIMD3(sin(az), cos(az), 0)
        side = SIMD3(cos(az), -sin(az), 0)
        showWarp = frame.warp != nil
        if let w = frame.warp {
            warp.centre = SIMD2(0, Self.horizonY + (1 - Self.horizonY) * 0.5)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: FlashLimiter.sparkleScale(gentle: gentle), quality: quality,
                        size: size, dt: dt, time: t)
        }
        let bearing = frame.stormBearing
        let km = frame.distanceKm.isFinite ? min(StrikeLines.farKm, max(StrikeLines.nearestKm, frame.distanceKm)) : StrikeLines.farKm

        // One flash limiter for the storm's light: the strikes (far ones count for less), crawlers over 0.25, the drop's
        // sheet-lit sky. Gentle visuals halve every rise.
        limiter.gentle = gentle
        var raw: Float = Self.unit(frame.sheetLit)
        for f in frame.strikes { raw = max(raw, Self.unit(f.brightness) * Self.proximity(f.km)) }
        for c in frame.crawlers where c.brightness > FlashLimiter.flashRise { raw = max(raw, Self.unit(c.brightness)) }
        let limited = limiter.limit(exposure: raw, sparkle: 1, dt: dt)
        strikeOut = Self.unit(limited.exposure * limited.sparkle)
        let ratio: Float = raw > 1e-4 ? min(1, strikeOut / raw) : (gentle ? 0.5 : 1)
        sheetOut = Self.unit(frame.sheetLit) * ratio
        let soft: Float = gentle ? 0.5 : 1

        buildBolts(frame, sky: s, pixel: pixel, ratio: ratio, gentle: gentle, quality: quality)
        let flashLight = fillUniforms(frame, sky: s, km: km, bearing: bearing, pixel: pixel, ratio: ratio, soft: soft,
                                      quality: quality, time: t, gentle: gentle)
        stormBox = stormBounds(km: km, bearing: bearing)
        stormScale = Self.reducedScale(quality)
        buildProps(frame, params: p, quality: quality, gentle: gentle, dt: dt, pixel: pixel, time: t, flash: flashLight)

        let night = 1 - Self.smooth(-12, -3, Float(s.sun.altitude))
        let mood = frame.mood
        post = PostSettings(
            bloom: 0.8, bloomThreshold: 0.85,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.02, vignette: 0.32,
            exposure: MoodLook.exposure(mood) * (1 + 1.0 * night) * weather.exposureBoost,
            warmth: MoodLook.warmthOffset(mood) + s.warmthGrade + 0.04 * (1 - night),
            time: t, quality: quality)
    }

    /// How much a strike `km` away counts toward the storm's flash: far ones are small on the horizon.
    nonisolated static func proximity(_ km: Double) -> Float {
        guard km.isFinite else { return 0.55 }
        return 0.55 + 0.45 * smooth(30, 1, Float(km))
    }

    /// The forks (newest first, within the budget) and the crawlers (the sky's and the storm's, two on Smooth).
    private func buildBolts(_ frame: PlainsFrame, sky s: SkyState, pixel: Float, ratio: Float, gentle: Bool, quality: QualityLevel) {
        segments.removeAll(keepingCapacity: true)
        forkSegmentCount = 0
        crawlerSegmentCount = 0
        lastFork = []
        firstCore = 0
        let gain: Float = gentle ? 0.45 : 1
        let soften: Float = gentle ? 3 : 1
        for f in frame.strikes.reversed() {
            guard f.km.isFinite, f.km > 0 else { continue }
            let scale = Double(f.baseKm) / f.km
            let close = Self.smooth(25, 1, Float(f.km))
            let core = pixel * (0.9 + 2.4 * close) * soften
            let light = Self.unit(f.brightness) * ratio * gain
            var paths: [[SIMD2<Float>]] = []
            for (bi, branch) in f.branches.enumerated() {
                var line: [SIMD2<Float>] = []
                for pt in branch {
                    let a = f.azimuth + atan(Double(pt.x) * scale) * 180 / .pi
                    let e = atan(Double(pt.y) * scale) * 180 / .pi
                    if let q = skyPoint(azimuth: a, altitude: e) { line.append(q) }
                }
                paths.append(line)
                let main = bi == 0
                let w = core * (main ? 1 : 0.6)
                let reach = w * 5 + pixel * (main ? 4 + 8 * close : 2 + 4 * close)
                guard line.count >= 2 else { continue }
                for j in 0..<(line.count - 1) where segments.count / 3 < Self.segmentBudget {
                    appendSegment(line[j], line[j + 1], core: w, reach: reach, light: light * (main ? 1 : 0.55),
                                  colour: Self.channelColour * (3 + 4 * close))
                    forkSegmentCount += 1
                }
            }
            if lastFork.isEmpty { lastFork = paths; firstCore = core }
        }
        let crawlers = Array((s.crawlers + frame.crawlers).suffix(StrikeLines.crawlerSlots(quality)))
        for c in crawlers {
            let lit = c.brightness > FlashLimiter.flashRise ? c.brightness * ratio : c.brightness
            let light = Self.unit(lit) * gain * 3
            guard light > 1e-4 else { continue }
            for seg in c.segments {
                let drawn = seg.drawn(at: c.progress)
                guard drawn > 0, segments.count / 3 < Self.segmentBudget else { continue }
                let end = seg.from + (seg.to - seg.from) * drawn
                guard let a = skyPoint(azimuth: Double(seg.from.x), altitude: Double(seg.from.y)),
                      let b = skyPoint(azimuth: Double(end.x), altitude: Double(end.y)) else { continue }
                appendSegment(a, b, core: pixel * 0.8 * soften, reach: pixel * 8, light: light, colour: c.colour * 2.5)
                crawlerSegmentCount += 1
            }
        }
        segmentCount = segments.count / 3
    }

    /// The scene's uniforms; returns the strikes' light on the plain (rgb).
    private func fillUniforms(_ frame: PlainsFrame, sky s: SkyState, km: Double, bearing: Double, pixel: Float, ratio: Float,
                              soft: Float, quality: QualityLevel, time t: Float, gentle: Bool) -> SIMD3<Float> {
        let deg = 180 / Double.pi
        let sunAlt = Float(s.sun.altitude)
        let night = 1 - Self.smooth(-12, -3, sunAlt)
        let low = max(0, 1 - abs(sunAlt) / 15)
        let sunOffset = Float(Self.wrap(s.sun.azimuth - bearing))
        let facing = exp(-abs(sunOffset) / 50)
        let band = SIMD3<Float>(0.9, 0.42, 0.14) * (0.55 * low * facing)
        // The low sky ahead (behind the silhouettes): the horizon's colour, greyed by Earth's shadow when it rises
        // opposite the sun at twilight (as the sky draws it), and the sunset's band when the sun is ahead.
        let belt = Self.smooth(-6, -4, sunAlt) * (1 - Self.smooth(0, 1, sunAlt))
        let away = max(0, -cos(sunOffset * .pi / 180))
        let shade = belt * away * away
        let luma = 0.2126 * s.horizon.x + 0.7152 * s.horizon.y + 0.0722 * s.horizon.z
        let grey = SIMD3<Float>(0.8, 0.86, 1.02) * luma
        let shaded: SIMD3<Float> = (s.horizon + (grey - s.horizon) * (0.6 * shade)) * (1 - 0.25 * shade)
        let glow: SIMD3<Float> = shaded * 0.85 + band
        let moonUp = Self.smooth(-2, 10, Float(s.moon.altitude)) * Float(s.moonLit)
        let moonLight = SIMD3<Float>(0.05, 0.06, 0.08) * moonUp
        let skyLight: SIMD3<Float> = s.zenith * 0.55 + s.horizon * 0.35
        let ambient: SIMD3<Float> = skyLight + moonLight
        let towerLight = frame.towerFlash.reduce(Float(0)) { $0 + $1.level }
        let strikes = frame.strikes.reduce(Float(0)) { $0 + Self.unit($1.brightness) * Self.proximity($1.km) }
        let flashStrength = (0.45 * min(1.5, strikes) * ratio + 0.8 * sheetOut + 0.5 * min(0.4, towerLight)) * (gentle ? 0.6 : 1)
        let flashLight = SIMD3<Float>(0.8, 0.85, 1.0) * flashStrength

        // The header.
        shakeOffset = gentle ? .zero : SIMD2(frame.cameraShake.x.isFinite ? frame.cameraShake.x : 0,
                                              frame.cameraShake.y.isFinite ? frame.cameraShake.y : 0)
        let shake = SIMD2<Float>(2 * shakeOffset.x / Float(max(1, size.width)), 2 * shakeOffset.y / Float(max(1, size.height)))
        let scale = Float(max(0.4, 0.28 * atan(4.5 / km) * deg))
        let octaves: Float = quality == .lite ? 2 : 3
        let deckFront = Float(atan(Self.baseKm / km) * deg), deckFar = Float(atan(Self.baseKm / (km + Self.depthKm)) * deg)
        let lineHalf = Float(atan(Self.lineKm / km) * deg)
        let shadowKm: Float = sunAlt < 0 ? 3185.5 * (sunAlt * .pi / 180) * (sunAlt * .pi / 180) : 0
        let sunlit = Self.smooth(-9, -1.5, sunAlt) * (1 - 0.7 * Self.unit(s.cloudCover))
        let windLateral = frame.wind.steady.x
        plainsU[0] = SIMD4(aspect, t, Self.horizonY, octaves)
        plainsU[1] = SIMD4(Self.eyeHeight, 2 * cam.tanV / Float(max(1, size.height)), gentle ? 1 : 0, scale)
        plainsU[2] = SIMD4(shake.x, shake.y, sheetOut * soft, Float(km))
        plainsU[3] = SIMD4(Float(bearing), lineHalf, frame.dry ? 1 : 0, deckFront)
        plainsU[4] = SIMD4(ahead.x, ahead.y, side.x, side.y)
        plainsU[5] = SIMD4(ambient, night)
        plainsU[6] = SIMD4(glow, sunOffset)
        plainsU[7] = SIMD4(sunlit, shadowKm, pixel, sunAlt)
        plainsU[8] = SIMD4(flashLight, 0)
        let hfov = Float(atan(Double(cam.tanH)) * deg)
        let ridgeFrom = Self.ridgeFrom * hfov, ridgeTo = Self.ridgeTo * hfov
        plainsU[9] = SIMD4(ridgeFrom, ridgeTo, Self.ridgeHeight, Self.ridgeKm)
        if let b = frame.ballLightning {
            let th = ridgeFrom + (ridgeTo - ridgeFrom) * Self.unit(b.position)
            let top = max(0, Self.ridgeTop(th, from: ridgeFrom, to: ridgeTo, height: Self.ridgeHeight))
            plainsU[10] = SIMD4(th, top + 0.3, Self.unit(b.brightness) * soft, 0.28)
        } else {
            plainsU[10] = .zero
        }
        plainsU[11] = SIMD4(frame.dry ? 0.35 : 0.5, max(-0.4, min(0.4, windLateral * 0.04)), frame.dry ? 1 : 0, deckFar)

        // The towers.
        for (i, tower) in StrikeLines.towers.prefix(5).enumerated() {
            let v = StrikeLines.view(tower, stormKm: km)
            plainsU[Self.towerARow + i] = SIMD4(Float(v.offset), Float(v.halfWidth), Float(v.top), Float(v.anvilHalf))
            plainsU[Self.towerBRow + i] = SIMD4(Float(v.anvilBase), Float(v.km), Float(i) * 17.3, Self.shaftWeights[i])
        }
        if StrikeLines.towers.count < 5 {
            for i in StrikeLines.towers.count..<5 { plainsU[Self.towerARow + i] = .zero; plainsU[Self.towerBRow + i] = .zero }
        }

        // The light inside the storm: each fork's at its cloud base, the towers' own flashes, the heat lightning in the
        // tower over it. The eight strongest.
        var lights: [(SIMD4<Float>, SIMD3<Float>)] = []
        for f in frame.strikes where f.brightness > 0.02 && f.km > 0 {
            let alt = atan(Double(f.baseKm) / f.km) * deg
            let radius = max(1.2, atan(2.5 / f.km) * deg)
            lights.append((SIMD4(Float(Self.wrap(f.azimuth - bearing)), Float(alt) * 1.05, Float(radius),
                                 Self.unit(f.brightness) * ratio * 0.9 * soft), SIMD3<Float>(0.82, 0.8, 1.0)))
        }
        for fl in frame.towerFlash where fl.level > 0.002 {
            lights.append((SIMD4(Float(Self.wrap(fl.azimuth - bearing)), Float(fl.altitude), Float(max(0.5, fl.radius)),
                                 fl.level * 4.5 * soft), SIMD3<Float>(0.86, 0.8, 1.0)))
        }
        var rims: [SIMD4<Float>] = []
        for sl in s.sheet where sl.brightness > 0.002 {
            let off = Self.wrap(Double(sl.azimuth) - bearing)
            let near = StrikeLines.view(StrikeLines.towers[StrikeLines.nearestTower(offset: off, stormKm: km)], stormKm: km)
            lights.append((SIMD4(Float(off), Float(0.45 * near.top), max(1, sl.width * 0.5), sl.brightness * 3.5 * soft),
                           SIMD3<Float>(1.0, 0.88, 0.72)))
            rims.append(SIMD4(Float(off), max(1, sl.width * 0.5), sl.height, sl.brightness * soft))
        }
        lights.sort { $0.0.w > $1.0.w }
        for i in 0..<Self.lightSlots {
            if i < lights.count {
                plainsU[Self.lightARow + i] = lights[i].0
                plainsU[Self.lightCRow + i] = SIMD4(lights[i].1, 0)
            } else {
                plainsU[Self.lightARow + i] = .zero
                plainsU[Self.lightCRow + i] = .zero
            }
        }
        rims.sort { $0.w > $1.w }
        for i in 0..<Self.rimSlots { plainsU[Self.rimRow + i] = i < rims.count ? rims[i] : .zero }
        return flashLight
    }

    /// The plain's props, sorted back to front.
    private func buildProps(_ frame: PlainsFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double,
                            pixel: Float, time t: Float, flash: SIMD3<Float>) {
        propList.removeAll(keepingCapacity: true)
        postRects.removeAll(keepingCapacity: true)
        let pixelAngle = 2 * cam.tanV / Float(max(1, size.height))

        // Grass rows on the wind field: the wind across each row sampled at four places across the view.
        let rows = Self.grassRows(quality)
        let dial = Float(p.number("grass"))
        let grassH: Float = 0.42 + 0.36 * (dial.isFinite ? min(1, max(0, dial)) : 0.6)
        let sway: Float = (0.05 + 0.06 * Self.unit(frame.grassLean)) * (gentle ? 0.5 : 1)
        grassRowCount = 0
        for k in 0..<rows {
            let f = Float(k) / Float(max(1, rows - 1))
            let z = Self.grassNear * exp(f * log(Self.grassFar / Self.grassNear))
            // (Its top: the tallest blade, 1.1875 of the grass's height, a little over; a pixel's margin below.)
            guard let foot = ground(0, z, 0), let top = ground(0, z, 1.2 * grassH + 0.02) else { continue }
            // The nearer row's solid band (at least 0.45 of the grass's height) hides this row below its top.
            var y0 = max(-1.05, foot.y - 2 * pixel)
            if k > 0 {
                let nearer = Self.grassNear * exp(Float(k - 1) / Float(max(1, rows - 1)) * log(Self.grassFar / Self.grassNear))
                if let band = ground(0, nearer, 0.45 * grassH) { y0 = max(y0, band.y - 2 * pixel) }
            }
            let y1 = min(1.05, top.y + 2 * pixel)
            guard y1 > -1, y0 < 1, y1 > y0 else { continue }
            var lean = SIMD4<Float>(0, 0, 0, 0)
            for j in 0..<4 {
                let x = (-1 + 2 * Float(j) / 3) * cam.tanH * z
                lean[j] = frame.wind.sample(SIMD2(x, z)).x
            }
            let spacing = max(0.02, z * pixelAngle * 6)
            propList.append(Prop(depth: z, a: SIMD4(-1.05, y0, 1.05, y1), b: SIMD4(0, z, grassH, Float(k) * 7.31),
                                 c: lean, d: SIMD4(spacing, 0, sway, z < 4 ? 0.07 : 0.04)))
            grassRowCount += 1
        }

        // The fence: 88 posts, lit by their notes, and the wire between them.
        var levels = [Float](repeating: 0, count: Self.postCount)
        let showKeys = p.number("keys.show") > 0.5
        if showKeys {
            for l in frame.postLit where (0..<Self.postCount).contains(l.index) { levels[l.index] = Self.unit(l.level) * (gentle ? 0.8 : 1) }
        }
        postGlow = levels
        var tops: [SIMD2<Float>] = []
        var lows: [SIMD2<Float>] = []
        var highs: [SIMD2<Float>] = []
        var depths: [Float] = []
        tops.reserveCapacity(Self.postCount)
        for i in 0..<Self.postCount {
            let place = postPlace(i)
            let base = ground(place.x, place.y, 0) ?? SIMD2(0, Self.horizonY)
            let top = ground(place.x, place.y, Self.postHeight) ?? SIMD2(0, Self.horizonY)
            let hw = max(0.45 * pixel, (Self.postWidth / 2) / (place.y * cam.tanV))
            let level = levels[i]
            let reach = max(10 * pixel, 8 * hw) * (0.7 + 0.6 * level)
            let x0 = min(base.x, top.x), x1 = max(base.x, top.x)
            let pad = (hw + (level > 0 ? reach : pixel)) / aspect
            let rect = SIMD4(x0 - pad, base.y - pixel, x1 + pad, top.y + (level > 0 ? reach : pixel))
            propList.append(Prop(depth: place.y, a: rect, b: SIMD4(1, place.y, level, Float(i)),
                                 c: SIMD4(base.x, base.y, top.x, top.y), d: SIMD4(hw, reach, pixel, 0)))
            postRects.append(SIMD4(x0 - hw / aspect, base.y, x1 + hw / aspect, top.y))
            tops.append(top)
            lows.append(ground(place.x, place.y, Self.wireLow) ?? base)
            highs.append(ground(place.x, place.y, Self.wireHigh) ?? top)
            depths.append(place.y)
        }
        for i in 0..<(Self.postCount - 1) {
            let a = lows[i], b = lows[i + 1], ha = highs[i], hb = highs[i + 1]
            let x0 = min(a.x, b.x) - 2 * pixel / aspect, x1 = max(a.x, b.x) + 2 * pixel / aspect
            let y0 = min(min(a.y, b.y), min(ha.y, hb.y)) - 2 * pixel, y1 = max(max(a.y, b.y), max(ha.y, hb.y)) + 2 * pixel
            let lit = 0.5 * max(levels[i], levels[i + 1])
            propList.append(Prop(depth: 0.5 * (depths[i] + depths[i + 1]) + 0.01, a: SIMD4(x0, y0, x1, y1),
                                 b: SIMD4(2, 0.5 * (depths[i] + depths[i + 1]), 0, 0), c: SIMD4(a.x, a.y, b.x, b.y),
                                 d: SIMD4(ha.y, hb.y, pixel, lit)))
        }

        // The windmill, turning at its rate (capped under Gentle visuals and Reduce Motion), blurring as it races.
        let rpm = frame.windmillRPM.isFinite ? max(0, frame.windmillRPM) : 0
        wheelRPM = gentle ? min(rpm, Self.calmRPM) : rpm
        wheelAngle = (wheelAngle + wheelRPM / 60 * 2 * Float.pi * Float(max(0, dt))).truncatingRemainder(dividingBy: 2 * Float.pi)
        let mz = Self.windmillAt.y
        let mx = across(Self.windmillAt.x, at: mz)
        if let base = ground(mx, mz, 0), let hub = ground(mx, mz, Self.windmillHub),
           let rim = ground(mx, mz, Self.windmillHub + Self.wheelRadius) {
            let R = rim.y - hub.y
            let perMetre = 1 / (mz * cam.tanV)
            let vane = 2.9 * perMetre
            let sailsPerFrame = wheelRPM / 60 * 18 / 60
            let blur = Self.smooth(0.25, 0.9, sailsPerFrame)
            let rect = SIMD4(hub.x - (1.3 * R + 2 * pixel) / aspect, base.y - 2 * pixel,
                             hub.x + (max(R, vane) + 2 * pixel) / aspect, hub.y + R + 2 * pixel)
            propList.append(Prop(depth: mz, a: rect, b: SIMD4(3, mz, wheelAngle, blur), c: SIMD4(hub.x, hub.y, R, base.y),
                                 d: SIMD4(1.3 * perMetre, 0.22 * perMetre, pixel, vane)))
        }
        // The tank on its stand.
        let tz = Self.tankAt.y
        let tx = across(Self.tankAt.x, at: tz)
        if let foot = ground(tx, tz, 0), let stand = ground(tx, tz, 2.2), let rimTop = ground(tx, tz, 4.7), let peak = ground(tx, tz, 5.1) {
            let hw = 1.7 / (tz * cam.tanV)
            let rect = SIMD4(foot.x - (hw + 2 * pixel) / aspect, foot.y - 2 * pixel, foot.x + (hw + 2 * pixel) / aspect, peak.y + 2 * pixel)
            propList.append(Prop(depth: tz, a: rect, b: SIMD4(4, tz, 0, 0), c: SIMD4(foot.x, foot.y, hw, stand.y),
                                 d: SIMD4(rimTop.y, peak.y, pixel, 0)))
        }
        // A dust devil crossing.
        if let devil = frame.dustDevil, devil.centre.y > 3, let foot = ground(devil.centre.x, devil.centre.y, 0),
           let top = ground(devil.centre.x, devil.centre.y, 38) {
            let perMetre = 1 / (devil.centre.y * cam.tanV)
            let wide = 8 * perMetre
            let rect = SIMD4(foot.x - (wide + 2 * pixel) / aspect, foot.y - 2 * pixel, foot.x + (wide + 2 * pixel) / aspect, top.y)
            propList.append(Prop(depth: devil.centre.y, a: rect, b: SIMD4(5, devil.centre.y, 0, 0),
                                 c: SIMD4(foot.x, foot.y, top.y, 1.2 * perMetre), d: SIMD4(wide, t, Self.unit(devil.level), 0)))
        }
        // The rain curtain crossing to you: its foot on the plain, the base above it; once it is on you, a lighter veil
        // as the rain falls.
        curtainFootY = nil
        if let ck = frame.curtainKm, frame.rainCurtain > 0 {
            let d = max(2, Float(ck) * 1000)
            let crossing = frame.rainCurtain < 1
            let density: Float = crossing ? (frame.dry ? 0.42 : 0.62) : 0.3 * Self.unit(frame.rain)
            if density > 0.01 {
                let foot = max(-1.05, ground(0, d, 0)?.y ?? -1.05)
                curtainFootY = foot
                let rect = SIMD4<Float>(-1.05, max(-1.05, foot - 2 * pixel), 1.05, 1.05)
                let slant = -frame.wind.steady.x * 0.04
                propList.append(Prop(depth: d, a: rect, b: SIMD4(6, d, frame.dry ? 1 : 0, 0),
                                     c: SIMD4(Float(Self.baseKm * 1000), 0.45, slant, density), d: .zero))
            }
        }

        propList.sort { $0.depth > $1.depth }
        propInstances.removeAll(keepingCapacity: true)
        for prop in propList.prefix(Self.propCapacity) {
            propInstances.append(prop.a); propInstances.append(prop.b); propInstances.append(prop.c); propInstances.append(prop.d)
        }
        propCount = propInstances.count / 4
        _ = flash
    }

    // MARK: - Render

    /// The storm's target for a scene `width` × `height` at `scale` (made when the size changes, kept).
    private func stormTexture(width: Int, height: Int, scale: Float) -> MTLTexture? {
        let w = max(1, Int((Float(width) * scale).rounded(.up))), h = max(1, Int((Float(height) * scale).rounded(.up)))
        if stormTarget?.width != w || stormTarget?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            stormTarget = device.makeTexture(descriptor: d)
            stormAllocations += 1
        }
        return stormTarget
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        let skyU = sky.uniforms
        // The storm first, at a reduced resolution, over its bounds (the rest of its target clear).
        var stormDrawn: MTLTexture?
        if var box = stormBox, skipLayers & 2 == 0, stormScale < 1, let hdr = stack.hdrTarget,
           let target = stormTexture(width: hdr.width, height: hdr.height, scale: stormScale) {
            let hp = MTLRenderPassDescriptor()
            hp.colorAttachments[0].texture = target
            hp.colorAttachments[0].loadAction = .clear
            hp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            hp.colorAttachments[0].storeAction = .store
            if let he = cb.makeRenderCommandEncoder(descriptor: hp) {
                he.setRenderPipelineState(stormHalf)
                he.setVertexBytes(&box, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                skyU.withUnsafeBytes { he.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                plainsU.withUnsafeBytes { he.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                he.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                he.endEncoding()
                stormDrawn = target
            }
        }
        // (The scene's triangle writes every pixel, uncleared; the timing test's skipped scene keeps the clear.)
        guard let pass = skipLayers & 1 == 0 ? stack.scenePassOverwritten() : stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        plainsU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        if skipLayers & 1 == 0 { e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3) }
        if var box = stormBox, skipLayers & 2 == 0 {
            if let drawn = stormDrawn {
                e.setRenderPipelineState(stormCompose)
                e.setFragmentTexture(drawn, index: 0)
            } else {
                e.setRenderPipelineState(storm)
            }
            e.setVertexBytes(&box, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            plainsU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        if showWarp { warp.draw(e) }

        let row = MemoryLayout<SIMD4<Float>>.stride
        let boltBytes = segments.count * row
        let propBytes = propInstances.count * row
        if boltBytes + propBytes > 0, !ring.isEmpty {
            slot = (slot + 1) % ring.count
            let buf = ring[slot]
            if boltBytes > 0 { segments.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: boltBytes) } }
            if propBytes > 0 {
                propInstances.withUnsafeBytes { (buf.contents() + boltBytes).copyMemory(from: $0.baseAddress!, byteCount: propBytes) }
            }
            if segmentCount > 0, skipLayers & 4 == 0 {
                e.setRenderPipelineState(bolts)
                e.setVertexBuffer(buf, offset: 0, index: 0)
                plainsU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segmentCount)
            }
            if propCount > 0, skipLayers & 8 == 0 {
                e.setRenderPipelineState(props)
                e.setVertexBuffer(buf, offset: boltBytes, index: 0)
                plainsU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
                skyU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
                skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                plainsU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: propCount)
            }
        }
        if skipLayers & 16 == 0 { weather.draw(e) }
        e.endEncoding()
    }
}

/// Made on any thread (the warm-up makes the worlds' renderers off the main thread, real-Mac performance 14 Nov), drawn on
/// the main thread: the class itself is not tied to the main actor, only its conformance is.
extension LightningPlainsRenderer: ThemeRenderer {}
