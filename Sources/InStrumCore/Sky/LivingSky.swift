import Foundation

/// Everything a world needs to draw and hear its sky this frame.
public struct SkyState: Equatable {
    public var sun = SkyDirection(azimuth: 0, altitude: -30)
    public var moon = SkyDirection(azimuth: 0, altitude: -30)
    /// 0…1: 0 new, 0.5 full.
    public var moonPhase = 0.0
    /// Lit fraction of the disc, 0…1.
    public var moonLit = 0.0
    /// Local sidereal time (degrees) and latitude, for turning the stars.
    public var siderealDegrees = 0.0
    public var latitude = 0.0
    /// Sky colours (linear RGB, 0…1).
    public var zenith = SIMD3<Float>(repeating: 0), horizon = SIMD3<Float>(repeating: 0)
    public var starVisibility: Float = 0
    public var weather = WeatherKind.clear
    /// 0…1 toward `nextWeather` while a change is under way (0 when steady).
    public var weatherBlend: Float = 0
    public var nextWeather = WeatherKind.clear
    public var cloudCover: Float = 0, rain: Float = 0, snow: Float = 0, mist: Float = 0, wind: Float = 0
    /// 0…1: a lightning flash request (storms), fading in a fraction of a second.
    public var lightning: Float = 0
    /// Local hour at the sky's city (0…<24).
    public var hourOfDay = 0.0
    public var subsolar = GeoPoint(latitude: 0, longitude: 0)
    /// Ice halos and sundogs, 0…1 (light cloud above all).
    public var halo: Float = 0
    /// Frost on glass, 0…1 (snow and blizzards any time; clear and cloudy skies only at night; rain melts it).
    public var frost: Float = 0
    /// How wet the world is, 0…1: rises in rain, dries over minutes, held at 0.85 after the rain.
    public var wetness: Float = 0
    /// The live gust, 0…1: the weather's gustiness times an envelope that comes every 3–8 s.
    public var gust: Float = 0
    /// 0…1: how pastel this dawn is (about one morning in three, gliding in and out).
    public var dawnPastel: Float = 0
    /// How big the moon and sun look, 1 = as designed (the Advanced settings).
    public var moonSize: Float = 1, sunSize: Float = 1
    /// The dark part of the moon's faint glow, 0…0.3.
    public var earthshine: Float = 0.04
    /// 0…1: how clearly a rainbow stands opposite the sun (sun-showers, and after the rain, with the sun 1°–42° up).
    public var rainbow: Float = 0
    /// The aurora tonight, 0…1 (0 by day); the band's base above the pole-ward horizon (degrees); the substorm phase 0…1.
    public var aurora: Float = 0, auroraAltitude: Float = 0, auroraStorm: Float = 0
    /// The world's aurora is "Always": shown for the show, not the real one, so the sky stands it wherever the world
    /// looks (in Follow the sky it keeps to the pole).
    public var auroraAlways = false
    /// Fireflies (a humid night's, times darkness), 0…1.
    public var fireflies: Float = 0
    /// Diamond dust's glittering crystals, and the light pillars it throws (only with the sun low, or at night), 0…1.
    public var diamondDust: Float = 0, pillar: Float = 0
    /// How strongly the constellation lines are drawn (the Advanced setting), 0…1.
    public var constellationLines: Float = 0
    /// +1 in the northern hemisphere, −1 in the southern (which way the pole, and the aurora, lie).
    public var hemisphere: Float = 1
    /// The day of the year on the sky city's own calendar, 1…366: today's in real time and frozen modes, a new day
    /// with every cycle in quick mode (it drives the seasons).
    public var dayOfYear = 1
    /// Iridescent cloud, 0…1: pastel bands on thin cloud (cover 0.15–0.6) with the sun 5°–50° up; each light-cloud
    /// spell has its own (like its ice), scaled by the Advanced setting.
    public var iridescence: Float = 0
    /// How rimed the world is, 0…1: rime frost feathers every edge over 10–20 minutes of freezing fog, melts within
    /// minutes in sun once the fog has gone, and lingers for most of an hour in the dark.
    public var rime: Float = 0
    /// Sea smoke rising off open water, 0…1 (spec §6.4): the weather's steam, after the world's rule (the warm rule
    /// zeroes it). Worlds draw it from their water band; worlds without open water show only its frost haze.
    public var steam: Float = 0
    /// The shooting stars in the sky now (spec §6.2): at most six, heads and trains, in no particular order.
    public var meteors: [Meteor] = []
    /// A fireball's soft sky brightening, 0…0.08: multiply the sky by 1 + meteorFlash. Only fireballs (magnitude −4 or
    /// brighter) set it, and it has passed the sky's own `FlashLimiter` with the lightning's rules.
    public var meteorFlash: Float = 0
    /// The strongest shower in the sky right now (spec §6.2), or nil: none active, or the world's meteors are "Never".
    public var shower: ShowerNow?
    /// Meteors expected per hour of viewing over the whole sky right now, the Advanced "Meteors" setting included: the
    /// arrivals, of which those that would start below 5° are then dropped (about a quarter with a radiant high up).
    public var meteorRate: Float = 0
    /// The meteors' clock: seconds of viewing since the sky began. `Meteor.born` is on it, so `progress(at:)` and
    /// `headBrightness(at:)` take it.
    public var meteorTime: Double = 0
    /// The Sun's ecliptic longitude λ⊙ on the sky's calendar (degrees, J2000; spec §6.3): it walks a day with each
    /// quick-mode cycle and keeps today's date when frozen.
    public var solarLongitude: Double = 0
    /// The instant (UT) the sky's calendar shows: now in real time; in quick and frozen modes the shown day at the shown
    /// local hour (the meteor calendar's date). The reef's spawning nights are counted on it.
    public var calendar = Date(timeIntervalSince1970: 0)
    /// The moon is the real one at `calendar` (real time), so its full moons can be found with `Lunar`; otherwise it is
    /// placed by `moonPhase` alone (quick and frozen modes, and any sky made by hand).
    public var realMoon = false
    /// Storms (spec §6.1): the anvil crawlers creeping across a storm's cloud base now (at most 4, each up to 16
    /// segments), lit for this instant after the sky's flash limiter. The cloud layer draws them.
    public var crawlers: [CrawlerSlot] = []
    /// Storms (spec §6.2): sheet lightning on the sky's rim now (at most 2), and the nearest cloud cell each one lights.
    public var sheet: [SheetSlot] = []
    /// The storm light's brightening of the scene, 0…0.4: the brighter of the crawlers and the sheet lightning, after the
    /// sky's own `FlashLimiter` (a crawler above 0.25 costs a flash there; the sheet, at most 0.2, never does but is
    /// counted).
    public var stormFlash: Float = 0
    /// A gust front's outflow, the cold air out of the storm, 0…1 (spec §7.1); and where the gust front is (its stage,
    /// its shelf cloud and dust wall), nil without one.
    public var outflow: Float = 0
    public var gustFront: GustFrontNow?
    /// The weather's grade on a world's warmth (added to its post warmth): the gust front's cold drop, 0 … −0.08.
    public var warmthGrade: Float = 0
    /// Virga: streaks of rain hanging under the cloud base that never reach the ground, 0…1 (spec §7.2).
    public var virga: Float = 0
    /// A far storm on the horizon, 0…1 (Fire & Neon spec §6.1): a world's or the far-storm machine's, and every supercell
    /// is one. Sheet lightning and crawlers read it.
    public var farStorm: Float = 0
    /// The supercell over a world that has one (Supercell Sky's own weather), 0 or 1, and its event's phase (0…<1:
    /// Approach to a third, Core to two thirds, Clearing after), mapped from the world's stage picker
    /// (`WorldWeather.supercellStep`). The event's own drawing and weather come with Fire & Neon's Supercell.
    public var supercell: Float = 0
    public var supercellPhase: Float = 0
    /// Fire & Neon (spec §6.1): the far storm the sky has on its horizon on a clear night (nil: none; a world's own far
    /// storm and a supercell are not this one), drawn by the shared sky as a dark anvil flickering from inside; and the red
    /// sprites over a storm now (at most 3), lit for this instant after the sky's flash limiter.
    public var farStormNow: FarStormNow?
    public var sprites: [SpriteSlot] = []
    /// The bearing (degrees) of the storm the sprites stand over, and a number that changes with each new storm, so a
    /// renderer can stage it where its world looks, once (`SkyLayer`).
    public var stormBearing: Float = 0
    public var stormEpisode = 0
    /// Fire & Neon (spec §6.2): the satellites in the sky now (at most 4, the brightest), lit and dark-sky gated.
    public var satellites: [SatelliteSlot] = []
    /// Fire & Neon (spec §7.2): the supercell weather's staged event (nil without it), and its hail falling here (0…1).
    public var supercellWeather: SupercellNow?
    public var hail: Float = 0
    /// Fire & Neon (spec §7.1): ashfall's ash (0…1), and the embers rising through it where the world is their source
    /// (0…1: the ash, at an ember source; 0 everywhere else). The sun's and moon's light through the ash's haze, reddened
    /// and dimmed ((1, 1, 1) without ash): multiply the light a world takes from them by it.
    public var ash: Float = 0
    public var embers: Float = 0
    public var sunTint = SIMD3<Float>(1, 1, 1)
    public var moonTint = SIMD3<Float>(1, 1, 1)

