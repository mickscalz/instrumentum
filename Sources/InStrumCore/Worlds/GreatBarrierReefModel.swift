import Foundation
import simd

/// Everything the Great Barrier Reef renderer needs for a frame: a split view at the waterline (spec §9.1, §17 ruling
/// 1), the sky above and the reef below.
public struct ReefFrame: AmbienceProviding {
    /// The Living Sky after `WorldWeather.warm` (snow falls as rain; no frost, rime, diamond dust, pillars, ice fog or
    /// sea smoke: a light morning haze instead), with no fireflies (a cay has none).
    public var sky: SkyState
    /// Where the water's surface splits the frame at rest, as a fraction of the frame's height from its bottom edge:
    /// 0.6 − 0.3 × the Waterline dial (0.6 more reef … 0.3 more sky; 0.45 by default).
    public var waterlineY: Float
    /// The swell's lift of the surface at the lens now (fractions of the frame's height, up positive): within ±0.012 on
    /// a calm day, ±0.09 in a storm. Draw the meniscus at `waterlineY + swellLift`, rolling with `swellPhases`.
    public var swellLift: Float
    /// How far the swell has carried the lens under the surface (0 above … 1 under), smoothed over 0.4 s: only a storm's
    /// crests do (the lens rides 0.05 above the resting surface). The mix crossfades with it.
    public var lensUnder: Float
    /// The swell's four component phases (wrapped, radians) and its weather scale, as the beach's and the bay's.
    public var swellPhases: SIMD4<Float>
    public var swellScale: Float
    /// Coral Pulse: the seven coral groups (bass first; glow 0 and their own hues while Galaxy Warp plays), the lit
    /// polyp patches (at most 64), the school, and a chord's colour wave while it sweeps the reef.
    public var corals: [CoralGroup]
    public var patches: [PolypPatch]
    public var school: School
    public var colourWave: ColourWave?
    /// Tonight's coral spawn: the beads rising and the slick gathering under the surface.
    public var spawn: CoralSpawn
    /// The corals' polyps open to feed at night and glow softly: 0 with the sun above −2° … 1 below −10°.
    public var polypsOpen: Float
    /// Which way the camera looks, degrees from north clockwise: east (90) over the reef crest toward sunrise; on a
    /// shower night it turns (τ 8 s) to face 60° of azimuth from the radiant, where the meteors run long.
    public var cameraAzimuth: Double
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the reef's sky, when it's the chosen visual (notes then streak instead of lighting the corals).
    public var warp: WarpFrame?
}

