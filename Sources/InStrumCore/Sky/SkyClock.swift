import Foundation

/// Quick (a whole day in minutes), real time (your Mac's clock at a city), or frozen at a chosen hour and moon.
public enum TimeMode: String, Codable, CaseIterable { case quick, realTime, frozen }

/// How often a Sky extras feature shows (Storms spec §6: anvil crawlers and sheet lightning; Fire & Neon's red sprites
/// and satellites are meant to share it): not at all, as often as the real thing, or three times as often.
public enum SkyExtraMode: String, Codable, CaseIterable {
    case off = "Off", natural = "Natural", often = "Often"

    /// A world's own choice for one of them (a world parameter, so leaving the world leaves it behind): `crawlers.mode`
    /// or `sheet.mode`. A world without it follows the Sky extras setting.
    public static func spec(id: String, name: String, help: String, default d: SkyExtraMode) -> ParamSpec {
        ParamSpec(id: id, name: name, group: "Sky", help: help, kind: .choice(allCases.map(\.rawValue)),
                  defaultValue: .choice(d.rawValue))
    }

    /// The world parameter ids, which are also the settings' keys.
    public static let crawlersID = "crawlers.mode", sheetID = "sheet.mode"
}

public struct SkySettings: Codable, Equatable {
    public var timeMode: TimeMode = .quick
    /// Quick mode: one day lasts this many minutes (2…60).
    public var dayMinutes: Double = 12
    /// Frozen mode: local hour (0…<24) and moon phase (0 new … 0.5 full … 1).
    public var frozenHour: Double = 21
    public var frozenPhase: Double = 0.5
    /// nil follows the Mac's time zone.
    public var cityID: String?
    public var weatherMode: WeatherMode = .randomBeautiful
    public var weather: WeatherKind = .clear
    /// Advanced: how long a weather you pick takes to blend in (1…120 s), how long random weather blends (10…300 s),
    /// and how long a random spell lasts on average (2…60 min).
    public var pickBlendSeconds: Double = 12
    public var randomBlendSeconds: Double = 60
    public var spellMinutes: Double = 12.5
    /// Advanced: how bright rainbows are, 0 (none) … 1 (full).
    public var rainbowStrength: Double = 1
    /// Advanced: how long the ground takes to dry after rain (2…60 min).
    public var dryingMinutes: Double = 8
    /// Advanced: scale the wind and the mist/haze (0…2), halo strength and frost (0…1.5); 1 is as designed.
    public var windScale: Double = 1
    public var mistScale: Double = 1
    public var haloScale: Double = 1
    public var frostScale: Double = 1
    /// Advanced: scale how hard it rains and snows, and how gusty it is (0…2).
    public var rainScale: Double = 1
    public var snowScale: Double = 1
    public var gustScale: Double = 1
    /// Advanced: keep random weather gentle (no storms, blizzards, monsoons, hail, squalls or dust storms).
    public var calmRandom: Bool = false
    /// Advanced: weathers "Random, beautiful" must never pick (your choice, on top of Calm).
    public var randomExcluded: [WeatherKind] = []
    /// Advanced: how often a storm flashes (0.25…3, 1 = every 6–20 s), cloud cover (0…1.5) and star brightness (0…1.5).
    public var lightningFrequency: Double = 1
    public var cloudScale: Double = 1
    public var starScale: Double = 1
    /// Advanced: how big the moon and the sun look (0.5…3; 1 is true size ~; try 2 for a supermoon).
    public var moonSize: Double = 1
    public var sunSize: Double = 1
    /// Advanced: the faint glow on the dark part of the moon (0…0.3, designed 0.04).
    public var earthshine: Double = 0.04
    /// Advanced: how strongly the constellation lines are drawn (0…1), and how bright a real aurora is in
    /// Follow-the-sky worlds (0…2; 1 as designed).
    public var constellationLines: Double = 0.35
    public var auroraScale: Double = 1
    /// Advanced: how strongly thin cloud near the sun iridesces (0…1.5; 1 as designed), and how fast rime frost
    /// builds and melts (0.25…4; 1 as designed).
    public var iridescence: Double = 1
    public var rimeSpeed: Double = 1
    /// Advanced: how many shooting stars, as a multiple of a real night (0.5…10; 2 by default, so they are a treat
    /// rather than a rarity).
    public var meteorRate: Double = 2
    /// Sky extras (Storms spec §6): anvil crawlers under a storm's anvil and sheet lightning on the rim, Off / Natural /
    /// Often (Natural by default). A world may choose its own (`crawlers.mode`, `sheet.mode`).
    public var crawlersMode: SkyExtraMode = .natural
    public var sheetMode: SkyExtraMode = .natural
    /// Advanced: how long a gust front takes from the shelf cloud on the horizon to the rain (60…600 s; 180 by
    /// default): Approach for the first third, the Hit for the second, the Rain from two thirds on.
    public var gustFrontSeconds: Double = 180

