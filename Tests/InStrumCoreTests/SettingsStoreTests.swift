import XCTest
@testable import InStrumCore

final class SettingsStoreTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }

    func testRoundTripIncludingPluginState() throws {
        var s = AppSettings.default
        s.instrument = InstrumentChoice(name: "Splice INSTRUMENT", componentType: 0x61756D75,
                                        componentSubType: 0x53706C63, componentManufacturer: 0x53706C63,
                                        stateData: Data([1, 2, 3]))
        s.themeID = "midnight-steinway"; s.masterVolume = 0.5
        let store = SettingsStore(directory: dir)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
    func testMissingFileGivesDefaults() {
        XCTAssertEqual(SettingsStore(directory: dir).load(), .default)
    }
    func testCorruptFileGivesDefaultsAndIsKeptAside() throws {
        try Data("{not json".utf8).write(to: settingsURL)
        XCTAssertEqual(SettingsStore(directory: dir).load(), .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.corrupt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }
    func testUnknownKeysIgnoredAndMissingKeysDefaulted() throws {
        try Data(#"{"themeID":"moonlit-lake","futureThing":42}"#.utf8).write(to: settingsURL)
        let s = SettingsStore(directory: dir).load()
        XCTAssertEqual(s.themeID, "moonlit-lake")
        XCTAssertEqual(s.masterVolume, AppSettings.default.masterVolume)
        XCTAssertNil(s.instrument)
    }
    func testSoundAndMIDISettingsRoundTrip() throws {
        var s = AppSettings.default
        s.outputDeviceUID = "BuiltInSpeakerDevice"; s.midiChannel = 3; s.disabledMIDISources = ["IAC Bus 1"]; s.bufferFrames = 1024
        let store = SettingsStore(directory: dir)
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }
    func testOlderFilesFollowTheDefaultOutputAndEveryKeyboard() throws {
        try Data(#"{"themeID":"moonlit-lake","bufferFrames":512}"#.utf8).write(to: settingsURL)
        let s = SettingsStore(directory: dir).load()
        XCTAssertNil(s.outputDeviceUID)
        XCTAssertNil(s.midiChannel)
        XCTAssertEqual(s.disabledMIDISources, [])
        XCTAssertEqual(s.bufferFrames, 512)
    }
    func testABadMIDIChannelMeansAllChannels() throws {
        try Data(#"{"midiChannel":42}"#.utf8).write(to: settingsURL)
        XCTAssertNil(SettingsStore(directory: dir).load().midiChannel)
    }
    func testSaveCreatesMissingDirectory() throws {
        let nested = dir.appendingPathComponent("a/b")
        try SettingsStore(directory: nested).save(.default)
        XCTAssertEqual(SettingsStore(directory: nested).load(), .default)
    }

    /// Small Wins' four settings (review focus 5): a file from before them loads with the soft pedal, 88 keys, breathing
    /// on at depth 1 and Reduce Motion followed; bad values fall back (or clamp) without losing the rest of the file;
    /// every value round-trips.
    func testSmallWinsSettingsLoadWithDefaults() throws {
        try Data(#"{"themeID":"moonlit-lake","gentleVisuals":true,"ambience":{"volume":0.4}}"#.utf8).write(to: settingsURL)
        let old = SettingsStore(directory: dir).load()
        XCTAssertEqual(old.themeID, "moonlit-lake")
        XCTAssertTrue(old.gentleVisuals)
        XCTAssertEqual(old.holdPedal, .soft)
        XCTAssertEqual(old.keyboardRange, .keys88)
        XCTAssertTrue(old.breath.enabled)
        XCTAssertEqual(old.breath.depth, 1)
        XCTAssertTrue(old.followReduceMotion)
        XCTAssertEqual(old.ambience.volume, 0.4, accuracy: 1e-9)

        let bad = #"{"themeID":"moonlit-lake","holdPedal":"kazoo","keyboardRange":"keys12","breath":{"enabled":false,"depth":9},"followReduceMotion":"yes"}"#
        try Data(bad.utf8).write(to: settingsURL)
        let fixed = SettingsStore(directory: dir).load()
        XCTAssertEqual(fixed.themeID, "moonlit-lake", "the rest of the file still loads")
        XCTAssertEqual(fixed.holdPedal, .soft)
        XCTAssertEqual(fixed.keyboardRange, .keys88)
        XCTAssertFalse(fixed.breath.enabled)
        XCTAssertEqual(fixed.breath.depth, 1.5, "clamped")
        XCTAssertTrue(fixed.followReduceMotion)
        try Data(#"{"breath":{"depth":-2}}"#.utf8).write(to: settingsURL)
        XCTAssertEqual(SettingsStore(directory: dir).load().breath, AmbienceBreathSettings(enabled: true, depth: 0))
        try Data(#"{"breath":7}"#.utf8).write(to: settingsURL)
        XCTAssertEqual(SettingsStore(directory: dir).load().breath, AmbienceBreathSettings())

        let store = SettingsStore(directory: dir)
        for (i, (pedal, range)) in zip(HoldPedal.allCases + [.soft], KeyboardRange.allCases).enumerated() {
            var s = AppSettings.default
            s.holdPedal = pedal
            s.keyboardRange = range
            s.breath = AmbienceBreathSettings(enabled: i % 2 == 0, depth: Double(i) * 0.5)
            s.followReduceMotion = i % 2 == 1
            try store.save(s)
            XCTAssertEqual(store.load(), s, "\(pedal) \(range)")
        }

        // The values the rest of Small Wins reads.
        XCTAssertEqual(HoldPedal.allCases.map(\.controller), [67, 66, nil])
        XCTAssertEqual(HoldPedal.allCases.map(\.displayName), ["Soft pedal", "Sostenuto pedal", "Off"])
        XCTAssertEqual(KeyboardRange.allCases.map { [$0.low, $0.high] }, [[21, 108], [28, 103], [36, 96], [36, 84]])
        XCTAssertEqual(KeyboardRange.allCases.map { Int($0.high) - Int($0.low) + 1 }, [88, 76, 61, 49])
        XCTAssertEqual(KeyboardRange.keys88.displayName, "88 keys (A0–C8)")
        var breath = AmbienceBreathSettings()
        breath.depth = 2
        XCTAssertEqual(breath.depth, 1.5, "clamped as it's set, too")
    }

    /// "Opens on what's new" (Storms Review focus 6): a file from before the rule has no record of the gallery it saw, so
    /// it opens on the newest set once; one from a build with fewer sets, or an older newest, does too; once marked seen
    /// it round-trips and opens as before. A first install (no file) has nothing it hasn't seen.
    func testOlderSettingsOpenOnWhatsNewOnce() throws {
        try Data(#"{"themeID":"great-barrier-reef","activeSetID":"great-barrier-reef"}"#.utf8).write(to: settingsURL)
        let store = SettingsStore(directory: dir)
        var old = store.load()
        XCTAssertEqual(old.activeSetID, "great-barrier-reef", "the rest of the file still loads")
        XCTAssertNil(old.lastNewestSetID)
        XCTAssertNil(old.lastSetCount)
        XCTAssertTrue(old.opensOnWhatsNew)
        old.markSetsSeen()
        let newestID = old.lastNewestSetID
        let count = old.lastSetCount
        XCTAssertEqual(newestID, "neon-night-drive")
        XCTAssertEqual(count, 16)
        XCTAssertFalse(old.opensOnWhatsNew)
        try store.save(old)
        let again = store.load()
        XCTAssertEqual(again, old)
        XCTAssertFalse(again.opensOnWhatsNew)

        // The storms build's gallery (Sets 17 & 18, the previous gallery: fourteen sets, Lightning Plains the newest): this
        // build's first launch opens on what's new, Neon Night Drive (Fire & Neon).
        var storms = AppSettings.default
        storms.lastNewestSetID = "lightning-plains"
        storms.lastSetCount = 14
        XCTAssertTrue(storms.opensOnWhatsNew)
        storms.markSetsSeen()
        XCTAssertFalse(storms.opensOnWhatsNew)
        XCTAssertEqual(storms.lastNewestSetID, SetLibrary.neonNightDrive.id)
        XCTAssertEqual(storms.lastSetCount, SetLibrary.all.count)
        // The twelve-set build's gallery, had it kept one: its newest was the reef.
        var twelve = AppSettings.default
        twelve.lastNewestSetID = "great-barrier-reef"
        twelve.lastSetCount = 12
        XCTAssertTrue(twelve.opensOnWhatsNew)
        // The same newest but more sets than it counted, or a newer newest at the same count, is new too.
        var fewer = AppSettings.default
        fewer.lastSetCount = 15
        XCTAssertTrue(fewer.opensOnWhatsNew)
        var other = AppSettings.default
        other.lastNewestSetID = "volcano-rim"
        XCTAssertTrue(other.opensOnWhatsNew)

        // A first install (no file) starts with this build's own record.
        let fresh = AppSettings.default
        XCTAssertFalse(fresh.opensOnWhatsNew)
        let freshNewest = fresh.lastNewestSetID
        XCTAssertEqual(freshNewest, SetLibrary.newest.id)
        try FileManager.default.removeItem(at: settingsURL)
        let missing = SettingsStore(directory: dir).load()
        XCTAssertFalse(missing.opensOnWhatsNew)
    }
}

final class LaunchGuardTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func testFirstLaunchIsClean() { XCTAssertFalse(LaunchGuard(directory: dir).beginLaunch()) }
    func testLaunchWithoutMarkStableIsUnclean() {
        _ = LaunchGuard(directory: dir).beginLaunch()
        XCTAssertTrue(LaunchGuard(directory: dir).beginLaunch())
    }
    func testMarkStableMakesNextLaunchClean() {
        let g = LaunchGuard(directory: dir)
        _ = g.beginLaunch(); g.markStable()
        XCTAssertFalse(LaunchGuard(directory: dir).beginLaunch())
    }
}
