import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Bedroom Window at Dawn (spec §9.1, §7.4): the Living Sky over rooftops, chimneys and a street waking up
/// through a painted sash window (Galaxy Warp over the sky when chosen), weather and drops on the glass, the Window
/// Kit's glass and sashes, the room with the window's light on the floor, light shafts through the panes, sheer
/// curtains moving in the breeze and your notes' puffs, dust motes, fairy lights and soft peach keys.
@MainActor
final class BedroomDawnRenderer: ThemeRenderer {
    /// Dust motes drawn (fewer on Smooth).
    static func moteBudget(_ q: QualityLevel) -> Int { CurtainLight.moteBudget(q) }
    static func patchBudget(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }
    static let fieldSeed: UInt64 = 0xBED5
    /// Degrees the view turns left of a low sun, so it rises right of the middle bar and the beams slant.
    static let sunOffset = 10.0

    /// The sash window: two panes across, three up (two sashes), above the sill; the floor shows below the wall.
    static func layout(aspect: Float, keyTop: Float) -> (window: WindowSpec, floorLine: Float) {
        let frameWidth: Float = 0.045
        let floorLine = keyTop + 0.24
        let bottom = floorLine + 0.32
        let top = min(0.86, 0.95 - frameWidth * aspect)
        let width = min(1.0, 1.15 * (top - bottom) / max(aspect, 0.2))
        let spec = WindowSpec(columns: 2, rows: 3, bar: 0.014, rect: SIMD4(-width / 2, bottom, width / 2, top),
                              material: .paintedSash, frameWidth: frameWidth)
        return (spec, floorLine)
    }

