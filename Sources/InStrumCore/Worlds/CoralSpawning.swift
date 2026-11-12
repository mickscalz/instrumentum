import Foundation
import simd

/// When the reef spawns (spec §9.3): on the calendar's nights, tonight whatever the calendar says, or never.
public enum CoralSpawningSetting: String, Codable, CaseIterable {
    case follow = "Follow the calendar", tonight = "Tonight", off = "Off"

    /// The world parameter that chooses it.
    public static func spec(default d: CoralSpawningSetting) -> ParamSpec {
        ParamSpec(id: "spawning", name: "Coral spawning", group: "Reef",
                  help: "Follow the calendar (one to six nights after the October, November and December full moons, from two and a half to five hours after sunset), make tonight a spawning night, or never",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }
}

/// A bead of coral spawn, rising from the reef toward the surface.
public struct SpawnBead: Equatable {
    public var id: Int
    /// x 0…1 across the frame; y in water heights, 0 the reef floor at the bottom of the water … 1 the underside of the
    /// surface (where it joins the slick and is gone).
    public var position: SIMD2<Float>
    /// Linear RGB: one of the bundles' pink, orange or yellow (`CoralSpawning.colours`).
    public var colour: SIMD3<Float>
    /// Its size, 1…2 px.
    public var size: Float
    /// 0…1 now: it brightens over its first 1.5 s and fades into the slick over the last 6% of the water.
    public var brightness: Float
    var origin: Float
    var speed: Float
    var sway: Float
    var swayRate: Float
    var phase: Float
    var albedo: Float
    var age: Float
}

/// The night's spawn, for the renderer.
public struct CoralSpawn: Equatable {
    /// The beads rising now (at most 600; 300 on Smooth), oldest first.
    public var beads: [SpawnBead]
    /// 0 none … 1: the pinkish slick gathering on the underside of the surface after the snowstorm.
    public var slick: Float
    /// 0…1: how strongly the reef is spawning now (the spawning hours' 10-minute ramps × the night's strength).
    public var intensity: Float

    public static let none = CoralSpawn(beads: [], slick: 0, intensity: 0)
}

/// Where the reef's spawning calendar stands on the sky's night (spec §9.3).
public struct SpawningNight: Equatable {
    /// Nights since the last full moon (the full moon's own night is 0): with the real moon, counted on the sky city's
    /// clock (a night is noon to noon, named by its evening); with a placed moon, its age less a half-month, rounded.
    public var night: Int
    /// The month (1…12) of that full moon on the sky city's calendar.
    public var fullMoonMonth: Int
    /// Tonight is one of the spawning nights: +1…+6 after an October, November or December full moon (with a placed
    /// moon: its age 15.8–20.8 days).
    public var isSpawningNight: Bool
    /// The night's strength: 1 on the outer reef's nights (+3…+5 after the November and December full moons), 0.6 on
    /// the others (the inshore reefs, a month earlier, and the first and last nights).
    public var strength: Float
}

/// Coral spawning (spec §9.3). On nights +1…+6 after the October, November and December full moons, from 2.5 to 5 hours
/// after sunset (ramping in and out over 10 minutes centred on those hours), the reef's polyps release pink, orange and
/// yellow bundles that rise slowly through the water (0.01–0.03 water heights a second), wobbling: they thicken into an
/// upside-down snowstorm for 20–40 minutes (seeded by the night), then gather into a pinkish slick on the underside of
/// the surface. The nights are found with the Living Sky's own moon: in real time its last full moon (`Lunar`, at the
/// sky's calendar instant), counted on the city's clock; with a placed moon (quick and frozen modes) its age. The hours
/// come from where the sky shows the sun. "Tonight" makes any night a spawning night at full strength; "Off" never.
/// At most 600 beads (300 on Smooth), deterministic from the seed; the beads step in place.
public struct CoralSpawning {
    /// Beads at most, by quality (Smooth 300).
    public static func cap(_ q: QualityLevel) -> Int { q == .lite ? 300 : 600 }
    public static let capacity = 600
    public static let nights: ClosedRange<Int> = 1...6
    public static let strongestNights: ClosedRange<Int> = 3...5
    /// A placed moon's spawning ages (days since the new moon).
    public static let ages: ClosedRange<Double> = 15.8...20.8
    /// The spawning hours (after sunset) and their ramps (hours, centred on each edge).
    public static let hours: ClosedRange<Double> = 2.5...5
    public static let ramp = 10.0 / 60
    /// The months whose full moons bring spawning.
    public static let months: ClosedRange<Int> = 10...12
    public static let synodicMonth = 29.530588853
    /// The snowstorm lasts this long (minutes, seeded by the night), then thins to a trickle (`trickle` of its rate,
    /// with τ 10 minutes) while the slick gathers.
    public static let snowstormMinutes: ClosedRange<Double> = 20...40
    static let trickle = 0.12
    /// Beads released a second at full strength (with the 600 cap: the snowstorm's column holds about 600).
    public static let fullRate = 15.0
    /// How long a bead takes, on average, from its coral to the surface (s): the mean of (1 − y₀) / speed.
    static let meanLife = 0.73 * log(3.0) / 0.02
    public static let colours: [SIMD3<Float>] = [SIMD3<Float>(1.0, 0.42, 0.62), SIMD3<Float>(1.0, 0.55, 0.22),
                                                 SIMD3<Float>(1.0, 0.86, 0.35)]

