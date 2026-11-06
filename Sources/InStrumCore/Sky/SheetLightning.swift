import Foundation

// Sheet and heat lightning (Storms spec §6.2): a storm too far away to hear, flashing below the horizon or inside its
// own towers, so all you see is the sky's rim lit warm-white for a tenth to three tenths of a second, flickering as the
// strokes repeat, and, where there is cloud over you, the nearest cloud cell lit from inside. It never costs a flash (its
// brightness is at most 0.2, under the limiter's 0.25 rise) but the sky's limiter still counts it.

/// A sheet-lightning flash on the sky's rim now.
public struct SheetSlot: Equatable {
    /// The glow's centre (degrees from north, clockwise, 0…<360), its full width in azimuth (10–25°: a raised cosine)
    /// and how far up the rim it reaches (3–6°: an exponential in altitude, falling to e⁻² there).
    public var azimuth: Float
    public var width: Float
    public var height: Float
    /// When it began (seconds on the sheet's clock, the sky's own seconds) and how long it lasts (0.1–0.3 s).
    public var born: Double
    public var duration: Float
    /// How strong this flash is (0.5–1), and its flicker now (0…1: one to three strokes, the first the brightest).
    public var strength: Float
    public var level: Float
    /// The rim's brightening now, a share of the sky's luminance: 0.2 × strength × level at most, after the sky's
    /// `FlashLimiter`.
    public var brightness: Float
    /// Its light: a warm white.
    public var colour: SIMD3<Float>
    /// The nearest cloud cell to the flash: the centre of the cell of the cloud deck (the cloud layer's own coordinates
    /// at rest, `SheetLightning.deck`) right above the glow, and its direction in the horizon frame (x east, y north,
    /// z up). The cloud there is lit from inside: its brightness × `cellGain`, which is 1 + 1.5 × level with cloud over
    /// you (cover 0.15 or more) and 1 (nothing to light) without.
    public var cell: SIMD2<Float>
    public var cellDirection: SIMD3<Float>
    public var cellGain: Float
    /// A big moment called it.
    public var called: Bool

    public init(azimuth: Float, width: Float, height: Float, born: Double, duration: Float, strength: Float,
                level: Float = 0, brightness: Float = 0, colour: SIMD3<Float> = SheetLightning.colour,
                cell: SIMD2<Float> = .zero, cellDirection: SIMD3<Float> = .zero, cellGain: Float = 1, called: Bool = false) {
        self.azimuth = azimuth; self.width = width; self.height = height; self.born = born; self.duration = duration
        self.strength = strength; self.level = level; self.brightness = brightness; self.colour = colour
        self.cell = cell; self.cellDirection = cellDirection; self.cellGain = cellGain; self.called = called
    }

    /// The rim glow's added light at a point of the sky (azimuth and altitude, degrees), a share of the sky's luminance:
    /// brightness × the raised cosine across `width` × e^(−2·altitude/height); nothing below the horizon.
    public func glow(azimuth az: Float, altitude: Float) -> Float {
        guard altitude >= 0, az.isFinite, altitude.isFinite else { return 0 }
        var d = (az - azimuth).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        let half = max(0.5, width / 2)
        guard abs(d) < half else { return 0 }
        let across = 0.5 + 0.5 * cos(Float.pi * d / half)
        return brightness * across * exp(-2 * altitude / max(0.1, height))
    }
}

/// The sheet lightning's machine (spec §6.2): flashes every 8–30 s (Often: a third of that) while a far or dry storm
/// stands on the horizon at dusk or night, clustered about that storm's bearing (one bearing an episode, each flash
/// within ±15° of it), and one at a big moment's call; on its own seeded streams, the gaps solved inside each step.
public struct SheetLightning {
    /// Flashes at once.
    public static let slots = 2
    /// The rim's brightening at most (never a flash: under the limiter's 0.25 rise).
    public static let brightest: Float = 0.2
    /// The gaps between flashes on Natural (seconds); Often divides them by 3.
    public static let gaps = 8.0...30.0
    public static let oftenFactor = 3.0
    /// Each flash: how long (seconds), how wide (degrees of azimuth), how high up the rim (degrees), how strong.
    public static let durations = 0.1...0.3
    public static let widths = 10.0...25.0
    public static let heights = 3.0...6.0
    public static let strengths = 0.5...1.0
    /// How far a flash strays from its storm's bearing, in all (degrees: ±15°).
    public static let spread = 30.0
    /// Its warm-white light.
    public static let colour = SIMD3<Float>(1.0, 0.88, 0.72)
    /// Only at dusk and by night: the sun below this (degrees).
    public static let darkBelow = -3.0
    /// The least cloud cover there must be for a cell to light, and how much a lit cell brightens at the flash's peak.
    public static let cellCloud: Float = 0.15
    public static let cellLift: Float = 1.5
    /// The cloud deck the cloud layer draws (SkyShaders: uv = d.xy / (d.z + 0.12) × 0.55, its noise read at uv × 2.2):
    /// a direction d lies on the deck at q = 1.21 × d.xy / (d.z + 0.12), and the noise's cells are q's unit squares.
    public static let deckScale = 1.21
    public static let deckLift = 0.12
    /// The lit cell is the deck's cell this far (degrees) above the glow's top, where the cloud is first drawn thick.
    public static let deckAbove = 2.0
    /// A called flash waits at least this long after the last one called (seconds).
    static let callSpacing = 1.0
    static let arrivalCap = 64

