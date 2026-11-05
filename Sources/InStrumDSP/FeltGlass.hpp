// Felt Glass: a modelled felt piano (modal strings with inharmonicity and unison beating,
// felt hammer, damper, soundboard body, sympathetic ring) plus an inharmonic glass-bell
// bloom layer, finished in the shared Space reverb. Everything is preallocated.
#pragma once
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "SpaceReverb.hpp"
#include "PianoStrings.hpp"

namespace isd {

class FeltGlass final : public Engine {
public:
    explicit FeltGlass(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    void allNotesOff() override;
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int debugCount(int which) const override { return which == 0 ? retunes : 0; }
    int activeVoices() const override;

    static constexpr int kPolyphony = 32;   // sounding voices
    static constexpr int kPool = 40;        // plus voices fading out after being stolen
    static constexpr int kSub = 32;         // samples per inner block
    static constexpr int kStrings = 64;     // string components per voice
    static constexpr int kGlass = 16;       // glass components per voice

private:
    struct Voice {
        bool active = false, keyDown = false, damped = false, fading = false;
        int note = 0, pitch = 0;
        float amp = 0;                 // A(v) × register gain
        float panL = 0.7071f, panR = 0.7071f;
        int attackPos = 0, attackLen = 1;
        float fadeGain = 1, fadeStep = 0;
        float level = 0, stringRef = 0, glassRef = 0;
        StringBank<kStrings> str;      // the strings' partials
        StringBank<kGlass> glass;      // the glass bloom's partials
        FeltNoise noise;               // the felt's contact thump, then the damper's touch
        float noiseHz = 300, noteRms = 0;
    };

    void startVoice(Voice &v, int note, int pitch, int velocity);
    Voice &allocate();
    void damp(Voice &v);
    void beginFade(Voice &v);
    void retune();
    void setSympDecay(float t60) { symp.setDecay(t60, fineRatio); }
    void processBlock(float *left, float *right, int n);
    void renderVoice(Voice &v, float *sL, float *sR, float *gL, float *gR, float *mono, int n);
    void renderSymp(const float *mono, float *sL, float *sR, int n);
    void housekeeping();

    double sr;
    Voice voices[kPool];
    bool sustain = false;
    FastRandom rng;

    // Dials (raw) and mood.
    float pFine = 0, pTranspose = 0, pFelt = 0.55f, pRing = 0.55f, pWidth = 0.5f;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, glassGain, warmth, space, wet, sympGain;
    float fineRatio = 1, appliedCents = 0, appliedWarmth = -1, appliedSpace = -1;

    SoundBoard board;
    Biquad lowShelf[2], highShelf[2];
    SympBank symp;
    bool sympActive = false;

    SpaceReverb reverb;
    PeakLimiter limiter;
    bool idle = true, reverbLive = false;
    int idleSamples = 0, retunes = 0;
    unsigned blockCount = 0;   // wraps after 2^32 blocks, a multiple of 4: every-fourth-block work keeps its cadence
};

} // namespace isd