    public init() {}
}

/// What a world and the playing ask of the storm sky this step (Storms spec §6–§8): each Sky extras mode (nil: the
/// settings'), the supercell's stage (nil: no supercell), a big moment (it calls a crawler and a sheet flash), a far
/// storm the world has on its horizon, and the weathers its Random Beautiful adds (`WorldWeather.randomExtras`).
public struct StormInputs: Equatable {
    public var crawlers: SkyExtraMode?
    public var sheet: SkyExtraMode?
    public var supercell: SupercellStage?
    public var moment: BigMoment?
    public var farStorm: Float
    public var randomExtras: [WeatherKind: Float]
    /// Fire & Neon (spec §6): a world's own red sprites and satellites modes (nil: the Sky extras settings), and its sky
    /// flags (`SkyWorldFlags`): a city's skyglow (satellites fainter than this magnitude unseen) and embers in ashfall.
    public var sprites: SkyExtraMode?
    public var satellites: SkyExtraMode?
    public var skyglowLimit: Float?
    public var emberSource: Bool
    /// A world's own call for red sprites this step (a surprise; `SpriteCalling`), 0…1: like a big moment's, it makes
    /// one only where the sprites' rules allow (at night, over a storm).
    public var spriteCall: Float?

    public init(crawlers: SkyExtraMode? = nil, sheet: SkyExtraMode? = nil, supercell: SupercellStage? = nil,
                moment: BigMoment? = nil, farStorm: Float = 0, randomExtras: [WeatherKind: Float] = [:],
                sprites: SkyExtraMode? = nil, satellites: SkyExtraMode? = nil, skyglowLimit: Float? = nil,
                emberSource: Bool = false, spriteCall: Float? = nil) {
        self.crawlers = crawlers; self.sheet = sheet; self.supercell = supercell; self.moment = moment
        self.farStorm = farStorm; self.randomExtras = randomExtras
        self.sprites = sprites; self.satellites = satellites; self.skyglowLimit = skyglowLimit; self.emberSource = emberSource
        self.spriteCall = spriteCall
    }
}

/// The Living Sky: sun, moon, stars, colour and weather for a time mode and a city.
public final class LivingSky {
    public var settings: SkySettings {
        didSet { if settings.cityID != oldValue.cityID { clock.place(cityID: settings.cityID, homeZone: homeZone) } }
    }
    public var location: GeoPoint { clock.location }
    public var timeZone: TimeZone { clock.timeZone }

