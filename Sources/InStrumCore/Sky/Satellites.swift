import Foundation
import simd

// Satellite passes and flares (Fire & Neon spec §6.2). After dusk and before dawn, satellites still in sunlight cross the
// dark sky as steady points, a few minutes from horizon to horizon, and some fade out partway as they run into the Earth's
// shadow, reddening for a moment as the last sunlight reaching them comes through the atmosphere's limb. Now and then a
// flat panel catches the sun and one flares for a few seconds; a bright station crosses slowly once or twice an evening;
// and very rarely a freshly launched train crosses as a short line of evenly spaced points.
//
// The passes are seeded and plausible, not live orbits (spec §17.21): each one is a circular orbit at its own height,
// its plane set by an inclination family and how close it passes, seen from the observer on a round Earth, so it rises
// slowly, crosses fastest high up, and sets; its brightness comes from its size, its range, its phase (the sun's angle at
// it) and the air it is seen through; and the Earth's shadow is a cylinder away from the sun, so passes fade into it on
// the side of the sky away from the sun, and the later the night the fewer stay lit.

/// A satellite (or a train of them) in the sky now.
public struct SatelliteSlot: Equatable {
    public enum Kind: String, Equatable { case satellite, station, train }
    public var kind: Kind
    /// The pass it belongs to (a new number for each pass).
    public var id: Int
    /// Where it is (the lead's direction, east-north-up unit vector) and which way it moves across the sky (a unit vector
    /// at right angles to it), and how fast (radians a second).
    public var direction: SIMD3<Float>
    public var tangent: SIMD3<Float>
    public var angularSpeed: Float
    /// A train's members (1 for one satellite) and the gap between them along the track (radians: how far a member
    /// moves across the sky in the time it trails the one ahead).
    public var count: Int
    public var spacing: Float
    /// Its brightness: its magnitude now (with any flare; in shadow it is the magnitude it would have) and its light on
    /// the stars' scale (1 = Sirius), lit share and dark sky included (0 is unseen).
    public var magnitude: Float
    public var light: Float
    /// How sunlit it is (0 in the Earth's shadow … 1 in full sun: a second or two of penumbra) and how red the sunlight
    /// reaching it is (0…1, near the shadow's edge).
    public var sunlit: Float
    public var redden: Float
    /// A train's shadow edge: the members past `shadowMember` (a fractional index from the lead, 0) are lit when
    /// `litBehind` (it is running into the shadow: the lead goes first), those before it otherwise (coming out of it).
    public var shadowMember: Float
    public var litBehind: Bool
    /// A panel's glint now, 0…1 (0 with none).
    public var flare: Float
    /// Its height (km) and its range from you (km).
    public var heightKm: Float
    public var rangeKm: Float

    public init(kind: Kind, id: Int = 0, direction: SIMD3<Float>, tangent: SIMD3<Float>, angularSpeed: Float, count: Int = 1,
                spacing: Float = 0, magnitude: Float, light: Float, sunlit: Float = 1, redden: Float = 0,
                shadowMember: Float = -1, litBehind: Bool = true, flare: Float = 0, heightKm: Float = 500, rangeKm: Float = 800) {
        self.kind = kind; self.id = id; self.direction = direction; self.tangent = tangent; self.angularSpeed = angularSpeed
        self.count = count; self.spacing = spacing; self.magnitude = magnitude; self.light = light; self.sunlit = sunlit
        self.redden = redden; self.shadowMember = shadowMember; self.litBehind = litBehind; self.flare = flare
        self.heightKm = heightKm; self.rangeKm = rangeKm
    }

    /// The light on the stars' scale (1 = Sirius, magnitude −1.44) of magnitude `m`.
    public static func light(magnitude m: Float) -> Float {
        guard m.isFinite else { return 0 }
        return Float(pow(10.0, -0.4 * (Double(m) - Satellites.siriusMagnitude)))
    }
}

