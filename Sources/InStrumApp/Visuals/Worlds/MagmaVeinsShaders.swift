/// Metal source for Magma Veins (Fire & Neon spec §8.2): a full-frame view straight down into the lava lake. One pass
/// draws the crust (24 plates through a warped Voronoi, their cracks a blackbody core and halo, the plates' skin and its
/// fine cracks; a moment's split widens every crack to the bright magma beneath); the veins (each note's lens-shaped
/// channel and its braids, and the channels joining a chord's veins) are instanced distance-field strokes over it, each
/// lit by its own cooling temperature along its length. Smooth rules: no ray marching, at most 3 octaves (2 on Smooth),
/// no pow.
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
    /// A crack's light (as the lake's): the lava cools from its core to its crusted lips, a thin white-yellow core
    /// through orange to deep red, no halo; its light kept when it's thinner than a pixel.
    float3 crackGlow(float d, float w, float f, float Tcore) {
        float we = sqrt(w * w + 0.5 * f * f);
        return blackbody(Tcore - 330.0 * max(d, 0.0) / we) * (w / we);
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
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
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
        // The three nearest cracks (a junction's third crack never drops out, so its halo never shows a wedge). Held in
        // named registers, not an array (Intel and AMD GPUs put a run-time-indexed array in scratch memory: this pass
        // took 80 ms on CI's Intel Mac).
        float bd0 = 1e9, bd1 = 1e9, bd2 = 1e9;
        int bj0 = i1, bj1 = i1, bj2 = i1;
        for (int k = 0; k < 24; k++) {
            if (k == i1) continue;
            float2 n = u.plates[k].xy - c1;
            float ln = length(n);
            if (ln < 1e-4) continue;
            float dist = dot(0.5 * (c1 + u.plates[k].xy) - q, n / ln);
            if (dist < bd0) { bd2 = bd1; bj2 = bj1; bd1 = bd0; bj1 = bj0; bd0 = dist; bj0 = k; }
            else if (dist < bd1) { bd2 = bd1; bj2 = bj1; bd1 = dist; bj1 = k; }
            else if (dist < bd2) { bd2 = dist; bj2 = k; }
        }
        float split = u.b.x;
        float energy = u.b.y;
        // The plates' cracks, as on the lake: most thin and pinching shut along their length, a few wide spreading seams
        // with white-hot cores (more of them, and all wider and hotter, as the plates split apart); the brightest shows.
        float3 col = float3(0);
        float3 spill = float3(0);
        float dm = max(bd0, 0.0) * m;
        for (int c = 0; c < 3; c++) {
            int j = c == 0 ? bj0 : (c == 1 ? bj1 : bj2);
            float bdm = max(c == 0 ? bd0 : (c == 1 ? bd1 : bd2), 0.0) * m;
            float heat = 0.5 * (u.plates[i1].z + u.plates[j].z);
            float pair = hash12(float2(float(min(i1, j)) * 7.13, float(max(i1, j)) * 3.71));
            float wide = smoothstep(0.82 - 0.15 * energy, 0.97, pair);
            float along = vn2(q * 9.0 + pair * 31.0);
            float pinch = smoothstep(0.12, 0.55, along) * (0.5 + vn2(q * 30.0 + pair * 7.0));
            float w = (0.05 + 0.4 * wide) * pinch * (0.7 + 0.6 * heat) + split * (0.16 + 0.42 * along);
            float bdt = max(bdm + (vn2(q * 60.0 + pair * 13.0) - 0.5) * 0.5 * (0.3 + w), 0.0);
            float T = u.c.x - 50.0 + 60.0 * pair + 220.0 * wide + 40.0 * energy + 130.0 * split + 60.0 * heat + 60.0 * (along - 0.5);
            col = max(col, crackGlow(bdt, w, pix * m, T));
            spill = max(spill, blackbody(T - 180.0) * exp(-bdm / (0.35 + 0.8 * w)));
        }
        // The plate: a dark grey skin with ropy wrinkles and glassy patches, lit by the cracks beside it and with a faint
        // sheen; young plates a little red with heat; dim hairlines in it, some glowing.
        float2 local = (p - c1) * m + float2(hash12(float2(float(i1), 1.7)) * 97.0, hash12(float2(float(i1), 4.1)) * 61.0);
        float skin = fbm2(local * 0.12, oct);
        float Tc = mix(u.c.z, u.c.y, u.plates[i1].z) + 80.0 * (skin - 0.5) + 40.0 * energy + 100.0 * exp(-dm / 1.0);
        col += blackbody(Tc);
        float2 rw = local * 0.9 + 3.0 * float2(vn2(local * 0.08), vn2(local * 0.08 + 5.0));
        float ropes = 1.0 - abs(sin(rw.x * 1.1 + rw.y * 0.7 + 2.5 * vn2(rw * 0.3)));
        float glassy = smoothstep(0.35, 0.8, fbm2(local * 0.4 + float2(2.0, 9.0), oct));
        float albedo = 0.07 + 0.07 * ropes * ropes * (1.0 - glassy) + 0.04 * skin;
        col += albedo * (0.9 * spill + float3(0.05, 0.03, 0.022) * (0.5 + 0.5 * energy));
        col += float3(0.045, 0.03, 0.022) * (0.2 + 0.8 * glassy) * (0.4 + 0.6 * energy) * (0.4 + 0.6 * ropes);
        float fine = fineNet(local + 7.0 * float2(skin, vn2(local * 0.05)), 5.5);
        float seam = smoothstep(0.45, 0.75, vn2(local * 0.35 + 4.0));
        col += crackGlow(fine, 0.04, pix * m, Tc + 280.0 + 80.0 * energy) * (seam * (0.3 + 0.7 * u.plates[i1].z));
        // The drop's flood: bright magma breaking through everywhere for a moment.
        col += blackbody(1260.0) * (u.b.z * 0.35 * smoothstep(0.45, 0.8, vn2(p * 6.0 + u.a.y * 0.3)));
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(0.5, 0, 0, 1);
        return out;
    }

    // One segment of a vein's channel (or a braid of it, or a chord's joining channel): an instanced quad round it, lit
    // by distance. Its width and its core's temperature run from one end's to the other's, so a channel of segments
    // swells and pinches (a lens) and cools along its length without a step at the joints.
    struct Seg { float4 seg; float4 info; float4 tail; };   // NDC x0, y0, x1, y1; half width (NDC y) at the start,
                                                            // temperature (K) there, light, halo; width and temperature at the end
    struct SegOut { float4 pos [[position]]; float2 p; float4 seg; float4 info; float2 tail; };
    vertex SegOut veins_seg_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Seg* segs [[buffer(0)]],
                                   constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Seg s = segs[iid];
        float pad = max(s.info.x, s.tail.x) * (2.2 + 6.0 * s.info.w) + 0.014;
        float2 lo = min(s.seg.xy, s.seg.zw) - float2(pad / view.x, pad);
        float2 hi = max(s.seg.xy, s.seg.zw) + float2(pad / view.x, pad);
        SegOut o;
        float2 at = mix(lo, hi, c[vid]);
        o.pos = float4(at, 0, 1);
        o.p = at;
        o.seg = s.seg;
        o.info = s.info;
        o.tail = s.tail.xy;
        return o;
    }
    fragment float4 veins_seg_fragment(SegOut in [[stage_in]], constant float4& view [[buffer(0)]]) {
        float2 a = float2(in.seg.x * view.x, in.seg.y), b = float2(in.seg.z * view.x, in.seg.w);
        float2 p0 = float2(in.p.x * view.x, in.p.y);
        // The channel meanders off its polyline (a smooth field in view space, the same for every stroke).
        float2 p = p0 + (float2(vn2(p0 * 9.0 + 1.0), vn2(p0 * 9.0 + 7.0)) - 0.5) * 0.016;
        float2 ab = b - a;
        float s = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-10), 0.0, 1.0);
        float dist = length(p - (a + ab * s));
        float width = mix(in.info.x, in.tail.x, s);
        float Tcore = mix(in.info.y, in.tail.y, s);
        // A channel of magma burst through the crust, lens-shaped along its length and swelling and pinching along it: its
        // banks torn, a hot core whose light varies along it (fresher here, rafts of skin there, drifting up the channel),
        // cooling across to its banks; as it cools a skin forms over it, dark crust broken into plates with the magma
        // glowing in the seams between them (yellow through red to black as it dies). Outside it, narrow banks of chilled
        // crust, soft-edged, and the channel's glow bleeding onto the crust beside it (the noise is in view space, so it
        // runs on unbroken across the strokes' joints).
        float wv = vn2(p * 30.0 + 3.0) * 0.7 + vn2(p * 7.0 + 11.0) * 0.3;
        float w = max(width * (0.7 + 0.6 * wv), view.w * 1.2);
        float torn = (vn2(p * 60.0) - 0.5) * 0.25 * w;
        float x = max(dist + torn, 0.0) / w;
        float2 flow = p - float2(0.0, view.z * 0.03);
        float pulse = vn2(flow * 7.0 + 9.0);
        float raft = smoothstep(0.72, 0.9, vn2(flow * 13.0 + float2(5.0, 1.0)) * 0.8 + 0.25 * vn2(flow * 37.0));
        float crust = smoothstep(1060.0, 860.0, Tcore);
        float seam = 1.0 - smoothstep(0.0, 0.22, abs(vn2(flow * 26.0 + 3.0) - 0.5));
        float T = Tcore - 140.0 * (1.0 - pulse) - 240.0 * raft * (1.0 - 0.5 * x) - 430.0 * smoothstep(0.35, 1.0, x)
                - 300.0 * crust * (1.0 - seam);
        float inChan = 1.0 - smoothstep(0.9, 1.05, x);
        // Two passes (view.y): first every channel's banks (so one stroke's bank never covers the next one's core at a
        // joint), then the molten cores and their glow over them (the brighter of theirs and what's there).
        if (view.y < 0.5) {
            float bank = (1.0 - smoothstep(1.0, 1.45, x + 0.3 * (vn2(p * 40.0) - 0.5))) * 0.7;
            float3 levee = float3(0.02, 0.016, 0.013) * (0.5 + 0.9 * vn2(p * 110.0)) * (0.7 + 0.5 * vn2(p * 23.0))
                         + blackbody(Tcore - 420.0) * (0.3 * exp(-max(x - 1.0, 0.0) / 0.15));
            float a2 = bank * in.info.z;
            if (a2 < 0.003) discard_fragment();
            return float4(levee * a2, a2);
        }
        float3 core = blackbody(T) * (0.4 * inChan);
        float3 glow = blackbody(Tcore - 330.0) * (0.2 * in.info.w * exp(-max(x - 0.9, 0.0) / 0.55) * (1.0 - inChan));
        float3 c = (core + glow) * in.info.z;
        float a2 = inChan * in.info.z;
        if (a2 < 0.003 && max(c.r, max(c.g, c.b)) < 0.002) discard_fragment();
        return float4(c, a2);
    }
    """
}
