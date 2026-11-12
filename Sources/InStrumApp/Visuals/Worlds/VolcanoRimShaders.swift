/// Metal source for Volcano Rim (Fire & Neon spec §8, §12): one full-screen pass draws the sky, the crater, the lava lake,
/// its fountains, the eruption's column, the plume and the fume; the embers, blobs and bombs, the plume's lightning and
/// the basalt columns (the keys) are instanced over it.
///
/// The crater is analytic, in metres round the lake's centre (x across the view, y ahead, z up), each surface hit in
/// closed form (never marched): the lake and the floor (a plane), the cliffs (two cylinders round the wall centre, their
/// top edges ragged, cut by the breach's notch), the bench between them. The lake's crust is a Voronoi of the model's 64
/// seeds looked up through a two-scale domain warp, so the cracks run ragged; each crack's light is a blackbody core and
/// a cooler halo, filtered by the pixel's footprint across it (so a crack too thin to see averages to its light instead
/// of stair-stepping). Temperature runs from 600 K (old crust, black) to 1450 K (a fountain's heart): `blackbody` gives
/// its chroma (fitted to the CIE blackbody locus under D65) and a film-like compressed intensity, so the post's bloom
/// and per-channel tone curve take the hottest light through orange to yellow-white as a long exposure does. The walls
/// are lit by the lake below them (a disc light) and the plume above; the plume is a lit volume on a plane through the
/// lake's centre, its billows bright underneath; the fume over the lake is an analytic glowing haze. Smooth rules: no ray
/// marching, at most 3 octaves (2 on Smooth), no pow.
enum VolcanoRimShaders {
    static let source = SkyShaders.common + """
    struct VolcanoU {
        float4 a;        // aspect, time (s, wrapped), octaves, pixel angle (rad)
        float4 cam;      // shake (NDC xy), keys top (NDC), a pixel (NDC y)
        float4 axes;     // the view's forward (ENU xy), its right (ENU xy)
        float4 eye;      // eye (crater metres xyz), the lake's level (m: tension swells it)
        float4 lake;     // lake radius (m), the crust's clock (m drifted), crack width scale, activity
        float4 glow;     // the lake's light on the crater (rgb, HDR), the margin's heat 0…1
        float4 play;     // energy, tension, drop, the cracks' beat now
        float4 temps;    // crack temperature (K), young crust (K), old crust (K), fine-crack density
        float4 plume;    // amount 0…1, billow 0…1, bend (m per m² of height), rise (m, the billows' clock)
        float4 river;    // flow 0…1, its crust's travel (m), breach 0…1, breach age (s; < 0 none)
        float4 skyL;     // the night sky's light on the rocks (rgb), night 0…1
        float4 fountA;   // fountain: place (lake m xy), height (m), burst 0…1
        float4 fountB;
        float4 erupt;    // column height (m), its light 0…1 (limited), age (s; < 0 none), strength
        float4 bolt;     // lightning's light in the plume 0…1 (limited), its place (plume m x, z), gentle 0/1
        float4 fireball; // progress 0…1 (< 0 none), start bearing (deg from the view), start altitude (deg), light
        float4 rockfall; // progress (< 0 none), angle round the wall centre (rad), seed, 0
        float4 steam;    // progress (< 0 none), angle round the wall centre (rad), seed, 0
        float4 sprites;  // light 0…1 (< 0 none), bearing (deg from the view), seed, far storm 0…1
        float4 tree;     // progress (< 0 none), share along the river, seed, 0
        float4 dims;     // foot radius, bench height, bench radius, top radius (m)
        float4 dims2;    // wall centre (m xy), rim height (m), breach angle (rad)
        float4 dims3;    // breach halfW-width (rad), fountain pool scale, foreground top (NDC), keys shown 0/1
        float4 riverA;   // river start (m xy), river end (m xy)
        float4 cellA[64];  // crust seeds: place (m xy), a note's glow, young heat
        float4 cellB[64];  // birth 0…1, the twin it split from (index; −1 none), 0, 0
    };
    struct VolOut { float4 pos [[position]]; float2 ndc; };

    vertex VolOut volcano_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VolOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- noise
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
    float sq(float x) { return x * x; }
    float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    // ---------------------------------------------------------------- light
    /// Incandescence at a temperature (kelvin): the blackbody's chroma (G/R and B/R of the CIE locus under D65 over
    /// 1000–3000 K, as display ratios: the finishing pass writes its tone curve straight to the screen, so the ratios
    /// are the sRGB-encoded ones), times an intensity that rises e-fold every 115 K from 1 at 1150 K, a long exposure's
    /// compression of Planck's far steeper climb: old crust (600 K) is all but black, cracks (1100–1300 K) orange, a
    /// fountain's heart (1450 K) bright enough that the per-channel tone curve takes it to yellow-white.
    float3 blackbody(float T) {
        float t = clamp(T, 450.0, 2200.0);
        float inv = 1.0 / t;
        float g = exp(0.38 - 1848.0 * inv);
        float b = exp(2.036 - 8727.0 * inv);
        return float3(1.0, g, b) * exp((t - 1150.0) * 0.0086957);
    }

    /// A line source's light filtered by the pixel's footprint across it: an exponential profile of width `w` (m) at
    /// distance `d` (m), widened by the footprint `f` (m) with its total kept, so a thin crack averages to its light.
    float lineLight(float d, float w, float f) {
        float we = sqrt(w * w + 0.5 * f * f);
        return (w / we) * exp(-max(d, 0.0) / we);
    }

    /// The lake's light falling on a point with normal N (crater metres): the lake as a disc light below (irradiance
    /// falling off as R² / (R² + d²), from its glowing middle), its bright margin near by, and the plume's glow from above.
    float3 craterLight(float3 P, float3 N, constant VolcanoU& u) {
        float R = u.lake.x;
        float lakeZ = u.eye.w;
        float h = max(P.z - lakeZ, 0.0);
        // The lake below: from its middle, falling off with distance, brightest low on the walls (the margin's spatter
        // and the fume glow there), the face turned to it lit most.
        float3 toLake = float3(-P.xy * 0.7, lakeZ + 25.0 - P.z);
        float dl = length(toLake);
        float3 L = toLake / max(dl, 1e-3);
        float disc = R * R / (R * R + dl * dl);
        float facing = saturate(0.2 + 0.8 * dot(N, L));
        float low = 0.3 + 0.7 * exp(-h / 70.0);
        float3 lake = u.glow.rgb * (14.0 * disc * low * facing);
        // The margin: a ring of spatter at the lake's edge, lighting what stands near it.
        float rp = length(P.xy);
        float toRing = max(abs(rp - R), 0.0);
        float ring = u.glow.w * 3.0 / (1.0 + sq(toRing / 45.0) + sq(h / 50.0));
        float3 margin = u.glow.rgb * ring * saturate(0.3 + 0.7 * dot(N, normalize(float3(-P.xy, 6.0))));
        // The plume over the lake's middle, lit from below: an orange light from above and ahead.
        float3 toPlume = float3(-P.x + 30.0, -P.y, lakeZ + 150.0 - P.z);
        float dp = length(toPlume);
        float3 Lp = toPlume / max(dp, 1e-3);
        float3 plume = u.glow.rgb * float3(1.0, 0.82, 0.7) * (2.2 * u.plume.x * 200.0 * 200.0 / (200.0 * 200.0 + dp * dp))
                     * saturate(0.2 + 0.8 * dot(N, Lp));
        return lake + margin + plume;
    }

    // ---------------------------------------------------------------- the crater's shape
    struct Hit { int kind; float t; float3 p; float theta; };   // kind: 0 beyond, 1 lake, 2 floor, 3 cliff, 4 bench

    /// The far side of a vertical cylinder of radius R round C, seen from inside it (or 1e9).
    float cylinderFar(float3 o, float3 d, float2 C, float R) {
        float2 q = o.xy - C;
        float a = max(dot(d.xy, d.xy), 1e-8);
        float b = dot(q, d.xy);
        float c = dot(q, q) - R * R;
        float disc = b * b - a * c;
        if (disc < 0.0) return 1e9;
        float t = (-b + sqrt(disc)) / a;
        return t > 0.0 ? t : 1e9;
    }

    /// How high the cliffs stand at an angle round the wall centre: the breach's notch cuts them to the floor, its sides
    /// sloping and broken (a gap torn in the wall, never a sawn slot).
    float notchCut(float theta, constant VolcanoU& u) {
        float hw = u.dims3.x;
        float off = abs(theta - u.dims2.w) + hw * 0.35 * (vn2(float2(theta * 120.0, 2.0)) - 0.5);
        return smoothstep(hw * 0.45, hw * 1.4, off);
    }

    /// The cliffs' ragged top edges (m above their nominal tops): boulders and spatter on the lip.
    float lipRag(float theta, float scale) {
        float a = theta * 57.0;
        return (vn2(float2(a * 0.09, scale + 11.0)) - 0.5) * 34.0 + (vn2(float2(a * 0.3, scale + 5.0)) - 0.5) * 12.0
             + (vn2(float2(a, scale)) - 0.5) * 6.0 + (vn2(float2(a * 4.3, scale + 3.0)) - 0.5) * 2.4
             + smoothstep(0.6, 0.9, vn2(float2(a * 0.37, scale + 7.0))) * 9.0;
    }

    /// The lake's edge (its radius, m) toward a point: a ragged shore of old spatter, never a drawn ellipse.
    float lakeEdge(float2 p, constant VolcanoU& u) {
        float R = u.lake.x;
        float arc = atan2(p.y, p.x) * R;
        return R + 9.0 * (vn2(float2(arc * 0.018, 1.3)) - 0.5) + 4.0 * (vn2(float2(arc * 0.07, 4.1)) - 0.5);
    }

    Hit craterHit(float3 o, float3 d, constant VolcanoU& u) {
        Hit h;
        h.kind = 0; h.t = 1e9; h.p = o + d * 1e4; h.theta = 0.0;
        float2 C = u.dims2.xy;
        float rimH = u.dims2.z;
        float lakeZ = u.eye.w;
        // The floor and the lake.
        if (d.z < -1e-5) {
            float t = (lakeZ - o.z) / d.z;
            float3 p = o + d * t;
            float r = length(p.xy - C);
            float2 qf = p.xy - C;
            bool inNotch = r < 0.5 * (u.dims.z + u.dims.w) + 4.0 && notchCut(atan2(qf.x, qf.y), u) < 0.999;
            if (r < u.dims.x || inNotch) {
                h.kind = length(p.xy) < lakeEdge(p.xy, u) ? 1 : 2;
                h.t = t; h.p = p;
            }
        }
        // The cliff above the floor (its top ragged, cut by the notch).
        float tA = cylinderFar(o, d, C, u.dims.x);
        if (tA < h.t) {
            float3 p = o + d * tA;
            float2 q = p.xy - C;
            float th = atan2(q.x, q.y);
            float top = (u.dims.y + lipRag(th, 1.0)) * notchCut(th, u);
            if (p.z >= lakeZ - 0.5 && p.z <= top) { h.kind = 3; h.t = tA; h.p = p; h.theta = th; }
        }
        // The bench.
        if (d.z < -1e-5) {
            float t = (u.dims.y - o.z) / d.z;
            if (t < h.t && t > 0.0) {
                float3 p = o + d * t;
                float2 q = p.xy - C;
                float r = length(q);
                float th = atan2(q.x, q.y);
                if (r >= u.dims.x && r < u.dims.z && notchCut(th, u) > 0.5) { h.kind = 4; h.t = t; h.p = p; h.theta = th; }
            }
        }
        // The upper cliff to the rim.
        float rB = 0.5 * (u.dims.z + u.dims.w);
        float tB = cylinderFar(o, d, C, rB);
        if (tB < h.t) {
            float3 p = o + d * tB;
            float2 q = p.xy - C;
            float th = atan2(q.x, q.y);
            float topFull = rimH + lipRag(th, 5.0);
            float cut = notchCut(th, u);
            float top = mix(lakeZ - 1.0, topFull, cut);
            if (p.z >= u.dims.y - 2.0 && p.z <= top) { h.kind = 3; h.t = tB; h.p = p; h.theta = th; }
            else if (h.kind == 0 && p.z < u.dims.y - 2.0 && p.z > lakeZ - 1.0) { h.kind = 3; h.t = tB; h.p = p; h.theta = th; }
            else if (h.kind == 0 && cut < 0.999 && p.z < topFull) { h.kind = 5; h.t = tB; h.p = p; h.theta = th; }
        }
        return h;
    }

    // ---------------------------------------------------------------- the lava lake
    /// The crust's Voronoi through a two-scale warp: the nearest seed `i1`, the neighbour across the nearest crack `i2`,
    /// the distance to it (m) and the crack's normal (in the lake's plane).
    struct Plates { int i1; int i2; int i3; float border; float border2; float2 n; float2 n2; float2 q; };

    Plates plates(float2 p, constant VolcanoU& u) {
        float2 q0 = p * 0.042;
        float2 w1 = float2(vn2(q0 + float2(3.1, 7.7)), vn2(q0 + float2(11.3, 1.9))) - 0.5;
        float2 q1 = p * 0.17;
        float2 w2 = float2(vn2(q1 + float2(5.2, 3.3)), vn2(q1 + float2(9.4, 6.1))) - 0.5;
        float2 q = p + w1 * 17.0 + w2 * 3.6;
        Plates r;
        r.q = q;
        int i1 = 0;
        float best = 1e12;
        for (int k = 0; k < 64; k++) {
            float2 c = u.cellA[k].xy - q;
            float dd = dot(c, c);
            if (dd < best) { best = dd; i1 = k; }
        }
        float2 c1 = u.cellA[i1].xy;
        float d1 = sqrt(best);
        float border = 1e9, border2 = 1e9;
        int i2 = i1, i3 = i1;
        float2 nrm = float2(1, 0), nrm2 = float2(0, 1);
        for (int k = 0; k < 64; k++) {
            if (k == i1) continue;
            float2 c = u.cellA[k].xy;
            // A seed this far off is at least (D − d1)/2 from its crack: past the second nearest, skip it.
            float2 cq = c - q;
            float D = sqrt(dot(cq, cq));
            if (0.5 * (D - d1) > border2) continue;
            float2 n = c - c1;
            float ln = length(n);
            if (ln < 1e-3) continue;
            n /= ln;
            float dist = dot(0.5 * (c1 + c) - q, n);
            if (dist < border) {
                border2 = border; i3 = i2; nrm2 = nrm;
                border = dist; i2 = k; nrm = n;
            } else if (dist < border2) {
                border2 = dist; i3 = k; nrm2 = n;
            }
        }
        r.i1 = i1; r.i2 = i2; r.i3 = i3; r.border = max(border, 0.0); r.border2 = max(border2, 0.0); r.n = nrm; r.n2 = nrm2;
        return r;
    }

    /// The fine cracks inside a plate: a smaller cellular net fixed to the plate (so it rides with it), the distance to
    /// its nearest crack (m).
    float fineCracks(float2 local, float scale) {
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

    /// The lake's own light at a point of its surface (crater metres), seen along d; J is the pixel's footprint (lake
    /// metres per pixel across x and y).
    float3 lakeSurface(float3 P, float3 d, float2 Jx, float2 Jy, constant VolcanoU& u, int oct) {
        float2 p = P.xy;
        float energy = u.play.x;
        Plates pl = plates(p, u);
        float4 A = u.cellA[pl.i1];
        float4 Ab = u.cellB[pl.i1];
        float foot = max(length(Jx), length(Jy));
        float note = A.z;
        // Each of the two nearest cracks, its own character (so a junction never steps): most run thin and dull, a few
        // wide and white-hot (spreading), each wandering in width and heat along its length; the brighter one shows.
        float heatA = A.w;
        float3 crack = float3(0);
        for (int c = 0; c < 2; c++) {
            int j = c == 0 ? pl.i2 : pl.i3;
            float bd = c == 0 ? pl.border : pl.border2;
            float2 nn = c == 0 ? pl.n : pl.n2;
            float4 Bj = u.cellA[j];
            float4 Bjb = u.cellB[j];
            float fnj = length(float2(dot(Jx, nn), dot(Jy, nn)));
            float lo = float(min(pl.i1, j)), hi = float(max(pl.i1, j));
            float pair = hash12(float2(lo * 7.13, hi * 3.71));
            float wide = smoothstep(0.72, 0.95, pair);
            float heat = 0.5 * (heatA + Bj.w);
            float note = max(A.z, Bj.z);
            float along = vn2(pl.q * 0.07 + pair * 31.0);
            float along2 = vn2(pl.q * 0.31 + pair * 7.0);
            float width = u.lake.z * (0.18 + 0.35 * pair + 1.1 * wide) * (0.6 + 0.8 * heat) * (0.3 + 1.4 * along * along2);
            // A crack between two plates just split apart opens as they part.
            bool twins = int(Ab.y) == j || int(Bjb.y) == pl.i1;
            float open = twins ? smoothstep(0.0, 1.0, min(Ab.x, Bjb.x)) : 1.0;
            float T = u.temps.x + 60.0 * pair + 150.0 * wide + 110.0 * heat + 120.0 * energy + 250.0 * note
                    + 90.0 * u.play.w + 80.0 * (along - 0.5);
            float3 cj = blackbody(T) * lineLight(bd, width, fnj) + blackbody(T - 200.0) * (0.45 * lineLight(bd, width * 4.0 + 0.8, fnj));
            crack = max(crack, cj * open);
        }
        // The crust: old plates black, young ones (near the spreading centre) a dull red, thinner (glowing) toward the
        // cracks; the fine cracks of the plate's skin, livelier with Energy.
        float2 local = p - A.xy + float2(hash12(float2(float(pl.i1), 1.7)) * 97.0, hash12(float2(float(pl.i1), 4.1)) * 61.0);
        float skin = fbm2(local * 0.11, oct);
        float Tc = mix(u.temps.z, u.temps.y, A.w) + 90.0 * (skin - 0.5) + 50.0 * energy;
        Tc += 140.0 * exp(-pl.border / (1.2 + 2.5 * A.w));
        float3 crust = blackbody(Tc);
        if (oct >= 3) {
            float fine = fineCracks(local, 6.0 + 6.0 * (1.0 - A.w));
            float fineT = Tc + 200.0 + 110.0 * u.temps.w + 80.0 * note;
            crust += blackbody(fineT) * (0.5 * lineLight(fine, 0.12 + 0.1 * A.w, foot)) * (0.25 + 0.75 * u.temps.w);
        }
        // Sheen: the glassy crust mirrors the plume's glow above, more at grazing angles, less where it's rough.
        float grazing = 1.0 - saturate(-d.z);
        float g2 = grazing * grazing;
        float fres = 0.045 + 0.955 * g2 * g2 * grazing;
        float rough = smoothstep(0.35, 0.75, fbm2(local * 0.35 + float2(2.0, 9.0), oct));
        float sheen = fres * (0.5 - 0.42 * rough) * smoothstep(-80.0, 150.0, p.y);
        float3 col = crust + crack + u.glow.rgb * float3(1.0, 0.9, 0.8) * (0.3 * sheen * u.plume.x);
        // The fountains' pools of fresh lava, churning, spreading their heat into the crust round them.
        for (int k = 0; k < 2; k++) {
            float4 f = k == 0 ? u.fountA : u.fountB;
            float rp = (7.0 + 0.35 * f.z) * u.dims3.y;
            float dist = length(p - f.xy) + 5.0 * (vn2(p * 0.12 + u.a.y * 0.3) - 0.5);
            float pool = 1.0 - smoothstep(rp * 0.45, rp * 1.1, dist);
            float churn = vn2(p * 0.35 + float2(u.a.y * 0.9, -u.a.y * 0.6));
            float skinOver = smoothstep(0.55, 0.8, vn2(p * 0.22 - u.a.y * 0.15)) * (1.0 - f.w);
            float Tp = 1220.0 + 140.0 * f.w + 80.0 * churn + 50.0 * energy - 160.0 * skinOver;
            col = mix(col, blackbody(Tp), pool);
            col += blackbody(1150.0) * (0.25 * exp(-max(dist - rp, 0.0) / 9.0));
        }
        // The margin: torn crust and spatter where the lake meets its shore, bright in patches, dark in others.
        float r = length(p);
        float edgeR = lakeEdge(p, u);
        float toEdge = edgeR - r;
        float arc = atan2(p.y, p.x) * u.lake.x;
        float spot = smoothstep(0.35, 0.8, vn2(float2(arc * 0.025, 2.0)) * 0.7 + vn2(float2(arc * 0.1, u.a.y * 0.2)) * 0.45);
        float wm = 0.8 + 2.8 * spot;
        float Tm = 1060.0 + 190.0 * spot + 90.0 * u.glow.w;
        col += blackbody(Tm) * lineLight(abs(toEdge - 0.8), wm, foot) * (0.25 + 0.75 * spot);
        // The breach's new river leaves the lake here: the lake's own crust torn open toward it.
        float toMouth = length(p - u.riverA.xy);
        col += blackbody(1260.0 + 80.0 * u.river.z) * (u.river.z * exp(-toMouth / 22.0) * 0.8);
        return col;
    }

    // ---------------------------------------------------------------- the floor, the river and the walls
    /// The distance from p to the river's bed (a gentle bend from the lake's mouth to the notch) and the share along it.
    float2 riverDistance(float2 p, constant VolcanoU& u) {
        float2 a = u.riverA.xy, b = u.riverA.zw;
        float2 ab = b - a;
        float len2 = max(dot(ab, ab), 1e-3);
        float s = clamp(dot(p - a, ab) / len2, 0.0, 1.0);
        float2 side = float2(-ab.y, ab.x) / sqrt(len2);
        float2 c = a + ab * s + side * (sin(s * 3.14159) * 14.0 + sin(s * 9.0) * 3.0);
        return float2(length(p - c), s);
    }

    float3 floorColour(float3 P, float3 d, float foot, constant VolcanoU& u, int oct) {
        float2 p = P.xy;
        // Old black lava: ropy and blocky, a little glassy, here and there a skylight onto hot lava beneath.
        float rope = fbm2(p * float2(0.035, 0.022) + float2(3.0, 1.0), oct);
        float block = vn2(p * 0.07);
        float3 albedo = float3(0.04, 0.036, 0.034) * (0.55 + 0.5 * rope + 0.2 * block);
        float3 N = normalize(float3((rope - 0.5) * 0.5, (block - 0.5) * 0.5, 1.0));
        float3 col = albedo * (craterLight(P, N, u) + u.skyL.rgb);
        float sky = smoothstep(0.86, 0.93, vn2(p * 0.03 + float2(7.0, 2.0))) * smoothstep(0.5, 0.8, vn2(p * 0.12));
        col += blackbody(980.0 + 120.0 * u.play.x) * (0.25 * sky);
        // The river: a channel of crusted lava (bright where its crust tears) running to the breach, its levees lit.
        float2 rd = riverDistance(p, u);
        float flow = u.river.x, breach = u.river.z;
        float halfW = (4.0 + 4.0 * flow + 16.0 * breach) * (0.7 + 0.6 * vn2(float2(rd.y * 9.0, 3.0)) + 0.25 * (vn2(p * 0.15) - 0.5));
        float inside = 1.0 - smoothstep(halfW - max(1.0, foot), halfW + max(1.0, foot), rd.x);
        if (inside > 0.0) {
            float along = rd.y * 120.0 - u.river.y * 0.6;
            float2 rp = float2(along, rd.x * 0.35);
            float crustNet = oct >= 3 ? fineCracks(rp + float2(13.0, 5.0), 3.0) : 3.0 * abs(vn2(rp * 0.5) - 0.5);
            float run = vn2(float2(along * 0.4, rd.x * 0.2));
            float Tr = 720.0 + 230.0 * flow + 560.0 * breach + 80.0 * run;
            float3 river = blackbody(Tr) + blackbody(1120.0 + 70.0 * flow + 220.0 * breach) * lineLight(crustNet, 0.3, foot) * 0.8;
            river += blackbody(1150.0 + 80.0 * breach) * (exp(-abs(rd.x - halfW * 0.85) / 1.2) * (0.25 + 0.75 * flow));
            col = mix(col, river, inside);
        }
        col += blackbody(1080.0 + 150.0 * breach) * (exp(-max(rd.x - halfW, 0.0) / 10.0) * (0.08 + 0.15 * flow + 0.7 * breach) * 0.3);
        // The lake's shore: a low levee of spatter, dark, its lake side lit.
        float shore = length(p) - lakeEdge(p, u);
        col += blackbody(1100.0) * (0.35 * exp(-max(shore, 0.0) / 3.5));
        return col;
    }

    float3 wallColour(Hit h, float3 d, constant VolcanoU& u, int oct, float foot) {
        float3 P = h.p;
        float2 C = u.dims2.xy;
        float2 q = P.xy - C;
        float r = length(q);
        float th = h.theta;
        float z = P.z - u.eye.w;
        float arc = th * r;   // metres round the wall
        // Layered basalt: flows stacked in irregular bands (some oxidised red-brown), cut by gullies and buttresses;
        // a talus of rubble at each cliff's foot.
        float wob = (fbm2(float2(arc * 0.015, z * 0.008), oct) - 0.5) * 16.0;
        float layer = z + wob;
        float band = vn2(float2(layer * 0.1, arc * 0.003 + 3.0)) * 0.7 + vn2(float2(layer * 0.37, arc * 0.006)) * 0.3;
        float fineBand = vn2(float2(layer * 0.35, arc * 0.01 + 9.0));
        float gully = fbm2(float2(arc * 0.03 + 0.4 * wob, z * 0.006 + 4.0), oct);
        float buttress = vn2(float2(arc * 0.006, 7.0)) * 0.65 + vn2(float2(arc * 0.017, z * 0.004 + 2.0)) * 0.35;
        float3 basalt = mix(float3(0.055, 0.05, 0.048), float3(0.085, 0.062, 0.05), smoothstep(0.6, 0.85, band));
        basalt *= 0.8 + 0.25 * fineBand;
        // Relief: the face leans with the gullies and buttresses, the ledges between the flows step out.
        float ledge = smoothstep(0.42, 0.58, vn2(float2(layer * 0.075, arc * 0.004 + 1.0))) - 0.5;
        float3 inward = float3(-q / max(r, 1e-3), 0.0);
        float3 tangent = float3(inward.y, -inward.x, 0.0);
        float lean = (gully - 0.5) * 1.6 + (buttress - 0.5) * 2.6;
        float3 N = normalize(inward + tangent * lean + float3(0, 0, ledge * 1.3));
        if (h.kind == 4) N = normalize(float3(0, 0, 1) + inward * 0.25);
        // Crevices hold the dark: gullies' floors and the ledges' undersides.
        float ao = (0.35 + 0.65 * smoothstep(0.2, 0.7, gully)) * (0.55 + 0.45 * smoothstep(0.25, 0.6, buttress))
                 * (0.7 + 0.3 * smoothstep(-0.3, 0.2, ledge));
        float footZ = h.p.z > u.dims.y + 1.0 ? u.dims.y : u.eye.w;
        float talus = h.kind == 3 ? (1.0 - smoothstep(0.0, 10.0 + 14.0 * gully, P.z - footZ)) : 0.0;
        float rubble = vn2(float2(arc * 0.4, P.z * 0.4));
        basalt = mix(basalt, float3(0.07, 0.06, 0.055) * (0.6 + 0.8 * rubble), talus);
        if (h.kind == 4) {
            basalt = float3(0.06, 0.052, 0.048) * (0.5 + 0.8 * vn2(P.xy * 0.15));
            ao = 0.8;
        }
        float3 col = basalt * ao * (craterLight(P, N, u) + u.skyL.rgb);
        // The breach's notch: its cut faces lit by the river pouring through.
        float off = abs(th - u.dims2.w);
        float nearNotch = 1.0 - smoothstep(u.dims3.x * 0.5, u.dims3.x * 2.2, off);
        float riverLight = (0.1 + 0.3 * u.river.x + 3.0 * u.river.z) * nearNotch * exp(-max(z, 0.0) / 40.0);
        col += basalt * u.glow.rgb * riverLight * 4.0;
        // A rockfall (a surprise): a cascade of dust and debris sliding down the wall from the lip, lit from below.
        if (u.rockfall.x >= 0.0) {
            float pr = u.rockfall.x;
            float da = (th - u.rockfall.y) * r;
            float front = u.dims2.z + 10.0 - pr * 1.4 * u.dims2.z;
            float width = 14.0 + 34.0 * pr + 0.15 * max(u.dims2.z - P.z, 0.0);
            float spread = exp(-sq(da / width));
            float body = smoothstep(front - 12.0, front + 20.0, P.z) * (1.0 - smoothstep(0.55, 1.0, pr));
            float n = fbm2(float2(da * 0.07, P.z * 0.04 + pr * 5.0), oct);
            float dust = saturate(spread * body * (0.35 + 0.9 * n));
            float3 dustLit = u.glow.rgb * float3(1.0, 0.86, 0.74) * (1.1 * exp(-max(z, 0.0) / 140.0) * (0.6 + 0.6 * n)) + u.skyL.rgb * 0.5;
            col = mix(col, dustLit, dust * 0.8);
            float debris = smoothstep(0.82, 0.95, vn2(float2(da * 0.25, P.z * 0.18 + pr * 40.0))) * spread * body;
            col += blackbody(1000.0) * (0.4 * debris);
        }
        // Hot seams in the old walls, here and there low down, livelier with Energy.
        float seam = smoothstep(0.94, 0.975, vn2(float2(arc * 0.08, layer * 0.25))) * (1.0 - smoothstep(0.0, 50.0, z));
        col += blackbody(960.0 + 120.0 * u.play.x) * (0.15 * seam);
        return col;
    }

    // ---------------------------------------------------------------- fountains, the column and the plume
    /// Billows: a field of rounded lumps (cells of `cell` metres, each its own size) and the normal of the domes under
    /// a point, blended smoothly between neighbours (no seams); `cover` 1 at a lump's middle, 0 between them.
    float3 lumps(float2 m, float cell, float seed, thread float& cover) {
        float2 g = m / cell;
        float2 gi = floor(g), gf = fract(g);
        float3 acc = float3(0);
        float wsum = 0.0, e = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 c = float2(float(x), float(y));
                float2 h = hash22(gi + c + seed);
                float rr = 0.6 + 0.45 * hash12(gi + c + seed + 3.7);
                float2 r = c + h - gf;
                float dd = length(r) / rr;
                float2 q = -r / rr;
                float hz = sqrt(saturate(1.0 - dot(q, q)));
                float w = exp(-4.0 * dd * dd);
                acc += normalize(float3(q, hz + 0.1)) * w;
                wsum += w;
                e += exp(-dd / 0.2);
            }
        }
        cover = saturate(1.0 + 0.2 * log(max(e, 1e-6)));
        return normalize(acc / max(wsum, 1e-5) + float3(0, 0, 1e-3));
    }

    /// Flung clots: round drops scattered on a jittered grid (each its own size, some cells empty), 0…1 cover.
    float clotField(float2 g, float fill) {
        float2 gi = floor(g), gf = fract(g);
        float best = 0.0;
        for (int y = 0; y <= 1; y++) {
            for (int x = 0; x <= 1; x++) {
                float2 c = float2(float(x), float(y)) - step(0.5, gf) + float2(0.0);
                float2 id = gi + c;
                float2 h = hash22(id + 3.1);
                float keep = step(1.0 - fill, hash12(id + 9.7));
                float r = 0.12 + 0.2 * hash12(id + 5.3);
                float dd = length(c + h - gf);
                best = max(best, keep * (1.0 - smoothstep(r * 0.55, r, dd)));
            }
        }
        return best;
    }

    /// A fountain's spatter dome on its own plane through its site, facing the camera: a bright jet in the middle and
    /// clots flung out to its parabolic envelope; returns light (rgb) and cover (a).
    float4 fountain(float3 o, float3 d, float4 f, constant VolcanoU& u, float tMax) {
        if (f.z < 0.5 || d.y < 1e-4) return float4(0);
        float t = (f.y - o.y) / d.y;
        if (t <= 0.0 || t >= tMax) return float4(0);
        float3 P = o + d * t;
        float x = P.x - f.x;
        float z = P.z - u.eye.w;
        float H = f.z, W = 0.85 * f.z + 9.0;
        if (z < -2.0 || z > H * 1.35 || abs(x) > W * 1.6) return float4(0);
        float s = x / W;
        float env = H * (1.0 - s * s);
        // A dome of spatter: a bright jet in the middle, sheets of it bursting outward, clots flung to its envelope.
        float body = smoothstep(env + 2.0, env - 0.35 * H - 2.0, z) * smoothstep(-1.5, 1.0, z) * (1.0 - smoothstep(0.85, 1.2, abs(s)));
        float core = exp(-s * s / 0.05) * smoothstep(H * 1.1, H * 0.35, z);
        float sheet = smoothstep(0.45, 0.8, vn2(float2(x * 0.22, z * 0.3 - u.a.y * 6.0) + f.w * 3.0)) * body;
        float clots = clotField(float2(x * 0.32, z * 0.2 - u.a.y * 2.2) + f.w * 5.0, 0.5)
                    * smoothstep(1.35 * H, 0.2 * H, z) * (1.0 - smoothstep(1.0, 1.5, abs(s)));
        float dens = saturate(0.9 * core + 0.7 * sheet + 0.9 * clots + 0.12 * body);
        float T = 1160.0 + 230.0 * core + 70.0 * f.w + 50.0 * sheet - 140.0 * saturate(z / max(H, 1.0)) * (1.0 - core);
        float glow = exp(-length(float2(x, z * 1.6)) / (0.6 * W)) * 0.25;
        return float4(blackbody(T) * dens + blackbody(1150.0) * glow * (0.5 + 0.5 * f.w), saturate(dens));
    }

    /// A steam blast (a surprise): a jet of steam roaring up from a vent on the floor by the wall, white but lit orange
    /// from the lake below, rising fast and spreading, then thinning away.
    float4 steamJet(float3 o, float3 d, constant VolcanoU& u, float tMax, int oct) {
        if (u.steam.x < 0.0 || d.y < 1e-4) return float4(0);
        float pr = u.steam.x;
        float th = u.steam.y;
        float2 V = u.dims2.xy + float2(sin(th), cos(th)) * (u.dims.x - 45.0);
        float t = (V.y - o.y) / d.y;
        if (t <= 0.0 || t >= tMax) return float4(0);
        float3 P = o + d * t;
        float x = P.x - V.x;
        float z = P.z - u.eye.w;
        float H = 190.0 * smoothstep(0.0, 0.3, pr);
        if (z < -2.0 || z > H + 40.0) return float4(0);
        float w = 9.0 + 0.5 * max(z, 0.0);
        float s = x / w;
        if (abs(s) > 1.8) return float4(0);
        float2 m = float2(x, z - pr * 260.0);
        float c1;
        float3 nb = lumps(m + 30.0 * (float2(vn2(m * 0.02), vn2(m * 0.02 + 7.0)) - 0.5), 22.0 + 0.1 * z, 21.0, c1);
        float n = fbm2(m * 0.05, oct);
        float dens = smoothstep(1.4, 0.2, abs(s) + 0.5 * (n - 0.5) - 0.2 * c1) * smoothstep(H + 30.0, H * 0.5, z)
                   * (1.0 - smoothstep(0.55, 1.0, pr)) * (0.45 + 0.6 * n + 0.3 * c1);
        dens = saturate(dens * 1.3);
        float under = saturate(0.5 + 0.6 * dot(nb, normalize(float3(0.0, -1.0, 0.6))));
        float3 lit = (u.glow.rgb * float3(1.0, 0.9, 0.82) * (2.2 * exp(-max(z, 0.0) / 110.0)) * (0.35 + 0.8 * under)
                    + float3(0.03, 0.03, 0.035));
        return float4(lit * dens, dens);
    }

    /// A lava tree (a surprise): a pillar of chilled lava left standing in the river as its level drops, its foot ringed
    /// with the river's glow.
    float4 lavaTree(float3 o, float3 d, constant VolcanoU& u, float tMax) {
        if (u.tree.x < 0.0 || d.y < 1e-4) return float4(0);
        float2 a = u.riverA.xy, b = u.riverA.zw;
        float sh = u.tree.y;
        float2 ab = b - a;
        float2 side = float2(-ab.y, ab.x) / max(length(ab), 1e-3);
        float2 V = a + ab * sh + side * (sin(sh * 3.14159) * 14.0 + sin(sh * 9.0) * 3.0);
        float t = (V.y - o.y) / d.y;
        if (t <= 0.0 || t >= tMax) return float4(0);
        float3 P = o + d * t;
        float x = P.x - V.x;
        float z = P.z - u.eye.w;
        float pr = u.tree.x;
        float stand = smoothstep(0.0, 0.08, pr) * (1.0 - smoothstep(0.9, 1.0, pr));
        float hgt = 9.0 + 3.0 * u.tree.z;
        float wTree = 2.2 * (1.0 - 0.45 * saturate(z / hgt)) + 0.6 * (vn2(float2(z * 0.8, 3.0)) - 0.5);
        float body = smoothstep(wTree + 0.3, wTree - 0.3, abs(x)) * smoothstep(-0.5, 0.0, z) * smoothstep(hgt + 0.5, hgt - 0.8, z);
        float collar = exp(-max(z, 0.0) / 1.2) * smoothstep(wTree * 3.0, wTree, abs(x));
        float3 c = float3(0.03, 0.026, 0.024) * u.glow.rgb * 6.0 * (0.4 + 0.6 * exp(-z / 4.0));
        float4 tree = float4(c * body + blackbody(1180.0) * collar * 0.8, saturate(body + 0.6 * collar));
        return tree * stand;
    }

    /// The eruption's fountain on the middle plane, as a long exposure sees it: a dense, ragged jet of spatter out of the
    /// vent breaking up into a sheaf of clots, each clot's flight a parabolic streak (rising fast, slowing, curving over,
    /// cooling from yellow to red as it falls back); the streaks re-seed every second or so, staggered, and bright beads
    /// run up them. `fp` is metres a pixel at the plane (the streaks are footprint-filtered lines).
    float4 column(float3 P, constant VolcanoU& u, float fp, int oct) {
        float H = u.erupt.x;
        float age = u.erupt.z;
        if (age < 0.0 || age > 6.0) return float4(0);
        float strength = u.erupt.w;
        // Its peak (Eruption.peak): 3 lake-widths at the weakest, 6 at the strongest.
        float sp = clamp(strength, 0.3, 1.0);
        float peak = (3.0 + 3.0 * (sp - 0.3) / 0.7) * 2.0 * u.lake.x;
        float z = P.z - u.eye.w;
        if (z < -2.0 || z > peak * 1.05) return float4(0);
        float x = P.x;
        float tt = u.a.y;
        // The sheaf never spreads wider than its arcs allow: skip what is far outside it.
        if (abs(x) > 60.0 + 0.6 * max(z, 0.0) + 0.1 * peak) return float4(0);
        float3 light = float3(0);
        float cover = 0.0;
        // The jet: dense spatter out of the vent, widening, its edges torn, breaking up into clots within a hundred metres
        // or so; yellow-hot in its heart, never a beam (its density falls fast with height). It dies as the column falls.
        float jetAmt = saturate(H / peak);
        float jw = 14.0 + 0.16 * max(z, 0.0);
        float rag = vn2(float2(x * 0.08, z * 0.035 - tt * 9.0)) + 0.5 * vn2(float2(x * 0.21, z * 0.09 - tt * 17.0));
        float js = abs(x + 6.0 * (vn2(float2(z * 0.01 - tt * 2.0, 4.0)) - 0.5)) / jw;
        float jet = smoothstep(1.0, 0.15, js + 0.45 * (rag - 0.75)) * exp(-max(z, 0.0) / (0.025 * peak + 35.0)) * jetAmt;
        jet *= smoothstep(0.25, 0.75, rag + 0.35 * exp(-max(z, 0.0) / 40.0));
        float jT = 1170.0 + 110.0 * exp(-js * js * 4.0) - 120.0 * saturate(z / (0.1 * peak));
        light += blackbody(jT) * (0.9 * jet);
        cover = max(cover, jet);
        // The clots: each streak is one clot's path over the last part of its flight (a long exposure's trail). Each of the
        // streaks has its own height class (most low, a few to the top); its clot is thrown again each time the last one
        // lands, on a new arc, while the column stands (rise and hold, 3 s). Low arcs curve over and fall back in view;
        // the tall ones leave the frame still climbing. The clot crosses the plane at a steady pace, so the share of its
        // arc it has flown is its share of its flight time, 2·√(2h/g); the flights play 3.2 times fast.
        const float pace = 3.2;
        int n = oct >= 3 ? 36 : 20;
        for (int k = 0; k < 36; k++) {
            if (k >= n) break;
            float fk = float(k);
            float hk = hash12(float2(fk * 1.37, 4.4));
            float h = peak * (0.02 + 0.98 * hk * hk * hk * hk);
            float flight = 2.0 * sqrt(2.0 * h / 9.81);
            float period = flight / pace + 0.15 + 0.3 * hash12(float2(fk, 1.3));
            float delay = 0.35 * hash12(float2(fk, 2.9)) + 0.015 * fk;
            float since = age - delay;
            if (since < 0.0) continue;
            float launch = floor(since / period);
            launch = min(launch, floor((3.0 - delay) / period));
            float s0 = (since - launch * period) * pace;
            float2 sd = float2(fk * 3.17 + launch * 1.71, launch * 0.37 + 5.0);
            float r1 = hash12(sd), r3 = hash12(sd + 23.9), r4 = hash12(sd + 37.1);
            // Its launch: a little off the vent, tipped from upright (the low ones more so).
            float x0 = (r3 - 0.5) * 24.0;
            float T = tan((r1 - 0.5) * (1.0 - 0.55 * hk));
            T = T < 0.0 ? min(T, -0.006) : max(T, 0.006);
            float uu = (x - x0) / T;
            if (uu < -2.0 || uu > 4.0 * h) continue;
            float along = saturate(uu / (4.0 * h));
            float sPix = along * flight;
            float trail = (0.2 + 0.25 * r4) * min(flight, 18.0);
            if (sPix > s0 + 0.5 || sPix < s0 - trail - 0.5) continue;
            float zArc = uu - uu * uu / (4.0 * h);
            float slope = (1.0 - uu / (2.0 * h)) / T;
            float dist = abs(z - zArc) / sqrt(1.0 + slope * slope);
            if (dist > 12.0 + 6.0 * fp) continue;
            // Along the trail: brightest at the clot, fading behind it; it cools as it flies, and is gone once it lands.
            float tr = saturate((sPix - (s0 - trail)) / trail);
            float head = smoothstep(s0 + 0.04, s0 - 0.01, sPix);
            float w = 0.5 + 1.1 * r4;
            float line = lineLight(dist, w, fp);
            float bead = 0.6 + 0.4 * smoothstep(0.35, 0.8, vn2(float2(sPix * 6.0, fk * 7.0 + launch * 3.0)));
            float Tk = 1210.0 + 80.0 * r4 - 40.0 * sPix / pace;
            float b = (0.6 + 0.7 * r1 * r3) * head * tr * tr * bead * (0.7 + 0.3 * strength)
                    * (0.4 + 0.6 * smoothstep(0.0, 70.0, z)) * smoothstep(0.0, 0.25, s0)
                    * smoothstep(flight + 0.3, flight - 0.3, s0) * smoothstep(6.0, 5.0, age);
            light += blackbody(Tk) * (line * b * 2.4);
            cover = max(cover, saturate(line * b * 0.7) * smoothstep(850.0, 1100.0, Tk));
        }
        // The spatter's light scattered in the gas round it.
        float haze = exp(-abs(x) / (60.0 + 0.2 * max(z, 0.0))) * exp(-max(z, 0.0) / max(0.35 * H, 1.0)) * smoothstep(-2.0, 20.0, z);
        light += blackbody(1120.0) * (0.12 * haze * u.erupt.y);
        return float4(light, saturate(cover));
    }

    /// The plume on its plane through the lake's middle: a column of gas and ash rising and spreading, bent by the wind,
    /// its billows lit from below by the lake (bright undersides, darker crowns); `tMax` the scene behind it.
    float4 plume(float3 P, constant VolcanoU& u, int oct, float3 lightCol) {
        float z = P.z - u.eye.w;
        float amount = u.plume.x;
        if (amount <= 0.01 || z < -5.0) return float4(0);
        float bend = u.plume.z * z * z;
        float W = (85.0 + 0.5 * z) * (0.75 + 0.5 * amount) * (1.0 + 0.35 * u.plume.y);
        float x = P.x - bend;
        float s = x / W;
        if (abs(s) > 1.7) return float4(0);
        // Billows rising: big lumps with smaller ones on them (cauliflower), scrolling up as the plume climbs, warped so
        // they never line up, each lump a dome lit from the lake below and in front: bright undersides, crowns and the
        // creases between lumps in shade. Low down, over the lake, it's glowing gas more than cloud.
        float2 m = float2(x, z - u.plume.w);
        float2 wq = float2(vn2(m * 0.012 + float2(4.0, 1.0)), vn2(m * 0.012 + float2(9.0, 2.0))) - 0.5;
        m += wq * 46.0;
        float c1, c2 = 0.0;
        float3 n1 = lumps(m, 64.0 + 0.12 * max(z, 0.0), 0.0, c1);
        float3 n2 = float3(0, 0, 1);
        if (oct >= 3) n2 = lumps(m * 1.0 + float2(17.0, 5.0), 26.0, 11.0, c2);
        float soft = fbm2(m * 0.02, oct);
        float profile = smoothstep(1.2, 0.1, abs(s) + 0.45 * (soft - 0.5) - 0.25 * c1);
        float base = smoothstep(-5.0, 35.0, z);
        float body = 0.12 + 0.88 * smoothstep(25.0, 190.0, z);
        float lumpy = smoothstep(-0.05, 0.55, c1 + 0.3 * c2 + 0.5 * (soft - 0.5));
        float dens = saturate(profile * base * (0.6 + 0.7 * amount) * mix(0.35 + 0.4 * soft, 1.6 * lumpy, body));
        if (dens <= 0.002) return float4(0);
        float chord = sqrt(saturate(1.0 - s * s * 0.5));
        float alpha = 1.0 - exp(-dens * chord * 2.8);
        float3 N = normalize(n1 + n2 * 0.55);
        float3 Lb = normalize(float3(-0.1, -1.0, 0.55));
        float dome = saturate(0.5 + 0.5 * dot(N, Lb) * 1.6);
        // Gas, not clay: light scatters through it, so the billows' shading is soft and the thin parts glow through.
        float through = exp(-dens * 1.6);
        float shade = mix(0.75, dome, 0.65 * body) * (0.75 + 0.25 * smoothstep(0.0, 0.25, c1)) + 0.35 * through;
        // Lit from below: brightest at its foot (the lake's disc), fading with height.
        float R = u.lake.x;
        float fall = R * R / (R * R + sq(max(z, 0.0) + 30.0)) * (0.25 + 0.75 * exp(-max(z, 0.0) / 110.0));
        float3 lit = lightCol * float3(1.0, 0.84, 0.72) * (1.45 * fall * (0.1 + 1.0 * shade));
        lit += float3(0.012, 0.014, 0.02) * u.skyL.w + u.skyL.rgb * 0.5;
        // Lightning inside it: a violet-white glow round the stroke.
        float2 b = float2(x + bend - u.bolt.y, z - u.bolt.z);
        lit += float3(0.72, 0.7, 1.0) * (u.bolt.x * 0.7 * exp(-dot(b, b) / (2.0 * 38.0 * 38.0)) * (0.4 + 0.6 * shade));
        // The column inside it lights it hard.
        lit += u.glow.rgb * (u.erupt.y * 0.25 * exp(-abs(P.x) / 90.0) * smoothstep(u.erupt.x + 60.0, 0.0, z) * (0.3 + 0.7 * shade));
        return float4(lit * alpha, alpha);
    }

    /// The fume over the lake: a haze glowing with the lake's light, thickest just above it, churning; returns its light
    /// and its transmittance along the ray up to `t`.
    float4 fume(float3 o, float3 d, float t, constant VolcanoU& u, int oct) {
        float lakeZ = u.eye.w;
        float hs = 26.0;
        // Along the ray, the height falls from the eye's to the hit's; the fume's density e^(−z/hs) integrates in closed form.
        float z0 = o.z - lakeZ, z1 = o.z + d.z * min(t, 4000.0) - lakeZ;
        float dz = z0 - z1;
        float len = min(t, 4000.0);
        float integral;
        if (dz > 0.5) integral = len * hs * (exp(-max(z1, 0.0) / hs) - exp(-z0 / hs)) / dz;
        else integral = len * exp(-max(z1, 0.0) / hs);
        // Over the lake only (the far end of the ray decides), and churning.
        float3 end = o + d * len;
        float overLake = 1.0 - smoothstep(u.lake.x * 0.8, u.lake.x * 1.6, length(end.xy));
        float churn = fbm2(end.xy * 0.012 + float2(u.a.y * 0.05, -u.a.y * 0.035), oct);
        float tau = integral * 0.0024 * overLake * (0.35 + 1.3 * churn) * (0.6 + 0.6 * u.plume.x);
        float T = exp(-tau);
        float3 light = u.glow.rgb * float3(1.0, 0.82, 0.7) * (1.0 - T) * 0.32;
        return float4(light, T);
    }

    // ---------------------------------------------------------------- the sky and beyond
    float3 beyond(float3 dE, float3 d, constant SkyU& sky, constant VolcanoU& u, texture2d<float> stars, float2 ndc) {
        float3 col;
        float el = asin(clamp(d.z, -1.0, 1.0));
        float az = atan2(d.x, d.y);
        if (dE.z >= 0.0) {
            float moonMask = 0.0;
            // A long exposure's sky: the stars and the Milky Way come up over the glow.
            col = skyRadiance(dE, sky, moonMask, stars) * 1.9;
        } else {
            // The dark plain far below, the horizon's haze over it.
            col = sky.horizon.rgb * 0.3 * exp(dE.z * 30.0);
        }
        // Far volcanoes on the plain's horizon: low dark ranges and a broad cone, hazed by distance, hiding the stars.
        float range = 0.006 + 0.012 * vn2(float2(az * 9.0, 2.0)) + 0.006 * vn2(float2(az * 31.0, 5.0));
        float cone = 0.034 * smoothstep(0.32, 0.0, abs(az - 0.55)) * (1.0 - 0.15 * vn2(float2(az * 60.0, 1.0)));
        float ridge = max(range, cone);
        if (el < ridge) {
            float haze = exp(-(ridge - el) / 0.01);
            col = mix(sky.horizon.rgb * 0.18, sky.horizon.rgb * 0.45, haze * 0.5);
        }
        // The plume's glow on the low sky round it (the air scatters the lit plume).
        float bendX = u.plume.z * 200.0 * 200.0;
        float ax = atan2(bendX * 0.5, u.eye.y * -1.0);
        float off = az - ax;
        float glowSky = exp(-off * off / 0.09) * exp(-max(el + 0.02, 0.0) / 0.22) * u.plume.x;
        col += u.glow.rgb * float3(1.0, 0.7, 0.5) * (0.06 * glowSky);
        // Far storms on the plain beyond the rim, left of the view: dark towers on the horizon, lit now and then from
        // inside, red sprites above them (a surprise).
        float st = u.sprites.w;
        if (st > 0.0 && el > -0.01 && el < 0.09) {
            float sx = (az + 0.56) / 0.13;
            float top = 0.05 + 0.02 * vn2(float2(sx * 3.0, 1.0)) + 0.025 * smoothstep(0.7, 0.0, abs(sx - 0.2));
            float tower = smoothstep(1.0, 0.3, abs(sx)) * smoothstep(top, top - 0.012, el);
            float flick = u.sprites.x > 0.0 ? u.sprites.x : 0.0;
            float inner = vn2(float2(sx * 2.0 + u.a.y * 0.3, el * 40.0));
            col = mix(col, sky.horizon.rgb * 0.22, tower * st);
            col += float3(0.7, 0.72, 1.0) * (tower * (flick * 0.12 * (0.5 + inner) + 0.015 * inner * st));
        }
        if (u.sprites.x > 0.0) {
            // Red sprites high over the far storm: two or three carrot-shaped columns, a red crown each with faint
            // blue-violet tendrils hanging below, gone in a blink.
            float b = u.sprites.y * 0.0174533;
            float sxp = (az - b) / 0.007;
            float sy = (el - 0.105) / 0.016;
            float cols = exp(-sxp * sxp) + 0.7 * exp(-sq(sxp - 2.6)) + 0.55 * exp(-sq(sxp + 2.2));
            float crown = exp(-sy * sy * 1.5) * smoothstep(-3.0, -0.5, sy);
            float fil = 0.5 + 0.5 * cos(sxp * 5.0 + u.sprites.z * 9.0);
            float tendril = exp(-sq((sy + 2.2) / 1.3)) * fil * fil * fil;
            float3 sprite = float3(1.0, 0.1, 0.22) * crown + float3(0.5, 0.3, 1.0) * (0.45 * tendril);
            col += sprite * (cols * u.sprites.x * 0.8);
        }
        // A fireball (a surprise): a bright head and a fading train across the sky.
        if (u.fireball.x >= 0.0) {
            float p = u.fireball.x;
            float2 a0 = float2(u.fireball.y, u.fireball.z) * 0.0174533;
            float2 a1 = a0 + float2(0.55, -0.32);
            float2 head = mix(a0, a1, p);
            float2 here = float2(az, el);
            float2 ab = head - a0;
            float s = clamp(dot(here - a0, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
            float dist = length(here - (a0 + ab * s));
            float train = exp(-dist / 0.0015) * s * s * (1.0 - smoothstep(0.85, 1.0, p));
            float h = exp(-length(here - head) / 0.0025);
            col += float3(0.8, 1.0, 0.75) * (train * 2.0 + h * 9.0) * u.fireball.w;
        }
        return col;
    }

    // ---------------------------------------------------------------- the foreground
    /// The near rim's rocks along the bottom of the view (screen space): rough basalt boulders, rim-lit by the crater's
    /// glow; returns light and cover.
    float4 foreground(float2 ndc, constant VolcanoU& u, int oct) {
        float top = u.dims3.z;
        float x = ndc.x * u.a.x;
        float edge = top + 0.05 * (fbm2(float2(x * 2.2, 3.0), oct) - 0.5) + 0.035 * (vn2(float2(x * 9.0, 1.0)) - 0.5);
        float pix = u.cam.w;
        float cover = smoothstep(edge + pix, edge - pix, ndc.y);
        if (cover <= 0.0) return float4(0);
        float depth = edge - ndc.y;
        float3 rock = float3(0.045, 0.04, 0.038) * (0.6 + 0.8 * fbm2(float2(x * 14.0, ndc.y * 14.0), oct));
        float rim = exp(-depth / (0.012 + 0.02 * vn2(float2(x * 6.0, 2.0))));
        float3 light = u.glow.rgb * float3(1.0, 0.8, 0.65) * (4.0 * rim + 0.35) + u.skyL.rgb;
        return float4(rock * light * cover, cover);
    }

    // ---------------------------------------------------------------- the scene
    fragment ColorDepth volcano_scene_fragment(VolOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                               constant VolcanoU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc - u.cam.xy;
        int oct = int(u.a.z + 0.5);
        float3 Dn = sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w);
        float3 dE = normalize(Dn);
        float3 fwd3 = float3(u.axes.xy, 0.0), right3 = float3(u.axes.zw, 0.0);
        float3 d = float3(dot(dE, right3), dot(dE, fwd3), dE.z);
        float3 o = u.eye.xyz;
        Hit h = craterHit(o, d, u);
        float3 col;
        float depth = 1.0;
        if (h.kind == 1 || h.kind == 2) {
            // The pixel's footprint on the plane (metres per pixel across x and y), from the unnormalised ray.
            float3 Dc = float3(dot(Dn, right3), dot(Dn, fwd3), Dn.z);
            float px = u.cam.w / max(u.a.x, 1e-3), py = u.cam.w;
            float3 sx = sky.right.xyz * (sky.right.w * px), sy = sky.up.xyz * (sky.up.w * py);
            float3 dx = float3(dot(sx, right3), dot(sx, fwd3), sx.z), dy = float3(dot(sy, right3), dot(sy, fwd3), sy.z);
            float tp = (u.eye.w - o.z) / min(Dc.z, -1e-6);
            float2 Jx = tp * (dx.xy - Dc.xy * (dx.z / Dc.z));
            float2 Jy = tp * (dy.xy - Dc.xy * (dy.z / Dc.z));
            if (h.kind == 1) col = lakeSurface(h.p, d, Jx, Jy, u, oct);
            else col = floorColour(h.p, d, max(length(Jx), length(Jy)), u, oct);
            depth = 0.6;
        } else if (h.kind >= 3) {
            col = wallColour(h, d, u, oct, h.t * u.a.w);
            depth = 0.7;
        } else {
            col = beyond(dE, d, sky, u, stars, ndc);
            if (h.kind == 5) {
                // Through the breach: the river pouring over its lip lights the fume in the gap from below.
                float zz = h.p.z - u.eye.w;
                float lip = exp(-max(zz, 0.0) / (30.0 + 60.0 * u.river.z));
                col += u.glow.rgb * float3(1.0, 0.8, 0.6) * ((0.25 + 0.6 * u.river.x + 3.5 * u.river.z) * lip);
                col += blackbody(1150.0 + 150.0 * u.river.z) * (exp(-max(zz, 0.0) / 4.0) * (0.15 + 0.3 * u.river.x + 1.5 * u.river.z));
            }
        }
        // What stands over the lake, nearest last: by the walls a steam blast and a lava tree, the fountains, then the
        // column and the plume on the middle plane.
        float tHit = (h.kind == 0 || h.kind == 5) ? 1e9 : h.t;
        float4 jet = steamJet(o, d, u, tHit, oct);
        col = col * (1.0 - jet.a) + jet.rgb;
        float4 tree = lavaTree(o, d, u, tHit);
        col = col * (1.0 - tree.a) + tree.rgb;
        float4 fa = fountain(o, d, u.fountA, u, tHit);
        float4 fb = fountain(o, d, u.fountB, u, tHit);
        float ta = (u.fountA.y - o.y) / max(d.y, 1e-4), tb = (u.fountB.y - o.y) / max(d.y, 1e-4);
        float tm = (0.0 - o.y) / max(d.y, 1e-4);
        float4 farF = ta > tb ? fa : fb, nearF = ta > tb ? fb : fa;
        float farT = max(ta, tb);
        float4 mid = float4(0);
        float4 pl = float4(0);
        if (tm < tHit && tm > 0.0) {
            float3 P = o + d * tm;
            mid = column(P, u, tm * sky.up.w * u.cam.w, oct);
            pl = plume(P, u, oct, u.glow.rgb);
        }
        // The column stands inside the plume: the gas veils it a little, its light shows through.
        float veil = 1.0 - 0.45 * pl.a;
        if (farT > tm) {
            col = col * (1.0 - farF.a) + farF.rgb;
            col = col * (1.0 - pl.a) + pl.rgb;
            col = col * (1.0 - mid.a * veil) + mid.rgb * veil;
            col = col * (1.0 - nearF.a) + nearF.rgb;
        } else {
            col = col * (1.0 - pl.a) + pl.rgb;
            col = col * (1.0 - mid.a * veil) + mid.rgb * veil;
            col = col * (1.0 - farF.a) + farF.rgb;
            col = col * (1.0 - nearF.a) + nearF.rgb;
        }
        // The fume over the lake, in front of it all.
        float4 fm = fume(o, d, min(tHit, tm > 0.0 ? max(tm, tHit) : tHit), u, oct);
        col = col * fm.a + fm.rgb;
        // The near rim's rocks.
        float4 fg = foreground(in.ndc, u, oct);
        col = col * (1.0 - fg.a) + fg.rgb;
        ColorDepth out;
        out.color = float4(max(col, 0.0), 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- embers, blobs, bombs, sparks
    // Each spark is a capsule streaked along its motion on screen (its blur over a 30th of a second), its light kept
    // as it streaks; a near ember is a soft disc (out of focus).
    struct Spark { float4 at; float4 info; };   // centre (NDC xy), its travel on screen (NDC xy); halfW size (NDC y), temperature (K), light, softness
    struct SparkOut { float4 pos [[position]]; float2 uv; float3 col; float soft; float len; };
    vertex SparkOut volcano_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Spark* sparks [[buffer(0)]],
                                         constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        Spark s = sparks[iid];
        float2 v = float2(s.at.z * view.x, s.at.w);
        float speed = length(v);
        float2 dir = speed > 1e-6 ? v / speed : float2(0, 1);
        float2 side = float2(-dir.y, dir.x);
        float halfW = max(s.info.x, 1e-5);
        float L = 0.5 * speed / halfW;                 // the streak's halfW-length past the head, in sizes
        float2 q = c[vid] * 1.6;
        float2 off = dir * (q.y * halfW * (1.0 + L)) + side * (q.x * halfW);
        SparkOut o;
        o.pos = float4(s.at.xy + float2(off.x / view.x, off.y) + view.yz, 0, 1);
        o.uv = float2(q.x, q.y * (1.0 + L));
        float t = clamp(s.info.y, 450.0, 2200.0);
        float inv = 1.0 / t;
        float3 bb = float3(1.0, exp(0.38 - 1848.0 * inv), exp(2.036 - 8727.0 * inv)) * exp((t - 1150.0) * 0.0086957);
        o.col = bb * (s.info.z / (1.0 + 0.5 * L));
        o.soft = s.info.w;
        o.len = L;
        return o;
    }
    fragment float4 volcano_spark_fragment(SparkOut in [[stage_in]]) {
        float2 p = in.uv;
        float dy = max(abs(p.y) - in.len, 0.0);
        float r2 = p.x * p.x + dy * dy;
        // A comet, not a dash: brightest at its head (ahead, along its motion), its trail fading and thinning behind.
        float along = in.len > 0.05 ? saturate((p.y + in.len + 1.0) / (2.0 * in.len + 2.0)) : 1.0;
        float thin = 0.45 + 0.55 * along;
        float sharp = exp(-(p.x * p.x / (thin * thin) + dy * dy) * 3.0) * (0.12 + 0.88 * along * along);
        float disc = (1.0 - smoothstep(0.75, 1.0, sqrt(r2))) * (0.55 + 0.45 * smoothstep(0.9, 0.5, sqrt(r2)));
        float a = mix(sharp, 0.5 * disc, in.soft);
        if (a < 0.002) discard_fragment();
        return float4(in.col * a, 0.0);
    }

    // ---------------------------------------------------------------- the plume's lightning
    struct Bolt { float4 seg; float4 info; };   // NDC x0, y0, x1, y1; core (NDC), reach (NDC), light, branch
    struct BoltOut { float4 pos [[position]]; float2 p; float4 seg; float4 info; };
    vertex BoltOut volcano_bolt_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Bolt* bolts [[buffer(0)]],
                                       constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Bolt b = bolts[iid];
        float pad = b.info.y;
        float2 lo = min(b.seg.xy, b.seg.zw) - float2(pad / view.x, pad);
        float2 hi = max(b.seg.xy, b.seg.zw) + float2(pad / view.x, pad);
        BoltOut o;
        float2 at = mix(lo, hi, c[vid]);
        o.pos = float4(at + view.yz, 0, 1);
        o.p = at;
        o.seg = b.seg;
        o.info = b.info;
        return o;
    }
    fragment float4 volcano_bolt_fragment(BoltOut in [[stage_in]], constant float4& view [[buffer(0)]]) {
        float2 a = float2(in.seg.x * view.x, in.seg.y), b = float2(in.seg.z * view.x, in.seg.w);
        float2 p = float2(in.p.x * view.x, in.p.y);
        float2 ab = b - a;
        float s = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-10), 0.0, 1.0);
        float dist = length(p - (a + ab * s));
        float core = in.info.x, reach = in.info.y;
        float l = exp(-sq(dist / max(core, 1e-5))) * 3.0 + exp(-dist / max(reach * 0.35, 1e-5)) * 0.45;
        float3 c = mix(float3(0.85, 0.82, 1.0), float3(0.72, 0.6, 1.0), in.info.w) * (l * in.info.z);
        if (l * in.info.z < 0.002) discard_fragment();
        return float4(c, 0.0);
    }

    // ---------------------------------------------------------------- the basalt columns (the keys)
    struct Column { float4 rect; float4 info; };   // NDC x0, y0, x1, y1; black 0/1, glow, pressed, 0
    struct ColumnOut { float4 pos [[position]]; float2 uv; float4 info; float seed; float2 size; };
    vertex ColumnOut volcano_column_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Column* cols [[buffer(0)]],
                                           constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Column k = cols[iid];
        ColumnOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        o.seed = hash12(float2(k.rect.x * 431.0, 7.3));
        o.size = float2((k.rect.z - k.rect.x) * view.x, k.rect.w - k.rect.y);
        return o;
    }
    fragment ColorDepth volcano_column_fragment(ColumnOut in [[stage_in]], constant float4& light [[buffer(0)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y;
        float x = in.uv.x, y = in.uv.y;
        float s1 = in.seed, s2 = fract(s1 * 7.31), s3 = fract(s1 * 13.17), s4 = fract(s1 * 5.17);
        float ax = 1.5 / max(in.size.x * 900.0, 1.0);
        float ay = 1.5 / max(in.size.y * 900.0, 1.0);
        // Packed basalt prisms seen side-on against the crater's glow: each fills its key, a dark joint between it and
        // the next; the prism's edge splits the face toward us in two (one turned a little to the light); its top broken
        // off at a slant, sometimes with a chipped step.
        float side = min(x, 1.0 - x);
        float top = 0.64 + 0.32 * s3 + (s2 - 0.5) * 0.3 * (x - 0.5);
        if (s4 > 0.45) top -= 0.07 * smoothstep(-ax, ax, (x - (0.25 + 0.5 * fract(s4 * 3.7))) * (s2 > 0.5 ? 1.0 : -1.0));
        float body = smoothstep(top + ay, top - ay, y);
        if (body < 0.004) discard_fragment();
        float edgeX = 0.3 + 0.4 * s2;
        float faceA = smoothstep(edgeX - ax, edgeX + ax, x);
        float faceLight = mix(0.1, 0.2, s2 > 0.5 ? faceA : 1.0 - faceA);
        float jointSide = smoothstep(0.0, black ? 0.12 : 0.08, side);
        float cross = smoothstep(0.44, 0.485, abs(fract(y * 2.3 + s1 * 3.0 + (x - 0.5) * (s3 - 0.5) * 0.3) - 0.5));
        float grain = vn2(float2(x * 5.0 + s1 * 30.0, y * 16.0)) * 0.6 + 0.4 * vn2(float2(x * 13.0, y * 41.0 + s1 * 9.0));
        float3 rock = float3(0.042, 0.038, 0.035) * (0.65 + 0.7 * grain) * (1.0 - 0.5 * cross) * (black ? 0.75 : 1.0);
        // The glow from beyond rims the broken top and the prism's edge; the faces are in shade but for the sky and the
        // lit plume overhead.
        float rim = exp(-max(top - y, 0.0) / 0.03);
        float ridge = exp(-abs(x - edgeX) / 0.04) * 0.25;
        float3 c = rock * light.rgb * (faceLight * (0.4 + 0.6 * y) + 1.3 * rim + ridge);
        c *= 0.25 + 0.75 * jointSide;
        // A note heats it from inside: lava glowing in its cross joints, its sides and its broken top, the face warming.
        float T = 760.0 + 400.0 * glow;
        float inv = 1.0 / T;
        float3 bb = float3(1.0, exp(0.38 - 1848.0 * inv), exp(2.036 - 8727.0 * inv)) * exp((T - 1150.0) * 0.0086957);
        float hotTop = exp(-max(top - y, 0.0) / 0.05);
        float hot = cross * 0.9 + (1.0 - jointSide) * 0.6 + hotTop * 0.8 + 0.08 * (0.5 + grain);
        c += bb * (hot * smoothstep(0.0, 0.2, glow) * (0.35 + 0.65 * glow));
        ColorDepth o;
        o.color = float4(c * body, body);
        o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
