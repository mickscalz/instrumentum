import Foundation
import simd

/// Everything the Snowbound Cabin renderer needs for a frame.
public struct CabinFrame: AmbienceProviding {
    /// The sky after `coldSky`: rain falls as snow, storms are blizzards, no lightning, never wet.
    public var sky: SkyState
    /// The frost level on the glass (0…0.85) and the warm patches notes melt in it.
    public var frostLevel: Float
    public var patches: [FrostPatch]
    /// The fire's flare from chords (0…1) and its colour (1 gold, 0 ember, 0.5 between).
    public var flare: Float
    public var flareWarm: Float
    /// High notes this frame: flakes near these x (0…1 across the window) catch the light.
    public var flakeGlints: [Float]
    /// The fire's light, flickering (0…1, deterministic).
    public var fireFlicker: Float
    /// The far cabin's window is lit (dusk until late at night).
    public var farCabinLit: Bool
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp past the window, when it's the chosen visual (notes then streak instead of melting patches).
    public var warp: WarpFrame?
    /// Excitement (Fire & Neon spec §5.5): the fire roaring up (0…1 × the moment's strength, before the flash limiter),
    /// the snow whirling past the glass (0…1), the wind gathering with tension (0…1), the gust after a drop (0…1), the
    /// drawn Energy, and the surprises playing (0 an owl on the sill, 1 the aurora's edge, 2 a star through a break in
    /// the clouds).
    public var roar: Float = 0
    public var whirl: Float = 0
    public var gather: Float = 0
    public var gust: Float = 0
    public var energy: Float = 0
    public var surprises: [PlayingSurprise] = []
    public var reduceMotion = false
}