    /// The sheet's clock: seconds of sky time.
    public private(set) var time = 0.0
    /// Flashes made so far, and the latest births (the last 512, for tests).
    public private(set) var spawned = 0
    private(set) var births: [Double] = []
    /// The far storm's bearing this episode (degrees): drawn afresh each time a storm comes onto the horizon.
    public private(set) var bearing = 0.0

    private struct Pulse { var at: Double; var width: Double; var amplitude: Double }
    private struct Flash { var slot: SheetSlot; var pulses: [Pulse] }
    private var live: [Flash] = []
    private var shapeRng: SeededRandom
    private var gapRng: SeededRandom
    private var bearingRng: SeededRandom
    private var wait: Double
    private var phase = 0.0
    private var lastCall = -1e9
    private var wasEligible = false

    public init(seed: UInt64) {
        shapeRng = SeededRandom(seed: seed &* 0xA076_1D64_78BD_642F &+ 0x5EE7)
        var gaps = SeededRandom(seed: seed &* 0xE703_7ED1_A0B4_28DB &+ 0x11E7)
        wait = AnvilCrawlers.unit(&gaps)
        gapRng = gaps
        bearingRng = SeededRandom(seed: seed &* 0x8EBC_6AF0_9C88_C6E3 &+ 0xBEA2)
    }

    /// The gap a draw `u` stands for (seconds).
    static func gap(_ u: Double, mode: SkyExtraMode) -> Double {
        (gaps.lowerBound + u * (gaps.upperBound - gaps.lowerBound)) / (mode == .often ? oftenFactor : 1)
    }

