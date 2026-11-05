import Foundation
import simd

/// What a note releases in Deep Lights, by its register (spec §8.2).
public enum CreatureKind: String, CaseIterable, Equatable {
    /// The bass, below C3: a slow, large jelly with a glowing rim.
    case jelly
    /// The middle, C3 to B4: a comb jelly whose rows of cilia shimmer.
    case combJelly
    /// The treble, from C5: a tiny bright speck (larvae and copepods).
    case speck
}

/// A glowing creature a note releases into the porthole's view (spec §8.2). The view's units: x 0…1 across (left to
/// right), y 0…1 up (0 the deep bottom … 1 the top).
public struct DeepCreature: Equatable {
    public var id: Int
    public var note: UInt8
    public var kind: CreatureKind
    /// Where it is: y by its note's pitch (`DeepLights.height(for:)`), x drifting with the current (a held creature
    /// that drifts out of view comes round again from the other side).
    public var position: SIMD2<Float>
    /// 0.35 + 0.65 × velocity: the renderer sizes each kind from it (a jelly large, a speck tiny).
    public var size: Float
    /// Its brightness while lit: 0.35 + 0.65 × velocity, times the mood's reaction (at most 1).
    public var peak: Float
    /// 0…1 now: `peak` × its pulse (the instrument's blink, or its own swim) × its fade once let go. A brightness the
    /// renderer passes through its `FlashLimiter`, never a flash of its own.
    public var glow: Float
    /// Held, or sounding under the pedal (only its note's latest creature).
    public var held: Bool
    /// Seconds since its note released it.
    public var age: Float
    /// Its own swim pulse (Hz): jellies 0.3–0.45, comb jellies 0.45–0.7, specks 0.7–1.
    public var swimRate: Float
    /// Where it is in its swim stroke, 0…1 (0 the stroke's brightest, where every creature starts): the renderer may
    /// beat a jelly's bell or ripple a comb jelly's cilia with it.
    public var swimPhase: Float
    /// 0 swimming at its own pace … 1 blinking on the instrument's pulse (gliding between the two over about 0.15 s).
    public var blinking: Float
    /// Porthole widths a second it drifts with the current (0.01…0.04, by kind).
    var drift: Float
    /// Its light's level: 1 while held, fading once let go.
    var level: Float
}

/// A lanternfish shoal a run sends flashing past (spec §8.2): a string of tiny lights along the run's contour, its head
/// crossing the porthole in `DeepLights.shoalCross` seconds.
public struct LanternShoal: Equatable {
    public var id: Int
    /// Each light's height (0…1, its note's, as the creatures'), from the head back: the run's notes in order, the first
    /// at the head; the run's later notes join at the tail (at most `DeepLights.shoalLights`).
    public var contour: [Float]
    /// +1 swimming left to right (a rising run), −1 right to left (a falling one).
    public var direction: Float
    /// 0…1: the run's velocity, times the mood's reaction.
    public var strength: Float
    /// Seconds since it set off.
    public var age: Float
    /// 0…1 now: `strength`, coming in over its first 0.15 s and going out as its tail leaves (for the `FlashLimiter`).
    public var brightness: Float

    /// How far across the head has come: 0 at the edge it enters by, 1 at the far edge (then on, out of view, until the
    /// tail has crossed too).
    public var progress: Float { age / DeepLights.shoalCross }

    /// Where light `i` is (x 0…1 across, y 0…1 up): the head at `progress` from its edge, each light
    /// `DeepLights.shoalSpacing` behind the one before it.
    public func light(_ i: Int) -> SIMD2<Float> {
        guard !contour.isEmpty else { return SIMD2<Float>(-1, 0.5) }
        let k = min(max(i, 0), contour.count - 1)
        let head: Float = direction >= 0 ? progress : 1 - progress
        let back: Float = direction * Float(k) * DeepLights.shoalSpacing
        return SIMD2<Float>(head - back, contour[k])
    }
}

