import Foundation
import simd

// Volcano Rim (Fire & Neon spec §8): Set 13's world. You stand on the rim of a broad crater at night. Below, a lava
// lake: black crust plates drifting on slow convection, broken by incandescent cracks, two spattering fountains, a bright
// margin where the lake meets the floor, and a lava river running out through a breach in the far wall. Across the
// crater the far wall stands lit orange from below; over the lake an ash-and-gas plume climbs and bends with the wind,
// lit from beneath by the lake and flickering with volcanic lightning; beyond, a dark plain with far storms, and the
// stars. Everything you play lands on the lake: each note brightens the crack cell where its key falls across it (low
// left, high right), notes below C3 spit lava blobs, chords speed the convection, Energy drives the fountains, the river,
// the embers and the plume's lightning; tension swells the lake and beats its cracks; a big moment is an Eruption and
// the drop is the Breach. Everything here is control-rate Core state in fixed pools (64 crack cells, 24 blobs, 16
// bombs, 400 embers, 4 plume strokes); the renderer draws it.

public extension Mood {
    /// Volcano Rim: molten (Fire & Neon spec §10), the most energetic and the warmest mood in the app.
    static let molten = Mood(energy: 0.85, warmth: 0.95, brightness: 0.4, space: 0.75, motion: 0.65)
}

/// The crater, in metres. The frame: x across the view (right positive), y ahead (away from the camera), z up; the
/// origin at the lake's centre on its surface. The camera stands on the near rim and looks along +y. Core places the
/// cells, blobs, bombs, embers and strokes in it; the renderer draws the same shape.
public enum VolcanoCrater {
    /// The lava lake: a disc on the crater floor.
    public static let lakeRadius: Float = 230
    /// The camera: this far back from the lake's centre, standing this high over the lake on the near rim.
    public static let cameraBack: Float = 480
    public static let rimHeight: Float = 170
    public static let eyeHeight: Float = 1.7
    public static var eye: SIMD3<Float> { SIMD3(0, -cameraBack, rimHeight + eyeHeight) }
    /// The walls are circles round this point (the lake's centre is ahead of it), so the camera stands at the near
    /// rim's edge and the far wall stands beyond the lake: the floor's edge (the cliff's foot), a bench, the rim's lip.
    public static let wallCentre = SIMD2<Float>(0, -100)
    public static let footRadius: Float = 410
    public static let benchHeight: Float = 80
    public static let benchRadius: Float = 440
    public static let topRadius: Float = 470
    /// The breach: a notch in the far wall, its middle this far round from straight ahead (radians, right positive,
    /// measured at the wall centre) and this wide each side.
    public static let breachAngle: Float = 0.85
    public static let breachHalfWidth: Float = 0.075
    /// The two spattering fountains on the lake.
    public static let fountainSites: [SIMD2<Float>] = [SIMD2(-78, 46), SIMD2(96, -38)]
    /// Where the lake's crust wells up (the spreading centre the plates drift away from).
    public static let upwelling = SIMD2<Float>(-40, 30)

    /// A point on the wall circle at an angle round the wall centre (radians, 0 straight ahead, right positive).
    public static func wallPoint(angle: Float, radius: Float) -> SIMD2<Float> {
        wallCentre + SIMD2(sin(angle), cos(angle)) * radius
    }

    /// The lava river: from the lake's margin toward the breach, across the floor to the wall's foot in the notch.
    public static var riverStart: SIMD2<Float> {
        let foot = wallPoint(angle: breachAngle, radius: footRadius)
        return simd_normalize(foot) * lakeRadius
    }
    public static var riverEnd: SIMD2<Float> { wallPoint(angle: breachAngle, radius: footRadius + 12) }

    /// Where a note lands on the lake: across it by its key (low left, high right), a little ahead or back by its pitch
    /// class, so a repeated note lands in the same place.
    public static func lakePoint(for note: UInt8) -> SIMD2<Float> {
        let key = KeyboardLayout.key(for: note)
        let raw: Float = key.map { $0.x + 0.5 * $0.width } ?? (note < KeyboardLayout.lowestNote ? 0 : 1)
        let across = min(1, max(0, raw))
        let x = (across - 0.5) * 2 * lakeRadius * 0.86
        let half = (lakeRadius * lakeRadius - x * x).squareRoot()
        let pc = Float((Int(note) * 7) % 12) / 11
        let y = (pc - 0.5) * 1.1 * half
        return SIMD2(x, y)
    }

    /// The far rim's lip at an angle round the wall centre (a bomb's landing place).
    public static func rimPoint(angle: Float) -> SIMD3<Float> {
        let p = wallPoint(angle: angle, radius: topRadius + 14)
        return SIMD3(p.x, p.y, rimHeight)
    }
}

/// One of the lake's 64 crust plates: its seed point (the cracks run between the seeds), the light a note left in its
/// cracks, how young (hot) its crust is, and how far it has opened since it split off another plate.
public struct CrackCell: Equatable {
    /// The seed (lake metres).
    public var position: SIMD2<Float>
    /// A note's light in the cracks round it, 0…1, fading.
    public var glow: Float
    /// Young crust is hot (1, just split off at the spreading centre) and cools to old (0) over a few minutes.
    public var heat: Float
    /// 0 just split from its parent … 1 a plate of its own: its new crack opens as it drifts away.
    public var birth: Float
    /// The push apart after a split (m/s), easing off.
    public var drift: SIMD2<Float>
    /// The plate it split from (an index into the cells; −1 for none): their shared crack opens with `birth`.
    public var twin: Int
}

