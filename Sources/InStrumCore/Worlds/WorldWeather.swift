import Foundation

/// Weather rules shared by worlds (the Snowbound Cabin and the Aurora Fjord; the warm rule for warm worlds).
public enum WorldWeather {
    /// It's cold here: rain falls as snow (and frosts the glass), storms become blizzards (gliding in and out with the
    /// weather, whiting out with each gust), no lightning and never wet.
    public static func cold(_ s: SkyState) -> SkyState {
        var s = s
        // How much storm is in the sky right now: the weather machine's own smoothstep glide between kinds.
        let t = min(max(s.weatherBlend, 0), 1), glide = t * t * (3 - 2 * t)
        let storm = (s.weather == .storm ? 1 - glide : 0) + (s.nextWeather == .storm ? glide : 0)
        let rainAsSnow = s.rain
        s.snow = max(s.snow, rainAsSnow, storm)
        s.wind += (1 - s.wind) * storm
        s.gust = min(1, s.gust * (1 + 0.67 * storm))          // a storm's gusts (0.6) become a blizzard's (1)
        s.frost = max(s.frost, 0.6 * rainAsSnow, 0.9 * storm)  // rain melts frost; here it's snow, and frosts the glass
        s.mist = min(1, s.mist + 0.3 * s.gust * storm)          // the blizzard's whiteout with each gust
        s.rain = 0
        s.lightning = 0
        s.wetness = 0
        s.rainbow = 0                                           // it snows here; no rainbows
        s.fireflies = 0                                         // and no fireflies in the cold
        s.supercellWeather = nil                                // a supercell is a blizzard here (its snow above)
        s.hail = 0
        func chill(_ k: WeatherKind) -> WeatherKind {
            switch k {
            case .drizzle, .rain, .sunShower, .sleet, .hail, .freezingDrizzle: return .snow
            case .squall: return .blizzard
            case .dryLightning: return .overcast
            case .flurries: return .snow
            case .smokeHaze, .iceFog, .dustStorm: return .mist
            case .thunderheads: return .overcast
            case .monsoon: return .blizzard
            case .fogBank: return .mist
            case .storm: return .blizzard
            case .afterRain: return .lightCloud
            case .humid: return .clear
            case .supercell: return .blizzard
            default: return k   // diamond dust, rime frost, sea smoke and ashfall are at home in the cold
            }
        }
        s.weather = chill(s.weather)
        s.nextWeather = chill(s.nextWeather)
        return s
    }

    /// It's warm here (spec §7.5): snow and flurries fall as rain, blizzards become squalls, and sleet and hail become
    /// rain. Frost, rime, diamond dust, ice fog and sea smoke never happen: sea smoke and ice fog become a light haze
    /// (no steam, mist 0.25) and the halos of their ice (and of diamond dust's) go with them, as do light pillars.
    /// Fireflies are left alone (a world that has none zeroes them itself).
    public static func warm(_ sky: SkyState) -> SkyState {
        var s = sky
        let b = sky.weatherBlend.isFinite ? min(max(sky.weatherBlend, 0), 1) : 0
        let glide = b * b * (3 - 2 * b)
        let haze = share(in: sky, glide: glide) { $0 == .iceFog || $0 == .seaSmoke }
        let ice = share(in: sky, glide: glide) { $0 == .iceFog || $0 == .seaSmoke || $0 == .diamondDust }
        s.rain = min(1, max(s.rain, s.snow))   // snow, flurries, blizzards, sleet and hail all fall as rain
        s.snow = 0
        s.frost = 0
        s.rime = 0
        s.diamondDust = 0
        s.pillar = 0
        s.steam = 0
        s.mist = s.mist * (1 - haze) + 0.25 * haze   // a light haze where the fog would have been (exactly 0.25 in it)
        s.halo *= 1 - ice
        s.weather = warmed(s.weather)
        s.nextWeather = warmed(s.nextWeather)
        return s
    }

    /// A weather as a warm world has it.
    static func warmed(_ k: WeatherKind) -> WeatherKind {
        switch k {
        case .snow, .flurries, .sleet, .hail: return .rain
        case .blizzard: return .squall
        case .freezingDrizzle: return .drizzle
        case .iceFog, .seaSmoke, .diamondDust: return .clear   // a light haze under a clear sky
        case .rime: return .mist                               // fog that never freezes
        default: return k
        }
    }

