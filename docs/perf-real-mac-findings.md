# Real-Mac performance: findings (14 Nov 2026, branch `real-mac-perf`, from build 214)

Source: Michael's Help > Copy Performance Report, MacBookPro14,3 (Radeon Pro 560 in use), Smooth, 1265 x 790.
Every world: typical ~18 ms (vsync), 95% ~50 ms, worst 740-900 ms, one stall of 2-10 s; GPU 3-8 ms typical.
Moonlit Lake typical 32 ms (GPU 4 ms), Bioluminescent Bay 22 ms. Line numbers below are build 214's (`origin/main`
6f77a73) unless marked "now".

## 1. What happens on world entry (build 214)

The world switch is set by `AppModel.setTheme` (AppModel.swift:516) and picked up by the canvas on its next frame:
`ThemeCanvas.syncSettings` -> `SceneDirector.switchTheme` (ThemeCanvas.swift:97) makes the new model. The renderer was
made lazily **inside `drawFrame`**, on the main thread, the first frame the world's frame type came back
(ThemeCanvas.swift:166-236, e.g. :174 `if moonlitLake == nil { moonlitLake = MoonlitLakeRenderer(device: device) }`).
Its time lands in the next frame's gap, and is recorded under the new world.

Synchronous main-thread work inside that one frame, per world:

| Step | Where (build 214) | What |
|---|---|---|
| Sky dome | WorldKit/SkyLayer.swift:239, :246, :250 | `makeLibrary(source: SkyShaders.source)` (~1,900 lines MSL), 1 pipeline, 1x1 texture |
| Weather | WorldKit/SkyLayer.swift:700, :713 | the **same** `SkyShaders.source` compiled again, 2 pipelines |
| Warp | WorldKit/WarpLayer.swift:108, :120 | `WarpShaders.source` (= `SkyShaders.common` + warp), 2 pipelines |
| Window glass (cabin, bedroom, submarine, tea house x2) | WorldKit/WindowKit.swift:217, :234 | `WindowKitShaders.source`, 6 pipelines each |
| World's own | e.g. Worlds/MoonlitLakeRenderer.swift:53, :67, :80 | its source (= `SkyShaders.common` + world, 2,000-3,400 lines), 3-9 pipelines |
| Volcano extras | Worlds/MagmaVeinsRenderer.swift:44; VolcanoRimRenderer.swift:148, :160 | another library, a 512^2 RGBA32F texture, a compute pipeline |
| Drive extras | LightTrailsRenderer.swift:34; WindscreenLayer.swift:17, :99 | `WindscreenShaders.source` compiled 3 times (ViewCopy x2, WindscreenLayer) |

So each entry compiled `SkyShaders.common` 3-5 times plus the world's own code (4-8 runtime MSL compiles) and built
6-20 pipelines, synchronously. On a cold shader cache (the first run of a new build) that is seconds on the Radeon
Pro 560 (a stall: gap > 1 s, excluded from the histogram); on a warm cache, hundreds of ms (the 740-900 ms "worst").

Built later, also inside a frame (mid-play hitches):

- The sky's storm programs: `SkyPipeline.state` built the storm / supercell specialisation of every sky-reading pipeline
  the first frame a far storm, sprite, ash or supercell appeared (WorldKit/SkyPipeline.swift:83-101) - the dome's and the
  world's own, the biggest fragment shaders in the app.
- The supercell impostor's compute kernel (WorldKit/SkyLayer.swift:341-348) and its 1280 x 2688 RGBA16F texture
  (27.5 MB, :350-357) on the first supercell frame.

Allocations on the draw path that stay (cheap, once per drawable size, not compiles): `RenderStack.resize`
(RenderStack.swift:69: HDR, depth, DoF, 5 bloom levels), `ViewCopy`, the glass's blur/view copies (WindowKit.swift:454,
:523), Lightning Plains' storm target, Supercell's cloud targets, Volcano's plume, the drive's mirror, the garden's shafts.
The supercell texture stays lazy too (allocating it for every world would hold 440 MB).

