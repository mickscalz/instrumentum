import SwiftUI
import Combine
import InStrumCore

/// Decks: the DDJ-ERGO's knobs (what each one moves, and where it is now), the effects' switches, and saved sounds.
/// Everything here works from the screen too, with no controller plugged in.
struct ControllerPanel: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    /// Redraws the sliders while the controller turns the instrument's dials (those don't publish).
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sounds
                Divider()
                switches
                HStack(alignment: .top, spacing: 28) {
                    column(.left)
                    column(.right)
                }
                Divider()
                Text(Self.buttonsHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 780)
        .frame(maxHeight: 660)
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in tick &+= 1 }
    }

    static let buttonsHelp = """
        Buttons. FX1: ON switches all the effects; 1, 2 and 3 switch Echo, Reverb and Drive. \
        FX2: ON steps to your next saved sound; 1 and 2 step back and forward through the instrument's presets; \
        3 puts the effects and tone back to neutral. The DECK and SHIFT buttons change nothing.
        """

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Decks").font(.title3.weight(.semibold))
            Circle().fill(model.controllerConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            Text(model.controllerConnected ? "DDJ-ERGO connected" : "No DDJ-ERGO plugged in: the sliders here do the same")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Reset effects") { model.resetFX() }
                .help("Effects and tone back to neutral")
            Button("Default knobs") { model.resetControlLayout() }
                .disabled(model.controlLayout.isDefault)
                .help("Left side the effects and tone, right side the instrument's own dials")
        }
    }

    // MARK: - Saved sounds

    private var sounds: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved sounds").font(.headline)
            HStack {
                TextField("Name this sound", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(save)
                Button("Save", action: save)
                    .help("Saves the instrument, every one of its dials, and the effects and tone")
                if let current = model.soundPresetName, model.soundPresets.contains(where: { $0.name == current }) {
                    Button("Save over “\(current)”") { model.saveSound(named: current) }
                }
            }
            if model.soundPresets.isEmpty {
                Text("Nothing saved yet. Set the instrument and the knobs how you like them, then Save.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.soundPresets) { preset in
                        HStack {
                            Button {
                                Task { await model.applySound(preset) }
                            } label: {
                                Label(preset.name, systemImage: preset.name == model.soundPresetName ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.plain)
                            Text(preset.instrument.name).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { model.deleteSound(preset) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete this saved sound")
                        }
                    }
                }
            }
        }
    }

    private func save() {
        model.saveSound(named: newName)
        newName = ""
    }

    // MARK: - Switches

    private var switches: some View {
        HStack(spacing: 18) {
            ForEach(FXSwitch.allCases, id: \.self) { s in
                Toggle(s.displayName, isOn: Binding(get: { model.soundFX.isOn(s) }, set: { model.setFXSwitch(s, on: $0) }))
                    .toggleStyle(.switch)
                    .disabled(s != .all && !model.soundFX.isOn(.all))
            }
            Spacer()
        }
    }

    // MARK: - The knobs

    private func column(_ side: DeckSide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(side == .left ? "Left side · FX1" : "Right side · FX2").font(.headline)
            ForEach(DeckKnob.allCases, id: \.self) { knob in
                row(DeckControl(side, knob))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ control: DeckControl) -> some View {
        let target = model.controlLayout[control]
        let value = model.controlValue(target)
        return HStack(spacing: 8) {
            Text(control.displayName).font(.callout).frame(width: 96, alignment: .leading)
            Picker(control.displayName, selection: Binding(get: { model.controlLayout[control] },
                                                           set: { model.setControlTarget(control, to: $0) })) {
                ForEach(options(including: target), id: \.target) { option in
                    Text(option.name).tag(option.target)
                }
            }
            .labelsHidden()
            .frame(width: 138)
            Slider(value: Binding(get: { _ = tick; return model.controlValue(target) ?? 0 },
                                  set: { model.setControlValue(target, to: $0) }), in: 0...1)
                .disabled(value == nil)
                .frame(minWidth: 80)
        }
    }

    struct Option {
        let target: ControlTarget
        let name: String
    }

    /// Everything a knob can move: nothing, the effects and tone, this instrument's dials, the two volumes. A knob
    /// pointed at a dial this instrument doesn't have keeps its entry, so it isn't lost on the way to one that does.
    private func options(including current: ControlTarget) -> [Option] {
        Self.options(dials: model.controllerDials, including: current)
    }

    static func options(dials: [ControllerDial], including current: ControlTarget) -> [Option] {
        var out = [Option(target: .none, name: "Nothing")]
        for param in FXParam.allCases { out.append(Option(target: .fx(param), name: param.displayName)) }
        for dial in dials { out.append(Option(target: .dial(dial.index), name: "Dial \(dial.index + 1) · \(dial.name)")) }
        if case let .dial(index) = current, !dials.contains(where: { $0.index == index }) {
            out.append(Option(target: current, name: "Dial \(index + 1) · not on this instrument"))
        }
        out.append(Option(target: .volume, name: "Volume"))
        out.append(Option(target: .ambience, name: "Ambience volume"))
        return out
    }
}
