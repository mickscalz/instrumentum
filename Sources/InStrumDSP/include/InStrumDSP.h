// In Strum Meants Sound Core: the only public interface to the real-time DSP.
// Plain C so Swift imports it directly. All render/process calls are real-time safe.
#ifndef IN_STRUM_DSP_H
#define IN_STRUM_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Space reverb (100% wet) ----------
typedef struct ISDReverb ISDReverb;
ISDReverb *isd_reverb_create(double sampleRate, int maxFrames);
void isd_reverb_destroy(ISDReverb *reverb);
/// size, damping and shimmer 0…1; pre-delay 0…80 ms. Real-time safe.
void isd_reverb_configure(ISDReverb *reverb, float size, float damping, float predelayMs, float shimmer);
/// Real-time safe; in-place allowed.
void isd_reverb_process(ISDReverb *reverb, const float *inL, const float *inR, float *outL, float *outR, int frames);

// ---------- Built-in instruments ----------
typedef enum { ISD_ENGINE_FELT_GLASS = 0, ISD_ENGINE_ORBIT_PAD = 1, ISD_ENGINE_HONEY_TAPE = 2, ISD_ENGINE_HAZE_BELLS = 3, ISD_ENGINE_CABIN_FELT = 4, ISD_ENGINE_MORNING_BOX = 5, ISD_ENGINE_POLAR_CHOIR = 6, ISD_ENGINE_PLANKTON_KEYS = 7, ISD_ENGINE_TEA_HOUSE_KOTO = 8, ISD_ENGINE_ZEN_SHAKUHACHI = 9, ISD_ENGINE_BLUE_DEPTH = 10, ISD_ENGINE_REEF_MARIMBA = 11,
               ISD_ENGINE_MAGMA_BASS = 12, ISD_ENGINE_REPLICANT_BRASS = 13,
               /* 14 and 15 are Home Lights' (Sets 15 & 16). */
               /* Storms (Sets 17 & 18): Endless Rise (spec 2026-11-05-storms-design.md §4.1) and Single Note Grand
                  (§4.2, reserved: not creatable until its task lands, so isd_synth_create returns NULL for it). */
               ISD_ENGINE_ENDLESS_RISE = 16, ISD_ENGINE_SINGLE_NOTE_GRAND = 17 } ISDEngine;

