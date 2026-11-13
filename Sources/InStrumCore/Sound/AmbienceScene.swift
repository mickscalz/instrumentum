/// The ambience sources a world can blend (spec §5).
public enum AmbienceSource: String, Codable, CaseIterable {
    case water, crickets, breeze, owl, rainOnWater, rainOnGlass, dawnChorus, shipHum, airFlow, chime, hullTicks, wind
    case surf, palms, gulls, road, engine, windowWind, passingCar
    case fire, kettle, street, drips, clock
    case iceGroan, waterfall, lapping, boat
    case templeBell, paperScreens, waterKnocker, warbler
    case sonar, hullCreak, whaleSong, bubbles, snappingShrimp, fishChorus
    /// Storms (Sets 17 & 18): the storm family, then the plains family. The thunder roll makes no sound of its own: it
    /// rolls the scene's `thunderQueue`.
    case grassWind, hailOnTin, birdsFlee, thunderRoll, inflowRoar, rainOnDust
    case dryCicadas, windmill, cattleGrid, dustTicks, shimmerHum, farTruck
    /// Fire & Neon (Sets 13 & 14, spec §8.3, §9.3): the volcano family, then the drive family. The eruption's boom, the
    /// plume's thunder, the wipers and the drive's passing cars sound only on the world's events (`AmbienceScene.events`);
    /// the steam vent and the rockfall also go now and then by themselves. The drive's engine and passing cars are the
    /// drive's own, beside the coast road's `.engine` and `.passingCar` (which keep their sound).
    case ventRumble, lavaHiss, steamVent, rockfall, eruptionBoom, plumeThunder
    case wetTyres, wipers, driveEngine, drivePassingCar, roofRain, farSiren
}

/// A one-shot a world sets going (Fire & Neon spec §8.3, §9.3): the eruption's boom, a crack of the plume's thunder, a
/// rockfall, a steam blast, a car passing beside you, a wiper's sweep. It is due `delay` seconds from now (the picture
/// first, the sound after: 3 s a kilometre, capped at 12 s) and heard only while its source is up; the engine holds 32 (a
/// 33rd drops the oldest), and a world switch or a panic drops those still waiting. Each source reads its own fields
/// (InStrumDSP.h, `isd_ambience_post_event`): strength 0…1 for all; pan −1 left … 1 right (the plume's cracks, a
/// rockfall, a steam blast, which side a car passes); distance 0 near … 1 far (a rockfall, a steam blast) or a car's
/// lateral metres; speed a car's closing speed (m/s) or a wiper's sweep time (s); kind 1 for a truck.
public struct AmbienceEvent: Equatable {
    public var source: AmbienceSource
    public var delay: Double
    public var strength: Double
    public var pan: Double
    public var speed: Double
    public var distance: Double
    public var kind: Int

    public init(source: AmbienceSource, delay: Double = 0, strength: Double = 1, pan: Double = 0, speed: Double = 0,
                distance: Double = 0, kind: Int = 0) {
        self.source = source
        self.delay = delay
        self.strength = strength
        self.pan = pan
        self.speed = speed
        self.distance = distance
        self.kind = kind
    }

    /// A car passing beside you, at its closest `in` seconds from now (it is heard from 3 s before): closing at `closing`
    /// m/s, `lateral` metres to the side (< 0 on your left), a truck or a car.
    public static func passingCar(in delay: Double, closing: Double, lateral: Double, truck: Bool, strength: Double = 1) -> AmbienceEvent {
        AmbienceEvent(source: .drivePassingCar, delay: delay, strength: strength, pan: lateral < 0 ? -1 : 1, speed: closing,
                      distance: abs(lateral), kind: truck ? 1 : 0)
    }

    /// A wiper's sweep (up and back) taking `seconds`, starting `in` seconds from now, on glass `wet` (0 dry … 1 streaming).
    public static func sweep(in delay: Double, seconds: Double, wet: Double) -> AmbienceEvent {
        AmbienceEvent(source: .wipers, delay: delay, strength: wet, speed: seconds)
    }
}

/// A strike's thunder on its way (Storms spec §3): the roll starts `delay` seconds from now (the picture first, the sound
/// after: 3 s a kilometre, capped at 12 s), at `strength` 0…1.
public struct QueuedThunder: Equatable {
    public var delay: Double
    public var strength: Double

    public init(delay: Double, strength: Double) {
        self.delay = delay
        self.strength = strength
    }

    /// The thunder of a strike `km` off: 3 s a kilometre, capped at 12 s.
    public static func strike(km: Double, strength: Double) -> QueuedThunder {
        QueuedThunder(delay: min(12, max(0, km.isFinite ? 3 * km : 12)), strength: strength)
    }
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
    /// One-shots: the thunder of the strikes seen this frame, each arriving late by its distance (Storms spec §3). Heard
    /// only while the world's thunder roll is up; the engine holds 16 (a 17th drops the oldest), and a world switch or a
    /// panic clears them.
    public var thunderQueue: [QueuedThunder]
    /// One-shots: the world's events seen this frame (Fire & Neon), each due by its delay. Heard only while its source is up.
    public var events: [AmbienceEvent]
    /// The volcano's lake, 0…1 each: how hard it surges (the vent rumble) and how brightly its cracks glow (the lava hiss).
    public var lakeSurge: Double
    public var lakeGlow: Double
    /// The world's trim in decibels (`AmbienceTrim`): a plain gain on the whole ambience, so every world's sits at one
    /// loudness. The app sets it where it hands the scene to the engine; the engine glides to it over 0.5 s.
    public var trimDB: Double

    public init(levels: [AmbienceSource: Double] = [:], nightCool: Double = 0, activity: Double = 0, thunder: Double? = nil,
                closeness: Double = 0.5, density: Double = 1, wave: Double? = nil, speed: Double = 0, surfDistance: Double = 0,
                indoors: Double = 0, wetness: Double = 0, snowOnGlass: Double = 0, key: AmbienceKey? = nil,
                bubbleBurst: Double? = nil, thunderQueue: [QueuedThunder] = [], events: [AmbienceEvent] = [],
                lakeSurge: Double = 0, lakeGlow: Double = 0, trimDB: Double = 0) {
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
        self.thunderQueue = thunderQueue
        self.events = events
        self.lakeSurge = lakeSurge
        self.lakeGlow = lakeGlow
        self.trimDB = trimDB
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
