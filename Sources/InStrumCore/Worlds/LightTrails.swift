import Foundation
import simd

// Light Trails (Fire & Neon spec §9.2): Set 14's visual. Every note fires a streak of light down a lane of the expressway,
// as a long exposure draws a car's lights: its colour the chord's neon, its length set by how long it is held, its
// brightness by how hard. The arp's notes (Chrome Bass, the left hand) run in the left lanes, the brass in the right.
// A big moment draws an interchange bloom: streaks fanning out across the ramps ahead. The streaks live in a fixed ring of
// 128 that never grows.

/// One streak of light along a lane: from its tail to its head, metres ahead of the car.
public struct LightStreak: Equatable {
    public var id: Int
    public var note: UInt8
    /// The lane it runs in: 0 and 1 (the left lanes: the arp's), 2 and 3 (the right: the brass's).
    public var lane: Int
    /// Across its lane from the lane's centre (m), by pitch class, so a chord's notes run side by side.
    public var offset: Float
    /// How high above the road it runs (m): low notes low, high notes higher (0.12…0.45).
    public var height: Float
    /// Its colour (linear rgb, the neon's at its note-on).
    public var colour: SIMD3<Float>
    /// Metres ahead of the car: where it starts and where its head has raced to.
    public var tail: Float
    public var head: Float
    /// How fast its head races away (m/s, faster for a harder note).
    public var speed: Float
    /// Its light (0.3…1.2, by velocity and the Light trails dial).
    public var brightness: Float
    public var held: Bool
    public var age: Float
    /// 1 while its note sounds; falling to 0 once let go.
    public var fade: Float

    /// Its length now (m).
    public var length: Float { max(0, head - tail) }
    /// Its light now (brightness × fade).
    public var light: Float { brightness * fade }
}

/// The interchange bloom a big moment draws (spec §9.2): streaks fanning out across the ramps where they leave the road.
public struct InterchangeBloom: Equatable {
    public var age: Float
    public var strength: Float
    public var seed: UInt64
    /// Where the ramps leave the road (m ahead): it comes towards you as you drive on.
    public var at: Float
    /// How long it lasts (s), and how many streaks fan out.
    public static let life: Float = 3.5
    public static let fanCount = 10
    /// Its light now (0…1): up in 0.15 s, fading over its life.
    public var light: Float {
        guard age >= 0, age < Self.life else { return 0 }
        let up: Float = min(1, age / 0.15)
        let x: Float = age / Self.life
        return strength * up * (1 - x) * (1 - x)
    }
}

/// Light Trails: the streaks and the interchange bloom.
public struct LightTrails {
    /// The ring holds this many streaks and never grows.
    public static let capacity = 128
    /// A new streak starts this far ahead (m): just past the bonnet, where the road is first seen.
    public static let launchAhead: Float = 9
    /// Beyond this (m) a streak is lost in the city's haze.
    public static let farthest: Float = 420
    /// The interchange's ramps leave the road this far ahead (m) when a bloom fires.
    public static let bloomAhead: Float = 110
    /// While time is held a new streak shows at once, already this long (m) (Small Wins §4).
    public static let bloomLength: Float = 18
    /// After its note is let go a streak fades with this time constant (s), at Light trails 0.5.
    public static let fadeTau: Float = 0.9
    /// The arp's split: notes below it are Chrome Bass's (the left lanes).
    public static let split: UInt8 = 48

    /// The Light trails dial (0…1): how long and bright the streaks are.
    public var trails: Float = 0.6
    public private(set) var bloom: InterchangeBloom?
    /// Seconds left of a big moment's surge, when the streaks race away faster.
    public private(set) var surge: Float = 0

    /// The ring: always `capacity` slots, each live or free.
    private var ring: [LightStreak]
    private var live: [Bool]
    private var nextID = 0

    public init() {
        let blank = LightStreak(id: -1, note: 0, lane: 0, offset: 0, height: 0, colour: SIMD3(0, 0, 0), tail: 0, head: 0,
                                speed: 0, brightness: 0, held: false, age: 0, fade: 0)
        ring = [LightStreak](repeating: blank, count: Self.capacity)
        live = [Bool](repeating: false, count: Self.capacity)
    }

    /// The streaks alive now, oldest first.
    public var streaks: [LightStreak] {
        var out: [LightStreak] = []
        out.reserveCapacity(Self.capacity)
        for i in 0..<Self.capacity where live[i] { out.append(ring[i]) }
        out.sort { $0.id < $1.id }
        return out
    }

