import Foundation
import simd

/// A world that tells the ambience what it should sound like this frame.
public protocol AmbienceProviding { var ambience: AmbienceScene { get } }

/// Everything the Moonlit Lake renderer needs for a frame.
public struct LakeFrame: AmbienceProviding {
    public var sky: SkyState
    public var ripples: [Ripple]
    public var fireflies: [Firefly]
    /// 0…1: how much the moon (or sun) path sparkles.
    public var glitter: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the lake's sky, when it's the chosen visual (notes then streak instead of rippling).
    public var warp: WarpFrame?

    // Excitement as the lake draws it (Fire & Neon spec §5.5). The meteor burst and the fireball are already in `sky`
    // (the shared sky draws them, and the water mirrors them).
    /// Rings that aren't a note's: a fish rising, and the water's own dimples as Energy rises (beside `ripples`).
    public var rings: [Ripple] = []
    /// The owl crossing the moon (a surprise), while it flies.
    public var owl: LakeOwl? = nil
    /// The wind the water and the reeds feel: the sky's, raised by Energy (0…1).
    public var windOnWater: Float = 0
    /// Tension: the mist gathers on the water (0…1). The drop: it lifts all at once (1), settling back over 14 s.
    public var mistGather: Float = 0
    public var mistLift: Float = 0
    /// A fireball's light on the lake (0…1, before the renderer's flash limiter).
    public var flashRequest: Float = 0
    /// How many of the lake's own meteors (the burst's, a fireball's) are showing.
    public var worldMeteors: Int = 0
    /// The surprises playing now.
    public var surprises: [LakeSurprise] = []
    public var energy: Float = 0
    public var tension: Float = 0
}

/// The owl crossing the moon (Fire & Neon spec §5.5): it glides a straight line across the sky from `from` to `to`
/// (east-north-up unit vectors), through the moon's disc; `progress` 0…1 along it, its wings' beat (−1 down … 1 up: a
/// few deep, slow beats, then a glide) and its wingspan's angular size (degrees).
public struct LakeOwl: Equatable {
    public var from: SIMD3<Float>
    public var to: SIMD3<Float>
    public var progress: Float
    public var wing: Float
    public var span: Float

    /// Where it is now (an east-north-up unit vector).
    public var direction: SIMD3<Float> {
        let a = simd_normalize(from), b = simd_normalize(to)
        let p = min(1, max(0, progress.isFinite ? progress : 0))
        return simd_normalize(a * (1 - p) + b * p)
    }
}

/// A lake surprise playing now (Fire & Neon spec §5.5): a fireball, an owl crossing the moon (a fish rising instead
/// while the moon is down or out of view), a fish rising.
public struct LakeSurprise: Equatable {
    public enum Kind: Int, CaseIterable { case fireball, owl, fish }
    public var kind: Kind
    public var age: Float
    public var duration: Float
    public var seed: UInt64

    public static func duration(_ k: Kind) -> Float {
        switch k {
        case .fireball: return 3.6
        case .owl: return 7
        case .fish: return 4.5
        }
    }
    public var progress: Float { min(1, max(0, age / max(duration, 1e-3))) }
}

