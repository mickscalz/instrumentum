import Foundation

/// A DJ controller used as a control surface for the sound and the world (the Pioneer DDJ-ERGO): the knobs and faders of
/// its two effect boxes and its mixer, its jog wheels and rotary selectors, and its buttons. Nothing it sends reaches the
/// instrument as notes or controllers; every message is decoded here into a knob's position, a wheel's turn or a
/// button's press.
public enum DeckSide: String, Codable, CaseIterable, Hashable {
    case left, right
    /// The middle of the mixer: the crossfader, the master and headphone knobs, the browser.
    case centre

    public var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .centre: return "Centre"
        }
    }
}

/// The knobs and faders: a position, 0…1.
public enum DeckKnob: String, Codable, CaseIterable, Hashable {
    /// The effect box: its three numbered knobs and the CONTROL knob.
    case fx1, fx2, fx3, fxControl
    /// The mixer channel.
    case hi, mid, low, filter
    /// The channel's GAIN knob and fader, and the deck's TEMPO slider.
    case gain, fader, tempo
    /// The centre: the crossfader, MASTER VOL, HEADPHONES MIX and VOL, AUX / MIC VOL.
    case crossfader, master, headphonesMix, headphonesVolume, auxVolume

    /// The knobs each deck side has, top to bottom, and the centre's.
    public static let ofASide: [DeckKnob] = [.fx1, .fx2, .fx3, .fxControl, .gain, .hi, .mid, .low, .filter, .fader, .tempo]
    public static let ofTheCentre: [DeckKnob] = [.master, .crossfader, .headphonesMix, .headphonesVolume, .auxVolume]
}

/// One knob: where it is and which it is.
public struct DeckControl: Hashable, Codable, Identifiable {
    public var side: DeckSide
    public var knob: DeckKnob

    public init(_ side: DeckSide, _ knob: DeckKnob) { self.side = side; self.knob = knob }

    /// Stable, e.g. `left.hi` (the key the layout is saved under).
    public var id: String { "\(side.rawValue).\(knob.rawValue)" }

    public init?(id: String) {
        let parts = id.split(separator: ".")
        guard parts.count == 2, let side = DeckSide(rawValue: String(parts[0])),
              let knob = DeckKnob(rawValue: String(parts[1])) else { return nil }
        let control = DeckControl(side, knob)
        guard Self.all.contains(control) else { return nil }
        self = control
    }

    /// The name printed on the controller.
    public var displayName: String {
        let box = side == .left ? "FX1" : "FX2"
        switch knob {
        case .fx1: return "\(box) knob 1"
        case .fx2: return "\(box) knob 2"
        case .fx3: return "\(box) knob 3"
        case .fxControl: return "\(box) CONTROL"
        case .hi: return "HI"
        case .mid: return "MID"
        case .low: return "LOW"
        case .filter: return "FILTER"
        case .gain: return "GAIN"
        case .fader: return "Channel fader"
        case .tempo: return "TEMPO slider"
        case .crossfader: return "Crossfader"
        case .master: return "MASTER VOL"
        case .headphonesMix: return "HEADPHONES MIX"
        case .headphonesVolume: return "HEADPHONES VOL"
        case .auxVolume: return "AUX / MIC VOL"
        }
    }

    public static func of(_ side: DeckSide) -> [DeckControl] {
        (side == .centre ? DeckKnob.ofTheCentre : DeckKnob.ofASide).map { DeckControl(side, $0) }
    }

    public static let all: [DeckControl] = DeckSide.allCases.flatMap { of($0) }
}

/// The buttons. A deck side has the effect box's four (`on`, `one`, `two`, `three`) and the deck's; the centre has the
/// browser's and FUNCTION.
public enum DeckButton: String, Codable, CaseIterable, Hashable {
    case on, one, two, three
    case play, cue, sync, keylock, vinyl
    case loopIn, loopOut, loopPress
    case hotCue1, hotCue2, hotCue3, hotCue4
    case sampler1, sampler2, sampler3, sampler4
    case load, headphoneCue, assignFX1, assignFX2
    case browsePress, function

