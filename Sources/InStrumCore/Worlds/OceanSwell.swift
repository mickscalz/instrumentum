import Foundation
import simd

/// One wave of the swell. `strength` is 0…1 after the weather's scale (clamped at 1).
public struct Wave: Equatable {
    public var breakTime: Double
    public var strength: Float
    /// Seconds since the wave before it.
    public var period: Double
    /// Part of a set (the bigger waves), not a lull.
    public var big: Bool

    public init(breakTime: Double, strength: Float, period: Double, big: Bool) {
        self.breakTime = breakTime; self.strength = strength; self.period = period; self.big = big
    }
}

/// The sea's swell as a seeded schedule: waves 8–12 s apart, in sets of 3–5 bigger ones with lulls of 2–4
/// smaller ones between. Each break is an event the picture and the surf sound share, and the wash it
/// sends up the sand is a pure function of time. The same seed always gives the same waves.
public struct OceanSwell {
    /// Weather's effect on the swell (see `weatherScale`).
    public var scale: Float = 1
    public private(set) var time: Double = 0
    /// The last few waves that broke (newest last), with the strength they broke at.
    public private(set) var recent: [Wave] = []

    /// Scheduled waves with their calm-weather strengths.
    private var schedule: [Wave] = []
    private var rng: SeededRandom
    private var runLeft = 0
    private var inSet = false
    private var lastBreak = 0.0
    /// Swell components' phases at time 0 (radians) and their periods (seconds).
    private let phase0: SIMD4<Double>
    private static let componentPeriods = SIMD4<Double>(9.7, 11.3, 7.1, 5.3)
    private static let lookAhead = 40.0
    /// Seconds from a break until its wash reaches the sand: the white water's run in from the break line (the
    /// beach draws 11 m of it at 4.4 m/s), so the wash slides up the sand as the foam arrives, not before.
    public static let washDelay = 2.5
    private static let keepRecent = 6

    public init(seed: UInt64) {
        rng = SeededRandom(seed: seed ^ 0x5E11_0CEA)
        phase0 = SIMD4(Double(rng.unit()), Double(rng.unit()), Double(rng.unit()), Double(rng.unit())) * 2 * .pi
        lastBreak = Double(rng.range(1, 4))
        inSet = rng.unit() < 0.5
        runLeft = Int(rng.range(2, 4.99))
        schedule.append(Wave(breakTime: lastBreak, strength: nextStrength(), period: 0, big: inSet))
        runLeft -= 1
        fillAhead()
    }

    /// Clear and light cloud 1, rain and drizzle 1.2, a storm 1.8 (bigger and steeper), mist 0.8, and sea smoke 0.4
    /// (it needs still air); blended while the weather changes.
    public static func weatherScale(_ s: SkyState) -> Float {
        func base(_ k: WeatherKind) -> Float {
            switch k {
            case .clear, .lightCloud, .overcast, .snow: return 1
            case .rain, .drizzle: return 1.2
            case .storm: return 1.8
            case .blizzard: return 1.6
            case .mist: return 0.8
            case .afterRain: return 0.9
            case .sunShower: return 1.1
            case .fogBank, .smokeHaze, .iceFog: return 0.8
            case .thunderheads: return 1.2
            case .flurries: return 1
            case .dryLightning: return 1.2
            case .freezingDrizzle: return 1.1
            case .squall: return 1.7
            case .dustStorm: return 1.3
            case .hail: return 1.4
            case .sleet: return 1.3
            case .monsoon: return 1.7
            case .humid: return 0.9
            case .diamondDust: return 0.3
            case .rime: return 0.3
            case .seaSmoke: return 0.4
            case .gustFront: return 1.7   // the outflow whips the sea up as a squall does
            case .virga: return 1
            case .ashfall: return 0.8    // still air under the ash
            case .supercell: return 1.6  // its outflow and squalls stir the sea
            }
        }
        let b = min(1, max(0, s.weatherBlend))
        return base(s.weather) * (1 - b) + base(s.nextWeather) * b
    }