    private let homeZone: TimeZone
    private let seed: UInt64
    private var clock = SkyClock()
    private var weather: WeatherMachine
    private var rng: SeededRandom
    private var lightning: Float = 0
    private var nextFlash = 3.0
    private var wetness: Float = 0
    private var gustRng: SeededRandom
    private var gustAge = 10.0, nextGust = 4.0
    private var dawnPastel: Float = 0
    private var auroraMachine: AuroraMachine
    private var rime: Float = 0
    /// The meteor calendar's machine, on its own stream (internal so tests can reach its tally and its
    /// `forceMagnitude` seam), and the sky's own flash limiter for its fireballs and its storm light (internal so tests
    /// can read what it counted).
    var meteorSky: MeteorSky
    private(set) var flashLimiter = FlashLimiter()
    /// Storms: the anvil crawlers and the sheet lightning, each on its own stream (internal for their seams and tallies);
    /// the gust front's clock and seeded details; the supercell's phase.
    var crawlerSky: AnvilCrawlers
    var sheetSky: SheetLightning
    private var frontRng: SeededRandom
    private var gustOn = false
    private var gustElapsed = 0.0
    private var gustCross = 15.0, gustHeight: Float = 11, gustBearing: Float = 0
    private var supercellOn = false
    private var supercellPhase = 0.0
    /// Fire & Neon: the far storms, the red sprites and the satellites, each on its own streams (internal for their seams
    /// and tallies).
    var farStorms: FarStorms
    var spriteSky: RedSprites
    var satelliteSky: Satellites
    /// Fire & Neon: the supercell weather's event (its clock, bearing, turn and flicker).
    private var cellOn = false
    private var cellElapsed = 0.0
    private var cellBearing = 0.0
    private var cellEpisode = 0
    private var cellTurn = 0.0
    private var cellRng: SeededRandom
    private var cellFlicker: StormFlicker
    /// The weathers the current world's Random Beautiful adds (the last step's storm inputs), for tests.
    var randomExtras: [WeatherKind: Float] { weather.extras }

    public init(settings: SkySettings, seed: UInt64 = 1, homeZone: TimeZone = .current) {
        self.settings = settings
        self.homeZone = homeZone
        self.seed = seed
        weather = WeatherMachine(settings: settings, seed: seed)
        rng = SeededRandom(seed: seed &+ 0x11_9E37)
        gustRng = SeededRandom(seed: seed &+ 0x6057)
        auroraMachine = AuroraMachine(seed: seed &+ 0xA0_7A)
        meteorSky = MeteorSky(seed: seed &+ 0x3E7E_0125)
        crawlerSky = AnvilCrawlers(seed: seed &+ 0xC2A3_71E5)
        sheetSky = SheetLightning(seed: seed &+ 0x5EE7_11E7)
        frontRng = SeededRandom(seed: seed &+ 0x6F00_7F2E)
        farStorms = FarStorms(seed: seed &+ 0xFA25_7012)
        spriteSky = RedSprites(seed: seed &+ 0x5B21_7E5D)
        satelliteSky = Satellites(seed: seed &+ 0x5A7E_1175)
        cellRng = SeededRandom(seed: seed &+ 0xCE11_5C0F)
        cellFlicker = StormFlicker(seed: seed &+ 0xCE11_F11C)
        clock.place(cityID: settings.cityID, homeZone: homeZone)
        nextGust = Double(gustRng.range(3, 8))
    }

    /// Starts over with these settings: the weather begins settled instead of blending from the old one
    /// (launch and previews; setting `settings` later blends as usual).
    public func reset(settings: SkySettings) {
        self.settings = settings
        weather = WeatherMachine(settings: settings, seed: seed)
        lightning = 0
        nextFlash = 3
        wetness = 0
        dawnPastel = 0
        gustRng = SeededRandom(seed: seed &+ 0x6057)
        gustAge = 10
        nextGust = Double(gustRng.range(3, 8))
        auroraMachine = AuroraMachine(seed: seed &+ 0xA0_7A)
        rime = 0
        meteorSky = MeteorSky(seed: seed &+ 0x3E7E_0125)
        flashLimiter = FlashLimiter()
        crawlerSky = AnvilCrawlers(seed: seed &+ 0xC2A3_71E5)
        sheetSky = SheetLightning(seed: seed &+ 0x5EE7_11E7)
        frontRng = SeededRandom(seed: seed &+ 0x6F00_7F2E)
        farStorms = FarStorms(seed: seed &+ 0xFA25_7012)
        spriteSky = RedSprites(seed: seed &+ 0x5B21_7E5D)
        satelliteSky = Satellites(seed: seed &+ 0x5A7E_1175)
        cellRng = SeededRandom(seed: seed &+ 0xCE11_5C0F)
        cellFlicker = StormFlicker(seed: seed &+ 0xCE11_F11C)
        gustOn = false
        gustElapsed = 0
        supercellOn = false
        supercellPhase = 0
        cellOn = false
        cellElapsed = 0
        cellTurn = 0
    }

