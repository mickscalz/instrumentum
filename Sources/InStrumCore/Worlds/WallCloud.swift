import Foundation
import simd

// Wall Cloud (Storms spec §8.2): Supercell Sky's visual. The supercell's lowered, rotating wall cloud and the inflow
// bands feeding it, played: Energy spins the mesocyclone (0.3 → 2 rpm) and tightens the inflow (the bands' spacing
// 12° → 5°); each note sends a glow up the inflow band nearest its key into the wall cloud; a chord pulses light into
// the wall cloud's base; a run is a ripple travelling round its circumference. Everything here is control-rate Core
// state: the renderer draws the bands, the base and the ripples from it.

/// A note's light running up an inflow band into the wall cloud.
public struct InflowGlow: Equatable {
    public var id: Int
    /// The band it runs up: 0 … `WallCloud.bandCount` − 1, the band whose outer end is leftmost first.
    public var band: Int
    /// Seconds since its note.
    public var age: Float
    /// Its light at full, 0…1 (the note's velocity × the mood's reach).
    public var strength: Float

    /// How far up the band it has run: 0 at the band's outer end … 1 into the wall cloud (over `WallCloud.glowSeconds`).
    public var progress: Float { min(1, max(0, age / WallCloud.glowSeconds)) }
    /// Its light now: in over 60 ms, full while it runs, then fading into the wall cloud over `WallCloud.glowFade`.
    public var brightness: Float {
        let rise = min(1, max(0, age / 0.06))
        let fade = 1 - min(1, max(0, (age - WallCloud.glowSeconds) / WallCloud.glowFade))
        return strength * rise * fade
    }
}

/// A chord's pulse of light into the wall cloud's base: a ring spreading out from the wall cloud over the base.
public struct BasePulse: Equatable {
    public var id: Int
    public var age: Float
    public var strength: Float

    /// Its light now: an 80 ms rise, then falling away (τ 0.45 s), gone at `WallCloud.pulseSeconds`.
    public var brightness: Float {
        let rise = min(1, max(0, age / 0.08))
        let fall: Float = age <= 0.08 ? 1 : exp(-(age - 0.08) / 0.45)
        let end = 1 - min(1, max(0, (age - WallCloud.pulseSeconds + 0.3) / 0.3))
        return strength * rise * fall * end
    }
    /// How far its ring has spread over the base: 0 at the wall cloud … 1 at the base's edge.
    public var spread: Float { min(1, max(0, age / WallCloud.pulseSeconds)) }
}

/// A run's ripple round the wall cloud's circumference: a bulge of brighter cloud travelling round it.
public struct WallRipple: Equatable {
    public var id: Int
    /// Where it set out (radians round the wall cloud: 0 faces the camera, positive anticlockwise seen from above).
    public var start: Float
    /// Which way it runs: +1 anticlockwise (a rising run), −1 clockwise (a falling one).
    public var direction: Float
    public var age: Float
    /// 0…1: each further note of the run feeds it.
    public var strength: Float

    /// Where it is now (radians, unwrapped): a turn in `WallCloud.rippleSeconds`.
    public var angle: Float { start + direction * 2 * Float.pi * age / WallCloud.rippleSeconds }
    /// Its light now: in over 0.1 s, out over its last 40%.
    public var brightness: Float {
        let rise = min(1, max(0, age / 0.1))
        let x = min(1, max(0, (age / WallCloud.rippleSeconds - 0.6) / 0.4))
        return strength * rise * (1 - x * x * (3 - 2 * x))
    }
}

