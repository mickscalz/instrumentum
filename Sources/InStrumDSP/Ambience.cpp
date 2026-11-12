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
    /* grass wind */ 0.54f, /* hail on tin */ 0.109f, /* birds flee */ 0.149f, /* thunder roll */ 0.12f, /* inflow roar */ 0.169f,
    /* rain on dust */ 0.264f, /* dry cicadas */ 0.242f, /* windmill */ 0.134f, /* cattle grid */ 0.114f, /* dust ticks */ 0.6f,
    /* shimmer hum */ 0.0112f, /* far truck */ 0.0886f,
    /* vent rumble */ 0.232f, /* lava hiss */ 0.275f, /* steam vent */ 0.49f, /* rockfall */ 1.2f, /* eruption boom */ 0.142f,
    /* plume thunder */ 0.31f, /* wet tyres */ 0.233f, /* wipers */ 0.165f, /* drive engine */ 0.172f, /* drive passing car */ 0.5f,
    /* roof rain */ 0.142f, /* far siren */ 0.0196f,
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

// ---------------------------------------------------------------- Chime (a rare soft bell on the Glass partials, in your key)
/// The chime's tones (Small Wins spec §7), into `out` (6 at most), returning how many. Before a key is sensed, the six
/// it has always rung: E♭ major pentatonic, E♭5–E♭6. Once one is, the key's own pentatonic (major 0 2 4 7 9, minor
/// 0 3 5 7 10) in the same octave, MIDI 75–87: five tones, or six when E♭ is one of them.
inline int chimeTones(const AmbienceContext &c, float *out) {
    static constexpr float kBefore[6] = {622.25f, 698.46f, 783.99f, 932.33f, 1046.5f, 1244.5f};
    if (!c.keySensed) {
        for (int i = 0; i < 6; ++i) out[i] = kBefore[i];
        return 6;
    }
    static constexpr int kMajor[5] = {0, 2, 4, 7, 9}, kMinor[5] = {0, 3, 5, 7, 10};
    const int *scale = c.keyMajor ? kMajor : kMinor;
    const int root = ((c.keyRoot % 12) + 12) % 12;
    int n = 0;
    for (int m = 75; m <= 87 && n < 6; ++m) {
        const int degree = ((m - root) % 12 + 12) % 12;
        for (int k = 0; k < 5; ++k) {
            if (scale[k] != degree) continue;
            out[n++] = 440.f * std::exp2((float)(m - 69) / 12.f);
            break;
        }
    }
    return n;
}

class Chime final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRatio[6] = {1.f, 2.32f, 4.25f, 6.63f, 9.38f, 12.5f};
    static constexpr float kAmp[6] = {1.f, 0.55f, 0.35f, 0.22f, 0.14f, 0.09f};
    struct Bell {
        bool on = false; Partial p[6]; float gl = 0.7f, gr = 0.7f, hz = 0; int attack = 0, attackLen = 1; int check = 0;
        uint32_t serial = 0;
    } bells[4];
    float next = 0, second = -1;
    uint32_t serial = 0;

    /// Each strike picks its tone from the key as it stands then, and keeps it: a new key never retunes a ring. With all
    /// four ringing, the oldest makes way.
    void strike(const AmbienceContext &c) {
        Bell *b = nullptr;
        for (auto &x : bells) if (!x.on) { b = &x; break; }
        if (!b) { b = &bells[0]; for (auto &x : bells) if (x.serial < b->serial) b = &x; }
        float tones[6];
        const int count = chimeTones(c, tones);
        if (count <= 0) return;
        const float tone = tones[std::min(count - 1, (int)(rng.uniform() * ((float)count - 0.01f)))], v = 0.6f + 0.4f * rng.uniform();
        for (int i = 0; i < 6; ++i) {
            const float hz = tone * kRatio[i] * std::exp2((2.f * rng.bipolar()) / 1200.f);
            if (i == 0) b->hz = hz;
            b->p[i].start(hz, 6.f / (1.f + 0.6f * (float)i), v * kAmp[i], c.sr);
        }
        panGains(0.5f * rng.bipolar(), b->gl, b->gr);
        b->on = true; b->attack = 0; b->attackLen = (int)((0.002f + 0.002f * rng.uniform()) * c.sr);
        b->check = 0; b->serial = ++serial;
        ++events;
    }

public:
    explicit Chime(uint64_t seed) : rng(seed) { direct = 0.8f; send = 0.8f; }
    /// Up from silence: nothing left ringing from before (a ring cut off with the world never resumes with it).
    void wake(const AmbienceContext &) override {
        for (auto &b : bells) b.on = false;
        next = 15.f + 35.f * rng.uniform(); second = -1;
    }
    /// A strike now (tests): the next one waits its usual 80–160 s.
    void strikeNow(const AmbienceContext &c) { strike(c); next = (80.f + 80.f * rng.uniform()) / c.density; second = -1; }
    /// The struck fundamental of the newest ringing strike, or 0 while none rings.
    float ringingHz() const {
        const Bell *newest = nullptr;
        for (auto &b : bells) if (b.on && (!newest || b.serial > newest->serial)) newest = &b;
        return newest ? newest->hz : 0.f;
    }
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

// ================================================================ Storms (Sets 17 & 18): the storm and plains families

/// Pareto amplitudes (most small, a few big): at least 1, a tail of `alpha`, capped.
inline float pareto(FastRandom &rng, float alpha, float cap) { return std::min(cap, std::exp(expRand(rng) / alpha)); }

/// Glides a pitch toward its target in equal steps of pitch, about 63% of the way in `seconds` (a wind's or the air's
/// note drifts to a new key; it never jumps).
inline void glidePitch(float &hz, float target, float dt, float seconds) {
    if (!(hz > 0.f)) { hz = target; return; }
    hz *= std::exp2(std::log2(target / hz) * (1.f - std::exp(-dt / seconds)));
}

/// The inflow roar's resonance: a fifth (equal-tempered) below the key's tonic in A2–G♯3, so 73.4–138.6 Hz.
inline float roarHz(int root) { return 2.f * bellTonicHz(root) * 0.66741992708f; }
/// The heat shimmer's hum: the key's tonic in A5–G♯6 (the sonar's octave), with its fifth and octave above it.
inline float shimmerHz(int root) { return 16.f * bellTonicHz(root); }

// ---------------------------------------------------------------- Grass wind: a field of dry grass in the wind
/// The level is the wind: the stubble hisses brighter and busier as it rises, gust waves sweep across the field from one
/// side to the other, and seed heads tick in the gusts.
class GrassWind final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkW, pinkB;
    SVF hissL, hissR, hissW, topL, topR, body;
    Wander gust;
    struct Wave { bool on = false; float t = 0, dur = 2, from = -1, to = 1, amp = 1; } waves[3];
    Burst ticks[6];
    int nextTick = 0;
    float toWave = 2, toTick = 1, a = 0.55f, w = 0, wl = 0.7f, wr = 0.7f;

public:
    explicit GrassWind(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.3f; }
    void wake(const AmbienceContext &) override {
        for (auto &q : waves) q.on = false;
        toWave = 0.5f + 2.f * rng.uniform();
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, wind = level;
        const float g = gust.next(rng, dt, 3.f);
        if ((toWave -= dt) <= 0) {
            for (auto &q : waves) if (!q.on) {
                const float side = rng.uniform() < 0.5f ? -1.f : 1.f;
                q.on = true; q.t = 0; q.dur = 1.6f + 2.2f * rng.uniform(); q.amp = 0.5f + 0.5f * rng.uniform();
                q.from = side * (0.6f + 0.35f * rng.uniform()); q.to = -side * (0.6f + 0.35f * rng.uniform());
                break;
            }
            toWave = (2.5f + 5.f * rng.uniform()) * (1.4f - 0.6f * wind) / c.density;
        }
        float wave = 0, pan = 0;
        for (auto &q : waves) {
            if (!q.on) continue;
            q.t += dt;
            const float u = q.t / q.dur;
            if (u >= 1.f) { q.on = false; continue; }
            const float e = q.amp * (0.5f - 0.5f * std::cos(kTwoPi * u));
            wave += e; pan += e * (q.from + (q.to - q.from) * u);
        }
        if (wave > 0) pan /= wave;
        wave = std::min(1.2f, wave);
        // Brighter in a stronger wind and in each gust.
        const float centre = 1500.f + 2600.f * (0.45f + 0.55f * wind) * (0.75f + 0.25f * g + 0.3f * wave);
        hissL.set(centre, 0.8f, fsr); hissR.set(centre * 1.07f, 0.8f, fsr); hissW.set(centre * 1.15f, 0.9f, fsr);
        topL.set(9000.f, 0.7f, fsr); topR.set(9000.f, 0.7f, fsr); body.set(420.f, 0.7f, fsr);
        float pl, pr;
        panGains(pan, pl, pr);
        const float inv = 1.f / (float)n, a1 = 0.55f + 0.3f * g, w1 = 0.9f * wave;
        const float da = (a1 - a) * inv, dw = (w1 - w) * inv, dl = (pl - wl) * inv, dr = (pr - wr) * inv;
        // Seed heads ticking, more of them in the gusts.
        const float tickRate = (6.f + 50.f * wind * (0.3f + g + wave)) * c.density;
        toTick -= tickRate * dt;
        for (int k = 0; k < 3 && toTick <= 0.f; ++k) {
            ticks[nextTick].start(4000.f + 4000.f * rng.uniform(), 2.f, 0.0006f + 0.0012f * rng.uniform(),
                                  0.5f * pareto(rng, 2.5f, 3.f), 0.85f * rng.bipolar(), fsr);
            nextTick = (nextTick + 1) % 6;
            toTick += expRand(rng);
        }
        for (int t = 0; t < n; ++t) {
            a += da; w += dw; wl += dl; wr += dr;
            const float xb = 0.18f * body.low(pinkB.next(rng.bipolar()));
            const float xw = w * hissW.band(pinkW.next(rng.bipolar()));
            float yl = a * hissL.band(pinkL.next(rng.bipolar())) + xw * wl + xb;
            float yr = a * hissR.band(pinkR.next(rng.bipolar())) + xw * wr + xb;
            for (auto &k : ticks) if (k.on()) { const float x = k.next(rng); yl += x * k.gl; yr += x * k.gr; }
            l[t] += topL.low(yl); r[t] += topR.low(yr);
        }
    }
};

// ---------------------------------------------------------------- Hail on tin: a far shed's roof in a hailstorm
/// The level is the hail: stones strike the corrugated iron as a Poisson rain of impacts (700 a second at 1, rising with
/// the level's 1.5 power), each ringing the roof's own panel modes (seven on each half of the roof, fixed for the shed,
/// 1.5–4 kHz, ringing 30–90 ms) as strongly as where it lands lets them; the rare big stone (a Pareto tail) knocks the
/// frame. Mostly dry, so the roof keeps its own tuning.
class HailTin final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kModes = 7;
    static constexpr float kRate = 700.f, kMostRate = 1000.f;
    struct Mode { float re = 0, im = 0, cr = 1, ci = 0; };
    Mode roof[2][kModes];
    float weight[2][kModes] = {};
    float sideGl[2] = {0.7f, 0.7f}, sideGr[2] = {0.7f, 0.7f};
    Partial knock;
    SVF topL, topR;
    float toHit = 1;

    void hit(float sr) {
        const int s = rng.uniform() < 0.5f ? 0 : 1;
        const float a = 0.25f * pareto(rng, 2.3f, 4.f);
        for (int k = 0; k < kModes; ++k) roof[s][k].im += a * weight[s][k] * (0.25f + 0.75f * rng.uniform());   // where it lands
        // Now and then a big stone knocks the frame (about one hit in 200).
        if (a >= 0.9f && rng.uniform() < 0.25f && knock.energy() < 1e-4f) knock.startSine(170.f + 90.f * rng.uniform(), 0.12f, 0.12f * a, sr);
        if (events < 0x7fffffff) ++events;
    }

public:
    HailTin(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.1f;
        for (int s = 0; s < 2; ++s)
            for (int k = 0; k < kModes; ++k) {
                // Spread over the band (one mode in each seventh of 1.5–4 kHz, on a log scale), each its own decay.
                const float u = ((float)k + 0.15f + 0.7f * rng.uniform()) / (float)kModes;
                const float hz = 1500.f * std::exp2(1.415f * u), t60 = 0.03f + 0.06f * rng.uniform();
                const float rr = std::pow(10.f, -3.f / (t60 * sr)), wv = kTwoPi * hz / sr;
                roof[s][k].cr = rr * std::cos(wv); roof[s][k].ci = rr * std::sin(wv);
                weight[s][k] = 0.5f + 0.5f * rng.uniform();
            }
        panGains(0.05f, sideGl[0], sideGr[0]); panGains(0.45f, sideGl[1], sideGr[1]);   // the shed, off to the right
        topL.set(7000.f, 0.7f, sr); topR.set(7000.f, 0.7f, sr);
    }
    void wake(const AmbienceContext &) override {
        for (auto &side : roof) for (auto &m : side) m.re = m.im = 0;
        toHit = expRand(rng);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float step = std::min(kMostRate, kRate * level * std::sqrt(level) * c.density) / c.sr;
        for (int i = 0; i < n; ++i) {
            if ((toHit -= step) <= 0.f) { hit(c.sr); toHit += expRand(rng); }
            float y[2] = {0, 0};
            for (int s = 0; s < 2; ++s)
                for (auto &m : roof[s]) {
                    const float nr = m.re * m.cr - m.im * m.ci, ni = m.re * m.ci + m.im * m.cr;
                    m.re = nr; m.im = ni; y[s] += ni;
                }
            const float k = knock.mag > 0.f ? knock.next() : 0.f;
            if (knock.mag > 0.f && knock.energy() < 1e-10f) knock.mag = 0.f;
            l[i] += topL.low(y[0] * sideGl[0] + y[1] * sideGl[1] + 0.6f * k);
            r[i] += topR.low(y[0] * sideGr[0] + y[1] * sideGr[1] + 0.8f * k);
        }
    }
};

// ---------------------------------------------------------------- Birds fleeing the storm
/// A flock flushed out of the stubble ahead of the storm: a burst of wingbeats, then a scatter of harsh alarm calls
/// (galah-like screeches near 2–3.5 kHz, rough with a fast flutter), one at a time, each farther round to one side and
/// fainter and duller than the last, so the calls sweep away from the storm (straight ahead) in azimuth. A flight as the
/// level comes up (the world raises it on its first big moment), then another every 12–30 s.
class BirdsFlee final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kMost = 13;
    struct Call { float at = 0, dur = 0.1f, f0 = 2400, f1 = 2800, depth = 0.08f, amp = 1, pan = 0, cut = 6000; };
    Call calls[kMost];
    int count = 0, cur = -1;
    float t = -1, toFlight = 1, ph = 0, fm = 0, fmHz = 90, wingHz = 12, wingDur = 0.8f, gl = 0.7f, gr = 0.7f;
    float wingGl = 0.7f, wingGr = 0.7f;
    int flights = 0;   // since the level came up: the field empties, so each flight comes later than the last

    float flightInterval(const AmbienceContext &c) { return (15.f + 30.f * rng.uniform()) * (1.f + 0.5f * (float)std::min(flights, 6)) / c.density; }
    SVF breath, far, wings;

    void flight() {
        count = 8 + (int)(rng.uniform() * 5.99f);
        const float side = rng.uniform() < 0.5f ? -1.f : 1.f, p0 = 0.06f + 0.12f * rng.uniform(), p1 = 0.82f + 0.15f * rng.uniform();
        const float span = 3.f + 2.5f * rng.uniform();
        float at = 0.3f + 0.2f * rng.uniform();
        for (int i = 0; i < count; ++i) {
            Call &q = calls[i];
            const float frac = (float)i / (float)(count - 1);
            q.at = at; q.dur = 0.09f + 0.12f * rng.uniform();
            q.pan = side * (p0 + (p1 - p0) * std::pow(frac, 0.85f));
            q.f0 = 2000.f + 900.f * rng.uniform(); q.f1 = q.f0 * (1.12f + 0.15f * rng.uniform()); q.depth = 0.05f + 0.06f * rng.uniform();
            q.amp = (1.f - 0.62f * frac) * (0.75f + 0.25f * rng.uniform());
            q.cut = 7500.f - 4300.f * frac;
            at += q.dur + std::max(0.07f, span / (float)count - q.dur) * (0.6f + 0.8f * rng.uniform());
        }
        t = 0; cur = -1; wingHz = 10.f + 5.f * rng.uniform(); wingDur = 0.6f + 0.4f * rng.uniform(); ++flights;
        panGains(0.15f * rng.bipolar(), wingGl, wingGr);
        fmHz = 70.f + 40.f * rng.uniform();
    }

public:
    // Mostly direct: an open field gives little back, and each call is heard where the bird is.
    BirdsFlee(uint64_t seed, float sr) : rng(seed) { direct = 1.f; send = 0.12f; wings.set(900.f, 0.8f, sr); }
    void wake(const AmbienceContext &) override { t = -1; flights = 0; toFlight = 0.15f + 0.5f * rng.uniform(); }
    void triggerNow(const AmbienceContext &c) override { flight(); toFlight = flightInterval(c); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, invSr = 1.f / fsr;
        if (t < 0) {
            if ((toFlight -= (float)n * invSr) > 0) return;
            flight();
            toFlight = flightInterval(c);
        }
        for (int i = 0; i < n && t >= 0; ++i) {
            float yl = 0, yr = 0;
            if (t < wingDur) {   // the flock lifting: wingbeats, fading as it climbs away
                const float e = (1.f - t / wingDur), beat = 0.5f - 0.5f * std::cos(kTwoPi * wingHz * t);
                const float x = 0.5f * e * e * beat * wings.band(rng.bipolar());
                yl += x * wingGl; yr += x * wingGr;
            }
            const int next = cur + 1;
            if (next < count && t >= calls[next].at) {   // the next call: where it is, how far off
                cur = next;
                const Call &q = calls[cur];
                far.set(q.cut, 0.7f, fsr); breath.set(2.f * q.f0, 1.5f, fsr); panGains(q.pan, gl, gr);
                ph = 0; fm = 0;
                ++events;
            }
            if (cur >= 0 && cur < count) {
                const Call &q = calls[cur];
                const float u = t - q.at;
                if (u < q.dur) {
                    const float x = u / q.dur;
                    const float env = std::min(1.f, u / 0.008f) * std::min(1.f, (q.dur - u) / 0.03f);
                    const float arch = x < 0.35f ? x / 0.35f : 1.f - 0.6f * (x - 0.35f) / 0.65f;   // up, then sagging
                    advanceTone(fm, fmHz * invSr);
                    const float f = (q.f0 + (q.f1 - q.f0) * arch) * (1.f + q.depth * sin2pi(fm));
                    advanceTone(ph, f * invSr);
                    const float tone = sin2pi(ph) + 0.55f * sin2pi(2.f * ph) + 0.3f * sin2pi(3.f * ph) + 0.15f * sin2pi(4.f * ph);
                    const float y = far.low(q.amp * env * (tone + 0.35f * breath.band(rng.bipolar())));
                    yl += y * gl; yr += y * gr;
                } else {
                    const float y = far.low(0.f);
                    yl += y * gl; yr += y * gr;
                }
            }
            l[i] += yl; r[i] += yr;
            t += invSr;
            if (cur == count - 1 && t > calls[cur].at + calls[cur].dur + 0.05f) t = -1;
        }
    }
};

