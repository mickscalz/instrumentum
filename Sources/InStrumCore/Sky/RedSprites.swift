import Foundation

// Red sprites and far storms (Fire & Neon spec §6.1). A sprite is a faint red flash 50–90 km up over a strong
// thunderstorm a few hundred kilometres away: a diffuse red crown with fine tendrils hanging under it that turn
// blue-violet low down, and now and then thin streamers reaching up; lit for a tenth of a second, often two or three
// columns at once. They are seen at night over a storm far enough off that its anvil is a dark shape on the horizon,
// flickering from inside. On a clear night the sky can have such a storm of its own now and then (a far storm), and the
// sprites stand over it. Everything here is seeded and stepped in the sky's own seconds, each machine on its own streams.

/// A far storm on the horizon now (spec §6.1): a storm beyond the horizon in one direction, its anvil's top a degree or
/// three up, lit from inside by lightning every few seconds.
public struct FarStormNow: Equatable {
    /// Its bearing (degrees from north, clockwise) and how far off it is (km).
    public var bearing: Float
    public var distanceKm: Float
    /// How far its anvil's top stands over the horizon (degrees) and how wide it is (degrees of azimuth, edge to edge).
    public var top: Float
    public var width: Float
    /// How much of it there is, 0…1: it comes onto the horizon over a minute and goes over one.
    public var amount: Float
    /// A new number for each storm, so a renderer stages it once (and never follows the camera with it).
    public var episode: Int
    /// The lightning inside its cloud now (0…1, before the sky's flash limiter), and where: degrees across from its
    /// centre, and how far up the cloud (0 at the horizon … 1 at the anvil's top).
    public var flicker: Float
    public var flickerAcross: Float
    public var flickerUp: Float

    public init(bearing: Float, distanceKm: Float, top: Float, width: Float, amount: Float, episode: Int,
                flicker: Float = 0, flickerAcross: Float = 0, flickerUp: Float = 0.5) {
        self.bearing = bearing; self.distanceKm = distanceKm; self.top = top; self.width = width; self.amount = amount
        self.episode = episode; self.flicker = flicker; self.flickerAcross = flickerAcross; self.flickerUp = flickerUp
    }

    /// Its in-cloud flicker's share of the sky's luminance at most (a small patch low on the horizon: never a flash, but
    /// the sky's limiter counts it).
    public static let flickerLight: Float = 0.02
}

/// The far storms' machine (spec §6.1): on a clear night (the sky dark and its own weather dry and mostly clear), one
/// every 2–4 hours of such viewing on Natural (Often: three times as many), each lasting 5–20 minutes, at a seeded
/// bearing and distance; while one stands, lightning flickers inside it every 1.5–7 s in bursts of one to three strokes.
/// The clock between storms runs only while the night is clear, and the first storm waits a whole gap.
public struct FarStorms {
    /// The gaps between storms on Natural (seconds of clear-night viewing); Often divides them by 3.
    public static let gaps = 7200.0...14_400.0
    public static let oftenFactor = 3.0
    /// How long each one lasts (seconds), and how long it takes to come onto the horizon and to go.
    public static let durations = 300.0...1200.0
    public static let fadeSeconds = 60.0
    /// How far off (km): the anvil's top 1.2–3.7° up at these distances (it sinks below the horizon past them), under
    /// the sprites' 4–9°.
    public static let distances = 200.0...340.0
    /// The anvil's top (km) and Earth's radius (km), for its height over the horizon.
    public static let anvilKm = 16.0
    public static let earthKm = 6371.0
    /// Its width edge to edge (degrees of azimuth).
    public static let widths = 16.0...30.0
    /// The gaps between in-cloud flashes (seconds) and each burst's length.
    public static let flickerGaps = 1.5...7.0
    public static let burstSeconds = 0.15...0.5
    /// A clear night: the sun below this (degrees), the sky's cloud under `clearCloud` and no rain or snow.
    public static let darkBelow = -6.0
    public static let clearCloud: Float = 0.6

    /// The machine's clock (seconds of sky time), the storms begun so far and their start times (the last 512).
    public private(set) var time = 0.0
    public private(set) var spawned = 0
    public private(set) var births: [Double] = []
    /// The storm on the horizon now, if any (internal for tests).
    private(set) var current: Storm?
    /// Test seam: start a storm at once on the next eligible step.
    var forceStart = false

    struct Storm {
        var bearing: Double, distance: Double, width: Double, born: Double, duration: Double, episode: Int
        var amount = 0.0
        var ending = false
        var burstAt = 0.0, burstLength = 0.3, burstAcross = 0.0, burstUp = 0.5
        var strokes: [(at: Double, width: Double, amplitude: Double)] = []
        var nextBurst = 1.0
    }

