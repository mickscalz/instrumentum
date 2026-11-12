import AppKit
import AVFoundation
import SwiftUI
import InStrumAudio
import InStrumCore

/// The window for the app's own instruments: presets, dials, tuning and the song that inspired it.
struct BuiltInPanel: View {
    @ObservedObject var model: AppModel
    let unit: BuiltInInstrumentAU
    @State private var refresh = 0

    private var allParameters: [AUParameter] { unit.parameterTree?.allParameters ?? [] }

    /// The dial list: every dial but tuning, the hidden mood dials and those in the Arp row.
    private var dials: [AUParameter] {
        let shown = Set(Self.layout(allParameters.map(\.identifier), engine: unit.engine).dials)
        return allParameters.filter { shown.contains($0.identifier) }
    }

    /// The Arp row's dials, in its order (none for an engine without an arp).
    private var arpParameters: [AUParameter] {
        Self.layout(allParameters.map(\.identifier), engine: unit.engine).arp.compactMap { parameter($0) }
    }

    private func parameter(_ identifier: String) -> AUParameter? {
        unit.parameterTree?.allParameters.first { $0.identifier == identifier }
    }

    private func binding(_ p: AUParameter) -> Binding<Double> {
        Binding(get: { _ = refresh; return Double(p.value) },
                set: { p.value = AUValue($0); refresh += 1 })
    }

    private func stepper(_ identifier: String) -> Binding<Double> {
        Binding(get: { _ = refresh; return Double(parameter(identifier)?.value ?? 0) },
                set: { parameter(identifier)?.value = AUValue($0.rounded()); refresh += 1 })
    }

    private var currentPatch: Patch? { model.builtInPatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(unit.engine.displayName).font(.title2.weight(.semibold))
                Spacer()
                Menu(currentPatch?.name ?? "Presets") {
                    ForEach(PatchLibrary.patches(for: unit.engine)) { patch in
                        Button(patch.displayName) { model.applyPatch(patch); refresh += 1 }
                    }
                }
                .frame(width: 200)
            }
            VStack(spacing: 10) {
                ForEach(dials, id: \.address) { p in
                    HStack {
                        Text(p.displayName).frame(width: 90, alignment: .leading)
                        Slider(value: binding(p), in: Double(p.minValue)...Double(p.maxValue))
                    }
                }
            }
            if !arpParameters.isEmpty {
                Divider()
                arpRow
            }
            Divider()
            HStack(spacing: 24) {
                Stepper(value: stepper("fineTune"), in: -50...50, step: 1) {
                    Text("Fine tune \(Int(stepper("fineTune").wrappedValue)) cents").monospacedDigit()
                }
                Stepper(value: stepper("transpose"), in: -12...12, step: 1) {
                    Text("Transpose \(Int(stepper("transpose").wrappedValue))").monospacedDigit()
                }
            }
            .help("Fine tune locks onto a recording that sits slightly off standard pitch.")
            if let credit = currentPatch?.credit ?? PatchLibrary.defaultPatch(for: unit.engine).credit {
                InspiredByCard(credit: credit).frame(width: 400)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - The Arp row

    /// The Arp row (Fire & Neon spec §4.4): an instrument with an arpeggiator shows its arp's own dials together in one
    /// labelled row instead of among the other dials: the mode, the rate and the split as menus, the tempo as a stepper in
    /// BPM, Blue Depth's Blink as a slider.
    private var arpRow: some View {
        HStack(alignment: .top) {
            Text("Arp").font(.headline).frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(arpParameters, id: \.address) { p in arpControl(p) }
            }
        }
        .help("The arpeggiator: it plays the notes you hold one after another, in time")
    }

    @ViewBuilder private func arpControl(_ p: AUParameter) -> some View {
        switch p.identifier {
        case "arp":
            choiceMenu(p, Self.arpModes.enumerated().map { ArpChoice(tag: $0.offset, name: $0.element) })
        case "rate":
            choiceMenu(p, Self.arpRates.enumerated().map { ArpChoice(tag: $0.offset, name: $0.element) })
        case "split":
            choiceMenu(p, [ArpChoice(tag: 0, name: "Off")] + (28...60).map { ArpChoice(tag: $0, name: Self.splitName(Double($0))) })
        case "tempo":
            Stepper(value: stepper(p.identifier), in: Double(p.minValue)...Double(p.maxValue), step: 1) {
                Text("\(p.displayName) \(Int(stepper(p.identifier).wrappedValue)) BPM").monospacedDigit()
            }
        default:
            HStack {
                Text(p.displayName).frame(width: 60, alignment: .leading)
                Slider(value: binding(p), in: Double(p.minValue)...Double(p.maxValue))
            }
        }
    }

    private func choiceMenu(_ p: AUParameter, _ options: [ArpChoice]) -> some View {
        let selection = Binding<Int>(
            get: {
                _ = refresh
                let v = Int(Double(p.value).rounded())
                return options.contains { $0.tag == v } ? v : (options.first?.tag ?? 0)
            },
            set: { (v: Int) in p.value = AUValue(v); refresh += 1 })
        return Picker(p.displayName, selection: selection) {
            ForEach(options) { Text($0.name).tag($0.tag) }
        }
        .pickerStyle(.menu)
        .frame(width: 220, alignment: .leading)
    }

    /// One entry of an Arp row menu: the dial's value and its name.
    struct ArpChoice: Identifiable, Hashable {
        let tag: Int
        let name: String
        var id: Int { tag }
    }

    /// The panel's two groups of an engine's dials (identifiers, in the engine's order): the dial list, and the Arp row
    /// (Fire & Neon spec §4.4), which gathers the arp's own dials (`BuiltInEngine.arpDials`) for an engine that has an
    /// arp and is empty for one that hasn't. Tuning and the hidden mood dials are in neither.
    static func layout(_ identifiers: [String], engine: BuiltInEngine) -> (dials: [String], arp: [String]) {
        let shown = identifiers.filter { !Mood.parameterIdentifiers.contains($0) && $0 != "fineTune" && $0 != "transpose" }
        let arp = engine.arpDials.filter { shown.contains($0) }
        return (dials: shown.filter { !arp.contains($0) }, arp: arp)
    }

    /// The arp's modes (0 Off … 5 Random) and its rates against the tempo (0 a quarter … 5 a thirty-second), as Replicant
    /// Brass numbers them.
    static let arpModes = ["Off", "Up", "Down", "Up-down", "Played", "Random"]
    static let arpRates = ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32"]

    /// The split point as the row names it: Off below E1 (28), else the note, C3 for 48.
    static func splitName(_ value: Double) -> String {
        let n = Int(value.rounded())
        guard n >= 28 else { return "Off" }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[n % 12])\(n / 12 - 1)"
    }
}

/// Shows the built-in instrument panel in its own window.
@MainActor
final class BuiltInPanelController: NSObject, NSWindowDelegate {
    static let shared = BuiltInPanelController()
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func show(model: AppModel, unit: BuiltInInstrumentAU) {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        onClose = { model.autosave() }
        let host = NSHostingController(rootView: BuiltInPanel(model: model, unit: unit))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = unit.engine.displayName
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === self.window }

    func close() {
        guard let w = window else { return }
        w.delegate = nil
        onClose?()
        w.close()
        w.contentViewController = nil
        window = nil
        onClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        window?.contentViewController = nil
        window = nil
        onClose = nil
    }
}
