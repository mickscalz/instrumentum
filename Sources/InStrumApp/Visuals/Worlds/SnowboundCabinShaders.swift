/// Metal source for Snowbound Cabin Window: the view from inside a log cabin through a three-by-two window.
/// Outside: two ranges of snowy peaks (arêtes and couloirs) in aerial haze with alpenglow, three rows of snow-laden pines, a far cabin whose
/// window lights at dusk with a ribbon of chimney smoke, a snow field that glints by the sun or moon, a frozen
/// creek mirroring the sky, the window's light on the snow at night, and drifts banked against the panes.
/// Inside: log walls and a thick sill lit by the fire (with a candle in a jar and a mug), and ember-amber keys.
/// The glass and frame are the Window Kit's. Built on SkyShaders.common.
/// Smooth rules: no ray marching, ≤ 3 noise octaves (the smoke), squares written out (no pow).
enum SnowboundCabinShaders {
    static let source = SkyShaders.common + """
    struct CabinU {
        float4 a;        // keys top (NDC y), aspect, horizon (NDC y), time
        float4 rect;     // glass NDC x0, y0, x1, y1
        float4 b;        // night 0…1, fire (setting × flicker), flare (after the limiter), flare warmth 0…1
        float4 c;        // far cabin light 0…1, smoke 0…1, wind 0…1, mist
        float4 d;        // frame width (NDC x), sill height (NDC y), quality (0 Smooth), sparkle scale
        float4 light;    // the outside light rgb (the scene's average), snow
        float4 fire;     // the fire's colour rgb, the candle's flicker 0…1
        float4 e;        // the window's bar count, unused…
        float4 bars[19]; // the Window Kit's bars: lo, hi (window coordinates), kind (0 vertical, 1 horizontal)
        float4 owl;      // Excitement: an owl on the sill: its feet (NDC x, y), its height (NDC), shown 0/1
        float4 owl2;     // its head's turn (−1 … 1), its blink 0…1, how much of it shows 0…1, unused
        float4 star;     // a star through a break in the clouds: position (NDC x, y), strength 0…1, a pixel (NDC)
        float4 roar;     // the fire's roar (limited), the snow's whirl, the wind's gathering, unused
    };

    constant float2 cabinQuad[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

    float ch11(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }
    float ch21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }
    float cvn1(float x) {
        float i = floor(x), f = fract(x);
        float u = f * f * (3.0 - 2.0 * f);
        return mix(ch11(i), ch11(i + 1.0), u);
    }
    float cvn2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(ch21(i), ch21(i + float2(1, 0)), u.x), mix(ch21(i + float2(0, 1)), ch21(i + float2(1, 1)), u.x), u.y);
    }
    // A range of alpine peaks: in each cell a summit (random place and height, a steeper and a gentler flank); the
    // cones of the cell and its two neighbours meet in a smooth maximum, so valleys crease without seams. Returns the
    // height above the horizon and, through `nx` and `arete`, the face's sideways normal (arêtes and couloirs fanning
    // down from each summit, softening lower down) and how close the point is to a rocky arête near the top.
    float peaks(float sx, float sy, float horizon, float freq, float h0, float amp, float seed, float bands,
                thread float& nx, thread float& arete) {
        float cell0 = floor(sx * freq);
        float hs[3], nxs[3], ars[3];
        float hmax = -9.0;
        for (int j = 0; j < 3; j++) {
            float cell = cell0 + float(j - 1);
            float cx = (cell + 0.15 + 0.7 * ch11(cell + seed)) / freq;
            float pk = h0 + amp * (0.3 + 0.7 * ch11(cell * 1.7 + seed + 17.0));
            float dx = sx - cx;
            float side = dx < 0.0 ? -1.0 : 1.0;
            float s = amp * freq * (1.0 + 1.5 * ch11(cell + seed + (dx < 0.0 ? 31.0 : 47.0)));
            float dy = max(horizon + pk - sy, 1e-4);
            float a = saturate(atan(abs(dx) / dy) / atan(1.0 / s));       // 0 straight below the summit … 1 the crest
            float f = a * bands + (cvn1(dy * 7.0 + cell * 3.3 + side * 5.0) - 0.5) + ch11(cell + side * 9.0) * 0.8;
            float t = fract(f);
            float tilt = (ch11(floor(f) * 7.1 + cell * 13.0 + side) - 0.5) * 0.4;
            float depthK = dy / max(pk, 1e-3);
            float gully = (t < 0.5 ? 1.0 : -1.0) * 0.6 * sin(t * M_PI_F) * (1.0 - 0.5 * smoothstep(0.05, 0.3, depthK));
            nxs[j] = side * (0.2 + 0.9 * a) + gully * side + tilt;
            ars[j] = (1.0 - smoothstep(0.0, 0.06, abs(t - 0.5))) * (1.0 - smoothstep(0.1, 0.45, depthK));
            hs[j] = pk - abs(dx) * s;
            hmax = max(hmax, hs[j]);
        }
        const float K = 0.012;
        float total = 0.0;
        for (int j = 0; j < 3; j++) total += exp((hs[j] - hmax) / K);
        float H = hmax + K * log(total);
        nx = 0.0; arete = 0.0;
        for (int j = 0; j < 3; j++) {
            float w = exp((hs[j] - H) / K);
            nx += w * nxs[j]; arete += w * ars[j];
        }
        return H;
    }

    // The pane around a window point and whether it's on a bar (as the Window Kit lays them out).
    float4 cabinPane(float2 w, constant CabinU& c, thread bool& onBar) {
        float4 p = float4(0, 0, 1, 1);
        onBar = false;
        int nBars = int(c.e.x);
        for (int i = 0; i < 19; i++) {
            if (i >= nBars) break;
            float4 bar = c.bars[i];
            if (bar.y <= bar.x) continue;
            float v = bar.z < 0.5 ? w.x : w.y;
            if (v >= bar.x && v <= bar.y) onBar = true;
            if (bar.z < 0.5) {
                if (bar.y <= w.x) p.x = max(p.x, bar.y);
                if (bar.x >= w.x) p.z = min(p.z, bar.x);
            } else {
                if (bar.y <= w.y) p.y = max(p.y, bar.y);
                if (bar.x >= w.y) p.w = min(p.w, bar.x);
            }
        }
        return p;
    }

    // One snowy pine at cx: coverage (soft-edged), through `snow` how much of the hit is snow on the boughs, and
    // through `rime` the rime fringe on its flanks (spec §6.4; `far` scales the depth: > 1 thins the fringe for a
    // distant row, < 1 widens it for a pine right outside the glass).
    float pine(float sx, float sy, float cx, float base, float ht, float wBase, float r, float far, constant SkyU& u,
               thread float& snow, thread float& rime) {
        snow = 0.0;
        rime = 0.0;
        float t = (sy - base) / ht;
        if (t < -0.1 || t > 1.0) return 0.0;
        float tier = fract(t * 6.0 + r);
        float w = (1.0 - t) * wBase * (0.6 + 0.4 * (1.0 - tier)) + wBase * 0.012;
        w *= 0.88 + 0.24 * cvn1(t * 40.0 + r * 13.0);             // ragged bough tips
        float dx = abs(sx - cx);
        float edge = max(0.0012, wBase * 0.012);
        float inTree = 1.0 - smoothstep(w - edge, w + edge, dx);
        if (t < 0.06) inTree = max(inTree, 1.0 - smoothstep(wBase * 0.05, wBase * 0.08, dx));
        float s = smoothstep(0.5, 0.85, tier) * smoothstep(0.15, 0.85, dx / max(w, 1e-4)) + smoothstep(0.86, 0.96, t);
        snow = saturate(s) * (0.55 + 0.45 * fract(r * 7.3));
        if (inTree > 0.0 && t >= 0.06) {
            // The boughs narrow upward (each tier and the whole tree): that taper tilts the flank's normal up.
            float taper = wBase / ht * (0.6 + 0.4 * (1.0 - tier) + 2.4 * (1.0 - t));
            float inside = (w - dx) * rsqrt(1.0 + taper * taper) * far;
            if (rimeNear(u, inside)) rime = rimeEdge(u, inside, float2(sx < cx ? -1.0 : 1.0, taper), float2(sx, sy));
        }
        return inTree;
    }

    // A row of snowy pines (some gaps): the nearest hit's coverage, snow and rime.
    float pines(float sx, float sy, float base, float height, float density, float seed, float gaps, float far,
                constant SkyU& u, thread float& snow, thread float& rime) {
        float cell = floor(sx * density + seed);
        float hit = 0.0;
        snow = 0.0;
        rime = 0.0;
        for (int k = -1; k <= 1; k++) {
            float id = cell + float(k);
            float r = ch11(id * 1.37 + seed);
            if (ch11(id * 3.71 + seed * 2.0) < gaps) continue;
            float cx = (id + 0.5 + (r - 0.5) * 0.6 - seed) / density;
            float ht = height * (0.55 + 0.6 * ch11(id * 2.11 + seed * 3.0));
            float sn, rm;
            float h = pine(sx, sy, cx, base, ht, 0.42 / density, r, far, u, sn, rm);
            if (h > hit) { hit = h; snow = sn; rime = rm; }
        }
        return hit;
    }

    // An owl perched on the drift at the foot of the glass (a surprise), in its own units (feet at 0, the top of its head
    // near 1), seen at night as an owl is: a dark, upright, tapering shape, its round head (no ear tufts) set on it with
    // no neck, the window's warm light faint on its front and its pale facial disc, the cold sky catching its crown and
    // shoulders, dark eyes with the window caught in them, faint streaks down its breast, the folded wings' edges. Soft
    // at its edge (a pixel's width: `px`, in the scene's units). `ambient` is the night's light on it (sky, moon, sun), `window` the cabin's.
    // Returns its colour and cover.
    float4 cabinOwl(float sx, float sy, float px, constant CabinU& c, float3 ambient, float3 window, float3 fireCol) {
        float4 o = c.owl;
        if (o.w < 0.5 || o.z < 1e-4) return float4(0.0);
        float aspect = c.a.y;
        float2 q = float2(sx - o.x * aspect, sy - o.y) / o.z;
        if (abs(q.x) > 0.5 || q.y < -0.02 || q.y > 1.08) return float4(0.0);
        float turn = c.owl2.x, blink = c.owl2.y;
        float aa = px / o.z + 1e-4;
        // The body: an egg, broadest at the shoulders, narrowing to the tail; the head: a flattened ball.
        float rx = 0.26 * (1.0 - 0.3 * smoothstep(0.42, 0.02, q.y));
        float2 bq = float2(q.x / rx, (q.y - 0.4) / 0.4);
        float2 hc = float2(0.02 * turn, 0.79);
        float2 hq = (q - hc) / float2(0.235, 0.2);
        float db = (length(bq) - 1.0) * rx, dh = (length(hq) - 1.0) * 0.2;
        float k = 0.06;
        float hm = saturate(0.5 + 0.5 * (dh - db) / k);
        float d = mix(dh, db, hm) - k * hm * (1.0 - hm);           // a smooth union: no neck
        d = max(d, 0.03 - q.y);                                    // its feet sunk in the snow
        float cover = (1.0 - smoothstep(-aa, aa, d)) * saturate(c.owl2.z);
        if (cover <= 0.0) return float4(0.0);
        // Its roundness (how squarely a point faces you), from the nearer of the two.
        float r = min(length(bq), length(hq));
        float nz = sqrt(saturate(1.0 - r * r));
        bool onHead = length(hq) < length(bq);
        float upper = onHead ? saturate(hq.y + 0.2) : saturate(bq.y + 0.1);
        float mottle = cvn2(q * 26.0 + float2(3.1, 7.7)) * 0.6 + cvn2(q * float2(60.0, 14.0)) * 0.4;
        float albedo = 0.075 * (0.8 + 0.4 * mottle);
        // Faint streaks down its breast, and the folded wings' darker edges.
        float streak = smoothstep(0.55, 0.85, cvn2(float2(q.x * 34.0, q.y * 5.0)));
        albedo *= onHead ? 1.0 : 1.0 - 0.3 * streak * nz;
        float wing = onHead ? 0.0 : smoothstep(0.55, 0.8, abs(bq.x)) * smoothstep(0.02, 0.25, q.y) * smoothstep(0.62, 0.45, q.y);
        albedo *= 1.0 - 0.35 * wing;
        float3 plumage = float3(1.0, 0.86, 0.7);
        float3 col = plumage * albedo * (ambient * (0.45 + 0.55 * nz) + window * (nz * nz) * 1.3);
        // The sky's cold light along its crown and shoulders.
        float rim = (1.0 - nz) * (1.0 - nz) * upper;
        col += ambient * float3(0.75, 0.85, 1.0) * (0.22 * rim);
        // The facial disc, its ruff, the eyes and the beak, turned with the head.
        float2 fc = float2(0.085 * turn, 0.775);
        float2 fd = (q - fc) / float2(0.19 * (1.0 - 0.3 * abs(turn)), 0.165);
        float fl = length(fd);
        float disc = 1.0 - smoothstep(0.82, 1.0, fl);
        float ruff = exp(-((fl - 1.0) * (fl - 1.0)) / 0.02);
        float3 face = float3(1.0, 0.9, 0.78) * 0.2 * (0.85 + 0.3 * mottle) * (ambient * 0.8 + window * 1.4);
        col = mix(col, face, disc * 0.85);
        col *= 1.0 - 0.45 * ruff;
        for (int e = -1; e <= 1; e += 2) {
            float2 eye = fc + float2(float(e) * 0.075 * (1.0 - 0.25 * abs(turn)), 0.025);
            float2 ed = (q - eye) / float2(0.042, 0.042 * (1.0 - 0.92 * blink) + 1e-3);
            float inEye = 1.0 - smoothstep(0.7, 1.0, length(ed));
            float2 gd = (q - eye - float2(0.012, 0.014)) / 0.01;
            float glint = exp(-dot(gd, gd)) * (1.0 - blink);
            col = mix(col, float3(0.006, 0.005, 0.004), inEye) + fireCol * window.r * (glint * 1.6);
        }
        float2 bk = (q - fc - float2(0.0, -0.06)) / float2(0.02, 0.035);
        col = mix(col, float3(0.32, 0.3, 0.26) * (ambient + window), 0.8 * (1.0 - smoothstep(0.6, 1.0, length(bk))));
        return float4(col, cover);
    }

    struct CabinOut { float4 pos [[position]]; float2 ndc; };

    vertex CabinOut cabin_glass_vertex(uint vid [[vertex_id]], constant CabinU& c [[buffer(1)]]) {
        float2 p = mix(c.rect.xy, c.rect.zw, cabinQuad[vid]);
        CabinOut o;
        o.pos = float4(p, 0, 1);
        o.ndc = p;
        return o;
    }

    vertex CabinOut cabin_full_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        CabinOut o;
        o.pos = float4(p[vid], 0, 1);
        o.ndc = p[vid];
        return o;
    }

    // ---------------------------------------------------------------- outside the window
    fragment ColorDepth cabin_scene_fragment(CabinOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant CabinU& c [[buffer(1)]],
                                          texture2d<float> stars [[texture(0)]]) {
        float2 ndc = in.ndc;
        float aspect = c.a.y, horizon = c.a.z, time = c.a.w;
        float sx = ndc.x * aspect, sy = ndc.y;
        float night = c.b.x, fire = c.b.y, mist = c.c.w, sparkle = c.d.w;
        float3 d = normalize(u.forward.xyz + u.right.xyz * ndc.x * u.right.w + u.up.xyz * ndc.y * u.up.w);
        float sunAlt = u.sun.w;
        float moonAlt = toDeg(asin(clamp(u.moon.z, -1.0, 1.0)));
        float cloud = u.horizon.w;
        float sunUp = smoothstep(-3.0, 6.0, sunAlt) * (1.0 - 0.75 * cloud);
        float moonUp = smoothstep(-2.0, 6.0, moonAlt) * u.moonInfo.x * (1.0 - 0.7 * cloud);
        float3 sunCol = mix(float3(1.0, 0.5, 0.28), float3(1.0, 0.95, 0.88), smoothstep(0.0, 25.0, sunAlt)) * 2.0 * sunUp;
        float3 moonCol = float3(0.55, 0.63, 0.82) * 0.32 * moonUp;
        float3 skyAmb = u.zenith.rgb * 0.55 + u.horizon.rgb * 0.45;
        float3 haze = u.horizon.rgb;
        // Light directions in camera space (x right, y up, z ahead).
        float3 Ls = float3(dot(u.sun.xyz, u.right.xyz), dot(u.sun.xyz, u.up.xyz), dot(u.sun.xyz, u.forward.xyz));
        float3 Lm = float3(dot(u.moon.xyz, u.right.xyz), dot(u.moon.xyz, u.up.xyz), dot(u.moon.xyz, u.forward.xyz));
        float3 fireCol = c.fire.rgb;
        float2 win = (ndc - c.rect.xy) / max(c.rect.zw - c.rect.xy, float2(1e-5));
        float glassBottom = c.rect.y;

        // ---- an owl on the sill, nearest of all (a surprise), lit by the sky and the window's own light at night
        if (c.owl.w > 0.5) {
            float3 owlAmbient = skyAmb * 1.1 + moonCol * 0.8 + sunCol * 0.4;
            float3 owlWindow = fireCol * fire * 0.45 * night;
            float px = max(fwidth(sx), fwidth(sy));
            float4 owl = cabinOwl(sx, sy, px, c, owlAmbient, owlWindow, fireCol);
            if (owl.a > 0.002) {
                // Its soft edge over the snow behind it (the drift and the field it sits against).
                float3 snow = float3(0.92, 0.95, 1.0) * (skyAmb * 0.95 + moonCol * 0.8 + sunCol * 0.35 + fireCol * fire * 0.3 * night);
                ColorDepth o; o.color = float4(mix(snow, owl.rgb, owl.a), 1); o.depth = float4(0.08, 0, 0, 1); return o;
            }
        }

        // ---- drifts banked against the panes (nearest of all)
        bool onBar;
        float4 pane = cabinPane(win, c, onBar);
        {
            float pu = (win.x - pane.x) / max(pane.z - pane.x, 1e-4);
            float ph = (win.y - pane.y) / max(pane.w - pane.y, 1e-4);
            float corner = max(max(0.0, 1.0 - pu / 0.32), max(0.0, 1.0 - (1.0 - pu) / 0.32));
            bool lowest = pane.y < 0.01;
            float lumpy = cvn1(pu * 9.0 + pane.x * 31.0) * 0.7 + cvn1(pu * 23.0 + pane.x * 7.0) * 0.3;
            float profile = lowest ? 0.03 + 0.15 * corner * corner + 0.035 * lumpy
                                   : 0.008 + 0.045 * corner * corner + 0.008 * lumpy;
            float edgeNoise = (cvn2(float2(pu * 60.0, ph * 60.0)) - 0.5) * 0.012;
            if (!onBar && ph < profile + edgeNoise) {
                float top = saturate((profile - ph) / 0.06);
                float3 snowLit = skyAmb * 1.0 + sunCol * 0.45 * saturate(Ls.y + 0.3) + moonCol * 0.8 + fireCol * fire * 0.22 * night;
                float grain = 0.94 + 0.06 * cvn2(float2(pu * 140.0, ph * 140.0));
                float3 col = float3(0.92, 0.95, 1.0) * snowLit * mix(1.0, 0.8, top) * grain;
                col = mix(col, col * float3(0.72, 0.84, 1.12), smoothstep(0.3, 1.0, top) * 0.55);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.1, 0, 0, 1); return o;
            }
        }

        float halfW = 0.5 * (c.rect.z - c.rect.x) * aspect;   // the window's half width in scene units
        float glassH = c.rect.w - glassBottom;
        float3 snowAmb = skyAmb * 0.95 + sunCol * saturate(Ls.y + 0.2) * 0.6 + moonCol;

        // ---- two big pines just outside, half in view at the window's edges (nearest after the drifts)
        for (int side = -1; side <= 1; side += 2) {
            float snow, rime;
            float hit = pine(sx, sy, float(side) * (halfW + 0.03), glassBottom - 0.04, glassH * 0.95, 0.19, side < 0 ? 0.31 : 0.77,
                             0.6, u, snow, rime);   // right outside the glass: a wider fringe (about 1% of the view)
            if (hit > 0.5) {
                float3 col = mix(float3(0.012, 0.022, 0.02) * (skyAmb * 1.4 + fireCol * fire * 0.25 * night),
                                 float3(0.92, 0.95, 1.0) * snowAmb * 0.95, snow);
                col = mix(col, rimeColor(u), rime);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.2, 0, 0, 1); return o;
            }
        }

        // ---- the ground: the snow field from the window out to the forest's edge
        float groundTop = horizon - 0.014 + 0.007 * sin(sx * 3.1);
        if (sy < groundTop) {
            float t = saturate((groundTop - sy) / max(groundTop - glassBottom, 1e-3));   // 0 far … 1 near
            float persp = 0.2 + t;
            float n = cvn2(float2(sx * 3.5, sy * 20.0 / persp)) * 0.65 + cvn2(float2(sx * 9.0, sy * 52.0 / persp) + 3.7) * 0.35;
            // Gentle drifts: lit faces toward the sun or moon, blue hollows away from them.
            float lit = saturate(0.55 + (n - 0.5) * 1.4);
            float3 col = float3(0.92, 0.95, 1.0) * (skyAmb * 0.9 + sunCol * 0.45 * saturate(Ls.y * 0.8 + 0.2) * (0.55 + 0.45 * lit)
                                                     + moonCol * saturate(Lm.y * 0.8 + 0.3) * (0.6 + 0.4 * lit));
            col = mix(col * float3(0.7, 0.82, 1.12), col, lit);
            // Glints: a facet per 2 px, catching the sun or moon when it's tilted just right.
            if (t > 0.04) {
                float2 cell = floor(in.pos.xy * 0.5);
                float3 h = hash33(float3(cell, 1.0));
                float3 nf = normalize(float3((h.x - 0.5) * 0.8, 1.0, (h.y - 0.5) * 0.8));
                float3 V = -normalize(float3(ndc.x * u.right.w, ndc.y * u.up.w, 1.0));
                float tw = 0.6 + 0.4 * sin(time * (1.5 + 3.0 * h.z) + h.z * 40.0);
                float gs = smoothstep(0.994, 1.0, dot(nf, normalize(Ls + V))) * sunUp;
                float gm = smoothstep(0.995, 1.0, dot(nf, normalize(Lm + V))) * moonUp;
                col += (float3(1.0, 0.95, 0.85) * gs * 5.0 + float3(0.75, 0.82, 1.0) * gm * 2.5) * tw * sparkle * smoothstep(0.04, 0.3, t);
            }
            // The frozen creek, winding across the field: narrow, half snowed over, mirroring the sky.
            float yc = glassBottom + (groundTop - glassBottom) * (0.5 + 0.13 * sin(sx * 2.1 + 0.7) + 0.06 * sin(sx * 5.3 + 2.0));
            float hw = (0.0025 + 0.014 * t) * (0.6 + 0.4 * sin(sx * 7.0 + 1.3));
            float off = abs(sy - yc);
            if (off < hw * 1.6 && d.z < 0.0) {
                float3 r = float3(d.x, d.y, -d.z);
                float moonMask = 0.0;
                float3 ice = skyRadiance(r, u, moonMask, stars) * 0.35 + float3(0.62, 0.72, 0.82) * (skyAmb * 0.8 + sunCol * 0.25 + moonCol * 0.5);
                float crack = 1.0 - smoothstep(0.0, 0.035, abs(cvn2(float2(sx * 38.0, sy * 140.0)) - 0.5));
                ice *= 1.0 - 0.25 * crack;
                float snowed = smoothstep(0.55, 0.7, cvn2(float2(sx * 16.0, sy * 50.0 / persp) + 4.4));
                float bank = smoothstep(hw * 0.6, hw, off);
                float3 rim = col * 1.12;
                col = off < hw ? mix(mix(ice, col, snowed), rim, bank) : mix(rim, col, smoothstep(hw, hw * 1.6, off));
            }
            // At night the window's light falls on the snow below it, with the bars' shadows.
            float poolH = 0.5 * (groundTop - glassBottom);
            float pw = (sy - glassBottom) / max(poolH, 1e-3);
            if (night > 0.01 && pw < 1.0) {
                float pu = 0.5 + (win.x - 0.5) / (0.85 + 0.5 * pw);
                bool poolBar;
                cabinPane(float2(pu, 0.08 + 0.9 * pw), c, poolBar);
                float inside = (poolBar ? 0.08 : 1.0) * smoothstep(0.0, 0.05, pu) * smoothstep(1.0, 0.95, pu) * smoothstep(1.0, 0.8, pw);
                col += fireCol * fire * 0.9 * night * inside * (1.0 - 0.5 * pw) * float3(1.0, 0.88, 0.75);
            }
            col = mix(col, haze * 1.02, (1.0 - t) * (0.1 + 0.4 * mist));
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.3 + 0.4 * (1.0 - t), 0, 0, 1); return o;
        }

        // ---- the near row of pines along the far edge of the field
        float farLight = c.c.x;
        float s3, s2, s1, r3, r2, r1;
        float p3 = pines(sx, sy, groundTop - 0.008, 0.2, 5.5, 7.31, 0.35, 1.25, u, s3, r3);
        if (p3 > 0.5) {
            float3 col = mix(float3(0.016, 0.028, 0.027) * (skyAmb * 1.3 + fireCol * fire * 0.15 * night), float3(0.92, 0.95, 1.0) * snowAmb, s3);
            col = mix(col, rimeColor(u), r3);
            col = mix(col, haze, 0.08 + 0.3 * mist);
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.55, 0, 0, 1); return o;
        }
        // ---- the far cabin, its lit window and its chimney, in front of the middle row
        float cabX = halfW * 0.38, cabBase = horizon - 0.012, cabW = 0.09, cabH = 0.04;
        {
            float cx = sx - cabX, cy = sy - cabBase;
            float roof = cabH + 0.032 * (1.0 - abs(cx) / (cabW * 0.62));
            bool body = abs(cx) < cabW * 0.5 && cy > 0.0 && cy < cabH;
            bool roofHit = abs(cx) < cabW * 0.62 && cy >= cabH && cy < roof;
            bool chimney = cx > -cabW * 0.34 && cx < -cabW * 0.2 && cy >= cabH && cy < cabH + 0.04;
            if (body || roofHit || chimney) {
                float logs = 0.75 + 0.25 * step(0.5, fract(cy / 0.008));
                float3 col = float3(0.07, 0.045, 0.03) * logs * (skyAmb * 1.3 + sunCol * 0.35 * saturate(Ls.x * 0.5 + 0.5));
                if (roofHit) col = float3(0.92, 0.95, 1.0) * snowAmb * (0.75 + 0.25 * saturate((cy - cabH) / 0.03));
                if (chimney && !roofHit) col = float3(0.08, 0.07, 0.07) * skyAmb * 1.5;
                bool window = body && abs(cx - 0.012) < 0.011 && cy > cabH * 0.3 && cy < cabH * 0.75;
                if (window) {
                    float muntin = step(0.0015, abs(cx - 0.012)) * step(0.0015, abs(cy - cabH * 0.525));
                    col = farLight > 0.01 ? float3(1.0, 0.68, 0.32) * 2.6 * farLight * muntin + float3(0.03, 0.02, 0.015)
                                          : float3(0.05, 0.06, 0.08) * skyAmb * 3.0;
                }
                col = mix(col, haze, 0.15 + 0.3 * mist);
                ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.62, 0, 0, 1); return o;
            }
        }
        // The far cabin's window glows into the snow and the trees around it at night.
        float2 glowD = float2((sx - cabX - 0.012) * 0.8, sy - cabBase - cabH * 0.5);
        float cabinGlow = farLight * exp(-dot(glowD, glowD) * 260.0) * 0.4;
        float p2 = pines(sx, sy, horizon - 0.01, 0.11, 10.0, 3.17, 0.15, 1.6, u, s2, r2);
        if (p2 > 0.5) {
            float3 col = mix(float3(0.02, 0.034, 0.034) * skyAmb * 1.2, float3(0.9, 0.94, 1.0) * snowAmb * 0.92, s2);
            col = mix(col, rimeColor(u), r2);
            col = mix(col, haze * 0.95, 0.2 + 0.35 * mist) + float3(1.0, 0.65, 0.3) * cabinGlow;
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.7, 0, 0, 1); return o;
        }
        // A strip of snow between the rows, glowing round the far cabin at night.
        if (sy < horizon - 0.006) {
            float3 col = float3(0.9, 0.93, 1.0) * snowAmb * 0.95 + float3(1.0, 0.65, 0.3) * cabinGlow * 1.5;
            col = mix(col, haze, 0.25 + 0.35 * mist);
            ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.72, 0, 0, 1); return o;
        }
        float p1 = pines(sx, sy, horizon + 0.002, 0.06, 18.0, 1.93, 0.05, 2.2, u, s1, r1);
        float3 behind = float3(0);
        float behindA = 0.0;
        float behindDepth = 1.0;
        if (p1 > 0.5) {
            float3 col = mix(float3(0.03, 0.045, 0.05) * skyAmb, float3(0.88, 0.92, 1.0) * snowAmb * 0.85, s1);
            col = mix(col, rimeColor(u), r1);
            behind = mix(col, haze * 0.95, 0.4 + 0.3 * mist);
            behindA = 1.0; behindDepth = 0.78;
        } else {
            // ---- the mountains: a near ridge with forest on its lower slopes, then a high far range in deeper haze
            for (int k = 0; k < 2; k++) {
                float seed = k == 0 ? 7.7 : 3.1;
                float freq = k == 0 ? 1.5 : 0.9;
                float h0 = k == 0 ? 0.03 : 0.07;
                float amp = k == 0 ? 0.16 : 0.3;
                float nx, arete;
                float peak = peaks(sx, sy, horizon, freq, h0, amp, seed, k == 0 ? 3.0 : 2.0, nx, arete);
                // A ragged crest: two folded octaves of fine roughness on the cones.
                float rough = (1.0 - abs(2.0 * cvn1(sx * freq * 11.0 + seed) - 1.0)) * 0.6
                            + (1.0 - abs(2.0 * cvn1(sx * freq * 29.0 + seed * 2.0) - 1.0)) * 0.4;
                float top = horizon + max(peak, h0 * 0.4) + amp * 0.04 * rough;
                if (sy < top) {
                    float below = top - sy;
                    float frac = saturate(below / max(top - horizon, 1e-3));     // 0 at the crest … 1 at the foot
                    // Faces turn with the flanks of each summit, creased by the arêtes and couloirs fanning down.
                    float3 n = normalize(float3(nx, 0.75, 0.6));
                    float sunFace = dot(n, Ls), moonFace = dot(n, Lm);
                    float rock = saturate(arete * 0.85);
                    float3 albedo = mix(float3(0.9, 0.93, 1.0), float3(0.28, 0.26, 0.27), rock);
                    float3 col = albedo * (skyAmb * 0.65 + sunCol * 1.0 * saturate(sunFace) + moonCol * 1.6 * saturate(moonFace));
                    col *= mix(float3(0.62, 0.74, 1.05), float3(1.0), saturate(max(sunFace * sunUp, moonFace * moonUp) * 2.5 + 0.3));
                    // Alpenglow: the peaks catch the low sun pink-orange, from just before sunrise to a little after.
                    float alpen = smoothstep(-2.5, -0.5, sunAlt) * (1.0 - smoothstep(5.0, 8.0, sunAlt)) * (1.0 - 0.6 * cloud);
                    col += float3(1.0, 0.42, 0.32) * alpen * 0.85 * (1.0 - smoothstep(0.1, 0.7, frac)) * saturate(sunFace + 0.6);
                    if (k == 0) {
                        // Forest on the near ridge's lower slopes, with a ragged tree line.
                        float line = 0.62 + 0.1 * (cvn1(sx * 9.0 + 2.0) - 0.5) + 0.05 * (cvn1(sx * 31.0) - 0.5);
                        float forest = smoothstep(line - 0.02, line + 0.02, frac);
                        float specks = smoothstep(0.55, 0.8, cvn2(float2(sx * 90.0, sy * 160.0)));
                        float3 trees = mix(float3(0.03, 0.045, 0.045) * skyAmb * 1.3, float3(0.85, 0.9, 1.0) * snowAmb * 0.8, specks * 0.6);
                        col = mix(col, trees, forest * 0.9);
                    }
                    col = mix(col, haze, (k == 0 ? 0.14 : 0.3) + 0.35 * mist);
                    behind = col; behindA = 1.0; behindDepth = k == 0 ? 0.85 : 0.92;
                    break;
                }
            }
        }
        // ---- the far cabin's chimney smoke, leaning with the wind, over whatever is behind it
        float smoke = 0.0;
        {
            float chimX = cabX - cabW * 0.27, chimTop = cabBase + cabH + 0.04;
            float rise = sy - chimTop;
            if (rise > 0.0 && rise < 0.36) {
                float centre = chimX + rise * (0.12 + 0.8 * c.c.z) + 0.015 * sin(rise * 18.0 - time * 0.7);
                float width = 0.006 + rise * 0.16;
                float q = (sx - centre) / width;
                float body = exp(-q * q);
                float n = cvn2(float2(sx * 26.0, sy * 26.0 - time * 0.45)) * 0.55 + cvn2(float2(sx * 55.0, sy * 55.0 - time * 0.8) + 5.1) * 0.3
                        + cvn2(float2(sx * 110.0, sy * 110.0 - time * 1.3) + 9.3) * 0.15;
                smoke = body * smoothstep(0.2, 0.7, n) * (1.0 - smoothstep(0.1, 0.36, rise)) * smoothstep(0.0, 0.012, rise) * c.c.y * 0.9;
            }
        }
        float3 smokeCol = skyAmb * 1.15 + sunCol * 0.3 + moonCol * 0.6 + float3(1.0, 0.65, 0.3) * cabinGlow * 0.5;
        float3 col = behind * behindA * (1.0 - smoke) + smokeCol * smoke;
        float a = 1.0 - (1.0 - behindA) * (1.0 - smoke);
        // The cabin's glow also hazes the air (and sky) around it.
        col += float3(1.0, 0.65, 0.3) * cabinGlow * 0.5;
        // A star through a break in the clouds (a surprise): the cloud parts round it and it shines through, twinkling
        // low in the cold air.
        float4 st = c.star;
        if (st.z > 0.001 && behindA < 0.5) {
            float2 sd = float2(sx - st.x * aspect, sy - st.y);
            float r = length(sd);
            float ragged = cvn2(float2(sx, sy) * 9.0 + 3.7) - 0.5;
            float clear = (1.0 - smoothstep(0.05, 0.15, r + 0.05 * ragged)) * st.z * cloud;
            float3 clearSky = u.zenith.rgb * 0.6;
            float tw = 0.72 + 0.28 * sin(time * 9.0) * sin(time * 13.7 + 1.0);
            float px = max(st.w, 1e-4);
            float core = exp(-dot(sd, sd) / (px * px * 1.6));
            float halo = exp(-r / (px * 5.0)) * 0.12;
            float3 starLight = float3(0.92, 0.95, 1.0) * ((core * 2.4 + halo) * tw * st.z);
            col = col * (1.0 - clear) + clearSky * clear + starLight;
            a = max(a, clear);
        }
        if (a < 0.003 && cabinGlow < 0.003 && st.z < 0.001) discard_fragment();
        ColorDepth o; o.color = float4(col, max(a, 0.0)); o.depth = float4(behindA > 0.5 ? behindDepth : 0.9, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- high notes: flakes by the glass catch the light
    struct Spark { float4 a; };   // x, y (NDC), size (NDC x), brightness
    struct SparkOut { float4 pos [[position]]; float2 uv; float bright; };
    vertex SparkOut cabin_spark_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Spark* ss [[buffer(0)]],
                                       constant CabinU& c [[buffer(1)]]) {
        float2 q = cabinQuad[vid] * 2.0 - 1.0;
        Spark s = ss[iid];
        SparkOut o;
        o.uv = q;
        o.pos = float4(s.a.xy + q * float2(s.a.z, s.a.z * c.a.y), 0, 1);
        o.bright = s.a.w;
        return o;
    }
    fragment float4 cabin_spark_fragment(SparkOut in [[stage_in]], constant CabinU& c [[buffer(1)]]) {
        float2 p = in.uv;
        float r = length(p);
        float rays = exp(-abs(p.x) * 18.0) * exp(-abs(p.y) * 2.2) + exp(-abs(p.y) * 18.0) * exp(-abs(p.x) * 2.2);
        float core = exp(-r * r * 30.0);
        float a = saturate(rays * 0.6 + core) * (1.0 - smoothstep(0.7, 1.0, r)) * in.bright;
        float3 col = mix(float3(0.85, 0.9, 1.0), c.fire.rgb, 0.35) * 2.2;
        return float4(col * a, 0.0);
    }

    // ---------------------------------------------------------------- the room: log walls and the sill
    fragment ColorDepth cabin_room_fragment(CabinOut in [[stage_in]], constant SkyU& u [[buffer(0)]], constant CabinU& c [[buffer(1)]]) {
        float2 p = in.ndc;
        float aspect = c.a.y, time = c.a.w;
        float fw = c.d.x, fh = c.d.x * aspect;
        float4 outer = c.rect + float4(-fw, -fh, fw, fh);
        float sx = p.x * aspect, sy = p.y;
        // The candle jar and the mug stand on the sill in front of the window's lower frame; the rest of the
        // window belongs to the glass and frame.
        float sillTopY = outer.y;
        float2 jarP = float2(sx - (outer.x + 0.17) * aspect, sy - (sillTopY - 0.012));
        float2 mugP = float2(sx - (outer.z - 0.2) * aspect, sy - (sillTopY - 0.014));
        bool overWindow = p.x > outer.x && p.x < outer.z && p.y > outer.y && p.y < outer.w;
        bool mayHit = (abs(jarP.x) < 0.056 && jarP.y > 0.0 && jarP.y < 0.17) || (mugP.x > -0.052 && mugP.x < 0.1 && mugP.y > 0.0 && mugP.y < 0.1);
        if (overWindow && !mayHit) discard_fragment();
        float night = c.b.x, fire = c.b.y, flare = c.b.z;
        float3 fireCol = c.fire.rgb;
        // Firelight from low and to the left (off screen), flickering; chords flare it.
        float2 firePos = float2(-1.3 * aspect, -1.2);
        float2 fv = float2(sx, sy) - firePos;
        float3 fireLight = fireCol * fire * (1.0 + 0.8 * flare) * (1.5 / (1.0 + dot(fv, fv) * 0.55));
        // Daylight or moonlight spilling in around the window.
        float2 nearest = clamp(p, outer.xy, outer.zw);
        float wd = length((p - nearest) * float2(aspect, 1.0));
        float3 winLight = c.light.rgb * 0.5 * exp(-wd * 3.5);
        float3 ambient = c.light.rgb * 0.03 + fireCol * fire * 0.025;

        // The candle in its jar, on the sill to the left, and its glow.
        float sillTop = outer.y, sillH = c.d.y;
        float candleX = (outer.x + 0.17) * aspect, candleBase = sillTop - 0.012;
        float flick = c.fire.w;
        float2 flameC = float2(candleX + 0.003 * sin(time * 9.0), candleBase + 0.112 + 0.006 * flick);
        float2 fd = float2(sx, sy) - flameC;
        float3 candleLight = float3(1.0, 0.62, 0.28) * (0.75 + 0.35 * flick) * (0.12 / (0.006 + dot(fd, fd) * 2.2));

        float3 col;
        float depth = 0.05;
        float sillX0 = (outer.x - 0.06) * aspect, sillX1 = (outer.z + 0.06) * aspect;
        bool onSill = sy <= sillTop && sy > sillTop - sillH && sx > sillX0 && sx < sillX1;
        if (onSill) {
            // A thick plank: a lit top face, a darker front face, varnished grain.
            float topFace = sillTop - 0.045;
            float grain = cvn2(float2(sx * 2.5, sy * 60.0)) * 0.6 + cvn2(float2(sx * 9.0, sy * 140.0) + 2.3) * 0.4;
            float3 albedo = mix(float3(0.26, 0.15, 0.08), float3(0.45, 0.29, 0.16), grain);
            float lit = sy > topFace ? 1.0 : 0.45;
            col = albedo * (fireLight * lit + winLight * (sy > topFace ? 1.6 : 0.4) + ambient + candleLight * lit);
            if (sy > topFace && sy < topFace + 0.004) col *= 1.25;   // the front edge catches the light
        } else {
            // Log walls: rounded logs with dark chinking between them, lit by the fire and the window.
            float logH = 0.13;
            float row = floor((sy + 0.03) / logH);
            float v = fract((sy + 0.03) / logH);
            float across = v * 2.0 - 1.0;
            float nz = sqrt(saturate(1.0 - across * across));
            float3 n = float3(0.0, across, nz);
            float diff = saturate(dot(n, normalize(float3(-0.4, -0.55, 0.75))));
            float grain = cvn2(float2(sx * 3.0, row * 7.1 + across * 2.0)) * 0.6 + cvn2(float2(sx * 11.0, row * 3.3 + v * 4.0)) * 0.4;
            float knot = smoothstep(0.92, 0.97, cvn2(float2(sx * 6.0 + row * 13.0, row * 1.7)));
            float3 albedo = mix(float3(0.17, 0.095, 0.05), float3(0.32, 0.19, 0.1), grain) * (1.0 - 0.5 * knot);
            float chink = smoothstep(0.86, 0.97, abs(across));
            albedo = mix(albedo, float3(0.24, 0.22, 0.19), chink * 0.8);
            col = albedo * (fireLight * (0.3 + 0.7 * diff) + winLight * (0.5 + 0.5 * nz) + ambient) * (1.0 - 0.45 * chink);
            col += albedo * candleLight * 0.6;
            depth = 0.06;
        }

        // On the sill: the candle jar and a mug.
        float jarW = 0.055, jarH = 0.14;
        float2 jp = float2(sx - candleX, sy - candleBase);
        if (abs(jp.x) < jarW && jp.y > 0.0 && jp.y < jarH) {
            float edge = smoothstep(jarW - 0.008, jarW, abs(jp.x));
            float3 glass = (winLight + fireLight * 0.4) * 0.25 + float3(1.0, 0.62, 0.28) * (0.35 + 0.2 * flick) * (1.0 - jp.y / jarH);
            bool wax = abs(jp.x) < jarW - 0.012 && jp.y < 0.075;
            float3 waxCol = float3(0.9, 0.82, 0.68) * (float3(1.0, 0.62, 0.28) * (0.7 + 0.3 * flick) * (0.4 + jp.y / 0.075) + ambient);
            col = wax ? waxCol : mix(col, col * 0.6 + glass, 0.55) + float3(0.6, 0.62, 0.65) * edge * 0.25 * (0.3 + night);
            if (jp.y > jarH - 0.009) col += float3(0.5) * 0.15;   // the rim
        }
        // The flame: a small teardrop, bright core.
        float2 fq = float2(fd.x / 0.011, (fd.y + 0.01) / (0.03 + 0.01 * flick));
        float flame = 1.0 - smoothstep(0.6, 1.0, length(float2(fq.x * (1.0 + 0.6 * saturate(fq.y)), fq.y)));
        col = mix(col, float3(1.0, 0.55, 0.15) * 4.0 + float3(1.0, 0.95, 0.75) * 5.0 * smoothstep(0.4, 1.0, flame), flame);

        float mugX = (outer.z - 0.2) * aspect, mugBase = sillTop - 0.014;
        float2 mp = float2(sx - mugX, sy - mugBase);
        float mugW = 0.05, mugH = 0.095;
        float ring = abs(length(float2(mp.x - mugW - 0.006, mp.y - mugH * 0.5)) - 0.026);
        bool handle = ring < 0.008 && mp.x > mugW - 0.003;
        bool mugBody = abs(mp.x) < mugW && mp.y > 0.0 && mp.y < mugH;
        if (mugBody || handle) {
            float shade = mugBody ? sqrt(saturate(1.0 - (mp.x / mugW) * (mp.x / mugW))) : 0.6;
            float3 glaze = float3(0.62, 0.2, 0.16);
            col = glaze * (fireLight * (0.35 + 0.65 * shade * saturate(0.5 - mp.x / mugW)) + winLight * 0.8 + ambient + candleLight * 0.5);
            col += float3(1.0) * smoothstep(0.85, 1.0, shade) * 0.05 * (0.3 + night);
            if (mugBody && mp.y > mugH - 0.008) col *= 0.5;
        }
        // Soft contact shadows on the sill.
        if (onSill) {
            float sj = exp(-(jp.x * jp.x) / 0.005) * exp(-max(0.0, -jp.y) * 45.0) * step(jp.y, 0.0);
            float sm = exp(-(mp.x * mp.x) / 0.005) * exp(-max(0.0, -mp.y) * 45.0) * step(mp.y, 0.0);
            col *= 1.0 - 0.4 * saturate(sm) - 0.2 * saturate(sj);
        }
        // Over the window only the jar, its flame and the mug are drawn.
        bool objectHit = (abs(jp.x) < jarW && jp.y > 0.0 && jp.y < jarH) || mugBody || handle || flame > 0.05;
        if (overWindow && !objectHit) discard_fragment();
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(depth, 0, 0, 1);
        return o;
    }

    // ---------------------------------------------------------------- keys: ember amber where you play
    struct CabinKey { float4 rect; float4 info; };   // rect NDC; info: black, glow, pressed, light
    struct CabinKeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex CabinKeyOut cabin_keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant CabinKey* keys [[buffer(0)]]) {
        CabinKey k = keys[iid];
        CabinKeyOut o;
        o.uv = cabinQuad[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }
    fragment ColorDepth cabin_keys_fragment(CabinKeyOut in [[stage_in]], constant CabinU& c [[buffer(1)]]) {
        bool black = in.info.x > 0.5;
        float glow = in.info.y, pressed = in.info.z, light = in.info.w;
        float3 base = black ? float3(0.012, 0.009, 0.008) : float3(0.11, 0.085, 0.065);
        float y2 = in.uv.y * in.uv.y;
        float y6 = y2 * y2 * y2;
        float sheen = y6 * (black ? 0.05 : 0.12) * (1.0 - 0.5 * pressed);
        float edge = smoothstep(0.0, 0.06, in.uv.x) * smoothstep(1.0, 0.94, in.uv.x);
        float3 ember = float3(1.0, 0.42, 0.12);
        float3 col = base * (c.fire.rgb * c.b.y * 0.6 + light) + float3(0.9, 0.75, 0.6) * sheen * (0.3 + 0.6 * light)
                   + ember * glow * (1.8 * (0.3 + 0.7 * in.uv.y));
        col *= 0.55 + 0.45 * edge;
        ColorDepth o; o.color = float4(col, 1); o.depth = float4(0.05, 0, 0, 1);
        return o;
    }
    """
}
