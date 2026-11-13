import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Great Barrier Reef (spec §9.1–§9.3): a split view at the edge of a coral cay's lagoon, the lens right at the
/// waterline. Above the rolling meniscus, the Living Sky over the Coral Sea (facing east over the reef crest, or on a
/// shower night 60° from the radiant), the low white cay with its pisonia trees on the left, the crest breaking white on
/// the horizon, terns wheeling by day and the lagoon mirroring it all; below it, the reef in clear turquoise water with
/// Coral Pulse's seven coral groups, the giant clam, the school darting along the melody, the chromis over the
/// staghorn, the spawn rising on spawning nights, marine snow, and a strip of wet sand for the keys.
///
/// The sky and the reef are drawn each in its own scissored part of the frame (spec §12), the reef first and the sky
/// over it, feathered along the meniscus. Every flash (the corals' glow, the patches with them, the school's silver,
/// the colour wave, lightning) goes through a `FlashLimiter`; Gentle visuals halve them and calm the glitter and the
/// lens's dips under the swell. The renderers step by the director's visual dt (held time holds the snow and the
/// limiters); the particles' buffers are made once.
///
/// Excitement (Fire & Neon spec §5.5): a spawning burst is the spawn's own beads (the model's), the corals' flare through
/// its own `FlashLimiter` (a glow under gentle visuals) and a pink haze in the water (`ReefU.spawn.w`); the visitors (a
/// manta, a green turtle, a blacktip reef shark) are a third kind in the dots' pass, each one instance; tension's
/// tightening and the drop's burst are the school's own (Coral Pulse's spread).
@MainActor
final class GreatBarrierReefRenderer: ThemeRenderer {
    /// Polyp patches sent to the GPU (fewer on Smooth), and the beads (the spawn's own cap: 300 on Smooth).
    static func patchBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : CoralPulse.cap }
    static func beadBudget(_ q: QualityLevel) -> Int { CoralSpawning.cap(q) }
    /// The small blue-green fish hovering over the staghorn (besides the school).
    nonisolated static let chromisCount = 10
    /// The most fish and dots drawn: the school at 80, the chromis, every bead and every fleck of marine snow.
    nonisolated static let fishCapacity = CoralPulse.schoolSizes.upperBound + chromisCount
    nonisolated static let dotCapacity = CoralSpawning.capacity + MarineSnow.capacity
    /// The visitors drawn at most at once (one each of the three surprises).
    nonisolated static let visitorCapacity = 3

    /// The uniform block (MSL `ReefU`): 17 header rows, the 7 groups, their 7 hues, then the patches.
    nonisolated static let headerCount = 17
    nonisolated static let groupBase = 17
    nonisolated static let hueBase = 24
    nonisolated static let patchBase = 31
    nonisolated static let uniformCount = 31 + CoralPulse.cap

    /// The view: its vertical field (degrees); the above view's horizon this far over the waterline (NDC), seen from
    /// this height over the lagoon (m); the view below has its eye level this share of the way up the water.
    nonisolated static let verticalFOV = 56.0
    nonisolated static let horizonLift: Float = 0.36
    nonisolated static let eyeHeight: Float = 0.25
    nonisolated static let eyeShare: Float = 0.82
    /// The cay's azimuth (degrees: a little north of east, so it stands on the left of the view east).
    nonisolated static let cayAzimuth = 66.0
    /// The corals stand this many times as tall as Coral Pulse's polyp reach (`CoralPulse.groupTop`), so the reef fills
    /// the water's lower half; the patches and the spawn's beads are placed on the same scale.
    nonisolated static let coralScale: Float = 1.9
    /// A bead's height on screen keeps its share of the way from its coral's top to the surface.
    nonisolated static let beadRise: Float = 0.8
    /// Gentle visuals keep the lens's dips under the swell to this share of the way up the frame.
    nonisolated static let gentleWash: Float = 0.35

    /// The reef's sky (tests swap its star texture), weather and Galaxy Warp.
    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let above, below: SkyPipeline
    private let dots, keys: MTLRenderPipelineState
    private var reefU = [SIMD4<Float>](repeating: .zero, count: GreatBarrierReefRenderer.uniformCount)
    private var keyInstances: [KeyInstance] = []
    private var fishInstances: [SIMD4<Float>] = []
    private var dotInstances: [SIMD4<Float>] = []
    /// The visitors: two rows each (as the fish's), and each one's draw (2, aspect, its shape, its stroke's phase).
    private var visitorInstances: [SIMD4<Float>] = []
    private var visitorKinds: [SIMD4<Float>] = []
    private var burstLimiter = FlashLimiter()
    private var burstPrimed = false
    private var burstGlow = ExcitementGlow()
    /// Excitement as drawn (tests read them): the corals' flare after its limiter and what it asked for, the haze, the
    /// visitors drawn.
    private(set) var burstOut: Float = 0
    private(set) var burstRequest: Float = 0
    private(set) var hazeOut: Float = 0
    var visitorCount: Int { visitorKinds.count }
    var flashesInLastSecond: Int { max(limiter.recent, burstLimiter.recent) }
    var flashTotal: Int { limiter.total + burstLimiter.total }
    /// The instance buffers: a ring of three, made once (fish and dots together).
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private(set) var bufferAllocations = 0
    private var snow = MarineSnow(quality: .high, seed: 0x2EEF_5A0F)
    private var limiter = FlashLimiter()
    private var groupLimiters = [FlashLimiter](repeating: FlashLimiter(), count: CoralPulse.groupCount)
    private var schoolLimiter = FlashLimiter()
    private var waveLimiter = FlashLimiter()
    private var aspect: Float = 16.0 / 9
    private(set) var post = PostSettings()

    /// The corals' glow after their flash limiters (gentle visuals halve it), bass first.
    private(set) var coralGlowOut = [Float](repeating: 0, count: CoralPulse.groupCount)
    /// The school's silver flash and the colour wave after theirs.
    private(set) var schoolFlashOut: Float = 0
    private(set) var waveOut: Float = 0
    /// What was drawn this frame.
    private(set) var patchCount = 0, fishCount = 0, beadCount = 0, snowCount = 0
    /// Where things sit on screen (NDC y): the keys' top, the waterline at rest and the meniscus at the frame's middle
    /// now, the above view's horizon and the view below's eye level.
    private(set) var keyTop: Float = -0.76
    private(set) var waterlineY: Float = -0.1
    private(set) var meniscusY: Float = -0.1
    private(set) var horizonY: Float = 0.26
    private(set) var eyeLevelY: Float = -0.22
    /// The meniscus's lowest and highest points across the frame this frame (the two parts' scissors).
    private(set) var meniscusRange: ClosedRange<Float> = -0.12 ... -0.08
    private var size = CGSize(width: 1280, height: 720)
    /// The shader's uniforms (tests read them).
    var uniforms: [SIMD4<Float>] { reefU }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }
    /// The fish drawn this frame (tests): position (NDC), half-length, heading.
    var fish: [SIMD4<Float>] { stride(from: 0, to: fishInstances.count, by: 2).map { fishInstances[$0] } }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: GreatBarrierReefShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, blend: Bool, storms: Bool = false) -> MTLRenderPipelineState? {
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
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        // The dots blend over the water and leave its depth alone.
        func makeDots() -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction("reef_dot_vertex")
            d.fragmentFunction = lib.skyFunction("reef_dot_fragment")
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let a = SkyPipeline(build: { make("reef_vertex", "reef_above_fragment", blend: true, storms: $0) }),
              let b = SkyPipeline(build: { make("reef_vertex", "reef_below_fragment", blend: false, storms: $0) }),
              let k = make("reef_keys_vertex", "reef_keys_fragment", blend: false), let dd = makeDots() else { return nil }
        let bytes = (Self.fishCapacity + Self.dotCapacity) * 2 * MemoryLayout<SIMD4<Float>>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(buf)
        }
        sky = s; weather = w; warp = gw; above = a; below = b; keys = k; dots = dd
        ring = buffers
        bufferAllocations = buffers.count
        fishInstances.reserveCapacity(Self.fishCapacity * 2)
        dotInstances.reserveCapacity(Self.dotCapacity * 2)
        visitorInstances.reserveCapacity(Self.visitorCapacity * 2)
        visitorKinds.reserveCapacity(Self.visitorCapacity)
        keyInstances.reserveCapacity(88)
        sky.verticalFOV = Self.verticalFOV
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }
    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// Where the waterline rests (NDC y) for the frame's `waterlineY` (a share of the frame from its bottom edge), kept
    /// at least a fifth of the frame clear of the keys' sand and a quarter under the top.
    nonisolated static func restingWaterline(_ share: Float, keyTop: Float) -> Float {
        let y = -1 + 2 * (share.isFinite ? share : 0.45)
        return min(0.5, max(keyTop + 0.2, y))
    }

    /// The meniscus (NDC y) at screen x, as the shader draws it (`reefMeniscus`).
    nonisolated static func meniscus(at x: Float, rest: Float, aspect: Float, phases p: SIMD4<Float>, liftScale: Float, wash: Float,
                                     storm: Float, time t: Float) -> Float {
        let X = x * aspect * 0.5
        let lift = 0.4 * sin(p.x + 1.1 * X) + 0.3 * sin(p.y - 0.8 * X) + 0.2 * sin(p.z + 2.3 * X) + 0.1 * sin(p.w - 3.7 * X)
        let wobble = 0.0025 * sin(9 * X + 2.1 * t) + 0.0015 * sin(17 * X - 3.3 * t + 1.7)
        return rest + liftScale * lift + wobble * (0.5 + storm) + wash
    }

    /// The stage's width (stage units: the water's height on screen) for a frame's aspect and the water's height (NDC).
    nonisolated static func stageWidth(aspect: Float, waterHeight h: Float) -> Float { 2 * aspect / max(h, 0.05) }

    /// A coral group's half-width (stage units): a share of its stretch of the reef by its kind, within bounds.
    nonisolated static func halfWidth(_ kind: CoralKind, stageWidth: Float) -> Float {
        let base = min(0.7, max(0.12, 0.46 * stageWidth / Float(CoralPulse.groupCount)))
        switch kind {
        case .brain: return base * 0.88
        case .plate: return base
        case .soft: return base * 0.74
        case .staghorn: return base * 0.95
        }
    }

    nonisolated static func kindIndex(_ k: CoralKind) -> Float {
        switch k {
        case .brain: return 0
        case .plate: return 1
        case .soft: return 2
        case .staghorn: return 3
        }
    }

    /// The NDC point of a place on the reef's stage (x 0…1 across the frame, y in water heights).
    func screenPoint(x: Float, waterHeight y: Float) -> SIMD2<Float> {
        SIMD2(-1 + 2 * x, keyTop + y * (waterlineY - keyTop))
    }

    /// Where a coral group's top stands on screen (NDC).
    func groupTop(_ g: Int) -> SIMD2<Float> {
        let i = min(max(g, 0), CoralPulse.groupCount - 1)
        return screenPoint(x: CoralPulse.groupX[i], waterHeight: CoralPulse.groupTop[i] * Self.coralScale)
    }

    /// Light (rgb) after `metres` of clear ocean: the shader's waterAbsorb.
    nonisolated static func absorb(_ metres: Float) -> SIMD3<Float> {
        let m = max(0, metres)
        return SIMD3(exp(-0.35 * m), exp(-0.07 * m), exp(-0.03 * m))
    }

    func update(_ frame: ReefFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        self.size = size
        aspect = Float(max(1, size.width) / max(1, size.height))
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let keysShow = p.number("keys.show") > 0.5
        keyTop = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let rest = Self.restingWaterline(frame.waterlineY, keyTop: keyTop)
        waterlineY = rest
        let h = rest - keyTop
        eyeLevelY = keyTop + Self.eyeShare * h
        horizonY = min(0.9, rest + Self.horizonLift)
        let storm = Self.unit((frame.swellScale - 1) / 0.8)
        let liftScale = 2 * GreatBarrierReefModel.liftScale(s)
        let wash = Self.unit(frame.lensUnder) * (gentle ? Self.gentleWash : 1) * (1.3 - rest)
        meniscusY = Self.meniscus(at: 0, rest: rest, aspect: aspect, phases: frame.swellPhases, liftScale: liftScale, wash: wash,
                                  storm: storm, time: t)
        var lo = Float.infinity, hi = -Float.infinity
        for i in 0...48 {
            let x = -1 + 2 * Float(i) / 48
            let y = Self.meniscus(at: x, rest: rest, aspect: aspect, phases: frame.swellPhases, liftScale: liftScale, wash: wash,
                                  storm: storm, time: t)
            lo = min(lo, y); hi = max(hi, y)
        }
        meniscusRange = (lo - 0.01) ... (hi + 0.01)

        // The sky: facing the camera's way (east, or away from a shower's radiant), its horizon over the waterline.
        sky.viewAzimuth = frame.cameraAzimuth
        sky.horizonY = horizonY
        sky.verticalFOV = Self.verticalFOV
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: t)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizonY))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        showWarp = frame.warp != nil
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (1 - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: t)
        }

        // Light: the sun and the moon (each by its own weight), the sky all round, the night, the mood.
        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let day = Float(Self.smooth(-4, 8, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, 0.2 * MoodLook.hazeScale(mood) + s.mist)
        let sunColour: SIMD3<Float> = lights.sunColor * 1.6
        let moonColour: SIMD3<Float> = lights.moonColor * 0.3
        let sky0: SIMD3<Float> = s.zenith * 0.55
        let ambient: SIMD3<Float> = (sky0 + s.horizon * 0.45) * 0.9
        // The light falling on the water, on the Underwater Kit's scale (1: a noon sun and sky): a low sun's light
        // mostly glances off, so under water dusk is the blue of the sky overhead.
        let sunIn = Float(0.35 + 0.65 * Self.smooth(2, 30, s.sun.altitude))
        let overhead: SIMD3<Float> = s.zenith * 0.75 + s.horizon * 0.25
        let sunIntoWater: SIMD3<Float> = lights.sunColor * (0.8 * lights.sun.w * sunIn)
        let moonIntoWater: SIMD3<Float> = lights.moonColor * (0.09 * lights.moon.w)
        let surfaceLight: SIMD3<Float> = sunIntoWater + moonIntoWater + overhead * 0.3
        limiter.gentle = gentle
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let limited = limiter.limit(exposure: exposure, sparkle: 1, dt: dt)

        // Coral Pulse, each flash through its limiter: the groups' glow (their patches follow it), the school's silver,
        // the colour wave.
        let W = Self.stageWidth(aspect: aspect, waterHeight: h)
        var ratio = [Float](repeating: 0, count: CoralPulse.groupCount)
        // A spawning burst's flare: one limiter for the whole reef (primed at rest, so arriving is never a flash), its light
        // added to every group's glow; under gentle visuals a glow.
        burstLimiter.gentle = gentle
        if !burstPrimed {
            burstPrimed = true
            for _ in 0..<16 { _ = burstLimiter.limit(exposure: 1, sparkle: 1, dt: 1) }
        }
        let burstAsk = Self.unit(frame.burst)
        let askedBurst = ExcitementGlow.ask(burstAsk, gentle: gentle, scale: 0.6)
        let burstLimited = burstLimiter.limit(exposure: 1 + askedBurst, sparkle: 1, dt: dt)
        let burstPassed = ExcitementGlow.passed(limited: burstLimited.exposure, base: 1, asked: askedBurst)
        burstRequest = burstAsk
        burstOut = burstGlow.update(request: burstAsk, passed: burstPassed, gentle: gentle, dt: dt)
        hazeOut = Self.unit(frame.burstHaze) * (gentle ? 0.6 : 1)
        for (g, group) in frame.corals.prefix(CoralPulse.groupCount).enumerated() {
            groupLimiters[g].gentle = gentle
            let raw = Self.unit(group.glow)
            let l = groupLimiters[g].limit(exposure: raw, sparkle: 1, dt: dt)
            coralGlowOut[g] = Self.unit(l.exposure * l.sparkle)
            ratio[g] = raw > 1e-4 ? min(1, coralGlowOut[g] / raw) : (gentle ? 0.5 : 1)
            let shown = min(1, coralGlowOut[g] + 0.8 * burstOut)
            reefU[Self.groupBase + g] = SIMD4(group.x * W, group.top * Self.coralScale, Self.halfWidth(group.kind, stageWidth: W), shown)
            reefU[Self.hueBase + g] = SIMD4(group.colour, Self.kindIndex(group.kind))
        }
        for i in Self.patchBase..<Self.uniformCount { reefU[i] = .zero }
        let patches = CoralPulse.visible(frame.patches, limit: Self.patchBudget(quality))
        patchCount = patches.count
        for (i, pt) in patches.enumerated() {
            let g = min(max(pt.group, 0), CoralPulse.groupCount - 1)
            reefU[Self.patchBase + i] = SIMD4(pt.x * W, pt.y * Self.coralScale, Float(g), Self.unit(pt.brightness) * ratio[g])
        }
        schoolLimiter.gentle = gentle
        let sl = schoolLimiter.limit(exposure: Self.unit(frame.school.flash), sparkle: 1, dt: dt)
        schoolFlashOut = Self.unit(sl.exposure * sl.sparkle)
        waveLimiter.gentle = gentle
        let wl = waveLimiter.limit(exposure: Self.unit(frame.colourWave?.strength ?? 0), sparkle: 1, dt: dt)
        waveOut = Self.unit(wl.exposure * wl.sparkle)
        if let w = frame.colourWave {
            reefU[13] = SIMD4(w.left, w.right, CoralPulse.waveWidth, waveOut)
            let waveColour: SIMD3<Float> = CoralPulse.rgb(hue: w.hue) * 0.9 + SIMD3<Float>(repeating: 0.1)
            reefU[14] = SIMD4(waveColour, schoolFlashOut)
        } else {
            reefU[13] = SIMD4(-1, -1, CoralPulse.waveWidth, waveOut)
            reefU[14] = SIMD4(0, 0, 0, schoolFlashOut)
        }

        // The header.
        let az = Float(frame.cameraAzimuth * .pi / 180)
        let forward = SIMD2<Float>(sin(az), cos(az))
        let rough = Self.unit(s.wind * 0.8 + s.rain * 0.4 + storm * 0.5)
        let octaves: Float = quality == .lite ? 2 : 3
        let birds = day * (1 - 0.6 * Self.unit(s.cloudCover)) * (1 - Self.unit(s.rain))
        let shafts = day * (1 - 0.7 * Self.unit(s.cloudCover))
        reefU[0] = SIMD4(aspect, keyTop, rest, keyTop)
        reefU[1] = frame.swellPhases
        reefU[2] = SIMD4(liftScale, wash, eyeLevelY, t)
        reefU[3] = SIMD4(forward.x, forward.y, cam.tanH, cam.tanV)
        reefU[4] = SIMD4(surfaceLight, day)
        reefU[5] = lights.sun
        reefU[6] = SIMD4(sunColour, night)
        reefU[7] = lights.moon
        reefU[8] = SIMD4(moonColour, sparkleScale)
        reefU[9] = SIMD4(ambient, haze)
        reefU[10] = SIMD4(horizonY, Self.eyeHeight, rough, octaves)
        reefU[11] = SIMD4(Self.unit(s.rain), Self.unit(s.cloudCover), storm, Self.unit(s.mist))
        reefU[12] = SIMD4(Self.unit(frame.polypsOpen), 0, sparkleScale, Float(patchCount))
        reefU[15] = SIMD4(Self.unit(frame.spawn.slick), Self.unit(frame.spawn.intensity), shafts, hazeOut)
        reefU[16] = SIMD4(Float(Self.cayAzimuth * .pi / 180), az, birds, Self.unit(frame.burstRise))

        // The light in the water where the fish swim (rgb, about a metre down) and on the sand's keys.
        let fromAbove: SIMD3<Float> = surfaceLight * Self.absorb(0.9) * 0.55
        let waterGlow: SIMD3<Float> = surfaceLight * Self.absorb(0.3) * SIMD3<Float>(0.04, 0.3, 0.375)
        let fishLight: SIMD3<Float> = fromAbove + waterGlow
        buildFish(frame, h: h, light: fishLight, sparkle: sparkleScale, t: t)
        buildDots(frame, h: h, light: fishLight, quality: quality, dt: dt, storm: storm, night: night)
        buildVisitors(frame, h: h, light: fishLight)

        // Keys: wet sand along the bottom edge, turquoise where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let skyMean: Float = (ambient.x + ambient.y + ambient.z) / 3
            let light: Float = min(1.4, 0.15 + 0.55 * (lights.sun.w + 0.4 * lights.moon.w) + 0.4 * skyMean)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.65, bloomThreshold: 0.85,
            dof: 0, focusDepth: 0.2,   // no depth of field: the stars and their reflections stay sharp
            grade: 0, grain: 0.015, vignette: 0.28,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.05 * day - 0.05 * night,
            time: t, quality: quality)
    }

    /// The school (in the frame's own places, all turned with its heading, silver on accents) and the chromis hovering
    /// over the staghorn.
    private func buildFish(_ frame: ReefFrame, h: Float, light: SIMD3<Float>, sparkle: Float, t: Float) {
        fishInstances.removeAll(keepingCapacity: true)
        let scale = min(1.3, max(0.7, h / 0.66))
        let body = SIMD3<Float>(0.38, 0.62, 0.80) * light
        let silver = light * (1.4 * schoolFlashOut * sparkle)
        for (i, p) in frame.school.positions.prefix(CoralPulse.schoolSizes.upperBound).enumerated() {
            let k = Float((i * 37) % 11) / 10
            let heading = frame.school.heading + 0.12 * sin(t * 5.3 + Float(i) * 1.7)
            let at = screenPoint(x: p.x, waterHeight: p.y)
            fishInstances.append(SIMD4(at.x, at.y, 0.013 * scale * (0.8 + 0.4 * k), heading))
            fishInstances.append(SIMD4(body * (0.9 + 0.2 * k) + silver, 0.95))
        }
        // The chromis: a little cloud over each staghorn, facing into the current, nosing about.
        let chromis = SIMD3<Float>(0.22, 0.62, 0.78) * light
        for i in 0..<Self.chromisCount {
            let g = i % 2 == 0 ? 5 : 6
            let fi = Float(i)
            let x = CoralPulse.groupX[g] + 0.03 * sin(fi * 2.1) + 0.012 * sin(t * 0.37 + fi)
            let y = CoralPulse.groupTop[g] * Self.coralScale + 0.06 + 0.05 * Float((i * 7) % 5) / 4 + 0.012 * sin(t * 0.51 + fi * 1.3)
            let at = screenPoint(x: x, waterHeight: y)
            let facing: Float = sin(t * 0.11 + fi * 0.8) > 0 ? 0.05 : .pi - 0.05
            fishInstances.append(SIMD4(at.x, at.y, 0.009 * scale, facing + 0.1 * sin(t * 1.9 + fi)))
            fishInstances.append(SIMD4(chromis, 0.9))
        }
        fishCount = fishInstances.count / 2
    }

    /// The spawn's beads (catching what light there is, a little even on a dark night) and the marine snow.
    private func buildDots(_ frame: ReefFrame, h: Float, light: SIMD3<Float>, quality: QualityLevel, dt: Double, storm: Float, night: Float) {
        dotInstances.removeAll(keepingCapacity: true)
        let pixel = 2 / Float(max(1, size.height))
        let seen = light + SIMD3<Float>(0.05, 0.07, 0.09) * night
        for b in frame.spawn.beads.prefix(Self.beadBudget(quality)) {
            // Released from their coral's polyps (on the corals' scale), rising to the surface.
            let y = b.position.y < 1 ? 1 - (1 - b.position.y) * Self.beadRise : 1
            let at = screenPoint(x: b.position.x, waterHeight: y)
            let k = Self.unit(b.brightness)
            // Pale bundles catch what light there is: the moon's, the corals' glow; a soft glow round each.
            let lit: SIMD3<Float> = b.colour * (seen * 1.6 + SIMD3<Float>(repeating: 0.1 * night))
            dotInstances.append(SIMD4(at.x, at.y, b.size * pixel * 0.95, 0))
            dotInstances.append(SIMD4(lit, min(1, 0.95 * k)))
        }
        beadCount = dotInstances.count / 2
        snow.setQuality(quality)
        snow.current = SIMD3(0.01 + 0.03 * storm, 0, 0.002)
        snow.step(dt: dt)
        let pale = SIMD3<Float>(0.85, 0.9, 0.95) * seen
        for f in snow.live {
            let z = f.position.z
            let at = screenPoint(x: f.position.x, waterHeight: f.position.y * 0.97)
            let r = (1.9 - 1.3 * z) * f.size * pixel * 0.6
            dotInstances.append(SIMD4(at.x, at.y, r, 0))
            dotInstances.append(SIMD4(pale, Self.unit(f.brightness) * (0.18 + 0.32 * (1 - z))))
        }
        snowCount = dotInstances.count / 2 - beadCount
    }

    /// The visitors (surprises), each crossing the whole water in about ten seconds, near the lens (large, and less of the
    /// water's blue between: their own colours show): a manta gliding high, a green turtle stroking up toward the surface,
    /// a blacktip reef shark cruising over the corals. Each is one instance (its place, half-length and heading; the
    /// light on it) and one draw (its shape and its stroke's phase).
    private func buildVisitors(_ frame: ReefFrame, h: Float, light: SIMD3<Float>) {
        visitorInstances.removeAll(keepingCapacity: true)
        visitorKinds.removeAll(keepingCapacity: true)
        let scale = min(1.3, max(0.7, h / 0.66))
        let grey: Float = (light.x + light.y + light.z) / 3
        let near: SIMD3<Float> = light * 0.6 + SIMD3<Float>(repeating: grey * 0.45)
        for s in frame.surprises.prefix(Self.visitorCapacity) {
            let age = s.age
            let env = ExcitementPlay.envelope(age: age, life: s.duration, rise: 0.8, fall: 1.0)
            guard env > 0.002 else { continue }
            let right = s.unit(0) < 0.5
            let run: Float = s.progress
            let x: Float = right ? -0.3 + 1.6 * run : 1.3 - 1.6 * run
            let heading: Float = right ? 0 : .pi
            let y: Float, half: Float, phase: Float
            switch s.index {
            case 0:
                y = 0.66 + 0.1 * s.unit(1) + 0.02 * sin(age * 0.5)
                half = 0.3 * scale
                phase = age * 0.38
            case 1:
                y = 0.5 + 0.1 * s.unit(1) + 0.12 * run
                half = 0.23 * scale
                phase = age * 0.45
            default:
                y = 0.47 + 0.08 * s.unit(1) + 0.015 * sin(age * 0.6)
                half = 0.33 * scale
                phase = age * 0.8
            }
            let at = screenPoint(x: x, waterHeight: y)
            visitorInstances.append(SIMD4(at.x, at.y, half, heading))
            visitorInstances.append(SIMD4(near, 0.97 * env))
            visitorKinds.append(SIMD4(2, aspect, Float(s.index), phase))
        }
    }

    /// The scissor rectangle (pixels, top-left origin) between two NDC heights of the target.
    private static func scissor(from y0: Float, to y1: Float, width: Int, height: Int) -> MTLScissorRect? {
        let lo = max(-1, min(1, y0)), hi = max(-1, min(1, y1))
        guard hi > lo else { return nil }
        let top = Int(((1 - hi) / 2 * Float(height)).rounded(.down))
        let bottom = Int(((1 - lo) / 2 * Float(height)).rounded(.up))
        let t = max(0, min(height, top)), b = max(0, min(height, bottom))
        guard b > t else { return nil }
        return MTLScissorRect(x: 0, y: t, width: width, height: b - t)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass), let target = stack.hdrTarget else { return }
        let W = target.width, H = target.height
        let full = MTLScissorRect(x: 0, y: 0, width: W, height: H)
        let pixel = 2 / Float(max(1, H))
        let skyU = sky.uniforms
        let underRect = Self.scissor(from: -1, to: meniscusRange.upperBound + 3 * pixel, width: W, height: H)
        let aboveRect = Self.scissor(from: meniscusRange.lowerBound - 2 * pixel, to: 1, width: W, height: H)

        // The reef below the meniscus, then the sky and the lagoon above it, feathered over the reef along the line.
        if let rect = underRect {
            e.setScissorRect(rect)
            e.setRenderPipelineState(below.state(storms: sky.storms))
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            reefU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            sky.bindStars(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let rect = aboveRect {
            e.setScissorRect(rect)
            e.setRenderPipelineState(above.state(storms: sky.storms))
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            reefU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            sky.bindStars(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if showWarp { warp.draw(e) }
            weather.draw(e)
        }

        // The fish, the beads and the snow, in the water (and any visitors, after them).
        let fishBytes = fishInstances.count * MemoryLayout<SIMD4<Float>>.stride
        let dotBytes = dotInstances.count * MemoryLayout<SIMD4<Float>>.stride
        if let rect = underRect, fishBytes + dotBytes > 0 || !visitorKinds.isEmpty, !ring.isEmpty {
            slot = (slot + 1) % ring.count
            let buf = ring[slot]
            if fishBytes > 0 { fishInstances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: fishBytes) } }
            if dotBytes > 0 {
                dotInstances.withUnsafeBytes { (buf.contents() + fishBytes).copyMemory(from: $0.baseAddress!, byteCount: dotBytes) }
            }

            e.setScissorRect(rect)
            e.setRenderPipelineState(dots)
            reefU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            if fishCount > 0 {
                var kind = SIMD4<Float>(0, aspect, 0, 0)
                e.setVertexBuffer(buf, offset: 0, index: 0)
                e.setVertexBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                e.setFragmentBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: fishCount)
            }
            let dotCount = beadCount + snowCount
            if dotCount > 0 {
                var kind = SIMD4<Float>(1, aspect, 0, 0)
                e.setVertexBuffer(buf, offset: fishBytes, index: 0)
                e.setVertexBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                e.setFragmentBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: dotCount)
            }
            // Each visitor: its two rows straight into the vertex bytes (no buffer offset), and its own shape.
            let row = MemoryLayout<SIMD4<Float>>.stride
            for (i, k) in visitorKinds.enumerated() where 2 * i + 1 < visitorInstances.count {
                var kind = k
                visitorInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress! + 2 * row * i, length: 2 * row, index: 0) }
                e.setVertexBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                e.setFragmentBytes(&kind, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
        }

        e.setScissorRect(full)
        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