    public static let ofASide: [DeckButton] = [
        .on, .one, .two, .three, .play, .cue, .sync, .keylock, .vinyl, .loopIn, .loopOut, .loopPress,
        .hotCue1, .hotCue2, .hotCue3, .hotCue4, .sampler1, .sampler2, .sampler3, .sampler4,
        .load, .headphoneCue, .assignFX1, .assignFX2,
    ]
    public static let ofTheCentre: [DeckButton] = [.browsePress, .function]
}

/// One button: where it is and which it is.
public struct DeckKey: Hashable, Codable, Identifiable {
    public var side: DeckSide
    public var button: DeckButton

    public init(_ side: DeckSide, _ button: DeckButton) { self.side = side; self.button = button }

    public var id: String { "\(side.rawValue).\(button.rawValue)" }

    public init?(id: String) {
        let parts = id.split(separator: ".")
        guard parts.count == 2, let side = DeckSide(rawValue: String(parts[0])),
              let button = DeckButton(rawValue: String(parts[1])) else { return nil }
        let key = DeckKey(side, button)
        guard Self.all.contains(key) else { return nil }
        self = key
    }

    /// The name printed on the controller.
    public var displayName: String {
        let box = side == .left ? "FX1" : "FX2"
        let deck = side == .left ? "A" : "B"
        switch button {
        case .on: return "\(box) ON"
        case .one: return "\(box) button 1"
        case .two: return "\(box) button 2"
        case .three: return "\(box) button 3"
        case .play: return "PLAY"
        case .cue: return "CUE"
        case .sync: return "SYNC"
        case .keylock: return "KEYLOCK"
        case .vinyl: return "VINYL"
        case .loopIn: return "IN"
        case .loopOut: return "OUT"
        case .loopPress: return "AUTO LOOP (press)"
        case .hotCue1: return "HOT CUE 1"
        case .hotCue2: return "HOT CUE 2"
        case .hotCue3: return "HOT CUE 3"
        case .hotCue4: return "HOT CUE 4"
        case .sampler1: return "SAMPLER 1"
        case .sampler2: return "SAMPLER 2"
        case .sampler3: return "SAMPLER 3"
        case .sampler4: return "SAMPLER 4"
        case .load: return "LOAD \(deck)"
        case .headphoneCue: return "Headphone CUE \(deck)"
        case .assignFX1: return "Channel \(deck) FX1"
        case .assignFX2: return "Channel \(deck) FX2"
        case .browsePress: return "Browser (press)"
        case .function: return "FUNCTION"
        }
    }

    public static func of(_ side: DeckSide) -> [DeckKey] {
        (side == .centre ? DeckButton.ofTheCentre : DeckButton.ofASide).map { DeckKey(side, $0) }
    }

    public static let all: [DeckKey] = DeckSide.allCases.flatMap { of($0) }
}

/// The things that turn without end: the jog wheels, the AUTO LOOP rotaries, the browser's rotary selector.
public enum DeckWheelKind: String, Codable, CaseIterable, Hashable {
    case jog, loop, browse
}

public struct DeckWheel: Hashable, Codable, Identifiable {
    public var side: DeckSide
    public var kind: DeckWheelKind

    public init(_ side: DeckSide, _ kind: DeckWheelKind) { self.side = side; self.kind = kind }

    public var id: String { "\(side.rawValue).\(kind.rawValue)" }

    public init?(id: String) {
        guard let wheel = Self.all.first(where: { $0.id == id }) else { return nil }
        self = wheel
    }

    public var displayName: String {
        switch kind {
        case .jog: return "\(side.displayName) jog wheel"
        case .loop: return "\(side.displayName) AUTO LOOP (turn)"
        case .browse: return "Browser (turn)"
        }
    }

