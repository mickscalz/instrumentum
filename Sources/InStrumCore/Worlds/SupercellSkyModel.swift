import Foundation
import simd

// Supercell Sky (Storms spec §8): Set 17's world. You stand in a wheat field at the end of a hot afternoon, the low sun
// behind you, and a rotating supercell fills the sky: a striated mesocyclone over a flat rain-free base, a lowered wall
// cloud fed by inflow bands, a hail shaft lit white, an anvil overhead with mammatus under it. The storm is the world's
// weather (the stage picker holds or cycles it); Distance is the hero dial. Everything you play lands on the storm:
// Energy spins it and tightens the inflow, notes glow up the inflow bands, chords pulse the wall cloud's base, runs
// ripple round it, a big moment is a cloud-to-ground strike at the storm's distance with its thunder late by that
// distance, and the drop is the gust front. Resting lets it settle into its Clearing.

/// A cloud-to-ground strike at the storm's distance (spec §8.2).
public struct GroundStrike: Equatable {
    public var id: Int
    /// How far off it comes down (km): the storm's distance when the moment fired.
    public var distanceKm: Float
    /// Its bearing from the middle of the view (degrees, right positive).
    public var bearing: Float
    /// How high its channel leaves the cloud (km): the base, or for the biggest moments higher up the storm's side.
    public var topKm: Float
    /// The moment's strength (0.3…1) and the seed for its channel's shape and its strokes.
    public var strength: Float
    public var seed: UInt64
    /// Seconds since it struck.
    public var age: Float

    /// How long a strike is seen (s): its strokes over the first 0.3 s, then the channel's afterglow fading.
    public static let life: Float = 0.6
    /// How many return strokes it has (2–4).
    public var strokes: Int { 2 + Int(seed % 3) }
    /// Its light now, 0…1 (before any flash limiter): each return stroke a sharp spike, the channel glowing between.
    public var brightness: Float {
        guard age >= 0, age < Self.life else { return 0 }
        var light: Float = 0
        let times: [Float] = [0, 0.07, 0.16, 0.25]
        for k in 0..<strokes {
            let since = age - times[k]
            let peak: Float = k == 0 ? 1 : 0.75
            if since >= 0 { light = max(light, peak * exp(-since / 0.03)) }
        }
        let glow = 0.35 * exp(-age / 0.2) * (1 - min(1, age / Self.life))
        return min(1, max(light, glow) * (0.55 + 0.45 * strength))
    }
    /// Where it comes down on the field (km: x across the view, y away from the camera).
    public var ground: SIMD2<Float> {
        let b = bearing * Float.pi / 180
        return SIMD2(distanceKm * sin(b), distanceKm * cos(b))
    }
}

/// A funnel cloud lowering from the wall cloud (spec §5: a surprise, far, once an evening, never touching anything).
public struct StormFunnel: Equatable {
    public var age: Float
    /// How long it lasts (8–14 s): it lowers, hangs and lifts again.
    public var duration: Float
    public var seed: UInt64
    /// The furthest it reaches down from the wall cloud toward the ground (a share of the way): never the ground.
    public static let maxReach: Float = 0.7

    /// How far down it reaches now (0 … `maxReach` × 0.8–1).
    public var reach: Float {
        let x = min(1, max(0, age / max(duration, 1e-3)))
        let down = SupercellSkyModel.smooth(0, 0.4, x) * (1 - SupercellSkyModel.smooth(0.6, 1, x))
        let deep = 0.8 + 0.2 * Float(seed % 1000) / 1000
        return Self.maxReach * deep * down
    }
}

/// The light after the storm (spec §8.2): crepuscular rays under the anvil's edge, a double rainbow at the sun's
/// antipoint, and the stars behind the retreating core.
public struct SupercellAfter: Equatable {
    public var rays: Float
    public var rainbow: Float
    public var stars: Float
    public init(rays: Float = 0, rainbow: Float = 0, stars: Float = 0) { self.rays = rays; self.rainbow = rainbow; self.stars = stars }
}

