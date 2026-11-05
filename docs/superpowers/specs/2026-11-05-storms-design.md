# Sets 17 & 18: Supercell Sky and Lightning Plains ("Storms"), Design Spec

**Date:** 2026-11-05 (23:40)
**Status:** Written to Michael's order of 5 Nov 23:27: finish and release what is built (Sets 7–12), then **Storms**, then Fire & Neon (the bass), then Small Wins. No questions were asked; every choice the docs did not settle is in §17 with what it costs if Michael decides otherwise.
**Numbering:** Fire & Neon is Sets 13 & 14 and Home Lights is Sets 15 & 16, so Storms is **Sets 17 & 18** even though it is built before Fire & Neon's engines. Engine ids 16 and 17 are reserved here; 14 and 15 stay with Home Lights.

**Builds on:**
- `2026-11-05-fire-and-neon-design.md` §5 (Excitement: Energy, Big moments, Surprises, Build and drop; already on `sets-13-14`), §6.1 (red sprites and far storms), §7.2 (the Supercell weather event, staged over 8 minutes).
- `2026-11-04-sets-11-12-design.md`: the analogue voice core `AnalogVoice.hpp`, `SkyU` rows, `instrumentPulse`, meteors in `skyRadiance`, the warm rule.
- `2026-11-04-sets-9-10-design.md`: pitch bend and aftertouch, ambience in key, optional credits and place cards.
- `2026-10-28-sets-1-2-design.md`: `FlashLimiter`, the lightning rules (≤ 3 flashes a second, no red flash over 20% of the screen).
- Felt Glass (`2026-10-28-sets-1-2-design.md` §4) for the piano core Single Note Grand stands on.

**Backlog:** worlds #6 Supercell Sky and #4 Lightning Plains. SkyKit: **anvil crawlers** (Set 17) and **sheet and heat lightning** (Set 18). WeatherKit: **Gust front** (Set 17) and **Virga** (Set 18). Instruments: **Endless Rise** (Set 17) and **Single Note Grand** (Set 18). Ambience: the storm family (six sources) and the plains family (six).

---

## 1. Purpose

Michael asked for the most immersive, effects-heavy world in the catalogue, as a full set. Supercell Sky scored 15/15 in `2026-11-05-remaining-worlds-ranked.md` because it is the one world where the sky, the weather, the light, the camera, the physics, the fauna, the sound and the big-moment arc all come from one cause: the player's hands. Lightning Plains is its lonelier sister: one repeated note on an empty plain, and a storm that arrives as the note turns into a voice.

### Success looks like
- On Supercell Sky, playing harder and faster visibly spins the wall cloud up, pulls the inflow tighter and darkens the base, within one frame of each note. A hard low chord after a build is the drop: the gust front hits, the grass flattens, hail comes in a lit shaft, the camera shakes with a close strike, and the thunder arrives late by the distance.
- Endless Rise climbs for as long as you hold it and never arrives, until the build/drop detector hands the drop to the storm; then it resolves, once, and the sky clears behind it.
- On Lightning Plains, a repeated single note lands a strike on the horizon each time, far at first; the strikes walk closer as tension rises; and under pressure the piano's note becomes a distorted voice as the storm reaches you.
- Both run on Smooth on the Intel MacBook Pro. Every flash goes through `FlashLimiter`. Gentle visuals turn strikes into glows and keep the motion.
- Old saves load: settings without the new weathers, worlds without the new parameters, and a 16-set store that now shows 18.

### Standing rules (unchanged)
Original synthesis only, no samples; credits are text and a Spotify link only; cards breathe at the felt pulse; Smooth tier ≤ 1 MP, no per-pixel ray marching, ≤ 3 noise octaves, no per-frame buffers; every flash through `FlashLimiter`; no `pow` of a possibly negative base; threat-flavoured awe (the funnel, the close strike) once per evening and never touching anything built.

---

## 2. The two sets

