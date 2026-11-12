import Foundation
import simd

// Magma Veins (Fire & Neon spec §8.2): Volcano Rim's second visual, a full-frame view straight down into the lava lake.
// The crust is a field of plates; each note opens a vein of magma that branches up from its key's place along the foot
// of the view and cools from yellow through red to black; a chord's notes join their veins with a crack between them;
// a big moment splits the plates apart to show the bright magma beneath. Everything here is control-rate Core state in
// fixed pools (96 veins, 24 plates); the renderer draws the veins as distance-field strokes.

/// One vein of magma opened by a note.
public struct MagmaVein: Equatable {
    public var alive: Bool
    public var note: UInt8
    /// Where it opens: its key's place across the view (0 left … 1 right), at the view's foot.
    public var origin: Float
    public var seed: UInt64
    /// Seconds since its note.
    public var age: Float
    /// The note's velocity (0…1): how far it reaches and how hot it opens.
    public var strength: Float
    /// Its skin's temperature now (kelvin): 1450 K as it opens, held near 1250 K while its key is down, cooling to black
    /// crust once it is let go.
    public var temperature: Float
    /// The vein of the chord's previous note it is joined to (an index into the pool), nil for none.
    public var link: Int?
    public var held: Bool

    public static let growSeconds: Float = 0.45
    public static let openTemperature: Float = 1450
    public static let crust: Float = 680
    public static let dead = MagmaVein(alive: false, note: 0, origin: 0, seed: 0, age: 0, strength: 0, temperature: 0,
                                       link: nil, held: false)

    /// How far it has grown, 0…1 (fast, then easing).
    public var reach: Float {
        let x = min(1, max(0, age / Self.growSeconds))
        return 1 - (1 - x) * (1 - x)
    }

    /// How tall it reaches up the view (a share of its height), with the note's strength.
    public var length: Float { 0.22 + 0.5 * min(1, max(0, strength)) }

    /// Its main channel: 9 points from its origin up the view, wandering (x across in view heights from the origin, y up
    /// in view heights). Seeded, so it keeps its shape.
    public func path() -> [SIMD2<Float>] {
        var rng = SeededRandom(seed: seed)
        var points: [SIMD2<Float>] = [SIMD2(0, 0)]
        var heading = rng.range(-0.5, 0.5)
        var p = SIMD2<Float>(0, 0)
        let step = length / 8
        for _ in 0..<8 {
            heading += rng.range(-0.55, 0.55)
            heading *= 0.8
            p += SIMD2(sin(heading), cos(heading)) * step
            points.append(p)
        }
        return points
    }

    /// Its distributaries: two or three channels forking off the upper half of the main channel and fanning out from it
    /// (a delta), 4 points each.
    public func branches() -> [[SIMD2<Float>]] {
        let main = path()
        var rng = SeededRandom(seed: seed ^ 0xB4A2_C4E5)
        let count = 2 + Int(seed % 2)
        var out: [[SIMD2<Float>]] = []
        for k in 0..<count {
            let at = 4 + (k + Int(seed % 3)) % 4
            var p = main[at]
            let along = main[min(at + 1, main.count - 1)] - main[at]
            var heading = atan2(along.x, along.y) + (k % 2 == 0 ? -1 : 1) * rng.range(0.35, 0.7)
            var line: [SIMD2<Float>] = [p]
            let step = length / 10
            for _ in 0..<3 {
                heading += rng.range(-0.3, 0.3)
                p += SIMD2(sin(heading), cos(heading)) * step
                line.append(p)
            }
            out.append(line)
        }
        return out
    }
}

/// What the Magma Veins renderer draws for a frame.
public struct VeinsFrame: Equatable {
    /// The pool, always 96 long (dead slots have `alive` false).
    public var veins: [MagmaVein]
    /// The crust's plates: their seeds (view units: x 0…1 across, y 0…1 up), drifting slowly.
    public var plates: [SIMD2<Float>]
    /// How far a moment has split the plates apart (0…1).
    public var split: Float
    public var energy: Float
    public var drop: Float
    public var time: Double
}

/// The Magma Veins visual's state (spec §8.2). Notes reach it through `noteOn`, time through `step`.
public struct MagmaVeins {
    public static let capacity = 96
    public static let plateCount = 24
    /// Notes this close together are a chord: their veins are joined.
    static let chordWindow = 0.06