/// The Wall Cloud visual's state (spec §8.2). Notes reach it through `noteOn`, time through `step`.
public struct WallCloud {
    /// The inflow bands feeding the wall cloud.
    public static let bandCount = 7
    /// A glow takes this long to run up its band, then fades into the wall cloud over `glowFade`.
    public static let glowSeconds: Float = 1.2
    public static let glowFade: Float = 0.4
    public static let pulseSeconds: Float = 1.8
    public static let rippleSeconds: Float = 2.6
    /// The most glows, pulses and ripples alive at once, and the most glows a step releases (a MIDI flood waits its turn,
    /// the latest notes first).
    public static let glowCap = 24
    public static let pulseCap = 4
    public static let rippleCap = 4
    public static let maxSpawnsPerStep = 8
    /// The mesocyclone's turn (spec §8.2): 0.3 rpm at rest, 2 rpm at full Energy; Reduce Motion caps it at 1.
    public static let restingRPM: Float = 0.3
    public static let fullRPM: Float = 2
    public static let reducedRPM: Float = 1
    /// The inflow bands' spacing (degrees round the wall cloud): wide at rest, tight at full Energy.
    public static let wideSpacing: Float = 12
    public static let tightSpacing: Float = 5
    /// Chords: three or more notes within 60 ms. A note within `runWindow` of the last (but not struck with it) carries a run.
    static let chordWindow = 0.06
    static let runWindow = 0.25
    static let minRunGap = 0.04

    /// Which way the storm turns seen from above: +1 anticlockwise (a northern supercell), −1 clockwise (southern).
    public var spin: Float = 1
    /// How far reactions reach (the mood's `reactionScale`).
    public var reaction: Float = 1

    /// The mesocyclone's angle (radians, wrapped to ±π), its rate now and the inflow's tightness (0 wide … 1 tight).
    public private(set) var rotation: Float = 0
    public private(set) var rpm: Float = WallCloud.restingRPM
    public private(set) var tightness: Float = 0
    public private(set) var glows: [InflowGlow] = []
    public private(set) var pulses: [BasePulse] = []
    public private(set) var ripples: [WallRipple] = []
    /// How many glows the last step released.
    public private(set) var lastSpawns = 0
    /// The next ids (internal, so tests can start them near the top and see them wrap).
    var nextGlowID = 0, nextPulseID = 0, nextRippleID = 0

    private var queue: [(band: Int, v: Float)] = []
    private var time = 0.0
    private var lastNote = -Double.infinity
    private var lastPitch: Int?
    private var chordNotes: [(t: Double, v: Float)] = []
    private var lastChord = -Double.infinity

    public init() {}

    // MARK: - The laws

