import XCTest
@testable import InStrumCore

/// LRC lyrics (Song Sheet spec §3, Task S1). Every lyric line here is invented.
final class LRCParserTests: XCTestCase {
    func testLinesWithAndWithoutHundredths() {
        let lrc = """
        [00:12.50] the kettle sings a morning tune
        [01:03] my bicycle bell is rusty again
        [02:07.125]we planted beans beside the shed
        [75:00.5] a very long breakfast indeed
        """
        let lines = LRCParser.parse(lrc)
        guard lines.count == 4 else { return XCTFail("got \(lines.count) lines") }
        XCTAssertEqual(lines[0].time, 12.5, accuracy: 1e-9)
        XCTAssertEqual(lines[0].text, "the kettle sings a morning tune")
        XCTAssertEqual(lines[1].time, 63, accuracy: 1e-9)
        XCTAssertEqual(lines[1].text, "my bicycle bell is rusty again")
        XCTAssertEqual(lines[2].time, 127.125, accuracy: 1e-9)
        XCTAssertEqual(lines[2].text, "we planted beans beside the shed")
        XCTAssertEqual(lines[3].time, 4500.5, accuracy: 1e-9)
        let first = lines[0].words[0]
        XCTAssertEqual(first, LyricWord(text: "the"), "no word timing")
        XCTAssertEqual(lines[0].words.count, 6)
    }

    func testSeveralTimeTagsOnOneLine() {
        let lrc = """
        [00:30.00][01:30.00] oh the porridge is warm
        [00:10.00] the postman parks beside the gate
        """
        let lines = LRCParser.parse(lrc)
        guard lines.count == 3 else { return XCTFail("got \(lines.count) lines") }
        XCTAssertEqual(lines[0].time, 10)
        XCTAssertEqual(lines[0].text, "the postman parks beside the gate")
        XCTAssertEqual(lines[1].time, 30)
        XCTAssertEqual(lines[1].text, "oh the porridge is warm")
        XCTAssertEqual(lines[2].time, 90)
        XCTAssertEqual(lines[2].text, "oh the porridge is warm")
    }

    func testWordTags() throws {
        let lrc = "[00:05.00]<00:05.00>socks <00:05.40>are <00:05.70>drying <00:06.50>slowly <00:07.20>"
        let lines = LRCParser.parse(lrc)
        guard lines.count == 1 else { return XCTFail("got \(lines.count) lines") }
        let words = lines[0].words
        guard words.count == 4 else { return XCTFail("got \(words.count) words: the closing tag is not a word") }
        XCTAssertEqual(lines[0].text, "socks are drying slowly")
        let t0 = try XCTUnwrap(words[0].time)
        let t1 = try XCTUnwrap(words[1].time)
        let t2 = try XCTUnwrap(words[2].time)
        let t3 = try XCTUnwrap(words[3].time)
        XCTAssertEqual(t0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(t1, 5.4, accuracy: 1e-9)
        XCTAssertEqual(t2, 5.7, accuracy: 1e-9)
        XCTAssertEqual(t3, 6.5, accuracy: 1e-9)
    }

    func testWordTagsOnARepeatedLineFollowEachShowing() throws {
        let lines = LRCParser.parse("[00:10.00][00:20.00]<00:10.00>tea <00:10.50>time")
        guard lines.count == 2 else { return XCTFail("got \(lines.count) lines") }
        let later = lines[1].words
        guard later.count == 2 else { return XCTFail("got \(later.count) words") }
        let t0 = try XCTUnwrap(later[0].time)
        let t1 = try XCTUnwrap(later[1].time)
        XCTAssertEqual(t0, 20.0, accuracy: 1e-9)
        XCTAssertEqual(t1, 20.5, accuracy: 1e-9)
    }

    func testEmptyLinesAreGaps() {
        let lrc = """
        [00:01.00] the toaster pops at half past eight
        [00:04.00]
        [00:09.00] ♪
        [00:12.00] grandma knits a scarf for the dog
        """
        let lines = LRCParser.parse(lrc)
        guard lines.count == 4 else { return XCTFail("got \(lines.count) lines") }
        XCTAssertFalse(lines[0].isGap)
        XCTAssertTrue(lines[1].isGap)
        XCTAssertEqual(lines[1].time, 4)
        XCTAssertTrue(lines[2].isGap, "a line of only ♪ is a gap too")
        XCTAssertFalse(lines[3].isGap)
    }

    func testBadLinesAreSkipped() {
        let lrc = """
        [ar:Nobody In Particular]
        [ti:A Song About Breakfast]
        [length: 03:12]
        not a timed line at all
        [00:61.00] seconds out of range
        [ab:cd.ef] letters for numbers
        [00:03.00] the radiator ticks when it warms up

        [00:06.00] the radiator hums when it cools down
        """
        let lines = LRCParser.parse(lrc + "\r\n[00:08.00] a draught under the door\r\n")
        guard lines.count == 3 else { return XCTFail("got \(lines.count) lines") }
        XCTAssertEqual(lines[0].text, "the radiator ticks when it warms up")
        XCTAssertEqual(lines[1].text, "the radiator hums when it cools down")
        XCTAssertEqual(lines[2].text, "a draught under the door")
        XCTAssertEqual(lines[2].time, 8)
    }

    func testPlainLyricsAreUnsynced() {
        let text = """
        the kettle sings a morning tune

          my bicycle bell is rusty again
        """
        let lines = LRCParser.plain(text)
        guard lines.count == 2 else { return XCTFail("got \(lines.count) lines") }
        XCTAssertEqual(lines[0].time, -1)
        XCTAssertEqual(lines[1].time, -1)
        XCTAssertEqual(lines[0].text, "the kettle sings a morning tune")
        XCTAssertEqual(lines[1].text, "my bicycle bell is rusty again")
    }
}
