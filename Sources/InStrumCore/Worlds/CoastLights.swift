import Foundation

/// Where a Coast Light sits on the passing road, by pitch.
public enum Lane: Equatable {
    /// Cat's-eyes on the road edge (below MIDI 48).
    case road
    /// Points along the guardrail (48–71).
    case rail
    /// Lamp heads (72 and up).
    case lamp
}

/// One light streaming past the car window.
public struct CoastLight: Equatable {
    /// A running number (so equal notes stay distinct).
    public var id: Int
    public var note: UInt8
    public var lane: Lane
    /// 0…1 within its lane, by pitch.
    public var height: Float
    /// 0 entering at the right … 1 gone at the left.
    public var x: Float
    public var brightness: Float
    /// Trail length 0…1 (velocity × Light trails).
    public var trail: Float
    /// The note's colour (a soft pitch-class palette).
    public var hue: Float
    public var age: Float
    public var held: Bool
    /// Where the car was (metres) when this light joined the road.
    public var spawnDistance: Double = 0
}

/// Coast Lights: every note lights a passing light (cat's-eyes low, guardrail in the middle, lamp heads high);
/// playing intensity sets the car's speed; chords bloom the sea's glitter path in the chord's colour.
public struct CoastLights {
    public static let cap = 128
    /// New lights admitted per step: a MIDI burst streams out over frames (flash safety).
    public static let maxSpawnsPerStep = 24
    /// The car's cruising speed (0…1 of 30…100 km/h: about 55 km/h).
    public static let cruise: Float = 0.35
    /// Bloom colours: warm for major, cool for minor, violet for tense.
    public static let majorHue: Float = 0.11, minorHue: Float = 0.58, tenseHue: Float = 0.78
    static let riseTau = 0.8, fallTau = 3.0
    /// Metres a lamp light travels with the car before it has surely left the widest window.
    public static let lampTravel = 70.0

    public static func lane(for note: UInt8) -> Lane { note < 48 ? .road : (note < 72 ? .rail : .lamp) }

    /// Height within the lane, 0 (its lowest note) … 1 (its highest).
    static func height(for note: UInt8) -> Float {
        let n = Float(min(108, max(21, note)))
        switch lane(for: note) {
        case .road: return (n - 21) / 26
        case .rail: return (n - 48) / 23
        case .lamp: return (n - 72) / 36
        }
    }

    /// A soft pitch-class palette: round the circle of fifths, so neighbouring keys of a key sit close in colour.
    public static func hue(for note: UInt8) -> Float { Float((Int(note) % 12) * 7 % 12) / 12 }

    /// Parallax: the road edge passes fastest, the lamps a little slower.
    static func laneSpeed(_ lane: Lane) -> Float {
        switch lane { case .road: return 1.0; case .rail: return 0.85; case .lamp: return 0.7 }
    }

    public private(set) var lights: [CoastLight] = []
    public private(set) var speed: Float = CoastLights.cruise
    /// Metres travelled (speed 0…1 maps to 30…100 km/h).
    public private(set) var distance: Double = 0
    public private(set) var bloom: Float = 0
    public private(set) var bloomHue: Float = CoastLights.majorHue

    /// Settings (0…1) and the mood's scales, set by the world each frame.
    public var trails: Float = 0.6
    public var speedResponse: Float = 0.6
    public var bloomAmount: Float = 0.6
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1
    /// Excitement's Energy (Fire & Neon spec §5.5), 0…1: it pushes the car as playing does, so a hard, fast passage keeps
    /// it going between the notes.
    public var push: Float = 0

    private var held = Set<UInt8>()
    private var pending: [CoastLight] = []
    private var nextID = 0
    private var rng = SeededRandom(seed: 0xC0A57)

    public init() {}

