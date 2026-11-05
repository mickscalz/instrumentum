// Endless Rise (Supercell Sky, after "FADE"): a pressure pad with a Shepard–Risset riser that climbs for as long as
// you hold it and never arrives, until the drop resolves it. Engine 16, on the analogue voice core (AnalogVoice.hpp)
// with the riser from ShepardRise.hpp (spec §4.1 of docs/superpowers/specs/2026-11-05-storms-design.md; brief
// docs/superpowers/briefs/endless-rise.md).
//
// The Pressure Pad: each key a voice (8, with spares so a stolen one fades): a pulse (oscillator A, its width
// breathing slowly) and a saw at half its level a few cents above it (never beating faster than 1.2 Hz), the pair
// centred on the note, through Grit (a soft drive into the ladder, 0–12 dB, and the same on the ladder's output stage,
// as a hard-driven analogue ladder saturates) and the ZDF ladder; one 25 Hz high-pass on the voices' sum keeps the
// sub-sonic out. It swells in, its filter blooming open over the first second. Pressure sets the filter's base,
// Tension opens it from 600 Hz to 6 kHz (at Pressure .4), and Tail sets the release (0.6–3 s). Pulse is a
// tempo-locked tremolo on the pad, a sidechain-style duck on every beat at Tempo (70–170 BPM: down in 12 ms, back by
// 60% of the beat; Pulse .5 dips about 5 dB), its grid starting with each phrase.
// The riser: a Shepard–Risset stack per held pitch class, climbing at Rise × (1 + 3·tension) octaves a second.
// Tension (0…1) is isd_synth_set_tension's value plus 0.3 × pressure (channel, or the strongest held key's), read
// from an atomic once per control block and smoothed, so the climb, the filter and the riser's level move
// continuously. The drop (isd_synth_trigger_drop, or a hard chord: three note-ons within 40 ms at mean velocity
// ≥ 0.78, while tension is or has within 2.5 s been above 0.6): the riser resolves (ShepardRise.hpp), the pad's
// filter snaps open and closes again over 2.5 s with the release envelope (1 → 0, as ExcitementFrame.drop), and a 48 Hz
// sine thump fires (Sub sets its level; −60 dB 400 ms after it starts). A second drop is ignored until the release
// envelope has passed 0.2 and 2.5 s have gone by (Review focus 2). The wheel bends everything ±2 semitones.
// Everything is preallocated; the render thread never allocates.
#pragma once
#include "AnalogVoice.hpp"
#include "DSPCommon.hpp"
#include "Engine.hpp"
#include "ShepardRise.hpp"
#include "SpaceReverb.hpp"
#include <atomic>
#include <cstdint>

namespace isd {

class EndlessRise final : public Engine {
public:
    explicit EndlessRise(double sampleRate);
    void setParam(int address, float value, bool snap) override;
    void noteOn(int note, int velocity) override;
    void noteOff(int note) override;
    void setSustain(bool down) override;
    /// Every pad voice and every riser stack fades out over 20 ms, as does the thump; the drop is over and the pulse's
    /// grid starts afresh with the next phrase. The reverb's tail continues.
    void allNotesOff() override;
    /// As allNotesOff, and the reverb fades and empties too: silent within 50 ms.
    void allSoundOff() override;
    void render(float *left, float *right, int frames) override;
    int activeVoices() const override;
    int debugCount(int which) const override;
    void pitchBend(float semitones) override;
    void aftertouch(int note, float pressure) override;
    /// Any thread: the tension from the world (0…1). Read once per control block.
    void setTension(float tension) override;
    /// Any thread: the drop. Taken at the next control block, unless the last one is still within its 2.5 s.
    void triggerDrop() override;