    /// Advances the swell; returns the waves that broke during this step.
    public mutating func step(dt: Double) -> [Wave] {
        time += max(0, dt)
        var broke: [Wave] = []
        while let first = schedule.first, first.breakTime <= time {
            schedule.removeFirst()
            var w = first
            w.strength = min(1, w.strength * scale)
            broke.append(w)
            recent.append(w)
        }
        if recent.count > Self.keepRecent { recent.removeFirst(recent.count - Self.keepRecent) }
        fillAhead()
        return broke
    }

    /// A big wave out of turn (Fire & Neon spec §5.5, the beach's drop): the next wave due at least `after` seconds from
    /// now breaks at `strength` (before the weather's scale) if that is bigger than its own, as part of a set. Returns
    /// that wave as it was, or nil when none is due in the schedule's 40 s. The schedule keeps its times, so the crest
    /// already rolling in is the one that grows.
    @discardableResult
    public mutating func surge(strength: Float, after: Double) -> Wave? {
        guard strength.isFinite, let i = schedule.firstIndex(where: { $0.breakTime >= time + max(0, after) }) else { return nil }
        let was = schedule[i]
        schedule[i].strength = max(was.strength, min(1.5, strength))
        schedule[i].big = true
        return was
    }

    /// The next `n` waves still to break, at the current weather's strength.
    public func upcoming(_ n: Int) -> [Wave] {
        schedule.prefix(n).map { var w = $0; w.strength = min(1, w.strength * scale); return w }
    }

    /// How far up the sand the wash reaches at time `t`: 0 at the waterline … 1 at the top of the wet sand.
    /// Each wave's wash arrives `washDelay` after it breaks, rises (ease-out) to 0.3 + 0.6 × strength over
    /// 1.2–2 s, then drains by 6 s.
    public func washFront(at t: Double) -> Float {
        var front: Float = 0
        for w in recent {
            let a = t - w.breakTime - Self.washDelay
            guard a > 0, a < 6 else { continue }
            let peak = 0.3 + 0.6 * w.strength
            let rise = 1.2 + 0.8 * Double(w.strength)
            let v: Float
            if a < rise {
                let x = Float(a / rise)
                v = peak * (1 - (1 - x) * (1 - x))
            } else {
                v = peak * Float(1 - (a - rise) / (6 - rise))
            }
            front = max(front, v)
        }
        return min(1, front)
    }

    /// The four swell components' phases at time `t`, accumulated in Double and wrapped to 0..<2π (so shaders
    /// never see a large Float time, however long the session).
    public func phases(at t: Double) -> SIMD4<Float> {
        var out = SIMD4<Float>()
        for i in 0..<4 {
            let p = (phase0[i] + 2 * .pi * t / Self.componentPeriods[i]).truncatingRemainder(dividingBy: 2 * .pi)
            out[i] = Float(p < 0 ? p + 2 * .pi : p)
            if out[i] >= 2 * .pi { out[i] = 0 }
        }
        return out
    }

    // MARK: - Schedule

    /// A set's waves are 0.45–0.75 in calm weather, a lull's 0.12–0.35 (leaving headroom for storms).
    private mutating func nextStrength() -> Float {
        inSet ? rng.range(0.45, 0.75) : rng.range(0.12, 0.35)
    }

    private mutating func fillAhead() {
        while (schedule.last?.breakTime ?? lastBreak) < time + Self.lookAhead {
            if runLeft <= 0 {
                inSet.toggle()
                runLeft = inSet ? Int(rng.range(3, 5.99)) : Int(rng.range(2, 4.99))
            }
            let period = Double(rng.range(8, 12))
            let at = (schedule.last?.breakTime ?? lastBreak) + period
            schedule.append(Wave(breakTime: at, strength: nextStrength(), period: period, big: inSet))
            lastBreak = at
            runLeft -= 1
        }
    }
}
