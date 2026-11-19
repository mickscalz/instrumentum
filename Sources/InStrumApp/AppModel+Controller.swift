import AppKit
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
    var buttons = ButtonLayout()
    var fx = SoundFX()
    /// The instrument's dials, in the knobs' order.
    var dialParams: [AUParameter] = []
    /// Waiting for the main actor: the effects moved; a volume moved; world knobs moved (their positions); wheels
    /// turned (their units so far); buttons were pressed; the control last touched.
    var fxMoved = false
    var volume: Double?
    var ambience: Double?
    var world: [WorldParam: Double] = [:]
    var turns: [DeckWheel: Double] = [:]
    var presses: [DeckKey] = []
    var last: DeckEvent?
    /// A visit to the main actor is already on its way.
    var syncQueued = false
}

/// The controller (a Pioneer DDJ-ERGO as a control surface), the effects and tone it turns, and saved sounds.
///
/// Out of the box: **the left side's knobs are the effects and the tone, the right side's are the instrument's own
/// dials, and the faders, sliders and centre knobs are the world** (its mood, its ambience, the wind, and the app's
/// volume on MASTER). **The left deck's buttons are the instrument and the playing, the right deck's are the world and
/// its sky**; the jog wheels scrub the time of day and the moon. Every knob, button and wheel can be pointed at
/// something else in the Decks panel (`ControlLayout`, `ButtonLayout`).
extension AppModel {

    // MARK: - From the controller (CoreMIDI thread)

