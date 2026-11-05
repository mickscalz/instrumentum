import Foundation
import simd

/// The reef's kinds of coral (spec §9.2): rounded brain corals for the bass, plate and soft corals in the middle and
/// branching staghorn tips for the treble.
public enum CoralKind: String, CaseIterable {
    case brain, plate, soft, staghorn
}

/// One of the reef's seven coral groups (spec §9.2), from the bass at the left of the frame to the treble at the right.
public struct CoralGroup: Equatable {
    public var kind: CoralKind
    /// Where it stands across the frame (0…1, left to right: `CoralPulse.groupX`) and how high its polyps reach in the
    /// water (0 the reef floor at the bottom of the water … 1 the underside of the surface: `CoralPulse.groupTop`).
    public var x: Float
    public var top: Float
    /// How brightly its polyps glow now, 0…1: its lit patches together (the soft union of their brightness), lifted by
    /// up to 0.3 while a colour wave passes. It changes smoothly; the renderer passes it through `FlashLimiter`.
    public var glow: Float
    /// Its fluorescent hue in turns (0 red, 1/3 green, 2/3 blue; fully saturated): its own green, orange or pink
    /// (`CoralPulse.hues`), carried toward the colour wave's hue while the wave passes.
    public var hue: Float

    /// The hue as linear RGB, fully saturated (the fluorescence; scale it by `glow`).
    public var colour: SIMD3<Float> { CoralPulse.rgb(hue: hue) }
}

/// A patch of polyps a note opens and lights on its coral group.
public struct PolypPatch: Equatable {
    public var id: Int
    public var note: UInt8
    /// The coral group it lights (0 the bass … 6 the treble).
    public var group: Int
    /// Across the frame: its key's place (0.06…0.94, within its group's head); how high up the coral head it sits
    /// (water heights: the group's top × (0.6 + 0.4 × velocity), so harder notes light the tips).
    public var x: Float
    public var y: Float
    /// Its brightness while lit: 0.4 + 0.6 × velocity, times the mood's reaction (at most 1).
    public var peak: Float
    /// Its brightness now: `peak` while held (or pedalled), fading with τ 2.5 s (5 s while the playing lingers, times
    /// the mood's linger) once let go.
    public var brightness: Float
    /// Held, or sounding under the pedal.
    public var held: Bool
}

/// A chord's colour wave: two fronts running out from where the chord was played until they have swept the whole reef.
public struct ColourWave: Equatable {
    public var id: Int
    /// Where the chord's keys sit across the frame (their mean place, 0…1): the fronts start here.
    public var x: Float
    /// 0 as the chord sounds … 1 once both fronts have run off the reef's edges (then the wave is gone).
    public var phase: Float
    /// The chord: major (warm pinks and oranges), minor (blues and violets), tense (a flicker of purple); open fifths and
    /// anything else a pale aqua.
    public var quality: ChordQuality
    /// The wave's hue in turns: `CoralPulse.waveHue(for: quality)`. A renderer may spread it ±0.05 across a front.
    public var hue: Float
    /// 0…1 now: rising over 0.3 s, dimming to 0.4 of its peak as it travels; a tense chord's flickers by up to 20% at
    /// 2.5 Hz (never a flash). The renderer passes it through `FlashLimiter`.
    public var strength: Float
    /// How far each front has run from `x` (frame widths, `CoralPulse.waveSpeed` a second); the fronts' soft width is
    /// `CoralPulse.waveWidth`.
    public var offset: Float
    var peak: Float
    var age: Float
    var reach: Float

    /// The fronts' places across the frame (off the frame once they have passed its edges).
    public var left: Float { x - offset }
    public var right: Float { x + offset }
}

/// The school of small fish that darts along the melody: 20…80 of them, by the Fish dial.
public struct School: Equatable {
    /// Each fish's place: x 0…1 across the frame, y in water heights (0 the reef floor … 1 the underside of the surface).
    public var positions: [SIMD2<Float>]
    /// The way the school swims, radians (0 toward +x, π/2 up): every fish turns with it.
    public var heading: Float
    /// 0…1: the school flashing silver as it turns on an accent (velocity 0.85 or more): rising over about 50 ms and
    /// fading with τ 0.35 s. The renderer passes it through `FlashLimiter`.
    public var flash: Float
    /// Its leader's place (the school follows it).
    public var centre: SIMD2<Float>
    /// The places of the last 8 melody notes (oldest first): the path the school follows.
    public var path: [SIMD2<Float>]

