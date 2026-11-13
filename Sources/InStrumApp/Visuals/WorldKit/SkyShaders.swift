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

    // ---------------------------------------------------------------- the storm program
    // Fire & Neon's storm weathers (the far storm and its sprites, the supercell, the ash) are compiled into a sky only
    // where its pipeline is specialised for them (`SkySpecialisation`): a plain sky's program carries none of their code
    // (inlined into every sky, its registers slowed them all). A function made without the constant keeps them.
    constant bool kSkyStormsSet [[function_constant(20)]];
    constant bool kSkyStorms = is_function_constant_defined(kSkyStormsSet) ? kSkyStormsSet : true;
    // The supercell weather alone has a program of its own (it reads its impostor; none of the far storm, the sprites or
    // the ash is compiled in): its constant, set with the storms' by `skyFunction(_:program:)`, else the storms'.
    constant bool kSkyCellSet [[function_constant(21)]];
    constant bool kSkyCell = is_function_constant_defined(kSkyCellSet) ? kSkyCellSet
                           : (is_function_constant_defined(kSkyStormsSet) ? kSkyStormsSet : true);

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
    constant float kSpriteGain = 8.0;
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
    /// both in sprite heights. A diffuse crown high on the column, brighter and sharper on top; six fine tendrils hanging
    /// from its underside, each leaving it at its own place, wavering a little and ending at its own length, fainter as
    /// they go and turning blue-violet low down (they draw in under a carrot and spread under a jellyfish); now and then
    /// thin streamers reaching up from the crown; a faint halo round it all.
    float3 spriteColumn(float x, float v, float shape, float streamers, float seed) {
        if (v < -0.05 || v > 1.3 || abs(x) > 0.42) return float3(0);
        float vc = mix(0.76, 0.72, shape);
        float wc = mix(0.055, 0.12, shape);
        float hc = mix(0.13, 0.1, shape);
        float dy = v - vc;
        float ky = dy > 0.0 ? dy / (hc * 0.75) : dy / (hc * 1.35);
        float crown = exp(-(x * x) / (wc * wc) - ky * ky);
        float halo = 0.07 * exp(-(x * x) / (10.0 * wc * wc) - (dy * dy) / 0.09);
        float3 col = kSpriteRed * (crown + halo);
        if (v < vc + 0.02) {
            float below = saturate((vc - v) / vc);                          // 0 at the crown … 1 at the bottom
            float conv = mix(0.5, 1.2, shape);
            float3 tint = mix(kSpriteRed, kSpriteBlue, smoothstep(0.42, 0.06, v));
            float t = 0.0;
            for (int k = 0; k < 6; k++) {
                float h1 = hash13(float3(seed * 61.0, float(k), 1.7));
                float h2 = hash13(float3(seed * 61.0, float(k), 4.3));
                float h3 = hash13(float3(seed * 61.0, float(k), 8.9));
                float x0 = (h1 - 0.5) * 1.7 * wc;
                float xk = x0 * mix(1.0, conv, below) + 0.01 * sin(v * 23.0 + h2 * 31.0);
                float tip = 0.02 + 0.42 * h3;
                float w = 0.008 + 0.006 * h2;
                float strand = exp(-((x - xk) * (x - xk)) / (w * w));
                float along = smoothstep(tip, tip + 0.16, v) * smoothstep(vc + 0.02, vc - 0.1, v);
                t += strand * along * (0.4 + 0.6 * h2) * (0.25 + 0.75 * (1.0 - below));
            }
            col += tint * (0.75 * t);
        }
        if (streamers > 0.0 && v > vc) {
            float up = saturate((v - vc) / (1.25 - vc));
            float s2 = 0.0;
            for (int k = 0; k < 3; k++) {
                float h1 = hash13(float3(seed * 29.0, float(k), 2.1));
                float xk = (h1 - 0.5) * 1.2 * wc * (1.0 - 0.5 * up) + 0.008 * sin(v * 31.0 + h1 * 20.0);
                float w = 0.007;
                s2 += exp(-((x - xk) * (x - xk)) / (w * w)) * (1.0 - up) * smoothstep(vc, vc + 0.06, v);
            }
            col += kSpriteRed * (0.4 * streamers * s2);
        }
        return col;
    }

    /// The red sprites in the sky along `d` (spec §6.1): each slot a cluster of 1–3 columns of differing sizes, as faint
    /// as the sky's luminance allows (≤ 0.04), dimmed by mist and low haze like the stars.
    float3 redSprites(float3 d, float alt, constant SkyU& u) {
        float3 sum = float3(0);
        float y = toDeg(alt);
        float az = 1e9;
        for (int i = 0; i < 3; i++) {
            float4 A = u.spriteA[i];
            if (A.w <= 0.0) continue;
            float H = max(A.z, 0.5);
            float v = (y - A.y) / H;
            if (v < -0.2 || v > 1.5) continue;
            if (az > 1e8) az = toDeg(atan2(d.x, d.y));
            float dx = az - A.x;
            dx -= 360.0 * floor((dx + 180.0) / 360.0);
            float x = dx * cos(alt);
            float4 B = u.spriteB[i];
            int columns = clamp(int(B.x), 1, 3);
            float streamers = fract(B.x) / 0.9, spread = B.y, shape = B.z, seed = B.w;
            if (abs(x) > 0.5 * spread * float(columns - 1) + 0.5 * H) continue;
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

    /// A far storm on the horizon (spec §6.1), over `col`: a dark anvil beyond the horizon, a degree or three high and
    /// many times as wide. Its tower stands on the upwind side, billowed, with an overshooting dome over the anvil's flat
    /// top; the anvil spreads downwind, thinning, its underside rising and its end ragged; lower towers step down upwind;
    /// its foot is lost in the horizon's haze. Between flashes it is a soft dark shape against the horizon's glow. A flash
    /// inside lights it from within: a bright heart where it strikes, a wider glow through the cloud (catching its
    /// billows, warm from the long air path, reaching its edges, so it never draws an outline), and a little light
    /// escaping over its top.
    float3 farStorm(float3 d, float alt, float3 col, constant SkyU& u, float time) {
        float amount = u.storm.z;
        if (amount <= 0.001) return col;
        float T = max(u.storm.w, 0.6);
        float y = toDeg(alt) / T;                          // 0 at the horizon … 1 at the anvil's top
        if (y > 2.6 || y < -0.05) return col;              // most of the sky is far above it
        float W = 0.5 * max(u.stormFlicker.w, 4.0);
        float x = degreesRightOf(d, u.storm.xy) / W;      // −1…1 across it
        if (abs(x) > 1.4) return col;
        float xt = -0.3;
        float n1 = vnoise3(float3(x * 9.0, y * 4.0, 5.1));
        float n2 = vnoise3(float3(x * 23.0, y * 9.0, 2.3));
        float bil = (n1 - 0.5) * 0.12 + (n2 - 0.5) * 0.05;
        float dx = x - xt;
        float anvTop = 0.93 - 0.08 * max(0.0, dx) + 0.5 * bil;
        float anvBot = 0.5 + 0.22 * smoothstep(xt, 1.0, x) + bil;
        float anvEnd = 0.95 + 0.14 * (n1 - 0.5) - x;
        // Its upwind end is rounded and ragged, reaching back furthest at mid-height (no straight cut).
        float mid = y - 0.5 * (anvTop + anvBot);
        float anvStart = dx + 0.36 + 0.18 * (n2 - 0.5) - 1.6 * mid * mid;
        float anvil = min(min(anvTop - y, y - anvBot), 0.6 * min(anvEnd, anvStart));
        float dome = 0.16 * exp(-(dx * dx) / 0.006);
        float tower = min(0.11 + 0.04 * y + 0.5 * bil - abs(dx), 0.95 + dome + 0.7 * bil - y);
        float f1 = 0.6 + 1.6 * bil - y - 6.0 * (dx + 0.25) * (dx + 0.25);
        float f2 = 0.38 + 1.6 * bil - y - 8.0 * (dx + 0.44) * (dx + 0.44);
        float shape = max(max(anvil, tower), max(f1, f2));
        float a = smoothstep(-0.03, 0.09, shape) * amount;
        float haze = smoothstep(0.0, 0.55, y);
        float lv = u.stormFlicker.x;
        const float3 glowCol = float3(1.0, 0.8, 0.64);
        float3 outCol = col;
        if (a > 0.0005) {
            float3 cloud = col * mix(0.85, 0.45, haze) + float3(0.0015, 0.0016, 0.0022);
            if (lv > 0.0) {
                float fx = x - u.stormFlicker.y / W, fy = y - u.stormFlicker.z;
                float core = exp(-(fx * fx) / 0.025 - (fy * fy) / 0.12);
                float wide = exp(-(fx * fx) / 0.35 - (fy * fy) / 0.8);
                float tex = 0.55 + 0.8 * n1 * n2 + 0.3 * n2;
                float inner = smoothstep(-0.03, 0.25, shape);
                cloud += glowCol * (lv * (0.55 * core * (0.4 + 0.6 * inner) + 0.16 * wide) * tex * (0.45 + 0.55 * haze));
            }
            outCol = mix(col, cloud, a);
        }
        if (lv > 0.0) {
            float fx = x - u.stormFlicker.y / W;
            outCol += glowCol * (0.035 * lv * amount * exp(-fx * fx / 0.25) * exp(-max(y - 0.9, 0.0) / 0.5) * (1.0 - a));
        }
        return outCol;
    }

    /// The satellites along `d` (spec §6.2), among the real stars and drawn as they are: a Gaussian footprint the size of
    /// a star of the same magnitude in the star texture, its light on the stars' scale, twinkling with them; a bright
    /// flare stays a hard point (its glow is the bloom's, never a disc). A train is a line of evenly spaced points along
    /// its track, its members past the shadow's edge unlit. Sunlight through the atmosphere's limb reddens one at the
    /// shadow's edge.
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
            // As bright as a star of its magnitude up to Sirius; brighter ones (a station, a flare) climb gently above it,
            // so a flare at Venus's brightness is a hard point whose glow is the bloom's, never a disc.
            float peak = kRealStarGain * (light <= 1.0 ? light : 1.0 + 0.45 * log2(light));
            float3 colour = mix(float3(1.0, 0.97, 0.92), float3(1.0, 0.55, 0.32), u.satC[i].w);
            sum += colour * (min(peak, kSatPeak) * lit * exp(-2.0 * r2 / (R * R)));
        }
        if (sum.x + sum.y + sum.z <= 0.0) return sum;
        return sum * (0.8 + 0.2 * vnoise3(v * 80.0 + float3(0.0, 0.0, time * 3.0)));
    }

    // ---------------------------------------------------------------- Fire & Neon: ashfall (spec §7.1)
    /// The sun's light through the ash (the sky's own, `SkyState.sunTint`; a zero row, as a test sky has, is no ash).
    float3 ashSunTint(constant SkyU& u) {
        if (!kSkyStorms) return float3(1.0);
        float3 t = u.ash.yzw;
        return t.x + t.y + t.z > 0.0 ? t : float3(1.0);
    }
    /// The moon's (mirrors `WorldWeather.ashTint`: ash × (0.05, 0.085, 0.13) an airmass, Rozenberg's airmass).
    float3 ashMoonTint(constant SkyU& u, float moonZ) {
        float ash = kSkyStorms ? saturate(u.ash.x) : 0.0;
        if (ash <= 0.0) return float3(1.0);
        float hgt = max(moonZ, 0.0);
        float airmass = 1.0 / (hgt + 0.025 * exp(-11.0 * hgt));
        return exp(-float3(0.05, 0.085, 0.13) * (ash * airmass));
    }

    // ---------------------------------------------------------------- shared cloud shapes (Supercell Sky and the sky)
    // Supercell Sky's storm and the shared sky's supercell are drawn from the same shapes: the smooth sum of rounded
    // bumps (the tower's cauliflower, the mammatus pouches), the striations, the anvil melting up out of the tower, the
    // base's ragged rim and the inflow bands. The world reads them on its 3D shapes; the sky on its planes and sheets,
    // with fewer bumps and less detail at a distance.
    float skyHash12(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    float2 skyHash22(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }
    float skyNoise2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = skyHash12(i), b = skyHash12(i + float2(1, 0));
        float c = skyHash12(i + float2(0, 1)), e = skyHash12(i + float2(1, 1));
        return mix(mix(a, b, w.x), mix(c, e, w.x), w.y);
    }
    /// Up to three octaves of skyNoise2, normalised.
    float skyFbm2(float2 p, int octaves) {
        float s = 0.0, a = 0.5, n = 0.0;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            s += a * skyNoise2(p);
            n += a;
            p = p * 2.03 + float2(17.1, 9.2);
            a *= 0.5;
        }
        return s / n;
    }

    /// Cauliflower and pouches: a smooth sum of rounded bumps over a jittered grid at `g` (3×3 cells: each cell one
    /// bump, its centre 0.15–0.85 across it from `seedV`, its size s0 … s0 + sA cells from `seedS`, its sharpness
    /// kNum / size²), and its slope (per cell) in `grad`. The slope comes from the sum, so the light rolls round every
    /// bump and the folds between them shade softly (the nearest-bump switch drew hard creases). `period` wraps the
    /// grid's x every so many cells (round a tower, so there is no seam as it turns; 0: no wrap).
    float cloudBumps(float2 g, float period, float2 seedV, float2 seedS, float s0, float sA, float kNum,
                     thread float2& grad) {
        float2 gi = floor(g), gf = fract(g);
        float H = 0.0;
        grad = float2(0);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 cell = float2(float(x), float(y));
                float2 id = gi + cell;
                if (period > 0.0) id.x -= period * floor(id.x / period);
                float2 v = gf - (cell + 0.15 + 0.7 * skyHash22(id + seedV));
                float s = s0 + sA * skyHash12(id + seedS);
                float kk = kNum / (s * s);
                float e = exp(-dot(v, v) * kk);
                H += e;
                grad -= 2.0 * kk * v * e;
            }
        }
        return H;
    }

    /// A supercell's striations at band coordinate `k` (one band a unit) and `strength` 0…1: each band a lip catching
    /// the light over a soft shadow under it. Returns the shade (× the cloud's light) and in `lip` the thread of light
    /// on its lip.
    float cloudStriation(float k, float strength, thread float& lip) {
        float b = 0.5 + 0.5 * sin(6.2831853 * k);
        lip = strength * b * b * b;
        return 1.0 + strength * (0.32 * b * b - 0.32 * (1.0 - b) * (1.0 - b));
    }

    /// How far a tower's cloud at height `z` (km) has gone up into its anvil (0…1), the anvil's underside at `anvilZ`
    /// over it and the tower's turrets `lumps` (0…1): the join is lumpy and below the anvil's own plane, so the anvil's
    /// smooth line is lost in cloud of one colour. `junction` is where it begins.
    float cloudAnvilMelt(float z, float anvilZ, float lumps, thread float& junction) {
        junction = anvilZ - 1.5 + 1.8 * (lumps - 0.5);
        return smoothstep(junction - 0.35, junction + 0.5, z);
    }

    /// A storm base's ragged rim at angle `a` round it (radians), about 0.2–0.7: lumps along the circumference (seen
    /// edge-on they notch it rather than streak it).
    float cloudRagged(float a, int octaves) {
        return 0.65 * skyFbm2(float2(a * 4.0, 21.0), octaves) + 0.35 * skyNoise2(float2(a * 11.0, 5.0));
    }

    /// An inflow band's cloud `off` km from its line (`width` km), clumped along it by `streak` (0…1): a soft-edged band,
    /// never a thread. Its profile across (squared) in `profile`.
    float cloudInflow(float off, float width, float streak, thread float& profile) {
        profile = 1.0 - smoothstep(0.0, 1.3 * width, off);
        profile *= profile;
        return profile * smoothstep(0.3, 0.65, streak);
    }

    /// Mammatus at `g` (pouch cells): round pouches of jittered sizes summed smoothly, each sagging most at its middle.
    /// Returns the underside's normal (x, y along g; z up), tilted by the pouches' slope × `tilt` × `amount`, and in
    /// `dome` how near a pouch's rounded middle it is (0 the creases … 1).
    float3 mammatusNormal(float2 g, float amount, float tilt, thread float& dome) {
        float2 grad;
        float H = cloudBumps(g, 0.0, float2(0.0), float2(7.0), 0.48, 0.3, 1.7, grad);
        dome = smoothstep(0.1, 1.0, H);
        return normalize(float3(-tilt * amount * grad, -1.0));
    }

    // ---------------------------------------------------------------- Fire & Neon: the supercell weather (spec §7.2)
    // The staged storm over any sky world at the shared sky's cost: no ray march, each part one closed-form hit,
    // composited front to back, its texture 2D value noise. In the storm's own frame (km): u along its bearing from you,
    // v to its right (mirrored in the south, where they turn the other way). Supercell Sky's shapes on planes and sheets:
    // - level planes: the rain-free base 1.1 km up (from tens of km it sits on the horizon), the inflow bands streaming
    //   in under it, and the anvil's underside 9.5 km up, from its leading edge (ahead of the storm as it comes,
    //   overhead by the Core) back to its trailing edge;
    // - sheets facing you at the storm (it stands tens of km off, so a sheet loses no parallax worth having): what falls
    //   under it (the forward flank's rain and hail reaching the ground, the rear flank's lighter rain and the shaded
    //   air under the rest of the base, the inflow notch lighter between them: no daylight under the storm), the wall
    //   cloud hanging from the base, and its body: the striated skirt, the cauliflower tower leaning into the anvil with
    //   an overshooting top, the anvil's flat top spreading both ways with rounded, feathered ends, the forward flank's
    //   cloud and the flanking line stepping down, all one field of rounded lumps at their edges.
    // Edges are as sharp as a pixel (a km of softness blurred it into a cut-out). Backlit, the cloud is silver-lined
    // where it thins; lightning lights it from inside round the strike (its billows showing), with a little light all
    // over, through the sky layer's flash limiter.
    constant float kCellBase = 1.1;
    constant float kCellAnvil = 9.5;
    constant float kCellTop = 11.4;

    /// Where the supercell's lightning strikes (km in the storm's frame: along its bearing, to its right, up): a little
    /// ahead of its middle; overhead in its Core it strikes where you look, ahead and low in the rain under the base, not
    /// straight above you out of sight.
    float3 supercellSpot(constant SkyU& u) {
        float D = u.cellC.x;
        float nearCore = 1.0 - smoothstep(3.0, 9.0, D);
        return float3(max(D + 3.0 + (u.cellC.w - 0.5) * 8.0, nearCore * (7.0 + 4.0 * fract(u.cellC.w * 5.3))),
                      (fract(u.cellC.w * 7.31) - 0.5) * mix(6.0, 10.0, saturate((D - 9.0) / 10.0)),
                      mix(2.0 + 4.5 * fract(u.cellC.w * 3.17), 1.4 + 1.6 * fract(u.cellC.w * 3.17), nearCore));
    }

    /// The lightning's light on the storm along `d` this frame (Fire & Neon §7.2, through the sky layer's flash limiter):
    /// a heart round the strike and a wider glow seen along this view, a little light all over; `cover` is how much storm
    /// covers the sky here and `recept` how its cloud takes the light (its lumps bulging bright, the creases dark, its thin
    /// edges glowing), both from `supercellSky`. Never a wash.
    float3 supercellFlashLight(float3 d, constant SkyU& u, float cover, float recept) {
        float glow = saturate(u.cellB.z);
        if (glow <= 0.0 || cover <= 0.002) return float3(0.0);
        float2 b = u.cellA.xy;
        float mirror = u.aurora.w < 0.0 ? -1.0 : 1.0;
        float3 dS = float3(dot(d.xy, b), dot(d.xy, float2(b.y, -b.x)) * mirror, d.z);
        float3 spot = supercellSpot(u);
        float sl = length(spot);
        float sd = sl > 1e-3 ? dot(dS, spot / sl) : 1.0;
        // (A hot heart a few degrees round the strike, falling off fast: lightning in the cloud, not moonlight on it.)
        float heart = 0.95 * exp((sd - 1.0) / 0.007) + 0.3 * exp((sd - 1.0) / 0.04) + 0.08 * exp((sd - 1.0) / 0.3);
        return float3(0.62, 0.66, 0.85) * (glow * (0.04 * cover + recept * heart));
    }

    /// The storm body's shape on its sheet without its lumps (km inside its outline; x across, z up, km), for the light's
    /// roll over it: the skirt and the tower leaning into the anvil, the forward flank's shelf, the flanking line's towers.
    float supercellMass(float x, float z) {
        float hz = z - kCellBase;
        float xa = 1.0 - 0.22 * max(hz - 3.0, 0.0);
        float upper = smoothstep(2.0, 3.8, hz);
        float Ws = 6.6 - 2.2 * smoothstep(0.0, 2.6, hz);
        float Wt = 4.3 + 0.5 * exp(-(hz - 4.8) * (hz - 4.8) / 3.0) + 2.0 * smoothstep(6.0, 8.8, hz);
        float dome = kCellAnvil + 1.0 + 1.9 * exp(-(x - xa - 0.5) * (x - xa - 0.5) / 5.0);
        float e = min(mix(Ws, Wt, upper) - sqrt((x - xa) * (x - xa) + 1.0), dome - z);
        float eF = min(min(x - xa + 9.6 - 0.18 * (z - 3.3) * (z - 3.3), xa - 2.0 + 0.25 * hz - x),
                       min(6.0 - 0.2 * max(xa - x, 0.0) - 0.1 * max(xa - x - 5.5, 0.0) - z, 2.0 * (hz - 0.8)));
        float fx = x - xa;
        float crest = -1e3;
        for (int i = 0; i < 4; i++) {
            float3 t = i == 0 ? float3(5.6, 2.6, 6.6) : (i == 1 ? float3(9.2, 2.3, 5.2)
                             : (i == 2 ? float3(12.6, 2.0, 4.0) : float3(15.6, 1.7, 3.0)));
            float q = (fx - t.x) / t.y;
            crest = max(crest, t.z - (t.z - kCellBase) * (1.0 - sqrt(max(1.0 - 0.55 * q * q, 0.0))) - 0.9 * max(abs(q) - 1.35, 0.0));
        }
        float eL = min(crest - z, 1.6 * (min(fx - 2.5, 21.0 - fx) + 0.8));
        return max(e, max(eF, eL));
    }

    /// The supercell along `d`: its light (premultiplied) in rgb, and in a how much of the sky behind it shows through;
    /// `pa` is a pixel (radians), `fine` its detail (0 the sky's own, drawn every pixel; 1 the impostor's). How its cloud
    /// takes the lightning's light comes back in `recept` (supercellFlashLight adds the light).
    float4 supercellSky(float3 d, constant SkyU& u, float time, float pa, float fine, thread float& recept) {
        recept = 0.0;
        float2 b = u.cellA.xy;
        float2 rgt = float2(b.y, -b.x);
        float mirror = u.aurora.w < 0.0 ? -1.0 : 1.0;
        float hl = length(d.xy);
        float2 hv = hl > 1e-5 ? float2(dot(d.xy, b), dot(d.xy, rgt) * mirror) / hl : float2(1.0, 0.0);
        float k = max(d.z, 0.0) / max(hl, 1e-4);              // km up per km out
        float3 dS = float3(hv * hl, d.z);                       // the view in the storm's frame
        float D = u.cellC.x, E = u.cellC.y, phase = u.cellA.z;
        float turn = u.cellB.y * mirror;
        const float glow = 0.0;                                  // (the lightning is added each frame, from `recept`)
        float mam = saturate(u.cellC.z);
        pa = max(pa, 2e-4);                                     // a pixel (radians)
        int oct = int(u.weather.z + 0.5);
        float sunAlt = u.sun.w;
        bool day = sunAlt > -6.0;
        float3 Lw = day ? u.sun.xyz : u.moon.xyz;
        float3 Lu = float3(dot(Lw.xy, b), dot(Lw.xy, rgt) * mirror, Lw.z);
        // The sun lights the cloud a little after it sets (the anvil stands 9.5 km up); the moon faintly.
        float lightAmt = day ? saturate((sunAlt + 4.0) / 9.0) : u.moonInfo.x * 0.1 * saturate(u.moon.z * 5.0 + 0.2);
        float3 Lc = day ? mix(float3(1.0, 0.5, 0.26), float3(1.0, 0.93, 0.84), saturate(sunAlt / 25.0)) * ashSunTint(u)
                        : float3(0.6, 0.66, 0.82);
        float lowSun = day ? (1.0 - smoothstep(3.0, 14.0, sunAlt)) * smoothstep(-5.0, -1.0, sunAlt) : 0.0;
        float3 amb = mix(u.zenith.rgb, u.horizon.rgb, 0.5);
        float3 grey = float3(0.86, 0.92, 1.04) * dot(amb, float3(0.2126, 0.7152, 0.0722));
        float3 haze = mix(u.horizon.rgb, grey * 1.6, 0.35) * 0.5;
        float toward = saturate(dot(d, Lw));
        float wideBack = toward * toward;
        float back = wideBack * wideBack; back *= back;            // forward scattering toward a light behind it
        // Lightning inside: its spot (u, v, height) and its light are the frame's own (supercellFlashLight); here only
        // how each part takes it, into `recept`.
        float3 spot = supercellSpot(u);
        const float3 flashCol = float3(0.62, 0.66, 0.85);
        float3 acc = float3(0);
        float T = 1.0;
        float baseHit = k > 1e-4 ? kCellBase / k : 1e4;
        float fwd = hv.x;

        // The rain all round you under its core (the schedule's rain at this phase): a grey murk thickening toward the
        // horizon, paler low down and toward the light, in shafts; the Core's flashes light it round the strike.
        float q2 = saturate(phase * 3.0 - 1.0), q3 = saturate(phase * 3.0 - 2.0);
        float rainNow = phase < 1.0 / 3.0 ? 0.0
                      : (phase < 2.0 / 3.0 ? smoothstep(0.0, 0.3, q2) * (1.0 - 0.2 * smoothstep(0.6, 1.0, q2))
                                           : 0.8 * (1.0 - smoothstep(0.0, 0.45, q3)));
        if (rainNow > 0.01) {
            // (Thick enough low down to hide the sun: heavy rain a few km deep.)
            float a = rainNow * (1.0 - exp(-min(baseHit, 12.0) / 1.7));
            float azR = atan2(hv.y, hv.x);
            float shafts = skyNoise2(float2(azR * 7.0, time * 0.04 + 3.0));
            // (In the impostor, the denser shafts it falls in: darker, a few degrees wide, longer than wide.)
            float streaks = fine > 0.5 ? skyFbm2(float2(azR * 13.0 + 3.0 * shafts, atan(k) * 2.0 + time * 0.04), 2) : 0.5;
            streaks = mix(0.5, streaks, smoothstep(0.6, 0.1, k));
            float3 c = grey * (0.27 + 0.26 * (1.0 - saturate(k * 3.0))) * (0.85 + 0.3 * shafts) * (1.06 - 0.14 * streaks)
                     + Lc * (lightAmt * 0.3 * back);
            recept += T * a * 0.55 * (0.6 + 0.8 * shafts);
            acc += T * a * c; T *= 1.0 - a;
        }

        // Scud: ragged low fragments torn off the base's front, 0.7 km up, racing in under it as it arrives (the
        // impostor's detail): dark against the bright low sky, greyer against the base, lit a little from beneath.
        if (T > 0.01 && fine > 0.5 && k > 0.07 && D < 16.0) {
            float ts = 0.7 / k;
            float2 Ps = hv * ts;
            float es = (1.0 - length((Ps - float2(D + 1.5, -2.5)) / float2(5.6, 11.5))) * 5.6;   // km in from the base's rim
            float zone = smoothstep(-2.5, 0.0, es) * (1.0 - smoothstep(2.0, 5.0, es)) * (1.0 - smoothstep(12.0, 16.0, D))
                       * smoothstep(0.07, 0.14, k) * smoothstep(1.5, 3.5, ts);   // (far off, low down, it would be threads)
            if (zone > 0.0) {
                float2 ws = Ps * 1.1 + float2(time * 0.02, time * 0.008);
                float w1 = skyNoise2(ws * 0.5 + 13.0);
                float fs = skyFbm2(ws + 1.5 * float2(w1, skyNoise2(ws * 0.5 + 29.0)), 3);
                float as = smoothstep(0.55, 0.72, fs) * zone * 0.85;
                if (as > 0.002) {
                    float3 c = grey * (0.11 + 0.08 * fs) + u.horizon.rgb * (0.04 + 0.12 * smoothstep(0.6, 0.85, fs));
                    c = mix(c, haze, 1.0 - exp(-ts / 80.0));
                    recept += T * as * 0.4;
                    acc += T * as * c; T *= 1.0 - as;
                }
            }
        }

        // What falls under the storm, on a sheet just in front of its middle, from the ground to the base: the forward
        // flank's rain (left of the wall cloud) streaked as it falls with a paler hail shaft, the rear flank's lighter
        // rain and the shaded air under the rest of the base (right), and between them the inflow notch, lighter, a
        // little of the horizon's light through it.
        float Dr = D - 1.0;
        if (Dr > 2.5 && fwd > 0.2) {
            float rho = Dr / fwd;
            float x = rho * hv.y, z = rho * k;
            if (z < kCellBase + 0.3 && x > -20.0 && x < 20.0) {
                // (Its curtains slant with the wind as they fall, and their edges wander as they come down: soft,
                // never a straight vertical edge.)
                float xs = x + 0.45 * (kCellBase - z) * mirror;
                float n = skyNoise2(float2(xs * 1.3 + z * 0.9, z * 0.6 - time * 0.03));
                float n2 = skyNoise2(float2(xs * 0.35 + 4.0, 1.7 + z * 0.5));
                // (Only under the base and the forward flank's cloud: beyond them, under the flanking line's higher
                // bases and past the rain shield's end, the air is clear.)
                float span = smoothstep(-13.5, -9.0, xs + 2.5 * n2) * (1.0 - smoothstep(6.5, 10.5, xs + 2.5 * n2));
                float rain = 1.0 - smoothstep(-2.4, 1.6, xs + 1.4 * n);
                float rear = smoothstep(3.4, 6.4, xs + 1.4 * n);
                float notch = saturate(1.0 - rain - rear);
                float under = 1.0 - smoothstep(kCellBase - 0.3, kCellBase + 0.15, z);
                // Shafts: the rain heavier and lighter across it, each shaft a few hundred metres to a km wide.
                float2 qs = float2(xs * 0.85 + 11.0, z * 0.3 + 0.3 * n);
                float shaft = 0.8 + 0.32 * (fine > 0.5 ? skyFbm2(qs, 2) : skyNoise2(qs));
                float dens = (rain * (0.88 + 0.12 * n) + rear * (0.74 + 0.2 * n) * (1.0 - 0.35 * smoothstep(9.0, 15.0, x))) * shaft
                           + notch * 0.5;
                float a = saturate(dens * span * under) * smoothstep(2.5, 6.0, Dr);
                if (a > 0.002) {
                    float hail = rain * exp(-(x + 4.5) * (x + 4.5) / 2.5);
                    float3 c = grey * (0.15 + 0.06 * n + 0.12 * hail) * (1.0 - 0.25 * rear);
                    float thinR = 1.0 - saturate(dens * span);
                    c += Lc * (lightAmt * (0.04 + 0.45 * back * thinR * thinR) * (0.6 + 0.6 * notch));
                    c = mix(c, haze * (0.9 + 0.5 * notch), 0.25 * notch * (1.0 - z / kCellBase));
                    c = mix(c, haze, 0.6 * (1.0 - exp(-rho / 80.0)));
                    recept += T * a * (0.5 + 0.3 * hail);
                    acc += T * a * c; T *= 1.0 - a;
                }
            }
        }

        // The wall cloud: an abrupt lowering hanging from the base under the updraft, rounded and ragged at its foot
        // (scud tags), streaked as it turns.
        float Dw = D - 0.5;
        if (T > 0.01 && Dw > 2.5 && fwd > 0.2) {
            float rho = Dw / fwd;
            float x = rho * hv.y - 2.5, z = rho * k;
            float px = rho * pa;
            if (z < kCellBase + 0.1 && abs(x) < 2.9) {
                float s = clamp(x / 2.1, -1.0, 1.0);
                float n = skyNoise2(float2((s * 1.4 + turn) * 2.2, z * 3.0));
                float tags = skyNoise2(float2(x * 3.1 + turn, 7.0));
                float foot = kCellBase - 0.85 + 0.55 * s * s + 0.16 * (n - 0.5) + 0.12 * (tags - 0.5);
                float edge = min(2.05 - 0.45 * saturate((kCellBase - z) / 0.8) + 0.25 * (n - 0.5) - abs(x),
                                 3.0 * (z - foot));
                // (Its top melts into the base it hangs from: the base nearer than it there, a hard top drew a line.)
                float a = smoothstep(-max(px, 0.03), max(px, 0.03) + 0.06, edge) * smoothstep(2.5, 6.0, Dw)
                        * (1.0 - smoothstep(kCellBase - 0.2, kCellBase + 0.1, z));
                if (a > 0.002) {
                    float ndl = saturate(dot(float3(-sqrt(1.0 - s * s), s, 0.0), Lu) * 0.7 + 0.3);
                    float3 c = grey * (0.1 + 0.07 * n) + Lc * (lightAmt * 0.2 * ndl * (0.6 + 0.4 * n));
                    // Its rim, backlit, from afar only (near, its thin rim drew a bright hook across the view).
                    c += Lc * (lightAmt * 0.3 * back * (1.0 - smoothstep(0.0, 0.25, edge)) * smoothstep(8.0, 14.0, Dw));
                    c = mix(c, haze, 1.0 - exp(-rho / 80.0));
                    recept += T * a * 0.8 * (0.6 + 0.4 * n);
                    acc += T * a * c; T *= 1.0 - a;
                }
            }
        }

        // The inflow bands: low bands of cloud 0.8 km up streaming in from the right toward the wall cloud, each a log
        // spiral round it, converging in perspective (Supercell Sky's bands); they fade as they lie edge-on at the
        // horizon, and are gone once the storm is overhead.
        if (T > 0.01 && k > 0.02 && D > 5.0) {
            float t = 0.8 / k;
            float2 q = hv * t - float2(D - 0.5, 2.5);
            float r = length(q);
            if (r > 2.2 && r < 16.0) {
                float centre = atan2(6.0, -(D - 0.5));
                float ang = atan2(q.y, q.x) + 0.3 * mirror * log(r / 1.8) - centre;
                ang -= 6.2831853 * floor((ang + 3.14159265) / 6.2831853);
                float f = ang / 0.32 + 3.0;
                float kb = floor(f + 0.5);
                float off = abs(f - kb) * 0.32 * r;
                float width = 0.22 + 0.05 * r;
                if (kb >= 0.0 && kb <= 6.0 && off < 1.3 * width) {
                    float streak = skyNoise2(float2(r * 0.55 - time * 0.02, kb * 3.7));
                    float profile;
                    float dens = cloudInflow(off, width, streak, profile) * smoothstep(2.2, 4.5, r)
                               * (1.0 - smoothstep(9.0, 15.0, r)) * smoothstep(0.03, 0.1, k) * smoothstep(5.0, 9.0, D) * 0.4
                               * smoothstep(4.0, 9.0, t);   // (near and high overhead they would smear across the view)
                    if (dens > 0.002) {
                        float3 c = grey * (0.2 + 0.12 * streak) + Lc * (lightAmt * (0.08 + 0.5 * back) * (0.6 + 0.4 * streak));
                        c = mix(c, haze, 1.0 - exp(-t / 80.0));
                        acc += T * dens * c; T *= 1.0 - dens;
                    }
                }
            }
        }

        // The storm's base, under its body from its front back to its far side: rain-free round the updraft, darker over
        // the forward flank's rain; a dark mottled underside, its ragged rim catching a low light beyond it; overhead (the
        // Core) it is near, scud racing under it.
        if (T > 0.01 && k > 0.004 && baseHit < 400.0) {
            float2 P = hv * baseHit;
            float2 qc = (P - float2(D + 1.5, -2.5)) / float2(5.6, 11.5);
            float rr = length(qc);
            float pxb = baseHit * pa / max(k, 0.03) * 0.5;          // a pixel across its rim, seen edge-on (km)
            float a = 0.0;
            // Overhead and arriving (its front within 12 km), its underside turbulent: three octaves from a km down,
            // drifting with the inflow (the impostor's detail).
            float closeB = 1.0 - smoothstep(6.0, 12.0, D - 4.0);
            float tb = 0.5;
            if (closeB > 0.0 && fine > 0.5 && rr < 1.4) tb = skyFbm2(P * 0.8 + float2(time * 0.004, 0.0) + 7.0, 3);
            if (rr < 1.25 + pxb * 0.2 + 0.15 * closeB) {
                float rag = cloudRagged(atan2(qc.y, qc.x), oct);
                float edge = (1.0 - rr) * 5.6 + 1.1 * (rag - 0.3) + 1.4 * closeB * (tb - 0.5);
                float sb = max(pxb, 0.15) + 0.35 * closeB;
                a = smoothstep(-sb, sb + 0.3, edge);
            }
            if (a > 0.002) {
                float edge = (1.0 - rr) * 5.6;
                float nb = skyNoise2(P * 0.22 + 3.0);
                float2 qf = (P - float2(D - 0.5, -6.5)) * float2(1.0, 1.1);
                float near = 1.0 - smoothstep(4.0, 9.0, baseHit);
                float scud = near > 0.0 ? skyNoise2(P * 1.3 + float2(time * 0.015, time * 0.006)) : 0.5;
                float3 c = grey * (0.1 + 0.06 * nb + 0.08 * near * (scud - 0.5)) * (1.0 - 0.3 * exp(-dot(qf, qf) / 45.0))
                         * mix(1.0, 0.65 + 0.7 * tb, closeB);
                float2 Ld = Lu.xy / max(length(Lu.xy), 1e-3);
                float2 qn = qc / max(rr, 1e-3);
                c += Lc * (lightAmt * (0.05 * back + 0.55 * lowSun * saturate(dot(qn, Ld))) * smoothstep(3.0, 0.0, edge) * (0.5 + nb));
                // Arriving, lit from beneath by the bright sky low round it: its leading edge most (the shelf's lip,
                // layered: a second, fainter step a couple of km in), and the lumps hanging lowest in its underside.
                float lip = 1.0 - smoothstep(0.0, 1.4, edge) + 0.45 * exp(-(edge - 2.4) * (edge - 2.4) / 0.35);
                c += u.horizon.rgb * (closeB * (0.1 * lip * (0.4 + 1.2 * tb) + 0.07 * smoothstep(0.5, 0.85, tb)));
                c = mix(c, haze, 1.0 - exp(-baseHit / 80.0));
                recept += T * a * (0.2 + 0.9 * nb);
                acc += T * a * c; T *= 1.0 - a;
            }
        }

        // The storm's body, one sheet facing you at its front, and the anvil's underside over you: each found, then the
        // nearer laid first (the anvil's leading edge overhangs the body as it comes).
        float4 body = float4(0.0);
        float bodyT = 1e9, bodyRec = 0.0, anvilRec = 0.0;
        float Df = D - 3.0;
        if (T > 0.01 && Df > 1.5 && fwd > 0.15) {
            float rho = Df / fwd;
            float x = rho * hv.y, z = rho * k;
            float hz = z - kCellBase;
            float px = rho * pa;                                    // a pixel at the sheet (km)
            float xa = 1.0 - 0.22 * max(hz - 3.0, 0.0);             // the updraft's axis, leaning downshear as it rises
            // Arriving (its front 13 km off and nearer) the storm's front fills the view and is drawn as the shelf and
            // the heavy underside passing over: soft turbulent cloud, its tiers soft and lit from below, its edges ragged
            // and soft (the striated wall seen from afar drew a stack of terraces with a line round each).
            float close = 1.0 - smoothstep(6.0, 13.0, Df);
            // A cheap bound first (the skirt and tower, the forward flank and the flanking line with their widest lumps),
            // so the sky beside the storm costs a few sums.
            float bound = max(max(9.0 - abs(x - xa), min(min(x - xa + 15.0, xa + 1.0 - x), 9.0 - z)),
                              min(min(x - 3.0, 19.5 - x), 9.5 - z));
            // (Close, the impostor's veil reaches a km and a half past the outline.)
            if (hz > -0.3 && z < kCellTop + 1.6 && bound > -0.1 - 1.8 * close * fine) {
                float2 p = float2(x, z) * 0.8 + 7.0;
                float e1 = skyNoise2(p);
                float en = 0.6667 * e1 + 0.3333 * skyNoise2(p * 2.03 + float2(17.1, 9.2));
                // Cauliflower at two sizes (Supercell Sky's smooth sum of rounded bumps, warped so they never line up):
                // turrets a couple of km across, and the lumps on them a few hundred metres (never finer than a few
                // pixels: fewer, larger lumps far off).
                float2 warp = 0.9 * float2(e1, skyNoise2(p * 0.5 + 3.3));
                float bs = max(0.5, 2.5 * px);
                float2 gb;
                float Hb = cloudBumps(float2(x - 0.2 * turn, z) / bs + warp, 0.0, float2(17.0), float2(3.0), 0.5, 0.3, 2.2, gb);
                // (Drawn every pixel, the turrets are one octave of noise: a wobbling outline, not the sums.)
                float2 gB = float2(0.0);
                float HB = 0.25 + 1.1 * skyNoise2(float2(x, z) * 0.75 + 31.0);
                if (fine > 0.5) HB = cloudBumps(float2(x - 0.1 * turn, z) / 1.9 + 0.6 * warp + 31.0, 0.0, float2(5.0), float2(9.0),
                                                0.55, 0.4, 1.8, gB);
                float lobe = smoothstep(0.08, 0.9, Hb) - 0.5;      // −0.5 … 0.5
                float turret = smoothstep(0.1, 1.15, HB) - 0.5;
                // Close, its turbulence: three octaves from a km to 250 m, drifting, warped by the big noise; and the same a
                // little higher, so each puff's underside (the field rising into it) can take the light from below.
                float turb = 0.5, turbRise = 0.0;
                if (close > 0.0 && fine > 0.5) {
                    float2 pt = float2(x - 0.15 * turn, z) * 1.1 + 1.4 * float2(en, e1) + float2(time * 0.006, 0.0);
                    turb = skyFbm2(pt, 3);
                    turbRise = skyFbm2(pt + float2(0.0, 0.2), 3) - turb;
                }
                // The updraft: the striated skirt flaring over the base (smooth, laminar), the cauliflower tower above it
                // rising in turrets, widening as it goes up into the anvil.
                float upper = smoothstep(2.0, 3.8, hz);
                float Ws = 6.6 - 2.2 * smoothstep(0.0, 2.6, hz);
                float Wt = 4.3 + 0.5 * exp(-(hz - 4.8) * (hz - 4.8) / 3.0) + 2.0 * smoothstep(6.0, 8.8, hz);
                float W0 = mix(Ws, Wt, upper);
                float s = clamp((x - xa) / W0, -1.0, 1.0);
                // Striations: rings round the turning updraft. Seen from below, a ring's sides stand farther off than its
                // front, so each band bows down toward the sides; a helix, it climbs across the face as it turns; its
                // spacing wanders round it and up it, and each band is strongest where it faces you. (Close they are gone:
                // seen from under it, a whole skirt of them drew a stack of terraces with a line round each.)
                float side = sqrt(max(1.0 - s * s, 0.0));
                float zr = z * (1.0 + W0 * (1.0 - side) / Df) - kCellBase;
                float swirl = asin(s) * 0.3183 * mirror;            // −0.5 … 0.5 across the face
                float kb = zr * 1.05 + 0.85 * swirl + 0.16 * turn + 0.55 * (en - 0.5)
                         + 0.5 * skyNoise2(float2(swirl * 3.0 + 0.3 * turn, zr * 0.45 + 9.0));
                float fb = fract(kb);
                float stri = (1.0 - upper) * smoothstep(0.05, 0.45, hz) * smoothstep(0.15, 0.7, side + 0.3 * en)
                           * smoothstep(2.0, 4.0, Df) * (1.0 - close)
                           * (0.3 + 0.7 * smoothstep(0.25, 0.75, skyNoise2(float2(floor(kb) * 3.7 + 1.0, swirl * 5.0 + 0.2 * turn))));
                // (Each band's foot is a lip standing out from the one under it: the skirt's outline steps.)
                float lipOut = (1.0 - upper) * 0.42 * (1.0 - fb) * (1.0 - fb) * smoothstep(0.1, 0.5, hz) * (1.0 - close);
                float W = W0 + lipOut + 0.25 * (en - 0.5) + upper * (1.9 * turret + 0.3 * lobe);
                // Its top: turrets pushing up into the anvil's foot, an overshooting dome over the axis.
                float dome = kCellAnvil + 1.0 + 1.9 * exp(-(x - xa - 0.5) * (x - xa - 0.5) / 5.0);
                float edge = min(W - abs(x - xa), dome + 1.1 * turret + 0.4 * lobe - z);
                // (Close, its underside is lumpy all over: rounded puffs, each lit on its underside from below.)
                float sn = s, nz = 0.12, lumpy = max(upper, 0.85 * close);
                // The forward flank's cloud beside it (left, downshear): a lower, flatter shelf over the rain, from a
                // couple of km up to a shoulder falling away from the updraft, its lumps smoothed.
                float eF = min(min(x - xa + 9.6 - 0.18 * (z - 3.3) * (z - 3.3), xa - 2.0 + 0.25 * hz - x),
                               min(6.0 - 0.2 * max(xa - x, 0.0) - 0.1 * max(xa - x - 5.5, 0.0) - z, 2.0 * (hz - 0.8)))
                         + 1.2 * (en - 0.5) + 0.5 * turret;
                if (eF > edge - 1.0) {
                    float w = smoothstep(-1.0, 1.0, eF - edge);
                    sn = mix(sn, -0.3, w); nz = mix(nz, 0.3, w); stri *= 1.0 - w; lumpy = mix(lumpy, 0.5, w); edge = max(edge, eF);
                }
                // The flanking line: towers stepping down to its right, one line of cloud (their feet one shelf, the
                // valleys between them shallow), each as wide as it is tall and cauliflower all over: turrets on turrets.
                float fx = x - xa;
                float xr = min(fx - 2.5, 21.0 - fx);
                float shelf = min(min(fx - 2.5, 13.5 - fx) * 0.6, 2.6 - 0.1 * fx - hz);
                float crest = -1e3;
                for (int i = 0; i < 4; i++) {
                    float3 t = i == 0 ? float3(5.6, 2.6, 6.6) : (i == 1 ? float3(9.2, 2.3, 5.2)
                                     : (i == 2 ? float3(12.6, 2.0, 4.0) : float3(15.6, 1.7, 3.0)));
                    float q = (fx - t.x) / t.y;
                    // A rounded dome (no neck): full height over its middle, falling as a circle to its sides.
                    float c = t.z - (t.z - kCellBase) * (1.0 - sqrt(max(1.0 - 0.55 * q * q, 0.0))) - 0.9 * max(abs(q) - 1.35, 0.0);
                    crest = max(crest, c);
                }
                float eL = min(crest - z, 1.6 * (xr + 0.8)) + 1.1 * turret + 0.25 * lobe + 0.3 * (en - 0.5);
                eL = max(eL, shelf + 0.5 * turret);
                if (eL > edge - 1.0) {
                    float w = smoothstep(-1.0, 1.0, eL - edge);
                    sn = mix(sn, clamp((fx - 9.0) / 9.0, -1.0, 1.0), w); nz = mix(nz, 0.35, w);
                    stri *= 1.0 - w; lumpy = mix(lumpy, 1.0, w); edge = max(edge, eL);
                }
                // As sharp as a pixel (a km of softness blurred it into a cut-out); close, ragged and soft over a couple
                // of hundred metres, as near cloud is.
                edge += close * 0.9 * (turb - 0.5);
                float soft = max(max((fine > 0.5 ? 0.75 : 1.1) * px, 0.025), 0.35 * close);
                float aCore = smoothstep(-soft, soft, edge);
                // Close, a thin torn veil beyond its edge, fading over a km and a half, so the sky past it is graded
                // (never a bright cut-out slot).
                float veil = close * fine * 0.6 * smoothstep(-1.6, 0.0, edge) * smoothstep(0.25, 0.75, turb + 0.3 * (en - 0.5));
                float a = max(aCore, veil) * smoothstep(-0.3, 0.05, hz) * smoothstep(1.5, 3.4, Df);
                float thinA = 1.0 - smoothstep(0.0, 1.2, edge);
                if (a > 0.002) {
                    // The normal: rounded in from its outline (each turret a dome: across its edge it turns from facing
                    // you to facing out), tilted by its lumps' slope (from the sums): each lump lighter on its side toward
                    // the light, the folds between them soft.
                    // (The outline's own direction from the shape without its lumps, so its parts roll into each
                    // other with no seam; the surface faces you deep inside it and turns out toward its outline.)
                    // (Drawn every pixel, the parts' own hand-set directions stand in: cheaper, a seam or two.)
                    float2 out2 = float2(sn, nz);
                    if (fine > 0.5) {
                        float m0 = supercellMass(x, z);
                        float2 gm = float2(supercellMass(x + 0.8, z) - m0, supercellMass(x, z + 0.8) - m0);
                        out2 = -gm / max(length(gm), 1e-4);
                    }
                    float tIn = saturate(max(edge, 0.0) / 2.6);
                    float facing = sqrt(tIn * (2.0 - tIn));
                    float2 slope = (gb * (0.04 / bs) + gB * (0.5 / 1.9)) * lumpy;
                    float3 N = normalize(float3(-max(facing, 0.15), out2.x * (1.0 - facing) - slope.x,
                                                out2.y * (1.0 - facing) + 0.2 * nz - slope.y));
                    float fold = mix(0.7 + 0.3 * smoothstep(0.1, 0.9, Hb), smoothstep(0.05, 0.9, HB), lumpy);
                    float occl = mix(1.0, 0.88 + 0.12 * fold, lumpy);
                    float ndl = dot(N, Lu);
                    float direct = saturate(0.7 * ndl + 0.3) * occl;
                    float strLip;
                    float bandShade = cloudStriation(kb, stri, strLip);
                    // Near, each band's foot is a crisp lip (a pixel or two, not a soft swell), lit, over the shadow it
                    // casts on the top of the band under it.
                    float near = (1.0 - smoothstep(9.0, 16.0, Df)) * (1.0 - close);
                    if (near > 0.0 && stri > 0.0) {
                        float wl = clamp(px * 1.05 * 3.0, 0.05, 0.22);
                        float lipB = exp(-fb / wl);
                        float shadowB = smoothstep(1.0 - 6.0 * wl, 1.0, fb);
                        bandShade = mix(bandShade, (1.0 + 0.35 * stri * lipB) * (1.0 - 0.45 * stri * shadowB * shadowB), near);
                        strLip = mix(strLip, stri * lipB, near);
                    }
                    // The sky's light on it: steel blue-grey, lighter on the tops, darker low down in the base's shade;
                    // close, mottled by its turbulence.
                    float skyLit = (0.7 + 0.5 * saturate(N.z + 0.25)) * occl;
                    float3 body3 = grey * float3(0.8, 0.9, 1.05) * (0.15 + 0.05 * en) * skyLit
                                 * mix(0.55, 1.0, smoothstep(0.0, 3.0, hz)) * mix(1.0, 0.65 + 0.7 * turb, close);
                    float sunSide = saturate(0.7 * ndl + 0.3);
                    float3 warm = Lc * (lightAmt * sunSide * sqrt(sunSide) * occl * (0.5 + 0.6 * smoothstep(0.5, 6.0, hz)));
                    float3 c = (body3 * (1.0 - 0.3 * direct) + warm) * bandShade;
                    c += Lc * (lightAmt * 0.07 * strLip * saturate(ndl + 0.5));
                    // Close, its cloud lit from beneath by the bright sky low under the storm: each puff's rounded underside
                    // (the lumps' own slope, and the turbulence rising into it), the lowest most.
                    float underL = close * (1.0 - 0.75 * smoothstep(0.0, 3.5, hz)) * (0.4 + 0.6 * turb);
                    c += u.horizon.rgb * (underL * (0.03 + 0.35 * saturate(-N.z) + 0.6 * saturate(turbRise)));
                    // Backlit: the low light comes through where it thins, a gold rim on every turret's outline and a
                    // softer glow a little inside it; the lips of the skirt's bands catch a thread of it too, and its body
                    // takes a faint warm translucence near the light, so the storm stands in the sun's light, not before it.
                    float rimW = max(max(3.0 * px, 0.06), 1.5 * soft);
                    float rim = 1.0 - smoothstep(0.0, rimW, edge);
                    float vary = smoothstep(0.25, 0.75, en + 0.35 * (fold - 0.5));
                    float lining = (0.75 * rim + 0.15 * thinA * thinA) * (0.35 + 0.65 * saturate(N.z + 0.6)) * (0.3 + 1.0 * vary);
                    c += Lc * (lightAmt * (2.2 * back + 0.35 * wideBack) * lining);
                    c += Lc * (lightAmt * back * (0.06 * saturate(N.z + 0.5) * (0.4 + en) + 0.05 * strLip * stri));
                    // How it takes the lightning (supercellFlashLight): its lumps bulge bright, the creases stay dark,
                    // its thin edges glow.
                    float rec = (0.62 + 0.38 * fold * saturate(N.z + 0.6)) * (0.7 + 0.6 * thinA) * (0.55 + 0.45 * en);
                    // Up into the anvil's own shade, so the tower and the anvil overhead are one cloud.
                    float junction;
                    float into = cloudAnvilMelt(z, kCellAnvil, 0.5 + 0.8 * turret, junction);
                    c = mix(c, grey * (0.17 + 0.06 * en + 0.05 * fold) + Lc * (lightAmt * 0.6 * back * lining), 0.75 * into);
                    // (The veil: thin cloud, lit by the sky round it.)
                    c = mix(c, haze * 0.8 + grey * 0.08, 0.6 * close * (1.0 - aCore));
                    c = mix(c, haze, 1.0 - exp(-rho / 90.0));
                    body = float4(c * a, a);
                    bodyT = rho;
                    bodyRec = a * rec;
                }
            }
        }

        float4 anvil = float4(0.0);
        float anvilT = 1e9;
        // (Behind an opaque body by more than the cross-fade, the anvil would add nothing: its underside sags at most
        // 3 km, so it is never nearer than 6.5 km up.)
        bool hidden = body.a >= 1.0 && bodyT + 1.2 <= (kCellAnvil - 3.0) / max(k, 1e-4);
        if (T > 0.01 && k > 0.0015 && !hidden) {
            // The anvil's underside, a ceiling over you from far off the view's sides back to its trailing edge behind
            // the storm (as Supercell Sky's): it sags toward the tower it spreads from (one step of the sag at the level
            // plane's hit), so the two meet; its trailing edge is rounded and ragged, feathered into fibres.
            float rho = kCellAnvil / k;
            float2 P = hv * rho;
            float2 top = float2(D - 3.0, -0.75);
            float sag = (2.2 + 1.6 * (skyNoise2(P * 0.45 + 1.0) - 0.5)) * exp(-length(P - top) / 6.0);
            rho = (kCellAnvil - sag) / k;
            P = hv * rho;
            float na = skyNoise2(P * 0.06 + 11.0);
            float trail = E - P.x - P.y * P.y / 60.0 + 20.0 * (na - 0.5);
            float spread = smoothstep(2.0, -9.0, D);
            float side = 30.0 + 0.6 * max(D + 4.0 - P.x, 0.0) + 0.5 * spread * max(P.x - D - 4.0, 0.0)
                       - abs(P.y + 2.0) + 8.0 * (na - 0.5);
            // While the storm is far its anvil is a fan spreading toward you from the tower's top (its edges running out
            // from it toward the view's upper corners, the sky showing under them), widening as it comes; by the Core it
            // is the whole sheet.
            float ahead = top.x - P.x;
            float fan = 5.5 + 0.85 * max(ahead, 0.0) - 0.35 * max(-ahead, 0.0) - abs(P.y - top.y + 0.3 * max(ahead, 0.0))
                      + 7.0 * (na - 0.5);
            side = mix(fan, side, smoothstep(15.0, 6.0, D));
            float ed = min(trail, side);
            if (abs(ed) < 6.0) {
                float fade = 1.0 - smoothstep(4.0, 6.0, abs(ed));
                ed += (2.6 * (skyNoise2(P * 0.25 + 5.0) - 0.5) + 1.1 * (skyNoise2(P * float2(0.9, 1.7) + 2.0) - 0.5)) * fade;
            }
            // As sharp as a pixel (seen edge-on its edge is foreshortened), its fibres doing the feathering.
            float pxA = rho * pa / max(k, 0.05) * 0.6;
            float a = smoothstep(-max(pxA, 0.05), max(pxA, 0.05) + 0.35, ed);
            // Its edges thin cirrus: translucent over their last few km, in fibres (no cut-out cliff against the sky).
            if (a > 0.002 && ed < 6.0) {
                float fe = skyNoise2(float2(atan2(P.y - top.y, P.x - top.x) * 14.0, length(P - top) * 0.05 + 4.0));
                a *= 0.15 + 0.85 * smoothstep(-0.5, 5.0, ed + 3.0 * (fe - 0.5));
            }
            if (a > 0.002) {
                float thin = 1.0 - smoothstep(0.0, 10.0, ed);
                // Its underside's texture in a frame where a shape stays round on screen at any distance (across, the
                // arc round you; outward, 9.5·asinh(ρ/9.5)): broad soft billows, lit a little on their side toward the
                // light, and the outflow's fibres radiating from the tower.
                float phi = atan2(P.y, P.x);
                float outward = kCellAnvil * log(rho / kCellAnvil + sqrt(rho * rho / (kCellAnvil * kCellAnvil) + 1.0));
                float2 gq = float2(rho * phi, outward);
                float bil = skyNoise2(gq * 0.2 + 3.0);
                float under = saturate(0.3 - 5.0 * Lu.z);
                float bilL = bil;
                if (under > 0.0) {
                    float2 Lq = normalize(float2(Lu.y, Lu.x) + float2(1e-4, 0.0));
                    bilL = skyNoise2((gq + Lq * 1.2) * 0.2 + 3.0);
                }
                float2 qt = P - top;
                float fib = skyNoise2(float2(atan2(qt.y, qt.x) * 9.0 + 2.0 * bil, length(qt) * 0.08 + 2.0));
                // Its underside lumpy (the outflow's billows: the sum of rounded bumps, round on screen), darker over the
                // tower it pours from, lighter and fibrous toward its thin edges.
                float HA = bil * 1.2;
                float2 gA = float2(0.0);
                // (Warped in the same frame, by noise round on screen: a warp taken on the plane shears them into streaks.)
                float wq = skyNoise2(gq * 0.13 + 21.0);
                if (fine > 0.5) HA = cloudBumps(gq / 2.4 + 0.8 * float2(wq, bil) + 50.0, 0.0, float2(11.0), float2(13.0),
                                                0.55, 0.45, 1.7, gA);
                float billow = smoothstep(0.1, 1.1, HA);
                float pm = mam * smoothstep(0.38, 0.58, na) * (1.0 - smoothstep(14.0, 30.0, trail)) * smoothstep(0.0, 4.0, trail);
                if (fine > 0.5 && pm < 0.6) {
                    // (Smaller lumps on the billows: an underside, not a ceiling. Among the pouches, the pouches.)
                    float2 gA2;
                    float HA2 = cloudBumps(gq / 0.95 + 0.6 * float2(bil, wq) + 70.0, 0.0, float2(19.0), float2(23.0), 0.5, 0.4, 1.8, gA2);
                    float w2 = 1.0 - smoothstep(0.3, 0.6, pm);
                    gA += 0.6 * w2 * gA2;
                    billow = mix(billow, 0.65 * billow + 0.35 * smoothstep(0.1, 1.1, HA2), w2);
                }
                float edgeNear = 1.0 - smoothstep(0.0, 7.0, ed);
                // (The billows lit from the bright sky low under its edge, toward the light: relief, not a flat lid.)
                float2 Lh2 = normalize(float2(Lu.y, Lu.x) + float2(1e-4, 0.0));
                float relief = fine > 0.5 ? saturate(0.5 + 0.3 * dot(gA, Lh2)) : 0.5;
                float3 c = grey * (0.07 + 0.05 * bil + 0.08 * billow + 0.14 * relief * (0.4 + billow) + 0.04 * fib * edgeNear
                                   + 0.05 * na + 0.14 * thin)
                         * mix(0.7, 1.0, smoothstep(2.0, 14.0, length(qt)));
                // Warmed from below near its edges by the low sky's light.
                c += Lc * (lightAmt * 0.05 * edgeNear * relief * (0.5 + billow));
                // A low light gets under it from the clear side beyond its trailing edge (warmest near the edge); after
                // sunset it lights it from below.
                float reach = exp(-max(trail, 0.0) / 14.0) * saturate(Lu.x * 2.0 + 0.4);
                float lit = under * (0.7 + 0.6 * saturate(0.5 + 2.0 * (bilL - bil)));
                float dome = 0.5;
                if (pm > 0.01) {
                    // Mammatus: Supercell Sky's pouches (the same sum of bumps and the same light), in the frame where a
                    // pouch stays round on screen: each lit on its flank toward the low sun, the folds between soft and
                    // shaded.
                    float2 gm = gq / 1.5 + 0.35 * float2(bil, skyNoise2(gq * 0.11 + 4.0));
                    float3 nq = mammatusNormal(gm, pm, 1.6, dome);
                    // The frame's axes round you (across, outward) into the storm's (along, right).
                    float2 out2 = P / max(length(P), 1e-3);
                    float3 nrm = normalize(float3(out2 * nq.y + float2(-out2.y, out2.x) * nq.x, nq.z));
                    // (Seen from below, the low light reaches them from under the anvil's edge, scattered up off the
                    // rain-washed air and the ground as much as from the sun: each pouch's rounded bottom lit, its flank
                    // away from the sun and the folds between in shade.)
                    float3 Lp = normalize(float3(Lu.xy, min(Lu.z, 0.0) - 0.35));
                    float ndl = 0.6 * saturate(dot(nrm, Lp)) + 0.4 * saturate(-nrm.z) * saturate(-nrm.z);
                    lit = mix(lit, (0.35 * ndl + 0.65 * dome * dome) * (0.4 + 0.6 * dome), pm);
                    c = mix(c, grey * (0.1 + 0.16 * dome), 0.6 * pm);
                }
                c += Lc * float3(1.0, 0.82, 0.68) * (lightAmt * (0.04 + 1.2 * lowSun * reach) * lit * (0.8 + 0.4 * dome));
                // At night the clear sky beyond its trailing edge (the horizon's faint glow) lights its underside a little,
                // most near the edge, so its billows and pouches show faintly against the black of its middle.
                if (!day) c += u.horizon.rgb * (1.1 * exp(-max(trail, 0.0) / 9.0) * (0.45 + 0.9 * bil) * (0.55 + 0.7 * dome));
                // Its edges, thin, glow against a light behind them (silver, then gold low down).
                float edgeBand = 1.0 - smoothstep(0.0, 2.0, ed);
                c += Lc * (lightAmt * (1.2 * back + 0.12 * wideBack) * edgeBand * (0.5 + 0.7 * fib));
                c = mix(c, haze, 1.0 - exp(-rho / 110.0));
                anvil = float4(c * a, a);
                anvilT = rho;
                anvilRec = a * 0.55 * (0.75 + 0.5 * bil) * (0.8 + 0.4 * dome);
            }
        }
        // Where the two meet they cross-fade over a km or so (a hard order drew a straight line where the tower's sheet
        // meets the anvil's ceiling).
        float wA = smoothstep(-1.2, 1.2, bodyT - anvilT);
        float3 rgb = mix(body.rgb + (1.0 - body.a) * anvil.rgb, anvil.rgb + (1.0 - anvil.a) * body.rgb, wA);
        recept += T * mix(bodyRec + (1.0 - body.a) * anvilRec, anvilRec + (1.0 - anvil.a) * bodyRec, wA);
        acc += T * rgb; T *= (1.0 - body.a) * (1.0 - anvil.a);

        // Crepuscular rays: with the low sun behind the storm's body (from far off), its towers cast their shadows
        // through the hazy air toward you and the light streams between them, beams fanning out round it.
        float sunAng = acos(clamp(dot(d, u.sun.xyz), -1.0, 1.0));
        if (day && lowSun > 0.0 && T > 0.01 && Df > 4.0 && Lu.x > 0.2 && fine > 0.5 && sunAng < 2.2) {
            float rs = Df / Lu.x;
            float hidden = smoothstep(-0.3, 0.6, supercellMass(rs * Lu.y, rs * Lu.z));
            if (hidden > 0.0) {
                float3 S = u.sun.xyz;
                float ang = sunAng;
                float3 e1 = normalize(cross(S, float3(0.0, 0.0, 1.0)) + float3(1e-4, 0.0, 0.0));
                float psi = atan2(dot(d, cross(e1, S)), dot(d, e1));
                float beams = smoothstep(0.3, 0.75, skyNoise2(float2(psi * 9.0, 2.0 + time * 0.002)))
                            * (0.6 + 0.4 * skyNoise2(float2(psi * 23.0, 7.0)));
                float reachR = hidden * lowSun * lightAmt * exp(-ang / 0.7) * smoothstep(0.03, 0.2, ang) * smoothstep(0.0, 0.03, d.z);
                acc += T * Lc * (0.2 * reachR * beams);
                T *= 1.0 - 0.12 * reachR * (1.0 - beams);
            }
        }

        return float4(acc, T);
    }

    /// The sky's light in direction `d` (alt ≥ 0): gradient, sunset band, stars, Milky Way, aurora, moon, pillars,
    /// clouds, sun. `moonMask` returns how much of the moon disc covers the ray. Shared by the dome and by reflections.
    /// `stars` is the real star texture (fragment texture 0; a 1×1 placeholder while it builds, with u.eq0.w = 0).
    float3 skyRadianceBase(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars) {
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
        // Ashfall (Fire & Neon §7.1): a brown-grey haze low down.
        if (kSkyStorms && u.ash.x > 0.0) {
            float hl = dot(u.horizon.rgb, float3(0.2126, 0.7152, 0.0722));
            col = mix(col, float3(1.1, 0.96, 0.78) * hl, saturate(u.ash.x) * 0.45 * exp(-max(alt, 0.0) / 0.22));
        }

        // Sunset band and sun glow.
        float sunDot = dot(d, S), sunAngle = acos(clamp(sunDot, -1.0, 1.0));
        float low = saturate(1.0 - abs(sunAlt) / 15.0);
        col += float3(0.9, 0.42, 0.14) * low * 0.55 * exp(-sunAngle / 0.45) * exp(-max(alt, 0.0) / 0.25);
        if (sunAlt > -2.0) {
            col += float3(1.0, 0.85, 0.65) * ashSunTint(u) * 0.45 * exp(-sunAngle / 0.08) * saturate((sunAlt + 2.0) / 4.0);
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
        if (kSkyStorms && alt > 0.0 && (u.spriteA[0].w > 0.0 || u.spriteA[1].w > 0.0 || u.spriteA[2].w > 0.0)) {
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
            float3 moonCol = float3(1.0, 0.97, 0.9) * ashMoonTint(u, M.z) * 1.6 * maria * limb * (lit + u.moonInfo.y);
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
        if (kSkyStorms && u.storm.z > 0.001 && alt > -0.01) col = farStorm(d, alt, col, u, time);

        // The supercell weather (Fire & Neon §7.2) takes the generic cloud's place as it comes (drawn over all this in
        // skyRadiance).
        if (kSkyCell) cloudCover *= 1.0 - saturate(u.cellA.w);

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
            col = mix(col, sunCol * ashSunTint(u), disc * (1.0 - 0.85 * saturate(cloudCover - 0.4)));
        }

        // A fireball's soft brightening of the whole sky (meteorFlash, already through the sky's flash limiter).
        return col * (1.0 + u.flash.x);
    }

    /// skyRadianceBase under the supercell's `storm` (its light premultiplied, and how much of the sky shows through) at
    /// `amount`.
    float3 skyRadianceOver(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars, float amount,
                           float4 storm) {
        // The light under the core goes green (a grade of at most 12%).
        float3 grade = mix(float3(1.0), float3(1.0 - 0.9 * 0.12, 1.0 + 0.25 * 0.12, 1.0 - 0.6 * 0.12),
                           saturate(u.cellB.x / 0.12)) * amount;
        float through = 1.0 - amount + amount * storm.a;
        float3 col = float3(0);
        moonMask = 0.0;
        // One call site: skyRadianceBase is large, and inlined twice it slowed every sky about sevenfold on CI.
        if (through > 0.002) col = skyRadianceBase(d, u, moonMask, stars);
        moonMask *= through;
        return col * (1.0 - amount) + grade * (storm.rgb + storm.a * col);
    }

    /// The sky's light in direction `d`: skyRadianceBase, with the supercell weather (Fire & Neon §7.2) over it all as
    /// it comes (over the clouds, the moon and the sun's disc, which it hides). The storm is drawn first, where little
    /// else is live, and the sky behind it only where it shows through (under the storm's dark body none of it is drawn).
    float3 skyRadiance(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars) {
        // (A plain sky's program has none of the storm: amount folds to 0, and the base is all that is left.)
        float amount = kSkyCell && d.z > -0.01 ? saturate(u.cellA.w) : 0.0;
        float4 storm = float4(0.0, 0.0, 0.0, 1.0);
        if (kSkyCell && amount > 0.001) {
            float recept;
            storm = supercellSky(d, u, u.forward.w, u.weather.w, 0.0, recept);
            storm.rgb += supercellFlashLight(d, u, 1.0 - storm.a, recept);
        }
        return skyRadianceOver(d, u, moonMask, stars, amount, storm);
    }

    // The supercell's impostor (Fire & Neon fix pass; SkyLayer.prepare draws it): a window in azimuth and altitude round
    // the view, its centre's azimuth in eq1.w and its half-width in eq2.w, its bottom and top altitudes in flash.y and
    // flash.z (radians); flash.w 1 + (3 × the older snapshot + the newer) + 0.9 × how far from the older to the newer
    // (0: none drawn). The texture holds three snapshots, each two halves: the storm's light and how much sky shows
    // through, then how its cloud takes the lightning's light.
    constexpr sampler cellImpostorSampler(filter::linear, address::clamp_to_edge);

    /// Snapshot `slot` at (x, y) 0…1 in the window: the storm, and in `recept` how it takes the lightning (read only
    /// while there is lightning, `flash`).
    float4 cellSnapshot(texture2d<float> cell, float x, float y, float slot, bool flash, thread float& recept) {
        float rows = float(cell.get_height());
        float H = rows / 6.0;
        float r = clamp(y * H, 0.5, H - 0.5) + 2.0 * slot * H;
        recept = flash ? cell.sample(cellImpostorSampler, float2(x, (r + H) / rows)).r : 0.0;
        return cell.sample(cellImpostorSampler, float2(x, r / rows));
    }

    /// The supercell along `d` from its impostor (as supercellSky gives it), and in `recept` how it takes the lightning.
    float4 supercellImpostor(float3 d, constant SkyU& u, texture2d<float> cell, thread float& recept) {
        recept = 0.0;
        float hw = max(u.eq2.w, 1e-3), lo = u.flash.y, hi = max(u.flash.z, u.flash.y + 1e-3);
        float da = atan2(d.x, d.y) - u.eq1.w;
        da -= 6.2831853 * floor((da + 3.14159265) / 6.2831853);
        float x = 0.5 + 0.5 * da / hw;
        float y = (asin(clamp(d.z, -1.0, 1.0)) - lo) / (hi - lo);
        if (x <= 0.0 || x >= 1.0 || y <= 0.0 || y >= 1.0) return float4(0.0, 0.0, 0.0, 1.0);
        // The older snapshot cross-fading into the newer.
        float q = max(u.flash.w - 1.0, 0.0);
        float idx = floor(q);
        float blend = saturate((q - idx) / 0.9);
        float older = floor(idx / 3.0), newer = idx - 3.0 * older;
        bool flash = u.cellB.z > 0.0;
        float4 s = cellSnapshot(cell, x, y, newer, flash, recept);
        if (blend < 0.999 && older != newer) {
            // (How it takes the lightning: the newer's alone, a flash being a moment.)
            float r0;
            s = mix(cellSnapshot(cell, x, y, older, false, r0), s, blend);
        }
        // (Its sides fade over the last 2%, past the view's own edge.)
        float fade = smoothstep(0.0, 0.02, x) * smoothstep(1.0, 0.98, x);
        recept *= fade;
        return float4(s.rgb * fade, 1.0 - fade * (1.0 - s.a));
    }

    /// The sky's light in direction `d` with the supercell from its impostor (`cell`, fragment texture
    /// SkyLayer.cellTextureIndex) when the sky's rows say it is drawn, else none: the worlds that draw it each frame read
    /// this; skyRadiance without the texture draws the storm itself (the worlds that don't).
    float3 skyRadiance(float3 d, constant SkyU& u, thread float& moonMask, texture2d<float> stars, texture2d<float> cell) {
        float amount = kSkyCell && d.z > -0.01 && u.flash.w > 0.5 ? saturate(u.cellA.w) : 0.0;
        float4 storm = float4(0.0, 0.0, 0.0, 1.0);
        if (kSkyCell && amount > 0.001) {
            float recept;
            storm = supercellImpostor(d, u, cell, recept);
            storm.rgb += supercellFlashLight(d, u, 1.0 - storm.a, recept);
        }
        return skyRadianceOver(d, u, moonMask, stars, amount, storm);
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
                                          texture2d<float> stars [[texture(0)]], texture2d<float> cell [[texture(9)]]) {
        float3 d = normalize(u.forward.xyz + u.right.xyz * in.ndc.x * u.right.w + u.up.xyz * in.ndc.y * u.up.w);
        float moonMask = 0.0;
        float3 col = d.z < 0.0 ? u.horizon.rgb * 0.6 : skyRadiance(d, u, moonMask, stars, cell);
        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    /// The supercell's impostor (SkyLayer.prepare): rows job.x, job.x + job.y, … of job.z in each half of the snapshot
    /// from row job.w, every column; the storm along each texel's direction in the window the sky's rows carry, at the
    /// impostor's own detail.
    kernel void sky_cell_impostor(texture2d<float, access::write> out [[texture(0)]], constant SkyU& u [[buffer(0)]],
                                  constant uint4& job [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), H = job.z;
        uint y = job.x + gid.y * job.y;
        if (gid.x >= W || y >= H) return;
        float hw = u.eq2.w, lo = u.flash.y, hi = u.flash.z;
        float az = u.eq1.w + hw * ((float(gid.x) + 0.5) / float(W) * 2.0 - 1.0);
        float el = lo + (hi - lo) * (float(y) + 0.5) / float(H);
        float3 d = float3(sin(az) * cos(el), cos(az) * cos(el), sin(el));
        // (A texel's own size, as the storm's edges are as sharp as one.)
        float texel = max(2.0 * hw / float(W) * cos(max(el, 0.0)), (hi - lo) / float(H));
        float recept = 0.0;
        float4 s = float4(0.0, 0.0, 0.0, 1.0);
        if (d.z > -0.03 && u.cellA.w > 0.0) s = supercellSky(d, u, u.forward.w, texel, 1.0, recept);
        out.write(s, uint2(gid.x, y + job.w));
        out.write(float4(recept, 0.0, 0.0, 1.0), uint2(gid.x, y + job.w + H));
    }

    // ---------------------------------------------------------------- weather
    // instance: pos.xy (NDC), size.x (length or radius), size.y (alpha); kind: 0 rain streak, 1 snow, 2 bead on glass,
    // 3 a ground streamer (blowing snow), 4 a firefly (radius of its soft glow), 5 a diamond-dust crystal, 6 one blob of a
    // sea-smoke wisp (its radius), 7 sea smoke's thin flat mist over the water's far edge (its half width in NDC x),
    // 8 an ember (its radius; alpha its heat), 9 an ash flake (its radius; it tumbles on the clock), 10 a hailstone's
    // short streak (its length). Kinds 8–10 carry the weather clock in tint.x.
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
        if (kind < 0.5 || kind > 9.5) {  // rain, and hail (a wider, shorter streak)
            float len = p.z, w = kind > 9.5 ? 0.0032 : 0.0016;
            float2 dir = normalize(float2(u.params.z, -1.0));
            float2 side = float2(-dir.y, dir.x);
            offset = dir * q.y * len * 0.5 + side * q.x * w;
            offset.x /= u.params.x;
        } else if (kind > 2.5 && kind < 3.5) {
            offset = float2(q.x * p.z * 0.5, q.y * 0.0035);
        } else if (kind > 6.5 && kind < 7.5) {   // sea smoke's flat mist: as wide as the water, a thin band high
            offset = float2(q.x * p.z, q.y * u.params.z);
        } else if (kind > 8.5) {         // an ash flake: turning, and tumbling (narrowing as it turns edge-on)
            float ph = fract(sin(float(iid) * 12.9898) * 43758.5453);
            float t = u.tint.x;
            float ang = ph * 6.2831853 + t * (0.6 + 1.4 * ph);
            float flip = 0.3 + 0.7 * abs(cos(t * (0.9 + 1.3 * ph) + ph * 9.0));
            float2 r = float2(q.x * p.z, q.y * p.z * flip);
            offset = float2(r.x * cos(ang) - r.y * sin(ang), r.x * sin(ang) + r.y * cos(ang));
            offset.x /= u.params.x;
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
        if (in.kind > 7.5) {
            if (in.kind > 9.5) {         // hail: a short hard white streak
                a = (1.0 - in.uv.x * in.uv.x) * smoothstep(1.0, 0.35, abs(in.uv.y)) * in.alpha;
                col = float3(0.93, 0.96, 1.0);
            } else if (in.kind > 8.5) {  // an ash flake: a soft, lumpy grey flake
                float r = length(in.uv) * (1.0 + 0.16 * sin(atan2(in.uv.y, in.uv.x) * 3.0 + in.alpha * 40.0));
                a = smoothstep(1.0, 0.4, r) * in.alpha * 0.85;
                col = float3(0.4, 0.38, 0.35);   // ash is dark (an albedo a third of snow's)
            } else {                     // an ember: a hot core in a soft glow, cooling from orange to a dull red
                float r2 = dot(in.uv, in.uv);
                a = saturate(exp(-r2 * 10.0) + 0.3 * exp(-r2 * 3.0)) * smoothstep(1.0, 0.8, sqrt(r2)) * in.alpha;
                col = mix(float3(0.9, 0.16, 0.03), float3(1.0, 0.62, 0.22), saturate(in.alpha * 1.2));
            }
            return float4(col * u.params.w * a, a);
        }
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
