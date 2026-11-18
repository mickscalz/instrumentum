import Foundation

/// The knobs of the effects and the tone that sit after the instrument. Each is 0…1, as a knob.
public enum FXParam: String, Codable, CaseIterable, Hashable {
    /// Tone: 0.5 is flat; left cuts (to −26 dB), right lifts (to +6 dB), like a DJ mixer's.
    case eqLow, eqMid, eqHigh
    /// 0.5 is off; left closes a low-pass, right opens a high-pass (the mixer's FILTER knob).
    case filter
    /// How much echo, how long between repeats, and how many repeats.
    case echo, echoTime, echoRepeats
    case reverb
    /// Warm overdrive, and a lo-fi crush.
    case drive, crush

    public var displayName: String {
        switch self {
        case .eqLow: return "Low"
        case .eqMid: return "Mid"
        case .eqHigh: return "High"
        case .filter: return "Filter"
        case .echo: return "Echo"
        case .echoTime: return "Echo time"
        case .echoRepeats: return "Echo repeats"
        case .reverb: return "Reverb"
        case .drive: return "Drive"
        case .crush: return "Crush"
        }
    }

    /// Where the knob does nothing.
    public var neutral: Double {
        switch self {
        case .eqLow, .eqMid, .eqHigh, .filter: return 0.5
        case .echo, .reverb, .drive, .crush: return 0
        case .echoTime: return 0.45
        case .echoRepeats: return 0.35
        }
    }

    /// The switch that silences it, if it has one.
    public var switchedBy: FXSwitch? {
        switch self {
        case .echo, .echoTime, .echoRepeats: return .echo
        case .reverb: return .reverb
        case .drive, .crush: return .drive
        case .eqLow, .eqMid, .eqHigh, .filter: return nil
        }
    }
}

/// The on/off switches (the effect box's buttons): everything, and the three effects under the numbered knobs.
public enum FXSwitch: String, Codable, CaseIterable, Hashable {
    case all, echo, reverb, drive

    public var displayName: String {
        switch self {
        case .all: return "Effects"
        case .echo: return "Echo"
        case .reverb: return "Reverb"
        case .drive: return "Drive"
        }
    }
}

/// The effects and tone after the instrument: every knob's position and every switch. Saved with the settings and in
/// each saved sound; a value that is missing, unreadable or out of range is the knob's neutral.
public struct SoundFX: Codable, Equatable {
    private var values: [String: Double] = [:]
    private var off: [String] = []

    public init() {}

    public subscript(param: FXParam) -> Double {
        get { values[param.rawValue] ?? param.neutral }
        set {
            let v = newValue.isFinite ? max(0, min(1, newValue)) : param.neutral
            if v == param.neutral { values[param.rawValue] = nil } else { values[param.rawValue] = v }
        }
    }

    public func isOn(_ s: FXSwitch) -> Bool { !off.contains(s.rawValue) }

    public mutating func set(_ s: FXSwitch, on: Bool) {
        off.removeAll { $0 == s.rawValue }
        if !on { off.append(s.rawValue); off.sort() }
    }

    public mutating func toggle(_ s: FXSwitch) { set(s, on: !isOn(s)) }

    /// The knob as the sound hears it: its neutral while its switch (or the whole section) is off.
    public func effective(_ param: FXParam) -> Double {
        guard isOn(.all) else { return param.neutral }
        if let s = param.switchedBy, !isOn(s) { return param.neutral }
        return self[param]
    }

    /// True when the sound is exactly the instrument's own: nothing is turned from its neutral (or it is switched off).
    public var isNeutral: Bool {
        FXMath.eqGainDB(effective(.eqLow)) == 0 && FXMath.eqGainDB(effective(.eqMid)) == 0
            && FXMath.eqGainDB(effective(.eqHigh)) == 0 && FXMath.filter(effective(.filter)) == .off
            && effective(.echo) < FXMath.silent && effective(.reverb) < FXMath.silent
            && effective(.drive) < FXMath.silent && effective(.crush) < FXMath.silent
    }

    enum CodingKeys: String, CodingKey { case values, off }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: Double].self, forKey: .values)) ?? [:]
        for (key, value) in raw {
            guard let p = FXParam(rawValue: key) else { continue }
            self[p] = value
        }
        let switches = (try? c.decodeIfPresent([String].self, forKey: .off)) ?? []
        for name in switches {
            if let s = FXSwitch(rawValue: name) { set(s, on: false) }
        }
    }
}

/// What a knob position means in decibels, hertz and seconds. Pure arithmetic, pinned by tests.
public enum FXMath {
    /// Below this an effect's amount counts as none.
    public static let silent = 0.004
    /// The EQ's centre detent: this far either side of 0.5 is flat.
    static let detent = 0.02
    static let cutDB = -26.0, boostDB = 6.0

    /// 0.5 → 0 dB; 0 → −26 dB; 1 → +6 dB.
    public static func eqGainDB(_ knob: Double) -> Double {
        let d = max(0, min(1, knob)) - 0.5
        if abs(d) <= detent { return 0 }
        let span = 0.5 - detent
        return d < 0 ? cutDB * (-d - detent) / span : boostDB * (d - detent) / span
    }

    public enum Filter: Equatable {
        case off
        /// Lets through what is below (low-pass) or above (high-pass) this many hertz.
        case lowPass(Double), highPass(Double)
    }

    /// 0.5 (±0.03) is off; left sweeps a low-pass from 18 kHz down to 90 Hz; right sweeps a high-pass from 30 Hz up to 6 kHz.
    public static func filter(_ knob: Double) -> Filter {
        let k = max(0, min(1, knob))
        let edge = 0.03
        if abs(k - 0.5) <= edge { return .off }
        if k < 0.5 {
            let t = (0.5 - edge - k) / (0.5 - edge)          // 0 just left of centre … 1 fully left
            return .lowPass(18_000 * pow(90.0 / 18_000, t))
        }
        let t = (k - 0.5 - edge) / (0.5 - edge)
        return .highPass(30 * pow(6_000.0 / 30, t))
    }

    /// 60 ms … 1.2 s between repeats.
    public static func echoSeconds(_ knob: Double) -> Double {
        0.06 * pow(1.2 / 0.06, max(0, min(1, knob)))
    }

    /// How much of each repeat feeds the next, in percent (never enough to run away).
    public static func echoFeedbackPercent(_ knob: Double) -> Double { 80 * max(0, min(1, knob)) }

    /// The echo's and the reverb's share of the sound, in percent.
    public static func echoMixPercent(_ knob: Double) -> Double { 45 * max(0, min(1, knob)) }
    public static func reverbMixPercent(_ knob: Double) -> Double { 55 * max(0, min(1, knob)) }

    /// The overdrive's share of the sound in percent (it comes in gently), and how hard it is pushed, in dB.
    public static func driveMixPercent(_ knob: Double) -> Double { min(100, 140 * max(0, min(1, knob))) }
    public static func driveGainDB(_ knob: Double) -> Double { -6 + 20 * max(0, min(1, knob)) }
    /// Turned down as the drive goes up, so Drive changes the colour more than the volume.
    public static func driveMakeupDB(_ knob: Double) -> Double { -4 * max(0, min(1, knob)) }

    /// The crush's share of the sound and how coarse it is, both in percent.
    public static func crushMixPercent(_ knob: Double) -> Double { min(100, 150 * max(0, min(1, knob))) }
    public static func crushDecimationPercent(_ knob: Double) -> Double { 15 + 55 * max(0, min(1, knob)) }
}
