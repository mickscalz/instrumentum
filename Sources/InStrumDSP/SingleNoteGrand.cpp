// Single Note Grand: see SingleNoteGrand.hpp and docs/superpowers/briefs/single-note-grand.md.
#include "SingleNoteGrand.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace isd {

namespace {

// Level and tone calibration (measured with the C++ mirror harness; see the commit that brought this engine in).
constexpr float kStringGain = 0.30f;       // the string's level at full velocity (Felt Glass's)
constexpr float kRing = 0.75f;             // a concert grand's ring (Felt Glass plays at 0.55): A4 rings 7 s, its aftersound 18 s
constexpr double kBoardLength = 1.35;      // the board's modes ÷ 1.35: 81, 185, 889 and 2593 Hz
constexpr double kBoardDark = 0.5;         // and darker: the presence peak becomes a 1.5 dB dip (warmth moves it ±0.4)
constexpr float kSympIn = 0.02f, kSympOut = 8.0f;
constexpr float kDamperNoiseGain = 1.0f;
constexpr float kMaster = 1.0f;
// The voice.
constexpr float kF1Closed = 400.f, kF1Open = 700.f, kF2Closed = 1200.f, kF2Open = 1800.f;
constexpr float kBw1 = 80.f, kBw2 = 120.f;
constexpr float kFormant1 = 1.f, kFormant2 = 0.35f;  // both in phase: the pair dips between its centres
constexpr float kDirect = 1.0f;            // the first partial's direct path, against the formants' unity peaks
constexpr float kMorphGain = 8.f;          // the clipper's drive rises 1 → 8 (18 dB) with the morph…
constexpr float kBreakDb = 30.f;           // …and 0–30 dB more with Break
constexpr float kDrive = 2.0f;             // the clipper's drive at morph 0, Break 0
constexpr float kRef = 0.035f;             // the clipper input's amplitude the make-up holds at unity
constexpr float kVoiceLevel = 1.6f;        // the voice against the piano
constexpr float kSingMax = 0.96f, kSingCurve = 1.3f;   // a held key's string sings on: t60 × 25 at Morph 1
constexpr float kBlend = 1.4f;             // the crossfade's loudness held: × 1/√(1 − 1.4·w(1 − w)), +1.9 dB at w = .5
constexpr float kPanicFade = 0.02f;
constexpr float kWetMax = 0.7f;
constexpr double kRepeatSlack = 0.005;     // a strike counts as a repeat within the gap plus 5 ms of timing slop

inline float lerp(float a, float b, float t) { return a + (b - a) * t; }

/// The hall's decay for a Hall dial value: 2.8 s at .7, doubling every 0.4 of the dial. The tank is set 13% longer,
/// since its damping takes the top off faster, so that is what is heard (measured T20: 2.84 s at .7, 4.57 s at 1 and
/// 1.05 s at .1).
constexpr float kHallTrim = 1.13f;
inline float hallSeconds(float h) { return 2.8f * std::exp2(2.5f * (h - 0.7f)); }

} // namespace

SingleNoteGrand::SingleNoteGrand(double sampleRate) : sr(sampleRate), rng(0x5149A7D6A9D11ULL), reverb(sampleRate, kSub) {
    limiter.init(sr);
    const double blockRate = sr / (double)kSub;   // the live dials glide once per control block
    for (Smoothed *s : {&fine, &hall, &space, &width, &octave, &breakDial}) s->init(blockRate);
    fine.snap(0); hall.snap(0.7f); space.snap(0.5f); width.snap(0.5f); octave.snap(0.5f); breakDial.snap(0.5f);
    sympGain.init(sr, 50.0);
    sympGain.snap(0);
    board.configure(sr, kBoardLength, kBoardDark);
    symp.init(sr);
    symp.setDecay(0.08f, fineRatio);
    formantNow.setGains(kFormant1, kFormant2);
    formantNow.setBandwidths(kBw1, kBw2);
    formantNow.reset(kF1Closed, kF2Closed);
    formantNow.update(1.f, (float)sr);
    wetStep = (float)(1.0 - std::exp(-1.0 / (0.02 * sr)));
    for (auto &v : voices) for (auto &l : v.lnDecay) l = 0.f;
}

