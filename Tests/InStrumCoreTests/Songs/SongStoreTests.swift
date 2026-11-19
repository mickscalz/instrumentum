import XCTest
@testable import InStrumCore

/// Each song's sheet kept on the Mac (Song Sheet spec §3, Task S1): one JSON file per song in
/// `~/Library/Application Support/In Strum Meants/Songs`. Every lyric line here is invented.
final class SongStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Songs")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func song(id: String) -> SongFile {
        let words = [LyricWord(text: "the", time: 12.5), LyricWord(text: "kettle", time: 12.9), LyricWord(text: "sings")]
        let lines = [LyricLine(time: 12.5, words: words), LyricLine(time: 16, words: [])]
        return SongFile(id: id, title: "A Song About Breakfast", artist: "Nobody In Particular", lines: lines, offset: -0.4,
                        listened: [ChordEvent(time: 12.4, chord: Chord(root: 9, quality: .minor))],
                        pasted: [ChordEvent(time: 12.5, chord: Chord(root: 5, quality: .major7))],
                        fixes: [SongFix(time: 12.5, chord: Chord(root: 0, quality: .dominant7)), SongFix(time: 20, chord: nil)],
                        prefersFlats: true)
    }

    func testASongReadsBackAsSaved() throws {
        let store = SongStore(directory: dir)
        let file = song(id: "spotify:track:0kettle0sings0abc")
        try store.save(file)
        let loaded = store.load("spotify:track:0kettle0sings0abc")
        XCTAssertEqual(loaded, file)
        let bare = store.load("0kettle0sings0abc")
        XCTAssertEqual(bare, file, "Spotify's URI and its bare id are the same song")
        XCTAssertNil(store.load("0another0song0xyz"))
        // Saving again replaces it.
        var nudged = file
        nudged.offset = 0.3
        try store.save(nudged)
        let reloaded = store.load(file.id)
        XCTAssertEqual(reloaded, nudged)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["0kettle0sings0abc.json"])
    }

    func testAnOlderFileLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = """
        {"id": "0older0song", "title": "Toast", "artist": "Nobody", "lines": [{"time": 1.5, "words": [{"text": "toast"}]}],
         "someFieldFromLater": 7}
        """
        try Data(old.utf8).write(to: dir.appendingPathComponent("0older0song.json"))
        let store = SongStore(directory: dir)
        let loaded = try XCTUnwrap(store.load("0older0song"))
        let expected = SongFile(id: "0older0song", title: "Toast", artist: "Nobody",
                                lines: [LyricLine(time: 1.5, words: [LyricWord(text: "toast")])])
        XCTAssertEqual(loaded, expected, "the missing fields take their defaults")
        // No id, a fix in a shape this build can't read, and a stray value: what can be read still loads.
        let partial = """
        {"title": "Marmalade", "offset": 1.25, "fixes": "not a list", "prefersFlats": false}
        """
        try Data(partial.utf8).write(to: dir.appendingPathComponent("0partial0song.json"))
        let second = try XCTUnwrap(store.load("0partial0song"))
        XCTAssertEqual(second.id, "0partial0song", "the id comes from the file's name")
        XCTAssertEqual(second.title, "Marmalade")
        XCTAssertEqual(second.artist, "")
        XCTAssertEqual(second.offset, 1.25)
        XCTAssertEqual(second.fixes, [])
        XCTAssertEqual(second.prefersFlats, false)
        // Not JSON at all: nothing, and no crash.
        try Data("not json".utf8).write(to: dir.appendingPathComponent("0broken0song.json"))
        XCTAssertNil(store.load("0broken0song"))
    }

    func testFileNamesAreSafe() throws {
        XCTAssertEqual(SongStore.fileName(for: "spotify:track:0kettle0sings0abc"), "0kettle0sings0abc.json")
        XCTAssertEqual(SongStore.fileName(for: "0kettle0sings0abc"), "0kettle0sings0abc.json")
        let odd = SongStore.fileName(for: "spotify:local:Some/Artist:Tea:12")
        XCTAssertFalse(odd.contains("/"), odd)
        XCTAssertFalse(odd.contains(":"), odd)
        let swapped = SongStore.fileName(for: "spotify:local:Some:Artist/Tea:12")
        XCTAssertNotEqual(odd, swapped, "two ids never share a file")
        let hidden = SongStore.fileName(for: "..")
        XCTAssertFalse(hidden.hasPrefix("."), hidden)
        let empty = SongStore.fileName(for: "")
        XCTAssertNotEqual(empty, ".json")
        let long = SongStore.fileName(for: String(repeating: "toast/", count: 100))
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        // An odd id saves in the folder itself and reads back.
        let store = SongStore(directory: dir)
        let file = song(id: "spotify:local:Some/Artist:Tea:12")
        try store.save(file)
        let loaded = store.load("spotify:local:Some/Artist:Tea:12")
        XCTAssertEqual(loaded, file)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, [odd])
    }

    func testNothingIsWrittenUntilASave() throws {
        let store = SongStore(directory: dir)
        XCTAssertNil(store.load("0kettle0sings0abc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "loading makes no folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path))
        try store.save(song(id: "0kettle0sings0abc"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("0kettle0sings0abc.json").path))
        let path = SongStore.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/In Strum Meants/Songs"), path)
    }
}
