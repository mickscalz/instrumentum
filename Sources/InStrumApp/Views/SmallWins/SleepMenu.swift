import SwiftUI
import AppKit
import InStrumCore

/// The sleep timer (Small Wins spec §3): the moon in the main bar, with its menu (Off, 15–90 minutes) and the time left
/// beside it while it runs ("23 min", then "45 s"). Any click or key in the app counts as being awake, so it can wake a
/// fading world as a note does.
struct SleepMenu: View {
    @ObservedObject var model: AppModel
    @State private var monitor: Any?

    static let help = "Sleep timer: drift to night and silence"

    /// The time left as the moon shows it: whole minutes, rounded up, from a minute; then whole seconds.
    static func label(remaining: Double) -> String {
        let s = max(0, remaining)
        if s >= 60 { return "\(Int((s / 60).rounded(.up))) min" }
        return "\(Int(s.rounded(.up))) s"
    }

    var body: some View {
        Menu {
            Button("Off") { model.setSleepTimer(minutes: nil) }
            Divider()
            ForEach(SleepFade.choices, id: \.self) { minutes in
                Button("\(minutes) minutes") { model.setSleepTimer(minutes: minutes) }
            }
        } label: {
            if let remaining = model.sleepRemaining {
                Label(Self.label(remaining: remaining), systemImage: "moon.fill")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else {
                Label("Sleep Timer", systemImage: "moon")
                    .labelStyle(.iconOnly)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.help)
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let model = self.model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            model.noteUserActivity()
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