    /// `hold` keeps the sun at a chosen altitude for worlds that hold the light; everything else keeps running.
    /// `aurora` and `meteors` are the world's aurora and meteor modes for this step (world parameters, so they never
    /// outlive the world); `storm` is what the world and the playing ask of the storm sky (Storms spec §6–§8).
    public func step(now: Date, dt rawDt: Double, hold: SkyHold = .follow, aurora mode: AuroraMode = .follow,
                     meteors meteorMode: MeteorMode = .follow, storm inputs: StormInputs = StormInputs()) -> SkyState {
        let dt = min(1, max(0, rawDt))
        let reading = clock.read(now: now, dt: dt, settings: settings)
        var s = SkyState()
        let t = reading.instant
        s.sun = Solar.direction(at: t, from: clock.location)
        if let altitude = hold.altitude { s.sun.altitude = altitude }
        s.moonPhase = reading.moonPhase
        s.calendar = reading.calendar
        s.realMoon = !reading.virtualMoon
        if reading.virtualMoon {
            s.moon = clock.virtualMoon(at: t, phase: reading.moonPhase)
            s.moonLit = (1 - cos(2 * .pi * reading.moonPhase)) / 2
        } else {
            s.moon = Lunar.direction(at: t, from: clock.location)
            s.moonLit = Lunar.illuminatedFraction(at: t)
        }
        s.siderealDegrees = Sidereal.localSiderealDegrees(at: t, longitude: clock.location.longitude)
        s.latitude = clock.location.latitude
        s.hourOfDay = reading.hourOfDay
        s.dayOfYear = Self.dayOfYear(localDay: reading.day)
        s.subsolar = Solar.subsolarPoint(at: t)

        weather.extras = inputs.randomExtras
        weather.step(dt: dt, settings: settings)
        var w = weather.values
        // A gust front plays its stages (spec §7.1) from the moment it starts arriving: its staged weather stands in for
        // its nominal values by its share of the sky, and its clock runs on (holding the Rain) until it has gone. Each
        // one draws its dust wall's crossing, its height and the storm's bearing from its own stream.
        let front = weather.weight(of: .gustFront)
        if front > 0 {
            if !gustOn {
                gustOn = true
                gustElapsed = 0
                gustCross = 10 + 10 * AnvilCrawlers.unit(&frontRng)
                gustHeight = Float(8 + 7 * AnvilCrawlers.unit(&frontRng))
                gustBearing = Float(360 * AnvilCrawlers.unit(&frontRng))
            }
            gustElapsed += dt
            let g = WorldWeather.gustFront(elapsed: gustElapsed, duration: settings.gustFrontSeconds, cross: gustCross,
                                           dustHeight: gustHeight, bearing: gustBearing, amount: front)
            let n = WeatherKind.gustFront.values
            w.cloud += front * (g.cloud - n.cloud)
            w.rain += front * (g.rain - n.rain)
            w.mist += front * (g.mist - n.mist)
            w.wind += front * (g.wind - n.wind)
            w.gust += front * (g.gust - n.gust)
            w.outflow += front * (g.outflow - n.outflow)
            s.gustFront = g
            s.warmthGrade = front * g.warmth
        } else {
            gustOn = false
        }
        // The supercell weather (Fire & Neon spec §7.2) plays its stages from the moment it starts arriving, standing in for
        // its nominal values by its share of the sky: picked, it runs once and holds its Clearing; in Random Beautiful it
        // runs to its end (its spell is its length) and moves on. Each one draws its bearing from its own stream.
        let cellAmount = weather.weight(of: .supercell)
        var cellNow: SupercellNow?
        if cellAmount > 0 {
            if !cellOn {
                cellOn = true
                cellElapsed = 0
                cellBearing = 360 * AnvilCrawlers.unit(&cellRng)
                cellEpisode += 1
            }
            cellElapsed += dt
            let length = WeatherMachine.supercellSpell(settings)
            let hold = settings.weatherMode == .pick ? WorldWeather.supercellHeld : 1
            var c = WorldWeather.supercell(phase: min(hold, cellElapsed / length))
            let spin: Double = clock.location.latitude >= 0 ? 1 : -1   // anticlockwise from above in the north
            cellTurn = (cellTurn + spin * dt * 2 * .pi * Double(SupercellNow.rpm) / 60 * Double(c.rotation))
                .truncatingRemainder(dividingBy: 2 * .pi)
            c.amount = cellAmount
            c.bearing = Float(cellBearing)
            c.episode = cellEpisode
            c.turn = Float(cellTurn)
            let n = WeatherKind.supercell.values
            w.cloud += cellAmount * (c.cloud - n.cloud)
            w.rain += cellAmount * (c.rain - n.rain)
            w.mist += cellAmount * (c.mist - n.mist)
            w.wind += cellAmount * (c.wind - n.wind)
            w.gust += cellAmount * (c.gust - n.gust)
            cellNow = c
        } else {
            cellOn = false
        }
        s.hail = min(1, max(0, (cellNow?.hail ?? 0) * cellAmount))
        // Ashfall (spec §7.1): the ash, the embers at an ember source, the sun and moon reddened through it.
        s.ash = min(1, max(0, w.ash.isFinite ? w.ash : 0))
        s.embers = inputs.emberSource ? s.ash : 0
        s.outflow = min(1, max(0, w.outflow))
        s.virga = min(1, max(0, w.virga))
        s.weather = weather.current
        s.nextWeather = weather.transitioning ? weather.next : weather.current
        s.weatherBlend = weather.transitioning ? Float(weather.blend) : 0
        s.cloudCover = w.cloud; s.rain = w.rain; s.snow = w.snow; s.mist = w.mist; s.wind = w.wind
        s.steam = w.steam

        // Gusts: one every 3–8 s while the weather is gusty (a 0.5 s rise and a 1.5 s fall).
        if w.gust > 0 {
            nextGust -= dt
            if nextGust <= 0 { gustAge = 0; nextGust = max(0.5, nextGust + Double(gustRng.range(3, 8))) }
        }
        gustAge += dt
        s.gust = w.gust * Self.gustEnvelope(gustAge)
        if w.snow >= 0.9 { s.mist = min(1, w.mist + 0.3 * s.gust) }   // a blizzard whites out with each gust

        // Frost: night-only for clear and cloudy skies, any time for snow; rain melts it within seconds.
        let darkness = 1 - SkyPalette.smoothstep(-12, -2, Float(s.sun.altitude))
        var frost: Float = 0
        for k in Set([weather.current, weather.next]) {
            frost += weather.weight(of: k) * k.values.frost * (k.frostFormsOnlyAtNight ? darkness : 1)
        }
        s.frost = frost * (1 - SkyPalette.smoothstep(0, 0.05, w.rain))
        s.halo = Self.halo(weather)
        s.rainbow = Self.rainbow(weather, sunAltitude: s.sun.altitude) * Float(min(1, max(0, settings.rainbowStrength)))

        // Wetness: rain soaks (faster the harder it rains), dry weather dries it over minutes; after the rain stays wet.
        if w.rain > 0.1 { wetness += (1 - wetness) * Float(1 - exp(-dt * Double(w.rain) / 90)) }
        else { wetness *= Float(exp(-dt / (min(60, max(2, settings.dryingMinutes)) * 60))) }
        wetness = max(wetness, 0.85 * weather.weight(of: .afterRain))
        s.wetness = wetness

        // Rime: freezing fog feathers the world white over 10–20 minutes; once the fog has gone the sun melts it within
        // minutes, the dark only slowly.
        rime = Self.rimeStep(rime, fog: w.rime, sunAltitude: s.sun.altitude, speed: settings.rimeSpeed, dt: dt)
        s.rime = rime

        // Pastel dawns: about one morning in three, chosen by the local date and the city.
        if hold.forcesPastel {
            dawnPastel = 1
        } else {
            let target: Float = reading.hourOfDay < 12 && Self.dawnIsPastel(day: reading.day, cityID: settings.cityID) ? 1 : 0
            dawnPastel += (target - dawnPastel) * Float(1 - exp(-dt / 20))
        }
        s.dawnPastel = dawnPastel

        // Lightning: a flash every 6–20 s while the storm holds.
        let storm = stormAmount()
        // A supercell's Core flashes too, and more often (every 3–10 s): its lightning is staged.
        let cellStorm = (cellNow?.amount ?? 0) * (cellNow?.lightning ?? 0)
        if storm > 0.5 || cellStorm > 0.5 {
            nextFlash -= dt
            if nextFlash <= 0 {
                lightning = 1
                let gap = storm > 0.5 ? Double(rng.range(6, 20)) : Double(rng.range(3, 10))
                nextFlash = gap / min(3, max(0.25, settings.lightningFrequency))
            }
        } else {
            nextFlash = Double(rng.range(2, 8))
        }
        s.lightning = lightning
        lightning *= Float(exp(-dt / 0.12))
        // Its in-cloud light: the distant flicker while it approaches or goes, and its own close flashes in its Core.
        if var c = cellNow {
            let distant = c.stage != .core
            let gaps = c.stage == .approach ? 2.0...6.0 : 4.0...10.0
            let flicker = cellFlicker.step(dt: dt, gaps: gaps, active: distant) * (c.stage == .clearing ? 1 - c.stageProgress : 1)
            c.glow = min(1, max(flicker * (distant ? 0.8 : 0), s.lightning * c.lightning))
            c.spot = cellFlicker.spot
            cellNow = c
        } else {
            _ = cellFlicker.step(dt: dt, gaps: 2.0...6.0, active: false)
        }
        s.supercellWeather = cellNow

        let moonUp = Float(max(0, sin(Astro.rad(s.moon.altitude)))) * Float(s.moonLit)
        let colours = SkyPalette.colours(sunAltitude: s.sun.altitude, cloud: w.cloud, mist: w.mist, moonlight: moonUp, pastel: dawnPastel)
        let ashed = WorldWeather.ashSky(zenith: colours.zenith, horizon: colours.horizon, ash: s.ash)
        s.zenith = ashed.zenith; s.horizon = ashed.horizon
        s.sunTint = WorldWeather.ashTint(ash: s.ash, altitude: s.sun.altitude)
        s.moonTint = WorldWeather.ashTint(ash: s.ash, altitude: s.moon.altitude)
        let night = 1 - SkyPalette.smoothstep(-15, -4, Float(s.sun.altitude))
        s.starVisibility = night * (1 - 0.9 * w.cloud) * (1 - 0.6 * w.mist) * (1 - 0.3 * moonUp) * (1 - 0.5 * s.ash)
        // Advanced scales (1 = as designed).
        // The value is capped at `hi`; the scale itself may go above 1 (the looks boost up to 1.5, the sliders to 2).
        func scaled(_ v: Float, _ k: Double, _ hi: Double) -> Float { min(Float(hi), v * Float(min(4, max(0, k)))) }
        s.wind = scaled(s.wind, settings.windScale, 1)
        s.mist = scaled(s.mist, settings.mistScale, 1)
        s.halo = scaled(s.halo, settings.haloScale, 1)
        s.frost = scaled(s.frost, settings.frostScale, 1)
        s.rain = scaled(s.rain, settings.rainScale, 1)
        s.snow = scaled(s.snow, settings.snowScale, 1)
        s.gust = scaled(s.gust, settings.gustScale, 1)
        s.cloudCover = scaled(s.cloudCover, settings.cloudScale, 1)
        s.moonSize = Float(min(3, max(0.5, settings.moonSize))); s.sunSize = Float(min(3, max(0.5, settings.sunSize)))
        s.earthshine = Float(min(0.3, max(0, settings.earthshine)))
        s.starVisibility = scaled(s.starVisibility, settings.starScale, 1)
        s.iridescence = Self.iridescence(weather, cloudCover: s.cloudCover, sunAltitude: s.sun.altitude, setting: settings.iridescence)

        // The aurora: the machine's activity at this latitude, only in the dark, behind cloud and mist.
        let sunAlt = Float(s.sun.altitude)
        let a = auroraMachine.step(dt: dt, mode: mode, latitude: s.latitude)
        let auroraNight = 1 - SkyPalette.smoothstep(-10, -6, sunAlt)
        let auroraScale: Float = mode == .follow ? Float(min(2, max(0, settings.auroraScale))) : 1
        s.aurora = min(1, a.visible * auroraNight * (1 - 0.9 * w.cloud) * (1 - 0.6 * w.mist) * auroraScale)
        s.auroraAltitude = a.altitude
        s.auroraStorm = a.storm
        s.auroraAlways = mode == .always
        s.hemisphere = s.latitude >= 0 ? 1 : -1
        // Fireflies need the dark; diamond dust glitters any time, its pillars only with a low sun (or the moon by night).
        s.fireflies = w.fireflies * (1 - SkyPalette.smoothstep(-8, -2, sunAlt))
        s.diamondDust = w.pillar
        s.pillar = w.pillar * (1 - SkyPalette.smoothstep(10, 12, sunAlt))
        s.constellationLines = Float(min(1, max(0, settings.constellationLines)))

        // Meteors (spec §6.3): the calendar runs on the sky's own date (UT solar longitude), the sporadic meteors on
        // the local solar hour, and every rate per second of viewing; a fireball's brightening passes the sky's own
        // flash limiter as the exposure it causes (1 + flash), the lightning's rules.
        let solarHour = Solar.apparentSolarHour(at: t, longitude: clock.location.longitude)
        let m = meteorSky.step(dt: dt, date: reading.calendar, sky: s, mode: meteorMode, rate: settings.meteorRate,
                               solarHour: solarHour)
        s.meteors = m.meteors
        s.shower = m.shower
        s.meteorRate = m.perHour
        s.meteorTime = meteorSky.time
        s.solarLongitude = meteorSky.lambda

        // Storms (spec §6, §8.1): the supercell's phase from the world's picker; the storms on and over the horizon; the
        // anvil crawlers (under a storm's anvil with cloud 0.7 or more; a supercell's anvil is always there) and the
        // sheet lightning (dusk or night, with a far storm or a dry one in this sky), a big moment calling one of each.
        if let stage = inputs.supercell {
            if supercellOn { supercellPhase = WorldWeather.supercellStep(supercellPhase, stage: stage, dt: dt) }
            else { supercellOn = true; supercellPhase = WorldWeather.supercellPhase(held: stage) ?? 0 }
            s.supercell = 1
            let phase = Float(supercellPhase)
            s.supercellPhase = phase < 1 ? phase : 0   // a hair short of 1 rounds to it in a Float: that is the wrap
        } else {
            supercellOn = false
            supercellPhase = 0
            if let c = cellNow {
                s.supercell = c.amount
                s.supercellPhase = min(c.phase, 0.9999)   // its end is still its Clearing, not the next one's Approach
            }
        }
        var far = max(inputs.farStorm.isFinite ? min(1, max(0, inputs.farStorm)) : 0, s.supercell)
        // Fire & Neon (spec §6.1): a clear night may have a far storm of its own (unless the world or a supercell already
        // stands one on the horizon); it is a far storm like any other.
        let clearNight = s.sun.altitude < FarStorms.darkBelow && w.cloud < FarStorms.clearCloud && w.rain < 0.05 && w.snow < 0.05
            && far < 0.5
        let spritesMode = inputs.sprites ?? settings.spritesMode
        let farNow = farStorms.step(dt: dt, mode: spritesMode, eligible: clearNight)
        s.farStormNow = farNow
        far = max(far, farNow?.amount ?? 0)
        s.farStorm = far
        let anvil = weather.weight(of: .thunderheads) + weather.weight(of: .storm) + weather.weight(of: .gustFront) + far
        let base = s.supercell > 0 ? max(s.cloudCover, 0.85) : s.cloudCover
        let core = s.supercell > 0 && SupercellStage.event(at: s.supercellPhase) == .core
        let call = inputs.moment.map { $0.strength }
        let bearing = s.gustFront.map { Double($0.bearing) }
        let crawlers = crawlerSky.step(dt: dt, mode: inputs.crawlers ?? settings.crawlersMode,
                                       eligible: anvil >= 0.5 && base >= 0.7, core: core, bearing: bearing, call: call)
        let dry = weather.weight(of: .thunderheads) + weather.weight(of: .dryLightning) + weather.weight(of: .virga)
        let dusk = s.sun.altitude < SheetLightning.darkBelow
        let sheets = sheetSky.step(dt: dt, mode: inputs.sheet ?? settings.sheetMode, eligible: dusk && (far >= 0.5 || dry >= 0.5),
                                   cloud: s.cloudCover, bearing: bearing ?? farNow.map { Double($0.bearing) }, call: call)

        // Red sprites (spec §6.1): at night over a storm (this sky's, or a far one), standing over the far storm's bearing
        // when it has one; the satellites (spec §6.2), lit by the sun from below the horizon.
        let stormy = weather.weight(of: .storm) + weather.weight(of: .thunderheads) + weather.weight(of: .dryLightning) + far
        let spriteNight = s.sun.altitude < RedSprites.darkBelow
        let spriteBearing = farNow.map { Double($0.bearing) }
        // A world's own call (a surprise) counts as a big moment's does, the stronger of the two.
        let worldCall = inputs.spriteCall.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        let spriteCall = [call, worldCall].compactMap { $0 }.max()
        let sprites = spriteSky.step(dt: dt, mode: spritesMode, eligible: spriteNight && stormy >= 0.5, bearing: spriteBearing,
                                     call: spriteCall)
        if let f = farNow {
            s.stormBearing = f.bearing
            s.stormEpisode = f.episode
        } else {
            s.stormBearing = Float(spriteSky.bearing)
            s.stormEpisode = 100_000 + spriteSky.episode
        }
        let sats = satelliteSky.step(dt: dt, sun: AnvilCrawlers.enu(s.sun.azimuth, s.sun.altitude), latitude: s.latitude,
                                     mode: inputs.satellites ?? settings.satellitesMode, skyglow: inputs.skyglowLimit, call: call)

        // The sky's own flash limiter takes the fireballs' brightening and the storm light together (the brighter of the
        // crawlers and the sheet: a crawler above 0.25 costs a flash, the sheet never can), and whatever it holds back
        // it holds back from each of them alike.
        // Fire & Neon's lights ride with them: the sprites (at most 0.04), the far storm's flicker (at most 0.02) and a
        // satellite's flare (a point: 0.01 at Venus's brightness). None is a flash, but the limiter counts them all.
        let light = max(crawlers.reduce(Float(0)) { max($0, $1.brightness) }, sheets.reduce(Float(0)) { max($0, $1.brightness) })
        let spriteLight = sprites.reduce(Float(0)) { max($0, $1.brightness) }
        let flickerLight = (farNow?.flicker ?? 0) * FarStormNow.flickerLight
        let flareLight = sats.reduce(Float(0)) { max($0, 0.01 * $1.flare) }
        let extra = spriteLight + flickerLight + flareLight
        let exposure = flashLimiter.limit(exposure: 1 + m.flash + light + extra, sparkle: 0, dt: dt).exposure
        if light + extra > 0 {
            let asked = m.flash + light + extra
            let share = min(1, min(asked, max(0, exposure - 1)) / asked)
            s.meteorFlash = min(MeteorSky.maxFlash, max(0, m.flash * share))
            s.stormFlash = light * share
            s.crawlers = crawlers.map { c -> CrawlerSlot in var c = c; c.brightness *= share; return c }
            s.sheet = sheets.map { f -> SheetSlot in var f = f; f.brightness *= share; return f }
            s.sprites = sprites.map { p -> SpriteSlot in var p = p; p.brightness *= share; return p }
            if var f = farNow { f.flicker *= share; s.farStormNow = f }
        } else {
            s.meteorFlash = min(MeteorSky.maxFlash, max(0, exposure - 1))
            s.crawlers = crawlers
            s.sheet = sheets
            s.sprites = sprites
        }
        s.satellites = sats
        return s
    }

