import Foundation
import simd

/// Curtain Light (spec §9.3): holding notes raises the room's morning glow; every note sends a puff of air into the
/// sheer curtains at its key's place; high notes make dust motes glint at a height set by pitch; chords tint the
/// light (gold, rose or lilac), gliding in RGB; at night notes twinkle the fairy lights on the rod.
public struct CurtainLight {
    public static let riseTau = 2.5, fallTau = 6.0
    public static let glowCap: Float = 1
    public static let maxEventsPerStep = 12
    public static let fairyCount = 12
    public static let majorTint = SIMD3<Float>(1.0, 0.82, 0.55)
    public static let minorTint = SIMD3<Float>(1.0, 0.70, 0.76)
    public static let tenseTint = SIMD3<Float>(0.82, 0.72, 1.0)
    public static let neutralTint = SIMD3<Float>(1.0, 0.92, 0.84)
    /// Chords: three or more notes within 60 ms. A puff crosses the window (and is forgotten) in 0.8 s.
    static let chordWindow = 0.06, puffLife: Float = 0.8, glintTau: Float = 0.8, twinkleTau: Float = 0.6

    /// A dust mote in the room: x across the window (0…1), y up (0 floor … 1 the top of the window), z into the room.
    public struct Mote: Equatable {
        public var position: SIMD3<Float>
        public var glint: Float
    }

    /// How many motes each quality draws (Smooth draws half): glints go only to motes that are drawn.
    public static func moteBudget(_ q: QualityLevel) -> Int { q == .lite ? 200 : 400 }
    /// Glints pick among the first `glintLimit` motes (the ones on screen).
    public var glintLimit = Int.max

    /// The mood's scales.
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1
    /// How stirred the room's air is (Excitement's Energy, 0…1): the motes drift up to three times as fast.
    public var stir: Float = 0

    public private(set) var glow: Float = 0
    public private(set) var tint = CurtainLight.neutralTint
    public private(set) var puffs: [Cloth.Puff] = []
    public private(set) var motes: [Mote]
    public private(set) var fairy: [Float]
    /// Events (puffs, glints, twinkles) started by the last step (tests).
    private(set) var lastEvents = 0

    var nextID = 0
    private var held = Set<UInt8>()
    private var sustained = Set<UInt8>()
    private var pedal = false
    private var queue: [(note: UInt8, velocity: Float)] = []
    private var recent: [Double] = []
    private var lastChord = -Double.infinity
    /// The chord whose tint is showing (cleared when it lets go).
    private var chordNotes = Set<UInt8>()
    private var target = CurtainLight.neutralTint
    private var rng: SeededRandom
    private var time: Float = 0

