/// Metal source for Supercell Sky (Storms spec §8): one full-screen pass draws the sky, the storm and the field; the
/// birds and the fence posts are instanced over it.
///
/// The storm is built from analytic shapes in kilometres around the camera (x across the view, y ahead, z up), each hit
/// in closed form (never marched): the rain-free base (a plane disc), the striated mesocyclone (a tapering solid of
/// revolution, its tiers lipped and undercut), the wall cloud (a rotating cylinder hanging under the base, rippled by
/// runs), the inflow bands (log-spiral streaks on a low plane, converging on the wall cloud), the hail shaft and the rain
/// core (translucent columns), the anvil overhead (a high plane with mammatus lobes under it), a funnel, the gust front's
/// dust wall. Their textures are the cloud layer's value noise in the storm's turning frame, so the whole storm visibly
/// rotates. The field is wheat in rows that lean with the wind field (one sample a row), a line of trees and a silo.
/// Strikes and anvil crawlers are polylines the renderer projects; the rainbow is the sky kit's bow; the rays converge on
/// the sun's antipoint. Smooth rules: no ray marching, at most 3 octaves (2 on Smooth; the mammatus 1), no pow.
enum SupercellSkyShaders {
    static let source = SkyShaders.common + """
    struct CellU {
        float4 a;        // aspect, time (s, wrapped), octaves, pixel angle (rad)
        float4 cam;      // shake (NDC xy), keys top (NDC), a pixel (NDC)
        float4 axes;     // the view's forward (ENU xy), its right (ENU xy)
        float4 place;    // storm centre (km: x across, y ahead), eye height (km), dolly (km)
        float4 spin;     // rotation (rad), spin (±1), inflow spacing (rad), inflow flow (km)
        float4 look;     // base darkness, green cast, hail, clearing
        float4 sunCol;   // sunlight on the storm (rgb, HDR), sun up 0…1
        float4 sunL;     // toward the sun (local xyz), sun altitude (deg)
        float4 amb;      // sky light (rgb), night 0…1
        float4 haze;     // haze colour (rgb), haze distance (km)
        float4 play;     // energy, tension, drop, storm rain
        float4 wall;     // wall cloud centre (km xy), radius (km), bottom (km)
        float4 shaft;    // hail shaft centre (km xy), radius (km), approach 0…1
        float4 gust;     // gust front's distance ahead (km; < 0 none), dust 0…1, dust height (km), outflow 0…1
        float4 after;    // rays, rainbow, stars, mammatus
        float4 funnel;   // reach 0…1, sway (rad), on, strike light on the cloud 0…1
        float4 glowL;    // storm light (crawlers, sheet) 0…1, far cell 0…1, base pulse 0…1, pulse spread 0…1
        float4 dims;     // base height, base radius, tower top, anvil height (km)
        float4 extra;    // grass rows, mammatus octaves, blade height (m), anvil reach behind the storm (km)
        float4 ripples[4];     // angle (rad, 0 facing the camera), light 0…1
        float4 glows[8];       // band, progress 0…1, light 0…1 (0: empty)
        float4 strikeInfo[2];  // light 0…1, segments, segments in cloud, glow only
        float4 strikeBox[2];   // NDC xmin, ymin, xmax, ymax
        float4 strikeAt[2];    // the branches' first segment, top (NDC xy), the foot's NDC y
        float4 segs[48];       // strike segments (NDC x0, y0, x1, y1), 24 a strike
        float4 crawlInfo[4];   // light 0…1, segments, unused
        float4 crawl[64];      // crawler segments (NDC), 16 a crawler
        float4 grass[48];      // rows: distance (m), lean across at the tip (m), height kept 0…1, sheen 0…1
    };
    struct CellOut { float4 pos [[position]]; float2 ndc; };

    vertex CellOut cell_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        CellOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- noise in 2D (four hashes a sample)
    float hash12(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
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
    float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(c * p.x - s * p.y, s * p.x + c * p.y);
    }
    float sq(float x) { return x * x; }

    // ---------------------------------------------------------------- light
    /// A cloud surface's light: the low sun (wrapped round the cloud's curve, and shadowed by the cloud's own billows
    /// toward it), the sky above, and the sunlit field's warm bounce below.
    float3 cloudLight(float3 N, float shadow, float occlusion, constant CellU& u) {
        float ndl = dot(N, u.sunL.xyz);
        float3 sun = u.sunCol.rgb * (saturate(0.6 * ndl + 0.4) * shadow);
        float3 sky = u.amb.rgb * ((0.55 + 0.45 * N.z) * occlusion);
        float3 bounce = float3(0.55, 0.38, 0.2) * u.sunCol.rgb * (0.14 * saturate(0.3 - 0.7 * N.z) * occlusion);
        return sun + sky + bounce;
    }

    /// The air between the camera and something `t` km away: a haze in the horizon's colour.
    float3 aerial(float3 c, float t, constant CellU& u) {
        float k = 1.0 - exp(-max(t, 0.0) / max(u.haze.w, 1.0));
        return mix(c, u.haze.rgb, k);
    }

    /// Lightning's light on the cloud near a point on screen: the strikes' and the crawlers', cool blue-white.
    float3 flashOnCloud(float2 ndc, constant CellU& u) {
        float3 light = float3(0);
        for (int k = 0; k < 2; k++) {
            float b = u.strikeInfo[k].x;
            if (b <= 0.0) continue;
            float d = length(ndc - u.strikeAt[k].yz);
            light += float3(0.62, 0.72, 1.0) * (b * (1.2 * exp(-d / 0.3) + 0.25 * exp(-d / 1.2)));
        }
        light += float3(0.62, 0.72, 1.0) * (0.3 * u.glowL.x);
        return light * u.funnel.w;
    }

    struct Layer { float a; float3 c; };

    float2 hash22(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    // ---------------------------------------------------------------- the mesocyclone
    /// Where a ray meets a vertical cylinder of radius `R` round `C` between heights `z0` and `z1` from outside: the hit
    /// distance (or 1e9) and in `inside` how far inside the radius the ray passes (km; negative: it misses by that much).
    float cylinderHit(float3 o, float3 d, float2 C, float R, float z0, float z1, thread float& inside) {
        float2 q = o.xy - C;
        float a = max(dot(d.xy, d.xy), 1e-6);
        float b = dot(q, d.xy);
        float tc = -b / a;
        float bb = max(dot(q, q) - b * b / a, 0.0);
        inside = R - sqrt(bb);
        if (tc <= 0.0) { inside = -1e3; return 1e9; }
        float t = inside > 0.0 ? tc - sqrt((R * R - bb) / a) : tc;
        float z = o.z + t * d.z;
        if (t <= 0.0 || z < z0 || z > z1) { inside = min(inside, -0.5 - 4.0 * max(z0 - z, z - z1)); return 1e9; }
        return t;
    }

    /// The same for a spheroid round (C, zc) with horizontal radius `R` and vertical semi-axis `H`, kept above zc.
    float domeHit(float3 o, float3 d, float2 C, float zc, float R, float H, thread float& inside) {
        float3 s = float3(1.0 / R, 1.0 / R, 1.0 / H);
        float3 oo = (o - float3(C, zc)) * s, dd = d * s;
        float a = dot(dd, dd), b = dot(oo, dd), c = dot(oo, oo) - 1.0;
        float disc = b * b - a * c;
        // How far inside: the depth of the ray's nearest pass, as a share of the radius.
        float tm = -b / a;
        float3 m = oo + dd * tm;
        inside = (1.0 - length(m)) * R;
        if (disc <= 0.0) return 1e9;
        float t = (-b - sqrt(disc)) / a;
        float z = o.z + t * d.z;
        if (t <= 0.0 || z < zc) { inside = min(inside, -0.5); return 1e9; }
        return t;
    }

    /// The updraft's axis at a height (km): it rises from the storm's centre and leans downshear (left, a little away)
    /// above the striated skirt.
    float2 axisAt(float z, constant CellU& u) {
        float up = max(z - u.dims.x - 2.2, 0.0);
        return u.place.xy + float2(-0.32, 0.12) * up;
    }

    /// The updraft's radius (km) at a height and a place round it (`ring`, a unit vector in the storm's turning frame):
    /// a broad striated skirt flaring over the base, the tower above it, both pushed out into big asymmetric lobes.
    float bellRadius(float z, float2 ring, constant CellU& u, thread float& lobes) {
        float hb = u.dims.x, Rb = u.dims.y, ha = u.dims.w;
        float s = saturate((z - hb) / (ha - hb));
        float bell = Rb * (1.0 - 0.58 * s * sqrt(s)) + Rb * 0.04 * (1.0 - smoothstep(0.0, 0.2, s));
        lobes = vnoise3(float3(ring * 1.5, z * 0.3 + 4.0)) * 0.6 + vnoise3(float3(ring * 3.1, z * 0.62 + 9.0)) * 0.4;
        return bell * (1.0 + (0.1 + 0.22 * smoothstep(0.15, 0.5, s)) * (lobes - 0.5));
    }

    /// A cloud's billows at a point (km, in the storm's turning frame): a domain-warped density, and how lit it is from
    /// `Lr` (the sun's direction in the same frame) by the density between it and the sun: billow tops toward the sun
    /// bright, the creases between them dark. `bands` (0…1) folds in the striations' ridges at `k`.
    float billows(float3 p, float3 Lr, float freq, float bands, float k, int octaves, thread float& density) {
        float3 q = p * freq;
        float3 w = float3(vnoise3(q * 0.45 + 11.0), vnoise3(q * 0.45 + 23.0), vnoise3(q * 0.45 + 37.0)) - 0.5;
        q += w * 1.4;
        float ridge = 0.5 + 0.5 * sin(6.2831853 * k);
        float ridgeL = 0.5 + 0.5 * sin(6.2831853 * (k + Lr.z * 0.3));
        float dn = mix(fbm3(q, octaves), ridge, 0.55 * bands);
        float dl = mix(fbm3(q + Lr * 0.5, octaves), ridgeL, 0.55 * bands);
        density = dn;
        return saturate(0.6 + 2.0 * (dn - dl));
    }

    /// The updraft: a striated skirt flaring over the base, winding round as it turns, and the tower of billows above it
    /// leaning downshear into the anvil. Analytic shape, volume-like light: its own density toward the low sun, warm where
    /// lit and cool in shadow, dark low down in the base's shade.
    Layer tower(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float hb = u.dims.x, Rb = u.dims.y, ht = u.dims.z, ha = u.dims.w;
        float a = max(dot(d.xy, d.xy), 1e-6);
        // The ray's nearest pass to the (leaning) axis: two steps of the axis at the pass's height.
        float2 C = u.place.xy;
        float tc = 0.0, bb = 0.0, zc = 0.0;
        for (int k = 0; k < 2; k++) {
            float2 q = o.xy - C;
            float b = dot(q, d.xy);
            tc = -b / a;
            bb = max(dot(q, q) - b * b / a, 0.0);
            zc = o.z + tc * d.z;
            C = axisAt(clamp(zc, hb, ha), u);
        }
        float bm = sqrt(bb);
        if (tc <= 0.0 || bm > Rb * 1.3) return L;
        float lobes;
        float2 pc = (o.xy + d.xy * tc - C);
        float2 ringC = rot2(pc / max(length(pc), 1e-3), -u.spin.x);
        float Rc = bellRadius(clamp(zc, hb, ha), ringC, u, lobes);
        float t = tc, z = zc;
        if (Rc > bm) {
            for (int k = 0; k < 4; k++) {
                float2 pk = o.xy + d.xy * t - C;
                float2 rk = rot2(pk / max(length(pk), 1e-3), -u.spin.x);
                float R = bellRadius(clamp(z, hb, ha), rk, u, lobes);
                if (R <= bm) break;
                t = tc - sqrt((R * R - bb) / a);
                z = o.z + t * d.z;
            }
        }
        if (t <= 0.0 || z > ha + 0.4) return L;
        float3 P = o + d * t;
        float2 Cz = axisAt(clamp(z, hb, ha), u);
        float2 rel = P.xy - Cz;
        float rr = max(length(rel), 0.1);
        float2 radial2 = rel / rr;
        float2 ring = rot2(radial2, -u.spin.x);
        float R0 = bellRadius(clamp(z, hb, ha), ring, u, lobes);
        float skirtW = 1.0 - smoothstep(2.2, 4.0, z - hb);
        float3 pt = float3(ring * R0, z);                         // the point in the turning frame
        float3 Ls = u.sunL.xyz;
        float3 Lr = float3(rot2(Ls.xy, -u.spin.x), Ls.z);
        // Striations on the skirt: helical (seamless: one band a turn), turning with the storm.
        float k = (z - hb) / 0.5 + atan2(ring.y, ring.x) * 0.15915494 + 1.3 * (lobes - 0.5);
        float dens;
        float light = billows(pt, Lr, 1.15, 0.95 * skirtW, k, octaves, dens);
        // The edge: frayed by the density where the cloud thins, the billows' cauliflower above.
        float rimT = 1.0 - smoothstep(0.4, 1.8, Rc - bm);
        float turrets = 2.0 * fbm3(pt * 0.7 + 41.0, octaves) - 1.0;
        float fray = (0.4 + 1.6 * (1.0 - skirtW)) * (dens - 0.5) + 0.9 * (1.0 - skirtW) * turrets;
        float edge = Rc - bm + rimT * fray;
        float soft = 0.15 + 0.01 * t;
        float cover = smoothstep(-soft, soft, edge) * smoothstep(hb - 0.2, hb - 0.05, z);
        if (cover <= 0.002) return L;
        // The shape's own slope and lobes turn it toward or away from the sun.
        float e = 0.08, lobesA, lobesU;
        float Ra = bellRadius(clamp(z, hb, ha), rot2(ring, e), u, lobesA);
        float Ru = bellRadius(clamp(z + 0.25, hb, ha), ring, u, lobesU);
        float3 r3 = float3(radial2, 0.0), tangent = float3(-radial2.y, radial2.x, 0.0);
        float3 N = normalize(r3 - tangent * ((Ra - R0) / (e * R0)) * 1.6 - float3(0, 0, 1) * ((Ru - R0) / 0.25) * 1.3);
        float facing = saturate(0.75 * dot(N, Ls) + 0.25);
        float sun = (0.12 + 0.88 * facing * facing) * (0.45 + 0.55 * light);
        // The striations: each band's bulging face lit, the groove under the next band in deep shadow.
        float f = fract(k + 0.35 * (dens - 0.5));
        float bandOn = smoothstep(0.3, 0.6, vnoise3(float3(ring * 2.2, floor(k) * 1.3 + 0.5)));   // some bands fade out
        float bandLit = smoothstep(0.0, 0.3, f) * (1.0 - smoothstep(0.55, 0.95, f));
        float bandShade = mix(1.0, 0.3 + 0.85 * bandLit, 0.8 * skirtW * bandOn);
        float3 warm = u.sunCol.rgb * sun * bandShade;
        float3 cool = u.amb.rgb * (0.28 + 0.3 * dens + 0.22 * N.z) * mix(1.0, 0.55 + 0.6 * bandLit, 0.7 * skirtW * bandOn)
                    + float3(0.55, 0.38, 0.2) * u.sunCol.rgb * 0.06;
        float3 c = warm * 0.85 + cool * (0.62 - 0.32 * facing);
        // Low down the cloud is in the base's own shade and the rain-cooled air: darker, greyer.
        float shade = 1.0 - smoothstep(0.0, 1.6, z - hb);
        c *= 1.0 - 0.6 * shade * (0.55 + 0.45 * u.look.x);
        c *= 1.0 - 0.2 * u.look.x * skirtW;
        // Its top goes up into the anvil: into the anvil's own shade.
        float3 anvilShade = u.amb.rgb * 0.26 + float3(0.04, 0.042, 0.055);
        c = mix(c, anvilShade, smoothstep(ha - 4.0, ha - 0.8, z));
        c += flashOnCloud(ndc, u) * (0.4 + 0.6 * dens);
        L.a = cover;
        L.c = aerial(c, t, u);
        tHit = t;
        return L;
    }

    /// The flanking line: cumulus towers stepping down to the right of the updraft, feeding it (spheroids standing on
    /// the base's level, billowed and lit as the tower is). Returns the nearest one's layer.
    Layer flankingLine(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float2 C = u.place.xy;
        float hb = u.dims.x, Rb = u.dims.y;
        float best = 1e9, bestInside = -1e3;
        float3 bestCentre = float3(0), bestRadii = float3(1);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float3 centre = float3(C + float2(Rb * (0.85 + 0.42 * fi), -Rb * (0.12 + 0.12 * fi)), hb);
            float3 radii = float3(Rb * (0.36 - 0.07 * fi), Rb * (0.36 - 0.07 * fi), 6.2 - 1.6 * fi);
            float3 oo = (o - centre) / radii, dd = d / radii;
            float a = dot(dd, dd), b = dot(oo, dd), c = dot(oo, oo) - 1.0;
            float tm = -b / a;
            float3 m = oo + dd * tm;
            float inside = (1.0 - length(m)) * radii.x;
            float disc = b * b - a * c;
            float t = disc > 0.0 ? (-b - sqrt(disc)) / a : tm;
            bool better = inside > 0.0 ? (bestInside <= 0.0 || t < best) : (bestInside <= 0.0 && inside > bestInside);
            if (inside > -1.5 && t > 0.0 && o.z + t * d.z > hb - 0.1 && better) {
                best = t; bestInside = inside; bestCentre = centre; bestRadii = radii;
            }
        }
        if (best > 1e8) return L;
        float3 P = o + d * best;
        float2 pr = rot2(P.xy - u.place.xy, -0.3 * u.spin.x);
        float3 pt = float3(pr, P.z);
        float3 Ls = u.sunL.xyz;
        float dens;
        float light = billows(pt + 13.0, Ls, 1.0, 0.0, 0.0, octaves, dens);
        // Cauliflower: big lumps on the sides, turrets on the tops.
        float lumps = 2.0 * fbm3(pt * 0.8 + 31.0, octaves) - 1.0;
        float upper = smoothstep(hb + 1.0, hb + 4.5, P.z);
        // Only near the silhouette: deep inside, the tower stays whole (no holes through it).
        float rim = 1.0 - smoothstep(0.4, 1.8, bestInside);
        float edge = bestInside + rim * ((0.45 + 0.75 * upper) * lumps + 1.2 * (dens - 0.5));
        float cover = smoothstep(-0.12, 0.12, edge) * smoothstep(hb - 0.1, hb + 0.05, P.z);
        if (cover <= 0.002) return L;
        float3 N = normalize((P - bestCentre) / (bestRadii * bestRadii));
        float facing = saturate(0.75 * dot(N, Ls) + 0.25);
        float sun = (0.12 + 0.88 * facing * facing) * (0.45 + 0.55 * light);
        float3 c = u.sunCol.rgb * sun * 0.85 + u.amb.rgb * (0.28 + 0.3 * dens + 0.22 * N.z) * (0.62 - 0.32 * facing);
        float shade = 1.0 - smoothstep(0.0, 1.4, P.z - hb);
        c *= 1.0 - 0.55 * shade;
        c += flashOnCloud(ndc, u) * 0.3;
        L.a = cover;
        L.c = aerial(c, best, u);
        tHit = best;
        return L;
    }

    // ---------------------------------------------------------------- the rain-free base
    Layer base(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float hb = u.dims.x, Rb = u.dims.y;
        if (d.z <= 1e-4) return L;
        float t = (hb - o.z) / d.z;
        float3 P = o + d * t;
        float2 C = u.place.xy;
        float2 rel = P.xy - C;
        float r = length(rel);
        if (r > Rb * 1.3) return L;
        float2 pr = rot2(rel, -u.spin.x);
        // Its edge is the updraft's own foot, lumpy as it is.
        float lobes;
        float2 ring = rot2(rel / max(r, 1e-3), -u.spin.x);
        // Ragged round its rim (lumps along the circumference, so seen edge-on they notch it rather than streak it).
        float rag = fbm2(float2(atan2(ring.y, ring.x) * 4.0, 21.0), octaves);
        float edge = 0.9 * bellRadius(hb, ring, u, lobes) - r + 1.6 * (rag - 0.5);
        float cover = smoothstep(-0.4, 0.4, edge);
        // Beyond the storm's middle, on the rain's side, the base is lost in the rain.
        float rainSide = 1.0 - smoothstep(u.wall.x - 3.0, u.wall.x + 1.0, P.x);
        cover *= 1.0 - 0.85 * rainSide * smoothstep(C.y - 2.0, C.y + 2.0, P.y);
        if (cover <= 0.002) return L;
        // Mottled, with a faint spiral turning with the storm, inward to the wall cloud.
        float2 sp = rot2(pr, 0.8 * u.spin.y * log(max(r, 0.4)));
        float swirl = 0.6 * fbm2(sp * float2(0.45, 1.1) + 3.1, octaves) + 0.4 * fbm2(pr * 1.3 + 8.0, octaves);
        float dark = u.look.x;
        float3 under = float3(0.045, 0.05, 0.06) * (0.7 + 0.6 * swirl);
        under += u.amb.rgb * (0.06 * (0.7 + 0.6 * swirl));
        under += float3(0.55, 0.36, 0.18) * u.sunCol.rgb * 0.045;          // the field's warm bounce
        under *= 1.15 - 0.7 * dark;
        // Green under the core, over the hail shaft.
        float core = exp(-length(P.xy - u.shaft.xy) / 5.0);
        float l = dot(under, float3(0.2126, 0.7152, 0.0722));
        under = mix(under, l * float3(0.72, 1.2, 1.0), saturate(u.look.y * 8.0 * core));
        // A chord's pulse: a ring of light spreading out over the base from the wall cloud.
        if (u.glowL.z > 0.0) {
            float dw = length(P.xy - u.wall.xy) - u.wall.z;
            float ringR = u.glowL.w * (Rb * 0.8);
            float ringD = (dw - ringR) / (0.9 + 1.5 * u.glowL.w);
            under += float3(1.0, 0.86, 0.66) * (u.glowL.z * (0.7 * exp(-ringD * ringD) + 0.4 * exp(-max(dw, 0.0) / 1.2)));
        }
        under += flashOnCloud(ndc, u) * 0.5;
        L.a = cover;
        L.c = aerial(under, t * 0.6, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the wall cloud
    /// The wall cloud: an abrupt lowering hanging under the base, narrowing to a ragged bottom of scud, streaked
    /// vertically as it turns; its top is the base itself.
    Layer wallCloud(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float2 W = u.wall.xy;
        float Rw = u.wall.z, bottom = u.wall.w, hb = u.dims.x;
        float2 q = o.xy - W;
        float a = max(dot(d.xy, d.xy), 1e-6);
        float b = dot(q, d.xy);
        float tc = -b / a;
        float bb = max(dot(q, q) - b * b / a, 0.0);
        float bm = sqrt(bb);
        if (tc <= 0.0 || bm > Rw * 1.5) return L;
        float zc = o.z + tc * d.z;
        float t = tc, z = zc;
        for (int k = 0; k < 3; k++) {
            float R = Rw * (0.55 + 0.45 * saturate((z - bottom) / (hb - bottom)));
            if (R <= bm) break;
            t = tc - sqrt((R * R - bb) / a);
            z = o.z + t * d.z;
        }
        if (t <= 0.0) return L;
        float3 P = o + d * t;
        float2 rel = P.xy - W;
        float rr = max(length(rel), 0.05);
        float2 ring = rot2(rel / rr, -u.spin.x);
        float ang = atan2(rel.x, -rel.y);                         // 0 faces the camera
        // Ripples: a bulge of brighter cloud running round it.
        float bulge = 0.0;
        for (int i = 0; i < 4; i++) {
            float lr = u.ripples[i].y;
            if (lr <= 0.0) continue;
            float da = ang - u.ripples[i].x;
            da -= 6.2831853 * floor((da + 3.14159265) / 6.2831853);
            bulge += lr * exp(-da * da / 0.2);
        }
        float hzc = saturate((zc - bottom) / (hb - bottom));
        float3 Ls = u.sunL.xyz;
        float3 Lr = float3(rot2(Ls.xy, -u.spin.x), Ls.z);
        float3 pt = float3(ring * Rw * 1.4, z * 1.4);
        float dens;
        float light = billows(pt, Lr, 2.0, 0.0, 0.0, octaves, dens);
        float R = Rw * (0.55 + 0.45 * hzc) * (1.0 + 0.16 * bulge) + 0.7 * (dens - 0.5);
        // A ragged bottom: scud tags hanging below it.
        float bottomZ = bottom + 0.28 * (fbm2(ring * 3.0 + float2(z, 7.0), octaves) - 0.45) + 0.15 * (dens - 0.5);
        float side = smoothstep(0.12, -0.12, bm - R);
        float low = smoothstep(bottomZ - 0.05, bottomZ + 0.12, zc);
        float cover = side * low * (1.0 - smoothstep(hb + 0.02, hb + 0.12, zc));
        if (cover <= 0.002) return L;
        float hz = saturate((z - bottom) / (hb - bottom));
        float3 N = normalize(float3(rel / rr, 0.35));
        float facing = saturate(0.6 * dot(N, Ls) + 0.4);
        float3 c = u.sunCol.rgb * (0.22 * facing * light) + u.amb.rgb * (0.08 + 0.1 * dens) + float3(0.025, 0.028, 0.034);
        // Darker into its top, where it is the base; lighter low down in the horizon's light.
        c *= 0.75 + 0.45 * (1.0 - hz);
        c *= 1.2 - 0.6 * u.look.x;
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, l * float3(0.8, 1.12, 1.0), saturate(u.look.y * 4.0));
        // A chord's pulse lights it from inside, low down; a ripple brightens where it passes.
        float lowPart = 1.0 - hz;
        c += float3(1.0, 0.86, 0.66) * (u.glowL.z * 1.4 * lowPart * lowPart);
        c += float3(0.95, 0.9, 0.8) * u.sunCol.rgb * (0.25 * bulge);
        c += flashOnCloud(ndc, u) * 0.6;
        L.a = cover;
        L.c = aerial(c, t * 0.6, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the funnel
    Layer funnelCloud(float3 o, float3 d, constant CellU& u, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        if (u.funnel.z < 0.5 || u.funnel.x <= 0.0) return L;
        float top = u.wall.w + 0.05, tip = top * (1.0 - u.funnel.x);
        float2 A = u.wall.xy + float2(0.35 * u.wall.z, -0.2 * u.wall.z);
        float2 q = o.xy - A;
        float a = max(dot(d.xy, d.xy), 1e-6);
        float b = dot(q, d.xy);
        float tc = -b / a;
        if (tc <= 0.0) return L;
        float z = o.z + tc * d.z;
        if (z > top || z < tip - 0.02) return L;
        float k = saturate((top - z) / max(top - tip, 1e-3));      // 0 at the cloud … 1 at the tip
        float sway = 0.12 * k * k * sin(u.funnel.y);
        float2 axis = A + float2(sway, 0.0);
        float2 p = (o.xy + d.xy * tc) - axis;
        float r = length(p);
        float R = mix(0.2, 0.012, sqrt(k));
        float cover = smoothstep(R, R * 0.55, r) * smoothstep(tip - 0.02, tip + 0.03, z);
        if (cover <= 0.002) return L;
        float twist = vn2(float2(z * 9.0 + u.spin.x * 6.0, p.x * 30.0));
        float3 c = (u.amb.rgb * 0.6 + u.sunCol.rgb * 0.12) * (0.5 + 0.35 * twist);
        L.a = cover * 0.9;
        L.c = aerial(c, tc * 0.6, u);
        tHit = tc;
        return L;
    }

    // ---------------------------------------------------------------- the inflow bands
    /// Low laminar bands of cloud streaming in toward the wall cloud from the right and over the camera, converging on it
    /// in perspective; each a log spiral round it, its cloud carried inward along it.
    Layer inflow(float3 o, float3 d, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        const float h = 0.75;
        if (d.z <= 1e-4) return L;
        float t = (h - o.z) / d.z;
        float3 P = o + d * t;
        float2 W = u.wall.xy;
        float2 rel = P.xy - W;
        float r = length(rel);
        float rMax = 15.0;
        if (r < u.wall.z * 0.8 || r > rMax) return L;
        float centre = atan2(-0.35 * W.y, 14.0 - W.x);
        float twist = -0.3 * u.spin.y * log(r / u.wall.z);
        float phi = atan2(rel.y, rel.x) - twist;
        float spacing = u.spin.z;
        float bandsF = (phi - centre) / spacing + 3.0;            // band k at bandsF == k
        float k = floor(bandsF + 0.5);
        if (k < -0.5 || k > 6.5) return L;
        float across = (bandsF - k) * spacing * r;                // km off the band's line
        float width = 0.25 + 0.06 * r;
        float profile = exp(-across * across / (width * width));
        float flow = u.spin.w;
        float streak = fbm2(float2((r + flow) * 0.9, across * 6.0 + k * 3.7), octaves);
        float ends = smoothstep(u.wall.z * 0.9, u.wall.z * 2.0, r) * (1.0 - smoothstep(rMax * 0.55, rMax, r));
        float dens = profile * ends * smoothstep(0.25, 0.65, streak) * (0.75 + 0.25 * u.play.x);
        // A note's glow running up this band into the wall cloud.
        float glow = 0.0;
        for (int i = 0; i < 8; i++) {
            float4 g = u.glows[i];
            if (g.z <= 0.0 || abs(g.x - k) > 0.5) continue;
            float rg = mix(rMax * 0.7, u.wall.z, g.y);
            float x = (r - rg) / 1.0;
            glow += g.z * exp(-x * x);
        }
        glow *= profile * ends;
        float a = saturate(dens + 0.3 * glow);
        if (a <= 0.002) return L;
        float3 c = (u.amb.rgb * 0.32 + float3(0.04, 0.04, 0.05)) * (0.8 + 0.4 * streak)
                 + u.sunCol.rgb * float3(1.0, 0.86, 0.7) * ((0.22 + 0.2 * streak) * u.sunCol.w);
        c *= 1.15 - 0.5 * u.look.x;
        c += float3(1.0, 0.78, 0.42) * (2.6 * glow) / max(a, 0.05);
        L.a = a;
        L.c = aerial(c, t * 0.6, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the hail shaft and the rain core
    /// A translucent curtain of rain or hail falling from the base on axis `S` (radius `R`), slanting as it falls,
    /// feathered at its sides and streaked as it falls; `lit` is its light.
    Layer column(float3 o, float3 d, float2 S, float R, float density, float3 lit, float streaks, constant CellU& u,
                 thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float hb = u.dims.x;
        float a = max(dot(d.xy, d.xy), 1e-6);
        float2 A = S;
        float tc = 0.0, bb = 0.0, zc = 0.0;
        for (int k = 0; k < 2; k++) {
            float2 q = o.xy - A;
            float b = dot(q, d.xy);
            tc = -b / a;
            bb = max(dot(q, q) - b * b / a, 0.0);
            zc = o.z + tc * d.z;
            A = S + float2(0.55 * R * (1.0 - saturate(zc / hb)), 0.0);   // the foot blown downwind
        }
        if (tc <= 0.0 || zc > hb + 0.1 || zc < -0.3 || bb >= R * R * 1.2) return L;
        float z = clamp(zc, 0.0, hb);
        float2 p = o.xy + d.xy * tc - A;
        float fall = u.a.y * 0.3;
        float across = p.x / R;                                    // −1 … 1 across the curtain as seen
        float wobble = 0.25 * (fbm2(float2(z * 0.8 + 1.7, fall * 0.2), 2) - 0.5);
        float x = across + wobble;
        float profile = saturate(1.0 - x * x);
        profile *= profile;
        float st = fbm2(float2(across * 16.0 + 3.0, z * 0.45 + fall), 2);
        float st2 = mix(1.0, 0.3 + 1.4 * st, streaks);
        float top = 1.0 - smoothstep(hb - 0.2, hb + 0.05, zc);
        float alpha = (1.0 - exp(-density * 2.0 * R * profile * st2)) * top;
        if (alpha <= 0.002) return L;
        // Lit a little more on the side toward the sun.
        float side = 0.85 + 0.3 * saturate(0.5 + 0.5 * x * sign(u.sunL.x));
        L.a = alpha;
        L.c = aerial(lit * side, tc, u);
        tHit = tc;
        return L;
    }

    /// The forward flank's rain: a curtain hanging from the base behind the storm's centre, from far left to just short
    /// of the wall cloud, where the inflow notch stays open to the bright horizon.
    Layer rainCurtain(float3 o, float3 d, float2 ndc, float3 lit, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float hb = u.dims.x;
        float y0 = u.place.y - 1.0;
        if (d.y <= 1e-4) return L;
        float t = (y0 - o.y) / d.y;
        if (t <= 0.0) return L;
        float3 P = o + d * t;
        if (P.z > hb + 0.05) return L;
        float z = max(P.z, 0.0);
        float fall = u.a.y * 0.2;
        float right = u.wall.x - u.wall.z * 0.6 + 2.5 * (fbm2(float2(z * 0.9 + fall * 0.3, 3.3), 2) - 0.5);
        float x = P.x - right;
        float st = fbm2(float2(P.x * 1.4, z * 0.35 + fall), octaves);
        float dens = (1.0 - smoothstep(-2.5, 1.0, x)) * (0.55 + 0.45 * st) * (0.35 + 0.65 * u.play.w);
        float top = 1.0 - smoothstep(hb - 0.1, hb + 0.05, P.z);
        float a = saturate(dens * 1.3) * 0.95 * top;
        if (a <= 0.002) return L;
        float low = 1.0 - smoothstep(0.0, hb * 0.8, z);                // the rain's foot, lit by the horizon behind it
        L.a = a;
        L.c = aerial(lit * (0.75 + 0.35 * st) + u.haze.rgb * (0.35 * low), t * 0.7, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the anvil overhead
    Layer anvil(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float ha = u.dims.w;
        if (d.z <= 1e-4) return L;
        float t = (ha - o.z) / d.z;
        float3 P = o + d * t;
        float2 C = u.place.xy;
        // Its underside sags toward the updraft it spreads from (one step of the sag at the flat plane's hit).
        float2 top = axisAt(ha, u);
        float sag = 2.4 * exp(-length(P.xy - top) / (u.dims.y * 0.7));
        t = (ha - sag - o.z) / d.z;
        P = o + d * t;
        // It spreads from the storm toward and past the camera; its far edge stands behind the storm.
        float reach = C.y + u.extra.w + 6.0 * (fbm2(float2(P.x * 0.09, 1.3), 2) - 0.5);
        float fringe = fbm2(P.xy * 0.35 + 4.0, octaves);
        float edge = reach - P.y + 12.0 * (fringe - 0.5);
        float cover = smoothstep(-0.5, 2.0, edge) * (1.0 - smoothstep(55.0, 70.0, abs(P.x - C.x)));
        if (cover <= 0.002) return L;
        int mo = int(u.extra.y + 0.5);
        // Mammatus: pouches hanging under it (the nearest of a jittered grid of centres), lit on the side facing the low
        // sun, shadowed in the creases between.
        float2 g = P.xy / 1.45;
        g += (float2(fbm2(g * 0.3, mo), fbm2(g * 0.3 + 5.2, mo)) - 0.5) * 1.6;
        float2 gi = floor(g), gf = fract(g);
        float best = 9.0;
        float2 toward = float2(0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 cell = float2(float(x), float(y));
                float2 c = cell + 0.15 + 0.7 * hash22(gi + cell);
                float2 v = gf - c;
                float d2 = dot(v, v);
                if (d2 < best) { best = d2; toward = v; }
            }
        }
        float patch = smoothstep(0.35, 0.75, fbm2(P.xy * 0.06 + 2.0, 2));
        float mam = u.after.w * patch * smoothstep(-4.0, 4.0, edge) * (1.0 - smoothstep(30.0, 50.0, edge));
        float dome = exp(-best * 3.2);
        float3 N = normalize(float3(toward * (1.6 * mam * dome), -1.0));
        float lowSun = 1.0 - smoothstep(-1.0, 10.0, u.sunL.w);
        float ndl = saturate(dot(N, u.sunL.xyz) * 2.0 + 0.15);
        float tex = fbm2(P.xy * 0.15 + 9.0, octaves);
        float3 underside = (u.amb.rgb * 0.24 + float3(0.035, 0.038, 0.05)) * (0.75 + 0.5 * tex) * (1.15 - 0.4 * u.look.x);
        float3 sunlit = u.sunCol.rgb * float3(1.0, 0.72, 0.55) * ((0.05 + 0.3 * lowSun) * ndl * mam);
        float crease = 1.0 - 0.22 * mam * (1.0 - dome);
        float thin = 1.0 - smoothstep(0.0, 22.0, edge);              // thinner, lighter toward its far edge
        float3 c = (underside * (0.85 + 0.3 * dome * mam) * (0.8 + 0.9 * thin) + sunlit) * crease;
        // The far edge, where the low sun catches it from below.
        c += u.sunCol.rgb * float3(1.0, 0.7, 0.55) * (0.22 * (1.0 - smoothstep(0.0, 8.0, edge)) * (0.5 + fringe));
        c += flashOnCloud(ndc, u) * (0.5 + 0.5 * dome);
        L.a = cover;
        L.c = aerial(c, t * 0.35, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the field
    /// The wheat: rows of blades at the renderer's distances, each row leaning with the wind field's sample there.
    /// Returns the blade cover (0 where the ground shows) and its colour.
    float4 wheat(float3 o, float3 d, constant CellU& u) {
        int rows = int(u.extra.x + 0.5);
        float eye = u.place.z * 1000.0, H = u.extra.z;
        float down = -d.z / max(length(d.xy), 1e-4);             // tan of the depression
        if (down <= 0.0) return float4(0);
        float nearD = (eye - H * 1.05) / down, farD = eye / down;
        float pix = u.a.w;
        for (int i = 0; i < 48; i++) {
            if (i >= rows) break;
            float4 row = u.grass[i];
            float D = row.x;
            if (D < nearD * 0.98 || D > farD * 1.02) continue;
            // Where the ray crosses this row: across (m) and up (m).
            float along = D / max(d.y, 1e-4);
            float X = o.x * 1000.0 + d.x * along;
            float Z = eye + d.z * along;
            float Hk = H * row.z;
            if (Z < 0.0 || Z > Hk * 1.02) continue;
            float v = Z / max(Hk, 1e-3);                          // 0 at the root … 1 at the tip
            float lean = row.y * v * v;
            float spacing = 0.07;
            float footprint = pix * along / spacing;              // blades a pixel
            float x = (X - lean) / spacing + float(i) * 0.37;
            float cell = floor(x);
            float cover = 0.0, shade = 1.0;
            for (int j = -1; j <= 1; j++) {
                float c = cell + float(j);
                float h = hash12(float2(c, float(i)));
                float centre = c + 0.5 + 0.6 * (h - 0.5);
                float tall = 0.75 + 0.25 * fract(h * 7.3);
                if (v > tall) continue;
                float w = (0.11 + 0.06 * fract(h * 3.1)) * (1.0 - 0.7 * v / tall) + 0.04 * smoothstep(0.75, 0.9, v / tall);
                float dx = abs(x - centre);
                float px = max(footprint, 1e-3);
                float k = saturate((w - dx) / px + 0.5);
                if (k > cover) { cover = k; shade = 0.8 + 0.35 * fract(h * 13.7); }
            }
            // Far off the blades are finer than a pixel: their average cover, so the field never sparkles.
            float avg = 0.85 * (1.0 - 0.6 * v);
            cover = mix(cover, avg, smoothstep(0.25, 1.2, footprint));
            if (cover > 0.02) {
                float3 straw = float3(0.78, 0.6, 0.3) * shade;
                float3 lit = u.sunCol.rgb * 0.62 * (0.55 + 0.45 * v) + u.amb.rgb * (0.55 + 0.3 * v);
                float3 c = straw * lit * (0.55 + 0.45 * v);
                c += u.sunCol.rgb * float3(1.0, 0.9, 0.7) * (0.35 * row.w * v);   // the sheen of flattened wheat
                c += flashOnCloud(float2(0.0, 0.3), u) * 0.08;
                return float4(aerial(c, along * 0.001, u), cover);
            }
        }
        return float4(0);
    }

    /// The ground: stubble between the rows, the far field, a line of trees and a silo low on the horizon on the left.
    float3 field(float3 o, float3 d, float2 ndc, constant CellU& u, int octaves) {
        float t = -o.z / min(d.z, -1e-5);
        float3 P = o + d * t;
        float ground = t;
        float2 m = P.xy * 1000.0;                                // metres
        float patches = fbm2(m * 0.012 + 3.0, octaves);
        float3 straw = mix(float3(0.42, 0.31, 0.15), float3(0.62, 0.48, 0.24), patches);
        float3 c = straw * (u.sunCol.rgb * 0.5 + u.amb.rgb * 0.7);
        // The storm's shadow and rain: darker under its base, greener near the hail.
        float2 C = u.place.xy;
        float under = 1.0 - smoothstep(u.dims.y * 0.6, u.dims.y * 1.1, length(P.xy - C));
        c *= 1.0 - 0.55 * under * u.look.x;
        float rain = exp(-length(P.xy - u.shaft.xy) / (u.shaft.z * 1.2));
        c = mix(c, float3(0.06, 0.08, 0.08) * (u.amb.rgb * 2.0 + 0.05), saturate(rain * (0.4 + u.look.z)));
        c += flashOnCloud(ndc, u) * 0.06;
        return aerial(c, ground, u);
    }

    /// A line of trees (a windbreak 2–3 km off) and a grain silo, left of the storm; 0 alpha where there are none.
    float4 horizonThings(float3 d, constant CellU& u) {
        float az = atan2(d.x, d.y);                                // radians from the view's middle, right positive
        float el = atan2(d.z, length(d.xy));
        float3 lightFace = u.sunCol.rgb * 0.45 + u.amb.rgb * 0.5;
        // Trees: crowns along the left of the view.
        float ta = (az + 0.95) / 0.55;
        if (ta > -1.0 && ta < 1.0 && el < 0.02 && el > -0.004) {
            float crowns = 0.0045 + 0.0035 * vn2(float2(az * 140.0, 0.5)) + 0.002 * vn2(float2(az * 420.0, 3.1));
            crowns *= smoothstep(1.0, 0.7, abs(ta));
            float h = crowns - 0.0002;
            if (el < h) {
                float3 c = float3(0.09, 0.1, 0.06) * lightFace * 1.4 + float3(0.02, 0.025, 0.02);
                return float4(aerial(c, 2.4, u), smoothstep(h, h - 0.0006, el));
            }
        }
        // The silo: a corrugated steel cylinder with a cone roof, catching the low sun.
        float sa = az + 0.62;
        if (abs(sa) < 0.012 && el < 0.03 && el > -0.002) {
            float w = 0.0085;
            float body = 0.019, roof = 0.026;
            float x = abs(sa) / w;
            float coneH = body + (roof - body) * saturate(1.0 - x);
            if (x < 1.0 && el < coneH) {
                float curve = sqrt(saturate(1.0 - x * x));
                float rib = 0.85 + 0.15 * sin(el * 2600.0);
                float3 steel = float3(0.62, 0.62, 0.6) * (u.sunCol.rgb * (0.35 + 0.65 * curve) + u.amb.rgb * 0.6) * rib;
                if (el > body) steel *= 1.15;
                return float4(aerial(steel, 1.0, u), smoothstep(1.0, 0.9, x));
            }
        }
        return float4(0);
    }

    // ---------------------------------------------------------------- the gust front's dust
    Layer dustWall(float3 o, float3 d, constant CellU& u, int octaves, thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float front = u.gust.x, dust = u.gust.y;
        if (front < 0.0 || dust <= 0.001 || d.y <= 1e-4) return L;
        float t = (front - o.y) / d.y;
        if (t <= 0.0) return L;
        float3 P = o + d * t;
        float H = u.gust.z * (0.6 + 0.8 * fbm2(float2(P.x * 6.0 - u.a.y * 0.4, 0.7), octaves));
        if (P.z > H || P.z < -0.01) return L;
        float v = saturate(P.z / max(H, 1e-4));
        float billow = fbm2(float2(P.x * 14.0, P.z * 20.0 - u.a.y * 1.5), octaves);
        float a = dust * (1.0 - v * v) * (0.55 + 0.45 * billow);
        float3 c = float3(0.55, 0.42, 0.3) * (u.sunCol.rgb * 0.55 + u.amb.rgb * 0.8) * (0.8 + 0.3 * billow);
        L.a = saturate(a);
        L.c = c;
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- lightning on screen
    float segmentDistance(float2 p, float4 s, float aspect) {
        float2 a = float2(s.x * aspect, s.y), b = float2(s.z * aspect, s.w);
        float2 ab = b - a;
        float h = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-8));
        return length(p - a - ab * h);
    }

    float3 strikes(float2 ndc, constant CellU& u) {
        float aspect = u.a.x;
        float2 p = float2(ndc.x * aspect, ndc.y);
        float px = u.cam.w;
        float3 sum = float3(0);
        for (int k = 0; k < 2; k++) {
            float4 info = u.strikeInfo[k];
            if (info.x <= 0.0 || info.w > 0.5) continue;
            float4 box = u.strikeBox[k];
            if (ndc.x < box.x - 0.15 || ndc.x > box.z + 0.15 || ndc.y < box.y - 0.15 || ndc.y > box.w + 0.15) continue;
            int count = int(info.y + 0.5), inCloud = int(info.z + 0.5), branches = int(u.strikeAt[k].x + 0.5);
            float core = 0.0, halo = 1e3;
            for (int i = 0; i < 24; i++) {
                if (i >= count) break;
                float dist = segmentDistance(p, u.segs[k * 24 + i], aspect);
                float w = (i >= branches ? 0.6 : 1.0) * px * 1.3;
                float x = dist / w;
                float bright = i < inCloud ? 0.12 : (i >= branches ? 0.45 : 1.0);
                core = max(core, bright * exp(-x * x));
                halo = min(halo, dist);
            }
            sum += float3(0.78, 0.86, 1.0) * (info.x * (26.0 * core + 1.6 * exp(-halo / 0.03)));
        }
        return sum;
    }

    float3 crawlers(float2 ndc, constant CellU& u, float onCloud) {
        float aspect = u.a.x;
        float2 p = float2(ndc.x * aspect, ndc.y);
        float px = u.cam.w;
        float3 sum = float3(0);
        for (int k = 0; k < 4; k++) {
            float4 info = u.crawlInfo[k];
            if (info.x <= 0.0) continue;
            int count = int(info.y + 0.5);
            float core = 0.0, halo = 1e3;
            for (int i = 0; i < 16; i++) {
                if (i >= count) break;
                float dist = segmentDistance(p, u.crawl[k * 16 + i], aspect);
                float x = dist / (px * 1.6);
                core = max(core, exp(-x * x));
                halo = min(halo, dist);
            }
            sum += float3(0.75, 0.82, 1.0) * (info.x * (5.0 * core + 1.2 * exp(-halo / 0.05)));
        }
        return sum * onCloud;
    }

    // ---------------------------------------------------------------- the scene
    fragment ColorDepth cell_scene_fragment(CellOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                            constant CellU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc - u.cam.xy;
        int octaves = int(u.a.z + 0.5);
        float3 dE = normalize(sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w));
        float3 d = float3(dot(dE, float3(u.axes.zw, 0.0)), dot(dE, float3(u.axes.xy, 0.0)), dE.z);
        float3 o = float3(0.0, -u.place.w, u.place.z);

        float3 col = float3(0);
        float T = 1.0;
        float cloudy = 0.0;      // how much storm cloud covers the pixel (crawlers live on it)
        float anvilCover = 0.0;

        // Every layer the ray meets, then composited nearest first (an insertion sort of at most ten).
        float2 S = u.shaft.xy;
        float rainLit = u.sunCol.w;
        float3 hailLit = (u.sunCol.rgb * float3(1.0, 0.95, 0.88) * 1.05 + u.amb.rgb * 0.9) * (0.75 + 0.25 * rainLit);
        hailLit += flashOnCloud(ndc, u) * 0.8;
        float3 coreLit = (u.amb.rgb * 0.3 + u.sunCol.rgb * 0.05) * float3(0.86, 1.0, 0.94);
        float lum = dot(coreLit, float3(0.2126, 0.7152, 0.0722));
        coreLit = mix(coreLit, lum * float3(0.75, 1.15, 0.95), saturate(u.look.y * 6.0));
        coreLit += flashOnCloud(ndc, u) * 0.5;
        float groundT = dE.z < 0.0 ? -o.z / min(d.z, -1e-6) : 1e9;
        Layer layers[10];
        float depths[10];
        int count = 0;
        float lt;
        Layer ly;
        for (int i = 0; i < 10; i++) {
            switch (i) {
                case 0: ly = dustWall(o, d, u, octaves, lt); break;
                case 1: ly = funnelCloud(o, d, u, lt); break;
                case 2: ly = inflow(o, d, u, octaves, lt); break;
                case 3: ly = wallCloud(o, d, ndc, u, octaves, lt); break;
                case 4: ly = column(o, d, S, u.shaft.z, 0.04 + 0.26 * u.look.z, hailLit, 1.0, u, lt); break;
                case 5: ly = rainCurtain(o, d, ndc, coreLit, u, octaves, lt); break;
                case 6: ly = base(o, d, ndc, u, octaves, lt); break;
                case 7: ly = tower(o, d, ndc, u, octaves, lt); break;
                case 8: ly = flankingLine(o, d, ndc, u, octaves, lt); break;
                default: ly = anvil(o, d, ndc, u, octaves, lt); anvilCover = ly.a; break;
            }
            if (ly.a <= 0.0 || lt >= groundT) continue;
            if (i >= 3) cloudy = max(cloudy, i == 4 || i == 5 ? 0.0 : ly.a);
            int j = count;
            while (j > 0 && depths[j - 1] > lt) { layers[j] = layers[j - 1]; depths[j] = depths[j - 1]; j--; }
            layers[j] = ly;
            depths[j] = lt;
            count++;
        }
        for (int i = 0; i < 10; i++) {
            if (i >= count || T < 0.004) break;
            col += T * layers[i].a * layers[i].c;
            T *= 1.0 - layers[i].a;
        }
        float3 back;
        float depth = 1.0;
        if (dE.z >= 0.0) {
            float moonMask = 0.0;
            back = skyRadiance(dE, sky, moonMask, stars);
            // The far sky seen beneath the storm lies in its shade and its rain: dimmer, greyer.
            float2 q = o.xy - u.place.xy;
            float aa = max(dot(d.xy, d.xy), 1e-6);
            float bq = dot(q, d.xy);
            float miss = sqrt(max(dot(q, q) - bq * bq / aa, 0.0));
            float under = (1.0 - smoothstep(u.dims.y * 0.7, u.dims.y * 1.6, miss)) * (1.0 - smoothstep(0.0, 0.12, dE.z));
            float bl = dot(back, float3(0.2126, 0.7152, 0.0722));
            back = mix(back, bl * float3(0.62, 0.7, 0.8), 0.6 * under) * (1.0 - 0.45 * under);
            // The far cell on the horizon to the left, lit from inside (a surprise).
            if (u.glowL.y > 0.0) {
                float az = atan2(d.x, d.y), el = atan2(d.z, length(d.xy));
                float x = (az + 0.75) / 0.12, y = el / 0.05;
                back += float3(0.85, 0.82, 1.0) * (0.35 * u.glowL.y * exp(-x * x - y * y));
            }
        } else {
            back = field(o, d, ndc, u, octaves);
            float4 w = wheat(o, d, u);
            back = mix(back, w.rgb, w.a);
            depth = 0.6;
        }
        if (dE.z > -0.01) {
            float4 h = horizonThings(d, u);
            back = mix(back, h.rgb, h.a);
        }
        col += T * back;

        // The light after the storm: rays converging on the sun's antipoint through the clear air, and the double rainbow
        // standing in the rain.
        float3 anti = -sky.sun.xyz;
        if (u.after.x > 0.0 && dE.z > -0.02) {
            float3 e1 = normalize(cross(anti, float3(0, 0, 1)) + float3(1e-4, 0, 0));
            float3 e2 = cross(e1, anti);
            float psi = atan2(dot(dE, e2), dot(dE, e1));
            float beams = smoothstep(0.35, 0.8, vn2(float2(psi * 16.0, u.a.y * 0.01)));
            float fromAnti = acos(clamp(dot(dE, anti), -1.0, 1.0));
            float air = (1.0 - 0.75 * cloudy) * smoothstep(0.05, 0.4, fromAnti);
            col += u.sunCol.rgb * float3(1.0, 0.8, 0.6) * (0.07 * u.after.x * beams * air);
            col *= 1.0 - 0.12 * u.after.x * (1.0 - beams) * air;
        }
        if (u.after.y > 0.0 && dE.z > 0.0) {
            float angle = toDeg(acos(clamp(dot(dE, anti), -1.0, 1.0)));
            float3 bow = rainbowBow(angle);
            float darkBand = angle > 42.5 && angle < 50.5 ? 0.88 : 1.0;
            float strength = u.after.y * (1.0 - 0.75 * anvilCover);
            col = col * mix(1.0, darkBand, strength) + bow * (0.55 * strength) * (0.6 + u.sunCol.rgb * 0.3);
        }
        // Lightning: the strikes (blue-white, through the limiter) and the crawlers on the cloud.
        col += strikes(ndc, u);
        col += crawlers(ndc, u, max(cloudy, 0.3));
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the birds
    struct BirdInstance { float4 at; float4 info; };   // centre (NDC xy), size (NDC y), heading on screen; flap, light, 0, 0
    struct BirdOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex BirdOut cell_bird_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BirdInstance* birds [[buffer(0)]],
                                    constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        BirdInstance b = birds[iid];
        BirdOut o;
        o.uv = c[vid];
        float2 off = c[vid] * b.at.z;
        o.pos = float4(b.at.xy + float2(off.x / view.x, off.y) + view.yz, 0, 1);
        o.info = float4(b.info.x, b.info.y, b.at.w, 0);
        return o;
    }
    fragment float4 cell_bird_fragment(BirdOut in [[stage_in]]) {
        // A bird seen side-on: two wings in a shallow V that beat.
        float flap = sin(in.info.x);
        float2 p = in.uv;
        float x = abs(p.x);
        float wing = 0.3 * flap * x + 0.12 * x * x;
        float dy = p.y - wing;
        float thick = 0.16 * (1.0 - 0.75 * x);
        float a = smoothstep(thick, thick * 0.4, abs(dy)) * smoothstep(1.0, 0.85, x);
        a = max(a, smoothstep(0.24, 0.12, length(p * float2(1.0, 1.4))));
        float3 c = float3(in.info.y);
        return float4(c * a, a);
    }

    // ---------------------------------------------------------------- the fence posts (the keys)
    struct PostInstance { float4 rect; float4 info; };   // NDC x0, y0, x1, y1; picket 0/1, glow, pressed, light
    struct PostOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex PostOut cell_post_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant PostInstance* posts [[buffer(0)]],
                                    constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        PostInstance k = posts[iid];
        PostOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv) + view.yz, 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth cell_post_fragment(PostOut in [[stage_in]], constant float4& warm [[buffer(0)]]) {
        bool picket = in.info.x > 0.5;
        float glow = in.info.y, light = in.info.w;
        float x = in.uv.x, y = in.uv.y;
        // A timber post (or a steel star picket), a little lighter on its sunlit face; two strands of wire.
        float width = picket ? 0.16 : 0.24;
        float body = smoothstep(width, width - 0.06, abs(x - 0.5));
        float top = picket ? 0.82 : 1.0;
        body *= smoothstep(top, top - 0.02, y);
        float wire = 0.0;
        for (int i = 0; i < 2; i++) {
            float wy = 0.42 + 0.3 * float(i);
            wire = max(wire, smoothstep(0.03, 0.0, abs(y - wy)));
        }
        float a = max(body, 0.55 * wire);
        if (a < 0.004) discard_fragment();
        float grain = hash12(float2(floor(x * 18.0), floor(y * 60.0)));
        float3 timber = picket ? float3(0.12, 0.12, 0.13) : float3(0.36, 0.31, 0.25) * (0.85 + 0.25 * grain);
        float face = 0.7 + 0.3 * smoothstep(0.5 - width, 0.5 + width, x);
        float3 c = timber * warm.rgb * light * face;
        c = mix(c, float3(0.5, 0.5, 0.5) * warm.rgb * light, wire * (1.0 - body));
        // Lit white by its note: hot at the top, glowing down the post.
        c += float3(1.0, 0.97, 0.92) * (glow * (0.6 + 3.2 * y * y)) * body;
        c += float3(1.0, 0.95, 0.85) * (glow * 0.8) * wire * (1.0 - body);
        ColorDepth o;
        o.color = float4(c * a, a);
        o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
