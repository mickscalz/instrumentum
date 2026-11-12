/// Metal source for Magma Veins (Fire & Neon spec §8.2): a full-frame view straight down into the lava lake. One pass
/// draws the crust (24 plates through a warped Voronoi, their cracks a blackbody core and halo, the plates' skin and its
/// fine cracks; a moment's split widens every crack to the bright magma beneath); the veins (each note's channel and its
/// branches, and the cracks joining a chord's veins) are instanced distance-field strokes over it, each lit by its own
/// cooling temperature. Smooth rules: no ray marching, at most 3 octaves (2 on Smooth), no pow.
enum MagmaVeinsShaders {
    static let source = SkyShaders.common + """
    struct VeinsU {
        float4 a;          // aspect, time (s, wrapped), octaves, a pixel (view units)
        float4 b;          // split shown 0…1, energy, drop, the crust's drift (view units)
        float4 c;          // crack temperature (K), young crust (K), old crust (K), metres a view unit
        float4 plates[24]; // place (view units: x 0…aspect, y 0…1), young heat 0…1, 0
    };
    struct VOut { float4 pos [[position]]; float2 ndc; };

    vertex VOut veins_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float hash12(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    float2 hash22(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }
    float vn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
    }
    float fbm2(float2 p, int octaves) {
        float s = 0.0, a = 0.5, n = 0.0;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            s += a * vn2(p);
            n += a;
            p = p * 2.03 + float2(17.1, 9.2);
            a *= 0.5;
        }
        return s / n;
    }
    float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
    float3 blackbody(float T) {
        float t = clamp(T, 450.0, 2200.0);
        float inv = 1.0 / t;
        return float3(1.0, exp(0.38 - 1848.0 * inv), exp(2.036 - 8727.0 * inv)) * exp((t - 1150.0) * 0.0086957);
    }
    float lineLight(float d, float w, float f) {
        float we = sqrt(w * w + 0.5 * f * f);
        return (w / we) * exp(-max(d, 0.0) / we);
    }
    float fineNet(float2 local, float scale) {
        float2 g = local / scale;
        float2 gi = floor(g), gf = fract(g);
        float f1 = 9.0;
        float2 mr = float2(0), mg = float2(0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 cell = float2(float(x), float(y));
                float2 r = cell + hash22(gi + cell) * 0.85 - gf;
                float dd = dot(r, r);
                if (dd < f1) { f1 = dd; mr = r; mg = cell; }
            }
        }
        float edge = 9.0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float2 cell = mg + float2(float(x), float(y));
                float2 r = cell + hash22(gi + cell) * 0.85 - gf;
                float2 dr = r - mr;
                if (dot(dr, dr) > 1e-5) edge = min(edge, dot(0.5 * (mr + r), normalize(dr)));
            }
        }
        return edge * scale;
    }

    fragment ColorDepth veins_crust_fragment(VOut in [[stage_in]], constant VeinsU& u [[buffer(0)]]) {
        int oct = int(u.a.z + 0.5);
        float aspect = u.a.x;
        float2 p = float2((in.ndc.x * 0.5 + 0.5) * aspect, in.ndc.y * 0.5 + 0.5);
        float m = u.c.w;   // metres a view unit
        float pix = u.a.w;
        // Plates through a two-scale warp, so the cracks run ragged.
        float2 q0 = p * 2.3;
        float2 q = p + (float2(vn2(q0 + float2(3.1, 7.7)), vn2(q0 + float2(11.3, 1.9))) - 0.5) * 0.12;
        float2 q1 = p * 9.0;
        q += (float2(vn2(q1 + float2(5.2, 3.3)), vn2(q1 + float2(9.4, 6.1))) - 0.5) * 0.025;
        int i1 = 0;
        float best = 1e9;
        for (int k = 0; k < 24; k++) {
            float2 c = u.plates[k].xy - q;
            float dd = dot(c, c);
            if (dd < best) { best = dd; i1 = k; }
        }
        float2 c1 = u.plates[i1].xy;
        // The three nearest cracks (a junction's third crack never drops out, so its halo never shows a wedge).
        float bd[3] = { 1e9, 1e9, 1e9 };
        int bj[3] = { i1, i1, i1 };
        for (int k = 0; k < 24; k++) {
            if (k == i1) continue;
            float2 n = u.plates[k].xy - c1;
            float ln = length(n);
            if (ln < 1e-4) continue;
            float dist = dot(0.5 * (c1 + u.plates[k].xy) - q, n / ln);
            if (dist < bd[0]) { bd[2] = bd[1]; bj[2] = bj[1]; bd[1] = bd[0]; bj[1] = bj[0]; bd[0] = dist; bj[0] = k; }
            else if (dist < bd[1]) { bd[2] = bd[1]; bj[2] = bj[1]; bd[1] = dist; bj[1] = k; }
            else if (dist < bd[2]) { bd[2] = dist; bj[2] = k; }
        }
        float split = u.b.x;
        float energy = u.b.y;
        // Each crack its own width and heat (wider and hotter as the plates split apart); the brightest shows, so a
        // junction never steps. Their light spills onto the crust beside them.
        float3 col = float3(0);
        float3 spill = float3(0);
        float dm = max(bd[0], 0.0) * m;
        for (int c = 0; c < 3; c++) {
            int j = bj[c];
            float bdm = max(bd[c], 0.0) * m;
            float heat = 0.5 * (u.plates[i1].z + u.plates[j].z);
            float pair = hash12(float2(float(min(i1, j)) * 7.13, float(max(i1, j)) * 3.71));
            float along = vn2(q * 14.0 + pair * 31.0);
            float w = (0.12 + 0.3 * pair) * (0.3 + 1.4 * along) + split * (1.2 + 2.0 * along);
            float T = u.c.x - 60.0 + 90.0 * pair + 80.0 * energy + 230.0 * split + 60.0 * heat + 60.0 * (along - 0.5);
            float3 cj = blackbody(T) * lineLight(bdm, w, pix * m) + blackbody(T - 200.0) * (0.12 * lineLight(bdm, w * 2.5 + 0.4, pix * m));
            col = max(col, cj);
            spill = max(spill, blackbody(T) * exp(-bdm / (1.2 + 2.0 * w)));
        }
        // The plate: its skin (ropy wrinkles, glassy patches), its fine cracks, darker in its middle; the cracks' light
        // shows the skin's texture near them.
        float2 local = (p - c1) * m + float2(hash12(float2(float(i1), 1.7)) * 97.0, hash12(float2(float(i1), 4.1)) * 61.0);
        float skin = fbm2(local * 0.12, oct);
        float Tc = mix(u.c.z, u.c.y, u.plates[i1].z) + 80.0 * (skin - 0.5) + 40.0 * energy + 110.0 * exp(-dm / 1.1);
        col += blackbody(Tc);
        float2 rw = local * 0.9 + 3.0 * float2(vn2(local * 0.08), vn2(local * 0.08 + 5.0));
        float ropes = 1.0 - abs(sin(rw.x * 1.3 + 2.0 * vn2(rw * 0.3)));
        float glassy = smoothstep(0.35, 0.8, fbm2(local * 0.4 + float2(2.0, 9.0), oct));
        float albedo = 0.05 + 0.05 * ropes * (1.0 - glassy) + 0.03 * skin;
        col += spill * (albedo * (0.8 + 0.6 * glassy));
        float fine = fineNet(local + 7.0 * float2(skin, vn2(local * 0.05)), 5.5);
        // Only some of the fine cracks glow (the skin's hotter seams), so they never read as a net.
        float seam = smoothstep(0.45, 0.75, vn2(local * 0.35 + 4.0));
        col += blackbody(Tc + 300.0 + 80.0 * energy) * (0.3 * lineLight(fine, 0.06, pix * m)) * seam * (0.25 + 0.75 * u.plates[i1].z);
        // A sheen of reflected glow over the glassy skin.
        col += float3(0.03, 0.014, 0.008) * (0.15 + 0.45 * glassy) * (0.4 + 0.6 * energy);
        // The drop's flood: bright magma breaking through everywhere for a moment.
        col += blackbody(1260.0) * (u.b.z * 0.35 * smoothstep(0.45, 0.8, vn2(p * 6.0 + u.a.y * 0.3)));
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(0.5, 0, 0, 1);
        return out;
    }

    // One segment of a vein (or of a chord's joining crack): an instanced quad round it, lit by distance.
    struct Seg { float4 seg; float4 info; };   // NDC x0, y0, x1, y1; half width (NDC y), temperature (K), light, halo
    struct SegOut { float4 pos [[position]]; float2 p; float4 seg; float4 info; };
    vertex SegOut veins_seg_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Seg* segs [[buffer(0)]],
                                   constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Seg s = segs[iid];
        float pad = s.info.x * (2.0 + 6.0 * s.info.w) + 0.004;
        float2 lo = min(s.seg.xy, s.seg.zw) - float2(pad / view.x, pad);
        float2 hi = max(s.seg.xy, s.seg.zw) + float2(pad / view.x, pad);
        SegOut o;
        float2 at = mix(lo, hi, c[vid]);
        o.pos = float4(at, 0, 1);
        o.p = at;
        o.seg = s.seg;
        o.info = s.info;
        return o;
    }
    fragment float4 veins_seg_fragment(SegOut in [[stage_in]], constant float4& view [[buffer(0)]]) {
        float2 a = float2(in.seg.x * view.x, in.seg.y), b = float2(in.seg.z * view.x, in.seg.w);
        float2 p = float2(in.p.x * view.x, in.p.y);
        float2 ab = b - a;
        float s = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-10), 0.0, 1.0);
        float dist = length(p - (a + ab * s));
        // A channel, not a ruled line: its width swells and pinches, its edges are torn, its heat comes in pulses (the
        // noise is in view space, so it runs on unbroken across the strokes' joints).
        float wv = vn2(p * 38.0 + 3.0);
        float w = max(in.info.x * (0.55 + 0.9 * wv), view.w);
        float torn = (vn2(p * 160.0) - 0.5) * 1.1 * w;
        float dd = max(dist + torn, 0.0);
        float core = exp(-(dd * dd) / (w * w));
        float halo = exp(-dist / (w * (2.0 + 4.0 * in.info.w)));
        float pulse = 0.7 + 0.3 * vn2(p * 22.0 + 9.0);
        float3 c = blackbody(in.info.y - 120.0 * (1.0 - pulse)) * (core * 1.4) + blackbody(in.info.y - 220.0) * (halo * 0.35);
        c *= in.info.z;
        if (lum(c) < 0.0005) discard_fragment();
        return float4(c, 0.0);
    }
    """
}