    /// The mesocyclone's rate (rpm) for an Energy (0…1): 0.3 + 1.7 × Energy, at most 1 under Reduce Motion.
    public static func rpm(energy: Float, reduceMotion: Bool) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        let r = restingRPM + (fullRPM - restingRPM) * e
        return reduceMotion ? min(reducedRPM, r) : r
    }

    /// The inflow bands' spacing (degrees) at a tightness (0…1): 12° → 5°.
    public static func spacing(tightness: Float) -> Float {
        let k = tightness.isFinite ? min(1, max(0, tightness)) : 0
        return wideSpacing + (tightSpacing - wideSpacing) * k
    }

    /// The band a note glows up: the band whose outer end lies nearest the note's key across the keyboard (the bands'
    /// outer ends are spread evenly across the view, the leftmost first).
    public static func band(for note: UInt8) -> Int {
        guard let key = KeyboardLayout.key(for: note) else { return note < KeyboardLayout.lowestNote ? 0 : bandCount - 1 }
        let x = key.x + 0.5 * key.width
        return min(bandCount - 1, max(0, Int(x * Float(bandCount))))
    }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float) {
        let v = velocity.isFinite ? min(1, max(0, velocity)) : 0.7
        queue.append((band: Self.band(for: note), v: v))
        if queue.count > Self.glowCap { queue.removeFirst(queue.count - Self.glowCap) }
        let t = time
        // A run: a note soon after the last (not struck with it) feeds the newest ripple, or sets a new one off.
        let gap = t - lastNote
        let pitch = Int(note)
        if gap >= Self.minRunGap && gap <= Self.runWindow, let previous = lastPitch {
            let direction: Float = pitch >= previous ? 1 : -1
            if var r = ripples.last, r.age < 0.6 * Self.rippleSeconds, r.direction == direction {
                r.strength = min(1, r.strength + 0.12 * reaction)
                ripples[ripples.count - 1] = r
            } else {
                let start: Float = direction > 0 ? -0.5 * Float.pi : 0.5 * Float.pi
                ripples.append(WallRipple(id: nextRippleID, start: start, direction: direction, age: 0,
                                          strength: min(1, (0.35 + 0.35 * v) * reaction)))
                nextRippleID = nextRippleID &+ 1
                if ripples.count > Self.rippleCap { ripples.removeFirst(ripples.count - Self.rippleCap) }
            }
        }
        if gap < 0 || gap >= Self.minRunGap { lastPitch = pitch }
        lastNote = t
        // A chord: three or more notes within 60 ms (once per chord) pulse the wall cloud's base.
        chordNotes.append((t: t, v: v))
        chordNotes.removeAll { t - $0.t > Self.chordWindow }
        if chordNotes.count > Self.glowCap { chordNotes.removeFirst(chordNotes.count - Self.glowCap) }
        guard chordNotes.count >= 3, t - lastChord > Self.chordWindow else { return }
        lastChord = t
        var sum: Float = 0
        for c in chordNotes { sum += c.v }
        let mean = sum / Float(chordNotes.count)
        pulses.append(BasePulse(id: nextPulseID, age: 0, strength: min(1, (0.55 + 0.45 * mean) * reaction)))
        nextPulseID = nextPulseID &+ 1
        if pulses.count > Self.pulseCap { pulses.removeFirst(pulses.count - Self.pulseCap) }
    }

    /// A panic: nothing waits to glow and no run carries on.
    public mutating func allNotesOff() {
        queue.removeAll()
        chordNotes.removeAll()
        lastPitch = nil
    }

    // MARK: - Time

    /// Advances `dt` seconds at an Energy (the scene's, for drawing) and the inflow's tightness (0…1).
    public mutating func step(dt rawDt: Double, energy: Float, tightness k: Float, reduceMotion: Bool) {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        time += dt
        let fdt = Float(dt)
        rpm = Self.rpm(energy: energy, reduceMotion: reduceMotion)
        tightness = k.isFinite ? min(1, max(0, k)) : 0
        rotation += spin * rpm * 2 * Float.pi / 60 * fdt
        if rotation > Float.pi || rotation < -Float.pi {
            rotation -= 2 * Float.pi * (rotation / (2 * Float.pi)).rounded()
        }
        // Release the waiting notes' glows, at most `maxSpawnsPerStep` a step (they set out this step, so they are lit on
        // the frame they are struck); the cap lets the dimmest go first.
        let n = min(Self.maxSpawnsPerStep, queue.count)
        lastSpawns = n
        for q in queue.prefix(n) {
            glows.append(InflowGlow(id: nextGlowID, band: q.band, age: 0, strength: min(1, (0.45 + 0.55 * q.v) * reaction)))
            nextGlowID = nextGlowID &+ 1
        }
        queue.removeFirst(n)
        // Age what is alive, and let go of what has finished.
        for i in glows.indices { glows[i].age += fdt }
        glows.removeAll { $0.age >= Self.glowSeconds + Self.glowFade }
        for i in pulses.indices { pulses[i].age += fdt }
        pulses.removeAll { $0.age >= Self.pulseSeconds }
        for i in ripples.indices { ripples[i].age += fdt }
        ripples.removeAll { $0.age >= Self.rippleSeconds }
        while glows.count > Self.glowCap {
            var dimmest = 0
            for i in glows.indices where glows[i].brightness < glows[dimmest].brightness { dimmest = i }
            glows.remove(at: dimmest)
        }
    }
}

// MARK: - The flock

/// A bird of the storm's flock: where it is (metres: x across the view, y away from the camera, z up) and how it flies.
public struct StormBird: Equatable {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    /// Its wingbeat (radians, running).
    public var flap: Float