    public static let still = School(positions: [], heading: 0, flash: 0, centre: SIMD2<Float>(0.5, 0.6), path: [])
}

/// Coral Pulse (spec §9.2). The reef holds seven coral groups across the frame, the keyboard in seven stretches of
/// about an octave: brain corals at the left for the bass, plate and soft corals in the middle, staghorn tips at the
/// right for the treble. Each note opens and lights a patch of polyps on the group nearest its key, fluorescent green,
/// orange or pink by group and as bright as it was struck; held (or pedalled) notes keep it glowing, and it fades with
/// τ 2.5 s after release. A school of small fish darts along the melody, following the last 8 notes' places across
/// the reef and turning together (one deterministic flock of at most 80), flashing silver on accents; a chord sends a
/// colour wave sweeping the whole reef from its mean place, warm for major, cool for minor, a flicker of purple when
/// tense. At most 64 lit patches and 12 new ones a step; ids wrap. Every brightness it hands out is 0…1 and changes
/// smoothly, for the renderer's `FlashLimiter`.
public struct CoralPulse {
    public static let groupCount = 7
    public static let cap = 64
    public static let maxSpawnsPerStep = 12
    public static let fadeTau = 2.5, lingerTau = 5.0
    /// A note within this long of the previous one (but not struck with it) carries a run on: the school darts.
    public static let runWindow = 0.25
    /// Closer than this, notes are struck together (a chord or a smudge), not a melody: the school ignores them.
    static let minRunGap = 0.04
    /// Chords: three or more notes within 60 ms.
    static let chordWindow = 0.06
    /// The school follows the last this-many melody notes.
    public static let pathNotes = 8
    /// The school's size: 20 at Fish 0 … 80 at Fish 1.
    public static let schoolSizes: ClosedRange<Int> = 20...80
    /// A note at least this hard (velocity 0…1) is an accent: the school flashes silver.
    public static let accent: Float = 0.85
    /// The colour wave's fronts run this far a second (frame widths), with this soft width.
    public static let waveSpeed: Float = 0.4
    public static let waveWidth: Float = 0.08
    /// While time is held (a step of dt 0) a chord's colour wave born since the last step runs on to this age at once:
    /// risen to its full strength (it rises over 0.3 s), its fronts out where 0.3 s takes them; an accent's silver flash
    /// is full at once. Polyp patches are full at birth already. Else neither would show (Small Wins §4).
    public static let waveBloomAge: Float = 0.3

    /// The seven groups' places across the frame: the keyboard in seven equal stretches, each group at its stretch's
    /// middle, mapped like the keys' own places to 0.06…0.94.
    public static let groupX: [Float] = (0..<7).map { i -> Float in 0.06 + 0.88 * (Float(i) + 0.5) / 7 }
    public static let kinds: [CoralKind] = [.brain, .brain, .plate, .soft, .plate, .staghorn, .staghorn]
    /// How high each group's polyps reach (water heights): low rounded brains, plates and soft corals, tall staghorn.
    public static let groupTop: [Float] = [0.16, 0.19, 0.25, 0.30, 0.24, 0.33, 0.31]
    /// Each group's own fluorescence (hue in turns): green, orange, green, pink, orange, pink, green.
    public static let hues: [Float] = [0.33, 0.08, 0.36, 0.92, 0.06, 0.90, 0.30]

    /// The mood's scales, set by the world each frame (how brightly it reacts; how long released polyps linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1
    /// The Fish dial (0…1), set by the world each frame: the school's size.
    public var fish: Double = 0.6

    /// The groups after the last step (always seven, bass first).
    public private(set) var groups: [CoralGroup]
    /// The colour wave while it sweeps the reef.
    public private(set) var wave: ColourWave?
    /// Patches lit in the last step (tests).
    private(set) var lastSpawns = 0

