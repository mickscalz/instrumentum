# Song Sheet: synced lyrics with chords above the words — Design and Plan

**Date:** 2026-11-19. **Branch:** `lyrics` (off `main` at build 252). **Status:** written to Michael's standing instruction to keep going without questions; §8 lists the choices made without asking.

**What Michael asked for (19 Nov):** "Add lyric syncing to the music playing through my Spotify, and chord letters above the word where the chord is. Look up from anywhere, and an analyse-audio option too. Like Chordify is fine, but letters on top of the word instead of the Chordify layout." He then asked for it to go ahead of the rest of the Recorder.

## 1. What he gets
A **Song Sheet** panel (a button in the top bar, ⌘L) that follows whatever Spotify is playing:
- the song's title and artist, found by itself;
- its lyrics, scrolling in time, the current line bright;
- the chord letters **above the word they land on**;
- chords from one of three places: **Listen** (the app works them out from the sound), **Paste a chord sheet** (copied from anywhere), or **his own fixes**, which the app remembers for that song.

```
 Song Sheet                      Title — Artist            Chords: [Listen ▾]   ♭/♯   Sync −  +
 ──────────────────────────────────────────────────────────────────────────────────────────────
        Am                 F
   an earlier line of the song, dimmed
   C              G                Am
   THE LINE BEING SUNG NOW, bright, the word being sung underlined
        F                  C
   the next line, dimmed
```
(The lines above are placeholders. No real lyrics appear in this document, in code, in tests or in chat.)

## 2. Following Spotify
- **First choice, no setup:** ask the Spotify desktop app by AppleScript every second: track id, name, artist, album, duration (ms), player position (s), player state. macOS asks once for permission to control Spotify (`NSAppleEventsUsageDescription`).
- **The position between asks** runs on the Mac's clock from the last answer; a jump of more than 1.5 s (a seek, a new song) re-anchors it.
- **Fallback, if the position sticks** (two answers 2 s apart with the same position while the state says playing) or Spotify isn't scriptable: Spotify's Web API with his app (Client ID `373573bfddb24fd290b6aeea588df437`, redirect `http://127.0.0.1:8898/callback`, scopes `user-read-currently-playing user-read-playback-state`, Authorization Code with PKCE, no secret). A one-time "Connect Spotify" button opens the browser; a tiny local listener on port 8898 receives the code; tokens live in the Keychain and refresh by themselves. `GET https://api.spotify.com/v1/me/player/currently-playing` every 2 s gives `progress_ms`, `timestamp`, `is_playing`, `item.id/name/duration_ms`, `item.artists[].name`, `item.album.name`.
- Nothing is sent anywhere except the lyric lookup (title, artist, album, duration) and Spotify's own API.

## 3. Lyrics
- **Source:** LRCLIB, no key. `GET https://lrclib.net/api/get?track_name=&artist_name=&album_name=&duration=<seconds>` (header `User-Agent: In Strum Meants (personal)`); on 404, `GET https://lrclib.net/api/search?track_name=&artist_name=` and take the result whose duration is within 3 s (closest first), preferring one with `syncedLyrics`. JSON fields: `id`, `trackName`, `artistName`, `albumName`, `duration`, `instrumental`, `plainLyrics`, `syncedLyrics`.
- **Format:** LRC lines `[mm:ss.xx] text`; word timing where present as `<mm:ss.xx>` tags inside a line. Lines with no words (instrumental gaps) show "♪".
- **No synced lyrics:** show the plain lyrics unsynced, with a **Tap to sync** mode (press ↓ at the start of each line while the song plays; saved for that song). **Nothing found:** the panel says so, and chords still show on a bare timeline (bars of chord letters).
- **Kept on his Mac:** fetched lyrics are cached per song in `~/Library/Application Support/In Strum Meants/Songs/<spotify id>.json` with his sync offset, his tapped timings, the chords and his fixes. Community-sourced, for his own use; nothing is bundled or shared.
- **Sync nudge:** − / + move the lyrics 0.1 s earlier or later for this song (−5…+5 s), remembered.

