import Foundation

// Anvil crawlers (Storms spec §6.1): spider lightning, the dim, silent channels that creep across the underside of a
// storm's anvil for half a second to two seconds, branching sideways for tens of kilometres. Each one here is a seeded
// random walk across a level cloud base 7 km up, seen from the ground, so a channel overhead runs long across the sky
// and one far off is foreshortened toward the horizon, as a real one is. The bounds in StormSkyTests were measured on a
// Python mirror of this walk and its arrivals (the same streams, the same arithmetic in doubles).

/// One stretch of an anvil crawler's channel on the cloud base.
public struct CrawlerSegment: Equatable {
    /// Its two ends on the sky, (azimuth, altitude) in degrees: azimuth from north clockwise, unwrapped along the crawler
    /// (a channel across north runs on past 360° or below 0° rather than jumping), altitude within the cloud-base band.
    public var from: SIMD2<Float>
    public var to: SIMD2<Float>
    /// When the leader draws it, as shares of the crawl (0…1): it sets off from `from` at `start` and reaches `to` at
    /// `end` (the front runs at one pace along every branch, so a segment's times are its ends' distances along the
    /// channel from where the crawler began, over the longest).
    public var start: Float
    public var end: Float

    public init(from: SIMD2<Float>, to: SIMD2<Float>, start: Float, end: Float) {
        self.from = from; self.to = to; self.start = start; self.end = end
    }

    /// The cloud layer's SkyU row for it: x0, y0, x1, y1 (the azimuth and altitude of each end, degrees).
    public var row: SIMD4<Float> { SIMD4(from.x, from.y, to.x, to.y) }

    /// How much of it is lit at a crawl's progress `p`: 0 before the front reaches it … 1 once the front has passed.
    public func drawn(at p: Float) -> Float {
        guard end > start else { return p >= end ? 1 : 0 }
        return min(1, max(0, (p - start) / (end - start)))
    }

    /// Its length on the sky, degrees of arc.
    public var degrees: Float {
        Float(AnvilCrawlers.arc(Double(from.x), Double(from.y), Double(to.x), Double(to.y)))
    }
}

/// An anvil crawler in the sky now: its channel, and how far it has run and how bright it is at this step.
public struct CrawlerSlot: Equatable {
    /// The channel, 6–14 segments (at most `AnvilCrawlers.maxSegments`), in the order the leader laid them.
    public var segments: [CrawlerSegment]
    /// When it began (seconds on the crawlers' clock, the sky's own seconds) and how long the leader runs (0.5–2 s).
    public var born: Double
    public var duration: Float
    /// Its brightness at full glow, 0.15–0.4 of the sky's luminance (before the sky's flash limiter).
    public var peak: Float
    /// A big moment called it.
    public var called: Bool
    /// How far the leader has run, 0 → 1 over `duration`.
    public var progress: Float
    /// 1 while the leader runs, then fading to 0 over 0.3 s.
    public var glow: Float
    /// Its brightness now as a share of the sky's luminance: the peak × a 40 ms attack × the glow, after the sky's
    /// `FlashLimiter` (≤ 0.4; above 0.25 it costs a flash).
    public var brightness: Float
    /// Its light: a cool blue-white, never white.
    public var colour: SIMD3<Float>

    public init(segments: [CrawlerSegment], born: Double, duration: Float, peak: Float, called: Bool = false,
                progress: Float = 0, glow: Float = 1, brightness: Float = 0, colour: SIMD3<Float> = AnvilCrawlers.colour) {
        self.segments = segments; self.born = born; self.duration = duration; self.peak = peak; self.called = called
        self.progress = progress; self.glow = glow; self.brightness = brightness; self.colour = colour
    }
}