/// A siphonophore a chord sends drifting across behind the creatures (spec §8.2): a long chain of glowing bells,
/// coloured by the chord.
public struct Siphonophore: Equatable {
    public var id: Int
    /// The chord's quality (`PlayingAnalyzer.classify` of what was sounding).
    public var quality: ChordQuality
    /// Its glow (linear RGB, `DeepLights.colour(_:)`): pale blue-green for a major chord, deep blue-violet for a minor
    /// one, a slow deep red for a tense one (the deep sea's one red light, the dragonfish's), the living light's cyan
    /// otherwise.
    public var colour: SIMD3<Float>
    /// 0…1: gold flecks among its bells (a major chord's, in `DeepLights.fleckColour`).
    public var flecks: Float
    /// 12…20 bells: more for a bigger, harder chord.
    public var bells: Int
    /// Its head: x 0…1 across, drifting with the current (the chain trails `bells × DeepLights.bellSpacing` behind it,
    /// to the left), y the chord's mean pitch (as the creatures').
    public var position: SIMD2<Float>
    /// Seconds since the chord.
    public var age: Float
    /// 0…1: the chord's velocity, times the mood's reaction.
    public var strength: Float
    /// 0…1 now: swelling in over about a second, held while the chord sounds, fading after (τ 4 s), with a slow pulse
    /// running through it (`pulseRate`). For the `FlashLimiter`.
    public var brightness: Float
    /// Its glow's slow pulse (Hz): 0.2, the tense red slower still (0.1).
    public var pulseRate: Float
    /// The chord's notes (it stays lit while any of them sounds), and its swell (0…1).
    var notes: Set<UInt8>
    var level: Float
}

/// A stream of bubbles an accent sends rising past the glass from the hull (spec §8.2).
public struct BubbleStream: Equatable {
    public var id: Int
    /// Where it rises across the glass: its note's key across the keyboard, mapped to 0.08…0.92.
    public var x: Float
    /// 0…1, how strong (how many bubbles, how big): 0.6 at an accent's threshold (velocity 0.85) … 1 at full velocity.
    public var strength: Float
    /// Seconds since it began: its bubbles rise from the foot of the glass to its top in `DeepLights.streamRise`
    /// seconds, the last of them gone by `DeepLights.streamLife`.
    public var age: Float
    /// For the renderer's own jitter of its bubbles.
    public var seed: UInt32
}

