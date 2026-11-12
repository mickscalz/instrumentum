import Foundation

/// What holds the moment (Small Wins spec §4): the soft pedal (CC 67) while it is down, the sostenuto pedal (CC 66)
/// instead, or neither.
public enum HoldPedal: String, Codable, CaseIterable {
    case soft, sostenuto, off

    /// The pedal's controller number; nil when no pedal holds the moment.
    public var controller: UInt8? {
        switch self {
        case .soft: return 67
        case .sostenuto: return 66
        case .off: return nil
        }
    }

    /// As Sound & MIDI's "Hold the moment with" shows it.
    public var displayName: String {
        switch self {
        case .soft: return "Soft pedal"
        case .sostenuto: return "Sostenuto pedal"
        case .off: return "Off"
        }
    }
}

/// The MIDI keyboard's range (Sound & MIDI's "Keyboard layout"), so the key gesture finds its top three black keys
/// (spec §2). Notes are MIDI numbers, with middle C (60) as C4.
public enum KeyboardRange: String, Codable, CaseIterable {
    case keys88, keys76, keys61, keys49

    public var low: UInt8 {
        switch self {
        case .keys88: return 21
        case .keys76: return 28
        case .keys61, .keys49: return 36
        }
    }

    public var high: UInt8 {
        switch self {
        case .keys88: return 108
        case .keys76: return 103
        case .keys61: return 96
        case .keys49: return 84
        }
    }

    public var displayName: String {
        switch self {
        case .keys88: return "88 keys (A0–C8)"
        case .keys76: return "76 keys (E1–G7)"
        case .keys61: return "61 keys (C2–C7)"
        case .keys49: return "49 keys (C2–C6)"
        }
    }
}

/// Breathing ambience (spec §5): the beds swell and recede on their own. It lives in the app's settings, not in a
/// set's `AmbienceSettings`, so applying a set leaves it alone.
public struct AmbienceBreathSettings: Codable, Equatable {
    public static let depthRange: ClosedRange<Double> = 0...1.5

    public var enabled: Bool
    /// How far the beds swing, × the breath's ±25% (1 by default); always within `depthRange`.
    public var depth: Double { didSet { depth = Self.clamped(depth) } }

    public init(enabled: Bool = true, depth: Double = 1.0) {
        self.enabled = enabled
        self.depth = Self.clamped(depth)
    }

    enum CodingKeys: String, CodingKey { case enabled, depth }

    /// Missing or bad values take their defaults; a depth out of range is clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmbienceBreathSettings()
        self.init(enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled,
                  depth: (try? c.decodeIfPresent(Double.self, forKey: .depth)) ?? d.depth)
    }

    static func clamped(_ depth: Double) -> Double { min(depthRange.upperBound, max(depthRange.lowerBound, depth)) }
}

/// What the app asks of `SceneDirector`'s clock each frame: hold the moment, the sleep fade's dim, the Mac's Reduce
/// Motion and breathing (spec §3–§6). The defaults change nothing. Never saved.
public struct SceneControls: Equatable {
    /// Hold the moment from the hourglass or ⌘⇧H (the hold pedal is read from the playing).
    public var holdRequested: Bool
    /// The pedal that holds the moment.
    public var holdPedal: HoldPedal
    /// The sleep fade's dim, 0…1 (clamped): toward night, a stop darker, the world at up to half speed.
    public var sleepDim: Double { didSet { sleepDim = Self.clampedDim(sleepDim) } }
    /// The Mac's Reduce Motion, when the app follows it.
    public var reduceMotion: Bool
    public var breath: AmbienceBreathSettings
    /// Gentle visuals as the canvas draws them (yours, or Reduce Motion's while the app follows it): worlds hold back their
    /// alarms (the drive's far siren). It reaches them on the Excitement frame.
    public var gentle: Bool

    public init(holdRequested: Bool = false, holdPedal: HoldPedal = .soft, sleepDim: Double = 0.0, reduceMotion: Bool = false,
                breath: AmbienceBreathSettings = AmbienceBreathSettings(), gentle: Bool = false) {
        self.holdRequested = holdRequested
        self.holdPedal = holdPedal
        self.sleepDim = Self.clampedDim(sleepDim)
        self.reduceMotion = reduceMotion
        self.breath = breath
        self.gentle = gentle
    }

    static func clampedDim(_ dim: Double) -> Double { min(1, max(0, dim)) }
}

/// What `SceneDirector` says about the frame it just stepped: whether time is held, the sky and the key the player is
/// in (for the hourglass and the note beside a kept take).
public struct SceneReport: Equatable {
    public var holding: Bool
    public var sky: SkyState?
    public var key: AmbienceKey?

    public init(holding: Bool = false, sky: SkyState? = nil, key: AmbienceKey? = nil) {
        self.holding = holding
        self.sky = sky
        self.key = key
    }
}