    var nextID = 0, nextWaveID = 0
    private var lit: [PolypPatch] = []
    private var held = Set<UInt8>()
    /// Released while the pedal is down: still sounding, so still lit.
    private var sustained = Set<UInt8>()
    private var pedal = false
    /// Notes waiting for a patch (rationed per step; only the latest `cap` are kept).
    private var queue: [(note: UInt8, velocity: Float)] = []
    private var chordNotes: [(t: Double, x: Float, v: Float)] = []
    private var lastChord = -Double.infinity

    // The school.
    /// Where its leader may swim: above the corals, below the surface (x across the frame, y in water heights).
    public static let schoolLow = SIMD2<Float>(0.04, 0.32), schoolHigh = SIMD2<Float>(0.96, 0.9)
    private static let fishCapacity = 80
    private static let trailLength = 32
    private static let trailInterval = 1.0 / 30
    private var time = 0.0
    private var leader: SIMD2<Float>
    private var velocity = SIMD2<Float>(0, 0)
    private var heading: Float = 0
    private var flash: Float = 0
    private var flashTarget: Float = 0
    private var path: [SIMD2<Float>] = []
    private var lastNote = -Double.infinity
    private var lastRun = -Double.infinity
    private var trail: [SIMD2<Float>]
    private var trailHead = 0
    private var trailClock = 0.0
    private var fishPositions: [SIMD2<Float>]
    /// Each fish's lag behind the leader along its trail (s), its slot in the school (along and across its heading) and
    /// its own small wiggle's phase.
    private let fishDelay: [Float]
    private let fishAlong: [Float]
    private let fishAcross: [Float]
    private let fishPhase: [Float]

    public init() {
        var r = SeededRandom(seed: 0xC0_4A1F_15C4)
        var delay: [Float] = [], along: [Float] = [], across: [Float] = [], phase: [Float] = []
        for _ in 0..<Self.fishCapacity {
            let rank = r.unit()                  // 0 at the front of the school … 1 at its back
            let side = 2 * r.unit() - 1
            delay.append(0.4 * rank)
            along.append(0.02 - 0.07 * rank)
            across.append(0.035 * side * (1 - 0.4 * rank))
            phase.append(r.range(0, 2 * .pi))
        }
        fishDelay = delay; fishAlong = along; fishAcross = across; fishPhase = phase
        let start = Self.cruise(at: 0)
        leader = start
        trail = [SIMD2<Float>](repeating: start, count: Self.trailLength)
        var placed: [SIMD2<Float>] = []
        for i in 0..<Self.fishCapacity { placed.append(start + SIMD2<Float>(along[i], across[i])) }
        fishPositions = placed
        groups = (0..<Self.groupCount).map { g in
            CoralGroup(kind: Self.kinds[g], x: Self.groupX[g], top: Self.groupTop[g], glow: 0, hue: Self.hues[g])
        }
    }

    // MARK: - The reef's layout

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    /// A note's place across the frame: its key's centre, mapped to 0.06…0.94.
    public static func x(for note: UInt8) -> Float { 0.06 + 0.88 * centres[Int(min(108, max(21, note))) - 21] }

    private static let groupTable: [Int] = (21...108).map { n -> Int in
        let x = CoralPulse.x(for: UInt8(n))
        var best = 0
        for g in 1..<CoralPulse.groupCount where abs(CoralPulse.groupX[g] - x) < abs(CoralPulse.groupX[best] - x) { best = g }
        return best
    }

    /// The coral group a note lights: the one nearest its key across the frame.
    public static func group(for note: UInt8) -> Int { groupTable[Int(min(108, max(21, note))) - 21] }

    /// The school's size for a Fish dial value: 20 at 0 … 80 at 1.
    public static func schoolSize(fish: Double) -> Int {
        let f = fish.isFinite ? min(max(fish, 0), 1) : 0.6
        return schoolSizes.lowerBound + Int((Double(schoolSizes.upperBound - schoolSizes.lowerBound) * f).rounded())
    }