    private let sky: SkyLayer
    let weather: WeatherLayer
    let warp: WarpLayer
    let glass: WindowGlassLayer
    private var showWarp = false
    private let scene: SkyPipeline
    private let room, shafts, curtain, sprites, keys: MTLRenderPipelineState
    private var bedU = [SIMD4<Float>](repeating: .zero, count: 10 + 3 + 19)
    private var keyInstances: [KeyInstance] = []
    private var spriteData: [SIMD4<Float>] = []
    private var curtainData: [SIMD4<Float>] = []
    private let curtainIndices: MTLBuffer
    private let curtainIndexCount: Int
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    private var spriteOffset = 0, spriteCount = 0
    private var limiter = FlashLimiter()
    private var quality: QualityLevel = .high
    private(set) var viewAzimuth: Double?
    private var spec: WindowSpec?
    private var birds: [(x: Float, y: Float, phase: Float, flying: Bool, age: Float, stay: Float, vx: Float)] = []
    private var birdClock: Float = 6
    private var rng = SeededRandom(seed: 0xB1_2D5)
    private(set) var post = PostSettings()
    /// The shafts' strength, the motes' and fairy lights' glints, and the glow's swell after the flash limiter.
    private(set) var shaftOut: Float = 0
    private(set) var glintOut: Float = 0
    private(set) var glowOut: Float = 0
    /// Curtain vertices drawn this frame (two panels).
    private(set) var curtainVertexCount = 0
    /// Instance and vertex buffers made so far: a ring of three, grown only when too small.
    private(set) var bufferAllocations = 0
    /// The glass in NDC (x0, y0, x1, y1), the floor's top edge, and the beams' screen direction.
    private(set) var windowRect = SIMD4<Float>(-0.4, -0.2, 0.4, 0.86)
    private(set) var floorLine: Float = -0.5
    private(set) var beamDirection = SIMD2<Float>(0, -1)
    /// Where the curtains' points land on screen (tests check they stay inside the frame).
    private(set) var curtainPoints: [SIMD2<Float>] = []
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device), let gw = WarpLayer(device: device),
              let g = WindowGlassLayer(device: device),
              let lib = try? device.makeLibrary(source: BedroomDawnShaders.source, options: nil) else { return nil }
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
        guard let sc = SkyPipeline(build: { make("bed_glass_vertex", "bed_scene_fragment", .premultiplied, storms: $0) }),
              let rm = make("bed_full_vertex", "bed_room_fragment", .opaque),
              let sh = make("bed_full_vertex", "bed_shaft_fragment", .additive, writesDepth: false),
              let cu = make("bed_curtain_vertex", "bed_curtain_fragment", .premultiplied, writesDepth: false),
              let sp = make("bed_sprite_vertex", "bed_sprite_fragment", .additive, writesDepth: false),
              let k = make("bed_keys_vertex", "bed_keys_fragment", .opaque) else { return nil }
        // The curtains' triangles never change: two 24 × 32 grids.
        let cols = 24, rows = 32
        var idx: [UInt16] = []
        for panel in 0..<2 {
            let base = panel * cols * rows
            for j in 0..<(rows - 1) {
                for i in 0..<(cols - 1) {
                    let a = UInt16(base + j * cols + i), b = a + 1, c = a + UInt16(cols), d = c + 1
                    idx += [a, c, b, b, c, d]
                }
            }
        }
        guard let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared) else { return nil }
        curtainIndices = ib
        curtainIndexCount = idx.count
        sky = s; weather = w; warp = gw; glass = g
        scene = sc; room = rm; shafts = sh; curtain = cu; sprites = sp; keys = k
        sky.verticalFOV = 50
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let field = FrostField(seed: Self.fieldSeed, columns: 2, rows: 3, bar: 0.014)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.glass.setField(field) } }
        }
    }

    /// Waits (running the main run loop) until the frost field has grown; for previews and tests.
    @discardableResult
    func awaitField(timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !glass.hasField, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return glass.hasField
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }

    /// Window units (x across the glass, y up from its bottom, z toward us) to NDC, with a little perspective.
    private func project(_ p: SIMD3<Float>, spec: WindowSpec) -> SIMD2<Float> {
        let w = spec.rect.z - spec.rect.x, h = spec.rect.w - spec.rect.y
        let centre = SIMD2<Float>((spec.rect.x + spec.rect.z) / 2, (spec.rect.y + spec.rect.w) / 2)
        let flat = SIMD2<Float>(spec.rect.x + p.x * w, spec.rect.y + p.y * h)
        let grown = centre + (flat - centre) * (1 + 0.25 * max(0, p.z))
        return simd_clamp(grown, SIMD2<Float>(repeating: -0.995), SIMD2<Float>(repeating: 0.995))
    }

    func update(_ frame: BedroomFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        self.quality = quality
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(min(max(dt, 0), 0.1))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let (spec, floor) = Self.layout(aspect: aspect, keyTop: keyTop)
        windowRect = spec.rect
        floorLine = floor
        self.spec = spec
        let horizonY = spec.rect.y + (spec.rect.w - spec.rect.y) * 0.42

        // A held light: face its (low) sun, which sits a little right of the middle bar so its beams slant down across
        // the room. Following the sky: turn toward the morning sun while it's low in the east, gliding back to east as
        // it climbs, and look east the rest of the day, so the view never swings round.
        let east = 90.0
        let sunTarget = s.sun.azimuth - Self.sunOffset
        let target: Double
        if SkyHold(rawValue: p.choice("light.hold")) ?? .follow != .follow {
            target = sunTarget
        } else {
            let eastness = Self.smooth(0, 0.35, sin(s.sun.azimuth * .pi / 180))
            let low = Self.smooth(-14, -8, s.sun.altitude) * (1 - Self.smooth(15, 30, s.sun.altitude))
            target = east + ((sunTarget - east + 540).truncatingRemainder(dividingBy: 360) - 180) * eastness * low
        }
        if let az = viewAzimuth {
            let diff = (target - az + 540).truncatingRemainder(dividingBy: 360) - 180
            viewAzimuth = az + diff * (1 - exp(-min(dt, 0.1) / 4))
        } else {
            viewAzimuth = target
        }
        sky.viewAzimuth = viewAzimuth
        sky.horizonY = horizonY
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .glass)
        showWarp = frame.warp != nil
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        if let w = frame.warp {
            warp.centre = SIMD2(0, horizonY + (spec.rect.w - horizonY) * 0.5)
            warp.update(w, trails: 0.6, nebula: 0.7, intensity: sparkleScale, quality: quality, size: size, dt: dt, time: Float(frame.time))
        }

        // Light: night, the sun through the window, the glow (through the limiter: gentle halves its swell).
        let night = Float(1 - Self.smooth(-8, -2, s.sun.altitude))
        let sunUp = Float(Self.smooth(-3, 6, s.sun.altitude))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)
        let sunDir = SkyLayer.enu(s.sun)
        let ls = SIMD3<Float>(simd_dot(sunDir, cam.right), simd_dot(sunDir, cam.up), simd_dot(sunDir, cam.forward))
        let ahead = min(max(ls.z * 3, 0), 1)
        // Direct sun comes through once the disk clears the rooftops (most striking just after sunrise).
        let disk = Float(Self.smooth(-1.5, 2.5, s.sun.altitude))
        let direct = disk * ahead * (1 - 0.8 * s.cloudCover) * (1 - 0.5 * s.mist)
        limiter.gentle = gentle
        let exposure = MoodLook.exposure(frame.mood) * weather.exposureBoost * (1 + 0.12 * frame.glow * sparkleScale)
        let limited = limiter.limit(exposure: exposure, sparkle: 1, dt: dt)
        glowOut = frame.glow * limited.sparkle
        let setting = Float(p.number("light"))
        shaftOut = direct * setting * (0.45 + 0.55 * glowOut)
        let motesSetting = Float(p.number("motes"))
        let fairyLevel = Float(p.number("fairy")) * Float(Self.smooth(2, -1, s.sun.altitude))
        let brightestGlint = frame.motes.prefix(Self.moteBudget(quality)).map(\.glint).max() ?? 0
        glintOut = limited.sparkle * max(0.3, max(brightestGlint, frame.fairy.max() ?? 0))

        // The beams: down from the panes and sideways with the sun; the patch on the floor stretches as the sun sinks.
        let v = SIMD2<Float>(-ls.x * 0.9, -(0.25 + 0.75 * min(max(ls.y * 3, 0), 1)))
        beamDirection = simd_normalize(v)
        let patchDepth = min(max(0.5 / max(ls.y, 0.08), 0.4), 4)
        let outside = (s.zenith + s.horizon) * 0.55 + SIMD3<Float>(repeating: 0.2 * sunUp)
        let tint = frame.tint

        // The glass: drops after rain, morning condensation, frost on cold days (and Frost Grow's patches).
        let glassW = spec.rect.z - spec.rect.x, glassH = spec.rect.w - spec.rect.y
        let toWidth = glassH / max(glassW * aspect, 1e-3)
        let patches = FrostGrow.visible(frame.patches, limit: Self.patchBudget(quality))
            .map { GlassPatch(x: $0.x, y: $0.y, radius: $0.radius * toWidth, warmth: $0.warmth) }
        let morning: Float = s.hourOfDay < 11 || BedroomDawnModel.heldDawn(p) ? 1 : 0.4
        let condensation = min(0.6, 0.12 + 0.6 * s.frost) * morning
        let roomLight = SIMD3<Float>(1.0, 0.78, 0.55) * (0.15 + 0.4 * fairyLevel * night) + outside * 0.3
        glass.update(spec: spec, frost: frame.frostLevel, patches: patches, condensation: condensation,
                     wetDrips: s.rain < 0.05 ? s.wetness : 0, snow: s.snow,
                     reflection: SIMD4(1.0, 0.75, 0.45, 0.05 * night * fairyLevel), glint: SIMD4(roomLight, max(sunUp, 0.3)),
                     quality: quality, dt: dt, outsideLight: outside, aspect: aspect, sparkle: limited.sparkle)

        // Birds: now and then one lands on the tree or a roof, hops about, then flies off.
        updateBirds(dt: fdt, horizon: horizonY, halfW: 0.5 * glassW * aspect)

        // Uniforms.
        let qualityCode: Float = quality == .lite ? 0 : 1
        bedU[0] = SIMD4(keyTop, aspect, horizonY, time)
        bedU[1] = spec.rect
        bedU[2] = SIMD4(night, glowOut, setting, direct)
        bedU[3] = SIMD4(frame.streetLamp, Float(frame.litWindows), s.wetness, s.mist)
        let openCode: Float = frame.windowOpen ? 1 : 0
        bedU[4] = SIMD4(spec.frameWidth, qualityCode, limited.sparkle, openCode)
        bedU[5] = SIMD4(v.x, v.y, 1.0, s.frost)
        bedU[6] = SIMD4(outside, min(1, sunUp * (1 - 0.6 * s.cloudCover)))
        bedU[7] = SIMD4(tint, motesSetting)
        bedU[8] = SIMD4(s.wind, fairyLevel, floor, 0.1)
        bedU[9] = SIMD4(patchDepth, Float(min(19, spec.bars().count)), 0, 0)
        for i in 0..<3 {
            if i < birds.count {
                let b = birds[i]
                bedU[10 + i] = SIMD4(b.x, b.y, b.phase, b.flying ? 1 : 0)
            } else {
                bedU[10 + i] = SIMD4(-10, 0, 0, 0)
            }
        }
        let bars = spec.bars()
        for i in 0..<19 { bedU[13 + i] = i < bars.count ? bars[i] : .zero }

        // Curtains: each cloth point projected, with a normal from its neighbours and how folded it is.
        curtainData.removeAll(keepingCapacity: true)
        curtainPoints.removeAll(keepingCapacity: true)
        let cols = 24, rows = 32
        for panel in [frame.curtains.left, frame.curtains.right] where panel.count == cols * rows {
            for j in 0..<rows {
                for i in 0..<cols {
                    let k = j * cols + i
                    let pt = panel[k]
                    let du = panel[j * cols + min(i + 1, cols - 1)] - panel[j * cols + max(i - 1, 0)]
                    let dv = panel[min(j + 1, rows - 1) * cols + i] - panel[max(j - 1, 0) * cols + i]
                    var n = simd_cross(du, dv)
                    let len = simd_length(n)
                    n = len > 1e-6 ? n / len : SIMD3(0, 0, 1)
                    let ndc = project(pt, spec: spec)
                    curtainPoints.append(ndc)
                    let fold = min(1, abs(n.x) * 1.5)
                    curtainData.append(SIMD4(ndc.x, ndc.y, pt.z, fold))
                    curtainData.append(SIMD4(n.x, n.y, n.z, Float(i) / Float(cols - 1)))
                }
            }
        }
        curtainVertexCount = curtainData.count / 2

        // Motes (lit where a shaft passes) and the fairy lights on the rod.
        spriteData.removeAll(keepingCapacity: true)
        let moteBudget = Self.moteBudget(quality)
        let wallH = spec.rect.w - floor
        for m in frame.motes.prefix(moteBudget) {
            let flat = SIMD2<Float>(spec.rect.x + m.position.x * glassW, floor + m.position.y * wallH)
            let centre = SIMD2<Float>((spec.rect.x + spec.rect.z) / 2, (spec.rect.y + spec.rect.w) / 2)
            let pos = centre + (flat - centre) * (1 + 0.6 * m.position.z)
            var lit: Float = 0
            for step in 0..<6 {
                let sAlong = (Float(step) + 0.5) / 6
                let q = pos - v * sAlong
                let wx = (q.x - spec.rect.x) / glassW, wy = (q.y - spec.rect.y) / glassH
                if wx > 0, wx < 1, wy > 0, wy < 1 { lit = max(lit, 1 - sAlong) }
            }
            // Dust shows in the beams against the dim room; over the bright glass it all but disappears.
            let overGlass = pos.x > spec.rect.x && pos.x < spec.rect.z && pos.y > spec.rect.y && pos.y < spec.rect.w
            let bright = motesSetting * (0.06 + 0.7 * lit * direct * (0.4 + 0.6 * glowOut)) * (overGlass ? 0.3 : 1)
                * (1 + 2.5 * m.glint * limited.sparkle)
            guard bright > 0.01 else { continue }
            let size: Float = 0.0035 + 0.004 * m.position.z
            spriteData.append(SIMD4(pos.x, pos.y, size, min(bright, 2)))
            spriteData.append(SIMD4(1.0, 0.92, 0.8, 0))
        }
        let rodY = spec.rect.w + spec.frameWidth * aspect + 0.035
        for i in 0..<CurtainLight.fairyCount {
            let t = (Float(i) + 0.5) / Float(CurtainLight.fairyCount)
            let x = spec.rect.x - 0.3 * glassW + t * glassW * 1.6
            let y = rodY - 0.035 * sin(t * .pi * 3).magnitude
            let twinkle = i < frame.fairy.count ? frame.fairy[i] : 0
            let flicker = 0.85 + 0.15 * sin(time * (1.3 + Float(i) * 0.37) + Float(i))
            let bright = fairyLevel * flicker * 0.9 + twinkle * 1.2 * limited.sparkle
            guard bright > 0.01 else { continue }
            let colour: SIMD3<Float> = i % 3 == 0 ? SIMD3(1.0, 0.62, 0.35) : (i % 3 == 1 ? SIMD3(1.0, 0.8, 0.5) : SIMD3(1.0, 0.7, 0.62))
            spriteData.append(SIMD4(min(max(x, -0.99), 0.99), min(y, 0.99), 0.012, bright))
            spriteData.append(SIMD4(colour, 1))
        }
        spriteCount = spriteData.count / 2

        // This frame's curtain vertices and sprites, in the next slot of the ring (grown only when too small).
        slot = (slot + 1) % ring.count
        let curtainBytes = curtainData.count * MemoryLayout<SIMD4<Float>>.stride
        let spriteBytes = spriteData.count * MemoryLayout<SIMD4<Float>>.stride
        spriteOffset = (curtainBytes + 255) / 256 * 256
        let total = spriteOffset + spriteBytes
        if total > 0 {
            if (ring[slot]?.length ?? 0) < total {
                ring[slot] = glassDevice.makeBuffer(length: max(total, 96 * 1024), options: .storageModeShared)
                bufferAllocations += 1
            }
            if let buf = ring[slot] {
                curtainData.withUnsafeBytes { if curtainBytes > 0 { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: curtainBytes) } }
                spriteData.withUnsafeBytes { if spriteBytes > 0 { (buf.contents() + spriteOffset).copyMemory(from: $0.baseAddress!, byteCount: spriteBytes) } }
            }
        }

        // Keys: pale keys in the morning light, soft peach where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottomY: Float = -0.995, gap: Float = 0.0015
            let light = 0.25 + 0.5 * sunUp + 0.15 * glowOut
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottomY) * 0.62 : bottomY
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.6, bloomThreshold: 0.95,
            dof: quality == .lite ? 0 : 0.08, focusDepth: 0.05,
            grade: 0, grain: 0.02, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(frame.mood) + 0.05 * glowOut,
            time: time, quality: quality)
    }

    private var glassDevice: MTLDevice { curtainIndices.device }

    /// The panes in NDC (x0, y0, x1, y1), for tests.
    func glassPanesNDC() -> [SIMD4<Float>] {
        guard let spec else { return [] }
        return spec.panes().map { p in
            let a = spec.ndc(SIMD2(p.x, p.y)), b = spec.ndc(SIMD2(p.z, p.w))
            return SIMD4(a.x, a.y, b.x, b.y)
        }
    }

    private func updateBirds(dt: Float, horizon: Float, halfW: Float) {
        birdClock -= dt
        if birdClock <= 0, birds.count < 3 {
            // Land on the tree (right) or a rooftop.
            let onTree = rng.unit() < 0.6
            let x = onTree ? halfW * rng.range(0.6, 0.95) : halfW * rng.range(-0.9, 0.4)
            let y = onTree ? horizon + rng.range(0.3, 0.55) : horizon + rng.range(0.12, 0.17)
            birds.append((x, y, 0, false, 0, rng.range(5, 20), 0))
            birdClock = rng.range(12, 30)
        }
        for i in birds.indices {
            var b = birds[i]
            b.age += dt
            if !b.flying {
                // Now and then a hop.
                if rng.unit() < dt * 0.4 { b.x += rng.range(-0.02, 0.02) }
                if b.age > b.stay { b.flying = true; b.vx = rng.unit() < 0.5 ? -0.5 : 0.5 }
            } else {
                b.phase += dt * 22
                b.x += b.vx * dt
                b.y += 0.25 * dt
            }
            birds[i] = b
        }
        birds.removeAll { $0.flying && ($0.y > horizon + 1.2 || abs($0.x) > halfW + 0.3) }
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)   // the supercell's impostor, before the frame's passes
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              var e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        func bindUniforms(_ e: MTLRenderCommandEncoder, vertex: Bool = false) {
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            sky.bindStars(e)
            bedU.withUnsafeBytes {
                e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                if vertex { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            }
        }
        // Outside: the sky (and the warp), the street and houses, then the weather.
        sky.draw(e)
        if showWarp { warp.draw(e) }
        e.setRenderPipelineState(scene.state(storms: sky.storms))
        bindUniforms(e, vertex: true)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        weather.draw(e)

        var blur: MTLTexture?
        if quality != .lite, let hdr = stack.hdrTarget {
            e.endEncoding()
            blur = glass.makeBlur(from: hdr, commandBuffer: cb)
            guard let again = stack.scenePassContinuing(), let next = cb.makeRenderCommandEncoder(descriptor: again) else { return }
            e = next
        }
        glass.drawGlass(e, blur: blur)
        glass.drawFrame(e)

        // The room, the shafts through it, the curtains, the motes and fairy lights, then the keys.
        e.setRenderPipelineState(room)
        bindUniforms(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.setRenderPipelineState(shafts)
        bindUniforms(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if curtainVertexCount > 0, let buf = ring[slot] {
            e.setRenderPipelineState(curtain)
            e.setVertexBuffer(buf, offset: 0, index: 0)
            bindUniforms(e)
            e.drawIndexedPrimitives(type: .triangle, indexCount: curtainIndexCount, indexType: .uint16, indexBuffer: curtainIndices, indexBufferOffset: 0)
        }
        if spriteCount > 0, let buf = ring[slot] {
            e.setRenderPipelineState(sprites)
            e.setVertexBuffer(buf, offset: spriteOffset, index: 0)
            bedU.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: spriteCount)
        }
        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            bindUniforms(e)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