    /// Halo strength: the weather's halo, with each light-cloud spell's own ice standing in for light cloud's 0.7
    /// (0.5–1 in "Random, beautiful", so icy spells pass 0.7 and show the 46° ring; 0.7 when picked).
    static func halo(_ m: WeatherMachine) -> Float {
        let light = m.weight(of: .lightCloud)
        return max(0, m.values.halo + light * (m.ice - WeatherKind.lightCloud.values.halo))
    }

    /// Iridescent cloud (spec §6.3): each light-cloud spell's own iridescence (0.3–1 one spell in two in "Random,
    /// beautiful", 0.6 when picked) at light cloud's weight, only where the cloud is thin (cover 0.15–0.6) and the
    /// sun 5°–50° up, easing in over the last stretch of each edge, × the Advanced setting (0…1.5), at most 1.
    static func iridescence(_ m: WeatherMachine, cloudCover c: Float, sunAltitude alt: Double, setting: Double) -> Float {
        let a = Float(alt)
        let thin = SkyPalette.smoothstep(0.15, 0.2, c) * (1 - SkyPalette.smoothstep(0.55, 0.6, c))
        let sunWindow = SkyPalette.smoothstep(5, 8, a) * (1 - SkyPalette.smoothstep(45, 50, a))
        let k = Float(min(1.5, max(0, setting)))
        return min(1, max(0, m.weight(of: .lightCloud) * m.iridescence * thin * sunWindow * k))
    }

