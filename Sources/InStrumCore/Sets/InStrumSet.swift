/// A Set: one world, its visual, a built-in instrument preset and an ambience, tied together by a mood
/// and inspired by one song (credited in words and a link only), or born from its place with no song at all.
public struct InStrumSet: Codable, Equatable, Identifiable {
    public let id, name, moodName: String
    public let mood: Mood
    public let worldID: String
    /// The world's `visual` choice.
    public let visual: String
    /// A `PatchLibrary` preset (its engine is the built-in instrument to load).
    public let patchID: String
    public let ambience: AmbienceSettings
    /// A `CreditLibrary` id: the song that inspired the set. Nil for a set born from its place rather than a song
    /// (it shows a place card instead). Sets saved by older builds always carried one, and still decode.
    public let creditID: String?
}

/// The Sets, in gallery order.
public enum SetLibrary {
    public static let moonlitLake = InStrumSet(id: "moonlit-lake", name: "Moonlit Lake", moodName: "Serene", mood: .serene,
                                               worldID: MoonlitLakeModel.id, visual: "Lake Ripples", patchID: "felt-glass",
                                               ambience: AmbienceSettings(), creditID: CreditLibrary.comeBackToEarth.id)
    public static let spaceshipLounge = InStrumSet(id: "spaceship-lounge", name: "Spaceship Lounge", moodName: "Dreamy, awe-struck",
                                                   mood: .dreamy, worldID: SpaceshipLoungeModel.id, visual: "Galaxy Warp",
                                                   patchID: "orbit-pad", ambience: AmbienceSettings(), creditID: CreditLibrary.innerbloom.id)
    public static let goldenHourBeach = InStrumSet(id: "golden-hour-beach", name: "Golden Hour Beach", moodName: "Warm, hazy, nostalgic",
                                                   mood: .warmHaze, worldID: GoldenHourBeachModel.id, visual: "Tide Lines",
                                                   patchID: "honey-tape", ambience: AmbienceSettings(),
                                                   creditID: CreditLibrary.musicToWatchBoysTo.id)
    public static let coastRoad = InStrumSet(id: "coast-road", name: "Coast Road", moodName: "Hazy, restless, free",
                                             mood: .restless, worldID: CoastRoadModel.id, visual: "Coast Lights",
                                             patchID: "haze-bells", ambience: AmbienceSettings(), creditID: CreditLibrary.highByTheBeach.id)
    public static let snowboundCabin = InStrumSet(id: "snowbound-cabin", name: "Snowbound Cabin Window", moodName: "Hushed, safe, warm",
                                                  mood: .hushedWarm, worldID: SnowboundCabinModel.id, visual: "Frost Grow",
                                                  patchID: "cabin-felt", ambience: AmbienceSettings(), creditID: CreditLibrary.stay.id)
    public static let bedroomDawn = InStrumSet(id: "bedroom-dawn", name: "Bedroom Window at Dawn", moodName: "Soft, waking",
                                               mood: .softWaking, worldID: BedroomDawnModel.id, visual: "Curtain Light",
                                               patchID: "morning-box", ambience: AmbienceSettings(), creditID: CreditLibrary.dunno.id)
    public static let auroraFjord = InStrumSet(id: "aurora-fjord", name: "Aurora Fjord", moodName: "Awe-struck, cold, electric",
                                               mood: .electricAwe, worldID: AuroraFjordModel.id, visual: "Curtain Lights",
                                               patchID: "polar-choir", ambience: AmbienceSettings(), creditID: CreditLibrary.wings.id)
    public static let bioluminescentBay = InStrumSet(id: "bioluminescent-bay", name: "Bioluminescent Bay", moodName: "Magical, secret",
                                                     mood: .secretGlow, worldID: BioluminescentBayModel.id, visual: "Glow Wake",
                                                     patchID: "plankton-keys", ambience: AmbienceSettings(),
                                                     creditID: CreditLibrary.happinessIsAButterfly.id)
    /// Sets 9 and 10 ("Still Places") are born from their places, not from a song: no credit, so a place card.
    public static let teaHouseSnow = InStrumSet(id: "tea-house-snow", name: "Tea House Snow", moodName: "Delicate, hushed",
                                                mood: .delicate, worldID: TeaHouseSnowModel.id, visual: "Steam Lines",
                                                patchID: "tea-house-koto", ambience: AmbienceSettings(), creditID: nil)
    public static let zenRockGarden = InStrumSet(id: "zen-rock-garden", name: "Zen Rock Garden", moodName: "Ordered calm",
                                                 mood: .orderedCalm, worldID: ZenRockGardenModel.id, visual: "Rake Lines",
                                                 patchID: "zen-shakuhachi", ambience: AmbienceSettings(), creditID: nil)
    /// Sets 11 and 12 ("Deep Water"): the submarine after "Underwater"; the reef born from its place (a place card).
    public static let submarineWindow = InStrumSet(id: "submarine-window", name: "Submarine Window", moodName: "Pressure, hush",
                                                   mood: .deepHush, worldID: SubmarineWindowModel.id, visual: "Deep Lights",
                                                   patchID: "blue-depth", ambience: AmbienceSettings(),
                                                   creditID: CreditLibrary.underwater.id)
    public static let greatBarrierReef = InStrumSet(id: "great-barrier-reef", name: "Great Barrier Reef", moodName: "Colourful, alive",
                                                    mood: .reefAlive, worldID: GreatBarrierReefModel.id, visual: "Coral Pulse",
                                                    patchID: "reef-marimba", ambience: AmbienceSettings(), creditID: nil)
    public static let all: [InStrumSet] = [moonlitLake, spaceshipLounge, goldenHourBeach, coastRoad, snowboundCabin, bedroomDawn,
                                           auroraFjord, bioluminescentBay, teaHouseSnow, zenRockGarden, submarineWindow,
                                           greatBarrierReef]

    public static func set(id: String) -> InStrumSet? { all.first { $0.id == id } }
}
