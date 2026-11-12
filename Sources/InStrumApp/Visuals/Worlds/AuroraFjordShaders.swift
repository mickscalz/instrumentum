/// Metal source for Aurora Fjord (spec §8.1): steep snow-streaked walls framing a V of sky over the sea end, the still
/// black water mirroring the Living Sky (its aurora, stars and pillars) and the walls, a fishing village's warm lights
/// with their reflections (and pillars in diamond dust), drifting ice floes catching the aurora's light on their tops,
/// the jetty's snowy rails and ice-blue glass keys. Built on SkyShaders.common, so the water mirrors the very same sky.
/// Smooth rules: no ray marching (the walls are analytic silhouettes, the water one mirror bounce), ≤ 3 noise octaves
/// (2 on Smooth), squares and powers written out (no pow).
enum AuroraFjordShaders {
    static let source = SkyShaders.common + """
    struct FjordU {
        float4 a;          // keys top (NDC y), time (s, wrapped to the hour), aspect, noise octaves (2 on Smooth, 3 above)
        float4 b;          // night 0…1, day 0…1, mist 0…1, wind 0…1
        float4 c;          // swell 0…1, sparkle (after the flash limiter), village lights 0…1 (0 when unlit), alpenglow 0…1
        float4 sun;        // direction (east-north-up), strength 0…1
        float4 sunColor;   // rgb, unused
        float4 moon;       // direction (east-north-up), strength 0…1
        float4 aurora;     // the aurora's light on snow, ice and water (rgb), aurora amount 0…1
        float4 ambient;    // the sky's light on the scene (rgb), cloud cover
        float4 swell;      // the two swell components' phases (radians, wrapped), unused, unused
        float4 corona;     // Fire & Neon §5.5: the corona overhead, the surge (both after the sparkle), the magnetic zenith's altitude (rad), unused
    };

    // The fjord in the view's frame (metres; φ in radians across the view, + to the right).
    constant float kEye = 2.7;                              // the eye above the water
    constant float kOpenL = 0.13, kOpenR = 0.16;            // where the walls end at the sea, left and right of the view
    constant float kWallK = 0.55;                           // the walls' height over their distance
    constant float kWallFoot = 250.0, kWallSpread = 0.08;   // their feet either side of the jetty, and how they spread
    // The clock (f.a.y) wraps at the hour; what moves with it reads fjordNoise, which repeats every 64 cells, at whole
    // multiples of kFjordTick (64 cells an hour), so it comes round exactly at the wrap and never jumps.
    constant float kFjordTick = 64.0 / 3600.0;

    /// vnoise3 on a lattice wrapped every `n` cells along each axis (`n` whole): the same noise, but periodic.
    float fjordNoise(float3 p, float n) {
        float3 i = floor(p), f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float3 a = i - n * floor(i / n);
        float3 b = a + 1.0;
        b = float3(b.x >= n ? 0.0 : b.x, b.y >= n ? 0.0 : b.y, b.z >= n ? 0.0 : b.z);
        float h0 = hash13(a), h1 = hash13(float3(b.x, a.y, a.z)), h2 = hash13(float3(a.x, b.y, a.z)), h3 = hash13(float3(b.x, b.y, a.z));
        float h4 = hash13(float3(a.x, a.y, b.z)), h5 = hash13(float3(b.x, a.y, b.z)), h6 = hash13(float3(a.x, b.y, b.z)), h7 = hash13(b);
        return mix(mix(mix(h0, h1, u.x), mix(h2, h3, u.x), u.y), mix(mix(h4, h5, u.x), mix(h6, h7, u.x), u.y), u.z);
    }

    struct FjordOut { float4 pos [[position]]; float2 ndc; };

    vertex FjordOut fjord_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        FjordOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float3 fjordRay(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }
    /// Level unit vectors down the fjord (the view's heading) and across it (to the right).
    float3 fjordAhead(constant SkyU& u) { float2 f = normalize(u.forward.xy); return float3(f, 0.0); }
    float3 fjordAcross(constant SkyU& u) { float2 f = normalize(u.forward.xy); return float3(f.y, -f.x, 0.0); }
    /// A direction's angle across the view (radians, + to the right).
    float fjordPhi(float3 d, constant SkyU& u) { return atan2(dot(d, fjordAcross(u)), dot(d, fjordAhead(u))); }

    /// Two low islands far out in the sea end (their height over the horizon, radians).
    float fjordIslands(float phi) {
        float a = smoothstep(0.0, 1.0, 1.0 - abs(phi + 0.045) / 0.032) * 0.0055;
        float b = smoothstep(0.0, 1.0, 1.0 - abs(phi - 0.088) / 0.024) * 0.0034;
        return max(a, b);
    }

    /// The skyline over φ (radians over the horizon): each wall a long ridge beside the fjord (atan(k·sin|φ|), the
    /// profile of a ridge running down the view), cut into peaks and notches by ≤ 3 octaves of noise and stepping down
    /// to low headlands at the sea end; the far islands in the opening. `side` is −1 for the left wall, +1 the right.
    float fjordSkyline(float phi, int octaves, thread float& side) {
        side = phi < 0.0 ? -1.0 : 1.0;
        float a = abs(phi);
        float edge = side < 0.0 ? kOpenL : kOpenR;
        float k = side < 0.0 ? kWallK : kWallK * 1.12;
        float ridge = atan(k * sin(min(a, 1.5)));
        float n = fbm3(float3(phi * 9.0, side * 3.1, 1.7), octaves);
        float wall = ridge * (0.72 + 0.6 * n) * (0.3 + 0.7 * smoothstep(edge - 0.015, edge + 0.1, a));
        return mix(fjordIslands(phi), wall, smoothstep(edge - 0.006, edge + 0.006, a));
    }

    /// Whether φ looks out through the sea end (no wall there).
    bool fjordOpen(float phi) { return phi < 0.0 ? -phi < kOpenL : phi < kOpenR; }

    /// How far the wall's foot is at |φ| (metres).
    float fjordWallDistance(float a) {
        float b = min(a, 1.45);
        return kWallFoot / max(tan(b) - kWallSpread, 0.004) / cos(b);
    }

    /// The haze and the fog banks that hide the far end (the fog glows faintly with the aurora).
    float3 fjordMist(constant SkyU& u, constant FjordU& f) {
        return u.horizon.rgb * (1.05 + 0.15 * f.b.x) + f.aurora.rgb * 0.6;
    }

    /// The far islands: dark humps deep in the haze on the sea horizon.
    float3 fjordIslandColour(constant SkyU& u, constant FjordU& f) {
        float3 c = f.ambient.rgb * 0.25 + f.aurora.rgb * 0.2;
        return mix(c, fjordMist(u, f), saturate(0.55 + 0.4 * f.b.z));
    }

    /// A wall's face at (φ, alt): snow, with dark rock showing through in ribs running down the fall line (slanting
    /// toward the fjord), cliff bands on the sheer lower faces and bare patches; lit by the sky, the sun or the moon and
    /// the aurora (whose green the snow catches); alpenglow on the upper faces at dawn and dusk; the far falls on the
    /// right wall; haze and fog with distance.
    float3 fjordWallColour(float phi, float alt, float top, float side, constant SkyU& u, constant FjordU& f) {
        float a = abs(phi);
        float r = fjordWallDistance(a);
        float frac = saturate(alt / max(top, 1e-4));                                // 0 at the foot … 1 on the crest
        float3 F = fjordAhead(u), R = fjordAcross(u);
        float3 inward = R * (-side);
        float x = phi * 60.0, y = alt * 20.0;
        float fields = vnoise3(float3(x * 0.22 + y * 0.1, y * 0.5 - x * 0.05, side * 5.0 + 1.0));    // broad patches
        float gn = vnoise3(float3(x * 0.8 + 0.4 * y * side, y * 0.2, side * 4.0 + 2.0));             // ribs down the fall line
        float rib = smoothstep(0.72, 0.94, 1.0 - abs(2.0 * gn - 1.0));
        float band = smoothstep(0.55, 0.78, vnoise3(float3(x * 0.12, y * 1.3 + x * 0.02, side * 7.0 + 4.0)));   // cliff bands
        float3 n = normalize(inward * (0.85 + 0.5 * (gn - 0.5)) - F * (0.2 + 0.6 * (fields - 0.5)) + float3(0.0, 0.0, 0.45));
        float rock = max(rib * (0.55 + 0.45 * fields), max(band * (1.0 - 0.8 * frac), smoothstep(0.6, 0.78, 1.0 - fields) * (1.0 - frac)));
        float snow = saturate(1.0 - 1.15 * rock + 0.3 * smoothstep(0.75, 1.0, frac) + 0.2 * (1.0 - smoothstep(0.0, 0.08, frac)));
        float3 albedo = mix(float3(0.13, 0.125, 0.135), float3(0.9, 0.93, 1.0), snow);
        float sunFace = saturate(dot(n, f.sun.xyz)), moonFace = saturate(dot(n, f.moon.xyz));
        float3 sunC = f.sunColor.rgb * f.sun.w, moonC = float3(0.55, 0.63, 0.82) * (0.35 * f.moon.w);
        float3 lit = f.ambient.rgb * (0.5 + 0.35 * snow) + sunC * sunFace + moonC * moonFace + f.aurora.rgb * (0.25 + 0.9 * snow);
        float3 col = albedo * lit;
        // By day shaded snow goes blue under the sky; faces in the sun stay white.
        col *= mix(float3(0.7, 0.8, 1.06), float3(1.0), saturate(sunFace * f.sun.w * 2.5 + 0.35 + 0.65 * (1.0 - f.b.y)));
        // Alpenglow: the upper faces turned to the low sun glow pink-orange.
        col += float3(1.0, 0.42, 0.32) * (f.c.w * 0.85 * smoothstep(0.35, 0.95, frac) * saturate(sunFace * 1.4 + 0.1) * (0.4 + 0.6 * snow));
        // The far falls: a thread of white down the right wall.
        if (side > 0.0) {
            float fx = (phi - 0.43) / 0.0035;
            float fall = exp(-fx * fx) * smoothstep(0.05, 0.15, frac) * (1.0 - smoothstep(0.75, 0.95, frac));
            if (fall > 0.01) {
                float flow = 0.6 + 0.4 * fjordNoise(float3(phi * 400.0, alt * 60.0 + f.a.y * (84.0 * kFjordTick), 3.0), 64.0);
                col = mix(col, (f.ambient.rgb + sunC * 0.5 + moonC + f.aurora.rgb) * 0.9, fall * flow * 0.8);
            }
        }
        // Aerial perspective, then the fog banks.
        float far = 1.0 - exp(-r / 7000.0);
        col = mix(col, u.horizon.rgb * (1.0 + 0.1 * f.b.x), saturate(0.1 + 0.5 * far));
        col = mix(col, fjordMist(u, f), saturate(f.b.z * (0.2 + 1.3 * (1.0 - exp(-r / 2500.0)))) * 0.92);
        return col;
    }

    /// The still water along ray d (below the horizon): a mirror of the walls and the sky (its aurora, stars and
    /// pillars), broken by a slow swell and the wind's ripples, black at night and grey-green by day, with the sun's or
    /// the moon's path and mist far off. `depth` returns the depth-of-field depth.
    float3 fjordWater(float3 d, constant SkyU& u, constant FjordU& f, texture2d<float> stars, int octaves, thread float& depth) {
        float t = kEye / max(-d.z, 1e-4);
        float3 P = d * t;
        float3 F = fjordAhead(u), R = fjordAcross(u);
        float2 q = float2(dot(P, R), dot(P, F));                   // metres across and down the fjord
        float far = length(P.xy);
        float time = f.a.y, wind = f.b.w;
        float footprint = far * u.weather.w / max(-d.z, 1e-3);     // metres of water one pixel spans
        float2 slope = float2(0.0);
        // The swell: two long, low components rolling up the fjord, faded where a pixel spans a wavelength.
        float amp = 0.75 * f.c.x;
        slope.y += amp * 0.0898 * cos(0.0898 * q.y + f.swell.x) * (1.0 - smoothstep(35.0, 70.0, footprint));
        float2 d2 = float2(0.28, 0.96);
        slope += d2 * (amp * 0.5 * 0.137 * cos(0.137 * dot(d2, q) + f.swell.y) * (1.0 - smoothstep(23.0, 46.0, footprint)));
        // Cat's-paws: the wind's ripples (one octave on Smooth, two above), faded where a pixel spans them.
        float kw = 1.0 - smoothstep(1.5, 4.5, footprint);
        // Everything here that moves with the clock does so at whole multiples of kFjordTick (see fjordNoise).
        float tick = time * kFjordTick;
        if (kw > 0.001) {
            float2 wq = q * float2(0.7, 0.35) + float2(11.0, 4.0) * tick;
            float2 wq2 = q * float2(1.19, 0.595) + 5.0 + float2(19.0, 7.0) * tick;
            float2 w = float2(fjordNoise(float3(wq, 8.0 * tick), 64.0), fjordNoise(float3(wq2, 10.0 * tick), 64.0)) - 0.5;
            slope += w * ((0.01 + 0.14 * wind) * kw);
        }
        float kf = 1.0 - smoothstep(0.5, 1.5, footprint);
        if (octaves > 2 && kf > 0.001) {
            float2 fq = q * 2.4;
            float2 w2 = float2(fjordNoise(float3(fq, 28.0 * tick), 64.0), fjordNoise(float3(fq + 9.0, 31.0 * tick), 64.0)) - 0.5;
            slope += w2 * ((0.006 + 0.05 * wind) * kf);
        }
        float3 nrm = normalize(float3(-(slope.x * R.x + slope.y * F.x), -(slope.x * R.y + slope.y * F.y), 1.0));
        float3 rd = reflect(d, nrm);
        rd.z = max(rd.z, 0.002);
        rd = normalize(rd);
        // What it mirrors: a wall where one stands, else the sky.
        float rphi = fjordPhi(rd, u), ralt = asin(clamp(rd.z, -1.0, 1.0));
        float rside;
        float rtop = fjordSkyline(rphi, octaves, rside);
        float3 refl;
        if (ralt < rtop) {
            refl = fjordOpen(rphi) ? fjordIslandColour(u, f) : fjordWallColour(rphi, ralt, rtop, rside, u, f);
        } else {
            float mm;
            refl = skyRadiance(rd, u, mm, stars);
        }
        float cosT = saturate(-dot(d, nrm));
        float m = 1.0 - cosT, m2 = m * m;
        float fres = 0.02 + 0.98 * m2 * m2 * m;
        float3 dark = float3(0.002, 0.004, 0.006) + f.ambient.rgb * 0.02;
        float3 greyGreen = float3(0.055, 0.085, 0.068) * (0.4 + 0.6 * f.sun.w) + f.ambient.rgb * 0.03;
        float3 col = mix(mix(dark, greyGreen, f.b.y), refl, fres);
        // The sun's and the moon's paths: a soft sheen broken into glints near by (gentle visuals halve them).
        float kg = 1.0 - smoothstep(0.8, 2.4, footprint);
        float2 g = (float2(fjordNoise(float3(q * 1.3, 68.0 * tick), 64.0), fjordNoise(float3(q * 1.3 + 13.0, 79.0 * tick), 64.0)) - 0.5) * kg;
        float3 gn = normalize(nrm + float3(g * 0.12, 0.0));
        float3 gr = reflect(d, gn);
        float ss = saturate(dot(gr, f.sun.xyz)), sm = saturate(dot(gr, f.moon.xyz));
        float glint = f.c.y, near = 1.0 - smoothstep(60.0, 1500.0, far);
        col += f.sunColor.rgb * (f.sun.w * near * (exp(-700.0 * (1.0 - ss)) * (4.0 * glint) + 0.15 * exp(-50.0 * (1.0 - ss))));
        col += float3(0.78, 0.85, 1.0) * (f.moon.w * near * (exp(-700.0 * (1.0 - sm)) * (4.0 * glint) + 0.12 * exp(-50.0 * (1.0 - sm))));
        // Mist lying on the water, thicker far off.
        col = mix(col, fjordMist(u, f), saturate(f.b.z * (0.12 + 0.88 * (1.0 - exp(-far / 900.0)))) * 0.85);
        depth = saturate(far / 600.0);
        return col;
    }

    fragment ColorDepth fjord_scene_fragment(FjordOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant FjordU& f [[buffer(1)]],
                                             texture2d<float> stars [[texture(0)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < f.a.x) {   // under the keyboard (the keys draw there)
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.05, 0, 0, 1);
            return out;
        }
        float3 d = fjordRay(p, u);
        float alt = asin(clamp(d.z, -1.0, 1.0));
        if (alt > 0.75) {   // above the highest peak: the dome shows
            discard_fragment();
            out.color = float4(0, 0, 0, 1); out.depth = float4(1, 0, 0, 1);
            return out;
        }
        int octaves = int(f.a.w + 0.5);
        float phi = fjordPhi(d, u);
        float side;
        float top = fjordSkyline(phi, octaves, side);
        bool open = fjordOpen(phi);
        float wallDepth = 0.45 + 0.5 * saturate(fjordWallDistance(abs(phi)) / 6000.0);
        float3 col;
        float depth;
        if (alt >= 0.0) {
            if (alt >= top) {   // the V of sky: the dome shows
                discard_fragment();
                out.color = float4(0, 0, 0, 1); out.depth = float4(1, 0, 0, 1);
                return out;
            }
            col = open ? fjordIslandColour(u, f) : fjordWallColour(phi, alt, top, side, u, f);
            depth = open ? 0.98 : wallDepth;
        } else {
            float dip = open ? 0.0 : atan(kEye / fjordWallDistance(abs(phi)));
            if (-alt < dip) {
                col = fjordWallColour(phi, 0.0, top, side, u, f);   // the wall's foot, just below the horizon
                depth = wallDepth;
            } else {
                col = fjordWater(d, u, f, stars, octaves, depth);
            }
        }
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the village's lights
    // rect: NDC x0, y0, x1, y1 of the quad; dir: east-north-up direction, angular radius (rad); colour: rgb × strength,
    // the depression of its mirror image on the water (rad).
    struct VillageLight { float4 rect; float4 dir; float4 colour; };
    struct VillageOut { float4 pos [[position]]; float2 ndc; float4 dir; float4 colour; };

    vertex VillageOut fjord_village_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant VillageLight* ls [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        VillageLight l = ls[iid];
        float2 p = mix(l.rect.xy, l.rect.zw, c[vid]);
        VillageOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        o.dir = l.dir;
        o.colour = l.colour;
        return o;
    }

    /// A warm window light on the far shore: its glow, its reflection stretched toward you by the ripples, and in
    /// diamond dust a pillar over and under it with the sky's own profile (lightPillar). Additive.
    fragment float4 fjord_village_fragment(VillageOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant FjordU& f [[buffer(1)]]) {
        float3 d = fjordRay(in.ndc, u);
        float3 L = in.dir.xyz;
        float rad = in.dir.w;
        float alt = asin(clamp(d.z, -1.0, 1.0));
        float ang = acos(clamp(dot(d, L), -1.0, 1.0));
        float x = ang / rad;
        // The core, and a soft halo that fades out within its quad (about 2° across).
        float glow = exp(-x * x) * 3.0 + exp(-ang / (rad * 3.0)) * 0.12 * (1.0 - smoothstep(0.02, 0.034, ang));
        float pillar = u.dust.y;
        float column = pillar > 0.001 ? lightPillar(d, alt, L, rad) * (pillar * 0.3) : 0.0;
        float refl = 0.0;
        if (alt < 0.0) {
            float below = -alt - in.colour.w;          // below its mirror image
            float dAz = atan2(d.x, d.y) - atan2(L.x, L.y);
            dAz -= 6.2831853 * floor((dAz + 3.14159265) / 6.2831853);
            float across = dAz * cos(alt) / (rad * (1.2 + 2.0 * f.b.w));
            float len = 0.006 + 0.05 * f.b.w + 0.02 * f.c.x;
            float along = below > 0.0 ? exp(-below / len) : exp(-below * below / (rad * rad * 4.0));
            float glints = 0.35 + 0.65 * smoothstep(0.35, 0.75, fjordNoise(float3(alt * 700.0, dAz * 200.0, f.a.y * (96.0 * kFjordTick)), 256.0));
            refl = exp(-across * across) * along * glints * 0.7;
        }
        float fog = 1.0 - 0.85 * f.b.z;
        return float4(in.colour.rgb * ((glow + column + refl) * fog), 0.0);
    }

    // ---------------------------------------------------------------- ice floes
    // a: centre across, down the fjord (m), half length, half width (m); b: turn (rad), alpha (fading at the wrap),
    // seed, unused. Each floe draws twice: its side at the water line (instance 2i), then its top (2i + 1).
    struct FloeInstance { float4 a; float4 b; };

    /// A floe's outline in its own frame: a jittered hexagon of broken ice with a ragged edge (negative inside).
    float fjordFloeShape(float2 uv, float seed) {
        float d = -1e3;
        for (int k = 0; k < 6; k++) {
            float3 h = hash33(float3(seed * 13.0, float(k), 5.0));
            float a = (float(k) + 0.3 * (h.x - 0.5)) * 1.0471976;
            d = max(d, dot(uv, float2(cos(a), sin(a))) - (0.68 + 0.3 * h.y));
        }
        return d + 0.05 * (vnoise3(float3(uv * 5.0 + seed * 3.0, seed)) - 0.5);
    }
    struct FloeOut { float4 pos [[position]]; float2 uv; float layer; float alpha; float seed; float far; };

    vertex FloeOut fjord_floe_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant FloeInstance* fl [[buffer(0)]],
                                     constant SkyU& u [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        FloeInstance k = fl[iid / 2];
        float layer = float(iid % 2);
        float2 q = c[vid] * 1.3;
        float ca = cos(k.b.x), sa = sin(k.b.x);
        float2 local = float2(q.x * k.a.z, q.y * k.a.w);
        float2 g = k.a.xy + float2(local.x * ca - local.y * sa, local.x * sa + local.y * ca);
        float3 P = fjordAcross(u) * g.x + fjordAhead(u) * g.y + float3(0.0, 0.0, -kEye + 0.22 * layer);
        FloeOut o;
        o.pos = float4(dot(P, u.right.xyz) / u.right.w, dot(P, u.up.xyz) / u.up.w, 0.0, dot(P, u.forward.xyz));
        o.uv = q;
        o.layer = layer;
        o.alpha = k.b.y;
        o.seed = k.b.z;
        o.far = length(g);
        return o;
    }

    /// A pale slab of broken ice: a snowy top lit by the sky, the moon or the sun and tinted by the aurora, its wet
    /// rim, and a darker blue-ice side showing below it. Premultiplied alpha.
    fragment float4 fjord_floe_fragment(FloeOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant FjordU& f [[buffer(1)]]) {
        float dist = fjordFloeShape(in.uv, in.seed);
        float aa = max(fwidth(dist) * 1.2, 1e-3);
        float cover = 1.0 - smoothstep(-aa, 0.0, dist);
        if (cover < 0.002) discard_fragment();
        float3 amb = f.ambient.rgb;
        float3 sunC = f.sunColor.rgb * f.sun.w, moonC = float3(0.55, 0.63, 0.82) * (0.35 * f.moon.w);
        float3 col;
        if (in.layer > 0.5) {
            float drift = 0.92 + 0.08 * vnoise3(float3(in.uv * 3.0, in.seed * 3.0));
            float3 top = float3(0.86, 0.92, 0.98) * drift;
            float3 lit = amb * 1.0 + sunC * max(f.sun.z, 0.0) + moonC * 1.4 * max(f.moon.z, 0.0) + f.aurora.rgb * 2.0;
            col = top * lit;
            col = mix(col, col * float3(0.7, 0.85, 1.0), smoothstep(-0.14, 0.0, dist) * 0.5);   // the wet rim
        } else {
            col = float3(0.2, 0.38, 0.48) * (amb * 0.7 + f.aurora.rgb * 0.8 + sunC * 0.25 + moonC * 0.5);
        }
        col = mix(col, fjordMist(u, f), saturate(f.b.z * (0.1 + 0.9 * (1.0 - exp(-in.far / 900.0)))) * 0.85);
        float a = cover * in.alpha;
        return float4(col * a, a);
    }

    // ---------------------------------------------------------------- Fire & Neon §5.5: the surge and its corona
    // An additive quad over the V of sky (the renderer sizes it: x0, y0, x1, y1 in NDC), drawn only while the curtains
    // surge or the corona shows, and never over the walls (the skyline is tested per pixel).
    //
    // The surge: the curtains brighten and ripple. The sky's own aurora carries the curtain; this adds the surge's fine
    // rays (two octaves along the band, far finer than the curtain's own, soft: never hard bars), a fold travelling along
    // it and its base swaying, mostly green, with a thin pink-magenta fringe along the lower edge (the band's geometry is
    // the sky shader's, from the same uniforms).
    //
    // The corona: rays along the field lines, which perspective draws converging on one point high overhead (the
    // magnetic zenith, set just above the frame's top: f.corona.z its altitude), fanning out from it, each of its own
    // length, violet-pink near the point and green further out, flickering slowly.
    struct CoronaOut { float4 pos [[position]]; float2 ndc; };

    vertex CoronaOut fjord_corona_vertex(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        float2 p = mix(rect.xy, rect.zw, c[vid]);
        CoronaOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    fragment float4 fjord_corona_fragment(CoronaOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant FjordU& f [[buffer(1)]]) {
        float k = f.corona.x, surge = f.corona.y;
        if (k <= 0.001 && surge <= 0.001) discard_fragment();
        float3 d = fjordRay(in.ndc, u);
        float alt = asin(clamp(d.z, -1.0, 1.0));
        if (alt <= 0.0) discard_fragment();
        float phi = fjordPhi(d, u);
        int octaves = int(f.a.w + 0.5);
        float side;
        float top = fjordSkyline(phi, octaves, side);
        float clear = smoothstep(top, top + 0.002, alt);
        if (clear <= 0.0) discard_fragment();
        // The clock wraps at the hour: the noise's time runs 256 cells an hour (its lattice's period), the waves whole
        // turns an hour, so nothing jumps at the wrap.
        float tt = f.a.y * (4.0 * kFjordTick);
        float tw = f.a.y * (6.2831853 / 3600.0);
        float3 col = float3(0);
        if (surge > 0.001) {
            float2 ph = u.aurora.xy;
            float3 P = float3(ph / max(length(ph), 1e-4), 0.0);
            float3 W = float3(P.y, -P.x, 0.0);
            float A = toRad(clamp(u.aurora.z, 0.5, 89.0));
            float3 Bv = P * cos(A) + float3(0.0, 0.0, sin(A));
            float3 Uv = float3(0.0, 0.0, cos(A)) - P * sin(A);
            float along = atan2(dot(d, W), dot(d, Bv));
            float h = toDeg(asin(clamp(dot(d, Uv), -1.0, 1.0)));
            float hb = h + 1.1 * sin(along * 14.0 - tw * 1500.0) + 0.5 * sin(along * 37.0 + tw * 2700.0);
            if (hb > -6.0 && hb < 60.0) {
                float r1 = fjordNoise(float3(along * 260.0 + 3.0 * tt, 1.5, tt), 256.0);
                float r2 = fjordNoise(float3(along * 610.0 - 5.0 * tt, 4.5, 2.0 * tt), 256.0);
                float rays = 0.4 + 0.6 * (0.6 * r1 + 0.4 * r2);
                rays *= rays;
                float lower = hb < 0.0 ? exp(hb / 0.9) : 1.0;
                float profile = lower * exp(-max(hb, 0.0) / 9.0);
                float fr = (hb + 0.7) / 0.8;
                float fringe = exp(-fr * fr);
                float ends = 1.0 - smoothstep(1.2, 1.5708, abs(along));
                float3 green = float3(0.22, 1.0, 0.42), pink = float3(1.0, 0.3, 0.62);
                col += (green * (profile * rays) + pink * (fringe * (0.35 + 0.65 * rays) * 0.5)) * (0.14 * surge * ends * saturate(u.night.x));
            }
        }
        if (k > 0.001) {
            float3 F = fjordAhead(u);
            float za = f.corona.z;
            float3 Z = F * cos(za) + float3(0.0, 0.0, sin(za));
            float3 e1 = normalize(cross(Z, F)), e2 = cross(e1, Z);       // e2 points down the sky, ahead
            float ang = atan2(dot(d, e1), dot(d, e2));
            float from = acos(clamp(dot(d, Z), -1.0, 1.0));
            float n = 0.65 * fjordNoise(float3(ang * 45.0, 2.0, tt), 256.0) + 0.35 * fjordNoise(float3(ang * 120.0, 5.0, 2.0 * tt), 256.0);
            float rays = smoothstep(0.3, 0.85, n);
            float reach = 0.25 + 0.45 * fjordNoise(float3(ang * 45.0, 9.0, 0.5 * tt), 256.0);
            float profile = smoothstep(0.02, 0.1, from) * exp(-from / reach) * (1.0 - smoothstep(0.85, 1.2, from));
            float3 green = float3(0.25, 1.0, 0.45), violet = float3(0.75, 0.3, 0.9);
            float3 c = mix(green, violet, smoothstep(0.3, 0.08, from));
            float flicker = 0.85 + 0.15 * sin(tw * 1100.0 + ang * 9.0);
            col += c * (0.22 * k * rays * profile * flicker * saturate(u.night.x + 0.3));
        }
        return float4(col * clear, 0.0);
    }

    // ---------------------------------------------------------------- Fire & Neon §5.5: an orca in the fjord
    // rect: the quad (NDC); local: metres at its corners (lo across, lo up from the water, hi across, hi up); info: its
    // fin out of the water 0…1, seconds since its blow (< 0: none), the blow's strength, the wind 0…1; tint: the night's
    // light on its breath (rgb), cover. Premultiplied.
    struct OrcaInstance { float4 rect; float4 local; float4 info; float4 tint; };
    struct OrcaOut { float4 pos [[position]]; float2 uv; float4 info; float4 tint; };

    vertex OrcaOut fjord_orca_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant OrcaInstance* os [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        OrcaInstance o = os[iid];
        OrcaOut out;
        out.pos = float4(mix(o.rect.xy, o.rect.zw, c[vid]), 0, 1);
        out.uv = mix(o.local.xy, o.local.zw, c[vid]);
        out.info = o.info;
        out.tint = o.tint;
        return out;
    }

    /// How much of the orca stands out of the water at q (metres across, up; 0…1 cover) with `fin` how far it has
    /// surfaced: its back, a low dark arc, and a bull's tall dorsal fin, a little swept back, its leading edge convex
    /// and its trailing edge hollow; `edge` hands back how near the silhouette's edge q is (0 deep inside … 1 on it).
    float fjordOrcaCover(float2 q, float fin, float aa, thread float& edge) {
        edge = 0.0;
        if (fin <= 0.01 || q.y < -0.05) return 0.0;
        float2 bq = (q - float2(-0.2, -0.62 + 0.3 * fin)) / float2(2.3, 0.7);
        float back = (length(bq) - 1.0) * 0.7;
        float base = 0.05 + 0.2 * fin;                  // where the fin leaves the back
        float h = 1.7 * fin;
        float t = (q.y - base) / h;
        float finD = 1.0;
        if (t > -0.2 && t < 1.05) {
            float tc = saturate(t);
            float bend = sin(3.14159265 * tc);
            float lead = mix(0.42, -0.32, tc) + 0.12 * bend;
            float trail = mix(-0.36, -0.32, tc) + 0.1 * bend * (1.0 - tc);
            finD = max(max(trail - q.x, q.x - lead), max(q.y - (base + h), base - 0.15 - q.y));
        }
        float dd = min(back, finD);
        dd = max(dd, -q.y);                              // the water's surface
        edge = exp(-max(-dd, 0.0) / 0.1);
        return 1.0 - smoothstep(-aa, aa, dd);
    }

    /// The orca surfacing in the still water: its back and tall fin near-black and wet, the sky and the aurora catching
    /// their edges and the fin's top, a thin bright line where the water wraps them, and their reflection darkening the
    /// mirrored sky (broken by the ripples). Its blow: a pale puff rising fast to about four metres, billowing, then
    /// drifting downwind and thinning over four seconds, lit by the night (the aurora's green muted in the mist), with a
    /// faint reflection. Premultiplied.
    fragment float4 fjord_orca_fragment(OrcaOut in [[stage_in]], constant FjordU& f [[buffer(1)]]) {
        float2 q = in.uv;
        float fin = in.info.x, age = in.info.y, strength = in.info.z, wind = in.info.w;
        float aa = max(fwidth(q.x), fwidth(q.y)) * 1.2 + 1e-4;
        float3 light = in.tint.rgb;
        float lum = dot(light, float3(0.3, 0.5, 0.2));
        float tw = f.a.y * (6.2831853 / 3600.0);
        // The body (and, below the water line, its reflection).
        float edge;
        float body = 0.0;
        float3 bodyCol = float3(0.0);
        float refl = 0.0;
        if (q.y >= 0.0) {
            body = fjordOrcaCover(q, fin, aa, edge);
            if (body > 0.0) {
                float tip = saturate((q.y - 0.3) / 1.6);
                float saddle = exp(-((q.x + 0.75) * (q.x + 0.75)) / 0.12) * exp(-((q.y - 0.12) * (q.y - 0.12)) / 0.03);
                bodyCol = float3(0.006, 0.007, 0.008) + light * (0.05 + 0.25 * edge + 0.12 * tip) + float3(0.05) * lum * saddle * 4.0;
                float wl = exp(-q.y / 0.035);
                bodyCol += light * (0.6 * wl);
            }
        } else {
            float ripple = 0.06 * sin(q.y * 9.0 + tw * 2400.0) + 0.03 * sin(q.y * 23.0 - tw * 3300.0);
            float e2;
            refl = fjordOrcaCover(float2(q.x + ripple, -q.y), fin, aa * 2.0, e2) * 0.75 * (1.0 - smoothstep(0.6, 2.0, -q.y));
        }
        // The blow.
        float breath = 0.0;
        if (age >= 0.0 && age < 4.5 && strength > 0.0) {
            float y = abs(q.y);
            float H = 3.8 * (1.0 - exp(-age / 0.3));
            float up = saturate(y / max(H, 0.1));
            float shift = 0.75 + (0.35 + 0.9 * wind) * age * up;
            float w = 0.12 + 0.45 * up + 0.35 * age;
            float x = q.x - shift;
            float column = exp(-(x * x) / (w * w)) * smoothstep(0.0, 0.25, y) * (1.0 - smoothstep(H - 0.5, H + 0.4, y));
            float2 hq = float2(x, y - (H - 0.35)) / float2(0.55 + 0.35 * age, 0.45 + 0.25 * age);
            float head = exp(-dot(hq, hq));
            float2 nq = float2(x * 1.8, (y - 0.5 * age) * 1.6);
            float n = 0.6 * vnoise3(float3(nq, age * 0.6 + 3.0)) + 0.4 * vnoise3(float3(nq * 2.3 + 7.0, age * 0.9));
            float fade = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(1.0, 4.5, age));
            breath = saturate(max(column, head) * (0.25 + 0.95 * n) * strength * fade * 0.55);
            if (q.y < 0.0) breath *= 0.3 * (1.0 - smoothstep(0.3, 1.5, -q.y));
        }
        float3 breathCol = mix(light, float3(0.85, 0.95, 1.0) * lum, 0.5) * 1.5;
        float a = breath + (body + refl) * (1.0 - breath);
        if (a < 0.002) discard_fragment();
        float3 col = breathCol * breath + bodyCol * (body * (1.0 - breath)) + float3(0.002, 0.003, 0.004) * (refl * (1.0 - breath));
        a *= in.tint.w;
        return float4(col * in.tint.w, a);
    }

    // ---------------------------------------------------------------- the jetty's rails
    // Clip-space corners (near or left low, far or right low, near high, far high) and info: kind (0 wood, 1 snow),
    // length (m), seed, unused.
    struct RailPart { float4 p0; float4 p1; float4 p2; float4 p3; float4 info; };
    struct RailOut { float4 pos [[position]]; float2 uv; float4 info; float across; };

    vertex RailOut fjord_rail_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant RailPart* parts [[buffer(0)]]) {
        int idx[6] = { 0, 1, 2, 1, 3, 2 };
        float2 uvs[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        RailPart k = parts[iid];
        int i = idx[vid];
        RailOut o;
        o.pos = i == 0 ? k.p0 : (i == 1 ? k.p1 : (i == 2 ? k.p2 : k.p3));
        o.uv = uvs[i];
        o.info = k.info;
        // The part's width on screen at this end (NDC x): a post's, for rime up its windward side.
        float4 l = i < 2 ? k.p0 : k.p2, r = i < 2 ? k.p1 : k.p3;
        o.across = length(r.xy / r.w - l.xy / l.w);
        return o;
    }

    /// Weathered wood, and the snow lying along the rails and on the posts' tops (catching the aurora's light).
    fragment ColorDepth fjord_rail_fragment(RailOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant FjordU& f [[buffer(1)]]) {
        float3 amb = f.ambient.rgb;
        float3 sunC = f.sunColor.rgb * f.sun.w, moonC = float3(0.55, 0.63, 0.82) * (0.35 * f.moon.w);
        float3 col;
        float a = 1.0;
        if (in.info.x < 0.5) {
            float grain = vnoise3(float3(in.uv.x * in.info.y * 6.0, in.uv.y * 3.0, in.info.z));
            float3 wood = mix(float3(0.07, 0.05, 0.04), float3(0.16, 0.11, 0.08), grain);
            col = wood * (amb * 0.8 + sunC * 0.45 + moonC * 0.8 + f.aurora.rgb * 0.5);
            if (in.info.y < 0.5) {   // a post: rime up its windward (left) side (spec §6.4), the feathers on the post
                float x = in.uv.x * in.across * (u.right.w / u.up.w);
                col = rimed(col, u, x, float2(-1.0, 0.0), float2(x, in.uv.y * 0.3));
            }
        } else {
            float lump = 0.5 + 0.42 * vnoise3(float3(in.uv.x * in.info.y * 2.5, in.info.z, 1.0));
            a = 1.0 - smoothstep(lump - 0.08, lump, in.uv.y);
            if (a < 0.01) discard_fragment();
            float shade = 0.75 + 0.25 * smoothstep(0.0, lump, in.uv.y);
            float3 lit = amb * 1.2 + sunC * max(f.sun.z, 0.0) + moonC * 1.4 * max(f.moon.z, 0.0) + f.aurora.rgb * 1.8;
            col = float3(0.9, 0.93, 1.0) * lit * shade;
        }
        ColorDepth o;
        o.color = float4(col * a, a);
        o.depth = float4(0.03, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- keys: ice-blue glass along the jetty's edge
    struct FjordKey { float4 rect; float4 info; };   // rect NDC; info: black, glow, pressed, light
    struct FjordKeyOut { float4 pos [[position]]; float2 uv; float4 info; };

    vertex FjordKeyOut fjord_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant FjordKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        FjordKey k = keys[iid];
        FjordKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }

    fragment ColorDepth fjord_keys_fragment(FjordKeyOut in [[stage_in]], constant FjordU& f [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.006, 0.012, 0.018) : float3(0.03, 0.055, 0.075);
        float y2 = in.uv.y * in.uv.y;
        float y6 = y2 * y2 * y2;
        float sheen = y6 * (black ? 0.06 : 0.14) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * (1.0 - smoothstep(0.94, 1.0, in.uv.x));
        float3 ice = float3(0.55, 0.85, 1.0);
        float3 c = base * (1.0 + 4.0 * light) + float3(0.75, 0.88, 1.0) * sheen * (0.35 + light) + f.aurora.rgb * (sheen * 6.0)
                 + ice * glow * (1.7 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