    public static let all: [DeckWheel] = [
        DeckWheel(.left, .jog), DeckWheel(.right, .jog), DeckWheel(.left, .loop), DeckWheel(.right, .loop),
        DeckWheel(.centre, .browse),
    ]
}

public enum DeckEvent: Equatable {
    /// A knob's or fader's position, 0 (fully left or down) … 1 (fully right or up).
    case knob(DeckControl, Double)
    /// A button going down (releases are not reported).
    case press(DeckSide, DeckButton)
    /// A wheel turned, in units: one click of a rotary, an eighth of a turn of a jog wheel. Clockwise is positive.
    case turn(DeckWheel, Double)
    /// Something the controller sent that isn't mapped (shown in the panel, so it can be reported).
    case unknown(String)
}

/// Decodes the DDJ-ERGO's MIDI (Pioneer's "List of MIDI Messages" for the DDJ-ERGO). Channels are 0-based here: decks
/// A, B, C, D are channels 0…3, effect box A/C is channel 4, effect box B/D is channel 5, the browser and mixer are
/// channel 6. Decks A and C are the left side, B and D the right, so the DECK buttons never change what a control does,
/// and nor does SHIFT. Knobs send 14 bits as two controllers (the fine half is the coarse controller's number + 32), so
/// the decoder remembers both halves.
public struct DDJErgoDecoder {
    /// Whether a MIDI input with this name is the controller.
    public static func isController(sourceName: String) -> Bool {
        sourceName.lowercased().contains("ddj-ergo")
    }

    static let effectLeftChannel: UInt8 = 4
    static let effectRightChannel: UInt8 = 5
    static let mixerChannel: UInt8 = 6
    /// A jog wheel's counts in one full turn, and the units a full turn is worth.
    static let jogCountsPerTurn = 2430.0
    static let jogUnitsPerTurn = 8.0

    private var coarse: [DeckControl: UInt8] = [:]
    private var fine: [DeckControl: UInt8] = [:]
    /// The coarse half of each side's jog count (it arrives before the fine half).
    private var jogCoarse: [DeckSide: UInt8] = [:]

    public init() {}

    /// The side a deck channel (0…3) belongs to.
    static func deckSide(_ channel: UInt8) -> DeckSide? {
        switch channel {
        case 0, 2: return .left
        case 1, 3: return .right
        default: return nil
        }
    }

    public mutating func decode(_ message: MIDIMessage) -> DeckEvent? {
        switch message {
        case let .controlChange(channel, controller, value):
            if let side = Self.deckSide(channel) { return deckController(side, controller, value) }
            if channel == Self.mixerChannel, controller == 64 || controller == 100 {
                return .turn(DeckWheel(.centre, .browse), Self.clicks(value))
            }
            let isFine = controller >= 32
            let number = isFine ? controller - 32 : controller
            guard controller < 64, let control = Self.knob(channel: channel, coarseController: number) else {
                return .unknown("controller \(controller) on channel \(channel + 1)")
            }
            return absolute(control, isFine: isFine, value)
        case let .noteOn(channel, note, _):
            if Self.isIgnoredNote(channel: channel, note: note) { return nil }
            guard let (side, button) = Self.button(channel: channel, note: note) else {
                return .unknown("button \(note) on channel \(channel + 1)")
            }
            return .press(side, button)
        default:
            return nil
        }
    }

    /// A 14-bit knob: either half updates its position.
    private mutating func absolute(_ control: DeckControl, isFine: Bool, _ value: UInt8) -> DeckEvent? {
        if isFine { fine[control] = value } else { coarse[control] = value }
        // The fine half alone, before any coarse half, says nothing about where the knob is.
        guard let high = coarse[control] else { return nil }
        let low = fine[control] ?? 0
        let raw = (Int(high) << 7) | Int(low)
        return .knob(control, Double(raw) / 16383)
    }