    /// The beads rising now, oldest first.
    public private(set) var beads: [SpawnBead] = []
    /// 0…1: the slick under the surface.
    public private(set) var slick: Float = 0
    /// 0…1: how strongly the reef is spawning now.
    public private(set) var intensity: Float = 0
    /// Beads released and gone into the slick so far (tests).
    private(set) var released = 0
    private(set) var gathered = 0

    var nextID = 0
    private var rng: SeededRandom
    private var owed = 0.0
    private var lastRate: Double?
    /// The real moon's last full moon and the one after it: the cache holds while the sky's date stays between them.
    private var fullMoon: (last: Date, next: Date)?

    public init(seed: UInt64 = 0x5BA_C0A1) {
        rng = SeededRandom(seed: seed)
        beads.reserveCapacity(Self.capacity)
    }

    /// The spawn for the renderer.
    public var spawn: CoralSpawn { CoralSpawn(beads: beads, slick: slick, intensity: intensity) }

    // MARK: - The calendar

    /// Hours since the sun last set (0…<24), sunset being the upper limb at the horizon (−0.833°, as `Solar.sunset`).
    /// From where the sky shows the sun: its hour angle from its altitude (refraction taken back off), on the west side
    /// of the meridian when its azimuth is, its declination the subsolar latitude. With the light held (its sun is not
    /// the clock's), from the clock hour against a sunset at 12 + H₀/15 h, H₀ the sunset hour angle (local solar time
    /// taken as the clock's). A polar night counts a nominal 6 p.m. sunset; nil under the midnight sun (no night).
    public static func hoursAfterSunset(_ sky: SkyState, held: Bool = false) -> Double? {
        let lat = sky.latitude * .pi / 180, dec = sky.subsolar.latitude * .pi / 180
        guard lat.isFinite, dec.isFinite else { return nil }
        let across = cos(lat) * cos(dec)
        guard abs(across) > 1e-9 else { return nil }
        let level = sin(lat) * sin(dec)
        let c0 = (sin(-0.833 * Double.pi / 180) - level) / across
        guard c0 > -1 else { return nil }
        let setAngle = c0 >= 1 ? 90 : acos(c0) * 180 / .pi
        var since: Double
        if held {
            guard sky.hourOfDay.isFinite else { return nil }
            since = sky.hourOfDay - (12 + setAngle / 15)
        } else {
            let alt = sky.sun.altitude, az = sky.sun.azimuth
            guard alt.isFinite, az.isFinite else { return nil }
            let geometric = alt - Astro.refraction(alt)
            let c = (sin(geometric * .pi / 180) - level) / across
            var angle = acos(min(1, max(-1, c))) * 180 / .pi
            if sin(az * .pi / 180) > 0 { angle = -angle }   // east of the meridian: the morning's side
            since = (angle - setAngle) / 15
        }
        since = since.truncatingRemainder(dividingBy: 24)
        if since < 0 { since += 24 }
        return since
    }