/// The anvil crawlers' machine (spec §6.1): arrivals at the rate the storm's stage and the Sky extras mode set, a big
/// moment's call, and each crawler's walk, on their own seeded streams (so the rest of the sky never shifts). The gaps
/// are solved inside each step, so the arrivals are the same at 1/60 s or a second a step.
public struct AnvilCrawlers {
    /// Slots in the sky at once, and segments in one crawler at most (the cloud layer's rows).
    public static let slots = 4
    public static let maxSegments = 16
    /// Segments in one crawler, and each one's length on the sky (degrees).
    public static let segmentCount = 6...14
    public static let segmentDegrees = 2.0...6.0
    /// The cloud base band: altitudes (degrees) a channel stays within.
    public static let band = 12.0...60.0
    /// How long the leader runs (seconds), the attack, and the glow's fade after it.
    public static let durations = 0.5...2.0
    public static let attackSeconds = 0.04
    public static let fadeSeconds = 0.3
    /// Brightness at full glow, as a share of the sky's luminance; above `costs` a crawler costs a flash.
    public static let dimmest: Float = 0.15, brightest: Float = 0.4
    public static let costs: Float = FlashLimiter.flashRise
    /// The cool blue-white of the channel.
    public static let colour = SIMD3<Float>(0.75, 0.82, 1.0)
    /// The gaps between crawlers on Natural (seconds): in a supercell's Core stage, and otherwise. Often divides them by 3.
    public static let coreGaps = 15.0...45.0
    public static let gaps = 60.0...120.0
    public static let oftenFactor = 3.0
    /// The anvil's base above the ground (km), where the walk runs.
    public static let baseKm = 7.0
    /// Where a crawler begins: this far up the sky (degrees), and within ±60° of a storm's bearing when it has one.
    static let rootAltitudes = 16.0...46.0
    static let bearingSpread = 120.0
    /// A called crawler waits at least this long after the last one called (seconds).
    static let callSpacing = 1.0
    /// The most arrivals one step may make (only a huge step comes near it).
    static let arrivalCap = 64

    /// Test seam: every crawler's peak (nil: drawn, or set by its call).
    var forcePeak: Float?

    /// The crawlers' clock: seconds of sky time (the steps' sum).
    public private(set) var time = 0.0
    /// Crawlers made so far (each one, whether or not it kept a slot), and the latest births (the last 512, for tests).
    public private(set) var spawned = 0
    private(set) var births: [Double] = []
    /// The crawlers in the sky after the last step (at most `slots`).
    private(set) var live: [CrawlerSlot] = []

    private var shapeRng: SeededRandom
    private var gapRng: SeededRandom
    /// The current gap's draw (0…<1: where it falls in its range) and how much of it has passed (0…1).
    private var wait: Double
    private var phase = 0.0
    private var lastCall = -1e9

    public init(seed: UInt64) {
        shapeRng = SeededRandom(seed: seed &* 0xD1B5_4A32_D192_ED03 &+ 0xC4A7)
        var gaps = SeededRandom(seed: seed &* 0x8CB9_2BA7_2F3D_8DD7 &+ 0x6A95)
        wait = Self.unit(&gaps)
        gapRng = gaps
    }

    /// The gap a draw `u` stands for (seconds): its range by the storm's stage, divided by 3 on Often.
    static func gap(_ u: Double, core: Bool, mode: SkyExtraMode) -> Double {
        let r = core ? coreGaps : gaps
        return (r.lowerBound + u * (r.upperBound - r.lowerBound)) / (mode == .often ? oftenFactor : 1)
    }

    /// Advances `dt` seconds. `eligible`: the sky has a storm's anvil over it (spec §6.1); `core`: a supercell's Core
    /// stage; `bearing`: the storm's azimuth (degrees) when it has one; `call`: a big moment's strength this step (0…1),
    /// which calls a crawler now (at most one a second). Off makes none, called or not. Returns the crawlers in the sky
    /// at the end of the step, lit for that instant (before the sky's flash limiter).
    public mutating func step(dt rawDt: Double, mode: SkyExtraMode, eligible: Bool, core: Bool, bearing: Double? = nil,
                              call: Float? = nil) -> [CrawlerSlot] {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let start = time
        time += dt
        if mode != .off && eligible {
            var t = start, left = dt, count = 0
            while count < Self.arrivalCap {
                let span = Self.gap(wait, core: core, mode: mode)
                let need = (1 - phase) * span
                if need > left { phase += left / span; break }
                t += need
                left -= need
                spawn(at: t, peak: nil, bearing: bearing, called: false)
                phase = 0
                wait = Self.unit(&gapRng)
                count += 1
            }
            if let strength = call, strength.isFinite, time - lastCall >= Self.callSpacing {
                lastCall = time
                let s = Double(min(1, max(0, strength)))
                let peak = Double(Self.dimmest) + s * Double(Self.brightest - Self.dimmest)
                spawn(at: time, peak: Float(peak), bearing: bearing, called: true)
            }
        }
        let now = time
        live.removeAll { now - $0.born > Double($0.duration) + Self.fadeSeconds }
        return live.map { Self.light($0, at: now) }
    }

    /// A crawler lit at `t`: its progress, its glow and its brightness (a 40 ms smoothstep attack, full while the
    /// leader runs, then a linear fade over 0.3 s).
    static func light(_ c: CrawlerSlot, at t: Double) -> CrawlerSlot {
        var c = c
        let age = max(0, t - c.born)
        let run = Double(c.duration)
        c.progress = Float(min(1, age / max(1e-6, run)))
        let glow = age <= run ? 1 : max(0, 1 - (age - run) / fadeSeconds)
        c.glow = Float(glow)
        let x = min(1, age / attackSeconds)
        c.brightness = c.peak * Float(x * x * (3 - 2 * x) * glow)
        return c
    }