    public mutating func noteOn(_ note: UInt8, velocity: UInt8, at t: Double) {
        held.insert(note)
        guard (21...108).contains(note) else { return }
        let v = Float(min(127, velocity)) / 127
        pending.append(CoastLight(id: nextID, note: note, lane: Self.lane(for: note), height: Self.height(for: note),
                                  x: rng.range(0, 0.05), brightness: min(1.5, (0.3 + 0.7 * v) * reactionScale),
                                  trail: (0.25 + 0.75 * v) * trails, hue: Self.hue(for: note), age: 0, held: true))
        nextID &+= 1
        if pending.count > Self.cap { pending.removeFirst(pending.count - Self.cap) }
    }

    public mutating func noteOff(_ note: UInt8) {
        held.remove(note)
        for i in lights.indices where lights[i].note == note { lights[i].held = false }
        for i in pending.indices where pending[i].note == note { pending[i].held = false }
    }

    public mutating func allNotesOff() {
        held.removeAll()
        for i in lights.indices { lights[i].held = false }
        for i in pending.indices { pending[i].held = false }
    }

    /// The `limit` lights worth drawing when the budget is smaller than the cap: the brightest stay, in order.
    public static func visible(_ lights: [CoastLight], limit: Int) -> [CoastLight] {
        guard lights.count > limit else { return lights }
        let keep = Set(lights.indices.sorted { lights[$0].brightness > lights[$1].brightness }.prefix(max(0, limit)))
        return lights.indices.filter { keep.contains($0) }.map { lights[$0] }
    }

    public mutating func step(dt: Double, roles: RoleValues) {
        let d = max(0, dt), fdt = Float(d)
        // Speed: playing pushes the car toward 1 (τ 0.8 s); silence eases it back to cruise (τ 3 s).
        let played = Float(min(1, 0.6 * roles[.energy] + 0.4 * roles[.density]))
        let drive = max(played, push.isFinite ? min(1, max(0, push)) : 0)
        let target = min(1, Self.cruise + 0.65 * speedResponse * drive)
        let tau = target > speed ? Self.riseTau : Self.fallTau
        speed = min(1, speed + (target - speed) * Float(1 - exp(-d / tau)))
        distance += (30 + 70 * Double(speed)) / 3.6 * d

        // Chords bloom the glitter path in their colour, and fade when they let go.
        let quality = held.count >= 3 ? PlayingAnalyzer.classify(held) : .none
        let hue: Float?
        switch quality {
        case .major: hue = Self.majorHue
        case .minor: hue = Self.minorHue
        case .tense: hue = Self.tenseHue
        default: hue = nil
        }
        if let hue {
            bloomHue = hue   // the renderer glides the colour (in RGB, so it never passes through other hues)
            let top = min(1, bloomAmount * reactionScale)
            bloom += (top - bloom) * Float(1 - exp(-d / 0.35))
        } else {
            bloom *= Float(exp(-d / 2.5))
        }

        // Lights stream right to left with the car; released ones fade over about 1.5 s. Lamp lights pass with the
        // lamps themselves (x is the share of `lampTravel` the car has gone since they joined the road).
        let fade = Float(1.5) * lingerScale
        for i in lights.indices {
            if lights[i].lane == .lamp {
                lights[i].x = Float((distance - lights[i].spawnDistance) / Self.lampTravel)
            } else {
                lights[i].x += speed * 1.1 * Self.laneSpeed(lights[i].lane) * fdt
            }
            lights[i].age += fdt
            if !lights[i].held { lights[i].brightness *= exp(-fdt / max(0.3, fade)) }
        }
        lights.removeAll { ($0.lane == .lamp ? $0.x >= 1 : $0.x > 1.05) || $0.brightness < 0.01 }
        // Admit this step's share of the queue; over the cap, the faintest go.
        let launch = min(pending.count, Self.maxSpawnsPerStep)
        if launch > 0 {
            for var l in pending.prefix(launch) {
                l.spawnDistance = distance
                if l.lane == .lamp { l.x = 0 }
                lights.append(l)
            }
            pending.removeFirst(launch)
            while lights.count > Self.cap {
                var worst = 0
                for i in lights.indices where lights[i].brightness < lights[worst].brightness { worst = i }
                lights.remove(at: worst)
            }
        }
    }
}