    /// The last full moon at or before `date`, found with the Living Sky's own moon (`Lunar.next(.full, after:)`).
    public static func lastFullMoon(before date: Date) -> Date {
        guard date.timeIntervalSince1970.isFinite else { return date }
        var full = Lunar.next(.full, after: date.addingTimeInterval(-30 * 86_400))
        for _ in 0..<3 {   // thirty days hold one full moon or two
            let following = Lunar.next(.full, after: full)
            guard following <= date else { break }
            full = following
        }
        return full
    }

    /// The spawning calendar on the sky's night: the nights since its last full moon, that moon's month, and whether
    /// tonight spawns and how strongly. `lastFullMoon` saves the search when the caller has it (the real moon only).
    public static func night(_ sky: SkyState, lastFullMoon cached: Date? = nil) -> SpawningNight {
        let hour = sky.hourOfDay.isFinite ? min(max(sky.hourOfDay, 0), 24) : 0
        let x = hour / 24 - 0.5
        let days: Double
        let night: Int
        let inWindow: Bool
        if sky.realMoon {
            let full = cached ?? Self.lastFullMoon(before: sky.calendar)
            let elapsed = sky.calendar.timeIntervalSince(full) / 86_400
            days = elapsed.isFinite ? min(max(elapsed, 0), 40) : 0
            night = Int((x).rounded(.down)) - Int((x - days).rounded(.down))
            inWindow = Self.nights.contains(night)
        } else {
            var phase = sky.moonPhase.isFinite ? sky.moonPhase.truncatingRemainder(dividingBy: 1) : 0
            if phase < 0 { phase += 1 }
            let age = phase * Self.synodicMonth
            var after = age - Self.synodicMonth / 2
            if after < 0 { after += Self.synodicMonth }   // before this month's full moon: since last month's
            days = after
            night = Int(after.rounded())
            inWindow = Self.ages.contains(age)
        }
        let month = Self.month(dayOfYear: sky.dayOfYear + Int((hour / 24 - days).rounded(.down)), year: Self.year(sky.calendar))
        let spawning = inWindow && Self.months.contains(month)
        let outer = (month == 11 || month == 12) && Self.strongestNights.contains(night)
        return SpawningNight(night: night, fullMoonMonth: month, isSpawningNight: spawning, strength: outer ? 1 : 0.6)
    }

    /// The spawning hours' envelope (0…1) at `h` hours after sunset: 10-minute ramps centred on 2.5 h and 5 h.
    public static func hoursEnvelope(_ h: Double?) -> Float {
        guard let h, h.isFinite else { return 0 }
        let half = ramp / 2
        let up = MoonlitLakeModel.smooth(hours.lowerBound - half, hours.lowerBound + half, h)
        let down = 1 - MoonlitLakeModel.smooth(hours.upperBound - half, hours.upperBound + half, h)
        return Float(up * down)
    }

    /// How strongly the reef spawns under this sky, 0…1: on a spawning night the hours' envelope × the night's strength;
    /// with "Tonight" the envelope at full strength, whatever the moon and the month; with "Off", never.
    public static func intensity(_ sky: SkyState, setting: CoralSpawningSetting, held: Bool = false,
                                 lastFullMoon cached: Date? = nil) -> Float {
        let t = tonight(sky, setting: setting, held: held, lastFullMoon: cached)
        return t.strength * t.envelope
    }

    /// Tonight's strength (0 on a night that doesn't spawn) and the spawning hours' envelope now.
    static func tonight(_ sky: SkyState, setting: CoralSpawningSetting, held: Bool,
                        lastFullMoon cached: Date?) -> (strength: Float, envelope: Float) {
        let strength: Float
        switch setting {
        case .off:
            return (0, 0)
        case .tonight:
            strength = 1
        case .follow:
            let n = night(sky, lastFullMoon: cached)
            strength = n.isSpawningNight ? n.strength : 0
        }
        guard strength > 0 else { return (0, 0) }
        return (strength, hoursEnvelope(hoursAfterSunset(sky, held: held)))
    }

