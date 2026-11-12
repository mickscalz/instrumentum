import Foundation
import simd

/// One step of Excitement as a world reads it (Fire & Neon spec §5): the drawn Energy (Reduce Motion's cap included),
/// tension and the drop clamped to 0…1 (a NaN reads as 0), and the moment and the surprise, which arrive for exactly one
/// step, taken out of the held frame so they play once however often the world is stepped.
public struct ExcitementStep: Equatable {
    public var energy: Float
    public var tension: Float
    public var drop: Float
    public var moment: BigMoment?
    public var surprise: WorldSurprise?
    public var reduceMotion: Bool
    public var gentle: Bool

    public init(energy: Float = 0, tension: Float = 0, drop: Float = 0, moment: BigMoment? = nil, surprise: WorldSurprise? = nil,
                reduceMotion: Bool = false, gentle: Bool = false) {
        self.energy = energy
        self.tension = tension
        self.drop = drop
        self.moment = moment
        self.surprise = surprise
        self.reduceMotion = reduceMotion
        self.gentle = gentle
    }

    /// Reads `e` and clears its one-step events.
    public static func take(_ e: inout ExcitementFrame) -> ExcitementStep {
        let step = ExcitementStep(energy: unit(e.visualEnergy), tension: unit(e.tension), drop: unit(e.drop), moment: e.moment,
                                  surprise: e.surprise, reduceMotion: e.reduceMotion, gentle: e.gentle)
        e.moment = nil
        e.surprise = nil
        return step
    }

    /// A moment's strength as a world plays it: 0.15…1 (Reduce Motion's half of the weakest moment included); a NaN
    /// plays as the weakest Some moment (0.3).
    public static func strength(_ m: BigMoment) -> Float { m.strength.isFinite ? min(1, max(0.15, m.strength)) : 0.3 }

    public static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// `value` eased toward `target` over `dt` seconds with time constant `tau` (s).
    public static func ease(_ value: Float, to target: Float, tau: Float, dt: Float) -> Float {
        guard dt > 0, tau > 0 else { return dt > 0 ? target : value }
        return value + (target - value) * (1 - exp(-dt / tau))
    }

    /// 0 → 1 → 0 over a life: up over `rise` s, held, then down over `fall` s at its end (smoothsteps).
    public static func envelope(age: Float, life: Float, rise: Float, fall: Float) -> Float {
        guard age.isFinite, age >= 0, age < life else { return 0 }
        func s(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        let up = rise > 0 ? s(age / rise) : 1
        let down = fall > 0 ? s((life - age) / fall) : 1
        return min(up, down)
    }
}

/// A world's own shooting stars (Fire & Neon spec §5.5): the lake's meteor burst and fireball, the coast road's shooting
/// star, the fjord's fireball. The shared sky draws them in its six meteor slots, ahead of the calendar's, so a world's
/// call wins a slot; they are born on the sky's own meteor clock (`SkyState.meteorTime`), so held time holds them. A
/// fixed pool of `capacity` slots.
public struct WorldMeteors: Equatable {
    public static let capacity = 12

    /// The pool (fixed length; nil is a free slot).
    public private(set) var slots = [Meteor?](repeating: nil, count: WorldMeteors.capacity)

    public init() {}

    /// Puts a meteor in a free slot, or over the one that ends soonest.
    public mutating func add(_ m: Meteor) {
        if let free = slots.firstIndex(where: { $0 == nil }) {
            slots[free] = m
            return
        }
        var soonest = 0
        for i in slots.indices where (slots[i]?.ends ?? 0) < (slots[soonest]?.ends ?? 0) { soonest = i }
        slots[soonest] = m
    }

    /// Frees the slots whose meteors have gone by `t` (seconds on the sky's meteor clock).
    public mutating func prune(at t: Double) {
        for i in slots.indices {
            if let m = slots[i], m.ends <= t { slots[i] = nil }
        }
    }

    public mutating func removeAll() {
        for i in slots.indices { slots[i] = nil }
    }

    /// The meteors showing at `t` (born and not yet gone).
    public func live(at t: Double) -> [Meteor] {
        var out: [Meteor] = []
        for case let m? in slots where m.born <= t && m.ends > t { out.append(m) }
        return out
    }

