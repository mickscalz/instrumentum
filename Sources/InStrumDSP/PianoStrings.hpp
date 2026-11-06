// Shared modal piano strings: 8-lane decaying-phasor banks (a string's partials, or any bell-like modes),
// string inharmonicity and partial counts, the sympathetic resonator bank, and the grand's string recipe, hammer
// noise and soundboard. Moved out of Felt Glass so Cabin Felt and Single Note Grand play the same strings (Felt
// Glass's sound is locked by FeltGlassFingerprintTests).
#pragma once
#include "DSPCommon.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>

// The 8-lane helpers below are always inlined, so no vector values cross a call boundary.
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wpsabi"
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wpsabi"
#endif

namespace isd {

typedef float v8 __attribute__((vector_size(32)));
__attribute__((always_inline)) inline v8 ld8(const float *p) { v8 v; std::memcpy(&v, p, sizeof v); return v; }
__attribute__((always_inline)) inline void st8(float *p, v8 v) { std::memcpy(p, &v, sizeof v); }
__attribute__((always_inline)) inline float hsum(v8 v) { return ((v[0] + v[4]) + (v[1] + v[5])) + ((v[2] + v[6]) + (v[3] + v[7])); }

/// Advances one 8-lane chunk of decaying phasors `n` samples, adding their imaginary parts into `lane`.
__attribute__((always_inline)) inline void run1(float *re, float *im, const float *cr, const float *ci, v8 *lane, int n) {
    v8 r = ld8(re), i = ld8(im), c = ld8(cr), s = ld8(ci);
    for (int t = 0; t < n; ++t) {
        v8 nr = r * c - i * s, ni = r * s + i * c;
        r = nr; i = ni;
        lane[t] += ni;
    }
    st8(re, r); st8(im, i);
}

/// Two chunks at once: independent chains keep the multiplier pipelines busy.
__attribute__((always_inline)) inline void run2(float *re, float *im, const float *cr, const float *ci, v8 *lane, int n) {
    v8 r0 = ld8(re), i0 = ld8(im), c0 = ld8(cr), s0 = ld8(ci);
    v8 r1 = ld8(re + 8), i1 = ld8(im + 8), c1 = ld8(cr + 8), s1 = ld8(ci + 8);
    for (int t = 0; t < n; ++t) {
        v8 nr0 = r0 * c0 - i0 * s0, ni0 = r0 * s0 + i0 * c0;
        v8 nr1 = r1 * c1 - i1 * s1, ni1 = r1 * s1 + i1 * c1;
        r0 = nr0; i0 = ni0; r1 = nr1; i1 = ni1;
        lane[t] += ni0 + ni1;
    }
    st8(re, r0); st8(im, i0); st8(re + 8, r1); st8(im + 8, i1);
}

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float decayR(float t60, double sr) { return (float)std::pow(10.0, -3.0 / (t60 * sr)); }

/// String inharmonicity: lowest around the tenor (MIDI 45), rising gently into the bass and steeply into the treble.
inline float inharmonicity(int m) {
    float lg = m >= 45 ? -3.9f + (float)(m - 45) * (2.3f / 63.f) : -3.9f + (float)(45 - m) * (0.6f / 24.f);
    return std::pow(10.f, lg);
}

inline int partialCount(int m) {
    if (m <= 40) return 40;
    if (m <= 64) return (int)std::lround(40.f - (float)(m - 40) * (20.f / 24.f));
    if (m >= 96) return 8;
    return (int)std::lround(20.f - (float)(m - 64) * (12.f / 32.f));
}

inline float chunkEnergy(const float *re, const float *im) {
    float e = 0;
    for (int k = 0; k < 8; ++k) e += re[k] * re[k] + im[k] * im[k];
    return e;
}

/// A bank of up to N decaying phasors (N a multiple of 8): one voice's partials. `hz` and `dr` (per-sample decay)
/// are the recipe; `cr`/`ci` the rotation (decay × e^{iω}), refreshed by `retune`.
template <int N>
struct StringBank {
    static_assert(N % 8 == 0, "whole 8-lane chunks");
    alignas(32) float re[N], im[N], cr[N], ci[N], hz[N], dr[N];
    /// Components in use, rounded up to whole chunks.
    int n = 0;
    bool on[N / 8] = {};

    void clear() {
        std::memset(re, 0, sizeof re); std::memset(im, 0, sizeof im);
        std::memset(cr, 0, sizeof cr); std::memset(ci, 0, sizeof ci);
        std::memset(hz, 0, sizeof hz); std::memset(dr, 0, sizeof dr);
        n = 0;
        for (auto &c : on) c = false;
    }

