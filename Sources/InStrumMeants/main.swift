import Foundation
import InStrumApp
import Sparkle

/// Hears what Sparkle's checks find (the quiet one at launch, the hourly scheduled ones, and the ones you start) and
/// tells the top bar's update button, which turns into **Update** when a newer build is out.
final class UpdateWatcher: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let build = item.versionString
        Task { @MainActor in AppUpdates.status.found(build: build) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in AppUpdates.status.found(build: nil) }
    }
}

/// Sparkle behind the app's updater hook. The feed (the latest GitHub release's appcast) and the public EdDSA key are in
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`); automatic checks are on without asking (`SUEnableAutomaticChecks`), at
/// most hourly (`SUScheduledCheckInterval`). Every update is the build's zip, signed in CI with the matching private key.
@MainActor
final class SparkleUpdater: AppUpdating {
    private let watcher: UpdateWatcher          // Sparkle holds its delegate weakly
    private let controller: SPUStandardUpdaterController

    init() {
        let w = UpdateWatcher()
        watcher = w
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: w, userDriverDelegate: nil)
        // A quiet look a few seconds after launch (no window), so the update button shows a new build straight away.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.controller.updater.checkForUpdateInformation()
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

// Only an installed app updates itself (not the bare executable run from the build folder).
if Bundle.main.bundleURL.pathExtension == "app" {
    AppUpdates.make = { SparkleUpdater() }
}
InStrumMeantsApp.main()