    /// The month (1…12) of a day of the year (a day before 1 January is last year's December: the spawning nights reach
    /// back a week at most).
    static func month(dayOfYear doy: Int, year: Int) -> Int {
        guard doy >= 1 else { return 12 }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let d = min(365, leap && doy >= 60 ? doy - 1 : doy)   // a leap year's 29 February counts as the 28th
        let starts = [1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]
        var m = 1
        for (i, s) in starts.enumerated() where d >= s { m = i + 1 }
        return m
    }

    /// The year (UT) of an instant, on the proleptic Gregorian calendar (Howard Hinnant's days-to-civil).
    static func year(_ date: Date) -> Int {
        let t = date.timeIntervalSince1970
        guard t.isFinite, abs(t) < 1e12 else { return 1970 }
        let z = Int((t / 86_400).rounded(.down)) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let dayOfYear = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * dayOfYear + 2) / 153
        return yoe + era * 400 + (mp >= 10 ? 1 : 0)
    }

    /// The snowstorm's length tonight (hours): 20–40 minutes, seeded by the night (its evening's day of the year and
    /// the year), so a night keeps its own.
    static func snowstorm(_ sky: SkyState) -> Double {
        let evening = sky.dayOfYear - (sky.hourOfDay < 12 ? 1 : 0)
        let day = UInt64(bitPattern: Int64(evening)) &* 0x9E37_79B9_7F4A_7C15
        var r = SeededRandom(seed: day ^ UInt64(bitPattern: Int64(year(sky.calendar))))
        let u = Double(r.unit())
        return (snowstormMinutes.lowerBound + (snowstormMinutes.upperBound - snowstormMinutes.lowerBound) * u) / 60
    }

    // MARK: - Step

    /// Advances `dt` seconds of viewing under `sky`: the calendar sets tonight's intensity, the snowstorm's release and
    /// the slick (on the sky's clock); the beads rise (per second of viewing). Arriving in the middle of a snowstorm
    /// (the first step, or a jump in the release) fills the water as if it had been falling upward a while.
    public mutating func step(dt: Double, sky: SkyState, setting: CoralSpawningSetting, held: Bool, quality: QualityLevel) {
        let step = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fdt = Float(step)
        var full: Date?
        if sky.realMoon && setting == .follow { full = cachedFullMoon(sky.calendar) }
        let tonight = Self.tonight(sky, setting: setting, held: held, lastFullMoon: full)
        intensity = tonight.strength * tonight.envelope
        let into = (Self.hoursAfterSunset(sky, held: held) ?? 0) - Self.hours.lowerBound   // hours into the spawning hours
        let storm = Self.snowstorm(sky)
        var release = 1.0
        if into > storm { release = Self.trickle + (1 - Self.trickle) * exp(-(into - storm) / (10.0 / 60)) }
        let cap = Self.cap(quality)
        let fullRate = Self.fullRate * Double(cap) / Double(Self.capacity)
        let rate = fullRate * Double(intensity) * release

        // The beads rise; those at the surface join the slick.
        for i in beads.indices { Self.advance(&beads[i], by: fdt) }
        let before = beads.count
        beads.removeAll { $0.position.y >= 1 }
        gathered &+= before - beads.count
        if beads.count > cap {   // a lower quality: the highest (oldest) go into the slick at once
            gathered &+= beads.count - cap
            beads.removeFirst(beads.count - cap)
        }

        // Arriving while it spawns (the first step), or the release jumping (a time jump, "Tonight" chosen mid-night): the
        // water fills to the steady column at once, each bead part way up.
        let arriving = lastRate == nil && rate > 0
        let previous = lastRate ?? 0
        if arriving || (previous < 0.05 * fullRate && rate > 0.3 * fullRate) {
            let wanted = min(cap, Int(rate * Self.meanLife))
            while beads.count < wanted { beads.append(newBead(partWay: true)) }
            owed = 0
        }
        lastRate = rate

        // New beads, at the rate (whole beads owed carry over; none are banked while the water is full).
        owed += rate * step
        while owed >= 1, beads.count < cap {
            beads.append(newBead(partWay: false))
            owed -= 1
        }
        if beads.count >= cap { owed = min(owed, 1) }

        // The slick gathers after the snowstorm and stays while the spawning hours last (on the sky's clock), gliding
        // so that it never jumps.
        let gather = MoonlitLakeModel.smooth(0.5 * storm, storm + 0.25, into)
        let target = Float(gather) * intensity
        slick += (target - slick) * Float(1 - exp(-step / 3))
        slick = slick < 1e-4 ? 0 : min(1, slick)
    }