/// Deep Lights (spec §8.2): each note releases a glowing creature into the porthole's view (a jelly in the bass, a comb
/// jelly in the middle, a speck in the treble), as high as its pitch and as big and bright as its velocity. It drifts
/// with the current and pulses as it swims. While its note sounds (the pedal counts) it stays lit and, given the
/// instrument's pulse (Blue Depth's arp, spec §7.6), blinks on its sixteenth grid from the phrase's first note, as the
/// arp does; let go, it fades (τ 4 s). Runs send a lanternfish shoal flashing past along their contour, chords a
/// siphonophore drifting behind, coloured by the chord, and accents a stream of bubbles rising from the hull, with a
/// burst of their sound for the world's ambience.
///
/// The grid follows the arp's own clock: a note from C3 up (the arp never plays below it) starts it when none is
/// running, on that note; it steps every sixteenth at the pulse's tempo (each step's length taken at its start, as the
/// arp does, so a turned Tempo dial carries on from the step it is on); with nothing from C3 up sounding for
/// `phraseGap` seconds, or a panic (`allNotesOff`), it stops, and the next such note starts a fresh one. Turning Blink up
/// over held notes starts it there and then; with no pulse it stops.
///
/// Deterministic; every brightness it hands out is 0…1 and bounded, for the renderer's `FlashLimiter`. Note times are
/// on the clock `step` advances (`time`): the world stamps a note with its own time after adding the step it arrives
/// in, so a phrase's first note lights at its peak on that step.
public struct DeepLights {
    public static let cap = 48
    public static let maxSpawnsPerStep = 10
    /// Notes waiting for a creature (only the latest are kept).
    static let queueCap = 48
    /// Let go, a creature fades with this time constant (seconds, times the mood's linger; doubled while the playing
    /// lingers).
    public static let fadeTau = 4.0
    /// Below C3 a note is a jelly, from C5 a speck, comb jellies between. C3 is Blue Depth's bass split too: its arp
    /// never plays below it, so jellies never blink, and only notes from C3 up start or keep the grid.
    public static let bassSplit: UInt8 = 48, trebleSplit: UInt8 = 72
    /// The living light's colour (linear RGB): blue-cyan, mostly; the renderer adds its white core.
    public static let livingLight = SIMD3<Float>(0.25, 0.75, 1.0)
    /// A major chord's siphonophore's gold flecks (linear RGB).
    public static let fleckColour = SIMD3<Float>(1.0, 0.78, 0.3)
    /// Where a creature appears across the view (it drifts on from there), and past where it has drifted out of view
    /// (a held one comes round again from `outOfView − wrapWidth`).
    static let spawnX: ClosedRange<Float> = 0.1...0.6
    static let outOfView: Float = 1.15, wrapWidth: Float = 1.3
    /// Between swim strokes a creature dims to this share of its peak; the glide between swimming and blinking (s).
    static let swimFloor: Float = 0.6
    static let blinkGlide = 0.15
    /// With nothing from C3 up sounding this long (seconds), the arp's clock resets: the next note starts a fresh grid.
    public static let phraseGap = 2.0
    /// A note within this long of the previous one (but not struck with it) carries a run on.
    public static let runWindow = 0.2
    /// Closer than this, notes are struck together (a chord or a smudge), not a run.
    static let minRunGap = 0.04
    /// Shoals: at most 4 at once, 12 lights each, crossing in 1.5 s, their lights this far apart (view widths); a
    /// run's later notes join its shoal while the shoal is younger than `shoalJoin` seconds.
    public static let shoalCap = 4, shoalLights = 12
    public static let shoalCross: Float = 1.5
    public static let shoalSpacing: Float = 0.035
    static let shoalJoin: Float = 0.6
    /// Chords: three or more notes within 60 ms. At most 2 siphonophores, drifting across behind at this speed (view
    /// widths a second), each bell this far behind the one before it; a chord's swell lasts at least `chordSwell` s.
    static let chordWindow = 0.06
    public static let siphonophoreCap = 2
    public static let bellSpacing: Float = 0.03
    static let siphonophoreDrift: Float = 0.012
    static let swellTau = 0.6, chordSwell: Float = 1
    /// Accents: velocity 0.85 or more. At most 6 bubble streams, each rising for 2.5 s and gone by 3.5 s.
    public static let accent: Float = 0.85
    public static let streamCap = 6
    public static let streamRise: Float = 2.5, streamLife: Float = 3.5
    /// While time is held (a step of dt 0) what a note sends blooms at once (Small Wins §4), else it would never show: a
    /// shoal that set off since the last step starts this far into its crossing (its head a fifth of the way over, at
    /// full brightness), a bubble stream this far into its rise (a column already climbing the glass), and a chord's
    /// siphonophore at its full swell.
    public static let shoalBloomAge: Float = 0.3
    public static let streamBloomAge: Float = 0.8

    /// The instrument's pulse (spec §7.6), set by the world each frame: nil swims at the creatures' own pace.
    public var pulse: InstrumentPulse?
    /// The mood's scales (how brightly it reacts; how long released creatures linger).
    public var reactionScale: Float = 1
    public var lingerScale: Float = 1

    public private(set) var creatures: [DeepCreature] = []
    public private(set) var shoals: [LanternShoal] = []
    public private(set) var siphonophores: [Siphonophore] = []
    public private(set) var bubbleStreams: [BubbleStream] = []
    /// The bubble burst an accent asked for on the last step (its strength 0…1: the strongest accent's), else nil. The
    /// world's ambience carries it as a one-shot, so it is set on that step alone.
    public private(set) var burst: Double?
    /// The clock `step` advances (seconds): note times are on it.
    public private(set) var time: Double = 0
    /// Creatures released on the last step (tests).
    private(set) var lastSpawns = 0
    /// The arp's latest sixteenth, on `time`, while its grid runs (tests).
    var gridStep: Double? { grid?.last }

