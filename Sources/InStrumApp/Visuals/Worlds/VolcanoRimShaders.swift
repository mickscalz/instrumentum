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
        float4 dims3;    // breach half-width (rad), fountain pool scale, foreground top (NDC), keys shown 0/1
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
    /// Incandescence at a temperature (kelvin): the blackbody's chroma (G/R and B/R fitted to the CIE locus under D65,
    /// 1000–3000 K), times an intensity that rises e-fold every 115 K from 1 at 1150 K, a long exposure's compression of
    /// Planck's far steeper climb: old crust (600 K) is all but black, cracks (1100–1300 K) orange, a fountain's heart
    /// (1450 K) bright enough that the tone curve takes it to yellow-white.
    float3 blackbody(float T) {
        float t = clamp(T, 450.0, 2200.0);
        float inv = 1.0 / t;
        float g = exp(0.835 - 4065.0 * inv);
        float b = exp(4.48 - 19200.0 * inv);
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
        float3 toLake = float3(-P.xy * 0.75, u.eye.w + 12.0 - P.z);
        float dl = length(toLake);
        float3 L = toLake / max(dl, 1e-3);
        float disc = R * R / (R * R + dl * dl);
        float facing = saturate(0.15 + 0.85 * dot(N, L));
        float3 lake = u.glow.rgb * (2.6 * disc * facing);
        // The margin: a ring of spatter at the lake's edge, lighting what stands near it.
        float rp = length(P.xy);
        float toRing = max(abs(rp - R), 0.0);
        float ring = u.glow.w * 0.35 / (1.0 + sq(toRing / 30.0) + sq(max(P.z, 0.0) / 40.0));
        float3 margin = u.glow.rgb * ring * saturate(0.3 + 0.7 * dot(N, normalize(float3(-P.xy, 6.0))));
        // The plume over the lake's middle, lit from below: an orange light from above and ahead.
        float3 toPlume = float3(-P.x + 30.0, -P.y, 140.0 - P.z);
        float dp = length(toPlume);
        float3 Lp = toPlume / max(dp, 1e-3);
        float3 plume = u.glow.rgb * float3(1.0, 0.82, 0.7) * (0.7 * u.plume.x * 160.0 * 160.0 / (160.0 * 160.0 + dp * dp))
                     * saturate(0.25 + 0.75 * dot(N, Lp));
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

    /// How high the cliffs stand at an angle round the wall centre: the breach's notch cuts them to the floor.
    float notchCut(float theta, constant VolcanoU& u) {
        float off = abs(theta - u.dims2.w);
        float hw = u.dims3.x;
        return smoothstep(hw * 0.45, hw * 1.15, off);
    }

    /// The cliffs' ragged top edges (m above their nominal tops): boulders and spatter on the lip.
    float lipRag(float theta, float scale) {
        float a = theta * 57.0;
        return (vn2(float2(a, scale)) - 0.5) * 6.0 + (vn2(float2(a * 4.3, scale + 3.0)) - 0.5) * 2.4
             + smoothstep(0.62, 0.9, vn2(float2(a * 0.37, scale + 7.0))) * 7.0;
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
            if (r < u.dims.x) {
                h.kind = length(p.xy) < u.lake.x ? 1 : 2;
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
            float top = rimH + lipRag(th, 5.0);
            float cut = notchCut(th, u);
            top = mix(lakeZ - 1.0, top, cut);
            if (p.z >= u.dims.y - 2.0 && p.z <= top) { h.kind = 3; h.t = tB; h.p = p; h.theta = th; }
        }
        return h;
    }

    // ---------------------------------------------------------------- the lava lake
    /// The crust's Voronoi through a two-scale warp: the nearest seed `i1`, the neighbour across the nearest crack `i2`,
    /// the distance to it (m) and the crack's normal (in the lake's plane).
    struct Plates { int i1; int i2; float border; float2 n; float2 q; };

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
        float border = 1e9;
        int i2 = i1;
        float2 nrm = float2(1, 0);
        for (int k = 0; k < 64; k++) {
            if (k == i1) continue;
            float2 c = u.cellA[k].xy;
            float2 n = c - c1;
            float ln = length(n);
            if (ln < 1e-3) continue;
            n /= ln;
            float dist = dot(0.5 * (c1 + c) - q, n);
            if (dist < border) { border = dist; i2 = k; nrm = n; }
        }
        r.i1 = i1; r.i2 = i2; r.border = max(border, 0.0); r.n = nrm;
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

    /// The lake's own light at a point of its surface (crater metres), seen along d from `t` away; J is the pixel's
    /// footprint (lake metres per pixel across x and y).
    float3 lakeSurface(float3 P, float3 d, float2 Jx, float2 Jy, constant VolcanoU& u, int oct) {
        float2 p = P.xy;
        float R = u.lake.x;
        float energy = u.play.x;
        Plates pl = plates(p, u);
        float4 A = u.cellA[pl.i1], B = u.cellA[pl.i2];
        float4 Ab = u.cellB[pl.i1], Bb = u.cellB[pl.i2];
        // The pixel's footprint across the crack.
        float fn = length(float2(dot(Jx, pl.n), dot(Jy, pl.n)));
        float foot = max(length(Jx), length(Jy));
        // This crack's character: some run wide and hot (spreading), each wanders in width along its length.
        float lo = float(min(pl.i1, pl.i2)), hi = float(max(pl.i1, pl.i2));
        float pair = hash12(float2(lo * 7.13, hi * 3.71));
        float heat = 0.5 * (A.w + B.w);
        float note = max(A.z, B.z);
        float along = vn2(pl.q * 0.07 + pair * 31.0);
        float width = u.lake.z * (0.25 + 0.75 * pair) * (0.55 + 0.9 * heat) * (0.35 + 1.3 * along);
        // A crack between two plates just split apart opens as they part.
        bool twins = int(Ab.y) == pl.i2 || int(Bb.y) == pl.i1;
        float open = twins ? smoothstep(0.0, 1.0, min(Ab.x, Bb.x)) : 1.0;
        float T = u.temps.x + 110.0 * pair + 140.0 * heat + 150.0 * energy + 230.0 * note + 90.0 * u.play.w;
        float3 crack = blackbody(T) * lineLight(pl.border, width, fn)
                     + blackbody(T - 190.0) * (0.55 * lineLight(pl.border, width * 5.0 + 1.2, fn));
        crack *= open;
        // The crust: old plates black, young ones (near the spreading centre) a dull red, thinner (glowing) toward the
        // cracks; ropy folds across the flow; the fine cracks of the plate's skin, livelier with Energy.
        float2 local = p - A.xy + float2(hash12(float2(float(pl.i1), 1.7)) * 97.0, hash12(float2(float(pl.i1), 4.1)) * 61.0);
        float skin = fbm2(local * 0.11, oct);
        float Tc = mix(u.temps.z, u.temps.y, A.w) + 70.0 * (skin - 0.5) + 60.0 * energy;
        Tc += 180.0 * exp(-pl.border / (2.5 + 4.0 * A.w));
        float3 crust = blackbody(Tc);
        float fine = fineCracks(local, 7.0 + 5.0 * (1.0 - A.w));
        float fineT = Tc + 230.0 + 120.0 * u.temps.w + 90.0 * note;
        crust += blackbody(fineT) * (0.6 * lineLight(fine, 0.18 + 0.1 * A.w, foot)) * (0.35 + 0.65 * u.temps.w);
        // Sheen: the glassy crust mirrors the plume's glow above, more at grazing angles, less where it's rough.
        float grazing = 1.0 - saturate(-d.z);
        float g2 = grazing * grazing;
        float fres = 0.045 + 0.955 * g2 * g2 * grazing;
        float rough = smoothstep(0.3, 0.75, fbm2(local * 0.35 + float2(2.0, 9.0), oct));
        float sheen = fres * (0.55 - 0.4 * rough) * smoothstep(-60.0, 120.0, p.y);
        float3 col = crust + crack + u.glow.rgb * float3(1.0, 0.85, 0.75) * (0.85 * sheen * u.plume.x);
        // The fountains' pools of fresh lava, churning.
        for (int k = 0; k < 2; k++) {
            float4 f = k == 0 ? u.fountA : u.fountB;
            float rp = (9.0 + 0.45 * f.z) * u.dims3.y;
            float dist = length(p - f.xy);
            float pool = 1.0 - smoothstep(rp * 0.5, rp * 1.25, dist + 6.0 * (vn2(p * 0.15 + u.a.y * 0.4) - 0.5));
            float churn = vn2(p * 0.3 + float2(u.a.y * 0.9, -u.a.y * 0.6));
            float Tp = 1240.0 + 110.0 * f.w + 70.0 * churn + 60.0 * energy;
            col = mix(col, blackbody(Tp), pool);
        }
        // The margin: torn crust and spatter where the lake meets the floor.
        float r = length(p);
        float edge = R - r;
        float spatter = vn2(float2(atan2(p.y, p.x) * 60.0, u.a.y * 0.7));
        float wm = 1.6 + 2.2 * spatter;
        float Tm = 1120.0 + 120.0 * u.glow.w + 90.0 * spatter;
        col += blackbody(Tm) * lineLight(abs(edge - 1.0), wm, foot);
        // The breach's new river leaves the lake here: the lake's own crust torn open toward it.
        float2 rs = u.riverA.xy;
        float toMouth = length(p - rs);
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
        // Old black lava: ropy, a little glassy, here and there a skylight onto hot lava beneath.
        float rope = fbm2(p * float2(0.09, 0.05) + float2(3.0, 1.0), oct);
        float3 albedo = float3(0.055, 0.05, 0.048) * (0.65 + 0.7 * rope);
        float3 N = normalize(float3((rope - 0.5) * 0.5, (vn2(p * 0.07) - 0.5) * 0.5, 1.0));
        float3 col = albedo * craterLight(P, N, u) + albedo * u.skyL.rgb;
        float sky = smoothstep(0.82, 0.9, vn2(p * 0.045 + float2(7.0, 2.0))) * vn2(p * 0.3);
        col += blackbody(1000.0 + 120.0 * u.play.x) * (0.25 * sky);
        // The river: a channel of crusted lava (bright where its crust tears) running to the breach, its levees lit.
        float2 rd = riverDistance(p, u);
        float flow = u.river.x, breach = u.river.z;
        float half = 5.0 + 5.0 * flow + 16.0 * breach;
        float inside = 1.0 - smoothstep(half - max(1.0, foot), half + max(1.0, foot), rd.x);
        if (inside > 0.0) {
            float along = rd.y * 120.0 - u.river.y * 0.6;
            float2 rp = float2(along, rd.x * 0.35);
            float crustNet = fineCracks(rp + float2(13.0, 5.0), 3.5);
            float run = vn2(float2(along * 0.4, rd.x * 0.2));
            float Tr = 760.0 + 260.0 * flow + 520.0 * breach + 80.0 * run;
            float3 river = blackbody(Tr) + blackbody(1150.0 + 60.0 * flow + 200.0 * breach) * lineLight(crustNet, 0.35, foot) * 0.8;
            river += blackbody(1180.0) * (exp(-abs(rd.x - half * 0.85) / 1.5) * (0.3 + 0.7 * flow));
            col = mix(col, river, inside);
        }
        col += blackbody(1100.0 + 150.0 * breach) * (exp(-max(rd.x - half, 0.0) / 9.0) * (0.12 + 0.2 * flow + 0.6 * breach) * 0.25);
        // Lava tree (a surprise): a pillar left standing as the river drops, glowing at its foot.
        return col;
    }

    float3 wallColour(Hit h, float3 d, constant VolcanoU& u, int oct, float foot) {
        float3 P = h.p;
        float2 C = u.dims2.xy;
        float2 q = P.xy - C;
        float r = length(q);
        float th = h.theta;
        // Layered basalt: flows stacked in bands of their own colour (some oxidised red-brown), cut by gullies, a talus
        // of rubble at the foot; relief lit from below by the lake.
        float arc = th * r;   // metres round the wall
        float z = P.z;
        float wob = (fbm2(float2(arc * 0.02, z * 0.01), oct) - 0.5) * 9.0;
        float layer = z + wob;
        float band = vn2(float2(layer * 0.22, 3.0));
        float fineBand = vn2(float2(layer * 1.1, arc * 0.004 + 9.0));
        float gully = fbm2(float2(arc * 0.06, z * 0.012 + 4.0), oct);
        float3 basalt = mix(float3(0.06, 0.055, 0.052), float3(0.11, 0.075, 0.055), smoothstep(0.55, 0.8, band));
        basalt *= 0.7 + 0.45 * fineBand;
        // Relief: the face's normal leans with the gullies and the ledges between the bands.
        float ledge = smoothstep(0.35, 0.65, fract(layer * 0.09)) - 0.5;
        float3 inward = float3(-q / max(r, 1e-3), 0.0);
        float3 tangent = float3(inward.y, -inward.x, 0.0);
        float3 N = normalize(inward + tangent * ((gully - 0.5) * 1.4) + float3(0, 0, ledge * 0.9 + (h.kind == 4 ? 4.0 : 0.0)));
        float talus = h.kind == 3 ? (1.0 - smoothstep(0.0, 14.0 + 10.0 * gully, z - (z > u.dims.y ? u.dims.y : 0.0))) : 0.0;
        float rubble = vn2(float2(arc * 0.5, z * 0.5));
        basalt = mix(basalt, float3(0.07, 0.06, 0.055) * (0.6 + 0.8 * rubble), talus);
        if (h.kind == 4) basalt = float3(0.07, 0.06, 0.055) * (0.6 + 0.6 * vn2(P.xy * 0.2));
        float3 col = basalt * (craterLight(P, N, u) + u.skyL.rgb);
        // The breach's notch: its cut faces lit by the river pouring through.
        float off = abs(th - u.dims2.w);
        float near = 1.0 - smoothstep(u.dims3.x * 0.5, u.dims3.x * 2.2, off);
        float riverLight = (0.15 + 0.35 * u.river.x + 2.5 * u.river.z) * near * exp(-max(z, 0.0) / 35.0);
        col += basalt * u.glow.rgb * riverLight * 3.0;
        // Hot seams in the old walls, here and there, livelier with Energy.
        float seam = smoothstep(0.93, 0.97, vn2(float2(arc * 0.09, layer * 0.3))) * (1.0 - smoothstep(0.0, 60.0, z));
        col += blackbody(980.0 + 120.0 * u.play.x) * (0.12 * seam);
        return col;
    }

    // ---------------------------------------------------------------- fountains, the column and the plume
    /// A fountain's spatter dome on its own plane through its site, facing the camera: a bright jet in the middle and
    /// clots flung out to its parabolic envelope; returns light (rgb) and cover (a).
    float4 fountain(float3 o, float3 d, float4 f, constant VolcanoU& u, float tMax) {
        if (f.z < 0.5 || d.y < 1e-4) return float4(0);
        float t = (f.y - o.y) / d.y;
        if (t <= 0.0 || t >= tMax) return float4(0);
        float3 P = o + d * t;
        float x = P.x - f.x;
        float z = P.z - u.eye.w;
        float H = f.z, W = 0.55 * f.z + 6.0;
        if (z < -2.0 || z > H * 1.2 || abs(x) > W * 1.4) return float4(0);
        float s = x / W;
        float env = H * (1.0 - s * s);
        float body = smoothstep(env + 1.5, env - 4.0, z) * smoothstep(-1.5, 1.5, z) * (1.0 - smoothstep(0.9, 1.15, abs(s)));
        float core = exp(-s * s / 0.06) * smoothstep(H * 1.05, H * 0.5, z);
        float clots = smoothstep(0.62, 0.9, vn2(float2(x * 0.9, z * 0.9 - u.a.y * 9.0) + f.w * 5.0));
        float dens = saturate(0.85 * core + 0.9 * clots * body + 0.25 * body);
        float T = 1180.0 + 230.0 * core + 60.0 * f.w - 160.0 * saturate(z / max(H, 1.0)) * (1.0 - core);
        return float4(blackbody(T) * dens, dens);
    }

    /// The eruption's column, out of the lake's middle to far above the frame: a white-hot core, ragged orange edges
    /// throwing clots.
    float4 column(float3 P, constant VolcanoU& u) {
        float H = u.erupt.x;
        if (H <= 1.0) return float4(0);
        float z = P.z - u.eye.w;
        if (z < -2.0 || z > H) return float4(0);
        float w = 24.0 + 0.03 * z + 14.0 * u.erupt.w;
        float wob = (vn2(float2(z * 0.03 - u.a.y * 3.0, 1.0)) - 0.5) * 18.0;
        float x = P.x - wob;
        float s = x / w;
        float rag = vn2(float2(z * 0.08 - u.a.y * 12.0, x * 0.2));
        float body = smoothstep(1.0 + 0.5 * rag, 0.4, abs(s));
        float clots = smoothstep(0.7, 0.92, vn2(float2(x * 0.25, z * 0.2 - u.a.y * 30.0))) * smoothstep(2.2, 0.9, abs(s));
        float topFade = 1.0 - smoothstep(H * 0.8, H, z);
        float dens = saturate(body + 0.8 * clots) * topFade;
        float T = 1250.0 + 220.0 * exp(-s * s / 0.15) - 120.0 * saturate(abs(s) - 0.6);
        return float4(blackbody(T) * dens * (0.6 + 0.4 * u.erupt.y), dens);
    }

    /// The plume on its plane through the lake's middle: a column of gas and ash rising and spreading, bent by the wind,
    /// its billows lit from below by the lake (bright undersides, darker crowns); `tMax` the scene behind it.
    float4 plume(float3 P, constant VolcanoU& u, int oct, float3 lightCol) {
        float z = P.z - u.eye.w;
        float amount = u.plume.x;
        if (amount <= 0.01 || z < -5.0) return float4(0);
        float bend = u.plume.z * z * z;
        float W = (70.0 + 0.55 * z) * (0.75 + 0.5 * amount) * (1.0 + 0.35 * u.plume.y);
        float x = P.x - bend;
        float s = x / W;
        if (abs(s) > 1.6) return float4(0);
        // Billows rising: the field scrolls up with the plume's rise and grows with height, so each lobe swells as it
        // climbs; warped so they never line up.
        float rise = u.plume.w;
        float scale = 1.0 / (55.0 + 0.35 * max(z, 0.0));
        float2 g = float2(x * scale, (z - rise) * scale);
        float2 wq = float2(vn2(g * 1.7 + float2(4.0, rise * 0.004)), vn2(g * 1.7 + float2(9.0, 2.0 - rise * 0.003))) - 0.5;
        g += wq * 0.9;
        float n = fbm2(g * 2.2, oct);
        float nl = fbm2((g + float2(0.0, -0.18)) * 2.2, oct);
        float profile = smoothstep(1.25, 0.15, abs(s) + 0.35 * (n - 0.5));
        float base = smoothstep(-5.0, 35.0, z);
        float dens = saturate((n * 1.35 - 0.28) * profile * base * (0.6 + 0.6 * amount));
        if (dens <= 0.002) return float4(0);
        float chord = sqrt(saturate(1.0 - s * s * 0.6));
        float alpha = 1.0 - exp(-dens * chord * 3.2);
        // Lit from below: brightest at its foot (the lake's disc), lobes' undersides catching it, crowns in shade.
        float R = u.lake.x;
        float fall = R * R / (R * R + sq(max(z, 0.0) + 40.0));
        float under = saturate(0.55 + 2.4 * (n - nl));
        float3 lit = lightCol * float3(1.0, 0.8, 0.66) * (0.42 * fall * (0.35 + 0.9 * under));
        lit += float3(0.018, 0.02, 0.026) * u.skyL.w + u.skyL.rgb * 0.4;
        // Lightning inside it: a blue-white glow round the stroke.
        float2 b = float2(x + bend - u.bolt.y, z - u.bolt.z);
        lit += float3(0.75, 0.75, 1.0) * (u.bolt.x * 2.2 * exp(-dot(b, b) / (2.0 * 70.0 * 70.0)));
        // The column inside it lights it hard.
        lit += u.glow.rgb * (u.erupt.y * 1.4 * exp(-abs(P.x) / 120.0) * smoothstep(u.erupt.x + 50.0, 0.0, z));
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
        float tau = integral * 0.0032 * overLake * (0.45 + 1.1 * churn) * (0.6 + 0.6 * u.plume.x);
        float T = exp(-tau);
        float3 light = u.glow.rgb * float3(1.0, 0.78, 0.62) * (1.0 - T) * 0.85;
        return float4(light, T);
    }

    // ---------------------------------------------------------------- the sky and beyond
    float3 beyond(float3 dE, float3 d, constant SkyU& sky, constant VolcanoU& u, texture2d<float> stars, float2 ndc) {
        float3 col;
        float el = asin(clamp(d.z, -1.0, 1.0));
        float az = atan2(d.x, d.y);
        if (dE.z >= 0.0) {
            float moonMask = 0.0;
            col = skyRadiance(dE, sky, moonMask, stars);
        } else {
            // The dark plain far below, the horizon's haze over it.
            col = sky.horizon.rgb * 0.25 * exp(dE.z * 40.0);
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
            float sx = (az + 0.62) / 0.16;
            float tower = smoothstep(1.0, 0.2, abs(sx)) * smoothstep(0.06 + 0.02 * vn2(float2(sx * 3.0, 1.0)), 0.0, el);
            float flick = u.sprites.x > 0.0 ? u.sprites.x : 0.0;
            col = mix(col, col * 0.4, tower * 0.7 * st);
            col += float3(0.7, 0.72, 1.0) * (tower * flick * 0.25);
        }
        if (u.sprites.x > 0.0) {
            float b = u.sprites.y * 0.0174533;
            float sxp = (az - b) / 0.012;
            float sy = (el - 0.105) / 0.03;
            float col1 = exp(-sxp * sxp) + 0.6 * exp(-sq(sxp - 2.1)) + 0.5 * exp(-sq(sxp + 1.7));
            float crown = exp(-sy * sy) * smoothstep(-2.5, 0.0, sy);
            float tendril = exp(-sq(sy + 1.6) / 1.2) * (0.5 + 0.5 * sin(sxp * 9.0));
            float3 red = float3(1.0, 0.12, 0.25) * crown + float3(0.45, 0.25, 1.0) * tendril * 0.35;
            col += red * (col1 * u.sprites.x * 0.04);
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
        float3 light = u.glow.rgb * float3(1.0, 0.8, 0.65) * (0.9 * rim + 0.1) + u.skyL.rgb;
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
        }
        // What stands over the lake, nearest last: the fountains, then the column and the plume on the middle plane.
        float tHit = h.kind == 0 ? 1e9 : h.t;
        float4 fa = fountain(o, d, u.fountA, u, tHit);
        float4 fb = fountain(o, d, u.fountB, u, tHit);
        float ta = (u.fountA.y - o.y) / max(d.y, 1e-4), tb = (u.fountB.y - o.y) / max(d.y, 1e-4);
        float tm = (0.0 - o.y) / max(d.y, 1e-4);
        float4 far = ta > tb ? fa : fb, nearF = ta > tb ? fb : fa;
        float farT = max(ta, tb);
        float4 mid = float4(0);
        float4 pl = float4(0);
        if (tm < tHit && tm > 0.0) {
            float3 P = o + d * tm;
            mid = column(P, u);
            pl = plume(P, u, oct, u.glow.rgb);
        }
        if (farT > tm) {
            col = col * (1.0 - far.a) + far.rgb;
            col = col * (1.0 - mid.a) + mid.rgb;
            col = col * (1.0 - pl.a) + pl.rgb;
            col = col * (1.0 - nearF.a) + nearF.rgb;
        } else {
            col = col * (1.0 - mid.a) + mid.rgb;
            col = col * (1.0 - pl.a) + pl.rgb;
            col = col * (1.0 - far.a) + far.rgb;
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
    struct Spark { float4 at; float4 info; };   // centre (NDC xy), its travel on screen (NDC xy); half size (NDC y), temperature (K), light, softness
    struct SparkOut { float4 pos [[position]]; float2 uv; float3 col; float soft; float len; };
    vertex SparkOut volcano_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Spark* sparks [[buffer(0)]],
                                         constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        Spark s = sparks[iid];
        float2 v = float2(s.at.z * view.x, s.at.w);
        float speed = length(v);
        float2 dir = speed > 1e-6 ? v / speed : float2(0, 1);
        float2 side = float2(-dir.y, dir.x);
        float half = max(s.info.x, 1e-5);
        float L = 0.5 * speed / half;                 // the streak's half-length past the head, in sizes
        float2 q = c[vid] * 1.6;
        float2 off = dir * (q.y * half * (1.0 + L)) + side * (q.x * half);
        SparkOut o;
        o.pos = float4(s.at.xy + float2(off.x / view.x, off.y) + view.yz, 0, 1);
        o.uv = float2(q.x, q.y * (1.0 + L));
        float t = clamp(s.info.y, 450.0, 2200.0);
        float inv = 1.0 / t;
        float3 bb = float3(1.0, exp(0.835 - 4065.0 * inv), exp(4.48 - 19200.0 * inv)) * exp((t - 1150.0) * 0.0086957);
        o.col = bb * (s.info.z / (1.0 + 0.8 * L));
        o.soft = s.info.w;
        o.len = L;
        return o;
    }
    fragment float4 volcano_spark_fragment(SparkOut in [[stage_in]]) {
        float2 p = in.uv;
        float dy = max(abs(p.y) - in.len, 0.0);
        float r2 = p.x * p.x + dy * dy;
        float sharp = exp(-r2 * 3.0);
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
        float s1 = in.seed, s2 = fract(s1 * 7.31), s3 = fract(s1 * 13.17);
        // A basalt column seen from the side: its faces (a lit one and a shaded one), its top broken off at a slant,
        // the joints across it; a black key's column stands shorter and further back.
        float halfW = 0.42 + 0.05 * s2;
        float cx = 0.5 + (s3 - 0.5) * 0.08;
        float across = (x - cx) / halfW;
        float aa = 1.5 / max(in.size.x * 1000.0, 1.0);
        float body = smoothstep(1.0 + aa, 1.0 - aa, abs(across));
        float top = 0.93 - 0.05 * s3 - 0.06 * across * (s2 > 0.5 ? 1.0 : -1.0);
        body *= smoothstep(top + 0.01, top - 0.01, y);
        if (body < 0.004) discard_fragment();
        float face = across < (s2 - 0.5) * 0.4 ? 0.55 : 1.0;
        float joint = smoothstep(0.03, 0.0, abs(fract(y * 3.0 + s1 * 3.0) - 0.5) - 0.47);
        float grain = vn2(float2(across * 5.0 + s1 * 30.0, y * 18.0));
        float3 rock = float3(0.05, 0.046, 0.044) * (0.7 + 0.6 * grain) * face * (1.0 - 0.5 * joint) * (black ? 0.75 : 1.0);
        // Lit by the crater ahead: the top edge catches the glow.
        float rim = exp(-(top - y) / 0.06);
        float3 c = rock * (light.rgb * (0.35 + 1.4 * rim)) ;
        // A note lights its column from inside: lava in its joints and its broken top, cooling as it fades.
        float T = 820.0 + 520.0 * glow;
        float inv = 1.0 / T;
        float3 bb = float3(1.0, exp(0.835 - 4065.0 * inv), exp(4.48 - 19200.0 * inv)) * exp((T - 1150.0) * 0.0086957);
        float seams = joint * smoothstep(0.0, 0.3, glow) + exp(-abs(y - top + 0.02) / 0.03) * glow;
        float crack = smoothstep(0.08, 0.0, abs(across - 0.3 * sin(y * 7.0 + s1 * 6.0)) - 0.02) * glow;
        c += bb * (seams + 0.8 * crack) * glow;
        ColorDepth o;
        o.color = float4(c * body, body);
        o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
