import Foundation

/// The note beside a kept take (Small Wins spec §2): the moment it was played in. Saved as JSON next to its `.mid`;
/// fields that are nil (no set, no sky, no key sensed, a plugin's patch) are left out.
public struct TakeNote: Codable, Equatable {
    /// The instrument: the built-in preset's id (nil for a plugin), its name, and its dials by name (0…1).
    public struct Instrument: Codable, Equatable {
        public var patchID: String?
        public var name: String
        public var dials: [String: Double]

        public init(patchID: String?, name: String, dials: [String: Double]) {
            self.patchID = patchID
            self.name = name
            self.dials = dials
        }
    }

    /// The sky over the world: the city, its time of day ("21:07"), the weather, the sun's altitude (degrees) and the
    /// moon's phase (0 new … 0.5 full … 1).
    public struct Sky: Codable, Equatable {
        public var city: String
        public var localTime: String
        public var weather: String
        public var sunAltitude: Double
        public var moonPhase: Double

        public init(city: String, localTime: String, weather: String, sunAltitude: Double, moonPhase: Double) {
            self.city = city
            self.localTime = localTime
            self.weather = weather
            self.sunAltitude = sunAltitude
            self.moonPhase = moonPhase
        }
    }

    public var setID: String?
    public var worldID: String
    public var instrument: Instrument
    public var sky: Sky?
    /// The key the player was in, once it was sensed.
    public var key: AmbienceKey?
    public var appVersion: String
    /// How long the take runs.
    public var seconds: Double

    public init(setID: String?, worldID: String, instrument: Instrument, sky: Sky?, key: AmbienceKey?, appVersion: String, seconds: Double) {
        self.setID = setID
        self.worldID = worldID
        self.instrument = instrument
        self.sky = sky
        self.key = key
        self.appVersion = appVersion
        self.seconds = seconds
    }
}
