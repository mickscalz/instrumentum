#include "FeltGlass.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cstring>

namespace isd {

namespace {

// Level calibration (see docs/superpowers/briefs/felt-glass.md).
constexpr float kStringGain = 0.30f;
constexpr float kGlassGain = 0.146f;
constexpr float kDamperNoiseGain = 1.0f;
constexpr float kSympIn = 0.02f;
constexpr float kSympOut = 8.0f;
constexpr float kMaster = 1.0f;

const float kGlassRatio[6] = {1.0f, 2.32f, 4.25f, 6.63f, 9.38f, 12.5f};
const float kGlassBase[6] = {1.0f, 0.55f, 0.35f, 0.22f, 0.14f, 0.09f};

} // namespace

FeltGlass::FeltGlass(double sampleRate) : sr(sampleRate), rng(0x5EED1234ABCDULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    fine.init(sr); glassGain.init(sr); warmth.init(sr); space.init(sr); wet.init(sr); sympGain.init(sr, 50.0);
    fine.snap(0); glassGain.snap(0.35f); warmth.snap(0.60f); space.snap(0.45f); wet.snap(0); sympGain.snap(0);
    board.configure(sr);
    symp.init(sr);
    setSympDecay(0.08f);
}

void FeltGlass::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: pFine = value; set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_FELT: pFelt = value; break;
    case ISD_P_GLASS: set(glassGain); break;
    case ISD_P_WARMTH: set(warmth); break;
    case ISD_P_RING: pRing = value; break;
    case ISD_P_WIDTH: pWidth = value; break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    default: break;
    }
}

int FeltGlass::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) n += v.active ? 1 : 0;
    return n;
}

FeltGlass::Voice &FeltGlass::allocate() {
    int sounding = 0;
    Voice *quietest = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        if (!quietest || v.level < quietest->level) quietest = &v;
    }
    if (sounding >= kPolyphony && quietest) beginFade(*quietest);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void FeltGlass::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (0.02f * (float)sr);
}

void FeltGlass::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    idle = false; idleSamples = 0;
    int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    // Struck again without a release: the earlier strike counts as released. The new strike gets its own
    // components, which sum with the still-ringing ones exactly as re-exciting the same string would.
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
    startVoice(allocate(), note, pitch, velocity);
}

