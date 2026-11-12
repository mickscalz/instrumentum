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
}

/// Set 2's world: a softly lit lounge with a big window on Earth, the Moon and deep stars.
/// Its visual, Galaxy Warp, streaks stars past the window as you play.
public struct SpaceshipLoungeModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = LoungeFrame
    public static let id = "spaceship-lounge"
    public static let displayName = "Spaceship Lounge"
    public static let visuals = ["Galaxy Warp"]
    /// The lounge drifts east over Earth, one turn every two hours.
    public static let orbitSeconds = 7200.0

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

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
        let w = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Keys glow console blue while held, then fade.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.0 : 0.25)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        let ambience = AmbienceScene(levels: [.shipHum: 0.8, .airFlow: 0.5, .chime: 0.25, .hullTicks: 0.25],
                                     nightCool: 0, activity: activity, thunder: nil,
                                     closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood))
        let lon = Self.viewerLongitude(sky, time: time)
        return LoungeFrame(sky: sky, warp: w, earthRotation: Float(lon * .pi / 180), keys: keys, ambience: ambience,
                           mood: mood, time: time)
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
