import AVFoundation
import AudioToolbox
import InStrumCore
import InStrumDSP
import os

/// The ambience generator the render block uses. Retired instances (after a sample-rate change) live until the
/// unit goes away, so the render thread never touches freed memory.
final class AmbienceBox {
    var ambience: OpaquePointer?
    var retired: [OpaquePointer] = []
    var scratchL: UnsafeMutablePointer<Float>?
    var scratchR: UnsafeMutablePointer<Float>?
    deinit {
        if let ambience { isd_ambience_destroy(ambience) }
        retired.forEach { isd_ambience_destroy($0) }
    }
}

/// The live ambience (spec §5) as an in-process generator Audio Unit. It plays on its own bus,
/// never through the instrument's, so the sound-character tap never hears it and panic leaves its beds alone (a panic only
/// drops the thunder on its way and stops any that is rolling).
public final class AmbienceAU: AUAudioUnit {
    private let box = AmbienceBox()
    private var outputBus: AUAudioUnitBus!
    private var busArray: AUAudioUnitBusArray!
    private var scratch: AVAudioPCMBuffer?
    private var rate: Double = 0
    private struct State { var scene = AmbienceScene.silent; var enabled = true; var playing = false }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private static let seed = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        guard make(rate: 48_000) else { throw AudioEngineError.loadFailed("Ambience") }
        maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { busArray }
    public override var canProcessInPlace: Bool { true }

    // MARK: - Control (any thread)

    public func setScene(_ scene: AmbienceScene) {
        state.withLockUnchecked { $0.scene = scene }
        apply(thunder: scene.thunder, wave: scene.wave, bubbles: scene.bubbleBurst, thunderQueue: scene.thunderQueue)
    }

    /// A world switch (Storms Review focus 4): thunder still on its way from the last world never arrives in the next
    /// (rolls already sounding fade out with the world's levels).
    public func clearThunder() {
        if let a = box.ambience { isd_ambience_clear_thunder(a) }
    }

    /// Panic: the thunder on its way is dropped and anything rolling fades out within 40 ms; the beds carry on.
    public func allSoundOff() {
        if let a = box.ambience { isd_ambience_all_sound_off(a) }
    }

    /// Off fades every source out (and stops the work); on brings the scene back.
    public var enabled: Bool {
        get { state.withLockUnchecked { $0.enabled } }
        set { state.withLockUnchecked { $0.enabled = newValue }; apply(thunder: nil) }
    }

    /// Notes held on the instrument: the ambience ducks under them.
    public func setPlaying(_ playing: Bool) {
        let changed = state.withLockUnchecked { s -> Bool in let c = s.playing != playing; s.playing = playing; return c }
        if changed { apply(thunder: nil) }
    }

    private func apply(thunder: Double?, wave: Double? = nil, bubbles: Double? = nil, thunderQueue: [QueuedThunder] = []) {
        guard let a = box.ambience else { return }
        let s = state.withLockUnchecked { $0 }
        for source in AmbienceSource.allCases {
            let level = s.enabled ? s.scene.level(source) : 0
            isd_ambience_set_level(a, Self.cSource(source), Float(level))
        }
        isd_ambience_set_night_cool(a, Float(s.scene.nightCool))
        isd_ambience_set_closeness(a, Float(s.scene.closeness))
        isd_ambience_set_density(a, Float(s.scene.density))
        isd_ambience_set_activity(a, Float(max(s.scene.activity, s.playing ? 1 : 0)))
        isd_ambience_set_speed(a, Float(s.scene.speed))
        isd_ambience_set_surf_distance(a, Float(s.scene.surfDistance))
        isd_ambience_set_indoors(a, Float(s.scene.indoors))
        isd_ambience_set_wetness(a, Float(s.scene.wetness))
        isd_ambience_set_snow_on_glass(a, Float(s.scene.snowOnGlass))
        // The temple bell and the sonar take a new key at their next strike or ping; while the key can't be sensed
        // they stay where they are.
        if let key = s.scene.key { isd_ambience_set_key(a, Int32(clamping: key.root), key.major ? 1 : 0) }
        if let distance = thunder, s.enabled { isd_ambience_trigger_thunder(a, Float(distance)) }
        if let strength = wave, s.enabled { isd_ambience_trigger_wave(a, Float(strength)) }
        if let strength = bubbles, s.enabled { isd_ambience_trigger_bubbles(a, Float(strength)) }
        // After the levels: the engine hears a roll only while the thunder roll is up.
        if s.enabled { for roll in thunderQueue { isd_ambience_queue_thunder(a, Float(roll.delay), Float(roll.strength)) } }
    }