    private mutating func spawn(at t: Double, peak forced: Float?, bearing: Double?, called: Bool) {
        let shape = Self.walk(&shapeRng, bearing: bearing)
        let uPeak = Self.unit(&shapeRng), uDuration = Self.unit(&shapeRng)
        var peak = Float(Double(Self.dimmest) + uPeak * Double(Self.brightest - Self.dimmest))
        if let f = forced { peak = f }
        if let f = forcePeak { peak = f }
        peak = min(Self.brightest, max(0, peak.isFinite ? peak : 0))
        // Longer channels take longer to lay: the duration leans 40% on the crawler's size.
        let size = Double(shape.count - Self.segmentCount.lowerBound)
            / Double(Self.segmentCount.upperBound - Self.segmentCount.lowerBound)
        let duration = Self.durations.lowerBound
            + (0.6 * uDuration + 0.4 * size) * (Self.durations.upperBound - Self.durations.lowerBound)
        live.append(CrawlerSlot(segments: shape, born: t, duration: Float(duration), peak: peak, called: called))
        spawned += 1
        births.append(t)
        if births.count > 512 { births.removeFirst(births.count - 512) }
        while live.count > Self.slots { live.removeFirst() }   // the oldest makes way
    }

    // MARK: - The walk

    private struct Node {
        var p: SIMD2<Double>      // on the cloud base: km east, km north of the viewer
        var azimuth: Double       // degrees, unwrapped from its parent's
        var altitude: Double      // degrees
        var path: Double          // degrees of channel from the root
        var heading: Double       // the heading it was reached on (radians from east, counter-clockwise)
    }

    /// A crawler's channel: a persistent random walk across the anvil's base (a level plane `baseKm` up) from a root
    /// 16–46° up the sky, each step 2–6° long on the sky, turning a little each step (the sum of three uniform draws:
    /// about ±17°), and forking now and then (about one step in four after the second, up to four leaders), every node
    /// kept within the cloud-base band. Nine draws a step and four for the crawler, whatever happens, so the stream
    /// keeps its step.
    static func walk(_ rng: inout SeededRandom, bearing: Double?) -> [CrawlerSegment] {
        let uCount = unit(&rng), uAzimuth = unit(&rng), uAltitude = unit(&rng), uHeading = unit(&rng)
        let n = segmentCount.lowerBound + min(segmentCount.count - 1, Int(uCount * Double(segmentCount.count)))
        let azimuth: Double
        if let b = bearing, b.isFinite { azimuth = b + bearingSpread * (uAzimuth - 0.5) } else { azimuth = 360 * uAzimuth }
        let altitude = rootAltitudes.lowerBound + uAltitude * (rootAltitudes.upperBound - rootAltitudes.lowerBound)
        let r = baseKm / tan(altitude * .pi / 180)
        let a = azimuth * .pi / 180
        var nodes = [Node(p: SIMD2(r * sin(a), r * cos(a)), azimuth: azimuth, altitude: altitude, path: 0,
                          heading: 2 * .pi * uHeading)]
        var tips: [(node: Int, heading: Double)] = [(0, 2 * .pi * uHeading)]
        var links: [(from: Int, to: Int)] = []
        for k in 0..<n {
            let uFork = unit(&rng), uForkNode = unit(&rng), uForkSide = unit(&rng), uForkAngle = unit(&rng)
            let uTip = unit(&rng), uTurn1 = unit(&rng), uTurn2 = unit(&rng), uTurn3 = unit(&rng), uLength = unit(&rng)
            var which = 0
            if k >= 2, uFork < 0.28, tips.count < 4 {
                // A fork: a new leader off a node of the channel so far, 30–70° off the heading it was reached on.
                let parent = min(nodes.count - 1, Int(uForkNode * Double(nodes.count)))
                let side = uForkSide < 0.5 ? -1.0 : 1.0
                tips.append((parent, nodes[parent].heading + side * (0.5 + 0.7 * uForkAngle)))
                which = tips.count - 1
            } else if tips.count > 1, uTip >= 0.65 {
                // Now and then a branch's leader goes on instead of the main one.
                which = 1 + min(tips.count - 2, Int((uTip - 0.65) / 0.35 * Double(tips.count - 1)))
            }
            let turn = (uTurn1 + uTurn2 + uTurn3 - 1.5) * 0.6
            let length = segmentDegrees.lowerBound + uLength * (segmentDegrees.upperBound - segmentDegrees.lowerBound)
            let from = nodes[tips[which].node]
            let next = advance(from, heading: tips[which].heading + turn, degrees: length)
            nodes.append(next)
            links.append((tips[which].node, nodes.count - 1))
            tips[which] = (nodes.count - 1, next.heading)
        }
        let longest = max(1e-9, nodes.map(\.path).max() ?? 1)
        return links.map { l -> CrawlerSegment in
            let f = nodes[l.from], t = nodes[l.to]
            return CrawlerSegment(from: SIMD2(Float(f.azimuth), Float(f.altitude)), to: SIMD2(Float(t.azimuth), Float(t.altitude)),
                                  start: Float(f.path / longest), end: Float(t.path / longest))
        }
    }