    var nextID = 0, nextShoalID = 0, nextSiphonophoreID = 0, nextStreamID = 0
    private var held = Set<UInt8>()
    /// Released while the pedal is down: still sounding, so still lit.
    private var sustained = Set<UInt8>()
    private var pedal = false
    /// Notes waiting for a creature (rationed per step).
    private var queue: [(note: UInt8, velocity: Float, t: Double)] = []
    /// The creature each note released last (only that one stays lit while the note sounds).
    private var currentCreature: [UInt8: Int] = [:]
    /// When the last note came; a run's notes waiting for a shoal (it sets off at three), and the shoal the run is
    /// filling.
    private var lastNote: Double?
    private var pendingShoal: [(height: Float, velocity: Float)] = []
    private var runShoal: Int?
    private var chordNotes: [(t: Double, note: UInt8, v: Float)] = []
    private var lastChord = -Double.infinity
    /// The latest chord's siphonophore, and its notes so far: how many, their velocities' and pitches' sums.
    private var chord: (id: Int, count: Int, velocity: Float, pitch: Float)?
    /// The arp's grid while it runs: its latest step and the next (on `time`); and since when nothing from C3 up has
    /// sounded.
    private var grid: (last: Double, next: Double)?
    private var quietSince: Double?
    private var rng = SeededRandom(seed: 0xDEE9_11C7)