    private var gapRng: SeededRandom
    private var shapeRng: SeededRandom
    private var flickerRng: SeededRandom
    private var wait: Double
    private var phase = 0.0
    private var episode = 0

    public init(seed: UInt64) {
        var g = SeededRandom(seed: seed &* 0xF1A5_4C0B_9E2D_3317 &+ 0xFA2)
        wait = AnvilCrawlers.unit(&g)
        gapRng = g
        shapeRng = SeededRandom(seed: seed &* 0x9C2F_0D4B_6E1A_7F35 &+ 0x5A7E)
        flickerRng = SeededRandom(seed: seed &* 0xB4E6_2A91_C3D7_5F09 &+ 0xF11C)
    }

    /// The gap a draw `u` stands for (seconds).
    static func gap(_ u: Double, mode: SkyExtraMode) -> Double {
        (gaps.lowerBound + u * (gaps.upperBound - gaps.lowerBound)) / (mode == .often ? oftenFactor : 1)
    }

    /// `n` uniform draws in 0…<1 from `r`.
    static func draws(_ n: Int, _ r: inout SeededRandom) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(AnvilCrawlers.unit(&r)) }
        return out
    }

    /// The anvil's top over the horizon (degrees) for a storm `km` off: its height less the Earth's curve there.
    public static func anvilTop(km: Double) -> Double {
        let drop = km * km / (2 * earthKm)
        return atan2(anvilKm - drop, km) * 180 / .pi
    }

    /// Advances `dt` seconds. `eligible`: a clear night here (spec §6.1). Off starts none (a storm already standing
    /// goes). Returns the storm on the horizon at the end of the step, if any.
    public mutating func step(dt rawDt: Double, mode: SkyExtraMode, eligible: Bool) -> FarStormNow? {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        time += dt
        if current == nil, mode != .off, eligible {
            if forceStart {
                forceStart = false
                begin(at: time)
            } else {
                var left = dt
                let span = Self.gap(wait, mode: mode)
                let need = (1 - phase) * span
                if need <= left {
                    left -= need
                    begin(at: time - left)
                    phase = 0
                    wait = AnvilCrawlers.unit(&gapRng)
                } else {
                    phase += left / span
                }
            }
        }
        guard var s = current else { return nil }
        let age = time - s.born
        if !eligible || mode == .off { s.ending = true }
        // In over a minute, out over a minute at its end (or as soon as the night stops being clear).
        let rise = min(1, age / Self.fadeSeconds)
        var target = rise
        if s.ending || age >= s.duration - Self.fadeSeconds {
            s.ending = true
            target = 0
        }
        if target < s.amount { s.amount = max(target, s.amount - dt / Self.fadeSeconds) } else { s.amount = target }
        if s.ending, s.amount <= 0 {
            current = nil
            return nil
        }
        // The flicker: a burst every 1.5–7 s, one to three strokes inside it, the first the brightest.
        while time >= s.nextBurst {
            let u = Self.draws(8, &flickerRng)
            s.burstAt = s.nextBurst
            s.burstLength = Self.burstSeconds.lowerBound + u[0] * (Self.burstSeconds.upperBound - Self.burstSeconds.lowerBound)
            s.burstAcross = (u[1] - 0.5) * 0.7 * s.width
            s.burstUp = 0.25 + 0.6 * u[2]
            let count = 1 + min(2, Int(u[3] * 3))
            s.strokes = [(0, min(s.burstLength, 0.05 + 0.06 * u[4]), 1)]
            if count > 1 { s.strokes.append(((0.3 + 0.3 * u[5]) * s.burstLength, 0.05, 0.4 + 0.5 * u[6])) }
            if count > 2 { s.strokes.append((0.7 * s.burstLength, 0.05, 0.3 + 0.4 * u[7])) }
            s.nextBurst += Self.flickerGaps.lowerBound + AnvilCrawlers.unit(&flickerRng)
                * (Self.flickerGaps.upperBound - Self.flickerGaps.lowerBound)
        }
        var level = 0.0
        let since = time - s.burstAt
        for k in s.strokes where k.width > 0 {
            let x = (since - k.at) / k.width
            if x >= 0 && x <= 1 { let b = sin(Double.pi * x); level += k.amplitude * b * b }
        }
        current = s
        return FarStormNow(bearing: Float(s.bearing), distanceKm: Float(s.distance),
                           top: Float(Self.anvilTop(km: s.distance)), width: Float(s.width), amount: Float(s.amount),
                           episode: s.episode, flicker: Float(min(1, level)) * Float(s.amount),
                           flickerAcross: Float(s.burstAcross), flickerUp: Float(s.burstUp))
    }

    /// Five draws a storm, whatever it uses, so the stream keeps its step.
    private mutating func begin(at t: Double) {
        let u = Self.draws(5, &shapeRng)
        episode += 1
        var s = Storm(bearing: 360 * u[0],
                      distance: Self.distances.lowerBound + u[1] * (Self.distances.upperBound - Self.distances.lowerBound),
                      width: Self.widths.lowerBound + u[2] * (Self.widths.upperBound - Self.widths.lowerBound),
                      born: t,
                      duration: Self.durations.lowerBound + u[3] * (Self.durations.upperBound - Self.durations.lowerBound),
                      episode: episode)
        s.nextBurst = t + 1 + 3 * u[4]
        current = s
        spawned += 1
        births.append(t)
        if births.count > 512 { births.removeFirst(births.count - 512) }
    }
}

