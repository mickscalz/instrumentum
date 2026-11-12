import XCTest
import Metal
import SwiftUI
import AppKit
@testable import InStrumApp
@testable import InStrumCore

/// Hold the moment in the app (Small Wins spec §4, Task 7; Review focus 3 and 6): the hourglass held down, its
/// double-click and ⌘⇧H reach the director's controls, and the pedal setting steers it. The renders draw a world as the
/// canvas does (the director under the model's controls, the renderer stepped by `visualDt`) at 640 × 360. Assertions are
/// plain statements over named locals, so the type-checker finishes quickly in CI.
@MainActor
final class HoldTheMomentTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> AppModel {
        AppModel(engine: FakeEngine(), store: SettingsStore(directory: dir), launchGuard: LaunchGuard(directory: dir),
                 presets: PresetStore(directory: dir.appendingPathComponent("Presets")))
    }

    // MARK: - The controls

    func testThePadHoldsWhilePressed() {
        let m = makeModel()
        XCTAssertFalse(m.sceneControls.holdRequested)
        m.setHoldPressed(true)
        XCTAssertTrue(m.holdPressed)
        XCTAssertTrue(m.sceneControls.holdRequested, "held while pressed")
        m.setHoldPressed(false)
        XCTAssertFalse(m.sceneControls.holdRequested, "let go")
        XCTAssertFalse(m.holdLatched)
        XCTAssertEqual(HoldPad.help, "Hold the moment: press and hold, or double-click to keep it held (⌘⇧H)")
    }

    func testDoubleClickAndShortcutToggle() {
        let m = makeModel()
        m.toggleHold()
        XCTAssertTrue(m.holdLatched)
        XCTAssertTrue(m.sceneControls.holdRequested, "latched")
        m.setHoldPressed(true)
        m.toggleHold()
        XCTAssertFalse(m.holdLatched)
        XCTAssertTrue(m.sceneControls.holdRequested, "still pressed")
        m.setHoldPressed(false)
        XCTAssertFalse(m.sceneControls.holdRequested, "a latch and a press hold until both let go")
        m.setHoldPressed(true)
        m.toggleHold()
        m.setHoldPressed(false)
        XCTAssertTrue(m.sceneControls.holdRequested, "latched while pressed: still held")
        m.toggleHold()
        XCTAssertFalse(m.sceneControls.holdRequested)
        XCTAssertEqual(HoldMenuItems.shortcut.key.character, "h")
        XCTAssertEqual(HoldMenuItems.shortcut.modifiers, [.command, .shift])
    }

    /// The hourglass lights from the director's report, however the hold was asked for.
    func testTheHourglassLightsWhileHeld() {
        let m = makeModel()
        XCTAssertFalse(m.holdShown)
        m.noteSceneReport(SceneReport(holding: true))
        XCTAssertTrue(m.holdShown)
        m.noteSceneReport(SceneReport(holding: false))
        XCTAssertFalse(m.holdShown)
    }

    /// The setting reaches the director through the model's controls: the soft pedal holds by default, the sostenuto
    /// pedal once chosen, and neither under Off. The setting is saved.
    func testThePedalSettingSteersTheDirector() {
        let m = makeModel()
        func holds(_ controller: UInt8) -> Bool {
            let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            d.controls = m.sceneControls
            _ = m.drainEvents()
            m.handleMIDI(bytes: [0xB0, controller, 127], time: 1)
            d.handle(m.drainEvents(), at: 1)
            _ = d.step(dt: 1.0 / 60, t: 1, quality: .lite)
            let held = d.holding
            m.handleMIDI(bytes: [0xB0, controller, 0], time: 2)
            _ = m.drainEvents()
            return held
        }
        XCTAssertTrue(holds(67), "the soft pedal by default")
        XCTAssertFalse(holds(66))
        m.setHoldPedal(.sostenuto)
        XCTAssertTrue(holds(66))
        XCTAssertFalse(holds(67))
        m.setHoldPedal(.off)
        XCTAssertFalse(holds(67), "under Off, the soft pedal doesn't hold")
        XCTAssertFalse(holds(66))
        XCTAssertEqual(makeModel().holdPedal, .off, "saved")
        XCTAssertEqual(HoldPedal.allCases.map(\.displayName), ["Soft pedal", "Sostenuto pedal", "Off"])
    }

    // MARK: - The renders

    /// A world drawn as the canvas draws it, at 60 frames a second: the director stepped under its controls, the
    /// renderer by the director's `visualDt`, and each capture with its exposure.
    @MainActor
    final class Rig {
        let director: SceneDirector
        let preview: PreviewRenderer
        var lake: MoonlitLakeRenderer?
        var lounge: SpaceshipLoungeRenderer?
        var t = 0.0

        init(world: String, sky: SkySettings) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
            preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
            director = SceneDirector(themeID: world, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            let start = Date(timeIntervalSince1970: 1_793_000_000)
            director.clock = { start }
            director.sky.reset(settings: sky)
            if world == MoonlitLakeModel.id { lake = MoonlitLakeRenderer(device: device) }
            if world == SpaceshipLoungeModel.id { lounge = SpaceshipLoungeRenderer(device: device) }
            XCTAssertTrue(lake != nil || lounge != nil, "a renderer")
        }

        /// Steps `frames` frames.
        func step(_ frames: Int = 1) {
            let size = CGSize(width: 640, height: 360)
            for _ in 0..<frames {
                t += 1.0 / 60
                let frame = director.step(dt: 1.0 / 60, t: t, quality: .high)
                let dt = director.visualDt
                if let f = frame as? LakeFrame {
                    lake?.update(f, params: director.parameters, quality: .high, gentle: false, dt: dt, size: size)
                } else if let f = frame as? LoungeFrame {
                    lounge?.update(f, params: director.parameters, quality: .high, gentle: false, dt: dt, size: size)
                }
            }
        }

        func play(_ notes: [UInt8], velocity: Float = 0.9) {
            var events: [PerformanceEvent] = notes.map { PerformanceEvent.noteOn(note: $0, velocity: velocity) }
            if notes.count >= 3 { events.append(.chord(notes: notes)) }
            director.handle(events, at: t)
        }

        func release(_ notes: [UInt8]) {
            let events: [PerformanceEvent] = notes.map { PerformanceEvent.noteOff(note: $0) }
            director.handle(events, at: t)
        }

        func capture() throws -> CGImage {
            var renderer: ThemeRenderer?
            if let lake { renderer = lake } else if let lounge { renderer = lounge }
            let r = try XCTUnwrap(renderer)
            return try XCTUnwrap(preview.capture(r, exposureScale: director.exposureScale))
        }
    }

    /// Night (the frozen clock at 22:00) with rain falling, settled from the first frame.
    static func rainyNight() -> SkySettings {
        var s = SkySettings()
        s.timeMode = .frozen
        s.frozenHour = 22
        s.weatherMode = .pick
        s.weather = .rain
        return s
    }

    /// The rainy night lake and the lounge (its warp in flight): over a held second nothing moves on screen; a second
    /// after release, it does.
    func testAHeldMomentStandsStill() throws {
        let m = makeModel()
        for world in [MoonlitLakeModel.id, SpaceshipLoungeModel.id] {
            let rig = try Rig(world: world, sky: Self.rainyNight())
            rig.step(30)
            let chord: [UInt8] = [52, 59, 64, 67, 71]
            rig.play(chord)
            rig.step(48)
            rig.release(chord)
            rig.step(42)
            m.toggleHold()
            rig.director.controls = m.sceneControls
            rig.step()
            let first = try rig.capture()
            rig.step(60)
            let held = try rig.capture()
            m.toggleHold()
            rig.director.controls = m.sceneControls
            rig.step(60)
            let after = try rig.capture()
            let still = PreviewRenderer.difference(first, held)
            let moved = PreviewRenderer.difference(held, after)
            XCTAssertLessThan(still, 1e-4, "\(world): a held second (\(still))")
            XCTAssertGreaterThan(moved, 1e-3, "\(world): a second after release (\(moved))")
        }
    }

    /// A chord played into a held moment changes the frame (the lake's rings and fireflies bloom at once), and then that
    /// moment holds: 0.1 s and 1.1 s after it, the frames match.
    func testNotesFillAHeldMoment() throws {
        let rig = try Rig(world: MoonlitLakeModel.id, sky: Self.rainyNight())
        rig.step(60)
        rig.director.controls.holdRequested = true
        rig.step(6)
        let before = try rig.capture()
        let chord: [UInt8] = [48, 55, 60, 64, 67]
        rig.play(chord)
        rig.step(6)
        let soon = try rig.capture()
        rig.step(60)
        let later = try rig.capture()
        let filled = PreviewRenderer.difference(before, soon)
        let held = PreviewRenderer.difference(soon, later)
        XCTAssertGreaterThan(filled, 2e-4, "the chord shows (\(filled))")
        XCTAssertLessThan(held, 1e-4, "and holds (\(held))")
    }

    /// Time eases back in: the first frames after release barely move, the frames 0.6 s on move at full speed.
    func testTheHoldEasesOut() throws {
        let rig = try Rig(world: MoonlitLakeModel.id, sky: Self.rainyNight())
        rig.step(60)
        rig.director.controls.holdRequested = true
        rig.step(30)
        rig.director.controls.holdRequested = false
        rig.step(2)
        let one = try rig.capture()
        rig.step()
        let two = try rig.capture()
        rig.step(34)
        let late = try rig.capture()
        rig.step()
        let later = try rig.capture()
        let early = PreviewRenderer.difference(one, two)
        let full = PreviewRenderer.difference(late, later)
        XCTAssertLessThan(early, full, "frames 1–2 after release (\(early)) move less than frames 36–37 (\(full))")
    }

    /// Review focus 6: no flash on screen while time is held. Held as lightning flashes over the stormy lake, the
    /// weather's exposure boost (through its flash limiter) stays where it was for two seconds.
    func testNoFlashesOnScreenWhileHeld() throws {
        var stormy = Self.rainyNight()
        stormy.weather = .storm
        let rig = try Rig(world: MoonlitLakeModel.id, sky: stormy)
        var lit: Float = 0
        var frames = 0
        while lit < 0.3, frames < 40 * 60 {
            rig.step()
            lit = rig.director.lastSky?.lightning ?? 0
            frames += 1
        }
        XCTAssertGreaterThan(lit, 0.3, "a flash within 40 s")
        rig.director.controls.holdRequested = true
        rig.step()
        let boost = try XCTUnwrap(rig.lake).weather.exposureBoost
        var changed = 0
        for _ in 0..<120 {
            rig.step()
            let now = try XCTUnwrap(rig.lake).weather.exposureBoost
            if now != boost { changed += 1 }
        }
        XCTAssertEqual(changed, 0, "the boost holds at \(boost)")
    }
}

