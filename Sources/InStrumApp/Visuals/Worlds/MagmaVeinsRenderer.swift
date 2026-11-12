import Metal
import CoreGraphics
import simd
import InStrumCore

/// Draws Magma Veins (Fire & Neon spec §8.2), Volcano Rim's second visual: the view straight down into the lava lake.
/// One full-screen pass draws the crust's plates and cracks (`MagmaVeinsShaders`); each vein (a note's channel and its
/// branches, grown as far as it has reached) and each chord's joining crack is a run of instanced strokes over it, lit
/// by the vein's own temperature as it cools. A moment's split eases open (quickly, or slowly under gentle visuals) and
/// the light it brings passes through a `FlashLimiter`. The instance buffers (a ring of three) are made once.
@MainActor
final class MagmaVeinsRenderer: ThemeRenderer {
    nonisolated static let uniformCount = 27
    nonisolated static let plateBase = 3
    /// The strokes at most: every vein's channel (8) and branches (3 × 3), and a joining crack (4) for each.
    nonisolated static let segmentCapacity = MagmaVeins.capacity * (8 + 9 + 4)
    /// Metres of lake a view height spans.
    nonisolated static let metresPerView: Float = 46

    private let crust, segs, cores: MTLRenderPipelineState
    private var veinsU = [SIMD4<Float>](repeating: .zero, count: MagmaVeinsRenderer.uniformCount)
    private var instances: [SIMD4<Float>] = []
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private(set) var bufferAllocations = 0
    private var view = SIMD4<Float>(16.0 / 9, 0, 0, 0)
    private var limiter = FlashLimiter()
    private var primed = false
    private var splitShown: Float = 0
    private(set) var post = PostSettings()
    /// What was drawn (tests): the strokes, the veins drawn, the split as shown.
    private(set) var segmentCount = 0
    private(set) var veinsDrawn = 0
    private(set) var linksDrawn = 0
    var shownSplit: Float { splitShown }
    var flashesInLastSecond: Int { limiter.recent }
    var flashTotal: Int { limiter.total }
    var uniforms: [SIMD4<Float>] { veinsU }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: MagmaVeinsShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String, additive: Bool, brighter: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if additive {
                // The channels lie over the crust (premultiplied): their dark levees hide it, overlapping strokes of a
                // channel never add up to bright knots.
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                if brighter {
                    // The cores: the brighter of theirs and what's there (no seams where strokes meet).
                    c.rgbBlendOperation = .max
                    c.alphaBlendOperation = .max
                    c.destinationRGBBlendFactor = .one
                    c.destinationAlphaBlendFactor = .one
                }
                d.colorAttachments[1].writeMask = []
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let c = make("veins_vertex", "veins_crust_fragment", additive: false),
              let s = make("veins_seg_vertex", "veins_seg_fragment", additive: true),
              let k = make("veins_seg_vertex", "veins_seg_fragment", additive: true, brighter: true) else { return nil }
        let bytes = Self.segmentCapacity * 2 * MemoryLayout<SIMD4<Float>>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buf = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            buffers.append(buf)
        }
        crust = c; segs = s; cores = k
        ring = buffers
        bufferAllocations = buffers.count
        instances.reserveCapacity(Self.segmentCapacity * 2)
    }

    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    func update(_ frame: VeinsFrame, mood: Mood, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        let width = Float(max(1, size.width)), height = Float(max(1, size.height))
        let aspect = width / height
        let t = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        // The split eases open (a motion, not a jump) and closes as the model lets it.
        let target = Self.unit(frame.split)
        let tau: Float = gentle ? 0.9 : 0.18
        if target > splitShown { splitShown += (target - splitShown) * (dt == 0 ? 1 : 1 - exp(-fdt / tau)) }
        else { splitShown = target }
        let base: Float = MoodLook.exposure(mood) * 1.25
        let asked: Float = gentle ? min(0.16, 0.3 * splitShown) : 0.6 * splitShown
        limiter.gentle = gentle
        if !primed {
            // The limiter starts from black: settle it on the view's own exposure first, so arriving is never a flash.
            primed = true
            for _ in 0..<16 { _ = limiter.limit(exposure: base, sparkle: 1, dt: 1) }
        }
        let limited = limiter.limit(exposure: base * (1 + asked), sparkle: 1, dt: dt)
        let pixel: Float = 2 / height
        view = SIMD4(aspect, 0, 0, pixel)
        let octaves: Float = quality == .lite ? 2 : 3
        veinsU[0] = SIMD4(aspect, t, octaves, 1 / height)
        veinsU[1] = SIMD4(splitShown, Self.unit(frame.energy), Self.unit(frame.drop), 0)
        veinsU[2] = SIMD4(1080, 770, 560, Self.metresPerView)
        for k in 0..<MagmaVeins.plateCount {
            if k < frame.plates.count {
                let p = frame.plates[k]
                let heat = Float((k * 37) % 11) / 10
                veinsU[Self.plateBase + k] = SIMD4(p.x * aspect, p.y, heat, 0)
            } else {
                veinsU[Self.plateBase + k] = SIMD4(1e3, 1e3, 0, 0)
            }
        }
        buildSegments(frame, aspect: aspect, pixel: pixel, gentle: gentle)
        post = PostSettings(
            bloom: 0.85, bloomThreshold: 0.75,
            dof: 0, focusDepth: 0.5,
            grade: 0, grain: 0.03, vignette: 0.3,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) * 0.3,
            time: t, quality: quality)
    }

    /// Each vein's channel and branches, grown as far as it has reached (view heights from its origin at the foot of the
    /// view), and the jagged cracks joining a chord's veins.
    private func buildSegments(_ frame: VeinsFrame, aspect: Float, pixel: Float, gentle: Bool) {
        instances.removeAll(keepingCapacity: true)
        veinsDrawn = 0
        linksDrawn = 0
        func ndc(_ v: MagmaVein, _ q: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(-1 + 2 * v.origin + 2 * q.x / aspect, -1.06 + 2 * q.y)
        }
        func add(_ a: SIMD2<Float>, _ b: SIMD2<Float>, width: Float, kelvin: Float, light: Float, halo: Float) {
            guard instances.count < Self.segmentCapacity * 2 else { return }
            instances.append(SIMD4(a.x, a.y, b.x, b.y))
            instances.append(SIMD4(width, kelvin, light, halo))
        }
        let soft: Float = gentle ? 0.8 : 1
        for v in frame.veins where v.alive {
            let path = v.path()
            let reach = v.reach
            let steps = Float(path.count - 1)
            // A channel opening as it bursts through: wider the harder the note, widening as it grows.
            let width = pixel * (4.5 + 9.0 * v.strength) * (0.55 + 0.45 * v.reach)
            let light: Float = soft
            var drawn = false
            for i in 0..<(path.count - 1) {
                let from = Float(i) / steps
                guard from < reach else { break }
                let to = min(1, Float(i + 1) / steps)
                let part = min(1, (reach - from) / max(to - from, 1e-4))
                let a = path[i], b = path[i] + (path[i + 1] - path[i]) * part
                let taper = 1 - 0.45 * from
                add(ndc(v, a), ndc(v, b), width: width * taper, kelvin: v.temperature, light: light, halo: 0.6)
                drawn = true
            }
            if reach > 0.5 {
                for branch in v.branches() {
                    for i in 0..<(branch.count - 1) {
                        add(ndc(v, branch[i]), ndc(v, branch[i + 1]), width: width * 0.6 * (1 - 0.25 * Float(i)),
                            kelvin: v.temperature - 50, light: light, halo: 0.3)
                    }
                }
            }
            if drawn { veinsDrawn += 1 }
        }
        // A chord's joining cracks: from 40% up one vein to 40% up the next, jagged, at the cooler of the two.
        for v in frame.veins where v.alive {
            guard let l = v.link, l >= 0, l < frame.veins.count else { continue }
            let w = frame.veins[l]
            guard w.alive, v.reach > 0.4, w.reach > 0.4 else { continue }
            let pa = v.path(), pb = w.path()
            let a = ndc(v, pa[3]), b = ndc(w, pb[3])
            var rng = SeededRandom(seed: v.seed ^ w.seed)
            var prev = a
            for k in 1...4 {
                let f = Float(k) / 4
                var p = a + (b - a) * f
                if k < 4 { p += SIMD2(rng.range(-0.02, 0.02), rng.range(-0.03, 0.03)) }
                add(prev, p, width: pixel * 2.4, kelvin: min(v.temperature, w.temperature) - 40, light: soft, halo: 0.5)
                prev = p
            }
            linksDrawn += 1
        }
        segmentCount = instances.count / 2
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(crust)
        veinsU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        let bytes = instances.count * MemoryLayout<SIMD4<Float>>.stride
        if bytes > 0, !ring.isEmpty {
            slot = (slot + 1) % ring.count
            let buf = ring[slot]
            instances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            e.setRenderPipelineState(segs)
            e.setVertexBuffer(buf, offset: 0, index: 0)
            var vw = view
            e.setVertexBytes(&vw, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            // The levees first, then the molten cores over them (view.y picks the pass).
            for pass in 0..<2 {
                e.setRenderPipelineState(pass == 0 ? segs : cores)
                var pv = SIMD4<Float>(vw.x, Float(pass), vw.z, vw.w)
                e.setFragmentBytes(&pv, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segmentCount)
            }
        }
        e.endEncoding()
    }
}
