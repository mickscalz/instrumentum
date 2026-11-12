/// Metal source for the Living Sky (dome, sun, moon, real and procedural stars, constellation lines, the Milky Way,
/// the aurora, shooting stars, light pillars, clouds) and the weather layer (rain, snow, splash rings, drops on glass,
/// fireflies, diamond-dust crystals, sea smoke). Compiled at runtime.
/// Smooth-quality rules: no ray marching, at most 3 noise octaves (2 on Smooth); the real stars are one texture sample.
enum SkyShaders {
    /// Noise, the sky uniforms and skyRadiance(): shared by the dome and by anything that reflects the sky.
    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };

    // ---------------------------------------------------------------- noise
    float hash13(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }
    float3 hash33(float3 p) {
        p = fract(p * float3(0.1031, 0.1030, 0.0973));
        p += dot(p, p.yxz + 33.33);
        return fract((p.xxy + p.yxx) * p.zyx);
    }
    float vnoise3(float3 p) {
        float3 i = floor(p), f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float a = hash13(i), b = hash13(i + float3(1, 0, 0)), c = hash13(i + float3(0, 1, 0)), d = hash13(i + float3(1, 1, 0));
        float e = hash13(i + float3(0, 0, 1)), g = hash13(i + float3(1, 0, 1)), h = hash13(i + float3(0, 1, 1)), k = hash13(i + float3(1, 1, 1));
        return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
    }
    float fbm3(float3 p, int octaves) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            s += a * vnoise3(p);
            p = p * 2.03 + float3(17.1, 9.2, 3.7);
            a *= 0.5;
        }
        return s / (1.0 - pow(0.5, float(octaves)));
    }
    /// fbm3 that also hands back its first octave (the field's big, smooth cells): the same sum, so the clouds drawn
    /// with it are the clouds fbm3 draws.
    float fbm3c(float3 p, int octaves, thread float& first) {
        float s = 0.0, a = 0.5;
        first = 0.5;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            float v = vnoise3(p);
            if (i == 0) first = v;
            s += a * v;
            p = p * 2.03 + float3(17.1, 9.2, 3.7);
            a *= 0.5;
        }
        return s / (1.0 - 2.0 * a);   // 1 − 0.5^octaves, exactly (a halves once per octave from 0.5)
    }

    // ---------------------------------------------------------------- sky dome
    // camera: right.xyz/tanH, up.xyz/tanV, forward.xyz/time (all in east-north-up)
    // eq0..eq2: columns turning east-north-up into equatorial (x: RA 0, z: north pole)
    struct SkyU {
        float4 right, up, forward;
        float4 zenith;      // rgb, star visibility
        float4 horizon;     // rgb, cloud cover
        float4 sun;         // direction, altitude (degrees)
        float4 moon;        // direction, phase 0…1
        float4 moonInfo;    // lit fraction, earthshine, moon radius (rad), sun radius (rad)
        float4 eq0, eq1, eq2;
        float4 weather;     // mist, wind, octaves, pixel angle (rad)
        float4 extra;       // halo, dawn pastel, gust, wetness
        float4 night;       // aurora, aurora storm, constellation lines, fireflies
        float4 aurora;      // pole-ward azimuth unit vector (east, north), band base altitude (degrees), hemisphere
        float4 dust;        // diamond dust, pillar, aurora hue shift (−1 cool … +1 warm), aurora glow 0…1
        float4 ripples[8];  // along the band 0…1, age (s), strength, width
        float4 still;       // iridescence 0…1, rime 0…1, the wind on screen (x right, y up: the way it blows × its strength)
        float4 meteorA[6];  // shooting stars (spec §7.2): start direction (east-north-up), head progress 0…1 (a train: drift, °)
        float4 meteorB[6];  // end direction, light on the stars' scale (1 = Sirius, before kRealStarGain; 0: the slot is empty)
        float4 meteorC[6];  // colour (linear, brightest channel 1), 0 for a head … the train's age 0.001…1
        float4 flash;       // a fireball's sky brightening (the sky × 1 + x, x ≤ 0.08), unused…
        // Fire & Neon (spec §6–§7)
        float4 storm;        // a far storm: its bearing (unit east, north), how much of it 0…1, its anvil's top (degrees)
        float4 stormFlicker; // its lightning inside: level 0…1, degrees across from its centre, how far up 0…1, width (degrees)
        float4 spriteA[3];   // red sprites: azimuth (degrees), base altitude (degrees), height (degrees), brightness (0: empty)
        float4 spriteB[3];   // columns (+ 0.9 × streamers in the fraction), spread (degrees), shape 0 carrot … 1 jellyfish, seed
        float4 satA[4];      // satellites: the lead's direction (east-north-up), its light on the stars' scale (0: empty)
        float4 satB[4];      // its motion across the sky (unit) × a train's spacing (radians; 0 for one), member count
        float4 satC[4];      // a train's shadow edge (member index, −1 none), +1 lit behind it / −1 before, footprint (rad), redden
        float4 cellA;        // the supercell weather: its bearing (unit east, north), phase 0…1, amount 0…1 (0: none)
        float4 cellB;        // green 0…0.12, the wall cloud's turn (radians), lightning inside 0…1, hail 0…1
        float4 cellC;        // the storm's distance (km: + ahead, − behind), the anvil's trailing edge (km), mammatus 0…1, flash spot
        float4 ash;          // ash 0…1, the sun's and moon's light through it (rgb)
    };
    // eq0.w is 1 when the real star texture is bound (0: a 1×1 placeholder, the procedural stars carry the sky).

    // The real stars: equirectangular, x = RA (wraps), y = Dec +90 → −90 (clamped).
    constexpr sampler skyStarSampler(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    // Sirius's peak (1.0 in the texture) shows at the brightest procedural star's scale (starField's mag reaches ~9.25).
    constant float kRealStarGain = 9.0;
    // The sun's pillar: the spec's 0.35 of its (HDR, 9–14) colour is lost against the bright low sky after the tone
    // curve; 0.55 stands a thin column over a 4° sun (6° up it reads about 1.35× the sky beside it, and 10° up it is
    // still a colour, not clipped white: 1.2 blew it out into a flare); the moon's keeps 0.35.
    constant float kPillarGain = 0.55;
    // Constellation lines: the spec's 0.06 all but vanishes where a figure crosses the Milky Way (Crux, Scorpius,
    // Cygnus), so 0.1: a clear blue trace at full strength, a faint one at the default 35%.
    constant float kLineGain = 0.1;

    // ---------------------------------------------------------------- optics (mirrors HaloOptics)
    float toDeg(float r) { return r * 57.2957795; }
    float toRad(float d) { return d * 0.0174532925; }
    float3 haloRing(float angleDeg, float radius) {
        float x = angleDeg - radius;
        float a = (x + 0.2) / 0.3, b = (x - 0.15) / 0.35;
        float tail = smoothstep(-0.1, 0.3, x) * exp(-max(0.0, x - 0.1) / 1.5);
        return exp(-a * a) * float3(1.0, 0.25, 0.05) + exp(-b * b) * float3(0.9, 0.85, 0.3) + tail * float3(0.55, 0.65, 0.85);
    }
    float sundogStrength(float altDeg) {
        return altDeg < -1.0 ? 0.0 : 1.0 - smoothstep(30.0, 45.0, altDeg);
    }
    /// Two rainbow-tinted spots 22°/cos(alt) either side of the light at its altitude, each with a short white tail outward.
    float3 sundogs(float3 d, float3 L, float lightAltDeg) {
        float s = sundogStrength(lightAltDeg);
        if (s <= 0.0) return float3(0);
        float altD = toDeg(asin(clamp(d.z, -1.0, 1.0)));
        float dAz = toDeg(atan2(d.x, d.y) - atan2(L.x, L.y));
        dAz -= 360.0 * floor((dAz + 180.0) / 360.0);
        float c = cos(toRad(lightAltDeg));
        float x = (abs(dAz) - 22.0 / max(c, 0.2)) * c;   // degrees outward from the dog
        float y = altD - lightAltDeg;
        float core = exp(-(x * x) / 0.81 - (y * y) / 1.96);
        float3 tint = mix(float3(1.0, 0.45, 0.2), float3(0.75, 0.85, 1.0), smoothstep(-0.8, 0.8, x));
        float tail = x > 0.0 ? exp(-x / 7.0) * exp(-(y * y) / 0.25) * 0.35 : 0.0;
        return (tint * core + float3(tail)) * s;
    }
    /// Rainbow light at `angleDeg` from the antisolar point (mirrors RainbowOptics.bow).
    float3 spectrum(float t) {
        float a = (t - 0.88) / 0.2, b = (t - 0.5) / 0.18, c = (t - 0.12) / 0.2;
        return float3(exp(-a * a), exp(-b * b), exp(-c * c));
    }
    float3 rainbowBow(float angleDeg) {
        float t1 = (angleDeg - 40.5) / 2.0;
        if (t1 >= 0.0 && t1 <= 1.0) return spectrum(t1) * smoothstep(0.0, 0.12, t1) * (1.0 - smoothstep(0.88, 1.0, t1));
        float t2 = (angleDeg - 50.5) / 3.0;
        if (t2 >= 0.0 && t2 <= 1.0) return spectrum(1.0 - t2) * smoothstep(0.0, 0.12, t2) * (1.0 - smoothstep(0.88, 1.0, t2)) * 0.35;
        return float3(0.0);
    }
    float beltOfVenus(float sunAltDeg) {
        return smoothstep(-6.0, -4.0, sunAltDeg) * (1.0 - smoothstep(0.0, 1.0, sunAltDeg));
    }
    /// The procedural stars. A star's brightness rank is r.y (0…1; its magnitude climbs steeply with it): `rankLimit`
    /// keeps those ranked at or below it (0.7 leaves out the brightest 30%, for the real stars to replace; 2 keeps all).
    float3 starField(float3 v, float pixelAngle, float time, float visibility, float rankLimit) {
        const float scale = 90.0;
        float3 p = v * scale;
        float3 cell = floor(p);
        float3 r = hash33(cell);
        if (r.x > 0.30 || r.y > rankLimit) return float3(0);    // most cells are empty
        float3 star = cell + 0.15 + 0.7 * hash33(cell + 7.7);
        float d = length(p - star);
        float radius = max(0.9 * pixelAngle * scale, 0.04);
        float mag = pow(r.y, 7.0) * 9.0 + 0.25 * r.y;            // a few bright stars, many faint ones
        float twinkle = 0.82 + 0.18 * sin(time * (1.7 + 4.0 * r.z) + r.z * 40.0);
        float3 tint = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.86, 0.7), r.z);
        return tint * mag * twinkle * exp(-(d * d) / (radius * radius)) * visibility;
    }

    float3 milkyWay(float3 v, int octaves, float visibility) {
        const float3 ngp = float3(-0.8676, -0.1981, 0.4560);    // galactic north pole (RA 192.86°, Dec 27.13°)
        const float3 gc = float3(-0.0548, -0.8734, -0.4838);    // galactic centre (RA 266.41°, Dec −28.94°)
        float b = asin(clamp(dot(v, ngp), -1.0, 1.0));
        float band = exp(-(b * b) / (0.2 * 0.2));
        if (band < 0.01) return float3(0);
        float toCentre = 0.5 + 0.5 * dot(v, gc);
        float centre = 0.3 + 0.7 * toCentre * toCentre;
        float n = fbm3(v * 5.0, octaves);
        float lane = exp(-(b * b) / (0.035 * 0.035)) * smoothstep(0.35, 0.8, fbm3(v * 9.0 + 3.1, max(octaves - 1, 1)));
        float glow = band * centre * (0.35 + 0.9 * n) * (1.0 - 0.75 * lane);
        return float3(0.92, 0.88, 1.0) * glow * 0.22 * visibility;
    }

    /// The real stars and the constellation lines along equatorial direction `v` (one bilinear sample). The texture
    /// stores the square root of the light, so it is squared back here.
    float3 realStars(float3 v, texture2d<float> stars, float time, float lines, float visibility) {
        float ra = atan2(v.y, v.x);
        ra = ra < 0.0 ? ra + 6.2831853 : ra;
        float dec = asin(clamp(v.z, -1.0, 1.0));
        float2 uv = float2(ra / 6.2831853, 0.5 - dec / 3.14159265);
        float4 t = stars.sample(skyStarSampler, uv, level(0.0));
        float3 light = t.rgb * t.rgb;
        // A twinkle hashed over the sky in cells smaller than a degree and smoothed between them (so a star's footprint
        // never splits on a cell edge, and RA 0/360 has no seam): 0.8–1.0, flickering at a few hertz.
        float twinkle = 0.8 + 0.2 * vnoise3(v * 80.0 + float3(0.0, 0.0, time * 3.0));
        float3 col = light * kRealStarGain * twinkle * visibility;
        col += float3(0.55, 0.65, 0.9) * t.a * kLineGain * lines * visibility;
        return col;
    }

    /// The pole-ward aurora (spec §6.3). The band's base is a great circle through the points 90° either side of the
    /// pole-ward azimuth, tilted up to the base altitude A over the pole-ward horizon (so it stands A° up there and
    /// comes down to the horizon at the band's ends; at A near 90° it arches through the zenith). Two thin curtains
    /// rise from it with an exponential profile, striped by vertical rays (noise along the band only).
    float3 auroraLight(float3 d, constant SkyU& u, float time, int octaves) {
        float2 ph = u.aurora.xy;
        float3 P = float3(ph / max(length(ph), 1e-4), 0.0);
        float3 W = float3(P.y, -P.x, 0.0);
        float A = toRad(clamp(u.aurora.z, 0.5, 89.0));
        float3 B = P * cos(A) + float3(0.0, 0.0, sin(A));
        float3 U = float3(0.0, 0.0, cos(A)) - P * sin(A);
        float along = atan2(dot(d, W), dot(d, B));            // 0 mid-band, ±π/2 at its ends on the horizon
        float ends = 1.0 - smoothstep(1.2, 1.5708, abs(along));
        if (ends <= 0.0) return float3(0);
        float h = toDeg(asin(clamp(dot(d, U), -1.0, 1.0)));     // degrees above the base
        float crown = 1.0 - smoothstep(55.0, 80.0, h);
        if (crown <= 0.0 || h < -14.0) return float3(0);   // well below the base the light is gone
        float pos = 0.5 + along / 3.14159265;                    // 0…1 along the band
        float storm = saturate(u.night.y);
        float hueShift = clamp(u.dust.z, -1.0, 1.0), glow = saturate(u.dust.w);
        float warm = max(hueShift, 0.0), cool = max(-hueShift, 0.0);

        // Ripples: each a bulge and a brightness pulse travelling outward both ways from where it started.
        float pulse = 0.0;
        for (int i = 0; i < 8; i++) {
            float4 r = u.ripples[i];
            if (r.z < 0.001) continue;
            float w = max(r.w, 0.01), travel = 0.12 * max(r.y, 0.0);
            float a = (pos - (r.x - travel)) / w, b = (pos - (r.x + travel)) / w;
            pulse += max(exp(-a * a), exp(-b * b)) * r.z;
        }
        pulse = min(pulse, 1.0);

        float t = time;
        float wobble = (vnoise3(float3(along * 3.0, t * 0.04, 7.3)) - 0.5) * 5.0;   // one octave, degrees
        float scale = 8.0 + 6.0 * storm;
        float sharp = saturate(0.35 + 0.45 * storm + 0.35 * glow);
        float3 green = mix(float3(0.25, 1.0, 0.45), float3(0.35, 0.55, 1.0), 0.6 * cool);
        float3 top = mix(float3(0.95, 0.25, 0.4), float3(0.55, 0.35, 1.0), cool);
        float topW = storm + 0.7 * warm + 0.5 * cool;
        float3 fringe = mix(mix(float3(0.6, 0.35, 1.0), float3(1.0, 0.78, 0.3), warm), float3(0.45, 0.4, 1.0), cool);
        float fringeW = storm * storm + 0.6 * warm + 0.4 * cool;

        float3 col = float3(0);
        float nearRays = 0.5;
        for (int c = 0; c < 2; c++) {
            float seed = c == 0 ? 0.0 : 31.0;
            // The second curtain stands 7° higher, behind the first; a ripple pushes the base down 3° (a bulge).
            float hb = h - (c == 0 ? 0.0 : 7.0) - wobble * (c == 0 ? 1.0 : 0.7) + 3.0 * pulse;
            float profile = hb < 0.0 ? exp(hb / 1.2) : exp(-hb / scale);
            float topP = hb > 0.0 ? smoothstep(2.0, scale, hb) * exp(-hb / (scale * 2.2)) : 0.0;
            float f = hb + 0.8;
            float fringeP = exp(-(f * f) / 1.5);
            // Rays: fbm along the band (3 octaves, 2 on Smooth); the far curtain takes one octave of its own above
            // Smooth and shares the near one's on Smooth.
            float n = c == 0 ? fbm3(float3(along * 38.0 + t * 0.05, t * 0.12, seed), octaves)
                             : (octaves > 2 ? vnoise3(float3(along * 30.0 - t * 0.04, t * 0.1, seed)) : nearRays);
            if (c == 0) nearRays = n;
            float rays = mix(0.6 + 0.4 * n, smoothstep(0.42, 0.68, n), sharp);
            float3 sheet = green * profile + top * (topW * topP) + fringe * (fringeW * fringeP);
            col += sheet * rays * (c == 0 ? 1.0 : 0.5);
        }
        // A full aurora peaks near 0.2 linear (about 0.35 of a day sky's luminance); the glow lifts it up to 1.6×, a
        // ripple's pulse up to 1.6× where it passes (Curtain Lights sends them through the flash limiter).
        return col * 0.25 * u.night.x * ends * crown * (1.0 + 0.6 * glow) * (1.0 + 0.6 * pulse);
    }

    /// A light pillar: a column through a light of angular radius `radius`, 1.5× as wide, fading exp(−|Δalt|/6°)
    /// from the light's edge.
    float lightPillar(float3 d, float alt, float3 L, float radius) {
        float lAlt = asin(clamp(L.z, -1.0, 1.0));
        float dAz = atan2(d.x, d.y) - atan2(L.x, L.y);
        dAz -= 6.2831853 * floor((dAz + 3.14159265) / 6.2831853);
        float x = dAz * cos(alt) / max(radius * 1.5, 1e-4);
        float dy = max(abs(alt - lAlt) - radius, 0.0);
        return exp(-x * x) * exp(-toDeg(dy) / 6.0);
    }

    /// Iridescent cloud (spec §6.3): thin cloud (density 0.05–0.5) within 40° of the sun turns pastel, in bands whose
    /// hue cycles with the angle from the sun and with the cloud's density (so they run along its edges), most
    /// saturated 10–20° from the sun and gone by 40°. With the sun low, a smooth iridescent cap (a pileus) arcs over the
    /// tops of the cloud's big cells: `n1` is the field's first octave (the cells, whose contours are smooth), `edge1`
    /// the level of it where the cloud begins, `near` how close the full field is to the cloud's edge from outside
    /// (so a cap only ever sits just over a cloud), and the one extra read is that octave 1.5° higher up the sky
    /// (where it falls away, this is a cell's upper side). The band is one sine (and its cosine) of a dot product:
    /// mother-of-pearl pinks and greens with a little lilac and gold between them, never a rainbow. The colour is
    /// never brighter than the cloud's own light + 20%. Returns the cloud's colour and, in `veil`, the cap's density.
    float3 iridescentCloud(float3 cloud, float3 d, float angleDeg, float density, float n1, float edge1, float near,
                           float2 drift, float time, constant SkyU& u, thread float& veil) {
        veil = 0.0;
        float zone = smoothstep(3.0, 10.0, angleDeg) * (1.0 - smoothstep(20.0, 40.0, angleDeg));
        float k = saturate(u.still.x) * zone;
        if (k <= 0.0) return cloud;
        float thin = smoothstep(0.03, 0.1, density) * (1.0 - smoothstep(0.3, 0.55, density));
        float cap = 0.0, capBand = 0.0;
        float low = 1.0 - smoothstep(12.0, 25.0, u.sun.w);
        if (low > 0.0 && near > 0.0) {
            float3 du = normalize(d + float3(0.0, 0.0, 0.026));
            float2 uvu = du.xy / (du.z + 0.12) * 0.55 + drift;
            float fall = saturate((n1 - vnoise3(float3(uvu * 2.2, time * 0.003))) * 10.0);
            float lift = edge1 - n1;                       // how far below the cloud's own level in the cells
            capBand = smoothstep(0.02, 0.07, lift) * (1.0 - smoothstep(0.07, 0.17, lift));
            cap = capBand * fall * near * low;
            veil = 0.16 * cap * k;
        }
        float a = k * max(thin, cap);
        if (a <= 0.0) return cloud;
        // Broad bands: a cycle per 9° out from the sun and one across the thin edge (along the cap for a cap).
        float phase = dot(float2(angleDeg, density + 0.5 * capBand), float2(0.7, 11.0));
        float s = sin(phase), c = cos(phase);
        float3 chroma = s * float3(0.6, -0.22, 0.4) + 0.3 * c * float3(-0.05, -0.08, 0.95);   // pink↔green, lilac↔gold
        float3 iri = cloud * (1.0 + chroma * (0.85 * a));                                       // luminance kept
        const float3 lw = float3(0.2126, 0.7152, 0.0722);
        float lc = dot(cloud, lw), li = dot(iri, lw);
        return max(iri, 0.0) * min(1.0, 1.2 * lc / max(li, 1e-5));
    }

    // ---------------------------------------------------------------- shooting stars (spec §6.3)
    // Six slots (SkyU's meteorA/B/C). A head runs from its start toward its end along their great circle (A.w how far):
    // a bright point with a tail fading over the 25% of the path behind it. A train (C.w its age, > 0) glows along the
    // whole path, widening 1 → 3× and drifting sideways by a one-octave noise as it ages (A.w: how far, degrees). B.w is
    // the light on the stars' scale (1 = Sirius = the real-star texture's peak, before kRealStarGain); 0 leaves the slot
    // empty. Core computes every light curve (the sin^0.7 rise and fall, the terminal flare, the train's fade), so there
    // is no pow here.

    /// A head's light at most (HDR; Sirius is 9): a fireball's head stays a hard point under the bloom, never a ball of
    /// light the size of the moon. Brighter heads grow their faint halo instead (up to 3×).
    constant float kMeteorPeak = 16.0;
    /// A train's light at most (HDR): it eases toward this (x ↦ cap·(1 − e^(−x/cap)), so faint trains keep their light),
    /// because a line as bright as a few percent of a fireball's head would read as a laser, not a faint glow.
    constant float kTrainPeak = 0.25;

    /// The shooting stars' light along `d` (altitude `alt` > 0), dimmed by mist and cloud like the stars and faded into
    /// the haze over the last 2° above the horizon. A slot costs one dot product where it is rejected (nearly every pixel).
    float3 meteorLight(float3 d, float alt, constant SkyU& u) {
        float3 sum = float3(0);
        float w = 0.75 * max(u.weather.w, 1e-5);       // the streak's half-width: about 1.25 px across at half its peak
        for (int i = 0; i < 6; i++) {
            float light = u.meteorB[i].w;
            if (light <= 0.0) continue;                 // an empty slot
            float3 S = u.meteorA[i].xyz, E = u.meteorB[i].xyz;
            float age = u.meteorC[i].w;
            bool train = age > 0.0;
            // The bound: within half the arc (plus the widest glow) of its middle. |S + E| = 2 cos(half the arc).
            float3 mid = S + E;
            float ml = length(mid);
            if (ml < 1e-4) continue;
            float ch = 0.5 * ml, sh = sqrt(max(1.0 - ch * ch, 0.0));
            float margin = train ? 0.04 : 10.0 * w;
            if (dot(d, mid) < ml * (ch * (1.0 - 0.5 * margin * margin) - sh * margin)) continue;
            // Across the path (radians off its great circle) and along it (0 at the start … 1 at the end).
            float3 pole = cross(S, E);
            float st = length(pole);
            if (st < 1e-6) continue;
            pole /= st;
            float arc = atan2(st, dot(S, E));
            float along = atan2(dot(d, cross(pole, S)), dot(d, S)) / arc;
            float across = dot(d, pole);
            float3 colour = u.meteorC[i].rgb;
            if (!train) {
                // The head: a hard point with a faint halo; the tail: the quarter of the path behind it, fading back.
                float p = u.meteorA[i].w;
                float peak = min(light * kRealStarGain, kMeteorPeak);
                float halo = 0.12 * clamp(light * kRealStarGain / kMeteorPeak, 1.0, 3.0);
                float ds = (along - p) * arc;
                float r2 = across * across + ds * ds;
                float rh = 1.3 * w;
                float head = exp(-r2 / (rh * rh)) + halo * exp(-r2 / (16.0 * rh * rh));
                float back = p - along;
                float tail = 0.0;
                if (back > 0.0 && back < 0.25 && along > 0.0) {
                    float f = 1.0 - back * 4.0;
                    tail = 0.55 * f * f * exp(-(across * across) / (w * w));
                }
                sum += colour * (peak * (head + tail));
            } else {
                if (along < 0.0 || along > 1.0) continue;
                float widen = 1.0 + 2.0 * age;
                float wt = max(1.5 * w, 0.002) * widen;  // a little softer than the streak (at least 0.11°), then 1 → 3×
                float reach = u.meteorA[i].w * 0.0174533 * age;
                float seed = dot(S, float3(37.1, 17.3, 23.9));
                float x = across - (vnoise3(float3(along * 3.0, seed, age * 0.7)) - 0.5) * 2.0 * reach;
                float taper = smoothstep(0.0, 0.12, along) * (1.0 - smoothstep(0.88, 1.0, along));
                float rise = smoothstep(0.0, 0.03, age);  // it forms as the head goes out
                float glow = kTrainPeak * (1.0 - exp(-light * kRealStarGain / kTrainPeak));
                sum += colour * (glow / widen * exp(-(x * x) / (wt * wt)) * taper * rise);
            }
        }
        // Mist dims them as it dims the stars (and thickest low down, as the sky's own mist band lies); a cloudy sky dims
        // them everywhere, as it does the stars (skyRadiance's clouds hide them where they are thick).
        float mist = u.weather.x;
        float through = (1.0 - 0.5 * mist) * (1.0 - 0.6 * mist * exp(-alt / 0.12)) * (1.0 - 0.95 * u.horizon.w);
        return sum * (through * smoothstep(0.0, 0.035, alt));
    }

    // ---------------------------------------------------------------- Fire & Neon: red sprites, far storms, satellites
    /// A sprite's crown at its brightest (HDR per unit of its brightness, ≤ 0.04): a faint red glow, never a flash.
    constant float kSpriteGain = 7.0;
    /// A satellite's point at most (HDR): a flare at Venus's brightness stays a hard point under the bloom.
    constant float kSatPeak = 40.0;
    constant float3 kSpriteRed = float3(1.0, 0.33, 0.22);
    constant float3 kSpriteBlue = float3(0.5, 0.36, 1.0);

    /// Degrees right of a bearing (unit east, north) along direction `d`, round the horizon.
    float degreesRightOf(float3 d, float2 b) {
        float2 h = d.xy;
        return toDeg(atan2(h.x * b.y - h.y * b.x, dot(h, b)));
    }

    /// One sprite column (spec §6.1) in its own units: `x` across and `v` up (0 at the tendrils' ends … 1 at its top),
    /// both in sprite heights. A diffuse crown two thirds of the way up, brighter and sharper on top; fine tendrils hanging
    /// under it, each ending at its own length, fanning in under a carrot and hanging straight and wide under a jellyfish,
    /// turning blue-violet low down; thin streamers reaching up from the crown now and then; a faint halo round it all.
    float3 spriteColumn(float x, float v, float shape, float streamers, float seed) {
        if (v < -0.08 || v > 1.35 || abs(x) > 0.7) return float3(0);
        float vc = mix(0.64, 0.7, shape);
        float wc = mix(0.09, 0.2, shape);
        float hc = mix(0.12, 0.085, shape);
        float dy = v - vc;
        float ky = dy > 0.0 ? dy / (hc * 0.75) : dy / (hc * 1.5);
        float crown = exp(-(x * x) / (wc * wc) - ky * ky);
        float halo = 0.1 * exp(-(x * x) / (6.0 * wc * wc) - (dy * dy) / 0.12);
        float3 col = kSpriteRed * (crown + halo);
        // Tendrils under the crown.
        if (v < vc + 0.04) {
            float below = saturate((vc - v) / vc);                       // 0 at the crown … 1 at the bottom
            float width = wc * mix(1.0 - 0.55 * below, 0.95 + 0.1 * below, shape);
            float s = x / max(width, 1e-3);
            float q = s * 3.4 + 0.12 * sin(v * 17.0 + seed * 40.0) + 7.0;
            float j = floor(q), f = fract(q) - 0.5;
            float jit = (hash13(float3(j, seed * 53.0, 1.3)) - 0.5) * 0.5;
            float strand = exp(-((f - jit) * (f - jit)) / 0.012);
            float tip = 0.04 + 0.42 * hash13(float3(j, seed * 53.0, 7.9));      // where it ends, from the bottom
            float reach = smoothstep(tip - 0.03, tip + 0.14, v);
            float under = smoothstep(vc + 0.04, vc - 0.1, v);                 // they hang from the crown's underside
            float across = exp(-s * s * 0.9);
            float t = strand * reach * under * across * (0.35 + 0.4 * (1.0 - below));
            float3 tint = mix(kSpriteRed, kSpriteBlue, smoothstep(0.42, 0.08, v));
            col += tint * t;
        }
        // Streamers up from the crown's top, now and then (fainter, narrower).
        if (streamers > 0.0 && v > vc) {
            float up = saturate((v - vc) / (1.25 - vc));
            float s = x / (wc * (0.7 - 0.3 * up));
            float q = s * 2.6 + 0.1 * sin(v * 23.0 + seed * 17.0) + 3.0;
            float f = fract(q) - 0.5;
            float strand = exp(-(f * f) / 0.01) * exp(-s * s * 0.8);
            col += kSpriteRed * (0.35 * streamers * strand * (1.0 - up) * smoothstep(vc, vc + 0.08, v));
        }
        return col;
    }

    /// The red sprites in the sky along `d` (spec §6.1): each slot a cluster of 1–3 columns of differing sizes, as faint
    /// as the sky's luminance allows (≤ 0.04), dimmed by mist and low haze like the stars.
    float3 redSprites(float3 d, float alt, constant SkyU& u) {
        float3 sum = float3(0);
        float y = toDeg(alt);
        float az = toDeg(atan2(d.x, d.y));
        for (int i = 0; i < 3; i++) {
            float4 A = u.spriteA[i];
            if (A.w <= 0.0) continue;
            float H = max(A.z, 0.5);
            float v = (y - A.y) / H;
            if (v < -0.2 || v > 1.5) continue;
            float dx = az - A.x;
            dx -= 360.0 * floor((dx + 180.0) / 360.0);
            float x = dx * cos(alt);
            float4 B = u.spriteB[i];
            int columns = clamp(int(B.x), 1, 3);
            float streamers = fract(B.x) / 0.9, spread = B.y, shape = B.z, seed = B.w;
            if (abs(x) > 0.5 * spread * float(columns - 1) + 0.8 * H) continue;
            float3 c = float3(0);
            for (int k = 0; k < 3; k++) {
                if (k >= columns) break;
                float hk = hash13(float3(seed * 91.0, float(k), 3.7));
                float offset = (float(k) - 0.5 * float(columns - 1)) * spread + (hk - 0.5) * 0.3 * spread;
                float scale = k == 0 ? 1.0 : 0.65 + 0.35 * hash13(float3(seed * 37.0, float(k), 9.1));
                float lift = (1.0 - scale) * 0.35;                         // the smaller ones stand a little higher
                c += spriteColumn((x - offset) / (H * scale), (v - lift) / scale, shape, streamers, seed + 0.37 * float(k))
                     * (k == 0 ? 1.0 : 0.6 + 0.4 * scale);
            }
            sum += c * (A.w * kSpriteGain);
        }
        float mist = u.weather.x;
        return sum * (1.0 - 0.5 * mist) * (1.0 - 0.6 * mist * exp(-alt / 0.12)) * smoothstep(0.0, 0.03, alt);
    }

    /// A far storm on the horizon (spec §6.1), over `col`: a dark anvil beyond the horizon, its tower and an overshooting
    /// top on its upwind side, the anvil spreading downwind and thinning, its lower part lost in the horizon's haze; its
    /// edges billowed. Lightning inside it lights the cloud from within (a bright core where it strikes and a wider glow
    /// through the cloud, tinted warm by the long air path) and the sky just over it.
    float3 farStorm(float3 d, float alt, float3 col, constant SkyU& u, float time) {
        float amount = u.storm.z;
        if (amount <= 0.001) return col;
        float W = 0.5 * max(u.stormFlicker.w, 4.0);
        float T = max(u.storm.w, 0.6);
        float x = degreesRightOf(d, u.storm.xy) / W;      // −1…1 across it
        float y = toDeg(alt) / T;                          // 0 at the horizon … 1 at the anvil's top
        if (abs(x) > 1.35 || y > 2.2 || y < -0.05) return col;
        // The shape: the tower at xt (left of middle), the anvil from x −0.8 to 1, its top easing down downwind, its base
        // rising; an overshooting dome over the tower; flanking towers stepping down on the left.
        float xt = -0.32;
        float edge = (vnoise3(float3(x * 7.0, y * 3.0, 5.1)) - 0.5) * 0.16 + (vnoise3(float3(x * 19.0, y * 8.0, 2.3)) - 0.5) * 0.06;
        float top = 1.0 - 0.14 * max(0.0, x - xt) + 0.24 * exp(-((x - xt) * (x - xt)) / 0.012);
        float bottom = 0.55 + 0.3 * smoothstep(xt, 1.0, x);
        float ends = min(x + 0.82, 1.0 - x) * W / T;
        float anvil = min(min(top + edge - y, y - bottom - edge * 0.6), ends * 0.12 + edge);
        float tw = 0.13 + 0.06 * y;
        float tower = min(tw - abs(x - xt) + edge * 0.7, top + edge - y);
        float f1 = 0.5 - y + edge - 3.0 * (x - xt + 0.3) * (x - xt + 0.3);
        float f2 = 0.33 - y + edge - 4.0 * (x - xt + 0.52) * (x - xt + 0.52);
        float shape = max(max(anvil, tower), max(f1, f2));
        float a = smoothstep(-0.02, 0.06, shape) * amount;
        if (a <= 0.0005) {
            // Only the air over it, glowing with its flash.
            float lv = u.stormFlicker.x;
            if (lv > 0.0 && y > 0.0) {
                float fx = x - u.stormFlicker.y / W;
                col += float3(1.0, 0.78, 0.62) * (0.05 * lv * amount * exp(-fx * fx / 0.2) * exp(-max(y - top, 0.0) / 0.6));
            }
            return col;
        }
        // Lost in the horizon's haze low down; dark against the sky above it.
        float haze = smoothstep(0.0, 0.5, y);
        float3 cloud = col * mix(0.82, 0.42, haze) + float3(0.002, 0.0022, 0.003);
        // Lightning inside: a bright core where it strikes and a glow through the cloud (the thicker, the more it spreads).
        float lv = u.stormFlicker.x;
        if (lv > 0.0) {
            float fx = x - u.stormFlicker.y / W, fy = y - u.stormFlicker.z;
            float core = exp(-(fx * fx) / 0.02 - (fy * fy) / 0.08);
            float wide = exp(-(fx * fx) / 0.25 - (fy * fy) / 0.6);
            float depth = smoothstep(-0.02, 0.2, shape);
            float3 light = float3(1.0, 0.8, 0.66) * (0.9 * core * depth + 0.22 * wide);
            cloud += light * (lv * (0.4 + 0.6 * haze));
        }
        return mix(col, cloud, a);
    }

    /// The satellites along `d` (spec §6.2), among the real stars and drawn as they are: a Gaussian footprint the size of
    /// a star of the same magnitude in the star texture, its light on the stars' scale, twinkling with them; a bright
    /// flare grows a faint halo instead of a bigger disc. A train is a line of evenly spaced points along its track,
    /// its members past the shadow's edge unlit. Sunlight through the atmosphere's limb reddens one at the shadow's edge.
    float3 satelliteLight(float3 d, float3 v, float time, constant SkyU& u) {
        float3 sum = float3(0);
        for (int i = 0; i < 4; i++) {
            float light = u.satA[i].w;
            if (light <= 0.0) continue;
            float3 D = u.satA[i].xyz;
            float3 Tv = u.satB[i].xyz;
            float count = max(u.satB[i].w, 1.0);
            float spacing = length(Tv);
            float R = max(u.satC[i].z, 1e-4);
            float c = dot(d, D);
            float reach = 6.0 * R + spacing * (count - 1.0);
            if (c < 1.0 - 0.5 * reach * reach - 1e-6) continue;
            float r2, lit = 1.0;
            if (count > 1.5 && spacing > 1e-7) {
                float3 Tn = Tv / spacing;
                float along = atan2(dot(d, Tn), c);
                float across = dot(d, cross(D, Tn));
                float k = clamp(floor(-along / spacing + 0.5), 0.0, count - 1.0);
                float da = along + k * spacing;
                r2 = da * da + across * across;
                float edge = u.satC[i].x;
                if (edge >= 0.0) {
                    float behind = smoothstep(edge - 0.5, edge + 0.5, k);
                    lit = u.satC[i].y > 0.0 ? behind : 1.0 - behind;
                }
            } else {
                float3 off = d - D * c;
                r2 = dot(off, off);
            }
            float peak = min(light * kRealStarGain, kSatPeak);
            float halo = 0.05 * (clamp(light * kRealStarGain / kMeteorPeak, 1.0, 3.0) - 1.0);
            float3 colour = mix(float3(1.0, 0.97, 0.92), float3(1.0, 0.55, 0.32), u.satC[i].w);
            sum += colour * (peak * lit) * (exp(-2.0 * r2 / (R * R)) + halo * exp(-r2 / (16.0 * R * R)));
        }
        return sum * (0.8 + 0.2 * vnoise3(v * 80.0 + float3(0.0, 0.0, time * 3.0)));
    }

    /// The sky's light in direction `d` (alt ≥ 0): gradient, sunset band, stars, Milky Way, aurora, moon, pillars,
    /// clouds, sun. `moonMask` returns how much of the moon disc covers the ray. Shared by the dome and by reflections.
    /// `stars` is the real star texture (fragment texture 0; a 1×1 placeholder while it builds, with u.eq0.w = 0).
    float3 skyRadiance(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars) {
        float alt = asin(clamp(d.z, -1.0, 1.0));
        int octaves = int(u.weather.z + 0.5);
        float rainbow = (u.weather.z - float(octaves)) / 0.45;   // the fraction carries the rainbow
        float time = u.forward.w, mist = u.weather.x, cloudCover = u.horizon.w, starVis = u.zenith.w;
        float3 S = u.sun.xyz, M = u.moon.xyz;
        float sunAlt = u.sun.w;
        // A narrow horizon band under a clean zenith colour (mixing them over the whole height turns them grey).
        float band = exp(-max(alt, 0.0) / (0.2 + 0.25 * mist));
        float3 col = mix(u.zenith.rgb, u.horizon.rgb, band);
        col = mix(col, u.horizon.rgb * 1.05, mist * 0.6 * exp(-max(alt, 0.0) / 0.12));

        // Sunset band and sun glow.
        float sunDot = dot(d, S), sunAngle = acos(clamp(sunDot, -1.0, 1.0));
        float low = saturate(1.0 - abs(sunAlt) / 15.0);
        col += float3(0.9, 0.42, 0.14) * low * 0.55 * exp(-sunAngle / 0.45) * exp(-max(alt, 0.0) / 0.25);
        if (sunAlt > -2.0) {
            col += float3(1.0, 0.85, 0.65) * 0.45 * exp(-sunAngle / 0.08) * saturate((sunAlt + 2.0) / 4.0);
        }

        // Stars and the Milky Way, turned by sidereal time and latitude.
        float3x3 eq = float3x3(u.eq0.xyz, u.eq1.xyz, u.eq2.xyz);
        float3 v = eq * d;
        float above = smoothstep(0.0, 0.17, alt);
        if (starVis > 0.001 && alt > 0.0) {
            float3 procedural = starField(v, u.weather.w, time, starVis, u.eq0.w > 0.5 ? 0.7 : 2.0);
            float3 catalogue = float3(0);
            if (u.eq0.w > 0.5) {
                // The real stars lead: they replace the procedural field's brightest 30% (left out above), and the rest
                // stays as the faint background.
                catalogue = realStars(v, stars, time, saturate(u.night.z), starVis);
                procedural *= 0.45;
            }
            col += (procedural + catalogue + milkyWay(v, octaves, starVis)) * above;
            // Satellites (Fire & Neon §6.2): steady points among the stars, as dim as they are dimmed.
            if (u.satA[0].w > 0.0 || u.satA[1].w > 0.0 || u.satA[2].w > 0.0 || u.satA[3].w > 0.0) {
                col += satelliteLight(d, v, time, u) * (starVis * above);
            }
        }

        // The aurora, pole-ward, in front of the stars (clouds hide it below).
        if (u.night.x > 0.001 && alt > 0.0) {
            col += auroraLight(d, u, time, octaves) * above;
        }

        // Shooting stars (spec §6.3): over the stars and the aurora, under the moon and the clouds (which hide them).
        float3 meteors = alt > 0.0 ? meteorLight(d, alt, u) : float3(0);
        col += meteors;
        // Red sprites (Fire & Neon §6.1): 50–90 km up, over the far storm; any cloud here hides them.
        if (alt > 0.0 && (u.spriteA[0].w > 0.0 || u.spriteA[1].w > 0.0 || u.spriteA[2].w > 0.0)) {
            col += redSprites(d, alt, u);
        }

        // Moon: a lit sphere with its phase terminator toward the sun, plus earthshine.
        float moonR = u.moonInfo.z;
        float mDot = dot(d, M);
        float3 o3 = (d - M * mDot) / moonR;
        float r2 = dot(o3, o3);
        moonMask = 0.0;
        if (mDot > 0.0 && r2 < 1.0 && M.z > -0.05) {
            float3 n = o3 - M * sqrt(1.0 - r2);
            float3 toSun = S - M * dot(S, M);
            float ts = length(toSun);
            float3 tdir = ts > 1e-5 ? toSun / ts : u.up.xyz;
            float E = 6.2831853 * u.moon.w;
            float3 L = M * cos(E) + tdir * sin(E);
            float lit = smoothstep(-0.03, 0.06, dot(n, L));
            float maria = 0.78 + 0.22 * fbm3(o3 * 3.0 + 11.0, 2);
            float limb = 0.75 + 0.25 * sqrt(1.0 - r2);
            float edge = smoothstep(1.0, 0.92, r2);
            float3 moonCol = float3(1.0, 0.97, 0.9) * 1.6 * maria * limb * (lit + u.moonInfo.y);
            moonMask = edge;
            col = mix(col, moonCol + col * 0.3 * (1.0 - lit), edge);
        }
        if (M.z > -0.05) {
            float moonAngle = acos(clamp(mDot, -1.0, 1.0));
            float haze = 0.10 * exp(-moonAngle / 0.05) + (0.025 + 0.05 * mist) * exp(-moonAngle / 0.3);
            col += float3(0.7, 0.78, 0.95) * u.moonInfo.x * haze * (1.0 - moonMask) * saturate(M.z * 4.0 + 0.2);
        }

        // Ice halos: the 22° ring (and the faint 46° one in heavy ice) with sundogs around the sun; paler, near
        // colourless ones around a bright moon. A fraction of the sky's own brightness, so nothing flashes.
        float halo = u.extra.x;
        if (halo > 0.001 && alt > 0.0) {
            float skyLum = dot(col, float3(0.2126, 0.7152, 0.0722));
            if (sunAlt > -1.0) {
                float ang = toDeg(sunAngle);
                float3 h = haloRing(ang, 22.0) * 0.12 + haloRing(ang, 46.0) * 0.05 * saturate((halo - 0.7) / 0.3);
                h += sundogs(d, S, sunAlt) * 0.8;
                col += h * halo * saturate((sunAlt + 1.0) / 3.0) * (0.25 + skyLum);
            }
            if (M.z > 0.0 && u.moonInfo.x > 0.6) {
                float moonAlt = toDeg(asin(clamp(M.z, -1.0, 1.0)));
                float ang = toDeg(acos(clamp(mDot, -1.0, 1.0)));
                float3 h = haloRing(ang, 22.0) * 0.10 + sundogs(d, M, moonAlt) * 0.35;
                float l = dot(h, float3(0.2126, 0.7152, 0.0722));
                col += mix(float3(l), h, 0.25) * float3(0.85, 0.9, 1.0) * halo * smoothstep(0.6, 0.9, u.moonInfo.x) * (0.3 + skyLum);
            }
        }

        // Light pillars in diamond dust: over and under a low sun (−2°…12°), and a bright moon (lit > 0.3).
        float pillar = u.dust.y;
        if (pillar > 0.001) {
            float sunW = smoothstep(-2.0, -1.0, sunAlt) * (1.0 - smoothstep(11.0, 12.0, sunAlt));
            if (sunW > 0.0) {
                float3 sunCol = mix(float3(9.0, 4.5, 2.0), float3(14.0, 12.5, 10.5), saturate(sunAlt / 12.0));
                col += sunCol * (kPillarGain * pillar * sunW) * lightPillar(d, alt, S, u.moonInfo.w) * (1.0 - moonMask);
            }
            float moonW = smoothstep(0.3, 0.4, u.moonInfo.x) * saturate(M.z * 10.0 + 0.5);
            if (moonW > 0.0) {
                float3 moonCol = float3(1.0, 0.97, 0.9) * 1.6 * u.moonInfo.x;
                col += moonCol * (0.35 * pillar * moonW) * lightPillar(d, alt, M, u.moonInfo.z) * (1.0 - moonMask);
            }
        }

        // The Belt of Venus: at twilight, a pink band 5–20° up opposite the sun over the blue-grey of Earth's shadow.
        float belt = beltOfVenus(sunAlt);
        if (belt > 0.0 && alt > 0.0) {
            float2 hs = S.xy / max(length(S.xy), 1e-4), hd = d.xy / max(length(d.xy), 1e-4);
            float away = saturate(-dot(hs, hd));
            away *= away;
            float altDeg = toDeg(alt);
            float band = smoothstep(4.0, 7.0, altDeg) * (1.0 - smoothstep(16.0, 22.0, altDeg));
            col += float3(1.0, 0.62, 0.70) * 0.12 * belt * (1.0 + u.extra.y) * band * away;
            float shadow = (1.0 - smoothstep(2.0, 5.0, altDeg)) * away * belt;
            float l = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(col, l * float3(0.8, 0.86, 1.02), 0.6 * shadow) * (1.0 - 0.25 * shadow);
        }

        // A far storm on the horizon (Fire & Neon §6.1), in front of the stars and the moon, behind any cloud here.
        if (u.storm.z > 0.001 && alt > -0.01) col = farStorm(d, alt, col, u, time);

        // Clouds: a drifting layer lit by the sun or the moon.
        if (cloudCover > 0.01 && alt > 0.0) {
            float2 drift = float2(time * 0.004 * (0.3 + u.weather.y), time * 0.0015);
            float2 uv = d.xy / (d.z + 0.12) * 0.55 + drift;
            float n1;
            float n = fbm3c(float3(uv * 2.2, time * 0.003), octaves, n1);
            // Calibrated so light cloud leaves most of the sky clear and overcast closes it.
            float threshold = 0.85 - 0.6 * cloudCover;
            float density = smoothstep(threshold, threshold + 0.12 + 0.1 * cloudCover, n) * smoothstep(0.0, 0.08, alt);
            bool day = sunAlt > -6.0;
            float3 L = day ? S : M;
            float lightAmt = day ? saturate((sunAlt + 6.0) / 12.0) : u.moonInfo.x * 0.35;
            float facing = pow(saturate(dot(d, L)), 6.0);
            float baseLum = dot(mix(u.zenith.rgb, u.horizon.rgb, 0.4), float3(0.2126, 0.7152, 0.0722));
            float3 base = mix(mix(u.zenith.rgb * 0.7 + 0.02, u.horizon.rgb * 0.9, 0.4), baseLum * float3(0.92, 0.97, 1.06), 0.5);
            float3 lightCol = day ? mix(float3(1.0, 0.62, 0.38), float3(1.0, 0.98, 0.95), saturate(sunAlt / 20.0)) : float3(0.55, 0.62, 0.8);
            // Pastel dawns light the cloud undersides pink.
            float pastel = u.extra.y * smoothstep(-10.0, -6.0, sunAlt) * (1.0 - smoothstep(4.0, 8.0, sunAlt));
            lightCol = mix(lightCol, float3(1.0, 0.68, 0.78), 0.7 * pastel);
            float3 cloud = base * (0.55 + 0.45 * lightAmt) + lightCol * lightAmt * (0.25 + 0.9 * facing) * (1.0 - 0.6 * density);
            float cover = density;
            if (u.still.x > 0.0 && day) {
                // The first octave's level where the cloud begins (its weight in the sum is 0.5 / (1 − 0.5^octaves);
                // the finer octaves average a half each).
                float w1 = octaves > 2 ? 0.5714286 : 0.6666667;
                // Just outside the cloud (with a little clear air between, as over a real cap).
                float near = smoothstep(threshold - 0.14, threshold - 0.06, n) * (1.0 - smoothstep(threshold - 0.04, threshold, n));
                float veil;
                cloud = iridescentCloud(cloud, d, toDeg(sunAngle), density, n1, (threshold - 0.5 * (1.0 - w1)) / w1, near,
                                        drift, time, u, veil);
                cover = max(density, veil * smoothstep(0.0, 0.08, alt));
            }
            col = mix(col, cloud, cover * (1.0 - moonMask * 0.0));
            // Shooting stars burn 80–100 km up, far above any cloud: thin cloud hides them too ((1 − cover)⁴ comes
            // through, not the 1 − cover the mix left).
            float clear = 1.0 - cover;
            col = max(col - meteors * ((1.0 - moonMask) * clear * (1.0 - clear * clear * clear)), float3(0.0));
        }

        // Rainbows: the primary bow 42° and the secondary 51° from the point opposite the sun, a little light
        // added to the sky (and dimmed where cloud is thick), so nothing flashes.
        if (rainbow > 0.002 && sunAlt > 0.0) {
            float anti = toDeg(acos(clamp(dot(d, -S), -1.0, 1.0)));
            float3 bow = rainbowBow(anti);
            float inside = anti < 41.5 ? 0.05 * smoothstep(20.0, 41.5, anti) : 0.0;   // the sky inside the bow is a touch brighter
            col += (bow * 0.30 + float3(inside)) * rainbow * (1.0 - 0.5 * cloudCover);
        }

        // Sun disc last (clouds can hide it softly).
        if (sunAlt > -1.0) {
            float sunR = u.moonInfo.w;
            float disc = smoothstep(sunR, sunR * 0.85, sunAngle);
            float3 sunCol = mix(float3(9.0, 4.5, 2.0), float3(14.0, 12.5, 10.5), saturate(sunAlt / 12.0));
            col = mix(col, sunCol, disc * (1.0 - 0.85 * saturate(cloudCover - 0.4)));
        }

        // A fireball's soft brightening of the whole sky (meteorFlash, already through the sky's flash limiter).
        return col * (1.0 + u.flash.x);
    }

    // ---------------------------------------------------------------- rime frost on silhouettes (spec §6.4)
    // Freezing fog feathers the windward edge of everything it touches. A world calls these where it knows how far a
    // pixel lies inside one of its silhouettes:
    //   inside   NDC-y units (screen x × aspect, y) from the silhouette's edge, > 0 inside it (≤ 0: no rime)
    //   outward  the edge's outward normal on screen (x right, y up; any length; zero rimes every side alike)
    //   p        a point fixed to the silhouette in NDC-y units, for the feathers (so they never swim)
    // The fringe reaches 0.6% of the view's height (0.012 NDC) × the sky's rime (u.still.y) on the side facing into
    // the wind (u.still.zw, the way it blows on screen), a third as far on the lee, ruffled by two octaves of noise.

    /// Whether a pixel this far inside a silhouette can carry rime now (the fringe's widest reach): test it before
    /// paying for the feathers.
    bool rimeNear(constant SkyU& u, float inside) {
        return u.still.y > 0.0 && inside > 0.0 && inside < 0.0156 * saturate(u.still.y);
    }

    /// The fringe's cover 0…1, given its feather noise 0…1 (for worlds whose silhouettes need their own, periodic
    /// noise; rimeEdge takes it at a point).
    float rimeFringe(constant SkyU& u, float inside, float2 outward, float feather) {
        float rime = saturate(u.still.y);
        if (rime <= 0.0 || inside <= 0.0) return 0.0;
        float2 w = u.still.zw;
        float wl = length(w), nl = length(outward);
        float facing = (wl > 1e-4 && nl > 1e-6) ? -dot(outward, w) / (nl * wl) : 0.0;   // 1 into the wind … −1 the lee
        float f = saturate(feather);
        float width = 0.012 * rime * (0.6 + 0.4 * facing) * (0.3 + 0.95 * f);
        if (inside >= width) return 0.0;
        // Thickest at the edge and thinning into the silhouette, in tufts with gaps between them where the noise is
        // low: feathers of ice rather than an outline.
        float t = inside / max(width, 1e-6);
        return (1.0 - t) * (1.0 - t) * smoothstep(0.2, 0.6, f) * (0.55 + 0.35 * rime);
    }

    /// For a silhouette made of overlapping shapes (a trunk's segments, fronds, a knot): offer each shape's `inside`
    /// and its outward direction `away`; the deepest is kept, so the fringe follows the outline of their union.
    /// Start with deepest = −1.
    void rimeKeepDeepest(float inside, float2 away, thread float& deepest, thread float2& outward) {
        if (inside > deepest) { deepest = inside; outward = away; }
    }

    /// Two octaves of feather noise at `p` (NDC-y units): about three feathers to a full fringe's width.
    float rimeFeather(float2 p) {
        return fbm3(float3(p * 90.0, 2.7), 2);
    }

    /// The rime fringe's cover 0…1 at a silhouette pixel (see above).
    float rimeEdge(constant SkyU& u, float inside, float2 outward, float2 p) {
        if (!rimeNear(u, inside)) return 0.0;
        return rimeFringe(u, inside, outward, rimeFeather(p));
    }

    /// Rime's light: the sky's horizon colour × 1.3 (white by day, blue-grey at night).
    float3 rimeColor(constant SkyU& u) {
        return u.horizon.rgb * 1.3;
    }

    /// A silhouette's colour with its rime fringe (exactly `col` where there is none).
    float3 rimed(float3 col, constant SkyU& u, float inside, float2 outward, float2 p) {
        float r = rimeEdge(u, inside, outward, p);
        return r > 0.0 ? mix(col, rimeColor(u), r) : col;
    }

    """

    static let source = common + """
    struct SkyOut { float4 pos [[position]]; float2 ndc; };

    vertex SkyOut sky_dome_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    fragment ColorDepth sky_dome_fragment(SkyOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                          texture2d<float> stars [[texture(0)]]) {
        float3 d = normalize(u.forward.xyz + u.right.xyz * in.ndc.x * u.right.w + u.up.xyz * in.ndc.y * u.up.w);
        float moonMask = 0.0;
        float3 col = d.z < 0.0 ? u.horizon.rgb * 0.6 : skyRadiance(d, u, moonMask, stars);
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- weather
    // instance: pos.xy (NDC), size.x (length or radius), size.y (alpha); kind: 0 rain streak, 1 snow, 2 bead on glass,
    // 3 a ground streamer (blowing snow), 4 a firefly (radius of its soft glow), 5 a diamond-dust crystal, 6 one blob of a
    // sea-smoke wisp (its radius), 7 sea smoke's thin flat mist over the water's far edge (its half width in NDC x)
    struct Particle { float4 posSize; };
    // params: x aspect, y kind, z tilt (dx per dy; kind 7: the mist's half height), w brightness. Sea smoke's light (kinds 6
    // and 7; zero for the rest): tint rgb, the sun's screen x (NDC); glow rgb (the low sun's ahead, else 0), its width.
    struct WeatherU { float4 params; float4 tint; float4 glow; };
    struct WeatherOut { float4 pos [[position]]; float2 uv; float alpha; float kind; float2 ndc; };

    vertex WeatherOut weather_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                     constant Particle* ps [[buffer(0)]], constant WeatherU& u [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float4 p = ps[iid].posSize;
        float2 q = c[vid];
        float kind = u.params.y;
        float2 offset;
        if (kind < 0.5) {
            float len = p.z, w = 0.0016;
            float2 dir = normalize(float2(u.params.z, -1.0));
            float2 side = float2(-dir.y, dir.x);
            offset = dir * q.y * len * 0.5 + side * q.x * w;
            offset.x /= u.params.x;
        } else if (kind > 2.5 && kind < 3.5) {
            offset = float2(q.x * p.z * 0.5, q.y * 0.0035);
        } else if (kind > 6.5) {         // sea smoke's flat mist: as wide as the water, a thin band high
            offset = float2(q.x * p.z, q.y * u.params.z);
        } else {
            offset = q * p.z;
            offset.x /= u.params.x;
        }
        WeatherOut o;
        o.pos = float4(p.xy + offset, 0, 1);
        o.uv = q;
        o.alpha = p.w;
        o.kind = kind;
        o.ndc = p.xy + offset;
        return o;
    }

    fragment float4 weather_fragment(WeatherOut in [[stage_in]], constant WeatherU& u [[buffer(0)]]) {
        float3 col;
        float a;
        if (in.kind < 0.5) {             // rain: a thin soft streak
            a = (1.0 - in.uv.x * in.uv.x) * smoothstep(1.0, 0.2, abs(in.uv.y)) * in.alpha;
            col = float3(0.72, 0.78, 0.9);
        } else if (in.kind < 1.5) {      // snow: a soft flake
            float r = length(in.uv);
            a = smoothstep(1.0, 0.3, r) * in.alpha;
            col = float3(0.95, 0.97, 1.0);
        } else if (in.kind > 5.5) {      // sea smoke: a wisp's soft blob (6), or the thin flat mist over the far water (7)
            if (in.kind > 6.5) {
                float v = 1.0 - in.uv.y * in.uv.y;
                a = v * v * (1.0 - smoothstep(0.85, 1.0, abs(in.uv.x))) * in.alpha;
            } else {
                float r2 = dot(in.uv, in.uv);
                a = exp(-r2 * 2.6) * (1.0 - smoothstep(0.7, 1.0, sqrt(r2))) * in.alpha;
            }
            // The horizon's light (moonlit blue-grey at night), and the low sun's glow when it is ahead.
            float gx = (in.ndc.x - u.tint.w) / max(u.glow.w, 1e-3);
            col = u.tint.rgb + u.glow.rgb * exp(-gx * gx);
        } else if (in.kind > 4.5) {      // a diamond-dust crystal: a hard glint with a faint cross
            float r2 = dot(in.uv, in.uv);
            float spikes = exp(-in.uv.x * in.uv.x * 40.0) * exp(-in.uv.y * in.uv.y * 2.0)
                         + exp(-in.uv.y * in.uv.y * 40.0) * exp(-in.uv.x * in.uv.x * 2.0);
            a = saturate(exp(-r2 * 9.0) + 0.25 * spikes) * smoothstep(1.0, 0.8, sqrt(r2)) * in.alpha;
            col = float3(0.82, 0.9, 1.0);
        } else if (in.kind > 3.5) {      // a firefly: a warm core in a soft glow
            float r2 = dot(in.uv, in.uv);
            a = saturate(exp(-r2 * 16.0) + 0.35 * exp(-r2 * 4.0)) * smoothstep(1.0, 0.85, sqrt(r2)) * in.alpha;
            col = float3(1.0, 0.95, 0.45);
        } else if (in.kind > 2.5) {      // a ground streamer: a long thin wisp, thickest at its head
            float along = 0.5 + 0.5 * in.uv.x;
            a = (1.0 - in.uv.y * in.uv.y) * smoothstep(0.0, 0.35, along) * smoothstep(1.0, 0.75, along) * in.alpha;
            col = float3(0.92, 0.95, 1.0);
        } else {                          // a drop on glass: bright rim, darker lens
            float r = length(in.uv * float2(1.0, 0.85));
            float rim = smoothstep(1.0, 0.82, r) - smoothstep(0.82, 0.55, r) * 0.6;
            float glint = exp(-dot(in.uv - float2(-0.35, 0.4), in.uv - float2(-0.35, 0.4)) * 30.0);
            a = saturate(rim + glint) * in.alpha;
            col = float3(0.8, 0.86, 0.95) + glint;
        }
        return float4(col * u.params.w * a, a);
    }

    // Splash rings on water: pos.xy, radius, alpha.
    struct RingOut { float4 pos [[position]]; float2 uv; float alpha; };
    vertex RingOut ring_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Particle* rs [[buffer(0)]], constant WeatherU& u [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float4 r = rs[iid].posSize;
        RingOut o;
        o.uv = c[vid];
        o.pos = float4(r.xy + c[vid] * float2(r.z / u.params.x, r.z * 0.3), 0, 1);
        o.alpha = r.w;
        return o;
    }

    fragment float4 ring_fragment(RingOut in [[stage_in]], constant WeatherU& u [[buffer(0)]]) {
        float r = length(in.uv);
        float q = (r - 0.85) / 0.08;
        float ring = exp(-q * q);
        float a = ring * in.alpha;
        return float4(float3(0.75, 0.8, 0.9) * u.params.w * a, a);
    }
    """
}