    /// Which way it is flying (a unit vector; straight up the view while it sits).
    public var heading: SIMD3<Float> {
        let l = simd_length(velocity)
        return l > 1e-4 ? velocity / l : SIMD3(0, 1, 0)
    }
}

/// The flock on the field (spec §8.2): a boids flock of 40 (20 on Smooth) that sits in the stubble until the first big
/// moment, lifts and wheels over the field (faster as you play harder), and streams away ahead of the gust front, toward
/// and past the camera, climbing. Once it has gone it comes back to the field a while later.
public struct StormFlock {
    public enum State: Equatable { case grounded, wheeling, fleeing, gone }

    public static func count(_ q: QualityLevel) -> Int { q == .lite ? 20 : 40 }
    /// The box it keeps to (metres).
    public static let lower = SIMD3<Float>(-800, -400, 0)
    public static let upper = SIMD3<Float>(800, 1000, 300)
    /// Where it sits, and the circle it wheels round once up.
    public static let roost = SIMD2<Float>(-30, 190)
    public static let wheelRadius: Float = 45
    public static let wheelHeight: Float = 28
    /// How long it stays away before it comes back to the field (s).
    public static let returnSeconds: Float = 45

    public private(set) var birds: [StormBird] = []
    public private(set) var state: State = .grounded
    /// Seconds in this state.
    public private(set) var stateAge: Float = 0
    /// The way it flees (on the ground: away from the storm, toward the camera).
    public private(set) var fleeDirection = SIMD2<Float>(-0.35, -1)
    private var rng: SeededRandom
    private var wanted: Int

    public init(quality: QualityLevel = .high, seed: UInt64 = 0xB12D_F10C) {
        rng = SeededRandom(seed: seed)
        wanted = Self.count(quality)
        settle()
    }

    /// The flock's size for a quality (40, or 20 on Smooth): birds are added on the field or let go.
    public mutating func setQuality(_ q: QualityLevel) {
        let n = Self.count(q)
        guard n != wanted else { return }
        wanted = n
        if birds.count > n { birds.removeLast(birds.count - n) }
        while birds.count < n { birds.append(seat(near: birds.last?.position)) }
    }

    /// The first big moment: up off the field (nothing changes once it is up or away).
    public mutating func lift() {
        guard state == .grounded else { return }
        state = .wheeling
        stateAge = 0
        for i in birds.indices {
            let up = rng.range(3, 6)
            let out = SIMD2<Float>(rng.range(-1, 1), rng.range(-1, 1))
            birds[i].velocity = SIMD3(2 * out.x, 2 * out.y, up)
        }
    }

    /// The gust front: stream away from the storm (`awayFromStorm` on the ground, any length), lifting first if it sits.
    public mutating func flee(awayFromStorm: SIMD2<Float>) {
        if state == .gone { return }
        if state == .grounded { lift() }
        let l = simd_length(awayFromStorm)
        if l > 1e-4, l.isFinite { fleeDirection = awayFromStorm / l }
        state = .fleeing
        stateAge = 0
    }

    /// How alarmed the flock sounds (0…1): calling as it lifts and flees, quiet on the field and once gone.
    public var alarm: Float {
        switch state {
        case .grounded, .gone: return 0
        case .wheeling: return max(0.25, 1 - stateAge / 6)
        case .fleeing: return max(0, 1 - stateAge / 20)
        }
    }

    /// The flock's mean height (m) and mean velocity (m/s).
    public var meanHeight: Float {
        guard !birds.isEmpty else { return 0 }
        var z: Float = 0
        for b in birds { z += b.position.z }
        return z / Float(birds.count)
    }
    public var meanVelocity: SIMD3<Float> {
        guard !birds.isEmpty else { return .zero }
        var v = SIMD3<Float>(repeating: 0)
        for b in birds { v += b.velocity }
        return v / Float(birds.count)
    }

