// Endless Rise: see EndlessRise.hpp, ShepardRise.hpp and docs/superpowers/briefs/endless-rise.md.
#include "EndlessRise.hpp"
#include "include/InStrumDSP.h"
#include <algorithm>
#include <cmath>

namespace isd {

namespace {

// Level and tone calibration (measured with the C++ mirror harness; see the commit that brought this engine in).
constexpr float kVoiceGain = 0.34f;        // a pad voice at velocity 127, before the master
constexpr float kRiseLevel = 0.070f;       // a riser stack's RMS at velocity 127 and tension 0
constexpr float kRiseTension = 0.4f;       // the riser comes forward with tension: +2.9 dB at 1
constexpr float kThumpGain = 0.55f;        // the thump's peak at Sub 1
constexpr float kMaster = 0.80f;
constexpr float kOscMix = 0.50f;           // the oscillators' sum into the drive and the ladder
constexpr float kShapeA = 0.62f;           // oscillator A: a pulse (about 40% wide), its width breathing slowly
constexpr float kPwmDepth = 0.06f;         // ± shape at mood motion 0.5
constexpr float kDetuneCents = 7.f;        // oscillator B sits up to this far above A; the pair is centred on the note…
constexpr float kMaxBeatHz = 1.2f;         // …and never beats faster than this (4.7 cents at A4), so it can't fight the Pulse
constexpr float kSawLevel = 0.5f;          // oscillator B against A: the pair's fundamentals beat about 4.7 dB deep
constexpr float kNoiseGain = 0.0126f;      // a breath of noise at −38 dB
constexpr float kResonance = 0.22f;
constexpr float kKeyTrack = 0.3f;
constexpr float kCutoffRest = 600.f;       // at Pressure .4 and tension 0…
constexpr float kTensionDecades = 1.f;     // …×10 at tension 1 (600 Hz → 6 kHz)
constexpr float kPressureOctaves = 2.5f;   // Pressure 0…1 moves the base −1 … +1.5 octaves around 600 Hz
constexpr float kBloomOctaves = 1.f, kBloomSeconds = 0.45f;   // the filter swells open over the first second
constexpr float kDecaySeconds = 3.f, kSustain = 0.8f;
constexpr float kPanicFade = 0.02f;
constexpr float kPadSend = 0.8f, kRiseSend = 1.4f, kWetMax = 0.5f;
constexpr float kDuckAttackSeconds = 0.012f, kDuckRelease = 0.6f;   // the pulse's duck: down in 12 ms, up by 60% of the beat
constexpr float kHardChordWindow = 0.040f, kHardChordVelocity = 0.78f;

inline float midiHz(float m) { return 440.f * std::exp2((m - 69.f) / 12.f); }
inline float velocityGain(int velocity) { return std::pow(0.35f + 0.65f * (float)std::clamp(velocity, 1, 127) / 127.f, 1.3f); }

/// The pulse's duck over one beat (0…1 of it): straight down in `attack` (12 ms, as a fraction of the beat), then back
/// up by 60% of the beat ((1 − s)², a sidechain's pump).
inline float duck(float ph, float attack) {
    if (ph < attack) return ph / attack;
    const float s = (ph - attack) / (kDuckRelease - attack);
    if (s >= 1.f) return 0.f;
    return (1.f - s) * (1.f - s);
}

/// Grit's soft drive at gain g (1…4): tanh(g·x)/g, lifted by √g so a moderate signal keeps about its level
/// (`norm` = 1/√g, worked out once a block).
inline float drive(float x, float g, float norm) { return analog::tanhApprox(g * x) * norm; }

} // namespace

EndlessRise::EndlessRise(double sampleRate) : sr(sampleRate), reverb(sampleRate, kSub) {
    limiter.init(sr);
    const double blockRate = sr / (double)kSub;   // the dials glide once per control block
    for (Smoothed *s : {&fine, &pressureDial, &grit, &pulse, &tail, &sub, &space, &width, &riserOn}) s->init(blockRate);
    fine.snap(0); pressureDial.snap(0.4f); grit.snap(0.3f); pulse.snap(0.5f); tail.snap(0.6f); sub.snap(0.7f);
    space.snap(0.5f); width.snap(0.6f); riserOn.snap(1.f);
    for (auto &p : keyPitch) p = -1.f;
    riser.prepare(sr);
    for (auto &h : padHP) h.set(25.f, 0.7071f, (float)sr);
    thumpDecay = (float)std::exp(-6.907755278982137 / ((double)kThumpT60 * sr));
    wetStep = (float)(1.0 - std::exp(-1.0 / (0.02 * sr)));
}

void EndlessRise::setParam(int address, float value, bool snap) {
    auto set = [&](Smoothed &s) { if (snap) s.snap(value); else s.setTarget(value); };
    switch (address) {
    case ISD_P_FINE_TUNE: set(fine); break;
    case ISD_P_TRANSPOSE: pTranspose = value; break;
    case ISD_P_RISE:
        riseDial = std::clamp(value, 0.f, 0.5f);
        if (snap) riserOn.snap(riseDial >= 0.005f ? 1.f : 0.f); else riserOn.setTarget(riseDial >= 0.005f ? 1.f : 0.f);
        break;
    case ISD_P_PRESSURE: set(pressureDial); break;
    case ISD_P_GRIT_ER: set(grit); break;
    case ISD_P_PULSE: set(pulse); break;
    case ISD_P_TEMPO_ER: tempo = std::clamp(value, 70.f, 170.f); break;
    case ISD_P_TAIL: set(tail); break;
    case ISD_P_SUB: set(sub); break;
    case ISD_P_SPACE: set(space); break;
    case ISD_P_WIDTH: set(width); break;
    case ISD_P_MOOD_ENERGY: mEnergy = value; break;
    case ISD_P_MOOD_WARMTH: mWarmth = value; break;
    case ISD_P_MOOD_BRIGHTNESS: mBright = value; break;
    case ISD_P_MOOD_SPACE: mSpace = value; break;
    case ISD_P_MOOD_MOTION: mMotion = value; break;
    case ISD_P_DEBUG_ER_PAD_ONLY: padOnly = value >= 0.5f; break;
    case ISD_P_DEBUG_ER_RISE_ONLY: riseOnly = value >= 0.5f; break;
    case ISD_P_DEBUG_ER_DRY: dryHook = value >= 0.5f; break;
    default: break;
    }
}

int EndlessRise::activeVoices() const {
    int n = 0;
    for (const auto &v : voices) if (v.active) ++n;
    return n;
}

int EndlessRise::debugCount(int which) const {
    if (which == ISD_DEBUG_DROPS) return drops;
    if (which == ISD_DEBUG_TENSION_PERMILLE) return (int)std::lround(1000.f * tension);
    return 0;
}

void EndlessRise::setTension(float t) { tensionIn.store(std::isfinite(t) ? clamp01(t) : 0.f, std::memory_order_relaxed); }

void EndlessRise::triggerDrop() { dropRequests.fetch_add(1u, std::memory_order_relaxed); }

// ---------- Keys and voices ----------

float EndlessRise::level(const Voice &v) const { return v.amp.level * v.gain * v.fadeGain; }

EndlessRise::Voice *EndlessRise::voiceFor(int note) {
    Voice *found = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note) continue;
        if (!found || v.age > found->age) found = &v;
    }
    return found;
}

