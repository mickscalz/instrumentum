import XCTest
@testable import InStrumCore

/// Where recordings go (Recorder spec §3; plan Task 1): an unsaved recording lives in a working folder of its own under
/// a temporary folder, and Save moves it to `~/Music/In Strum Meants/Recordings/YYYY-MM-DD HH.mm — <name>/`, never over
/// another. Nothing is written until a working folder is asked for. `session.json` reads back as written, and older
/// files read with their defaults.
final class RecordingStoreTests: XCTestCase {
    var root: URL!
    var dir: URL!
    var temp: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        dir = root.appendingPathComponent("Recordings")
        temp = root.appendingPathComponent("Working")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let melbourne = TimeZone(identifier: "Australia/Melbourne")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = melbourne
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func note() -> TakeNote {
        TakeNote(setID: "moonlit-lake", worldID: "moonlit-lake",
                 instrument: .init(patchID: "felt-glass", name: "Felt Glass", dials: ["Tone": 0.5]),
                 sky: .init(city: "Melbourne", localTime: "21:07", weather: "clear", sunAltitude: -12.5, moonPhase: 0.4),
                 key: AmbienceKey(root: 2, major: true), appVersion: "dev", seconds: 64)
    }

    func testFolderNames() throws {
        let at = date(2026, 11, 16, 21, 7)
        let plain = RecordingStore.folderName(title: "Moonlit Lake", date: at, timeZone: melbourne)
        XCTAssertEqual(plain, "2026-11-16 21.07 — Moonlit Lake")
        let unsafe = RecordingStore.folderName(title: "AC/DC: Live", date: at, timeZone: melbourne)
        XCTAssertEqual(unsafe, "2026-11-16 21.07 — AC-DC- Live")
        let takeStem = TakeStore.fileStem(title: "AC/DC: Live", date: at, timeZone: melbourne)
        XCTAssertEqual(unsafe, takeStem, "named as Keep That names a take")
        let blank = RecordingStore.folderName(title: " \n ", date: at, timeZone: melbourne)
        XCTAssertEqual(blank, "2026-11-16 21.07 — Recording", "a name is never blank")

        let store = RecordingStore(directory: dir, temporary: temp)
        let firstWorking = try store.newWorkingFolder()
        let first = try store.save(workingFolder: firstWorking, title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(first.lastPathComponent, "2026-11-16 21.07 — Moonlit Lake")
        let secondWorking = try store.newWorkingFolder()
        let second = try store.save(workingFolder: secondWorking, title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(second.lastPathComponent, "2026-11-16 21.07 — Moonlit Lake 2", "never over the first")
        let thirdWorking = try store.newWorkingFolder()
        let third = try store.save(workingFolder: thirdWorking, title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(third.lastPathComponent, "2026-11-16 21.07 — Moonlit Lake 3")
        XCTAssertTrue(exists(first))
        XCTAssertTrue(exists(second))
        XCTAssertTrue(RecordingStore.defaultDirectory.path.hasSuffix("Music/In Strum Meants/Recordings"), RecordingStore.defaultDirectory.path)
    }

    func testSessionRoundTripsAndToleratesOldFiles() throws {
        let store = RecordingStore(directory: dir, temporary: temp)
        let folder = try store.newWorkingFolder()
        var s = RecordingSession(title: "Moonlit Lake", sampleRate: 48_000, appVersion: "1.4 (214)")
        _ = s.addLayer(kind: .instrument, name: "Felt Glass", note: note())
        _ = s.addLayer(kind: .playAlong, name: "Play-along", note: nil)
        s.layers[0].volume = 0.5
        s.layers[0].muted = true
        s.layers[0].offsetFrames = -7200
        s.layers[0].frames = 96_000
        s.layers[1].frames = 100_000
        try store.writeSession(s, in: folder)
        let file = folder.appendingPathComponent("session.json")
        XCTAssertTrue(exists(file))
        let back = try store.readSession(in: folder)
        XCTAssertEqual(back, s, "it reads back as written")

        // Fields that are nil are left out.
        let data = try Data(contentsOf: file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 2)
        let alongKeys = Set(layers[1].keys)
        XCTAssertFalse(alongKeys.contains("midiFileName"))
        XCTAssertFalse(alongKeys.contains("note"))
        let feltKeys = Set(layers[0].keys)
        XCTAssertTrue(feltKeys.contains("midiFileName"))
        XCTAssertTrue(feltKeys.contains("note"))

        // A file from before offsets, mutes, volumes, lengths, notes and MIDI files, with keys this build doesn't know.
        let old = """
        {"title": "Old Lake", "sampleRate": 44100, "appVersion": "1.0", "futureKey": true,
         "layers": [{"id": 1, "kind": "instrument", "name": "Felt Glass", "fileName": "Layer 1 — Felt Glass.wav", "somethingNew": 3}]}
        """
        let oldFolder = try store.newWorkingFolder()
        try Data(old.utf8).write(to: oldFolder.appendingPathComponent("session.json"))
        let read = try store.readSession(in: oldFolder)
        XCTAssertEqual(read.title, "Old Lake")
        XCTAssertEqual(read.sampleRate, 44_100)
        XCTAssertEqual(read.appVersion, "1.0")
        let layer = try XCTUnwrap(read.layers.first)
        XCTAssertEqual(layer.id, 1)
        XCTAssertEqual(layer.kind, .instrument)
        XCTAssertEqual(layer.fileName, "Layer 1 — Felt Glass.wav")
        XCTAssertEqual(layer.volume, 1)
        XCTAssertFalse(layer.muted)
        XCTAssertEqual(layer.offsetFrames, 0)
        XCTAssertEqual(layer.frames, 0)
        XCTAssertNil(layer.note)
        XCTAssertNil(layer.midiFileName)

        // A session with no layers yet.
        let bare = """
        {"title": "Empty", "sampleRate": 48000}
        """
        let bareFolder = try store.newWorkingFolder()
        try Data(bare.utf8).write(to: bareFolder.appendingPathComponent("session.json"))
        let empty = try store.readSession(in: bareFolder)
        XCTAssertTrue(empty.layers.isEmpty)
        XCTAssertEqual(empty.appVersion, "")
    }

    func testNothingExistsUntilAWorkingFolderIsAsked() throws {
        let store = RecordingStore(directory: dir, temporary: temp)
        XCTAssertFalse(exists(root), "making a store writes nothing")
        let folder = try store.newWorkingFolder()
        XCTAssertTrue(exists(folder))
        XCTAssertEqual(folder.deletingLastPathComponent().path, temp.path, "under the temporary folder")
        XCTAssertFalse(exists(dir), "nothing in Recordings until a save")
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(contents.isEmpty, "\(contents)")
        let other = try store.newWorkingFolder()
        XCTAssertNotEqual(other.path, folder.path, "each recording has a folder of its own")

        // Discarding removes the working folder and leaves the other alone.
        store.discard(workingFolder: folder)
        XCTAssertFalse(exists(folder))
        XCTAssertTrue(exists(other))
        XCTAssertFalse(exists(dir))
    }

    func testSaveMovesTheFolder() throws {
        let store = RecordingStore(directory: dir, temporary: temp)
        let working = try store.newWorkingFolder()
        let stemName = "Layer 1 — Felt Glass.wav"
        try Data([1, 2, 3]).write(to: working.appendingPathComponent(stemName))
        var s = RecordingSession(title: "Moonlit Lake", sampleRate: 48_000, appVersion: "dev")
        _ = s.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        try store.writeSession(s, in: working)

        let saved = try store.save(workingFolder: working, title: "Moonlit Lake", at: date(2026, 11, 16, 21, 7), timeZone: melbourne)
        XCTAssertFalse(exists(working), "moved, not copied")
        XCTAssertEqual(saved.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(saved.lastPathComponent, "2026-11-16 21.07 — Moonlit Lake")
        let names = try FileManager.default.contentsOfDirectory(atPath: saved.path).sorted()
        XCTAssertEqual(names, [stemName, "session.json"])
        let bytes = try Data(contentsOf: saved.appendingPathComponent(stemName))
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        let back = try store.readSession(in: saved)
        XCTAssertEqual(back, s)

        // Saving a recording that is already saved (reopened, with a layer added) leaves it where it is.
        let again = try store.save(workingFolder: saved, title: "Moonlit Lake", at: date(2026, 11, 17, 8, 0), timeZone: melbourne)
        XCTAssertEqual(again.path, saved.path)
        XCTAssertTrue(exists(saved))

        // Discard only ever removes a working folder, never a saved recording.
        store.discard(workingFolder: saved)
        XCTAssertTrue(exists(saved))
    }

    func testDiskGuards() {
        let start: Int64 = 2_000_000_000
        let stop: Int64 = 500_000_000
        XCTAssertEqual(RecordingStore.minimumFreeBytesToStart, start)
        XCTAssertEqual(RecordingStore.minimumFreeBytesToKeepGoing, stop)
        XCTAssertFalse(RecordingStore.diskAllows(start: start - 1), "under 2 GB free: refuse to start")
        XCTAssertTrue(RecordingStore.diskAllows(start: start))
        XCTAssertFalse(RecordingStore.diskAllows(start: 0))
        XCTAssertTrue(RecordingStore.diskMustStop(stop - 1), "under 500 MB free: stop and keep")
        XCTAssertFalse(RecordingStore.diskMustStop(stop))
        XCTAssertTrue(RecordingStore.diskMustStop(0))
        XCTAssertFalse(RecordingStore.diskMustStop(start))
    }
}