    public init() {}

    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!
        return k.x + k.width / 2
    }

    // MARK: - Where and what

    /// A note's height in the view: 0.1 for A0 (the deep bottom) … 0.9 for C8 (near the top), by pitch.
    public static func height(for note: UInt8) -> Float { height(pitch: Float(note)) }

    static func height(pitch: Float) -> Float {
        let n = pitch.isFinite ? min(108, max(21, pitch)) : 60
        return 0.1 + 0.8 * (n - 21) / 87
    }

    /// What a note releases, by its register: a jelly below C3, a comb jelly from C3, a speck from C5.
    public static func kind(for note: UInt8) -> CreatureKind {
        if note < bassSplit { return .jelly }
        return note < trebleSplit ? .combJelly : .speck
    }

    /// Where an accent's bubbles rise across the glass: its key's centre, mapped to 0.08…0.92.
    public static func streamX(for note: UInt8) -> Float { 0.08 + 0.84 * centres[Int(min(108, max(21, note))) - 21] }

    /// A siphonophore's colour for its chord (linear RGB).
    public static func colour(_ quality: ChordQuality) -> SIMD3<Float> {
        switch quality {
        case .major: return SIMD3<Float>(0.45, 0.95, 0.8)
        case .minor: return SIMD3<Float>(0.32, 0.22, 1.0)
        case .tense: return SIMD3<Float>(0.8, 0.06, 0.05)
        case .open, .none: return livingLight
        }
    }

    // MARK: - The instrument's pulse

    /// The arp's sixteenth (seconds): 60 / bpm / 4, the tempo held to Blue Depth's 70…160 (127.1 ms at 118).
    public static func stepLength(_ p: InstrumentPulse) -> Double {
        let bpm: Double = p.bpm.isFinite ? min(160, max(70, p.bpm)) : 118
        return 60 / bpm / 4
    }

    /// How much of a step its note sounds: Blue Depth's gate, 70% of a step at Blink 0 … 25% at 1.
    static func gateFraction(_ p: InstrumentPulse) -> Double {
        let g: Double = p.gate.isFinite ? min(1, max(0, p.gate)) : 0.6
        return 0.7 - 0.45 * g
    }

    /// The blink's low between steps, as a share of the peak: 0.6 at Blink 0 … 0.25 at 1 (harder as Blink rises).
    static func blinkLow(_ p: InstrumentPulse) -> Float {
        let g: Float = p.gate.isFinite ? Float(min(1, max(0, p.gate))) : 0.6
        return 0.6 - 0.35 * g
    }

    /// The blink `since` seconds after a step: 1 on the step, falling (τ half the gate) toward the low.
    static func blink(since: Double, _ p: InstrumentPulse) -> Float {
        let tau = 0.5 * gateFraction(p) * stepLength(p)
        let e = Float(exp(-max(0, since) / tau))
        let low = blinkLow(p)
        return low + (1 - low) * e
    }

    /// A creature's swim pulse at a point in its stroke (0…1): 1 at the stroke's start, easing to `swimFloor` half way.
    static func swim(_ phase: Float) -> Float {
        let c: Float = cos(2 * .pi * phase)
        return swimFloor + (1 - swimFloor) * (0.5 + 0.5 * c)
    }

    // MARK: - Events

    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double) {
        let v = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        let at = t.isFinite ? t : time
        held.insert(note)
        sustained.remove(note)
        queue.append((note, v, at))
        if queue.count > Self.queueCap { queue.removeFirst(queue.count - Self.queueCap) }
        if note >= Self.bassSplit { joinArp(at: at) }
        // A chord: three or more notes within 60 ms (once per chord) sends a siphonophore, coloured by what's sounding;
        // a note joining the chord within 60 ms of that grows its chain and recolours it by the whole chord.
        chordNotes.append((at, note, v))
        while let first = chordNotes.first, at - first.t > Self.chordWindow { chordNotes.removeFirst() }
        if chordNotes.count > Self.queueCap { chordNotes.removeFirst(chordNotes.count - Self.queueCap) }   // bounded, whatever the clock
        if chordNotes.count >= 3, at - lastChord > Self.chordWindow {
            lastChord = at
            sendSiphonophore()
        } else if at >= lastChord, at - lastChord <= Self.chordWindow {
            joinChord(note, velocity: v)
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

    /// Lets every note go (a panic, an unplugged keyboard, a change of visual): no creature stays lit, no queued note
    /// releases one, the next note starts a new run, and the arp's grid stops (the next note starts a fresh one).
    public mutating func allNotesOff() {
        held.removeAll()
        sustained.removeAll()
        queue.removeAll()
        lastNote = nil
        pendingShoal.removeAll()
        runShoal = nil
        chordNotes.removeAll()
        chord = nil
        grid = nil
        quietSince = nil
    }

    /// A note from C3 up joins the arp: when no grid is running (or nothing has sounded for `phraseGap`), a phrase
    /// begins and the grid starts on this note, as the arp's clock does.
    private mutating func joinArp(at t: Double) {
        if let q = quietSince, t - q >= Self.phraseGap { grid = nil }
        quietSince = nil
        if grid == nil, let p = pulse { grid = (t, t + Self.stepLength(p)) }
    }

    // MARK: - Step

    public mutating func step(dt: Double, roles: RoleValues) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        time += step
        burst = nil
        lastSpawns = 0
        let reaction: Float = reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1
        let linger: Double = Double(lingerScale.isFinite ? min(max(lingerScale, 0.2), 3) : 1)
        let sounding = held.union(sustained)
        advanceGrid(arpSounding: sounding.contains { $0 >= Self.bassSplit })
        let beat = blinkNow()

        // Shoals cross and go, siphonophores swell and fade behind, bubble streams rise.
        ageShoals(fdt)
        stepSiphonophores(step, sounding: sounding, linger: linger)
        for i in bubbleStreams.indices { bubbleStreams[i].age += fdt }
        bubbleStreams.removeAll { $0.age >= Self.streamLife }

        // The creatures: held ones stay lit (blinking with the pulse, or swimming), let go they fade; all drift.
        let tau = Self.fadeTau * linger * (roles[.linger] > 0.5 ? 2 : 1)
        let fade = Float(exp(-step / tau))
        let glide = Float(1 - exp(-step / Self.blinkGlide))
        for i in creatures.indices {
            var c = creatures[i]
            c.age += fdt
            c.held = sounding.contains(c.note) && currentCreature[c.note] == c.id
            if c.held { c.level = 1 } else { c.level *= fade }
            let wants: Float = c.held && c.kind != .jelly && beat != nil ? 1 : 0
            c.blinking += (wants - c.blinking) * glide
            c.position.x += c.drift * fdt
            if c.held, c.position.x > Self.outOfView { c.position.x -= Self.wrapWidth }
            creatures[i] = Self.lit(c, beat: beat)
        }
        creatures.removeAll { (!$0.held && $0.peak * $0.level < 0.01) || $0.position.x > Self.outOfView }

        // New creatures, at most 10 a step; a full window lets its dimmest creature go first.
        let batch = min(queue.count, Self.maxSpawnsPerStep)
        for k in 0..<batch {
            let q = queue[k]
            release(q.note, velocity: q.velocity, at: q.t, sounding: sounding, beat: beat, reaction: reaction)
        }
        queue.removeFirst(batch)

        // Time held: what this step sent blooms at once (a running step's sit at age 0, as they set off).
        if step == 0 {
            for i in shoals.indices where shoals[i].age == 0 {
                shoals[i].age = Self.shoalBloomAge
                shoals[i].brightness = Self.shoalBrightness(shoals[i])
            }
            for i in bubbleStreams.indices where bubbleStreams[i].age == 0 { bubbleStreams[i].age = Self.streamBloomAge }
        }
    }

    /// The arp's grid this step: it stops without a pulse or after `phraseGap` with nothing from C3 up sounding; starts
    /// here if the pulse came up over held notes; and steps on past every sixteenth it has reached (each step as long as
    /// the tempo says as it begins).
    private mutating func advanceGrid(arpSounding: Bool) {
        guard let p = pulse else { grid = nil; return }
        if arpSounding {
            quietSince = nil
        } else if quietSince == nil {
            quietSince = time
        }
        if let q = quietSince, time - q >= Self.phraseGap { grid = nil }
        if grid == nil, arpSounding { grid = (time, time + Self.stepLength(p)) }
        guard var g = grid else { return }
        var n = 0
        while g.next <= time + 1e-9, n < 16 {
            g.last = g.next
            g.next += Self.stepLength(p)
            n += 1
        }
        if g.next <= time { g = (time, time + Self.stepLength(p)) }   // never spins: start again here
        grid = g
    }

    /// The blink now, while the grid runs (nil without it: the creatures swim).
    private func blinkNow() -> Float? {
        guard let p = pulse, let g = grid else { return nil }
        return Self.blink(since: time - g.last, p)
    }

    /// A creature's glow now: its peak × its pulse (the blink and its swim, by how far it is blinking) × its level.
    private static func lit(_ creature: DeepCreature, beat: Float?) -> DeepCreature {
        var c = creature
        var phase = (c.swimRate * c.age).truncatingRemainder(dividingBy: 1)
        if !phase.isFinite || phase < 0 { phase = 0 }
        c.swimPhase = phase
        let swim = Self.swim(phase)
        let pulse = c.blinking * (beat ?? swim) + (1 - c.blinking) * swim
        let g = c.peak * pulse * c.level
        c.glow = g.isFinite ? min(1, max(0, g)) : 0
        return c
    }

    /// A note releases its creature (and, as it does, carries a run on and raises an accent's bubbles).
    private mutating func release(_ note: UInt8, velocity v: Float, at t: Double, sounding: Set<UInt8>, beat: Float?,
                                  reaction: Float) {
        if creatures.count >= Self.cap,
           let dimmest = creatures.indices.min(by: { Self.score(creatures[$0]) < Self.score(creatures[$1]) }) {
            creatures.remove(at: dimmest)
        }
        let kind = Self.kind(for: note)
        let x = rng.range(Self.spawnX.lowerBound, Self.spawnX.upperBound)
        let drift: Float, rate: Float
        switch kind {
        case .jelly:
            drift = rng.range(0.01, 0.018)
            rate = rng.range(0.3, 0.45)
        case .combJelly:
            drift = rng.range(0.015, 0.03)
            rate = rng.range(0.45, 0.7)
        case .speck:
            drift = rng.range(0.025, 0.04)
            rate = rng.range(0.7, 1)
        }
        let isHeld = sounding.contains(note)
        let blinks: Float = isHeld && kind != .jelly && beat != nil ? 1 : 0
        let peak = min(1, (0.35 + 0.65 * v) * reaction)
        let c = DeepCreature(id: nextID, note: note, kind: kind, position: SIMD2<Float>(x, Self.height(for: note)),
                             size: 0.35 + 0.65 * v, peak: peak, glow: 0, held: isHeld, age: 0, swimRate: rate, swimPhase: 0,
                             blinking: blinks, drift: drift, level: 1)
        creatures.append(Self.lit(c, beat: beat))
        currentCreature[note] = nextID
        nextID = nextID &+ 1
        lastSpawns += 1
        carryRun(note, velocity: v, at: t, reaction: reaction)
        if v >= Self.accent { sendBubbles(note, velocity: v) }
    }

    static func score(_ c: DeepCreature) -> Float { c.held ? 2 + c.glow : c.glow }

    /// The `limit` creatures worth drawing when the budget is smaller than the cap: the held and brightest, in their
    /// original order.
    public static func visible(_ c: [DeepCreature], limit: Int) -> [DeepCreature] {
        guard c.count > limit else { return c }
        let keep = Set(c.indices.sorted { score(c[$0]) > score(c[$1]) }.prefix(max(0, limit)))
        return c.indices.filter { keep.contains($0) }.map { c[$0] }
    }

    // MARK: - Runs: the lanternfish

    /// A run (notes within 0.2 s of each other, not struck together) sends a lanternfish shoal along its contour once it
    /// has three notes; its later notes join the shoal's tail while the shoal is young and not full, and after that the
    /// next three set another off. Notes struck together neither carry the run on nor break it; after a pause (or out of
    /// order) a new run begins.
    private mutating func carryRun(_ note: UInt8, velocity v: Float, at t: Double, reaction: Float) {
        let gap = lastNote.map { t - $0 } ?? .infinity
        lastNote = t
        let h = Self.height(for: note)
        if gap >= Self.minRunGap && gap <= Self.runWindow {
            if let id = runShoal, let j = shoals.firstIndex(where: { $0.id == id }),
               shoals[j].age < Self.shoalJoin, shoals[j].contour.count < Self.shoalLights {
                shoals[j].contour.append(h)
                shoals[j].strength = max(shoals[j].strength, min(1, (0.5 + 0.5 * v) * reaction))
                return
            }
            runShoal = nil
            pendingShoal.append((h, v))
            if pendingShoal.count >= 3 { sendShoal(reaction: reaction) }
        } else if !(gap >= 0 && gap < Self.minRunGap) {
            pendingShoal = [(h, v)]
            runShoal = nil
        }
    }

    private mutating func sendShoal(reaction: Float) {
        guard let first = pendingShoal.first, let last = pendingShoal.last else { return }
        let meanV = pendingShoal.map(\.velocity).reduce(0, +) / Float(pendingShoal.count)
        if shoals.count >= Self.shoalCap { shoals.removeFirst(shoals.count - Self.shoalCap + 1) }
        shoals.append(LanternShoal(id: nextShoalID, contour: pendingShoal.map(\.height),
                                   direction: last.height >= first.height ? 1 : -1,
                                   strength: min(1, (0.5 + 0.5 * meanV) * reaction), age: 0, brightness: 0))
        runShoal = nextShoalID
        nextShoalID = nextShoalID &+ 1
        pendingShoal.removeAll(keepingCapacity: true)
    }

    /// How far across a shoal's tail must come before it has gone.
    private static func shoalEnd(_ s: LanternShoal) -> Float { 1 + Float(max(s.contour.count - 1, 0)) * shoalSpacing }

    private mutating func ageShoals(_ dt: Float) {
        for i in shoals.indices {
            shoals[i].age += dt
            shoals[i].brightness = Self.shoalBrightness(shoals[i])
        }
        shoals.removeAll { $0.progress >= Self.shoalEnd($0) }
    }

    /// A shoal's brightness at its age: its strength, coming in over its first tenth of the crossing and going out as its
    /// tail leaves.
    private static func shoalBrightness(_ s: LanternShoal) -> Float {
        let p = s.progress, end = shoalEnd(s)
        let entering = smoothstep(0, 0.1, p)
        let leaving = 1 - smoothstep(end - 0.2, end, p)
        return min(1, max(0, s.strength * entering * leaving))
    }

    // MARK: - Chords: the siphonophore

    private mutating func sendSiphonophore() {
        let tally = (id: nextSiphonophoreID, count: chordNotes.count, velocity: chordNotes.map(\.v).reduce(0, +),
                     pitch: Float(chordNotes.map { Int($0.note) }.reduce(0, +)))
        chord = tally
        if siphonophores.count >= Self.siphonophoreCap {
            siphonophores.removeFirst(siphonophores.count - Self.siphonophoreCap + 1)
        }
        let quality = PlayingAnalyzer.classify(held.union(sustained))
        let r = reaction
        var s = Siphonophore(id: tally.id, quality: quality, colour: Self.livingLight, flecks: 0, bells: 12,
                             position: SIMD2<Float>(rng.range(0.15, 0.45), 0.5), age: 0, strength: 0, brightness: 0,
                             pulseRate: 0.2, notes: Set(chordNotes.map(\.note)), level: 0)
        Self.shape(&s, tally: tally, quality: quality, reaction: r)
        siphonophores.append(s)
        nextSiphonophoreID = nextSiphonophoreID &+ 1
    }

    /// A note joining the latest chord within 60 ms: its siphonophore's chain grows, and takes the whole chord's colour.
    private mutating func joinChord(_ note: UInt8, velocity v: Float) {
        guard var tally = chord, let j = siphonophores.firstIndex(where: { $0.id == tally.id }) else { return }
        guard !siphonophores[j].notes.contains(note) else { return }
        tally.count += 1
        tally.velocity += v
        tally.pitch += Float(note)
        chord = tally
        let quality = PlayingAnalyzer.classify(held.union(sustained))
        let r = reaction
        var s = siphonophores[j]
        s.notes.insert(note)
        Self.shape(&s, tally: tally, quality: quality, reaction: r)
        siphonophores[j] = s
    }

    private var reaction: Float { reactionScale.isFinite ? min(max(reactionScale, 0), 2) : 1 }

    /// A siphonophore as its chord makes it: coloured by the chord's quality, as high as its mean pitch, 12…20 bells (more
    /// for a bigger, harder chord), as strong as its velocity.
    private static func shape(_ s: inout Siphonophore, tally: (id: Int, count: Int, velocity: Float, pitch: Float),
                              quality: ChordQuality, reaction: Float) {
        let n = Float(max(1, tally.count))
        let meanV = tally.velocity / n
        let bigger: Float = min(1, max(0, (n - 3) / 3))
        let bells = 12 + Int((8 * min(1, 0.5 * meanV + 0.5 * bigger)).rounded())
        s.quality = quality
        s.colour = colour(quality)
        s.flecks = quality == .major ? 1 : 0
        s.pulseRate = quality == .tense ? 0.1 : 0.2
        s.bells = max(s.bells, bells)
        s.position.y = height(pitch: tally.pitch / n)
        s.strength = max(s.strength, min(1, (0.55 + 0.45 * meanV) * reaction))
    }

    /// Siphonophores drift across behind, swelling in while their chord sounds (for at least a second, however short the
    /// chord) and fading after; they go once faded, or once the whole chain has drifted out of view.
    private mutating func stepSiphonophores(_ step: Double, sounding: Set<UInt8>, linger: Double) {
        let fdt = Float(step)
        let swell = Float(1 - exp(-step / Self.swellTau))
        let fade = Float(exp(-step / (Self.fadeTau * linger)))
        for i in siphonophores.indices {
            var s = siphonophores[i]
            s.age += fdt
            s.position.x += Self.siphonophoreDrift * fdt
            if step == 0, s.age == 0 {
                s.level = 1   // time held: a chord since the last step swells in at once
            } else if s.age < Self.chordSwell || !s.notes.isDisjoint(with: sounding) {
                s.level += (1 - s.level) * swell
            } else {
                s.level *= fade
            }
            let wave: Float = 0.8 + 0.2 * cos(2 * .pi * s.pulseRate * s.age)
            s.brightness = min(1, max(0, s.strength * s.level * wave))
            siphonophores[i] = s
        }
        siphonophores.removeAll { s in
            let tail = s.position.x - Float(s.bells) * Self.bellSpacing
            let spent = s.age >= Self.chordSwell && s.level < 0.01 && s.notes.isDisjoint(with: sounding)
            return spent || tail > 1.05
        }
    }

    // MARK: - Accents: the bubbles

    private mutating func sendBubbles(_ note: UInt8, velocity v: Float) {
        let strength = min(1, max(0, 0.6 + 0.4 * (v - Self.accent) / (1 - Self.accent)))
        if bubbleStreams.count >= Self.streamCap { bubbleStreams.removeFirst(bubbleStreams.count - Self.streamCap + 1) }
        bubbleStreams.append(BubbleStream(id: nextStreamID, x: Self.streamX(for: note), strength: strength, age: 0,
                                          seed: UInt32(truncatingIfNeeded: rng.next())))
        nextStreamID = nextStreamID &+ 1
        burst = max(burst ?? 0, Double(strength))
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