    /// How much of the kinds that `matches` is in the sky right now (the weather machine's glide between kinds), 0…1.
    private static func share(in s: SkyState, glide: Float, _ matches: (WeatherKind) -> Bool) -> Float {
        var w: Float = 0
        if matches(s.weather) { w += 1 - glide }
        if matches(s.nextWeather) { w += glide }
        return min(1, w)
    }
}

// MARK: - Storms: the gust front's stages, the supercell's stage, and Random Beautiful's tables

/// A gust front's three stages (Storms spec §7.1).
public enum GustFrontStage: String, Equatable, CaseIterable {
    /// The shelf cloud rises off the horizon toward you, and the inflow gusts blow toward the storm.
    case approach
    /// The dust wall crosses the view in 10–20 s, the wind turns and reaches 1, and the cold air drops the warmth 8%.
    case hit
    /// The first big drops, then rain at 0.6; it holds here once the stages have played.
    case rain
}

/// Where a gust front is now: its stage, its seeded details and what it does to the sky (Storms spec §7.1).
public struct GustFrontNow: Equatable {
    public var stage: GustFrontStage
    /// Seconds since it began arriving, and its whole length (the Advanced setting, 60–600 s): Approach to a third of
    /// it, the Hit to two thirds, then the Rain.
    public var elapsed: Double
    public var duration: Double
    /// How far through the current stage (0…1; 1 from the end of the Rain's ramp on, as it holds).
    public var stageProgress: Float
    /// How much of the sky the gust front is (the weather machine's blend), 0…1.
    public var amount: Float
    /// The storm's bearing (degrees from north, clockwise): the shelf cloud stands there, the inflow blows toward it and
    /// the outflow and the dust wall come from it.
    public var bearing: Float
    /// The shelf cloud: 0 below the horizon … 1 overhead (it rises through the Approach and has passed once it rains).
    public var shelf: Float
    /// The wind toward the storm (the Approach's inflow) and out of it (the outflow, from the Hit on), 0…1.
    public var inflow: Float
    public var outflow: Float
    /// The dust wall: how far it has crossed the view (0 on the storm's horizon … 1 past you; 0 before the Hit), how
    /// thick it is now (0…1), how tall it stands (8–15°) and how long it takes to cross (10–20 s).
    public var dustFront: Float
    public var dust: Float
    public var dustHeight: Float
    public var crossSeconds: Double
    /// The cold air's grade on the world's warmth (0, falling to −0.08 as the dust wall passes, and holding).
    public var warmth: Float
    /// The staged weather (what replaces the gust front's nominal values in the sky).
    public var cloud: Float, rain: Float, mist: Float, wind: Float, gust: Float

    public init(stage: GustFrontStage, elapsed: Double, duration: Double, stageProgress: Float, amount: Float, bearing: Float,
                shelf: Float, inflow: Float, outflow: Float, dustFront: Float, dust: Float, dustHeight: Float,
                crossSeconds: Double, warmth: Float, cloud: Float, rain: Float, mist: Float, wind: Float, gust: Float) {
        self.stage = stage; self.elapsed = elapsed; self.duration = duration; self.stageProgress = stageProgress
        self.amount = amount; self.bearing = bearing; self.shelf = shelf; self.inflow = inflow; self.outflow = outflow
        self.dustFront = dustFront; self.dust = dust; self.dustHeight = dustHeight; self.crossSeconds = crossSeconds
        self.warmth = warmth; self.cloud = cloud; self.rain = rain; self.mist = mist; self.wind = wind; self.gust = gust
    }

    /// How far the Rain's ramp has gone (0 until the Rain, rising 0.2 → 0.6 of rain over the first half of the stage).
    public var rainRamp: Float { stage == .rain ? min(1, 2 * stageProgress) : 0 }
}

/// The supercell's stage (Fire & Neon spec §7.2, Storms spec §8.1): the event's own three, and Cycle, which the picker
/// in Supercell Sky offers instead of a weather.
public enum SupercellStage: String, Codable, CaseIterable {
    case approach = "Approach", core = "Core", clearing = "Clearing", cycle = "Cycle"

    /// Which of the event's stages a phase (0…<1) is in: Approach to a third, Core to two thirds, Clearing after.
    public static func event(at phase: Float) -> SupercellStage {
        let p = phase.isFinite ? phase - phase.rounded(.down) : 0
        if p < 1.0 / 3 { return .approach }
        return p < 2.0 / 3 ? .core : .clearing
    }

    /// The world parameter that picks it (Supercell Sky's picker).
    public static func spec(default d: SupercellStage) -> ParamSpec {
        ParamSpec(id: id, name: "Storm stage", group: "Weather",
                  help: "Hold the supercell as it approaches, at its core or as it clears, or let it cycle through all three",
                  kind: .choice(allCases.map(\.rawValue)), defaultValue: .choice(d.rawValue))
    }

