/// Metal source for Light Trails (Fire & Neon spec §9.2), Neon Night Drive's visual: one additive full-screen pass over the
/// scene. Each streak is a ribbon of light along its lane (a line parallel to the road at its height, from its tail to its
/// head), found in closed form where the view ray passes closest to it; its mirror on the wet road is the same line below
/// the deck, stretched towards you by the rain-roughened surface. The scene's depth hides a streak behind a car. Lanes
/// whose band the ray passes nowhere near are skipped, so a pixel looks at a handful of streaks at most. A big moment's
/// interchange bloom is ten streaks fanning out from the road ahead across the ramps, light flowing along them.
/// Smooth rules: no marching, no pow.
enum LightTrailsShaders {
    static let source = SkyShaders.common + NeonNightDriveShaders.common + """
    struct TrailsU {
        float4 lanes[4];   // per lane: first streak, count, the lane's centre x (m), 0
        float4 bloomA;     // the ramps leave at (m ahead; < 0 none), light (after the limiter), seed 0…1, age (s)
        float4 info;       // streak count, quality (0 Smooth), wetness, 0
    };
    struct Streak { float4 a; float4 b; };   // x (m), height (m), tail, head (m ahead); colour × light (rgb), 0

    /// The ray's closest pass to the line (x, y, ·) along the road: its distance in the cross-section (x, y offsets) and how
    /// far ahead (z) and along the ray (t) that is.
    float4 passLine(float3 d, float x, float y, float eye) {
        float dd = max(d.x * d.x + d.y * d.y, 1e-7);
        float t = (d.x * x + d.y * (y - eye)) / dd;
        float ex = d.x * t - x, ey = eye + d.y * t - y;
        return float4(ex, ey, d.z * t, t);
    }

    /// A streak's light where the ray passes it: a crisp line whose width is the light's own (`w`, m) far off but never more
    /// than `maxPx` pixels near (a long exposure's trail stays thin at every depth), with a faint glow a few pixels wide.
    /// `soften` widens the line's profile across (a mirror on the wet road: thin, but softer than the trail).
    float streakLight(float4 pass, float tail, float head, float w, float maxPx, float soften, float pa) {
        if (pass.w <= 0.0 || pass.z < tail || pass.z > head) return 0.0;
        float pix = pass.w * pa;
        float wEff = min(w, maxPx * pix);
        float r = sqrt(pass.x * pass.x + pass.y * pass.y);
        float w2 = wEff * wEff * soften * soften + pix * pix;
        // The profile's height keeps a line's total light across it the same whether it is a pixel wide or more.
        float core = exp(-r * r / w2) * (wEff / sqrt(w2));
        float glowR = min(0.12, 3.0 * pix);
        float halo = exp(-r / glowR) * 0.05 / soften;
        float ends = smoothstep(tail, tail + 3.0, pass.z) * smoothstep(head, head - 1.5, pass.z);
        float headGlow = 1.0 + 0.6 * smoothstep(head - 10.0, head, pass.z);
        return (core + halo) * ends * headGlow;
    }
    fragment float4 trails_fragment(DriveOut in [[stage_in]], constant SkyU& sky [[buffer(0)]],
                                    constant DriveU& u [[buffer(1)]], constant TrailsU& tu [[buffer(2)]],
                                    constant Streak* streaks [[buffer(3)]], texture2d<float> depth [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float3 dE;
        float3 d = driveRay(in.ndc, sky, u, dE);
        float eye = u.road3.y;
        float pa = u.a.w;
        // (A ray that passes near no lane's band, nor its mirror's, and no bloom: nothing here, and the scene's depth and
        // the road under it aren't read. Most of the view above the road.)
        bool any = tu.bloomA.x > 0.0 && tu.bloomA.y > 0.0;
        for (int lane = 0; lane < 4; lane++) {
            float4 L = tu.lanes[lane];
            if (any || int(L.y + 0.5) <= 0) continue;
            float4 band = passLine(d, L.z, 0.3, eye);
            float4 mband = passLine(d, L.z, -0.3, eye);
            any = (band.w > 0.0 && abs(band.x) < 2.4 && abs(band.y) < 1.2) || (mband.w > 0.0 && abs(mband.x) < 2.4 && abs(mband.y) < 3.0);
        }
        if (!any) { discard_fragment(); return float4(0.0); }   // (additive: nothing to add, the pixel is let go)
        float2 here = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        float dep = depth.sample(s, here).r;
        float sceneT = 60.0 * dep / max(1.0 - dep, 1e-4);
        // The road under this pixel, if the road is what it shows: the streaks' mirrors live there.
        float3 rp;
        float surface = driveSurface(d, u, rp);
        float roadT = surface > 0.5 && surface < 1.5 ? eye / -d.y : -1.0;
        bool onRoad = roadT > 0.0 && abs(sceneT - roadT) < 0.04 * roadT + 0.5;
        float F = onRoad ? fresnelWet(-d.y) * (0.3 + 0.7 * tu.info.z) : 0.0;
        float3 col = float3(0);
        for (int lane = 0; lane < 4; lane++) {
            float4 L = tu.lanes[lane];
            int first = int(L.x + 0.5), count = int(L.y + 0.5);
            if (count <= 0) continue;
            float4 band = passLine(d, L.z, 0.3, eye);
            bool near = band.w > 0.0 && abs(band.x) < 2.4 && abs(band.y) < 1.2;
            float4 mband = passLine(d, L.z, -0.3, eye);
            bool nearMirror = onRoad && mband.w > 0.0 && abs(mband.x) < 2.4 && abs(mband.y) < 3.0;
            if (!near && !nearMirror) continue;
            float3 laneCol = float3(0);
            for (int i = 0; i < 128; i++) {
                if (i >= count) break;
                Streak st = streaks[first + i];
                float3 c = st.b.rgb;
                if (near) {
                    float4 p = passLine(d, st.a.x, st.a.y, eye);
                    if (p.w < sceneT + 0.5) laneCol += c * streakLight(p, st.a.z, st.a.w, 0.05, 1.5, 1.0, pa) * 2.6;
                }
                if (nearMirror) {
                    // The mirror: the same line below the deck, reaching a little nearer, softer and dimmer.
                    float4 m = passLine(d, st.a.x, -st.a.y, eye);
                    laneCol += c * streakLight(m, st.a.z * 0.8, st.a.w, 0.05, 2.0, 1.6, pa) * F * 1.2;
                }
            }
            // A crowded lane reads as many lines, not one blaze: its light grows as the root of its count past four.
            col += laneCol * rsqrt(max(1.0, float(count) / 4.0));
        }
        // The interchange bloom: ten streaks fanning out across the ramps, light flowing out along them.
        if (tu.bloomA.x > 0.0 && tu.bloomA.y > 0.0) {
            float z0 = tu.bloomA.x;
            float seed = tu.bloomA.z;
            for (int k = 0; k < 10; k++) {
                float side = k < 5 ? -1.0 : 1.0;
                float j = float(k % 5);
                float ang = (0.12 + 0.14 * j + 0.05 * hash11(seed * 13.0 + float(k))) * side;
                float rise = (hash11(seed * 7.0 + float(k)) - 0.4) * 0.12;
                float3 p0 = float3(u.road3.x + side * 4.0, 0.3, z0);
                float3 dir = normalize(float3(sin(ang), rise, cos(ang)));
                float len = 170.0;
                // The ray's closest pass to this segment.
                float3 o = float3(0.0, eye, 0.0);
                float3 w0 = o - p0;
                float b = dot(d, dir), dd = dot(d, w0), e = dot(dir, w0);
                float den = max(1.0 - b * b, 1e-5);
                float sAlong = clamp((e - b * dd) / den, 0.0, len);
                float tRay = max(b * sAlong - dd, 0.0);
                float3 off = (o + d * tRay) - (p0 + dir * sAlong);
                float dist = length(off);
                if (tRay > sceneT + 0.5) continue;
                float pix = tRay * pa;
                float w2 = 0.04 + pix * pix;
                float core = exp(-dist * dist / w2) * 0.04 / w2;
                float flow = 0.55 + 0.45 * sin(sAlong * 0.35 - tu.bloomA.w * 18.0 + float(k));
                float fade = smoothstep(0.0, 8.0, sAlong) * smoothstep(len, len * 0.6, sAlong);
                int slot = k % 3;
                col += u.pal[slot].rgb * (core * 2.0 + exp(-dist / 1.2) * 0.04) * flow * fade * tu.bloomA.y;
            }
        }
        if (col.x == 0.0 && col.y == 0.0 && col.z == 0.0) discard_fragment();   // (nothing added: let go, as above)
        return float4(col, 0.0);
    }
    """
}
