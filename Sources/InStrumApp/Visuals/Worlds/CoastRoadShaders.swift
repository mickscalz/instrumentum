/// Metal source for Coast Road: the view from the passenger seat, out the side window and down to the sea
/// from about 60 m up. Far headlands in haze, the Ocean layer from height with white water at the cliff base,
/// coastal scrub along the cliff edge, guardrail posts streaming past, road lamps lit from dusk, sea fog, the
/// window frame and glass, Coast Lights (additive) and a dashboard-amber keyboard.
/// Built on SkyShaders.common and OceanShaders.common. Smooth rules: no ray marching, ≤ 2 noise octaves on
/// Smooth, and every scroll is a wrapped phase (the car can drive all night without a seam or a jump).
enum CoastRoadShaders {
    static let source = SkyShaders.common + OceanShaders.common + """
    struct RoadU {
        float4 a;   // keys top (NDC y), aspect, roll (radians), haze 0…1
        float4 b;   // far scroll, mid scroll (wrapped to 40), post phase 0…1, lamp phase 0…1
        float4 c;   // lamps lit 0…1 (after the limiter), night 0…1, speed 0…1, fog 0…1
        float4 d;   // seconds since the last break (< 0 none), its strength, cliff-base scroll (wrapped), wind
        float4 w;   // window: half width (x·aspect units), bottom, top, corner radius
        float4 e;   // wetness 0…1, the road's far edge (NDC y), unused…
        // Fire & Neon §5.5 (Excitement):
        float4 f;   // the lighthouse's lantern from the eye (m: across, out, up), its beams' light 0…1
        float4 g;   // the beams' bearing (rad; 0 faces you), the mist's drift (wrapped), the lantern's flare 0…1, the road opening 0…1
        float4 h;   // the far train: its head's bearing from the view's centre (rad), signed length (rad), light, headlights gathering
        float4 i;   // oncoming headlights on the verge: x (aspect units), light; x, light
        float4 j;   // x, light, unused, unused
        float4 k;   // the day's moment: the glitter race's light 0…1 (after the limiter), its front (m out), the sun's glare 0…1, the glints' twinkle phase 0…1
    };
    struct RoadOut { float4 pos [[position]]; float2 ndc; };

    constant float kSeaBelow = 60.0;        // metres from the road down to the sea
    constant float kPostSpacing = 0.62;     // guardrail posts on screen (aspect units)
    constant float kLampSpacing = 3.3;      // lamps on screen (aspect units)

    vertex RoadOut road_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        RoadOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    /// Signed distance to the side window's glass (aspect units; > 0 outside it, on the car's trim). The front
    /// edge (right: the car drives that way) slants with the A-pillar.
    float windowDistance(float2 p, constant RoadU& u) {
        float hw = u.w.x, bottom = u.w.y, top = u.w.z;
        float2 c = float2(0.0, 0.5 * (bottom + top));
        float d = sdRoundBox(p - c, float2(hw, 0.5 * (top - bottom)), u.w.w);
        // The A-pillar: a slanted cut across the top-right corner.
        float2 n = normalize(float2(1.0, 0.55));
        d = max(d, dot(p - float2(hw - 0.05, top - 0.02), n) + 0.12);
        return d;
    }

    /// The outside world's screen frame: rotated by the road's roll about the window's centre.
    float2 outside(float2 ndc, constant RoadU& u) {
        float2 p = float2(ndc.x * u.a.y, ndc.y);
        float r = u.a.z, cr = cos(r), sr = sin(r);
        return float2(p.x * cr - p.y * sr, p.x * sr + p.y * cr);
    }

    /// Rime on a lamp post (spec §6.4): up its windward side, and along its arm's top. `dx` is across the post from
    /// its centre and `y` up (aspect units), `armY` the arm's centre line, `post` and `arm` their covers; the
    /// feathers ride the post as it passes.
    float lampPostRime(constant SkyU& sky, float dx, float y, float armY, float post, float arm) {
        if (post >= arm) return rimeEdge(sky, post > 0.0 ? 0.012 - abs(dx) : -1.0, float2(dx < 0.0 ? -1.0 : 1.0, 0.0), float2(dx, y));
        return rimeEdge(sky, y > armY ? 0.008 - (y - armY) : -1.0, float2(0.0, 1.0), float2(dx, y));
    }

    /// Where the scrub meets the sky or sea on screen (y), by x (aspect units) and the mid layer's scroll.
    float scrubLine(float x, float scroll, float base) {
        float n = vnoiseP(float3((x + scroll) * 1.6, 2.0, 1.0), 64.0) * 0.07
                + vnoiseP(float3((x + scroll) * 5.0, 5.0, 3.0), 200.0) * 0.03
                + vnoiseP(float3((x + scroll) * 22.0, 8.0, 2.0), 880.0) * 0.016;   // bush tops
        return base + n;
    }

    /// Fire & Neon §5.5: the lighthouse on the far point. Its two beams (half a turn apart) are narrow cones of light in
    /// the sea air (about 0.9° each side, a Gaussian across), seen by the light the haze scatters toward you: brightest
    /// near the lantern, where the cone is narrow and the light dense, fading along it as the haze takes the light, and
    /// far brighter as a beam swings toward you (sea haze scatters forward). Faint mist drifts through them. Where the
    /// view ray passes the beam's axis is found in closed form (clamped to the lantern's side and to `maxT`, where the
    /// sea stops the ray), so a beam has no edge anywhere. And the lantern, a point that blazes when a beam faces you
    /// (the flare after the flash limiter).
    float3 lighthouseLight(float3 d, constant SkyU& sky, constant RoadU& u, float haze, float fog, float maxT) {
        float light = u.f.w;
        if (light <= 0.001) return float3(0);
        float2 fwd = normalize(sky.forward.xy), rgt = float2(fwd.y, -fwd.x);
        float3 L = float3(rgt * u.f.x + fwd * u.f.y, u.f.z);
        float distL = length(L);
        float2 home = -normalize(L.xy);
        float ca = cos(u.g.x), sa = sin(u.g.x);
        float3 B = float3(home.x * ca - home.y * sa, home.x * sa + home.y * ca, 0.0);
        float density = 0.3 + haze + 1.2 * fog;             // how much the air scatters
        float reach = 2600.0 / (1.0 + haze + 2.0 * fog);    // how far along a beam its light carries
        float sum = 0.0, toward = 0.0;
        float3 Ln = L / distL;
        for (int k = 0; k < 2; k++) {
            float3 b = k == 0 ? B : -B;
            float db = dot(d, b);
            toward = max(toward, -dot(b, Ln));
            float sin2 = max(1.0 - db * db, 1e-6);
            float s = max((db * dot(d, L) - dot(b, L)) / sin2, 0.0);
            float t = clamp(dot(d, L + b * s), 0.0, maxT);
            s = max(dot(d * t - L, b), 0.0);
            float3 gap = d * t - L - b * s;
            float width = 2.5 + 0.016 * s;
            float x2 = dot(gap, gap) / (width * width);
            if (x2 > 10.0) continue;
            // Henyey–Greenstein (g 0.72) for the angle between the beam's light and the way back to you.
            float hg = 1.518 + 1.44 * db;
            float phase = 0.4816 / (hg * sqrt(hg));
            float path = min(rsqrt(sin2), 4.0);
            // Mist drifting through the light, in the beam's own frame (along it, and across it in units of its width):
            // two octaves, wrapped along the drift so it never jumps; looking down the beam the long path through it
            // evens the mist out.
            float3 g2 = gap / width;
            float mist = 0.6 * vnoiseP(float3(s * 0.006 + u.g.y, g2.z * 1.2, g2.x * 1.2 + g2.y * 1.2), 64.0)
                       + 0.4 * vnoiseP(float3(s * 0.017 + 2.0 * u.g.y, g2.z * 2.6 + 5.0, (g2.x + g2.y) * 2.6), 128.0);
            mist = mix(mist, 0.5, saturate((path - 1.0) / 2.5));
            sum += exp(-x2) * phase * path * (40.0 / width) * exp(-s / reach) * (0.45 + 1.1 * mist);
        }
        float v = sum * density * 0.3;
        float beams = v / (1.0 + 0.4 * v);
        float c = 1.0 - dot(d, L / distL);
        // The lantern brightens as a beam swings round toward you (its light's spread), and blazes as one faces you.
        float nearing = toward * toward;
        nearing *= nearing;
        float lantern = maxT < 1e8 ? 0.0 : exp(-c / 1.2e-6) * (0.8 + 3.0 * nearing + 30.0 * u.g.z)
                                         + exp(-c / 2e-5) * 0.04 * (1.0 + 3.0 * nearing + 12.0 * u.g.z);
        return float3(1.0, 0.92, 0.75) * ((beams + lantern) * light);
    }

    /// One of the flare's ghosts: a soft disc a little brighter at its rim (NDC centre, radius in aspect units).
    float lanternGhost(float2 ndc, float2 at, float aspect, float size) {
        float g = length((ndc - at) * float2(aspect, 1.0)) / size;
        return smoothstep(1.0, 0.75, g) * (0.35 + 0.65 * g * g) * 0.035;
    }

    /// The lantern's flare in the lens as a beam faces you (u.g.z, after the flash limiter): a thin horizontal streak
    /// through it, a faint ring, and three small ghosts on the line through the frame's centre.
    float3 lanternFlare(float2 ndc, constant SkyU& sky, constant RoadU& u) {
        float k = u.g.z * u.f.w;
        if (k <= 0.01) return float3(0);
        float2 fwd = normalize(sky.forward.xy), rgt = float2(fwd.y, -fwd.x);
        float3 L = normalize(float3(rgt * u.f.x + fwd * u.f.y, u.f.z));
        float lz = dot(L, sky.forward.xyz);
        if (lz <= 0.05) return float3(0);
        float2 lp = float2(dot(L, sky.right.xyz) / (lz * sky.right.w), dot(L, sky.up.xyz) / (lz * sky.up.w));
        float aspect = u.a.y;
        float2 dp = (ndc - lp) * float2(aspect, 1.0);
        float r = length(dp);
        float3 col = float3(1.0, 0.9, 0.72) * (exp(-abs(dp.y) / 0.0035) * exp(-abs(dp.x) / 0.22) * 0.35);
        float ring = (r - 0.075) / 0.01;
        col += float3(0.7, 0.85, 1.0) * (exp(-ring * ring) * 0.025);
        col += lanternGhost(ndc, lp * 0.45, aspect, 0.022) * float3(0.55, 0.8, 1.0);
        col += lanternGhost(ndc, lp * -0.3, aspect, 0.05) * float3(1.0, 0.75, 0.45);
        col += lanternGhost(ndc, lp * -0.85, aspect, 0.032) * float3(0.7, 1.0, 0.75);
        return col * k;
    }

    /// Fire & Neon §5.5, the day's big moment: the sun breaks out and a path of glitter races across the sea from the
    /// horizon to the shore. The sun's glitter column (wide: the breeze's facets tilt every way) sparkling in points (cells
    /// square on screen, out stretched by the view's foreshortening from 60 m up, so they never shimmer), lit from the
    /// horizon down to the race's front, brightest along it, the water behind glittering on while the sun stays out.
    float3 roadGlitterRace(float3 d, float3 nrm, float2 q, float f, constant RoadU& u, constant OceanU& o) {
        float k = u.k.x;
        if (k <= 0.001) return float3(0);
        float3 L = o.sun.xyz;
        if (L.z < -0.03) return float3(0);
        float c = 1.0 - dot(reflect(d, nrm), L);      // about half the angle² from the sun's mirror
        float column = exp(-c / 0.018);
        if (column < 0.002) return float3(0);
        float x = (f - u.k.y) / (0.18 * u.k.y + 25.0);   // < 0 not reached yet … > 0 reached
        float crest = exp(-x * x * 2.5);
        float lit = crest * 1.6 + (x > 0.0 ? 0.45 + 0.55 * exp(-x / 2.0) : 0.0);
        if (lit < 0.002) return float3(0);
        float across = 0.008 * f;
        float2 cell = float2(across, across * max(f / kSeaBelow, 1.0));
        float2 g = q / cell;
        float2 id = floor(g);
        float3 h = hash33(float3(id, 11.0));
        float2 dd = g - (id + 0.25 + 0.5 * h.yz);
        float tw = 0.5 + 0.5 * sin(6.2831853 * (u.k.w + 2.0 * h.x) + o.phases.y);
        float pt = step(h.x, 0.2 + 0.6 * column) * exp(-dot(dd, dd) / 0.035) * tw * tw;
        return o.sunColor.rgb * (k * lit * column * (0.2 + 3.5 * pt) * (0.4 + 0.6 * o.sun.w) * 2.2);
    }

    /// The sun breaking out: its glare in the sea air round it (after the limiter), a bright core fading into a wide veil.
    float3 roadSunGlare(float3 d, constant RoadU& u, constant OceanU& o) {
        float k = u.k.z;
        if (k <= 0.001 || o.sun.z < -0.05) return float3(0);
        float c = 1.0 - dot(d, o.sun.xyz);
        return o.sunColor.rgb * (k * (1.5 * exp(-c / 0.0004) + 0.35 * exp(-c / 0.006) + 0.08 * exp(-c / 0.05)));
    }

    /// Fire & Neon §5.5: a lit train along the far shore, its windows a dotted line at the headlands' foot.
    float3 farTrain(float azRel, float alt, constant RoadU& u) {
        if (u.h.z <= 0.0 || abs(u.h.y) < 1e-4) return float3(0);
        float tu = (u.h.x - azRel) / u.h.y;                 // 0 at its head … 1 at its tail
        if (tu < -0.02 || tu > 1.0) return float3(0);
        float band = smoothstep(0.0003, 0.0007, alt) * (1.0 - smoothstep(0.0018, 0.0024, alt));
        float cars = fract(tu * 6.0), win = fract(tu * 42.0);
        float lit = step(0.0, tu) * step(0.08, cars) * step(cars, 0.94) * smoothstep(0.5, 0.2, abs(win - 0.5));
        float head = exp(-tu * tu / 0.0004);
        return (float3(1.0, 0.78, 0.48) * lit * 1.6 + float3(1.0, 0.95, 0.85) * head * 6.0) * (band * u.h.z);
    }

    fragment ColorDepth road_fragment(RoadOut in [[stage_in]], constant SkyU& sky [[buffer(0)]], constant RoadU& u [[buffer(1)]],
                                      constant OceanU& o [[buffer(2)]], texture2d<float> stars [[texture(0)]],
                                      texture2d<float> cell [[texture(9)]]) {
        ColorDepth out;
        float2 ndc = in.ndc;
        if (ndc.y < u.a.x) { out.color = float4(0, 0, 0, 1); out.depth = float4(0.05, 0, 0, 1); return out; }
        float2 p = outside(ndc, u);
        float3 d = normalize(sky.forward.xyz + sky.right.xyz * ndc.x * sky.right.w + sky.up.xyz * ndc.y * sky.up.w);
        float alt = asin(clamp(d.z, -1.0, 1.0)), az = atan2(d.x, d.y);
        float camAz = atan2(sky.forward.x, sky.forward.y);
        float azRel = az - camAz;
        if (azRel > 3.14159) azRel -= 6.28318;
        if (azRel < -3.14159) azRel += 6.28318;
        float3 horizon = sky.horizon.rgb, zenith = sky.zenith.rgb;
        float haze = u.a.w, lampsLit = u.c.x, night = u.c.y, speed = u.c.z, fog = u.c.w;
        float bottom = u.w.y;
        float opened = u.g.w;          // the drop: the road comes out of the scrub onto the open cliff
        fog *= 1.0 - 0.6 * opened;
        float3 extra = float3(0);      // the lighthouse and the far train, added over the sky after the premultiply
        float lightW = saturate(o.sun.w + o.moon.w);
        float3 lightCol = (o.sun.w * o.sunColor.rgb + o.moon.w * o.moonColor.rgb) / max(o.sun.w + o.moon.w, 1e-3);
        float3 hazeCol = horizon * (1.0 + 0.1 * night);
        float3 lampCol = float3(1.0, 0.72, 0.42);
        float3 ambient = zenith * 0.25 + horizon * 0.35;

        // Near layers (aspect units, rolled with the world).
        float railY = bottom + 0.2;
        float scrubY = scrubLine(p.x, u.b.y, bottom + 0.34 - 0.11 * opened);
        // Lamps: posts every kLampSpacing with an arm reaching over the road, lit from dusk.
        float lampDx = (fract(p.x / kLampSpacing + u.b.w) - 0.5) * kLampSpacing;
        float headY = u.w.z - 0.2;
        float post = smoothstep(0.012, 0.007, abs(lampDx)) * step(p.y, headY + 0.015) * step(scrubY - 0.05, p.y);
        float armY = headY + 0.012 + 0.16 * (lampDx / 0.16) * (1.0 - lampDx / 0.16) * 0.25;
        float arm = smoothstep(0.008, 0.004, abs(p.y - armY)) * step(0.0, lampDx) * step(lampDx, 0.165);
        float lampBody = max(post, arm);

        float3 col = float3(0);
        float alpha = 0.0;
        float depth = 1.0;
        if (p.y < scrubY) {
            // The scrub along the cliff edge, then the guardrail and the road edge.
            // Coastal scrub: clumps of dark bushes, leafy texture, a rim of sky light along the tops.
            float clumps = vnoiseP(float3((p.x + u.b.y) * 6.0, p.y * 7.0, 2.0), 240.0);
            float leaves = vnoiseP(float3((p.x + u.b.y) * 40.0, p.y * 40.0, 5.0), 1600.0);
            float3 scrub = float3(0.03, 0.04, 0.024) * (0.45 + 0.7 * clumps) * (0.75 + 0.5 * leaves);
            float depthIn = saturate((scrubY - p.y) / 0.12);
            col = scrub * (ambient * (1.1 - 0.5 * depthIn) + lightCol * lightW * 0.3 * (1.0 - depthIn));
            col += horizon * 0.12 * exp(-(scrubY - p.y) / 0.008) * (0.5 + 0.5 * leaves);
            // The lamps' pools of light on the scrub.
            float pool = exp(-(lampDx * lampDx) / 0.06) * exp(-max(scrubY - p.y, 0.0) / 0.18);
            col += lampCol * scrub * pool * lampsLit * 6.0 + lampCol * pool * lampsLit * 0.03;
            depth = 0.25;
            // Guardrail posts streaming past, blurred by speed.
            float postDx = (fract(p.x / kPostSpacing + u.b.z) - 0.5) * kPostSpacing;
            float blur = 0.004 + 0.05 * speed;
            float postCover = smoothstep(0.015 + blur, 0.015, abs(postDx)) * (0.015 / (0.015 + blur * 0.5)) * step(p.y, railY);
            // The rail: a galvanised W-beam with two grooves, catching the sky and the lamps.
            float ry = p.y - railY + 0.005;
            float beam = smoothstep(0.03, 0.024, abs(ry));
            float grooves = 0.75 + 0.25 * cos(ry * 200.0);
            float3 metal = float3(0.22, 0.23, 0.25) * grooves * (ambient * 1.4 + lightCol * lightW * 0.4)
                         + lampCol * lampsLit * 0.12 * exp(-(lampDx * lampDx) / 0.6);
            float sh = (p.y - railY - 0.016) / 0.005;
            float shine = exp(-sh * sh);
            col = mix(col, metal, max(beam, postCover * 0.95));
            col += (horizon * 0.25 + lampCol * lampsLit * 0.3) * shine * beam;
            // Oncoming headlights washing over the verge as each car passes, and gathering round the bend ahead.
            float w0 = p.x - u.i.x, w1 = p.x - u.i.z, w2 = p.x - u.j.x;
            float wash = u.i.y * exp(-w0 * w0 / 0.12) + u.i.w * exp(-w1 * w1 / 0.12) + u.j.y * exp(-w2 * w2 / 0.12);
            float ahead = u.h.w * smoothstep(0.1 * u.a.y, 0.95 * u.a.y, p.x);
            col += float3(0.85, 0.9, 1.0) * (0.09 * wash + 0.05 * ahead) * (0.4 + 0.6 * max(beam, 1.0 - depthIn));
            // Rime along the rail's top (spec §6.4), its feathers passing with the posts: two octaves of a noise that
            // repeats every post spacing, so the post phase's wrap never shows, smeared into an even band by speed
            // (like the posts) so it never strobes.
            float railIn = 0.027 - ry;
            if (beam > 0.0 && ry > 0.0 && rimeNear(sky, railIn)) {
                float along = fract(p.x / kPostSpacing + u.b.z);
                float feather = 0.65 * vnoiseP(float3(along * 48.0, ry * 90.0, 2.7), 48.0)
                              + 0.35 * vnoiseP(float3(along * 96.0, ry * 180.0, 5.3), 96.0);
                feather = mix(feather, 0.55, saturate(speed * 1.5));
                col = mix(col, rimeColor(sky), rimeFringe(sky, railIn, float2(0.0, 1.0), feather) * beam);
            }
            // The road's edge below the rail; wet tarmac darkens, mirrors the sky and streaks the lamps' light.
            if (p.y < bottom + 0.06) {
                float wetRoad = u.e.x;
                col = float3(0.018, 0.017, 0.016) * (ambient + 0.4) * (1.0 - 0.35 * wetRoad) + lampCol * lampsLit * 0.03;
                col += (zenith * 0.5 + horizon * 0.5) * 0.18 * wetRoad;
                float below = saturate((u.e.y - p.y) / 0.06);
                col += lampCol * lampsLit * wetRoad * 0.35 * exp(-(lampDx - 0.16) * (lampDx - 0.16) / 0.0012) * (0.6 + 0.4 * below);
                depth = 0.1;
            }
            alpha = 1.0;
        } else if (alt < 0.0) {
            // The sea from height (the Ocean layer, travelling with the car).
            float t = kSeaBelow / max(-d.z, 0.003);   // at most 20 km: the haze has it by then
            float3 P = d * t;
            float2 fwd = normalize(sky.forward.xy), rgt = float2(fwd.y, -fwd.x);
            float f = dot(P.xy, fwd), s = dot(P.xy, rgt);
            float2 q = float2(s, f);
            float2 slope = oceanSlope(q, o, oceanFootprint(d, f, sky));
            float3 nrm = oceanNormal(slope, fwd, rgt);
            col = oceanShade(d, nrm, q, f, sky, o, stars, cell);
            col += roadGlitterRace(d, nrm, q, f, u, o);
            // White water at the cliff base, surging with each break.
            float above = p.y - scrubY;
            float since = u.d.x, last = u.d.y, base = u.d.z;
            float surge = last > 0.0 && since >= 0.0 ? last * exp(-since / 3.0) * smoothstep(0.0, 0.6, since) : 0.0;
            float width = 0.02 + 0.03 * vnoiseP(float3((p.x + base) * 4.0, 1.0, 0.0), 200.0) + 0.04 * surge;
            float lace = smoothstep(0.3, 0.7, vnoiseP(float3((p.x + base) * 12.0, above * 30.0, 2.0 * sin(o.phases.x)), 600.0));
            float white = exp(-above / width) * (0.35 + 0.65 * lace) * (0.5 + 0.8 * surge);
            float3 foamCol = (horizon * 0.55 + 0.3) * (0.5 + 0.6 * lightW) + lightCol * 0.2 * lightW;
            col = mix(col, foamCol, saturate(white));
            col = mix(col, hazeCol, saturate(haze * 0.75 * (1.0 - exp(-f / 900.0))));
            // The beams in the air over the sea, as far as the water (a beam facing you lights the air all round).
            extra = lighthouseLight(d, sky, u, haze, fog, t) + roadSunGlare(d, u, o);
            depth = 0.6 + 0.4 * saturate(f / 3000.0);
            alpha = 1.0;
        } else {
            // Far headlands: two or three ridgelines in haze above the horizon, scrolling very slowly.
            float hl = -1.0;
            for (int i = 0; i < 3; i++) {
                float k = float(i);
                float x = azRel * (2.0 + k) + u.b.x * (0.4 + 0.5 * k) + k * 7.3;
                float present = smoothstep(0.35, 0.6, vnoise3(float3(x * 0.35, k, 0.0)));
                float h = (0.4 + 0.45 * (3.0 - k) * present + 0.5 * vnoise3(float3(x * 2.0, k + 4.0, 1.0)) * present) * 0.0174533 * present;
                if (alt < h && h > hl) {
                    hl = h;
                    float far = (3.0 - k) / 3.0;
                    float3 c = mix(horizon, zenith, 0.35) * (0.25 + 0.15 * k) + o.sunColor.rgb * 0.02 * o.sun.w;
                    col = mix(c, hazeCol, saturate(0.35 + 0.35 * far + 0.3 * haze));
                }
            }
            if (hl > 0.0) { alpha = 1.0; depth = 0.97; }
            extra = lighthouseLight(d, sky, u, haze, fog, 1e9) * (hl > 0.0 ? 0.5 : 1.0) + roadSunGlare(d, u, o);
            if (hl > 0.0) extra += farTrain(azRel, alt, u);
        }
        // Premultiplied from here: lamp posts over everything, fog over the view, lamp heads glowing on top.
        col *= alpha;
        if (lampBody > 0.0) {
            float3 postCol = float3(0.02, 0.02, 0.022) * (zenith + horizon * 0.5) + lampCol * lampsLit * 0.05;
            float lampRime = lampPostRime(sky, lampDx, p.y, armY, post, arm);
            if (lampRime > 0.0) postCol = mix(postCol, rimeColor(sky), lampRime);
            col = col * (1.0 - lampBody) + postCol * lampBody;
            alpha = alpha + (1.0 - alpha) * lampBody;
            depth = min(depth, 0.2);
        }
        if (fog > 0.001) {
            float fn = vnoiseP(float3((p.x + u.b.y * 0.625) * 0.8, p.y * 2.5, 1.0 + sin(o.phases.y)), 20.0);
            float low = exp(-max(p.y - scrubY + 0.15, 0.0) / 0.5);
            float3 fogCol = hazeCol * 0.95 + lampCol * lampsLit * 0.06;
            float fa = saturate(fog * (0.25 + 0.75 * fn) * (0.35 + 0.65 * low)) * (alt < 0.0 || p.y < scrubY ? 1.0 : 0.5);
            col = col * (1.0 - fa) + fogCol * fa;
            alpha = alpha + (1.0 - alpha) * fa;
        }
        float2 head = float2(lampDx - 0.16, p.y - headY + 0.01);
        float hd2 = dot(head * float2(1.0, 1.6), head * float2(1.0, 1.6));
        col += lampCol * lampsLit * (exp(-hd2 / 0.0009) * 5.0 + exp(-hd2 / 0.012) * 0.6);
        extra += lanternFlare(ndc, sky, u);
        col += extra;
        if (alpha < 0.002 && hd2 > 0.1 && extra.r + extra.g + extra.b < 1e-5) discard_fragment();
        out.color = float4(col, alpha);
        out.depth = float4(depth, 0, 0, 1);
        return out;
    }

    // Coast Lights: per instance (x, y, trail length, radius) and (r, g, b, brightness), NDC before the roll.
    struct LightInstance { float4 pos; float4 colour; };
    struct LightOut { float4 pos [[position]]; float2 local; float4 colour; float trail; float radius; float reflection; float worldY; };
    vertex LightOut road_lights_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant LightInstance* lights [[buffer(0)]],
                                       constant RoadU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        LightInstance l = lights[iid];
        float reflection = l.pos.w < 0.0 ? 1.0 : 0.0;   // a reflection on the wet road: stretched 4× down
        float r = abs(l.pos.w), trail = l.pos.z, stretch = 1.0 + 3.0 * reflection;
        float2 lo = float2(-r * 2.5, -r * 2.5 * stretch), hi = float2(trail + r * 2.5, r * 2.5 * stretch);
        float2 local = mix(lo, hi, c[vid]);
        // Aspect units, rotated by the roll, then back to NDC.
        float aspect = u.a.y, ro = u.a.z, cr = cos(ro), sr = sin(ro);
        float2 q = float2(l.pos.x * aspect + local.x, l.pos.y + local.y);
        float2 rq = float2(q.x * cr + q.y * sr, -q.x * sr + q.y * cr);   // the world's frame back to the screen's
        LightOut o;
        o.pos = float4(rq.x / aspect, rq.y, 0, 1);
        o.local = local;
        o.colour = l.colour;
        o.trail = trail;
        o.radius = r;
        o.reflection = reflection;
        o.worldY = l.pos.y + local.y;
        return o;
    }
    fragment float4 road_lights_fragment(LightOut in [[stage_in]], constant RoadU& u [[buffer(1)]]) {
        float r = in.radius;
        float2 q = in.local;
        if (in.reflection > 0.5) {
            if (in.worldY > u.e.y || in.worldY < u.w.y) discard_fragment();   // only on the road itself
            q.y *= 0.25;
        }
        float core = exp(-dot(q, q) / (r * r));
        float along = saturate(q.x / max(in.trail, 1e-4));
        float streak = in.trail > 0.0 && q.x > 0.0 ? exp(-(q.y * q.y) / (r * r * 0.25)) * (1.0 - along) * (1.0 - along) * step(q.x, in.trail) : 0.0;
        float3 c = in.colour.rgb * in.colour.w * (core * 2.2 + streak * 0.9 + exp(-dot(q, q) / (r * r * 5.0)) * 0.25);
        return float4(c, 0.0);
    }

    // Posts and arms for the lamps that high notes light: per instance (x, head y, base y, unused) in aspect
    // units of the world's frame, rolled like the lights.
    struct PostOut { float4 pos [[position]]; float2 local; float4 p; };
    vertex PostOut road_post_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4* posts [[buffer(0)]],
                                    constant RoadU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        float4 pp = posts[iid];
        float2 q = mix(float2(pp.x - 0.02, pp.z), float2(pp.x + 0.19, pp.y + 0.06), c[vid]);
        float aspect = u.a.y, ro = u.a.z, cr = cos(ro), sr = sin(ro);
        float2 rq = float2(q.x * cr + q.y * sr, -q.x * sr + q.y * cr);
        PostOut o;
        o.pos = float4(rq.x / aspect, rq.y, 0, 1);
        o.local = q;
        o.p = pp;
        return o;
    }
    fragment float4 road_post_fragment(PostOut in [[stage_in]], constant float4& colour [[buffer(0)]],
                                       constant SkyU& sky [[buffer(1)]]) {
        float2 q = in.local;
        float dx = q.x - in.p.x, headY = in.p.y;
        float post = smoothstep(0.012, 0.007, abs(dx)) * step(q.y, headY + 0.015);
        float w = dx / 0.16;
        float armY = headY + 0.012 + 0.04 * w * (1.0 - w);
        float arm = smoothstep(0.008, 0.004, abs(q.y - armY)) * step(0.0, dx) * step(dx, 0.165);
        float a = max(post, arm);
        float r = lampPostRime(sky, dx, q.y, armY, post, arm);   // rimed like the road's own lamp posts
        float3 c = r > 0.0 ? mix(colour.rgb, rimeColor(sky), r) : colour.rgb;
        return float4(c * a, a);
    }

    // ---------------------------------------------------------------- Fire & Neon §5.5: a fox in the scrub
    // p: where it stands (x, y of its feet, aspect units of the world's frame), its height (aspect units), its trot's
    // phase; q: cover, eyeshine 0…1, unused, unused; tint: its coat (rgb), unused. Rolled like the lights; premultiplied
    // (the eyeshine adds light).
    struct FoxInstance { float4 p; float4 q; float4 tint; };
    struct FoxOut { float4 pos [[position]]; float2 uv; float4 q; float4 tint; float trot; };

    vertex FoxOut road_fox_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant FoxInstance* foxes [[buffer(0)]],
                                  constant RoadU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        FoxInstance fx = foxes[iid];
        float2 uv = mix(float2(-1.4, -0.15), float2(1.4, 1.4), c[vid]);
        float2 q = fx.p.xy + uv * fx.p.z;
        float aspect = u.a.y, ro = u.a.z, cr = cos(ro), sr = sin(ro);
        float2 rq = float2(q.x * cr + q.y * sr, -q.x * sr + q.y * cr);
        FoxOut o;
        o.pos = float4(rq.x / aspect, rq.y, 0, 1);
        o.uv = uv;
        o.q = fx.q;
        o.tint = fx.tint;
        o.trot = fx.p.w;
        return o;
    }

    float2 foxSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
        return float2(length(pa - ba * h), h);
    }

    /// A fox side on, in units of its height (feet at y = 0, its head to the right, turned to look at you): body, legs
    /// mid-trot, a bushy tail, a pointed head with its ears up. A signed distance.
    float foxDistance(float2 uv, float trot) {
        float d = length((uv - float2(0.0, 0.55)) / float2(1.0, 0.36)) - 0.55;
        d = min(d, length(uv - float2(0.62, 0.78)) - 0.15);
        float2 sn = foxSegment(uv, float2(0.66, 0.74), float2(0.86, 0.7));
        d = min(d, sn.x - mix(0.07, 0.025, sn.y));
        for (int k = 0; k < 2; k++) {
            float ex = k == 0 ? 0.56 : 0.68;
            float2 ear = foxSegment(uv, float2(ex, 0.86), float2(ex - 0.02, 1.05));
            d = min(d, ear.x - mix(0.05, 0.01, ear.y));
        }
        float2 tail = foxSegment(uv, float2(-0.48, 0.58), float2(-1.15, 0.36 + 0.04 * sin(trot * 0.5)));
        d = min(d, tail.x - (0.08 + 0.07 * sin(3.14159 * tail.y)));
        for (int k = 0; k < 4; k++) {
            float fk = float(k);
            float x = k < 2 ? 0.3 + 0.08 * fk : -0.32 + 0.08 * (fk - 2.0);
            float swing = 0.09 * sin(trot + fk * 1.7 + (k < 2 ? 0.0 : 3.14159));
            float2 leg = foxSegment(uv, float2(x, 0.42), float2(x + swing, 0.0));
            d = min(d, leg.x - 0.035);
        }
        return d;
    }

    fragment float4 road_fox_fragment(FoxOut in [[stage_in]]) {
        float d = foxDistance(in.uv, in.trot);
        float aa = max(fwidth(in.uv.x) * 1.2, 1e-3);
        float cover = (1.0 - smoothstep(-aa, aa, d)) * in.q.x;
        // Eyeshine: the car's light caught in its eyes, green-gold, at night.
        float2 e0 = in.uv - float2(0.59, 0.81), e1 = in.uv - float2(0.69, 0.81);
        float eyes = (exp(-dot(e0, e0) / 0.0006) + exp(-dot(e1, e1) / 0.0006)) * in.q.y * in.q.x;
        if (cover < 0.002 && eyes < 0.002) discard_fragment();
        float3 glow = float3(0.7, 1.0, 0.45) * eyes * 3.0;
        return float4(in.tint.rgb * cover + glow, cover);
    }

    // ---------------------------------------------------------------- Fire & Neon §5.5: seabirds lifting past the window
    // p: where the bird is (x, y, aspect units of the world's frame), its half-span (aspect units), its wingbeat's phase
    // (radians); c: its underside's colour (rgb, lit), its cover. Rolled like the lights; premultiplied.
    struct BirdInstance { float4 p; float4 c; };
    struct BirdOut { float4 pos [[position]]; float2 uv; float4 c; float beat; };

    vertex BirdOut road_bird_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant BirdInstance* birds [[buffer(0)]],
                                    constant RoadU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        BirdInstance bi = birds[iid];
        float2 uv = mix(float2(-1.15, -0.75), float2(1.15, 0.75), c[vid]);
        float2 q = bi.p.xy + uv * bi.p.z;
        float aspect = u.a.y, ro = u.a.z, cr = cos(ro), sr = sin(ro);
        float2 rq = float2(q.x * cr + q.y * sr, -q.x * sr + q.y * cr);
        BirdOut o;
        o.pos = float4(rq.x / aspect, rq.y, 0, 1);
        o.uv = uv;
        o.c = bi.c;
        o.beat = bi.p.w;
        return o;
    }

    /// A gull from a little below, in units of its half-span: a small body and head, and each wing a shoulder–wrist–tip
    /// line, thick at the shoulder and fine at the tip, bending at the wrist as it beats. Returns its cover; `tips` the
    /// dark wingtips' share, `rim` the sunlit upper edge's.
    float roadGull(float2 p, float beat, float aa, thread float& tips, thread float& rim) {
        float flap = sin(beat);
        float2 s = float2(abs(p.x), p.y);
        float2 shoulder = float2(0.07, 0.0);
        float2 wrist = float2(0.45, 0.1 + 0.22 * flap);
        float2 tip = float2(0.98, -0.02 + 0.45 * flap - 0.1 * cos(beat));
        float2 a1 = foxSegment(s, shoulder, wrist), a2 = foxSegment(s, wrist, tip);
        float inner = a1.x - mix(0.085, 0.05, a1.y);
        float outer = a2.x - mix(0.05, 0.012, a2.y);
        float wing = min(inner, outer);
        float body = length((p - float2(0.0, -0.02)) / float2(0.075, 0.2)) - 1.0;
        float head = length(p - float2(0.0, 0.17)) - 0.055;
        float dist = min(wing * 1.0, min(body * 0.075, head));
        float cover = 1.0 - smoothstep(-aa, aa, dist);
        tips = (outer < inner && a2.y > 0.55) ? 1.0 : 0.0;
        // The wing's upper (leading) edge catches the sun.
        float2 dir = normalize(tip - wrist);
        float above = (s - wrist).x * -dir.y + (s - wrist).y * dir.x;
        rim = smoothstep(0.0, 0.03, above) * (outer < inner ? 1.0 : 0.5);
        return cover;
    }

    fragment float4 road_bird_fragment(BirdOut in [[stage_in]]) {
        float aa = max(fwidth(in.uv.x) * 1.2, 1e-3);
        float tips = 0.0, rim = 0.0;
        float cover = roadGull(in.uv, in.beat, aa, tips, rim) * in.c.a;
        if (cover < 0.002) discard_fragment();
        float3 col = in.c.rgb * (1.0 - 0.75 * tips) * (0.85 + 0.6 * rim);
        return float4(col * cover, cover);
    }

    // The car around the window: door trim and headliner lit by the sky and the dashboard, a rubber seal
    // along the glass, and faint reflections on the glass itself.
    fragment ColorDepth road_frame_fragment(RoadOut in [[stage_in]], constant RoadU& u [[buffer(1)]], constant SkyU& sky [[buffer(0)]]) {
        float2 ndc = in.ndc;
        float2 p = float2(ndc.x * u.a.y, ndc.y);
        float dist = windowDistance(p, u);
        float px = 2.0 / 720.0;
        float cover = smoothstep(-px, px, dist);
        float3 ambient = sky.zenith.rgb * 0.08 + sky.horizon.rgb * 0.12;
        float3 dash = float3(1.0, 0.55, 0.18);
        float keysTop = u.a.x;
        if (cover < 0.004) {
            // On the glass: a faint diagonal sheen and the dashboard's glow reflected low down.
            float sx = (p.x * 0.35 + p.y - 0.25) / 0.35;
            float sheen = exp(-sx * sx) * 0.025;
            float dashRefl = exp(-max(p.y - u.w.y, 0.0) / 0.12) * 0.04;
            float3 c = ambient * sheen * 3.0 + dash * dashRefl * 0.25;
            ColorDepth o; o.color = float4(c, 0.0); o.depth = float4(0.05, 0, 0, 0);
            return o;
        }
        float3 trim = float3(0.018, 0.017, 0.016) + ambient * 0.5;
        trim += dash * 0.05 * exp(-max(ndc.y - keysTop, 0.0) / 0.3);          // the dashboard's glow on the door
        trim *= 0.8 + 0.2 * smoothstep(-1.0, 1.0, ndc.y);
        float seal = exp(-max(dist, 0.0) / 0.01);
        trim = mix(trim, float3(0.006), seal * 0.6);
        float ex = (dist - 0.018) / 0.006;
        trim += (sky.horizon.rgb * 0.06) * exp(-ex * ex);   // a lit edge on the trim
        ColorDepth o;
        o.color = float4(trim * cover, cover);
        o.depth = float4(0.04, 0, 0, 1);
        return o;
    }

    // Keys: rect (x0, y0, x1, y1) and info (isBlack, glow, pressed, light); dashboard amber.
    struct RoadKey { float4 rect; float4 info; };
    struct RoadKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex RoadKeyOut road_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant RoadKey* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        RoadKey k = keys[iid];
        RoadKeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth road_keys_fragment(RoadKeyOut in [[stage_in]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.004, 0.004, 0.005) : float3(0.03, 0.03, 0.032);
        float sheen = pow(in.uv.y, 6.0) * (black ? 0.04 : 0.1) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 amber = float3(1.0, 0.55, 0.18);
        float3 c = base + float3(0.8, 0.8, 0.85) * sheen * (0.3 + 0.5 * light) + amber * glow * (1.7 * (0.3 + 0.7 * in.uv.y));
        c *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(c, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
