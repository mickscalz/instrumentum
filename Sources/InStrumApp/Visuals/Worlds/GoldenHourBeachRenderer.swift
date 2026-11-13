import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Golden Hour Beach: the Living Sky, a headland, the Ocean layer with breaking waves, the wash on the
/// sand, Tide Lines, palms, weather and an amber keyboard.
@MainActor
final class GoldenHourBeachRenderer: ThemeRenderer {
    /// Tide lines sent to the GPU (fewer on Smooth).
    static func lineBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : TideLines.cap }
    /// Shore geometry in metres (matches the shader's constants).
    static let waterline: Float = 11, wetBand: Float = 5, breakLine: Float = 22, waveSpeed: Float = 5
    /// White water rushing in from the break line to the shore (m/s; matches the shader's kBoreSpeed).
    static let boreSpeed: Float = 4.4
    static let cameraHeight: Float = 2.0

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let beach: SkyPipeline
    private let keys, sparks, sprites: MTLRenderPipelineState
    private var beachU = [SIMD4<Float>](repeating: .zero, count: GoldenHourBeachRenderer.uniformCount)
    /// Fire & Neon §5.5: the fireworks' and the green flash's streaks (two float4s each, in a ring of three buffers made
    /// once) and the sprites (the gulls and the kite over the sky, the dolphins on the sea).
    private var sparkInstances: [SIMD4<Float>] = []
    private var skySprites: [BeachSprite] = []
    /// The bursts' smoke (drawn over the sky before the stars, so they burn in front of it).
    private var smokeSprites: [BeachSprite] = []
    private var seaSprites: [BeachSprite] = []
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private var view = SIMD4<Float>(16.0 / 9, 2.0 / 720, 0, 0)
    private var primed = false
    /// Under gentle visuals the exposure only ever eases up (never a flash).
    private var gentleExposure = GentleExposure()
    private var burstGlow: Float = 0
    private var oceanU = [SIMD4<Float>](repeating: .zero, count: 7)   // the beach doesn't travel: travel stays 0
    private var keyInstances: [KeyInstance] = []
    private var aspect: Float = 16.0 / 9
    private var viewAzimuth: Double?
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    private(set) var lineCount = 0
    /// The glitter after the flash limiter (gentle visuals halve it).
    private(set) var glitterOut: Float = 0
    /// How strongly spray glints on the foam (gentle visuals should calm it).
    private(set) var sprayOut: Float = 1
    /// The shader's uniforms (tests read them).
    var oceanUniforms: [SIMD4<Float>] { oceanU }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }
    /// Excitement as drawn (tests read them): the firework stars and every streak, the bursts mirrored by the water, the
    /// gulls, dolphins and kite, the green flash, the exposure after the flash limiter, the buffers made.
    private(set) var starCount = 0
    private(set) var sparkCount = 0
    private(set) var burstsReflected = 0
    private(set) var gullsDrawn = 0
    private(set) var dolphinsDrawn = 0
    private(set) var kiteDrawn = false
    private(set) var greenFlashOut: Float = 0
    private(set) var exposureOut: Float = 1
    private(set) var bufferAllocations = 0
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }

    /// BeachU's rows: 7, the 48 lines' two rows, then the fireworks' 9 bursts' two rows.
    nonisolated static let fireworkRow = 7 + 2 * TideLines.cap, fireworkRows = 9
    nonisolated static let uniformCount = fireworkRow + 2 * fireworkRows
    /// Every streak at once: each shell's stars and its climbing comet, and the green flash's two.
    nonisolated static let sparkCapacity = GoldenHourBeachModel.shellCount * (FireworkShell.mostStars + 1) + 2

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }
    /// The shader's BeachSprite.
    private struct BeachSprite { var rect: SIMD4<Float>; var local: SIMD4<Float>; var info: SIMD4<Float>; var tint: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: GoldenHourBeachShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, program: SkyProgram = .plain) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, program: program)
            d.fragmentFunction = lib.skyFunction(f, program: program)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        func blended(_ v: String, _ f: String, additive: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = additive ? .zero : .one
            c.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let b = SkyPipeline(program: { make("beach_vertex", "beach_fragment", program: $0) }), let k = make("beach_keys_vertex", "beach_keys_fragment"),
              let sp = blended("beach_spark_vertex", "beach_spark_fragment", additive: true),
              let sr = blended("beach_sprite_vertex", "beach_sprite_fragment", additive: false) else { return nil }
        let bytes = Self.sparkCapacity * 2 * MemoryLayout<SIMD4<Float>>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(buf)
        }
        sky = s; weather = w; warp = gw; beach = b; keys = k; sparks = sp; sprites = sr
        ring = buffers
        bufferAllocations = buffers.count
        sparkInstances.reserveCapacity(Self.sparkCapacity * 2)
        sky.verticalFOV = 58
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// Face the low sun over the sea (a little to its left), else the moon while it's up, else out to sea.
    static func targetAzimuth(_ s: SkyState) -> Double {
        if s.sun.altitude > -12, s.sun.altitude < 25 { return s.sun.azimuth - 8 }
        if s.moon.altitude > -5 { return s.moon.azimuth - 8 }
        return SkyLayer.defaultViewAzimuth(latitude: s.latitude)
    }

    /// Where a line in the sand lies (x 0…1 across the keyboard, y 0 waterline … 1 top of the wet sand).
    static func shorePoint(x: Float, y: Float, tanH: Float) -> (s: Float, f: Float) {
        let f = waterline - min(1, max(0, y)) * wetBand
        return ((x - 0.5) * 2 * f * tanH * 0.85, f)
    }

    func update(_ frame: BeachFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))

        let target = Self.targetAzimuth(s)
        if let az = viewAzimuth {
            let diff = (target - az + 540).truncatingRemainder(dividingBy: 360) - 180
            viewAzimuth = az + diff * (1 - exp(-min(dt, 0.1) / 4))
        } else {
            viewAzimuth = target
        }
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let horizonY = keyTop + (1 - keyTop) * 0.4
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizonY
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        // Sea smoke over the sea, from the waterline out to the horizon (spec §6.4).
        let shore = SkyLayer.waterY(out: Self.waterline, height: Self.cameraHeight, horizonY: horizonY, verticalFOV: sky.verticalFOV)
        weather.waterBand = SIMD4(-1, shore, 1, horizonY)
        weather.steamCamera = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizonY))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        showWarp = frame.warp != nil
        limiter.gentle = gentle
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (1 - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        let lights = OceanLight.lights(s)
        let night = Float(1 - Self.smooth(-12, -3, s.sun.altitude))
        let mood = frame.mood
        let haze = min(1, Float(p.number("haze")) * MoodLook.hazeScale(mood) + s.mist)
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        // The fireworks' bursts light the beach through the flash limiter; under gentle visuals only ever a glow, eased in.
        let request = Self.unit(frame.flashRequest)
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        if gentle {
            burstGlow += (min(0.12, 0.4 * request) - burstGlow) * (dt == 0 ? 1 : 1 - exp(-fdt / 0.8))
        } else {
            burstGlow = 0.9 * request
        }
        if !primed {
            // The limiter starts from black: settle it on the scene's own exposure first, so arriving is never a flash.
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: exposure, sparkle: 1, dt: 1) }
        }
        let limited = limiter.limit(exposure: gentleExposure.step(exposure * (1 + burstGlow), gentle: gentle, dt: dt), sparkle: Float(p.number("glitter")) * (0.25 + 0.75 * frame.glitter), dt: dt)
        exposureOut = limited.exposure
        glitterOut = limited.sparkle

        // Tide lines → sand coordinates.
        let lines = TideLines.visible(frame.lines, limit: Self.lineBudget(quality))
        lineCount = lines.count
        for i in 0..<TideLines.cap { beachU[7 + i] = .zero; beachU[7 + TideLines.cap + i] = .zero }
        for (i, l) in lines.enumerated() {
            let pt = Self.shorePoint(x: l.x, y: l.y, tanH: cam.tanH)
            // Traced left to right like a finger drawing it: the stroke grows from its left end.
            let fullHalf = l.length * 0.5 * 2 * pt.f * cam.tanH * 0.85
            let halfLength = fullHalf * l.drawn
            let glow = l.strength * min(1, 0.3 + l.drawn) * (1 - l.washed) * (0.55 + 0.45 * sparkleScale)
            beachU[7 + i] = SIMD4(pt.s - fullHalf + halfLength, pt.f, halfLength, glow)
            beachU[7 + TideLines.cap + i] = SIMD4(l.hue, 0, 0, 0)
        }
        // The next crests (metres beyond the break line) and the white water from the last break.
        var crests = [SIMD4<Float>](repeating: .zero, count: 3)
        for (i, w) in frame.upcoming.prefix(3).enumerated() {
            let ahead = Float(w.breakTime - frame.swellTime) * Self.waveSpeed
            crests[i] = SIMD4(ahead, w.strength, 0, 0)
        }
        // The last two breaks: how long ago and how strong (the shader rolls their white water in from the break
        // line, the older one still fading as the newer arrives).
        var since: Float = -1, lastStrength: Float = 0, since2: Float = -1, strength2: Float = 0
        let broken = frame.recent.filter { frame.swellTime >= $0.breakTime }
        if let last = broken.last { since = Float(min(60, frame.swellTime - last.breakTime)); lastStrength = last.strength }
        if broken.count >= 2 {
            let before = broken[broken.count - 2]
            since2 = Float(min(60, frame.swellTime - before.breakTime)); strength2 = before.strength
        }
        sprayOut = sparkleScale
        beachU[0] = SIMD4(keyTop, sprayOut, limited.sparkle, haze)
        beachU[1] = SIMD4(Float(p.number("palms")), s.wind, Float(lines.count), night)
        beachU[2] = SIMD4(aspect, Self.cameraHeight, since, lastStrength)
        beachU[3] = SIMD4(frame.washFront, frame.foam * sparkleScale, since2, strength2)
        crests[0].z = s.wetness   // after the rain: the whole beach is wet
        beachU[4] = crests[0]; beachU[5] = crests[1]; beachU[6] = crests[2]

        oceanU[0] = frame.swellPhases
        oceanU[1] = lights.sun
        oceanU[2] = SIMD4(lights.sunColor, Float(lights.sun.w) * Float(Self.smooth(15, 2, s.sun.altitude)))
        oceanU[3] = lights.moon
        oceanU[4] = SIMD4(lights.moonColor, limited.sparkle)
        oceanU[5] = SIMD4(frame.swellScale, 0.06 + 0.25 * s.wind, haze, quality == .lite ? 2 : 3)

        buildExcitement(frame, cam: cam, sunLight: lights.sun.w, gentle: gentle, height: Float(max(1, size.height)))

        // Keys: dark wood along the sand, golden amber where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let light = max(lights.sun.w, lights.moon.w)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.6, bloomThreshold: 0.85,
            dof: quality == .lite ? 0 : 0.2, focusDepth: 0.14,
            grade: 0, grain: 0.02, vignette: 0.25,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.08 * (1 - night),
            time: time, quality: quality)
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    nonisolated static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// A small integer hash to 0…1.
    nonisolated static func hash01(_ x: UInt32) -> Float {
        var h = x &* 0x9E37_79B1
        h ^= h >> 15
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        return Float(h & 0xFFFF) / 65535
    }

    /// A firework's colour (brightest channel 1): a vivid hue, or silver for a negative one.
    nonisolated static func fireworkColour(_ hue: Float) -> SIMD3<Float> {
        guard hue >= 0, hue.isFinite else { return SIMD3(1, 0.95, 0.88) }
        let h = hue - floor(hue)
        let k = SIMD3<Float>(abs(h * 6 - 3) - 1, 2 - abs(h * 6 - 2), 2 - abs(h * 6 - 4))
        let rgb = simd_clamp(k, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return rgb + (SIMD3<Float>(repeating: 1) - rgb) * 0.15
    }

    /// Star `i` of `n` leaving a burst: an even spread over the sphere (turned by the shell's seed), and how fast it goes
    /// against the shell's own speed (0.85…1.15).
    nonisolated static func starDirection(_ i: Int, of n: Int, seed: UInt32) -> (dir: SIMD3<Float>, pace: Float, hash: Float) {
        let count = Float(max(n, 1))
        let z = 1 - 2 * (Float(i) + 0.5) / count
        let r = max(0, 1 - z * z).squareRoot()
        let h = hash01(UInt32(truncatingIfNeeded: i) &* 2_654_435_761 ^ seed)
        let phi = Float(i) * 2.399963 + Float(seed % 1000) * 0.00628
        return (SIMD3(r * cos(phi), r * sin(phi), z), 0.85 + 0.3 * h, h)
    }

    /// Where a star is `t` s after the burst (metres in the beach's frame): out along `dir` against the air's drag, and
    /// sinking toward its terminal fall as the burst slows (a burning star falls at 15–25 m/s: a willow's heavy embers
    /// fastest), so every burst droops into falling embers.
    nonisolated static func starPoint(_ sh: FireworkShell, dir: SIMD3<Float>, pace: Float, t: Float) -> SIMD3<Float> {
        let tt = max(0, t)
        let drag = max(0.2, sh.drag)
        let out = (1 - exp(-drag * tt)) / drag
        let fall: Float = sh.kind == .willow ? 24 : 15
        let sag = fall * (tt - out)
        return sh.burst + dir * (sh.speed * pace * out) - SIMD3<Float>(0, 0, sag)
    }

    /// The fireworks, the bursts' rows for the water, the gulls, the dolphins, the kite and the green flash.
    private func buildExcitement(_ frame: BeachFrame, cam: SkyLayer.Camera, sunLight: Float, gentle: Bool, height: Float) {
        let s = frame.sky
        view = SIMD4(cam.tanH / cam.tanV, 2 / height, 0, 0)
        let fwd2 = simd_normalize(SIMD2<Float>(cam.forward.x, cam.forward.y))
        let rgt2 = SIMD2<Float>(fwd2.y, -fwd2.x)
        let eye = Self.cameraHeight
        func world(_ q: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(rgt2.x * q.x + fwd2.x * q.y, rgt2.y * q.x + fwd2.y * q.y, q.z - eye)
        }
        func project(_ q: SIMD3<Float>) -> SIMD3<Float>? {
            let w = world(q)
            let z = simd_dot(w, cam.forward)
            guard z > 1 else { return nil }
            return SIMD3(simd_dot(w, cam.right) / (z * cam.tanH), simd_dot(w, cam.up) / (z * cam.tanV), z)
        }
        func projectDirection(_ d: SIMD3<Float>) -> SIMD2<Float>? {
            let z = simd_dot(d, cam.forward)
            guard z > 1e-3 else { return nil }
            return SIMD2(simd_dot(d, cam.right) / (z * cam.tanH), simd_dot(d, cam.up) / (z * cam.tanV))
        }
        let lightScale: Float = gentle ? 0.6 : 1
        // Daylight fireworks are pale and smoky (their colour all but lost against the bright sky); toward dusk they glow.
        let day = Float(Self.smooth(-3, 10, s.sun.altitude))
        let glowScale: Float = 1 + 0.5 * (1 - day)
        let pale = SIMD3<Float>(1.0, 0.95, 0.86)
        sparkInstances.removeAll(keepingCapacity: true)
        smokeSprites.removeAll(keepingCapacity: true)
        func spark(_ a: SIMD2<Float>, _ b: SIMD2<Float>, colour: SIMD3<Float>, radius: Float) {
            guard sparkInstances.count + 2 <= Self.sparkCapacity * 2 else { return }
            guard max(abs(a.x), abs(b.x)) < 1.3, max(abs(a.y), abs(b.y)) < 1.3 else { return }
            sparkInstances.append(SIMD4(a.x, a.y, b.x, b.y))
            sparkInstances.append(SIMD4(colour, radius))
        }

        // The fireworks: climbing comets, then the stars; each burst a row for the water's reflections.
        for i in 0..<(2 * Self.fireworkRows) { beachU[Self.fireworkRow + i] = .zero }
        var rows = 0, stars = 0
        for sh in frame.fireworks {
            if sh.sinceBurst < 0 {
                let rise = max(sh.rise, 1e-3)
                func climb(_ a: Float) -> SIMD3<Float> {
                    let x = min(1, max(0, a / rise))
                    return sh.launch + (sh.burst - sh.launch) * (1 - (1 - x) * (1 - x))
                }
                // The shell climbing on a faint trail of sparks (a long dim tail, a brighter head).
                if let p0 = project(climb(sh.age - 0.35)), let p1 = project(climb(sh.age)) {
                    spark(SIMD2(p0.x, p0.y), SIMD2(p1.x, p1.y), colour: SIMD3<Float>(1.0, 0.72, 0.38) * (0.45 * lightScale * glowScale), radius: 0.8)
                }
                continue
            }
            let t = sh.sinceBurst, u = min(1, t / max(sh.life, 1e-3))
            let trail: Float
            switch sh.kind {
            case .peony: trail = 0.26
            case .chrysanthemum: trail = 0.3
            case .willow: trail = 0.6
            }
            let c0 = Self.fireworkColour(sh.hue), c1 = Self.fireworkColour(sh.hue2)
            let vivid = c0 + (c1 - c0) * u
            let colour = vivid + (pale - vivid) * (0.6 * day)
            let on = min(1, t / 0.12)
            let base = 5 * sh.brightness * on * lightScale * glowScale
            for k in 0..<min(sh.stars, FireworkShell.mostStars) {
                let st = Self.starDirection(k, of: sh.stars, seed: sh.seed)
                let fade: Float
                switch sh.kind {
                case .peony: fade = (1 - u) * (1 - u).squareRoot()
                case .chrysanthemum: fade = (1 - u) * (u > 0.65 ? 0.55 + 0.45 * sin(st.hash * 40 + t * 38) : 1)
                case .willow: fade = (1 - u) * (1 - 0.3 * u)
                }
                guard fade > 0.01 else { continue }
                guard let p1 = project(Self.starPoint(sh, dir: st.dir, pace: st.pace, t: t)),
                      let p0 = project(Self.starPoint(sh, dir: st.dir, pace: st.pace, t: t - trail)) else { continue }
                spark(SIMD2(p0.x, p0.y), SIMD2(p1.x, p1.y), colour: colour * (base * fade), radius: 1.2)
                stars += 1
            }
            // Its smoke: a soft ball where it burst, growing and drifting downwind, pale grey in daylight (where it is
            // most of what you see) and faint at dusk, lit from inside by the burst for a moment.
            if let c = project(sh.burst + SIMD3<Float>(6 * t * (0.3 + s.wind), 0, 2 * t)) {
                let spread = sh.speed * (1 - exp(-max(0.2, sh.drag) * t)) / max(0.2, sh.drag)
                let radius = (0.35 + 0.45 * min(1, t / 1.5)) * spread + 10
                let hx = radius / (c.z * cam.tanH), hy = radius / (c.z * cam.tanV)
                let thick = (0.18 + 0.5 * day) * min(1, t / 0.4) * (1 - u * u) * lightScale
                // Smoke is grey against the sky's colour: by day a little darker than the bright sky beside it, sunlit on
                // top; at dusk dim.
                let grey = simd_dot(s.horizon, SIMD3<Float>(0.3, 0.5, 0.2))
                let skyLit: SIMD3<Float> = (s.horizon * 0.35 + SIMD3<Float>(repeating: grey * 0.65)) * (0.5 + 0.3 * day)
                let sunAmount: Float = Float(sunLight) * day
                let sunLit = SIMD3<Float>(0.15 * sunAmount, 0.14 * sunAmount, 0.12 * sunAmount)
                let flashLit: SIMD3<Float> = vivid * (0.25 * sh.brightness * exp(-t / 0.5) * glowScale * lightScale)
                let lit: SIMD3<Float> = skyLit + sunLit + flashLit
                smokeSprites.append(BeachSprite(rect: SIMD4(c.x - hx, c.y - hy, c.x + hx, c.y + hy), local: SIMD4(-1, -1, 1, 1),
                                                info: SIMD4(3, t + Float(sh.seed % 97), thick, 1), tint: SIMD4(lit, 0)))
            }
            if rows < Self.fireworkRows {
                let w = world(sh.burst)
                let dist = max(1, simd_length(w))
                let spread = sh.speed * (1 - exp(-max(0.2, sh.drag) * t)) / max(0.2, sh.drag)
                let light = 0.35 * sh.brightness * on * (1 - u) * lightScale
                beachU[Self.fireworkRow + rows] = SIMD4(w / dist, max(0.004, spread / dist))
                beachU[Self.fireworkRow + Self.fireworkRows + rows] = SIMD4(colour * light, 1)
                rows += 1
            }
        }
        starCount = stars
        burstsReflected = rows

        // The green flash: the sun's last (or first) sliver turning green for a breath, and a green spot over it.
        let gf = Self.unit(frame.greenFlash) * lightScale
        greenFlashOut = 0
        if gf > 0.001 {
            let r = 0.9 * Double(s.sunSize.isFinite ? min(3, max(0.5, s.sunSize)) : 1)
            let limb = SkyLayer.enu(SkyDirection(azimuth: s.sun.azimuth, altitude: s.sun.altitude + 0.95 * r))
            let left = SkyLayer.enu(SkyDirection(azimuth: s.sun.azimuth - 0.45 * r, altitude: s.sun.altitude + 0.88 * r))
            let right = SkyLayer.enu(SkyDirection(azimuth: s.sun.azimuth + 0.45 * r, altitude: s.sun.altitude + 0.88 * r))
            let spot = SkyLayer.enu(SkyDirection(azimuth: s.sun.azimuth, altitude: s.sun.altitude + 1.2 * r))
            if s.sun.altitude + r > -0.05, let a = projectDirection(left), let b = projectDirection(right),
               let c = projectDirection(limb), let d = projectDirection(spot) {
                let green = SIMD3<Float>(0.25, 1.0, 0.45)
                spark(a, b, colour: green * (4 * gf), radius: 1.5)
                spark(c, d, colour: green * (1.6 * gf), radius: 2.4)
                greenFlashOut = gf
            }
        }
        sparkCount = sparkInstances.count / 2

        // Sprites: the gulls and the kite over the sky, the dolphins on the sea.
        skySprites.removeAll(keepingCapacity: true)
        seaSprites.removeAll(keepingCapacity: true)
        let sunHigh = Float(Self.smooth(8, 30, s.sun.altitude))
        let ambient = s.horizon * 0.08 + s.zenith * 0.05
        var gullCount = 0
        for g in frame.gulls {
            guard let at = project(g.position) else { continue }
            let half = 0.65 / at.z * 1.25
            let hx = half / cam.tanH, hy = half / cam.tanV
            let tint = ambient + SIMD3<Float>(0.3, 0.3, 0.32) * sunHigh * sunLight
            skySprites.append(BeachSprite(rect: SIMD4(at.x - hx, at.y - hy, at.x + hx, at.y + hy), local: SIMD4(-1.25, -1.25, 1.25, 1.25),
                                          info: SIMD4(0, g.wing, 0, Self.unit(g.alpha)), tint: SIMD4(tint, 0)))
            gullCount += 1
        }
        gullsDrawn = gullCount
        kiteDrawn = false
        if let k = frame.kite, let at = project(k.position) {
            let mx = 1 / (at.z * cam.tanH), my = 1 / (at.z * cam.tanV)
            let lo = SIMD2<Float>(-1.5, -4.4), hi = SIMD2<Float>(1.5, 1.1)
            let backlight = sunLight * Float(1 - Self.smooth(20, 45, s.sun.altitude))
            skySprites.append(BeachSprite(rect: SIMD4(at.x + lo.x * mx, at.y + lo.y * my, at.x + hi.x * mx, at.y + hi.y * my),
                                          local: SIMD4(lo.x, lo.y, hi.x, hi.y), info: SIMD4(2, k.tail, k.tilt, Self.unit(k.alpha)),
                                          tint: SIMD4(s.horizon * 0.25 + s.zenith * 0.1, backlight)))
            kiteDrawn = k.alpha > 0.01
        }
        var dolphinCount = 0
        for dph in frame.dolphins {
            let unitM = max(0.5, dph.length) / 2.25   // metres per unit of the shader's dolphin
            guard let at = project(dph.position + SIMD3<Float>(0, 0, 0.22 * unitM)) else { continue }
            let mx = unitM / (at.z * cam.tanH), my = unitM / (at.z * cam.tanV)
            let flip: Float = dph.heading < 0 ? -1 : 1
            let rim = sunLight * 0.6
            seaSprites.append(BeachSprite(rect: SIMD4(at.x - 1.6 * mx, at.y - 0.5 * my, at.x + 1.6 * mx, at.y + 0.95 * my),
                                          local: SIMD4(-1.6 * flip, -0.5, 1.6 * flip, 0.95), info: SIMD4(1, dph.roll, 0, 1),
                                          tint: SIMD4(SIMD3<Float>(0.02, 0.025, 0.03) + ambient * 0.6, rim)))
            dolphinCount += 1
        }
        dolphinsDrawn = dolphinCount
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)   // the supercell's impostor, before the frame's passes
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        // The fireworks and the green flash over the sky, and the gulls and the kite: the headland and the palms then
        // draw over them where they stand in front.
        if !smokeSprites.isEmpty {
            e.setRenderPipelineState(sprites)
            smokeSprites.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: smokeSprites.count)
        }
        if sparkCount > 0, !ring.isEmpty {
            slot = (slot + 1) % ring.count
            let buf = ring[slot]
            let bytes = sparkCount * 2 * MemoryLayout<SIMD4<Float>>.stride
            sparkInstances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            var vw = view
            e.setRenderPipelineState(sparks)
            e.setVertexBuffer(buf, offset: 0, index: 0)
            e.setVertexBytes(&vw, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: sparkCount)
        }
        if !skySprites.isEmpty {
            e.setRenderPipelineState(sprites)
            skySprites.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: skySprites.count)
        }

        let skyU = sky.uniforms
        e.setRenderPipelineState(beach.state(sky.program))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        beachU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        oceanU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !seaSprites.isEmpty {
            e.setRenderPipelineState(sprites)
            seaSprites.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: seaSprites.count)
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
