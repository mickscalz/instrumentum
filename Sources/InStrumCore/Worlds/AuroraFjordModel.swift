import Foundation
import simd

/// A pale slab of ice drifting on the fjord.
public struct Floe: Equatable {
    /// Across the view (0…1, wrapping behind the walls at the edges).
    public var x: Float
    /// Down the fjord: 0 near the jetty … 1 at the far, sea end.
    public var depth: Float
    /// Its size (0…1 of the largest slab).
    public var size: Float
    /// Its turn about the vertical (radians).
    public var angle: Float
    /// Its own drift across the view with the current (per second, signed; the wind adds to it).
    public var drift: Float
}

/// Everything the Aurora Fjord renderer needs for a frame.
public struct FjordFrame: AmbienceProviding {
    /// The sky after `fjordSky`: rain falls as sleet, storms are blizzards, no lightning.
    public var sky: SkyState
    /// Curtain Lights: the ripples to draw (at most `CurtainLights.cap`, the strongest, in order), the held-note glow
    /// (0…1), the hue shift (−1 cool … +1 warm), a tense chord's purple-fringe pulse (0…1) and the shimmer speed (1…2).
    public var ripples: [CurtainRipple]
    public var glow: Float
    public var hueShift: Float
    public var tensePulse: Float
    public var shimmer: Float
    /// The ice floes on the water (6…14 by the Ice floes setting).
    public var floes: [Floe]
    /// The fishing village's lights are on (the sun below −4°).
    public var villageLit: Bool
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the fjord's sky, when it's the chosen visual (notes then streak instead of rippling the curtain).
    public var warp: WarpFrame?

    // Excitement as the fjord draws it (Fire & Neon spec §5.5). A fireball and a satellite's flare are already in `sky`.
    /// Energy: how fast the aurora moves (1…1.8×) and how much higher it stands in the V of sky (degrees).
    public var auroraPace: Float = 1
    public var auroraLift: Float = 0
    /// Tension: the curtains gather, brightening and drawing down into a tight arc (0…1).
    public var gather: Float = 0
    /// The signature moment: the aurora surging (0…1), its corona overhead (0…1), and seconds since it began (−1: none).
    public var surge: Float = 0
    public var corona: Float = 0
    public var surgeAge: Float = -1
    /// An orca in the fjord (a surprise): its fin and its blow.
    public var orca: FjordOrca? = nil
    public var surprises: [FjordSurprise] = []
    /// A fireball's light on the fjord (0…1, before the renderer's flash limiter).
    public var flashRequest: Float = 0
    public var energy: Float = 0
    public var tension: Float = 0
}

/// An orca surfacing in the fjord (Fire & Neon spec §5.5): where (across the view 0…1 and down the fjord 0 near … 1 far,
/// as the floes are placed), how far its fin stands out of the water (0…1), and its blow: seconds since it began (−1:
/// none) and how strong (0…1).
public struct FjordOrca: Equatable {
    public var x: Float
    public var depth: Float
    public var fin: Float
    public var blowAge: Float
    public var blow: Float
}

/// A fjord surprise playing now (Fire & Neon spec §5.5): a fireball, an orca's blow in the fjord, a satellite's flare.
public struct FjordSurprise: Equatable {
    public enum Kind: Int, CaseIterable { case fireball, orca, satelliteFlare }
    public var kind: Kind
    public var age: Float
    public var duration: Float
    public var seed: UInt64

    public static func duration(_ k: Kind) -> Float {
        switch k {
        case .fireball: return 3.6
        case .orca: return 10
        case .satelliteFlare: return 28
        }
    }
    public var progress: Float { min(1, max(0, age / max(duration, 1e-3))) }
}