EndlessRise::Voice &EndlessRise::allocate() {
    int sounding = 0;
    Voice *victim = nullptr;
    for (auto &v : voices) {
        if (!v.active || v.fading) continue;
        ++sounding;
        // Voices nobody holds go first (quietest first); otherwise the oldest held note.
        if (!victim) { victim = &v; continue; }
        if (v.held() != victim->held()) { if (!v.held()) victim = &v; continue; }
        if (!v.held() ? level(v) < level(*victim) : v.age < victim->age) victim = &v;
    }
    if (sounding >= kPolyphony && victim) beginFade(*victim);
    for (auto &v : voices) if (!v.active) return v;
    Voice *best = nullptr;
    for (auto &v : voices) if (v.fading && (!best || v.fadeGain < best->fadeGain)) best = &v;
    if (!best) best = &voices[0];
    best->active = false;
    return *best;
}

void EndlessRise::beginFade(Voice &v) {
    if (v.fading) return;
    v.fading = true;
    v.fadeStep = 1.f / (kPanicFade * (float)sr);
}

void EndlessRise::startVoice(Voice &v, int note, int velocity) {
    const float fsr = (float)sr;
    v = Voice{};
    v.active = true;
    v.keyDown = true;
    v.note = note;
    v.age = ++noteCounter;
    v.pitch = std::clamp((float)note + pTranspose, 0.f, 127.f);
    v.gain = velocityGain(velocity);
    v.pan = (float)((note * 7) % 12) / 5.5f - 1.f;
    // Free-running oscillators, the detuned pair centred on the note (power-weighted at the fundamental).
    v.oscA.setShape(kShapeA);
    v.oscA.reset(rng.uniform());
    v.oscB.reset(rng.uniform());
    const float f0 = midiHz(v.pitch);
    const float gA = analog::ShapeOsc::fundamentalGain(kShapeA), gA2 = gA * gA, gB2 = kSawLevel * kSawLevel;
    const float detune = std::min(kDetuneCents, 1200.f * std::log2(1.f + kMaxBeatHz / f0));
    const float centre = detune * gB2 / (gA2 + gB2);
    v.detuneA = -centre;
    v.detuneB = detune - centre;
    voiceSeed += 0x9E3779B97F4A7C15ULL;
    v.slop.seed(voiceSeed);
    v.pwmPhase = rng.uniform();
    v.pwmRate = 0.18f + 0.2f * rng.uniform();
    v.keyTrack = analog::keyTrack(f0, kKeyTrack);
    v.ladder.setResonance(kResonance);
    v.ladder.snapCutoff(cutoffBase * v.keyTrack * std::exp2(-kBloomOctaves), fsr);
    v.amp.setAttack(attackSeconds, fsr);
    v.amp.setDecay(kDecaySeconds, fsr);
    v.amp.setSustain(kSustain);
    v.amp.trigger(1.f);
}

