import XCTest
@testable import InStrumCore

/// The take keeper (Small Wins spec §2, Task 1; Review focus 1 and 2): a ring of what was played over the last two hours,
/// and the take it hands back. Every scenario was run first on a Python mirror of `TakeKeeper`, which agreed with each
/// bound here.
final class TakeKeeperTests: XCTestCase {
    private func on(_ note: UInt8, _ velocity: UInt8 = 80, channel: UInt8 = 0) -> MIDIMessage {
        .noteOn(channel: channel, note: note, velocity: velocity)
    }
    private func off(_ note: UInt8, channel: UInt8 = 0) -> MIDIMessage { .noteOff(channel: channel, note: note) }
    private func cc(_ controller: UInt8, _ value: UInt8) -> MIDIMessage { .controlChange(channel: 0, controller: controller, value: value) }

    /// Notes `length` s long, one every `every` s, from `from` while they start by `to`.
    private func phrase(_ k: inout TakeKeeper, from: Double, to: Double, every: Double = 0.5, length: Double = 0.3, note: UInt8 = 60) {
        var i = 0
        while from + Double(i) * every <= to + 1e-9 {
            let t = from + Double(i) * every
            k.record(on(note), at: t)
            k.record(off(note), at: t + length)
            i += 1
        }
    }

    private func assertTimes(_ take: Take, _ times: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(take.events.count, times.count, "events", file: file, line: line)
        for (e, t) in zip(take.events, times) { XCTAssertEqual(e.time, t, accuracy: 1e-9, "\(e.message)", file: file, line: line) }
    }

    /// Note-ons and note-offs pair up: each note-on has exactly one later note-off, and there's no note-off without one.
    private func assertPaired(_ take: Take, file: StaticString = #filePath, line: UInt = #line) {
        var open: [Int: Double] = [:]
        for e in take.events {
            switch e.message {
            case let .noteOn(c, n, _):
                XCTAssertNil(open[Int(c) * 128 + Int(n)], "note \(n) struck again before its note-off", file: file, line: line)
                open[Int(c) * 128 + Int(n)] = e.time
            case let .noteOff(c, n, _):
                XCTAssertNotNil(open.removeValue(forKey: Int(c) * 128 + Int(n)), "an orphan note-off for \(n) at \(e.time)", file: file, line: line)
            default: break
            }
            XCTAssertTrue((0...take.duration + 1e-9).contains(e.time), "\(e.time) inside the take", file: file, line: line)
        }
        XCTAssertTrue(open.isEmpty, "notes left open: \(open)", file: file, line: line)
        XCTAssertEqual(take.events.map(\.time), take.events.map(\.time).sorted(), "in time order", file: file, line: line)
    }

    func testOnlyThePlayingIsKept() throws {
        var k = TakeKeeper()
        k.record(cc(64, 127), at: 0.1)
        k.record(cc(66, 100), at: 0.2)
        k.record(cc(67, 90), at: 0.3)
        k.record(on(60), at: 1)
        k.record(.polyPressure(channel: 0, note: 60, value: 40), at: 1.1)
        k.record(.pitchBend(channel: 0, value: 9000), at: 1.2)
        k.record(.channelPressure(channel: 0, value: 50), at: 1.3)
        for controller: UInt8 in [1, 7, 11] { k.record(cc(controller, 64), at: 1.4) }
        k.record(.other, at: 1.5)
        k.record(off(60), at: 2)
        XCTAssertEqual(k.count, 8, "note on and off, three pedals, bend and both pressures; not the mod wheel, volume, expression or a program change")
        let take = try XCTUnwrap(k.lastTake(endingAt: 3))
        XCTAssertEqual(take.events.map(\.message), [cc(64, 127), cc(66, 100), cc(67, 90), on(60), .polyPressure(channel: 0, note: 60, value: 40),
                                                     .pitchBend(channel: 0, value: 9000), .channelPressure(channel: 0, value: 50), off(60)])
        assertTimes(take, [0, 0, 0, 0, 0.1, 0.2, 0.3, 1])   // the pedals as they stood, at its start
        XCTAssertEqual(take.duration, 2, accuracy: 1e-9, "to now (2 s after the last note-off is later)")
    }

    func testTakeStartsAfterTheLastLongSilence() throws {
        var k = TakeKeeper()
        phrase(&k, from: 0, to: 20)
        phrase(&k, from: 29, to: 40, note: 64)
        let take = try XCTUnwrap(k.lastTake(endingAt: 41))
        XCTAssertEqual(take.events.first?.message, on(64), "8.7 s of silence: the second phrase alone")
        XCTAssertEqual(take.events.first?.time, 0)
        XCTAssertEqual(take.duration, 12, accuracy: 1e-9, "29 s to now (41 s)")
        XCTAssertFalse(take.events.contains { $0.message == on(60) })
        assertPaired(take)
        var close = TakeKeeper()
        phrase(&close, from: 0, to: 20)
        phrase(&close, from: 28.1, to: 40, note: 64)
        let whole = try XCTUnwrap(close.lastTake(endingAt: 41))
        XCTAssertEqual(whole.events.first?.message, on(60), "7.8 s isn't a silence: both phrases")
        XCTAssertEqual(whole.duration, 41, accuracy: 1e-9)
        assertPaired(whole)
    }