    /// `k` components were written: round up to chunks and switch those chunks on.
    void setUsed(int k) {
        n = (k + 7) & ~7;
        for (int c = 0; c < N / 8; ++c) on[c] = c * 8 < k;
    }

    /// Rotations for the first `count` components at `fineRatio` (phase-continuous).
    void retune(float fineRatio, double sr, int count) {
        const float fsr = (float)sr;
        for (int i = 0; i < count; ++i) {
            float w0 = kTwoPi * hz[i] * fineRatio / fsr;
            cr[i] = dr[i] * std::cos(w0); ci[i] = dr[i] * std::sin(w0);
        }
    }
    void retune(float fineRatio, double sr) { retune(fineRatio, sr, n); }

    /// Adds `frames` samples of the bank into `lane` (8 lanes each).
    __attribute__((always_inline)) void render(v8 *lane, int frames) {
        const int chunks = n / 8;
        for (int c = 0; c < chunks;) {
            if (on[c] && c + 1 < chunks && on[c + 1]) {
                run2(re + 8 * c, im + 8 * c, cr + 8 * c, ci + 8 * c, lane, frames); c += 2;
            } else {
                if (on[c]) run1(re + 8 * c, im + 8 * c, cr + 8 * c, ci + 8 * c, lane, frames);
                ++c;
            }
        }
    }

    /// Shortens every component that rings longer than the per-sample decay `rd`.
    void damp(float rd) {
        for (int i = 0; i < n; ++i)
            if (dr[i] > rd) { float s = rd / dr[i]; cr[i] *= s; ci[i] *= s; dr[i] = rd; }
    }