/// Parameter addresses (stable: saved in presets and instrument state).
enum {
    ISD_P_FINE_TUNE = 0, ISD_P_TRANSPOSE = 1, ISD_P_SPACE = 2,
    ISD_P_FELT = 10, ISD_P_GLASS = 11, ISD_P_WARMTH = 12, ISD_P_RING = 13, ISD_P_WIDTH = 14,
    ISD_P_BLOOM = 20, ISD_P_DRIFT = 21, ISD_P_MOTION = 22, ISD_P_SHIMMER = 23, ISD_P_BRIGHTNESS = 24,
    ISD_P_BREATH = 30, ISD_P_STRINGS = 31, ISD_P_WOW = 32, ISD_P_AGE = 33, ISD_P_REEL = 34,
    ISD_P_BELLS = 40, ISD_P_ORGAN = 41, ISD_P_ECHO = 42, ISD_P_CRUSH = 43,
    ISD_P_HORN = 50, ISD_P_FIRE = 51, ISD_P_WOOD = 52,
    ISD_P_BARS = 60, ISD_P_BOX = 61, ISD_P_BUILD = 62, ISD_P_HAZE = 63,
    ISD_P_VOWEL = 70, ISD_P_SWELL = 71,
    ISD_P_TINE = 80, ISD_P_BARK = 81, ISD_P_SPARKLE = 82, ISD_P_TREMOLO = 83, ISD_P_PHASE = 84,
    ISD_P_PICK = 90, ISD_P_SILK = 91, ISD_P_BODY = 92, ISD_P_YURI = 93,
    ISD_P_AIR = 94, ISD_P_BEND = 95, ISD_P_BAMBOO = 96,
    ISD_P_BLINK = 110, ISD_P_MURK = 111, ISD_P_GHOSTS = 112, ISD_P_BASS = 113, ISD_P_TEMPO = 114,
    ISD_P_MALLET = 120, ISD_P_STRIKE = 121, ISD_P_TUBE = 122, ISD_P_ROLL = 123, ISD_P_STEEL = 124,
    /// Magma Bass (Sets 13 & 14, reserved; spec 2026-11-05-fire-and-neon-design.md §4.2).
    ISD_P_GROWL = 130, ISD_P_HEAT = 131, ISD_P_ERUPT = 132, ISD_P_RUMBLE = 133, ISD_P_GRIT = 134, ISD_P_FLOW = 135,
    ISD_P_SHAPE = 136, ISD_P_MONO = 137, ISD_P_SPARK = 138, ISD_P_RES = 139,
    /// Replicant Brass with Chrome Bass (Sets 13 & 14, reserved; spec §4.3). Tempo 70…170, default 120.
    ISD_P_SWELL_RB = 140, ISD_P_BLAZE = 141, ISD_P_UNISON_WIDTH = 142, ISD_P_HALL = 143, ISD_P_CHROME = 144,
    ISD_P_PUNCH = 145, ISD_P_ARP_MODE = 146, ISD_P_ARP_RATE = 147, ISD_P_SPLIT = 148, ISD_P_TEMPO_RB = 149,
    /// Endless Rise (Storms, Sets 17 & 18; spec 2026-11-05-storms-design.md §4.1). Rise is the riser's climb in
    /// octaves a second (0 switches the riser off, else 0.02…0.5; default 0.08); Tempo 70…170, default 124. Also
    /// uses ISD_P_SPACE and ISD_P_WIDTH.
    ISD_P_RISE = 150, ISD_P_PRESSURE = 151, ISD_P_GRIT_ER = 152, ISD_P_PULSE = 153, ISD_P_TEMPO_ER = 154,
    ISD_P_TAIL = 155, ISD_P_SUB = 156,
    /// Single Note Grand (Storms, Sets 17 & 18, reserved; spec §4.2). Also uses ISD_P_SPACE and ISD_P_WIDTH.
    ISD_P_HALL_SNG = 160, ISD_P_FELT_SNG = 161, ISD_P_MORPH = 162, ISD_P_OCTAVE_DOWN = 163, ISD_P_BREAK = 164,
    ISD_P_MOOD_ENERGY = 100, ISD_P_MOOD_WARMTH = 101, ISD_P_MOOD_BRIGHTNESS = 102, ISD_P_MOOD_SPACE = 103, ISD_P_MOOD_MOTION = 104,
    /// Test hook (unit 3, never shown): Orbit Pad plays one plain saw, no detune, drift, motion or chorus.
    ISD_P_DEBUG_LAYER_A_ONLY = 200,
    /// Test hook (unit 3, never shown): Honey Tape's flute plays without vibrato.
    ISD_P_DEBUG_NO_VIBRATO = 201,
    /// Test hooks (unit 3, never shown): Cabin Felt without its key and damper noises; Cabin Felt's horn alone.
    ISD_P_DEBUG_NO_MECHANICS = 202, ISD_P_DEBUG_HORN_ONLY = 203,
    /// Test hooks (unit 3, never shown): Morning Box's box alone; its wall alone.
    ISD_P_DEBUG_BOX_ONLY = 204, ISD_P_DEBUG_WALL_ONLY = 205,
    /// Test hook (unit 3, never shown): Polar Choir's voices alone: one saw, no breath, glass, chorus, drift or swell rise.
    ISD_P_DEBUG_VOICES_ONLY = 206,
    /// Test hooks (unit 3, never shown): Plankton Keys without its sparks; without its tremolo.
    ISD_P_DEBUG_NO_SPARKLE = 207, ISD_P_DEBUG_NO_TREMOLO = 208,
    /// Test hooks (unit 3, never shown): Tea House Koto without its sympathetic open strings; without its body.
    ISD_P_DEBUG_NO_SYMPATHY = 209, ISD_P_DEBUG_NO_BODY = 210,
    /// Test hooks (unit 3, never shown): Zen Shakuhachi's tone alone (no breath, muraiki, yuri or echo); no octave fold.
    ISD_P_DEBUG_TONE_ONLY = 211, ISD_P_DEBUG_NO_FOLD = 212,
    /// Test hooks (unit 3, never shown): Blue Depth with its arp off (Blink ignored); Blue Depth dry (no echo, ghosts,
    /// reverb, slop or current).
    ISD_P_DEBUG_NO_ARP = 213, ISD_P_DEBUG_DRY = 214,
    /// Test hooks (unit 3, never shown): Reef Marimba without its rolls; its bars alone (no tube, steel, untuned modes
    /// or reverb).
    ISD_P_DEBUG_NO_ROLL = 215, ISD_P_DEBUG_BAR_ONLY = 216,
    /// Test hooks (unit 3, never shown; reserved for Sets 13 & 14): Magma Bass dry (no fold, drive or spark);
    /// Replicant Brass without the Chrome arp; Replicant Brass dry (no chorus or hall).
    ISD_P_DEBUG_MB_DRY = 217, ISD_P_DEBUG_RB_NO_ARP = 218, ISD_P_DEBUG_RB_DRY = 219,
    /// Test hooks (unit 3, never shown; Storms, Sets 17 & 18): Endless Rise's pad alone (no riser or thump); its riser
    /// alone (with the drop's thump); Endless Rise dry (no pulse, drive, reverb or slop). They combine.
    ISD_P_DEBUG_ER_PAD_ONLY = 220, ISD_P_DEBUG_ER_RISE_ONLY = 221, ISD_P_DEBUG_ER_DRY = 222,
    /// Test hooks (unit 3, never shown; Storms, Sets 17 & 18, reserved): Single Note Grand's piano alone; its voice
    /// alone; the grand dry (no hall).
    ISD_P_DEBUG_SNG_PIANO_ONLY = 223, ISD_P_DEBUG_SNG_VOICE_ONLY = 224, ISD_P_DEBUG_SNG_DRY = 225
};

