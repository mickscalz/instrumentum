import XCTest
@testable import InStrumCore

final class SetsTests: XCTestCase {
    /// Every set is whole: its world, visual and preset exist, and it carries a song's credit or, born from its place, none
    /// (the App's `InspiredByCardTests.testEverySetHasACardOrPlaceArt` checks that each one then has its card). Sets 11 and
    /// 12 ("Deep Water") come after the still places, the submarine then the reef; Sets 17 and 18 ("Storms", built before
    /// Sets 13 to 16) come last, the supercell then the plains (Storms spec §12), so the plains are the newest.
    func testStormSetsAreComplete() throws {
        let ids = SetLibrary.all.map(\.id)
        let expected = ["moonlit-lake", "spaceship-lounge", "golden-hour-beach", "coast-road", "snowbound-cabin", "bedroom-dawn",
                        "aurora-fjord", "bioluminescent-bay", "tea-house-snow", "zen-rock-garden", "submarine-window",
                        "great-barrier-reef", "supercell-sky", "lightning-plains"]
        XCTAssertEqual(ids, expected)
        XCTAssertEqual(ids.count, 14)
        let uniqueIDs = Set(ids).count
        XCTAssertEqual(uniqueIDs, 14, "ids are unique")
        let worlds = Set(SetLibrary.all.map(\.worldID)).count
        XCTAssertEqual(worlds, 14, "one world each")
        XCTAssertEqual(SetLibrary.newest, SetLibrary.lightningPlains, "the newest is the last in the gallery")
        for s in SetLibrary.all {
            XCTAssertEqual(ThemeRegistry.resolve(s.worldID), s.worldID, s.id)
            let visual = try XCTUnwrap(ThemeRegistry.parameters(for: s.worldID).first { $0.id == "visual" }, s.id)
            guard case let .choice(options) = visual.kind else { return XCTFail("\(s.id): visual is not a choice") }
            XCTAssertTrue(options.contains(s.visual), s.id)
            XCTAssertNotNil(PatchLibrary.all.first { $0.id == s.patchID }, s.id)
            // A credit, when the set has one, is in the library (a set born from its place has none).
            if let credit = s.creditID { XCTAssertNotNil(CreditLibrary.credit(id: credit), s.id) }
            XCTAssertEqual(SetLibrary.set(id: s.id), s)
            XCTAssertFalse(s.name.isEmpty); XCTAssertFalse(s.moodName.isEmpty)
        }
        let lake = try XCTUnwrap(SetLibrary.set(id: "moonlit-lake"))
        XCTAssertEqual(lake.mood, .serene)
        XCTAssertEqual(lake.worldID, MoonlitLakeModel.id)
        XCTAssertEqual(lake.visual, "Lake Ripples")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == lake.patchID }?.engine, .feltGlass)
        XCTAssertEqual(lake.creditID, CreditLibrary.comeBackToEarth.id)
        let lounge = try XCTUnwrap(SetLibrary.set(id: "spaceship-lounge"))
        XCTAssertEqual(lounge.mood, .dreamy)
        XCTAssertEqual(lounge.worldID, SpaceshipLoungeModel.id)
        XCTAssertEqual(lounge.visual, "Galaxy Warp")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == lounge.patchID }?.engine, .orbitPad)
        XCTAssertEqual(lounge.creditID, CreditLibrary.innerbloom.id)
        let beach = try XCTUnwrap(SetLibrary.set(id: "golden-hour-beach"))
        XCTAssertEqual(beach.name, "Golden Hour Beach")
        XCTAssertEqual(beach.moodName, "Warm, hazy, nostalgic")
        XCTAssertEqual(beach.mood, .warmHaze)
        XCTAssertEqual(beach.worldID, GoldenHourBeachModel.id)
        XCTAssertEqual(beach.visual, "Tide Lines")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == beach.patchID }?.engine, .honeyTape)
        XCTAssertEqual(beach.patchID, "honey-tape")
        XCTAssertEqual(beach.creditID, CreditLibrary.musicToWatchBoysTo.id)
        let road = try XCTUnwrap(SetLibrary.set(id: "coast-road"))
        XCTAssertEqual(road.name, "Coast Road")
        XCTAssertEqual(road.moodName, "Hazy, restless, free")
        XCTAssertEqual(road.mood, .restless)
        XCTAssertEqual(road.worldID, CoastRoadModel.id)
        XCTAssertEqual(road.visual, "Coast Lights")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == road.patchID }?.engine, .hazeBells)
        XCTAssertEqual(road.patchID, "haze-bells")
        XCTAssertEqual(road.creditID, CreditLibrary.highByTheBeach.id)
        let cabin = try XCTUnwrap(SetLibrary.set(id: "snowbound-cabin"))
        XCTAssertEqual(cabin.name, "Snowbound Cabin Window")
        XCTAssertEqual(cabin.moodName, "Hushed, safe, warm")
        XCTAssertEqual(cabin.mood, .hushedWarm)
        XCTAssertEqual(cabin.worldID, SnowboundCabinModel.id)
        XCTAssertEqual(cabin.visual, "Frost Grow")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == cabin.patchID }?.engine, .cabinFelt)
        XCTAssertEqual(cabin.patchID, "cabin-felt")
        XCTAssertEqual(cabin.creditID, CreditLibrary.stay.id)
        let bedroom = try XCTUnwrap(SetLibrary.set(id: "bedroom-dawn"))
        XCTAssertEqual(bedroom.name, "Bedroom Window at Dawn")
        XCTAssertEqual(bedroom.moodName, "Soft, waking")
        XCTAssertEqual(bedroom.mood, .softWaking)
        XCTAssertEqual(bedroom.worldID, BedroomDawnModel.id)
        XCTAssertEqual(bedroom.visual, "Curtain Light")
        XCTAssertEqual(PatchLibrary.all.first { $0.id == bedroom.patchID }?.engine, .morningBox)
        XCTAssertEqual(bedroom.patchID, "morning-box")
        XCTAssertEqual(bedroom.creditID, CreditLibrary.dunno.id)
        let fjord = try XCTUnwrap(SetLibrary.set(id: "aurora-fjord"))
        XCTAssertEqual(fjord, SetLibrary.auroraFjord)
        XCTAssertEqual(fjord.name, "Aurora Fjord")
        XCTAssertEqual(fjord.moodName, "Awe-struck, cold, electric")
        XCTAssertEqual(fjord.mood, .electricAwe)
        XCTAssertEqual(fjord.worldID, AuroraFjordModel.id)
        XCTAssertEqual(fjord.visual, "Curtain Lights")
        XCTAssertTrue(AuroraFjordModel.visuals.contains(fjord.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == fjord.patchID }?.engine, .polarChoir)
        XCTAssertEqual(fjord.patchID, "polar-choir")
        XCTAssertEqual(fjord.ambience, AmbienceSettings())
        XCTAssertEqual(fjord.creditID, CreditLibrary.wings.id)
        let bay = try XCTUnwrap(SetLibrary.set(id: "bioluminescent-bay"))
        XCTAssertEqual(bay, SetLibrary.bioluminescentBay)
        XCTAssertEqual(bay.name, "Bioluminescent Bay")
        XCTAssertEqual(bay.moodName, "Magical, secret")
        XCTAssertEqual(bay.mood, .secretGlow)
        XCTAssertEqual(bay.worldID, BioluminescentBayModel.id)
        XCTAssertEqual(bay.visual, "Glow Wake")
        XCTAssertTrue(BioluminescentBayModel.visuals.contains(bay.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == bay.patchID }?.engine, .planktonKeys)
        XCTAssertEqual(bay.patchID, "plankton-keys")
        XCTAssertEqual(bay.ambience, AmbienceSettings())
        XCTAssertEqual(bay.creditID, CreditLibrary.happinessIsAButterfly.id)
        let tea = try XCTUnwrap(SetLibrary.set(id: "tea-house-snow"))
        XCTAssertEqual(tea, SetLibrary.teaHouseSnow)
        XCTAssertEqual(tea.name, "Tea House Snow")
        XCTAssertEqual(tea.moodName, "Delicate, hushed")
        XCTAssertEqual(tea.mood, .delicate)
        XCTAssertEqual(tea.worldID, TeaHouseSnowModel.id)
        XCTAssertEqual(tea.visual, "Steam Lines")
        XCTAssertTrue(TeaHouseSnowModel.visuals.contains(tea.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == tea.patchID }?.engine, .teaHouseKoto)
        XCTAssertEqual(tea.patchID, "tea-house-koto")
        XCTAssertEqual(tea.ambience, AmbienceSettings())
        XCTAssertNil(tea.creditID, "born from its place, not a song")
        let garden = try XCTUnwrap(SetLibrary.set(id: "zen-rock-garden"))
        XCTAssertEqual(garden, SetLibrary.zenRockGarden)
        XCTAssertEqual(garden.name, "Zen Rock Garden")
        XCTAssertEqual(garden.moodName, "Ordered calm")
        XCTAssertEqual(garden.mood, .orderedCalm)
        XCTAssertEqual(garden.worldID, ZenRockGardenModel.id)
        XCTAssertEqual(garden.visual, "Rake Lines")
        XCTAssertTrue(ZenRockGardenModel.visuals.contains(garden.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == garden.patchID }?.engine, .zenShakuhachi)
        XCTAssertEqual(garden.patchID, "zen-shakuhachi")
        XCTAssertEqual(garden.ambience, AmbienceSettings())
        XCTAssertNil(garden.creditID, "born from its place, not a song")
        // The deep water (spec §2, §11): the submarine after "Underwater", the reef born from its place.
        let sub = try XCTUnwrap(SetLibrary.set(id: "submarine-window"))
        XCTAssertEqual(sub, SetLibrary.submarineWindow)
        XCTAssertEqual(sub.name, "Submarine Window")
        XCTAssertEqual(sub.moodName, "Pressure, hush")
        XCTAssertEqual(sub.mood, .deepHush)
        XCTAssertEqual(sub.worldID, SubmarineWindowModel.id)
        XCTAssertEqual(sub.visual, "Deep Lights")
        XCTAssertTrue(SubmarineWindowModel.visuals.contains(sub.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == sub.patchID }?.engine, .blueDepth)
        XCTAssertEqual(sub.patchID, "blue-depth")
        XCTAssertEqual(sub.ambience, AmbienceSettings())
        XCTAssertEqual(sub.creditID, CreditLibrary.underwater.id)
        XCTAssertEqual(sub.creditID, "underwater")
        let reef = try XCTUnwrap(SetLibrary.set(id: "great-barrier-reef"))
        XCTAssertEqual(reef, SetLibrary.greatBarrierReef)
        XCTAssertEqual(reef.name, "Great Barrier Reef")
        XCTAssertEqual(reef.moodName, "Colourful, alive")
        XCTAssertEqual(reef.mood, .reefAlive)
        XCTAssertEqual(reef.worldID, GreatBarrierReefModel.id)
        XCTAssertEqual(reef.visual, "Coral Pulse")
        XCTAssertTrue(GreatBarrierReefModel.visuals.contains(reef.visual))
        XCTAssertEqual(PatchLibrary.all.first { $0.id == reef.patchID }?.engine, .reefMarimba)
        XCTAssertEqual(reef.patchID, "reef-marimba")
        XCTAssertEqual(reef.ambience, AmbienceSettings())
        XCTAssertNil(reef.creditID, "born from its place, not a song")
        // The storms (Storms spec §2, §11, §12): the supercell after "FADE", the plains after "Runaway".
        let supercell = try XCTUnwrap(SetLibrary.set(id: "supercell-sky"))
        XCTAssertEqual(supercell, SetLibrary.supercellSky)
        XCTAssertEqual(supercell.name, "Supercell Sky")
        XCTAssertEqual(supercell.moodName, "Tense, thrilling")
        XCTAssertEqual(supercell.mood, .stormTense)
        XCTAssertEqual(supercell.worldID, SupercellSkyModel.id)
        XCTAssertEqual(supercell.worldID, "supercell-sky")
        XCTAssertEqual(supercell.visual, "Wall Cloud")
        let supercellVisuals = SupercellSkyModel.visuals
        XCTAssertTrue(supercellVisuals.contains(supercell.visual))
        XCTAssertEqual(supercell.patchID, "endless-rise")
        let supercellPatch = try XCTUnwrap(PatchLibrary.all.first { $0.id == "endless-rise" })
        XCTAssertEqual(supercellPatch.engine, .endlessRise)
        XCTAssertEqual(supercell.ambience, AmbienceSettings())
        XCTAssertEqual(supercell.creditID, CreditLibrary.fade.id)
        XCTAssertEqual(supercell.creditID, "fade")
        let plains = try XCTUnwrap(SetLibrary.set(id: "lightning-plains"))
        XCTAssertEqual(plains, SetLibrary.lightningPlains)
        XCTAssertEqual(plains.name, "Lightning Plains")
        XCTAssertEqual(plains.moodName, "Dramatic, vast")
        XCTAssertEqual(plains.mood, .plainsVast)
        XCTAssertEqual(plains.worldID, LightningPlainsModel.id)
        XCTAssertEqual(plains.worldID, "lightning-plains")
        XCTAssertEqual(plains.visual, "Strike Lines")
        let plainsVisuals = LightningPlainsModel.visuals
        XCTAssertTrue(plainsVisuals.contains(plains.visual))
        XCTAssertEqual(plains.patchID, "single-note-grand")
        let plainsPatch = try XCTUnwrap(PatchLibrary.all.first { $0.id == "single-note-grand" })
        XCTAssertEqual(plainsPatch.engine, .singleNoteGrand)
        XCTAssertEqual(plains.ambience, AmbienceSettings())
        XCTAssertEqual(plains.creditID, CreditLibrary.runaway.id)
        XCTAssertEqual(plains.creditID, "runaway")
        // Only the two still places and the reef go without a song.
        XCTAssertEqual(SetLibrary.all.filter { $0.creditID == nil }.map(\.id), ["tea-house-snow", "zen-rock-garden", "great-barrier-reef"])
        // Every set's mood is its own.
        let setMoods = SetLibrary.all.map(\.mood)
        for i in 0..<setMoods.count { for j in (i + 1)..<setMoods.count { XCTAssertNotEqual(setMoods[i], setMoods[j]) } }
        XCTAssertNil(SetLibrary.set(id: "nope"))
        // Each set's built-in preset carries the same credit as the set.
        for s in SetLibrary.all { XCTAssertEqual(PatchLibrary.all.first { $0.id == s.patchID }?.creditID, s.creditID) }
    }

    /// Sets saved by older builds always carried a credit; they still decode now it is optional. A set born from its
    /// place (no credit) is written without the key and reads back as nil, as does an explicit null. And the gallery an
    /// eight-set build stored (Review focus 4) reads back as this build's first eight, in their places, with their credits;
    /// the two still places come after them, then the deep water, then the storms (the App's `testTenSetStoresStillLoad`
    /// opens a ten-set build's store on this gallery, and `testOldSetStoresStillLoad` a twelve-set build's).
    func testOldSetsWithACreditStillDecode() throws {
        let old = #"{"id":"moonlit-lake","name":"Moonlit Lake","moodName":"Serene","#
            + #""mood":{"energy":0.2,"warmth":0.45,"brightness":0.3,"space":0.85,"motion":0.25},"#
            + #""worldID":"moonlit-lake","visual":"Lake Ripples","patchID":"felt-glass","#
            + #""ambience":{"enabled":true,"volume":0.25,"closeness":0.5},"creditID":"come-back-to-earth"}"#
        let lake = try JSONDecoder().decode(InStrumSet.self, from: Data(old.utf8))
        XCTAssertEqual(lake, SetLibrary.moonlitLake)
        XCTAssertEqual(lake.creditID, CreditLibrary.comeBackToEarth.id)
        for s in SetLibrary.all {
            XCTAssertEqual(try JSONDecoder().decode(InStrumSet.self, from: JSONEncoder().encode(s)), s, s.id)
        }
        let places = SetLibrary.all.filter { $0.creditID == nil }
        XCTAssertEqual(places, [SetLibrary.teaHouseSnow, SetLibrary.zenRockGarden, SetLibrary.greatBarrierReef])
        for place in places {
            let written = try JSONEncoder().encode(place)
            XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("creditID"), place.id)
            XCTAssertEqual(try JSONDecoder().decode(InStrumSet.self, from: written), place, place.id)
        }
        let withNull = old.replacingOccurrences(of: #""creditID":"come-back-to-earth""#, with: #""creditID":null"#)
        XCTAssertNotEqual(withNull, old)
        XCTAssertNil(try JSONDecoder().decode(InStrumSet.self, from: Data(withNull.utf8)).creditID)
        // The eight-set gallery: every set with its song's credit (a credited set is written the same then and now).
        let eightSetGallery = ["moonlit-lake", "spaceship-lounge", "golden-hour-beach", "coast-road", "snowbound-cabin",
                               "bedroom-dawn", "aurora-fjord", "bioluminescent-bay"]
        let eight = Array(SetLibrary.all.prefix(8))
        XCTAssertEqual(eight.map(\.id), eightSetGallery, "the older sets keep their places")
        let stored = try JSONEncoder().encode(eight)
        let parsed = try JSONSerialization.jsonObject(with: stored)
        let objects = try XCTUnwrap(parsed as? [[String: Any]])
        XCTAssertEqual(objects.compactMap { $0["creditID"] as? String }, eight.compactMap(\.creditID), "every older set carries its credit")
        XCTAssertEqual(objects.count, 8)
        XCTAssertEqual(try JSONDecoder().decode([InStrumSet].self, from: stored), eight)
        let after = Array(SetLibrary.all.dropFirst(8))
        let laterSets = [SetLibrary.teaHouseSnow, SetLibrary.zenRockGarden, SetLibrary.submarineWindow, SetLibrary.greatBarrierReef,
                         SetLibrary.supercellSky, SetLibrary.lightningPlains]
        XCTAssertEqual(after, laterSets)
    }

    func testNewMoods() {
        XCTAssertEqual(Mood.warmHaze, Mood(energy: 0.25, warmth: 0.85, brightness: 0.55, space: 0.75, motion: 0.35))
        XCTAssertEqual(Mood.restless, Mood(energy: 0.5, warmth: 0.35, brightness: 0.4, space: 0.85, motion: 0.75))
        XCTAssertNotEqual(Mood.warmHaze, Mood.serene); XCTAssertNotEqual(Mood.restless, Mood.dreamy)
        XCTAssertEqual(Mood.hushedWarm, Mood(energy: 0.2, warmth: 0.85, brightness: 0.3, space: 0.35, motion: 0.2))
        XCTAssertEqual(Mood.softWaking, Mood(energy: 0.25, warmth: 0.6, brightness: 0.65, space: 0.55, motion: 0.3))
        XCTAssertEqual(Mood.electricAwe, Mood(energy: 0.45, warmth: 0.25, brightness: 0.45, space: 0.95, motion: 0.6))
        XCTAssertEqual(Mood.secretGlow, Mood(energy: 0.3, warmth: 0.55, brightness: 0.35, space: 0.7, motion: 0.4))
        // The still places (spec §8.1, §9.1).
        XCTAssertEqual(Mood.delicate, Mood(energy: 0.2, warmth: 0.55, brightness: 0.5, space: 0.3, motion: 0.2))
        XCTAssertEqual(Mood.orderedCalm, Mood(energy: 0.15, warmth: 0.45, brightness: 0.55, space: 0.5, motion: 0.15))
        // The deep water (Sets 11 & 12 spec §8.1, §9.1, §10): pressure and hush; colourful and alive.
        XCTAssertEqual(Mood.deepHush, Mood(energy: 0.3, warmth: 0.3, brightness: 0.15, space: 0.9, motion: 0.45))
        XCTAssertEqual(Mood.reefAlive, Mood(energy: 0.65, warmth: 0.75, brightness: 0.85, space: 0.45, motion: 0.75))
        // The storms (Storms spec §2, §11): tense and thrilling; dramatic, vast and lonely.
        let stormTense = Mood(energy: 0.7, warmth: 0.35, brightness: 0.5, space: 0.8, motion: 0.9)
        XCTAssertEqual(Mood.stormTense, stormTense)
        let plainsVast = Mood(energy: 0.45, warmth: 0.3, brightness: 0.4, space: 1.0, motion: 0.4)
        XCTAssertEqual(Mood.plainsVast, plainsVast)
        let moods = [Mood.serene, .dreamy, .warmHaze, .restless, .hushedWarm, .softWaking, .electricAwe, .secretGlow,
                     .delicate, .orderedCalm, .deepHush, .reefAlive, .stormTense, .plainsVast]
        for i in 0..<moods.count { for j in (i + 1)..<moods.count { XCTAssertNotEqual(moods[i], moods[j]) } }
        // A mood saved by a set decodes as itself.
        let stored = try? JSONEncoder().encode(Mood.plainsVast)
        let decoded = stored.flatMap { try? JSONDecoder().decode(Mood.self, from: $0) }
        XCTAssertEqual(decoded, .plainsVast)
    }

    // MARK: - Inspired-by cards

    func testListenLinks() throws {
        let c = CreditLibrary.comeBackToEarth
        let app = ListenLink.spotifyApp(for: c)
        XCTAssertEqual(app.scheme, "spotify")
        XCTAssertTrue(app.absoluteString.contains("Mac%20Miller"), app.absoluteString)
        XCTAssertTrue(app.absoluteString.contains("Come%20Back%20to%20Earth"), app.absoluteString)
        let web = ListenLink.spotifyWeb(for: c)
        XCTAssertEqual(web.host, "open.spotify.com")
        XCTAssertEqual(web.scheme, "https")
        XCTAssertTrue(web.path.hasPrefix("/search/"))
        // Accented names survive the trip.
        let bloom = ListenLink.spotifyWeb(for: CreditLibrary.innerbloom)
        XCTAssertEqual(bloom.path, "/search/RÜFÜS DU SOL Innerbloom")
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.stay).path, "/search/Mac Miller Stay")
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.dunno).path, "/search/Mac Miller Dunno")
        XCTAssertTrue(ListenLink.spotifyApp(for: CreditLibrary.dunno).absoluteString.contains("Dunno"))
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.wings).path, "/search/Mac Miller Wings")
        XCTAssertTrue(ListenLink.spotifyApp(for: CreditLibrary.wings).absoluteString.contains("Wings"))
        XCTAssertEqual(ListenLink.spotifyWeb(for: CreditLibrary.happinessIsAButterfly).path,
                       "/search/Lana Del Rey Happiness Is a Butterfly")
        let butterfly = ListenLink.spotifyApp(for: CreditLibrary.happinessIsAButterfly).absoluteString
        XCTAssertTrue(butterfly.contains("Lana%20Del%20Rey"), butterfly)
        XCTAssertTrue(butterfly.contains("Happiness%20Is%20a%20Butterfly"), butterfly)
    }

    func testPulseFollowsTempo() {
        for c in CreditLibrary.all { XCTAssertEqual(c.pulsePeriod, 60 / c.tempoBPM, accuracy: 1e-12) }
        XCTAssertEqual(CreditLibrary.comeBackToEarth.pulsePeriod, 60.0 / 84, accuracy: 1e-12)
    }
}