    /// One step of the walk from `from` on `heading`, `degrees` long on the sky, kept in the band: if the step would
    /// leave it (or can't reach that far: heading away near the horizon), the heading turns 30° at a time toward the
    /// way back into the band, and at worst goes straight there (toward the viewer from low down, away from overhead),
    /// which always fits.
    private static func advance(_ from: Node, heading: Double, degrees: Double) -> Node {
        let inward = atan2(-from.p.y, -from.p.x), outward = atan2(from.p.y, from.p.x)
        var target: Double?
        for attempt in 0...5 {
            var h = heading
            if attempt == 5 {
                h = target ?? (from.altitude < (band.lowerBound + band.upperBound) / 2 ? inward : outward)
            } else if attempt > 0, let goal = target {
                h = turn(heading, toward: goal, by: Double(attempt) * .pi / 6)
            }
            let dir = SIMD2(cos(h), sin(h))
            if let s = reach(from.p, dir, degrees) {
                let p = from.p + dir * s
                let altitude = atan2(baseKm, length(p)) * 180 / .pi
                if band.contains(altitude) {
                    var az = atan2(p.x, p.y) * 180 / .pi
                    az += 360 * ((from.azimuth - az) / 360).rounded()
                    let walked = arc(from.azimuth, from.altitude, az, altitude)
                    return Node(p: p, azimuth: az, altitude: altitude, path: from.path + walked, heading: h)
                }
                if target == nil { target = altitude < band.lowerBound ? inward : outward }
            } else if target == nil {
                target = inward   // heading away near the horizon: come back in
            }
        }
        // Unreachable in practice (the straight way back always fits); stay put rather than leave the band.
        return Node(p: from.p, azimuth: from.azimuth, altitude: from.altitude, path: from.path, heading: heading)
    }

    /// How far along `dir` (km) from `p` the walk must go to move `degrees` across the sky, or nil if it can't (the
    /// angle only grows along the line, toward the heading's own horizon direction): bisection, 60 halvings.
    private static func reach(_ p: SIMD2<Double>, _ dir: SIMD2<Double>, _ degrees: Double) -> Double? {
        let start = SIMD3(p.x, p.y, baseKm)
        func angle(_ s: Double) -> Double {
            let q = SIMD3(p.x + dir.x * s, p.y + dir.y * s, baseKm)
            return atan2(length3(cross3(start, q)), dot3(start, q)) * 180 / .pi
        }
        var lo = 0.0, hi = 2000.0
        guard angle(hi) >= degrees else { return nil }
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            if angle(mid) < degrees { lo = mid } else { hi = mid }
        }
        return 0.5 * (lo + hi)
    }

    /// `heading` turned toward `goal` by `step` radians (or onto it, if it is nearer than that).
    private static func turn(_ heading: Double, toward goal: Double, by step: Double) -> Double {
        var d = (goal - heading).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return abs(d) <= step ? goal : heading + (d > 0 ? step : -step)
    }

    // MARK: - Helpers

    /// The arc between two points of the sky given by azimuth and altitude (degrees), degrees: atan2 of the cross and dot
    /// products, well conditioned at small angles too.
    static func arc(_ az0: Double, _ alt0: Double, _ az1: Double, _ alt1: Double) -> Double {
        let a = enu(az0, alt0), b = enu(az1, alt1)
        return atan2(length3(cross3(a, b)), dot3(a, b)) * 180 / .pi
    }

    /// The horizon frame's unit vector (x east, y north, z up) for an azimuth and altitude in degrees.
    static func enu(_ azimuth: Double, _ altitude: Double) -> SIMD3<Double> {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        return SIMD3(sin(az) * cos(alt), cos(az) * cos(alt), sin(alt))
    }

    /// A uniform double in 0…<1 (53 bits).
    static func unit(_ r: inout SeededRandom) -> Double { Double(r.next() >> 11) * 0x1p-53 }

    private static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
    private static func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func length3(_ v: SIMD3<Double>) -> Double { dot3(v, v).squareRoot() }
    private static func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