// ---------------------------------------------------------------- Thunder roll: thunder that arrives late
/// A strike's thunder (spec §3, §8.3), from the queue: the roll starts when its delay runs out (to the sample), from the
/// channel's arrivals: the nearest part first (a sharp onset, a ripping crack when it is close, a boom under it), then
/// the rest of the channel over 2–8 s (the farther, the longer, the softer and the lower: front-loaded when close, a
/// slow swell when far), nearly all of it below 150 Hz, in no key. It makes no sound of its own: every roll is a strike's
/// (picture first, sound late). The queue holds 16 (a 17th drops the oldest) and is cleared as the roll goes silent.
class ThunderRoll final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kQueue = 16, kRolls = 6, kArrivals = 20, kBooms = 3;
    struct Pending { bool on = false; int left = 0; float km = 1, strength = 1; uint32_t serial = 0; } queue[kQueue];
    struct Arrival { float at = 0, amp = 0, rise = 0.01f, tau = 0.3f; };
    struct Roll {
        bool on = false;
        uint32_t serial = 0;
        int wait = 0, count = 0, booms = 0, nextBoom = 0;
        float t = 0, end = 3, gain = 1, env = 0, fade = 1, fadeStep = 0, gl = 0.7f, gr = 0.7f;
        float crack = 0, crackDecay = 1, cut = 150;
        Arrival arr[kArrivals];
        Partial boom[kBooms];
        float boomAt[kBooms] = {}, boomHz[kBooms] = {}, boomT60[kBooms] = {}, boomAmp[kBooms] = {};
        Brown brownL, brownR;
        SVF lowL[2], lowR[2], hpL[2], hpR[2], crackF, crackTop;
    } rolls[kRolls];
    uint32_t serial = 0, rollSerial = 0;
    // The rumble's scale: about 0.25 RMS at an envelope of 1 (the brown noise, its two low-passes and the 25 Hz high-pass).
    static constexpr float kRumble = 18.f;

    static float shape(const Arrival &a, float t) {
        const float u = t - a.at;
        if (u <= 0.f) return 0.f;
        if (u < a.rise) { const float s = u / a.rise; return a.amp * s * s * (3.f - 2.f * s); }
        return a.amp * std::exp(-(u - a.rise) / a.tau);
    }
    static float envelope(const Roll &r, float t) {
        float e = 0;
        for (int i = 0; i < r.count; ++i) e += shape(r.arr[i], t);
        return e;
    }

    void start(const Pending &p, int offset, float sr) {
        Roll *r = nullptr;
        for (auto &x : rolls) if (!x.on) { r = &x; break; }
        if (!r) {   // every voice rolling (a storm overhead): the quietest gives way
            r = &rolls[0];
            for (auto &x : rolls) if (x.env * x.gain < r->env * r->gain) r = &x;
        }
        const float km = std::clamp(p.km, 0.f, 4.f), s = p.strength, far = km / 4.f;
        r->on = true; r->serial = ++rollSerial; r->wait = offset; r->t = 0; r->env = 0; r->fade = 1; r->fadeStep = 0;
        r->gain = (0.35f + 0.65f * s) / (1.f + 0.9f * km);   // 13 dB down at 4 km
        const float dur = std::clamp(2.5f + 1.05f * km + 0.6f * s + 1.2f * rng.uniform(), 2.5f, 7.6f);
        const float span = std::max(0.5f, dur - 1.6f - 0.3f * far);   // the arrivals; the last of them ring on to `dur`
        r->count = std::min(kArrivals, 6 + (int)(dur * 1.5f + 3.f * s * rng.uniform()));
        r->arr[0] = {0.f, 1.f - 0.3f * far, 0.006f + 0.02f * far, 0.25f + 0.2f * rng.uniform() + 0.2f * far};
        float last = r->arr[0].rise + 5.f * r->arr[0].tau;
        for (int i = 1; i < r->count; ++i) {
            // Front-loaded when close (most of the channel is near), evenly spread when far.
            const float u = rng.uniform(), x = std::pow(u, 1.5f - 0.5f * far);
            Arrival &a = r->arr[i];
            a.at = span * x;
            // Close, the clap is the loudest and the rest roll away under it; far, the roll swells and fades.
            const float profile = (1.f - far) * 0.6f * std::exp(-2.2f * x) + far * (0.45f + 0.55f * std::sin(kPi * x));
            a.amp = (0.25f + 0.55f * rng.uniform()) * profile;
            a.rise = 0.015f + 0.06f * rng.uniform() + 0.12f * far;
            a.tau = 0.15f + 0.3f * rng.uniform() + 0.35f * far;
            last = std::max(last, a.at + a.rise + 5.f * a.tau);
        }
        // However the arrivals overlap, the roll at its loudest is the strike's own loudness (the distance sets it).
        float most = 0;
        for (int k = 0; k <= 96; ++k) most = std::max(most, envelope(*r, (float)k * (span + 0.4f) / 96.f));
        if (most > 1.f) for (int i = 0; i < r->count; ++i) r->arr[i].amp /= most;
        // Booms: the first arrival's, then the two biggest after it.
        r->booms = 0; r->nextBoom = 0;
        r->boomAt[0] = 0.f; r->boomHz[0] = 40.f + 18.f * rng.uniform(); r->boomT60[0] = 0.7f + 0.5f * rng.uniform();
        r->boomAmp[0] = 0.55f * (1.f - 0.4f * far);
        r->booms = 1;
        int took = -1;
        for (int pass = 0; pass < 2; ++pass) {
            int best = -1;
            for (int i = 1; i < r->count; ++i)
                if (i != took && r->arr[i].amp > 0.45f && (best < 0 || r->arr[i].amp > r->arr[best].amp)) best = i;
            took = best;
            if (best < 0) break;
            r->boomAt[r->booms] = r->arr[best].at + 0.5f * r->arr[best].rise; r->boomHz[r->booms] = 36.f + 20.f * rng.uniform();
            r->boomT60[r->booms] = 0.6f + 0.6f * rng.uniform(); r->boomAmp[r->booms] = 0.45f * r->arr[best].amp;
            ++r->booms;
        }
        // Keep the booms in time order, so each starts as the roll's clock passes it.
        for (int a = 1; a < r->booms; ++a)
            for (int b = a; b > 0 && r->boomAt[b] < r->boomAt[b - 1]; --b) {
                std::swap(r->boomAt[b], r->boomAt[b - 1]); std::swap(r->boomHz[b], r->boomHz[b - 1]);
                std::swap(r->boomT60[b], r->boomT60[b - 1]); std::swap(r->boomAmp[b], r->boomAmp[b - 1]);
            }
        for (auto &b : r->boom) b.mag = 0;
        r->end = last + 1.f;
        // The farther, the lower: the air takes the top off the rumble (170 Hz close, 90 Hz at 4 km).
        r->cut = 170.f - 20.f * km;
        for (int k = 0; k < 2; ++k) { r->lowL[k].clear(); r->lowR[k].clear(); r->lowL[k].set(r->cut, 0.7f, sr); r->lowR[k].set(r->cut * 1.04f, 0.7f, sr); }
        // Nothing below 28 Hz: what no speaker plays would only take headroom (24 dB an octave).
        for (int k = 0; k < 2; ++k) { r->hpL[k].clear(); r->hpR[k].clear(); r->hpL[k].set(28.f, 0.7f, sr); r->hpR[k].set(28.f, 0.7f, sr); }
        r->brownL.y = r->brownR.y = 0;
        // A close one rips first: a crack above the rumble, gone in a tenth of a second.
        r->crack = km < 1.5f ? 0.9f * (1.f - km / 1.5f) * (0.4f + 0.6f * s) : 0.f;
        r->crackDecay = std::exp(-1.f / ((0.07f + 0.05f * rng.uniform()) * sr));
        r->crackF.clear(); r->crackF.set(1100.f, 0.6f, sr); r->crackTop.clear(); r->crackTop.set(3500.f, 0.7f, sr);
        panGains(0.3f * rng.bipolar(), r->gl, r->gr);
        if (events < 0x7fffffff) ++events;
    }

public:
    explicit ThunderRoll(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.6f; }
    /// A roll on its way: it starts `delaySeconds` (0…12) from the start of the next render, `strength` 0…1, from a
    /// strike delaySeconds / 3 km off. With 16 waiting, the oldest gives way.
    void enqueue(float delaySeconds, float strength, float sr) {
        Pending *p = nullptr;
        for (auto &q : queue) if (!q.on) { p = &q; break; }
        if (!p) { p = &queue[0]; for (auto &q : queue) if (q.serial < p->serial) p = &q; }
        const float d = std::clamp(delaySeconds, 0.f, 12.f);
        p->on = true; p->left = (int)std::lround(d * sr); p->km = d / 3.f; p->strength = clamp01(strength); p->serial = ++serial;
    }
    void clearQueue() { for (auto &q : queue) q.on = false; }
    /// Panic: nothing more on its way, and everything rolling gone within 40 ms.
    void silence(float sr) override {
        clearQueue();
        for (auto &r : rolls) if (r.on) r.fadeStep = 1.f / (0.04f * sr);
    }
    void wake(const AmbienceContext &) override { clearQueue(); for (auto &r : rolls) r.on = false; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, invSr = 1.f / fsr;
        for (auto &q : queue) {
            if (!q.on) continue;
            if (q.left < n) { start(q, q.left, fsr); q.on = false; }
            else q.left -= n;
        }
        for (auto &v : rolls) {
            if (!v.on) continue;
            const int from = std::min(v.wait, n);
            v.wait -= from;
            if (from >= n) continue;
            const float t1 = v.t + (float)(n - from) * invSr, e1 = envelope(v, t1);
            const float de = (e1 - v.env) / (float)(n - from);
            while (v.nextBoom < v.booms && v.boomAt[v.nextBoom] <= t1) {
                const int b = v.nextBoom++;
                v.boom[b].startSine(v.boomHz[b], v.boomT60[b], v.boomAmp[b], fsr);
            }
            for (int i = from; i < n; ++i) {
                v.env += de;
                const float rl = v.hpL[1].high(v.hpL[0].high(v.lowL[1].low(v.lowL[0].low(v.brownL.next(rng.bipolar())))));
                const float rr = v.hpR[1].high(v.hpR[0].high(v.lowR[1].low(v.lowR[0].low(v.brownR.next(rng.bipolar())))));
                float b = 0;
                for (int k = 0; k < v.booms; ++k) if (v.boom[k].mag > 0.f) b += v.boom[k].next();
                float ck = 0;
                if (v.crack > 1e-4f) { ck = v.crack * v.crackTop.low(v.crackF.band(rng.bipolar())); v.crack *= v.crackDecay; }
                const float g = v.gain * v.fade, rumble = kRumble * v.env;
                l[i] += g * (rumble * rl + (b + ck) * v.gl);
                r[i] += g * (rumble * rr + (b + ck) * v.gr);
                if (v.fadeStep > 0.f && (v.fade -= v.fadeStep) <= 0.f) { v.on = false; break; }
            }
            v.t = t1;
            if (v.t > v.end) v.on = false;
        }
    }
};

// ---------------------------------------------------------------- Inflow roar: the storm drawing the air in
/// A low wind body (brown noise under a low-pass that opens as the level, the storm's energy, rises) with a resonant
/// throat a fifth below the key's tonic (in A2–G♯3: a narrow band of the wind itself, Q 45, and a fainter one an octave
/// up), so the roar sits under the music instead of against it; a new key glides in over about 1.5 s. All dry: the
/// shared room's modulated tail would pull it off the key.
class InflowRoar final : public AmbienceSource {
    FastRandom rng;
    Brown brownL, brownR;
    SVF bodyL, bodyR, lowCutL, lowCutR, throatL, throatR, coreL, coreR, octL, octR;
    Wander swell;
    float hz = 0, a = 0.85f, applied = -1, bodyCut = -1;
    // The throat: a breathy band (Q 45) round a narrow core (Q 400, a quarter of a hertz wide) that carries the pitch,
    // breathing slowly in level, like wind over a pipe.
    static constexpr float kQ = 45.f, kCoreQ = 400.f;

public:
    InflowRoar(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.f;
        lowCutL.set(38.f, 0.7f, sr); lowCutR.set(38.f, 0.7f, sr);   // nothing a speaker can't play
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        glidePitch(hz, roarHz(c.keyRoot), dt, 1.5f);
        if (std::fabs(hz - applied) > 1e-4f * hz) {
            applied = hz;
            throatL.set(hz, kQ, fsr); throatR.set(hz, kQ, fsr); coreL.set(hz, kCoreQ, fsr); coreR.set(hz, kCoreQ, fsr);
            octL.set(2.f * hz, kQ, fsr); octR.set(2.f * hz, kQ, fsr);
        }
        const float cut = 140.f + 220.f * level;
        if (std::fabs(cut - bodyCut) > 0.5f) { bodyCut = cut; bodyL.set(cut, 0.6f, fsr); bodyR.set(cut * 1.05f, 0.6f, fsr); }
        const float a1 = 0.7f + 0.3f * swell.next(rng, dt, 5.f), da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            const float bl = lowCutL.high(bodyL.low(brownL.next(rng.bipolar()))), br = lowCutR.high(bodyR.low(brownR.next(rng.bipolar())));
            const float tl = throatL.band(rng.bipolar()) + 5.f * coreL.band(rng.bipolar()) + 0.3f * octL.band(rng.bipolar());
            const float tr = throatR.band(rng.bipolar()) + 5.f * coreR.band(rng.bipolar()) + 0.3f * octR.band(rng.bipolar());
            l[t] += a * (4.f * bl + 20.f * tl);
            r[t] += a * (4.f * br + 20.f * tr);
        }
    }
};

// ---------------------------------------------------------------- Rain on dust: the smell of rain, then its first drops
/// Petrichor: a soft hiss (the rain curtain still far off, 1.1 kHz up, brighter as it nears), heard from the first of
/// the level; the first fat drops patter on the dust only past 0.6 (16 a second at 1), each a dull thud with a tick of
/// grit, so the hiss always comes before the rain, and virga's petrichor (0.5) never drops a drop.
class RainOnDust final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR;
    SVF hpL, hpR, lpL, lpR;
    Wander swell;
    struct Drop { Burst thud, grit; } drops[8];
    int nextDrop = 0;
    float a = 0.9f, toDrop = 1, lpApplied = -1;

public:
    RainOnDust(uint64_t seed, float sr) : rng(seed) { direct = 1.f; send = 0.35f; hpL.set(1100.f, 0.7f, sr); hpR.set(1150.f, 0.7f, sr); }
    void wake(const AmbienceContext &) override { toDrop = expRand(rng); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        const float lp = 3500.f + 3500.f * level;
        if (std::fabs(lp - lpApplied) > 5.f) { lpApplied = lp; lpL.set(lp, 0.7f, fsr); lpR.set(lp * 1.04f, 0.7f, fsr); }
        const float a1 = 0.8f + 0.2f * swell.next(rng, dt, 3.f), da = (a1 - a) / (float)n;
        const float perSecond = 16.f * std::max(0.f, level - 0.6f) / 0.4f * c.density;
        toDrop -= perSecond * dt;
        for (int k = 0; k < 3 && toDrop <= 0.f; ++k) {
            Drop &d = drops[nextDrop]; nextDrop = (nextDrop + 1) & 7;
            const float amp = 0.6f * pareto(rng, 3.f, 3.f), pan = 0.8f * rng.bipolar();
            d.thud.start(380.f + 620.f * rng.uniform(), 1.3f, 0.012f + 0.013f * rng.uniform(), amp, pan, fsr);
            d.grit.start(3000.f + 2500.f * rng.uniform(), 2.f, 0.0015f, 0.3f * amp, pan, fsr);
            toDrop += expRand(rng);
            ++events;
        }
        for (int t = 0; t < n; ++t) {
            a += da;
            float yl = a * lpL.low(hpL.high(pinkL.next(rng.bipolar()))), yr = a * lpR.low(hpR.high(pinkR.next(rng.bipolar())));
            for (auto &d : drops) {
                if (d.thud.on()) { const float x = d.thud.next(rng); yl += x * d.thud.gl; yr += x * d.thud.gr; }
                if (d.grit.on()) { const float x = d.grit.next(rng); yl += x * d.grit.gl; yr += x * d.grit.gr; }
            }
            l[t] += yl; r[t] += yr;
        }
    }
};

// ---------------------------------------------------------------- Dry cicadas: the dusk chorus on the plain
/// Six singers, each a train of tymbal clicks (140–260 a second) ringing its body's resonance (4.2–6.8 kHz), in phrases
/// that swell, hold for 3–12 s and fade. A drop in the level to nothing (the world hushing them before a close strike)
/// stops the whole chorus dead, together, within 50 ms, as a startled chorus does; when the level comes back they start
/// again one by one.
class DryCicadas final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kSingers = 6;
    struct Singer {
        SVF res;
        float rate = 200, ph = 0, gl = 0.7f, gr = 0.7f, gain = 1, env = 0, t = 0, rise = 0.8f, hold = 6, fall = 1, rest = 2;
        int stage = 0;   // 0 resting, 1 swelling, 2 holding, 3 fading
    } singers[kSingers];
    float gate = 1;
    bool hushed = false;

    void restAll(float most) {
        for (auto &s : singers) { s.stage = 0; s.t = 0; s.env = 0; s.rest = 0.2f + most * rng.uniform(); }
    }

