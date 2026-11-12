import SwiftUI
import InStrumAudio

struct MainView: View {
    @ObservedObject var model: AppModel
    let audio: AudioEngine
    @State private var showSafeModePrompt = false
    @State private var showPicker = false
    @State private var volume: Float = 0.8
    @State private var showSettings = false
    @State private var showVisuals = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                MetalCanvas(model: model)
                    .overlay(alignment: .top) { ToastBanner(model: model) }
                if showVisuals {
                    SettingsPanel(model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showVisuals)
            if model.showsOnScreenKeyboard {
                OnScreenKeyboard(model: model)
                    .frame(height: 120)
            }
        }
        .background(Color(red: 0.043, green: 0.035, blue: 0.027))
        .task {
            model.willChangeInstrument = {
                PluginWindowController.shared.close()
                BuiltInPanelController.shared.close()
            }
            if model.offersSafeMode { showSafeModePrompt = true }
            else { await model.launch(skipPluginInSafeMode: false) }
            volume = model.volume
        }
        .onChange(of: model.status) { status in
            if case .needsInstrument = status { showPicker = true }
        }
        .alert("In Strum Meants didn't close properly last time", isPresented: $showSafeModePrompt) {
            Button("Start normally") { Task { await model.launch(skipPluginInSafeMode: false) } }
            Button("Start without plugin") { Task { await model.launch(skipPluginInSafeMode: true) } }
        } message: {
            Text("If an instrument plugin caused a crash, start without it and choose an instrument again.")
        }
        .sheet(isPresented: $showPicker) {
            InstrumentPicker(model: model, isPresented: $showPicker)
        }
    }

    private var statusText: String {
        switch model.status {
        case .starting: return "Starting…"
        case .safeMode: return "Safe Mode: no instrument loaded"
        case .needsInstrument: return "Choose an instrument"
        case let .playing(name): return name
        }
    }

    private var isPlaying: Bool { if case .playing = model.status { return true }; return false }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text("IN STRUM MEANTS")
                .font(.system(size: 13, weight: .heavy)).tracking(2)
                .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.63))
            Divider().frame(height: 18)
            Text(statusText).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Spacer()
            UpdateButton()
            KeepButton(model: model)
            HoldPad(model: model)
            SleepMenu(model: model)
            Button("Choose Instrument") { showPicker = true }.disabled(model.isLoading)
            Button(model.isBuiltIn ? "Open Instrument" : "Open Plugin Window") {
                if let builtIn = audio.loadedBuiltIn {
                    BuiltInPanelController.shared.show(model: model, unit: builtIn)
                } else if let unit = audio.loadedAudioUnit, case let .playing(name) = model.status {
                    PluginWindowController.shared.show(audioUnit: unit, title: name) { model.autosave() }
                }
            }
            .disabled(!isPlaying)
            Button(role: .destructive) { model.panic() } label: { Label("Panic", systemImage: "speaker.slash.fill") }
                .help("Silence everything")
            Button { showVisuals.toggle() } label: { Label("Visuals", systemImage: "sparkles") }
                .help("Theme, look and display settings")
            Button { showSettings.toggle() } label: { Label("Sound & MIDI", systemImage: "gearshape") }
                .help("Output, buffer, restart audio, MIDI keyboards and channel, touch")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(model: model) }
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(volume) },
                                  set: { volume = Float($0); model.setVolume(volume) }), in: 0...1)
                .frame(width: 110)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
