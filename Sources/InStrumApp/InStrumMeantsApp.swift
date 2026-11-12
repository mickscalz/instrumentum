import SwiftUI
import AppKit
import InStrumCore
import InStrumAudio

/// Owns the long-lived pieces: sound engine, MIDI input and app model.
@MainActor
final class AppContainer: ObservableObject {
    let audio: AudioEngine
    let model: AppModel
    private var midi: MIDIInput?

    init() {
        BuiltInCatalog.registerAll()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("In Strum Meants", isDirectory: true)
        audio = AudioEngine()
        model = AppModel(engine: audio, store: SettingsStore(directory: support),
                         launchGuard: LaunchGuard(directory: support),
                         presets: PresetStore(directory: support.appendingPathComponent("Presets", isDirectory: true)))
        let model = self.model
        midi = try? MIDIInput(
            onBytes: { bytes, time in model.handleMIDI(bytes: bytes, time: time) },
            onSourcesChanged: { names, removed in
                Task { @MainActor in model.midiSourcesChanged(names: names, removed: removed) }
            })
        model.midi = midi   // hands over the keyboards switched off in Sound & MIDI
        model.startWatchingReduceMotion()   // the Mac's Reduce Motion, followed from the first frame
        if let names = midi?.sourceNames, !names.isEmpty { model.midiSourcesChanged(names: names, removed: false) }
    }
}

public struct InStrumMeantsApp: App {
    @StateObject private var container = AppContainer()

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
        AppUpdates.start()
    }

    public var body: some Scene {
        Window("In Strum Meants", id: "main") {
            MainView(model: container.model, audio: container.audio)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .commands {
            UpdateCommands()
            PlayMenu(model: container.model)
        }
    }
}