public:
    DryCicadas(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.15f;
        for (auto &s : singers) {
            s.res.set(4200.f + 2600.f * rng.uniform(), 18.f + 8.f * rng.uniform(), sr);   // the body rings 1–2 ms a click
            s.rate = 140.f + 120.f * rng.uniform();
            s.gain = 0.6f + 0.4f * rng.uniform();
            panGains(0.9f * rng.bipolar(), s.gl, s.gr);
        }
    }
    void wake(const AmbienceContext &) override { hushed = false; gate = 1; restAll(1.5f); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        const bool hush = levelTarget <= 0.02f && level > 0.1f;
        if (hush && !hushed) hushed = true;
        else if (hushed && levelTarget > 0.02f) { hushed = false; gate = 1; restAll(5.f); }   // back, one by one
        const float g1 = hushed ? std::max(0.f, gate - dt / 0.04f) : 1.f, dg = (g1 - gate) / (float)n;
        if (hushed && gate <= 0.f) return;
        for (auto &s : singers) {   // the phrases, at control rate
            s.t += dt;
            switch (s.stage) {
            case 0: if (s.t >= s.rest) { s.stage = 1; s.t = 0; s.rise = 0.4f + 0.8f * rng.uniform(); ++events; } break;
            case 1: if (s.t >= s.rise) { s.stage = 2; s.t = 0; s.hold = (3.f + 9.f * rng.uniform()); } break;
            case 2: if (s.t >= s.hold) { s.stage = 3; s.t = 0; s.fall = 0.5f + 1.f * rng.uniform(); } break;
            default: if (s.t >= s.fall) { s.stage = 0; s.t = 0; s.rest = (0.5f + 3.5f * rng.uniform()) / c.density; } break;
            }
        }
        bool singing[kSingers];
        for (int k = 0; k < kSingers; ++k) singing[k] = singers[k].stage != 0 || singers[k].env > 1e-4f;
        for (int i = 0; i < n; ++i) {
            gate += dg;
            float yl = 0, yr = 0;
            for (int k = 0; k < kSingers; ++k) {
                if (!singing[k]) continue;
                Singer &s = singers[k];
                float e = 0;
                switch (s.stage) {
                case 1: e = std::min(1.f, s.t / s.rise); break;
                case 2: e = 1.f; break;
                case 3: e = std::max(0.f, 1.f - s.t / s.fall); break;
                default: break;
                }
                s.env += (e - s.env) * 0.002f;
                s.ph += s.rate * invSr;
                float kick = 0;
                if (s.ph >= 1.f) { s.ph -= 1.f; kick = 30.f * (0.8f + 0.4f * rng.uniform()); }
                const float y = s.gain * s.env * s.res.band(kick + 0.8f * rng.bipolar());
                yl += y * s.gl; yr += y * s.gr;
            }
            l[i] += gate * yl; r[i] += gate * yr;
        }
    }
};

// ---------------------------------------------------------------- Windmill: a steel water pump in the wind
/// The level is the wind: below the cut-in (0.08) the wheel stands still; above it the pump works at 0.75 × (level −
/// 0.08) / 0.92 strokes a second (45 a minute in a gale), the wheel speeding up and running down with its weight (2.5 s
/// up, 5 s down). Each stroke clanks at the top (the rod and the gear: inharmonic iron partials near 300 Hz–2.2 kHz,
/// pitched afresh each time, so in no key) and knocks softer at the bottom, the bushing creaks on most up-strokes (a
/// stick-slip squeal), and the wheel whirs. Off to the left, by the tank.
class Windmill final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRatio[4] = {1.f, 2.41f, 4.17f, 6.89f}, kAmp[4] = {1.f, 0.6f, 0.4f, 0.25f}, kT60[4] = {0.45f, 0.3f, 0.2f, 0.12f};
    Partial clank[4], thunk;
    Burst click;
    struct Creak { bool on = false; float t = 0, dur = 0.4f, ph = 0, rate0 = 30, rate1 = 60, f0 = 900, amp = 1; SVF res; } creak;
    SVF whirBand;
    float speed = 0, phase = 0, wheel = 0, gl = 0.7f, gr = 0.7f, whir = 0;

    float rateFor(float wind) const { return 0.75f * std::max(0.f, wind - 0.08f) / 0.92f; }
    void strike(float scale, float lower, float sr) {
        const float f0 = 285.f * lower * (0.96f + 0.08f * rng.uniform());
        for (int k = 0; k < 4; ++k)
            clank[k].startSine(f0 * kRatio[k] * (1.f + 0.01f * rng.bipolar()), kT60[k] * (0.85f + 0.3f * rng.uniform()) * lower,
                               scale * kAmp[k], sr);
        thunk.startSine(95.f + 35.f * rng.uniform(), 0.18f, 0.9f * scale, sr);
        click.start(2500.f, 1.f, 0.003f, 2.f * scale, 0.f, sr);
    }

public:
    explicit Windmill(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.35f;
        panGains(-0.5f, gl, gr);
        whirBand.set(900.f, 1.f, sr);
    }
    void wake(const AmbienceContext &) override { speed = 0; phase = 0.6f * rng.uniform(); creak.on = false; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        const float want = rateFor(level);
        speed += (want - speed) * (1.f - std::exp(-dt / (want > speed ? 2.5f : 5.f)));
        if (want <= 0.f && speed < 1e-4f) speed = 0;   // run down: it stands still
        const float p0 = phase;
        phase += speed * dt;
        wheel += 3.29f * speed * dt;   // back-geared: the wheel turns 3.29 times a stroke
        wheel -= std::floor(wheel);
        const float drive = std::min(1.f, speed / 0.75f), scale = 0.5f + 0.5f * drive;
        if (phase >= 1.f) {   // the top of the stroke: the clank
            phase -= 1.f;
            strike(scale, 1.f, fsr);
            ++events;
            if (rng.uniform() < 0.55f) {   // and on the way up, the bushing creaks
                creak.on = true; creak.t = -(0.1f + 0.15f * rng.uniform()) / std::max(0.2f, speed);
                creak.dur = std::min(1.f, (0.25f + 0.35f * rng.uniform()) / std::max(0.3f, speed));
                creak.rate0 = 25.f + 20.f * rng.uniform(); creak.rate1 = 45.f + 30.f * rng.uniform();
                creak.f0 = 650.f + 750.f * rng.uniform(); creak.amp = 0.5f + 0.5f * rng.uniform(); creak.ph = 0;
            }
        } else if (p0 < 0.5f && phase >= 0.5f) {   // the bottom: a softer knock, lower
            strike(0.45f * scale, 0.62f, fsr);
        }
        const float w1 = 0.15f * drive, dw = (w1 - whir) / (float)n;
        float creakInc = 0, creakTone = 1;
        if (creak.on && creak.t >= 0) {
            const float u = std::min(1.f, creak.t / creak.dur), arch = std::sin(kPi * u);
            creakInc = (creak.rate0 + (creak.rate1 - creak.rate0) * arch) * invSr;
            creakTone = 1.f + 0.15f * arch;
            creak.res.set(creak.f0 * creakTone, 14.f, fsr);
        }
        const bool sounding = clank[0].mag > 0.f || thunk.mag > 0.f || click.on() || creak.on || whir > 1e-4f || w1 > 0.f;
        if (!sounding) return;
        for (int i = 0; i < n; ++i) {
            whir += dw;
            float x = 0;
            for (auto &p : clank) if (p.mag > 0.f) x += p.next();
            if (thunk.mag > 0.f) x += thunk.next();
            if (click.on()) x += click.next(rng);
            if (creak.on) {
                if (creak.t >= 0) {
                    const float u = creak.t / creak.dur;
                    float slip = 0;
                    creak.ph += creakInc;
                    if (creak.ph >= 1.f) { creak.ph -= 1.f + 0.15f * (rng.uniform() - 0.5f); slip = 30.f * (0.6f + 0.4f * rng.uniform()); }
                    const float env = std::sin(kPi * std::min(1.f, u));
                    x += creak.amp * env * creak.res.band(slip);
                    if (u >= 1.f) creak.on = false;
                }
                creak.t += invSr;
            }
            if (whir > 1e-4f) x += whir * (0.6f + 0.4f * sin2pi(18.f * wheel)) * whirBand.band(rng.bipolar());
            l[i] += x * gl; r[i] += x * gr;
        }
        for (auto &p : clank) if (p.mag > 0.f && p.energy() < 1e-10f) p.mag = 0;
        if (thunk.mag > 0.f && thunk.energy() < 1e-10f) thunk.mag = 0;
    }
};

// ---------------------------------------------------------------- Cattle grid: a far truck drumming over the bars
/// Rare (every 90–240 s): a vehicle on the far road comes up, crosses the cattle grid at the fence line and goes on: a
/// semi-trailer (five axles) or a ute (two), each axle drumming over the bars at its speed (bars 0.2 m apart, so 70–110
/// strikes a second at 50–80 km/h) through the rails' ring (340–870 Hz) and the pit's boom (95 Hz), under the engine's
/// far drone; it crosses the view from one side to the other, low-passed by the distance.
class CattleGrid final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kAxles = 5;
    bool on = false;
    int axles = 5;
    float t = 0, dur = 18, cross = 8, until = 60, v = 18, barPh = 0, engPh = 0, engHz = 32, panFrom = -0.6f, panTo = 0.6f;
    float axleAt[kAxles] = {}, axleLoad[kAxles] = {};
    SVF rail[3], pit, engLP, engHP, farL, farR;
    Pink pink;

    float interval(const AmbienceContext &c) { return (90.f + 150.f * rng.uniform()) / c.density; }

public:
    explicit CattleGrid(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.5f; }
    void triggerNow(const AmbienceContext &c) override {
        const float fsr = c.sr;
        on = true; t = 0; dur = 16.f + 6.f * rng.uniform(); cross = dur * (0.42f + 0.1f * rng.uniform());
        v = (50.f + 30.f * rng.uniform()) / 3.6f;
        const bool truck = rng.uniform() < 0.7f;
        static constexpr float kSemi[kAxles] = {0.f, 4.6f, 5.9f, 12.5f, 13.8f}, kSemiLoad[kAxles] = {0.6f, 1.f, 1.f, 0.9f, 0.9f};
        axles = truck ? 5 : 2;
        for (int i = 0; i < axles; ++i) {
            axleAt[i] = cross + (truck ? kSemi[i] : 2.7f * (float)i) / v;
            axleLoad[i] = truck ? kSemiLoad[i] * (0.85f + 0.3f * rng.uniform()) : 0.6f;
        }
        const float k = 0.95f + 0.1f * rng.uniform();
        rail[0].set(340.f * k, 9.f, fsr); rail[1].set(560.f * k, 9.f, fsr); rail[2].set(870.f * k, 9.f, fsr);
        pit.set(95.f, 3.f, fsr);
        engHz = truck ? 28.f + 10.f * rng.uniform() : 40.f + 15.f * rng.uniform();
        engLP.set(500.f, 0.7f, fsr); engHP.set(45.f, 0.7f, fsr); farL.set(1600.f, 0.7f, fsr); farR.set(1650.f, 0.7f, fsr);
        const float side = rng.uniform() < 0.5f ? -1.f : 1.f;
        panFrom = side * (0.5f + 0.3f * rng.uniform()); panTo = -side * (0.5f + 0.3f * rng.uniform());
        barPh = 0;
        ++events;
        until = interval(c);
    }
    void wake(const AmbienceContext &c) override { on = false; until = interval(c) * (0.05f + 0.25f * rng.uniform()); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (!on) {
            if ((until -= dt) > 0) return;
            triggerNow(c);
        }
        const float onGrid = 2.4f / v, barHz = v / 0.2f;
        float pl, pr;
        panGains(panFrom + (panTo - panFrom) * std::min(1.f, t / dur), pl, pr);
        const float x = (t - cross) / (0.2f * dur), engine = 0.12f * std::exp(-x * x);
        for (int i = 0; i < n; ++i) {
            float kick = 0;
            barPh += barHz * invSr;
            if (barPh >= 1.f) {
                barPh -= 1.f;
                for (int k = 0; k < axles; ++k) {
                    const float u = (t - axleAt[k]) / onGrid;
                    // Each bar is one sample's strike: a resonance of unity peak gain rings to about 2πf/(Q·sr) of it.
                    if (u > 0.f && u < 1.f) kick += 100.f * axleLoad[k] * std::sqrt(std::sin(kPi * u)) * (0.75f + 0.5f * rng.uniform());
                }
            }
            const float grid = 0.5f * (rail[0].band(kick) + 0.8f * rail[1].band(kick) + 0.5f * rail[2].band(kick)) + 1.2f * pit.band(kick);
            advanceTone(engPh, engHz * invSr);
            // Far off, the engine is its upper harmonics and the tyres; its firing note is gone in the distance.
            const float eng = engine * engHP.high(engLP.low(0.3f * sin2pi(engPh) + 0.5f * sin2pi(2.f * engPh) + 0.4f * sin2pi(3.f * engPh)
                                                            + 0.25f * sin2pi(4.f * engPh) + 0.5f * pink.next(rng.bipolar())));
            const float y = grid + eng;
            l[i] += farL.low(y * pl); r[i] += farR.low(y * pr);
            t += invSr;
        }
        if (t > dur) on = false;
    }
};

// ---------------------------------------------------------------- Dust ticks: grit on the wind against wire and tin
/// Grains of grit blown against the fence wire and the tank: soft clicks of a fraction of a millisecond (3–9 kHz,
/// Pareto amplitudes, anywhere across the field), in clusters with the gusts, more of them the higher the level (the
/// wind); now and then the tank ticks as it cools.
class DustTicks final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kVoices = 10;
    Burst voices[kVoices];
    Partial tink[2];
    Wander gust;
    int next = 0;
    float toTick = 1, toTink = 10, tinkGl = 0.7f, tinkGr = 0.7f;

    float tinkInterval(const AmbienceContext &c) { return (10.f + 20.f * rng.uniform()) / c.density; }

public:
    explicit DustTicks(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.25f; }
    void wake(const AmbienceContext &c) override { toTick = expRand(rng); toTink = tinkInterval(c) * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        const float g = gust.next(rng, dt, 1.2f);
        const float perSecond = (30.f + 260.f * level) * c.density * (0.25f + 1.5f * g * g);
        toTick -= perSecond * dt;
        for (int k = 0; k < 4 && toTick <= 0.f; ++k) {
            voices[next].start(3000.f * std::exp2(1.585f * rng.uniform()), 2.5f, 0.0003f + 0.0005f * rng.uniform(),
                               0.5f * pareto(rng, 2.5f, 3.f), 0.9f * rng.bipolar(), fsr);
            next = (next + 1) % kVoices;
            toTick += expRand(rng);
            if (events < 0x7fffffff) ++events;
        }
        if ((toTink -= dt) <= 0) {
            const float f = 1900.f + 1500.f * rng.uniform();
            tink[0].startSine(f, 0.08f + 0.08f * rng.uniform(), 0.35f, fsr); tink[1].startSine(f * 2.76f, 0.05f, 0.12f, fsr);
            panGains(-0.45f + 0.1f * rng.bipolar(), tinkGl, tinkGr);   // the tank, by the windmill
            toTink = tinkInterval(c);
        }
        for (int i = 0; i < n; ++i) {
            float yl = 0, yr = 0;
            for (auto &v : voices) if (v.on()) { const float x = v.next(rng); yl += x * v.gl; yr += x * v.gr; }
            if (tink[0].mag > 0.f) { const float x = tink[0].next() + tink[1].next(); yl += x * tinkGl; yr += x * tinkGr; }
            l[i] += yl; r[i] += yr;
        }
        if (tink[0].mag > 0.f && tink[0].energy() < 1e-10f) tink[0].mag = tink[1].mag = 0;
    }
};

// ---------------------------------------------------------------- Heat shimmer: a faint high hum in the hot air
/// A faint hum on the key's tonic in A5–G♯6 with its fifth and octave above, each a pair a fraction of a hertz apart so
/// it beats slowly, its level flickering in each ear as the hot air shimmers; the world fades it with the day's heat
/// (by dusk it is gone). A new key glides in over about two seconds; all dry, so it never leaves the key.
class ShimmerHum final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kRatio[3] = {1.f, 1.5f, 2.f}, kAmp[3] = {1.f, 0.42f, 0.18f};
    float ph[3][2] = {}, det[3][2] = {}, hz = 0, fl = 0.8f, fr = 0.8f;
    Wander flutterL, flutterR;

public:
    explicit ShimmerHum(uint64_t seed) : rng(seed) {
        direct = 1.f; send = 0.f;
        for (auto &d : det) { d[0] = -(0.25f + 0.45f * rng.uniform()); d[1] = 0.25f + 0.45f * rng.uniform(); }
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        glidePitch(hz, shimmerHz(c.keyRoot), dt, 2.f);
        float inc[3][2];
        for (int k = 0; k < 3; ++k) for (int j = 0; j < 2; ++j) inc[k][j] = (hz * kRatio[k] + det[k][j]) * invSr;
        const float l1 = 0.6f + 0.4f * flutterL.next(rng, dt, 0.35f), r1 = 0.6f + 0.4f * flutterR.next(rng, dt, 0.45f);
        const float dl = (l1 - fl) / (float)n, dr = (r1 - fr) / (float)n;
        for (int i = 0; i < n; ++i) {
            fl += dl; fr += dr;
            float s = 0;
            for (int k = 0; k < 3; ++k)
                for (int j = 0; j < 2; ++j) { s += kAmp[k] * sin2pi(ph[k][j]); advanceTone(ph[k][j], inc[k][j]); }
            l[i] += s * fl; r[i] += s * fr;
        }
    }
};

// ---------------------------------------------------------------- A far truck on the highway
/// A road train on a highway a few kilometres off, every 50–140 s: its diesel (a firing note of 28–42 Hz and its
/// harmonics, under a tyre roar) swells over 30–60 s as it comes along the road and fades as it goes, crossing from one
/// side to the other, a little brighter at its closest and falling 2.4% in pitch as it passes (the doppler), with a gear
/// change or two on the way. Low-passed by the distance; in no key.
class FarTruck final : public AmbienceSource {
    FastRandom rng;
    static constexpr float kHarm[6] = {1.f, 0.75f, 0.5f, 0.4f, 0.22f, 0.15f};
    Pink pink;
    SVF tyres, lowCut, farL, farR;
    bool on = false;
    int shifts = 0;
    float t = 0, dur = 40, until = 30, ph = 0, base = 34, panFrom = -0.7f, panTo = 0.7f, shiftAt[2] = {-1, -1};
    float farApplied = -1;

    float interval(const AmbienceContext &c) { return (50.f + 90.f * rng.uniform()) / c.density; }

public:
    FarTruck(uint64_t seed, float sr) : rng(seed) { direct = 1.f; send = 0.4f; tyres.set(600.f, 0.7f, sr); lowCut.set(40.f, 0.7f, sr); }
    void triggerNow(const AmbienceContext &c) override {
        on = true; t = 0; dur = 30.f + 30.f * rng.uniform(); base = 28.f + 14.f * rng.uniform(); ph = 0;
        shifts = rng.uniform() < 0.6f ? 2 : 1;
        shiftAt[0] = dur * (0.15f + 0.2f * rng.uniform()); shiftAt[1] = shifts > 1 ? dur * (0.6f + 0.2f * rng.uniform()) : -1.f;
        const float side = rng.uniform() < 0.5f ? -1.f : 1.f;
        panFrom = side * (0.6f + 0.25f * rng.uniform()); panTo = -side * (0.6f + 0.25f * rng.uniform());
        ++events;
        until = interval(c);
    }
    void wake(const AmbienceContext &c) override { on = false; until = interval(c) * (0.05f + 0.3f * rng.uniform()); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (!on) {
            if ((until -= dt) > 0) return;
            triggerNow(c);
        }
        const float x = t / dur, near = std::exp(-((x - 0.5f) / 0.22f) * ((x - 0.5f) / 0.22f));
        // A gear change: the revs fall by a third and climb back over 4 s, the note dropping out for the clutch.
        float rev = 1.f, clutch = 1.f;
        for (int k = 0; k < 2; ++k) {
            const float u = t - shiftAt[k];
            if (shiftAt[k] < 0 || u < 0 || u > 4.4f) continue;
            if (u < 0.4f) clutch = std::min(clutch, 0.35f + 0.65f * std::fabs(1.f - u / 0.2f));
            else rev = std::min(rev, 0.7f + 0.3f * (u - 0.4f) / 4.f);
        }
        const float doppler = 1.f + 0.012f * std::tanh(6.f * (0.5f - x)), f = base * rev * doppler;
        const float cut = 300.f + 600.f * near;
        if (std::fabs(cut - farApplied) > 2.f) { farApplied = cut; farL.set(cut, 0.7f, fsr); farR.set(cut * 1.05f, 0.7f, fsr); }
        float pl, pr;
        panGains(panFrom + (panTo - panFrom) * x, pl, pr);
        const float amp = near, inc = f * invSr;
        for (int i = 0; i < n; ++i) {
            advanceTone(ph, inc);
            // The harmonics by the Chebyshev recurrence: sin((k + 1)x) = 2cos(x)·sin(kx) − sin((k − 1)x).
            const float s1 = sin2pi(ph), c2 = 2.f * sin2pi(ph + 0.25f);
            float prev = 0.f, cur = s1, tone = kHarm[0] * s1;
            for (int k = 1; k < 6; ++k) { const float next = c2 * cur - prev; prev = cur; cur = next; tone += kHarm[k] * cur; }
            const float y = amp * lowCut.high(0.35f * clutch * tone + 0.8f * tyres.low(pink.next(rng.bipolar())));
            l[i] += farL.low(y * pl); r[i] += farR.low(y * pr);
        }
        t += dt;
        if (t > dur) on = false;
    }
};