    func testHeldKeysAreNotSilence() throws {
        var k = TakeKeeper()
        k.record(on(40), at: 0)
        k.record(off(40), at: 15)
        k.record(on(60), at: 15.5)
        k.record(off(60), at: 16)
        let take = try XCTUnwrap(k.lastTake(endingAt: 30))
        XCTAssertEqual(take.events.first?.message, on(40), "a key held 15 s isn't silence")
        XCTAssertEqual(take.duration, 18, accuracy: 1e-9, "to 2 s after the last note-off")
        assertPaired(take)
    }

    func testThePedalAloneIsSilence() throws {
        var k = TakeKeeper()
        k.record(cc(64, 127), at: 0.5)
        phrase(&k, from: 1, to: 4.5)   // the last key up at 4.8, under the pedal
        k.record(on(62), at: 14)
        k.record(off(62), at: 14.5)
        let take = try XCTUnwrap(k.lastTake(endingAt: 20))
        XCTAssertEqual(take.events.map(\.message), [cc(64, 127), on(62), off(62)], "the pedal held 9 s with no keys down is silence")
        assertTimes(take, [0, 0, 0.5])
        XCTAssertEqual(take.duration, 2.5, accuracy: 1e-9)
    }

    func testTakesAreAtMostThirtyMinutes() throws {
        var k = TakeKeeper()
        phrase(&k, from: 0, to: 2699, every: 2)
        let take = try XCTUnwrap(k.lastTake(endingAt: 2701))
        XCTAssertTrue((1797...1800).contains(take.duration), "\(take.duration) s")
        XCTAssertEqual(take.events.first?.message, on(60), "it starts on a note")
        assertPaired(take)
    }

    func testNothingToKeepAfterTenMinutes() throws {
        var k = TakeKeeper()
        XCTAssertNil(k.lastTake(endingAt: 5), "nothing played")
        k.record(cc(64, 127), at: 0)
        XCTAssertNil(k.lastTake(endingAt: 5), "a pedal alone is nothing to keep")
        k.record(on(60), at: 0)
        k.record(off(60), at: 0.1)
        XCTAssertNil(k.lastTake(endingAt: 600.5))
        let take = try XCTUnwrap(k.lastTake(endingAt: 599.5))
        XCTAssertEqual(take.duration, 2.1, accuracy: 1e-9)
        XCTAssertNil(k.lastMinutes(endingAt: 700), "nor anything in the last ten minutes")
    }

    func testLastTenMinutesIgnoresSilences() throws {
        var k = TakeKeeper()
        phrase(&k, from: 0, to: 30, length: 0.25)
        phrase(&k, from: 300, to: 310, length: 0.25, note: 64)
        let take = try XCTUnwrap(k.lastMinutes(endingAt: 320))
        XCTAssertEqual(take.events.first?.message, on(60))
        XCTAssertEqual(take.duration, 312.25, accuracy: 1e-9)
        XCTAssertEqual(take.events.filter { if case .noteOn = $0.message { return true }; return false }.count, 61 + 21)
        assertPaired(take)
        let last = try XCTUnwrap(k.lastTake(endingAt: 320))
        XCTAssertEqual(last.duration, 12.25, accuracy: 1e-9, "the last take alone")
    }

    /// Review focus 1: a take never starts or ends mid-note. A key down before its start loses its note-off, one still
    /// down at its end is let go there, and a bend from before it is where it was at its start.
    func testTakeEdgesStayClean() throws {
        var k = TakeKeeper()
        k.record(.pitchBend(channel: 0, value: 12000), at: 10)
        k.record(on(48), at: 50)            // down before the last ten minutes begin (at 100)
        phrase(&k, from: 120, to: 145, every: 5)
        k.record(off(48), at: 150)          // let go inside them: an orphan
        phrase(&k, from: 150, to: 680, every: 5)
        k.record(on(72), at: 685)           // still down at the end
        let take = try XCTUnwrap(k.lastMinutes(endingAt: 700))
        XCTAssertEqual(take.events.first?.message, .pitchBend(channel: 0, value: 12000), "the earlier bend, at 0")
        XCTAssertEqual(take.events.first?.time, 0)
        XCTAssertEqual(take.events[1].message, on(60), "then the first note in the window")
        XCTAssertFalse(take.events.contains { $0.message == off(48) || $0.message == on(48) }, "the key from before is left out")
        XCTAssertEqual(take.duration, 580, accuracy: 1e-9, "120 s to now: a key is still down")
        XCTAssertEqual(take.events.last?.message, off(72), "and let go at the end")
        XCTAssertEqual(take.events.last?.time ?? 0, 580, accuracy: 1e-9)
        assertPaired(take)
        // A keyboard's all-notes-off lets go of everything it holds.
        k.record(cc(123, 0), at: 701)
        let after = try XCTUnwrap(k.lastMinutes(endingAt: 710))
        XCTAssertEqual(after.events.last?.message, off(72))
        XCTAssertEqual(after.events.last?.time ?? 0, 701 - 120, accuracy: 1e-9)
        XCTAssertEqual(after.duration, 703 - 120, accuracy: 1e-9, "2 s after the keys were let go")
        assertPaired(after)
        // A take ending now closes a key still down now.
        var held = TakeKeeper()
        held.record(on(60), at: 0)
        held.record(off(60), at: 0.5)
        held.record(on(62), at: 1)
        let open = try XCTUnwrap(held.lastTake(endingAt: 4))
        XCTAssertEqual(open.events.map(\.message), [on(60), off(60), on(62), off(62)])
        assertTimes(open, [0, 0.5, 1, 4])
        assertPaired(open)
        // A panic lets go of everything too.
        held.releaseAll(at: 5)
        XCTAssertEqual(held.lastTake(endingAt: 20)?.duration ?? 0, 7, accuracy: 1e-9)
    }

