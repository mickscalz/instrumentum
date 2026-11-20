import CoreAudio
import Foundation

/// A sound output the Mac knows about (speakers, headphones, an audio interface, a Bluetooth speaker…).
public struct OutputDevice: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    /// Stable across launches and reconnections (what the settings remember).
    public let uid: String
    public let name: String

    public init(id: AudioDeviceID, uid: String, name: String) {
        self.id = id; self.uid = uid; self.name = name
    }
}

/// Core Audio lookups for devices: the outputs here, and the helpers the Recorder's inputs share (`InputDevices`).
enum CoreAudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every device the Mac knows about, in the system's order.
    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Every device with at least one output channel, in the system's order.
    static func outputs() -> [OutputDevice] {
        var seen = Set<String>()
        return allDevices().compactMap { id in
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty, seen.insert(uid).inserted else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Output"
            return OutputDevice(id: id, uid: uid, name: name.isEmpty ? "Output" : name)
        }
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func device(uid: String) -> AudioDeviceID? { outputs().first { $0.uid == uid }?.id }

    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// False once a device has been unplugged or switched off (it can stay in the list for a moment).
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int { channels(id, scope: kAudioDevicePropertyScopeOutput) }

    /// The device's input channels, over all its input streams (0 for an output-only device).
    static func inputChannels(_ id: AudioDeviceID) -> Int { channels(id, scope: kAudioDevicePropertyScopeInput) }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// A whole-number property (a latency, a buffer size, a transport type); nil if the object doesn't report it.
    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// A device's nominal sample rate in Hz; nil if it doesn't report one.
    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    /// The device's input streams (their own latencies add to the device's).
    static func inputStreams(_ id: AudioDeviceID) -> [AudioStreamID] {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }
}