    /// One step of rime (spec §6.2): it builds toward 1 at the weather's rime weight (τ 12 min) and, as the fog
    /// leaves, melts toward 0 (τ 6 min with the sun above 2°, τ 40 min below); the Advanced "Rime speed" (0.25…4)
    /// divides both. Solved exactly over the step, so it stays in 0…1 whatever the step.
    static func rimeStep(_ r: Float, fog rawFog: Float, sunAltitude: Double, speed rawSpeed: Double, dt: Double) -> Float {
        let fog = rawFog.isFinite ? min(1, max(0, rawFog)) : 0
        let speed = Float(min(4, max(0.25, rawSpeed)))
        let build = speed * fog / 720
        let melt = speed * (1 - fog) / (sunAltitude > 2 ? 360 : 2400)
        let k = build + melt
        let now = r.isFinite ? min(1, max(0, r)) : 0
        guard k > 0, dt > 0 else { return now }
        let target = build / k
        return min(1, max(0, target + (now - target) * Float(exp(-dt * Double(k)))))
    }

    /// A rainbow needs sun and rain-light together: sun-showers full, "after the rain" three-quarters, and only
    /// with the sun between about 1° and 42° up (the bow sits 42° from the antisolar point).
    static func rainbow(_ m: WeatherMachine, sunAltitude alt: Double) -> Float {
        let amount = min(1, m.weight(of: .sunShower) + 0.75 * m.weight(of: .afterRain))
        let a = Float(alt)
        return amount * SkyPalette.smoothstep(1, 6, a) * (1 - SkyPalette.smoothstep(32, 42, a))
    }

