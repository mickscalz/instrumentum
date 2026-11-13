import Metal
import simd
import CoreGraphics
import InStrumCore

/// Draws a GardenFrame into the render stack.
///
/// Excitement (Fire & Neon spec §5.5): the swarm is the model's butterflies; its bloom of light rides on the exposure
/// through the `FlashLimiter` (a glow under gentle visuals) and on the sun's rays; the hummingbird is one more sprite
/// (style 9), and rain on the glasshouse's glass is a fourth kind of the stateless particles (drops clinging and sliding).
@MainActor
final class ButterflyRenderer: ThemeRenderer {
    struct Sprite { var pos: SIMD4<Float>; var a: SIMD4<Float>; var b: SIMD4<Float> }
    struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    static let screenSize: Float = 0.028
    static let particleCounts: [QualityLevel: (pollen: Int, petals: Int, fireflies: Int)] = [
        .lite: (300, 60, 40), .high: (900, 180, 90), .ultra: (2400, 400, 160),
    ]
    /// Sun-shaft march steps and sky noise detail per quality (Smooth skips the march).
    static let shaftSteps: [QualityLevel: Int] = [.lite: 0, .high: 10, .ultra: 28]
    static let noiseOctaves: [QualityLevel: Int] = [.lite: 3, .high: 4, .ultra: 5]
    static let skies: [String: (top: SIMD3<Float>, mid: SIMD3<Float>, horizon: SIMD3<Float>, night: Float)] = [
        "Dawn": (SIMD3(0.35, 0.42, 0.72), SIMD3(0.9, 0.62, 0.7), SIMD3(1.3, 0.85, 0.7), 0),
        "Morning": (SIMD3(0.25, 0.5, 0.95), SIMD3(0.55, 0.75, 1.0), SIMD3(0.95, 0.98, 1.0), 0),
        "Golden Hour": (SIMD3(0.30, 0.38, 0.70), SIMD3(0.95, 0.62, 0.55), SIMD3(1.5, 0.95, 0.45), 0),
        "Dusk": (SIMD3(0.12, 0.10, 0.30), SIMD3(0.6, 0.3, 0.45), SIMD3(1.3, 0.55, 0.35), 0),
        "Moonlight": (SIMD3(0.01, 0.02, 0.07), SIMD3(0.03, 0.06, 0.15), SIMD3(0.08, 0.14, 0.28), 1),
    ]
    static let grades = ["Natural", "Warm Film", "Cool Film", "Dreamy", "Vivid"]
    static let finishes = ["Lacquer", "Satin", "Ivory", "Brushed metal", "Gold", "Pearl"]

