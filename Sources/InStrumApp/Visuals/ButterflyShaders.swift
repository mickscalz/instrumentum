/// Butterfly Garden: sky, sun and god-rays, foliage, meadow, blooms, butterflies,
/// pollen/petals/fireflies and keys. All procedural (no image files).
/// Scene space: x 0...1 across, y 0...1 up (above the keyboard), z depth 0 near ... 1 far.
enum ButterflyShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SceneU {
        float4 a;          // resolution.x, resolution.y, time, keyTop (0...1 of screen height)
        float4 sun;        // sunX, sunY (0...1 screen), rays, mist
        float4 skyTop;     // rgb, night (0/1)
        float4 skyMid;     // rgb, unused
        float4 skyHorizon; // rgb, foliage
        float4 air;        // breezeX, pollen, petals, fireflies
        float4 cam;        // zoom, camX, camY, parallax
        float4 look;       // iridescence, shimmer, trailGlow, keysShow
        float4 counts;     // pollenCount, petalCount, fireflyCount, exposureHint
        float4 keyGlow;    // rgb, finish index
        float4 perf;       // shaftSteps, noiseOctaves (by quality), drops on the glass (count), rain on the glass 0…1
    };

    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };

    // ---------- helpers ----------
    float hash11(float n) { return fract(sin(n * 127.1) * 43758.5453); }
    float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }
    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.03 + 17.0; a *= 0.5; }
        return v;
    }
    float fbmN(int oct, float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < oct; i++) { v += a * noise(p); p = p * 2.03 + 17.0; a *= 0.5; }
        return v + a * 0.5;   // keep the average brightness when octaves are dropped
    }
    float3 hsv(float h, float s, float v) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return v * mix(float3(1.0), k, s);
    }
    // Scene (x, y, z) → clip space, with zoom, camera drift and parallax.
    float2 toClip(float3 p, constant SceneU& u) {
        float depthScale = 1.0 + (0.5 - p.z) * u.cam.w * 0.35;
        float sx = (p.x - 0.5) * depthScale * u.cam.x + 0.5 + u.cam.y * (1.0 - p.z);
        float keyTop = u.a.w;
        float sy = keyTop + p.y * (1.0 - keyTop);
        sy = (sy - 0.5) * u.cam.x + 0.5 + u.cam.z * (1.0 - p.z);
        return float2(sx * 2.0 - 1.0, sy * 2.0 - 1.0);
    }

    // ---------- sky, sun, god-rays, foliage, meadow (fullscreen) ----------
    struct SkyOut { float4 pos [[position]]; float2 uv; };
    vertex SkyOut sky_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut o; o.pos = float4(p[vid], 0, 1); o.uv = (p[vid] + 1.0) * 0.5; return o;
    }

    // x = distant tree line, y = overhanging canopy (0...1 each)
    float2 foliageMask(float2 uv, constant SceneU& u, float t, int oct) {
        float d = u.skyHorizon.w;
        float aspect = u.a.x / u.a.y;
        float x = uv.x * aspect;
        float keyTop = u.a.w;
        float horizon = keyTop + (1.0 - keyTop) * 0.2;
        // tree crowns: rounded bumps of varied size, with leafy fuzz along the edge
        float cell = floor(x * 7.0);
        float fx = fract(x * 7.0) - 0.5;
        float crown = 0.0;
        for (int k = -1; k <= 1; k++) {
            float c = cell + float(k);
            float hgt = 0.35 + 0.65 * hash11(c * 3.7);
            float wid = 0.45 + 0.4 * hash11(c * 9.1);
            float dx = (fx - float(k)) / wid;
            crown = max(crown, hgt * sqrt(max(0.0, 1.0 - dx * dx)));
        }
        float fuzz = (fbmN(oct, float2(x * 40.0, uv.y * 40.0)) - 0.5) * 0.025;
        float line = horizon + (0.03 + 0.11 * crown) * (0.35 + d) + fuzz;
        float back = step(keyTop, uv.y) * smoothstep(line + 0.003, line - 0.003, uv.y);
        float sway = 0.012 * sin(t * 0.6) + 0.02 * u.air.x * sin(t * 0.9 + uv.y * 3.0);
        float leafNoise = fbmN(oct, float2(x * 6.0 + sway * 8.0, uv.y * 6.0)) + (fbmN(oct, float2(x * 34.0, uv.y * 34.0) + sway * 20.0) - 0.5) * 0.35;
        float reach = 0.22 + 0.33 * d;
        float rL = length((uv - float2(0.0, 1.06)) * float2(aspect * 0.55, 1.0));
        float rR = length((uv - float2(1.0, 1.06)) * float2(aspect * 0.55, 1.0));
        float canopy = max(smoothstep(reach + 0.015, reach - 0.015, rL + (leafNoise - 0.5) * 0.5),
                           smoothstep(reach + 0.015, reach - 0.015, rR + (fbmN(oct, float2(x * 6.0 + 9.0 - sway * 8.0, uv.y * 6.0)) - 0.5) * 0.5));
        float holes = smoothstep(0.62, 0.7, fbmN(oct, float2(x * 22.0, uv.y * 22.0) + sway * 4.0));
        canopy *= 1.0 - holes * 0.95;
        return float2(back, canopy);
    }

    fragment ColorDepth sky_fragment(SkyOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float t = u.a.z;
        float aspect = u.a.x / u.a.y;
        float keyTop = u.a.w;
        float night = u.skyTop.w;
        int oct = int(u.perf.y);
        int steps = int(u.perf.x);
        float h = clamp((uv.y - keyTop) / (1.0 - keyTop), 0.0, 1.0);
        float3 col = h < 0.38 ? mix(u.skyHorizon.rgb, u.skyMid.rgb, smoothstep(0.0, 0.38, h))
                              : mix(u.skyMid.rgb, u.skyTop.rgb, smoothstep(0.38, 1.0, h));
        // wispy clouds, lit from below at golden hour
        float clouds = fbmN(oct, float2(uv.x * aspect * 2.2 + t * 0.008, uv.y * 7.0 - t * 0.002));
        float cloudMask = smoothstep(0.58, 0.82, clouds) * smoothstep(0.3, 0.6, h);
        col = mix(col, mix(u.skyMid.rgb, float3(1.0, 0.92, 0.85), 0.5) * (1.0 - night * 0.8) + 0.02, cloudMask * 0.55);
        // sun or moon
        float2 sp = float2(u.sun.x, u.sun.y);
        float2 dv = (uv - sp) * float2(aspect, 1.0);
        float r = length(dv);
        float3 sunCol = mix(float3(1.0, 0.85, 0.58), float3(0.8, 0.88, 1.0), night);
        float disc = smoothstep(0.042, 0.036, r);
        col += sunCol * (disc * (night > 0.5 ? 2.2 : 6.0) + exp(-r * 5.0) * (night > 0.5 ? 0.35 : 1.1) + exp(-r * 1.6) * 0.2);
        // stars
        if (night > 0.5) {
            float2 g = floor(uv * float2(aspect, 1.0) * 160.0);
            float star = step(0.9965, hash21(g)) * (0.6 + 0.4 * sin(t * 2.0 + hash21(g + 3.0) * 30.0));
            col += float3(0.9, 0.95, 1.0) * star * 1.8 * smoothstep(0.25, 0.6, h);
        }
        // light beams through the leaves
        float2 fm = foliageMask(uv, u, t, oct);
        if (u.sun.z > 0.01) {
            float lit;
            if (steps > 0) {
                // March toward the sun through the leaves (cheap noise unless Ultra).
                int marchOct = steps >= 28 ? oct : 2;
                float2 stepv = (sp - uv) / float(steps);
                float2 p = uv;
                float decay = 1.0, total = 0.0;
                lit = 0.0;
                for (int i = 0; i < steps; i++) {
                    p += stepv;
                    float2 m = foliageMask(p, u, t, marchOct);
                    lit += (1.0 - max(m.x, m.y)) * decay;
                    total += decay;
                    decay *= 0.95;
                }
                lit = lit / max(total, 1e-3) * 1.1;
            } else {
                lit = 0.9 * (1.0 - max(fm.x, fm.y));   // Smooth: no march
            }
            float ang = atan2(dv.y, dv.x);
            float beams = pow(0.5 + 0.5 * sin(ang * 13.0 + fbmN(oct, float2(ang * 3.0, t * 0.03)) * 6.0), 5.0);
            float shafts = lit * (0.25 + beams * 0.9) * exp(-r * 1.5);
            col += sunCol * shafts * u.sun.z * (night > 0.5 ? 0.55 : 0.9) * (1.0 - fm.y * 0.7);
        }
        // tree line (hazy, aerial perspective) and canopy (deep green, backlit edges)
        float treeShade = 0.75 + 0.5 * fbmN(oct, float2(uv.x * aspect * 25.0, uv.y * 25.0));
        float3 treeCol = mix(float3(0.03, 0.07, 0.045), u.skyHorizon.rgb * 0.22, 0.25) * treeShade * (1.0 - night * 0.5);
        col = mix(col, treeCol, fm.x * 0.97);
        float backlight = exp(-r * 2.2) * (1.0 - night);
        float leafVar = fbmN(oct, float2(uv.x * aspect * 45.0, uv.y * 45.0));
        float3 leafCol = mix(float3(0.02, 0.05, 0.025), float3(0.1, 0.2, 0.06), leafVar);
        leafCol = mix(leafCol, float3(0.45, 0.6, 0.15) * sunCol, backlight * (0.4 + 0.6 * leafVar));
        col = mix(col, leafCol * (1.0 - night * 0.55), fm.y);
        // meadow
        float meadowTop = keyTop + (1.0 - keyTop) * 0.16;
        if (uv.y < meadowTop + 0.02) {
            float mh = clamp((meadowTop - uv.y) / (meadowTop - keyTop + 1e-4), 0.0, 1.0);
            float blades = fbmN(oct, float2(uv.x * aspect * 70.0 + sin(t * 0.7 + uv.x * 9.0) * 0.4 * u.air.x, uv.y * 9.0));
            float3 grass = mix(float3(0.22, 0.36, 0.12), float3(0.05, 0.12, 0.04), mh) * (0.65 + 0.55 * blades);
            grass = mix(grass, grass * u.skyHorizon.rgb * 1.4, 0.3) * (1.0 - night * 0.7);
            float edge = smoothstep(0.0, 0.015, meadowTop - uv.y + (blades - 0.5) * 0.035);
            col = mix(col, grass, edge);
        }
        // mist along the horizon
        float horizonY = keyTop + (1.0 - keyTop) * 0.24;
        col = mix(col, u.skyHorizon.rgb * 1.1 + 0.08, u.sun.w * exp(-abs(uv.y - horizonY) * 7.0) * 0.4);
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(0.8, 0, 0, 1);
        return o;
    }

    // ---------- instanced sprites (butterflies, trails, blooms) ----------
    struct Sprite {
        float4 pos;    // x, y, z, size (fraction of screen height)
        float4 a;      // butterflies: hue, flapPhase, style, glow   | blooms: hue, openness, kind, seed
        float4 b;      // butterflies: opacity, landed, side, seed   | blooms: opacity, 0, 0, 0
    };
    struct SpriteOut { float4 pos [[position]]; float2 uv; float4 a; float4 b; float z; float extent; };

    // Butterflies use two instances per butterfly (left/right wing, b.z = -1/+1); blooms use b.z = 0.
    vertex SpriteOut sprite_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant Sprite* sprites [[buffer(0)]], constant SceneU& u [[buffer(1)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        Sprite s = sprites[iid];
        float2 q = c[vid];
        float aspect = u.a.x / u.a.y;
        float size = s.pos.w;
        float2 offset;
        float extent = 1.0;
        SpriteOut o;
        if (s.b.z != 0.0) {
            // wing: u outward 0..1, v -1..1; flap foreshortens the wing horizontally
            float side = s.b.z;
            float phase = s.a.y;
            float open = 0.32 + 0.68 * (0.5 + 0.5 * cos(phase * 6.28318));
            if (s.b.y > 0.5) { open = 0.35 + 0.6 * (0.5 + 0.5 * cos(phase * 6.28318)); }   // basking
            extent = open;
            float tilt = 0.18 * sin(u.a.z * 1.3 + s.b.w * 40.0);
            float2 local = float2(side * q.x * open * 1.1, (q.y * 2.0 - 1.0) * 0.95);
            local = float2(local.x * cos(tilt) - local.y * sin(tilt), local.x * sin(tilt) + local.y * cos(tilt));
            offset = local * size;
            o.uv = float2(q.x, q.y * 2.0 - 1.0);
        } else {
            offset = (q * 2.0 - 1.0) * size;
            o.uv = q * 2.0 - 1.0;
        }
        float2 clip = toClip(s.pos.xyz, u);
        o.pos = float4(clip + float2(offset.x / aspect, offset.y) * 2.0 * u.cam.x, 0, 1);
        o.a = s.a; o.b = s.b; o.z = s.pos.z; o.extent = extent;
        return o;
    }

    float ellipse(float2 p, float2 c, float2 r, float rot) {
        float2 d = p - c;
        d = float2(d.x * cos(rot) + d.y * sin(rot), -d.x * sin(rot) + d.y * cos(rot));
        return length(d / r) - 1.0;
    }

    // A hummingbird (a surprise), side on in a square sprite (uv -1..1): heading a.x (±1), its wings' phase a.y. A slim
    // iridescent green body, a ruby throat, a long fine bill, a forked tail, and its wings a translucent blur beating.
    ColorDepth gardenHummingbird(SpriteOut in, constant SceneU& u) {
        float2 p = float2(in.uv.x * (in.a.x < 0.0 ? -1.0 : 1.0), in.uv.y);
        float2 bq = p - float2(0.02, -0.02);
        float ca = cos(-0.35), sa = sin(-0.35);
        bq = float2(bq.x * ca - bq.y * sa, bq.x * sa + bq.y * ca);
        float body = length(bq / float2(0.36, 0.13));
        float head = length((p - float2(0.36, 0.1)) / 0.12);
        float2 bv = p - float2(0.44, 0.1);
        float bill = (bv.x > 0.0 && bv.x < 0.42) ? 1.0 - smoothstep(0.012, 0.022, abs(bv.y + 0.05 * bv.x)) : 0.0;
        float tx = -0.3 - p.x;
        float tail = (tx > 0.0 && tx < 0.32) ? 1.0 - smoothstep(0.05 + 0.25 * tx, 0.08 + 0.25 * tx, abs(p.y + 0.12 + 0.35 * tx)) : 0.0;
        float solid = max(max(1.0 - smoothstep(0.85, 1.0, body), 1.0 - smoothstep(0.85, 1.0, head)), max(bill, tail));
        // The wings: a fan of blur above the back, brightest at the ends of each stroke.
        float stroke = sin(in.a.y * 6.2831853);
        float2 wq = p - float2(-0.02, 0.06);
        float wr = length(wq);
        float wa = atan2(wq.x, wq.y);
        float fan = (1.0 - smoothstep(0.55, 0.7, wr)) * smoothstep(0.05, 0.15, wr) * (1.0 - smoothstep(0.9, 1.25, abs(wa - 0.25 * stroke)));
        float wings = fan * (0.22 + 0.18 * abs(stroke));
        float a = max(solid, wings);
        float3 light = mix(u.skyMid.rgb, float3(1.0, 0.95, 0.85), 0.5) * (1.0 - u.skyTop.w * 0.6) + 0.05;
        float3 green = float3(0.08, 0.5, 0.26) + 0.12 * (0.5 + 0.5 * cos(6.2831853 * (p.x * 0.8 + p.y + float3(0.0, 0.33, 0.67))));
        float3 col = green;
        float throat = 1.0 - smoothstep(0.8, 1.0, length((p - float2(0.3, -0.02)) / float2(0.1, 0.07)));
        col = mix(col, float3(0.75, 0.05, 0.12), throat);
        col = mix(col, float3(0.75, 0.75, 0.72), (1.0 - smoothstep(-0.1, -0.02, p.y)) * step(body, 1.0) * 0.6);
        col = mix(col, float3(0.05, 0.04, 0.035), max(bill, tail * 0.7));
        col = solid > 0.5 ? col * light * 1.3 : float3(0.85, 0.9, 0.95) * light;
        float2 eq = p - float2(0.4, 0.13);
        if (dot(eq, eq) < 0.0006) col = float3(0.02);
        col = mix(col, u.skyHorizon.rgb * 0.9, in.z * u.sun.w * 0.5);
        ColorDepth o;
        o.color = float4(col, a * in.b.x);
        o.depth = float4(in.z, 0, 0, 1);
        return o;
    }

    fragment ColorDepth butterfly_fragment(SpriteOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 p = in.uv;                          // x 0..1 outward, y -1..1
        int style = int(in.a.z + 0.5);
        if (style == 9) {
            ColorDepth h = gardenHummingbird(in, u);
            if (h.color.a < 0.03) { discard_fragment(); }
            return h;
        }
        float hue = in.a.x, glow = in.a.w, opacity = in.b.x, seed = in.b.w;
        // wing shape: forewing + hindwing
        float fore = ellipse(p, float2(0.52, 0.36), float2(0.5, 0.36), 0.55);
        float hind = ellipse(p, float2(0.4, -0.38), float2(0.36, 0.34), -0.4);
        if (style == 5) { // origami: crisp triangles
            fore = max(max(-p.x, p.y - 0.95 + p.x * 0.3), -(p.y - 0.02 - p.x * 0.1)) ;
            fore = max(fore, p.x - 1.0);
            hind = max(max(-p.x, -(p.y + 0.75 - p.x * 0.2)), p.y + 0.02);
            hind = max(hind, p.x - 0.75);
        }
        float d = min(fore, hind);
        float body = length(float2(p.x / 0.05, p.y / 0.55)) - 1.0;
        float alpha = smoothstep(0.06, -0.02, d);
        float isBody = smoothstep(0.2, -0.2, body);
        alpha = max(alpha, isBody);
        if (alpha < 0.04) { discard_fragment(); }
        float edge = smoothstep(-0.28, -0.04, d);           // 1 near the outline
        float ang = atan2(p.y, p.x);
        float veins = smoothstep(0.92, 1.0, abs(sin(ang * 7.0 + p.x * 2.0)));
        float3 tint = hsv(hue, 0.65, 1.0);
        float3 col; float a = alpha; float emissive = 0.0;
        float t = u.a.z;
        if (style == 1) {        // Monarch
            float3 orange = mix(float3(1.0, 0.45, 0.05), tint, 0.25);
            col = mix(orange, float3(0.02), max(veins * 0.9, edge));
            float dots = step(0.82, hash21(floor(p * 14.0) + seed)) * edge;
            col = mix(col, float3(1.0), dots);
        } else if (style == 2) { // Glasswing
            col = mix(float3(0.9, 0.95, 1.0) * 0.6, float3(0.25, 0.12, 0.05), edge);
            a *= mix(0.22, 1.0, edge);
            emissive = 0.15 * (1.0 - edge);
        } else if (style == 3) { // Morpho Blue: thin-film iridescence
            float film = in.a.y * 0.6 + p.y * 0.35 + p.x * 0.2 + t * 0.05;
            float3 irid = 0.5 + 0.5 * cos(6.28318 * (film + float3(0.0, 0.33, 0.67)));
            float3 blue = float3(0.05, 0.35, 1.0);
            col = mix(blue, irid, u.look.x * 0.7) * (1.0 - edge * 0.85);
            emissive = 0.5 + 0.6 * u.look.x;
        } else if (style == 4) { // Moth
            col = mix(float3(0.62, 0.55, 0.45), float3(0.35, 0.28, 0.2), fbm(p * 9.0 + seed * 10.0)) * (1.0 - edge * 0.4);
            col = mix(col, tint * 0.6, 0.15);
        } else if (style == 5) { // Origami
            float facet = step(0.0, p.y - p.x * 0.4) * 0.25 + step(0.5, p.x) * 0.15;
            col = tint * (0.65 + facet) + 0.05;
        } else if (style == 6) { // Crystal
            col = mix(float3(0.85, 0.92, 1.0), tint, 0.25) * 0.55;
            float facets = abs(sin(p.x * 18.0 + p.y * 11.0)) * abs(sin(p.y * 16.0 - p.x * 7.0));
            emissive = 0.6 * smoothstep(0.85, 1.0, facets) + 0.8 * edge;
            a *= 0.75;
        } else if (style == 7) { // Neon
            col = float3(0.02);
            emissive = 2.5 * edge + 0.8 * veins;
            col += tint * emissive;
            emissive = 0.0;
        } else {                 // Petal
            col = mix(float3(1.0, 0.85, 0.9), tint, 0.4) * (0.75 + 0.35 * (1.0 - length(p - float2(0.3, 0.0))));
        }
        // shimmer: a light sweep across the wings as they beat
        float sweep = smoothstep(0.85, 1.0, sin(p.x * 4.0 + in.a.y * 6.28318 * 0.5 + seed * 6.0));
        col += float3(1.0) * sweep * u.look.y * 0.35 * (1.0 - edge);
        col += tint * emissive;
        col *= 1.0 + glow * 0.8;
        col = mix(col, float3(0.03, 0.02, 0.02), isBody);
        // farther butterflies sit in the haze
        col = mix(col, u.skyHorizon.rgb * 0.9, in.z * u.sun.w * 0.5);
        ColorDepth o;
        o.color = float4(col, a * opacity);
        o.depth = float4(in.z, 0, 0, 1);
        return o;
    }

    fragment ColorDepth bloom_fragment(SpriteOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float2 p = in.uv;
        float hue = in.a.x, open = in.a.y; int kind = int(in.a.z + 0.5);
        float r = length(p), ang = atan2(p.y, p.x) + in.a.w * 6.0;
        float n = kind == 2 ? 4.0 : kind == 3 ? 8.0 : kind == 4 ? 6.0 : 5.0;
        float petal;
        if (kind == 3) { petal = pow(abs(cos(ang * n * 0.5)), 0.45); }          // lotus: pointed
        else if (kind == 5) { petal = abs(cos(ang * n * 0.5)) * (1.0 - 0.25 * smoothstep(0.9, 1.0, abs(cos(ang * n * 0.5)))); } // cherry: notched
        else { petal = 0.55 + 0.45 * abs(cos(ang * n * 0.5)); }
        float radius = open * (kind == 1 ? 0.75 : 0.9) * petal;
        float shape = smoothstep(radius + 0.03, radius - 0.03, r);
        if (kind == 1) { shape = max(shape, smoothstep(open * 0.55 + 0.03, open * 0.55 - 0.03, r) * 1.0); } // rose: layered
        if (shape < 0.03) { discard_fragment(); }
        float3 petalCol = hsv(hue, kind == 5 ? 0.25 : 0.6, 1.0) * (0.55 + 0.45 * (r / max(radius, 0.01)));
        float centre = smoothstep(0.2 * open, 0.12 * open, r);
        float3 col = mix(petalCol, float3(1.0, 0.8, 0.25), centre);
        col *= mix(1.0, 0.35, u.skyTop.w);
        col += float3(1.0, 0.85, 0.6) * u.sun.z * 0.15 * (1.0 - u.skyTop.w);
        ColorDepth o;
        o.color = float4(col, shape * in.b.x);
        o.depth = float4(in.z, 0, 0, 1);
        return o;
    }

    // Soft additive dot for butterfly trails (sprite_vertex with side 0).
    fragment ColorDepth trail_fragment(SpriteOut in [[stage_in]]) {
        float f = exp(-dot(in.uv, in.uv) * 2.5);
        ColorDepth o;
        o.color = float4(hsv(in.a.x, 0.45, 1.0) * f * in.b.x, 1.0);
        o.depth = float4(1.0, 0, 0, 0);
        return o;
    }

    // ---------- pollen, petals, fireflies (stateless procedural particles) ----------
    struct ParticleOut { float4 pos [[position]]; float2 uv; float4 color; };
    vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant SceneU& u [[buffer(0)]]) {
        float2 c[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, -1), float2(1, 1), float2(-1, 1) };
        float i = float(iid);
        float t = u.a.z;
        float pollenN = u.counts.x, petalN = u.counts.y, fireN = u.counts.z;
        float3 p; float size; float4 col;
        float breeze = u.air.x;
        if (i < pollenN) {
            float3 h = float3(hash11(i), hash11(i + 7.1), hash11(i + 13.3));
            p = float3(fract(h.x + t * (0.004 + 0.02 * breeze)), 0.12 + 0.85 * fract(h.y + 0.01 * sin(t * 0.3 + i)), h.z);
            size = 0.0016 * (1.2 - p.z);
            float tw = pow(0.5 + 0.5 * sin(t * (1.0 + h.z * 3.0) + i), 3.0);
            float2 sp = float2(u.sun.x, u.sun.y);
            float nearSun = exp(-length(float2(p.x, u.a.w + p.y * (1.0 - u.a.w)) - sp) * 2.5);
            col = float4(1.0, 0.9, 0.6, 1.0) * u.air.y * tw * (0.25 + 1.5 * nearSun) * (1.0 - u.skyTop.w * 0.7);
        } else if (i < pollenN + petalN) {
            float j = i - pollenN;
            float3 h = float3(hash11(j + 31.0), hash11(j + 41.0), hash11(j + 53.0));
            float fall = fract(h.y - t * (0.025 + 0.02 * h.z));
            p = float3(fract(h.x + t * (0.01 + 0.05 * breeze) + 0.03 * sin(t * 1.3 + j)), 0.1 + 0.9 * fall, h.z);
            size = 0.007 * (1.3 - p.z);
            col = float4(1.0, 0.75, 0.82, 1.0) * u.air.z * 0.9;
        } else if (i < pollenN + petalN + fireN) {
            float j = i - pollenN - petalN;
            float3 h = float3(hash11(j + 71.0), hash11(j + 83.0), hash11(j + 97.0));
            p = float3(fract(h.x + 0.03 * sin(t * 0.4 + j)), 0.05 + 0.3 * h.y + 0.04 * sin(t * 0.7 + j * 2.0), h.z);
            size = 0.004 * (1.3 - p.z);
            float blink = smoothstep(0.6, 1.0, sin(t * (0.8 + h.z) + j * 3.0));
            col = float4(0.75, 1.0, 0.35, 1.0) * u.air.w * blink * 5.0;
        } else {
            // Rain on the glasshouse's glass (a surprise): drops clinging, now and then running down in short slides,
            // each catching the light as a small bright bead.
            float j = i - pollenN - petalN - fireN;
            float3 h = float3(hash11(j + 131.0), hash11(j + 151.0), hash11(j + 173.0));
            float run = max(0.0, sin(t * (0.6 + 0.9 * h.z) + h.x * 40.0));
            float y = fract(h.y - t * 0.012 * (0.4 + h.z) - 0.04 * run * run);
            float on = smoothstep(0.0, 0.25, u.perf.w - h.z * 0.6);
            float aspectD = u.a.x / u.a.y;
            ParticleOut d;
            float2 c2 = float2(h.x * 2.0 - 1.0, y * 2.0 - 1.0);
            float sz = (0.0035 + 0.006 * h.z) * on;
            d.pos = float4(c2 + float2(c[vid].x / aspectD, c[vid].y) * sz, 0, 1);
            d.uv = c[vid];
            float3 sheen = mix(u.skyMid.rgb, float3(1.0), 0.6) * (1.0 - u.skyTop.w * 0.6);
            d.color = float4(sheen * 0.55 * u.perf.w, 1.0);
            return d;
        }
        float aspect = u.a.x / u.a.y;
        float2 clip = toClip(p, u);
        ParticleOut o;
        o.pos = float4(clip + float2(c[vid].x / aspect, c[vid].y) * size * 2.0, 0, 1);
        o.uv = c[vid];
        o.color = col;
        return o;
    }
    fragment ColorDepth particle_fragment(ParticleOut in [[stage_in]]) {
        float f = exp(-dot(in.uv, in.uv) * 5.0);
        ColorDepth o;
        o.color = float4(in.color.rgb * f, 1.0);
        o.depth = float4(1.0, 0, 0, 0);
        return o;
    }

    // ---------- keys ----------
    struct KeyInstance { float4 rect; float4 info; };   // rect x0,y0,x1,y1 clip; info isBlack, glow, pressed
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };
    vertex KeyOut keys_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o; o.uv = c[vid]; o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1); o.info = k.info; return o;
    }
    fragment ColorDepth keys_fragment(KeyOut in [[stage_in]], constant SceneU& u [[buffer(0)]]) {
        float isBlack = in.info.x, glow = in.info.y, pressed = in.info.z;
        int finish = int(u.keyGlow.w + 0.5);
        float2 uv = in.uv;
        float3 white = float3(0.95, 0.92, 0.86), black = float3(0.05, 0.045, 0.04);
        if (finish == 1) { white = float3(0.82, 0.8, 0.76); black = float3(0.12, 0.11, 0.1); }          // Satin
        else if (finish == 2) { white = float3(0.96, 0.89, 0.74); black = float3(0.1, 0.07, 0.05); }   // Ivory
        else if (finish == 3) { white = float3(0.75, 0.77, 0.8); black = float3(0.25, 0.26, 0.28); }   // Brushed metal
        else if (finish == 4) { white = float3(1.0, 0.82, 0.45); black = float3(0.35, 0.22, 0.06); }   // Gold
        else if (finish == 5) { white = float3(0.96, 0.95, 0.98); black = float3(0.2, 0.18, 0.24); }   // Pearl
        float3 col = isBlack > 0.5 ? black : white * mix(0.82, 1.0, uv.y);
        if (finish == 3) { col *= 0.92 + 0.08 * fract(sin(uv.y * 900.0) * 43758.5); }
        if (finish == 5) { col += (0.5 + 0.5 * cos(6.28318 * (uv.y * 0.6 + uv.x + float3(0.0, 0.33, 0.67)))) * 0.08; }
        if (finish == 0 || finish == 4) { col += float3(0.12) * smoothstep(0.85, 1.0, uv.y) * isBlack; }
        if (pressed > 0.5) col *= isBlack > 0.5 ? 1.3 : 0.9;
        float edge = 1.0 - smoothstep(0.0, 0.18, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        col = mix(col, u.keyGlow.rgb, glow * 0.3);
        col += u.keyGlow.rgb * glow * edge * 1.6;
        ColorDepth o;
        o.color = float4(col, 1.0);
        o.depth = float4(0.0, 0, 0, 1);
        return o;
    }
    """
}