/// Lets a voice's key (and the pedal) go: the release takes Tail as it is now, 0.6 → 3 s.
void EndlessRise::releaseVoice(Voice &v) {
    v.amp.setRelease(0.6f * std::exp2(clamp01(tail.value) * 2.3219281f), (float)sr);
    v.amp.release();
}

float EndlessRise::lowestHeld(int pc) const {
    for (int n = 0; n < 128; ++n)
        if (keyPitch[n] >= 0.f && ((int)std::lround(keyPitch[n]) % 12) == pc) return keyPitch[n];
    return -1.f;
}

/// A key of pitch class `pc` went up or the pedal let go: its riser stack follows what is still held.
void EndlessRise::classChanged(int pc) {
    const float home = lowestHeld(pc);
    if (home < 0.f) riser.letGo(pc);
    else riser.setHome(pc, home);
}

void EndlessRise::noteHardChord(int velocity) {
    const double now = (double)clock / sr;
    recentTime[recentHead] = now;
    recentVel[recentHead] = (float)std::clamp(velocity, 0, 127) / 127.f;
    recentHead = (recentHead + 1) % kRecent;
    recentCount = std::min(recentCount + 1, kRecent);
    int n = 0;
    float v = 0.f;
    for (int i = 0; i < recentCount; ++i) {
        if (now - recentTime[i] > (double)kHardChordWindow + 1e-9) continue;
        ++n;
        v += recentVel[i];
    }
    // Without Excitement (and with it, in step with its own rule): a hard chord once the tension has gathered.
    if (n >= 3 && v / (float)n >= kHardChordVelocity && sinceArmed <= (double)kArmedHold) takeDrop();
}

void EndlessRise::noteOn(int note, int velocity) {
    if (velocity <= 0) { noteOff(note); return; }
    note &= 127;
    bool phrase = true;   // nothing sounding: the pulse's grid starts on this note
    for (const auto &v : voices) if (v.active && !v.fading) { phrase = false; break; }
    if (phrase) pulseBeats = 0.0;
    // A key struck again while its note still sounds takes a fresh voice; the old one fades.
    if (Voice *old = voiceFor(note)) beginFade(*old);
    Voice &v = allocate();
    startVoice(v, note, velocity);
    keyDown[note] = true;
    keySustained[note] = false;
    keyPitch[note] = v.pitch;
    const int pc = (int)std::lround(v.pitch) % 12;
    riser.press(pc, lowestHeld(pc), v.gain);
    noteHardChord(velocity);
}

void EndlessRise::noteOff(int note) {
    note &= 127;
    if (!keyDown[note]) return;
    keyDown[note] = false;
    for (auto &v : voices) {
        if (!v.active || v.fading || v.note != note || !v.keyDown) continue;
        v.keyDown = false;
        if (sustain) v.sustained = true;
        else releaseVoice(v);
    }
    if (sustain) { keySustained[note] = true; return; }
    const float p = keyPitch[note];
    keyPitch[note] = -1.f;
    if (p >= 0.f) classChanged((int)std::lround(p) % 12);
}