    /// Review focus 1: the ring keeps two hours, and never more than 250,000 events, dropping the oldest first.
    func testTheRingStaysBounded() {
        var k = TakeKeeper()
        let n = 200_000, step = 3 * 3600.0 / Double(n)
        for i in 0..<n { k.record(i % 2 == 0 ? on(60) : off(60), at: Double(i) * step) }
        XCTAssertEqual(Double(k.count), 133_334, accuracy: 2, "the last two hours of three")
        var full = TakeKeeper()
        let many = 300_000, quick = 3600.0 / Double(many)
        let started = Date()
        for i in 0..<many { full.record(i % 2 == 0 ? on(60) : off(60), at: Double(i) * quick) }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(full.count, TakeKeeper.cap, "exactly the newest 250,000")
        XCTAssertLessThan(seconds, 1, "recorded in \(seconds) s")
        let take = full.lastMinutes(endingAt: 3600)
        XCTAssertEqual(take?.duration ?? 0, 600, accuracy: 0.05)
    }

    /// The gesture keeps the take before it and is cut from it: none of its notes, and none of their late note-offs.
    func testTheGestureIsCutFromTheTake() throws {
        var k = TakeKeeper()
        phrase(&k, from: 10, to: 22)
        let keys: [UInt8] = [102, 104, 106]
        var fired: [Double] = []
        for (i, note) in keys.enumerated() {
            if let start = k.record(on(note, 100), at: 25 + 0.01 * Double(i)) { fired.append(start) }
        }
        for note in keys { k.record(off(note), at: 25.1) }
        for (i, note) in keys.enumerated() {
            if let start = k.record(on(note, 100), at: 25.6 + 0.01 * Double(i)) { fired.append(start) }
        }
        XCTAssertEqual(fired, [25], "the gesture, starting at 25 s")
        let counted = k.count
        XCTAssertEqual(counted, 50, "the phrase's 25 notes alone")
        for note in keys { k.record(off(note), at: 25.7) }
        XCTAssertEqual(k.count, counted, "the late note-offs aren't kept")
        for end in [25.0, 40.0] {
            let take = try XCTUnwrap(k.lastTake(endingAt: end))
            XCTAssertFalse(take.events.contains {
                switch $0.message {
                case let .noteOn(_, n, _), let .noteOff(_, n, _): return n > 100
                default: return false
                }
            }, "no gesture note in the take ending at \(end)")
            XCTAssertEqual(take.duration, 14.3, accuracy: 1e-9, "10 s to 2 s after 22.3 s")
            assertPaired(take)
        }
        // The first tap alone is music, kept as played.
        var once = TakeKeeper()
        for (i, note) in keys.enumerated() { once.record(on(note), at: 1 + 0.01 * Double(i)) }
        for note in keys { once.record(off(note), at: 1.2) }
        XCTAssertEqual(once.count, 6)
        XCTAssertEqual(once.lastTake(endingAt: 5)?.events.count, 6)
    }

    /// A narrower keyboard moves the gesture down to its own top three black keys.
    func testTheRangeMovesTheGesture() {
        var k = TakeKeeper(low: 36, high: 96)
        let keys: [UInt8] = [90, 92, 94]
        var fired = 0
        func taps(at times: [Double]) {
            for t in times {
                for (i, note) in keys.enumerated() {
                    if k.record(on(note), at: t + 0.01 * Double(i)) != nil { fired += 1 }
                }
                for note in keys { k.record(off(note), at: t + 0.1) }
            }
        }
        taps(at: [1, 1.5])
        XCTAssertEqual(fired, 1)
        k.setRange(low: 21, high: 108)
        taps(at: [3, 3.5])
        XCTAssertEqual(fired, 1, "on an 88 they're music")
    }
}
