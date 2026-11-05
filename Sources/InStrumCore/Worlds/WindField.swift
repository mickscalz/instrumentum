import Foundation
import simd

/// The shared wind field (Storms spec §10): the wind over a world's ground plane, which grass, cloth and particles
/// read. It is the sum of four things, all in metres per second over a plane in metres (x across the view, y away
/// from the viewer), centred where the wind matters (usually the ground under the camera):
///
/// - **The steady flow:** the weather's wind, the same everywhere. The world sets it as the weather changes (the
///   weather layer already eases its values, so it is applied at once).
/// - **Its breathing:** the steady flow is never dead steady. A seeded two-octave value noise over position and time
///   adds lulls and surges of at most `breathingDepth` (15%) of the steady speed, mostly along the wind and less
///   across it, as real wind is. The pattern is carried downwind at the steady speed (frozen turbulence) while it
///   slowly changes, so the bright and dark patches in a field of grass roll downwind as they do in a wheat field.
/// - **Gusts:** up to four travelling waves, each a raised cosine `width` metres front to back (zero outside it,
///   `strength` at its crest) moving at `speed` from where it set out and blowing the way it travels. With a `span`
///   it is a patch (a cat's paw on the grass, raised-cosine side to side as well); without one it is a front (the
///   gust front at 15 m/s). It fades in as it sets out, so it never pops, and ends once it has passed twice the
///   field's extent downwind with all of it outside the field. A fifth gust replaces the oldest.
/// - **Vortices:** up to two swirls (a dust devil), each a Lamb–Oseen vortex fastest at `radius` (`strength` there,
///   anticlockwise seen from above when positive), calm in its eye, fading to nothing by eight radii, optionally
///   spiralling in, drifting with `drift`. They spin up as they form, spin down at the end of a finite `lifetime`,
///   and end once they have drifted out of the field. A third replaces the oldest.
///
/// Everything is held inline (no arrays, no references), so nothing is ever allocated, retained or released after
/// `init`; `sample` is a handful of multiplies and a cosine or an exponential per live gust or vortex, cheap enough to
/// call per grass row or per particle every frame (never per pixel).
public struct WindField: Equatable {
    /// A gust: a raised-cosine wave of wind travelling over the ground.
    public struct Gust: Equatable {
        /// Where it set out (metres).
        public internal(set) var origin: SIMD2<Float>
        /// The way it travels, and blows (a unit vector).
        public internal(set) var direction: SIMD2<Float>
        /// How fast its crest travels (m/s).
        public internal(set) var speed: Float
        /// The whole wave, front to back (metres): zero further than half of this from the crest.
        public internal(set) var width: Float
        /// The wind at its crest once it has set out (m/s along `direction`; negative is a lull, pushing back).
        public internal(set) var strength: Float
        /// Its reach side to side (metres, raised-cosine), or infinite for a front.
        public internal(set) var span: Float
        /// Seconds since it set out.
        public internal(set) var age: Float
        var serial: UInt32

        /// How far its crest has travelled from `origin` (metres).
        public var travelled: Float { speed * age }
        /// Its crest's point on the line it travels (from `origin` along `direction`).
        public var crest: SIMD2<Float> { origin + direction * travelled }
        /// How far it has faded in (0…1): over the time its leading half takes to leave the origin (0.1–1.5 s).
        public var level: Float { WindField.smooth(age / min(max(0.5 * width / speed, 0.1), 1.5)) }

        /// This gust's share of the wind at `p` (m/s).
        public func velocity(at p: SIMD2<Float>) -> SIMD2<Float> {
            let d = p - origin
            let half = 0.5 * width
            let ahead = simd_dot(d, direction) - travelled   // > 0 ahead of the crest, < 0 behind it
            guard abs(ahead) < half else { return .zero }
            var k = 0.5 + 0.5 * cos(Float.pi * ahead / half)
            if span.isFinite {
                let side = simd_dot(d, SIMD2(-direction.y, direction.x))
                let reach = 0.5 * span
                guard abs(side) < reach else { return .zero }
                k *= 0.5 + 0.5 * cos(Float.pi * side / reach)
            }
            return direction * (strength * level * k)
        }
    }