    /// A deck's own controllers: the TEMPO slider (0, or 5 with SHIFT), the jog wheel (1, 2, 3, or 6 and 39 with SHIFT;
    /// fine halves 33, 34, 35, 38 and 7) and the AUTO LOOP rotary (19, or 79 with SHIFT).
    private mutating func deckController(_ side: DeckSide, _ controller: UInt8, _ value: UInt8) -> DeckEvent? {
        switch controller {
        case 0, 5: return absolute(DeckControl(side, .tempo), isFine: false, value)
        case 32, 37: return absolute(DeckControl(side, .tempo), isFine: true, value)
        case 1, 2, 3, 6, 39:
            jogCoarse[side] = value
            return nil
        case 33, 34, 35, 38, 7:
            // A difference since the last message: clockwise counts up from 1, counter-clockwise down from 16383.
            let high = jogCoarse[side] ?? (value >= 64 ? 127 : 0)
            let raw = (Int(high) << 7) | Int(value)
            let counts = max(-300, min(300, raw < 8192 ? raw : raw - 16384))
            guard counts != 0 else { return nil }
            return .turn(DeckWheel(side, .jog), Double(counts) / Self.jogCountsPerTurn * Self.jogUnitsPerTurn)
        case 19, 79: return .turn(DeckWheel(side, .loop), Self.clicks(value))
        default: return .unknown("controller \(controller) on deck channel \(side == .left ? "A/C" : "B/D")")
        }
    }

    /// A rotary's clicks since its last message: clockwise 1…30, counter-clockwise 127 (one) … 98.
    static func clicks(_ value: UInt8) -> Double {
        value < 64 ? Double(value) : Double(Int(value) - 128)
    }

