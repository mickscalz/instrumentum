import XCTest
@testable import InStrumCore

/// Pasted chord sheets (Song Sheet spec §4, Task S1): chords over lyrics and ChordPro. Every lyric line here is invented.
final class ChordSheetParserTests: XCTestCase {
    private let c = Chord(root: 0, quality: .major)
    private let d = Chord(root: 2, quality: .major)
    private let dm = Chord(root: 2, quality: .minor)
    private let em = Chord(root: 4, quality: .minor)
    private let f = Chord(root: 5, quality: .major)
    private let g = Chord(root: 7, quality: .major)
    private let am = Chord(root: 9, quality: .minor)

    func testChordColumnsMapToTheWordsUnderThem() {
        let sheet = """
        C        G           Am
        we planted beans beside the shed
        """
        let lines = ChordSheetParser.parse(sheet)
        guard lines.count == 1 else { return XCTFail("got \(lines.count) lines") }
        let expected = SheetLine(text: "we planted beans beside the shed",
                                 chords: [(chord: c, wordIndex: 0), (chord: g, wordIndex: 1), (chord: am, wordIndex: 3)])
        XCTAssertEqual(lines[0], expected)
    }

    func testAChordPastTheEndOfTheLineGoesOnTheLastWord() {
        let sheet = """
        G                          D          Em
        the postman parks his van
        """
        let lines = ChordSheetParser.parse(sheet)
        guard lines.count == 1 else { return XCTFail("got \(lines.count) lines") }
        let expected = SheetLine(text: "the postman parks his van",
                                 chords: [(chord: g, wordIndex: 0), (chord: d, wordIndex: 4), (chord: em, wordIndex: 4)])
        XCTAssertEqual(lines[0], expected)
    }

    func testAChordOnlyLineGoesOnTheNextLyricLinesFirstWord() {
        let sheet = """
        [Intro]
        Em        D
        [Verse 1]
        grandma knits a scarf for the dog
        Am
        C              G
        a paper boat drifts across the pond
        Intro: F  C

        toast and marmalade again
        """
        let lines = ChordSheetParser.parse(sheet)
        guard lines.count == 3 else { return XCTFail("got \(lines.count) lines") }
        let first = SheetLine(text: "grandma knits a scarf for the dog", chords: [(chord: em, wordIndex: 0), (chord: d, wordIndex: 0)])
        let second = SheetLine(text: "a paper boat drifts across the pond",
                               chords: [(chord: am, wordIndex: 0), (chord: c, wordIndex: 0), (chord: g, wordIndex: 3)])
        let third = SheetLine(text: "toast and marmalade again", chords: [(chord: f, wordIndex: 0), (chord: c, wordIndex: 0)])
        XCTAssertEqual(lines[0], first)
        XCTAssertEqual(lines[1], second, "a chord line over another chord line has nothing under it")
        XCTAssertEqual(lines[2], third, "\"Intro:\" goes and its chords stay")
    }

    func testChordPro() {
        let sheet = """
        {title: A Song About Breakfast}
        [Am]the kettle [F]sings a [C]morning tune [G]
        {c: Chorus}
        oh the [Dm]porridge is warm
        toast and mar[D]malade
        [Em] [Am]
        """
        let lines = ChordSheetParser.parse(sheet)
        guard lines.count == 3 else { return XCTFail("got \(lines.count) lines") }
        let first = SheetLine(text: "the kettle sings a morning tune",
                              chords: [(chord: am, wordIndex: 0), (chord: f, wordIndex: 2), (chord: c, wordIndex: 4), (chord: g, wordIndex: 5)])
        let second = SheetLine(text: "oh the porridge is warm", chords: [(chord: dm, wordIndex: 2)])
        let third = SheetLine(text: "toast and marmalade", chords: [(chord: d, wordIndex: 2)])
        XCTAssertEqual(lines[0], first)
        XCTAssertEqual(lines[1], second)
        XCTAssertEqual(lines[2], third, "a chord inside a word goes on that word")
    }

    func testHeadingsAreSkipped() {
        let sheet = """
        [Chorus]
        Verse 1:
        (Bridge)
        Capo 2
        Tuning: standard
        Key: G
        Chorus x2
        (x2)
        | N.C. | % |
        C           G
        socks are drying on the radiator
        Chorus: the cat sleeps on the warm towel
        Key to the garden shed is under the pot
        """
        let lines = ChordSheetParser.parse(sheet)
        guard lines.count == 3 else { return XCTFail("got \(lines.count) lines") }
        let first = SheetLine(text: "socks are drying on the radiator", chords: [(chord: c, wordIndex: 0), (chord: g, wordIndex: 2)])
        let second = SheetLine(text: "the cat sleeps on the warm towel")
        let third = SheetLine(text: "Key to the garden shed is under the pot")
        XCTAssertEqual(lines[0], first)
        XCTAssertEqual(lines[1], second, "a heading before words keeps the words")
        XCTAssertEqual(lines[2], third, "a lyric that starts with a header word is still a lyric")
    }

    func testSheetLinesCompareTheirChords() {
        let one = SheetLine(text: "jam on the toast", chords: [(chord: c, wordIndex: 1)])
        let same = SheetLine(text: "jam on the toast", chords: [(chord: c, wordIndex: 1)])
        let otherWord = SheetLine(text: "jam on the toast", chords: [(chord: c, wordIndex: 2)])
        let otherChord = SheetLine(text: "jam on the toast", chords: [(chord: g, wordIndex: 1)])
        let none = SheetLine(text: "jam on the toast")
        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, otherWord)
        XCTAssertNotEqual(one, otherChord)
        XCTAssertNotEqual(one, none)
    }
}
