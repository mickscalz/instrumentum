import Foundation
import AppKit
import os
import InStrumCore
import InStrumAudio

/// Wires keyboard → sound → visuals, and keeps settings safe.
@MainActor
public final class AppModel: ObservableObject {
    public enum Status: Equatable {
        case starting
        case safeMode
        case needsInstrument(message: String?)
        case playing(instrumentName: String)
    }

    public static let screenVelocity: UInt8 = 90
    static let autosaveInterval: TimeInterval = 30
    static let stableAfter: UInt64 = 10_000_000_000   // ns

    @Published public private(set) var status: Status = .starting
    @Published public private(set) var midiSourceNames: [String] = []
    /// True while a plugin is being loaded; new choices are ignored until it finishes.
    @Published public private(set) var isLoading = false
    @Published public private(set) var touchCurve: TouchCurve
    /// The active visual theme.
    @Published public private(set) var themeID: String
    /// Bumped whenever any visual setting changes (the canvas re-reads them).
    @Published public internal(set) var visualsVersion = 0
    @Published public private(set) var quality: QualitySetting
    @Published public private(set) var gentleVisuals: Bool
    /// Name of the active reaction style ("Custom" after editing the mapping).
    @Published public private(set) var reactionName: String
    public private(set) var reaction: ReactionMap
    public let presets: PresetStore
    /// Where kept takes go (`~/Music/In Strum Meants/Takes`; tests use their own folder).
    var takeStore = TakeStore(directory: TakeStore.defaultDirectory)
    /// Called just before the instrument changes (e.g. to close the old plugin's window).
    public var willChangeInstrument: (@MainActor () -> Void)?
    /// True when the previous run ended without settling (offer Safe Mode before launching).
    public let offersSafeMode: Bool

    /// True when no MIDI keyboard is listened to (none connected, or all switched off).
    public var showsOnScreenKeyboard: Bool { midiSourceNames.allSatisfy { disabledMIDISources.contains($0) } }
    public var volume: Float { engine.masterVolume }

    // nonisolated: touched from the CoreMIDI and render threads.
    nonisolated let engine: InstrumentEngine
    struct Live {
        var parser = MIDIParser()
        var state = PerformanceState()
        var events: [PerformanceEvent] = []
        var touch: TouchCurve = .normal
        /// 1…16 to listen to one MIDI channel only; nil for all.
        var channel: Int?
        /// The last key pressed, pedal moved or click (system uptime); -∞ before any.
        var lastActivity = -Double.infinity
        /// What the instrument heard over the last two hours (Keep that), in memory only.
        var keeper = TakeKeeper()
    }
    nonisolated let live = OSAllocatedUnfairLock(uncheckedState: Live())

    /// The loaded instrument's own dials (knobs/sliders in its window).
    @Published public private(set) var dials: [DialInfo] = []
    /// The preset on the loaded built-in instrument (nil for plugins).
    @Published public private(set) var builtInPatch: Patch?
    /// Dials moved since the instrument loaded (offered first in the mapping editor).
    @Published public private(set) var movedDials: [UInt64] = []
    var dialReader: DialReader?
    private struct DialLive { var pending: [UInt64: Double] = [:]; var moved: [UInt64] = [] }
    nonisolated private let dialLive = OSAllocatedUnfairLock(uncheckedState: DialLive())
    /// What the instrument's pulse follows: the loaded built-in engine (nil for a plugin, or none) and its dials by
    /// identifier, in their own units. Written on the main actor when an instrument loads or a preset is applied, and
    /// from the dial reader's thread as the dials move.
    private struct PulseLive { var engine: BuiltInEngine?; var values: [String: Double] = [:] }
    nonisolated private let pulseLive = OSAllocatedUnfairLock(uncheckedState: PulseLive())

    /// The loaded instrument's own pulse (spec §7.6): Blue Depth's arp, its Tempo with Blink as the gate, while Blink is
    /// up. Nil for every other instrument, a plugin, or Blue Depth at Blink 0. It follows the presets and the dials as
    /// they move; the canvas hands it to `SceneDirector.instrumentPulse` every frame.
    public nonisolated var instrumentPulse: InstrumentPulse? {
        pulseLive.withLockUnchecked { InstrumentPulse(engine: $0.engine, values: $0.values) }
    }

    /// The grand's half of the step (Storms spec §3, §4.2, §9.2), which the canvas hands `SceneDirector` before every
    /// step: the morph Single Note Grand sings at, as the engine reads it back (the player's pressure over the Morph floor,
    /// or the world's forced morph, smoothed 80 ms up and 250 ms down), so the strike distance and the voice's distortion
    /// are one number; and whether it hears the same key struck four or more times at 2 a second or faster. 0 and false
    /// for every other instrument and a plugin.
    public nonisolated var instrumentPressure: Float { engine.morphInUse }
    public nonisolated var instrumentRepeat: Bool { engine.isRepeating }

    /// The morph the world forces on the grand's voice (`SceneDirector.forcedMorph`), which the canvas hands over after
    /// every step: 0…1, or nil (or a negative value) to let it go, when the morph returns to the player's pressure over
    /// 250 ms. The engine keeps it in an atomic read once per control block. Every other instrument and a plugin ignore it.
    public func forceMorph(_ morph: Float?) { engine.setForcedMorph(morph) }

