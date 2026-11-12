import SwiftUI
import InStrumCore

/// Hold the moment (Small Wins spec §4): the hourglass in the main bar. Held down, it holds the moment while pressed; a
/// double-click keeps it held until asked again (as ⌘⇧H does). It glows while time is held, however that was asked for:
/// the soft pedal too.
struct HoldPad: View {
    @ObservedObject var model: AppModel
    @State private var pressing = false

    static let help = "Hold the moment: press and hold, or double-click to keep it held (⌘⇧H)"
    /// The app's warm accent, as the title and the toast use it.
    static let glow = Color(red: 1, green: 0.85, blue: 0.63)

    var body: some View {
        let lit = model.holdShown
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Image(systemName: "hourglass")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(lit ? Self.glow : Color.primary.opacity(0.85))
            .frame(width: 30, height: 22)
            .background { shape.fill(lit ? Self.glow.opacity(0.2) : Color.primary.opacity(pressing ? 0.18 : 0.09)) }
            .overlay { shape.strokeBorder(lit ? Self.glow.opacity(0.6) : Color.primary.opacity(0.14), lineWidth: 0.5) }
            .shadow(color: lit ? Self.glow.opacity(0.35) : Color.clear, radius: 4)
            .contentShape(shape)
            .gesture(TapGesture(count: 2).onEnded { model.toggleHold() })
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        model.setHoldPressed(true)
                    }
                    .onEnded { _ in
                        pressing = false
                        model.setHoldPressed(false)
                    }
            )
            .animation(.easeOut(duration: 0.18), value: lit)
            .help(Self.help)
            .accessibilityElement()
            .accessibilityLabel("Hold the Moment")
            .accessibilityValue(Text(model.holdLatched ? "Held" : "Not held"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggleHold() }
    }
}

/// The Play menu's hold item: Hold the Moment (⌘⇧H), ticked while it is latched.
struct HoldMenuItems: View {
    @ObservedObject var model: AppModel

    static let shortcut = KeyboardShortcut("h", modifiers: [.command, .shift])

    var body: some View {
        Toggle("Hold the Moment", isOn: Binding(get: { model.holdLatched },
                                                set: { on in if on != model.holdLatched { model.toggleHold() } }))
            .keyboardShortcut(Self.shortcut)
    }
}
