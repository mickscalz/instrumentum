import AVFoundation
import CoreAudio
import InStrumCore

/// Where an input plays (Recorder spec §5.2, §6): the play-along (the Mac's sound through BlackHole) on the play-along
/// bus, or the live input (a microphone, an interface, a processor's return) on the live-input bus.
public enum InputSlot: String, CaseIterable, Sendable {
    case playAlong, liveInput

    /// The stem it records as.
    public var stemKind: StemKind {
        switch self {
        case .playAlong: return .playAlong
        case .liveInput: return .liveInput
        }
    }
}

/// What the engine keeps for its inputs (AudioEngine+Inputs). Empty until an input is chosen, so an engine that never
/// has one keeps today's graph and sound.
struct InputParts {
    /// A chosen input: its capture, and its gate (source → gate → bus), whose volume is Hear it.
    struct Slot {
        let device: InputDevice
        let channels: ChannelChoice
        var hearIt: Bool
        let capture: InputCapture
        let gate: AVAudioMixerNode
        var stemTapped = false
    }
    var playAlong: Slot?
    var liveInput: Slot?
    var playAlongGainDB: Float = 0
    var liveInputGainDB: Float = 0
    var onStopped: ((InputSlot) -> Void)?
    /// Tests: stands in for the device the app really plays to (offline engines play to none).
    var outputUIDForTests: String?

    subscript(slot: InputSlot) -> Slot? {
        get { slot == .playAlong ? playAlong : liveInput }
        set {
            if slot == .playAlong { playAlong = newValue } else { liveInput = newValue }
        }
    }

    func gainDB(_ slot: InputSlot) -> Float { slot == .playAlong ? playAlongGainDB : liveInputGainDB }
}

extension AudioEngine {

    // MARK: - Choosing an input

    /// Chooses the input for a slot (nil removes it): captures `channels` of `device`, plays it through the slot's bus
    /// when `hearIt`, and records it as the slot's stem whenever a pass records that stem, heard or not. Play-through stays
    /// muted while the input is the device the app really plays to (no howl). Throws if the device can't be opened.
    /// An offline engine (tests) never opens a device: its tests write into the input's capture ring themselves.
    public func setInput(_ slot: InputSlot, device: InputDevice?, channels: ChannelChoice, hearIt: Bool) throws {
        removeInput(slot)
        guard let device else { return }
        let capture = try makeCapture(slot, device: device, channels: channels)
        let bus = slot == .playAlong ? playAlongBus : liveInputBus
        let gate = AVAudioMixerNode()
        // With the engine stopped, as the Recorder's buses are attached (AudioEngine+Recording).
        let running = engine.isRunning
        if running { engine.stop() }
        engine.attach(capture.sourceNode)
        engine.attach(gate)
        engine.connect(capture.sourceNode, to: gate, format: capture.format)
        engine.connect(gate, to: bus, format: renderFormat())
        inputParts[slot] = InputParts.Slot(device: device, channels: capture.channels, hearIt: hearIt, capture: capture, gate: gate)
        applyHearIt(slot)
        installInputStemTap(slot)
        if running { try? engine.start() }
    }

    /// Hear it: plays the slot's input through (unless it is the device the app plays to), or records it unheard.
    public func setHearIt(_ slot: InputSlot, _ on: Bool) {
        guard inputParts[slot] != nil else { return }
        inputParts[slot]?.hearIt = on
        applyHearIt(slot)
    }

    /// The slot's input is the device the app is really playing to: play-through would feed it back into itself, so it
    /// stays muted (spec §5.2, §6). False without an input.
    public func inputIsTheOutput(_ slot: InputSlot) -> Bool {
        guard let input = inputParts[slot], let output = playingOutputUID else { return false }
        return input.device.uid == output
    }

    /// The input's meter, 0…1 and over (after its gain); 0 without one.
    public func inputPeak(_ slot: InputSlot) -> Float { inputParts[slot]?.capture.peak ?? 0 }

    /// The input reached full scale in the last moment (its meter turns red).
    public func inputClipped(_ slot: InputSlot) -> Bool { inputParts[slot]?.capture.clipped ?? false }

    /// The input side's latency in the engine's frames (device, stream, safety offset, buffer); nil without an input.
    public func inputLatency(_ slot: InputSlot) -> RecordingLatency.Device? {
        guard let input = inputParts[slot] else { return nil }
        let device = InputDevices.latency(input.device.id)
        let scale = input.capture.engineRate / input.capture.deviceRate
        func frames(_ n: Int) -> Int { Int((Double(n) * scale).rounded()) }
        return RecordingLatency.Device(latencyFrames: frames(device.latencyFrames), safetyFrames: frames(device.safetyFrames),
                                       bufferFrames: frames(device.bufferFrames))
    }

    /// The capture buffer's target in the engine's frames, for `RecordingLatency.offsetFrames`; 0 without an input.
    public func inputBufferFrames(_ slot: InputSlot) -> Int { inputParts[slot]?.capture.bufferFrames ?? 0 }

    /// The input chosen for the slot (still chosen after it was unplugged, until the app removes it).
    public func inputDevice(_ slot: InputSlot) -> InputDevice? { inputParts[slot]?.device }

    /// The input gain, −24…+24 dB (spec §6). Kept for the slot when its device changes.
    public func setInputGain(_ slot: InputSlot, dB: Float) {
        let value = dB.isFinite ? min(24, max(-24, dB)) : 0
        if slot == .playAlong { inputParts.playAlongGainDB = value } else { inputParts.liveInputGainDB = value }
        inputParts[slot]?.capture.gainDB = value
    }