Other main-thread work at entry: the frost fields (cabin, bedroom, tea house) grow on a background queue and are uploaded
on the main thread when done (SnowboundCabinRenderer.swift:110-113, BedroomDawnRenderer.swift:143-146,
TeaHouseSnowRenderer.swift:18-23); the star texture is built once in the background and uploaded on the main thread
(SkyLayer.swift:28-30, :44). A Set switch (`AppModel.applySet`, :579) also loads the set's instrument on the main actor
(`AudioEngine.loadInstrument`: `AVAudioUnit.instantiate`, then `engine.attach` / `connect` while the engine runs,
AudioEngine.swift:94-110) and writes the settings 3-4 times (`autosave`, AppModel.swift:855-862: the AU's full state and a
JSON file). At launch, `RenderStack.init` compiled `PostShaders` and 5 pipelines in `ThemeCanvas.init` (before the first
frame).

## 2. What happens every frame

`ThemeCanvas.drawFrame` (now ThemeCanvas.swift `drawFrame`): `syncSettings` (only when `visualsVersion` moved), timing
and `AutoQuality`, drawable size, events, the sound reading into the hub, `director.step` (the world model and the
Living Sky), the instrument cue, ambience (a lock, at most 10 Hz to the engine), `noteSceneReport` (publishes only on a
change of `holdShown`), the "Meteors tonight" line (once a second, published only on change), the renderer's `update`
and `render`, `stack.post`, commit. No per-frame `@Published` change reaches SwiftUI from the canvas (checked:
`drainDialChanges` publishes `movedDials` only when its count changes). Per-frame allocations are small (the ambience
dictionary, 88 key visuals, a few instance arrays).

## 3. What changed (this branch)

- `ShaderCache` (Visuals/ShaderCache.swift): one library per source, per process, any thread; the shared layers'
  pipelines memoised (sky dome and its storm programs, weather, warp, window glass, finishing passes, the supercell
  kernel). `SkyShaders.common` is now compiled once for the dome/weather and once per world source.
- `WorldRenderers` (Visuals/WorldRenderers.swift): the warm-up starts in `ThemeCanvas.init`: every world's renderer made
  on `ShaderWork.queue` (utility QoS, one job at a time), the current world first; then, once all are made, every storm
  program and the supercell kernel (the heavy extras). A world entered before it is ready is moved to the front of the
  line; its frames draw nothing new (the last frame stays; a dark frame at launch) - nothing waits.
- The renderers and shared layers are no longer `@MainActor` classes (made on any thread, used on the main thread);
  `ThemeRenderer` conformance moved to an extension. `SkyPipeline` and `StarTextureCache` are thread-safe.