// ================================================================ Fire & Neon (Sets 13 & 14): the volcano and drive families

/// A smooth bump: 0 outside 0…1, sin² inside.
inline float bump(float x) { if (x <= 0.f || x >= 1.f) return 0.f; const float s = std::sin(kPi * x); return s * s; }

// ---------------------------------------------------------------- Vent rumble: the lake's deep roar, felt more than heard
/// Brown noise under a 4-pole low-pass at 42–72 Hz and a 4-pole high-pass at 18 Hz (nothing a speaker can't play), mostly
/// the same in both ears with a little of each side's own; its level wanders slowly (7 s and 17 s), so it never repeats,
/// and now and then a deep chuff swells it over 3–8 s as gas pistons up through the lake. It surges with the lake (the
/// world's `lakeSurge`): louder, a little higher, chuffing more often. A faint growl round 95 Hz lets it be sensed on small
/// speakers. Unpitched (so in no key), mostly direct.
class VentRumble final : public AmbienceSource {
    FastRandom rng;
    Brown common, sideL, sideR;
    Pink pink;
    SVF lowA[2], lowB[2], cutA[2], cutB[2], growl;
    Wander slow, slower;
    struct Chuff { bool on = false; float t = 0, dur = 5, amp = 0.5f; } chuffs[2];
    float toChuff = 8, surge = 0.3f, a = 0.6f, g = 0.05f, cutApplied = -1;

    float interval(const AmbienceContext &c) { return (8.f + 16.f * rng.uniform()) / (c.density * (0.6f + 0.8f * surge)); }

public:
    VentRumble(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.1f;
        for (int k = 0; k < 2; ++k) { cutA[k].set(18.f, 0.5412f, sr); cutB[k].set(18.f, 1.3066f, sr); }   // 4-pole Butterworth
        growl.set(95.f, 0.8f, sr);
    }
    void wake(const AmbienceContext &c) override {
        surge = c.lakeSurge;
        for (auto &q : chuffs) q.on = false;
        toChuff = 2.f + 6.f * rng.uniform();
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        surge += (c.lakeSurge - surge) * (1.f - std::exp(-dt / 1.2f));
        if ((toChuff -= dt) <= 0) {
            for (auto &q : chuffs) if (!q.on) { q = {true, 0.f, 3.f + 5.f * rng.uniform(), 0.35f + 0.5f * rng.uniform()}; break; }
            toChuff = interval(c);
            if (events < 0x7fffffff) ++events;
        }
        float chuff = 0;
        for (auto &q : chuffs) {
            if (!q.on) continue;
            q.t += dt;
            if (q.t >= q.dur) { q.on = false; continue; }
            chuff += q.amp * bump(q.t / q.dur);
        }
        chuff = std::min(1.f, chuff);
        const float cut = 42.f + 20.f * surge + 10.f * chuff;
        if (std::fabs(cut - cutApplied) > 0.5f) {
            cutApplied = cut;
            for (int k = 0; k < 2; ++k) { lowA[k].set(cut, 0.5412f, fsr); lowB[k].set(cut, 1.3066f, fsr); }
        }
        const float a1 = (0.5f + 0.5f * surge) * (0.75f + 0.25f * slow.next(rng, dt, 7.f)) * (0.85f + 0.3f * slower.next(rng, dt, 17.f))
                         * (1.f + 0.6f * chuff);
        const float g1 = 0.4f + 0.6f * surge + 0.8f * chuff;
        const float inv = 1.f / (float)n, da = (a1 - a) * inv, dg = (g1 - g) * inv;
        for (int t = 0; t < n; ++t) {
            a += da; g += dg;
            const float m = common.next(rng.bipolar());
            const float xl = m + 0.45f * sideL.next(rng.bipolar()), xr = m + 0.45f * sideR.next(rng.bipolar());
            const float yl = cutB[0].high(cutA[0].high(lowB[0].low(lowA[0].low(xl))));
            const float yr = cutB[1].high(cutA[1].high(lowB[1].low(lowA[1].low(xr))));
            const float gr = 0.05f * g * growl.band(pink.next(rng.bipolar()));
            l[t] += a * (yl + gr);
            r[t] += a * (yr + gr);
        }
    }
};

// ---------------------------------------------------------------- Lava hiss: a lava lake's own voice
/// The convection's soft roar (pink noise round 380–900 Hz, churning slowly, over a low body) and on it the crust: sparse
/// crackles in little clusters as it cracks (grains of 0.6–2.5 ms at 1.5–6 kHz, Pareto loud, about 2–9 a second), glassy
/// tinkles of cooling crust (a pair of inharmonic partials at 3–7 kHz ringing 20–60 ms), and every 5–15 s a gas burst: a
/// viscous "blorp" (a 70–130 Hz bubble rising half again as it opens, over a puff of gas) with its spatter falling back
/// after it. The lake's glow (`lakeGlow`) brightens it all: the roar opens, the top lifts, it cracks and tinkles more.
/// Never a frying hiss: the grains are few, and the bed is the roar, not white noise.
class LavaHiss final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkB;
    SVF roarL, roarR, body, topL, topR;
    Wander churn, swirl;
    static constexpr int kCrackles = 14, kTinks = 4, kBlorps = 2;
    Burst crackles[kCrackles];
    struct Tink { Partial a, b; float gl = 0.7f, gr = 0.7f; } tinks[kTinks];
    struct Blorp { Ping bubble; Burst puff; int spatter = 0; float toSpatter = 0, pan = 0; } blorps[kBlorps];
    int nextCrackle = 0, nextTink = 0, nextBlorp = 0, cluster = 0;
    float toCrack = 0.5f, toCluster = 0, clusterPan = 0, toTink = 2, toBlorp = 6, glow = 0.3f, a = 0.8f, topApplied = -1, roarApplied = -1;

    void crackle(float sr, float pan, float lo, float hi, float scale) {
        crackles[nextCrackle].start(lo * std::pow(hi / lo, rng.uniform()), 1.2f, 0.0006f + 0.0019f * rng.uniform(),
                                    scale * 0.9f * pareto(rng, 2.2f, 4.f), pan, sr);
        nextCrackle = (nextCrackle + 1) % kCrackles;
        if (events < 0x7fffffff) ++events;
    }

public:
    LavaHiss(uint64_t seed, float sr) : rng(seed) { direct = 1.f; send = 0.35f; body.set(170.f, 0.6f, sr); }
    void wake(const AmbienceContext &c) override {
        glow = c.lakeGlow; toCrack = expRand(rng) * 0.5f; toTink = 1.f + 2.f * rng.uniform(); toBlorp = 3.f + 6.f * rng.uniform(); cluster = 0;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        glow += (c.lakeGlow - glow) * (1.f - std::exp(-dt / 0.6f));
        const float centre = 380.f + 520.f * glow;
        if (std::fabs(centre - roarApplied) > 4.f) { roarApplied = centre; roarL.set(centre, 0.55f, fsr); roarR.set(centre * 1.08f, 0.55f, fsr); }
        const float top = 2600.f + 4400.f * glow;
        if (std::fabs(top - topApplied) > 20.f) { topApplied = top; topL.set(top, 0.7f, fsr); topR.set(top * 1.04f, 0.7f, fsr); }
        // The crust cracking: clusters of 1–5 grains a few milliseconds apart, anywhere across the lake.
        if ((toCrack -= (0.6f + 2.4f * glow) * c.density * dt) <= 0.f) {
            cluster = 1 + (int)(rng.uniform() * 4.99f); toCluster = 0; clusterPan = 0.85f * rng.bipolar();
            toCrack = expRand(rng);
        }
        while (cluster > 0 && (toCluster -= dt) <= 0.f) {
            crackle(fsr, std::clamp(clusterPan + 0.12f * rng.bipolar(), -1.f, 1.f), 1500.f, 6000.f, 0.6f + 0.6f * glow);
            --cluster; toCluster = 0.004f + 0.022f * rng.uniform();
        }
        // Glassy crust tinkling as it cools.
        if ((toTink -= (0.15f + 0.6f * glow) * c.density * dt) <= 0.f) {
            Tink &k = tinks[nextTink]; nextTink = (nextTink + 1) % kTinks;
            const float f = 3000.f * std::pow(7.f / 3.f, rng.uniform()), amp = 0.05f + 0.07f * rng.uniform();
            k.a.startSine(f, 0.02f + 0.04f * rng.uniform(), amp, fsr); k.b.startSine(f * (2.4f + 0.5f * rng.uniform()), 0.015f, 0.4f * amp, fsr);
            panGains(0.8f * rng.bipolar(), k.gl, k.gr);
            toTink = expRand(rng);
        }
        // A gas burst: a viscous bubble opening, a puff of gas, spatter falling back.
        if ((toBlorp -= dt * (1.f + glow) * c.density) <= 0.f) {
            Blorp &b = blorps[nextBlorp]; nextBlorp = (nextBlorp + 1) % kBlorps;
            b.pan = 0.7f * rng.bipolar();
            b.bubble.start(70.f + 60.f * rng.uniform(), 0.18f + 0.12f * rng.uniform(), 0.35f + 0.25f * rng.uniform(), b.pan, fsr, 0.5f, 0.05f);
            b.puff.start(450.f + 450.f * rng.uniform(), 0.8f, 0.04f + 0.05f * rng.uniform(), 0.9f, b.pan, fsr);
            b.spatter = 3 + (int)(rng.uniform() * 5.99f); b.toSpatter = 0.08f + 0.1f * rng.uniform();
            toBlorp = 5.f + 10.f * rng.uniform();
        }
        for (auto &b : blorps) {
            while (b.spatter > 0 && (b.toSpatter -= dt) <= 0.f) {
                crackle(fsr, std::clamp(b.pan + 0.3f * rng.bipolar(), -1.f, 1.f), 800.f, 2500.f, 0.8f);
                --b.spatter; b.toSpatter = 0.02f + 0.08f * rng.uniform();
            }
        }
        const float a1 = (0.7f + 0.3f * churn.next(rng, dt, 2.5f)) * (0.88f + 0.12f * swirl.next(rng, dt, 0.6f)) * (0.85f + 0.3f * glow);
        const float da = (a1 - a) / (float)n;
        for (int t = 0; t < n; ++t) {
            a += da;
            const float bd = 0.45f * body.band(pinkB.next(rng.bipolar()));
            float yl = a * (roarL.band(pinkL.next(rng.bipolar())) + bd), yr = a * (roarR.band(pinkR.next(rng.bipolar())) + bd);
            for (auto &k : crackles) if (k.on()) { const float x = k.next(rng); yl += x * k.gl; yr += x * k.gr; }
            for (auto &k : tinks) if (k.a.mag > 0.f) { const float x = k.a.next() + k.b.next(); yl += x * k.gl; yr += x * k.gr; }
            for (auto &b : blorps) {
                if (b.bubble.on()) { const float x = b.bubble.next(); yl += x * b.bubble.gl; yr += x * b.bubble.gr; }
                if (b.puff.on()) { const float x = b.puff.next(rng); yl += x * b.puff.gl; yr += x * b.puff.gr; }
            }
            l[t] += topL.low(yl); r[t] += topR.low(yr);
        }
        for (auto &k : tinks) if (k.a.mag > 0.f && k.a.energy() < 1e-10f) k.a.mag = k.b.mag = 0.f;
    }
};

// ---------------------------------------------------------------- Steam vent: a fumarole's jet
/// A jet of steam from a vent in the crater wall: it builds (0.3–1 s), roars (turbulent band-passed noise whose centre
/// climbs from 1.1 to 2.8 kHz with the pressure, a hiss over it, a body under the big ones, all of it spluttering as the
/// flow breaks up) and fades; a little whistle rides it (a narrow band of the jet's own noise, rising with the pressure).
/// Small far ones by themselves every 8–30 s; the world's steam blast (an event) is a big one of about 6 s. The distance
/// darkens it, and each sits where its vent is.
class SteamVent final : public AmbienceSource {
    FastRandom rng;
    struct Jet {
        bool on = false;
        float t = 0, build = 0.6f, hold = 1.5f, fade = 1.5f, amp = 1, body = 0, pitch = 1, gl = 0.7f, gr = 0.7f;
        float fadeGain = 1, fadeStep = 0, turb = 1, centreApplied = -1;
        SVF jetL, jetR, hiss, whistle, roar, farL, farR;
        Pink pink;
        Wander gust, splutter;
    } jets[3];
    float toJet = 10;

    void start(float strength, float pan, float far, bool blast, float sr) {
        Jet *j = nullptr;
        for (auto &x : jets) if (!x.on) { j = &x; break; }
        if (!j) { j = &jets[0]; for (auto &x : jets) if (x.t > j->t) j = &x; }
        const float s = clamp01(strength), d = clamp01(far);
        j->on = true; j->t = 0; j->fadeGain = 1; j->fadeStep = 0; j->centreApplied = -1;
        if (blast) {
            j->build = 0.5f + 0.5f * rng.uniform(); j->hold = 2.f + 1.5f * s; j->fade = 1.8f + 1.2f * rng.uniform();
            j->amp = 0.45f + 0.55f * s; j->body = 0.12f * s;
            toJet = std::max(toJet, j->build + j->hold + j->fade + 4.f);   // the vent has just vented: its own small jets wait
        } else {
            j->build = 0.3f + 0.5f * rng.uniform(); j->hold = 0.5f + 1.5f * rng.uniform(); j->fade = 0.8f + 1.2f * rng.uniform();
            j->amp = 0.2f + 0.3f * s; j->body = 0.f;
        }
        j->amp *= 1.f - 0.55f * d;
        j->pitch = 0.85f + 0.3f * rng.uniform();
        panGains(std::clamp(pan, -1.f, 1.f), j->gl, j->gr);
        j->hiss.clear(); j->hiss.set(6500.f, 0.7f, sr); j->roar.clear(); j->roar.set(260.f * j->pitch, 0.7f, sr);
        const float cut = 9000.f * std::exp2(-1.8f * d);
        j->farL.clear(); j->farR.clear(); j->farL.set(cut, 0.7f, sr); j->farR.set(cut * 1.05f, 0.7f, sr);
        j->jetL.clear(); j->jetR.clear(); j->whistle.clear();
        if (events < 0x7fffffff) ++events;
    }
    float interval(const AmbienceContext &c) { return (8.f + 22.f * rng.uniform()) / c.density; }

public:
    explicit SteamVent(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.35f; }
    void wake(const AmbienceContext &c) override { for (auto &j : jets) j.on = false; toJet = interval(c) * (0.1f + 0.4f * rng.uniform()); }
    void triggerNow(const AmbienceContext &c) override { start(0.8f, 0.5f * rng.bipolar(), 0.3f, true, c.sr); }
    void event(const AmbienceEvent &e, float, const AmbienceContext &c) override { start(e.strength, e.pan, e.distance, true, c.sr); }
    void silence(float sr) override { for (auto &j : jets) if (j.on) j.fadeStep = 1.f / (0.04f * sr); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        if ((toJet -= dt) <= 0.f) {
            start(0.3f + 0.6f * rng.uniform(), 0.85f * rng.bipolar(), 0.45f + 0.5f * rng.uniform(), false, fsr);
            toJet = interval(c);
        }
        for (auto &j : jets) {
            if (!j.on) continue;
            // The pressure: up (a little faster than linear), holding with its gusts, then down.
            float p;
            if (j.t < j.build) { const float x = j.t / j.build; p = x * std::sqrt(x); }
            else if (j.t < j.build + j.hold) p = 0.82f + 0.18f * j.gust.next(rng, dt, 0.7f);
            else { const float x = (j.t - j.build - j.hold) / j.fade; const float cx = std::cos(0.5f * kPi * std::min(1.f, x)); p = 0.9f * cx * cx; }
            const float centre = (1100.f + 1700.f * p) * j.pitch;
            if (std::fabs(centre - j.centreApplied) > 8.f) {
                j.centreApplied = centre;
                j.jetL.set(centre, 0.9f, fsr); j.jetR.set(centre * 1.06f, 0.9f, fsr); j.whistle.set((2500.f + 900.f * p) * j.pitch, 30.f, fsr);
            }
            const float turb1 = 0.75f + 0.5f * j.splutter.next(rng, dt, 0.05f), dturb = (turb1 - j.turb) / (float)n;
            const float e0 = j.amp * p, h = 0.4f * p, w = 0.9f * p, b = j.body * p;
            for (int i = 0; i < n; ++i) {
                j.turb += dturb;
                const float e = e0 * j.turb * j.fadeGain;
                const float wl = rng.bipolar(), wr = rng.bipolar(), wm = rng.bipolar();
                const float common = h * j.hiss.band(wm) + w * j.whistle.band(wm) + b * j.roar.band(4.f * j.pink.next(wm));
                l[i] += j.farL.low(e * (j.jetL.band(wl) + common) * j.gl);
                r[i] += j.farR.low(e * (j.jetR.band(wr) + common) * j.gr);
                if (j.fadeStep > 0.f && (j.fadeGain -= j.fadeStep) <= 0.f) { j.on = false; break; }
            }
            j.t += dt;
            if (j.t > j.build + j.hold + j.fade + 0.05f) j.on = false;
        }
    }
};