/// The satellites' machine (spec §6.2).
public struct Satellites {
    /// Slots in the sky at once: the brightest passes now.
    public static let slots = 4
    /// Natural: a pass every 225–675 s of viewing (8 an hour); Often a third of that. All of them lit right after dusk,
    /// fewer as the night deepens.
    public static let gaps = 225.0...675.0
    public static let oftenFactor = 3.0
    /// Only while the sky is dark enough: the sun below −6° (they fade in over the degree above).
    public static let darkBelow = -6.0
    /// A train: one a week of viewing on Natural (gaps of 4–10 days); 8–24 members 2–5 s apart, 290–340 km up.
    public static let trainGaps = 345_600.0...864_000.0
    /// A flare: on one pass in ten; 2–10 s long, peaking at −3 … −4.6 (Venus at its brightest, never brighter).
    public static let flareChance = 0.1
    public static let flareSeconds = 2.0...10.0
    public static let venus: Float = -4.6
    public static let flarePeaks: ClosedRange<Float> = -4.6 ... -3
    /// A big moment's flare waits this long after the last one called (seconds).
    static let callSpacing = 30.0
    /// The Earth (km), μ (km³/s²), Sirius's magnitude and the air's extinction (magnitudes per airmass).
    public static let earthKm = 6371.0
    static let mu = 398_600.4418
    public static let siriusMagnitude = -1.44
    static let extinction = 0.2
    /// The penumbra: sunlight is cut off by the atmosphere's lowest 5 km and fully through above 12 km over the limb, and
    /// reddened up to 70 km over it.
    static let shadowEdge = (5.0, 12.0)
    static let reddening = 70.0
    /// A station: one in the first 3–25 minutes after dusk, high (35–85° up), and one orbit later (92.6 min) one evening
    /// in two; standard magnitude −1.3 (a large station near −3 overhead).
    static let stationDelay = 180.0...1500.0
    static let stationOrbit = 5556.0
    static let stationMagnitude = -1.3
    /// The real-star texture's footprint (StarTexture: 1 + 0.2 × max(0, 2.5 − m) texels of 2π/2048 rad).
    public static func footprint(magnitude m: Float) -> Float {
        (1 + 0.2 * max(0, 2.5 - m)) * (2 * Float.pi / 2048)
    }

    struct Flare { var at: Double; var peak: Double; var duration: Double }

    struct Pass {
        var id: Int
        var kind: SatelliteSlot.Kind
        var radius: Double
        var omega: Double
        var q: SIMD3<Double>
        var t: SIMD3<Double>
        var t0: Double
        var half: Double
        var standard: Double
        var count: Int
        var gap: Double
        var flare: Flare?

        var rise: Double { t0 - half / omega }
        var set: Double { t0 + half / omega }
        func position(at time: Double) -> SIMD3<Double> {
            let phi = omega * (time - t0)
            return radius * (cos(phi) * q + sin(phi) * t)
        }
        func velocity(at time: Double) -> SIMD3<Double> {
            let phi = omega * (time - t0)
            return radius * omega * (-sin(phi) * q + cos(phi) * t)
        }
    }

    public private(set) var time = 0.0
    /// Passes made so far (stations and trains included) and the stations' times (for tests).
    public private(set) var spawned = 0
    public private(set) var stationTimes: [Double] = []
    private(set) var passes: [Pass] = []
    /// Test seams: the next pass's kind, maximum elevation (degrees), heading (degrees) and a flare at its middle.
    var forceNext: (kind: SatelliteSlot.Kind, elevation: Double, heading: Double, height: Double, flare: Bool)?
    private var gapRng: SeededRandom
    private var shapeRng: SeededRandom
    private var trainRng: SeededRandom
    private var stationRng: SeededRandom
    private var wait: Double
    private var phase = 0.0
    private var trainWait: Double
    private var trainPhase = 0.0
    private var nextID = 0
    private var lastSunAltitude: Double?
    private var stationQueue: [Double] = []
    private var lastCall = -1e9

    public init(seed: UInt64) {
        var g = SeededRandom(seed: seed &* 0x9FB2_1C65_1E98_DF25 &+ 0x5A7)
        wait = AnvilCrawlers.unit(&g)
        gapRng = g
        shapeRng = SeededRandom(seed: seed &* 0xA24B_AED4_963E_E407 &+ 0x0B17)
        var tr = SeededRandom(seed: seed &* 0x9E6C_63D0_676A_9A99 &+ 0x7A15)
        trainWait = AnvilCrawlers.unit(&tr)
        trainRng = tr
        stationRng = SeededRandom(seed: seed &* 0xE703_7ED1_A0B4_28DB &+ 0x5747)
    }

    static func gap(_ u: Double, mode: SkyExtraMode) -> Double {
        (gaps.lowerBound + u * (gaps.upperBound - gaps.lowerBound)) / (mode == .often ? oftenFactor : 1)
    }

