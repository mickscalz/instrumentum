import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Zen Rock Garden (spec §9.1, §9.2): from the veranda of a temple hall, a dry garden of raked white gravel with
/// five stones in three groups on moss islands, kerbed and set in moss; a low earthen wall with a tiled cap across the
/// back, the temple grounds' trees and a tall cedar beyond it; a maple on the left bank that turns with the season; a
/// bamboo water-knocker by a stone basin on the right bank; and keys along the veranda's edge. The
/// gravel is Rake Lines' height field, lit by the sun or the moon so its ridges throw short shadows; a chord's wave
/// brightens along its fronts; Galaxy Warp streams over the sky instead when chosen.
///
/// The garden's frame (metres): x to the right, y ahead from the eye, z up from the gravel. Field cell (cx, cy) lies at
/// x = (cx − 128) × cell, y = bedNear + (144 − cy) × cell: the field's row 0 at the wall's foot, row 144 at the kerb
/// below the veranda.
@MainActor
final class ZenRockGardenRenderer: ThemeRenderer {
    /// One field cell on the ground (m): the bed is 256 × 144 cells, 10.24 m across and 5.76 m deep.
    nonisolated static let cell: Float = 0.04
    /// The eye above the gravel (m): kneeling on a veranda raised a metre above the garden.
    nonisolated static let eyeHeight: Float = 2.2
    /// The bed's near edge (its kerb below the veranda) and the wall's face, ahead of the eye (m).
    nonisolated static let bedNear: Float = 4.3
    nonisolated static let wallDistance: Float = bedNear + Float(RakeField.height) * cell
    /// The earthen wall and its tiled cap (m).
    nonisolated static let wallHeight: Float = 1.05
    nonisolated static let capHeight: Float = 0.26
    /// The granite kerb round the bed (m).
    nonisolated static let kerb: Float = 0.14
    /// How high the rake's ridges stand (m per field unit) at Rake depth 1: the morning's lines rise about a centimetre
    /// and a half at the default depth.
    nonisolated static let reliefScale: Float = 0.045
    /// How tall the tallest stone (height 1) stands (m).
    nonisolated static let stoneScale: Float = 0.95
    /// The maple's trunk (x, the plane it stands in) on the left bank, the knocker's pivot (x, plane) on the right bank,
    /// and the cedar (x, plane, its tip's height) beyond the wall (m).
    nonisolated static let maple = SIMD2<Float>(-5.75, wallDistance - 0.75)
    nonisolated static let knocker = SIMD2<Float>(6.0, wallDistance - 1.45)
    nonisolated static let cedar = SIMD3<Float>(3.6, wallDistance + 18, 10.8)
    /// The wall's foot lands this share of the way from the keys to the top, whatever the window's shape.
    nonisolated static let wallFootShare: Float = 0.32

    /// The uniform block (MSL `GardenU`): 19 header rows, the five stones, their frames (four rows each), their facets
    /// (two each), and the held notes' rakes.
    nonisolated static let headerCount = 19
    nonisolated static let stoneBase = 19
    nonisolated static let frameBase = 24
    nonisolated static let cutBase = 44
    nonisolated static let rakeBase = 54
    nonisolated static let rakeCap = 12
    nonisolated static let uniformCount = 66
    /// Held notes' rakes drawn (fewer on Smooth).
    static func rakeBudget(_ q: QualityLevel) -> Int { q == .lite ? 6 : rakeCap }