// ---------------------------------------------------------------- Rockfall: rocks bouncing down the crater wall
/// A fall of rocks of every size down the inner wall: each rock bounces down the scree (its bounces coming quicker and
/// softer as it loses itself, so the fall slows to rest), every impact a click whose pitch is the stone's size (big
/// ones lower, with a thud; small hard ones with a short ring of the stone's own modes), farther away and darker the
/// lower it goes; then the dust: a trickle of grit and a sliding hiss dying away. A small far one by itself every
/// 45–150 s; the world's rockfall (an event) a big one, where on the wall it is (its pan) and how far (its distance).
class Rockfall final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kPlan = 256, kVoices = 24, kGrit = 8;
    struct Hit { float at = 0, amp = 0, size = 0, pan = 0, dark = 0; };
    Hit plan[kPlan];
    int planCount = 0, planNext = 0;
    struct Voice { Burst click; Partial thud, ring, ring2; SVF dark; float gl = 0.7f, gr = 0.7f, amp = 0; bool on = false; } voices[kVoices];
    Burst grit[kGrit];
    SVF slide, slideDark;
    int nextVoice = 0, nextGrit = 0;
    float t = -1, end = 0, trickleFrom = 0.6f, trickleDur = 3, trickleAmp = 0, far = 0, toGrit = 0, toFall = 60, fade = 1, fadeStep = 0;
    float slidePan = 0, slideCutApplied = -1;

    void fall(float strength, float pan, float distance, float sr) {
        const float s = clamp01(strength);
        far = clamp01(distance);
        planCount = 0; planNext = 0; t = 0; fade = 1; fadeStep = 0;
        const int bigs = 3 + (int)std::lround(4.f * s), rocks = bigs + 8 + (int)std::lround(22.f * s);
        float last = 0;
        for (int k = 0; k < rocks && planCount < kPlan; ++k) {
            // All of them break away together; the big ones bounce on down the wall (long, slowly settling trains),
            // the small ones settle on the scree after a few bounces.
            const bool big = k < bigs;
            const float size = big ? 0.45f + 0.55f * rng.uniform() : 0.08f + 0.3f * rng.uniform();
            float at = 0.6f * rng.uniform() * rng.uniform() + (big ? 0.f : 0.1f * rng.uniform());
            float gap = big ? 0.3f + 0.25f * rng.uniform() : 0.12f + 0.12f * rng.uniform();
            float amp = size * (0.6f + 0.4f * rng.uniform()) * (0.5f + 0.5f * s);
            const float ratio = big ? 0.86f + 0.07f * rng.uniform() : 0.7f + 0.1f * rng.uniform();
            const float loss = big ? 0.78f + 0.08f * rng.uniform() : 0.6f + 0.12f * rng.uniform();
            const int bounces = big ? 7 + (int)(rng.uniform() * 3.99f) : 2 + (int)(rng.uniform() * 3.99f);
            const float p0 = std::clamp(pan + 0.25f * rng.bipolar(), -1.f, 1.f), drift = 0.2f * rng.bipolar();
            for (int b = 0; b < bounces && amp > 0.02f && planCount < kPlan; ++b) {
                Hit &h = plan[planCount++];
                h.at = at; h.amp = amp; h.size = size * (0.9f + 0.2f * rng.uniform());
                h.pan = std::clamp(p0 + drift * (float)b / 8.f, -1.f, 1.f);
                h.dark = clamp01(far + 0.45f * at);   // farther down the wall: farther from you, darker
                last = std::max(last, at);
                at += gap * (0.75f + 0.5f * rng.uniform());
                gap *= ratio; amp *= loss;
            }
        }
        std::sort(plan, plan + planCount, [](const Hit &x, const Hit &y) { return x.at < y.at; });
        trickleFrom = 0.4f + 0.4f * rng.uniform(); trickleDur = 2.f + 2.5f * s; trickleAmp = 0.5f + 0.5f * s;
        end = std::max(last + 0.6f, trickleFrom + trickleDur) + 0.3f;
        slidePan = std::clamp(pan, -1.f, 1.f);
        slide.clear(); slide.set(2200.f, 0.7f, sr); slideDark.clear(); slideCutApplied = -1;
        toGrit = 0;
    }
    void strike(const Hit &h, float sr) {
        Voice &v = voices[nextVoice]; nextVoice = (nextVoice + 1) % kVoices;
        const float big = h.size, near = 1.f - 0.7f * h.dark;
        v.on = true; v.amp = h.amp * near;
        v.click.start((900.f + 2600.f * (1.f - big) * (0.8f + 0.4f * rng.uniform())) * (1.f - 0.6f * h.dark), 0.8f, 0.001f + 0.006f * big, 1.f, 0.f, sr);
        // A dull, short thump under a big one (scree gives under it: no drum's ring); the clack of the stone's own modes,
        // lower the bigger it is, is what carries across the crater, and softer as the rocks slow on the scree below.
        v.thud.startSine(50.f + 80.f * (1.f - big), 0.04f + 0.05f * big, 0.3f * big, sr);
        const float f = (500.f + 900.f * rng.uniform()) * (1.3f - 0.6f * big), clack = 1.f - 0.5f * std::min(1.f, h.dark);
        v.ring.startSine(f, 0.03f + 0.04f * rng.uniform(), 0.6f * clack, sr);
        v.ring2.startSine(f * (2.2f + 0.7f * rng.uniform()), 0.015f, 0.26f * clack, sr);
        v.dark.clear(); v.dark.set(6500.f * std::exp2(-3.f * h.dark), 0.7f, sr);
        panGains(h.pan, v.gl, v.gr);
        if (events < 0x7fffffff) ++events;
    }
    float interval(const AmbienceContext &c) { return (45.f + 105.f * rng.uniform()) / c.density; }

public:
    explicit Rockfall(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.45f; }
    void wake(const AmbienceContext &c) override { t = -1; toFall = interval(c) * (0.1f + 0.5f * rng.uniform()); }
    void triggerNow(const AmbienceContext &c) override { fall(0.8f, 0.5f * rng.bipolar(), 0.3f, c.sr); }
    void event(const AmbienceEvent &e, float, const AmbienceContext &c) override { fall(e.strength, e.pan, e.distance, c.sr); }
    void silence(float sr) override { if (t >= 0) fadeStep = 1.f / (0.04f * sr); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        if (t < 0) {
            if ((toFall -= dt) > 0.f) return;
            fall(0.2f + 0.25f * rng.uniform(), 0.9f * rng.bipolar(), 0.5f + 0.4f * rng.uniform(), fsr);
            toFall = interval(c);
        }
        const float t1 = t + dt;
        while (planNext < planCount && plan[planNext].at < t1) strike(plan[planNext++], fsr);
        // The dust: a trickle of grit and a sliding hiss, rising over 0.3 s and dying away.
        const float u = (t - trickleFrom) / trickleDur;
        const float dust = u > 0.f && u < 1.f ? trickleAmp * std::min(1.f, u * trickleDur / 0.3f) * std::exp(-3.f * u) * (1.f - u) : 0.f;
        const float cut = 5000.f * std::exp2(-2.f * clamp01(far + 0.45f * t));
        if (std::fabs(cut - slideCutApplied) > 20.f) { slideCutApplied = cut; slideDark.set(cut, 0.7f, fsr); }
        if (dust > 0.f) {
            toGrit -= 140.f * dust * dt;
            for (int k = 0; k < 3 && toGrit <= 0.f; ++k) {
                grit[nextGrit].start(2000.f * std::exp2(1.6f * rng.uniform()), 1.5f, 0.0002f + 0.0004f * rng.uniform(),
                                     0.35f * pareto(rng, 2.5f, 3.f), std::clamp(slidePan + 0.3f * rng.bipolar(), -1.f, 1.f), fsr);
                nextGrit = (nextGrit + 1) % kGrit;
                toGrit += expRand(rng);
            }
        }
        float sl, sr2; panGains(slidePan, sl, sr2);
        const float sh = 0.08f * dust * (1.f - 0.5f * far);
        for (int i = 0; i < n; ++i) {
            float yl = 0, yr = 0;
            for (auto &v : voices) {
                if (!v.on) continue;
                const float x = v.dark.low(v.amp * (v.click.next(rng) + v.thud.next() + v.ring.next() + v.ring2.next()));
                yl += x * v.gl; yr += x * v.gr;
            }
            float g = 0;
            for (auto &k : grit) if (k.on()) g += k.next(rng);
            const float s = slideDark.low(sh * slide.band(rng.bipolar()) + 0.4f * g);
            yl += s * sl; yr += s * sr2;
            l[i] += fade * yl; r[i] += fade * yr;
            if (fadeStep > 0.f && (fade -= fadeStep) <= 0.f) { fade = 0.f; break; }
        }
        for (auto &v : voices) if (v.on && !v.click.on() && v.thud.energy() < 1e-9f && v.ring.energy() < 1e-9f) v.on = false;
        t = t1;
        if (t > end || fade <= 0.f) { t = -1; fadeStep = 0; fade = 1; for (auto &v : voices) v.on = false; for (auto &k : grit) k = Burst(); }
    }
};

// ---------------------------------------------------------------- Eruption boom: the blast, its echoes, its tail
/// The eruption (an event): a deep blast (a 30–40 Hz pressure pulse of a few cycles and a low rumble of the air under it,
/// with a punch near 70 Hz for small speakers), the vent's crack on top, then the column's roar and a long crackling tail
/// of spatter thinning out, and bombs landing on the far rim 2–7 s on (dull thuds, far and dark). Its echoes come back
/// off the crater walls 92, 147, 213 and 288 ms later (each darker, from one side or the other). The stronger, the louder,
/// deeper and longer, with more bombs. At most two at once (a third takes the quieter's place).
class EruptionBoom final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kBooms = 2, kTaps = 4, kCrackles = 16, kFalls = 8;
    static constexpr float kTapSeconds[kTaps] = {0.092f, 0.147f, 0.213f, 0.288f}, kTapGain[kTaps] = {0.6f, 0.5f, 0.45f, 0.42f};
    static constexpr float kTapPan[kTaps] = {-0.65f, 0.7f, -0.35f, 0.45f};
    struct Boom {
        bool on = false;
        float t = 0, s = 1, fade = 1, fadeStep = 0, end = 10, bodyEnv = 0, crackAmp = 0, crackDecay = 1, roarTau = 2, crackleTau = 2;
        float toCrackle = 0, gl = 0.7f, gr = 0.7f;
        Partial pulse, punch;
        Brown brownL, brownR;
        SVF bodyL[2], bodyR[2], crack, crackTop, roarL, roarR, roarTop;
        Pink pinkL, pinkR;
        float fallAt[kFalls] = {}, fallAmp[kFalls] = {}, fallPan[kFalls] = {};
        int falls = 0, nextFall = 0;
    } booms[kBooms];
    Burst crackles[kCrackles];
    struct Fall { Partial thud; Burst knock; float gl = 0.7f, gr = 0.7f; bool on = false; } fallVoices[4];
    SVF fallDarkL, fallDarkR, crackleDarkL, crackleDarkR;
    int nextCrackle = 0, nextFallVoice = 0;
    float tail = 1;   // seconds since a boom last sounded: the walls ring on 0.3 s more
    float walls = 1, wallsStep = 0;   // a panic fades the walls' echoes with the booms
    std::vector<float> line;
    int lineLen = 1, w = 0, tap[kTaps] = {};
    float tapY[kTaps] = {}, tapGl[kTaps] = {}, tapGr[kTaps] = {}, tapA = 0.8f;
    SVF hp[2];

    void start(float strength, float sr) {
        Boom *b = nullptr;
        for (auto &x : booms) if (!x.on) { b = &x; break; }
        if (!b) { b = &booms[0]; for (auto &x : booms) if (x.s * x.fade < b->s * b->fade) b = &x; }
        const float s = std::clamp(strength, 0.3f, 1.f);
        b->on = true; b->t = 0; b->s = s; b->fade = 1; b->fadeStep = 0; b->bodyEnv = 0;
        b->pulse.startSine(30.f + 10.f * rng.uniform(), 0.3f + 0.15f * s, 0.9f * s, sr);
        b->punch.startSine(64.f + 14.f * rng.uniform(), 0.2f, 0.45f * s, sr);
        for (int k = 0; k < 2; ++k) { b->bodyL[k].clear(); b->bodyR[k].clear(); b->bodyL[k].set(90.f, 0.7f, sr); b->bodyR[k].set(95.f, 0.7f, sr); }
        b->crack.clear(); b->crack.set(1400.f, 0.5f, sr); b->crackTop.clear(); b->crackTop.set(3200.f, 0.7f, sr);
        b->crackAmp = 1.3f * s; b->crackDecay = std::exp(-1.f / (0.012f * sr));
        b->roarL.clear(); b->roarR.clear(); b->roarL.set(250.f, 0.6f, sr); b->roarR.set(275.f, 0.6f, sr);
        b->roarTop.clear(); b->roarTop.set(1600.f, 0.7f, sr);
        b->roarTau = 1.8f + 1.6f * s; b->crackleTau = 1.5f + 2.5f * s; b->toCrackle = 0.12f;
        b->falls = std::min(kFalls, 3 + (int)std::lround(5.f * s)); b->nextFall = 0;
        for (int k = 0; k < b->falls; ++k) {
            b->fallAt[k] = 2.2f + 4.8f * rng.uniform(); b->fallAmp[k] = 0.15f + 0.2f * rng.uniform(); b->fallPan[k] = 0.85f * rng.bipolar();
        }
        std::sort(b->fallAt, b->fallAt + b->falls);
        b->end = 9.f + 3.f * s;
        panGains(0.15f * rng.bipolar(), b->gl, b->gr);
        if (events < 0x7fffffff) ++events;
    }

public:
    EruptionBoom(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.12f;   // the crater's own walls are its room
        lineLen = (int)(0.3f * sr) + 2;
        line.assign((size_t)lineLen, 0.f);
        for (int k = 0; k < kTaps; ++k) { tap[k] = (int)std::lround(kTapSeconds[k] * sr); panGains(kTapPan[k], tapGl[k], tapGr[k]); }
        tapA = std::exp(-kTwoPi * 3500.f / sr);   // the walls and the air take the top off
        for (auto &h : hp) h.set(24.f, 0.7f, sr);
        fallDarkL.set(1200.f, 0.7f, sr); fallDarkR.set(1200.f, 0.7f, sr); crackleDarkL.set(4200.f, 0.7f, sr); crackleDarkR.set(4200.f, 0.7f, sr);
    }
    void wake(const AmbienceContext &) override {
        for (auto &b : booms) b.on = false;
        std::fill(line.begin(), line.end(), 0.f);
        for (auto &y : tapY) y = 0;
    }
    void triggerNow(const AmbienceContext &c) override { start(0.8f, c.sr); }
    void event(const AmbienceEvent &e, float, const AmbienceContext &c) override { start(e.strength, c.sr); }
    void silence(float sr) override {
        for (auto &b : booms) if (b.on) b.fadeStep = 1.f / (0.04f * sr);
        wallsStep = 1.f / (0.04f * sr);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        bool any = false;
        for (auto &b : booms) {
            if (!b.on) continue;
            any = true;
            while (b.nextFall < b.falls && b.fallAt[b.nextFall] < b.t + dt) {
                Fall &f = fallVoices[nextFallVoice]; nextFallVoice = (nextFallVoice + 1) % 4;
                const float a = b.fallAmp[b.nextFall] * b.s;
                f.thud.startSine(70.f + 70.f * rng.uniform(), 0.15f, a, fsr);
                f.knock.start(500.f + 700.f * rng.uniform(), 0.9f, 0.008f, 1.2f * a, 0.f, fsr);
                panGains(b.fallPan[b.nextFall], f.gl, f.gr); f.on = true;
                ++b.nextFall;
            }
            // The tail's crackle: spatter and bombs bursting, thinning out.
            if (b.t > 0.35f) {   // the spatter and the bombs bursting, once the column is up
                const float in = std::min(1.f, (b.t - 0.35f) / 0.5f);
                b.toCrackle -= in * (30.f + 60.f * b.s) * std::exp(-(b.t - 0.35f) / b.crackleTau) * b.fade * dt;
                for (int k = 0; k < 4 && b.toCrackle <= 0.f; ++k) {
                    crackles[nextCrackle].start(600.f * std::pow(6.f, rng.uniform()), 1.f, 0.0005f + 0.0035f * rng.uniform(),
                                                0.55f * b.s * pareto(rng, 2.f, 4.f), 0.9f * rng.bipolar(), fsr);
                    nextCrackle = (nextCrackle + 1) % kCrackles;
                    b.toCrackle += expRand(rng);
                }
            }
        }
        bool sounding = any;
        for (auto &k : crackles) sounding = sounding || k.on();
        for (auto &f : fallVoices) sounding = sounding || f.on;
        tail = sounding ? 0.f : tail + dt;
        if (tail > 0.4f) return;   // the walls have rung out too
        for (int i = 0; i < n; ++i) {
            float yl = 0, yr = 0, feed = 0;
            for (auto &b : booms) {
                if (!b.on) continue;
                const float tt = b.t + (float)i * invSr;
                // The air's low rumble under the blast: up in 12 ms, down over half a second.
                const float body = b.s * std::min(1.f, tt / 0.012f) * std::exp(-tt / (0.35f + 0.25f * b.s));
                const float bl = b.bodyL[1].low(b.bodyL[0].low(b.brownL.next(rng.bipolar()))), br = b.bodyR[1].low(b.bodyR[0].low(b.brownR.next(rng.bipolar())));
                const float thump = b.pulse.next() + b.punch.next();
                float ck = 0;
                if (b.crackAmp > 1e-4f) { ck = b.crackAmp * b.crackTop.low(b.crack.band(rng.bipolar())); b.crackAmp *= b.crackDecay; }
                const float roarEnv = 0.45f * b.s * (1.f - std::exp(-tt / 0.8f)) * std::exp(-tt / b.roarTau);   // the column builds
                const float rl = roarEnv * b.roarTop.low(b.roarL.band(b.pinkL.next(rng.bipolar()))), rr = roarEnv * b.roarTop.low(b.roarR.band(b.pinkR.next(rng.bipolar())));
                const float direct = thump + ck;
                const float g = b.fade;
                yl += g * (direct * b.gl * 1.41f + 9.f * body * bl + rl);
                yr += g * (direct * b.gr * 1.41f + 9.f * body * br + rr);
                feed += g * (direct + 4.5f * body * (bl + br));
                if (b.fadeStep > 0.f && (b.fade -= b.fadeStep) <= 0.f) { b.fade = 0.f; b.on = false; }
            }
            // The crater's walls: four early reflections, darker than the blast.
            line[(size_t)w] = feed;
            for (int k = 0; k < kTaps; ++k) {
                int ri = w - tap[k]; if (ri < 0) ri += lineLen;
                tapY[k] = line[(size_t)ri] + (tapY[k] - line[(size_t)ri]) * tapA;
                yl += walls * kTapGain[k] * tapY[k] * tapGl[k]; yr += walls * kTapGain[k] * tapY[k] * tapGr[k];
            }
            if (++w >= lineLen) w = 0;
            if (wallsStep > 0.f && (walls -= wallsStep) <= 0.f) {   // the walls silenced: empty them, ready for the next
                std::fill(line.begin(), line.end(), 0.f);
                for (auto &y : tapY) y = 0.f;
                walls = 1.f; wallsStep = 0.f;
            }
            float cl = 0, cr = 0;
            for (auto &k : crackles) if (k.on()) { const float x = k.next(rng); cl += x * k.gl; cr += x * k.gr; }
            float fl = 0, fr = 0;
            for (auto &f : fallVoices) if (f.on) { const float x = f.thud.next() + f.knock.next(rng); fl += x * f.gl; fr += x * f.gr; }
            yl += crackleDarkL.low(cl) + fallDarkL.low(fl);
            yr += crackleDarkR.low(cr) + fallDarkR.low(fr);
            l[i] += hp[0].high(yl); r[i] += hp[1].high(yr);
        }
        for (auto &f : fallVoices) if (f.on && !f.knock.on() && f.thud.energy() < 1e-10f) f.on = false;
        for (auto &b : booms) {
            if (!b.on) continue;
            b.t += dt;
            if (b.t > b.end) b.on = false;
        }
    }
};