void EndlessRise::setSustain(bool down) {
    if (down == sustain) return;
    sustain = down;
    if (down) return;
    for (auto &v : voices) {
        if (!v.active || v.fading || !v.sustained) continue;
        v.sustained = false;
        if (!v.keyDown) releaseVoice(v);
    }
    for (int n = 0; n < 128; ++n) {
        if (!keySustained[n]) continue;
        keySustained[n] = false;
        const float p = keyPitch[n];
        keyPitch[n] = -1.f;
        if (p >= 0.f) classChanged((int)std::lround(p) % 12);
    }
}

void EndlessRise::pitchBend(float semitones) { bendTarget = std::clamp(semitones, -2.f, 2.f); }

void EndlessRise::aftertouch(int note, float pressure) {
    const float p = clamp01(pressure);
    if (note < 0) channelPressure = p; else polyPressure[note & 127] = p;
}

void EndlessRise::resetTouch() {
    bendTarget = bendMid = bendNow = 0.f;
    channelPressure = pressureNow = 0.f;
    for (auto &p : polyPressure) p = 0.f;
}

void EndlessRise::allNotesOff() {
    for (auto &v : voices) if (v.active) beginFade(v);
    riser.fadeAll(kPanicFade);
    if (thumpOn && !thumpFading) { thumpFading = true; thumpFadeStep = 1.f / (kPanicFade * (float)sr); }
    for (int n = 0; n < 128; ++n) { keyDown[n] = keySustained[n] = false; keyPitch[n] = -1.f; }
    sustain = false;
    dropAge = 1e9;
    dropRelease = 0.f;
    recentCount = 0;
    sinceArmed = 1e9;
    resetTouch();
}

void EndlessRise::allSoundOff() {
    allNotesOff();
    // The reverb empties over a little longer than the voices fade, and takes nothing in meanwhile.
    reverbEmptying = true;
    reverbFadeStep = 1.f / (1.25f * kPanicFade * (float)sr);
}

// ---------- The drop ----------

void EndlessRise::takeDrop() {
    // Review focus 2: a second drop does nothing until the first's release envelope has passed 0.2 and its 2.5 s
    // have run (the envelope falls 1 → 0 over the 2.5 s, as ExcitementFrame.drop does, so the 2.5 s rule is the later).
    if (dropRelease > 0.2f || dropAge < (double)kDropSeconds) return;
    dropAge = 0.0;
    dropRelease = 1.f;
    ++drops;
    sinceArmed = 1e9;   // a hard chord needs the tension to gather again
    riser.drop();
    thumpOn = true;
    thumpFading = false;
    thumpFade = 1.f;
    thumpPhase = 0.0;
    thumpEnv = 1.f;
    thumpLevel = kThumpGain * clamp01(sub.value) * (0.85f + 0.3f * clamp01(mWarmth));
}

// ---------- Rendering ----------

void EndlessRise::render(float *left, float *right, int frames) {
    DenormalGuard guard;
    int pos = 0;
    while (pos < frames) {
        const int n = std::min(kSub, frames - pos);
        processBlock(left + pos, right + pos, n);
        pos += n;
        clock += n;
    }
}

