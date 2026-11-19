import SwiftUI
import Combine
import InStrumCore

/// Decks: the DDJ-ERGO's knobs, faders, wheels and buttons (what each one does, and where each knob is now), the
/// effects' switches, and saved sounds. Everything here works from the screen too, with no controller plugged in.
struct ControllerPanel: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var page = Page.knobs
    /// Redraws the sliders while the controller turns the instrument's dials (those don't publish).
    @State private var tick = 0

    enum Page: String, CaseIterable {
        case knobs = "Knobs and faders", buttons = "Buttons", wheels = "Wheels"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                sounds
                Divider()
                switches
                Picker("", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch page {
                case .knobs: knobs
                case .buttons: buttons
                case .wheels: wheels
                }
            }
            .padding(18)
        }
        .frame(width: 860)
        .frame(maxHeight: 700)
        .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in tick &+= 1 }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Decks").font(.title3.weight(.semibold))
                Circle().fill(model.controllerConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(model.controllerConnected ? "DDJ-ERGO connected" : "No DDJ-ERGO plugged in: the sliders here do the same")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset effects") { model.resetFX() }
                    .help("Effects and tone back to neutral")
                Button("Default layout") { model.resetControlLayout() }
                    .disabled(model.layoutsAreDefault)
                    .help("Every knob, button and wheel back to how it came")
            }
            Text(Self.lastTouchedLine(model.controllerLastTouched))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func lastTouchedLine(_ last: String?) -> String {
        guard let last else { return "Touch anything on the controller and it shows here, with what it does." }
        return "Last touched: \(last)"
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
                    ForEach(Array(model.soundPresets.enumerated()), id: \.element.id) { index, preset in
                        HStack {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
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

    // MARK: - Knobs and faders

    private var knobs: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                knobColumn("Left side", DeckControl.of(.left))
                knobColumn("Right side", DeckControl.of(.right))
            }
            knobColumn("Centre", DeckControl.of(.centre))
                .frame(maxWidth: 400)
        }
    }

    private func knobColumn(_ title: String, _ controls: [DeckControl]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(controls) { control in
                knobRow(control)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func knobRow(_ control: DeckControl) -> some View {
        let target = model.controlLayout[control]
        let value = model.controlValue(target)
        return HStack(spacing: 8) {
            Text(control.displayName).font(.callout).frame(width: 118, alignment: .leading)
            Picker(control.displayName, selection: Binding(get: { model.controlLayout[control] },
                                                           set: { model.setControlTarget(control, to: $0) })) {
                ForEach(options(including: target), id: \.target) { option in
                    Text(option.name).tag(option.target)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Slider(value: Binding(get: { _ = tick; return model.controlValue(target) ?? 0 },
                                  set: { model.setControlValue(target, to: $0) }), in: 0...1)
                .disabled(value == nil)
                .frame(minWidth: 70)
        }
    }

    struct Option {
        let target: ControlTarget
        let name: String
    }

    /// Everything a knob can move: nothing, the effects and tone, this instrument's dials, the two volumes, the world.
    /// A knob pointed at a dial this instrument doesn't have keeps its entry, so it isn't lost on the way to one that
    /// does.
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
        for param in WorldParam.allCases { out.append(Option(target: .world(param), name: param.displayName)) }
        return out
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                buttonColumn("Left deck", DeckKey.of(.left))
                buttonColumn("Right deck", DeckKey.of(.right))
            }
            buttonColumn("Centre", DeckKey.of(.centre))
                .frame(maxWidth: 400)
            Text("The DECK and SHIFT buttons change nothing: each button does the same on either deck, with or without SHIFT.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func buttonColumn(_ title: String, _ keys: [DeckKey]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(keys) { key in
                HStack(spacing: 8) {
                    Text(key.displayName).font(.callout).frame(width: 150, alignment: .leading)
                    Picker(key.displayName, selection: Binding(get: { model.buttonLayout[key] },
                                                               set: { model.setButtonAction(key, to: $0) })) {
                        Text(DeckAction.none.displayName).tag(DeckAction.none)
                        ForEach(DeckAction.Group.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(Self.actions(in: group), id: \.self) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func actions(in group: DeckAction.Group) -> [DeckAction] {
        DeckAction.allCases.filter { $0.group == group }
    }

    // MARK: - Wheels

    private var wheels: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wheels and rotaries").font(.headline)
            ForEach(DeckWheel.all) { wheel in
                HStack(spacing: 8) {
                    Text(wheel.displayName).font(.callout).frame(width: 200, alignment: .leading)
                    Picker(wheel.displayName, selection: Binding(get: { model.buttonLayout[wheel] },
                                                                 set: { model.setWheelTarget(wheel, to: $0) })) {
                        ForEach(WheelTarget.allCases, id: \.self) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            Text("Each deck's wheel is two controls: its top (a hand on the disc, as when scratching) and its outer edge (spun without pressing down). On the time of day the top is the precise one, ten minutes a full turn, and the edge covers ground, half an hour a turn slowly and up to three hours a turn when spun. On the moon a full turn is a quarter of its cycle, and on a list it steps eight times a turn. A rotary moves one step a click. Turning the time or the moon freezes the sky's clock; the right deck's CUE button lets it run again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