    public init() {}

    public enum AdvancedPreset: String, CaseIterable { case gentle, dramatic, dreamy }

    /// A one-tap look for the Advanced dials: Gentle (soft, calm), Dramatic (wild, bold) or Dreamy (misty, big moon, halos).
    public mutating func applyAdvanced(_ p: AdvancedPreset) {
        resetAdvanced()
        switch p {
        case .gentle:
            calmRandom = true; windScale = 0.6; gustScale = 0.5; rainScale = 0.7; lightningFrequency = 0.5; pickBlendSeconds = 20
            constellationLines = 0.2; auroraScale = 0.7
            iridescence = 0.6; rimeSpeed = 0.7; meteorRate = 1.5
            crawlersMode = .natural; sheetMode = .natural; gustFrontSeconds = 300
        case .dramatic:
            windScale = 1.4; gustScale = 1.5; lightningFrequency = 2; cloudScale = 1.3; rainScale = 1.3; frostScale = 1.2; pickBlendSeconds = 6
            constellationLines = 0.5; auroraScale = 1.6
            iridescence = 1.4; rimeSpeed = 1.5; meteorRate = 4
            crawlersMode = .often; sheetMode = .often; gustFrontSeconds = 120
        case .dreamy:
            mistScale = 1.5; haloScale = 1.5; starScale = 1.4; moonSize = 1.6; windScale = 0.6; rainbowStrength = 1; pickBlendSeconds = 20
            constellationLines = 0.35; auroraScale = 1.0
            iridescence = 1.0; rimeSpeed = 1.0; meteorRate = 2.5
            crawlersMode = .natural; sheetMode = .often; gustFrontSeconds = 240
        }
    }

    /// Puts every Advanced weather and sky setting back to its designed value (keeps time, city and the weather choice).
    public mutating func resetAdvanced() {
        let d = SkySettings()
        pickBlendSeconds = d.pickBlendSeconds; randomBlendSeconds = d.randomBlendSeconds; spellMinutes = d.spellMinutes
        rainbowStrength = d.rainbowStrength; dryingMinutes = d.dryingMinutes
        windScale = d.windScale; mistScale = d.mistScale; haloScale = d.haloScale; frostScale = d.frostScale
        rainScale = d.rainScale; snowScale = d.snowScale; gustScale = d.gustScale; calmRandom = d.calmRandom; randomExcluded = d.randomExcluded
        lightningFrequency = d.lightningFrequency; cloudScale = d.cloudScale; starScale = d.starScale
        moonSize = d.moonSize; sunSize = d.sunSize; earthshine = d.earthshine
        constellationLines = d.constellationLines; auroraScale = d.auroraScale
        iridescence = d.iridescence; rimeSpeed = d.rimeSpeed; meteorRate = d.meteorRate
        crawlersMode = d.crawlersMode; sheetMode = d.sheetMode; gustFrontSeconds = d.gustFrontSeconds
    }

    enum CodingKeys: String, CodingKey { case timeMode, dayMinutes, frozenHour, frozenPhase, cityID, weatherMode, weather, pickBlendSeconds, randomBlendSeconds, spellMinutes, rainbowStrength, dryingMinutes, windScale, mistScale, haloScale, frostScale, rainScale, snowScale, gustScale, calmRandom, randomExcluded, lightningFrequency, cloudScale, starScale, moonSize, sunSize, earthshine, constellationLines, auroraScale, iridescence, rimeSpeed, meteorRate
        case crawlersMode = "crawlers.mode", sheetMode = "sheet.mode", gustFrontSeconds }

