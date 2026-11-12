import Foundation

// The Supercell weather (Fire & Neon spec §7.2), after backlog #6 Supercell Sky: a rotating thunderstorm on the horizon
// coming closer and passing over, staged as an event over 8 minutes of viewing by default (Advanced: 3–20):
// - Approach: a broad rain-free base on the horizon with a lowered wall cloud slowly turning, a striated tower, the anvil
//   spreading overhead, distant flicker, and the inflow gusting toward it.
// - Core: the green-tinted light under it, a hail burst, then heavy rain and close lightning.
// - Clearing: the rain easing, mammatus hanging under the anvil overhead, lit low, and the clear sky (and its stars)
//   coming in behind.
// Picked, it plays once and holds its Clearing; in Random Beautiful it plays and moves on. In any sky world it is the same
// staged event Supercell Sky's own storm runs on (`SkyState.supercell`, `supercellPhase`), drawn by the shared sky.

/// The supercell weather now: its stage and what it does to the sky.
public struct SupercellNow: Equatable {
    /// Its stage (the event's, at `phase`) and how far through it (0…1).
    public var stage: SupercellStage
    public var phase: Float
    public var stageProgress: Float
    /// How much of the sky it is (the weather machine's blend), 0…1.
    public var amount: Float
    /// Its bearing (degrees from north, clockwise) and a new number for each storm (so a renderer stages it once).
    public var bearing: Float
    public var episode: Int
    /// Where the storm's centre is (km along its bearing: ahead positive, behind negative), and the anvil's trailing edge
    /// (km ahead: the clear sky lies beyond it).
    public var distanceKm: Float
    public var anvilEdgeKm: Float
    /// The wall cloud's turn (radians; the storm's way round for the hemisphere) and how fast it turns (0…1).
    public var turn: Float
    public var rotation: Float
    /// The green under its core (a grade of at most 12%), its hail now (0…1), the mammatus under its anvil (0…1).
    public var green: Float
    public var hail: Float
    public var mammatus: Float
    /// How much its lightning flashes (1 through the Core: close strikes the sky's lightning times), and the lightning
    /// inside its cloud now (0…1: the distant flicker, or a close flash) with a seed for where it is (0…1).
    public var lightning: Float
    public var glow: Float
    public var spot: Float
    /// The staged weather (what replaces its nominal values in the sky).
    public var cloud: Float, rain: Float, mist: Float, wind: Float, gust: Float

    public init(stage: SupercellStage = .approach, phase: Float = 0, stageProgress: Float = 0, amount: Float = 1,
                bearing: Float = 0, episode: Int = 0, distanceKm: Float = 30, anvilEdgeKm: Float = 38, turn: Float = 0,
                rotation: Float = 1, green: Float = 0, hail: Float = 0, mammatus: Float = 0, lightning: Float = 0,
                glow: Float = 0, spot: Float = 0.5, cloud: Float = 0.35, rain: Float = 0, mist: Float = 0.12, wind: Float = 0.3,
                gust: Float = 0.5) {
        self.stage = stage; self.phase = phase; self.stageProgress = stageProgress; self.amount = amount; self.bearing = bearing
        self.episode = episode; self.distanceKm = distanceKm; self.anvilEdgeKm = anvilEdgeKm; self.turn = turn
        self.rotation = rotation; self.green = green; self.hail = hail; self.mammatus = mammatus; self.lightning = lightning
        self.glow = glow; self.spot = spot; self.cloud = cloud; self.rain = rain; self.mist = mist; self.wind = wind
        self.gust = gust
    }

    /// The green grade at most (spec §7.2: real, from deep cloud and reddened sunlight).
    public static let greenest: Float = 0.12
    /// The wall cloud's turn at full rotation (revolutions a minute).
    public static let rpm: Float = 1.2
}