- In the app (`ShaderWork.defersDrawPathBuilds`), a storm program a frame finds missing is made off the main thread and
  the plain program stands in meanwhile (only possible before the warm-up's extras finish). Previews and tests build at
  once as before, so their pictures are unchanged.
- **Not covered**: Tea House Snow and Zen Rock Garden (files off-limits). Their renderers are still `@MainActor` and are
  made on the main thread when first shown (counted in `ShaderWork.drawPathBuilds`); their sky, weather, warp and glass now
  come from the caches, so the remaining cost is their own library and pipelines. Including them takes two lines in each
  file (drop `@MainActor`, move `: ThemeRenderer` to an extension) and a case in `WorldRenderers.make`.
- Not changed: the Set switch's instrument load and settings writes (audio graph changes stay on the main actor);
  `InstrumentSwitchTimingTests` (audio suite) measured making each engine's Sound Core and Audio Unit and allocating it
  at 44.1 kHz on CI: under 0.2 ms for every engine, so the DSP side of a Set switch is not a hitch; what remains on the
  main actor is AVAudioEngine's attach/connect while running and the settings writes (not measured on CI, which has no
  audio device; the new report's Entry worst against Entry CPU will show it: a long entry gap with a short canvas time).

## 4. Moonlit Lake 32 ms / Bay 22 ms

Not reproduced, and not the worlds' per-frame CPU. `WorldCPUTimeSweepTests` (new) runs every world's demo for 5 s at
Smooth 1264 x 790 under a night and a day sky, timing the step (world + sky + ambience), the renderer's update and the
encoding, as the canvas does them. On CI (run 43454537159, looks job; InStrumApp is built without `-O` in tests, so
update/encode are pessimistic, the step is optimised):

| World | frame (night / day) ms | step | update | encode | note |
|---|---|---|---|---|---|
| moonlit-lake | 0.79 / 0.85 | 0.21 | 0.36 | 0.23 | among the cheapest |
| bioluminescent-bay | 1.03 / 1.04 | 0.26 | 0.47 | 0.27 | |
| spaceship-lounge (untouched) | 0.85 / 0.78 | 0.33 | 0.19 | 0.32 | |
| golden-hour-beach (untouched) | 0.87 / 0.89 | 0.22 | 0.39 | 0.24 | |
| great-barrier-reef (untouched) | 1.39 / 1.37 | 0.29 | 0.77 | 0.30 | |
| bedroom-dawn | 3.82 / 3.76 | 0.82 | 2.70 | 0.29 | heaviest step (the curtains' cloth) and the curtains' projection |
| neon-night-drive | 4.55 / 4.44 | 0.29 | 3.83 | 0.41 | heaviest update (debug build) |
| lightning-plains | 1.99 / 2.05 | 0.27 | 1.41 | 0.31 | |

All other worlds 0.8-1.6 ms. The lake's model and renderer do nothing per frame that the beach or the fjord don't
(ripples, fireflies, keys, the shared sky and weather; checked in MoonlitLakeModel.swift, LakeRipples.swift,
MoonlitLakeRenderer.swift), and its GPU frame was 4 ms on his Mac. So the 32 ms was not the lake's own work: with under
30 s in the world, his row is dominated by whatever else held the main thread then (build 214 compiled the next world on
entry, a Set switch loads an instrument and writes the settings on the main thread, launch-time work). The new report
answers it directly: per world, steady frames apart from the first 3 s, the canvas's CPU time a frame and the step's
share, and the stalls' causes. If the lake's steady typical is still 32 ms with CPU typ well under 16 ms, the time is
outside the canvas (SwiftUI or another main-thread client) or in presentation; if CPU typ is high, Step typ says whether
it is the world model.

## 5. CI measurements (this branch)

- Pictures: the lake's, the lounge's and the volcano's previews (23 frames, sprites and storms included) rendered on this
  branch are pixel-identical to main's (`previews` branch, build 6f77a73): max difference 0.
- CPU sweep repeated (second run): the same medians within 0.1 ms; the bedroom's 21-41 ms slowest frame of the first run
  did not recur (6.5 ms), so it was the runner. Slowest frames everywhere else 1-7 ms.
- GPU frame times (`WorldFrameTimeSweepTests`, same run) match main's within the runners' spread (lake 10.07 against
  10.35 ms, bay 14.53 against 14.95, lounge 6.12 against 6.45): the renderers draw the same work.
- Warm-up (WorldRenderersTests, CI): every world and every storm program made off the main thread in 3.1-7.3 s, then every
  world entered with a frame at once and 0 builds on the draw path; Tea House Snow and Zen Rock Garden one main-thread
  build each, and never again.
- World switch itself (`SceneDirector.switchTheme`, a new model) is 0.01-0.8 ms (Zen Rock Garden 3.5 ms once, its rake
  lines), and its first step 0.1-1.0 ms: not a hitch.

- Open: in the one full App run that finished (run 43467777409), `testBayBurstStaysInBudget` (4.2 s against its 4 s limit,
  8.2 s for the test against main's 5.2) and `testSubBurstStaysInBudget` (4.3 s against 1.6) ran ~3 s slower than on
  main while every other test and both frame-time sweeps matched main. Not explained: their per-frame code and GPU work
  are unchanged. A shared frost-field cache tried for it (the bedroom's and the cabin's tests, which run just before,
  each start a seconds-long frost growth) was taken out again: with it, every CI job that ran those classes lost its
  runner (below).
- CI on 13 Nov: "The hosted runner lost communication with the server" ~55 min after the job started. This branch: 7 of
  its 8 jobs that ran the bedroom/bay/cabin/lounge/submarine renderer tests did not finish (6 lost, 1 stopped by hand
  after 58 min): 2 of 3 before the frost-field cache, 5 of 5 with it. look-volcano-sky-plains (none of this branch's
  code): 3 of 5 App-suite runs lost the same way. The jobs that did not run those classes (both branches' other looks
  jobs, all Core and Audio jobs) always finished. Those classes start about 10 min into a job. Which test stops an
  Intel VM is not known; the frost cache made it worse, so it is out.

## 6. Stalls

A stall is a gap over 1 s between drawn frames. The draw loop also stops when the window is covered, minimised or the
screen sleeps (MTKView's display link), which build 214 reported the same way. The report now says, per row, how many
stalls happened in front, in the background (window showing) or with the window hidden, and keeps the first 3 s after
each entry apart (Entry worst includes stalls).