    /// Advances `dt` seconds. `sun`: the sun's direction now (east-north-up unit vector); `latitude`: the observer's
    /// (degrees, for the tracks' headings); `skyglow`: a city's limiting magnitude (fainter passes unseen; nil: a dark
    /// sky); `call`: a big moment's strength this step (it flares a pass in view). Off makes none (and clears the sky).
    /// Returns the brightest passes in the sky at the end of the step, at most `slots`.
    public mutating func step(dt rawDt: Double, sun: SIMD3<Double>, latitude: Double, mode: SkyExtraMode,
                              skyglow: Float? = nil, call: Float? = nil) -> [SatelliteSlot] {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let start = time
        time += dt
        let sunAlt = asin(min(1, max(-1, sun.z))) * 180 / .pi
        guard mode != .off else {
            passes.removeAll()
            stationQueue.removeAll()
            lastSunAltitude = sunAlt
            return []
        }
        let lat = latitude.isFinite ? latitude : 0
        // The evening begins as the sun goes below −6° (or on the first dark step): its station passes are booked.
        let wasDark = lastSunAltitude.map { $0 < Self.darkBelow }
        if sunAlt < Self.darkBelow, wasDark != true, (lastSunAltitude ?? sunAlt + 1) >= sunAlt {
            stationQueue.removeAll()
            var delay = Self.stationDelay.lowerBound
                + AnvilCrawlers.unit(&stationRng) * (Self.stationDelay.upperBound - Self.stationDelay.lowerBound)
            // A sky whose sun races (the quick day) gets its station while it is still dark: within 40% of the time the
            // sun takes to reach −18° at its present pace.
            if let last = lastSunAltitude, dt > 0, last > sunAlt {
                let pace = (last - sunAlt) / dt
                delay = min(delay, 0.4 * max(0, sunAlt + 18) / pace)
            }
            let first = time + delay
            stationQueue.append(first)
            if AnvilCrawlers.unit(&stationRng) < 0.5 { stationQueue.append(first + Self.stationOrbit) }
        }
        lastSunAltitude = sunAlt
        while let next = stationQueue.first, next <= time {
            stationQueue.removeFirst()
            spawn(kind: .station, at: next, latitude: lat)
        }
        // Ordinary passes, at their rate; and trains, very rarely.
        var t = start, left = dt, count = 0
        while count < 64 {
            let span = Self.gap(wait, mode: mode)
            let need = (1 - phase) * span
            if need > left { phase += left / span; break }
            t += need
            left -= need
            spawn(kind: .satellite, at: t, latitude: lat)
            phase = 0
            wait = AnvilCrawlers.unit(&gapRng)
            count += 1
        }
        let trainSpan = (Self.trainGaps.lowerBound + trainWait * (Self.trainGaps.upperBound - Self.trainGaps.lowerBound))
            / (mode == .often ? Self.oftenFactor : 1)
        trainPhase += dt / trainSpan
        if trainPhase >= 1 {
            trainPhase = 0
            trainWait = AnvilCrawlers.unit(&trainRng)
            spawn(kind: .train, at: time, latitude: lat)
        }
        let now = time
        passes.removeAll { now > $0.set + Double($0.count - 1) * $0.gap }

        var shown: [(index: Int, slot: SatelliteSlot)] = []
        for (i, p) in passes.enumerated() {
            if let s = slot(for: p, at: now, sun: sun, sunAltitude: sunAlt, skyglow: skyglow) { shown.append((i, s)) }
        }
        // A big moment flares the brightest single pass in view that has none on.
        if let s = call, s.isFinite, now - lastCall >= Self.callSpacing,
           let best = shown.filter({ $0.slot.kind != .train && $0.slot.flare == 0 && $0.slot.sunlit > 0.9 && $0.slot.direction.z > 0.26 })
               .max(by: { $0.slot.light < $1.slot.light }) {
            lastCall = now
            let k = Double(min(1, max(0, s)))
            let duration = 5.0 + 2 * k
            passes[best.index].flare = Flare(at: now + duration / 2, peak: Double(Self.flarePeaks.upperBound) - k * 1.6,
                                             duration: duration)
        }
        shown.sort { $0.slot.light > $1.slot.light }
        return shown.prefix(Self.slots).map(\.slot)
    }

    /// The flare's light now at `time`: 0…1, a bell 2–10 s long (5% of its peak at its ends).
    static func flareEnvelope(_ f: Flare, at time: Double) -> Double {
        let sigma = f.duration / (2 * (log(20.0)).squareRoot())
        let x = (time - f.at) / sigma
        return abs(time - f.at) > f.duration / 2 ? 0 : exp(-x * x)
    }