    /// Switches off (and zeroes) chunks whose energy fell below `floor`; returns the energy still ringing
    /// (0 when nothing is left: `floor` is always above 0).
    float energyAndPrune(float floor) {
        float e = 0;
        for (int c = 0; c < n / 8; ++c) {
            if (!on[c]) continue;
            float ce = chunkEnergy(re + 8 * c, im + 8 * c);
            if (ce < floor) {
                on[c] = false;
                std::memset(re + 8 * c, 0, 8 * sizeof(float)); std::memset(im + 8 * c, 0, 8 * sizeof(float));
            } else {
                e += ce;
            }
        }
        return e;
    }
};

/// How a grand string is struck (Felt Glass's strings; Single Note Grand's concert grand).
struct GrandTouch {
    int pitch = 60;            // the sounding MIDI pitch
    float vb = 0.8f;           // the strike's brightness, 0…1 (the velocity, moved by the mood)
    float felt = 0.55f;        // 0…1: closes the hammer's cutoff (up to −60%) and shortens the ring (up to −35%)
    float ring = 0.55f;        // 0…1: the ring's length, × 0.45 … 1.85
    float level = 1.f;         // the string's level: the partials' RMS sum, at the full-velocity reference
};

/// What grandString wrote.
struct GrandString {
    int count = 0;             // components written
    int fundamental = 0;       // components of the first partial (its unison pair: 2; or 1; or 0 above Nyquist)
    float refE = 0, actE = 0;  // the hammer's reference (full-bright) energy and the strike's own, before levelling
    float energy = 0;          // Σ|amplitude|² after levelling
};

/// The felt-hammered grand string: inharmonic partials n·f0·√(1 + B·n²)/√(1 + B), struck at 1/8 of its length (so
/// every eighth is missing), shaped by the felt hammer's low-pass (its cutoff follows the pitch, as treble hammers are
/// smaller and harder, opens with the strike's brightness and closes under the felt), each ringing for t0 by pitch
/// (longer with `ring`, shorter under the felt) less the higher it is, the lower twelve as beating unison pairs, the
/// top quarter tapered so the partial cap never leaves an edge. Each partial starts at a fixed quasi-random phase (the
/// contact ramp hides the start), which keeps the crest factor of chords and bass notes musical. Levelled so a
/// full-bright strike's partials sum to `level` (a softer strike is quieter by what the hammer took). Writes the bank's
/// components (rotations still to be set by `retune`).
template <int N>
inline GrandString grandString(StringBank<N> &bank, const GrandTouch &t, double sr) {
    const float fsr = (float)sr, nyq = 0.45f * fsr;
    const int pitch = t.pitch;
    const float vb = t.vb, felt = clamp01(t.felt), ring = clamp01(t.ring);
    const float f0 = midiHz((float)pitch);
    bank.clear();
    const float B = inharmonicity(pitch), s1 = std::sqrt(1.f + B);
    const int P = partialCount(pitch);
    // The felt hammer's cutoff follows the string's pitch (treble hammers are smaller and harder) and opens with velocity.
    const float hammer = 360.f * std::pow(f0 / 261.63f, 0.6f);
    const float fc = hammer * (1.f - 0.6f * felt) * std::exp2(4.5f * vb), fcRef = hammer * std::exp2(4.5f);
    const float t0 = 18.f * std::pow(10.f, -(float)(pitch - 21) / 87.f) * (0.45f + 1.4f * ring) * (1.f - 0.35f * felt);
    GrandString out;
    float refE = 0, actE = 0;
    int k = 0;
    float phase = 0;
    auto add = [&](float hz, float a, float t60) {
        bank.hz[k] = hz; bank.re[k] = a * std::cos(phase); bank.im[k] = a * std::sin(phase); bank.dr[k] = decayR(t60, sr); ++k;
    };
    for (int n = 1; n <= P && k < N; ++n) {
        float nf = (float)n, fn = nf * f0 * std::sqrt(1.f + B * nf * nf) / s1;
        if (fn > nyq) break;
        float pos = std::sin(nf * kPi / 8.f);
        if (std::fabs(pos) < 1e-3f) continue;
        // The top quarter of the partials tapers off, so the partial cap never leaves a spectral edge.
        float edge = nf > 0.75f * (float)P ? 0.5f + 0.5f * std::cos(kPi * (nf - 0.75f * (float)P) / (0.25f * (float)P + 1.f)) : 1.f;
        float aRef = edge * pos / (1.f + std::pow(fn / fcRef, 3.f));
        float a = edge * pos / (1.f + std::pow(fn / fc, 3.f));
        float t60 = t0 / (1.f + fn / 2500.f);
        phase = kTwoPi * (0.381966f * nf + 0.137f * (float)pitch - std::floor(0.381966f * nf + 0.137f * (float)pitch));
        if (n <= 12 && k + 2 <= N) {
            float d = 0.15f + 0.35f * nf / 12.f;
            add(fn * std::exp2(-d / 1200.f), a, t60);
            add(fn * std::exp2(d / 1200.f), 0.25f * a, 2.6f * t60);
            refE += aRef * aRef * 1.0625f; actE += a * a * 1.0625f;
            if (n == 1) out.fundamental = 2;
        } else {
            add(fn, a, t60);
            refE += aRef * aRef; actE += a * a;
            if (n == 1) out.fundamental = 1;
        }
    }
    const float norm = refE > 0 ? t.level / std::sqrt(refE) : 0.f;
    float energy = 0;
    for (int i = 0; i < k; ++i) {
        bank.re[i] *= norm; bank.im[i] *= norm;
        energy += bank.re[i] * bank.re[i] + bank.im[i] * bank.im[i];
    }
    bank.setUsed(k);
    out.count = k; out.refE = refE; out.actE = actE; out.energy = energy;
    return out;
}

/// A short band-limited noise burst (the felt's contact thump, a damper's touch): a 1 ms rise, then an exponential fall
/// over `seconds`, through a band-pass at `hz` (Q 1.2) and a low-pass at 2·hz, its RMS starting near `rms`.
struct FeltNoise {
    int left = 0, age = 0, attack = 1;
    float amp = 0, decay = 0;
    Biquad bp;
    OnePole lp;

    void clear() { bp.clear(); lp.clear(); }
    void start(float seconds, float hz, float rms, double sr) {
        const float fsr = (float)sr;
        left = (int)(seconds * fsr); age = 0; attack = std::max(1, (int)(0.001f * fsr));
        // Uniform noise (RMS 0.577) through the band-pass and its low-pass keeps ≈ sqrt(π·f/(Q·sr))·0.8 of its RMS.
        const float keep = 0.577f * std::sqrt(kPi * hz / (1.2f * fsr)) * 0.8f;
        amp = rms / keep;
        decay = std::exp(-1.f / (seconds / 3.f * fsr));
        bp.setBandpass(hz, 1.2, sr);
        lp.setCutoff(2.f * hz, sr);
    }
    /// Adds the burst into x[0…n), drawing its noise from `rng`.
    void add(float *x, int n, FastRandom &rng) {
        for (int t = 0; t < n && left > 0; ++t, --left, ++age) {
            float env = age < attack ? (float)age / (float)attack : 1.f;
            float v = rng.bipolar() * amp * env;
            amp *= decay;
            x[t] += lp.process(bp.process(v));
        }
    }
};

/// The soundboard's body, stereo: four broad resonances. At length 1 and darkness 0 it is Felt Glass's board (peaks
/// at 110, 250, 1200 and 3500 Hz: +3, +2, −2, +1.5 dB). A longer board moves every mode down (÷ length); a darker one
/// gives up the 3.5 kHz presence for a dip and leans its two low modes up (dB per unit of darkness: +1, +0.5, −1, −6).
struct SoundBoard {
    Biquad peak[4][2];