/// unit: 0 generic 0…1, 1 cents, 2 semitones, 3 internal (test hooks: hosts never show or save these).
typedef struct {
    int address;
    const char *identifier;
    const char *name;
    float minValue, maxValue, defaultValue;
    int unit;
} ISDParamInfo;

typedef struct ISDSynth ISDSynth;
/// Returns NULL for an engine that isn't available.
ISDSynth *isd_synth_create(ISDEngine engine, double sampleRate, int maxFrames);
void isd_synth_destroy(ISDSynth *synth);
int isd_synth_param_count(ISDEngine engine);
const ISDParamInfo *isd_synth_param_info(ISDEngine engine, int index);
/// Any thread. Values are clamped to the parameter's range and smoothed while playing.
void isd_synth_set_param(ISDSynth *synth, int address, float value);
float isd_synth_get_param(const ISDSynth *synth, int address);
/// Render thread, before the render call it belongs to. `sampleOffset` is within that render.
void isd_synth_midi(ISDSynth *synth, const uint8_t *bytes, int length, int sampleOffset);
/// Render thread. Overwrites `left`/`right`.
void isd_synth_render(ISDSynth *synth, float *left, float *right, int frames);
/// Any thread: every note fades out over 20 ms at the next render.
void isd_synth_all_notes_off(ISDSynth *synth);
int isd_synth_active_voices(const ISDSynth *synth);
/// Internal counters for tests. Not real-time safe to rely on; read between renders.
/// RETUNES: Felt Glass retunes. HORN_NOTE: Cabin Felt's horn note (folded into its range), or -1.
/// BUILD_PERMILLE and WALL_UNISON: Morning Box's build level × 1000 and its wall's unison count.
/// DROPS and TENSION_PERMILLE: Endless Rise's drops taken (a second one within 2.5 s is not) and the tension it is
/// using × 1000 (the world's plus 0.3 × pressure, smoothed).
typedef enum { ISD_DEBUG_RETUNES = 0, ISD_DEBUG_HORN_NOTE = 1, ISD_DEBUG_BUILD_PERMILLE = 2, ISD_DEBUG_WALL_UNISON = 3,
               /* Magma Bass: how many eruption swells hard low chords have set off. */ ISD_DEBUG_ERUPTIONS = 4,
               ISD_DEBUG_DROPS = 5, ISD_DEBUG_TENSION_PERMILLE = 6 } ISDDebugCount;
int isd_synth_debug_count(const ISDSynth *synth, ISDDebugCount which);