    /// How sunlit a point `p` (km, Earth-centred, east-north-up axes) is under a sun along `sun`, and how red: the
    /// shadow is a cylinder of the Earth's radius away from the sun, its edge softened by the atmosphere's limb.
    public static func sunlight(at p: SIMD3<Double>, sun: SIMD3<Double>) -> (lit: Double, red: Double) {
        let along = simd_dot(p, sun)
        guard along < 0 else { return (1, 0) }
        let off = simd_length(p - along * sun) - earthKm
        let lo = shadowEdge.0, hi = shadowEdge.1
        let x = min(1, max(0, (off - lo) / (hi - lo)))
        let lit = x * x * (3 - 2 * x)
        let r = min(1, max(0, (off - hi) / (reddening - hi)))
        return (lit, lit * (1 - r * r * (3 - 2 * r)))
    }

    /// A pass's apparent magnitude seen along `look` (observer to satellite, km): its standard magnitude (at 1000 km,
    /// half lit), its range, its phase (a diffuse sphere's), and the air (0.2 magnitudes an airmass).
    static func magnitude(standard: Double, look: SIMD3<Double>, sun: SIMD3<Double>) -> Double {
        let range = max(1, simd_length(look))
        let dir = look / range
        let cosPsi = min(1, max(-1, simd_dot(sun, -dir)))
        let psi = acos(cosPsi)
        let phase = max(1e-3, sin(psi) + (Double.pi - psi) * cosPsi)
        let e = max(0, asin(min(1, max(-1, dir.z))) * 180 / .pi)
        let airmass = min(40, 1 / (sin(e * .pi / 180) + 0.50572 * pow(e + 6.07995, -1.6364)))
        return standard + 5 * log10(range / 1000) - 2.5 * log10(phase) + extinction * airmass
    }

    /// The slot a pass makes now (nil while it is below the horizon or unseen).
    private func slot(for p: Pass, at now: Double, sun: SIMD3<Double>, sunAltitude: Double, skyglow: Float?) -> SatelliteSlot? {
        let observer = SIMD3<Double>(0, 0, Self.earthKm)
        let pos = p.position(at: now)
        let look = pos - observer
        let range = simd_length(look)
        guard range > 1 else { return nil }
        let dir = look / range
        guard dir.z > -0.02 else { return nil }
        let v = p.velocity(at: now)
        let across = (v - simd_dot(v, dir) * dir) / range
        let speed = simd_length(across)
        let tangent = speed > 1e-12 ? across / speed : SIMD3<Double>(1, 0, 0)
        let sunlight = Self.sunlight(at: pos, sun: sun)
        var m = Self.magnitude(standard: p.standard, look: look, sun: sun)
        var glint = 0.0
        if let f = p.flare {
            glint = Self.flareEnvelope(f, at: now) * sunlight.lit
            if glint > 0 {
                let base = pow(10.0, -0.4 * m), peak = pow(10.0, -0.4 * f.peak)
                m = -2.5 * log10(base + (max(peak, base) - base) * glint)
            }
        }
        let x = min(1, max(0, (sunAltitude - (Self.darkBelow - 1)) / 1))
        let dark = 1 - x * x * (3 - 2 * x)
        // A train's shadow edge: which members are lit (the lead's light is the train's).
        var litBehind = true, edge: Double = -1
        var lit = sunlight.lit
        if p.kind == .train, p.count > 1 {
            var prev = sunlight.lit
            for k in 1..<p.count {
                let s = Self.sunlight(at: p.position(at: now - Double(k) * p.gap), sun: sun).lit
                if (prev - 0.5) * (s - 0.5) < 0 {
                    edge = Double(k - 1) + (0.5 - prev) / (s - prev)
                    litBehind = s > prev
                    break
                }
                prev = s
            }
            if edge >= 0 { lit = 1 }   // some members are lit: the lead's light stands for theirs
            else if sunlight.lit < 0.5 { lit = Self.sunlight(at: p.position(at: now - Double(p.count - 1) * p.gap), sun: sun).lit }
        }
        var light = Double(SatelliteSlot.light(magnitude: Float(m))) * lit * dark
        if let limit = skyglow, limit.isFinite {
            let y = min(1, max(0, (Double(limit) - m) / 0.3))
            light *= y * y * (3 - 2 * y)
        }
        guard light > 1e-6 else { return nil }
        return SatelliteSlot(kind: p.kind, id: p.id, direction: SIMD3(Float(dir.x), Float(dir.y), Float(dir.z)),
                             tangent: SIMD3(Float(tangent.x), Float(tangent.y), Float(tangent.z)), angularSpeed: Float(speed),
                             count: p.count, spacing: Float(speed * p.gap), magnitude: Float(m), light: Float(light),
                             sunlit: Float(lit), redden: Float(sunlight.red), shadowMember: Float(edge), litBehind: litBehind,
                             flare: Float(glint), heightKm: Float(p.radius - Self.earthKm), rangeKm: Float(range))
    }