/// The look of hold the moment and the sleep timer (PREVIEW_DIR, for the looks job): the main bar's hourglass and moon
/// beside their neighbours, the hourglass dark and lit, the moon off and running; and the Touch section's new row.
@MainActor
final class SmallWinsBarPreviewTests: XCTestCase {
    func testWriteBarPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let m = AppModel(engine: FakeEngine(), store: SettingsStore(directory: tmp), launchGuard: LaunchGuard(directory: tmp),
                         presets: PresetStore(directory: tmp.appendingPathComponent("Presets")))
        m.toastDuration = 60
        let size = CGSize(width: 720, height: 200)
        let plain = try XCTUnwrap(Self.snapshot(Self.bar(m), size: size))
        try PreviewRenderer.writePNG(plain, to: url.appendingPathComponent("bar-plain.png"))
        m.noteSceneReport(SceneReport(holding: true))
        m.sleepRemaining = 23 * 60
        let lit = try XCTUnwrap(Self.snapshot(Self.bar(m), size: size))
        try PreviewRenderer.writePNG(lit, to: url.appendingPathComponent("bar-held-sleeping.png"))
        m.sleepRemaining = 45
        m.noteSceneReport(SceneReport(holding: false))
        m.showToast(AppModel.awakeText, symbol: "sunrise")
        let awake = try XCTUnwrap(Self.snapshot(Self.bar(m), size: size))
        try PreviewRenderer.writePNG(awake, to: url.appendingPathComponent("bar-seconds-awake.png"))
        XCTAssertGreaterThan(PreviewRenderer.difference(plain, lit), 0.0005, "the hourglass lights and the moon fills")
        let settings = try XCTUnwrap(Self.snapshot(SettingsPopover(model: m).environment(\.colorScheme, .dark),
                                                   size: CGSize(width: 420, height: 620)))
        try PreviewRenderer.writePNG(settings, to: url.appendingPathComponent("sound-settings.png"))
    }

    /// The sleep fade's light: Golden Hour Beach at dim 0, ½ and 1 (the sun sliding from 5° toward −14°, a stop darker).
    func testWriteSleepDimPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        var sky = SkySettings()
        sky.weatherMode = .pick
        sky.weather = .clear
        var means: [Double] = []
        for dim in [0.0, 0.5, 1.0] {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [3], sky: sky,
                                                     controls: { _ in SceneControls(sleepDim: dim) }).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("sleep-dim-\(Int(dim * 100)).png"))
            means.append(PreviewRenderer.stats(image).meanLuminance)
        }
        XCTAssertGreaterThan(means[0], means[1], "darker at half")
        XCTAssertGreaterThan(means[1], means[2], "darker still at the end")
    }

    /// The right end of the main bar over a night-blue canvas, with the toast where the app puts it.
    static func bar(_ m: AppModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                KeepButton(model: m)
                HoldPad(model: m)
                SleepMenu(model: m)
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
