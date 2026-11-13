/// Metal source for Bioluminescent Bay: two headlands with palms and mangroves framing the bay's mouth, the lighthouse
/// on the far point, a moored boat with its lantern, the still bay mirroring the Living Sky (the headlands and the boat
/// in it too), the glow line along the waterline, Glow Wake's patches, wakes, darts and pool on the water (emissive:
/// nothing reflects them), white sand, near palms at the frame's edges and a dark glass keyboard. Built on
/// SkyShaders.common and OceanShaders.common (the swell is the Ocean layer's, at a small amplitude).
/// Smooth rules: no ray marching, ≤ 2 noise octaves on Smooth (3 above, in the sky and the chop), ≤ 24 patches, 8 wakes
/// and 6 darts per water pixel on Smooth; everything that moves is timed by the swell's wrapped phases or the wash's
/// wrapped phase (never a raw clock). No pow(): squares and powers are written out.
enum BioluminescentBayShaders {
    static let source = SkyShaders.common + OceanShaders.common + """
    struct BayU {
        float4 a;             // keys top (NDC y), aspect, camera height (m), night 0…1
        float4 b;             // glow line (Plankton glow × the dark × sparkle), wash phase 0…1 (0.15 Hz), swell wash 0…1, haze 0…1
        float4 c;             // lantern 0…1, lighthouse flash 0…1 (× setting × sparkle), wind 0…1, wetness 0…1
        float4 d;             // waterline (m out), patch count, wake count, dart count
        float4 e;             // day 0…1, light pillar 0…1, glow gain (Plankton glow × sparkle), noise octaves
        float4 pool;          // the chord's pool: across (m), out (m), radius (m), strength (× the dark)
        float4 poolColor;     // rgb (bright cyan for major … deep teal for minor), unused
        float4 boat;          // the moored boat: across (m), out (m), bob (m), roll (rad)
        float4 lantern;       // the lantern: across (m), out (m), height above the water (m), unused
        float4 lanternDir;    // east-north-up unit vector from the eye to the lantern, its pillar's angular radius (rad)
        float4 lighthouse;    // the lamp: azimuth from the view's centre (rad, right +), altitude (rad), tower half width (rad), unused
        float4 lighthouseDir; // east-north-up unit vector to the lamp, unused
        // Fire & Neon §5.5 (Excitement):
        float4 wave;          // the wave of light: its front (m out), light 0…1 (× the dark, after the limiter), its arrival on the shore 0…1, a drop's sparkles 0…1
        float4 excite;        // the glow gathered under the surface 0…1 (× the dark), Energy 0…1, the wave's gain (a drop's brighter), the sparkles' twinkle phase 0…1
        float4 manta;         // a manta gliding in: across (m), out (m), heading (rad, in the across–out plane), its cover 0…1
        float4 mantaB;        // its span (m), its wingbeat's phase 0…1, the plankton lit along its edges 0…1 (× the dark), unused
        float4 turtle;        // a turtle surfacing: across (m), out (m), seconds since it came up, its rings' light 0…1 (× the dark)
        float4 turtleB;       // how far it is up 0…1, which way it faces (±1), its cover 0…1, unused
        float4 sand;          // the sun's and moon's direct light on the sand (falling with heavy cloud), the sky's light on it, unused, unused
        float4 patches[48];   // across (m), out (m), radius (m), brightness (× the dark)
        float4 wake[16];      // from across, from out, to across, to out (m)
        float4 wakeB[16];     // brightness (× the dark), half width (m), unused, unused
        float4 dart[12];      // head across, head out, tail across, tail out (m)
        float4 dartB[12];     // brightness (× the dark), half width (m), unused, unused
    };
    struct BayOut { float4 pos [[position]]; float2 ndc; };

    constant float3 kGlowCyan = float3(0.3, 1.0, 0.75);
    constant float3 kWaveBlue = float3(0.18, 0.78, 1.0);   // the wave of light: the plankton's bluer flash
    constant float3 kLanternWarm = float3(1.0, 0.62, 0.28);
    constant float3 kLampWhite = float3(1.0, 0.93, 0.78);
    constant float kLeftTip = 0.2;     // the left headland's point: radians left of the view's centre
    constant float kRightTip = 0.13;   // the far point (the lighthouse's): radians right of it

    vertex BayOut bay_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BayOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float3 bayRay(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    /// An angle wrapped to −π…π.
    float bayWrap(float a) {
        return a - 6.2831853 * floor((a + 3.14159265) / 6.2831853);
    }

    /// Distance from p to segment ab, and how far along it (0…1) the nearest point lies.
    float2 baySeg(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        return float2(length(pa - ba * h), h);
    }

    // ---------------------------------------------------------------- the headlands

    /// How far beyond its headland's point an azimuth lies (radians; < 0 out over the bay's mouth).
    float bayBeyond(float azRel) {
        return azRel < 0.0 ? -azRel - kLeftTip : azRel - kRightTip;
    }

    /// The headlands' skyline (radians above the horizon) by azimuth from the view's centre (radians, left negative): the
    /// left one ends in a rounded point kLeftTip left of centre, the right one in the low far point kRightTip right of
    /// it; between them the bay's mouth opens to the sea (−1: no land). Smooth: the ridges add their noise in bayLand.
    float bayLandSmooth(float azRel) {
        float x = bayBeyond(azRel);
        if (x < 0.0) return -1.0;
        bool left = azRel < 0.0;
        float nose = sqrt(saturate(x / 0.012));
        float rise = 1.0 - exp(-x / (left ? 0.38 : 0.55));
        return toRad(0.45 * nose + (left ? 10.5 : 7.0) * rise);
    }

    /// The skyline with its rolling ridges (≤ 2 octaves).
    float bayLand(float azRel, int octaves) {
        float h = bayLandSmooth(azRel);
        if (h < 0.0) return -1.0;
        float ridge = fbm3(float3(azRel * 9.0, azRel < 0.0 ? 1.7 : 4.3, 2.0), octaves) - 0.5;
        return max(h + toRad(1.6 * ridge) * saturate(bayBeyond(azRel) / 0.08), 0.15 * h);
    }

    /// Mangroves along the headlands' shores: a lumpy canopy (radians above the horizon) at the waterline, reaching a
    /// little past the left point over the water; none on the far point's rocks by the lighthouse. 0 where there are none.
    float bayMangroves(float azRel) {
        bool left = azRel < 0.0;
        float x = bayBeyond(azRel);
        if (left ? x < -0.03 : x < 0.05) return 0.0;
        float reach = left ? smoothstep(-0.03, 0.0, x) : smoothstep(0.05, 0.08, x);
        float lumps = 0.65 * vnoise3(float3(azRel * 70.0, 3.1, 0.5)) + 0.35 * vnoise3(float3(azRel * 190.0, 7.7, 1.5));
        return toRad((0.3 + 0.8 * lumps) * reach);
    }

    /// A headland's colour (or its mangroves', nearer and darker): green under haze by day, a dark silhouette at night.
    float3 bayLandColor(float alt, bool mangrove, constant SkyU& u, constant BayU& b, constant OceanU& o) {
        float day = b.e.x, night = b.a.w, haze = b.b.w;
        float3 horizon = u.horizon.rgb, zenith = u.zenith.rgb;
        float3 lit = mix(zenith, horizon, 0.5) * 0.6 + o.sunColor.rgb * o.sun.w * 0.3 + o.moonColor.rgb * o.moon.w * 0.015;
        float3 green = mangrove ? float3(0.03, 0.065, 0.04) : float3(0.06, 0.11, 0.06);
        float k = saturate(0.1 + 0.3 * day + 0.45 * haze) * (mangrove ? 0.45 : 1.0);
        return mix(green * lit, horizon * (1.0 + 0.1 * night), k * (0.5 + 0.5 * exp(-max(alt, 0.0) / 0.02)));
    }

    /// A far palm on a headland (q in degrees: azimuth from the view's centre, altitude): a leaning trunk and a crown of
    /// seven drooping fronds, anti-aliased over `px` degrees.
    float bayFarPalm(float2 q, float2 root, float height, float lean, float sway, float seed, float px) {
        float2 top = root + float2(lean + sway, height);
        if (q.y < root.y - px || q.y > top.y + 0.45 * height || abs(q.x - top.x) > 0.62 * height + px) return 0.0;
        float2 t = baySeg(q, root, top);
        float w = mix(0.075, 0.045, t.y) * height * 0.4;
        float cover = saturate((w - t.x) / px + 0.5);
        for (int k = 0; k < 7; k++) {
            float h = hash13(float3(seed, float(k), 2.0));
            float a = 0.2 + float(k) * 0.45 + 0.25 * (h - 0.5) + 0.3 * sway;
            float2 dir = float2(cos(a), sin(a));
            float len = (0.45 + 0.17 * h) * height;
            float2 mid = top + dir * (0.55 * len) + float2(0.0, 0.05 * height);
            float2 tip = top + dir * len - float2(0.0, (0.2 + 0.25 * saturate(dir.y)) * len);
            float2 d1 = baySeg(q, top, mid), d2 = baySeg(q, mid, tip);
            float along = d1.x < d2.x ? 0.5 * d1.y : 0.5 + 0.5 * d2.y;
            float fw = height * (0.028 + 0.034 * (1.0 - along));
            cover = max(cover, saturate((fw - min(d1.x, d2.x)) / px + 0.5));
        }
        return cover;
    }

    /// Palms along the headlands' lower slopes (a few per stretch, hashed), standing above the skyline; none by the
    /// lighthouse.
    float bayFarPalms(float azRel, float alt, float px, float wind, constant OceanU& o) {
        bool left = azRel < 0.0;
        float x = bayBeyond(azRel);
        if (x < -0.04 || x > 0.36) return 0.0;
        float2 q = float2(toDeg(azRel), toDeg(alt));
        float pxD = toDeg(px);
        float cell = 2.3;
        float ci = floor(q.x / cell);
        float cover = 0.0;
        for (int k = -1; k <= 1; k++) {
            float c = ci + float(k);
            float3 h = hash33(float3(c, left ? 3.0 : 7.0, 11.0));
            if (h.x > 0.6) continue;
            float pa = (c + 0.2 + 0.6 * h.y) * cell;   // the palm's azimuth (degrees)
            float xr = bayBeyond(toRad(pa));
            if ((pa < 0.0) != left || xr < (left ? 0.01 : 0.05) || xr > 0.32) continue;
            float height = 1.7 + 1.5 * h.z;
            float2 root = float2(pa, toDeg(bayLandSmooth(toRad(pa))) - 0.25);
            float lean = (h.y - 0.5) * 0.7 + (left ? 0.3 : -0.3);   // leaning out toward the bay
            float sway = (0.03 + 0.1 * wind) * sin(o.phases.x + c * 1.7);
            cover = max(cover, bayFarPalm(q, root, height, lean, sway, c, pxD));
        }
        return cover;
    }

    /// The lighthouse on the far point: a white tower tapering up from the skyline to its lamp room and cap (coverage);
    /// `lampRoom` says how much of the pixel is the lamp room's glass.
    float bayTower(float azRel, float alt, float px, constant BayU& b, thread float& lampRoom) {
        lampRoom = 0.0;
        float hw = b.lighthouse.z, top = b.lighthouse.y;
        float dA = abs(azRel - b.lighthouse.x);
        if (dA > 2.0 * hw + 2.0 * px) return 0.0;
        float base = max(bayLandSmooth(b.lighthouse.x), 0.0) - 0.002;
        if (alt < base || alt > top + 3.0 * hw + 2.0 * px) return 0.0;
        float k = saturate((alt - base) / max(top - base, 1e-4));
        float body = saturate((hw * (1.3 - 0.4 * k) - dA) / px + 0.5) * saturate((top - alt) / px + 0.5);
        float roomTop = top + 1.5 * hw;
        float room = saturate((0.75 * hw - dA) / px + 0.5) * saturate((alt - top) / px + 0.5) * saturate((roomTop - alt) / px + 0.5);
        float capH = (alt - roomTop) / (1.2 * hw);
        float cap = saturate((hw * (1.05 - capH) - dA) / px + 0.5) * saturate((alt - roomTop) / px + 0.5) * step(capH, 1.0);
        lampRoom = room;
        return max(body, max(room, cap));
    }

    // ---------------------------------------------------------------- the boat

    /// The moored boat at a point of its plane (across from the eye's line, up from the water; metres) with `pxm` metres
    /// to a pixel: a hull with a raked bow and a transom, a low cabin, a mast with stays, rolled by the swell; white by
    /// day, a dark shape at night warmed near its lantern. Returns its coverage and writes its colour.
    float bayBoatAt(float2 w, float pxm, constant BayU& b, constant SkyU& u, constant OceanU& o, thread float3& colOut) {
        float2 p = float2(w.x - b.boat.x, w.y - b.boat.z);   // from the boat's middle at the (bobbing) waterline
        if (abs(p.x) > 4.5 || p.y > 7.5 || p.y < -0.3) return 0.0;
        float cr = cos(b.boat.w), sr = sin(b.boat.w);
        float2 q = float2(cr * p.x + sr * p.y, -sr * p.x + cr * p.y);   // into the boat's own (rolling) frame
        float aa = max(pxm, 0.01);
        float deck = 0.72 + 0.28 * smoothstep(0.5, 3.0, q.x);
        float zk = saturate(q.y / deck);
        float bow = 3.1 - 0.85 * (1.0 - zk), stern = -2.8 + 0.12 * (1.0 - zk);
        float hull = saturate(min(min(q.x - stern, bow - q.x), deck - q.y) / aa + 0.5) * step(-0.3, q.y);
        float cabinTop = 1.42 - 0.35 * smoothstep(-0.3, 0.15, q.x);
        float cabin = saturate(min(min(q.x + 1.9, 0.15 - q.x), min(cabinTop - q.y, q.y - deck + 0.05)) / aa + 0.5);
        float mast = saturate((0.06 - abs(q.x - 0.6)) / aa + 0.5) * step(deck - 0.05, q.y) * saturate((6.6 - q.y) / aa + 0.5);
        float fore = baySeg(q, float2(0.6, 6.5), float2(3.05, 0.95)).x, back = baySeg(q, float2(0.6, 6.5), float2(-2.75, 0.85)).x;
        float stays = saturate((0.02 - min(fore, back)) / aa + 0.5);
        float cover = max(max(hull, cabin), max(mast, stays));
        if (cover < 0.002) return 0.0;
        float3 lit = mix(u.zenith.rgb, u.horizon.rgb, 0.5) * 0.7 + o.sunColor.rgb * o.sun.w * 0.55;
        float3 paint = (hull > 0.5 && q.y < 0.22) ? float3(0.12, 0.3, 0.55) : float3(0.84, 0.85, 0.82);   // a blue boot stripe
        float3 col = mix(float3(0.004, 0.005, 0.007), paint * lit, b.e.x);
        float2 lp = float2(b.lantern.x - w.x, b.lantern.z - w.y);
        col += kLanternWarm * (b.c.x * 0.35 * exp(-length(lp) / 1.3));
        colOut = col;
        return cover;
    }

    /// The boat along ray d from the eye (nothing where the ray meets the water before the boat's plane).
    float bayBoatSeen(float3 d, float2 fwd, float2 rgt, constant BayU& b, constant SkyU& u, constant OceanU& o,
                      thread float3& colOut) {
        float df = dot(d.xy, fwd);
        if (df < 1e-3) return 0.0;
        float t = b.boat.y / df;
        float z = b.a.z + t * d.z;   // height above the water where the ray crosses the boat's plane
        if (z < 0.0) return 0.0;
        return bayBoatAt(float2(t * dot(d.xy, rgt), z), t * u.weather.w, b, u, o, colOut);
    }

    /// The boat in the mirror: the reflected ray rd from the water at q (across, out) crossing the boat's plane.
    float bayBoatMirrored(float3 rd, float2 q, float2 fwd, float2 rgt, constant BayU& b, constant SkyU& u, constant OceanU& o,
                          thread float3& colOut) {
        float df = dot(rd.xy, fwd);
        if (q.y >= b.boat.y || df < 1e-3) return 0.0;
        float t = (b.boat.y - q.y) / df;
        return bayBoatAt(float2(q.x + t * dot(rd.xy, rgt), t * rd.z), b.boat.y * u.weather.w, b, u, o, colOut);
    }

    // ---------------------------------------------------------------- lights in the air

    /// Light in the air: the lantern's glow and, in diamond dust, its pillar above and below; the lighthouse lamp, its
    /// halo and glare while it flashes.
    float3 bayAirLight(float3 d, float alt, float azRel, float px, constant BayU& b) {
        float3 col = float3(0);
        float lantern = b.c.x;
        if (lantern > 0.001) {
            float3 L = b.lanternDir.xyz;
            float ang = acos(clamp(dot(d, L), -1.0, 1.0));
            float rr = max(0.0025, 0.8 * px);
            col += kLanternWarm * (lantern * (4.0 * exp(-(ang * ang) / (rr * rr)) + 0.5 * exp(-ang / 0.006) + 0.05 * exp(-ang / 0.03)));
            float pillar = b.e.y;
            if (pillar > 0.001) col += kLanternWarm * (0.55 * lantern * pillar * lightPillar(d, alt, L, b.lanternDir.w));
        }
        float flash = b.c.y;
        if (flash > 0.001) {
            float dA = azRel - b.lighthouse.x, dy = alt - b.lighthouse.y;
            float r = sqrt(dA * dA + dy * dy);
            float rr = max(0.0025, 0.8 * px);
            col += kLampWhite * (flash * (16.0 * exp(-(r * r) / (rr * rr)) + 0.6 * exp(-r / 0.008) + 0.1 * exp(-r / 0.045)));
            col += kLampWhite * (flash * 0.35 * exp(-abs(dA) / 0.08) * exp(-(dy * dy) / (0.0028 * 0.0028)));
        }
        return col;
    }

    // ---------------------------------------------------------------- the glow

    /// The 0.15 Hz wash: how far up the sand (metres) the latest wavelet runs, and how brightly it lights the plankton
    /// (rising as it breaks, fading as it drains; continuous where the phase wraps).
    float2 bayWash(constant BayU& b) {
        float ph = b.b.y;
        float rise = saturate(ph / 0.25);
        float run = ph < 0.25 ? 1.0 - (1.0 - rise) * (1.0 - rise) : 1.0 - smoothstep(0.25, 1.0, ph);
        float lit = ph < 0.25 ? mix(0.0724, 1.0, smoothstep(0.0, 0.25, ph)) : exp(-(ph - 0.25) * 3.5);
        return float2(0.12 + run * (0.55 + 1.6 * b.b.z), lit);
    }

    /// The glow line: plankton lighting along the waterline in stretches where the small waves break, flecked, with the
    /// running front of each wavelet's wash brightest as it breaks and a faint glow stirred into the shallows.
    float3 bayGlowLine(float s, float f, float edge, constant BayU& b, constant OceanU& o) {
        float glow = b.b.x * (1.0 + 0.9 * b.excite.y);   // Energy lifts the plankton's glow
        float shore = b.wave.z;                          // the wave of light arriving
        if (glow < 0.001 && shore < 0.001) return float3(0);
        float2 wash = bayWash(b);
        float lit = wash.y;
        float n1 = vnoise3(float3(s * 0.45, 2.0 * sin(o.phases.y), 1.2 * cos(o.phases.x)));
        float n2 = vnoise3(float3(s * 2.3, 1.7 * cos(o.phases.w), 3.1));
        float patchy = smoothstep(0.35, 0.85, n1) * (0.5 + 0.5 * n2) + 0.03;
        float fleck = 0.6 + 0.8 * vnoise3(float3(s * 7.0, f * 7.0, 2.0 * sin(o.phases.z)));
        float x = f - edge;
        float lineGlow = exp(-(x * x) / 0.012) * (0.25 + 0.75 * lit);          // where the wavelets break (±0.11 m)
        float stirred = x > 0.0 ? exp(-x / 0.7) * 0.12 * lit : 0.0;            // stirred into the shallows
        float y = f - (edge - wash.x);
        float front = x < 0.0 ? exp(-(y * y) / 0.008) * lit * lit : 0.0;       // the wash's running front
        float sheet = (x < 0.0 && y > 0.0) ? 0.05 * lit : 0.0;                 // and the thin sheet behind it
        float spill = x < 0.0 ? exp(x / 0.5) * 0.06 : 0.0;                     // a soft light on the wet sand
        float3 col = mix(kGlowCyan, float3(0.75, 1.0, 0.95), 0.3) * (glow * patchy * fleck * (lineGlow + stirred + front + sheet + spill) * 1.8);
        if (shore > 0.001) {
            // The wave of light reaching the shore: the waterline blazes and the wash runs up the sand lit, brightest at
            // its running front.
            float line = exp(-(x * x) / 0.05);
            float sheetLit = (x < 0.0 && y > 0.0) ? 0.45 : 0.0;
            float runFront = x < 0.0 ? exp(-(y * y) / 0.02) : 0.0;
            float shallows = x > 0.0 ? exp(-x / 1.6) * 0.5 : 0.0;
            float broken = 0.35 + 0.65 * smoothstep(0.2, 0.7, n1) + 0.25 * n2;
            col += mix(kWaveBlue, float3(0.7, 1.0, 1.0), 0.25) * (shore * broken * fleck * (1.6 * line + sheetLit + 1.4 * runFront + shallows) * 1.5);
        }
        return col;
    }

    /// Glow Wake on the water at q (across, out in metres): patches with white cores, wakes brightening toward the newest
    /// patch, darts bright at their heads, and the chord's pool, flecked like plankton (the flecks fade where a pixel
    /// covers more water than they do). Emissive: it is the water, so nothing reflects it.
    float3 bayGlowWake(float2 q, float footprint, constant BayU& b, constant OceanU& o) {
        float gain = b.e.z;
        if (gain < 0.001) return float3(0);
        float3 g = float3(0);
        int n = int(b.d.y + 0.5);
        for (int i = 0; i < 48; i++) {
            if (i >= n) break;
            float4 pt = b.patches[i];
            if (pt.w < 0.002) continue;
            float2 dq = q - pt.xy;
            float r2 = dot(dq, dq) / max(pt.z * pt.z, 1e-4);
            if (r2 > 9.0) continue;
            g += kGlowCyan * (exp(-r2 * 1.5) * pt.w) + float3(0.75, 1.0, 0.92) * (exp(-r2 * 7.0) * pt.w * pt.w);
        }
        int nw = int(b.d.z + 0.5);
        for (int i = 0; i < 16; i++) {
            if (i >= nw) break;
            float k = b.wakeB[i].x, hw = max(b.wakeB[i].y, 0.02);
            if (k < 0.002) continue;
            float2 sd = baySeg(q, b.wake[i].xy, b.wake[i].zw);
            if (sd.x > 3.0 * hw) continue;
            float x = sd.x / hw;
            g += kGlowCyan * (exp(-x * x) * k * (0.35 + 0.65 * sd.y));
        }
        int nd = int(b.d.w + 0.5);
        for (int i = 0; i < 12; i++) {
            if (i >= nd) break;
            float k = b.dartB[i].x, hw = max(b.dartB[i].y, 0.02);
            if (k < 0.002) continue;
            float2 sd = baySeg(q, b.dart[i].zw, b.dart[i].xy);   // tail → head
            if (sd.x > 3.0 * hw) continue;
            float x = sd.x / hw;
            g += mix(kGlowCyan, float3(0.85, 1.0, 0.95), sd.y) * (exp(-x * x) * k * (0.25 + 0.75 * sd.y) * 1.4);
        }
        float4 pl = b.pool;
        if (pl.w > 0.002) {
            float2 dq = q - pl.xy;
            float r2 = dot(dq, dq) / max(pl.z * pl.z, 1e-4);
            if (r2 < 9.0) g += b.poolColor.rgb * (exp(-r2 * 1.3) * pl.w);
        }
        float fleckK = 1.0 - smoothstep(0.15, 0.5, footprint);
        float fleck = vnoise3(float3(q * 5.0, 2.0 * sin(o.phases.z) + 1.5 * cos(o.phases.y)));
        g *= mix(1.0, 0.55 + 0.9 * fleck, fleckK);
        return g * (gain * 1.6);
    }

    // ---------------------------------------------------------------- Excitement on the water (Fire & Neon §5.5)

    /// Plankton firing in points here and there (Energy's), and a drop's sparkles: cells square on screen (out stretched
    /// by the view's foreshortening, f / eye height), one point in some of them, twinkling on the wrapped phase.
    float bayFlecks(float2 q, float f, float density, float phase, float eye) {
        if (density < 0.001) return 0.0;
        float across = 0.022 * f;
        float2 cell = float2(across, across * max(f / eye, 1.0));
        float2 g = q / cell;
        float2 id = floor(g);
        float3 h = hash33(float3(id, 7.0));
        if (h.x > density) return 0.0;
        float2 dd = g - (id + 0.25 + 0.5 * h.yz);
        float tw = 0.5 + 0.5 * sin(6.2831853 * (phase + 3.0 * h.y));
        return exp(-dot(dd, dd) / 0.012) * tw * tw * (0.6 + 0.8 * h.z);
    }

    /// The manta from above in its own units (x along its heading, y across it, the half-span 1): broad wings sweeping
    /// back to their tips, the trailing edges hollow, the cephalic fins ahead and a thin tail behind; the wings rise and
    /// fall slowly (`beat`, 0…1). Returns how far inside its outline the point is (< 0 outside), in those units.
    float bayMantaMargin(float2 p, float beat) {
        float spanK = 0.9 + 0.1 * cos(6.2831853 * beat);   // the tips lift and fall: seen from above, the span breathes
        float ax = abs(p.y) / spanK;
        float m = -1.0;
        if (ax < 1.0) {
            float lead = 0.42 - 0.7 * ax * sqrt(ax);
            float trail = -0.3 + 0.25 * sin(3.14159265 * sqrt(ax) * ax) - 0.04 * ax;
            m = min(lead - p.x, p.x - trail);
        }
        float2 h1 = (p - float2(0.46, 0.08)) / float2(0.08, 0.03), h2 = (p - float2(0.46, -0.08)) / float2(0.08, 0.03);
        m = max(m, 0.03 * (1.0 - min(length(h1), length(h2))));
        float tail = (p.x < -0.25 && p.x > -0.95) ? 0.012 - abs(p.y) : -1.0;
        return max(m, tail);
    }

    /// What Excitement draws on the water at q (across, out; `f` out), seen along d through a surface of Fresnel `fres`:
    /// `under` is the light below the surface already there (Glow Wake), which the manta's dark form covers. Energy's
    /// flecks, the glow gathered under the surface, the wave of light and a drop's sparkles, the manta lit along its edges
    /// with its wingtips' trails, and the turtle's rings.
    float3 bayExcite(float3 d, float2 q, float f, float footprint, float fres, float3 under, constant BayU& b,
                     constant OceanU& o) {
        float night = b.a.w, eye = b.a.z;
        float3 g = under;
        // The glow gathering under the surface (tension): soft, deep, blurred by the water over it, mid-bay.
        float gather = b.excite.x;
        if (gather > 0.001) {
            float region = smoothstep(8.0, 16.0, f) * (1.0 - smoothstep(45.0, 110.0, f));
            float ang = q.x / max(f, 1.0);
            float blobs = smoothstep(0.25, 0.8, vnoise3(float3(q.x * 0.09, f * 0.05, 1.3 * sin(o.phases.y) + 0.8 * cos(o.phases.x))));
            float breathe = 0.85 + 0.15 * sin(o.phases.x * 2.0);
            g += float3(0.04, 0.42, 0.56) * (gather * region * exp(-ang * ang / 0.3) * (0.3 + 0.7 * blobs) * breathe * 0.75);
        }
        // The wave of light: a band running in from the mouth (its middle ahead, an arc), broken into patches of plankton,
        // brightest along its crest, the water behind it still lit and fading.
        float wl = b.wave.y;
        float band = 0.0;
        if (wl > 0.001) {
            float ang = q.x / max(f, 1.0);
            float F = b.wave.x * (1.0 + 0.6 * ang * ang);
            float x = (f - F) / (0.16 * F + 0.5);             // < 0 not reached yet … > 0 passed
            float crest = exp(-x * x * 3.0);
            float behind = x > 0.0 ? 0.5 * exp(-x / 2.5) + 0.25 * exp(-x / 12.0) : 0.0;
            band = crest + behind;
            if (band > 0.002) {
                float n = vnoise3(float3(q.x * 0.22, f * 0.07, 2.0 * sin(o.phases.z) + 1.2 * cos(o.phases.w)));
                float patchy = 0.35 + 1.0 * smoothstep(0.25, 0.8, n);
                float fine = 1.0 - smoothstep(0.15, 0.6, footprint);
                float fl = vnoise3(float3(q * float2(2.2, 1.1), 2.0 * sin(o.phases.y)));
                float flecked = mix(1.0, 0.5 + 1.0 * fl, fine);
                float3 c = mix(kWaveBlue, kGlowCyan, 0.35 + 0.3 * n) + float3(0.6, 0.6, 0.45) * (crest * crest * 0.5);
                g += c * (wl * b.excite.z * band * patchy * flecked * 1.25);
            }
        }
        // Energy's plankton firing in points over the near water, and a drop's sparkles scattering behind its wave.
        float fleckDensity = 0.1 * b.excite.y * night * (1.0 - smoothstep(25.0, 60.0, f));
        float sparkle = b.wave.w * saturate(band * 1.5);
        float points = bayFlecks(q, f, fleckDensity + 0.55 * sparkle, b.excite.w, eye);
        if (points > 0.001) g += mix(kGlowCyan, float3(0.85, 1.0, 1.0), 0.4) * (points * (0.5 * b.excite.y * night + 2.2 * sparkle));
        // The manta gliding in under the surface: its dark form covers the light beneath it, the plankton lit along its
        // wing edges (brighter on each downstroke) and in two trails from its wingtips.
        float mc = b.manta.w;
        if (mc > 0.001) {
            float halfSpan = 0.5 * b.mantaB.x;
            float2 dq = q - b.manta.xy;
            float2 fw = float2(cos(b.manta.z), sin(b.manta.z));
            float2 p = float2(dot(dq, fw), dot(dq, float2(-fw.y, fw.x))) / halfSpan;
            if (abs(p.x) < 6.0 && abs(p.y) < 1.6) {
                float beat = b.mantaB.y;
                float m = bayMantaMargin(p, beat);
                float w = max(0.035, 0.8 * footprint / halfSpan);
                float inside = smoothstep(-w, w, m);
                g *= 1.0 - 0.9 * inside * mc;
                float stroke = 0.6 + 0.4 * saturate(sin(6.2831853 * beat) + 0.3);
                float rim = exp(-(m * m) / (w * w)) * step(-0.5, m);
                float spanK = 0.9 + 0.1 * cos(6.2831853 * beat);
                float tipX = -0.3, behind = tipX - p.x;
                float lat = abs(abs(p.y) - spanK * (0.97 + 0.02 * behind));
                float trails = behind > 0.0 ? exp(-(lat * lat) / (w * w * 2.0)) * exp(-behind / 2.2) : 0.0;
                float body = inside * 0.12 * (0.5 + 0.5 * vnoise3(float3(p * 6.0, 1.0)));
                float3 lit = mix(kGlowCyan, kWaveBlue, 0.4);
                g += lit * (b.mantaB.z * mc * (1.6 * rim * stroke + 0.9 * trails + body));
            }
        }
        // The turtle's rings of glow, spreading from where it came up (and again as it dives).
        float tl = b.turtle.w;
        if (tl > 0.001) {
            float2 dq = q - b.turtle.xy;
            float r = length(dq);
            if (r < 9.0) {
                float age = b.turtle.z;
                float rings = 0.0;
                for (int k = 0; k < 3; k++) {
                    float born = k == 0 ? 0.6 : (k == 1 ? 1.3 : 6.4);
                    float a = age - born;
                    if (a <= 0.0 || a > 5.0) continue;
                    float rr = 0.45 + 0.75 * a;
                    float wr = 0.12 + 0.06 * a + 0.6 * footprint;
                    float x = (r - rr) / wr;
                    rings += exp(-x * x) * exp(-a / 1.8) * (k == 2 ? 0.7 : 1.0);
                }
                float stir = exp(-r * r / 0.8) * b.turtleB.x * 0.5;   // the plankton stirred round its shell
                float n = 0.6 + 0.6 * vnoise3(float3(dq * 3.0, 2.0 * sin(o.phases.z)));
                g += mix(kGlowCyan, kWaveBlue, 0.3) * (tl * (rings * n * 1.4 + stir));
            }
        }
        return g * (1.0 - 0.35 * fres);
    }

    /// The turtle's dark shell and head breaking the surface, seen along the ray that meets the water `f` out at q: the
    /// ray's height where it passes the turtle (the eye is `eye` m up). Its cover (0…1).
    float bayTurtleAbove(float2 q, float f, float eye, constant BayU& b) {
        float up = b.turtleB.x, cover = b.turtleB.z;
        if (cover < 0.001 || up < 0.001) return 0.0;
        float T = b.turtle.y;
        if (f < T - 0.6 || f > T * 1.6) return 0.0;
        float z = f > T ? eye * (1.0 - T / f) : 0.0;          // the ray's height over the water as it passes the turtle
        float xc = f > T ? q.x * T / f : q.x;
        float dx = xc - b.turtle.x;
        float shellH = 0.09 * up * sqrt(saturate(1.0 - (dx / 0.5) * (dx / 0.5)));
        float pxm = 0.0016 * T;
        float shell = f > T ? saturate((shellH - z) / pxm + 0.5) * step(abs(dx), 0.5) : 0.0;
        // Its footprint on the water (the ray meets the water at the shell itself).
        float2 fp = (q - b.turtle.xy) / float2(0.5, 0.38);
        float foot = (1.0 - smoothstep(0.85, 1.0, length(fp))) * step(0.5, up);
        float2 hd = float2((xc - b.turtle.x - b.turtleB.y * 0.6) / 0.12, (z - 0.02 - 0.1 * up) / 0.085);
        float head = f > T ? (1.0 - smoothstep(0.8, 1.0, length(hd))) : 0.0;
        return max(max(shell, foot), head) * cover;
    }

    // ---------------------------------------------------------------- water and sand

    /// The water's surface at q (across, out; `f` out) seen along d, and what it mirrors: its footprint, normal and
    /// reflected rays, and whether the headlands or their mangroves fill the mirror there (else the sky does, along `rd`).
    struct BayMirror { float footprint; float3 nrm; float3 rd0; float3 rd; float rAlt; bool land; bool mangrove; };
    BayMirror bayMirror(float3 d, float2 q, float f, float camAz, float2 fwd, float2 rgt, int octaves, constant SkyU& u,
                        constant OceanU& o) {
        BayMirror m;
        m.footprint = oceanFootprint(d, f, u);
        float2 slope = oceanSlope(q, o, m.footprint);
        m.nrm = oceanNormal(slope, fwd, rgt);
        m.rd0 = reflect(d, m.nrm);
        m.rd = normalize(float3(m.rd0.xy, max(m.rd0.z, 0.002)));
        // What the mirror shows: the boat, the headlands and their mangroves, else the sky.
        float rAz = bayWrap(atan2(m.rd.x, m.rd.y) - camAz);
        m.rAlt = asin(clamp(m.rd.z, -1.0, 1.0));
        float landS = bayLandSmooth(rAz);
        float mang = m.rAlt < toRad(1.2) ? bayMangroves(rAz) : 0.0;
        float land = (landS > -0.5 && m.rAlt < landS + toRad(1.0)) ? bayLand(rAz, min(octaves, 2)) : -1.0;
        m.land = m.rAlt < land || m.rAlt < mang;
        m.mangrove = m.rAlt < mang;
        return m;
    }

    /// The bay's water at q (across, out; `f` out), seen along d: its own colour (turquoise over the sand by day, dark at
    /// night), mirroring the headlands, the boat and the sky (stars, aurora, moon; `sky`, the sky's light along the
    /// mirror's ray, drawn by the fragment's one call) by Fresnel, the moon's and the sun's paths, the lantern's light and
    /// the lighthouse's flash on it, then Glow Wake (emissive, unreflected).
    float3 bayWater(float3 d, float2 q, float f, float2 fwd, float2 rgt, BayMirror mirror, float3 sky, constant SkyU& u,
                    constant BayU& b, constant OceanU& o) {
        float footprint = mirror.footprint;
        float3 nrm = mirror.nrm, rd0 = mirror.rd0, rd = mirror.rd;
        float3 refl;
        if (mirror.land) {
            refl = bayLandColor(mirror.rAlt, mirror.mangrove, u, b, o) * 0.85;
        } else {
            refl = sky;
        }
        float3 boatCol = float3(0);
        float boat = bayBoatMirrored(rd, q, fwd, rgt, b, u, o, boatCol);
        refl = mix(refl, boatCol * 0.85, boat);
        float cosT = saturate(-dot(d, nrm));
        float m = 1.0 - cosT, m2 = m * m;
        float fres = 0.02 + 0.98 * m2 * m2 * m;
        // The water's own colour: dark at night; by day turquoise over the sand in the shallows, deepening out in the bay.
        float day = b.e.x;
        float3 zenith = u.zenith.rgb, horizon = u.horizon.rgb;
        float shallow = 1.0 - smoothstep(9.0, 70.0, f);
        float3 sunLit = o.sunColor.rgb * o.sun.w * 0.9 + mix(zenith, horizon, 0.5) * 0.6;
        float3 bodyDay = mix(float3(0.015, 0.16, 0.24), float3(0.09, 0.50, 0.46), shallow) * sunLit;
        float3 bodyNight = zenith * 0.05 + horizon * 0.03 + float3(0.0008, 0.002, 0.0025);
        float3 body = mix(bodyNight, bodyDay, day);
        if (day > 0.01 && shallow > 0.01) {
            // Sunlight netting the sandy bottom in the shallows (faded where a pixel covers the net's mesh).
            float fine = 1.0 - smoothstep(0.5, 1.5, footprint);
            float caustic = smoothstep(0.55, 0.85, vnoise3(float3(q * float2(0.9, 1.6), 2.0 * sin(o.phases.x) + 1.3 * cos(o.phases.z))));
            body += float3(0.10, 0.28, 0.24) * (caustic * shallow * day * o.sun.w * fine);
        }
        float3 col = mix(body, refl, fres);
        // The sun's and the moon's paths.
        float glitter = o.moonColor.w;
        col += glitterPath(d, nrm, q, f, o.sun.xyz, o.sunColor.rgb * 2.5, o.sun.w, glitter, footprint, o);
        col += glitterPath(d, nrm, q, f, o.moon.xyz, o.moonColor.rgb, o.moon.w, glitter, footprint, o);
        // The lantern pooled on the water round the boat and shining back from it in a broken column.
        float lantern = b.c.x;
        if (lantern > 0.001) {
            float3 lp = float3(b.lantern.x - q.x, b.lantern.y - q.y, b.lantern.z);
            float3 L = normalize(float3(rgt * lp.x + fwd * lp.y, lp.z));
            float sd = dot(rd0, L);
            float spec = exp(8000.0 * (sd - 1.0)) * 3.0 + exp(400.0 * (sd - 1.0)) * 0.1;
            float pool = exp(-(lp.x * lp.x + lp.y * lp.y) / 14.0) * 0.05;
            col += kLanternWarm * (lantern * (spec + pool));
        }
        // The lighthouse's flash shining back across the bay.
        float flash = b.c.y;
        if (flash > 0.001) {
            float sd = dot(rd0, b.lighthouseDir.xyz);
            col += kLampWhite * (flash * (exp(12000.0 * (sd - 1.0)) * 3.0 + exp(500.0 * (sd - 1.0)) * 0.12));
        }
        float3 under = bayGlowWake(q, footprint, b, o);
        col += bayExcite(d, q, f, footprint, fres, under, b, o);
        // The turtle breaking the surface: a dark shell and head (lit a little by the sky by day).
        float turtle = bayTurtleAbove(q, f, b.a.z, b);
        if (turtle > 0.001) {
            float3 shellCol = mix(float3(0.003, 0.004, 0.004), float3(0.16, 0.13, 0.07) * (o.sunColor.rgb * o.sun.w * 0.6 + mix(zenith, horizon, 0.5) * 0.6), day);
            col = mix(col, shellCol, turtle);
        }
        return col;
    }

    /// Whether the sand at q mirrors the sky (wet toward the waterline or after rain, or under a wavelet's wash), and in
    /// `dir` the way it mirrors (its ripples roughening it): the fragment draws the sky there in its one call.
    bool baySandMirror(float3 d, float2 q, float f, float edge, constant BayU& b, thread float3& dir) {
        float wet = max(smoothstep(edge - 1.2, edge - 0.3, f), 0.6 * b.c.w);
        float front = edge - bayWash(b).x;
        bool sheet = f > front;
        if (!(wet > 0.01 || sheet)) return false;
        float2 rough = (float2(vnoise3(float3(q * 3.0, 2.0)), vnoise3(float3(q * 3.0 + 7.0, 4.0))) - 0.5) * (sheet ? 0.025 : 0.07);
        float3 rd = reflect(d, normalize(float3(rough, 1.0)));
        rd.z = max(rd.z, 0.002);
        dir = normalize(rd);
        return true;
    }

    /// The sand: white by day, mirror-dark and wet toward the waterline (and all over after rain), under the thin sheet of
    /// each wavelet's wash; `sky` is the sky's light it mirrors (baySandMirror's way).
    float3 baySand(float3 d, float2 q, float f, float edge, float3 sky, constant SkyU& u, constant BayU& b,
                   constant OceanU& o) {
        float3 zenith = u.zenith.rgb, horizon = u.horizon.rgb;
        float grain = vnoise3(float3(q * float2(9.0, 5.0), 3.0));
        float ripple = 0.5 + 0.5 * sin(q.y * 9.0 + 2.0 * vnoise3(float3(q * 0.7, 1.0)) + q.x * 0.6);
        float3 sand = float3(0.93, 0.89, 0.81) * (0.86 + 0.06 * ripple + 0.08 * grain);
        float3 direct = o.sunColor.rgb * (saturate(o.sun.z * 3.0 + 0.15) * o.sun.w)
                      + o.moonColor.rgb * (saturate(o.moon.z * 3.0 + 0.15) * o.moon.w);
        // Under heavy cloud the sun and the moon are behind it: their direct light falls with it (b.sand), and the dark
        // cloud base takes some of the sky's light off the sand, so it sits as dark as the scene.
        float3 light = mix(zenith, horizon, 0.7) * ((0.55 + 0.6 * b.a.w) * b.sand.y) + direct * (0.7 * b.sand.x) + 0.003;   // white sand shows by starlight
        float3 col = sand * light;
        float wet = max(smoothstep(edge - 1.2, edge - 0.3, f), 0.6 * b.c.w);
        float front = edge - bayWash(b).x;
        bool sheet = f > front;
        if (wet > 0.01 || sheet) {
            float3 refl = sky;
            float m = 1.0 - saturate(-d.z);
            float fres = 0.25 + 0.6 * m * m * m;
            col = mix(col, mix(sand * light * 0.2, refl, fres), wet);
            if (sheet) {
                float thick = smoothstep(front, front + 0.6, f);
                float3 water = mix(refl, horizon * 0.5 + float3(0.04, 0.09, 0.085) * b.e.x, 0.25);
                col = mix(col, water, 0.35 + 0.4 * thick);
            }
        }
        return col;
    }

    // ---------------------------------------------------------------- near palms

    /// A near palm's coverage at q (screen units: x × aspect, y): a tapered, ringed trunk and a crown of drooping fronds
    /// with serrated leaflets (the beach's palm). Sway comes from the swell's wrapped phases.
    float bayPalm(float2 q, float2 root, float height, float lean, float scale, float sway, float frondSway, float seed,
                  constant SkyU& u, thread float& rime) {
        rime = 0.0;
        float2 top = root + float2(lean + sway, height);
        if (q.y < root.y - 0.02 || q.y > top.y + 0.42 * scale) return 0.0;
        float cover = 0.0;
        float deepest = -1.0;                 // rime (spec §6.4): the trunk, knot and midribs offer their depths
        float2 outward = float2(0.0, 1.0);
        float2 ctrl = root + float2(lean * 0.15 + 0.05 * sign(lean), height * 0.55);
        float2 prev = root;
        if (abs(q.x - mix(root.x, top.x, saturate((q.y - root.y) / height))) < 0.12) {
            for (int k = 1; k <= 6; k++) {
                float t = float(k) / 6.0;
                float2 pt = (1.0 - t) * (1.0 - t) * root + 2.0 * (1.0 - t) * t * ctrl + t * t * top;
                float2 dh = baySeg(q, prev, pt);
                float tt = (float(k - 1) + dh.y) / 6.0;
                float w = mix(0.03, 0.014, tt) * scale * (1.0 + 0.12 * abs(sin(tt * 70.0 + seed)));
                cover = max(cover, 1.0 - smoothstep(w * 0.6, w, dh.x));
                rimeKeepDeepest(w - dh.x, q - mix(prev, pt, dh.y), deepest, outward);
                prev = pt;
            }
        }
        float bend = saturate((q.y - root.y) / height);     // the feathers ride the palm as it sways
        float2 riding = q - float2(sway * bend * bend, 0.0);
        if (length(q - top) > 0.42 * scale) {
            if (cover > 0.0) rime = rimeEdge(u, deepest, outward, riding);
            return cover;
        }
        // A dark knot where the fronds meet.
        cover = max(cover, 1.0 - smoothstep(0.018 * scale, 0.03 * scale, length(q - top - float2(0.0, -0.01))));
        rimeKeepDeepest(0.03 * scale - length(q - top - float2(0.0, -0.01)), q - top - float2(0.0, -0.01), deepest, outward);
        for (int j = 0; j < 10; j++) {
            float h = hash13(float3(seed, float(j), 4.0));
            float a = -0.25 + float(j) * 0.36 + 0.25 * (h - 0.5) + 0.06 * sin(frondSway + float(j) * 1.7);
            float len = (0.26 + 0.1 * h) * scale;
            float2 dir = float2(cos(a), sin(a));
            float droop = (0.14 + 0.12 * saturate(dir.y)) * scale;
            float2 p0 = top;
            float2 p1 = top + dir * len * 0.4 + float2(0.0, 0.02 * scale);
            float2 p2 = top + dir * len * 0.75 - float2(0.0, droop * 0.45);
            float2 p3 = top + dir * len - float2(0.0, droop);
            float2 d1 = baySeg(q, p0, p1), d2 = baySeg(q, p1, p2), d3 = baySeg(q, p2, p3);
            float2 best = d1; float base = 0.0; float2 sa = p0, sb = p1;
            if (d2.x < best.x) { best = d2; base = 1.0; sa = p1; sb = p2; }
            if (d3.x < best.x) { best = d3; base = 2.0; sa = p2; sb = p3; }
            float t = (base + best.y) / 3.0;
            // Leaflets: thin blades slanting back from the midrib, hanging lower on the underside.
            float2 sd = normalize(sb - sa);
            float side = sd.x * (q.y - sa.y) - sd.y * (q.x - sa.x);   // > 0 above the midrib
            float reach = 0.045 * scale * sin(3.14159 * min(1.0, t * 1.05)) * (side > 0.0 ? 0.6 : 1.0);
            float across = best.x / max(reach, 1e-4);
            float blades = abs(fract(t * 22.0 + across * 0.9 + h * 3.0) - 0.5);
            float leaf = (1.0 - smoothstep(0.16, 0.32, blades)) * (1.0 - smoothstep(0.75, 1.0, across)) * step(0.05, t);
            cover = max(cover, leaf);
            cover = max(cover, 1.0 - smoothstep(0.003 * scale, 0.006 * scale, best.x));   // the midrib
            rimeKeepDeepest((0.006 * scale - best.x) * 3.0, q - mix(sa, sb, best.y), deepest, outward);   // a spine: a third the fringe
        }
        if (cover > 0.0) rime = rimeEdge(u, deepest, outward, riding);
        return cover;
    }

    /// A tall palm leaning in from the left edge and a smaller one from the right, rooted on the sand behind the keys.
    float bayNearPalms(float2 p, constant BayU& b, constant OceanU& o, constant SkyU& u, thread float& rime) {
        rime = 0.0;
        if (abs(p.x) < 0.3) return 0.0;
        float aspect = b.a.y, base = b.a.x - 0.02, wind = b.c.z;
        float2 q = float2(p.x * aspect, p.y);
        float sway = 0.01 + 0.03 * wind;
        if (p.x < 0.0) {
            return bayPalm(q, float2(-0.95 * aspect, base), 1.25, 0.24, 0.95, sway * sin(o.phases.x), o.phases.w, 5.0, u, rime);
        }
        return bayPalm(q, float2(0.97 * aspect, base), 0.95, -0.2, 0.75, sway * sin(o.phases.y + 1.3), o.phases.w + 2.5, 6.0, u, rime);
    }

    // ---------------------------------------------------------------- the frame

    fragment ColorDepth bay_fragment(BayOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant BayU& b [[buffer(1)]],
                                     constant OceanU& o [[buffer(2)]], texture2d<float> stars [[texture(0)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < b.a.x) {   // under the keyboard
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.1, 0, 0, 1);
            return out;
        }
        float3 d = bayRay(p, u);
        float alt = asin(clamp(d.z, -1.0, 1.0));
        float camAz = atan2(u.forward.x, u.forward.y);
        float azRel = bayWrap(atan2(d.x, d.y) - camAz);
        float2 fwd = normalize(u.forward.xy), rgt = float2(fwd.y, -fwd.x);
        float px = u.weather.w;
        int octaves = int(b.e.w + 0.5);
        float3 horizon = u.horizon.rgb, zenith = u.zenith.rgb;
        float night = b.a.w, haze = b.b.w, day = b.e.x;
        float palmRime;
        float palm = bayNearPalms(p, b, o, u, palmRime);
        float3 air = bayAirLight(d, alt, azRel, px, b);
        float3 boatCol = float3(0);
        float boat = bayBoatSeen(d, fwd, rgt, b, u, o, boatCol);
        float3 col;
        float depth = 1.0;
        // The sky's light is drawn at one call site: above the horizon the sky itself, below it the sky in the water's
        // or the wet sand's mirror. Each call inlines the whole sky again (a second one made every sky about sevenfold
        // slower on CI; the bay had three), so each branch first works out the way it needs the sky, then the sky is
        // drawn once, then each branch finishes with it.
        bool wantSky = false;
        float3 skyDir = d;
        bool hitLand = false;
        float mang = 0.0, farPalm = 0.0, tower = 0.0, lampRoom = 0.0;
        float f = 0.0, s = 0.0, edge = 0.0;
        float2 q = float2(0.0);
        bool water = false;
        BayMirror mirror;
        mirror.footprint = 0.0; mirror.nrm = float3(0.0, 0.0, 1.0); mirror.rd0 = d; mirror.rd = d; mirror.rAlt = 0.0;
        mirror.land = false; mirror.mangrove = false;
        if (alt >= 0.0) {
            // Above the horizon: the headlands with their mangroves and palms, the lighthouse, else the sky (only where
            // something of the bay's own is drawn; elsewhere the dome shows).
            bool low = alt < toRad(14.0);
            float landS = low ? bayLandSmooth(azRel) : -1.0;
            mang = alt < toRad(1.2) ? bayMangroves(azRel) : 0.0;
            float land = (landS > -0.5 && alt < landS + toRad(1.0)) ? bayLand(azRel, min(octaves, 2)) : -1.0;
            farPalm = low ? bayFarPalms(azRel, alt, px, b.c.z, o) : 0.0;
            tower = low ? bayTower(azRel, alt, px, b, lampRoom) : 0.0;
            hitLand = alt < land || alt < mang;
            if (!hitLand && farPalm < 0.002 && tower < 0.002 && boat < 0.002 && palm < 0.002 && air.x + air.y + air.z < 0.004) {
                discard_fragment();
                out.color = float4(0, 0, 0, 1); out.depth = float4(1, 0, 0, 1);
                return out;
            }
            wantSky = !hitLand;
        } else {
            // Below it: where the ray meets the bay (the eye is a.z metres up), the water beyond the wandering waterline
            // and the sand before it.
            float t = b.a.z / max(-d.z, 1e-4);
            float3 P = d * t;
            f = dot(P.xy, fwd);
            s = dot(P.xy, rgt);
            q = float2(s, f);
            edge = b.d.x + 0.35 * (vnoise3(float3(s * 0.22, 5.0, 1.5 * sin(o.phases.w))) - 0.5);
            water = f > edge;
            if (water) {
                mirror = bayMirror(d, q, f, camAz, fwd, rgt, octaves, u, o);
                wantSky = !mirror.land;
                skyDir = mirror.rd;
            } else {
                wantSky = baySandMirror(d, q, f, edge, b, skyDir);
            }
        }
        float3 sky = float3(0.0);
        if (wantSky) {
            float mm;
            sky = skyRadiance(skyDir, u, mm, stars);
        }
        if (alt >= 0.0) {
            if (hitLand) {
                col = bayLandColor(alt, alt < mang, u, b, o);
                depth = alt < mang ? 0.95 : 0.97;
            } else {
                col = sky;
            }
            if (farPalm > 0.002) col = mix(col, bayLandColor(alt, false, u, b, o) * 0.8, farPalm);
            if (tower > 0.002) {
                float3 white = float3(0.86, 0.86, 0.83) * (mix(zenith, horizon, 0.5) * 0.7 + o.sunColor.rgb * o.sun.w * 0.5);
                float3 towerCol = mix(float3(0.006, 0.006, 0.008), white, day) + kLampWhite * (lampRoom * (0.03 * night + 6.0 * b.c.y));
                col = mix(col, towerCol, tower);
                if (tower > 0.5) depth = 0.98;
            }
        } else {
            // Below it: the water or the sand, with the glow line along their edge.
            if (water) {
                col = bayWater(d, q, f, fwd, rgt, mirror, sky, u, b, o);
            } else {
                col = baySand(d, q, f, edge, sky, u, b, o);
            }
            col += bayGlowLine(s, f, edge, b, o);
            // Haze over the bay, thicker far away.
            col = mix(col, horizon * (1.02 + 0.1 * night), saturate(haze * 0.6 * (1.0 - exp(-f / 250.0))));
            depth = saturate(f / 60.0);
        }
        col = mix(col, boatCol, boat);
        if (boat > 0.5) depth = saturate(b.boat.y / 60.0);
        col += air;
        float3 palmCol = zenith * 0.04 + horizon * 0.035 + float3(0.02, 0.05, 0.025) * (o.sun.w * day);   // sky-lit green by day
        col = mix(col, palmCol, palm);
        if (palmRime > 0.0) col = mix(col, rimeColor(u), palmRime * palm);
        if (palm > 0.5) depth = 0.03;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light).
    struct BayKey { float4 rect; float4 info; };
    struct BayKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex BayKeyOut bay_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BayKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BayKey k = keys[iid];
        BayKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    /// Dark glass keys along the sand: a cool sheen near their tops, plankton cyan where you play.
    fragment ColorDepth bay_keys_fragment(BayKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.003, 0.005, 0.007) : float3(0.018, 0.028, 0.036);
        float y2 = in.uv.y * in.uv.y;
        float sheen = y2 * y2 * y2 * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * (1.0 - smoothstep(0.94, 1.0, in.uv.x));
        float3 c = base + float3(0.55, 0.75, 0.9) * (sheen * (0.4 + light)) + kGlowCyan * (glow * 1.7 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.1, 0, 0, 1);
        return o;
    }
    """
}
