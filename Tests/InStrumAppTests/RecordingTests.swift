import XCTest
import SwiftUI
@testable import InStrumApp
@testable import InStrumAudio
@testable import InStrumCore

/// A sound engine that records nothing: it notes where it was asked to record (and makes the file there, as the real
/// one does when a pass begins) and says it wrote `framesToWrite`.
final class RecorderStubEngine: InstrumentEngine {
    var audioLevel: Float = 0
    var masterVolume: Float = 0.8
    var sleepGain: Float = 1
    var bufferFrames: UInt32 = 128
    var ambienceVolume: Float = 0.25
    var ambienceEnabled = true
    var outputSampleRate: Double = 48_000
    var panics = 0
    func start() throws {}
    func loadInstrument(_ choice: InstrumentChoice) async throws {}
    func currentInstrumentState() -> Data? { nil }
    func send(_ bytes: [UInt8]) {}
    func panic() { panics += 1 }
    // The Record button
    var urls: [URL] = []
    var beginError: Error?
    var framesToWrite = 0
    var ends = 0
    var recordingSeconds: Double = 0
    func beginInstrumentRecording(to url: URL) throws {
        if let beginError { throw beginError }
        urls.append(url)
        try Data([0]).write(to: url)
    }
    func endInstrumentRecording() -> Int {
        ends += 1
        return framesToWrite
    }
}

