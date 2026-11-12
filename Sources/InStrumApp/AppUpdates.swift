import SwiftUI

/// The in-app updater as the app sees it: Sparkle in the shipped app (wired in by the executable, `main.swift`), nothing
/// in the tests and previews. It checks for a new build at launch (at most once an hour), from the top bar's update
/// button and from the app menu, shows what's new, and installs it in place: settings, saves and presets live in
/// Application Support, so they carry over, and the relaunched build opens on what's new as any new build does.
@MainActor
public protocol AppUpdating: AnyObject {
    /// Shows the update window: checking, then what's new with Install, or "you're up to date".
    func checkForUpdates()
}

/// What the last quiet check found, for the top bar's update button.
@MainActor
public final class UpdateStatus: ObservableObject {
    /// The build number of a newer build the last check found; nil when up to date or not yet checked.
    @Published public private(set) var newBuild: String?

    public init() {}

    /// A check's result: the newer build's number, or nil when there is none.
    public func found(build: String?) {
        let b = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        newBuild = (b?.isEmpty ?? true) ? nil : b
    }
}

@MainActor
public enum AppUpdates {
    /// How the executable makes its updater (set once by `main.swift`'s top-level code, before the app starts).
    nonisolated(unsafe) public static var make: (@MainActor () -> AppUpdating)?
    /// The running updater, once the app has started (nil in tests, previews and `swift run`).
    public private(set) static var updater: AppUpdating?
    /// What the updater's quiet checks found (the executable reports into it).
    public static let status = UpdateStatus()

    /// This build's number (the CI run that made it), or "dev" outside a packaged app.
    public static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }

    /// Starts the updater once the app object exists (Sparkle needs it).
    static func start() {
        guard updater == nil, let make else { return }
        updater = make()
    }
}

/// The top bar's update button: a quiet icon that checks for a new build, which turns into an orange **Update** once a
/// newer build is out. Either way it opens the update window (what's new, then Install Update). Hidden where there is
/// no updater (tests, previews, `swift run`).
struct UpdateButton: View {
    @ObservedObject var status: UpdateStatus
    let hasUpdater: Bool
    let check: () -> Void

    init(status: UpdateStatus = AppUpdates.status, hasUpdater: Bool = AppUpdates.updater != nil,
         check: @escaping () -> Void = { AppUpdates.updater?.checkForUpdates() }) {
        _status = ObservedObject(wrappedValue: status); self.hasUpdater = hasUpdater; self.check = check
    }

    var body: some View {
        if hasUpdater {
            if let build = status.newBuild {
                Button(action: check) { Label("Update", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.95, green: 0.55, blue: 0.2))
                    .help("Build \(build) is ready: see what's new and install it. Your settings, presets and keeps stay.")
            } else {
                Button(action: check) { Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath") }
                    .labelStyle(.iconOnly)
                    .help("Check for a new build (this is build \(AppUpdates.currentBuild))")
            }
        }
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
