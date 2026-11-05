# Sound brief: Single Note Grand (Lightning Plains)

A cavernous concert grand that becomes a voice under pressure. It stands on **Felt Glass's string core** plus the formant helper from Sets 11 & 12. Engine 17. Spec: `docs/superpowers/specs/2026-11-05-storms-design.md` §2, §4.2 and §12. Plan: Tasks 4 and 5.

## Facts
- **The set's credit:** "Runaway", by Kanye West, from *My Beautiful Dark Twisted Fantasy* (2010).
  - The record opens on **one piano note, repeated**. Its closing voice is **an octave down and distorted**.
  - The card's one-line description is ours: "one piano note, repeated, and a voice that arrives distorted". It says what the instrument does; it is not a claim about how the recording was made.
  - Spotify search: `Runaway Kanye West`. Credits are text and a Spotify link only.
  - **No artwork, lyrics or imagery from the record.** Nothing is sampled, copied or modelled from it. We take the *idea* only: a single repeated note, and a piano that breaks into a voice.
- **The felt pulse:** 85–87 BPM. The card breathes at **86**. **Check by ear** before the card relies on it.
- **Key:** none is fixed by the spec. Find it by ear.
- **Why a plain gets it:** Lightning Plains is the lonelier sister of Supercell Sky. One repeated note on an empty plain lands a strike on the horizon each time, and the storm walks closer as you play. Under pressure the note turns into a voice as the storm reaches you.

## What we're matching
- **The grand:**
  - Felt Glass's string core with the felt at **0.2** and a longer, darker board, in a **2.8 s hall**.
  - Reuse, don't copy, the string and the board. Parameterise the felt and the board length.
  - 16 voices.
- **The morph:**
  - `morph = smooth(aftertouch, 80 ms up, 250 ms down)`. After an aftertouch step from 0 to 1 the read-back reaches **.63 at 80 ± 10 ms**. From 1 to 0 it reaches **.37 at 250 ± 25 ms**. *(As built: the target is the Morph dial plus the pressure the rest of the way; read back as `ISD_DEBUG_MORPH_PERMILLE`. Measured 80 ms and 249 ms.)*
  - Output = `(1 − morph) · piano + morph · voice`. *(As built: both × 1/√(1 − 1.4·m(1 − m)), +1.9 dB halfway, so the morph holds its loudness; the formants are in phase with the string, so nothing cancels on the way.)*
  - At pressure 0 it is a piano. At 1 it is a voice.
- **The voice:**
  - `voice = softclip(formants(stringExcitation · gain(morph)))`, fed by the same string excitation as the piano.
  - Gain runs 1 → 8 (18 dB) with morph, through a `tanh` clipper.
  - Two formants open with morph: F1 400 → 700 Hz and F2 1200 → 1800 Hz, bandwidths 80 and 120 Hz. It is an "ah" opening to an "aw".
  - Measured: F1 at **400 ± 40 Hz** at Morph .1 and **700 ± 60 Hz** at Morph 1.
  - At Morph 0 the 400–700 Hz formant peak is absent (< 3 dB above the string's envelope). At Morph 1 it is **≥ 12 dB** above. At .5 it is between.
- **Break:** the clipper's drive. At Morph 1, Break 1 raises the 3rd harmonic **≥ 10 dB** over Break 0. *(As built: 0–30 dB of drive with a make-up gain. Measured on C5, whose 3rd harmonic falls between the formants: +18.7 dB, and −28.0 → −12.2 dB against the fundamental, the level within 3.5 dB. On a note with a harmonic on a formant, A3's 3rd or A4's 4th, the clean voice already leads with it, and a clipper can't lift a harmonic past a square's −9.5 dB.)*
- **Octave Down:** adds the voice an octave below, 0…1. At Morph 1, Octave Down 1 adds a component at f0/2 within **3 dB** of f0. *(As built: ring modulation by the half-angle of the string's first partial, locked to it. Measured +1.4 dB.)*
- *(As built: the voice also carries the string's own first partial beside the formants, its body and pitch; and a held key's string sings on under pressure, every partial's decay stretched toward none, t60 × 25 at Morph 1.)*
- **Pitch:**
  - At Morph 0, tuning is within **2 cents**, A0–C8 (PIANO_ONLY, DRY hook).
  - At Morph 1 the voice stays within **5 cents** of the string (VOICE_ONLY, A3). The formant filters do not shift pitch.
- **The drop's forced morph:**
  - `isd_synth_set_forced_morph` holds the morph at .8 for the drop's 2.5 s, over the player's aftertouch.
  - On release the morph returns to the player's aftertouch over **250 ± 25 ms**, never snapping: no step larger than .05 per ms. *(Measured: 63% of the way back at 251 ms; the largest step .008 per ms.)*
- **Repeat detection:**
  - The same key struck **four or more times at 2 a second or faster** sets `repeating`, which Strike Lines reads through `SceneDirector.instrumentRepeat`.
  - Four strikes at 2.5 a second: true after the fourth. Three strikes, or four at 1.5 a second: false. A different key resets it.
  - Pure control-rate bookkeeping.
- **Safety:** NaN-free at every extreme; `allSoundOff` is silent within 50 ms; no allocation on the audio thread.
- **CPU:** **< 6%** on the Intel Mac at a 10-note chord with Hall 1 and Morph .5. *(Measured: 3.9% of a core on the build machine, where Felt Glass's budget chord takes 3.1–3.5%.)*
- *(As built, the grand: Felt Glass's strings, felt thump and board, shared from `PianoStrings.hpp`, at Felt .2, a ring of .75 and a board 1.35× longer and darker; the hall 2.8 s at Hall .7 as heard (measured T20 2.84 s), about 4.6 s at 1 and 1 s at .1. Tuning measured within 0.29 cents, A0–C8.)*

## What we'll do better
- **The note turns into a voice under your hands.** Pressure cross-fades the string into a singing, breaking vowel, and the same number (`instrumentPressure`) sets the storm's distance and the voice's distortion.
- **The repeated note is an instrument feature.** The grand notices it and tells the world, so each strike lands on the horizon.
- **The drop forces the voice.** The storm's arrival sets Morph to .8 for 2.5 s, then hands it back to you without a jump.
- **Every part is a dial:** Hall, Felt, Morph (a manual floor under aftertouch), Octave Down, Break, Width and Space.

## Playing notes
- Strike one key again and again, at 2 a second or faster: eighth notes at 86 BPM are 2.9 a second. Watch the strikes land on the horizon and walk closer.
- Press into the key after it sounds. The piano becomes a voice; Break makes it ragged; Octave Down puts a second voice below.
- Open into chords when the storm arrives. A hard chord after a build is the drop.
- **Tuning:** concert pitch, Fine tune 0.

## Preset starting values
The spec lists only what differs from *Runaway*, so the other dials are taken from it. Space and Width stay at the engine defaults; the spec doesn't set them, so Task 5 tunes them by ear. Felt is .2 in every preset.

| Preset | hall | felt | morph | octave down | break |
|---|---|---|---|---|---|
| Runaway (default) | .70 | .20 | 0 | .50 | .50 |
| Marble Hall | 1.0 | .20 | 0 | .50 | .50 |
| Broken Voice | .70 | .20 | .60 | .50 | .90 |
| Dry Grand | .10 | .20 | 0 | .50 | .50 |
