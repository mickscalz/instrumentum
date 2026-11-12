import XCTest
import SwiftUI
import AppKit
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

/// Keep that in the app (Small Wins spec §2, Task 2; Review focus 2): the bookmark, ⌘K, Keep the Last 10 Minutes and
/// the key gesture write a MIDI file and its note to the takes folder, and say so in a toast.
@MainActor
final class KeepThatTests: XCTestCase {
    var dir: URL!
    var engine: FakeEngine!
    var store: SettingsStore!
    var takes: URL { dir.appendingPathComponent("Takes", isDirectory: true) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeEngine()
        store = SettingsStore(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        let m = AppModel(engine: engine, store: store, launchGuard: LaunchGuard(directory: dir),
                         presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
        m.takeStore = TakeStore(directory: takes)
        m.toastDuration = 60   // the toasts stay up while a test reads them
        return m
    }

    /// 0.25 s notes, one every 0.5 s from `from` while they start by `to`, through the MIDI input.
    private func play(_ m: AppModel, from: Double, to: Double, note: UInt8 = 60) {
        var i = 0
        while from + Double(i) * 0.5 <= to + 1e-9 {
            let t = from + Double(i) * 0.5
            m.handleMIDI(bytes: [0x90, note, 90], time: t)
            m.handleMIDI(bytes: [0x80, note, 64], time: t + 0.25)
            i += 1
        }
    }

    /// The top three black keys tapped together twice, through the MIDI input.
    private func gesture(_ m: AppModel, _ keys: [UInt8], at t: Double) {
        for tap in [t, t + 0.6] {
            for (i, k) in keys.enumerated() { m.handleMIDI(bytes: [0x90, k, 100], time: tap + 0.01 * Double(i)) }
            for k in keys { m.handleMIDI(bytes: [0x80, k, 64], time: tap + 0.1) }
        }
    }

    private func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: takes.path)) ?? []).sorted() }

    private func kept() throws -> (midi: (name: String, bpm: Double, events: [TakeEvent]), note: TakeNote) {
        let mid = try XCTUnwrap(files().first { $0.hasSuffix(".mid") }, "no take kept")
        let url = takes.appendingPathComponent(mid)
        let data = try Data(contentsOf: url)
        let midi = try XCTUnwrap(StandardMIDIFile.read(data))
        let note = try JSONDecoder().decode(TakeNote.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
        return (midi, note)
    }

    func testKeepThatSavesTheLastTake() throws {
        let m = makeModel()
        m.setTheme(MoonlitLakeModel.id)
        play(m, from: 100, to: 110)
        m.keepThat(at: 120)
        XCTAssertEqual(files().count, 2, "the .mid and its .json")
        let mid = try XCTUnwrap(files().first { $0.hasSuffix(".mid") })
        XCTAssertTrue(mid.hasSuffix(" — Moonlit Lake.mid"), mid)
        XCTAssertTrue(files().contains(mid.replacingOccurrences(of: ".mid", with: ".json")))
        let (midi, note) = try kept()
        XCTAssertEqual(midi.name, "Moonlit Lake")
        XCTAssertEqual(midi.bpm, 120, "no set: 120")
        XCTAssertEqual(midi.events.count, 42, "21 notes")
        XCTAssertEqual(midi.events.last?.time ?? 0, 10.25, accuracy: 0.001)
        XCTAssertEqual(note.seconds, 12.25, accuracy: 1e-9)
        XCTAssertEqual(m.toast?.text, "Kept · 0:12")
        XCTAssertEqual(m.toast?.symbol, "bookmark.fill")
        XCTAssertEqual(AppModel.keptLength(252.4), "4:12")
        XCTAssertEqual(AppModel.keptLength(59.6), "1:00")
    }

    func testTheTempoIsTheSetsCredit() async throws {
        let m = makeModel()
        await m.applySet("moonlit-lake")
        XCTAssertEqual(m.takeTempo(), 84, "Come Back to Earth")
        XCTAssertEqual(m.takeTitle(), "Moonlit Lake")
        play(m, from: 100, to: 101)
        m.keepThat(at: 105)
        let bpm = try kept().midi.bpm
        XCTAssertEqual(StandardMIDIFile.microseconds(bpm: bpm), 714_286, "84 BPM in the file")
        m.setTheme(GoldenHourBeachModel.id)
        XCTAssertEqual(m.takeTempo(), 120, "the set's world isn't showing")
        XCTAssertEqual(m.takeTitle(), "Golden Hour Beach")
        await m.applySet("tea-house-snow")
        XCTAssertEqual(m.takeTempo(), 120, "a set born from its place has no song")
        XCTAssertEqual(m.takeTitle(), "Tea House Snow")
    }

    func testNothingToKeep() {
        let m = makeModel()
        m.keepThat(at: 50)
        XCTAssertEqual(m.toast?.text, "Nothing to keep yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: takes.path), "no folder")
        m.keepLastTenMinutes(at: 50)
        XCTAssertEqual(m.toast?.text, "Nothing to keep yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: takes.path))
    }

    func testAFailedSaveSaysSo() throws {
        let m = makeModel()
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        m.takeStore = TakeStore(directory: blocker.appendingPathComponent("Takes"))   // a file stands where the folder goes
        play(m, from: 1, to: 2)
        m.keepThat(at: 5)
        XCTAssertEqual(m.toast?.text, "Couldn't save the take")
    }

    /// The gesture keeps the take before it, without itself, once the main actor gets a turn.
    func testTheGestureKeepsWithoutItself() async throws {
        let m = makeModel()
        m.setTheme(MoonlitLakeModel.id)
        play(m, from: 100, to: 110)
        gesture(m, [102, 104, 106], at: 115)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files().filter { $0.hasSuffix(".mid") }.count, 1, "one take")
        let (midi, note) = try kept()
        XCTAssertFalse(midi.events.contains {
            switch $0.message {
            case let .noteOn(_, n, _), let .noteOff(_, n, _): return n > 100
            default: return false
            }
        }, "none of the gesture's notes")
        XCTAssertEqual(note.seconds, 12.25, accuracy: 1e-9, "ending 2 s after the music, before the first tap")
        XCTAssertEqual(m.toast?.text, "Kept · 0:12")
    }

    /// Review focus 2: the gesture lives on the keyboard's own top three black keys.
    func testTheGestureFollowsTheKeyboardLayout() async throws {
        let m = makeModel()
        m.setKeyboardRange(.keys61)
        play(m, from: 10, to: 12)
        gesture(m, [102, 104, 106], at: 20)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(files().isEmpty, "on a 61 those keys are out of range: just notes")
        gesture(m, [90, 92, 94], at: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files().filter { $0.hasSuffix(".mid") }.count, 1, "C2–C7's top three black keys keep")
        // The layout comes back at the next launch, and the gesture with it.
        let again = makeModel()
        XCTAssertEqual(again.keyboardRange, .keys61)
        again.play(from: 40, to: 41)
        gesture(again, [90, 92, 94], at: 45)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files().filter { $0.hasSuffix(".mid") }.count, 2)
    }

    func testKeepTheLastTenMinutes() throws {
        let m = makeModel()
        play(m, from: 0, to: 30)
        play(m, from: 300, to: 310, note: 64)
        m.keepLastTenMinutes(at: 320)
        let (midi, note) = try kept()
        XCTAssertEqual(note.seconds, 312.25, accuracy: 1e-9, "0 to 312.25 s, the silence and all")
        XCTAssertEqual(midi.events.count, 2 * (61 + 21))
        XCTAssertEqual(m.toast?.text, "Kept · 5:12")
        m.keepThat(at: 320)
        XCTAssertEqual(m.toast?.text, "Kept · 0:12", "while Keep That keeps the last take alone")
    }

    func testTheNoteCarriesTheMoment() async throws {
        let m = makeModel()
        await m.applySet("moonlit-lake")
        var sky = m.skySettings
        sky.cityID = "melbourne"
        m.setSky(sky)
        var state = SkyState()
        state.hourOfDay = 21.5
        state.weather = .rain
        state.moonPhase = 0.25
        state.sun = SkyDirection(azimuth: 250, altitude: -21)
        m.noteSceneReport(SceneReport(holding: false, sky: state, key: AmbienceKey(root: 2, major: true)))
        play(m, from: 1, to: 3)
        m.keepThat(at: 6)
        let note = try kept().note
        XCTAssertEqual(note.worldID, MoonlitLakeModel.id)
        XCTAssertEqual(note.setID, "moonlit-lake")
        XCTAssertEqual(note.instrument.patchID, "felt-glass")
        XCTAssertEqual(note.instrument.name, "Felt Glass")
        XCTAssertEqual(note.sky, TakeNote.Sky(city: "Melbourne", localTime: "21:30", weather: "rain", sunAltitude: -21, moonPhase: 0.25))
        XCTAssertEqual(note.key, AmbienceKey(root: 2, major: true))
        XCTAssertFalse(note.appVersion.isEmpty, "the app's version, or dev")
        XCTAssertEqual(note.seconds, 4.25, accuracy: 1e-9)
    }

    /// Nothing reaches the disk until a keep: 2,000 notes leave no folder behind.
    func testNothingIsWrittenUntilKeep() {
        let m = makeModel()
        for i in 0..<1_000 {
            m.handleMIDI(bytes: [0x90, UInt8(40 + i % 40), 80], time: Double(i) * 0.2)
            m.handleMIDI(bytes: [0x80, UInt8(40 + i % 40), 64], time: Double(i) * 0.2 + 0.1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: takes.path))
        XCTAssertEqual(m.live.withLockUnchecked { $0.keeper.count }, 2_000, "all of it in memory")
    }

    /// A panic lets go of every key in the take, as the instrument heard it.
    func testAPanicEndsTheNotesInTheTake() throws {
        let m = makeModel()
        let now = ProcessInfo.processInfo.systemUptime
        m.handleMIDI(bytes: [0x90, 60, 90], time: now)
        m.panic()
        let take = try XCTUnwrap(m.live.withLockUnchecked { $0.keeper.lastTake(endingAt: now + 5) })
        XCTAssertEqual(take.events.filter { if case .noteOff = $0.message { return true }; return false }.count, 1)
    }

    func testTheShortcutIsCommandK() {
        XCTAssertEqual(KeepMenuItems.shortcut.key.character, "k")
        XCTAssertEqual(KeepMenuItems.shortcut.modifiers, .command)
        XCTAssertEqual(KeepButton.help, "Keep that: save your last take (⌘K)")
        XCTAssertEqual(SettingsPopover.keyboardLayoutCaption, "Tap its top three black keys together, twice, to keep a take.")
        XCTAssertEqual(KeyboardRange.allCases.map(\.displayName), ["88 keys (A0–C8)", "76 keys (E1–G7)", "61 keys (C2–C7)", "49 keys (C2–C6)"])
    }
}