    /// A spawning burst (Excitement's big moment on the reef, Fire & Neon spec §5.5): every coral group lets go a puff of
    /// bundles at once, any night or day, rising quicker than the calendar's at first and already catching the light.
    /// Up to 60 + 160 × `strength` beads; with the water full, the oldest (highest) go into the slick to make room.
    public mutating func burst(strength: Float, quality: QualityLevel) {
        let s = strength.isFinite ? min(1, max(0, strength)) : 0.3
        let cap = Self.cap(quality)
        let count = min(cap, Int((60 + 160 * s).rounded()))
        if beads.count + count > cap {
            let out = beads.count + count - cap
            gathered &+= out
            beads.removeFirst(min(out, beads.count))
        }
        for _ in 0..<count {
            var bead = newBead(partWay: false)
            bead.speed = rng.range(0.035, 0.09)
            Self.advance(&bead, by: 1.0 + rng.unit())
            beads.append(bead)
        }
    }

    /// The real moon's last full moon, searched for again only once the sky's date leaves the month it began.
    private mutating func cachedFullMoon(_ date: Date) -> Date {
        if let f = fullMoon, date >= f.last, date < f.next { return f.last }
        let last = Self.lastFullMoon(before: date)
        fullMoon = (last, Lunar.next(.full, after: last))
        return last
    }

    /// A new bead from one of the seven coral groups (`partWay`: already some way up, as if released a while ago).
    private mutating func newBead(partWay: Bool) -> SpawnBead {
        let g = min(CoralPulse.groupCount - 1, Int(rng.unit() * Float(CoralPulse.groupCount)))
        let x0 = CoralPulse.groupX[g] + rng.range(-0.05, 0.05)
        let y0 = CoralPulse.groupTop[g] + rng.range(-0.01, 0.04)
        let speed = rng.range(0.01, 0.03)
        let pick = rng.unit()
        let colour = Self.colours[pick < 0.45 ? 0 : (pick < 0.75 ? 1 : 2)]
        let size = 1 + rng.unit()
        let sway = rng.range(0.003, 0.01), swayRate = rng.range(0.5, 1.3), phase = rng.range(0, 2 * .pi)
        let albedo = rng.range(0.6, 1)
        let along = rng.unit()
        var bead = SpawnBead(id: nextID, position: SIMD2<Float>(x0, y0), colour: colour, size: size, brightness: 0,
                             origin: x0, speed: speed, sway: sway, swayRate: swayRate, phase: phase, albedo: albedo, age: 0)
        nextID = nextID &+ 1
        released &+= 1
        if partWay {
            let life = (1 - y0) / speed
            Self.advance(&bead, by: 0.97 * along * life)
        } else {
            Self.advance(&bead, by: 0)
        }
        return bead
    }

    /// A bead `dt` seconds on: it rises at its speed, sways on its wobble and drifts a little with the current.
    private static func advance(_ b: inout SpawnBead, by dt: Float) {
        b.age += dt
        b.position.y += b.speed * dt
        let wobble = b.sway * sin(b.swayRate * b.age + b.phase)
        b.position.x = min(1, max(0, b.origin + wobble + 0.0008 * b.age))
        let fadeIn = min(1, b.age / 1.5)
        let fadeOut = min(1, max(0, (1 - b.position.y) / 0.06))
        b.brightness = b.albedo * fadeIn * fadeOut
    }
}
