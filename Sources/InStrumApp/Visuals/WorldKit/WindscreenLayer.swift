import Metal
import simd
import InStrumCore

/// A half-resolution copy of the view with a mip chain (the Window Kit's, for glass and wet surfaces to blur and bend):
/// made once at its size and kept, remade only when the view's size changes; never one a frame.
@MainActor
final class ViewCopy {
    static let levels = 6
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private(set) var texture: MTLTexture?
    /// Textures made so far (tests: one per size, never one a frame).
    private(set) var allocations = 0

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: WindscreenShaders.source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "screen_vertex")
        d.fragmentFunction = lib.makeFunction(name: "screen_copy_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        pipeline = p
    }

    /// Copies `source` at half resolution and builds its mips; encode it between passes. Nil if it can't.
    func make(from source: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        let w = max(1, source.width / 2), h = max(1, source.height / 2)
        if texture?.width != w || texture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: w, height: h, mipmapped: true)
            d.mipmapLevelCount = min(Self.levels, d.mipmapLevelCount)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
            allocations += 1
        }
        guard let tex = texture else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = tex
        p.colorAttachments[0].level = 0
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return nil }
        e.setRenderPipelineState(pipeline)
        e.setFragmentTexture(source, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        if tex.mipmapLevelCount > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        return tex
    }
}

/// The Window Kit's windscreen (Fire & Neon spec §9.1): the rain on a car's windscreen and the wipers clearing it, and the
/// car's cabin round the glass (the dashboard with the keys' strip of light, the A-pillars, the roof lining, the mirror).
/// A world draws its outside, then:
///
///     screen.update(spec: .windscreen(aspect:), wipers: frame.wipers, glassRain:, cabinLight:, ...)
///     let view = screen.makeView(from: stack.hdrTarget!, commandBuffer: cb)
///     // a colour-only pass continuing the scene:
///     screen.drawGlass(e, view: view)
///     screen.drawCabin(e, view: view)
///
/// The drops gather where a blade last passed at the rain's rate (none land while the car is sheltered: under a bridge, in
/// a tunnel), and evaporate slowly in the dry. Nothing is allocated a frame.
@MainActor
final class WindscreenLayer {
    // MARK: The shader's rows (MSL `ScreenU`)
    nonisolated static let rowA = 0, rowDash = 1, rowPillars = 2, rowMirror = 3, rowBladeA = 4, rowBladeB = 5
    nonisolated static let rowSweep = 6, rowWiper = 7, rowWiper2 = 8, rowDry = 9, rowLight = 10, rowKeyInfo = 11
    nonisolated static let keyBase = 12, keyRows = 22
    nonisolated static let uniformCount = 34
    /// How long the glass takes to bead over again after a wipe (s): a second in a downpour, 7 in a drizzle.
    nonisolated static func fillTime(rain: Float) -> Float {
        let r: Float = rain.isFinite ? min(1, max(0, rain)) : 0
        return 1 + 6 * (1 - r) * (1 - r)
    }

    let copy: ViewCopy
    private let glass, cabin: MTLRenderPipelineState
    private var u = [SIMD4<Float>](repeating: .zero, count: WindscreenLayer.uniformCount)
    private var clock: Double = 0
    private var lastAngle: Float = 0
    private var rainLevel: Float = 0
    private var shelterBegan: Double?
    private var shelterEnded: Double?
    private(set) var spec = WindowSpec.windscreen(aspect: 16.0 / 9)

    /// The shader's rows (tests read them).
    var uniforms: [SIMD4<Float>] { u }
    /// Whether the car is sheltered now (no rain landing on the glass), and the drops' density (0…1).
    private(set) var sheltered = false
    var dropDensity: Float { u[Self.rowWiper2].w }

