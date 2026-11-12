import Foundation
import simd

/// Everything the Coast Road renderer needs for a frame.
public struct RoadFrame: AmbienceProviding {
    public var sky: SkyState
    public var lights: [CoastLight]
    /// The car's speed, 0…1 of 30…100 km/h (cruise 0.35).
    public var speed: Float
    /// Metres travelled (the renderer wraps it for each layer's scroll).
    public var distance: Double
    /// The chord bloom on the sea's glitter path (0…1) and its hue.
    public var bloom: Float
    public var bloomHue: Float
    /// The swell's four component phases (wrapped) and the last few breaks (white water at the cliff base).
    public var swellPhases: SIMD4<Float>
    public var recent: [Wave]
    public var swellScale: Float
    public var swellTime: Double
    /// The road's gentle curves: the view's roll and yaw in degrees (at most ±1.5° and ±2°).
    public var roll: Double
    public var yaw: Double
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the coast's sky, when it's the chosen visual (notes then streak instead of passing).
    public var warp: WarpFrame?

    // Excitement as the coast road draws it (Fire & Neon spec §5.5). A shooting star is already in `sky`.
    /// The lighthouse on the far point (lit from dusk): its beams' bearing (radians; a beam faces you at 0 and at π) and
    /// their light (0…1; a big moment swells it as a beam sweeps round toward you).
    public var beamAngle: Float = 0
    public var beamLight: Float = 0
    /// Oncoming traffic's headlights washing over the verge as each car passes (Energy brings more): where each wash
    /// is across the window (1 entering at the right … 0 gone at the left) and how bright (0…1).
    public var washes: [CarWash] = []
    /// Tension: headlights gathering round the bend ahead (0…1). The drop: the road comes out of the scrub onto the open
    /// cliff, the sea opening below (0…1).
    public var headlights: Float = 0
    public var open: Float = 0
    /// The surprises: a fox in the scrub, a lit train along the far shore.
    public var fox: RoadFox? = nil
    public var train: RoadTrain? = nil
    public var surprises: [RoadSurprise] = []
    /// The lighthouse's lantern facing you (and a fireball's light): 0…1, before the renderer's flash limiter.
    public var flashRequest: Float = 0
    public var energy: Float = 0
    public var tension: Float = 0
}

/// An oncoming car's headlights washing over the verge (Fire & Neon spec §5.5).
public struct CarWash: Equatable {
    public var x: Float
    public var light: Float
}

/// A fox in the scrub as the car passes (a surprise): where it stands in the passing scrub (metres along the road from
/// where the window's right edge was when it was seen), its trot's phase, and how much of it shows.
public struct RoadFox: Equatable {
    public var along: Double
    public var trot: Float
    public var alpha: Float
}

/// A lit train running along the far shore (a surprise): its head's bearing from the view's centre (radians, + right),
/// its length (radians; + when it runs right, its carriages trailing to the left) and its light (0…1).
public struct RoadTrain: Equatable {
    public var head: Float
    public var length: Float
    public var light: Float
}

/// A coast road surprise playing now (Fire & Neon spec §5.5): a fox crossing the scrub, a far train, a shooting star.
public struct RoadSurprise: Equatable {
    public enum Kind: Int, CaseIterable { case fox, train, shootingStar }
    public var kind: Kind
    public var age: Float
    public var duration: Float
    public var seed: UInt64

    public static func duration(_ k: Kind) -> Float {
        switch k {
        case .fox: return 7
        case .train: return 26
        case .shootingStar: return 2.5
        }
    }
    public var progress: Float { min(1, max(0, age / max(duration, 1e-3))) }
}