    /// A vortex: a swirl of wind over the ground (a dust devil).
    public struct Vortex: Equatable {
        /// Its eye (metres); it moves with `drift`.
        public internal(set) var centre: SIMD2<Float>
        /// Where it swirls fastest (metres).
        public internal(set) var radius: Float
        /// The swirl's speed at `radius` (m/s): positive anticlockwise seen from above (x across, y away), negative
        /// clockwise.
        public internal(set) var strength: Float
        /// How its eye moves (m/s): a dust devil drifts with the wind.
        public internal(set) var drift: SIMD2<Float>
        /// How much it spirals in, as a share of the swirl (0 a pure swirl, 0.3 a dust devil's inward spiral).
        public internal(set) var inflow: Float
        /// How long it lasts (seconds; infinite until it drifts out of the field or is replaced).
        public internal(set) var lifetime: Float
        /// Seconds since it formed.
        public internal(set) var age: Float
        var serial: UInt32

        /// Beyond this from its eye it adds nothing (metres): eight radii.
        public var reach: Float { 8 * radius }
        /// How strongly it is turning (0…1): it spins up over 1.5 s and, with a finite lifetime, down over its last 2.
        public var level: Float {
            guard lifetime.isFinite else { return WindField.smooth(age / 1.5) }
            let spinUp = min(1.5, lifetime / 3), spinDown = min(2, lifetime / 3)
            return WindField.smooth(age / spinUp) * WindField.smooth((lifetime - age) / spinDown)
        }

        /// This vortex's share of the wind at `p` (m/s).
        public func velocity(at p: SIMD2<Float>) -> SIMD2<Float> {
            let d = p - centre
            let r2 = simd_dot(d, d)
            let far = reach
            guard r2 > 1e-12, r2 < far * far else { return .zero }
            let r = r2.squareRoot()
            // Lamb–Oseen, scaled so the swirl peaks at exactly `strength` at `radius`.
            let x2 = r2 / (radius * radius)
            let shape: Float = -expm1(-WindField.lambOseenAlpha * x2) * (radius / r)
            let swirl = strength * level * WindField.lambOseenPeak * shape
            // Fades out between four and eight radii, so it is local and its edge is soft.
            let s = swirl * (1 - WindField.smooth((r - 4 * radius) / (4 * radius)))
            let unit = d / r
            return SIMD2(-unit.y, unit.x) * s - unit * (inflow * abs(s))
        }
    }

    /// Gusts and vortices live at once.
    public static let maxGusts = 4
    public static let maxVortices = 2
    /// The steady flow's breathing at most, as a share of its speed.
    public static let breathingDepth: Float = 0.15

    /// The radius of the region the world reads (metres), centred on the origin.
    public let extent: Float
    /// The steady flow (m/s).
    public private(set) var steady: SIMD2<Float> = .zero
    /// How much the steady flow breathes (0 dead steady … 1 natural).
    public var breathing: Float = 1

    private var g0: Gust?, g1: Gust?, g2: Gust?, g3: Gust?
    private var v0: Vortex?, v1: Vortex?
    private var nextSerial: UInt32 = 0
    /// How far the breathing's pattern has been carried downwind (metres, wrapped at its period).
    private var carried: SIMD2<Float> = .zero
    /// How far the pattern has evolved (in its coarse cells, wrapped at its period).
    private var phase: Float = 0
    private let coarseSalt: UInt32, fineSalt: UInt32

