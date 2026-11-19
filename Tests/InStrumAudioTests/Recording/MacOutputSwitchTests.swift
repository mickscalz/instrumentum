import XCTest
@testable import InStrumAudio

/// The Mac's default output ↔ BlackHole (Recorder spec §5.2; plan Task 4, Review focus 3). The Mac's output here is a
/// stand-in: `current` is the default output's UID, and only devices in `present` can be chosen. The marker lives in a
/// throwaway defaults domain.
final class MacOutputSwitchTests: XCTestCase {
    static let speakers = "BuiltInSpeakerDevice"
    static let headphones = "BuiltInHeadphoneOutputDevice"
    static let blackHole = "BlackHole2ch_UID"

    var suite = ""
    var defaults: UserDefaults!
    var current: String?
    var present: Set<String> = []

    override func setUpWithError() throws {
        suite = "MacOutputSwitchTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        current = Self.speakers
        present = [Self.speakers, Self.headphones, Self.blackHole]
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A switch on the stand-in Mac (one per launch of the app).
    private func makeSwitch() -> MacOutputSwitch {
        MacOutputSwitch(get: { [unowned self] in self.current },
                        set: { [unowned self] uid in
                            guard self.present.contains(uid) else { return false }
                            self.current = uid
                            return true
                        },
                        marker: defaults)
    }

    private var marker: String? { defaults.string(forKey: MacOutputSwitch.markerKey) }

    func testSwitchRemembersAndRestores() {
        var output = makeSwitch()
        let previous = output.switchTo(Self.blackHole)
        let during = current
        let markerDuring = marker
        output.restore()
        let after = current
        let markerAfter = marker
        XCTAssertEqual(previous, Self.speakers)
        XCTAssertEqual(during, Self.blackHole)
        XCTAssertEqual(markerDuring, Self.speakers, "remembered where a crash can't lose it")
        XCTAssertEqual(after, Self.speakers)
        XCTAssertNil(markerAfter)
    }

    /// Review focus 3: the app dies with the Mac's output on BlackHole; the next launch puts it back, once.
    func testCrashMarkerRestoresTheMacsOutput() {
        var calmLaunch = makeSwitch()
        let restoredWithoutAMarker = calmLaunch.restoreAfterCrashIfNeeded()

        var crashing = makeSwitch()
        _ = crashing.switchTo(Self.blackHole)
        let stuck = current   // … and the app dies here, before `restore()`

        var nextLaunch = makeSwitch()
        let restored = nextLaunch.restoreAfterCrashIfNeeded()
        let after = current
        let markerAfter = marker
        let again = nextLaunch.restoreAfterCrashIfNeeded()
        XCTAssertFalse(restoredWithoutAMarker)
        XCTAssertEqual(stuck, Self.blackHole)
        XCTAssertTrue(restored)
        XCTAssertEqual(after, Self.speakers)
        XCTAssertNil(markerAfter)
        XCTAssertFalse(again, "once")
    }

    /// The speakers it was playing to were unplugged meanwhile: nothing to put back, so the default is left alone and the
    /// marker is cleared (on stop, and after a crash).
    func testRestoreWhenThePreviousDeviceIsGoneLeavesTheDefaultAlone() {
        var output = makeSwitch()
        _ = output.switchTo(Self.blackHole)
        present.remove(Self.speakers)
        output.restore()
        let afterStop = current
        let markerAfterStop = marker

        present.insert(Self.speakers)
        current = Self.speakers
        var crashing = makeSwitch()
        _ = crashing.switchTo(Self.blackHole)
        present.remove(Self.speakers)
        var nextLaunch = makeSwitch()
        let restored = nextLaunch.restoreAfterCrashIfNeeded()
        let afterCrash = current
        let markerAfterCrash = marker
        XCTAssertEqual(afterStop, Self.blackHole)
        XCTAssertNil(markerAfterStop)
        XCTAssertFalse(restored)
        XCTAssertEqual(afterCrash, Self.blackHole)
        XCTAssertNil(markerAfterCrash)
    }

    /// He chose other speakers himself while it was on: his choice stands.
    func testAChoiceMadeMeanwhileIsKept() {
        var output = makeSwitch()
        _ = output.switchTo(Self.blackHole)
        current = Self.headphones
        output.restore()
        let after = current
        let markerAfter = marker
        XCTAssertEqual(after, Self.headphones)
        XCTAssertNil(markerAfter)
    }

    /// Already on BlackHole: nothing to remember, nothing to put back.
    func testSwitchingToTheOutputInUseRemembersNothing() {
        current = Self.blackHole
        var output = makeSwitch()
        let previous = output.switchTo(Self.blackHole)
        let markerDuring = marker
        output.restore()
        let after = current
        XCTAssertNil(previous)
        XCTAssertNil(markerDuring)
        XCTAssertEqual(after, Self.blackHole)
    }

    /// BlackHole refuses to become the output: nothing changes, nothing is remembered.
    func testASwitchThatFailsChangesNothing() {
        present.remove(Self.blackHole)
        var output = makeSwitch()
        let previous = output.switchTo(Self.blackHole)
        let after = current
        let markerAfter = marker
        XCTAssertNil(previous)
        XCTAssertEqual(after, Self.speakers)
        XCTAssertNil(markerAfter)
    }
}