private extension AppModel {
    /// 0.25 s notes every 0.5 s (a second model in a test).
    func play(from: Double, to: Double) {
        var t = from
        while t <= to + 1e-9 {
            handleMIDI(bytes: [0x90, 60, 90], time: t)
            handleMIDI(bytes: [0x80, 60, 64], time: t + 0.25)
            t += 0.5
        }
    }
}

/// The look of Keep that (PREVIEW_DIR, for the looks job): the main bar's bookmark beside its neighbours, plain and
/// filled while the "Kept · 4:12" toast shows over the canvas.
@MainActor
final class KeepThatPreviewTests: XCTestCase {
    func testWriteKeepPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = AppModel(engine: FakeEngine(), store: SettingsStore(directory: tmp), launchGuard: LaunchGuard(directory: tmp),
                         presets: PresetStore(directory: tmp.appendingPathComponent("Presets")))
        m.toastDuration = 60
        let plain = try XCTUnwrap(Self.snapshot(Self.scene(m), size: CGSize(width: 720, height: 200)))
        try PreviewRenderer.writePNG(plain, to: url.appendingPathComponent("keep-bar.png"))
        m.showToast("Kept · \(AppModel.keptLength(252))", symbol: "bookmark.fill")
        let kept = try XCTUnwrap(Self.snapshot(Self.scene(m), size: CGSize(width: 720, height: 200)))
        try PreviewRenderer.writePNG(kept, to: url.appendingPathComponent("keep-toast.png"))
        XCTAssertGreaterThan(PreviewRenderer.difference(plain, kept), 0.001, "the toast and the filled bookmark show")
    }

    /// The right end of the main bar over a night-blue canvas, with the toast where the app puts it.
    static func scene(_ m: AppModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                KeepButton(model: m)
                Button("Choose Instrument") {}
                Button {} label: { Label("Panic", systemImage: "speaker.slash.fill") }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(red: 0.13, green: 0.12, blue: 0.11))
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.10, green: 0.12, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .top) { ToastBanner(model: m) }
        }
        .frame(width: 720, height: 200)
        .environment(\.colorScheme, .dark)
    }

    static func snapshot<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}
