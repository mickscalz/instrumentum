# Sound brief: Endless Rise (Supercell Sky)

The pad-and-riser instrument on the **analogue voice core** (`AnalogVoice.hpp`), with a new header-only **Shepard–Risset riser** (`ShepardRise.hpp`). Engine 16. Spec: `docs/superpowers/specs/2026-11-05-storms-design.md` §2, §4.1 and §12. Plan: Tasks 2 and 3.

## Facts
- **The set's credit:** "FADE", by Kanye West, from *The Life of Pablo* (2016).
  - The card's one-line description is ours: "a relentless pulse under a rise that never resolves". It says what the instrument does; it is not a claim about the recording's arrangement.
  - Spotify search: `FADE Kanye West`. Credits are text and a Spotify link only.
  - **No artwork, lyrics or imagery from the record.** Nothing is sampled, copied or modelled from it. We take the *kind* of sound only: a pulse that never lets go, under a rise that never arrives.
- **The felt pulse:** the credit's tempo is disputed. The card breathes at **124 BPM** until Michael taps it. **Check by ear** before the card relies on it.
- **Key:** none is fixed by the spec. Find it by ear.
- **The sound itself:** a Shepard–Risset tone is a stack of octave-spaced partials whose loudness follows a window across the spectrum while their pitches climb. As the top partial fades out, a new one fades in at the bottom, so the pitch seems to rise for ever and never arrives. Everything here is original synthesis.
- **Why a storm gets it:** Supercell Sky is the one world where the sky, the light, the camera and the sound all come from the player's hands. The riser is the gathering; the drop is the gust front.

## What we're matching
- **Two bodies in one instrument:**
  - A **Pressure Pad**: the chord you hold, a slow, filtered, swelling pad on the saw and pulse oscillators with the ZDF ladder.
  - A **riser** over it: 8 voices per held note, each a band-limited saw one octave apart, pitched `f0 · 2^(k + φ)` for k = −4…3.
  - φ ∈ [0, 1) advances at `rate` octaves a second (default 0.08, range 0.02–0.5). When φ wraps, the voices re-index and nothing jumps, because the window has already silenced the top voice.
- **The window:** `w(x) = 0.5 − 0.5·cos(2π·x)` over each voice's normalised log-frequency position x between 40 Hz and 12 kHz. Loudness is normalised so the sum stays constant as φ advances. As built: exactly eight octaves, 43.3 Hz–11.09 kHz (inside 40 Hz–12 kHz), so the wrap is at w = 0 at both ends; one stack per held pitch class.
- **It never arrives:**
  - At Rise 0.08 with A3 held for 30 s, the spectral centroid is periodic with a period of **12.5 ± 0.5 s** and never monotone beyond one period.
  - Band energies at 1 s and 13.5 s match within **1 dB**.
- **The seam:**
  - RMS over any 1 s window stays within **±0.5 dB** of the 30 s mean.
  - No sample-to-sample jump above 0.05 at the wrap.
- **Tension (0…1):**
  - It multiplies the rate by 1 + 3·tension, so tension 1 gives a period of **3.1 ± 0.3 s**.
  - It opens the pad's filter cutoff from 600 Hz to 6 kHz.
  - At tension 1 the 2–6 kHz energy is **≥ 6 dB** higher.
  - With Excitement on, tension comes from `ExcitementFrame.tension`. With it off, from aftertouch (Excitement on: aftertouch adds 0.3 to it).