/// Lightning flickering inside a storm's cloud: a burst every few seconds, one to three strokes in each, the first the
/// brightest (the far storms' flicker, for a supercell's distant stages).
struct StormFlicker {
    private var rng: SeededRandom
    private var time = 0.0
    private var next = 1.0
    private var burstAt = -10.0
    private var strokes: [(at: Double, width: Double, amplitude: Double)] = []
    private(set) var spot: Float = 0.5

    init(seed: UInt64) { rng = SeededRandom(seed: seed &* 0xA3B1_9535_4A7C_15F9 &+ 0xF1C) }

    /// Advances `dt` seconds with bursts every `gaps` seconds while `active`; returns the flicker now (0…1).
    mutating func step(dt: Double, gaps: ClosedRange<Double>, active: Bool) -> Float {
        time += dt
        guard active else { next = time + gaps.lowerBound; return 0 }
        while time >= next {
            let u = FarStorms.draws(7, &rng)
            burstAt = next
            let length = 0.15 + 0.35 * u[0]
            spot = Float(u[1])
            strokes = [(0, 0.05 + 0.06 * u[2], 1)]
            if u[3] < 0.6 { strokes.append(((0.3 + 0.3 * u[4]) * length, 0.05, 0.4 + 0.5 * u[5])) }
            if u[3] < 0.25 { strokes.append((0.75 * length, 0.05, 0.3 + 0.3 * u[6])) }
            next += gaps.lowerBound + AnvilCrawlers.unit(&rng) * (gaps.upperBound - gaps.lowerBound)
        }
        var level = 0.0
        for k in strokes where k.width > 0 {
            let x = (time - burstAt - k.at) / k.width
            if x >= 0 && x <= 1 { let b = sin(Double.pi * x); level += k.amplitude * b * b }
        }
        return Float(min(1, level))
    }
}

