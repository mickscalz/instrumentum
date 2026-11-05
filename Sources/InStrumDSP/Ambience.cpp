#include "Ambience.hpp"
#include <algorithm>
#include <cmath>

namespace isd {

namespace amb {

constexpr float kRampSeconds = 2.5f;

// Level calibration: continuous sources sit near −24 dBFS RMS at level 1 (closeness 0.5, room included);
// rare events (owl, chime, ticks) are set by ear-safe peak levels. See AmbienceTests.
const float kGain[ISD_AMB_COUNT] = {
    /* water */ 0.475f, /* crickets */ 0.50f, /* breeze */ 0.427f, /* owl */ 0.05f, /* rain on water */ 0.617f, /* rain on glass */ 0.708f,
    /* dawn chorus */ 0.60f, /* ship hum */ 0.0845f, /* air flow */ 0.363f, /* chime */ 0.0525f, /* hull ticks */ 0.15f, /* wind */ 0.257f,
    /* surf */ 0.54f, /* palms */ 0.92f, /* gulls */ 0.06f, /* road */ 0.19f, /* engine */ 0.36f, /* window wind */ 0.61f, /* passing car */ 0.30f,
    /* fire */ 0.45f, /* kettle */ 0.095f, /* street */ 0.067f, /* drips */ 0.30f, /* clock */ 0.30f,
    /* ice groan */ 0.10f, /* waterfall */ 0.134f, /* lapping */ 0.72f, /* boat */ 0.24f,
    /* temple bell */ 0.143f, /* paper screens */ 0.216f, /* water-knocker */ 0.055f, /* warbler */ 0.107f,
    /* sonar */ 0.0845f, /* hull creak */ 0.066f, /* whale */ 0.0663f, /* bubbles */ 0.083f, /* shrimp */ 0.223f, /* fish chorus */ 0.182f,
    // Storms (Sets 17 & 18): twelve ids reserved in the header, no source and no gain yet (zero-filled; Task 8 sets them).
};

/// sin(2πx) for x in cycles (any value). 9th-order odd polynomial after folding: error ≈ 2e-6.
inline float sin2pi(float x) {
    x -= std::floor(x);
    x -= 0.5f;
    float y = x > 0.25f ? 0.5f - x : (x < -0.25f ? -0.5f - x : x);
    float z = y * kTwoPi, z2 = z * z;
    float s = z * (1.f + z2 * (-1.f / 6.f + z2 * (1.f / 120.f + z2 * (-1.f / 5040.f + z2 * (1.f / 362880.f)))));
    return -s;
}

/// Topology-preserving state-variable filter (safe to retune while it rings). Band output has unity peak gain.
struct SVF {
    float ic1 = 0, ic2 = 0, a1 = 1, a2 = 0, a3 = 0, k = 1;
    void set(float hz, float q, float sr) {
        float g = std::tan(kPi * std::clamp(hz, 10.f, 0.45f * sr) / sr);
        k = 1.f / q;
        a1 = 1.f / (1.f + g * (g + k)); a2 = g * a1; a3 = g * a2;
    }
    inline void tick(float x, float &lp, float &bp, float &hp) {
        float v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.f * v1 - ic1; ic2 = 2.f * v2 - ic2;
        lp = v2; bp = k * v1; hp = x - k * v1 - v2;
    }
    inline float low(float x) { float l, b, h; tick(x, l, b, h); return l; }
    inline float band(float x) { float l, b, h; tick(x, l, b, h); return b; }
    inline float high(float x) { float l, b, h; tick(x, l, b, h); return h; }
    void clear() { ic1 = ic2 = 0; }
};

/// Paul Kellet's economy pink filter on white input.
struct Pink {
    float b0 = 0, b1 = 0, b2 = 0;
    inline float next(float w) {
        b0 = 0.99765f * b0 + w * 0.0990460f; b1 = 0.96300f * b1 + w * 0.2965164f; b2 = 0.57000f * b2 + w * 1.0526913f;
        return (b0 + b1 + b2 + w * 0.1848f) * 0.25f;
    }
};

/// Leaky integrator: brown-ish noise.
struct Brown { float y = 0; inline float next(float w) { y = 0.997f * y + 0.03f * w; return y; } };

/// A smooth random value in 0…1 that wanders to a new target every `seconds`.
struct Wander {
    float a = 0.5f, b = 0.5f, t = 1;
    float next(FastRandom &r, float dt, float seconds) {
        t += dt / seconds;
        if (t >= 1.f) { t -= std::floor(t); a = b; b = r.uniform(); }
        float s = t * t * (3.f - 2.f * t);
        return a + (b - a) * s;
    }
};

/// A decaying complex phasor (one sine partial).
struct Partial {
    float re = 0, im = 0, cr = 1, ci = 0, mag = 0;
    void start(float hz, float t60, float amp, float sr) {
        float r = t60 > 0 ? std::pow(10.f, -3.f / (t60 * sr)) : 1.f, w = kTwoPi * hz / sr;
        cr = r * std::cos(w); ci = r * std::sin(w); re = 0; im = amp; mag = amp;
    }
    /// As `start`, but from sine phase, as a struck resonator rings: silent at the onset, so the strike has no step.
    void startSine(float hz, float t60, float amp, float sr) { start(hz, t60, amp, sr); re = amp; im = 0; }
    inline float next() { float nr = re * cr - im * ci, ni = re * ci + im * cr; re = nr; im = ni; return ni; }
    float energy() const { return re * re + im * im; }
    /// For undamped partials: pull rounding drift back to the starting amplitude.
    void renorm() { float m = std::sqrt(energy()); if (m > 0) { float s = mag / m; re *= s; im *= s; } }
};

inline void panGains(float pan, float &gl, float &gr) {
    float th = (std::clamp(pan, -1.f, 1.f) + 1.f) * kPi / 4.f;
    gl = std::cos(th); gr = std::sin(th);
}

inline float expRand(FastRandom &r) { return -std::log(std::max(1e-6f, r.uniform())); }

// ---------------------------------------------------------------- Water lapping
class Water final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkBody, pinkFL, pinkFR;
    SVF sloshL, sloshR, foamL, foamR, body, topL, topR;
    struct Wave { bool on = false; float t = 0, rise = 1, fall = 2, amp = 1; } waves[4];
    float nextWave = 0, nextPlip = 0, env = 0;
    struct Plip { bool on = false; float ph = 0, f = 1000, t = 0, dur = 0.03f, amp = 0, gl = 0.7f, gr = 0.7f; } plips[8];

public:
    explicit Water(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.5f; }
    void wake(const AmbienceContext &) override { nextWave = 0.1f; nextPlip = 0.4f + rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((nextWave -= dt) <= 0) {
            for (auto &w : waves) if (!w.on) { w = {true, 0, 0.5f + 0.6f * rng.uniform(), 1.2f + 1.4f * rng.uniform(), 0.6f + 0.4f * rng.uniform()}; break; }
            nextWave = 1.8f + 2.7f * rng.uniform();
        }
        float target = 0;
        for (auto &w : waves) {
            if (!w.on) continue;
            w.t += dt;
            float v;
            if (w.t < w.rise) { float s = std::sin(0.5f * kPi * w.t / w.rise); v = s * s; }
            else if (w.t < w.rise + w.fall) v = 0.5f + 0.5f * std::cos(kPi * (w.t - w.rise) / w.fall);
            else { w.on = false; v = 0; }
            target += w.amp * v;
        }
        target = std::min(1.2f, target);
        sloshL.set(300.f + 800.f * target, 0.8f, c.sr); sloshR.set(320.f + 760.f * target, 0.8f, c.sr);
        foamL.set(1200.f, 1.5f, c.sr); foamR.set(1300.f, 1.5f, c.sr); body.set(180.f, 0.7f, c.sr);
        topL.set(2500.f, 0.7f, c.sr); topR.set(2500.f, 0.7f, c.sr);   // a calm lake doesn't hiss
        if ((nextPlip -= dt) <= 0) {
            for (auto &p : plips) if (!p.on) {
                p.on = true; p.ph = 0; p.t = 0; p.f = 600.f * std::pow(3.f, rng.uniform()); p.dur = 0.015f + 0.025f * rng.uniform();
                p.amp = 0.08f + 0.17f * rng.uniform(); panGains(0.6f * rng.bipolar(), p.gl, p.gr);
                break;
            }
            nextPlip = (0.3f + 2.2f * rng.uniform()) / c.density;
        }
        const float de = (target - env) / (float)n;
        for (int t = 0; t < n; ++t) {
            env += de;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            const float a = 0.25f + 0.75f * env, foam = 0.3f * env * env;
            const float b = 0.2f * body.low(pinkBody.next(rng.bipolar()));
            l[t] += topL.low(a * sloshL.band(pinkL.next(wl)) + 2.f * foam * foamL.band(pinkFL.next(wl))) + b;
            r[t] += topR.low(a * sloshR.band(pinkR.next(wr)) + 2.f * foam * foamR.band(pinkFR.next(wr))) + b;
        }
        for (auto &p : plips) {
            if (!p.on) continue;
            const float invSr = 1.f / c.sr, decay = std::pow(0.01f, invSr / p.dur);
            for (int t = 0; t < n; ++t) {
                const float u = p.t / p.dur, att = std::min(1.f, p.t * 333.f);
                const float x = p.amp * att * sin2pi(p.ph);
                p.ph += p.f * (1.f + 0.5f * u) * invSr;
                p.amp *= decay;
                p.t += invSr;
                l[t] += x * p.gl; r[t] += x * p.gr;
            }
            if (p.t > 3.f * p.dur) p.on = false;
        }
    }
};

// ---------------------------------------------------------------- Crickets
class Crickets final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kPulse = 0.018f, kPeriod = 0.032f;
    struct Chirper {
        float f = 4600, gl = 0.7f, gr = 0.7f, gain = 1, period = 0.7f, ph = 0;
        int pulses = 4, chirpsLeft = 10;
        float next = 0, t = -1;   // t ≥ 0 while chirping
    } ch[5];

public:
    explicit Crickets(uint64_t seed) : rng(seed) {
        direct = 1.f; send = 0.4f;
        const float pans[5] = {-0.8f, -0.35f, 0.1f, 0.5f, 0.85f};
        for (int i = 0; i < 5; ++i) {
            auto &c = ch[i];
            c.f = 4200.f + 1000.f * rng.uniform();
            panGains(pans[i], c.gl, c.gr);
            c.gain = 0.5f + 0.5f * rng.uniform();
            c.period = 0.55f + 0.35f * rng.uniform();
            c.pulses = 3 + (int)(rng.uniform() * 2.99f);
        }
    }
    void wake(const AmbienceContext &) override {
        for (auto &c : ch) { c.next = 0.1f + c.period * rng.uniform(); c.t = -1; c.chirpsLeft = 8 + (int)(12 * rng.uniform()); }
    }
    void render(float *l, float *r, int n, const AmbienceContext &cx) override {
        const float dt = (float)n / cx.sr, invSr = 1.f / cx.sr, rate = cx.density * (1.f - 0.4f * cx.cool);
        for (auto &c : ch) {
            if (c.t < 0) {
                if ((c.next -= dt) > 0) continue;
                c.t = 0; c.ph = 0;
                if (--c.chirpsLeft <= 0) { c.chirpsLeft = 8 + (int)(12 * rng.uniform()); c.next = 1.5f + 3.5f * rng.uniform(); }
                else c.next = c.period * (0.92f + 0.16f * rng.uniform()) / rate;
                c.next -= dt;
            }
            const float len = (float)c.pulses * kPeriod;
            for (int t = 0; t < n && c.t < len; ++t) {
                const int k = (int)(c.t / kPeriod);
                const float u = (c.t - (float)k * kPeriod) / kPulse;
                if (u < 1.f) {
                    float e = std::sin(kPi * u); e *= e;
                    const float x = c.gain * e * (sin2pi(c.ph) + 0.12f * sin2pi(2.f * c.ph));
                    l[t] += x * c.gl; r[t] += x * c.gr;
                    c.ph += c.f * (1.f - 0.02f * u) * invSr;
                }
                c.t += invSr;
            }
            if (c.t >= len) c.t = -1;
        }
    }
};

// ---------------------------------------------------------------- Breeze
class Breeze final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF bl, br, rhl, rhr, rll, rlr;
    Wander centre, amp, rustle;
    float a = 0.8f, ru = 0;

public:
    explicit Breeze(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        const float cf = 350.f + 750.f * centre.next(rng, dt, 6.f);
        const float a1 = 0.6f + 0.4f * amp.next(rng, dt, 8.f), ru1 = 0.15f * a1 * a1 * rustle.next(rng, dt, 4.f);
        bl.set(cf, 0.6f, c.sr); br.set(cf * 1.07f, 0.6f, c.sr);
        rhl.set(2000.f, 0.7f, c.sr); rhr.set(2100.f, 0.7f, c.sr); rll.set(5000.f, 0.7f, c.sr); rlr.set(5200.f, 0.7f, c.sr);
        const float da = (a1 - a) / (float)n, dr = (ru1 - ru) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da; ru += dr;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            l[t] += a * bl.band(pinkL.next(wl)) + ru * rll.low(rhl.high(wl));
            r[t] += a * br.band(pinkR.next(wr)) + ru * rlr.low(rhr.high(wr));
        }
    }
};

// ---------------------------------------------------------------- Wind (with gusts)
class Wind final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkW;
    Brown brownL, brownR;
    SVF bl, br, whistle;
    Wander drift, tone;
    struct Gust { bool on = false; float t = 0, rise = 1, fall = 3, amp = 1; } gusts[3];
    float nextGust = 0, g = 0;

public:
    explicit Wind(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void wake(const AmbienceContext &) override { nextGust = 1.f + 3.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((nextGust -= dt) <= 0) {
            for (auto &q : gusts) if (!q.on) { q = {true, 0, 1.f + rng.uniform(), 2.f + 2.f * rng.uniform(), 0.5f + 0.5f * rng.uniform()}; break; }
            nextGust = (4.f + 8.f * rng.uniform()) / c.density;
        }
        float target = 0;
        for (auto &q : gusts) {
            if (!q.on) continue;
            q.t += dt;
            float v;
            if (q.t < q.rise) { float s = std::sin(0.5f * kPi * q.t / q.rise); v = s * s; }
            else if (q.t < q.rise + q.fall) v = 0.5f + 0.5f * std::cos(kPi * (q.t - q.rise) / q.fall);
            else { q.on = false; v = 0; }
            target += q.amp * v;
        }
        target = std::min(1.f, target);
        const float cf = (180.f + 100.f * drift.next(rng, dt, 7.f)) * (1.f + 0.8f * target);
        bl.set(cf, 0.9f, c.sr); br.set(cf * 1.08f, 0.9f, c.sr);
        whistle.set(700.f + 400.f * tone.next(rng, dt, 5.f), 12.f, c.sr);
        const float dg = (target - g) / (float)n;
        for (int t = 0; t < n; ++t) {
            g += dg;
            const float a = 0.4f + 0.9f * g, wh = 0.25f * g * g;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            const float w = wh * whistle.band(pinkW.next(rng.bipolar()));
            l[t] += a * bl.band(brownL.next(wl) * 4.f + pinkL.next(wl)) + w;
            r[t] += a * br.band(brownR.next(wr) * 4.f + pinkR.next(wr)) + w;
        }
    }
};

// ---------------------------------------------------------------- Owl (distant two-note call)
class Owl final : public AmbienceSource {
    FastRandom rng;
    SVF breath, distance;
    float next = 0, t = -1, base = 380, ph = 0, gl = 0.7f, gr = 0.7f;
    static constexpr float kStart2 = 0.72f, kDur1 = 0.42f, kDur2 = 0.6f;

public:
    explicit Owl(uint64_t seed) : rng(seed) { direct = 0.35f; send = 1.f; }
    void wake(const AmbienceContext &) override { next = 10.f + 30.f * rng.uniform(); t = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, invSr = 1.f / c.sr;
        if (t < 0) {
            if ((next -= dt) > 0) return;
            t = 0; ph = 0; base = 360.f + 40.f * rng.uniform();
            panGains(0.4f * rng.bipolar(), gl, gr);
            next = (54.f + 72.f * rng.uniform()) / c.density;
            breath.set(base, 6.f, c.sr); distance.set(1500.f, 0.7f, c.sr);
        }
        for (int s = 0; s < n && t >= 0; ++s) {
            float f = 0, env = 0, vib = 0, tn = 0, dur = 1;
            if (t < kDur1) { tn = t; dur = kDur1; f = base; vib = 0.004f; }
            else if (t >= kStart2 && t < kStart2 + kDur2) { tn = t - kStart2; dur = kDur2; f = base * 0.895f; vib = 0.012f; }
            if (f > 0) {
                env = std::min(1.f, tn / 0.06f);
                env = env * env * (3.f - 2.f * env);
                const float rel = (dur - tn) / 0.15f;
                if (rel < 1.f) env *= rel * rel * (3.f - 2.f * rel);
                const float freq = f * (1.f - 0.03f * tn / dur) * (1.f + vib * sin2pi(5.5f * tn));
                ph += freq * invSr;
                const float tone = sin2pi(ph) + 0.12f * sin2pi(2.f * ph) + 0.04f * sin2pi(3.f * ph);
                const float x = distance.low(env * (tone + 0.6f * breath.band(rng.bipolar())));
                l[s] += x * gl; r[s] += x * gr;
            } else {
                const float x = distance.low(0.f);
                l[s] += x * gl; r[s] += x * gr;
            }
            t += invSr;
            if (t > kStart2 + kDur2 + 0.05f) t = -1;
        }
    }
};

// ---------------------------------------------------------------- Rain (on water or on glass)
class Rain final : public AmbienceSource {
    FastRandom rng;
    bool glass;
    struct Res { SVF f; float gl = 0.7f, gr = 0.7f; int life = 0; } res[8];
    int nextRes = 0;
    SVF bedAL, bedAR, bedBL, bedBR;
    Wander swell;
    float a = 1, dropRate, snowApplied = 0;

