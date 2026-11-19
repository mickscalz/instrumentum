import AVFoundation
import InStrumCore

/// What the Recorder keeps in the engine (Recorder spec §3, §7). Nothing in it is made or attached until it is first
/// used, so an engine that never records has today's graph and sound.
struct RecorderParts {
    var playAlong: AVAudioMixerNode?
    var liveInput: AVAudioMixerNode?
    var layers: AVAudioMixerNode?
    var playAlongVolume: Float = 1
    var liveInputVolume: Float = 1
    var layersVolume: Float = 1
    /// The recorder of the current or last pass, and the one it replaced after a change of sample rate (kept, so a tap
    /// that still holds it is never the one to let it go).
    var recorder: StemRecorder?
    var retired: StemRecorder?
    /// The pass records the ambience; its bus then carries a tap (not in offline rendering, where taps don't run).
    var recordsAmbience = false
    var ambienceTapped = false
}

extension AudioEngine {

    // MARK: - The Recorder's buses

    /// The play-along (a track file, or the Mac's sound through BlackHole), into the main mixer. Attached on first use.
    public var playAlongBus: AVAudioMixerNode { recordingBus(\.playAlong, volume: recorderParts.playAlongVolume) }
    /// The live input (a microphone, an interface, a processor's return), into the main mixer. Attached on first use.
    public var liveInputBus: AVAudioMixerNode { recordingBus(\.liveInput, volume: recorderParts.liveInputVolume) }
    /// The earlier layers playing back, into the main mixer. Attached on first use.
    public var layersBus: AVAudioMixerNode { recordingBus(\.layers, volume: recorderParts.layersVolume) }

    /// Each bus's own volume, 0…1 (its output volume; the sleep fade is its input volume on the main mixer, as for the
    /// instrument's and the ambience's buses). Setting one attaches nothing.
    public var playAlongVolume: Float {
        get { recorderParts.playAlongVolume }
        set {
            recorderParts.playAlongVolume = max(0, min(1, newValue))
            recorderParts.playAlong?.outputVolume = recorderParts.playAlongVolume
        }
    }
    public var liveInputVolume: Float {
        get { recorderParts.liveInputVolume }
        set {
            recorderParts.liveInputVolume = max(0, min(1, newValue))
            recorderParts.liveInput?.outputVolume = recorderParts.liveInputVolume
        }
    }
    public var layersVolume: Float {
        get { recorderParts.layersVolume }
        set {
            recorderParts.layersVolume = max(0, min(1, newValue))
            recorderParts.layers?.outputVolume = recorderParts.layersVolume
        }
    }

    /// False until one of the three buses is first used.
    public var recordingBusesAttached: Bool {
        recorderParts.playAlong != nil || recorderParts.liveInput != nil || recorderParts.layers != nil
    }

    private func recordingBus(_ slot: WritableKeyPath<RecorderParts, AVAudioMixerNode?>, volume: Float) -> AVAudioMixerNode {
        if let bus = recorderParts[keyPath: slot] { return bus }
        let bus = AVAudioMixerNode()
        // With the engine stopped, as a rebuild connects: of several buses connected to the main mixer while it runs,
        // only the last one plays. A bus is attached once, on first use, so the restart is once per bus.
        let running = engine.isRunning
        if running { engine.stop() }
        engine.attach(bus)
        engine.connect(bus, to: engine.mainMixerNode, format: renderFormat())
        bus.outputVolume = volume
        bus.volume = sleepGain
        recorderParts[keyPath: slot] = bus
        if running { try? engine.start() }
        return bus
    }

    private var attachedRecordingBuses: [AVAudioMixerNode] {
        [recorderParts.playAlong, recorderParts.liveInput, recorderParts.layers].compactMap { $0 }
    }

    /// The sleep fade, on whichever of the buses are attached (from `applySleepGain`).
    func applySleepGainToRecordingBuses() {
        for bus in attachedRecordingBuses { bus.volume = sleepGain }
    }

    /// From `rebuildOutput`: the attached buses back into the main mixer at the output's (possibly new) rate, and the
    /// ambience stem's tap again if a pass is recording it. Does nothing when the Recorder was never used.
    func reconnectRecordingBuses() {
        for bus in attachedRecordingBuses {
            engine.disconnectNodeOutput(bus)
            engine.connect(bus, to: engine.mainMixerNode, format: renderFormat())
        }
        if recorderParts.ambienceTapped { installAmbienceStemTap() }
    }

