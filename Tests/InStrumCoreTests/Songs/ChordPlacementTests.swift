import XCTest
@testable import InStrumCore

/// Where a chord sits (Song Sheet spec §5, Task S1). Every lyric line here is invented.
final class ChordPlacementTests: XCTestCase {
    private let c = Chord(root: 0, quality: .major)
    private let d = Chord(root: 2, quality: .major)
    private let f = Chord(root: 5, quality: .major)
    private let g = Chord(root: 7, quality: .major)
    private let am = Chord(root: 9, quality: .minor)

    private func line(_ time: Double, _ text: String) -> LyricLine {
        var words: [LyricWord] = []
        for w in text.split(separator: " ") { words.append(LyricWord(text: String(w))) }
        return LyricLine(time: time, words: words)
    }

    /// my kite is (10 s) · up in the old oak tree (14 s) · ♪ (22 s) · stuck in the tree again (30 s)
    private var song: [LyricLine] {
        [line(10, "my kite is"), line(14, "up in the old oak tree"), LyricLine(time: 22, words: []), line(30, "stuck in the tree again")]
    }

    func testWordTimesFollowTheLettersAcrossTheLinesSpan() {
        // 2 + 4 + 2 letters over 4 s: half a second a letter.
        let short = ChordPlacement.wordTimes(line(10, "my kite is"), nextStart: 14)
        guard short.count == 3 else { return XCTFail("got \(short.count) times") }
        XCTAssertEqual(short[0], 10, accuracy: 1e-9)
        XCTAssertEqual(short[1], 11, accuracy: 1e-9)
        XCTAssertEqual(short[2], 13, accuracy: 1e-9)
        // The next line 30 s away: the span stops at 8 s, a second a letter.
        let capped = ChordPlacement.wordTimes(line(10, "my kite is"), nextStart: 40)
        guard capped.count == 3 else { return XCTFail("got \(capped.count) times") }
        XCTAssertEqual(capped[1], 12, accuracy: 1e-9)
        XCTAssertEqual(capped[2], 16, accuracy: 1e-9)
        let last = ChordPlacement.wordTimes(line(10, "my kite is"), nextStart: nil)
        XCTAssertEqual(last, capped, "the last line's span is 8 s too")
        // Punctuation doesn't count as letters.
        let punctuated = ChordPlacement.wordTimes(line(10, "my, kite! is"), nextStart: 14)
        XCTAssertEqual(punctuated, short)
    }

    func testWordTimingIsUsedWhereTheLyricsHaveIt() {
        let timed = LyricLine(time: 5, words: [LyricWord(text: "socks", time: 5.2), LyricWord(text: "are", time: 5.9),
                                               LyricWord(text: "drying", time: 7.5)])
        let times = ChordPlacement.wordTimes(timed, nextStart: 9)
        let expected: [Double] = [5.2, 5.9, 7.5]
        XCTAssertEqual(times, expected)
        let gap = ChordPlacement.wordTimes(LyricLine(time: 5, words: []), nextStart: 9)
        XCTAssertEqual(gap, [])
        let unsynced = ChordPlacement.wordTimes(line(-1, "tea and toast"), nextStart: nil)
        XCTAssertEqual(unsynced, [-1, -1, -1])
    }

    func testChordsSitOverTheWordBeingSung() {
        let placed = ChordPlacement.place([ChordEvent(time: 12.5, chord: c), ChordEvent(time: 10, chord: am),
                                           ChordEvent(time: 16, chord: g)], on: song)
        guard placed.count == 4 else { return XCTFail("one list a line: got \(placed.count)") }
        let first = [PlacedChord(chord: am, wordIndex: 0, time: 10), PlacedChord(chord: c, wordIndex: 1, time: 12.5)]
        let second = [PlacedChord(chord: g, wordIndex: 2, time: 16)]
        XCTAssertEqual(placed[0], first, "in time order: Am over \"my\", C over \"kite\"")
        XCTAssertEqual(placed[1], second, "G over \"the\"")
        XCTAssertEqual(placed[2], [])
        XCTAssertEqual(placed[3], [])
    }

