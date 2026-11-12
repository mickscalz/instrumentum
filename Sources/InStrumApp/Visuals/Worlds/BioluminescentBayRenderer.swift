import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Bioluminescent Bay (spec §9.1, §9.2): the Living Sky facing the pole (so Crux, or the Plough, stands over the
/// headlands and an aurora over the bay's mouth), two headlands with palms and mangroves, the lighthouse on the far
/// point, a moored boat with its lantern, the still bay mirroring it all, the glow line along the waterline, Glow Wake's
/// patches, wakes, darts and pool on the water, weather on the water, near palms and a dark glass keyboard on the sand.
@MainActor
final class BioluminescentBayRenderer: ThemeRenderer {
    /// Glow Wake sent to the GPU (fewer on Smooth): patches, wakes and darts.
    static func patchBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : GlowWake.cap }
    static func wakeBudget(_ q: QualityLevel) -> Int { q == .lite ? 8 : GlowWake.wakeCap }
    static func dartBudget(_ q: QualityLevel) -> Int { q == .lite ? 6 : GlowWake.dartCap }

    /// Shore geometry in metres (the shader reads it from the uniforms): the eye above the water, the waterline out.
    nonisolated static let cameraHeight: Float = 1.6
    nonisolated static let waterline: Float = 6
    /// Depth 0 of the bay lies this far out (metres); depth d at nearOut / (1 − 0.9·d), so hard notes land close.
    nonisolated static let nearOut: Float = 7.5
    /// The moored boat: its azimuth from the view's centre (degrees, right +) and distance (metres); the lantern hangs on
    /// its mast at (across, up) in the boat's own frame.
    nonisolated static let boatAzimuth: Float = -6.9
    nonisolated static let boatOut: Float = 42
    nonisolated static let lanternLocal = SIMD2<Float>(0.72, 2.4)
    /// The lighthouse lamp on the far point: azimuth from the view's centre and altitude (degrees).
    nonisolated static let lighthouseAzimuth: Float = 8.6
    nonisolated static let lighthouseAltitude: Float = 1.75
    /// The uniform block (MSL `BayU`): 12 header rows, then the patches, the wakes (two rows each) and the darts (two).
    nonisolated static let headerCount = 12
    nonisolated static let patchBase = 12
    nonisolated static let wakeBase = 12 + GlowWake.cap
    nonisolated static let wakeBBase = 12 + GlowWake.cap + GlowWake.wakeCap
    nonisolated static let dartBase = 12 + GlowWake.cap + 2 * GlowWake.wakeCap
    nonisolated static let dartBBase = 12 + GlowWake.cap + 2 * GlowWake.wakeCap + GlowWake.dartCap
    nonisolated static let uniformCount = 12 + GlowWake.cap + 2 * GlowWake.wakeCap + 2 * GlowWake.dartCap

    typealias Camera = (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, tanH: Float, tanV: Float)

    /// The bay's sky (tests swap its star texture).
    let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let bay: SkyPipeline
    private let keys: MTLRenderPipelineState
    private var bayU = [SIMD4<Float>](repeating: .zero, count: 12 + GlowWake.cap + 2 * GlowWake.wakeCap + 2 * GlowWake.dartCap)
    private var oceanU = [SIMD4<Float>](repeating: .zero, count: 7)   // the bay doesn't travel: travel stays 0
    private var keyInstances: [KeyInstance] = []
    private var aspect: Float = 16.0 / 9
    private var limiter = FlashLimiter()
    private var lanternLevel: Float = 0
    private var lanternPrimed = false
    private var camera: Camera?
    private(set) var post = PostSettings()
    /// The glow line's brightness after the flash limiter: the dark × rain (the frame's glowScale) × "Plankton glow"
    /// (gentle visuals halve it).
    private(set) var glowOut: Float = 0
    /// The lighthouse's flash × "Lighthouse" after the limiter's sparkle (gentle visuals halve it).
    private(set) var lighthouseOut: Float = 0
    /// The boat's lantern: lit once the sun is down × "Boat lantern", gliding on and off, with a gentle flicker.
    private(set) var lanternOut: Float = 0
    /// Glow Wake drawn this frame.
    private(set) var patchCount = 0, wakeCount = 0, dartCount = 0
    /// The horizon and the waterline in NDC y.
    private(set) var horizonY: Float = -0.2
    private(set) var waterlineY: Float = -0.6
    /// Where the lantern and the lighthouse lamp sit on screen (NDC).
    private(set) var lanternScreen = SIMD2<Float>(0, 0)
    private(set) var lighthouseScreen = SIMD2<Float>(0, 0)
    /// The shader's uniforms (tests read them).
    var uniforms: [SIMD4<Float>] { bayU }
    var oceanUniforms: [SIMD4<Float>] { oceanU }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: BioluminescentBayShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let b = SkyPipeline(build: { make("bay_vertex", "bay_fragment", storms: $0) }), let k = make("bay_keys_vertex", "bay_keys_fragment") else { return nil }
        sky = s; weather = w; warp = gw; bay = b; keys = k
        sky.verticalFOV = 62
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// The camera faces the pole: south from the southern hemisphere (Crux over the headlands from Melbourne), north from
    /// the northern; an aurora, when there is one, stands over the bay's mouth.
    nonisolated static func viewAzimuth(latitude: Double) -> Double { latitude < 0 ? 180 : 0 }

    /// Where a point of the bay (x 0…1 across, depth 0 near … 1 far) lies on the water: (across, out) in metres.
    nonisolated static func bayPoint(x: Float, depth: Float, tanH: Float) -> SIMD2<Float> {
        let f = nearOut / (1 - 0.9 * min(1, max(-0.2, depth)))
        return SIMD2((x - 0.5) * baySpan(out: f, tanH: tanH), f)
    }

    /// How wide (metres) x 0…1 spans at `out` metres: 85% of the view's width there, so every note's glow is in view.
    nonisolated static func baySpan(out f: Float, tanH: Float) -> Float { 2 * f * tanH * 0.85 }

    private static func ndc(_ v: SIMD3<Float>, _ cam: Camera) -> SIMD2<Float>? {
        let z = simd_dot(v, cam.forward)
        guard z > 1e-4 else { return nil }
        return SIMD2(simd_dot(v, cam.right) / (z * cam.tanH), simd_dot(v, cam.up) / (z * cam.tanV))
    }

    /// The NDC point of a place in the bay (across, out and up from the water in metres; the eye is `cameraHeight` up).
    func screenPoint(across: Float, out: Float, up: Float) -> SIMD2<Float>? {
        guard let cam = camera else { return nil }
        let fwd = simd_normalize(SIMD2(cam.forward.x, cam.forward.y)), rgt = SIMD2(fwd.y, -fwd.x)
        let h = fwd * out + rgt * across
        return Self.ndc(SIMD3(h.x, h.y, up - Self.cameraHeight), cam)
    }

    /// Where a Glow Wake patch lies on screen: its centre and half extents (NDC), from the last frame's camera.
    func screenBox(of patch: GlowPatch) -> (centre: SIMD2<Float>, half: SIMD2<Float>)? {
        guard let cam = camera else { return nil }
        let pt = Self.bayPoint(x: patch.x, depth: patch.depth, tanH: cam.tanH)
        let r = patch.radius * Self.baySpan(out: pt.y, tanH: cam.tanH)
        guard let c = screenPoint(across: pt.x, out: pt.y, up: 0), let side = screenPoint(across: pt.x + r, out: pt.y, up: 0),
              let near = screenPoint(across: pt.x, out: pt.y - r, up: 0), let far = screenPoint(across: pt.x, out: pt.y + r, up: 0)
        else { return nil }
        return (centre: c, half: SIMD2(abs(side.x - c.x), abs(far.y - near.y) / 2))
    }

    func update(_ frame: BayFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        aspect = Float(max(1, size.width) / max(1, size.height))
        let fdt = Float(min(max(dt, 0), 0.1))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let horizon = keyTop + (1 - keyTop) * 0.42
        horizonY = horizon
        let viewAzimuth = Self.viewAzimuth(latitude: s.latitude)
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizon
        // The aurora framed low over the bay's mouth, as the fjord frames it (the sky's band can sit 25–60° up, or
        // overhead near the poles: above this nearly level view).
        var shown = s
        shown.auroraAltitude = AuroraFjordRenderer.framedAltitude(s.auroraAltitude)
        sky.update(shown, quality: quality, size: size, time: Float(frame.time))
        // Sea smoke over the bay, from the waterline out to the horizon (spec §6.4).
        let shore = SkyLayer.waterY(out: Self.waterline, height: Self.cameraHeight, horizonY: horizon, verticalFOV: sky.verticalFOV)
        weather.waterBand = SIMD4(-1, shore, 1, horizon)
        weather.steamCamera = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizon))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        camera = cam
        showWarp = frame.warp != nil
        limiter.gentle = gentle
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizon + (1 - horizon) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        // Light: the sun and the moon (each by its own weight), the night, the mood; the glow through the flash limiter.
        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let day = Float(Self.smooth(-4, 8, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, 0.2 * MoodLook.hazeScale(mood) + s.mist)
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let glowSetting = Float(min(1, max(0, p.number("glow"))))
        let limited = limiter.limit(exposure: exposure, sparkle: min(1, max(0, frame.glowScale)) * glowSetting, dt: dt)
        glowOut = limited.sparkle
        // Glow Wake's brightness already carries the dark (and the rain): the setting and the sparkle scale go on top.
        let glowGain = glowSetting * sparkleScale
        lighthouseOut = min(1, max(0, frame.lighthouseFlash)) * Float(min(1, max(0, p.number("lighthouse")))) * sparkleScale
        let lanternTarget: Float = frame.lanternLit ? Float(min(1, max(0, p.number("lantern")))) : 0
        if lanternPrimed {
            lanternLevel += (lanternTarget - lanternLevel) * (1 - exp(-fdt / 1.2))
        } else {
            lanternLevel = lanternTarget
            lanternPrimed = true
        }
        let t = frame.time
        let wobble = Float(0.6 * sin(t * 5.3) + 0.4 * sin(t * 8.9 + 1.3))
        lanternOut = lanternLevel * (1 + (gentle ? 0.025 : 0.05) * wobble)

        // The swell's small waves (the Ocean layer's, at the bay's scale) and its light.
        oceanU[0] = frame.swellPhases
        oceanU[1] = lights.sun
        oceanU[2] = SIMD4(lights.sunColor, 0)
        oceanU[3] = lights.moon
        oceanU[4] = SIMD4(lights.moonColor, 0.45 * sparkleScale)
        oceanU[5] = SIMD4(frame.swellScale, 0.012 + 0.16 * s.wind, haze, quality == .lite ? 2 : 3)
        oceanU[6] = .zero

        // Glow Wake → the water (metres across and out).
        let tanH = cam.tanH
        for i in Self.patchBase..<Self.uniformCount { bayU[i] = .zero }
        let patches = GlowWake.visible(frame.patches, limit: Self.patchBudget(quality))
        patchCount = patches.count
        for (i, pt) in patches.enumerated() {
            let at = Self.bayPoint(x: pt.x, depth: pt.depth, tanH: tanH)
            bayU[Self.patchBase + i] = SIMD4(at.x, at.y, pt.radius * Self.baySpan(out: at.y, tanH: tanH), min(1, max(0, pt.brightness)))
        }
        let wakes = Array(frame.wakes.suffix(Self.wakeBudget(quality)))
        wakeCount = wakes.count
        for (i, w) in wakes.enumerated() {
            let from = Self.bayPoint(x: w.from.x, depth: w.from.y, tanH: tanH), to = Self.bayPoint(x: w.to.x, depth: w.to.y, tanH: tanH)
            let k = min(1, max(0, w.brightness))
            bayU[Self.wakeBase + i] = SIMD4(from.x, from.y, to.x, to.y)
            bayU[Self.wakeBBase + i] = SIMD4(k, 0.22 + 0.12 * k, 0, 0)
        }
        let darts = Array(frame.darts.suffix(Self.dartBudget(quality)))
        dartCount = darts.count
        for (i, d) in darts.enumerated() {
            let tail = d.start + d.direction * (d.speed * max(0, d.age - 0.12))
            let h = Self.bayPoint(x: d.position.x, depth: d.position.y, tanH: tanH)
            let tl = Self.bayPoint(x: tail.x, depth: tail.y, tanH: tanH)
            bayU[Self.dartBase + i] = SIMD4(h.x, h.y, tl.x, tl.y)
            bayU[Self.dartBBase + i] = SIMD4(min(1, max(0, d.brightness)), 0.12, 0, 0)
        }
        // A chord's pool: wide and mid-bay, bright cyan for major, a deeper teal for minor.
        let pool = frame.pool
        let pc = Self.bayPoint(x: pool.x, depth: 0.35, tanH: tanH)
        bayU[5] = SIMD4(pc.x, pc.y, pool.radius * Self.baySpan(out: pc.y, tanH: tanH), min(1, max(0, pool.strength)))
        let teal = SIMD3<Float>(0.08, 0.6, 0.7) * 0.3, bright = SIMD3<Float>(0.55, 1.0, 0.9) * 0.36
        bayU[6] = SIMD4(teal + (bright - teal) * min(1, max(0, pool.warm)), 0)

        // The boat bobs and rolls with the swell (more in a storm); its lantern hangs on the mast.
        let storm = min(1, max(0, (frame.swellScale - 0.12) / 0.38))
        let ph = frame.swellPhases
        let bob = (0.04 + 0.14 * storm) * sin(ph.x) + 0.02 * sin(ph.z)
        let roll = (0.02 + 0.06 * storm) * sin(ph.y + 0.7)
        let boatAcross = Self.boatOut * tan(Self.boatAzimuth * .pi / 180)
        bayU[7] = SIMD4(boatAcross, Self.boatOut, bob, roll)
        let lx = Self.lanternLocal.x, ly = Self.lanternLocal.y
        let lanternAcross = boatAcross + cos(roll) * lx - sin(roll) * ly, lanternHeight = bob + sin(roll) * lx + cos(roll) * ly
        bayU[8] = SIMD4(lanternAcross, Self.boatOut, lanternHeight, 0)
        let fwd = simd_normalize(SIMD2(cam.forward.x, cam.forward.y)), rgt = SIMD2(fwd.y, -fwd.x)
        let toLantern = fwd * Self.boatOut + rgt * lanternAcross
        let lanternDir = simd_normalize(SIMD3(toLantern.x, toLantern.y, lanternHeight - Self.cameraHeight))
        let pillarRadius: Float = 0.45 * .pi / 180   // a lamp's narrow column (the profile is 1.5× this wide)
        bayU[9] = SIMD4(lanternDir, pillarRadius)
        // The lighthouse on the far point.
        let lampAz = Self.lighthouseAzimuth * .pi / 180, lampAlt = Self.lighthouseAltitude * .pi / 180
        bayU[10] = SIMD4(lampAz, lampAlt, 0.0022, 0)
        let a = Float(viewAzimuth * .pi / 180) + lampAz
        let lampDir = SIMD3<Float>(sin(a) * cos(lampAlt), cos(a) * cos(lampAlt), sin(lampAlt))
        bayU[11] = SIMD4(lampDir, 0)

        // The header: the keys, the eye, the night, the glow line and its 0.15 Hz wash, the lights, the weather.
        let washPhase = Float((frame.time * 0.15).truncatingRemainder(dividingBy: 1))
        bayU[0] = SIMD4(keyTop, aspect, Self.cameraHeight, night)
        bayU[1] = SIMD4(glowOut, washPhase, min(1, max(0, frame.washFront)), haze)
        bayU[2] = SIMD4(lanternOut, lighthouseOut, s.wind, s.wetness)
        bayU[3] = SIMD4(Self.waterline, Float(patchCount), Float(wakeCount), Float(dartCount))
        bayU[4] = SIMD4(day, min(1, max(0, s.pillar)), glowGain, quality == .lite ? 2 : 3)

        waterlineY = screenPoint(across: 0, out: Self.waterline, up: 0)?.y ?? keyTop
        lanternScreen = Self.ndc(lanternDir, cam) ?? SIMD2(0, 0)
        lighthouseScreen = Self.ndc(lampDir, cam) ?? SIMD2(0, 0)

        // Keys: dark glass along the sand, plankton cyan where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let light = max(lights.sun.w, 0.5 * lights.moon.w)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.7, bloomThreshold: 0.8,
            dof: 0, focusDepth: 0.2,   // no depth of field: the reflected stars stay sharp
            grade: 0, grain: 0.02, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.06 * day - 0.06 * night,
            time: Float(frame.time.truncatingRemainder(dividingBy: 3600)), quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        let skyU = sky.uniforms
        e.setRenderPipelineState(bay.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        bayU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
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