    static func gustEnvelope(_ age: Double) -> Float {
        if age < 0.5 { let x = Float(age / 0.5); return x * x * (3 - 2 * x) }
        if age < 2 { let x = Float((age - 0.5) / 1.5); return 1 - x * x * (3 - 2 * x) }
        return 0
    }

    /// Whether this local day's dawn is pastel at this city (about one in three, the same every time).
    public static func dawnIsPastel(day: Int, cityID: String?) -> Bool {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a: stable across launches, unlike Hasher
        for b in (cityID ?? "home").utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        var r = SeededRandom(seed: (UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15) ^ h)
        return r.next() % 3 == 0
    }

    /// Days since 1970-01-01 on the local calendar of `zone`.
    static func localDay(_ instant: Date, zone: TimeZone) -> Int {
        Int(floor((instant.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: instant))) / 86_400))
    }

    /// The day of the year (1 on 1 January … 365, or 366 in a leap year) of a local day counted from 1970-01-01, on
    /// the proleptic Gregorian calendar (Howard Hinnant's days-to-civil, which needs no Calendar per frame).
    static func dayOfYear(localDay: Int) -> Int {
        let z = localDay + 719_468                        // days since 0000-03-01
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                       // day of the 400-year era, 0…146096
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let year = yoe + era * 400                        // the year this March-to-February year starts in
        let fromMarch = doe - (365 * yoe + yoe / 4 - yoe / 100)
        if fromMarch >= 306 { return fromMarch - 305 }    // January and February belong to the next year
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return fromMarch + 60 + (leap ? 1 : 0)
    }

    private func stormAmount() -> Float {
        let t = Float(weather.blend), b = t * t * (3 - 2 * t)
        if weather.transitioning {
            return (weather.current.flashes ? 1 - b : 0) + (weather.next.flashes ? b : 0)
        }
        return weather.current.flashes ? 1 : 0
    }
}