/// Set 4's world: the passenger seat on a coast road high above the sea, the window looking out over cliffs
/// and swell at blue hour. Its visual, Coast Lights, turns notes into lights streaming past; playing speeds
/// the car up, chords bloom the glitter on the sea.
public struct CoastRoadModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = RoadFrame
    public static let id = "coast-road"
    public static let displayName = "Coast Road"
    public static let visuals = ["Coast Lights", "Galaxy Warp"]
    /// A fox crossing, a far train, a shooting star (Fire & Neon spec §5.5).
    public static let surpriseCount = RoadSurprise.Kind.allCases.count
    /// The lighthouse on the far point, from the eye (metres: across to the right, out to sea, up): 20° to the right
    /// of the view, about 5 km off, its lantern 80 m over the sea (the road is 60 m up).
    public static let lighthouse = SIMD3<Float>(1750, 4800, 20)
    /// Its two beams turn once in 16 s; a big moment's sweep crosses toward you at 0.75 rad/s.
    public static let beamTurn: Float = 2 * .pi / 16, sweepTurn: Float = 0.75
    /// The traffic washes' pool.
    public static let washCount = 3

    /// The sway's periods (seconds): slow enough never to feel queasy.
    static let rollPeriod = 11.0, yawPeriod = 17.0

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var swell = OceanSwell(seed: 0xC0A5)
    private var coast = CoastLights()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held = Set<UInt8>()
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xC0A)

    // Excitement (Fire & Neon spec §5.5): fixed pools throughout.
    private var excite = ExcitementFrame()
    private var rng = SeededRandom(seed: 0xC0A5_7E1E)
    private var meteors = WorldMeteors()
    private var energyEased: Float = 0
    private var gather: Float = 0
    private var beam: Float = 0.6
    private var turn: Float = CoastRoadModel.beamTurn
    /// The moment's sweep: its age, the beam's bearing when it began and how far it must turn to come round, its strength.
    private var sweep: (age: Float, from: Float, by: Float, strength: Float)?
    private var washPool = [CarWash](repeating: CarWash(x: -1, light: 0), count: CoastRoadModel.washCount)
    private var washDebt: Float = 0
    private var openAge: Float?
    private var surprises: [RoadSurprise?] = [nil, nil, nil]
    private var foxSeen: Double = 0
    private var trainFrom: Float = 0
    private var trainWay: Float = 1

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// Where the window looks: out over the low sun or the moon, else out to sea (the road's curves add their yaw).
    public static func viewAzimuth(_ s: SkyState) -> Double {
        if s.sun.altitude > -12, s.sun.altitude < 25 { return s.sun.azimuth }
        if s.moon.altitude > -5 { return s.moon.azimuth }
        return s.latitude < 0 ? 0 : 180
    }

    /// The lighthouse is lit from dusk (the sun below 2°), as the road's lamps are.
    public static func lighthouseLit(sunAltitude: Double) -> Float {
        let t = min(1, max(0, (2 - sunAltitude) / 3))
        return Float(t * t * (3 - 2 * t))
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> RoadFrame {
        time += dt
        coast.trails = Float(p.number("lights.trails"))
        coast.speedResponse = Float(p.number("speed.response"))
        coast.bloomAmount = Float(p.number("bloom"))
        coast.reactionScale = MoodLook.reactionScale(mood)
        coast.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held.insert(note)
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { coast.noteOn(note, velocity: v, at: time) }
                if (21...108).contains(note) { keyGlow[Int(note) - 21] = max(keyGlow[Int(note) - 21], velocity * 0.7) }
            case let .noteOff(note):
                held.remove(note)
                coast.noteOff(note)
                warp.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                coast.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        let x = ExcitementStep.take(&excite)
        let fd = Float(max(0, dt.isFinite ? dt : 0))
        energyEased = ExcitementStep.ease(energyEased, to: x.energy, tau: x.energy > energyEased ? 1 : 4, dt: fd)
        coast.push = energyEased
        coast.step(dt: dt, roles: roles)
        stepExcitement(x, dt: fd, warping: warping)
        swell.scale = OceanSwell.weatherScale(sky)
        let breaks = swell.step(dt: dt)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Dashboard amber on the keys while held, then fading.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 where !held.contains(UInt8(i + 21)) { keyGlow[i] *= fall }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held.contains(k.note), glow: keyGlow[Int(k.note) - 21]) }

        let sway = p.number("sway")
        let roll = 1.5 * sway * sin(2 * .pi * time.truncatingRemainder(dividingBy: Self.rollPeriod) / Self.rollPeriod)
        let yaw = 2 * sway * sin(2 * .pi * time.truncatingRemainder(dividingBy: Self.yawPeriod) / Self.yawPeriod + 1)

        var shown = sky
        meteors.inject(into: &shown)
        var frame = RoadFrame(sky: shown, lights: coast.lights, speed: coast.speed, distance: coast.distance,
                              bloom: coast.bloom, bloomHue: coast.bloomHue, swellPhases: swell.phases(at: swell.time),
                              recent: swell.recent, swellScale: swell.scale, swellTime: swell.time, roll: roll, yaw: yaw, keys: keys,
                              ambience: ambience(roles: roles, breaks: breaks), mood: mood, time: time,
                              warp: warping ? warpFrame : nil)
        let lit = Self.lighthouseLit(sunAltitude: sky.sun.altitude)
        let swelling: Float = sweep.map { sw -> Float in
            sw.strength * ExcitementStep.envelope(age: sw.age, life: 5, rise: 0.8, fall: 2)
        } ?? 0
        frame.beamAngle = beam
        frame.beamLight = min(1, lit * (0.25 + 0.75 * swelling))
        frame.washes = lit > 0.05 ? washPool.filter { $0.light > 0.005 && $0.x > -0.2 } : []
        frame.headlights = gather * lit
        frame.open = openAge.map { ExcitementStep.envelope(age: $0, life: 16, rise: 1.2, fall: 6) } ?? 0
        frame.fox = fox()
        frame.train = trainNow(lit: lit)
        frame.surprises = surprises.compactMap { $0 }
        // A beam facing you flares the lantern (every 8 s faintly; at full light in a sweep).
        let off = Self.facing(beam)
        frame.flashRequest = max(0.3 * frame.beamLight * exp(-off * off / 0.0016), 0.3 * meteors.fireballLight(at: sky.meteorTime))
        frame.energy = x.energy
        frame.tension = x.tension
        return frame
    }

    /// How far (radians) the nearer of the two beams is from facing you.
    public static func facing(_ angle: Float) -> Float {
        guard angle.isFinite else { return .pi / 2 }
        var a = angle.truncatingRemainder(dividingBy: .pi)
        if a < 0 { a += .pi }
        return min(a, .pi - a)
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    private mutating func stepExcitement(_ x: ExcitementStep, dt fd: Float, warping: Bool) {
        let now = sky.meteorTime
        meteors.prune(at: now)
        // A big moment: the lighthouse's beam sweeps round toward you, swelling. The drop: the road opens onto the sea.
        if let m = x.moment {
            // Turn the nearer beam (they are half a turn apart) round to 1.1 rad short of facing you, quickly while it is
            // still dim, then sweep it across you.
            var by = (-1.1 - beam).truncatingRemainder(dividingBy: .pi)
            if by < 0 { by += .pi }
            sweep = (0, beam, by, ExcitementStep.strength(m))
            if m.isDrop { openAge = 0 }
        }
        if var s = sweep {
            s.age += fd
            if s.age < 0.6 {
                let k = s.age / 0.6
                beam = s.from + s.by * k * k * (3 - 2 * k)
                turn = Self.sweepTurn
            } else {
                beam += turn * fd
                if s.age > 3.6 { turn = ExcitementStep.ease(turn, to: Self.beamTurn, tau: 1, dt: fd) }
            }
            sweep = s.age > 6 ? nil : s
        } else {
            turn = ExcitementStep.ease(turn, to: Self.beamTurn, tau: 1, dt: fd)
            beam += turn * fd
        }
        if beam > 2 * .pi { beam -= 2 * .pi } else if beam < 0 { beam += 2 * .pi }
        if let a = openAge { openAge = a + fd > 16 ? nil : a + fd }
        gather = ExcitementStep.ease(gather, to: x.tension, tau: x.tension > gather ? 1.5 : 3, dt: fd)
        if openAge != nil { gather = ExcitementStep.ease(gather, to: 0, tau: 0.5, dt: fd) }

        // Oncoming traffic, by Energy and the gathering headlights: each car's lights sweep the verge right to left.
        for i in washPool.indices where washPool[i].x > -0.2 {
            washPool[i].x -= fd / 0.9
            if washPool[i].x <= -0.2 { washPool[i].light = 0 }
        }
        if fd > 0, !warping {
            washDebt += (0.3 * energyEased * energyEased + 0.7 * gather) * fd
            while washDebt >= 1 {
                washDebt -= 1
                if let free = washPool.firstIndex(where: { $0.x <= -0.2 }) {
                    washPool[free] = CarWash(x: 1.1, light: rng.range(0.5, 1) * (0.6 + 0.4 * max(energyEased, gather)))
                }
            }
        }

        // Surprises.
        if let sp = x.surprise { surprised(sp, gentle: x.gentle, now: now) }
        for i in surprises.indices {
            guard var sp = surprises[i] else { continue }
            sp.age += fd
            surprises[i] = sp.age >= sp.duration ? nil : sp
        }
    }

    private func fox() -> RoadFox? {
        guard let found = surprises.first(where: { $0?.kind == .fox }), let sp = found else { return nil }
        let alpha = min(1, sp.age / 0.4) * min(1, (sp.duration - sp.age) / 0.4)
        return RoadFox(along: coast.distance - foxSeen, trot: sp.age * 9, alpha: max(0, alpha))
    }

    private func trainNow(lit: Float) -> RoadTrain? {
        guard let found = surprises.first(where: { $0?.kind == .train }), let sp = found else { return nil }
        let light = min(1, sp.age / 2) * min(1, (sp.duration - sp.age) / 2) * max(0.35, lit)
        return RoadTrain(head: trainFrom + trainWay * 0.028 * sp.age, length: 0.09 * trainWay, light: max(0, light))
    }

    private mutating func surprised(_ s: WorldSurprise, gentle: Bool, now: Double) {
        guard let kind = RoadSurprise.Kind(rawValue: s.index) else { return }
        guard !surprises.contains(where: { $0?.kind == kind }) else { return }
        var r = SeededRandom(seed: s.seed)
        switch kind {
        case .fox:
            foxSeen = coast.distance
        case .train:
            trainWay = r.unit() < 0.5 ? -1 : 1
            trainFrom = -trainWay * r.range(0.25, 0.4)
        case .shootingStar:
            // Low over the sea (the window shows the sky to about 15°): a quick one with a short train.
            let view = Self.viewAzimuth(sky)
            let rightward = r.unit() < 0.5
            let a = view + (rightward ? -1 : 1) * Double(r.range(14, 22))
            let b = view + (rightward ? 1 : -1) * Double(r.range(0, 8))
            let start = WorldMeteors.direction(azimuth: a, altitude: Double(r.range(11, 14)))
            let end = WorldMeteors.direction(azimuth: b, altitude: Double(r.range(3, 6)))
            meteors.add(WorldMeteors.meteor(from: start, to: end, born: now, duration: r.range(0.7, 1.0),
                                            magnitude: gentle ? -1.5 : -3, speed: 62, flare: false))
        }
        let record = RoadSurprise(kind: kind, age: 0, duration: RoadSurprise.duration(kind), seed: s.seed)
        if let free = surprises.firstIndex(where: { $0 == nil }) { surprises[free] = record }
    }

    /// The drive's soundscape: road and engine under the window's rush, the surf far below thumping with each
    /// break, now and then a passing car; rain on the glass.
    private mutating func ambience(roles: RoleValues, breaks: [Wave]) -> AmbienceScene {
        let night = MoonlitLakeModel.smooth(-3, -9, sky.sun.altitude)
        var levels: [AmbienceSource: Double] = [
            .road: 0.8,
            .engine: 0.6,
            .windowWind: 0.5,
            .surf: 0.5,
            .passingCar: 0.3 + 0.4 * Double(energyEased),   // Energy brings the traffic
            .rainOnGlass: Double(sky.rain),
        ]
        if sky.wind > 0.6 { levels[.wind] = Double(sky.wind - 0.6) * 2 }
        WeatherAmbience.levels(sky, base: &levels)
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        let wave = breaks.map { Double($0.strength) }.max()
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             wave: wave, speed: Double(coast.speed), surfDistance: 0.9, indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension CoastRoadModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the drive",
                  kind: .choice(visuals), defaultValue: .choice("Coast Lights")),
        SkyHold.spec(default: .blueHour),
        MeteorMode.spec(default: .follow),
        slider("lights.trails", "Light trails", "Coast Lights", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How long the passing lights streak"),
        slider("speed.response", "Speed response", "Coast Lights", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How much your playing speeds the car up"),
        slider("bloom", "Glitter bloom from chords", "Coast Lights", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords bloom the glitter on the sea in their colour"),
        slider("lamps", "Lamps", "Coast Road", 0...1, 0.8, surprise: 0.3...1, help: "Road lamps lit from dusk"),
        slider("fog", "Sea fog", "Coast Road", 0...1, 0.3, surprise: 0...0.8, help: "Fog rolling in off the sea"),
        slider("sway", "Sway", "Coast Road", 0...1, 0.5, help: "How much the road's curves sway the view (never more than a gentle lean)"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the dashboard",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("lights.trails", 0.8), ("bloom", 0.6)],
        .speed: [("speed.response", 1)],
        .density: [("lamps", 0.6)],
        .glow: [("bloom", 1), ("lamps", 0.5)],
        .chaos: [("sway", 0.4)],
        .temperature: [],
    ]
}