// ---------- Storms (Sets 17 & 18): the riser's calls (Task 2); the grand's are declared here, defined by Task 4 ----------
/// Endless Rise. Any thread. Tension 0…1 from the Excitement step: it multiplies the riser's rate by 1 + 3·tension,
/// opens the pad's filter (600 Hz → 6 kHz at Pressure .4) and brings the riser forward. The engine adds 0.3 × the
/// player's pressure to it (so with nothing set, a full press is tension 0.3); with Excitement off the host passes the
/// pressure itself here. An atomic, read once per control block and smoothed over 50 ms, so it never steps. Other
/// engines ignore it.
void isd_synth_set_tension(ISDSynth *synth, float tension);
/// Endless Rise. Any thread. The drop: the riser resolves onto the chord within 120 ms and fades out over 2.5 s, the
/// pad's filter snaps open and a 48 Hz thump fires. A second drop is ignored until the first's release envelope has
/// passed 0.2 and its 2.5 s have run. Taken at the next control block. Other engines ignore it.
void isd_synth_trigger_drop(ISDSynth *synth);
/// Single Note Grand. Any thread. Forces the morph (0…1) over aftertouch, for the storm's arrival; a negative value
/// releases it, and the morph returns to the player's aftertouch over 250 ms.
void isd_synth_set_forced_morph(ISDSynth *synth, float morph);
/// Internal (tests) and the repeat detector's read-back (any thread): 1 while the same key has been struck four or more
/// times at 2 a second or faster, else 0.
int isd_synth_debug_is_repeating(const ISDSynth *synth);