    /// Advances `dt` seconds; Energy quickens the wheeling.
    public mutating func step(dt rawDt: Double, energy: Float) {
        let total = Float(rawDt.isFinite ? min(1, max(0, rawDt)) : 0)
        guard total > 0 else { return }
        stateAge += total
        if state == .grounded { return }
        if state == .gone {
            if stateAge >= Self.returnSeconds { settle() }
            return
        }
        let steps = max(1, Int((total * 30).rounded(.up)))
        let dt = total / Float(steps)
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        for _ in 0..<steps { boids(dt: dt, energy: e) }
        if state == .fleeing {
            var out = 0
            for b in birds where b.position.y < -150 || abs(b.position.x) > 650 || b.position.z > 260 { out += 1 }
            if out == birds.count || stateAge > 40 {
                state = .gone
                stateAge = 0
            }
        }
    }

    private mutating func boids(dt: Float, energy e: Float) {
        let n = birds.count
        let fleeing = state == .fleeing
        let cruise: Float = fleeing ? 16 : 8 + 5 * e
        let lo: Float = fleeing ? 12 : 6, hi: Float = fleeing ? 20 : 14
        var next = birds
        for i in 0..<n {
            let p = birds[i].position
            var sep = SIMD3<Float>(repeating: 0), align = SIMD3<Float>(repeating: 0), centre = SIMD3<Float>(repeating: 0)
            var near = 0
            for j in 0..<n where j != i {
                let d = birds[j].position - p
                let r2 = simd_dot(d, d)
                if r2 < 16, r2 > 1e-6 { sep -= d / r2 }
                if r2 < 400 {
                    align += birds[j].velocity
                    centre += birds[j].position
                    near += 1
                }
            }
            var steer: SIMD3<Float> = sep * 3.5
            if near > 0 {
                align = align / Float(near) - birds[i].velocity
                centre = centre / Float(near) - p
                steer += align * 0.6
                steer += centre * 0.25
            }
            let goal: SIMD3<Float>
            if fleeing {
                goal = SIMD3(fleeDirection.x, fleeDirection.y, 0.35) * cruise
            } else {
                // Wheel round the roost, at its height, turning the storm's way.
                let c = SIMD3(Self.roost.x, Self.roost.y, Self.wheelHeight)
                let off = SIMD2(p.x - c.x, p.y - c.y)
                let r = max(1, simd_length(off))
                let tangent = SIMD2(-off.y, off.x) / r
                let pull: Float = (r - Self.wheelRadius) * 0.08 / r
                let inward: SIMD2<Float> = off * (-pull)
                let around: SIMD2<Float> = tangent * cruise + inward
                goal = SIMD3(around.x, around.y, (c.z - p.z) * 0.3)
            }
            steer += (goal - birds[i].velocity) * 0.9
            var v = birds[i].velocity + steer * dt
            let speed = simd_length(v)
            if speed > hi { v *= hi / speed } else if speed < lo, speed > 1e-4 { v *= lo / speed }
            var q = p + v * dt
            q = q.clamped(lowerBound: Self.lower, upperBound: Self.upper)
            if q.z <= 0.5, v.z < 0 { v.z = -v.z * 0.5 }
            next[i].position = q
            next[i].velocity = v
            next[i].flap += dt * (fleeing ? 14 : 10)
            if next[i].flap > 2 * Float.pi { next[i].flap -= 2 * Float.pi }
        }
        birds = next
    }

    /// Back on the field: sat in the stubble round the roost.
    private mutating func settle() {
        state = .grounded
        stateAge = 0
        birds = []
        for _ in 0..<wanted { birds.append(seat(near: nil)) }
    }

    private mutating func seat(near: SIMD3<Float>?) -> StormBird {
        let x = Self.roost.x + rng.range(-35, 35), y = Self.roost.y + rng.range(-25, 25)
        return StormBird(position: SIMD3(x, y, 0), velocity: .zero, flap: rng.range(0, 2 * Float.pi))
    }
}
