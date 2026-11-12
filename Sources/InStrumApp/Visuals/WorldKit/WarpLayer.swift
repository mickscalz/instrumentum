import Metal
import CoreGraphics
import simd
import InStrumCore

/// Metal source for Galaxy Warp: streaking stars (instanced lines) and the nebula glow (two screen-space blobs).
enum WarpShaders {
    static let source = SkyShaders.common + """
    // A streak from tail to head in p-space (x scaled by aspect): a.xy head, a.zw tail; b: width, brightness, hue, unused.
    struct StreakInstance { float4 a; float4 b; };
    struct WarpU { float4 params; };   // aspect, time, unused, unused
    struct StreakOut { float4 pos [[position]]; float2 uv; float brightness; float hue; };

    float3 hueToRGB(float h) {
        float3 k = fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
        return saturate(abs(k) - 1.0);
    }

    vertex StreakOut warp_streak_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant StreakInstance* ss [[buffer(0)]], constant WarpU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, -1), float2(1, -1), float2(0, 1), float2(1, -1), float2(1, 1), float2(0, 1) };
        StreakInstance s = ss[iid];
        float2 head = s.a.xy, tail = s.a.zw;
        float w = s.b.x;
        float2 d = head - tail;
        float len = length(d);
        float2 dir = len > 1e-5 ? d / len : float2(1, 0);
        // Round caps: extend by the width at both ends, so a still star is a dot.
        float2 from = tail - dir * w, to = head + dir * w;
        float2 n = float2(-dir.y, dir.x);
        float2 p = mix(from, to, c[vid].x) + n * w * c[vid].y;
        StreakOut o;
        o.pos = float4(p.x / u.params.x, p.y, 0, 1);
        // uv.x: 0 at the tail cap … 1 at the head cap; uv.y across.
        o.uv = float2(c[vid].x, c[vid].y);
        o.brightness = s.b.y;
        o.hue = s.b.z;
        return o;
    }

    fragment float4 warp_streak_fragment(StreakOut in [[stage_in]]) {
        float across = exp(-in.uv.y * in.uv.y * 4.0);
        float along = pow(saturate(in.uv.x), 1.6);              // bright head, fading tail
        float3 tint = mix(float3(1.0), hueToRGB(in.hue), 0.55);
        float core = exp(-in.uv.y * in.uv.y * 30.0) * along;
        float3 c = tint * across * along * in.brightness * 1.6 + float3(1.0) * core * in.brightness * 1.4;
        return float4(c, 0.0);
    }

    // Nebula: blobA/blobB (centre p-space xy, radius, strength), colour (rgb, time), params (aspect, octaves, hue shift, unused).
    struct NebulaU { float4 blobA, blobB, color, params; };
    struct NebulaOut { float4 pos [[position]]; float2 ndc; };

    vertex NebulaOut warp_nebula_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        NebulaOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    fragment float4 warp_nebula_fragment(NebulaOut in [[stage_in]], constant NebulaU& u [[buffer(0)]]) {
        float2 p = float2(in.ndc.x * u.params.x, in.ndc.y);
        int octaves = int(u.params.y + 0.5);
        float time = u.color.w;
        float3 col = float3(0);
        for (int i = 0; i < 2; i++) {
            float4 b = i == 0 ? u.blobA : u.blobB;
            if (b.w < 0.002) continue;
            float2 q = (p - b.xy) / b.z;
            float g = exp(-dot(q, q) * 1.6);
            if (g < 0.003) continue;
            float n = fbm3(float3(q * 1.3 + float(i) * 7.3, time * 0.02 + float(i)), octaves);
            float wisps = smoothstep(0.3, 0.85, n);
            float3 c = mix(u.color.rgb, u.color.rgb.gbr * 0.6 + u.color.rgb * 0.5, float(i) * u.params.z);
            col += c * g * (0.25 + 1.1 * wisps) * b.w;
        }
        return float4(col * 0.45, 0.0);
    }
    """
}

/// Galaxy Warp's drawing, shared by every world with a sky: a field of warp stars that streams faster with
/// playing intensity, the note streaks from the model, and the nebula glow. Additive, drawn after the sky.
@MainActor
final class WarpLayer {
    /// Background warp stars (the whole field moves at warp speed).
    static func fieldCount(_ q: QualityLevel) -> Int { q == .lite ? 150 : (q == .high ? 300 : 500) }

    /// The vanishing point (NDC).
    var centre = SIMD2<Float>(0, 0.2)
    private(set) var instanceCount = 0

    private struct FieldStar { var angle, offset, rate, brightness, hue: Float }
    private struct Instance { var a: SIMD4<Float>; var b: SIMD4<Float> }

