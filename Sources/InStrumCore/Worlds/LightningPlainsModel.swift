import Foundation
import simd

/// Everything the Lightning Plains renderer needs for a frame (Storms spec §9.2).
public struct PlainsFrame: AmbienceProviding {
    /// The Living Sky over the plain: warm (no snow, frost or sea smoke), with the storm's heat lightning added to its
    /// sheet slots, the storm on the horizon (`farStorm` 1) and the storm's own rain (never under virga).
    public var sky: SkyState
    /// Which way the camera looks (degrees from north): west, turned toward the sunset, where the storm stands.
    public var cameraAzimuth: Double
    public var stormBearing: Double
    /// The storm's distance: 0 (40 km out) … 1 (overhead), and in kilometres.
    public var distance: Float
    public var distanceKm: Double
    /// The forks in the sky now (each: its origin, 4–7 branches, its age and light).
    public var strikes: [Fork]
    /// The towers' own flashes (heat lightning inside them, and every note's flicker).
    public var towerFlash: [TowerFlash]
    /// Crawlers across the towers (runs', and the storm's own), in the sky's (azimuth, altitude), lit for this instant.
    public var crawlers: [CrawlerSlot]
    /// The drop's sheet-lit sky (0…1, before the renderer's flash limiter).
    public var sheetLit: Float
    /// The rain curtain: 0 none, rising to 1 as it crosses to you (and 1 while its rain falls); how far off it is (km).
    public var rainCurtain: Float
    public var curtainKm: Double?
    /// The storm's rain on you (0…1), or under virga its streaks hanging dry.
    public var rain: Float
    /// Virga: the strikes come dry.
    public var dry: Bool
    /// The windmill: its wheel's speed (turns a minute) and where it has turned to (radians).
    public var windmillRPM: Float
    public var windmillAngle: Float
    /// How hard the wind leans the grass (0…1), and the wind field itself (the renderer samples it per grass row).
    public var grassLean: Float
    public var wind: WindField
    /// The camera's shake now (pixels; ≤ 6, only for a close strike).
    public var cameraShake: SIMD2<Float>
    /// The fence posts lit by your notes (the keys): which, and how brightly (brighter with each repeat).
    public var postLit: [PostLight]
    public var ballLightning: BallLightning?
    public var dustDevil: DustDevil?
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the plain, when it's the chosen visual (notes then streak instead of striking).
    public var warp: WarpFrame?
}

/// Set 18's world: a dry grass plain at dusk under a vast sky. A windmill and a water tank on the left, a fence line
/// running away from you (its 88 posts are the keys), a far ridge on the right; on the western horizon a line of storm
/// towers lit from inside, which walks closer as you play and back out when you rest. Its visual, Strike Lines, lands a
/// strike for every repeat of the same key.
public struct LightningPlainsModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, InstrumentAware, SurpriseListing {
    public typealias Frame = PlainsFrame
    public static let id = "lightning-plains"
    public static let displayName = "Lightning Plains"
    public static let visuals = ["Strike Lines", "Galaxy Warp"]
    public static var surpriseCount: Int { StrikeLines.surpriseCount }

    /// The camera looks west (the storm on the western horizon); toward the sunset, so the afterglow stands behind the
    /// towers: wholly while the light is held, and while it follows the sky as the low sun nears the west.
    public static let west = 270.0
    /// The sunset sits this far left of the middle (degrees), behind the windmill's side of the storm.
    public static let sunsetOffset = 15.0
    public static let cameraTau = 30.0

    public var mood = Mood.neutral
    public var instrumentPressure: Float = 0
    public var instrumentRepeat = false
    /// The morph the storm forces on the grand: .8 for the drop's 2.5 s.
    public var forcedMorph: Float? { lines.forcedMorph }

    var lines = StrikeLines()
    private var sky = SkyState()
    private var excitement = ExcitementFrame()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var postBoost = [Float](repeating: 0.45, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var camera: Double?
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0x9_1A1E_7D)

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// It's warm on the plain (`WorldWeather.warm`: snow falls as rain, no frost, rime or sea smoke), and no fireflies.
    public mutating func setSky(_ s: SkyState) {
        var warm = WorldWeather.warm(s)
        warm.fireflies = 0
        sky = warm
    }

    public mutating func setExcitement(_ e: ExcitementFrame) { excitement = e }

    // MARK: - The camera