    static constexpr int kPolyphony = 8;
    static constexpr int kPool = 12;         // spares, so a stolen voice still fades
    static constexpr int kSub = 32;          // samples per control block
    static constexpr float kThumpHz = 48.f;
    static constexpr float kThumpT60 = 0.4f;  // seconds to −60 dB
    static constexpr float kDropSeconds = 2.5f;
    static constexpr float kDropArmed = 0.6f, kArmedHold = 2.5f;   // the hard-chord drop's tension, and its memory
    /// One beat at the Tempo.
    static float beatSeconds(float bpm) { return 60.f / bpm; }

private:
    struct Voice {
        bool active = false, fading = false, keyDown = false, sustained = false;
        int note = 0;
        unsigned age = 0;
        float pitch = 0, gain = 0, pan = 0;
        float detuneA = 0, detuneB = 0, keyTrack = 1;
        float bloom = 0;                     // the filter's swell, 0 → 1 over the first second
        float pwmPhase = 0, pwmRate = 0.25f;
        analog::ShapeOsc oscA;
        analog::SawOsc oscB;
        analog::Slop slop;
        analog::Ladder ladder;
        analog::ADSR amp;
        float fadeGain = 1, fadeStep = 0;
        bool held() const { return keyDown || sustained; }
    };

    Voice *voiceFor(int note);
    Voice &allocate();
    void startVoice(Voice &v, int note, int velocity);
    void beginFade(Voice &v);
    void releaseVoice(Voice &v);
    float level(const Voice &v) const;
    void renderVoice(Voice &v, float *l, float *r, int n);
    void processBlock(float *left, float *right, int n);
    void takeDrop();
    void noteHardChord(int velocity);
    void classChanged(int pc);
    float lowestHeld(int pc) const;
    void resetTouch();

    double sr;
    Voice voices[kPool];
    bool sustain = false, padOnly = false, riseOnly = false, dryHook = false;
    unsigned noteCounter = 0;
    uint64_t voiceSeed = 0xE7D1E55A15EULL;
    FastRandom rng{0x5E9A7D0F1A5EULL};
    analog::Noise noise{0x0E7D1E55ULL};
    float breath[kSub] = {};
    analog::HighPass padHP[2];

    // Keys: the sounding pitch of each key held (by hand or pedal), or −1.
    float keyPitch[128];
    bool keyDown[128] = {}, keySustained[128] = {};

    // Dials (smoothed per control block where they act live) and mood.
    float pTranspose = 0, riseDial = 0.08f, tempo = 124.f;
    float mEnergy = 0.5f, mWarmth = 0.5f, mBright = 0.5f, mSpace = 0.5f, mMotion = 0.5f;
    Smoothed fine, pressureDial, grit, pulse, tail, sub, space, width, riserOn;
    float appliedSpace = -1;

    // Performance.
    float bendTarget = 0, bendMid = 0, bendNow = 0;
    float channelPressure = 0, polyPressure[128] = {};
    float pressureNow = 0;
    std::atomic<float> tensionIn{0.f};
    std::atomic<unsigned> dropRequests{0};
    unsigned dropsSeen = 0;
    float tension = 0;               // the tension in use: smoothed, 0…1
    double sinceArmed = 1e9;         // seconds since the tension was last above 0.6
    // The hard chord: recent note-ons.
    static constexpr int kRecent = 16;
    double recentTime[kRecent] = {};
    float recentVel[kRecent] = {};
    int recentHead = 0, recentCount = 0;

    // The drop: its age, release envelope (1 → 0 over 2.5 s) and how many were taken.
    double dropAge = 1e9;
    float dropRelease = 0;
    int drops = 0;

    // The thump: a 48 Hz sine from phase 0, decaying.
    bool thumpOn = false;
    double thumpPhase = 0;
    float thumpEnv = 0, thumpDecay = 0, thumpLevel = 0;
    float thumpFade = 1, thumpFadeStep = 0;
    bool thumpFading = false;

    // The pulse: beats since the phrase began.
    double pulseBeats = 0;

    // Per-block values shared by the voices.
    float cutoffBase = 600.f, slopDepth = 1.f, pwmDepth = 0.f, driveIn = 1.f, driveOut = 1.f, attackSeconds = 0.6f;

    shepard::Riser riser;
    SpaceReverb reverb;
    PeakLimiter limiter;
    float wet = 0, wetStep = 0;
    float reverbFade = 1, reverbFadeStep = 0;
    bool reverbEmptying = false;
    int64_t clock = 0;
    int blockCount = 0;
};

} // namespace isd