    /// The knob a coarse controller number belongs to, on the effect and mixer channels.
    static func knob(channel: UInt8, coarseController n: UInt8) -> DeckControl? {
        switch channel {
        case effectLeftChannel, effectRightChannel:
            // 0, 2, 4, 6 for deck A or B; + 8 for deck C or D; + 16 with SHIFT held.
            let side: DeckSide = channel == effectLeftChannel ? .left : .right
            switch n % 8 {
            case 0: return DeckControl(side, .fxControl)
            case 2: return DeckControl(side, .fx1)
            case 4: return DeckControl(side, .fx2)
            case 6: return DeckControl(side, .fx3)
            default: return nil
            }
        case mixerChannel:
            // Four in a row for decks A, B, C, D.
            func side(_ first: UInt8) -> DeckSide { (n - first) % 2 == 0 ? .left : .right }
            switch n {
            case 0: return DeckControl(.centre, .master)
            case 1: return DeckControl(.centre, .headphonesMix)
            case 2: return DeckControl(.centre, .headphonesVolume)
            case 3...6: return DeckControl(side(3), .gain)
            case 7...10: return DeckControl(side(7), .hi)
            case 11...14: return DeckControl(side(11), .mid)
            case 15...18: return DeckControl(side(15), .low)
            case 19, 23: return DeckControl(.left, .fader)
            case 21, 25: return DeckControl(.right, .fader)
            case 20: return DeckControl(.centre, .auxVolume)
            case 27...30: return DeckControl(side(27), .filter)
            case 31: return DeckControl(.centre, .crossfader)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Notes that mean nothing here: a hand on a jog wheel (54, 55; 103 with SHIFT) and the DECK button (114), which
    /// only changes which deck the controller says it is.
    static func isIgnoredNote(channel: UInt8, note: UInt8) -> Bool {
        guard deckSide(channel) != nil else { return false }
        return note == 54 || note == 55 || note == 103 || note == 114
    }

    /// The button a note belongs to, if any (most have two notes: without and with SHIFT).
    static func button(channel: UInt8, note: UInt8) -> (DeckSide, DeckButton)? {
        if let side = deckSide(channel) {
            switch note {
            case 11, 71: return (side, .play)
            case 12, 72: return (side, .cue)
            case 16, 76: return (side, .loopIn)
            case 17, 77: return (side, .loopOut)
            case 20, 80: return (side, .loopPress)
            case 21, 22: return (side, .vinyl)
            case 26...30: return (side, .keylock)
            case 46, 95: return (side, .hotCue1)
            case 47, 96: return (side, .hotCue2)
            case 48, 97: return (side, .hotCue3)
            case 49, 98: return (side, .hotCue4)
            case 60, 61: return (side, .sampler1)
            case 62, 63: return (side, .sampler2)
            case 64, 65: return (side, .sampler3)
            case 66, 67: return (side, .sampler4)
            case 88, 92: return (side, .sync)
            default: return nil
            }
        }
        switch channel {
        case effectLeftChannel, effectRightChannel:
            let side: DeckSide = channel == effectLeftChannel ? .left : .right
            switch note {
            case 67, 64, 74, 102: return (side, .on)
            case 71, 99, 75, 103: return (side, .one)
            case 72, 100, 76, 104: return (side, .two)
            case 73, 101, 77, 105: return (side, .three)
            default: return nil
            }
        case mixerChannel:
            func side(_ first: UInt8) -> DeckSide { (note - first) % 2 == 0 ? .left : .right }
            switch note {
            case 65, 66: return (.centre, .browsePress)
            case 70...73: return (side(70), .load)
            case 88...91: return (side(88), .load)
            case 76...79: return (side(76), .assignFX1)
            case 80...83: return (side(80), .assignFX2)
            case 84...87: return (side(84), .headphoneCue)
            case 101, 102: return (.centre, .function)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The messages that light (or darken) a button on the controller: the note it sends, on both of the side's decks,
    /// so the light is right whichever deck the DECK button has chosen.
    public static func light(_ side: DeckSide, _ button: DeckButton, on: Bool) -> [[UInt8]] {
        let velocity: UInt8 = on ? 127 : 0
        func deck(_ note: UInt8) -> [[UInt8]] {
            let channels: [UInt8] = side == .left ? [0, 2] : [1, 3]
            return side == .centre ? [] : channels.map { [0x90 | $0, note, velocity] }
        }
        func effect(_ notes: [UInt8]) -> [[UInt8]] {
            guard side != .centre else { return [] }
            let status: UInt8 = 0x90 | (side == .left ? effectLeftChannel : effectRightChannel)
            return notes.map { [status, $0, velocity] }
        }
        /// Decks A and C, or B and D, on the mixer's channel: `first` is deck A's note.
        func mixer(_ first: UInt8) -> [[UInt8]] {
            let offsets: [UInt8] = side == .left ? [0, 2] : [1, 3]
            return side == .centre ? [] : offsets.map { [0x90 | mixerChannel, first + $0, velocity] }
        }
        switch button {
        case .on: return effect([67, 74])
        case .one: return effect([71, 75])
        case .two: return effect([72, 76])
        case .three: return effect([73, 77])
        case .play: return deck(11)
        case .cue: return deck(12)
        case .loopIn: return deck(16)
        case .loopOut: return deck(17)
        case .loopPress: return deck(20)
        case .vinyl: return deck(21)
        case .keylock: return deck(26)
        case .hotCue1: return deck(46)
        case .hotCue2: return deck(47)
        case .hotCue3: return deck(48)
        case .hotCue4: return deck(49)
        case .sampler1: return deck(60)
        case .sampler2: return deck(62)
        case .sampler3: return deck(64)
        case .sampler4: return deck(66)
        case .sync: return deck(88)
        case .load: return mixer(70)
        case .assignFX1: return mixer(76)
        case .assignFX2: return mixer(80)
        case .headphoneCue: return mixer(84)
        case .browsePress: return side == .centre ? [[0x90 | mixerChannel, 65, velocity]] : []
        case .function: return side == .centre ? [[0x90 | mixerChannel, 101, velocity]] : []
        }
    }
}

/// What a knob moves.
public enum ControlTarget: Hashable, Codable, Identifiable {
    case none
    /// An effect or the tone (see `FXParam`).
    case fx(FXParam)
    /// One of the instrument's own dials, counted from 0 in the order its panel shows them.
    case dial(Int)
    /// The app's volume, and the world's ambience volume.
    case volume, ambience
    /// The world and its sky (see `WorldParam`).
    case world(WorldParam)

    public var id: String {
        switch self {
        case .none: return "none"
        case let .fx(p): return "fx.\(p.rawValue)"
        case let .dial(i): return "dial.\(i)"
        case .volume: return "volume"
        case .ambience: return "ambience"
        case let .world(p): return "world.\(p.rawValue)"
        }
    }

    public init?(id: String) {
        if id == "none" { self = .none; return }
        if id == "volume" { self = .volume; return }
        if id == "ambience" { self = .ambience; return }
        if id.hasPrefix("fx."), let p = FXParam(rawValue: String(id.dropFirst(3))) { self = .fx(p); return }
        if id.hasPrefix("world."), let p = WorldParam(rawValue: String(id.dropFirst(6))) { self = .world(p); return }
        if id.hasPrefix("dial."), let i = Int(id.dropFirst(5)), (0..<64).contains(i) { self = .dial(i); return }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = ControlTarget(id: text) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

/// Which knob moves what. Saved with the settings; anything missing or unreadable falls back to the default layout's.
public struct ControlLayout: Codable, Equatable {
    private var targets: [String: ControlTarget]

    public init() { targets = [:] }

    public subscript(control: DeckControl) -> ControlTarget {
        get { targets[control.id] ?? Self.defaultTarget(control) }
        set { targets[control.id] = newValue }
    }

    /// The layout out of the box: **the left side's knobs are the effects and the tone, the right side's are the
    /// instrument's own dials** (its first nine, in its panel's order), **and the faders, sliders and centre knobs are
    /// the world**: its mood on the two channel faders, the two TEMPO sliders and the crossfader, the ambience on the
    /// headphone knobs, the wind on AUX / MIC, and the app's volume on MASTER.
    public static func defaultTarget(_ control: DeckControl) -> ControlTarget {
        switch (control.side, control.knob) {
        case (.left, .gain): return .fx(.echoRepeats)
        case (.right, .gain): return .dial(8)
        case (.left, .fader): return .world(.moodEnergy)
        case (.right, .fader): return .world(.moodSpace)
        case (.left, .tempo): return .world(.moodBrightness)
        case (.right, .tempo): return .world(.moodMotion)
        case (.centre, .crossfader): return .world(.moodWarmth)
        case (.centre, .master): return .volume
        case (.centre, .headphonesVolume): return .ambience
        case (.centre, .headphonesMix): return .world(.closeness)
        case (.centre, .auxVolume): return .world(.wind)
        case (.left, .fx1): return .fx(.echo)
        case (.left, .fx2): return .fx(.reverb)
        case (.left, .fx3): return .fx(.drive)
        case (.left, .fxControl): return .fx(.echoTime)
        case (.left, .hi): return .fx(.eqHigh)
        case (.left, .mid): return .fx(.eqMid)
        case (.left, .low): return .fx(.eqLow)
        case (.left, .filter): return .fx(.filter)
        case (.right, .fx1): return .dial(0)
        case (.right, .fx2): return .dial(1)
        case (.right, .fx3): return .dial(2)
        case (.right, .fxControl): return .dial(3)
        case (.right, .hi): return .dial(4)
        case (.right, .mid): return .dial(5)
        case (.right, .low): return .dial(6)
        case (.right, .filter): return .dial(7)
        default: return .none
        }
    }

    public var isDefault: Bool { DeckControl.all.allSatisfy { self[$0] == Self.defaultTarget($0) } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode([String: String].self)) ?? [:]
        var out: [String: ControlTarget] = [:]
        for (key, value) in raw {
            guard DeckControl(id: key) != nil, let target = ControlTarget(id: value) else { continue }
            out[key] = target
        }
        targets = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(targets.mapValues(\.id))
    }
}