    /// True while any is still to come or showing at `t`.
    public func busy(at t: Double) -> Bool {
        for case let m? in slots where m.ends > t { return true }
        return false
    }

    /// The sky with this world's meteors showing first, then the calendar's, six in all (the sky's slots); with more than
    /// six of its own, the heads before the trains, the brighter first.
    public func inject(into s: inout SkyState) {
        let t = s.meteorTime
        var mine = live(at: t)
        guard !mine.isEmpty else { return }
        if mine.count > MeteorSky.slots {
            mine.sort { MeteorSky.importance($0, at: t) > MeteorSky.importance($1, at: t) }
            mine.removeLast(mine.count - MeteorSky.slots)
        }
        let room = max(0, MeteorSky.slots - mine.count)
        s.meteors = mine + Array(s.meteors.prefix(room))
    }

    /// The light the brightest fireball among them casts at `t` (0…1, before any flash limiter): the sky's own fireball
    /// rule (magnitude −4 or brighter; 0.2 at −4 … 1 at −8) along the head's light curve.
    public func fireballLight(at t: Double) -> Float {
        var light: Float = 0
        for case let m? in slots where m.magnitude <= MeteorSky.fireball && m.isHead(at: t) {
            let strength = min(1, (-3 - m.magnitude) / 5)
            let shape = m.headBrightness(at: t) / max(1e-6, m.peakBrightness)
            light = max(light, strength * min(1.5, shape))
        }
        return min(1, light)
    }

    /// An east-north-up unit vector at azimuth `azimuth` (degrees from north, clockwise) and altitude `altitude` (degrees).
    public static func direction(azimuth: Double, altitude: Double) -> SIMD3<Float> {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        return SIMD3<Float>(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }

    /// A shooting star running away from `radiant` (an east-north-up unit vector): it starts `distance` degrees from it,
    /// at the bearing `angle` about it (radians: 0 straight down the sky from it, + to its right), and runs `length`
    /// degrees further along the same great circle in `duration` seconds. Fast (`speed` km/s ≥ 55) bright ones (brighter
    /// than −1) leave a train, as the sky's own do.
    public static func meteor(radiant: SIMD3<Float>, distance: Float, angle: Float, length: Float, born: Double, duration: Float,
                              magnitude: Float, speed: Double, flare: Bool) -> Meteor {
        let r = simd_normalize(SIMD3<Double>(Double(radiant.x), Double(radiant.y), Double(radiant.z)))
        let up = SIMD3<Double>(0, 0, 1)
        var down = r * simd_dot(r, up) - up            // straight down the sky, in the plane at right angles to r
        if simd_length(down) < 1e-6 { down = SIMD3<Double>(0, -1, 0) }
        down = simd_normalize(down)
        let side = simd_normalize(simd_cross(r, down))
        let a = Double(angle)
        let tangent = down * cos(a) + side * sin(a)
        let d0 = Double(distance) * .pi / 180, d1 = Double(distance + length) * .pi / 180
        let start = r * cos(d0) + tangent * sin(d0), end = r * cos(d1) + tangent * sin(d1)
        let seen = Double(magnitude)
        let train: Float = speed >= 55 && seen < -1 ? Float(min(1, (-1 - seen) / 6)) : 0
        return Meteor(start: float(start), end: float(end), born: born, duration: max(0.08, duration), magnitude: magnitude,
                      colour: MeteorSky.colour(speed: speed, magnitude: seen), train: train, shower: -1, flare: flare,
                      radiant: radiant)
    }

    /// A meteor along the great circle from `start` to `end` (east-north-up unit vectors).
    public static func meteor(from start: SIMD3<Float>, to end: SIMD3<Float>, born: Double, duration: Float, magnitude: Float,
                              speed: Double, flare: Bool) -> Meteor {
        let seen = Double(magnitude)
        let train: Float = speed >= 55 && seen < -1 ? Float(min(1, (-1 - seen) / 6)) : 0
        return Meteor(start: simd_normalize(start), end: simd_normalize(end), born: born, duration: max(0.08, duration),
                      magnitude: magnitude, colour: MeteorSky.colour(speed: speed, magnitude: seen), train: train, shower: -1,
                      flare: flare)
    }

    private static func float(_ v: SIMD3<Double>) -> SIMD3<Float> {
        let n = simd_normalize(v)
        return SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
    }
}
