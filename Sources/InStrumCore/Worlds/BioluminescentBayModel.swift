import Foundation
import simd

/// Everything the Bioluminescent Bay renderer needs for a frame.
public struct BayFrame: AmbienceProviding {
    public var sky: SkyState
    /// Glow Wake (every brightness already times `glowScale`; empty while Galaxy Warp plays).
    public var patches: [GlowPatch]
    public var wakes: [GlowWakeLine]
    public var darts: [Dart]
    public var pool: GlowPool
    /// 0 by day … 1 at night: the plankton needs the dark (rain dulls it to 0.4×).
    public var glowScale: Float
    /// The lighthouse on the far point: a 0.4 s flash every 6 s once the sun is down (0…1).
    public var lighthouseFlash: Float
    /// The moored boat's lantern is lit (the sun below −3°).
    public var lanternLit: Bool
    /// The bay's small swell (`OceanSwell` at a fraction of the beach's height; storms whip it up).
    public var swellPhases: SIMD4<Float>
    public var swellScale: Float
    public var swellTime: Double
    /// How far the latest small wave's wash reaches up the sand (0 waterline … 1).
    public var washFront: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the bay's sky, when it's the chosen visual (notes then streak instead of glowing).
    public var warp: WarpFrame?

    // Excitement as the bay draws it (Fire & Neon spec §5.5). A fireball is already in `sky` (the shared sky draws it, and
    // the water mirrors it).
    /// The drawn Energy (Reduce Motion's cap included), eased: it lifts the plankton's glow (0…1).
    public var energy: Float = 0
    /// The big moment: a wave of plankton light running in from the bay's mouth to the shore (nil while none runs).
    public var wave: BayWave? = nil
    /// Tension: the glow gathering under the surface (0…1). The drop breaks it into a wave (`wave.drop`).
    public var gather: Float = 0
    /// A drop's sparkles scattering over the water behind its wave (0…1 × the moment's strength).
    public var sparkle: Float = 0
    /// The surprises playing (0 a manta gliding in, 1 a turtle surfacing for a breath, 2 a fireball).
    public var surprises: [PlayingSurprise] = []
    /// A fireball's light on the bay (0…1, before the renderer's flash limiter).
    public var flashRequest: Float = 0
    /// How many of the bay's own meteors (a fireball's) are showing.
    public var worldMeteors: Int = 0
    public var reduceMotion = false
}

/// The bay's big moment (Fire & Neon spec §5.5): a band of blue-green plankton light that sets off from the bay's mouth
/// and runs in to the shore, lighting the water as it passes and the wash on the sand as it arrives, then fading.
public struct BayWave: Equatable {
    /// How far it has run: 0 at the bay's mouth … 1 at the waterline (a drop's sets off from the gathered glow, 0.3).
    public var front: Float
    /// Its light (0…1 × the moment's strength, before the flash limiter): up as it sets off, held while it runs, fading
    /// over the seconds after it reaches the shore.
    public var light: Float
    /// Its arrival: the waterline and the wash on the sand lit (0…1 × the strength), flaring and dying away.
    public var shore: Float
    /// A drop's wave: brighter, quicker, from the gathered glow, with sparkles scattering behind it.
    public var drop: Bool
}