    private let device: MTLDevice
    private let sky, wings, blooms, trails, particles, keys: MTLRenderPipelineState
    /// High and Ultra: the sun's shafts through the leaves (a march toward the sun) drawn at half resolution into
    /// `shaftTexture` before the sky, which reads them back filtered. Made once a size.
    private let shafts: MTLRenderPipelineState
    private var shaftTexture: MTLTexture?
    private(set) var shaftAllocations = 0
    private var uniforms = [SIMD4<Float>](repeating: .zero, count: 11)
    private var butterflySprites: [Sprite] = []
    private var bloomSprites: [Sprite] = []
    private var trailSprites: [Sprite] = []
    private var keyInstances: [KeyInstance] = []
    private var particleCount = 0
    private var history: [Int: [SIMD3<Float>]] = [:]
    private var limiter = FlashLimiter()
    private(set) var post = PostSettings()
    private var primed = false
    private var bloomGlow = ExcitementGlow()
    /// The hummingbird's sprite style (the butterfly fragment draws it instead of a wing).
    static let hummingbirdStyle: Float = 9
    /// Drops on the glass while it rains (fewer on Smooth).
    static func dropCount(_ q: QualityLevel) -> Int { q == .lite ? 60 : 140 }
    /// Excitement as drawn (tests read them): the bloom's light after the limiter and what it asked for, the drops on
    /// the glass, whether the hummingbird is drawn.
    private(set) var bloomOut: Float = 0
    private(set) var bloomRequest: Float = 0
    private(set) var dropsDrawn = 0
    private(set) var hummingbirdDrawn = false
    private(set) var butterfliesDrawn = 0
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: ButterflyShaders.source, options: nil) else { return nil }
        enum Blend { case none, alpha, add }
        func make(_ v: String, _ f: String, _ blend: Blend, writeDepth: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if !writeDepth { d.colorAttachments[1].writeMask = [] }
            let c = d.colorAttachments[0]!
            switch blend {
            case .none: break
            case .alpha:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .add:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let s = make("sky_vertex", "sky_fragment", .none, writeDepth: true),
              let w = make("sprite_vertex", "butterfly_fragment", .alpha, writeDepth: true),
              let b = make("sprite_vertex", "bloom_fragment", .alpha, writeDepth: true),
              let t = make("sprite_vertex", "trail_fragment", .add, writeDepth: false),
              let p = make("particle_vertex", "particle_fragment", .add, writeDepth: false),
              let k = make("keys_vertex", "keys_fragment", .none, writeDepth: true) else { return nil }
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "sky_vertex")
        sd.fragmentFunction = lib.makeFunction(name: "shaft_fragment")
        sd.colorAttachments[0].pixelFormat = .r16Float
        guard let sh = try? device.makeRenderPipelineState(descriptor: sd) else { return nil }
        self.device = device
        sky = s; wings = w; blooms = b; trails = t; particles = p; keys = k; shafts = sh
    }

    func update(_ f: GardenFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        limiter.gentle = gentle
        // The swarm's bloom of light rides on the exposure, through the limiter (primed on the garden's own, so arriving
        // is never a flash); under gentle visuals it is a glow. Rain on the glass dims the light a little.
        let rain = ExcitementGlow.unit(f.rainOnGlass)
        let base = f.exposure * (1 - 0.12 * rain)
        if !primed {
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: base, sparkle: f.pollen, dt: 1) }
        }
        let request = ExcitementGlow.unit(f.momentLight)
        let asked = ExcitementGlow.ask(request, gentle: gentle, scale: 0.3)
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: f.pollen, dt: dt)
        let passed = ExcitementGlow.passed(limited: limited.exposure, base: base, asked: asked)
        bloomRequest = request
        bloomOut = bloomGlow.update(request: request, passed: passed, gentle: gentle, dt: dt)
        let rays = f.rays * (1 - 0.6 * rain) + 0.6 * bloomOut
        let keysShow = p.number("keys.show") > 0.5
        let keyTop = keysShow ? Float(p.number("keys.height")) : 0
        let sky = Self.skies[f.timeOfDay] ?? Self.skies["Golden Hour"]!
        let sunX = Float(0.15 + 0.7 * p.number("sun.angle"))
        let sunY = keyTop + (1 - keyTop) * (0.3 + f.sunHeight * 0.75)
        let counts = Self.particleCounts[quality]!
        let petals = f.petals > 0.01 ? counts.petals : 0
        let fireflies = f.fireflies > 0.01 ? counts.fireflies : 0
        let drops = rain > 0.01 ? Self.dropCount(quality) : 0
        dropsDrawn = drops
        particleCount = counts.pollen + petals + fireflies + drops
        let glowColor = p.color("keys.glowColor")
        let finish = Float(Self.finishes.firstIndex(of: p.choice("keys.finish")) ?? 0)
        uniforms = [
            SIMD4(Float(size.width), Float(size.height), Float(f.time), keyTop),
            SIMD4(sunX, sunY, rays, f.mist),
            SIMD4(sky.top, sky.night),
            SIMD4(sky.mid, 0),
            SIMD4(sky.horizon, Float(p.number("foliage"))),
            SIMD4(f.breeze.x, limited.sparkle, f.petals, f.fireflies),
            SIMD4(f.cameraZoom, f.cameraOffset.x, f.cameraOffset.y, Float(p.number("parallax"))),
            SIMD4(Float(p.number("wings.iridescence")), Float(p.number("wings.shimmer")), Float(p.number("trail.glow")), keysShow ? 1 : 0),
            SIMD4(Float(counts.pollen), Float(petals), Float(fireflies), limited.exposure),
            SIMD4(Float(glowColor.r), Float(glowColor.g), Float(glowColor.b), finish),
            SIMD4(Float(Self.shaftSteps[quality] ?? 0), Float(Self.noiseOctaves[quality] ?? 3), Float(drops), rain),
        ]

        // Butterflies, far to near; two wings each.
        let sorted = f.butterflies.sorted { $0.position.z > $1.position.z }
        butterflySprites.removeAll(keepingCapacity: true)
        for b in sorted {
            let s = Self.screenSize * b.size * (1.25 - 0.5 * b.position.z)
            let pos = SIMD4(b.position, s)
            let a = SIMD4(b.hue, b.flapPhase, Float(b.style), b.glow)
            let seed = Float(b.id % 997) / 997
            butterflySprites.append(Sprite(pos: pos, a: a, b: SIMD4(b.opacity, b.landed ? 1 : 0, -1, seed)))
            butterflySprites.append(Sprite(pos: pos, a: a, b: SIMD4(b.opacity, b.landed ? 1 : 0, 1, seed)))
        }
        butterfliesDrawn = sorted.count
        // The hummingbird: one square sprite in front of the butterflies' haze (its heading and its wings' phase in a).
        hummingbirdDrawn = false
        if let h = f.hummingbird {
            let size: Float = 0.05
            butterflySprites.append(Sprite(pos: SIMD4(h.x, h.y, h.z, size), a: SIMD4(h.w, f.hummingbirdWing, Self.hummingbirdStyle, 0),
                                           b: SIMD4(1, 0, 0, 0.5)))
            hummingbirdDrawn = true
        }

        // Trails from recent positions.
        let trailLength = Int((p.number("trail.length") * 14).rounded())
        var alive = Set<Int>()
        trailSprites.removeAll(keepingCapacity: true)
        for b in f.butterflies {
            alive.insert(b.id)
            var h = history[b.id] ?? []
            // While time is held (dt 0) the trails hold too, rather than collapsing onto the butterflies.
            if dt > 0 || h.isEmpty { h.append(b.position) }
            if h.count > max(trailLength, 1) { h.removeFirst(h.count - max(trailLength, 1)) }
            history[b.id] = h
            guard trailLength > 0, !b.landed else { continue }
            for (i, pos) in h.dropLast().enumerated() {
                let age = Float(h.count - 1 - i) / Float(max(trailLength, 1))
                let s = Self.screenSize * b.size * 0.22 * (1 - age * 0.6)
                trailSprites.append(Sprite(pos: SIMD4(pos, s), a: SIMD4(b.hue, 0, 0, 0),
                                           b: SIMD4((1 - age) * 0.5 * Float(p.number("trail.glow")) * b.opacity, 0, 0, 0)))
            }
        }
        history = history.filter { alive.contains($0.key) }

        // Blooms on the meadow.
        bloomSprites = f.blooms.map { bl in
            let seed = (bl.x * 97).truncatingRemainder(dividingBy: 1)
            let z = 0.3 + 0.3 * seed
            return Sprite(pos: SIMD4(bl.x, 0.04 + 0.08 * seed, z, 0.045 * (0.6 + 0.6 * bl.openness) * (1.2 - z)),
                          a: SIMD4(bl.hue, bl.openness, Float(bl.kind), seed),
                          b: SIMD4(min(1, bl.openness * 3), 0, 0, 0))
        }

        // Keys.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let top = -1 + 2 * keyTop, bottom: Float = -0.995, gap: Float = 0.0015
            for k in f.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? top - (top - bottom) * 0.62 : bottom
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, top),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, 0)))
            }
        }

        post = PostSettings(
            bloom: Float(p.number("glow")) * 1.1 + 0.15,
            bloomThreshold: 0.85,
            dof: Float(p.number("dof")),
            focusDepth: 0.35,
            grade: Self.grades.firstIndex(of: p.choice("grade")) ?? 0,
            grain: Float(p.number("grain")),
            vignette: 0.35,
            exposure: limited.exposure,
            warmth: f.warmth,
            time: Float(f.time),
            quality: quality)
    }

    private func buffer<T>(_ items: [T]) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// The half-resolution shaft target for a scene `width` × `height` (made when the size changes, kept).
    private func shaftTarget(width: Int, height: Int) -> MTLTexture? {
        let w = max(1, (width + 1) / 2), h = max(1, (height + 1) / 2)
        if shaftTexture?.width != w || shaftTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            shaftTexture = device.makeTexture(descriptor: d)
            shaftAllocations += 1
        }
        return shaftTexture
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        var u = uniforms
        let uLen = u.count * MemoryLayout<SIMD4<Float>>.stride
        guard let hdr = stack.hdrTarget, let shaft = shaftTarget(width: hdr.width, height: hdr.height) else { return }
        // The shafts first, at half resolution, where the quality marches them (Smooth doesn't).
        if u.count > 10, u[10].x > 0, u[1].z > 0.01 {
            let sp = MTLRenderPassDescriptor()
            sp.colorAttachments[0].texture = shaft
            sp.colorAttachments[0].loadAction = .dontCare
            sp.colorAttachments[0].storeAction = .store
            if let se = cb.makeRenderCommandEncoder(descriptor: sp) {
                se.setRenderPipelineState(shafts)
                se.setFragmentBytes(&u, length: uLen, index: 0)
                se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                se.endEncoding()
            }
        }
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(sky)
        e.setFragmentBytes(&u, length: uLen, index: 0)
        e.setFragmentTexture(shaft, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        func sprites(_ list: [Sprite], _ pipeline: MTLRenderPipelineState) {
            guard let b = buffer(list) else { return }
            e.setRenderPipelineState(pipeline)
            e.setVertexBuffer(b, offset: 0, index: 0)
            e.setVertexBytes(&u, length: uLen, index: 1)
            e.setFragmentBytes(&u, length: uLen, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: list.count)
        }
        sprites(bloomSprites, blooms)
        sprites(trailSprites, trails)
        sprites(butterflySprites, wings)

        if particleCount > 0 {
            e.setRenderPipelineState(particles)
            e.setVertexBytes(&u, length: uLen, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
        }
        if let kb = buffer(keyInstances) {
            e.setRenderPipelineState(keys)
            e.setVertexBuffer(kb, offset: 0, index: 0)
            e.setFragmentBytes(&u, length: uLen, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
