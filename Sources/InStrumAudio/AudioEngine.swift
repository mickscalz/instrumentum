import AVFoundation
import AudioToolbox
import CoreAudio
import InStrumCore
import os

public enum AudioEngineError: Error, Equatable {
    case pluginNotFound(String)
    case loadFailed(String)
}

/// Hosts one instrument plugin and plays it to the speakers.
/// `send` is safe to call from the CoreMIDI thread.
public final class AudioEngine {

    private let engine = AVAudioEngine()
    /// The instrument plays into its own bus; the level and sound-character tap listen here, so ambience never counts.
    private let instrumentBus = AVAudioMixerNode()
    /// Ambience plays on its own bus straight into the main mixer.
    private let ambienceBus = AVAudioMixerNode()
    private var ambienceUnit: AVAudioUnit?
    private var ambienceScene = AmbienceScene.silent
    private let manualRendering: Bool
    private let manualSampleRate: Double
    private var instrument: AVAudioUnit?
    private struct Shared {
        var midiBlock: AUScheduleMIDIEventBlock?
        var level: Float = 0
        var analyzer: SoundCharacterAnalyzer?
        var held = Set<UInt16>()   // channel << 8 | note
        var ambience: AmbienceAU?
    }
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
    private var configObserver: NSObjectProtocol?

    /// Output buffer size in frames (smaller = lower latency, larger = fewer glitches).
    public var bufferFrames: UInt32 = 256 {
        didSet { if !manualRendering && engine.isRunning { setOutputBufferSize() } }
    }

    public init(manualRendering: Bool = false, manualSampleRate: Double = 44_100) {
        self.manualRendering = manualRendering
        self.manualSampleRate = manualSampleRate
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        instrumentBus.removeTap(onBus: 0)
        engine.stop()
    }