void SingleNoteGrand::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_HALL_SNG: set(hall); break;
    case ISD_P_FELT_SNG: pFelt = value; break;
    case ISD_P_MORPH: pMorph = value; break;
    case ISD_P_OCTAVE_DOWN: set(octave); break;
    case ISD_P_BREAK: set(breakDial); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_SNG_PIANO_ONLY: pianoOnly = value >= 0.5f; break;
    case ISD_P_DEBUG_SNG_VOICE_ONLY: voiceOnly = value >= 0.5f; break;
    case ISD_P_DEBUG_SNG_DRY: dryHook = value >= 0.5f; break;
    default: break;
    }
}

int SingleNoteGrand::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) n += v.active ? 1 : 0;
    return n;
}

int SingleNoteGrand::debugCount(int which) const {
    if (which == ISD_DEBUG_MORPH_PERMILLE) return morphPermille.load(std::memory_order_relaxed);
    return 0;
}

void SingleNoteGrand::setForcedMorph(float m) {
    forcedIn.store(std::isfinite(m) && m >= 0.f ? clamp01(m) : -1.f, std::memory_order_relaxed);
}

// ---------- Keys and voices ----------

SingleNoteGrand::Voice &SingleNoteGrand::allocate() {
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

void SingleNoteGrand::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (kPanicFade * (float)sr);
}

/// Sets how much of each partial's decay the held key takes away: |rotation| = decay^(1 − s), so s = 0 is the
/// piano string as struck and s → 1 rings on undamped. Phase-continuous (only the rotations' lengths change).
void SingleNoteGrand::applySing(Voice &v, float s) {
    const float ds = s - v.sing;
    if (ds == 0.f) return;
    for (int i = 0; i < v.str.n; ++i) {
        const float k = std::exp(-ds * v.lnDecay[i]);
        v.str.cr[i] *= k;
        v.str.ci[i] *= k;
    }
    v.sing = s;
}

void SingleNoteGrand::startVoice(Voice &v, int note, int pitch, int velocity) {
    const float fsr = (float)sr;
    const float vp = (float)std::clamp(velocity, 1, 127) / 127.f;
    const float vb = clamp01(vp + 0.3f * (mBright - 0.5f) + 0.15f * (mEnergy - 0.5f));
    const float felt = clamp01(pFelt);
    const float A = std::pow(vp, 1.7f);

    v.active = true; v.keyDown = true; v.damped = false; v.fading = false;
    v.note = note; v.pitch = pitch;
    v.fadeGain = 1; v.fadeStep = 0;

    // The shared grand string (PianoStrings.hpp) with the felt at Felt and a concert grand's ring.
    GrandTouch touch;
    touch.pitch = pitch; touch.vb = vb; touch.felt = felt; touch.ring = kRing; touch.level = A * kStringGain;
    const GrandString built = grandString(v.str, touch, sr);
    v.stringRef = built.energy;
    v.fundamental = built.fundamental;
    for (int i = 0; i < kStrings; ++i) v.lnDecay[i] = i < built.count ? std::log(v.str.dr[i]) : 0.f;
    v.sing = 0.f;
    v.str.retune(fineRatio, sr, kStrings);

    // Felt contact ramp, thump and stereo place. The thump sits (−18 + 10·felt) dB under the note's initial level.
    v.attackPos = 0;
    v.attackLen = std::max(1, (int)((4.f - 3.f * vp) * 0.001f * fsr));
    v.noteRms = std::sqrt(0.5f * v.stringRef);
    v.noise.clear();
    v.noiseHz = 180.f + 220.f * (float)(pitch - 21) / 87.f;
    v.noise.start((25.f - 17.f * vp) * 0.001f, v.noiseHz, v.noteRms * std::pow(10.f, (-18.f + 10.f * felt) / 20.f), sr);
    const float pan = std::clamp(clamp01(width.value) * (float)(pitch - 64) / 44.f, -1.f, 1.f), th = (pan + 1.f) * kPi / 4.f;
    v.panL = std::cos(th); v.panR = std::sin(th);
    v.level = v.stringRef;

    // The voice path starts from rest the first block it runs.
    v.voiceLive = false;
    v.hRe = 1.f; v.hIm = 0.f;
}

void SingleNoteGrand::damp(Voice &v) {
    if (v.damped) return;
    applySing(v, 0.f);   // a piano string again, so the damper takes its own decay
    v.damped = true;
    v.str.damp(decayR(0.15f, sr));
    v.noise.start(0.01f, 2.f * v.noiseHz, v.noteRms * 0.0316f * kDamperNoiseGain, sr);
}

