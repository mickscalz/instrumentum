// Single Note Grand (Lightning Plains, after "Runaway"): a cavernous concert grand that becomes a voice under pressure.
// Engine 17, on Felt Glass's string core (PianoStrings.hpp) with the analogue core's formant pair (AnalogVoice.hpp).
// Spec §4.2 of docs/superpowers/specs/2026-11-05-storms-design.md; brief docs/superpowers/briefs/single-note-grand.md.
//
// The grand: each strike a voice (16, with spares so a stolen one fades) on the shared grand string (grandString: Felt
// Glass's inharmonic, felt-hammered partials) with the felt at Felt (0.2 by default) and a concert grand's long ring,
// its felt contact thump and damper touch (FeltNoise), sympathetic strings under the pedal (SympBank), and the shared
// soundboard made longer (its modes ÷ 1.35) and darker; then the hall: the Space reverb with its decay set by Hall
// (2.8 s at .7 as heard, about 4.6 s at 1 and 1 s at .1), its size, pre-delay and share growing with it, and Space
// setting how much of it.
//
// The voice: fed by the same string, never retuned. Each voice's string (its whole signal, contact thump included)
// runs through two formants, F1 400 → 700 Hz and F2 1200 → 1800 Hz as the morph rises (bandwidths 80 and 120 Hz; both
// in phase at their centres, so they dip between them and never turn the piano they are mixed with against itself),
// beside a direct path of the string's own first partial (an exact copy of its phasors: the voice's body and its
// pitch). Into a tanh clipper (first-order antiderivative anti-aliased) at a drive of 1 → 8 with the morph (18 dB), and
// 0–30 dB more with Break; a make-up gain holds a typical strike's level, so Break and pressure change the tone, not
// the loudness. Octave Down ring-modulates the voice's input with the half-angle of the first partial's own phasor
// (a cosine at f0/2, locked to the string): the string's partials gain sidebands at every odd multiple of f0/2 (an
// octave-down series the formants sing as the same vowel), at Octave Down 1 the f0/2 line as strong as f0.
// While its key is held, a voice's string sings on: every partial's decay stretches toward none (its t60 × 25 at
// Morph 1), so a pressed note holds like a sung one; let go, it is a piano string again and the dampers take it.
//
// The morph: morph = smooth(target, 80 ms up, 250 ms down) once per control block, where the target is the Morph dial
// (a floor) plus the rest of the way by the player's pressure (channel pressure, or the strongest held key's), or the
// world's forced morph while one is set (isd_synth_set_forced_morph: an atomic read once a block; negative releases
// it, and the same smoothing hands the morph back to the player's pressure: Review focus 3). The output is
// (1 − morph)·piano + morph·voice, the weight ramped across each block and both held up by 1/√(1 − 1.4·m(1 − m)) (the
// voice is the same string, so halfway the two would sum about 2 dB under either alone), then the board and the hall.
//
// Repeats: the same key struck four or more times with at most 0.5 s between strikes (2 a second or faster) sets
// `repeating` (an atomic, any thread); a different key, or 0.5 s with no strike, clears it. Control-rate bookkeeping.
// Everything is preallocated; the render thread never allocates.
#pragma once
#include "AnalogVoice.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "PianoStrings.hpp"
#include "SpaceReverb.hpp"
#include <atomic>
#include <cstdint>

