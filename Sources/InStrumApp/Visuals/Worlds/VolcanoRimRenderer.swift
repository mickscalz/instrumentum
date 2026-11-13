import Metal
import CoreGraphics
import simd
import InStrumCore

extension VolcanoFrame: SkyBearing {}

/// Draws Volcano Rim (Fire & Neon spec §8, §12): the crater at night from its near rim. One full-screen pass draws the
/// sky, the crater, the lava lake, its fountains, the eruption's column, the plume and the fume over the lake
/// (`VolcanoRimShaders`); the embers, blobs, bombs and sparks (one instanced pass, each a blackbody streak), the plume's
/// lightning (instanced segments), the weather and the basalt columns (the keys) go over it. Magma Veins, when chosen,
/// draws instead (`MagmaVeinsRenderer`).
///
/// The renderer turns the model's state into the shader's rows: the 64 crust seeds with their light, the fountains, the
/// column, the river and the breach, the plume's bend and billow, the surprises. Every flash (the plume's lightning, the
/// eruption's light, a fireball) goes through one `FlashLimiter`; under gentle visuals the scene never brightens past a
/// glow and the strokes are glows inside the plume, not channels. The camera shakes only as the model says (never under
/// Reduce Motion, never on Smooth). The instance buffers (a ring of three) are made once.
@MainActor
final class VolcanoRimRenderer: ThemeRenderer {
    // MARK: The shader's rows (MSL `VolcanoU`)
    nonisolated static let rowA = 0, rowCam = 1, rowAxes = 2, rowEye = 3, rowLake = 4, rowGlow = 5, rowPlay = 6, rowTemps = 7
    nonisolated static let rowPlume = 8, rowRiver = 9, rowSkyL = 10, rowFountA = 11, rowFountB = 12, rowErupt = 13, rowBolt = 14
    nonisolated static let rowFireball = 15, rowRockfall = 16, rowSteam = 17, rowSprites = 18, rowTree = 19
    nonisolated static let rowDims = 20, rowDims2 = 21, rowDims3 = 22, rowRiverA = 23
    nonisolated static let cellABase = 24, cellBBase = 88
    nonisolated static let uniformCount = 152

    // MARK: The view
    nonisolated static let verticalFOV = 46.0
    /// The horizon (the far rim's skyline) a little above the middle: the lake fills the lower half.
    nonisolated static let horizonY: Float = 0.42
    /// The sparks (each blob and bomb in flight a trail of `trailSegments`), the bolts' segments.
    nonisolated static let trailSegments = 4
    nonisolated static let sparkCapacity = VolcanoRimModel.emberCount
        + (VolcanoRimModel.blobCount + VolcanoRimModel.bombCount) * VolcanoRimRenderer.trailSegments
    nonisolated static let boltCapacity = VolcanoRimModel.strokeCount * 16
    /// The plume's lightning: violet-white.
    nonisolated static let boltColour = SIMD3<Float>(0.82, 0.78, 1.0)

    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    let veinsRenderer: MagmaVeinsRenderer
    private var showWarp = false
    private(set) var showingVeins = false
    /// Layers a timing test skips (0 in the app: everything is drawn), so one run can price each on a slow GPU. The scene's
    /// bits: 1 the lake, 512 the lake's plates, 1024 its fine cracks, 2 the floor and the river, 4 the walls, 8 the sky, 16
    /// the fountains, 32 the eruption's column (and a steam blast, a lava tree), 64 the plume, 128 the fume, 256 the near
    /// rocks; the renderer's: 2048 the embers and the bolts, 4096 the weather, 8192 the basalt columns (the keys).
    var skipLayers: UInt32 = 0
    private let scene: SkyPipeline
    private let sparks, bolts, columns: MTLRenderPipelineState
    /// The lake's plates' map (`volcano_plate_map`): for each texel of the warped lake plane the 12 crust seeds of least
    /// power there, which the lake reads instead of all 64. Made once; a sixteenth of its rows refreshed a frame (every
    /// 16th row), the whole map when it is new or the clock jumped (previews, a world come back to). Without its kernel
    /// (if it couldn't be made) the lake reads all 64 seeds, as before.
    nonisolated static let plateMapSize = 512
    nonisolated static let plateMapStrips = 16
    private let plateKernel: MTLComputePipelineState?
    private let plateMap: MTLTexture
    private var plateMapWhole = false
    private var plateMapClock: Float = .nan
    private var plateMapStrip = 0
    /// Tests: whole refreshes of the map and single strips drawn.
    private(set) var plateMapWholeDraws = 0
    private(set) var plateMapStripDraws = 0
    private var volU = [SIMD4<Float>](repeating: .zero, count: VolcanoRimRenderer.uniformCount)
    private var sparkInstances: [SIMD4<Float>] = []
    private var boltInstances: [SIMD4<Float>] = []
    private var columnInstances: [SIMD4<Float>] = []
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private(set) var bufferAllocations = 0
    private var view = SIMD4<Float>(16.0 / 9, 0, 0, 0)
    private var columnLight = SIMD4<Float>(1, 1, 1, 1)
    private var limiter = FlashLimiter()
    private var primed = false
    private var rise: Float = 0
    private var eruptGlow: Float = 0
    private(set) var post = PostSettings()