    /// `extent` is the radius of the region the world reads (metres); `seed` picks the breathing's pattern.
    public init(extent: Float = 250, seed: UInt64 = 0x5749_4E44_F1E1_D000) {
        self.extent = extent.isNaN ? 250 : min(max(extent, 1), 100_000)
        coarseSalt = Self.mix(UInt32(truncatingIfNeeded: seed) ^ 0x68E3_1DA4)
        fineSalt = Self.mix(UInt32(truncatingIfNeeded: seed >> 32) ^ 0xB529_7A4D)
    }

    // MARK: - Setting it

    /// Sets the steady flow (m/s): the weather's wind, the same everywhere.
    public mutating func set(steady: SIMD2<Float>) {
        self.steady = SIMD2(Self.clamp(steady.x, -100, 100, 0), Self.clamp(steady.y, -100, 100, 0))
    }

    /// Sends a gust from `origin`, travelling `direction` (by default towards the field's centre) at `speed` m/s,
    /// `width` metres front to back, `strength` m/s at its crest, and `span` metres side to side (infinite: a front).
    public mutating func addGust(from origin: SIMD2<Float>, direction: SIMD2<Float>? = nil, speed: Float,
                                 width: Float, strength: Float, span: Float = .infinity) {
        let o = Self.clampPoint(origin)
        var heading = direction.map(Self.clampPoint) ?? -o
        if simd_length(heading) < 1e-6 { heading = simd_length(steady) > 1e-6 ? steady : SIMD2(1, 0) }
        let gust = Gust(origin: o, direction: simd_normalize(heading), speed: Self.clamp(speed, 0.5, 200, 10),
                        width: Self.clamp(width, 1, 10_000, 30), strength: Self.clamp(strength, -100, 100, 0),
                        span: span.isNaN ? .infinity : max(span, 1), age: 0, serial: nextSerial)
        nextSerial &+= 1
        let slot = slotToFill(Self.maxGusts) { self.gust(at: $0)?.serial }
        setGust(gust, at: slot)
    }

    /// Forms a vortex at `centre`, fastest at `radius` metres with `strength` m/s there (positive anticlockwise),
    /// drifting with `drift` m/s, spiralling in by `inflow` (0…1), for `lifetime` seconds (infinite by default).
    public mutating func addVortex(at centre: SIMD2<Float>, radius: Float, strength: Float, drift: SIMD2<Float>,
                                   inflow: Float = 0, lifetime: Float = .infinity) {
        let vortex = Vortex(centre: Self.clampPoint(centre), radius: Self.clamp(radius, 0.1, 1000, 5),
                            strength: Self.clamp(strength, -100, 100, 0),
                            drift: SIMD2(Self.clamp(drift.x, -100, 100, 0), Self.clamp(drift.y, -100, 100, 0)),
                            inflow: Self.clamp(inflow, 0, 1, 0),
                            lifetime: lifetime.isNaN || lifetime > 100_000 ? .infinity : max(lifetime, 0.1),
                            age: 0, serial: nextSerial)
        nextSerial &+= 1
        let slot = slotToFill(Self.maxVortices) { self.vortex(at: $0)?.serial }
        setVortex(vortex, at: slot)
    }

    // MARK: - Time

    public mutating func step(dt: Double) {
        let s: Float = dt.isFinite ? Float(min(max(dt, 0), 1)) : 0
        guard s > 0 else { return }
        phase = Self.wrap(phase + s * Self.eddyRate, Self.phasePeriod)
        let moved = carried + steady * s
        carried = SIMD2(Self.wrap(moved.x, Self.carryPeriod), Self.wrap(moved.y, Self.carryPeriod))
        for slot in 0..<Self.maxGusts {
            guard var g = gust(at: slot) else { continue }
            g.age += s
            // Gone once its crest is past twice the extent downwind and none of it is left in the field.
            let crestAlong = simd_dot(g.origin, g.direction) + g.travelled
            let gone = (crestAlong > 2 * extent && crestAlong - 0.5 * g.width > extent) || g.age > 3600
            setGust(gone ? nil : g, at: slot)
        }
        for slot in 0..<Self.maxVortices {
            guard var v = vortex(at: slot) else { continue }
            v.age += s
            v.centre = Self.clampPoint(v.centre + v.drift * s)
            let out = simd_length(v.centre)
            let gone = v.age >= v.lifetime || (out > 2 * extent && out - v.reach > extent)
            setVortex(gone ? nil : v, at: slot)
        }
    }

