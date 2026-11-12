import SwiftUI

/// Keep that (Small Wins spec §2): the bookmark in the main bar. A click keeps the last take; its menu keeps the last
/// ten minutes. It fills while the "Kept" toast shows.
struct KeepButton: View {
    @ObservedObject var model: AppModel

    static let help = "Keep that: save your last take (⌘K)"

    private var kept: Bool { model.toast?.symbol == "bookmark.fill" }

    var body: some View {
        Button { model.keepThat() } label: { Label("Keep That", systemImage: kept ? "bookmark.fill" : "bookmark") }
            .labelStyle(.iconOnly)
            .help(Self.help)
            .contextMenu {
                Button("Keep the last 10 minutes") { model.keepLastTenMinutes() }
            }
    }
}

/// The Play menu's keep items: Keep That (⌘K) and Keep the Last 10 Minutes.
struct KeepMenuItems: View {
    @ObservedObject var model: AppModel

    static let shortcut = KeyboardShortcut("k", modifiers: .command)

    var body: some View {
        Button("Keep That") { model.keepThat() }
            .keyboardShortcut(Self.shortcut)
        Button("Keep the Last 10 Minutes") { model.keepLastTenMinutes() }
    }
}
