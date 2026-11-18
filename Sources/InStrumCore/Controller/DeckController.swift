import Foundation

/// A DJ controller used as a bank of knobs for the sound (the Pioneer DDJ-ERGO): its two effect boxes (FX1 on the left,
/// FX2 on the right), and the HI / MID / LOW and FILTER knobs of the two mixer channels. Nothing it sends reaches the
/// instrument as notes or controllers; every message is decoded here into a knob turn or a button press.
public enum DeckSide: String, Codable, CaseIterable, Hashable {
    case left, right

    public var displayName: String { self == .left ? "Left" : "Right" }
}

/// The knobs of one side, top to bottom as they sit on the controller.
public enum DeckKnob: String, Codable, CaseIterable, Hashable {
    /// The effect box: its three numbered knobs and the CONTROL knob.
    case fx1, fx2, fx3, fxControl
    /// The mixer channel.
    case hi, mid, low, filter
}

/// One knob: a side and which knob on it.
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
        self.side = side; self.knob = knob
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
        }
    }

    public static let all: [DeckControl] = DeckSide.allCases.flatMap { side in DeckKnob.allCases.map { DeckControl(side, $0) } }
}

/// The buttons of an effect box: ON, and the three under the numbered knobs.
public enum DeckButton: String, Codable, CaseIterable, Hashable {
    case on, one, two, three
}

public enum DeckEvent: Equatable {
    /// A knob's position, 0 (fully left) … 1 (fully right).
    case knob(DeckControl, Double)
    /// A button going down (releases are not reported).
    case press(DeckSide, DeckButton)
}

/// Decodes the DDJ-ERGO's MIDI (Pioneer's "List of MIDI Messages" for the DDJ-ERGO). Channels are 0-based here:
/// effect box A/C is channel 4, effect box B/D is channel 5, the mixer is channel 6. Decks A and C are the left side,
/// B and D the right, so the DECK buttons never change what a knob does, and nor does SHIFT. Knobs send 14 bits as two
/// controllers (the fine half is the coarse controller's number + 32), so the decoder remembers both halves.
public struct DDJErgoDecoder {
    /// Whether a MIDI input with this name is the controller.
    public static func isController(sourceName: String) -> Bool {
        sourceName.lowercased().contains("ddj-ergo")
    }

    static let effectLeftChannel: UInt8 = 4
    static let effectRightChannel: UInt8 = 5
    static let mixerChannel: UInt8 = 6

    private var coarse: [DeckControl: UInt8] = [:]
    private var fine: [DeckControl: UInt8] = [:]

    public init() {}

    public mutating func decode(_ message: MIDIMessage) -> DeckEvent? {
        switch message {
        case let .controlChange(channel, controller, value):
            let isFine = controller >= 32
            let number = isFine ? controller - 32 : controller
            guard controller < 64, let control = Self.knob(channel: channel, coarseController: number) else { return nil }
            if isFine { fine[control] = value } else { coarse[control] = value }
            // The fine half alone, before any coarse half, says nothing about where the knob is.
            guard let high = coarse[control] else { return nil }
            let low = fine[control] ?? 0
            let raw = (Int(high) << 7) | Int(low)
            return .knob(control, Double(raw) / 16383)
        case let .noteOn(channel, note, _):
            guard let (side, button) = Self.button(channel: channel, note: note) else { return nil }
            return .press(side, button)
        default:
            return nil
        }
    }

    /// The knob a coarse controller number belongs to, if any.
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
            case 7...10: return DeckControl(side(7), .hi)
            case 11...14: return DeckControl(side(11), .mid)
            case 15...18: return DeckControl(side(15), .low)
            case 27...30: return DeckControl(side(27), .filter)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The effect-box button a note belongs to, if any (each has four notes: deck A/B or C/D, with and without SHIFT).
    static func button(channel: UInt8, note: UInt8) -> (DeckSide, DeckButton)? {
        guard channel == effectLeftChannel || channel == effectRightChannel else { return nil }
        let side: DeckSide = channel == effectLeftChannel ? .left : .right
        switch note {
        case 67, 64, 74, 102: return (side, .on)
        case 71, 99, 75, 103: return (side, .one)
        case 72, 100, 76, 104: return (side, .two)
        case 73, 101, 77, 105: return (side, .three)
        default: return nil
        }
    }

    /// The messages that light (or darken) a button on the controller: the same notes it sends, for both of the side's
    /// decks, so the light is right whichever deck the DECK button has chosen.
    public static func light(_ side: DeckSide, _ button: DeckButton, on: Bool) -> [[UInt8]] {
        let status: UInt8 = 0x90 | (side == .left ? effectLeftChannel : effectRightChannel)
        let notes: [UInt8]
        switch button {
        case .on: notes = [67, 74]
        case .one: notes = [71, 75]
        case .two: notes = [72, 76]
        case .three: notes = [73, 77]
        }
        return notes.map { [status, $0, on ? 127 : 0] }
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

    public var id: String {
        switch self {
        case .none: return "none"
        case let .fx(p): return "fx.\(p.rawValue)"
        case let .dial(i): return "dial.\(i)"
        case .volume: return "volume"
        case .ambience: return "ambience"
        }
    }

    public init?(id: String) {
        if id == "none" { self = .none; return }
        if id == "volume" { self = .volume; return }
        if id == "ambience" { self = .ambience; return }
        if id.hasPrefix("fx."), let p = FXParam(rawValue: String(id.dropFirst(3))) { self = .fx(p); return }
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

    /// The layout out of the box: **the left side is the effects and the tone, the right side is the instrument's own
    /// dials** (its first eight, in its panel's order).
    public static func defaultTarget(_ control: DeckControl) -> ControlTarget {
        switch (control.side, control.knob) {
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