/// A lava blob (a low note's spit) or a bomb (an eruption's): incandescent, ballistic, cooling as it flies.
public struct LavaParticle: Equatable {
    public var alive: Bool
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: Float
    /// Its size (metres) and its skin's temperature (kelvin).
    public var size: Float
    public var temperature: Float
    /// Seconds since it came down (its splash or its sparks on the rim), nil while it flies.
    public var landed: Float?

    public static let dead = LavaParticle(alive: false, position: .zero, velocity: .zero, age: 0, size: 0, temperature: 0,
                                          landed: nil)
}

/// An ember (or a spark): a fleck of glowing spatter carried up on the heat, drifting with the wind and cooling.
public struct Ember: Equatable {
    public var alive: Bool
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: Float
    public var life: Float
    /// Its size (metres) and temperature (kelvin) when it set out; it cools over its life.
    public var size: Float
    public var temperature: Float
    /// Near embers drift up past the view from the rim's own vents (larger, closer); the rest rise off the lake.
    public var near: Bool

    public static let dead = Ember(alive: false, position: .zero, velocity: .zero, age: 0, life: 1, size: 0, temperature: 0,
                                   near: false)

    /// Its temperature now: cooling from its start toward 650 K over its life.
    public var temperatureNow: Float {
        let x = min(1, max(0, age / max(life, 1e-3)))
        return temperature + (650 - temperature) * x
    }
    /// Its light now, 0…1: in over 0.15 s, out over the last 30% of its life.
    public var brightness: Float {
        guard alive else { return 0 }
        let rise = min(1, max(0, age / 0.15))
        let x = min(1, max(0, (age / max(life, 1e-3) - 0.7) / 0.3))
        return rise * (1 - x)
    }
}

/// A lightning stroke inside the plume (volcanic lightning): short, branching, flickering.
public struct PlumeStroke: Equatable {
    public var alive: Bool
    public var seed: UInt64
    public var age: Float
    public var strength: Float
    /// Where it starts (metres, in the plume) and how long it reaches.
    public var origin: SIMD3<Float>
    public var length: Float

    public static let life: Float = 0.45
    public static let dead = PlumeStroke(alive: false, seed: 0, age: 0, strength: 0, origin: .zero, length: 0)

    /// Its light now, 0…1 (before any flash limiter): two or three return strokes, then the channel's glow dying.
    public var brightness: Float {
        guard alive, age >= 0, age < Self.life else { return 0 }
        var light: Float = 0
        let times: [Float] = [0, 0.06, 0.15]
        let count = 2 + Int(seed % 2)
        for k in 0..<count {
            let since = age - times[k]
            let peak: Float = k == 0 ? 1 : 0.7
            if since >= 0 { light = max(light, peak * exp(-since / 0.035)) }
        }
        let glow: Float = 0.3 * exp(-age / 0.15) * (1 - age / Self.life)
        return min(1, max(light, glow) * (0.5 + 0.5 * strength))
    }

    /// Its channel (metres): a jagged path of 10 steps from its origin, with two short branches; seeded, so it keeps its
    /// shape while it is seen. Each segment is (from, to, branch).
    public func segments() -> [(SIMD3<Float>, SIMD3<Float>, Bool)] {
        var rng = SeededRandom(seed: seed)
        let heading = rng.range(-1.3, 1.3)
        let dip = rng.range(-0.9, 0.5)
        let dir = SIMD3<Float>(cos(heading) * cos(dip), 0.25 * sin(heading), sin(dip))
        var points: [SIMD3<Float>] = [origin]
        var p = origin
        let step = length / 10
        for _ in 0..<10 {
            let jag = SIMD3<Float>(rng.range(-0.6, 0.6), rng.range(-0.2, 0.2), rng.range(-0.6, 0.6))
            p += (dir + jag) * step
            points.append(p)
        }
        var out: [(SIMD3<Float>, SIMD3<Float>, Bool)] = []
        for i in 0..<10 { out.append((points[i], points[i + 1], false)) }
        for k in 0..<2 {
            var q = points[2 + k * 3 + Int(seed % 2)]
            let side: Float = rng.unit() < 0.5 ? -1 : 1
            for _ in 0..<3 {
                let n = q + SIMD3<Float>(side * rng.range(0.3, 0.8), rng.range(-0.2, 0.2), rng.range(-0.9, -0.2)) * step
                out.append((q, n, true))
                q = n
            }
        }
        return out
    }
}

/// The signature moment (spec §8.1): a fountain column rising out of the lake to 3–6 lake-widths in 0.8 s, bombs arcing
/// out to the far rim, the plume billowing, a lightning cluster, the ground shaking.
public struct Eruption: Equatable {
    public var age: Float
    public var strength: Float

    public static let rise: Float = 0.8
    public static let hold: Float = 2.2
    public static let fall: Float = 3.0
    public static var life: Float { rise + hold + fall }

    /// The column's top at its height (metres): 3 lake-widths at the weakest, 6 at the strongest.
    public static func peak(strength: Float) -> Float {
        let s = min(1, max(0.3, strength.isFinite ? strength : 0.3))
        let widths: Float = 3 + 3 * (s - 0.3) / 0.7
        return widths * 2 * VolcanoCrater.lakeRadius
    }

    /// The column's top now (metres): up in 0.8 s, holding, then collapsing.
    public var height: Float {
        let top = Self.peak(strength: strength)
        if age < Self.rise {
            let x = max(0, age / Self.rise)
            return top * (1 - (1 - x) * (1 - x) * (1 - x))
        }
        if age < Self.rise + Self.hold { return top }
        let x = min(1, (age - Self.rise - Self.hold) / Self.fall)
        return top * (1 - x * x)
    }

    /// Its light on the crater, 0…1 (before the flash limiter).
    public var light: Float {
        guard age < Self.life else { return 0 }
        let rise = min(1, max(0, age / 0.25))
        let fade = 1 - min(1, max(0, (age - Self.rise - Self.hold) / Self.fall))
        return min(1, (0.55 + 0.45 * strength) * rise * fade)
    }

