import XCTest
@testable import InStrumCore

/// Chord names (Song Sheet spec §4, Task S1): reading them, spelling them with sharps or flats, transposing.
final class ChordSpellingTests: XCTestCase {
    func testReadsChordNames() {
        let am = ChordSpelling.parse("Am")
        let fSharpM7 = ChordSpelling.parse("F#m7")
        let bFlatMaj7 = ChordSpelling.parse("Bbmaj7")
        let cOverG = ChordSpelling.parse("C/G")
        let dSus4 = ChordSpelling.parse("Dsus4")
        XCTAssertEqual(am, Chord(root: 9, quality: .minor))
        XCTAssertEqual(fSharpM7, Chord(root: 6, quality: .minor7))
        XCTAssertEqual(bFlatMaj7, Chord(root: 10, quality: .major7))
        XCTAssertEqual(cOverG, Chord(root: 0, quality: .major), "the bass note is dropped")
        XCTAssertEqual(dSus4, Chord(root: 2, quality: .major), "sus comes out as the plain chord")
    }

    func testReadsOtherSpellingsAsTheNearestSimpleChord() {
        let g7 = ChordSpelling.parse("G7")
        let e = ChordSpelling.parse("E")
        let eFlatMinor = ChordSpelling.parse("Ebm")
        let halfDiminished = ChordSpelling.parse("Am7b5")
        let added = ChordSpelling.parse("Cadd9")
        let ninth = ChordSpelling.parse("G9")
        let unicode = ChordSpelling.parse("B♭m7")
        let spaced = ChordSpelling.parse(" A/C# ")
        XCTAssertEqual(g7, Chord(root: 7, quality: .dominant7))
        XCTAssertEqual(e, Chord(root: 4, quality: .major))
        XCTAssertEqual(eFlatMinor, Chord(root: 3, quality: .minor))
        XCTAssertEqual(halfDiminished, Chord(root: 9, quality: .minor7))
        XCTAssertEqual(added, Chord(root: 0, quality: .major))
        XCTAssertEqual(ninth, Chord(root: 7, quality: .dominant7))
        XCTAssertEqual(unicode, Chord(root: 10, quality: .minor7))
        XCTAssertEqual(spaced, Chord(root: 9, quality: .major))
    }

    func testRejectsWords() {
        XCTAssertNil(ChordSpelling.parse("Hello"))
        XCTAssertNil(ChordSpelling.parse("Bed"))
        XCTAssertNil(ChordSpelling.parse("Ebb"))
        XCTAssertNil(ChordSpelling.parse("Gone"))
        XCTAssertNil(ChordSpelling.parse("am"), "a chord's root is a capital")
        XCTAssertNil(ChordSpelling.parse(""))
        XCTAssertNil(ChordSpelling.parse("C/kettle"))
        XCTAssertNil(ChordSpelling.parse("N.C."))
    }

    func testNames() {
        let bFlatMaj7 = Chord(root: 10, quality: .major7)
        XCTAssertEqual(ChordSpelling.name(bFlatMaj7, flats: true), "Bbmaj7")
        XCTAssertEqual(ChordSpelling.name(bFlatMaj7, flats: false), "A#maj7")
        XCTAssertEqual(ChordSpelling.name(Chord(root: 6, quality: .minor7), flats: false), "F#m7")
        XCTAssertEqual(ChordSpelling.name(Chord(root: 9, quality: .minor), flats: true), "Am")
        XCTAssertEqual(ChordSpelling.name(Chord(root: 7, quality: .dominant7), flats: true), "G7")
        XCTAssertEqual(ChordSpelling.name(Chord(root: 0, quality: .major), flats: false), "C")
    }

    func testEveryNameReadsBack() {
        for root in 0..<12 {
            for quality in Chord.Quality.allCases {
                for flats in [false, true] {
                    let chord = Chord(root: root, quality: quality)
                    let name = ChordSpelling.name(chord, flats: flats)
                    let back = ChordSpelling.parse(name)
                    XCTAssertEqual(back, chord, name)
                }
            }
        }
    }

    func testTranspose() {
        let up = ChordSpelling.transposed(Chord(root: 9, quality: .minor), by: 3)
        let down = ChordSpelling.transposed(Chord(root: 2, quality: .dominant7), by: -5)
        let farDown = ChordSpelling.transposed(Chord(root: 0, quality: .major), by: -13)
        XCTAssertEqual(up, Chord(root: 0, quality: .minor))
        XCTAssertEqual(down, Chord(root: 9, quality: .dominant7))
        XCTAssertEqual(farDown, Chord(root: 11, quality: .major))
    }

    func testFlatKeys() {
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: 5, minor: false), "F major")
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: 10, minor: false), "B flat major")
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: 3, minor: false), "E flat major")
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: 2, minor: true), "D minor")
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: 0, minor: true), "C minor")
        XCTAssertFalse(ChordSpelling.prefersFlats(keyRoot: 7, minor: false), "G major")
        XCTAssertFalse(ChordSpelling.prefersFlats(keyRoot: 0, minor: false), "C major")
        XCTAssertFalse(ChordSpelling.prefersFlats(keyRoot: 4, minor: true), "E minor")
        XCTAssertFalse(ChordSpelling.prefersFlats(keyRoot: 9, minor: true), "A minor")
        XCTAssertTrue(ChordSpelling.prefersFlats(keyRoot: -7, minor: false), "a root below 0 counts round: F major")
    }
}
