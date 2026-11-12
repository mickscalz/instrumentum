import simd
import InStrumCore

/// Metal source for the shared Ocean layer (both coasts): an analytic sea of four swell components plus chop,
/// reflecting the Living Sky with Fresnel, the sun's and the moon's glitter paths blended by each light's
/// strength, crest foam and golden-hour translucence. Everything that moves is driven by the swell's wrapped
/// phases, never by a raw clock, so the sea stays smooth however long the session.
/// Travel: the whole sea is periodic across the shore over `kOceanTile` metres (swell directions are chosen so
/// each component repeats exactly; chop and glitter noise wrap their lattice), so a moving camera passes the
/// distance it has travelled, wrapped to the tile, with no seam however far it drives.
/// Smooth rules: no ray marching; chop noise is 2 octaves on Smooth, 3 on High and Ultra.
enum OceanShaders {
    static let common = """
    struct OceanU {
        float4 phases;      // four swell components (radians, wrapped)
        float4 sun;         // direction, glitter weight 0…1
        float4 sunColor;    // rgb, translucence weight 0…1
        float4 moon;        // direction, glitter weight 0…1
        float4 moonColor;   // rgb, glitter amount 0…1
        float4 params;      // swell scale, chop, haze, octaves
        float4 travel;      // x: metres travelled along the shore (wrapped to kOceanTile), yzw unused
    };

    constant float kOceanTile = 400.0;

    // Swell components in the shore's frame (x across, y out to sea): directions, wavenumbers and heights.
    // Each direction's across-shore wavenumber (dir.x · k) is a whole number of cycles per kOceanTile.
    constant float2 kSwellDir[4] = { float2(0.0, -1.0), float2(0.3926991, -0.9196670), float2(-0.4619989, -0.8868805),
                                     float2(0.1208305, -0.9926732) };
    constant float kSwellK[4] = { 0.11, 0.08, 0.17, 0.26 };
    constant float kSwellA[4] = { 0.22, 0.15, 0.08, 0.05 };

    /// Value noise that repeats every `period` lattice cells along x (period a whole number).
    float vnoiseP(float3 p, float period) {
        float3 i = floor(p), f = fract(p);
        float3 u = f * f * (3.0 - 2.0 * f);
        float x0 = i.x - period * floor(i.x / period);
        float x1 = x0 + 1.0 >= period ? 0.0 : x0 + 1.0;
        float a = hash13(float3(x0, i.y, i.z)), b = hash13(float3(x1, i.y, i.z));
        float c = hash13(float3(x0, i.y + 1.0, i.z)), d = hash13(float3(x1, i.y + 1.0, i.z));
        float e = hash13(float3(x0, i.y, i.z + 1.0)), g = hash13(float3(x1, i.y, i.z + 1.0));
        float h = hash13(float3(x0, i.y + 1.0, i.z + 1.0)), k = hash13(float3(x1, i.y + 1.0, i.z + 1.0));
        return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y), mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
    }

    /// How much sea one pixel covers along the view (metres): the ray's length × the pixel's angle, stretched by
    /// how shallowly the ray meets the water. Detail finer than this is faded out, not sampled into shimmer.
    float oceanFootprint(float3 d, float far, constant SkyU& u) {
        return far * u.weather.w / max(-d.z, 1e-3);
    }

    /// Surface slope (d height / d across, d height / d out) at q = (across, out) metres. Swell components and
    /// chop octaves finer than the pixel's `footprint` fade out (far water reads smooth, never fizzing).
    float2 oceanSlope(float2 q, constant OceanU& o, float footprint) {
        q.x += o.travel.x;
        float2 g = float2(0);
        float scale = o.params.x;
        for (int i = 0; i < 4; i++) {
            float k = kSwellK[i], a = kSwellA[i] * scale;
            float wavelength = 6.28318 / k;
            float keep = 1.0 - smoothstep(0.5 * wavelength, wavelength, footprint);
            float ph = dot(kSwellDir[i], q) * k - o.phases[i];
            g += a * k * kSwellDir[i] * cos(ph) * keep;
        }
        // Chop: noise that sloshes in small circles with the swell (periodic, so it never jumps). Each octave's
        // cells are 3.1, 1.1 and 0.4 m along the view.
        float chop = o.params.y;
        int octaves = int(o.params.w + 0.5);
        float2 drift = float2(cos(o.phases.z), sin(o.phases.z)) * 0.6;
        float2 drift2 = float2(sin(o.phases.w), cos(o.phases.w)) * 0.35;
        float p1 = 0.55 * kOceanTile, p2 = 1.6 * kOceanTile, p3 = 4.3 * kOceanTile;
        float k1 = 1.0 - smoothstep(3.1, 9.3, footprint);
        float k2 = 1.0 - smoothstep(1.1, 3.3, footprint);
        float k3 = 1.0 - smoothstep(0.4, 1.2, footprint);
        if (k1 > 0.001) {
            float2 c = q * float2(0.55, 0.32) + drift;
            g += (float2(vnoiseP(float3(c, 1.7), p1), vnoiseP(float3(c + 5.3, 4.1), p1)) - 0.5) * chop * k1;
        }
        if (k2 > 0.001) {
            float2 c2 = q * float2(1.6, 0.9) + drift2 + 11.0;
            g += (float2(vnoiseP(float3(c2, 7.3), p2), vnoiseP(float3(c2 + 3.1, 2.2), p2)) - 0.5) * chop * 0.55 * k2;
        }
        if (octaves > 2 && k3 > 0.001) {
            float2 c3 = q * float2(4.3, 2.5) - drift * 1.7 + 23.0;
            g += (float2(vnoiseP(float3(c3, 5.5), p3), vnoiseP(float3(c3 + 8.7, 6.6), p3)) - 0.5) * chop * 0.3 * k3;
        }
        return g;
    }

    /// The shore-frame slope as an east-north-up normal.
    float3 oceanNormal(float2 slope, float2 fwd, float2 rgt) {
        return normalize(float3(-(slope.x * rgt.x + slope.y * fwd.x), -(slope.x * rgt.y + slope.y * fwd.y), 1.0));
    }

    /// One light's glitter path on the water: a soft sheen broken into glints.
    float3 glitterPath(float3 d, float3 nrm, float2 q, float far, float3 L, float3 color, float weight, float glitter,
                       float footprint, constant OceanU& o) {
        if (weight < 0.001 || L.z < -0.1) return float3(0);
        q.x += o.travel.x;
        float pg = 0.9 * kOceanTile, ps = 2.2 * kOceanTile;
        // Glints finer than a pixel merge into an even sheen far away.
        float kg = 1.0 - smoothstep(1.1, 3.3, footprint), ks = 1.0 - smoothstep(0.45, 1.35, footprint);
        float2 g = float2(0);
        if (kg > 0.001) {
            g = (float2(vnoiseP(float3(q * 0.9, 3.0 * sin(o.phases.x) + 1.0), pg),
                        vnoiseP(float3(q * 0.9 + 13.0, 3.0 * cos(o.phases.y)), pg)) - 0.5) * kg;
        }
        float3 mn = normalize(nrm + float3(g.x * 0.25, g.y * 0.25, 0));
        float sd = saturate(dot(reflect(d, mn), L));
        float sparkle = 0.3;
        if (ks > 0.001) {
            float glint = smoothstep(0.6 - 0.22 * glitter, 0.8, vnoiseP(float3(q * 2.2, 4.0 * sin(o.phases.y) + 2.0 * cos(o.phases.z)), ps));
            sparkle = mix(0.3, glint, ks);
        }
        float spec = pow(sd, 700.0) * sparkle * (2.0 + 6.0 * glitter) * smoothstep(400.0, 40.0, far) + pow(sd, 60.0) * 0.2;
        return color * spec * weight * (0.35 + 0.65 * glitter);
    }

    /// The sea's colour along ray d, hitting the surface with normal nrm at q, `far` metres out.
    float3 oceanShade(float3 d, float3 nrm, float2 q, float far, constant SkyU& u, constant OceanU& o, texture2d<float> stars,
                      texture2d<float> cell) {
        float3 rd = reflect(d, nrm);
        rd.z = max(rd.z, 0.002);
        rd = normalize(rd);
        float mm;
        float3 refl = skyRadiance(rd, u, mm, stars, cell);
        float cosT = saturate(-dot(d, nrm));
        float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
        float3 deep = u.zenith.rgb * 0.05 + u.horizon.rgb * 0.05 + float3(0.002, 0.008, 0.010);
        float3 col = mix(deep, refl, fres);
        // Golden hour: a low sun ahead shines through the wave faces that lean toward you.
        float2 dh = normalize(d.xy + 1e-5);
        float face = saturate(dot(nrm.xy, -dh) * 6.0);
        float ahead = saturate(dot(normalize(o.sun.xy + 1e-5), dh));
        col += float3(0.10, 0.42, 0.33) * o.sunColor.w * face * ahead * 0.22 * smoothstep(250.0, 20.0, far);
        float glitter = o.moonColor.w;
        float footprint = oceanFootprint(d, far, u);
        col += glitterPath(d, nrm, q, far, o.sun.xyz, o.sunColor.rgb * 2.5, o.sun.w, glitter, footprint, o);
        col += glitterPath(d, nrm, q, far, o.moon.xyz, o.moonColor.rgb, o.moon.w, glitter, footprint, o);
        // Crest foam where the surface is steep (more of it in a storm).
        float steep = length(nrm.xy);
        col = mix(col, float3(0.85, 0.88, 0.9) * (u.horizon.rgb * 0.6 + 0.25), smoothstep(0.18, 0.32, steep) * 0.6);
        return col;
    }
    """
}