void EndlessRise::renderVoice(Voice &v, float *l, float *r, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    v.slop.advance(dt);
    const float f0 = midiHz(v.pitch + bendNow + 0.01f * fine.value);
    const float incA = std::min(analog::kMaxIncrement, f0 * std::exp2((v.detuneA + v.slop.pitchCents(0, slopDepth)) / 1200.f) / fsr);
    const float incB = std::min(analog::kMaxIncrement, f0 * std::exp2((v.detuneB + v.slop.pitchCents(1, slopDepth)) / 1200.f) / fsr);
    // The pulse's width breathes slowly.
    v.pwmPhase += v.pwmRate * dt;
    if (v.pwmPhase >= 1.f) v.pwmPhase -= 1.f;
    v.oscA.setShape(kShapeA + pwmDepth * std::sin(kTwoPi * v.pwmPhase));
    // The filter: Pressure's base, the swell, key tracking and the slop, opened by tension (or the drop's snap).
    v.bloom += (1.f - std::exp(-dt / kBloomSeconds)) * (1.f - v.bloom);
    const float t = std::max(tension, dropRelease);
    const float cutoff = cutoffBase * v.keyTrack * v.slop.cutoffRatio(slopDepth)
                         * std::exp2(3.3219281f * kTensionDecades * t - kBloomOctaves * (1.f - v.bloom));
    v.ladder.setCutoff(cutoff, fsr, n);
    const float g = kVoiceGain * v.gain;
    const float w = clamp01(width.value);
    const float p = std::clamp(0.7f * w * v.pan, -1.f, 1.f);
    const float gl = std::sqrt(0.5f * (1.f - p)) * g, gr = std::sqrt(0.5f * (1.f + p)) * g;
    const float dIn = driveIn, dOut = driveOut, nIn = 1.f / std::sqrt(dIn), nOut = 1.f / std::sqrt(dOut);
    const bool driven = dIn > 1.0001f;
    for (int i = 0; i < n; ++i) {
        float x = kOscMix * (v.oscA.next(incA) + kSawLevel * v.oscB.next(incB) + kNoiseGain * breath[i]);
        if (driven) x = drive(x, dIn, nIn);
        float y = v.ladder.process(x);
        if (driven) y = drive(y, dOut, nOut);
        y *= v.amp.next();
        if (v.fading) {
            v.fadeGain -= v.fadeStep;
            if (v.fadeGain <= 0.f) { v.fadeGain = 0.f; v.active = false; }
            y *= v.fadeGain;
        }
        l[i] += y * gl;
        r[i] += y * gr;
        if (!v.active) break;
    }
    if (v.active && !v.held() && v.amp.idle()) v.active = false;
}

