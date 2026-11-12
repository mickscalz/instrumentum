import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Aurora Fjord (spec §8.1): from a jetty at the head of a fjord, looking down it toward the pole with the aurora
/// over the sea end; steep snow-streaked walls framing a V of sky; the still water mirroring the sky and the walls; the
/// fishing village's lights with their reflections (and pillars in diamond dust); drifting ice floes; the jetty's snowy
/// rails and ice-blue glass keys. Curtain Lights ripples the aurora itself (the sky's ripples and tint); Galaxy Warp
/// streams over the sky instead when chosen.
@MainActor
final class AuroraFjordRenderer: ThemeRenderer {
    /// Curtain Lights' band (the keyboard's 0.08…0.92) is laid over the part of the curtain the V of sky shows: the
    /// shader's band units 0.5 ± 0.42 × bandSpan (about ±21° along the aurora). Travel and widths scale with it, so a
    /// ripple crosses the V as it crosses the keyboard.
    static let bandSpan: Float = 0.28
    /// The eye above the water (m; the shader's kEye).
    static let eyeHeight: Float = 2.7
    /// A tense chord's purple-fringe pulse flares the curtain through the sky's storm value (times the sparkle).
    static let tenseFlare: Float = 0.55
    static let maxVillageLights = 10
    /// The walls' feet either side of the jetty and their spread down the fjord (the shader's kWallFoot, kWallSpread).
    static let wallFoot: Float = 250, wallSpread: Float = 0.08