/// The repeat detector: the same key again within the gap counts on; a different key, or a slower strike, starts over.
void SingleNoteGrand::noteRepeat(int note) {
    const double now = (double)clock / sr;
    if (note == repeatNote && now - repeatLast <= kRepeatGap + kRepeatSlack) ++repeatCount;
    else { repeatNote = note; repeatCount = 1; }
    repeatLast = now;
    repeating.store(repeatCount >= kRepeatStrikes, std::memory_order_relaxed);
}

void SingleNoteGrand::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    idle = false; idleSamples = 0;
    noteRepeat(note);
    const int pitch = std::clamp(note + (int)std::lround(pTranspose), 0, 127);
    // Struck again without a release: the earlier strike counts as released (Felt Glass's rule).
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
    startVoice(allocate(), note, pitch, velocity);
    keyHeld[note] = true;
}

void SingleNoteGrand::noteOff(int note) {
    note &= 127;
    keyHeld[note] = false;
    for (auto &v : voices)
        if (v.active && !v.fading && v.note == note && v.keyDown) { v.keyDown = false; if (!sustain) damp(v); }
}

void SingleNoteGrand::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (down) {
        symp.setDecay(3.f, fineRatio);
        sympGain.setTarget(1.f);
        sympActive = true;
    } else {
        symp.setDecay(0.08f, fineRatio);
        sympGain.setTarget(0.f);
        for (auto &v : voices) if (v.active && !v.fading && !v.keyDown) damp(v);
    }
}

void SingleNoteGrand::aftertouch(int note, float pressure) {
    const float p = std::isfinite(pressure) ? clamp01(pressure) : 0.f;
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void SingleNoteGrand::resetTouch() {
    channelPressure = 0.f;
    for (auto &p : polyPressure) p = 0.f;
}

void SingleNoteGrand::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    for (auto &k : keyHeld) k = false;
    sympGain.setTarget(0.f);
    symp.setDecay(0.08f, fineRatio);
    resetTouch();
    repeatNote = -1;
    repeatCount = 0;
    repeating.store(false, std::memory_order_relaxed);
}

void SingleNoteGrand::allSoundOff() {
    allNotesOff();
    // The hall empties over a little longer than the voices fade, and takes nothing in meanwhile.
    reverbEmptying = true;
    reverbFadeStep = 1.f / (1.25f * kPanicFade * (float)sr);
}

void SingleNoteGrand::retune() {
    for (auto &v : voices) {
        if (!v.active) continue;
        v.str.retune(fineRatio, sr);
        v.sing = 0.f;   // the rotations are back at their own decays; the next block sings them again
    }
    symp.setDecay(sustain ? 3.f : 0.08f, fineRatio);
}

// ---------- Rendering ----------

void SingleNoteGrand::render(float *left, float *right, int frames) {
    DenormalGuard guard;
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
        clock += n;
    }
}

namespace {

/// The voice's clipper: tanh (the analogue core's rational one) with first-order antiderivative anti-aliasing, so a
/// broken voice stays clean of fold-back without oversampling (half a sample of delay). Where the input and the last
/// one both sit within ±0.6, tanh is nearly straight and adds almost nothing to fold back: there the ADAA's own limit
/// (tanh of the midpoint, the same half-sample delay, within 1e-4 of it) stands in, and the logarithm is only taken
/// where the clipper bends. `prevF` is the antiderivative at `prevIn`, or NaN when it hasn't been taken.
constexpr float kGentle = 0.6f;
inline float clipADAA(double &prevIn, double &prevF, float xf) {
    const double x = xf;
    if (std::fabs(xf) < kGentle && std::fabs(prevIn) < (double)kGentle) {
        const float y = analog::tanhApprox(0.5f * (xf + (float)prevIn));
        prevIn = x;
        prevF = std::numeric_limits<double>::quiet_NaN();
        return y;
    }
    if (std::isnan(prevF)) prevF = analog::tanhApproxIntegral(prevIn);
    const double F = analog::tanhApproxIntegral(x), d = x - prevIn;
    const double y = std::fabs(d) > 1e-5 ? (F - prevF) / d : (double)analog::tanhApprox((float)(0.5 * (x + prevIn)));
    prevIn = x;
    prevF = F;
    return (float)y;
}

} // namespace

