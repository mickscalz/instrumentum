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
        float4 sprites;  // the plume drawn at half size (1; else drawn here), the plates' map is whole 0/1, 3 + the line
                         // (NDC y) below which the keys' columns hide the scene (0: none), layers a timing test skips (0)
        float4 tree;     // progress (< 0 none), share along the river, seed, 0
        float4 dims;     // foot radius, bench height, bench radius, top radius (m)
        float4 dims2;    // wall centre (m xy), rim height (m), breach angle (rad)
        float4 dims3;    // breach halfW-width (rad), fountain pool scale, foreground top (NDC), keys shown 0/1
        float4 riverA;   // river start (m xy), river end (m xy)
        float4 cellA[64];  // crust seeds: place (m xy), a note's glow, young heat
        float4 cellB[64];  // birth 0…1, the twin it split from (index; −1 none), its plate's weight (m²), 0
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

    /// The eruption's fountain's head (m over the lake; 0: none): 130–230 m with its strength (within the frame; the
    /// column the model raises is far taller), up as its column is.
    float fountainTop(constant VolcanoU& u) {
        if (u.erupt.z < 0.0 || u.erupt.z > 9.0) return 0.0;
        float sp = clamp(u.erupt.w, 0.3, 1.0);
        float peak = (3.0 + 3.0 * (sp - 0.3) / 0.7) * 2.0 * u.lake.x;
        return (130.0 + 100.0 * sp) * saturate(u.erupt.x / peak);
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
        float low = 0.1 + 0.9 * exp(-h / 55.0);
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
        // The eruption's fountain: a tall source of its own over the lake's middle, warm on the faces turned to it.
        float Hj = fountainTop(u);
        float3 fount = float3(0);
        if (Hj > 1.0 && u.erupt.y > 0.0) {
            float3 toF = float3(-P.x, -P.y, lakeZ + 0.45 * Hj - P.z);
            float df = length(toF);
            float Rf = 60.0 + 0.3 * Hj;
            fount = blackbody(1240.0) * (u.erupt.y * 4.0 * Rf * Rf / (Rf * Rf + df * df)
                                         * saturate(0.25 + 0.75 * dot(N, toF / max(df, 1e-3))));
        }
        return lake + margin + plume + fount;
    }

    // ---------------------------------------------------------------- the crater's shape
    struct Hit { int kind; float t; float3 p; float theta; float edge; };   // kind: 0 beyond, 1 lake, 2 floor, 3 cliff, 4 bench;
                                                                            // edge: the lake's edge toward p (lake, floor)

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
        float away = abs(theta - u.dims2.w);
        // (Its sides wander 0.175 × the half-width at most (the noise is 0…1): farther round the wall stands whole whatever
        // the noise, so none is read there.)
        if (away >= hw * 1.6) return 1.0;
        float off = away + hw * 0.35 * (vn2(float2(theta * 120.0, 2.0)) - 0.5);
        return smoothstep(hw * 0.45, hw * 1.4, off);
    }

    /// The cliffs' ragged top edges (m above their nominal tops): boulders and spatter on the lip.
    float lipRag(float theta, float scale) {
        float a = theta * 57.0;
        return (vn2(float2(a * 0.09, scale + 11.0)) - 0.5) * 34.0 + (vn2(float2(a * 0.3, scale + 5.0)) - 0.5) * 12.0
             + (vn2(float2(a, scale)) - 0.5) * 6.0 + (vn2(float2(a * 4.3, scale + 3.0)) - 0.5) * 2.4
             + smoothstep(0.6, 0.9, vn2(float2(a * 0.37, scale + 7.0))) * 9.0;
    }

    /// The lake's edge (its radius, m) toward a point: a ragged shore of old spatter, never a drawn ellipse. It is
    /// lopsided (reaching farther to the left and the far side), bitten by two bays where the lake has eaten into the
    /// floor, and a ledge of solid crust juts into it from the right.
    float lakeEdge(float2 p, constant VolcanoU& u) {
        float R = u.lake.x;
        float a = atan2(p.y, p.x);
        float arc = a * R;
        float e = R + 46.0 * (vn2(float2(arc * 0.007, 1.3)) - 0.5) + 18.0 * (vn2(float2(arc * 0.022, 4.1)) - 0.5)
                + 6.0 * (vn2(float2(arc * 0.09, 7.7)) - 0.5);
        // Lopsided: the lake's middle is not the crater's.
        e += 42.0 * cos(a - 2.4) + 14.0 * cos(2.0 * a + 0.7);
        // The bays (angles wrapped to −π…π about each).
        float b1 = a - 2.35; b1 -= 6.2831853 * floor((b1 + 3.14159265) / 6.2831853);
        float b2 = a - 1.05; b2 -= 6.2831853 * floor((b2 + 3.14159265) / 6.2831853);
        float b3 = a + 0.25; b3 -= 6.2831853 * floor((b3 + 3.14159265) / 6.2831853);
        float b4 = a + 1.2; b4 -= 6.2831853 * floor((b4 + 3.14159265) / 6.2831853);
        float b5 = a + 2.05; b5 -= 6.2831853 * floor((b5 + 3.14159265) / 6.2831853);
        e += 60.0 * exp(-b1 * b1 / 0.06) + 40.0 * exp(-b2 * b2 / 0.03) + 35.0 * exp(-b4 * b4 / 0.05);
        // The ledge: a tongue of crust from the right shore, narrow and blunt-ended; a spit of old spatter near the left.
        // (Each shelf's noise is read only within its reach: farther round it takes off under 2e-7 m, which an edge of
        // a few hundred metres doesn't hold in a float, so the edge is the same.)
        if (b3 * b3 < 0.2) e -= 95.0 * exp(-b3 * b3 / 0.01) * (0.8 + 0.4 * vn2(float2(arc * 0.05, 3.0)));
        e -= 50.0 * exp(-b5 * b5 / 0.02);
        // A second, broader shelf of crust from the far shore, its end ragged.
        float b6 = a - 1.72; b6 -= 6.2831853 * floor((b6 + 3.14159265) / 6.2831853);
        if (b6 * b6 < 0.36) e -= 75.0 * exp(-b6 * b6 / 0.018) * (0.75 + 0.5 * vn2(float2(arc * 0.06, 9.0)));
        return e;
    }

    Hit craterHit(float3 o, float3 d, constant VolcanoU& u) {
        Hit h;
        h.kind = 0; h.t = 1e9; h.p = o + d * 1e4; h.theta = 0.0; h.edge = 0.0;
        float2 C = u.dims2.xy;
        float rimH = u.dims2.z;
        float lakeZ = u.eye.w;
        // The floor and the lake.
        if (d.z < -1e-5) {
            float t = (lakeZ - o.z) / d.z;
            float3 p = o + d * t;
            float r = length(p.xy - C);
            float2 qf = p.xy - C;
            if (r < u.dims.x || (r < 0.5 * (u.dims.z + u.dims.w) + 4.0 && notchCut(atan2(qf.x, qf.y), u) < 0.999)) {
                h.edge = lakeEdge(p.xy, u);   // (read once: the lake's margin and the floor's shore use it too)
                h.kind = length(p.xy) < h.edge ? 1 : 2;
                h.t = t; h.p = p;
            }
        }
        // The cliff above the floor (its top ragged, cut by the notch).
        float tA = cylinderFar(o, d, C, u.dims.x);
        // (Above the lip's highest reach, or below the lake, there is no cliff whatever the notch: its angle isn't
        // worked out there.)
        if (tA < h.t) {
            float3 p = o + d * tA;
            if (p.z >= lakeZ - 0.5 && p.z <= u.dims.y + 36.3) {
                float2 q = p.xy - C;
                float th = atan2(q.x, q.y);
                // (The lip's rag is −27.2…36.2 m (its noise is 0…1): a point outside that band round its top is in the
                // cliff or over it whatever the rag, which is read only where it decides; the hits are unchanged.)
                float cut = notchCut(th, u);
                bool cliff = false;
                if (p.z <= (u.dims.y + 36.3) * cut) {
                    cliff = p.z <= (u.dims.y - 27.3) * cut || p.z <= (u.dims.y + lipRag(th, 1.0)) * cut;
                }
                if (cliff) { h.kind = 3; h.t = tA; h.p = p; h.theta = th; }
            }
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
        // (Over the rim's highest reach nothing is hit here whatever the notch: its angle isn't worked out there. A
        // metre's margin, so the test below decides every point near it, rounded as it is there.)
        if (tB < h.t && o.z + d.z * tB < rimH + 37.3) {
            float3 p = o + d * tB;
            float2 q = p.xy - C;
            float th = atan2(q.x, q.y);
            float cut = notchCut(th, u);
            // (As above: the rim's rag is read only where it decides; the hits are unchanged.)
            bool below = p.z < rimH - 27.3, above = p.z >= rimH + 36.3;
            bool upper = false;
            if (p.z >= u.dims.y - 2.0 && p.z <= mix(lakeZ - 1.0, rimH + 36.3, cut)) {
                upper = p.z <= mix(lakeZ - 1.0, rimH - 27.3, cut) || p.z <= mix(lakeZ - 1.0, rimH + lipRag(th, 5.0), cut);
            }
            if (upper) { h.kind = 3; h.t = tB; h.p = p; h.theta = th; }
            else if (h.kind == 0 && p.z < u.dims.y - 2.0 && p.z > lakeZ - 1.0) { h.kind = 3; h.t = tB; h.p = p; h.theta = th; }
            else if (h.kind == 0 && cut < 0.999 && !above && (below || p.z < rimH + lipRag(th, 5.0))) {
                h.kind = 5; h.t = tB; h.p = p; h.theta = th;
            }
        }
        return h;
    }

    // ---------------------------------------------------------------- the lava lake
    /// The crust's plates: a power diagram of the model's 64 seeds (each seed its own weight, so the plates run from
    /// small to big), measured in a frame stretched along the drift away from the spreading centre (so the plates are
    /// drawn out along it), looked up through a two-scale domain warp (so the cracks run torn and ragged). For the
    /// nearest plate `i1`: the two nearest cracks (the plates across them, real distances in metres, their normals).
    struct Plates { int i1; int i2; int i3; float border; float border2; float2 n; float2 n2; float2 q; };

    Plates plates(float2 p, constant VolcanoU& u) {
        float2 q0 = p * 0.028;
        float2 w1 = float2(vn2(q0 + float2(3.1, 7.7)), vn2(q0 + float2(11.3, 1.9))) - 0.5;
        float2 q1 = p * 0.14;
        float2 w2 = float2(vn2(q1 + float2(5.2, 3.3)), vn2(q1 + float2(9.4, 6.1))) - 0.5;
        float2 q = p + w1 * 26.0 + w2 * 5.0;
        // The drift's frame here (VolcanoCrater.upwelling is the spreading centre): distances along it count for less.
        float2 off = q - float2(-40.0, 30.0);
        float lo = length(off);
        float2 dir = lo > 1e-3 ? off / lo : float2(1, 0);
        float2 perp = float2(-dir.y, dir.x);
        const float squeeze = 0.6;
        Plates r;
        r.q = q;
        int i1 = 0;
        float best = 1e12;
        float2 t1 = float2(0);
        for (int k = 0; k < 64; k++) {
            float2 dl = u.cellA[k].xy - q;
            float2 t = float2(dot(dl, dir) * squeeze, dot(dl, perp));
            float P = dot(t, t) - u.cellB[k].z;
            if (P < best) { best = P; i1 = k; t1 = t; }
        }
        float lt1 = length(t1);
        float border = 1e9, border2 = 1e9;
        int i2 = i1, i3 = i1;
        float2 nrm = float2(1, 0), nrm2 = float2(0, 1);
        for (int k = 0; k < 64; k++) {
            if (k == i1) continue;
            float2 dl = u.cellA[k].xy - q;
            float2 t = float2(dot(dl, dir) * squeeze, dot(dl, perp));
            float lt = length(t);
            float Pk = dot(t, t) - u.cellB[k].z;
            // A seed this far off is past the second nearest crack: skip it.
            if ((lt * lt - 1400.0 - best) / (2.0 * (lt + lt1) + 1e-3) > border2 * 1.0) continue;
            float2 dt = t - t1;
            float L = length(dt);
            if (L < 1e-3) continue;
            float2 nt = dt / L;
            float2 g = dir * (nt.x * squeeze) + perp * nt.y;   // the crack's real-space gradient
            float gl = max(length(g), 1e-3);
            float dist = (Pk - best) / (2.0 * L * gl);
            if (dist < border) {
                border2 = border; i3 = i2; nrm2 = nrm;
                border = dist; i2 = k; nrm = g / gl;
            } else if (dist < border2) {
                border2 = dist; i3 = k; nrm2 = g / gl;
            }
        }
        r.i1 = i1; r.i2 = i2; r.i3 = i3; r.border = max(border, 0.0); r.border2 = max(border2, 0.0); r.n = nrm; r.n2 = nrm2;
        return r;
    }

    // The plates' candidates. Every lake pixel looked for its plate among all 64 seeds, twice (its plate, then its two
    // nearest cracks): on Intel and AMD GPUs that was a quarter of the frame. The seeds drift a few metres a second at
    // most, so a map of the warped plane (q, ±kPlateSpan m each way, `volcano_plate_map`) holds for each texel the 12 seeds
    // of least power at its middle (three to a channel, a + 64 b + 4096 c, exact in a float), refreshed a sixteenth of its
    // rows a frame (every 16th row, so nothing tears; the whole map when it is new or the clock jumped), and the lake
    // reads only those 12 (`platesNear`: the same sums on the same seeds, so the same plates and cracks; on the CPU, at
    // 235,000 points of the lake in six layouts of the seeds, every plate and every crack within 25 m is the same as
    // with all 64 but at 28 points, where a second crack 14 m or more off is another one at nearly its distance).
    constant float kPlateSpan = 420.0;

    void plateOrder(thread float& a, thread float& b, thread int& i, thread int& j) {
        if (b < a) { float t = a; a = b; b = t; int s = i; i = j; j = s; }
    }

    /// The 12 seeds of least power at q (in the drift's frame there, as `plates` measures), packed for the map.
    float4 plateCandidates(float2 q, constant VolcanoU& u) {
        float2 off = q - float2(-40.0, 30.0);
        float lo = length(off);
        float2 dir = lo > 1e-3 ? off / lo : float2(1, 0);
        float2 perp = float2(-dir.y, dir.x);
        const float squeeze = 0.6;
        float p0 = 1e30, p1 = 1e30, p2 = 1e30, p3 = 1e30, p4 = 1e30, p5 = 1e30;
        float p6 = 1e30, p7 = 1e30, p8 = 1e30, p9 = 1e30, p10 = 1e30, p11 = 1e30;
        int k0 = 0, k1 = 0, k2 = 0, k3 = 0, k4 = 0, k5 = 0, k6 = 0, k7 = 0, k8 = 0, k9 = 0, k10 = 0, k11 = 0;
        for (int k = 0; k < 64; k++) {
            float2 dl = u.cellA[k].xy - q;
            float2 t = float2(dot(dl, dir) * squeeze, dot(dl, perp));
            float P = dot(t, t) - u.cellB[k].z;
            if (P >= p11) continue;
            // In at the end, then down the sorted twelve to its place (no array: they stay in registers).
            p11 = P; k11 = k;
            plateOrder(p10, p11, k10, k11); plateOrder(p9, p10, k9, k10); plateOrder(p8, p9, k8, k9);
            plateOrder(p7, p8, k7, k8); plateOrder(p6, p7, k6, k7); plateOrder(p5, p6, k5, k6); plateOrder(p4, p5, k4, k5);
            plateOrder(p3, p4, k3, k4); plateOrder(p2, p3, k2, k3); plateOrder(p1, p2, k1, k2); plateOrder(p0, p1, k0, k1);
        }
        return float4(float(k0 + 64 * k1 + 4096 * k2), float(k3 + 64 * k4 + 4096 * k5), float(k6 + 64 * k7 + 4096 * k8),
                      float(k9 + 64 * k10 + 4096 * k11));
    }

    kernel void volcano_plate_map(texture2d<float, access::write> map [[texture(0)]], constant VolcanoU& u [[buffer(0)]],
                                  constant uint4& job [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        uint w = map.get_width(), h = map.get_height();
        uint y = job.x + gid.y * job.y;           // rows first, first + strips, …
        if (gid.x >= w || y >= h) return;
        float2 q = ((float2(float(gid.x), float(y)) + 0.5) / float2(float(w), float(h)) * 2.0 - 1.0) * kPlateSpan;
        map.write(plateCandidates(q, u), uint2(gid.x, y));
    }

    /// The map's candidate `n` (0…11) from its texel.
    int plateCandidate(float4 c, int n) {
        int code = int(n < 3 ? c.x : (n < 6 ? c.y : (n < 9 ? c.z : c.w)));
        int slot = n - 3 * (n / 3);
        return (code >> (6 * slot)) & 63;
    }

    /// `plates`, among the map's 12 candidates at q instead of all 64 seeds.
    Plates platesNear(float2 p, constant VolcanoU& u, texture2d<float> map) {
        float2 q0 = p * 0.028;
        float2 w1 = float2(vn2(q0 + float2(3.1, 7.7)), vn2(q0 + float2(11.3, 1.9))) - 0.5;
        float2 q1 = p * 0.14;
        float2 w2 = float2(vn2(q1 + float2(5.2, 3.3)), vn2(q1 + float2(9.4, 6.1))) - 0.5;
        float2 q = p + w1 * 26.0 + w2 * 5.0;
        float2 off = q - float2(-40.0, 30.0);
        float lo = length(off);
        float2 dir = lo > 1e-3 ? off / lo : float2(1, 0);
        float2 perp = float2(-dir.y, dir.x);
        const float squeeze = 0.6;
        Plates r;
        r.q = q;
        float mw = float(map.get_width()), mh = float(map.get_height());
        float2 g = (q / kPlateSpan * 0.5 + 0.5) * float2(mw, mh);
        uint2 tx = uint2(clamp(floor(g), float2(0.0), float2(mw - 1.0, mh - 1.0)));
        float4 c = map.read(tx);
        int i1 = 0;
        float best = 1e12;
        float2 t1 = float2(0);
        for (int n = 0; n < 12; n++) {
            int k = plateCandidate(c, n);
            float2 dl = u.cellA[k].xy - q;
            float2 t = float2(dot(dl, dir) * squeeze, dot(dl, perp));
            float P = dot(t, t) - u.cellB[k].z;
            if (P < best) { best = P; i1 = k; t1 = t; }
        }
        float lt1 = length(t1);
        float border = 1e9, border2 = 1e9;
        int i2 = i1, i3 = i1;
        float2 nrm = float2(1, 0), nrm2 = float2(0, 1);
        for (int n = 0; n < 12; n++) {
            int k = plateCandidate(c, n);
            if (k == i1) continue;
            float2 dl = u.cellA[k].xy - q;
            float2 t = float2(dot(dl, dir) * squeeze, dot(dl, perp));
            float lt = length(t);
            float Pk = dot(t, t) - u.cellB[k].z;
            if ((lt * lt - 1400.0 - best) / (2.0 * (lt + lt1) + 1e-3) > border2 * 1.0) continue;
            float2 dt = t - t1;
            float L = length(dt);
            if (L < 1e-3) continue;
            float2 nt = dt / L;
            float2 gr = dir * (nt.x * squeeze) + perp * nt.y;
            float gl = max(length(gr), 1e-3);
            float dist = (Pk - best) / (2.0 * L * gl);
            if (dist < border) {
                border2 = border; i3 = i2; nrm2 = nrm;
                border = dist; i2 = k; nrm = gr / gl;
            } else if (dist < border2) {
                border2 = dist; i3 = k; nrm2 = gr / gl;
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

    /// A crack's light at distance d (m) from its middle: the lava cools from its core to its crusted lips, so across it
    /// the colour runs from a thin white-yellow core through orange to deep red as it fades (a blackbody profile, no
    /// halo); `w` its half-width (m), `f` the pixel's footprint across it (m), its light kept when it's thinner than one.
    float3 crackGlow(float d, float w, float f, float Tcore) {
        float we = sqrt(w * w + 0.5 * f * f);
        return blackbody(Tcore - 330.0 * max(d, 0.0) / we) * (w / we);
    }

    /// The lake's own light at a point of its surface (crater metres), seen along d; J is the pixel's footprint (lake
    /// metres per pixel across x and y).
    float3 lakeSurface(float3 P, float3 d, float2 Jx, float2 Jy, constant VolcanoU& u, int oct, float edgeR,
                       texture2d<float> plateMap) {
        float2 p = P.xy;
        float energy = u.play.x;
        uint skipL = uint(u.sprites.w + 0.5);
        Plates pl;
        // (The map's 12 candidates once it is whole; all 64 seeds without it.)
        if ((skipL & 512u) == 0u) pl = u.sprites.y > 0.5 ? platesNear(p, u, plateMap) : plates(p, u);
        else { pl.i1 = 0; pl.i2 = 1; pl.i3 = 2; pl.border = 9.0; pl.border2 = 12.0; pl.n = float2(1, 0); pl.n2 = float2(0, 1); pl.q = p; }
        float4 A = u.cellA[pl.i1];
        float4 Ab = u.cellB[pl.i1];
        float foot = max(length(Jx), length(Jy));
        // The two nearest cracks, each its own character (so a junction never steps): most are thin, dull seams that
        // pinch shut and open again along their length; a few are wide spreading seams with white-hot cores (more of
        // them with Energy: more seams, never a wash). The brighter shows.
        float heatA = A.w;
        float3 crack = float3(0);
        float3 spill = float3(0);
        for (int c = 0; c < 2; c++) {
            int j = c == 0 ? pl.i2 : pl.i3;
            float bd = c == 0 ? pl.border : pl.border2;
            float2 nn = c == 0 ? pl.n : pl.n2;
            float4 Bj = u.cellA[j];
            float4 Bjb = u.cellB[j];
            float fnj = length(float2(dot(Jx, nn), dot(Jy, nn)));
            float lo = float(min(pl.i1, j)), hi = float(max(pl.i1, j));
            float pair = hash12(float2(lo * 7.13, hi * 3.71));
            float heat = 0.5 * (heatA + Bj.w);
            float wide = max(smoothstep(0.85 - 0.17 * energy, 0.97 - 0.12 * energy, pair), 0.8 * heat * heat);
            float note = max(A.z, Bj.z);
            float along = vn2(pl.q * 0.045 + pair * 31.0);
            float along2 = vn2(pl.q * 0.2 + pair * 7.0);
            float pinch = smoothstep(0.15, 0.6, along) * (0.4 + 1.2 * along2);
            float width = u.lake.z * mix(0.22, 2.0, wide) * pinch * (0.7 + 0.6 * heat);
            // Torn lips: the crack's edge wanders on a short scale.
            float bdt = max(bd + (vn2(pl.q * 0.55 + pair * 13.0) - 0.5) * 0.9 * (0.4 + width), 0.0);
            bool twins = int(Ab.y) == j || int(Bjb.y) == pl.i1;
            float open = twins ? smoothstep(0.0, 1.0, min(Ab.x, Bjb.x)) : 1.0;
            float T = u.temps.x + 90.0 + 40.0 * pair + 230.0 * wide + 80.0 * heat + 40.0 * energy + 150.0 * note
                    + 80.0 * u.play.w + 70.0 * (along2 - 0.5);
            crack = max(crack, crackGlow(bdt, width, fnj, T) * open);
            spill = max(spill, blackbody(T - 150.0) * (exp(-bd / (1.0 + 2.0 * width)) * open * (0.3 + 0.7 * pinch)));
        }
        // The crust: a dark grey glassy skin (young plates thinner, a little red with heat), its ropy wrinkles catching
        // the cracks' light beside them and the plume's glow above (a faint sheen, more at grazing angles).
        float2 local = p - A.xy + float2(hash12(float2(float(pl.i1), 1.7)) * 97.0, hash12(float2(float(pl.i1), 4.1)) * 61.0);
        float skin = fbm2(local * 0.11, oct);
        float Tc = mix(u.temps.z, u.temps.y, A.w) + 80.0 * (skin - 0.5) + 30.0 * energy;
        Tc += 110.0 * exp(-pl.border / (1.0 + 2.0 * A.w));
        float3 col = blackbody(Tc);
        float2 rw = local * 0.6 + 4.0 * float2(vn2(local * 0.05), vn2(local * 0.05 + 5.0));
        float ropes = 1.0 - abs(sin(rw.x * 1.1 + 2.5 * vn2(rw * 0.25)));
        float albedo = 0.06 + 0.06 * ropes * ropes + 0.04 * skin;
        float grazing = 1.0 - saturate(-d.z);
        float g2 = grazing * grazing;
        float fres = 0.04 + 0.96 * g2 * g2 * grazing;
        col += albedo * (1.3 * spill + u.glow.rgb * (0.35 * u.plume.x) + u.skyL.rgb);
        // (The sheen is none on the near half of the lake (80 m short of its middle): its roughness isn't read there.)
        float sheenFar = smoothstep(-80.0, 150.0, p.y);
        if (sheenFar > 0.0) {
            float rough = smoothstep(0.35, 0.75, fbm2(local * 0.35 + float2(2.0, 9.0), oct));
            float sheen = fres * (0.55 - 0.4 * rough) * sheenFar;
            col += u.glow.rgb * float3(0.95, 0.9, 0.85) * (0.32 * sheen * u.plume.x);
        }
        // Dim hairlines within the plate (some of them glowing: the skin's hotter seams).
        if (oct >= 3 && (skipL & 1024u) == 0u) {
            // (Where the skin's seams are cold there are none to see: the net isn't walked there.)
            float hot = smoothstep(0.35, 0.7, vn2(local * 0.12 + 3.0));
            if (hot > 0.0) {
                float fine = fineCracks(local, 5.0 + 7.0 * (1.0 - A.w));
                float fineT = Tc + 230.0 + 90.0 * u.temps.w + 80.0 * A.z;
                col += crackGlow(fine, 0.05 + 0.05 * A.w, foot, fineT) * (hot * (0.3 + 0.5 * u.temps.w));
            }
        }
        col += crack;
        // The fountains' pools: fresh lava churning at their feet, crusting over between bursts.
        for (int k = 0; k < 2; k++) {
            float4 f = k == 0 ? u.fountA : u.fountB;
            float rp = (4.0 + 0.22 * f.z) * u.dims3.y;
            // (Its edge wanders 1.5 m at most (the noise is 0…1): farther off there is no pool whatever the noise, and
            // mixing in none leaves the colour exactly as it is, so none is read.)
            float centre = length(p - f.xy);
            if (centre - 1.6 >= rp * 1.1) continue;
            float dist = centre + 3.0 * (vn2(p * 0.15 + u.a.y * 0.3) - 0.5);
            float pool = 1.0 - smoothstep(rp * 0.5, rp * 1.1, dist);
            float churn = vn2(p * 0.4 + float2(u.a.y * 0.9, -u.a.y * 0.6));
            float skinOver = smoothstep(0.5, 0.75, vn2(p * 0.3 - u.a.y * 0.2)) * (1.0 - 0.6 * f.w);
            float Tp = 1150.0 + 110.0 * f.w + 90.0 * churn - 220.0 * skinOver;
            col = mix(col, blackbody(Tp), pool);
        }
        // The margin: old crust jammed against the shore (darker), a splash of fresh lava here and there.
        float r = length(p);
        float toEdge = edgeR - r;
        float arc = atan2(p.y, p.x) * u.lake.x;
        float jam = exp(-max(toEdge, 0.0) / 6.0);
        col *= 1.0 - 0.45 * jam;
        float splash = smoothstep(0.72, 0.9, vn2(float2(arc * 0.05, u.a.y * 0.35)) * 0.75 + vn2(float2(arc * 0.3, 2.0)) * 0.35);
        if (splash > 0.0) {
            col += crackGlow(abs(toEdge - 0.6), 0.5 + 1.2 * splash, foot, 1120.0 + 120.0 * splash + 60.0 * u.glow.w) * splash;
        }
        // The breach's new river leaves the lake here: the lake's own crust torn open toward it.
        if (u.river.z > 0.0) {
            float toMouth = length(p - u.riverA.xy);
            col += blackbody(1240.0 + 80.0 * u.river.z) * (u.river.z * exp(-toMouth / 18.0) * 0.6);
        }
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

    float3 floorColour(float3 P, float3 d, float foot, constant VolcanoU& u, int oct, float edgeR) {
        float2 p = P.xy;
        // Old black lava: ropy and blocky, a little glassy, here and there a skylight onto hot lava beneath.
        float rope = fbm2(p * float2(0.035, 0.022) + float2(3.0, 1.0), oct);
        float block = vn2(p * 0.07);
        float3 albedo = float3(0.04, 0.036, 0.034) * (0.55 + 0.5 * rope + 0.2 * block);
        float3 N = normalize(float3((rope - 0.5) * 0.5, (block - 0.5) * 0.5, 1.0));
        float3 col = albedo * (craterLight(P, N, u) + u.skyL.rgb);
        // (A skylight's second noise is read only where its first opens one.)
        float sky = smoothstep(0.86, 0.93, vn2(p * 0.03 + float2(7.0, 2.0)));
        if (sky > 0.0) {
            sky *= smoothstep(0.5, 0.8, vn2(p * 0.12));
            col += blackbody(980.0 + 120.0 * u.play.x) * (0.25 * sky);
        }
        // The river: from a bright lip where the lake spills over its ledge, a channel running to the breach, rafts of
        // crust riding on it (moving with the flow, more of them and darker downstream), incandescent lava in the gaps
        // between them, its banks' inner edges glowing.
        float2 rd = riverDistance(p, u);
        float flow = u.river.x, breach = u.river.z;
        // (The river is 17.6 m wide at most and its glow beside it fades by e^-20 over 160 m: farther off neither is
        // drawn, and the river's noise isn't read.)
        if (rd.x < 180.0) {
            float lenR = length(u.riverA.zw - u.riverA.xy);
            float halfW = (3.0 + 3.0 * flow + 7.0 * breach) * (0.75 + 0.5 * vn2(float2(rd.y * 7.0, 3.0)) + 0.2 * (vn2(p * 0.15) - 0.5));
            float inside = 1.0 - smoothstep(halfW - max(1.0, foot), halfW + max(1.0, foot), rd.x);
            if (inside > 0.0) {
                float alongM = rd.y * lenR - u.river.y;
                float2 rp = float2(alongM * 0.8, rd.x * 1.1 + 3.0);
                float edgeR = oct >= 3 ? fineCracks(rp + float2(13.0, 5.0), 6.0) : 6.0 * abs(vn2(rp * 0.17) - 0.5);
                float gapW = mix(1.4, 0.2, rd.y) * (0.45 + 0.6 * breach + 0.25 * flow);
                float Tlava = 1160.0 + 130.0 * breach + 50.0 * flow - 260.0 * rd.y;
                float3 raft = blackbody(760.0 + 120.0 * breach - 140.0 * rd.y)
                            + float3(0.06, 0.055, 0.05) * (0.5 + 0.6 * vn2(rp * 0.9)) * (u.glow.rgb * 0.6 + u.skyL.rgb);
                float3 river = raft + crackGlow(edgeR, gapW, foot, Tlava);
                float lip = exp(-sq((rd.y - 0.05) / 0.035));
                river = mix(river, blackbody(1220.0 + 110.0 * breach + 40.0 * (vn2(p * 0.6 + u.a.y) - 0.5)), lip * (0.35 + 0.65 * breach));
                river += blackbody(1080.0 + 100.0 * breach) * (exp(-abs(rd.x - halfW * 0.9) / 1.0) * (0.12 + 0.35 * breach) * (1.0 - 0.6 * rd.y));
                col = mix(col, river, inside);
            }
            col += blackbody(1060.0 + 120.0 * breach) * (exp(-max(rd.x - halfW, 0.0) / 8.0) * (0.05 + 0.1 * flow + 0.35 * breach) * 0.3);
        }
        // The lake's shore: a black ledge of chilled spatter, lumpy, its lake-facing lips lit by the lake (they fade by
        // e^-20 within 50 m of the shore: farther off their noise isn't read).
        float shore = length(p) - edgeR;
        float ledge = exp(-max(shore, 0.0) / 5.0);
        col *= 1.0 - 0.5 * ledge;
        if (shore < 50.0) {
            float lumpy = vn2(p * 0.5) * 0.6 + vn2(p * 1.7) * 0.4;
            col += u.glow.rgb * float3(1.0, 0.85, 0.7) * (0.05 * smoothstep(0.45, 0.8, lumpy) * exp(-max(shore, 0.0) / 2.5));
            float drip = smoothstep(0.8, 0.95, vn2(p * 0.9 + 4.0)) * exp(-max(shore, 0.0) / 1.5);
            col += blackbody(1060.0 + 60.0 * u.play.x) * (0.25 * drip);
        }
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
        float3 inward = float3(-q / max(r, 1e-3), 0.0);
        float3 tangent = float3(inward.y, -inward.x, 0.0);
        // Stacked lava flows, each a unit of its own thickness that thickens, thins and pinches out along the wall (its
        // boundaries wander by a layer or more over a couple of hundred metres), offset where a stretch of wall has
        // slumped; most units are rough, dark, broken rock (rubble and blocky entablature), a few a colonnade.
        float slump = 15.0 * smoothstep(0.55, 0.78, vn2(float2(arc * 0.008, 9.0))) - 10.0 * smoothstep(0.6, 0.82, vn2(float2(arc * 0.011, 4.0)));
        // Gullies: chutes cut down the wall every hundred metres or so, each its own width, wider up; rockfall has
        // heaped a talus cone at each one's foot.
        float gc = arc / 95.0 + 0.7 * vn2(float2(arc * 0.01, 2.0)) + 0.14 * vn2(float2(arc * 0.03, z * 0.035 + 6.0));
        float gid = floor(gc + 0.5);
        float gseed = hash12(float2(gid, 8.1));
        float gd = abs(gc - gid) * 95.0;
        float gw = (10.0 + 16.0 * gseed) * (0.45 + 0.55 * smoothstep(0.0, 140.0, z));
        float gully = step(0.3, gseed) * (1.0 - smoothstep(0.15 * gw, 1.15 * gw, gd));
        float lz = (z + slump - 9.0 * gully) / 24.0 + 0.85 * vn2(float2(arc * 0.004, z * 0.006 + 1.0))
                 + 0.3 * vn2(float2(arc * 0.012, z * 0.02 + 3.0));
        float Li = floor(lz), f = lz - Li;
        float seedL = hash12(float2(Li, 3.3));
        float colonnade = step(0.62, seedL);
        // Columns, where a unit has them: each its own width, wandering; dark joints between them, cross-joints up them.
        float Wc = 4.0 + 5.0 * seedL;
        float ca = arc / Wc + 0.45 * vn2(float2(z * 0.07, Li * 5.0));
        float ci = floor(ca), cu = ca - ci;
        float colSeed = hash12(float2(ci, Li * 7.1));
        float facet = (cu < 0.3 + 0.4 * colSeed ? -0.5 : 0.45) * colonnade;
        float ju = min(cu, 1.0 - cu) * Wc;
        float joint = (1.0 - smoothstep(0.06, 0.2 + foot, ju)) * colonnade;
        float cross = 0.0;
        if (oct >= 3) {
            float cz = z * (0.55 + 0.35 * colSeed) + colSeed * 5.0;
            float dz = abs(fract(cz + 0.5) - 0.5) / (0.55 + 0.35 * colSeed);
            cross = (1.0 - smoothstep(0.05, 0.12 + foot, dz)) * colonnade;
        }
        // The blocky, broken rock of the other units: lumps of every size, rough.
        float blocksR = vn2(float2(arc * 0.13, z * 0.16 + Li * 3.1)) * 0.6 + vn2(float2(arc * 0.45, z * 0.5)) * 0.4;
        float rubbly = max(smoothstep(0.55, 0.8, f), 1.0 - colonnade);
        // A ledge only here and there: where a unit's top stands out and holds, catching the lake's light; it breaks off,
        // and the gullies cut it.
        float holds = smoothstep(0.4, 0.62, vn2(float2(arc * 0.012, Li * 2.3))) * step(0.25, seedL) * (1.0 - gully);
        // Its lit edge thickens and thins along the wall and fades in and out (a broken edge, never a drawn line).
        // (None where nothing holds, or below the lowest the lip reaches (f under 0.95 − 1.6 × 0.27): its noise isn't read.)
        float lip = 0.0;
        if (holds > 0.0 && f > 0.518) {
            float lipW = 0.07 + 0.2 * vn2(float2(arc * 0.021, Li * 4.7));
            lip = smoothstep(0.95 - 1.6 * lipW, 0.95 - 0.6 * lipW, f) * (1.0 - smoothstep(0.95, 1.0, f)) * holds
                * (0.35 + 0.9 * vn2(float2(arc * 0.035, Li * 1.9 + 6.0)));
        }
        float under = (1.0 - smoothstep(0.0, 0.2, f)) * holds;
        // The wall's big relief: buttresses between the gullies, the gullies themselves recessed and shaded.
        float relief = fbm2(float2(arc * 0.025, z * 0.006 + 4.0), oct);
        float buttress = vn2(float2(arc * 0.006, 7.0)) * 0.65 + vn2(float2(arc * 0.017, z * 0.004 + 2.0)) * 0.35;
        float side = sign(gc - gid);
        float lean = (relief - 0.5) * 1.1 + (buttress - 0.5) * 1.6 + gully * side * 1.2;
        float3 N = normalize(inward + tangent * (lean + facet * (1.0 - rubbly) + (blocksR - 0.5) * 0.8 * (1.0 - colonnade))
                             + float3(0, 0, -0.15 + 0.4 * f));
        if (lip > 0.0) N = normalize(mix(N, normalize(inward * 0.35 + float3(0, 0, 1)), lip));
        if (h.kind == 4) N = normalize(float3(0, 0, 1) + inward * 0.25);
        float grain = vn2(float2(arc * 1.3, z * 1.3)) * 0.5 + vn2(float2(arc * 0.35, z * 0.35)) * 0.5;
        float3 basalt = float3(0.05, 0.047, 0.045) * (0.75 + 0.5 * colSeed) * (0.8 + 0.4 * grain);
        float3 scoria = float3(0.075, 0.05, 0.04) * (0.5 + 0.9 * blocksR) * (0.8 + 0.4 * grain);
        float3 basaltC = mix(basalt, scoria, rubbly);
        float ao = (1.0 - 0.38 * joint * (1.0 - rubbly)) * (1.0 - 0.45 * cross * (1.0 - rubbly)) * (1.0 - 0.5 * under)
                 * (0.45 + 0.55 * smoothstep(0.2, 0.7, relief)) * (0.6 + 0.4 * smoothstep(0.25, 0.6, buttress))
                 * (1.0 - 0.65 * gully) * (0.7 + 0.3 * blocksR);
        // A talus of rubble at each cliff's foot, heaped into a cone under each gully: loose blocks, paler.
        float footZ = h.p.z > u.dims.y + 1.0 ? u.dims.y : u.eye.w;
        float coneR = 25.0 + 45.0 * gseed;
        float cone = step(0.3, gseed) * saturate(1.0 - gd / coneR);
        // (The talus stands 94 m at most (its noise is 0…1): higher up there is none, and its noise isn't read.)
        if (h.kind == 3 && P.z - footZ < 94.0) {
            float talusH = 8.0 + 10.0 * relief + 6.0 * vn2(float2(arc * 0.05, 1.0)) + (30.0 + 40.0 * gseed) * cone;
            float talus = 1.0 - smoothstep(talusH * 0.75, talusH, P.z - footZ);
            if (talus > 0.0) {
                float blocks = vn2(float2(arc * 0.22, P.z * 0.22)) * 0.6 + 0.4 * vn2(float2(arc * 0.7, P.z * 0.7));
                basaltC = mix(basaltC, float3(0.058, 0.052, 0.048) * (0.6 + 0.7 * blocks), talus);
                N = normalize(mix(N, normalize(inward + float3(0, 0, 0.8) + tangent * (0.6 * side * cone)), talus));
                ao = mix(ao, 0.7 + 0.3 * blocks, talus);
            }
        }
        if (h.kind == 4) {
            basaltC = float3(0.06, 0.052, 0.048) * (0.5 + 0.8 * vn2(P.xy * 0.15));
            ao = 0.8;
        }
        float3 lit = craterLight(P, N, u);
        float3 col = basaltC * ao * (lit + u.skyL.rgb);
        col += basaltC * lit * (1.25 * lip);
        float3 basalt0 = basaltC;
        // The breach's notch: its cut faces lit by the river pouring through.
        float off = abs(th - u.dims2.w);
        float nearNotch = 1.0 - smoothstep(u.dims3.x * 0.5, u.dims3.x * 2.2, off);
        float riverLight = (0.1 + 0.3 * u.river.x + 3.0 * u.river.z) * nearNotch * exp(-max(z, 0.0) / 40.0);
        col += basalt0 * u.glow.rgb * riverLight * 4.0;
        // A rockfall (a surprise): a cascade of dust and debris sliding down the wall from the lip, lit from below.
        if (u.rockfall.x >= 0.0) {
            float pr = u.rockfall.x;
            float da = (th - u.rockfall.y) * r;
            float front = u.dims2.z + 10.0 - pr * 1.4 * u.dims2.z;
            float width = 22.0 + 50.0 * pr + 0.2 * max(u.dims2.z - P.z, 0.0);
            float spread = exp(-sq(da / width));
            float body = smoothstep(front - 12.0, front + 20.0, P.z) * (1.0 - smoothstep(0.55, 1.0, pr));
            float n = fbm2(float2(da * 0.07, P.z * 0.04 + pr * 5.0), oct);
            float dust = saturate(spread * body * (0.45 + 1.1 * n));
            float warm = lum(u.glow.rgb);
            float3 dustLit = mix(float3(warm), u.glow.rgb, 0.45) * float3(1.0, 0.9, 0.82) * (2.2 * exp(-max(z, 0.0) / 160.0) * (0.55 + 0.7 * n))
                           + float3(0.035, 0.033, 0.032) + u.skyL.rgb * 0.6;
            col = mix(col, dustLit, dust * 0.85);
            float debris = smoothstep(0.82, 0.95, vn2(float2(da * 0.25, P.z * 0.18 + pr * 40.0))) * spread * body;
            col += blackbody(1000.0) * (0.4 * debris);
        }
        // Hot seams in the old walls, here and there low down, livelier with Energy (none 50 m up: not read there).
        if (z < 50.0) {
            float seam = smoothstep(0.94, 0.975, vn2(float2(arc * 0.08, lz * 3.2))) * (1.0 - smoothstep(0.0, 50.0, z));
            col += blackbody(960.0 + 120.0 * u.play.x) * (0.15 * seam);
        }
        return col;
    }

    // ---------------------------------------------------------------- fountains, the column and the plume
    /// Clots thrown from a vent on parabolic arcs, on a vertical plane (x across, z up, metres from the vent), seen as a
    /// long exposure: `n` arcs, each a stream of clots thrown every `gap` seconds; each clot drawn as the stretch of its
    /// own arc it swept in the last `trail` seconds of flight (so the streaks curve with the arcs, as long exposures of
    /// fountaining do), brightest at its head, thinning behind it, its own size, cooling from yellow through orange to
    /// red as it flies. The flights play `pace` times fast. The arcs: the tallest `top` (m), most `low` to `high`,
    /// leaning up to `tip` (rad); clots are thrown from `since` seconds ago until `until` seconds after the vent opened.
    /// The nearest point of each arc is found from its height and its run (so steep and flat parts both hold), then
    /// refined once along the tangent.
    float4 clotArcs(float x, float z, float fp, float low, float high, float top, float tip, float size, int n, float gap,
                    float pace, float since, float until, float seed, float T0, float cool, float trail) {
        float3 light = float3(0);
        float cover = 0.0;
        const float g = 9.81;
        for (int k = 0; k < 28; k++) {
            if (k >= n) break;
            float fk = float(k) + seed * 37.0;
            float r1 = hash12(float2(fk, 1.3)), r2 = hash12(float2(fk, 4.4)), r3 = hash12(float2(fk, 7.9));
            float h = r3 > 0.85 ? top * (0.35 + 0.65 * r2) : mix(low, high, r2 * r2);
            float T = tan((r1 - 0.5) * 2.0 * tip * (1.0 - 0.4 * r2));
            T = T < 0.0 ? min(T, -0.01) : max(T, 0.01);
            float x0 = (fract(r3 * 7.13) - 0.5) * size * 5.0;
            float h4 = 4.0 * h;
            float pad = size * 4.0 + 4.0 * fp + 2.0;
            // Cheap reject: far outside this arc's box.
            float xr = x - x0;
            if (z < -pad || z > h + pad) continue;
            if (xr * sign(T) < -pad || abs(xr) > abs(T) * h4 + pad) continue;
            // The nearest point of the arc P(u) = (x0 + T·u, u − u²/4h), u from 0 (the vent) to 4h (back down).
            float uA = clamp(xr / T, 0.0, h4);
            float root = sqrt(saturate(1.0 - z / h));
            float uB = 2.0 * h * (1.0 - root), uC = 2.0 * h * (1.0 + root);
            float best = 1e12, ub = uA;
            for (int c = 0; c < 3; c++) {
                float uu = c == 0 ? uA : (c == 1 ? uB : uC);
                float2 dv = float2(xr - T * uu, z - (uu - uu * uu / h4));
                float dd = dot(dv, dv);
                if (dd < best) { best = dd; ub = uu; }
            }
            float2 tg = float2(T, 1.0 - ub / (2.0 * h));
            float tl = max(length(tg), 1e-4);
            float2 dv0 = float2(xr - T * ub, z - (ub - ub * ub / h4));
            ub = clamp(ub + dot(dv0, tg) / (tl * tl), 0.0, h4);
            float2 Pu = float2(T * ub, ub - ub * ub / h4);
            float2 dv = float2(xr, z) - Pu;
            tg = float2(T, 1.0 - ub / (2.0 * h));
            tl = max(length(tg), 1e-4);
            float lat = (dv.x * tg.y - dv.y * tg.x) / tl;   // signed, across the arc
            if (abs(lat) > pad + 0.04 * ub) continue;
            // The clot ahead of this point on the stream (the one whose streak can reach back over it): clots leave
            // every gap·pace of flight time and move along with time; this point is `behind` seconds of flight
            // behind it.
            float flight = 2.0 * sqrt(2.0 * h / g);
            float sPix = ub / h4 * flight;
            float spacing = gap * pace * (0.75 + 0.5 * r2);
            float rel = (since * pace - sPix) / spacing;
            float j = floor(rel);
            float launch = j * spacing / pace;
            if (j < 0.0 || launch > until) continue;
            float behind = (rel - j) * spacing;
            float rj = hash12(float2(fk * 3.1 + j * 0.173, 5.7));
            float rk = hash12(float2(fk * 1.7 + j * 0.311, 2.2));
            // Not every slot holds a clot, and each streaks its own length (their sizes and speeds differ), so a
            // stream is never a dotted line. A long exposure (the eruption's fountain: a long `trail`) streaks each clot
            // at least as far back as the one behind it, so its arcs run unbroken, never dashed.
            bool exposure = trail > 0.15;
            float reach = trail * pace * (0.4 + 0.9 * rk);
            if (exposure) reach = max(reach, 1.1 * spacing);
            if (rj < (exposure ? 0.12 : 0.35) || behind > reach) continue;
            float tail = behind / max(reach, 1e-3);                  // 0 at its head … 1 at the streak's end
            float rad = size * (0.45 + 0.7 * (rj - 0.35)) * (1.0 - 0.35 * tail);
            float la = lat;
            float we = sqrt(rad * rad + 0.5 * fp * fp);
            float core = exp(-la * la / (we * we)) * (rad / we) * (1.0 - (exposure ? 0.8 : 0.55) * tail) * smoothstep(0.0, 0.3, 1.0 - tail)
                       * (1.0 + 0.8 * exp(-tail * 14.0));                // the clot itself at the streak's head
            if (core < 0.002) continue;
            float Tk = T0 + 90.0 * rj - cool * sPix / pace;
            float b = 0.6 + 0.6 * rk;
            light += blackbody(Tk) * (core * b * 1.5);
            cover = max(cover, saturate(core * 1.2) * smoothstep(800.0, 1050.0, Tk));
        }
        return float4(light, cover);
    }

    /// A fountain on its own plane through its site, facing the camera: a low dome of spatter bulging and bursting out
    /// of the lake, and fragments flying from it on short arcs, cooling as they fall back.
    float4 fountain(float3 o, float3 d, float4 f, constant VolcanoU& u, float tMax, float fp, int oct) {
        if (f.z < 0.5 || d.y < 1e-4) return float4(0);
        float t = (f.y - o.y) / d.y;
        if (t <= 0.0 || t >= tMax) return float4(0);
        float3 P = o + d * t;
        float x = P.x - f.x;
        float z = P.z - u.eye.w;
        float H = 6.0 + 1.3 * f.z;
        if (z < -2.0 || z > H * 1.25 || abs(x) > H * 1.4 + 6.0) return float4(0);
        float tt = u.a.y;
        // The dome: a bulge of bright lava, its skin tearing, its top bursting into fragments.
        float Wd = 4.0 + 0.3 * H, Hd = 2.0 + 0.22 * H * (0.6 + 0.6 * f.w);
        float rag = vn2(float2(x * 0.5, z * 0.5 - tt * 5.0) + f.x);
        float dd = length(float2(x / Wd, z / Hd)) + 0.35 * (rag - 0.5);
        float dome = smoothstep(1.0, 0.7, dd) * smoothstep(-1.0, 0.3, z);
        float Td = 1180.0 + 120.0 * smoothstep(0.8, 0.0, dd) + 60.0 * f.w + 50.0 * (rag - 0.5);
        float3 light = blackbody(Td) * dome;
        float cover = dome;
        int n = oct >= 3 ? 10 : 6;
        float4 cl = clotArcs(x, z, fp, H * 0.25, H * 0.8, H, 0.55, 0.22 + 0.012 * H, n, 0.11, 1.0, tt + 1000.0, 1e9,
                             f.x * 0.37 + 2.0, 1230.0 + 60.0 * f.w, 120.0, 0.12);
        light += cl.rgb * (0.6 + 0.6 * f.w);
        cover = max(cover, cl.a);
        return float4(light, saturate(cover));
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
        // Steam: domain-warped fbm, torn and billowing, rising fast; white, lit orange from the lake below.
        float2 m = float2(x * 0.035, (z - pr * 260.0) * 0.025);
        float2 wq = float2(fbm2(m * 0.8 + float2(2.0, 5.0), 2), fbm2(m * 0.8 + float2(7.0, 1.0), 2)) - 0.5;
        float n = fbm2(m + wq * 1.4, oct);
        float dens = smoothstep(1.3, 0.2, abs(s) + 0.7 * (n - 0.5)) * smoothstep(H + 30.0, H * 0.4, z)
                   * (1.0 - smoothstep(0.55, 1.0, pr)) * smoothstep(0.3, 0.7, n + 0.25 * (1.0 - abs(s)));
        dens = saturate(dens * 1.4);
        float under = saturate(0.6 + 1.5 * (vn2(m + wq * 1.4) - vn2(m + wq * 1.4 - float2(0.0, 0.25))));
        float warmS = lum(u.glow.rgb);
        float3 lit = mix(float3(warmS), u.glow.rgb, 0.4) * (2.4 * exp(-max(z, 0.0) / 130.0)) * (0.4 + 0.7 * under)
                   + float3(0.05, 0.052, 0.058) * (0.6 + 0.4 * under) + u.skyL.rgb;
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

    /// The eruption's lava fountain on the middle plane, as a long exposure of Hawaiian fountaining shows one: a dense,
    /// continuous incandescent jet from the vent, its core narrow and hottest low down, broadening as it climbs and
    /// tearing into clots at its head; streaks of clots racing up it; and fewer, larger clots thrown from it on
    /// parabolic arcs, most falling back into the lake, each the curved stretch of its arc it swept during the exposure,
    /// cooling from yellow to red. The jet stands within the frame (its head 150–260 m up; the column the model raises
    /// is far taller), and up in under a second.
    float4 column(float3 P, constant VolcanoU& u, float fp, int oct) {
        float H = u.erupt.x;
        float age = u.erupt.z;
        if (age < 0.0 || age > 9.0) return float4(0);
        float sp = clamp(u.erupt.w, 0.3, 1.0);
        float peak = (3.0 + 3.0 * (sp - 0.3) / 0.7) * 2.0 * u.lake.x;   // Eruption.peak
        float standing = saturate(H / peak);
        float z = P.z - u.eye.w;
        float x = P.x;
        float Hj = fountainTop(u);
        if (z < -4.0 || z > Hj * 1.7 + 60.0 || abs(x) > 60.0 + 1.6 * Hj) return float4(0);
        float tt = u.a.y;
        float zn = saturate(z / max(Hj, 1.0));
        // The jet: a little bent by the wind, its half-width narrow at the vent and broadening as it climbs.
        float xj = x - 0.05 * z - 6.0 * zn * zn;
        float w = (11.0 + 9.0 * sp) * (1.0 + 2.2 * zn * zn) + 0.6 * fp;
        float q = xj / w;
        // Inside it, long-exposure threads (clots racing up smeared into lines) and clumps rising through it.
        float threads = vn2(float2(q * 3.2 + 7.0, z * 0.01 - tt * 0.8));
        float clumps = vn2(float2(xj * 0.13, (z - tt * 95.0) * 0.08)) * 0.75 + 0.25 * vn2(float2(xj * 0.31, (z - tt * 95.0) * 0.2));
        float body = exp(-q * q * 1.4) * (0.85 + 0.25 * threads);
        // Its head tears into clots: from two-thirds of the way up the jet thins into clumps, and above its head only
        // clots remain.
        float tear = smoothstep(0.55, 1.05, zn + 0.25 * (clumps - 0.5));
        float dens = body * mix(1.0, smoothstep(0.42, 0.72, clumps + 0.15 * threads), tear)
                   * (1.0 - smoothstep(1.0, 1.35, z / max(Hj, 1.0) - 0.15 * clumps)) * smoothstep(-3.0, 2.0, z) * standing;
        float Tj = 1370.0 - 190.0 * zn - 170.0 * q * q + 45.0 * (threads - 0.5) + 30.0 * sp - 120.0 * tear;
        float3 light = blackbody(Tj) * (dens * (1.1 + 0.25 * threads));
        float cover = saturate(dens * 1.4);
        // Clots from its head, fewer and larger, on tall narrow arcs (the flights 6 times fast, a long exposure's
        // streaks); most fall back into the lake round the vent, a few flung wider.
        int n = oct >= 3 ? 13 : 8;
        float4 cl = clotArcs(x, z, fp, 0.5 * Hj, 1.0 * Hj, 1.2 * Hj, 0.4, 1.4 + 0.9 * sp, n, 0.08, 6.0, age, 3.0,
                             7.0, 1290.0, 200.0, 0.22);
        light += cl.rgb * (0.85 + 0.3 * sp);
        cover = max(cover, cl.a);
        // Its light in the gas and the spray round the vent.
        float haze = exp(-length(float2(xj * 0.8, (z - 0.4 * Hj) * 0.5)) / (30.0 + 25.0 * sp)) * standing;
        light += blackbody(1150.0) * (0.06 * haze * u.erupt.y);
        return float4(light, saturate(cover));
    }

    /// The plume on its plane through the lake's middle: translucent gas rising off the lake, widening and leaning with
    /// the wind. Its density is domain-warped fbm scrolling up with the gas (curling, torn wisps, holes the far wall and
    /// the stars show through); it is lit from below by the lake (brightest at its foot, falling off with height, the
    /// undersides of its billows catching more), and higher up and toward its back it is a dark brown-grey.
    float4 plume(float3 P, constant VolcanoU& u, int oct, float3 lightCol) {
        float z = P.z - u.eye.w;
        float amount = u.plume.x;
        if (amount <= 0.01 || z < -5.0) return float4(0);
        float zz = max(z, 0.0);
        float bend = u.plume.z * zz * zz;
        float x = P.x - bend;
        float W = (46.0 + 0.34 * zz) * (0.8 + 0.4 * amount) * (1.0 + 0.15 * u.plume.y);
        float s = x / W;
        if (abs(s) > 1.9) return float4(0);
        float2 m = float2(x * 0.017, (z - u.plume.w) * 0.011);
        int wo = oct >= 3 ? 2 : 1;
        float2 w1 = float2(fbm2(m * 0.7 + float2(3.1, 7.3), wo), fbm2(m * 0.7 + float2(8.4, 1.6), wo)) - 0.5;
        float2 mw = m + w1 * 1.5;
        float n = fbm2(mw + float2(1.7, 4.2), oct);
        // Torn, see-through edges; wisps and holes inside; dense just over the lake, thinning as it climbs.
        float edge = 1.0 - smoothstep(0.3, 1.05, abs(s) + 0.6 * (n - 0.5));
        // High up it is wisps only (the gas spreading and mixing): never a dense lump at its top.
        float high = saturate(zz / 350.0);
        float wisp = smoothstep(0.4 + 0.14 * high, 0.66 + 0.08 * high, n);
        float thick = 0.42 + 0.78 * exp(-zz / 110.0);     // thinning as it widens
        float dens = edge * (0.2 + 0.8 * wisp) * thick * (0.55 + 0.6 * amount) * smoothstep(-5.0, 20.0, z);
        if (dens <= 0.003) return float4(0);
        float alpha = 1.0 - exp(-dens * 1.35);
        // Lit from below: the lake's disc light falls off with height and off its axis; a billow's underside (thinner gas
        // below it) catches more, and the light reaching into the gas fades with its depth.
        float R = u.lake.x;
        float irr = R * R / (R * R + sq(zz + 15.0) + 0.6 * x * x);
        float n1 = vn2(mw + float2(1.7, 4.2));
        float nb = vn2(mw + float2(1.7, 3.8));
        float under = saturate(0.5 + 1.8 * (n1 - nb));
        float depthIn = exp(-dens * 0.8);
        // The lake's light reaching up through the gas below (its optical depth growing with height): no lit lumps high
        // in the plume, its top in shadow.
        float below = exp(-zz * (0.0016 + 0.0014 * amount) * (1.0 + 0.5 * u.plume.y));
        float3 lit = lightCol * float3(1.0, 0.8, 0.64) * (2.3 * irr * below * (0.35 + 0.65 * under) * (0.45 + 0.55 * depthIn));
        // Its shaded upper parts: a dark brown-grey (light scattered many times, and the night sky's).
        lit += float3(0.034, 0.03, 0.027) * (lum(lightCol) * 0.8 * exp(-zz / 400.0)) + u.skyL.rgb * 0.5;
        // Lightning inside it: a violet-white glow round the stroke.
        float2 b = float2(x + bend - u.bolt.y, z - u.bolt.z);
        lit += float3(0.72, 0.7, 1.0) * (u.bolt.x * 0.6 * exp(-dot(b, b) / (2.0 * 38.0 * 38.0)) * (0.4 + 0.6 * under));
        // The eruption's fountain lights it from below and within: brightest on its undersides near the fountain's head.
        float Hj = fountainTop(u);
        if (Hj > 1.0) {
            float df2 = P.x * P.x + sq(zz - 0.8 * Hj);
            float Rf = 50.0 + 0.3 * Hj;
            lit += blackbody(1210.0) * (u.erupt.y * 0.16 * Rf * Rf / (Rf * Rf + df2) * (0.3 + 0.7 * under) * (0.5 + 0.5 * depthIn));
        }
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
        // (Where the ray ends off the lake the fume is none whatever its churn: exactly what the sum below gives.)
        if (overLake <= 0.0) return float4(0, 0, 0, 1);
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
        // (They stand 0.034 rad at most: above that their noise isn't read.)
        if (el < 0.034) {
            float range = 0.006 + 0.012 * vn2(float2(az * 9.0, 2.0)) + 0.006 * vn2(float2(az * 31.0, 5.0));
            float cone = 0.034 * smoothstep(0.32, 0.0, abs(az - 0.55)) * (1.0 - 0.15 * vn2(float2(az * 60.0, 1.0)));
            float ridge = max(range, cone);
            if (el < ridge) {
                float haze = exp(-(ridge - el) / 0.01);
                col = mix(sky.horizon.rgb * 0.18, sky.horizon.rgb * 0.45, haze * 0.5);
            }
        }
        // The plume's glow on the low sky round it (the air scatters the lit plume).
        float bendX = u.plume.z * 200.0 * 200.0;
        float ax = atan2(bendX * 0.5, u.eye.y * -1.0);
        float off = az - ax;
        float glowSky = exp(-off * off / 0.09) * exp(-max(el + 0.02, 0.0) / 0.22) * u.plume.x;
        col += u.glow.rgb * float3(1.0, 0.7, 0.5) * (0.06 * glowSky);
        // A far storm and its red sprites are SkyKit's (in `skyRadiance` above, when SkyKit's far storms or the weather
        // bring one): the crater has none of its own.
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
        float pix = u.cam.w;
        // (The edge wanders 0.0425 at most (its noise is 0…1): a pixel farther above it has no rock whatever the noise,
        // and reads none.)
        if (ndc.y >= top + 0.0425 + pix) return float4(0);
        float edge = top + 0.05 * (fbm2(float2(x * 2.2, 3.0), oct) - 0.5) + 0.035 * (vn2(float2(x * 9.0, 1.0)) - 0.5);
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
                                               constant VolcanoU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]],
                                               texture2d<float> plateMap [[texture(1)]],
                                               texture2d<float> plumeTex [[texture(2)]]) {
        // Under the keys' white columns, opaque there and drawn over the scene, nothing of it is seen: not drawn.
        if (in.ndc.y < u.sprites.z - 3.0) {
            ColorDepth hidden;
            hidden.color = float4(0.0, 0.0, 0.0, 1.0);
            hidden.depth = float4(0.6, 0, 0, 1);
            return hidden;
        }
        float2 ndc = in.ndc - u.cam.xy;
        int oct = int(u.a.z + 0.5);
        float3 Dn = sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w);
        float3 dE = normalize(Dn);
        float3 fwd3 = float3(u.axes.xy, 0.0), right3 = float3(u.axes.zw, 0.0);
        float3 d = float3(dot(dE, right3), dot(dE, fwd3), dE.z);
        float3 o = u.eye.xyz;
        Hit h = craterHit(o, d, u);
        float3 col = float3(0.05);
        float depth = 1.0;
        // (The timing test's mask: a set bit skips a layer, so one run can price each. Always 0 in the app.)
        uint skip = uint(u.sprites.w + 0.5);
        if (h.kind == 1 || h.kind == 2) {
            // The pixel's footprint on the plane (metres per pixel across x and y), from the unnormalised ray.
            float3 Dc = float3(dot(Dn, right3), dot(Dn, fwd3), Dn.z);
            float px = u.cam.w / max(u.a.x, 1e-3), py = u.cam.w;
            float3 sx = sky.right.xyz * (sky.right.w * px), sy = sky.up.xyz * (sky.up.w * py);
            float3 dx = float3(dot(sx, right3), dot(sx, fwd3), sx.z), dy = float3(dot(sy, right3), dot(sy, fwd3), sy.z);
            float tp = (u.eye.w - o.z) / min(Dc.z, -1e-6);
            float2 Jx = tp * (dx.xy - Dc.xy * (dx.z / Dc.z));
            float2 Jy = tp * (dy.xy - Dc.xy * (dy.z / Dc.z));
            if (h.kind == 1) { if ((skip & 1u) == 0u) col = lakeSurface(h.p, d, Jx, Jy, u, oct, h.edge, plateMap); }
            else if ((skip & 2u) == 0u) col = floorColour(h.p, d, max(length(Jx), length(Jy)), u, oct, h.edge);
            depth = 0.6;
        } else if (h.kind >= 3) {
            if ((skip & 4u) == 0u) col = wallColour(h, d, u, oct, h.t * u.a.w);
            depth = 0.7;
        } else {
            if ((skip & 8u) == 0u) col = beyond(dE, d, sky, u, stars, ndc);
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
        if ((skip & 32u) == 0u) {
            float4 jet = steamJet(o, d, u, tHit, oct);
            col = col * (1.0 - jet.a) + jet.rgb;
            float4 tree = lavaTree(o, d, u, tHit);
            col = col * (1.0 - tree.a) + tree.rgb;
        }
        float fpA = ((u.fountA.y - o.y) / max(d.y, 1e-4)) * sky.up.w * u.cam.w;
        float fpB = ((u.fountB.y - o.y) / max(d.y, 1e-4)) * sky.up.w * u.cam.w;
        float4 fa = float4(0), fb = float4(0);
        if ((skip & 16u) == 0u) {
            fa = fountain(o, d, u.fountA, u, tHit, fpA, oct);
            fb = fountain(o, d, u.fountB, u, tHit, fpB, oct);
        }
        float ta = (u.fountA.y - o.y) / max(d.y, 1e-4), tb = (u.fountB.y - o.y) / max(d.y, 1e-4);
        float tm = (0.0 - o.y) / max(d.y, 1e-4);
        float4 farF = ta > tb ? fa : fb, nearF = ta > tb ? fb : fa;
        float farT = max(ta, tb);
        float4 mid = float4(0);
        float4 pl = float4(0);
        if (tm < tHit && tm > 0.0) {
            float3 P = o + d * tm;
            if ((skip & 32u) == 0u) mid = column(P, u, tm * sky.up.w * u.cam.w, oct);
            if ((skip & 64u) == 0u) {
                if (u.sprites.x > 0.5) {
                    constexpr sampler ps(filter::linear, address::clamp_to_edge);
                    pl = plumeTex.sample(ps, float2(0.5 + 0.5 * in.ndc.x, 0.5 - 0.5 * in.ndc.y));
                } else {
                    pl = plume(P, u, oct, u.glow.rgb);
                }
            }
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
        if ((skip & 128u) == 0u) {
            float4 fm = fume(o, d, min(tHit, tm > 0.0 ? max(tm, tHit) : tHit), u, oct);
            col = col * fm.a + fm.rgb;
        }
        // The near rim's rocks.
        if ((skip & 256u) == 0u) {
            float4 fg = foreground(in.ndc, u, oct);
            col = col * (1.0 - fg.a) + fg.rgb;
        }
        ColorDepth out;
        out.color = float4(max(col, 0.0), 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the plume at half size
    // The plume is soft gas (its finest billows metres across, tens of pixels): drawn into a half-size target wherever the
    // ray crosses its plane, and read back (filtered) by the scene, which still decides pixel by pixel what stands in
    // front of it.
    fragment float4 volcano_plume_fragment(VolOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                           constant VolcanoU& u [[buffer(1)]]) {
        float2 ndc = in.ndc - u.cam.xy;
        int oct = int(u.a.z + 0.5);
        float3 Dn = sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w);
        float3 dE = normalize(Dn);
        float3 fwd3 = float3(u.axes.xy, 0.0), right3 = float3(u.axes.zw, 0.0);
        float3 d = float3(dot(dE, right3), dot(dE, fwd3), dE.z);
        float3 o = u.eye.xyz;
        float tm = (0.0 - o.y) / max(d.y, 1e-4);
        if (tm <= 0.0) return float4(0.0);
        return plume(o + d * tm, u, oct, u.glow.rgb);
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
    // The keys are a pavement of hexagonal basalt columns along the near rim, seen a little from above: the white keys
    // the front row (their tops and their two front faces down to the bottom of the view), the black keys the row
    // behind, nested between them; where the piano has no black key the back row's column is plain rock. Each column's
    // height differs a touch. A played column glows from its joints (lava in them) and the cracks in its top.
    struct Column { float4 rect; float4 info; };   // NDC x0, y0, x1, y1; black 0/1, glow, pressed, 0
    struct ColumnOut { float4 pos [[position]]; float2 uv; float4 info; float seed; float2 size; float2 backSeed; };
    vertex ColumnOut volcano_column_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Column* cols [[buffer(0)]],
                                           constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Column k = cols[iid];
        ColumnOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        float cx = k.info.x > 0.5 ? 0.5 * (k.rect.x + k.rect.z) : k.rect.x;
        o.seed = hash12(float2(cx * 431.0, 7.3));
        o.backSeed = float2(hash12(float2(k.rect.x * 431.0, 7.3)), hash12(float2(k.rect.z * 431.0, 7.3)));
        o.size = float2((k.rect.z - k.rect.x) * view.x, k.rect.w - k.rect.y);
        return o;
    }

    /// Inside a pointy-topped hexagon (flat-to-flat 1, top view): the distance in from its edge (negative outside).
    float hexInside(float2 p) {
        float2 a = abs(p);
        return 0.5 - max(a.x, 0.5 * a.x + 0.8660254 * a.y);
    }

    fragment ColorDepth volcano_column_fragment(ColumnOut in [[stage_in]], constant float4& light [[buffer(0)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y;
        const float R = 0.5773503;     // the hexagon's corner radius (flat-to-flat 1)
        const float sq_ = 0.7;         // seen from a little above: the tops squashed this much
        float px = 0.0028 / max(in.size.x, 1e-4);   // a pixel, in key widths (about)
        float X = in.uv.x;
        float Hk = in.size.y / max(in.size.x, 1e-4);
        float Y = in.uv.y * Hk;
        float T = 760.0 + 420.0 * glow;
        float inv = 1.0 / T;
        float3 bb = float3(1.0, exp(0.38 - 1848.0 * inv), exp(2.036 - 8727.0 * inv)) * exp((T - 1150.0) * 0.0086957);
        float hot = smoothstep(0.0, 0.2, glow) * (0.35 + 0.65 * glow);
        float3 c = float3(0);
        float cover = 1.0;
        // A column's top: weathered rock, its far edges catching the crater's glow, a thin dark joint all round; lit
        // from inside along its joints and its cracks when its note plays.
        if (black) {
            float2 p = float2(X - 0.5, (Y - 0.5 * Hk) / sq_);
            float din = hexInside(p);
            cover = smoothstep(-px, px, din);
            if (cover < 0.004) discard_fragment();
            float grain = vn2(p * 9.0 + in.seed * 40.0);
            float rim = exp(-max(din, 0.0) / 0.05) * smoothstep(-0.1, 0.25, p.y);
            float joint = 1.0 - smoothstep(0.0, 0.035 + px, din);
            float3 rock = float3(0.07, 0.065, 0.06) * (0.7 + 0.5 * grain);
            c = rock * (light.rgb * (0.32 + 0.9 * rim)) * (1.0 - 0.7 * joint);
            float wig = (vn2(p * 7.0 + in.seed * 9.0) - 0.5) * 0.12;
            float crack = smoothstep(0.035 + px, 0.0, abs(p.x * 0.8 - p.y * 0.6 + (in.seed - 0.5) * 0.3 + wig)) * smoothstep(0.02, 0.12, din);
            c += bb * (hot * (exp(-max(din, 0.0) / 0.08) * 1.2 + 0.8 * crack + 0.12));
        } else {
            float dh = (in.seed - 0.5) * 0.1;
            float Yc = Hk - 2.5 * R * sq_ + dh;
            float x1 = X - 0.5;
            float2 pf = float2(x1, (Y - Yc) / sq_);
            float dinF = hexInside(pf);
            float topEdge = Yc - sq_ * (R - abs(x1) / 1.7320508);   // the top face's lower edge here
            if (dinF > -px * 2.0 || Y < topEdge) {
                if (Y >= topEdge - px) {
                    // The front column's top.
                    float grain = vn2(pf * 9.0 + in.seed * 40.0);
                    float rim = exp(-max(dinF, 0.0) / 0.05) * smoothstep(-0.1, 0.25, pf.y);
                    float joint = 1.0 - smoothstep(0.0, 0.035 + px, dinF);
                    float3 rock = float3(0.075, 0.069, 0.064) * (0.7 + 0.5 * grain);
                    c = rock * (light.rgb * (0.38 + 0.95 * rim)) * (1.0 - 0.7 * joint);
                    float wig = (vn2(pf * 7.0 + in.seed * 9.0) - 0.5) * 0.12;
                    float crack = smoothstep(0.035 + px, 0.0, abs(pf.x * 0.7 + pf.y * 0.7 - (in.seed - 0.5) * 0.3 + wig))
                                * smoothstep(0.02, 0.12, dinF);
                    c += bb * (hot * (exp(-max(dinF, 0.0) / 0.08) * 1.2 + 0.8 * crack + 0.12));
                } else {
                    // Its two front faces, in shade: the sky's light, a little of the glow on their edges; the
                    // prism's edges dark joints, glowing when it plays.
                    float leftF = x1 < 0.0 ? 1.0 : 0.0;
                    float down = (topEdge - Y) / max(topEdge, 1e-3);
                    float grain = vn2(float2(X * 6.0 + in.seed * 30.0, Y * 3.0));
                    float3 rock = float3(0.045, 0.041, 0.038) * (0.7 + 0.6 * grain);
                    float face = mix(0.07, 0.12, leftF) * (1.0 - 0.6 * down);
                    float edgeD = min(min(X, 1.0 - X), abs(x1)) ;
                    float joint = 1.0 - smoothstep(0.0, 0.03 + px, edgeD);
                    float lip = exp(-(topEdge - Y) / 0.05);
                    c = rock * light.rgb * (face + 0.35 * lip) * (1.0 - 0.7 * joint);
                    float crossJ = smoothstep(0.46 - px, 0.495, abs(fract(Y * 0.9 + in.seed * 3.0 + x1 * 0.2) - 0.5));
                    float seep = exp(-edgeD / 0.07);
                    c += bb * (hot * (seep * 0.9 + lip * 0.7 + crossJ * 0.4 + 0.08) * (1.0 - 0.55 * down));
                }
            } else {
                // The back row: the column nested to the left or right (a black key draws over it when there is one).
                float xb = X < 0.5 ? X : X - 1.0;
                float sb = X < 0.5 ? in.backSeed.x : in.backSeed.y;
                float Ycb = Yc - dh + 1.5 * R * sq_ + (sb - 0.5) * 0.1;
                float2 pb = float2(xb, (Y - Ycb) / sq_);
                float dinB = hexInside(pb);
                cover = smoothstep(-px, px, dinB);
                if (cover < 0.004) discard_fragment();
                float grain = vn2(pb * 9.0 + sb * 40.0);
                float rim = exp(-max(dinB, 0.0) / 0.05) * smoothstep(-0.1, 0.25, pb.y);
                float joint = 1.0 - smoothstep(0.0, 0.035 + px, dinB);
                float3 rock = float3(0.068, 0.063, 0.058) * (0.7 + 0.5 * grain);
                c = rock * (light.rgb * (0.3 + 0.9 * rim)) * (1.0 - 0.7 * joint);
            }
        }
        ColorDepth o;
        o.color = float4(c * cover, cover);
        o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