/// Everything the Supercell Sky renderer needs for a frame (spec §8.2).
public struct SupercellFrame: AmbienceProviding {
    /// The Living Sky after the storm's own weather (warm: a summer evening; the storm's rain only where its core is).
    public var sky: SkyState
    /// Which way the camera looks (degrees from north): away from the sun, so the low sun lights the storm's face.
    public var viewAzimuth: Double
    /// How far off the storm's centre is (km): the Distance dial at its Core, further while it comes and as it clears.
    public var distanceKm: Float
    /// The mesocyclone's rate (rpm) and its angle now (radians, the storm's way round).
    public var rotationRPM: Float
    public var rotation: Float
    /// Which way it turns seen from above: +1 anticlockwise (north), −1 clockwise (south).
    public var spin: Float
    /// The inflow's tightness (0…1) and the bands' spacing (degrees, 12 → 5).
    public var inflowTightness: Float
    public var inflowSpacing: Float
    /// How dark the base is (0…1), the green cast under the core (0…0.12), the hail shaft's density (0…1), and the rain
    /// the storm drops (0…1, in its shafts; the sky's `rain` is what falls on you).
    public var baseDarkness: Float
    public var greenCast: Float
    public var hailDensity: Float
    public var stormRain: Float
    /// The stage (the event's, at `phase`), its weights (approach, core, clearing; summing to 1) and how settled into
    /// its Clearing the storm looks (the stage's Clearing, or resting).
    public var stage: SupercellStage
    public var phase: Float
    public var stageWeights: SIMD3<Float>
    public var clearing: Float
    /// The strikes in the sky now.
    public var strikes: [GroundStrike]
    /// The gust front's wave crossing the field: 0 at the field's far edge … 1 at the camera, nil when none is crossing.
    public var gustWave: Float?
    /// The dust it lifts (0…1).
    public var dust: Float
    /// The wind over the field, for the grass rows.
    public var wind: WindField
    /// The flock (positions and velocities in metres; the count is 40, 20 on Smooth).
    public var flock: [StormBird]
    /// The camera's shake now (pixels; ≤ 6, 0.4 s; none under Reduce Motion) and how far it has dollied back (metres).
    public var cameraShake: SIMD2<Float>
    public var cameraDolly: Float
    /// Wall Cloud: the glows running up the inflow bands, the chords' pulses in the base, the runs' ripples round it.
    public var glows: [InflowGlow]
    public var pulses: [BasePulse]
    public var ripples: [WallRipple]
    /// A funnel lowering (a surprise), a far cell lit from inside (0…0.2), the light after the storm.
    public var funnel: StormFunnel?
    public var farCell: Float
    public var after: SupercellAfter
    /// Excitement as the world draws it: Energy, tension and the drop's release.
    public var energy: Float
    public var tension: Float
    public var drop: Float
    public var reduceMotion: Bool
    /// The keys: a line of fence posts along the bottom edge, each lit white by its note.
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the storm, when it's the chosen visual (notes then streak instead of lighting the inflow).
    public var warp: WarpFrame?
}

/// Set 17's world (spec §8).
public struct SupercellSkyModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, InstrumentAware, SurpriseListing {
    public typealias Frame = SupercellFrame
    public static let id = "supercell-sky"
    public static let displayName = "Supercell Sky"
    public static let visuals = ["Wall Cloud", "Galaxy Warp"]
    /// The world's surprises (spec §5): a funnel, a hail burst out of a clear patch, the next cell lit from inside (where
    /// Fire & Neon's red sprites will stand), a rainbow against the core.
    public static let surpriseCount = 4