## 4. Chords
- **Listen (analyse the audio).** The app hears Spotify through the Recorder's play-along capture (BlackHole; Recorder Task 4). Until that ships, or without BlackHole, Listen is greyed with one line saying why, and Paste works.
  - Method: 12-bin chroma from a constant-Q-style transform (4096-sample frames, hop 2048, 55 Hz–2 kHz, tuned to the track's own reference found in its first 20 s), smoothed over half a second, matched to templates for major, minor, 7, maj7, m7 on all twelve roots plus "no chord", then a Viterbi pass that makes changes cost something so chords don't flicker. Chords shorter than 0.4 s are dropped.
  - It learns the song as it plays and keeps what it found, so the second listen shows chords ahead of time. The first time through, chords appear as they are heard (a moment late).
  - Honest limits: plain triads and sevenths; slash chords, sus and extended chords come out as their nearest simple chord; dense or distorted mixes are wrong more often.
- **Paste a chord sheet.** Paste text copied from anywhere: "chords over lyrics" (a line of chord names above each lyric line) or ChordPro (`[Am]` inside the words). The app matches each pasted lyric line to the synced lyrics by its words (ignoring case and punctuation; best match in order), and puts each chord on the word its column or bracket sits over. Unmatched lines are listed so he can see what didn't fit.
- **His fixes.** Click a chord to change it (a small menu: root, quality, or remove); click a word to add one. Fixes override Listen and Paste for that song, and are kept.
- **Spelling:** a ♭/♯ switch; the default follows the song's key estimate (flats in flat keys).
- **Transpose follows the app:** when the instrument's Transpose is +n (the capo read-out), the sheet can show chords as played (down n) with a "Capo n" note; a toggle, off by default.

## 5. Where a chord sits
- Each chord has a time. With word timing, it sits over the word being sung at that time. With line timing only, the words of a line are spread across the line's span (to the next line's start, at most 8 s) in proportion to their length in letters, and the chord sits over the word at its time.
- A chord that falls in a gap between lines sits at the end of the earlier line, or at the start of the next if it is within 0.3 s of it.
- Chords never overlap: if two would collide, the later one moves right until it clears, and the words below spread to keep each chord over its word.

