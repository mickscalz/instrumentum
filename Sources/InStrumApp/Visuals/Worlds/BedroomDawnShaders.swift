/// Metal source for Bedroom Window at Dawn: the view from a bedroom through a painted sash window behind sheer
/// curtains. Outside: low hills, a row of rooftops and chimneys (smoke on cold mornings), houses across the road
/// whose windows light up as the morning comes, a street lamp, a big tree whose leaves move in the wind (and the odd
/// bird), and the street, which mirrors the sky and the lights when it's wet. Inside: a plaster wall and the floor,
/// the window's light on the floor with the bars' and the leaves' shadows, light shafts from the panes (analytic,
/// no screen sampling), the sill with a plant and a steaming mug, sheer curtains lit through, dust motes, fairy
/// lights and soft peach keys. The glass and frame are the Window Kit's. Built on SkyShaders.common.
/// Smooth rules: no ray marching, ≤ 3 noise octaves, squares written out (no pow).
enum BedroomDawnShaders {
    static let source = SkyShaders.common + """
    struct BedU {
        float4 a;        // keys top (NDC y), aspect, horizon (NDC y), time
        float4 rect;     // glass NDC x0, y0, x1, y1
        float4 b;        // night 0…1, glow (after the limiter), morning light setting, direct sun through the window 0…1
        float4 c;        // street lamp 0…1, lit windows 0…8, wetness, mist
        float4 d;        // frame width (NDC x), quality (0 Smooth), sparkle scale, window open 0/1
        float4 beam;     // the beams' screen direction per unit (x, y), the beams' length, frost on the glass (sky)
        float4 light;    // outside light rgb, sun strength 0…1 (the room uses the direct sun, b.w)
        float4 tint;     // the glow's tint rgb, dust motes setting
        float4 e;        // wind, fairy lights level, floor line (NDC y), sill height
        float4 f;        // the floor patch's depth (window heights per floor depth), the window's bar count, unused…
        float4 birds[3]; // x (scene units), y (NDC), wing phase, flying 0/1 (x < -9: none)
        float4 bars[19]; // the Window Kit's bars: lo, hi (window coordinates), kind
        float4 plane;    // Excitement: a paper plane gliding past: x (scene units), y (NDC), roll (radians), heading ±1 (x < -9: none)
        float4 sillBird; // a bird on the outer sill: x (scene units), y (NDC: its feet), phase, ±1 perched / ±2 flying (x < -9: none)
        float4 prism;    // the rainbow on the wall: centre (NDC x, y), strength 0…1, its tilt (radians)
    };

    constant float2 bedQuad[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

    float bh11(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }
    float bh21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }
    float bvn1(float x) {
        float i = floor(x), f = fract(x);
        float u = f * f * (3.0 - 2.0 * f);
        return mix(bh11(i), bh11(i + 1.0), u);
    }
    float bvn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(bh21(i), bh21(i + float2(1, 0)), u.x), mix(bh21(i + float2(0, 1)), bh21(i + float2(1, 1)), u.x), u.y);
    }

    // Inside a pane (not on a bar or outside the glass), in window coordinates.
    bool inPane(float2 w, constant BedU& c) {
        if (w.x <= 0.0 || w.x >= 1.0 || w.y <= 0.0 || w.y >= 1.0) return false;
        int nBars = int(c.f.y);
        for (int i = 0; i < 19; i++) {
            if (i >= nBars) break;
            float4 bar = c.bars[i];
            if (bar.y <= bar.x) continue;
            float v = bar.z < 0.5 ? w.x : w.y;
            if (v >= bar.x && v <= bar.y) return false;
        }
        return true;
    }

    // The spectrum a bevelled edge throws: red at 0 … violet at 1, a little softened.
    float3 bedSpectrum(float t) {
        float h = 0.78 * saturate(t);
        float3 k = saturate(abs(fract(float3(h) + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0);
        return mix(k, float3(1.0), 0.12) * (1.0 - 0.35 * smoothstep(0.7, 1.0, t));
    }

    struct BedOut { float4 pos [[position]]; float2 ndc; };

    vertex BedOut bed_glass_vertex(uint vid [[vertex_id]], constant BedU& c [[buffer(1)]]) {
        float2 p = mix(c.rect.xy, c.rect.zw, bedQuad[vid]);
        BedOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    vertex BedOut bed_full_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        BedOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- outside the window
    fragment ColorDepth bed_scene_fragment(BedOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant BedU& c [[buffer(1)]],
                                        texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc;
        float aspect = c.a.y, horizon = c.a.z, time = c.a.w;
        float sx = ndc.x * aspect, sy = ndc.y;
        float night = c.b.x, lamp = c.c.x, litCount = c.c.y, wet = c.c.z, mist = c.c.w, wind = c.e.x;
        float3 d = normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
        float sunAlt = u.sun.w;
        float cloud = u.horizon.w;
        float sunUp = smoothstep(-3.0, 6.0, sunAlt) * (1.0 - 0.75 * cloud);
        float3 sunCol = mix(float3(1.0, 0.55, 0.32), float3(1.0, 0.95, 0.88), smoothstep(0.0, 25.0, sunAlt)) * 1.6 * sunUp;
        float3 skyAmb = u.zenith.rgb * 0.5 + u.horizon.rgb * 0.5;
        float3 haze = u.horizon.rgb;
        float3 Ls = float3(dot(u.sun.xyz, u.right.xyz), dot(u.sun.xyz, u.up.xyz), dot(u.sun.xyz, u.forward.xyz));
        float halfW = 0.5 * (c.rect.z - c.rect.x) * aspect;
        float glassBottom = c.rect.y;
        float3 warmLamp = float3(1.0, 0.72, 0.4);
        float3 windowWarm = float3(1.0, 0.74, 0.42);

        // ---- a paper plane gliding past and a bird on the sill (surprises), nearest of all: against the low sun mostly
        // in silhouette, rimmed with its light
        if (c.plane.x > -9.0) {
            float S = 0.045;
            // Seen a little from below, its wings show more of themselves as it rolls.
            float tilt = max(0.25, abs(sin(c.plane.z + 0.6)));
            float2 q = float2((sx - c.plane.x) * c.plane.w, (sy - c.plane.y) / tilt) / S;
            if (abs(q.x) < 0.7 && abs(q.y) < 0.4) {
                // A dart: nose ahead, its two wings folded back from the crease, the far wing a little darker.
                float span = 0.24 * (0.5 - q.x);
                bool wing = q.x > -0.5 && q.x < 0.5 && abs(q.y) < span;
                if (wing) {
                    float far = q.y > 0.0 ? 0.78 : 1.0;
                    float crease = 1.0 - 0.35 * exp(-q.y * q.y / 0.0006);
                    float3 paper = float3(0.92, 0.9, 0.86) * (skyAmb * 0.9 + sunCol * 0.45 * (0.5 + 0.5 * tilt)) * far * crease;
                    ColorDepth o; o.color = float4(paper, 1); o.depth = float4(0.25, 0, 0, 1); return o;
                }
            }
        }
        if (c.sillBird.x > -9.0) {
            float S = 0.05;
            float dir = c.sillBird.w < 0.0 ? -1.0 : 1.0;
            bool flying = abs(c.sillBird.w) > 1.5;
            float2 q = float2((sx - c.sillBird.x) * dir, sy - c.sillBird.y) / S;
            if (abs(q.x) < 1.2 && q.y > -0.1 && q.y < 1.2) {
                float bob = flying ? 0.0 : 0.04 * sin(c.sillBird.z);
                float2 bq = (q - float2(0.0, 0.4)) / float2(0.44, 0.32);
                float2 hq = (q - float2(0.32, 0.74 + bob)) / 0.21;
                float body = length(bq), head = length(hq);
                bool tail = q.x < -0.3 && q.x > -0.8 && abs(q.y - 0.36 - 0.25 * (q.x + 0.3)) < 0.06 + 0.12 * (-0.3 - q.x);
                bool beak = q.x > 0.48 && q.x < 0.62 && abs(q.y - 0.72 - bob) < 0.035 * (0.62 - q.x) / 0.14;
                bool legs = !flying && q.y < 0.12 && (abs(q.x + 0.06) < 0.02 || abs(q.x - 0.1) < 0.02);
                bool wings = false;
                if (flying) {
                    float flap = sin(c.sillBird.z) * 0.6;
                    wings = abs(q.y - 0.45 - abs(q.x) * flap) < 0.06 && abs(q.x) < 0.95;
                }
                float shape = min(body, head);
                if (shape < 1.0 || tail || beak || legs || wings) {
                    // A robin: olive-brown back, an orange-red breast, in the low sun's backlight with a bright rim.
                    bool breast = q.x > -0.05 && q.y < 0.68 && q.y > 0.12 && shape < 1.0;
                    float3 albedo = breast ? float3(0.75, 0.33, 0.12) : float3(0.3, 0.25, 0.17);
                    if (beak || legs) albedo = float3(0.12, 0.1, 0.08);
                    float rim = smoothstep(0.7, 1.0, shape) * (shape < 1.0 ? 1.0 : 0.0);
                    float3 col = albedo * (skyAmb * 0.55 + sunCol * 0.12) + sunCol * (0.45 * rim);
                    float2 eq = q - float2(0.38, 0.79 + bob);
                    if (dot(eq, eq) < 0.0025) col = float3(0.01) + sunCol * 0.05;
                    ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.2, 0, 0, 1); return o;
                }
            }
        }

        // ---- the big tree at the right, its canopy moving in the wind (nearest)
        float treeX = halfW * 0.78;
        float sway = (0.012 + 0.03 * wind) * sin(time * (0.7 + 0.6 * wind)) + 0.008 * sin(time * 2.3 + 1.0) * wind;
        {
            float trunkW = 0.035 + 0.02 * smoothstep(horizon + 0.2, glassBottom, sy);
            bool trunk = abs(sx - treeX - (sy - glassBottom) * 0.05) < trunkW && sy < horizon + 0.3;
            float2 cp = float2(sx - treeX - sway * (sy - horizon) * 2.0, sy - (horizon + 0.42));
            float r = length(cp * float2(0.85, 1.15));
            float leaves = bvn2(float2(sx * 18.0 + sway * 40.0, sy * 18.0)) * 0.6 + bvn2(float2(sx * 41.0 + sway * 90.0, sy * 41.0) + 3.3) * 0.4;
            bool canopy = r < 0.38 + 0.12 * (leaves - 0.5) && leaves > 0.32 + 0.4 * smoothstep(0.2, 0.42, r);
            // Branches reaching into the canopy.
            float br = abs(sx - treeX - 0.25 * (sy - horizon - 0.3) * sin(sy * 9.0) - sway);
            bool branch = br < 0.008 && sy > horizon + 0.25 && sy < horizon + 0.62;
            if (trunk || canopy || branch) {
                float3 col;
                if (canopy) {
                    float rim = smoothstep(0.25, 0.38, r) * sunUp;
                    col = float3(0.05, 0.09, 0.04) * (skyAmb * 1.5 + sunCol * 0.25) * (0.7 + 0.6 * leaves) + sunCol * float3(0.5, 0.45, 0.2) * rim * 0.4;
                    // Rime round the canopy's windward rim (spec §6.4), its feathers swaying with the leaves.
                    col = rimed(col, u, (0.38 + 0.12 * (leaves - 0.5) - r) / 1.15, cp * float2(0.72, 1.32), cp);
                } else {
                    col = float3(0.05, 0.04, 0.035) * (skyAmb * 1.3 + sunCol * 0.2);
                }
                col = mix(col, haze, 0.05 + 0.2 * mist);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.3, 0, 0, 1); return o;
            }
        }
        // ---- birds: on a branch or the rooftops, or flying off
        for (int i = 0; i < 3; i++) {
            float4 bd = c.birds[i];
            if (bd.x < -9.0) continue;
            float2 q = float2(sx - bd.x, sy - bd.y);
            float body = length(q * float2(1.0, 1.8));
            bool hit = body < 0.012;
            if (bd.w > 0.5) {
                float flap = sin(bd.z) * 0.012;
                bool wings = abs(q.y - abs(q.x) * (flap / 0.02)) < 0.0025 && abs(q.x) < 0.022;
                hit = hit || wings;
            } else {
                hit = hit || length(q - float2(0.009, 0.008)) < 0.006;   // head
            }
            if (hit) {
                float3 col = float3(0.03, 0.025, 0.025) * (skyAmb + 0.2);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.35, 0, 0, 1); return o;
            }
        }
        // ---- the street lamp on the near pavement, left
        float lampX = -halfW * 0.6, lampTop = horizon + 0.2;
        {
            bool post = abs(sx - lampX) < 0.007 && sy < lampTop && sy > glassBottom;
            bool arm = sy > lampTop - 0.008 && sy < lampTop && sx > lampX && sx < lampX + 0.06;
            float2 hq = float2(sx - lampX - 0.06, sy - lampTop + 0.012);
            bool head = abs(hq.x) < 0.02 && hq.y > -0.006 && hq.y < 0.01;
            if (post || arm || head) {
                float3 col = float3(0.03, 0.035, 0.04) * (skyAmb * 1.2 + sunCol * 0.2);
                if (head && hq.y < -0.002) col = warmLamp * 3.0 * lamp + float3(0.05) * (1.0 - lamp);
                // Rime up the post's windward side and along the arm's and the lamp's tops.
                float rimeIn = head ? 0.01 - hq.y : (arm ? lampTop - sy : 0.007 - abs(sx - lampX));
                col = rimed(col, u, rimeIn, (head || arm) ? float2(0.0, 1.0) : float2(sx < lampX ? -1.0 : 1.0, 0.0), float2(sx, sy));
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.4, 0, 0, 1); return o;
            }
        }
        float2 lampHead = float2(lampX + 0.06, lampTop - 0.014);
        float2 ld = float2(sx, sy) - lampHead;
        float lampGlow = lamp * (0.25 / (0.02 + dot(ld, ld) * 18.0));

        // ---- the street and pavement (foreground), mirroring the sky and the lights when wet
        float kerb = glassBottom + 0.22 * (horizon - glassBottom);
        float farKerb = horizon - 0.015;
        if (sy < farKerb) {
            float3 col;
            float depth;
            if (sy < kerb && sy > kerb - 0.03) {
                col = float3(0.32, 0.31, 0.3) * (skyAmb * 1.1 + sunCol * 0.3);    // the near pavement
                depth = 0.45;
            } else if (sy < kerb - 0.03) {
                float slab = step(0.94, fract(sx * 6.0)) + step(0.92, fract((sy - glassBottom) * 14.0));
                col = float3(0.3, 0.29, 0.28) * (skyAmb * 1.1 + sunCol * 0.3) * (1.0 - 0.25 * saturate(slab));
                depth = 0.42;
            } else {
                // Tarmac with a faint centre line.
                float t = saturate((farKerb - sy) / max(farKerb - kerb, 1e-3));
                float grit = bvn2(float2(sx * 60.0, sy * 140.0)) * 0.15;
                col = float3(0.07, 0.07, 0.075) * (skyAmb * 1.6 + sunCol * 0.5) * (0.92 + grit);
                float line = step(abs(sy - mix(farKerb, kerb, 0.45)), 0.0025 * (0.4 + t)) * step(0.5, fract(sx * 4.0));
                col = mix(col, float3(0.75, 0.72, 0.6) * (skyAmb + sunCol * 0.3), line * 0.6);
                // Wet: a mirror of the sky, with the lamp's and windows' light streaking toward us.
                if (wet > 0.02 && d.z < 0.0) {
                    float3 r = float3(d.x, d.y, -d.z);
                    float moonMask = 0.0;
                    float3 mirror = skyRadiance(r, u, moonMask, stars) * 0.55;
                    float ripple = 0.85 + 0.3 * bvn2(float2(sx * 25.0, sy * 90.0));
                    float streak = exp(-abs(sx - lampHead.x) * 30.0) * lamp * 2.0 * (1.0 - t * 0.6);
                    col = mix(col, mirror * ripple, wet * 0.7) + warmLamp * streak * wet;
                    for (int k = 0; k < 8; k++) {
                        if (float(k) >= litCount) break;
                        float wx = (-halfW * 0.85 + (float(k) + 0.5) * (halfW * 1.7 / 8.0));
                        col += windowWarm * exp(-abs(sx - wx) * 90.0) * 0.5 * wet * (1.0 - t);
                    }
                }
                depth = 0.5;
            }
            col += warmLamp * lampGlow * 0.6;
            col = mix(col, haze, 0.05 + 0.15 * mist);
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(depth, 0, 0, 1); return o;
        }

        // ---- the houses across the road: facades with windows, pitched roofs and chimneys
        float houseW = 0.36;
        float hid = floor((sx + 3.0) / houseW);
        float hx = (sx + 3.0) - hid * houseW;            // 0…houseW within the house
        float hr = bh11(hid * 3.17);
        float eave = horizon + 0.1 + 0.04 * hr;
        float ridgeH = eave + 0.06 + 0.03 * bh11(hid * 1.3);
        float roofLine = mix(eave, ridgeH, 1.0 - abs(hx / houseW * 2.0 - 1.0));
        float chimX = houseW * (0.25 + 0.5 * bh11(hid * 7.7));
        bool hasChimney = bh11(hid * 5.1) > 0.3;
        bool chimney = hasChimney && abs(hx - chimX) < 0.016 && sy < roofLine + 0.05 && sy > roofLine - 0.02;
        if (sy < roofLine || chimney) {
            float3 col;
            if (chimney) {
                col = float3(0.22, 0.12, 0.09) * (skyAmb * 1.2 + sunCol * 0.4 * saturate(Ls.x + 0.4));
            } else if (sy > eave) {
                // Slate roof catching the morning light on one side, with a few rows of tiles.
                float tiles = 0.85 + 0.15 * step(0.5, fract((sy - eave) * 90.0));
                float side = hx / houseW < 0.5 ? 1.0 : 0.0;
                col = float3(0.12, 0.12, 0.14) * tiles * (skyAmb * 1.3 + sunCol * 0.5 * (side > 0.5 ? saturate(-Ls.x + 0.5) : saturate(Ls.x + 0.5)));
                // Frost on the roofs on cold mornings.
                col = mix(col, float3(0.85, 0.88, 0.95) * (skyAmb * 1.3 + sunCol * 0.4), saturate(c.beam.w * 1.5) * 0.6);
                // Rime along the roof line (spec §6.4): the depth below it, square to the slope.
                float slope = (ridgeH - eave) * 2.0 / houseW * (hx < 0.5 * houseW ? 1.0 : -1.0);
                col = rimed(col, u, (roofLine - sy) * rsqrt(1.0 + slope * slope), float2(-slope, 1.0), float2(sx, sy));
            } else {
                // Facade: painted brick, two windows per house, lit as the morning comes.
                float3 paint = mix(float3(0.42, 0.3, 0.24), float3(0.55, 0.5, 0.42), hr);
                col = paint * (skyAmb * 1.1 + sunCol * 0.35 * saturate(Ls.z * 0.5 + 0.5));
                float wy = (sy - farKerb) / max(eave - farKerb, 1e-3);
                for (int k = 0; k < 2; k++) {
                    float wxc = houseW * (0.28 + 0.44 * float(k));
                    if (abs(hx - wxc) < 0.035 && wy > 0.35 && wy < 0.85) {
                        int index = int(hid) * 2 + k;
                        float order = bh11(float(index) * 2.71);
                        bool lit = order * 8.0 < litCount;
                        float3 glass = mix(skyAmb * 0.35, windowWarm * 1.6, lit ? 1.0 : 0.0);
                        float frameLine = step(0.004, abs(hx - wxc)) * step(0.006, abs(wy - 0.6) * (eave - farKerb));
                        col = mix(float3(0.85, 0.83, 0.78) * (skyAmb + sunCol * 0.3), glass, frameLine);
                    }
                }
                // The front door of every other house.
                if (int(hid) % 2 == 0 && abs(hx - houseW * 0.5) < 0.025 && wy < 0.32) col = float3(0.12, 0.2, 0.25) * (skyAmb + sunCol * 0.3);
            }
            col += warmLamp * lampGlow * 0.4;
            col = mix(col, haze, 0.12 + 0.45 * mist);
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.7, 0, 0, 1); return o;
        }
        // ---- the far hills, low and hazy
        float hill = horizon + 0.05 + 0.07 * bvn1(sx * 1.1 + 4.0) + 0.025 * bvn1(sx * 3.7);
        float3 behind = float3(0);
        float behindA = 0.0;
        if (sy < hill) {
            float3 col = float3(0.2, 0.25, 0.22) * (skyAmb * 1.2 + sunCol * 0.3);
            behind = mix(col, haze, 0.55 + 0.3 * mist);
            behindA = 1.0;
        }
        // ---- chimney smoke on cold mornings, leaning with the wind, over the hills or sky
        float smoke = 0.0;
        if (c.beam.w > 0.2) {
            for (int k = -1; k <= 1; k++) {
                float id = floor((sx + 3.0) / houseW) + float(k);
                if (bh11(id * 5.1) <= 0.3) continue;
                float cx = id * houseW - 3.0 + houseW * (0.25 + 0.5 * bh11(id * 7.7));
                float rl = horizon + 0.1 + 0.04 * bh11(id * 3.17);
                float ridge2 = rl + 0.06 + 0.03 * bh11(id * 1.3);
                float localX = houseW * (0.25 + 0.5 * bh11(id * 7.7));
                float top = mix(rl, ridge2, 1.0 - abs(localX / houseW * 2.0 - 1.0)) + 0.05;
                float rise = sy - top;
                if (rise <= 0.0 || rise > 0.3) continue;
                float centre = cx + rise * (0.1 + 0.8 * wind) + 0.012 * sin(rise * 20.0 - time * 0.6 + id);
                float q = (sx - centre) / (0.005 + rise * 0.15);
                float n = bvn2(float2(sx * 30.0, sy * 30.0 - time * 0.4 + id)) * 0.6 + bvn2(float2(sx * 64.0, sy * 64.0 - time * 0.8)) * 0.4;
                smoke = max(smoke, exp(-q * q) * smoothstep(0.25, 0.7, n) * (1.0 - smoothstep(0.08, 0.3, rise)) * saturate((c.beam.w - 0.2) * 4.0) * 0.7);
            }
        }
        float3 smokeCol = skyAmb * 1.2 + sunCol * 0.3;
        float3 col = behind * behindA * (1.0 - smoke) + smokeCol * smoke + warmLamp * lampGlow * 0.3;
        float a = 1.0 - (1.0 - behindA) * (1.0 - smoke);
        // Mist between the houses after the rain, and the lamp's glow in the air.
        col = mix(col, haze * a, mist * 0.3 * behindA);
        if (a < 0.003 && lampGlow < 0.003) discard_fragment();
        ColorDepth o; o.color = float4(col, a); o.depth = float4(behindA > 0.5 ? 0.9 : 0.95, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the room: wall, floor, the window's light, the sill
    fragment ColorDepth bed_room_fragment(BedOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant BedU& c [[buffer(1)]]) {
        float2 p = in.ndc;
        float aspect = c.a.y, time = c.a.w;
        float fw = c.d.x, fh = c.d.x * aspect;
        float4 outer = c.rect + float4(-fw, -fh, fw, fh);
        float sx = p.x * aspect, sy = p.y;
        float sillTop = outer.y, sillH = c.e.w;
        // The plant and the mug stand on the sill, in front of the window's lower frame.
        float2 potP = float2(sx - (outer.x + 0.16) * aspect, sy - (sillTop - 0.01));
        float2 mugP = float2(sx - (outer.z - 0.18) * aspect, sy - (sillTop - 0.012));
        bool overWindow = p.x > outer.x && p.x < outer.z && p.y > outer.y && p.y < outer.w;
        bool mayHit = (abs(potP.x) < 0.12 && potP.y > 0.0 && potP.y < 0.3) || (abs(mugP.x) < 0.09 && mugP.y > 0.0 && mugP.y < 0.3);
        if (overWindow && !mayHit) discard_fragment();

        float night = c.b.x, glow = c.b.y, setting = c.b.z, direct = c.b.w;
        float3 outside = c.light.rgb;
        float3 tint = c.tint.rgb;
        float3 sunLight = float3(1.0, 0.86, 0.68) * direct;
        float floorLine = c.e.z;
        float wallLight = 0.0;
        // Soft light from the window across the wall, and the morning glow (held notes) warming it.
        float2 nearest = clamp(p, outer.xy, outer.zw);
        float wd = length((p - nearest) * float2(aspect, 1.0));
        float3 fromWindow = (outside * 0.45 + sunLight * 0.25) * exp(-wd * 2.2) * (1.0 + 0.8 * glow * setting) * tint;
        float3 lampThrough = float3(1.0, 0.72, 0.4) * c.c.x * night * 0.08 * exp(-wd * 1.5);
        float3 fairyGlow = float3(1.0, 0.75, 0.45) * c.e.y * 0.12 * exp(-max(0.0, outer.w + 0.06 - sy) * 2.5) * exp(-abs(sx) * 0.4);
        float3 ambient = outside * 0.06 + float3(0.02, 0.018, 0.016);
        float3 col;
        float depth = 0.06;
        if (sy > floorLine) {
            // Warm plaster, faintly mottled; a skirting board above the floor.
            float mottle = bvn2(float2(sx * 4.0, sy * 4.0)) * 0.06 + bvn2(float2(sx * 23.0, sy * 23.0)) * 0.03;
            float3 albedo = float3(0.82, 0.76, 0.68) * (0.95 + mottle);
            col = albedo * (fromWindow + lampThrough + fairyGlow + ambient);
            if (sy < floorLine + 0.04) col = float3(0.9, 0.88, 0.84) * (fromWindow * 0.8 + ambient + fairyGlow) * (sy < floorLine + 0.006 ? 0.6 : 1.0);
            wallLight = 1.0;
            // The rainbow (a surprise): the low sun split by the glass's bevelled edge, a short bright band of spectrum
            // on the plaster.
            if (c.prism.z > 0.001) {
                float2 d = float2((p.x - c.prism.x) * aspect, p.y - c.prism.y);
                float ca = cos(c.prism.w), sa = sin(c.prism.w);
                float along = d.x * ca + d.y * sa, across = -d.x * sa + d.y * ca;
                across -= 1.6 * along * along;
                float band = (1.0 - smoothstep(0.045, 0.075, abs(along))) * (1.0 - smoothstep(0.016, 0.024, abs(across)));
                if (band > 0.0) {
                    float3 spec = bedSpectrum(across / 0.04 + 0.5);
                    col += albedo * spec * (band * c.prism.z * 0.9);
                }
            }
        } else {
            // Floorboards, and the window's light on them: the panes with the bars' shadows and dappled leaves.
            float k = saturate((floorLine - sy) / max(floorLine - c.a.x, 1e-3));    // 0 at the wall … 1 near us
            float boards = 0.88 + 0.12 * step(0.5, fract(sx * (5.0 / (1.0 + 2.0 * k))));
            float grain = bvn2(float2(sx * 2.0 / (1.0 + k), sy * 60.0)) * 0.1;
            float3 albedo = float3(0.5, 0.36, 0.24) * (boards + grain);
            col = albedo * (fromWindow * 0.7 + ambient + lampThrough + fairyGlow * 0.5);
            // The patch: the window seen along the sun's direction, foreshortened on the floor.
            // Light through the bottom of the window lands by the wall; through the top, further into the room.
            float wy = k / max(c.f.x, 0.2);
            float side = c.beam.x * k * 0.6;
            float glassW = (c.rect.z - c.rect.x);
            float wx = 0.5 + (p.x - 0.5 * (c.rect.x + c.rect.z) - side) / (glassW * (1.0 + 0.7 * k));
            bool lit = inPane(float2(wx, wy), c);
            float leaves = bvn2(float2(sx * 9.0 + time * 0.3 * (0.3 + c.e.x), sy * 20.0 + sin(time * 0.8) * 0.3 * c.e.x)) * 0.6
                         + bvn2(float2(sx * 21.0 - time * 0.5 * c.e.x, sy * 41.0)) * 0.4;
            float dapple = 0.8 + 0.2 * smoothstep(0.3, 0.6, leaves);
            float patch = lit ? dapple : 0.0;
            // Sunlit boards read pale gold rather than orange.
            float3 litAlbedo = mix(albedo, float3(0.78, 0.66, 0.52), 0.4);
            col += litAlbedo * (sunLight * 0.9 * (0.45 + 0.55 * glow) * setting + outside * 0.2) * tint * patch;
            depth = 0.08 + 0.1 * k;
        }

        // The sill: a painted ledge under the window.
        bool onSill = sy <= sillTop && sy > sillTop - sillH && p.x > outer.x - 0.05 && p.x < outer.z + 0.05;
        if (onSill) {
            float topFace = sillTop - 0.035;
            float3 albedo = float3(0.9, 0.88, 0.84);
            float lit = sy > topFace ? 1.0 : 0.5;
            col = albedo * ((fromWindow * 1.4 + sunLight * 0.5 * (0.4 + 0.6 * glow)) * lit + ambient + fairyGlow);
            if (sy > topFace && sy < topFace + 0.003) col *= 1.15;
            depth = 0.05;
        }
        // A plant in a terracotta pot.
        float3 objLight = fromWindow * 1.2 + sunLight * 0.4 + ambient + fairyGlow;
        bool potHit = abs(potP.x) < 0.04 - potP.y * 0.12 && potP.y > 0.0 && potP.y < 0.07;
        float leafN = bvn2(float2(potP.x * 40.0, potP.y * 30.0)) * 0.6 + bvn2(float2(potP.x * 90.0 + 2.0, potP.y * 70.0)) * 0.4;
        float2 lp = potP - float2(0.0, 0.13);
        bool leafHit = length(lp * float2(1.0, 1.3)) < 0.075 + 0.04 * (leafN - 0.5) && potP.y > 0.06 && leafN > 0.35;
        if (potHit) { col = float3(0.62, 0.32, 0.2) * objLight * (0.8 + 0.2 * (potP.x / 0.04 * -0.5 + 0.5)); depth = 0.04; }
        else if (leafHit) { col = float3(0.12, 0.3, 0.1) * objLight * (0.6 + 0.6 * leafN) + float3(0.3, 0.4, 0.1) * sunLight * 0.3 * smoothstep(0.5, 0.8, leafN); depth = 0.04; }
        // A mug with steam curling up (bending away when the window is open).
        float mugW = 0.042, mugH = 0.075;
        bool mugBody = abs(mugP.x) < mugW && mugP.y > 0.0 && mugP.y < mugH;
        float ring = abs(length(float2(mugP.x - mugW - 0.005, mugP.y - mugH * 0.5)) - 0.022);
        bool handle = ring < 0.007 && mugP.x > mugW - 0.003;
        if (mugBody || handle) {
            float shade = mugBody ? sqrt(saturate(1.0 - (mugP.x / mugW) * (mugP.x / mugW))) : 0.6;
            col = float3(0.78, 0.82, 0.86) * objLight * (0.55 + 0.45 * shade);
            if (mugBody && mugP.y > mugH - 0.007) col *= 0.45;
            depth = 0.04;
        }
        float steam = 0.0;
        {
            float rise = mugP.y - mugH;
            if (rise > 0.0 && rise < 0.22) {
                float bend = c.d.w * rise * rise * 3.0;
                float centre = 0.006 * sin(rise * 45.0 - time * 2.0) + bend;
                float q = (mugP.x - centre) / (0.003 + rise * 0.05);
                // Thin wisps that break up as they rise.
                float n = bvn2(float2(mugP.x * 90.0, rise * 45.0 - time * 1.5));
                steam = exp(-q * q) * smoothstep(0.45, 0.75, n) * smoothstep(0.0, 0.015, rise) * (1.0 - smoothstep(0.04, 0.18, rise)) * 0.2;
                col += (objLight * 0.8 + 0.03) * steam;
            }
        }
        bool objectHit = potHit || leafHit || mugBody || handle || steam > 0.03;
        if (overWindow && !objectHit) discard_fragment();
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- light shafts (additive, analytic)
    fragment float4 bed_shaft_fragment(BedOut in [[stage_in]], constant BedU& c [[buffer(1)]]) {
        float2 p = in.ndc;
        float strength = c.b.w * c.b.z * (0.45 + 0.55 * c.b.y);
        if (strength < 0.002) discard_fragment();
        float2 v = c.beam.xy;
        float len = c.beam.z;
        // Only pixels the window can reach along the beams: the glass swept down along v.
        float2 lo = c.rect.xy + min(float2(0.0), v * len), hi = c.rect.zw + max(float2(0.0), v * len);
        if (p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y) discard_fragment();   // outside every beam
        int n = c.d.y > 0.5 ? 14 : 7;
        float sum = 0.0;
        for (int i = 0; i < 14; i++) {
            if (i >= n) break;
            float s = (float(i) + 0.5) / float(n) * len;
            float2 q = p - v * s;
            float2 w = (q - c.rect.xy) / max(c.rect.zw - c.rect.xy, float2(1e-5));
            if (inPane(w, c)) sum += 1.0 - s / len;
        }
        sum /= float(n);
        float density = 1.0;
        if (c.d.y > 0.5) {
            density = 0.6 + 0.8 * bvn2(float2(p.x * c.a.y * 6.0 + c.a.w * 0.05, p.y * 6.0 - c.a.w * 0.03));
        }
        float3 col = float3(1.0, 0.86, 0.66) * c.tint.rgb * sum * strength * density * (0.4 + 0.6 * c.tint.w) * 0.95;
        return float4(col, 0.0);
    }

    // ---------------------------------------------------------------- curtains: translucent sheers lit through
    struct CurtainVertex { float4 a; float4 b; };   // a: ndc.x, ndc.y, z (toward us), fold 0…1; b: normal xyz, u 0…1
    struct CurtainOut { float4 pos [[position]]; float2 ndc; float z; float fold; float3 normal; float u; };

    vertex CurtainOut bed_curtain_vertex(uint vid [[vertex_id]], constant CurtainVertex* vs [[buffer(0)]]) {
        CurtainVertex v = vs[vid];
        CurtainOut o;
        o.pos = float4(v.a.xy, 0, 1);
        o.ndc = v.a.xy;
        o.z = v.a.z;
        o.fold = v.a.w;
        o.normal = v.b.xyz;
        o.u = v.b.w;
        return o;
    }

    fragment float4 bed_curtain_fragment(CurtainOut in [[stage_in]], constant BedU& c [[buffer(1)]]) {
        float2 w = (in.ndc - c.rect.xy) / max(c.rect.zw - c.rect.xy, float2(1e-5));
        bool overGlass = w.x > 0.0 && w.x < 1.0 && w.y > 0.0 && w.y < 1.0;
        float3 n = normalize(in.normal);
        // Folds seen edge-on are denser; a sheer seen face-on lets most light through.
        float edgeOn = 1.0 - abs(n.z);
        float density = saturate(0.28 + 0.5 * edgeOn + 0.15 * in.fold);
        float3 outside = c.light.rgb;
        float3 sun = float3(1.0, 0.86, 0.68) * c.b.w;
        float glow = c.b.y * c.b.z;
        float3 tint = c.tint.rgb;
        // Back-lit by the window (and the sun), front-lit by the room.
        float3 back = (outside * 0.9 + sun * 0.9 * (0.4 + 0.6 * glow)) * tint * (overGlass ? 1.0 : 0.35);
        float rim = smoothstep(0.55, 0.95, edgeOn) * (overGlass ? 1.0 : 0.3);
        float3 front = float3(0.95, 0.93, 0.9) * (outside * 0.12 + float3(1.0, 0.75, 0.45) * c.e.y * 0.08 + c.c.x * c.b.x * float3(1.0, 0.72, 0.4) * 0.05);
        float weave = 0.95 + 0.05 * sin(in.ndc.y * 900.0);
        float3 col = (front + back * (0.55 + 0.6 * rim)) * weave;
        float alpha = density * 0.85;
        return float4(col * alpha, alpha);
    }

    // ---------------------------------------------------------------- motes and fairy lights (additive sprites)
    struct Sprite { float4 a; float4 b; };   // a: x, y (NDC), size (NDC x), brightness; b: rgb, kind (0 mote, 1 bulb)
    struct SpriteOut { float4 pos [[position]]; float2 uv; float bright; float3 col; float kind; };
    vertex SpriteOut bed_sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Sprite* ss [[buffer(0)]],
                                       constant BedU& c [[buffer(1)]]) {
        float2 q = bedQuad[vid] * 2.0 - 1.0;
        Sprite s = ss[iid];
        SpriteOut o;
        o.uv = q;
        o.pos = float4(s.a.xy + q * float2(s.a.z, s.a.z * c.a.y), 0, 1);
        o.bright = s.a.w;
        o.col = s.b.rgb;
        o.kind = s.b.w;
        return o;
    }
    fragment float4 bed_sprite_fragment(SpriteOut in [[stage_in]]) {
        float r = length(in.uv);
        float a;
        if (in.kind < 0.5) {
            a = exp(-r * r * 9.0);
        } else {
            a = exp(-r * r * 30.0) * 1.5 + exp(-r * r * 4.0) * 0.25;   // a bulb with a soft halo
        }
        a *= (1.0 - smoothstep(0.8, 1.0, r)) * in.bright;
        return float4(in.col * a, 0.0);
    }

    // ---------------------------------------------------------------- keys: soft peach where you play
    struct BedKey { float4 rect; float4 info; };
    struct BedKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex BedKeyOut bed_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BedKey* keys [[buffer(0)]]) {
        BedKey k = keys[iid];
        BedKeyOut o;
        o.uv = bedQuad[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth bed_keys_fragment(BedKeyOut in [[stage_in]], constant BedU& c [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.03, 0.028, 0.03) : float3(0.62, 0.6, 0.58);
        float y2 = in.uv.y * in.uv.y;
        float sheen = y2 * y2 * y2 * (black ? 0.06 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.05, in.uv.x) * smoothstep(1.0, 0.95, in.uv.x);
        float3 peach = float3(1.0, 0.62, 0.48);
        float3 col = base * (0.15 + light) + float3(1.0) * sheen * (0.3 + light) + peach * glow * (1.4 * (0.3 + 0.7 * in.uv.y));
        col *= 0.6 + 0.4 * edge;
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