    /// Where a melody note calls the school: above its key's coral, higher for higher notes (water heights 0.36…0.8).
    public static func point(for note: UInt8) -> SIMD2<Float> {
        let pitch = Float(Int(min(108, max(21, note))) - 21) / 87
        return SIMD2<Float>(x(for: note), 0.36 + 0.44 * pitch)
    }

    /// The colour wave's hue (turns) for a chord: warm pink-orange, blue-violet, purple, or a pale aqua.
    public static func waveHue(for q: ChordQuality) -> Float {
        switch q {
        case .major: return 0.97
        case .minor: return 0.70
        case .tense: return 0.79
        case .open, .none: return 0.47
        }
    }

    /// A fully saturated hue (turns) as linear RGB.
    public static func rgb(hue: Float) -> SIMD3<Float> {
        let h = hue.isFinite ? hue - hue.rounded(.down) : 0
        func channel(_ offset: Float) -> Float {
            var k = (h * 6 + offset).truncatingRemainder(dividingBy: 6)
            if k < 0 { k += 6 }
            return 1 - min(max(min(k, 4 - k), 0), 1)
        }
        return SIMD3<Float>(channel(5), channel(3), channel(1))
    }

    /// The hue `t` of the way from `a` to `b` round the shorter side of the colour wheel (turns, 0…<1).
    static func mixHue(_ a: Float, _ b: Float, _ t: Float) -> Float {
        var d = b - a
        d -= d.rounded()
        var h = a + d * min(max(t, 0), 1)
        h -= h.rounded(.down)
        return h
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private var reaction: Float { reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1 }

    // MARK: - What it shows

    /// The lit polyp patches (at most 64), oldest first.
    public var patches: [PolypPatch] { lit }

    /// The school now: `schoolSize(fish:)` fish.
    public var school: School {
        let n = Self.schoolSize(fish: fish)
        return School(positions: Array(fishPositions.prefix(n)), heading: heading, flash: flash, centre: leader, path: path)
    }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v))
        if queue.count > Self.cap { queue.removeFirst(queue.count - Self.cap) }
        guard t.isFinite else { return }

        // The melody calls the school: notes struck together (a chord, a smudge) neither call it nor break a run.
        let gap = t - lastNote
        if !(gap >= 0 && gap < Self.minRunGap) {
            path.append(Self.point(for: note))
            if path.count > Self.pathNotes { path.removeFirst(path.count - Self.pathNotes) }
            if gap <= Self.runWindow { lastRun = t }
        }
        lastNote = t
        if v >= Self.accent { flashTarget = 1 }

        // A chord: three or more notes within 60 ms (once per chord) send a colour wave from their mean place.
        chordNotes.append((t, Self.x(for: note), v))
        while let first = chordNotes.first, t - first.t > Self.chordWindow { chordNotes.removeFirst() }
        if chordNotes.count > Self.cap { chordNotes.removeFirst(chordNotes.count - Self.cap) }
        guard chordNotes.count >= 3, t - lastChord > Self.chordWindow else { return }
        lastChord = t
        let n = Float(chordNotes.count)
        let origin = chordNotes.map(\.x).reduce(0, +) / n
        let meanV = chordNotes.map(\.v).reduce(0, +) / n
        let quality = PlayingAnalyzer.classify(held.union(sustained))
        let reach = max(origin, 1 - origin) + Self.waveWidth
        wave = ColourWave(id: nextWaveID, x: origin, phase: 0, quality: quality, hue: Self.waveHue(for: quality),
                          strength: 0, offset: 0, peak: min(1, (0.5 + 0.5 * meanV) * reaction), age: 0, reach: reach)
        nextWaveID = nextWaveID &+ 1
    }

    public mutating func noteOff(_ note: UInt8) {
        guard held.remove(note) != nil else { return }
        if pedal { sustained.insert(note) }
    }

    public mutating func setPedal(_ down: Bool) {
        pedal = down
        if !down { sustained.removeAll() }
    }

    /// Lets every note go (a panic, an unplugged keyboard, a change of visual): no patch stays lit, no queued note
    /// lights one, and the next note starts a new melody (the school keeps its path and swims on).
    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
        chordNotes.removeAll()
        lastNote = -.infinity
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        time += step
        let linger = Double(lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1)

        // New patches, at most 12 a step; a full reef lets its dimmest patch go first.
        lastSpawns = 0
        for (note, v) in queue.prefix(Self.maxSpawnsPerStep) {
            if lit.count >= Self.cap, let dimmest = lit.indices.min(by: { Self.score(lit[$0]) < Self.score(lit[$1]) }) {
                lit.remove(at: dimmest)
            }
            let g = Self.group(for: note)
            let peak = min(1, (0.4 + 0.6 * v) * reaction)
            lit.append(PolypPatch(id: nextID, note: note, group: g, x: Self.x(for: note), y: Self.groupTop[g] * (0.6 + 0.4 * v),
                                  peak: peak, brightness: peak, held: true))
            nextID = nextID &+ 1
            lastSpawns += 1
        }
        queue.removeFirst(min(queue.count, Self.maxSpawnsPerStep))

        // Held (or pedalled) patches stay lit; released ones fade (twice as slowly while the playing lingers).
        let sounding = held.union(sustained)
        let tau = (roles[.linger] > 0.5 ? Self.lingerTau : Self.fadeTau) * linger
        let fade = Float(exp(-step / tau))
        for i in lit.indices {
            lit[i].held = sounding.contains(lit[i].note)
            if lit[i].held { lit[i].brightness = lit[i].peak } else { lit[i].brightness *= fade }
        }
        lit.removeAll { !$0.held && $0.brightness < 0.01 }

        stepWave(fdt)
        stepSchool(step)
        groups = shine()
    }

    /// The colour wave's fronts run out until both have left the reef.
    private mutating func stepWave(_ dt: Float) {
        guard var w = wave else { return }
        // Held, a wave born since the last step runs on to its bloom.
        let dt = dt == 0 && w.age == 0 ? Self.waveBloomAge : dt
        w.age += dt
        w.offset += Self.waveSpeed * dt
        w.phase = min(1, w.offset / max(w.reach, 1e-3))
        var s = w.peak * Self.smoothstep(0, 0.3, w.age) * (1 - 0.6 * w.phase)
        if w.quality == .tense {
            let beat = 0.5 + 0.5 * sin(2 * Float.pi * 2.5 * w.age)
            s *= 1 - 0.2 * beat
        }
        w.strength = min(1, max(0, s))
        wave = w.phase >= 1 ? nil : w
    }

    /// Each group's glow and hue: its patches together, and the colour wave where its fronts are.
    private func shine() -> [CoralGroup] {
        var dark = [Float](repeating: 1, count: Self.groupCount)
        for p in lit where p.group >= 0 && p.group < Self.groupCount { dark[p.group] *= 1 - min(1, max(0, p.brightness)) }
        var out: [CoralGroup] = []
        out.reserveCapacity(Self.groupCount)
        for g in 0..<Self.groupCount {
            var glow = 1 - dark[g]
            var hue = Self.hues[g]
            if let w = wave {
                let a = (Self.groupX[g] - w.left) / Self.waveWidth, b = (Self.groupX[g] - w.right) / Self.waveWidth
                let near = max(exp(-a * a), exp(-b * b))
                let weight = w.strength * near
                glow = min(1, glow + 0.3 * weight)
                hue = Self.mixHue(hue, w.hue, 0.8 * min(1, near))
            }
            out.append(CoralGroup(kind: Self.kinds[g], x: Self.groupX[g], top: Self.groupTop[g], glow: glow, hue: hue))
        }
        return out
    }

    // MARK: - The school

    /// The school's slow cruise over the reef while nothing calls it: a lazy loop above the corals.
    static func cruise(at t: Double) -> SIMD2<Float> {
        let x = 0.5 + 0.3 * sin(0.11 * t + 0.6)
        let y = 0.6 + 0.12 * sin(0.17 * t + 1.9)
        return SIMD2<Float>(Float(x), Float(y))
    }

    /// The leader chases the newest melody note (darting during a run), then eases back onto its cruise; the fish follow
    /// its trail, each a little later and in its own slot, so a run stretches the school along the melody's contour.
    private mutating func stepSchool(_ dt: Double) {
        let since = time - lastNote
        let goal: SIMD2<Float>
        let omega: Double
        if let newest = path.last, since < 5 {
            let back = Float(MoonlitLakeModel.smooth(3, 5, since))
            goal = newest + (Self.cruise(at: time) - newest) * back
            omega = time - lastRun < 0.6 ? 9 : (since < 3 ? 4 : 1.5)
        } else {
            goal = Self.cruise(at: time)
            omega = 1.5
        }
        // A critically damped spring toward the goal, solved exactly over the step (stable at any step).
        let e = Float(exp(-omega * dt))
        let w = Float(omega), h = Float(dt)
        let a = leader - goal
        let b = velocity + a * w
        leader = goal + (a + b * h) * e
        velocity = (b - (a + b * h) * w) * e
        let kept = leader.clamped(lowerBound: Self.schoolLow, upperBound: Self.schoolHigh)
        if kept.x != leader.x { velocity.x = 0 }
        if kept.y != leader.y { velocity.y = 0 }
        leader = kept

        // The school turns together toward where the leader is going.
        let speed = simd_length(velocity)
        if speed > 0.03 {
            var turn = atan2(velocity.y, velocity.x) - heading
            turn -= 2 * .pi * (turn / (2 * .pi)).rounded()
            heading += turn * Float(1 - exp(-dt / 0.2))
            heading -= 2 * .pi * (heading / (2 * .pi)).rounded()
        }

        // The silver flash on an accent: in over about 50 ms, out with τ 0.35 s.
        flashTarget *= Float(exp(-dt / 0.35))
        if flashTarget > flash {
            // Held (dt 0), an accent's flash is full at once and holds; running, it comes in over about 50 ms.
            flash += (flashTarget - flash) * (dt == 0 ? 1 : Float(1 - exp(-dt / 0.025)))
        } else {
            flash = flashTarget
        }
        if flash < 1e-4 { flash = 0; if flashTarget < 1e-4 { flashTarget = 0 } }

        // The leader's trail, a sample every 1/30 s.
        trailClock += dt
        var pushes = 0
        while trailClock >= Self.trailInterval && pushes < Self.trailLength {
            trailClock -= Self.trailInterval
            trailHead = (trailHead + 1) % Self.trailLength
            trail[trailHead] = leader
            pushes += 1
        }
        if trailClock >= Self.trailInterval { trailClock = 0 }

        let c = cos(heading), s = sin(heading)
        let glide = Float(1 - exp(-dt / 0.1))
        let t = Float(time.truncatingRemainder(dividingBy: 3600))
        for i in 0..<Self.fishCapacity {
            let back = Double(fishDelay[i]) / Self.trailInterval
            let k = min(Double(Self.trailLength - 2), back)
            let k0 = Int(k)
            let f = Float(k - Double(k0))
            let p0 = trail[(trailHead - k0 + 2 * Self.trailLength) % Self.trailLength]
            let p1 = trail[(trailHead - k0 - 1 + 2 * Self.trailLength) % Self.trailLength]
            let base = p0 + (p1 - p0) * f
            let along = fishAlong[i], across = fishAcross[i] + 0.004 * sin(2.3 * t + fishPhase[i])
            let slot = SIMD2<Float>(along * c - across * s, along * s + across * c)
            var p = fishPositions[i]
            p += (base + slot - p) * glide
            fishPositions[i] = p.clamped(lowerBound: SIMD2<Float>(0, 0), upperBound: SIMD2<Float>(1, 1))
        }
    }

    static func score(_ p: PolypPatch) -> Float { p.held ? 2 + p.brightness : p.brightness }

    /// The `limit` patches worth drawing when the budget is smaller than the cap: the brightest, in their original order.
    public static func visible(_ p: [PolypPatch], limit: Int) -> [PolypPatch] {
        guard p.count > limit else { return p }
        let keep = Set(p.indices.sorted { score(p[$0]) > score(p[$1]) }.prefix(max(0, limit)))
        return p.indices.filter { keep.contains($0) }.map { p[$0] }
    }
}