/// Set 5's world: a log cabin's window on a snowy valley at night or day, frost on the glass, the fire behind you.
/// Its visual, Frost Grow, lets the frost creep further while you hold notes, and each note melts a warm patch.
public struct SnowboundCabinModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = CabinFrame
    public static let id = "snowbound-cabin"
    public static let displayName = "Snowbound Cabin Window"
    public static let visuals = ["Frost Grow", "Galaxy Warp"]
    /// The surprises (spec §5.5): an owl on the sill, the aurora's edge, a star through a break in the clouds. The aurora
    /// and the star need the dark: by day the owl comes instead.
    public static let surpriseCount = 3
    public static let surpriseSeconds: [Float] = [10, 18, 12]
    /// The fire roars up (spec §5.5) for this long (a drop's, the gust's release, longer).
    public static let momentSeconds: Float = 4.5, dropSeconds: Float = 5.5

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var frost = FrostGrow()
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

    /// The surprise that plays for `index` under this sky: the aurora's edge and the star need the sun 10° down (the owl
    /// comes by day instead).
    static func available(_ index: Int, sky: SkyState) -> Int {
        let dark = sky.sun.altitude.isFinite && sky.sun.altitude < -10
        return index == 0 || dark ? index : 0
    }

    /// The fire's roar `age` seconds into a moment `life` long: up in 0.35 s, held, dying back over its last 3 s (0…1).
    public static func roar(age: Float, life: Float) -> Float {
        ExcitementPlay.envelope(age: age, life: life, rise: 0.35, fall: 3)
    }

    /// The snow whirling past the glass: the eddy rises in 0.6 s and blows itself out over 2.5 s (0…1).
    public static func whirl(age: Float, life: Float) -> Float {
        ExcitementPlay.envelope(age: age, life: min(life, 3.6), rise: 0.6, fall: 2.5)
    }

    public mutating func setSky(_ s: SkyState) { sky = Self.coldSky(s) }

    /// It's cold here (shared with every cold world as `WorldWeather.cold`).
    public static func coldSky(_ s: SkyState) -> SkyState { WorldWeather.cold(s) }

    /// The fire's flicker: a few incommensurate wobbles, always 0…1.
    static func flicker(_ t: Double) -> Float {
        let w = 0.5 * sin(t * 7.3) + 0.3 * sin(t * 13.1 + 1.3) + 0.2 * sin(t * 23.7 + 2.1) + 0.15 * sin(t * 3.1 + 0.4)
        return Float(min(1, max(0, 0.72 + 0.24 * w)))
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> CabinFrame {
        time += dt
        frost.frost = Float(p.number("frost"))
        frost.reactionScale = MoodLook.reactionScale(mood)
        frost.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    frost.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                frost.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                frost.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                frost.allNotesOff(); frost.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        frost.step(dt: dt, baseFrost: sky.frost * frost.frost, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // Excitement (spec §5.5): Energy brings the snow down thicker and flares the fire; a moment roars the fire up and
        // whirls the snow past the glass; tension raises the wind, and a drop is the gust. The surprises that need the
        // dark come only in the dark (the owl otherwise); the aurora's edge is the shared sky's own, called here.
        var e = excite
        excite.moment = nil
        excite.surprise = nil
        if let sp = e.surprise { e.surprise = WorldSurprise(index: Self.available(sp.index, sky: sky), seed: sp.seed) }
        play.step(dt: dt, frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        let energy = play.energy
        var roar: Float = 0, whirl: Float = 0, gust: Float = 0
        if let m = play.moment {
            roar = Self.roar(age: m.age, life: m.duration) * m.strength
            whirl = Self.whirl(age: m.age, life: m.duration) * m.strength
            if m.isDrop { gust = max(play.drop, whirl) }
        }
        var shown = sky
        let snow = ExcitementPlay.unit(sky.snow)
        shown.snow = min(1, snow + (1 - snow) * (0.3 * energy + 0.45 * whirl))
        let windNow = ExcitementPlay.unit(sky.wind)
        shown.wind = min(1, windNow + 0.45 * play.tension + 0.5 * whirl + 0.4 * gust)
        shown.gust = min(1, ExcitementPlay.unit(sky.gust) + 0.35 * play.tension + 0.6 * max(whirl, gust))
        if let a = play.surprise(1) {
            // The aurora's edge: a band low over the far peaks, rising and fading (the shared sky draws it).
            let edge = ExcitementPlay.envelope(age: a.age, life: a.duration, rise: 4, fall: 5)
            shown.aurora = max(shown.aurora, 0.55 * edge)
            if edge > 0.01, sky.aurora < 0.05 {
                shown.auroraAltitude = 12
                shown.auroraAlways = true
                shown.auroraStorm = max(shown.auroraStorm, 0.25)
            }
        }

        // Keys glow ember amber while held, then fade.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let hour = sky.hourOfDay
        let farCabinLit = p.number("farCabin") > 0.02 && sky.sun.altitude < -4 && !(hour >= 1 && hour < 5)
        // Energy flares the fire a little (as a chord does); its roar is the renderer's to light, through the flash
        // limiter. The draught of a rising wind bows the flames.
        let flare = max(frost.flare, 0.35 * energy)
        let flicker = Self.flicker(time) * (1 - 0.15 * play.tension)

        var frame = CabinFrame(sky: shown, frostLevel: frost.level, patches: warping ? [] : frost.patches,
                               flare: flare, flareWarm: frost.flareWarm, flakeGlints: frost.flakeGlints,
                               fireFlicker: flicker, farCabinLit: farCabinLit, keys: keys,
                               ambience: ambience(roles: roles, params: p, sky: shown, roar: roar), mood: mood, time: time,
                               warp: warping ? warpFrame : nil)
        frame.roar = roar
        frame.whirl = whirl
        frame.gather = play.tension
        frame.gust = gust
        frame.energy = energy
        frame.surprises = play.surprises
        frame.reduceMotion = play.reduceMotion
        return frame
    }

    /// The cabin's soundscape: the fire (roaring with a moment), the wind round the walls (rising with the tension), snow
    /// ticking on the glass; all heard indoors.
    private func ambience(roles: RoleValues, params p: ParameterSet, sky: SkyState, roar: Float) -> AmbienceScene {
        var levels: [AmbienceSource: Double] = [
            .fire: min(1, 0.7 * p.number("fire") * (1 + 0.6 * Double(roar))),
            .wind: min(1, 0.25 + Double(sky.gust)),
            .rainOnGlass: 0.4 * Double(sky.snow),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.7, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: 1, wetness: 0, snowOnGlass: Double(sky.snow))
    }
}

extension SnowboundCabinModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the window",
                  kind: .choice(visuals), defaultValue: .choice("Frost Grow")),
        SkyHold.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        slider("frost", "Frost", "Frost Grow", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How far the frost creeps over the glass while you hold notes"),
        slider("fire", "Fire glow", "Cabin", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "The fire behind you: its light on the frame and its crackle"),
        slider("condensation", "Condensation", "Cabin", 0...1, 0.4, surprise: 0...0.8,
               help: "A soft fog along the bottom of the panes"),
        slider("farCabin", "Distant cabin", "Cabin", 0...1, 0.7, surprise: 0...1,
               help: "A far cabin across the valley whose window lights up at dusk"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard below the sill",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("frost", 0.6), ("fire", 0.6)],
        .speed: [],
        .density: [("condensation", 0.5), ("frost", 0.4)],
        .glow: [("fire", 1), ("farCabin", 0.4)],
        .chaos: [("frost", 0.3)],
        .temperature: [("fire", 0.8)],
    ]
}
