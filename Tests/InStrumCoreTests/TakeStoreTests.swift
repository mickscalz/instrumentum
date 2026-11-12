import XCTest
@testable import InStrumCore

/// Where kept takes go (Small Wins spec §2, Task 1): `~/Music/In Strum Meants/Takes/YYYY-MM-DD HH.mm — <name>.mid`, with
/// a `.json` note beside it. The folder is made on the first keep, and a keep never overwrites another.
final class TakeStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Takes")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private let melbourne = TimeZone(identifier: "Australia/Melbourne")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = melbourne
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// A JSON object's keys (none for anything else).
    private func keys(_ value: Any?) -> Set<String> { Set((value as? [String: Any])?.keys.map { $0 } ?? []) }

    private func note(seconds: Double = 12.25) -> TakeNote {
        TakeNote(setID: "moonlit-lake", worldID: "moonlit-lake",
                 instrument: .init(patchID: "felt-glass", name: "Felt Glass", dials: ["Tone": 0.5]),
                 sky: .init(city: "Melbourne", localTime: "21:07", weather: "clear", sunAltitude: -12.5, moonPhase: 0.4),
                 key: AmbienceKey(root: 2, major: true), appVersion: "dev", seconds: seconds)
    }

    func testFileNames() throws {
        let at = date(2026, 11, 4, 21, 7)
        XCTAssertEqual(TakeStore.fileStem(title: "Moonlit Lake", date: at, timeZone: melbourne), "2026-11-04 21.07 — Moonlit Lake")
        XCTAssertEqual(TakeStore.fileStem(title: "AC/DC: Live", date: at, timeZone: melbourne), "2026-11-04 21.07 — AC-DC- Live")
        XCTAssertEqual(TakeStore.fileStem(title: "  ", date: at, timeZone: melbourne), "2026-11-04 21.07 — Take", "a name is never blank")
        let store = TakeStore(directory: dir)
        let first = try store.save(midi: Data([1, 2, 3]), note: note(), title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(first.lastPathComponent, "2026-11-04 21.07 — Moonlit Lake.mid")
        let second = try store.save(midi: Data([4, 5, 6]), note: note(), title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(second.lastPathComponent, "2026-11-04 21.07 — Moonlit Lake 2.mid", "never over the first")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5, 6]))
        let third = try store.save(midi: Data([7]), note: note(), title: "Moonlit Lake", at: at, timeZone: melbourne)
        XCTAssertEqual(third.lastPathComponent, "2026-11-04 21.07 — Moonlit Lake 3.mid")
    }

    func testTheFolderIsMadeOnTheFirstKeep() throws {
        let store = TakeStore(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing until a keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path))
        let url = try store.save(midi: Data([0x4D]), note: note(), title: "Spaceship Lounge", at: date(2026, 1, 2, 3, 4), timeZone: melbourne)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["2026-01-02 03.04 — Spaceship Lounge.json", "2026-01-02 03.04 — Spaceship Lounge.mid"])
        XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
        XCTAssertTrue(TakeStore.defaultDirectory.path.hasSuffix("Music/In Strum Meants/Takes"), TakeStore.defaultDirectory.path)
    }

    func testTheNotesFields() throws {
        let store = TakeStore(directory: dir)
        let url = try store.save(midi: Data([0]), note: note(), title: "Moonlit Lake", at: date(2026, 11, 4, 21, 7), timeZone: melbourne)
        let json = try Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(keys(object), ["setID", "worldID", "instrument", "sky", "key", "appVersion", "seconds"])
        XCTAssertEqual(keys(object["instrument"]), ["patchID", "name", "dials"])
        XCTAssertEqual(keys(object["sky"]), ["city", "localTime", "weather", "sunAltitude", "moonPhase"])
        XCTAssertEqual(keys(object["key"]), ["root", "major"])
        XCTAssertEqual(try JSONDecoder().decode(TakeNote.self, from: json), note(), "it reads back as written")
        // With no set, no sky, no key and a plugin: those keys are absent.
        var bare = note()
        bare.setID = nil
        bare.sky = nil
        bare.key = nil
        bare.instrument = .init(patchID: nil, name: "Splice INSTRUMENT", dials: [:])
        let data = try TakeStore.encode(bare)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(keys(fields), ["worldID", "instrument", "appVersion", "seconds"])
        XCTAssertEqual(keys(fields["instrument"]), ["name", "dials"])
        XCTAssertEqual(try JSONDecoder().decode(TakeNote.self, from: data), bare)
    }
}
