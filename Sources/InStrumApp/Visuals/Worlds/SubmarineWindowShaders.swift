/// Metal source for Submarine Window (spec §8.1, §8.2): the sea outside the porthole at the chosen depth (the Underwater
/// Kit's water, Snell's window with the sky in it, a sand-and-coral slope under its caustics, light shafts, rain rings
/// on the surface, sea smoke's milky window, the outside lamps' beams), Deep Lights' living light and the marine snow as
/// sprites, then the cabin around the brass porthole (painted steel in its own soft light, cables, a padded console
/// edge, the brass depth gauge and the sonar screen) and the backlit console buttons.
/// Smooth rules: no ray marching, at most 2 noise octaves here (the Kit's own stay within its rules), no `pow`.
enum SubmarineWindowShaders {
    static let source = SkyShaders.common + UnderwaterShaders.common + """
    // ================================================================ Submarine Window
    struct SubU {
        float4 view;     // the glass's centre (NDC x, y), its radius (NDC-y units), aspect (w/h)
        float4 cam;      // view azimuth (rad), pitch (rad, up +), tan of the half view at the glass's rim, time (s)
        float4 sea;      // depth (m), waves 0…1, rain on the surface 0…1, sea smoke's milkiness 0…1
        float4 light;    // the light falling on the surface (rgb), the shafts' strength
        float4 shaft;    // the shafts' direction on screen (x, y), a pixel's angle (rad), Snell's window 0…1
        float4 lamp;     // the outside lamps 0…1, the night eye's gain, the floor below the viewer (m; 0 none), quality
        float4 cabin;    // the cabin's light (rgb, its colour × the setting), the keys' top (NDC y)
        float4 room;     // the ring's outer radius (NDC-y units), the console's top (NDC y), night 0…1, the ring's width
        float4 glow;     // the sea's light through the glass (rgb: what spills round the ring), the sonar screen 0…1
        float4 gauge;    // the depth gauge's centre (NDC x, y), its face's radius (NDC-y units), the needle (rad, cw from up)
        float4 sonar;    // the sonar screen's centre (NDC x, y), its radius, the sweep (rad, clockwise from the top)
        float4 misc;     // blips shown, living light on the wall 0…1, the cables' sag, the view's height (px)
        float4 whale;    // Excitement: a whale passing: its middle (disc units, radius 1), its half-length (disc radii), presence 0…1
        float4 whaleB;   // its heading ±1, its flukes' beat (turns), how far off it is (0 close … 1 far), unused
        float4 contact;  // a far sub's sonar contact: bearing (rad), range 0…1, strength 0…1, its ping's phase 0…1
        float4 blips[24];// bearing (rad, clockwise from the top), range 0…1, brightness 0…1, unused
    };
    constant int kSubBlips = 24;
    constant float3 kLampColour = float3(1.0, 0.92, 0.8);
    /// The floor's slope, rising away ahead (metres up a metre out).
    constant float kSubSlope = 0.3;

    struct SubOut { float4 pos [[position]]; float2 ndc; };

    /// A humpback side on (a big moment), in its own units (x along the body, the snout at about +1.05, the flukes' tips
    /// at about −1.35; y up): how much of a point it covers (soft by `px`, its own units' pixel), and through `pale` how
    /// much of it is the pale underside and the long pale pectoral fins. Its tail stock flexes with the beat and the
    /// flukes, edge on, pitch with it.
    float subWhale(float2 p, float beat, float px, thread float& pale) {
        pale = 0.0;
        float x = p.x, y = p.y;
        float b = sin(beat * 6.2831853);
        float back = max(0.0, -0.45 - x);
        float yb = y - 0.11 * b * back * back;
        // The body: fuller toward the head, a small dorsal hump two-thirds back, the stock narrowing to the flukes.
        float e = (x - 0.12) / 0.93;
        float half = 0.19 * sqrt(max(0.0, 1.0 - e * e)) * (0.82 + 0.18 * smoothstep(-0.8, 0.5, x));
        float stock = (x < -0.5 && x > -1.18) ? 0.028 + 0.1 * smoothstep(-1.18, -0.5, x) : 0.0;
        float top = max(half, stock) + (yb > 0.0 ? 0.035 * exp(-((x + 0.42) / 0.07) * ((x + 0.42) / 0.07)) : 0.0);
        float body = 1.0 - smoothstep(-px, px, abs(yb + 0.015 * x) - top);
        // The flukes, edge on: a thin blade at the stock's end, pitching with the beat.
        float2 fq = float2(x + 1.24, yb + 0.11 * b * 0.6);
        float ang = 0.55 * b;
        float ca = cos(ang), sa = sin(ang);
        float2 fr = float2(fq.x * ca - fq.y * sa, fq.x * sa + fq.y * ca);
        float fl = length(fr / float2(0.13, 0.026 + 0.05 * abs(b))) - 1.0;
        float fluke = 1.0 - smoothstep(-px * 8.0, px * 8.0, fl);
        // The pectoral fin: long and pale, swept back and down from behind the head, slowly sculling.
        float fa = -2.45 + 0.12 * sin(beat * 6.2831853 + 1.0);
        float2 fd = float2(cos(fa), sin(fa));
        float2 fv = p - float2(0.42, -0.07);
        float along = dot(fv, fd), across = dot(fv, float2(-fd.y, fd.x));
        float finW = 0.05 * (1.0 - saturate(along / 0.46)) + 0.012;
        float fin = (along > 0.0 && along < 0.46) ? 1.0 - smoothstep(finW - px, finW + px, abs(across)) : 0.0;
        // The pale underside: below the body's middle line, brightest toward the throat.
        float under = 1.0 - smoothstep(-0.08, 0.0, yb + 0.03);
        pale = max(fin, body * under * (0.5 + 0.5 * smoothstep(-0.6, 0.5, x)));
        return max(max(body, fluke), fin);
    }

    vertex SubOut sub_full_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
        SubOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    /// The outside lamps' beams in the porthole's disc (radius 1, y up): two warm-white floodlights below the glass to
    /// either side, aimed up and in, widening and fading as they reach out. The renderer's `lampLight` is the same sum.
    float subLampBeams(float2 q) {
        float sum = 0.0;
        for (int i = 0; i < 2; i++) {
            float side = i == 0 ? -1.0 : 1.0;
            float2 src = float2(side * 0.92, -1.08);
            float2 axis = normalize(float2(-side * 0.42, 1.0));
            float2 v = q - src;
            float along = dot(v, axis);
            if (along <= 0.0) continue;
            float across = dot(v, float2(axis.y, -axis.x));
            float spread = 0.06 + 0.22 * along;
            sum += exp(-(across * across) / (spread * spread)) * exp(-0.85 * along) * smoothstep(0.0, 0.25, along);
        }
        return sum;
    }

    /// Rain on the surface seen from below (spec §8.1): rings spreading from each drop, on the surface's underside where
    /// the ray `d` meets it from `depth`; 0 where they would be finer than a pixel.
    float subRainRings(float3 d, float depth, float t, float rain, float pixel) {
        if (rain <= 0.001 || d.z < 0.12) return 0.0;
        float S = depth / d.z;
        float2 P = d.xy * S / 1.3;                       // cells 1.3 m across, one drop each at a time
        float2 cell = floor(P), f = P - cell;
        float3 h = hash33(float3(cell, 7.7));
        if (h.z > rain) return 0.0;                      // fewer drops in lighter rain
        float period = 0.7 + 0.9 * h.y;
        float age = fract(t / period + h.x);
        float2 c0 = 0.25 + 0.5 * h.xy;
        float dist = length(f - c0) * 1.3;               // metres from the drop
        float radius = 0.05 + 0.5 * age, width = 0.035 + 0.03 * age;
        float x = (dist - radius) / width;
        float foot = S * pixel / max(d.z, 0.1);
        float fine = 1.0 - smoothstep(0.6, 2.0, foot / width);
        float fade = (1.0 - age) * (1.0 - age);
        return exp(-x * x) * fade * fine;
    }

    fragment ColorDepth sub_sea_fragment(SubOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                         constant SubU& s [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float aspect = s.view.w;
        float2 q = (in.ndc - s.view.xy) * float2(aspect, 1.0) / max(s.view.z, 1e-3);   // the porthole's disc: radius 1
        float az = s.cam.x, pitch = s.cam.y, tanR = s.cam.z, t = s.cam.w;
        float3 fwd = float3(sin(az) * cos(pitch), cos(az) * cos(pitch), sin(pitch));
        float3 right = float3(cos(az), -sin(az), 0.0);
        float3 up = cross(right, fwd);
        float3 d = normalize(fwd + right * (q.x * tanR) + up * (q.y * tanR));
        float D = max(s.sea.x, 0.0), waves = s.sea.y, rain = s.sea.z, milky = s.sea.w;
        float3 L = s.light.rgb;
        float pixel = s.shaft.z;

        // The open water, and what comes through the surface above (Snell's window, in the shallows): the sky's part is
        // kept apart, as the night eye's gain lifts the water and not the stars.
        float3 col = waterView(d, D, L);
        float3 skyPart = float3(0.0);
        float depthOut = 1.0;
        // The floor: a sand-and-coral slope rising gently away ahead (in the shallows), met before the surface.
        float2 ahead = normalize(float2(sin(az), cos(az)));
        float denom = kSubSlope * dot(d.xy, ahead) - d.z;
        float floorDist = denom > 1e-4 && s.lamp.z > 0.0 ? s.lamp.z / denom : 1e9;
        bool onFloor = floorDist < 160.0 && d.z < 0.03;
        if (!onFloor && d.z > 0.0 && s.shaft.w > 0.001) {
            float window;
            float3 mirror = waterView(float3(d.x, d.y, -d.z), 0.0, L);
            float3 through = snellWindow(d, D, t, waves, mirror, u, stars, window);
            // Sea smoke: the fog over the water lights the whole underside of the surface evenly, so the window's sharp
            // circle and its sky melt into a soft milky glow rising overhead.
            if (milky > 0.001) {
                float3 fogSky = mix(u.horizon.rgb, u.zenith.rgb, 0.4) * 1.4 + float3(0.05);
                float3 fog = fogSky * kWindowGain * waterAbsorb(D / max(d.z, 0.05)) * (1.0 - smoothstep(20.0, 40.0, D))
                           * smoothstep(0.15, 0.95, d.z);
                through = mix(through, fog * 0.8 + through * 0.2, 0.85 * milky);
            }
            float ring = subRainRings(d, D, t, rain, pixel);
            skyPart = through + (through * 0.9 + 0.05 * L) * ring * rain;
        } else if (onFloor) {
            // Lit from above through the caustics, seen through the water between.
            {
                float dist = floorDist;
                {
                    float3 p = float3(d.xy * dist, -D + d.z * dist);
                    float floorDepth = max(-p.z, 0.0);
                    float footprint = dist * pixel / max(-d.z + 0.1, 0.05);
                    // Coral heads in clumps of a few colours, sand between (2 octaves, settled where finer than a pixel).
                    float2 cq = p.xy * 0.32;
                    float n1 = vnoise3(float3(cq, 1.7));
                    float fine = 1.0 - smoothstep(0.4, 1.6, footprint * 0.9);
                    float n2 = mix(0.5, vnoise3(float3(cq * 2.9 + 3.1, 4.1)), fine);
                    float clump = smoothstep(0.56, 0.7, 0.7 * n1 + 0.3 * n2);
                    float3 hc = hash33(float3(floor(cq * 1.4), 2.0));
                    float3 hue = mix(mix(float3(0.62, 0.32, 0.42), float3(0.7, 0.5, 0.26), hc.x), float3(0.35, 0.5, 0.42), hc.y * hc.y);
                    float3 albedo = mix(float3(0.85, 0.8, 0.66) * (0.9 + 0.1 * n2), hue * (0.75 + 0.35 * n2), clump);
                    // The net drawn a little shallower than it lies, so the slope's sunlit sand still dances at 20 m.
                    float lit = caustics(float3(p.xy, -0.58 * floorDepth), t, footprint) * (1.0 - 0.2 * clump * (1.0 - n2));
                    float3 ground = albedo * waterLight(floorDepth, L) * lit * 0.85;
                    float3 T = waterAbsorb(dist);
                    float shown = (1.0 - smoothstep(45.0, 90.0, D)) * (1.0 - smoothstep(-0.03, 0.03, d.z));
                    col = mix(col, col * (1.0 - T) + ground * T, shown);
                    depthOut = saturate(dist / 60.0);
                }
            }
        }

        // Shafts of the sun (or a bright moon) slanting down from the surface, flickering with it.
        // (Lifted with depth, where the eye picks them out of the dark blue: a faint glow far above still reaches down.)
        float shaftLift = 1.0 + 1.8 * smoothstep(20.0, 80.0, D);
        col += lightShafts(q * 0.8, s.shaft.xy, t, D, waves) * waterLight(D, L) * kWaterTint * (s.light.w * shaftLift);

        // The eye's adaptation to the depth (and, in the shallows at night, to the dark).
        // (At night the window's stars are softened: seen through the surface's ripples they would read as a blizzard.)
        col = (col * s.lamp.y + skyPart * ((1.0 + 0.12 * (s.lamp.y - 1.0)) * (1.0 - 0.55 * s.room.z))) * waterAdapt(D);
        // The eye keeps a little green and red in a deep blue, so it reads as sea, not as a screen's blue.
        col.g = max(col.g, 0.28 * col.b);
        col.r = max(col.r, 0.03 * col.b);

        // The outside lamps: warm-white beams in the water, turning blue-green as they reach out.
        float beams = subLampBeams(q);
        float3 beamCol = mix(kLampColour, float3(0.55, 0.85, 1.0), saturate(0.35 * (q.y + 1.0)));
        col += beamCol * (beams * s.lamp.x * 0.45);

        // A whale passing (a big moment): a dark shape out of the blue, its pale fins and underside catching the light from
        // above and the lamps' beams, melting into the water the farther off it swims.
        if (s.whale.w > 0.002) {
            float2 wq = (q - s.whale.xy) / max(s.whale.z, 0.05);
            wq.x *= s.whaleB.x;
            if (abs(wq.x) < 1.5 && abs(wq.y) < 0.6) {
                float px = 2.0 / (max(s.misc.w, 1.0) * max(s.view.z, 0.05) * max(s.whale.z, 0.05));
                float pale;
                float cover = subWhale(wq, s.whaleB.y, px, pale);
                if (cover > 0.0) {
                    float above = saturate(0.5 + 1.6 * wq.y);
                    float3 albedo = mix(float3(0.035, 0.045, 0.055), float3(0.5, 0.55, 0.57), pale);
                    float3 lit = albedo * (waterLight(D, L) * kWaterTint * (0.25 + 0.6 * above) * s.lamp.y
                                           + kLampColour * (beams * s.lamp.x * (0.6 + 0.6 * pale)));
                    lit *= waterAdapt(D);
                    float haze = 0.15 + 0.6 * s.whaleB.z;
                    col = mix(col, mix(lit, col, haze), cover * s.whale.w);
                }
            }
        }

        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(depthOut, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the living light and the snow (sprites)
    // a: position (NDC x, y), radius (NDC-y units), kind + the lamps' light on it (fraction); b: colour (rgb, light
    // included), a parameter. Kinds: 0 a fleck of marine snow, 1 a jelly (its swim phase), 2 a comb jelly (its swim
    // phase), 3 a speck, 4 a lanternfish's light, 5 a siphonophore's bell (1: a gold fleck), 6 a bubble, 7 a small fish
    // (its heading ±1). Light is added (alpha 0); a fish darkens what is behind it.
    struct SubSprite { float4 a; float4 b; };
    struct SubSpriteOut { float4 pos [[position]]; float2 uv; float4 col; float kind; float lit; };

    vertex SubSpriteOut sub_sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                          constant SubSprite* sprites [[buffer(0)]], constant SubU& s [[buffer(1)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        SubSprite p = sprites[iid];
        float kind = floor(p.a.w);
        float2 ext = float2(p.a.z / max(s.view.w, 0.1), p.a.z);
        if (kind > 6.5) ext.x *= 1.8;    // a fish is long
        SubSpriteOut o;
        o.uv = c[vid];
        o.pos = float4(p.a.xy + o.uv * ext, 0, 1);
        o.col = p.b;
        o.kind = kind;
        o.lit = p.a.w - kind;
        return o;
    }

    fragment float4 sub_sprite_fragment(SubSpriteOut in [[stage_in]], constant SubU& s [[buffer(1)]]) {
        float2 uv = in.uv;
        float t = s.cam.w;
        float3 c = in.col.rgb;
        float param = in.col.w;
        float r2 = dot(uv, uv);
        float k = in.kind;
        if (k < 0.5) {                                   // marine snow: a soft pale fleck
            float a = exp(-r2 * 4.0) * (1.0 - smoothstep(0.55, 1.0, sqrt(r2)));
            return float4(c * a, 0.0);
        }
        if (k < 1.5) {                                   // a jelly: a glowing bell rim, its margin and trailing tentacles
            float beat = 0.5 + 0.5 * cos(6.2831853 * param);   // 1 as the stroke begins: the bell drawn in
            float sq = 1.0 - 0.13 * beat;
            float2 b = (uv - float2(0.0, 0.22)) / float2(0.64 * sq, 0.5 * (1.0 + 0.1 * beat));
            float br = length(b);
            float dome = smoothstep(-0.42, -0.3, b.y);
            float edge = (br - 1.0) / 0.075;
            float outline = exp(-edge * edge) * dome;
            float my = (b.y + 0.33) / 0.07;
            float margin = exp(-my * my) * (1.0 - smoothstep(0.78, 1.02, abs(b.x)));
            float inside = (1.0 - smoothstep(0.75, 1.0, br)) * dome;
            float canals = 0.0;
            for (int j = 0; j < 4; j++) {
                float ang = -0.9 + 0.6 * float(j);
                float2 dir = float2(sin(ang), cos(ang));
                float off = b.x * dir.y - (b.y + 0.3) * dir.x;
                canals += exp(-off * off * 900.0) * inside * step(0.0, dot(b + float2(0.0, 0.3), dir));
            }
            float tent = 0.0;
            float top = 0.22 - 0.33 * 0.5;
            if (uv.y < top) {
                for (int j = 0; j < 6; j++) {
                    float x0 = (-0.5 + 0.2 * float(j)) * sq;
                    float sway = 0.08 * sin(uv.y * 6.0 + t * 1.3 + float(j) * 1.7) * (top - uv.y);
                    float dx = (uv.x - x0 - sway) / 0.022;
                    tent += exp(-dx * dx);
                }
                tent *= smoothstep(-1.0, -0.55, uv.y) * (1.0 - smoothstep(top - 0.06, top, uv.y) * 0.5);
            }
            float light = 0.85 * outline + 1.25 * margin + 0.1 * inside + 0.25 * canals + 0.3 * tent;
            float3 col = c * light + float3(1.0) * (0.35 * margin * margin) * max(c.g, c.b);
            col += float3(0.75, 0.82, 0.9) * (in.lit * (0.18 * inside + 0.25 * outline + 0.08 * tent));
            return float4(col, 0.0);
        }
        if (k < 2.5) {                                   // a comb jelly: an ovoid body, its rows of cilia shimmering
            float2 e2 = uv / float2(0.5, 0.86);
            float e = length(e2);
            if (e > 1.15) return float4(0.0);
            float body = (1.0 - smoothstep(0.7, 1.0, e)) * 0.08;
            float eo = (e - 1.0) / 0.07;
            float rim = exp(-eo * eo) * 0.22;
            float rows = 0.0;
            float3 iri = float3(0.0);
            float spin = 0.35 * t + 6.2831853 * param * 0.15;
            float lat = sqrt(max(0.0, 1.0 - e2.y * e2.y));
            for (int j = 0; j < 8; j++) {
                float lon = spin + 0.7853982 * float(j);
                float front = cos(lon);
                if (front < 0.0) continue;
                float xr = 0.5 * sin(lon) * lat;
                float dx = (uv.x - xr) / (0.035 * (0.4 + 0.6 * front));
                float row = exp(-dx * dx) * (1.0 - smoothstep(0.78, 0.95, abs(e2.y))) * front;
                float wave = 0.5 + 0.5 * sin(uv.y * 24.0 - t * 9.0 + float(j) * 1.7);
                row *= 0.35 + 0.65 * wave * wave;
                rows += row;
                iri += row * (0.5 + 0.5 * cos(6.2831853 * (uv.y * 0.9 + t * 0.25 + float(j) * 0.125 + float3(0.0, 0.33, 0.67))));
            }
            float3 col = c * (body + rim + 0.9 * rows) + iri * (0.12 + 0.6 * in.lit) * max(max(c.r, c.g), c.b);
            col += float3(0.7, 0.8, 0.9) * (in.lit * (body * 2.0 + rim));
            return float4(col, 0.0);
        }
        if (k < 3.5) {                                   // a speck: a bright point in a small halo
            float a = 1.3 * exp(-r2 * 24.0) + 0.16 * exp(-r2 * 3.5);
            return float4((c + float3(0.35) * exp(-r2 * 60.0) * max(c.g, c.b)) * a, 0.0);
        }
        if (k < 4.5) {                                   // a lanternfish's photophore
            float a = exp(-r2 * 14.0) + 0.12 * exp(-r2 * 2.5);
            return float4(c * a, 0.0);
        }
        if (k < 5.5) {                                   // a siphonophore's bell, now and then a gold fleck
            float2 b = (uv - float2(0.0, 0.12)) / float2(0.72, 0.62);
            float br = length(b);
            float bo = (br - 0.92) / 0.14;
            float bell = exp(-bo * bo) * smoothstep(-0.55, -0.3, b.y) + 0.3 * (1.0 - smoothstep(0.3, 1.0, br));
            float3 col = c * bell;
            if (param > 0.5) {
                float2 f = uv - float2(0.28, -0.12);
                col += float3(1.0, 0.78, 0.3) * (exp(-dot(f, f) * 55.0) * 1.4 * max(max(c.r, c.g), c.b));
            }
            return float4(col, 0.0);
        }
        if (k < 6.5) {                                   // a bubble: a bright rim and a highlight
            float r = sqrt(r2);
            if (r > 1.0) return float4(0.0);
            float ro = (r - 0.8) / 0.1;
            float rim = exp(-ro * ro);
            float2 hp = uv - float2(-0.34, 0.38);
            float hi = exp(-dot(hp, hp) * 28.0);
            return float4(c * (0.55 * rim + 0.12 * (1.0 - smoothstep(0.6, 0.9, r)) + 1.1 * hi), 0.0);
        }
        // A small fish in silhouette against the bright shallows: head toward its heading, a forked tail behind.
        float2 f = float2(uv.x * (param < 0.0 ? -1.0 : 1.0), uv.y);
        float body = length(float2((f.x - 0.1) / 0.62, f.y / 0.3));
        float shape = 1.0 - smoothstep(0.85, 1.0, body);
        float tx = -0.55 - f.x;
        if (tx > 0.0 && tx < 0.42) {
            float w = 0.06 + 0.9 * tx;
            float fork = abs(abs(f.y) - 0.55 * tx);
            shape = max(shape, (1.0 - smoothstep(w * 0.45, w * 0.6, fork)) * (1.0 - smoothstep(0.3, 0.42, tx)));
        }
        float a = shape * in.lit;
        float belly = smoothstep(0.1, -0.25, f.y) * (1.0 - smoothstep(0.85, 1.0, body));
        return float4((c + float3(0.25, 0.3, 0.32) * belly * 0.35) * a, a);
    }

    // ---------------------------------------------------------------- the cabin
    /// Brass (the gauge's bezel and hub): polished, brushed, lit warm by the cabin and catching a little sea light.
    float3 subBrass(float3 nrm, float3 lamp, float3 sea, float grain) {
        float3 Lc = normalize(float3(-0.45, 0.6, 0.66));
        float3 H = normalize(Lc + float3(0.0, 0.0, 1.0));
        float diff = saturate(dot(nrm, Lc));
        float sh = saturate(dot(nrm, H));
        float s2 = sh * sh, s4 = s2 * s2, s8 = s4 * s4, s16 = s8 * s8, s32 = s16 * s16;
        float room = 0.2 + 0.8 * smoothstep(-0.6, 0.8, 2.0 * nrm.z * nrm.y);
        float3 albedo = float3(0.8, 0.58, 0.26) * (0.85 + 0.2 * grain);
        return albedo * lamp * (0.06 + 0.3 * diff + 0.5 * room + s32 * (1.3 + grain) + 0.2 * s8) + albedo * sea * 0.06;
    }

    fragment ColorDepth sub_cabin_fragment(SubOut in [[stage_in]], constant SubU& s [[buffer(1)]]) {
        float aspect = s.view.w;
        float2 p = in.ndc * float2(aspect, 1.0);                  // NDC-y units
        float2 qc = p - s.view.xy * float2(aspect, 1.0);
        float r = length(qc);
        float R = s.room.x;
        if (r < R - 0.002) discard_fragment();                   // the glass and its brass ring show through
        float night = s.room.z;
        float3 lamp = s.cabin.rgb;
        float3 sea = s.glow.rgb;
        float consoleTop = s.room.y;
        float t = s.cam.w;

        // The wall: painted steel in a soft pool of the cabin's light from up and to the left, darker into the corners;
        // panel seams with rivets; the ring's shadow round it and the sea's light spilling out past it.
        float2 lp = p - float2(-0.45 * aspect, 1.2);
        float pool = 0.2 + 0.8 * exp(-dot(lp, lp) * 0.32);
        float grain = 0.93 + 0.07 * vnoise3(float3(p * 34.0, 1.3)) + 0.03 * vnoise3(float3(p * 5.0, 7.1));
        float3 paint = float3(0.3, 0.34, 0.32) * grain;
        // Two seams, one either side of the porthole, each with a row of rivets beside it.
        float seam = 0.0, rivet = 0.0;
        float cx = s.view.x * aspect;
        for (int j = 0; j < 2; j++) {
            float x = j == 0 ? cx - R - 0.34 : cx + R + 0.16;
            float dx = (p.x - x) / 0.004;
            seam = max(seam, exp(-dx * dx));
            float ry = fract((p.y + 1.0) / 0.16) - 0.5;
            float2 rv = float2(p.x - x - (j == 0 ? -0.024 : 0.024), ry * 0.16);
            rivet = max(rivet, exp(-dot(rv, rv) / 0.00004));
        }
        float3 col = paint * lamp * pool * (1.0 - 0.45 * seam) + lamp * pool * rivet * 0.07;
        float shadow = mix(0.35, 1.0, smoothstep(R, R + 0.09, r));
        col *= shadow;
        col += paint * sea * (1.2 * exp(-(r - R) * 6.0)) + paint * sea * 0.18;
        col += float3(0.25, 0.75, 1.0) * (s.misc.y * 0.025 * exp(-(r - R) * 4.0));   // the living light, faintly

        // Cables: two along the top of the wall, sagging between their clips, and a short one from the gauge down to the
        // sonar; round rubber catching the lamp along their tops.
        float sag = s.misc.z;
        for (int j = 0; j < 2; j++) {
            float y0 = 0.962 - 0.042 * float(j);
            float span = 0.82 * aspect / (1.6 + 0.4 * float(j));
            float uu = fract((p.x + aspect + 0.31 * float(j) * span) / span) - 0.5;
            float yc = y0 - sag * (1.0 - 4.0 * uu * uu) * (1.0 + 0.5 * float(j));
            float thick = 0.011 - 0.002 * float(j);
            float v = (p.y - yc) / thick;
            if (abs(v) < 1.0) {
                float nz = sqrt(1.0 - v * v);
                float lit = saturate(0.75 * v + 0.6 * nz);
                float hl = lit * lit * lit * lit;
                col = float3(0.025, 0.025, 0.028) * (0.4 + 0.6 * nz) * (0.6 + 2.0 * lamp) + lamp * (hl * 0.35 * pool);
            }
            // The clips: small steel saddles screwed to the wall.
            float2 cl = float2((abs(uu) - 0.5) * span, p.y - y0 + 0.002);
            if (abs(cl.x) < 0.016 && abs(cl.y) < thick + 0.008) {
                float edge = smoothstep(0.016, 0.012, abs(cl.x)) * smoothstep(thick + 0.008, thick + 0.004, abs(cl.y));
                float screw = exp(-dot(cl - float2(0.0, 0.0), cl) / 0.00002);
                col = mix(col, float3(0.09, 0.09, 0.095) * (0.5 + 2.0 * lamp) * (0.7 + 0.3 * smoothstep(-thick, thick, cl.y)) + lamp * screw * 0.2, edge);
            }
        }
        {
            float2 gc0 = s.gauge.xy * float2(aspect, 1.0), sc0 = s.sonar.xy * float2(aspect, 1.0);
            float x0 = gc0.x + 0.35 * s.sonar.z;
            float yTop = gc0.y - 1.1 * s.gauge.z, yBot = sc0.y + 1.05 * s.sonar.z;
            if (p.y < yTop && p.y > yBot) {
                float k2 = (p.y - yBot) / max(yTop - yBot, 1e-3);
                float xc = x0 + 0.025 * sin(k2 * 3.14159265);
                float v = (p.x - xc) / 0.01;
                if (abs(v) < 1.0) {
                    float nz = sqrt(1.0 - v * v);
                    float lit = saturate(-0.6 * v + 0.6 * nz);
                    col = float3(0.025, 0.025, 0.028) * (0.4 + 0.6 * nz) * (0.6 + 2.0 * lamp) + lamp * (lit * lit * lit * lit * 0.3 * pool);
                }
            }
        }

        // The cabin's lamp, high on the wall left of the porthole (where its pool of light comes from): a frosted dome
        // glowing in the cabin's light, behind a three-bar cage on a round mounting plate.
        {
            float2 lc = float2(0.5 * (-aspect + (cx - R)), 0.66);
            float space = (cx - R) + aspect;
            if (space > 0.3) {
                float2 lv = p - lc;
                float lr = length(lv);
                float plate = 0.075, dome = 0.05;
                if (lr < plate * 1.6) col *= mix(0.55, 1.0, smoothstep(plate, plate * 1.6, lr));
                if (lr < plate) {
                    float3 n = normalize(float3(lv / plate * 0.6, 1.0));
                    float sp = saturate(dot(n, normalize(float3(-0.3, 0.5, 0.8))));
                    col = float3(0.08, 0.085, 0.09) * (0.5 + 2.5 * lamp) * (0.6 + 0.4 * sp);
                }
                if (lr < dome) {
                    float x = lr / dome;
                    float glowL = 1.0 - 0.45 * x * x;
                    col = lamp * (2.6 * glowL) + float3(0.02);
                    float2 hp = lv / dome - float2(-0.35, 0.35);
                    col += lamp * (1.2 * exp(-dot(hp, hp) * 8.0));
                }
                // The cage: two bars over the dome and a ring round it.
                float bar = min(abs(lv.x - 0.017), abs(lv.x + 0.017));
                float ringd = abs(lr - dome * 1.02);
                if (lr < dome * 1.08 && (bar < 0.0035 || ringd < 0.003)) col = float3(0.03, 0.03, 0.032) + lamp * 0.12;
                col += lamp * (0.12 * exp(-max(lr - plate, 0.0) * 16.0)) * step(plate, lr);
            }
        }

        // The depth gauge: a brass bezel round a cream face (red under the night lighting), its ticks over 270° and a
        // dark needle reading the Depth, a brass hub, and the glass's soft highlight.
        float2 gc = s.gauge.xy * float2(aspect, 1.0);
        float2 g = p - gc;
        float gr = length(g), GR = s.gauge.z;
        if (gr < GR * 1.36) {
            float shadowG = mix(0.4, 1.0, smoothstep(GR * 1.18, GR * 1.36, gr));
            col *= shadowG;
        }
        if (gr < GR * 1.18) {
            float ang = atan2(g.x, g.y);                          // clockwise from up
            if (gr > GR) {
                float sx = (gr - GR) / (0.18 * GR);
                float tilt = 0.9 * (sx - 0.5) * 2.0;
                float3 n = normalize(float3(g / max(gr, 1e-5) * tilt, 1.0));
                col = subBrass(n, lamp, sea, vnoise3(float3(ang * 6.0, sx * 30.0, 0.0)));
            } else {
                float x = gr / GR;
                float3 face = mix(float3(0.82, 0.78, 0.66), float3(0.5, 0.42, 0.36), night);
                float3 c = face * lamp * (0.55 + 0.45 * pool) * 0.9 + face * 0.01;
                float a = ang + 2.3561945;                       // 0 at the dial's start (−135°)
                float span = 4.712389;
                if (a >= -0.02 && a <= span + 0.02 && x > 0.7 && x < 0.9) {
                    float minor = abs(fract(a / (span / 30.0) + 0.5) - 0.5) * (span / 30.0) * gr;
                    float major = abs(fract(a / (span / 10.0) + 0.5) - 0.5) * (span / 10.0) * gr;
                    float tk = max(1.0 - smoothstep(0.0025, 0.0045, minor) * 1.0, 0.0) * step(0.8, x);
                    tk = max(tk, (1.0 - smoothstep(0.004, 0.0065, major)) * step(0.72, x));
                    float3 ink = a > span * 0.82 ? float3(0.45, 0.04, 0.03) : float3(0.03, 0.03, 0.03);
                    // Luminous paint on the marks, faint under the red night lighting.
                    float3 glowInk = float3(0.18, 0.32, 0.22) * (0.25 * night);
                    c = mix(c, ink * (0.4 + lamp) + glowInk, tk);
                }
                // The needle: tapered, dark, with a red tip, and its shadow on the face.
                float na = s.gauge.w;
                float2 nd = float2(sin(na), cos(na));
                float along = dot(g, nd), across = abs(g.x * nd.y - g.y * nd.x);
                float w = mix(0.022, 0.004, saturate(along / (0.85 * GR))) * GR;
                float2 sh = g - float2(0.008, -0.01) * GR;
                float salong = dot(sh, nd), sacross = abs(sh.x * nd.y - sh.y * nd.x);
                if (salong > -0.15 * GR && salong < 0.85 * GR && sacross < w) c *= 0.7;
                if (along > -0.15 * GR && along < 0.85 * GR && across < w) {
                    c = along > 0.62 * GR ? float3(0.5, 0.05, 0.03) * (0.4 + lamp) + float3(0.18, 0.32, 0.22) * (0.25 * night)
                                          : float3(0.02, 0.02, 0.025) + lamp * 0.03;
                }
                if (x < 0.1) {
                    float3 n = normalize(float3(g / max(gr, 1e-5) * (x / 0.1) * 0.8, 1.0));
                    c = subBrass(n, lamp, sea, 0.5);
                }
                // The glass over the face: a soft highlight up and to the left.
                float2 hp = g / GR - float2(-0.35, 0.4);
                c += lamp * (0.06 * exp(-dot(hp, hp) * 6.0));
                c *= 1.0 - 0.25 * smoothstep(0.85, 1.0, x);
                col = c;
            }
        }

        // The sonar screen: a dark bezel round a green phosphor face, its range rings and cross, the sweep line going
        // round with its fading trail, and the blips your notes left, flaring as the sweep passes them.
        float2 so = p - s.sonar.xy * float2(aspect, 1.0);
        float sr = length(so), SR = s.sonar.z;
        if (sr < SR * 1.3) col *= mix(0.45, 1.0, smoothstep(SR * 1.14, SR * 1.3, sr));
        if (sr < SR * 1.14) {
            if (sr > SR) {
                float sx = (sr - SR) / (0.14 * SR);
                float3 n = normalize(float3(so / max(sr, 1e-5) * (1.6 * sx - 0.8), 1.0));
                float spec = saturate(dot(n, normalize(float3(-0.4, 0.6, 0.7))));
                col = float3(0.035, 0.037, 0.04) * (0.4 + lamp * 2.0) + lamp * (spec * spec * spec * spec * 0.12);
            } else {
                float bright = s.glow.w;
                float3 phos = float3(0.22, 1.0, 0.5);
                float x = sr / SR;
                float ang = atan2(so.x, so.y);
                float behind = fract((s.sonar.w - ang) / 6.2831853);   // 0 on the sweep line … 1 a turn behind it
                float trail = exp(-behind * 4.0) * 0.6;
                float line = exp(-(behind * 6.2831853 * sr / (0.012 * SR)) * (behind * 6.2831853 * sr / (0.012 * SR)));
                float grid = 0.0;
                for (int j = 1; j <= 3; j++) {
                    float rr = (x - 0.3 * float(j)) / 0.012;
                    grid += exp(-rr * rr);
                }
                grid += exp(-(so.x / (0.006 * SR)) * (so.x / (0.006 * SR))) + exp(-(so.y / (0.006 * SR)) * (so.y / (0.006 * SR)));
                float blips = 0.0;
                int count = min(int(s.misc.x + 0.5), kSubBlips);
                for (int j = 0; j < count; j++) {
                    float4 b = s.blips[j];
                    float2 bp = b.y * SR * float2(sin(b.x), cos(b.x));
                    float2 dv = so - bp;
                    float since = fract((s.sonar.w - b.x) / 6.2831853);
                    float flare = 0.35 + 0.65 * exp(-since * 3.5);
                    blips += b.z * flare * exp(-dot(dv, dv) / (0.0016 * SR * SR));
                }
                // A far sub's contact (a surprise): a bright return far out, its ping's ring spreading from it.
                if (s.contact.z > 0.001) {
                    float2 cp = s.contact.y * SR * float2(sin(s.contact.x), cos(s.contact.x));
                    float2 cv = so - cp;
                    float cd = length(cv);
                    float ringR = s.contact.w * 0.35 * SR, ringW = 0.02 * SR;
                    float rr = (cd - ringR) / ringW;
                    float ring = exp(-rr * rr) * (1.0 - s.contact.w);
                    float echo = exp(-dot(cv, cv) / (0.0025 * SR * SR));
                    blips += s.contact.z * (1.2 * echo + 0.8 * ring);
                }
                float3 c = float3(0.006, 0.03, 0.018) + phos * (0.08 * grid + trail * 0.25 + line * 0.9 + blips * 1.3) * bright;
                c *= 1.0 - 0.5 * smoothstep(0.7, 1.0, x);
                float2 hp = so / SR - float2(-0.3, 0.35);
                c += (lamp * 0.5 + float3(0.02)) * (0.05 * exp(-dot(hp, hp) * 5.0));
                col = c;
            }
        }
        // The screen's glow on the wall around it.
        col += float3(0.22, 1.0, 0.5) * (s.glow.w * 0.012 * exp(-max(sr - SR, 0.0) * 9.0)) * step(SR * 1.14, sr);

        // The console under the keys, and its padded edge: a rolled cushion in dark oxblood vinyl, buttoned.
        if (p.y < consoleTop) {
            float top = consoleTop - 0.075;
            if (p.y > top) {
                float v = (p.y - top) / 0.075 * 2.0 - 1.0;       // −1 … 1 across the roll
                float nz = sqrt(max(0.0, 1.0 - v * v));
                float3 n = float3(0.0, v, nz);
                float diff = saturate(dot(n, normalize(float3(-0.3, 0.75, 0.6))));
                float bx = fract(p.x / 0.22) - 0.5;
                float2 bv = float2(bx * 0.22, (v) * 0.03);
                float button = exp(-dot(bv, bv) / 0.00006);
                float pleat = exp(-(bx * 0.22 / 0.006) * (bx * 0.22 / 0.006)) * 0.5;
                float3 vinyl = float3(0.4, 0.13, 0.09);
                float sheen = diff * diff * diff * diff;
                col = vinyl * lamp * (0.15 + 0.75 * diff) * (1.0 - 0.4 * button - 0.3 * pleat) + lamp * sheen * 0.06
                    + vinyl * sea * 0.6 * saturate(v + 0.3);
                col *= smoothstep(-1.0, -0.6, v) * 0.6 + 0.4;
            } else {
                // The console's face: dark painted metal, its edge catching the light.
                float lip = exp(-((top - p.y) / 0.006) * ((top - p.y) / 0.006));
                col = float3(0.03, 0.033, 0.035) * (0.4 + lamp) + lamp * lip * 0.08;
            }
        }
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(0.01, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the keys: backlit console buttons
    struct SubKey { float4 rect; float4 info; };   // NDC rect; black, glow, pressed, night
    struct SubKeyOut { float4 pos [[position]]; float2 uv; float4 info; float2 size; };

    vertex SubKeyOut sub_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant SubKey* keys [[buffer(0)]],
                                     constant SubU& s [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        SubKey k = keys[iid];
        SubKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        o.size = float2((k.rect.z - k.rect.x) * s.view.w, k.rect.w - k.rect.y);   // NDC-y units
        return o;
    }

    /// A rounded button with a translucent cap: dark when idle with a thin backlight under its top edge (cool by day,
    /// red at night), glowing cyan from within where you play.
    fragment ColorDepth sub_keys_fragment(SubKeyOut in [[stage_in]], constant SubU& s [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, night = in.info.w;
        float2 sz = max(in.size, float2(1e-4));
        float2 pp = (in.uv - 0.5) * sz;
        float inset = 0.0012 + 0.06 * min(sz.x, sz.y);
        float2 halfIn = sz * 0.5 - inset;
        float rad = min(halfIn.x, halfIn.y) * 0.45;
        float2 qd = abs(pp) - (halfIn - rad);
        float sd = length(max(qd, 0.0)) + min(max(qd.x, qd.y), 0.0) - rad;
        float px = 2.0 / max(s.misc.w, 100.0);
        float cap = 1.0 - smoothstep(-px, px, sd);
        float3 lamp = s.cabin.rgb;
        float3 back = mix(float3(0.3, 0.75, 0.9), float3(0.9, 0.12, 0.05), night);
        float3 plate = float3(0.012, 0.013, 0.015) + lamp * 0.03;
        float3 body = black ? float3(0.006, 0.007, 0.009) : float3(0.022, 0.025, 0.03);
        float topEdge = (1.0 - smoothstep(0.0, 0.006, abs(sd + 0.004))) * cap * (0.4 + 0.6 * smoothstep(0.3, 0.9, in.uv.y));
        float bevel = smoothstep(-0.006, 0.0, sd) * cap;
        float3 cyan = float3(0.25, 0.85, 1.0);
        float centre = 1.0 - smoothstep(0.0, 0.7, length((in.uv - float2(0.5, 0.45)) * float2(1.6, 1.0)));
        float3 c = body * (1.0 - 0.3 * pressed) + lamp * bevel * 0.05
                 + back * (topEdge * (black ? 0.16 : 0.2))
                 + cyan * (glow * (0.9 + 0.9 * centre) * (1.0 - 0.3 * bevel));
        c = mix(plate, c, cap);
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
