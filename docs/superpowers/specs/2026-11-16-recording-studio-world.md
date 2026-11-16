# Future worldscape #291: Recording Studio at Night ("The Live Room")

**Date:** 2026-11-16. **Asked for by Michael** with the Recorder ("add recording studio to future worldscape plans"). It continues the numbering of the backlog (`claude/ideas-backlog-worlds-and-skies.md`, #1–#110) and Draft A (#111–#290), and belongs in the ranked list (`claude/2026-11-05-remaining-worlds-ranked.md`) at about **11/15, Tier B**. It is a candidate for the next pair of sets once the Recorder has shipped, because the world is the Recorder made visible.

## The set (world · visual · instrument · sky · weather · ambience, tied by a mood)
- **Mood:** focused, warm, late. The hour when a take finally works.
- **World: the live room at night.** You sit at the piano in a wood-panelled live room. One thing fills the frame: the control-room window, a wide pane of glass with a long console glowing behind it and a two-inch tape machine whose reels catch the light. A skylight above shows the Living Sky, so the real moon, stars and weather still reach the room. Microphones on stands stand as dark shapes near the piano.
- **Visual: Tape & Needles.**
  - Every note swings the console's meter needles and lights a channel; soft notes barely move them, hard notes pin them.
  - What you play scrolls across the glass as a ribbon of tape, the waveform drawn in warm light and fading as it winds on.
  - Held chords make the valves behind the glass glow; the pedal blurs the ribbon.
  - **It mirrors the Recorder.** Press Record and the red RECORDING lamp lights and the reels turn. Each layer is a lit channel strip with its own colour; on playback the faders ride and the earlier layers' ribbons run under the new one. Stop, and the reels coast to rest.
  - **Big moment:** build, then land a hard chord: every needle swings into the red, the tape ribbon flares and the room's lamps bloom (through `FlashLimiter`; a slow glow with Gentle visuals).
  - **Surprises (rare):** the engineer's silhouette crosses behind the glass and gives a thumbs-up; the talkback lamp blinks; a moth circles the lamp over the console.
- **Instrument: Tape Room Grand.** A close-miked grand through tape and a plate reverb: dials for *Tape* (hiss, wobble, saturation; grown from Honey Tape's TapeKit), *Room* (the live room's size) and *Mic distance* (close and dry to far and roomy). A second voice on the same engine, *Studio Upright*, for the felt-and-tape sound.
- **Sky (SkyKit):** city glow through a skylight; the moon crossing the skylight and laying a moving square of light on the floor.
- **Weather (WeatherKit / Window Kit):** rain on a skylight, with the drops' shadows falling across the piano lid.
- **Ambience:** room tone, tape hiss and the reels' soft flutter, console hum, valves ticking as they warm, a chair creak, a far door, the talkback's click, rain on the skylight. The hiss and hum sit in the key you play in.

## Variants (the same set from another seat)
- **Control Room:** behind the console looking into the live room through the glass.
- **Vocal Booth:** close, dark, one lamp and a pop shield; the live input's level moves the room.
- **Mastering Room at Dawn:** two big speakers, a window going from blue to gold.
- **Bedroom Studio:** a desk, fairy lights, a laptop's glow; the homely twin.

## What it needs first
- The Recorder (`docs/superpowers/specs/2026-11-16-recorder-design.md`), so the lamp, reels, strips and ribbons have something real to show.
- The Window Kit (built) for the control-room glass and the skylight.
- Smooth rules as always: ≤ 1 MP, no per-pixel ray marching, ≤ 3 noise octaves; the reels, needles and ribbon are cheap 2-D shapes with one glow pass.

## Score (the ranked list's scale)
Spectacle 1 · Reactivity 3 · Kits 2 · Coupling 2 · Big moment 1 · Novelty 2 = **11**. Low on vastness, top marks for reactivity and for picture and sound coming from one cause.