/// Set 8's world: a sheltered cove at night, headlands with palms and mangroves, a still bay mirroring the real
/// stars, a moored boat's lantern, a lighthouse blinking on the far point, and plankton glowing along the
/// waterline. Its visual, Glow Wake, lights the water where your notes fall.
public struct BioluminescentBayModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = BayFrame
    public static let id = "bioluminescent-bay"
    public static let displayName = "Bioluminescent Bay"
    public static let visuals = ["Glow Wake", "Galaxy Warp"]
    /// A manta's glow, a turtle surfacing, a fireball (Fire & Neon spec §5.5), and how long each plays (s).
    public static let surpriseCount = 3
    public static let surpriseSeconds: [Float] = [13, 9, 3.8]
    /// Surprises held back until they are good enough: the manta (0) is drawn as a glowing outline that doesn't read as
    /// a manta and costs a millisecond a frame, so the director's pick of it plays the turtle instead.
    public static let heldBackSurprises: Set<Int> = [0]
    /// The wave of light plays this long (a drop's a little longer); it runs to the shore in `waveRun` s (a drop's,
    /// setting off from the gathered glow at `dropStart` of the way, in `dropRun`).
    public static let momentSeconds: Float = 7, dropSeconds: Float = 8
    public static let waveRun: Float = 3, dropRun: Float = 2.2, dropStart: Float = 0.3

    /// The lighthouse's period and flash length (seconds).
    public static let lighthousePeriod = 6.0, lighthouseFlashLength = 0.4
    /// The bay's swell is this fraction of the open sea's: still in calm weather, whipped up in a storm.
    static let calmSwell: Float = 0.12, stormSwell: Float = 0.5

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var glow = GlowWake()
    private var warp = GalaxyWarp()
    private var swell = OceanSwell(seed: 0xB10_1A7)
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xB1A7)

    // Excitement (Fire & Neon spec §5.5): fixed pools throughout.
    private var excite = ExcitementFrame()
    private var play = ExcitementPlay()
    private var meteors = WorldMeteors()
    private var energyEased: Float = 0
    /// The glow gathering under the surface: it gathers slowly (τ 1 s) and breaks as quickly as the tension lets go.
    private var gatherEased: Float = 0
    /// The playing moment set off as a drop (its wave runs from the gathered glow).
    private var dropWave = false

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// Where the bay looks (degrees from north): toward the pole, as the renderer's camera (south from the southern
    /// hemisphere).
    public static func viewAzimuth(_ s: SkyState) -> Double { s.latitude < 0 ? 180 : 0 }

    /// The wave of light `age` seconds into a moment of `life` seconds and `strength` (a drop's: `drop`).
    public static func wave(age: Float, life: Float, strength: Float, drop: Bool) -> BayWave {
        let run = drop ? dropRun : waveRun
        let start: Float = drop ? dropStart : 0
        let k = min(1, max(0, age.isFinite ? age / run : 0))
        let eased = 0.5 * k + 0.5 * k * k * (3 - 2 * k)
        let light = ExcitementPlay.envelope(age: age, life: life, rise: drop ? 0.15 : 0.35, fall: max(1, life - run))
        let arrived = ExcitementPlay.smooth(run - 0.3, run + 0.15, age) * exp(-max(0, age - run) / 1.7)
        let s = ExcitementPlay.unit(strength)
        return BayWave(front: start + (1 - start) * eased, light: light * s, shore: arrived * s, drop: drop)
    }

    /// 0 with the sun above −2° … 1 below −8°.
    public static func night(_ s: SkyState) -> Double { MoonlitLakeModel.smooth(-2, -8, s.sun.altitude) }

    /// The plankton's glow: the dark, dulled by rain (×(1 − 0.6·rain)).
    public static func glowScale(_ s: SkyState) -> Float {
        let rain = s.rain.isFinite ? min(max(s.rain, 0), 1) : 0
        return Float(night(s)) * (1 - 0.6 * rain)
    }

    /// A smooth 0.4 s pulse at the start of every 6 s (0 between).
    public static func lighthouse(at t: Double) -> Float {
        guard t.isFinite else { return 0 }
        var phase = t.truncatingRemainder(dividingBy: lighthousePeriod)
        if phase < 0 { phase += lighthousePeriod }
        guard phase < lighthouseFlashLength else { return 0 }
        return Float(sin(Double.pi * phase / lighthouseFlashLength))
    }

    /// The swell's height for the weather: calm 0.12 of the open sea's, a storm (open-sea scale 1.8) 0.5.
    static func swellScale(_ s: SkyState) -> Float {
        let w = OceanSwell.weatherScale(s)
        let storm = min(1, max(0, (w - 1) / 0.8))
        return calmSwell + (stormSwell - calmSwell) * storm
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> BayFrame {
        time += dt
        let glowScale = Self.glowScale(sky)
        glow.nightScale = glowScale
        glow.reactionScale = MoodLook.reactionScale(mood)
        glow.lingerScale = MoodLook.lingerScale(mood)
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        // Switching visuals lets held notes go: no patch stays lit, no streak waits for a release.
        if let lastVisual, lastVisual != visual { glow.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    glow.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                glow.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                glow.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                glow.allNotesOff(); glow.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        glow.step(dt: dt, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)
        let fd = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
        stepExcitement(dt: fd)
        swell.scale = Self.swellScale(sky)
        _ = swell.step(dt: dt)
        let front = swell.washFront(at: swell.time)

        // Keys glow cyan while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let down = sky.sun.altitude < -3
        let flash = down && p.number("lighthouse") > 0.02 ? Self.lighthouse(at: time) : 0

        var shown = sky
        meteors.inject(into: &shown)
        var frame = BayFrame(sky: shown, patches: warping ? [] : glow.patches, wakes: warping ? [] : glow.wakes,
                             darts: warping ? [] : glow.darts, pool: warping ? GlowPool.still : glow.pool, glowScale: glowScale,
                             lighthouseFlash: flash, lanternLit: down && p.number("lantern") > 0.02,
                             swellPhases: swell.phases(at: swell.time), swellScale: swell.scale, swellTime: swell.time,
                             washFront: front, keys: keys, ambience: ambience(roles: roles), mood: mood, time: time,
                             warp: warping ? warpFrame : nil)
        frame.energy = energyEased
        if let m = play.moment {
            frame.wave = Self.wave(age: m.age, life: m.duration, strength: m.strength, drop: dropWave)
            // A drop scatters sparkles over the water behind its wave, dying away.
            if m.isDrop { frame.sparkle = m.strength * ExcitementPlay.smooth(0, 0.25, m.age) * exp(-m.age / 2.6) }
        }
        frame.gather = gatherEased
        frame.surprises = play.surprises
        frame.flashRequest = 0.35 * meteors.fireballLight(at: sky.meteorTime)
        frame.worldMeteors = meteors.live(at: sky.meteorTime).count
        frame.reduceMotion = play.reduceMotion
        return frame
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    /// Energy lifts the plankton's glow; a big moment sends a wave of light across the whole bay; tension gathers the glow
    /// under the surface and a drop breaks it into a brighter wave; the surprises play (the fireball in the shared sky).
    private mutating func stepExcitement(dt fd: Float) {
        var e = excite
        if var sp = e.surprise, Self.heldBackSurprises.contains(sp.index) { sp.index = 1; e.surprise = sp }
        excite.moment = nil
        excite.surprise = nil
        play.step(dt: Double(fd), frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        energyEased = ExcitementStep.ease(energyEased, to: play.energy, tau: play.energy > energyEased ? 0.8 : 3, dt: fd)
        // (Its release follows the tension's own, already eased by ExcitementPlay.)
        gatherEased = play.tension < gatherEased ? play.tension : ExcitementStep.ease(gatherEased, to: play.tension, tau: 1, dt: fd)
        if let m = play.momentBegan { dropWave = m.isDrop }
        let now = sky.meteorTime
        meteors.prune(at: now)
        if let sp = play.surpriseBegan, sp.index == 2 { fireball(seed: sp.seed, gentle: play.gentle, now: now) }
    }

    /// A slow golden fireball across the view, high to low, ending in a flare (fainter and no flare under gentle
    /// visuals); the bay mirrors it.
    private mutating func fireball(seed: UInt64, gentle: Bool, now: Double) {
        var r = SeededRandom(seed: seed)
        let view = Self.viewAzimuth(sky)
        let leftToRight = r.unit() < 0.5
        let a = view + (leftToRight ? -1 : 1) * Double(r.range(18, 28))
        let b = view + (leftToRight ? 1 : -1) * Double(r.range(10, 20))
        let start = WorldMeteors.direction(azimuth: a, altitude: Double(r.range(24, 30)))
        let end = WorldMeteors.direction(azimuth: b, altitude: Double(r.range(5, 9)))
        let run = r.range(2.8, 3.3)
        meteors.add(WorldMeteors.meteor(from: start, to: end, born: now, duration: run, magnitude: gentle ? -6 : -8,
                                        speed: 24, flare: !gentle))
    }

    /// The bay's soundscape: small waves lapping the hull and rocks, crickets and an owl on the headlands at
    /// night, a far boat now and then, gulls by day.
    private mutating func ambience(roles: RoleValues) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = Self.night(sky)
        let day = MoonlitLakeModel.smooth(-4, 2, sunAlt)
        var levels: [AmbienceSource: Double] = [
            .lapping: 0.7,
            .water: 0.3,
            .crickets: 0.5 * night,
            .boat: 0.4,
            .breeze: min(1, 0.25 + Double(sky.wind)),
            .owl: 0.15 * night,
            .rainOnWater: Double(sky.rain),
            .gulls: 0.2 * day,
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
                             closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension BioluminescentBayModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the bay",
                  kind: .choice(visuals), defaultValue: .choice("Glow Wake")),
        SkyHold.spec(default: .deepNight),
        AuroraMode.spec(default: .follow),
        MeteorMode.spec(default: .follow),
        slider("glow", "Plankton glow", "Glow Wake", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How brightly the plankton lights where your notes fall and along the waterline"),
        slider("lantern", "Boat lantern", "Bay", 0...1, 0.6, surprise: 0.2...1,
               help: "The moored boat's lantern and its light on the water"),
        slider("lighthouse", "Lighthouse", "Bay", 0...1, 0.5, surprise: 0...1,
               help: "The lighthouse on the far point, blinking every six seconds"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A dark glass keyboard along the sand",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("glow", 0.8)],
        .speed: [],
        .density: [("glow", 0.4)],
        .glow: [("glow", 1), ("lantern", 0.5)],
        .chaos: [],
        .temperature: [("lantern", 0.6)],
    ]
}