// ---------- Ambience (generated live, never loops) ----------
typedef enum {
    ISD_AMB_WATER, ISD_AMB_CRICKETS, ISD_AMB_BREEZE, ISD_AMB_OWL, ISD_AMB_RAIN_WATER, ISD_AMB_RAIN_GLASS,
    ISD_AMB_DAWN_CHORUS, ISD_AMB_SHIP_HUM, ISD_AMB_AIR_FLOW, ISD_AMB_CHIME, ISD_AMB_HULL_TICKS, ISD_AMB_WIND,
    ISD_AMB_SURF, ISD_AMB_PALMS, ISD_AMB_GULLS, ISD_AMB_ROAD, ISD_AMB_ENGINE, ISD_AMB_WINDOW_WIND, ISD_AMB_PASSING_CAR,
    ISD_AMB_FIRE, ISD_AMB_KETTLE, ISD_AMB_STREET, ISD_AMB_DRIPS, ISD_AMB_CLOCK,
    /// The night skies (all outdoor): ICE_GROAN a faint creak bed under deep groans (40–120 Hz sweeps, every 20–90 s)
    /// and sharp cracks with a 1–2 kHz ring (every 15–60 s); WATERFALL a far white roar (200 Hz–3 kHz, a slow 0.1 Hz
    /// flicker, about −26 dBFS at 1) over a 60–120 Hz rumble; LAPPING soft sloshes against a hull (300–2000 Hz,
    /// 0.3–0.8 s, every 2–6 s) with now and then a hollow 180 Hz knock; BOAT a distant outboard crossing from one
    /// side to the other every 150–400 s (a 12–20 s swell of a low pulsing buzz), its wake washing in after.
    ISD_AMB_ICE_GROAN, ISD_AMB_WATERFALL, ISD_AMB_LAPPING, ISD_AMB_BOAT,
    /// The still places: TEMPLE_BELL a far bonshō (outdoor) struck every 120–300 s: hum partials at about 1, 1.6, 2.3
    /// and 3.0 × the tonic of the player's key in A1–G♯2 (isd_ambience_set_key), ringing 6–12 s with a slow 0.3 Hz
    /// beat after a 1 ms clapper click, its first 2 s near −30 dBFS RMS at 1; PAPER_SCREENS shoji in a draught
    /// (indoor): 1–4 kHz rustles of 0.2–0.6 s (every 6–20 s at level 0.5, more often the higher the level), now and
    /// then a wooden creak, a rustle near −38 dBFS RMS at 1; WATER_KNOCKER a bamboo shishi-odoshi (outdoor): a thin
    /// 2–4 kHz trickle fills it for 15–40 s, it tips with a slosh and clacks on its stone (a bright 2 ms knock with a
    /// 60 ms ring near 1.8 kHz, peaking near −18 dBFS at 1), then fills again; WARBLER a bush warbler (outdoor): a long
    /// whistle rising from about 2.5 to 3.2 kHz over 0.6 s, then two quick notes, every 40–120 s (the world decides
    /// in which seasons and hours it sings), peaking near −20 dBFS at 1.
    ISD_AMB_TEMPLE_BELL, ISD_AMB_PAPER_SCREENS, ISD_AMB_WATER_KNOCKER, ISD_AMB_WARBLER,
    /// Deep water: SONAR a soft ping (outdoor: it rings in the water and is heard through the hull) every 14–30 s, a
    /// pure sine at the tonic of the player's key in A5–G♯6 (880–1661 Hz; E6, 1318.5 Hz, until a key is set) with a
    /// 25 ms attack and a 0.35 s body peaking near −26 dBFS at 1, ringing on for 3–5 s in its own unmodulated underwater
    /// tail (the ping's own tone, so nothing above it and never off the key) and coming back off the seabed 1.4–2.6 s
    /// later at −20 dB; HULL_CREAK the pressure hull settling (indoor: you are inside it) every 12–45 s, a stick-slip
    /// groan of 0.6–3 s whose pulses glide between 8 and 30 Hz through hull resonances at 60–250 Hz (near −30 dBFS RMS
    /// at 1), and now and then a 1–3 kHz metal tick of 0.2 s; WHALE a far-off humpback (outdoor) singing units (moans
    /// at 100–400 Hz, whoops rising from 200 to 800 Hz, cries at 800–1800 Hz, grunts) in phrases of 3–6, each phrase
    /// sung 2–4 times as a theme and the themes in a seeded order that drifts slowly, 20–60 s of song then 30–180 s of
    /// quiet, low-passed above 2 kHz and mostly reverberant, near −30 dBFS RMS while it sings at 1; BUBBLES (outdoor)
    /// bursts of 4–30 bubbles over 0.3–1.5 s, each a damped sine ringing 5–25 ms at its Minnaert frequency (1.1–8 kHz)
    /// with an 8% upward chirp, by themselves every 8–30 s and on isd_ambience_trigger_bubbles, peaking near −28 dBFS
    /// at 1; SHRIMP a reef's snapping shrimp (outdoor), a crackle of 0.1–0.3 ms clicks high-passed at 2 kHz with
    /// Pareto amplitudes, scattered across the stereo field, 900 a second at 1 and fewer the lower the level (a world
    /// sets the hour's rate through the level), near −24 dBFS RMS at 1; FISH_CHORUS reef fish (outdoor) at 100–800 Hz,
    /// damselfish trains of 3–10 pulses at 20–60 Hz, knocks, pops and croaks, calling more often the higher the level
    /// until they gather into a chorus, near −30 dBFS RMS at 1.
    ISD_AMB_SONAR, ISD_AMB_HULL_CREAK, ISD_AMB_WHALE, ISD_AMB_BUBBLES, ISD_AMB_SHRIMP, ISD_AMB_FISH_CHORUS,
    /// Storms (Sets 17 & 18), all outdoor. The storm family: GRASS_WIND a field of dry grass in the wind (the level is
    /// the wind: brighter and busier as it rises, gust waves sweeping across from one side to the other, seed heads
    /// ticking), 1.5–6 kHz, near −24 dBFS RMS at 1; HAIL_TIN hail on a far shed's tin roof (the level is the hail: 700
    /// impacts a second at 1, rising with the level's 1.5 power, each ringing the roof's own panel modes at 1.5–4 kHz;
    /// mostly dry); BIRDS_FLEE a flock flushed ahead of the storm: wingbeats, then 8–13 harsh calls one at a time, each
    /// farther round to one side, fainter and duller, sweeping away from the storm (ahead) in azimuth: a flight as the
    /// level comes up, then rarer ones (15–45 s apart and growing, as the field empties); THUNDER_ROLL thunder that
    /// arrives late (isd_ambience_queue_thunder): a roll of 2–8 s, nearly all of it below 150 Hz, a crack first when
    /// close, in no key; it makes no sound of its own; INFLOW_ROAR a low wind body that opens with the level (the storm's
    /// energy) around a resonant throat a fifth below the key's tonic (in A2–G♯3: 73–139 Hz; all dry, so never off the
    /// key); RAIN_ON_DUST petrichor: a soft hiss from the first of the level, the first fat drops pattering only past 0.6
    /// (virga's 0.5 stays dry). The plains family: DRY_CICADAS a dusk chorus (4.2–6.8 kHz) that stops dead, together,
    /// within 50 ms when its level drops to nothing (a world hushes them 2 s before a close strike) and comes back singer
    /// by singer; WINDMILL a steel water pump (the level is the wind: still
    /// below 0.08, then 0.75 × (level − 0.08) / 0.92 strokes a second), clanking at the top of each stroke, knocking at
    /// the bottom and creaking, in no key; CATTLE_GRID a vehicle on the far road drumming over a grid's bars, every
    /// 90–240 s; DUST_TICKS grit on the wind against wire and tin, 3–9 kHz, more in the gusts; SHIMMER_HUM a faint high
    /// hum on the key's tonic in A5–G♯6 with its fifth and octave, beating slowly (the world fades it with the heat);
    /// FAR_TRUCK a road train on a far highway every 50–140 s, swelling and fading over 30–60 s. Ids are never saved
    /// (Swift keeps names), so a merge with Fire & Neon's twelve may renumber them.
    ISD_AMB_GRASS_WIND, ISD_AMB_HAIL_TIN, ISD_AMB_BIRDS_FLEE, ISD_AMB_THUNDER_ROLL, ISD_AMB_INFLOW_ROAR, ISD_AMB_RAIN_ON_DUST,
    ISD_AMB_DRY_CICADAS, ISD_AMB_WINDMILL, ISD_AMB_CATTLE_GRID, ISD_AMB_DUST_TICKS, ISD_AMB_SHIMMER_HUM, ISD_AMB_FAR_TRUCK,
    ISD_AMB_COUNT
} ISDAmbienceSource;

