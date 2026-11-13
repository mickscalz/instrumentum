/// Metal source for Neon Night Drive (Fire & Neon spec §9): the view through the windscreen down a wet elevated expressway
/// into a dense neon city at night. One full-screen pass (`drive_scene_fragment`) draws the sky, the city, the road and its
/// traffic; a second (`drive_mirror_fragment`, at half resolution, added in by `drive_mirror_compose_fragment`) adds the wet
/// road's and the harbour's mirror of the city from a blurred copy of the first, streaked down the road; Light Trails (`LightTrailsShaders`) and the windscreen (`WindscreenShaders`) go
/// over them.
///
/// Everything is hit in closed form, never marched: the road deck, its parapets and the median are planes; the towers along
/// the road are rows of facades parallel to it (each building found from the row's plane, its setback and its end wall
/// facing you), the downtown ahead is layers of facades facing you; the tunnel is a box, the bridge's harbour a plane. The
/// windows are a hashed grid box-filtered by each pixel's footprint (no stair-steps or shimmer at any distance); the neon
/// signs are SDF glyph strokes on the facades they hang on (so the towers in front hide them), wordless, coloured by the
/// chord and pulsed by the notes. The street lights' and the traffic's reflections on the wet road are analytic streaks.
/// Smooth rules: no ray marching, at most 3 octaves (2 on Smooth), no pow.
enum NeonNightDriveShaders {
    /// The drive's uniforms and geometry, shared by the scene, the reflections and Light Trails.
    static let common = """
    struct DriveU {
        float4 a;        // aspect, time (s, wrapped at an hour), octaves, pixel angle (rad)
        float4 axes;     // the road's forward (ENU xy), its right (ENU xy)
        float4 move;     // distance (m, wrapped), speed 0…1.25, metres a second, night 0…1
        float4 neon;     // warmth, the Neon dial, city light (the release's breath), keys top (NDC)
        float4 wave;     // wave age (s; < 0 none), wave strength (after the limiter), tunnel strobe 0…1 (after the limiter), 0
        float4 play;     // energy, tension, drop, close-in
        float4 route;    // tunnel start, tunnel end, bridge start, bridge end (m ahead; 1e5 none)
        float4 route2;   // parting 0…1, tunnel light spacing (m), tunnel light offset (m), 0
        float4 rain;     // rain outside, glass rain, wetness, rain slow
        float4 amb;      // ambient light (rgb), sun up 0…1
        float4 haze;     // haze colour (rgb), haze distance (m)
        float4 glow;     // skyglow colour (rgb), strength
        float4 flash;    // lightning light (after the limiter), across (−1…1), seed (0…1), 0
        float4 over;     // overpass ahead (m; 1e5 none), depth (m), rail 0/1, train head x (m; −1e5 none)
        float4 over2;    // train length (m), 0, 0, 0
        float4 bloom;    // interchange at (m; < 0 none), light, seed (0…1), 0
        float4 dead;     // the dying sign's slot (−1 none), its light, 0, 0
        float4 road1;    // left parapet x, left edge x, median near x, median far x (m)
        float4 road2;    // far parapet x, parapet height, median height, lane width (m)
        float4 road3;    // your lane's centre x, eye height (m), 0, layers a timing test skips (0 in the app)
        float4 signs[12];   // the 48 signs' pulses, four a row
        float4 studs[16];   // ahead (m; ≤ 0 empty), brightness, 0, 0
        float4 cars[24];    // per car: (x centre, ahead, oncoming, brake), (seed 0…1, light bar, body, 0); empty: ahead −1e5
        float4 pal[6];      // the neon now: three palette colours (rgb), then three accents (rgb)
        float4 moon;        // the moon behind the overcast: its direction (east-north-up), how much shows 0…1
        float4 cabin;       // the windscreen's outline (NDC): the dashboard's line y, the roof's line y, 0, 0
        float4 pillars;     // the left pillar's inner edge x at the dashboard and at the roof, the right pillar's
        float4 carCone[12]; // per car: the direction to its lights (the road's frame), and the cosine within which a ray
                            // passes nearer than its glow reaches (|cos| under it: none of the car; empty 2, always −1)
    };
    struct DriveOut { float4 pos [[position]]; float2 ndc; };

    vertex DriveOut drive_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        DriveOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- small maths
    float sq(float x) { return x * x; }
    float hash12(float2 p) {
        float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    float hash11(float p) {
        p = fract(p * 0.1031);
        p *= p + 33.33;
        p *= p + p;
        return fract(p);
    }
    float vn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
    }
    float fbm2(float2 p, int octaves) {
        float s = 0.0, a = 0.5, n = 0.0;
        for (int i = 0; i < 3; i++) {
            if (i >= octaves) break;
            s += a * vn2(p);
            n += a;
            p = p * 2.03 + float2(17.1, 9.2);
            a *= 0.5;
        }
        return s / n;
    }
    /// Water's reflectance at a grazing angle (`c` the cosine from the normal): Schlick's, written out.
    float fresnelWet(float c) {
        float m = 1.0 - clamp(c, 0.0, 1.0);
        float m2 = m * m;
        return 0.02 + 0.98 * m2 * m2 * m;
    }
    /// A pulse train of period `p` that is 1 for the first `on` of each period, box-filtered over `w` (all in the same
    /// units): exact, so windows and dashes never alias however small they get.
    float pulseTrain(float x, float p, float on, float w) {
        float ww = max(w, 1e-4);
        float a = x - 0.5 * ww, b = x + 0.5 * ww;
        float fa = floor(a / p) * on + clamp(a - floor(a / p) * p, 0.0, on);
        float fb = floor(b / p) * on + clamp(b - floor(b / p) * p, 0.0, on);
        return clamp((fb - fa) / ww, 0.0, 1.0);
    }

    // ---------------------------------------------------------------- the camera
    /// The view ray in the road's frame (x right, y up, z ahead; the eye at (0, eye, 0)) and in east-north-up.
    float3 driveRay(float2 ndc, constant SkyU& sky, constant DriveU& u, thread float3& dE) {
        dE = normalize(sky.forward.xyz + sky.right.xyz * (ndc.x * sky.right.w) + sky.up.xyz * (ndc.y * sky.up.w));
        return float3(dot(dE.xy, u.axes.zw), dE.z, dot(dE.xy, u.axes.xy));
    }
    /// A direction in the road's frame back to the screen (NDC); w < 0 behind the camera.
    float3 driveProject(float3 d, constant SkyU& sky, constant DriveU& u) {
        float3 e = float3(d.x * u.axes.zw + d.z * u.axes.xy, d.y);
        float depth = dot(e, sky.forward.xyz);
        return float3(dot(e, sky.right.xyz) / (max(depth, 1e-4) * sky.right.w),
                      dot(e, sky.up.xyz) / (max(depth, 1e-4) * sky.up.w), depth);
    }

    /// The wet road's (and the harbour's) surface along a ray: its distance, its kind (1 road, 2 water) and where it is
    /// (road frame), or 0 for neither. Shared by the scene and the reflection pass so both agree on the mirror.
    float driveSurface(float3 d, constant DriveU& u, thread float3& p) {
        if (d.y >= -1e-5) return 0.0;
        float eye = u.road3.y;
        float t = eye / -d.y;
        p = float3(d.x * t, 0.0, d.z * t);
        float lp = u.road1.x, fp = u.road2.x;
        // The deck between the parapets (the median's top counts as the median, not road).
        if (p.x >= lp && p.x <= fp) {
            if (p.x > u.road1.z && p.x < u.road1.w) return 0.0;
            // The tunnel's road is dry.
            if (p.z > u.route.x && p.z < u.route.y) return 0.0;
            // The parapets in front of the deck hide nothing of the deck itself (they stand at its edges).
            return 1.0;
        }
        // Past the deck's edge: the harbour under a bridge (the railing lets it be seen), else the street far below.
        float tw = (eye + 22.0) / -d.y;
        float3 w = float3(d.x * tw, -22.0, d.z * tw);
        // Over the parapet only on a bridge: elsewhere the parapet's top hides the ground this close to the deck.
        float edgeT = (p.x < lp ? lp : fp) / d.x;
        float yAtEdge = eye + d.y * edgeT;
        float zAtEdge = d.z * edgeT;
        bool onBridge = zAtEdge > u.route.z && zAtEdge < u.route.w;
        if (!onBridge && yAtEdge < u.road2.y) return 0.0;
        if (w.z > u.route.z - 60.0 && w.z < u.route.w + 60.0 && u.route.z < 1e4) { p = w; return 2.0; }
        return 0.0;
    }
    """