| | Set 17: Supercell Sky | Set 18: Lightning Plains |
|---|---|---|
| World | a flat plain at the end of a hot afternoon; a rotating supercell advancing on you | a dry grass plain at dusk, a far ridge, a windmill; a storm line on the horizon that walks closer |
| Visual | **Wall Cloud** (`WallCloud`) | **Strike Lines** (`StrikeLines`) |
| Instrument | **Endless Rise** (`endlessRise`, engine 16) | **Single Note Grand** (`singleNoteGrand`, engine 17) |
| Sky feature | **anvil crawlers** | **sheet and heat lightning** |
| Weather | **Gust front** (`.gustFront`) | **Virga** (`.virga`) |
| Ambience | the storm family: grass wind, hail on tin, birds fleeing, far thunder roll, inflow roar, rain on dust | the plains family: dry cicadas, a windmill, a far cattle grid, dust ticks, heat shimmer hum, a far truck |
| Mood | tense, thrilling: E .7 W .35 B .5 S .8 M .9 (`Mood.stormTense`) | dramatic, vast, lonely: E .45 W .3 B .4 S 1.0 M .4 (`Mood.plainsVast`) |
| Credit | "FADE" (Kanye West, *The Life of Pablo*, 2016): a relentless pulse under a rise that never resolves | "Runaway" (Kanye West, *My Beautiful Dark Twisted Fantasy*, 2010): one repeated piano note, and a voice that arrives distorted |
| Felt pulse | the credit's tempo is disputed; the card breathes at 124 until Michael taps it | 85–87; the card breathes at 86 |

---

## 3. How it fits together
- **Excitement is the spine.** Both worlds adopt `ExcitementAware`. Energy drives the storm's rotation and the strike distance; a big moment is the strike; tension is the gathering; the drop is the gust front (17) or the storm's arrival (18). Nothing in this run fires on a timer except the weather event's own stages.
- **The instrument and the world share one clock.** Endless Rise publishes `instrumentPulse` (its Pulse tempo) and a new `instrumentTension: Float` on `SceneDirector`, so the wall cloud's rotation and the riser's climb are one number. Single Note Grand publishes `instrumentPressure` (the aftertouch morph), so the strike distance and the voice's distortion are one number.
- **Picture first, sound late (Draft H rule 13).** A strike's flash lands in the frame the moment fires; its thunder is delayed by distance (3 s per km, capped at 12 s) through a new `thunderQueue` in the ambience scene. Close strikes shake the camera (≤ 6 px, 0.4 s); far ones only glow.
- **Sky and weather reach every world.** Anvil crawlers appear in any world during `.supercell`, `.thunderheads` or `.storm`; sheet lightning in any world with far storms (Fire & Neon §6.1). Gust front and Virga can be picked in every sky world; Random Beautiful includes Gust front only where storms appear and Virga only in dry worlds (plains, outback, desert, coast road).

---

## 4. The instruments