    /// Each field falls back on its own, and numbers are clamped, so one bad value never loses the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkySettings()
        timeMode = (try? c.decodeIfPresent(TimeMode.self, forKey: .timeMode)) ?? d.timeMode
        dayMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .dayMinutes)) ?? d.dayMinutes))
        frozenHour = min(23.99, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frozenHour)) ?? d.frozenHour))
        frozenPhase = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frozenPhase)) ?? d.frozenPhase))
        cityID = (try? c.decodeIfPresent(String.self, forKey: .cityID)) ?? nil
        weatherMode = (try? c.decodeIfPresent(WeatherMode.self, forKey: .weatherMode)) ?? d.weatherMode
        weather = (try? c.decodeIfPresent(WeatherKind.self, forKey: .weather)) ?? d.weather
        pickBlendSeconds = min(120, max(1, (try? c.decodeIfPresent(Double.self, forKey: .pickBlendSeconds)) ?? d.pickBlendSeconds))
        randomBlendSeconds = min(300, max(10, (try? c.decodeIfPresent(Double.self, forKey: .randomBlendSeconds)) ?? d.randomBlendSeconds))
        rainbowStrength = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .rainbowStrength)) ?? d.rainbowStrength))
        dryingMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .dryingMinutes)) ?? d.dryingMinutes))
        windScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .windScale)) ?? d.windScale))
        mistScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .mistScale)) ?? d.mistScale))
        haloScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .haloScale)) ?? d.haloScale))
        frostScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .frostScale)) ?? d.frostScale))
        rainScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .rainScale)) ?? d.rainScale))
        snowScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .snowScale)) ?? d.snowScale))
        gustScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .gustScale)) ?? d.gustScale))
        calmRandom = (try? c.decodeIfPresent(Bool.self, forKey: .calmRandom)) ?? d.calmRandom
        lightningFrequency = min(3, max(0.25, (try? c.decodeIfPresent(Double.self, forKey: .lightningFrequency)) ?? d.lightningFrequency))
        cloudScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .cloudScale)) ?? d.cloudScale))
        starScale = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .starScale)) ?? d.starScale))
        moonSize = min(3, max(0.5, (try? c.decodeIfPresent(Double.self, forKey: .moonSize)) ?? d.moonSize))
        sunSize = min(3, max(0.5, (try? c.decodeIfPresent(Double.self, forKey: .sunSize)) ?? d.sunSize))
        randomExcluded = (try? c.decodeIfPresent([WeatherKind].self, forKey: .randomExcluded)) ?? d.randomExcluded
        earthshine = min(0.3, max(0, (try? c.decodeIfPresent(Double.self, forKey: .earthshine)) ?? d.earthshine))
        spellMinutes = min(60, max(2, (try? c.decodeIfPresent(Double.self, forKey: .spellMinutes)) ?? d.spellMinutes))
        constellationLines = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .constellationLines)) ?? d.constellationLines))
        auroraScale = min(2, max(0, (try? c.decodeIfPresent(Double.self, forKey: .auroraScale)) ?? d.auroraScale))
        iridescence = min(1.5, max(0, (try? c.decodeIfPresent(Double.self, forKey: .iridescence)) ?? d.iridescence))
        rimeSpeed = min(4, max(0.25, (try? c.decodeIfPresent(Double.self, forKey: .rimeSpeed)) ?? d.rimeSpeed))
        meteorRate = min(10, max(0.5, (try? c.decodeIfPresent(Double.self, forKey: .meteorRate)) ?? d.meteorRate))
        // Storms (Review focus 6): settings saved before the two Sky extras modes and the gust front's length load them
        // at their defaults, and a mode from a later build (or a typo) falls back to Natural on its own.
        crawlersMode = (try? c.decodeIfPresent(SkyExtraMode.self, forKey: .crawlersMode)) ?? d.crawlersMode
        sheetMode = (try? c.decodeIfPresent(SkyExtraMode.self, forKey: .sheetMode)) ?? d.sheetMode
        gustFrontSeconds = min(600, max(60, (try? c.decodeIfPresent(Double.self, forKey: .gustFrontSeconds)) ?? d.gustFrontSeconds))
    }
}

/// Where the sky is and what time it shows there.
struct SkyClock {
    struct Reading {
        var instant: Date
        var moonPhase: Double          // 0…1, 0.5 full
        var virtualMoon: Bool          // quick and frozen modes place the moon by phase on the ecliptic
        var hourOfDay: Double
        /// The local calendar day the sky is showing (days since 1970): today's date in real time and frozen
        /// modes, a new day for every cycle in quick mode. It picks each dawn's character and gives the day of the year.
        var day: Int
        /// The real instant (UT) the sky's calendar shows: now in real time; in quick and frozen modes the shown day
        /// at the shown local hour. The meteor calendar runs on it (its solar longitude), so quick mode walks the
        /// showers a day a cycle and frozen mode keeps today's.
        var calendar: Date
    }