// ---------------------------------------------------------------- Plume thunder: the plume's lightning, close and dry
/// A stroke inside the plume (an event), heard from the rim: a short dry rip (the channel's 4–12 arrivals over 30–150 ms,
/// front-loaded, each kicking a tearing band of noise at 0.7–3 kHz that dies in a few milliseconds, so the rip crackles)
/// with a short low knock under it (a 55–75 Hz thump and a little rumble of the air, gone in under half a second), so it
/// is snappier than storm thunder and never rolls. Mostly dry; where the stroke is (its pan). Four at once at most.
class PlumeThunder final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kCracks = 4, kArrivals = 12;
    struct Crack {
        bool on = false;
        float t = 0, s = 1, end = 1, gl = 0.7f, gr = 0.7f, fade = 1, fadeStep = 0, boomTau = 0.2f, rip = 0, ripDecay = 1;
        int count = 0, next = 0;
        float at[kArrivals] = {}, amp[kArrivals] = {};
        Partial knock;
        Brown brown;
        SVF low, tear, top;
    } cracks[kCracks];

    void start(float strength, float pan, float sr) {
        Crack *k = nullptr;
        for (auto &x : cracks) if (!x.on) { k = &x; break; }
        if (!k) { k = &cracks[0]; for (auto &x : cracks) if (x.t > k->t) k = &x; }
        const float s = clamp01(strength);
        k->on = true; k->t = 0; k->s = s; k->fade = 1; k->fadeStep = 0; k->next = 0; k->rip = 0;
        k->count = std::min(kArrivals, 4 + (int)std::lround(8.f * s * (0.6f + 0.4f * rng.uniform())));
        const float span = 0.03f + 0.12f * rng.uniform();
        for (int i = 0; i < k->count; ++i) {
            const float u = (float)i / (float)std::max(1, k->count - 1);
            k->at[i] = i == 0 ? 0.f : span * u * u * (0.8f + 0.4f * rng.uniform());
            k->amp[i] = (i == 0 ? 1.f : 0.35f + 0.6f * rng.uniform() * (1.f - 0.6f * u)) * (0.5f + 0.5f * s);
        }
        std::sort(k->at, k->at + k->count);
        k->ripDecay = std::exp(-1.f / ((0.003f + 0.003f * rng.uniform()) * sr));
        k->knock.startSine(55.f + 20.f * rng.uniform(), 0.2f + 0.1f * s, 0.12f * (0.4f + 0.6f * s), sr);
        k->boomTau = 0.12f + 0.1f * s;
        k->low.clear(); k->low.set(140.f, 0.7f, sr);
        k->tear.clear(); k->tear.set(1200.f + 900.f * rng.uniform(), 0.6f, sr);
        k->top.clear(); k->top.set(4200.f, 0.7f, sr);
        k->end = 0.9f;
        panGains(std::clamp(pan, -1.f, 1.f), k->gl, k->gr);
        if (events < 0x7fffffff) ++events;
    }

public:
    explicit PlumeThunder(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.15f; }
    void wake(const AmbienceContext &) override { for (auto &k : cracks) k.on = false; }
    void triggerNow(const AmbienceContext &c) override { start(0.7f, 0.4f * rng.bipolar(), c.sr); }
    void event(const AmbienceEvent &e, float, const AmbienceContext &c) override { start(e.strength, e.pan, c.sr); }
    void silence(float sr) override { for (auto &k : cracks) if (k.on) k.fadeStep = 1.f / (0.04f * sr); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        for (auto &k : cracks) {
            if (!k.on) continue;
            for (int i = 0; i < n; ++i) {
                const float tt = k.t + (float)i * invSr;
                while (k.next < k.count && k.at[k.next] <= tt) k.rip += k.amp[k.next++];   // an arrival tears the air again
                const float x = 2.2f * k.rip * k.tear.band(rng.bipolar());
                k.rip *= k.ripDecay;
                const float boom = 0.5f * k.s * std::min(1.f, tt / 0.008f) * std::exp(-tt / k.boomTau);
                const float y = k.fade * (k.top.low(x) + k.knock.next() + 1.5f * boom * k.low.low(k.brown.next(rng.bipolar())));
                l[i] += y * k.gl; r[i] += y * k.gr;
                if (k.fadeStep > 0.f && (k.fade -= k.fadeStep) <= 0.f) { k.on = false; break; }
            }
            k.t += dt;
            if (k.t > k.end) k.on = false;
        }
    }
};

// ---------------------------------------------------------------- Drive: the speed in km/h
/// The drive's speed (0…1) in km/h: 50 at 0, 130 at 1 (Neon Night Drive's own law).
inline float driveKmh(float speed) { return 50.f + 80.f * clamp01(speed); }

// ---------------------------------------------------------------- Wet tyres: the road under you, in the rain
/// Tyre roar from inside the car (pink noise round 450–1100 Hz over a low body, rising 16 dB from 50 to 130 km/h) and the
/// wet road's spray (a hiss at 2.8–5.2 kHz, louder the wetter and the faster, the water film thick and thin under you,
/// and now and then a puddle's swoosh), brighter with the speed; and the expressway's deck joints every 36–60 m, each two
/// thumps (front axle, then rear 2.75 m later) through the suspension.
class WetTyres final : public AmbienceSource {
    FastRandom rng;
    Pink pinkL, pinkR, pinkB;
    SVF roarL, roarR, body, sprayL, sprayR, sprayTopL, sprayTopR;
    Wander film;
    Partial thump[2];
    Burst clack[2];
    int nextJoint = 0;
    float toJoint = 20, rearIn = -1, rearAmp = 0, toPuddle = 6, puddleT = -1, puddleDur = 0.5f, puddleAmp = 0;
    float roarApplied = -1, sprayApplied = -1, a = 0.3f, sp = 0.1f;

    void axle(float amp, float sr) {
        Partial &p = thump[nextJoint]; Burst &b = clack[nextJoint]; nextJoint ^= 1;
        p.startSine(38.f + 17.f * rng.uniform(), 0.12f, amp, sr);
        b.start(250.f + 200.f * rng.uniform(), 1.f, 0.012f, 1.6f * amp, 0.1f, sr);
    }

public:
    WetTyres(uint64_t seed, float sr) : rng(seed) { direct = 1.f; send = 0.15f; body.set(110.f, 0.6f, sr); sprayTopL.set(9000.f, 0.7f, sr); sprayTopR.set(9200.f, 0.7f, sr); }
    void wake(const AmbienceContext &) override { toJoint = 10.f + 30.f * rng.uniform(); rearIn = -1; toPuddle = 3.f + 6.f * rng.uniform(); }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, s = clamp01(c.speed), v = driveKmh(s) / 3.6f, wet = clamp01(c.wetness);
        const float centre = 450.f + 650.f * s;
        if (std::fabs(centre - roarApplied) > 3.f) { roarApplied = centre; roarL.set(centre, 0.8f, fsr); roarR.set(centre * 1.07f, 0.8f, fsr); }
        const float spray = 2800.f + 2400.f * s;
        if (std::fabs(spray - sprayApplied) > 10.f) { sprayApplied = spray; sprayL.set(spray, 0.7f, fsr); sprayR.set(spray * 1.05f, 0.7f, fsr); }
        // The deck joints: front axle, then the rear.
        if ((toJoint -= v * dt) <= 0.f) {
            const float amp = 0.45f + 0.35f * s;
            axle(amp, fsr); rearIn = 2.75f / v; rearAmp = amp * (0.8f + 0.2f * rng.uniform());
            toJoint = 36.f + 24.f * rng.uniform();
            if (events < 0x7fffffff) ++events;
        }
        if (rearIn >= 0.f && (rearIn -= dt) < 0.f) axle(rearAmp, fsr);
        // A puddle now and then: the spray swells for a moment.
        if ((toPuddle -= dt * (0.5f + s) * c.density) <= 0.f) {
            puddleT = 0; puddleDur = 0.25f + 0.45f * rng.uniform(); puddleAmp = 0.8f + 1.2f * rng.uniform() * wet;
            toPuddle = 5.f + 9.f * rng.uniform();
        }
        float puddle = 0;
        if (puddleT >= 0.f) { puddle = puddleAmp * bump(puddleT / puddleDur); puddleT += dt; if (puddleT > puddleDur) puddleT = -1; }
        const float vr = v / 36.1f;
        const float a1 = 0.18f + 0.82f * vr * vr;
        const float sp1 = wet * (0.15f + 0.85f * s * s) * (0.7f + 0.3f * film.next(rng, dt, 1.5f)) * (1.f + puddle);
        const float inv = 1.f / (float)n, da = (a1 - a) * inv, ds = (sp1 - sp) * inv;
        for (int t = 0; t < n; ++t) {
            a += da; sp += ds;
            const float bd = 0.8f * body.band(pinkB.next(rng.bipolar()));
            const float wl = rng.bipolar(), wr = rng.bipolar();
            float jl = 0;
            for (int k = 0; k < 2; ++k) { if (thump[k].mag > 0.f) jl += thump[k].next(); if (clack[k].on()) jl += clack[k].next(rng); }
            l[t] += a * (roarL.band(pinkL.next(rng.bipolar())) + bd) + sprayTopL.low(0.9f * sp * sprayL.band(wl)) + 0.55f * jl;
            r[t] += a * (roarR.band(pinkR.next(rng.bipolar())) + bd) + sprayTopR.low(0.9f * sp * sprayR.band(wr)) + 0.45f * jl;
        }
        for (auto &p : thump) if (p.mag > 0.f && p.energy() < 1e-10f) p.mag = 0.f;
    }
};

// ---------------------------------------------------------------- Wipers: rubber on the windscreen
/// A sweep (an event; the world's wipers set its time and how wet the glass is): the blades go up and back, fastest in
/// the middle of each stroke and still at its ends. On a wet screen they push the water off with a soft swish; as it
/// dries the rubber catches and lets go (a stick-slip squeak through the blade's own resonance, in patches). At each end
/// a muted thunk as the blade flips over (a little firmer at rest). They sweep across the glass in front of you. Subtle.
class Wipers final : public AmbienceSource {
    FastRandom rng;
    struct Sweep { bool on = false; float T = 1.45f, wet = 0.6f; };
    Sweep now, queued;
    float t = 0, stick = 0;
    int thunks = 0;
    SVF swishL, swishR, chirp, chirpBody, thunkLP;
    Partial thunk;
    Burst flip;
    Wander catchW;

    void begin(const Sweep &s) { now = s; now.on = true; t = 0; thunks = 0; if (events < 0x7fffffff) ++events; }

public:
    Wipers(uint64_t seed, float sr) : rng(seed) {
        direct = 1.f; send = 0.12f; indoor = true;
        swishL.set(1700.f, 0.8f, sr); swishR.set(1850.f, 0.8f, sr); chirp.set(1350.f, 6.f, sr); chirpBody.set(2600.f, 3.f, sr);
        thunkLP.set(900.f, 0.7f, sr);
    }
    void wake(const AmbienceContext &) override { now.on = false; queued.on = false; }
    void triggerNow(const AmbienceContext &) override { Sweep s; s.T = 1.2f; s.wet = 0.6f; if (now.on) { queued = s; queued.on = true; } else begin(s); }
    void event(const AmbienceEvent &e, float, const AmbienceContext &) override {
        Sweep s; s.T = std::clamp(e.speed > 0.f ? e.speed : 1.45f, 0.5f, 3.f); s.wet = clamp01(e.strength);
        if (now.on) { queued = s; queued.on = true; } else begin(s);
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (!now.on) {
            if (thunk.mag <= 0.f && !flip.on()) return;
        }
        const float phase0 = now.on ? t / now.T : 1.f;
        // The ends: a thunk as each stroke turns (the top) and as the blade comes to rest (the park).
        if (now.on) {
            const float phase1 = (t + dt) / now.T;
            if (thunks == 0 && phase1 >= 0.5f) { thunk.startSine(105.f + 25.f * rng.uniform(), 0.08f, 0.45f, fsr); flip.start(1300.f, 1.2f, 0.003f, 0.6f, 0.f, fsr); thunks = 1; }
            if (thunks == 1 && phase1 >= 1.f) { thunk.startSine(90.f + 20.f * rng.uniform(), 0.1f, 0.65f, fsr); flip.start(1100.f, 1.2f, 0.004f, 0.5f, 0.f, fsr); thunks = 2; }
        }
        const float ang = now.on ? 0.5f - 0.5f * std::cos(kTwoPi * phase0) : 0.f;
        float gl, gr; panGains(-0.55f + 1.1f * ang, gl, gr);
        const float speed = now.on ? std::fabs(std::sin(kTwoPi * phase0)) : 0.f;   // the blade's speed, 0 at the ends
        const float wet = now.wet, dry = 1.f - wet;
        const float swish = speed * (0.25f + 0.75f * wet) * 0.6f;
        const float catchNow = catchW.next(rng, dt, 0.07f);
        const float squeak = speed * dry * std::sqrt(dry) * (catchNow > 0.4f ? (catchNow - 0.4f) / 0.6f : 0.f) * 3.f
                             + 0.15f * dry * (1.f - speed) * (now.on ? 1.f : 0.f);
        const float slipHz = 260.f + 520.f * speed;
        for (int i = 0; i < n; ++i) {
            float y = 0, yl = 0, yr = 0;
            if (now.on) {
                const float wl = rng.bipolar(), wr = rng.bipolar();
                yl += swish * swishL.band(wl); yr += swish * swishR.band(wr);
                stick += slipHz * invSr * (0.9f + 0.2f * rng.uniform());
                float pulse = 0;
                if (stick >= 1.f) { stick -= 1.f; pulse = 1.f; }
                y += squeak * (chirp.band(pulse * 6.f) + 0.4f * chirpBody.band(pulse * 6.f));
            }
            float th = 0;
            if (thunk.mag > 0.f) th += thunk.next();
            if (flip.on()) th += 0.4f * flip.next(rng);
            th = thunkLP.low(th);
            l[i] += (yl + y) * gl * 1.41f + th * 0.75f;
            r[i] += (yr + y) * gr * 1.41f + th * 0.65f;
        }
        if (thunk.mag > 0.f && thunk.energy() < 1e-10f) thunk.mag = 0.f;
        if (now.on) {
            t += dt;
            if (t >= now.T) {
                now.on = false;
                if (queued.on) { Sweep s = queued; queued.on = false; begin(s); }
            }
        }
    }
};

// ---------------------------------------------------------------- Drive engine: a modern car's engine from inside
/// A four-cylinder heard through the firewall: its firing note (twice the crank's turns) with its even orders and a trace
/// of the odd, warm under a cabin's low-pass, a little combustion breath pulsing at the firing rate, the revs breathing a
/// fraction. Through an eight-speed automatic (34.5, 44, 55 and 67 km/h a thousand revs in fifth to eighth): the revs
/// follow the speed and, past 1950 (later when accelerating), it shifts up and the note drops over 0.35 s with a dip as the
/// torque hands over; under 1250 it shifts down. Louder and a little brighter as it pulls. Quiet, under the music.
class DriveEngine final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kLowGear = 5, kTopGear = 8;
    static constexpr float kKmhPer1000[kTopGear + 1] = {0, 0, 0, 0, 26.f, 34.5f, 44.f, 55.f, 67.f};
    static constexpr float kHarm[8] = {0.07f, 1.f, 0.05f, 0.42f, 0.03f, 0.2f, 0.02f, 0.1f};
    int gear = kLowGear;
    float rpm = 1450, shiftT = -1, shiftFrom = 0, lastSpeed = -1, load = 0, ph = 0, hzNow = 0, a = 0.5f, cutApplied = -1;
    Pink pink;
    SVF cabin, cabin2, breath;
    Wander jitter;
    float breathApplied = -1;

    static float revs(float kmh, int g) { return 1000.f * kmh / kKmhPer1000[g]; }

public:
    explicit DriveEngine(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.08f; indoor = true; }
    void wake(const AmbienceContext &c) override {
        const float kmh = driveKmh(c.speed);
        gear = kLowGear;
        while (gear < kTopGear && revs(kmh, gear) > 1950.f) ++gear;
        rpm = revs(kmh, gear); shiftT = -1; lastSpeed = c.speed; load = 0;
    }
    float hz() const override { return hzNow; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, s = clamp01(c.speed), kmh = driveKmh(s);
        if (lastSpeed < 0) lastSpeed = s;
        const float accel = (s - lastSpeed) / dt;   // speed units a second
        lastSpeed = s;
        load += (clamp01(accel * 4.f) - load) * (1.f - std::exp(-dt / 0.4f));
        // The gearbox: up past 1950 (2300 pulling hard), down under 1250.
        if (shiftT < 0.f) {
            const float up = 1950.f + 350.f * load;
            int want = gear;
            if (gear < kTopGear && revs(kmh, gear) > up) want = gear + 1;
            else if (gear > kLowGear && revs(kmh, gear) < 1250.f) want = gear - 1;
            if (want != gear) { shiftFrom = revs(kmh, gear); gear = want; shiftT = 0; if (events < 0x7fffffff) ++events; }
        }
        float target = revs(kmh, gear), dip = 1.f;
        if (shiftT >= 0.f) {
            const float x = std::min(1.f, shiftT / 0.35f), e = x * x * (3.f - 2.f * x);
            target = shiftFrom + (target - shiftFrom) * e;
            dip = 1.f - 0.3f * bump(x);
            shiftT += dt;
            if (shiftT > 0.35f) shiftT = -1;
        }
        rpm = target * (1.f + 0.003f * (jitter.next(rng, dt, 0.4f) - 0.5f));
        const float f1 = rpm / 60.f;   // the crank's turns a second
        hzNow = 2.f * f1;              // the firing note
        const float cut = 260.f + 160.f * load;
        if (std::fabs(cut - cutApplied) > 2.f) { cutApplied = cut; cabin.set(cut, 0.7f, fsr); cabin2.set(cut * 1.3f, 0.6f, fsr); }
        const float br = 3.f * hzNow;
        if (std::fabs(br - breathApplied) > 1.f) { breathApplied = br; breath.set(br, 1.5f, fsr); }
        const float a1 = (0.55f + 0.45f * load) * dip, da = (a1 - a) / (float)n, inc = f1 * invSr;
        for (int i = 0; i < n; ++i) {
            a += da;
            advanceTone(ph, inc);
            const float s1 = sin2pi(ph), c2 = 2.f * sin2pi(ph + 0.25f);
            float prev = 0.f, cur = s1, tone = kHarm[0] * s1;
            for (int k = 1; k < 8; ++k) { const float next = c2 * cur - prev; prev = cur; cur = next; tone += kHarm[k] * cur; }
            const float puff = 0.5f + 0.5f * sin2pi(2.f * ph);
            const float x = cabin2.low(cabin.low(0.5f * tone + 0.6f * (0.4f + 0.6f * load) * puff * breath.band(pink.next(rng.bipolar()))));
            l[i] += a * x; r[i] += a * x * 0.96f;
        }
    }
};