/// Set 12's world: at the edge of a coral cay's lagoon, the camera at the waterline, facing east over the reef crest.
/// Above, the Coral Sea's sky, a low white cay with pisonia trees and the far crest breaking white; below, the reef in
/// clear turquoise water. Its visual, Coral Pulse, lights the corals as you play; on a few nights after the spring full
/// moons the reef spawns.
public struct GreatBarrierReefModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = ReefFrame
    public static let id = "great-barrier-reef"
    public static let displayName = "Great Barrier Reef"
    public static let visuals = ["Coral Pulse", "Galaxy Warp"]

    /// The camera faces east; on a shower night (the strongest shower's ZHR now at least 10, its radiant up, the sun at
    /// −6° or lower) it turns, with this time constant, to 60° of azimuth from the radiant, on the side nearer east.
    public static let east = 90.0
    public static let showerTurn = 60.0
    public static let cameraTau = 8.0
    public static let showerZHR = 10.0
    /// The swell's height at the lens (frame heights): a sheltered lagoon's in calm weather, a storm's; the lens rides
    /// this far above the resting surface.
    static let calmLift: Float = 0.012, stormLift: Float = 0.09, lensClearance: Float = 0.05
    /// When the lens goes under, the sources above the water dip and those below rise by up to 30%, over 0.4 s.
    public static let crossfade = 0.3
    static let crossfadeTau = 0.4
    /// The sources heard below the water (the rest are above it; rain on the water is both: see `levels`).
    public static let below: Set<AmbienceSource> = [.snappingShrimp, .fishChorus, .whaleSong, .bubbles]
    /// The shrimp's level before the hour's factor (0.4: at dusk, 0.64, the crackle's peaks stay near −7 dBFS; at 0.55
    /// they reached −3 dBFS); the fish chorus at dawn and dusk, and at night; the whales.
    public static let shrimpLevel = 0.4
    public static let fishPeak = 0.4, fishNight = 0.15
    public static let whaleLevel = 0.3
    /// A burst of bubbles as the lens goes under: at most one every this many seconds.
    static let burstGap = 4.0

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var pulse = CoralPulse()
    private var spawning = CoralSpawning()
    private var warp = GalaxyWarp()
    private var swell = OceanSwell(seed: 0x2EEF_C4E5)
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var camera: Double?
    private var under = 0.0
    private var wasUnder = false
    private var lastBurst = -Double.infinity
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0x2EEF)

    private static let layout = KeyboardLayout.keys()
    /// The groups with nothing lit (while Galaxy Warp plays).
    static let restingCorals: [CoralGroup] = (0..<CoralPulse.groupCount).map { g in
        CoralGroup(kind: CoralPulse.kinds[g], x: CoralPulse.groupX[g], top: CoralPulse.groupTop[g], glow: 0, hue: CoralPulse.hues[g])
    }

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// It's warm here (`WorldWeather.warm`), and a cay has no fireflies.
    public mutating func setSky(_ s: SkyState) {
        var warm = WorldWeather.warm(s)
        warm.fireflies = 0
        sky = warm
    }

    /// Where the surface splits the frame for a Waterline dial value (fraction of the height from the bottom).
    public static func waterlineY(_ dial: Double) -> Float {
        let d = dial.isFinite ? min(max(dial, 0), 1) : 0.5
        return Float(0.6 - 0.3 * d)
    }

    // MARK: - The swell and the camera

    /// The swell's lift at the lens (frame heights): its four components' weighted sum (0.4, 0.3, 0.2, 0.1) × the
    /// lagoon's height for the weather (0.012 calm … 0.09 in a storm, as `OceanSwell.weatherScale` goes 1 … 1.8).
    public static func lift(phases p: SIMD4<Float>, sky: SkyState) -> Float {
        let long = 0.4 * sin(p.x) + 0.3 * sin(p.y)
        let short = 0.2 * sin(p.z) + 0.1 * sin(p.w)
        return liftScale(sky) * (long + short)
    }

    /// The lagoon's swell height at the lens for this weather (frame heights): 0.012 calm … 0.09 in a storm.
    public static func liftScale(_ s: SkyState) -> Float {
        let storm = min(1, max(0, (OceanSwell.weatherScale(s) - 1) / 0.8))
        return calmLift + (stormLift - calmLift) * storm
    }

    /// How far a lift carries the lens under: 0 below the clearance (0.05) … 1 a hundredth past it.
    public static func underAmount(_ lift: Float) -> Float {
        guard lift.isFinite else { return 0 }
        let t = min(1, max(0, (lift - (lensClearance - 0.01)) / 0.02))
        return t * t * (3 - 2 * t)
    }

    /// Where the camera wants to look (degrees from north): east, or on a shower night 60° of azimuth from the radiant
    /// (the side nearer east), so the meteors streak across the view.
    public static func cameraTarget(_ s: SkyState) -> Double {
        guard let shower = s.shower, shower.zhr >= showerZHR, shower.radiantAltitude > 0,
              shower.radiantAzimuth.isFinite, s.sun.altitude <= -6 else { return east }
        let a = norm(shower.radiantAzimuth + showerTurn), b = norm(shower.radiantAzimuth - showerTurn)
        return abs(turn(from: east, to: a)) <= abs(turn(from: east, to: b)) ? a : b
    }

    /// The signed turn from one azimuth to another, degrees (−180…180].
    static func turn(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    static func norm(_ a: Double) -> Double {
        let x = a.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> ReefFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        // Switching visuals lets held notes go: no polyps stay lit, no streak waits for a release.
        if let lastVisual, lastVisual != visual { pulse.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        pulse.reactionScale = MoodLook.reactionScale(mood)
        pulse.lingerScale = MoodLook.lingerScale(mood)
        pulse.fish = p.number("fish")
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    pulse.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                pulse.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                pulse.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                pulse.allNotesOff(); pulse.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        pulse.step(dt: fdt, roles: roles)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)
        let hold = SkyHold(rawValue: p.choice("light.hold")) ?? .follow
        let setting = CoralSpawningSetting(rawValue: p.choice("spawning")) ?? .follow
        spawning.step(dt: fdt, sky: sky, setting: setting, held: hold != .follow, quality: quality)

        // The lagoon's swell: the reef crest's surf breaks with it, and the lens rides its meniscus.
        swell.scale = OceanSwell.weatherScale(sky)
        let breaks = swell.step(dt: fdt)
        let phases = swell.phases(at: swell.time)
        let lift = Self.lift(phases: phases, sky: sky)
        let goal = Double(Self.underAmount(lift))
        under += (goal - under) * (1 - exp(-fdt / Self.crossfadeTau))

        // The camera turns (τ 8 s, the short way round) toward where it wants to look; it arrives looking there.
        let target = Self.cameraTarget(sky)
        if let az = camera {
            camera = Self.norm(az + Self.turn(from: az, to: target) * (1 - exp(-fdt / Self.cameraTau)))
        } else {
            camera = target
        }

        // Keys glow turquoise in the wet sand while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let feeding = Float(MoonlitLakeModel.smooth(-2, -10, sky.sun.altitude))
        return ReefFrame(sky: sky, waterlineY: Self.waterlineY(p.number("waterline")), swellLift: lift, lensUnder: Float(under),
                         swellPhases: phases, swellScale: swell.scale,
                         corals: warping ? Self.restingCorals : pulse.groups, patches: warping ? [] : pulse.patches,
                         school: pulse.school, colourWave: warping ? nil : pulse.wave, spawn: spawning.spawn,
                         polypsOpen: feeding, cameraAzimuth: camera ?? Self.east, keys: keys,
                         ambience: ambience(roles: roles, breaks: breaks), mood: mood, time: time,
                         warp: warping ? warpFrame : nil)
    }

    // MARK: - Ambience

    /// The snapping shrimp's factor for the hour (spec §5): 1 by day (the sun above 12°), 1.6 at dawn and dusk (the sun
    /// between +4° and −8°) and 1.25 at night (below −14°), gliding between.
    public static func shrimpFactor(_ s: SkyState) -> Double {
        let alt = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let day = MoonlitLakeModel.smooth(4, 12, alt)
        let night = 1 - MoonlitLakeModel.smooth(-14, -8, alt)
        let twilight = max(0, 1 - day - night)
        return day + 1.6 * twilight + 1.25 * night
    }

    /// The fish chorus (spec §5, §9.1): silent by day; the dusk drumming builds through the late afternoon as the sun
    /// goes down (from 40° to −2°), holds through dusk and stops abruptly by −10°; a dawn chorus from −12° until the sun
    /// is well up (14°); 0.4 at the peaks, and scattered calls (0.15) through the night.
    public static func fishChorus(_ s: SkyState) -> Double {
        let alt = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let night = 1 - MoonlitLakeModel.smooth(-14, -10, alt)
        let gathered: Double
        if s.hourOfDay >= 12 {
            gathered = MoonlitLakeModel.smooth(40, -2, alt) * (1 - MoonlitLakeModel.smooth(-7, -10, alt))
        } else {
            gathered = MoonlitLakeModel.smooth(-12, -6, alt) * (1 - MoonlitLakeModel.smooth(4, 14, alt))
        }
        return max(fishPeak * gathered, fishNight * night)
    }

    /// The humpbacks are in the reef's lagoon from June to October (the reef's own season, by the sky city's date).
    public static func whaleSeason(_ s: SkyState) -> Bool {
        (6...10).contains(CoralSpawning.month(dayOfYear: s.dayOfYear, year: CoralSpawning.year(s.calendar)))
    }

    /// The reef's soundscape (spec §5, §9.1) with the lens `under` the surface (0…1): above the water the reef crest's
    /// far surf, the lapping at the waterline, the breeze, the terns and gulls by day; below it the snapping shrimp by
    /// the hour, the fish chorus, the humpbacks in season and the bubbles; then the weather's (`WeatherAmbience`). The
    /// lens going under dips the sources above by up to 30% and lifts those below by as much (at most 1). Rain on the
    /// lagoon (`rainOnWater`) is both: it pocks the surface above (0.5 × rain) and is a soft hiss below, the same source
    /// muffled to half (0.25 × rain), each half crossfading with its side.
    public static func levels(_ s: SkyState, under: Double) -> [AmbienceSource: Double] {
        let alt = s.sun.altitude.isFinite ? s.sun.altitude : 90
        let day = MoonlitLakeModel.smooth(-4, 2, alt)
        let wind = s.wind.isFinite ? Double(min(max(s.wind, 0), 1)) : 0
        let rain = s.rain.isFinite ? Double(min(max(s.rain, 0), 1)) : 0
        var levels: [AmbienceSource: Double] = [
            .surf: 0.3,
            .lapping: 0.45,
            .breeze: min(1, 0.25 + wind),
            .gulls: 0.15 * day,
            .snappingShrimp: shrimpLevel * shrimpFactor(s),
            .fishChorus: fishChorus(s),
            .whaleSong: whaleSeason(s) ? whaleLevel : 0,
            .bubbles: 0.35,
        ]
        if wind > 0.6 { levels[.wind] = (wind - 0.6) * 2 }
        WeatherAmbience.levels(s, base: &levels)
        let u = under.isFinite ? min(max(under, 0), 1) : 0
        for source in Array(levels.keys) {
            let level = levels[source] ?? 0
            let shifted = below.contains(source) ? level * (1 + crossfade * u) : level * (1 - crossfade * u)
            levels[source] = min(1, max(0, shifted))
        }
        let pocks = 0.5 * (1 - crossfade * u), hiss = 0.25 * (1 + crossfade * u)
        levels[.rainOnWater] = min(1, rain * (pocks + hiss))
        return levels
    }

    private mutating func ambience(roles: RoleValues, breaks: [Wave]) -> AmbienceScene {
        let levels = Self.levels(sky, under: under)
        let night = MoonlitLakeModel.smooth(-3, -9, sky.sun.altitude)
        // Night cools from dusk (about 19:00) over eight hours.
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        // The swell's waves break on the reef crest, far off; the lens going under traps a burst of bubbles.
        let wave = breaks.map { Double($0.strength) }.max()
        var burst: Double?
        let dipping = under > 0.5
        if dipping, !wasUnder, time - lastBurst >= Self.burstGap {
            burst = 0.6
            lastBurst = time
        }
        wasUnder = dipping
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.55, mood), density: MoodLook.ambienceDensity(mood),
                             wave: wave, speed: 0, surfDistance: 0.9, indoors: WeatherAmbience.indoorsLift(sky),
                             wetness: Double(sky.wetness), bubbleBurst: burst)
    }
}

extension GreatBarrierReefModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does on the reef",
                  kind: .choice(visuals), defaultValue: .choice("Coral Pulse")),
        SkyHold.spec(default: .follow),
        AuroraMode.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        slider("fish", "Fish", "Coral Pulse", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How many small fish school over the reef and dart along your melody: from 20 to 80"),
        slider("waterline", "Waterline", "Reef", 0...1, 0.5, surprise: 0.2...0.8,
               help: "Where the water's surface splits the view: from more reef to more sky"),
        CoralSpawningSetting.spec(default: .follow),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A strip of wet sand along the bottom, glowing where you play",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("fish", 0.6)],
        .speed: [],
        .density: [("fish", 0.8)],
        .glow: [],
        .chaos: [("fish", 0.3)],
        .temperature: [],
    ]
}