    /// Called on the main thread when an input stops by itself (unplugged): that stem ends there, the others carry on.
    public var onInputStopped: ((InputSlot) -> Void)? {
        get { inputParts.onStopped }
        set { inputParts.onStopped = newValue }
    }

    // MARK: - Inside the engine

    /// The device the app is really playing to (its UID), or the tests' stand-in.
    var playingOutputUID: String? {
        if let uid = inputParts.outputUIDForTests { return uid }
        guard !manualRendering, let id = currentDeviceID() else { return nil }
        return CoreAudioDevices.uid(of: id)
    }

    /// Tests: the device the app plays to, as far as the no-howl rule is concerned.
    var outputUIDForTests: String? {
        get { inputParts.outputUIDForTests }
        set { inputParts.outputUIDForTests = newValue }
    }

    /// The slot's capture (tests write into its ring).
    func inputCapture(_ slot: InputSlot) -> InputCapture? { inputParts[slot]?.capture }

    private func makeCapture(_ slot: InputSlot, device: InputDevice, channels: ChannelChoice) throws -> InputCapture {
        let capture = InputCapture(device: device, channels: channels, engineRate: renderFormat().sampleRate)
        capture.gainDB = inputParts.gainDB(slot)
        if !manualRendering { try capture.start() }
        capture.onStopped = { [weak self, weak capture] in
            guard let self, let capture else { return }
            self.inputStopped(slot, capture)
        }
        return capture
    }

    private func removeInput(_ slot: InputSlot) {
        guard let input = inputParts[slot] else { return }
        inputParts[slot] = nil
        input.capture.onStopped = nil
        input.capture.stop()
        if input.stemTapped { input.capture.sourceNode.removeTap(onBus: 0) }
        let running = engine.isRunning
        if running { engine.stop() }
        engine.detach(input.capture.sourceNode)
        engine.detach(input.gate)
        if running { try? engine.start() }
    }

    /// The gate's volume: 1 when the input is to be heard and isn't the device the app plays to, else 0. The source node
    /// is still pulled (and its stem still recorded) at 0.
    private func applyHearIt(_ slot: InputSlot) {
        guard let input = inputParts[slot] else { return }
        input.gate.outputVolume = input.hearIt && !inputIsTheOutput(slot) ? 1 : 0
    }

    /// The input's device went away: its capture has stopped and its source node plays silence. The app is told.
    private func inputStopped(_ slot: InputSlot, _ capture: InputCapture) {
        guard inputParts[slot]?.capture === capture else { return }
        inputParts.onStopped?(slot)
    }

    /// From `rebuildOutput` (the engine is stopped): the inputs at the output's (possibly new) rate, and the no-howl rule
    /// looked at again, since the device the app plays to may have changed. Does nothing without an input.
    func reconnectInputs() {
        for slot in InputSlot.allCases {
            guard let input = inputParts[slot] else { continue }
            let rate = renderFormat().sampleRate
            if input.capture.engineRate != rate {
                let bus = slot == .playAlong ? playAlongBus : liveInputBus
                // A new rate: a new capture of the same device plays at it; the old one lets the device go.
                if input.stemTapped { input.capture.sourceNode.removeTap(onBus: 0) }
                input.capture.onStopped = nil
                input.capture.stop()
                engine.detach(input.capture.sourceNode)
                engine.disconnectNodeOutput(input.gate)
                guard let fresh = try? makeCapture(slot, device: input.device, channels: input.channels) else {
                    engine.detach(input.gate)
                    inputParts[slot] = nil
                    inputParts.onStopped?(slot)
                    continue
                }
                engine.attach(fresh.sourceNode)
                engine.connect(fresh.sourceNode, to: input.gate, format: fresh.format)
                engine.connect(input.gate, to: bus, format: renderFormat())
                inputParts[slot] = InputParts.Slot(device: input.device, channels: fresh.channels, hearIt: input.hearIt,
                                                   capture: fresh, gate: input.gate)
                installInputStemTap(slot)
            }
            applyHearIt(slot)
        }
    }

    // MARK: - The inputs' stems

    /// The input's stem tap: on its source node's output, before the gate (Hear it) and the bus, so the input records
    /// whether or not it is heard. A node carries one tap; nothing else taps a source node. Not in offline rendering,
    /// where taps don't run.
    private func installInputStemTap(_ slot: InputSlot) {
        guard !manualRendering, let input = inputParts[slot] else { return }
        let node = input.capture.sourceNode
        if input.stemTapped { node.removeTap(onBus: 0) }
        let kind = slot.stemKind
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, when in
            self?.feedInputStem(kind, buffer, sampleTime: when.sampleTime)
        }
        inputParts[slot]?.stemTapped = true
    }

    /// The tap's handler (tests call it directly): hands the buffer to the recorder as `kind` when a pass is recording.
    /// The recorder drops a kind its pass doesn't record.
    func feedInputStem(_ kind: StemKind, _ buffer: AVAudioPCMBuffer, sampleTime: Int64) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0, let recorder = shared.withLockUnchecked({ $0.recorder }) else { return }
        let right = buffer.format.channelCount > 1 ? data[1] : data[0]
        recorder.feed(kind, left: data[0], right: right, frames: n, sampleTime: sampleTime)
    }
}