public extension WorldWeather {
    /// The supercell event's stages at `phase` (0…1, clamped): pure, so the sky, the renderers and the tests read one
    /// schedule. Distances in km along its bearing; the stages run on into each other with no jump.
    /// - Approach (to 1/3): the storm comes from 30 km to 9 km; cloud 0.35 → 0.7 (the storm, the sky beyond it clear),
    ///   no rain (a drop or two at its end), the inflow rising (wind 0.3 → 0.6, gustiness 0.5 → 0.8), a hint of green.
    /// - Core (to 2/3): it passes over (9 km ahead → 9 km behind): cloud to 0.95, rain to 1 and easing to 0.81, a hail
    ///   burst early in it, the green at its 12% mid-core, lightning flashing through it, the wind 0.9.
    /// - Clearing: it goes (to 40 km behind), the anvil's trailing edge passing from 52 km ahead to overhead (38 km, about
    ///   17° up, where a picked one holds), the rain gone by its middle, mammatus under the anvil, the cloud thinning to
    ///   0.3 by its middle (the stars come out) and the wind dropping.
    static func supercell(phase raw: Double) -> SupercellNow {
        let p = raw.isFinite ? min(1, max(0, raw)) : 0
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return Float(t * t * (3 - 2 * t))
        }
        var c = SupercellNow()
        c.phase = Float(p)
        if p < 1.0 / 3 {
            let a = p * 3
            c.stage = .approach
            c.stageProgress = Float(a)
            let k = smooth(0, 1, a)
            c.distanceKm = 30 - 21 * k
            c.anvilEdgeKm = c.distanceKm + 8
            c.cloud = 0.35 + 0.35 * Float(a)
            c.rain = 0.05 * smooth(0.8, 1, a)
            c.mist = 0.12 + 0.06 * Float(a)
            c.wind = 0.3 + 0.3 * Float(a)
            c.gust = 0.5 + 0.3 * Float(a)
            c.green = 0.03 * Float(a)
            c.rotation = 0.7 + 0.3 * Float(a)
            return c
        }
        if p < 2.0 / 3 {
            let q = (p - 1.0 / 3) * 3
            c.stage = .core
            c.stageProgress = Float(q)
            c.distanceKm = 9 - 18 * Float(q)
            c.anvilEdgeKm = c.distanceKm + 8 + 53 * smooth(0.2, 1, q)
            c.cloud = 0.7 + 0.25 * smooth(0, 0.2, q)
            c.rain = 0.05 + 0.95 * smooth(0, 0.3, q) * (1 - 0.2 * smooth(0.6, 1, q))
            c.hail = smooth(0.06, 0.24, q) * (1 - smooth(0.35, 0.55, q))
            c.mist = 0.18 + 0.17 * smooth(0, 0.3, q)
            c.wind = 0.6 + 0.3 * smooth(0, 0.2, q) - 0.2 * smooth(0.6, 1, q)
            c.gust = 0.8 + 0.2 * smooth(0, 0.2, q)
            c.green = 0.03 + 0.09 * smooth(0, 0.25, q) - 0.12 * smooth(0.6, 1, q)
            c.lightning = smooth(0, 0.2, q) * (1 - smooth(0.8, 1, q))
            c.rotation = 1 - 0.2 * Float(q)
            return c
        }
        let q = (p - 2.0 / 3) * 3
        c.stage = .clearing
        c.stageProgress = Float(q)
        c.distanceKm = -9 - 31 * Float(q)
        c.anvilEdgeKm = 52 * Float((1 - q) * (1 + 0.9 * q))
        c.cloud = 0.25 + 0.7 * (1 - smooth(0, 0.6, q))
        c.rain = 0.81 * (1 - smooth(0, 0.45, q))
        c.mist = 0.35 - 0.2 * Float(q)
        c.wind = 0.7 - 0.5 * Float(q)
        c.gust = 1 - 0.9 * Float(q)
        c.mammatus = smooth(0, 0.25, q) * (1 - 0.5 * smooth(0.7, 1, q))
        c.rotation = 0.8 * (1 - Float(q))
        return c
    }

    /// The supercell's phase where a picked one holds (the middle of its Clearing), and where a random one ends.
    static let supercellHeld = 5.0 / 6

    /// The light of the sun or moon through ashfall's haze at `altitude` degrees (spec §7.1): an extinction of
    /// ash × (0.05, 0.085, 0.13) per airmass (Rozenberg's airmass, 40 at the horizon), so it reddens and dims, the more
    /// the lower it stands; (1, 1, 1) without ash. The sky shader mirrors it for the moon.
    static func ashTint(ash rawAsh: Float, altitude: Double) -> SIMD3<Float> {
        let ash = rawAsh.isFinite ? min(1, max(0, rawAsh)) : 0
        guard ash > 0 else { return SIMD3(1, 1, 1) }
        let h = sin(max(0, altitude.isFinite ? altitude : 0) * .pi / 180)
        let airmass = Float(1 / (h + 0.025 * exp(-11 * h)))
        let tau = SIMD3<Float>(0.05, 0.085, 0.13) * (ash * airmass)
        return SIMD3(exp(-tau.x), exp(-tau.y), exp(-tau.z))
    }

    /// The sky's colours under ash (spec §7.1): a brown-grey haze low down, a dimmed, browner zenith.
    static func ashSky(zenith: SIMD3<Float>, horizon: SIMD3<Float>, ash rawAsh: Float) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        let ash = rawAsh.isFinite ? min(1, max(0, rawAsh)) : 0
        guard ash > 0 else { return (zenith, horizon) }
        func lum(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let brown = SIMD3<Float>(1.12, 0.98, 0.8)
        let h = horizon + (brown * lum(horizon) * 0.9 - horizon) * (0.65 * ash)
        let z = (zenith + (SIMD3<Float>(1.06, 1.0, 0.9) * lum(zenith) - zenith) * (0.4 * ash)) * (1 - 0.15 * ash)
        return (z, h)
    }
}
