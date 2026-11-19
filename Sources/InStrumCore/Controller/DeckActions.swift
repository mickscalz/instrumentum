import Foundation

/// The world and its sky as a knob sees them: each is 0…1 on the knob.
public enum WorldParam: String, Codable, CaseIterable, Hashable {
    /// The mood, which shapes the world, the built-in instrument and the ambience together.
    case moodEnergy, moodWarmth, moodBrightness, moodSpace, moodMotion
    /// The sky's clock and moon (turning either freezes the time, so it stays where the knob put it).
    case timeOfDay, moonPhase
    /// The weather's strength: 0.5 on the knob is as designed.
    case wind, mist, clouds, stars, rain, snow, lightning, moonSize
    /// How close the ambience is, and Excitement's energy set by hand.
    case closeness, energy
    /// The look's six macros: 0.5 on the knob is as designed.
    case intensity, speed, density, glow, chaos, temperature

    public var displayName: String {
        switch self {
        case .moodEnergy: return "Mood: energy"
        case .moodWarmth: return "Mood: warmth"
        case .moodBrightness: return "Mood: brightness"
        case .moodSpace: return "Mood: space"
        case .moodMotion: return "Mood: motion"
        case .timeOfDay: return "Time of day"
        case .moonPhase: return "Moon phase"
        case .wind: return "Wind"
        case .mist: return "Mist and haze"
        case .clouds: return "Clouds"
        case .stars: return "Stars"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .lightning: return "Lightning"
        case .moonSize: return "Moon size"
        case .closeness: return "Ambience closeness"
        case .energy: return "Excitement energy"
        case .intensity: return "Look: intensity"
        case .speed: return "Look: speed"
        case .density: return "Look: density"
        case .glow: return "Look: glow"
        case .chaos: return "Look: calm to chaos"
        case .temperature: return "Look: colour temperature"
        }
    }

    /// The look macro this is, if it is one.
    public var macro: Macro? {
        switch self {
        case .intensity: return .intensity
        case .speed: return .speed
        case .density: return .density
        case .glow: return .glow
        case .chaos: return .chaos
        case .temperature: return .temperature
        default: return nil
        }
    }

    /// The value's range, and (for the scales) the designed value that sits at the knob's centre.
    var range: (low: Double, high: Double, centre: Double?) {
        switch self {
        case .moodEnergy, .moodWarmth, .moodBrightness, .moodSpace, .moodMotion, .closeness, .energy, .moonPhase:
            return (0, 1, nil)
        case .timeOfDay: return (0, 23.99, nil)
        case .wind, .mist, .rain, .snow: return (0, 2, 1)
        case .clouds, .stars: return (0, 1.5, 1)
        case .lightning: return (0.25, 3, 1)
        case .moonSize: return (0.5, 3, 1)
        case .intensity, .speed, .density, .glow, .chaos, .temperature: return (-1, 1, 0)
        }
    }

    /// The value a knob position (0…1) means. A scale's designed value is at the centre, whatever its range.
    public func value(knob: Double) -> Double {
        let k = knob.isFinite ? max(0, min(1, knob)) : 0.5
        let r = range
        guard let centre = r.centre else { return r.low + k * (r.high - r.low) }
        return k < 0.5 ? r.low + (k / 0.5) * (centre - r.low) : centre + ((k - 0.5) / 0.5) * (r.high - centre)
    }

    /// The knob position a value sits at (the inverse of `value(knob:)`).
    public func knob(value: Double) -> Double {
        let r = range
        let v = value.isFinite ? max(r.low, min(r.high, value)) : (r.centre ?? r.low)
        guard let centre = r.centre else { return (v - r.low) / (r.high - r.low) }
        return v < centre ? 0.5 * (v - r.low) / (centre - r.low) : 0.5 + 0.5 * (v - centre) / (r.high - centre)
    }
}

/// What a button does.
public enum DeckAction: String, Codable, CaseIterable, Hashable {
    case none
    // Effects and tone.
    case fxAll, fxEcho, fxReverb, fxDrive, fxReset
    // Saved sounds.
    case soundNext, soundPrevious, soundSave
    case sound1, sound2, sound3, sound4, sound5, sound6, sound7, sound8
    // The instrument.
    case presetNext, presetPrevious, presetReload, instrumentNext, instrumentPrevious
    case transposeUp, transposeDown
    // Playing.
    case hold, panic, keepThat, keepTenMinutes, testNote, mute
    // The world.
    case worldNext, worldPrevious, setNext, setPrevious, setRestore, surprise, reactionNext, moodReset
    // The sky.
    case weatherNext, weatherPrevious, weatherRandom, weatherClear, weatherRain, weatherStorm, weatherSnow
    case timeMode, timeMorning, timeMidday, timeEvening, timeNight
    // The app.
    case ambience, gentle, sleepTimer, fullScreen

