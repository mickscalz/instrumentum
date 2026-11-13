/// Metal source for the Window Kit's windscreen (Fire & Neon spec §9.1): the rain on a car's windscreen and the wipers
/// clearing it, and the car's interior around the glass.
///
/// `screen_glass_fragment` draws the glass over the view: drops gathering in three sizes, each a little lens showing the
/// view behind it upside down and out of focus (the city's lights become soft discs of colour in them), cleared where a
/// blade has passed and gathering again at the rain's rate (the time since each drop's place was last wiped is worked
/// out from the wipers' state in closed form), none landing while the car is sheltered; a thin film just behind the
/// blades; the blades themselves, motion-blurred. `screen_frame_fragment` draws the dashboard, the A-pillars, the roof
/// lining and the rear-view mirror round the glass, lit faintly by the city through it, and the keys as a strip of light
/// along the dashboard's edge. `screen_copy_fragment` makes the half-resolution copy of the view the glass refracts.
/// Smooth rules: no marching, no pow; one drop per cell per size (no neighbour search).
enum WindscreenShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ScreenU {
        float4 a;        // aspect, time (s, wrapped), quality (0 Smooth), rain landing now 0…1
        float4 dash;     // the dashboard's line: y at the centre (NDC), its curve; the roof's line: y, its curve
        float4 pillars;  // the left pillar's inner edge x at the dashboard and at the roof, the right pillar's (NDC)
        float4 mirror;   // the rear-view mirror's centre (NDC), half size (NDC)
        float4 bladeA;   // blade 0: pivot (x in aspect units, y NDC), inner and outer radius (NDC y units)
        float4 bladeB;   // blade 1
        float4 sweep;    // rest angle (rad), sweep (rad, signed), where the blades stand now and a frame ago (0…1)
        float4 wiper;    // phase 0…1, this sweep's time (s), the last sweep's (s), the rest before (s)
        float4 wiper2;   // sweeping 0/1, ever swept 0/1, fill time (s: how long the glass takes to bead over), drop density
        float4 dry;      // shelter began (s ago; < 0 never), shelter ended (s ago; 0 while sheltered), speed 0…1.25, 0
        float4 light;    // the cabin's light from outside (rgb), the tunnel's strobe on it 0…1 (after the limiter)
        float4 keyInfo;  // the keys' colour (rgb), shown 0/1
        float4 keys[22]; // the 88 keys' glow, four a row
    };
    struct ScreenOut { float4 pos [[position]]; float2 ndc; };

    vertex ScreenOut screen_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        ScreenOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float sh12(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    // ---------------------------------------------------------------- the glass's outline
    float dashY(float x, constant ScreenU& u) { return u.dash.x + u.dash.y * x * x; }
    float roofY(float x, constant ScreenU& u) { return u.dash.z - u.dash.w * x * x; }
    /// How far inside the glass a point is (NDC; negative outside): under the roof, over the dashboard, between the
    /// pillars.
    float glassInside(float2 p, constant ScreenU& u) {
        float dy = dashY(p.x, u), ry = roofY(p.x, u);
        float f = clamp((p.y - dy) / max(ry - dy, 1e-3), 0.0, 1.0);
        float lx = mix(u.pillars.x, u.pillars.y, f), rx = mix(u.pillars.z, u.pillars.w, f);
        return min(min(p.y - dy, ry - p.y), min(p.x - lx, rx - p.x));
    }

    // ---------------------------------------------------------------- the wipers
    /// Seconds since a blade last passed `a` (0 parked … 1 the top of its sweep): the Core `Wipers.sinceWiped`.
    float sinceWiped(float a, constant ScreenU& u) {
        float x = clamp(a, 0.0, 1.0);
        float up = acos(clamp(1.0 - 2.0 * x, -1.0, 1.0)) / 6.2831853;
        float down = 1.0 - up;
        float phase = u.wiper.x, S = u.wiper.y, last = u.wiper.z, rest = u.wiper.w;
        bool sweeping = u.wiper2.x > 0.5, ever = u.wiper2.y > 0.5;
        if (!ever && !sweeping) return 1000.0;
        if (sweeping) {
            if (phase >= down) return (phase - down) * S;
            if (phase >= up) return (phase - up) * S;
            if (!ever) return 1000.0;
            return phase * S + rest + up * last;
        }
        return rest + up * last;
    }

    /// Where a point lies in a blade's sweep: (0…1 through it, or < 0 outside it) and its radius (NDC y units).
    float2 bladePlace(float2 q, float4 blade, constant ScreenU& u) {
        float2 rel = q - blade.xy;
        float r = length(rel);
        if (r < blade.z || r > blade.w) return float2(-1.0, r);
        float ang = atan2(rel.y, rel.x);
        float rest = u.sweep.x, sweep = u.sweep.y;
        float f = (ang - rest) / sweep;
        if (f < -0.02 || f > 1.02) return float2(-1.0, r);
        return float2(clamp(f, 0.0, 1.0), r);
    }

    /// Seconds since the glass at `q` (aspect units) was last wiped, by either blade.
    float wipedAgo(float2 q, constant ScreenU& u) {
        float since = 1000.0;
        float2 a = bladePlace(q, u.bladeA, u);
        if (a.x >= 0.0) since = min(since, sinceWiped(a.x, u));
        float2 b = bladePlace(q, u.bladeB, u);
        if (b.x >= 0.0) since = min(since, sinceWiped(b.x, u));
        return since;
    }

    /// The blades: dark rubber on a thin arm, smeared across the arc they swept in the last frame.
    float bladeCover(float2 q, float4 blade, constant ScreenU& u, float px) {
        float2 rel = q - blade.xy;
        float r = length(rel);
        if (r < blade.z * 0.3 || r > blade.w + 0.01) return 0.0;
        float ang = atan2(rel.y, rel.x);
        float now = u.sweep.x + u.sweep.y * u.sweep.z;
        float was = u.sweep.x + u.sweep.y * u.sweep.w;
        float lo = min(now, was), hi = max(now, was);
        bool rubber = r >= blade.z;
        float halfW = (rubber ? 0.0065 : 0.0035) / r + px / r;
        float swept = hi - lo;
        float inside = smoothstep(lo - halfW, lo - halfW * 0.4, ang) * smoothstep(hi + halfW, hi + halfW * 0.4, ang);
        float cover = inside * min(1.0, 2.0 * halfW / max(swept + 2.0 * halfW, 1e-4));
        float ends = smoothstep(blade.w + 0.01, blade.w - 0.005, r);
        return cover * ends;
    }

    // ---------------------------------------------------------------- the drops
    /// One size of drop: cells `cell` wide (NDC y units), each with at most one drop of radius up to `rmax`, its place
    /// jittered so it never leaves its cell. Returns the drop's offset from its centre (in its radii) and its radius, or
    /// radius 0 for none here.
    float3 dropAt(float2 q, float cell, float rmax, float seed, float density, float fill, constant ScreenU& u) {
        float2 g = q / cell;
        float2 c = floor(g);
        float h0 = sh12(c + seed), h1 = sh12(c * 1.37 + seed + 3.1), h2 = sh12(c * 0.71 + seed + 7.7);
        if (h0 > density) return float3(0);
        float h3 = sh12(c * 2.13 + seed + 1.9);
        float r = rmax * (0.35 + 0.65 * h3 * h3);
        float margin = r / cell;
        float2 centre = (c + float2(margin + (1.0 - 2.0 * margin) * h1, margin + (1.0 - 2.0 * margin) * h2)) * cell;
        // Not quite round: the wind of the car's speed flattens and leans each a little.
        float2 rel = q - centre;
        float lean = (h1 - 0.5) * 0.5;
        rel = float2(rel.x - rel.y * lean * 0.3, rel.y * (1.0 + 0.25 * h2));
        // (Outside the drop at its full size, a pixel is outside it at any size it has grown to: when it landed isn't
        // worked out. Most of a drop's cell.)
        float2 full = rel / r;
        if (dot(full, full) >= 1.0) return float3(0);
        // Has it landed since its place was last wiped (and not while sheltered)?
        float since = wipedAgo(centre, u);
        float delay = fract(h0 * 7.13 + h2) * fill;
        float landed = since - delay;
        if (landed < 0.0) return float3(0);
        if (u.dry.x >= 0.0 && landed >= u.dry.y && landed <= u.dry.x) return float3(0);
        // A new drop swells to its size over its first second.
        float grow = min(1.0, 0.55 + landed);
        r *= grow;
        float2 off = rel / r;
        if (dot(off, off) >= 1.0) return float3(0);
        return float3(off, r);
    }

    /// The keys' strip along the dashboard's edge: 88 slim keys with rounded ends (the black keys shorter and set higher),
    /// unlit barely there, lit a soft glow in `keyInfo`'s colour. Light at `p` (NDC); `blur` (pixels) softens it for its
    /// reflection in the glass. `dim` is the unlit keys' faint shade (the city's light on them).
    float3 keysLight(float2 p, constant ScreenU& u, float px, float blur, float3 dim) {
        float aspect = u.a.x;
        float pxX = px / max(aspect, 0.1);
        float sw = 1.8 / 88.0;
        float k0 = floor((p.x + 0.9) / sw);
        float yc = dashY(p.x, u) - 0.026;
        float r = max(0.12 * sw / pxX, 1.2);
        float3 light = float3(0);
        for (int j = -1; j <= 1; j++) {
            float k = k0 + float(j);
            if (k < 0.0 || k > 87.0) continue;
            int i = int(k);
            int pc = (i + 9) % 12;
            bool black = pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10;
            float hh = (black ? 0.010 : 0.016) / px;
            float yk = yc + (black ? 0.006 : 0.0);
            float dx = (p.x - (-0.9 + (k + 0.5) * sw)) / pxX;
            float dy = (p.y - yk) / px;
            float d = length(float2(dx, max(abs(dy) - max(hh - r, 0.0), 0.0))) - r;
            float cov = saturate(0.5 - d / (1.0 + blur));
            float g = u.keys[i / 4][i % 4];
            float outD = max(d, 0.0);
            float3 hot = mix(u.keyInfo.rgb, float3(1.0), 0.35 * g);
            light += hot * (g * (cov * 1.6 + exp(-outD / (2.5 + blur)) * 0.3 + exp(-outD / (8.0 + blur)) * 0.06));
            light += dim * (cov * (1.0 - g) * (black ? 0.5 : 1.0));
        }
        return light;
    }

    fragment float4 screen_glass_fragment(ScreenOut in [[stage_in]], constant ScreenU& u [[buffer(0)]],
                                          texture2d<float> view [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 p = in.ndc;
        float inside = glassInside(p, u);
        // (Where the glass adds nothing (blended over: the same frame) the pixel is let go, so the view there isn't read
        // and written back: off the glass, and on it between the drops.)
        if (inside < -0.01) { discard_fragment(); return float4(0); }
        float aspect = u.a.x;
        float2 q = float2(p.x * aspect, p.y);
        float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        float px = 2.0 / max(float(view.get_height()) * 2.0, 1.0);
        float rain = u.a.w;
        float density = u.wiper2.w;
        float fill = max(u.wiper2.z, 0.3);
        bool smooth = u.a.z < 0.5;
        // Composed back to front, premultiplied: the film a blade leaves, the drops, the blades.
        float3 C = float3(0);
        float A = 0.0;
        float since = wipedAgo(q, u);
        float film = exp(-since / 0.18) * step(since, 0.9) * min(1.0, rain * 3.0);
        if (film > 0.003) {
            float streak = 0.6 + 0.4 * sh12(float2(floor(length(q - u.bladeA.xy) * 260.0), 1.0));
            float af = film * 0.45 * streak;
            C = view.sample(s, uv, level(2.0)).rgb * af;
            A = af;
        }
        // Three sizes of drop, the biggest first (a smaller one shows only where no bigger one sits).
        float3 drop = dropAt(q, 0.075, 0.026, 1.7, density * 0.35, fill * 1.6, u);
        if (drop.z <= 0.0) drop = dropAt(q, 0.036, 0.013, 5.3, density * 0.55, fill, u);
        if (drop.z <= 0.0 && !smooth) drop = dropAt(q, 0.016, 0.0055, 9.1, density * 0.8, fill * 0.7, u);
        if (drop.z > 0.0) {
            float2 off = drop.xy;
            float r = sqrt(dot(off, off));
            // A lens: the view behind it, from a wider patch and upside down, out of focus.
            float2 look = uv - float2(off.x / aspect, -off.y) * (drop.z * 2.6) * 0.5;
            float lod = 2.2 + 3.0 * drop.z / 0.026;
            float3 inDrop = view.sample(s, look, level(lod)).rgb;
            // Its rim darkens (light turned away inside it); a glint where it catches the brightest light above.
            float rim = smoothstep(0.5, 1.0, r);
            float2 g = off - float2(-0.3, 0.36);
            float glint = exp(-dot(g, g) / 0.02);
            float3 lit = view.sample(s, uv + float2(0.0, -0.08), level(5.0)).rgb;
            float3 behind = view.sample(s, uv, level(1.5)).rgb;
            // Out of focus: a soft disc that mostly carries the colour of the light it gathers, darker where it bends
            // light away at its rim; only a faint glint on top.
            float3 dc = inDrop * (1.2 - 0.75 * rim) + lit * glint * 0.35;
            float ad = smoothstep(1.0, 0.62, r) * (0.55 + 0.4 * smoothstep(0.0, 0.25, dot(inDrop, float3(0.33)))) ;
            dc = mix(behind, dc, 0.85);
            C = dc * ad + C * (1.0 - ad);
            A = ad + A * (1.0 - ad);
        }
        // The blades.
        float blade = max(bladeCover(q, u.bladeA, u, px), bladeCover(q, u.bladeB, u, px));
        if (blade > 0.0) {
            float3 rubber = float3(0.006, 0.006, 0.007) + u.light.rgb * 0.05;
            C = rubber * blade + C * (1.0 - blade);
            A = blade + A * (1.0 - blade);
        }
        // The glass's own edge darkens into the frame: the frit's black band and its fading dots, wide enough that what the
        // pillars cut off doesn't show as a bright sliver at their edge.
        float dyB = dashY(p.x, u), ryB = roofY(p.x, u);
        float fB = clamp((p.y - dyB) / max(ryB - dyB, 1e-3), 0.0, 1.0);
        float pillarIn = min(p.x - mix(u.pillars.x, u.pillars.y, fB), mix(u.pillars.z, u.pillars.w, fB) - p.x);
        float band = smoothstep(0.0, 0.035, inside) * smoothstep(0.0, 0.08, pillarIn);
        C *= band;
        A = A * band + (1.0 - band);
        // The lit keys' faint reflection in the glass's base, just above the band (the glass leans back over the dash).
        if (u.keyInfo.w > 0.5) {
            float dy = dashY(p.x, u);
            float above = p.y - (dy + 0.07);
            if (above > -0.04 && above < 0.12 && abs(p.x) < 0.95) {
                float2 src = float2(p.x, (dy - 0.026) - above * 1.4);
                float3 kr = keysLight(src, u, px, 4.0, float3(0));
                C += kr * (0.12 * exp(-max(above, 0.0) / 0.05) * smoothstep(-0.04, 0.0, above));
            }
        }
        if (A == 0.0 && C.x == 0.0 && C.y == 0.0 && C.z == 0.0) discard_fragment();
        return float4(C, A);
    }

    // ---------------------------------------------------------------- the car round the glass
    fragment float4 screen_frame_fragment(ScreenOut in [[stage_in]], constant ScreenU& u [[buffer(0)]],
                                          texture2d<float> view [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 p = in.ndc;
        float px = 2.0 / max(float(view.get_height()) * 2.0, 1.0);
        float inside = glassInside(p, u);
        float2 mq = (p - u.mirror.xy) / u.mirror.zw;
        float mirror = 0.0;
        {
            float2 b = abs(mq) - float2(1.0, 1.0) + 0.35;
            float dm = length(max(b, 0.0)) + min(max(b.x, b.y), 0.0) - 0.35;
            mirror = smoothstep(px / u.mirror.w * 1.5, -px / u.mirror.w * 1.5, dm);
            // Its stem up to the roof lining.
            float stem = smoothstep(0.012, 0.008, abs(p.x - u.mirror.x - u.mirror.z * 0.15)) * step(u.mirror.y, p.y);
            mirror = max(mirror, stem);
        }
        float body = smoothstep(px * 1.5, -px * 1.5, inside);
        float a = max(body, mirror);
        if (a <= 0.001) discard_fragment();
        // The cabin is dark, lit faintly by the city through the glass (more on the dashboard's top, which faces it) and,
        // in a tunnel, by its lights as they pass over.
        float3 outside = u.light.rgb;
        float3 strobe = float3(1.0, 0.5, 0.15) * u.light.w * 0.06;
        float dy = dashY(p.x, u);
        float3 col;
        if (p.y < dy + 0.004) {
            // The dashboard: its top pad catches the glow off the glass; its face below is darker, a vent's slot in it.
            float down = dy - p.y;
            float pad = exp(-down / 0.05);
            float sheen = 0.5 + 0.5 * view.sample(s, float2(p.x * 0.5 + 0.5, 0.5 - (dy + 0.1) * 0.5), level(5.0)).r * 3.0;
            col = float3(0.004, 0.004, 0.005) + (outside * 0.07 + strobe) * (0.25 + 1.2 * pad * sheen);
            float vent = smoothstep(0.003, 0.0, abs(down - 0.03)) * step(abs(p.x + 0.3), 0.35);
            col *= 1.0 - 0.6 * vent;
            // The keys: a slim row of light along the dashboard's edge, each lit in the neon's colour by its note.
            if (u.keyInfo.w > 0.5) {
                float yc = dy - 0.026;
                if (abs(p.y - yc) < 0.06 && abs(p.x) < 0.95) {
                    col += keysLight(p, u, px, 0.0, float3(0.012, 0.012, 0.015) + outside * 0.03);
                }
            }
        } else {
            // The pillars and the roof lining: dark, their inner edges catching a little light.
            float edge = exp(-max(-inside, 0.0) / 0.02);
            col = float3(0.003, 0.003, 0.0035) + (outside * 0.035 + strobe * 0.6) * (0.3 + edge);
        }
        if (mirror > 0.0) {
            // The mirror: the road behind, dark, a few lights in it, framed in black.
            float2 back = float2(0.5 - mq.x * 0.12, 0.42 + mq.y * 0.05);
            float3 behind = view.sample(s, back, level(3.0)).rgb * 0.25;
            float rim = smoothstep(0.75, 0.95, max(abs(mq.x), abs(mq.y)));
            float3 m = mix(behind, float3(0.004), rim);
            col = mix(col, m, mirror);
        }
        return float4(col * a, a);
    }

    // ---------------------------------------------------------------- the copy the glass looks through
    fragment float4 screen_copy_fragment(ScreenOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        return float4(src.sample(s, uv).rgb, 1.0);
    }
    """
}