// ---------------------------------------------------------------- Drive: cars passing in the next lanes
/// A car (or now and then a truck) passing in a lane beside you (an event, due at its closest approach and heard from 3 s
/// before): as it comes the distance falls to its lane's and grows again behind, and everything about it follows: its
/// level (the distance's), its Doppler (the speed at which it closes, so an oncoming car's note falls by about a fifth as
/// it passes, one overtaking you by a few cents), its brightness (the air, and darker behind), and where it is (swinging
/// out to its side as it comes alongside, back toward the middle as it goes). It is its engine (a firing note of 62–95 Hz,
/// a truck's 34–48 Hz with more weight), its tyres' roar and, on a wet road, their spray, and the whoosh of the air it
/// pushes; a truck is longer alongside and buffets the car.
class DrivePassingCar final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kCars = 4;
    static constexpr float kSound = 343.f;
    struct Car {
        bool on = false, truck = false;
        float t = 0, end = 3, v = 30, d = 4, side = 1, f0 = 80, ph = 0, amp = 1, hzNow = 0, doppler = 1, gain = 0, pan = 0;
        float gl = 0.7f, gr = 0.7f, cut = 8000, whoosh = 0, buffet = 0, tyreApplied = -1, cutApplied = -1;
        SVF tyre, spray, whooshF, engLP, far, buffetLP;
        Pink pink;
        Brown brown;
    } cars[kCars];
    uint32_t newest = 0, serial[kCars] = {};

    void start(float ahead, float closing, float lateral, float side, bool truck, float strength, float sr) {
        Car *k = nullptr; int ki = 0;
        for (int i = 0; i < kCars; ++i) if (!cars[i].on) { k = &cars[i]; ki = i; break; }
        if (!k) { ki = 0; for (int i = 1; i < kCars; ++i) if (serial[i] < serial[ki]) ki = i; k = &cars[ki]; }
        serial[ki] = ++newest;
        k->on = true; k->truck = truck; k->t = -std::clamp(ahead, 0.f, 3.f); k->end = 3.f;
        k->v = std::clamp(closing, 2.f, 90.f); k->d = std::clamp(lateral, 2.f, 30.f); k->side = side < 0.f ? -1.f : 1.f;
        k->f0 = truck ? 34.f + 14.f * rng.uniform() : 62.f + 33.f * rng.uniform();
        k->amp = clamp01(strength) * (truck ? 1.25f : 1.f);
        k->tyreApplied = -1; k->cutApplied = -1; k->ph = rng.uniform();
        k->engLP.clear(); k->engLP.set(truck ? 320.f : 420.f, 0.7f, sr); k->whooshF.clear(); k->whooshF.set(850.f, 0.5f, sr);
        k->buffetLP.clear(); k->buffetLP.set(60.f, 0.7f, sr);
        k->tyre.clear(); k->spray.clear(); k->far.clear();
        if (events < 0x7fffffff) ++events;
    }
    /// How far along the road the car is from you at time `t` from its closest approach (m): a truck is alongside for its
    /// whole 20 m.
    static float along(const Car &k, float t) {
        const float x = k.v * t;
        if (!k.truck) return x;
        return x > 10.f ? x - 10.f : (x < -10.f ? x + 10.f : 0.f);
    }
    /// Where the car is at time `t`: its distance (m) and how fast it opens (m/s, < 0 closing).
    static void geometry(const Car &k, float t, float &dist, float &radial) {
        const float x = along(k, t);
        dist = std::sqrt(k.d * k.d + x * x);
        radial = x == 0.f ? 0.f : k.v * x / dist;
    }

public:
    explicit DrivePassingCar(uint64_t seed) : rng(seed) { direct = 1.f; send = 0.2f; }
    float lead() const override { return 3.f; }
    void wake(const AmbienceContext &) override { for (auto &k : cars) k.on = false; }
    void triggerNow(const AmbienceContext &c) override { start(2.f, 56.f, 13.f, 1.f, false, 1.f, c.sr); }
    void event(const AmbienceEvent &e, float ahead, const AmbienceContext &c) override {
        start(ahead, e.speed, e.distance, e.pan, e.kind == 1, e.strength, c.sr);
    }
    float hz() const override {
        int best = -1;
        for (int i = 0; i < kCars; ++i) if (cars[i].on && (best < 0 || serial[i] > serial[best])) best = i;
        return best < 0 ? 0.f : cars[best].hzNow;
    }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr, wet = clamp01(c.wetness);
        for (auto &k : cars) {
            if (!k.on) continue;
            // This block's geometry at its start and end, the tone gliding between them.
            float d0, r0, d1, r1;
            geometry(k, k.t, d0, r0); geometry(k, k.t + dt, d1, r1);
            const float dop0 = kSound / (kSound + r0), dop1 = kSound / (kSound + r1);
            const float g0 = k.amp * std::min(1.f, 4.f / d0), g1 = k.amp * std::min(1.f, 4.f / d1);
            k.hzNow = k.f0 * dop1;   // its engine's note as heard
            const float behind = k.t > 0.f ? 0.7f : 1.f;
            const float cut = std::clamp(16000.f * std::pow(5.f / d1, 0.7f), 1800.f, 16000.f) * behind;
            if (std::fabs(cut - k.cutApplied) > 30.f) { k.cutApplied = cut; k.far.set(cut, 0.7f, fsr); }
            const float tyre = (k.truck ? 520.f : 700.f) * dop1;
            if (std::fabs(tyre - k.tyreApplied) > 3.f) { k.tyreApplied = tyre; k.tyre.set(tyre, 0.7f, fsr); k.spray.set(3500.f * dop1, 0.8f, fsr); }
            const float sinA = k.d / d1, pan1 = k.side * (0.12f + 0.78f * sinA);
            float gl1, gr1; panGains(pan1, gl1, gr1);
            const float inv = 1.f / (float)n;
            const float dg = (g1 - g0) * inv, dgl = (gl1 - k.gl) * inv, dgr = (gr1 - k.gr) * inv;
            const float inc0 = k.f0 * dop0 * invSr, dinc = (k.f0 * dop1 * invSr - inc0) * inv;
            // The air it pushes: a whoosh strongest alongside (and for a truck, a buffet).
            const float xa = along(k, k.t + dt) / 8.f, near1 = std::exp(-xa * xa) * std::min(1.f, 4.f / k.d);
            const float wsh = (k.truck ? 0.7f : 0.45f) * near1, buf = k.truck ? 0.25f * near1 : 0.f;
            const float dw = (wsh - k.whoosh) * inv, db = (buf - k.buffet) * inv;
            float g = g0, inc = inc0;
            for (int i = 0; i < n; ++i) {
                g += dg; k.gl += dgl; k.gr += dgr; inc += dinc; k.whoosh += dw; k.buffet += db;
                advanceTone(k.ph, inc);
                const float s1 = sin2pi(k.ph), c2 = 2.f * sin2pi(k.ph + 0.25f), s2 = c2 * s1, s3 = c2 * s2 - s1, s4 = c2 * s3 - s2;
                const float eng = k.engLP.low(k.truck ? 0.45f * s1 + 0.6f * s2 + 0.45f * s3 + 0.35f * s4 : 0.2f * s1 + 0.5f * s2 + 0.2f * s3 + 0.15f * s4);
                // One car is one place: its sound is made once and panned.
                const float w = rng.bipolar();
                const float air = k.whoosh * k.whooshF.band(rng.bipolar()) + k.buffet * k.buffetLP.low(k.brown.next(rng.bipolar())) * 6.f;
                const float y = k.far.low(g * (0.25f * eng + 0.8f * k.tyre.band(k.pink.next(w)) + 0.45f * wet * k.spray.band(w)) + air) * 1.41f;
                l[i] += y * k.gl; r[i] += y * k.gr;
            }
            k.t += dt;
            if (k.t > k.end) k.on = false;
        }
    }
};

// ---------------------------------------------------------------- Roof rain: the rain on a car, from inside
/// The existing rain on the glass (the windscreen in front of you: its drops tick close and bright, a little dulled by the
/// cabin) with the roof over your head: drops drumming on the padded steel (each a dull knock of the panel at 180–520 Hz,
/// muffled by the headliner) over the roof's own soft roar. The level is the rain: heavier means more drops, not only
/// louder; and when it stops (under a bridge) the drops stop within a fraction of a second.
class RoofRain final : public AmbienceSource {
    FastRandom rng;
    Rain glass;
    Pink pinkL, pinkR;
    SVF bedL, bedR, cutL, cutR, cabinL, cabinR, roofL, roofR;
    static constexpr int kDrops = 12;
    Partial drops[kDrops];
    float dropGl[kDrops] = {}, dropGr[kDrops] = {};
    int nextDrop = 0;
    float toDrop = 0, wet = 0;
    float gl_[64] = {}, gr_[64] = {};

public:
    RoofRain(uint64_t seed, float sr) : rng(seed), glass(seed ^ 0x5EEDF00DULL, true, sr) {
        direct = 1.f; send = 0.25f; indoor = true;
        bedL.set(650.f, 0.6f, sr); bedR.set(700.f, 0.6f, sr); cabinL.set(5500.f, 0.7f, sr); cabinR.set(5800.f, 0.7f, sr);
        // No sub-bass under the roof: the drops' knocks, each rung from rest, would add up to a standing offset (300 a
        // second), and the pink bed's own wander below 20 Hz is no part of a roar.
        cutL.set(70.f, 0.7f, sr); cutR.set(70.f, 0.7f, sr);
        roofL.set(950.f, 0.7f, sr); roofR.set(1000.f, 0.7f, sr);
    }
    void wake(const AmbienceContext &) override { wet = levelTarget; toDrop = expRand(rng) * 0.01f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr;
        wet += (levelTarget - wet) * (1.f - std::exp(-dt / 0.15f));
        std::fill(gl_, gl_ + n, 0.f); std::fill(gr_, gr_ + n, 0.f);
        glass.render(gl_, gr_, n, c);
        // Heavier rain: more drops (the level is mostly how loud); none once it has stopped (under a bridge).
        const float rate = levelTarget > 0.f ? 520.f * wet * c.density : 0.f;
        toDrop -= rate * dt;
        for (int k = 0; k < 4 && toDrop <= 0.f; ++k) {
            Partial &p = drops[nextDrop];
            p.startSine(180.f * std::pow(520.f / 180.f, rng.uniform()), 0.025f + 0.035f * rng.uniform(), 0.35f * pareto(rng, 2.5f, 3.f), fsr);
            panGains(0.65f * rng.bipolar(), dropGl[nextDrop], dropGr[nextDrop]);
            nextDrop = (nextDrop + 1) % kDrops;
            toDrop += expRand(rng);
            if (events < 0x7fffffff) ++events;
        }
        const float rw = std::sqrt(wet), bed = 0.5f * rw, tick = 0.75f * std::min(1.f, 1.5f * rw);
        for (int i = 0; i < n; ++i) {
            float dl = 0, dr = 0;
            for (int k = 0; k < kDrops; ++k) if (drops[k].mag > 0.f) { const float x = drops[k].next(); dl += x * dropGl[k]; dr += x * dropGr[k]; }
            l[i] += roofL.low(cutL.high(dl + bed * bedL.low(pinkL.next(rng.bipolar())))) + tick * cabinL.low(gl_[i]);
            r[i] += roofR.low(cutR.high(dr + bed * bedR.low(pinkR.next(rng.bipolar())))) + tick * cabinR.low(gr_[i]);
        }
        for (auto &p : drops) if (p.mag > 0.f && p.energy() < 1e-10f) p.mag = 0.f;
    }
};

// ---------------------------------------------------------------- Far siren: a soft wail somewhere across the city
/// Rare (every 90–240 s) and never close: a wordless wail far off across the city, coming and going for 14–28 s as it
/// moves between the towers (its level swelling and sinking, darker when it is hidden), through the distance and the room.
/// Its pitch glides slowly (0.9–1.8 s, eased) from one of the key's pentatonic tones to another and rests on each for
/// 0.7–1.8 s, a step or two at a time, never back to the tone before last, so it is never a two-tone siren, never a
/// sweep on a clock, and never off the key: each new tone is the key's at that moment (a held tone is never retuned).
/// The tones run from the tonic in A3–G♯4 up an octave and a step; soft (a few harmonics and a breath).
class FarSiren final : public AmbienceSource {
    FastRandom rng;
    static constexpr int kPentaMajor[5] = {0, 2, 4, 7, 9}, kPentaMinor[5] = {0, 3, 5, 7, 10};
    static constexpr int kTop = 6;   // degrees 0…6: the tonic up an octave and a step
    bool on = false;
    int deg = 0, prevDeg = -99;
    float t = 0, dur = 20, until = 60, hzNow = 0, from = 0, to = 0, glideT = 0, glideLen = 1, holdLeft = 1, ph = 0;
    float cutApplied = -1, breathApplied = -1;
    SVF farL, farR, breath;
    Wander occlusion, flutter, scint;

    static float tone(int root, bool major, int degree) {
        const int *scale = major ? kPentaMajor : kPentaMinor;
        const int semis = 12 * (degree / 5) + scale[degree % 5];
        return 4.f * bellTonicHz(root) * std::exp2((float)semis / 12.f);
    }
    float interval(const AmbienceContext &c) { return (90.f + 150.f * rng.uniform()) / c.density; }
    void call(const AmbienceContext &c) {
        on = true; t = 0; dur = 14.f + 14.f * rng.uniform();
        deg = (int)(rng.uniform() * 2.99f); prevDeg = -99;
        hzNow = from = to = tone(c.keyRoot, c.keyMajor, deg);
        glideT = 0; glideLen = 0; holdLeft = 0.7f + 1.1f * rng.uniform();
        if (events < 0x7fffffff) ++events;
    }
    void nextTone(const AmbienceContext &c) {
        int next = deg;
        for (int tries = 0; tries < 16; ++tries) {
            const float u = rng.uniform();
            const int step = (u < 0.7f ? 1 : 2) * (rng.uniform() < 0.5f ? -1 : 1);
            next = std::clamp(deg + step, 0, kTop);
            if (next != deg && next != prevDeg) break;
        }
        if (next == deg || next == prevDeg) {   // hemmed in: anything else that is new
            for (int k = 0; k <= kTop; ++k) if (k != deg && k != prevDeg) { next = k; break; }
        }
        prevDeg = deg; deg = next;
        from = hzNow; to = tone(c.keyRoot, c.keyMajor, deg);
        glideT = 0; glideLen = 0.9f + 0.9f * rng.uniform();
        holdLeft = 0.7f + 1.1f * rng.uniform();
    }

public:
    FarSiren(uint64_t seed, float sr) : rng(seed) { direct = 0.55f; send = 0.8f; (void)sr; }
    void wake(const AmbienceContext &c) override { on = false; hzNow = 0; until = interval(c) * (0.15f + 0.35f * rng.uniform()); }
    void triggerNow(const AmbienceContext &c) override { call(c); until = interval(c); }
    float hz() const override { return on ? hzNow : 0.f; }
    void render(float *l, float *r, int n, const AmbienceContext &c) override {
        const float fsr = c.sr, dt = (float)n / fsr, invSr = 1.f / fsr;
        if (!on) {
            if ((until -= dt) > 0.f) return;
            call(c); until = interval(c);
        }
        // The pitch: gliding (eased, in equal steps of pitch), then resting on the tone.
        if (glideLen > 0.f && glideT < glideLen) {
            glideT += dt;
            const float x = std::min(1.f, glideT / glideLen), e = 0.5f - 0.5f * std::cos(kPi * x);
            hzNow = from * std::exp2(std::log2(to / from) * e);
            if (x >= 1.f) { hzNow = to; glideLen = 0; }
        } else if ((holdLeft -= dt) <= 0.f) {
            nextTone(c);
        }
        const float f = hzNow * (1.f + 0.0015f * (flutter.next(rng, dt, 0.4f) - 0.5f));   // ±1.3 cents of air
        // Coming and going between the towers: its level, and darker when hidden.
        const float x = t / dur, env = std::min(1.f, x * dur / 3.f) * std::min(1.f, (1.f - x) * dur / 4.f);
        const float occ = occlusion.next(rng, dt, 2.5f), seen = 0.4f + 0.6f * occ;
        const float cut = 900.f + 1300.f * occ;
        if (std::fabs(cut - cutApplied) > 10.f) { cutApplied = cut; farL.set(cut, 0.7f, fsr); farR.set(cut * 1.04f, 0.7f, fsr); }
        if (std::fabs(f - breathApplied) > 0.5f) { breathApplied = f; breath.set(f, 25.f, fsr); }
        const float amp = env * seen * (0.85f + 0.3f * scint.next(rng, dt, 0.25f));
        const float inc = f * invSr;
        for (int i = 0; i < n; ++i) {
            advanceTone(ph, inc);
            const float s1 = sin2pi(ph), c2 = 2.f * sin2pi(ph + 0.25f), s2 = c2 * s1, s3 = c2 * s2 - s1, s4 = c2 * s3 - s2;
            const float y = amp * (s1 + 0.28f * s2 + 0.1f * s3 + 0.04f * s4 + 0.3f * breath.band(rng.bipolar()));
            l[i] += farL.low(y); r[i] += farR.low(0.9f * y);
        }
        t += dt;
        if (t > dur) { on = false; hzNow = 0; }
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
            v.fade = 1; v.fadeStep = 0;
            return;
        }
    }
    bool active() const { for (auto &v : voices) if (v.on) return true; return false; }
    /// Panic: every clap still waiting is dropped and every one rolling fades out within 40 ms.
    void silence(float sr) {
        for (auto &v : voices) {
            if (!v.on) continue;
            if (v.t < 0) v.on = false; else v.fadeStep = 1.f / (0.04f * sr);
        }
    }
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
                const float x = v.fade * v.level * (env * rumble + crack);
                l[t] += x; r[t] += x * 0.9f;
                if (v.t > v.dur + 6.f) { v.on = false; break; }
                if (v.fadeStep > 0.f && (v.fade -= v.fadeStep) <= 0.f) { v.on = false; break; }
            }
        }
    }