    private let device: MTLDevice
    private let streakPipeline, nebulaPipeline: MTLRenderPipelineState
    private var field: [FieldStar] = []
    private var instances: [Instance] = []
    private var travel: Float = 0
    private var aspect: Float = 16.0 / 9
    private var time: Float = 0
    private var nebulaU = [SIMD4<Float>](repeating: .zero, count: 4)
    private var showNebula = false

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: WarpShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let s = make("warp_streak_vertex", "warp_streak_fragment"),
              let n = make("warp_nebula_vertex", "warp_nebula_fragment") else { return nil }
        self.device = device
        streakPipeline = s; nebulaPipeline = n
        var rng = SeededRandom(seed: 0x57A2)
        field = (0..<Self.fieldCount(.ultra)).map { _ in
            FieldStar(angle: rng.range(0, 2 * .pi), offset: rng.unit(), rate: rng.range(0.6, 1.4),
                      brightness: rng.range(0.25, 1), hue: rng.range(0.55, 0.7))
        }
    }

    /// Radial position (p-space units from the vanishing point) for a distance 0…1.6: accelerating outward.
    private static func radial(_ d: Float) -> Float { 1.4 * d }

    /// `intensity` scales the streaks and the field (the flash limiter's sparkle; 0.5 on gentle visuals).
    func update(_ w: WarpFrame, trails: Float, nebula: Float, intensity: Float = 1, quality: QualityLevel, size: CGSize, dt: Double, time t: Float) {
        aspect = Float(max(1, size.width) / max(1, size.height))
        time = t
        let fdt = Float(min(dt, 0.1))
        let warp = w.warpSpeed
        travel += (0.008 + 0.25 * warp * warp) * fdt
        let c = SIMD2<Float>(centre.x * aspect, centre.y)
        instances.removeAll(keepingCapacity: true)

        // The field: each star loops outward from the centre, faster and longer at warp.
        let trail = 0.004 + 0.09 * warp * warp * (0.3 + trails)
        for s in field.prefix(Self.fieldCount(quality)) {
            let d = (s.offset + travel * s.rate).truncatingRemainder(dividingBy: 1)
            let r = 0.03 + 2.3 * d * d
            let rt = 0.03 + 2.3 * max(0, d - trail) * max(0, d - trail)
            let dir = SIMD2(cos(s.angle), sin(s.angle))
            let fade = min(1, d / 0.15)
            let h = c + dir * r, tl = c + dir * rt
            instances.append(Instance(a: SIMD4(h.x, h.y, tl.x, tl.y),
                                      b: SIMD4(0.0022 + 0.003 * d, s.brightness * fade * (0.5 + 0.6 * warp) * intensity, s.hue, 0)))
        }
        // Note streaks.
        for s in w.streaks {
            let len = (0.03 + 0.35 * warp * trails + 0.1 * trails) * (0.3 + s.distance)
            let head = c + s.direction * Self.radial(s.distance)
            let tail = c + s.direction * Self.radial(max(0, s.distance - len))
            let fade = min(1, max(0, (GalaxyWarp.maxAge - s.age) / 1.5))
            instances.append(Instance(a: SIMD4(head.x, head.y, tail.x, tail.y), b: SIMD4(0.004 + 0.006 * s.brightness, 1.6 * s.brightness * fade * intensity, s.hue, 0)))
        }
        instanceCount = instances.count

        // Nebula: two soft blobs drifting round the vanishing point.
        let amount = w.nebula * nebula
        showNebula = amount > 0.005
        let a1 = t * 0.03, a2 = t * 0.021 + 2.4
        let rgb = Self.nebulaColour(w.nebulaHue)
        nebulaU[0] = SIMD4(c.x + 0.45 * cos(a1), c.y + 0.25 * sin(a1), 0.75, amount)
        nebulaU[1] = SIMD4(c.x + 0.6 * cos(a2), c.y + 0.3 * sin(a2), 0.55, amount * 0.8)
        nebulaU[2] = SIMD4(rgb, t)
        nebulaU[3] = SIMD4(aspect, quality == .lite ? 2 : 3, 0.5, 0)
    }

    static func nebulaColour(_ hue: Float) -> SIMD3<Float> {
        let h = hue - floor(hue)
        let k = SIMD3<Float>(h, h + 2.0 / 3.0, h + 1.0 / 3.0)
        let f = k - floor(k)
        let rgb = SIMD3<Float>(abs(f.x * 6 - 3) - 1, abs(f.y * 6 - 3) - 1, abs(f.z * 6 - 3) - 1)
        return simd_clamp(rgb, .zero, SIMD3(repeating: 1)) * 0.8 + 0.1
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        var u = SIMD4<Float>(aspect, time, 0, 0)
        if showNebula {
            e.setRenderPipelineState(nebulaPipeline)
            nebulaU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        guard !instances.isEmpty,
              let buf = instances.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return }
        e.setRenderPipelineState(streakPipeline)
        e.setVertexBuffer(buf, offset: 0, index: 0)
        e.setVertexBytes(&u, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
    }
}
