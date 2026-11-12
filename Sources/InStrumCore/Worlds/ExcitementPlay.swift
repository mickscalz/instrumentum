import Foundation
import simd

// Excitement in the interiors, space and Deep Water (Fire & Neon spec §5.5; plan Task 7): the Spaceship Lounge, Snowbound
// Cabin, Bedroom at Dawn, Butterfly Garden, Midnight Steinway, Submarine Window and Great Barrier Reef each read
// Excitement through an `ExcitementPlay`: it takes the moment and the surprise that arrive for one step, keeps the one
// moment and the few surprises playing in a fixed pool, and eases the tension so a drop releases it quickly but never in
// a single frame.

/// A world's signature moment as it plays: seconds since it began, how long it lasts, its strength (0.15…1: Reduce
/// Motion's halving comes from Excitement itself) and whether it landed on built-up tension (a drop: the world plays its
/// release).
public struct PlayingMoment: Equatable {
    public var age: Float
    public var duration: Float
    public var strength: Float
    public var isDrop: Bool
    public init(age: Float, duration: Float, strength: Float, isDrop: Bool) {
        self.age = age; self.duration = duration; self.strength = strength; self.isDrop = isDrop
    }
    /// 0 as it begins … 1 at its end.
    public var progress: Float { duration > 0 ? min(1, max(0, age / duration)) : 1 }
}

/// One of a world's own surprises as it plays: its index in the world's list, seconds since it began, how long it lasts,
/// and its seed (where it crosses, which way it goes).
public struct PlayingSurprise: Equatable {
    public var index: Int
    public var age: Float
    public var duration: Float
    public var seed: UInt64
    public init(index: Int, age: Float, duration: Float, seed: UInt64) {
        self.index = index; self.age = age; self.duration = duration; self.seed = seed
    }
    /// 0 as it begins … 1 at its end.
    public var progress: Float { duration > 0 ? min(1, max(0, age / duration)) : 1 }
    /// A number in 0..<1 from the seed, the `k`th of its own (the same every step).
    public func unit(_ k: Int) -> Float {
        var r = SeededRandom(seed: seed ^ (UInt64(truncatingIfNeeded: k &+ 1) &* 0x9E37_79B9_7F4A_7C15))
        return r.unit()
    }
}

/// What one world keeps of Excitement (spec §5.1–§5.4): the drawn Energy, the tension eased, the drop, the moment playing
/// and the surprises playing (at most `surpriseCap`, never two of a kind). A moment while one plays doesn't stack: it
/// lifts the strength, and a drop arriving turns the moment playing into its release.
public struct ExcitementPlay: Equatable {
    public static let surpriseCap = 3
    /// The tension falls this fast (s, time constant) when a drop snaps it to 0: a quick release, never a jump.
    public static let releaseTau: Float = 0.3

    /// The drawn Energy (Reduce Motion's 0.5 cap included), 0…1.
    public private(set) var energy: Float = 0
    /// The tension as drawn: rising with Excitement's own, falling with τ `releaseTau`, 0…1.
    public private(set) var tension: Float = 0
    /// The release after a drop: 1 falling to 0 over 2.5 s (Excitement's own).
    public private(set) var drop: Float = 0
    public private(set) var reduceMotion = false
    public private(set) var gentle = false
    public private(set) var moment: PlayingMoment?
    public private(set) var surprises: [PlayingSurprise] = []
    /// The moment and the surprise that began on the latest step (nil on every other step).
    public private(set) var momentBegan: PlayingMoment?
    public private(set) var surpriseBegan: PlayingSurprise?

    public init() { surprises.reserveCapacity(Self.surpriseCap) }

    /// A moment's strength as a world plays it: 0.15…1 (Reduce Motion's half of the weakest); a NaN plays as 0.3.
    public static func strength(_ m: BigMoment) -> Float { m.strength.isFinite ? min(1, max(0.15, m.strength)) : 0.3 }

    public static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    public static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        guard x.isFinite, a != b else { return 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// 0 → 1 → 0 over `life` seconds: up over `rise` s, held, then down over `fall` s at its end (smoothsteps).
    public static func envelope(age: Float, life: Float, rise: Float, fall: Float) -> Float {
        guard age.isFinite, age >= 0, age < life else { return 0 }
        let up: Float = rise > 0 ? smooth(0, rise, age) : 1
        let down: Float = fall > 0 ? smooth(0, fall, life - age) : 1
        return min(up, down)
    }

    /// The surprise of index `i` playing now, if it is.
    public func surprise(_ i: Int) -> PlayingSurprise? { surprises.first { $0.index == i } }

    /// Advances by `dt` seconds (the world's dt; 0 while time is held, when nothing moves) with Excitement's frame `e`,
    /// whose moment and surprise are this step's (the world clears them in its own copy once read). `momentSeconds` and
    /// `dropSeconds` are how long the world's moment and its release last; `surpriseSeconds[i]` how long its surprise `i`
    /// lasts (an index outside the list plays nothing).
    public mutating func step(dt: Double, frame e: ExcitementFrame, momentSeconds: Float, dropSeconds: Float,
                              surpriseSeconds: [Float]) {
        let fd: Float = dt.isFinite ? Float(min(max(dt, 0), 0.25)) : 0
        reduceMotion = e.reduceMotion
        gentle = e.gentle
        energy = Self.unit(e.visualEnergy)
        let t = Self.unit(e.tension)
        tension = t >= tension ? t : t + (tension - t) * exp(-fd / Self.releaseTau)
        drop = Self.unit(e.drop)
        momentBegan = nil
        surpriseBegan = nil

        // What plays ages; what has ended goes.
        if var m = moment {
            m.age += fd
            moment = m.age >= m.duration ? nil : m
        }
        for i in surprises.indices { surprises[i].age += fd }
        surprises.removeAll { $0.age >= $0.duration }

        // This step's moment: begun, or lifting the one playing (and a drop turns it into the release).
        if let m = e.moment {
            let s = Self.strength(m)
            if var playing = moment {
                playing.strength = max(playing.strength, s)
                if m.isDrop, !playing.isDrop {
                    playing.isDrop = true
                    playing.duration = max(playing.duration, playing.age + max(1, dropSeconds - momentSeconds))
                }
                moment = playing
            } else {
                let begun = PlayingMoment(age: 0, duration: max(0.1, m.isDrop ? dropSeconds : momentSeconds), strength: s,
                                          isDrop: m.isDrop)
                moment = begun
                momentBegan = begun
            }
        }
        // This step's surprise: one of each kind at once, at most `surpriseCap` (a surprise with no room waits for none).
        if let sp = e.surprise, sp.index >= 0, sp.index < surpriseSeconds.count, surprises.count < Self.surpriseCap,
           !surprises.contains(where: { $0.index == sp.index }) {
            let begun = PlayingSurprise(index: sp.index, age: 0, duration: max(0.1, surpriseSeconds[sp.index]), seed: sp.seed)
            surprises.append(begun)
            surpriseBegan = begun
        }
    }

    /// Forgets the moment and the surprises (a visual switched off, say); Energy and tension stay.
    public mutating func clear() {
        moment = nil
        surprises.removeAll(keepingCapacity: true)
        momentBegan = nil
        surpriseBegan = nil
    }
}