    void setGlassBed(float lower, float sr) {
        const float k = 1.f - 0.4f * lower;
        bedAL.set(1800.f * k, 0.6f, sr); bedAR.set(1900.f * k, 0.6f, sr); bedBL.set(9000.f * k, 0.7f, sr); bedBR.set(9200.f * k, 0.7f, sr);
    }

public:
    Rain(uint64_t seed, bool onGlass, float sr) : rng(seed), glass(onGlass) {
        direct = 1.f; send = 0.4f;
        indoor = onGlass;   // at the glass itself: never behind it
        dropRate = onGlass ? 220.f : 350.f;
        if (glass) setGlassBed(0, sr);
        else { bedAL.set(1600.f, 0.5f, sr); bedAR.set(1700.f, 0.5f, sr); bedBL.set(6000.f, 0.7f, sr); bedBR.set(6200.f, 0.7f, sr); }
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        // Snow on the glass: fewer, softer, lower ticks.
        const float snow = glass ? c.snowOnGlass : 0.f, soften = 1.f - 0.6f * snow;
        if (glass && std::fabs(snow - snowApplied) > 0.005f) { snowApplied = snow; setGlassBed(snow, c.sr); }
        const float dt = (float)n / c.sr, p = dropRate * c.density * soften / c.sr;
        const float a1 = (0.85f + 0.3f * swell.next(rng, dt, 5.f)) * soften, da = (a1 - a) / (float)n;
        const int ring = (int)(0.06f * c.sr);
        for (int t = 0; t < n; ++t) {
            a += da;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            float il = 0, ir = 0;
            if (rng.uniform() < p) {
                const float amp = 0.2f + 0.8f * rng.uniform() * rng.uniform();
                float pl, pr;
                panGains(0.9f * rng.bipolar(), pl, pr);
                il = 3.f * amp * pl; ir = 3.f * amp * pr;   // the splash itself, through the bed filters
                if (glass || rng.uniform() < 0.35f) {
                    Res &q = res[nextRes]; nextRes = (nextRes + 1) & 7;
                    const float f = glass ? 2500.f * (1.f - 0.4f * snow) * std::pow(2.8f, rng.uniform()) : 900.f * std::pow(3.9f, rng.uniform());
                    q.f.set(f, glass ? 8.f : 25.f, c.sr);
                    q.gl = pl * amp; q.gr = pr * amp; q.life = ring;
                    float lo, bp, hi; q.f.tick(glass ? 6.f : 12.f, lo, bp, hi);
                }
            }
            float yl = 0, yr = 0;
            for (auto &q : res) {
                if (q.life <= 0) continue;
                --q.life;
                const float y = q.f.band(0.f);
                yl += y * q.gl; yr += y * q.gr;
            }
            const float bl = bedBL.low(glass ? bedAL.high(0.35f * wl + il) : bedAL.band(0.5f * wl + il));
            const float br = bedBR.low(glass ? bedAR.high(0.35f * wr + ir) : bedAR.band(0.5f * wr + ir));
            l[t] += a * bl + soften * yl;
            r[t] += a * br + soften * yr;
        }
    }
};

// ---------------------------------------------------------------- Dawn chorus
class DawnChorus final : public AmbienceSource {
    FastRandom rng;
    struct Syllable { float start, dur, f0, f1, fmRate, fmDepth, amp; };
    struct Bird {
        int type = 0, count = 0, cur = 0;
        Syllable s[12];
        float t = -1, next = 0, ph = 0, gl = 0.7f, gr = 0.7f, gain = 1;
    } birds[4];

    void phrase(Bird &b) {
        float at = 0;
        const float u = rng.uniform();
        switch (b.type) {
        case 0: {   // whistle: two to four gliding notes
            b.count = 2 + (int)(u * 2.99f);
            for (int i = 0; i < b.count; ++i) {
                const float d = 0.12f + 0.13f * rng.uniform(), f0 = 2600.f + 1000.f * rng.uniform();
                b.s[i] = {at, d, f0, f0 * (0.85f + 0.4f * rng.uniform()), 0, 0, 0.8f + 0.2f * rng.uniform()};
                at += d + 0.06f + 0.09f * rng.uniform();
            }
            break;
        }
        case 1: {   // trill
            b.count = 6 + (int)(u * 6.99f);
            const float f0 = 4200.f + 800.f * rng.uniform();
            for (int i = 0; i < b.count; ++i) { b.s[i] = {at, 0.035f, f0, f0 * 0.8f, 0, 0, 0.7f + 0.3f * (float)(i % 2)}; at += 0.06f; }
            break;
        }
        case 2: {   // warble
            b.count = 1;
            const float f0 = 3200.f + 1000.f * rng.uniform();
            b.s[0] = {0, 0.6f + 0.5f * u, f0, f0 * 1.05f, 22.f + 16.f * rng.uniform(), 250.f + 200.f * rng.uniform(), 0.7f};
            break;
        }
        default: {  // chips
            b.count = 3 + (int)(u * 2.99f);
            const float f0 = 5000.f + 1000.f * rng.uniform();
            for (int i = 0; i < b.count; ++i) { b.s[i] = {at, 0.02f, f0, f0 * 0.9f, 0, 0, 0.6f}; at += 0.11f + 0.04f * rng.uniform(); }
            break;
        }
        }
        b.cur = 0; b.t = 0; b.ph = 0;
    }

public:
    explicit DawnChorus(uint64_t seed) : rng(seed) {
        direct = 0.9f; send = 0.6f;
        const float pans[4] = {-0.7f, -0.2f, 0.3f, 0.75f};
        for (int i = 0; i < 4; ++i) { birds[i].type = i; panGains(pans[i], birds[i].gl, birds[i].gr); birds[i].gain = 0.5f + 0.5f * rng.uniform(); }
    }
    void wake(const AmbienceContext &) override { for (auto &b : birds) { b.t = -1; b.next = 0.1f + 1.5f * rng.uniform(); } }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, invSr = 1.f / c.sr;
        for (auto &b : birds) {
            if (b.t < 0) {
                if ((b.next -= dt) > 0) continue;
                phrase(b);
                b.next = (2.5f + 4.5f * rng.uniform()) / c.density;
            }
            for (int t = 0; t < n && b.t >= 0; ++t) {
                while (b.cur < b.count && b.t > b.s[b.cur].start + b.s[b.cur].dur) ++b.cur;
                if (b.cur >= b.count) { b.t = -1; break; }
                const Syllable &s = b.s[b.cur];
                if (b.t >= s.start) {
                    const float u = (b.t - s.start) / s.dur, env = std::sin(kPi * u);
                    const float f = s.f0 + (s.f1 - s.f0) * u + s.fmDepth * sin2pi(s.fmRate * (b.t - s.start));
                    b.ph += f * invSr;
                    const float x = b.gain * s.amp * env * env * sin2pi(b.ph);
                    l[t] += x * b.gl; r[t] += x * b.gr;
                }
                b.t += invSr;
            }
        }
    }
};

// ---------------------------------------------------------------- Ship hum
class ShipHum final : public AmbienceSource {
    FastRandom rng;
    Partial tones[2][6];
    Brown brownL, brownR;
    SVF lowL, lowR;
    Wander level;
    float a = 1;
    int renorm = 0;

public:
    ShipHum(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.15f;
        const float f[3] = {40.f, 80.f, 120.f}, amp[3] = {1.f, 0.6f, 0.35f};
        for (int c = 0; c < 2; ++c)
            for (int h = 0; h < 3; ++h) {
                tones[c][2 * h].start(f[h], 0, amp[h], sr);
                tones[c][2 * h + 1].start(f[h] + 0.1f + 0.2f * rng.uniform(), 0, 0.45f * amp[h], sr);   // gentle beating
            }
        lowL.set(200.f, 0.7f, sr); lowR.set(200.f, 0.7f, sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, a1 = 0.89f + 0.22f * level.next(rng, dt, 9.f), da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            float hl = 0, hr = 0;
            for (int k = 0; k < 6; ++k) { hl += tones[0][k].next(); hr += tones[1][k].next(); }
            l[t] += a * (hl + 0.35f * lowL.low(brownL.next(rng.bipolar())));
            r[t] += a * (hr + 0.35f * lowR.low(brownR.next(rng.bipolar())));
        }
        if (++renorm >= 64) {   // keep the undamped phasors at their amplitude
            renorm = 0;
            for (auto &ch : tones) for (auto &p : ch) p.renorm();
        }
    }
};

// ---------------------------------------------------------------- Air flow
class AirFlow final : public AmbienceSource {
    FastRandom rng;
    SVF hl, hr, ll, lr;
    Wander level;
    float a = 1;

public:
    AirFlow(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.2f;
        hl.set(300.f, 0.7f, sr); hr.set(310.f, 0.7f, sr); ll.set(3000.f, 0.7f, sr); lr.set(2900.f, 0.7f, sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, a1 = 0.92f + 0.16f * level.next(rng, dt, 7.f), da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            l[t] += a * ll.low(hl.high(rng.bipolar()));
            r[t] += a * lr.low(hr.high(rng.bipolar()));
        }
    }
};

// ---------------------------------------------------------------- Chime (a rare soft bell on the Glass partials)
class Chime final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRatio[6] = {1.f, 2.32f, 4.25f, 6.63f, 9.38f, 12.5f};
    static constexpr float kAmp[6] = {1.f, 0.55f, 0.35f, 0.22f, 0.14f, 0.09f};
    static constexpr float kNotes[6] = {622.25f, 698.46f, 783.99f, 932.33f, 1046.5f, 1244.5f};   // E♭ major pentatonic
    struct Bell { bool on = false; Partial p[6]; float gl = 0.7f, gr = 0.7f; int attack = 0, attackLen = 1; int check = 0; } bells[4];
    float next = 0, second = -1;

    void strike(const AmbienceContext &c) {
        for (auto &b : bells) {
            if (b.on) continue;
            const float f0 = kNotes[(int)(rng.uniform() * 5.99f)], v = 0.6f + 0.4f * rng.uniform();
            for (int i = 0; i < 6; ++i)
                b.p[i].start(f0 * kRatio[i] * std::exp2((2.f * rng.bipolar()) / 1200.f), 6.f / (1.f + 0.6f * (float)i), v * kAmp[i], c.sr);
            panGains(0.5f * rng.bipolar(), b.gl, b.gr);
            b.on = true; b.attack = 0; b.attackLen = (int)((0.002f + 0.002f * rng.uniform()) * c.sr);
            return;
        }
    }

public:
    explicit Chime(uint64_t seed) : rng(seed) { direct = 0.8f; send = 0.8f; }
    void wake(const AmbienceContext &) override { next = 15.f + 35.f * rng.uniform(); second = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((next -= dt) <= 0) {
            strike(c);
            next = (80.f + 80.f * rng.uniform()) / c.density;
            if (rng.uniform() < 0.3f) second = 0.3f + 0.5f * rng.uniform();
        }
        if (second >= 0 && (second -= dt) < 0) strike(c);
        for (auto &b : bells) {
            if (!b.on) continue;
            for (int t = 0; t < n; ++t) {
                float x = 0;
                for (auto &p : b.p) x += p.next();
                if (b.attack < b.attackLen) { const float u = (float)b.attack++ / (float)b.attackLen; x *= u * u * (3.f - 2.f * u); }
                l[t] += x * b.gl; r[t] += x * b.gr;
            }
            if (++b.check >= 16) {
                b.check = 0;
                float e = 0;
                for (auto &p : b.p) e += p.energy();
                if (e < 1e-10f) b.on = false;
            }
        }
    }
};

// ---------------------------------------------------------------- Hull ticks
class HullTicks final : public AmbienceSource {
    FastRandom rng;
    struct Tick { bool on = false; Partial a, b; float gl = 0.7f, gr = 0.7f; int left = 0; } ticks[4];
    float next = 0, cluster[2] = {-1, -1};

    void tick(const AmbienceContext &c) {
        for (auto &k : ticks) {
            if (k.on) continue;
            const float f = 1800.f + 2700.f * rng.uniform(), t60 = 0.004f + 0.004f * rng.uniform(), amp = 0.5f + 0.5f * rng.uniform();
            k.a.start(f, t60, amp, c.sr);
            k.b.start(f * 2.7f, t60 * 0.6f, 0.4f * amp, c.sr);
            panGains(0.8f * rng.bipolar(), k.gl, k.gr);
            k.on = true; k.left = (int)(t60 * 1.5f * c.sr) + 1;
            return;
        }
    }

public:
    explicit HullTicks(uint64_t seed) : rng(seed) { direct = 0.9f; send = 0.7f; }
    void wake(const AmbienceContext &) override { next = 3.f + 12.f * rng.uniform(); cluster[0] = cluster[1] = -1; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr;
        if ((next -= dt) <= 0) {
            tick(c);
            next = (6.f + 19.f * rng.uniform()) / c.density;
            if (rng.uniform() < 0.4f) {
                cluster[0] = 0.08f + 0.22f * rng.uniform();
                cluster[1] = rng.uniform() < 0.5f ? cluster[0] + 0.08f + 0.22f * rng.uniform() : -1;
            }
        }
        for (auto &q : cluster) if (q >= 0 && (q -= dt) < 0) tick(c);
        for (auto &k : ticks) {
            if (!k.on) continue;
            for (int t = 0; t < n && k.left > 0; ++t, --k.left) {
                const float x = k.a.next() + k.b.next();
                l[t] += x * k.gl; r[t] += x * k.gr;
            }
            if (k.left <= 0) k.on = false;
        }
    }
};


// ---------------------------------------------------------------- Surf (waves breaking on the shore)
class Surf final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF bedL, bedR, farL, farR, lowCutL, lowCutR;
    float bed = 0.25f, farApplied = -1;
    struct Break {
        bool on = false;
        float t = 0, s = 1, k = 1, thumpPh = 0, gl = 0.7f, gr = 0.7f;
        Pink pl, pr;
        SVF crashL, crashR, washL, washR, fizzL, fizzR;
    } breaks[4];

public:
    explicit Surf(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.4f; }
    void trigger(float strength, float distance) {
        Break *b = nullptr;
        for (auto &x : breaks) if (!x.on) { b = &x; break; }
        if (!b) { b = &breaks[0]; for (auto &x : breaks) if (x.t > b->t) b = &x; }   // the oldest makes room
        b->on = true; b->t = 0; b->s = std::clamp(strength, 0.05f, 1.f); b->k = 1.f + 0.8f * distance; b->thumpPh = 0;
        panGains(0.5f * rng.bipolar(), b->gl, b->gr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, d = c.surfDistance;
        // The bed swells after each wave and settles between them.
        float lively = 0;
        for (auto &b : breaks) if (b.on) lively += b.s * std::exp(-b.t / (2.5f * b.k));
        const float bedTarget = 0.25f + 0.5f * std::min(1.f, lively);
        bed += (bedTarget - bed) * (1.f - std::exp(-dt / 0.8f));
        bedL.set(450.f + 500.f * bed, 0.7f, fsr); bedR.set(480.f + 480.f * bed, 0.7f, fsr);
        if (std::fabs(d - farApplied) > 1e-3f) {
            farApplied = d;
            const float cut = std::exp(std::log(14000.f) * (1.f - d) + std::log(550.f) * d);
            farL.set(cut, 0.7f, fsr); farR.set(cut, 0.7f, fsr);
            lowCutL.set(55.f, 0.7f, fsr); lowCutR.set(55.f, 0.7f, fsr);
        }
        float bl[64], br[64];
        const int m = std::min(n, 64);
        for (int t = 0; t < m; ++t) {
            bl[t] = 0.6f * bed * bedL.low(pinkL.next(rng.bipolar()));
            br[t] = 0.6f * bed * bedR.low(pinkR.next(rng.bipolar()));
        }
        const float fizzKeep = 1.f - 0.85f * d;
        for (auto &b : breaks) {
            if (!b.on) continue;
            const float k = b.k, s = b.s;
            // Crash: a noise burst whose top falls from 2 kHz to 400 Hz over the first half second, and a thump.
            const float crashCut = 400.f + 1600.f * std::exp(-b.t / (0.25f * k));
            b.crashL.set(crashCut, 0.8f, fsr); b.crashR.set(crashCut * 1.05f, 0.8f, fsr);
            b.washL.set(4500.f, 0.7f, fsr); b.washR.set(4800.f, 0.7f, fsr);
            b.fizzL.set(6500.f, 1.5f, fsr); b.fizzR.set(7000.f, 1.5f, fsr);
            const float crashTau = 0.45f * k * (0.6f + 0.8f * s);
            for (int t = 0; t < m; ++t) {
                const float tt = b.t + (float)t * invSr;
                const float crash = s * (tt < 0.03f * k ? tt / (0.03f * k) : std::exp(-(tt - 0.03f * k) / crashTau));
                const float thump = tt < 0.6f * k ? 0.6f * s * std::exp(-tt / (0.12f * k)) * sin2pi(b.thumpPh) : 0.f;
                b.thumpPh += 70.f * invSr;
                // Wash: a bright fizz sliding up the sand, then thinning out.
                const float u = tt - 0.3f * k;
                float wash = 0;
                if (u > 0) {
                    const float up = std::min(1.f, u / (1.5f * k));
                    wash = 0.6f * s * fizzKeep * up * up * (3.f - 2.f * up) * std::max(0.f, u < 1.5f * k ? 1.f : 1.f - (u - 1.5f * k) / (1.5f * k));
                }
                // Backwash: the sand's grains draining back, thinning over three seconds.
                const float v = tt - 2.5f * k;
                float grainL = 0, grainR = 0;
                if (v > 0 && v < 3.f * k) {
                    const float p = 0.06f * (1.f - v / (3.f * k));
                    if (rng.uniform() < p) grainL = rng.bipolar();
                    if (rng.uniform() < p) grainR = rng.bipolar();
                }
                const float wl = rng.bipolar(), wr = rng.bipolar();
                const float xl = crash * b.crashL.low(b.pl.next(wl)) * 1.6f + thump
                               + wash * b.washL.band(wl) + 0.35f * s * fizzKeep * b.fizzL.band(grainL);
                const float xr = crash * b.crashR.low(b.pr.next(wr)) * 1.6f + thump
                               + wash * b.washR.band(wr) + 0.35f * s * fizzKeep * b.fizzR.band(grainR);
                bl[t] += xl * b.gl * 1.41f;
                br[t] += xr * b.gr * 1.41f;
            }
            b.t += (float)m * invSr;
            if (b.t > 6.f * k) b.on = false;
        }
        // Below the surf's own thump there's only rumble the ear doesn't place as sea.
        for (int t = 0; t < m; ++t) { l[t] += farL.low(lowCutL.high(bl[t])); r[t] += farR.low(lowCutR.high(br[t])); }
    }
};

// ---------------------------------------------------------------- Palm fronds
class Palms final : public AmbienceSource {
    FastRandom rng;
    Wander gust;
    SVF bedL, bedR;
    struct Grain { bool on = false; float t = 0, dur = 0.01f, amp = 0, gl = 0.7f, gr = 0.7f; SVF bp; } grains[24];
    float nextGrain = 0;

public:
    explicit Palms(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        const float g = gust.next(rng, dt, 2.5f);
        bedL.set(3200.f, 0.8f, fsr); bedR.set(3500.f, 0.8f, fsr);
        const float bedAmp = 0.12f + 0.3f * g;
        for (int t = 0; t < n; ++t) { l[t] += bedAmp * bedL.band(rng.bipolar()); r[t] += bedAmp * bedR.band(rng.bipolar()); }
        // Clatter: dry fronds knocking, more of them in each gust.
        if ((nextGrain -= dt) <= 0) {
            for (auto &q : grains) if (!q.on) {
                q.on = true; q.t = 0; q.dur = 0.005f + 0.025f * rng.uniform(); q.amp = (0.3f + 0.7f * rng.uniform()) * (0.4f + 0.6f * g);
                q.bp.set(2000.f + 4000.f * rng.uniform(), 2.f, fsr); panGains(0.8f * rng.bipolar(), q.gl, q.gr);
                break;
            }
            nextGrain = expRand(rng) / (40.f * (0.3f + 0.7f * g) * c.density);
        }
        for (auto &q : grains) {
            if (!q.on) continue;
            for (int t = 0; t < n; ++t) {
                const float e = q.amp * std::exp(-q.t / q.dur);
                const float x = e * q.bp.band(rng.bipolar());
                l[t] += x * q.gl; r[t] += x * q.gr;
                q.t += invSr;
            }
            if (q.t > 6.f * q.dur) q.on = false;
        }
    }
};

