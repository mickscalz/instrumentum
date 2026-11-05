// The Shepard–Risset riser (spec §4.1 of docs/superpowers/specs/2026-11-05-storms-design.md; brief
// docs/superpowers/briefs/endless-rise.md): a climb that never arrives, on the analogue voice core's band-limited saw
// (AnalogVoice.hpp). Header-only, in namespace isd::shepard. Endless Rise layers it over its pad; nothing here
// allocates, and every stack is plain data run per sample on the render thread.
//
// How it never arrives
//   A stack is eight band-limited saws an octave apart. Their pitches climb together at `rate` octaves a second (φ);
//   their loudness follows a raised cosine, w(x) = 0.5 − 0.5·cos(2πx), over each voice's place x on a log-frequency
//   axis. The window spans exactly eight octaves, 43.3 Hz to 11.09 kHz (centred, geometrically, on the spec's 40 Hz
//   to 12 kHz, and inside it), so the voice climbing out of the top meets w = 0 at the very moment a new one enters the
//   bottom at w = 0: the stack re-indexes there and nothing jumps. Because the eight places are evenly spaced around
//   one period of the window, Σw² is exactly 3 at every φ (and so is every sum of products of two windows a fixed
//   number of octaves apart), so the power is constant as it climbs, coherent octave partials included.
//   Every voice of a stack is phase-locked to one master phase Φ (voice m's saw sits at frac(2^m·Φ + θ)): each pair
//   of octaves keeps the same phase relation for ever, so their interference never beats the loudness. θ = 1/16 of a
//   cycle: the octaves' coincident partials then mostly reinforce (the stack is 1.8 dB above an incoherent sum, full
//   rather than hollow; at ½ they cancel, −5.9 dB), no two voices' edges ever land together ((2^d − 1)·θ is never
//   whole), and the largest sample step is the smallest against the RMS (0.88×; aligned edges give 3.2×). At the
//   re-index the master phase halves (or doubles, going down), which leaves every voice's own phase where it was.
//   Stacks belong to pitch classes, not keys: a Shepard tone is octave-blind, so A2 and A4 held together share one
//   stack (two would sit on the same frequencies and interfere). Every stack climbs on one shared φ, so a chord stays
//   a chord; a phrase starts φ at 0, so the riser begins on the chord's own pitches.
// The tension law
//   climbRate(rise, tension) = rise × (1 + 3·tension). Tension also leans the window up by 2.5 dB an octave at 1 (its
//   ends still zero, its power still normalised to 3), so the gathering climbs faster and brighter.
// The drop (drop())
//   The climb stops and φ settles on the nearest whole octave over 120 ms, so every stack lands on its own notes (a
//   resolution in tune with the pad, not a chord frozen up to six semitones off it). In the same 120 ms the window
//   narrows from eight octaves to one around each stack's home (its lowest held note) and every saw folds into its
//   own fundamental: the riser collapses into the chord's fundamentals as sines, its power held while the window
//   narrows. Then it fades: −40 dB at 2.5 s, and silence from there. Its stacks stay silent (resolved) until a new
//   key goes down, when every held stack climbs again from where the drop left it.
// The hold rule (press/letGo)
//   A stack sounds only while a key of its class is held or pedalled: in over 0.4 s, gone in 200 ms (−60 dB).
//
// API (render thread)
//   Riser::prepare(sr); press(pc, homePitch, gain); setHome(pc, homePitch); letGo(pc); drop(); fadeAll(seconds);
//   render(l, r, n, Controls) adds n ≤ kMaxBlock samples.
#pragma once
#include "AnalogVoice.hpp"
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

// The 8-lane helpers below are always inlined, so no vector values cross a call boundary (as in PianoStrings.hpp).
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wpsabi"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wpsabi"
#endif

