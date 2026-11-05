/// The ambience sources a world can blend (spec §5).
public enum AmbienceSource: String, Codable, CaseIterable {
    case water, crickets, breeze, owl, rainOnWater, rainOnGlass, dawnChorus, shipHum, airFlow, chime, hullTicks, wind
    case surf, palms, gulls, road, engine, windowWind, passingCar
    case fire, kettle, street, drips, clock
    case iceGroan, waterfall, lapping, boat
    case templeBell, paperScreens, waterKnocker, warbler
    case sonar, hullCreak, whaleSong, bubbles, snappingShrimp, fishChorus
    /// Storms (Sets 17 & 18), reserved: the storm family, then the plains family. Silent until the engine has sources
    /// for them (Task 8 of the Storms plan).
    case grassWind, hailOnTin, birdsFlee, thunderRoll, inflowRoar, rainOnDust
    case dryCicadas, windmill, cattleGrid, dustTicks, shimmerHum, farTruck
}

/// The key the player is in (spec §7.1): root 0…11 (C = 0), major or minor.
public struct AmbienceKey: Equatable, Codable {
    public var root: Int
    public var major: Bool

    public init(root: Int, major: Bool) {
        self.root = root
        self.major = major
    }
}

/// What a world wants to hear right now. Levels are 0…1; anything missing is silent.
public struct AmbienceScene: Equatable {
    public var levels: [AmbienceSource: Double]
    /// 0 warm early night … 1 cool late night.
    public var nightCool: Double
    /// 0…1 while playing: the ambience ducks under the instrument.
    public var activity: Double
    /// One-shot: thunder at this distance (0 near … 1 far).
    public var thunder: Double?
    /// 0 distant … 1 all around you (the user's setting with the mood on top).
    public var closeness: Double
    /// 0.5…1.5: how often things happen (from the mood's energy).
    public var density: Double
    /// One-shot: a wave breaks on the shore now, with this strength (0…1).
    public var wave: Double?
    /// A car's speed 0…1 (road, engine and window wind follow it).
    public var speed: Double
    /// 0 close, detailed surf … 1 a far, low roar.
    public var surfDistance: Double
    /// 0 outdoors … 1 inside behind glass: outdoor sounds lose their top and come through quieter.
    public var indoors: Double
    /// 0…1: a wet road hisses.
    public var wetness: Double
    /// 0…1: snow on the glass turns rain on the glass into soft ticks.
    public var snowOnGlass: Double
    /// The key the player is in, once it can be sensed: in-key sources (the temple bell, the sonar) take it at their
    /// next strike or ping. Nil leaves them where they are.
    public var key: AmbienceKey?
    /// One-shot: a burst of bubbles rises now, with this strength (0 a few … 1 a stream). Heard only while the world's
    /// bubbles are up.
    public var bubbleBurst: Double?

    public init(levels: [AmbienceSource: Double] = [:], nightCool: Double = 0, activity: Double = 0, thunder: Double? = nil,
                closeness: Double = 0.5, density: Double = 1, wave: Double? = nil, speed: Double = 0, surfDistance: Double = 0,
                indoors: Double = 0, wetness: Double = 0, snowOnGlass: Double = 0, key: AmbienceKey? = nil,
                bubbleBurst: Double? = nil) {
        self.levels = levels
        self.nightCool = nightCool
        self.activity = activity
        self.thunder = thunder
        self.closeness = closeness
        self.density = density
        self.wave = wave
        self.speed = speed
        self.surfDistance = surfDistance
        self.indoors = indoors
        self.wetness = wetness
        self.snowOnGlass = snowOnGlass
        self.key = key
        self.bubbleBurst = bubbleBurst
    }

    public static let silent = AmbienceScene()

    public func level(_ source: AmbienceSource) -> Double { levels[source] ?? 0 }
}

/// The user's ambience controls (persisted).
public struct AmbienceSettings: Codable, Equatable {
    public var enabled = true
    /// 0…1 (default 25%).
    public var volume: Double = 0.25
    /// 0 distant … 1 all around you.
    public var closeness: Double = 0.5

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, volume, closeness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmbienceSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        volume = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume))
        closeness = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .closeness)) ?? d.closeness))
    }
}
