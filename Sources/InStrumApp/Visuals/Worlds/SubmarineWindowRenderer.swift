import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Submarine Window (spec §8.1, §8.2): the sea at the chosen depth through a round porthole in a thick brass ring
/// (the Window Kit's acrylic, its rim fogging with the cold), Deep Lights' creatures, shoals, siphonophores and bubbles
/// with the marine snow in the lamps, small fish in the shallows (Galaxy Warp through the glass when chosen), then the
/// cabin in silhouette and soft light: painted steel, cables, a padded console edge, the brass depth gauge reading the
/// Depth, the sonar screen with your notes' blips, and a row of backlit console buttons for the keys. By day the cabin is
/// a dim, cool white; at night it turns to red night lighting.
///
/// Every brightness of the living light goes through a `FlashLimiter` (the window's lit area, so a field of creatures
/// blinking on the arp's grid can never strobe), and gentle visuals halve it.
///
/// Excitement (Fire & Neon spec §5.5): the whale passing is drawn in the sea pass (a humpback's silhouette, its long pale
/// fins and belly catching the lamps, melting into the blue with distance); tension dims the lamps and the light from
/// above; the far lights of Energy's traffic, an anglerfish's lure and a squid's cloud of light are sprites (the cloud's
/// light counts with the living light's, through its limiter); a far sub's sonar is a contact echoing on the screen and
/// its two lights crossing far off. Three uniform rows before the blips.
@MainActor
final class SubmarineWindowRenderer: ThemeRenderer {
    /// SubU's float4 rows (the MSL struct's size / 16): 12 rows, the whale's two, the sonar contact, and the 24 blips.
    nonisolated static let rowWhale = 12, rowWhaleB = 13, rowContact = 14
    nonisolated static let uniformCount = 39
    nonisolated static let blipBase = 15
    /// The squid's cloud of light: this many motes.
    nonisolated static let squidMotes = 36
    /// Sprites a frame at most (each 32 bytes, in a ring of three buffers made once): the marine snow (400 on Ultra),
    /// 48 creatures, 4 shoals of 12, 2 siphonophores of 20 bells, 6 bubble streams and the fish, with room to spare.
    nonisolated static let spriteCapacity = 1024
    nonisolated static let bubblesPerStream = 14
    nonisolated static let fishCount = 9
    /// Creatures drawn at most (Smooth draws the 24 held and brightest).
    nonisolated static func creatureBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : DeepLights.cap }
    /// The view's half angle at the glass's rim (degrees), and the camera's pitch in the shallows and deep down.
    nonisolated static let halfView: Float = 34
    nonisolated static let shallowPitch: Float = 16, deepPitch: Float = 5
    /// The view faces this many degrees to the left of the sun, so its shafts slant in from the right.
    nonisolated static let sunOffset: Double = 15

    /// Where everything sits on a screen of `aspect` (w/h) with the keys up to `keyTop` (NDC y): the porthole a little
    /// left of centre at about 70% of the height, its brass ring, the gauge at the upper right and the sonar under it,
    /// the padded console edge above the keys. Radii are in NDC-y units (screen x × aspect, y).
    struct Layout: Equatable {
        var centre: SIMD2<Float>
        var radius: Float
        var ring: Float
        var gauge: SIMD2<Float>
        var gaugeRadius: Float
        var sonar: SIMD2<Float>
        var sonarRadius: Float
        var consoleTop: Float
        /// The ring's outside (NDC-y units).
        var outer: Float { radius + ring }
        /// The porthole for the Window Kit (its frame width in NDC x).
        func spec(aspect: Float) -> WindowSpec {
            WindowSpec.porthole(centre: centre, height: 2 * radius, aspect: aspect, frameWidth: ring / aspect)
        }
    }

    nonisolated static func layout(aspect: Float, keyTop: Float) -> Layout {
        let a: Float = aspect.isFinite ? min(max(aspect, 0.3), 5) : 16.0 / 9
        let keys: Float = keyTop.isFinite ? min(max(keyTop, -1), -0.3) : -0.76
        let consoleTop = keys + 0.075
        let top: Float = 0.95, bottom = consoleTop + 0.04
        let ring: Float = 0.06
        var radius = max(0.2, min(0.7, (top - bottom) / 2 - ring))
        // The instruments' column: the gauge (its bezel 1.18× its face) over the sonar (1.14×), scaled to fit.
        let gaugeR: Float = 0.15, sonarR: Float = 0.19
        let columnW: Float = 2 * max(gaugeR * 1.18, sonarR * 1.14) + 0.04
        let margin: Float = 0.08
        let avail = 2 * a - 3 * margin
        var k: Float = 1
        if 2 * (radius + ring) + columnW > avail {
            k = max(0.5, (avail - 2 * (radius + ring)) / columnW)
            if 2 * (radius + ring) + columnW * k > avail { radius = max(0.15, (avail - columnW * k) / 2 - ring) }
        }
        let outer = radius + ring
        let left = -a + margin, right = a - margin - columnW * k - margin
        var cx = (left + right) / 2
        cx = min(max(cx, left + outer), max(left + outer, right - outer))
        let cy = (top + bottom) / 2
        var colX = (cx + outer + a) / 2
        colX = min(colX, a - 0.04 - columnW * k / 2)
        colX = max(colX, cx + outer + 0.02 + columnW * k / 2)
        let gr = gaugeR * k, sr = sonarR * k
        let gy = top - 0.06 - gr * 1.18
        let below: Float = bottom + sr * 1.14 + 0.02
        let under: Float = gy - gr * 1.18 - 0.12 * k - sr * 1.14
        let sy = max(below, under)
        return Layout(centre: SIMD2(cx / a, cy), radius: radius, ring: ring, gauge: SIMD2(colX / a, gy), gaugeRadius: gr,
                      sonar: SIMD2(colX / a, sy), sonarRadius: sr, consoleTop: consoleTop)
    }

    /// The outside lamps' beams at a point of the porthole's disc (radius 1, y up): the shader's `subLampBeams`, so the
    /// marine snow and the creatures they reach are lit as the water is.
    nonisolated static func lampLight(_ q: SIMD2<Float>) -> Float {
        var sum: Float = 0
        for i in 0..<2 {
            let side: Float = i == 0 ? -1 : 1
            let src = SIMD2<Float>(side * 0.92, -1.08)
            let axis = simd_normalize(SIMD2<Float>(-side * 0.42, 1))
            let v = q - src
            let along = simd_dot(v, axis)
            guard along > 0 else { continue }
            let across = simd_dot(v, SIMD2(axis.y, -axis.x))
            let spread = 0.06 + 0.22 * along
            sum += exp(-(across * across) / (spread * spread)) * exp(-0.85 * along) * smooth(0, 0.25, along)
        }
        return sum
    }

    /// The sea's own light through the glass (rgb, display-referred: what the shader's water reads at the porthole's
    /// middle, level): the Underwater Kit's water colour at `metres` under `surface`, through the eye's adaptation.
    nonisolated static func seaGlow(surface: SIMD3<Float>, metres: Float, nightGain: Float) -> SIMD3<Float> {
        let m = metres.isFinite ? max(0, metres) : 0
        let absorb = SIMD3<Float>(exp(-0.35 * m), exp(-0.07 * m), exp(-0.03 * m))
        let tint = SIMD3<Float>(0.08, 0.6, 0.75)
        let adapt = exp(0.0229 * min(m, 400))
        let g = surface * absorb * tint * adapt * nightGain
        return SIMD3(min(g.x, 2), min(g.y, 2), min(g.z, 2))
    }

    /// A creature's radius (NDC-y units, for a porthole of radius 0.7): a jelly large, a comb jelly middling, a speck
    /// tiny; each grows with its velocity's size (0.35…1).
    nonisolated static func creatureRadius(_ c: DeepCreature) -> Float {
        let s = min(max(c.size.isFinite ? c.size : 0.6, 0), 1)
        switch c.kind {
        case .jelly: return 0.075 + 0.07 * s
        case .combJelly: return 0.04 + 0.035 * s
        case .speck: return 0.014 + 0.012 * s
        }
    }

    /// How much of the window a creature's light covers when fully lit, for the flash limiter: its sprite's area as a
    /// share of the glass's, × how much of that is lit (a jelly's rim and margin, a comb jelly's rows, a speck's halo),
    /// × 10, so 10% of the glass swinging fully is 1.
    nonisolated static func flashWeight(_ c: DeepCreature, glassRadius: Float) -> Float {
        let rd = creatureRadius(c) * (glassRadius / 0.7) / max(glassRadius, 1e-3)
        let lit: Float
        switch c.kind {
        case .jelly: lit = 0.35
        case .combJelly: lit = 0.3
        case .speck: lit = 0.25
        }
        return rd * rd * 4 / Float.pi * lit * 10
    }

    private let sky: SkyLayer
    let warp: WarpLayer
    let glass: WindowGlassLayer
    private var showWarp = false
    private let sea: SkyPipeline
    private let sprites, cabin, keys: MTLRenderPipelineState
    private(set) var uniforms = [SIMD4<Float>](repeating: .zero, count: uniformCount)

    /// A sprite: position (NDC), radius (NDC-y), kind + lamp light; colour (rgb), a parameter.
    struct Sprite: Equatable { var a: SIMD4<Float>; var b: SIMD4<Float> }
    enum Kind: Float {
        case snow = 0, jelly = 1, comb = 2, speck = 3, photophore = 4, bell = 5, bubble = 6, fish = 7
    }
    private(set) var spriteList: [Sprite] = []
    private var ring: [MTLBuffer] = []
    private var slot = 0
    /// Buffers made for the sprites: three, once, at the start.
    private(set) var bufferAllocations = 0

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }
    private var keyInstances: [KeyInstance] = []
    private var limiter = FlashLimiter()
    /// The living light's own limiter: it sees how much of the window is lit.
    private var deepLimiter = FlashLimiter()
    private var quality: QualityLevel = .high
    private(set) var post = PostSettings()

    /// This frame's: the layout; the living light's level as the limiter saw it, and the gain it allowed (× the gentle
    /// halving): every creature, shoal and siphonophore is drawn at its glow × `glowOut`.
    private(set) var frameLayout = SubmarineWindowRenderer.layout(aspect: 16.0 / 9, keyTop: -0.76)
    private(set) var livingLevel: Float = 0
    private(set) var glowOut: Float = 0
    /// What this frame drew: creatures, shoal lights, bells, bubbles, flecks and fish.
    private(set) var creatureCount = 0, shoalLightCount = 0, bellCount = 0, bubbleCount = 0, snowCount = 0, fishCount = 0
    /// The creatures drawn, as sprites (position NDC, radius, their glow after the limiter), for tests.
    private(set) var creatureSprites: [(centre: SIMD2<Float>, radius: Float, glow: Float)] = []
    /// The lamps' light on the brightest-lit flecks of snow (tests).
    private(set) var snowLampPeak: Float = 0
    /// Excitement as drawn (tests read them): the whale's presence, the lamps after the dark's dimming, and the
    /// surprises' sprites drawn this frame.
    private(set) var whalePresence: Float = 0
    private(set) var lampsOut: Float = 0
    private(set) var surpriseSprites = 0
    var flashesInLastSecond: Int { max(limiter.recent, deepLimiter.recent) }
    var flashTotal: Int { limiter.total + deepLimiter.total }
    /// The keys' rectangles in NDC (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let gw = WarpLayer(device: device), let g = WindowGlassLayer(device: device),
              let lib = try? device.makeLibrary(source: SubmarineWindowShaders.source, options: nil) else { return nil }
        enum Blend { case opaque, premultiplied }
        func make(_ v: String, _ f: String, _ blend: Blend, writesDepth: Bool = true, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if blend == .premultiplied {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if !writesDepth { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let se = SkyPipeline(build: { make("sub_full_vertex", "sub_sea_fragment", .opaque, storms: $0) }),
              let sp = make("sub_sprite_vertex", "sub_sprite_fragment", .premultiplied, writesDepth: false),
              let cb = make("sub_full_vertex", "sub_cabin_fragment", .opaque),
              let k = make("sub_keys_vertex", "sub_keys_fragment", .opaque) else { return nil }
        let bytes = Self.spriteCapacity * MemoryLayout<Sprite>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(b)
        }
        sky = s; warp = gw; glass = g; sea = se; sprites = sp; cabin = cb; keys = k
        ring = buffers
        bufferAllocations = buffers.count
        spriteList.reserveCapacity(Self.spriteCapacity)
        keyInstances.reserveCapacity(88)
        creatureSprites.reserveCapacity(DeepLights.cap)
    }

    /// A key's console button (NDC rect): a white key's in the lower row, a black key's in the upper one, over the
    /// keyboard's own span of it.
    nonisolated static func buttonRect(_ k: KeyRect, keyTop: Float) -> SIMD4<Float> {
        let bottom: Float = -0.995, gap: Float = 0.0015
        let x0 = -0.995 + k.x * 1.99 + gap, x1 = -0.995 + (k.x + k.width) * 1.99 - gap
        let h = max(0.02, keyTop - bottom)
        return k.isBlack ? SIMD4(x0, bottom + 0.53 * h, x1, keyTop - 0.004) : SIMD4(x0, bottom, x1, bottom + 0.49 * h)
    }

    nonisolated static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func hash(_ a: Int, _ b: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    func update(_ frame: SubFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        self.quality = quality
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let lay = Self.layout(aspect: aspect, keyTop: keysShow ? keyTop : -0.92)
        frameLayout = lay
        let R = lay.radius
        let unit = R / 0.7   // sprites scale with the porthole

        // The sea and the light from above.
        let metres = frame.depthMetres.isFinite ? max(0, frame.depthMetres) : 65
        let shallow = SubmarineWindowModel.shallow(metres: metres)
        let deep = Self.smooth(15, 120, metres)
        let pitch = (Self.shallowPitch + (Self.deepPitch - Self.shallowPitch) * deep) * .pi / 180
        let sunAz = s.sun.azimuth.isFinite ? s.sun.azimuth : 0
        let viewAz = sunAz - Self.sunOffset
        let tanR = tan(Self.halfView * .pi / 180)
        let night = Float(1 - OceanLight.smooth(-8, -2, s.sun.altitude))
        let nightGain: Float = 1 + 6 * night * shallow   // the eye adapts to a dark night near the surface
        let cloud = min(1, max(0, s.cloudCover.isFinite ? s.cloudCover : 0))
        let sunShaft = Float(OceanLight.smooth(-2, 12, s.sun.altitude)) * (1 - 0.65 * cloud)
        let moonShaft = Float(s.moonLit) * Float(OceanLight.smooth(2, 15, s.moon.altitude)) * (1 - 0.8 * cloud)
        let byMoon = moonShaft > sunShaft
        let lightAz = byMoon ? (s.moon.azimuth.isFinite ? s.moon.azimuth : sunAz) : sunAz
        let rel = Float((lightAz - viewAz) * .pi / 180)
        let shaftStrength = 1.3 * max(sunShaft, moonShaft * 0.9)
        // The dark gathering with tension: the light from above and the lamps dim (they come back as it releases).
        let dark = min(1, max(0, frame.dark.isFinite ? frame.dark : 0))
        let surface = frame.surfaceLight * (1 - 0.5 * dark)
        let glowSea = Self.seaGlow(surface: surface, metres: metres, nightGain: nightGain)
        let lamps = min(1, max(0, frame.lamps)) * (1 - 0.6 * dark)
        lampsOut = lamps

        // Snell's window samples the Living Sky: its camera matches this view (its pixel angle above all).
        sky.viewAzimuth = viewAz
        sky.verticalFOV = Double(2 * atan(tanR / max(R, 0.05)) * 180 / .pi)
        sky.horizonY = 0
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: time)
        showWarp = frame.warp != nil
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = lay.centre
            warp.update(w, trails: 0.6, nebula: 0.6, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: time)
        }

        // The cabin's light: a dim, cool white by day, red night lighting after dark (dimmer, to keep eyes dark-adapted).
        let cabinNight = min(1, max(0, frame.cabinNight))
        let dayLight = SIMD3<Float>(0.78, 0.85, 0.95), redLight = SIMD3<Float>(0.95, 0.1, 0.05)
        let cabinLight = min(1, max(0, frame.cabinLight))
        let cabinTint: SIMD3<Float> = dayLight + (redLight - dayLight) * cabinNight
        let cabinLevel: Float = (0.12 + 0.88 * cabinLight) * (0.6 - 0.2 * cabinNight)
        let cabinCol: SIMD3<Float> = cabinTint * cabinLevel

        // The living light through the flash limiter: how much of the window it lights, held to the flash rules.
        let visible = DeepLights.visible(frame.creatures, limit: Self.creatureBudget(quality))
        var level: Float = 0
        for c in visible { level += min(1, max(0, c.glow)) * Self.flashWeight(c, glassRadius: R) }
        // A squid's cloud of light counts with the living light (a burst over a good part of the glass).
        if let sq = frame.surprises.first(where: { $0.index == 1 }) { level += 0.6 * Self.squidLight(age: sq.age, life: sq.duration) }
        for sh in frame.shoals { level += min(1, max(0, sh.brightness)) * Float(sh.contour.count) * 0.002 }
        for sp in frame.siphonophores { level += min(1, max(0, sp.brightness)) * Float(sp.bells) * 0.003 }
        livingLevel = level
        deepLimiter.gentle = gentle
        let limitedLiving = deepLimiter.limit(exposure: level, sparkle: 1, dt: dt)
        let allowed: Float = level > 1e-4 ? min(1, max(0, limitedLiving.exposure / level)) : 1
        glowOut = allowed * limitedLiving.sparkle
        limiter.gentle = gentle
        let mood = frame.mood
        let limited = limiter.limit(exposure: MoodLook.exposure(mood), sparkle: 1, dt: dt)

        // The glass: its rim fogging with the cold sea (more the deeper), the cabin faintly mirrored in it, no frost.
        let spec = lay.spec(aspect: aspect)
        glass.updatePorthole(spec: spec, condensation: 0.2 + 0.3 * frame.depth, cold: frame.depth, cabinLight: cabinCol * 1.6,
                             reflection: SIMD4(cabinCol * 1.4, 0.05), outsideLight: glowSea, quality: quality, dt: dt,
                             aspect: aspect, sparkle: sparkleScale)

        // The uniforms.
        uniforms[0] = SIMD4(lay.centre.x, lay.centre.y, R, aspect)
        uniforms[1] = SIMD4(Float(viewAz * .pi / 180), pitch, tanR, time)
        uniforms[2] = SIMD4(metres, frame.surfaceWaves, frame.rainOnSurface, frame.milky)
        uniforms[3] = SIMD4(surface, shaftStrength * (1 - 0.4 * dark))
        let pixelAngle: Float = 2 * tanR / max(R, 0.05) / Float(max(1, size.height))
        uniforms[4] = SIMD4(-sin(rel) * 0.45, -1, pixelAngle, frame.snellVisible)
        let below: Float = metres < 70 ? 3 + 0.25 * metres : 0
        let qualityCode: Float = quality == .lite ? 0 : 1
        uniforms[5] = SIMD4(lamps, nightGain, below, qualityCode)
        uniforms[6] = SIMD4(cabinCol, keyTop)
        uniforms[7] = SIMD4(lay.outer, lay.consoleTop, cabinNight, lay.ring)
        let wallGlow: SIMD3<Float> = glowSea + SIMD3<Float>(1, 0.92, 0.8) * (0.05 * lamps)
        let screen: Float = min(1, max(0, frame.sonarScreen)) * (1 - 0.3 * cabinNight)
        uniforms[8] = SIMD4(wallGlow, screen)
        let needle = (-135 + 270 * min(1, max(0, frame.depth))) * Float.pi / 180
        uniforms[9] = SIMD4(lay.gauge.x, lay.gauge.y, lay.gaugeRadius, needle)
        uniforms[10] = SIMD4(lay.sonar.x, lay.sonar.y, lay.sonarRadius, frame.sonarSweep)
        let blips = frame.sonarBlips.suffix(24)
        for i in 0..<24 { uniforms[Self.blipBase + i] = .zero }
        for (i, b) in blips.enumerated() { uniforms[Self.blipBase + i] = SIMD4(b.angle, b.range, min(1, max(0, b.brightness)), 0) }
        uniforms[11] = SIMD4(Float(blips.count), min(1, level * glowOut), 0.012, Float(max(1, size.height)))
        // The whale (in the sea pass) and the far sub's contact (on the sonar screen).
        if let w = frame.whale, w.presence > 0.002 {
            uniforms[Self.rowWhale] = SIMD4(w.centre.x, w.centre.y, max(0.05, w.halfLength), min(1, w.presence))
            uniforms[Self.rowWhaleB] = SIMD4(w.heading < 0 ? -1 : 1, w.beat, min(1, max(0, w.distance)), 0)
            whalePresence = w.presence
        } else {
            uniforms[Self.rowWhale] = .zero
            uniforms[Self.rowWhaleB] = SIMD4(1, 0, 0, 0)
            whalePresence = 0
        }
        uniforms[Self.rowContact] = .zero
        if let c = frame.surprises.first(where: { $0.index == 2 }) {
            let env = ExcitementPlay.envelope(age: c.age, life: c.duration, rise: 1, fall: 2)
            let ping = (c.age / 2.4).truncatingRemainder(dividingBy: 1)
            uniforms[Self.rowContact] = SIMD4(6.2831853 * c.unit(0), 0.78 + 0.15 * c.unit(1), env, ping)
        }

        // The sprites: the far snow, the siphonophores behind, the creatures, the shoals, the fish, the near snow, the
        // bubbles at the glass.
        spriteList.removeAll(keepingCapacity: true)
        creatureSprites.removeAll(keepingCapacity: true)
        func ndc(_ v: SIMD2<Float>) -> SIMD2<Float> { lay.centre + SIMD2((v.x - 0.5) * 2 * R / aspect, (v.y - 0.5) * 2 * R) }
        func lampAt(_ v: SIMD2<Float>) -> Float { Self.lampLight(SIMD2(2 * v.x - 1, 2 * v.y - 1)) * lamps }
        func push(_ at: SIMD2<Float>, _ radius: Float, _ kind: Kind, _ colour: SIMD3<Float>, _ param: Float = 0, lit: Float = 0) {
            guard spriteList.count < Self.spriteCapacity, at.x.isFinite, at.y.isFinite, radius.isFinite else { return }
            spriteList.append(Sprite(a: SIMD4(at.x, at.y, max(radius, 0.0005), kind.rawValue + min(0.99, max(0, lit))),
                                     b: SIMD4(colour, param)))
        }
        let pixel = 2 / Float(max(1, size.height))
        let lampCol = SIMD3<Float>(1, 0.92, 0.8)
        let ambient = glowSea * 0.5
        func snow(near: Bool) {
            var peak: Float = 0
            for f in frame.snow.live where (f.position.z < 0.35) == near {
                let v = SIMD2(f.position.x, f.position.y)
                let z = f.position.z
                let lampF: Float = lampAt(v) * exp(-1.4 * z)
                peak = max(peak, lampF)
                let fade: Float = 0.35 + 0.65 * exp(-1.2 * z)
                let lampLit: SIMD3<Float> = lampCol * (3.5 * lampF)
                let cabinLit: SIMD3<Float> = cabinCol * (0.3 * max(0, 0.3 - z))
                let light: SIMD3<Float> = (ambient + lampLit + cabinLit) * (f.brightness * fade)
                guard light.x + light.y + light.z > 0.003 else { continue }
                let r: Float = max(1.3 * pixel, 0.0045 * f.size * unit / (0.22 + z))
                let shown: SIMD3<Float> = light * (near ? 0.6 : 1)
                push(ndc(v), r, .snow, shown)
                snowCount += 1
            }
            snowLampPeak = max(snowLampPeak, peak)
        }
        snowCount = 0; snowLampPeak = 0
        snow(near: false)

        let gain: Float = glowOut * 1.6
        bellCount = 0
        for sp in frame.siphonophores {
            let b: Float = min(1, max(0, sp.brightness)) * gain * 0.8
            guard b > 0.002 else { continue }
            for k in 0..<max(0, min(sp.bells, 24)) {
                let x = sp.position.x - Float(k) * DeepLights.bellSpacing
                let ripple: Float = 0.012 * sin(Float(k) * 0.7 + time * 0.5 + Float(sp.id))
                let y: Float = sp.position.y + ripple
                let fall: Float = 1 - 0.35 * Float(k) / Float(max(1, sp.bells))
                let fleck: Float = sp.flecks > 0.5 && k % 3 == 1 ? 1 : 0
                let bellColour: SIMD3<Float> = sp.colour * (b * fall)
                push(ndc(SIMD2(x, y)), 0.013 * unit * fall, .bell, bellColour, fleck, lit: lampAt(SIMD2(x, y)))
                bellCount += 1
            }
        }

        creatureCount = 0
        for c in visible {
            let g: Float = min(1, max(0, c.glow)) * gain
            let at = ndc(c.position)
            let radius = Self.creatureRadius(c) * unit
            let h = Self.hash(c.id, 7)
            let tint: SIMD3<Float>
            let kind: Kind
            switch c.kind {
            case .jelly:
                kind = .jelly
                tint = DeepLights.livingLight + (SIMD3<Float>(0.4, 0.55, 1.0) - DeepLights.livingLight) * (0.35 * h)
            case .combJelly:
                kind = .comb
                tint = DeepLights.livingLight + (SIMD3<Float>(0.3, 0.95, 0.85) - DeepLights.livingLight) * (0.4 * h)
            case .speck:
                kind = .speck
                tint = DeepLights.livingLight + (SIMD3<Float>(0.55, 0.9, 1.0) - DeepLights.livingLight) * (0.5 * h)
            }
            let colour: SIMD3<Float> = tint * g
            push(at, radius, kind, colour, c.swimPhase, lit: lampAt(c.position) * 0.9)
            creatureSprites.append((at, radius, g))
            creatureCount += 1
        }

        shoalLightCount = 0
        for sh in frame.shoals {
            let b: Float = min(1, max(0, sh.brightness)) * gain * 1.2
            guard b > 0.002 else { continue }
            for i in sh.contour.indices {
                let v = sh.light(i)
                let flick: Float = 0.75 + 0.25 * sin(time * 17 + Float(i) * 2.1 + Float(sh.id))
                let k: Float = b * flick
                let colour = SIMD3<Float>(0.55 * k, 0.88 * k, k)
                push(ndc(v), 0.009 * unit, .photophore, colour)
                shoalLightCount += 1
            }
        }

        // Small fish crossing the bright shallows in a loose school (silhouettes; gone by 40 m and in the dark).
        fishCount = 0
        let seaLuma = simd_dot(glowSea, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let fishShow = shallow * Self.smooth(0.03, 0.15, seaLuma)
        if fishShow > 0.01 {
            let cycle = frame.time / 26
            let school = Int(cycle.rounded(.down))
            let phase = Float(cycle - cycle.rounded(.down))
            let heading: Float = school % 2 == 0 ? 1 : -1
            for i in 0..<Self.fishCount {
                let hx = Self.hash(school, i), hy = Self.hash(school, i + 31)
                let across = phase * 1.6 - 0.3 - 0.08 * hx
                let x = heading > 0 ? across : 1 - across
                let sway: Float = 0.015 * sin(time * 1.3 + Float(i) * 1.9)
                let y: Float = 0.42 + 0.22 * (hy - 0.5) + sway
                let r = (0.024 + 0.014 * hx) * unit
                let shade: SIMD3<Float> = glowSea * 0.25
                push(ndc(SIMD2(x, y)), r, .fish, shade, heading, lit: 0.8 * fishShow)
                fishCount += 1
            }
        }

        // Energy's traffic: far lanternfish lights drifting across the dark.
        surpriseSprites = 0
        for f in frame.passers {
            let b: Float = min(1, max(0, f.z)) * gain * 0.7
            guard b > 0.002 else { continue }
            let flick: Float = 0.8 + 0.2 * sin(time * 5.1 + f.y * 40)
            let lanternGlow: Float = b * flick
            let lantern = SIMD3<Float>(0.45 * lanternGlow, 0.8 * lanternGlow, lanternGlow)
            push(ndc(SIMD2<Float>(f.x, f.y)), 0.008 * unit, .photophore, lantern)
        }
        surpriseSprites += addSurprises(frame, ndc: ndc, unit: unit, gain: gain, time: time, push: push)

        snow(near: true)

        bubbleCount = 0
        for st in frame.bubbleStreams {
            let fadeOut = 1 - Self.smooth(DeepLights.streamRise, DeepLights.streamLife, st.age)
            let n = 6 + Int((Float(Self.bubblesPerStream - 6) * min(1, max(0, st.strength))).rounded())
            for j in 0..<n {
                let seed = Int(st.seed % 100_000)
                let delay = Self.hash(seed, j) * 1.1
                let y = (st.age - delay) / DeepLights.streamRise
                guard y > -0.02, y < 1.08 else { continue }
                let wobble: Float = 0.014 * sin(st.age * 7 + Float(j) * 2.3)
                let wob: Float = wobble + 0.03 * (Self.hash(seed, j + 50) - 0.5)
                let v = SIMD2(st.x + wob, y)
                let size: Float = 0.006 + 0.012 * Self.hash(seed, j + 90) * st.strength
                let r: Float = size * unit * (1 + 0.35 * max(0, y))
                let sea: SIMD3<Float> = glowSea * 0.8
                let lampLit: SIMD3<Float> = lampCol * (lampAt(v) * 1.2)
                let cabinLit: SIMD3<Float> = cabinCol * 0.7 + SIMD3<Float>(repeating: 0.02)
                let light: SIMD3<Float> = (sea + lampLit + cabinLit) * fadeOut
                push(ndc(v), r, .bubble, light)
                bubbleCount += 1
            }
        }

        if !spriteList.isEmpty {
            slot = (slot + 1) % ring.count
            let bytes = spriteList.count * MemoryLayout<Sprite>.stride
            spriteList.withUnsafeBytes { ring[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        }

        // The keys: backlit console buttons in two staggered rows (the white keys below, the black ones above, where
        // they fall on the keyboard), glowing cyan where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            for k in frame.keys {
                let glow = min(1, max(0, k.glow)) * (gentle ? 0.75 : 1)
                keyInstances.append(KeyInstance(rect: Self.buttonRect(k.key, keyTop: keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, glow, k.pressed ? 1 : 0, cabinNight)))
            }
        }

        post = PostSettings(
            bloom: 0.65, bloomThreshold: 0.85,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.025, vignette: 0.4,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) - 0.04 * (1 - cabinNight) + 0.03 * cabinNight,
            time: time, quality: quality)
    }

    /// A squid's cloud of light, `age` seconds into its `life`: bright at once, fading over its life (0…1).
    nonisolated static func squidLight(age: Float, life: Float) -> Float {
        guard age >= 0, age < life else { return 0 }
        return min(1, age / 0.15) * exp(-age / 2) * (1 - smooth(life - 1, life, age))
    }

    /// The surprises' sprites: an anglerfish's lure bobbing in the dark (its jaws just lit by it), a squid's cloud of
    /// light spreading and fading, and the far sub's two lights crossing far off. Returns how many were pushed.
    private func addSurprises(_ frame: SubFrame, ndc: (SIMD2<Float>) -> SIMD2<Float>, unit: Float, gain: Float, time: Float,
                              push: (SIMD2<Float>, Float, Kind, SIMD3<Float>, Float, Float) -> Void) -> Int {
        var n = 0
        for s in frame.surprises {
            let age = s.age
            switch s.index {
            case 0:
                let env = ExcitementPlay.envelope(age: age, life: s.duration, rise: 1.5, fall: 2)
                let x: Float = 0.3 + 0.4 * s.unit(0) + 0.03 * sin(age * 0.7)
                let y: Float = 0.35 + 0.25 * s.unit(1) + 0.02 * sin(age * 1.3 + 1)
                let pulse: Float = 0.7 + 0.3 * sin(age * 1.9)
                let lure = SIMD3<Float>(0.55, 0.85, 1.0) * (env * pulse * gain)
                let side: Float = s.unit(2) < 0.5 ? -1 : 1
                push(ndc(SIMD2(x - side * 0.05, y - 0.04)), 0.05 * unit, .fish, lure * 0.12, side, 0.5 * env)
                push(ndc(SIMD2(x, y)), 0.035 * unit, .speck, lure * 0.5, 0, 0)
                push(ndc(SIMD2(x, y)), 0.012 * unit, .photophore, lure * 1.4, 0, 0)
                n += 3
            case 1:
                let light = Self.squidLight(age: age, life: s.duration)
                guard light > 0.002 else { continue }
                let cx: Float = 0.3 + 0.4 * s.unit(0), cy: Float = 0.35 + 0.3 * s.unit(1)
                let spread: Float = 0.2 * (1 - exp(-age / 0.6)) + 0.01 * age
                for k in 0..<Self.squidMotes {
                    let fk = Float(k)
                    let a = 6.2831853 * Self.hash(Int(s.seed % 10_000), k)
                    let r = spread * (0.25 + 0.75 * Self.hash(Int(s.seed % 10_000), k + 50))
                    let drift = SIMD2<Float>(0.02 * sin(time * 0.6 + fk), 0.015 * age)
                    let at = SIMD2<Float>(cx + r * cos(a), cy + r * sin(a)) + drift
                    let b: Float = light * gain * (0.4 + 0.6 * Self.hash(Int(s.seed % 10_000), k + 90))
                    push(ndc(at), (0.006 + 0.006 * Self.hash(Int(s.seed % 10_000), k + 130)) * unit, .photophore,
                         SIMD3<Float>(0.3, 0.9, 1.0) * b, 0, 0)
                    n += 1
                }
            default:
                let env = ExcitementPlay.envelope(age: age, life: s.duration, rise: 2, fall: 2)
                let dir: Float = s.unit(2) < 0.5 ? -1 : 1
                let x: Float = 0.5 + dir * (0.6 - 1.2 * s.progress)
                let y: Float = 0.62 + 0.15 * s.unit(3)
                let blink: Float = (age.truncatingRemainder(dividingBy: 2) < 0.12) ? 1 : 0.15
                push(ndc(SIMD2(x, y)), 0.006 * unit, .photophore, SIMD3<Float>(1.0, 0.95, 0.85) * (0.5 * env), 0, 0)
                push(ndc(SIMD2(x + 0.025 * dir, y - 0.004)), 0.005 * unit, .photophore, SIMD3<Float>(1.0, 0.3, 0.2) * (0.4 * env * blink), 0, 0)
                n += 2
            }
        }
        return n
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              var e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        // The sea, the warp through it, and the living light and the snow.
        e.setRenderPipelineState(sea.state(storms: sky.storms))
        skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        uniforms.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if showWarp { warp.draw(e) }
        if !spriteList.isEmpty {
            e.setRenderPipelineState(sprites)
            e.setVertexBuffer(ring[slot], offset: 0, index: 0)
            uniforms.withUnsafeBytes {
                e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: spriteList.count)
        }

        // The view through the thick acrylic (every quality), then the brass ring.
        var view: MTLTexture?
        if let hdr = stack.hdrTarget {
            e.endEncoding()
            view = glass.makeView(from: hdr, commandBuffer: cb)
            guard let again = stack.scenePassContinuing(), let next = cb.makeRenderCommandEncoder(descriptor: again) else { return }
            e = next
        }
        glass.drawPorthole(e, view: view)
        glass.drawFrame(e)

        // The cabin round it, then the keys.
        e.setRenderPipelineState(cabin)
        uniforms.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            uniforms.withUnsafeBytes {
                e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