namespace isd {
namespace shepard {

/// A stack's eight voices side by side (GCC/Clang vector extensions: AVX, two SSE halves, or NEON).
typedef float f8 __attribute__((vector_size(32)));
typedef int32_t i8 __attribute__((vector_size(32)));
__attribute__((always_inline)) inline f8 load8(const float *p) { f8 v; std::memcpy(&v, p, sizeof v); return v; }
__attribute__((always_inline)) inline void store8(float *p, f8 v) { std::memcpy(p, &v, sizeof v); }
__attribute__((always_inline)) inline float sum8(f8 v) { return ((v[0] + v[4]) + (v[1] + v[5])) + ((v[2] + v[6]) + (v[3] + v[7])); }
/// frac(x) for x ≥ 0 (truncation is the floor there).
__attribute__((always_inline)) inline f8 frac8(f8 x) { return x - __builtin_convertvector(__builtin_convertvector(x, i8), f8); }
/// max(x, 0).
__attribute__((always_inline)) inline f8 relu8(f8 x) { const f8 z = {}; return (f8)((i8)x & (i8)(x > z)); }
/// The branch-free BLEP residual (blep below) on eight lanes.
__attribute__((always_inline)) inline f8 blep8(f8 d) {
    f8 a = relu8(2.f - d), b = relu8(1.f - d);
    a *= a;
    b *= b;
    return (a * a - 4.f * b * b) * (1.f / 24.f);
}

constexpr int kVoices = 8;                         // per stack, an octave apart
constexpr int kStacks = 12;                        // one per pitch class
constexpr double kLowHz = 43.301270189221932;      // the window's bottom: √(40 Hz · 12 kHz) / 2⁴
constexpr float kRiserGain = 1.f;                  // a stack's RMS at w-sum 3 (Σw² = 3, saws at 1/√3 RMS)
constexpr float kTensionGain = 3.f;                // rate × (1 + 3·tension)
constexpr float kTensionTilt = 2.5f;               // dB an octave the window leans up at tension 1 (brighter, power held)
constexpr float kSawOffset = 0.0625f;              // θ: a sixteenth of a cycle (see the header's comment)
constexpr float kCollapseSeconds = 0.12f;          // the drop's resolution
constexpr float kDropSeconds = 2.5f;               // the drop's fade (to −40 dB)
constexpr float kFadeDb = -40.f;
constexpr float kAttackSeconds = 0.4f, kReleaseSeconds = 0.2f;   // the hold rule: in, and gone (−60 dB)
constexpr float kPowerSum = 3.f;                   // Σ w² over eight evenly spaced places of the raised cosine
constexpr float kScale[kVoices] = {1.f, 2.f, 4.f, 8.f, 16.f, 32.f, 64.f, 128.f};   // voice m runs at 2^m × the bottom's

/// The climb's rate in octaves a second: Rise × (1 + 3·tension).
inline float climbRate(float rise, float tension) { return rise * (1.f + kTensionGain * clamp01(tension)); }

inline float smoothstep01(float t) { t = clamp01(t); return t * t * (3.f - 2.f * t); }

/// The window at place x (0…1 over the eight octaves): cos²(π(x − centre)/width) within ±width/2 of the centre, else
/// 0. At centre 0.5 and width 1 it is the plain raised cosine 0.5 − 0.5·cos(2πx); the drop narrows it.
inline float window(float x, float centre, float width) {
    const float d = (x - centre) / width;
    if (d <= -0.5f || d >= 0.5f) return 0.f;
    const float c = std::cos(kPi * d);
    return c * c;
}

/// The riser's level t seconds after a drop: a fade straight in dB to −40 dB at 2.5 s, tapered (raised cosine) to
/// exactly 0 over its last 0.3 s.
inline float dropFade(float t) {
    if (t <= 0.f) return 1.f;
    if (t >= kDropSeconds) return 0.f;
    float g = std::exp2(kFadeDb * 0.16609640f * t / kDropSeconds);   // 10^(dB/20 · t/T)
    const float taperFrom = kDropSeconds - 0.3f;
    if (t > taperFrom) { const float c = std::cos(0.5f * kPi * (t - taperFrom) / 0.3f); g *= c * c; }
    return g;
}

/// A band-limited saw (−1…1, falling edge at the wrap) as analog::saw, with the increment's reciprocal given.
inline float saw(float p, float inc, float invInc) {
    float v = 2.f * p - 1.f;
    if (p < 2.f * inc) v += 2.f * analog::blepResidual(p * invInc);
    else if (p > 1.f - 2.f * inc) v -= 2.f * analog::blepResidual((1.f - p) * invInc);
    return v;
}

/// analog::blepResidual for any d ≥ 0 (zero from 2 samples on), without a branch: the cubic B-spline's residual in
/// truncated powers, ((2 − d)₊⁴ − 4·(1 − d)₊⁴) / 24, which expands to the core's two pieces exactly.
inline float blep(float d) {
    float a = std::max(2.f - d, 0.f), b = std::max(1.f - d, 0.f);
    a *= a;
    b *= b;
    return (a * a - 4.f * b * b) * (1.f / 24.f);
}

/// The fundamental of saw(p): −(2/π)·sin(2πp), in phase with it.
inline float fundamental(float p) { return -0.63661977f * std::sin(kTwoPi * p); }

class Riser {
public:
    static constexpr int kMaxBlock = 64;