    public enum Group: String, CaseIterable {
        case effects = "Effects", sounds = "Saved sounds", instrument = "Instrument", playing = "Playing"
        case world = "World", sky = "Sky", app = "App"
    }

    public var group: Group? {
        switch self {
        case .none: return nil
        case .fxAll, .fxEcho, .fxReverb, .fxDrive, .fxReset: return .effects
        case .soundNext, .soundPrevious, .soundSave, .sound1, .sound2, .sound3, .sound4, .sound5, .sound6, .sound7, .sound8:
            return .sounds
        case .presetNext, .presetPrevious, .presetReload, .instrumentNext, .instrumentPrevious, .transposeUp,
             .transposeDown:
            return .instrument
        case .hold, .panic, .keepThat, .keepTenMinutes, .testNote, .mute: return .playing
        case .worldNext, .worldPrevious, .setNext, .setPrevious, .setRestore, .surprise, .reactionNext, .moodReset: return .world
        case .weatherNext, .weatherPrevious, .weatherRandom, .weatherClear, .weatherRain, .weatherStorm, .weatherSnow,
             .timeMode, .timeMorning, .timeMidday, .timeEvening, .timeNight:
            return .sky
        case .ambience, .gentle, .sleepTimer, .fullScreen: return .app
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .fxAll: return "All effects on / off"
        case .fxEcho: return "Echo on / off"
        case .fxReverb: return "Reverb on / off"
        case .fxDrive: return "Drive on / off"
        case .fxReset: return "Reset effects and tone"
        case .soundNext: return "Next saved sound"
        case .soundPrevious: return "Previous saved sound"
        case .soundSave: return "Save this sound"
        case .sound1: return "Saved sound 1"
        case .sound2: return "Saved sound 2"
        case .sound3: return "Saved sound 3"
        case .sound4: return "Saved sound 4"
        case .sound5: return "Saved sound 5"
        case .sound6: return "Saved sound 6"
        case .sound7: return "Saved sound 7"
        case .sound8: return "Saved sound 8"
        case .presetNext: return "Next preset"
        case .presetPrevious: return "Previous preset"
        case .presetReload: return "Dials back to the preset"
        case .instrumentNext: return "Next instrument"
        case .instrumentPrevious: return "Previous instrument"
        case .transposeUp: return "Transpose up a semitone"
        case .transposeDown: return "Transpose down a semitone"
        case .hold: return "Hold the moment on / off"
        case .panic: return "All notes off"
        case .keepThat: return "Keep that"
        case .keepTenMinutes: return "Keep the last ten minutes"
        case .testNote: return "Play a test note"
        case .mute: return "Mute on / off"
        case .worldNext: return "Next world"
        case .worldPrevious: return "Previous world"
        case .setNext: return "Next set"
        case .setPrevious: return "Previous set"
        case .setRestore: return "Set back as designed"
        case .surprise: return "Surprise me (a new look)"
        case .reactionNext: return "Next reaction style"
        case .moodReset: return "Mood back to the set's"
        case .weatherNext: return "Next weather"
        case .weatherPrevious: return "Previous weather"
        case .weatherRandom: return "Random weather on / off"
        case .weatherClear: return "Weather: clear"
        case .weatherRain: return "Weather: rain"
        case .weatherStorm: return "Weather: storm"
        case .weatherSnow: return "Weather: snow"
        case .timeMode: return "Time: quick day, real, frozen"
        case .timeMorning: return "Time: morning"
        case .timeMidday: return "Time: midday"
        case .timeEvening: return "Time: evening"
        case .timeNight: return "Time: night"
        case .ambience: return "Ambience on / off"
        case .gentle: return "Gentle visuals on / off"
        case .sleepTimer: return "Sleep timer on / off"
        case .fullScreen: return "Full screen on / off"
        }
    }

    /// Which saved sound (0-based) a `sound1`…`sound8` action recalls.
    public var soundSlot: Int? {
        switch self {
        case .sound1: return 0
        case .sound2: return 1
        case .sound3: return 2
        case .sound4: return 3
        case .sound5: return 4
        case .sound6: return 5
        case .sound7: return 6
        case .sound8: return 7
        default: return nil
        }
    }

    /// The frozen hour a `time…` action jumps to.
    public var hour: Double? {
        switch self {
        case .timeMorning: return 6.75
        case .timeMidday: return 12.5
        case .timeEvening: return 18.75
        case .timeNight: return 23.5
        default: return nil
        }
    }

