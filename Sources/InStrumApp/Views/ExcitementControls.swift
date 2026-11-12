import SwiftUI
import InStrumCore

/// The words and the pure rules behind the Excitement controls (Fire & Neon spec §5), kept apart so they can be tested.
enum ExcitementPanel {
    static let title = "Excitement"
    static let energyTitle = "Energy"
    static let momentsTitle = "Big moments"
    static let surprisesTitle = "Surprises"
    static let buildTitle = "Build and drop"

    static let energyHelp = "Auto reads how hard and fast you play; Manual holds the world at the dial"
    static let momentsHelp = "A hard chord or a crescendo sets off the world's big moment"
    static let surprisesHelp = "Now and then, while you play, something the world doesn't usually show"
    static let buildHelp = "Climbing or swelling playing gathers the world; a big moment on top of it releases it"

    /// Searching All settings finds the group by its title or any of its controls.
    static func matches(_ search: String) -> Bool {
        search.isEmpty || "\(title) energy auto manual big moments surprises build and drop tension excitement"
            .localizedCaseInsensitiveContains(search)
    }

    static func name(_ m: ExcitementSettings.Moments) -> String {
        switch m {
        case .off: return "Off"
        case .some: return "Some"
        case .lots: return "Lots"
        }
    }

    static func name(_ s: ExcitementSettings.Surprises) -> String {
        switch s {
        case .off: return "Off"
        case .rare: return "Rare"
        case .often: return "Often"
        }
    }

    static func energyLabel(_ e: ExcitementSettings) -> String {
        e.autoEnergy ? "Energy: Auto" : "Energy: \(Int((min(1, max(0, e.manualEnergy)) * 100).rounded()))%"
    }

    /// What calms Excitement just now, in a line under the controls (nil when nothing does): gentle visuals hold big
    /// moments to Some and surprises to Rare and turn flashes into glows; Reduce Motion caps the drawn Energy at half
    /// and plays moments at half strength.
    static func calmedCaption(_ e: ExcitementSettings, gentle: Bool, reduceMotion: Bool) -> String? {
        var parts: [String] = []
        if gentle {
            var held: [String] = []
            if e.moments == .lots { held.append("big moments to Some") }
            if e.surprises == .often { held.append("surprises to Rare") }
            parts.append(held.isEmpty ? "Gentle visuals turn the flashes into glows."
                                      : "Gentle visuals hold \(held.joined(separator: " and ")), and turn the flashes into glows.")
        }
        if reduceMotion { parts.append("Reduce Motion keeps the world at half its energy and its moments at half strength.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The settings with one change made (the manual dial kept within 0…1).
    static func updated(_ e: ExcitementSettings, _ change: (inout ExcitementSettings) -> Void) -> ExcitementSettings {
        var out = e
        change(&out)
        out.manualEnergy = out.manualEnergy.isFinite ? min(1, max(0, out.manualEnergy)) : 0.5
        return out
    }
}

/// The Excitement controls themselves: Energy (Auto, or Manual with its dial), Big moments, Surprises, Build and drop.
struct ExcitementControls: View {
    @ObservedObject var model: AppModel

    private var e: ExcitementSettings { model.excitementSettings }
    private func update(_ change: (inout ExcitementSettings) -> Void) {
        model.setExcitementSettings(ExcitementPanel.updated(e, change))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(ExcitementPanel.energyTitle, selection: Binding(get: { e.autoEnergy }, set: { v in update { $0.autoEnergy = v } })) {
                    Text("Auto").tag(true)
                    Text("Manual").tag(false)
                }
                .pickerStyle(.segmented)
                if !e.autoEnergy {
                    HStack {
                        Slider(value: Binding(get: { Double(e.manualEnergy) }, set: { v in update { $0.manualEnergy = Float(v) } }),
                               in: 0...1)
                        Text("\(Int((e.manualEnergy * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text(ExcitementPanel.energyHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker(ExcitementPanel.momentsTitle, selection: Binding(get: { e.moments }, set: { v in update { $0.moments = v } })) {
                    ForEach(ExcitementSettings.Moments.allCases, id: \.self) { Text(ExcitementPanel.name($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(ExcitementPanel.momentsHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker(ExcitementPanel.surprisesTitle, selection: Binding(get: { e.surprises }, set: { v in update { $0.surprises = v } })) {
                    ForEach(ExcitementSettings.Surprises.allCases, id: \.self) { Text(ExcitementPanel.name($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(ExcitementPanel.surprisesHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(ExcitementPanel.buildTitle, isOn: Binding(get: { e.buildAndDrop }, set: { v in update { $0.buildAndDrop = v } }))
                Text(ExcitementPanel.buildHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let caption = ExcitementPanel.calmedCaption(e, gentle: model.effectiveGentleVisuals, reduceMotion: model.reduceMotionActive) {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// All settings' Excitement group, with its own reset.
struct ExcitementSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            ExcitementControls(model: model)
        } header: {
            HStack {
                Text(ExcitementPanel.title)
                Spacer()
                Button("Reset group") { model.setExcitementSettings(ExcitementSettings()) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }
}
