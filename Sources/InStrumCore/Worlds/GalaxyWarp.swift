import Foundation
import simd

/// A star launched by a note, streaking out from the vanishing point.
public struct Streak: Equatable {
    /// Unit direction on screen (x right, y up).
    public var direction: SIMD2<Float>
    /// 0 at the vanishing point … ~1.6 past the screen edge.
    public var distance: Float
    public var speed: Float
    public var brightness: Float
    /// 0…1 colour wheel.
    public var hue: Float
    /// Seconds since launch (streaks fade out by `GalaxyWarp.maxAge`).
    public var age: Float = 0
}

/// What Galaxy Warp draws this frame.
public struct WarpFrame: Equatable {
    public var streaks: [Streak]
    /// 0.1 drifting … 1 full warp.
    public var warpSpeed: Float
    /// 0…1 nebula glow and its hue (0…1 colour wheel).
    public var nebula: Float
    public var nebulaHue: Float
}

/// Galaxy Warp: notes launch streaking stars (pitch sets the direction, velocity the brightness), playing
/// intensity sets the warp speed, chords bloom a nebula tinted by their quality, silence settles to a drift.
public struct GalaxyWarp {
    public static let cap = 400
    /// Hues for chord qualities: major warm violet, minor deep blue, tense magenta.
    public static let majorHue: Float = 0.78, minorHue: Float = 0.63, tenseHue: Float = 0.9
    public static let maxAge: Float = 7
    /// New streaks admitted per step: a MIDI burst streams out over a few frames instead of filling the window
    /// in one (flash safety); the rest wait in a queue capped at `cap`.
    public static let maxSpawnsPerStep = 40
    /// Warp speed reaches 90% of a rise in 0.6 s and falls 90% in 2.5 s.
    static let riseTau = 0.6 / log(10.0), fallTau = 2.5 / log(10.0)
    /// The speed it aims at while the Mac asks for less motion (Small Wins spec §6): the streaks become a slow drift,
    /// however hard you play.
    public static let driftSpeed: Float = 0.1

    /// The streak direction for a note: a 240° arc from down-left (lowest) over the top to down-right (highest),
    /// like the keyboard read left to right.
    public static func angle(for note: UInt8) -> Float {
        let p = (Float(min(108, max(21, note))) - 21) / 87
        return Float.pi * (7.0 / 6.0 - 4.0 / 3.0 * p)
    }

    public private(set) var streaks: [Streak] = []
    public private(set) var warpSpeed: Float = 0.1
    public private(set) var nebula: Float = 0
    public private(set) var nebulaHue: Float = GalaxyWarp.majorHue

    private var held = Set<UInt8>()
    private var pending: [Streak] = []
    private var rng = SeededRandom(seed: 0x6A1A)

    public init() {}

    public mutating func noteOn(_ note: UInt8, velocity: UInt8, at t: Double) {
        held.insert(note)
        let v = Float(min(127, velocity)) / 127
        let count = 1 + Int(velocity) / 40
        let p = (Float(min(108, max(21, note))) - 21) / 87
        for _ in 0..<count {
            let a = Self.angle(for: note) + rng.range(-0.15, 0.15)
            pending.append(Streak(direction: SIMD2(cos(a), sin(a)), distance: rng.range(0.03, 0.12),
                                  speed: (0.5 + 0.7 * v) * rng.range(0.85, 1.15), brightness: 0.35 + 0.65 * v,
                                  hue: 0.55 + 0.25 * p + rng.range(-0.03, 0.03)))
        }
        if pending.count > Self.cap { pending.removeFirst(pending.count - Self.cap) }
    }

    public mutating func noteOff(_ note: UInt8) { held.remove(note) }

    public mutating func allNotesOff() { held.removeAll() }

    public mutating func step(dt: Double, roles: RoleValues, inputs: InputFrame) -> WarpFrame {
        let d = max(0, dt)
        let drifting = inputs[.reduceMotion] > 0.5
        let target = drifting ? Self.driftSpeed : Float(0.1 + 0.9 * roles[.energy])
        let tau = target > warpSpeed ? Self.riseTau : Self.fallTau
        warpSpeed += (target - warpSpeed) * Float(1 - exp(-d / tau))

        // Chords bloom the nebula, tinted by their quality; it fades when they let go.
        let quality = held.count >= 2 ? PlayingAnalyzer.classify(held) : .none
        let hue: Float?
        switch quality {
        case .major: hue = Self.majorHue
        case .minor: hue = Self.minorHue
        case .tense: hue = Self.tenseHue
        default: hue = nil
        }
        if let hue {
            if nebula < 0.05 { nebulaHue = hue } else { nebulaHue += (hue - nebulaHue) * Float(1 - exp(-d / 0.4)) }
            nebula += (1 - nebula) * Float(1 - exp(-d / 0.35))
        } else {
            nebula *= Float(exp(-d / 2.5))
        }

        // Streaks accelerate outward (perspective) and faster at warp; they leave the screen or fade.
        let fdt = Float(d)
        let push = 0.5 + 1.5 * warpSpeed
        for i in streaks.indices {
            streaks[i].distance += streaks[i].speed * push * (0.3 + streaks[i].distance) * fdt
            streaks[i].age += fdt
        }
        streaks.removeAll { $0.distance > 1.6 || $0.age > Self.maxAge }
        // Launch this frame's share of the queue.
        let launch = min(pending.count, Self.maxSpawnsPerStep)
        if launch > 0 {
            streaks.append(contentsOf: pending.prefix(launch))
            pending.removeFirst(launch)
            if streaks.count > Self.cap { streaks.removeFirst(streaks.count - Self.cap) }
        }
        return WarpFrame(streaks: streaks, warpSpeed: warpSpeed, nebula: nebula, nebulaHue: nebulaHue)
    }
}
