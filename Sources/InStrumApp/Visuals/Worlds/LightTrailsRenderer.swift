import Metal
import simd
import InStrumCore

/// Draws Light Trails (Fire & Neon spec §9.2), Neon Night Drive's visual, over the drive's scene: every streak in the
/// model's ring as a ribbon of light along its lane and its mirror on the wet road, and a big moment's interchange bloom
/// (`LightTrailsShaders`, one additive full-screen pass that reads the scene's depth). The streaks go to the GPU sorted by
/// lane through a ring of three buffers made once, at their largest (128 streaks), so nothing is allocated a frame.
@MainActor
final class LightTrailsLayer {
    // MARK: The shader's rows (MSL `TrailsU`) and streaks
    nonisolated static let laneRows = 4, rowBloom = 4, rowInfo = 5, uniformCount = 6
    nonisolated static let streakStride = 2 * MemoryLayout<SIMD4<Float>>.stride
    /// Streaks sent on Smooth (the brightest), and on High and Ultra (all of them).
    nonisolated static func budget(_ q: QualityLevel) -> Int { q == .lite ? 64 : LightTrails.capacity }

    private let pipeline: MTLRenderPipelineState
    private var ring: [MTLBuffer] = []
    private var slot = 0
    private var tu = [SIMD4<Float>](repeating: .zero, count: LightTrailsLayer.uniformCount)
    private var packed = [SIMD4<Float>](repeating: .zero, count: LightTrails.capacity * 2)
    private var order = [Int](repeating: 0, count: LightTrails.capacity)

    /// Buffers made so far (three, at start; never more).
    private(set) var bufferAllocations = 0
    /// The streaks sent this frame, and the interchange bloom's light (tests).
    private(set) var drawn = 0
    private(set) var bloomLight: Float = 0
    /// The shader's rows and the streaks as packed this frame (tests).
    var uniforms: [SIMD4<Float>] { tu }
    var streakRows: [SIMD4<Float>] { Array(packed.prefix(drawn * 2)) }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: LightTrailsShaders.source, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "drive_vertex")
        d.fragmentFunction = lib.makeFunction(name: "trails_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = .one
        d.colorAttachments[0].sourceAlphaBlendFactor = .zero
        d.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        pipeline = p
        let bytes = LightTrails.capacity * Self.streakStride
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            ring.append(b)
            bufferAllocations += 1
        }
    }

    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// Packs this frame's streaks by lane (the brightest within the quality's budget) and the bloom.
    func update(_ frame: DriveFrame, quality: QualityLevel, gentle: Bool) {
        let streaks = frame.trails
        let budget = min(Self.budget(quality), streaks.count)
        // The brightest `budget`, by a partial selection into `order` (no allocation).
        var n = 0
        for i in streaks.indices where n < LightTrails.capacity {
            order[n] = i
            n += 1
        }
        if budget < n {
            for k in 0..<budget {
                var best = k
                for j in (k + 1)..<n where streaks[order[j]].light > streaks[order[best]].light { best = j }
                order.swapAt(k, best)
            }
            n = budget
        }
        let scale: Float = FlashLimiter.sparkleScale(gentle: gentle)
        var count = 0
        for lane in 0..<4 {
            let first = count
            for k in 0..<n {
                let s = streaks[order[k]]
                guard s.lane == lane else { continue }
                let x: Float = DriveRoad.laneCentre(lane) + s.offset
                let light: Float = max(0, s.light.isFinite ? s.light : 0) * scale
                packed[count * 2] = SIMD4(x, s.height, max(0, s.tail), max(0, s.head))
                packed[count * 2 + 1] = SIMD4(s.colour * light, 0)
                count += 1
            }
            tu[lane] = SIMD4(Float(first), Float(count - first), DriveRoad.laneCentre(lane), 0)
        }
        drawn = count
        if let b = frame.bloom {
            bloomLight = Self.unit(b.light) * scale
            tu[Self.rowBloom] = SIMD4(b.at, bloomLight, Float(b.seed % 1000) / 1000, b.age)
        } else {
            bloomLight = 0
            tu[Self.rowBloom] = SIMD4(-1, 0, 0, 0)
        }
        let wet: Float = Self.unit(frame.sky.wetness)
        tu[Self.rowInfo] = SIMD4(Float(count), quality == .lite ? 0 : 1, wet, 0)
        slot = (slot + 1) % ring.count
        let bytes = count * Self.streakStride
        if bytes > 0 {
            packed.withUnsafeBytes { ring[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        }
    }

    /// The streaks over the scene (a colour-only pass), reading the scene's depth and its uniforms.
    func draw(_ e: MTLRenderCommandEncoder, depth: MTLTexture, sky: [SIMD4<Float>], drive: [SIMD4<Float>]) {
        guard drawn > 0 || bloomLight > 0 else { return }
        e.setRenderPipelineState(pipeline)
        sky.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        drive.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        tu.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        e.setFragmentBuffer(ring[slot], offset: 0, index: 3)
        e.setFragmentTexture(depth, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
