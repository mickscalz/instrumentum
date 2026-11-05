import AVFoundation
import AudioToolbox
import InStrumCore
import InStrumDSP

/// Holds the Sound Core instance the render block uses. Retired instances (after a sample-rate change)
/// are kept until the unit itself goes away, so the render thread never touches freed memory.
final class SynthBox {
    var synth: OpaquePointer?
    var retired: [OpaquePointer] = []
    /// Output memory for hosts that pass empty buffers.
    var scratchL: UnsafeMutablePointer<Float>?
    var scratchR: UnsafeMutablePointer<Float>?
    deinit {
        if let synth { isd_synth_destroy(synth) }
        retired.forEach { isd_synth_destroy($0) }
    }
}

/// Felt Glass / Orbit Pad as an in-process Audio Unit instrument.
public final class BuiltInInstrumentAU: AUAudioUnit {
    public let engine: BuiltInEngine
    /// The preset last applied (saved with the instrument's state).
    public private(set) var patchID: String?

    private let box = SynthBox()
    private let isdEngine: ISDEngine
    private var outputBus: AUAudioUnitBus!
    private var busArray: AUAudioUnitBusArray!
    private var tree: AUParameterTree!
    private var scratch: AVAudioPCMBuffer?
    private var synthRate: Double = 0

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        engine = BuiltInCatalog.engine(forSubType: componentDescription.componentSubType) ?? .feltGlass
        isdEngine = BuiltInCatalog.isdEngine(engine)
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        guard makeSynth(rate: 48_000) else { throw AudioEngineError.loadFailed(engine.displayName) }
        tree = makeTree()
        maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { busArray }
    public override var parameterTree: AUParameterTree? {
        get { tree }
        set { }
    }
    public override var canProcessInPlace: Bool { true }
    public override var providesUserInterface: Bool { false }

    // MARK: - Presets, mood and state

    /// Sets every dial the patch names (tuning is left as it is).
    public func apply(_ patch: Patch) {
        for (identifier, value) in patch.values { parameter(identifier)?.value = AUValue(value) }
        patchID = patch.id
    }

    public func setMood(_ mood: Mood) {
        for (identifier, value) in mood.parameterValues { parameter(identifier)?.value = AUValue(value) }
    }

    func parameter(_ identifier: String) -> AUParameter? {
        tree.allParameters.first { $0.identifier == identifier }
    }

    public override var fullState: [String: Any]? {
        get {
            var values: [String: NSNumber] = [:]
            for p in tree.allParameters { values[p.identifier] = NSNumber(value: p.value) }
            return ["engine": engine.rawValue, "patchID": patchID ?? "", "values": values]
        }
        set {
            guard let state = newValue else { return }
            if let id = state["patchID"] as? String { patchID = id.isEmpty ? nil : id }
            if let values = state["values"] as? [String: NSNumber] {
                for (identifier, number) in values { parameter(identifier)?.value = number.floatValue }
            }
        }
    }

    // MARK: - The grand's morph and repeats (Single Note Grand; every other engine ignores them)

    /// The morph the world forces on the voice (Storms spec §9.2: Morph .8 for the storm's arrival), 0…1; nil (or a
    /// negative value) lets it go, and the morph returns to the player's pressure over 250 ms. Any thread: the engine
    /// keeps it in an atomic read once per control block and moves to it through its own smoothing, so calling it every
    /// frame is cheap and never steps.
    public func setForcedMorph(_ morph: Float?) {
        if let synth = box.synth { isd_synth_set_forced_morph(synth, morph ?? -1) }
    }

    /// The morph the engine is using, 0…1: the player's pressure over the Morph floor, or the world's forced morph,
    /// smoothed 80 ms up and 250 ms down. 0 for every other engine. Any thread.
    public var morphInUse: Float {
        box.synth.map { Float(isd_synth_debug_count($0, ISD_DEBUG_MORPH_PERMILLE)) / 1000 } ?? 0
    }