    /// Advances `dt` seconds. `eligible`: dusk or night with a far or dry storm on the horizon (spec §6.2); `cloud`: the
    /// sky's cloud cover (a cell is lit only with some); `bearing`: the storm's own azimuth when the sky knows it (nil:
    /// the episode's); `call`: a big moment's strength this step (0…1). Off makes none. Returns the flashes lit at the
    /// end of the step (before the sky's flash limiter).
    public mutating func step(dt rawDt: Double, mode: SkyExtraMode, eligible: Bool, cloud: Float, bearing storm: Double? = nil,
                              call: Float? = nil) -> [SheetSlot] {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let start = time
        time += dt
        if eligible && !wasEligible { bearing = 360 * AnvilCrawlers.unit(&bearingRng) }   // a storm on the horizon
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
                spawn(at: t, bearing: toward, strength: nil)
                phase = 0
                wait = AnvilCrawlers.unit(&gapRng)
                count += 1
            }
            if let s = call, s.isFinite, time - lastCall >= Self.callSpacing {
                lastCall = time
                spawn(at: time, bearing: toward, strength: 0.5 + 0.5 * Double(min(1, max(0, s))))
            }
        }
        let now = time
        live.removeAll { now - $0.slot.born > Double($0.slot.duration) }
        let c = cloud.isFinite ? cloud : 0
        return live.map { Self.light($0, at: now, cloud: c) }
    }

    /// Thirteen draws a flash, whatever it uses, so the stream keeps its step.
    private mutating func spawn(at t: Double, bearing: Double, strength called: Double?) {
        var u: [Double] = []
        for _ in 0..<13 { u.append(AnvilCrawlers.unit(&shapeRng)) }
        var azimuth = (bearing + Self.spread * (u[0] - 0.5)).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }
        let width = Self.widths.lowerBound + u[1] * (Self.widths.upperBound - Self.widths.lowerBound)
        let height = Self.heights.lowerBound + u[2] * (Self.heights.upperBound - Self.heights.lowerBound)
        let duration = Self.durations.lowerBound + u[3] * (Self.durations.upperBound - Self.durations.lowerBound)
        let strength = called ?? (Self.strengths.lowerBound + u[4] * (Self.strengths.upperBound - Self.strengths.lowerBound))
        // One to three strokes: the first at once and the brightest, the others later and fainter, all inside it.
        let strokes = 1 + min(2, Int(u[5] * 3))
        var pulses = [Pulse(at: 0, width: min(duration, 0.05 + 0.05 * u[6]), amplitude: 1)]
        if strokes > 1 {
            let at = (0.3 + 0.3 * u[7]) * duration
            pulses.append(Pulse(at: at, width: min(duration - at, 0.04 + 0.05 * u[8]), amplitude: 0.5 + 0.4 * u[9]))
        }
        if strokes > 2 {
            let at = (0.6 + 0.25 * u[10]) * duration
            pulses.append(Pulse(at: at, width: min(duration - at, 0.04 + 0.04 * u[11]), amplitude: 0.3 + 0.4 * u[12]))
        }
        // The nearest cloud cell: the deck's cell just above the glow, at its azimuth.
        let above = Self.deck(AnvilCrawlers.enu(azimuth, height + Self.deckAbove))
        let cell = Self.cell(containing: above)
        let towards = Self.direction(deck: cell)
        let slot = SheetSlot(azimuth: Float(azimuth), width: Float(width), height: Float(height), born: t,
                             duration: Float(duration), strength: Float(strength),
                             cell: SIMD2(Float(cell.x), Float(cell.y)),
                             cellDirection: SIMD3(Float(towards.x), Float(towards.y), Float(towards.z)), called: called != nil)
        live.append(Flash(slot: slot, pulses: pulses))
        spawned += 1
        births.append(t)
        if births.count > 512 { births.removeFirst(births.count - 512) }
        while live.count > Self.slots { live.removeFirst() }
    }

    /// A flash lit at `t`: its strokes' sum (each a sin² bump), at most 1; its brightness; its cell's gain.
    private static func light(_ f: Flash, at t: Double, cloud: Float) -> SheetSlot {
        var s = f.slot
        let age = t - s.born
        var level = 0.0
        for p in f.pulses where p.width > 0 {
            let x = (age - p.at) / p.width
            if x >= 0 && x <= 1 {
                let b = sin(Double.pi * x)
                level += p.amplitude * b * b
            }
        }
        s.level = Float(min(1, max(0, level)))
        s.brightness = min(brightest, brightest * s.strength * s.level)
        s.cellGain = cloud >= cellCloud ? 1 + cellLift * s.level : 1
        return s
    }

    // MARK: - The cloud deck

    /// Where a direction (x east, y north, z up) lies on the cloud deck: q = 1.21 × d.xy / (d.z + 0.12).
    public static func deck(_ d: SIMD3<Double>) -> SIMD2<Double> {
        let k = deckScale / max(1e-6, d.z + deckLift)
        return SIMD2(d.x * k, d.y * k)
    }

    /// The centre of the deck's cell (a unit square) that holds `q`: of all the cells' centres, the nearest to it.
    public static func cell(containing q: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(q.x.rounded(.down) + 0.5, q.y.rounded(.down) + 0.5)
    }

    /// The direction a point of the deck is seen in (the inverse of `deck`, by bisection on the altitude: the deck's
    /// radius cos a / (sin a + 0.12) falls as the altitude a rises); a point past the horizon is seen on it.
    public static func direction(deck q: SIMD2<Double>) -> SIMD3<Double> {
        let rho = (q.x * q.x + q.y * q.y).squareRoot() / deckScale
        var altitude = 0.0
        if 1 - rho * deckLift > 0 {
            var lo = 0.0, hi = Double.pi / 2
            for _ in 0..<60 {
                let mid = 0.5 * (lo + hi)
                if cos(mid) - rho * (sin(mid) + deckLift) > 0 { lo = mid } else { hi = mid }
            }
            altitude = 0.5 * (lo + hi)
        }
        let az = atan2(q.x, q.y)
        return SIMD3(sin(az) * cos(altitude), cos(az) * cos(altitude), sin(altitude))
    }
}