- **The drop:**
  - When `ExcitementFrame.drop` jumps to 1, φ freezes and the window collapses to the fundamental octave over **120 ms**: the riser's energy above that octave falls by **≥ 20 dB**. As built, φ settles on the nearest whole octave in those 120 ms, so the riser lands on the held notes, in tune with the pad.
  - The pad's filter snaps open, and a one-shot **sub thump** fires: a 48 Hz decaying sine that appears within 10 ms and decays over **400 ± 50 ms**.
  - Over the next 2.5 s the riser fades out (−40 dB by 2.5 s) and the pad plays on alone.
  - **Once only:** a second drop within 2.5 s is ignored until the release envelope passes 0.2, with no second thump (48 Hz energy over 0.5–0.9 s below −30 dB relative to the first thump's peak).
  - Without Excitement the drop fires on a hard chord (three note-ons within 40 ms at mean velocity ≥ 0.78) after tension has been above 0.6.
- **The pulse:** a tempo-locked tremolo on the pad. At Pulse 0.5 and Tempo 124 the amplitude dips every **483.9 ± 2 ms**. Pulse 0 is off. Tempo runs 70…170 BPM.
- **Grit:** a soft drive before the ladder, 0–12 dB (as built, and the same on the ladder's output stage). At Grit 1 the 3rd-harmonic level is **≥ 10 dB** above Grit 0 (measured where the 3rd harmonic lies above the pad's filter, as on A4).
- **The hold rule:** the riser runs only while a note is held or the pedal is down. On release the pad takes its release (0.6–3 s by Tail) and the riser is gone in 200 ms.
- **Pitch bend ±2 semitones.**
- **Tuning:** pad only, A2–A5 within **2 cents** with the DRY hook; slop ≤ 6 cents. Fine tune and transpose are exact.
- **Safety:** NaN-free at every extreme. `allSoundOff` takes the riser and the thump below −60 dBFS within 50 ms. No allocation on the audio thread. Tension and the drop are atomics read once per control block.
- **CPU:** 8-voice polyphony, each with 8 riser partials = 64 saws. **< 7%** on the Intel Mac at 8 held notes with Grit .6 and Space .5.

## What we'll do better
- **The rise is tied to the world.** Tension drives the riser's rate and the wall cloud's rotation, so the sound and the sky climb on one number (`instrumentTension`).
- **The drop is handed to the storm.** The riser resolves once, and the gust front hits in the same frame.
- **The pulse follows your tempo.** Pulse and Tempo are dials, and the world reads the pulse.
- **Lean in.** Pressure opens the filter and speeds the climb; the wheel bends everything ±2 semitones.
- **Every part is a dial:** Rise, Pressure, Grit, Pulse, Tempo, Tail, Sub, Space and Width. *Pad Only* is a preset (Rise 0), not a second engine.

## Playing notes
- Hold a minor chord and let it climb. Hold the pedal and the riser keeps going with your hands off.
- Press into the keys to gather: the climb speeds up and the pad opens.
- After a build, play a hard low chord for the drop. Listen for the thump, then the pad alone.
- Pulse at 0.5 at Tempo 124 for the relentless pulse; Pulse 0 for a plain swell.
- **Tuning:** concert pitch, Fine tune 0.

## Preset starting values
Rise is in octaves a second (0 switches the riser off). The spec lists only what differs from *Supercell*, so the other dials are taken from it. The spec doesn't set Space and Width: *Supercell* keeps the engine's defaults (.50, .60); as built in Task 3 the others lean with their character (*Slow Front* far and wide, *Siren* close so its pulse stays tight, *Pad Only* with air round it). Those four pairs were reasoned, not heard: **check them by ear.**

| Preset | rise | pressure | grit | pulse | tempo | tail | sub | space | width |
|---|---|---|---|---|---|---|---|---|---|
| Supercell (default) | .08 | .40 | .30 | .50 | 124 | .60 | .70 | .50 | .60 |
| Slow Front | .03 | .40 | .30 | 0 | 124 | 1.0 | .70 | .70 | .75 |
| Siren | .30 | .40 | .60 | .80 | 128 | .60 | .70 | .35 | .50 |
| Pad Only | 0 | .40 | .30 | .50 | 124 | .60 | .70 | .60 | .70 |

## In the app (Task 3, as built)
- **The credit:** "FADE", Kanye West, *The Life of Pablo*, 2016, track 18 (the final tracklist, from memory: check it), 124 BPM (the felt pulse). No key is claimed until one is heard, so the card's liner notes read `TRACK 18 · 124 BPM`.
- **Tension and the drop:** `SceneDirector` owns Excitement and steps it every frame from the notes; its `instrumentCue` (Excitement's tension, and the drop on the one step it lands) reaches the engine through `AppModel.cueInstrument` and the two C calls. With build and drop off, the cue is 0.7 × the pressure, so with the engine's own 0.3 the riser climbs at the pressure itself (aftertouch = Tension). `SceneDirector.instrumentTension` is the same number for the world.
- **The demo** (`DemoPhrases.endlessRise`, F minor at 124) is rendered as the app plays it, through a director, because its drop is Excitement's.
