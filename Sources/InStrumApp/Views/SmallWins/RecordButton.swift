import SwiftUI

/// The Record button in the main bar, beside Keep: a click records the instrument to a WAV file, a second click stops
/// and saves it. While it records, the circle fills red and the running time shows beside it. Its menu shows the
/// recordings in the Finder.
struct RecordButton: View {
    @ObservedObject var model: AppModel

    static let help = "Record what you play (⌘R)"

    var body: some View {
        Button { model.toggleRecording() } label: {
            if model.isRecording {
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(AppModel.keptLength(model.recordingSeconds)).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Stop Recording")
            } else {
                Label("Record", systemImage: "record.circle").labelStyle(.iconOnly)
            }
        }
        .help(Self.help)
        .contextMenu {
            Button("Show Recordings in Finder") { model.showRecordingsInFinder() }
        }
    }
}

/// The Play menu's record items: Record / Stop Recording (⌘R) and Show Recordings in Finder.
struct RecordMenuItems: View {
    @ObservedObject var model: AppModel

    static let shortcut = KeyboardShortcut("r", modifiers: .command)

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "Record") { model.toggleRecording() }
            .keyboardShortcut(Self.shortcut)
        Button("Show Recordings in Finder") { model.showRecordingsInFinder() }
    }
}
