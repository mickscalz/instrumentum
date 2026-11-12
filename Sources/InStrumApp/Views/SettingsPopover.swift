import SwiftUI
import Combine
import InStrumCore
import InStrumAudio

/// Sound & MIDI: where the sound goes, how safe the buffer is, which keyboards are heard, and touch.
struct SettingsPopover: View {
    @ObservedObject var model: AppModel
    @State private var buffer: UInt32 = 256

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sound & MIDI").font(.title3.weight(.semibold))
                output
                bufferSection
                Divider()
                keyboards
                Divider()
                touch
            }
            .padding(18)
        }
        .frame(width: 420)
        .frame(maxHeight: 620)
        .onAppear {
            buffer = model.bufferFrames
            model.refreshOutputDevices()
        }
        // An output plugged in while the panel is open appears without reopening it.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refreshOutputDevices() }
    }

    // MARK: - Output

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            Picker("Output", selection: Binding(get: { model.outputDeviceUID }, set: { model.selectOutputDevice($0) })) {
                Text("Mac default output").tag(String?.none)
                ForEach(model.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let uid = model.outputDeviceUID, !model.outputDevices.contains(where: { $0.uid == uid }) {
                    Text("Chosen output (not connected)").tag(Optional(uid))
                }
            }
            .labelsHidden()
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 6) {
                    Circle().fill(model.audioRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { model.restartAudio() } label: { Label("Restart audio", systemImage: "arrow.clockwise") }
                Button { model.playTestNote() } label: { Label("Test sound", systemImage: "speaker.wave.2") }
            }
            if let note = model.audioNote {
                Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Sound cutting in and out? Press Restart audio, or pick the output by name. Wired speakers or headphones are steadier than Bluetooth.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        guard model.audioRunning else { return "Stopped. Press Restart audio." }
        let rate = model.outputSampleRate
        return rate > 0 ? String(format: "Playing · %.1f kHz", rate / 1000) : "Playing"
    }

    private var bufferSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio buffer").font(.headline)
            Picker("Audio buffer", selection: Binding(get: { buffer }, set: { buffer = $0; model.setBufferFrames($0) })) {
                Text("128").tag(UInt32(128))
                Text("256").tag(UInt32(256))
                Text("512").tag(UInt32(512))
                Text("1024").tag(UInt32(1024))
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("128 is fastest, 1024 is safest. If you hear crackles or dropouts, choose 512 or 1024.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - MIDI

    private var keyboards: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MIDI keyboards").font(.headline)
                Spacer()
                Button { model.rescanMIDI() } label: { Label("Rescan", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
            }
            let names = uniqueSourceNames
            if names.isEmpty {
                Text("No MIDI keyboard found. Plug one in or switch it on, then press Rescan. Until then, play the keys on screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 0.15)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            Toggle(isOn: Binding(get: { model.isMIDISourceEnabled(name) },
                                                 set: { model.setMIDISource(name, enabled: $0) })) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(model.midiActive(name) ? Color.green : Color.secondary.opacity(0.3))
                                        .frame(width: 8, height: 8)
                                    Text(name).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                Text("The dot lights when that keyboard sends a note. Switch off any you don't want heard.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Channel")
                Picker("Channel", selection: Binding(get: { model.midiChannel }, set: { model.setMIDIChannel($0) })) {
                    Text("All channels").tag(Int?.none)
                    ForEach(1...16, id: \.self) { Text("Channel \($0)").tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            HStack {
                Text("Keyboard layout")
                Picker("Keyboard layout", selection: Binding(get: { model.keyboardRange }, set: { model.setKeyboardRange($0) })) {
                    ForEach(KeyboardRange.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Text(Self.keyboardLayoutCaption)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under Keyboard layout (Small Wins spec §2): the keep gesture lives on the keyboard's top three black keys.
    static let keyboardLayoutCaption = "Tap its top three black keys together, twice, to keep a take."

    private var uniqueSourceNames: [String] {
        var seen = Set<String>()
        return model.midiSourceNames.filter { seen.insert($0).inserted }
    }

    // MARK: - Touch

    private var touch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Touch").font(.headline)
            Picker("Touch", selection: Binding(get: { model.touchCurve }, set: { model.setTouchCurve($0) })) {
                ForEach(TouchCurve.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Heavy keeps soft playing soft. Light makes loud notes easier.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Hold the moment with")
                Picker("Hold the moment with", selection: Binding(get: { model.holdPedal }, set: { model.setHoldPedal($0) })) {
                    ForEach(HoldPedal.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.top, 6)
            Text(Self.holdCaption)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Under "Hold the moment with" (Small Wins spec §4).
    static let holdCaption = "While it's down, the sky, the weather and the world stand still and your notes fill the moment. The hourglass and ⌘⇧H hold it too."
}