/// A world can hold the light at a favourite moment: only the sun's altitude is held (its direction, the moon,
/// the clock and the weather keep running), and the Living Sky settings are never changed.
public enum SkyHold: String, CaseIterable, Codable {
    case follow = "Follow the sky", goldenHour = "Golden hour", blueHour = "Blue hour", pastelDawn = "Pastel dawn", deepNight = "Deep night"

    /// The held sun altitude in degrees, or nil to follow the sky.
    public var altitude: Double? {
        switch self {
        case .follow: return nil
        case .goldenHour: return 5
        case .blueHour: return -6
        case .pastelDawn: return 1.5
        case .deepNight: return -30
        }
    }

    /// Pastel dawn also makes the dawn pastel, whatever the day.
    public var forcesPastel: Bool { self == .pastelDawn }

    /// The world parameter that chooses it.
    public static func spec(default d: SkyHold) -> ParamSpec {
        ParamSpec(id: "light.hold", name: "Hold the light", group: "Light",
                  help: "Keep the world at golden hour, blue hour, a pastel dawn or deep night, or follow the Living Sky",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }
}

/// Sky colours keyed to the sun's altitude, greyed by cloud and lifted by moonlight.
enum SkyPalette {
    struct Anchor { var altitude: Float; var zenith, horizon: SIMD3<Float> }

    static let anchors: [Anchor] = [
        Anchor(altitude: -18, zenith: [0.010, 0.014, 0.035], horizon: [0.020, 0.028, 0.060]),      // night
        Anchor(altitude: -12, zenith: [0.015, 0.022, 0.065], horizon: [0.040, 0.050, 0.110]),      // astronomical twilight
        Anchor(altitude: -6, zenith: [0.040, 0.060, 0.160], horizon: [0.200, 0.170, 0.260]),       // nautical
        Anchor(altitude: -0.833, zenith: [0.160, 0.240, 0.450], horizon: [0.850, 0.480, 0.300]),   // civil: sunset glow
        Anchor(altitude: 6, zenith: [0.300, 0.480, 0.780], horizon: [0.980, 0.700, 0.420]),        // golden hour
        Anchor(altitude: 20, zenith: [0.260, 0.520, 0.920], horizon: [0.700, 0.840, 0.970]),       // day
    ]

    /// Pastel dawn: a lavender-blue zenith over a peach-pink horizon, for the sun between −10° and +8°.
    static let pastelAnchors: [Anchor] = [
        Anchor(altitude: -10, zenith: [0.10, 0.10, 0.25], horizon: [0.35, 0.25, 0.40]),
        Anchor(altitude: -4, zenith: [0.30, 0.30, 0.55], horizon: [0.85, 0.55, 0.62]),
        Anchor(altitude: -0.833, zenith: [0.46, 0.44, 0.74], horizon: [0.98, 0.66, 0.62]),
        Anchor(altitude: 4, zenith: [0.45, 0.58, 0.85], horizon: [1.0, 0.78, 0.66]),
        Anchor(altitude: 8, zenith: [0.32, 0.52, 0.88], horizon: [0.92, 0.82, 0.74]),
    ]

    /// 1 for the sun between −6° and +4°, easing to 0 at −10° and +8°.
    static func pastelWindow(_ altitude: Float) -> Float {
        smoothstep(-10, -6, altitude) * (1 - smoothstep(4, 8, altitude))
    }

    static func interpolate(_ table: [Anchor], _ alt: Float) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        if alt <= table[0].altitude { return (table[0].zenith, table[0].horizon) }
        for i in 0..<(table.count - 1) where alt < table[i + 1].altitude {
            let s = smoothstep(table[i].altitude, table[i + 1].altitude, alt)
            return (table[i].zenith + (table[i + 1].zenith - table[i].zenith) * s,
                    table[i].horizon + (table[i + 1].horizon - table[i].horizon) * s)
        }
        return (table[table.count - 1].zenith, table[table.count - 1].horizon)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func colours(sunAltitude: Double, cloud: Float, mist: Float, moonlight: Float, pastel: Float = 0) -> (zenith: SIMD3<Float>, horizon: SIMD3<Float>) {
        let alt = Float(sunAltitude)
        var z = anchors[0].zenith, h = anchors[0].horizon
        if alt >= anchors[anchors.count - 1].altitude {
            z = anchors[anchors.count - 1].zenith; h = anchors[anchors.count - 1].horizon
        } else if alt > anchors[0].altitude {
            for i in 0..<(anchors.count - 1) where alt < anchors[i + 1].altitude {
                let s = smoothstep(anchors[i].altitude, anchors[i + 1].altitude, alt)
                z = anchors[i].zenith + (anchors[i + 1].zenith - anchors[i].zenith) * s
                h = anchors[i].horizon + (anchors[i + 1].horizon - anchors[i].horizon) * s
                break
            }
        }
        // A pastel dawn: blend toward the pastel anchors inside the dawn window (exactly today's colours at 0).
        let weight = pastel * pastelWindow(alt)
        if weight > 0 {
            let p = interpolate(pastelAnchors, alt)
            z += (p.zenith - z) * weight
            h += (p.horizon - h) * weight
        }
        // Moonlight: a cool lift.
        z += SIMD3<Float>(0.015, 0.022, 0.040) * moonlight
        h += SIMD3<Float>(0.012, 0.018, 0.032) * moonlight
        // Cloud greys and dims (up to 60% desaturation); mist softens the horizon.
        func grey(_ c: SIMD3<Float>, _ amount: Float, dim: Float) -> SIMD3<Float> {
            let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let coolGrey = SIMD3<Float>(0.94, 0.98, 1.06) * l   // cloud light is cool, never muddy
            return (c + (coolGrey - c) * amount) * (1 - dim)
        }
        z = grey(z, 0.6 * cloud, dim: 0.25 * cloud)
        h = grey(h, min(0.8, 0.6 * cloud + 0.3 * mist), dim: 0.2 * cloud)
        return (z, h)
    }
}