    /// What was drawn (tests read them): the sparks and bolt segments, the scene's light after the limiter, the shake
    /// applied (NDC), the lake's light on the crater, where the lake's middle and the plume stand on screen.
    private(set) var sparkCount = 0
    private(set) var boltCount = 0
    private(set) var exposureOut: Float = 1
    private(set) var flashShare: Float = 1
    private(set) var lightningLight: Float = 0
    private(set) var channelsDrawn = false
    private(set) var shakeApplied = SIMD2<Float>(0, 0)
    private(set) var lakeGlow = SIMD3<Float>(0, 0, 0)
    private(set) var lakeCentreNDC = SIMD2<Float>(0, 0)
    private(set) var rimNDC = SIMD2<Float>(0, 0)
    private(set) var keyTop: Float = -0.78
    var flashesInLastSecond: Int { showingVeins ? veinsRenderer.flashesInLastSecond : limiter.recent }
    var flashTotal: Int { limiter.total + veinsRenderer.flashTotal }
    var keyRects: [SIMD4<Float>] { stride(from: 0, to: columnInstances.count, by: 2).map { columnInstances[$0] } }
    /// The shader's rows (tests read them).
    var uniforms: [SIMD4<Float>] { volU }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let mv = MagmaVeinsRenderer(device: device),
              let lib = try? device.makeLibrary(source: VolcanoRimShaders.source, options: nil) else { return nil }
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
            if blend == 2 { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        // Blend 1: premultiplied over (with depth); 2: additive (no depth).
        guard let sc = SkyPipeline(build: { make("volcano_vertex", "volcano_scene_fragment", blend: 0, storms: $0) }),
              let sp = make("volcano_spark_vertex", "volcano_spark_fragment", blend: 2),
              let bo = make("volcano_bolt_vertex", "volcano_bolt_fragment", blend: 2),
              let co = make("volcano_column_vertex", "volcano_column_fragment", blend: 1) else { return nil }
        let row = MemoryLayout<SIMD4<Float>>.stride
        let bytes = (Self.sparkCapacity * 2 + Self.boltCapacity * 2) * row
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(buf)
        }
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: Self.plateMapSize,
                                                          height: Self.plateMapSize, mipmapped: false)
        md.usage = [.shaderRead, .shaderWrite]
        md.storageMode = .private
        guard let plates = device.makeTexture(descriptor: md) else { return nil }
        sky = s; weather = w; warp = gw; veinsRenderer = mv
        scene = sc; sparks = sp; bolts = bo; columns = co
        plateMap = plates
        if let f = lib.skyFunction("volcano_plate_map") {
            plateKernel = try? device.makeComputePipelineState(function: f)
        } else {
            plateKernel = nil
        }
        ring = buffers
        bufferAllocations = buffers.count
        sparkInstances.reserveCapacity(Self.sparkCapacity * 2)
        boltInstances.reserveCapacity(Self.boltCapacity * 2)
        columnInstances.reserveCapacity(88 * 2)
        sky.verticalFOV = Self.verticalFOV
        sky.horizonY = Self.horizonY
    }

    // MARK: - Helpers

    nonisolated static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
    nonisolated static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard x.isFinite, a != b else { return 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Incandescence at a temperature (kelvin), as the shader's `blackbody`: the CIE locus's chroma under D65 and a film's
    /// compressed intensity (1 at 1150 K, e-fold every 115 K).
    nonisolated static func blackbody(_ kelvin: Float) -> SIMD3<Float> {
        let t = min(2200, max(450, kelvin.isFinite ? kelvin : 450))
        let g = exp(0.38 - 1848 / t)
        let b = exp(2.036 - 8727 / t)
        return SIMD3(1, g, b) * exp((t - 1150) / 115)
    }

    /// The lake's light on the crater (rgb, HDR): its crust and cracks together as one glowing disc, brighter with Energy,
    /// the lake's activity, the fountains, the column and the breach.
    /// A crust seed's weight in the lake's power diagram (m²): fixed by its index (so the plates run from small to big),
    /// and a plate just split off takes its parent's at first, so nothing jumps as it is born.
    nonisolated static func plateWeight(_ k: Int, twin: Int, birth: Float) -> Float {
        func size(_ i: Int) -> Float { (Float(i) * 0.618034).truncatingRemainder(dividingBy: 1) }
        let own = size(k)
        let parent = twin >= 0 ? size(twin) : own
        let h = parent + (own - parent) * unit(birth)
        return 900 * (1.8 * h * h * h - 0.3)
    }

    nonisolated static func lakeLight(energy: Float, activity: Float, fountains: Float, eruption: Float, breach: Float) -> SIMD3<Float> {
        let e = unit(energy), a = unit(activity)
        let level: Float = 0.38 + 0.3 * e + 0.15 * a + 0.12 * unit(fountains) + 0.25 * unit(eruption) + 0.5 * unit(breach)
        let warm = blackbody(1150)
        return warm * level
    }

    /// The camera's basis and where a crater point (metres) lands on screen (NDC), with its distance, or nil behind.
    private struct View {
        var cam: SkyLayer.Camera
        var fwd: SIMD2<Float>
        var right: SIMD2<Float>
        var eye: SIMD3<Float>
        func project(_ p: SIMD3<Float>) -> (ndc: SIMD2<Float>, depth: Float)? {
            let rel = p - eye
            let e = SIMD3<Float>(rel.x * right.x + rel.y * fwd.x, rel.x * right.y + rel.y * fwd.y, rel.z)
            let depth = simd_dot(e, cam.forward)
            guard depth > 0.5 else { return nil }
            let x = simd_dot(e, cam.right) / (depth * cam.tanH)
            let y = simd_dot(e, cam.up) / (depth * cam.tanV)
            return (SIMD2(x, y), depth)
        }
    }

    // MARK: - Update

    func update(_ frame: VolcanoFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        // Magma Veins: the full-frame view down into the lake, instead of the crater.
        if let v = frame.veins {
            showingVeins = true
            veinsRenderer.update(v, mood: frame.mood, quality: quality, gentle: gentle, dt: dt, size: size)
            post = veinsRenderer.post
            return
        }
        showingVeins = false
        let s = frame.sky
        let width = Float(max(1, size.width)), height = Float(max(1, size.height))
        let aspect = width / height
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        let keysShow = p.number("keys.show") > 0.5
        keyTop = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let activity = Self.unit(Float(p.number("activity")))
        let plumeDial = Self.unit(Float(p.number("plume")))

        // The sky, seen the camera's way; the weather on the crater.
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
        let lakeLevel: Float = 2.5 * Self.unit(frame.swell)
        let eye = VolcanoCrater.eye
        let v = View(cam: cam, fwd: fwd, right: right, eye: eye)
        showWarp = frame.warp != nil
        if let w = frame.warp {
            warp.centre = SIMD2(0, 0.25)
            warp.update(w, trails: 0.6, nebula: 0.5, intensity: FlashLimiter.sparkleScale(gentle: gentle), quality: quality,
                        size: size, dt: dt, time: t)
        }

        // Flashes, through the limiter: the plume's lightning, the eruption's light, a fireball. Under gentle visuals
        // the scene brightens by no more than a glow (never a flash), and the strokes stay glows inside the plume.
        let night = 1 - Self.smooth(-15, -4, Float(s.sun.altitude))
        let mood = frame.mood
        let base: Float = MoodLook.exposure(mood) * (1 + 0.55 * night)
        let request = Self.unit(frame.flashRequest)
        let asked: Float = gentle ? min(0.12, 0.4 * request) : 0.9 * request
        limiter.gentle = gentle
        if !primed {
            // The limiter starts from black: settle it on the scene's own exposure first, so arriving is never a flash.
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: base, sparkle: 1, dt: 1) }
        }
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: 1, dt: dt)
        exposureOut = limited.exposure
        let passed: Float = asked > 1e-4 ? Self.unit((limited.exposure / base - 1) / asked) : 1
        let share: Float = gentle ? 0.5 * passed : passed
        flashShare = share
        var strokeRaw: Float = 0
        var strongest: PlumeStroke?
        for st in frame.strokes where st.alive && st.brightness > strokeRaw {
            strokeRaw = st.brightness
            strongest = st
        }
        lightningLight = strokeRaw * share
        // The eruption's light on the crater: through the limiter, and under gentle visuals eased in (a glow, not a jump).
        let eruptRaw = frame.eruption?.light ?? 0
        let eruptTarget = eruptRaw * (gentle ? 0.6 : max(0.35, share))
        let ease: Float = gentle ? 1 - exp(-fdt / 0.8) : 1 - exp(-fdt / 0.06)
        eruptGlow += (eruptTarget - eruptGlow) * (dt == 0 ? 1 : ease)
        var fountainBurst: Float = 0
        for f in frame.fountains { fountainBurst = max(fountainBurst, f.burst * Self.unit(f.height / 45)) }
        let glow = Self.lakeLight(energy: frame.energy, activity: activity, fountains: fountainBurst, eruption: eruptGlow,
                                  breach: frame.breach)
        lakeGlow = glow

        // The shake (degrees → NDC): never on Smooth.
        let shakeDeg = quality == .lite ? SIMD2<Float>(0, 0) : frame.cameraShake
        let tanV = Float(tan(Self.verticalFOV * .pi / 360))
        let rad = shakeDeg * (Float.pi / 180)
        shakeApplied = SIMD2(rad.x / (tanV * aspect), rad.y / tanV)
        view = SIMD4(aspect, shakeApplied.x, shakeApplied.y, 0)
        rise += fdt * (7 + 9 * Self.unit(frame.energy) + 14 * frame.billow)
        if rise > 100_000 { rise -= 100_000 }

        // The rows.
        let octaves: Float = quality == .lite ? 2 : 3
        volU[Self.rowA] = SIMD4(aspect, t, octaves, 2 * tanV / height)
        volU[Self.rowCam] = SIMD4(shakeApplied.x, shakeApplied.y, keyTop, 2 / height)
        volU[Self.rowAxes] = SIMD4(fwd.x, fwd.y, right.x, right.y)
        volU[Self.rowEye] = SIMD4(eye, lakeLevel)
        let crackScale: Float = 0.9 + 0.35 * Self.unit(frame.energy) + 0.2 * activity
        volU[Self.rowLake] = SIMD4(VolcanoCrater.lakeRadius, frame.convection, crackScale, activity)
        volU[Self.rowGlow] = SIMD4(glow, 0.5 + 0.5 * Self.unit(frame.energy))
        volU[Self.rowPlay] = SIMD4(Self.unit(frame.energy), Self.unit(frame.tension), Self.unit(frame.drop), Self.unit(frame.beat))
        volU[Self.rowTemps] = SIMD4(1050 + 50 * activity, 830, 600, 0.3 + 0.7 * Self.unit(frame.energy))
        let bend: Float = (frame.wind.x.isFinite ? frame.wind.x : 3) * 0.0002
        volU[Self.rowPlume] = SIMD4(0.35 + 0.65 * plumeDial, Self.unit(frame.billow), bend, rise)
        volU[Self.rowRiver] = SIMD4(Self.unit(frame.river), frame.riverFlow, Self.unit(frame.breach), frame.breachAge ?? -1)
        let moonUp = Self.smooth(-2, 10, Float(s.moon.altitude)) * Float(s.moonLit)
        let skyLight: SIMD3<Float> = (s.zenith * 0.6 + s.horizon * 0.4) * 0.5 + SIMD3<Float>(0.03, 0.035, 0.045) * moonUp
        volU[Self.rowSkyL] = SIMD4(skyLight, night)
        for (k, row) in [Self.rowFountA, Self.rowFountB].enumerated() {
            if k < frame.fountains.count {
                let f = frame.fountains[k]
                volU[row] = SIMD4(f.position.x, f.position.y, max(0, f.height), Self.unit(f.burst))
            } else {
                volU[row] = .zero
            }
        }
        if let e = frame.eruption {
            volU[Self.rowErupt] = SIMD4(e.height, Self.unit(eruptGlow), e.age, e.strength)
        } else {
            volU[Self.rowErupt] = SIMD4(0, Self.unit(eruptGlow), -1, 0)
        }
        // The lightning's glow in the plume: at the strongest stroke's middle (on the plume's plane).
        if let st = strongest {
            let mid = st.origin + SIMD3<Float>(0, 0, -0.2 * st.length)
            volU[Self.rowBolt] = SIMD4(lightningLight, mid.x, mid.z, gentle ? 1 : 0)
        } else {
            volU[Self.rowBolt] = SIMD4(0, 0, 0, gentle ? 1 : 0)
        }
        fillSurprises(frame, share: share)
        volU[Self.rowDims] = SIMD4(VolcanoCrater.footRadius, VolcanoCrater.benchHeight, VolcanoCrater.benchRadius,
                                   VolcanoCrater.topRadius)
        volU[Self.rowDims2] = SIMD4(VolcanoCrater.wallCentre.x, VolcanoCrater.wallCentre.y, VolcanoCrater.rimHeight,
                                    VolcanoCrater.breachAngle)
        let foreTop: Float = keysShow ? keyTop - 0.035 : -0.9
        volU[Self.rowDims3] = SIMD4(VolcanoCrater.breachHalfWidth, 1, foreTop, keysShow ? 1 : 0)
        let rs = VolcanoCrater.riverStart, re = VolcanoCrater.riverEnd
        volU[Self.rowRiverA] = SIMD4(rs.x, rs.y, re.x, re.y)
        for k in 0..<VolcanoRimModel.cellCount {
            if k < frame.cells.count {
                let c = frame.cells[k]
                volU[Self.cellABase + k] = SIMD4(c.position.x, c.position.y, Self.unit(c.glow), Self.unit(c.heat))
                volU[Self.cellBBase + k] = SIMD4(Self.unit(c.birth), Float(c.twin), Self.plateWeight(k, twin: c.twin, birth: c.birth), 0)
            } else {
                volU[Self.cellABase + k] = SIMD4(1e5, 1e5, 0, 0)
                volU[Self.cellBBase + k] = SIMD4(1, -1, 0, 0)
            }
        }

        // Where things stand on screen (tests).
        lakeCentreNDC = v.project(SIMD3(0, 0, lakeLevel))?.ndc ?? .zero
        rimNDC = v.project(SIMD3(0, VolcanoCrater.wallCentre.y + VolcanoCrater.topRadius, VolcanoCrater.rimHeight))?.ndc ?? .zero

        buildSparks(frame, view: v, height: height, tanV: tanV, gentle: gentle)
        buildBolts(frame, view: v, height: height, gentle: gentle, share: share)
        buildColumns(frame, show: keysShow, glow: glow, sky: skyLight, aspect: aspect)

        post = PostSettings(
            bloom: 0.9, bloomThreshold: 0.75,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.035, vignette: 0.34,
            exposure: limited.exposure * weather.exposureBoost,
            warmth: MoodLook.warmthOffset(mood) * 0.35 + s.warmthGrade,
            time: t, quality: quality)
    }

    /// The surprises' rows: each its progress (−1 when none), where, and its light (flashes through the limiter).
    private func fillSurprises(_ frame: VolcanoFrame, share: Float) {
        volU[Self.rowFireball] = SIMD4(-1, 0, 0, 0)
        volU[Self.rowRockfall] = SIMD4(-1, 0, 0, 0)
        volU[Self.rowSteam] = SIMD4(-1, 0, 0, 0)
        // A far storm and its red sprites are SkyKit's (the sky's rows, when its far storms or the weather bring one; the
        // red-sprites surprise calls them through the sky's inputs): the crater draws none of its own.
        volU[Self.rowSprites] = SIMD4(-1, 0, 0, 0)
        volU[Self.rowTree] = SIMD4(-1, 0, 0, 0)
        for sp in frame.surprises {
            let x = sp.progress
            let seed = Float(sp.seed % 1000) / 1000
            switch sp.kind {
            case .fireball:
                let light: Float = 0.6 + 0.4 * share
                volU[Self.rowFireball] = SIMD4(x, sp.angle - 14, 24 + 8 * seed, light)
            case .rockfall:
                volU[Self.rowRockfall] = SIMD4(x, sp.angle, seed, 0)
            case .steamBlast:
                volU[Self.rowSteam] = SIMD4(x, sp.angle, seed, 0)
            case .redSprites:
                break   // SkyKit's sprites, called through the sky's inputs (`SpriteCalling`)
            case .lavaTree:
                volU[Self.rowTree] = SIMD4(x, 0.35 + 0.3 * seed, seed, 0)
            }
        }
    }

    /// The embers, blobs, bombs and sparks: each a streak along its motion on screen, its blackbody light kept as it
    /// shrinks below a pixel.
    private func buildSparks(_ frame: VolcanoFrame, view v: View, height: Float, tanV: Float, gentle: Bool) {
        sparkInstances.removeAll(keepingCapacity: true)
        let pixel: Float = 2 / height
        func add(_ p: SIMD3<Float>, _ vel: SIMD3<Float>, size: Float, kelvin: Float, light: Float, soft: Float,
                 blur: Float = 1.0 / 30) {
            guard light > 1e-3, sparkInstances.count < Self.sparkCapacity * 2, let at = v.project(p) else { return }
            guard abs(at.ndc.x) < 1.3, abs(at.ndc.y) < 1.3 else { return }
            let trueHalf = size / (at.depth * tanV)
            let minHalf = soft > 0.5 ? 2.5 * pixel : 0.9 * pixel
            let half = max(trueHalf, minHalf)
            let keep = min(1, (trueHalf / half) * (trueHalf / half))
            var travel = SIMD2<Float>(0, 0)
            if let next = v.project(p + vel * blur) { travel = next.ndc - at.ndc }
            let lightOut = light * max(keep, 0.06) * (gentle ? 0.7 : 1)
            sparkInstances.append(SIMD4(at.ndc.x, at.ndc.y, travel.x, travel.y))
            sparkInstances.append(SIMD4(half, kelvin, lightOut, soft))
        }
        for e in frame.embers where e.alive {
            let b = e.brightness
            add(e.position, e.velocity, size: e.size, kelvin: e.temperatureNow, light: b * (e.near ? 0.9 : 1.6),
                soft: e.near ? 1 : 0)
        }
        // A long exposure's trails: each blob and bomb in flight streaks back along the arc it has flown (its past
        // positions under gravity, a few segments, so the streak curves as it does in a photograph of fountaining),
        // brightest at its head; landed, it glows where it lies and fades.
        func trail(_ b: LavaParticle, size: Float, light: Float, seconds: Float) {
            guard b.landed == nil else {
                add(b.position, .zero, size: size, kelvin: b.temperature, light: light, soft: 0)
                return
            }
            let g = VolcanoRimModel.gravity
            func past(_ t: Float) -> SIMD3<Float> { b.position - b.velocity * t - SIMD3(0, 0, 0.5 * g * t * t) }
            let n = Self.trailSegments
            for i in 0..<n {
                let t0 = seconds * Float(i) / Float(n), t1 = seconds * Float(i + 1) / Float(n)
                let head = past(t0), tail = past(t1)
                let k = Float(i) / Float(n)
                add(tail, head - tail, size: size * (1 - 0.3 * k), kelvin: b.temperature, light: light * (1 - 0.65 * k),
                    soft: 0, blur: 1)
            }
        }
        for b in frame.blobs where b.alive {
            let fade: Float = b.landed.map { max(0, 1 - $0 / 1.2) } ?? 1
            trail(b, size: b.size * 0.6, light: 2.0 * fade, seconds: 0.5)
        }
        for b in frame.bombs where b.alive {
            let fade: Float = b.landed.map { max(0, 1 - $0 / 3) } ?? 1
            trail(b, size: b.size * 0.4, light: 1.7 * fade, seconds: 0.8)
        }
        sparkCount = sparkInstances.count / 2
    }

    /// The plume's lightning: each stroke's channel and branches projected, through the limiter; none under gentle
    /// visuals (their light stays a glow inside the plume).
    private func buildBolts(_ frame: VolcanoFrame, view v: View, height: Float, gentle: Bool, share: Float) {
        boltInstances.removeAll(keepingCapacity: true)
        channelsDrawn = false
        guard !gentle else { boltCount = 0; return }
        let pixel: Float = 2 / height
        for st in frame.strokes where st.alive {
            let light = Self.unit(st.brightness) * share
            guard light > 0.01 else { continue }
            for (a, b, branch) in st.segments() where boltInstances.count < Self.boltCapacity * 2 {
                guard let pa = v.project(a), let pb = v.project(b) else { continue }
                let core = pixel * (branch ? 0.7 : 1.1)
                boltInstances.append(SIMD4(pa.ndc.x, pa.ndc.y, pb.ndc.x, pb.ndc.y))
                boltInstances.append(SIMD4(core, pixel * (branch ? 6 : 10), light * (branch ? 0.55 : 1), branch ? 1 : 0))
                channelsDrawn = true
            }
        }
        boltCount = boltInstances.count / 2
    }

    /// The keys: a row of basalt columns along the near rim, white keys' standing taller, lit by the crater ahead.
    /// The keys' pavement: the white keys the front row of hexagonal columns (their rects run from the bottom of the view
    /// to the top of the row behind), each black key a column of the row behind, centred on its boundary and as wide as
    /// a white one (its rect just its hexagonal top).
    private func buildColumns(_ frame: VolcanoFrame, show: Bool, glow: SIMD3<Float>, sky: SIMD3<Float>, aspect: Float) {
        columnInstances.removeAll(keepingCapacity: true)
        guard show else { return }
        let bottom: Float = -1.0
        let whiteWidth = frame.keys.first(where: { !$0.key.isBlack })?.key.width ?? (1 / 52)
        let keyHeight = 2 * whiteWidth * aspect          // a white key's width, in NDC y
        let rs: Float = 0.5773503 * 0.7                    // the hexagon's corner radius, squashed (key widths)
        let backCentre = keyTop - rs * keyHeight
        for k in frame.keys {
            if k.key.isBlack {
                let mid = -1 + (k.key.x + 0.5 * k.key.width) * 2
                let x0 = max(-1, mid - whiteWidth), x1 = min(1, mid + whiteWidth)
                columnInstances.append(SIMD4(x0, max(bottom, backCentre - rs * keyHeight), x1, backCentre + rs * keyHeight))
            } else {
                let x0 = -1 + k.key.x * 2, x1 = -1 + (k.key.x + k.key.width) * 2
                columnInstances.append(SIMD4(x0, bottom, x1, keyTop))
            }
            columnInstances.append(SIMD4(k.key.isBlack ? 1 : 0, Self.unit(k.glow), k.pressed ? 1 : 0, 0))
        }
        let light: SIMD3<Float> = glow * 3.5 + sky
        columnLight = SIMD4(light, 1)
    }

    // MARK: - Render

    /// This frame's share of the plates' map (before the scene's pass): every 16th row from this frame's strip, or the
    /// whole map when it is new or the clock jumped more than half a second (a still frame has no frames after it).
    private func encodePlateMap(_ cb: MTLCommandBuffer) {
        guard skipLayers & 512 == 0, let kernel = plateKernel, let enc = cb.makeComputeCommandEncoder() else { return }
        let map = plateMap
        let clock = volU[Self.rowA].y
        let whole = !plateMapWhole || !plateMapClock.isFinite || abs(clock - plateMapClock) > 0.5
        plateMapClock = clock
        let strips = whole ? 1 : Self.plateMapStrips
        let first = whole ? 0 : plateMapStrip
        var job = SIMD4<UInt32>(UInt32(first), UInt32(strips), 0, 0)
        enc.setComputePipelineState(kernel)
        volU.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setBytes(&job, length: MemoryLayout<SIMD4<UInt32>>.size, index: 1)
        enc.setTexture(map, index: 0)
        let tw = max(1, kernel.threadExecutionWidth)
        let th = max(1, min(8, kernel.maxTotalThreadsPerThreadgroup / tw))
        let rows = (Self.plateMapSize - first + strips - 1) / strips
        enc.dispatchThreadgroups(MTLSize(width: (Self.plateMapSize + tw - 1) / tw, height: (rows + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        if whole {
            plateMapWhole = true
            plateMapStrip = 0
            plateMapWholeDraws += 1
        } else {
            plateMapStrip = (plateMapStrip + 1) % Self.plateMapStrips
            plateMapStripDraws += 1
        }
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        if showingVeins {
            veinsRenderer.render(stack: stack, commandBuffer: cb)
            return
        }
        encodePlateMap(cb)
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        volU[Self.rowSprites].y = plateMapWhole ? 1 : 0
        volU[Self.rowSprites].w = Float(skipLayers & 0x7FF)
        volU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        volU[Self.rowSprites].w = 0
        sky.bindStars(e)
        e.setFragmentTexture(plateMap, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if showWarp { warp.draw(e) }
        let row = MemoryLayout<SIMD4<Float>>.stride
        let sparkBytes = sparkInstances.count * row
        let boltBytes = boltInstances.count * row
        if sparkBytes + boltBytes > 0, !ring.isEmpty, skipLayers & 2048 == 0 {
            slot = (slot + 1) % ring.count
            let buf = ring[slot]
            if sparkBytes > 0 { sparkInstances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: sparkBytes) } }
            if boltBytes > 0 {
                boltInstances.withUnsafeBytes { (buf.contents() + sparkBytes).copyMemory(from: $0.baseAddress!, byteCount: boltBytes) }
            }
            var vw = view
            if sparkCount > 0 {
                e.setRenderPipelineState(sparks)
                e.setVertexBuffer(buf, offset: 0, index: 0)
                e.setVertexBytes(&vw, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sparkCount)
            }
            if boltCount > 0 {
                e.setRenderPipelineState(bolts)
                e.setVertexBuffer(buf, offset: sparkBytes, index: 0)
                e.setVertexBytes(&vw, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                e.setFragmentBytes(&vw, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: boltCount)
            }
        }
        if skipLayers & 4096 == 0 { weather.draw(e) }
        if !columnInstances.isEmpty, skipLayers & 8192 == 0 {
            e.setRenderPipelineState(columns)
            columnInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            var still = SIMD4<Float>(view.x, 0, 0, 0)   // the columns stand still while the world shakes
            e.setVertexBytes(&still, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            var light = columnLight
            e.setFragmentBytes(&light, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: columnInstances.count / 2)
        }
        e.endEncoding()
    }
}