    /// The fishing village on the far left shore: angle across the view (radians, − left) and height over the water
    /// (m), in the order the lights come on as the Village lights setting rises (6…10), spread along the shore.
    static let villageLayout: [(phi: Float, height: Float)] = [
        (-0.2897, 12), (-0.2112, 10), (-0.2583, 8), (-0.1798, 15), (-0.2426, 18),
        (-0.1641, 6), (-0.2740, 48), (-0.1955, 34), (-0.3037, 26), (-0.2269, 130),
    ]

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let village, floe, rail, keys: MTLRenderPipelineState
    private var fjordU = [SIMD4<Float>](repeating: .zero, count: 9)
    private var villageInstances: [VillageInstance] = []
    private var floeInstances: [SIMD4<Float>] = []
    private var railParts: [RailPart] = []
    private var keyInstances: [KeyInstance] = []
    private var viewAzimuth: Double?
    /// The sky's clock: it runs at Curtain Lights' shimmer speed (1…2×), so intensity speeds the curtain's rays.
    private var skyClock = 0.0
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    /// The held-note glow sent to the aurora, after the flash limiter (gentle visuals halve it).
    private(set) var glowOut: Float = 0
    /// Ripples sent to the aurora this frame (at most 8), and what was sent (position, age, strength, width).
    private(set) var rippleCount = 0
    private(set) var shaderRipples = [SIMD4<Float>](repeating: .zero, count: SkyLayer.rippleCount)
    /// The village's lights drawn this frame, and where they are (NDC).
    private(set) var villageLightCount = 0
    private(set) var villagePoints: [SIMD2<Float>] = []
    private(set) var floeCount = 0
    /// The horizon (NDC y): the sea end's water line.
    private(set) var horizonY: Float = -0.23
    /// The tops of the jetty's two end posts (NDC; tests check the jetty stays in view).
    private(set) var jettyPosts: [SIMD2<Float>] = []
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }
    /// The village lights' quads in NDC (x0, y0, x1, y1), in `villageLayout` order (tests check each holds its reflection).
    var villageRects: [SIMD4<Float>] { villageInstances.map(\.rect) }
    /// The shader's FjordU (tests read its clock).
    var uniforms: [SIMD4<Float>] { fjordU }
    /// The shader's clock wraps at the hour (the newer worlds' wrap); the water, the falls and the glints read noise that
    /// repeats in a whole number of cells an hour (the shader's kFjordTick), so the wrap never shows.
    static let clockWrap = 3600.0

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }
    /// The shader's VillageLight: the quad (NDC), direction and angular radius, colour and mirror depression.
    private struct VillageInstance { var rect: SIMD4<Float>; var dir: SIMD4<Float>; var colour: SIMD4<Float> }
    /// The shader's RailPart: four clip-space corners and info (kind, length, seed).
    private struct RailPart { var p0, p1, p2, p3, info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let lib = try? device.makeLibrary(source: AuroraFjordShaders.source, options: nil) else { return nil }
        enum Blend { case opaque, premultiplied, additive }
        func make(_ v: String, _ f: String, _ blend: Blend, writesDepth: Bool = true, storms: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v, storms: storms)
            d.fragmentFunction = lib.skyFunction(f, storms: storms)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            let c = d.colorAttachments[0]!
            switch blend {
            case .opaque: break
            case .premultiplied:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            if !writesDepth { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let sc = SkyPipeline(build: { make("fjord_vertex", "fjord_scene_fragment", .opaque, storms: $0) }),
              let v = make("fjord_village_vertex", "fjord_village_fragment", .additive, writesDepth: false),
              let fl = make("fjord_floe_vertex", "fjord_floe_fragment", .premultiplied, writesDepth: false),
              let r = make("fjord_rail_vertex", "fjord_rail_fragment", .premultiplied),
              let k = make("fjord_keys_vertex", "fjord_keys_fragment", .opaque) else { return nil }
        sky = s; weather = w; warp = gw; scene = sc; village = v; floe = fl; rail = r; keys = k
        sky.verticalFOV = 64
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }
    private static func smoothF(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The lens: 64° tall at 16:9, a little narrower on wide windows and taller on square ones (54…74°), so the V of
    /// sky keeps its shape.
    static func verticalFOV(aspect: Float) -> Double {
        let a = Double(aspect.isFinite ? max(aspect, 0.2) : 16.0 / 9)
        return min(74, max(54, 64 * pow(16.0 / 9 / a, 0.3)))
    }

    /// The fjord frames the aurora low over the sea end, where its walls and water can show it (the sky's band sits
    /// 25–60° up in "Always" and overhead at Tromsø): its base comes down to 4° + 0.12 × the sky's altitude.
    static func framedAltitude(_ a: Float) -> Float { 4 + 0.12 * min(max(a.isFinite ? a : 0, 0), 90) }

    /// A Curtain Lights ripple as the sky shader takes it (position 0…1 along the band, age s, strength, width), laid
    /// over the V's part of the band: positions about the band's middle, the travel (via the age) and the width all
    /// scale by `bandSpan`; the strength goes through the flash limiter's sparkle.
    static func shaderRipple(_ r: CurtainRipple, sparkle: Float) -> SIMD4<Float> {
        let k = bandSpan
        let position = r.position.isFinite ? r.position : 0.5
        let age = r.age.isFinite ? max(0, r.age) : 0
        let strength = r.strength.isFinite ? min(max(r.strength, 0), 1) : 0
        let width = r.width.isFinite ? max(0, r.width) : 0.04
        return SIMD4(0.5 + (position - 0.5) * k, age * k, strength * sparkle, width * k)
    }

    /// Where a shader ripple's two fronts are along the band (the sky shader moves them at 0.12 per second of age).
    static func fronts(_ r: SIMD4<Float>) -> (left: Float, right: Float) { (r.x - 0.12 * r.y, r.x + 0.12 * r.y) }

    /// How many village lights the setting shows (6…10).
    static func villageCount(_ amount: Double) -> Int {
        let a = amount.isFinite ? min(max(amount, 0), 1) : 0.7
        return 6 + Int((4 * a).rounded())
    }

    /// How far the wall's foot is at |φ| (m; the shader's fjordWallDistance).
    static func wallDistance(_ a: Float) -> Float {
        let b = min(abs(a), 1.45)
        return wallFoot / max(tan(b) - wallSpread, 0.004) / cos(b)
    }

    /// Where a floe sits on the water: x across (0…1, past the view's edges at the wrap), depth 0 near … 1 far.
    static func floePoint(x: Float, depth: Float, tanH: Float) -> (s: Float, f: Float) {
        let f = 9 / (1 - 0.9 * min(1, max(0, depth)))
        return ((x - 0.5) * 2 * f * tanH * 1.25, f)
    }

    func update(_ frame: FjordFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let fdt = dt.isFinite ? min(max(dt, 0), 0.1) : 0
        let time = Float(frame.time)
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        // A big sky: the horizon sits 30% of the way from the keys to the top.
        horizonY = keyTop + (1 - keyTop) * 0.3
        sky.verticalFOV = Self.verticalFOV(aspect: aspect)
        sky.horizonY = horizonY

        // Weather on the water: rings, snow and blizzards, diamond dust's crystals (the cold has no fireflies), and sea
        // smoke over the fjord from the jetty out to the sea end (spec §6.4; the walls' feet stand within a few hundredths
        // of the horizon, so the band runs the whole width).
        weather.waterBand = SIMD4(-1, keyTop, 1, horizonY)
        weather.steamCamera = sky.camera(latitude: s.latitude, aspect: aspect)
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .water(horizonY: horizonY))

        // The exposure and everything that glows go through the flash limiter (gentle visuals halve the sparkle).
        let mood = frame.mood
        let sunAlt = s.sun.altitude
        let night = Float(1 - Self.smooth(-12, -3, sunAlt))
        limiter.gentle = gentle
        let exposure = MoodLook.exposure(mood) * (1 + 0.9 * night) * weather.exposureBoost
        let limited = limiter.limit(exposure: exposure, sparkle: 1, dt: dt)
        let sparkle = limited.sparkle

        // The camera faces the aurora's pole-ward azimuth, gliding over 4 s as it wanders; the sky's clock runs at the
        // curtain's shimmer speed.
        let shimmer = frame.shimmer.isFinite ? min(max(frame.shimmer, 1), 2) : 1
        skyClock += fdt * Double(shimmer)
        let skyTime = Float(skyClock)
        let target = SkyLayer.auroraAzimuth(hemisphere: s.hemisphere, time: skyTime)
        if let az = viewAzimuth {
            var diff = (target - az).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff -= 360 } else if diff < -180 { diff += 360 }
            var next = az + diff * (1 - exp(-fdt / 4))
            if next < 0 { next += 360 } else if next >= 360 { next -= 360 }
            viewAzimuth = next
        } else {
            viewAzimuth = target < 0 ? target + 360 : target
        }
        sky.viewAzimuth = viewAzimuth

        // Curtain Lights on the aurora: the ripples (mapped into the V's span of the band), the hue shift and the
        // held-note glow (eased in: it builds like a bow pressing in), all through the limiter's sparkle.
        var ripples = [SIMD4<Float>](repeating: .zero, count: SkyLayer.rippleCount)
        let sent = CurtainLights.visible(frame.ripples, limit: SkyLayer.rippleCount)
        for (i, r) in sent.enumerated() { ripples[i] = Self.shaderRipple(r, sparkle: sparkle) }
        rippleCount = sent.count
        shaderRipples = ripples
        sky.ripples = ripples
        let glow = frame.glow.isFinite ? min(max(frame.glow, 0), 1) : 0
        glowOut = glow * glow * sparkle
        let hue = frame.hueShift.isFinite ? min(max(frame.hueShift, -1), 1) : 0
        sky.auroraTint = SIMD2(hue, glowOut)
        var shown = s
        shown.auroraAltitude = Self.framedAltitude(s.auroraAltitude)
        let tense = frame.tensePulse.isFinite ? min(max(frame.tensePulse, 0), 1) : 0
        shown.auroraStorm = max(s.auroraStorm, Self.tenseFlare * tense * sparkle)
        sky.update(shown, quality: quality, size: size, time: skyTime)
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)

        // Galaxy Warp streams out of the sky over the sea end (the walls and water draw over it).
        showWarp = frame.warp != nil
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (1 - horizonY) * 0.45)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkle, quality: quality, size: size, dt: dt, time: time)
        }

        // Light: the sun (warm when low), the moon, the sky's own light, and the aurora's green on snow, ice and water.
        let cloud = min(max(s.cloudCover, 0), 1)
        let sunUp = Float(Self.smooth(-3, 6, sunAlt)) * (1 - 0.75 * cloud)
        let moonUp = Float(Self.smooth(-2, 6, s.moon.altitude) * s.moonLit) * (1 - 0.7 * cloud)
        let low = SIMD3<Float>(1.0, 0.5, 0.28), high = SIMD3<Float>(1.0, 0.95, 0.88)
        let sunColour = (low + (high - low) * Float(Self.smooth(0, 25, sunAlt))) * 2
        let day = Float(Self.smooth(-6, 4, sunAlt))
        let alpenglow = Float(Self.smooth(-2.5, -0.5, sunAlt) * (1 - Self.smooth(5, 8, sunAlt))) * (1 - 0.6 * cloud)
        let cool = max(-hue, 0), warm = max(hue, 0)
        let green = SIMD3<Float>(0.25, 1.0, 0.45) + (SIMD3<Float>(0.35, 0.55, 1.0) - SIMD3<Float>(0.25, 1.0, 0.45)) * (0.6 * cool)
        let topColour = SIMD3<Float>(0.95, 0.25, 0.4) + (SIMD3<Float>(0.55, 0.35, 1.0) - SIMD3<Float>(0.95, 0.25, 0.4)) * cool
        let aurora = min(max(s.aurora, 0), 1)
        let topWeight: Float = 0.4 * (shown.auroraStorm + 0.7 * warm + 0.5 * cool)
        let auroraGain: Float = aurora * (1 + 0.6 * glowOut) * 0.05
        let auroraLight: SIMD3<Float> = (green + topColour * topWeight) * auroraGain
        let mist = min(1, max(0, s.mist) * (0.6 + 0.4 * MoodLook.hazeScale(mood)))
        let swell = Float(min(max(p.number("swell"), 0), 1))
        let villageAmount = Float(min(max(p.number("village"), 0), 1))
        let villageOn: Float = frame.villageLit ? villageAmount : 0
        let phase1 = Float((frame.time * 2 * .pi / 9).truncatingRemainder(dividingBy: 2 * .pi))
        let phase2 = Float((frame.time * 2 * .pi / 6.3).truncatingRemainder(dividingBy: 2 * .pi))
        let clock = Float(frame.time.truncatingRemainder(dividingBy: Self.clockWrap))
        fjordU[0] = SIMD4(keyTop, clock, aspect, quality == .lite ? 2 : 3)
        fjordU[1] = SIMD4(night, day, mist, min(max(s.wind, 0), 1))
        fjordU[2] = SIMD4(swell, sparkle, villageOn, alpenglow)
        fjordU[3] = SIMD4(SkyLayer.enu(s.sun), sunUp)
        fjordU[4] = SIMD4(sunColour, 0)
        fjordU[5] = SIMD4(SkyLayer.enu(s.moon), moonUp)
        fjordU[6] = SIMD4(auroraLight, aurora)
        fjordU[7] = SIMD4(s.zenith * 0.7 + s.horizon * 0.3, cloud)
        fjordU[8] = SIMD4(phase1, phase2, 0, 0)

        // The view's frame (level ahead and across, as the shader takes them) and projection.
        let ahead2 = simd_normalize(SIMD2(cam.forward.x, cam.forward.y))
        let ahead = SIMD3<Float>(ahead2.x, ahead2.y, 0), across = SIMD3<Float>(ahead2.y, -ahead2.x, 0)
        func direction(phi: Float, alt: Float) -> SIMD3<Float> {
            let level = cos(alt)
            let flat: SIMD3<Float> = ahead * (level * cos(phi)) + across * (level * sin(phi))
            return flat + SIMD3<Float>(0, 0, sin(alt))
        }
        func project(_ d: SIMD3<Float>) -> SIMD2<Float>? {
            let z = simd_dot(d, cam.forward)
            guard z > 1e-3 else { return nil }
            return SIMD2(simd_dot(d, cam.right) / (z * cam.tanH), simd_dot(d, cam.up) / (z * cam.tanV))
        }
        func clip(_ q: SIMD3<Float>) -> SIMD4<Float> {
            SIMD4(simd_dot(q, cam.right) / cam.tanH, simd_dot(q, cam.up) / cam.tanV, 0, max(simd_dot(q, cam.forward), 1e-3))
        }

        // The village: warm windows on the far left shore from dusk, each with its reflection (and pillar in diamond
        // dust); a slow, faint flicker.
        villageInstances.removeAll(keepingCapacity: true)
        villagePoints.removeAll(keepingCapacity: true)
        let eye = Self.eyeHeight
        if villageOn > 0 {
            let len = 0.006 + 0.05 * min(max(s.wind, 0), 1) + 0.02 * swell
            let pillar = min(max(s.pillar, 0), 1)
            for (i, l) in Self.villageLayout.prefix(Self.villageCount(Double(villageAmount))).enumerated() {
                let r = Self.wallDistance(l.phi) * 1.03
                let alt = atan((l.height - eye) / r), mirror = atan((l.height + eye) / r)
                let radius: Float = 0.0026
                let flicker = 0.9 + 0.1 * sin(time * (1.3 + 0.37 * Float(i)) + Float(i) * 2.1)
                let strength = (0.45 + 0.55 * villageAmount) * flicker
                let colour = SIMD3<Float>(1.0, 0.72, 0.42) * strength
                guard let at = project(direction(phi: l.phi, alt: alt)) else { continue }
                // The quad: the glow's halo across; up to the pillar's reach above, down to the reflection's end (or the
                // pillar's) below: from the light (alt up) past the horizon to its mirror point (mirror down), then on
                // until the streak has faded (5 × its length).
                let half: Float = 0.036
                let above: Float = pillar > 0.001 ? 0.45 : 0.036
                let below: Float = max(alt + mirror + 5 * len, pillar > 0.001 ? 0.45 : 0.036)
                var lo = SIMD2<Float>(repeating: 9), hi = SIMD2<Float>(repeating: -9)
                for (dp, da) in [(-half, above), (half, above), (-half, -below), (half, -below), (Float(0), above), (Float(0), -below)] {
                    if let c = project(direction(phi: l.phi + dp, alt: alt + da)) { lo = simd_min(lo, c); hi = simd_max(hi, c) }
                }
                guard lo.x < hi.x, lo.y < hi.y else { continue }
                let pad = (hi - lo) * 0.08
                lo = simd_max(lo - pad, SIMD2(repeating: -1.05)); hi = simd_min(hi + pad, SIMD2(repeating: 1.05))
                villageInstances.append(VillageInstance(rect: SIMD4(lo.x, lo.y, hi.x, hi.y),
                                                        dir: SIMD4(direction(phi: l.phi, alt: alt), radius),
                                                        colour: SIMD4(colour, mirror)))
                villagePoints.append(at)
            }
        }
        villageLightCount = villageInstances.count

        // Floes: far ones first (each draws its side, then its top), fading out where they wrap behind the view's edges.
        floeInstances.removeAll(keepingCapacity: true)
        let ordered = frame.floes.enumerated().sorted { $0.element.depth > $1.element.depth }
        for (index, fl) in ordered {
            let pt = Self.floePoint(x: fl.x, depth: fl.depth, tanH: cam.tanH)
            let seed = Float(index) * 0.618
            let halfLength = 0.8 + 2.2 * min(max(fl.size, 0), 1)
            let halfWidth = halfLength * (0.5 + 0.3 * (seed * 7.31 - floor(seed * 7.31)))
            let fade = Self.smoothF(0, 0.08, fl.x) * (1 - Self.smoothF(0.92, 1, fl.x))
            floeInstances.append(SIMD4(pt.s, pt.f, halfLength, halfWidth))
            floeInstances.append(SIMD4(fl.angle, fade, seed, 0))
        }
        floeCount = frame.floes.count

        // The jetty: rails either side running out to its end, 4.5 m ahead, with snow along them and on the posts.
        railParts.removeAll(keepingCapacity: true)
        jettyPosts.removeAll(keepingCapacity: true)
        func point(_ x: Float, _ f: Float, _ z: Float) -> SIMD3<Float> {
            let flat: SIMD3<Float> = across * x + ahead * f
            return flat + SIMD3<Float>(0, 0, z)
        }
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, kind: Float, length: Float, seed: Float) {
            railParts.append(RailPart(p0: clip(a), p1: clip(b), p2: clip(c), p3: clip(d), info: SIMD4(kind, length, seed, 0)))
        }
        let deck: Float = 1.0 - eye, railTop: Float = -0.6, railLow: Float = -0.74
        for side: Float in [-1, 1] {
            let sx = side * 1.15
            add(point(sx, 1.4, railLow), point(sx, 4.5, railLow), point(sx, 1.4, railTop), point(sx, 4.5, railTop),
                kind: 0, length: 3.1, seed: side * 3)
            add(point(sx, 1.4, railTop), point(sx, 4.5, railTop), point(sx, 1.4, railTop + 0.12), point(sx, 4.5, railTop + 0.12),
                kind: 1, length: 3.1, seed: side * 5)
            for f: Float in [2.5, 3.5, 4.5] {
                let w: Float = 0.06, front = f - 0.06
                add(point(sx - w, front, deck), point(sx + w, front, deck), point(sx - w, front, railTop + 0.03),
                    point(sx + w, front, railTop + 0.03), kind: 0, length: 0.12, seed: f + side)
                add(point(sx - w - 0.015, front, railTop + 0.03), point(sx + w + 0.015, front, railTop + 0.03),
                    point(sx - w - 0.015, front, railTop + 0.1), point(sx + w + 0.015, front, railTop + 0.1),
                    kind: 1, length: 0.15, seed: f * 3 + side)
            }
            if let top = project(simd_normalize(point(sx, 4.44, railTop + 0.03))) { jettyPosts.append(top) }
        }

        // Keys: ice-blue glass along the jetty's edge, glowing where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottom: Float = -0.995, gap: Float = 0.0015
            let light = max(sunUp, 0.4 * moonUp) * 0.3
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.55, bloomThreshold: 0.9,
            dof: quality == .lite ? 0 : 0.12, focusDepth: 0.45,
            grade: 0, grain: 0.025, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) - 0.08 * night,
            time: Float(frame.time.truncatingRemainder(dividingBy: 3600)), quality: quality)
    }

    /// The NDC point of a place on the aurora's curtain as drawn this frame: `position` along the band in the shader's
    /// units (0…1) and `above` degrees over the band's base (its slow wobble aside); nil behind the camera (tests).
    func bandPoint(position: Float, above: Float) -> SIMD2<Float>? {
        let u = sky.uniforms
        let pole = simd_normalize(SIMD2(u[14].x, u[14].y))
        let P = SIMD3<Float>(pole.x, pole.y, 0), W = SIMD3<Float>(pole.y, -pole.x, 0)
        let A = min(max(u[14].z, 0.5), 89) * .pi / 180
        let B: SIMD3<Float> = P * cos(A) + SIMD3<Float>(0, 0, sin(A))
        let U: SIMD3<Float> = SIMD3<Float>(0, 0, cos(A)) - P * sin(A)
        let along = (position - 0.5) * .pi, h = above * .pi / 180
        let base: SIMD3<Float> = B * cos(along) + W * sin(along)
        let d: SIMD3<Float> = base * cos(h) + U * sin(h)
        let right = SIMD3(u[0].x, u[0].y, u[0].z), up = SIMD3(u[1].x, u[1].y, u[1].z), forward = SIMD3(u[2].x, u[2].y, u[2].z)
        let z = simd_dot(d, forward)
        guard z > 1e-3 else { return nil }
        return SIMD2(simd_dot(d, right) / (z * u[0].w), simd_dot(d, up) / (z * u[1].w))
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        if showWarp { warp.draw(e) }

        // The walls and the water (mirroring the sky: the stars bound at texture 0).
        let skyU = sky.uniforms
        func bindUniforms() {
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            fjordU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        }
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        bindUniforms()
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !villageInstances.isEmpty {
            e.setRenderPipelineState(village)
            villageInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            bindUniforms()
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: villageInstances.count)
        }

        if !floeInstances.isEmpty {
            e.setRenderPipelineState(floe)
            floeInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            skyU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            bindUniforms()
            // Two float4s per floe, two layers each (its side, then its top): one instance per float4.
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: floeInstances.count)
        }

        // Snow and rain, diamond dust's crystals (the weather layer binds its own buffers).
        weather.draw(e)

        if !railParts.isEmpty {
            e.setRenderPipelineState(rail)
            railParts.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            bindUniforms()
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: railParts.count)
        }

        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            bindUniforms()
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