    /// How many bombs it throws (4 at the weakest, 16 at the strongest).
    public static func bombs(strength: Float) -> Int {
        let s = min(1, max(0.3, strength.isFinite ? strength : 0.3))
        return min(16, 4 + Int(((s - 0.3) / 0.7 * 12).rounded()))
    }
}

/// One of the lake's two spattering fountains: where, and how high its spatter throws now (metres).
public struct LavaFountain: Equatable {
    public var position: SIMD2<Float>
    public var height: Float
    /// How hard it is bursting now, 0…1 (it spatters in bursts).
    public var burst: Float
}

/// A surprise playing now (spec §8.1): a fireball, a rockfall down the inner wall, a steam blast from a vent, red
/// sprites over the far storm on the plain, a lava tree left standing as the river drops.
public struct VolcanoSurprise: Equatable {
    public enum Kind: Int, CaseIterable { case fireball, rockfall, steamBlast, redSprites, lavaTree }
    public var kind: Kind
    public var age: Float
    public var duration: Float
    public var seed: UInt64
    /// Where (radians round the wall centre for the rockfall and the steam; the bearing from the view for the
    /// fireball and the sprites, degrees).
    public var angle: Float

    public static func duration(_ k: Kind) -> Float {
        switch k {
        case .fireball: return 1.8
        case .rockfall: return 7
        case .steamBlast: return 6
        case .redSprites: return 1.4
        case .lavaTree: return 40
        }
    }
    /// 0…1 through it.
    public var progress: Float { min(1, max(0, age / max(duration, 1e-3))) }
}

/// Everything the Volcano Rim renderer needs for a frame (spec §8).
public struct VolcanoFrame: AmbienceProviding {
    /// The Living Sky over the crater (warm: no snow, frost or rime; no fireflies).
    public var sky: SkyState
    /// Which way the camera looks (degrees from north).
    public var viewAzimuth: Double
    /// The lake's 64 crust plates.
    public var cells: [CrackCell]
    /// The pools, always full length (dead slots have `alive` false): 24 blobs, 16 bombs, 400 embers, 4 strokes.
    public var blobs: [LavaParticle]
    public var bombs: [LavaParticle]
    public var embers: [Ember]
    public var strokes: [PlumeStroke]
    public var fountains: [LavaFountain]
    /// The eruption playing, if any.
    public var eruption: Eruption?
    /// The breach's new river (after a drop): 1 pouring, crusting over to 0; and seconds since it opened.
    public var breach: Float
    public var breachAge: Float?
    /// The river's flow (0…1, with Energy) and how far its crust has moved (metres, for its texture).
    public var river: Float
    public var riverFlow: Float
    /// The convection's speed at the margin (m/s) and the crust's own clock (s, scaled by it).
    public var convection: Float
    /// Tension: the lake swells (0…1) and its cracks beat (the beat's light now, 0…1).
    public var swell: Float
    public var beat: Float
    /// The plume: how hard it is billowing (an eruption's push, 0…1) and the wind bending it (m/s, x across, y ahead).
    public var billow: Float
    public var wind: SIMD2<Float>
    /// The camera's shake now (degrees; ≤ 0.15, none under Reduce Motion).
    public var cameraShake: SIMD2<Float>
    public var surprises: [VolcanoSurprise]
    /// The light the scene asks for this step (lightning, the eruption, a fireball), 0…1, before any flash limiter.
    public var flashRequest: Float
    /// Excitement as the world draws it.
    public var energy: Float
    public var tension: Float
    public var drop: Float
    public var reduceMotion: Bool
    /// The keys: a row of basalt columns along the near rim, each lit from inside by its note.
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the crater, when it's the chosen visual (notes then streak instead of lighting the lake).
    public var warp: WarpFrame?
    /// Magma Veins, when it's the chosen visual: the full-frame view down into the lake.
    public var veins: VeinsFrame?
}

/// Set 13's world (spec §8).
public struct VolcanoRimModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, PulseAware, SurpriseListing {
    public typealias Frame = VolcanoFrame
    public static let id = "volcano-rim"
    public static let displayName = "Volcano Rim"
    /// The lake's own reactions; Magma Veins (the second visual, a full-frame view down into the lake); Galaxy Warp.
    public static let visuals = ["Lava Lake", "Magma Veins", "Galaxy Warp"]
    /// A fireball, a rockfall, a steam blast, red sprites over the plain, a lava tree (spec §8.1).
    public static let surpriseCount = VolcanoSurprise.Kind.allCases.count