## 6. Architecture
- **Core (`Sources/InStrumCore/Songs/`, pure Swift):** `SongTypes.swift` (shared types, already committed), `LRCParser`, `ChordSheetParser`, `ChordSheetAligner`, `ChordPlacement` (§5), `ChordSpelling` (names, ♭/♯, transpose), `SongStore` (the per-song JSON), `PlaybackClock` (§2's position between asks and the stuck-position test).
- **Audio (`Sources/InStrumAudio/Songs/`):** `ChordRecognizer` (Accelerate; fed mono buffers; pure of AVAudioEngine so it is tested on synthesised chords).
- **App (`Sources/InStrumApp/Songs/`):** `SpotifyDesktop` (AppleScript), `SpotifyWeb` (PKCE, Keychain, the port-8898 listener), `LRCLIBClient`, `AppModel+SongSheet.swift`, `Views/SongSheet/` (`SongSheetButton`, `SongSheetPanel`, `ChordLine`, `ChordMenu`, `PasteChordsSheet`), `Packaging/Info.plist` (`NSAppleEventsUsageDescription`: "In Strum Meants asks Spotify which song is playing and where it is up to, to show its lyrics and chords.").
- **Cost:** one AppleScript call a second, one small web request per song, and the recogniser at about 12 frames a second on one mono stream: well under one percent of a core. The panel is plain SwiftUI text; it doesn't touch the renderer.

## 7. The plan
> Agents: one task each, own worktree and branch off `lyrics`, no websites, Opus on Extra. Check through a `.github/look-filter` with your test classes (the `looks` job; `test (InStrumAppTests)` loses its runner on every branch, ignore it), read with `gh api` REST only, and remove the filter in your last commit. Test assertions are simple statements over named locals. **No real song lyrics anywhere: tests use invented lines.**

**Global constraints:** macOS 13, Intel, Swift 5.10, no new packages. Core stays Foundation-only. Network and AppleScript sit behind protocols so tests never touch them. Older settings and song files load (`decodeIfPresent`). Nothing is written to disk until a song's lyrics are fetched or a chord is found or edited. Don't touch the renderers, DSP engines, the GPU safety net, or the Recorder's files.

**Review focus:** (1) a song with no lyrics found, (2) Spotify paused, closed, or playing a podcast or local file (no id), (3) seeking and skipping, (4) a pasted sheet for a different version of the song (few lines match), (5) no network.

### Task S1: Core — parsing, alignment, placement, the song store, the clock
Files: create `Sources/InStrumCore/Songs/LRCParser.swift`, `ChordSheetParser.swift`, `ChordSheetAligner.swift`, `ChordPlacement.swift`, `ChordSpelling.swift`, `SongStore.swift`, `PlaybackClock.swift`; tests under `Tests/InStrumCoreTests/Songs/` (one file per source file). Uses the types in `SongTypes.swift` (do not change their stored properties; add methods in extensions).
```swift
public enum LRCParser { public static func parse(_ lrc: String) -> [LyricLine]; public static func plain(_ text: String) -> [LyricLine] /* time -1 */ }
public enum ChordSheetParser { public static func parse(_ text: String) -> [SheetLine] }   // chords-over-lyrics and ChordPro; section labels ("[Chorus]", "Verse 1:") skipped
public struct SheetLine: Equatable, Sendable { public var text: String; public var chords: [(chord: Chord, wordIndex: Int)] }   // Equatable written by hand
public enum ChordSheetAligner { public static func align(_ sheet: [SheetLine], to lines: [LyricLine]) -> (chords: [ChordEvent], unmatched: [Int]) }   // word-set similarity ≥ 0.6, in order; a repeated chorus matches each time it is sung
public enum ChordPlacement {
    public static func wordTimes(_ line: LyricLine, nextStart: Double?) -> [Double]        // §5; span capped at 8 s
    public static func place(_ chords: [ChordEvent], on lines: [LyricLine]) -> [[PlacedChord]]   // per line
    public static func currentLine(_ lines: [LyricLine], at t: Double) -> Int?
    public static func currentWord(_ line: LyricLine, nextStart: Double?, at t: Double) -> Int?
}
public struct PlacedChord: Equatable, Sendable { public var chord: Chord; public var wordIndex: Int; public var time: Double }
public enum ChordSpelling { public static func name(_ c: Chord, flats: Bool) -> String; public static func parse(_ s: String) -> Chord?; public static func transposed(_ c: Chord, by semitones: Int) -> Chord; public static func prefersFlats(keyRoot: Int, minor: Bool) -> Bool }
public struct SongStore { public init(directory: URL); public static var defaultDirectory: URL; public func load(_ id: String) -> SongFile?; public func save(_ file: SongFile) throws; public static func fileName(for id: String) -> String }
public struct PlaybackClock { public init(); public mutating func report(position: Double, playing: Bool, at now: Double); public func position(at now: Double) -> Double; public var looksStuck: Bool { get } }
```
Tests (invented lines only): LRC with and without hundredths, multiple time tags on one line, word tags, empty lines → "♪", bad lines skipped; chords-over-lyrics columns map to the right word (including a chord past the end of the line → last word, and a chord-only line → attached to the next lyric line's first word); ChordPro; section labels skipped; `ChordSpelling.parse` accepts `Am`, `F#m7`, `Bbmaj7`, `C/G` (→ C), `Dsus4` (→ D), rejects `Hello`; the aligner matches a chorus sung three times, tolerates punctuation and case, reports unmatched lines; word times proportional to letters and capped at 8 s; a gap chord goes to the end of the earlier line, or the next line's start within 0.3 s; `currentLine` before the first line is nil; the store round-trips, tolerates an old file, names files safely for ids with odd characters, and writes nothing until `save`; the clock runs between reports, re-anchors on a 1.5 s jump, stops when paused, and `looksStuck` after two equal positions 2 s apart while playing.
Commit: `feat(core): song sheets: LRC and chord-sheet parsing, alignment, chord placement, the song store and the playback clock`.

### Task S2: Audio — the chord recogniser
Files: create `Sources/InStrumAudio/Songs/ChordRecognizer.swift`; tests `Tests/InStrumAudioTests/Songs/ChordRecognizerTests.swift`.
```swift
public final class ChordRecognizer {
    public init(sampleRate: Double)
    public func reset()
    /// Any thread but one at a time; mono samples in song order starting at `time` seconds. Not for a render block: call it from a tap or a queue.
    public func feed(_ samples: UnsafePointer<Float>, count: Int, at time: Double)
    public func chords(upTo time: Double) -> [ChordEvent]      // settled chords (Viterbi with a 2 s look-back), ≥ 0.4 s each
    public var tuningCents: Double { get }                      // found in the first 20 s
    public var keyEstimate: (root: Int, minor: Bool)? { get }
}
```
Method as §4. Tests synthesise audio (sums of sines with a few harmonics and a decaying envelope, plus low-level noise): C–G–Am–F at two seconds each is named right with boundaries within 0.3 s; a song tuned 30 cents flat is still right and `tuningCents` is −30 ± 8; C7 vs C vs Cmaj7 vs Cm7 are told apart; silence and noise give no chord; a bass note alone doesn't flip C to Am; feeding in 512-sample pieces equals feeding in one piece; a jump back in `time` (a seek) keeps what was learned for other parts of the song; ten minutes of audio feeds in under 5 s on the CI machine; no allocation after `init` in `feed` (preallocated buffers).
Commit: `feat(audio): a chord recogniser for the Song Sheet`.

### Task S3: App — Spotify, lyrics lookup, the panel (after S1 and S2)
Files: as §6 App, plus tests `Tests/InStrumAppTests/SongSheetTests.swift`, `SpotifyTests.swift`, `LRCLIBClientTests.swift` (stubs for AppleScript, the web and the clock). Hooks the recogniser to the Recorder's play-along capture when that exists on `main` (behind `SongSheetFeatures.listen`, off until then).
Tests: a new track id fetches once and caches; 404 falls back to search and picks the closest duration; no network shows the cached song or "No lyrics found"; a podcast or local file shows "Nothing to show for this"; the current line and word follow the clock; nudge is remembered per song; paste aligns and lists unmatched lines; an edit overrides and survives a relaunch; ♭/♯ and capo display; the stuck-position rule switches to the Web API when connected and shows "Connect Spotify" when not; PKCE values (verifier length 64, S256 challenge, state checked); ⌘L.
Commit: `feat(app): the Song Sheet: synced lyrics with chords above the words`.

### Task S4: review, release notes, merge to `main` (main session).

## 8. Choices made without asking
| Choice | Instead of | Cost to change |
|---|---|---|
| A side panel in the app, ⌘L | a separate window or an overlay on the world | small |
| AppleScript first, his Spotify app as the fallback | the Web API only | none; both are built |
| LRCLIB for lyrics | a licensed, paid lyrics API (Musixmatch) | small: one more client |
| Chords: listen, paste, and his own fixes | fetching chords from chord sites (no proper source; not scraping) | — |
| Triads and sevenths only when listening | a larger chord vocabulary | medium |
| Chords shown as heard on the first listen, ahead of time from the second | analysing the whole song before it plays (not possible with a stream) | — |
| Lyrics and chords cached per song on his Mac | fetching every time | trivial |
