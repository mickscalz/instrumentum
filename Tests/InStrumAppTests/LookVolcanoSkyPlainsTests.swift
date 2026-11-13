import XCTest
import Metal
import CoreGraphics
@testable import InStrumApp
@testable import InStrumCore

/// The look job on Volcano Rim, Supercell Sky and Lightning Plains (13 Nov): the frames it is judged by, written to the
/// previews branch (PREVIEW_DIR), and the frame times of the three worlds against untouched ones in the same run.
/// Every frame name here is kept from the job's first run (current main) to its last, so each is compared with itself.
@MainActor
final class LookVSPPreviewTests: XCTestCase {
    private func folder() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Volcano Rim

    /// The Eruption through its life (a big moment of full strength at 2 s, so each frame is its age after it), a weak one,
    /// one under gentle visuals, one on Smooth, one held at golden hour; the lake's edge calm and lively.
    func testWriteVolcanoEruptionFrames() throws {
        let url = try folder()
        typealias T = VolcanoRimRendererTests
        func write(_ shot: T.VolcanoShot, _ name: String) throws {
            let image = try XCTUnwrap(shot.image)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
            var age = "-", height = "-"
            if let e = shot.frame.eruption {
                age = String(format: "%.2f", e.age)
                height = String(format: "%.0f", e.height)
            }
            let bombs = shot.frame.bombs.filter { $0.alive }.count
            let sparks = shot.renderer.sparkCount
            let clots = shot.renderer.clotCount
            print("VOLCANO_LOOK \(name): eruption age \(age), height \(height) m, bombs \(bombs), sparks \(sparks), clots \(clots)")
        }
        for age in [0.4, 1.0, 2.0, 3.5, 5.5, 7.5] {
            let shot = try T.renderVolcano(at: 2 + age, energy: 0.8, moments: [120: T.chord(1)], notes: T.playing,
                                           width: 1280, height: 720)
            try write(shot, "volcano-eruption-t\(age)")
        }
        try write(try T.renderVolcano(at: 3.2, energy: 0.5, moments: [120: T.chord(0.35)], notes: T.playing, width: 1280,
                                      height: 720), "volcano-eruption-weak-t1.2")
        try write(try T.renderVolcano(at: 3.2, gentle: true, energy: 0.8, moments: [120: T.chord(1)], notes: T.playing,
                                      width: 1280, height: 720), "volcano-eruption-gentle-t1.2")
        try write(try T.renderVolcano(at: 3.2, quality: .lite, energy: 0.8, moments: [120: T.chord(1)], notes: T.playing,
                                      width: 1280, height: 720), "volcano-eruption-smooth-t1.2")
        try write(try T.renderVolcano(at: 3.2, hold: .blueHour, energy: 0.8, moments: [120: T.chord(1)], notes: T.playing,
                                      width: 1280, height: 720), "volcano-eruption-bluehour-t1.2")
        // The lake's shore: calm (nobody playing) and lively.
        try write(try T.renderVolcano(at: 6, energy: 0.1, width: 1280, height: 720), "volcano-lake-edge-calm")
        try write(try T.renderVolcano(at: 6, energy: 1, tension: 0.4, notes: T.playing, width: 1280, height: 720),
                  "volcano-lake-edge-energy")
        try write(try T.renderVolcano(at: 6, quality: .lite, energy: 0.5, notes: T.playing, width: 1280, height: 720),
                  "volcano-lake-edge-smooth")
    }