    /// The weather a `weather…` action picks.
    public var weather: WeatherKind? {
        switch self {
        case .weatherClear: return .clear
        case .weatherRain: return .rain
        case .weatherStorm: return .storm
        case .weatherSnow: return .snow
        default: return nil
        }
    }
}

/// What a wheel turns.
public enum WheelTarget: String, Codable, CaseIterable, Hashable {
    case none
    /// Steps through a list, one item per unit.
    case presets, instruments, sounds, worlds, sets, weather
    /// Scrubs the sky's clock (half an hour per unit) and the moon (a thirty-second of its cycle per unit).
    case timeOfDay, moonPhase
    /// Nudges the app's volume and the ambience's (3 % per unit).
    case volume, ambience

    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .presets: return "Presets"
        case .instruments: return "Instruments"
        case .sounds: return "Saved sounds"
        case .worlds: return "Worlds"
        case .sets: return "Sets"
        case .weather: return "Weather"
        case .timeOfDay: return "Time of day"
        case .moonPhase: return "Moon phase"
        case .volume: return "Volume"
        case .ambience: return "Ambience volume"
        }
    }

    /// True for the list-stepping targets.
    public var steps: Bool {
        switch self {
        case .presets, .instruments, .sounds, .worlds, .sets, .weather: return true
        default: return false
        }
    }

    public static let hoursPerUnit = 0.5
    public static let phasePerUnit = 1.0 / 32
    public static let volumePerUnit = 0.03

    /// Hours of sky for a jog wheel's turn since the last look at it (about a twentieth of a second ago), by how fast
    /// it is turning: about an hour a full turn when turned slowly, for precision, rising to several hours a turn when
    /// spun (never more than eight times the slow rate). `units` are eighths of a turn.
    ///
    /// The top of the wheel (a hand on the disc, `search` false) is the precise one: ten minutes a full turn when
    /// turned slowly, at most three times that. The outer edge (`search` true) covers ground: half an hour a turn
    /// slowly, up to three hours a turn when spun.
    public static func jogHours(units: Double, search: Bool) -> Double {
        let slowHoursPerUnit = search ? 0.5 / 8 : (1.0 / 6) / 8
        let most = search ? 6.0 : 3.0
        let faster = min(most, 1 + 6.25 * abs(units))
        return units * slowHoursPerUnit * faster
    }

    /// The frozen hour moved on by this many hours (round the clock in either direction, always 0 ..< 24).
    public static func hour(_ hour: Double, movedBy hours: Double) -> Double {
        let h = (hour + hours).truncatingRemainder(dividingBy: 24)
        return min(23.99, h < 0 ? h + 24 : h)
    }

    /// The frozen hour after a wheel turned `units` (round the clock in either direction, always 0 ..< 24).
    public static func hour(_ hour: Double, turnedBy units: Double) -> Double {
        let h = (hour + units * hoursPerUnit).truncatingRemainder(dividingBy: 24)
        return min(23.99, h < 0 ? h + 24 : h)
    }

    /// The moon's phase after a wheel turned `units` (round the cycle in either direction, always 0 ..< 1).
    public static func phase(_ phase: Double, turnedBy units: Double) -> Double {
        let p = (phase + units * phasePerUnit).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }

    /// Whole steps to take now from what a wheel has turned so far, and what is left over for next time.
    public static func steps(from turned: Double) -> (steps: Int, left: Double) {
        let n = Int(turned.rounded(.towardZero))
        return (n, turned - Double(n))
    }

    /// The item `by` places on from `current` in a list of `count`, round the ends. With nothing current, stepping
    /// forward starts at the first and stepping back at the last.
    public static func index(after current: Int?, by: Int, count: Int) -> Int? {
        guard count > 0, by != 0 else { return nil }
        let start = current ?? (by > 0 ? -1 : 0)
        return ((start + by) % count + count) % count
    }
}

/// Which button does what, and which wheel turns what. Saved with the settings; anything missing or unreadable is the
/// default.
public struct ButtonLayout: Codable, Equatable {
    private var actions: [String: DeckAction] = [:]
    private var wheels: [String: WheelTarget] = [:]

    public init() {}

    public subscript(key: DeckKey) -> DeckAction {
        get { actions[key.id] ?? Self.defaultAction(key) }
        set { actions[key.id] = newValue }
    }

    public subscript(wheel: DeckWheel) -> WheelTarget {
        get { wheels[wheel.id] ?? Self.defaultTarget(wheel) }
        set { wheels[wheel.id] = newValue }
    }

