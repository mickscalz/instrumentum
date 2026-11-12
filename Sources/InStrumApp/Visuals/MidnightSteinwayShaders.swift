/// Metal source for the Midnight Steinway look. Compiled at runtime so the
/// package needs no .metal build step.
enum MidnightSteinwayShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // params: x = keyTop (NDC y), y = bloom, z = ambience, w = spotlight count
    // style: x = spotlight width, y = warmth (-1...1), z = lacquer sheen, w = haze
    // moment (Excitement): x = the spotlight's bloom overhead (limited), y = tension's gathering, z = the dust motes'
    // shimmer, w = the curtain stirring; clock: x = time (s), y = seconds the curtain has stirred
    struct StageUniforms { float4 params; float4 style; float4 spots[64]; float4 moment; float4 clock; };
    struct ColorDepth { float4 color [[color(0)]]; float4 depth [[color(1)]]; };
    struct StageOut { float4 pos [[position]]; float2 p; };

    vertex StageOut stage_vertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        StageOut o;
        o.pos = float4(corners[vid], 0, 1);
        o.p = corners[vid];
        return o;
    }

    fragment ColorDepth stage_fragment(StageOut in [[stage_in]], constant StageUniforms& u [[buffer(0)]]) {
        float2 p = in.p;
        float keyTop = u.params.x, bloom = u.params.y, ambience = u.params.z;
        int count = int(u.params.w);
        float3 col = float3(0.043, 0.035, 0.027);                       // #0B0907
        float sheen = smoothstep(1.3, 0.0, length((p - float2(0.0, 0.95)) * float2(0.6, 1.4)));
        col += sheen * float3(0.05, 0.04, 0.03) * (0.4 + 1.2 * u.style.z); // glossy lacquer
        float3 spot = mix(float3(0.85, 0.9, 1.0), float3(1.0, 0.851, 0.627), 0.5 + 0.5 * u.style.y); // #FFD9A0 when warm
        float3 amber = float3(1.0, 0.706, 0.353);                         // #FFB45A
        float h = p.y - keyTop;
        if (h > 0.0) {
            for (int i = 0; i < count; i++) {
                float sx = -0.98 + u.spots[i].x * 1.96;
                float width = (0.02 + h * 0.16) * u.style.x;
                float d = (p.x - sx) / width;
                float cone = exp(-d * d) * exp(-h * 1.2);
                col += spot * cone * u.spots[i].y * 0.5;
            }
            col += amber * bloom * 0.28 * exp(-h * 0.8);
            // faint reflection of the light on the lacquered fall-board
            col += amber * bloom * 0.15 * exp(-h * 18.0);
        }
        // The spotlight blooming overhead (a big moment): a wide soft cone down through the haze onto the piano, its
        // pool on the lacquer just above the keys.
        float bloomSpot = u.moment.x;
        if (bloomSpot > 0.001) {
            float hh = 1.15 - p.y;
            float hw = (0.1 + 0.32 * hh) * (0.55 + 0.45 * bloomSpot);
            float dx = p.x / hw;
            float cone = exp(-dx * dx) * (0.35 + 0.65 * smoothstep(-0.2, 1.0, hh));
            col += spot * cone * (bloomSpot * 0.22 * (0.6 + 1.2 * u.style.w));
            if (h > 0.0) {
                float2 pq = float2(p.x / (0.35 + 0.45 * bloomSpot), (h - 0.05) / 0.07);
                col += spot * exp(-dot(pq, pq)) * (bloomSpot * 0.35);
            }
        }
        // Dust motes drifting down through the light, glinting (a surprise).
        float motes = u.moment.z;
        if (motes > 0.001 && h > 0.0) {
            float t = u.clock.x;
            float2 g = p * float2(40.0, 24.0) + float2(0.0, t * 0.4);
            float2 cell = floor(g), f = fract(g) - 0.5;
            float hs = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
            float2 off = float2(fract(hs * 13.7) - 0.5, fract(hs * 7.3) - 0.5) * 0.6;
            float2 dd = f - off;
            float tw = 0.5 + 0.5 * sin(t * (2.0 + 3.0 * hs) + hs * 40.0);
            float beam = exp(-(p.x * p.x) / 0.25) * (0.4 + 0.6 * max(bloomSpot, ambience));
            float mote = exp(-dot(dd, dd) * 900.0) * step(0.55, hs) * tw * tw;
            col += float3(1.0, 0.9, 0.75) * (mote * motes * beam * 1.2);
        }
        // The stage curtains stirring at the sides (a surprise): their velvet folds catch a little of the light as they move.
        float stir = u.moment.w;
        if (stir > 0.001) {
            float edge = max(smoothstep(0.72, 0.98, p.x), smoothstep(0.72, 0.98, -p.x));
            if (edge > 0.0) {
                float t = u.clock.x;
                float wave = 1.6 * sin(p.y * 2.3 - u.clock.y * 1.3) * stir;
                float folds = saturate(sin(abs(p.x) * 46.0 + wave + t * 0.2));
                float f2 = folds * folds;
                float sheenF = f2 * f2 * f2;
                col += float3(0.35, 0.04, 0.05) * (sheenF * edge * stir * (0.18 + 0.3 * ambience) * (1.2 - 0.5 * abs(p.y)));
            }
        }
        col += float3(1.0, 0.78, 0.5) * ambience * 0.05 * (1.2 - abs(p.y));
        col += float3(1.0, 0.8, 0.55) * u.style.w * 0.025 * (1.0 - abs(p.y - 0.2));
        ColorDepth o; o.color = float4(col, 1.0); o.depth = float4(0.5, 0, 0, 1);
        return o;
    }

    // rect: x0, y0 (bottom), x1, y1 (top) in NDC; info: isBlack, glow, pressed
    struct KeyInstance { float4 rect; float4 info; };
    struct KeyOut { float4 pos [[position]]; float2 uv; float4 info; };

    vertex KeyOut key_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant KeyInstance* keys [[buffer(0)]]) {
        float2 c[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
        KeyInstance k = keys[iid];
        KeyOut o;
        o.uv = c[vid];
        o.pos = float4(mix(k.rect.xy, k.rect.zw, o.uv), 0, 1);
        o.info = k.info;
        return o;
    }

    fragment ColorDepth key_fragment(KeyOut in [[stage_in]], constant float4& glowColor [[buffer(0)]]) {
        float isBlack = in.info.x, glow = in.info.y, pressed = in.info.z;
        float2 uv = in.uv;
        float3 ivory = float3(0.949, 0.922, 0.867);                       // #F2EBDD
        float3 ebony = float3(0.078, 0.071, 0.063);                       // #141210
        float3 amber = glowColor.rgb;
        float3 col;
        if (isBlack > 0.5) {
            col = ebony + float3(0.10) * smoothstep(0.8, 1.0, uv.y)        // glossy top bevel
                        + float3(0.04) * smoothstep(0.3, 0.0, abs(uv.x - 0.5) - 0.2);
            if (pressed > 0.5) col *= 1.3;
        } else {
            col = ivory * mix(0.84, 1.0, uv.y);                            // soft shading toward the player
            if (pressed > 0.5) col *= 0.9;
        }
        float edge = 1.0 - smoothstep(0.0, 0.16, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        col = mix(col, amber, glow * (isBlack > 0.5 ? 0.35 : 0.22));
        col += amber * glow * edge * 1.6;
        ColorDepth o; o.color = float4(col, 1.0); o.depth = float4(0.3, 0, 0, 1);
        return o;
    }
    """
}
