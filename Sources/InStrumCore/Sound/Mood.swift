/// The feeling a set shares across its world, visual, instrument and ambience. Each value 0…1; 0.5 is neutral.
public struct Mood: Codable, Equatable {
    public var energy, warmth, brightness, space, motion: Double

    public init(energy: Double, warmth: Double, brightness: Double, space: Double, motion: Double) {
        self.energy = energy; self.warmth = warmth; self.brightness = brightness; self.space = space; self.motion = motion
    }

    public static let neutral = Mood(energy: 0.5, warmth: 0.5, brightness: 0.5, space: 0.5, motion: 0.5)
    /// Moonlit Lake.
    public static let serene = Mood(energy: 0.2, warmth: 0.45, brightness: 0.3, space: 0.85, motion: 0.25)
    /// Spaceship Lounge.
    public static let dreamy = Mood(energy: 0.35, warmth: 0.3, brightness: 0.5, space: 0.95, motion: 0.6)
    /// Golden Hour Beach: warm, hazy, nostalgic.
    public static let warmHaze = Mood(energy: 0.25, warmth: 0.85, brightness: 0.55, space: 0.75, motion: 0.35)
    /// Coast Road: hazy, restless, free.
    public static let restless = Mood(energy: 0.5, warmth: 0.35, brightness: 0.4, space: 0.85, motion: 0.75)
    /// Snowbound Cabin Window: hushed, warm, close.
    public static let hushedWarm = Mood(energy: 0.2, warmth: 0.85, brightness: 0.3, space: 0.35, motion: 0.2)
    /// Bedroom Window at Dawn: soft, waking.
    public static let softWaking = Mood(energy: 0.25, warmth: 0.6, brightness: 0.65, space: 0.55, motion: 0.3)
    /// Bioluminescent Bay: magical, secret.
    public static let secretGlow = Mood(energy: 0.3, warmth: 0.55, brightness: 0.35, space: 0.7, motion: 0.4)
    /// Tea House Snow: delicate, hushed.
    public static let delicate = Mood(energy: 0.2, warmth: 0.55, brightness: 0.5, space: 0.3, motion: 0.2)
    /// Zen Rock Garden: ordered calm.
    public static let orderedCalm = Mood(energy: 0.15, warmth: 0.45, brightness: 0.55, space: 0.5, motion: 0.15)
    /// Submarine Window: pressure, hush.
    public static let deepHush = Mood(energy: 0.3, warmth: 0.3, brightness: 0.15, space: 0.9, motion: 0.45)
    /// Great Barrier Reef: colourful, alive.
    public static let reefAlive = Mood(energy: 0.65, warmth: 0.75, brightness: 0.85, space: 0.45, motion: 0.75)
    /// Aurora Fjord: awe-struck, cold, electric.
    public static let electricAwe = Mood(energy: 0.45, warmth: 0.25, brightness: 0.45, space: 0.95, motion: 0.6)
    /// Supercell Sky: tense, thrilling (Storms spec §2, §11).
    public static let stormTense = Mood(energy: 0.7, warmth: 0.35, brightness: 0.5, space: 0.8, motion: 0.9)

    /// The built-in instruments' hidden mood parameters (Audio Unit identifiers can't contain dots).
    public static let parameterIdentifiers: Set<String> = ["moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion"]

    /// Values keyed by those identifiers.
    public var parameterValues: [String: Double] {
        ["moodEnergy": energy, "moodWarmth": warmth, "moodBrightness": brightness, "moodSpace": space, "moodMotion": motion]
    }
}

public extension Mood {
    /// Lightning Plains: dramatic, vast, lonely (Storms spec §11).
    static let plainsVast = Mood(energy: 0.45, warmth: 0.3, brightness: 0.4, space: 1.0, motion: 0.4)
    /// Neon Night Drive: wired (Fire & Neon spec §10), the most energetic and the fastest-moving mood in the app. Its pair,
    /// Volcano Rim's `molten`, is declared beside its world (`VolcanoRimModel.swift`).
    static let wired = Mood(energy: 0.9, warmth: 0.3, brightness: 0.8, space: 0.55, motion: 0.95)
}
