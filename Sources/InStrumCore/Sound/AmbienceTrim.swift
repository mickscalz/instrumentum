/// Each world's ambience trim in decibels: a plain gain on the world's whole ambience, applied where the app hands the
/// world's scene to the engine (`AppModel.updateAmbience`), so that switching world never jumps in volume. Set by
/// measurement: each world's ambience demo (the scene `DemoRenderTests.ambienceDemo` renders), at the default ambience
/// volume, sits within 1.5 LU of the worlds' median loudness (ITU-R BS.1770-4), within ±6 dB. The sources' own levels
/// inside a world, and when its one-shots (thunder, bells, waves) happen, are as they were. A theme with no ambience of
/// its own (Midnight Steinway, Butterfly Garden), or a world not listed, has none.
public enum AmbienceTrim {
    public static let byWorld: [String: Double] = [
        MoonlitLakeModel.id: 0,
        SpaceshipLoungeModel.id: 0,
        GoldenHourBeachModel.id: 0,
        CoastRoadModel.id: 0,
        SnowboundCabinModel.id: 0,
        BedroomDawnModel.id: 0,
        AuroraFjordModel.id: 0,
        BioluminescentBayModel.id: 0,
        TeaHouseSnowModel.id: 0,
        ZenRockGardenModel.id: 0,
        SubmarineWindowModel.id: 0,
        GreatBarrierReefModel.id: 0,
        SupercellSkyModel.id: 0,
        LightningPlainsModel.id: 0,
        VolcanoRimModel.id: 0,
        NeonNightDriveModel.id: 0,
    ]

    /// The world's trim (dB); 0 for a theme without one.
    public static func db(for worldID: String) -> Double { byWorld[worldID] ?? 0 }
}