    // MARK: - Reading it

    /// The wind at `p` (m/s): the steady flow, its breathing, and every live gust and vortex, summed.
    public func sample(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = Self.clampPoint(p)
        var v = steady + breath(at: q)
        for slot in 0..<Self.maxGusts { if let g = gust(at: slot) { v += g.velocity(at: q) } }
        for slot in 0..<Self.maxVortices { if let w = vortex(at: slot) { v += w.velocity(at: q) } }
        return v
    }

    /// The breathing alone at `p` (m/s): never more than `breathingDepth` × `breathing` × the steady speed.
    public func turbulence(at p: SIMD2<Float>) -> SIMD2<Float> { breath(at: Self.clampPoint(p)) }

    /// The gust in `slot` (0..<`maxGusts`), if one is live there.
    public func gust(at slot: Int) -> Gust? {
        switch slot {
        case 0: return g0
        case 1: return g1
        case 2: return g2
        case 3: return g3
        default: return nil
        }
    }

    /// The vortex in `slot` (0..<`maxVortices`), if one is live there.
    public func vortex(at slot: Int) -> Vortex? {
        switch slot {
        case 0: return v0
        case 1: return v1
        default: return nil
        }
    }

    public var gustCount: Int {
        var n = 0
        for slot in 0..<Self.maxGusts where gust(at: slot) != nil { n += 1 }
        return n
    }

    public var vortexCount: Int {
        var n = 0
        for slot in 0..<Self.maxVortices where vortex(at: slot) != nil { n += 1 }
        return n
    }

    // MARK: - The breathing

    /// The coarse octave's cell (metres); the fine octave's is half of it.
    static let cell: Float = 16
    /// How fast the pattern changes as it is carried (coarse cells per second: a coarse eddy lasts about 8 s).
    static let eddyRate: Float = 0.12
    /// The noise repeats every 256 cells, so the carry and the phase wrap there exactly (powers of two).
    static let carryPeriod: Float = 256 * cell
    static let phasePeriod: Float = 256
    /// Moves the fine lattice off the coarse one, so their corners never line up.
    static let fineShift = SIMD2<Float>(0.37, 0.71)

    private func breath(at q: SIMD2<Float>) -> SIMD2<Float> {
        let amount = Self.clamp(breathing, 0, 1, 0) * Self.breathingDepth
        let speed = simd_length(steady)
        guard amount > 0, speed > 1e-6 else { return .zero }
        let local = q - carried
        let coarse = Self.valueNoise(local / Self.cell, phase, coarseSalt)
        let fine = Self.valueNoise(local / (0.5 * Self.cell) + Self.fineShift, 2 * phase + 0.5, fineSalt)
        var n = (coarse + 0.5 * fine) / 1.5
        n *= 1.5 - 0.5 * n * n                         // a little more contrast, still within ±1
        // Along the wind, and three quarters as much across it (the surface layer's σv : σu), within the unit disc.
        var e = SIMD2(n.x, 0.75 * n.y)
        let m = simd_length(e)
        if m > 1 { e /= m }
        let along = steady / speed
        return (along * e.x + SIMD2(-along.y, along.x) * e.y) * (amount * speed)
    }

