import SwiftUI

/// The in-app updater as the app sees it: Sparkle in the shipped app (wired in by the executable, `main.swift`), nothing
/// in the tests and previews. It checks for a new build at launch (at most once an hour) and from the app menu, shows
/// what's new, and installs it in place: settings, saves and presets live in Application Support, so they carry over,
/// and the relaunched build opens on what's new as any new build does.
@MainActor
public protocol AppUpdating: AnyObject {
    /// Shows the update window: checking, then what's new with Install, or "you're up to date".
    func checkForUpdates()
}

@MainActor
public enum AppUpdates {
    /// How the executable makes its updater (set before the app starts).
    public static var make: (@MainActor () -> AppUpdating)?
    /// The running updater, once the app has started (nil in tests, previews and `swift run`).
    public private(set) static var updater: AppUpdating?

    /// Starts the updater once the app object exists (Sparkle needs it).
    static func start() {
        guard updater == nil, let make else { return }
        updater = make()
    }
}

/// "Check for Updates…" in the app menu, under About.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdates.updater?.checkForUpdates() }
        }
    }
}