    /// Where the camera wants to look (degrees from north): west; toward the sunset (15° right of the sun, so the glow
    /// is behind the towers' left) wholly while the light is held, and while following the sky as the sun comes down
    /// within 60° of west.
    public static func cameraTarget(_ s: SkyState, held: Bool) -> Double {
        let alt = s.sun.altitude, az = s.sun.azimuth
        guard alt.isFinite, az.isFinite else { return west }
        let toward = turn(from: west, to: az + sunsetOffset)
        let near = 1 - StrikeLines.smooth(45, 60, abs(turn(from: west, to: az)))
        let low = 1 - StrikeLines.smooth(4, 12, alt)
        let w = held ? 1 : near * low
        return norm(west + toward * w)
    }

    static func turn(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    static func norm(_ a: Double) -> Double {
        let x = a.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    static func index(_ note: UInt8) -> Int? {
        let i = Int(note) - 21
        return (0..<88).contains(i) ? i : nil
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> PlainsFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        if let lastVisual, lastVisual != visual { warp.allNotesOff() }
        lastVisual = visual
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping { warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time) }
                lines.noteOn(note, velocity: velocity, at: time, repeating: instrumentRepeat, striking: !warping)
                if let i = Self.index(note) { postBoost[i] = lines.postBrightness(note) }
            case let .noteOff(note):
                held[note] = nil
                warp.noteOff(note)
                lines.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                warp.allNotesOff()
                lines.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // The camera turns (τ 30 s, the short way round) toward where it wants to look; it arrives looking there.
        let holding = (SkyHold(rawValue: p.choice("light.hold")) ?? .follow) != .follow
        let target = Self.cameraTarget(sky, held: holding)
        if let az = camera {
            camera = Self.norm(az + Self.turn(from: az, to: target) * (1 - exp(-fdt / Self.cameraTau)))
        } else {
            camera = target
        }
        let bearing = camera ?? Self.west

        // The storm.
        let cicadas = Self.cicadaBase(sky, rain: lines.rain)
        let crawlers = SkyExtraMode(rawValue: p.choice(SkyExtraMode.crawlersID)) ?? .natural
        let sheet = SkyExtraMode(rawValue: p.choice(SkyExtraMode.sheetID)) ?? .often
        let input = StrikeLines.Inputs(excitement: excitement, sky: sky, bearing: bearing, quality: quality,
                                       pull: p.number("storm.pull"), pressure: instrumentPressure, crawlers: crawlers,
                                       sheet: sheet, cicadas: cicadas, striking: !warping)
        lines.step(dt: fdt, now: time, input)
        excitement.moment = nil     // one-shots: each lands once
        excitement.surprise = nil

        // Keys: each lights its fence post while held, brighter with each repeat, then fades (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.45)))
        var posts: [PostLight] = []
        let showKeys = p.number("keys.show") > 0.5
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
            if keyGlow[i] < 1e-3 { keyGlow[i] = 0 }
            if showKeys, keyGlow[i] > 0.01 { posts.append(PostLight(index: i, level: min(1, 2 * keyGlow[i] * postBoost[i]))) }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        // The sky over the plain: the storm on the horizon, its heat lightning on the rim, its rain (dry under virga).
        var s = sky
        let dry = StrikeLines.isDry(s)
        s.farStorm = 1
        s.sheet = s.sheet + lines.heat
        if !dry {
            s.rain = min(1, max(s.rain, 0.85 * lines.rain))
            s.wetness = max(s.wetness, 0.6 * lines.rain)
        }
        let windAtYou = simd_length(lines.wind.sample(SIMD2(0, 12)))
        let lean = min(1, simd_length(lines.wind.steady) / 16)

        return PlainsFrame(sky: s, cameraAzimuth: bearing, stormBearing: bearing, distance: lines.distance,
                           distanceKm: lines.km, strikes: lines.forks, towerFlash: lines.towerFlash, crawlers: lines.crawlers,
                           sheetLit: lines.sheetLit, rainCurtain: lines.rainCurtain, curtainKm: lines.curtainKm,
                           rain: lines.rain, dry: dry, windmillRPM: lines.windmillRPM, windmillAngle: lines.windmillAngle,
                           grassLean: lean, wind: lines.wind, cameraShake: lines.shake, postLit: posts,
                           ballLightning: lines.ball, dustDevil: lines.dustDevil, keys: keys,
                           ambience: ambience(roles: roles, sky: s, cicadas: cicadas, wind: Double(windAtYou), dry: dry),
                           mood: mood, time: time, warp: warping ? warpFrame : nil)
    }

    // MARK: - Ambience (spec §9.3)

    /// The dry cicadas' level before any hush: a dusk chorus (0.6 as the sun goes down, from 10° up until −7°, gone by
    /// −12°), a thinner one by day (0.3), none at night or in the rain.
    public static func cicadaBase(_ s: SkyState, rain: Float) -> Double {
        let alt = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let dusk = StrikeLines.smooth(10, 0, alt) * (1 - StrikeLines.smooth(-7, -12, alt))
        let day = StrikeLines.smooth(-2, 8, alt)
        let wet = Double(max(s.rain.isFinite ? s.rain : 0, rain.isFinite ? rain : 0))
        return max(0.6 * dusk, 0.3 * day) * (1 - min(1, 2 * wet))
    }

    /// The plains' soundscape before the weather's (spec §9.3): the dry cicadas (as hushed), the windmill at its drive,
    /// the grass in the wind, grit ticking on the wire, the heat shimmer by day, the cattle grid and a far truck (rare,
    /// the engine's own schedules), crickets by night, the thunder roll up (so the queue plays), and the storm's smell
    /// and its rain on the dust.
    public static func levels(_ s: SkyState, cicadas: Double, windmill: Double, wind: Double, petrichor: Double,
                              rain: Double) -> [AmbienceSource: Double] {
        let alt = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let night = 1 - StrikeLines.smooth(-14, -8, alt)
        let breeze = s.wind.isFinite ? Double(min(1, max(0, s.wind))) : 0
        let wet = min(1, max(0, rain))
        var levels: [AmbienceSource: Double] = [
            .dryCicadas: cicadas,
            .windmill: windmill,
            .grassWind: min(1, 0.12 + max(0, wind) / 18),
            .dustTicks: (0.12 + 0.5 * breeze) * (1 - min(1, 2 * wet)),
            .shimmerHum: 0.35 * StrikeLines.smooth(8, 25, alt),
            .cattleGrid: 0.3 * (1 - 0.6 * night),
            .farTruck: 0.25,
            .crickets: 0.4 * night,
            .thunderRoll: 1,
        ]
        let dust = max(petrichor, wet > 0.02 ? 0.35 + 0.5 * wet : 0)
        if dust > 0 { levels[.rainOnDust] = min(1, dust) }
        if breeze > 0.6 { levels[.wind] = (breeze - 0.6) * 2 }
        WeatherAmbience.levels(s, base: &levels)
        return levels
    }

    private mutating func ambience(roles: RoleValues, sky s: SkyState, cicadas: Double, wind: Double, dry: Bool) -> AmbienceScene {
        let singing = lines.hush.level(cicadas)
        var levels = Self.levels(s, cicadas: singing, windmill: lines.windmillDrive, wind: wind,
                                 petrichor: Double(lines.petrichor), rain: dry ? 0 : Double(lines.rain))
        // Under virga the curtain's crossing is all smell, no rain.
        if dry, lines.rainCurtain > 0 {
            levels[.rainOnDust] = max(levels[.rainOnDust] ?? 0, 0.4 + 0.4 * Double(lines.rainCurtain))
        }
        let night = StrikeLines.smooth(-3, -9, s.sun.altitude)
        let sinceDusk = (s.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        // The sky's own storms rumble as they always have; Strike Lines' strikes queue their thunder late by distance.
        var thunder: Double?
        if s.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.3, 0.95)) }
        lastLightning = s.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.45, mood), density: MoodLook.ambienceDensity(mood),
                             wetness: Double(s.wetness), thunderQueue: lines.thunder)
    }
}

extension LightningPlainsModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the storm on the plain",
                  kind: .choice(visuals), defaultValue: .choice("Strike Lines")),
        SkyHold.spec(default: .blueHour),
        AuroraMode.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        SkyExtraMode.spec(id: SkyExtraMode.crawlersID, name: "Anvil crawlers",
                          help: "Lightning creeping across the towers now and then, besides the ones your runs send",
                          default: .natural),
        SkyExtraMode.spec(id: SkyExtraMode.sheetID, name: "Sheet lightning",
                          help: "Heat lightning flickering on the rim behind the storm at dusk and by night",
                          default: .often),
        slider("storm.pull", "Storm pull", "Strike Lines", 0...1, 0.5, hero: true, surprise: 0.3...0.8,
               help: "How hard your playing (energy, build and pressure) walks the storm in; each repeated strike always brings it 2% closer"),
        slider("grass", "Grass", "Plain", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How tall and thick the dry grass stands"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "The fence posts light where you play",
                  kind: .toggle, defaultValue: .bool(true)),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("storm.pull", 0.6)],
        .speed: [("storm.pull", 0.3)],
        .density: [("grass", 0.6)],
        .glow: [],
        .chaos: [("storm.pull", 0.4)],
        .temperature: [],
    ]
}
