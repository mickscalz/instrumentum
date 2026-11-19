# The Recorder: recording, overdubbing, play-along and input sources: Design Spec

**Date:** 2026-11-16
**Status:** Written to Michael's standing instruction to keep going without questions. §11 lists every choice made without asking, and what changing it would cost. Branch: `recording` (off `main`, build 214+).

**What Michael asked for (16 Nov):**
1. "Add recording features."
2. "Record over the top of a recording together (dubbing?)."
3. "Record with BlackHole playing music through Spotify but still able to hear instrument playing and Spotify playing at the same time, or also option to upload track to play alongside with if that's easier on the processing."
4. "The ability to choose import source for recording so I can play instruments through audio processors and microphones."
5. "Add recording studio to future worldscape plans." (Done as world #291 in the project doc `claude/2026-11-16-recording-studio-world.md`; not part of this build.)

**Builds on:** Keep That (`TakeKeeper`, `TakeStore`, `StandardMIDIFile`), `AudioEngine` (instrument bus, ambience bus, output-device choice and recovery), the Small Wins top-bar buttons and toast.

---

## 1. Purpose and success

Today the app only keeps the notes (Keep That saves a MIDI file). The Recorder keeps the **sound**, lets him build a piece in **layers**, and lets him play and record **along with other music** and **with other instruments and microphones**.

Success looks like:
1. One click records what he plays as audio. One click stops. The file is in `~/Music` and plays anywhere.
2. He can record a second, third … layer over the first while hearing the earlier layers, each with any instrument and world, and the layers line up as he heard them.
3. He can play along with Spotify (through BlackHole) or with a track he drops in, hear both at once, balance them, and record the result.
4. He can pick any input on the Mac (a microphone, an audio interface, an effects processor's return) as a live source, hear it with the app's instrument, and record it as a layer.
5. The sound he hears while playing never glitches because of recording, and the visuals do not slow down.

**Standing rules hold:** personal use; older settings load; nothing is written to disk until he presses Record; audio-thread code never allocates, locks or touches files; the GPU safety net is untouched.

**Anti-goals:** a DAW (no editing, cutting, tempo grid, plugins on layers); anything that changes how the instrument sounds when the Recorder is off.

---

## 2. What he sees

A red **Record** dot joins the top bar next to Keep. Clicking it opens the **Recorder strip** along the bottom of the window (above the on-screen keyboard), and the top-bar dot shows the running time while recording.

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ● Record   ▶ Play   ■ Stop      0:42 / 3:15      Play along: [Mac sound · BlackHole ▾] ▁▃▅ │
│                                                   Live input: [Scarlett 2i2 · 1+2  ▾] 🎧 ▁▃ │
│ 1 Felt Glass   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬   🔈──●──  M  ✕                                    │
│ 2 Magma Bass   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬           🔈────●  M  ✕                                    │
│ 3 Microphone   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬     🔈──●──  M  ✕              [Save]  [New]  [Open…]│
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Record** (⌘R): with no layers, starts a new recording. With layers, it is **overdub**: the earlier layers play from the start and a new layer records on top. A 3-2-1 count shows before an overdub starts (can be turned off).
- **Play / Stop** (⌘↩): plays the layers back. Stop ends recording or playback. Esc (panic) also stops a recording and keeps it.
- **Layer rows:** name (the instrument or input it came from), a waveform, volume, mute, delete. Deleting the newest layer is the "undo" for a bad take.
- **Save** writes the mix; **New** starts a fresh recording (asks first if the current one is unsaved); **Open…** reopens a past recording to listen or add layers.
- The strip hides with the same button; hiding never stops a recording.

---

## 3. Recording

- **What a pass records.** Each pass writes one stem per source that is switched on:
  - **Instrument:** the app's instrument (built-in or plugin), taken from the instrument bus, before the master volume and the sleep fade.
  - **Live input** (§6), if one is chosen.
  - **Play-along** (§5), if one is playing and "Keep the play-along in the recording" is on. It is recorded on the first pass only.
  - **Ambience,** if "Record the world's ambience" is on (default off). First pass only, so it never stacks.
- **Stems are separate files,** so the instrument is always clean of Spotify and of the microphone.
- **Notes too:** each instrument layer also saves its MIDI (from the existing keeper), so a layer can later be re-rendered through another instrument (future work).
- **Format:** stems are WAV, 24-bit, stereo, at the output's sample rate. The mix is **`Mix.m4a`** (AAC, 256 kbps) and, if "Also save a WAV mix" is on, `Mix.wav`.
- **Where:** `~/Music/In Strum Meants/Recordings/2026-11-16 21.07 — Moonlit Lake/` holding `Mix.m4a`, `Layer 1 — Felt Glass.wav`, `Layer 1.mid`, `Layer 2 — Magma Bass.wav`, `Play-along.wav`, `Ambience.wav` and `session.json` (layers, volumes, mutes, offsets, the Keep That note of the moment for each layer, app version).
  - Stems are written as they record into the session folder. An unsaved session lives in a temporary folder and is moved on **Save**; quitting with an unsaved recording asks Save / Discard.
- **Limits:** 8 layers; 60 minutes per layer; recording refuses to start with under 2 GB free and stops (and keeps what it has) under 500 MB.
- **If the sound output changes or stops mid-recording,** the pass ends cleanly, the layer is kept, and a toast says so.

## 4. Overdubbing and staying in time

- Overdub always starts from the beginning of the recording. Stopping early gives a shorter layer.
- **Lining up.** Everything is on the engine's one sample clock: earlier layers start at a scheduled sample time and the new stems are stamped with the tap's sample time.
- **Latency.** He plays to what he *hears*, which is later than the engine's clock by the output's latency (a few ms on built-in speakers and wired interfaces; 150 ms or more on Bluetooth). So:
  - an **instrument** stem is moved earlier by the output latency;
  - a **live input** stem is moved earlier by the output latency plus the input's latency (its device latency, safety offset and buffer, plus the capture buffer of §6);
  - the play-along stem and the earlier layers are not moved.
  - Latencies are read from Core Audio. A **Timing nudge** (−100…+100 ms, default 0) in the Recorder's settings corrects a device that reports wrongly.
- **Mixdown** (on Save, and for Play): each stem × its volume, summed at its offset. If the peak passes −1 dBFS the whole mix is turned down to fit (one gain for the whole file, never a pumping limiter). The mix is rendered off the audio thread.

## 5. Playing along: a track file, or the Mac's sound through BlackHole

**Play along** has three settings: **Off**, **A track…**, **Mac sound (BlackHole)**.

### 5.1 A track (the light and exact way)
- Choose or drag in an audio file (MP3, M4A/AAC, WAV, AIFF, FLAC, ALAC). Copy-protected files can't be opened; the app says so.
- It plays on its own bus with its own volume, with play/pause and a scrub bar. "Start the track when I record" (default on) starts it from its beginning on Record.
- It is the cheapest path (a file read, no second device, no clock drift) and lines up to the sample.

### 5.2 Mac sound through BlackHole (Spotify, YouTube, anything)
- **How it works:** the Mac's sound goes to BlackHole (a free virtual output that plays to nowhere); the app listens to BlackHole, **plays it through to his speakers or headphones itself**, mixed with the instrument, and can record it. So he hears Spotify and the instrument together, with a volume for each.
- **One switch.** Turning this on:
  1. finds a device whose name starts with "BlackHole". If there is none, the strip shows a small card: what BlackHole is, an "Open the BlackHole page" button (existential.audio), and "Look again";
  2. remembers the Mac's current output, sets the **Mac's output to BlackHole**, and makes sure the **app plays to the real output** (the remembered one, or the one already chosen in Sound & MIDI);
  3. starts listening and playing through.
  Turning it off, or quitting, puts the Mac's output back. If the app dies with it on, the next launch puts it back (a small marker in settings).
- **No howl.** The app never plays into the device it is listening to: if the app's output would be BlackHole, play-through stays muted and the strip says "Choose your speakers in Sound & MIDI".
- **Volume keys:** while it is on, the Mac's volume keys act on BlackHole, so the strip's **Play-along volume** is the control to use. The strip says so once.
- **Permission:** macOS asks for microphone permission the first time (any input counts as a "microphone"). Denied → the switch shows **Allow in System Settings**.
- **Two clocks.** BlackHole and the speakers run on separate clocks that drift apart slowly. The capture goes through a small buffer (target 10 ms) and a gentle resampler that keeps the buffer level steady, so there are no clicks however long he plays.

*(Not in this build: capturing the Mac's sound without BlackHole through macOS's screen-and-audio capture. It needs no install but arrives late and can't be lined up as well. It can come later as a third source.)*

## 6. Live input: microphones, interfaces and processors

- **Live input** is a menu of every input on the Mac (built-in microphone, audio interfaces, an effects unit's USB return, BlackHole 16ch, aggregate devices), then a **channel** choice (1, 2, 1+2, 3+4 …; a single channel records as centred mono).
- **Hear it** (the headphones toggle): on plays the input through with the instrument; off records it silently (for an amp in the room or a mic near the speakers). Default **off** for a built-in microphone (to avoid feedback), **on** for anything else.
- **Level:** an input gain (−24…+24 dB) and a meter that turns red at clipping.
- It records as its own layer, in the same pass as the instrument or alone ("Record: Instrument / Live input / Both").
- **Processors:** to play the app's instrument *through* an outboard processor, choose the processor's send as the app's output in Sound & MIDI and its return as the Live input, with Hear it on. The Recorder then records the processed return. The same no-howl rule applies: if input and output are the same device and Hear it is on, the app warns once (an interface with direct monitoring would double the sound).
- Live input and Play along use the same capture engine (§5.2's buffer and resampler), so both can run at once on different devices.

## 7. How it is built

- **Core (`InStrumCore/Recording/`, pure Swift, no audio frameworks):**
  - `RecordingSession` (layers, kinds, volumes, mutes, offsets, limits), `RecordingStore` (folder and file names, `session.json`, temp → saved), `Mixdown` (sum with gains and offsets, the one-gain headroom rule, peak and waveform summaries), `RecordingLatency` (the offset arithmetic of §4).
- **Audio (`InStrumAudio/`):**
  - `AudioEngine+Recording.swift`: three new buses into the main mixer (`playAlongBus`, `liveInputBus`, `layersBus`); the instrument tap fans out to the level reader *and* the recorder (a node has one tap); `StemRecorder` copies tap buffers into a preallocated queue drained by a writer thread into `AVAudioFile`s, each stamped with its first sample time.
  - `LayerPlayer`: `AVAudioPlayerNode`s for the track file and the earlier layers, all started at one future sample time.
  - `InputDevices` (list, channels, latencies, the Mac's default output get/set) and `InputCapture` (a second, input-only engine on the chosen device → lock-free ring → `AVAudioSourceNode` in the main engine, with the drift-following resampler).
- **App:** `AppModel+Recording.swift` (state machine: idle / counting in / recording / playing; the settings; the toasts), `Views/Recorder/` (the top-bar button, the strip, the BlackHole card, the settings), the Play menu items and shortcuts, `NSMicrophoneUsageDescription` reworded for inputs.
- **Cost:** recording adds a memory copy per audio buffer and a background file write; capture adds a 2-channel resampler. Both are far below one percent of a core. Nothing touches the renderer. With the Recorder off and no source chosen, the engine's graph and sound are exactly as today.

## 8. Edge cases
- Changing instrument or world between layers is fine and expected; during a pass it is allowed too (the layer just carries the change).
- Sleep fade during a recording: the recording is not faded (stems are taken before the fade).
- Panic stops and keeps the pass.
- Output device lost mid-pass: §3.
- BlackHole removed or the input unplugged mid-pass: that stem ends there; the others carry on; a toast says so.
- A sample-rate change between sessions: reopened layers are resampled on load to the current rate for playback; new stems record at the current rate; the mix is rendered at the first layer's rate.
- Older settings files load with the Recorder off and no sources chosen.

## 9. Testing
- **Core:** file and folder names; `session.json` round-trip and old-file tolerance; mix maths (gains, offsets, mute, the −1 dBFS rule: one gain, never louder than the sum); latency arithmetic; limits (8 layers, 60 minutes, disk guards).
- **Audio (offline engine):** with the Recorder idle the rendered output is bit-identical to today's; the instrument stem equals the instrument bus sample for sample; ambience never leaks into the instrument stem; master volume and sleep gain never reach a stem; an overdub of a click against a click layer lands within 1 sample after compensation (with an injected latency); a 60-minute simulated capture with 200 ppm drift never under- or over-runs and stays within ±3 ms of its target; the no-howl rule mutes play-through when input and output match; the Mac's output is restored on stop and after a simulated crash marker.
- **App:** the state machine; ⌘R/⌘↩; toasts; nothing is written before Record; unsaved-quit prompt; settings round-trip.
- **Michael's ear checklist** with the release: record and listen back; overdub a second layer on built-in speakers, then on Bluetooth (use Timing nudge if it flams); play along with a track; play along with Spotify through BlackHole and check both volumes; record a microphone; check the visuals stay smooth while recording.

## 10. Build order (each a task in the plan)
1. Core: session, store, mixdown, latency.
2. Audio: buses, tap fan-out, `StemRecorder`.
3. Audio: `LayerPlayer`, overdub timing, mix rendering to m4a/WAV.
4. Audio: `InputDevices`, `InputCapture`, drift, no-howl, the Mac's output switch and restore.
5. App: model, strip, button, menu, settings, permission text.
6. Whole-branch review by the main session, fixes, release notes, merge to `main`.

A first build can ship after task 5 with tasks 1–3 only wired (record, overdub, play along with a track), and BlackHole and Live input follow in the next build, if task 4 needs longer to reach the bar.

## 11. Choices made without asking
| Choice | Instead of | Cost to change |
|---|---|---|
| Stems as separate WAVs plus an m4a mix | one mixed file only | small (a setting) |
| Overdub always from the start; no punch-in, no editing | a DAW-style timeline | large; a later feature |
| 8 layers, 60 minutes each | unlimited | trivial |
| The app plays BlackHole through itself and switches the Mac's output for him | he builds a Multi-Output Device by hand in Audio MIDI Setup | small; the manual way still works with the switch's "Don't change my Mac's output" option |
| BlackHole only for Mac sound in this build | macOS screen-and-audio capture (no install) | medium; a third source later |
| Play-along is kept in the mix by default, with a switch | never recording it | trivial |
| Ambience is not recorded by default | recording it | trivial |
| One Live input at a time (plus Play along) | several inputs at once | medium |
| The world reacts to live playing only; recorded layers and live input don't drive visuals yet | ghost notes from earlier layers, the input's level moving the world | medium; a natural follow-on ("Duet with yesterday", Listen) |
| The Recorder strip at the bottom, one new top-bar button | a separate window | small |

**A note on Spotify:** recording Spotify's stream is for his own practice and listening. As I understand Spotify's terms of use, they don't allow copying or sharing its music, so a mix that contains a Spotify play-along should stay on his Mac; the clean instrument stem is his to share. (Not legal advice.) A track file he owns has no such limit.