    func testAChordInAGapGoesToTheEndOfTheLineBeforeOrTheStartOfTheNext() {
        let placed = ChordPlacement.place([ChordEvent(time: 25, chord: c), ChordEvent(time: 29.5, chord: f),
                                           ChordEvent(time: 29.8, chord: am), ChordEvent(time: 13.8, chord: d)], on: song)
        guard placed.count == 4 else { return XCTFail("one list a line: got \(placed.count)") }
        let second = [PlacedChord(chord: d, wordIndex: 0, time: 13.8), PlacedChord(chord: c, wordIndex: 5, time: 25),
                      PlacedChord(chord: f, wordIndex: 5, time: 29.5)]
        let fourth = [PlacedChord(chord: am, wordIndex: 0, time: 29.8)]
        XCTAssertEqual(placed[1], second, "0.2 s early goes on the next line; in the ♪ gap, on the end of the line before")
        XCTAssertEqual(placed[2], [], "nothing sits on the ♪")
        XCTAssertEqual(placed[3], fourth, "within 0.3 s of the next line: its first word")
    }

    func testChordsBeforeTheFirstLineAreNotPlacedAndChordsOnOneWordAreAllKept() {
        let placed = ChordPlacement.place([ChordEvent(time: 2, chord: g), ChordEvent(time: 9.8, chord: f),
                                           ChordEvent(time: 31.1, chord: g), ChordEvent(time: 31, chord: d)], on: song)
        guard placed.count == 4 else { return XCTFail("one list a line: got \(placed.count)") }
        let first = [PlacedChord(chord: f, wordIndex: 0, time: 9.8)]
        let fourth = [PlacedChord(chord: d, wordIndex: 0, time: 31), PlacedChord(chord: g, wordIndex: 0, time: 31.1)]
        XCTAssertEqual(placed[0], first, "the intro's chord at 2 s has no line; 9.8 s is the first line's")
        XCTAssertEqual(placed[3], fourth, "both on \"stuck\", in time order: the panel moves the later one right")
        let unsynced = ChordPlacement.place([ChordEvent(time: 3, chord: c)], on: LRCParser.plain("tea and toast"))
        XCTAssertEqual(unsynced, [[]])
    }

    func testCurrentLine() {
        let lines = song
        XCTAssertNil(ChordPlacement.currentLine(lines, at: 9.9), "before the first line")
        XCTAssertEqual(ChordPlacement.currentLine(lines, at: 10), 0)
        XCTAssertEqual(ChordPlacement.currentLine(lines, at: 13.9), 0)
        XCTAssertEqual(ChordPlacement.currentLine(lines, at: 14), 1)
        XCTAssertEqual(ChordPlacement.currentLine(lines, at: 25), 2, "the ♪")
        XCTAssertEqual(ChordPlacement.currentLine(lines, at: 300), 3)
        XCTAssertNil(ChordPlacement.currentLine(LRCParser.plain("tea and toast"), at: 5), "unsynced")
        XCTAssertNil(ChordPlacement.currentLine([], at: 5))
    }

    func testCurrentWord() {
        let kite = line(10, "my kite is")
        XCTAssertNil(ChordPlacement.currentWord(kite, nextStart: 14, at: 9.9))
        XCTAssertEqual(ChordPlacement.currentWord(kite, nextStart: 14, at: 10), 0)
        XCTAssertEqual(ChordPlacement.currentWord(kite, nextStart: 14, at: 11.5), 1)
        XCTAssertEqual(ChordPlacement.currentWord(kite, nextStart: 14, at: 13.5), 2)
        XCTAssertEqual(ChordPlacement.currentWord(kite, nextStart: 40, at: 17.9), 2)
        XCTAssertNil(ChordPlacement.currentWord(kite, nextStart: 40, at: 18.5), "past its 8 s, in a gap")
        XCTAssertNil(ChordPlacement.currentWord(LyricLine(time: 10, words: []), nextStart: 14, at: 11))
    }
}
