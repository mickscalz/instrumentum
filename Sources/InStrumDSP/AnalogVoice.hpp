// The analogue voice core: the parts of a vintage polysynth voice (spec §4.1 of
// docs/superpowers/specs/2026-11-04-sets-11-12-design.md). Blue Depth is the first instrument built on it;
// Replicant Brass, Juno Prayer and the anthem voices reuse it later. Header-only, in namespace isd::analog (so
// its short names never meet another core's). Nothing here allocates: every part is plain data, set up when a
// voice starts and then run per sample (or once per block, where noted) on the render thread. Two oscillators,
// the sub, noise, the ladder, the high-pass and two envelopes come to about 120–160 cycles per voice per sample.
//
// API
//   Oscillators. A phase runs 0…1 and an increment is Hz / sample rate, kept at or below kMaxIncrement (0.24) so
//   an edge's correction never meets the next edge. Every edge is band-limited by a 4-point (cubic B-spline)
//   polyBLEP: the waveform is the ideal one convolved with that kernel, so nothing is added beyond the edges.
//     float saw(p, inc)            a band-limited saw, −1…1, falling edge at the wrap.
//     ShapeOsc                     oscillator A. setShape(s) morphs continuously from saw (0) through square (0.5)
//                                  to a narrow 8% pulse (1): saw(p) − k·saw(p + w), so it never has DC. next(inc)
//                                  returns it; nextWithSub(inc) also sets `sub`, the sub-octave square taken from
//                                  A's own phase (it flips at every second wrap, so it is locked to A); skip(n, inc)
//                                  advances a silent voice. fundamentalGain(s): A's fundamental against a plain
//                                  saw's, for centring a detuned pair on the note.
//     SawOsc                       oscillator B: a plain saw. Detune it through its increment.
//     Noise                        white noise, −1…1, seeded.
//   Slop, the gentle unsteadiness of an analogue poly (seeded per voice, so a seed always plays the same):
//     Slop::seed(s); advance(seconds) once per block; pitchCents(i, depth) for oscillator i = 0, 1 (±3 cents ×
//     depth) and cutoffRatio(depth) (1 ± 1% × depth). Each rides its own smoothed random walk at 0.1–0.4 Hz.
//   Filters:
//     Ladder                       4-pole (24 dB/oct) zero-delay-feedback low-pass: four TPT one-poles solved in
//                                  one step, with a tanh in the feedback so resonance stays soft. setResonance(r),
//                                  r 0…0.95, below self-oscillation; the passband level holds as r rises.
//                                  setCutoff(hz, sr, n) once per block glides to the new cutoff (clamped to 20 Hz–
//                                  18 kHz and 0.45·sr) across the next n samples; snapCutoff jumps; process(x).
//     float keyTrack(noteHz, a)    the cutoff factor for key tracking a (0…1): (noteHz / 261.63 Hz)^a.
//     HighPass                     a 2-pole state-variable (TPT) high-pass, to clear low mud. set(hz, q, sr).
//     BandPass                     a state-variable band-pass with unity gain at its centre.
//     TwoFormant                   two band-passes with gliding centres, for voice-like layers. reset(f1, f2),
//                                  setGains(g1, g2) (give g2 the opposite sign, as parallel formant synthesis does,
//                                  so the pair adds between its centres; with both positive the pair dips between
//                                  them instead and never turns a signal it is mixed with against itself, as Single
//                                  Note Grand's crossfade needs), setBandwidths(b1, b2) (constant bandwidths in Hz in
//                                  place of the shared q), setTargets(f1, f2), update(glide, sr) once
//                                  per block (glide 0…1: the share of the way, in octaves, each centre moves this
//                                  block), process(x). response(f, re, im) / responseAt(f): the pair's gain at f, for
//                                  levelling a layer whose pitch moves against the formants (a pair cancels above
//                                  its upper centre, so such a layer wants a small direct path beside it).
//   Envelopes:
//     ADSR                         setAttack/setDecay/setRelease(seconds, sr), setSustain(fraction of the peak).
//                                  trigger(peak) starts the attack from wherever the level is now, so a retrigger
//                                  never clicks; release(); next() per sample. The attack is a straight line at a
//                                  fixed slope (peak per attack time); decay and release are exponential, each
//                                  stage's time being its −60 dB time.
//   Helpers: tanhApprox(x), a rational tanh that is exactly ±1 beyond ±3.
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace isd {
namespace analog {

constexpr float kMaxIncrement = 0.24f;
constexpr float kMinCutoff = 20.f, kMaxCutoff = 18000.f;
constexpr float kMiddleC = 261.63f;

/// A rational tanh (Padé), exactly ±1 beyond ±3 with a smooth join, within 2.5% of tanh everywhere.
inline float tanhApprox(float x) {
    if (x > 3.f) return 1.f;
    if (x < -3.f) return -1.f;
    const float x2 = x * x;
    return x * (27.f + x2) / (27.f + 9.f * x2);
}

/// The cubic B-spline BLEP residual at distance d (0…2 samples) from a unit step (odd-symmetric about the step).
inline float blepResidual(float d) {
    if (d < 1.f) {
        const float d2 = d * d;
        return (1.f / 24.f) + (1.f / 6.f) * (2.75f - 4.f * d + 2.f * d2 * d - 0.75f * d2 * d2);
    }
    float e = 2.f - d;
    e *= e;
    return e * e * (1.f / 24.f);
}

/// A band-limited saw (−1…1, falling edge at the wrap) at phase p with per-sample increment inc (≤ 0.25).
inline float saw(float p, float inc) {
    float v = 2.f * p - 1.f;
    if (p < 2.f * inc) v += 2.f * blepResidual(p / inc);
    else if (p > 1.f - 2.f * inc) v -= 2.f * blepResidual((1.f - p) / inc);
    return v;
}

/// Oscillator A: saw (0) → square (0.5) → narrow pulse (1), plus the sub-octave square from its phase.
struct ShapeOsc {
    double phase = 0;
    bool odd = false;   // A has wrapped an odd number of times: the sub is in its second half
    float k = 0.f, w = 0.5f, sub = 0.f;

    /// k and w of saw(p) − k·saw(p + w) for a shape: k rises 0 → 1 up to the square, then the width narrows to 8%.
    static void shapeTerms(float s, float &kOut, float &wOut) {
        s = clamp01(s);
        if (s <= 0.5f) { kOut = 2.f * s; wOut = 0.5f; }
        else { kOut = 1.f; wOut = 0.5f - 0.84f * (s - 0.5f); }
    }
    void setShape(float s) { shapeTerms(s, k, w); }
    /// |1 − k·e^(−2πiw)|: the fundamental's amplitude against a plain saw's.
    static float fundamentalGain(float s) {
        float kk, ww;
        shapeTerms(s, kk, ww);
        const float c = std::cos(kTwoPi * ww), d = std::sin(kTwoPi * ww);
        return std::sqrt((1.f - kk * c) * (1.f - kk * c) + kk * d * kk * d);
    }
    void reset(float startPhase) { phase = startPhase; odd = false; sub = 0.f; }

    float next(float inc) {
        const float p = (float)phase;
        float p2 = p + w;
        if (p2 >= 1.f) p2 -= 1.f;
        const float a = saw(p, inc) - k * saw(p2, inc);
        phase += inc;
        if (phase >= 1.0) { phase -= 1.0; odd = !odd; }
        return a;
    }
    float nextWithSub(float inc) {
        const float p = (float)phase, hinc = 0.5f * inc;
        float ps = 0.5f * p + (odd ? 0.5f : 0.f), ps2 = ps + 0.5f;
        if (ps2 >= 1.f) ps2 -= 1.f;
        sub = saw(ps, hinc) - saw(ps2, hinc);
        return next(inc);
    }
    /// Advances n samples without producing anything (a silent voice keeps its place).
    void skip(int n, float inc) {
        phase += (double)n * (double)inc;
        const double whole = std::floor(phase);
        if (((long long)whole & 1LL) != 0) odd = !odd;
        phase -= whole;
    }
};

/// Oscillator B: a plain band-limited saw.
struct SawOsc {
    double phase = 0;
    void reset(float startPhase) { phase = startPhase; }
    float next(float inc) {
        const float v = saw((float)phase, inc);
        phase += inc;
        if (phase >= 1.0) phase -= 1.0;
        return v;
    }
    void skip(int n, float inc) { phase += (double)n * (double)inc; phase -= std::floor(phase); }
};

/// White noise, −1…1.
struct Noise {
    FastRandom rng;
    explicit Noise(uint64_t seed = 0x5EED0F5EA5ULL) : rng(seed) {}
    float next() { return rng.bipolar(); }
};

/// One smoothed random walk in −1…1: a reflected random walk sampled every 1/rate seconds, eased between points.
struct Walk {
    float from = 0, to = 0, pos = 0, rate = 0.25f;
    static float reflect(float x) { return x > 1.f ? 2.f - x : (x < -1.f ? -2.f - x : x); }
    void seed(FastRandom &r, float hz) { from = r.bipolar(); to = reflect(from + r.bipolar()); pos = r.uniform(); rate = hz; }
    void advance(float seconds, FastRandom &r) {
        pos += seconds * rate;
        while (pos >= 1.f) { pos -= 1.f; from = to; to = reflect(from + r.bipolar()); }
    }
    float value() const { const float s = pos * pos * (3.f - 2.f * pos); return from + (to - from) * s; }
};

/// Analogue slop: each oscillator's pitch wanders ±3 cents and the cutoff ±1%, each on its own 0.1–0.4 Hz walk.
struct Slop {
    static constexpr float kCents = 3.f, kCutoff = 0.01f;
    FastRandom rng{0x510951095109ULL};
    Walk walk[3];
    void seed(uint64_t s) {
        rng = FastRandom(s);
        for (auto &w : walk) w.seed(rng, 0.1f + 0.3f * rng.uniform());
    }
    void advance(float seconds) { for (auto &w : walk) w.advance(seconds, rng); }
    float pitchCents(int i, float depth) const { return kCents * depth * walk[i & 1].value(); }
    float cutoffRatio(float depth) const { return 1.f + kCutoff * depth * walk[2].value(); }
};

/// The cutoff factor for key tracking `amount` (0…1) at a note's frequency.
inline float keyTrack(float noteHz, float amount) { return std::exp2(amount * std::log2(std::max(noteHz, 1.f) / kMiddleC)); }

/// The 4-pole zero-delay-feedback ladder low-pass (TPT one-poles, tanh in the feedback).
struct Ladder {
    float s[4] = {};
    float g = 0.1f, dg = 0.f, k = 0.f, comp = 1.f;

    static float coefficient(float hz, float sr) {
        const float f = std::clamp(hz, kMinCutoff, std::min(kMaxCutoff, 0.45f * sr));
        return std::tan(kPi * f / sr);
    }
    void reset() { s[0] = s[1] = s[2] = s[3] = 0.f; }
    /// r 0…0.95 (the loop gain is 4r, so it never self-oscillates); the input is lifted so the passband holds.
    void setResonance(float r) { k = 4.f * std::clamp(r, 0.f, 0.95f); comp = 1.f + k; }
    void setCutoff(float hz, float sr, int n) { dg = (coefficient(hz, sr) - g) / (float)std::max(1, n); }
    void snapCutoff(float hz, float sr) { g = coefficient(hz, sr); dg = 0.f; }
    float process(float x) {
        g += dg;
        const float G = g / (1.f + g), Gm = 1.f - G, G2 = G * G, G4 = G2 * G2;
        // Solve the linear loop for the fourth stage's output, then feed back its tanh.
        const float sigma = Gm * (G2 * G * s[0] + G2 * s[1] + G * s[2] + s[3]);
        const float xin = comp * x;
        const float y4lin = (G4 * xin + sigma) / (1.f + k * G4);
        const float u = xin - k * tanhApprox(y4lin);
        float v = (u - s[0]) * G; const float y1 = v + s[0]; s[0] = y1 + v;
        v = (y1 - s[1]) * G; const float y2 = v + s[1]; s[1] = y2 + v;
        v = (y2 - s[2]) * G; const float y3 = v + s[2]; s[2] = y3 + v;
        v = (y3 - s[3]) * G; const float y4 = v + s[3]; s[3] = y4 + v;
        return y4;
    }
};

/// The state-variable (TPT) core shared by the high-pass and the band-pass.
struct SVFCore {
    float ic1 = 0, ic2 = 0, a1 = 1, a2 = 0, a3 = 0, k = 1.4142f;
    void set(float hz, float q, float sr) {
        const float g = std::tan(kPi * std::clamp(hz, 5.f, 0.45f * sr) / sr);
        k = 1.f / std::max(q, 0.05f);
        a1 = 1.f / (1.f + g * (g + k)); a2 = g * a1; a3 = g * a2;
    }
    void reset() { ic1 = ic2 = 0.f; }
    /// Runs one sample; v1 is the band output, v2 the low.
    void tick(float v0, float &v1, float &v2) {
        const float v3 = v0 - ic2;
        v1 = a1 * ic1 + a2 * v3;
        v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.f * v1 - ic1; ic2 = 2.f * v2 - ic2;
    }
};

/// A 2-pole high-pass.
struct HighPass {
    SVFCore f;
    void set(float hz, float q, float sr) { f.set(hz, q, sr); }
    void reset() { f.reset(); }
    float process(float x) { float v1, v2; f.tick(x, v1, v2); return x - f.k * v1 - v2; }
};

/// A 2-pole band-pass with unity gain at its centre.
struct BandPass {
    SVFCore f;
    void set(float hz, float q, float sr) { f.set(hz, q, sr); }
    void reset() { f.reset(); }
    float process(float x) { float v1, v2; f.tick(x, v1, v2); return f.k * v1; }
};

/// Two band-passes whose centres glide toward their targets (in octaves), for voice-like layers. As in parallel
/// formant synthesis, give the second a negative gain so the pair adds (rather than cancels) between the centres.
struct TwoFormant {
    BandPass bp[2];
    float hz[2] = {500.f, 1000.f}, target[2] = {500.f, 1000.f}, gain[2] = {1.f, -0.25f}, q = 5.f;
    /// Constant bandwidths (Hz) in place of the shared q, as a voice's formants keep theirs while they move (0: use q).
    float bw[2] = {0.f, 0.f};
    void reset(float f1, float f2) { hz[0] = target[0] = f1; hz[1] = target[1] = f2; bp[0].reset(); bp[1].reset(); }
    void setTargets(float f1, float f2) { target[0] = f1; target[1] = f2; }
    void setGains(float g1, float g2) { gain[0] = g1; gain[1] = g2; }
    void setBandwidths(float b1, float b2) { bw[0] = b1; bw[1] = b2; }
    float qOf(int i) const { return bw[i] > 0.f ? hz[i] / bw[i] : q; }
    void update(float glide, float sr) {
        for (int i = 0; i < 2; ++i) {
            hz[i] *= std::exp2(clamp01(glide) * std::log2(target[i] / hz[i]));
            bp[i].set(hz[i], qOf(i), sr);
        }
    }
    float process(float x) { return gain[0] * bp[0].process(x) + gain[1] * bp[1].process(x); }
    /// The pair's complex response at `f` (from the analogue prototype, close for f well below Nyquist): for
    /// levelling a layer whose pitch moves against fixed formants, alone or summed with another path.
    void response(float f, float &re, float &im) const {
        re = im = 0.f;
        for (int i = 0; i < 2; ++i) {
            // h = (j r/Q) / (1 − r² + j r/Q), r = f / centre: unity at the centre.
            const float r = f / hz[i], a = 1.f - r * r, b = r / qOf(i), d = a * a + b * b;
            re += gain[i] * (b * b) / d;
            im += gain[i] * (b * a) / d;
        }
    }
    float responseAt(float f) const { float re, im; response(f, re, im); return std::sqrt(re * re + im * im); }
};

/// An ADSR whose retrigger starts from the current level, so it never clicks.
struct ADSR {
    enum Stage { Idle, Attack, Decay, Release };
    Stage stage = Idle;
    float level = 0.f, peak = 1.f, sustain = 0.f;
    float slope = 1.f, decayCoef = 0.f, releaseCoef = 0.f;
    static constexpr float kFloor = 1e-5f;

    static float t60(float seconds, float sr) { return std::exp(-6.9077553f / (std::max(seconds, 1e-4f) * sr)); }
    void setAttack(float seconds, float sr) { slope = 1.f / std::max(1.f, seconds * sr); }
    void setDecay(float seconds, float sr) { decayCoef = t60(seconds, sr); }
    void setSustain(float fraction) { sustain = clamp01(fraction); }
    void setRelease(float seconds, float sr) { releaseCoef = t60(seconds, sr); }
    /// Starts the attack toward `pk` from wherever the level is now (straight into the decay if already above it).
    void trigger(float pk) { peak = std::max(pk, 0.f); stage = level < peak ? Attack : Decay; }
    void release() { if (stage != Idle) stage = Release; }
    void clear() { stage = Idle; level = 0.f; }
    bool idle() const { return stage == Idle; }
    bool gated() const { return stage == Attack || stage == Decay; }
    float next() {
        switch (stage) {
        case Attack:
            level += slope * peak;
            if (level >= peak) { level = peak; stage = Decay; }
            break;
        case Decay: {
            const float s = sustain * peak;
            level = s + (level - s) * decayCoef;
            break;
        }
        case Release:
            level *= releaseCoef;
            if (level < kFloor) { level = 0.f; stage = Idle; }
            break;
        default:
            break;
        }
        return level;
    }
};

// ---------- The vintage-synth core's additions (Sets 13 & 14, spec §4.1 of 2026-11-05-fire-and-neon-design.md) ----------
// Nothing here changes Blue Depth: every addition is a new type, and Ladder's saturation defaults to off.

/// The antiderivative of tanhApprox: (27 + 9x² + 216·ln(27 + 9x²)) / 162 within ±3, and linear beyond (where
/// tanhApprox is ±1), so the two join smoothly.
/// In double: ADAA divides a difference of these by a small step, so float rounding would become hiss.
inline double tanhApproxIntegral(double x) {
    const double ax = std::fabs(x);
    auto inner = [](double v) { const double w = 27.0 + 9.0 * v * v; return (w + 216.0 * std::log(w)) * (1.0 / 162.0); };
    if (ax <= 3.0) return inner(ax);
    return inner(3.0) + (ax - 3.0);
}

/// The growl stage: a sine wavefolder, then a soft clipper with an even-harmonic (asymmetric) term. Both are
/// first-order antiderivative anti-aliased (ADAA), so a driven saw stays clean without oversampling; the price is
/// half a sample of delay. set(drive, fold, asym), each 0…1; reset() between notes; process(x).
///   Fold:  m·sin(π/2·(1 + 3·fold)·x) + (1 − m)·x, with m = min(1, 5·fold) so a fold of 0 is a true bypass.
///   Drive: tanh(g·x′) / tanh(g), g = 1 + 11·drive, x′ = x + 0.15·asym·x² (the asym term adds DC: high-pass after).
struct Shaper {
    float g = 1.f, invNorm = 1.f, foldMix = 0.f, asym = 0.f;
    double foldK = 0.5 * 3.14159265358979323846;
    double dPrev = 0.0, dFPrev = tanhApproxIntegral(0.0);   // the drive's last input (scaled) and its antiderivative
    double fPrev = 0.0;                                     // the fold's last input
    static constexpr double kEps = 1e-5;

    void set(float drive, float fold, float asymmetry) {
        g = 1.f + 11.f * clamp01(drive);
        invNorm = 1.f / tanhApprox(g);
        const float f = clamp01(fold);
        foldK = 0.5 * 3.14159265358979323846 * (1.0 + 3.0 * f);
        foldMix = std::min(1.f, 5.f * f);
        asym = 0.15f * clamp01(asymmetry);
    }
    void reset() { dPrev = 0.0; dFPrev = tanhApproxIntegral(0.0); fPrev = 0.0; }

    float foldADAA(float xf) {
        // ∫ sin(kx) dx = −cos(kx)/k
        const double x = xf, d = x - fPrev;
        const double y = std::fabs(d) > kEps ? (std::cos(foldK * fPrev) - std::cos(foldK * x)) / (foldK * d)
                                             : std::sin(foldK * 0.5 * (x + fPrev));
        fPrev = x;
        return (float)y;
    }
    float driveADAA(float x) {
        const double u = (double)g * ((double)x + (double)asym * (double)x * (double)x);
        const double F = tanhApproxIntegral(u), d = u - dPrev;
        const double y = std::fabs(d) > kEps ? (F - dFPrev) / d : (double)tanhApprox((float)(0.5 * (u + dPrev)));
        dPrev = u; dFPrev = F;
        return (float)y * invNorm;
    }
    float process(float x) {
        if (foldMix > 0.f) x = foldMix * foldADAA(x) + (1.f - foldMix) * x;
        return driveADAA(x);
    }
};

/// A stack of up to N band-limited saws spread evenly across ±spread cents, with seeded phases and an equal-power
/// sum (÷√count), for width. setCount(n), setSpread(cents), reset(seed); next(baseInc) per sample.
template <int N>
struct Unison {
    SawOsc saw[N];
    float ratio[N] = {};
    int count = 1;
    float gain = 1.f;
    void setCount(int n) { count = std::clamp(n, 1, N); gain = 1.f / std::sqrt((float)count); }
    void setSpread(float cents) {
        for (int i = 0; i < N; ++i) {
            const float pos = count > 1 ? 2.f * (float)i / (float)(count - 1) - 1.f : 0.f;
            ratio[i] = std::exp2(pos * cents / 1200.f);
        }
    }
    void reset(uint64_t seed) { FastRandom r(seed); for (auto &s : saw) s.reset(r.uniform()); }
    float next(float baseInc) {
        float sum = 0.f;
        for (int i = 0; i < count; ++i) sum += saw[i].next(std::min(kMaxIncrement, baseInc * ratio[i]));
        return sum * gain;
    }
};

/// The ladder's own envelope, in octaves of cutoff: depth × ((1 − vd) + vd·velocity) × the ADSR. So with a velocity
/// depth of 1, a soft note barely opens the filter and a hard one opens it the whole depth.
struct FilterEnv {
    ADSR env;
    float depth = 0.f, velocityDepth = 0.f, scale = 1.f;
    void set(float a, float d, float s, float r, float sr) { env.setAttack(a, sr); env.setDecay(d, sr); env.setSustain(s); env.setRelease(r, sr); }
    void setDepth(float octaves) { depth = octaves; }
    void setVelocityDepth(float vd) { velocityDepth = clamp01(vd); }
    void gate(bool on, float velocity) {
        if (on) { scale = (1.f - velocityDepth) + velocityDepth * clamp01(velocity); env.trigger(1.f); }
        else env.release();
    }
    void clear() { env.clear(); }
    /// Advances one sample; returns the envelope's offset in octaves.
    float next() { return depth * scale * env.next(); }
    /// Advances n samples (a per-block envelope); returns the offset at the end.
    float advance(int n) { float v = 0.f; for (int i = 0; i < n; ++i) v = env.next(); return depth * scale * v; }
};

/// Portamento in constant time: a straight line in semitones from where the pitch is to the new target, arriving
/// exactly after `seconds`. jump() skips the glide (a new phrase, or legato-only with no overlap).
struct Glide {
    float current = 0.f, target = 0.f, step = 0.f;
    int remaining = 0, total = 1;
    void setTime(float seconds, float sr) { total = std::max(1, (int)std::lround(std::max(seconds, 0.f) * sr)); }
    void jump(float semitones) { current = target = semitones; remaining = 0; step = 0.f; }
    void glideTo(float semitones) {
        target = semitones;
        remaining = total;
        step = (target - current) / (float)total;
    }
    /// Advances n samples; returns the pitch (semitones) at the end.
    float advance(int n) {
        if (remaining <= 0) return current = target;
        const int k = std::min(n, remaining);
        current += step * (float)k;
        remaining -= k;
        if (remaining <= 0) current = target;
        return current;
    }
    bool gliding() const { return remaining > 0; }
};

/// How a voice takes new notes: every key its own voice, or one voice for the last key held (retriggering on each
/// new key, or legato: no retrigger and a glide while keys overlap).
enum class VoiceMode { poly, mono, legato };

/// The keys held for a mono voice, last pressed last, so letting go of the newest returns to the one before.
struct MonoKeys {
    static constexpr int kMax = 16;
    int note[kMax] = {}, velocity[kMax] = {};
    int count = 0;
    void press(int n, int v) {
        release(n);
        if (count == kMax) { for (int i = 1; i < kMax; ++i) { note[i - 1] = note[i]; velocity[i - 1] = velocity[i]; } --count; }
        note[count] = n; velocity[count] = v; ++count;
    }
    void release(int n) {
        for (int i = 0; i < count; ++i) if (note[i] == n) {
            for (int j = i + 1; j < count; ++j) { note[j - 1] = note[j]; velocity[j - 1] = velocity[j]; }
            --count;
            return;
        }
    }
    void clear() { count = 0; }
    bool empty() const { return count == 0; }
    int top() const { return count ? note[count - 1] : -1; }
    int topVelocity() const { return count ? velocity[count - 1] : 0; }
};

/// A ladder whose input saturates before the filter, so driven resonance growls instead of whistling. `drive` 0
/// is the plain Ladder exactly; above it, the input passes tanh(gd·x)/gd with gd = 1 + 3·drive (unity for small
/// signals, compressing loud ones into the loop).
struct DrivenLadder {
    Ladder ladder;
    float drive = 0.f, gd = 1.f;
    void setDrive(float d) { drive = clamp01(d); gd = 1.f + 3.f * drive; }
    void reset() { ladder.reset(); }
    void setResonance(float r) { ladder.setResonance(r); }
    void setCutoff(float hz, float sr, int n) { ladder.setCutoff(hz, sr, n); }
    void snapCutoff(float hz, float sr) { ladder.snapCutoff(hz, sr); }
    float process(float x) { return ladder.process(drive > 0.f ? tanhApprox(gd * x) / gd : x); }
};

} // namespace analog
} // namespace isd