void FeltGlass::startVoice(Voice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr, nyq = 0.45f * fsr;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float vb = clamp01(vp + 0.3f * (mBright - 0.5f));
    const float felt = clamp01(pFelt);
    const float f0 = midiHz((float)pitch);
    const float A = std::pow(vp, 1.7f);

    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch; v.amp = A;
    v.fadeGain = 1; v.fadeStep = 0;
    v.glass.clear();

    // Strings: the shared grand string (PianoStrings.hpp), its felt and ring from the dials.
    GrandTouch touch;
    touch.pitch = pitch; touch.vb = vb; touch.felt = pFelt; touch.ring = pRing; touch.level = A * kStringGain;
    const GrandString built = grandString(v.str, touch, sr);
    const float refE = built.refE, actE = built.actE;
    v.stringRef = built.energy;

    // Glass: inharmonic bell partials an octave up, each a swell (difference of two decays).
    const float tau = 0.3f + 1.2f * (1.f - clamp01(mEnergy));
    const float t60g = std::clamp(8.f * std::pow(0.5f, (float)(pitch - 36) / 60.f), 3.f, 9.f);
    const float detune = 0.5f + 3.f * clamp01(mMotion);
    float w[6], wE = 0;
    for (int i = 0; i < 6; ++i) { w[i] = kGlassBase[i] * std::exp(-(1.f - vb) * (float)i * 0.5f); wE += w[i] * w[i]; }
    // The glass halo softens with the touch too: half as many dB as the hammer took from the strings.
    const float hammerLoss = refE > 0 ? actE / refE : 1.f;
    const float gAmp = A * kGlassGain * std::pow(hammerLoss, 0.25f) / std::sqrt(wE);
    int g = 0;
    v.glassRef = 0;
    for (int i = 0; i < 6 && g + 2 <= kGlass; ++i) {
        float hz = 2.f * f0 * kGlassRatio[i] * std::exp2(((i & 1) ? -detune : detune) / 1200.f);
        if (hz > nyq) continue;
        // Like a real bell, higher partials fade sooner. Each partial swells in (difference of two decays),
        // normalised so its peak is its weight.
        const float t60 = t60g / (1.f + hz / 6000.f), alpha = 6.9078f / t60;
        const float tstar = tau * std::log(1.f + 1.f / (alpha * tau));
        const float peak = std::exp(-alpha * tstar) * (1.f - std::exp(-tstar / tau));
        const float rg = decayR(t60, sr), rs = rg * std::exp(-1.f / (tau * fsr));
        float a = w[i] * gAmp / peak;
        float ph = kTwoPi * (0.618034f * (float)(i + 1) + 0.29f * (float)pitch - std::floor(0.618034f * (float)(i + 1) + 0.29f * (float)pitch));
        v.glass.hz[g] = hz; v.glass.re[g] = a * std::cos(ph); v.glass.im[g] = a * std::sin(ph); v.glass.dr[g] = rg; ++g;
        v.glass.hz[g] = hz; v.glass.re[g] = -a * std::cos(ph); v.glass.im[g] = -a * std::sin(ph); v.glass.dr[g] = rs; ++g;
        v.glassRef += 2.f * a * a;
    }
    v.glass.setUsed(g);

    v.str.retune(fineRatio, sr, kStrings);
    v.glass.retune(fineRatio, sr, kGlass);

    // Felt contact ramp, thump and stereo place. The thump sits (−18 + 10·felt) dB under the note's initial level.
    v.attackPos = 0;
    v.attackLen = std::max(1, (int)((4.f - 3.f * vp) * 0.001f * fsr));
    v.noteRms = std::sqrt(0.5f * v.stringRef);
    v.noise.clear();
    v.noiseHz = 180.f + 220.f * (float)(pitch - 21) / 87.f;
    const float td = (25.f - 17.f * vp) * 0.001f;
    v.noise.start(td, v.noiseHz, v.noteRms * std::pow(10.f, (-18.f + 10.f * felt) / 20.f), sr);
    const float pan = std::clamp(clamp01(pWidth) * (float)(pitch - 64) / 44.f, -1.f, 1.f), th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    v.level = v.stringRef + v.glassRef;
}

void FeltGlass::damp(Voice &v) {
    if (v.damped) return;
    v.damped = true;
    const float rd = decayR(0.15f, sr), rgd = decayR(0.6f, sr);
    v.str.damp(rd);
    v.glass.damp(rgd);
    v.noise.start(0.01f, 2.f * v.noiseHz, v.noteRms * 0.0316f * kDamperNoiseGain, sr);
}

void FeltGlass::noteOff(int note) {
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void FeltGlass::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (down) {
        setSympDecay(3.f);
        sympGain.setTarget(1.f);
        sympActive = true;
    } else {
        setSympDecay(0.08f);
        sympGain.setTarget(0.f);
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
    }
}

void FeltGlass::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    sympGain.setTarget(0.f);
    setSympDecay(0.08f);
}

void FeltGlass::allSoundOff() {
    allNotesOff();
    reverb.clear();
}

void FeltGlass::retune() {
    ++retunes;
    for (auto &v : voices) {
        if (!v.active) continue;
        v.str.retune(fineRatio, sr);
        v.glass.retune(fineRatio, sr);
    }
    setSympDecay(sustain ? 3.f : 0.08f);
}

void FeltGlass::render(float *left, float *right, int frames) {
    int pos = 0;
    while (pos < frames) {
        int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
    }
}

void FeltGlass::renderVoice(Voice &v, float *sL, float *sR, float *gL, float *gR, float *mono, int n) {
    v8 lane[kSub];
    float vs[kSub], vg[kSub];
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    v.str.render(lane, n);
    for (int t = 0; t < n; ++t) vs[t] = hsum(lane[t]);
    if (v.attackPos < v.attackLen) {
        for (int t = 0; t < n && v.attackPos < v.attackLen; ++t, ++v.attackPos)
            vs[t] *= 0.5f - 0.5f * std::cos(kPi * (float)v.attackPos / (float)v.attackLen);
    }
    if (v.noise.left > 0) v.noise.add(vs, n, rng);
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    v.glass.render(lane, n);
    for (int t = 0; t < n; ++t) vg[t] = hsum(lane[t]);
    if (v.fading) {
        for (int t = 0; t < n; ++t) {
            vs[t] *= v.fadeGain; vg[t] *= v.fadeGain;
            v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep);
        }
        if (v.fadeGain <= 0.f) v.active = false;
    }
    for (int t = 0; t < n; ++t) {
        sL[t] += vs[t] * v.panL; sR[t] += vs[t] * v.panR;
        gL[t] += vg[t] * v.panL; gR[t] += vg[t] * v.panR;
        mono[t] += vs[t];
    }
}