    private(set) var location = GeoPoint(latitude: 0, longitude: 0)
    private(set) var timeZone = TimeZone(identifier: "UTC")!
    private var equinoxMidnight = Date(timeIntervalSince1970: 0)
    private var quickDays: Double?
    private var quickStart = 0.0, quickPhase0 = 0.5, quickBaseDay = 0
    private var mode: TimeMode?

    /// Resolves the city: the chosen one, else the Mac's time zone's, else 0°, 0° in the Mac's zone.
    mutating func place(cityID: String?, homeZone: TimeZone) {
        let city = cityID.flatMap(Cities.city(id:)) ?? Cities.defaultCity(for: homeZone)
        location = city?.point ?? GeoPoint(latitude: 0, longitude: 0)
        timeZone = city?.timeZone ?? homeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        equinoxMidnight = cal.date(from: DateComponents(year: 2026, month: 3, day: 20)) ?? equinoxMidnight
        quickDays = nil
    }

    func localHour(_ t: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: t)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + (Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9) / 3600
    }

    mutating func read(now: Date, dt: Double, settings s: SkySettings) -> Reading {
        if s.timeMode != mode { mode = s.timeMode; quickDays = nil }
        switch s.timeMode {
        case .realTime:
            return Reading(instant: now, moonPhase: Lunar.phaseAngle(at: now) / 360, virtualMoon: false, hourOfDay: localHour(now),
                           day: LivingSky.localDay(now, zone: timeZone), calendar: now)
        case .frozen:
            let t = equinoxMidnight.addingTimeInterval(s.frozenHour * 3600)
            let today = LivingSky.localDay(now, zone: timeZone)
            return Reading(instant: t, moonPhase: s.frozenPhase, virtualMoon: true, hourOfDay: s.frozenHour,
                           day: today, calendar: Self.calendar(day: today, hour: s.frozenHour, zone: timeZone))
        case .quick:
            if quickDays == nil {
                let start = localHour(now) / 24
                quickDays = start; quickStart = start
                quickPhase0 = Lunar.phaseAngle(at: now) / 360
                quickBaseDay = LivingSky.localDay(now, zone: timeZone)
            }
            quickDays! += dt / (min(60, max(2, s.dayMinutes)) * 60)
            let fraction = quickDays! - floor(quickDays!)
            var phase = (quickPhase0 + (quickDays! - quickStart) / 8).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            let day = quickBaseDay + Int(floor(quickDays!))
            return Reading(instant: equinoxMidnight.addingTimeInterval(fraction * 86_400), moonPhase: phase, virtualMoon: true,
                           hourOfDay: fraction * 24, day: day, calendar: Self.calendar(day: day, hour: fraction * 24, zone: timeZone))
        }
    }

    /// The UT instant of local day `day` (days since 1970 on the zone's calendar) at local `hour`.
    static func calendar(day: Int, hour: Double, zone: TimeZone) -> Date {
        let local = Double(day) * 86_400 + hour * 3600
        let offset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: local)))
        return Date(timeIntervalSince1970: local - offset)
    }

    /// A moon on the ecliptic `phase` of a cycle ahead of the sun: rises at sunset when full, trails the sun as a crescent.
    func virtualMoon(at t: Date, phase: Double) -> SkyDirection {
        let T = Astro.centuries(t)
        let lam = Astro.rad(Solar.core(t).longitude + 360 * phase), eps = Astro.rad(Lunar.obliquity(T))
        let ra = Astro.norm(Astro.deg(atan2(sin(lam) * cos(eps), cos(lam))))
        let dec = Astro.deg(asin(sin(eps) * sin(lam)))
        let ha = Sidereal.localSiderealDegrees(at: t, longitude: location.longitude) - ra
        let h = Astro.horizontal(hourAngle: ha, declination: dec, latitude: location.latitude)
        var alt = h.alt - 0.95 * cos(Astro.rad(h.alt))   // parallax
        alt += Astro.refraction(alt)
        return SkyDirection(azimuth: h.az, altitude: alt)
    }
}
