import Foundation
import simd

/// Everything the Spaceship Lounge renderer needs for a frame.
public struct LoungeFrame: AmbienceProviding {
    /// Space has no weather: clouds, rain, snow, mist and wind are zero, stars always out.
    public var sky: SkyState
    public var warp: WarpFrame
    /// The longitude (radians, east positive) the lounge floats above: Earth turns beneath the window.
    public var earthRotation: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Excitement (Fire & Neon spec §5.5): the warp jump's stretch (0…1, the stars drawn out into lines, already in
    /// `warp`'s speed), the light of its arrival as they snap back (0…1, before the flash limiter), the drive's charge
    /// gathering at the vanishing point with tension (0…1), the drawn Energy, and the surprises playing (0 a comet, 1 a
    /// far ship's lights, 2 a pulsar).
    public var jump: Float = 0
    public var arrival: Float = 0
    public var charge: Float = 0
    public var energy: Float = 0
    public var surprises: [PlayingSurprise] = []
    public var reduceMotion = false
}

/// Set 2's world: a softly lit lounge with a big window on Earth, the Moon and deep stars.
/// Its visual, Galaxy Warp, streaks stars past the window as you play.
public struct SpaceshipLoungeModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = LoungeFrame
    public static let id = "spaceship-lounge"
    public static let displayName = "Spaceship Lounge"
    public static let visuals = ["Galaxy Warp"]
    /// The lounge drifts east over Earth, one turn every two hours.
    public static let orbitSeconds = 7200.0
    /// The surprises (spec §5.5): a comet passing the window, a far ship's lights, a pulsar's blink.
    public static let surpriseCount = 3
    public static let surpriseSeconds: [Float] = [16, 14, 10]
    /// The warp jump (spec §5.5): the stars stretch over 0.45 s, hold this long from the start (a drop's longer), snap back
    /// in 0.18 s, and the arrival's light fades; the moment lasts `momentSeconds` (a drop's `dropSeconds`).
    public static let jumpHold: Float = 1.2, dropHold: Float = 1.9
    public static let momentSeconds: Float = 2.4, dropSeconds: Float = 3.2
    /// How far a full jump adds to the warp's speed (its 0.1 drift … 1 full warp), and the speed Energy holds it to at least.
    public static let jumpBoost: Float = 1.3
    public static let energySpeed: Float = 0.45

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var excite = ExcitementFrame()
    private var play = ExcitementPlay()

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// The warp jump's stretch `age` seconds into a jump held `hold` seconds: drawn out over 0.45 s, held, snapped back in
    /// 0.18 s (0…1).
    public static func stretch(age: Float, hold: Float) -> Float {
        guard age.isFinite, age >= 0 else { return 0 }
        return ExcitementPlay.smooth(0, 0.45, age) * (1 - ExcitementPlay.smooth(hold, hold + 0.18, age))
    }

    /// The arrival's light as the stars snap back: in over about 0.06 s at the snap, out with τ 0.35 s (0…1).
    public static func arrival(age: Float, hold: Float) -> Float {
        let since = age - hold
        guard since.isFinite, since > 0 else { return 0 }
        return (1 - exp(-since / 0.06)) * exp(-since / 0.35)
    }

    public mutating func setSky(_ s: SkyState) { sky = Self.weatherless(s) }

    /// Space has no weather: the sky's clock, sun and moon without cloud (or its iridescence), rain, frost, rime,
    /// halos, wetness, gusts or sea smoke; and no air for meteors to burn in (no meteors, fireball flash or shower); nor
    /// any storm (no crawlers, sheet lightning, gust front, virga, supercell, far storm or sprites), and no satellites
    /// crossing a sky it is already among.
    static func weatherless(_ s: SkyState) -> SkyState {
        var s = s
        s.weather = .clear; s.nextWeather = .clear; s.weatherBlend = 0
        s.cloudCover = 0; s.rain = 0; s.snow = 0; s.mist = 0; s.wind = 0; s.lightning = 0
        s.halo = 0; s.frost = 0; s.wetness = 0; s.gust = 0
        s.aurora = 0; s.auroraStorm = 0; s.fireflies = 0; s.diamondDust = 0; s.pillar = 0
        s.rime = 0; s.iridescence = 0
        s.steam = 0; s.meteors = []; s.meteorFlash = 0; s.shower = nil; s.meteorRate = 0
        s.crawlers = []; s.sheet = []; s.stormFlash = 0; s.outflow = 0; s.gustFront = nil; s.warmthGrade = 0
        s.virga = 0; s.farStorm = 0; s.supercell = 0; s.supercellPhase = 0
        s.farStormNow = nil; s.sprites = []; s.satellites = []
        s.supercellWeather = nil; s.hail = 0; s.ash = 0; s.embers = 0; s.sunTint = SIMD3(1, 1, 1); s.moonTint = SIMD3(1, 1, 1)
        s.starVisibility = 1
        return s
    }

    /// The longitude below the lounge: where the local solar hour matches the sky's hour, plus the orbit's drift.
    static func viewerLongitude(_ s: SkyState, time: Double) -> Double {
        var lon = s.subsolar.longitude + (s.hourOfDay - 12) * 15 + 360 * time / orbitSeconds
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return lon
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> LoungeFrame {
        time += dt
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
            case let .noteOff(note):
                held[note] = nil
                warp.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        var w = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Excitement (spec §5.5): Energy speeds the stars; a moment is the warp jump (the stars stretch, then snap back);
        // tension charges the drive at the vanishing point and raises the hum, and a drop is the jump at its longest.
        // Reduce Motion keeps the warp adrift: no speed from Energy, no stretch, only the arrival's soft light.
        let e = excite
        excite.moment = nil
        excite.surprise = nil
        play.step(dt: dt, frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        let reduce = play.reduceMotion
        var jump: Float = 0, arrival: Float = 0
        if let m = play.moment {
            let hold = m.isDrop ? Self.dropHold : Self.jumpHold
            jump = Self.stretch(age: m.age, hold: hold) * m.strength
            arrival = Self.arrival(age: m.age, hold: hold) * m.strength
        }
        if !reduce {
            w.warpSpeed = max(w.warpSpeed, 0.1 + Self.energySpeed * play.energy) + Self.jumpBoost * jump
        }

        // Keys glow console blue while held, then fade.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.0 : 0.25)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        // The hum rises with the tension (the drive spooling up), the air a little with Energy.
        let hum = Double(0.8 + 0.2 * play.tension), air = Double(0.5 + 0.15 * play.energy)
        let ambience = AmbienceScene(levels: [.shipHum: hum, .airFlow: air, .chime: 0.25, .hullTicks: 0.25],
                                     nightCool: 0, activity: activity, thunder: nil,
                                     closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood))
        let lon = Self.viewerLongitude(sky, time: time)
        var frame = LoungeFrame(sky: sky, warp: w, earthRotation: Float(lon * .pi / 180), keys: keys, ambience: ambience,
                                mood: mood, time: time)
        frame.jump = reduce ? 0 : jump
        frame.arrival = arrival
        frame.charge = play.tension
        frame.energy = play.energy
        frame.surprises = play.surprises
        frame.reduceMotion = reduce
        return frame
    }
}

extension SpaceshipLoungeModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws past the window",
                  kind: .choice(visuals), defaultValue: .choice("Galaxy Warp")),
        slider("warp.trails", "Star trails", "Galaxy Warp", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How long the streaking stars' trails are"),
        slider("nebula", "Nebula glow", "Galaxy Warp", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How brightly chords bloom the nebula"),
        slider("earth.size", "Earth size", "Window", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How much of the window Earth fills"),
        slider("interior.glow", "Lounge glow", "Window", 0...1, 0.5, surprise: 0.2...0.8,
               help: "The warm light inside the lounge"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A console keyboard under the window",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("warp.trails", 0.7), ("nebula", 0.5)],
        .speed: [],
        .density: [("nebula", 0.4)],
        .glow: [("interior.glow", 0.6), ("nebula", 0.6)],
        .chaos: [("warp.trails", 0.4)],
        .temperature: [("interior.glow", 0.5)],
    ]
}