    public init(moteCount: Int) {
        var r = SeededRandom(seed: 0xC0A7_1167)
        motes = (0..<max(0, min(moteCount, 1000))).map { _ in
            Mote(position: SIMD3(r.range(0.02, 0.98), r.range(0.05, 1.0), r.range(0.05, 0.6)), glint: 0)
        }
        fairy = [Float](repeating: 0, count: Self.fairyCount)
        rng = r
    }

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place across the window (its key's centre, 0…1).
    public static func x(for note: UInt8) -> Float { centres[Int(min(108, max(21, note))) - 21] }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v))
        if queue.count > 48 { queue.removeFirst(queue.count - 48) }
        guard t.isFinite else { return }
        recent.append(t)
        while let first = recent.first, t - first > Self.chordWindow { recent.removeFirst() }
        if recent.count >= 3, t - lastChord > Self.chordWindow {
            lastChord = t
            let sounding = held.union(sustained)
            switch PlayingAnalyzer.classify(sounding) {
            case .major: target = Self.majorTint; chordNotes = sounding
            case .minor: target = Self.minorTint; chordNotes = sounding
            case .tense: target = Self.tenseTint; chordNotes = sounding
            default: break
            }
        }
    }

    public mutating func noteOff(_ note: UInt8) {
        guard held.remove(note) != nil else { return }
        if pedal { sustained.insert(note) }
    }

    public mutating func setPedal(_ down: Bool) {
        pedal = down
        if !down { sustained.removeAll() }
    }

    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
    }

    // MARK: - Step

    public mutating func step(dt: Double, sunAltitude: Double, roles: RoleValues) {
        let step = dt.isFinite ? Float(min(max(dt, 0), 0.25)) : 0
        time += step
        let night = sunAltitude.isFinite && sunAltitude < -4
        let reaction = reactionScale.isFinite ? min(max(reactionScale, 0.2), 2) : 1
        let linger = lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1
        let sounding = held.union(sustained)

        // New events, at most 12 per step: a puff for each note, glints for high notes, twinkles at night.
        lastEvents = 0
        let batch = queue.prefix(Self.maxEventsPerStep)
        for (note, v) in batch {
            nextID = nextID &+ 1
            let x = Self.x(for: note)
            puffs.append(Cloth.Puff(x: x, strength: (0.3 + 0.7 * v) * min(1, reaction), age: 0))
            if note >= 72 { glint(height: Float(Int(note) - 72) / 36) }
            if night {
                let i = min(Self.fairyCount - 1, max(0, Int(x * Float(Self.fairyCount))))
                fairy[i] = 1
            }
            lastEvents += 1
        }
        queue.removeFirst(batch.count)

        // The glow rises while notes sound and settles when they stop (capped).
        let wanted: Float = sounding.isEmpty ? 0 : min(Self.glowCap, (0.45 + 0.2 * Float(sounding.count)) * min(1, reaction))
        let tau = Float(wanted > glow ? Self.riseTau : Self.fallTau * Double(linger))
        glow += (wanted - glow) * (1 - exp(-step / tau))
        glow = min(max(glow, 0), Self.glowCap)

        // The chord tint glides straight toward its target in RGB; when the chord lets go it heads back to neutral.
        if !chordNotes.isEmpty, chordNotes.isDisjoint(with: sounding) {
            chordNotes.removeAll()
            target = Self.neutralTint
        }
        tint += (target - tint) * (1 - exp(-step / 1.0))

        // Puffs age and cross; glints and twinkles fade; motes drift on slow air.
        for i in puffs.indices { puffs[i].age += step }
        puffs.removeAll { $0.age > Self.puffLife }
        let fade = exp(-step / Self.glintTau), twinkle = exp(-step / Self.twinkleTau)
        for i in fairy.indices { fairy[i] = night ? fairy[i] * twinkle : 0 }
        let airy: Float = step * (1 + 2 * (stir.isFinite ? min(max(stir, 0), 1) : 0))
        for i in motes.indices {
            var m = motes[i]
            m.glint *= fade
            if m.glint < 0.002 { m.glint = 0 }
            let phase = Float(i) * 0.37
            m.position.x += 0.004 * sin(time * 0.31 + phase) * airy
            m.position.y += (0.006 * sin(time * 0.23 + phase * 1.7) - 0.0015) * airy
            m.position.z += 0.003 * cos(time * 0.27 + phase * 0.6) * airy
            if m.position.y < 0.03 { m.position.y = 1.0 }
            if m.position.x < 0 { m.position.x += 1 } else if m.position.x > 1 { m.position.x -= 1 }
            m.position.z = min(max(m.position.z, 0.03), 0.65)
            motes[i] = m
        }
    }

    /// 3–6 of the motes nearest a height (0…1) glint.
    private mutating func glint(height h: Float) {
        guard !motes.isEmpty else { return }
        let count = 3 + Int(rng.unit() * 3.999)
        let drawn = motes.indices.prefix(max(1, min(glintLimit, motes.count)))
        let order = drawn.sorted { abs(motes[$0].position.y - h) < abs(motes[$1].position.y - h) }
        // Pick among the nearest dozen so repeated notes catch different motes.
        var pool = Array(order.prefix(12))
        for _ in 0..<min(count, pool.count) {
            let k = min(pool.count - 1, Int(rng.unit() * Float(pool.count)))
            motes[pool[k]].glint = 1
            pool.remove(at: k)
        }
    }
}