    private let store: SettingsStore
    private let launchGuard: LaunchGuard
    var settings: AppSettings
    private var launched = false
    private var autosaveTimer: Timer?
    /// The sleep timer (Small Wins spec §3): its fade, its 10 Hz ticker (running only while there is something to do)
    /// and its clock (system uptime, as the playing's; tests set their own). Never saved.
    var sleepFade = SleepFade()
    var sleepTicker: Timer?
    var sleepClock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var watchdogTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    /// The Mac's Reduce Motion, once the app follows it (`startWatchingReduceMotion`).
    var reduceMotionWatcher: ReduceMotionWatching?

    public init(engine: InstrumentEngine, store: SettingsStore, launchGuard: LaunchGuard, presets: PresetStore) {
        self.presets = presets
        self.engine = engine
        self.store = store
        self.launchGuard = launchGuard
        let loaded = store.load()
        self.settings = loaded
        self.touchCurve = loaded.touchCurve
        self.themeID = ThemeRegistry.resolve(loaded.themeID)
        self.quality = loaded.quality
        self.gentleVisuals = loaded.gentleVisuals
        self.reactionName = loaded.reactionName
        self.reaction = loaded.reaction
            ?? ReactionPresets.all.first { $0.name == loaded.reactionName }?.map
            ?? ReactionPresets.expressivePianist
        self.offersSafeMode = launchGuard.beginLaunch()
        self.disabledMIDISources = Set(loaded.disabledMIDISources)
        outputDeviceUID = loaded.outputDeviceUID
        midiChannel = loaded.midiChannel
        live.withLockUnchecked { l in
            l.touch = loaded.touchCurve
            l.channel = loaded.midiChannel
            l.keeper.setRange(low: loaded.keyboardRange.low, high: loaded.keyboardRange.high)
        }
        let closeness = loaded.ambience.closeness
        ambienceLive.withLockUnchecked { $0.closeness = closeness }
        activeSetID = loaded.activeSetID.flatMap { SetLibrary.set(id: $0) }?.id
        mood = activeSetID.flatMap { SetLibrary.set(id: $0) }?.mood ?? .neutral
        sceneControls = SceneControls(holdPedal: loaded.holdPedal, breath: loaded.breath)
    }

    // MARK: - Launch and instruments

    /// Runs once; later calls do nothing.
    public func launch(skipPluginInSafeMode: Bool) async {
        guard !launched else { return }
        launched = true
        engine.masterVolume = settings.masterVolume
        engine.bufferFrames = settings.bufferFrames
        do { try engine.start() } catch {
            status = .needsInstrument(message: "Sound output couldn't start. Check your speakers or headphones, then reopen the app.")
            return
        }
        if let uid = settings.outputDeviceUID, !engine.selectOutputDevice(uid: uid) {
            engine.selectOutputDevice(uid: nil)
            outputDeviceUID = nil
            settings.outputDeviceUID = nil
            audioNote = "Your chosen output wasn't found, so the sound is playing to the Mac's default output. Pick it again here once it's connected."
        }
        refreshOutputDevices()
        engine.ambienceVolume = Float(settings.ambience.volume)
        engine.ambienceEnabled = settings.ambience.enabled
        await engine.startAmbience()
        startAutosave()
        startWatchdog()
        if offersSafeMode && skipPluginInSafeMode {
            status = .safeMode
            launchGuard.markStable()
            return
        }
        // "Opens on what's new" (the owner's standing rule): a build with sets the last launch didn't see opens on the
        // newest of them, once, instead of restoring the last set.
        if settings.opensOnWhatsNew {
            await openOnWhatsNew()
            return
        }
        guard let choice = settings.instrument else {
            status = .needsInstrument(message: nil)
            return
        }
        await load(choice)
    }

    public func choose(_ plugin: PluginInfo) async {
        guard !isLoading else { return }
        await load(plugin.choice())
    }

    private func load(_ choice: InstrumentChoice) async {
        isLoading = true
        defer { isLoading = false }
        willChangeInstrument?()
        do {
            try await engine.loadInstrument(choice)
        } catch let AudioEngineError.pluginNotFound(name) {
            status = .needsInstrument(message: "“\(name)” couldn't be found. It may have been uninstalled or moved. Choose an instrument below.")
            return
        } catch {
            status = .needsInstrument(message: "“\(choice.name)” couldn't be loaded. If it needs you to sign in, open its own app first, then choose it again.")
            return
        }
        settings.instrument = choice
        let kind = BuiltInCatalog.engine(for: choice)
        pulseLive.withLockUnchecked { $0 = PulseLive(engine: kind) }   // a new instrument: its own dials, or no pulse
        watchDials()
        updateBuiltInPatch()
        engine.setMood(mood)   // a freshly loaded built-in starts neutral
        status = .playing(instrumentName: choice.name)
        autosave()
        let launchGuard = self.launchGuard
        Task { try? await Task.sleep(nanoseconds: Self.stableAfter); launchGuard.markStable() }
    }

    // MARK: - Playing (any thread)

    /// Called on the CoreMIDI thread. Sound first, visuals second. Messages on other channels than the chosen one are ignored.
    public nonisolated func handleMIDI(bytes raw: [UInt8], time: Double) {
        let channel = live.withLockUnchecked { $0.channel }
        guard MIDIChannelFilter.passes(raw, channel: channel) else { return }
        perform(raw, time: time)
    }