    /// True while the engine hears the same key struck four or more times at 2 a second or faster. False for every
    /// other engine. Any thread.
    public var isRepeating: Bool {
        box.synth.map { isd_synth_debug_is_repeating($0) != 0 } ?? false
    }

    // MARK: - Rendering

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let rate = outputBus.format.sampleRate
        if rate != synthRate, !makeSynth(rate: rate) { throw AudioEngineError.loadFailed(engine.displayName) }
        scratch = AVAudioPCMBuffer(pcmFormat: outputBus.format, frameCapacity: max(maximumFramesToRender, 4096))
        box.scratchL = scratch?.floatChannelData?[0]
        box.scratchR = outputBus.format.channelCount > 1 ? scratch?.floatChannelData?[1] : nil
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let box = self.box
        return { _, timestamp, frameCount, _, outputData, eventList, _ in
            guard let synth = box.synth else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2 else { return kAudioUnitErr_FormatNotSupported }
            if buffers[0].mData == nil || buffers[1].mData == nil, let sl = box.scratchL, let sr = box.scratchR {
                buffers[0].mData = UnsafeMutableRawPointer(sl)
                buffers[1].mData = UnsafeMutableRawPointer(sr)
            }
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidParameter }
            let now = Int64(timestamp.pointee.mSampleTime)
            var event = eventList
            while let e = event {
                switch e.pointee.head.eventType {
                case .MIDI, .midiSysEx:
                    var midi = e.pointee.MIDI
                    let offset = Int32(clamping: max(0, midi.eventSampleTime - now))
                    let length = Int32(min(3, Int(midi.length)))
                    withUnsafeBytes(of: &midi.data) { raw in
                        isd_synth_midi(synth, raw.bindMemory(to: UInt8.self).baseAddress, length, offset)
                    }
                case .parameter, .parameterRamp:
                    let p = e.pointee.parameter
                    isd_synth_set_param(synth, Int32(clamping: Int(p.parameterAddress)), p.value)
                default:
                    break
                }
                event = e.pointee.head.next.map { UnsafePointer($0) }
            }
            isd_synth_render(synth, l, r, Int32(frameCount))
            buffers[0].mDataByteSize = frameCount * 4
            buffers[1].mDataByteSize = frameCount * 4
            return noErr
        }
    }

    // MARK: - Private

    /// Creates the Sound Core at `rate`, carrying over every dial value.
    private func makeSynth(rate: Double) -> Bool {
        guard let fresh = isd_synth_create(isdEngine, rate, 4096) else { return false }
        if let old = box.synth {
            for i in 0..<isd_synth_param_count(isdEngine) {
                guard let info = isd_synth_param_info(isdEngine, i) else { continue }
                let a = info.pointee.address
                isd_synth_set_param(fresh, a, isd_synth_get_param(old, a))
            }
            box.retired.append(old)
        }
        box.synth = fresh
        synthRate = rate
        return true
    }

    private func makeTree() -> AUParameterTree {
        var params: [AUParameter] = []
        for i in 0..<isd_synth_param_count(isdEngine) {
            guard let info = isd_synth_param_info(isdEngine, i)?.pointee, info.unit != 3 else { continue }   // 3: test hooks
            let unit: AudioUnitParameterUnit = info.unit == 1 ? .cents : (info.unit == 2 ? .relativeSemiTones : .generic)
            let p = AUParameterTree.createParameter(withIdentifier: String(cString: info.identifier), name: String(cString: info.name),
                                                    address: AUParameterAddress(info.address), min: info.minValue, max: info.maxValue,
                                                    unit: unit, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable],
                                                    valueStrings: nil, dependentParameters: nil)
            p.value = info.defaultValue
            params.append(p)
        }
        let t = AUParameterTree.createTree(withChildren: params)
        let box = self.box
        t.implementorValueObserver = { param, value in
            if let s = box.synth { isd_synth_set_param(s, Int32(clamping: Int(param.address)), value) }
        }
        t.implementorValueProvider = { param in
            box.synth.map { isd_synth_get_param($0, Int32(clamping: Int(param.address))) } ?? 0
        }
        return t
    }
}
