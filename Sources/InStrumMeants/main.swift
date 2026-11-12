import Foundation
import InStrumApp
import Sparkle

/// Sparkle behind the app's updater hook. The feed (the latest GitHub release's appcast) and the public EdDSA key are in
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`); automatic checks are on without asking (`SUEnableAutomaticChecks`), at
/// most hourly (`SUScheduledCheckInterval`). Every update is the build's zip, signed in CI with the matching private key.
@MainActor
final class SparkleUpdater: AppUpdating {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

// Only an installed app updates itself (not the bare executable run from the build folder).
if Bundle.main.bundleURL.pathExtension == "app" {
    AppUpdates.make = { SparkleUpdater() }
}
InStrumMeantsApp.main()
