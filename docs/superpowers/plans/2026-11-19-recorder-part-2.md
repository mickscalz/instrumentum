# The Recorder, part 2 (19 Nov 2026): what changed since the 16 Nov plan

Read with `docs/superpowers/plans/2026-11-16-recorder.md` (tasks 1–6) and the spec `docs/superpowers/specs/2026-11-16-recorder-design.md`. Where this file differs, this file wins.

## State
- **Shipped:** the bare Record button (instrument → WAV, ⌘R), merged to `main` as `e1d7a4e` on 19 Nov. It uses Task 2's `StemRecorder` and buses.
- **Done on `recording`:** Task 1 (Core: `RecordingSession`, `RecordingStore`, `Mixdown`, `RecordingLatency`) and Task 2. `recording` = `main` + Task 1.
- **To build:** Task 3 (playback, overdub, mix, and now the transport below), Task 4 (inputs, BlackHole), Task 5 (the app: strip, model), Task 7 (the DDJ-ERGO, new, below), Task 6 (review and release).

## How to check your work now (replaces "fix until the three test jobs are green")
The full `test (InStrumAppTests)` job loses its runner on every branch since 16 Nov (a runner problem, proven with an unchanged commit). So:
- Put one line in `.github/look-filter` on your branch: a `swift test --filter` pattern with the test classes your task adds or touches, joined by `|` (e.g. `InStrumAudioTests.LayerPlayerTests|InStrumAudioTests.MixRendererTests`). The `looks` job then builds and runs just those in about 10 minutes. Read it with `gh api repos/mickscalz/instrumentum/actions/runs/<run>/jobs` → the `looks` job id → `gh api repos/mickscalz/instrumentum/actions/jobs/<id>/logs | grep -E "Executed|error:|passed|failed"`.
- `test (InStrumCoreTests)` and `test (InStrumAudioTests)` still finish; they must stay green. Ignore `test (InStrumAppTests)`.
- **Remove `.github/look-filter` in your last commit.**

## Michael's request of 19 Nov (the controller)
"Make use of the cue and play button mappings and tempo slider. Also the in and out buttons and lights are free for use, along with vinyl button and lights … on each side, and the left side disc is free to use for scrubbing and searching through track or tracks."

## One timeline (added to spec §4 and §5)
The play-along track and the recorded layers share one timeline starting at 0, with one position, one cue point and one loop.
- **Play / pause** plays the track and the layers together from the position.
- **Cue** (as on a DJ deck): while paused, pressing it sets the cue point at the position; while playing, it jumps back to the cue point and pauses. The cue point starts at 0.
- **Loop:** IN sets the loop's start at the position; OUT sets its end and starts looping; OUT again leaves the loop. A loop shorter than 50 ms is not made.
- **Scrub:** moves the position. If playing, playback carries on from the new place.
- **Tempo:** the track's speed, 0.9…1.1 (±10%), **pitch kept** (`AVAudioUnitTimePitch`), default 1. Stems are always recorded in real time. Once a recording has a layer, the tempo is locked at the speed its first layer was recorded at (`RecordingSession.trackRate`, new, default 1) so the layers always fit the track; the slider then shows a toast "Tempo is locked while the recording has layers".
- **While a pass is recording:** cue, loop and scrub do nothing (a toast says so); Play/Stop ends the pass.
- With Mac sound (BlackHole) as the play-along there is no track to move: the timeline is the layers alone.

## Task 3, added interfaces (same files as the 16 Nov plan, plus `Sources/InStrumAudio/Recording/Transport.swift` and `Tests/InStrumAudioTests/Recording/TransportTests.swift`)
```swift
// Core, add to RecordingSession (decodeIfPresent, default 1): public var trackRate: Double
// Core, new file Sources/InStrumCore/Recording/TransportState.swift (pure, tested in InStrumCoreTests/Recording/TransportStateTests.swift):
public struct TransportState: Equatable, Sendable {
    public var position = 0.0, duration = 0.0, cue = 0.0
    public var loopIn: Double?; public var loopOut: Double?; public var looping = false
    public var playing = false; public var rate = 1.0
    public static let minLoop = 0.05, minRate = 0.9, maxRate = 1.1
    public mutating func pressCue() -> Double?            // paused: sets cue = position, returns nil; playing: playing = false, position = cue, returns cue
    public mutating func pressLoopIn()                    // loopIn = position; clears loopOut and looping
    public mutating func pressLoopOut()                   // not looping: if loopIn != nil and position - loopIn >= minLoop → loopOut = position, looping = true; looping: looping = false
    public mutating func scrub(by seconds: Double)        // clamps to 0…duration
    public mutating func advance(by seconds: Double) -> Bool   // moves position by seconds × rate while playing; wraps to loopIn at loopOut when looping; stops at duration; true when it wrapped or stopped
    public static func rate(fromSlider x: Double) -> Double    // 0…1 → 1.1…0.9 (top of a DJ tempo slider is slower), 0.5 → exactly 1
    public static func jogSeconds(units: Double, fine: Bool) -> Double   // units = eighths of a turn: fine 0.25 s a unit (2 s a turn); search 2 s a unit × min(8, 1 + 6.25 × |units|)
}
// Audio:
extension AudioEngine {
    public func transportPlay(from seconds: Double, rate: Double) -> Int64     // track + layers at one sample time
    public func transportPause() -> Double                                      // the position it stopped at
    public func transportSeek(_ seconds: Double)                                // playing: carries on from there
    public func setTransportLoop(in: Double?, out: Double?)                     // sample-exact wrap by scheduled segments, or within 10 ms
    public var transportPosition: Double { get }                                // timeline seconds (not real seconds) 
    public var transportDuration: Double { get }
    public func setTrackRate(_ rate: Double)                                    // time-pitch on the play-along bus, pitch kept
}
```
Added tests: `testCueSetsWhenPausedAndReturnsWhenPlaying`, `testLoopInOutAndExit`, `testATinyLoopIsRefused`, `testScrubClamps`, `testAdvanceWrapsAtTheLoop`, `testSliderCentreIsExactlyOne`, `testJogIsFineOnTopAndFarOnTheEdge` (Core); `testSeekWhilePlayingCarriesOn`, `testLoopWrapsWithinTenMilliseconds`, `testRateKeepsPitch` (a 1 kHz sine at rate 0.9 is still 1000 ± 3 Hz and lasts 1/0.9 as long ± 20 ms), `testPauseReportsThePosition` (Audio, offline).