    /// Safe to call more than once.
    public func start() throws {
        if engine.isRunning { return }
        if manualRendering {
            if !engine.isInManualRenderingMode {
                let format = AVAudioFormat(standardFormatWithSampleRate: manualSampleRate, channels: 2)!
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            }
        } else {
            setOutputBufferSize()
            if configObserver == nil { configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restartAfterConfigurationChange() } }
        }
        _ = engine.mainMixerNode   // make sure the graph has an output path
        if instrumentBus.engine == nil {
            engine.attach(instrumentBus)
            engine.connect(instrumentBus, to: engine.mainMixerNode, format: renderFormat())
        }
        applySleepGain()
        if !manualRendering { installLevelTap() }   // taps don't run in offline manual rendering
        engine.prepare()
        try engine.start()
    }

    /// Graph changes and plugin state happen on the main thread.
    @MainActor
    public func loadInstrument(_ choice: InstrumentChoice) async throws {
        let description: AudioComponentDescription
        if BuiltInCatalog.engine(for: choice) != nil {
            BuiltInCatalog.registerAll()
            description = AudioComponentDescription(componentType: choice.componentType, componentSubType: choice.componentSubType,
                                                    componentManufacturer: choice.componentManufacturer,
                                                    componentFlags: 0, componentFlagsMask: 0)
        } else {
            guard let component = PluginCatalog.component(for: choice) else {
                throw AudioEngineError.pluginNotFound(choice.name)
            }
            description = component.audioComponentDescription
        }
        let unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: description, options: [])
        } catch {
            throw AudioEngineError.loadFailed(choice.name)
        }
        if let data = choice.stateData,
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        let ambience = shared.withLockUnchecked { s -> AmbienceAU? in s.midiBlock = nil; s.held.removeAll(); return s.ambience }
        ambience?.setPlaying(false)
        if let old = instrument { engine.detach(old) }
        engine.attach(unit)
        engine.connect(unit, to: instrumentBus, format: renderFormat())
        instrument = unit
        let block = unit.auAudioUnit.scheduleMIDIEventBlock
        shared.withLockUnchecked { $0.midiBlock = block }
        if !engine.isRunning { try engine.start() }
    }

    /// The loaded instrument when it's one of the app's own.
    public var loadedBuiltIn: BuiltInInstrumentAU? { instrument?.auAudioUnit as? BuiltInInstrumentAU }

    /// Tells a built-in instrument the set's mood (plugins ignore it).
    public func setMood(_ mood: Mood) { loadedBuiltIn?.setMood(mood) }

    @MainActor
    public func currentInstrumentState() -> Data? {
        guard let state = instrument?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    public func send(_ bytes: [UInt8]) {
        let block = shared.withLockUnchecked { $0.midiBlock }
        guard let block, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { p in
            block(AUEventSampleTimeImmediate, 0, p.count, p.baseAddress!)
        }
        trackNotes(bytes)
    }

    /// What the instrument currently sounds like (sharp/smooth, bright/dark, ...).
    public var soundReading: SoundReading {
        shared.withLockUnchecked { $0.analyzer }?.reading ?? SoundReading()
    }

    /// Tells the sound analyser when notes start and when everything is released.
    private func trackNotes(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        let status = bytes[0] & 0xF0, key = UInt16(bytes[0] & 0x0F) << 8 | UInt16(bytes[1])
        let isOn = status == 0x90 && bytes[2] > 0
        let isOff = status == 0x80 || (status == 0x90 && bytes[2] == 0)
        guard isOn || isOff else { return }
        let (analyzer, released, ambience) = shared.withLockUnchecked { s -> (SoundCharacterAnalyzer?, Bool, AmbienceAU?) in
            let had = !s.held.isEmpty
            if isOn { s.held.insert(key) } else { s.held.remove(key) }
            return (s.analyzer, had && s.held.isEmpty, s.ambience)
        }
        if isOn { analyzer?.noteOn() } else if released { analyzer?.noteOff() }
        if isOn || released { ambience?.setPlaying(isOn) }
    }

    /// Silences everything: pedal up, all notes off, all sound off; and the ambience's thunder (Storms Review focus 4):
    /// what is on its way never arrives and what is rolling stops. The ambience's beds carry on.
    public func panic() {
        for ch: UInt8 in 0..<16 {
            send([0xB0 | ch, 64, 0])
            send([0xB0 | ch, 123, 0])
            send([0xB0 | ch, 120, 0])
        }
        for note: UInt8 in 0...127 { send([0x80, note, 0]) }
        shared.withLockUnchecked { $0.ambience }?.allSoundOff()
    }

    /// A world switch: thunder queued in the last world never arrives in the next (Storms Review focus 4).
    public func clearAmbienceThunder() {
        shared.withLockUnchecked { $0.ambience }?.clearThunder()
    }

    public var audioLevel: Float {
        shared.withLockUnchecked { $0.level }
    }

    public var loadedAudioUnit: AUAudioUnit? { instrument?.auAudioUnit }

    public var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    // MARK: - Ambience

    /// Attaches the ambience generator on its own bus. Safe to call more than once.
    @MainActor
    public func startAmbience() async {
        guard ambienceUnit == nil else { return }
        BuiltInCatalog.registerAll()
        guard let unit = try? await AVAudioUnit.instantiate(with: BuiltInCatalog.ambienceDescription, options: []),
              let au = unit.auAudioUnit as? AmbienceAU else { return }
        if ambienceBus.engine == nil {
            engine.attach(ambienceBus)
            engine.connect(ambienceBus, to: engine.mainMixerNode, format: renderFormat())
        }
        engine.attach(unit)
        engine.connect(unit, to: ambienceBus, format: renderFormat())
        ambienceUnit = unit
        au.enabled = ambienceEnabled
        au.setScene(ambienceScene)
        let playing = shared.withLockUnchecked { s -> Bool in s.ambience = au; return !s.held.isEmpty }
        au.setPlaying(playing)
        updateAmbienceBus()
        applySleepGain()
        if !engine.isRunning { try? engine.start() }
    }

    /// What the world wants to hear; every change glides over at least 2 s.
    public func setAmbience(_ scene: AmbienceScene) {
        ambienceScene = scene
        ambienceUnit.flatMap { $0.auAudioUnit as? AmbienceAU }?.setScene(scene)
    }

    /// 0…1 (default 25%).
    public var ambienceVolume: Float = 0.25 { didSet { updateAmbienceBus() } }

    public var ambienceEnabled = true {
        didSet {
            ambienceUnit.flatMap { $0.auAudioUnit as? AmbienceAU }?.enabled = ambienceEnabled
            updateAmbienceBus()
        }
    }

    /// Routing checks (tests): ambience goes straight to the main mixer, never through the instrument bus,
    /// where the level and sound-character tap listens.
    var ambienceFeedsMainMixer: Bool {
        ambienceUnit != nil && engine.outputConnectionPoints(for: ambienceBus, outputBus: 0).contains { $0.node === engine.mainMixerNode }
    }
    var ambienceFeedsInstrumentBus: Bool {
        guard let unit = ambienceUnit else { return false }
        return [unit, ambienceBus].contains { node in engine.outputConnectionPoints(for: node, outputBus: 0).contains { $0.node === instrumentBus } }
    }

    private func updateAmbienceBus() {
        ambienceBus.outputVolume = ambienceEnabled ? max(0, min(1, ambienceVolume)) : 0
    }

    // MARK: - The sleep fade's gain

    /// A run-time gain on everything you hear, 0…1 (the sleep fade, Small Wins spec §3). It is the input volume of the
    /// instrument's and the ambience's buses on the main mixer, after the level tap, so the saved volumes
    /// (`masterVolume`, `ambienceVolume`) never see it.
    public var sleepGain: Float {
        get { currentSleepGain }
        set {
            currentSleepGain = max(0, min(1, newValue))
            applySleepGain()
        }
    }
    private var currentSleepGain: Float = 1

    /// Both buses take the gain whenever they are (re)connected.
    private func applySleepGain() {
        instrumentBus.volume = currentSleepGain
        ambienceBus.volume = currentSleepGain
    }

    /// The gain as the two buses carry it, and the ambience bus's own volume (tests).
    var busSleepGains: (instrument: Float, ambience: Float) { (instrumentBus.volume, ambienceBus.volume) }
    var ambienceBusVolume: Float { ambienceBus.outputVolume }

    /// Offline rendering, for tests only.
    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    // MARK: - Private

    /// Render the instrument at the output device's rate so nothing is resampled.
    private func renderFormat() -> AVAudioFormat {
        var rate = manualRendering ? engine.manualRenderingFormat.sampleRate
                                   : engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = 44_100 }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    }

    private func setOutputBufferSize() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames = bufferFrames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    private func installLevelTap() {
        let mixer = instrumentBus
        mixer.removeTap(onBus: 0)
        let rate = mixer.outputFormat(forBus: 0).sampleRate
        let analyzer = SoundCharacterAnalyzer(sampleRate: rate > 0 ? rate : 44_100)
        shared.withLockUnchecked { $0.analyzer = analyzer }
        mixer.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let rms = min(1, sqrtf(sum / Float(n)) * 2)
            self.shared.withLockUnchecked { $0.level = rms }
            let right = buffer.format.channelCount > 1 ? data[1] : data[0]
            analyzer.process(left: data[0], right: right, frames: n)
        }
    }

    private func restartAfterConfigurationChange() {
        guard hardwareReady else { return }   // mid-switch: the watchdog restarts it once the output is ready
        rebuildOutput()
        try? engine.start()
    }

    /// Reconnects every bus at the output's (possibly new) rate, resets the buffer size and the level tap.
    private func rebuildOutput() {
        engine.disconnectNodeOutput(instrumentBus)
        engine.connect(instrumentBus, to: engine.mainMixerNode, format: renderFormat())
        if let unit = instrument {
            engine.disconnectNodeOutput(unit)
            engine.connect(unit, to: instrumentBus, format: renderFormat())
        }
        if let unit = ambienceUnit {
            engine.disconnectNodeOutput(ambienceBus)
            engine.connect(ambienceBus, to: engine.mainMixerNode, format: renderFormat())
            engine.disconnectNodeOutput(unit)
            engine.connect(unit, to: ambienceBus, format: renderFormat())
        }
        applySleepGain()
        setOutputBufferSize()
        installLevelTap()
        engine.prepare()
    }

    // MARK: - Output device and recovery

    /// Every sound output on the Mac.
    public static func listOutputDevices() -> [OutputDevice] { CoreAudioDevices.outputs() }
    public var outputDevices: [OutputDevice] { CoreAudioDevices.outputs() }

    /// The output the user chose (nil follows the Mac's default output).
    public private(set) var selectedOutputUID: String?
    /// True while a chosen output is missing and the Mac's default output stands in for it.
    public private(set) var usingFallback = false
    /// How many times the sound had to be restarted.
    public private(set) var restarts = 0

    public var isRunning: Bool { manualRendering || engine.isRunning }

    /// The output's sample rate in Hz (0 before it starts).
    public var outputSampleRate: Double {
        manualRendering ? manualSampleRate : engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// The device the output is really playing to.
    private func currentDeviceID() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr,
              id != 0 else { return nil }
        return id
    }

    private func play(to id: AudioDeviceID) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        let wasRunning = engine.isRunning
        engine.stop()
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            if wasRunning { try? engine.start() }
            return false
        }
        rebuildOutput()
        try? engine.start()
        return true
    }

    /// Plays to the output with this unique ID, or to the Mac's default output for nil. False if it isn't there
    /// (or while rendering offline); the sound then stays where it was.
    @discardableResult
    public func selectOutputDevice(uid: String?) -> Bool {
        guard !manualRendering else { return false }
        guard let id = uid.flatMap(CoreAudioDevices.device(uid:)) ?? (uid == nil ? CoreAudioDevices.defaultOutput() : nil),
              play(to: id) else { return false }
        selectedOutputUID = uid
        usingFallback = false
        lastSeenDefault = CoreAudioDevices.defaultOutput()
        return true
    }

    /// The Mac's default output when it was last looked at (so a change is followed once, never fought over).
    private var lastSeenDefault: AudioDeviceID?

    /// Restarts the sound from scratch (the Restart audio button).
    public func restartAudio() {
        guard !manualRendering else { return }
        engine.stop()
        if hardwareReady { rebuildOutput() }
        try? engine.start()
        restarts += 1
    }

    /// False mid-switch, while the output reports no rate or channels (rebuilding then can throw inside AVAudioEngine).
    private var hardwareReady: Bool {
        let hw = engine.outputNode.outputFormat(forBus: 0)
        return hw.sampleRate > 0 && hw.channelCount > 0
    }

    /// The chosen output when it came back but refused to take over (not retried until it goes and returns).
    private var refusedOutput: AudioDeviceID?
    /// The default output last tried as a stand-in for a missing chosen output (each one is tried once).
    private var triedFallback: AudioDeviceID?

    /// Called every couple of seconds: puts the sound back when it has stopped, moves to the Mac's default output
    /// when the chosen one disappears (and back when it returns), and follows the default output when that's the
    /// choice. Every switch is tried once per change, so a device that refuses never causes a dropout every tick.
    /// Returns a note for the user when it had to act.
    public func checkHealth() -> String? {
        guard !manualRendering, instrumentBus.engine != nil else { return nil }
        if let uid = selectedOutputUID {
            let chosen = CoreAudioDevices.device(uid: uid)
            let chosenAlive = chosen.map(CoreAudioDevices.isAlive) ?? false
            if !chosenAlive { refusedOutput = nil }
            if usingFallback, chosenAlive, let back = chosen, back != refusedOutput {
                if play(to: back) {
                    usingFallback = false
                    triedFallback = nil
                    return "Your chosen output is back: playing to it again."
                }
                refusedOutput = back
            }
            if !chosenAlive, let fallback = CoreAudioDevices.defaultOutput(), fallback != chosen, CoreAudioDevices.isAlive(fallback),
               !engine.isRunning || (fallback != triedFallback && currentDeviceID() != fallback) {
                triedFallback = fallback
                let first = !usingFallback
                if play(to: fallback) {
                    usingFallback = true
                    if first { return "Your chosen output isn't connected: playing to the Mac's default output until it's back." }
                }
            }
        } else if let target = CoreAudioDevices.defaultOutput(), target != lastSeenDefault {
            if lastSeenDefault == nil || currentDeviceID() == target {
                lastSeenDefault = target
            } else if CoreAudioDevices.isAlive(target) {
                lastSeenDefault = target   // one try per change
                if play(to: target) { return nil }   // followed the Mac's new default output, as asked
            }                              // not ready yet (a Bluetooth device just connecting): look again next time
        }
        if !engine.isRunning {
            guard hardwareReady else { return "The sound has stopped. Check the output below, then press Restart audio." }
            rebuildOutput()
            try? engine.start()
            restarts += 1
            return engine.isRunning ? "The sound stopped and was restarted." : "The sound has stopped. Check the output below, then press Restart audio."
        }
        return nil
    }
}