    /// Sound first: an effect knob moves its effect and a dial knob moves the instrument's dial here, on the CoreMIDI
    /// thread. The world, the panel, the settings, the wheels and the buttons follow on the main actor a moment later.
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
                l.last = event
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
                    case let .world(param):
                        l.world[param] = value
                    }
                case let .press(side, button):
                    l.presses.append(DeckKey(side, button))
                case let .turn(wheel, units):
                    l.turns[wheel, default: 0] += units
                case .unknown:
                    break
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
        queueControllerSync()
    }

    /// A keyboard's volume knob or slider (controller 7), on the CoreMIDI thread: the app's volume follows on the main
    /// actor, and the message never reaches the instrument (or it would be turned down twice).
    nonisolated func keyboardVolume(_ volume: Double, time: Double) {
        let sync: Bool = controllerLive.withLockUnchecked { l in
            l.volume = volume
            guard !l.syncQueued else { return false }
            l.syncQueued = true
            return true
        }
        guard sync else { return }
        noteUserActivity(at: time)
        queueControllerSync()
    }

    /// A knob sends hundreds of messages a second; the main actor follows twenty times a second.
    private nonisolated func queueControllerSync() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.syncController()
        }
    }

    /// A dial to a knob position, 0…1, across its own range.
    nonisolated static func setDial(_ parameter: AUParameter, to value: Double) {
        let v = AUValue(max(0, min(1, value)))
        parameter.value = parameter.minValue + v * (parameter.maxValue - parameter.minValue)
    }

    /// The main actor catches up with what the controller (or a keyboard's volume knob) did.
    func syncController() {
        struct Pending {
            var fx: SoundFX?
            var volume: Double?
            var ambience: Double?
            var world: [WorldParam: Double] = [:]
            var turns: [DeckWheel: Double] = [:]
            var presses: [DeckKey] = []
            var last: DeckEvent?
        }
        let pending: Pending = controllerLive.withLockUnchecked { l in
            var p = Pending()
            if l.fxMoved { p.fx = l.fx }
            p.volume = l.volume
            p.ambience = l.ambience
            p.world = l.world
            p.turns = l.turns
            p.presses = l.presses
            p.last = l.last
            l.fxMoved = false
            l.volume = nil
            l.ambience = nil
            l.world = [:]
            l.turns = [:]
            l.presses = []
            l.last = nil
            l.syncQueued = false
            return p
        }
        if let fx = pending.fx, fx != soundFX {
            soundFX = fx
            settings.soundFX = fx
            scheduleSave()
        }
        if let v = pending.volume { applyVolume(v) }
        if let a = pending.ambience { setAmbienceVolume(a) }
        if !pending.world.isEmpty { applyWorld(pending.world) }
        if !pending.turns.isEmpty { applyTurns(pending.turns) }
        for key in pending.presses { perform(buttonLayout[key]) }
        if let last = pending.last {
            let text = describe(last)
            if text != controllerLastTouched { controllerLastTouched = text }
        }
    }

    /// What the panel says was last touched.
    func describe(_ event: DeckEvent) -> String {
        func place(_ side: DeckSide, _ name: String) -> String { side == .centre ? name : "\(side.displayName) \(name)" }
        switch event {
        case let .knob(control, _):
            return "\(place(control.side, control.displayName)): \(targetName(controlLayout[control]))"
        case let .press(side, button):
            let key = DeckKey(side, button)
            return "\(place(side, key.displayName)): \(buttonLayout[key].displayName)"
        case let .turn(wheel, _):
            return "\(wheel.displayName): \(buttonLayout[wheel].displayName)"
        case let .unknown(what):
            return "Not mapped: \(what)"
        }
    }

    /// A knob target's name, with the dial's own name when the instrument has it.
    public func targetName(_ target: ControlTarget) -> String {
        switch target {
        case .none: return "Nothing"
        case let .fx(param): return param.displayName
        case let .dial(index):
            guard let dial = controllerDials.first(where: { $0.index == index }) else { return "Dial \(index + 1)" }
            return "Dial \(index + 1) · \(dial.name)"
        case .volume: return "Volume"
        case .ambience: return "Ambience volume"
        case let .world(param): return param.displayName
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
        controllerLit = [:]   // a controller just plugged in has every light off
        lightController()
        showToast("DDJ-ERGO connected", symbol: "dial.medium")
    }

    /// Whether a button's light should be on, for the actions that are a switch; nil for the rest (their lights are
    /// left alone).
    func isLit(_ action: DeckAction) -> Bool? {
        switch action {
        case .fxAll: return soundFX.isOn(.all)
        case .fxEcho: return soundFX.isOn(.echo)
        case .fxReverb: return soundFX.isOn(.reverb)
        case .fxDrive: return soundFX.isOn(.drive)
        case .hold: return holdLatched
        case .mute: return mutedVolume != nil
        case .ambience: return settings.ambience.enabled
        case .gentle: return gentleVisuals
        case .weatherRandom: return settings.sky.weatherMode == .randomBeautiful
        case .sleepTimer: return sleepTimerRunning
        default: return nil
        }
    }

    /// The controller's lights follow the switches: only the lights that changed are sent.
    func lightController() {
        guard controllerConnected else { return }
        var messages: [[UInt8]] = []
        for key in DeckKey.all {
            guard let on = isLit(buttonLayout[key]), controllerLit[key.id] != on else { continue }
            controllerLit[key.id] = on
            messages += DDJErgoDecoder.light(key.side, key.button, on: on)
        }
        if !messages.isEmpty { midi?.sendToController(messages) }
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

    // MARK: - Which knob, button and wheel does what

    public func setControlTarget(_ control: DeckControl, to target: ControlTarget) {
        var layout = controlLayout
        layout[control] = target
        setLayouts(knobs: layout, buttons: buttonLayout)
    }

    public func setButtonAction(_ key: DeckKey, to action: DeckAction) {
        var layout = buttonLayout
        layout[key] = action
        setLayouts(knobs: controlLayout, buttons: layout)
    }

    public func setWheelTarget(_ wheel: DeckWheel, to target: WheelTarget) {
        var layout = buttonLayout
        layout[wheel] = target
        wheelResidue[wheel.id] = nil
        setLayouts(knobs: controlLayout, buttons: layout)
    }

    /// Every knob, button and wheel back to how it came.
    public func resetControlLayout() { setLayouts(knobs: ControlLayout(), buttons: ButtonLayout()) }

    public var layoutsAreDefault: Bool { controlLayout.isDefault && buttonLayout.isDefault }

    private func setLayouts(knobs: ControlLayout, buttons: ButtonLayout) {
        controlLayout = knobs
        buttonLayout = buttons
        controllerLive.withLockUnchecked { l in
            l.layout = knobs
            l.buttons = buttons
        }
        settings.controlLayout = knobs
        settings.buttonLayout = buttons
        lightController()
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
        case let .world(param):
            return param.knob(value: worldValue(param))
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
            applyVolume(value)
        case .ambience:
            setAmbienceVolume(value)
        case let .world(param):
            applyWorld([param: value])
        }
    }

    /// The app's volume from a knob, a wheel or a keyboard: it ends a mute, and the save waits for the knob to settle.
    func applyVolume(_ value: Double) {
        objectWillChange.send()
        mutedVolume = nil
        engine.masterVolume = Float(max(0, min(1, value)))
        settings.masterVolume = engine.masterVolume
        lightController()
        scheduleSave()
    }

    // MARK: - The world from the knobs

    /// A world setting as it is now, in its own units.
    func worldValue(_ param: WorldParam) -> Double {
        let sky = settings.sky
        switch param {
        case .moodEnergy: return mood.energy
        case .moodWarmth: return mood.warmth
        case .moodBrightness: return mood.brightness
        case .moodSpace: return mood.space
        case .moodMotion: return mood.motion
        case .timeOfDay: return sky.frozenHour
        case .moonPhase: return sky.frozenPhase
        case .wind: return sky.windScale
        case .mist: return sky.mistScale
        case .clouds: return sky.cloudScale
        case .stars: return sky.starScale
        case .rain: return sky.rainScale
        case .snow: return sky.snowScale
        case .lightning: return sky.lightningFrequency
        case .moonSize: return sky.moonSize
        case .closeness: return settings.ambience.closeness
        case .energy: return Double(excitementSettings.manualEnergy)
        case .intensity, .speed, .density, .glow, .chaos, .temperature:
            guard let macro = param.macro else { return 0 }
            return themeState(for: themeID).macros[macro] ?? 0
        }
    }

    /// Knob positions (0…1) for world settings, applied together: the mood once, the sky once, the look once. Turning
    /// the time of day or the moon freezes the sky's clock, so it stays where the knob put it.
    func applyWorld(_ knobs: [WorldParam: Double]) {
        var nextMood = mood
        var moodChanged = false
        var sky = settings.sky
        var skyChanged = false
        var look: ThemeState?
        for (param, knob) in knobs {
            let value = param.value(knob: knob)
            switch param {
            case .moodEnergy: nextMood.energy = value; moodChanged = true
            case .moodWarmth: nextMood.warmth = value; moodChanged = true
            case .moodBrightness: nextMood.brightness = value; moodChanged = true
            case .moodSpace: nextMood.space = value; moodChanged = true
            case .moodMotion: nextMood.motion = value; moodChanged = true
            case .timeOfDay: sky.frozenHour = value; sky.timeMode = .frozen; skyChanged = true
            case .moonPhase: sky.frozenPhase = value; sky.timeMode = .frozen; skyChanged = true
            case .wind: sky.windScale = value; skyChanged = true
            case .mist: sky.mistScale = value; skyChanged = true
            case .clouds: sky.cloudScale = value; skyChanged = true
            case .stars: sky.starScale = value; skyChanged = true
            case .rain: sky.rainScale = value; skyChanged = true
            case .snow: sky.snowScale = value; skyChanged = true
            case .lightning: sky.lightningFrequency = value; skyChanged = true
            case .moonSize: sky.moonSize = value; skyChanged = true
            case .closeness: setAmbienceCloseness(value)
            case .energy:
                var excitement = excitementSettings
                excitement.autoEnergy = false
                excitement.manualEnergy = Float(value)
                setExcitementSettings(excitement)
            case .intensity, .speed, .density, .glow, .chaos, .temperature:
                guard let macro = param.macro else { break }
                var state = look ?? themeState(for: themeID)
                state.macros[macro] = value
                look = state
            }
        }
        if moodChanged { setMood(nextMood) }
        if skyChanged { setSkyFromController(sky) }
        if let look { saveThemeState(look, for: themeID) }
    }

    /// The sky from the controller: says so once when the clock stops, so a frozen sky is never a surprise.
    private func setSkyFromController(_ sky: SkySettings) {
        let froze = sky.timeMode == .frozen && settings.sky.timeMode != .frozen
        objectWillChange.send()   // `settings` isn't published: tell the panels
        setSky(sky)
        if froze { showToast("Time frozen: the right CUE button lets it run again", symbol: "clock") }
        lightController()
    }

    // MARK: - Wheels

    /// What the wheels turned since the last visit: scrubbing targets move by the units turned, list targets take
    /// their whole steps and keep the rest for next time.
    func applyTurns(_ turns: [DeckWheel: Double]) {
        for (wheel, units) in turns {
            let target = buttonLayout[wheel]
            switch target {
            case .none:
                break
            case .timeOfDay:
                var sky = settings.sky
                sky.frozenHour = WheelTarget.hour(sky.frozenHour, turnedBy: units)
                sky.timeMode = .frozen
                setSkyFromController(sky)
            case .moonPhase:
                var sky = settings.sky
                sky.frozenPhase = WheelTarget.phase(sky.frozenPhase, turnedBy: units)
                sky.timeMode = .frozen
                setSkyFromController(sky)
            case .volume:
                applyVolume(Double(engine.masterVolume) + units * WheelTarget.volumePerUnit)
            case .ambience:
                setAmbienceVolume(settings.ambience.volume + units * WheelTarget.volumePerUnit)
            case .presets, .instruments, .sounds, .worlds, .sets, .weather:
                let turned = WheelTarget.steps(from: (wheelResidue[wheel.id] ?? 0) + units)
                wheelResidue[wheel.id] = turned.left
                if turned.steps != 0 { step(target, by: turned.steps) }
            }
        }
    }

    /// Steps a list target on by `count` (round its ends).
    func step(_ target: WheelTarget, by count: Int) {
        switch target {
        case .presets: stepPatch(by: count)
        case .instruments: stepInstrument(by: count)
        case .sounds: stepSound(by: count)
        case .worlds: stepWorld(by: count)
        case .sets: stepSet(by: count)
        case .weather: stepWeather(by: count)
        case .none, .timeOfDay, .moonPhase, .volume, .ambience: break
        }
    }

    // MARK: - Buttons

    /// Does what a button asks. Every action says what it did in a toast, since the hands are on the controller.
    func perform(_ action: DeckAction) {
        switch action {
        case .none:
            break
        case .fxAll: toggleFXSwitch(.all)
        case .fxEcho: toggleFXSwitch(.echo)
        case .fxReverb: toggleFXSwitch(.reverb)
        case .fxDrive: toggleFXSwitch(.drive)
        case .fxReset: resetFX()
        case .soundNext: stepSound(by: 1)
        case .soundPrevious: stepSound(by: -1)
        case .soundSave: saveSound(named: "")
        case .sound1, .sound2, .sound3, .sound4, .sound5, .sound6, .sound7, .sound8:
            guard let slot = action.soundSlot else { break }
            guard slot < soundPresets.count else {
                showToast("No saved sound \(slot + 1) yet: save one in Decks", symbol: "dial.medium")
                break
            }
            let preset = soundPresets[slot]
            Task { await applySound(preset) }
        case .presetNext: stepPatch(by: 1)
        case .presetPrevious: stepPatch(by: -1)
        case .presetReload: reloadPatch()
        case .instrumentNext: stepInstrument(by: 1)
        case .instrumentPrevious: stepInstrument(by: -1)
        case .hold:
            toggleHold()
            showToast(holdLatched ? "Holding the moment" : "Hold off", symbol: "hourglass")
        case .panic:
            panic()
            showToast("All notes off", symbol: "speaker.slash")
        case .keepThat: keepThat()
        case .keepTenMinutes: keepLastTenMinutes()
        case .testNote: playTestNote()
        case .mute: toggleMute()
        case .worldNext: stepWorld(by: 1)
        case .worldPrevious: stepWorld(by: -1)
        case .setNext: stepSet(by: 1)
        case .setPrevious: stepSet(by: -1)
        case .setRestore:
            guard let set = activeSetID.flatMap({ SetLibrary.set(id: $0) }) else {
                showToast("No set chosen yet", symbol: "square.grid.2x2")
                break
            }
            Task { await restoreSet() }
            showToast("\(set.name), as designed", symbol: "square.grid.2x2")
        case .surprise:
            surprise()
            showToast("A new look", symbol: "sparkles")
        case .reactionNext:
            let all = allReactions()
            let current = all.firstIndex { $0.name == reactionName }
            guard let next = WheelTarget.index(after: current, by: 1, count: all.count) else { break }
            setReaction(all[next])
            showToast("Reaction: \(all[next].name)", symbol: "sparkles")
        case .moodReset:
            let designed = activeSetID.flatMap { SetLibrary.set(id: $0) }?.mood ?? .neutral
            setMood(designed)
            showToast("Mood back to the set's", symbol: "dial.medium")
        case .weatherNext: stepWeather(by: 1)
        case .weatherPrevious: stepWeather(by: -1)
        case .weatherRandom:
            var sky = settings.sky
            sky.weatherMode = sky.weatherMode == .randomBeautiful ? .pick : .randomBeautiful
            setSkyFromController(sky)
            showToast(sky.weatherMode == .randomBeautiful ? "Weather: random, beautiful" : "Weather: staying as it is", symbol: "cloud.sun")
        case .weatherClear, .weatherRain, .weatherStorm, .weatherSnow:
            if let kind = action.weather { pickWeather(kind) }
        case .timeMode:
            var sky = settings.sky
            let modes = TimeMode.allCases
            let current = modes.firstIndex(of: sky.timeMode)
            guard let next = WheelTarget.index(after: current, by: 1, count: modes.count) else { break }
            sky.timeMode = modes[next]
            objectWillChange.send()
            setSky(sky)
            showToast("Time: \(Self.timeModeName(sky.timeMode))", symbol: "clock")
        case .timeMorning, .timeMidday, .timeEvening, .timeNight:
            guard let hour = action.hour else { break }
            var sky = settings.sky
            sky.frozenHour = hour
            sky.timeMode = .frozen
            objectWillChange.send()
            setSky(sky)
            showToast(action.displayName, symbol: "clock")
        case .ambience:
            setAmbienceEnabled(!settings.ambience.enabled)
            showToast(settings.ambience.enabled ? "Ambience on" : "Ambience off", symbol: "leaf")
        case .gentle:
            setGentleVisuals(!gentleVisuals)
            showToast(gentleVisuals ? "Gentle visuals on" : "Gentle visuals off", symbol: "sparkles")
        case .sleepTimer:
            if sleepTimerRunning {
                setSleepTimer(minutes: nil)
                showToast("Sleep timer off", symbol: "moon")
            } else {
                setSleepTimer(minutes: Self.controllerSleepMinutes)
                showToast("Sleep timer: \(Self.controllerSleepMinutes) minutes", symbol: "moon")
            }
        case .fullScreen:
            toggleFullScreen()
        }
        lightController()
    }

    /// The sleep timer a button starts.
    static let controllerSleepMinutes = 30

    static func timeModeName(_ mode: TimeMode) -> String {
        switch mode {
        case .quick: return "quick day"
        case .realTime: return "real time"
        case .frozen: return "frozen"
        }
    }

    /// Silences the app, or brings the volume back to where it was. The saved volume is never the muted one.
    func toggleMute() {
        objectWillChange.send()
        if let was = mutedVolume {
            mutedVolume = nil
            engine.masterVolume = was
            showToast("Sound on", symbol: "speaker.wave.2")
        } else {
            mutedVolume = engine.masterVolume
            engine.masterVolume = 0
            showToast("Muted", symbol: "speaker.slash")
        }
    }

    /// The app's window in and out of full screen (nothing to do when there is no window, as in tests).
    func toggleFullScreen() {
        guard let app = NSApp, let window = app.mainWindow ?? app.keyWindow ?? app.windows.first else { return }
        window.toggleFullScreen(nil)
    }

    // MARK: - Stepping through the lists

    /// Steps through a built-in instrument's presets (wrapping round). Plugins keep their presets to themselves.
    func stepPatch(by step: Int) {
        guard let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice) else {
            showToast("Preset buttons work with the app's own instruments", symbol: "dial.medium")
            return
        }
        let patches = PatchLibrary.patches(for: kind)
        let current = patches.firstIndex { $0.id == builtInPatch?.id }
        guard let next = WheelTarget.index(after: current, by: step, count: patches.count) else { return }
        applyPatch(patches[next])
        showToast(patches[next].name, symbol: "pianokeys")
    }

    /// The instrument's dials back to its preset's.
    func reloadPatch() {
        guard let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice),
              let patch = Patch.builtIn(id: builtInPatch?.id, engine: kind) else {
            showToast("Preset buttons work with the app's own instruments", symbol: "dial.medium")
            return
        }
        applyPatch(patch)
        showToast("\(patch.name), as it came", symbol: "pianokeys")
    }

    /// Steps through the app's own instruments (wrapping round). A step asked for while one is loading is dropped.
    func stepInstrument(by step: Int) {
        guard !isLoading else { return }
        let instruments = BuiltInCatalog.instruments
        let current = instruments.firstIndex { $0.name == settings.instrument?.name }
        guard let next = WheelTarget.index(after: current, by: step, count: instruments.count) else { return }
        let instrument = instruments[next]
        showToast(instrument.name, symbol: "pianokeys")
        Task { await choose(instrument) }
    }

    /// Steps through the saved sounds (wrapping round).
    func stepSound(by step: Int) {
        let current = soundPresets.firstIndex { $0.name == soundPresetName }
        guard let next = WheelTarget.index(after: current, by: step, count: soundPresets.count) else {
            showToast("No saved sounds yet: save one in Decks", symbol: "dial.medium")
            return
        }
        let preset = soundPresets[next]
        Task { await applySound(preset) }
    }

    /// Steps through the worlds (wrapping round).
    func stepWorld(by step: Int) {
        let worlds = ThemeRegistry.all
        let current = worlds.firstIndex { $0.id == themeID }
        guard let next = WheelTarget.index(after: current, by: step, count: worlds.count) else { return }
        setTheme(worlds[next].id)
        showToast(worlds[next].name, symbol: "globe")
    }

    /// Steps through the sets (wrapping round): the world, its instrument, its ambience and its mood together.
    func stepSet(by step: Int) {
        guard !isLoading else { return }
        let sets = SetLibrary.all
        let current = sets.firstIndex { $0.id == activeSetID }
        guard let next = WheelTarget.index(after: current, by: step, count: sets.count) else { return }
        let set = sets[next]
        showToast(set.name, symbol: "square.grid.2x2")
        Task { await applySet(set.id) }
    }

    /// Steps through the weathers the app offers (wrapping round), and stops the random weather so it stays.
    func stepWeather(by step: Int) {
        let kinds = WeatherKind.offered
        let current = kinds.firstIndex(of: settings.sky.weather)
        guard let next = WheelTarget.index(after: current, by: step, count: kinds.count) else { return }
        pickWeather(kinds[next])
    }

    func pickWeather(_ kind: WeatherKind) {
        var sky = settings.sky
        sky.weather = kind
        sky.weatherMode = .pick
        objectWillChange.send()
        setSky(sky)
        showToast("Weather: \(SkyControls.weatherName(kind).lowercased())", symbol: "cloud.sun")
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
}