private:
    FastRandom rng;
    struct Voice {
        bool on = false;
        float d = 0.5f, delay = 1, t = 0, dur = 2, level = 1, crack = 0, fade = 1, fadeStep = 0;
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
    auto chimeSource = std::make_unique<Chime>(s(9));
    chime = chimeSource.get();
    sources[ISD_AMB_CHIME] = std::move(chimeSource);
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
    // Storms (Sets 17 & 18): the storm family, then the plains family.
    sources[ISD_AMB_GRASS_WIND] = std::make_unique<GrassWind>(s(39));
    sources[ISD_AMB_HAIL_TIN] = std::make_unique<HailTin>(s(40), fsr);
    sources[ISD_AMB_BIRDS_FLEE] = std::make_unique<BirdsFlee>(s(41), fsr);
    auto rollSource = std::make_unique<ThunderRoll>(s(42));
    thunderRoll = rollSource.get();
    sources[ISD_AMB_THUNDER_ROLL] = std::move(rollSource);
    sources[ISD_AMB_INFLOW_ROAR] = std::make_unique<InflowRoar>(s(43), fsr);
    sources[ISD_AMB_RAIN_ON_DUST] = std::make_unique<RainOnDust>(s(44), fsr);
    sources[ISD_AMB_DRY_CICADAS] = std::make_unique<DryCicadas>(s(45), fsr);
    sources[ISD_AMB_WINDMILL] = std::make_unique<Windmill>(s(46), fsr);
    sources[ISD_AMB_CATTLE_GRID] = std::make_unique<CattleGrid>(s(47));
    sources[ISD_AMB_DUST_TICKS] = std::make_unique<DustTicks>(s(48));
    sources[ISD_AMB_SHIMMER_HUM] = std::make_unique<ShimmerHum>(s(49));
    sources[ISD_AMB_FAR_TRUCK] = std::make_unique<FarTruck>(s(50), fsr);
    // Fire & Neon (Sets 13 & 14): the volcano family, then the drive family.
    sources[ISD_AMB_VENT_RUMBLE] = std::make_unique<VentRumble>(s(51), fsr);
    sources[ISD_AMB_LAVA_HISS] = std::make_unique<LavaHiss>(s(52), fsr);
    sources[ISD_AMB_STEAM_VENT] = std::make_unique<SteamVent>(s(53));
    sources[ISD_AMB_ROCKFALL] = std::make_unique<Rockfall>(s(54));
    sources[ISD_AMB_ERUPTION_BOOM] = std::make_unique<EruptionBoom>(s(55), fsr);
    sources[ISD_AMB_PLUME_THUNDER] = std::make_unique<PlumeThunder>(s(56));
    sources[ISD_AMB_WET_TYRES] = std::make_unique<WetTyres>(s(57), fsr);
    sources[ISD_AMB_WIPERS] = std::make_unique<Wipers>(s(58), fsr);
    sources[ISD_AMB_DRIVE_ENGINE] = std::make_unique<DriveEngine>(s(59));
    sources[ISD_AMB_DRIVE_PASSING_CAR] = std::make_unique<DrivePassingCar>(s(60));
    sources[ISD_AMB_ROOF_RAIN] = std::make_unique<RoofRain>(s(61), fsr);
    sources[ISD_AMB_FAR_SIREN] = std::make_unique<FarSiren>(s(62), fsr);
    for (int i : {ISD_AMB_SHIP_HUM, ISD_AMB_AIR_FLOW, ISD_AMB_CHIME, ISD_AMB_HULL_TICKS}) sources[i]->indoor = true;
    closeness.init(sampleRate, 300.0);
    closeness.snap(0.5f);
}

Ambience::~Ambience() = default;

void Ambience::setLevel(int source, float level) {
    if (source < 0 || source >= ISD_AMB_COUNT || !sources[source]) return;
    Ramp &r = ramps[source];
    const float v = clamp01(level);
    if (v > 0.f && r.silent()) sources[source]->wake(ctx);
    r.setTarget(v, (int)(kRampSeconds * (float)sr));
    // The world's thunder going (a world switch): nothing still on its way may arrive in the next one; nor any one-shot.
    if (source == ISD_AMB_THUNDER_ROLL && v <= 0.f) thunderRoll->clearQueue();
    if (v <= 0.f) clearEvents(source);
}

void Ambience::postEvent(int source, float delaySeconds, const AmbienceEvent &e) {
    if (source < 0 || source >= ISD_AMB_COUNT || !sources[source]) return;
    if (ramps[source].to <= 0.f) return;   // silent, or fading out as the world changes
    Pending *p = nullptr;
    for (auto &q : pending) if (!q.on) { p = &q; break; }
    if (!p) { p = &pending[0]; for (auto &q : pending) if (q.serial < p->serial) p = &q; }
    const float d = std::isfinite(delaySeconds) ? std::clamp(delaySeconds, 0.f, 12.f) : 0.f;
    p->on = true; p->source = source; p->left = (int)std::lround(d * (float)sr); p->e = e; p->serial = ++eventSerial;
    eventsWaiting = true;
}

void Ambience::clearEvents(int source) {
    for (auto &q : pending) if (q.on && (source < 0 || q.source == source)) q.on = false;
}

/// Hands each waiting one-shot to its source at the start of the block it falls due in (less the source's lead).
void Ambience::deliverEvents(int n) {
    if (!eventsWaiting) return;
    bool left = false;
    for (auto &p : pending) {
        if (!p.on) continue;
        const int lead = (int)(sources[p.source]->lead() * (float)sr);
        if (p.left - lead < n) {
            p.on = false;
            if (ramps[p.source].to > 0.f) sources[p.source]->event(p.e, (float)std::max(0, p.left) / (float)sr, ctx);
        } else {
            p.left -= n;
            left = true;
        }
    }
    eventsWaiting = left;
}

float Ambience::sourceHz(int source) const {
    if (source < 0 || source >= ISD_AMB_COUNT || !sources[source] || ramps[source].silent()) return 0.f;
    return sources[source]->hz();
}

void Ambience::triggerThunder(float distance) { thunder->trigger(distance); }

void Ambience::queueThunder(float delaySeconds, float strength) {
    if (ramps[ISD_AMB_THUNDER_ROLL].to <= 0.f) return;   // silent, or fading out as the world changes
    thunderRoll->enqueue(delaySeconds, strength, (float)sr);
}

void Ambience::clearThunder() { thunderRoll->clearQueue(); clearEvents(); }

void Ambience::allSoundOff() {
    thunderRoll->silence((float)sr);
    thunder->silence((float)sr);
    clearEvents();
    for (auto &src : sources) if (src) src->silence((float)sr);
}

void Ambience::triggerNow(int source) {
    if (source < 0 || source >= ISD_AMB_COUNT || !sources[source]) return;
    if (ramps[source].silent()) sources[source]->wake(ctx);
    sources[source]->triggerNow(ctx);
}

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

void Ambience::strikeChime() {
    if (ramps[ISD_AMB_CHIME].silent()) chime->wake(ctx);
    chime->strikeNow(ctx);
}

float Ambience::chimeRingingHz() const { return ramps[ISD_AMB_CHIME].silent() ? 0.f : chime->ringingHz(); }

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
        deliverEvents(n);
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
    ctx.lakeSurge += (lakeSurgeTarget - ctx.lakeSurge) * slow;
    ctx.lakeGlow += (lakeGlowTarget - ctx.lakeGlow) * slow;
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
        sources[i]->levelTarget = r.to;
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
    std::atomic<int> key{4 | 16};   // root | (major << 4) | 32 once sensed: E major, unsensed, until the player's key is
    std::atomic<int> chimeSeq{0};
    int chimeSeen = 0;
    std::atomic<float> chimeHz{0.f};   // after each render: the chime's newest ringing strike, 0 while none rings
    std::atomic<int> bellSeq{0}, knockerSeq{0}, warblerSeq{0};
    int bellSeen = 0, knockerSeen = 0, warblerSeen = 0;
    std::atomic<float> bellHz{0.f};   // after each render: the bell's ringing fundamental, 0 while it is silent
    std::atomic<float> bubbleStrength{0.5f};
    std::atomic<int> bubbleSeq{0}, sonarSeq{0}, whaleSeq{0};
    int bubbleSeen = 0, sonarSeen = 0, whaleSeen = 0;
    std::atomic<float> sonarHz{0.f};   // after each render: the sonar's ringing ping, 0 while it is silent
    // Thunder on its way: a mailbox of 32 from any thread to the render (each slot's ticket is its index + 1 once
    // written), drained in order at the start of each render; overrun, the oldest are lost. A clear or an all-sound-off
    // drops everything posted before it.
    static constexpr uint32_t kThunderMail = 32;
    struct ThunderMail { std::atomic<uint32_t> ticket{0}; std::atomic<float> delay{0.f}, strength{0.f}; } thunderMail[kThunderMail];
    std::atomic<uint32_t> thunderHead{0}, thunderClearAt{0}, allOffAt{0};
    std::atomic<int> thunderClearSeq{0}, allOffSeq{0};
    uint32_t thunderTail = 0;
    int thunderClearSeen = 0, allOffSeen = 0;
    std::atomic<int> triggerSeq[ISD_AMB_COUNT];
    int triggerSeen[ISD_AMB_COUNT];
    // The world's one-shots (Fire & Neon): a mailbox of 64 like the thunder's, cleared by the same marks.
    static constexpr uint32_t kEventMail = 64;
    struct EventMail {
        std::atomic<uint32_t> ticket{0};
        std::atomic<int> source{0}, kind{0};
        std::atomic<float> delay{0.f}, strength{0.f}, pan{0.f}, speed{0.f}, distance{0.f};
    } eventMail[kEventMail];
    std::atomic<uint32_t> eventHead{0}, eventClearAt{0}, eventAllOffAt{0};
    uint32_t eventTail = 0;
    std::atomic<float> lakeSurge{0.f}, lakeGlow{0.f};
    std::atomic<float> hz[ISD_AMB_COUNT];   // after each render: each tonal source's pitch, 0 while silent
    ISDAmbience(double sr, uint64_t seed) : engine(sr, seed) {
        for (int i = 0; i < ISD_AMB_COUNT; ++i) { levels[i].store(0.f); applied[i] = 0.f; triggerSeq[i].store(0); triggerSeen[i] = 0; hz[i].store(0.f); }
    }
    /// Render thread: skips every one-shot posted before `at` (a clear's or a panic's mark).
    void skipEventsBefore(uint32_t at) { if ((int32_t)(at - eventTail) > 0) eventTail = at; }
    /// Render thread: hands the posted one-shots to the engine, oldest first.
    void drainEvents() {
        const uint32_t head = eventHead.load(std::memory_order_acquire);
        if (head - eventTail > kEventMail) eventTail = head - kEventMail;
        while (eventTail != head) {
            EventMail &m = eventMail[eventTail % kEventMail];
            const uint32_t want = eventTail + 1, ticket = m.ticket.load(std::memory_order_acquire);
            if (ticket != want) {
                if ((int32_t)(ticket - want) > 0) { ++eventTail; continue; }
                break;
            }
            isd::AmbienceEvent e;
            const int source = m.source.load(std::memory_order_relaxed);
            const float delay = m.delay.load(std::memory_order_relaxed);
            e.strength = m.strength.load(std::memory_order_relaxed); e.pan = m.pan.load(std::memory_order_relaxed);
            e.speed = m.speed.load(std::memory_order_relaxed); e.distance = m.distance.load(std::memory_order_relaxed);
            e.kind = m.kind.load(std::memory_order_relaxed);
            if (m.ticket.load(std::memory_order_acquire) == want) engine.postEvent(source, delay, e);
            ++eventTail;
        }
    }
    /// Render thread: skips everything posted before `at` (a clear's mark).
    void skipThunderBefore(uint32_t at) { if ((int32_t)(at - thunderTail) > 0) thunderTail = at; }
    /// Render thread: hands the posted rolls to the engine, oldest first.
    void drainThunder() {
        const uint32_t head = thunderHead.load(std::memory_order_acquire);
        if (head - thunderTail > kThunderMail) thunderTail = head - kThunderMail;   // overrun: the oldest are gone
        while (thunderTail != head) {
            ThunderMail &m = thunderMail[thunderTail % kThunderMail];
            const uint32_t want = thunderTail + 1, ticket = m.ticket.load(std::memory_order_acquire);
            if (ticket != want) {
                if ((int32_t)(ticket - want) > 0) { ++thunderTail; continue; }   // written over by a newer one: lost
                break;                                                           // still being written: next render
            }
            const float delay = m.delay.load(std::memory_order_relaxed), strength = m.strength.load(std::memory_order_relaxed);
            if (m.ticket.load(std::memory_order_acquire) == want) engine.queueThunder(delay, strength);
            ++thunderTail;
        }
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

void isd_ambience_queue_thunder(ISDAmbience *a, float delaySeconds, float strength) {
    if (!a || !std::isfinite(delaySeconds) || !std::isfinite(strength)) return;
    const uint32_t i = a->thunderHead.fetch_add(1, std::memory_order_acq_rel);
    ISDAmbience::ThunderMail &m = a->thunderMail[i % ISDAmbience::kThunderMail];
    m.delay.store(std::clamp(delaySeconds, 0.f, 12.f), std::memory_order_relaxed);
    m.strength.store(isd::clamp01(strength), std::memory_order_relaxed);
    m.ticket.store(i + 1, std::memory_order_release);
}

void isd_ambience_clear_thunder(ISDAmbience *a) {
    if (!a) return;
    a->thunderClearAt.store(a->thunderHead.load(std::memory_order_acquire), std::memory_order_relaxed);
    a->eventClearAt.store(a->eventHead.load(std::memory_order_acquire), std::memory_order_relaxed);
    a->thunderClearSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_all_sound_off(ISDAmbience *a) {
    if (!a) return;
    a->allOffAt.store(a->thunderHead.load(std::memory_order_acquire), std::memory_order_relaxed);
    a->eventAllOffAt.store(a->eventHead.load(std::memory_order_acquire), std::memory_order_relaxed);
    a->allOffSeq.fetch_add(1, std::memory_order_release);
}

void isd_ambience_post_event(ISDAmbience *a, ISDAmbienceSource source, float delaySeconds, float strength, float pan, float speed,
                             float distance, int kind) {
    if (!a || (int)source < 0 || (int)source >= ISD_AMB_COUNT) return;
    for (float v : {delaySeconds, strength, pan, speed, distance}) if (!std::isfinite(v)) return;
    const uint32_t i = a->eventHead.fetch_add(1, std::memory_order_acq_rel);
    ISDAmbience::EventMail &m = a->eventMail[i % ISDAmbience::kEventMail];
    m.source.store((int)source, std::memory_order_relaxed);
    m.delay.store(std::clamp(delaySeconds, 0.f, 12.f), std::memory_order_relaxed);
    m.strength.store(isd::clamp01(strength), std::memory_order_relaxed);
    m.pan.store(std::clamp(pan, -1.f, 1.f), std::memory_order_relaxed);
    m.speed.store(std::clamp(speed, 0.f, 200.f), std::memory_order_relaxed);
    m.distance.store(std::clamp(distance, 0.f, 100.f), std::memory_order_relaxed);
    m.kind.store(kind, std::memory_order_relaxed);
    m.ticket.store(i + 1, std::memory_order_release);
}

void isd_ambience_set_lake(ISDAmbience *a, float surge, float glow) {
    if (!a || !std::isfinite(surge) || !std::isfinite(glow)) return;
    a->lakeSurge.store(isd::clamp01(surge), std::memory_order_relaxed);
    a->lakeGlow.store(isd::clamp01(glow), std::memory_order_relaxed);
}

float isd_ambience_debug_hz(const ISDAmbience *a, ISDAmbienceSource source) {
    if (!a || (int)source < 0 || (int)source >= ISD_AMB_COUNT) return 0.f;
    return a->hz[source].load(std::memory_order_acquire);
}

void isd_ambience_debug_trigger(ISDAmbience *a, ISDAmbienceSource source) {
    if (!a || (int)source < 0 || (int)source >= ISD_AMB_COUNT) return;
    a->triggerSeq[source].fetch_add(1, std::memory_order_release);
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
    a->key.store(root | (major ? 16 : 0) | 32, std::memory_order_relaxed);   // 32: a key has been sensed (the chime)
}

void isd_ambience_debug_strike_bell(ISDAmbience *a) { if (a) a->bellSeq.fetch_add(1, std::memory_order_release); }
void isd_ambience_debug_strike_chime(ISDAmbience *a) { if (a) a->chimeSeq.fetch_add(1, std::memory_order_release); }
float isd_ambience_debug_chime_hz(const ISDAmbience *a) { return a ? a->chimeHz.load(std::memory_order_acquire) : 0.f; }
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
    a->engine.setKey(key & 15, (key & 16) != 0, (key & 32) != 0);   // before any strike this render: a new key waits for the next strike
    const int bells = a->bellSeq.load(std::memory_order_acquire);
    if (bells != a->bellSeen) { a->bellSeen = bells; a->engine.strikeBell(); }
    const int chimes = a->chimeSeq.load(std::memory_order_acquire);
    if (chimes != a->chimeSeen) { a->chimeSeen = chimes; a->engine.strikeChime(); }
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
    // Thunder: a panic or a world switch first (each drops what was posted before it), then what is on its way, after
    // the levels (a roll is heard only while the thunder roll is up).
    const int offs = a->allOffSeq.load(std::memory_order_acquire);
    if (offs != a->allOffSeen) {
        a->allOffSeen = offs;
        a->engine.allSoundOff();
        a->skipThunderBefore(a->allOffAt.load(std::memory_order_relaxed));
        a->skipEventsBefore(a->eventAllOffAt.load(std::memory_order_relaxed));
    }
    const int clears = a->thunderClearSeq.load(std::memory_order_acquire);
    if (clears != a->thunderClearSeen) {
        a->thunderClearSeen = clears;
        a->engine.clearThunder();
        a->skipThunderBefore(a->thunderClearAt.load(std::memory_order_relaxed));
        a->skipEventsBefore(a->eventClearAt.load(std::memory_order_relaxed));
    }
    a->drainThunder();
    a->engine.setLake(a->lakeSurge.load(std::memory_order_relaxed), a->lakeGlow.load(std::memory_order_relaxed));
    a->drainEvents();   // after the levels: a source hears its one-shots only while it is up
    for (int i = 0; i < ISD_AMB_COUNT; ++i) {
        const int asked = a->triggerSeq[i].load(std::memory_order_acquire);
        if (asked != a->triggerSeen[i]) { a->triggerSeen[i] = asked; a->engine.triggerNow(i); }
    }
    a->engine.render(left, right, frames);
    a->bellHz.store(a->engine.bellRingingHz(), std::memory_order_release);
    a->chimeHz.store(a->engine.chimeRingingHz(), std::memory_order_release);
    a->sonarHz.store(a->engine.sonarRingingHz(), std::memory_order_release);
    for (int i = ISD_AMB_VENT_RUMBLE; i < ISD_AMB_COUNT; ++i) a->hz[i].store(a->engine.sourceHz(i), std::memory_order_release);
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