    /// How many slots the ring has (tests: always `capacity`, however hard it is played).
    public var ringSize: Int { ring.count }

    // MARK: - Where

    /// The lane a note runs in: the arp's (below the split) in the left two, the brass's in the right two, by register.
    public static func lane(for note: UInt8) -> Int {
        if note < split { return note < split - 12 ? 0 : 1 }
        return note < 72 ? 2 : 3
    }

    /// Across its lane by pitch class (m): a chord's notes run side by side.
    public static func offset(for note: UInt8) -> Float {
        let pc = Float(Int(note) % 12)
        return (pc / 11 - 0.5) * 1.6
    }

    /// How high it runs (m) by its place in its lane's register: low over the road, as a long exposure from above draws
    /// the lights along it (0.12…0.45).
    public static func height(for note: UInt8) -> Float {
        let n = Float(min(108, max(21, note)))
        let low: Float, high: Float
        switch lane(for: note) {
        case 0: low = 21; high = 36
        case 1: low = 36; high = 48
        case 2: low = 48; high = 72
        default: low = 72; high = 108
        }
        let f: Float = min(1, max(0, (n - low) / max(1, high - low)))
        return 0.12 + 0.33 * f
    }

    // MARK: - Notes

    /// A note fires a streak in its colour. `bloomNow` (time held) starts it already `bloomLength` long.
    public mutating func noteOn(_ note: UInt8, velocity: Float, colour: SIMD3<Float>, bloomNow: Bool = false) {
        let v: Float = velocity.isFinite ? min(1, max(0, velocity)) : 0.7
        let dial: Float = trails.isFinite ? min(1, max(0, trails)) : 0.6
        let speed: Float = (20 + 24 * v) * (0.7 + 0.6 * dial)
        let light: Float = (0.3 + 0.7 * v) * (0.6 + 0.6 * dial)
        let head: Float = Self.launchAhead + (bloomNow ? Self.bloomLength : 0)
        let s = LightStreak(id: nextID, note: note, lane: Self.lane(for: note), offset: Self.offset(for: note),
                            height: Self.height(for: note), colour: colour, tail: Self.launchAhead, head: head,
                            speed: speed, brightness: light, held: true, age: 0, fade: 1)
        nextID &+= 1
        // A free slot, else (the ring full) the faintest streak gives its place.
        var slot = -1
        for i in 0..<Self.capacity where !live[i] { slot = i; break }
        if slot < 0 {
            slot = 0
            for i in 0..<Self.capacity where ring[i].light < ring[slot].light { slot = i }
        }
        ring[slot] = s
        live[slot] = true
    }

    public mutating func noteOff(_ note: UInt8) {
        for i in 0..<Self.capacity where live[i] && ring[i].note == note && ring[i].held { ring[i].held = false }
    }

    public mutating func allNotesOff() {
        for i in 0..<Self.capacity where live[i] { ring[i].held = false }
    }

    /// A big moment: the ramps ahead bloom with fanning streaks, and every streak races away faster for a second.
    public mutating func fireBloom(strength: Float, seed: UInt64) {
        let s: Float = strength.isFinite ? min(1, max(0.3, strength)) : 0.6
        bloom = InterchangeBloom(age: 0, strength: s, seed: seed, at: Self.bloomAhead)
        surge = 1
    }

    // MARK: - Step

    /// Advances by `dt` with the car at `metresPerSecond`: heads race away (faster in a surge), tails hold at the launch
    /// while held and chase their heads once let go, and released streaks fade.
    public mutating func step(dt: Double, metresPerSecond: Float) {
        let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        guard fdt > 0 else { return }
        let dial: Float = trails.isFinite ? min(1, max(0, trails)) : 0.6
        let tau: Float = Self.fadeTau * (0.5 + dial)
        let boost: Float = 1 + 0.8 * surge
        surge = max(0, surge - fdt)
        for i in 0..<Self.capacity where live[i] {
            var s = ring[i]
            s.age += fdt
            s.head = min(Self.farthest + 40, s.head + s.speed * boost * fdt)
            if !s.held {
                s.tail += s.speed * 1.4 * boost * fdt
                s.fade *= exp(-fdt / tau)
            }
            ring[i] = s
            if s.tail >= s.head || s.fade < 0.02 || s.tail > Self.farthest { live[i] = false }
        }
        if var b = bloom {
            b.age += fdt
            b.at -= metresPerSecond * fdt
            bloom = b.age >= InterchangeBloom.life || b.at < 8 ? nil : b
        }
    }
}