    /// What the engine gives every block.
    struct Controls {
        float rise = 0.08f;        // octaves a second at tension 0 (0: no climb)
        float tension = 0.f;       // 0…1, smoothed by the caller
        float bendOct = 0.f;       // the wheel, in octaves
        float fineOct = 0.f;       // fine tune, in octaves
        float level = 1.f;         // the riser's gain (dial, velocity curve and mood folded in by the caller)
        float width = 0.6f;        // 0…1: each stack's place across the field, and the octaves' spread around it
    };

    void prepare(double sampleRate) {
        sr = sampleRate;
        // The guard: no voice reaches 0.235·sr (the saw's band-limiting needs an increment ≤ 0.24). Above 48 kHz it
        // starts above the window's top and changes nothing.
        guardHi = (float)(0.235 * sr);
        guardLo = 0.8f * guardHi;
        for (auto &s : stacks) s = Stack{};
        phi = 0.0;
        dropAge = 0.f;
        isDropping = false;
    }

    /// A key of pitch class `pc` went down. `homePitch`: the lowest held pitch (MIDI, fractional) of the class, where a
    /// drop lands it; `gain` its velocity's. A phrase (nothing sounding) starts the climb at φ = 0; a key after a drop
    /// has finished wakes every resolved stack.
    void press(int pc, float homePitch, float gain) {
        pc = ((pc % kStacks) + kStacks) % kStacks;
        bool any = false;
        for (const auto &s : stacks) if (s.active) { any = true; break; }
        if (!any && !isDropping) phi = 0.0;
        if (!isDropping) {
            for (auto &s : stacks) if (s.active && s.resolved && !s.fading) { s.resolved = false; s.env.clear(); s.env.trigger(1.f); }
        }
        Stack &s = stacks[pc];
        if (!s.active || s.fading) {
            s = Stack{};
            s.active = true;
            s.env.setAttack(kAttackSeconds, (float)sr);
            s.env.setSustain(1.f);
            s.env.setDecay(1.f, (float)sr);
            s.env.setRelease(kReleaseSeconds, (float)sr);
            s.phase = 0.0;
            s.gain = gain;
            s.based = false;
        }
        s.target = gain;
        s.held = true;
        setHome(pc, homePitch);
        s.env.trigger(1.f);
    }

    /// The class's home: its lowest held pitch (MIDI, fractional), where a drop lands it.
    void setHome(int pc, float homePitch) {
        Stack &s = stacks[((pc % kStacks) + kStacks) % kStacks];
        const double oct = std::log2(440.0 / kLowHz) + ((double)homePitch - 69.0) / 12.0;
        s.homeOct = (float)oct;
        s.classOct = (float)(oct - std::floor(oct));
    }

    /// No key of `pc` is held or pedalled now: its stack is gone in 200 ms.
    void letGo(int pc) {
        Stack &s = stacks[((pc % kStacks) + kStacks) % kStacks];
        if (!s.active) return;
        s.held = false;
        s.env.release();
    }

    /// Every stack fades out over `seconds` (all notes off), and the drop is over.
    void fadeAll(float seconds) {
        for (auto &s : stacks) {
            if (!s.active || s.fading) continue;
            s.fading = true;
            s.fadeStep = 1.f / std::max(1.f, seconds * (float)sr);
        }
        isDropping = false;
        dropAge = 0.f;
    }

    /// The drop: the climb stops, φ settles on the nearest octave and the window collapses onto each stack's home
    /// over 120 ms, then the riser fades to −40 dB at 2.5 s. The caller decides whether a drop is taken.
    void drop() {
        isDropping = true;
        dropAge = 0.f;
        phiFrom = phi;
        phiTo = std::floor(phi + 0.5);
    }