    /// Distance: 0 is 30 km, 1 overhead.
    public static let farthestKm: Float = 30
    /// The storm comes in from this much further over the Approach, and goes this far again as it clears; resting
    /// takes it `settleKm` further.
    public static let retreatKm: Float = 14
    public static let settleKm: Float = 8
    /// The eye over the field (m).
    public static let eyeHeight: Float = 1.7
    /// Closer than this a strike shakes the camera.
    public static let closeKm: Float = 2
    public static let shakePixels: Float = 6
    public static let shakeSeconds: Float = 0.4
    /// The gust front (spec §8.2): it sets out from the field's far edge and crosses to the camera at 15 m/s, the
    /// outflow blowing on behind it.
    public static let gustStart: Float = 300
    public static let gustSpeed: Float = 15
    public static let gustWidth: Float = 50
    public static let gustStrength: Float = 14
    public static let gustTail: Float = 400
    /// The strikes kept at once.
    public static let strikeCap = 3
    /// Resting: after this long without a note the storm begins to settle into its Clearing, all the way by `settleFull`.
    public static let settleAfter = 10.0
    public static let settleFull = 25.0
    /// The camera dollies back at most this far (m) as the storm comes on.
    public static let dollyMetres: Float = 30
    public static let cameraTau = 8.0

    public var mood = Mood.neutral
    public var instrumentPressure: Float = 0
    public var instrumentRepeat = false
    public var forcedMorph: Float? { nil }

    private var rawSky = SkyState()
    private var excite = ExcitementFrame()
    private var wall = WallCloud()
    private var warp = GalaxyWarp()
    private var flock = StormFlock()
    private var wind = WindField(extent: 400, seed: 0x5C_E11_5C1)
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var sinceNote = 0.0
    private var calm: Float = 0
    private var camera: Double?
    private var dolly: Float = 0
    private var strikes: [GroundStrike] = []
    private var nextStrikeID = 0
    private var rng = SeededRandom(seed: 0x5C_E115)
    private var shakeAge: Float = 1
    private var shakeAmount: Float = 0
    private var shakePhase: Float = 0
    private var gustAge: Float?
    private var skyFrontHit = false
    private var dropHail: Float = 0
    private var hailBurst: Float = 0
    private var farCell: Float = 0
    private var rainbowSurprise: Float = 0
    private var funnel: StormFunnel?
    private var lastFunnelEvening: Int?