void SingleNoteGrand::renderVoice(Voice &v, int n, bool voicePath) {
    v8 lane[kSub];
    float vs[kSub], vv[kSub], ramp[kSub];
    // The first partial's phasors as they stand at the block's start: the direct path runs an exact copy of them.
    float fr[2] = {}, fi[2] = {}, fcr[2] = {}, fci[2] = {};
    const int nf = voicePath ? std::min(v.fundamental, 2) : 0;
    for (int k = 0; k < nf; ++k) { fr[k] = v.str.re[k]; fi[k] = v.str.im[k]; fcr[k] = v.str.cr[k]; fci[k] = v.str.ci[k]; }
    for (int t = 0; t < n; ++t) lane[t] = v8{};
    v.str.render(lane, n);
    for (int t = 0; t < n; ++t) { vs[t] = hsum(lane[t]); ramp[t] = 1.f; }
    if (v.attackPos < v.attackLen) {
        for (int t = 0; t < n && v.attackPos < v.attackLen; ++t, ++v.attackPos) {
            ramp[t] = 0.5f - 0.5f * std::cos(kPi * (float)v.attackPos / (float)v.attackLen);
            vs[t] *= ramp[t];
        }
    }
    if (v.noise.left > 0) v.noise.add(vs, n, rng);

    if (voicePath) {
        if (!v.voiceLive) {
            v.formant.bp[0].reset(); v.formant.bp[1].reset();
            v.clipIn = 0.0; v.clipF = std::numeric_limits<double>::quiet_NaN();
            v.voiceLive = true;
        }
        for (int i = 0; i < 2; ++i) {
            v.formant.bp[i].f.a1 = formantNow.bp[i].f.a1; v.formant.bp[i].f.a2 = formantNow.bp[i].f.a2;
            v.formant.bp[i].f.a3 = formantNow.bp[i].f.a3; v.formant.bp[i].f.k = formantNow.bp[i].f.k;
            v.formant.gain[i] = formantNow.gain[i];
        }
        // The half-angle phasor follows the first partial: resynchronised to its phase at the block's start (the root
        // nearer the last one, so it never flips), it turns at half the partial's rotation.
        float hcr = 1.f, hci = 0.f;
        if (nf > 0) {
            const float zm = std::sqrt(fr[0] * fr[0] + fi[0] * fi[0]);
            if (zm > 1e-30f) {
                const float a = fr[0] / zm, b = fi[0] / zm;
                float cr = std::sqrt(std::max(0.f, 0.5f * (1.f + a))), ci = std::copysign(std::sqrt(std::max(0.f, 0.5f * (1.f - a))), b);
                if (cr * v.hRe + ci * v.hIm < 0.f) { cr = -cr; ci = -ci; }
                v.hRe = cr; v.hIm = ci;
            }
            const float cm = std::sqrt(fcr[0] * fcr[0] + fci[0] * fci[0]);
            const float c = cm > 0.f ? std::clamp(fcr[0] / cm, -1.f, 1.f) : 1.f;
            hcr = std::sqrt(0.5f * (1.f + c));
            hci = std::sqrt(0.5f * (1.f - c));
        }
        const float og = nf > 0 ? octaveGain : 0.f, on = nf > 0 ? octaveNorm : 1.f, dg = directGain;
        const float dd = (drive1 - drive0) / (float)n, dk = (makeup1 - makeup0) / (float)n;
        float D = drive0, K = makeup0, hr = v.hRe, hi = v.hIm;
        for (int t = 0; t < n; ++t) {
            float fsum = 0.f;
            for (int k = 0; k < nf; ++k) {
                const float nr = fr[k] * fcr[k] - fi[k] * fci[k], ni = fr[k] * fci[k] + fi[k] * fcr[k];
                fr[k] = nr; fi[k] = ni;
                fsum += ni;
            }
            const float nhr = hr * hcr - hi * hci, nhi = hr * hci + hi * hcr;
            hr = nhr; hi = nhi;
            const float ring = on * (1.f + og * hr);
            const float y = v.formant.process(vs[t] * ring) + dg * fsum * ramp[t] * ring;
            D += dd; K += dk;
            vv[t] = K * clipADAA(v.clipIn, v.clipF, D * y);
        }
        v.hRe = hr; v.hIm = hi;
    } else {
        v.voiceLive = false;
        for (int t = 0; t < n; ++t) vv[t] = 0.f;
    }

    if (v.fading) {
        for (int t = 0; t < n; ++t) {
            vs[t] *= v.fadeGain; vv[t] *= v.fadeGain;
            v.fadeGain = std::max(0.f, v.fadeGain - v.fadeStep);
        }
        if (v.fadeGain <= 0.f) v.active = false;
    }
    for (int t = 0; t < n; ++t) {
        pianoL[t] += vs[t] * v.panL; pianoR[t] += vs[t] * v.panR;
        voiceL[t] += vv[t] * v.panL; voiceR[t] += vv[t] * v.panR;
        mono[t] += vs[t];
    }
}