void EndlessRise::processBlock(float *left, float *right, int n) {
    const float fsr = (float)sr, dt = (float)n / fsr;
    for (Smoothed *s : {&fine, &pressureDial, &grit, &pulse, &tail, &sub, &space, &width, &riserOn}) s->next();
    // The wheel through two 4 ms smoothers: there within about 25 ms.
    const float kb = 1.f - std::exp(-(float)n / (0.004f * fsr));
    bendMid += kb * (bendTarget - bendMid);
    bendNow += kb * (bendMid - bendNow);
    // Tension: the world's (an atomic, read once here) plus 0.3 × pressure, smoothed over 50 ms so it never steps.
    float press = channelPressure;
    for (int k = 0; k < 128; ++k) if (keyPitch[k] >= 0.f) press = std::max(press, polyPressure[k]);
    pressureNow += (1.f - std::exp(-dt / 0.03f)) * (press - pressureNow);
    const float world = tensionIn.load(std::memory_order_relaxed);
    tension += (1.f - std::exp(-dt / 0.05f)) * (clamp01(world + 0.3f * pressureNow) - tension);
    if (tension > kDropArmed) sinceArmed = 0.0; else sinceArmed += (double)dt;
    // The drop, once a block (however many calls arrived since the last).
    const unsigned asked = dropRequests.load(std::memory_order_relaxed);
    if (asked != dropsSeen) { dropsSeen = asked; takeDrop(); }
    dropRelease = dropAge < (double)kDropSeconds ? 1.f - (float)(dropAge / (double)kDropSeconds) : 0.f;

    // The mood under the dials.
    slopDepth = dryHook ? 0.f : 0.5f + clamp01(mMotion);
    pwmDepth = dryHook ? 0.f : kPwmDepth * (0.5f + clamp01(mMotion));
    const float gr = dryHook ? 0.f : clamp01(grit.value);
    // Grit: 0…12 dB into the ladder (the spec's soft drive), and the same on its output stage, as a hard-driven
    // analogue ladder saturates. Before a linear filter alone a drive can't add harmonics above the cutoff (a dark
    // note's 3rd harmonic stayed within 1 dB); with the output stage Grit 1 lifts it 18–25 dB, the level held.
    driveIn = std::exp2(2.f * gr);
    driveOut = std::exp2(2.f * gr);
    cutoffBase = kCutoffRest * std::exp2(kPressureOctaves * (clamp01(pressureDial.value) - 0.4f)
                                         + 0.6f * (clamp01(mBright) - 0.5f) - 0.3f * (clamp01(mWarmth) - 0.5f));
    attackSeconds = 0.6f * (1.3f - 0.6f * clamp01(mEnergy));
    const float sv = clamp01(space.value + 0.6f * (mSpace - 0.5f));
    if (std::fabs(sv - appliedSpace) > 2e-3f) { appliedSpace = sv; reverb.configure(0.45f + 0.45f * sv, 0.45f, 18.f, 0.f); }

    float padL[kSub] = {}, padR[kSub] = {}, riseL[kSub] = {}, riseR[kSub] = {};
    for (int t = 0; t < n; ++t) breath[t] = noise.next();   // one breath of noise for every voice this block
    for (auto &v : voices) if (v.active) renderVoice(v, padL, padR, n);
    // Below the notes: the drive is symmetric, so one sub-sonic high-pass on the pad's sum does what one per voice did.
    for (int t = 0; t < n; ++t) { padL[t] = padHP[0].process(padL[t]); padR[t] = padHP[1].process(padR[t]); }
    shepard::Riser::Controls rc;
    rc.rise = riseDial >= 0.005f ? std::max(0.02f, riseDial) : 0.f;
    rc.tension = tension;
    rc.bendOct = bendNow / 12.f;
    rc.fineOct = fine.value / 1200.f;
    rc.level = kRiseLevel * (1.f + kRiseTension * tension) * clamp01(riserOn.value);
    rc.width = clamp01(width.value);
    riser.render(riseL, riseR, n, rc);
    dropAge += (double)dt;

    // The pulse (a duck on every beat), the thump and the mix.
    const float depth = dryHook ? 0.f : std::min(0.95f, 0.9f * clamp01(pulse.value) * (0.8f + 0.4f * clamp01(mEnergy)));
    const double beat = (double)tempo / 60.0 / sr;
    const float attackBeats = kDuckAttackSeconds * tempo / 60.f;
    const float padGain = riseOnly ? 0.f : 1.f, riseGain = padOnly ? 0.f : 1.f;
    const bool reverbOn = !dryHook;
    float sendL[kSub], sendR[kSub], thump[kSub];
    for (int t = 0; t < n; ++t) {
        const float ph = (float)(pulseBeats - std::floor(pulseBeats));
        const float pg = (1.f - depth * duck(ph, attackBeats)) * padGain;
        pulseBeats += beat;
        padL[t] *= pg;
        padR[t] *= pg;
        riseL[t] *= riseGain;
        riseR[t] *= riseGain;
        float th = 0.f;
        if (thumpOn) {
            // From phase 0, so it starts at zero: no click and no attack needed.
            th = thumpLevel * thumpEnv * (float)std::sin(2.0 * 3.14159265358979323846 * thumpPhase);
            thumpPhase += (double)kThumpHz / sr;
            if (thumpPhase >= 1.0) thumpPhase -= 1.0;
            thumpEnv *= thumpDecay;
            if (thumpFading) {
                thumpFade = std::max(0.f, thumpFade - thumpFadeStep);
                th *= thumpFade;
                if (thumpFade <= 0.f) thumpOn = false;
            }
            if (thumpEnv < 1e-6f) thumpOn = false;
        }
        thump[t] = th * riseGain;
        sendL[t] = reverbEmptying ? 0.f : kPadSend * padL[t] + kRiseSend * riseL[t];
        sendR[t] = reverbEmptying ? 0.f : kPadSend * padR[t] + kRiseSend * riseR[t];
    }
    float revL[kSub] = {}, revR[kSub] = {};
    if (reverbOn) reverb.process(sendL, sendR, revL, revR, n);
    const float wetTarget = reverbOn ? kWetMax * std::pow(sv, 0.8f) : 0.f;
    for (int t = 0; t < n; ++t) {
        wet += wetStep * (wetTarget - wet);
        float rg = wet;
        if (reverbEmptying) { reverbFade = std::max(0.f, reverbFade - reverbFadeStep); rg *= reverbFade; }
        float l = kMaster * (padL[t] + riseL[t] + thump[t] + rg * revL[t]);
        float r = kMaster * (padR[t] + riseR[t] + thump[t] + rg * revR[t]);
        limiter.process(l, r);
        left[t] = softLimit(l);
        right[t] = softLimit(r);
    }
    if (reverbEmptying && reverbFade <= 0.f) {
        // All sound off has run its course: the reverb and the pad's high-pass are emptied, so nothing rings on.
        reverb.clear();
        for (auto &h : padHP) h.reset();
        reverbEmptying = false;
        reverbFade = 1.f;
    }
    ++blockCount;
}

} // namespace isd