### 4.1 Endless Rise (Set 17, engine 16, on the analogue voice core)
**What it is.** One instrument with two bodies: a **Pressure Pad** (the chord you hold: a slow, filtered, swelling pad on `AnalogVoice.hpp`'s saw and pulse oscillators with the ZDF ladder) and a **Shepard–Risset riser** layered over it: eight octave-spaced partial groups whose amplitudes follow a raised-cosine window across the spectrum while their pitches climb, so the climb never ends and never arrives. The riser's rate is tied to tension; the drop resolves it.

**The riser (new, `ShepardRise.hpp`, header-only):**
- 8 voices per held note, each a band-limited saw, spaced an octave apart, pitched `f0 · 2^(k + φ)` for k = −4…3 and a phase φ ∈ [0, 1) that advances at `rate` octaves per second (default 0.08, range 0.02–0.5). When φ wraps, the voices re-index and nothing audibly jumps because the window has already silenced the top voice.
- Amplitude window: `w(x) = 0.5 − 0.5·cos(2π·x)` over the normalised log-frequency position x of each voice between 40 Hz and 12 kHz. Loudness normalised so the sum is constant within ±0.5 dB as φ advances.
- A **Tension** input (0…1) multiplies `rate` by 1 + 3·tension and opens the pad's filter cutoff from 600 Hz to 6 kHz. With Excitement on, Tension comes from `ExcitementFrame.tension`; without it, from aftertouch.
- The **drop**: when `ExcitementFrame.drop` jumps to 1, the riser's φ freezes, its window collapses to the fundamental octave over 120 ms (a resolution), the pad's filter snaps open and a one-shot sub thump (a 48 Hz decaying sine, 400 ms) fires. Over the next 2.5 s the riser fades out and the pad is alone. Without Excitement, the drop fires on a hard chord (three note-ons within 40 ms at mean velocity ≥ 0.78) after Tension has been above 0.6.
- **Hold rule:** the riser only runs while a note is held or the pedal is down. Release: the pad's release (0.6–3 s by the Tail dial), the riser gone in 200 ms.

**Dials (Swift order):** Rise (rate), Pressure (filter base), Grit (a soft drive before the ladder, 0–12 dB), Pulse (a tempo-locked tremolo on the pad, 0 = off; 70…170 BPM on a separate Tempo dial, default 124), Tail, Sub (the thump's level), Space, Width.
**Parameters:** `ISD_P_RISE = 150, ISD_P_PRESSURE = 151, ISD_P_GRIT_ER = 152, ISD_P_PULSE = 153, ISD_P_TEMPO_ER = 154, ISD_P_TAIL = 155, ISD_P_SUB = 156` (Space 2, Width 14; mood 100–104). Hooks: `ISD_P_DEBUG_ER_PAD_ONLY = 220, ISD_P_DEBUG_ER_RISE_ONLY = 221, ISD_P_DEBUG_ER_DRY = 222`. Control: `isd_synth_set_tension(ISDSynth*, float)` and `isd_synth_trigger_drop(ISDSynth*)`.
**Presets:** *Supercell* (Rise .08, Pressure .4, Grit .3, Pulse .5 at 124, Tail .6, Sub .7), *Slow Front* (Rise .03, Pulse 0, Tail 1.0), *Siren* (Rise .3, Grit .6, Pulse .8 at 128), *Pad Only* (Rise 0).
**Targets:** 8-voice polyphony, each with 8 riser partial groups = 64 saws; CPU < 7% on the Intel Mac at 8 held notes with Grit .6 and Space .5. No allocation on the audio thread. NaN-free at every extreme.
**Pitch bend ±2 semitones; aftertouch = Tension when Excitement is off, else adds 0.3 to it.**

### 4.2 Single Note Grand (Set 18, engine 17, on the Felt Glass piano core)
**What it is.** A cavernous concert grand (Felt Glass's string core with the felt at 0.2 and a longer, darker board; a 2.8 s hall) that **morphs under pressure into a distorted voice-like lead**: aftertouch cross-fades the string's output into a two-formant resonator (the `AnalogVoice` formant helper from Sets 11 & 12) fed by the same string excitation, through a soft clipper, so the piano note becomes a vowel that sings and breaks. At pressure 0 it is a piano; at 1 it is a voice.

**The morph:**
- `morph = smooth(aftertouch, 80 ms up, 250 ms down)`, plus `instrumentPressure` published to `SceneDirector`.
- Output = `(1 − morph) · piano + morph · voice`, where `voice = softclip(formants(stringExcitation · gain(morph)))`, gain 1 → 8 (18 dB), the clipper `tanh`, formants F1 400 → 700 Hz and F2 1200 → 1800 Hz as morph rises (an "ah" opening to "aw"), bandwidths 80 and 120 Hz.
- An **Octave Down** dial adds the voice an octave below at 0…1 (the "Runaway" ending is a voice an octave down).
- **Repeat detection:** the same key struck four or more times at ≥ 2 per second sets `repeating = true` on `SceneDirector.instrumentRepeat`, which Strike Lines uses (§9.2). Pure control-rate bookkeeping.

**Dials:** Hall (the room), Felt (0.2 default), Morph (a manual floor under aftertouch), Octave Down, Break (clipper drive), Width, Space.
**Parameters:** `ISD_P_HALL_SNG = 160, ISD_P_FELT_SNG = 161, ISD_P_MORPH = 162, ISD_P_OCTAVE_DOWN = 163, ISD_P_BREAK = 164` (Space 2, Width 14; mood 100–104). Hooks: `ISD_P_DEBUG_SNG_PIANO_ONLY = 223, ISD_P_DEBUG_SNG_VOICE_ONLY = 224, ISD_P_DEBUG_SNG_DRY = 225`.
**Presets:** *Runaway* (Hall .7, Felt .2, Morph 0, Octave Down .5, Break .5), *Marble Hall* (Hall 1, Morph 0), *Broken Voice* (Morph .6, Break .9), *Dry Grand* (Hall .1).
**Targets:** 16 voices; CPU < 6% at a 10-note chord with Hall 1 and Morph .5; tuning within 2 cents at Morph 0; the voice stays within 5 cents of the string at Morph 1 (the formant filters do not shift pitch).

### 4.3 CPU budget (measured in CI)
`CPUBudgetTests.testEndlessRiseBudget` < 7%; `testSingleNoteGrandBudget` < 6%; both engines together with the storm ambience < 16%.

---

## 5. Excitement in the two new worlds

| | Energy drives | Signature moment | Surprises | Build → drop |
|---|---|---|---|---|
| Supercell Sky | wall-cloud rotation (0.3 → 2 rpm), inflow tightness, base darkness, hail-shaft density, bird traffic | a **cloud-to-ground strike** at the storm's distance, with thunder late by that distance | a **funnel** (lowers and lifts, far, 8–14 s, once an evening), a **hail burst** out of a clear patch, **red sprites** over the next cell (real: Fire & Neon §6.1), a **rainbow** standing against the retreating core | the light pulls green and the inflow rises; the drop is the **gust front**: grass flattens in a wave from the storm, dust lifts, the hail shaft comes in, the camera shakes once |
| Lightning Plains | strike frequency, strike distance (far → close), grass sway | a **forked strike** at the current distance (single notes land horizon strikes when `instrumentRepeat`; a chord forks it) | **ball lightning** rolling along the ridge (10 s), a **dust devil** crossing, a **windmill** that spins up and stops, the **storm's smell** (no visual: the ambience's rain-on-dust rises 20 s before the rain) | the strikes walk closer and the wind rises; the drop is the **storm's arrival**: the rain curtain crosses you, the sky goes to sheet-lit, and the piano's voice (§4.2) is forced to Morph .8 for the drop's 2.5 s |

Both honour gentle visuals (strikes become glows), Reduce Motion (no camera shake, rotation capped) and Hold the Moment.

---

## 6. Sky (SkyKit): one new feature per set

### 6.1 Set 17: anvil crawlers
**The phenomenon:** spider lightning that creeps across the underside of a storm's anvil over 0.5–2 s, branching horizontally for tens of kilometres, dim and silent or with a late, long rumble.
**In the app (Core, `AnvilCrawlers`):**
- **When:** the sky has `.supercell` (any stage), `.thunderheads`, `.storm` or `.gustFront`, or a far storm; and cloud ≥ 0.7.
- **Rate:** one every 15–45 s in a supercell's Core stage, one every 60–120 s otherwise. A big moment can call one; it costs a flash-limiter unit only if its brightness exceeds 0.25.
- **Shape:** a seeded random walk of 6–14 segments across the cloud base, each segment 2–6° long, drawn over 0.5–2 s as a growing polyline with a 0.3 s glow fade; brightness 0.15–0.4 of the sky's luminance, never white (a cool blue-white, `(0.75, 0.82, 1.0)`).
- **How it's drawn:** analytic segments in the cloud layer (not `skyRadiance`), 4 crawler slots × 16 segments packed into 16 `SkyU` rows (a segment is one `SIMD4`: x0, y0, x1, y1 in sky space; brightness and progress in 2 more rows). No texture.
- **Settings:** All settings → Sky extras: **Anvil crawlers** Off / Natural (default) / Often.

### 6.2 Set 18: sheet and heat lightning
**The phenomenon:** a cloud lit from inside by a flash too far to hear, or a flash below the horizon lighting the sky's rim: silent, soft-edged, 100–300 ms.
**In the app (Core, `SheetLightning`):**
- **When:** night or dusk (sun below −3°), and either far storms (Fire & Neon §6.1) or `.thunderheads`, `.dryLightning`, `.virga` in this world.
- **Rate:** every 8–30 s with far storms; a big moment can call one; it never costs a flash-limiter unit (brightness ≤ 0.2) but is counted.
- **How it's drawn:** a horizon glow in `skyRadiance` at a seeded azimuth, 10–25° wide, 0–6° tall, a raised-cosine in azimuth and an exponential in altitude, colour warm-white; with cloud present, the nearest cloud cell is lit from inside (its brightness × (1 + 1.5·flash)). 2 slots × 4 rows.
- **Settings:** Sky extras: **Sheet lightning** Off / Natural (default) / Often.

---

## 7. Weather (WeatherKit): one new weather per set

### 7.1 Set 17: Gust front
**What it is:** the outflow of a storm arriving before the rain: a shelf cloud, a wall of dust along the ground, a sudden cold wind, then the first big drops.
**Values:** `WeatherValues(cloud: 0.9, rain: 0.2, snow: 0, mist: 0.5, wind: 1, gust: 1)`, plus a new `outflow: Float` (0…1, default 0). It is staged over 3 minutes by default (Advanced 1–10): **Approach** (the shelf cloud on the horizon, inflow gusts towards it), **Hit** (the dust wall crosses the view in 10–20 s; wind to 1; temperature drop drives a cool grade of −8% warmth), **Rain** (the first drops, then rain 0.6).
**How it's drawn:** the shelf cloud is the existing cloud layer's lowest band with a linear ramp; the dust wall is the dust-storm particle path masked to a moving band 8–15° tall; grass and cloth in a world bend to `wind` through PhysicsKit's wind field (new, §10).
**Sound:** the gust roar rising 12 dB over the Hit, rain on dust, a door banging far off in worlds with buildings. `WeatherAmbience` handles it.
**Where:** every sky world; Random Beautiful only where storms appear.

### 7.2 Set 18: Virga
**What it is:** rain that evaporates before it reaches the ground: grey streaks hanging under a cloud base, a dust haze, the smell of rain and none falling, dry lightning inside it.
**Values:** `WeatherValues(cloud: 0.7, rain: 0, snow: 0, mist: 0.6, wind: 0.4, gust: 0.3)`, plus `virga: Float` (0…1, default 0).
**How it's drawn:** streaks as a tilted 1-octave noise band under the cloud base, fading to nothing 30% of the way to the horizon; the haze as a warm low aerosol (the smoke-haze extinction at 0.5); dry lightning (existing) may play inside it.
**Sound:** the rain-on-dust petrichor rise with no rain; a dry wind; distant thunder with no close strikes.
**Where:** every sky world; Random Beautiful in dry worlds only (plains, coast road, outback, desert).

---

## 8. Set 17: Supercell Sky

### 8.1 World
You stand in a wheat-stubble field. The horizon is flat; a line of trees and a far grain silo sit low to the left. Above, the supercell: the Fire & Neon §7.2 event as the world's permanent weather, with the world adding what the event cannot: **the storm's distance** (the hero dial, 0 = 30 km away, 1 = overhead), the **field** (grass that bends to the wind field), the **camera** (a slow dolly back as the storm comes on; a shake on close strikes), the **birds** (a flock that lifts and streams away from the gust front), and the **after** (crepuscular rays under the anvil edge, a double rainbow, the stars behind the retreating core).
- **Light:** late afternoon by default (Living Sky `hold` at 17:30 local in Freeze; real time otherwise), the sun behind you lighting the storm's face; the green cast under the core at most 12% (Fire & Neon §7.2); the base darkens with Energy.
- **The keys** are a line of fence posts along the bottom edge, each lit white by its note.
- **Weather picks:** the supercell is permanent in this world; the picker offers its stage (Approach / Core / Clearing / Cycle) instead of a weather, plus Gust front (which plays as the drop), and the usual clear and overcast for a quiet evening in the field.

### 8.2 Visual: Wall Cloud (Core, `WallCloud`)
- **Rotation:** `rpm = 0.3 + 1.7·energy`, applied to the cloud layer's noise domain about the wall cloud's axis (Fire & Neon §7.2 draws it; this sets the rate).
- **Inflow:** a tail cloud and inflow bands tighten with energy (band spacing 12° → 5°).
- **Hail shaft:** density follows energy; it lights white when the sun is behind you.
- **Strikes:** a big moment places a cloud-to-ground strike at the storm's distance; through the limiter. Each strike queues its thunder at `distance_km × 3 s` (cap 12 s) in `AmbienceScene.thunderQueue`.
- **Gust front (the drop):** a wave in the wind field crossing from the storm to the camera at 15 m/s; grass flattens behind it; dust lifts; the camera shakes once (≤ 6 px, 0.4 s; none under Reduce Motion).
- **Birds:** a boids flock of 40 (20 on Smooth) that lifts on the first big moment and streams away ahead of the front.
- **After:** when the stage is Clearing, crepuscular rays (existing) under the anvil edge, a double rainbow at the sun's anti-point when rain > 0.2 and the sun is up, the stars behind.
- Notes: each note sends a brief glow up the nearest inflow band; chords send a bright pulse into the wall cloud's base; a run is a ripple around its circumference.
- **Smooth:** flock 20, no shake, the mammatus pattern at 1 octave.

### 8.3 Ambience (six sources, the storm family)
`ISD_AMB_GRASS_WIND` (a broad band rustle keyed to wind), `ISD_AMB_HAIL_TIN` (hail on a far shed's roof: dense tuned clicks at 1.5–4 kHz, rate by hail), `ISD_AMB_BIRDS_FLEE` (a scatter of calls that sweep away in azimuth), `ISD_AMB_THUNDER_ROLL` (a long low roll, 2–8 s, with the queue's delay), `ISD_AMB_INFLOW_ROAR` (a low wind body rising with energy), `ISD_AMB_RAIN_ON_DUST` (petrichor: a soft hiss that rises before rain). The thunder roll is in no key; the inflow roar's resonance is tuned a fifth below the current key's tonic so it never clashes.

---

## 9. Set 18: Lightning Plains

### 9.1 World
A dry grass plain at dusk under a vast sky. A far ridge to the right; a windmill (a steel water pump) and a water tank to the left; a fence line runs away from you. The storm is a line of towers on the horizon, lit from inside by sheet lightning, dry at first. **Distance** is the hero dial here too (0 = the storm 40 km out, 1 = overhead), but in this world Energy and tension move it on their own: the storm walks closer as you play, and retreats when you rest.
- **Light:** civil dusk by default; the sky's rim lit by heat lightning; by night the Milky Way over the plain (real stars, southern by default for Melbourne).
- **The keys** are the fence posts; the repeated note lights the same post again and again, brighter each time.

### 9.2 Visual: Strike Lines (Core, `StrikeLines`)
- **The repeated note:** while `instrumentRepeat` is true, each note-on of that key lands a strike on the horizon at the current distance (a vertical fork, 4–7 branches, 120 ms, through the limiter), and the distance steps closer by 2% per strike (a 9-minute walk at 86 BPM).
- **A chord** forks a strike at the current distance; a **big moment** forks three; a **run** is a crawler across the towers (the Set 17 feature, reused).
- **Tension's look:** the wind rises in the grass; the windmill spins up; the towers' internal flashes quicken.
- **The drop:** the storm arrives: a rain curtain crosses the view, a close strike (shake ≤ 6 px), the sky sheet-lit for 2.5 s, and the piano's Morph is forced to .8 for the drop's length (through `SceneDirector.forcedMorph`, which the engine reads at control rate).
- **Dry lightning in Virga:** when `.virga` is picked, strikes come with no rain and the petrichor rises.
- **Smooth:** 2 crawler slots, no shake.

### 9.3 Ambience (six sources, the plains family)
`ISD_AMB_DRY_CICADAS` (a dusk band that stops dead 2 s before a close strike), `ISD_AMB_WINDMILL` (a slow creak-and-clank at the wind's rate, in no key), `ISD_AMB_CATTLE_GRID` (a far truck crossing a grid, rare), `ISD_AMB_DUST_TICKS`, `ISD_AMB_SHIMMER_HUM` (heat shimmer as a faint high hum that fades with dusk), `ISD_AMB_FAR_TRUCK`. The thunder roll and rain on dust are shared with Set 17.

---

## 10. PhysicsKit: the wind field (new, shared)
A `WindField` in Core: a 2-D vector field over the world's ground plane, the sum of the weather's `wind` as a steady flow, gusts as travelling raised-cosine waves (the gust front is one at 15 m/s), and a dust devil as a vortex. Grass, cloth and particles read it. Cost: control-rate; grass in the renderer samples it per blade row, not per pixel. Reused by the Cool Change, Blizzard and Dust storm in later work.

## 11. Mood
`Mood.stormTense` (E .7 W .35 B .5 S .8 M .9) and `Mood.plainsVast` (E .45 W .3 B .4 S 1.0 M .4), appended to `Mood.all` so saved moods still decode.

## 12. Sets, credits and cards
- `SetLibrary.supercellSky`: visual "Wall Cloud", patch `endless-rise`, credit `fade`. `SetLibrary.lightningPlains`: visual "Strike Lines", patch `single-note-grand`, credit `runaway`. `all` holds 18 (with Home Lights and Fire & Neon specced in order; if Storms lands first, `all` holds 14 and the ids are assigned in build order, with the gallery sorted by id).
- **Credits** (text and a Spotify link only): "FADE", Kanye West, *The Life of Pablo*, 2016, "a relentless pulse under a rise that never resolves"; "Runaway", Kanye West, *My Beautiful Dark Twisted Fantasy*, 2010, "one piano note, repeated, and a voice that arrives distorted". Cards are abstract art: a rotating ring of cloud with a green core, breathing at 124; a single lit post under a forked line, breathing at 86. No artwork, lyrics or imagery from either record.
- Gallery tints: storm green-grey `(0.35, 0.42, 0.38)` and dusk amber `(0.55, 0.4, 0.25)`.

## 13. Performance
Both worlds ≤ 1 MP on Smooth; the wall cloud reuses the cloud layer's octaves (no new ones); crawlers and sheet lightning are analytic; the wind field is control-rate; the flock is 20 on Smooth. Budget per world ≤ 2.5 ms a frame on the Intel Mac on Smooth, measured by the structured previews.

## 14. Reliability
- `FlashLimiter` governs strikes, crawlers over 0.25 brightness and the sheet-lit drop; ≤ 3 flashes a second; no red flash over 20% of the screen (strikes are blue-white; the sheet is warm-white at ≤ 0.2).
- Thunder's queue is bounded (16 entries) and cleared on world switch.
- Engines: no allocation on the audio thread; drop and tension are atomics read at control rate; `allSoundOff` kills the riser and the thump within 50 ms.
- Old saves: `WeatherKind` decoding tolerates unknown cases (existing); `SceneControls` and world parameters have defaults; the set store with fewer sets decodes.

## 15. Testing (the plan lists them per task)
DSP: tuning, the riser's constant loudness (±0.5 dB over a full wrap), the rate–tension law, the drop's resolution within 120 ms, the thump, NaN-free extremes, CPU; the grand's tuning at Morph 0, the voice's pitch at Morph 1, the formant centres, repeat detection at 4 strikes ≥ 2/s. Core: rotation from energy, strike placement and thunder delay, the gust-front wave speed, the flock's bound, the strike walk's 2% step, forced morph during the drop, the weather stages, crawler geometry bounds, sheet-lightning brightness ≤ 0.2, wind-field superposition. App: shaders compile with no `pow(`, previews at each stage, gentle visuals and Reduce Motion, any aspect, burst budgets, 18-set gallery and old stores.

## 16. Build order
1. Branch, briefs, reserved numbers. 2. Endless Rise (DSP). 3. Endless Rise in the app, the "FADE" card, tension and drop plumbing. 4. Single Note Grand (DSP). 5. The grand in the app, the "Runaway" card, pressure and repeat plumbing. 6. Sky Core: anvil crawlers, sheet lightning; weather Core: Gust front, Virga; the wind field. 7. Sky and weather drawing. 8. The twelve ambience sources and the thunder queue. 9. Supercell Sky model and Wall Cloud. 10. Supercell Sky renderer. 11. Lightning Plains model and Strike Lines. 12. Lightning Plains renderer. 13. Sets, cards, gallery, release notes, demos. 14. Review, fixes, merge, release.

## 17. Decisions made without asking (with the cost if Michael decides otherwise)
1. **Storms is Sets 17 & 18, engines 16 and 17,** so Home Lights and Fire & Neon keep their numbers. Cost: a renumber if he wants Storms to be 13 & 14.
2. **Endless Rise is one instrument** (pad + riser), not two. Cost: splitting is a preset (*Pad Only*) and a second engine entry.
3. **The riser needs Excitement for its drop**; without it, a hard chord after tension drops it. Cost: none.
4. **Supercell Sky's weather is the storm itself**; the picker offers its stage. Cost: a flag to allow any weather.
5. **Distance is a dial in Set 17 and automatic in Set 18.** Cost: a dial in Set 18.
6. **The funnel is a surprise, far, once an evening, never touching anything.** Cost: a switch to turn it off.
7. **The forced Morph during the drop** overrides aftertouch for 2.5 s. Cost: a setting.
8. **Felt pulse for "FADE" is 124** until tapped. Cost: a number.
9. **Credits are the two Kanye tracks** as matched in the song docs. Cost: swapping to place-born cards.
10. **The wind field is Core and control-rate**, not a shader. Cost: none now; a shader version later for Ultra.