    void configure(double sr, double length = 1.0, double darkness = 0.0) {
        const double peaks[4][3] = {{110, 1.0, 3.0}, {250, 1.2, 2.0}, {1200, 0.9, -2.0}, {3500, 1.0, 1.5}};
        const double dark[4] = {1.0, 0.5, -1.0, -6.0};
        for (int b = 0; b < 4; ++b)
            for (int c = 0; c < 2; ++c) peak[b][c].setPeak(peaks[b][0] / length, peaks[b][1], peaks[b][2] + darkness * dark[b], sr);
    }
    void process(float &l, float &r) {
        for (int b = 0; b < 4; ++b) { l = peak[b][0].process(l); r = peak[b][1].process(r); }
    }
    void clear() { for (auto &p : peak) { p[0].clear(); p[1].clear(); } }
};

/// Undamped strings ringing in sympathy while the pedal is down: 36 resonators from MIDI 48, panned by pitch.
struct SympBank {
    static constexpr int kSymp = 40;          // 36 used, in whole chunks
    static constexpr int kMaxBlock = 64;      // the largest inner block a caller renders
    alignas(32) float yre[kSymp], yim[kSymp], ycr[kSymp], yci[kSymp], yhz[kSymp], yL[kSymp], yR[kSymp];
    float sympR = 0;
    double sr = 48000;

    void init(double sampleRate) {
        sr = sampleRate;
        for (int k = 0; k < kSymp; ++k) { yre[k] = yim[k] = ycr[k] = yci[k] = yhz[k] = yL[k] = yR[k] = 0.f; }
        for (int k = 0; k < 36; ++k) {
            yhz[k] = midiHz((float)(48 + k));
            float pan = 0.5f * (float)(48 + k - 64) / 44.f, th = (pan + 1.f) * kPi / 4.f;
            yL[k] = std::cos(th); yR[k] = std::sin(th);
        }
    }

    void setDecay(float t60, float fineRatio) {
        sympR = decayR(t60, sr);
        for (int k = 0; k < kSymp; ++k) {
            float w = kTwoPi * yhz[k] * fineRatio / (float)sr;
            ycr[k] = yhz[k] > 0 ? sympR * std::cos(w) : 0.f;
            yci[k] = yhz[k] > 0 ? sympR * std::sin(w) : 0.f;
        }
    }

    /// Drives the resonators with `mono` × `inGain` × the smoothed `gain`, adding `outGain` × their ring into l/r.
    void render(const float *mono, float *l, float *r, int n, Smoothed &gain, float inGain, float outGain) {
        v8 laneL[kMaxBlock], laneR[kMaxBlock];
        float x[kMaxBlock];
        const float scale = inGain * (1.f - sympR);
        for (int t = 0; t < n; ++t) { x[t] = mono[t] * scale * gain.next(); laneL[t] = v8{}; laneR[t] = v8{}; }
        for (int c = 0; c < kSymp / 8; ++c) {
            v8 rr = ld8(yre + 8 * c), ii = ld8(yim + 8 * c), cr = ld8(ycr + 8 * c), ci = ld8(yci + 8 * c);
            const v8 wl = ld8(yL + 8 * c), wr = ld8(yR + 8 * c);
            for (int t = 0; t < n; ++t) {
                v8 nr = rr * cr - ii * ci + x[t], ni = rr * ci + ii * cr;
                rr = nr; ii = ni;
                laneL[t] += ni * wl; laneR[t] += ni * wr;
            }
            st8(yre + 8 * c, rr); st8(yim + 8 * c, ii);
        }
        for (int t = 0; t < n; ++t) { l[t] += outGain * hsum(laneL[t]); r[t] += outGain * hsum(laneR[t]); }
    }

    /// True (and zeroed) once the resonators have rung out.
    bool pruneIfSilent() {
        float e = 0;
        for (int k = 0; k < kSymp; ++k) e += yre[k] * yre[k] + yim[k] * yim[k];
        if (e >= 1e-14f) return false;
        for (int k = 0; k < kSymp; ++k) { yre[k] = 0.f; yim[k] = 0.f; }
        return true;
    }
};

} // namespace isd