    void render(float *l, float *r, int n, const Controls &c) {
        n = std::min(n, kMaxBlock);
        const float dt = (float)n / (float)sr;
        // The climb (or the drop's settle), the collapse and the fade, at this block's start and end.
        const double phi0 = phi;
        const float age0 = dropAge;
        float c0 = 0.f, c1 = 0.f, f0 = 1.f, f1 = 1.f;
        if (isDropping) {
            dropAge += dt;
            c0 = smoothstep01(age0 / kCollapseSeconds);
            c1 = smoothstep01(dropAge / kCollapseSeconds);
            phi = phiFrom + (phiTo - phiFrom) * (double)c1;
            f0 = dropFade(age0);
            f1 = dropFade(dropAge);
            if (dropAge >= kDropSeconds) {
                // The drop is over: every stack sounding through it stays silent until a key wakes it.
                isDropping = false;
                dropAge = 0.f;
                phi = phiTo;
                for (auto &s : stacks) if (s.active) s.resolved = true;
            }
        } else {
            // The climb runs while a stack is heard (resolved stacks wait where the drop left them).
            bool audible = false;
            for (const auto &s : stacks) if (s.active && !s.resolved) { audible = true; break; }
            if (audible) phi += (double)climbRate(std::max(0.f, c.rise), c.tension) * (double)dt;
            if (phi >= 1024.0) {   // keep the climb small; every stack's octave count follows it
                phi -= 1024.0;
                for (auto &s : stacks) s.base -= 1024;
            }
        }
        const double shift = (double)c.bendOct + (double)c.fineOct;
        const float tilt = kTensionTilt * clamp01(c.tension) / 6.0205999f;   // octaves of gain per octave
        const Block b{phi0 + shift, phi + shift, c0, c1, f0, f1, c.level, c.width, lastTilt, tilt};
        lastTilt = tilt;
        for (int i = 0; i < kStacks; ++i) {
            Stack &s = stacks[i];
            if (!s.active) continue;
            renderStack(s, i, l, r, n, b);
        }
    }

private:
    struct Stack {
        bool active = false, held = false, fading = false, resolved = false, based = false;
        double phase = 0.0;       // Φ: the bottom voice's phase, 0…1
        long long base = 0;       // the octave count of the bottom voice's place at the last block
        float classOct = 0.f;     // the class's place within an octave above kLowHz, 0…1
        float homeOct = 0.f;      // log2(home / kLowHz): where the drop lands
        float gain = 0.f, target = 0.f;
        analog::ADSR env;
        float fadeGain = 1.f, fadeStep = 0.f;
    };
    struct Block { double pos0, pos1; float c0, c1, f0, f1, level, width, tilt0, tilt1; };

    /// The window's centre and width for a stack at collapse c: from the whole window to one octave around its home.
    static void shape(const Stack &s, float c, float &centre, float &width) {
        float home = s.homeOct;
        while (home < 0.5f) home += 1.f;   // keep the home voice at least half an octave inside the window
        while (home > 7.5f) home -= 1.f;
        centre = 0.5f + (home / 8.f - 0.5f) * c;
        width = std::exp2(-3.f * c);
    }

    float guard(float hz) const {
        if (hz <= guardLo) return 1.f;
        if (hz >= guardHi) return 0.f;
        return 1.f - smoothstep01((hz - guardLo) / (guardHi - guardLo));
    }

    /// The eight voices' weights at place u (the bottom voice's place in its octave, relative to the stack's base),
    /// leaned by `tilt` (octaves of gain per octave, about the window's centre) and normalised so their squares sum to
    /// 3 (Σw² of the plain window): constant power as it climbs, and the power held while the drop narrows the window.
    void weights(const Stack &s, float u, float c, float tilt, float *w) const {
        float centre, width;
        shape(s, c, centre, width);
        float sum = 0.f;
        const float bottomHz = (float)(kLowHz * std::exp2((double)u));
        for (int m = 0; m < kVoices; ++m) {
            const float x = (u + (float)m) / 8.f;
            float v = 0.f;
            if (x > 0.f && x < 1.f) {
                v = window(x, centre, width) * guard(bottomHz * (float)(1 << m));
                if (tilt != 0.f) v *= std::exp2(tilt * (8.f * x - 4.f));
            }
            w[m] = v;
            sum += v * v;
        }
        const float norm = sum > 1e-9f ? std::min(2.f, std::sqrt(kPowerSum / std::max(sum, 0.25f))) : 0.f;
        for (int m = 0; m < kVoices; ++m) w[m] *= norm;
    }