    /// A new pass rising now: its height, orbit family, heading, how close it passes and its brightness (a fixed eleven
    /// draws, whatever it uses, so the stream keeps its step).
    private mutating func spawn(kind: SatelliteSlot.Kind, at t: Double, latitude: Double) {
        var u = FarStorms.draws(11, &shapeRng)
        var kind = kind
        var flareAt: Double? = nil
        if let f = forceNext {
            forceNext = nil
            kind = f.kind
            u[3] = 1
            if f.flare { flareAt = 0 }
        }
        let height: Double, standard: Double, count: Int, gap: Double, inclination: Double
        switch kind {
        case .station:
            height = 415 + 10 * u[0]; standard = Self.stationMagnitude; count = 1; gap = 0; inclination = 51.6
        case .train:
            height = 290 + 50 * u[0]; standard = 2.6 + 0.8 * u[1]; count = 8 + Int(u[2] * 17); gap = 2 + 3 * u[4]
            inclination = 53
        case .satellite:
            height = u[0] < 0.7 ? 450 + 200 * u[1] : (u[0] < 0.9 ? 650 + 250 * u[1] : 900 + 300 * u[1])
            standard = 2 + 3.5 * u[2].squareRoot(); count = 1; gap = 0
            inclination = u[4] < 0.5 ? 51.6 + 1.6 * u[5] : (u[4] < 0.85 ? 97 + 2 * u[5] : 30 + 50 * u[5])
        }
        // The track's heading at this latitude for the inclination (ascending or descending, either way along it).
        let ratio = cos(inclination * .pi / 180) / max(0.05, cos(latitude * .pi / 180))
        var heading = abs(ratio) <= 1 ? asin(ratio) * 180 / .pi : 90
        if u[6] < 0.5 { heading = 180 - heading }
        if u[7] < 0.5 { heading += 180 }
        heading += 6 * (u[8] - 0.5)
        // How high it passes: low passes outnumber high ones; a station's first pass is a good one.
        var elevation = kind == .station ? 35 + 50 * u[9] : 12 + 76 * u[9] * u[9]
        if kind == .train { elevation = 30 + 50 * u[9] }
        var radius = Self.earthKm + height
        if let f = forceNextApplied { elevation = f.elevation; heading = f.heading; radius = Self.earthKm + f.height }
        let side: Double = u[10] < 0.5 ? -1 : 1
        let e = elevation * .pi / 180
        let beta = max(0, acos(min(1, Self.earthKm / radius * cos(e))) - e)
        let psi = heading * .pi / 180
        let along = SIMD3<Double>(sin(psi), cos(psi), 0)
        let sideways = SIMD3<Double>(cos(psi), -sin(psi), 0) * side
        let q = cos(beta) * SIMD3<Double>(0, 0, 1) + sin(beta) * sideways
        let half = acos(min(1, Self.earthKm / (radius * cos(beta))))
        let omega = (Self.mu / (radius * radius * radius)).squareRoot()
        let t0 = t + half / omega
        if kind == .satellite, flareAt == nil, u[3] < Self.flareChance {
            flareAt = (u[3] / Self.flareChance * 1.2 - 0.6) * half / omega
        }
        var flare: Flare?
        if let offset = flareAt {
            let duration = Self.flareSeconds.lowerBound + u[1] * (Self.flareSeconds.upperBound - Self.flareSeconds.lowerBound)
            let peak = Double(Self.flarePeaks.upperBound) - Double(u[2]) * 1.6
            flare = Flare(at: t0 + offset, peak: max(Double(Self.venus), peak), duration: duration)
        }
        nextID += 1
        passes.append(Pass(id: nextID, kind: kind, radius: radius, omega: omega, q: q, t: along, t0: t0, half: half,
                           standard: standard, count: count, gap: gap, flare: flare))
        forceNextApplied = nil
        spawned += 1
        if kind == .station { stationTimes.append(t) }
    }

    /// The forced pass's geometry while it is being made (test seam).
    private var forceNextApplied: (kind: SatelliteSlot.Kind, elevation: Double, heading: Double, height: Double, flare: Bool)?

    /// Test seam: the next ordinary pass is this one, rising now.
    mutating func force(kind: SatelliteSlot.Kind, elevation: Double, heading: Double, height: Double, flare: Bool = false,
                        latitude: Double = -37.8) {
        forceNext = (kind, elevation, heading, height, flare)
        forceNextApplied = forceNext
        spawn(kind: kind, at: time, latitude: latitude)
    }
}