    /// Magma Veins: calm (a few notes), lively (runs and chords), a moment's split, gentle visuals, Smooth.
    func testWriteVeinsFrames() throws {
        let url = try folder()
        typealias T = VolcanoRimRendererTests
        let veins: [String: ParamValue] = ["visual": .choice("Magma Veins")]
        func write(_ shot: T.VolcanoShot, _ name: String) throws {
            let image = try XCTUnwrap(shot.image)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        let calm: (Int) -> [UInt8] = { i in i % 70 == 0 ? [UInt8(48 + (i / 70) * 5 % 30)] : [] }
        let lively: (Int) -> [UInt8] = { i in
            if i % 60 == 0 { return [40, 47, 52, 59, 64] }
            if i % 12 == 0 { return [UInt8(55 + (i / 12) * 7 % 36)] }
            return []
        }
        try write(try T.renderVolcano(at: 4, values: veins, energy: 0.2, notes: calm, width: 1280, height: 720), "volcano-veins-calm")
        try write(try T.renderVolcano(at: 4, values: veins, energy: 0.9, notes: lively, width: 1280, height: 720),
                  "volcano-veins-energy")
        try write(try T.renderVolcano(at: 3, values: veins, energy: 0.7, moments: [150: T.chord(1)], notes: lively, width: 1280,
                                      height: 720), "volcano-veins-moment")
        try write(try T.renderVolcano(at: 3, values: veins, gentle: true, energy: 0.7, moments: [150: T.chord(1)], notes: lively,
                                      width: 1280, height: 720), "volcano-veins-gentle")
        try write(try T.renderVolcano(at: 4, values: veins, quality: .lite, energy: 0.9, notes: lively, width: 1280, height: 720),
                  "volcano-veins-smooth")
    }

    // MARK: - Supercell Sky

    /// The base where it meets the clear air under it: day, golden hour, blue hour and night, the approach, Smooth; and the
    /// core with each of its low layers left out in turn (the timing mask), to show which draws what under the base.
    func testWriteSupercellBaseFrames() throws {
        let url = try folder()
        typealias T = SupercellSkyRendererTests
        func write(_ image: CGImage?, _ name: String) throws {
            try PreviewRenderer.writePNG(try XCTUnwrap(image), to: url.appendingPathComponent("\(name).png"))
        }
        let cases: [(String, SupercellStage, SkyHold, Double, QualityLevel)] = [
            ("supercell-base-day", .core, .follow, 14.5, .high),
            ("supercell-base-dusk", .core, .goldenHour, 18.5, .high),
            ("supercell-base-bluehour", .core, .blueHour, 18.5, .high),
            ("supercell-base-night", .core, .deepNight, 18.5, .high),
            ("supercell-base-approach", .approach, .goldenHour, 18.5, .high),
            ("supercell-base-smooth", .core, .goldenHour, 18.5, .lite),
        ]
        for (name, stage, hold, hour, q) in cases {
            let shot = try T.renderCell(at: 5, stage: stage, hold: hold, skyHour: hour, quality: q, notes: T.playing,
                                        width: 1280, height: 720)
            try write(shot.image, name)
        }
        // Gentle visuals at night with the storm's light on (glows, no flashes).
        try write(try T.renderCell(at: 5, hold: .deepNight, gentle: true, notes: T.playing, width: 1280, height: 720, edit: { _, f in
            f.sky.stormFlash = 0.35
        }).image, "supercell-base-night-gentle")
        // Which layer draws what under the base (the timing mask: 1 tower, 8 wall cloud, 16 base, 32 hail and rain,
        // 64 inflow, funnel and dust, 128 the sky behind).
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let holds: [(SkyHold, String)] = [(.goldenHour, "dusk"), (.deepNight, "night")]
        let masks: [(UInt32, String)] = [(16, "no-base"), (32, "no-rain"), (64, "no-inflow"), (8, "no-wall"), (1, "no-tower"),
                                         (128, "no-sky")]
        for (hold, tag) in holds {
            let shot = try T.renderCell(at: 5, hold: hold, notes: T.playing, width: 1280, height: 720, capture: false)
            for (mask, layer) in masks {
                shot.renderer.skipLayers = mask
                try write(preview.capture(shot.renderer), "supercell-diag-\(tag)-\(layer)")
            }
            shot.renderer.skipLayers = 0
            try write(preview.capture(shot.renderer), "supercell-diag-\(tag)-all")
        }
    }

    // MARK: - Lightning Plains

    /// The far rain under the storm: dusk with the storm far (40 km), day, night with a fork lighting it, the storm walked
    /// in, gentle visuals, Smooth.
    func testWritePlainsRainFrames() throws {
        let url = try folder()
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        typealias T = LightningPlainsRendererTests
        let figure: T.Script = { _, t in
            var events: [PerformanceEvent] = []
            let notes: [UInt8] = [45, 52, 57, 60, 64, 57, 52, 48]
            let k = Int((t / 0.45).rounded())
            if abs(t - Double(k) * 0.45) < 0.5 / 60, k > 0 { events.append(.noteOn(note: notes[k % notes.count], velocity: 0.6)) }
            let j = Int(((t - 0.3) / 0.45).rounded())
            if abs(t - Double(j) * 0.45 - 0.3) < 0.5 / 60, j > 0 { events.append(.noteOff(note: notes[j % notes.count])) }
            return (events, nil)
        }
        let quiet: T.Script = { _, _ in ([], nil) }
        let walk = T.repeating(57, every: 0.4, from: 0.5)
        let cases: [(String, SkySettings, QualityLevel, Bool, Double, T.Script)] = [
            ("plains-far-rain-dusk", T.sky(hour: 19.75), .high, false, 2.0, quiet),
            ("plains-far-rain-dusk-flash", T.sky(hour: 19.75), .high, false, 4.62, T.both(figure, T.chord([48, 52, 55], at: 4.6))),
            ("plains-far-rain-day", T.sky(hour: 17.2), .high, false, 2.0, quiet),
            ("plains-far-rain-night", T.sky(hour: 21.2, phase: 0.05), .high, false, 6.03, T.both(figure, T.chord([55, 59, 62], at: 6.0))),
            ("plains-far-rain-near", T.sky(hour: 20.1), .high, false, 19.72, walk),
            ("plains-far-rain-gentle", T.sky(hour: 19.75), .high, true, 4.62, T.both(figure, T.chord([48, 52, 55], at: 4.6))),
            ("plains-far-rain-smooth", T.sky(hour: 19.75), .lite, false, 2.0, quiet),
        ]
        for (name, s, q, gentle, t, script) in cases {
            let shot = try T.renderPlains(seconds: t, sky: s, quality: q, gentle: gentle, script: script, preview: preview)
            try PreviewRenderer.writePNG(shot.image, to: url.appendingPathComponent("\(name).png"))
            let km = String(format: "%.1f", shot.frame.distanceKm)
            print("PLAINS_LOOK \(name): sun \(String(format: "%.1f", shot.frame.sky.sun.altitude))°, storm \(km) km, \(shot.frame.strikes.count) forks")
        }
    }
}

/// The three worlds' GPU time at 1280×720 against untouched worlds, drawn round-robin frame by frame in one run (so the
/// runner's drift falls on all alike): scene and finishing passes, the median of 16 after 3 to warm up. CI's GPUs are not
/// the target Mac's, so this only reports (`FRAME TIME look` lines), in the looks job (PREVIEW_DIR set): it holds 22
/// renderers at once, which the full test run, with everything else it holds, has no room for.
@MainActor
final class LookVSPFrameTimeTests: XCTestCase {
    func testFrameTimesAgainstUntouchedWorlds() throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_DIR"] != nil else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        StarTextureCache.shared.request(device: device)
        StarTextureCache.shared.awaitTexture()
        let width = 1280, height = 720
        let size = CGSize(width: width, height: height)
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: width, height: height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        typealias V = VolcanoRimRendererTests
        typealias C = SupercellSkyRendererTests
        typealias P = LightningPlainsRendererTests
        var entries: [(String, ThemeRenderer)] = []
        for q in [QualityLevel.lite, .high] {
            let label = q == .lite ? "Smooth" : "High"
            let calm = try V.renderVolcano(at: 3, quality: q, energy: 0.6, notes: V.playing, width: width, height: height,
                                           capture: false)
            entries.append(("volcano-calm \(label)", calm.renderer))
            let erupting = try V.renderVolcano(at: 3.2, quality: q, energy: 0.8, moments: [120: V.chord(1)], notes: V.playing,
                                               width: width, height: height, capture: false)
            entries.append(("volcano-eruption \(label)", erupting.renderer))
            let veins = try V.renderVolcano(at: 3, values: ["visual": .choice("Magma Veins")], quality: q, energy: 0.8,
                                            notes: { i in i % 12 == 0 ? [UInt8(48 + (i / 12) * 5 % 36)] : [] },
                                            width: width, height: height, capture: false)
            entries.append(("volcano-veins \(label)", veins.renderer))
            let cell = try C.renderCell(at: 3, quality: q, notes: C.playing, width: width, height: height, capture: false)
            entries.append(("supercell \(label)", cell.renderer))
            let plains = try P.renderPlains(seconds: 3, sky: P.sky(hour: 19.75), quality: q, width: width, height: height)
            entries.append(("plains \(label)", plains.renderer))
            for (id, name) in [(MoonlitLakeModel.id, "lake"), (CoastRoadModel.id, "road"), (NeonNightDriveModel.id, "drive")] {
                let r = try XCTUnwrap(WorldFrameTimeSweepTests.renderer(themeID: id, seconds: 3, quality: q, device: device, size: size))
                entries.append(("untouched-\(name) \(label)", r))
            }
        }
        var times = [[Double]](repeating: [], count: entries.count)
        for rep in 0..<19 {
            for (i, entry) in entries.enumerated() {
                guard let cb = queue.makeCommandBuffer() else { continue }
                entry.1.render(stack: stack, commandBuffer: cb)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                stack.post(into: pass, commandBuffer: cb, settings: entry.1.post)
                cb.commit()
                cb.waitUntilCompleted()
                if rep >= 3 { times[i].append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
        }
        for (i, entry) in entries.enumerated() {
            let s = times[i].sorted()
            let median = s.isEmpty ? 0 : s[s.count / 2]
            let best = s.first ?? 0
            print(String(format: "FRAME TIME look %@ 1280x720: scene+finish median %.2f ms, best %.2f ms (of %d, interleaved)",
                         entry.0, median, best, s.count))
            XCTAssertGreaterThan(median, 0, entry.0)
        }
    }
}