/// Set 7's world: a jetty at the head of a fjord looking down it toward the pole, the aurora over the sea end,
/// still black water mirroring it, a fishing village's lights and drifting ice. Its visual, Curtain Lights, lets
/// your notes ripple the aurora.
public struct AuroraFjordModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = FjordFrame
    public static let id = "aurora-fjord"
    public static let displayName = "Aurora Fjord"
    public static let visuals = ["Curtain Lights", "Galaxy Warp"]
    /// A fireball, an orca's blow in the fjord, a satellite's flare (Fire & Neon spec §5.5).
    public static let surpriseCount = FjordSurprise.Kind.allCases.count
    /// How much higher the curtain stands at full Energy (degrees), and how long a surge lasts (a drop's a little longer).
    public static let liftAtFull: Float = 6
    public static let surgeSeconds: Float = 7, dropSurgeSeconds: Float = 9
    /// The most floes the setting can ask for (the pool is built once, seeded).
    public static let maxFloes = 14, minFloes = 6

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var lights = CurtainLights()
    private var warp = GalaxyWarp()
    private var pool: [Floe]
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastVisual = ""
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xF7_0AD)

    // Excitement (Fire & Neon spec §5.5): fixed pools throughout.
    private var excite = ExcitementFrame()
    private var meteors = WorldMeteors()
    private var energyEased: Float = 0
    private var energySlow: Float = 0
    private var gatherEased: Float = 0
    private var surgeState: (age: Float, strength: Float, life: Float)?
    private var surprises: [FjordSurprise?] = [nil, nil, nil]
    private var orcaAt = SIMD3<Float>(0.5, 0.5, 1)   // x, depth, which way it swims
    /// The satellite's pass: where it starts and ends (east-north-up), when (s on the sky's clock) and its flare's peak.
    private var pass: (from: SIMD3<Float>, to: SIMD3<Float>, peak: Float)?

    private static let layout = KeyboardLayout.keys()

    public init() {
        var r = SeededRandom(seed: 0xF10E_5EED)
        pool = (0..<Self.maxFloes).map { _ in
            let side: Float = r.unit() < 0.5 ? -1 : 1
            return Floe(x: r.range(0.05, 0.95), depth: r.range(0.08, 0.95), size: r.range(0.35, 1),
                        angle: r.range(0, 2 * .pi), drift: side * r.range(0.002, 0.008))
        }
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = Self.fjordSky(s) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// The pole-ward azimuth the fjord looks down (degrees): the camera glides after the aurora's wander about it.
    public static func poleAzimuth(_ s: SkyState) -> Double { s.hemisphere >= 0 ? 0 : 180 }

    /// It's cold here, but by the sea: the cold-world rule (`WorldWeather.cold`: storms become blizzards, no
    /// lightning, no fireflies, frost from the cold rain), except that rain falls as sleet, half rain and half snow,
    /// and leaves the jetty half as wet as rain would.
    public static func fjordSky(_ s: SkyState) -> SkyState {
        var c = WorldWeather.cold(s)
        // How much storm is in the sky right now (the same glide `cold` uses): that part is already a blizzard.
        let t = min(max(s.weatherBlend, 0), 1), glide = t * t * (3 - 2 * t)
        let storm = (s.weather == .storm ? 1 - glide : 0) + (s.nextWeather == .storm ? glide : 0)
        let sleet = max(0, s.rain) * (1 - storm)
        c.rain = 0.5 * sleet
        c.snow = max(s.snow, 0.5 * sleet, storm)
        c.wetness = 0.5 * s.wetness * (1 - storm)
        func sleety(_ k: WeatherKind, _ chilled: WeatherKind) -> WeatherKind {
            switch k {
            case .drizzle, .rain, .sunShower, .sleet, .freezingDrizzle: return .sleet
            default: return chilled
            }
        }
        c.weather = sleety(s.weather, c.weather)
        c.nextWeather = sleety(s.nextWeather, c.nextWeather)
        return c
    }

    /// How many floes the setting asks for (6…14).
    public static func floeCount(_ amount: Double) -> Int {
        let a = amount.isFinite ? min(max(amount, 0), 1) : 0.6
        return minFloes + Int((Double(maxFloes - minFloes) * a).rounded())
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> FjordFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        if visual != lastVisual {
            // Switching visuals lets held notes go: no stuck ripples or streaks.
            lights.allNotesOff(); warp.allNotesOff()
            lastVisual = visual
        }
        lights.reactionScale = MoodLook.reactionScale(mood)
        lights.lingerScale = MoodLook.lingerScale(mood)
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping { warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time) }
                else { lights.noteOn(note, velocity: velocity, at: time) }
            case let .noteOff(note):
                held[note] = nil
                lights.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                lights.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                lights.allNotesOff(); lights.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        lights.step(dt: fdt, roles: roles)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // The floes drift with the current and the wind (more with the swell), turning slowly, wrapping behind the walls.
        let swell = Float(min(max(p.number("swell"), 0), 1))
        let wind = sky.wind.isFinite ? min(max(sky.wind, 0), 1) : 0
        let fstep = Float(fdt)
        for i in pool.indices {
            var f = pool[i]
            let along: Float = f.drift < 0 ? -1 : 1
            let push = (f.drift + 0.006 * wind * along) * (0.6 + swell)
            f.x += push * fstep / (0.4 + 0.6 * f.depth)          // near floes cross the view faster
            if f.x < 0 { f.x += 1 } else if f.x > 1 { f.x -= 1 }
            f.angle += (f.drift * 6 + 0.01 * wind) * fstep
            if f.angle > 2 * .pi { f.angle -= 2 * .pi } else if f.angle < 0 { f.angle += 2 * .pi }
            pool[i] = f
        }
        let floes = Array(pool.prefix(Self.floeCount(p.number("floes"))))

        // Keys glow ice-blue while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let villageLit = p.number("village") > 0.02 && sky.sun.altitude < -4

        let x = ExcitementStep.take(&excite)
        stepExcitement(x, dt: Float(fdt))
        var shown = sky
        meteors.inject(into: &shown)
        if let sat = satellite() { shown.satellites = [sat] + Array(shown.satellites.prefix(Satellites.slots - 1)) }
        var frame = FjordFrame(sky: shown,
                               ripples: warping ? [] : CurtainLights.visible(lights.ripples, limit: CurtainLights.cap),
                               glow: warping ? 0 : lights.glow, hueShift: lights.hueShift,
                               tensePulse: warping ? 0 : lights.tensePulse, shimmer: lights.shimmerSpeed,
                               floes: floes, villageLit: villageLit, keys: keys,
                               ambience: ambience(roles: roles), mood: mood, time: time, warp: warping ? warpFrame : nil)
        frame.auroraPace = 1 + 0.8 * energyEased
        let k = min(1, max(0, (energySlow - 0.35) / 0.65))
        frame.auroraLift = Self.liftAtFull * k * k * (3 - 2 * k)
        frame.gather = gatherEased
        if let sg = surgeState {
            frame.surgeAge = sg.age
            frame.surge = sg.strength * ExcitementStep.envelope(age: sg.age, life: sg.life, rise: 0.5, fall: 3)
            frame.corona = sg.strength * ExcitementStep.envelope(age: sg.age - 0.4, life: sg.life - 1.5, rise: 0.8, fall: 2.5)
        }
        frame.orca = orca()
        frame.surprises = surprises.compactMap { $0 }
        frame.flashRequest = 0.3 * meteors.fireballLight(at: sky.meteorTime)
        frame.energy = x.energy
        frame.tension = x.tension
        return frame
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    private mutating func stepExcitement(_ x: ExcitementStep, dt fd: Float) {
        let now = sky.meteorTime
        meteors.prune(at: now)
        energyEased = ExcitementStep.ease(energyEased, to: x.energy, tau: 2, dt: fd)
        energySlow = ExcitementStep.ease(energySlow, to: x.energy, tau: 6, dt: fd)
        gatherEased = ExcitementStep.ease(gatherEased, to: x.tension, tau: x.tension > gatherEased ? 1.5 : 3, dt: fd)
        // A big moment: the aurora surges, a corona opening overhead; a drop is the whole of it, a little longer.
        if let m = x.moment {
            let strength = m.isDrop ? 1 : ExcitementStep.strength(m)
            let life = m.isDrop ? Self.dropSurgeSeconds : Self.surgeSeconds
            if let sg = surgeState, sg.age < sg.life - 3 {
                surgeState = (sg.age, max(sg.strength, strength), max(sg.life, sg.age + 3))   // never two at once
            } else {
                surgeState = (0, strength, life)
            }
            if m.isDrop { gatherEased = 0 }
        }
        if var sg = surgeState {
            sg.age += fd
            surgeState = sg.age >= sg.life ? nil : sg
            if sg.age < 1.5 { gatherEased = ExcitementStep.ease(gatherEased, to: 0, tau: 0.5, dt: fd) }   // the surge spends it
        }

        // Surprises.
        if let sp = x.surprise { surprised(sp, gentle: x.gentle, now: now) }
        for i in surprises.indices {
            guard var sp = surprises[i] else { continue }
            sp.age += fd
            if sp.kind == .orca { orcaAt.x = min(0.95, max(0.05, orcaAt.x + 0.008 * orcaAt.z * fd)) }
            if sp.age >= sp.duration {
                surprises[i] = nil
                if sp.kind == .satelliteFlare { pass = nil }
            } else {
                surprises[i] = sp
            }
        }
    }

    private func orca() -> FjordOrca? {
        guard let found = surprises.first(where: { $0?.kind == .orca }), let sp = found else { return nil }
        let t = sp.age
        // It surfaces twice, blowing each time (the second fainter), its fin standing out of the still water.
        func rise(_ a: Float, _ b: Float) -> Float { t > a && t < b ? sin(.pi * (t - a) / (b - a)) : 0 }
        let fin = max(rise(0.4, 2.2), rise(5.0, 6.6))
        let blowAge: Float = t >= 5.2 ? t - 5.2 : (t >= 0.7 ? t - 0.7 : -1)
        let blow: Float = t >= 5.2 ? 0.7 : 1
        return FjordOrca(x: orcaAt.x, depth: orcaAt.y, fin: fin, blowAge: blowAge, blow: blow)
    }

    /// The flaring satellite's slot now, while its pass lasts: it glides across the V of sky at about 1.4° a second,
    /// faint, then flares to Venus's brightness for a few seconds (never brighter) and fades again.
    private func satellite() -> SatelliteSlot? {
        guard let p = pass, let found = surprises.first(where: { $0?.kind == .satelliteFlare }), let sp = found else { return nil }
        let f = sp.progress
        let a = simd_normalize(p.from), b = simd_normalize(p.to)
        let dir = simd_normalize(a * (1 - f) + b * f)
        var tangent = b - a - dir * simd_dot(b - a, dir)
        if simd_length(tangent) < 1e-6 { tangent = SIMD3<Float>(1, 0, 0) }
        tangent = simd_normalize(tangent)
        let x = (sp.age - p.peak) / 1.1
        let flare = exp(-x * x)
        let magnitude = 4.5 + (Satellites.venus - 4.5) * flare
        let fade = min(1, sp.age / 1.5) * min(1, (sp.duration - sp.age) / 1.5)
        let light = SatelliteSlot.light(magnitude: magnitude) * max(0, fade)
        let span = acos(min(1, max(-1, simd_dot(a, b))))
        return SatelliteSlot(kind: .satellite, id: Int(sp.seed % 100_000) + 900_000, direction: dir, tangent: tangent,
                             angularSpeed: span / max(sp.duration, 1), magnitude: magnitude, light: light, flare: flare,
                             heightKm: 780, rangeKm: 1300)
    }

    private mutating func surprised(_ s: WorldSurprise, gentle: Bool, now: Double) {
        guard let kind = FjordSurprise.Kind(rawValue: s.index) else { return }
        guard !surprises.contains(where: { $0?.kind == kind }) else { return }
        var r = SeededRandom(seed: s.seed)
        let pole = Self.poleAzimuth(sky)
        switch kind {
        case .fireball:
            // Down the V of sky over the sea end, high to low, ending in a flare (a glow under gentle visuals).
            let way: Double = r.unit() < 0.5 ? -1 : 1
            let start = WorldMeteors.direction(azimuth: pole - way * Double(r.range(12, 20)), altitude: Double(r.range(30, 36)))
            let end = WorldMeteors.direction(azimuth: pole + way * Double(r.range(4, 12)), altitude: Double(r.range(6, 10)))
            meteors.add(WorldMeteors.meteor(from: start, to: end, born: now, duration: r.range(2.6, 3.2),
                                            magnitude: gentle ? -6 : -8, speed: 26, flare: !gentle))
        case .orca:
            orcaAt = SIMD3(r.range(0.44, 0.56), r.range(0.45, 0.7), r.unit() < 0.5 ? -1 : 1)
        case .satelliteFlare:
            let way: Double = r.unit() < 0.5 ? -1 : 1
            let from = WorldMeteors.direction(azimuth: pole - way * 24, altitude: Double(r.range(18, 24)))
            let to = WorldMeteors.direction(azimuth: pole + way * 24, altitude: Double(r.range(28, 34)))
            pass = (from, to, r.range(10, 16))
        }
        let record = FjordSurprise(kind: kind, age: 0, duration: FjordSurprise.duration(kind), seed: s.seed)
        if let free = surprises.firstIndex(where: { $0 == nil }) { surprises[free] = record }
    }

    /// The fjord's soundscape: ice groaning and cracking (more at night), a far waterfall on the right wall, still
    /// water lapping at the jetty, the wind down the fjord; no crickets, no owl.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = MoonlitLakeModel.smooth(-3, -9, sunAlt)
        var levels: [AmbienceSource: Double] = [
            .iceGroan: 0.5 + 0.3 * night,
            .waterfall: 0.35,
            .water: 0.5,
            .wind: min(1, 0.2 + 0.8 * Double(sky.wind)),
            .lapping: 0.3,
            .breeze: 0.2,
            .rainOnWater: Double(sky.rain),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        // Thunder as the lake (the cold sky has no lightning, so it stays quiet unless that changes).
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.45, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension AuroraFjordModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the sky",
                  kind: .choice(visuals), defaultValue: .choice("Curtain Lights")),
        SkyHold.spec(default: .deepNight),
        AuroraMode.spec(default: .always),
        MeteorMode.spec(default: .follow),
        slider("floes", "Ice floes", "Fjord", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How much ice drifts on the water"),
        slider("village", "Village lights", "Fjord", 0...1, 0.7, surprise: 0.3...1,
               help: "The fishing village's lights on the far shore, from dusk"),
        slider("swell", "Swell", "Fjord", 0...1, 0.4, surprise: 0...0.8,
               help: "A slow swell on the still water"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "Ice-blue glass keys along the jetty",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("swell", 0.6), ("floes", 0.4)],
        .speed: [],
        .density: [("floes", 0.8), ("village", 0.4)],
        .glow: [("village", 1)],
        .chaos: [("swell", 0.5)],
        .temperature: [],
    ]
}