    public static let id = "supercell.stage"
}

public extension WorldWeather {
    // MARK: The gust front (spec §7.1)

    /// A gust front's stages at `elapsed` seconds of its `duration` (clamped to 60–600 s), with its seeded details: the
    /// dust wall's crossing (10–20 s), its height (8–15°) and the storm's bearing. Pure, so the sky, the renderers and
    /// the tests read one schedule:
    /// - Approach (to D/3): the shelf cloud rises (cloud 0.45 → 0.9), the inflow gusts build toward the storm (wind
    ///   0.25 → 0.45, gustiness 0.4 → 0.8), mist 0.15, no rain.
    /// - Hit (D/3 to 2D/3): the dust wall crosses in `cross` seconds; with it the wind turns (the inflow dies within the
    ///   first 30% of the crossing; the outflow and the wind reach 1 by 60%), the dust thickens the mist to 0.5, and the
    ///   cold air grades the warmth down to −8% by the time the wall has passed; then the dust thins to half.
    /// - Rain (from 2D/3): the first big drops (0.2, in over 4 s), then the rain setting in to 0.6 by 5D/6; the dust
    ///   laid by it, the shelf cloud gone over, the wind easing to 0.8 and the outflow to 0.6; it holds there after D.
    static func gustFront(elapsed rawElapsed: Double, duration rawDuration: Double, cross rawCross: Double = 15,
                          dustHeight: Float = 11, bearing: Float = 0, amount: Float = 1) -> GustFrontNow {
        let duration = rawDuration.isFinite ? min(600, max(60, rawDuration)) : 180
        let elapsed = rawElapsed.isFinite ? max(0, rawElapsed) : 0
        let cross = rawCross.isFinite ? min(20, max(10, rawCross)) : 15
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return Float(t * t * (3 - 2 * t))
        }
        let third = duration / 3
        var g = GustFrontNow(stage: .approach, elapsed: elapsed, duration: duration, stageProgress: 0,
                             amount: amount.isFinite ? min(1, max(0, amount)) : 0,
                             bearing: bearing.isFinite ? bearing : 0, shelf: 0, inflow: 0, outflow: 0, dustFront: 0, dust: 0,
                             dustHeight: dustHeight.isFinite ? min(15, max(8, dustHeight)) : 11, crossSeconds: cross,
                             warmth: 0, cloud: 0.45, rain: 0, mist: 0.15, wind: 0.25, gust: 0.4)
        if elapsed < third {
            let a = elapsed / third
            g.stageProgress = Float(a)
            g.shelf = smooth(0, 1, a)
            g.cloud = 0.45 + 0.45 * g.shelf
            g.inflow = Float(0.3 + 0.3 * a)
            g.wind = Float(0.25 + 0.2 * a)
            g.gust = Float(0.4 + 0.4 * a)
            return g
        }
        g.shelf = 1
        g.cloud = 0.9
        g.dustFront = Float(min(1, (elapsed - third) / cross))
        g.warmth = -0.08 * smooth(0.3, 1, Double(g.dustFront))
        let turned = smooth(0.2, 0.6, Double(g.dustFront))
        if elapsed < 2 * third {
            let c = Double(g.dustFront)
            g.stage = .hit
            g.stageProgress = Float((elapsed - third) / third)
            g.inflow = 0.6 * (1 - smooth(0, 0.3, c))
            g.outflow = turned
            g.wind = 0.45 + 0.55 * turned
            g.gust = 0.8 + 0.2 * smooth(0, 0.3, c)
            // The wall thickens as it comes, and once it has passed you are left in its thinning dust.
            let after = (elapsed - third - cross) / max(1e-6, third - cross)
            g.dust = c < 1 ? smooth(0, 0.3, c) : 1 - 0.5 * smooth(0, 1, after)
            g.mist = 0.15 + 0.35 * g.dust
            return g
        }
        g.stage = .rain
        let r = min(1, (elapsed - 2 * third) / third)
        g.stageProgress = Float(r)
        let drops = smooth(0, min(1, 4 / third), r)   // the first big drops, in over 4 s
        let ramp = smooth(0.1, 0.5, r)                 // then the rain sets in, 0.6 by 5D/6
        g.shelf = 1 - ramp
        g.cloud = 0.9 + 0.05 * ramp
        g.rain = 0.2 * drops + 0.4 * ramp
        g.outflow = 1 - 0.4 * ramp
        g.wind = 1 - 0.2 * ramp
        g.gust = 1 - 0.3 * ramp
        g.dust = 0.5 * (1 - smooth(0, 0.25, r))
        g.mist = 0.15 + 0.35 * g.dust + 0.15 * ramp
        return g
    }

    // MARK: The supercell (spec §8.1)

    /// The supercell event's length when it cycles (Fire & Neon's 8 minutes; its Advanced setting comes with the event).
    static let supercellSeconds = 480.0
    /// A held stage glides forward to its phase at a whole cycle in this many seconds (never back: a storm doesn't
    /// un-happen), so a change in the picker plays out in at most a minute.
    static let supercellGlideSeconds = 60.0

    /// The event's phase the picker holds for a stage: the middle of Approach (1/6), Core (1/2) and Clearing (5/6); nil
    /// for Cycle, which runs.
    static func supercellPhase(held stage: SupercellStage) -> Double? {
        switch stage {
        case .approach: return 1.0 / 6
        case .core: return 0.5
        case .clearing: return 5.0 / 6
        case .cycle: return nil
        }
    }

    /// One step of the supercell's phase (0…<1) under the picker: Cycle runs the event at its own pace, one pass a
    /// `duration`, and loops; a held stage glides forward to its phase and holds there.
    static func supercellStep(_ rawPhase: Double, stage: SupercellStage, dt rawDt: Double,
                              duration rawDuration: Double = supercellSeconds) -> Double {
        let dt = rawDt.isFinite ? max(0, rawDt) : 0
        let duration = rawDuration.isFinite ? max(1, rawDuration) : supercellSeconds
        var phase = rawPhase.isFinite ? rawPhase - rawPhase.rounded(.down) : 0
        guard let target = supercellPhase(held: stage) else {
            phase += dt / duration
            return phase - phase.rounded(.down)
        }
        var ahead = (target - phase).truncatingRemainder(dividingBy: 1)
        if ahead < 0 { ahead += 1 }
        if ahead < 1e-12 || ahead > 1 - 1e-12 { return target }
        let move = dt / supercellGlideSeconds
        if move >= ahead { return target }
        phase += move
        return phase - phase.rounded(.down)
    }

    // MARK: Random Beautiful's tables (spec §3, §7)

    /// The volcano (Set 13's world, when it comes): Random Beautiful brings ashfall there and nowhere else (spec §7.1).
    static let ashWorlds: Set<String> = ["volcano-rim"]
    /// Where Random Beautiful may bring a supercell (spec §7.2): the worlds where storms already appear (the lake, the
    /// beach, the coast road) and Neon Night Drive. (Supercell Sky's storm is its own; Lightning Plains' is a storm line.)
    static let supercellWorlds: Set<String> = [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, NeonNightDriveModel.id]
    static let ashfallWeight: Float = 0.5
    static let supercellWeight: Float = 0.25

    /// Worlds where storms already appear (Fire & Neon spec §7.2's list): Random Beautiful may bring a gust front here.
    /// The ids after the three on this branch are the worlds still to come (Neon Night Drive, and Storms' own two), so
    /// their tables are ready when they are registered.
    static let stormWorlds: Set<String> = [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id,
                                           "neon-night-drive", "supercell-sky", "lightning-plains"]
    /// Dry worlds (plains, the coast road, the outback, the desert): Random Beautiful may bring virga here. Only the coast
    /// road is on this branch; Lightning Plains is Set 18's, and an outback or desert world adds its id here.
    static let dryWorlds: Set<String> = [CoastRoadModel.id, "lightning-plains"]
    /// How often Random Beautiful picks them where they belong (squalls and thunderheads are 0.3 and 0.4).
    static let gustFrontWeight: Float = 0.3
    static let virgaWeight: Float = 0.5

    /// The weathers a world's Random Beautiful adds, with their weights (for `LivingSky.step`'s storm inputs): a gust
    /// front only where storms appear, virga only in dry worlds, ashfall only at the volcano, a supercell only at the
    /// lake, the beach, the coast road and the drive; none anywhere else.
    static func randomExtras(for worldID: String) -> [WeatherKind: Float] {
        var extras: [WeatherKind: Float] = [:]
        if stormWorlds.contains(worldID) { extras[.gustFront] = gustFrontWeight }
        if dryWorlds.contains(worldID) { extras[.virga] = virgaWeight }
        if ashWorlds.contains(worldID) { extras[.ashfall] = ashfallWeight }
        if supercellWorlds.contains(worldID) { extras[.supercell] = supercellWeight }
        return extras
    }
}