/// Set 1's world: a still lake under the Living Sky, ridges and pines, reeds and mist.
/// Its visual, Lake Ripples, answers your notes on the water.
public struct MoonlitLakeModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = LakeFrame
    public static let id = "moonlit-lake"
    public static let displayName = "Moonlit Lake"
    public static let visuals = ["Lake Ripples", "Galaxy Warp"]
    /// A fireball, an owl crossing the moon, a fish rising (Fire & Neon spec §5.5).
    public static let surpriseCount = LakeSurprise.Kind.allCases.count
    /// The rings' pool (a fish's and the water's own), the burst's meteors at most, and the mist's settling time.
    public static let ringCount = 16
    public static let burstMost = 12, burstLeast = 5
    public static let liftSeconds: Float = 20

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var lake = LakeRipples()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var pedal = false
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0x7E11)

    // Excitement (Fire & Neon spec §5.5): fixed pools throughout.
    private var excite = ExcitementFrame()
    private var rng = SeededRandom(seed: 0x1A4E_E7C1)
    private var meteors = WorldMeteors()
    private var rings = [Ripple](repeating: MoonlitLakeModel.deadRing, count: MoonlitLakeModel.ringCount)
    private var surprises: [LakeSurprise?] = [nil, nil, nil]
    private var owl: LakeOwl?
    private var energyEased: Float = 0
    private var gather: Float = 0
    private var liftAge: Float?
    private var dimpleDebt: Float = 0
    private var burstAge: Float?
    private var burstRadiant = SIMD3<Float>(0, 0, 1)

    private static let layout = KeyboardLayout.keys()
    private static let deadRing = Ripple(x: 0, depth: 0, age: 0, strength: 0, lifetime: 0)

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// Where the lake looks: at the moon while it's up (a little to its left, so it sits off-centre), else at the sun,
    /// else toward the equator (the renderer glides its camera here).
    public static func viewAzimuth(_ s: SkyState) -> Double {
        if s.moon.altitude > -5, s.sun.altitude < 2 { return s.moon.azimuth - 10 }
        if s.sun.altitude > -12 { return s.sun.azimuth - 10 }
        return s.latitude < 0 ? 0 : 180
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> LakeFrame {
        time += dt
        lake.size = Float(p.number("ripples.size"))
        lake.linger = Float(p.number("ripples.linger"))
        lake.fireflyAmount = Float(p.number("fireflies"))
        lake.reactionScale = MoodLook.reactionScale(mood)
        lake.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { lake.noteOn(note, velocity: v, pedal: pedal, at: time) }
            case let .noteOff(note):
                held[note] = nil
                lake.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                pedal = down
            case .allNotesOff:
                held.removeAll()
                lake.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        lake.step(dt: dt, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)
        let x = ExcitementStep.take(&excite)
        stepExcitement(x, dt: Float(max(0, dt.isFinite ? dt : 0)), warping: warping)

        // Keys glow moon-silver while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        var shown = sky
        meteors.inject(into: &shown)
        var frame = LakeFrame(sky: shown, ripples: lake.ripples, fireflies: lake.fireflies, glitter: lake.glitter, keys: keys,
                              ambience: ambience(roles: roles), mood: mood, time: time, warp: warping ? warpFrame : nil)
        frame.rings = rings.filter { $0.lifetime > 0 && $0.age >= 0 }   // a fish's later rings wait their turn
        frame.owl = owl
        frame.windOnWater = min(1, max(0, (sky.wind.isFinite ? sky.wind : 0) + 0.35 * energyEased))
        frame.mistGather = gather
        frame.mistLift = liftAge.map { ExcitementStep.envelope(age: $0, life: Self.liftSeconds, rise: 0.7, fall: 14) } ?? 0
        frame.flashRequest = 0.35 * max(meteors.fireballLight(at: sky.meteorTime), burstFlareLight(at: sky.meteorTime))
        frame.worldMeteors = meteors.live(at: sky.meteorTime).count
        frame.surprises = surprises.compactMap { $0 }
        frame.energy = x.energy
        frame.tension = x.tension
        return frame
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    /// Energy stirs the water (its wind, and dimples here and there); a big moment is a meteor burst from one radiant,
    /// mirrored in the lake; tension gathers the mist and a drop lifts it all at once; the surprises play.
    private mutating func stepExcitement(_ x: ExcitementStep, dt fd: Float, warping: Bool) {
        energyEased = ExcitementStep.ease(energyEased, to: x.energy, tau: x.energy > energyEased ? 1.2 : 4, dt: fd)
        let now = sky.meteorTime
        meteors.prune(at: now)

        // The water's own dimples: rarer than a note's rings and fainter, about 3 a second at full Energy.
        for i in rings.indices where rings[i].lifetime > 0 {
            rings[i].age += fd
            if rings[i].age >= rings[i].lifetime { rings[i] = Self.deadRing }
        }
        if fd > 0, !warping {
            dimpleDebt += 3 * energyEased * energyEased * fd
            while dimpleDebt >= 1 {
                dimpleDebt -= 1
                ring(x: rng.range(0.08, 0.92), depth: rng.range(0.2, 0.85), strength: rng.range(0.12, 0.3) * lake.reactionScale,
                     lifetime: rng.range(2, 3))
            }
        }

        // A big moment: a meteor burst. The drop: the mist lifts.
        if let m = x.moment {
            burst(strength: ExcitementStep.strength(m), gentle: x.gentle, now: now)
            if m.isDrop { liftAge = 0 }
        }
        if let a = burstAge { burstAge = a + fd > 4 ? nil : a + fd }
        if let a = liftAge { liftAge = a + fd > Self.liftSeconds ? nil : a + fd }
        let target = x.tension
        gather = ExcitementStep.ease(gather, to: target, tau: target > gather ? 1.5 : 3, dt: fd)
        if liftAge != nil { gather = ExcitementStep.ease(gather, to: 0, tau: 0.4, dt: fd) }

        // Surprises.
        if let sp = x.surprise { surprised(sp, gentle: x.gentle, now: now) }
        for i in surprises.indices {
            guard var sp = surprises[i] else { continue }
            sp.age += fd
            surprises[i] = sp.age >= sp.duration ? nil : sp
        }
        if let o = owl {
            if let found = surprises.first(where: { $0?.kind == .owl }), let sp = found {
                var next = o
                next.progress = sp.progress
                // A few deep, slow beats, then a glide, and again.
                let cycle = (sp.age * 2.1).truncatingRemainder(dividingBy: 5)
                next.wing = cycle < 3 ? sin(cycle * 2 * .pi) : 0.15
                owl = next
            } else {
                owl = nil
            }
        }
    }

    /// A ring in the pool (over the most nearly spent when it's full); a negative `age` waits that long to start.
    private mutating func ring(x: Float, depth: Float, strength: Float, lifetime: Float, age: Float = 0) {
        let r = Ripple(x: x, depth: depth, age: age, strength: strength, lifetime: lifetime)
        if let free = rings.firstIndex(where: { $0.lifetime <= 0 }) {
            rings[free] = r
        } else {
            var oldest = 0
            for i in rings.indices where rings[i].age / max(rings[i].lifetime, 1e-3) > rings[oldest].age / max(rings[oldest].lifetime, 1e-3) {
                oldest = i
            }
            rings[oldest] = r
        }
    }

    /// 5–12 meteors from one radiant high in the view, the first ones at once and the rest over 2.4 s, all running away
    /// from it. Their heads stay points (about as bright as the brightest stars: a brighter head only grows the sky's halo
    /// round it into a ball of light); their brightness is in their long, thin, tapering streaks and trains. At strength
    /// 0.6 and over the first two are the brightest and longest, each ending in a brief small flare (never under gentle
    /// visuals, where every one is a magnitude and a half fainter).
    private mutating func burst(strength s: Float, gentle: Bool, now: Double) {
        // Never two at once: a moment while a burst still runs adds two more from its radiant (to free slots only, so
        // nothing in flight is cut off).
        let adding = burstAge != nil
        if !adding { burstAge = 0 }
        let span = Float(Self.burstMost - Self.burstLeast)
        let count = adding ? 2 : min(Self.burstMost, Self.burstLeast + Int(((s - 0.15) / 0.85 * span).rounded()))
        let view = Self.viewAzimuth(sky)
        if !adding { burstRadiant = WorldMeteors.direction(azimuth: view + Double(rng.range(-16, 16)), altitude: Double(rng.range(22, 32))) }
        let radiant = burstRadiant
        let fainter: Float = gentle ? 1.5 : 0
        for k in 0..<count {
            if adding, meteors.slots.allSatisfy({ $0 != nil }) { break }
            let f = count > 1 ? Float(k) / Float(count - 1) : 0
            let offset = adding ? Double(k) * 0.2 : 2.4 * Double(f * f.squareRoot())
            let bright = !adding && k < 2 && s >= 0.6
            let length = rng.range(14, 28) * (0.8 + 0.4 * s) * (bright ? 1.3 : 1)
            let pace = rng.range(22, 36)
            let magnitude: Float = bright ? -2.3 + 0.4 * Float(k) : -0.9 - 1.0 * s + rng.range(-0.6, 0.6)
            let m = WorldMeteors.meteor(radiant: radiant, distance: rng.range(5, 22), angle: rng.range(-1.35, 1.35), length: length,
                                        born: now + offset, duration: length / pace, magnitude: magnitude + fainter,
                                        speed: Double(rng.range(58, 70)), flare: bright && !gentle)
            meteors.add(m)
        }
    }

    /// The burst's terminal flares on the lake (0…1, before the limiter): a brief lift at each flare's height, a fifth of
    /// a fireball's at most.
    private func burstFlareLight(at t: Double) -> Float {
        var light: Float = 0
        for case let m? in meteors.slots where m.flare && m.isHead(at: t) {
            let shape = m.headBrightness(at: t) / max(1e-6, m.peakBrightness)
            light = max(light, 0.5 * max(0, shape - 1.05))
        }
        return min(1, light)
    }

    private mutating func surprised(_ s: WorldSurprise, gentle: Bool, now: Double) {
        guard var kind = LakeSurprise.Kind(rawValue: s.index) else { return }
        var r = SeededRandom(seed: s.seed)
        let view = Self.viewAzimuth(sky)
        if kind == .owl {
            // The owl crosses the moon: only while the moon is up, lit and in view (else a fish rises instead).
            let off = abs((sky.moon.azimuth - view + 540).truncatingRemainder(dividingBy: 360) - 180)
            if sky.moon.altitude < 4 || sky.moonLit < 0.15 || off > 35 { kind = .fish }
        }
        guard !surprises.contains(where: { $0?.kind == kind }) else { return }
        var duration = LakeSurprise.duration(kind)
        switch kind {
        case .fireball:
            // A slow golden fireball across the view, high to low, ending in a flare (a glow under gentle visuals).
            let leftToRight = r.unit() < 0.5
            let a = view + (leftToRight ? -1 : 1) * Double(r.range(20, 30))
            let b = view + (leftToRight ? 1 : -1) * Double(r.range(14, 24))
            let start = WorldMeteors.direction(azimuth: a, altitude: Double(r.range(26, 32)))
            let end = WorldMeteors.direction(azimuth: b, altitude: Double(r.range(4, 9)))
            let run = r.range(2.8, 3.3)
            meteors.add(WorldMeteors.meteor(from: start, to: end, born: now, duration: run, magnitude: gentle ? -6 : -8,
                                            speed: 24, flare: !gentle))
            duration = run + 0.2
        case .owl:
            let m = WorldMeteors.direction(azimuth: sky.moon.azimuth, altitude: sky.moon.altitude)
            let up = SIMD3<Float>(0, 0, 1)
            var across = simd_cross(m, up)
            if simd_length(across) < 1e-4 { across = SIMD3<Float>(1, 0, 0) }
            across = simd_normalize(across) * (r.unit() < 0.5 ? 1 : -1)
            let rising = up - m * simd_dot(m, up)   // up the sky from the moon (nothing with the moon overhead)
            let downhill: SIMD3<Float> = simd_length(rising) > 1e-4 ? simd_normalize(rising) * -0.18 : .zero
            let path = simd_normalize(across + downhill)
            let half: Float = 9 * .pi / 180
            let start = simd_normalize(m * cos(half) - path * sin(half)), end = simd_normalize(m * cos(half) + path * sin(half))
            owl = LakeOwl(from: start, to: end, progress: 0, wing: 0, span: 1.6)
        case .fish:
            let x = r.range(0.25, 0.75), depth = r.range(0.25, 0.6)
            // A rise: a ring, then two more from the same spot as the fish turns down.
            for k in 0..<3 {
                ring(x: x + r.range(-0.004, 0.004), depth: depth, strength: (0.7 - 0.15 * Float(k)) * lake.reactionScale,
                     lifetime: 3.5 - 0.35 * Float(k), age: -0.35 * Float(k))
            }
        }
        let record = LakeSurprise(kind: kind, age: 0, duration: duration, seed: s.seed)
        if let free = surprises.firstIndex(where: { $0 == nil }) { surprises[free] = record }
    }

    /// The lake's soundscape, following the sky and your playing.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = Self.smooth(-3, -9, sunAlt)
        let rising = sky.hourOfDay < 12
        let dawn = rising ? Self.smooth(-7, -5, sunAlt) * Self.smooth(9, 6, sunAlt) : 0
        var levels: [AmbienceSource: Double] = [
            .water: 0.8,
            .crickets: 0.7 * night,
            .dawnChorus: 0.5 * dawn,
            .breeze: min(1, 0.3 + Double(sky.wind)),
            .owl: 0.3 * night,
            .rainOnWater: Double(sky.rain),
        ]
        if sky.wind > 0.6 { levels[.wind] = Double(sky.wind - 0.6) * 2 }
        WeatherAmbience.levels(sky, base: &levels)
        // Night cools from dusk (about 19:00) over eight hours.
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}

extension MoonlitLakeModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the lake",
                  kind: .choice(visuals), defaultValue: .choice("Lake Ripples")),
        MeteorMode.spec(default: .follow),
        slider("ripples.size", "Ripple size", "Lake Ripples", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How far each note's ring spreads"),
        slider("ripples.linger", "Ripples linger", "Lake Ripples", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How long the rings keep moving"),
        slider("fireflies", "Fireflies from chords", "Lake Ripples", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords lift fireflies off the water"),
        slider("glitter", "Moon path glitter", "Lake", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How much the moon's path sparkles while you hold notes"),
        slider("mist", "Mist", "Lake", 0...1, 0.4, surprise: 0...0.8, help: "Mist lying on the water"),
        slider("reeds", "Reeds", "Lake", 0...1, 0.6, surprise: 0...1, help: "Reeds at the water's edge"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A glassy keyboard along the shore",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("ripples.size", 0.8), ("glitter", 0.6)],
        .speed: [],
        .density: [("fireflies", 0.8), ("reeds", 0.5)],
        .glow: [("glitter", 1)],
        .chaos: [("ripples.size", 0.4)],
        .temperature: [],
    ]
}
