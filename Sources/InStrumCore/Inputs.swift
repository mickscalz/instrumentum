import Foundation

public enum InputFamily: String, CaseIterable, Codable, CodingKeyRepresentable {
    case keys, playing, sound, dials, listening

    public var displayName: String {
        switch self {
        case .keys: return "Keys"
        case .playing: return "Playing"
        case .sound: return "Sound"
        case .dials: return "Instrument dials"
        case .listening: return "Listening"
        }
    }
}

/// A named input, e.g. "keys.velocity". The family is the part before the dot.
public struct InputID: Hashable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { rawValue = raw }

    public var family: InputFamily {
        InputFamily(rawValue: String(rawValue.prefix { $0 != "." })) ?? .keys
    }

    // Keys
    public static let velocity = InputID("keys.velocity")
    public static let held = InputID("keys.held")
    public static let pedal = InputID("keys.pedal")
    public static let softPedal = InputID("keys.softPedal")
    public static let sostenuto = InputID("keys.sostenuto")
    public static let modWheel = InputID("keys.modWheel")
    public static let pitchBend = InputID("keys.pitchBend")
    public static let pressure = InputID("keys.pressure")
    public static let expression = InputID("keys.expression")
    public static let releaseSpeed = InputID("keys.releaseSpeed")
    public static func cc(_ n: UInt8) -> InputID { InputID("keys.cc\(n)") }
    // Playing
    public static let busyness = InputID("playing.busyness")
    public static let direction = InputID("playing.direction")
    public static let leap = InputID("playing.leap")
    public static let crescendo = InputID("playing.crescendo")
    public static let spread = InputID("playing.spread")
    public static let repetition = InputID("playing.repetition")
    public static let silence = InputID("playing.silence")
    public static let chordMajor = InputID("playing.chordMajor")
    public static let chordMinor = InputID("playing.chordMinor")
    public static let chordTense = InputID("playing.chordTense")
    // Sound
    public static let attack = InputID("sound.attack")
    public static let brightness = InputID("sound.brightness")
    public static let ring = InputID("sound.ring")
    public static let texture = InputID("sound.texture")
    public static let loudness = InputID("sound.loudness")
    public static let width = InputID("sound.width")
    // Dials
    public static func dial(_ address: UInt64) -> InputID { InputID("dials.\(address)") }
    // Listening
    public static let level = InputID("listening.level")
    public static let bass = InputID("listening.bass")
    public static let mid = InputID("listening.mid")
    public static let treble = InputID("listening.treble")
    public static let beat = InputID("listening.beat")

    /// The Mac's Reduce Motion while the app follows it (Small Wins spec §6): 1 or 0. The director puts it into every
    /// step's frame itself, never into the hub, so the mapping editor never offers it; Galaxy Warp drifts while it is up.
    public static let reduceMotion = InputID("comfort.reduceMotion")
}

/// Smoothed input values for one frame. Missing inputs read 0.
public struct InputFrame {
    public var values: [InputID: Double]
    public init(values: [InputID: Double] = [:]) { self.values = values }
    public subscript(_ id: InputID) -> Double { values[id] ?? 0 }
}

/// Collects raw inputs and smooths them (fast rise, slower fall). Not thread-safe:
/// use from one thread (the render loop).
public final class InputHub {
    public static let riseTime = 0.03
    public static let fallTime = 0.25

    private var target: [InputID: Double] = [:]
    private var current: [InputID: Double] = [:]
    private var lastTime: Double?

    public init() {}

    /// Sets a held value (pedal, mod wheel, busyness…).
    public func set(_ id: InputID, _ value: Double, at t: Double) {
        advance(to: t)
        target[id] = value
    }

    /// A momentary value (velocity, beat): jumps up immediately, then fades.
    public func pulse(_ id: InputID, _ value: Double, at t: Double) {
        advance(to: t)
        current[id] = max(current[id] ?? 0, value)
        target[id] = 0
    }

    public func frame(at t: Double, listenStrength: Double) -> InputFrame {
        advance(to: t)
        var out: [InputID: Double] = [:]
        for (id, v) in current { out[id] = id.family == .listening ? v * listenStrength : v }
        return InputFrame(values: out)
    }

    /// The unsmoothed value last set (for tests and inspection).
    public func rawTarget(_ id: InputID) -> Double { target[id] ?? current[id] ?? 0 }

    /// All inputs seen so far (for the mapping editor).
    public var knownInputs: [InputID] { Array(Set(target.keys).union(current.keys)) }

    private func advance(to t: Double) {
        guard let last = lastTime else { lastTime = t; return }
        let dt = t - last
        guard dt > 0 else { return }
        lastTime = t
        for (id, goal) in target {
            let now = current[id] ?? 0
            let tau = goal > now ? Self.riseTime : Self.fallTime
            current[id] = goal + (now - goal) * exp(-dt / tau)
        }
    }
}

extension InputID {
    /// Every built-in input, in display order (CCs and instrument dials are added as they appear).
    public static let standard: [InputID] = [
        .velocity, .held, .releaseSpeed, .pedal, .softPedal, .sostenuto, .modWheel, .pitchBend, .pressure, .expression,
        .chordMajor, .chordMinor, .chordTense, .direction, .leap, .busyness, .crescendo, .spread, .repetition, .silence,
        .attack, .brightness, .ring, .texture, .loudness, .width,
        .level, .bass, .mid, .treble, .beat,
    ]

    private static let names: [String: String] = [
        "keys.velocity": "How hard (velocity)", "keys.held": "Notes held", "keys.releaseSpeed": "Release speed",
        "keys.pedal": "Sustain pedal", "keys.softPedal": "Soft pedal", "keys.sostenuto": "Sostenuto pedal",
        "keys.modWheel": "Mod wheel", "keys.pitchBend": "Pitch bend", "keys.pressure": "Aftertouch", "keys.expression": "Expression pedal",
        "playing.chordMajor": "Major chord", "playing.chordMinor": "Minor chord", "playing.chordTense": "Tense chord",
        "playing.direction": "Melody up / down", "playing.leap": "Big leaps", "playing.busyness": "Fast, busy playing",
        "playing.crescendo": "Building up / fading", "playing.spread": "Hands spread wide", "playing.repetition": "Repeated patterns",
        "playing.silence": "Silence",
        "sound.attack": "Sharp vs smooth sound", "sound.brightness": "Bright vs dark sound", "sound.ring": "Long ringing sound",
        "sound.texture": "Textured / noisy sound", "sound.loudness": "Actual loudness", "sound.width": "Stereo width",
        "listening.level": "Listen: level", "listening.bass": "Listen: bass", "listening.mid": "Listen: mids",
        "listening.treble": "Listen: treble", "listening.beat": "Listen: beat",
    ]

    public var displayName: String {
        if let n = Self.names[rawValue] { return n }
        if rawValue.hasPrefix("keys.cc") { return "Knob / fader CC \(rawValue.dropFirst("keys.cc".count))" }
        if rawValue.hasPrefix("dials.") { return "Instrument dial \(rawValue.dropFirst("dials.".count))" }
        return rawValue
    }
}