void SingleNoteGrand::housekeeping() {
    for (auto &v : voices) {
        if (!v.active) continue;
        const float floorS = std::max(1e-8f * v.stringRef, 1e-14f);
        const float e = v.str.energyAndPrune(floorS);
        v.level = e;
        if (e <= 0.f && v.noise.left <= 0) v.active = false;
    }
    if (sympActive && sympGain.target == 0.f && sympGain.value < 1e-4f && symp.pruneIfSilent()) sympActive = false;
}

void SingleNoteGrand::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    for (Smoothed *s : {&fine, &hall, &space, &width, &octave, &breakDial}) s->next();
    // Fine tune glides (20 ms); retuning every ringing partial is costly, so it follows the glide every 4th block and
    // only for steps of a tenth of a cent or more (Felt Glass's rule). Phase-continuous.
    if (blockCount % 4 == 0) {
        const bool landed = std::fabs(fine.value - fine.target) < 0.01f && std::fabs(fine.target - appliedCents) > 1e-4f;
        if (landed || std::fabs(fine.value - appliedCents) > 0.1f) {
            appliedCents = landed ? fine.target : fine.value;
            fineRatio = std::exp2(appliedCents / 1200.f);
            retune();
        }
    }
    // The board darkens with warmth; the hall follows its dial.
    const float warm = clamp01(mWarmth);
    if (std::fabs(warm - appliedWarmth) > 1e-3f) {
        appliedWarmth = warm;
        board.configure(sr, kBoardLength, kBoardDark + 0.8 * (double)(warm - 0.5f));
    }
    const float hv = clamp01(hall.value);
    if (std::fabs(hv - appliedHall) > 2e-3f) {
        appliedHall = hv;
        reverb.setDecay(kHallTrim * hallSeconds(hv));
        reverb.configure(0.3f + 0.7f * hv, 0.35f + 0.3f * hv, 6.f + 24.f * hv, 0.f);
    }
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    const float wetTarget = dryHook ? 0.f : kWetMax * std::pow(sv, 0.8f) * (0.3f + 0.7f * hv);

    // The morph: the dial's floor plus the player's pressure the rest of the way, or the world's forced value; smoothed
    // once a block, rising with an 80 ms time constant and falling with 250 ms, so it never snaps (Review focus 3).
    float press = channelPressure;
    for (int k = 0; k < 128; ++k) if (keyHeld[k]) press = std::max(press, polyPressure[k]);
    const float forced = forcedIn.load(std::memory_order_relaxed);
    const float floorM = clamp01(pMorph);
    const float target = forced >= 0.f ? forced : floorM + (1.f - floorM) * clamp01(press);
    const float m0 = morph;
    morph += (1.f - std::exp(-dt / (target > morph ? kMorphUp : kMorphDown))) * (target - morph);
    if (std::fabs(target - morph) < 1e-6f) morph = target;
    const float m1 = morph;
    morphPermille.store((int)std::lround(1000.f * m1), std::memory_order_relaxed);

    // The repeat detector lets go once the gap has passed with no strike.
    if (repeatCount > 0 && (double)clock / sr - repeatLast > kRepeatGap + kRepeatSlack) {
        repeatCount = 0;
        repeating.store(false, std::memory_order_relaxed);
    }

    // A held key's string sings on as the morph rises; let go, or under the damper, it is a piano string.
    const float singTarget = kSingMax * std::pow(m1, kSingCurve);
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        const float s = v.keyDown && !v.damped ? singTarget : 0.f;
        if (std::fabs(s - v.sing) > 0.01f || (s == 0.f && v.sing != 0.f)) applySing(v, s);
    }

    // The voice's formants, drive and octave for this block.
    const bool voicePath = voiceOnly || m0 > 0.f || m1 > 0.f;
    if (voicePath) {
        const float wander = 1.f + 0.04f * std::max(0.f, 2.f * (clamp01(mMotion) - 0.5f)) * std::sin(kTwoPi * motionPhase);
        formantNow.setTargets(kF1Closed * std::pow(kF1Open / kF1Closed, m1) * wander, kF2Closed * std::pow(kF2Open / kF2Closed, m1) * wander);
        formantNow.update(1.f, fsr);
        const float D = kDrive * std::pow(kMorphGain, m1) * std::pow(10.f, kBreakDb * clamp01(breakDial.value) / 20.f)
                        * std::exp2(clamp01(mEnergy) - 0.5f);
        const float K = kVoiceLevel * std::sqrt(1.f / (D * D) + kRef * kRef);
        if (drive1 <= 0.f) { drive1 = D; makeup1 = K; }
        drive0 = drive1; makeup0 = makeup1;
        drive1 = D; makeup1 = K;
        const float od = clamp01(octave.value);
        octaveGain = 2.f * od;
        octaveNorm = 1.f / std::sqrt(1.f + 2.f * od * od);
        directGain = kDirect;
    } else {
        drive1 = 0.f;
    }
    motionPhase += 0.2f * dt;
    if (motionPhase >= 1.f) motionPhase -= 1.f;

    for (int t = 0; t < n; ++t) { pianoL[t] = pianoR[t] = voiceL[t] = voiceR[t] = mono[t] = 0.f; }
    float dryL[kSub] = {}, dryR[kSub] = {};
    if (!idle) {
        bool anyVoice = false;
        for (auto &v : voices) {
            if (!v.active) continue;
            anyVoice = true;
            renderVoice(v, n, voicePath);
        }
        if (sympActive) symp.render(mono, pianoL, pianoR, n, sympGain, kSympIn, kSympOut);
        // (1 − morph)·piano + morph·voice, the weight ramped across the block; then the board. The two are partly alike
        // (the voice is the same string), so halfway they sum about 2 dB under either alone: a common gain holds it.
        const float c0 = 1.f / std::sqrt(1.f - kBlend * m0 * (1.f - m0)), c1 = 1.f / std::sqrt(1.f - kBlend * m1 * (1.f - m1));
        float peakAbs = 0.f;
        for (int t = 0; t < n; ++t) {
            const float a = (float)(t + 1) / (float)n, w = lerp(m0, m1, a), c = lerp(c0, c1, a);
            const float pw = voiceOnly ? 0.f : (pianoOnly ? 1.f : c * (1.f - w)), vw = pianoOnly ? 0.f : (voiceOnly ? 1.f : c * w);
            float l = pw * pianoL[t] + vw * voiceL[t], r = pw * pianoR[t] + vw * voiceR[t];
            board.process(l, r);
            dryL[t] = l; dryR[t] = r;
            peakAbs = std::max(peakAbs, std::max(std::fabs(l), std::fabs(r)));
        }
        if (!anyVoice && !sympActive && peakAbs < 1e-6f) {
            idleSamples += n;
            if (idleSamples >= (int)(0.25f * fsr)) { idle = true; idleSamples = 0; board.clear(); }
        } else {
            idleSamples = 0;
        }
    } else {
        for (int t = 0; t < n; ++t) sympGain.next();
    }

    // The hall.
    float revL[kSub] = {}, revR[kSub] = {};
    if (!dryHook) {
        float sendL[kSub], sendR[kSub];
        for (int t = 0; t < n; ++t) { sendL[t] = reverbEmptying ? 0.f : dryL[t]; sendR[t] = reverbEmptying ? 0.f : dryR[t]; }
        reverb.process(sendL, sendR, revL, revR, n);
    }
    for (int t = 0; t < n; ++t) {
        wet += wetStep * (wetTarget - wet);
        float rg = wet;
        if (reverbEmptying) { reverbFade = std::max(0.f, reverbFade - reverbFadeStep); rg *= reverbFade; }
        float l = kMaster * (dryL[t] + rg * revL[t]), r = kMaster * (dryR[t] + rg * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (reverbEmptying && reverbFade <= 0.f) {
        // All sound off has run its course: the hall, the sympathetic strings and the board are emptied.
        reverb.clear();
        for (int k = 0; k < SympBank::kSymp; ++k) { symp.yre[k] = 0.f; symp.yim[k] = 0.f; }
        board.clear();
        reverbEmptying = false;
        reverbFade = 1.f;
    }
    if (++blockCount % 4 == 0) housekeeping();
}

} // namespace isd