    /// Two channels of smooth value noise in (x, y, t), each within ±1, repeating every 256 cells on each axis.
    static func valueNoise(_ xy: SIMD2<Float>, _ t: Float, _ salt: UInt32) -> SIMD2<Float> {
        let fx = xy.x.rounded(.down), fy = xy.y.rounded(.down), ft = t.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy), it = Int32(ft)
        let ux = fade(xy.x - fx), uy = fade(xy.y - fy), ut = fade(t - ft)
        func plane(_ k: Int32) -> SIMD2<Float> {
            let a = lerp(lattice(ix, iy, k, salt), lattice(ix &+ 1, iy, k, salt), ux)
            let b = lerp(lattice(ix, iy &+ 1, k, salt), lattice(ix &+ 1, iy &+ 1, k, salt), ux)
            return lerp(a, b, uy)
        }
        return lerp(plane(it), plane(it &+ 1), ut)
    }

    /// Two values in −1…1 at a lattice corner: one 32-bit hash, split in halves. Distinct corners (mod 256 per
    /// axis) are distinct inputs to a bijective mix, so no two corners of a period share a hash.
    @inline(__always)
    static func lattice(_ x: Int32, _ y: Int32, _ t: Int32, _ salt: UInt32) -> SIMD2<Float> {
        let corner = UInt32(bitPattern: x & 255) | UInt32(bitPattern: y & 255) << 8 | UInt32(bitPattern: t & 255) << 16
        let h = mix(corner ^ salt)
        return SIMD2(Float(h & 0xFFFF), Float(h >> 16)) * (2 / 65535 as Float) - 1
    }

    /// A 32-bit integer hash (Wellons' lowbias32): a bijection with good avalanche.
    @inline(__always)
    static func mix(_ v: UInt32) -> UInt32 {
        var x = v
        x ^= x >> 16
        x &*= 0x7FEB_352D
        x ^= x >> 15
        x &*= 0x846C_A68B
        x ^= x >> 16
        return x
    }

    // MARK: - Helpers

    /// Lamb–Oseen: v(x) ∝ (1 − e^(−αx²)) / x peaks at x = 1 when e^α = 1 + 2α; the peak is 2α / (1 + 2α).
    static let lambOseenAlpha: Float = 1.256_431
    static let lambOseenPeak: Float = 1 + 1 / (2 * lambOseenAlpha)

    /// Smoothstep of `t` over 0…1, clamped (0 for NaN).
    @inline(__always)
    static func smooth(_ t: Float) -> Float {
        let k = t.isNaN ? 0 : min(max(t, 0), 1)
        return k * k * (3 - 2 * k)
    }

    /// The quintic fade, so the breathing is smooth in its rate of change too.
    @inline(__always)
    static func fade(_ t: Float) -> Float { t * t * t * (t * (6 * t - 15) + 10) }

    @inline(__always)
    static func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> { a + (b - a) * t }

    /// `v` into `period` (a power of two, so this is exact): 0…period.
    static func wrap(_ v: Float, _ period: Float) -> Float { v - period * (v / period).rounded(.down) }

    static func clamp(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float {
        v.isNaN ? fallback : min(max(v, lo), hi)
    }

    /// Any point, held to ±1000 km (NaN to 0), so every sum stays finite.
    static func clampPoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(clamp(p.x, -1_000_000, 1_000_000, 0), clamp(p.y, -1_000_000, 1_000_000, 0))
    }

    /// The slot a new gust or vortex takes: the first free one, else the oldest (wrap-safe on the serial).
    private func slotToFill(_ count: Int, _ serial: (Int) -> UInt32?) -> Int {
        var oldest = 0, oldestAge: UInt32 = 0
        for slot in 0..<count {
            guard let s = serial(slot) else { return slot }
            let age = nextSerial &- s
            if age > oldestAge { oldestAge = age; oldest = slot }
        }
        return oldest
    }

    private mutating func setGust(_ g: Gust?, at slot: Int) {
        switch slot {
        case 0: g0 = g
        case 1: g1 = g
        case 2: g2 = g
        case 3: g3 = g
        default: break
        }
    }

    private mutating func setVortex(_ v: Vortex?, at slot: Int) {
        switch slot {
        case 0: v0 = v
        case 1: v1 = v
        default: break
        }
    }
}