/// The Record button: one click records the instrument to a WAV file in the recordings folder, a second stops and
/// saves it, with a toast each time. It stops itself at an hour; a panic leaves it running.
@MainActor
final class RecordingTests: XCTestCase {
    var dir: URL!
    var engine: RecorderStubEngine!
    var store: SettingsStore!
    var recordings: URL { dir.appendingPathComponent("Recordings", isDirectory: true) }
    let date = Date(timeIntervalSince1970: 1_794_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = RecorderStubEngine()
        store = SettingsStore(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        let m = AppModel(engine: engine, store: store, launchGuard: LaunchGuard(directory: dir),
                         presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
        m.recordingsDirectory = recordings
        m.toastDuration = 60   // the toasts stay up while a test reads them
        m.setTheme(MoonlitLakeModel.id)
        return m
    }

    func testRecordThenStopSavesAndToasts() throws {
        let m = makeModel()
        m.toggleRecording(at: date)
        let recording = m.isRecording
        let startText = m.toast?.text
        let startSymbol = m.toast?.symbol
        let ticking = m.recordingTicker != nil
        let watchingQuit = m.recordingQuitObserver != nil
        let url = try XCTUnwrap(engine.urls.first)
        engine.framesToWrite = 48_000 * 64
        m.toggleRecording()
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent().path
        let expected = TakeStore.fileStem(title: "Moonlit Lake", date: date, timeZone: .current) + ".wav"
        let kept = FileManager.default.fileExists(atPath: url.path)
        let tickingAfter = m.recordingTicker != nil
        let watchingQuitAfter = m.recordingQuitObserver != nil
        XCTAssertTrue(recording)
        XCTAssertEqual(startText, "Recording")
        XCTAssertEqual(startSymbol, "record.circle.fill")
        XCTAssertTrue(ticking)
        XCTAssertTrue(watchingQuit)
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(m.toast?.text, "Saved · 1:04")
        XCTAssertEqual(m.toast?.symbol, "checkmark.circle.fill")
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertEqual(folder, recordings.path)
        XCTAssertTrue(name.hasSuffix(" — Moonlit Lake.wav"), name)
        XCTAssertEqual(name, expected)
        XCTAssertTrue(kept, "a saved recording stays")
        XCTAssertEqual(engine.ends, 1)
        XCTAssertFalse(tickingAfter)
        XCTAssertFalse(watchingQuitAfter)
    }

    func testNothingIsWrittenBeforeRecord() {
        let m = makeModel()
        for i in 0..<20 {
            m.handleMIDI(bytes: [0x90, UInt8(48 + i), 80], time: Double(i) * 0.2)
            m.handleMIDI(bytes: [0x80, UInt8(48 + i), 64], time: Double(i) * 0.2 + 0.1)
        }
        m.recordingTick(seconds: 4000)   // a stray tick while idle does nothing
        m.panic()
        let folder = FileManager.default.fileExists(atPath: recordings.path)
        let asked = engine.urls.count
        XCTAssertFalse(folder, "no folder until Record")
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(engine.ends, 0)
    }

    func testAClashAddsANumber() {
        let m = makeModel()
        engine.framesToWrite = 48_000
        for _ in 0..<3 {
            m.toggleRecording(at: date)
            m.toggleRecording(at: date)
        }
        let names = engine.urls.map(\.lastPathComponent)
        let stem = TakeStore.fileStem(title: "Moonlit Lake", date: date, timeZone: .current)
        XCTAssertEqual(names, [stem + ".wav", stem + " 2.wav", stem + " 3.wav"])
        XCTAssertEqual(m.toast?.text, "Saved · 0:01")
    }

    func testZeroFramesSaysNothingRecorded() throws {
        let m = makeModel()
        engine.framesToWrite = 0
        m.toggleRecording(at: date)
        let url = try XCTUnwrap(engine.urls.first)
        let existed = FileManager.default.fileExists(atPath: url.path)
        m.toggleRecording()
        let exists = FileManager.default.fileExists(atPath: url.path)
        XCTAssertTrue(existed)
        XCTAssertFalse(exists, "an empty recording is deleted")
        XCTAssertEqual(m.toast?.text, "Nothing recorded")
        XCTAssertFalse(m.isRecording)
    }

    func testAStartErrorToastsAndStaysIdle() throws {
        struct Refused: Error {}
        let m = makeModel()
        engine.beginError = Refused()
        m.toggleRecording(at: date)
        let refusedText = m.toast?.text
        let refusedSymbol = m.toast?.symbol
        let refusedRecording = m.isRecording
        // A file where the folder goes says the same, and the engine is never asked.
        engine.beginError = nil
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        m.recordingsDirectory = blocker.appendingPathComponent("Recordings", isDirectory: true)
        m.toggleRecording(at: date)
        let blockedText = m.toast?.text
        let blockedRecording = m.isRecording
        let asked = engine.urls.count
        XCTAssertEqual(refusedText, "Couldn't start recording")
        XCTAssertEqual(refusedSymbol, "exclamationmark.triangle")
        XCTAssertFalse(refusedRecording)
        XCTAssertEqual(blockedText, "Couldn't start recording")
        XCTAssertFalse(blockedRecording)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(engine.ends, 0)
        XCTAssertNil(m.recordingTicker)
    }

    /// The ticker hands over the engine's running time; here the tests hand it over instead of waiting an hour.
    func testItStopsItselfAfterAnHour() throws {
        let m = makeModel()
        engine.framesToWrite = 48_000 * 3600
        m.toggleRecording(at: date)
        m.recordingTick(seconds: 59.7)
        let shown = m.recordingSeconds
        m.recordingTick(seconds: 3599.9)
        let nearlyAnHour = m.isRecording
        let shownNearlyAnHour = m.recordingSeconds
        m.recordingTick(seconds: 3600)
        let longest = AppModel.maxRecordingSeconds
        XCTAssertEqual(shown, 59, "whole seconds, for the button")
        XCTAssertTrue(nearlyAnHour)
        XCTAssertEqual(shownNearlyAnHour, 3599)
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(engine.ends, 1)
        XCTAssertEqual(m.toast?.text, "Saved · 60:00")
        XCTAssertEqual(longest, 3600)
        XCTAssertEqual(m.recordingSeconds, 0)
    }

    func testPanicDoesNotStopARecording() {
        let m = makeModel()
        m.toggleRecording(at: date)
        let before = engine.panics
        m.panic()
        let after = engine.panics
        let recording = m.isRecording
        XCTAssertEqual(after, before + 1)
        XCTAssertTrue(recording)
        XCTAssertEqual(engine.ends, 0)
        m.toggleRecording()
        XCTAssertEqual(engine.ends, 1)
    }

    func testTheShortcutIsCommandR() {
        let key = RecordMenuItems.shortcut.key.character
        let modifiers = RecordMenuItems.shortcut.modifiers
        XCTAssertEqual(key, "r")
        XCTAssertEqual(modifiers, .command)
        XCTAssertEqual(RecordButton.help, "Record what you play (⌘R)")
    }
}
