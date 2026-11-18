import AVFoundation
import Foundation
import InStrumAudio
import InStrumCore

/// One of the instrument's own dials as the controller's knobs count them.
public struct ControllerDial: Identifiable, Equatable {
    public let index: Int
    public let name: String
    public var id: Int { index }
}

/// What the CoreMIDI thread and the main actor share about the controller (under `AppModel.controllerLive`).
struct ControllerLive {
    var parser = MIDIParser()
    var decoder = DDJErgoDecoder()
    var layout = ControlLayout()
    var fx = SoundFX()
    /// The instrument's dials, in the knobs' order.
    var dialParams: [AUParameter] = []
    /// Waiting for the main actor: the effects moved, a volume knob moved, buttons were pressed.
    var fxMoved = false
    var volume: Double?
    var ambience: Double?
    var presses: [DeckPress] = []
    /// A visit to the main actor is already on its way.
    var syncQueued = false
}

struct DeckPress: Equatable {
    let side: DeckSide
    let button: DeckButton
}

/// The controller (a Pioneer DDJ-ERGO as a bank of knobs), the effects and tone it turns, and saved sounds.
///
/// By default **the left side is the effects and the tone** (FX1: Echo, Reverb, Drive, with CONTROL as the echo's time;
/// HI / MID / LOW and FILTER as on a mixer) and **the right side is the instrument's own dials** (FX2's knobs and the
/// right HI / MID / LOW / FILTER are its first eight). Every knob can be pointed at something else in the panel.
/// Buttons: FX1's ON switches all effects, its 1 / 2 / 3 switch Echo / Reverb / Drive; FX2's ON steps to the next saved
/// sound, its 1 and 2 step back and forward through the instrument's presets, its 3 puts the effects and tone back to
/// neutral.
extension AppModel {

    // MARK: - From the controller (CoreMIDI thread)

    /// Sound first: an effect knob moves its effect and a dial knob moves the instrument's dial here, on the CoreMIDI
    /// thread. The panel, the settings and the buttons follow on the main actor a moment later.
    public nonisolated func handleController(bytes: [UInt8], time: Double) {
        struct Work {
            var fx: SoundFX?
            var dials: [(AUParameter, Double)] = []
            var sync = false
        }
        let work: Work = controllerLive.withLockUnchecked { l in
            var work = Work()
            var heard = false
            for message in l.parser.parse(bytes) {
                guard let event = l.decoder.decode(message) else { continue }
                heard = true
                switch event {
                case let .knob(control, value):
                    switch l.layout[control] {
                    case .none:
                        break
                    case let .fx(param):
                        l.fx[param] = value
                        l.fxMoved = true
                        work.fx = l.fx
                    case let .dial(index):
                        if index < l.dialParams.count { work.dials.append((l.dialParams[index], value)) }
                    case .volume:
                        l.volume = value
                    case .ambience:
                        l.ambience = value
                    }
                case let .press(side, button):
                    l.presses.append(DeckPress(side: side, button: button))
                }
            }
            if heard && !l.syncQueued {
                l.syncQueued = true
                work.sync = true
            }
            return work
        }
        if let fx = work.fx { engine.setFX(fx) }
        for (parameter, value) in work.dials { Self.setDial(parameter, to: value) }
        guard work.sync else { return }
        noteUserActivity(at: time)
        Task { @MainActor [weak self] in
            // A knob sends hundreds of messages a second; the panel and the settings follow twenty times a second.
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.syncController()
        }
    }

    /// A dial to a knob position, 0…1, across its own range.
    nonisolated static func setDial(_ parameter: AUParameter, to value: Double) {
        let v = AUValue(max(0, min(1, value)))
        parameter.value = parameter.minValue + v * (parameter.maxValue - parameter.minValue)
    }

    /// The main actor catches up with what the controller did.
    func syncController() {
        struct Pending {
            var fx: SoundFX?
            var volume: Double?
            var ambience: Double?
            var presses: [DeckPress] = []
        }
        let pending: Pending = controllerLive.withLockUnchecked { l in
            var p = Pending()
            if l.fxMoved { p.fx = l.fx }
            p.volume = l.volume
            p.ambience = l.ambience
            p.presses = l.presses
            l.fxMoved = false
            l.volume = nil
            l.ambience = nil
            l.presses = []
            l.syncQueued = false
            return p
        }
        if let fx = pending.fx, fx != soundFX {
            soundFX = fx
            settings.soundFX = fx
            scheduleSave()
        }
        if let v = pending.volume {
            objectWillChange.send()
            engine.masterVolume = Float(v)
            settings.masterVolume = engine.masterVolume
            scheduleSave()
        }
        if let a = pending.ambience { setAmbienceVolume(a) }
        for press in pending.presses { controllerPressed(press) }
    }