    typealias Camera = (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, tanH: Float, tanV: Float)

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let keys: MTLRenderPipelineState
    /// The rake field: a ring of three r32Float textures (so a frame still in flight keeps reading its own), one written
    /// only when the field's version moves on, at most once a frame.
    private let fieldTextures: [MTLTexture]
    private var fieldSlot = 0
    private var uploadedVersion: Int?
    private var gardenU = [SIMD4<Float>](repeating: .zero, count: 66)
    private var keyInstances: [KeyInstance] = []
    private var aspect: Float = 16.0 / 9
    private var limiter = FlashLimiter()
    private var waveLimiter = FlashLimiter()
    private var camera: Camera?
    private(set) var post = PostSettings()
    /// Field uploads so far (tests: one per change of version, never more than one a frame).
    private(set) var fieldUploads = 0
    /// The version of the field the shader is reading.
    var fieldVersion: Int? { uploadedVersion }
    /// The chord wave's brightening after the flash limiter (gentle visuals halve it).
    private(set) var waveOut: Float = 0
    /// Held notes' rakes drawn this frame.
    private(set) var rakeCount = 0
    /// The horizon, the wall's foot and the top of its cap, in NDC y.
    private(set) var horizonY: Float = 0.35
    private(set) var wallFootY: Float = -0.1
    private(set) var wallTopY: Float = 0.2
    /// Where the stones' feet and tops, the knocker's pivot and the maple's crown sit on screen (NDC).
    private(set) var stoneScreen: [SIMD2<Float>] = []
    private(set) var stoneTopScreen: [SIMD2<Float>] = []
    private(set) var knockerScreen = SIMD2<Float>(0, 0)
    private(set) var mapleScreen = SIMD2<Float>(0, 0)
    /// The shader's uniforms (tests read them).
    var uniforms: [SIMD4<Float>] { gardenU }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: ZenRockGardenShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let sc = SkyPipeline(build: { make("garden_vertex", "garden_fragment", storms: $0) }), let k = make("garden_keys_vertex", "garden_keys_fragment") else { return nil }
        // The field's textures, made once and filled with the morning's pattern (so no frame ever reads an empty one).
        let fw = RakeField.width, fh = RakeField.height
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: fw, height: fh, mipmapped: false)
        td.usage = [.shaderRead]
        var textures: [MTLTexture] = []
        for _ in 0..<3 {
            guard let tex = device.makeTexture(descriptor: td) else { return nil }
            RakeLines.morning.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: fw * 4)
            }
            textures.append(tex)
        }
        sky = s; weather = w; warp = gw; scene = sc; keys = k; fieldTextures = textures
        for (i, row) in Self.stoneRows.enumerated() { gardenU[Self.stoneBase + i] = row }
        for (i, row) in Self.frameRows.enumerated() { gardenU[Self.frameBase + i] = row }
        for (i, row) in Self.cutRows.enumerated() { gardenU[Self.cutBase + i] = row }
    }

    nonisolated private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }
    nonisolated private static func unit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

    // MARK: - The garden's layout

    /// The garden faces the equator, as a hall's garden does (south in the north, north in the south): the sun and the
    /// moon cross the sky over the wall, the morning and evening light rakes in from the sides with the stones' long
    /// shadows across the bed, and noon stands high and bright in front.
    nonisolated static func viewAzimuth(latitude: Double) -> Double { SkyLayer.defaultViewAzimuth(latitude: latitude) }

    /// The lens for a window shape: 0.82 of the tangent across at 16:9, a little narrower on square windows and wider
    /// on wide ones, so the bed spans the view at the stones; the vertical field follows (degrees).
    nonisolated static func lens(aspect a: Float) -> (tanH: Float, tanV: Float, verticalFOV: Double) {
        let aspect = a.isFinite ? min(max(a, 0.4), 4) : 16.0 / 9
        let tanH = 0.82 * pow(aspect / (16.0 / 9), 0.25)
        let tanV = tanH / aspect
        return (tanH, tanV, Double(2 * atan(tanV)) * 180 / .pi)
    }

    /// The horizon (NDC y) that puts the wall's foot `wallFootShare` of the way from the keys to the top.
    nonisolated static func horizon(keyTop: Float, tanV: Float) -> Float {
        let foot = keyTop + (1 - keyTop) * wallFootShare
        let depression = atan(eyeHeight / wallDistance)
        return tan(atan(foot * tanV) + depression) / tanV
    }

    /// A field cell (x right 0…256, y 0 at the wall … 144 at the kerb) on the ground, in the garden's frame (m).
    nonisolated static func gardenPoint(cellX x: Float, cellY y: Float, height z: Float = 0) -> SIMD3<Float> {
        SIMD3((x - Float(RakeField.width) / 2) * cell, bedNear + (Float(RakeField.height) - y) * cell, z)
    }

    /// The NDC point of a place in the garden (its frame, m), from the last frame's camera; nil behind the eye.
    func screenPoint(_ p: SIMD3<Float>) -> SIMD2<Float>? {
        guard let cam = camera else { return nil }
        let fwd = simd_normalize(SIMD2(cam.forward.x, cam.forward.y)), rgt = SIMD2(fwd.y, -fwd.x)
        let h = rgt * p.x + fwd * p.y
        let v = SIMD3(h.x, h.y, p.z - Self.eyeHeight)
        let z = simd_dot(v, cam.forward)
        guard z > 1e-4 else { return nil }
        return SIMD2(simd_dot(v, cam.right) / (z * cam.tanH), simd_dot(v, cam.up) / (z * cam.tanV))
    }

    /// Where a field cell lies on screen (NDC).
    func screenPoint(cellX x: Float, cellY y: Float) -> SIMD2<Float>? { screenPoint(Self.gardenPoint(cellX: x, cellY: y)) }

    /// An NDC rectangle (x0, y0, x1, y1) over open gravel on the near flank of the tall stone's first note ring (tests
    /// read the rake there).
    func gravelPatch() -> SIMD4<Float>? {
        let s = RakeLines.stones[2]
        let r = RakeLines.firstRingRadius(2)
        guard let a = screenPoint(cellX: s.centre.x + r - 6, cellY: s.centre.y + 0.55 * r),
              let b = screenPoint(cellX: s.centre.x + r + 6, cellY: s.centre.y + 0.15 * r) else { return nil }
        return SIMD4(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
    }

    // MARK: - The stones

    /// Each stone's shape: yaw (rad), its long and short axes (× the footprint radius), its lean (rad, toward the long
    /// axis), and two facets cut from it (normal in the stone's own frame: long, short, up; offset × the stone's height).
    /// The tall stone of the middle island stands with two sheared faces meeting in a ridge; its neighbours lean, sit
    /// low and flat-topped, bevelled where weather has split them.
    nonisolated static let stoneShapes: [(yaw: Float, long: Float, short: Float, lean: Float, cut: SIMD4<Float>, cut2: SIMD4<Float>)] = [
        (0.45, 1.2, 0.85, 0.14, SIMD4(0.36, 0.1, 0.93, 0.8), SIMD4(-0.7, -0.45, 0.55, 0.42)),
        (-0.35, 1.32, 0.82, -0.06, SIMD4(0.05, 0.0, 1.0, 0.74), SIMD4(0.8, -0.35, 0.35, 0.62)),
        (0.2, 1.05, 0.78, -0.07, SIMD4(-0.62, 0.22, 0.75, 0.62), SIMD4(0.55, -0.55, 0.62, 0.6)),
        (0.95, 1.22, 0.92, 0.02, SIMD4(0.08, -0.04, 1.0, 0.66), SIMD4(-0.75, -0.35, 0.45, 0.45)),
        (-0.6, 1.16, 0.8, 0.16, SIMD4(0.32, -0.38, 0.87, 0.74), SIMD4(-0.5, 0.55, 0.6, 0.55)),
    ]
    /// The ellipsoid's centre lies this share of its height below the moss (the stone is sunk into it).
    nonisolated static let stoneSink: Float = 0.3

    /// A stone's frame in the garden: its long, short and up axes (leaned), the ellipsoid's semi-axes and centre, and its
    /// facets as planes in the garden (outward normal, offset: dot(n, p) ≤ offset is stone).
    nonisolated static func stoneFrame(_ i: Int) -> (e1: SIMD3<Float>, e2: SIMD3<Float>, e3: SIMD3<Float>, axes: SIMD3<Float>,
                                                    centre: SIMD3<Float>, cuts: [SIMD4<Float>]) {
        let st = RakeLines.stones[i], shape = stoneShapes[i]
        let r = st.radius * cell, h = st.height * stoneScale
        let a1 = SIMD3<Float>(cos(shape.yaw), sin(shape.yaw), 0), a2 = SIMD3<Float>(-sin(shape.yaw), cos(shape.yaw), 0)
        let up = SIMD3<Float>(0, 0, 1)
        let e1 = a1 * cos(shape.lean) - up * sin(shape.lean)
        let e3 = up * cos(shape.lean) + a1 * sin(shape.lean)
        let foot = 1 / (1 - stoneSink * stoneSink).squareRoot()
        let axes = SIMD3<Float>(r * shape.long * foot, r * shape.short * foot, h / (1 - stoneSink))
        let base = gardenPoint(cellX: st.centre.x, cellY: st.centre.y)
        let centre = base - e3 * (stoneSink * axes.z)
        let cuts = [shape.cut, shape.cut2].map { c -> SIMD4<Float> in
            let n = simd_normalize(SIMD3<Float>(c.x, c.y, c.z))
            let nw = e1 * n.x + a2 * n.y + e3 * n.z
            return SIMD4(nw, simd_dot(nw, base) + c.w * h)
        }
        return (e1, a2, e3, axes, centre, cuts)
    }

    /// The stones' rows: centre (cells), footprint radius (cells), height (m).
    nonisolated static let stoneRows: [SIMD4<Float>] = RakeLines.stones.prefix(5).map {
        SIMD4($0.centre.x, $0.centre.y, $0.radius, $0.height * stoneScale)
    }
    /// Their frames: (long axis, its semi-axis), (short axis, …), (up axis, …), (centre, 0) per stone.
    nonisolated static let frameRows: [SIMD4<Float>] = (0..<5).flatMap { i -> [SIMD4<Float>] in
        let f = stoneFrame(i)
        return [SIMD4(f.e1, f.axes.x), SIMD4(f.e2, f.axes.y), SIMD4(f.e3, f.axes.z), SIMD4(f.centre, 0)]
    }
    nonisolated static let cutRows: [SIMD4<Float>] = (0..<5).flatMap { stoneFrame($0).cuts }

    // MARK: - The knocker

    /// The knocker's tube angle (rad; + the mouth raised under the spout): at rest 24° up, sagging a little as it fills,
    /// 22° down while it pours, with a small rebound after the clack.
    nonisolated static func knockerAngle(_ k: KnockerState) -> Float {
        let rest: Float = 0.42, tipped: Float = -0.38
        let fill = unit(k.fill), tip = unit(k.tip), clack = unit(k.clack)
        let bounce = 0.04 * clack * clack * abs(sin((1 - clack) * 12))
        return rest + (tipped - rest) * tip - 0.07 * fill * fill + bounce
    }

    // MARK: - Update

    func update(_ frame: ZenGardenFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        aspect = Float(max(1, size.width) / max(1, size.height))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let lens = Self.lens(aspect: aspect)
        horizonY = Self.horizon(keyTop: keyTop, tanV: lens.tanV)
        sky.verticalFOV = lens.verticalFOV
        sky.horizonY = horizonY
        sky.viewAzimuth = Self.viewAzimuth(latitude: s.latitude)
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        camera = cam
        wallFootY = screenPoint(SIMD3(0, Self.wallDistance, 0))?.y ?? keyTop
        wallTopY = screenPoint(SIMD3(0, Self.wallDistance, Self.wallHeight + Self.capHeight))?.y ?? horizonY

        // Weather lands on the gravel; a humid night's fireflies come over the moss (the frame's, more with more moss).
        var weatherSky = s
        weatherSky.fireflies = Self.unit(frame.fireflies)
        weather.gentle = gentle
        weather.update(weatherSky, quality: quality, size: size, dt: dt, surface: .ground(horizonY: wallFootY))
        showWarp = frame.warp != nil
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, wallTopY + (1 - wallTopY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        // Light: the stronger of the sun and the moon throws the shadows (fading out as the two cross at twilight); the
        // other only fills. The sky's own light comes down on everything.
        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let day = Float(Self.smooth(-4, 8, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, 0.12 * MoodLook.hazeScale(mood) + Self.unit(s.mist))
        limiter.gentle = gentle
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let limited = limiter.limit(exposure: exposure, sparkle: 1, dt: dt)
        let fwd = simd_normalize(SIMD2(cam.forward.x, cam.forward.y)), rgt = SIMD2(fwd.y, -fwd.x)
        func local(_ v: SIMD4<Float>) -> SIMD3<Float> {
            SIMD3(v.x * rgt.x + v.y * rgt.y, v.x * fwd.x + v.y * fwd.y, v.z)
        }
        let sunLight = lights.sunColor * (1.9 * lights.sun.w)
        let moonLight = lights.moonColor * (0.3 * lights.moon.w)
        let sunKey = lights.sun.w >= lights.moon.w
        let keyDir = local(sunKey ? lights.sun : lights.moon), fillDir = local(sunKey ? lights.moon : lights.sun)
        let strong = max(lights.sun.w, lights.moon.w), weak = min(lights.sun.w, lights.moon.w)
        let shadowStrength = Self.unit((strong - weak) / 0.15)
        let skyLight: SIMD3<Float> = s.zenith * 0.55 + s.horizon * 0.45
        let ambient: SIMD3<Float> = skyLight * 0.62 + SIMD3<Float>(0.0009, 0.0012, 0.002)

        // Rake depth and moss from the parameters; rain darkens and dulls the gravel, snow fills its grooves.
        let ridge = Self.unit(Float(p.number("ridge")))
        let moss = Self.unit(Float(p.number("moss")))
        let relief = Self.reliefScale * (0.15 + 0.85 * ridge)
        let mossReach = 1.2 + 5.3 * moss
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let wind = Self.unit(s.wind)

        gardenU[0] = SIMD4(keyTop, aspect, Self.eyeHeight, night)
        gardenU[1] = SIMD4(day, relief, mossReach, Self.unit(frame.wetness))
        gardenU[2] = SIMD4(Self.unit(frame.snowCover), haze, wind, quality == .lite ? 2 : 3)
        gardenU[3] = SIMD4(Self.cell, Self.bedNear, Self.wallDistance, Self.kerb)
        gardenU[4] = SIMD4(Self.wallHeight, Self.capHeight, quality == .lite ? 2 : 3, quality == .lite ? 0 : 1)
        gardenU[5] = SIMD4(keyDir, shadowStrength)
        gardenU[6] = SIMD4(sunKey ? sunLight : moonLight, sunKey ? 1 : 0)
        gardenU[7] = SIMD4(fillDir, 0)
        gardenU[8] = SIMD4(sunKey ? moonLight : sunLight, 0)
        gardenU[9] = SIMD4(ambient, Self.unit(s.cloudCover))
        gardenU[10] = SIMD4(frame.maple, Self.unit(frame.mapleLeaves))
        gardenU[11] = SIMD4(Self.maple.x, Self.maple.y, (0.02 + 0.08 * wind) * sin(time * 0.9), 0)
        gardenU[12] = SIMD4(Self.knockerAngle(frame.knocker), Self.unit(frame.knocker.fill),
                            Self.smoothF(0.3, 0.7, frame.knocker.tip) * Self.smoothF(0, 0.25, frame.knocker.fill),
                            Self.unit(frame.knocker.clack))
        gardenU[13] = SIMD4(Self.knocker.x, Self.knocker.y, 0, 0)
        gardenU[14] = SIMD4(Self.cedar, (0.04 + 0.16 * wind) * sin(time * 0.37 + 1.1))

        // A chord's wave: a soft light along its two fronts, through its own flash limiter (gentle visuals halve it).
        waveLimiter.gentle = gentle
        let wave = frame.wave
        let waveLimited = waveLimiter.limit(exposure: Self.unit(wave?.brightness ?? 0), sparkle: 1, dt: dt)
        waveOut = waveLimited.exposure * waveLimited.sparkle
        if let w = wave {
            gardenU[15] = SIMD4(w.left, w.right, max(w.width, 0.004), waveOut)
            let warm = Self.unit(w.warm)
            let cool = SIMD3<Float>(0.72, 0.84, 1.0), gold = SIMD3<Float>(1.0, 0.8, 0.5)
            gardenU[16] = SIMD4(cool + (gold - cool) * warm, 0)
        } else {
            gardenU[15] = SIMD4(-1, -1, 0.02, 0)
            gardenU[16] = .zero
        }
        gardenU[17] = SIMD4(fwd.x, fwd.y, time, limited.sparkle)

        // Held notes: the rake going round each one's ring (fresh gravel turning over where it is).
        for i in 0..<Self.rakeCap { gardenU[Self.rakeBase + i] = .zero }
        let held = frame.rings.filter(\.held).suffix(Self.rakeBudget(quality))
        rakeCount = held.count
        for (i, r) in held.enumerated() {
            let c = RakeLines.stones[min(max(r.stone, 0), RakeLines.stones.count - 1)].centre
            let at = c + SIMD2(cos(r.rakeAngle), sin(r.rakeAngle)) * r.radius
            gardenU[Self.rakeBase + i] = SIMD4(at.x, at.y, r.radius, Self.unit(r.depth) * limited.sparkle)
        }
        gardenU[18] = SIMD4(Float(rakeCount), RakeLines.islandBlend, 0, 0)

        // The field: re-upload only when its version has moved on (at most once a frame).
        if frame.field.version != uploadedVersion, frame.field.heights.count == RakeField.width * RakeField.height {
            fieldSlot = (fieldSlot + 1) % fieldTextures.count
            let w = RakeField.width, h = RakeField.height
            frame.field.heights.withUnsafeBytes { raw in
                fieldTextures[fieldSlot].replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                                 withBytes: raw.baseAddress!, bytesPerRow: w * 4)
            }
            uploadedVersion = frame.field.version
            fieldUploads += 1
        }

        // Test reads: the stones, the knocker, the maple's crown on screen.
        stoneScreen = Self.stoneRows.map { screenPoint(Self.gardenPoint(cellX: $0.x, cellY: $0.y)) ?? SIMD2(9, 9) }
        stoneTopScreen = Self.stoneRows.map { screenPoint(Self.gardenPoint(cellX: $0.x, cellY: $0.y, height: $0.w)) ?? SIMD2(9, 9) }
        knockerScreen = screenPoint(SIMD3(Self.knocker.x, Self.knocker.y, 0.42)) ?? SIMD2(9, 9)
        mapleScreen = screenPoint(SIMD3(Self.maple.x + 1.4, Self.maple.y, 2.4)) ?? SIMD2(9, 9)

        // Keys: pale cypress along the veranda's edge, glowing pale gold where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let light = min(1, 0.25 + 0.75 * max(lights.sun.w, 0.4 * lights.moon.w))
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.4, bloomThreshold: 1.25,
            dof: quality == .lite ? 0 : 0.06, focusDepth: 0.18,
            grade: 0, grain: 0.02, vignette: 0.32,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.05 * day - 0.06 * night,
            time: time, quality: quality)
    }

    nonisolated private static func smoothF(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard x.isFinite else { return 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        // The garden (the sky shows where it discards): the stars at texture 0, the rake field at texture 1.
        let skyU = sky.uniforms
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        gardenU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        e.setFragmentTexture(fieldTextures[fieldSlot], index: 1)
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
