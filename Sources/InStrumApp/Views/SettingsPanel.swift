import SwiftUI
import InStrumCore

/// The ✦ Visuals panel: theme, macros, the theme's hero settings, Excitement, quality and comfort.
struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false

    private var state: ThemeState { model.themeState(for: model.themeID) }
    private var params: ParameterSet { ThemeRegistry.parameterSet(for: model.themeID, state: state) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Sets") {
                    SetsGallery(model: model)
                }
                section("Theme") {
                    Picker("", selection: Binding(get: { model.themeID }, set: { model.setTheme($0) })) {
                        ForEach(ThemeRegistry.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                section("Presets") {
                    PresetBar(model: model)
                }
                section("Feel") {
                    ForEach(Macro.allCases, id: \.self) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(VisualSettings.macroName(m)).font(.callout)
                                Spacer()
                                let v = state.macros[m] ?? 0
                                Text(v == 0 ? "–" : String(format: "%+.2f", v)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(get: { state.macros[m] ?? 0 }, set: { v in
                                model.saveThemeState(VisualSettings.updatedMacro(state, m, to: v), for: model.themeID)
                            }), in: -1...1)
                        }
                    }
                }
                section(ThemeRegistry.all.first { $0.id == model.themeID }?.name ?? "Theme settings") {
                    ForEach(VisualSettings.heroSpecs(for: model.themeID)) { spec in
                        ParamControl(spec: spec, value: params.baseValue(spec.id) ?? spec.defaultValue) { v in
                            model.saveThemeState(VisualSettings.updated(state, themeID: model.themeID, id: spec.id, to: v),
                                                 for: model.themeID)
                        }
                    }
                }
                if ThemeRegistry.isWorld(model.themeID) {
                    section("World") {
                        SkyControls(model: model)
                    }
                }
                section(ExcitementPanel.title) {
                    ExcitementControls(model: model)
                }
                section("Display") {
                    Picker("Quality", selection: Binding(get: { model.quality }, set: { model.setQuality($0) })) {
                        Text("Smooth").tag(QualitySetting.lite)
                        Text("Auto").tag(QualitySetting.auto)
                        Text("High").tag(QualitySetting.high)
                        Text("Ultra").tag(QualitySetting.ultra)
                    }
                    .pickerStyle(.segmented)
                    Text("Smooth is fastest with the lowest latency. Auto starts smooth and steps up when your Mac keeps up. If frames ever stall, the visuals drop to Smooth on their own.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Gentle visuals (softer flashes and sparkle)",
                           isOn: Binding(get: { model.gentleVisuals }, set: { model.setGentleVisuals($0) }))
                    Toggle("Follow the Mac's Reduce Motion",
                           isOn: Binding(get: { model.followReduceMotion }, set: { model.setFollowReduceMotion($0) }))
                    if model.reduceMotionActive {
                        Text(Self.reduceMotionCaption)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button { showAdvanced = true } label: { Label("Advanced…", systemImage: "slider.horizontal.3") }
                    Spacer()
                    Button(role: .destructive) {
                        model.saveThemeState(VisualSettings.reset(state), for: model.themeID)
                    } label: { Label("Reset theme", systemImage: "arrow.counterclockwise") }
                }
            }
            .padding(18)
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showAdvanced) { AdvancedView(model: model, isPresented: $showAdvanced) }
    }

    /// Under "Follow the Mac's Reduce Motion", while it applies (Small Wins spec §6).
    static let reduceMotionCaption = "The Mac's Reduce Motion is on, so the visuals move gently."

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
            content()
        }
    }
}
