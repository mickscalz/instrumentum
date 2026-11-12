import XCTest
@testable import InStrumCore

/// The keep gesture (Small Wins spec §2, Task 1; Review focus 2): the keyboard's top three black keys tapped together,
/// twice within 1.5 s. Here a tap is the three note-ons within 30 ms, let go 100 ms later. Every case was run first on a
/// Python mirror of `KeyGesture`, which fired exactly where these tests say.
final class KeyGestureTests: XCTestCase {
    private let top: [UInt8] = [102, 104, 106]   // F♯7, G♯7 and A♯7 on an 88

    private func on(_ note: UInt8) -> MIDIMessage { .noteOn(channel: 0, note: note, velocity: 90) }
    private func off(_ note: UInt8) -> MIDIMessage { .noteOff(channel: 0, note: note) }

    /// One tap at `t`: the three keys 15 ms apart, let go 100 ms after the first.
    private func tap(at t: Double, _ keys: [UInt8]? = nil) -> [(Double, MIDIMessage)] {
        let keys = keys ?? top
        var out: [(Double, MIDIMessage)] = []
        for (i, k) in keys.enumerated() { out.append((t + 0.015 * Double(i), on(k))) }
        for k in keys { out.append((t + 0.1, off(k))) }
        return out
    }

    /// Feeds the messages in time order and returns each fire: when it fired and what it returned.
    private func fires(_ messages: [(Double, MIDIMessage)], notes: [UInt8]? = nil) -> [(at: Double, start: Double)] {
        var g = KeyGesture(notes: notes ?? top)
        var out: [(at: Double, start: Double)] = []
        let ordered = messages.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        for (_, (t, m)) in ordered {
            if let start = g.feed(m, at: t) { out.append((t, start)) }
        }
        return out
    }

    func testTheTopThreeBlackKeys() {
        XCTAssertEqual(KeyGesture.triple(low: 21, high: 108), [102, 104, 106], "F♯7, G♯7, A♯7 on an 88")
        XCTAssertEqual(KeyGesture.triple(low: 28, high: 103), [90, 92, 94], "76 keys: G7 is the top, so the octave below")
        XCTAssertEqual(KeyGesture.triple(low: 36, high: 96), [90, 92, 94], "61 keys")
        XCTAssertEqual(KeyGesture.triple(low: 36, high: 84), [78, 80, 82], "49 keys")
        XCTAssertNil(KeyGesture.triple(low: 100, high: 105), "no whole F♯–A♯ in range")
        XCTAssertNil(KeyGesture.triple(low: 0, high: 5))
        for range in KeyboardRange.allCases {
            let keys = KeyGesture.triple(low: range.low, high: range.high)
            XCTAssertNotNil(keys, range.rawValue)
            XCTAssertTrue(keys?.allSatisfy { KeyboardLayout.isBlack($0) && (range.low...range.high).contains($0) } ?? false, range.rawValue)
        }
    }

    func testTwoTapsWithinOneAndAHalfSecondsFire() {
        let quick = fires(tap(at: 0) + tap(at: 0.9))
        XCTAssertEqual(quick.count, 1, "once")
        XCTAssertEqual(quick.first?.at ?? -1, 0.93, accuracy: 1e-9, "at the second tap's third note-on")
        XCTAssertEqual(quick.first?.start ?? -1, 0, accuracy: 1e-9, "returning the first tap's start")
        XCTAssertTrue(fires(tap(at: 0) + tap(at: 1.6)).isEmpty, "1.6 s apart: too slow")
        let late = fires(tap(at: 0) + tap(at: 1.6) + tap(at: 2.4))
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?.start ?? -1, 1.6, accuracy: 1e-9, "the second and third taps make the pair")
    }

    /// Review focus 2: nothing that merely contains the three keys fires it.
    func testAChordContainingTheKeysNeverFires() {
        // D♯7 struck with the three, twice in a second, in either order.
        let withDSharp = [(0.0, on(99))] + tap(at: 0.005) + [(0.1, off(99)), (0.6, on(99))] + tap(at: 0.6) + [(0.7, off(99))]
        XCTAssertTrue(fires(withDSharp).isEmpty, "D♯7 first")
        let dSharpLast = tap(at: 0) + [(0.04, on(99)), (0.1, off(99))] + tap(at: 0.6) + [(0.64, on(99)), (0.7, off(99))]
        XCTAssertTrue(fires(dSharpLast).isEmpty, "D♯7 last")
        // The three with a G2 inside the 80 ms, twice.
        let withBass = tap(at: 0) + [(0.02, on(43)), (0.1, off(43))] + tap(at: 0.7) + [(0.72, on(43)), (0.8, off(43))]
        XCTAssertTrue(fires(withBass).isEmpty, "a G2 among them")
        // The three spread over 120 ms, twice.
        let spread: [(Double, MIDIMessage)] = [(0, on(102)), (0.06, on(104)), (0.12, on(106)), (0.2, off(102)), (0.2, off(104)),
                                               (0.2, off(106)), (0.5, on(102)), (0.56, on(104)), (0.62, on(106))]
        XCTAssertTrue(fires(spread).isEmpty, "rolled over 120 ms")
        // A 2 s F♯7–G♯7 trill, a note every 60 ms, with a quick F♯–G♯–A♯ run every half second.
        var trill: [(Double, MIDIMessage)] = []
        var t = 0.0, i = 0
        while t < 2 {
            if i % 8 == 7 {
                for (j, k) in top.enumerated() { trill.append((t + 0.03 * Double(j), on(k))); trill.append((t + 0.03 * Double(j) + 0.025, off(k))) }
                t += 0.12
            } else {
                let k = i % 2 == 0 ? top[0] : top[1]
                trill.append((t, on(k)))
                trill.append((t + 0.05, off(k)))
                t += 0.06
            }
            i += 1
        }
        XCTAssertTrue(fires(trill).isEmpty, "a trill with runs")
        XCTAssertTrue(fires(tap(at: 0)).isEmpty, "one tap")
        // Something played between two good taps breaks the pair.
        XCTAssertTrue(fires(tap(at: 0) + [(0.4, on(60)), (0.5, off(60))] + tap(at: 0.9)).isEmpty, "a note between")
    }

    /// Review focus 2: three taps in a row fire once, at the second; the third starts a new count.
    func testThreeTapsFireOnce() {
        let three = fires(tap(at: 0) + tap(at: 0.6) + tap(at: 1.2))
        XCTAssertEqual(three.count, 1)
        XCTAssertEqual(three.first?.at ?? -1, 0.63, accuracy: 1e-9)
        XCTAssertEqual(three.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(fires(tap(at: 0) + tap(at: 0.6) + tap(at: 1.2) + tap(at: 1.8)).count, 2, "the fourth pairs with the third")
    }

    /// The gesture follows the keyboard it's given: on a 61, the 88's top keys are music.
    func testTheGestureFollowsItsKeys() {
        let narrow: [UInt8] = [90, 92, 94]
        XCTAssertEqual(fires(tap(at: 0, narrow) + tap(at: 0.5, narrow), notes: narrow).count, 1)
        XCTAssertTrue(fires(tap(at: 0) + tap(at: 0.5), notes: narrow).isEmpty)
        XCTAssertTrue(fires(tap(at: 0) + tap(at: 0.5), notes: []).isEmpty, "no keys, no gesture")
    }
}