    private static let layout = KeyboardLayout.keys()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// A summer evening: snow and sleet fall as rain (the warm rule), and the storm brings its own weather (in `step`).
    public mutating func setSky(_ s: SkyState) { rawSky = WorldWeather.warm(s) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    // MARK: - The laws

    /// The storm's distance (km) for the Distance dial: 30 km at 0, overhead at 1.
    public static func km(dial: Double) -> Float {
        let d = dial.isFinite ? Float(min(1, max(0, dial))) : 0.45
        return farthestKm * (1 - d)
    }

    /// How far below the horizon a point `km` off on the field lies, seen from the eye (degrees).
    public static func horizonDepression(km: Float) -> Float {
        atan(eyeHeight / max(1, km * 1000)) * 180 / Float.pi
    }

    /// The stage's weights at a phase (approach, core, clearing), gliding over the boundaries.
    public static func stageWeights(phase raw: Float) -> SIMD3<Float> {
        let p = raw.isFinite ? raw - raw.rounded(.down) : 0
        let e: Float = 0.03
        let core = smooth(1.0 / 3 - e, 1.0 / 3 + e, p) * (1 - smooth(2.0 / 3 - e, 2.0 / 3 + e, p))
        let clearing = smooth(2.0 / 3 - e, 2.0 / 3 + e, p) * (1 - smooth(1 - e, 1, p))
        return SIMD3(max(0, 1 - core - clearing), core, clearing)
    }

    /// How far the storm stands beyond the dial's distance at a phase (km): coming in over the Approach, going away as it
    /// clears (the two meet at the wrap, so Cycle never jumps).
    public static func retreat(phase raw: Float) -> Float {
        let p = raw.isFinite ? raw - raw.rounded(.down) : 0
        let w = stageWeights(phase: p)
        let approachLeft = 1 - min(1, max(0, p * 3))
        let cleared = min(1, max(0, (p - 2.0 / 3) * 3))
        return retreatKm * (w.x * approachLeft + w.z * cleared)
    }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The evening a sky belongs to (a funnel comes at most once in one): its day, counting the small hours as the
    /// evening before.
    static func evening(_ s: SkyState) -> Int { s.dayOfYear - (s.hourOfDay < 6 ? 1 : 0) }

    static func norm(_ a: Double) -> Double {
        let x = a.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    static func turn(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SupercellFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fd = Float(fdt)
        time += fdt
        sinceNote += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        if let lastVisual, lastVisual != visual { wall.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        wall.reaction = MoodLook.reactionScale(mood)
        wall.spin = rawSky.latitude < 0 ? -1 : 1

        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                sinceNote = 0
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    wall.noteOn(note, velocity: velocity)
                }
            case let .noteOff(note):
                held[note] = nil
                warp.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                wall.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        // Excitement, as drawn: Reduce Motion caps Energy's look at 0.5 and the turn at 1 rpm, and shakes nothing.
        let reduce = excite.reduceMotion
        let energy = min(1, max(0, excite.visualEnergy.isFinite ? excite.visualEnergy : 0))
        let tension = min(1, max(0, excite.tension.isFinite ? excite.tension : 0))
        let drop = min(1, max(0, excite.drop.isFinite ? excite.drop : 0))
        let moment = excite.moment
        let surprise = excite.surprise
        excite.moment = nil
        excite.surprise = nil

        // The stage: the sky's supercell when it has one, else the picker's held phase.
        let picked = SupercellStage(rawValue: p.choice(SupercellStage.id)) ?? .core
        let heldPhase = Float(WorldWeather.supercellPhase(held: picked) ?? 0)
        let phase: Float = rawSky.supercell > 0 ? rawSky.supercellPhase : heldPhase
        let w = Self.stageWeights(phase: phase)
        // Resting lets it settle into its Clearing (when the picker holds the Core or cycles); playing brings it back.
        let settles = picked == .core || picked == .cycle
        let resting = Self.smooth(Float(Self.settleAfter), Float(Self.settleFull), Float(sinceNote))
        let calmTarget: Float = settles && energy < 0.08 ? resting : 0
        let calmTau: Float = calmTarget > calm ? 6 : 1.2
        calm += (calmTarget - calm) * (1 - exp(-fd / calmTau))
        let clearLook = max(w.z, calm)
        let coreLook = w.y * (1 - calm)
        let cleared = min(1, max(0, (phase - phase.rounded(.down) - 2.0 / 3) * 3))
        let km = Self.km(dial: p.number("distance")) + Self.retreat(phase: phase) + Self.settleKm * calm

        // Wall Cloud: the turn, the inflow and the glows.
        let tight = min(1, energy + 0.3 * tension * (1 - energy))
        wall.step(dt: fdt, energy: energy, tightness: tight, reduceMotion: reduce)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // The storm's rain and hail, the base's darkness and the green under the core.
        let stormRain = min(1, 0.15 * w.x + 0.6 * coreLook + max(w.z * (0.5 - 0.25 * cleared), 0.4 * calm))
        dropHail *= exp(-fd / 10)
        hailBurst *= exp(-fd / 6)
        farCell *= exp(-fd / 1.2)
        rainbowSurprise = max(0, rainbowSurprise - fd / 25)
        let hailRaw = 0.12 * w.x + 0.5 * coreLook + 0.08 * clearLook + 0.35 * energy * (1 - 0.7 * clearLook)
        let hail = min(1, hailRaw + 0.55 * hailBurst + 0.6 * dropHail)
        let darkness = min(1, max(0, 0.35 + 0.4 * energy + 0.2 * tension + 0.15 * coreLook - 0.3 * clearLook))
        let green = 0.12 * min(1, 0.6 * coreLook + 0.4 * tension + 0.3 * drop) * (1 - clearLook)
        let rainHere = stormRain * Self.smooth(5, 0.5, km)

        // A big moment: a strike at the storm's distance, its thunder late by that distance; the first one lifts the
        // flock; a close one shakes the camera. The drop is the gust front.
        var thunder: [QueuedThunder] = []
        if let m = moment {
            let power = min(1, max(0.3, m.strength.isFinite ? m.strength : 0.3))
            let strike = makeStrike(km: km, strength: power)
            strikes.append(strike)
            if strikes.count > Self.strikeCap { strikes.removeFirst(strikes.count - Self.strikeCap) }
            thunder.append(QueuedThunder.strike(km: Double(strike.distanceKm), strength: Double(power)))
            flock.lift()
            if strike.distanceKm < Self.closeKm { shake(0.5 + 0.5 * (1 - strike.distanceKm / Self.closeKm)) }
            if m.isDrop {
                startGust()
                dropHail = 1
                shake(1)
            }
        }
        // A picked Gust front plays as the drop as its dust wall arrives.
        let frontHit = rawSky.gustFront?.stage == .hit
        if frontHit && !skyFrontHit { startGust() }
        skyFrontHit = frontHit
        for i in strikes.indices { strikes[i].age += fd }
        strikes.removeAll { $0.age >= GroundStrike.life }

        // Surprises.
        if let sp = surprise { surprised(sp, km: km, weights: w) }
        if var f = funnel {
            f.age += fd
            funnel = f.age >= f.duration ? nil : f
        }

        // The wind over the field: the inflow toward the storm (stronger as you play and as tension gathers, easing as it
        // clears), and the gust front's wave with the outflow behind it.
        let inflow = (2 + 3 * energy + 2 * tension) * (1 - 0.5 * clearLook)
        wind.set(steady: simd_normalize(SIMD2<Float>(0.35, 1)) * inflow)
        wind.step(dt: fdt)
        var wave: Float?
        if let a = gustAge {
            let age = a + fd
            let travelled = Self.gustSpeed * age
            if travelled <= Self.gustStart { wave = travelled / Self.gustStart }
            gustAge = travelled > Self.gustStart + Self.gustTail + Self.gustWidth ? nil : age
        }
        let here = wind.sample(.zero)
        let outflow = min(1, max(0, -here.y / Self.gustStrength))
        var dust: Float = 0
        if let a = gustAge {
            let travelled = Self.gustSpeed * a
            dust = Self.smooth(0, 40, travelled) * (1 - Self.smooth(Self.gustStart, Self.gustStart + Self.gustTail, travelled))
        }
        if let g = rawSky.gustFront { dust = max(dust, g.dust * g.amount) }

        // The flock: up on the first moment, away ahead of the front.
        flock.setQuality(quality)
        let unalarmed = flock.state == .grounded || flock.state == .wheeling
        if gustAge != nil, unalarmed { flock.flee(awayFromStorm: SIMD2(-0.35, -1)) }
        flock.step(dt: fdt, energy: energy)

        // The camera: facing away from the sun (so it lights the storm), a slow dolly back as the storm comes on, and a
        // shake on a close strike and at the drop.
        let target = Self.norm(rawSky.sun.azimuth + 180)
        if let az = camera { camera = Self.norm(az + Self.turn(from: az, to: target) * (1 - exp(-fdt / Self.cameraTau))) }
        else { camera = target }
        let closeness = 1 - min(1, km / Self.farthestKm)
        let dollyTarget: Float = reduce ? 0 : Self.dollyMetres * closeness * (0.4 + 0.6 * energy)
        dolly += (dollyTarget - dolly) * (1 - exp(-fd / 8))
        if reduce { dolly = 0; shakeAmount = 0 }
        shakeAge += fd
        var shakeNow = SIMD2<Float>(0, 0)
        if shakeAge < Self.shakeSeconds, shakeAmount > 0 {
            let x = 1 - shakeAge / Self.shakeSeconds
            let a = Self.shakePixels * min(1, shakeAmount) * x * x * sin(2 * Float.pi * 16 * shakeAge + 0.6)
            let spinAngle = shakePhase + 9 * shakeAge
            shakeNow = SIMD2(cos(spinAngle), sin(spinAngle)) * a
        }

        // The light after it: rays under the anvil's edge with the sun up and low, a double rainbow in the rain with the
        // sun 1°–42° up, the stars behind once it's dark.
        let alt = Float(rawSky.sun.altitude.isFinite ? rawSky.sun.altitude : -90)
        let rays = clearLook * Self.smooth(-3, 1, alt) * (1 - Self.smooth(25, 40, alt))
        let wet = Self.smooth(0.2, 0.3, stormRain)
        let bowSun = Self.smooth(1, 4, alt) * (1 - Self.smooth(38, 42, alt))
        let bow = min(1, max(clearLook * wet, rainbowSurprise)) * bowSun
        let stars = clearLook * (1 - Self.smooth(-10, -4, alt))
        let after = SupercellAfter(rays: rays, rainbow: bow, stars: stars)

        // The sky the world shows: the storm's own weather (a few far clouds behind it, its rain only where its core is,
        // its wind), no generic lightning (the strikes are the world's) and no rainbow of the sky's (the world draws it).
        var s = rawSky
        s.cloudCover = 0.18 + 0.12 * w.x
        s.rain = rainHere
        s.snow = 0
        s.mist = min(1, 0.1 + 0.15 * coreLook + 0.35 * dust)
        s.wind = min(1, (inflow + Self.gustStrength * outflow) / 14)
        s.gust = max(s.gust, outflow)
        s.lightning = 0
        s.rainbow = 0
        s.fireflies = 0
        s.halo = 0
        s.iridescence = 0

        // Keys: fence posts lit white while held, then fading.
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.0 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.8) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        let ambience = scene(sky: s, km: km, hail: hail, energy: energy, tension: tension, clearLook: clearLook,
                             stormRain: stormRain, rainHere: rainHere, outflow: outflow, thunder: thunder, roles: roles)
        return SupercellFrame(sky: s, viewAzimuth: camera ?? target, distanceKm: km, rotationRPM: wall.rpm,
                              rotation: wall.rotation, spin: wall.spin, inflowTightness: wall.tightness,
                              inflowSpacing: WallCloud.spacing(tightness: wall.tightness), baseDarkness: darkness,
                              greenCast: green, hailDensity: hail, stormRain: stormRain,
                              stage: SupercellStage.event(at: phase), phase: phase, stageWeights: w, clearing: clearLook,
                              strikes: strikes, gustWave: wave, dust: dust, wind: wind, flock: flock.birds,
                              cameraShake: shakeNow, cameraDolly: dolly,
                              glows: warping ? [] : wall.glows, pulses: warping ? [] : wall.pulses,
                              ripples: warping ? [] : wall.ripples, funnel: funnel, farCell: farCell, after: after,
                              energy: energy, tension: tension, drop: drop, reduceMotion: reduce, keys: keys,
                              ambience: ambience, mood: mood, time: time, warp: warping ? warpFrame : nil)
    }

    // MARK: - Events

    /// A strike at the storm's distance: toward the core and the hail shaft (left of the middle) while the storm is off,
    /// anywhere round you when it is overhead; the biggest moments come down from high on the storm's side.
    private mutating func makeStrike(km: Float, strength: Float) -> GroundStrike {
        let seed = rng.next()
        let spread: Float = km < 3 ? 40 : 1
        let bearing = km < 3 ? rng.range(-spread, spread) : rng.range(-24, 10)
        let top: Float = strength >= 0.6 ? rng.range(3, 6) : 1.3
        let strike = GroundStrike(id: nextStrikeID, distanceKm: max(0.3, km), bearing: bearing, topKm: top,
                                  strength: strength, seed: seed, age: 0)
        nextStrikeID = nextStrikeID &+ 1
        return strike
    }

    /// The camera shakes once (spec §3, §8.2): ≤ 6 px over 0.4 s; never under Reduce Motion.
    private mutating func shake(_ amount: Float) {
        guard !excite.reduceMotion else { return }
        let ongoing: Float = shakeAge < Self.shakeSeconds ? shakeAmount : 0
        shakeAge = 0
        shakeAmount = min(1, max(ongoing, amount))
        shakePhase = rng.range(0, 2 * Float.pi)
    }

    /// The gust front sets out from the field's far edge toward the camera.
    private mutating func startGust() {
        wind.addGust(from: SIMD2(0, Self.gustStart), direction: SIMD2(0, -1), speed: Self.gustSpeed, width: Self.gustWidth,
                     strength: Self.gustStrength, tail: Self.gustTail)
        gustAge = 0
    }

    private mutating func surprised(_ s: WorldSurprise, km: Float, weights w: SIMD3<Float>) {
        switch s.index {
        case 0:
            // A funnel: far (3 km or more), while the storm turns (not as it clears), once an evening.
            let evening = Self.evening(rawSky)
            guard funnel == nil, km >= 3, w.x + w.y > 0.5, lastFunnelEvening != evening else { return }
            lastFunnelEvening = evening
            var r = SeededRandom(seed: s.seed)
            funnel = StormFunnel(age: 0, duration: r.range(8, 14), seed: s.seed)
        case 1:
            hailBurst = 1
        case 2:
            farCell = 1
        default:
            rainbowSurprise = 1
        }
    }

    // MARK: - Ambience

    /// The storm family (spec §8.3): the grass's rustle on the wind, hail on a far shed's tin roof (rate and level with the
    /// hail, louder as the storm comes close), the flock's calls as it flees (only after a moment has lifted it), the
    /// thunder roll (it plays the queue), the inflow's roar with Energy, and the smell of rain on dust before the rain.
    public static func levels(_ s: SkyState, km: Float, hail: Float, energy: Float, tension: Float, clearing: Float,
                              stormRain: Float, rainHere: Float, outflow: Float, alarm: Float) -> [AmbienceSource: Double] {
        let near = Double(0.35 + 0.65 * smooth(14, 2, km))
        let wind = Double(min(1, max(0, s.wind.isFinite ? s.wind : 0)))
        var levels: [AmbienceSource: Double] = [
            .grassWind: min(1, 0.25 + 0.5 * wind + 0.35 * Double(outflow)),
            .hailOnTin: Double(min(1, max(0, hail))) * near,
            .birdsFlee: 0.6 * Double(min(1, max(0, alarm))),
            .thunderRoll: 0.85,
            .inflowRoar: Double(min(1, 0.12 + 0.6 * energy + 0.2 * tension)) * Double(1 - 0.5 * clearing),
            .rainOnDust: Double(min(1, 0.5 * stormRain * smooth(16, 4, km) * (1 - rainHere) + 0.45 * rainHere)),
            .breeze: 0.2,
        ]
        WeatherAmbience.levels(s, base: &levels)
        return levels
    }

    private func scene(sky s: SkyState, km: Float, hail: Float, energy: Float, tension: Float, clearLook: Float,
                       stormRain: Float, rainHere: Float, outflow: Float, thunder: [QueuedThunder],
                       roles: RoleValues) -> AmbienceScene {
        let levels = Self.levels(s, km: km, hail: hail, energy: energy, tension: tension, clearing: clearLook,
                                 stormRain: stormRain, rainHere: rainHere, outflow: outflow, alarm: flock.alarm)
        let night = MoonlitLakeModel.smooth(-3, -9, s.sun.altitude)
        let sinceDusk = (s.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.55, mood), density: MoodLook.ambienceDensity(mood),
                             wetness: Double(s.wetness), thunderQueue: thunder)
    }
}

extension SupercellSkyModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the storm",
                  kind: .choice(visuals), defaultValue: .choice("Wall Cloud")),
        slider("distance", "Distance", "Storm", 0...1, 0.45, hero: true, surprise: 0.2...0.8,
               help: "How far off the storm is: from 30 km away on the horizon to right overhead"),
        SupercellStage.spec(default: .core),
        SkyHold.spec(default: .goldenHour),
        MeteorMode.spec(default: .follow),
        SkyExtraMode.spec(id: SkyExtraMode.crawlersID, name: "Anvil crawlers",
                          help: "Spider lightning creeping across the anvil's underside", default: .natural),
        SkyExtraMode.spec(id: SkyExtraMode.sheetID, name: "Sheet lightning",
                          help: "Far flashes lighting the clouds on the rim of the sky", default: .natural),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A line of fence posts along the bottom, lit white where you play",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the fence posts are"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [], .speed: [], .density: [], .glow: [], .chaos: [], .temperature: [],
    ]
}
