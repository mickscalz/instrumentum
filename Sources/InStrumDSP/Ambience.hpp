// Ambience: fifty sources generated live (never loops), each gliding to its level over 2.5 s, through a
// small room whose amount follows "closeness", ducking under the instrument while you play. Outdoor sources can be
// heard through a window ("indoors"): darker and quieter, while the indoor ones stay close. In-key sources (the
// temple bell, the sonar, the inflow roar, the heat shimmer) follow the key the player is in. Thunder can be queued to
// arrive late by its distance (the picture first, the sound after).
// Everything is preallocated; the setters are lock-free atomics read at the start of each render.
#pragma once
#include "DSPCommon.hpp"
#include "SpaceReverb.hpp"
#include "include/InStrumDSP.h"
#include <atomic>
#include <memory>

namespace isd {

struct AmbienceContext {
    float sr = 48000.f;
    float density = 1.f;     // multiplies event rates
    float cool = 0.f;        // night cool 0…1
    float speed = 0.f;       // a car's speed 0…1 (road, engine, window wind), gliding over half a second
    float surfDistance = 0.f;// 0 close surf … 1 a far, low roar
    float wetness = 0.f;     // a wet road hisses
    float snowOnGlass = 0.f; // rain on the glass becomes soft snow ticks
    int keyRoot = 4;         // the key the player is in (C = 0; E until one is sensed), for in-key sources
    bool keyMajor = true;
};

/// One generator. `render` adds its sound (calibrated for level 1) into `l`/`r`.
class AmbienceSource {
public:
    virtual ~AmbienceSource() = default;
    /// Called when the source comes up from silence: schedule events afresh.
    virtual void wake(const AmbienceContext &) {}
    /// Its next event now (tests): the birds take flight, a truck crosses the grid, a far truck passes. Most have none.
    virtual void triggerNow(const AmbienceContext &) {}
    virtual void render(float *l, float *r, int n, const AmbienceContext &c) = 0;
    float direct = 1.f, send = 0.5f;   // how much goes straight out and how much into the room
    /// Indoors (or at the glass itself): never muffled by the window.
    bool indoor = false;
    /// This block's level (0…1), for sources whose events thin out as they fade.
    float level = 0.f;
    /// The level it is gliding to (0…1): a drop to nothing stops the cicadas dead instead of fading them.
    float levelTarget = 0.f;
    /// Events started so far (tests): the street counts its passing cars.
    int events = 0;
};

class Thunder;
namespace amb { class Surf; class Kettle; class Boat; class TempleBell; class WaterKnocker; class Warbler; class Sonar; class Whale; class Bubbles;
                class ThunderRoll; }

class Ambience {
public:
    Ambience(double sampleRate, uint64_t seed);
    ~Ambience();
    void setLevel(int source, float level);
    void setCloseness(float c) { closeness.setTarget(clamp01(c)); }
    void setActivity(float a) { activity = clamp01(a); }
    void setNightCool(float c) { ctx.cool = clamp01(c); }
    void setDensity(float d) { ctx.density = d < 0.5f ? 0.5f : (d > 1.5f ? 1.5f : d); }
    void triggerThunder(float distance);
    /// Thunder that arrives late (Storms spec §3): a roll starting `delaySeconds` (0…12) from now, at `strength` 0…1, as
    /// from a strike delaySeconds / 3 km off. Heard only while the thunder roll is up; 16 wait at most (a 17th drops the
    /// oldest), and the queue is cleared as the roll's level goes to nothing.
    void queueThunder(float delaySeconds, float strength);
    /// A world switch: every roll still waiting is dropped (those already rolling fade with the world).
    void clearThunder();
    /// Panic: the queue is dropped and every roll and clap fades out within 40 ms; the beds carry on.
    void allSoundOff();
    /// A source's next event now (tests), waking it first if it is silent.
    void triggerNow(int source);
    void setSpeed(float s) { speedTarget = clamp01(s); }
    void setSurfDistance(float d) { ctx.surfDistance = clamp01(d); }
    /// A wave breaks now (0…1); heard only while the surf is up.
    void triggerWave(float strength);
    void setIndoors(float v) { indoorsTarget = clamp01(v); }
    void setWetness(float v) { wetTarget = clamp01(v); }
    void setSnowOnGlass(float v) { snowTarget = clamp01(v); }
    void startKettle();
    /// A boat passes now (tests).
    void startBoat();
    /// The key the player is in (root 0…11, C = 0; anything else keeps the last): in-key sources take it at their
    /// next event (the bell at its next strike, never mid-ring).
    void setKey(int root, bool major) { if (root >= 0 && root < 12) { ctx.keyRoot = root; ctx.keyMajor = major; } }
    /// The temple bell strikes now (tests).
    void strikeBell();
    /// The fundamental of the temple bell's newest ringing strike, or 0 while it is silent.
    float bellRingingHz() const;
    /// The water-knocker starts filling now (tests).
    void startKnocker();
    /// The bush warbler calls now (tests).
    void callWarbler();
    /// A burst of bubbles (0…1); heard only while the bubbles are up.
    void triggerBubbles(float strength);
    /// The sonar pings now (tests).
    void pingSonar();
    /// The pitch of the sonar's newest ringing ping (its tail and return included), or 0 while it is silent.
    float sonarRingingHz() const;
    /// The whale starts singing now (tests).
    void startWhale();
    /// Events a source has started (tests; read when not rendering).
    int events(int source) const { return source >= 0 && source < ISD_AMB_COUNT && sources[source] ? sources[source]->events : 0; }
    void render(float *left, float *right, int frames);

    static constexpr int kBlock = 64;

private:
    struct Ramp {
        float value = 0, from = 0, to = 0;
        int pos = 0, len = 1;
        void setTarget(float t, int samples) { if (t == to) return; from = value; to = t; pos = 0; len = samples; }
        float advance(int n) {
            if (pos >= len) { value = to; return value; }
            pos = pos + n > len ? len : pos + n;
            float x = (float)pos / (float)len;
            value = from + (to - from) * x * x * (3.f - 2.f * x);
            return value;
        }
        bool silent() const { return value == 0.f && to == 0.f; }
    };

    void processBlock(float *left, float *right, int n);

    double sr;
    AmbienceContext ctx;
    std::unique_ptr<AmbienceSource> sources[ISD_AMB_COUNT];
    std::unique_ptr<Thunder> thunder;
    amb::Surf *surf = nullptr;
    amb::Kettle *kettle = nullptr;
    amb::Boat *boat = nullptr;
    amb::TempleBell *bell = nullptr;
    amb::WaterKnocker *knocker = nullptr;
    amb::Warbler *warbler = nullptr;
    amb::Sonar *sonar = nullptr;
    amb::Whale *whale = nullptr;
    amb::Bubbles *bubbles = nullptr;
    amb::ThunderRoll *thunderRoll = nullptr;
    float speedTarget = 0, indoorsTarget = 0, indoors = 0, indoorsApplied = -1, wetTarget = 0, snowTarget = 0;
    float windowA1 = 1, windowA2 = 0, windowA3 = 0, windowGain = 1;
    Ramp ramps[ISD_AMB_COUNT];
    float closenessApplied = -1, duckDb = 0, activity = 0;
    Smoothed closeness;
    struct OneSVF { float ic1 = 0, ic2 = 0; } air[2];
    OneSVF window[4];   // the window's low-pass on the outdoor direct and room sends
    float airA1 = 1, airA2 = 0, airA3 = 0, width = 1, directGain = 0.8f, roomGain = 0.5f;
    SpaceReverb room;
    bool roomLive = false;
};

} // namespace isd
