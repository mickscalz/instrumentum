/// Metal source for Golden Hour Beach: a low headland, the Ocean layer out to the breakers, crests rolling in
/// and breaking into white water, the wash sliding up the sand, wet sand mirroring the sky, dry sand with ripple
/// marks, Tide Lines glowing in the sand, palms and dune grass, and an amber keyboard. Built on
/// SkyShaders.common and OceanShaders.common.
/// Smooth rules: no ray marching, ≤ 2 noise octaves, ≤ 24 lines per sand pixel on Smooth; everything that moves
/// is timed by the swell's wrapped phases (never a raw clock).
enum GoldenHourBeachShaders {
    static let source = SkyShaders.common + OceanShaders.common + """
    struct BeachU {
        float4 a;           // keys top (NDC y), spray scale (gentle visuals halve it), glitter 0…1, haze 0…1
        float4 b;           // palms 0…1, wind, line count, night 0…1
        float4 c;           // aspect, camera height (m), seconds since the last break (< 0: none), its strength
        float4 shore;       // wash front 0…1, foam from chords 0…1, seconds since the break before last, its strength
        float4 crest[3];    // the next crests: metres beyond the break line, strength (crest[0].z: wetness after rain)
        float4 line[48];    // across (m), out (m), half length (m), glow
        float4 lineB[48];   // hue, unused…
        float4 fw[9];       // Fire & Neon §5.5, the fireworks' bursts: direction from the eye (unit), angular radius (rad)
        float4 fwB[9];      // their light on the water: colour × brightness (rgb, HDR), 1 for a live row (0 ends the list)
    };
    struct BeachOut { float4 pos [[position]]; float2 ndc; };

    constant float kWaterline = 11.0;   // metres from the camera to where the sea meets the sand
    constant float kWetBand = 5.0;      // wet sand from here back toward the camera
    constant float kBreak = 22.0;       // where the waves break
    constant float kBoreSpeed = 4.4;    // white water rushing in from the break (m/s)

    vertex BeachOut beach_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BeachOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float3 beachRay(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    /// A line's colour: warm gold tinted toward the chord's hue.
    float3 lineColor(float h) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return mix(float3(1.0, 0.86, 0.6), k, 0.6);
    }

    /// Distance from p to segment ab, and how far along it (0…1) the nearest point lies.
    float2 segDistH(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        return float2(length(pa - ba * h), h);
    }

    /// One palm's coverage at q (screen units: x × aspect, y): a tapered, ringed trunk and a crown of drooping
    /// fronds with serrated leaflets. Sway comes from the swell's wrapped phases. `rime` returns the rime fringe on its
    /// trunk, knot and midribs (spec §6.4; the leaflets' blades have no edge distance to give), following the outline of
    /// their union: each offers its depth and its direction out from its centre line.
    float palmTree(float2 q, float2 root, float height, float lean, float scale, float sway, float frondSway, float seed,
                   constant SkyU& u, thread float& rime) {
        rime = 0.0;
        float2 top = root + float2(lean + sway, height);
        // Cheap bounds: nothing far from the trunk or the crown.
        if (q.y < root.y - 0.02 || q.y > top.y + 0.42 * scale) return 0.0;
        float cover = 0.0;
        float deepest = -1.0;
        float2 outward = float2(0.0, 1.0);
        float2 ctrl = root + float2(lean * 0.15 + 0.05 * sign(lean), height * 0.55);
        float2 prev = root;
        if (abs(q.x - mix(root.x, top.x, saturate((q.y - root.y) / height))) < 0.12) {
            for (int k = 1; k <= 6; k++) {
                float t = float(k) / 6.0;
                float2 pt = (1.0 - t) * (1.0 - t) * root + 2.0 * (1.0 - t) * t * ctrl + t * t * top;
                float2 dh = segDistH(q, prev, pt);
                float tt = (float(k - 1) + dh.y) / 6.0;
                float w = mix(0.03, 0.014, tt) * scale * (1.0 + 0.12 * abs(sin(tt * 70.0 + seed)));
                cover = max(cover, smoothstep(w, w * 0.6, dh.x));
                rimeKeepDeepest(w - dh.x, q - mix(prev, pt, dh.y), deepest, outward);
                prev = pt;
            }
        }
        // The feathers ride the palm as it sways (the trunk bends more toward its top).
        float bend = saturate((q.y - root.y) / height);
        float2 riding = q - float2(sway * bend * bend, 0.0);
        if (length(q - top) > 0.42 * scale) {
            if (cover > 0.0) rime = rimeEdge(u, deepest, outward, riding);
            return cover;
        }
        // A dark knot where the fronds meet.
        float knot = length(q - top - float2(0, -0.01));
        cover = max(cover, smoothstep(0.03 * scale, 0.018 * scale, knot));
        rimeKeepDeepest(0.03 * scale - knot, q - top - float2(0, -0.01), deepest, outward);
        for (int f = 0; f < 10; f++) {
            float h = hash13(float3(seed, float(f), 4.0));
            float a = -0.25 + float(f) * 0.36 + 0.25 * (h - 0.5) + 0.06 * sin(frondSway + float(f) * 1.7);
            float len = (0.26 + 0.1 * h) * scale;
            float2 dir = float2(cos(a), sin(a));
            float droop = (0.14 + 0.12 * saturate(dir.y)) * scale;
            float2 p0 = top;
            float2 p1 = top + dir * len * 0.4 + float2(0, 0.02 * scale);
            float2 p2 = top + dir * len * 0.75 - float2(0, droop * 0.45);
            float2 p3 = top + dir * len - float2(0, droop);
            float2 d1 = segDistH(q, p0, p1), d2 = segDistH(q, p1, p2), d3 = segDistH(q, p2, p3);
            float2 best = d1; float base = 0.0; float2 sa = p0, sb = p1;
            if (d2.x < best.x) { best = d2; base = 1.0; sa = p1; sb = p2; }
            if (d3.x < best.x) { best = d3; base = 2.0; sa = p2; sb = p3; }
            float t = (base + best.y) / 3.0;
            // Leaflets: thin blades slanting back from the midrib, hanging lower on the underside.
            float2 sd = normalize(sb - sa);
            float side = sd.x * (q.y - sa.y) - sd.y * (q.x - sa.x);      // > 0 above the midrib
            float reach = 0.045 * scale * sin(3.14159 * min(1.0, t * 1.05)) * (side > 0.0 ? 0.6 : 1.0);
            float across = best.x / max(reach, 1e-4);
            float blades = abs(fract(t * 22.0 + across * 0.9 + h * 3.0) - 0.5);
            float leaf = smoothstep(0.32, 0.16, blades) * smoothstep(1.0, 0.75, across) * step(0.05, t);
            cover = max(cover, leaf);
            cover = max(cover, smoothstep(0.006 * scale, 0.003 * scale, best.x));   // the midrib
            rimeKeepDeepest((0.006 * scale - best.x) * 3.0, q - mix(sa, sb, best.y), deepest, outward);   // a spine: a third the fringe
        }
        if (cover > 0.0) rime = rimeEdge(u, deepest, outward, riding);
        return cover;
    }

    /// Palms at the frame's edges and dune grass along the bottom corners. Returns coverage 0…1, and through `rime`
    /// the rime fringe on the palms' trunks and midribs and the grass blades (spec §6.4).
    float shoreSilhouettes(float2 p, constant BeachU& b, constant OceanU& o, constant SkyU& u, thread float& rime) {
        rime = 0.0;
        float amount = b.b.x;
        if (amount < 0.01 || abs(p.x) < 0.25) return 0.0;
        float aspect = b.c.x, wind = b.b.y, base = b.a.x;
        float2 q = float2(p.x * aspect, p.y);
        float sway = (0.01 + 0.035 * wind);
        float cover = 0.0;
        // Left: a tall palm leaning in and a smaller one behind it; right: one leaning in. Each palm's rime counts
        // where that palm is the one seen.
        float pr;
        float pc = palmTree(q, float2(-0.93 * aspect, base - 0.02), 1.45, 0.2, 1.0, sway * sin(o.phases.x), o.phases.w, 1.0, u, pr);
        if (pc > cover) { cover = pc; rime = pr; }
        if (amount > 0.35) {
            pc = 0.85 * palmTree(q, float2(-0.68 * aspect, base + 0.03), 0.95, 0.12, 0.72, sway * sin(o.phases.y + 1.0),
                                 o.phases.w + 2.0, 2.0, u, pr);
            if (pc > cover) { cover = pc; rime = pr; }
        }
        if (amount > 0.65) {
            pc = palmTree(q, float2(0.9 * aspect, base - 0.02), 1.3, -0.24, 0.95, sway * sin(o.phases.z + 2.0), o.phases.w + 4.0,
                          3.0, u, pr);
            if (pc > cover) { cover = pc; rime = pr; }
        }
        // Dune grass: thin blades in tufts near the bottom corners.
        float edge = smoothstep(0.55, 0.9, abs(p.x));
        if (edge > 0.0 && p.y < base + 0.2) {
            float x = q.x * 38.0;
            float i = floor(x), fx = fract(x);
            float hb = hash13(float3(i, 7.0, 1.0));
            float tuft = smoothstep(0.45, 0.75, vnoise3(float3(i * 0.09, 3.0, 2.0)));
            float bladeH = (0.03 + 0.12 * hb) * edge * tuft * amount;
            float y = (p.y - base) / max(bladeH, 1e-3);
            if (y >= 0.0 && y < 1.0) {
                float lean = (0.5 * (hb - 0.5) + (0.25 + 0.6 * wind) * sin(o.phases.w + hb * 6.0)) * y * y * 1.6;
                float width = 0.22 * (1.0 - y * 0.92);
                float across = fx - 0.5 - lean;
                float gc = smoothstep(width, width * 0.5, abs(across));
                if (gc > cover) {
                    cover = gc;
                    // The blade's edge (cells are 1/38 of a screen unit), its feathers riding the blade as it sways.
                    rime = rimeEdge(u, (width - abs(across)) / 38.0, float2(across < 0.0 ? -1.0 : 1.0, 0.1),
                                    float2((i + 0.5 + across) / 38.0, p.y));
                }
            }
        }
        return cover;
    }

    /// One broken wave's white water: the bore rolling in from the break line, the foam it leaves behind, and its
    /// breaking face slumping over half a second (so a break never pops). Adds to `white` and to the slope.
    void breakerWhite(float f, float s, float2 q, float since, float last, constant OceanU& o,
                      thread float& white, thread float2& slope) {
        if (last <= 0.0 || since < 0.0 || since >= 14.0) return;
        // Where the bore is: it leaves the break line along the crest's own curve, then wanders.
        float wobble = mix(1.2 * sin(s * 0.05), 0.9 * (vnoise3(float3(s * 0.3, 2.0, 0.0)) - 0.5), saturate(since / 1.5));
        float fb = max(kWaterline, kBreak - since * kBoreSpeed) + wobble;
        float behind = f - fb;
        float bore = exp(-(behind * behind) / 0.9) * step(since * kBoreSpeed, kBreak - kWaterline + 1.0);
        float trail = behind > 0.0 ? exp(-behind / (2.0 + since * 0.9)) * step(f, kBreak + 2.0) : 0.0;
        float lace = smoothstep(0.28, 0.7, vnoise3(float3(q * float2(0.8, 1.6), 2.0 * sin(o.phases.x) + since * 0.2)));
        white += (0.35 + last) * exp(-since / 5.0) * (bore * 1.2 + trail * (0.25 + 0.85 * lace));
        float face = exp(-((behind + 1.6) * (behind + 1.6)) / 2.2), lip = exp(-(behind * behind) / 0.7);
        slope.y += (0.3 + last) * exp(-since / 0.5) * (face - 0.4 * lip);
    }

    /// The fireworks' bursts mirrored by the water along the reflected ray `rd` (Fire & Neon §5.5): each a soft glow
    /// the size of its burst, broken into a column by the water's ripples (the normal already is).
    float3 fireworkReflection(float3 rd, constant BeachU& b) {
        float3 glow = float3(0);
        for (int i = 0; i < 9; i++) {
            if (b.fwB[i].w < 0.5) break;
            float r = max(b.fw[i].w, 0.004);
            float c = 1.0 - dot(rd, b.fw[i].xyz);       // ≈ θ² / 2
            if (c > 8.0 * r * r + 0.002) continue;
            glow += b.fwB[i].rgb * exp(-c / (0.5 * r * r + 0.00004));
        }
        return glow;
    }

    // A low headland to the left, hazy with distance. Height above the horizon (radians) by relative azimuth.
    float headland(float azRel) {
        if (azRel < -0.95 || azRel > -0.22) return -1.0;
        float x = (azRel + 0.95) / 0.73;
        float hump = pow(sin(3.14159 * x), 0.6) * (0.75 + 0.25 * x);
        return (0.6 + 2.2 * hump + 0.35 * fbm3(float3(azRel * 9.0, 2.0, 5.0), 2)) * 0.0174533;
    }

    fragment ColorDepth beach_fragment(BeachOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant BeachU& b [[buffer(1)]],
                                       constant OceanU& o [[buffer(2)]], texture2d<float> stars [[texture(0)]]) {
        ColorDepth out;
        float2 p = in.ndc;
        if (p.y < b.a.x) {   // under the keyboard
            out.color = float4(0, 0, 0, 1); out.depth = float4(0.1, 0, 0, 1);
            return out;
        }
        float3 d = beachRay(p, u);
        float alt = asin(clamp(d.z, -1.0, 1.0)), az = atan2(d.x, d.y);
        float camAz = atan2(u.forward.x, u.forward.y);
        float azRel = az - camAz;
        if (azRel > 3.14159) azRel -= 6.28318;
        if (azRel < -3.14159) azRel += 6.28318;
        float haze = b.a.w, night = b.b.w;
        float3 horizon = u.horizon.rgb, zenith = u.zenith.rgb;
        float3 hazeCol = horizon * (1.02 + 0.1 * night);
        float silRime;
        float sil = shoreSilhouettes(p, b, o, u, silRime);
        float3 silCol = zenith * 0.04 + horizon * 0.035;

        // Both lights, each by its own weight (never an either/or switch, so dusk crosses to moonlight smoothly).
        float lightW = saturate(o.sun.w + o.moon.w);
        float3 lightCol = (o.sunColor.rgb * o.sun.w + o.moonColor.rgb * o.moon.w) / max(o.sun.w + o.moon.w, 1e-3);

        float3 col;
        float depth = 1.0;
        if (alt >= 0.0) {
            float hl = headland(azRel);
            bool hit = alt < hl;
            if (!hit && sil < 0.01) discard_fragment();
            if (hit) {
                float3 c = mix(horizon, zenith, 0.4) * 0.3 + o.sunColor.rgb * 0.02 * o.sun.w;
                col = mix(c, hazeCol, saturate(0.45 + 0.4 * haze) * (0.6 + 0.4 * exp(-alt / 0.02)));
                depth = 0.98;
            } else {
                float mm;
                col = skyRadiance(d, u, mm, stars);
            }
        } else {
            float hcam = b.c.y;
            float t = hcam / max(-d.z, 1e-4);
            float3 P = d * t;
            float2 fwd = normalize(u.forward.xy), rgt = float2(fwd.y, -fwd.x);
            float f = dot(P.xy, fwd), s = dot(P.xy, rgt);
            float2 q = float2(s, f);
            float since = b.c.z, last = b.c.w;
            // The wash's front wanders along the shore.
            float wobble = (vnoise3(float3(s * 0.35, 1.0, 2.0 * sin(o.phases.y))) - 0.5) * 0.9;
            float front = kWaterline - b.shore.x * kWetBand + wobble * saturate(b.shore.x * 3.0);
            float3 foamBase = (horizon * 0.55 + 0.35) * (0.55 + 0.6 * lightW) + lightCol * 0.25 * lightW;
            float foamGold = b.shore.y;
            float3 foamCol = mix(foamBase, foamBase * float3(1.15, 0.95, 0.7) + o.sunColor.rgb * 0.3, foamGold);
            float edge = kWaterline + 0.8 * (vnoise3(float3(s * 0.22, 5.0, 1.5 * sin(o.phases.w))) - 0.5);
            if (f > edge) {
                // The sea: swells steepen over the shallows; crests roll in, curl and break into white water.
                float2 slope = oceanSlope(q, o, oceanFootprint(d, f, u));
                float shoal = smoothstep(kBreak + 25.0, kBreak - 4.0, f);
                slope *= 1.0 + 1.0 * shoal;
                float white = 0.0;
                for (int i = 0; i < 3; i++) {
                    float ahead = b.crest[i].x, strength = max(b.crest[i].y, 0.0);
                    if (strength <= 0.0 || ahead < 0.0 || ahead > 65.0) continue;
                    float cf = kBreak + ahead + 1.2 * sin(s * 0.05 + float(i) * 2.1);   // never ruler-straight
                    float x = f - cf;              // > 0 behind the crest, < 0 its face toward you
                    float nearing = smoothstep(65.0, 10.0, ahead);
                    float lip = exp(-(x * x) / 0.7);
                    float face = exp(-((x + 1.6) * (x + 1.6)) / 2.2);
                    slope.y += (0.3 + strength) * nearing * (1.0 * face - 0.4 * lip);
                    // It whitens along the lip as it nears the break, in broken stretches first.
                    float curl = smoothstep(10.0, 0.0, ahead) * (0.35 + strength);
                    float broken = smoothstep(0.25, 0.7, vnoise3(float3(s * 0.18, ahead * 0.3, 1.0)) + smoothstep(4.0, 0.0, ahead));
                    white += curl * lip * broken * 1.3 + (0.3 + strength) * nearing * lip * 0.1;
                }
                // The last two waves' white water: the newest rolling in, the one before still fading.
                breakerWhite(f, s, q, since, last, o, white, slope);
                breakerWhite(f, s, q, b.shore.z, b.shore.w, o, white, slope);
                // Lingering lace over the shallows.
                white += 0.22 * shoal * smoothstep(0.58, 0.85, vnoise3(float3(q * float2(0.5, 1.1), 1.5 * cos(o.phases.z))));
                // A thin swash line where the sea laps the sand.
                white += 0.55 * exp(-(f - edge) / 0.35) * (0.5 + 0.5 * vnoise3(float3(s * 1.4, 3.0, 2.0 * sin(o.phases.y))));
                white = saturate(white);
                float3 nrm = oceanNormal(slope, fwd, rgt);
                col = oceanShade(d, nrm, q, f, u, o, stars);
                if (b.fwB[0].w > 0.5) col += fireworkReflection(normalize(reflect(d, nrm)), b) * (0.08 + 0.3 * smoothstep(40.0, 400.0, f));
                col = mix(col, foamCol, white * (0.7 + 0.25 * foamGold));
                // Spray glints on golden foam.
                float spark = smoothstep(0.8, 0.95, vnoise3(float3(q * 6.0, 5.0 * sin(o.phases.y))));
                col += lightCol * spark * white * (0.3 + foamGold) * 1.5 * lightW * b.a.y;
                depth = saturate(f / 60.0);
            } else {
                // The sand: wet below the highest recent wash (a mirror), dry beyond it.
                float wetTop = kWaterline - kWetBand + wobble * 0.5;
                float wet = smoothstep(wetTop - 0.8, wetTop + 0.8, f);
                // After the rain the wet sand spreads up the beach toward the camera.
                float rainWet = b.crest[0].z;
                float rainTop = mix(wetTop, 1.5, rainWet);
                float damp = rainWet * smoothstep(rainTop - 0.8, rainTop + 0.8, f) * (1.0 - wet);
                float grain = vnoise3(float3(q * float2(9.0, 5.0), 3.0));
                float ripple = 0.5 + 0.5 * sin(f * 11.0 + 2.0 * vnoise3(float3(q * 0.7, 1.0)) + s * 0.8);
                float3 sandDry = float3(0.62, 0.50, 0.36) * (0.88 + 0.07 * ripple + 0.1 * grain);
                float3 sandWet = float3(0.16, 0.12, 0.09) * (0.9 + 0.2 * grain);
                float3 sky = mix(zenith, horizon, 0.7);
                float3 direct = o.sunColor.rgb * saturate(o.sun.z * 3.0 + 0.15) * o.sun.w
                              + o.moonColor.rgb * saturate(o.moon.z * 3.0 + 0.15) * o.moon.w;
                float3 dryCol = sandDry * (sky * 0.55 + direct * 0.7 + 0.02) * (1.0 - 0.25 * rainWet);   // dry ripples darken
                // Wet sand reflects the sky (slightly rough) and the lights' paths.
                float2 rough = (float2(vnoise3(float3(q * 3.0, 2.0)), vnoise3(float3(q * 3.0 + 7.0, 4.0))) - 0.5) * 0.07;
                float3 n = normalize(float3(rough, 1.0));
                float3 rd = reflect(d, n);
                rd.z = max(rd.z, 0.002);
                float mm;
                float3 refl = skyRadiance(normalize(rd), u, mm, stars);
                float fres = 0.25 + 0.6 * pow(1.0 - saturate(-d.z), 3.0);
                float3 wetCol = mix(sandWet * (sky * 0.4 + 0.02), refl, fres);
                float sdS = saturate(dot(rd, o.sun.xyz)), sdM = saturate(dot(rd, o.moon.xyz));
                float3 spec = o.sunColor.rgb * (pow(sdS, 90.0) * 1.4 + pow(sdS, 12.0) * 0.12) * o.sun.w
                            + o.moonColor.rgb * (pow(sdM, 90.0) * 1.4 + pow(sdM, 12.0) * 0.12) * o.moon.w;
                wetCol += spec * (0.5 + 0.5 * b.a.z);
                if (b.fwB[0].w > 0.5) wetCol += fireworkReflection(normalize(rd), b) * fres * 0.6;
                col = mix(dryCol, wetCol, wet);
                // Rain-wet sand: darker, with a duller mirror of the sky than the sea's own wet band.
                col = mix(col, mix(dryCol * 0.7, wetCol, 0.6), damp);
                // Sand drifting in the breeze over the dry sand.
                float drift = smoothstep(0.6, 0.9, vnoise3(float3(q * float2(0.6, 7.0) + float2(3.0 * sin(o.phases.x), 0.0), 4.0)));
                col += sandDry * sky * 0.12 * drift * b.b.y * (1.0 - wet);
                // The wash: a thin sheet of water from the waterline up to its front, lacy foam along its edge.
                if (f > min(front, edge)) {
                    float thick = smoothstep(front, front + 2.5, f) * smoothstep(edge - 3.0, edge, f) + smoothstep(edge - 0.6, edge, f) * 0.5;
                    thick = saturate(thick);
                    float3 sheet = mix(refl, horizon * 0.6 + 0.15, 0.2);
                    col = mix(col, sheet, 0.25 + 0.4 * thick);
                    float rim = exp(-(f - front) / 0.3) * step(front, f);
                    float lacy = smoothstep(0.3, 0.7, vnoise3(float3(q * float2(1.8, 3.5), 2.0 * sin(o.phases.z))));
                    col = mix(col, foamCol, saturate(rim * (0.45 + 0.5 * lacy) + (1.0 - thick) * lacy * 0.15));
                }
                // Tide Lines: strokes traced by a finger, a soft groove with light welling up from it.
                int count = int(b.b.z + 0.5);
                float3 glow = float3(0);
                for (int i = 0; i < 48; i++) {
                    if (i >= count) break;
                    float4 ln = b.line[i];
                    float ax = s - ln.x;
                    if (abs(ax) > ln.z + 0.4) continue;
                    float along = ax / max(ln.z, 0.05);
                    float curve = 0.18 * sin(along * 1.7 + b.lineB[i].x * 23.0) * min(ln.z, 1.0);
                    float dy = (f - ln.y - curve) * 0.2;              // ÷5 along the view: foreshortening
                    float dx = max(abs(ax) - ln.z, 0.0);
                    float taper = 1.0 - 0.6 * smoothstep(0.6, 1.0, abs(along));
                    float dist2 = dx * dx + dy * dy;
                    float w = 0.022 * taper;
                    float core = exp(-dist2 / (w * w)), halo = exp(-dist2 / 0.008) * 0.14;
                    glow += lineColor(b.lineB[i].x) * (core * 1.4 + halo) * ln.w;
                    col *= 1.0 - 0.25 * exp(-dist2 / 0.004) * ln.w;    // the groove
                }
                col += glow * (1.1 + 0.3 * night);
                depth = saturate(f / 60.0);
            }
            // Haze over the sea, thicker far away.
            col = mix(col, hazeCol, saturate(haze * 0.7 * (1.0 - exp(-f / 120.0))));
        }
        col = mix(col, silCol, sil);
        if (silRime > 0.0) col = mix(col, rimeColor(u), silRime * sil);
        if (sil > 0.5) depth = 0.03;
        out.color = float4(col, 1.0);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- Fire & Neon §5.5: fireworks and the green flash
    // Additive streaks: a: from (x, y) to (x, y), NDC; b: colour × light (rgb, HDR) and the half-width in pixels. The
    // view row: aspect, NDC per pixel (y), unused, unused.
    struct BeachSpark { float4 a; float4 b; };
    struct BeachSparkOut { float4 pos [[position]]; float2 local; float len; float radius; float3 colour; };

    vertex BeachSparkOut beach_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BeachSpark* sp [[buffer(0)]],
                                            constant float4& view [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BeachSpark s = sp[iid];
        float aspect = view.x, px = view.y;
        // In aspect units (x × aspect), so a streak is as wide whichever way it runs.
        float2 a = float2(s.a.x * aspect, s.a.y), e = float2(s.a.z * aspect, s.a.w);
        float2 dir = e - a;
        float len = length(dir);
        dir = len > 1e-6 ? dir / len : float2(1, 0);
        float2 nrm = float2(-dir.y, dir.x);
        float r = max(s.b.w, 0.7) * px;
        float2 k = c[vid];
        float along = mix(-2.5 * r, len + 2.5 * r, k.x), across = mix(-2.5 * r, 2.5 * r, k.y);
        float2 q = a + dir * along + nrm * across;
        BeachSparkOut o;
        o.pos = float4(q.x / aspect, q.y, 0, 1);
        o.local = float2(along, across);
        o.len = len;
        o.radius = r;
        o.colour = s.b.rgb;
        return o;
    }

    /// A spark's streak: its head (the far end) bright, its trail fading back along it. Additive.
    fragment float4 beach_spark_fragment(BeachSparkOut in [[stage_in]]) {
        float along = clamp(in.local.x, 0.0, in.len);
        float2 dq = float2(in.local.x - along, in.local.y);
        float r = in.radius;
        float core = exp(-dot(dq, dq) / (r * r));
        float h = in.len > 1e-6 ? along / in.len : 1.0;
        float tail = 0.25 + 0.75 * h * h;
        return float4(in.colour * (core * tail), 0.0);
    }

    // Sprites (premultiplied): the gulls, a dolphin breaking the surface, a kite. rect: the quad (NDC x0, y0, x1, y1);
    // local: its own units at the quad's corners (lo x, lo y, hi x, hi y); info: kind (0 a gull, 1 a dolphin, 2 a kite),
    // its wingbeat / its roll / the kite's tail phase, the kite's tilt, cover; tint: its colour (rgb) and the sun on it.
    struct BeachSprite { float4 rect; float4 local; float4 info; float4 tint; };
    struct BeachSpriteOut { float4 pos [[position]]; float2 uv; float4 info; float4 tint; };

    vertex BeachSpriteOut beach_sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BeachSprite* sp [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BeachSprite s = sp[iid];
        BeachSpriteOut o;
        o.pos = float4(mix(s.rect.xy, s.rect.zw, c[vid]), 0, 1);
        o.uv = mix(s.local.xy, s.local.zw, c[vid]);
        o.info = s.info;
        o.tint = s.tint;
        return o;
    }

    /// A gull from below, its wingspan −1…1 across: a slim body and long angled wings, crooked at the wrist, the beat
    /// lifting them. A signed distance.
    float gullDistance(float2 uv, float wing) {
        float d = length((uv - float2(0.0, -0.02)) / float2(0.55, 1.0)) - 0.09;
        for (int k = 0; k < 2; k++) {
            float side = k == 0 ? -1.0 : 1.0;
            float2 root = float2(0.06 * side, 0.0);
            float2 wrist = float2(0.42 * side, 0.1 + 0.22 * wing);
            float2 tip = float2(0.98 * side, -0.06 + 0.5 * wing);
            float2 a = segDistH(uv, root, wrist), e = segDistH(uv, wrist, tip);
            d = min(d, a.x - mix(0.08, 0.06, a.y));
            d = min(d, e.x - mix(0.06, 0.02, e.y));
        }
        return d;
    }

    /// A dolphin's back breaking the surface (uv in its own units: x along its swim, y up, the water at y = −0.22): an
    /// arc rising and setting as it rolls (`roll` 0…1), the dorsal fin riding on it. A signed distance; `spray` returns the
    /// white water where it breaks the surface and goes under.
    float dolphinDistance(float2 uv, float roll, thread float& spray) {
        float R = 0.9;
        float rise = 0.62 * sin(3.14159 * saturate(roll));
        float2 cen = float2(mix(-0.55, 0.55, roll), -0.22 - R + rise);
        float2 q = uv - cen;
        float ang = atan2(q.x, q.y);                          // 0 at the top of the arc, + ahead
        float band = abs(length(q) - R) - mix(0.11, 0.05, saturate(abs(ang) / 1.2));
        float d = max(band, abs(ang) - 1.25);
        // The fin: a swept-back triangle a little behind the top of the arc.
        float2 f = q - float2(-0.12 * R, R);
        float t = saturate(f.y / 0.34);
        float fin = max(abs(f.x + 0.1 * t * t + 0.02) - 0.1 * (1.0 - t), max(-f.y, f.y - 0.34));
        d = min(d, fin);
        float water = -0.22;
        float edge = exp(-((uv.y - water) * (uv.y - water)) / 0.004);
        spray = edge * (smoothstep(0.25, 0.0, roll) + smoothstep(0.75, 1.0, roll)) * smoothstep(0.35, 0.0, abs(uv.x - cen.x - (roll < 0.5 ? 0.7 : -0.7) * R));
        return max(d, water - uv.y);
    }

    /// A diamond kite (uv in metres, its spine up) with two coloured halves, dark spars and a ribbon tail waving below
    /// (`tail` its phase). A signed distance; `side` returns which half (−1 left, +1 right; 0 the spars and tail).
    float kiteDistance(float2 uv, float tail, thread float& side) {
        float2 top = float2(0, 0.75), right = float2(0.45, 0.15), bottom = float2(0, -0.55), left = float2(-0.45, 0.15);
        float2 e0 = right - top, e1 = bottom - right, e2 = left - bottom, e3 = top - left;
        float c0 = e0.x * (uv.y - top.y) - e0.y * (uv.x - top.x);
        float c1 = e1.x * (uv.y - right.y) - e1.y * (uv.x - right.x);
        float c2 = e2.x * (uv.y - bottom.y) - e2.y * (uv.x - bottom.x);
        float c3 = e3.x * (uv.y - left.y) - e3.y * (uv.x - left.x);
        float inside = max(max(c0, c1), max(c2, c3)) / 0.6;   // ≤ 0 inside (clockwise)
        side = uv.x < 0.0 ? -1.0 : 1.0;
        float spar = min(abs(uv.x), abs(uv.y - 0.15) + max(abs(uv.x) - 0.45, 0.0));
        if (spar < 0.015 && inside < 0.0) side = 0.0;
        // The tail: from the bottom corner down 3.5 m, swinging wider as it goes.
        float y = -0.55 - uv.y;
        float d = inside;
        if (y > 0.0 && y < 3.5) {
            float k = y / 3.5;
            float x = 0.28 * k * sin(y * 1.9 - tail) + 0.05 * sin(y * 5.0 - 1.7 * tail);
            float dt = abs(uv.x - x) - 0.018 * (1.0 - 0.5 * k);
            if (dt < d) { d = dt; side = 0.0; }
        }
        return d;
    }

    fragment float4 beach_sprite_fragment(BeachSpriteOut in [[stage_in]]) {
        int kind = int(in.info.x + 0.5);
        float aa = max(fwidth(in.uv.x), fwidth(in.uv.y)) * 1.2 + 1e-4;
        float3 col = in.tint.rgb;
        float a;
        if (kind == 0) {
            float d = gullDistance(in.uv, in.info.y);
            a = 1.0 - smoothstep(-aa, aa, d);
        } else if (kind == 1) {
            float spray;
            float d = dolphinDistance(in.uv, in.info.y, spray);
            float body = 1.0 - smoothstep(-aa, aa, d);
            // The sun catches its wet back along the top.
            col = col + float3(1.0, 0.75, 0.45) * in.tint.w * smoothstep(0.1, 0.0, abs(d + 0.03)) * step(-0.18, in.uv.y);
            float3 white = float3(0.85, 0.82, 0.78) * (0.5 + in.tint.w);
            a = max(body, 0.6 * spray);
            col = (col * body + white * 0.6 * spray) / max(a, 1e-3);
        } else {
            float side;
            float ct = cos(in.info.z), st = sin(in.info.z);   // its tilt
            float2 kv = float2(ct * in.uv.x + st * in.uv.y, -st * in.uv.x + ct * in.uv.y);
            float d = kiteDistance(kv, in.info.y, side);
            a = (1.0 - smoothstep(-aa, aa, d));
            float3 red = float3(0.85, 0.12, 0.1), yellow = float3(1.0, 0.72, 0.12);
            float3 cloth = side < 0.0 ? red : yellow;
            // Backlit, the cloth glows with the low sun through it; the spars and the tail stay dark.
            col = side == 0.0 ? in.tint.rgb * 0.4 : cloth * (in.tint.rgb * 1.5 + in.tint.w * 0.9);
            a *= side == 0.0 ? 1.0 : 0.92;
        }
        a *= in.info.w;
        if (a < 0.002) discard_fragment();
        return float4(col * a, a);
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light).
    struct BeachKey { float4 rect; float4 info; };
    struct BeachKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex BeachKeyOut beach_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BeachKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BeachKey k = keys[iid];
        BeachKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth beach_keys_fragment(BeachKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.006, 0.004, 0.003) : float3(0.05, 0.04, 0.03);
        float sheen = pow(in.uv.y, 6.0) * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 amber = float3(1.0, 0.68, 0.3);
        float3 c = base + amber * sheen * (0.4 + light) + amber * glow * (1.6 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.1, 0, 0, 1);
        return o;
    }
    """
}