    static let source = SkyShaders.common + common + """
    // ---------------------------------------------------------------- the city's light
    /// The neon's colour for a slot (0…2 the chord's palette, 3…5 the accents).
    float3 neonColour(int slot, constant DriveU& u) { return u.pal[clamp(slot, 0, 5)].rgb; }

    /// The haze between the eye and a point `t` away along `d`: the rain-soaked city air glowing with its own light.
    float3 hazeColour(float3 d, constant DriveU& u) {
        float up = saturate(d.y * 3.0);
        float3 low = u.haze.rgb;
        float3 high = u.haze.rgb * float3(0.45, 0.5, 0.75);
        return mix(low, high, up);
    }
    float3 applyHaze(float3 col, float t, float3 d, constant DriveU& u) {
        float k = 1.0 - exp(-t / max(u.haze.w, 1.0));
        return mix(col, hazeColour(d, u), k);
    }

    // ---------------------------------------------------------------- the sky
    float3 driveSky(float3 dE, float3 d, constant SkyU& sky, constant DriveU& u, texture2d<float> stars,
                    texture2d<float> cell) {
        float moonMask = 0.0;
        float3 s = skyRadiance(dE, sky, moonMask, stars, cell);
        float night = u.move.w;
        // The city washes out all but the brightest stars and lights the cloud base from below: warm near the horizon,
        // stronger over the downtown ahead, the cloud's underside mottled.
        float el = max(d.y, 0.0);
        float ahead = d.z / max(length(d.xz), 1e-4);
        float across = d.x / max(d.z, 0.05);
        float overCity = 0.55 + 0.45 * exp(-across * across * 1.6);
        float2 cp = d.xz / max(d.y + 0.035, 0.035) * 0.9 + float2(u.a.y * 0.012, u.move.x * 0.0004);
        int oct = int(u.a.z + 0.5);
        float cloud = fbm2(cp, oct);
        float lowCloud = exp(-el / 0.1) * overCity * (0.3 + 1.3 * cloud * cloud);
        // The overcast's base overhead, lit from below: mottled, its gaps darker.
        float mottle = smoothstep(0.25, 0.75, cloud);
        float highCloud = 0.22 * exp(-el / 0.5) * (0.1 + 1.6 * mottle * mottle);
        float3 glow = u.glow.rgb * (u.glow.w * night * u.neon.z * smoothstep(-0.2, 0.3, ahead)) * lowCloud
                    + u.glow.rgb * float3(0.6, 0.55, 0.9) * (u.glow.w * night * highCloud);
        s = s * (1.0 - 0.6 * night) + glow + float3(0.0015, 0.002, 0.005) * night;
        // The moon behind the overcast (the Sky kit's own disc isn't drawn here): soft and dim in its halo, a little
        // clearer where the cloud thins.
        float3 M = u.moon.xyz;
        if (u.moon.w > 0.0 && M.z > -0.02) {
            float ang = acos(clamp(dot(dE, M), -1.0, 1.0));
            float R = max(sky.moonInfo.z, 0.004);
            float disc = 1.0 - smoothstep(R * 0.6, R * 1.6, ang);
            float halo = exp(-ang / (R * 3.0)) * 0.35 + exp(-ang / 0.2) * 0.05;
            float through = 0.45 + 0.55 * (1.0 - smoothstep(0.3, 0.8, cloud));
            s += float3(0.72, 0.78, 0.92) * (u.moon.w * through * (disc * 0.08 + halo * 0.05));
        }
        // Far lightning behind the towers (a surprise): the cloud lit from inside near its place on the skyline, and its
        // bolt, a thin jagged line from the cloud base down behind the towers.
        if (u.flash.x > 0.0) {
            float fx = (across - u.flash.y * 0.9);
            float lit = exp(-fx * fx * 9.0) * exp(-el / 0.25);
            s += float3(0.7, 0.75, 1.0) * (u.flash.x * 0.9 * lit * (0.5 + cloud));
            float jag = (vn2(float2(el * 60.0, u.flash.z * 91.0)) - 0.5) * 0.03 + (vn2(float2(el * 13.0, u.flash.z * 37.0)) - 0.5) * 0.05;
            float bolt = exp(-sq((fx - jag) / 0.0035)) * step(el, 0.16) * (1.0 - u.flash.w);
            s += float3(0.85, 0.9, 1.0) * (u.flash.x * 3.0 * bolt);
        }
        return s;
    }

    // ---------------------------------------------------------------- neon glyphs (wordless)
    float sdSeg(float2 p, float2 a, float2 b) {
        float2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
        return length(pa - ba * h);
    }
    float sdArc(float2 p, float2 c, float r, float a0, float a1) {
        float2 q = p - c;
        float ang = atan2(q.y, q.x);
        if (ang >= a0 && ang <= a1) return abs(length(q) - r);
        float2 e0 = c + r * float2(cos(a0), sin(a0)), e1 = c + r * float2(cos(a1), sin(a1));
        return min(length(p - e0), length(p - e1));
    }
    /// The distance from `p` (−1…1 across the sign) to the tube's centre line of glyph `kind`: rings, chevrons, ticks,
    /// waves, arcs, a crescent, a diamond, stacked bars, a zigzag; and once in the city the app's own butterfly.
    float glyph(int kind, float2 p) {
        switch (kind) {
            case 0: {
                // A target: two rings and a dot.
                float d = min(abs(length(p) - 0.82), abs(length(p) - 0.46));
                return min(d, max(length(p) - 0.1, 0.0));
            }
            case 1: {
                float2 q = float2(abs(p.x + 0.35) < abs(p.x - 0.35) ? p.x + 0.35 : p.x - 0.35, abs(p.y));
                return sdSeg(q, float2(-0.25, 0.72), float2(0.25, 0.0));
            }
            case 2: {
                // A sun: a ring with eight short rays.
                float d = abs(length(p) - 0.42);
                float a = atan2(p.y, p.x);
                float k = round(a / 0.785398) * 0.785398;
                float2 dir = float2(cos(k), sin(k));
                return min(d, sdSeg(p, dir * 0.62, dir * 0.9));
            }
            case 3: {
                float2 a = float2(0, 0.8), b = float2(0.75, -0.6), c = float2(-0.75, -0.6);
                return min(min(sdSeg(p, a, b), sdSeg(p, b, c)), sdSeg(p, c, a));
            }
            case 4: {
                // A hexagon.
                float2 q = abs(p);
                float d = max(q.x * 0.866 + q.y * 0.5, q.y) - 0.78;
                return abs(d);
            }
            case 5: {
                float outer = length(p) - 0.8;
                float inner = length(p - float2(0.34, 0.16)) - 0.66;
                return abs(max(outer, -inner));
            }
            case 6: {
                float d = abs(abs(p.x) + abs(p.y) - 0.86) * 0.7071;
                return min(d, max(length(p) - 0.1, 0.0));
            }
            case 7: {
                float d = 10.0;
                for (int i = 1; i <= 3; i++) d = min(d, sdArc(p, float2(0, -0.75), 0.48 * float(i), 0.75, 2.39));
                return min(d, length(p - float2(0, -0.75)) - 0.04);
            }
            case 8: {
                float d = abs(length(p) - 0.8);
                d = min(d, sdSeg(p, float2(-0.5, 0), float2(0.5, 0)));
                return min(d, sdSeg(p, float2(0, -0.5), float2(0, 0.5)));
            }
            case 9: {
                float d = sdSeg(p, float2(-0.85, 0.55), float2(0.85, 0.55));
                d = min(d, sdSeg(p, float2(-0.55, 0.0), float2(0.55, 0.0)));
                return min(d, sdSeg(p, float2(-0.25, -0.55), float2(0.25, -0.55)));
            }
            case 10: {
                // A four-pointed sparkle.
                float2 q = abs(p);
                float d = sdSeg(q, float2(0.0, 0.92), float2(0.2, 0.2));
                d = min(d, sdSeg(q, float2(0.2, 0.2), float2(0.92, 0.0)));
                return d;
            }
            default: {
                // The butterfly: two wings either side of a body, and two antennae.
                float2 q = float2(abs(p.x), p.y);
                float upper = abs(length((q - float2(0.42, 0.28)) * float2(1.0, 1.25)) - 0.36);
                float lower = abs(length((q - float2(0.3, -0.36)) * float2(1.15, 1.0)) - 0.24);
                float body = sdSeg(p, float2(0, -0.55), float2(0, 0.42));
                float ant = sdSeg(q, float2(0.02, 0.45), float2(0.22, 0.82));
                return min(min(upper, lower), min(body, ant));
            }
        }
    }

    /// A lit sign's light: the tube's hot core and its glow, box-filtered by the footprint `fp` (in the sign's own units),
    /// so a tube smaller than a pixel dims and spreads instead of breaking up.
    float3 neonTube(float dist, float tube, float fp, float3 colour, float level) {
        float w2 = tube * tube + fp * fp;
        float energy = tube * tube / w2;
        float core = exp(-dist * dist / w2) * energy;
        float halo = exp(-dist / (tube * 3.5 + fp)) * 0.3 + exp(-dist / (tube * 7.0 + fp)) * 0.035;
        float3 hot = mix(colour, float3(1.0), 0.18);
        return (hot * core * 3.4 + colour * halo) * level;
    }

    // ---------------------------------------------------------------- facades
    /// A facade's light at (u along it, v up it from the ground; metres) of building `seed`, `height` tall, the pixel's
    /// footprint `fu` × `fv` (m), `near` 1 for the rows beside the road (dimmer, mostly dark): offices light whole floors in
    /// runs (cool or neutral white behind dark mullions), homes window by window (warm, now and then a television's blue),
    /// each window brighter under its ceiling; far off, the grid averages to its lit share. By day its glass reflects the sky.
    float3 facade(float u, float v, float height, float seed, float fu, float fv, float near, float cosI, constant DriveU& u0) {
        float night = u0.move.w;
        float h1 = hash11(seed * 13.7 + 1.3), h2 = hash11(seed * 7.1 + 4.1), h3 = hash11(seed * 3.3 + 9.7);
        float h4 = hash11(seed * 5.9 + 2.2), h5 = hash11(seed * 11.3 + 6.6);
        bool glass = h4 < 0.5;
        float floorH = glass ? 3.8 + 0.6 * h1 : 2.9 + 0.5 * h1;
        float colW = glass ? 1.5 + 0.6 * h2 : 1.8 + 1.4 * h2;
        float winW = glass ? 0.93 : 0.42 + 0.22 * h3;
        float winH = glass ? 0.84 : 0.46 + 0.18 * h5;
        float litShare = (glass ? 0.06 + 0.2 * h3 : 0.05 + 0.2 * h3) * (1.0 - 0.5 * near) * night * u0.neon.z;
        float cu = pulseTrain(u + colW * (1.0 - winW) * 0.5, colW, colW * winW, fu);
        float cv = pulseTrain(v + floorH * (1.0 - winH) * 0.5, floorH, floorH * winH, fv);
        float cover = cu * cv;
        float col = floor(u / colW), fl = floor(v / floorH);
        float lit;
        float3 wc;
        float bright;
        if (glass) {
            float floorLit = hash12(float2(fl * 1.3 + seed, seed * 31.0 + floor(col / 7.0)));
            lit = step(floorLit, litShare * 1.4) * step(hash12(float2(col * 1.7 + seed, fl * 3.1)), 0.88);
            float tint = hash12(float2(fl * 0.7 + seed, floor(col / 7.0)));
            wc = h5 < 0.7 ? (tint < 0.6 ? float3(0.74, 0.9, 1.0) : float3(0.95, 0.96, 0.9)) : float3(1.0, 0.84, 0.62);
            // Desks and partitions break the floor's light up; its ceiling panels are the brightest.
            bright = (0.48 + 0.5 * hash12(float2(fl, seed))) * (0.3 + 1.2 * hash12(float2(floor(u / 0.9), fl + seed)));
        } else {
            float winLit = hash12(float2(col * 1.7 + seed * 5.0, fl * 3.1 + seed));
            lit = step(winLit, litShare);
            float temp = hash12(float2(col + seed, fl * 0.37));
            wc = temp < 0.08 ? float3(0.55, 0.7, 1.0) : mix(float3(1.0, 0.5, 0.18), float3(1.0, 0.72, 0.42), temp);
            bright = 0.35 + 0.7 * hash12(float2(col * 3.3 + seed, fl));
        }
        // Under its ceiling a window is brighter (the room's lights), towards its sill darker.
        float vin = clamp((fract((v + floorH * (1.0 - winH) * 0.5) / floorH) * floorH) / (floorH * winH), 0.0, 1.0);
        // An office's ceiling panels in rows; below them, the desks' dark shapes against the far wall's light.
        float panels = glass ? smoothstep(0.84, 0.93, vin) * step(fract(u / 1.2 + seed), 0.55) : 0.0;
        float desks = glass ? 1.0 - 0.55 * step(vin, 0.32) * step(0.4, hash12(float2(floor(u / 1.6), fl * 1.9 + seed))) : 1.0;
        float inner = glass ? (0.5 + 0.45 * vin) * desks + 2.2 * panels : 0.7 + 0.55 * vin;
        // Recessed windows hide behind their reveals when seen at a grazing angle; flush glass mirrors instead.
        float reveal = glass ? 0.35 + 0.65 * smoothstep(0.02, 0.4, cosI) : smoothstep(0.04, 0.45, cosI);
        float3 sharp = wc * (lit * bright * inner);
        float far = smoothstep(0.45, 1.5, max(fu / colW, fv / floorH));
        float3 avgCol = (glass ? (h5 < 0.7 ? float3(0.78, 0.9, 1.0) : float3(1.0, 0.84, 0.62)) * 0.41 * 1.4
                               : float3(1.0, 0.6, 0.3) * 0.7) * litShare;
        float3 windowLight = mix(sharp * cover, avgCol * (winW * winH), far) * reveal;
        // The wall: dark concrete, or dark glass catching the city's glow (more of it higher up); by day, the sky's light.
        float up = saturate(v / max(height, 1.0));
        float3 wall = glass ? float3(0.03, 0.035, 0.045) * (0.6 + 0.8 * up) : float3(0.045, 0.042, 0.04) * (0.6 + 0.6 * h1);
        float3 dayWall = (glass ? float3(0.12, 0.13, 0.15) : float3(0.2, 0.19, 0.18)) * u0.amb.rgb * 8.0;
        float3 nightWall = wall * (u0.haze.rgb * 2.2 + u0.glow.rgb * u0.glow.w * 0.6 * (glass ? up : 0.2) + float3(0.002));
        float3 base = mix(dayWall, nightWall, night) * (1.0 - 0.6 * cover * (1.0 - far));
        // The street's light washing the lowest floors; a lit crown on some towers.
        float pools = 0.35 + 0.65 * sq(0.5 + 0.5 * cos(u * 0.157 + seed * 6.0));
        float wash = exp(-max(v - 3.0, 0.0) / 7.0) * 0.016 * pools * night * (1.0 - near);
        // Tall towers' crowns are washed by uplights: cones of light fanning up from a ledge, brightest at their feet.
        float crownOn = step(0.62, h2) * step(45.0, height) * night * u0.neon.z * (1.0 - 0.6 * near);
        float cz = v - (height - 9.0);
        float crownV = step(0.0, cz) * step(v, height) * exp(-max(cz, 0.0) / 5.0);
        float spacing = 3.2;
        float across = (fract(u / spacing) - 0.5) * spacing;
        float spread = 0.35 + 0.22 * max(cz, 0.0);
        float cone = exp(-across * across / (spread * spread)) * (0.35 / spread + 0.15);
        float coneAvg = 0.2 + 0.05 * spread;
        cone = mix(cone, coneAvg, smoothstep(0.5, 1.5, fu / spacing));
        float3 crown = mix(float3(1.0, 0.72, 0.45), float3(0.65, 0.82, 1.0), step(0.75, h1)) * (0.22 * crownOn * crownV * cone);
        return base + windowLight * 0.95 + float3(1.0, 0.8, 0.6) * wash + crown;
    }

    /// A neon sign on a building: `mode` 0 stands on its roof against the sky, 1 is a tall banner on its wall, 2 a framed
    /// panel. `uv` is across the facade (m from its left edge) and up it (m from the ground). Lit in the chord's colour (or
    /// an accent), pulsed by its note `slot`, fired by the Drop's wave as it runs out along the skyline (`screenX`, −1…1).
    /// `cover` is how much it hides the facade behind it (its panel), or for a roof sign how much of the sky its tube hides.
    float3 neonSign(float2 uv, float width, float height, int mode, int slot, float seed, float fp, float screenX, bool hero,
                    constant DriveU& u, thread float& cover) {
        cover = 0.0;
        float night = u.move.w;
        float w, h;
        float2 c;
        if (mode == 0) {
            w = min(width * 0.8, 34.0);
            h = w * (0.42 + 0.25 * hash11(seed * 4.4));
            c = float2(width * 0.5, height + h * 0.5 + 1.5);
        } else if (mode == 1) {
            w = clamp(width * 0.24, 5.0, 12.0);
            h = w * 3.3;
            c = float2(width * (hash11(seed * 8.8) < 0.5 ? 0.16 : 0.84), height * (0.5 + 0.3 * hash11(seed * 6.6)));
            c.y = min(c.y, height - h * 0.5 - 2.0);
        } else if (mode == 3) {
            w = width;
            h = height;
            c = float2(width * 0.5, height * 0.5);
        } else {
            w = clamp(width * 0.55, 10.0, 26.0);
            h = w * 0.7;
            c = float2(width * (0.3 + 0.4 * hash11(seed * 5.5)), height * (0.42 + 0.35 * hash11(seed * 7.7)));
            c.y = min(c.y, height - h * 0.5 - 2.0);
        }
        float2 q = (uv - c) / (0.5 * float2(w, h));
        if (abs(q.x) > 1.8 || abs(q.y) > 1.8) return float3(0);
        // Glyph space: square cells (a banner stacks three).
        float2 g;
        float cellM;
        if (mode == 1 || mode == 3) {
            float n = mode == 1 ? 3.0 : max(1.0, round(h / w * 0.9));
            g = float2(q.x * 1.15, (fract((q.y + 1.0) * 0.5 * n) - 0.5) * 2.0 * (h / n) / w * 1.15);
            cellM = min(w, h / n);
        } else {
            g = float2(q.x * w / h, q.y);
            cellM = h;
        }
        // Banners repeat a round ornament down their length (stacked shapes that could read as writing are never used
        // there); panels and roof signs take any glyph.
        int kind;
        if (mode == 1 || mode == 3) {
            // The round glyphs 0, 2, 6, 8 and 5, chosen without an array (indexed at run time, a private array lives in
            // scratch memory on Intel and AMD GPUs).
            int ri = int(hash11(seed * 9.1 + 3.3) * 4.99);
            kind = ri == 0 ? 0 : (ri == 1 ? 2 : (ri == 2 ? 6 : (ri == 3 ? 8 : 5)));
        } else {
            kind = int(hash11(seed * 9.1 + 3.3) * 10.99);
        }
        if (fract(seed * 0.0137) < 0.012) kind = 11;   // now and then, the app's own butterfly
        float d = glyph(kind, g);
        float unitsPerM = 2.0 / cellM;
        float tube = 0.075;
        float f = fp * unitsPerM;
        int cslot = hash11(seed * 3.7) < 0.7 ? slot % 3 : 3 + slot % 3;
        float3 colour = neonColour(cslot, u);
        float pulse = u.signs[slot / 4][slot % 4];
        float wave = 0.0;
        if (u.wave.x >= 0.0) {
            float since = u.wave.x - abs(screenX) * 0.5 / 1.1;
            float rise = max(u.wave.w, 0.02);
            wave = since > 0.0 ? u.wave.y * (1.0 - exp(-since / rise)) * exp(-since / (0.3 + rise)) : 0.0;
        }
        float dead = (u.dead.x >= 0.0 && int(u.dead.x + 0.5) == slot && hero) ? u.dead.y : 1.0;
        float lit = hero ? 1.0 : step(hash11(seed * 2.9 + 5.1), 0.3 + 0.7 * u.neon.y);
        float base = lit * (0.25 + 0.75 * night) * (0.35 + 0.65 * u.neon.y) * u.neon.z;
        float level = (base + 2.6 * pulse + 4.0 * wave) * dead;
        float3 light = neonTube(d, tube, f, colour, level);
        if (mode >= 2) {
            float2 b = abs(q) - float2(0.97, 0.985);
            float frame = abs(length(max(b, 0.0)) + min(max(b.x, b.y), 0.0));
            int fslot = (cslot + 1) % 3;
            light += neonTube(frame * 0.9, tube * 0.8, f, neonColour(fslot, u), level * 0.6);
        }
        // The unlit tube's glass.
        light += colour * (0.015 * exp(-d * d / (tube * tube + f * f)));
        if (mode == 0) {
            cover = exp(-d * d / (tube * tube * 4.0 + f * f)) * 0.8;
        } else if (mode == 3) {
            cover = 1.0;
            light += float3(0.006, 0.006, 0.008);
        } else {
            cover = step(abs(q.x), 1.12) * step(abs(q.y), 1.1);
            light += float3(0.004, 0.004, 0.006) * cover;
        }
        return light;
    }

    // ---------------------------------------------------------------- the towers
    /// What a layer of the city gives a ray: the nearest opaque thing (t, colour) and the roof signs it passes (their light,
    /// at their distance).
    struct Tower { float t; float3 col; float3 add; float addT; };

    /// A row of buildings along the road (`side` −1 left, +1 right) with their facades facing it at `x` (m), in cells
    /// `cell` m long, `minH`…`maxH` tall from the street 12 m below the deck. A ray may hit a facade, pass over a roof
    /// (and its sign), or pass through a gap to the next building's end wall facing you. Along a bridge the row parts.
    Tower towerRow(float3 d, float x, float side, float cell, float minH, float maxH, float rowSeed, float zMin, float zMax,
                   constant DriveU& u, float pa) {
        Tower r;
        r.t = 1e9; r.col = float3(0); r.add = float3(0); r.addT = 1e9;
        if (d.x * side <= 1e-4 || d.z <= 1e-4) return r;
        float eye = u.road3.y;
        float ground = -12.0;
        float offset = u.move.x + rowSeed * 37.0;
        float close = u.play.w;
        float xr = x * (1.0 - 0.32 * close);
        float hScale = 1.0 + 0.4 * close;
        // Blade signs: panels standing out from the facades towards the road, their neon facing the traffic (and you).
        // The ray is within their reach only between where it comes within 7 m of the facade and where it meets it.
        {
            float sl = d.x / d.z;
            float zA = (xr - side * 7.0) / sl, zB = xr / sl;
            if (zA > max(zMin, 2.0) && zA < zMax) {
                float cA = floor((zA + offset) / cell);
                for (int k = 0; k < 2; k++) {
                    float cb = cA + float(k);
                    float seedB = cb * 0.731 + rowSeed * 17.0;
                    if (hash11(seedB * 2.7 + 0.4) > 0.24 + 0.3 * u.neon.y) continue;
                    float lenB = cell * (0.58 + 0.32 * hash11(cb * 0.71 + rowSeed * 3.0));
                    float startB = (cell - lenB) * 0.5;
                    float zBlade = cb * cell + startB + lenB * (0.15 + 0.5 * hash11(seedB * 5.3)) - offset;
                    if (zBlade < zA || zBlade > zB) continue;
                    float bz0 = cb * cell + startB - offset;
                    bool bParted = u.route.z < 1e4 && bz0 + lenB > u.route.z - 20.0 && bz0 < u.route.w + 20.0;
                    if (bParted && u.route2.x > 0.02) continue;
                    float tb = zBlade / d.z;
                    float xb = d.x * tb, yb = eye + d.y * tb;
                    float out = (xb - xr) * -side;
                    float hB = (minH + (maxH - minH) * sq(hash11(cb * 0.53 + rowSeed * 7.0))) * hScale;
                    float bw = 3.0 + 2.5 * hash11(seedB * 6.1);
                    float y0 = 3.0 + 6.0 * hash11(seedB * 8.9);
                    float y1 = min(y0 + bw * (2.4 + 2.2 * hash11(seedB * 3.9)), ground + hB - 3.0);
                    if (out >= 0.6 && out <= 0.6 + bw && yb >= y0 && yb <= y1) {
                        float cover = 0.0;
                        int slot = int(hash11(seedB * 1.3) * 47.99);
                        float2 uv = float2(out - 0.6, yb - y0);
                        float sx = clamp(sl * 0.8, -1.0, 1.0);
                        float3 sg = neonSign(uv, bw, y1 - y0, 3, slot, seedB + 0.77, tb * pa, sx, false, u, cover);
                        r.t = tb;
                        r.col = sg;
                        return r;
                    }
                }
            }
        }
        float t = xr / d.x;
        float z = d.z * t;
        if (z > zMax || z < zMin) return r;
        float zw = z + offset;
        float ci = floor(zw / cell);
        float local = zw - ci * cell;
        float len = cell * (0.58 + 0.32 * hash11(ci * 0.71 + rowSeed * 3.0));
        float start = (cell - len) * 0.5;
        float height = (minH + (maxH - minH) * sq(hash11(ci * 0.53 + rowSeed * 7.0))) * hScale;
        float y = eye + d.y * t;
        // Parted along a bridge: the buildings beside it slide away into the haze as the city opens.
        float bz0 = ci * cell + start - offset;
        bool parted = u.route.z < 1e4 && bz0 + len > u.route.z - 20.0 && bz0 < u.route.w + 20.0;
        float slide = parted ? u.route2.x : 0.0;
        float seed = ci * 0.731 + rowSeed * 17.0;
        bool hasSign = hash11(seed * 4.3) < 0.2 + 0.5 * u.neon.y;
        int mode = int(hash11(seed * 6.1) * 2.99);
        int slot = int(hash11(seed * 1.9) * 47.99);
        float sx = clamp(d.x / d.z * 0.8, -1.0, 1.0);
        if (slide < 0.99) {
            float fu = t * pa / max(abs(d.x), 0.03);
            float fv = t * pa;
            // A sign on the facade fades out as it turns edge-on (it would read as a sliver).
            float facing = smoothstep(0.1, 0.35, abs(d.x) / max(length(d), 1e-4));
            if (local >= start && local <= start + len && y >= ground && y <= ground + height) {
                float2 uv = float2(side < 0.0 ? local - start : start + len - local, y - ground);
                float3 c = facade(uv.x, uv.y, height, seed, fu, fv, 1.0, abs(d.x), u);
                if (hasSign && mode > 0 && facing > 0.0) {
                    float cover = 0.0;
                    float3 sg = neonSign(uv, len, height, mode, slot, seed, fu, sx, false, u, cover);
                    c = c * (1.0 - cover * facing) + sg * facing;
                }
                r.t = t * (1.0 + 6.0 * slide);
                r.col = c * (1.0 - slide);
                return r;
            }
            if (hasSign && mode == 0 && local >= start - 4.0 && local <= start + len + 4.0 && y > ground + height) {
                float cover = 0.0;
                float2 uv = float2(side < 0.0 ? local - start : start + len - local, y - ground);
                float3 sg = neonSign(uv, len, height, 0, slot, seed, fu, sx, false, u, cover);
                r.add = sg * ((1.0 - slide) * facing);
                r.addT = t;
            }
        }
        // Through a gap (or over a lower roof): the end wall facing you of this building (before it) or the next one.
        float cj = local < start ? ci : ci + 1.0;
        float lenJ = cell * (0.58 + 0.32 * hash11(cj * 0.71 + rowSeed * 3.0));
        float startJ = (cell - lenJ) * 0.5;
        float zEnd = cj * cell + startJ - offset;
        if (zEnd <= z || zEnd > zMax || zEnd < zMin) return r;
        float te = zEnd / d.z;
        float xe = d.x * te;
        float ye = eye + d.y * te;
        float hJ = (minH + (maxH - minH) * sq(hash11(cj * 0.53 + rowSeed * 7.0))) * hScale;
        float depthB = 26.0;
        float into = (xe - xr) * side;
        float b0 = cj * cell + startJ - offset;
        bool partedJ = u.route.z < 1e4 && b0 + lenJ > u.route.z - 20.0 && b0 < u.route.w + 20.0;
        float slideJ = partedJ ? u.route2.x : 0.0;
        if (into >= 0.0 && into <= depthB && ye >= ground && ye <= ground + hJ && slideJ < 0.99) {
            float seedJ = cj * 0.731 + rowSeed * 17.0 + 0.37;
            float fe = te * pa / max(abs(d.z), 0.03);
            float3 c = facade(into, ye - ground, hJ, seedJ, fe, te * pa, 1.0, abs(d.z), u);
            r.t = te * (1.0 + 6.0 * slideJ);
            r.col = c * (1.0 - slideJ) * 0.8;
        }
        return r;
    }

    /// A layer of the downtown ahead: facades facing you `zLayer` m ahead (fixed: a skyline kilometres off doesn't come
    /// closer in a song), `cell` m apart, the road's canyon open between `gap0` and `gap1` (m across). The tallest stand
    /// round the road's end. Layer 0 is the hero row: every building carries a wall sign and a roof sign whose slots walk
    /// across it in order, so each note lights a sign and a run sweeps the skyline.
    Tower downtown(float3 d, float zLayer, float cell, float minH, float maxH, float gap0, float gap1, float layer,
                   constant DriveU& u, float pa) {
        Tower r;
        r.t = 1e9; r.col = float3(0); r.add = float3(0); r.addT = 1e9;
        if (d.z <= 1e-4) return r;
        float eye = u.road3.y;
        float ground = -12.0;
        float close = u.play.w;
        float t = zLayer / d.z;
        float x = d.x * t;
        float y = eye + d.y * t;
        float ci = floor(x / cell);
        float local = x - ci * cell;
        float width = cell * (0.66 + 0.28 * hash11(ci * 0.91 + layer * 3.1));
        float start = (cell - width) * 0.5;
        float g0 = gap0 + close * 6.0, g1 = gap1 - close * 6.0;
        float bx0 = ci * cell + start, bx1 = bx0 + width;
        if (bx1 > g0 && bx0 < g1) return r;
        float tall = hash11(ci * 0.37 + layer * 5.3);
        float mid = ci * cell + cell * 0.5;
        float centre = exp(-sq(mid / (zLayer * 0.35)));
        float height = (minH + (maxH - minH) * min(1.0, 0.45 * tall * tall + 0.75 * centre * (0.5 + 0.5 * tall))) * (1.0 + 0.25 * close);
        float seed = ci * 1.37 + layer * 101.0;
        float fp = t * pa;
        float sx = clamp(d.x / d.z / max(u.a.x * 0.42, 0.1), -1.0, 1.0);
        bool hero = layer < 0.5;
        int wallSlot = int(fmod(ci * 2.0 + 1.0 + 480.0, 48.0));
        int roofSlot = int(fmod(ci * 2.0 + 480.0, 48.0));
        if (!hero) { wallSlot = int(hash11(seed * 1.9) * 47.99); roofSlot = int(hash11(seed * 2.3) * 47.99); }
        bool wallSign = hero || hash11(seed * 4.3) < 0.15 + 0.45 * u.neon.y;
        // Its silhouette: flat, stepped back near the top, a spire, a slanted crown, or twin towers.
        float lx = (local - start) / width;
        int shape = int(hash11(seed * 8.3 + 1.1) * 4.99);
        float topH = height;
        if (shape == 1) topH = abs(lx - 0.5) < 0.3 ? height : height * 0.87;
        else if (shape == 2) topH = abs(lx - 0.5) < 0.035 ? height * 1.17 : height;
        else if (shape == 3) topH = height * (0.84 + 0.16 * (hash11(seed * 2.2) < 0.5 ? lx : 1.0 - lx));
        else if (shape == 4) topH = abs(lx - 0.5) < 0.08 ? height * 0.74 : height;
        bool roofSign = (hero || hash11(seed * 5.7) < 0.1 + 0.35 * u.neon.y) && shape != 2;
        if (local >= start && local <= start + width && y >= ground && y <= ground + topH) {
            float2 uv = float2(local - start, y - ground);
            float3 c = facade(uv.x, uv.y, topH, seed, fp, fp, 0.0, d.z, u);
            if (wallSign) {
                float cover = 0.0;
                int mode = 1 + int(hash11(seed * 6.1) * 1.99);
                float3 sg = neonSign(uv, width, height, mode, wallSlot, seed + 0.5, fp, sx, hero, u, cover);
                c = c * (1.0 - cover) + sg;
            }
            r.t = t;
            r.col = c;
            return r;
        }
        if (roofSign && local >= start - 4.0 && local <= start + width + 4.0 && y > ground + topH) {
            float cover = 0.0;
            float3 sg = neonSign(float2(local - start, y - ground), width, height, 0, roofSlot, seed + 0.25, fp, sx, hero, u, cover);
            r.add = sg;
            r.addT = t;
        }
        return r;
    }

    // ---------------------------------------------------------------- lights along the road
    /// The street lights: a row along the left parapet, a double row along the median, every `spacing` m. Returns the
    /// world z of the lamp head nearest to where the ray passes the row's line (x, y), and the ray's angular distance to it.
    float lampNearest(float3 d, float x, float y, float spacing, float phase, float dist, float eye, thread float3& lamp) {
        float2 cs = float2(d.x, d.y);
        float t = (d.x * x + d.y * (y - eye)) / max(dot(cs, cs), 1e-6);
        float z = d.z * max(t, 0.0);
        float k = round((z + dist - phase) / spacing);
        float zl = k * spacing + phase - dist;
        lamp = float3(x, y - eye, zl);
        return zl;
    }

    /// A street light seen along `d`: its head (a lens under its housing, with a shape near and a point of the same light
    /// far off), a tight glow round the lens, and its halo in the rain (no wider than a few degrees however near the lamp).
    float3 lampGlow(float3 d, float3 v, float tHit, float strength, float3 colour, float rain, float pa) {
        float dist = length(v);
        if (dist > tHit || v.z < 1.0) return float3(0);
        float3 o = d * dot(d, v) - v;
        float off = length(o);
        float fw = dist * pa;
        float r = min(2.2 + 3.5 * rain, dist * 0.03);
        float halo = exp(-off / r) * (0.03 + 0.07 * rain) + exp(-off / min(r * 4.0, dist * 0.2)) * 0.0035;
        // (The lens and the tight glow round it add under a millionth of the light farther than 4.5 m from the lens
        // (and 4.4 widths of its blur, far off): there only the halo is read. Most of the view, for most lamps.)
        if (off * off > max(20.25, 19.4 * (0.09 + fw * fw))) return colour * strength * halo;
        float3 h = float3(d.z, 0.0, -d.x) / max(length(d.xz), 1e-4);
        float3 w = cross(d, h);
        float ox = dot(o, h), oy = dot(o, w);
        // The lens: 0.6 m across, as tall as it shows from here (more of its underside as you near it).
        float hw = 0.3;
        float hh = 0.14 * saturate(v.y / dist) + 0.05;
        float sx2 = hw * hw + fw * fw, sy2 = hh * hh + fw * fw;
        float soft = fw / hh;
        float point = exp(-ox * ox / sx2 - oy * oy / sy2) * (hw * hh / sqrt(sx2 * sy2)) * (1.0 + 2.0 * smoothstep(0.5, 3.0, soft));
        float er = length(float2(ox / hw, oy / hh));
        float crisp = (1.0 - smoothstep(1.0 - soft, 1.0 + soft, er)) * (1.0 + 0.5 * exp(-er * er * 3.0));
        float core = mix(point, crisp, smoothstep(0.7, 0.3, soft)) * 6.0;
        float edgeOff = max(off - hw, 0.0);
        float tight = exp(-edgeOff / min(0.3, dist * 0.006)) * 0.1;
        return colour * strength * (core + tight + halo);
    }

    /// A light's mirror on the wet road at `p`, seen along `d`: a streak below its mirror image, narrow sideways and long
    /// towards you (the rain-roughened water stretches it), sharper in the tyre tracks.
    float roadStreak(float3 p, float3 d, float3 light, float rough) {
        float3 toL = light - p;
        float hd = length(toL.xz);
        if (hd < 0.5 || toL.y <= 0.0) return 0.0;
        float2 dh = normalize(d.xz);
        float2 lh = toL.xz / hd;
        float daz = dh.x * lh.y - dh.y * lh.x;
        if (dot(dh, lh) < 0.0) return 0.0;
        float sa = 0.005 + 0.012 * rough;
        // (More than six of its widths to the side the streak is under e^-36 of its light: not read.)
        if (abs(daz) > 6.0 * sa) return 0.0;
        float elL = toL.y / hd;
        float elR = -d.y / max(length(d.xz), 1e-4);
        float se = 0.04 + 0.32 * rough;
        float del = elL - elR;
        float lobe = exp(-daz * daz / (sa * sa) - del * del / (se * se));
        float fall = 1.0 / (1.0 + 0.0008 * hd * hd);
        return lobe * fall;
    }

    float boxCover(float x, float a, float b, float w) {
        float ww = max(w, 1e-4);
        return clamp((min(x + 0.5 * ww, b) - max(x - 0.5 * ww, a)) / ww, 0.0, 1.0);
    }
    float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    /// The lamp rows: the left parapet's heads reach 2.4 m over the road; the median's double arms reach both ways.
    float3 lampRowX(int row, constant DriveU& u) {
        if (row == 0) return float3(u.road1.x + 2.4, 0.0, 0.0);       // x of the heads, phase, 0
        if (row == 1) return float3(u.road1.z + 0.3 - 2.4, 20.0, 0.0);
        return float3(u.road1.w - 0.3 + 2.4, 20.0, 0.0);
    }
    constant float kLampSpacing = 40.0;
    constant float kLampHeight = 9.6;
    constant float3 kLampColour = float3(1.0, 0.84, 0.64);

    // ---------------------------------------------------------------- the road
    /// The deck at `p` seen along `d` from `t` away: wet asphalt, its paint and studs, lit by your headlights and the
    /// street lights, the street lights' and the traffic's mirror streaks, the arp's pulses racing down the studs.
    float3 shadeRoad(float3 p, float3 d, float t, constant DriveU& u, float pa, bool inTunnel) {
        float dist = u.move.x;
        float zw = p.z + dist;
        float fx = t * pa;
        float fz = t * pa / max(-d.y, 1e-3);
        float wet = inTunnel ? 0.1 : u.rain.z;
        int oct = int(u.a.z + 0.5);
        float grainVis = 1.0 - smoothstep(0.03, 0.25, max(fx, fz * 0.3));
        float grain = vn2(float2(p.x * 4.1, zw * 4.1)) * grainVis + 0.5 * (1.0 - grainVis);
        float puddle = smoothstep(0.56, 0.74, fbm2(float2(p.x * 0.21, zw * 0.07), oct)) * wet;
        float lw = u.road2.w;
        float track = 0.0;
        for (int i = 0; i < 4; i++) {
            float lc = u.road3.x + lw * float(i - 1);
            float a = abs(p.x - lc);
            track = max(track, exp(-sq((a - 0.85) / 0.35)));
        }
        float rough = clamp(0.75 - 0.35 * track - 0.45 * puddle, 0.12, 1.0);
        float3 albedo = float3(0.045, 0.045, 0.05) * (0.8 + 0.4 * grain) * (1.0 - 0.5 * wet) * (1.0 - 0.5 * puddle);
        // Paint: the edge lines and the dashed lane lines, your way and theirs.
        // (A line's dashes are read only where the pixel is on its line.)
        float paint = 0.0;
        float le = u.road1.y;
        for (int i = 0; i <= 4; i++) {
            float xl = le + lw * float(i);
            float across = boxCover(p.x, xl - 0.07, xl + 0.07, fx);
            if (across <= 0.0) continue;
            float dash = (i == 0 || i == 4) ? 1.0 : pulseTrain(zw, 12.0, 3.0, fz);
            paint = max(paint, across * dash);
        }
        float of0 = u.road1.w + 0.6;
        for (int i = 0; i <= 3; i++) {
            float xl = of0 + lw * float(i);
            float across = boxCover(p.x, xl - 0.07, xl + 0.07, fx);
            if (across <= 0.0) continue;
            float dash = (i == 0 || i == 3) ? 1.0 : pulseTrain(zw + 6.0, 12.0, 3.0, fz);
            paint = max(paint, across * dash);
        }
        // Your headlights: low beams pooling on the road from a few metres out, falling off past 40 m.
        float beam = smoothstep(2.0, 7.0, p.z) * exp(-sq((p.x - u.road3.x) / (1.4 + 0.17 * p.z))) / (1.0 + sq(p.z / 24.0));
        float3 head = float3(1.0, 0.9, 0.76) * beam * 1.4;
        // The street lights' pools (the two nearest of each row).
        float3 pools = float3(0);
        for (int row = 0; row < 3; row++) {
            float3 rx = lampRowX(row, u);
            float k = round((zw - rx.y) / kLampSpacing);
            for (int j = -1; j <= 1; j++) {
                float zl = (k + float(j)) * kLampSpacing + rx.y - dist;
                float3 v = float3(rx.x, kLampHeight, zl) - p;
                float r2 = dot(v, v);
                pools += kLampColour * (kLampHeight / (r2 * sqrt(r2))) * 70.0;
            }
        }
        if (inTunnel) pools *= 0.0;
        float3 light = u.amb.rgb * 0.6 + u.haze.rgb * 0.5 + head + pools * u.neon.z;
        float3 col = albedo * light;
        float3 paintCol = float3(0.42, 0.42, 0.4) * (light + head * 0.8) * (1.0 - 0.45 * wet);
        col = mix(col, paintCol, paint * 0.85);
        // Studs along the lines: glinting back in your headlights; the arp's pulses racing down them.
        float studLight = 0.0;
        float pulseSum = 0.0;
        float studZ = zw - (round((zw - 7.5) / 12.0) * 12.0 + 7.5);
        float r2 = 0.0025;
        float wx = r2 + fx * fx, wz = r2 + fz * fz;
        float studNorm = r2 / sqrt(wx * wz);
        float studAlong = studZ * studZ / wz;
        for (int i = 0; i <= 4; i++) {
            float xl = le + lw * float(i);
            float dx = p.x - xl;
            float g = exp(-dx * dx / wx - studAlong) * studNorm;
            studLight = max(studLight, g);
        }
        if (studLight > 1e-4) {
            for (int k = 0; k < 16; k++) {
                float4 s = u.studs[k];
                if (s.x <= 0.0) continue;
                pulseSum += s.y * exp(-sq((p.z - s.x) / 3.2));
            }
            float headOnStud = smoothstep(2.0, 6.0, p.z) / (1.0 + sq(p.z / 55.0));
            float3 white = float3(1.0, 0.95, 0.85) * headOnStud * 3.0;
            float3 pulse = mix(u.pal[0].rgb, u.pal[1].rgb, 0.5) * pulseSum * 60.0;
            col += studLight * (white + pulse);
        }
        // Mirror streaks of the street lights (the ones the reflected ray lines up with), and the traffic's lights.
        float F = fresnelWet(-d.y) * (0.35 + 0.65 * wet) * (1.0 + 1.2 * puddle);
        float3 spec = float3(0);
        float2 dh = normalize(d.xz);
        if (!inTunnel) {
            for (int row = 0; row < 3; row++) {
                float3 rx = lampRowX(row, u);
                if (abs(dh.x) < 1e-4) continue;
                float s = (rx.x - p.x) / dh.x;
                if (s <= 0.0) continue;
                float za = p.z + s * dh.y;
                float k = round((za + dist - rx.y) / kLampSpacing);
                for (int j = -1; j <= 1; j++) {
                    float zl = (k + float(j)) * kLampSpacing + rx.y - dist;
                    spec += kLampColour * roadStreak(p, d, float3(rx.x, kLampHeight, zl), rough) * 3.2;
                }
            }
        }
        for (int c = 0; c < 12; c++) {
            float4 a = u.cars[c * 2];
            if (a.y < -1e4 || a.y < p.z - 2.0 || a.y > 420.0) continue;
            float oncoming = a.z;
            float3 lc = oncoming > 0.5 ? float3(0.85, 0.9, 1.0) * 10.0 : float3(1.0, 0.05, 0.02) * (2.4 + 4.0 * a.w);
            float ly = oncoming > 0.5 ? 0.65 : 0.85;
            spec += lc * roadStreak(p, d, float3(a.x, ly, a.y), rough * 1.4) * 1.1;
        }
        // Rain ringing the puddles: tiny rings that come and go (they average away into a sheen far off).
        float ripple = 0.0;
        if (!inTunnel && u.rain.x > 0.02) {
            float2 cell = floor(float2(p.x, zw) / 0.45);
            float2 f = fract(float2(p.x, zw) / 0.45) - 0.5;
            float h = hash12(cell);
            float ph = fract(u.a.y * 1.6 + h);
            float2 o = float2(hash12(cell + 3.1), hash12(cell + 7.7)) - 0.5;
            float rr = length(f - o * 0.5) * 0.45;
            float ring = exp(-sq((rr - ph * 0.12) / 0.006)) * (1.0 - ph) * step(h, u.rain.x * 0.6);
            float near = 1.0 - smoothstep(0.004, 0.02, max(fx, fz * 0.1));
            ripple = ring * near * 0.15 + 0.01 * u.rain.x;
        }
        col += spec * F + u.glow.rgb * (ripple * 0.6 * u.move.w);
        return col;
    }

    // ---------------------------------------------------------------- the traffic
    /// A car's face (its rear your way, its front the other way) where the ray meets its plane, if it does: its colour and
    /// its coverage (antialiased by the footprint `fp`, m).
    float4 shadeCar(float2 l, float4 a, float4 b, float fp, constant DriveU& u) {
        bool oncoming = a.z > 0.5;
        float body = sdRoundBox(l - float2(0.0, 0.56), float2(0.9, 0.38), 0.14);
        float slant = 1.0 + 0.4 * clamp((l.y - 0.92) / 0.5, 0.0, 1.0);
        float cabin = sdRoundBox(float2(l.x * slant, l.y - 1.16), float2(0.7, 0.26), 0.16);
        float wheels = sdRoundBox(float2(abs(l.x) - 0.68, l.y - 0.2), float2(0.16, 0.2), 0.05);
        float sil = min(min(body, cabin), wheels);
        float cover = smoothstep(fp, -fp, sil);
        if (cover <= 0.0) return float4(0);
        float seed = b.x;
        // Its paint, one of six chosen without an array (a private array indexed at run time lives in scratch memory on
        // Intel and AMD GPUs).
        int paintIndex = int(seed * 5.99);
        float3 paint = paintIndex == 0 ? float3(0.02, 0.02, 0.022) : (paintIndex == 1 ? float3(0.06, 0.065, 0.07)
                     : (paintIndex == 2 ? float3(0.18, 0.19, 0.2) : (paintIndex == 3 ? float3(0.12, 0.02, 0.025)
                     : (paintIndex == 4 ? float3(0.02, 0.03, 0.07) : float3(0.28, 0.28, 0.27)))));
        float3 ambient = u.amb.rgb * 0.8 + u.haze.rgb * 0.9;
        float3 col = paint * ambient;
        // A highlight along the boot's edge and the roof from the lamps overhead.
        float edge = exp(-sq((l.y - 0.93) / 0.03)) + 0.6 * exp(-sq((l.y - 1.41) / 0.025));
        col += kLampColour * edge * 0.05 * (0.4 + paint.r * 3.0);
        // Glass: the rear (or front) window, dark, catching the city's glow.
        float glass = smoothstep(0.02, -0.02, sdRoundBox(float2(l.x * slant, l.y - 1.15), float2(0.6, 0.19), 0.1));
        col = mix(col, u.haze.rgb * 0.6 + float3(0.004), glass);
        float3 light = float3(0);
        if (!oncoming) {
            float tl = smoothstep(0.02, -0.01, sdRoundBox(float2(abs(l.x) - 0.7, l.y - 0.84), float2(0.17, 0.045), 0.03));
            float barAcross = step(0.5, fract(seed * 7.0)) * smoothstep(0.012, 0.0, abs(l.y - 0.84)) * step(abs(l.x), 0.75);
            float brake = a.w;
            light += float3(1.0, 0.04, 0.02) * (tl * (3.0 + 7.0 * brake) + barAcross * 1.6);
            light += float3(1.0, 0.03, 0.02) * smoothstep(0.02, 0.0, sdRoundBox(l - float2(0.0, 1.36), float2(0.12, 0.012), 0.01)) * 6.0 * brake;
            // The number plate's lamp: a plain lit panel (no characters).
            float plate = smoothstep(0.01, -0.01, sdRoundBox(l - float2(0.0, 0.42), float2(0.25, 0.06), 0.01));
            col = mix(col, float3(0.09, 0.09, 0.085), plate);
            // The surprise's abstract light bar: a slow ribbon of colour along the roof, never a flashing beacon.
            if (b.y > 0.5) {
                float bar = smoothstep(0.02, 0.0, sdRoundBox(l - float2(0.0, 1.5), float2(0.62, 0.05), 0.04));
                float s = 0.5 + 0.5 * sin(l.x * 2.6 - u.a.y * 0.9);
                float3 rib = mix(u.pal[0].rgb, u.pal[2].rgb, s);
                light += rib * bar * 5.0;
                cover = max(cover, bar);
            }
        } else {
            float hl = smoothstep(0.02, -0.01, sdRoundBox(float2(abs(l.x) - 0.64, l.y - 0.64), float2(0.17, 0.07), 0.05));
            float drl = smoothstep(0.012, 0.0, abs(l.y - 0.74)) * step(0.45, abs(l.x)) * step(abs(l.x), 0.82);
            light += float3(0.86, 0.92, 1.0) * (hl * 14.0 + drl * 3.0);
        }
        return float4(col + light, cover);
    }

    /// A car's lights glowing in the rainy air: red taillights and the spray behind its wheels, or white headlights; each
    /// a point at least a pixel wide with a halo some tens of centimetres round it.
    float3 carGlow(float3 d, float4 a, float4 cone, float tHit, float eye, float rain, float pa) {
        if (a.y < -1e4 || a.y < 1.0) return float3(0);
        bool oncoming = a.z > 0.5;
        // (Its lights and its spray all stand within 1.6 m of the cone's axis point, and none adds a millionth of its
        // light farther than 18 m from where the ray passes it (12 m for a taillight or the spray): a ray outside its
        // cone (19.6 m, 13.6 m) reads none of them. Most cars, for most of the view.)
        if (abs(dot(d, cone.xyz)) < cone.w) return float3(0);
        float3 glow = float3(0);
        for (int s = -1; s <= 1; s += 2) {
            float3 v = float3(a.x + float(s) * (oncoming ? 0.64 : 0.7), (oncoming ? 0.64 : 0.84) - eye, a.y);
            float dist = length(v);
            if (dist > tHit + 0.5) continue;
            float c = dot(d, v) / dist;
            float off = sqrt(max(1.0 - c * c, 0.0)) * dist;
            float pix = pa * dist;
            if (oncoming) {
                float core = exp(-off * off / (0.01 + pix * pix)) * 0.01 / (0.01 + pix * pix);
                glow += float3(0.85, 0.9, 1.0) * (core * 6.0 + exp(-off / (0.5 + 0.8 * rain)) * (0.25 + 0.4 * rain));
            } else {
                float brake = a.w;
                float core = exp(-off * off / (0.006 + pix * pix)) * 0.006 / (0.006 + pix * pix);
                glow += float3(1.0, 0.05, 0.02) * (core * 1.2 + exp(-off / (0.35 + 0.5 * rain)) * (0.08 + 0.12 * rain)) * (1.0 + 1.8 * brake);
            }
        }
        if (!oncoming && rain > 0.05) {
            float3 v = float3(a.x, 0.45 - eye, a.y + 1.5);
            float dist = length(v);
            if (dist < tHit + 2.0) {
                float c = dot(d, v) / dist;
                float off = sqrt(max(1.0 - c * c, 0.0)) * dist;
                glow += float3(0.45, 0.03, 0.02) * exp(-off / 1.1) * rain * 0.12;
            }
        }
        return glow;
    }

    // ---------------------------------------------------------------- the tunnel
    constant float kTunnelCeiling = 6.2;
    /// The tunnel's interior at a hit: tiled walls, a dark ceiling with its row of orange lights, the dry road; `kind` 1
    /// left wall, 2 right wall, 3 ceiling, 4 road.
    float3 shadeTunnel(float3 p, float3 d, float t, int kind, constant DriveU& u, float pa) {
        float spacing = max(u.route2.y, 4.0);
        float zw = p.z + u.move.x;
        float zl0 = p.z + u.route2.z;
        float k = round(zl0 / spacing);
        float3 E = float3(0);
        float3 lampC = float3(1.0, 0.5, 0.14);
        for (int j = -1; j <= 1; j++) {
            float zl = (k + float(j)) * spacing - u.route2.z;
            float3 v = float3(1.6, kTunnelCeiling - 0.15, zl) - p;
            float r2 = dot(v, v);
            E += lampC * (14.0 / (r2 + 1.0));
        }
        float3 col;
        if (kind == 3) {
            float fx = t * pa, fz = t * pa / max(d.y, 1e-3);
            float zl = zl0 - k * spacing;
            float fix = boxCover(p.x, 1.35, 1.85, fx) * boxCover(zl, -1.2, 1.2, fz);
            col = float3(0.03, 0.03, 0.032) * E + lampC * fix * 9.0;
        } else if (kind == 4) {
            col = shadeRoad(p, d, t, u, pa, true) + float3(0.03, 0.03, 0.03) * E;
            float2 dh = normalize(d.xz);
            float s = abs(dh.x) > 1e-4 ? (1.6 - p.x) / dh.x : 1e9;
            if (s > 0.0 && s < 1e8) {
                float za = p.z + s * dh.y;
                float kk = round((za + u.route2.z) / spacing);
                for (int j = -1; j <= 1; j++) {
                    float zl = (kk + float(j)) * spacing - u.route2.z;
                    col += lampC * roadStreak(p, d, float3(1.6, kTunnelCeiling - 0.15, zl), 0.9) * 3.0 * fresnelWet(-d.y);
                }
            }
        } else {
            float fu = t * pa / max(abs(d.x), 0.03), fv = t * pa;
            float tiles = pulseTrain(zw, 0.6, 0.57, fu) * pulseTrain(p.y, 0.3, 0.28, fv);
            float3 tile = mix(float3(0.06), float3(0.3, 0.3, 0.28), tiles);
            float tray = boxCover(p.y, 4.6, 4.9, fv);
            col = mix(tile, float3(0.02), tray) * E;
            col *= smoothstep(0.0, 0.6, p.y) * 0.5 + 0.5;
            // The glazed tiles mirror the lamps going by: soft highlights sliding along the wall (not on the grout).
            float3 n = float3(p.x > 0.0 ? -1.0 : 1.0, 0.0, 0.0);
            float3 R = d - 2.0 * dot(d, n) * n;
            float3 spec = float3(0);
            // The lamps the mirrored ray passes: where it crosses their line.
            float tr = abs(R.x) > 1e-4 ? (1.6 - p.x) / R.x : 0.0;
            float kr = round((p.z + R.z * max(tr, 0.0) + u.route2.z) / spacing);
            for (int j = -1; j <= 1; j++) {
                float zl = (kr + float(j)) * spacing - u.route2.z;
                float3 L = normalize(float3(1.6, kTunnelCeiling - 0.15, zl) - p);
                spec += lampC * exp(-(1.0 - dot(R, L)) / 0.004);
            }
            col += spec * 0.38 * tiles * (1.0 - tray);
        }
        return col;
    }

    // ---------------------------------------------------------------- the street below and the harbour
    float3 shadeGround(float3 p, float t, constant DriveU& u, float pa) {
        float2 g = float2(p.x, p.z + u.move.x) / 28.0;
        float2 cell = floor(g);
        float2 f = fract(g) - 0.5;
        float h = hash12(cell);
        float fp = t * pa / 28.0;
        float r2 = 0.0004 + fp * fp;
        float dot2 = exp(-dot(f, f) / r2) * 0.0004 / r2;
        float3 lampC = mix(float3(1.0, 0.6, 0.3), float3(0.8, 0.85, 1.0), step(0.7, h));
        return float3(0.006, 0.006, 0.008) + lampC * dot2 * 3.0 * u.move.w;
    }

    // ---------------------------------------------------------------- the scene
    constant float kTunnelPortalTop = 15.0;

    fragment ColorDepth drive_scene_fragment(DriveOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                             constant DriveU& u [[buffer(1)]], texture2d<float> stars [[texture(0)]],
                                             texture2d<float> cell [[texture(9)]]) {
        float3 dE;
        float3 d = driveRay(in.ndc, sky, u, dE);
        float pa = u.a.w;
        float eye = u.road3.y;
        float lp = u.road1.x, mn = u.road1.z, mf = u.road1.w, fpx = u.road2.x, ph = u.road2.y, mh = u.road2.z;
        float rain = u.rain.x;
        float tHit = 1e9;
        float3 col = float3(0);
        float3 add = float3(0);
        int kind = 0;
        float zMin = 0.0;
        float bs = u.route.z, be = u.route.w;
        bool bridge = bs < 1e4;
        float railT = 1e9, railCov = 0.0;
        float3 railCol = float3(0);
        // (The timing test's mask: a set bit skips a layer, so one run can price each. Always 0 in the app.)
        uint skip = uint(u.road3.w + 0.5);

        // The tunnel: its interior (from inside, or through its mouth ahead), its portal's face.
        float ts = u.route.x, te = u.route.y;
        float wallL = lp - 0.4, wallR = mn;
        if (ts < 1e4 && te > 0.0) {
            float tp = ts > 0.0 ? ts / max(d.z, 1e-5) : 0.0;
            float3 at = float3(d.x * tp, eye + d.y * tp, d.z * tp);
            bool enters = ts <= 0.0 || (d.z > 0.0 && at.x > wallL && at.x < wallR && at.y > 0.0 && at.y < kTunnelCeiling);
            if (enters) {
                float tb = 1e9;
                int kb = 0;
                if (d.x < 0.0) { float tt = wallL / d.x; if (tt > tp && tt < tb) { tb = tt; kb = 1; } }
                if (d.x > 0.0) { float tt = wallR / d.x; if (tt > tp && tt < tb) { tb = tt; kb = 2; } }
                if (d.y > 0.0) { float tt = (kTunnelCeiling - eye) / d.y; if (tt > tp && tt < tb) { tb = tt; kb = 3; } }
                if (d.y < 0.0) { float tt = eye / -d.y; if (tt > tp && tt < tb) { tb = tt; kb = 4; } }
                float zb = d.z * tb;
                if (zb < te) {
                    float3 p = float3(d.x * tb, eye + d.y * tb, zb);
                    if (kb == 4) p.y = 0.0;
                    tHit = tb;
                    kind = 10;
                    col = shadeTunnel(p, d, tb, kb, u, pa);
                } else {
                    zMin = te;
                }
            } else if (ts > 0.0 && d.z > 0.0 && at.y < kTunnelPortalTop && at.y > -0.5 && abs(at.x - 1.6) < 50.0) {
                tHit = tp;
                kind = 11;
                float fp = tp * pa;
                float band = boxCover(at.y, kTunnelCeiling + 0.6, kTunnelCeiling + 1.4, fp);
                float lights = band * pulseTrain(at.x + 40.0, 3.0, 0.5, fp);
                float3 concrete = float3(0.05, 0.048, 0.046) * (0.6 + 0.4 * vn2(at.xy * 0.7));
                float3 lit = (u.amb.rgb + u.haze.rgb * 1.4) * 1.0 + kLampColour * 0.04 * exp(-max(at.y - 1.0, 0.0) / 6.0);
                col = concrete * lit + float3(1.0, 0.6, 0.3) * lights * 2.0;
            }
        }

        // The deck: road, median, parapets (railings along a bridge, where the harbour shows between their posts).
        if (kind == 0) {
            if (d.y < 0.0) {
                float tr = eye / -d.y;
                float3 p = float3(d.x * tr, 0.0, d.z * tr);
                if (p.x >= lp && p.x <= fpx && p.z >= zMin) {
                    tHit = tr;
                    if (p.x > mn && p.x < mf) {
                        kind = 3;
                        col = float3(0.06, 0.06, 0.058) * (u.amb.rgb + u.haze.rgb * 1.2);
                    } else {
                        kind = 1;
                        col = float3(0.02);
                        if ((skip & 1u) == 0u) col = shadeRoad(p, d, tr, u, pa, false);
                    }
                }
            }
            for (int side = 0; side < 3; side++) {
                float xw = side == 0 ? lp : (side == 1 ? mn : fpx);
                if ((side == 0 && d.x >= 0.0) || (side > 0 && d.x <= 0.0)) continue;
                float tw = xw / d.x;
                float y = eye + d.y * tw;
                float z = d.z * tw;
                float top = side == 1 ? mh : ph;
                if (tw <= 0.0 || tw >= tHit || y < 0.0 || y > top || z < zMin) continue;
                float zw = z + u.move.x;
                float fz = tw * pa / max(abs(d.x), 0.02), fy = tw * pa;
                bool railing = side != 1 && bridge && z > bs && z < be;
                // Concrete, wet, lit by the street lights and your headlights near; a dark drain line along its foot.
                // Each street light pools on the wall below it; the joints between its cast panels, every 4.8 m; the
                // rain's dark streaks down its face.
                float3 rx = lampRowX(side == 0 ? 0 : 1, u);
                float lz = (zw - rx.y) / kLampSpacing;
                float pool = sq(0.5 + 0.5 * cos(6.2831853 * lz));
                float poolVis = 1.0 - smoothstep(0.3, 0.8, fz / kLampSpacing * 4.0);
                pool = mix(0.375, pool, poolVis);
                float3 lit = u.amb.rgb * 0.8 + u.haze.rgb * 1.6 + kLampColour * (0.03 + 0.26 * pool) * u.neon.z
                           + float3(1.0, 0.9, 0.76) * 0.16 * exp(-z / 12.0);
                float stain = vn2(float2(zw * 2.3, y * 0.35 + 3.0));
                float3 concrete = float3(0.09, 0.088, 0.085) * (0.75 + 0.5 * vn2(float2(zw * 0.8, y * 3.0))) * (0.8 + 0.35 * stain) * lit;
                concrete *= 1.0 - 0.6 * boxCover(y, 0.0, 0.12, fy);
                concrete *= 1.0 - 0.5 * pulseTrain(zw + 0.03, 4.8, 0.06, fz);
                concrete += float3(0.02, 0.02, 0.025) * smoothstep(top - 0.05, top, y) * u.move.w;
                if (railing) {
                    float post = pulseTrain(zw, 2.4, 0.12, fz);
                    float bars = max(boxCover(y, 0.98, 1.08, fy), boxCover(y, 0.5, 0.56, fy));
                    float cov = max(post, bars);
                    if (tw < railT) { railT = tw; railCov = cov; railCol = float3(0.12, 0.12, 0.13) * lit; }
                } else {
                    tHit = tw;
                    kind = 4 + side;
                    col = concrete;
                }
            }
        }

        // An overpass (a surprise): a road bridge on piers, or a railway's girder with a lit train crossing.
        if (u.over.x < 1e4) {
            float oa = u.over.x, od = u.over.y;
            bool rail = u.over.z > 0.5;
            float y0 = rail ? 6.4 : 6.0, y1 = rail ? 8.4 : 7.5;
            if (d.z > 0.0 && oa > 0.5) {
                float tf = oa / d.z;
                float y = eye + d.y * tf;
                float x = d.x * tf;
                if (tf < tHit && y >= y0 && y <= y1 && abs(x) < 120.0) {
                    tHit = tf; kind = 12;
                    float fp = tf * pa;
                    float3 lit = u.amb.rgb + u.haze.rgb * 1.5 + kLampColour * 0.06;
                    col = float3(0.07, 0.068, 0.065) * lit * (0.8 + 0.4 * vn2(float2(x * 0.5, y * 2.0)));
                    col *= 1.0 - 0.5 * boxCover(y, y1 - 0.25, y1, fp);
                }
                // The train above the girder: carriages with lit windows.
                if (rail && u.over.w > -1e4) {
                    float tt = (oa + 2.0) / d.z;
                    float yt = eye + d.y * tt;
                    float xt = d.x * tt;
                    float head = u.over.w, len = u.over2.x;
                    if (tt < tHit && yt > y1 && yt < 12.2 && xt < head && xt > head - len) {
                        float along = head - xt;
                        float car = fract(along / 20.0) * 20.0;
                        if (car > 0.6 && car < 19.4) {
                            tHit = tt; kind = 13;
                            float fp = tt * pa;
                            float win = boxCover(yt, 9.7, 11.1, fp) * pulseTrain(car + 0.6, 2.2, 1.45, fp);
                            float3 shell = float3(0.08, 0.085, 0.09) * (u.amb.rgb + u.haze.rgb * 1.4);
                            float stripe = boxCover(yt, 9.2, 9.4, fp);
                            // Inside: each carriage cool or warm, each window a little different, the ceiling's strip of
                            // light brightest, now and then a passenger's head and shoulders against it.
                            float carIdx = floor(along / 20.0);
                            float pos = fract((car + 0.6) / 2.2) * 2.2 - 0.725;
                            float hw = hash12(float2(floor((car + 0.6) / 2.2), carIdx + 7.0));
                            float hw2 = hash12(float2(floor((car + 0.6) / 2.2) * 1.7, carIdx + 3.0));
                            float vin = saturate((yt - 9.7) / 1.4);
                            float3 tint = fract(carIdx * 0.618 + 0.3) < 0.35 ? float3(0.58, 0.86, 1.0) : float3(1.0, 0.72, 0.42);
                            // The carriage's light inside: the ceiling's strip brightest, falling off towards the frame;
                            // seat backs dark along the sill; some windows dimmer (blinds half down, a dim car).
                            float edge = min(0.725 - abs(pos), min(yt - 9.7, 11.1 - yt));
                            float falloff = 0.45 + 0.55 * smoothstep(0.0, 0.32, edge);
                            float inside = (0.3 + 0.18 * hw) * (0.7 + 0.4 * vin) + 0.4 * smoothstep(0.8, 0.95, vin);
                            inside *= falloff * (1.0 - 0.45 * smoothstep(0.3, 0.12, vin));
                            inside *= hw2 < 0.22 ? 0.35 : 1.0;
                            float c0 = (hw - 0.5) * 0.7;
                            float headD = length(float2(pos - c0, yt - 10.42)) - 0.12;
                            float shoulders = max(abs(pos - c0) - 0.26, yt - 10.24);
                            float person = step(0.55, hw) * smoothstep(fp, -fp, min(headD, shoulders));
                            inside *= 1.0 - 0.8 * person;
                            // The window's dark frame and its mullion (filtered: far off they only dim the glass).
                            float fw = max(fp, 0.02);
                            float frame = 1.0 - smoothstep(0.035 - fw, 0.035 + fw, edge);
                            float mullion = 1.0 - smoothstep(0.02 - fw, 0.02 + fw, abs(pos));
                            float glassLit = 1.0 - max(frame, mullion) * 0.85;
                            col = shell + float3(0.0, 0.05, 0.09) * stripe * 0.4 + tint * (win * inside * glassLit);
                        }
                    }
                }
            }
            if (d.y > 0.0) {
                float tu = (y0 - eye) / d.y;
                float zu = d.z * tu;
                if (tu < tHit && zu > oa && zu < oa + od && abs(d.x * tu) < 120.0) {
                    tHit = tu; kind = 12;
                    col = float3(0.03, 0.03, 0.032) * (u.amb.rgb + u.haze.rgb + kLampColour * 0.05);
                }
            }
            if (!rail && d.z > 0.0) {
                float zp = oa + od * 0.5 - 0.8;
                float tpz = zp / d.z;
                float x = d.x * tpz, y = eye + d.y * tpz;
                bool pier = (x > lp - 2.6 && x < lp - 1.0) || (x > mn && x < mf) || (x > fpx + 0.5 && x < fpx + 2.1);
                if (tpz < tHit && pier && y > 0.0 && y < y0) {
                    tHit = tpz; kind = 12;
                    col = float3(0.06, 0.058, 0.055) * (u.amb.rgb + u.haze.rgb * 1.5 + kLampColour * 0.08);
                }
            }
        }

        // The city: the rows along the road (left or right), then the downtown's layers ahead; roof signs glow as you pass.
        if (kind == 0 && (skip & 2u) == 0u) {
            float zMax = 470.0;
            for (int i = 0; i < 2; i++) {
                // The row's facade line (m across), side, cell, lowest and tallest building (m) and seed: the near and
                // the far row on the left or the right. One call with its row chosen: towerRow (with its signs and
                // facades) was inlined four times, one for each row, which made the shader far larger, and an Intel or
                // AMD GPU slower, for no change in what it draws.
                bool left = d.x < 0.0;
                float4 row = left ? (i == 0 ? float4(-30.0, 64.0, 16.0, 62.0) : float4(-64.0, 80.0, 30.0, 140.0))
                                  : (i == 0 ? float4(44.0, 60.0, 16.0, 70.0) : float4(80.0, 96.0, 30.0, 150.0));
                float rowSeed = left ? (i == 0 ? 1.0 : 2.0) : (i == 0 ? 3.0 : 4.0);
                Tower r = towerRow(d, row.x, left ? -1.0 : 1.0, row.y, row.z, row.w, rowSeed, zMin, zMax, u, pa);
                if (r.addT < 1e8) add += r.add * exp(-r.addT / max(u.haze.w, 1.0));
                if (r.t < 1e8) { tHit = r.t; col = r.col; kind = 20; break; }
            }
        }
        if (kind == 0 && (skip & 4u) == 0u) {
            for (int i = 0; i < 4; i++) {
                // Each layer's distance, cell, lowest and tallest tower (m) and the gap the road runs through, chosen
                // without arrays (indexed at run time in a loop that isn't unrolled, private arrays live in scratch
                // memory on Intel and AMD GPUs).
                float4 lay = i == 0 ? float4(520.0, 34.0, 70.0, 300.0) : (i == 1 ? float4(820.0, 46.0, 60.0, 360.0)
                           : (i == 2 ? float4(1250.0, 62.0, 50.0, 330.0) : float4(1900.0, 85.0, 40.0, 260.0)));
                float2 gap = i == 0 ? float2(-24.0, 40.0) : (i == 1 ? float2(-34.0, 52.0)
                           : (i == 2 ? float2(-48.0, 66.0) : float2(0.0, 0.0)));
                if (lay.x < zMin) continue;
                Tower r = downtown(d, lay.x, lay.y, lay.z, lay.w, gap.x, gap.y, float(i), u, pa);
                if (r.addT < 1e8) add += r.add * exp(-r.addT / max(u.haze.w, 1.0));
                if (r.t < 1e8) { tHit = r.t; col = r.col; kind = 30; break; }
            }
        }

        // Below the deck's edge: the harbour under a bridge, the street far below elsewhere.
        if (kind == 0 && d.y < 0.0) {
            float tg = (eye + 12.0) / -d.y;
            float tw = (eye + 22.0) / -d.y;
            float zw = d.z * tw;
            if (bridge && zw > bs - 60.0 && zw < be + 60.0) {
                tHit = tw; kind = 2;
                float3 p = float3(d.x * tw, -22.0, zw);
                float swell = fbm2(float2(p.x * 0.05, (p.z + u.move.x) * 0.02 + u.a.y * 0.05), 2);
                col = float3(0.004, 0.006, 0.01) * (0.6 + 0.8 * swell) + u.haze.rgb * 0.15;
            } else {
                tHit = tg; kind = 2;
                if ((skip & 8u) == 0u) col = shadeGround(float3(d.x * tg, -12.0, d.z * tg), tg, u, pa);
            }
        }

        // The traffic: the cars' faces where the ray meets them, nearer than what it hit.
        float carT = 1e9;
        for (int c = 0; c < 12; c++) {
            float4 a = u.cars[c * 2];
            if ((skip & 16u) != 0u) break;
            // (A ray outside the car's cone passes more than 13.6 m from it: its face, 1.8 m round, can't be met.)
            float4 cone = u.carCone[c];
            if (abs(dot(d, cone.xyz)) < cone.w) continue;
            if (a.y < 1.0 || a.y > 700.0 || a.y < zMin || d.z <= 0.0) continue;
            float tc = a.y / d.z;
            if (tc >= tHit) continue;
            float2 l = float2(d.x * tc - a.x, eye + d.y * tc);
            if (abs(l.x) > 1.3 || l.y > 1.9 || l.y < -0.2) continue;
            float4 cc = shadeCar(l, a, u.cars[c * 2 + 1], tc * pa, u);
            if (cc.w <= 0.0) continue;
            col = mix(col, cc.rgb, cc.w);
            if (cc.w > 0.5) { carT = min(carT, tc); }
        }
        if (carT < tHit) tHit = carT;
        if (railT < tHit) col = mix(col, railCol, railCov);

        // The air: the haze over everything hit, and the lights glowing in the rain.
        if (kind == 0) {
            col = float3(0.01);
            if ((skip & 128u) == 0u) col = driveSky(dE, d, sky, u, stars, cell);
        } else {
            col = applyHaze(col, tHit, d, u);
        }
        col += add;
        for (int row = 0; row < 3; row++) {
            if ((skip & 32u) != 0u) break;
            float3 rx = lampRowX(row, u);
            float3 lamp;
            lampNearest(d, rx.x, kLampHeight, kLampSpacing, rx.y, u.move.x, eye, lamp);
            for (int j = -1; j <= 1; j++) {
                float3 v = lamp + float3(0.0, 0.0, float(j) * kLampSpacing);
                if (v.z < zMin || (v.z > ts - 2.0 && v.z < te + 2.0)) continue;
                col += lampGlow(d, v, tHit, u.neon.z * 1.4, kLampColour, rain, pa) * exp(-length(v) / max(u.haze.w * 1.5, 1.0));
            }
        }
        if (ts < 1e4 && te > 0.0) {
            float3 lamp;
            lampNearest(d, 1.6, kTunnelCeiling - 0.15, max(u.route2.y, 4.0), 0.0, u.route2.z, eye, lamp);
            for (int j = -1; j <= 1; j++) {
                float3 v = lamp + float3(0.0, 0.0, float(j) * max(u.route2.y, 4.0));
                if (v.z < max(ts, 0.0) || v.z > te) continue;
                col += lampGlow(d, v, tHit + 1.0, 0.6, float3(1.0, 0.5, 0.14), 0.15, pa);
            }
        }
        for (int c = 0; c < 12; c++) {
            float4 a = u.cars[c * 2];
            if ((skip & 64u) != 0u) break;
            if (a.y < zMin) continue;
            col += carGlow(d, a, u.carCone[c], tHit, eye, rain, pa);
        }
        ColorDepth out;
        out.color = float4(max(col, 0.0), 1.0);
        float tt = min(tHit, 1e4);
        out.depth = float4(tt / (tt + 60.0), 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- the wet road's mirror
    /// The road's and the harbour's reflection of the city above eye level, from the blurred copy of the scene: the
    /// mirrored direction's screen place, streaked down towards you by the rain-roughened surface, rippled by the rain;
    /// the Fresnel of water at that angle. Added over the scene (the analytic streaks of the street lights and the traffic
    /// are the scene's own).
    /// The mirror's light at a pixel (`ndc`; `pix` its place in the target, for the taps' jitter), and 1 where the road or
    /// the water is seen there (0 elsewhere); `testDepth` false leaves out the test for nearer things in front of the
    /// surface (the half-resolution pass: the full-resolution one that adds it in does that test, so their outlines stay
    /// sharp).
    float4 driveMirror(float2 ndc, float2 pix, constant SkyU& sky, constant DriveU& u, texture2d<float> view,
                       texture2d<float> depth, bool testDepth) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float3 dE;
        float3 d = driveRay(ndc, sky, u, dE);
        float3 p;
        float kind = driveSurface(d, u, p);
        if (kind < 0.5) return float4(0);
        // Nearer things (the cars, the parapets, a tunnel's portal) stand in front of the surface: the scene's depth says.
        float eye = u.road3.y;
        float t = kind > 1.5 ? (eye + 22.0) / -d.y : eye / -d.y;
        if (testDepth) {
            float2 here = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            float dep = depth.sample(s, here).r;
            float sceneT = 60.0 * dep / max(1.0 - dep, 1e-4);
            if (sceneT < t * 0.97 - 0.5) return float4(0);
        }
        float3 m = float3(d.x, -d.y, d.z);
        float3 sp = driveProject(m, sky, u);
        if (sp.z <= 0.0) return float4(0, 0, 0, 1);
        float2 uv = float2(sp.x * 0.5 + 0.5, 0.5 - sp.y * 0.5);
        float water = kind > 1.5 ? 1.0 : 0.0;
        float zw = p.z + u.move.x;
        float wet = mix(u.rain.z, 1.0, water);
        // How far beyond the road the mirrored thing stands (m), from the scene's depth along the mirrored ray: a wet road
        // mirrors what stands on it sharply and what stands far beyond it blurred and faint, as a glossy surface does.
        float depM = depth.sample(s, saturate(uv)).r;
        float tM = 60.0 * depM / max(1.0 - depM, 1e-4);
        float beyond = max(tM - t, 0.0);
        float spread = beyond / (t + beyond + 1e-3);
        int oct = int(u.a.z + 0.5);
        float puddle = smoothstep(0.56, 0.74, fbm2(float2(p.x * 0.21, zw * 0.07), oct)) * u.rain.z;
        float rough = water > 0.5 ? 0.35 : clamp(0.8 - 0.5 * puddle, 0.2, 1.0);
        // Ripples: the rain's on the road, the swell's on the harbour. They shift the mirror sideways in bands (more for
        // what's further off) and break its light into patches, as they break the lamps' streaks.
        float2 rp = float2(p.x, zw) * (water > 0.5 ? 0.08 : 0.9);
        float n1 = vn2(rp + float2(0.0, u.a.y * (water > 0.5 ? 0.3 : 2.0))) - 0.5;
        float n2 = vn2(rp * 2.3 + float2(u.a.y * 1.1, 3.7)) - 0.5;
        float shake = (water > 0.5 ? 3.0 : 1.0 + 2.0 * u.rain.x) * (0.4 + 1.6 * spread);
        uv += float2(n1 * 0.008 + n2 * 0.004, n2 * 0.01) * shake;
        float rip = vn2(float2(p.x * 1.3, zw * 3.1) + float2(0.0, u.a.y * 1.7));
        float patches = mix(1.0, 0.35 + 1.9 * rip * rip, 0.5 + 0.5 * spread);
        // The blur: the surface's sideways roughness over the distance beyond, in the copy's texels (half resolution).
        float sigma = (water > 0.5 ? 0.014 : 0.01 + 0.012 * rough) * spread;
        float lod = clamp(log2(max(sigma / max(u.a.w * 2.0, 1e-5), 1.0)), 1.6 + rough * 0.4, 4.0);
        // The streak: taps down the screen (towards you) and a few up, widening with roughness.
        // Jittered a pixel at a time (interleaved noise) so a bright line doesn't repeat down the road in bands.
        float3 acc = float3(0);
        float wsum = 0.0;
        float reach = 0.05 + 0.22 * rough;
        float jit = fract(52.9829189 * fract(dot(pix, float2(0.06711056, 0.00583715))));
        int taps = oct > 2 ? 12 : 8;
        float stepK = 9.0 / float(taps);
        for (int i = 0; i < taps; i++) {
            float k = (float(i) + jit) * stepK / 7.0 - 2.0 / 7.0;
            float w = exp(-k * k * 2.2);
            float2 q = uv + float2(0.0, k * reach);
            if (q.y < 0.0 || q.y > 1.0) continue;
            acc += view.sample(s, q, level(lod)).rgb * w;
            wsum += w;
        }
        float3 refl = wsum > 0.0 ? acc / wsum : float3(0);
        // Only what stands above the horizon is mirrored this way (lower things have their own streaks): fade the taps that
        // came back from below it. Nothing is mirrored from past the view's edges (no smeared edge columns), and the
        // mirror fades with the distance beyond.
        float3 hz = driveProject(float3(d.x, 0.0, d.z), sky, u);
        float aboveH = smoothstep(hz.y - 0.02, hz.y + 0.04, sp.y);
        // What the pillars hide from you isn't mirrored either (it would show as a stray patch under them).
        float fC = clamp((sp.y - u.cabin.x) / max(u.cabin.y - u.cabin.x, 1e-3), 0.0, 1.0);
        float lx = mix(u.pillars.x, u.pillars.y, fC), rx = mix(u.pillars.z, u.pillars.w, fC);
        float seen = smoothstep(lx - 0.02, lx + 0.12, sp.x) * smoothstep(rx + 0.02, rx - 0.12, sp.x);
        float edges = smoothstep(0.0, 0.06, uv.x) * smoothstep(1.0, 0.94, uv.x) * seen;
        float fade = 1.0 / (1.0 + beyond / 80.0);
        float F = fresnelWet(-d.y);
        float strength = F * wet * (water > 0.5 ? 0.9 : 0.55 + 0.6 * puddle) * aboveH * edges * fade * patches;
        float k = 1.0 - exp(-t / max(u.haze.w, 1.0));
        return float4(refl * strength * (1.0 - k), 1.0);
    }

    fragment float4 drive_reflect_fragment(DriveOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                           constant DriveU& u [[buffer(1)]], texture2d<float> view [[texture(0)]],
                                           texture2d<float> depth [[texture(1)]]) {
        return float4(driveMirror(in.ndc, in.pos.xy, sky, u, view, depth, true).rgb, 0.0);
    }

    // The mirror at half resolution: it is a blur (the copy's mips, streaked), so drawn into a half-size target (a
    // quarter of its taps a frame) and added in at full resolution, where the scene's depth hides it behind the cars,
    // the parapets and a portal pixel by pixel.
    fragment float4 drive_mirror_fragment(DriveOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                          constant DriveU& u [[buffer(1)]], texture2d<float> view [[texture(0)]],
                                          texture2d<float> depth [[texture(1)]]) {
        return driveMirror(in.ndc, in.pos.xy, sky, u, view, depth, false);
    }

    fragment float4 drive_mirror_compose_fragment(DriveOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                                  constant DriveU& u [[buffer(1)]], texture2d<float> mirror [[texture(0)]],
                                                  texture2d<float> depth [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 dE;
        float3 d = driveRay(in.ndc, sky, u, dE);
        float3 p;
        float kind = driveSurface(d, u, p);
        if (kind < 0.5) return float4(0);
        float eye = u.road3.y;
        float t = kind > 1.5 ? (eye + 22.0) / -d.y : eye / -d.y;
        float2 here = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        float dep = depth.sample(s, here).r;
        float sceneT = 60.0 * dep / max(1.0 - dep, 1e-4);
        if (sceneT < t * 0.97 - 0.5) return float4(0);
        // (Filtered over the texels that saw the surface only (alpha 1), so its edges at a parapet's foot or the median
        // don't darken by mixing in texels that saw neither.)
        float4 m = mirror.sample(s, here);
        return float4(m.a > 1e-3 ? m.rgb / m.a : float3(0), 0.0);
    }
    """
}