/// A red sprite in the sky now (spec §6.1): a cluster of one to three columns over a storm.
public struct SpriteSlot: Equatable {
    /// Where it stands: its azimuth (degrees from north, clockwise; the cluster's middle), the altitude of its lowest
    /// tendrils (4–9°) and its height from there to its top (2–4°).
    public var azimuth: Float
    public var base: Float
    public var height: Float
    /// Its columns (1–3) and the gap between them (degrees).
    public var columns: Int
    public var spread: Float
    /// Its shape (0 a carrot: a narrow crown with tendrils fanning down … 1 a jellyfish: a broad crown with tendrils
    /// hanging straight), how much its streamers reach up from the crown (0…1), and a seed for its tendrils (0…1).
    public var shape: Float
    public var streamers: Float
    public var seed: Float
    /// When it lit (seconds on the sprites' clock) and how long it stays lit (0.08–0.16 s), before a 60 ms fade.
    public var born: Double
    public var lit: Float
    /// Its brightness at full light (a share of the sky's luminance, 0.015–0.04), its light now (0…1) and its
    /// brightness now (peak × level, after the sky's flash limiter).
    public var peak: Float
    public var level: Float
    public var brightness: Float
    /// A big moment called it.
    public var called: Bool

    public init(azimuth: Float, base: Float, height: Float, columns: Int, spread: Float, shape: Float, streamers: Float,
                seed: Float, born: Double, lit: Float, peak: Float, level: Float = 0, brightness: Float = 0, called: Bool = false) {
        self.azimuth = azimuth; self.base = base; self.height = height; self.columns = columns; self.spread = spread
        self.shape = shape; self.streamers = streamers; self.seed = seed; self.born = born; self.lit = lit; self.peak = peak
        self.level = level; self.brightness = brightness; self.called = called
    }

    /// Its crown's red and its low tendrils' blue-violet (linear, never a saturated red: the red is 65% of its light).
    public static let crown = SIMD3<Float>(1.0, 0.33, 0.22)
    public static let tendril = SIMD3<Float>(0.5, 0.36, 1.0)
}

/// The red sprites' machine (spec §6.1): while it is night (the sun below −12°) and there is a storm to stand over (this
/// sky's storm, thunderheads or dry lightning, or a far storm), a sprite every 20–60 s on Natural (Often: three times as
/// often), and one at a big moment's call; each one 1–3 columns within 6° of the storm's bearing, lit for 80–160 ms and
/// fading over 60 ms, never brighter than 0.04 of the sky's luminance.
public struct RedSprites {
    public static let slots = 3
    public static let gaps = 20.0...60.0
    public static let oftenFactor = 3.0
    public static let litSeconds = 0.08...0.16
    public static let fadeSeconds = 0.06
    public static let dimmest: Float = 0.015, brightest: Float = 0.04
    public static let darkBelow = -12.0
    public static let bases = 4.0...9.0
    public static let heights = 2.0...4.0
    /// How far a sprite strays from its storm's bearing (degrees, either way).
    public static let stray = 6.0
    static let callSpacing = 1.0
    static let arrivalCap = 64

    /// Whether a call could bring sprites to this sky (as `LivingSky` decides it): night, and a storm to stand over (a
    /// far one, or the weather's own). A world asks before calling them (its own surprise).
    public static func couldStand(over s: SkyState) -> Bool {
        guard s.sun.altitude < darkBelow else { return false }
        let kinds: [WeatherKind] = [.storm, .thunderheads, .dryLightning]
        let t = min(1, max(0, s.weatherBlend.isFinite ? s.weatherBlend : 0))
        let blend = t * t * (3 - 2 * t)
        let weather = (kinds.contains(s.weather) ? 1 - blend : 0) + (kinds.contains(s.nextWeather) ? blend : 0)
        let far = s.farStorm.isFinite ? s.farStorm : 0
        return weather + far >= 0.5
    }

