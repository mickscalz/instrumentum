import SwiftUI
import Combine
import InStrumCore

/// The row under the top bar: step back and forward through the sets, the worlds and the instruments, and transpose
/// (a capo, when it's up) without opening the instrument's window.
struct StepBar: View {
    @ObservedObject var model: AppModel
    /// Follows a transpose changed in the instrument's own window.
    @State private var tick = 0

    var body: some View {
        HStack(spacing: 22) {
            stepper("Set", model.currentSetName, help: "set (its world, instrument, ambience and mood together)") { model.stepSet(by: $0) }
                .disabled(model.isLoading)
            stepper("World", model.currentWorldName, help: "world") { model.stepWorld(by: $0) }
            stepper("Instrument", model.currentInstrumentName, help: "instrument") { model.stepInstrument(by: $0) }
                .disabled(model.isLoading)
            Spacer(minLength: 8)
            transpose
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick &+= 1 }
    }

    private func stepper(_ title: String, _ name: String, help: String, step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous \(help)")
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(width: 132, alignment: .leading)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help("Next \(help)")
        }
    }

    private var transpose: some View {
        let value: Int? = { _ = tick; return model.transpose }()
        return HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                Text("TRANSPOSE").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(Self.transposeText(value)).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
            }
            Button { model.stepTranspose(by: -1) } label: { Image(systemName: "minus") }
                .help("Down a semitone")
            Button { model.stepTranspose(by: 1) } label: { Image(systemName: "plus") }
                .help("Up a semitone (like moving a capo up a fret)")
            Button("0") { model.setTranspose(0) }
                .help("Back to concert pitch")
                .disabled(value == nil || value == 0)
        }
        .disabled(value == nil)
        .help(value == nil ? "Transpose works with the app's own instruments; a plugin has its own" : "Semitones up or down, 12 either way")
    }

    /// "0", "+3 · capo 3", "−2"; a dash for a plugin.
    static func transposeText(_ value: Int?) -> String {
        guard let value else { return "–" }
        if value > 0 { return "+\(value) · capo \(value)" }
        if value < 0 { return "−\(-value)" }
        return "0"
    }
}