    private func controllerPressed(_ press: DeckPress) {
        switch (press.side, press.button) {
        case (.left, .on): toggleFXSwitch(.all)
        case (.left, .one): toggleFXSwitch(.echo)
        case (.left, .two): toggleFXSwitch(.reverb)
        case (.left, .three): toggleFXSwitch(.drive)
        case (.right, .on): Task { await nextSound() }
        case (.right, .one): stepPatch(by: -1)
        case (.right, .two): stepPatch(by: 1)
        case (.right, .three): resetFX()
        }
    }

    // MARK: - Starting, and the controller coming and going

    /// At launch: the saved effects reach the engine, and go into the instrument's path only if they do something (or
    /// once a controller is plugged in), so without either the sound path is exactly as it always was.
    func startController() {
        engine.setFX(soundFX)
        if !soundFX.isNeutral || controllerConnected { engine.insertFX() }
        soundPresets = presets.sounds()
    }

    func controllerSourcesChanged(_ names: [String]) {
        let connected = names.contains { DDJErgoDecoder.isController(sourceName: $0) && !disabledMIDISources.contains($0) }
        guard connected != controllerConnected else { return }
        controllerConnected = connected
        guard connected else { return }
        engine.insertFX()
        lightController()
        showToast("DDJ-ERGO connected", symbol: "dial.medium")
    }

    /// The effect box's lights follow the switches.
    func lightController() {
        guard controllerConnected else { return }
        var messages: [[UInt8]] = []
        messages += DDJErgoDecoder.light(.left, .on, on: soundFX.isOn(.all))
        messages += DDJErgoDecoder.light(.left, .one, on: soundFX.isOn(.echo))
        messages += DDJErgoDecoder.light(.left, .two, on: soundFX.isOn(.reverb))
        messages += DDJErgoDecoder.light(.left, .three, on: soundFX.isOn(.drive))
        midi?.sendToController(messages)
    }