## Task 5, changes
- The strip gains: a position bar (click or drag to scrub), a cue marker, loop markers, a tempo read-out ("100%", "96%") with a reset, and the transport buttons Play, Cue, In, Out.
- `AppModel` holds a `TransportState`, ticks it from `transportPosition` every 50 ms while playing, and exposes `transportPlayPause()`, `transportCue()`, `transportLoopIn()`, `transportLoopOut()`, `transportScrub(by:)`, `setTrackTempo(slider:)`, `transportToStart()`.
- The bare Record button of build 248+ stays; with the strip it becomes the same `toggleRecord()`.
- The full app suite can't run: every new app test class goes in the look filter.

## Task 7 (new): the DDJ-ERGO drives the Recorder
**Depends on:** Task 5. **Fetch `main` first:** another session changes the controller files often; rebase onto the newest `main` before starting and again before finishing.
**Files:** modify `Sources/InStrumCore/Controller/DeckActions.swift`, `DeckController.swift` (defaults only), `Sources/InStrumApp/AppModel+Controller.swift`, `Views/ControllerPanel.swift` (only if a menu needs the new section title), their tests `Tests/InStrumCoreTests/Controller/DeckControllerTests.swift` (or wherever the defaults are tested) and `Tests/InStrumAppTests/ControllerTests.swift`.

**New `DeckAction`s** (section "The Recorder" in every button's menu):
`recorderRecord` (Record / stop; overdub when there are layers), `recorderPlay` (play / pause), `recorderCue`, `recorderLoopIn`, `recorderLoopOut`, `recorderToStart`, `recorderUndoLayer` (delete the newest layer), `recorderSaveAndNew` (save the mix, then a new recording), `recorderMutePlayAlong`, `recorderHearInput`.
**New wheel targets:** `recorderScrubFine`, `recorderScrubSearch`. **New knob target:** `trackTempo`.

**Defaults (they replace what these controls did; the old actions stay in the menus):**
| Control | Does | Its light |
|---|---|---|
| Left PLAY | play / pause the track and layers | on while playing |
| Left CUE | cue (set when paused, return when playing) | on while paused at the cue point |
| Left IN | loop in | on when a loop start is set |
| Left OUT | loop out / leave loop | on while looping |
| Left VINYL | back to the start | on at 0:00 |
| Left wheel, top | scrub, fine (2 s a turn) | |
| Left wheel, edge | search (16 s a slow turn, faster when spun) | |
| Left TEMPO slider | the track's tempo, ±10%, pitch kept | |
| Right PLAY | Record / stop (overdub when there are layers) | on while recording, blinking through the count-in |
| Right CUE | delete the newest layer (undo) | on when there is a layer |
| Right IN | play-along heard / muted | on while heard |
| Right OUT | live input heard / muted | on while heard |
| Right VINYL | save the mix and start a new recording | on while there is something unsaved |
The right wheel and right TEMPO slider keep what they do now (time of day; mood motion). The actions these buttons had (hold, all notes off, random weather, time mode, previous/next instrument and world, previous saved sound, set as designed) stay in every button's menu and in the app's own buttons and menus.
A layout he changed by hand keeps his choices, as today.

**Tests:** each default above resolves to its action/target; each action calls the model (stub engine); each light follows its state (`DDJErgoDecoder.light` messages sent on a state change, including the blink at 2 Hz through the count-in); the tempo slider's centre is exactly 100%; scrubbing while recording does nothing and toasts; `Default layout` applies the table; a saved layout from build 247 still decodes.
**Release note must say** which buttons changed, and that everything can be put back in Decks.

## Task 7, added 19 Nov (Michael: the right TEMPO slider "could be how long the day is … not the time of day, that's a different setting")
- **New knob target `dayLength`** ("Day length") in `WorldParam`: quick mode's day length (`SkyClock`'s "one day lasts this many minutes", 2…60). The slider's centre is the designed default; slower (longer day) toward the top as a DJ tempo slider slows a track, on a curve that gives the short days room (geometric between 2 and 60 minutes).
- Moving it switches Time to **Quick** if it was real time or frozen (as the time-of-day knob switches to Frozen), and shows a small message "Day: 12 minutes".
- **Default: the right TEMPO slider is Day length** (it was mood motion, which stays in every knob's menu). The left TEMPO slider is the track's tempo.
- Time of day stays where he put it: the crossfader and the right wheel. Do not move or duplicate it.
- Tests: the slider's ends give 2 and 60 minutes; the centre gives the default; moving it from Frozen switches to Quick; a layout saved in build 247 that had the right TEMPO on mood motion by hand keeps it.