    init?(device: MTLDevice) {
        guard let c = ViewCopy(device: device), let lib = try? device.makeLibrary(source: WindscreenShaders.source, options: nil) else {
            return nil
        }
        func make(_ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "screen_vertex")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let g = make("screen_glass_fragment"), let f = make("screen_frame_fragment") else { return nil }
        copy = c
        glass = g
        cabin = f
    }

    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// - glassRain: the rain landing on the glass now (0 under a bridge or in a tunnel); its slow average sets how many
    ///   drops there are, so they evaporate in the dry.
    /// - cabinLight: the city's light through the glass (rgb), falling on the dashboard, the pillars and the drops' rims.
    /// - strobe: a tunnel's lights passing over the cabin (0…1, after the world's flash limiter; 0 under gentle visuals).
    /// - keys: the 88 keys' glow, lit in `keyColour`; `showKeys` off hides the strip.
    func update(spec s: WindowSpec, wipers: Wipers, glassRain: Float, speed: Float, cabinLight: SIMD3<Float>, strobe: Float,
                keys: [KeyVisual], keyColour: SIMD3<Float>, showKeys: Bool, quality: QualityLevel, dt: Double, aspect: Float,
                time: Float) {
        spec = s
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        clock += step
        let shape = s.windscreen ?? WindowSpec.windscreen(aspect: aspect).windscreen!
        let rain = Self.unit(glassRain)
        // The drops' density follows the rain's slow average (they dry off over half a minute); while it rains but none
        // lands (sheltered), no new drop appears where the blades clear.
        let k = Float(1 - exp(-step / 20))
        if rain > rainLevel { rainLevel += (rain - rainLevel) * Float(1 - exp(-step / 2)) } else { rainLevel += (rain - rainLevel) * k }
        let nowSheltered = rain < 0.02 && rainLevel > 0.05
        if nowSheltered && !sheltered { shelterBegan = clock; shelterEnded = nil }
        if !nowSheltered && sheltered { shelterEnded = clock }
        sheltered = nowSheltered
        let a: Float = aspect.isFinite && aspect > 0.1 ? min(aspect, 10) : 16.0 / 9
        u[Self.rowA] = SIMD4(a, time, quality == .lite ? 0 : 1, rain)
        u[Self.rowDash] = SIMD4(shape.dash, shape.dashCurve, shape.roof, shape.roofCurve)
        u[Self.rowPillars] = SIMD4(shape.leftPillar.x, shape.leftPillar.y, shape.rightPillar.x, shape.rightPillar.y)
        u[Self.rowMirror] = shape.mirror
        u[Self.rowBladeA] = shape.blades.count > 0 ? shape.blades[0] : .zero
        u[Self.rowBladeB] = shape.blades.count > 1 ? shape.blades[1] : .zero
        let angle = Self.unit(wipers.angle)
        u[Self.rowSweep] = SIMD4(shape.restAngle, shape.sweep, angle, lastAngle)
        lastAngle = angle
        u[Self.rowWiper] = SIMD4(wipers.phase, wipers.sweepSeconds, wipers.lastSweepSeconds, min(wipers.restBefore, 1000))
        let density: Float = Self.smooth(0.02, 0.5, rainLevel)
        u[Self.rowWiper2] = SIMD4(wipers.sweeping ? 1 : 0, wipers.sweeps > 0 ? 1 : 0, Self.fillTime(rain: max(rain, rainLevel)), density)
        var began: Float = -1, ended: Float = 0
        if let b = shelterBegan {
            began = Float(clock - b)
            ended = shelterEnded.map { Float(clock - $0) } ?? 0
            if ended > 60 { began = -1; ended = 0 }
        }
        u[Self.rowDry] = SIMD4(began, ended, speed.isFinite ? speed : 0, 0)
        let light = SIMD3<Float>(min(cabinLight.x, 4), min(cabinLight.y, 4), min(cabinLight.z, 4))
        u[Self.rowLight] = SIMD4(light, Self.unit(strobe))
        u[Self.rowKeyInfo] = SIMD4(keyColour, showKeys ? 1 : 0)
        for i in 0..<Self.keyRows { u[Self.keyBase + i] = .zero }
        for kv in keys {
            let i = Int(kv.key.note) - 21
            guard (0..<88).contains(i) else { continue }
            u[Self.keyBase + i / 4][i % 4] = Self.unit(kv.glow)
        }
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The copy of the view the glass looks through (kept; remade only when the view's size changes).
    func makeView(from source: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        copy.make(from: source, commandBuffer: cb)
    }

    /// The rain on the glass and the blades, over the view (a colour-only pass).
    func drawGlass(_ e: MTLRenderCommandEncoder, view: MTLTexture) {
        e.setRenderPipelineState(glass)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.setFragmentTexture(view, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The cabin round the glass, over everything (a colour-only pass).
    func drawCabin(_ e: MTLRenderCommandEncoder, view: MTLTexture) {
        e.setRenderPipelineState(cabin)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.setFragmentTexture(view, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
