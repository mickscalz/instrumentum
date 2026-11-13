/// Metal source for Lightning Plains (Storms spec §9): the vast dusk sky over a dry grass plain, the storm's line of
/// cumulonimbus on the horizon (soft-edged cauliflower over billows on billows, self-shaded, their crowns rose and gold
/// while they stand above Earth's shadow, a thin warm rim on their sunward edges, lit from inside by their flashes and the
/// heat lightning, a lining where the light is behind them; feathered, fibrous anvils streaming downwind; softened and
/// blued by the air between, less as the storm nears), its ragged dark base with rain curtains hanging under it, the far
/// glow beneath it, the ridge and the ball lightning; then Strike Lines' forks and crawlers as analytic segments; then the
/// props back to front: grass rows bending on the wind field, the fence posts (the keys) with their wires, the windmill,
/// the tank, a dust devil and the rain curtain. Built on SkyShaders.common (skyRadiance with the real stars). Smooth
/// rules: no ray marching, at most 3 noise octaves (2 on Smooth), analytic everything; squares are written out (no powers).
enum LightningPlainsShaders {
    static let source = SkyShaders.common + """
    // ---------------------------------------------------------------- Lightning Plains
    struct PlainsU {
        float4 frame;      // aspect, time (s), horizon (NDC y), noise octaves
        float4 view;       // eye height (m), a pixel's angle (rad), gentle 0/1, the storm's lump size (deg)
        float4 shake;      // camera shake (NDC xy), the drop's sheet-lit sky (after the limiter), the storm's distance (km)
        float4 storm;      // bearing (deg from north), the line's half-width (deg), dry 0/1, the base's near edge (altitude, deg)
        float4 ahead;      // the view's level forward (east, north), its right (east, north)
        float4 ambient;    // the sky's light on things (rgb), night 0…1
        float4 glow;       // the low sky behind the silhouettes (rgb), the sun's offset from the bearing (deg)
        float4 sun;        // the sun on the towers' tops 0…1, Earth's shadow's height there (km), one pixel (NDC y), its altitude (deg)
        float4 flash;      // the strikes' light on the plain (rgb, after the limiter), unused
        float4 ridge;      // from, to (offsets, deg), height (deg), distance (km)
        float4 ball;       // offset (deg), altitude (deg), brightness, radius (deg)
        float4 shafts;     // the rain shafts' strength, their slant, virga 0…1, the base's far edge (altitude, deg)
        float4 towerA[5];  // offset (deg), the turret's half-width (deg), its top (deg), the anvil's half-spread (deg)
        float4 towerB[5];  // the anvil's base (deg), distance (km), seed, rain shaft 0…1
        float4 lightA[8];  // light inside the storm: offset (deg), altitude (deg), radius (deg), level (0: empty)
        float4 lightC[8];  // its colour (rgb), unused
        float4 rim[4];     // heat lightning on the rim: offset (deg), half-width (deg), height (deg), brightness
    };

    struct PlainsOut { float4 pos [[position]]; float2 ndc; };

    float pl_sq(float x) { return x * x; }
    /// Smooth value noise along a line (two hashes).
    float pl_noise1(float x, float seed) {
        float i = floor(x), f = x - i;
        float a = hash33(float3(i, seed, 0.37)).x, b = hash33(float3(i + 1.0, seed, 0.37)).x;
        return mix(a, b, f * f * (3.0 - 2.0 * f));
    }
    float pl_wrap(float a) { return a - 360.0 * floor((a + 180.0) / 360.0); }

    vertex PlainsOut plains_vertex(uint vid [[vertex_id]]) {
        float2 c[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        PlainsOut o;
        o.pos = float4(c[vid], 0, 1);
        o.ndc = c[vid];
        return o;
    }

    float3 pl_ray(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    float pl_smin(float a, float b, float k) {
        float h = saturate(0.5 + 0.5 * (b - a) / k);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    /// The sun's direction in the view's frame: (right, up, toward you).
    float3 pl_sunView(constant SkyU& u) {
        float3 S = u.sun.xyz;
        return normalize(float3(dot(S, u.right.xyz), dot(S, u.up.xyz), -dot(S, u.forward.xyz)) + float3(0.0, 0.0, 1e-4));
    }

    /// The sun's light on cloud `above` km over Earth's shadow there: none inside the shadow, deep rose at its edge, peach
    /// and gold higher up; near white once the sun is well up.
    float3 pl_sunlight(float above, constant PlainsU& p) {
        float lit = p.sun.x * smoothstep(-0.8, 1.4, above);
        float warm = 1.0 - smoothstep(3.0, 16.0, p.sun.w);
        float3 low = mix(float3(1.0, 0.22, 0.13), float3(1.0, 0.5, 0.3), smoothstep(0.2, 7.0, above));
        return mix(float3(1.0, 0.95, 0.88), low, warm) * lit;
    }

    /// The light on the plain's things from the low sky behind you (the afterglow, when the sunset is at your back) and
    /// the sun itself while it is up.
    float3 pl_frontLight(constant SkyU& u, constant PlainsU& p) {
        float3 L = pl_sunView(u);
        float sunAlt = u.sun.w;
        float low = saturate(1.0 - abs(sunAlt) / 15.0);
        float dusk = smoothstep(-11.0, -2.0, sunAlt);
        float3 after = (u.horizon.rgb * 0.45 + float3(0.9, 0.42, 0.14) * 0.6 * low) * dusk * saturate(0.3 + 0.7 * L.z);
        float up = smoothstep(-1.0, 3.0, sunAlt) * saturate(0.25 + 0.75 * L.z);
        return after + pl_sunlight(4.0, p) * 0.9 * up;
    }

    /// What the storm's cloud is at a point of the sky: how far inside it (deg, < 0 inside) and how much it covers the
    /// sky there (its soft, eroded edge), its surface's normal in the view's frame (right, up, toward you), the creases'
    /// shade (1 open … low in the folds between lobes), how much of it is anvil (smooth, fibrous) rather than turret, how
    /// thick it is (0 at its edge … 1 deep inside), the nearest tower's distance and how far up it the point is (0 at
    /// the base … 1 at its top), how much of it is the low shelf along the line, how much the base's dark underside,
    /// the big lobe's dome there (1 at its middle … 0 in a fold) and the edge's outward direction on screen.
    struct PlStorm { float d; float a; float3 n; float ao; float anvil; float thick; float km; float rel; float shelf;
                     float under; float dome; float2 out2; };

    /// Distances that carry their gradient: (distance, d/dx, d/dy). The smooth union's exact gradient is the blend of its
    /// two gradients by the same weight; a max takes the larger's.
    float3 pl_dmin(float3 a, float3 b, float k) {
        float h = saturate(0.5 + 0.5 * (b.x - a.x) / k);
        return float3(mix(b.x, a.x, h) - k * h * (1.0 - h), mix(b.yz, a.yz, h));
    }
    float3 pl_dmax(float3 a, float3 b) { return a.x > b.x ? a : b; }
    float3 pl_circle(float2 q, float2 c, float r) {
        float2 v = q - c;
        float l = max(length(v), 1e-5);
        return float3(l - r, v / l);
    }

    /// The storm's envelope at (offset th × the altitude's squeeze, altitude), degrees: five cumulonimbus on a long low
    /// shelf of cloud that joins them along the line. Each: a core from the storm's base, broad at its foot, with puffs
    /// bulging out of its sides as it climbs (leaning a little downwind) and a cauliflower head of three domes; the grown
    /// ones an anvil, flat on top, its underside sweeping up from the head to a thin edge far downwind and a short way
    /// upwind, and an overshooting dome over the updraft. Returns the smooth union's distance (deg, < 0 inside) with its
    /// gradient; in `anvilShare` how much the anvils make it, in `km` the nearest tower's distance, in `rel` how far up
    /// that tower the point is (0 at its base … 1 at its top) and in `shelfShare` how much the low shelf makes it.
    float3 pl_envelope(float x, float alt, constant PlainsU& p, thread float& anvilShare, thread float& km,
                       thread float& rel, thread float& shelfShare) {
        float3 d = float3(1e4, 0.0, 1.0);
        float anvilBest = 1e4, turretBest = 1e4;
        float wsum = 1e-6, kmSum = 0.0, relSum = 0.0, raining = 0.0;
        float squeeze = cos(toRad(clamp(alt, 0.0, 85.0)));
        for (int i = 0; i < 5; i++) {
            float4 a = p.towerA[i];
            float4 b = p.towerB[i];
            if (a.z <= 0.0) continue;
            float c = a.x * squeeze, w = a.y, T = a.z, A = a.w, Ab = b.x;
            float dx = x - c;
            float under = dx / (1.6 * w);
            raining += b.w * exp(-under * under);
            if (dx < -0.45 * A - 2.0 * w || dx > A + 2.0 * w || alt > T + w || alt < -1.0) continue;
            float base = toDeg(atan(1.6 / max(b.y, 0.1)));
            float k = 0.3 * w;
            float thick = T - Ab;
            bool anvilled = A > 1.3 * w;
            float crown = anvilled ? Ab + 0.15 * thick : T - 0.85 * w;
            float y = saturate((alt - base) / max(crown - base, 0.1));
            float lean = 0.18 * w * y;
            float side = dx - lean >= 0.0 ? 1.0 : -1.0;
            // The core widens as it climbs (the updraft spreading) and flares at its foot into the base.
            float skirt = w * (0.5 + 0.22 * y) + 0.25 * w * (1.0 - y) * (1.0 - y);
            float3 turret = pl_dmax(pl_dmax(float3(abs(dx - lean) - skirt, side, 0.0), float3(base - alt, 0.0, -1.0)),
                                    float3(alt - crown, 0.0, 1.0));
            // The puffs, the head and the flanking turrets only near the tower (they reach 2.4 widths out; beyond, the
            // core's distance, less their reach, stands in: the storm's detail never reaches that far).
            float far = max(abs(dx - 0.09 * w) - 2.6 * w, max(alt - crown - 2.3 * w, base - 1.2 * w - alt));
            if (far > 0.0) {
                turret.x -= 1.4 * w;
            } else {
                float2 at = float2(dx, alt);
                for (int j = 0; j < 7; j++) {
                    float3 h = hash33(float3(b.z, float(j), 1.7));
                    float v = (float(j) + 0.3 + 0.4 * h.x) / 7.0;
                    float sd = (j % 2 == 0) ? -1.0 : 1.0;
                    float2 c2 = float2(0.18 * w * v + sd * w * (0.3 + 0.28 * h.y) * (0.85 + 0.3 * v),
                                       base + v * (crown - base));
                    float r = w * (0.4 + 0.26 * h.z) * (0.8 + 0.4 * v);
                    turret = pl_dmin(turret, pl_circle(at, c2, r), 0.22 * w);
                }
                float3 hh = hash33(float3(b.z, 9.0, 4.1));
                turret = pl_dmin(turret, pl_circle(at, float2(-0.3 * w, crown - (0.15 + 0.2 * hh.x) * w), 0.72 * w), 0.2 * w);
                turret = pl_dmin(turret, pl_circle(at, float2(0.23 * w, crown + 0.05 * w), (0.88 + 0.15 * hh.z) * w), 0.2 * w);
                turret = pl_dmin(turret, pl_circle(at, float2(0.78 * w, crown - (0.25 + 0.2 * hh.y) * w), 0.64 * w), 0.2 * w);
                // The flanking line: a younger turret stepping down beside the grown towers, upwind: a dome on a
                // broader, lower one.
                if (anvilled) {
                    float3 h = hash33(float3(b.z, 2.0, 6.3));
                    float cx = -w * (0.95 + 0.2 * h.x) + 0.5 * lean;
                    float top = base + (crown - base) * (0.5 + 0.12 * h.y);
                    float r = w * (0.38 + 0.08 * h.z);
                    turret = pl_dmin(turret, pl_circle(at, float2(cx + 0.1 * w, base + 0.35 * (top - base)), 1.25 * r), 0.3 * w);
                    turret = pl_dmin(turret, pl_circle(at, float2(cx - 0.05 * w, top - r), r), 0.3 * w);
                }
            }
            float3 tower = turret;
            float anvilD = 1e4;
            if (anvilled) {
                float2 ov = float2((dx - 0.1 * w) * 0.75, alt - (T - 0.35 * w));
                float lo = max(length(ov), 1e-5);
                turret = pl_dmin(turret, float3(lo - 0.6 * w, 0.75 * ov.x / lo, ov.y / lo), 0.6 * k);
                float reach = dx > 0.0 ? A : 0.2 * A;
                float ax = dx / max(reach, 1e-3);
                float sa = ax >= 0.0 ? 1.0 : -1.0;
                // Flat on top (the tropopause), its underside rising gently to a blunt edge downwind: an anvil, not a
                // tapering tail.
                float topE = T + 0.05 * thick - thick * 0.05 * ax * ax + 0.04 * thick * sin(dx / max(w, 1e-3) * 1.7 + b.z);
                float botE = Ab + thick * (-0.25 + 0.2 * abs(ax) + 0.5 * ax * ax);
                float3 topD = float3(alt - topE, thick * 0.24 * ax / reach, 1.0);
                float3 botD = float3(botE - alt, thick * (0.3 * sa + 0.84 * ax) / reach, -1.0);
                float3 endD = float3((abs(ax) - 1.0) * reach * 0.3, 0.3 * sa, 0.0);
                float3 anvil = pl_dmax(pl_dmax(topD, botD), endD);
                anvilD = anvil.x;
                tower = pl_dmin(turret, anvil, 1.6 * k);
            }
            // Which tower a point belongs to, softly (the deeper inside, the more), so its distance and height in it
            // blend across the joins without seams.
            float own = exp(-clamp(tower.x / (0.3 * w), -12.0, 12.0));
            wsum += own;
            kmSum += own * b.y;
            relSum += own * saturate((alt - base) / max(T - base, 0.1));
            d = pl_dmin(d, tower, 0.5 * k);
            anvilBest = min(anvilBest, anvilD);
            turretBest = min(turretBest, turret.x);
        }
        // The shelf along the line, rolling, a ninth of the middle storm's height; the base under it.
        float lineHalf = p.storm.y;
        float base = p.storm.w;
        float roll = 0.5 + 0.5 * sin(x * 0.21 + 1.3) * sin(x * 0.067 + 0.4);
        float shelfTop = base + (0.45 + 0.55 * roll) * max(p.towerA[2].z - base, 0.5) * 0.11;
        // Its underside reaches furthest (deepest, darkest) under the grown, raining towers and lifts between them.
        float bottom = mix(p.storm.w, p.shafts.w, saturate(1.3 * raining - 0.25));
        float3 shelf = pl_dmax(pl_dmax(float3(alt - shelfTop, 0.0, 1.0), float3(bottom - alt, 0.0, -1.0)),
                               float3(abs(x) - lineHalf, x >= 0.0 ? 1.0 : -1.0, 0.0));
        km = wsum > 1e-5 ? kmSum / wsum : p.shake.w;
        rel = wsum > 1e-5 ? relSum / wsum : 0.0;
        float lump = max(p.view.w, 0.05);
        shelfShare = smoothstep(-0.3 * lump, 0.3 * lump, min(turretBest, anvilBest) - shelf.x);
        d = pl_dmin(d, shelf, 0.9);
        anvilShare = smoothstep(-0.4 * lump, 0.4 * lump, turretBest - anvilBest);
        return d;
    }

    /// One octave of billows: domes of jittered sizes on a grid of `cell` degrees. Returns the domes' soft maximum over
    /// the point (0…1; low in the folds between them) and, in `at`, where on them the point lies (the tallest domes'
    /// offsets from their middles over their radii, softly blended so the folds stay soft): its surface's slope.
    float pl_billow(float2 q, float cell, float seed, thread float2& at) {
        float2 g = floor(q / cell);
        float wsum = 1e-4, hsum = 0.0;
        float2 nsum = float2(0.0);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 id = g + float2(float(i), float(j));
                float3 h = hash33(float3(id, seed));
                float2 c = (id + 0.15 + 0.7 * h.xy) * cell;
                float r = cell * (0.75 + 0.4 * h.z);
                float2 dd = (q - c) / r;
                float l2 = dot(dd, dd);
                if (l2 < 1.0) {
                    float hgt = sqrt(1.0 - l2) * (0.7 + 0.3 * h.z);
                    float w = exp(9.0 * hgt) - 1.0;
                    wsum += w; hsum += w * hgt; nsum += w * dd;
                }
            }
        }
        at = nsum / wsum;
        return hsum / wsum;
    }

    float2 pl_turn(float2 q, float c, float s) { return float2(q.x * c - q.y * s, q.x * s + q.y * c); }

    /// The storm at (offset th, altitude alt), degrees: the envelope, its outline thrown into cauliflower by billows on
    /// billows (three octaves, two on Smooth; knobbly at the climbing crowns, softer down the rain-washed flanks, gentle
    /// on the anvils) and eroded into wisps; the anvils frayed into fibres streaming downwind; the base's underside
    /// ragged. Its edge is soft (a few pixels on the crowns, wide and feathered on the anvils), crisper as the storm
    /// nears. The surface's normal is the tower's rounded mass (from the envelope's slope, turning to face you over a
    /// few lobes' depth) with the lobes' own domes on it.
    PlStorm pl_storm(float th, float alt, constant PlainsU& p, int octaves, float time) {
        PlStorm st;
        float squeeze = cos(toRad(clamp(alt, 0.0, 85.0)));
        float x = th * squeeze;
        float anvil = 0.0, km = p.shake.w, rel = 0.0, shelf = 0.0;
        float3 e3 = pl_envelope(x, alt, p, anvil, km, rel, shelf);
        float e = e3.x;
        st.km = km; st.anvil = anvil; st.rel = rel; st.shelf = shelf; st.n = float3(0.0, 0.0, 1.0); st.ao = 1.0;
        st.thick = 0.0; st.a = 0.0; st.under = 0.0; st.dome = 0.5; st.out2 = float2(0.0, 1.0);
        float s = max(p.view.w, 0.05);
        if (e > 1.6 * s) { st.d = e; return st; }
        float near = smoothstep(40.0, 6.0, p.shake.w);
        float2 outward = e3.yz / max(length(e3.yz), 1e-5);
        st.out2 = outward;
        float2 q = float2(x, alt);
        float drift = time * 0.012;
        float2 nb, ns = float2(0.0), nt = float2(0.0);
        float hb = pl_billow(q + float2(drift, 0.0), 1.5 * s, 3.1, nb);
        float hs = pl_billow(pl_turn(q, 0.866, 0.5) + 17.3, 0.55 * s, 8.7, ns);
        // Knobbly crowns, softer rain-washed flanks, a gentle anvil and a low, lumpy shelf.
        float crisp = smoothstep(0.3, 0.8, rel) * (1.0 - anvil) * (1.0 - shelf);
        // (the anvil's underside sags into pouches: mammatus)
        float belly = anvil * smoothstep(0.2, 0.8, -outward.y);
        float amp = mix(1.0, mix(0.25, 0.8, belly), anvil) * mix(0.8, 1.2, crisp) * mix(1.0, 0.6, shelf);
        // Clear of the cloud whatever the finest billows, wisps and fibres do: done.
        if (-e + amp * s * (0.75 * (hb - 0.45) + 0.36 * (hs - 0.45) + 0.1) + 0.6 * s < 0.0) { st.d = e; return st; }
        float ht = octaves > 2 ? pl_billow(pl_turn(q, 0.906, -0.423) + 5.1, 0.22 * s, 2.9, nt) : 0.6;
        float bump = 0.75 * (hb - 0.45) + 0.36 * (hs - 0.45) + 0.18 * (ht - 0.45);
        float wisp = vnoise3(float3((q.x - drift) / (0.5 * s), q.y / (0.5 * s), 1.9)) - 0.5;
        float fibre = vnoise3(float3((q.x - 2.5 * drift) / (3.2 * s), q.y / (0.13 * s) + 0.12 * q.x / s, 5.3)) - 0.5;
        // The base's dark underside (seen in depth from its near edge back), its far edge ragged with scud.
        float front = p.storm.w;
        float scud = vnoise3(float3(q.x / (0.7 * s), q.y / (0.2 * s), 7.7)) - 0.5;
        st.under = smoothstep(front + 0.1 * s, front - 0.3 * s, alt + 0.5 * s * scud) * (1.0 - anvil);
        float ends = abs(outward.x);
        float depth = -e + amp * s * bump + s * (mix(0.22, 0.12, crisp) * mix(1.0, 0.5, near) * (1.0 - anvil) * wisp
                                                 + mix(0.05, 0.1, ends) * anvil * fibre)
                      + st.under * s * 0.5 * scud;
        float aa = toDeg(p.view.y);
        float feather = s * mix(mix(0.2, 0.07, crisp), mix(0.18, 0.38, ends), anvil) * mix(1.0, 0.55, near) + 0.6 * aa;
        st.a = smoothstep(-0.5 * aa, feather, depth);
        st.d = -depth;
        st.thick = saturate(depth / (1.3 * s));
        // The anvil's thin edges stream away in strands of ice, some denser, some all but gone.
        float strands = saturate(0.5 + 1.7 * fibre);
        st.a *= mix(1.0, strands, anvil * (1.0 - smoothstep(0.08, 0.45, st.thick)) * mix(0.2, 0.45, ends));
        float t = 1.0 - saturate(depth / (mix(1.6, 1.0, anvil) * s));
        t *= 1.0 - 0.55 * anvil;
        float3 mass = float3(outward * t, sqrt(saturate(1.0 - t * t)));
        float2 lobes = (nb * 0.75 + pl_turn(ns, 0.866, -0.5) * 0.32 + pl_turn(nt, 0.906, 0.423) * 0.16) * amp;
        st.n = normalize(mass + float3(lobes, 1e-3));
        st.ao = (0.5 + 0.5 * smoothstep(0.0, 0.8, hb)) * (0.78 + 0.22 * smoothstep(0.0, 0.7, hs))
              * (0.9 + 0.1 * smoothstep(0.0, 0.6, ht));
        st.ao = mix(st.ao, 1.0, 0.65 * anvil);
        st.dome = hb;
        return st;
    }

    /// The sky's own colour toward (alt, deg) along the storm's bearing, without its stars: the air between you and the
    /// storm glows with it (the same gradient, Belt of Venus and Earth's shadow the sky draws).
    float3 pl_air(float3 d, float alt, constant SkyU& u) {
        float a = max(toRad(alt), 0.0);
        float band = exp(-a / (0.2 + 0.25 * u.weather.x));
        float3 col = mix(u.zenith.rgb, u.horizon.rgb, band);
        col = mix(col, u.horizon.rgb * 1.05, u.weather.x * 0.6 * exp(-a / 0.12));
        float belt = beltOfVenus(u.sun.w);
        if (belt > 0.0) {
            float2 hs = u.sun.xy / max(length(u.sun.xy), 1e-4), hd = d.xy / max(length(d.xy), 1e-4);
            float away = saturate(-dot(hs, hd));
            away *= away;
            float b = smoothstep(4.0, 7.0, alt) * (1.0 - smoothstep(16.0, 22.0, alt));
            col += float3(1.0, 0.62, 0.70) * 0.12 * belt * (1.0 + u.extra.y) * b * away;
            float shadow = (1.0 - smoothstep(2.0, 5.0, alt)) * away * belt;
            float l = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(col, l * float3(0.8, 0.86, 1.02), 0.6 * shadow) * (1.0 - 0.25 * shadow);
        }
        return col;
    }

    /// The storm's light at a point of it. The last sun (behind you at dusk, over your right shoulder) lights the faces
    /// turned to it, wrapping round the lobes, rose at Earth's shadow's edge and peach and gold above it, none below;
    /// its thin sunward edges glow as it comes through them (a thin warm rim). Where the sun is behind the storm, a
    /// lining. The sky lights the rest, more from above and less in the folds, and less down the towers (the mass above
    /// shades them) and least on the base's underside; the afterglow behind you warms the faces turned to you. The
    /// flashes' light diffuses through it from inside, brightest where it is thin: at its edges and in the folds
    /// between lobes, dimmer through the domes. Then the air between: the distant towers soften into the sky's own
    /// colour, their feet (in the thick low air) more than their crowns.
    float3 pl_stormLight(float3 d, float th, float alt, PlStorm st, constant SkyU& u, constant PlainsU& p, int octaves,
                         float time) {
        float squeeze = cos(toRad(clamp(alt, 0.0, 85.0)));
        float s = max(p.view.w, 0.05);
        float3 L = pl_sunView(u);
        float heightKm = st.km * tan(toRad(clamp(alt, 0.0, 80.0)));
        float3 sun = pl_sunlight(heightKm - p.sun.y, p);
        float wrap = saturate((dot(st.n, L) + 0.3) / 1.3);
        float direct = wrap * wrap * mix(0.3, 1.0, st.ao);
        float2 Lxy = L.xy / max(length(L.xy), 1e-4);
        float thin = 1.0 - st.thick;
        float rim = thin * thin * thin * saturate(0.15 + 0.85 * dot(st.out2, Lxy)) * (1.0 - st.under);
        float lining = thin * thin * saturate(-L.z) * (0.5 + 0.5 * saturate(dot(st.n.xy, L.xy)));
        float patch = vnoise3(float3(th * squeeze / (4.0 * s), alt / (4.0 * s), 2.2 + time * 0.004));
        float fibres = 1.0;
        if (st.anvil > 0.01) fibres = mix(1.0, 0.82 + 0.36 * vnoise3(float3(th * squeeze / (2.5 * s), alt / (0.22 * s), 6.6)), st.anvil);
        float3 col = sun * (1.25 * direct * fibres + (1.0 - 0.7 * st.anvil) * rim + 1.2 * lining);
        float sunLum = dot(col, float3(0.2126, 0.7152, 0.0722));
        float skyward = 0.5 + 0.5 * st.n.y;
        skyward = 0.25 + 0.85 * skyward * skyward;
        float shaded = mix(0.45, 1.0, smoothstep(0.0, 0.6, st.rel)) * mix(1.0, 0.75, st.shelf) * mix(1.0, 0.15, st.under);
        float3 skyLight = mix(p.ambient.rgb, u.zenith.rgb * 1.15, 0.5 * saturate(-st.n.x));   // the far side sees the dark east
        col += skyLight * (0.9 * skyward * st.ao * shaded * (0.85 + 0.3 * patch) * (1.0 - 0.5 * saturate(2.0 * sunLum)));
        float3 Lg = normalize(float3(L.x, 0.12, max(L.z, 0.2)));
        col += pl_frontLight(u, p) * (0.55 * saturate(dot(st.n, Lg)) * st.ao * shaded);
        col += p.glow.rgb * (0.08 * saturate(-st.n.y) + 0.06 * st.under);
        float3 glow = float3(0.0);
        for (int i = 0; i < 8; i++) {
            float4 l = p.lightA[i];
            if (l.w <= 0.0) continue;
            float2 dd = float2(pl_wrap(th - l.x) * squeeze, alt - l.y) / max(l.z, 0.05);
            float r2 = dot(dd, dd);
            glow += p.lightC[i].rgb * (l.w * (0.45 * exp(-0.6 * r2) + 0.5 * exp(-1.3 * sqrt(r2))));
        }
        glow += float3(0.8, 0.82, 1.0) * p.shake.z * 0.6;
        float through = (0.3 + 0.7 * thin * thin) * (1.45 - 0.9 * st.dome) * mix(0.75, 1.0, st.ao) * (0.7 + 0.6 * patch);
        col += glow * through * 0.85;
        // The air between: thick near the plain, thin up at the crowns.
        float dense = 0.2 + 0.8 * exp(-max(heightKm, 0.0) / 2.5);
        float clear = exp(-st.km * dense / 45.0);
        // (the air in the storm's shadow, under its base, is dim)
        col = mix(pl_air(d, alt, u) * (1.0 - 0.5 * st.under), col, clear);
        return col;
    }

    /// The anvil's canopy streaming toward you: a thin veil of ice cloud at the anvil's height, from the storm out over
    /// the plain (further overhead the nearer the storm), downwind to the right; frayed, in soft streaks along its flow.
    /// The last sun keeps it rose and gold longest (it is high); by night a dark veil over the stars, lit by the flashes
    /// in it. Returns (colour, cover).
    float4 pl_canopy(float3 d, float th, float alt, constant SkyU& u, constant PlainsU& p, int octaves, float time) {
        if (alt < 2.0) return float4(0.0);
        float km = p.shake.w;
        float H = km * tan(toRad(p.towerA[2].z)) * 0.82;        // the canopy's height (km)
        float r = H / max(tan(toRad(alt)), 1e-3);                // where the ray meets it, ahead (km)
        float near = clamp(0.3 * km, 3.0, 14.0);
        float reach = km - near;
        float along = saturate((km - r) / max(reach, 1e-3));    // 0 at the storm … 1 at its near edge
        if (r > km * 1.05 || r < near * 0.6) return float4(0.0);
        float across = r * tan(toRad(clamp(th, -80.0, 80.0)));  // km to the right of the storm's bearing
        float right = across + 0.25 * (km - r);                 // it fans out downwind as it comes
        float spread = 0.6 * km + 8.0 * along;
        float side = smoothstep(-0.25 * spread, 0.1 * spread, right) * (1.0 - smoothstep(0.8 * spread, 1.3 * spread, right));
        float fade = side * smoothstep(1.05, 0.9, r / km) * (1.0 - smoothstep(0.55, 1.0, along)) * 0.55;
        if (fade < 0.002) return float4(0.0);
        float body = fbm3(float3(right * 0.07, r * 0.09 - time * 0.002, 3.3), max(octaves - 1, 1));
        if (body < 0.4) return float4(0.0);
        float fibre = vnoise3(float3(right * 0.12 + r * 0.05, r * 0.9, 7.1));
        float cover = smoothstep(0.4, 0.72, body) * (0.45 + 0.55 * fibre) * fade;
        if (cover < 0.002) return float4(0.0);
        float3 sun = pl_sunlight(H - p.sun.y, p);
        float3 col = sun * 0.75 + p.ambient.rgb * 0.45;
        float3 glow = float3(0.0);
        for (int i = 0; i < 8; i++) {
            float4 l = p.lightA[i];
            if (l.w <= 0.0) continue;
            float2 dd = float2(pl_wrap(th - l.x), alt - l.y) / max(2.5 * l.z, 0.05);
            glow += p.lightC[i].rgb * (l.w * exp(-dot(dd, dd)));
        }
        col += (glow * 0.35 + float3(0.8, 0.82, 1.0) * p.shake.z * 0.5) * (0.5 + 0.5 * fibre);
        return float4(col, cover);
    }

    /// The rain shafts hanging from the storm's base to the plain (to half way under virga): grey curtains in a few
    /// folds, streaked, slanting with the wind and spreading a little toward the ground.
    float pl_shafts(float th, float alt, constant PlainsU& p, float time) {
        float front = p.storm.w;
        if (alt < -0.4 || alt > 1.05 * front) return 0.0;
        float down = 1.0 - saturate(alt / max(front, 1e-3));
        float v = 0.0;
        for (int i = 0; i < 5; i++) {
            float4 a = p.towerA[i];
            float w = p.towerB[i].w;
            if (w <= 0.0 || a.z <= 0.0) continue;
            float slanted = th - a.x + p.shafts.y * (front - alt);
            float wide = a.y * (0.8 + 0.35 * down);
            v = max(v, w * (1.0 - smoothstep(0.2, 0.95, abs(slanted) / max(wide, 1e-3))));
        }
        if (v <= 0.0) return 0.0;
        float s = max(p.view.w, 0.05);
        float along = th + p.shafts.y * alt;
        float folds = vnoise3(float3(along / (0.45 * s), 0.5, 4.4));
        float streak = vnoise3(float3(along / s * 5.0, alt / s * 0.35 + time * 0.6, 2.3));
        float hang = smoothstep(1.05 * front, 0.82 * front, alt);
        float reach = mix(1.0, smoothstep(0.3 * front, 0.65 * front, alt), p.shafts.z);
        return v * p.shafts.x * (0.3 + 0.7 * folds) * (0.6 + 0.4 * streak) * hang * reach;
    }

    /// The far ridge's top (altitude, deg) at offset th: a mesa rising off the plain on the right, its flat top gently
    /// rolling, a bench in its escarpment; -1 off its ends. (The renderer's `ridgeTop` is the same curve.)
    float pl_ridgeTop(float th, constant PlainsU& p) {
        float4 r = p.ridge;
        float u = (th - r.x) / max(r.y - r.x, 1e-3);
        if (u <= 0.0 || u >= 1.0) return -1.0;
        float rise = smoothstep(0.0, 0.1, u) * (1.0 - smoothstep(0.88, 1.0, u));
        float mesa = 0.8 + 0.12 * sin(u * 9.0 + 1.3) + 0.08 * sin(u * 23.0 + 0.4) - 0.18 * smoothstep(0.42, 0.47, u);
        return r.z * rise * mesa;
    }

    /// How much of the far ridge covers the sky at (th, alt), antialiased.
    float pl_ridge(float th, float alt, constant PlainsU& p) {
        float top = pl_ridgeTop(th, p);
        return top > 0.0 ? smoothstep(top + 0.05, top - 0.05, alt) : 0.0;
    }

    fragment ColorDepth plains_scene_fragment(PlainsOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                              constant PlainsU& p [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc - p.shake.xy;
        float3 d = pl_ray(ndc, u);
        float alt = toDeg(asin(clamp(d.z, -1.0, 1.0)));
        float th = pl_wrap(toDeg(atan2(d.x, d.y)) - p.storm.x);
        int octaves = int(p.frame.w + 0.5);
        float time = p.frame.y;

        // The sky (just over the horizon for the ground's haze).
        float moonMask = 0.0;
        float3 skyDir = normalize(float3(d.xy, max(d.z, 0.0015)));
        float3 col = skyRadiance(skyDir, u, moonMask, stars);

        // Heat lightning on the rim behind the storm: warm-white, soft-edged.
        for (int i = 0; i < 4; i++) {
            float4 r = p.rim[i];
            if (r.w <= 0.0) continue;
            float dth = pl_wrap(th - r.x);
            if (abs(dth) >= r.y) continue;
            float across = 0.5 + 0.5 * cos(3.14159265 * dth / r.y);
            float upward = exp(-2.0 * max(alt, 0.0) / max(r.z, 0.1)) * smoothstep(-0.5, 0.0, alt);
            col += float3(1.0, 0.88, 0.72) * (r.w * 1.6 * across * upward);
        }

        // The anvil's canopy and the far ridge (the storm and its rain are their own pass, over them, and under the
        // ridge while the ridge is the nearer).
        if (alt > -0.5) {
            float4 canopy = pl_canopy(d, th, alt, u, p, octaves, time);
            col = mix(col, canopy.rgb, canopy.a);
            float3 front = pl_frontLight(u, p);
            float ridge = pl_ridge(th, alt, p);
            float3 ridgeCol = mix(p.ambient.rgb * 0.3 + front * 0.3, p.glow.rgb * 0.8, 0.5) + p.flash.rgb * 0.05;
            col = mix(col, ridgeCol, ridge);
            // Ball lightning rolling along the ridge.
            if (p.ball.z > 0.0) {
                float2 bd = float2(pl_wrap(th - p.ball.x), alt - p.ball.y) / max(p.ball.w, 0.01);
                float r2 = dot(bd, bd);
                col += float3(1.0, 0.7, 0.4) * p.ball.z * (3.0 * exp(-r2) + 0.3 * exp(-0.5 * sqrt(r2)));
            }
        }

        // The plain beyond the grass, fading into the horizon's haze; lit by the strikes; dark and wet after rain.
        if (d.z < 0.0) {
            float g = p.view.x / max(-d.z, 1e-5);
            float2 flat = d.xy / max(length(d.xy), 1e-5) * g;
            float2 gp = float2(dot(flat, p.ahead.zw), dot(flat, p.ahead.xy));
            float tex = fbm3(float3(gp * 0.08, 1.7), max(octaves - 1, 1));
            float3 straw = float3(0.42, 0.33, 0.2);
            float3 ground = straw * (p.ambient.rgb * 0.6 + pl_frontLight(u, p) * 0.7) * (0.5 + 0.5 * tex);
            ground += p.flash.rgb * 0.12;
            float wet = saturate(u.extra.w);
            ground = mix(ground, col * 0.35, 0.4 * wet);
            float fog = 1.0 - exp(-g / 1400.0);
            col = mix(ground, col, fog);
        }

        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the storm, over its own bounds
    // Drawn over the scene within the storm's screen bounds (NDC x0, y0, x1, y1), premultiplied: so the sky's pixels
    // never carry the storm's work. Under the ridge while the ridge is the nearer; into the haze below the horizon.
    vertex PlainsOut plains_box_vertex(uint vid [[vertex_id]], constant float4& box [[buffer(0)]]) {
        float2 corner[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        float2 xy = mix(box.xy, box.zw, corner[vid]);
        PlainsOut o;
        o.pos = float4(xy, 0, 1);
        o.ndc = xy;
        return o;
    }

    /// The storm and its rain at a pixel (`ndcIn`, before the shake), premultiplied; `ridgeOver` false leaves out the
    /// nearer ridge's cut (the reduced-resolution pass: the full-resolution one that adds it in cuts it, so the ridge's
    /// outline stays sharp).
    float4 pl_stormOver(float2 ndcIn, constant SkyU& u, constant PlainsU& p, bool ridgeOver) {
        float2 ndc = ndcIn - p.shake.xy;
        float3 d = pl_ray(ndc, u);
        float alt = toDeg(asin(clamp(d.z, -1.0, 1.0)));
        if (alt <= -0.5) return float4(0.0);
        float th = pl_wrap(toDeg(atan2(d.x, d.y)) - p.storm.x);
        int octaves = int(p.frame.w + 0.5);
        float time = p.frame.y;
        PlStorm st = pl_storm(th, alt, p, octaves, time);
        float4 o = float4(0.0);
        if (st.a > 0.001) o = float4(pl_stormLight(d, th, alt, st, u, p, octaves, time) * st.a, st.a);
        // The rain hanging from the base's near edge, over its underside and the low sky beyond; lit by the flashes.
        float shaft = pl_shafts(th, alt, p, time);
        if (shaft > 0.001) {
            float3 front = pl_frontLight(u, p);
            float3 rain = p.ambient.rgb * 0.42 + p.glow.rgb * 0.18 + front * 0.3 + p.flash.rgb * 0.3;
            rain = mix(pl_air(d, alt, u), rain, 0.4 + 0.6 * exp(-p.shake.w / 60.0));
            shaft = min(0.9, 2.0 * shaft);
            o = float4(rain * shaft, shaft) + o * (1.0 - shaft);
        }
        if (ridgeOver && p.ridge.w < p.shake.w) o *= 1.0 - pl_ridge(th, alt, p);
        if (d.z < 0.0) o *= 1.0 - exp(-p.view.x / max(-d.z, 1e-5) / 1400.0);
        return o;
    }

    fragment ColorDepth plains_storm_fragment(PlainsOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                              constant PlainsU& p [[buffer(1)]]) {
        float4 o = pl_stormOver(in.ndc, u, p, true);
        if (o.a <= 0.001) discard_fragment();
        ColorDepth out;
        out.color = o;
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // The storm at a reduced resolution (half the view's size on Smooth, 0.7 of it on High): soft cloud and rain, drawn
    // into a target of their own over the storm's bounds, and added in at full resolution over them, where the nearer
    // ridge cuts it pixel by pixel.
    fragment float4 plains_storm_half_fragment(PlainsOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                               constant PlainsU& p [[buffer(1)]]) {
        return pl_stormOver(in.ndc, u, p, false);
    }

    fragment ColorDepth plains_storm_compose_fragment(PlainsOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                                      constant PlainsU& p [[buffer(1)]], texture2d<float> stormTex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        float4 o = stormTex.sample(s, uv);
        if (o.a > 0.001 && p.ridge.w < p.shake.w) {
            float2 ndc = in.ndc - p.shake.xy;
            float3 d = pl_ray(ndc, u);
            float alt = toDeg(asin(clamp(d.z, -1.0, 1.0)));
            float th = pl_wrap(toDeg(atan2(d.x, d.y)) - p.storm.x);
            o *= 1.0 - pl_ridge(th, alt, p);
        }
        if (o.a <= 0.001) discard_fragment();
        ColorDepth out;
        out.color = o;
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- Strike Lines: forks and crawlers
    // Each instance is one straight stretch of channel: its ends (NDC), core width and glow reach (NDC y units), light,
    // and colour (HDR). Drawn additively over the sky, under the plain's props.
    struct BoltIn { float4 seg; float4 info; float4 colour; };
    struct BoltOut { float4 pos [[position]]; float2 q; float4 seg [[flat]]; float4 info [[flat]]; float4 colour [[flat]]; };

    vertex BoltOut plains_bolt_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device BoltIn* bolts [[buffer(0)]], constant PlainsU& p [[buffer(1)]]) {
        BoltIn b = bolts[iid];
        float aspect = p.frame.x;
        float2 a = float2(b.seg.x * aspect, b.seg.y);
        float2 c = float2(b.seg.z * aspect, b.seg.w);
        float2 dir = c - a;
        float len = length(dir);
        float2 t = len > 1e-6 ? dir / len : float2(0.0, 1.0);
        float2 n = float2(-t.y, t.x);
        float w = b.info.y;
        float2 corner[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float2 k = corner[vid];
        float2 at = (k.x < 0.0 ? a - t * w : c + t * w) + n * (k.y * w);
        BoltOut o;
        o.q = at;
        o.pos = float4(at.x / aspect + p.shake.x, at.y + p.shake.y, 0, 1);
        o.seg = float4(a, c);
        o.info = b.info;
        o.colour = b.colour;
        return o;
    }

    float pl_hash1(float n) { return fract(sin(n) * 43758.5453); }
    float pl_vn1(float x) {
        float i = floor(x), f = x - i;
        return mix(pl_hash1(i), pl_hash1(i + 1.0), f * f * (3.0 - 2.0 * f));
    }

    fragment ColorDepth plains_bolt_fragment(BoltOut in [[stage_in]]) {
        float2 a = in.seg.xy, c = in.seg.zw;
        float2 pa = in.q - a, ba = c - a;
        float len = max(length(ba), 1e-6);
        float2 tdir = ba / len, nrm = float2(-tdir.y, tdir.x);
        float along = dot(pa, tdir);
        float h = saturate(along / len);
        // A real channel kinks far finer than its segments: it wanders across its line (two scales), never at the
        // segment's ends (so the segments still meet), and never further than its glow reaches.
        float seed = 100.0 * pl_hash1(dot(a + c, float2(12.9898, 78.233)));
        float wig = 0.7 * (pl_vn1(h * 9.0 + seed) - 0.5) + 0.3 * (pl_vn1(h * 31.0 + 1.7 * seed) - 0.5);
        float amp = min(0.08 * len, 0.5 * in.info.y) * 4.0 * h * (1.0 - h);
        float over = max(-along, 0.0) + max(along - len, 0.0);
        float dist = length(float2(dot(pa, nrm) - wig * amp, over));
        float core = max(in.info.x, 1e-5);
        float reach = max(in.info.y, 1e-5);
        float x = dist / core;
        float light = exp(-x * x) + 0.1 * exp(-4.0 * dist / reach) * (1.0 - smoothstep(0.5 * reach, reach, dist));
        ColorDepth o;
        o.color = float4(in.colour.rgb * (in.info.z * light), 0.0);
        o.depth = float4(1.0, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the plain's props, back to front
    // Each instance: a (its rectangle, NDC), b (kind, distance m, …), c and d (its own). Premultiplied colour out.
    struct PropIn { float4 a; float4 b; float4 c; float4 d; };
    struct PropOut { float4 pos [[position]]; float2 ndc; float4 b [[flat]]; float4 c [[flat]]; float4 d [[flat]];
                     float3 front [[flat]]; };

    vertex PropOut plains_prop_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device PropIn* props [[buffer(0)]], constant PlainsU& p [[buffer(1)]],
                                      constant SkyU& u [[buffer(2)]]) {
        float2 corner[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        PropIn k = props[iid];
        float2 xy = mix(k.a.xy, k.a.zw, corner[vid]);
        PropOut o;
        o.ndc = xy;
        o.pos = float4(xy + p.shake.xy, 0, 1);
        o.b = k.b; o.c = k.c; o.d = k.d;
        o.front = pl_frontLight(u, p);
        return o;
    }

    /// A row of dry grass at one distance: a solid band of tussocks whose top rolls (two octaves of noise along the
    /// row), with blades, stalks and seed heads poking up out of it, all bending on the wind sampled across the view (c:
    /// the wind across the row at its left edge, a third in, two thirds, its right edge, m/s), swaying, and the gusts'
    /// waves running through it as lighter, bent swathes. Deep in the grass it is dark; its tops and the tips catch the
    /// warm light of the low sky behind you. Patches of golden and greyer stubble lie across the plain itself (not along
    /// the rows), so the rows read as one field going back, hazier with distance.
    float4 pl_grass(float2 ndc, float4 b, float4 c, float4 d, constant SkyU& u, constant PlainsU& p, float3 front) {
        float3 ray = pl_ray(ndc, u);
        float fwd = dot(ray.xy, p.ahead.xy);
        if (fwd <= 1e-4) return float4(0.0);
        float z = b.y;
        float t = z / fwd;
        float X = t * dot(ray.xy, p.ahead.zw);
        float Y = p.view.x + t * ray.z;
        float H = b.z;
        float aa = max(t * p.view.y, 1e-4);           // a pixel's size there (m)
        // (Nothing of the row stands higher than its tallest blade, 1.1875 H, or its tussocks' top, 0.61 H, and half a
        // pixel: above that nothing is drawn, so nothing is worked out.)
        if (Y < -0.05 || Y > max(1.1875 * H, 0.61 * H + 0.5 * aa) + 0.02) return float4(0.0);
        float sx = saturate(ndc.x * 0.5 + 0.5) * 3.0;
        int i0 = min(int(sx), 2);
        float f = sx - float(i0);
        float w0 = i0 == 0 ? c.x : (i0 == 1 ? c.y : c.z);
        float w1 = i0 == 0 ? c.y : (i0 == 1 ? c.z : c.w);
        float wind = mix(w0, w1, f);
        float time = p.frame.y;
        // The gusts' waves: swathes bent further (and so lighter) travelling with the wind; the whole row swaying with
        // them (blade by blade only a little, so the near grass leans together).
        float wave = vnoise3(float3((X - wind * time * 0.9) * 0.09, z * 0.09, 9.1));
        float sway = d.z * sin(time * 1.7 + X * 0.35 + 2.0 * wave);
        float lean0 = clamp(wind / 16.0 * (0.7 + 0.6 * wave) + sway, -0.75, 0.75);
        // The tussocks' rolling, ragged top.
        float sb = max(d.x, 1e-3);
        float roll = pl_noise1(X / 0.9, b.w) * 0.65 + pl_noise1(X / 0.23, b.w + 7.7) * 0.35;
        float rag = pl_noise1(X / (0.8 * sb), b.w + 3.3);
        float g = H * (0.42 + 0.14 * roll + 0.1 * (rag - 0.5));
        float body = saturate((g - Y) / aa + 0.5);
        // Blades and stalks out of it, tapering, bowed by the wind.
        float jitter = min(0.12, sb / (0.75 * H));
        float bow = 0.75 * lean0 * Y * Y / (0.8 * H);
        float cell = floor((X - bow) / sb);
        float spike = 0.0, tip = 0.0, tone = 1.0;
        for (int j = Y > 0.6 * g ? -1 : 2; j <= 1; j++) {
            float cj = cell + float(j);
            float3 h = hash33(float3(cj, b.w, 3.7));
            bool tall = h.z > 1.0 - d.w;
            float hgt = H * (0.6 + 0.35 * h.y) * (tall ? 1.25 : 1.0);
            if (Y > hgt * 1.08 || Y < g * 0.6) continue;
            float k = saturate(Y / hgt);
            float lean = lean0 + (h.z - 0.5) * 2.0 * jitter;
            float root = (cj + 0.15 + 0.7 * h.x) * sb;
            float x = root + lean * 0.75 * Y * Y / (0.8 * H);
            float width = (tall ? 0.004 : 0.006) * (1.0 - 0.75 * k);
            float dist = abs(X - x);
            float blade = saturate((width - dist) / aa + 0.5) * (Y <= hgt ? 1.0 : 0.0);
            if (h.z > 0.6) {
                float hy = (Y - hgt * 0.86) / (hgt * 0.14);
                if (hy > -1.0 && hy < 1.0) {
                    float headW = width * 2.8;
                    float head = saturate((headW * sqrt(saturate(1.0 - hy * hy)) - dist) / aa + 0.5);
                    blade = max(blade, head);
                    tip = max(tip, head);
                }
            }
            if (blade > spike) tone = (0.75 + 0.45 * h.x) * (0.45 + 0.55 * k);
            spike = max(spike, blade);
            tip = max(tip, blade * smoothstep(0.5, 1.0, k));
        }
        float cover = max(body, spike);
        if (cover <= 0.001) return float4(0.0);
        // Golden and greyer stubble in patches across the plain; the stems' streaks in the tussocks.
        float patch = vnoise3(float3(X * 0.11, z * 0.11, 3.3));
        float3 straw = mix(float3(0.46, 0.41, 0.34), float3(0.62, 0.5, 0.32), smoothstep(0.25, 0.75, patch));
        float stems = pl_noise1((X - bow) / (0.45 * sb), b.w + 1.9);
        float rise = smoothstep(0.1 * H, g, Y);
        float depthShade = (0.55 + 0.45 * rise) * (0.7 + 0.5 * stems);
        float crest = body * smoothstep(0.8 * g, g, Y) * rag;
        float lit = max(tip * (1.0 - 0.6 * body), 0.35 * crest);
        float bent = 0.85 + 0.3 * wave;
        float shade = mix(depthShade, tone, spike * (1.0 - body));
        float3 col = straw * (p.ambient.rgb * (0.42 * shade) + front * (0.38 * shade + 0.9 * lit)) * bent
                   + p.flash.rgb * (0.07 + 0.14 * lit);
        float fog = 1.0 - exp(-z / 900.0);
        col = mix(col, p.glow.rgb * 0.8, fog);
        return float4(col * cover, cover);
    }

    /// A fence post: c (its base and top, NDC), d (half-width and glow reach, NDC y units; a pixel). Weathered wood,
    /// silver-grey, its sunward side lit by the low sky behind you and its grain running up it; lit by its note, a light
    /// that warms from the lightning's white to gold as the repeats brighten it, the glow round its top growing with
    /// the level (b.z).
    float4 pl_post(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p, float3 front) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float span = c.w - c.y;
        float k = (ndc.y - c.y) / max(span, 1e-5);
        float cx = mix(c.x, c.z, saturate(k));
        float across = (ndc.x - cx) * aspect;
        float hw = d.x;
        float body = saturate((hw + 0.35 * px - abs(across)) / px) * step(0.0, k) * saturate((1.0 - k) * span / px + 0.5);
        float lit = saturate(b.z);
        float side = smoothstep(-hw, hw, across);
        float grain = 0.82 + 0.18 * vnoise3(float3(across / max(hw, 1e-5) * 1.5, k * 9.0, b.w * 1.37));
        float3 weathered = float3(0.44, 0.4, 0.35) * grain * (0.85 + 0.15 * smoothstep(0.85, 1.0, k));
        float3 wood = weathered * (p.ambient.rgb * (0.38 + 0.12 * side) + front * (0.2 + 0.75 * side)) + p.flash.rgb * 0.15;
        float3 glowCol = mix(float3(0.78, 0.86, 1.0), float3(1.1, 0.8, 0.48), smoothstep(0.3, 0.95, lit));
        float3 col = mix(wood, glowCol * (0.9 + 2.2 * lit * (0.55 + 0.45 * k)), lit);
        float2 top = float2((ndc.x - c.z) * aspect, ndc.y - c.w);
        float r = length(top) / max(d.y, 1e-5);
        float halo = lit * (0.9 * exp(-4.0 * r * r) + 0.25 * exp(-2.5 * r));
        float3 shown = col * body + glowCol * halo * 1.4;
        return float4(shown, body);
    }

    /// The fence's three strands between two posts: c (the lowest strand's ends, NDC), d (the highest strand's two ends'
    /// heights, a pixel, the light of the posts at its ends). Thin dark wire glinting with the sky behind.
    float4 pl_wire(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p, float3 front) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float best = 1e9;
        float along = 0.0;
        for (int s = 0; s < 3; s++) {
            float f = float(s) * 0.5;
            float2 a = float2(c.x * aspect, mix(c.y, d.x, f));
            float2 e = float2(c.z * aspect, mix(c.w, d.y, f));
            float2 q = float2(ndc.x * aspect, ndc.y);
            float2 pa = q - a, ba = e - a;
            float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-12));
            float dist = length(pa - ba * h);
            if (dist < best) { best = dist; along = h; }
        }
        float cover = saturate(0.6 - best / px) * 0.9;
        if (cover <= 0.0) return float4(0.0);
        float lit = d.w * (0.4 + 0.6 * (1.0 - abs(along - 0.5) * 2.0));
        float3 glowCol = mix(float3(0.78, 0.86, 1.0), float3(1.1, 0.8, 0.48), smoothstep(0.15, 0.48, d.w));
        float3 col = p.ambient.rgb * 0.2 + front * 0.35 + glowCol * lit * 0.8 + p.flash.rgb * 0.2;
        return float4(col * cover, cover);
    }

    /// The steel windmill: c (the hub, NDC; the wheel's radius and the tower's base, NDC y), d (the legs' half-spread at
    /// the base and the top, NDC y units; a pixel; the tail vane's reach), b.z its angle (rad), b.w its blur (0 sharp …
    /// 1 a blurred disc). Iron against the light, rimmed with it.
    float4 pl_windmill(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p, float3 front) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float2 q = float2((ndc.x - c.x) * aspect, ndc.y - c.y);
        float R = c.z;
        float cover = 0.0;
        // The tower: two legs splayed to the base, cross braces in six bays, a platform under the wheel.
        float base = c.w - c.y;
        float k = q.y / min(base, -1e-5);
        if (k >= 0.0 && k <= 1.0) {
            float splay = mix(d.y, d.x, k);
            float leg = min(abs(q.x - splay), abs(q.x + splay));
            cover = max(cover, saturate(1.0 - leg / (0.9 * px)));
            // The back pair of legs, nearer together and a little to the side: the tower has depth.
            float sb = 0.62 * splay, xb = q.x - 0.2 * splay;
            cover = max(cover, 0.55 * saturate(1.0 - min(abs(xb - sb), abs(xb + sb)) / (0.8 * px)));
            float bay = k * 6.0;
            float f = bay - floor(bay);
            float x1 = mix(-splay, splay, f), x2 = mix(splay, -splay, f);
            float brace = min(abs(q.x - x1), abs(q.x - x2)) * (abs(q.x) < splay ? 1.0 : 1e3);
            cover = max(cover, 0.8 * saturate(1.0 - brace / (0.6 * px)));
        }
        float platform = abs(q.y + 0.2 * R) < 0.8 * px && abs(q.x) < 0.35 * R ? 1.0 : 0.0;
        cover = max(cover, platform);
        // The wheel, turned three-quarters into the wind (an ellipse): its rims, 18 pitched sails (each shows its face
        // on one side of the wheel and its edge on the other; the faces turned to the light catch it), the hub and the
        // head behind it; blurred into a disc as it races.
        const float yaw = 0.58;
        float2 w = float2(q.x / yaw, q.y);
        float r = length(w) / max(R, 1e-5);
        float rr = px / max(R * yaw, 1e-5);
        float ring = max(saturate(1.0 - abs(r - 0.97) / (1.3 * rr)), saturate(1.0 - abs(r - 0.36) / (1.1 * rr)));
        float sails = 0.0, sailLight = 0.0;
        if (r > 0.34 && r < 0.98) {
            float a0 = atan2(w.y, w.x);
            float a = a0 + b.z;
            float f = a * 18.0 / 6.2831853;
            float s = f - floor(f);
            float face = 0.3 + 0.32 * (0.5 + 0.5 * cos(a0));
            float sharp = smoothstep(0.03, 0.08, s) * (1.0 - smoothstep(face, face + 0.06, s));
            float sheen = smoothstep(0.4 * face, face, s);               // each curved sheet lighter toward its edge
            float blur = saturate(b.w);
            sails = mix(sharp, 0.5, blur) * 0.95;
            sailLight = mix(sharp * (0.35 + 0.65 * sheen), 0.3, blur) * (0.5 + 0.5 * cos(a0 - 0.9));
        }
        float hub = r < 0.11 ? 1.0 : 0.0;
        float head = (q.x > -0.04 * R && q.x < 0.32 * R && abs(q.y + 0.02 * R) < 0.09 * R) ? 1.0 : 0.0;
        cover = max(cover, max(max(ring, sails), max(hub, head)));
        // The tail vane behind the wheel, downwind and foreshortened: a boom rising a little away from you and a sheet
        // narrowing with distance.
        float vx = q.x / max(0.72 * d.w, 1e-5);
        if (vx > 0.1 && vx < 1.0) {
            float lift = 0.06 * R * vx;
            float boom = saturate(1.0 - abs(q.y - lift) / (0.7 * px));
            float hh = R * (0.12 + 0.36 * (vx - 0.55)) * (1.0 - 0.25 * vx);
            float sheet = vx > 0.55 && abs(q.y - lift) < hh ? 1.0 : 0.0;
            cover = max(cover, max(boom, sheet * 0.95));
        }
        if (cover <= 0.001) return float4(0.0);
        float3 iron = p.ambient.rgb * 0.16 + front * 0.22 + p.flash.rgb * 0.12;
        // Galvanised sails catch the sky's light on their faces; the frame stays dark iron.
        iron += (p.ambient.rgb * 0.22 + front * 0.32 + p.flash.rgb * 0.18) * sailLight;
        return float4(iron * cover, cover);
    }

    /// The water tank on its stand: c (its middle and the stand's foot, NDC x / y; its half-width, NDC y units; the stand's
    /// top), d (the tank's top and the roof's peak, NDC y; a pixel). Corrugated iron catching the light in faint bands.
    float4 pl_tank(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p, float3 front) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float x = (ndc.x - c.x) * aspect;
        float y = ndc.y;
        float hw = c.z;
        float cover = 0.0;
        if (y >= c.y && y <= c.w) {
            float leg = min(abs(abs(x) - 0.82 * hw), abs(x));
            cover = max(cover, saturate(1.0 - leg / (0.9 * px)));
            float f = (y - c.y) / max(c.w - c.y, 1e-5);
            float brace = abs(x - mix(-0.82, 0.82, f) * hw);
            cover = max(cover, abs(x) < 0.82 * hw ? 0.7 * saturate(1.0 - brace / (0.6 * px)) : 0.0);
        }
        float body = (y >= c.w && y <= d.x) ? saturate((hw - abs(x)) / px + 0.5) : 0.0;
        float roofY = d.x + (d.y - d.x) * (1.0 - saturate(abs(x) / hw));
        float roof = (y > d.x && y <= roofY) ? saturate((hw - abs(x)) / px + 0.5) : 0.0;
        cover = max(cover, max(body, roof));
        if (cover <= 0.001) return float4(0.0);
        float bands = 0.5 + 0.5 * sin((y - c.w) / max(px, 1e-5) * 1.6);
        float3 iron = p.ambient.rgb * 0.18 + front * (0.2 + 0.12 * bands * body) + p.flash.rgb * 0.14;
        return float4(iron * cover, cover);
    }

    /// A dust devil: c (its foot, NDC; its top, NDC y; its foot's half-width, NDC y units), d (its top's half-width;
    /// a pixel; its swirl's phase; how strongly it turns). A twisting column of dust, glowing as the light comes through it.
    float4 pl_devil(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p, float3 front) {
        float aspect = p.frame.x;
        float k = (ndc.y - c.y) / max(c.z - c.y, 1e-5);
        if (k < 0.0 || k > 1.0) return float4(0.0);
        float girth = mix(c.w, d.x, sqrt(k));
        float x = (ndc.x - c.x) * aspect / max(girth, 1e-5);
        if (abs(x) >= 1.0) return float4(0.0);
        float swirl = vnoise3(float3(x * 2.0 + k * 9.0 - d.y * 3.0, k * 14.0 - d.y * 2.0, 4.1));
        float body = (1.0 - x * x) * (0.45 + 0.55 * swirl) * smoothstep(0.0, 0.08, k) * (1.0 - smoothstep(0.6, 1.0, k));
        float a = saturate(body * d.z * 0.75);
        float3 dust = float3(0.62, 0.5, 0.36) * (p.ambient.rgb * 0.6 + front * 1.1) + p.flash.rgb * 0.2;
        return float4(dust * a, a);
    }

    /// The rain curtain at b.y metres: rain hanging from the storm's base (c.x m up) to the plain (to c.y of the way down
    /// under virga), streaked and slanting (c.z), at density c.w; above it the base, dark. It covers everything behind it.
    float4 pl_curtain(float2 ndc, float4 b, float4 c, float4 d, constant SkyU& u, constant PlainsU& p) {
        float3 ray = pl_ray(ndc, u);
        float fwd = dot(ray.xy, p.ahead.xy);
        if (fwd <= 1e-4) return float4(0.0);
        float D = max(b.y, 0.5);
        float t = D / fwd;
        float X = t * dot(ray.xy, p.ahead.zw);
        float Y = p.view.x + t * ray.z;
        if (Y < 0.0) return float4(0.0);
        float time = p.frame.y;
        float baseM = c.x;
        float slant = X + c.z * Y;
        // Fine streaks a few pixels wide however near the rain is (measured as angles, not metres: wide bright bands
        // read as a shower curtain hung across the sky), long and falling.
        float sx = slant / t, sy = Y / t;
        float streak = 0.65 * vnoise3(float3(sx / 0.0035, sy / 0.09 + time * 2.5, 6.1))
                     + 0.35 * vnoise3(float3(sx / 0.012, sy / 0.2 + time * 1.8, 2.7));
        float reach = mix(1.0, smoothstep(c.y * baseM, (c.y + 0.25) * baseM, Y), b.z);
        float rainA = c.w * (0.5 + 0.5 * streak) * reach;
        float3 lit = p.flash.rgb * 0.25 + float3(0.82, 0.84, 1.0) * p.shake.z * 0.3;
        float3 rainCol = p.ambient.rgb * 0.35 + p.glow.rgb * 0.08 + lit * (0.55 + 0.5 * streak);
        // Above the rain, the storm's dark base overhead, its ragged edge where the rain hangs from it.
        float edge = baseM * (0.9 + 0.2 * pl_noise1(X / 300.0, 4.2));
        float up = smoothstep(edge - 0.12 * baseM, edge + 0.12 * baseM, Y);
        float3 baseCol = p.ambient.rgb * 0.14 + lit * (0.5 + 0.4 * streak);
        float a = mix(rainA, 0.8 * c.w, up);
        float3 col = mix(rainCol, baseCol, up);
        a = saturate(a);
        return float4(col * a, a);
    }

    fragment ColorDepth plains_prop_fragment(PropOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                             constant PlainsU& p [[buffer(1)]]) {
        int kind = int(in.b.x + 0.5);
        float4 c = float4(0.0);
        float3 front = in.front;
        if (kind == 0) c = pl_grass(in.ndc, in.b, in.c, in.d, u, p, front);
        else if (kind == 1) c = pl_post(in.ndc, in.b, in.c, in.d, p, front);
        else if (kind == 2) c = pl_wire(in.ndc, in.b, in.c, in.d, p, front);
        else if (kind == 3) c = pl_windmill(in.ndc, in.b, in.c, in.d, p, front);
        else if (kind == 4) c = pl_tank(in.ndc, in.b, in.c, in.d, p, front);
        else if (kind == 5) c = pl_devil(in.ndc, in.b, in.c, in.d, p, front);
        else c = pl_curtain(in.ndc, in.b, in.c, in.d, u, p);
        if (c.a < 0.002 && dot(c.rgb, float3(1.0)) < 0.002) discard_fragment();
        ColorDepth o;
        o.color = c;
        o.depth = float4(saturate(in.b.y / 2000.0), 0, 0, 1);
        return o;
    }
    """
}