    /// The fixed pools (plan Task 11).
    public static let cellCount = 64
    public static let blobCount = 24
    public static let bombCount = 16
    public static let emberCount = 400
    public static let strokeCount = 4
    /// Gravity (m/s²).
    public static let gravity: Float = 9.81
    /// The plume's lightning (spec §8.1): 0.05 strokes a second at rest, 0.6 at full Energy.
    public static func lightningRate(energy: Float) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        return 0.05 + 0.55 * e
    }
    /// The fountains' height (metres) at an Energy: 5 m at rest, 45 m at full.
    public static func fountainHeight(energy: Float) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        return 5 + 40 * e
    }
    /// The river's flow (0…1) at an Energy.
    public static func riverFlow(energy: Float) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        return 0.2 + 0.8 * e
    }
    /// Embers set out per second at an Energy.
    public static func emberRate(energy: Float) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        return 18 + 110 * e
    }
    /// The camera's shake at an eruption (degrees) and how long it lasts (s).
    public static let shakeDegrees: Float = 0.15
    public static let shakeSeconds: Float = 1.4
    /// How long the breach's river pours before it has crusted over.
    public static let breachSeconds: Float = 45
    /// Notes below this spit lava (C3).
    public static let spitBelow: UInt8 = 48

    public var mood = Mood.neutral
    public var pulse: InstrumentPulse?

    private var rawSky = SkyState()
    private var excite = ExcitementFrame()
    private var warp = GalaxyWarp()
    private var veins = MagmaVeins()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var rng = SeededRandom(seed: 0x70_1CA_9013)

    private(set) var cells: [CrackCell]
    private(set) var blobs = [LavaParticle](repeating: .dead, count: VolcanoRimModel.blobCount)
    private(set) var bombs = [LavaParticle](repeating: .dead, count: VolcanoRimModel.bombCount)
    private(set) var embers = [Ember](repeating: .dead, count: VolcanoRimModel.emberCount)
    private(set) var strokes = [PlumeStroke](repeating: .dead, count: VolcanoRimModel.strokeCount)
    private var nextBlob = 0, nextBomb = 0, nextEmber = 0, nextStroke = 0
    private var emberDebt: Float = 0
    private var strokeClock: Float = 0
    private var cluster: [Float] = []
    private var eruption: Eruption?
    private var breach: Float = 0
    private var breachAge: Float?
    private var riverFlow: Float = 0
    private var crustClock: Float = 0
    private var beatPhase = 0.0
    private var billow: Float = 0
    private var shakeAge: Float = 99
    private var shakePhase: Float = 0
    private var surprises: [VolcanoSurprise] = []
    private var fountainPhase: [Float] = [0.3, 1.7]
    private var thunder: [QueuedThunder] = []
    private var riverDistance: Float = 0

    private static let layout = KeyboardLayout.keys()

    public init() {
        var r = SeededRandom(seed: 0xC0_FFEE_1A7A)
        var list: [CrackCell] = []
        list.reserveCapacity(Self.cellCount)
        // Seeds over the lake and a little beyond its margin, jittered on a sunflower so the plates are even but never
        // regular; the youngest near the spreading centre.
        let golden: Float = 2.399963
        for i in 0..<Self.cellCount {
            let f = (Float(i) + 0.5) / Float(Self.cellCount)
            let radius = VolcanoCrater.lakeRadius * 1.18 * f.squareRoot()
            let a = Float(i) * golden
            let jitter = SIMD2<Float>(r.range(-14, 14), r.range(-14, 14))
            let p = SIMD2<Float>(cos(a), sin(a)) * radius + jitter
            let fromUp = simd_length(p - VolcanoCrater.upwelling) / VolcanoCrater.lakeRadius
            list.append(CrackCell(position: p, glow: 0, heat: max(0, 1 - fromUp), birth: 1, drift: .zero, twin: -1))
        }
        cells = list
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// It's warm at the rim (snow and sleet fall as rain; no frost, rime or sea smoke), and no fireflies.
    public mutating func setSky(_ s: SkyState) {
        var warm = WorldWeather.warm(s)
        warm.fireflies = 0
        rawSky = warm
    }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    // MARK: - The laws

    /// The cell whose seed lies nearest a lake point.
    public static func nearestCell(_ p: SIMD2<Float>, in cells: [CrackCell]) -> Int {
        var best = 0
        var bestD = Float.greatestFiniteMagnitude
        for (i, c) in cells.enumerated() {
            let d = simd_length_squared(c.position - p)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// The convection's speed at the margin (m/s): slow at rest, faster with Energy and with the chord you hold.
    public static func convection(energy: Float, held: Int, activity: Float) -> Float {
        let e = energy.isFinite ? min(1, max(0, energy)) : 0
        let chord = Float(min(max(held - 1, 0), 7)) / 7
        let a = activity.isFinite ? min(1, max(0, activity)) : 0.5
        return (0.35 + 0.5 * a) * (1 + 1.4 * e) * (1 + 0.8 * chord)
    }

    /// The drift of the crust at a lake point (m/s) for a convection speed: out from the spreading centre, turning
    /// slowly round the lake.
    public static func flow(at p: SIMD2<Float>, speed: Float) -> SIMD2<Float> {
        let off = p - VolcanoCrater.upwelling
        let out = off / VolcanoCrater.lakeRadius
        let swirl = SIMD2<Float>(-p.y, p.x) / VolcanoCrater.lakeRadius * 0.35
        return (out + swirl) * speed
    }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func index(_ note: UInt8) -> Int? {
        let i = Int(note) - 21
        return (0..<88).contains(i) ? i : nil
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> VolcanoFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fd = Float(fdt)
        let still = fdt == 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        let veining = visual == "Magma Veins"
        if let lastVisual, lastVisual != visual { warp.allNotesOff(); veins.allNotesOff() }
        lastVisual = visual
        let reaction = MoodLook.reactionScale(mood)
        let activity = Float(p.number("activity").isFinite ? min(1, max(0, p.number("activity"))) : 0.5)

        // Excitement, as drawn: Reduce Motion caps Energy's look at 0.5 and shakes nothing.
        let reduce = excite.reduceMotion
        let energy = min(1, max(0, excite.visualEnergy.isFinite ? excite.visualEnergy : 0))
        let tension = min(1, max(0, excite.tension.isFinite ? excite.tension : 0))
        let drop = min(1, max(0, excite.drop.isFinite ? excite.drop : 0))
        let moment = excite.moment
        let surprise = excite.surprise
        excite.moment = nil
        excite.surprise = nil
        thunder.removeAll(keepingCapacity: true)

        // Notes: a crack cell lit where the key falls on the lake, spits below C3 (the lake's own visual); veins (Magma
        // Veins); streaks (Galaxy Warp).
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                let v = min(1, max(0, velocity.isFinite ? velocity : 0))
                held[note] = v
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (v * 127).rounded()))), at: time)
                } else if veining {
                    veins.noteOn(note, velocity: v, at: time)
                } else {
                    let i = Self.nearestCell(VolcanoCrater.lakePoint(for: note), in: cells)
                    cells[i].glow = min(1, max(cells[i].glow, v * min(1.2, reaction)))
                    if note < Self.spitBelow { spit(from: cells[i].position, velocity: v, still: still) }
                }
            case let .noteOff(note):
                held[note] = nil
                warp.noteOff(note)
                veins.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                warp.allNotesOff()
                veins.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // The lake: the convection (faster with Energy and the chord you hold), the cells drifting, splitting at the
        // spreading centre and sinking at the margin.
        let speed = Self.convection(energy: energy, held: held.count, activity: activity)
        crustClock += fd * speed
        if crustClock > 10_000 { crustClock -= 10_000 }
        let glowFall: Float = exp(-fd / (roles[.linger] > 0.5 ? 2.4 : 1.4))
        for i in cells.indices {
            var c = cells[i]
            c.position += (Self.flow(at: c.position, speed: speed) + c.drift) * fd
            c.drift *= exp(-fd / 9)
            c.glow *= glowFall
            if c.glow < 1e-3 { c.glow = 0 }
            c.heat = max(0, c.heat - fd / 240)
            c.birth = min(1, c.birth + fd / 10)
            cells[i] = c
        }
        resurface()

        // Tension swells the lake and beats its cracks with the instrument's pulse (a slow breath without one).
        let bpm = pulse?.bpm ?? 72
        beatPhase += fdt * bpm / 60
        if beatPhase > 1_000 { beatPhase -= 1_000 }
        let phase = Float(beatPhase - beatPhase.rounded(.down))
        let beat: Float = tension * exp(-phase / 0.18)

        // A big moment is an Eruption (never two at once: a moment while one plays answers with lightning and spatter);
        // the drop is the Breach.
        if let m = moment {
            let power = min(1, max(0.3, m.strength.isFinite ? m.strength : 0.3))
            if let e = eruption, e.age < Eruption.life {
                fireCluster(count: 2, strength: power)
                for k in 0..<2 { spit(from: VolcanoCrater.fountainSites[k], velocity: power, still: still) }
            } else {
                erupt(strength: power, still: still)
            }
            if m.isDrop { openBreach() }
        }
        if var e = eruption {
            e.age += fd
            eruption = e.age >= Eruption.life ? nil : e
        }
        billow = max(eruption.map { $0.light } ?? 0, billow * exp(-fd / 5))
        if let a = breachAge {
            let age = a + fd
            breachAge = age > Self.breachSeconds ? nil : age
            breach = 1 - Self.smooth(4, Self.breachSeconds, age)
        } else {
            breach = 0
        }

        // The river: its flow follows Energy (slowly), its crust moving with it.
        let flowTarget = Self.riverFlow(energy: energy)
        riverFlow += (flowTarget - riverFlow) * (1 - exp(-fd / 3))
        let riverSpeed: Float = 1.5 + 6 * riverFlow + 10 * breach

        // The fountains: their height with Energy, bursting.
        var fountains: [LavaFountain] = []
        for k in 0..<VolcanoCrater.fountainSites.count {
            fountainPhase[k] += fd * (0.5 + 0.9 * energy) * (k == 0 ? 1 : 1.27)
            if fountainPhase[k] > 1_000 { fountainPhase[k] -= 1_000 }
            let ph = fountainPhase[k]
            let burst: Float = max(0, sin(ph * 2.1) * 0.6 + sin(ph * 5.3 + 1.1) * 0.4)
            let base = Self.fountainHeight(energy: energy) * (0.75 + 0.5 * activity)
            let h = base * (0.45 + 0.55 * burst) * (k == 0 ? 1 : 0.8)
            fountains.append(LavaFountain(position: VolcanoCrater.fountainSites[k], height: h, burst: burst))
        }

        // Embers off the fountains and the lake's margin, and near ones drifting up past you; the wind bends them.
        let windAngle: Float = 2.6   // from the right: the plume leans left, clear of the breach
        let windSpeed: Float = 3 + 6 * min(1, max(0, rawSky.wind.isFinite ? rawSky.wind : 0))
        let wind = SIMD2<Float>(cos(windAngle), sin(windAngle) * 0.3) * windSpeed
        emberDebt += Self.emberRate(energy: energy) * (0.6 + 0.8 * activity) * fd
        var spawned = 0
        while emberDebt >= 1, spawned < 60 {
            emberDebt -= 1
            spawned += 1
            spawnEmber(fountains: fountains, wind: wind)
        }
        if emberDebt > 4 { emberDebt = 4 }
        stepEmbers(dt: fd, wind: wind)

        // Blobs and bombs fly, land, splash (each pool stepped as a copy: their landings touch the cells and embers).
        var flying = blobs
        stepParticles(&flying, dt: fd, landOnRim: false)
        blobs = flying
        flying = bombs
        stepParticles(&flying, dt: fd, landOnRim: true)
        bombs = flying

        // The plume's lightning: 0.05 → 0.6 strokes a second with Energy, and the eruption's clusters.
        strokeClock -= fd
        if strokeClock <= 0 {
            let rate = Self.lightningRate(energy: energy) * (eruption == nil ? 1 : 2.5)
            let wait = -log(max(1e-4, rng.unit())) / rate
            strokeClock = wait
            if time > 0.5 { fireStroke(strength: 0.4 + 0.5 * energy, delay: 0) }
        }
        for k in cluster.indices.reversed() {
            cluster[k] -= fd
            if cluster[k] <= 0 {
                cluster.remove(at: k)
                fireStroke(strength: 1, delay: 0)
            }
        }
        for i in strokes.indices where strokes[i].alive {
            strokes[i].age += fd
            if strokes[i].age >= PlumeStroke.life { strokes[i].alive = false }
        }

        // The camera: an eruption shakes it once (0.15°), never under Reduce Motion.
        shakeAge += fd
        var shake = SIMD2<Float>(0, 0)
        if !reduce, shakeAge < Self.shakeSeconds {
            let x = 1 - shakeAge / Self.shakeSeconds
            let a = Self.shakeDegrees * x * x
            let t = shakeAge
            shake = SIMD2(sin(2 * Float.pi * 7.3 * t + shakePhase), 0.7 * sin(2 * Float.pi * 9.1 * t + 2 * shakePhase)) * a
        }

        // Surprises.
        if let sp = surprise { surprised(sp) }
        for i in surprises.indices { surprises[i].age += fd }
        surprises.removeAll { $0.age >= $0.duration }

        // Magma Veins.
        if veining, let m = moment { veins.moment(strength: m.strength, drop: m.isDrop) }
        veins.step(dt: fdt, energy: energy, reaction: reaction)

        // The light the scene asks for: the lightning, the eruption, a fireball (the renderer's limiter governs it).
        var flash: Float = 0
        for s in strokes { flash = max(flash, s.brightness) }
        if let e = eruption { flash = max(flash, 0.8 * e.light * (e.age < 0.3 ? 1 : 0.6)) }
        for s in surprises where s.kind == .fireball {
            let x = s.progress
            flash = max(flash, 0.5 * Self.smooth(0.5, 0.75, x) * (1 - Self.smooth(0.75, 1, x)))
        }

        // Keys: basalt columns lit from inside while held, then cooling.
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.0 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v) } else { keyGlow[i] *= fall }
            if keyGlow[i] < 1e-3 { keyGlow[i] = 0 }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        // The sky over the crater: warm, its own lightning left to the plume.
        var s = rawSky
        s.lightning = 0
        s.fireflies = 0
        s.rainbow = 0

        riverDistance += riverSpeed * fd
        if riverDistance > 100_000 { riverDistance -= 100_000 }
        let ambience = scene(sky: s, energy: energy, roles: roles)
        let veinsFrame: VeinsFrame? = veining ? veins.frame(energy: energy, drop: drop, time: time) : nil
        return VolcanoFrame(sky: s, viewAzimuth: Self.viewAzimuth(latitude: s.latitude), cells: cells, blobs: blobs,
                            bombs: bombs, embers: embers, strokes: strokes, fountains: fountains, eruption: eruption,
                            breach: breach, breachAge: breachAge, river: riverFlow, riverFlow: riverDistance,
                            convection: speed, swell: tension, beat: beat, billow: billow, wind: wind,
                            cameraShake: shake, surprises: surprises, flashRequest: min(1, flash), energy: energy,
                            tension: tension, drop: drop, reduceMotion: reduce, keys: keys, ambience: ambience, mood: mood,
                            time: time, warp: warping ? warpFrame : nil, veins: veinsFrame)
    }

    /// The camera faces the equator-side sky (south in the north, north in the south), where the Milky Way stands.
    public static func viewAzimuth(latitude: Double) -> Double { latitude < 0 ? 15 : 195 }

    // MARK: - The lake's crust

    /// A seed that has drifted well past the margin sinks, and the crust is reborn at the spreading centre: it splits
    /// off the plate nearest there, at that plate's own seed, and drifts away from it, so its new crack opens out of
    /// nothing (no plate ever jumps).
    private mutating func resurface() {
        let limit = VolcanoCrater.lakeRadius * 1.55
        for i in cells.indices where simd_length(cells[i].position) > limit {
            let parent = Self.nearestCell(VolcanoCrater.upwelling + SIMD2(rng.range(-30, 30), rng.range(-30, 30)), in: cells)
            guard parent != i else { continue }
            let a = rng.range(0, 2 * Float.pi)
            let dir = SIMD2<Float>(cos(a), sin(a))
            let push = rng.range(1.2, 2.4)
            var c = cells[parent]
            c.position += dir * 0.05
            c.drift = dir * push
            c.heat = 1
            c.birth = 0
            c.glow = 0
            c.twin = parent
            cells[i] = c
            cells[parent].drift -= dir * push * 0.5
        }
    }

    // MARK: - Spits, bombs, embers, strokes

    /// A low note spits 1–3 blobs from the lake (more the harder it's played), each a ballistic arc.
    private mutating func spit(from p: SIMD2<Float>, velocity v: Float, still: Bool) {
        let count = 1 + Int((min(1, max(0, v)) * 2.99).rounded(.down))
        for _ in 0..<count {
            let up = rng.range(12, 20) + 16 * v
            let a = rng.range(0, 2 * Float.pi)
            let out = rng.range(2, 7)
            var b = LavaParticle(alive: true, position: SIMD3(p.x, p.y, 0.5),
                                 velocity: SIMD3(cos(a) * out, sin(a) * out, up), age: 0, size: rng.range(0.8, 2.2),
                                 temperature: 1380, landed: nil)
            if still { advance(&b, by: 0.3) }   // time is held: it shows at once, a little way up its arc
            blobs[nextBlob] = b
            nextBlob = (nextBlob + 1) % Self.blobCount
        }
    }

    private func advance(_ b: inout LavaParticle, by t: Float) {
        b.position += b.velocity * t + SIMD3(0, 0, -0.5 * Self.gravity * t * t)
        b.velocity.z -= Self.gravity * t
        b.age += t
    }

    /// The Eruption: the column, its bombs (more the stronger), a lightning cluster, the plume's billow, the shake.
    private mutating func erupt(strength: Float, still: Bool) {
        eruption = Eruption(age: still ? Eruption.rise : 0, strength: strength)
        let n = Eruption.bombs(strength: strength)
        for k in 0..<n {
            // Spread along the far rim, flying 6–9 s from high in the column.
            let angle = -1.0 + 2.0 * (Float(k) + rng.range(0.1, 0.9)) / Float(max(n, 1))
            let target = VolcanoCrater.rimPoint(angle: angle * 0.95)
            let start = SIMD3<Float>(rng.range(-20, 20), rng.range(-20, 20), rng.range(60, 160))
            let flight = rng.range(6, 9)
            let need = (target - start) / flight
            let v = SIMD3<Float>(need.x, need.y, need.z + 0.5 * Self.gravity * flight)
            var b = LavaParticle(alive: true, position: start, velocity: v, age: 0, size: rng.range(2.5, 6) * (0.6 + 0.4 * strength),
                                 temperature: 1420, landed: nil)
            if still { advance(&b, by: 1.2) }
            bombs[nextBomb] = b
            nextBomb = (nextBomb + 1) % Self.bombCount
        }
        fireCluster(count: 3 + Int(strength * 1.5), strength: strength)
        billow = 1
        shakeAge = 0
        shakePhase = rng.range(0, 2 * Float.pi)
        thunder.append(QueuedThunder(delay: 1.6, strength: Double(min(1, 0.6 + 0.4 * strength))))
    }

    private mutating func openBreach() {
        // Never two at once: a drop while the river still pours opens it no further, only keeps it pouring.
        if let a = breachAge, a < 4 { return }
        breachAge = 0
        breach = 1
    }

    private mutating func fireCluster(count: Int, strength: Float) {
        for k in 0..<max(0, count) where cluster.count < 6 {
            cluster.append(Float(k) * rng.range(0.07, 0.16))
        }
        _ = strength
    }

    private mutating func fireStroke(strength: Float, delay: Float) {
        // Inside the plume, between 40 m and 220 m up, a little off its axis.
        let z = rng.range(40, 220)
        let bend = 0.0007 * z * z
        let origin = SIMD3<Float>(bend + rng.range(-50, 50) * (1 + z / 220), rng.range(-30, 30), z)
        strokes[nextStroke] = PlumeStroke(alive: true, seed: rng.next(), age: -delay, strength: min(1, max(0, strength)),
                                          origin: origin, length: rng.range(45, 120))
        nextStroke = (nextStroke + 1) % Self.strokeCount
        thunder.append(QueuedThunder.strike(km: 0.55, strength: Double(0.35 + 0.5 * strength)))
    }

    private mutating func spawnEmber(fountains: [LavaFountain], wind: SIMD2<Float>) {
        let roll = rng.unit()
        var e = Ember.dead
        e.alive = true
        e.age = 0
        if roll < 0.12 {
            // Near: up past the view from the rim's own vents, a few tens of metres ahead.
            let eye = VolcanoCrater.eye
            e.position = SIMD3(rng.range(-55, 55), eye.y + rng.range(12, 60), eye.z - rng.range(14, 30))
            e.velocity = SIMD3(rng.range(-0.6, 0.6) + 0.3 * wind.x, rng.range(-0.4, 0.4), rng.range(2.2, 4.2))
            e.life = rng.range(5, 9)
            e.size = rng.range(0.035, 0.08)
            e.temperature = rng.range(1050, 1250)
            e.near = true
        } else {
            // Off a fountain (most), or anywhere along the crust's cracks.
            let fromFountain = roll < 0.7
            let site = fountains[Int(rng.next() % UInt64(max(1, fountains.count)))]
            let r = VolcanoCrater.lakeRadius * rng.unit().squareRoot() * 0.95
            let a = rng.range(0, 2 * Float.pi)
            let base = fromFountain ? site.position + SIMD2(rng.range(-6, 6), rng.range(-6, 6)) : SIMD2(cos(a) * r, sin(a) * r)
            let lift: Float = fromFountain ? site.height * rng.range(0.3, 1) : rng.range(0.5, 3)
            e.position = SIMD3(base.x, base.y, lift)
            e.velocity = SIMD3(rng.range(-3, 3), rng.range(-3, 3), rng.range(6, 16))
            e.life = rng.range(2.5, 6)
            e.size = rng.range(0.25, 0.7)
            e.temperature = rng.range(1150, 1380)
            e.near = false
        }
        embers[nextEmber] = e
        nextEmber = (nextEmber + 1) % Self.emberCount
    }

    private mutating func stepEmbers(dt: Float, wind: SIMD2<Float>) {
        guard dt > 0 else { return }
        let drag: Float = exp(-dt / 2.5)
        for i in embers.indices where embers[i].alive {
            var e = embers[i]
            e.age += dt
            if e.age >= e.life { embers[i].alive = false; continue }
            // The heat carries them up; the wind takes them across; they flicker side to side.
            let lift: Float = e.near ? 0.4 : 2.2 * exp(-e.position.z / 260)
            let target = SIMD3<Float>(wind.x, wind.y, e.velocity.z)
            e.velocity = target + (e.velocity - target) * drag
            e.velocity.z += (lift - 0.25) * dt
            let wobble = sin(Float(i) * 1.7 + e.age * 3.1) * 0.6
            e.position += (e.velocity + SIMD3(wobble, 0, 0)) * dt
            embers[i] = e
        }
    }

    private mutating func stepParticles(_ list: inout [LavaParticle], dt: Float, landOnRim: Bool) {
        guard dt > 0 else { return }
        for i in list.indices where list[i].alive {
            var b = list[i]
            b.age += dt
            if let l = b.landed {
                let t = l + dt
                b.landed = t
                b.temperature = max(700, b.temperature - 90 * dt)
                if t > (landOnRim ? 3 : 1.2) { b.alive = false }
                list[i] = b
                continue
            }
            b.position += b.velocity * dt + SIMD3(0, 0, -0.5 * Self.gravity * dt * dt)
            b.velocity.z -= Self.gravity * dt
            b.temperature = max(820, b.temperature - (landOnRim ? 40 : 70) * dt)
            let ground: Float = landOnRim ? groundHeight(b.position) : 0
            if b.velocity.z < 0, b.position.z <= ground {
                b.position.z = ground
                b.velocity = .zero
                b.landed = 0
                if landOnRim { sparks(at: b.position, count: 14) } else { sparks(at: b.position, count: 3) }
                if !landOnRim {
                    let p = SIMD2(b.position.x, b.position.y)
                    if simd_length(p) < VolcanoCrater.lakeRadius {
                        let c = Self.nearestCell(p, in: cells)
                        cells[c].glow = max(cells[c].glow, 0.5)
                    }
                }
            }
            if b.age > 20 { b.alive = false }
            list[i] = b
        }
    }

    /// The ground's height under a point (a bomb lands on the floor, the bench or the rim).
    private func groundHeight(_ p: SIMD3<Float>) -> Float {
        let r = simd_length(SIMD2(p.x, p.y) - VolcanoCrater.wallCentre)
        if r < VolcanoCrater.footRadius { return 0 }
        if r < VolcanoCrater.benchRadius { return VolcanoCrater.benchHeight }
        return VolcanoCrater.rimHeight
    }

    private mutating func sparks(at p: SIMD3<Float>, count: Int) {
        for _ in 0..<count {
            var e = Ember.dead
            e.alive = true
            e.position = p + SIMD3(0, 0, 0.5)
            let a = rng.range(0, 2 * Float.pi)
            let out = rng.range(2, 9)
            e.velocity = SIMD3(cos(a) * out, sin(a) * out, rng.range(3, 12))
            e.life = rng.range(0.8, 2)
            e.size = rng.range(0.3, 0.9)
            e.temperature = rng.range(1250, 1400)
            embers[nextEmber] = e
            nextEmber = (nextEmber + 1) % Self.emberCount
        }
    }

    // MARK: - Surprises

    private mutating func surprised(_ s: WorldSurprise) {
        guard let kind = VolcanoSurprise.Kind(rawValue: s.index) else { return }
        guard !surprises.contains(where: { $0.kind == kind }) else { return }
        var r = SeededRandom(seed: s.seed)
        let angle: Float
        switch kind {
        case .fireball: angle = r.range(-25, 25)
        case .rockfall: angle = r.range(-0.55, 0.15)
        case .steamBlast: angle = r.range(-0.6, 0.6)
        case .redSprites: angle = r.range(-28, -12)
        case .lavaTree: angle = r.range(0.35, 0.75)
        }
        surprises.append(VolcanoSurprise(kind: kind, age: 0, duration: VolcanoSurprise.duration(kind), seed: s.seed, angle: angle))
        if kind == .rockfall {
            // Hot fragments tumbling down the wall with the dust.
            let foot = VolcanoCrater.wallPoint(angle: angle, radius: VolcanoCrater.benchRadius)
            for _ in 0..<10 { sparks(at: SIMD3(foot.x, foot.y, VolcanoCrater.rimHeight * 0.8), count: 1) }
        }
    }

    // MARK: - Ambience

    /// The crater's soundscape before the weather's. The volcano's own family (vent rumble, lava hiss, steam vents,
    /// rockfall, the eruption's boom, the plume's thunder) comes with plan Task 10; until then the nearest existing
    /// sources stand in: the fire's crackle for the lake's hiss and spatter (louder with Energy), the wind over the rim,
    /// a breeze, and the thunder roll (which plays the queue: the plume's strokes and the eruption's boom).
    public static func levels(_ s: SkyState, energy: Float, eruption: Float, breach: Float) -> [AmbienceSource: Double] {
        let e = Double(energy.isFinite ? min(1, max(0, energy)) : 0)
        let wind = Double(s.wind.isFinite ? min(1, max(0, s.wind)) : 0)
        var levels: [AmbienceSource: Double] = [:]
        // TASK 10 (Fire & Neon plan): replace these stand-ins with .ventRumble, .lavaHiss, .steamVent, .rockfall,
        // .eruptionBoom and .plumeThunder.
        levels[.fire] = min(1, 0.35 + 0.4 * e + 0.25 * Double(max(eruption, breach)))
        levels[.wind] = min(1, 0.2 + 0.4 * wind)
        levels[.breeze] = 0.2
        levels[.thunderRoll] = 0.9
        WeatherAmbience.levels(s, base: &levels)
        return levels
    }

    private func scene(sky s: SkyState, energy: Float, roles: RoleValues) -> AmbienceScene {
        let levels = Self.levels(s, energy: energy, eruption: eruption?.light ?? 0, breach: breach)
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             wetness: Double(s.wetness), thunderQueue: thunder)
    }
}

extension VolcanoRimModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the lava lake",
                  kind: .choice(visuals), defaultValue: .choice("Lava Lake")),
        slider("activity", "Lava", "Lake", 0...1, 0.5, hero: true, surprise: 0.3...0.9,
               help: "How lively the lake is: its convection, fountains and embers"),
        slider("plume", "Plume", "Lake", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How thick and tall the glowing plume over the lake stands"),
        SkyHold.spec(default: .deepNight),
        AuroraMode.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A row of basalt columns along the rim, lit from inside where you play",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.11, help: "How tall the basalt columns stand"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("activity", 0.6)],
        .speed: [("activity", 0.3)],
        .density: [("plume", 0.5)],
        .glow: [("plume", 0.4)],
        .chaos: [("activity", 0.4)],
        .temperature: [],
    ]
}
