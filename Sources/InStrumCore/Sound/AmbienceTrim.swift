/// Each world's ambience trim in decibels: a plain gain on the world's whole ambience, applied where the app hands the
/// world's scene to the engine (`AppModel.updateAmbience`), so that switching world never jumps in volume. Set by
/// measurement: each world's ambience demo (the scene `DemoRenderTests.ambienceDemo` renders), at the default ambience
/// volume, sits within 1.5 LU of the worlds' median loudness before trims (−36.4 LUFS, ITU-R BS.1770-4), within ±6 dB;
/// Bedroom Dawn's demo, heard wholly indoors, would need +10.9 dB and is held at +6 (−41.3 LUFS). The sources' own levels
/// inside a world, and when its one-shots (thunder, bells, waves) happen, are as they were. A theme with no ambience of
/// its own (Midnight Steinway, Butterfly Garden), or a world not listed, has none.
public enum AmbienceTrim {
    public static let byWorld: [String: Double] = [
        MoonlitLakeModel.id: -5.6,
        SpaceshipLoungeModel.id: -0.9,
        GoldenHourBeachModel.id: -2.6,
        CoastRoadModel.id: -0.5,
        SnowboundCabinModel.id: 5.2,
        BedroomDawnModel.id: 6.0,
        AuroraFjordModel.id: 1.0,
        BioluminescentBayModel.id: -3.0,
        TeaHouseSnowModel.id: 6.0,
        ZenRockGardenModel.id: 0.5,
        SubmarineWindowModel.id: 4.4,
        GreatBarrierReefModel.id: -1.9,
        SupercellSkyModel.id: -6.0,
        LightningPlainsModel.id: -2.5,
        VolcanoRimModel.id: 1.1,
        NeonNightDriveModel.id: 1.8,
    ]

    /// The world's trim (dB); 0 for a theme without one.
    public static func db(for worldID: String) -> Double { byWorld[worldID] ?? 0 }
}