    public private(set) var veins = [MagmaVein](repeating: .dead, count: MagmaVeins.capacity)
    public private(set) var plates: [SIMD2<Float>] = []
    public private(set) var split: Float = 0
    private var drift: [SIMD2<Float>] = []
    private var next = 0
    private var rng = SeededRandom(seed: 0x3A_6A_7E1C)
    private var lastOn = -Double.infinity
    private var lastIndex: Int?
    private var time = 0.0

    public init() {
        var r = SeededRandom(seed: 0x9_1A7E5)
        let cols = 6, rows = 4
        for j in 0..<rows {
            for i in 0..<cols {
                let x = (Float(i) + r.range(0.15, 0.85)) / Float(cols)
                let y = (Float(j) + r.range(0.15, 0.85)) / Float(rows)
                plates.append(SIMD2(x, y))
                let a = r.range(0, 2 * Float.pi)
                drift.append(SIMD2(cos(a), sin(a)) * r.range(0.002, 0.006))
            }
        }
    }

    /// The veins alive now.
    public var aliveCount: Int { veins.reduce(0) { $0 + ($1.alive ? 1 : 0) } }

    /// A note opens a vein from its key's place (it takes the oldest slot when all 96 are in use).
    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let key = KeyboardLayout.key(for: note)
        let raw: Float = key.map { $0.x + 0.5 * $0.width } ?? (note < KeyboardLayout.lowestNote ? 0 : 1)
        let v = min(1, max(0, velocity.isFinite ? velocity : 0))
        var slot = next
        // Prefer a dead slot; else the oldest (the ring's next).
        for k in 0..<Self.capacity {
            let i = (next + k) % Self.capacity
            if !veins[i].alive { slot = i; break }
        }
        let link: Int? = t - lastOn <= Self.chordWindow ? lastIndex : nil
        veins[slot] = MagmaVein(alive: true, note: note, origin: min(1, max(0, raw)), seed: rng.next(), age: 0, strength: v,
                                temperature: MagmaVein.openTemperature - 120 * (1 - v), link: link, held: true)
        // A vein that pointed at this slot points at nothing now.
        for i in veins.indices where i != slot && veins[i].link == slot { veins[i].link = nil }
        next = (slot + 1) % Self.capacity
        lastOn = t
        lastIndex = slot
    }

    public mutating func noteOff(_ note: UInt8) {
        for i in veins.indices where veins[i].alive && veins[i].note == note { veins[i].held = false }
    }

    public mutating func allNotesOff() {
        for i in veins.indices { veins[i].held = false }
    }

    /// A big moment splits the plates apart (the drop all the way).
    public mutating func moment(strength: Float, drop: Bool) {
        let s = min(1, max(0.3, strength.isFinite ? strength : 0.3))
        split = max(split, drop ? 1 : s)
    }

    /// Advances by `dt` (the scene's visual time). While time is held (dt 0) a vein opened since the last step shows at
    /// once, fully grown.
    public mutating func step(dt: Double, energy: Float, reaction: Float) {
        let fd = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        time += Double(fd)
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        for i in veins.indices where veins[i].alive {
            var v = veins[i]
            if fd == 0 {
                if v.age == 0 { v.age = MagmaVein.growSeconds }
                veins[i] = v
                continue
            }
            v.age += fd
            if v.held {
                v.temperature += (1250 - v.temperature) * (1 - exp(-fd / 2.5))
            } else {
                v.temperature += (600 - v.temperature) * (1 - exp(-fd / (2.2 + 1.5 * min(1, reaction))))
            }
            if !v.held, v.temperature < MagmaVein.crust {
                v.alive = false
                v.link = nil
            }
            veins[i] = v
        }
        for i in veins.indices where !veins[i].alive { veins[i].link = nil }
        for i in veins.indices {
            if let l = veins[i].link, !veins[l].alive { veins[i].link = nil }
        }
        // The plates drift (faster with Energy) and the split closes again.
        for i in plates.indices {
            plates[i] += drift[i] * fd * (1 + 2 * e)
            if plates[i].x < -0.1 || plates[i].x > 1.1 { drift[i].x = -drift[i].x }
            if plates[i].y < -0.1 || plates[i].y > 1.1 { drift[i].y = -drift[i].y }
        }
        split *= exp(-fd / 3.5)
        if split < 1e-3 { split = 0 }
    }

    public func frame(energy: Float, drop: Float, time t: Double) -> VeinsFrame {
        VeinsFrame(veins: veins, plates: plates, split: max(split, 0.6 * drop), energy: energy, drop: drop, time: t)
    }
}
