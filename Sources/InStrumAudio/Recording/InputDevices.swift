import CoreAudio
import Foundation
import InStrumCore

/// A sound input the Mac knows about (Recorder spec §5.2, §6): a microphone, an audio interface, an effects unit's USB
/// return, BlackHole, an aggregate device.
public struct InputDevice: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    /// Stable across launches and reconnections (what the settings remember).
    public let uid: String
    public let name: String
    /// Input channels, over all its input streams.
    public let channels: Int
    /// The Mac's own microphone (or line input): Hear it starts off for it, so it never feeds back (spec §6).
    public var isBuiltInMicrophone: Bool

    public init(id: AudioDeviceID, uid: String, name: String, channels: Int, isBuiltInMicrophone: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.channels = channels
        self.isBuiltInMicrophone = isBuiltInMicrophone
    }

    /// BlackHole, the free virtual device the Mac's sound can be sent to (spec §5.2).
    public var isBlackHole: Bool { InputDevices.isBlackHole(name: name) }
}

/// Which of an input's channels play: one channel (centred, the same on both sides) or a pair (left, right). 0-based.
public struct ChannelChoice: Codable, Equatable, Hashable, Sendable {
    public var left: Int
    /// nil: mono, centred.
    public var right: Int?

    public init(left: Int, right: Int? = nil) {
        self.left = left
        self.right = right
    }

    /// 1, 2, 1+2, 3, 4, 3+4, … for an input with this many channels (spec §6).
    public static func choices(channels: Int) -> [ChannelChoice] {
        guard channels > 0 else { return [] }
        var all: [ChannelChoice] = []
        var c = 0
        while c < channels {
            all.append(ChannelChoice(left: c))
            if c + 1 < channels {
                all.append(ChannelChoice(left: c + 1))
                all.append(ChannelChoice(left: c, right: c + 1))
            }
            c += 2
        }
        return all
    }

    /// 1+2 for an input with two channels or more, else 1.
    public static func defaultChoice(channels: Int) -> ChannelChoice {
        channels >= 2 ? ChannelChoice(left: 0, right: 1) : ChannelChoice(left: 0)
    }

    /// "1", "1+2" (1-based, as on the interface's front panel).
    public var label: String {
        guard let right else { return "\(left + 1)" }
        return "\(left + 1)+\(right + 1)"
    }

    /// Whether an input with this many channels has every channel this choice plays.
    public func fits(channels: Int) -> Bool {
        left >= 0 && left < channels && (right.map { $0 >= 0 && $0 < channels } ?? true)
    }
}

/// The Mac's inputs, read from Core Audio (Recorder spec §5.2, §6).
public enum InputDevices {
    /// Every device with at least one input channel, in the system's order. Empty on a Mac with no inputs.
    public static func all() -> [InputDevice] {
        var seen = Set<String>()
        return CoreAudioDevices.allDevices().compactMap { id in
            let channels = CoreAudioDevices.inputChannels(id)
            guard channels > 0, let uid = CoreAudioDevices.string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                  seen.insert(uid).inserted else { return nil }
            let name = CoreAudioDevices.string(id, kAudioObjectPropertyName) ?? ""
            let builtIn = CoreAudioDevices.uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
            return InputDevice(id: id, uid: uid, name: name.isEmpty ? "Input" : name, channels: channels, isBuiltInMicrophone: builtIn)
        }
    }

    /// The BlackHole input to play the Mac's sound along from, if it is installed.
    public static func blackHole() -> InputDevice? { blackHole(in: all()) }

    /// The stereo BlackHole first (the Mac's sound is stereo), else any.
    static func blackHole(in devices: [InputDevice]) -> InputDevice? {
        let holes = devices.filter(\.isBlackHole)
        return holes.first { $0.channels == 2 } ?? holes.first
    }

    /// "BlackHole 2ch", "BlackHole 16ch", "BlackHole 64ch" (a name that starts with the word "BlackHole"); not
    /// "Black Hole Reverb" or "BlackHoleVerb".
    public static func isBlackHole(name: String) -> Bool {
        let word = "BlackHole"
        guard name.hasPrefix(word) else { return false }
        let rest = name.dropFirst(word.count)
        return rest.isEmpty || rest.first == " "
    }

    /// The input side's latency as Core Audio reports it, in frames at the device's own rate: the device's latency and
    /// its first input stream's, its safety offset, and its I/O buffer. Zeros for a device that reports nothing.
    public static func latency(_ id: AudioDeviceID) -> RecordingLatency.Device {
        let input = kAudioDevicePropertyScopeInput
        let device = CoreAudioDevices.uint32(id, kAudioDevicePropertyLatency, input) ?? 0
        let stream = CoreAudioDevices.inputStreams(id).first.flatMap { CoreAudioDevices.uint32($0, kAudioStreamPropertyLatency) } ?? 0
        let safety = CoreAudioDevices.uint32(id, kAudioDevicePropertySafetyOffset, input) ?? 0
        let buffer = CoreAudioDevices.uint32(id, kAudioDevicePropertyBufferFrameSize) ?? 0
        return RecordingLatency.Device(latencyFrames: Int(device) + Int(stream), safetyFrames: Int(safety), bufferFrames: Int(buffer))
    }

    /// The device's nominal sample rate in Hz; nil if it doesn't report one.
    public static func sampleRate(_ id: AudioDeviceID) -> Double? { CoreAudioDevices.nominalSampleRate(id) }
}
