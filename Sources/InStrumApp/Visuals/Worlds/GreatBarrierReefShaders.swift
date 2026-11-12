/// Metal source for Great Barrier Reef (spec §9.1–§9.3): a split view at the waterline of a coral cay's lagoon.
///
/// Above the rolling meniscus (`reef_above_fragment`): the Living Sky over the Coral Sea (skyRadiance, so the moon,
/// stars and shooting stars are all in it), the low white cay with its pisonia crowns and beach-grass fringe, the far
/// reef crest breaking white on the horizon, terns and noddies wheeling by day, and the lagoon's surface at a grazing
/// angle mirroring all of it (the mirror samples skyRadiance too, so whatever the sky draws reflects).
///
/// Below it (`reef_below_fragment`): the reef in clear water, built on the Underwater Kit (waterView, waterLight,
/// throughWater, caustics, lightShafts, snellWindow, waterAdapt): pale sand with caustics, far bommies in the blue,
/// and Coral Pulse's seven coral groups on a 2½-D stage (the stage's units are the water's height on screen, x across
/// from the frame's left edge, y up from the water's bottom edge, as `CoralPulse` lays them out): brain corals for the
/// bass, plate and soft corals in the middle, staghorn for the treble, a giant clam and the reef's rubble base. Their
/// polyps fluoresce in each group's colour as you play; at night they open and glow softly. Just under the meniscus,
/// the underside of the surface mirrors the reef (total internal reflection), with the spawn's slick and the rain's
/// silver dimples on it.
///
/// `reef_dot_vertex`/`reef_dot_fragment`: the school, the chromis over the staghorn, the spawn's beads and the marine
/// snow (instanced; clipped to the water). `reef_keys_*`: the strip of wet sand along the bottom edge.
///
/// Smooth rules: no ray marching; at most 2 noise octaves anywhere here (3 on the brain corals' maze on High); no `pow`.
enum GreatBarrierReefShaders {
    static let source = SkyShaders.common + UnderwaterShaders.common + """
    struct ReefU {
        float4 frame;       // aspect, key top (NDC), the waterline at rest (NDC), the water's bottom edge (NDC)
        float4 phases;      // the swell's four phases (radians, wrapped)
        float4 surface;     // the swell's lift scale (NDC), the wash (NDC: the lens going under), the under view's eye level (NDC), time (s)
        float4 camera;      // the level view's forward (east, north), tanH, tanV
        float4 light;       // the light falling on the surface (rgb), day 0…1
        float4 sun;         // direction (east-north-up), weight 0…1
        float4 sunColour;   // rgb, night 0…1
        float4 moon;        // direction, weight 0…1
        float4 moonColour;  // rgb, sparkle scale (gentle visuals halve it)
        float4 ambient;     // the sky's light from all round (rgb), haze 0…1
        float4 lagoon;      // the above view's horizon (NDC), the eye's height over the lagoon (m), roughness 0…1, octaves
        float4 weather;     // rain, cloud cover, storm 0…1, mist
        float4 reef;        // polyps open 0…1, unused, glow gain, patches drawn
        float4 wave;        // the colour wave's fronts (frame x 0…1: left, right), their width, strength (limited)
        float4 waveColour;  // rgb, the school's flash (limited)
        float4 spawn;       // the slick 0…1, the spawn's intensity, the light shafts' strength, a spawning burst's haze 0…1
        float4 cay;         // the cay's azimuth (radians), the view's azimuth (radians), the birds' visibility, unused
        float4 groups[7];   // per coral group: centre x, top, half-width (stage units), glow 0…1 (limited)
        float4 hues[7];     // per group: its fluorescence (linear rgb, fully saturated), kind (0 brain, 1 plate, 2 soft, 3 staghorn)
        float4 patches[64]; // lit polyp patches: x, y (stage units), group, brightness
    };

    struct ReefOut { float4 pos [[position]]; float2 ndc; };

    vertex ReefOut reef_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
        ReefOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    // ---------------------------------------------------------------- shared geometry
    /// The lens sits this far under the surface in the view below (m); the sand lies this far under the lens.
    constant float kEyeDepth = 0.3;
    constant float kSandBelow = 1.7;
    /// The near reef stands about this far from the lens (m), its corals this deep.
    constant float kReefDistance = 1.8;
    constant float kReefDepth = 1.2;

    /// Where the water's surface meets the lens at screen x (NDC): the waterline at rest, rolled by the swell's four
    /// components (the lens's own lift at x = 0) and a fine capillary wobble, raised by the wash when the lens goes under.
    float reefMeniscus(float x, constant ReefU& r) {
        float X = x * r.frame.x * 0.5;
        float4 p = r.phases;
        float lift = 0.4 * sin(p.x + 1.1 * X) + 0.3 * sin(p.y - 0.8 * X) + 0.2 * sin(p.z + 2.3 * X) + 0.1 * sin(p.w - 3.7 * X);
        float t = r.surface.w;
        float wobble = 0.0025 * sin(9.0 * X + 2.1 * t) + 0.0015 * sin(17.0 * X - 3.3 * t + 1.7);
        return r.frame.z + r.surface.x * lift + wobble * (0.5 + r.weather.z) + r.surface.y;
    }

    /// A screen point on the reef's stage: (stage units from the frame's left edge, water heights up from its bottom).
    float2 reefStage(float2 ndc, constant ReefU& r) {
        float h = max(r.frame.z - r.frame.w, 0.05);
        return float2((ndc.x + 1.0) * r.frame.x / h, (ndc.y - r.frame.w) / h);
    }

    /// The view below the surface: level, toward the same azimuth as the sky above, its eye level at surface.z.
    float3 reefUnderRay(float2 ndc, constant ReefU& r) {
        float2 f = r.camera.xy;
        float3 fwd = float3(f, 0.0), right = float3(f.y, -f.x, 0.0);
        return normalize(fwd + right * (ndc.x * r.camera.z) + float3(0.0, 0.0, 1.0) * ((ndc.y - r.surface.z) * r.camera.w));
    }

    float reefWrap(float a) {
        return a - 6.2831853 * floor((a + 3.14159265) / 6.2831853);
    }

    float reefFresnel(float c) {
        float k = 1.0 - saturate(c);
        float k2 = k * k;
        return 0.02 + 0.98 * k2 * k2 * k;
    }

    // ---------------------------------------------------------------- above the water
    /// The cay: a low white island of coral sand with a few broad pisonia crowns and a fringe of beach grass, 300 m
    /// off (azimuths and altitudes in degrees, `phi` from its middle). Returns its colour and its coverage.
    constant float4 kCrowns[7] = {
        float4(-8.6, 1.05, 1.9, 0.0), float4(-5.7, 1.62, 2.3, 1.0), float4(-2.9, 2.12, 2.5, 2.0), float4(-0.1, 2.38, 2.7, 3.0),
        float4(2.7, 1.92, 2.3, 4.0), float4(5.3, 1.48, 2.0, 5.0), float4(7.7, 0.98, 1.7, 6.0)
    };

    float4 reefCay(float phi, float alt, float pxDeg, constant SkyU& u, constant ReefU& r) {
        float halfWidth = 11.5;
        if (abs(phi) > halfWidth + 0.5 || alt > 2.8 || alt < -0.08) return float4(0);
        float edge = 1.0 - phi * phi / (halfWidth * halfWidth);
        float sandTop = 0.03 + 0.2 * sqrt(max(edge, 0.0));
        // The crowns: rounded, dense, overlapping; a leafy edge (one octave) so no outline is a clean arc.
        float veg = -1.0, nearest = 0.0;
        float2 crownN = float2(0.0, 1.0);
        for (int i = 0; i < 7; i++) {
            float4 c = kCrowns[i];
            float x = (phi - c.x) / c.z;
            if (abs(x) >= 1.0) continue;
            float top = sandTop * 0.7 + (c.y - sandTop * 0.7) * sqrt(1.0 - x * x);
            if (top > veg) {
                veg = top; nearest = c.w;
                float y = saturate((alt - sandTop) / max(c.y - sandTop, 0.1));
                crownN = normalize(float2(x, 0.4 + 0.8 * y));
            }
        }
        float leafy = vnoise3(float3(phi * 3.1, alt * 5.0, 2.7)) - 0.5;
        veg += 0.09 * leafy;
        float inVeg = veg > 0.0 ? 1.0 - smoothstep(veg - pxDeg, veg + pxDeg, alt) : 0.0;
        // The beach grass: a fine spiky fringe along the foot of the trees and a little beyond them on the berm.
        float grassTop = sandTop + (0.1 + 0.08 * vnoise3(float3(phi * 2.0, 0.5, 9.1))) * (abs(phi) < halfWidth - 0.8 ? 1.0 : 0.0);
        float blade = abs(fract(phi * 7.3 + 0.4 * sin(phi * 2.1)) - 0.5) * 2.0;
        float grassH = grassTop - 0.07 * blade;
        float inGrass = (1.0 - smoothstep(grassH - pxDeg, grassH + pxDeg, alt)) * step(sandTop * 0.8, alt + 0.5 * pxDeg);
        float inSand = (1.0 - smoothstep(sandTop - pxDeg, sandTop + pxDeg, alt)) * (abs(phi) < halfWidth ? 1.0 : 0.0);
        float cover = max(max(inVeg, inGrass), inSand);
        if (cover <= 0.0) return float4(0);

        // Light: the sun (or moon) from its side of the island, and the sky all round.
        float3 S = r.sun.xyz, M = r.moon.xyz;
        float sunW = r.sun.w, moonW = r.moon.w;
        float cayAz = r.cay.x;
        float sunSide = sin(atan2(S.x, S.y) - cayAz), moonSide = sin(atan2(M.x, M.y) - cayAz);
        float3 sky = r.ambient.rgb;
        float3 sunL = r.sunColour.rgb * sunW, moonL = r.moonColour.rgb * moonW;
        float sunUp = saturate(S.z * 1.6 + 0.08), moonUp = saturate(M.z * 1.6 + 0.08);
        float3 sand = float3(0.92, 0.88, 0.78) * (sunL * (0.35 + 0.65 * sunUp) * 0.9 + moonL * 0.9 * moonUp + sky * 0.55);
        float litSun = saturate(0.5 + 0.5 * (crownN.x * sunSide + crownN.y * (0.3 + sunUp)));
        float litMoon = saturate(0.5 + 0.5 * (crownN.x * moonSide + crownN.y * (0.3 + moonUp)));
        float tint = fract(nearest * 0.37);
        float3 leaf = mix(float3(0.045, 0.10, 0.035), float3(0.07, 0.13, 0.04), tint);
        float3 trees = leaf * (sunL * (0.15 + 1.1 * litSun) + moonL * (0.2 + 0.9 * litMoon) + sky * 0.35);
        float3 grass = float3(0.32, 0.36, 0.14) * (sunL * (0.3 + 0.9 * sunUp) + moonL * 0.6 + sky * 0.5);
        // The trees stand behind the beach: the grass in front of their feet, the sand berm in front of both.
        float3 col = trees;
        col = mix(col, grass, inGrass);
        col = mix(col, sand, inSand);
        // 300 m of sea air.
        float haze = 0.08 + 0.5 * r.weather.w + 0.35 * r.weather.z;
        col = mix(col, u.horizon.rgb, saturate(haze));
        return float4(col, cover);
    }

    /// The reef crest on the horizon: the ocean swell breaking in a white line, sets running along it with the swell,
    /// broken by the channels, and its spray above. `az` is the world azimuth (radians), `alt` degrees.
    float4 reefCrest(float az, float alt, float pxDeg, constant ReefU& r) {
        if (alt > 0.6 || alt < -0.12) return float4(0);
        float A = az * 9.5493;                                   // azimuth in units of 6°
        float gaps = smoothstep(0.4, 0.56, vnoise3(float3(A * 0.55, 1.3, 4.1)));
        if (gaps <= 0.0) return float4(0);
        float4 p = r.phases;
        float sets = 0.55 + 0.45 * sin(p.x + A * 0.8) * sin(p.y * 0.7 - A * 0.33 + 1.1);
        float storm = r.weather.z;
        float thick = (0.045 + 0.08 * storm) * (0.5 + 0.5 * sets);
        float band = 1.0 - smoothstep(thick - pxDeg, thick + pxDeg, abs(alt - thick * 0.5));
        float spray = exp(-max(alt, 0.0) / (0.1 + 0.2 * storm)) * (0.15 + 0.45 * storm) * sets;
        float k = saturate(band * (0.55 + 0.45 * sets) + spray * 0.6) * gaps;
        float3 foam = r.sunColour.rgb * r.sun.w * (0.45 + 0.55 * saturate(r.sun.z * 2.0)) + r.moonColour.rgb * r.moon.w * 0.8
                    + r.ambient.rgb * 0.7;
        return float4(foam * 0.6, k);
    }

    /// Terns and noddies wheeling over the cay by day: seven small birds on lazy loops, each flapping on its own beat.
    float4 reefBirds(float phi, float alt, float pxDeg, constant ReefU& r) {
        float vis = r.cay.z;
        if (vis <= 0.0 || alt < 0.6 || alt > 9.0 || abs(phi) > 18.0) return float4(0);
        float t = r.surface.w;
        float4 acc = float4(0);
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            float3 h = hash33(float3(fi, 4.2, 1.9));
            float speed = (0.18 + 0.22 * h.x) * (h.y > 0.5 ? 1.0 : -1.0);
            float a = t * speed + 6.2831853 * h.z;
            float2 centre = float2(-4.0 + 8.0 * h.y, 3.4 + 2.4 * h.x);
            float2 at = centre + float2((3.5 + 3.0 * h.z) * cos(a), (0.9 + 0.8 * h.x) * sin(a));
            float size = 0.3 + 0.16 * h.y;
            float2 q = (float2(phi, alt) - at) / size;
            if (abs(q.x) > 1.3 || abs(q.y) > 1.0) continue;
            // An "m": two wings from the body, raised and lowered as it flaps, with a soft droop to each tip.
            float flap = sin(t * (5.5 + 3.0 * h.x) + 6.2831853 * h.y);
            float ax = abs(q.x);
            float wing = (0.25 + 0.4 * flap) * ax - (0.15 + 0.25 * flap) * ax * ax;
            float dist = abs(q.y - wing) - 0.11 * (1.0 - 0.6 * ax);
            float k = (1.0 - smoothstep(-pxDeg / size, pxDeg / size, dist)) * step(ax, 1.0);
            // Terns are white, lit by the sun; noddies are dark.
            float3 c = h.z > 0.45 ? (r.sunColour.rgb * r.sun.w * 0.8 + r.ambient.rgb * 0.6) : r.ambient.rgb * 0.12;
            acc.rgb = mix(acc.rgb, c, k);
            acc.a = max(acc.a, k);
        }
        acc.a *= vis;
        return acc;
    }

    /// Everything along `d` above the horizon: the sky (and in it the sun, moon, stars, aurora and shooting stars),
    /// the crest, the cay and (seen directly) the birds.
    float3 reefSkyShore(float3 d, constant SkyU& u, constant ReefU& r, texture2d<float> stars, float pxDeg, bool birds) {
        float mm;
        float3 col = skyRadiance(d, u, mm, stars);
        float alt = asin(clamp(d.z, -1.0, 1.0)) * 57.29578;
        if (alt < 9.0) {
            float az = atan2(d.x, d.y);
            float phi = reefWrap(az - r.cay.x) * 57.29578;
            float4 crest = reefCrest(az, alt, pxDeg, r);
            col = mix(col, crest.rgb, crest.a);
            float4 cay = reefCay(phi, alt, pxDeg, u, r);
            col = mix(col, cay.rgb, cay.a);
            if (birds) {
                float4 b = reefBirds(phi, alt, pxDeg, r);
                col = mix(col, b.rgb, b.a);
            }
        }
        return col;
    }

    /// The lagoon's surface at a grazing angle: a mirror of the sky and the shore (Fresnel), the swell's long rolls
    /// and the wind's ripples on it (finer ripples than a pixel's patch of water settle out), the sun's and the moon's
    /// glitter paths, and the shallow turquoise water over white sand nearer the lens.
    float3 reefLagoon(float3 d, constant SkyU& u, constant ReefU& r, texture2d<float> stars, thread float& depthOut) {
        float h = r.lagoon.y;
        float s = h / max(-d.z, 1e-4);
        float2 q = d.xy * s;
        float foot = s * u.weather.w / max(-d.z, 0.002);
        float t = r.surface.w;
        float4 ph = r.phases;
        float2 fwd = r.camera.xy;
        float along = dot(q, fwd), across = dot(q, float2(fwd.y, -fwd.x));
        float storm = r.weather.z, rough = r.lagoon.z;
        // The swell's long rolls (fading where they are finer than the pixel's patch).
        float2 slope = float2(0);
        float swell = (0.012 + 0.09 * storm) * (1.0 - smoothstep(0.6, 3.0, foot));
        slope += fwd * (swell * cos(0.55 * along + ph.x) + 0.6 * swell * cos(0.9 * along - 0.35 * across + ph.y));
        // The wind's ripples: two octaves of drifting noise.
        float2 g = float2(0.8 * q.x - 0.6 * q.y, 0.6 * q.x + 0.8 * q.y) * 1.7 + float2(t * 0.35, -t * 0.22);
        float k1 = 1.0 - smoothstep(0.12, 0.5, foot * 1.7);
        if (k1 > 0.0) slope += (float2(vnoise3(float3(g, t * 0.5)), vnoise3(float3(g + 7.3, t * 0.5 + 2.1))) - 0.5) * (0.035 + 0.2 * rough) * k1;
        float k2 = r.lagoon.w > 2.5 ? 1.0 - smoothstep(0.12, 0.5, foot * 4.3) : 0.0;
        if (k2 > 0.0) {
            float2 g2 = float2(0.28 * g.x + 0.96 * g.y, -0.96 * g.x + 0.28 * g.y) * 2.5 + 3.3;
            slope += (float2(vnoise3(float3(g2, t * 0.9)), vnoise3(float3(g2 + 4.1, t * 0.9 + 1.7))) - 0.5) * (0.018 + 0.1 * rough) * k2;
        }
        float3 n = normalize(float3(-slope, 1.0));
        float3 R = reflect(d, n);
        R.z = max(R.z, 0.0015);
        R = normalize(R);
        float F = reefFresnel(saturate(-dot(d, n)));
        float pxDeg = u.weather.w * 57.29578 * (1.0 + 2.0 * rough);
        float3 mirror = reefSkyShore(R, u, r, stars, pxDeg, false);
        // The glitter paths: the sun's (warm at dusk) and the moon's, sparkling where the ripples tip toward them.
        float sparkle = r.moonColour.w;
        float sd = dot(R, r.sun.xyz), md = dot(R, r.moon.xyz);
        float3 glitter = r.sunColour.rgb * (r.sun.w * (exp((sd - 1.0) * 1800.0) * 40.0 + exp((sd - 1.0) * 90.0) * 0.6))
                       + r.moonColour.rgb * (r.moon.w * (exp((md - 1.0) * 2600.0) * 14.0 + exp((md - 1.0) * 160.0) * 0.25));
        glitter *= sparkle;
        // The lagoon's own colour: light down to white sand and back, turquoise, darker over the bommies in it.
        float bommies = smoothstep(0.5, 0.72, vnoise3(float3(q * 0.22, 5.5)));
        float shallow = exp(-s / 40.0);
        float3 body = float3(0.16, 0.76, 0.70) * (0.45 + 0.55 * shallow) * (1.0 - 0.45 * bommies * shallow);
        float3 daylight = r.light.rgb;
        float3 col = mirror * F + body * daylight * 1.1 * (1.0 - F) + glitter;
        // Distance: the far water hazes into the horizon.
        col = mix(col, u.horizon.rgb * 0.92, saturate(r.ambient.w * (1.0 - exp(-s / 900.0))));
        depthOut = saturate(s / 300.0);
        return col;
    }

    fragment ColorDepth reef_above_fragment(ReefOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                            constant ReefU& r [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float ym = reefMeniscus(in.ndc.x, r);
        float px = u.weather.w / max(u.up.w, 1e-4);   // one pixel in NDC: the pixel angle over tanV
        float edge = smoothstep(ym - 0.5 * px, ym + 1.0 * px, in.ndc.y);
        if (edge <= 0.0) discard_fragment();
        float3 d = normalize(u.forward.xyz + u.right.xyz * (in.ndc.x * u.right.w) + u.up.xyz * (in.ndc.y * u.up.w));
        float pxDeg = u.weather.w * 57.29578;
        float3 col;
        float depth = 1.0;
        if (d.z >= 0.0) {
            col = reefSkyShore(d, u, r, stars, pxDeg, true);
        } else {
            col = reefLagoon(d, u, r, stars, depth);
        }
        // The meniscus: water clinging to the lens just over the waterline, a bright thin rim of sky caught in its curve
        // and a soft shadow under the film above it.
        float above = (in.ndc.y - ym) / px;
        float rim = exp(-above * above / 2.5);
        float film = exp(-(above - 6.0) * (above - 6.0) / 12.0);
        col = col * (1.0 - 0.22 * film) + (r.ambient.rgb * 0.5 + r.light.rgb * 0.12) * (0.8 * rim);
        ColorDepth o;
        o.color = float4(col * edge, edge);
        o.depth = float4(depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- below the water
    /// White coral sand on the lagoon floor along `d` (pointing down) from the lens: lit from above through the
    /// caustics, its ripple marks across the current, a few dark fragments of rubble; seen through the water between.
    float3 reefSand(float3 d, constant SkyU& u, constant ReefU& r, float fromDepth, float below, thread float& dist) {
        float s = below / max(-d.z, 1e-3);
        dist = s;
        float3 L = r.light.rgb;
        if (s > 120.0) return waterView(d, fromDepth, L);
        float3 p = float3(d.xy * s, -(fromDepth + below));
        float t = r.surface.w;
        float foot = s * u.weather.w / max(-d.z, 0.05);
        // (By moonlight the net is fainter: the eye sees little contrast at night.)
        float caus = mix(1.0, caustics(p, t, foot), 0.45 + 0.55 * r.light.w);
        // Ripple marks: low ridges across the current, wandering a little, settling out where finer than a pixel.
        float settle = 1.0 - smoothstep(0.05, 0.3, foot * 2.4);
        float rip = sin(p.x * 2.4 + 1.3 * sin(p.y * 0.7) + 0.4 * sin(p.y * 1.9 + 1.1)) * settle;
        float shade = 0.82 + 0.18 * rip;
        float2 cell = floor(p.xy * 3.0);
        float rubble = step(0.965, hash13(float3(cell, 2.2))) * settle;
        float3 albedo = mix(float3(0.88, 0.84, 0.72), float3(0.42, 0.36, 0.33), rubble);
        float3 lit = waterLight(fromDepth + below, L) * (0.62 * caus * shade + 0.25) + waterLight(fromDepth, L) * kWaterTint * 0.35;
        return throughWater(albedo * lit, fromDepth + 0.5 * below, s, L);
    }

    /// The far bommies: big coral heads rising from the sand off in the blue, nearly lost in it. Screen-fixed.
    constant float4 kBommies[4] = {
        float4(-0.82, 15.0, 3.2, 1.3), float4(-0.24, 22.0, 4.5, 1.8), float4(0.38, 13.0, 2.4, 1.1), float4(0.86, 19.0, 3.8, 1.6)
    };

    float4 reefBommie(float2 ndc, constant ReefU& r) {
        float tanH = r.camera.z, tanV = r.camera.w;
        float eye = r.surface.z;
        float4 best = float4(0);
        for (int i = 0; i < 4; i++) {
            float4 b = kBommies[i];
            float dist = b.y;
            float cx = b.x, halfW = 0.5 * b.z / dist / tanH;
            float x = (ndc.x - cx) / halfW;
            if (abs(x) > 1.2) continue;
            float base = eye - (kSandBelow / dist) / tanV;
            float topY = eye - ((kSandBelow - b.w) / dist) / tanV;
            float lump = 0.12 * (vnoise3(float3(x * 3.0, float(i) * 3.7, 1.0)) - 0.5);
            float prof = sqrt(max(0.0, 1.0 - x * x)) * (0.85 + 0.15 * cos(x * 5.0 + float(i))) + lump;
            float y = (ndc.y - base) / max(topY - base, 1e-4);
            if (y < -0.05 || y > prof) continue;
            if (dist > best.y && best.x > 0.0) continue;
            best = float4(1.0, dist, y, x);
        }
        return best;
    }

    /// A coral's look at a stage point: how much it covers it (anti-aliased), its colour by daylight, its surface's
    /// facing (x right, y up, z toward the lens), where its polyps are (they fluoresce there) and how open to the light
    /// from above it is (for the caustics).
    struct CoralLook { float cover; float3 albedo; float3 n; float polyp; float open; };

    constant float4 kStagSeg[60] = {
        float4(-0.362, 0.000, -0.505, 0.318), float4(-0.505, 0.318, -0.679, 0.539), float4(-0.679, 0.539, -0.832, 0.682),
        float4(-0.832, 0.682, -0.950, 0.763), float4(-0.832, 0.682, -0.892, 0.828), float4(-0.679, 0.539, -0.720, 0.725),
        float4(-0.720, 0.725, -0.773, 0.841), float4(-0.720, 0.725, -0.698, 0.870), float4(-0.505, 0.318, -0.538, 0.601),
        float4(-0.538, 0.601, -0.634, 0.797), float4(-0.634, 0.797, -0.726, 0.913), float4(-0.634, 0.797, -0.662, 0.956),
        float4(-0.538, 0.601, -0.517, 0.796), float4(-0.517, 0.796, -0.536, 0.926), float4(-0.517, 0.796, -0.466, 0.931),
        float4(-0.128, 0.000, -0.173, 0.371), float4(-0.173, 0.371, -0.287, 0.631), float4(-0.287, 0.631, -0.414, 0.809),
        float4(-0.414, 0.809, -0.521, 0.918), float4(-0.414, 0.809, -0.439, 0.986), float4(-0.287, 0.631, -0.288, 0.851),
        float4(-0.288, 0.851, -0.326, 1.000), float4(-0.288, 0.851, -0.253, 0.995), float4(-0.173, 0.371, -0.102, 0.632),
        float4(-0.102, 0.632, -0.126, 0.825), float4(-0.126, 0.825, -0.194, 0.965), float4(-0.126, 0.825, -0.113, 0.960),
        float4(-0.102, 0.632, 0.004, 0.800), float4(0.004, 0.800, 0.019, 0.943), float4(0.004, 0.800, 0.098, 0.918),
        float4(0.085, 0.000, 0.137, 0.366), float4(0.137, 0.366, 0.099, 0.612), float4(0.099, 0.612, 0.024, 0.800),
        float4(0.024, 0.800, -0.057, 0.911), float4(0.024, 0.800, 0.014, 0.937), float4(0.099, 0.612, 0.114, 0.807),
        float4(0.114, 0.807, 0.091, 0.952), float4(0.114, 0.807, 0.159, 0.935), float4(0.137, 0.366, 0.251, 0.590),
        float4(0.251, 0.590, 0.265, 0.760), float4(0.265, 0.760, 0.241, 0.876), float4(0.265, 0.760, 0.307, 0.893),
        float4(0.251, 0.590, 0.368, 0.724), float4(0.368, 0.724, 0.397, 0.844), float4(0.368, 0.724, 0.474, 0.818),
        float4(0.320, 0.000, 0.480, 0.323), float4(0.480, 0.323, 0.521, 0.615), float4(0.521, 0.615, 0.497, 0.821),
        float4(0.497, 0.821, 0.437, 0.955), float4(0.497, 0.821, 0.518, 0.958), float4(0.521, 0.615, 0.592, 0.826),
        float4(0.592, 0.826, 0.598, 0.994), float4(0.592, 0.826, 0.674, 0.967), float4(0.480, 0.323, 0.666, 0.513),
        float4(0.666, 0.513, 0.738, 0.713), float4(0.738, 0.713, 0.746, 0.858), float4(0.738, 0.713, 0.837, 0.849),
        float4(0.666, 0.513, 0.807, 0.631), float4(0.807, 0.631, 0.864, 0.768), float4(0.807, 0.631, 0.927, 0.719)
    };
    // Radii at each end (× the coral's top) and whether the segment ends in a growing tip.
    constant float3 kStagRad[60] = {
        float3(0.070, 0.056, 0.0), float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0),
        float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0),
        float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0),
        float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.070, 0.056, 0.0),
        float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0),
        float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.056, 0.045, 0.0),
        float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0),
        float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.070, 0.056, 0.0), float3(0.056, 0.045, 0.0),
        float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0),
        float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0),
        float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0),
        float3(0.036, 0.029, 1.0), float3(0.070, 0.056, 0.0), float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0),
        float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0),
        float3(0.036, 0.029, 1.0), float3(0.056, 0.045, 0.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0),
        float3(0.036, 0.029, 1.0), float3(0.045, 0.036, 0.0), float3(0.036, 0.029, 1.0), float3(0.036, 0.029, 1.0)
    };

    /// Brain coral (the bass): a rounded boulder, its surface a maze of meandering ridges whose grooves hold the polyps.
    CoralLook reefBrain(float2 P, float4 g, float seed, float px, float t, float fuzz, int octaves) {
        CoralLook c;
        c.cover = 0.0;
        float2 q = float2((P.x - g.x) / g.z, P.y / g.y);
        if (abs(q.x) > 1.25 || q.y > 1.3 || q.y < -0.1) return c;
        float lump = 0.07 * (vnoise3(float3(q * 2.3, seed)) - 0.5);
        float2 e = float2(q.x, max(q.y, 0.0) * 1.02);
        float rho = length(e);
        float sdf = (rho - (1.0 + lump)) * min(g.y, g.z);
        // At night the polyps reach out from the grooves: a soft fuzz round the outline.
        sdf -= fuzz * 0.008 * (0.5 + vnoise3(float3(q * 18.0, seed + 3.0)));
        c.cover = (1.0 - smoothstep(-px, px, sdf)) * smoothstep(-0.06, 0.0, q.y);
        if (c.cover <= 0.0) return c;
        float zz = sqrt(max(0.0, 1.0 - min(rho * rho, 1.0)));
        c.n = normalize(float3(q.x * g.y / g.z, q.y, zz + 0.05));
        // The maze: contour lines of a smooth noise field (the grooves where they bunch, the ridges between).
        float n1 = vnoise3(float3(q * 2.6, seed + 11.0));
        n1 += 0.5 * vnoise3(float3(q * 5.3 + 3.1, seed + 13.0));
        if (octaves > 2) n1 += 0.25 * vnoise3(float3(q * 10.9 + 7.7, seed + 17.0));
        float band = abs(fract(n1 * 5.5) - 0.5) * 2.0;
        float groove = 1.0 - smoothstep(0.12, 0.42, band);
        float3 ridge = mix(float3(0.66, 0.55, 0.30), float3(0.58, 0.50, 0.36), fract(seed * 0.71));
        float3 valley = float3(0.26, 0.40, 0.20);
        c.albedo = mix(ridge, valley, groove) * (0.85 + 0.15 * zz);
        c.polyp = 0.3 + 0.7 * groove;
        c.open = saturate(c.n.y * 0.8 + c.n.z * 0.4);
        return c;
    }

    /// Plate coral: tiers of flat tables on a short stalk, seen a little from above; polyps along the rims.
    CoralLook reefPlate(float2 P, float4 g, float seed, float px, float t, float fuzz) {
        CoralLook c;
        c.cover = 0.0;
        float x = P.x - g.x;
        if (abs(x) > 1.25 * g.z || P.y > 1.2 * g.y) return c;
        float3 under = float3(0.30, 0.26, 0.24);
        // The stalk.
        float stalkR = 0.08 * g.z * (1.0 - 0.35 * saturate(P.y / (0.5 * g.y)));
        float sd = (abs(x + 0.03 * g.z * sin(P.y * 9.0)) - stalkR);
        float stalk = (1.0 - smoothstep(-px, px, sd)) * step(P.y, 0.5 * g.y) * step(-0.01, P.y);
        c.cover = stalk;
        c.albedo = float3(0.48, 0.42, 0.34);
        c.n = normalize(float3(sign(x) * saturate(abs(x) / max(stalkR, 1e-4)), 0.0, 1.0));
        c.polyp = 0.15;
        c.open = 0.1;
        // Three tables, the top one widest, each a thin ellipse of top surface over a darker rim.
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float yi = g.y * (0.5 + 0.25 * fi);
            float wi = g.z * (0.62 + 0.19 * fi) * (0.92 + 0.16 * fract(seed * (3.1 + fi)));
            float ci = g.z * (0.12 * sin(seed * 5.0 + fi * 2.3));
            float k = 0.13;                                  // how much of its top we see
            float thick = 0.06 * g.y;
            float2 a = float2((x - ci) / wi, (P.y - yi) / (k * wi));
            float lip = 0.05 * sin(atan2(a.y, a.x) * 7.0 + seed) ;
            float rTop = length(a);
            float topSD = (rTop - (1.0 + lip)) * k * wi;
            float inTop = 1.0 - smoothstep(-px, px, topSD);
            float2 b = float2(a.x, (P.y - (yi - thick)) / (k * wi));
            float rimSD = (length(b) - (1.0 + lip)) * k * wi;
            float inRim = (1.0 - smoothstep(-px, px, rimSD)) * step(P.y, yi);
            float body = max(inTop, inRim);
            if (body <= 0.0) continue;
            float edgeRing = smoothstep(0.72, 1.0, rTop);
            float radial = vnoise3(float3(a * float2(14.0, 9.0), seed + fi));
            // The lower tables lie in the shade of the ones over them.
            float3 top = mix(float3(0.62, 0.55, 0.42), float3(0.50, 0.46, 0.52), edgeRing) * (0.88 + 0.12 * radial) * (1.0 - 0.16 * (2.0 - fi));
            float frill = 0.5 + 0.5 * sin(a.x * 38.0 + seed * 3.0);
            float3 rimC = mix(under, float3(0.55, 0.42, 0.50), 0.3 + 0.3 * frill);
            float isTop = inTop > inRim ? 1.0 : saturate(inTop / max(body, 1e-4));
            c.albedo = mix(c.albedo, mix(rimC, top, isTop), body);
            c.n = normalize(mix(float3(a.x * 0.3, -0.2, 1.0), float3(a.x * 0.15, 1.0, 0.25), isTop));
            c.polyp = mix(c.polyp, mix(0.6, 0.3 + 0.7 * edgeRing, isTop) * (0.7 + 0.3 * radial), body);
            c.open = mix(c.open, isTop, body);
            c.cover = max(c.cover, body);
        }
        return c;
    }

    /// Soft coral: a clump of finger lobes swaying in the surge; polyps all over them.
    CoralLook reefSoft(float2 P, float4 g, float seed, float px, float t, float fuzz) {
        CoralLook c;
        c.cover = 0.0;
        float x = P.x - g.x;
        if (abs(x) > 1.4 * g.z || P.y > 1.25 * g.y) return c;
        float best = 1e3, along = 0.0, lean = 0.0;
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            float3 h = hash33(float3(fi, seed, 7.7));
            float bx = g.z * (-0.55 + 1.1 * (fi + 0.5 * h.x) / 7.0);
            float height = g.y * (0.62 + 0.38 * h.y);
            float tilt = (bx / g.z) * 0.45 * g.z + 0.2 * g.z * (h.z - 0.5);
            float sway = 0.07 * g.z * sin(t * 0.7 + fi * 0.9 + seed);
            // Along the lobe (0 its foot … 1 its tip), bent by the surge toward its top.
            float v = saturate(P.y / height);
            float cx = bx + (tilt + sway) * v * v;
            float radius = g.z * (0.11 - 0.035 * v) * (0.9 + 0.2 * h.x);
            float dy = max(P.y - height, 0.0);
            float dx = x - cx;
            float d = sqrt(dx * dx + dy * dy) - radius;
            if (P.y < 0.0) d = max(d, -P.y);
            if (d < best) { best = d; along = v; lean = dx / max(radius, 1e-4); }
        }
        best -= fuzz * 0.006 * (0.5 + vnoise3(float3(P * 60.0, seed)));
        c.cover = 1.0 - smoothstep(-px, px, best);
        if (c.cover <= 0.0) return c;
        float fur = vnoise3(float3(P * 70.0, seed + 2.0));
        c.albedo = mix(float3(0.62, 0.44, 0.52), float3(0.82, 0.62, 0.70), along) * (0.85 + 0.15 * fur);
        float l = clamp(lean, -1.0, 1.0);
        c.n = normalize(float3(l, 0.35 + 0.4 * along, sqrt(max(0.0, 1.0 - l * l))));
        c.polyp = 0.45 + 0.55 * along * fur;
        c.open = 0.3 + 0.5 * along;
        return c;
    }

    /// Staghorn: branching antlers in pale cream, their growing tips blue; polyps brightest at the tips.
    CoralLook reefStaghorn(float2 P, float4 g, float mirror, float px, float t, float fuzz) {
        CoralLook c;
        c.cover = 0.0;
        float x = (P.x - g.x) * mirror;
        if (abs(x) > 1.05 * g.z || P.y > 1.08 * g.y || P.y < -0.01) return c;
        float best = 1e3, tip = 0.0, h = 0.0, side = 0.0;
        for (int i = 0; i < 60; i++) {
            float4 s = kStagSeg[i];
            float3 rad = kStagRad[i];
            float2 a = float2(s.x * g.z, s.y * g.y), b = float2(s.z * g.z, s.w * g.y);
            float2 pa = float2(x, P.y) - a, ba = b - a;
            float k = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
            float r0 = mix(rad.x, rad.y, k) * g.y * 0.62;
            float2 off = pa - ba * k;
            float d = length(off) - r0;
            if (d < best) {
                best = d;
                tip = rad.z * smoothstep(0.55, 1.0, k);
                h = mix(s.y, s.w, k);
                side = dot(off, float2(ba.y, -ba.x)) / max(length(ba) * r0, 1e-5);
            }
        }
        c.cover = 1.0 - smoothstep(-px, px, best);
        if (c.cover <= 0.0) return c;
        float sd = clamp(side, -1.0, 1.0);
        c.albedo = mix(mix(float3(0.42, 0.34, 0.26), float3(0.70, 0.62, 0.48), h), float3(0.50, 0.62, 0.95), tip);
        c.n = normalize(float3(sd * mirror, 0.15 + 0.3 * tip, sqrt(max(0.0, 1.0 - sd * sd))));
        c.polyp = 0.3 + 0.7 * tip;
        c.open = 0.35 + 0.5 * h;
        return c;
    }

    /// The giant clam between the brain corals and the first plates: its blue-green mantle in the gape of a fluted shell.
    float4 reefClam(float2 P, float2 at, float size, float px, float t, constant ReefU& r, thread float& mantle) {
        mantle = 0.0;
        float2 q = (P - at) / size;
        if (abs(q.x) > 1.3 || abs(q.y) > 0.9) return float4(0);
        float wave = 0.1 * sin(q.x * 9.0 + 0.6 * sin(t * 0.5));
        float shell = length(float2(q.x, q.y * 2.4)) - 1.0;
        float inShell = 1.0 - smoothstep(-px / size, px / size, shell);
        float gape = abs(q.y - wave) - 0.18 * (1.0 - q.x * q.x);
        float inMantle = (1.0 - smoothstep(-px / size, px / size, gape)) * inShell;
        mantle = inMantle;
        float flutes = 0.5 + 0.5 * sin(q.x * 22.0);
        float3 shellC = float3(0.70, 0.66, 0.56) * (0.8 + 0.2 * flutes);
        float spots = step(0.82, hash13(float3(floor(q * float2(14.0, 30.0)), 5.0)));
        float3 mantleC = mix(float3(0.06, 0.45, 0.52), float3(0.25, 0.75, 0.85), spots) + float3(0.05, 0.1, 0.35) * smoothstep(0.6, 1.0, abs(q.x));
        float3 col = mix(shellC, mantleC, inMantle);
        return float4(col, inShell);
    }

    /// The polyps: a fine scatter of small round mouths (cells a fiftieth of the water's height), where the
    /// fluorescence gathers.
    float reefPolyps(float2 P) {
        float2 q = P * 62.0;
        float2 i = floor(q), f = fract(q) - 0.5;
        float3 h = hash33(float3(i, 9.1));
        float d = length(f - (h.xy - 0.5) * 0.5) * (0.8 + 0.4 * h.z);
        return 1.0 - smoothstep(0.1, 0.32, d);
    }

    /// The reef's rubble base along the bottom, in front of the coral's feet: dead coral, pink coralline crusts.
    float reefBaseLine(float sx) {
        return 0.045 + 0.028 * vnoise3(float3(sx * 5.0, 1.3, 0.0)) + 0.014 * vnoise3(float3(sx * 17.0, 2.9, 0.0));
    }

    fragment ColorDepth reef_below_fragment(ReefOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                            constant ReefU& r [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float ym = reefMeniscus(in.ndc.x, r);
        float px = u.weather.w / max(u.up.w, 1e-4);
        if (in.ndc.y > ym + 1.5 * px) discard_fragment();
        float2 P = reefStage(in.ndc, r);
        float h = max(r.frame.z - r.frame.w, 0.05);
        float pxS = px / h;                                    // one pixel in stage units
        float3 d = reefUnderRay(in.ndc, r);
        float3 L = r.light.rgb;
        float t = r.surface.w;
        float D = kEyeDepth;
        float storm = r.weather.z;
        int octaves = int(r.lagoon.w + 0.5);
        float3 col;
        float depth = 1.0;
        float3 glow = float3(0);

        if (d.z > 0.0) {
            // The underside of the surface: past the critical angle it mirrors the water and the sand below, shimmering
            // with the waves (the Underwater Kit's window, here all mirror); the spawn's slick gathers on it, and rain
            // dimples it silver.
            float3 m = float3(d.x, d.y, -d.z);
            float3 mirror = waterView(m, 0.0, L) * 1.2;
            float window;
            // (The window opens a little above level: cross from the level water's glow to it, so no line shows.)
            float3 level = waterView(normalize(float3(d.xy, 0.0)), D, L);
            float3 under = waterView(d, D, L) + snellWindow(d, D, t, 0.25 + 0.75 * storm, mirror, u, stars, window);
            col = mix(level, under, smoothstep(0.015, 0.06, d.z));
            float S = D / max(d.z, 1e-3);
            float2 hit = d.xy * S;
            float slick = r.spawn.x;
            if (slick > 0.001) {
                float patchy = smoothstep(0.35, 0.75, vnoise3(float3(hit * 0.9, t * 0.05)));
                col = mix(col, float3(0.95, 0.55, 0.62) * (L * 0.35 + r.ambient.rgb * 0.2 + 0.02), saturate(slick * (0.35 + 0.5 * patchy)));
            }
            // Rain dimples the underside silver: small round flecks that come and go where each drop lands.
            float rain = r.weather.x;
            float near = 1.0 - smoothstep(2.0, 9.0, S);
            if (rain > 0.01 && near > 0.0) {
                float2 q = hit * 7.0;
                float2 cell = floor(q);
                float3 h = hash33(float3(cell, 1.0));
                float flick = floor(t * (5.0 + 4.0 * h.z) + 9.0 * h.x);
                float on = step(1.0 - 0.25 * rain, hash13(float3(cell, flick)));
                float dd = length(fract(q) - 0.5 - (h.xy - 0.5) * 0.4);
                float dimple = on * (1.0 - smoothstep(0.06, 0.16, dd));
                col += (L * 0.5 + r.ambient.rgb * 0.3) * kWaterTint * (0.45 * dimple * near);
            }
            depth = saturate(S / 60.0);
        } else {
            float sandDist;
            col = reefSand(d, u, r, D, kSandBelow, sandDist);
            depth = saturate(sandDist / 60.0);
            // A far reef wall along the haze, 30 m off: a low ragged line of coral heads, nearly lost in the blue.
            float wallD = 30.0;
            float wallBase = r.surface.z - (kSandBelow / wallD) / r.camera.w;
            if (in.ndc.y > wallBase - 0.002) {
                float X = in.ndc.x * r.camera.z * wallD;
                float hb = 0.45 + 0.9 * vnoise3(float3(X * 0.16, 2.0, 0.5)) + 0.35 * vnoise3(float3(X * 0.55, 5.0, 0.5));
                float wallTop = r.surface.z - ((kSandBelow - hb) / wallD) / r.camera.w;
                if (in.ndc.y < wallTop) {
                    float3 rock = float3(0.36, 0.33, 0.32) * (waterLight(D + kSandBelow - 0.6, L) * 0.6 + waterLight(D, L) * kWaterTint * 0.3);
                    col = throughWater(rock, D + 1.0, wallD, L);
                    depth = saturate(wallD / 60.0);
                }
            }
            // The far bommies, nearly lost in the blue.
            float4 b = reefBommie(in.ndc, r);
            if (b.x > 0.0) {
                float shade = (0.45 + 0.55 * b.z) * (0.85 + 0.15 * vnoise3(float3(in.ndc * 30.0, 4.0))) * (1.0 - 0.3 * abs(b.w));
                float3 rock = float3(0.40, 0.36, 0.34) * (waterLight(D + kSandBelow - 1.0, L) * shade * 0.7 + waterLight(D, L) * kWaterTint * 0.3);
                col = throughWater(rock, D + 0.8, b.y, L);
                depth = saturate(b.y / 60.0);
            }
        }

        // The near reef, on its stage: the coral groups, the clam and the rubble base, lit from above (the sun's or
        // the moon's light through the surface and the caustics) and by the water's own glow all round.
        float polypsOpen = r.reef.x;
        float glowGain = r.reef.z;
        float3 keyLight = waterLight(kReefDepth, L);
        float3 fill = waterLight(D, L) * kWaterTint * 0.38 + r.ambient.rgb * 0.04;
        float dots = reefPolyps(P);
        float sunSide = sin(atan2(r.sun.x, r.sun.y) - atan2(r.camera.x, r.camera.y));
        // The light from above, leaning toward the sun's side so branches and domes have a lit side and a shade side.
        float3 Lv = normalize(float3(0.3 + 0.35 * sunSide, 1.0, 0.45));
        if (P.y < 1.45) {
            float3 reefCol = float3(0);
            float reefCover = 0.0;
            for (int i = 0; i < 7; i++) {
                float4 g = r.groups[i];
                if (abs(P.x - g.x) > 1.5 * g.z || P.y > 1.35 * g.y) continue;
                int kind = int(r.hues[i].w + 0.5);
                float seed = float(i) * 1.37 + 0.4;
                CoralLook c;
                if (kind == 0) c = reefBrain(P, g, seed, pxS, t, polypsOpen, octaves);
                else if (kind == 1) c = reefPlate(P, g, seed, pxS, t, polypsOpen);
                else if (kind == 2) c = reefSoft(P, g, seed, pxS, t, polypsOpen);
                else c = reefStaghorn(P, g, (i % 2 == 0) ? -1.0 : 1.0, pxS, t, polypsOpen);
                if (c.cover <= 0.0) continue;
                float diffuse = saturate(dot(c.n, Lv));
                float foot = 0.55 + 0.45 * smoothstep(0.0, 0.4, P.y / max(g.y, 1e-3));
                float3 wp = float3(P.x * 2.2, 3.0 + P.y * 1.5, -kReefDepth - 0.4 * (1.0 - P.y));
                float caus = mix(1.0, caustics(wp, t, pxS * 2.2), 0.4 * saturate(c.open));
                float3 lit = c.albedo * (keyLight * (0.2 + 0.8 * diffuse) * caus * 0.62 + fill) * foot;
                // Fluorescence: each group's colour in its polyps, as bright as its glow; the polyps' soft glow at night.
                float3 hue = mix(r.hues[i].rgb, float3(1.0), 0.12);
                float fl = (g.w * glowGain * 0.62 + polypsOpen * 0.05) * c.polyp * (0.45 + 0.55 * dots);
                reefCol = mix(reefCol, lit, c.cover);
                glow = mix(glow, hue * fl, c.cover);
                reefCover = max(reefCover, c.cover);
            }
            // The giant clam, between the brain corals and the first plates.
            float2 clamAt = float2(0.5 * (r.groups[1].x + r.groups[2].x), 0.055);
            float clamSize = 0.07 * min(r.groups[1].z, r.groups[2].z) / 0.2;
            float mantle;
            float4 clam = reefClam(P, clamAt, clamSize, pxS, t, r, mantle);
            if (clam.a > 0.0) {
                float3 lit = clam.rgb * (keyLight * 0.55 + fill * 1.2);
                reefCol = mix(reefCol, lit, clam.a);
                glow = mix(glow, float3(0.1, 0.6, 0.7) * mantle * (polypsOpen * 0.08), clam.a);
                reefCover = max(reefCover, clam.a);
            }
            // The rubble base along the bottom: dead coral and rubble, pink with coralline crusts in places.
            float base = reefBaseLine(P.x);
            float inBase = 1.0 - smoothstep(base - pxS, base + pxS, P.y);
            if (inBase > 0.0) {
                float n = vnoise3(float3(P * 26.0, 3.3));
                float pinkish = smoothstep(0.55, 0.8, vnoise3(float3(P * 7.0, 8.1)));
                float3 rubble = mix(float3(0.42, 0.38, 0.34), float3(0.62, 0.42, 0.48), pinkish) * (0.7 + 0.3 * n);
                float topLit = smoothstep(base - 0.02, base, P.y);
                float3 lit = rubble * (keyLight * (0.3 + 0.5 * topLit) * 0.62 + fill);
                reefCol = mix(reefCol, lit, inBase);
                glow *= 1.0 - inBase;
                reefCover = max(reefCover, inBase);
            }
            if (reefCover > 0.0) {
                // Close to, the eye keeps the corals' colours (it balances the water's blue away).
                reefCol *= float3(1.3, 1.0, 0.92);
                float3 seen = throughWater(reefCol, kReefDepth, kReefDistance, L);
                col = mix(col, seen, reefCover);
                depth = mix(depth, 0.06, reefCover);
            }
            // Lit polyp patches: each note's patch on its group, and a faint halo into the water round it.
            int count = int(r.reef.w + 0.5);
            if (P.y < 0.9) {
                float3 halo = float3(0);
                for (int j = 0; j < 64; j++) {
                    if (j >= count) break;
                    float4 pt = r.patches[j];
                    float2 dp = P - pt.xy;
                    float rr = 0.06 * (0.8 + 0.5 * pt.w);
                    float q2 = dot(dp, dp) / (rr * rr);
                    if (q2 > 9.0) continue;
                    int gi = clamp(int(pt.z + 0.5), 0, 6);
                    float3 hue = mix(r.hues[gi].rgb, float3(1.0), 0.12);
                    glow += hue * (pt.w * glowGain * 1.15 * exp(-q2) * reefCover * (0.45 + 0.55 * dots));
                    halo += hue * (pt.w * glowGain * 0.08 * exp(-q2 * 0.25));
                }
                glow += halo;
            }
            glow *= waterAbsorb(kReefDistance) * 0.6 + 0.4;
        }

        // The colour wave's soft wash along its two fronts, over the reef and the sand.
        float wave = r.wave.w;
        if (wave > 0.001) {
            float fx = (in.ndc.x + 1.0) * 0.5;
            float a = (fx - r.wave.x) / r.wave.z, b = (fx - r.wave.y) / r.wave.z;
            float lowness = 1.0 - smoothstep(0.3, 0.9, P.y);
            glow += r.waveColour.rgb * (wave * 0.32 * (exp(-a * a) + exp(-b * b)) * lowness * glowGain);
        }

        // A spawning burst's haze (a big moment): the water above the reef clouding pink with spawn, thickest over the
        // corals, thinning toward the surface.
        float haze = r.spawn.w;
        if (haze > 0.001) {
            float hy = (P.y - 0.5) / 0.35;
            float cloud = exp(-hy * hy) * (0.75 + 0.25 * vnoise3(float3(P * 3.0, t * 0.05)));
            col += float3(1.0, 0.55, 0.62) * (waterLight(D, L) * kWaterTint * 0.25 + float3(0.02, 0.015, 0.018)) * (haze * cloud);
        }

        // The light shafts: soft bands slanting down from the surface along the refracted sun.
        float shafts = r.spawn.z;
        if (shafts > 0.001) {
            float2 uv = float2(in.ndc.x * r.frame.x * 0.45, (in.ndc.y - r.surface.z) / h * 1.4 + 0.6);
            float lean = 0.35 * sunSide;
            col += lightShafts(uv, float2(-lean, -1.0), t, D + 0.5, 0.3 + 0.7 * storm) * waterLight(D, L) * kWaterTint * (1.7 * shafts);
        }

        col *= waterAdapt(D);
        col += glow;

        // The meniscus from below: a bright silver line where the surface meets the lens.
        // The meniscus from below: a bright silver line where the surface meets the lens, and the underside's sheen
        // just under it (the surface mirroring the bright water at its most grazing).
        float below = (ym - in.ndc.y) / px;
        float line = exp(-below * below / 3.0);
        float sheen = exp(-max(below, 0.0) / 9.0) * (1.0 - line);
        col += (L * 0.18 + r.ambient.rgb * 0.25) * kWaterTint * (1.6 * line) + waterLight(D, L) * kWaterTint * (0.28 * sheen);

        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the school, the beads, the snow
    // An instance: a (x, y NDC, size: a fish's half-length or a dot's radius in NDC, heading radians) and c (linear
    // rgb, alpha). kind (vertex buffer 1, fragment buffer 0): x 0 fish, 1 dots; y aspect.
    struct ReefDot { float4 a; float4 c; };
    struct ReefDotOut { float4 pos [[position]]; float2 uv; float4 c; float2 ndc; };

    // ---------------------------------------------------------------- the visitors (surprises)
    // Each in its own units (uv −1…1, facing +x, y up), a stroke's phase in turns; returns its cover (0…1) and through
    // `pale` how much of it is its pale side, through `dark` its dark markings.

    /// A blacktip reef shark side on: a slim body, the first dorsal and the pectoral fins swept back, the tall upper lobe
    /// of the tail; its tail sweeping side to side, so the caudal fin narrows and widens. Black tips on the fins.
    float reefShark(float2 p, float beat, float px, thread float& pale, thread float& dark) {
        float x = p.x, y = p.y;
        float e = (x - 0.12) / 0.8;
        float half = 0.14 * sqrt(max(0.0, 1.0 - e * e));
        float stock = (x < -0.5 && x > -0.8) ? 0.03 + 0.05 * (x + 0.8) / 0.3 : 0.0;
        float body = 1.0 - smoothstep(-px, px, abs(y - 0.01 * x) - max(half, stock));
        float k = 0.55 + 0.45 * abs(cos(beat * 6.2831853));
        float2 d1 = p - float2(-0.04, 0.17);
        float2 r1 = float2(d1.x * 0.88 + d1.y * 0.47, -d1.x * 0.47 + d1.y * 0.88);
        float dorsal = (1.0 - smoothstep(0.9, 1.0, length(r1 / float2(0.07, 0.16)))) * step(0.08, y);
        float2 d2 = p - float2(0.2, -0.15);
        float2 r2 = float2(d2.x * 0.88 - d2.y * 0.47, d2.x * 0.47 + d2.y * 0.88);
        float pect = (1.0 - smoothstep(0.9, 1.0, length(r2 / float2(0.15, 0.045)))) * step(y, -0.06);
        float2 d3 = p - float2(-0.84, 0.13);
        float2 r3 = float2(d3.x * 0.88 + d3.y * 0.47, -d3.x * 0.47 + d3.y * 0.88);
        float upper = 1.0 - smoothstep(0.9, 1.0, length(r3 / float2(0.055 * k, 0.2)));
        float2 d4 = p - float2(-0.8, -0.08);
        float2 r4 = float2(d4.x * 0.83 - d4.y * 0.56, d4.x * 0.56 + d4.y * 0.83);
        float lower = 1.0 - smoothstep(0.9, 1.0, length(r4 / float2(0.045 * k, 0.11)));
        float cover = max(max(body, dorsal), max(pect, max(upper, lower)));
        pale = body * (1.0 - smoothstep(-0.06, 0.0, y));
        dark = max(dorsal * step(0.27, y), max(upper * step(0.25, y), lower * step(y, -0.15)));
        return cover;
    }

    /// A manta from a little below as it glides: its broad wings spanning up and down the view (foreshortened as they
    /// beat), the leading edge swept back, the cephalic fins in front, a thin tail behind. A pale belly, dark margins.
    float reefManta(float2 p, float beat, float px, thread float& pale, thread float& dark) {
        float flap = sin(beat * 6.2831853);
        float span = 0.92 * (0.8 + 0.2 * cos(beat * 6.2831853));
        float ax = abs(p.y) / max(span, 0.1);
        float cover = 0.0;
        if (ax < 1.0) {
            float lead = 0.3 - 0.42 * ax * ax - 0.07 * flap * ax;
            float trail = -0.22 + 0.24 * ax;
            cover = (1.0 - smoothstep(lead - px, lead + px, p.x)) * smoothstep(trail - px, trail + px, p.x);
        }
        float2 h1 = (p - float2(0.36, 0.08)) / float2(0.08, 0.025);
        float2 h2 = (p - float2(0.36, -0.08)) / float2(0.08, 0.025);
        float horns = max(1.0 - smoothstep(0.8, 1.0, length(h1)), 1.0 - smoothstep(0.8, 1.0, length(h2)));
        float tail = (p.x < -0.18 && p.x > -0.9) ? 1.0 - smoothstep(0.008, 0.016, abs(p.y + 0.02 * sin(p.x * 6.0 + beat))) : 0.0;
        cover = max(cover, max(horns, tail));
        pale = cover * (1.0 - smoothstep(0.7, 0.95, ax));
        dark = max(cover * smoothstep(0.8, 0.98, ax), max(horns, tail));
        return cover;
    }

    /// A green turtle side on: its domed shell with its scutes, a flat underside, the head forward, the long fore
    /// flipper rowing, the hind flipper trailing.
    float reefTurtle(float2 p, float beat, float px, thread float& pale, thread float& dark) {
        float stroke = sin(beat * 6.2831853);
        float2 sq = (p - float2(-0.05, -0.04)) / float2(0.5, 0.3);
        float shell = (1.0 - smoothstep(1.0 - px * 3.0, 1.0 + px * 3.0, length(sq))) * smoothstep(-0.12, -0.09, p.y);
        float head = 1.0 - smoothstep(0.85, 1.0, length((p - float2(0.53, 0.0)) / float2(0.12, 0.08)));
        float fa = -2.2 + 0.75 * stroke;
        float2 fd = float2(cos(fa), sin(fa));
        float2 fv = p - float2(0.24, -0.06);
        float along = dot(fv, fd), across = dot(fv, float2(-fd.y, fd.x));
        float fw = 0.07 * (1.0 - saturate(along / 0.52)) + 0.015;
        float fore = (along > 0.0 && along < 0.52) ? 1.0 - smoothstep(fw - px, fw + px, abs(across)) : 0.0;
        float2 hv = p - float2(-0.5, -0.08);
        float2 hr = float2(hv.x * 0.95 - hv.y * 0.3, hv.x * 0.3 + hv.y * 0.95);
        float hind = 1.0 - smoothstep(0.85, 1.0, length(hr / float2(0.13, 0.04)));
        float scutes = smoothstep(0.42, 0.5, abs(fract(sq.x * 2.4 + 0.3 * sq.y) - 0.5) + abs(fract(sq.y * 1.6) - 0.5) * 0.4);
        pale = max(head, max(fore, hind)) * 0.6;
        dark = shell * scutes * step(-0.03, p.y);
        return max(max(shell, head), max(fore, hind));
    }

    /// A visitor's colour and cover (premultiplied): lit from above by the water's light (`light`), counter-shaded.
    float4 reefVisitor(float2 uv, int shape, float beat, float4 c, float px) {
        float pale = 0.0, dark = 0.0, cover;
        float3 albedo;
        float3 paleCol, darkCol;
        if (shape == 0) {
            cover = reefManta(uv, beat, px, pale, dark);
            albedo = float3(0.16, 0.17, 0.2); paleCol = float3(0.78, 0.8, 0.82); darkCol = float3(0.05, 0.06, 0.07);
        } else if (shape == 1) {
            cover = reefTurtle(uv, beat, px, pale, dark);
            albedo = float3(0.36, 0.3, 0.17); paleCol = float3(0.55, 0.52, 0.42); darkCol = float3(0.16, 0.12, 0.07);
        } else {
            cover = reefShark(uv, beat, px, pale, dark);
            albedo = float3(0.42, 0.4, 0.34); paleCol = float3(0.82, 0.82, 0.78); darkCol = float3(0.04, 0.04, 0.045);
        }
        if (cover <= 0.001) return float4(0.0);
        float3 col = mix(mix(albedo, paleCol, pale), darkCol, dark);
        float top = 0.55 + 0.45 * saturate(0.5 + uv.y);
        col *= c.rgb * (1.6 * top);
        float a = cover * c.a;
        return float4(col * a, a);
    }

    vertex ReefDotOut reef_dot_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant ReefDot* dots [[buffer(0)]],
                                      constant float4& kind [[buffer(1)]]) {
        float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        ReefDot item = dots[iid];
        float2 c = corners[vid];
        float2 off;
        float2 uvOut = c;
        if (kind.x < 0.5) {
            // Turned to its heading, mirrored when it swims left so its back stays up.
            float ca = cos(item.a.w), sa = sin(item.a.w);
            float flip = ca < 0.0 ? -1.0 : 1.0;
            float2 local = float2(c.x * item.a.z, c.y * item.a.z * 0.45 * flip);
            off = float2(local.x * ca - local.y * sa, local.x * sa + local.y * ca);
        } else if (kind.x > 1.5) {
            // A visitor: a square of its half-length, its own units facing the way it swims.
            off = c * item.a.z;
            uvOut = float2(c.x * (cos(item.a.w) < 0.0 ? -1.0 : 1.0), c.y);
        } else {
            off = c * item.a.z * 2.0;
        }
        off.x /= max(kind.y, 0.1);
        ReefDotOut o;
        o.ndc = item.a.xy + off;
        o.pos = float4(o.ndc, 0, 1);
        o.uv = uvOut;
        o.c = item.c;
        return o;
    }

    fragment float4 reef_dot_fragment(ReefDotOut in [[stage_in]], constant float4& kind [[buffer(0)]],
                                      constant ReefU& r [[buffer(1)]]) {
        if (in.ndc.y > reefMeniscus(in.ndc.x, r) - 0.003) discard_fragment();
        if (kind.x > 1.5) {
            float4 v = reefVisitor(in.uv, int(kind.z + 0.5), kind.w, in.c, 0.02);
            if (v.a < 0.002) discard_fragment();
            return v;
        }
        float a;
        if (kind.x < 0.5) {
            // A small fish seen side-on: a slim body (its back darker than its belly) and a forked tail.
            float2 q = in.uv;
            float body = length(float2((q.x - 0.12) / 0.7, q.y / 0.75));
            float inBody = 1.0 - smoothstep(0.85, 1.05, body);
            float tx = -0.5 - q.x;                                   // 0 at the tail's root … 0.5 at its end
            float spread = 0.15 + 1.2 * max(tx, 0.0);
            float inTail = (tx > 0.0 && tx < 0.5) ? 1.0 - smoothstep(spread - 0.12, spread + 0.12, abs(q.y)) : 0.0;
            float notch = tx > 0.28 ? 1.0 - smoothstep(-0.05, 0.05, abs(q.y) - (tx - 0.28) * 1.6) : 0.0;
            a = max(inBody, inTail * (1.0 - notch));
            float shade = mix(1.15, 0.7, saturate(0.5 + 0.5 * q.y));
            a *= in.c.a;
            return float4(in.c.rgb * (shade * a), a);
        } else {
            float r2 = dot(in.uv, in.uv);
            a = exp(-r2 * 4.0) * step(r2, 1.0);
        }
        a *= in.c.a;
        return float4(in.c.rgb * a, a);
    }

    // ---------------------------------------------------------------- the keys: wet sand along the bottom edge
    struct ReefKey { float4 rect; float4 info; };   // rect (x0, y0, x1, y1); info (isBlack, glow, pressed, light)
    struct ReefKeyOut { float4 pos [[position]]; float2 uv; float4 info; };

    vertex ReefKeyOut reef_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant ReefKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        ReefKey k = keys[iid];
        ReefKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }

    /// Wet sand: pale and sheened where the water has just drawn back (white keys), darker and wetter between (black
    /// keys), glowing turquoise where you play.
    fragment ColorDepth reef_keys_fragment(ReefKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float grain = hash13(float3(floor(in.pos.xy * 0.5), 3.0));
        float3 base = black ? float3(0.10, 0.09, 0.08) : float3(0.40, 0.37, 0.31);
        base *= 0.9 + 0.1 * grain;
        float y2 = in.uv.y * in.uv.y;
        float sheen = y2 * y2 * (black ? 0.06 : 0.16) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * (1.0 - smoothstep(0.94, 1.0, in.uv.x));
        float3 c = base * light + float3(0.7, 0.85, 0.9) * (sheen * light)
                 + float3(0.18, 0.95, 0.85) * (glow * 1.5 * (0.35 + 0.65 * in.uv.y));
        c *= 0.6 + 0.4 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
