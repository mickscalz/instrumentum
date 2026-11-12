import XCTest
@testable import InStrumCore

/// A kept take as a Standard MIDI File (Small Wins spec §2, Task 1): type 0, 480 ticks a quarter, the set's tempo, the
/// set's name, and times exact to within half a tick.
final class StandardMIDIFileTests: XCTestCase {
    private func bytes(_ data: Data) -> [UInt8] { [UInt8](data) }

    /// Where `needle` first occurs in `haystack`, or nil.
    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    func testHeaderAndTrack() {
        let take = Take(events: [TakeEvent(time: 0, message: .noteOn(channel: 0, note: 60, velocity: 100)),
                                 TakeEvent(time: 0.5, message: .noteOff(channel: 0, note: 60))], duration: 2.5)
        let file = bytes(StandardMIDIFile.write(take, name: "Moonlit Lake", bpm: 120))
        XCTAssertEqual(Array(file.prefix(14)), [0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xE0],
                       "MThd, 6 bytes: type 0, one track, 480 ticks a quarter")
        XCTAssertEqual(Array(file[14..<18]), [0x4D, 0x54, 0x72, 0x6B], "MTrk")
        let length = file[18..<22].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(length, file.count - 22, "the track's length is the rest")
        let name = Array("Moonlit Lake".utf8)
        var opening: [UInt8] = [0x00, 0xFF, 0x03, UInt8(name.count)]
        opening.append(contentsOf: name)
        opening.append(contentsOf: [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20] as [UInt8])
        XCTAssertEqual(Array(file[22..<(22 + opening.count)]), opening, "the name, then 120 BPM (500,000 µs)")
        var rest = Array(file[(22 + opening.count)...])
        XCTAssertEqual(Array(rest.suffix(3)), [0xFF, 0x2F, 0x00], "it closes")
        // The notes, each with its own status byte: C4 at 0, its note-off 480 ticks (0.5 s) later, the end at 2400 (2.5 s).
        rest.removeLast(3)
        XCTAssertEqual(rest, [0x00, 0x90, 60, 100, 0x83, 0x60, 0x80, 60, 64, 0x8F, 0x00])
    }

    func testVariableLengthQuantities() {
        XCTAssertEqual(StandardMIDIFile.vlq(0), [0x00])
        XCTAssertEqual(StandardMIDIFile.vlq(127), [0x7F])
        XCTAssertEqual(StandardMIDIFile.vlq(128), [0x81, 0x00])
        XCTAssertEqual(StandardMIDIFile.vlq(8192), [0xC0, 0x00])
        XCTAssertEqual(StandardMIDIFile.vlq(0x0FFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertEqual(StandardMIDIFile.vlq(0xFFFF_FFFF), [0xFF, 0xFF, 0xFF, 0x7F], "the largest a file can say")
    }

    func testTempoMeta() {
        let take = Take(events: [], duration: 1)
        let cases: [(bpm: Double, tempo: [UInt8])] = [(84, [0x0A, 0xE6, 0x2E]), (68, [0x0D, 0x76, 0xB1]), (120, [0x07, 0xA1, 0x20])]
        for (bpm, tempo) in cases {
            let file = bytes(StandardMIDIFile.write(take, name: "T", bpm: bpm))
            XCTAssertNotNil(find([0x00, 0xFF, 0x51, 0x03] + tempo, in: file), "\(bpm) BPM")
            XCTAssertEqual(StandardMIDIFile.read(Data(file))?.bpm ?? 0, bpm, accuracy: 1e-4)
        }
        XCTAssertEqual(StandardMIDIFile.microseconds(bpm: 84), 714_286)
        XCTAssertEqual(StandardMIDIFile.microseconds(bpm: 68), 882_353)
        XCTAssertEqual(StandardMIDIFile.microseconds(bpm: 0), 500_000, "a tempo that can't be is 120")
    }

    func testEveryKindRoundTrips() throws {
        let c: UInt8 = 3
        let messages: [MIDIMessage] = [
            .noteOn(channel: c, note: 60, velocity: 1), .noteOn(channel: c, note: 64, velocity: 127),
            .controlChange(channel: c, controller: 64, value: 0), .controlChange(channel: c, controller: 66, value: 64),
            .controlChange(channel: c, controller: 67, value: 127),
            .pitchBend(channel: c, value: 0), .pitchBend(channel: c, value: 8192), .pitchBend(channel: c, value: 16383),
            .channelPressure(channel: c, value: 0), .channelPressure(channel: c, value: 127),
            .polyPressure(channel: c, note: 60, value: 99),
            .noteOff(channel: c, note: 60, velocity: 30), .noteOff(channel: c, note: 64),
        ]
        let take = Take(events: messages.enumerated().map { TakeEvent(time: 0.25 * Double($0.offset), message: $0.element) }, duration: 5)
        let back = try XCTUnwrap(StandardMIDIFile.read(StandardMIDIFile.write(take, name: "Kinds", bpm: 84)))
        XCTAssertEqual(back.name, "Kinds")
        XCTAssertEqual(back.events.map(\.message), messages)
        for (a, b) in zip(back.events, take.events) { XCTAssertEqual(a.time, b.time, accuracy: 0.75e-3) }
        // Running status, as other programs write it: the second note-on and the note-offs (velocity 0) share a status.
        let running: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, 0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 18,
                                0x00, 0x91, 60, 90, 0x00, 64, 80, 0x83, 0x60, 60, 0, 0x00, 64, 0, 0x00, 0xFF, 0x2F, 0x00]
        let other = try XCTUnwrap(StandardMIDIFile.read(Data(running)))
        XCTAssertEqual(other.events.map(\.message), [.noteOn(channel: 1, note: 60, velocity: 90), .noteOn(channel: 1, note: 64, velocity: 80),
                                                     .noteOff(channel: 1, note: 60), .noteOff(channel: 1, note: 64)])
        XCTAssertEqual(other.events.map(\.time), [0, 0, 0.5, 0.5], "at 120 BPM until told otherwise")
        XCTAssertEqual(other.bpm, 120)
        XCTAssertNil(StandardMIDIFile.read(Data([0x4D, 0x54, 0x68])), "not a MIDI file")
    }

    func testTimesAreExactToTheMillisecond() throws {
        var r = SeededRandom(seed: 0x5EED)
        var times: [Double] = []
        for _ in 0..<2_000 { times.append(Double(r.next() % 1_800_001) / 1000) }
        times.sort()
        let events = times.enumerated().map { i, t in
            TakeEvent(time: t, message: i % 2 == 0 ? .noteOn(channel: 0, note: 60, velocity: 80) : .noteOff(channel: 0, note: 60))
        }
        let take = Take(events: events, duration: (times.last ?? 0) + 2)
        for (bpm, halfTick) in [(68.0, 0.92e-3), (84, 0.75e-3), (120, 0.53e-3)] {
            let back = try XCTUnwrap(StandardMIDIFile.read(StandardMIDIFile.write(take, name: "Times", bpm: bpm)))
            XCTAssertEqual(back.events.count, events.count)
            var worst = 0.0
            for (a, b) in zip(back.events, events) { worst = max(worst, abs(a.time - b.time)) }
            XCTAssertLessThanOrEqual(worst, halfTick, "\(bpm) BPM: \(worst * 1000) ms at worst")
            XCTAssertEqual(back.events.last?.time ?? 0, times.last ?? 0, accuracy: halfTick, "the last included")
        }
    }
}