    /// The knobs count the new instrument's dials: a built-in instrument's as its panel lists them (no tuning, no
    /// arp row), a plugin's first 64 as it publishes them.
    func refreshControllerDials() {
        let all = engine.loadedAudioUnit?.parameterTree?.allParameters ?? []
        var parameters = all.filter { !Mood.parameterIdentifiers.contains($0.identifier) }
        if let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice) {
            let shown = BuiltInPanel.layout(parameters.map(\.identifier), engine: kind).dials
            let byIdentifier = parameters
            parameters = shown.compactMap { identifier in byIdentifier.first { $0.identifier == identifier } }
        } else {
            parameters = Array(parameters.filter { $0.flags.contains(.flag_IsWritable) }.prefix(64))
        }
        let list = parameters
        controllerLive.withLockUnchecked { $0.dialParams = list }
        var dials: [ControllerDial] = []
        for (index, parameter) in list.enumerated() {
            let name = parameter.displayName.isEmpty ? parameter.identifier : parameter.displayName
            dials.append(ControllerDial(index: index, name: name))
        }
        controllerDials = dials
    }

    // MARK: - Effects and tone (the panel, and the buttons)

    /// Every change to the effects from the main actor goes through here: the engine, the controller's copy, the
    /// lights and the settings all follow.
    func updateFX(_ change: (inout SoundFX) -> Void) {
        var fx = controllerLive.withLockUnchecked { $0.fx }
        change(&fx)
        controllerLive.withLockUnchecked { $0.fx = fx }
        if !fx.isNeutral { engine.insertFX() }
        engine.setFX(fx)
        soundFX = fx
        settings.soundFX = fx
        lightController()
        scheduleSave()
    }

    public func setFX(_ param: FXParam, to value: Double) { updateFX { $0[param] = value } }

    public func setFXSwitch(_ s: FXSwitch, on: Bool) { updateFX { $0.set(s, on: on) } }

    func toggleFXSwitch(_ s: FXSwitch) {
        updateFX { $0.toggle(s) }
        showToast("\(s.displayName) \(soundFX.isOn(s) ? "on" : "off")", symbol: "dial.medium")
    }

    /// The effects and tone back to neutral, every switch on.
    public func resetFX() {
        updateFX { $0 = SoundFX() }
        showToast("Effects and tone reset", symbol: "dial.medium")
    }

    // MARK: - Which knob moves what

    public func setControlTarget(_ control: DeckControl, to target: ControlTarget) {
        var layout = controlLayout
        layout[control] = target
        setControlLayout(layout)
    }

    public func resetControlLayout() { setControlLayout(ControlLayout()) }

    private func setControlLayout(_ layout: ControlLayout) {
        controlLayout = layout
        controllerLive.withLockUnchecked { $0.layout = layout }
        settings.controlLayout = layout
        scheduleSave()
    }

    /// Where the thing a knob moves is now, 0…1 (nil when there is nothing there: no such dial on this instrument).
    public func controlValue(_ target: ControlTarget) -> Double? {
        switch target {
        case .none:
            return nil
        case let .fx(param):
            return soundFX[param]
        case let .dial(index):
            let parameter: AUParameter? = controllerLive.withLockUnchecked { l in
                index < l.dialParams.count ? l.dialParams[index] : nil
            }
            guard let parameter else { return nil }
            let span = Double(parameter.maxValue) - Double(parameter.minValue)
            guard span > 0 else { return 0 }
            return max(0, min(1, (Double(parameter.value) - Double(parameter.minValue)) / span))
        case .volume:
            return Double(engine.masterVolume)
        case .ambience:
            return settings.ambience.volume
        }
    }

    /// Moves it from the panel, as the knob would.
    public func setControlValue(_ target: ControlTarget, to value: Double) {
        switch target {
        case .none:
            break
        case let .fx(param):
            setFX(param, to: value)
        case let .dial(index):
            let parameter: AUParameter? = controllerLive.withLockUnchecked { l in
                index < l.dialParams.count ? l.dialParams[index] : nil
            }
            if let parameter { Self.setDial(parameter, to: value) }
            objectWillChange.send()
        case .volume:
            objectWillChange.send()
            engine.masterVolume = Float(value)
            settings.masterVolume = engine.masterVolume
            scheduleSave()
        case .ambience:
            setAmbienceVolume(value)
        }
    }

    // MARK: - The instrument's presets from the controller

    /// Steps through a built-in instrument's presets (wrapping round). Plugins keep their presets to themselves.
    func stepPatch(by step: Int) {
        guard let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice) else {
            showToast("Preset buttons work with the app's own instruments", symbol: "dial.medium")
            return
        }
        let patches = PatchLibrary.patches(for: kind)
        guard !patches.isEmpty else { return }
        let current = patches.firstIndex { $0.id == builtInPatch?.id } ?? 0
        let next = patches[((current + step) % patches.count + patches.count) % patches.count]
        applyPatch(next)
        showToast(next.name, symbol: "pianokeys")
    }

    // MARK: - Saved sounds

    /// Saves the sound as it is now under this name (a sound with the same name is replaced): the instrument, every
    /// one of its dials (a plugin's whole state), and the effects and tone.
    public func saveSound(named rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? SoundPreset.freeName(among: soundPresets.map(\.name)) : trimmed
        guard var instrument = settings.instrument else {
            showToast("Choose an instrument first", symbol: "exclamationmark.triangle")
            return
        }
        var dials: [String: Double] = [:]
        var patchID: String?
        if BuiltInCatalog.engine(for: instrument) != nil {
            instrument.stateData = nil
            patchID = builtInPatch?.id
            for parameter in engine.loadedAudioUnit?.parameterTree?.allParameters ?? []
            where !Mood.parameterIdentifiers.contains(parameter.identifier) {
                dials[parameter.identifier] = Double(parameter.value)
            }
        } else {
            instrument.stateData = engine.currentInstrumentState()
        }
        let preset = SoundPreset(name: name, instrument: instrument, patchID: patchID, dials: dials, fx: soundFX)
        do {
            try presets.save(preset)
        } catch {
            showToast("Couldn't save “\(name)”", symbol: "exclamationmark.triangle")
            return
        }
        soundPresets = presets.sounds()
        soundPresetName = name
        settings.soundPresetName = name
        scheduleSave()
        showToast("Saved “\(name)”", symbol: "square.and.arrow.down")
    }

    /// Brings a saved sound back: its instrument (loaded if it isn't the one playing), its dials, its effects and tone.
    public func applySound(_ preset: SoundPreset) async {
        guard !isLoading else { return }
        if let kind = BuiltInCatalog.engine(for: preset.instrument) {
            let playing = settings.instrument.flatMap { BuiltInCatalog.engine(for: $0) }
            if playing != kind { await load(Self.builtInChoice(kind)) }
            guard settings.instrument.flatMap({ BuiltInCatalog.engine(for: $0) }) == kind else { return }
            // The dials are the saved ones; the name and the loudness trim are the preset's it started from.
            let base = Patch.builtIn(id: preset.patchID, engine: kind) ?? PatchLibrary.defaultPatch(for: kind)
            applyPatch(Patch(id: base.id, name: base.name, engine: kind, values: preset.dials, creditID: base.creditID,
                             trimDB: base.trimDB))
        } else {
            await load(preset.instrument)
            guard settings.instrument?.name == preset.instrument.name, case .playing = status else { return }
        }
        updateFX { $0 = preset.fx }
        soundPresetName = preset.name
        settings.soundPresetName = preset.name
        scheduleSave()
        showToast(preset.name, symbol: "dial.medium")
    }

    public func deleteSound(_ preset: SoundPreset) {
        try? presets.delete(sound: preset.name)
        soundPresets = presets.sounds()
        if soundPresetName == preset.name {
            soundPresetName = nil
            settings.soundPresetName = nil
            scheduleSave()
        }
    }

    /// The saved sound after the one last chosen (the controller's FX2 ON button).
    func nextSound() async {
        guard let next = SoundPreset.next(after: soundPresetName, in: soundPresets) else {
            showToast("No saved sounds yet: save one in Decks", symbol: "dial.medium")
            return
        }
        await applySound(next)
    }
}