    /// Tests: each of the three buses is attached and feeds the main mixer.
    var recordingBusesFeedMainMixer: Bool {
        let buses = [recorderParts.playAlong, recorderParts.liveInput, recorderParts.layers]
        for bus in buses {
            guard let bus, engine.outputConnectionPoints(for: bus, outputBus: 0).contains(where: { $0.node === engine.mainMixerNode })
            else { return false }
        }
        return true
    }

    // MARK: - Recording

    /// The current (or last) pass's recorder; nil before the first recording.
    public var recorder: StemRecorder? { recorderParts.recorder }

    /// The engine's sample clock now, the clock the taps stamp their buffers with.
    var currentSampleTime: Int64 {
        if manualRendering { return engine.manualRenderingSampleTime }
        // The instrument bus's own clock first: its tap stamps the instrument stem's buffers on that timeline, so a
        // pass that starts there can never sit before or far after what the tap delivers.
        if let bus = instrumentBus.lastRenderTime, bus.isSampleTimeValid { return bus.sampleTime }
        guard let now = engine.outputNode.lastRenderTime, now.isSampleTimeValid else { return 0 }
        return now.sampleTime
    }

    /// Starts a pass writing these stems. Returns its start sample time: two buffers from now, so every stem (and
    /// anything scheduled to play with it) begins at the same frame. The instrument stem comes from the instrument
    /// bus's tap, before the master volume and the sleep fade; the ambience stem from the ambience bus's.
    public func beginRecording(_ stems: [(kind: StemKind, url: URL)]) throws -> Int64 {
        if recorderParts.recorder?.isRecording == true { throw StemRecorder.RecorderError.alreadyRecording }
        let rate = renderFormat().sampleRate
        let recorder: StemRecorder
        if let current = recorderParts.recorder, current.sampleRate == rate {
            recorder = current
        } else {
            recorder = StemRecorder(sampleRate: rate)
            recorderParts.retired = recorderParts.recorder
            recorderParts.recorder = recorder
        }
        let start = currentSampleTime + 2 * Int64(bufferFrames)
        try recorder.begin(stems, atSampleTime: start)
        recorderParts.recordsAmbience = stems.contains { $0.kind == .ambience }
        installAmbienceStemTap()
        shared.withLockUnchecked { $0.recorder = recorder }
        return start
    }

    /// Ends the pass: the taps stop feeding and every file is closed. Frames written per stem.
    @discardableResult
    public func endRecording() -> [StemKind: Int] {
        shared.withLockUnchecked { $0.recorder = nil }
        recorderParts.recordsAmbience = false
        if recorderParts.ambienceTapped {
            ambienceBus.removeTap(onBus: 0)
            recorderParts.ambienceTapped = false
        }
        return recorderParts.recorder?.end() ?? [:]
    }

    /// The ambience stem's tap: after the ambience's own volume, before the sleep fade. Only while a pass records the
    /// ambience, and only when it plays (a node carries one tap; nothing else taps this bus).
    func installAmbienceStemTap() {
        guard recorderParts.recordsAmbience, !manualRendering, ambienceBus.engine != nil else { return }
        if recorderParts.ambienceTapped { ambienceBus.removeTap(onBus: 0) }
        ambienceBus.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, when in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0, let recorder = self.shared.withLockUnchecked({ $0.recorder }) else { return }
            let right = buffer.format.channelCount > 1 ? data[1] : data[0]
            recorder.feed(.ambience, left: data[0], right: right, frames: n, sampleTime: when.sampleTime)
        }
        recorderParts.ambienceTapped = true
    }

    /// Offline tests: feed what `renderOffline` returned as this stem, stamped `sampleTime`. For the instrument stem it
    /// stands where the instrument bus's tap stands: the two gains the main mixer applies after that bus (the sleep
    /// gain and the master volume) are taken back out. That is exact while the instrument is all that plays.
    func feedOffline(_ buffer: AVAudioPCMBuffer, kind: StemKind, sampleTime: Int64) {
        guard let recorder = shared.withLockUnchecked({ $0.recorder }), let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let rightChannel = buffer.format.channelCount > 1 ? data[1] : data[0]
        let gain = kind == .instrument ? busSleepGains.instrument * masterVolume : 1
        guard gain > 0, gain != 1 else {
            recorder.feed(kind, left: data[0], right: rightChannel, frames: n, sampleTime: sampleTime)
            return
        }
        var left = Array(UnsafeBufferPointer(start: data[0], count: n))
        var right = Array(UnsafeBufferPointer(start: rightChannel, count: n))
        for i in 0..<n {
            left[i] /= gain
            right[i] /= gain
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                recorder.feed(kind, left: l.baseAddress!, right: r.baseAddress!, frames: n, sampleTime: sampleTime)
            }
        }
    }
}