namespace isd {

class SingleNoteGrand final : public Engine {
public:
    explicit SingleNoteGrand(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    /// Every voice fades out over 20 ms; the hall's tail continues. The player's pressure is let go.
    void allNotesOff() override;
    /// As allNotesOff, and the hall fades and empties too: silent within 50 ms.
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    int debugCount(int which) const override;
    void aftertouch(int note, float pressure) override;
    /// Any thread: the world's morph (0…1) over the player's pressure; negative releases it.
    void setForcedMorph(float morph) override;
    /// Any thread: the repeat detector's flag.
    bool isRepeating() const override { return repeating.load(std::memory_order_relaxed); }

    static constexpr int kPolyphony = 16;   // sounding voices
    static constexpr int kPool = 20;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per control block
    static constexpr int kStrings = 64;     // string components per voice
    static constexpr float kMorphUp = 0.080f, kMorphDown = 0.250f;   // the morph's smoothing (time constants, s)
    static constexpr int kRepeatStrikes = 4;
    static constexpr double kRepeatGap = 0.5;                        // the longest gap between repeated strikes (s)

private:
    struct Voice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        float level = 0;               // the string's energy, for stealing the quietest
        float panL = 0.7071f, panR = 0.7071f;
        int attackPos = 0, attackLen = 1;
        float fadeGain = 1, fadeStep = 0;
        float stringRef = 0, noteRms = 0, noiseHz = 300;
        StringBank<kStrings> str;      // the string's partials
        FeltNoise noise;               // the felt's contact thump, then the damper's touch
        float lnDecay[kStrings];       // ln of each component's own per-sample decay (for singing)
        float sing = 0;                // the share of decay taken away while the key is held (0 = a piano string)
        int fundamental = 0;           // components of the first partial (the direct path's copy)
        // The voice path.
        bool voiceLive = false;
        analog::TwoFormant formant;    // the formant pair (its coefficients copied in each block; its own state)
        float hRe = 1.f, hIm = 0.f;    // the half-angle phasor: h² is the first partial's phase
        double clipIn = 0.0, clipF = 0.0;   // the ADAA clipper's last input and its antiderivative (NaN: not taken)
    };

    Voice &allocate();
    void startVoice(Voice &v, int note, int pitch, int velocity);
    void beginFade(Voice &v);
    void damp(Voice &v);
    void applySing(Voice &v, float s);
    void retune();
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, int n, bool voicePath);
    void housekeeping();
    void noteRepeat(int note);
    void resetTouch();

    double sr;
    Voice voices[kPool];
    bool sustain = false, pianoOnly = false, voiceOnly = false, dryHook = false;
    bool keyHeld[128] = {};
    FastRandom rng;

    // Dials (raw where they act per note, smoothed per control block where they act live) and mood.
    float pTranspose = 0, pFelt = 0.2f, pMorph = 0.f;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, hall, space, width, octave, breakDial;
    float fineRatio = 1, appliedCents = 0, appliedWarmth = -1, appliedHall = -1;

    // Pressure and the morph.
    float channelPressure = 0, polyPressure[128] = {};
    std::atomic<float> forcedIn{-1.f};
    float morph = 0.f;                 // the morph in use (smoothed), 0…1
    std::atomic<int> morphPermille{0};
    float motionPhase = 0.f;

    // Per-block values shared by the voices: the formant pair's coefficients (one pair of band-passes, copied into each
    // voice so each keeps its own state), the drive and make-up at the block's start and end, the octave.
    analog::TwoFormant formantNow;
    float drive0 = 1, drive1 = 1, makeup0 = 1, makeup1 = 1, octaveGain = 0, octaveNorm = 1, directGain = 0;

    // The buses of one block.
    float pianoL[kSub], pianoR[kSub], voiceL[kSub], voiceR[kSub], mono[kSub];

    // The repeat detector (render thread; the flag is read anywhere).
    int repeatNote = -1, repeatCount = 0;
    double repeatLast = -1e9;
    std::atomic<bool> repeating{false};

    SoundBoard board;
    SympBank symp;
    Smoothed sympGain;
    bool sympActive = false;
    SpaceReverb reverb;
    PeakLimiter limiter;
    float wet = 0, wetStep = 0;
    float reverbFade = 1, reverbFadeStep = 0;
    bool reverbEmptying = false;
    bool idle = true;
    int idleSamples = 0;
    int64_t clock = 0;
    unsigned blockCount = 0;
};

} // namespace isd