void FeltGlass::renderSymp(const float *mono, float *sL, float *sR, int n) {
    symp.render(mono, sL, sR, n, sympGain, kSympIn, kSympOut);
}

void FeltGlass::housekeeping() {
    for (auto &v : voices) {
        if (!v.active) continue;
        const float floorS = std::max(1e-8f * v.stringRef, 1e-14f), floorG = std::max(1e-8f * v.glassRef, 1e-14f);
        const float e = v.str.energyAndPrune(floorS), eg = v.glass.energyAndPrune(floorG);
        const bool any = e > 0 || eg > 0;
        float g = glassGain.value;
        v.level = e + eg * g * g;
        if (!any && v.noise.left <= 0) v.active = false;
    }
    if (sympActive && sympGain.target == 0.f && sympGain.value < 1e-4f && symp.pruneIfSilent()) sympActive = false;
}

void FeltGlass::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr;
    // Control-rate updates.
    for (int t = 0; t < n; ++t) { fine.next(); warmth.next(); space.next(); }
    // Fine tune glides (20 ms); retuning every ringing partial is costly, so it follows the glide on the
    // housekeeping cadence (every 4th block) and only for steps a tenth of a cent or more. Phase-continuous.
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            retune();
        }
    }
    const float wv = clamp01(warmth.value + 0.5f * (mWarmth - 0.5f));
    if (std::fabs(wv - appliedWarmth) > 1e-3f) {
        appliedWarmth = wv;
        for (int c = 0; c < 2; ++c) {
            highShelf[c].setHighShelf(3000.0, 3.0 - 9.0 * wv, sr);
            lowShelf[c].setLowShelf(200.0, 1.5 * wv, sr);
        }
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) {
        appliedSpace = sv;
        reverb.configure(0.05f + 0.5f * std::pow(sv, 1.5f), 0.55f, 12.f, 0.f);
        wet.setTarget(0.6f * sv);
    }

    float sL[kSub] = {}, sR[kSub] = {}, gL[kSub] = {}, gR[kSub] = {}, mono[kSub] = {};
    float dryL[kSub] = {}, dryR[kSub] = {};
    bool anyVoice = false;
    if (!idle) {
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, sL, sR, gL, gR, mono, n);
        }
        if (sympActive) renderSymp(mono, sL, sR, n);
        float peakAbs = 0;
        for (int t = 0; t < n; ++t) {
            float l = sL[t], r = sR[t];
            board.process(l, r);
            float g = glassGain.next();
            l += g * gL[t]; r += g * gR[t];
            l = highShelf[0].process(lowShelf[0].process(l));
            r = highShelf[1].process(lowShelf[1].process(r));
            dryL[t] = l; dryR[t] = r;
            peakAbs = std::max(peakAbs, std::max(std::fabs(l), std::fabs(r)));
        }
        if (!anyVoice && !sympActive && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) {
                idle = true;
                idleSamples = 0;
                board.clear();
                for (int c = 0; c < 2; ++c) { highShelf[c].clear(); lowShelf[c].clear(); }
            }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) glassGain.next();
    }

    float revL[kSub] = {}, revR[kSub] = {};
    if (wet.target > 0.f || wet.value > 1e-5f) {
        reverb.process(dryL, dryR, revL, revR, n);
        reverbLive = true;
    } else if (reverbLive) {
        reverb.clear();
        reverbLive = false;
    }
    for (int t = 0; t < n; ++t) {
        float w = wet.next();
        float l = kMaster * (dryL[t] + w * revL[t]), r = kMaster * (dryR[t] + w * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