    /// The take keeper hears what the instrument heard; the keep gesture keeps the take before it, on the main actor.
    private nonisolated func perform(_ raw: [UInt8], time: Double) {
        let bytes = live.withLockUnchecked { $0.touch }.transform(raw)
        engine.send(bytes)
        let gesture: Double? = live.withLockUnchecked { l in
            var started: Double?
            for message in l.parser.parse(bytes) {
                if Self.isActivity(message) { l.lastActivity = time }
                l.events += l.state.apply(message, at: time)
                if let start = l.keeper.record(message, at: time) { started = start }
            }
            return started
        }
        if let start = gesture { Task { @MainActor [weak self] in self?.keepThat(at: start) } }
    }

    public func playFromScreen(note: UInt8, down: Bool) {
        let bytes: [UInt8] = down ? [0x90, note, Self.screenVelocity] : [0x80, note, 0]
        perform(bytes, time: ProcessInfo.processInfo.systemUptime)   // the screen keys ignore the channel filter
    }

    public func midiSourcesChanged(names: [String], removed: Bool) {
        midiSourceNames = names
        if removed { panic() }
    }

    public func panic() {
        engine.panic()
        ambienceLive.withLockUnchecked { $0.pendingThunder = nil; $0.pendingThunderQueue.removeAll(); $0.pendingEvents.removeAll() }   // nothing on its way
        let now = ProcessInfo.processInfo.systemUptime
        live.withLockUnchecked { l in
            l.events += l.state.reset()
            l.keeper.releaseAll(at: now)   // nothing held through a panic is still down in a take
        }
    }

    /// Called by the renderer each frame.
    public nonisolated func drainEvents() -> [PerformanceEvent] {
        live.withLockUnchecked { l in
            let out = l.events
            l.events.removeAll(keepingCapacity: true)
            return out
        }
    }

    public nonisolated var intensity: Float {
        live.withLockUnchecked { l in
            l.state.decay(to: ProcessInfo.processInfo.systemUptime)
            return l.state.intensity
        }
    }

    public nonisolated var audioLevel: Float { engine.audioLevel }
    public nonisolated var soundReading: SoundReading { engine.soundReading }

    /// True when the loaded instrument is one of the app's own.
    public var isBuiltIn: Bool { settings.instrument.flatMap { BuiltInCatalog.engine(for: $0) } != nil }

    /// Sets a built-in instrument's dials to a preset and saves it. Does nothing for plugins.
    public func applyPatch(_ patch: Patch) {
        guard let choice = settings.instrument, BuiltInCatalog.engine(for: choice) == patch.engine else { return }
        engine.applyPatch(patch)
        builtInPatch = patch
        follow(patch)
        stopTheArp()
        autosave()
    }

    /// Hands the director's step to the built-in instrument (Storms spec §3, §4.1): the tension, every step, and the drop
    /// on the one step it lands. The canvas calls it after each step, on the main thread; the engine keeps both in atomics
    /// it reads once per control block (the plan's ruling), so the sound follows within a step. With build and drop on
    /// the tension is Excitement's (the engine adds the player's pressure itself); with it off it is the pressure, so
    /// aftertouch drives the riser alone. Plugins and every other engine ignore both.
    public func cueInstrument(_ cue: InstrumentCue) {
        engine.setTension(cue.tension)
        if cue.drop { engine.triggerDrop() }
    }

    /// The pulse follows a preset's dials (and then the dials themselves as they move, through the dial reader).
    private func follow(_ patch: Patch) {
        pulseLive.withLockUnchecked { l in for (identifier, value) in patch.values { l.values[identifier] = value } }
    }

    /// Blue Depth's arp and echo run on their own clock, so a change of preset, world or set while it plays would keep
    /// them going (spec §13, review focus 1). All notes off stops the arp and empties the echo (the reverb's tail rings
    /// on), and the next phrase starts a fresh grid; it reaches the visuals as a keyboard's would, so they let go with
    /// the sound. Every other instrument rings on through these changes, as it always has.
    private func stopTheArp() {
        guard settings.instrument.flatMap({ BuiltInCatalog.engine(for: $0) }) == .blueDepth else { return }
        perform([0xB0, 123, 0], time: ProcessInfo.processInfo.systemUptime)
    }

