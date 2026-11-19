import XCTest
@testable import InStrumCore

/// The Recorder's one timeline (Recorder plan part 2, "One timeline"): the play-along track and the layers share one
/// position, one cue point and one loop; the tempo slider and the jog wheel turn into a speed and seconds.
final class TransportStateTests: XCTestCase {
    private func state(position: Double = 0, duration: Double = 60) -> TransportState {
        var s = TransportState()
        s.duration = duration
        s.position = position
        return s
    }

    func testCueSetsWhenPausedAndReturnsWhenPlaying() {
        let fresh = TransportState()
        XCTAssertEqual(fresh.cue, 0, "the cue point starts at 0")
        XCTAssertFalse(fresh.playing)
        XCTAssertEqual(fresh.rate, 1)

        // Paused: the cue point moves to the position, and nothing is jumped to.
        var s = state(position: 12.5)
        let paused = s.pressCue()
        XCTAssertNil(paused)
        XCTAssertEqual(s.cue, 12.5)
        XCTAssertEqual(s.position, 12.5)
        XCTAssertFalse(s.playing)

        // Playing: back to the cue point, and paused there.
        s.playing = true
        s.position = 30
        let jumped = s.pressCue()
        XCTAssertEqual(jumped, 12.5)
        XCTAssertEqual(s.position, 12.5)
        XCTAssertFalse(s.playing)
        XCTAssertEqual(s.cue, 12.5, "returning leaves the cue point where it was")
    }

    func testLoopInOutAndExit() {
        var s = state(position: 10)
        s.pressLoopIn()
        XCTAssertEqual(s.loopIn, 10)
        XCTAssertNil(s.loopOut)
        XCTAssertFalse(s.looping)

        s.position = 14
        s.pressLoopOut()
        XCTAssertEqual(s.loopOut, 14)
        XCTAssertTrue(s.looping, "OUT sets the end and starts looping")

        s.pressLoopOut()
        XCTAssertFalse(s.looping, "OUT again leaves the loop")

        // A new IN clears the old end and stops a loop.
        s.pressLoopOut()
        XCTAssertTrue(s.looping)
        s.position = 20
        s.pressLoopIn()
        XCTAssertEqual(s.loopIn, 20)
        XCTAssertNil(s.loopOut)
        XCTAssertFalse(s.looping)

        // OUT with no IN does nothing.
        var bare = state(position: 5)
        bare.pressLoopOut()
        XCTAssertNil(bare.loopOut)
        XCTAssertFalse(bare.looping)
    }

    func testATinyLoopIsRefused() {
        XCTAssertEqual(TransportState.minLoop, 0.05)
        var s = state(position: 1)
        s.pressLoopIn()
        s.position = 1.04
        s.pressLoopOut()
        XCTAssertNil(s.loopOut, "40 ms is shorter than the shortest loop")
        XCTAssertFalse(s.looping)

        s.position = 0.5   // before IN: no loop either
        s.pressLoopOut()
        XCTAssertFalse(s.looping)

        s.position = 1.06
        s.pressLoopOut()
        XCTAssertEqual(s.loopOut, 1.06)
        XCTAssertTrue(s.looping)
    }

    func testScrubClamps() {
        var s = state(position: 5, duration: 30)
        s.scrub(by: 2.5)
        XCTAssertEqual(s.position, 7.5)
        s.scrub(by: -100)
        XCTAssertEqual(s.position, 0, "never before the start")
        s.scrub(by: 1000)
        XCTAssertEqual(s.position, 30, "never past the end")
        s.scrub(by: .nan)
        XCTAssertEqual(s.position, 30, "nonsense moves nothing")
    }

    func testAdvanceWrapsAtTheLoop() {
        // Paused: nothing moves.
        var s = state(position: 1, duration: 10)
        let idle = s.advance(by: 0.5)
        XCTAssertFalse(idle)
        XCTAssertEqual(s.position, 1)

        // Playing at 0.9: seconds × rate.
        s.playing = true
        s.rate = 0.9
        let moved = s.advance(by: 1)
        XCTAssertFalse(moved)
        XCTAssertEqual(s.position, 1.9, accuracy: 1e-12)

        // A loop from 2 to 3: crossing its end wraps to its start by what went past.
        s.rate = 1
        s.loopIn = 2
        s.loopOut = 3
        s.looping = true
        s.position = 2.9
        let wrapped = s.advance(by: 0.25)
        XCTAssertTrue(wrapped)
        XCTAssertEqual(s.position, 2.15, accuracy: 1e-12)
        XCTAssertTrue(s.playing)

        // Past the loop's end already (scrubbed there): it plays on to the end of the timeline, and stops there.
        s.position = 9.5
        let ended = s.advance(by: 1)
        XCTAssertTrue(ended)
        XCTAssertEqual(s.position, 10)
        XCTAssertFalse(s.playing)

        // Not looping: the end of the timeline stops it.
        var plain = state(position: 9.9, duration: 10)
        plain.playing = true
        let stopped = plain.advance(by: 0.2)
        XCTAssertTrue(stopped)
        XCTAssertEqual(plain.position, 10)
        XCTAssertFalse(plain.playing)
    }

    func testSliderCentreIsExactlyOne() {
        let centre = TransportState.rate(fromSlider: 0.5)
        let bottom = TransportState.rate(fromSlider: 0)
        let top = TransportState.rate(fromSlider: 1)
        let beyond = TransportState.rate(fromSlider: 3)
        let quarter = TransportState.rate(fromSlider: 0.75)
        XCTAssertEqual(centre, 1, "exactly 100%")
        XCTAssertEqual(bottom, 1.1, accuracy: 1e-12)
        XCTAssertEqual(top, 0.9, accuracy: 1e-12, "the top of a DJ tempo slider is slower")
        XCTAssertEqual(beyond, 0.9, accuracy: 1e-12, "held to ±10%")
        XCTAssertEqual(quarter, 0.95, accuracy: 1e-12)
        XCTAssertEqual(TransportState.minRate, 0.9)
        XCTAssertEqual(TransportState.maxRate, 1.1)
    }

    func testJogIsFineOnTopAndFarOnTheEdge() {
        // Fine (the platter's top): 0.25 s an eighth of a turn, 2 s a turn, either way.
        let fineTurn = TransportState.jogSeconds(units: 8, fine: true)
        let fineBack = TransportState.jogSeconds(units: -1, fine: true)
        XCTAssertEqual(fineTurn, 2, accuracy: 1e-12)
        XCTAssertEqual(fineBack, -0.25, accuracy: 1e-12)

        // Search (the edge): 2 s a unit, faster the faster it spins, up to 8×.
        let slow = TransportState.jogSeconds(units: 0.08, fine: false)       // 0.16 × (1 + 0.5)
        let medium = TransportState.jogSeconds(units: 1, fine: false)        // 2 × 7.25
        let fast = TransportState.jogSeconds(units: 2, fine: false)          // 4 × 8
        let fastBack = TransportState.jogSeconds(units: -2, fine: false)
        XCTAssertEqual(slow, 0.24, accuracy: 1e-12)
        XCTAssertEqual(medium, 14.5, accuracy: 1e-12)
        XCTAssertEqual(fast, 32, accuracy: 1e-12)
        XCTAssertEqual(fastBack, -32, accuracy: 1e-12)

        // A slow turn of the edge, in many small steps, is about 16 s.
        var total = 0.0
        for _ in 0..<8000 { total += TransportState.jogSeconds(units: 0.001, fine: false) }
        XCTAssertEqual(total, 16, accuracy: 0.2)
    }
}