typedef struct ISDAmbience ISDAmbience;
/// Internal (tests): the frequency the ambience's tone oscillators really run at, measured over the last second
/// of a run of `seconds` from phase 0.
float isd_ambience_debug_tone_hz(float hz, float sampleRate, float seconds);
/// Internal (tests): how many events a source has started so far (the waking street counts its passing cars; the
/// ice its groans and cracks together; lapping its sloshes; the boat its passes; the temple bell its strikes; the
/// paper screens their rustles; the water-knocker its clacks; the warbler its calls; the sonar its pings; the hull
/// its groans and ticks together; the whale its units; the bubbles their bursts; the shrimp their snaps; the fish
/// their calls; the grass nothing; the hail its stones; the birds their calls; the thunder roll its rolls; the rain on
/// dust its drops; the cicadas their phrases; the windmill its strokes; the cattle grid and the far truck their
/// passes; the dust its ticks).
int isd_ambience_debug_events(const ISDAmbience *ambience, ISDAmbienceSource source);
/// The same seed gives the same ambience.
ISDAmbience *isd_ambience_create(double sampleRate, int maxFrames, uint64_t seed);
void isd_ambience_destroy(ISDAmbience *ambience);
/// Any thread. 0…1; the source glides to it over 2.5 s. Continuous sources sit near −24 dBFS RMS at 1.
void isd_ambience_set_level(ISDAmbience *ambience, ISDAmbienceSource source, float level);
/// Any thread. 0 distant (roomy, softer top) … 1 all around you (close, dry, wide).
void isd_ambience_set_closeness(ISDAmbience *ambience, float closeness);
/// Any thread. 0…1 while playing: ducks up to 4 dB within half a second, swells back over about 2 s.
void isd_ambience_set_activity(ISDAmbience *ambience, float activity);
/// Any thread. 0 warm early night … 1 cool late night (crickets chirp up to 40% slower).
void isd_ambience_set_night_cool(ISDAmbience *ambience, float cool);
/// Any thread. 0.5…1.5: multiplies how often things happen (calls, chirps, drops, chimes).
void isd_ambience_set_density(ISDAmbience *ambience, float density);
/// Any thread. Thunder rolls in 0.5 s (near) to 6 s (far) later.
void isd_ambience_trigger_thunder(ISDAmbience *ambience, float distance);
/// Any thread. Thunder that arrives late (Storms): a roll on ISD_AMB_THUNDER_ROLL starting `delaySeconds` (0…12) after
/// the next render begins (the picture first, the sound after: 3 s a kilometre, capped at 12 s), at `strength` 0…1, as
/// from a strike delaySeconds / 3 km off. Ignored while the thunder roll is silent or fading out. The queue holds 16 (a
/// 17th drops the oldest); a world switch (isd_ambience_clear_thunder, or the roll's level going to 0) and
/// isd_ambience_all_sound_off clear it.
void isd_ambience_queue_thunder(ISDAmbience *ambience, float delaySeconds, float strength);
/// Any thread. A world switch: every roll still waiting in the queue (queued before this call) is dropped; rolls
/// already sounding fade out with the world's levels.
void isd_ambience_clear_thunder(ISDAmbience *ambience);
/// Any thread. Panic: the thunder queue is cleared and every roll and clap still sounding (queued or triggered) fades
/// out within 40 ms. The beds carry on: they are the world, not a stuck note.
void isd_ambience_all_sound_off(ISDAmbience *ambience);
/// Internal (tests): a source's next event happens at the next render (the birds take flight, a truck crosses the
/// cattle grid, a far truck passes); ignored by sources without events of their own.
void isd_ambience_debug_trigger(ISDAmbience *ambience, ISDAmbienceSource source);
/// Any thread. A wave breaks on the shore (strength 0…1): a crash, a wash up the sand and a backwash. Silent
/// unless the surf is up.
void isd_ambience_trigger_wave(ISDAmbience *ambience, float strength);
/// Any thread. A car's speed 0…1 for the road, engine and window wind (glides over half a second).
void isd_ambience_set_speed(ISDAmbience *ambience, float speed);
/// Any thread. 0 close, detailed surf … 1 a far, low roar.
void isd_ambience_set_surf_distance(ISDAmbience *ambience, float distance);
/// Any thread. 0 outdoors … 1 inside behind glass: outdoor sources (and thunder) lose their top and 9 dB, gliding
/// over 2.5 s; indoor ones (fire, kettle, clock, the ship's sounds) and rain on the glass itself are untouched.
void isd_ambience_set_indoors(ISDAmbience *ambience, float indoors);
/// Any thread. 0…1: a wet road hisses under the tyres.
void isd_ambience_set_wetness(ISDAmbience *ambience, float wetness);
/// Any thread. 0…1: snow on the glass turns rain on the glass into fewer, softer, lower ticks.
void isd_ambience_set_snow_on_glass(ISDAmbience *ambience, float snow);
/// Internal (tests): the kettle starts a heating cycle now.
void isd_ambience_debug_start_kettle(ISDAmbience *ambience);
/// Internal (tests): a boat passes now.
void isd_ambience_debug_start_boat(ISDAmbience *ambience);
/// Any thread. The key the player is in: root 0…11 (C = 0), major 1 or minor 0. The temple bell sounds its tonic
/// (in A1–G♯2, in either mode) from its next strike on and never retunes a strike that is ringing; the sonar pings
/// it (in A5–G♯6) from its next ping on and never retunes a ping, its tail or its return. A root outside 0…11 (−1:
/// the key can't be sensed) keeps the last key; E major until one is set.
void isd_ambience_set_key(ISDAmbience *ambience, int root, int major);
/// Internal (tests): the temple bell strikes now.
void isd_ambience_debug_strike_bell(ISDAmbience *ambience);
/// Internal (tests): the fundamental (Hz) of the temple bell's ringing strike, or of its next strike while it is
/// silent. Any thread.
float isd_ambience_debug_bell_hz(const ISDAmbience *ambience);
/// Internal (tests): the water-knocker starts filling now, empty.
void isd_ambience_debug_start_knocker(ISDAmbience *ambience);
/// Internal (tests): the bush warbler calls now.
void isd_ambience_debug_call_warbler(ISDAmbience *ambience);
/// Any thread. A burst of bubbles rises now, strength 0…1 (from 4 bubbles over 0.3 s to 30 over 1.5 s), starting
/// within a render of the call. Silent unless the bubbles are up (a burst never carries into the next world).
void isd_ambience_trigger_bubbles(ISDAmbience *ambience, float strength);
/// Internal (tests): the sonar pings now.
void isd_ambience_debug_ping_sonar(ISDAmbience *ambience);
/// Internal (tests): the frequency (Hz) of the sonar's ringing ping (its tail and its return included), or of its
/// next ping while it is silent. Any thread.
float isd_ambience_debug_sonar_hz(const ISDAmbience *ambience);
/// Internal (tests): the whale starts singing now, from where its song left off.
void isd_ambience_debug_start_whale(ISDAmbience *ambience);
/// Render thread. Overwrites `left`/`right`.
void isd_ambience_render(ISDAmbience *ambience, float *left, float *right, int frames);

#ifdef __cplusplus
}
#endif

#endif
