/// Metal source for Moonlit Lake: ridges and pines, the lake (reflecting the Living Sky through Lake Ripples),
/// reeds, fireflies and a glassy keyboard. Built on SkyShaders.common so reflections use the very same sky.
/// Smooth rules: no ray marching, ≤ 3 noise octaves, ≤ 32 ripples per pixel on Smooth.
enum MoonlitLakeShaders {
    static let source = SkyShaders.common + """
    struct LakeU {
        float4 a;           // keys top (NDC y), time, glitter 0…1, mist 0…1
        float4 b;           // reeds 0…1, wind, ripple count, night 0…1
        float4 light;       // main light direction (moon or sun), intensity
        float4 lightColor;  // rgb, drift scale
        float4 rip[64];     // ripple centre across (s), out (f), ring radius, amplitude
        float4 ripB[64];    // ring width, wavenumber, glow, unused
    };
    struct LakeOut { float4 pos [[position]]; float2 ndc; };

    vertex LakeOut lake_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        LakeOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // Ridge heights (radians) around the horizon: periodic in azimuth, so no seam anywhere.
    float ridgeFar(float az) {
        float n = fbm3(float3(cos(az) * 2.2, sin(az) * 2.2, 3.7), 3);
        return (2.0 + 7.0 * n * n) * 0.0174533;
    }
    float ridgeNear(float az) {
        float n = fbm3(float3(cos(az) * 4.0 + 9.0, sin(az) * 4.0, 1.3), 2);
        return (0.6 + 2.6 * n) * 0.0174533;
    }
    // Pines along the near ridge: one tree per cell, a stacked-tier silhouette. `slope` is the cone's steepness
    // (d height / d azimuth, the tiers' saw-tooth left out): rime needs the flank's normal.
    float pines(float az, thread float& slope) {
        const float cells = 520.0;
        slope = 0.0;
        float x = (az / 6.2831853 + 0.5) * cells;
        float cell = floor(x), u = x - cell;
        float3 h = hash33(float3(cell, 4.0, 2.0));
        if (h.x > 0.72) return 0.0;
        float centre = 0.3 + 0.4 * h.y, half_ = 0.18 + 0.2 * h.z;
        float d = abs(u - centre) / half_;
        if (d >= 1.0) return 0.0;
        float height = (0.35 + 1.1 * h.y * h.z + 0.25 * h.x) * 0.0174533;
        float tiers = 0.82 + 0.18 * fract(d * 3.0 + h.y);
        slope = -sign(u - centre) * height * tiers * cells / (6.2831853 * half_);
        return height * (1.0 - d) * tiers;
    }

    float3 ridgeColor(float alt, float az, constant SkyU& u, constant LakeU& l, bool farOnly, thread bool& hit) {
        float near = ridgeNear(az);
        float slope;
        float nearTop = near + pines(az, slope);
        float far = ridgeFar(az);
        float3 horizon = u.horizon.rgb, zenith = u.zenith.rgb;
        float mist = l.a.w, night = l.b.w;
        hit = true;
        if (!farOnly && alt < nearTop) {
            float rim = smoothstep(nearTop - 0.004, nearTop, alt) * 0.4;
            float3 c = zenith * 0.09 + horizon * 0.05 + l.lightColor.rgb * rim * 0.02 * l.light.w;
            // Rime on the pines and the ridge line (spec §6.4), in NDC-y units (radians ÷ the tangent of half the
            // view): within a pine, the depth below its top turned into the distance from its flank by the flank's
            // steepness; below the ridge line, the depth below the ridge (its own edge). The far shore's fringe is
            // drawn at two thirds the width of a near one. The feathers go round the horizon (no seam), so the
            // lake's reflection shows the same ones.
            bool inPine = alt >= near;
            float inside = (inPine ? (nearTop - alt) * rsqrt(1.0 + slope * slope) : near - alt) * 1.5 / u.up.w;
            if (rimeNear(u, inside)) {
                float feather = fbm3(float3(cos(az) * 150.0, sin(az) * 150.0, alt * 150.0), 2);
                c = mix(c, rimeColor(u), rimeFringe(u, inside, float2(inPine ? -slope : 0.0, 1.0), feather));
            }
            return c;
        }
        if (alt < far) {
            // Aerial perspective: the far ridge is a hazy silhouette, darker than the sky, lighter than the pines.
            float3 c = mix(horizon, zenith, 0.5) * 0.28;
            float haze = saturate(0.3 + 0.5 * mist) * (0.55 + 0.45 * exp(-max(alt, 0.0) / 0.02));
            c += l.lightColor.rgb * 0.012 * l.light.w * night;   // moonlight on the far slopes
            return mix(c, horizon * (1.0 + 0.1 * night), haze * 0.55);
        }
        hit = false;
        return float3(0);
    }

    float3 cameraRay(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    // Reeds near the left and right edges, swaying with the wind. Returns coverage 0…1, and through `rime` the rime
    // fringe on the nearest reed's edge (its feathers ride the reed as it sways).
    float reeds(float2 p, constant LakeU& l, constant SkyU& u, thread float& rime) {
        rime = 0.0;
        float amount = l.b.x;
        if (amount < 0.01 || abs(p.x) < 0.62) return 0.0;
        float side = p.x < 0.0 ? -1.0 : 1.0;
        float base = l.a.x, time = l.a.y, wind = l.b.y;
        float cover = 0.0, inside = -1.0, edgeSide = 0.0, along = 0.0;
        for (int i = 0; i < 14; i++) {
            float3 h = hash33(float3(float(i), side * 7.0, 11.0));
            if (h.z > amount + 0.15) continue;
            float x0 = side * (0.66 + 0.36 * h.x);
            float height = (0.12 + 0.32 * h.y) * (0.6 + 0.6 * amount);
            float t = (p.y - base) / height;
            if (t < 0.0 || t > 1.0) continue;
            float sway = (0.012 + 0.035 * wind) * sin(time * (0.7 + 0.6 * h.z) + h.x * 20.0);
            float x = x0 + sway * t * t + side * 0.03 * t * h.y;
            float w = 0.0045 * (1.0 - 0.75 * t);
            if (h.z < 0.35 && t > 0.72 && t < 0.9) w = 0.009;   // a cattail head
            float c = smoothstep(w, w * 0.4, abs(p.x - x));
            if (c > cover) { inside = w - abs(p.x - x); edgeSide = p.x < x ? -1.0 : 1.0; along = p.x - x + x0 + float(i) * 3.1; }
            cover = max(cover, c);
        }
        // NDC x → NDC-y units: × the aspect (tanH / tanV).
        float aspect = u.right.w / u.up.w;
        if (cover > 0.0 && rimeNear(u, inside * aspect)) {
            rime = rimeEdge(u, inside * aspect, float2(edgeSide, 0.0), float2(along * aspect, p.y));
        }
        return cover;
    }

    fragment ColorDepth lake_fragment(LakeOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant LakeU& l [[buffer(1)]],
                                  texture2d<float> stars [[texture(0)]], texture2d<float> cell [[texture(9)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < l.a.x) {   // under the keyboard
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.1, 0, 0, 1);
            return out;
        }
        float3 d = cameraRay(p, u);
        float alt = asin(clamp(d.z, -1.0, 1.0)), az = atan2(d.x, d.y);
        float time = l.a.y, mist = l.a.w, night = l.b.w;
        float3 horizon = u.horizon.rgb;
        float3 mistCol = horizon * (1.05 + 0.15 * night) + l.lightColor.rgb * 0.015 * l.light.w * night;

        float reedRime;
        float reed = reeds(p, l, u, reedRime);
        float3 col;
        float depth = 1.0;
        if (alt >= 0.0) {
            if (alt > 0.11 && reed < 0.01) discard_fragment();   // above the tallest ridge: the dome shows
            bool hit;
            float3 r = ridgeColor(alt, az, u, l, false, hit);
            if (!hit && reed < 0.01) discard_fragment();
            col = hit ? r : float3(0);
            depth = hit ? 0.97 : 1.0;
            if (hit) col = mix(col, mistCol, mist * 0.55 * exp(-alt / 0.02));
            if (!hit) {
                float mm;
                col = skyRadiance(d, u, mm, stars, cell);
            }
        } else {
            // The water: where the ray meets the lake (camera 1 unit above it).
            float t = 1.0 / max(-d.z, 1e-4);
            float3 P = d * t;
            float2 fwd = normalize(u.forward.xy), rgt = float2(fwd.y, -fwd.x);
            float f = dot(P.xy, fwd), s = dot(P.xy, rgt);
            float2 slope = float2(0), q = float2(s, f);
            float glow = 0.0;
            int count = int(l.b.z + 0.5);
            for (int i = 0; i < 64; i++) {
                if (i >= count) break;
                float2 delta = q - l.rip[i].xy;
                float r = length(delta);
                float x = r - l.rip[i].z, w = l.ripB[i].x;
                if (abs(x) > 3.0 * w) continue;
                float band = exp(-(x * x) / (w * w));
                float k = l.ripB[i].y;
                float dh = l.rip[i].w * k * cos(k * x) * band;
                slope += dh * delta / max(r, 1e-3);
                glow += l.ripB[i].z * band * (0.5 + 0.5 * sin(k * x));
            }
            // A calm lake still breathes: small wind-driven waves.
            float drift = l.lightColor.w, wind = l.b.y;
            float2 wq = q * float2(2.6, 1.3) + float2(time * 0.15 * drift, time * 0.06 * drift);
            float2 calm = float2(vnoise3(float3(wq, time * 0.15)), vnoise3(float3(wq * 1.7 + 5.0, time * 0.2))) - 0.5;
            slope += calm * (0.035 + 0.25 * wind);
            // Finer wavelets break up the moon's mirror image near the shore.
            float2 fine = float2(vnoise3(float3(q * 6.0, time * 0.5)), vnoise3(float3(q * 6.0 + 9.0, time * 0.55))) - 0.5;
            slope += fine * 0.04;
            slope /= (1.0 + f * 0.015);   // far rings fade into the mirror
            float3 nrm = normalize(float3(-(slope.x * rgt.x + slope.y * fwd.x), -(slope.x * rgt.y + slope.y * fwd.y), 1.0));
            float3 rd = reflect(d, nrm);
            rd.z = max(rd.z, 0.002);
            rd = normalize(rd);
            float ralt = asin(rd.z), raz = atan2(rd.x, rd.y);
            bool hit;
            float3 refl = ridgeColor(ralt, raz, u, l, false, hit);
            if (!hit) {
                float mm;
                refl = skyRadiance(rd, u, mm, stars, cell);
            }
            float cosT = saturate(-dot(d, nrm));
            float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            float3 deep = u.zenith.rgb * 0.06 + float3(0.002, 0.005, 0.007);
            col = mix(deep, refl, fres);

            // The moon's (or sun's) path: a soft sheen broken into glints.
            float glitter = l.a.z;
            float3 L = l.light.xyz;
            float2 g = float2(vnoise3(float3(q * 7.0, time * 1.4)), vnoise3(float3(q * 7.0 + 13.0, time * 1.6))) - 0.5;
            float3 mn = normalize(nrm + float3(g.x * 0.3, g.y * 0.3, 0));
            float sd = saturate(dot(reflect(d, mn), L));
            float sparkle = smoothstep(0.62 - 0.22 * glitter, 0.8, vnoise3(float3(q * 13.0, time * 2.5)));
            float spec = pow(sd, 700.0) * sparkle * (2.0 + 6.0 * glitter) * smoothstep(90.0, 25.0, f) + pow(sd, 50.0) * 0.18;
            col += l.lightColor.rgb * spec * l.light.w * (0.35 + 0.65 * glitter);

            // Ring crests catch the moonlight even off the path.
            col += float3(0.85, 0.9, 1.0) * glow * (0.06 + 0.14 * night) / (1.0 + f * 0.06) * (0.4 + l.light.w * 0.3);

            // Mist lying on the water, thicker far away.
            col = mix(col, mistCol, saturate(mist * (0.15 + 0.85 * (1.0 - exp(-f / 30.0)))) * 0.8);
            depth = saturate(f / 40.0);
        }
        col = mix(col, u.zenith.rgb * 0.05 + float3(0.001, 0.0015, 0.002), reed);
        if (reedRime > 0.0) col = mix(col, rimeColor(u), reedRime * reed);
        if (reed > 0.5) depth = 0.02;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // Fireflies: x, y (NDC), size, alpha.
    struct GlowOut { float4 pos [[position]]; float2 uv; float alpha; };
    vertex GlowOut firefly_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4* fs [[buffer(0)]],
                                  constant float4& aspect [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float4 f = fs[iid];
        GlowOut o;
        o.uv = c[vid];
        o.pos = float4(f.xy + c[vid] * float2(f.z / aspect.x, f.z), 0, 1);
        o.alpha = f.w;
        return o;
    }
    fragment float4 firefly_fragment(GlowOut in [[stage_in]]) {
        float r2 = dot(in.uv, in.uv);
        float core = exp(-r2 * 8.0), halo = exp(-r2 * 2.5) * 0.3;
        float a = (core + halo) * in.alpha;
        return float4(float3(1.0, 0.86, 0.42) * 4.0 * a, 0.0);
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light).
    struct KeyInstance { float4 rect; float4 info; };
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex KeyOut lake_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth lake_keys_fragment(KeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.004, 0.005, 0.007) : float3(0.025, 0.03, 0.04);
        float sheen = pow(in.uv.y, 6.0) * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 silver = float3(0.85, 0.9, 1.0);
        float3 c = base + silver * sheen * (0.4 + light) + silver * glow * (1.6 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.1, 0, 0, 1);
        return o;
    }
    """
}
