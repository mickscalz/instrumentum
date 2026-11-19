import XCTest
@testable import InStrumCore

/// Where Spotify is between its answers (Song Sheet spec §2, Task S1).
final class PlaybackClockTests: XCTestCase {
    func testRunsBetweenAnswers() {
        var clock = PlaybackClock()
        XCTAssertEqual(clock.position(at: 5), 0, "nothing heard yet")
        clock.report(position: 30, playing: true, at: 100)
        XCTAssertEqual(clock.position(at: 100), 30, accuracy: 1e-9)
        XCTAssertEqual(clock.position(at: 100.5), 30.5, accuracy: 1e-9)
        XCTAssertEqual(clock.position(at: 101.25), 31.25, accuracy: 1e-9)
        XCTAssertFalse(clock.looksStuck)
    }

    func testAJumpOfMoreThanASecondAndAHalfReanchors() {
        var clock = PlaybackClock()
        clock.report(position: 30, playing: true, at: 100)
        clock.report(position: 80, playing: true, at: 101)
        XCTAssertEqual(clock.position(at: 101), 80, accuracy: 1e-9, "a seek forward")
        XCTAssertEqual(clock.position(at: 102), 81, accuracy: 1e-9)
        clock.report(position: 4, playing: true, at: 103)
        XCTAssertEqual(clock.position(at: 103.5), 4.5, accuracy: 1e-9, "a new song")
        var near = PlaybackClock()
        near.report(position: 30, playing: true, at: 100)
        near.report(position: 32.6, playing: true, at: 101)
        XCTAssertEqual(near.position(at: 101), 32.6, accuracy: 1e-9, "1.6 s out is a jump")
    }

    func testASmallDifferenceSettlesWithoutAJump() {
        var clock = PlaybackClock()
        clock.report(position: 30, playing: true, at: 100)
        clock.report(position: 31.4, playing: true, at: 101)
        XCTAssertEqual(clock.position(at: 101), 31.2, accuracy: 1e-9, "halfway from 31 to the answer")
        XCTAssertEqual(clock.position(at: 102), 32.2, accuracy: 1e-9)
    }

    func testStopsWhenPaused() {
        var clock = PlaybackClock()
        clock.report(position: 30, playing: true, at: 100)
        clock.report(position: 35, playing: false, at: 105)
        XCTAssertEqual(clock.position(at: 105), 35, accuracy: 1e-9)
        XCTAssertEqual(clock.position(at: 110), 35, accuracy: 1e-9)
        clock.report(position: 35.4, playing: false, at: 111)
        XCTAssertEqual(clock.position(at: 112), 35.4, accuracy: 1e-9, "moved while paused: it takes the answer")
        clock.report(position: 35.4, playing: true, at: 120)
        XCTAssertEqual(clock.position(at: 121), 36.4, accuracy: 1e-9, "playing again")
    }

    func testLooksStuckAfterTheSamePositionForTwoSecondsWhilePlaying() {
        var clock = PlaybackClock()
        clock.report(position: 42, playing: true, at: 0)
        clock.report(position: 42, playing: true, at: 1)
        XCTAssertFalse(clock.looksStuck, "one second is not enough")
        clock.report(position: 42, playing: true, at: 2)
        XCTAssertTrue(clock.looksStuck)
        XCTAssertEqual(clock.position(at: 3), 45, accuracy: 1e-9, "the clock runs on meanwhile")
        clock.report(position: 45.1, playing: true, at: 3)
        XCTAssertFalse(clock.looksStuck, "moving again")

        var twoAnswers = PlaybackClock()
        twoAnswers.report(position: 7, playing: true, at: 10)
        twoAnswers.report(position: 7, playing: true, at: 12)
        XCTAssertTrue(twoAnswers.looksStuck)

        var paused = PlaybackClock()
        paused.report(position: 42, playing: false, at: 0)
        paused.report(position: 42, playing: false, at: 2)
        paused.report(position: 42, playing: false, at: 4)
        XCTAssertFalse(paused.looksStuck, "paused is meant to stand still")
    }
}