    public private(set) var time = 0.0
    public private(set) var spawned = 0
    public private(set) var births: [Double] = []
    /// The storm's bearing when the sky has none of its own (a storm overhead): drawn afresh as each one begins.
    public private(set) var bearing = 0.0
    /// A new number each time sprites begin over a storm that has no bearing of its own (for staging).
    public private(set) var episode = 0
    private(set) var live: [SpriteSlot] = []
    private var shapeRng: SeededRandom
    private var gapRng: SeededRandom
    private var bearingRng: SeededRandom
    private var wait: Double
    private var phase = 0.0
    private var lastCall = -1e9
    private var wasEligible = false

    public init(seed: UInt64) {
        shapeRng = SeededRandom(seed: seed &* 0xC6A4_A793_5BD1_E995 &+ 0x5B21)
        var g = SeededRandom(seed: seed &* 0x8538_ECB5_BD45_6EA3 &+ 0x6A95)
        wait = AnvilCrawlers.unit(&g)
        gapRng = g
        bearingRng = SeededRandom(seed: seed &* 0xD6E8_FEB8_6659_FD93 &+ 0xBEA)
    }

    static func gap(_ u: Double, mode: SkyExtraMode) -> Double {
        (gaps.lowerBound + u * (gaps.upperBound - gaps.lowerBound)) / (mode == .often ? oftenFactor : 1)
    }

    /// A sprite's light at `age` seconds: a 5 ms rise, full while lit, then falling to nothing over 60 ms.
    public static func level(age: Double, lit: Double) -> Float {
        guard age >= 0 else { return 0 }
        let rise = min(1, age / 0.005)
        if age <= lit { return Float(rise) }
        let f = max(0, 1 - (age - lit) / fadeSeconds)
        return Float(f * f)
    }

    /// Advances `dt` seconds. `eligible`: night and a storm to stand over (spec §6.1); `bearing`: that storm's (nil: one
    /// of its own, drawn as each spell of sprites begins); `call`: a big moment's strength this step. Off makes none.
    /// Returns the sprites lit at the end of the step (before the sky's flash limiter).
    public mutating func step(dt rawDt: Double, mode: SkyExtraMode, eligible: Bool, bearing storm: Double? = nil,
                              call: Float? = nil) -> [SpriteSlot] {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let start = time
        time += dt
        if eligible && !wasEligible {
            bearing = 360 * AnvilCrawlers.unit(&bearingRng)
            episode += 1
        }
        wasEligible = eligible
        let toward = storm.flatMap { $0.isFinite ? $0 : nil } ?? bearing
        if mode != .off && eligible {
            var t = start, left = dt, count = 0
            while count < Self.arrivalCap {
                let span = Self.gap(wait, mode: mode)
                let need = (1 - phase) * span
                if need > left { phase += left / span; break }
                t += need
                left -= need
                spawn(at: t, bearing: toward, peak: nil)
                phase = 0
                wait = AnvilCrawlers.unit(&gapRng)
                count += 1
            }
            if let s = call, s.isFinite, time - lastCall >= Self.callSpacing {
                lastCall = time
                let k = Double(min(1, max(0, s)))
                spawn(at: time, bearing: toward, peak: Float(Double(Self.dimmest) + k * Double(Self.brightest - Self.dimmest)))
            }
        }
        let now = time
        live.removeAll { now - $0.born > Double($0.lit) + Self.fadeSeconds }
        return live.map { s in
            var s = s
            s.level = Self.level(age: now - s.born, lit: Double(s.lit))
            s.brightness = min(Self.brightest, s.peak * s.level)
            return s
        }
    }

    /// Nine draws a sprite, whatever it uses, so the stream keeps its step.
    private mutating func spawn(at t: Double, bearing: Double, peak forced: Float?) {
        let u = FarStorms.draws(9, &shapeRng)
        var az = (bearing + Self.stray * (2 * u[0] - 1)).truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        let columns = 1 + min(2, Int(u[1] * 3))
        let peak = forced ?? Float(Double(Self.dimmest) + u[2] * Double(Self.brightest - Self.dimmest))
        let lit = Self.litSeconds.lowerBound + u[3] * (Self.litSeconds.upperBound - Self.litSeconds.lowerBound)
        let height = Self.heights.lowerBound + u[4] * (Self.heights.upperBound - Self.heights.lowerBound)
        let base = Self.bases.lowerBound + u[5] * (Self.bases.upperBound - Self.bases.lowerBound)
        let s = SpriteSlot(azimuth: Float(az), base: Float(base), height: Float(height), columns: columns,
                           spread: Float((0.25 + 0.3 * u[6]) * height), shape: Float(u[7]),
                           streamers: u[8] < 0.35 ? Float(0.4 + u[8]) : 0, seed: Float(u[8]),
                           born: t, lit: Float(lit), peak: min(Self.brightest, max(0, peak)), called: forced != nil)
        live.append(s)
        spawned += 1
        births.append(t)
        if births.count > 512 { births.removeFirst(births.count - 512) }
        while live.count > Self.slots { live.removeFirst() }
    }
}
