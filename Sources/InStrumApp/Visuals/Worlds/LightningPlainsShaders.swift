/// Metal source for Lightning Plains (Storms spec §9): the vast dusk sky over a dry grass plain, the storm's line of towers
/// on the western horizon (lit from inside by its flashes and the heat lightning, with a silver lining toward the sunset,
/// their tops gold while they stand above Earth's shadow), its dark base and rain shafts, the far glow beneath it, the
/// ridge and the ball lightning; then Strike Lines' forks and crawlers as analytic segments; then the props back to front:
/// grass rows bending on the wind field, the fence posts (the keys) with their wires, the windmill, the tank, a dust devil
/// and the rain curtain. Built on SkyShaders.common (skyRadiance with the real stars). Smooth rules: no ray marching, at
/// most 3 noise octaves (2 on Smooth), analytic everything; squares are written out (no powers).
enum LightningPlainsShaders {
    static let source = SkyShaders.common + """
    // ---------------------------------------------------------------- Lightning Plains
    struct PlainsU {
        float4 frame;      // aspect, time (s), horizon (NDC y), noise octaves
        float4 view;       // eye height (m), a pixel's angle (rad), gentle 0/1, the storm's lump size (deg)
        float4 shake;      // camera shake (NDC xy), the drop's sheet-lit sky (after the limiter), the storm's distance (km)
        float4 storm;      // bearing (deg from north), the line's half-width (deg), dry 0/1, the base's near edge (altitude, deg)
        float4 ahead;      // the view's level forward (east, north), its right (east, north)
        float4 ambient;    // the sky's light on things (rgb), night 0…1
        float4 glow;       // the low sky behind the silhouettes (rgb), the sun's offset from the bearing (deg)
        float4 sun;        // the sun on the towers' tops 0…1, Earth's shadow's height there (km), one pixel (NDC y), unused
        float4 flash;      // the strikes' light on the plain (rgb, after the limiter), unused
        float4 ridge;      // from, to (offsets, deg), height (deg), distance (km)
        float4 ball;       // offset (deg), altitude (deg), brightness, radius (deg)
        float4 shafts;     // the rain shafts' strength, their slant, virga 0…1, the base's far edge (altitude, deg)
        float4 towerA[5];  // offset (deg), the turret's half-width (deg), its top (deg), the anvil's half-spread (deg)
        float4 towerB[5];  // the anvil's base (deg), distance (km), seed, rain shaft 0…1
        float4 lightA[8];  // light inside the storm: offset (deg), altitude (deg), radius (deg), level (0: empty)
        float4 lightC[8];  // its colour (rgb), unused
        float4 rim[4];     // heat lightning on the rim: offset (deg), half-width (deg), height (deg), brightness
    };

    struct PlainsOut { float4 pos [[position]]; float2 ndc; };

    float pl_sq(float x) { return x * x; }
    float pl_wrap(float a) { return a - 360.0 * floor((a + 180.0) / 360.0); }

    vertex PlainsOut plains_vertex(uint vid [[vertex_id]]) {
        float2 c[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        PlainsOut o;
        o.pos = float4(c[vid], 0, 1);
        o.ndc = c[vid];
        return o;
    }

    float3 pl_ray(float2 ndc, constant SkyU& u) {
        return normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
    }

    /// The storm's cloud at (offset th, altitude alt), degrees: five towers (a turret rounding over at its top, an anvil
    /// spread flat over it, its underside rising toward its ends) over the storm's dark base, which runs the line's width
    /// between its near and far edges. The outline is broken into lumps by noise the size of the storm's scale. Returns
    /// the cover 0…1; `edge` is 1 at the outline and 0 deep inside, `detail` the lumps' own noise, `km` the distance of the
    /// tower there.
    float pl_storm(float th, float alt, constant PlainsU& p, int octaves, float time,
                   thread float& edge, thread float& detail, thread float& km) {
        float s = max(p.view.w, 0.05);
        float field = -1e4;
        km = p.shake.w;
        for (int i = 0; i < 5; i++) {
            float4 a = p.towerA[i];
            float4 b = p.towerB[i];
            if (a.z <= 0.0) continue;
            float dx = th - a.x;
            float hy = alt / a.z;
            float body = a.y * (0.84 + 0.16 * saturate(hy));
            float dome = hy > 0.72 ? sqrt(saturate(1.0 - pl_sq((hy - 0.72) / 0.3))) : 1.0;
            float turret = min(body * dome - abs(dx), (a.z - alt) * 0.6);
            float ax = dx / max(a.w, 1e-3);
            float under = b.x + (a.z - b.x) * 0.5 * ax * ax;
            float spread = a.w * (1.0 - 0.2 * saturate((alt - b.x) / max(a.z - b.x, 0.1)));
            float plate = min(spread - abs(dx), min(a.z * 1.03 - alt, alt - under));
            float f = max(turret, plate);
            if (f > field) { field = f; km = b.y; }
        }
        float deck = min(min(p.storm.w - alt, alt - p.shafts.w), (p.storm.y - abs(th)) * 0.3);
        field = max(field, deck);
        if (field < -2.5 * s) { edge = 0.0; detail = 0.5; return 0.0; }
        float3 q = float3(th / s, alt / s, time * 0.015);
        float n = fbm3(q * 0.9, octaves);
        detail = vnoise3(q * 2.7 + 5.1);
        float shaped = field + s * (1.1 * (n - 0.5) + 0.3 * (detail - 0.5));
        edge = 1.0 - smoothstep(0.0, 0.9 * s, shaped);
        return smoothstep(-0.12 * s, 0.18 * s, shaped);
    }

    /// The storm's light: a dark, cool, backlit body with a silver lining where it is thin (brightest toward the sun);
    /// tops above Earth's shadow gold at their edges; and its flashes' light spreading through it, showing its lumps.
    float3 pl_stormLight(float th, float alt, float edge, float detail, float km, constant PlainsU& p) {
        float3 body = p.ambient.rgb * 0.36 + p.glow.rgb * 0.045;
        float sunSide = exp(-abs(pl_wrap(th - p.glow.w)) / 28.0);
        float lining = edge * edge;
        float3 col = body + p.glow.rgb * lining * (0.3 + 1.0 * sunSide) * 0.55;
        float heightKm = km * tan(toRad(clamp(alt, 0.0, 80.0)));
        float sunlit = p.sun.x * smoothstep(p.sun.y - 0.6, p.sun.y + 0.6, heightKm);
        col += float3(1.0, 0.6, 0.36) * sunlit * (0.1 + 1.2 * lining) * (0.45 + sunSide);
        float3 inside = float3(0.0);
        for (int i = 0; i < 8; i++) {
            float4 l = p.lightA[i];
            if (l.w <= 0.0) continue;
            float2 dd = float2(pl_wrap(th - l.x), alt - l.y) / max(l.z, 0.05);
            inside += p.lightC[i].rgb * (l.w * exp(-dot(dd, dd)));
        }
        inside += float3(0.82, 0.84, 1.0) * p.shake.z;
        col += inside * (0.3 + 1.0 * detail) * (1.0 - 0.35 * edge);
        return col;
    }

    /// The rain shafts hanging from the storm's base to the plain (to half way under virga), streaked, slanting.
    float pl_shafts(float th, float alt, constant PlainsU& p, float time) {
        float front = p.storm.w;
        if (alt < -0.4 || alt > front) return 0.0;
        float v = 0.0;
        for (int i = 0; i < 5; i++) {
            float4 a = p.towerA[i];
            float w = p.towerB[i].w;
            if (w <= 0.0 || a.z <= 0.0) continue;
            float slanted = th - a.x + p.shafts.y * (front - alt);
            v = max(v, w * (1.0 - smoothstep(0.3, 0.85, abs(slanted) / max(a.y, 1e-3))));
        }
        if (v <= 0.0) return 0.0;
        float s = max(p.view.w, 0.05);
        float streak = vnoise3(float3((th + p.shafts.y * alt) / s * 5.0, alt / s * 0.35 + time * 0.6, 2.3));
        float hang = smoothstep(front, 0.8 * front, alt);
        float reach = mix(1.0, smoothstep(0.3 * front, 0.65 * front, alt), p.shafts.z);
        return v * p.shafts.x * (0.5 + 0.5 * streak) * hang * reach;
    }

    /// The far ridge's top (altitude, deg) at offset th: a mesa rising off the plain on the right, its flat top gently
    /// rolling, a bench in its escarpment; -1 off its ends. (The renderer's `ridgeTop` is the same curve.)
    float pl_ridgeTop(float th, constant PlainsU& p) {
        float4 r = p.ridge;
        float u = (th - r.x) / max(r.y - r.x, 1e-3);
        if (u <= 0.0 || u >= 1.0) return -1.0;
        float rise = smoothstep(0.0, 0.1, u) * (1.0 - smoothstep(0.88, 1.0, u));
        float mesa = 0.8 + 0.12 * sin(u * 9.0 + 1.3) + 0.08 * sin(u * 23.0 + 0.4) - 0.18 * smoothstep(0.42, 0.47, u);
        return r.z * rise * mesa;
    }

    fragment ColorDepth plains_scene_fragment(PlainsOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                              constant PlainsU& p [[buffer(1)]], texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc - p.shake.xy;
        float3 d = pl_ray(ndc, u);
        float alt = toDeg(asin(clamp(d.z, -1.0, 1.0)));
        float th = pl_wrap(toDeg(atan2(d.x, d.y)) - p.storm.x);
        int octaves = int(p.frame.w + 0.5);
        float time = p.frame.y;

        // The sky (just over the horizon for the ground's haze).
        float moonMask = 0.0;
        float3 skyDir = normalize(float3(d.xy, max(d.z, 0.0015)));
        float3 col = skyRadiance(skyDir, u, moonMask, stars);

        // Heat lightning on the rim behind the storm: warm-white, soft-edged.
        for (int i = 0; i < 4; i++) {
            float4 r = p.rim[i];
            if (r.w <= 0.0) continue;
            float dth = pl_wrap(th - r.x);
            if (abs(dth) >= r.y) continue;
            float across = 0.5 + 0.5 * cos(3.14159265 * dth / r.y);
            float upward = exp(-2.0 * max(alt, 0.0) / max(r.z, 0.1)) * smoothstep(-0.5, 0.0, alt);
            col += float3(1.0, 0.88, 0.72) * (r.w * 1.6 * across * upward);
        }

        // The far ridge, the storm and its rain, nearest last.
        if (alt > -0.5) {
            float edge = 0.0, detail = 0.5, km = p.shake.w;
            float cover = pl_storm(th, alt, p, octaves, time, edge, detail, km);
            float3 stormCol = cover > 0.0 ? pl_stormLight(th, alt, edge, detail, km, p) : float3(0.0);
            float shaft = pl_shafts(th, alt, p, time);
            float3 rainCol = p.ambient.rgb * 0.3 + p.glow.rgb * 0.12;
            float ridgeTop = pl_ridgeTop(th, p);
            float ridge = ridgeTop > 0.0 ? smoothstep(ridgeTop + 0.05, ridgeTop - 0.05, alt) : 0.0;
            float3 haze = mix(u.horizon.rgb, p.glow.rgb, 0.5);
            float3 ridgeCol = mix(p.ambient.rgb * 0.3, haze * 0.75, 0.55) + p.flash.rgb * 0.05;
            bool ridgeNearer = p.ridge.w < p.shake.w;
            if (ridgeNearer) {
                col = mix(col, rainCol, shaft);
                col = mix(col, stormCol, cover);
                col = mix(col, ridgeCol, ridge);
            } else {
                col = mix(col, ridgeCol, ridge);
                col = mix(col, rainCol, shaft);
                col = mix(col, stormCol, cover);
            }
            // Ball lightning rolling along the ridge.
            if (p.ball.z > 0.0) {
                float2 bd = float2(pl_wrap(th - p.ball.x), alt - p.ball.y) / max(p.ball.w, 0.01);
                float r2 = dot(bd, bd);
                col += float3(1.0, 0.7, 0.4) * p.ball.z * (3.0 * exp(-r2) + 0.3 * exp(-0.5 * sqrt(r2)));
            }
        }

        // The plain beyond the grass, fading into the horizon's haze; lit by the strikes; dark and wet after rain.
        if (d.z < 0.0) {
            float g = p.view.x / max(-d.z, 1e-5);
            float2 flat = d.xy / max(length(d.xy), 1e-5) * g;
            float2 gp = float2(dot(flat, p.ahead.zw), dot(flat, p.ahead.xy));
            float tex = fbm3(float3(gp * 0.08, 1.7), max(octaves - 1, 1));
            float3 straw = float3(0.42, 0.33, 0.2);
            float3 ground = straw * p.ambient.rgb * (0.5 + 0.5 * tex) + p.glow.rgb * 0.05 * (0.5 + tex);
            ground += p.flash.rgb * 0.12;
            float wet = saturate(u.extra.w);
            ground = mix(ground, col * 0.35, 0.4 * wet);
            float fog = 1.0 - exp(-g / 1400.0);
            col = mix(ground, col, fog);
        }

        ColorDepth out;
        out.color = float4(col, 1.0);
        out.depth = float4(1.0, 0, 0, 1);
        return out;
    }

    // ---------------------------------------------------------------- Strike Lines: forks and crawlers
    // Each instance is one straight stretch of channel: its ends (NDC), core width and glow reach (NDC y units), light,
    // and colour (HDR). Drawn additively over the sky, under the plain's props.
    struct BoltIn { float4 seg; float4 info; float4 colour; };
    struct BoltOut { float4 pos [[position]]; float2 q; float4 seg [[flat]]; float4 info [[flat]]; float4 colour [[flat]]; };

    vertex BoltOut plains_bolt_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device BoltIn* bolts [[buffer(0)]], constant PlainsU& p [[buffer(1)]]) {
        BoltIn b = bolts[iid];
        float aspect = p.frame.x;
        float2 a = float2(b.seg.x * aspect, b.seg.y);
        float2 c = float2(b.seg.z * aspect, b.seg.w);
        float2 dir = c - a;
        float len = length(dir);
        float2 t = len > 1e-6 ? dir / len : float2(0.0, 1.0);
        float2 n = float2(-t.y, t.x);
        float w = b.info.y;
        float2 corner[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float2 k = corner[vid];
        float2 at = (k.x < 0.0 ? a - t * w : c + t * w) + n * (k.y * w);
        BoltOut o;
        o.q = at;
        o.pos = float4(at.x / aspect + p.shake.x, at.y + p.shake.y, 0, 1);
        o.seg = float4(a, c);
        o.info = b.info;
        o.colour = b.colour;
        return o;
    }

    fragment ColorDepth plains_bolt_fragment(BoltOut in [[stage_in]]) {
        float2 a = in.seg.xy, c = in.seg.zw;
        float2 pa = in.q - a, ba = c - a;
        float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-12));
        float dist = length(pa - ba * h);
        float core = max(in.info.x, 1e-5);
        float reach = max(in.info.y, 1e-5);
        float x = dist / core;
        float light = exp(-x * x) + 0.2 * exp(-4.0 * dist / reach);
        ColorDepth o;
        o.color = float4(in.colour.rgb * (in.info.z * light), 0.0);
        o.depth = float4(1.0, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- the plain's props, back to front
    // Each instance: a (its rectangle, NDC), b (kind, distance m, …), c and d (its own). Premultiplied colour out.
    struct PropIn { float4 a; float4 b; float4 c; float4 d; };
    struct PropOut { float4 pos [[position]]; float2 ndc; float4 b [[flat]]; float4 c [[flat]]; float4 d [[flat]]; };

    vertex PropOut plains_prop_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device PropIn* props [[buffer(0)]], constant PlainsU& p [[buffer(1)]]) {
        float2 corner[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        PropIn k = props[iid];
        float2 xy = mix(k.a.xy, k.a.zw, corner[vid]);
        PropOut o;
        o.ndc = xy;
        o.pos = float4(xy + p.shake.xy, 0, 1);
        o.b = k.b; o.c = k.c; o.d = k.d;
        return o;
    }

    /// A row of dry grass at one distance: blades from cells of the row's spacing, each with its own height, bending on
    /// the wind sampled across the view (c: the wind across the view at its left edge, a third in, two thirds, its right
    /// edge, m/s) and swaying; seed heads on the tall stalks. Backlit: dark straw, its tips glowing with the sky.
    float4 pl_grass(float2 ndc, float4 b, float4 c, float4 d, constant SkyU& u, constant PlainsU& p) {
        float3 ray = pl_ray(ndc, u);
        float fwd = dot(ray.xy, p.ahead.xy);
        if (fwd <= 1e-4) return float4(0.0);
        float z = b.y;
        float t = z / fwd;
        float X = t * dot(ray.xy, p.ahead.zw);
        float Y = p.view.x + t * ray.z;
        float H = b.z;
        if (Y < -0.02 || Y > 1.7 * H + 0.1) return float4(0.0);
        float sb = max(d.x, 1e-3);
        float aa = max(t * p.view.y * 0.8, 1e-4);
        float sx = saturate(ndc.x * 0.5 + 0.5) * 3.0;
        int i0 = min(int(sx), 2);
        float f = sx - float(i0);
        float w0 = i0 == 0 ? c.x : (i0 == 1 ? c.y : c.z);
        float w1 = i0 == 0 ? c.y : (i0 == 1 ? c.z : c.w);
        float wind = mix(w0, w1, f);
        float time = p.frame.y;
        float cell = floor(X / sb);
        float cover = 0.0, tip = 0.0;
        for (int j = -1; j <= 1; j++) {
            float cj = cell + float(j);
            float3 h = hash33(float3(cj, b.w, 3.7));
            bool tall = h.z > 1.0 - d.w;
            float hgt = H * (0.5 + 0.5 * h.y) * (tall ? 1.6 : 1.0);
            if (Y > hgt * 1.08) continue;
            float k = saturate(Y / hgt);
            float sway = d.z * sin(time * (1.3 + 1.1 * h.y) + h.x * 6.2832 + X * 0.35);
            float lean = clamp(wind / 12.0 + sway + (h.z - 0.5) * 0.3, -1.2, 1.2);
            float root = (cj + 0.15 + 0.7 * h.x) * sb;
            float x = root + lean * hgt * 0.55 * k * k;
            float width = (tall ? 0.004 : 0.006) * (1.0 - 0.7 * k) + 0.2 * aa;
            float dist = abs(X - x);
            float blade = saturate((width - dist) / aa + 0.5) * step(0.0, Y);
            if (h.z > 0.55) {
                float hy = (Y - hgt * 0.86) / (hgt * 0.14);
                if (hy > -1.0 && hy < 1.0) {
                    float headW = width * 2.6 + 0.3 * aa;
                    float head = saturate((headW * sqrt(saturate(1.0 - hy * hy)) - dist) / aa + 0.5);
                    blade = max(blade, head);
                    tip = max(tip, head);
                }
            }
            cover = max(cover, blade);
            tip = max(tip, blade * smoothstep(0.55, 1.0, k));
        }
        if (cover <= 0.001) return float4(0.0);
        float3 straw = float3(0.46, 0.36, 0.22);
        float3 col = straw * p.ambient.rgb * 0.55 + p.glow.rgb * (0.04 + 0.5 * tip) + p.flash.rgb * (0.1 + 0.3 * tip);
        float fog = 1.0 - exp(-z / 1400.0);
        col = mix(col, p.glow.rgb * 0.8 + u.horizon.rgb * 0.2, fog);
        return float4(col * cover, cover);
    }

    /// A fence post: c (its base and top, NDC), d (half-width and glow reach, NDC y units; a pixel). Dark weathered wood
    /// against the light; lit white by its note, the glow round its top growing with the level (b.z).
    float4 pl_post(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float span = c.w - c.y;
        float k = (ndc.y - c.y) / max(span, 1e-5);
        float cx = mix(c.x, c.z, saturate(k));
        float across = (ndc.x - cx) * aspect;
        float hw = d.x;
        float body = saturate((hw + 0.35 * px - abs(across)) / px) * step(0.0, k) * saturate((1.0 - k) * span / px + 0.5);
        float lit = saturate(b.z);
        float3 wood = p.ambient.rgb * float3(0.2, 0.17, 0.14) + p.glow.rgb * 0.07 * smoothstep(0.3, 1.0, k) + p.flash.rgb * 0.15;
        float3 white = float3(0.78, 0.86, 1.0);
        float3 col = mix(wood, white * (0.9 + 2.2 * lit * (0.55 + 0.45 * k)), lit);
        float2 top = float2((ndc.x - c.z) * aspect, ndc.y - c.w);
        float r = length(top) / max(d.y, 1e-5);
        float halo = lit * (0.9 * exp(-4.0 * r * r) + 0.25 * exp(-2.5 * r));
        float3 shown = col * body + white * halo * 1.4;
        return float4(shown, body);
    }

    /// The fence's three strands between two posts: c (the lowest strand's ends, NDC), d (the highest strand's two ends'
    /// heights, a pixel, the light of the posts at its ends). Thin dark wire glinting with the sky behind.
    float4 pl_wire(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float best = 1e9;
        float along = 0.0;
        for (int s = 0; s < 3; s++) {
            float f = float(s) * 0.5;
            float2 a = float2(c.x * aspect, mix(c.y, d.x, f));
            float2 e = float2(c.z * aspect, mix(c.w, d.y, f));
            float2 q = float2(ndc.x * aspect, ndc.y);
            float2 pa = q - a, ba = e - a;
            float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-12));
            float dist = length(pa - ba * h);
            if (dist < best) { best = dist; along = h; }
        }
        float cover = saturate(0.6 - best / px) * 0.9;
        if (cover <= 0.0) return float4(0.0);
        float lit = d.w * (0.4 + 0.6 * (1.0 - abs(along - 0.5) * 2.0));
        float3 col = p.ambient.rgb * 0.15 + p.glow.rgb * 0.22 + float3(0.78, 0.86, 1.0) * lit * 0.8 + p.flash.rgb * 0.2;
        return float4(col * cover, cover);
    }

    /// The steel windmill: c (the hub, NDC; the wheel's radius and the tower's base, NDC y), d (the legs' half-spread at
    /// the base and the top, NDC y units; a pixel; the tail vane's reach), b.z its angle (rad), b.w its blur (0 sharp …
    /// 1 a blurred disc). Iron against the light, rimmed with it.
    float4 pl_windmill(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float2 q = float2((ndc.x - c.x) * aspect, ndc.y - c.y);
        float R = c.z;
        float cover = 0.0;
        // The tower: two legs splayed to the base, cross braces in six bays, a platform under the wheel.
        float base = c.w - c.y;
        float k = q.y / min(base, -1e-5);
        if (k >= 0.0 && k <= 1.0) {
            float splay = mix(d.y, d.x, k);
            float leg = min(abs(q.x - splay), abs(q.x + splay));
            cover = max(cover, saturate(1.0 - leg / (0.9 * px)));
            float bay = k * 6.0;
            float f = bay - floor(bay);
            float x1 = mix(-splay, splay, f), x2 = mix(splay, -splay, f);
            float brace = min(abs(q.x - x1), abs(q.x - x2)) * (abs(q.x) < splay ? 1.0 : 1e3);
            cover = max(cover, 0.8 * saturate(1.0 - brace / (0.6 * px)));
        }
        float platform = abs(q.y + 0.2 * R) < 0.8 * px && abs(q.x) < 0.35 * R ? 1.0 : 0.0;
        cover = max(cover, platform);
        // The wheel: rings, 18 sails, the hub; blurred into a disc as it races.
        float2 w = float2(q.x / 0.86, q.y);
        float r = length(w) / max(R, 1e-5);
        float rr = px / max(R, 1e-5);
        float ring = max(saturate(1.0 - abs(r - 0.97) / (1.3 * rr)), saturate(1.0 - abs(r - 0.33) / (1.1 * rr)));
        float sails = 0.0;
        if (r > 0.33 && r < 0.98) {
            float a = atan2(w.y, w.x) + b.z;
            float f = a * 18.0 / 6.2831853;
            float s = f - floor(f);
            float sharp = smoothstep(0.05, 0.12, s) * (1.0 - smoothstep(0.55, 0.62, s));
            sails = mix(sharp, 0.5, saturate(b.w)) * 0.95;
        }
        float hub = r < 0.1 ? 1.0 : 0.0;
        cover = max(cover, max(max(ring, sails), hub));
        // The tail vane, downwind to the right: a boom and a flat sheet.
        float vx = q.x / max(d.w, 1e-5);
        if (vx > 0.1 && vx < 1.0) {
            float boom = saturate(1.0 - abs(q.y) / (0.7 * px));
            float sheet = vx > 0.55 && abs(q.y) < R * (0.12 + 0.4 * (vx - 0.55)) ? 1.0 : 0.0;
            cover = max(cover, max(boom, sheet * 0.95));
        }
        if (cover <= 0.001) return float4(0.0);
        float3 iron = p.ambient.rgb * 0.1 + p.glow.rgb * 0.1 + p.flash.rgb * 0.12;
        return float4(iron * cover, cover);
    }

    /// The water tank on its stand: c (its middle and the stand's foot, NDC x / y; its half-width, NDC y units; the stand's
    /// top), d (the tank's top and the roof's peak, NDC y; a pixel). Corrugated iron catching the light in faint bands.
    float4 pl_tank(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p) {
        float aspect = p.frame.x;
        float px = max(d.z, 1e-5);
        float x = (ndc.x - c.x) * aspect;
        float y = ndc.y;
        float hw = c.z;
        float cover = 0.0;
        if (y >= c.y && y <= c.w) {
            float leg = min(abs(abs(x) - 0.82 * hw), abs(x));
            cover = max(cover, saturate(1.0 - leg / (0.9 * px)));
            float f = (y - c.y) / max(c.w - c.y, 1e-5);
            float brace = abs(x - mix(-0.82, 0.82, f) * hw);
            cover = max(cover, abs(x) < 0.82 * hw ? 0.7 * saturate(1.0 - brace / (0.6 * px)) : 0.0);
        }
        float body = (y >= c.w && y <= d.x) ? saturate((hw - abs(x)) / px + 0.5) : 0.0;
        float roofY = d.x + (d.y - d.x) * (1.0 - saturate(abs(x) / hw));
        float roof = (y > d.x && y <= roofY) ? saturate((hw - abs(x)) / px + 0.5) : 0.0;
        cover = max(cover, max(body, roof));
        if (cover <= 0.001) return float4(0.0);
        float bands = 0.5 + 0.5 * sin((y - c.w) / max(px, 1e-5) * 1.6);
        float3 iron = p.ambient.rgb * 0.14 + p.glow.rgb * (0.08 + 0.05 * bands * body) + p.flash.rgb * 0.14;
        return float4(iron * cover, cover);
    }

    /// A dust devil: c (its foot, NDC; its top, NDC y; its foot's half-width, NDC y units), d (its top's half-width;
    /// a pixel; its swirl's phase; how strongly it turns). A twisting column of dust, glowing as the light comes through it.
    float4 pl_devil(float2 ndc, float4 b, float4 c, float4 d, constant PlainsU& p) {
        float aspect = p.frame.x;
        float k = (ndc.y - c.y) / max(c.z - c.y, 1e-5);
        if (k < 0.0 || k > 1.0) return float4(0.0);
        float girth = mix(c.w, d.x, sqrt(k));
        float x = (ndc.x - c.x) * aspect / max(girth, 1e-5);
        if (abs(x) >= 1.0) return float4(0.0);
        float swirl = vnoise3(float3(x * 2.0 + k * 9.0 - d.y * 3.0, k * 14.0 - d.y * 2.0, 4.1));
        float body = (1.0 - x * x) * (0.45 + 0.55 * swirl) * smoothstep(0.0, 0.08, k) * (1.0 - smoothstep(0.6, 1.0, k));
        float a = saturate(body * d.z * 0.75);
        float3 dust = float3(0.62, 0.5, 0.36) * p.ambient.rgb * 0.6 + p.glow.rgb * 0.55 + p.flash.rgb * 0.2;
        return float4(dust * a, a);
    }

    /// The rain curtain at b.y metres: rain hanging from the storm's base (c.x m up) to the plain (to c.y of the way down
    /// under virga), streaked and slanting (c.z), at density c.w; above it the base, dark. It covers everything behind it.
    float4 pl_curtain(float2 ndc, float4 b, float4 c, float4 d, constant SkyU& u, constant PlainsU& p) {
        float3 ray = pl_ray(ndc, u);
        float fwd = dot(ray.xy, p.ahead.xy);
        if (fwd <= 1e-4) return float4(0.0);
        float D = max(b.y, 0.5);
        float t = D / fwd;
        float X = t * dot(ray.xy, p.ahead.zw);
        float Y = p.view.x + t * ray.z;
        if (Y < 0.0) return float4(0.0);
        float time = p.frame.y;
        float baseM = c.x;
        float a;
        float3 col;
        if (Y > baseM) {
            a = 0.85 * c.w;
            col = p.ambient.rgb * 0.22 + p.flash.rgb * 0.35 + float3(0.82, 0.84, 1.0) * p.shake.z * 0.6;
        } else {
            float slant = X + c.z * Y;
            float streak = vnoise3(float3(slant / max(6.0, 0.02 * t), Y / max(60.0, 0.2 * t) + time * 2.5, 6.1));
            float reach = mix(1.0, smoothstep(c.y * baseM, (c.y + 0.25) * baseM, Y), b.z);
            a = c.w * (0.55 + 0.45 * streak) * reach;
            col = p.ambient.rgb * 0.45 + p.glow.rgb * 0.12 + p.flash.rgb * 0.4 + float3(0.82, 0.84, 1.0) * p.shake.z * 0.5;
        }
        a = saturate(a);
        return float4(col * a, a);
    }

    fragment ColorDepth plains_prop_fragment(PropOut in [[stage_in]], constant SkyU& u [[buffer(0)]],
                                             constant PlainsU& p [[buffer(1)]]) {
        int kind = int(in.b.x + 0.5);
        float4 c = float4(0.0);
        if (kind == 0) c = pl_grass(in.ndc, in.b, in.c, in.d, u, p);
        else if (kind == 1) c = pl_post(in.ndc, in.b, in.c, in.d, p);
        else if (kind == 2) c = pl_wire(in.ndc, in.b, in.c, in.d, p);
        else if (kind == 3) c = pl_windmill(in.ndc, in.b, in.c, in.d, p);
        else if (kind == 4) c = pl_tank(in.ndc, in.b, in.c, in.d, p);
        else if (kind == 5) c = pl_devil(in.ndc, in.b, in.c, in.d, p);
        else c = pl_curtain(in.ndc, in.b, in.c, in.d, u, p);
        if (c.a < 0.002 && dot(c.rgb, float3(1.0)) < 0.002) discard_fragment();
        ColorDepth o;
        o.color = c;
        o.depth = float4(saturate(in.b.y / 2000.0), 0, 0, 1);
        return o;
    }
    """
}