// ---------------------------------------------------------------- Gulls (rare and distant)
class Gulls final : public AmbienceSource {
    FastRandom rng;
    SVF formantL, formantR, topL, topR;
    float nextCall = 3;
    struct Cry { bool on = false; float t = -1, dur = 0.4f, f1 = 1300, ph = 0, amp = 0.6f, gl = 0.7f, gr = 0.7f, rough = 0; } cries[4];

public:
    explicit Gulls(uint64_t seed) : rng(seed) { direct = 0.6f; send = 0.9f; }
    void wake(const AmbienceContext &) override { nextCall = 2.f + 4.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        formantL.set(1600.f, 2.f, fsr); formantR.set(1650.f, 2.f, fsr); topL.set(4000.f, 0.7f, fsr); topR.set(4000.f, 0.7f, fsr);
        if ((nextCall -= dt) <= 0) {
            const int count = 2 + (int)(rng.uniform() * 2.99f);
            float pan = 0.7f * rng.bipolar(), at = 0;
            const float f1 = 1100.f + 400.f * rng.uniform();
            for (int i = 0; i < count && i < 4; ++i) {
                Cry &q = cries[i];
                q.on = true; q.t = -at; q.dur = 0.35f + 0.15f * rng.uniform(); q.f1 = f1 * (0.95f + 0.1f * rng.uniform());
                q.ph = 0; q.amp = (0.5f + 0.5f * rng.uniform()) * (i == 0 ? 1.f : 0.8f); q.rough = rng.uniform();
                panGains(pan, q.gl, q.gr);
                at += 0.45f + 0.25f * rng.uniform();
            }
            nextCall = (8.f + 17.f * rng.uniform()) / c.density;
        }
        for (auto &q : cries) {
            if (!q.on) continue;
            for (int t = 0; t < n; ++t) {
                q.t += invSr;
                if (q.t < 0) continue;
                if (q.t > q.dur) { q.on = false; break; }
                const float u = q.t / q.dur;
                const float env = std::min(1.f, q.t / 0.03f) * std::min(1.f, (q.dur - q.t) / 0.08f);
                const float f = q.f1 * (1.f - 0.45f * u * u) * (1.f + 0.03f * sin2pi(25.f * q.t + q.rough));
                q.ph += f * invSr;
                const float x = sin2pi(q.ph) + 0.5f * sin2pi(2.f * q.ph) + 0.3f * sin2pi(3.f * q.ph) + 0.2f * sin2pi(4.f * q.ph);
                const float y = q.amp * env * x;
                l[t] += topL.low(formantL.band(y * q.gl));
                r[t] += topR.low(formantR.band(y * q.gr));
            }
        }
    }
};

// ---------------------------------------------------------------- Road (tyres and expansion joints)
class Road final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    Brown brown;
    SVF lpL, lpR, rumble, thumpLP, hissL, hissR;
    float toJoint = 12, thumpT = 10, thumpGap = 0.1f, thumpAmp = 0;

public:
    explicit Road(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.2f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, sp = c.speed;
        const float v = 8.f + 22.f * sp;   // metres per second (about 30–110 km/h)
        lpL.set(300.f + 900.f * sp, 0.7f, fsr); lpR.set(320.f + 880.f * sp, 0.7f, fsr);
        rumble.set(90.f, 1.f, fsr); thumpLP.set(400.f, 0.7f, fsr);
        hissL.set(6300.f, 0.55f, fsr); hissR.set(6600.f, 0.55f, fsr);
        const float level = 0.3f + 0.7f * sp, hiss = 0.22f * sp * c.wetness;   // a wet road: tyre spray
        // Joints every ~30 m: a pair of thumps, front then rear wheels.
        if ((toJoint -= v * dt) <= 0) {
            toJoint = 30.f * (0.8f + 0.4f * rng.uniform());
            thumpT = 0; thumpGap = 2.7f / v; thumpAmp = 0.5f * (0.5f + 0.5f * sp);
        }
        for (int t = 0; t < n; ++t) {
            const float tyreL = lpL.low(pinkL.next(rng.bipolar())), tyreR = lpR.low(pinkR.next(rng.bipolar()));
            const float low = 0.5f * rumble.band(brown.next(rng.bipolar()) * 8.f);
            float th = 0;
            if (thumpT < 1.f) {
                for (float at : {0.f, thumpGap}) {
                    const float u = thumpT - at;
                    if (u >= 0 && u < 0.3f) th += thumpAmp * (std::exp(-u / 0.05f) * sin2pi(50.f * u) + 0.6f * std::exp(-u / 0.02f) * thumpLP.low(rng.bipolar()));
                }
                thumpT += invSr;
            }
            const float wl = hiss > 0 ? hiss * hissL.band(rng.bipolar()) : 0.f, wr = hiss > 0 ? hiss * hissR.band(rng.bipolar()) : 0.f;
            l[t] += level * (tyreL + low) + th + wl;
            r[t] += level * (tyreR + low) + th + wr;
        }
    }
};


// ---------------------------------------------------------------- Tone oscillators (engine purr, passing cars)
/// Advances a tone oscillator's phase (in cycles, kept in 0…1 so a float holds it exactly enough: harmonics
/// are whole multiples, so the wrap is seamless) by one sample's increment.
inline void advanceTone(float &ph, float inc) {
    ph += inc;
    if (ph >= 1.f) ph -= 1.f;
}

// ---------------------------------------------------------------- Engine (a soft purr that follows the speed)
class EngineHum final : public AmbienceSource {
    FastRandom rng;
    Wander load;
    SVF top;
    float ph = 0;

public:
    explicit EngineHum(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.15f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, sp = c.speed;
        const float w = load.next(rng, dt, 2.f);
        const float f = (35.f + 35.f * sp) * (1.f + 0.03f * (w - 0.5f));
        const float level = (0.4f + 0.6f * sp) * (0.9f + 0.2f * w);
        top.set(250.f, 0.7f, fsr);
        for (int t = 0; t < n; ++t) {
            advanceTone(ph, f * invSr);
            float x = 0;
            const float amps[6] = {1.f, 0.7f, 0.25f, 0.4f, 0.12f, 0.15f};   // a four-cylinder's even orders
            for (int k = 0; k < 6; ++k) x += amps[k] * sin2pi((float)(k + 1) * ph);
            const float y = level * top.low(0.3f * x + 0.05f * rng.bipolar());
            l[t] += y; r[t] += y;
        }
    }
};

// ---------------------------------------------------------------- Wind at the window
class WindowWind final : public AmbienceSource {
    FastRandom rng;
    Wander gust;
    SVF rushL, rushR, whistle;

public:
    explicit WindowWind(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.2f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, sp = c.speed;
        const float g = gust.next(rng, dt, 1.7f);
        rushL.set(600.f + 1500.f * sp, 1.2f, fsr); rushR.set(650.f + 1450.f * sp, 1.2f, fsr);
        whistle.set(1800.f + 600.f * sp + 80.f * g, 12.f, fsr);
        const float amp = (0.15f + 0.85f * sp * sp) * (0.8f + 0.4f * g), wh = 0.15f * sp * sp;
        for (int t = 0; t < n; ++t) {
            const float a = rng.bipolar(), b = rng.bipolar();
            const float w = wh * whistle.band(a + b);
            l[t] += amp * rushL.band(a) + w;
            r[t] += amp * rushR.band(b) + 0.8f * w;
        }
    }
};

// ---------------------------------------------------------------- A car passing the other way
class PassingCar final : public AmbienceSource {
    FastRandom rng;
    SVF sweepL, sweepR;
    float nextCar = 6, t = -1, dur = 3, dir = 1, ph = 0;

public:
    explicit PassingCar(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void wake(const AmbienceContext &) override { nextCar = 4.f + 10.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (t < 0 && (nextCar -= dt) <= 0) {
            t = 0; dur = 2.6f + 1.2f * rng.uniform(); dir = rng.uniform() < 0.5f ? -1.f : 1.f;
            nextCar = (15.f + 30.f * rng.uniform()) / c.density;
        }
        if (t < 0) return;
        const float x0 = (t / dur) * 2.f - 1.f;
        const float centre = 1100.f * (1.f - 0.45f * std::tanh(3.f * x0));
        sweepL.set(centre, 1.5f, fsr); sweepR.set(centre * 1.03f, 1.5f, fsr);
        for (int i = 0; i < n; ++i) {
            const float x = (t / dur) * 2.f - 1.f;
            const float env = std::exp(-(x / 0.35f) * (x / 0.35f));
            const float pan = 0.9f * dir * x;
            float gl, gr; panGains(pan, gl, gr);
            advanceTone(ph, 95.f * (1.f - 0.15f * std::tanh(3.f * x)) * invSr);
            const float tone = 0.25f * sin2pi(ph) + 0.1f * sin2pi(2.f * ph);
            const float a = rng.bipolar(), b = rng.bipolar();
            l[i] += env * gl * (sweepL.band(a) + tone);
            r[i] += env * gr * (sweepR.band(b) + tone);
            t += invSr;
        }
        if (t > dur) t = -1;
    }
};


// ---------------------------------------------------------------- Short noise bursts and decaying tones (shared)
/// A filtered noise burst: an attack of a fraction of a millisecond, an exponential tail.
struct Burst {
    SVF f;
    float amp = 0, decay = 0, gl = 0.7f, gr = 0.7f;
    int left = 0;
    void start(float hz, float q, float seconds, float a, float pan, float sr) {
        f.clear(); f.set(hz, q, sr);
        amp = a; left = (int)(seconds * sr); decay = std::exp(-2.5f / std::max(1.f, (float)left));   // ends near −22 dB
        panGains(pan, gl, gr);
    }
    bool on() const { return left > 0 || amp > 1e-5f; }
    inline float next(FastRandom &rng) {
        const float x = left > 0 ? rng.bipolar() * amp : 0.f;
        if (left > 0) { --left; amp *= decay; } else amp = 0.f;
        return f.band(x);
    }
};

/// A decaying sine with an optional upward glide (drips, thumps, pings).
struct Ping {
    float ph = 0, inc = 0, glide = 0, glideStep = 0, amp = 0, decay = 1, gl = 0.7f, gr = 0.7f;
    void start(float hz, float t60, float a, float pan, float sr, float rise = 0.f, float riseSeconds = 0.015f) {
        ph = 0; inc = hz / sr; glide = 0; glideStep = rise > 0 ? rise / (riseSeconds * sr) : 0;
        glideTo = rise; amp = a; decay = std::pow(10.f, -3.f / (std::max(0.005f, t60) * sr));
        panGains(pan, gl, gr);
    }
    float glideTo = 0;
    bool on() const { return amp > 1e-5f; }
    inline float next() {
        if (amp <= 1e-5f) { amp = 0; return 0.f; }
        if (glide < glideTo) glide = std::min(glideTo, glide + glideStep);
        ph += inc * (1.f + glide);
        if (ph >= 1.f) ph -= 1.f;
        const float y = amp * sin2pi(ph);
        amp *= decay;
        return y;
    }
};

// ---------------------------------------------------------------- Fireplace
class Fire final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF roarL, roarR, hissF;
    Wander flicker, breathe, crackleRate, popRate;
    Burst crackles[10];
    Ping thumps[3];
    int nextCrackle = 0, nextThump = 0;
    float toHiss = 30, hissT = -1, hissDur = 2, hissAmp = 0, toSettle = 90, shower = 0;

public:
    explicit Fire(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; indoor = true; }
    void wake(const AmbienceContext &c) override {
        toHiss = (20.f + 40.f * rng.uniform()) / c.density;
        toSettle = (60.f + 120.f * rng.uniform()) / c.density;
    }
    void crackle(float sr, float scale) {
        Burst &b = crackles[nextCrackle]; nextCrackle = (nextCrackle + 1) % 10;
        const float u = rng.uniform();
        b.start(1000.f * std::pow(5.f, rng.uniform()), 1.4f, 0.001f + 0.004f * rng.uniform(), scale * (3.5f + 3.f * u * u), 0.7f * rng.bipolar(), sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        roarL.set(300.f, 0.6f, fsr); roarR.set(320.f, 0.6f, fsr); hissF.set(5500.f, 0.9f, fsr);
        const float roar = 0.4f * (0.55f + 0.45f * flicker.next(rng, dt, 0.35f)) * (0.8f + 0.2f * breathe.next(rng, dt, 3.f));
        // Crackles 2–8 a second (a shower of them as a log settles), pops 0.1–0.5 a second with a low thump.
        const float cr = (2.f + 6.f * crackleRate.next(rng, dt, 4.f)) * c.density * (shower > 0 ? 8.f : 1.f);
        const float pr = (0.1f + 0.4f * popRate.next(rng, dt, 8.f)) * c.density;
        if (shower > 0) shower -= dt;
        if ((toHiss -= dt) <= 0) {
            hissT = 0; hissDur = 1.f + 2.f * rng.uniform(); hissAmp = 0.05f + 0.06f * rng.uniform();
            toHiss = (20.f + 40.f * rng.uniform()) / c.density;
        }
        if ((toSettle -= dt) <= 0) {
            Ping &p = thumps[nextThump]; nextThump = (nextThump + 1) % 3;
            p.start(65.f + 15.f * rng.uniform(), 0.35f, 0.9f, 0.2f * rng.bipolar(), fsr);
            shower = 1.f;
            toSettle = (60.f + 120.f * rng.uniform()) / c.density;
        }
        const float pc = cr / fsr, pp = pr / fsr, invSr = 1.f / fsr;
        for (int t = 0; t < n; ++t) {
            if (rng.uniform() < pc) crackle(fsr, 1.f);
            if (rng.uniform() < pp) {
                crackle(fsr, 1.8f);
                Ping &p = thumps[nextThump]; nextThump = (nextThump + 1) % 3;
                p.start(60.f + 60.f * rng.uniform(), 0.18f, 0.5f + 0.3f * rng.uniform(), 0.5f * rng.bipolar(), fsr);
            }
            float yl = roar * roarL.band(pinkL.next(rng.bipolar())), yr = roar * roarR.band(pinkR.next(rng.bipolar()));
            for (auto &b : crackles) {
                if (!b.on()) continue;
                const float y = b.next(rng);
                yl += y * b.gl; yr += y * b.gr;
            }
            for (auto &p : thumps) {
                if (!p.on()) continue;
                const float y = p.next();
                yl += y * p.gl; yr += y * p.gr;
            }
            if (hissT >= 0) {
                const float x = hissT / hissDur, env = x < 1.f ? std::sin(kPi * x) : 0.f;
                const float h = hissAmp * env * hissF.band(rng.bipolar());
                yl += h; yr += 0.9f * h;
                hissT += invSr;
                if (hissT > hissDur) hissT = -1;
            }
            l[t] += yl; r[t] += yr;
        }
    }
};

// ---------------------------------------------------------------- Kettle (an occasional cycle in the kitchen)
class Kettle final : public AmbienceSource {
    FastRandom rng;
    Brown brown;
    SVF rumbleBand, rumbleTop, clickF;
    Ping bubbles[6];
    Partial clink[3];
    int nextBubble = 0;
    float untilNext = 120, rumble = 0, clickLeft = 0;
    double t = -1, clinkAt = -1;   // seconds into the cycle (double: a float drifts by seconds over 100 s of samples)
    bool clicked = false;

