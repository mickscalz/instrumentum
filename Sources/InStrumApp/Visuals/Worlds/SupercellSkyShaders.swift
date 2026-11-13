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
        float4 crawlInfo[4];   // light 0…1, segments, unused; [0].w: layers skipped (a timing test's mask; 0 drawn)
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

    /// Lightning's light on the cloud near a point on screen: the strikes' and the crawlers', cool blue-white. The scene
    /// reads it once a pixel and hands it to each layer as `flash` (read in each, it was up to nine loops of exp a pixel).
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

    // ---------------------------------------------------------------- compositing without a sort
    // The scene's layers are composited nearest first, as an insertion sort ordered them, but with no array: each
    // layer's light comes through the cover of every layer in front of it, found by comparing depths with fixed
    // indices (an array indexed at run time lives in scratch memory on Intel and AMD GPUs).

    /// A layer the sort took in: one that covers the pixel and stands nearer than the field. Any other is emptied (no
    /// cover, no light), so it lets everything through wherever it stands.
    void keepLayer(thread Layer& L, float t, float groundT) {
        if (L.a <= 0.0 || t >= groundT) { L.a = 0.0; L.c = float3(0.0); }
    }
    /// What a layer `tj` km off, listed after the one at `ti`, lets through to it: `kj` (1 − its cover) if it is nearer.
    float ahead(float tj, float kj, float ti) { return tj < ti ? kj : 1.0; }
    /// The same for a layer listed before it: nearer, or at the same depth (the sort kept the order they came in).
    float aheadOrLevel(float tj, float kj, float ti) { return tj <= ti ? kj : 1.0; }
    /// A layer's light through `Tin`, what the layers in front of it let through, and the light it lets through on in
    /// `T`; none once `Tin` is under 0.004 (the walk front to back stopped there).
    float3 layerLight(Layer L, float Tin, thread float& T) {
        if (Tin < 0.004) return float3(0.0);
        T *= 1.0 - L.a;
        return Tin * L.a * L.c;
    }

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

    /// Cauliflower: rounded lumps of cloud over the tower's face, `n` cells round it (a whole number, so there is no
    /// seam as it turns) and `rows` a km up it, warped so they never line up; each lit as a dome by `Lt` (the light in
    /// the face's own frame: across, up, out), soft-shadowed where two lumps meet. Returns 0…1.
    /// The lumps are a smooth sum of rounded bumps of jittered sizes, its slope taken from the sum: the light rolls over
    /// each lump and the folds between them shade softly (the nearest-lump switch drew hard polygon creases).
    float cauliflower(float2 ring, float z, float n, float rows, float3 Lt) {
        float2 g = float2((atan2(ring.y, ring.x) * 0.15915494 + 0.5) * n, z * rows);
        g += 0.7 * float2(vnoise3(float3(ring * 2.5, z * 0.6)), vnoise3(float3(ring * 2.5 + 5.0, z * 0.6))) - 0.35;
        // (The shared sky's sum of bumps, wrapped round the storm and back to the first lump.)
        float2 grad;
        float H = cloudBumps(g, n, float2(17.0), float2(3.0), 0.5, 0.3, 2.2, grad);
        float3 nrm = normalize(float3(-0.32 * grad, 1.0));
        float fold = smoothstep(0.12, 0.85, H);
        return saturate(dot(nrm, Lt)) * (0.6 + 0.4 * fold);
    }

    /// The updraft: a striated skirt flaring over the base, winding round as it turns, and the tower of billows above it
    /// leaning downshear into the anvil. Analytic shape, volume-like light: its own density toward the low sun, warm where
    /// lit and cool in shadow, dark low down in the base's shade.
    Layer tower(float3 o, float3 d, float3 flash, constant CellU& u, int octaves, thread float& tHit) {
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
        // The first guess at where the ray enters: facing us near the axis, round to the side near the silhouette (a
        // blend, so it never flips across the axis).
        float2 toward = -d.xy / sqrt(a);
        float2 side = pc / max(length(pc), 1e-3);
        float2 ringC = rot2(normalize(mix(toward, side, saturate(bm / (0.7 * Rb)))), -u.spin.x);
        float Rc = bellRadius(clamp(zc, hb, ha), ringC, u, lobes);
        float t = tc, z = zc;
        if (Rc > bm) {
            int refine = octaves >= 3 ? 4 : 3;
            for (int k = 0; k < 4; k++) {
                if (k >= refine) break;
                float2 pk = o.xy + d.xy * t - C;
                float2 rk = rot2(pk / max(length(pk), 1e-3), -u.spin.x);
                float R = bellRadius(clamp(z, hb, ha), rk, u, lobes);
                if (R <= bm) break;
                t = tc - sqrt((R * R - bb) / a);
                z = o.z + t * d.z;
            }
            // Toward the silhouette the hit eases into the ray's nearest pass, so the edge's noise is read at points
            // that meet there (switching between them drew a hard line round the silhouette).
            t = mix(tc, t, smoothstep(0.0, 0.5, Rc - bm));
            z = o.z + t * d.z;
        }
        if (t <= 0.0 || z > ha + 1.0) return L;
        float h = z - hb;                                          // km above the base
        float skirtW = 1.0 - smoothstep(2.2, 4.0, h);
        // The edge: eroded by the cloud's own density into ragged shreds where it thins (the sides and the top), the
        // billows' cauliflower above; the sky shows through the thin parts, so it reads as vapour, not a cut-out.
        float upper = 1.0 - skirtW;
        float rimT = 1.0 - smoothstep(0.3, 2.4, Rc - bm);
        float soft = 0.2 + 0.012 * t;
        // (The fraying below moves the edge at most 0.8 + 1.5 × upper km (its noise is 0…1), so a ray passing farther
        // outside than that and the edge's softness misses the cloud whatever the noise: it reads none. Everything
        // the cover needs is read before the light's noise, which only a covered pixel pays for. On Intel and AMD GPUs
        // this skips most of the tower's noise round its silhouette; the pixels it draws are unchanged.)
        if (Rc - bm + rimT * (0.8 + 1.5 * upper) <= -soft) return L;
        float3 P = o + d * t;
        float2 Cz = axisAt(clamp(z, hb, ha), u);
        float2 rel = P.xy - Cz;
        float rr = max(length(rel), 0.1);
        float2 radial2 = rel / rr;
        float2 ring = rot2(radial2, -u.spin.x);
        // (The fraying is read where the ray passes nearest the axis, which moves evenly from pixel to pixel; read on
        // the surface it crowded into ribbons along the silhouette, as surface texture does toward a limb.)
        float3 pn = float3(rot2(pc, -u.spin.x), zc);
        float wisps = fbm3(pn * 1.9 + float3(0.0, 0.0, 19.0), octaves);
        float turrets = 2.0 * (octaves >= 3 ? fbm3(pn * 0.7 + 41.0, 2) : vnoise3(pn * 0.7 + 41.0)) - 1.0;
        float fray = 0.9 * upper * turrets + (1.6 + 1.2 * upper) * (wisps - 0.5);
        float edge = Rc - bm + rimT * fray;
        float thin = 1.0 - smoothstep(0.0, 1.2, edge);
        float cover = smoothstep(-soft, 1.6 * soft, edge);
        cover *= 1.0 - 0.8 * thin * (1.0 - smoothstep(0.3, 0.72, wisps));
        // Its underside: no ruled line, but a ragged lowering of scud a few hundred metres under the base.
        float scud = fbm3(float3(ring * 2.6, 3.0 + 0.4 * u.spin.x), 2);
        float bottomZ = hb - 0.08 - 0.5 * scud * scud - 0.25 * (wisps - 0.5);
        cover *= smoothstep(bottomZ - 0.06, bottomZ + 0.22, z);
        if (cover <= 0.002) return L;
        float R0 = bellRadius(clamp(z, hb, ha), ring, u, lobes);
        // The point in the turning frame (where the ray passes, so a ray missing the silhouette samples the air beyond
        // it, not the surface again: no streaks off its sides).
        float3 pt = float3(rot2(rel, -u.spin.x), z);
        float3 Ls = u.sunL.xyz;
        float3 Lr = float3(rot2(Ls.xy, -u.spin.x), Ls.z);
        // Striations on the skirt: helical (one band a turn, so seamless at any spacing), turning with the storm; their
        // spacing wanders round it and up it, and they bow and curl with the turn.
        float bow = fbm3(float3(ring * 1.3, h * 0.45 + 2.0), 2) - 0.5;
        float k = h * (0.95 + 0.6 * vnoise3(float3(ring * 0.9, 5.0))) + atan2(ring.y, ring.x) * 0.15915494 + 1.3 * bow
                + 0.9 * (lobes - 0.5);
        float dens;
        float light = billows(pt, Lr, 1.15, 0.25 * skirtW, k, octaves, dens);
        // The shape's own slope and lobes turn it toward or away from the sun.
        float e = 0.08, lobesA, lobesU;
        float Ra = bellRadius(clamp(z, hb, ha), rot2(ring, e), u, lobesA);
        float Ru = bellRadius(clamp(z + 0.25, hb, ha), ring, u, lobesU);
        float3 r3 = float3(radial2, 0.0), tangent = float3(-radial2.y, radial2.x, 0.0);
        float3 N = normalize(r3 - tangent * ((Ra - R0) / (e * R0)) * 1.6 - float3(0, 0, 1) * ((Ru - R0) / 0.25) * 1.3);
        // The light: the low sun from behind the camera warms the faces turned to it, more the higher they stand (low
        // down the cloud is in the base's shade and the rain-cooled air); its own billows shadow it.
        float facing = saturate(dot(N, Ls));
        float high = smoothstep(1.2, 7.0, h);
        // The skirt is laminar and smooth (soft light over its curve); the tower above is cauliflower (its billows'
        // tops lit, the creases between them in shadow).
        float3 Lt = normalize(float3(dot(Ls.xy, float2(-radial2.y, radial2.x)), Ls.z + 0.25, dot(Ls.xy, radial2)));
        float lump = upper > 0.01 ? cauliflower(ring, z, 22.0, 0.7, Lt) : 1.0;
        float lit = facing * facing * (0.5 + 0.5 * light) * mix(1.0, 0.3 + 0.7 * lump, 0.7 * upper) * (0.16 + 0.84 * high);
        // The striations: texture, not lines: a lip catching the light over a soft shadow, strongest low on the skirt.
        float strength = smoothstep(0.15, 0.85, vnoise3(float3(ring * 1.3, k * 0.45 + 11.0))) * skirtW
                       * (1.0 - smoothstep(0.2, 3.2, h));
        float lip;
        float bandShade = cloudStriation(k, strength, lip);
        // The body: dark steel blue-grey in the sky's light, darker on the side away from the sun.
        float away = saturate(-dot(radial2, normalize(Ls.xy)));
        float3 body = u.amb.rgb * float3(0.62, 0.8, 1.06) * (0.2 + 0.1 * dens + 0.08 * N.z) * (1.0 - 0.3 * away);
        float3 warm = u.sunCol.rgb * float3(1.0, 0.86, 0.62) * ((0.6 + 0.6 * upper) * lit);
        float3 c = (body * (1.0 - 0.45 * lit) + warm) * bandShade;
        // Each band's lip catches a thread of the low sun.
        c += u.sunCol.rgb * float3(1.0, 0.84, 0.62) * (0.07 * lip * facing * (0.5 + 0.5 * light));
        // A soft glow inside it: light scattered through the cloud, faint, warmest where it is lit.
        c += u.sunCol.rgb * float3(1.0, 0.78, 0.6) * (0.035 * smoothstep(0.4, 3.0, edge) * (0.4 + dens) * (0.3 + high));
        // Darker toward the base, and greener under the core (the hail's side, low down).
        c *= mix(0.22, 1.0, smoothstep(-0.5, 2.8, h)) * (1.0 - 0.22 * u.look.x * (1.0 - high));
        float coreSide = exp(-length(P.xy - u.shaft.xy) / 7.0) * (1.0 - smoothstep(0.0, 3.0, h));
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, lum * float3(0.72, 1.12, 0.98), saturate(u.look.y * 3.5 * coreSide));
        // Its top goes up into the anvil (whose underside sags over it): into the anvil's own shade, well before the
        // anvil meets it, so the two are one cloud with no seam between them.
        // The join is lumpy (the tower's turrets pushing up into it), below the anvil's own plane, so the plane's
        // smooth line is lost in cloud of one colour.
        float anvilZ = ha - 2.4 * exp(-length(P.xy - axisAt(ha, u)) / (u.dims.y * 0.7));
        float lumpsTop = octaves >= 3 ? fbm3(pt * 0.55 + 23.0, 2) : dens;
        float junction;
        float intoAnvil = cloudAnvilMelt(z, anvilZ, lumpsTop, junction);
        float3 anvilShade = u.amb.rgb * 0.22 + float3(0.03, 0.032, 0.045);
        c = mix(c, anvilShade, intoAnvil);
        // A gold lining on its top edge, where the cloud thins toward the low sun.
        float rimBand = smoothstep(-0.1, 0.2, edge) * (1.0 - smoothstep(0.3, 1.2, edge));
        float topBand = smoothstep(junction - 1.3, junction - 0.25, z) * (1.0 - intoAnvil);
        float lining = max(rimBand * smoothstep(2.4, 5.0, h) * (1.0 - intoAnvil), 0.8 * topBand) * (0.3 + 0.7 * light)
                     * (0.35 + 0.65 * saturate(0.5 + dot(radial2, normalize(Ls.xy))));
        c += u.sunCol.rgb * float3(1.0, 0.9, 0.64) * (0.8 * lining);
        // Where it thins, the bright air behind shows through it a little.
        c = mix(c, u.haze.rgb * 0.7, 0.3 * thin * (1.0 - lining));
        c += flash * (0.4 + 0.6 * dens);
        // Into the anvil it gives way to the anvil's own cloud behind it, softly (a hard cut at the anvil's height drew
        // a pale cap with a stepped edge over the tower's top).
        L.a = cover * (1.0 - 0.9 * intoAnvil) * (1.0 - smoothstep(ha - 0.6, ha + 0.8, z));
        L.c = aerial(c, t * mix(0.45, 0.35, intoAnvil), u);        // the storm's own dark air; the anvil's where it joins
        tHit = t;
        return L;
    }

    /// The flanking line: cumulus towers stepping down to the right of the updraft, feeding it (spheroids standing on
    /// the base's level, billowed and lit as the tower is). `which` 0 is the nearest tower the ray meets, 1 the one
    /// behind it (so the front one's ragged edge shows the next, not the sky).
    /// Where the ray meets the flanking line's towers: the nearest (`best`, how far inside its outline the ray passes,
    /// its centre and radii) and the one behind it (`second`, …); 1e9 for none.
    struct FlankHits { float best, bestInside, second, secondInside; float3 bestCentre, bestRadii, secondCentre, secondRadii; };

    FlankHits flankHits(float3 o, float3 d, constant CellU& u) {
        float2 C = u.place.xy;
        float hb = u.dims.x, Rb = u.dims.y;
        float best = 1e9, bestInside = -1e3, second = 1e9, secondInside = -1e3;
        float3 bestCentre = float3(0), bestRadii = float3(1), secondCentre = float3(0), secondRadii = float3(1);
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
            if (inside <= 0.0 || disc <= 0.0) continue;
            float t = (-b - sqrt(disc)) / a;
            if (t <= 0.0 || o.z + t * d.z < hb - 0.35) continue;
            if (t < best) {
                second = best; secondInside = bestInside; secondCentre = bestCentre; secondRadii = bestRadii;
                best = t; bestInside = inside; bestCentre = centre; bestRadii = radii;
            } else if (t < second) {
                second = t; secondInside = inside; secondCentre = centre; secondRadii = radii;
            }
        }
        FlankHits fh;
        fh.best = best; fh.bestInside = bestInside; fh.bestCentre = bestCentre; fh.bestRadii = bestRadii;
        fh.second = second; fh.secondInside = secondInside; fh.secondCentre = secondCentre; fh.secondRadii = secondRadii;
        return fh;
    }

    /// One of the flanking line's towers (`which` 0 the nearest the ray meets, 1 the one behind it), from its hits.
    Layer flankingLine(float3 o, float3 d, float3 flash, constant CellU& u, int octaves, FlankHits fh, int which,
                       thread float& tHit) {
        Layer L; L.a = 0.0; L.c = float3(0); tHit = 1e9;
        float hb = u.dims.x;
        float best = which == 1 ? fh.second : fh.best;
        float bestInside = which == 1 ? fh.secondInside : fh.bestInside;
        float3 bestCentre = which == 1 ? fh.secondCentre : fh.bestCentre;
        float3 bestRadii = which == 1 ? fh.secondRadii : fh.bestRadii;
        if (best > 1e8) return L;
        float3 P = o + d * best;
        float2 pr = rot2(P.xy - u.place.xy, -0.3 * u.spin.x);
        float3 pt = float3(pr, P.z);
        float3 Ls = u.sunL.xyz;
        float dens;
        float light = billows(pt + 13.0, Ls, 1.0, 0.0, 0.0, octaves, dens);
        // Cauliflower: big lumps on the sides, turrets on the tops.
        float lumps = 2.0 * fbm3(pt * 0.8 + 31.0, octaves) - 1.0;
        float wisps = fbm3(pt * 2.1 + 5.0, octaves);
        float upper = smoothstep(hb + 1.0, hb + 4.5, P.z);
        // Only near the silhouette: deep inside, the tower stays whole (no holes through it); at it, shredded vapour.
        float rim = 1.0 - smoothstep(0.4, 2.0, bestInside);
        // Eroded inward only, so a nearer tower's fringe is never cut by the choice of tower.
        float fray = (0.45 + 0.75 * upper) * lumps + 1.2 * (dens - 0.5) + 0.8 * (wisps - 0.5);
        float edge = bestInside + rim * min(fray - 0.35, 0.0);
        float thin = 1.0 - smoothstep(0.0, 0.9, edge);
        float cover = smoothstep(0.0, 0.45, edge) * (1.0 - 0.75 * thin * (1.0 - smoothstep(0.3, 0.7, wisps)));
        float foot = hb - 0.25 * fbm3(float3(P.xy * 1.7, 2.0), 2);
        cover *= smoothstep(foot - 0.05, foot + 0.25, P.z);
        if (cover <= 0.002) return L;
        float3 N = normalize((P - bestCentre) / (bestRadii * bestRadii));
        float facing = saturate(dot(N, Ls));
        float high = smoothstep(0.2, 4.5, P.z - hb);
        float lit = facing * facing * smoothstep(0.2, 0.9, light) * (0.25 + 0.75 * high);
        float3 c = u.amb.rgb * float3(0.72, 0.84, 1.0) * (0.2 + 0.1 * dens + 0.08 * N.z) * (1.0 - 0.45 * lit)
                 + u.sunCol.rgb * float3(1.0, 0.84, 0.64) * (0.72 * lit);
        c *= mix(0.45, 1.0, smoothstep(-0.2, 1.6, P.z - hb));
        // The gold catches their tops; their thin edges show the air behind.
        float lining = smoothstep(-0.1, 0.2, edge) * (1.0 - smoothstep(0.3, 1.0, edge)) * upper * (0.3 + 0.7 * light)
                     * saturate(0.4 + N.z + 0.5 * dot(N.xy, normalize(Ls.xy)));
        c += u.sunCol.rgb * float3(1.0, 0.9, 0.64) * (0.65 * lining);
        c = mix(c, u.haze.rgb * 0.7, 0.3 * thin * (1.0 - lining));
        c += flash * 0.3;
        L.a = cover;
        L.c = aerial(c, best, u);
        tHit = best;
        return L;
    }

    // ---------------------------------------------------------------- the rain-free base
    Layer base(float3 o, float3 d, float3 flash, constant CellU& u, int octaves, thread float& tHit) {
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
        float ang = atan2(ring.y, ring.x);
        float rag = cloudRagged(ang, octaves);
        // At least as wide as the skirt's foot, so a ray passing under the skirt's ragged bottom always meets the base
        // (narrower, it left a line of sky between them).
        float foot = bellRadius(hb, ring, u, lobes);               // (read once: the edge and the overhang share it)
        float edge = 1.02 * foot - r + 1.1 * (rag - 0.3);
        float cover = smoothstep(-0.9, 0.7, edge);
        // Where it reaches out past the skirt's foot it frays into the air. That overhang lies behind the skirt (a ray
        // meets it before the skirt's face just above it, and drawn in front it ruled a line across the skirt), so it
        // is composited behind the storm's other cloud and shows only where the skirt is absent or thin.
        float past = smoothstep(0.98, 1.04, r / max(foot, 1.0));
        float fr = fbm2(rel * float2(0.9, 0.2) + float2(4.0, 1.0), octaves);
        cover *= 1.0 - past * (1.0 - smoothstep(0.2, 1.4, edge)) * (1.0 - 0.6 * smoothstep(0.35, 0.65, fr));
        float behind = r > foot ? 40.0 : 0.0;
        // Beyond the storm's middle, on the rain's side, the base is lost in the rain.
        float rainSide = 1.0 - smoothstep(u.wall.x - 3.0, u.wall.x + 1.0, P.x);
        cover *= 1.0 - 0.85 * rainSide * smoothstep(C.y - 2.0, C.y + 2.0, P.y);
        if (cover <= 0.002) return L;
        // Mottled, with a faint spiral turning with the storm, inward to the wall cloud.
        float2 sp = rot2(pr, 0.8 * u.spin.y * log(max(r, 0.4)));
        float swirl = 0.6 * fbm2(sp * float2(0.3, 0.6) + 3.1, octaves) + 0.4 * fbm2(pr * 0.6 + 8.0, octaves);
        float dark = u.look.x;
        float3 under = float3(0.035, 0.04, 0.05) * (0.6 + 0.8 * swirl);
        under += u.amb.rgb * (0.05 * (0.6 + 0.8 * swirl));
        under += float3(0.55, 0.36, 0.18) * u.sunCol.rgb * 0.035;          // the field's warm bounce
        under *= (1.1 - 0.65 * dark) * (1.0 - 0.35 * u.gust.y);           // darker still in the drop
        // Green under the core, over the hail shaft.
        float core = exp(-length(P.xy - u.shaft.xy) / 5.0);
        float l = dot(under, float3(0.2126, 0.7152, 0.0722));
        under = mix(under, l * float3(0.72, 1.2, 1.0), saturate(u.look.y * 8.0 * core));
        // A chord's pulse: a ring of light spreading out over the base from the wall cloud.
        if (u.glowL.z > 0.0) {
            float dw = length(P.xy - u.wall.xy) - u.wall.z;
            float ringR = u.glowL.w * (Rb * 0.8);
            float ringD = (dw - ringR) / (0.7 + 1.1 * u.glowL.w);
            float fadeOut = 1.0 - 0.6 * u.glowL.w;                     // dimmer as it spreads
            under += float3(1.0, 0.8, 0.55) * (u.glowL.z * fadeOut * (0.16 * exp(-ringD * ringD) + 0.12 * exp(-max(dw, 0.0) / 1.0)));
        }
        under += flash * 0.5;
        L.a = cover;
        L.c = aerial(under, t * 0.6, u);
        tHit = t + behind;
        return L;
    }

    // ---------------------------------------------------------------- the wall cloud
    /// The wall cloud: an abrupt lowering hanging under the base, narrowing to a ragged bottom of scud, streaked
    /// vertically as it turns; its top is the base itself.
    Layer wallCloud(float3 o, float3 d, float3 flash, constant CellU& u, int octaves, thread float& tHit) {
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
        // (A ray passing its axis more than 0.125 km over the base is past its top whatever its cloud (its density moves
        // the top 0.075 km at most): it reads none. The test above is a column of all heights, so this spares the
        // wall cloud's noise in the strip of sky over it; the pixels it draws are unchanged.)
        if (zc - 0.075 >= hb + 0.05) return L;
        float t = tc, z = zc;
        for (int k = 0; k < 3; k++) {
            float down = saturate((hb - z) / (hb - bottom));
            float R = Rw * sqrt(max(1.0 - 0.8 * down * down, 0.05));     // a rounded lowering, not a cone
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
        float downC = 1.0 - hzc;
        float Rs = Rw * sqrt(max(1.0 - 0.8 * downC * downC, 0.05)) * (1.0 + 0.16 * bulge);
        // (Its density widens it 0.4 km at most: a ray passing farther out misses it whatever the noise.)
        if (bm - (Rs + 0.4) >= 0.12) return L;
        float3 Ls = u.sunL.xyz;
        float3 Lr = float3(rot2(Ls.xy, -u.spin.x), Ls.z);
        float3 pt = float3(rot2(rel, -u.spin.x), z * 1.6);           // its own cloud, turning with it
        float dens;
        float light = billows(pt, Lr, 1.7, 0.0, 0.0, octaves, dens);
        float R = Rs + 0.8 * (dens - 0.5);
        // A ragged bottom: scud tags hanging below it.
        float bottomZ = bottom + 0.5 * (fbm2(ring * 3.0 + float2(z, 7.0), octaves) - 0.45) + 0.25 * (dens - 0.5);
        float side = smoothstep(0.12, -0.12, bm - R);
        float low = smoothstep(bottomZ - 0.05, bottomZ + 0.12, zc);
        // Its top melts into the base it hangs from (a cut there drew a lid).
        float cover = side * low * (1.0 - smoothstep(hb - 0.35, hb + 0.05, zc + 0.15 * (dens - 0.5)));
        if (cover <= 0.002) return L;
        float hz = saturate((z - bottom) / (hb - bottom));
        float3 N = normalize(float3(rel / rr, 0.35));
        float facing = saturate(0.6 * dot(N, Ls) + 0.4);
        // Rotating streaks of scud wrapping round it, rising as they turn (3D noise on the ring: no seam).
        float scud = fbm3(float3(rot2(ring, 1.2 * hz) * 3.2, z * 1.2), 2);
        float3 c = u.sunCol.rgb * float3(1.0, 0.8, 0.62) * (0.06 * facing * light) + u.amb.rgb * float3(0.76, 0.86, 1.0) * (0.05 + 0.07 * dens)
                 + float3(0.018, 0.021, 0.028);
        c *= 0.75 + 0.5 * scud;
        // Darker into its top, where it is the base; lighter low down, in the bright horizon's light from beyond.
        c *= 0.7 + 0.45 * (1.0 - hz);
        c += u.haze.rgb * (0.05 * (1.0 - hz) * (1.0 - hz));
        c *= (1.15 - 0.6 * u.look.x) * (1.0 - 0.3 * u.gust.y);
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, l * float3(0.78, 1.12, 1.0), saturate(u.look.y * 3.0));
        // A chord's pulse lights it from inside, low down (through its own cloud, so it glows, it does not paint);
        // a ripple brightens where it passes.
        float lowPart = 1.0 - hz;
        c += float3(1.0, 0.58, 0.26) * (u.glowL.z * 0.09 * lowPart * lowPart * lowPart * (0.3 + 0.9 * dens));
        c += u.amb.rgb * float3(0.85, 0.92, 1.0) * (0.07 * min(bulge, 1.5) * (0.4 + dens));   // brighter cloud, not sunlight
        c += flash * 0.6;
        // Ragged where it thins at its sides and its foot.
        cover *= 1.0 - 0.6 * (1.0 - smoothstep(0.0, 0.5, R - bm)) * (1.0 - smoothstep(0.35, 0.7, scud));
        cover *= 1.0 - 0.7 * (1.0 - smoothstep(0.0, 0.3, zc - bottomZ)) * (1.0 - smoothstep(0.3, 0.65, scud));
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
        // Each band a slab of cloud ±130 m round 750 m up: the ray's run through the slab is from its floor to its
        // ceiling, and a band is met if that run passes its line (seen edge-on a band has the slab's depth, not a
        // plane's hairline, which a note's glow turned into a laser line).
        const float h = 0.75, th = 0.13;
        if (d.z <= 1e-4) return L;
        float t = (h - o.z) / d.z;
        // (Within 4 km the bands have thinned to nothing (`ends` below): the sky higher up than that reads none.)
        if (t <= 4.0) return L;
        float2 W = u.wall.xy;
        float2 q0 = o.xy + d.xy * ((h - th - o.z) / d.z) - W, q1 = o.xy + d.xy * ((h + th - o.z) / d.z) - W;
        float r0 = length(q0), r1 = length(q1);
        float r = 0.5 * (r0 + r1);
        float rMax = 15.0;
        if (r < u.wall.z * 0.8 || r > rMax) return L;
        // They fan in from the field off to the right of the camera, rising toward us in perspective.
        float centre = atan2(-1.0 - W.y, 4.0 - W.x);
        float spacing = u.spin.z;
        float f0 = (atan2(q0.y, q0.x) + 0.3 * u.spin.y * log(max(r0, 0.1) / u.wall.z) - centre) / spacing + 3.0;
        float f1 = (atan2(q1.y, q1.x) + 0.3 * u.spin.y * log(max(r1, 0.1) / u.wall.z) - centre) / spacing + 3.0;
        float k = floor(0.5 * (f0 + f1) + 0.5);                   // band k where the run's middle is nearest
        if (k < -0.5 || k > 6.5 || abs(f1 - f0) > 1.5) return L;
        float flow = u.spin.w;
        // A laminar band: a firm edge that wanders a little, clumped along its length as its cloud is carried in.
        float wander = fbm2(float2((r + flow) * 0.35, k * 5.1), 2) - 0.5;
        float width = (0.3 + 0.06 * r) * (0.8 + 0.5 * wander);
        float a0 = (f0 - k) * spacing * r0 + 0.6 * width * wander, a1 = (f1 - k) * spacing * r1 + 0.6 * width * wander;
        float across = a0 * a1 <= 0.0 ? 0.0 : (abs(a0) < abs(a1) ? a0 : a1);   // km off the band's line, at the nearest
        float off = abs(across);
        float streak = fbm2(float2((r + flow) * 0.6, 0.5 * (a0 + a1) * 3.0 + k * 3.7), octaves);
        float ends = smoothstep(u.wall.z * 0.9, u.wall.z * 2.0, r) * (1.0 - smoothstep(rMax * 0.4, rMax * 0.8, r));
        // Seen from the field they lie low over the horizon: the stretch passing over the camera (which would sweep
        // across the whole storm as long scratches) thins away.
        ends *= smoothstep(4.0, 8.0, t);
        // Far off and low over the horizon (seen nearly edge-on) they fade too: there they drew a faint line under the
        // base.
        ends *= mix(0.15, 1.0, smoothstep(0.04, 0.1, d.z / max(length(d), 1e-4)));
        float profile;                                             // soft-edged: a band of cloud, not a thread
        float dens = cloudInflow(off, width, streak, profile) * ends * (0.22 + 0.16 * u.play.x);
        // A note's glow running up this band into the wall cloud.
        float glow = 0.0;
        for (int i = 0; i < 8; i++) {
            float4 g = u.glows[i];
            if (g.z <= 0.0 || abs(g.x - k) > 0.5) continue;
            float rg = mix(rMax * 0.7, u.wall.z, g.y);
            float x = (r - rg) / 1.0;
            glow += g.z * exp(-x * x);
        }
        // At most one note's worth of light along a band: a soft warm glow in the cloud, never a white line (it used to
        // be divided by the band's thin alpha and blew past 1 into a streak).
        glow = min(glow * profile * ends, 1.0);
        float a = saturate(dens + 0.3 * glow);
        if (a <= 0.002) return L;
        float3 c = (u.amb.rgb * 0.26 + float3(0.03, 0.032, 0.04)) * (0.8 + 0.4 * streak)
                 + u.sunCol.rgb * float3(1.0, 0.82, 0.64) * ((0.05 + 0.06 * streak) * u.sunCol.w);
        c *= 1.1 - 0.5 * u.look.x;
        c = (c * dens + float3(1.0, 0.66, 0.34) * (0.26 * glow * (0.6 + 0.4 * streak))) / a;
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
        if (tc <= 0.0 || zc > hb + 0.1 || zc < -0.3 || bb >= R * R * 1.4) return L;
        float z = clamp(zc, 0.0, hb);
        float2 p = o.xy + d.xy * tc - A;
        float fall = u.a.y * 0.3;
        float across = p.x / R;                                    // −1 … 1 across the column as seen
        float wobble = 0.3 * (fbm2(float2(z * 0.8 + 1.7, fall * 0.2), 2) - 0.5);
        float x = across + wobble;
        // A soft column: feathered wide at its sides, no hard edge.
        float profile = saturate(1.0 - 0.8 * x * x);
        profile *= profile * profile;
        // Soft falling streaks along the slant, low in contrast: a veil of hail, not ruled stripes.
        float st = fbm2(float2(across * 5.0 + 3.0, z * 0.3 + fall), 2);
        float st2 = mix(1.0, 0.65 + 0.7 * st, streaks);
        float top = 1.0 - smoothstep(hb - 0.35, hb + 0.05, zc);
        float foot = 0.7 + 0.3 * smoothstep(0.0, 0.5, z);           // thinning a little where it bounces at the foot
        float alpha = (1.0 - exp(-density * 2.0 * R * profile * st2)) * top * foot;
        if (alpha <= 0.002) return L;
        // Lit from within its core and a little more on the side toward the sun; a faint glow round its middle.
        float side = 0.85 + 0.3 * saturate(0.5 + 0.5 * x * sign(u.sunL.x));
        float core = 0.75 + 0.35 * exp(-x * x * 3.0);
        L.a = alpha;
        L.c = aerial(lit * side * core * (0.9 + 0.2 * st), tc, u);
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
        // The rain slants as it falls (blown toward the inflow notch): everything here is measured along the slant.
        float s = P.x - 0.6 * (hb - z);
        float reach = abs(s - u.place.x) / u.dims.y;
        // (Right of its farthest reach toward the notch (its edge wanders 1 km at most), or beyond the base's far side,
        // there is no rain whatever its noise: none is read.)
        if (s - (u.wall.x - u.wall.z * 0.9 + 1.0) >= 0.8 || reach >= 1.3) return L;
        float right = u.wall.x - u.wall.z * 0.9 + 2.0 * (fbm2(float2(z * 0.9 + fall * 0.3, 3.3), 2) - 0.5);
        float x = s - right;
        // Shafts of heavier rain within it, wide and soft, falling.
        float st = fbm2(float2(s * 2.2, z * 0.2 + fall), octaves);
        float shafts = smoothstep(0.25, 0.75, fbm2(float2(s * 0.45 + 7.0, 1.0), 2));
        float dens = (1.0 - smoothstep(-3.0, 0.8, x)) * (0.4 + 0.35 * st + 0.35 * shafts) * (0.35 + 0.65 * u.play.w);
        // It hangs from the storm: none beyond the base's far side, softly into the base above.
        dens *= 1.0 - smoothstep(0.85 + 0.2 * st, 1.3, reach);
        float hang = hb - 0.05 - 0.35 * fbm2(float2(s * 0.8 + 2.0, 5.0), 2);
        float top = 1.0 - smoothstep(hang - 0.12, hb + 0.05, P.z);
        float a = saturate(dens * 2.1) * 0.94 * top;
        if (a <= 0.002) return L;
        // Translucent at its foot, where the bright horizon behind it shows through and lights the falling rain.
        float low = 1.0 - smoothstep(0.0, hb * 0.7, z);
        a *= 1.0 - 0.3 * low * (1.0 - shafts);
        L.a = a;
        L.c = aerial(lit * (0.7 + 0.4 * st) * (1.1 - 0.3 * shafts) + u.haze.rgb * (0.16 * low), t * 0.5, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the anvil overhead
    Layer anvil(float3 o, float3 d, float3 flash, constant CellU& u, int octaves, thread float& tHit) {
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
        // Its fringe in lobes about as deep as they are wide (deeper ones drew long streaks toward the horizon).
        float fringe = fbm2(P.xy * float2(0.3, 0.2) + 4.0, octaves);
        float edge = reach - P.y + 6.0 * (fringe - 0.5);
        float cover = smoothstep(-0.5, 2.0, edge) * (1.0 - smoothstep(55.0, 70.0, abs(P.x - C.x)));
        if (cover <= 0.002) return L;
        int mo = int(u.extra.y + 0.5);
        // Mammatus: pouches hanging under it (the nearest of a jittered grid of centres), lit on the side facing the low
        // sun, shadowed in the creases between.
        float2 g = P.xy / 1.45;
        g += (float2(fbm2(g * 0.3, mo), fbm2(g * 0.3 + 5.2, mo)) - 0.5) * 1.6;
        // Round pouches of jittered sizes summed smoothly (the nearest-centre switch drew a honeycomb), each sagging
        // most at its middle; the slope comes from the sum, so the light rolls round every pouch and the creases
        // between them are soft folds (the shared sky's mammatus).
        float patch = smoothstep(0.35, 0.75, fbm2(P.xy * 0.06 + 2.0, 2));
        float mam = u.after.w * patch * smoothstep(-4.0, 4.0, edge) * (1.0 - smoothstep(30.0, 50.0, edge));
        float dome;
        float3 N = mammatusNormal(g, mam, 0.5, dome);
        float lowSun = 1.0 - smoothstep(-1.0, 10.0, u.sunL.w);
        float ndl = saturate(dot(N, u.sunL.xyz) * 2.0 + 0.15);
        float tex = fbm2(P.xy * 0.15 + 9.0, octaves);
        float3 underside = (u.amb.rgb * 0.24 + float3(0.035, 0.038, 0.05)) * (0.75 + 0.5 * tex) * (1.15 - 0.4 * u.look.x);
        float3 sunlit = u.sunCol.rgb * float3(1.0, 0.72, 0.55) * ((0.05 + 0.3 * lowSun) * ndl * mam);
        float crease = 1.0 - 0.32 * mam * (1.0 - dome);
        float thin = 1.0 - smoothstep(0.0, 22.0, edge);              // thinner, lighter toward its far edge
        float3 c = (underside * (0.85 + 0.3 * dome * mam) * (0.8 + 0.9 * thin) + sunlit) * crease;
        // The far edge, where the low sun catches it from below.
        c += u.sunCol.rgb * float3(1.0, 0.7, 0.55) * (0.22 * (1.0 - smoothstep(0.0, 8.0, edge)) * (0.5 + fringe));
        c += flash * (0.6 + 0.4 * dome * mam) * (0.85 + 0.3 * tex);
        L.a = cover;
        L.c = aerial(c, t * 0.35, u);
        tHit = t;
        return L;
    }

    // ---------------------------------------------------------------- the field
    /// The gust front's distance (m) `X` m across the field: ragged, a few metres ahead or behind along its length
    /// (< 0: no front).
    float gustFrontAt(float X, constant CellU& u) {
        float F = u.gust.x * 1000.0;
        return F < 0.0 ? -1.0 : F + (4.0 + 0.1 * F) * (fbm2(float2(X * 0.07 - u.a.y * 0.15, 2.9), 2) - 0.5);
    }

    /// How deep in the storm's shadow the field is `dist` m ahead and `X` m across (0: lit by the low sun from behind
    /// the camera; 1: shadowed): the shadow's ragged edge drifts across the field a few tens of metres out.
    float fieldShadow(float dist, float X, constant CellU& u) {
        float edgeM = 42.0 * (0.6 + 0.8 * vn2(float2(X * 0.015 - u.a.y * 0.02, 3.7)));
        return smoothstep(0.45 * edgeM, 1.9 * edgeM, dist);
    }

    /// The field's light: the low sun warm on the near field, the storm's shadow cool and dark over the far field, and
    /// the gust front's dust over the field it has crossed.
    float3 fieldLight(float3 c, float dist, float X, constant CellU& u) {
        float sh = fieldShadow(dist, X, u) * (0.55 + 0.45 * u.look.x);
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(c, l * float3(0.8, 0.86, 0.98), 0.45 * sh) * (1.0 - 0.62 * sh);
        float F = gustFrontAt(X, u);
        if (F >= 0.0 && u.gust.y > 0.0) {
            float dustAmt = u.gust.y * smoothstep(F + 2.0, F + 45.0, dist) * (0.15 + 0.3 * vn2(float2(X * 0.04 + u.a.y * 0.5, dist * 0.02)));
            float3 dustC = float3(0.55, 0.42, 0.3) * (u.sunCol.rgb * 0.4 + u.amb.rgb * 0.7);
            c = mix(c, dustC, dustAmt);
        }
        return c;
    }

    /// The wheat: rows of blades at the renderer's distances, each row leaning with the wind field's sample there.
    /// Returns the blade cover (0 where the ground shows) and its colour.
    float4 wheat(float3 o, float3 d, constant CellU& u) {
        int rows = int(u.extra.x + 0.5);
        float eye = u.place.z * 1000.0, H = u.extra.z;
        float down = -d.z / max(length(d.xy), 1e-4);             // tan of the depression
        if (down <= 0.0) return float4(0);
        float nearD = (eye - H * 1.05) / down, farD = eye / down;
        float pix = u.a.w;
        // The drill rows, read where the ray meets the ground (continuous, so they run unbroken to the horizon however
        // few rows of blades are sampled): lines converging on the vanishing point, faded where finer than a few pixels.
        float groundAlong = farD / max(d.y, 1e-4);
        // (A pixel's footprint across the rows: their spread on screen, and toward the sides their run down it.)
        float spread = pix * groundAlong * (1.0 + abs(d.x) / max(d.y, 1e-3) * farD / max(eye, 1e-3));
        float drillSeen = 1.0 - smoothstep(0.12, 0.3, spread / 0.3);
        float drill = 0.5 + 0.5 * cos(6.2831853 * (o.x * 1000.0 + d.x * groundAlong) / 0.3);
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
                // Each row and each patch its own straw: riper gold, paler, a little browner.
                float rowTint = hash12(float2(float(i), 3.3));
                float patch = fbm2(float2(X * 0.04, D * 0.03 + float(i) * 0.1), 2);
                float3 straw = mix(float3(0.6, 0.42, 0.2), float3(0.82, 0.64, 0.32), patch) * shade * (0.95 + 0.1 * rowTint);
                float3 lit = u.sunCol.rgb * 0.62 * (0.55 + 0.45 * v) + u.amb.rgb * (0.5 + 0.3 * v);
                float3 c = straw * lit * (0.5 + 0.5 * v) * (1.0 - 0.32 * drillSeen * (1.0 - drill));
                // The sheen of wheat leaning in the wind (strongest laid toward the camera), and the gust front's wave: a
                // bright line of blades bent over as it crosses the field.
                float sheen = row.w + 0.7 * saturate(abs(row.y) / 0.25);
                float F = gustFrontAt(X, u);
                float wave = F >= 0.0 ? exp(-sq((D - F) / max(3.0, 0.14 * F))) : 0.0;
                c += u.sunCol.rgb * float3(1.0, 0.9, 0.68) * (0.32 * sheen * v * v + 1.1 * wave * (0.35 + 0.65 * v));
                c = fieldLight(c, D, X, u);
                c += straw * flashOnCloud(float2(0.0, 0.3), u) * (0.6 + 0.6 * v);   // lightning lights the wheat
                return float4(aerial(c, along * 0.001, u), cover);
            }
        }
        return float4(0);
    }

    /// The ground: stubble between the rows, the far field, a line of trees and a silo low on the horizon on the left.
    float3 field(float3 o, float3 d, float3 flash, constant CellU& u, int octaves) {
        float t = -o.z / min(d.z, -1e-5);
        float3 P = o + d * t;
        float ground = t;
        float2 m = P.xy * 1000.0;                                // metres
        float dist = (P.y - o.y) * 1000.0;
        float patches = fbm2(m * float2(0.03, 0.012) + 3.0, octaves);
        float3 straw = mix(float3(0.4, 0.29, 0.14), float3(0.62, 0.48, 0.24), patches);
        // Furrows between the drill rows: darker soil in lines running away to the horizon (where wider than a few pixels).
        float spread = u.a.w * t * 1000.0 * (1.0 + abs(d.x) / max(d.y, 1e-3) * dist / max(o.z * 1000.0, 1e-3));
        float furrows = (1.0 - smoothstep(0.12, 0.3, spread / 0.3))
                      * smoothstep(0.3, 0.9, 0.5 + 0.5 * cos(6.2831853 * (m.x + 0.15) / 0.3));
        straw *= 1.0 - 0.45 * furrows;
        float3 c = straw * (u.sunCol.rgb * 0.5 + u.amb.rgb * 0.7);
        c = fieldLight(c, dist, m.x, u);
        // The storm's shadow and rain: darker under its base, greener near the hail.
        float2 C = u.place.xy;
        float under = 1.0 - smoothstep(u.dims.y * 0.6, u.dims.y * 1.1, length(P.xy - C));
        c *= 1.0 - 0.55 * under * u.look.x;
        float rain = exp(-length(P.xy - u.shaft.xy) / (u.shaft.z * 1.2));
        c = mix(c, float3(0.06, 0.08, 0.08) * (u.amb.rgb * 2.0 + 0.05), saturate(rain * (0.4 + u.look.z)));
        c += straw * flash * 0.8;
        return aerial(c, ground, u);
    }

    /// A line of trees (a windbreak 2–3 km off) and a grain silo, left of the storm; 0 alpha where there are none.
    float4 horizonThings(float3 d, constant CellU& u) {
        // (Both stand under 0.03 rad: the sky well above that, tan 0.04 up, skips the two arctangents.)
        if (d.z > 0.04 * length(d.xy)) return float4(0);
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
        // At the front's distance from the camera, where the wheat's wave is drawn (ragged along its length).
        float t = max(gustFrontAt(d.x / d.y * front * 1000.0, u), 0.5) * 0.001 / d.y;
        float3 P = o + d * t;
        float xm = P.x * 1000.0, zm = P.z * 1000.0;              // metres
        // Lumps of dust along the front, each rolling up off the ground as the outflow drives it on.
        float lumps = fbm2(float2(xm * 0.22 - u.a.y * 0.6, 0.7), octaves);
        float H = u.gust.z * 1000.0 * (0.3 + 1.1 * lumps);
        if (zm > H * 1.5 || zm < -5.0) return L;
        float v = saturate(zm / max(H, 1e-3));
        float billow = fbm2(float2(xm * 0.75 + u.a.y * 1.6, zm * 0.9 - u.a.y * 1.4), octaves);
        float body = 1.0 - smoothstep(0.2, 1.05, v + 0.6 * (billow - 0.5));
        float a = dust * body * smoothstep(0.1, 0.55, billow + 0.4 * (1.0 - v)) * 0.9;
        a *= 0.25 + 0.75 * smoothstep(0.2, 1.4, zm);               // lifted off the field: thin at the bent wheat
        // Lit by the low sun from behind the camera on their rounded tops; browner and darker low down in their own dust.
        float tops = smoothstep(0.3, 0.9, v) * billow;
        float3 c = float3(0.56, 0.43, 0.3) * (u.sunCol.rgb * (0.35 + 0.45 * tops) + u.amb.rgb * 0.7) * (0.75 + 0.35 * billow);
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
            // The segments inside the cloud are hidden by it (their light is the cloud's glow, flashOnCloud).
            for (int i = 0; i < 24; i++) {
                if (i >= count) break;
                if (i < inCloud) continue;
                float dist = segmentDistance(p, u.segs[k * 24 + i], aspect);
                float w = (i >= branches ? 0.6 : 1.0) * px * 1.3;
                float x = dist / w;
                float bright = i >= branches ? 0.45 : 1.0;
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
    /// What the storm's layers give a pixel: their light (each through the layers in front of it), what they let through
    /// to the sky or the field behind them all, how much storm cloud covers it (the crawlers live on it) and the anvil.
    struct CloudSum { float3 col; float T; float cloudy; float anvilCover; };

    /// The view's ray for a pixel (east-north-up `dE`, the storm's frame `d`) and the eye `o`.
    void cellRay(float2 ndc, constant SkyU& sky, constant CellU& u, thread float3& dE, thread float3& d, thread float3& o) {
        dE = normalize(sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w));
        d = float3(dot(dE, float3(u.axes.zw, 0.0)), dot(dE, float3(u.axes.xy, 0.0)), dE.z);
        o = float3(0.0, -u.place.w, u.place.z);
    }

    CloudSum stormClouds(float2 ndc, float3 dE, float3 d, float3 o, float3 flash, constant CellU& u, int octaves, uint skip) {
        float3 col = float3(0);
        float cloudy = 0.0;      // how much storm cloud covers the pixel (crawlers live on it)
        float anvilCover = 0.0;

        // Every layer the ray meets, each into its own named variable (L0…L10, its depth t0…t10, in the order they were
        // listed when an insertion sort composited them): the dust wall, the funnel, the inflow bands, the wall cloud,
        // the hail shaft, the rain core, the base, the tower, the flanking line's nearest tower and the one behind it,
        // the anvil. (Kept in an array and sorted, they lived in scratch memory on Intel and AMD GPUs, which index an
        // array at run time there: Supercell Sky took 221 ms a frame on CI's Intel Mac against 13 on Apple silicon.)
        float groundT = dE.z < 0.0 ? -o.z / min(d.z, -1e-6) : 1e9;
        float t0 = 1e9, t1 = 1e9, t2 = 1e9, t3 = 1e9, t4 = 1e9, t5 = 1e9, t6 = 1e9, t7 = 1e9, t8 = 1e9, t9 = 1e9, t10 = 1e9;
        Layer none; none.a = 0.0; none.c = float3(0);
        Layer L1 = none, L2 = none, L3 = none, L4 = none, L5 = none, L6 = none, L7 = none, L8 = none, L9 = none, L10 = none;
        Layer L0 = none;
        if ((skip & 64u) == 0u) L0 = dustWall(o, d, u, octaves, t0);
        // Looking down at the field, only the dust wall can stand in the way (the clouds, the rain's feet at the storm's
        // distance, are all above a ray more than half a degree below the horizon).
        if (dE.z >= -0.01) {
            // The heaviest first, while few of the others are held (fewer registers live through their noise).
            if ((skip & 1u) == 0u) L7 = tower(o, d, flash, u, octaves, t7);
            if ((skip & 2u) == 0u) {
                FlankHits fh = flankHits(o, d, u);
                L8 = flankingLine(o, d, flash, u, octaves, fh, 0, t8);
                // The tower behind it, where the nearest lets light through (its frayed edge shows the next tower, not
                // the sky: on Smooth without it, the nearest one's outline cut the one behind with a hard curved edge).
                // Behind more than 99.6% cover it would add nothing (the walk front to back stops there): not read.
                if (L8.a <= 0.996 && fh.second < 1e8) L9 = flankingLine(o, d, flash, u, octaves, fh, 1, t9);
            }
            if ((skip & 4u) == 0u) L10 = anvil(o, d, flash, u, octaves, t10);
            anvilCover = L10.a;
            if ((skip & 8u) == 0u) L3 = wallCloud(o, d, flash, u, octaves, t3);
            if ((skip & 16u) == 0u) L6 = base(o, d, flash, u, octaves, t6);
            float rainLit = u.sunCol.w;
            float surge = u.gust.y;                                // the drop: the gust front's dust is up
            // The hail: a pale column lit softly by the low sun and the sky, greyed green by the core; brighter in the
            // drop.
            float3 hailLit = (u.sunCol.rgb * float3(1.0, 0.92, 0.8) * 0.3 + u.amb.rgb * 0.72) * (0.8 + 0.2 * rainLit);
            float hl = dot(hailLit, float3(0.2126, 0.7152, 0.0722));
            hailLit = mix(hailLit, hl * float3(0.84, 1.06, 1.0), saturate(u.look.y * 3.0)) * (1.0 + 0.3 * surge);
            hailLit += flash * 0.8;
            if ((skip & 32u) == 0u) L4 = column(o, d, u.shaft.xy, u.shaft.z, 0.05 + 0.25 * u.look.z + 0.1 * surge, hailLit, 1.0, u, t4);
            // The rain core: dark blue-grey, a little green.
            float3 coreLit = (u.amb.rgb * 0.13 + u.sunCol.rgb * 0.015) * float3(0.8, 0.94, 1.0) * (1.0 - 0.3 * surge);
            float lum = dot(coreLit, float3(0.2126, 0.7152, 0.0722));
            coreLit = mix(coreLit, lum * float3(0.75, 1.12, 0.98), saturate(u.look.y * 4.0));
            coreLit += flash * 0.5;
            if ((skip & 32u) == 0u) L5 = rainCurtain(o, d, ndc, coreLit, u, octaves, t5);
            if ((skip & 64u) == 0u) L2 = inflow(o, d, u, octaves, t2);
            if ((skip & 64u) == 0u) L1 = funnelCloud(o, d, u, t1);
        }
        // A layer counts where it covers the pixel nearer than the field (those the sort took in).
        keepLayer(L0, t0, groundT); keepLayer(L1, t1, groundT); keepLayer(L2, t2, groundT); keepLayer(L3, t3, groundT);
        keepLayer(L4, t4, groundT); keepLayer(L5, t5, groundT); keepLayer(L6, t6, groundT); keepLayer(L7, t7, groundT);
        keepLayer(L8, t8, groundT); keepLayer(L9, t9, groundT); keepLayer(L10, t10, groundT);
        cloudy = max(max(max(L3.a, L6.a), max(L7.a, L8.a)), max(L9.a, L10.a));   // (the cloud's, not the rain's)
        // Composited nearest first without sorting them: each layer's light comes through the layers in front of it (the
        // nearer, and at the same depth the one listed first, as the sort's order had it), all with fixed indices, so
        // they stay in registers. A layer behind 99.6% cover is left out, as the walk front to back stopped there.
        float k0 = 1.0 - L0.a, k1 = 1.0 - L1.a, k2 = 1.0 - L2.a, k3 = 1.0 - L3.a, k4 = 1.0 - L4.a, k5 = 1.0 - L5.a;
        float k6 = 1.0 - L6.a, k7 = 1.0 - L7.a, k8 = 1.0 - L8.a, k9 = 1.0 - L9.a, k10 = 1.0 - L10.a;
        float T0 = ahead(t1, k1, t0) * ahead(t2, k2, t0) * ahead(t3, k3, t0) * ahead(t4, k4, t0) * ahead(t5, k5, t0)
                 * ahead(t6, k6, t0) * ahead(t7, k7, t0) * ahead(t8, k8, t0) * ahead(t9, k9, t0) * ahead(t10, k10, t0);
        float T1 = aheadOrLevel(t0, k0, t1) * ahead(t2, k2, t1) * ahead(t3, k3, t1) * ahead(t4, k4, t1)
                 * ahead(t5, k5, t1) * ahead(t6, k6, t1) * ahead(t7, k7, t1) * ahead(t8, k8, t1) * ahead(t9, k9, t1)
                 * ahead(t10, k10, t1);
        float T2 = aheadOrLevel(t0, k0, t2) * aheadOrLevel(t1, k1, t2) * ahead(t3, k3, t2) * ahead(t4, k4, t2)
                 * ahead(t5, k5, t2) * ahead(t6, k6, t2) * ahead(t7, k7, t2) * ahead(t8, k8, t2) * ahead(t9, k9, t2)
                 * ahead(t10, k10, t2);
        float T3 = aheadOrLevel(t0, k0, t3) * aheadOrLevel(t1, k1, t3) * aheadOrLevel(t2, k2, t3) * ahead(t4, k4, t3)
                 * ahead(t5, k5, t3) * ahead(t6, k6, t3) * ahead(t7, k7, t3) * ahead(t8, k8, t3) * ahead(t9, k9, t3)
                 * ahead(t10, k10, t3);
        float T4 = aheadOrLevel(t0, k0, t4) * aheadOrLevel(t1, k1, t4) * aheadOrLevel(t2, k2, t4)
                 * aheadOrLevel(t3, k3, t4) * ahead(t5, k5, t4) * ahead(t6, k6, t4) * ahead(t7, k7, t4)
                 * ahead(t8, k8, t4) * ahead(t9, k9, t4) * ahead(t10, k10, t4);
        float T5 = aheadOrLevel(t0, k0, t5) * aheadOrLevel(t1, k1, t5) * aheadOrLevel(t2, k2, t5)
                 * aheadOrLevel(t3, k3, t5) * aheadOrLevel(t4, k4, t5) * ahead(t6, k6, t5) * ahead(t7, k7, t5)
                 * ahead(t8, k8, t5) * ahead(t9, k9, t5) * ahead(t10, k10, t5);
        float T6 = aheadOrLevel(t0, k0, t6) * aheadOrLevel(t1, k1, t6) * aheadOrLevel(t2, k2, t6)
                 * aheadOrLevel(t3, k3, t6) * aheadOrLevel(t4, k4, t6) * aheadOrLevel(t5, k5, t6) * ahead(t7, k7, t6)
                 * ahead(t8, k8, t6) * ahead(t9, k9, t6) * ahead(t10, k10, t6);
        float T7 = aheadOrLevel(t0, k0, t7) * aheadOrLevel(t1, k1, t7) * aheadOrLevel(t2, k2, t7)
                 * aheadOrLevel(t3, k3, t7) * aheadOrLevel(t4, k4, t7) * aheadOrLevel(t5, k5, t7)
                 * aheadOrLevel(t6, k6, t7) * ahead(t8, k8, t7) * ahead(t9, k9, t7) * ahead(t10, k10, t7);
        float T8 = aheadOrLevel(t0, k0, t8) * aheadOrLevel(t1, k1, t8) * aheadOrLevel(t2, k2, t8)
                 * aheadOrLevel(t3, k3, t8) * aheadOrLevel(t4, k4, t8) * aheadOrLevel(t5, k5, t8)
                 * aheadOrLevel(t6, k6, t8) * aheadOrLevel(t7, k7, t8) * ahead(t9, k9, t8) * ahead(t10, k10, t8);
        float T9 = aheadOrLevel(t0, k0, t9) * aheadOrLevel(t1, k1, t9) * aheadOrLevel(t2, k2, t9)
                 * aheadOrLevel(t3, k3, t9) * aheadOrLevel(t4, k4, t9) * aheadOrLevel(t5, k5, t9)
                 * aheadOrLevel(t6, k6, t9) * aheadOrLevel(t7, k7, t9) * aheadOrLevel(t8, k8, t9)
                 * ahead(t10, k10, t9);
        float T10 = aheadOrLevel(t0, k0, t10) * aheadOrLevel(t1, k1, t10) * aheadOrLevel(t2, k2, t10)
                  * aheadOrLevel(t3, k3, t10) * aheadOrLevel(t4, k4, t10) * aheadOrLevel(t5, k5, t10)
                  * aheadOrLevel(t6, k6, t10) * aheadOrLevel(t7, k7, t10) * aheadOrLevel(t8, k8, t10)
                  * aheadOrLevel(t9, k9, t10);
        float T = 1.0;           // what the layers taken in let through to what lies behind them all
        col += layerLight(L0, T0, T); col += layerLight(L1, T1, T); col += layerLight(L2, T2, T);
        col += layerLight(L3, T3, T); col += layerLight(L4, T4, T); col += layerLight(L5, T5, T);
        col += layerLight(L6, T6, T); col += layerLight(L7, T7, T); col += layerLight(L8, T8, T);
        col += layerLight(L9, T9, T); col += layerLight(L10, T10, T);
        CloudSum cs;
        cs.col = col; cs.T = T; cs.cloudy = cloudy; cs.anvilCover = anvilCover;
        return cs;
    }

    /// Everything behind and over the storm's layers: the sky or the field (through what the layers let through), the
    /// light after the storm, the lightning.
    ColorDepth cellFinish(float2 ndc, float3 dE, float3 d, float3 o, float3 flash, CloudSum cs, constant SkyU& sky,
                          constant CellU& u, int octaves, uint skip, texture2d<float> stars) {
        float3 col = cs.col;
        float T = cs.T, cloudy = cs.cloudy, anvilCover = cs.anvilCover;
        float depth = dE.z >= 0.0 ? 1.0 : 0.6;
        // Behind cloud that lets no light through at all (T exactly 0, under the storm's dark body) the sky and the
        // field add nothing, so they are not drawn there.
        if (T > 0.0) {
            float3 back = float3(0.1);
            if (dE.z >= 0.0) {
                float moonMask = 0.0;
                if ((skip & 128u) == 0u) back = skyRadiance(dE, sky, moonMask, stars);
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
                if ((skip & 256u) == 0u) back = field(o, d, flash, u, octaves);
                if ((skip & 8192u) == 0u) {
                    float4 w = wheat(o, d, u);
                    back = mix(back, w.rgb, w.a);
                }
            }
            if (dE.z > -0.01 && (skip & 512u) == 0u) {
                float4 h = horizonThings(d, u);
                back = mix(back, h.rgb, h.a);
            }
            col += T * back;
        }

        // The light after the storm: rays converging on the sun's antipoint through the clear air, and the double rainbow
        // standing in the rain.
        float3 anti = -sky.sun.xyz;
        if (u.after.x > 0.0 && dE.z > -0.02 && (skip & 512u) == 0u) {
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
            // The sun's disc (half a degree) blurs the bands into each other, as a real bow's colours run together.
            float3 bow = 0.25 * rainbowBow(angle - 0.35) + 0.5 * rainbowBow(angle) + 0.25 * rainbowBow(angle + 0.35);
            bow = mix(bow, float3(dot(bow, float3(0.2126, 0.7152, 0.0722))), 0.2);
            float darkBand = angle > 42.5 && angle < 50.5 ? 0.9 : 1.0;
            float strength = u.after.y * (1.0 - anvilCover);
            col = col * mix(1.0, darkBand, strength) + bow * (0.4 * strength) * (0.6 + u.sunCol.rgb * 0.3);
        }
        // Lightning: the strikes (blue-white, through the limiter) and the crawlers on the cloud.
        if ((skip & 1024u) == 0u) {
            col += strikes(ndc, u);
            col += crawlers(ndc, u, max(cloudy, 0.3));
        }
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    fragment ColorDepth cell_scene_fragment(CellOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                            constant CellU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc - u.cam.xy;
        int octaves = int(u.a.z + 0.5);
        float3 dE, d, o;
        cellRay(ndc, sky, u, dE, d, o);
        // Lightning's light on the cloud here, read once for every layer.
        float3 flash = flashOnCloud(ndc, u);
        // (The timing test's mask: a set bit skips a layer, so one run can price each. Always 0 in the app.)
        uint skip = uint(u.crawlInfo[0].w + 0.5);
        CloudSum cs = stormClouds(ndc, dE, d, o, flash, u, octaves, skip);
        return cellFinish(ndc, dE, d, o, flash, cs, sky, u, octaves, skip, stars);
    }

    // ---------------------------------------------------------------- the storm at a reduced resolution
    // The storm's layers (soft cloud, rain and dust, a few hundred metres to kilometres across) are drawn into two
    // reduced-resolution targets (half the view's size on Smooth, 0.7 of it on High), and the scene pass reads them back
    // (filtered) under the sky, the field and the wheat and the lightning, which it draws at full resolution: a quarter
    // of the storm's noise a frame on Smooth, half on High.
    struct CloudTargets { float4 light [[color(0)]]; float4 cover [[color(1)]]; };

    fragment CloudTargets cell_cloud_fragment(CellOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                              constant CellU& u [[buffer(1)]]) {
        float2 ndc = in.ndc - u.cam.xy;
        int octaves = int(u.a.z + 0.5);
        float3 dE, d, o;
        cellRay(ndc, sky, u, dE, d, o);
        float3 flash = flashOnCloud(ndc, u);
        uint skip = uint(u.crawlInfo[0].w + 0.5);
        CloudSum cs = stormClouds(ndc, dE, d, o, flash, u, octaves, skip);
        CloudTargets out;
        out.light = float4(cs.col, cs.T);
        out.cover = float4(cs.cloudy, cs.anvilCover, 0.0, 1.0);
        return out;
    }

    fragment ColorDepth cell_compose_fragment(CellOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                              constant CellU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]],
                                              texture2d<float> light [[texture(1)]], texture2d<float> cover [[texture(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 ndc = in.ndc - u.cam.xy;
        int octaves = int(u.a.z + 0.5);
        float3 dE, d, o;
        cellRay(ndc, sky, u, dE, d, o);
        float3 flash = flashOnCloud(ndc, u);
        uint skip = uint(u.crawlInfo[0].w + 0.5);
        float2 uv = float2(0.5 + 0.5 * in.ndc.x, 0.5 - 0.5 * in.ndc.y);
        float4 L = light.sample(s, uv);
        float2 C = cover.sample(s, uv).xy;
        CloudSum cs;
        cs.col = L.rgb; cs.T = L.a; cs.cloudy = C.x; cs.anvilCover = C.y;
        return cellFinish(ndc, dE, d, o, flash, cs, sky, u, octaves, skip, stars);
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
    struct PostOut { float4 pos [[position]]; float2 uv; float4 info; float seed; };
    vertex PostOut cell_post_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant PostInstance* posts [[buffer(0)]],
                                    constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        PostInstance k = posts[iid];
        PostOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv) + view.yz, 0, 1);
        o.info = k.info;
        o.seed = hash12(float2(k.rect.x * 517.0, 3.7));         // each post its own
        return o;
    }
    fragment ColorDepth cell_post_fragment(PostOut in [[stage_in]], constant float4& warm [[buffer(0)]]) {
        bool picket = in.info.x > 0.5;
        float glow = in.info.y, light = in.info.w;
        float x = in.uv.x, y = in.uv.y;
        float s1 = in.seed, s2 = fract(s1 * 7.31), s3 = fract(s1 * 13.17), s4 = fract(s1 * 3.77);
        // A weathered timber post (a steel star picket for a black key): narrow, each a little different in width,
        // lean and height, its top sawn off on a slant; two strands of wire.
        float halfW = picket ? 0.07 + 0.02 * s2 : 0.12 + 0.05 * s2;
        float cx = 0.5 + (s4 - 0.5) * 0.12 + (s3 - 0.5) * 0.08 * y;
        float across = (x - cx) / halfW;                         // −1 … 1 across the post
        float aa = 0.05 / halfW;
        float body = smoothstep(1.0 + aa, 1.0 - aa, abs(across));
        float top = (picket ? 0.8 + 0.04 * s3 : 0.9 + 0.08 * s3) - 0.03 * across * (s4 > 0.5 ? 1.0 : -1.0);
        body *= smoothstep(top + 0.008, top - 0.008, y);
        float wire = 0.0;
        for (int i = 0; i < 2; i++) {
            float wy = 0.42 + 0.3 * float(i);
            wire = max(wire, smoothstep(0.022, 0.0, abs(y - wy)));
        }
        // A note's light spills into the air round its post.
        float halo = glow * exp(-sq(x - cx) / 0.035) * (0.3 + 0.7 * y);
        float a = max(max(body, 0.6 * wire), 0.25 * halo);
        if (a < 0.004) discard_fragment();
        float3 c;
        if (picket) {
            float ridge = exp(-across * across * 8.0);
            c = float3(0.12, 0.12, 0.13) * (0.7 + 0.7 * ridge) * warm.rgb * light;
        } else {
            // Grey, sun-bleached timber: grain running up it, dark checks along it, now and then a knot.
            float grain = vn2(float2(across * 6.0 + s1 * 20.0, y * 4.0 + s2 * 9.0));
            float fine = vn2(float2(across * 9.0 + s3 * 40.0, y * 1.2 + s1 * 5.0));
            float check = 1.0 - smoothstep(0.015, 0.05, abs(fine - 0.5));
            float3 wood = mix(float3(0.3, 0.25, 0.19), float3(0.47, 0.42, 0.36), 0.3 + 0.45 * s2) * (0.8 + 0.35 * grain);
            wood *= 1.0 - 0.5 * check;
            float knot = smoothstep(0.07, 0.03, length(float2(across * halfW * 2.5, (y - 0.3 - 0.4 * s4) * 0.7)));
            wood *= 1.0 - 0.55 * knot * step(0.55, s3);
            // The low sun from behind and to the right lights its right face; the left is in its own shade.
            c = wood * warm.rgb * light * (0.5 + 0.65 * smoothstep(-0.5, 0.9, across));
        }
        c = mix(c, float3(0.2, 0.2, 0.21) * warm.rgb * light, wire * (1.0 - body));
        // Lit by its note: warm, like lamplight in the timber, hottest at the top; the wire catches it too.
        float3 lamp = float3(1.0, 0.52, 0.2);
        float hot = smoothstep(0.3, 1.0, y);
        float3 lit = lamp * (0.22 + 1.25 * hot * hot) * (0.85 + 0.3 * (c.r + c.g)) + c * 0.35;
        c = mix(c, lit, saturate(glow * 1.4) * body);
        c += lamp * (glow * 0.4) * wire * (1.0 - body);
        float3 pre = c * max(body, 0.6 * wire * (1.0 - body)) + lamp * (0.7 * halo * (0.4 + 0.6 * hot)) * (1.0 - body);
        ColorDepth o;
        o.color = float4(pre, a);
        o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
