import XCTest
import SwiftUI
@testable import InStrumApp

/// The top bar's update button and what feeds it.
@MainActor
final class AppUpdatesTests: XCTestCase {
    /// A check that finds a newer build lights the button with its number; one that finds none (or a blank) puts it out.
    func testStatusFollowsTheChecks() {
        let s = UpdateStatus()
        XCTAssertNil(s.newBuild)
        s.found(build: " 142 ")
        XCTAssertEqual(s.newBuild, "142")
        s.found(build: nil)
        XCTAssertNil(s.newBuild)
        s.found(build: "")
        XCTAssertNil(s.newBuild)
    }

    /// The button draws in all three states (no updater in tests and `swift run`; up to date; a build ready) and its
    /// action reaches the updater.
    func testButtonDrawsAndChecks() {
        let s = UpdateStatus()
        var checks = 0
        for (has, build) in [(false, nil), (true, nil), (true, "142")] as [(Bool, String?)] {
            s.found(build: build)
            let view = UpdateButton(status: s, hasUpdater: has) { checks += 1 }
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            host.layoutSubtreeIfNeeded()
            view.check()
        }
        XCTAssertEqual(checks, 3)
        // Outside a packaged app there is no updater and the build reads "dev".
        XCTAssertNil(AppUpdates.updater)
        XCTAssertFalse(AppUpdates.currentBuild.isEmpty)
    }
}