    void renderStack(Stack &s, int pc, float *l, float *r, int n, const Block &b) {
        // Where the bottom voice is: the class's place plus the climb (and the wheel and fine tune).
        const double raw0 = (double)s.classOct + b.pos0, raw1 = (double)s.classOct + b.pos1;
        const long long whole = (long long)std::floor(raw0);
        if (!s.based) { s.base = whole; s.based = true; }
        // Re-index at the block's start. Climbing: the bottom voice has reached twice the window's bottom, so the top
        // one (at w = 0) leaves and a new bottom one (at w = 0) enters: Φ halves, and every voice keeps its phase.
        while (whole > s.base) { s.phase *= 0.5; ++s.base; }
        while (whole < s.base) { s.phase += s.phase; if (s.phase >= 1.0) s.phase -= 1.0; --s.base; }
        const float u0 = (float)(raw0 - (double)s.base), u1 = (float)(raw1 - (double)s.base);
        if (s.resolved && !s.fading) {   // silent since a drop: only its hold envelope runs
            for (int t = 0; t < n; ++t) s.env.next();
            if (!s.held && s.env.idle()) s.active = false;
            return;
        }

        // Gains at the block's start and end: velocity (gliding), the riser's level and the drop's fade.
        const float g0 = s.gain;
        s.gain += (1.f - std::exp(-(float)n / (0.02f * (float)sr))) * (s.target - s.gain);
        const float lv0 = s.resolved ? 0.f : g0 * b.level * b.f0 * kRiserGain;
        const float lv1 = s.resolved ? 0.f : s.gain * b.level * b.f1 * kRiserGain;
        float w0[kVoices], w1[kVoices];
        weights(s, u0, b.c0, b.tilt0, w0);
        weights(s, u1, b.c1, b.tilt1, w1);

        // The octaves spread around the stack's place, as they climb (two swings across the window).
        const float place = (float)((pc * 7) % 12) / 5.5f - 1.f;
        float a[kVoices], da[kVoices], gl[kVoices], gr[kVoices], invInc[kVoices];
        bool on[kVoices];
        bool any = false;
        const float invN = 1.f / (float)n;
        float incB = (float)(kLowHz * std::exp2((double)u0) / sr);
        for (int m = 0; m < kVoices; ++m) {
            a[m] = w0[m] * lv0;
            da[m] = (w1[m] * lv1 - a[m]) * invN;
            on[m] = a[m] > 0.f || w1[m] * lv1 > 0.f;
            any = any || on[m];
            const float xm = (0.5f * (u0 + u1) + (float)m) / 8.f;
            const float pan = std::clamp(b.width * (-0.45f * place + 0.35f * std::sin(2.f * kTwoPi * xm)), -1.f, 1.f);
            gl[m] = std::sqrt(0.5f * (1.f - pan));
            gr[m] = std::sqrt(0.5f * (1.f + pan));
            invInc[m] = 1.f / (incB * (float)(1 << m));
        }
        const float ratio = std::exp2((u1 - u0) * invN);
        const f8 scale = load8(kScale), iv = load8(invInc), glv = load8(gl), grv = load8(gr), dav = load8(da);
        f8 av = load8(a);
        float tim = b.c0;
        const float dtim = (b.c1 - b.c0) * invN;

        for (int t = 0; t < n; ++t) {
            float yl = 0.f, yr = 0.f;
            if (any) {
                // Every voice's phase from the master's: frac(2^m·Φ + θ). Scaling by a power of two is exact, and Φ in
                // float costs the top voice 4·10⁻⁶ of a cycle.
                const float ph = (float)s.phase;
                if (tim <= 0.f) {
                    // Climbing: the eight saws side by side, without a branch.
                    const f8 q = frac8(frac8(ph * scale) + kSawOffset);
                    const f8 v = 2.f * q - 1.f + 2.f * (blep8(q * iv) - blep8((1.f - q) * iv));
                    const f8 o = av * v;
                    av += dav;
                    yl = sum8(o * glv);
                    yr = sum8(o * grv);
                } else {
                    // The drop's collapse: each saw folds into its own fundamental.
                    float amp[kVoices];
                    store8(amp, av);
                    av += dav;
                    float inc = incB;
                    for (int m = 0; m < kVoices; ++m, inc += inc) {
                        if (!on[m]) continue;
                        float q = ph * kScale[m];
                        q -= (float)(int)q;
                        q += kSawOffset;
                        if (q >= 1.f) q -= 1.f;
                        float v;
                        if (tim >= 1.f) v = fundamental(q);
                        else { const float sv = saw(q, inc, invInc[m]); v = sv + tim * (fundamental(q) - sv); }
                        const float y = amp[m] * v;
                        yl += y * gl[m];
                        yr += y * gr[m];
                    }
                    tim += dtim;
                }
            }
            s.phase += (double)incB;
            if (s.phase >= 1.0) s.phase -= 1.0;
            incB *= ratio;
            float e = s.env.next();
            if (s.fading) {
                s.fadeGain = std::max(0.f, s.fadeGain - s.fadeStep);
                e *= s.fadeGain;
            }
            l[t] += yl * e;
            r[t] += yr * e;
        }
        if ((s.fading && s.fadeGain <= 0.f) || (!s.held && s.env.idle())) s.active = false;
    }

    double sr = 48000.0;
    Stack stacks[kStacks];
    double phi = 0.0;              // the shared climb, octaves
    double phiFrom = 0.0, phiTo = 0.0;
    float dropAge = 0.f;
    bool isDropping = false;
    float lastTilt = 0.f;
    float guardLo = 9024.f, guardHi = 11280.f;
};

} // namespace shepard
} // namespace isd