/// The sea's tile across the shore (metres): a camera travelling along the coast passes its distance wrapped to it.
enum OceanTile {
    static let metres = 400.0
    static func wrap(_ distance: Double) -> Float { Float(distance.truncatingRemainder(dividingBy: metres)) }
}

/// The ocean's two lights, each weighted smoothly by its own altitude (never an either/or switch, so the light
/// on the water crosses from sun to moon without a snap).
enum OceanLight {
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Directions with glitter weights 0…1 in `.w`, and colours. The sun's colour warms as it sinks.
    static func lights(_ s: SkyState) -> (sun: SIMD4<Float>, sunColor: SIMD3<Float>, moon: SIMD4<Float>, moonColor: SIMD3<Float>) {
        let clouds = Double(1 - 0.8 * s.cloudCover)
        let sunW = smooth(-5, 5, s.sun.altitude) * clouds
        let dayness = smooth(-6, 2, s.sun.altitude)
        let moonW = s.moonLit * smooth(-3, 6, s.moon.altitude) * (1 - dayness) * clouds
        let k = Float(min(1, max(0, s.sun.altitude / 20)))
        let warm = SIMD3<Float>(1, 0.6, 0.32), white = SIMD3<Float>(1, 0.95, 0.85)
        return (SIMD4(SkyLayer.enu(s.sun), Float(sunW)), warm + (white - warm) * k,
                SIMD4(SkyLayer.enu(s.moon), Float(moonW)), SIMD3(0.78, 0.85, 1.0))
    }
}
