import XCTest
@testable import InStrumCore

/// Matching a pasted chord sheet to the synced lyrics (Song Sheet spec §4, Task S1). Every lyric line here is invented.
final class ChordSheetAlignerTests: XCTestCase {
    private let c = Chord(root: 0, quality: .major)
    private let f = Chord(root: 5, quality: .major)
    private let g = Chord(root: 7, quality: .major)
    private let a = Chord(root: 9, quality: .major)
    private let em = Chord(root: 4, quality: .minor)
    private let am = Chord(root: 9, quality: .minor)

    private func line(_ time: Double, _ text: String) -> LyricLine {
        var words: [LyricWord] = []
        for w in text.split(separator: " ") { words.append(LyricWord(text: String(w))) }
        return LyricLine(time: time, words: words)
    }

    func testAChorusWrittenOnceIsMatchedEachTimeItIsSung() {
        let lyrics = [
            line(10, "my bicycle bell is rusty again"),
            line(14, "the chain goes clank on every hill"),
            line(18, "pedal to the bakery before the buns run out"),
            line(22, "the baker counts the buns in twos and threes"),
            line(26, "the baker waves a floury hand"),
            line(30, "and gives the dog a crust of bread"),
            line(34, "pedal to the bakery before the buns run out"),
            line(38, "the baker counts the buns in twos and threes"),
            LyricLine(time: 42, words: []),
            line(50, "pedal to the bakery before the buns run out"),
            line(54, "the baker counts the buns in twos and threes"),
        ]
        let sheet = ChordSheetParser.parse("""
        G           D
        my bicycle bell is rusty again
        Em              C
        the chain goes clank on every hill

        [Chorus]
        A         E
        pedal to the bakery before the buns run out
        Bm              E
        the baker counts the buns in twos and threes
        """)
        let result = ChordSheetAligner.align(sheet, to: lyrics)
        XCTAssertEqual(result.unmatched, [])
        XCTAssertEqual(result.chords.count, 16, "2 chords on each verse line, and on each chorus line three times")
        let aTimes = result.chords.filter { $0.chord == a }.map(\.time)
        XCTAssertEqual(aTimes, [18, 34, 50], "the chorus's first chord, each time it is sung")
        let firstLine = ChordPlacement.wordTimes(lyrics[0], nextStart: 14)
        let d = Chord(root: 2, quality: .major)
        let dTimes = result.chords.filter { $0.chord == d }.map(\.time)
        XCTAssertEqual(dTimes, [firstLine[2]], "D over \"bell\"")
        let verseTwo = result.chords.filter { $0.time >= 26 && $0.time < 34 }
        XCTAssertEqual(verseTwo.count, 0, "lines the sheet doesn't have get no chords")
    }

    func testPunctuationAndCaseDontMatterAndUnmatchedLinesAreListed() {
        let lyrics = [
            line(5, "the kettle sings a morning tune"),
            line(9, "the toaster pops at half past eight"),
            line(13, "socks are drying on the radiator"),
        ]
        let sheet = [
            SheetLine(text: "The Kettle, sings a Morning tune!", chords: [(chord: am, wordIndex: 0)]),
            SheetLine(text: "a line from some other version entirely", chords: [(chord: g, wordIndex: 0)]),
            SheetLine(text: "oh the toaster pops at half past eight", chords: [(chord: f, wordIndex: 3)]),
            SheetLine(text: "Socks are drying on the radiator"),
        ]
        let result = ChordSheetAligner.align(sheet, to: lyrics)
        XCTAssertEqual(result.unmatched, [1])
        guard result.chords.count == 2 else { return XCTFail("got \(result.chords.count) chords") }
        let kettle = ChordEvent(time: 5, chord: am)
        XCTAssertEqual(result.chords[0], kettle)
        // "pops" is the sheet's fourth word but the lyric's third: it goes by the words, not the count.
        let toasterTimes = ChordPlacement.wordTimes(lyrics[1], nextStart: 13)
        let pops = ChordEvent(time: toasterTimes[2], chord: f)
        XCTAssertEqual(result.chords[1], pops)
    }

    func testMatchesKeepTheSheetsOrder() {
        // Each sheet line is alike enough to both lyric lines; in order, each gets its own.
        let lyrics = [line(10, "the hen sat on the warm step"), line(20, "the hen sat on the cold step")]
        let sheet = [
            SheetLine(text: "the hen sat on the warm step", chords: [(chord: c, wordIndex: 0)]),
            SheetLine(text: "the hen sat on the cold step", chords: [(chord: f, wordIndex: 0)]),
        ]
        let result = ChordSheetAligner.align(sheet, to: lyrics)
        let expected = [ChordEvent(time: 10, chord: c), ChordEvent(time: 20, chord: f)]
        XCTAssertEqual(result.chords, expected)
        XCTAssertEqual(result.unmatched, [])
    }

    func testChordsOnTheSameWordKeepTheLastWritten() {
        // A turnaround attached to the line's first word, under the line's own first chord: the line's own is sung there.
        let lyrics = [line(10, "a paper boat drifts across the pond")]
        let sheet = [SheetLine(text: "a paper boat drifts across the pond",
                               chords: [(chord: em, wordIndex: 0), (chord: c, wordIndex: 0), (chord: g, wordIndex: 3)])]
        let result = ChordSheetAligner.align(sheet, to: lyrics)
        let times = ChordPlacement.wordTimes(lyrics[0], nextStart: nil)
        let expected = [ChordEvent(time: 10, chord: c), ChordEvent(time: times[3], chord: g)]
        XCTAssertEqual(result.chords, expected)
    }

    func testUnsyncedLyricsMatchButGiveNoChords() {
        let lyrics = LRCParser.plain("the kettle sings a morning tune")
        let sheet = [SheetLine(text: "the kettle sings a morning tune", chords: [(chord: am, wordIndex: 1)])]
        let result = ChordSheetAligner.align(sheet, to: lyrics)
        XCTAssertEqual(result.chords, [])
        XCTAssertEqual(result.unmatched, [])
    }

    func testNothingToMatch() {
        let empty = ChordSheetAligner.align([], to: [])
        XCTAssertEqual(empty.chords, [])
        XCTAssertEqual(empty.unmatched, [])
        let sheet = [SheetLine(text: "the kettle sings a morning tune", chords: [(chord: am, wordIndex: 1)])]
        let noLyrics = ChordSheetAligner.align(sheet, to: [])
        XCTAssertEqual(noLyrics.chords, [])
        XCTAssertEqual(noLyrics.unmatched, [0])
    }
}