    static constexpr double kClickAt = 100.0;   // seconds from switching on to the click

public:
    explicit Kettle(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.4f; indoor = true; }
    float interval(const AmbienceContext &c) { return (240.f + 240.f * rng.uniform()) / c.density; }
    void wake(const AmbienceContext &c) override { untilNext = interval(c) * (0.15f + 0.35f * rng.uniform()); }
    void start(const AmbienceContext &c) { t = 0; clicked = false; clinkAt = -1; untilNext = interval(c); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        const double step = 1.0 / (double)fsr;
        if (t < 0 && (untilNext -= dt) <= 0) start(c);
        if (t < 0) return;
        rumbleBand.set(160.f, 0.5f, fsr); rumbleTop.set(400.f, 0.7f, fsr); clickF.set(3000.f, 0.5f, fsr);
        // Heating: a rumble rising over 90 s; bubbles from 70 s, densest in the last 20 s; then the click and,
        // a few seconds later, the clink of the switch settling.
        float target = 0;
        const float tf = (float)t;
        if (!clicked) { const float x = std::min(1.f, tf / 90.f); target = x * std::sqrt(x); }
        const float boil = std::min(1.f, (tf - 70.f) / 30.f);
        const float bubbleRate = (!clicked && tf > 70.f) ? 2.f + 36.f * boil * boil : 0.f;
        const float pb = bubbleRate / fsr;
        for (int i = 0; i < n; ++i) {
            rumble += (target - rumble) * (clicked ? 2.f * invSr : 0.5f * invSr);
            float y = rumble * 1.4f * rumbleTop.low(rumbleBand.band(brown.next(rng.bipolar()) * 8.f));
            if (rng.uniform() < pb) {
                Ping &b = bubbles[nextBubble]; nextBubble = (nextBubble + 1) % 6;
                b.start(400.f * std::pow(4.f, rng.uniform()), 0.025f + 0.03f * rng.uniform(), 0.06f + 0.1f * rng.uniform(), 0.4f * rng.bipolar(), fsr, 0.3f, 0.01f);
            }
            float yl = y, yr = y;
            for (auto &b : bubbles) { if (!b.on()) continue; const float s = b.next(); yl += s * b.gl; yr += s * b.gr; }
            if (!clicked && t >= kClickAt) { clicked = true; clickLeft = 0.002f * fsr; clinkAt = t + 3.0 + 7.0 * rng.uniform(); }
            if (clickLeft > 0) { const float k = clickF.high(rng.bipolar() * 8.f); yl += k; yr += k; clickLeft -= 1.f; }
            if (clinkAt > 0 && t >= clinkAt) {
                const float hz[3] = {2800.f, 4100.f, 6300.f}, amp[3] = {0.35f, 0.25f, 0.15f};
                for (int k = 0; k < 3; ++k) clink[k].start(hz[k] * (0.98f + 0.04f * rng.uniform()), 0.6f, amp[k], fsr);
                clinkAt = -1;
            }
            float ping = 0;
            for (auto &p : clink) if (p.mag > 0) { ping += p.next(); if (p.energy() < 1e-12f) p.mag = 0; }
            l[i] += yl + ping; r[i] += yr + 0.9f * ping;
            t += step;
        }
        if (clicked && t > kClickAt + 20.0) t = -1;   // the cycle is over; the next comes after `untilNext`
        if (t >= 0) untilNext -= dt;
    }
};

// ---------------------------------------------------------------- A waking street, far below the window
class Street final : public AmbienceSource {
    FastRandom rng;
    Brown brownL, brownR;
    SVF bedL, bedR, bedTopL, bedTopR, brake, busLow;
    Wander swell;
    struct Car { SVF f; float t = -1, dur = 5, pan = 0, dir = 1, amp = 1; } cars[3];
    Partial bell[4];
    Ping door, busTone;
    float toCar = 5, toBell = 90, toBus = 120, toDoor = 60, bellSecond = -1, bellF = 2900, busT = -1;

public:
    explicit Street(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.5f; }
    void wake(const AmbienceContext &c) override {
        toCar = (2.f + 6.f * rng.uniform()) / c.density;
        toBell = (60.f + 120.f * rng.uniform()) / c.density;
        toBus = (90.f + 150.f * rng.uniform()) / c.density;
        toDoor = (45.f + 105.f * rng.uniform()) / c.density;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        bedL.set(220.f, 0.5f, fsr); bedR.set(240.f, 0.5f, fsr); bedTopL.set(600.f, 0.7f, fsr); bedTopR.set(620.f, 0.7f, fsr);
        const float bed = 0.75f + 0.25f * swell.next(rng, dt, 6.f);
        if ((toCar -= dt) <= 0) {
            for (auto &car : cars) if (car.t < 0) {
                car.t = 0; car.dur = 4.f + 4.f * rng.uniform(); car.dir = rng.uniform() < 0.5f ? -1.f : 1.f; car.amp = 0.6f + 0.5f * rng.uniform();
                ++events;
                break;
            }
            // The street wakes up: the higher its level (the later the morning), the more often a car goes by.
            const float busy = std::min(2.f, std::max(0.25f, level / 0.4f));
            toCar = (6.f + 14.f * rng.uniform()) / (c.density * busy);
        }
        if ((toBell -= dt) <= 0) {
            const float f = 2600.f + 600.f * rng.uniform();
            bellF = f;
            bell[0].start(f, 0.9f, 0.18f, fsr); bell[1].start(f * 1.19f, 0.6f, 0.08f, fsr);
            bellSecond = 0.17f;
            toBell = (60.f + 120.f * rng.uniform()) / c.density;
        }
        if (bellSecond > 0 && (bellSecond -= dt) <= 0) {
            bell[2].start(bellF, 0.9f, 0.16f, fsr); bell[3].start(bellF * 1.19f, 0.6f, 0.07f, fsr);   // the second ring
            bellSecond = -1;
        }
        if ((toBus -= dt) <= 0) { busT = 0; busTone.start(48.f + 8.f * rng.uniform(), 30.f, 0.f, 0.3f * rng.bipolar(), fsr); toBus = (90.f + 150.f * rng.uniform()) / c.density; }
        if ((toDoor -= dt) <= 0) { door.start(120.f, 0.25f, 0.5f, 0.6f * rng.bipolar(), fsr); toDoor = (45.f + 105.f * rng.uniform()) / c.density; }
        busLow.set(300.f, 0.7f, fsr);
        for (int i = 0; i < n; ++i) {
            float yl = bed * bedTopL.low(bedL.band(brownL.next(rng.bipolar()) * 6.f));
            float yr = bed * bedTopR.low(bedR.band(brownR.next(rng.bipolar()) * 6.f));
            for (auto &car : cars) {
                if (car.t < 0) continue;
                const float x = (car.t / car.dur) * 2.f - 1.f, env = std::exp(-(x / 0.45f) * (x / 0.45f)) * car.amp;
                car.f.set(500.f * (1.f - 0.3f * std::tanh(2.f * x)), 0.9f, fsr);
                float gl, gr; panGains(0.7f * car.dir * x, gl, gr);
                const float s = env * car.f.band(rng.bipolar()) * 0.5f;
                yl += s * gl; yr += s * gr;
                car.t += invSr;
                if (car.t > car.dur) car.t = -1;
            }
            float ring = 0;
            for (auto &p : bell) if (p.mag > 0) { ring += p.next(); if (p.energy() < 1e-12f) p.mag = 0; }
            yl += 0.8f * ring; yr += ring;
            if (busT >= 0) {
                // A bus: its engine swells over six seconds, then the air brakes sigh down through the band.
                const float x = busT / 6.f, env = x < 1.f ? std::sin(kPi * x) : 0.f;
                const float engine = env * (0.25f * std::sin(kTwoPi * busTone.ph) + 0.4f * busLow.low(rng.bipolar()));
                busTone.ph += busTone.inc; if (busTone.ph >= 1.f) busTone.ph -= 1.f;
                float sigh = 0;
                if (busT > 5.f && busT < 6.5f) {
                    const float u = (busT - 5.f) / 1.5f;
                    brake.set(3000.f * std::pow(800.f / 3000.f, u), 1.2f, fsr);
                    sigh = 0.35f * (1.f - u) * brake.band(rng.bipolar());
                }
                yl += engine + sigh; yr += 0.8f * engine + sigh;
                busT += invSr;
                if (busT > 7.f) busT = -1;
            }
            if (door.on()) { const float d = door.next(); yl += d * door.gl; yr += d * door.gr; }
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- Drips (after the rain)
class Drips final : public AmbienceSource {
    FastRandom rng;
    Wander rate;
    Ping drops[6];
    int next = 0;

public:
    explicit Drips(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.45f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        // 0.5–4 drips a second, thinning as the level falls.
        const float perSecond = (0.5f + 3.5f * rate.next(rng, dt, 6.f)) * std::max(0.f, level) * c.density;
        const float p = perSecond / fsr;
        for (int i = 0; i < n; ++i) {
            if (rng.uniform() < p) {
                Ping &d = drops[next]; next = (next + 1) % 6;
                const bool gutter = rng.uniform() < 0.3f;
                const float hz = 1000.f * std::pow(3.f, rng.uniform()) * (gutter ? 1.6f : 1.f);
                d.start(hz, 0.07f + 0.12f * rng.uniform(), 0.4f + 0.6f * rng.uniform(), 0.8f * rng.bipolar(), fsr, 0.2f, 0.015f);
            }
            float yl = 0, yr = 0;
            for (auto &d : drops) { if (!d.on()) continue; const float y = d.next(); yl += y * d.gl; yr += y * d.gr; }
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- A clock on the wall
class Clock final : public AmbienceSource {
    FastRandom rng;
    Burst tick;
    SVF body;
    double toTick = 0.25;
    bool tock = false;

public:
    explicit Clock(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.5f; indoor = true; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const double period = 1.0, invSr = 1.0 / (double)c.sr;
        for (int i = 0; i < n; ++i) {
            toTick -= invSr;
            if (toTick <= 0) {
                toTick += period;
                tick.start(tock ? 2600.f : 3200.f, 4.f, 0.003f, 6.f, tock ? 0.15f : -0.15f, c.sr);
                tock = !tock;
            }
            if (tick.on()) { const float y = tick.next(rng); l[i] += y * tick.gl; r[i] += y * tick.gr; }
        }
    }
};

// ---------------------------------------------------------------- Ice on the fjord: a creak bed, deep groans, cracks
class IceGroan final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF creakL, creakR, creakTopL, creakTopR;
    Wander creakF, creakA;
    // A groan: a resonant sweep through 40–120 Hz over 1–4 s (a tone with a few harmonics and a moaning noise band).
    struct Groan { float t = -1, dur = 2, f0 = 100, f1 = 45, ph = 0, gl = 0.7f, gr = 0.7f, amp = 1, wob = 6; SVF res, top; Brown brown; } groan;
    // A crack: a 1–3 ms broadband click, then a ~300 ms ring at 1–2 kHz.
    Burst click;
    Partial ring[2];
    float ringGl = 0.7f, ringGr = 0.7f, toGroan = 10, toCrack = 8;

public:
    explicit IceGroan(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.6f; }
    float groanInterval(const AmbienceContext &c) { return (20.f + 70.f * rng.uniform()) / c.density; }
    float crackInterval(const AmbienceContext &c) { return (15.f + 45.f * rng.uniform()) / c.density; }
    void wake(const AmbienceContext &c) override {
        toGroan = groanInterval(c) * (0.1f + 0.4f * rng.uniform());
        toCrack = crackInterval(c) * (0.1f + 0.4f * rng.uniform());
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        // The bed: a faint stick-slip creak, a narrow noise band wandering through 250–650 Hz.
        const float cf = 250.f + 400.f * creakF.next(rng, dt, 3.f), ca = 0.5f + 0.5f * creakA.next(rng, dt, 2.f);
        creakL.set(cf, 4.f, fsr); creakR.set(cf * 1.06f, 4.f, fsr); creakTopL.set(900.f, 0.7f, fsr); creakTopR.set(950.f, 0.7f, fsr);
        if (groan.t < 0 && (toGroan -= dt) <= 0) {
            groan.t = 0; groan.dur = 1.f + 3.f * rng.uniform(); groan.ph = 0;
            const float lo = 40.f + 15.f * rng.uniform(), hi = 95.f + 25.f * rng.uniform();
            if (rng.uniform() < 0.6f) { groan.f0 = hi; groan.f1 = lo; } else { groan.f0 = lo; groan.f1 = hi; }
            groan.amp = 0.7f + 0.3f * rng.uniform(); groan.wob = 4.f + 5.f * rng.uniform();
            panGains(0.7f * rng.bipolar(), groan.gl, groan.gr);
            groan.top.set(260.f, 0.7f, fsr);
            toGroan = groanInterval(c);
            ++events;
        }
        if ((toCrack -= dt) <= 0) {
            const float pan = 0.8f * rng.bipolar();
            // At 16 the cracks were the loudest thing in the ambience (0.997 peak over 30 min at level 1, density 1.5);
            // at 8 they peak at 0.58 and still stand 28–35 dB over the 200 ms around them.
            click.start(3500.f, 0.35f, 0.001f + 0.002f * rng.uniform(), 8.f, pan, fsr);
            const float f = 1000.f + 1000.f * rng.uniform();
            ring[0].start(f, 0.3f, 0.12f, fsr); ring[1].start(f * 1.47f, 0.2f, 0.06f, fsr);
            panGains(pan, ringGl, ringGr);
            toCrack = crackInterval(c);
            ++events;
        }
        float f = 0, inc = 0;
        if (groan.t >= 0) {
            const float u = std::min(1.f, groan.t / groan.dur);
            f = groan.f0 * std::pow(groan.f1 / groan.f0, u);
            groan.res.set(f, 6.f, fsr);
            inc = f * invSr;
        }
        for (int i = 0; i < n; ++i) {
            const float wl = rng.bipolar(), wr = rng.bipolar();
            float yl = 1.4f * ca * creakTopL.low(creakL.band(pinkL.next(wl))), yr = 1.4f * ca * creakTopR.low(creakR.band(pinkR.next(wr)));
            if (groan.t >= 0) {
                const float u = groan.t / groan.dur, s = std::sin(kPi * std::min(1.f, u)), env = s * s;
                const float wobble = 0.75f + 0.25f * sin2pi(groan.wob * groan.t);
                advanceTone(groan.ph, inc);
                const float tone = sin2pi(groan.ph) + 0.35f * sin2pi(2.f * groan.ph) + 0.15f * sin2pi(3.f * groan.ph);
                const float moan = groan.res.band(groan.brown.next(rng.bipolar()) * 10.f);
                const float y = groan.amp * env * wobble * groan.top.low(0.6f * tone + moan);
                yl += 2.5f * y * groan.gl; yr += 2.5f * y * groan.gr;
                groan.t += invSr;
                if (groan.t > groan.dur) groan.t = -1;
            }
            if (click.on()) { const float k = click.next(rng); yl += k * click.gl; yr += k * click.gr; }
            float rg = 0;
            for (auto &p : ring) if (p.mag > 0) { rg += p.next(); if (p.energy() < 1e-12f) p.mag = 0; }
            yl += rg * ringGl; yr += rg * ringGr;
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- A far waterfall: a white roar over a low rumble
class Waterfall final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    Brown brownL, brownR;
    SVF hpL, hpR, lpL, lpR, rumL, rumR;
    Wander wander;
    float ph = 0, g = 1;

public:
    explicit Waterfall(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.6f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        hpL.set(200.f, 0.7f, fsr); hpR.set(210.f, 0.7f, fsr); lpL.set(3000.f, 0.7f, fsr); lpR.set(2900.f, 0.7f, fsr);
        rumL.set(80.f, 1.2f, fsr); rumR.set(90.f, 1.2f, fsr);
        // A slow flicker (about 0.1 Hz, ±1.5 dB) as the spray shifts.
        ph += 0.1f * dt; if (ph >= 1.f) ph -= 1.f;
        const float g1 = 1.f + 0.11f * sin2pi(ph) + 0.07f * (wander.next(rng, dt, 3.f) - 0.5f);
        const float dg = (g1 - g) / (float)n;
        for (int i = 0; i < n; ++i) {
            g += dg;
            const float wl = rng.bipolar(), wr = rng.bipolar();
            l[i] += g * lpL.low(hpL.high(pinkL.next(wl))) + 0.5f * rumL.band(brownL.next(rng.bipolar()) * 6.f);
            r[i] += g * lpR.low(hpR.high(pinkR.next(wr))) + 0.5f * rumR.band(brownR.next(rng.bipolar()) * 6.f);
        }
    }
};

// ---------------------------------------------------------------- Lapping: small waves against a hull and rocks
class Lapping final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF hpL, hpR, lpL, lpR;
    struct Slosh { float t = -1, dur = 0.5f, amp = 1, pan = 0; } slosh;
    Ping knock, knock2;
    Burst thud;
    float toSlosh = 1, toKnock = 10, env = 0, gl = 0.7f, gr = 0.7f;

public:
    explicit Lapping(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.4f; }
    void wake(const AmbienceContext &c) override {
        toSlosh = 0.3f + 1.5f * rng.uniform();
        toKnock = (8.f + 22.f * rng.uniform()) / c.density * (0.2f + 0.5f * rng.uniform());
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        if (slosh.t < 0 && (toSlosh -= dt) <= 0) {
            slosh = {0, 0.3f + 0.5f * rng.uniform(), 0.6f + 0.4f * rng.uniform(), 0.6f * rng.bipolar()};
            toSlosh = (2.f + 4.f * rng.uniform()) / c.density;
            ++events;
        }
        if ((toKnock -= dt) <= 0) {
            // A hollow knock: the hull's 180 Hz resonance, damped, with a soft thud on the strike.
            const float pan = 0.5f * rng.bipolar(), f = 170.f + 20.f * rng.uniform();
            knock.start(f, 0.18f, 0.5f + 0.3f * rng.uniform(), pan, fsr);
            knock2.start(f * 2.31f, 0.08f, 0.15f, pan, fsr);
            thud.start(700.f, 1.f, 0.006f, 1.2f, pan, fsr);
            toKnock = (8.f + 22.f * rng.uniform()) / c.density;
        }
        float target = 0;
        if (slosh.t >= 0) {
            const float u = slosh.t / slosh.dur;
            target = u < 1.f ? slosh.amp * std::sin(kPi * u) : 0.f;
            slosh.t += dt;
            if (slosh.t > slosh.dur) slosh.t = -1;
            if (u < 0.05f) panGains(slosh.pan, gl, gr);
        }
        hpL.set(300.f, 0.7f, fsr); hpR.set(310.f, 0.7f, fsr);
        lpL.set(900.f + 1100.f * env, 0.8f, fsr); lpR.set(950.f + 1050.f * env, 0.8f, fsr);
        const float de = (target - env) / (float)n;
        for (int i = 0; i < n; ++i) {
            env += de;
            const float a = 0.13f + env;
            float yl = a * (0.6f + 0.8f * gl) * lpL.low(hpL.high(pinkL.next(rng.bipolar())));
            float yr = a * (0.6f + 0.8f * gr) * lpR.low(hpR.high(pinkR.next(rng.bipolar())));
            if (knock.on()) { const float k = knock.next() + knock2.next(); yl += k * knock.gl; yr += k * knock.gr; }
            if (thud.on()) { const float k = thud.next(rng); yl += k * thud.gl; yr += k * thud.gr; }
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- A distant outboard crossing the bay
class Boat final : public AmbienceSource {
    FastRandom rng;
    SVF lp1, lp2, washHp, washLp;
    Pink pinkW;
    double t = -1;
    float untilNext = 200, dur = 15, dir = 1, f = 75, ph = 0, pulse = 0, washDur = 7, washPan = 0;

public:
    explicit Boat(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; }
    float interval(const AmbienceContext &c) { return (150.f + 250.f * rng.uniform()) / c.density; }
    void wake(const AmbienceContext &c) override { untilNext = interval(c) * (0.15f + 0.35f * rng.uniform()); }
    void start(const AmbienceContext &c) {
        t = 0; dur = 13.f + 7.f * rng.uniform(); dir = rng.uniform() < 0.5f ? -1.f : 1.f; f = 60.f + 30.f * rng.uniform();
        washDur = 6.f + 3.f * rng.uniform(); washPan = 0.6f * dir;
        untilNext = interval(c);
        ++events;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (t < 0 && (untilNext -= dt) <= 0) start(c);
        if (t < 0) return;
        untilNext -= dt;   // the next pass is timed from this one's start
        lp1.set(320.f, 0.7f, fsr); lp2.set(320.f, 0.7f, fsr);
        washHp.set(300.f, 0.7f, fsr); washLp.set(1500.f, 0.7f, fsr);
        const float x0 = (float)t / dur;
        // A little Doppler: the note sinks as the boat passes.
        const float hz = f * (1.f + 0.025f * (1.f - 2.f * std::min(1.f, x0)));
        float gl, gr; panGains(0.9f * dir * (2.f * std::min(1.f, x0) - 1.f), gl, gr);
        float wl, wr; panGains(washPan, wl, wr);
        const float washStart = 0.6f * dur;
        for (int i = 0; i < n; ++i) {
            const float tf = (float)t, x = tf / dur;
            float y = 0;
            if (x < 1.f) {
                const float env = std::sin(kPi * x);
                advanceTone(ph, hz * invSr);
                advanceTone(pulse, 25.f * invSr);
                const float p = 0.5f + 0.5f * sin2pi(pulse), throb = 0.3f + 0.7f * p * p;
                const float saw = 2.f * ph - 1.f;
                y = env * throb * lp2.low(lp1.low(saw));
            }
            l[i] += y * gl; r[i] += y * gr;
            const float u = (tf - washStart) / washDur;
            if (u > 0.f && u < 1.f) {
                // The wake arrives: a soft wash in slow waves.
                const float s = std::sin(kPi * u), wave = 0.55f + 0.45f * sin2pi(0.7f * tf);
                const float w = 0.35f * s * wave * washLp.low(washHp.high(pinkW.next(rng.bipolar())));
                l[i] += w * wl; r[i] += w * wr;
            }
            t += 1.0 / (double)fsr;
        }
        if (t > (double)(washStart + washDur) && t > (double)dur) t = -1;
    }
};

// ---------------------------------------------------------------- Temple bell: a far bonshō in the player's key
/// The tonic of a key (root 0…11, C = 0) in the bell's octave, A1–G♯2 (55–104 Hz).
inline float bellTonicHz(int root) {
    const int r = ((root % 12) + 12) % 12;
    return 440.f * std::exp2((float)(33 + (r + 3) % 12 - 69) / 12.f);   // A → MIDI 33 (A1) … G♯ → MIDI 44 (G♯2)
}

class TempleBell final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kModes = 6;
    // The hum partials (about 1, 1.6, 2.3 and 3.0 × f0, ringing 11 down to 6 s) and two short strike partials above.
    static constexpr float kRatio[kModes] = {1.f, 1.6f, 2.3f, 3.f, 4.15f, 5.4f};
    static constexpr float kAmp[kModes] = {1.f, 0.6f, 0.42f, 0.3f, 0.12f, 0.07f};
    static constexpr float kT60[kModes] = {11.f, 9.f, 7.5f, 6.2f, 2.f, 1.2f};
    struct Strike {
        bool on = false;
        uint32_t serial = 0;
        int check = 0;
        float hz = 0;
        Partial p[kModes];
        // The beat: each partial swells and fades (a doublet's slow 0.2–0.45 Hz beating, 0.3 Hz on the hum).
        float am[kModes] = {}, beat[kModes] = {}, beatInc[kModes] = {}, depth[kModes] = {};
        Burst click;
    } strikes[3];
    float untilNext = 60, gl = 0.7f, gr = 0.7f;
    uint32_t serial = 0;

    float interval(const AmbienceContext &c) { return (120.f + 180.f * rng.uniform()) / c.density; }

    /// The pitch is the key's tonic at the moment of the strike: a strike never changes once it rings.
    void strike(const AmbienceContext &c) {
        Strike *s = nullptr;
        for (auto &x : strikes) if (!x.on) { s = &x; break; }
        if (!s) { s = &strikes[0]; for (auto &x : strikes) if (x.serial < s->serial) s = &x; }   // the oldest ring makes room
        const float v = 0.85f + 0.15f * rng.uniform();   // how hard the beam swings
        s->hz = bellTonicHz(c.keyRoot);
        for (int k = 0; k < kModes; ++k) {
            const float spread = k == 0 ? 1.f : 1.f + 0.006f * rng.bipolar();   // a cast bell's upper partials are never exact
            s->p[k].startSine(s->hz * kRatio[k] * spread, kT60[k] * (0.92f + 0.16f * rng.uniform()), v * kAmp[k], c.sr);
            s->beatInc[k] = (k == 0 ? 0.3f : 0.2f + 0.25f * rng.uniform()) / c.sr;
            s->depth[k] = k == 0 ? 0.45f : 0.2f + 0.3f * rng.uniform();
            s->beat[k] = 0; s->am[k] = 1.f;
        }
        s->click.start(1200.f, 0.7f, 0.001f, 4.f * v, 0.f, c.sr);   // the wooden beam meeting the bronze
        s->on = true; s->check = 0; s->serial = ++serial;
        ++events;
    }

public:
    explicit TempleBell(uint64_t seed) : rng(seed) {
        // Mostly direct: snow and open gardens are acoustically dead, and the room's slowly modulated tail would blur
        // the bell's tuning (a send of 0.45 pulls the measured pitch up to 9 cents off; 0.3 stays within 1.5).
        direct = 1.f; send = 0.3f;
        panGains(0.35f * rng.bipolar(), gl, gr);   // the bell hangs where it hangs
    }
    void wake(const AmbienceContext &c) override {
        for (auto &s : strikes) s.on = false;
        untilNext = interval(c) * (0.15f + 0.35f * rng.uniform());
    }
    void strikeNow(const AmbienceContext &c) { strike(c); untilNext = interval(c); }
    float ringingHz() const {
        const Strike *newest = nullptr;
        for (auto &s : strikes) if (s.on && (!newest || s.serial > newest->serial)) newest = &s;
        return newest ? newest->hz : 0.f;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        if ((untilNext -= (float)n / c.sr) <= 0) { strike(c); untilNext = interval(c); }
        const int m = std::min(n, 64);
        for (auto &s : strikes) {
            if (!s.on) continue;
            float y[64] = {};
            for (int k = 0; k < kModes; ++k) {
                Partial &p = s.p[k];
                const float b1 = s.beat[k] + s.beatInc[k] * (float)m;
                const float a1 = 1.f - s.depth[k] * (0.5f - 0.5f * sin2pi(b1 + 0.25f)), da = (a1 - s.am[k]) / (float)m;
                float a = s.am[k];
                for (int t = 0; t < m; ++t) { a += da; y[t] += a * p.next(); }
                s.am[k] = a1; s.beat[k] = b1 - std::floor(b1);
            }
            if (s.click.on()) for (int t = 0; t < m; ++t) y[t] += s.click.next(rng);
            for (int t = 0; t < m; ++t) { l[t] += y[t] * gl; r[t] += y[t] * gr; }
            if (++s.check >= 16) {
                s.check = 0;
                float e = 0;
                for (auto &p : s.p) e += p.energy();
                if (e < 1e-10f) s.on = false;
            }
        }
    }
};

// ---------------------------------------------------------------- Paper screens: shoji in a draught (indoor)
class PaperScreens final : public AmbienceSource {
    FastRandom rng;
    SVF hpL, hpR, lpL, lpR;   // the paper's band, 1–4 kHz
    // A rustle: the paper flexing in the draught, a soft noise swell fluttering at 9–16 Hz with dry crinkles in it.
    struct Rustle { float t = -1, dur = 0.4f, amp = 1, rate = 12, ph = 0, gl = 0.7f, gr = 0.7f; } rustle;
    Burst ticks[2];   // the frame tapping in its track
    float tickAt[2] = {-1, -1};
    // A creak: the wooden frame's stick-slip, a slow pulse train through a 450–800 Hz resonance.
    struct Creak { float t = -1, dur = 0.5f, f0 = 30, f1 = 40, ph = 0, amp = 1, gl = 0.7f, gr = 0.7f; SVF wood, top; } creak;
    float toRustle = 10, toCreak = 100;
    int tail = 0;

    /// The draught: the higher the level (the world's wind), the more often the paper stirs.
    float rustleInterval(const AmbienceContext &c, float busy) { return (6.f + 14.f * rng.uniform()) / (c.density * busy); }
    float creakInterval(const AmbienceContext &c) { return (70.f + 130.f * rng.uniform()) / c.density; }

public:
    PaperScreens(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.4f; indoor = true;
        hpL.set(1000.f, 0.7f, sr); hpR.set(1060.f, 0.7f, sr); lpL.set(4000.f, 0.7f, sr); lpR.set(3800.f, 0.7f, sr);
    }
    void wake(const AmbienceContext &c) override {
        rustle.t = -1; creak.t = -1; tickAt[0] = tickAt[1] = -1;
        toRustle = rustleInterval(c, 1.f) * (0.2f + 0.6f * rng.uniform());
        toCreak = creakInterval(c) * (0.3f + 0.7f * rng.uniform());
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (rustle.t < 0 && (toRustle -= dt) <= 0) {
            rustle.t = 0; rustle.dur = 0.2f + 0.4f * rng.uniform(); rustle.amp = 0.8f + 0.2f * rng.uniform();
            rustle.rate = 9.f + 7.f * rng.uniform(); rustle.ph = rng.uniform();
            const float pan = 0.7f * rng.bipolar();
            panGains(pan, rustle.gl, rustle.gr);
            tickAt[0] = rustle.dur * (0.1f + 0.5f * rng.uniform());
            tickAt[1] = rng.uniform() < 0.5f ? tickAt[0] + 0.04f + 0.12f * rng.uniform() : -1.f;
            toRustle = rustleInterval(c, std::clamp(level / 0.5f, 0.25f, 1.5f));
            ++events;
        }
        if (creak.t < 0 && (toCreak -= dt) <= 0) {
            creak.t = 0; creak.dur = 0.3f + 0.5f * rng.uniform(); creak.f0 = 20.f + 25.f * rng.uniform();
            creak.f1 = creak.f0 * (0.7f + 0.6f * rng.uniform()); creak.amp = 0.6f + 0.4f * rng.uniform(); creak.ph = 0;
            creak.wood.set(450.f + 350.f * rng.uniform(), 6.f, fsr); creak.top.set(2000.f, 0.7f, fsr);
            panGains(0.8f * rng.bipolar(), creak.gl, creak.gr);
            toCreak = creakInterval(c);
        }
        const bool busy = rustle.t >= 0 || creak.t >= 0 || ticks[0].on() || ticks[1].on();
        if (busy) tail = (int)(0.05f * fsr); else if (tail <= 0) return; else tail -= n;   // let the band ring out, then rest
        const float pCrinkle = 180.f * invSr;
        for (int i = 0; i < n; ++i) {
            float xl = 0, xr = 0;
            if (rustle.t >= 0) {
                const float u = rustle.t / rustle.dur;
                const float a = u < 0.3f ? u / 0.3f : (u < 0.5f ? 1.f : 2.f - 2.f * u), env = rustle.amp * a * a * (3.f - 2.f * a);
                const float flap = 0.55f + 0.45f * (0.5f + 0.5f * sin2pi(rustle.ph));
                rustle.ph += rustle.rate * invSr;
                if (rustle.ph >= 1.f) rustle.ph -= 1.f;
                const float crinkle = rng.uniform() < pCrinkle ? 1.2f * rng.bipolar() : 0.f;
                xl = env * (flap * rng.bipolar() + crinkle) * rustle.gl;
                xr = env * (flap * rng.bipolar() + crinkle) * rustle.gr;
                for (int k = 0; k < 2; ++k)
                    if (tickAt[k] >= 0 && rustle.t >= tickAt[k]) {
                        ticks[k].start(3000.f + 2000.f * rng.uniform(), 3.f, 0.0005f + 0.0005f * rng.uniform(), 2.f + 2.f * rng.uniform(), 0.f, fsr);
                        tickAt[k] = -1;
                    }
                rustle.t += invSr;
                if (rustle.t > rustle.dur) rustle.t = -1;
            }
            for (auto &k : ticks) if (k.on()) { const float y = k.next(rng); xl += y * rustle.gl; xr += y * rustle.gr; }
            float yl = lpL.low(hpL.high(xl)), yr = lpR.low(hpR.high(xr));
            if (creak.t >= 0) {
                const float u = creak.t / creak.dur;
                creak.ph += (creak.f0 + (creak.f1 - creak.f0) * u) * invSr;
                float pulse = 0;
                if (creak.ph >= 1.f) { creak.ph -= 1.f; pulse = creak.amp * (0.6f + 0.4f * rng.uniform()) * 6.f; }
                const float y = std::sin(kPi * std::min(1.f, u)) * creak.top.low(creak.wood.band(pulse));
                yl += y * creak.gl; yr += y * creak.gr;
                creak.t += invSr;
                if (creak.t > creak.dur) creak.t = -1;
            }
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- Water-knocker (shishi-odoshi): fill, tip, clack
class WaterKnocker final : public AmbienceSource {
    FastRandom rng;
    SVF streamL, streamR, sloshBand, sloshTop;
    Wander gurgle;
    Ping bubbles[6];
    int nextBubble = 0;
    Burst knock;
    Partial ring[3];
    double t = 0;   // seconds into this fill (double: a float drifts over 40 s of samples)
    float fillDur = 25, flow = 1, sloshT = -1, clackIn = -1, resumeIn = -1, pan = 0, gl = 0.7f, gr = 0.7f;
    bool tipping = false;

    float fillTime(const AmbienceContext &c) { return (15.f + 25.f * rng.uniform()) / c.density; }

public:
    explicit WaterKnocker(uint64_t seed) : rng(seed) {
        direct = 1.f; send = 0.5f;
        pan = 0.5f * rng.bipolar();   // by its basin, in one place: the trickle, the slosh and the clack all come from there
        panGains(pan, gl, gr);
    }
    void wake(const AmbienceContext &c) override {
        fillDur = fillTime(c); t = fillDur * rng.uniform();   // part-full when you arrive
        flow = 1; sloshT = -1; clackIn = -1; resumeIn = -1; tipping = false;
    }
    void start(const AmbienceContext &c) { fillDur = fillTime(c); t = 0; flow = 1; sloshT = -1; clackIn = -1; resumeIn = -1; tipping = false; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (!tipping && t >= (double)fillDur) {
            // Full: the tube tips and pours (a slosh), then swings back and its end clacks on the stone.
            tipping = true; sloshT = 0; clackIn = 0.45f + 0.1f * rng.uniform();
        }
        // As the tube fills, the air column above the water shortens: the trickle's ring rises from 2 to 4 kHz.
        const float fill = tipping ? 1.f : std::min(1.f, (float)(t / (double)fillDur)), fc = 2000.f * std::exp2(fill);
        streamL.set(fc, 2.5f, fsr); streamR.set(fc * 1.04f, 2.5f, fsr);
        sloshBand.set(800.f, 0.8f, fsr); sloshTop.set(2500.f, 0.7f, fsr);
        // The stream runs into the tube while it fills; it spills past while the tube is down and settling.
        const bool filling = !tipping && resumeIn < 0;
        const float g = gurgle.next(rng, dt, 0.12f), pb = filling ? (14.f + 16.f * g) * invSr : 0.f;
        const float flowTarget = filling ? 1.f : 0.f, flowStep = 1.f - std::exp(-invSr / 0.04f);
        for (int i = 0; i < n; ++i) {
            flow += (flowTarget - flow) * flowStep;
            const float a = flow * (0.6f + 0.4f * g);
            float yl = a * 0.85f * gl * streamL.band(rng.bipolar()), yr = a * 0.85f * gr * streamR.band(rng.bipolar());
            if (rng.uniform() < pb) {
                Ping &b = bubbles[nextBubble]; nextBubble = (nextBubble + 1) % 6;
                b.start(fc * (0.8f + 0.45f * rng.uniform()), 0.02f + 0.02f * rng.uniform(), (0.09f + 0.15f * rng.uniform()) * flow,
                        pan + 0.15f * rng.bipolar(), fsr, 0.12f, 0.008f);
            }
            for (auto &b : bubbles) { if (!b.on()) continue; const float s = b.next(); yl += s * b.gl; yr += s * b.gr; }
            float y = 0;
            if (sloshT >= 0) {
                const float u = sloshT / 0.45f, env = u < 0.08f ? u / 0.08f : std::exp(-(u - 0.08f) * 4.f);
                y += 4.8f * env * sloshTop.low(sloshBand.band(rng.bipolar()));
                sloshT += invSr;
                if (sloshT > 0.7f) sloshT = -1;
            }
            if (clackIn >= 0 && (clackIn -= invSr) < 0) {
                // A bright knock and the hollow bamboo's short ring (with the stone's lower thud under it).
                knock.start(4000.f, 0.5f, 0.002f, 5.f, 0.f, fsr);
                const float f = 1800.f * (0.98f + 0.04f * rng.uniform());
                ring[0].startSine(f, 0.06f, 1.f, fsr); ring[1].startSine(f * 2.62f, 0.03f, 0.35f, fsr); ring[2].startSine(640.f, 0.04f, 0.3f, fsr);
                tipping = false; t = 0; fillDur = fillTime(c); resumeIn = 0.2f + 0.1f * rng.uniform();   // it settles, then fills again
                ++events;
            }
            if (knock.on()) y += knock.next(rng);
            for (auto &p : ring) if (p.mag > 0) { y += p.next(); if (p.energy() < 1e-12f) p.mag = 0; }
            l[i] += yl + y * gl; r[i] += yr + y * gr;
        }
        if (resumeIn >= 0 && (resumeIn -= dt) < 0) resumeIn = -1;
        if (filling) t += (double)n / (double)fsr;
    }
};

// ---------------------------------------------------------------- Bush warbler (uguisu): a long rising whistle, two quick notes
class Warbler final : public AmbienceSource {
    FastRandom rng;
    struct Note { float start = 0, dur = 0.1f, f0 = 3000, f1 = 3000, amp = 1, attack = 0.01f, release = 0.02f, octaves = 0; } notes[3];
    float t = -1, next = 30, ph = 0, gl = 0.7f, gr = 0.7f;

    float interval(const AmbienceContext &c) { return (40.f + 80.f * rng.uniform()) / c.density; }
    void call() {
        const float k = 0.97f + 0.06f * rng.uniform(), hold = 0.06f + 0.06f * rng.uniform();   // each bird a little higher or lower
        // The long whistle swells and rises over 0.6 s (equal steps in pitch), holds a moment; then the two quick notes.
        notes[0] = {0.f, 0.6f + hold, 2500.f * k, 3200.f * k, 0.8f, 0.1f, 0.05f};
        const float s1 = notes[0].dur + 0.07f + 0.03f * rng.uniform();
        notes[1] = {s1, 0.06f + 0.02f * rng.uniform(), 3900.f * k, 3550.f * k, 1.f, 0.008f, 0.015f};
        const float s2 = s1 + notes[1].dur + 0.04f + 0.03f * rng.uniform();
        notes[2] = {s2, 0.16f + 0.05f * rng.uniform(), 4300.f * k, 2900.f * k, 0.95f, 0.008f, 0.03f};
        for (auto &q : notes) q.octaves = std::log2(q.f1 / q.f0);
        t = 0; ph = 0;
        panGains(0.6f * rng.bipolar(), gl, gr);
        ++events;
    }

public:
    // Mostly direct, as in an open garden: the room's smear would blur the rise and fill the gaps between the notes.
    explicit Warbler(uint64_t seed) : rng(seed) { direct = 0.9f; send = 0.25f; }
    void wake(const AmbienceContext &c) override { t = -1; next = interval(c) * (0.15f + 0.35f * rng.uniform()); }
    void callNow(const AmbienceContext &c) { call(); next = interval(c); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float invSr = 1.f / c.sr;
        if (t < 0 && (next -= (float)n * invSr) <= 0) { call(); next = interval(c); }
        if (t < 0) return;
        const float end = notes[2].start + notes[2].dur;
        for (int i = 0; i < n && t >= 0; ++i) {
            for (int k = 0; k < 3; ++k) {
                const Note &q = notes[k];
                const float tn = t - q.start;
                if (tn < 0.f || tn >= q.dur) continue;
                const float glide = k == 0 ? std::min(1.f, tn / 0.6f) : tn / q.dur;
                const float f = q.f0 * std::exp2(q.octaves * glide);
                const float ea = std::min(1.f, tn / q.attack), er = std::min(1.f, (q.dur - tn) / q.release);
                float env = q.amp * ea * ea * (3.f - 2.f * ea) * er * er * (3.f - 2.f * er);
                if (k == 2) env *= 0.75f + 0.25f * sin2pi(32.f * tn);   // the last note's quick warble
                ph += f * invSr;
                if (ph >= 1.f) ph -= 1.f;
                const float x = env * (sin2pi(ph) + 0.06f * sin2pi(2.f * ph));
                l[i] += x * gl; r[i] += x * gr;
            }
            t += invSr;
            if (t > end + 0.02f) t = -1;
        }
    }
};

// ---------------------------------------------------------------- Sonar: a soft ping in the player's key
/// The tonic of a key (root 0…11, C = 0) in the sonar's octave, A5–G♯6 (880–1661 Hz): the bell's, four octaves up.
inline float sonarTonicHz(int root) { return 16.f * bellTonicHz(root); }

class Sonar final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kAttack = 0.025f, kBody = 0.35f;
    /// The tail rises to this (against the ping's peak: −14 dB) over about a tenth of a second; the return is −20 dB.
    static constexpr float kTail = 0.2f, kBuild = 0.08f, kReturn = 0.1f;
    // A ping, its tail and its return all ring on the ping's own tone: the tail is that tone (in quadrature, so it
    // adds to the ping and the return by power) with a slowly shimmering level in each ear, never a delay line, so
    // nothing pulls it off the key; and since the tone is all there is, nothing above it (well under 3 kHz).
    struct Ping {
        bool on = false;
        uint32_t serial = 0;
        int n = 0, back = 0, end = 0;   // samples since the ping; when its return arrives; when it has rung out
        float hz = 0, ph = 0, inc = 0;
        float build = 1, level = 1, buildBack = 1, levelBack = 1, decay = 1, buildK = 1;   // the two tails' envelopes
        float gl = 0.7f, gr = 0.7f, bl = 0.7f, br = 0.7f;   // where the ping and its return are heard
        Wander shimmer[2];
        float sh[2] = {0.8f, 0.8f};
    } pings[2];
    float untilNext = 10;
    uint32_t serial = 0;

    float interval(const AmbienceContext &c) { return (14.f + 16.f * rng.uniform()) / c.density; }

    /// The ping's own shape t seconds in: a 25 ms rise, then a 0.35 s body easing away.
    static float shape(float t) {
        if (t <= 0.f) return 0.f;
        if (t < kAttack) { const float u = t / kAttack; return u * u * (3.f - 2.f * u); }
        const float u = (t - kAttack) / kBody;
        return u >= 1.f ? 0.f : 1.f - u * u * (3.f - 2.f * u);
    }

    /// The pitch is the key's tonic at the moment of the ping: a ping, its tail and its return never change.
    void ping(const AmbienceContext &c) {
        Ping *p = nullptr;
        for (auto &x : pings) if (!x.on) { p = &x; break; }
        if (!p) { p = &pings[0]; for (auto &x : pings) if (x.serial < p->serial) p = &x; }   // the oldest makes room
        const float sr = c.sr, t60 = 3.f + 2.f * rng.uniform(), delay = 1.45f + 1.1f * rng.uniform();   // inside 1.4–2.6 s
        p->hz = sonarTonicHz(c.keyRoot); p->inc = p->hz / sr; p->ph = 0;
        p->n = 0; p->back = (int)(delay * sr); p->end = p->back + (int)((kAttack + kBody + t60) * sr);
        p->decay = std::pow(10.f, -3.f / (t60 * sr)); p->buildK = std::exp(-1.f / (kBuild * sr));
        p->build = p->buildBack = 1.f; p->level = p->levelBack = 1.f;
        panGains(0.1f * rng.bipolar(), p->gl, p->gr);    // the transducer, ahead of you
        panGains(0.35f * rng.bipolar(), p->bl, p->br);   // the seabed answers from somewhere below
        p->on = true; p->serial = ++serial;
        ++events;
    }

public:
    // All its own: the shared room's slowly modulated tail would pull a pure tone off the key (it took the temple
    // bell 9–12 cents off), so nothing goes to the room.
    explicit Sonar(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.f; }
    void wake(const AmbienceContext &c) override {
        for (auto &p : pings) p.on = false;
        untilNext = interval(c) * (0.25f + 0.35f * rng.uniform());
    }
    void pingNow(const AmbienceContext &c) { ping(c); untilNext = interval(c); }
    float ringingHz() const {
        const Ping *newest = nullptr;
        for (auto &p : pings) if (p.on && (!newest || p.serial > newest->serial)) newest = &p;
        return newest ? newest->hz : 0.f;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float dt = (float)n / c.sr, invSr = 1.f / c.sr;
        if ((untilNext -= dt) <= 0) { ping(c); untilNext = interval(c); }
        for (auto &p : pings) {
            if (!p.on) continue;
            float a = p.sh[0], b = p.sh[1];
            p.sh[0] = 0.6f + 0.4f * p.shimmer[0].next(rng, dt, 0.55f);
            p.sh[1] = 0.6f + 0.4f * p.shimmer[1].next(rng, dt, 0.7f);
            const float da = (p.sh[0] - a) / (float)n, db = (p.sh[1] - b) / (float)n;
            for (int i = 0; i < n && p.on; ++i) {
                a += da; b += db;
                const float tone = sin2pi(p.ph), quad = sin2pi(p.ph + 0.25f);
                advanceTone(p.ph, p.inc);
                const float direct = shape((float)p.n * invSr);
                float back = 0.f, tail = kTail * (1.f - p.build) * p.level;
                p.build *= p.buildK; p.level *= p.decay;
                if (p.n >= p.back) {
                    back = kReturn * shape((float)(p.n - p.back) * invSr);
                    tail += kReturn * kTail * (1.f - p.buildBack) * p.levelBack;
                    p.buildBack *= p.buildK; p.levelBack *= p.decay;
                }
                l[i] += tone * (direct * p.gl + back * p.bl) + quad * tail * a;
                r[i] += tone * (direct * p.gr + back * p.br) + quad * tail * b;
                if (++p.n >= p.end) p.on = false;
            }
        }
    }
};

// ---------------------------------------------------------------- Hull creak: the pressure hull settling (indoor)
class HullCreak final : public AmbienceSource {
    FastRandom rng;
    // A groan: the hull's plates stick and slip, a pulse train gliding between 8 and 30 Hz that rings three of its
    // resonances (60–250 Hz) under a faint moan through the lowest.
    struct Groan {
        float t = -1, dur = 1, f0 = 12, octaves = 0, ph = 0, amp = 1, gl = 0.7f, gr = 0.7f;
        SVF res[3], top;
        Brown brown;
    } groan;
    // A tick: the steel answering, a 1–3 kHz ping of 0.2 s on a short click.
    Partial ring[2];
    Burst click;
    float tickGl = 0.7f, tickGr = 0.7f, toGroan = 20, toTick = 60;
    static constexpr float kResGain[3] = {1.f, 0.7f, 0.45f};
    // A slip is one sample's kick (each resonance, of unity peak gain, rings to about 2πf/(Q·sr) of it); the moan and the
    // tick sit under and over the groan.
    static constexpr float kSlip = 750.f, kHum = 25.f, kTick = 0.7f;

    float groanInterval(const AmbienceContext &c) { return (12.f + 33.f * rng.uniform()) / c.density; }
    float tickInterval(const AmbienceContext &c) { return (30.f + 70.f * rng.uniform()) / c.density; }

    void startGroan(float sr) {
        groan.t = 0; groan.dur = 0.6f + 2.4f * rng.uniform(); groan.ph = 0; groan.amp = 0.75f + 0.25f * rng.uniform();
        const float a = 8.f * std::exp2(1.9f * rng.uniform()), b = 8.f * std::exp2(1.9f * rng.uniform());   // 8–30 Hz
        groan.f0 = a; groan.octaves = std::log2(b / a);
        const float lo[3] = {60.f, 100.f, 160.f}, span[3] = {40.f, 70.f, 90.f};
        for (int k = 0; k < 3; ++k) groan.res[k].set(lo[k] + span[k] * rng.uniform(), 7.f + 3.f * rng.uniform(), sr);
        groan.top.set(600.f, 0.7f, sr);
        panGains(0.6f * rng.bipolar(), groan.gl, groan.gr);
        ++events;
    }
    void startTick(float sr) {
        const float f = 1000.f + 2000.f * rng.uniform(), pan = 0.7f * rng.bipolar();
        ring[0].startSine(f, 0.2f, kTick, sr); ring[1].startSine(f * 2.76f, 0.12f, 0.35f * kTick, sr);
        click.start(4000.f, 0.7f, 0.0008f, 1.5f * kTick, pan, sr);
        panGains(pan, tickGl, tickGr);
        ++events;
    }

public:
    explicit HullCreak(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; indoor = true; }   // you are inside it
    void wake(const AmbienceContext &c) override {
        groan.t = -1;
        toGroan = groanInterval(c) * (0.1f + 0.4f * rng.uniform());
        toTick = tickInterval(c) * (0.2f + 0.6f * rng.uniform());
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if ((toGroan -= dt) <= 0 && groan.t < 0) { startGroan(fsr); toGroan = groanInterval(c); }   // start to start
        if ((toTick -= dt) <= 0) { startTick(fsr); toTick = tickInterval(c); }
        const bool ticking = click.on() || ring[0].mag > 0 || ring[1].mag > 0;
        if (groan.t < 0 && !ticking) return;
        float inc = 0;
        if (groan.t >= 0) inc = groan.f0 * std::exp2(groan.octaves * std::min(1.f, groan.t / groan.dur)) * invSr;
        for (int i = 0; i < n; ++i) {
            float yl = 0, yr = 0;
            if (groan.t >= 0) {
                const float u = groan.t / groan.dur;
                const float s = u < 0.3f ? u / 0.3f : (1.f - u) / 0.7f, env = s * s * (3.f - 2.f * s);
                groan.ph += inc;
                float slip = 0;
                if (groan.ph >= 1.f) { groan.ph -= 1.f + 0.2f * (rng.uniform() - 0.5f); slip = kSlip * groan.amp * (0.55f + 0.45f * rng.uniform()); }
                float x = 0;
                for (int k = 0; k < 3; ++k) x += kResGain[k] * groan.res[k].band(slip + (k == 0 ? kHum * groan.brown.next(rng.bipolar()) : 0.f));
                const float y = env * groan.top.low(x);
                yl += y * groan.gl; yr += y * groan.gr;
                groan.t += invSr;
                if (groan.t > groan.dur) groan.t = -1;
            }
            float tick = 0;
            if (click.on()) tick += click.next(rng);
            for (auto &p : ring) if (p.mag > 0) { tick += p.next(); if (p.energy() < 1e-12f) p.mag = 0; }
            l[i] += yl + tick * tickGl; r[i] += yr + tick * tickGr;
        }
    }
};

// ---------------------------------------------------------------- Whale song: a far-off humpback
class Whale final : public AmbienceSource {
    FastRandom rng;
    enum Kind : int { kMoan = 0, kWhoop, kCry, kGrunt };
    struct Unit { int kind = kMoan; float dur = 1, f0 = 200, f1 = 200, amp = 1, gap = 0.6f, rate = 0; };
    // The song: themes sung in a fixed order, each a phrase of 3–6 units repeated 2–4 times.
    static constexpr int kThemes = 5, kMostUnits = 6;
    static constexpr float kLongest = 57.f;   // seconds of song at most (its last unit can run 3 s past this)
    struct Theme { Unit unit[kMostUnits]; int count = 3, repeats = 2; float gap = 1.2f; } song[kThemes];
    SVF far;   // the distance: low-passed above 2 kHz
    int theme = 0, rep = 0, index = 0;   // where the song is
    int n = 0, len = 1, rest = 0;        // samples into the unit sounding now, its length; the silence before the next
    bool singing = false, sounding = false;
    float untilSong = 30, sung = 0, singFor = 30, ph = 0, inc = 0, oct = 0, am = 0, gl = 0.7f, gr = 0.7f;

    static void band(int kind, float &lo, float &hi, float &shortest, float &longest) {
        switch (kind) {
        case kMoan: lo = 120.f; hi = 400.f; shortest = 1.f; longest = 3.f; break;
        case kWhoop: lo = 180.f; hi = 820.f; shortest = 0.6f; longest = 1.4f; break;
        case kCry: lo = 800.f; hi = 1800.f; shortest = 0.5f; longest = 1.4f; break;
        default: lo = 140.f; hi = 260.f; shortest = 0.25f; longest = 0.7f; break;
        }
    }
    Unit compose() {
        Unit u;
        const float pick = rng.uniform();
        u.kind = pick < 0.35f ? kMoan : (pick < 0.55f ? kWhoop : (pick < 0.8f ? kCry : kGrunt));
        switch (u.kind) {
        case kMoan:    // a slow glide, up or down (kept off the band's floor, so its lowest stays above 100 Hz)
            u.f0 = 120.f * std::exp2(1.5f * rng.uniform()); u.f1 = std::clamp(u.f0 * std::exp2(0.6f * rng.bipolar()), 120.f, 400.f);
            u.dur = 1.f + 2.f * rng.uniform(); u.amp = 0.9f + 0.1f * rng.uniform(); break;
        case kWhoop:   // rising from about 200 to 800 Hz, faster as it goes
            u.f0 = 190.f + 50.f * rng.uniform(); u.f1 = 650.f + 150.f * rng.uniform();
            u.dur = 0.6f + 0.8f * rng.uniform(); u.amp = 0.75f; break;
        case kCry:     // high and nearly pure, wavering
            u.f0 = 850.f + 750.f * rng.uniform(); u.f1 = std::clamp(u.f0 * std::exp2(0.2f * rng.bipolar()), 800.f, 1800.f);
            u.dur = 0.5f + 0.9f * rng.uniform(); u.amp = 0.5f; break;
        default:       // a grunt: a low, pulsing growl
            u.f0 = 160.f + 80.f * rng.uniform(); u.f1 = u.f0 * (0.85f + 0.1f * rng.uniform());
            u.dur = 0.25f + 0.45f * rng.uniform(); u.rate = 18.f + 17.f * rng.uniform(); u.amp = 0.85f; break;
        }
        u.gap = 0.25f + 0.95f * rng.uniform();
        return u;
    }
    /// Real songs change slowly over a season: each time it sings, one unit of one theme moves a little.
    void drift() {
        Theme &th = song[std::min(kThemes - 1, (int)(rng.uniform() * (float)kThemes))];
        Unit &u = th.unit[std::min(th.count - 1, (int)(rng.uniform() * (float)th.count))];
        float lo, hi, shortest, longest;
        band(u.kind, lo, hi, shortest, longest);
        const float k = std::exp2(0.06f * rng.bipolar());
        u.f0 = std::clamp(u.f0 * k, lo, hi); u.f1 = std::clamp(u.f1 * k, lo, hi);
        u.dur = std::clamp(u.dur * (1.f + 0.08f * rng.bipolar()), shortest, longest);
    }
    void startSong(const AmbienceContext &c) {
        singing = true; sounding = false; rest = (int)(0.05f * c.sr); sung = 0; singFor = 20.f + 28.f * rng.uniform();
        index = 0;   // a song stops only at the end of a phrase, so it picks up with the next
        drift();
        panGains(0.5f * rng.bipolar(), gl, gr);
    }
    void startUnit(const AmbienceContext &c) {
        const Unit &u = song[theme].unit[index];
        n = 0; len = std::max(1, (int)(u.dur * c.sr)); sounding = true; ph = 0; am = 0; oct = std::log2(u.f1 / u.f0);
        ++events;
    }
    void unitDone(const AmbienceContext &c) {
        const Theme &th = song[theme];
        float gap = th.unit[index].gap;
        sounding = false;
        if (++index >= th.count) {   // the phrase is done: again, or on to the next theme
            index = 0;
            gap = th.gap;
            if (++rep >= th.repeats) { rep = 0; theme = (theme + 1) % kThemes; gap += 1.f; }
        }
        // It stops at the end of a phrase once its time is up (20–48 s, so its last phrase ends it inside 20–60 s), and
        // never sings past a minute (then the phrase picks up from its start next time).
        if ((index == 0 && sung >= singFor) || sung + gap >= kLongest) {
            singing = false; index = 0; untilSong = (30.f + 150.f * rng.uniform()) / c.density;
            return;
        }
        rest = (int)(gap * c.sr);
    }
    float voice(const Unit &u, float invSr) {
        const float t = (float)n * invSr, x = (float)n / (float)len;
        if ((n & 15) == 0) {   // the glide, in equal steps of pitch: moans ease, whoops speed up as they rise, cries waver
            const float g = u.kind == kMoan ? x * x * (3.f - 2.f * x) : (u.kind == kWhoop ? x * x : x);
            float f = u.f0 * std::exp2(oct * g);
            if (u.kind == kCry) f *= 1.f + 0.012f * sin2pi(5.5f * t);
            inc = f * invSr;
        }
        const float attack = std::min(0.2f, 0.3f * u.dur), release = std::min(0.35f, 0.4f * u.dur), left = u.dur - t;
        float e = 1.f;
        if (t < attack) { const float s = t / attack; e = s * s * (3.f - 2.f * s); }
        if (left < release) { const float s = std::max(0.f, left / release); e *= s * s * (3.f - 2.f * s); }
        advanceTone(ph, inc);
        const float s1 = sin2pi(ph), s2 = sin2pi(2.f * ph);
        float y;
        switch (u.kind) {
        case kMoan: y = s1 + 0.35f * s2 + 0.12f * sin2pi(3.f * ph); break;
        case kWhoop: y = s1 + 0.25f * s2; break;
        case kCry: y = s1 + 0.08f * s2; break;
        default: {
            advanceTone(am, u.rate * invSr);
            const float g = 0.5f + 0.5f * sin2pi(am);   // pulsing at 18–35 Hz: its sidebands stay above 100 Hz
            y = (s1 + 0.5f * s2 + 0.3f * sin2pi(3.f * ph)) * (0.3f + 0.7f * g);
            break;
        }
        }
        return u.amp * e * y;
    }

public:
    // Far off and mostly reverberant: the room's tail can't hurt a song that glides anyway.
    Whale(uint64_t seed, float sr) : rng(seed) {
        direct = 0.45f; send = 1.f;
        for (auto &th : song) {
            th.count = 3 + (int)(rng.uniform() * 3.99f);
            th.repeats = 2 + (int)(rng.uniform() * 2.99f);
            th.gap = 0.8f + 1.f * rng.uniform();
            for (int k = 0; k < th.count; ++k) th.unit[k] = compose();
        }
        far.set(2000.f, 0.707f, sr);
    }
    void wake(const AmbienceContext &c) override {
        singing = false; sounding = false;
        untilSong = (30.f + 150.f * rng.uniform()) / c.density * (0.05f + 0.25f * rng.uniform());
    }
    void startNow(const AmbienceContext &c) { if (!singing) startSong(c); }
    void render(float *l, float *r, int nf, const AmbienceContext &c) override {
        const float dt = (float)nf / c.sr, invSr = 1.f / c.sr;
        if (!singing) {
            if ((untilSong -= dt) > 0) return;
            startSong(c);
        }
        sung += dt;
        for (int i = 0; i < nf; ++i) {
            float x = 0;
            if (sounding) {
                x = voice(song[theme].unit[index], invSr);
                if (++n >= len) unitDone(c);
            } else if (singing && --rest <= 0) {
                startUnit(c);
            }
            const float y = far.low(x);
            l[i] += y * gl; r[i] += y * gr;
        }
    }
};

// ---------------------------------------------------------------- Bubbles: bursts of Minnaert plinks
class Bubbles final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kVoices = 16, kMost = 30;
    Ping voices[kVoices];
    int nextVoice = 0;
    // A burst: its bubbles' start times (samples from its start), front-loaded so the stream thins out.
    struct Burst { bool on = false; int count = 0, next = 0, n = 0; float pan = 0, strength = 0.5f; int at[kMost] = {}; } bursts[2];
    float toIdle = 10;

    float idleInterval(const AmbienceContext &c) { return (8.f + 22.f * rng.uniform()) / c.density; }

    void bubble(const Burst &b, float sr) {
        // Minnaert: f·a ≈ 3.26 m/s. Radii 0.47–2.7 mm (log-uniform; inside 0.4–3 mm) ring at 6.9–1.2 kHz, so even with
        // the 8% chirp every bubble stays well inside 1.1–8 kHz. Bigger bubbles ring longer (5–25 ms) and a little louder.
        const float a = 0.47f * std::exp2(2.522f * rng.uniform()), size = (a - 0.47f) / 2.23f, ring = 0.005f + 0.02f * size;
        const float amp = (0.5f + 0.5f * rng.uniform()) * (0.55f + 0.45f * size) * (0.7f + 0.3f * b.strength);
        voices[nextVoice].start(3260.f / a, ring, amp, b.pan + 0.25f * rng.bipolar(), sr, 0.08f, ring);
        nextVoice = (nextVoice + 1) % kVoices;
    }

public:
    explicit Bubbles(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; }
    /// A burst now: from 4 bubbles over 0.3 s (strength 0) to 30 over 1.5 s (1), the first at once.
    void start(float strength, float sr) {
        Burst *b = nullptr;
        for (auto &x : bursts) if (!x.on) { b = &x; break; }
        if (!b) { b = &bursts[0]; for (auto &x : bursts) if (x.n > b->n) b = &x; }   // the oldest makes room
        const float s = clamp01(strength), dur = 0.3f + 1.2f * s;
        b->count = std::min(kMost, 4 + (int)(26.f * s + 0.5f));
        const float last = dur * (0.9f + 0.1f * rng.uniform());   // the last straggler closes the burst
        b->at[0] = 0;
        for (int k = 1; k < b->count - 1; ++k) {
            const float u = rng.uniform();
            const int v = (int)(last * u * std::sqrt(u) * sr);
            int j = k;
            while (j > 1 && b->at[j - 1] > v) { b->at[j] = b->at[j - 1]; --j; }
            b->at[j] = v;
        }
        b->at[b->count - 1] = (int)(last * sr);
        b->next = 0; b->n = 0; b->pan = 0.6f * rng.bipolar(); b->strength = s; b->on = true;
        ++events;
    }
    void trigger(float strength, const AmbienceContext &c) { start(strength, c.sr); toIdle = idleInterval(c); }
    void wake(const AmbienceContext &c) override {
        for (auto &b : bursts) b.on = false;
        for (auto &v : voices) v.amp = 0;
        toIdle = idleInterval(c) * (0.5f + 0.5f * rng.uniform());
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        if ((toIdle -= (float)n / c.sr) <= 0) { start(0.1f + 0.45f * rng.uniform(), c.sr); toIdle = idleInterval(c); }
        bool busy = bursts[0].on || bursts[1].on;
        for (auto &v : voices) busy = busy || v.on();
        if (!busy) return;
        for (int i = 0; i < n; ++i) {
            for (auto &b : bursts) {
                if (!b.on) continue;
                while (b.next < b.count && b.n >= b.at[b.next]) { bubble(b, c.sr); ++b.next; }
                if (b.next >= b.count) b.on = false; else ++b.n;
            }
            float yl = 0, yr = 0;
            for (auto &v : voices) { if (!v.on()) continue; const float y = v.next(); yl += y * v.gl; yr += y * v.gr; }
            l[i] += yl; r[i] += yr;
        }
    }
};

// ---------------------------------------------------------------- Snapping shrimp: the reef's crackle
class Shrimp final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRate = 900.f, kMostRate = 1200.f;   // snaps a second at level 1; never more
    // A bed of sparse clicks is nearly all peaks (heard as it is, its crest would run near 28 dB): above this knee
    // (11 dB over the bed's RMS at level 1) the loudest snaps are rounded off toward the ceiling, 10 dB over the
    // faintest, so they still stand out but the bed stays clear of the limiter (it peaks near −3 dBFS at 1, as rain on
    // the glass does).
    static constexpr float kKnee = 1.8f, kCeiling = 3.2f;
    SVF hpL, hpR;   // high-passed at 2 kHz
    struct Snap { int left = 0, len = 1; float amp = 0, gl = 0, gr = 0, sign = 1; } snaps[8];
    int nextSnap = 0;
    float toNext = 1;   // in mean gaps: a Poisson process whose rate follows the level

    static float knee(float x) {
        const float a = std::fabs(x);
        if (a <= kKnee) return x;
        const float y = kKnee + (kCeiling - kKnee) * std::tanh((a - kKnee) / (kCeiling - kKnee));
        return x < 0 ? -y : y;
    }
    void snap(float sr) {
        Snap &s = snaps[nextSnap]; nextSnap = (nextSnap + 1) & 7;
        // Pareto amplitudes (α 2.5): most snaps faint and a few standing out, the loudest 6 times the faintest.
        s.amp = std::min(6.f, std::exp(-std::log(std::max(1e-6f, rng.uniform())) / 2.5f));
        s.len = std::max(2, (int)((0.0001f + 0.0002f * rng.uniform()) * sr));   // 0.1–0.3 ms of broadband click
        s.left = s.len;
        panGains(rng.bipolar(), s.gl, s.gr);   // scattered over the whole reef
        if (events < 0x7fffffff) ++events;
    }

public:
    Shrimp(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.3f;
        hpL.set(2000.f, 0.707f, sr); hpR.set(2000.f, 0.707f, sr);
    }
    void wake(const AmbienceContext &) override { toNext = expRand(rng); for (auto &s : snaps) s.left = 0; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        // The level carries the hour (a world's 1.0 by day, 1.6 at dusk and dawn, 1.25 at night): louder, and more of
        // them snapping.
        const float step = std::min(kMostRate, kRate * level * c.density) / c.sr;
        for (int i = 0; i < n; ++i) {
            if ((toNext -= step) <= 0.f) { snap(c.sr); toNext += expRand(rng); }
            float xl = 0, xr = 0;
            for (auto &s : snaps) {
                if (s.left <= 0) continue;
                // A flat burst of random signs (the most energy for its peak), each held for two samples so most of the
                // click sits below the air's 10 kHz top (still broadband: 2–12 kHz and on), easing off over its last 30%.
                const int k = s.len - s.left--;
                const float fade = (float)k < 0.7f * (float)s.len ? 1.f : (float)(s.len - k) / (0.3f * (float)s.len);
                if ((k & 1) == 0) s.sign = (rng.next() >> 40 & 1u) ? 1.f : -1.f;
                const float w = s.sign * s.amp * fade;
                xl += w * s.gl; xr += w * s.gr;
            }
            l[i] += knee(hpL.high(xl)); r[i] += knee(hpR.high(xr));
        }
    }
};

// ---------------------------------------------------------------- Fish chorus: the reef's pops, knocks and croaks
class FishChorus final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kVoices = 16;
    Ping voices[kVoices];
    int nextVoice = 0;
    // A call: a train of pulses (a damselfish's 3–10 at 20–60 Hz, a croak's 6–14 quicker, lower ones), or one knock or
    // pop. Each pulse is a short damped tone.
    struct Call { int left = 0, toPulse = 0, interval = 1000; float hz = 400, ring = 0.015f, amp = 1, pan = 0, partner = 0; } calls[8];
    SVF lpL, lpR, hpL, hpR;   // the reef's band, 100–800 Hz
    float toCall = 1;

    void call(float sr) {
        Call *q = nullptr;
        for (auto &x : calls) if (x.left <= 0) { q = &x; break; }
        if (!q) return;   // the reef is busy: this fish waits its turn
        const float pick = rng.uniform();
        q->pan = 0.85f * rng.bipolar(); q->toPulse = 0; q->partner = 0;
        if (pick < 0.45f) {          // a damselfish
            q->left = 3 + (int)(rng.uniform() * 7.99f); q->interval = (int)(sr / (20.f + 40.f * rng.uniform()));
            q->hz = 260.f + 390.f * rng.uniform(); q->ring = 0.012f + 0.008f * rng.uniform(); q->amp = 0.8f + 0.2f * rng.uniform();
        } else if (pick < 0.65f) {   // a croak
            q->left = 6 + (int)(rng.uniform() * 8.99f); q->interval = (int)(sr / (70.f + 40.f * rng.uniform()));
            q->hz = 150.f + 170.f * rng.uniform(); q->ring = 0.015f + 0.01f * rng.uniform(); q->amp = 0.6f + 0.2f * rng.uniform();
        } else if (pick < 0.85f) {   // a knock, with a woody second partial
            q->left = 1; q->interval = 1; q->partner = 0.3f;
            q->hz = 140.f + 200.f * rng.uniform(); q->ring = 0.03f + 0.02f * rng.uniform(); q->amp = 0.9f + 0.1f * rng.uniform();
        } else {                     // a pop
            q->left = 1; q->interval = 1;
            q->hz = 350.f + 400.f * rng.uniform(); q->ring = 0.01f + 0.006f * rng.uniform(); q->amp = 0.7f + 0.3f * rng.uniform();
        }
        ++events;
    }
    void pulse(const Call &q, float sr) {
        voices[nextVoice].start(q.hz * (0.98f + 0.04f * rng.uniform()), q.ring, q.amp * (0.75f + 0.25f * rng.uniform()), q.pan, sr);
        nextVoice = (nextVoice + 1) % kVoices;
        if (q.partner > 0) {
            voices[nextVoice].start(2.2f * q.hz, 0.5f * q.ring, q.partner * q.amp, q.pan, sr);
            nextVoice = (nextVoice + 1) % kVoices;
        }
    }

public:
    FishChorus(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.45f;
        lpL.set(900.f, 0.707f, sr); lpR.set(900.f, 0.707f, sr); hpL.set(100.f, 0.707f, sr); hpR.set(100.f, 0.707f, sr);
    }
    void wake(const AmbienceContext &) override { toCall = expRand(rng); for (auto &q : calls) q.left = 0; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        // The higher the level (the hour), the more of them call, until the reef drums as one chorus.
        const float perSecond = (0.6f + 35.f * level * std::sqrt(level)) * c.density;
        toCall -= perSecond * dt;
        for (int k = 0; k < 4 && toCall <= 0.f; ++k) { call(fsr); toCall += expRand(rng); }
        for (int i = 0; i < n; ++i) {
            for (auto &q : calls) {
                if (q.left <= 0 || --q.toPulse > 0) continue;
                pulse(q, fsr);
                --q.left;
                q.toPulse = (int)((float)q.interval * (0.9f + 0.2f * rng.uniform()));
            }
            float yl = 0, yr = 0;
            for (auto &v : voices) { if (!v.on()) continue; const float y = v.next(); yl += y * v.gl; yr += y * v.gr; }
            l[i] += lpL.low(hpL.high(yl)); r[i] += lpR.low(hpR.high(yr));
        }
    }
};

} // namespace amb

using namespace amb;

// ---------------------------------------------------------------- Thunder
class Thunder {
public:
    explicit Thunder(uint64_t seed) : rng(seed) {}
    void trigger(float distance) {
        for (auto &v : voices) {
            if (v.on) continue;
            v.on = true;
            v.d = clamp01(distance);
            v.delay = 0.5f + 5.5f * v.d;
            v.t = -v.delay;
            v.dur = 1.f + 3.f * (0.3f + 0.7f * v.d) * (0.8f + 0.2f * rng.uniform());
            v.level = 1.f - 0.75f * v.d;
            v.rolls = 2 + (int)(rng.uniform() * 2.99f);
            for (int i = 0; i < v.rolls; ++i) {
                v.at[i] = (i == 0 ? 0.f : (0.15f + 0.6f * rng.uniform()) * v.dur);
                v.rise[i] = 0.15f + 0.25f * rng.uniform();
                v.fall[i] = 0.6f + 1.2f * rng.uniform();
                v.amp[i] = i == 0 ? 1.f : 0.5f + 0.5f * rng.uniform();
            }
            v.crack = v.d < 0.3f ? 1.f - v.d / 0.3f : 0.f;
            return;
        }
    }
    bool active() const { for (auto &v : voices) if (v.on) return true; return false; }
    void render(float *l, float *r, int n, float sr) {
        const float invSr = 1.f / sr;
        for (auto &v : voices) {
            if (!v.on) continue;
            const float cut = 200.f - 80.f * v.d;
            v.lowA.set(cut, 0.7f, sr); v.lowB.set(cut, 0.7f, sr); v.crackF.set(900.f, 0.7f, sr);
            for (int t = 0; t < n; ++t) {
                v.t += invSr;
                if (v.t < 0) continue;
                float env = 0;
                for (int i = 0; i < v.rolls; ++i) {
                    const float u = v.t - v.at[i];
                    if (u < 0) continue;
                    if (u < v.rise[i]) { float s = std::sin(0.5f * kPi * u / v.rise[i]); env += v.amp[i] * s * s; }
                    else env += v.amp[i] * std::exp(-(u - v.rise[i]) / v.fall[i] * 2.3f);
                }
                const float rumble = v.lowB.low(v.lowA.low(v.brown.next(rng.bipolar()) * 6.f));
                const float crack = v.crack > 0 ? v.crack * std::exp(-v.t / 0.2f) * v.crackF.band(rng.bipolar()) : 0.f;
                const float x = v.level * (env * rumble + crack);
                l[t] += x; r[t] += x * 0.9f;
                if (v.t > v.dur + 6.f) { v.on = false; break; }
            }
        }
    }

private:
    FastRandom rng;
    struct Voice {
        bool on = false;
        float d = 0.5f, delay = 1, t = 0, dur = 2, level = 1, crack = 0;
        int rolls = 2;
        float at[4] = {}, rise[4] = {}, fall[4] = {}, amp[4] = {};
        Brown brown;
        SVF lowA, lowB, crackF;
    } voices[3];
};

Ambience::Ambience(double sampleRate, uint64_t seed) : sr(sampleRate), room(sampleRate, kBlock) {
    ctx.sr = (float)sampleRate;
    const float fsr = (float)sampleRate;
    auto s = [&](int i) { return seed * 0x9E3779B97F4A7C15ULL + 0x632BE59BD9B4E019ULL * (uint64_t)(i + 1); };
    sources[ISD_AMB_WATER] = std::make_unique<Water>(s(0));
    sources[ISD_AMB_CRICKETS] = std::make_unique<Crickets>(s(1));
    sources[ISD_AMB_BREEZE] = std::make_unique<Breeze>(s(2));
    sources[ISD_AMB_OWL] = std::make_unique<Owl>(s(3));
    sources[ISD_AMB_RAIN_WATER] = std::make_unique<Rain>(s(4), false, fsr);
    sources[ISD_AMB_RAIN_GLASS] = std::make_unique<Rain>(s(5), true, fsr);
    sources[ISD_AMB_DAWN_CHORUS] = std::make_unique<DawnChorus>(s(6));
    sources[ISD_AMB_SHIP_HUM] = std::make_unique<ShipHum>(s(7), fsr);
    sources[ISD_AMB_AIR_FLOW] = std::make_unique<AirFlow>(s(8), fsr);
    sources[ISD_AMB_CHIME] = std::make_unique<Chime>(s(9));
    sources[ISD_AMB_HULL_TICKS] = std::make_unique<HullTicks>(s(10));
    sources[ISD_AMB_WIND] = std::make_unique<Wind>(s(11));
    thunder = std::make_unique<Thunder>(s(12));
    auto surfSource = std::make_unique<Surf>(s(13));
    surf = surfSource.get();
    sources[ISD_AMB_SURF] = std::move(surfSource);
    sources[ISD_AMB_PALMS] = std::make_unique<Palms>(s(14));
    sources[ISD_AMB_GULLS] = std::make_unique<Gulls>(s(15));
    sources[ISD_AMB_ROAD] = std::make_unique<Road>(s(16));
    sources[ISD_AMB_ENGINE] = std::make_unique<EngineHum>(s(17));
    sources[ISD_AMB_WINDOW_WIND] = std::make_unique<WindowWind>(s(18));
    sources[ISD_AMB_PASSING_CAR] = std::make_unique<PassingCar>(s(19));
    sources[ISD_AMB_FIRE] = std::make_unique<Fire>(s(20));
    auto kettleSource = std::make_unique<Kettle>(s(21));
    kettle = kettleSource.get();
    sources[ISD_AMB_KETTLE] = std::move(kettleSource);
    sources[ISD_AMB_STREET] = std::make_unique<Street>(s(22));
    sources[ISD_AMB_DRIPS] = std::make_unique<Drips>(s(23));
    sources[ISD_AMB_CLOCK] = std::make_unique<Clock>(s(24));
    sources[ISD_AMB_ICE_GROAN] = std::make_unique<IceGroan>(s(25));
    sources[ISD_AMB_WATERFALL] = std::make_unique<Waterfall>(s(26));
    sources[ISD_AMB_LAPPING] = std::make_unique<Lapping>(s(27));
    auto boatSource = std::make_unique<Boat>(s(28));
    boat = boatSource.get();
    sources[ISD_AMB_BOAT] = std::move(boatSource);
    auto bellSource = std::make_unique<TempleBell>(s(29));
    bell = bellSource.get();
    sources[ISD_AMB_TEMPLE_BELL] = std::move(bellSource);
    sources[ISD_AMB_PAPER_SCREENS] = std::make_unique<PaperScreens>(s(30), fsr);
    auto knockerSource = std::make_unique<WaterKnocker>(s(31));
    knocker = knockerSource.get();
    sources[ISD_AMB_WATER_KNOCKER] = std::move(knockerSource);
    auto warblerSource = std::make_unique<Warbler>(s(32));
    warbler = warblerSource.get();
    sources[ISD_AMB_WARBLER] = std::move(warblerSource);
    auto sonarSource = std::make_unique<Sonar>(s(33));
    sonar = sonarSource.get();
    sources[ISD_AMB_SONAR] = std::move(sonarSource);
    sources[ISD_AMB_HULL_CREAK] = std::make_unique<HullCreak>(s(34));
    auto whaleSource = std::make_unique<Whale>(s(35), fsr);
    whale = whaleSource.get();
    sources[ISD_AMB_WHALE] = std::move(whaleSource);
    auto bubblesSource = std::make_unique<Bubbles>(s(36));
    bubbles = bubblesSource.get();
    sources[ISD_AMB_BUBBLES] = std::move(bubblesSource);
    sources[ISD_AMB_SHRIMP] = std::make_unique<Shrimp>(s(37), fsr);
    sources[ISD_AMB_FISH_CHORUS] = std::make_unique<FishChorus>(s(38), fsr);
    for (int i : {ISD_AMB_SHIP_HUM, ISD_AMB_AIR_FLOW, ISD_AMB_CHIME, ISD_AMB_HULL_TICKS}) sources[i]->indoor = true;
    closeness.init(sampleRate, 300.0);
    closeness.snap(0.5f);
}

Ambience::~Ambience() = default;

void Ambience::setLevel(int source, float level) {
    // A reserved id with no source behind it (the Storms families until Task 8) is ignored.
    if (source < 0 || source >= ISD_AMB_COUNT || !sources[source]) return;
    Ramp &r = ramps[source];
    const float v = clamp01(level);
    if (v > 0.f && r.silent()) sources[source]->wake(ctx);
    r.setTarget(v, (int)(kRampSeconds * (float)sr));
}

void Ambience::triggerThunder(float distance) { thunder->trigger(distance); }

void Ambience::startKettle() {
    if (ramps[ISD_AMB_KETTLE].silent()) kettle->wake(ctx);
    kettle->start(ctx);
}

void Ambience::startBoat() {
    if (ramps[ISD_AMB_BOAT].silent()) boat->wake(ctx);
    boat->start(ctx);
}

void Ambience::strikeBell() {
    if (ramps[ISD_AMB_TEMPLE_BELL].silent()) bell->wake(ctx);
    bell->strikeNow(ctx);
}

float Ambience::bellRingingHz() const { return ramps[ISD_AMB_TEMPLE_BELL].silent() ? 0.f : bell->ringingHz(); }

void Ambience::startKnocker() {
    if (ramps[ISD_AMB_WATER_KNOCKER].silent()) knocker->wake(ctx);
    knocker->start(ctx);
}

void Ambience::callWarbler() {
    if (ramps[ISD_AMB_WARBLER].silent()) warbler->wake(ctx);
    warbler->callNow(ctx);
}

void Ambience::triggerBubbles(float strength) {
    if (ramps[ISD_AMB_BUBBLES].to <= 0.f) return;   // silent, or fading out as the world changes
    bubbles->trigger(strength, ctx);
}

void Ambience::pingSonar() {
    if (ramps[ISD_AMB_SONAR].silent()) sonar->wake(ctx);
    sonar->pingNow(ctx);
}

float Ambience::sonarRingingHz() const { return ramps[ISD_AMB_SONAR].silent() ? 0.f : sonar->ringingHz(); }

void Ambience::startWhale() {
    if (ramps[ISD_AMB_WHALE].silent()) whale->wake(ctx);
    whale->startNow(ctx);
}

void Ambience::triggerWave(float strength) {
    if (ramps[ISD_AMB_SURF].to <= 0.f) return;   // silent, or fading out as the world changes
    surf->trigger(strength, ctx.surfDistance);
}

void Ambience::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kBlock, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void Ambience::processBlock(float *left, float *right, int n) {
    for (int t = 0; t < n; ++t) closeness.next();
    ctx.speed += (speedTarget - ctx.speed) * (1.f - std::exp(-(float)n / (0.5f * (float)sr)));
    // Indoors glides over about 2.5 s; wetness and snow on the glass over about a second.
    const float glide = 1.f - std::exp(-(float)n / (0.8f * (float)sr)), slow = 1.f - std::exp(-(float)n / (0.3f * (float)sr));
    indoors += (indoorsTarget - indoors) * glide;
    if (std::fabs(indoorsTarget - indoors) < 1e-4f) indoors = indoorsTarget;
    ctx.wetness += (wetTarget - ctx.wetness) * slow;
    ctx.snowOnGlass += (snowTarget - ctx.snowOnGlass) * slow;
    if (std::fabs(indoors - indoorsApplied) > 0.002f) {
        indoorsApplied = indoors;
        // The window: a 2-pole low-pass from 20 kHz (open air) down to 1.2 kHz (inside), and up to 9 dB quieter.
        const float cutoff = 20000.f * std::pow(1200.f / 20000.f, indoors);
        const float g = std::tan(kPi * std::min(cutoff, 0.45f * (float)sr) / (float)sr), k = 1.41421356f;
        windowA1 = 1.f / (1.f + g * (g + k)); windowA2 = g * windowA1; windowA3 = g * windowA2;
        windowGain = std::pow(10.f, -9.f * indoors / 20.f);
    }
    const float c = closeness.value;
    if (std::fabs(c - closenessApplied) > 0.005f) {
        closenessApplied = c;
        const float cutoff = 5000.f * std::exp2(2.f * c);   // distant air takes the top off
        const float g = std::tan(kPi * std::min(cutoff, 0.45f * (float)sr) / (float)sr), k = 1.41421356f;
        airA1 = 1.f / (1.f + g * (g + k)); airA2 = g * airA1; airA3 = g * airA2;
        width = 0.75f + 0.5f * c;
        directGain = 0.6f + 0.4f * c;
        roomGain = 0.2f + 0.6f * (1.f - c);
        room.configure(0.25f, 0.5f, 8.f, 0.f);
    }

    // Outdoor sources (and thunder) and indoor ones on separate buses: only the outdoor ones go through the window.
    float dl[kBlock] = {}, dr[kBlock] = {}, sl[kBlock] = {}, sr2[kBlock] = {};
    float ol[kBlock] = {}, orr[kBlock] = {}, osl[kBlock] = {}, osr[kBlock] = {};
    float tl[kBlock], tr[kBlock];
    bool any = false, outdoor = false;
    for (int i = 0; i < ISD_AMB_COUNT; ++i) {
        Ramp &r = ramps[i];
        if (r.silent()) continue;
        const float g0 = r.value, g1 = r.advance(n);
        std::fill(tl, tl + n, 0.f); std::fill(tr, tr + n, 0.f);
        sources[i]->level = g1;
        sources[i]->render(tl, tr, n, ctx);
        const float k = kGain[i], d = sources[i]->direct, s = sources[i]->send, step = (g1 - g0) / (float)n;
        const bool in = sources[i]->indoor;
        float *bl = in ? dl : ol, *br = in ? dr : orr, *bsl = in ? sl : osl, *bsr = in ? sr2 : osr;
        float g = g0;
        for (int t = 0; t < n; ++t) {
            g += step;
            const float xl = tl[t] * g * k, xr = tr[t] * g * k;
            bl[t] += xl * d; br[t] += xr * d;
            bsl[t] += xl * s; bsr[t] += xr * s;
        }
        any = true;
        outdoor = outdoor || !in;
    }
    if (thunder->active()) {
        // A near clap peaks about −7 dBFS (RMS ≈ −18) and a far one sits near the beds; never into the limiter.
        constexpr float kThunderGain = 0.11f;
        std::fill(tl, tl + n, 0.f); std::fill(tr, tr + n, 0.f);
        thunder->render(tl, tr, n, (float)sr);
        for (int t = 0; t < n; ++t) {
            const float xl = tl[t] * kThunderGain, xr = tr[t] * kThunderGain;
            ol[t] += xl; orr[t] += xr; osl[t] += 0.7f * xl; osr[t] += 0.7f * xr;
        }
        any = true; outdoor = true;
    }
    if (outdoor) {
        float *bus[4] = {ol, orr, osl, osr};
        const bool open = indoors <= 0.f;   // outdoors: exactly as before, while the filter keeps tracking
        for (int b = 0; b < 4; ++b) {
            OneSVF &f = window[b];
            float *x = bus[b];
            for (int t = 0; t < n; ++t) {
                const float v3 = x[t] - f.ic2, v1 = windowA1 * f.ic1 + windowA2 * v3, v2 = f.ic2 + windowA2 * f.ic1 + windowA3 * v3;
                f.ic1 = 2.f * v1 - f.ic1; f.ic2 = 2.f * v2 - f.ic2;
                if (!open) x[t] = v2 * windowGain;
            }
        }
        for (int t = 0; t < n; ++t) { dl[t] += ol[t]; dr[t] += orr[t]; sl[t] += osl[t]; sr2[t] += osr[t]; }
    }
    // Air absorption and width on the direct sound.
    if (any) {
        for (int t = 0; t < n; ++t) {
            float *in[2] = {dl, dr};
            for (int ch = 0; ch < 2; ++ch) {
                OneSVF &f = air[ch];
                const float x = in[ch][t], v3 = x - f.ic2, v1 = airA1 * f.ic1 + airA2 * v3, v2 = f.ic2 + airA2 * f.ic1 + airA3 * v3;
                f.ic1 = 2.f * v1 - f.ic1; f.ic2 = 2.f * v2 - f.ic2;
                in[ch][t] = v2;
            }
            const float m = 0.5f * (dl[t] + dr[t]), s = 0.5f * (dl[t] - dr[t]) * width;
            dl[t] = m + s; dr[t] = m - s;
        }
    }
    float rl[kBlock] = {}, rr[kBlock] = {};
    if (any || roomLive) {
        room.process(sl, sr2, rl, rr, n);
        roomLive = any;
        if (!any) {   // let the tail ring out, then rest
            float e = 0;
            for (int t = 0; t < n; ++t) e += rl[t] * rl[t] + rr[t] * rr[t];
            roomLive = e > 1e-12f;
        }
    }
    // Ducking: down within half a second, back over about two.
    const float target = -4.f * activity, tau = target < duckDb ? 0.12f : 0.7f;
    const float d0 = duckDb;
    duckDb += (target - duckDb) * (1.f - std::exp(-(float)n / (tau * (float)sr)));
    const float g0 = std::pow(10.f, d0 / 20.f), g1 = std::pow(10.f, duckDb / 20.f), dg = (g1 - g0) / (float)n;
    float g = g0;
    for (int t = 0; t < n; ++t) {
        g += dg;
        left[t] = softLimit(g * (directGain * dl[t] + roomGain * rl[t]));
        right[t] = softLimit(g * (directGain * dr[t] + roomGain * rr[t]));
    }
}

} // namespace isd

// ---------------------------------------------------------------- C API
struct ISDAmbience {
    isd::Ambience engine;
    std::atomic<float> levels[ISD_AMB_COUNT];
    float applied[ISD_AMB_COUNT];
    std::atomic<float> closeness{0.5f}, activity{0.f}, cool{0.f}, density{1.f}, thunderDistance{0.5f};
    std::atomic<int> thunderSeq{0};
    int thunderSeen = 0;
    std::atomic<float> speed{0.f}, surfDistance{0.f}, waveStrength{0.5f};
    std::atomic<int> waveSeq{0};
    int waveSeen = 0;
    std::atomic<float> indoors{0.f}, wetness{0.f}, snowOnGlass{0.f};
    std::atomic<int> kettleSeq{0}, boatSeq{0};
    int kettleSeen = 0, boatSeen = 0;
    std::atomic<int> key{4 | 16};   // root | (major << 4): E major until the player's key is sensed
    std::atomic<int> bellSeq{0}, knockerSeq{0}, warblerSeq{0};
    int bellSeen = 0, knockerSeen = 0, warblerSeen = 0;
    std::atomic<float> bellHz{0.f};   // after each render: the bell's ringing fundamental, 0 while it is silent
    std::atomic<float> bubbleStrength{0.5f};
    std::atomic<int> bubbleSeq{0}, sonarSeq{0}, whaleSeq{0};
    int bubbleSeen = 0, sonarSeen = 0, whaleSeen = 0;
    std::atomic<float> sonarHz{0.f};   // after each render: the sonar's ringing ping, 0 while it is silent
    ISDAmbience(double sr, uint64_t seed) : engine(sr, seed) {
        for (int i = 0; i < ISD_AMB_COUNT; ++i) { levels[i].store(0.f); applied[i] = 0.f; }
    }
};

extern "C" {

ISDAmbience *isd_ambience_create(double sampleRate, int maxFrames, uint64_t seed) {
    (void)maxFrames;
    if (sampleRate <= 0) return nullptr;
    return new ISDAmbience(sampleRate, seed);
}

void isd_ambience_destroy(ISDAmbience *a) { delete a; }

void isd_ambience_set_level(ISDAmbience *a, ISDAmbienceSource source, float level) {
    if (!a || (int)source < 0 || (int)source >= ISD_AMB_COUNT || !std::isfinite(level)) return;
    a->levels[source].store(isd::clamp01(level), std::memory_order_relaxed);
}

void isd_ambience_set_closeness(ISDAmbience *a, float c) { if (a && std::isfinite(c)) a->closeness.store(isd::clamp01(c), std::memory_order_relaxed); }
void isd_ambience_set_activity(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->activity.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_night_cool(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->cool.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_density(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->density.store(std::clamp(v, 0.5f, 1.5f), std::memory_order_relaxed); }

void isd_ambience_trigger_thunder(ISDAmbience *a, float distance) {
    if (!a || !std::isfinite(distance)) return;
    a->thunderDistance.store(isd::clamp01(distance), std::memory_order_relaxed);
    a->thunderSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_trigger_wave(ISDAmbience *a, float strength) {
    if (!a || !std::isfinite(strength)) return;
    a->waveStrength.store(isd::clamp01(strength), std::memory_order_relaxed);
    a->waveSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_set_speed(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->speed.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_surf_distance(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->surfDistance.store(isd::clamp01(v), std::memory_order_relaxed); }

void isd_ambience_set_indoors(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->indoors.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_wetness(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->wetness.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_set_snow_on_glass(ISDAmbience *a, float v) { if (a && std::isfinite(v)) a->snowOnGlass.store(isd::clamp01(v), std::memory_order_relaxed); }
void isd_ambience_debug_start_kettle(ISDAmbience *a) { if (a) a->kettleSeq.fetch_add(1, std::memory_order_release); }
void isd_ambience_debug_start_boat(ISDAmbience *a) { if (a) a->boatSeq.fetch_add(1, std::memory_order_release); }

void isd_ambience_set_key(ISDAmbience *a, int root, int major) {
    if (!a || root < 0 || root > 11) return;   // the key can't be sensed: the bell stays where it is
    a->key.store(root | (major ? 16 : 0), std::memory_order_relaxed);
}

void isd_ambience_debug_strike_bell(ISDAmbience *a) { if (a) a->bellSeq.fetch_add(1, std::memory_order_release); }
void isd_ambience_debug_start_knocker(ISDAmbience *a) { if (a) a->knockerSeq.fetch_add(1, std::memory_order_release); }
void isd_ambience_debug_call_warbler(ISDAmbience *a) { if (a) a->warblerSeq.fetch_add(1, std::memory_order_release); }

void isd_ambience_trigger_bubbles(ISDAmbience *a, float strength) {
    if (!a || !std::isfinite(strength)) return;
    a->bubbleStrength.store(isd::clamp01(strength), std::memory_order_relaxed);
    a->bubbleSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_debug_ping_sonar(ISDAmbience *a) { if (a) a->sonarSeq.fetch_add(1, std::memory_order_release); }
void isd_ambience_debug_start_whale(ISDAmbience *a) { if (a) a->whaleSeq.fetch_add(1, std::memory_order_release); }

float isd_ambience_debug_sonar_hz(const ISDAmbience *a) {
    if (!a) return 0.f;
    const float ringing = a->sonarHz.load(std::memory_order_acquire);
    return ringing > 0.f ? ringing : isd::amb::sonarTonicHz(a->key.load(std::memory_order_relaxed) & 15);
}

float isd_ambience_debug_bell_hz(const ISDAmbience *a) {
    if (!a) return 0.f;
    const float ringing = a->bellHz.load(std::memory_order_acquire);
    return ringing > 0.f ? ringing : isd::amb::bellTonicHz(a->key.load(std::memory_order_relaxed) & 15);
}
int isd_ambience_debug_events(const ISDAmbience *a, ISDAmbienceSource source) { return a ? a->engine.events((int)source) : 0; }

void isd_ambience_render(ISDAmbience *a, float *left, float *right, int frames) {
    if (!a || frames <= 0) return;
    isd::DenormalGuard guard;
    for (int i = 0; i < ISD_AMB_COUNT; ++i) {
        const float v = a->levels[i].load(std::memory_order_relaxed);
        if (v != a->applied[i]) { a->applied[i] = v; a->engine.setLevel(i, v); }
    }
    a->engine.setCloseness(a->closeness.load(std::memory_order_relaxed));
    a->engine.setActivity(a->activity.load(std::memory_order_relaxed));
    a->engine.setNightCool(a->cool.load(std::memory_order_relaxed));
    a->engine.setDensity(a->density.load(std::memory_order_relaxed));
    const int seq = a->thunderSeq.load(std::memory_order_acquire);
    if (seq != a->thunderSeen) { a->thunderSeen = seq; a->engine.triggerThunder(a->thunderDistance.load(std::memory_order_relaxed)); }
    a->engine.setSpeed(a->speed.load(std::memory_order_relaxed));
    a->engine.setSurfDistance(a->surfDistance.load(std::memory_order_relaxed));
    const int waves = a->waveSeq.load(std::memory_order_acquire);
    if (waves != a->waveSeen) { a->waveSeen = waves; a->engine.triggerWave(a->waveStrength.load(std::memory_order_relaxed)); }
    a->engine.setIndoors(a->indoors.load(std::memory_order_relaxed));
    a->engine.setWetness(a->wetness.load(std::memory_order_relaxed));
    a->engine.setSnowOnGlass(a->snowOnGlass.load(std::memory_order_relaxed));
    const int kettles = a->kettleSeq.load(std::memory_order_acquire);
    if (kettles != a->kettleSeen) { a->kettleSeen = kettles; a->engine.startKettle(); }
    const int boats = a->boatSeq.load(std::memory_order_acquire);
    if (boats != a->boatSeen) { a->boatSeen = boats; a->engine.startBoat(); }
    const int key = a->key.load(std::memory_order_relaxed);
    a->engine.setKey(key & 15, (key & 16) != 0);   // before any strike this render: a new key waits for the next strike
    const int bells = a->bellSeq.load(std::memory_order_acquire);
    if (bells != a->bellSeen) { a->bellSeen = bells; a->engine.strikeBell(); }
    const int knockers = a->knockerSeq.load(std::memory_order_acquire);
    if (knockers != a->knockerSeen) { a->knockerSeen = knockers; a->engine.startKnocker(); }
    const int calls = a->warblerSeq.load(std::memory_order_acquire);
    if (calls != a->warblerSeen) { a->warblerSeen = calls; a->engine.callWarbler(); }
    const int pings = a->sonarSeq.load(std::memory_order_acquire);   // after the key: a new key waits for the next ping
    if (pings != a->sonarSeen) { a->sonarSeen = pings; a->engine.pingSonar(); }
    const int songs = a->whaleSeq.load(std::memory_order_acquire);
    if (songs != a->whaleSeen) { a->whaleSeen = songs; a->engine.startWhale(); }
    const int bursts = a->bubbleSeq.load(std::memory_order_acquire);
    if (bursts != a->bubbleSeen) { a->bubbleSeen = bursts; a->engine.triggerBubbles(a->bubbleStrength.load(std::memory_order_relaxed)); }
    a->engine.render(left, right, frames);
    a->bellHz.store(a->engine.bellRingingHz(), std::memory_order_release);
    a->sonarHz.store(a->engine.sonarRingingHz(), std::memory_order_release);
}

float isd_ambience_debug_tone_hz(float hz, float sampleRate, float seconds) {
    if (!(hz > 0.f) || !(sampleRate > 0.f) || !(seconds > 1.f)) return 0.f;
    using namespace isd::amb;
    float ph = 0.f;
    const float inc = hz / sampleRate;
    const long total = (long)((double)seconds * sampleRate), last = (long)sampleRate;
    double cycles = 0;
    for (long i = 0; i < total; ++i) {
        const float before = ph;
        advanceTone(ph, inc);
        if (i >= total - last) cycles += ph >= before ? (double)ph - before : (double)ph + (before - ph > 500.f ? 1000.0 : 1.0) - before;
    }
    return (float)cycles;
}

} // extern "C"
