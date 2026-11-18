# The DDJ-ERGO as a bank of knobs, effects and tone, and saved sounds: Design

**Date:** 2026-11-18 · **Branch:** `ddj-ergo` (off `main`) · **Status:** built; Core tests pass; the Audio and App parts have not been compiled yet (see the project doc `claude/2026-11-18-ddj-ergo-status.md`).

**What Michael asked for (18 Nov):** "add function for the fx1 and fx2 box and the high mid low on each sides to change all instrument sound and effects and also add the ability to save presets customised. DDJ-ERGO, it's plugged in now."

## What it does
- A plugged-in Pioneer DDJ-ERGO is recognised by name and treated as a controller, not a keyboard: nothing it sends reaches the instrument as notes or controllers (its buttons are notes and its volume knob is a bank select, so this matters).
- **Left side = effects and tone.** FX1 knobs 1/2/3 are Echo, Reverb, Drive; FX1 CONTROL is the echo's time; the left HI/MID/LOW are a three-band tone control (flat at the centre, −26 dB fully left, +6 dB fully right); the left FILTER sweeps a low-pass to the left and a high-pass to the right.
- **Right side = the instrument's own dials.** FX2 knobs 1/2/3 and CONTROL are its first four dials, the right HI/MID/LOW/FILTER its next four, in the order its panel lists them. With a plugin, its first published parameters.
- **Every knob can be pointed at something else** in the new **Decks** panel: any effect or tone knob, any dial, Echo repeats, Crush, the volume, the ambience volume, or nothing.
- **Buttons:** FX1 ON switches all effects, FX1 1/2/3 switch Echo/Reverb/Drive (their lights follow). FX2 ON steps to the next saved sound; FX2 1/2 step through the instrument's presets; FX2 3 resets effects and tone.
- **Saved sounds:** Save in the Decks panel stores the instrument, every dial (a plugin's whole state), and the effects and tone under a name. Click one to bring it back (loading its instrument if needed). Files in `Presets/sound/`.
- The Decks panel's sliders do everything the knobs do, so it all works with no controller.

## Approaches considered
1. **Fixed map + a small Apple-unit effects chain + reassignable knobs (built).** Uses Apple's delay, reverb, distortion and EQ units, which add no latency and need no new DSP. Works the moment it is plugged in.
2. **MIDI-learn for everything.** Most general, but nothing works until he has taught sixteen knobs, and the 14-bit pairs make learning fiddly.
3. **New effects written in the DSP library.** Best control of the sound, but several engine-sized tasks before a knob does anything.

## How it is built
- **Core (`InStrumCore/Controller/`):** `DDJErgoDecoder` (Pioneer's published MIDI list: effect boxes on channels 5 and 6, mixer on 7; 14-bit knobs; decks C/D and SHIFT fold onto the same knobs), `ControlLayout`/`ControlTarget`, `SoundFX` + `FXMath` (knob → dB, Hz, seconds), `SoundPreset`; `PresetStore` gains `sound/`; `AppSettings` gains `soundFX`, `controlLayout`, `soundPresetName` (older files load neutral).
- **Audio:** `FXChain` (drive → crush → tone and filter → echo → reverb), every idle unit bypassed. `AudioEngine.insertFX()` puts it between the instrument and its bus **only when first wanted** (a controller is plugged in, or an effect is non-neutral): until then the graph is exactly as before. `MIDIInput` routes a controller's bytes to their own callback and can light its buttons.
- **App:** `AppModel+Controller.swift` (knobs act on the CoreMIDI thread; panel, settings and buttons follow on the main actor 20 times a second), `Views/ControllerPanel.swift`, a **Decks** button in the top bar.

## Choices made without asking
| Choice | Instead of | Cost to change |
|---|---|---|
| Left = effects and tone, right = instrument dials | an EQ on both sides | none: reassign in the panel |
| Knobs jump to where they are when touched | soft pick-up | small |
| Effects come before the level tap, so the visuals and (later) the Recorder hear them | after | small |
| Echo, Reverb, Drive, Crush from Apple's units | custom DSP | medium |
| Jog wheels, faders, crossfader, pads, tempo sliders do nothing yet | mapping them | small each |
| Saved sounds don't store the knob layout or the world | storing them | small |

## To check by ear (nobody has heard this yet)
Drive and Crush set Apple's distortion unit by its raw parameters; their loudness and character need his ear. The tone's corner frequencies (180 Hz, 1 kHz, 4.5 kHz), the reverb preset (Large Hall) and the echo's darkness (6 kHz) are first guesses.