    /// Out of the box: **the left deck is the instrument and the playing, the right deck is the world and its sky.**
    public static func defaultAction(_ key: DeckKey) -> DeckAction {
        switch (key.side, key.button) {
        // The effect boxes.
        case (.left, .on): return .fxAll
        case (.left, .one): return .fxEcho
        case (.left, .two): return .fxReverb
        case (.left, .three): return .fxDrive
        case (.right, .on): return .soundNext
        case (.right, .one): return .presetPrevious
        case (.right, .two): return .presetNext
        case (.right, .three): return .fxReset
        // The left deck: the instrument and the playing.
        case (.left, .play): return .hold
        case (.left, .cue): return .panic
        case (.left, .sync): return .keepThat
        case (.left, .keylock): return .soundSave
        case (.left, .vinyl): return .soundPrevious
        case (.left, .loopIn): return .instrumentPrevious
        case (.left, .loopOut): return .instrumentNext
        case (.left, .loopPress): return .presetReload
        case (.left, .hotCue1): return .sound1
        case (.left, .hotCue2): return .sound2
        case (.left, .hotCue3): return .sound3
        case (.left, .hotCue4): return .sound4
        // The eight SAMPLER buttons, left to right across the controller (Michael's, 19 Nov): previous and next set,
        // world and instrument, then transpose down and up.
        case (.left, .sampler1): return .setPrevious
        case (.left, .sampler2): return .setNext
        case (.left, .sampler3): return .worldPrevious
        case (.left, .sampler4): return .worldNext
        case (.left, .load): return .setPrevious
        case (.left, .headphoneCue): return .testNote
        case (.left, .assignFX1): return .ambience
        case (.left, .assignFX2): return .gentle
        // The right deck: the world and its sky.
        case (.right, .play): return .weatherRandom
        case (.right, .cue): return .timeMode
        case (.right, .sync): return .surprise
        case (.right, .keylock): return .reactionNext
        case (.right, .vinyl): return .setRestore
        case (.right, .loopIn): return .worldPrevious
        case (.right, .loopOut): return .worldNext
        case (.right, .loopPress): return .moodReset
        case (.right, .hotCue1): return .timeMorning
        case (.right, .hotCue2): return .timeMidday
        case (.right, .hotCue3): return .timeEvening
        case (.right, .hotCue4): return .timeNight
        case (.right, .sampler1): return .instrumentPrevious
        case (.right, .sampler2): return .instrumentNext
        case (.right, .sampler3): return .transposeDown
        case (.right, .sampler4): return .transposeUp
        case (.right, .load): return .setNext
        case (.right, .headphoneCue): return .keepTenMinutes
        case (.right, .assignFX1): return .sleepTimer
        case (.right, .assignFX2): return .mute
        // The centre.
        case (.centre, .browsePress): return .surprise
        case (.centre, .function): return .fullScreen
        default: return .none
        }
    }

    /// Out of the box: the right jog wheel scrubs the time of day and the left the moon; the left AUTO LOOP rotary
    /// steps the instrument's presets and the right the weather; the browser steps the worlds.
    public static func defaultTarget(_ wheel: DeckWheel) -> WheelTarget {
        switch (wheel.side, wheel.kind) {
        case (.left, .jog), (.left, .search): return .moonPhase
        case (.right, .jog), (.right, .search): return .timeOfDay
        case (.left, .loop): return .presets
        case (.right, .loop): return .weather
        case (.centre, .browse): return .worlds
        default: return .none
        }
    }

    public var isDefault: Bool {
        DeckKey.all.allSatisfy { self[$0] == Self.defaultAction($0) }
            && DeckWheel.all.allSatisfy { self[$0] == Self.defaultTarget($0) }
    }

    enum CodingKeys: String, CodingKey { case actions, wheels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawActions = (try? c.decodeIfPresent([String: String].self, forKey: .actions)) ?? [:]
        for (key, value) in rawActions {
            guard DeckKey(id: key) != nil, let action = DeckAction(rawValue: value) else { continue }
            actions[key] = action
        }
        let rawWheels = (try? c.decodeIfPresent([String: String].self, forKey: .wheels)) ?? [:]
        for (key, value) in rawWheels {
            guard DeckWheel(id: key) != nil, let target = WheelTarget(rawValue: value) else { continue }
            wheels[key] = target
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actions.mapValues(\.rawValue), forKey: .actions)
        try c.encode(wheels.mapValues(\.rawValue), forKey: .wheels)
    }
}

/// The app's volume from a keyboard's volume knob or slider (MIDI controller 7): 0…127 as 0…1.
public enum KeyboardVolume {
    /// The volume a message asks for, when it is controller 7; nil for everything else.
    public static func volume(in bytes: [UInt8]) -> Double? {
        guard bytes.count == 3, bytes[0] & 0xF0 == 0xB0, bytes[1] == 7 else { return nil }
        return Double(bytes[2] & 0x7F) / 127
    }
}