    static func cSource(_ s: AmbienceSource) -> ISDAmbienceSource {
        switch s {
        case .water: return ISD_AMB_WATER
        case .crickets: return ISD_AMB_CRICKETS
        case .breeze: return ISD_AMB_BREEZE
        case .owl: return ISD_AMB_OWL
        case .rainOnWater: return ISD_AMB_RAIN_WATER
        case .rainOnGlass: return ISD_AMB_RAIN_GLASS
        case .dawnChorus: return ISD_AMB_DAWN_CHORUS
        case .shipHum: return ISD_AMB_SHIP_HUM
        case .airFlow: return ISD_AMB_AIR_FLOW
        case .chime: return ISD_AMB_CHIME
        case .hullTicks: return ISD_AMB_HULL_TICKS
        case .wind: return ISD_AMB_WIND
        case .surf: return ISD_AMB_SURF
        case .palms: return ISD_AMB_PALMS
        case .gulls: return ISD_AMB_GULLS
        case .road: return ISD_AMB_ROAD
        case .engine: return ISD_AMB_ENGINE
        case .windowWind: return ISD_AMB_WINDOW_WIND
        case .passingCar: return ISD_AMB_PASSING_CAR
        case .fire: return ISD_AMB_FIRE
        case .kettle: return ISD_AMB_KETTLE
        case .street: return ISD_AMB_STREET
        case .drips: return ISD_AMB_DRIPS
        case .clock: return ISD_AMB_CLOCK
        case .iceGroan: return ISD_AMB_ICE_GROAN
        case .waterfall: return ISD_AMB_WATERFALL
        case .lapping: return ISD_AMB_LAPPING
        case .boat: return ISD_AMB_BOAT
        case .templeBell: return ISD_AMB_TEMPLE_BELL
        case .paperScreens: return ISD_AMB_PAPER_SCREENS
        case .waterKnocker: return ISD_AMB_WATER_KNOCKER
        case .warbler: return ISD_AMB_WARBLER
        case .sonar: return ISD_AMB_SONAR
        case .hullCreak: return ISD_AMB_HULL_CREAK
        case .whaleSong: return ISD_AMB_WHALE
        case .bubbles: return ISD_AMB_BUBBLES
        case .snappingShrimp: return ISD_AMB_SHRIMP
        case .fishChorus: return ISD_AMB_FISH_CHORUS
        case .grassWind: return ISD_AMB_GRASS_WIND
        case .hailOnTin: return ISD_AMB_HAIL_TIN
        case .birdsFlee: return ISD_AMB_BIRDS_FLEE
        case .thunderRoll: return ISD_AMB_THUNDER_ROLL
        case .inflowRoar: return ISD_AMB_INFLOW_ROAR
        case .rainOnDust: return ISD_AMB_RAIN_ON_DUST
        case .dryCicadas: return ISD_AMB_DRY_CICADAS
        case .windmill: return ISD_AMB_WINDMILL
        case .cattleGrid: return ISD_AMB_CATTLE_GRID
        case .dustTicks: return ISD_AMB_DUST_TICKS
        case .shimmerHum: return ISD_AMB_SHIMMER_HUM
        case .farTruck: return ISD_AMB_FAR_TRUCK
        }
    }

    // MARK: - Rendering

    private func make(rate newRate: Double) -> Bool {
        guard let fresh = isd_ambience_create(newRate, 4096, Self.seed) else { return false }
        if let old = box.ambience { box.retired.append(old) }
        box.ambience = fresh
        rate = newRate
        apply(thunder: nil)
        return true
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let busRate = outputBus.format.sampleRate
        if busRate != rate, !make(rate: busRate) { throw AudioEngineError.loadFailed("Ambience") }
        scratch = AVAudioPCMBuffer(pcmFormat: outputBus.format, frameCapacity: max(maximumFramesToRender, 4096))
        box.scratchL = scratch?.floatChannelData?[0]
        box.scratchR = outputBus.format.channelCount > 1 ? scratch?.floatChannelData?[1] : nil
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let box = self.box
        return { _, _, frameCount, _, outputData, _, _ in
            guard let ambience = box.ambience else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2 else { return kAudioUnitErr_FormatNotSupported }
            if buffers[0].mData == nil || buffers[1].mData == nil, let sl = box.scratchL, let sr = box.scratchR {
                buffers[0].mData = UnsafeMutableRawPointer(sl)
                buffers[1].mData = UnsafeMutableRawPointer(sr)
            }
            guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidParameter }
            isd_ambience_render(ambience, l, r, Int32(frameCount))
            buffers[0].mDataByteSize = frameCount * 4
            buffers[1].mDataByteSize = frameCount * 4
            return noErr
        }
    }
}