    private func updateBuiltInPatch() {
        guard let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice) else { builtInPatch = nil; return }
        if let id = engine.builtInPatchID, let saved = PatchLibrary.all.first(where: { $0.id == id && $0.engine == kind }) {
            builtInPatch = saved
        } else {
            let first = PatchLibrary.defaultPatch(for: kind)
            engine.applyPatch(first)
            builtInPatch = first
            follow(first)
        }
    }

    private func watchDials() {
        dialReader = nil
        let live = dialLive
        live.withLockUnchecked { $0 = DialLive() }
        movedDials = []
        guard let unit = engine.loadedAudioUnit else { dials = []; return }
        let reader = DialReader(audioUnit: unit)
        let initial = reader.currentValues()
        live.withLockUnchecked { $0.pending = initial }
        // The pulse follows the dials by identifier, in their own units (Tempo in BPM), from where they are now.
        var units: [UInt64: (identifier: String, low: Double, span: Double)] = [:]
        for p in unit.parameterTree?.allParameters ?? [] {
            units[p.address] = (p.identifier, Double(p.minValue), Double(p.maxValue) - Double(p.minValue))
        }
        let named = units, pulse = pulseLive
        pulse.withLockUnchecked { l in
            for (address, v) in initial { if let u = named[address] { l.values[u.identifier] = u.low + u.span * v } }
        }
        reader.onChange = { info, value in
            live.withLockUnchecked { l in
                l.pending[info.address] = value
                if !l.moved.contains(info.address) { l.moved.append(info.address) }
            }
            if let u = named[info.address] { pulse.withLockUnchecked { $0.values[u.identifier] = u.low + u.span * value } }
        }
        dialReader = reader
        dials = reader.dials
    }

    /// Dial positions that changed since the last call (the renderer feeds them to the visuals).
    public func drainDialChanges() -> [UInt64: Double] {
        let (pending, moved) = dialLive.withLockUnchecked { l -> ([UInt64: Double], [UInt64]) in
            let p = l.pending
            l.pending.removeAll(keepingCapacity: true)
            return (p, l.moved)
        }
        if moved.count != movedDials.count { movedDials = moved }
        return pending
    }

    /// Friendly name for any input, including this instrument's dials.
    public func inputName(_ id: InputID) -> String {
        if id.rawValue.hasPrefix("dials."), let a = UInt64(id.rawValue.dropFirst("dials.".count)),
           let d = dials.first(where: { $0.address == a }) {
            return "Instrument: \(d.name)"
        }
        return id.displayName
    }

    /// Inputs offered in the mapping editor: built-ins, dials you've moved (or all, if there are few), and any in use.
    public func mappingInputs(inUse: [InputID]) -> [InputID] {
        let dialIDs = (dials.count <= 40 ? dials.map(\.address) : movedDials).map { InputID.dial($0) }
        return MappingEdits.inputs(seen: inUse + dialIDs)
    }

    // MARK: - Settings

    public func setVolume(_ v: Float) {
        engine.masterVolume = v
        settings.masterVolume = engine.masterVolume
        autosave()
    }

    public var bufferFrames: UInt32 { engine.bufferFrames }

    public func setTouchCurve(_ curve: TouchCurve) {
        touchCurve = curve
        live.withLockUnchecked { $0.touch = curve }
        settings.touchCurve = curve
        autosave()
    }

    public func setBufferFrames(_ frames: UInt32) {
        engine.bufferFrames = frames
        settings.bufferFrames = frames
        autosave()
    }

    // MARK: - Sound & MIDI settings

    /// Every sound output on the Mac (refreshed while the settings are open and by the watchdog).
    @Published public private(set) var outputDevices: [OutputDevice] = []
    /// The chosen output's unique ID; nil follows the Mac's default output.
    @Published public private(set) var outputDeviceUID: String?
    /// What the sound last needed fixing, in plain words (shown in Sound & MIDI).
    @Published public private(set) var audioNote: String?
    /// 1…16 to listen to one MIDI channel only; nil for all channels.
    @Published public private(set) var midiChannel: Int?
    /// MIDI inputs switched off (by name).
    @Published public private(set) var disabledMIDISources: Set<String>
    /// The MIDI input (weak: the app container owns it). Setting it hands over the saved on/off choices.
    public weak var midi: MIDIControlling? {
        didSet { midi?.setDisabled(disabledMIDISources) }
    }

    public var audioRunning: Bool { engine.isRunning }
    public var outputSampleRate: Double { engine.outputSampleRate }

    public func refreshOutputDevices() {
        let now = engine.outputDevices
        if now != outputDevices { outputDevices = now }
    }

    /// nil plays to the Mac's default output.
    public func selectOutputDevice(_ uid: String?) {
        guard uid != outputDeviceUID || audioNote != nil else { return }   // already playing there: don't cut the sound
        if engine.selectOutputDevice(uid: uid) {
            outputDeviceUID = uid
            settings.outputDeviceUID = uid
            audioNote = nil
            autosave()
        } else {
            audioNote = "That output isn't available right now. Check it's switched on and connected, then try again."
        }
        refreshOutputDevices()
    }

    public func restartAudio() {
        panic()
        engine.restartAudio()
        audioNote = engine.isRunning ? "Sound restarted." : "The sound couldn't restart. Try choosing another output."
        refreshOutputDevices()
    }

    /// Run by the watchdog every couple of seconds.
    public func checkAudioHealth() {
        if let note = engine.checkHealth() {
            panic()   // anything held when the sound dropped would otherwise hang
            if note != audioNote { audioNote = note }
            refreshOutputDevices()
        }
    }

    /// Plays middle C for a moment, to check the sound without a keyboard.
    public func playTestNote() {
        playFromScreen(note: 60, down: true)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.playFromScreen(note: 60, down: false)
        }
    }

    /// nil listens to every channel.
    public func setMIDIChannel(_ channel: Int?) {
        let c = channel.flatMap { (1...16).contains($0) ? $0 : nil }
        guard c != midiChannel else { return }
        live.withLockUnchecked { $0.channel = c }
        panic()   // after the switch: notes held on the old channel would never get their note-off
        midiChannel = c
        settings.midiChannel = c
        autosave()
    }

    public func isMIDISourceEnabled(_ name: String) -> Bool { !disabledMIDISources.contains(name) }

    public func setMIDISource(_ name: String, enabled: Bool) {
        var set = disabledMIDISources
        if enabled { set.remove(name) } else { set.insert(name) }
        guard set != disabledMIDISources else { return }
        disabledMIDISources = set
        settings.disabledMIDISources = set.sorted()
        midi?.setDisabled(set)
        if !enabled { panic() }   // after it's disconnected, so nothing it holds can hang
        autosave()
    }

    public func rescanMIDI() {
        midi?.rescan()
        panic()   // keys or the pedal held while the keyboards reconnect would otherwise hang
    }

    /// True while this MIDI input is sending notes (lights its dot).
    public func midiActive(_ name: String) -> Bool {
        guard let t = midi?.lastActivity(name) else { return false }
        return ProcessInfo.processInfo.systemUptime - t < 0.25
    }

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAudioHealth() }
        }
    }

    // MARK: - Visuals

    public func setTheme(_ id: String) {
        let resolved = ThemeRegistry.resolve(id)
        guard resolved != themeID else { return }
        stopTheArp()
        // Storms Review focus 4: no thunder queued in the last world arrives in this one, whatever this one plays.
        ambienceLive.withLockUnchecked { $0.pendingThunderQueue.removeAll(); $0.pendingEvents.removeAll() }   // nor any one-shot
        engine.clearAmbienceThunder()
        themeID = resolved
        settings.themeID = resolved
        visualsVersion += 1
        autosave()
    }

    public func themeState(for id: String) -> ThemeState {
        settings.themeStates[ThemeRegistry.resolve(id)] ?? ThemeState()
    }

    public func saveThemeState(_ state: ThemeState, for id: String) {
        settings.themeStates[ThemeRegistry.resolve(id)] = state
        visualsVersion += 1
        scheduleSave()
    }

    public func setQuality(_ q: QualitySetting) {
        quality = q; settings.quality = q; visualsVersion += 1; autosave()
    }

    // MARK: - Sky and mood

    /// The set's mood: shapes the world, the visual, the built-in instrument and the ambience.
    @Published public private(set) var mood: Mood = .neutral

    public func setMood(_ m: Mood) {
        mood = m
        engine.setMood(m)
        visualsVersion += 1
    }

    public var skySettings: SkySettings { settings.sky }

    public func setSkySettings(_ s: SkySettings) { setSky(s) }

    // MARK: - Sets

    /// The Set last applied (nil until one is chosen).
    @Published public private(set) var activeSetID: String?

    /// True when the world, its visual, the built-in instrument or preset, or the ambience differ from the active set.
    public var isSetModified: Bool {
        guard let set = activeSetID.flatMap({ SetLibrary.set(id: $0) }) else { return false }
        if themeID != set.worldID { return true }
        if ThemeRegistry.parameterSet(for: set.worldID, state: themeState(for: set.worldID)).choice("visual") != set.visual { return true }
        guard let patch = PatchLibrary.all.first(where: { $0.id == set.patchID }) else { return true }
        if settings.instrument.flatMap({ BuiltInCatalog.engine(for: $0) }) != patch.engine || builtInPatch?.id != patch.id { return true }
        return settings.ambience != set.ambience
    }

    private var applyingSet = false

    /// Everything at once: the world and its visual, the built-in instrument and preset, the ambience and the mood.
    /// A tap while a set (or an instrument) is still loading is ignored, so two quick taps can't interleave.
    public func applySet(_ id: String) async {
        guard !isLoading, !applyingSet, let set = SetLibrary.set(id: id),
              let patch = PatchLibrary.all.first(where: { $0.id == set.patchID }) else { return }
        applyingSet = true
        defer { applyingSet = false }
        setTheme(set.worldID)
        var state = themeState(for: set.worldID)
        state.values["visual"] = .choice(set.visual)
        saveThemeState(state, for: set.worldID)
        mood = set.mood
        if settings.instrument.flatMap({ BuiltInCatalog.engine(for: $0) }) != patch.engine {
            await load(Self.builtInChoice(patch.engine))
        }
        applyPatch(patch)
        settings.ambience = set.ambience
        engine.ambienceEnabled = set.ambience.enabled
        engine.ambienceVolume = Float(set.ambience.volume)
        let closeness = set.ambience.closeness
        ambienceLive.withLockUnchecked { $0.closeness = closeness; $0.sent = nil }
        setMood(set.mood)
        activeSetID = set.id
        settings.activeSetID = set.id
        autosave()
    }

    /// Puts the active set back as it was designed.
    public func restoreSet() async {
        guard let id = activeSetID else { return }
        await applySet(id)
    }

    /// The first launch of a build whose gallery holds a newer newest set, or more sets, than the last launch saw (or of
    /// settings saved before the rule, once): the newest set, its world, visual, instrument and preset loaded, instead of
    /// the set and instrument last used. The gallery is then recorded as seen, so later launches restore the player's
    /// last set as before. A first install (no settings) has seen everything and starts as it always has.
    private func openOnWhatsNew() async {
        let newest = SetLibrary.newest
        settings.markSetsSeen()
        // The saved instrument may already be the newest set's engine: load it first, with its saved state, as the set
        // only loads an engine that differs from the saved one (and nothing is loaded yet).
        let newestEngine: BuiltInEngine? = PatchLibrary.all.first { $0.id == newest.patchID }?.engine
        if let choice = settings.instrument, let kind = BuiltInCatalog.engine(for: choice), kind == newestEngine {
            await load(choice)
        }
        await applySet(newest.id)
        if activeSetID != newest.id { autosave() }   // it didn't apply: the gallery is still seen
    }

    static func builtInChoice(_ kind: BuiltInEngine) -> InstrumentChoice {
        let d = BuiltInCatalog.description(for: kind)
        return InstrumentChoice(name: kind.displayName, componentType: d.componentType, componentSubType: d.componentSubType,
                                componentManufacturer: d.componentManufacturer)
    }

    /// The Living Sky's settings (persisted; the canvas picks them up through `visualsVersion`).
    public func setSky(_ s: SkySettings) {
        settings.sky = s
        visualsVersion += 1
        scheduleSave()   // the day-length, time and moon sliders drag this
    }

    /// The Living Sky panel's "Meteors tonight" line (spec §6.3; nil with no shower active), from the sky the canvas
    /// last drew. It changes only when the line does, so the panel redraws only then.
    @Published public private(set) var meteorsTonight: String?
    public func setMeteorsTonight(_ line: String?) { if line != meteorsTonight { meteorsTonight = line } }

    // MARK: - Ambience

    /// At most this often (seconds) does a world's soundscape reach the engine.
    nonisolated static let ambienceInterval = 0.1
    private struct AmbienceLive {
        var sent: AmbienceScene?
        var lastSend = -Double.infinity
        var pendingThunder: Double?
        var pendingWave: Double?
        var pendingBubbles: Double?
        /// Thunder on its way, held by the throttle, with when the world asked (its delay runs from then).
        var pendingThunderQueue: [(thunder: QueuedThunder, at: Double)] = []
        /// The world's one-shots (Fire & Neon), held the same way.
        var pendingEvents: [(event: AmbienceEvent, at: Double)] = []
        var closeness = 0.5
    }
    /// The engine's thunder queue holds 16: so does the throttle's.
    nonisolated static let thunderQueueLimit = 16
    /// The engine holds 32 one-shots waiting: so does the throttle.
    nonisolated static let ambienceEventLimit = 32
    nonisolated private let ambienceLive = OSAllocatedUnfairLock(uncheckedState: AmbienceLive())

    public var ambienceSettings: AmbienceSettings { settings.ambience }

    /// From the render loop (any thread): hands the world's soundscape to the engine at most ten times a second,
    /// and only when it has really changed (a level by > 0.01, the activity by > 0.05, the speed by > 0.02, the key
    /// the player is in) or thunder, a wave or a burst of bubbles is due. The user's closeness leans the world's own
    /// closeness; a thunderclap, a wave or a bubble burst held back by the throttle goes next time (two waves or two
    /// bursts inside one tenth of a second go as the bigger one), unless the next scene has no surf or no bubbles (a
    /// new world): a beach's wave never crashes in the next world, and the submarine's bubbles never rise in it. Queued
    /// thunder held back goes next time too, every roll of it (16 at most, the oldest giving way), its delay shortened by
    /// the time it waited, so it still arrives when the strike's distance says; it stays behind when the next scene has
    /// no thunder roll. The world's one-shots (Fire & Neon: a boom, a crack, a rockfall, a car passing, a wiper's sweep)
    /// go the same way (32 at most), each staying behind when the next scene has its source silent.
    public nonisolated func updateAmbience(_ s: AmbienceScene, at t: Double = ProcessInfo.processInfo.systemUptime) {
        let out: AmbienceScene? = ambienceLive.withLockUnchecked { a in
            var scene = s
            scene.closeness = min(1, max(0, s.closeness + (a.closeness - 0.5)))
            if let thunder = s.thunder { a.pendingThunder = thunder }
            if let wave = s.wave { a.pendingWave = max(wave, a.pendingWave ?? 0) }
            if s.level(.surf) <= 0 { a.pendingWave = nil }   // the world changed: its waves stay behind
            if let burst = s.bubbleBurst { a.pendingBubbles = max(burst, a.pendingBubbles ?? 0) }
            if s.level(.bubbles) <= 0 { a.pendingBubbles = nil }   // and its bubbles too
            if !s.thunderQueue.isEmpty {
                a.pendingThunderQueue += s.thunderQueue.map { (thunder: $0, at: t) }
                let over = a.pendingThunderQueue.count - Self.thunderQueueLimit
                if over > 0 { a.pendingThunderQueue.removeFirst(over) }
            }
            if s.level(.thunderRoll) <= 0 { a.pendingThunderQueue.removeAll() }   // and its thunder
            if !s.events.isEmpty {
                a.pendingEvents += s.events.map { (event: $0, at: t) }
                let over = a.pendingEvents.count - Self.ambienceEventLimit
                if over > 0 { a.pendingEvents.removeFirst(over) }
            }
            a.pendingEvents.removeAll { s.level($0.event.source) <= 0 }   // and its one-shots
            scene.thunder = a.pendingThunder
            scene.wave = a.pendingWave
            scene.bubbleBurst = a.pendingBubbles
            scene.thunderQueue = a.pendingThunderQueue.map {
                QueuedThunder(delay: max(0, $0.thunder.delay - max(0, t - $0.at)), strength: $0.thunder.strength)
            }
            scene.events = a.pendingEvents.map { held in
                var e = held.event
                e.delay = max(0, e.delay - max(0, t - held.at))
                return e
            }
            guard t - a.lastSend >= Self.ambienceInterval - 1e-9 else { return nil }
            if scene.thunder == nil, scene.wave == nil, scene.bubbleBurst == nil, scene.thunderQueue.isEmpty, scene.events.isEmpty,
               let previous = a.sent, !Self.ambienceChanged(previous, scene) { return nil }
            a.sent = scene
            a.lastSend = t
            a.pendingThunder = nil
            a.pendingWave = nil
            a.pendingBubbles = nil
            a.pendingThunderQueue.removeAll()
            a.pendingEvents.removeAll()
            return scene
        }
        if let out { engine.setAmbience(out) }
    }

    nonisolated static func ambienceChanged(_ a: AmbienceScene, _ b: AmbienceScene) -> Bool {
        let sources = Set(a.levels.keys).union(b.levels.keys)
        if sources.contains(where: { abs(a.level($0) - b.level($0)) > 0.01 }) { return true }
        if abs(a.activity - b.activity) > 0.05 { return true }
        if abs(a.speed - b.speed) > 0.02 || abs(a.surfDistance - b.surfDistance) > 0.01 { return true }
        if abs(a.indoors - b.indoors) > 0.01 || abs(a.wetness - b.wetness) > 0.01 || abs(a.snowOnGlass - b.snowOnGlass) > 0.01 { return true }
        if abs(a.lakeSurge - b.lakeSurge) > 0.02 || abs(a.lakeGlow - b.lakeGlow) > 0.02 { return true }   // the volcano's lake
        if a.key != b.key { return true }   // the temple bell and the sonar retune at their next strike or ping
        return abs(a.nightCool - b.nightCool) > 0.01 || abs(a.closeness - b.closeness) > 0.01 || abs(a.density - b.density) > 0.01
    }

    public func setAmbienceEnabled(_ on: Bool) {
        objectWillChange.send()   // `settings` isn't published: tell the controls and the set badge
        settings.ambience.enabled = on
        engine.ambienceEnabled = on
        autosave()
    }

    /// 0…1. A slider drags this at 60 Hz, so the save waits for the drag to settle.
    public func setAmbienceVolume(_ v: Double) {
        objectWillChange.send()
        settings.ambience.volume = min(1, max(0, v))
        engine.ambienceVolume = Float(settings.ambience.volume)
        scheduleSave()
    }

    /// 0 distant … 1 all around you.
    public func setAmbienceCloseness(_ c: Double) {
        objectWillChange.send()
        settings.ambience.closeness = min(1, max(0, c))
        let closeness = settings.ambience.closeness
        ambienceLive.withLockUnchecked { $0.closeness = closeness; $0.sent = nil }   // resend with the new closeness
        scheduleSave()
    }

    public func setGentleVisuals(_ on: Bool) {
        gentleVisuals = on; settings.gentleVisuals = on; visualsVersion += 1; autosave()
    }

    /// Excitement's controls (Fire & Neon spec §5), saved with the app's settings; the canvas hands them to the director.
    public var excitementSettings: ExcitementSettings { settings.excitement }

    /// Changes Excitement's controls: the manual dial is kept within 0…1, and the canvas picks them up at its next frame.
    public func setExcitementSettings(_ e: ExcitementSettings) {
        var next = e
        next.manualEnergy = next.manualEnergy.isFinite ? min(1, max(0, next.manualEnergy)) : ExcitementSettings().manualEnergy
        guard next != settings.excitement else { return }
        objectWillChange.send()   // `settings` isn't published: tell the panel
        settings.excitement = next
        visualsVersion += 1
        scheduleSave()   // the Energy dial drags this
    }

    // MARK: - Presets

    public func allReactions() -> [ReactionPreset] {
        ReactionPresets.all + presets.reactions().filter { p in !ReactionPresets.all.contains { $0.name == p.name } }
    }

    public func setReaction(_ preset: ReactionPreset) {
        reaction = preset.map
        reactionName = preset.name
        settings.reaction = preset.map
        settings.reactionName = preset.name
        visualsVersion += 1
        autosave()
    }

    /// Used by the mapping editor; the style becomes "Custom" until saved.
    public func setReactionMap(_ map: ReactionMap) {
        reaction = map
        reactionName = "Custom"
        settings.reaction = map
        settings.reactionName = "Custom"
        visualsVersion += 1
        scheduleSave()
    }

    public func saveReaction(named name: String) {
        let preset = ReactionPreset(name: name, map: reaction)
        try? presets.save(preset)
        setReaction(preset)
    }

    public func lookPresets() -> [LookPreset] {
        let builtIn = themeID == ButterflyGardenModel.id ? ButterflyGardenModel.builtInLooks : []
        return builtIn + presets.looks(for: themeID).filter { p in !builtIn.contains { $0.name == p.name } }
    }

    public func applyLook(_ look: LookPreset) {
        var state = look.state
        state.lookPresetName = look.name
        saveThemeState(state, for: look.themeID)
    }

    public func saveLook(named name: String) {
        var state = themeState(for: themeID)
        state.lookPresetName = name
        try? presets.save(LookPreset(name: name, themeID: themeID, state: state))
        saveThemeState(state, for: themeID)
    }

    /// A random, tasteful look for the current theme (macros kept).
    public func surprise() {
        let current = themeState(for: themeID)
        var state = Surprise.look(specs: ThemeRegistry.parameters(for: themeID), seed: UInt64.random(in: 1...UInt64.max))
        state.macros = current.macros
        saveThemeState(state, for: themeID)
    }

    private var saveTask: Task<Void, Never>?
    /// Saves after edits settle (0.5 s), so dragging a slider doesn't write on every tick.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.autosave()
        }
    }

    /// How many times settings have been written (tests watch the debounce).
    private(set) var saveCount = 0

    public func autosave() {
        saveCount += 1
        if settings.instrument != nil, case .playing = status {
            settings.instrument?.stateData = engine.currentInstrumentState()
        }
        settings.masterVolume = engine.masterVolume
        try? store.save(settings)
    }

    private func startAutosave() {
        guard autosaveTimer == nil else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosave() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autosave()
                self?.launchGuard.markStable()
            }
        }
    }

    // MARK: - Small Wins: the director's controls and report

    /// What the director's clock is asked for each frame (the canvas hands it over before the frame's events).
    public internal(set) var sceneControls = SceneControls()
    /// What the director said about the last frame (the canvas reports every frame): held or not, its sky and the key.
    public private(set) var sceneReport = SceneReport()
    /// Hold the moment: latched (a double-click on the hourglass, or ⌘⇧H) or pressed (the hourglass held down).
    @Published public internal(set) var holdLatched = false
    @Published public internal(set) var holdPressed = false
    /// True while time is held, however it was asked for (the hourglass lights).
    @Published public private(set) var holdShown = false
    /// The sleep timer's time left, in seconds (nil while it's off).
    @Published public internal(set) var sleepRemaining: TimeInterval?
    /// True while the visuals follow the Mac's Reduce Motion.
    @Published public internal(set) var reduceMotionActive = false

    /// The Gentle visuals the canvas draws with: yours, or the Mac's Reduce Motion while the app follows it. Your own
    /// setting never changes.
    public var effectiveGentleVisuals: Bool { gentleVisuals || reduceMotionActive }

    /// Called by the canvas after each frame. `holdShown` is published only when it changes.
    public func noteSceneReport(_ report: SceneReport) {
        sceneReport = report
        if holdShown != report.holding { holdShown = report.holding }
    }

    public var holdPedal: HoldPedal { settings.holdPedal }
    public var keyboardRange: KeyboardRange { settings.keyboardRange }
    public var breathSettings: AmbienceBreathSettings { settings.breath }
    public var followReduceMotion: Bool { settings.followReduceMotion }

    public func setHoldPedal(_ pedal: HoldPedal) {
        objectWillChange.send()   // `settings` isn't published: tell the controls
        settings.holdPedal = pedal
        sceneControls.holdPedal = pedal
        autosave()
    }

    public func setKeyboardRange(_ range: KeyboardRange) {
        objectWillChange.send()
        settings.keyboardRange = range
        live.withLockUnchecked { $0.keeper.setRange(low: range.low, high: range.high) }   // the keep gesture moves with it
        autosave()
    }

    /// The switch saves at once; the depth slider drags this, so a change of depth alone waits for the drag to settle.
    public func setBreath(_ breath: AmbienceBreathSettings) {
        objectWillChange.send()
        let switched = breath.enabled != settings.breath.enabled
        settings.breath = breath
        sceneControls.breath = breath
        if switched { autosave() } else { scheduleSave() }
    }

    public func setFollowReduceMotion(_ on: Bool) {
        objectWillChange.send()
        settings.followReduceMotion = on
        updateReduceMotion()
        autosave()
    }

    // MARK: - Small Wins: the toast

    /// A small note over the canvas, such as "Kept · 4:12", with an SF Symbol.
    public struct Toast: Equatable {
        public let text: String
        public let symbol: String
        public let id: Int
    }

    /// How long a toast stays up.
    nonisolated static let toastSeconds = 2.5
    @Published public private(set) var toast: Toast?
    /// A toast's time on screen (tests shorten it).
    var toastDuration = AppModel.toastSeconds
    private var toastCount = 0
    private var toastTimer: Task<Void, Never>?

    /// Shows a toast in place of any other; it clears itself after `toastDuration` unless a newer one replaces it.
    public func showToast(_ text: String, symbol: String) {
        toastCount += 1
        let shown = Toast(text: text, symbol: symbol, id: toastCount)
        toast = shown
        toastTimer?.cancel()
        let nanoseconds = UInt64(max(0, toastDuration) * 1_000_000_000)
        toastTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.toastExpired(shown.id)
        }
    }

    /// A toast's time is up: it goes, unless a newer toast has taken its place.
    func toastExpired(_ id: Int) {
        if toast?.id == id { toast = nil }
    }

    // MARK: - Help: Copy Performance Report

    /// How every drawn frame ran, by world and quality, since the app started: the canvas records into it each frame.
    /// A plain stored property, not `@Published`: it changes every frame and no view may redraw for it.
    var performanceLog = PerformanceLog()
    /// When the app started (system uptime), for the report's "Running for".
    let performanceStart = ProcessInfo.processInfo.systemUptime

    /// Help > Copy Performance Report: puts the report (the build, the Mac and its graphics chips, the quality setting,
    /// then a table of how each world ran) on the clipboard as plain text, for pasting into a chat.
    public func copyPerformanceReport() {
        let header = PerformanceReport.header(quality: quality, gentleVisuals: gentleVisuals,
                                              runningSeconds: ProcessInfo.processInfo.systemUptime - performanceStart)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(performanceLog.report(header: header), forType: .string)
        showToast("Performance report copied", symbol: "doc.on.clipboard")
    }

    // MARK: - Small Wins: activity

    /// When a key was last pressed, a pedal moved or the app clicked (system uptime; -∞ before any): what wakes the
    /// sleep fade (spec §3).
    nonisolated var lastActivityTime: Double { live.withLockUnchecked { $0.lastActivity } }

    /// A click or a key on the Mac's keyboard (any thread).
    nonisolated func noteUserActivity(at t: Double = ProcessInfo.processInfo.systemUptime) {
        live.withLockUnchecked { $0.lastActivity = t }
    }

    /// A note-on, or the sustain, sostenuto or soft pedal moving (either way).
    nonisolated static func isActivity(_ message: MIDIMessage) -> Bool {
        switch message {
        case .noteOn: return true
        case let .controlChange(_, controller, _): return controller == 64 || controller == 66 || controller == 67
        default: return false
        }
    }
}
