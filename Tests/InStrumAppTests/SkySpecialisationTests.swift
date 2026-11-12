import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// The shared sky's two programs (Fire & Neon fix pass): a plain sky draws with the program that has none of the storm
/// weathers' code, a sky with a supercell, ash, a far storm or a sprite with the one that has it, made once and kept;
/// and a plain sky looks the same through either.
@MainActor
final class SkySpecialisationTests: XCTestCase {
    typealias T = SkyExtrasRendererTests
    typealias R = FireNeonWeatherRendererTests

    /// Which rows call for the storm program: none of a plain night's or golden hour's; a supercell's, ash's, a far
    /// storm's and a lit sprite's each.
    func testTheStormRowsChooseTheProgram() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let layer = try XCTUnwrap(SkyLayer(device: device))
        let size = CGSize(width: 320, height: 180)
        func storms(_ s: SkyState) -> Bool {
            layer.update(s, quality: .high, size: size, time: 0)
            return layer.storms
        }
        XCTAssertFalse(storms(T.night()), "a plain night")
        XCTAssertFalse(storms(R.golden()), "a plain golden hour")
        var ash = T.night(); ash.ash = 0.4
        XCTAssertTrue(storms(ash), "ash")
        XCTAssertTrue(storms(R.supercell(R.golden(), phase: 0.2)), "a supercell")
        XCTAssertTrue(storms(T.stormy(T.night(), sprites: false)), "a far storm")
        var sprite = T.night()
        sprite.sprites = [SpriteSlot(azimuth: 10, base: 5, height: 3, columns: 1, spread: 1, shape: 0.5, streamers: 0,
                                     seed: 0.3, born: 0, lit: 0.1, peak: 0.03, level: 1, brightness: 0.03)]
        XCTAssertTrue(storms(sprite), "a sprite")
        XCTAssertFalse(storms(T.night()), "and back")
        XCTAssertFalse(SkySpecialisation.needsStorms([]), "no rows: plain")
    }

    /// The storm program is built the first time a frame needs it and kept: one build however many frames, none for a
    /// plain sky.
    func testTheStormProgramIsMadeOnceWhenNeeded() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        let preview = try XCTUnwrap(PreviewRenderer(width: 160, height: 90))
        let size = CGSize(width: 160, height: 90)
        for i in 0..<3 {
            r.update(T.night(), quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: .none)
            _ = preview.capture(r)
        }
        XCTAssertEqual(r.sky.domeStormBuilds, 0, "a plain sky never builds it")
        XCTAssertFalse(r.sky.domeHasStormProgram)
        let cell = R.supercell(R.golden(), phase: 0.45)
        for i in 0..<4 {
            r.update(cell, quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: .none)
            _ = preview.capture(r)
            r.update(T.night(), quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: .none)
            _ = preview.capture(r)
        }
        XCTAssertEqual(r.sky.domeStormBuilds, 1, "built once, kept")
        XCTAssertTrue(r.sky.domeHasStormProgram)
    }

    /// A plain sky looks the same through both programs (the plain one only leaves out code that would draw nothing);
    /// the storm program still draws the storm.
    func testAPlainSkyLooksTheSameThroughEitherProgram() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        let size = CGSize(width: 320, height: 180)
        func render(_ s: SkyState, force: Bool) throws -> CGImage {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = 0
            r.sky.forceStormProgram = force
            for i in 0..<3 { r.update(s, quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            XCTAssertEqual(r.sky.storms, force || SkySpecialisation.needsStorms(r.sky.uniforms))
            return try XCTUnwrap(preview.capture(r))
        }
        for s in [T.night(), R.golden()] {
            let plain = try render(s, force: false), stormy = try render(s, force: true)
            XCTAssertLessThan(PreviewRenderer.difference(plain, stormy), 2e-3)
        }
        let clear = try render(R.golden(), force: false)
        let cell = try render(R.supercell(R.golden(), phase: 0.2), force: false)
        XCTAssertGreaterThan(PreviewRenderer.difference(clear, cell), 0.02, "the storm program draws the storm")
    }

    /// The supercell's impostor (Fire & Neon fix pass): none for a plain sky. In the app no frame draws more than a
    /// strip of it: the storm's first snapshot is filled a strip a frame and shown once whole (`cellStrips` frames),
    /// then the next a strip a frame. Previews draw a snapshot whole at once, and again when the clock jumps. The rows
    /// say where it is.
    func testTheSupercellImpostorIsDrawnInStrips() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 160, height: 90))
        let size = CGSize(width: 160, height: 90)
        let cell = R.supercell(R.golden(), phase: 0.2)
        defer { SkyLayer.cellAtOnce = true }
        SkyLayer.cellAtOnce = false
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        r.sky.viewAzimuth = 0
        r.update(T.night(), quality: .high, size: size, dt: 1.0 / 30, time: 0, surface: .none)
        _ = preview.capture(r)
        XCTAssertNil(r.sky.cellTexture, "a plain sky has none")
        XCTAssertEqual(r.sky.uniforms[SkyLayer.flashRow].w, 0, "and its rows say so")
        for i in 0..<SkyLayer.cellStrips {
            r.update(cell, quality: .high, size: size, dt: 1.0 / 60, time: Float(i) / 60, surface: .none)
            _ = preview.capture(r)
            XCTAssertEqual(r.sky.uniforms[SkyLayer.flashRow].w > 0.5, i == SkyLayer.cellStrips - 1, "frame \(i)")
        }
        XCTAssertNotNil(r.sky.cellTexture, "whole after its strips")
        for i in 0..<4 {
            r.update(cell, quality: .high, size: size, dt: 1.0 / 60, time: Float(SkyLayer.cellStrips + i) / 60, surface: .none)
            _ = preview.capture(r)
        }
        XCTAssertEqual(r.sky.cellWholeDraws, 0, "never all at once in the app")
        XCTAssertEqual(r.sky.cellStripDraws, SkyLayer.cellStrips + 4, "a strip a frame")
        let rows = r.sky.uniforms
        XCTAssertGreaterThan(rows[SkyLayer.flashRow].w, 0.5, "the rows read it")
        XCTAssertGreaterThan(rows[10].w, 0.5, "its half-width (radians) covers the view")
        XCTAssertLessThan(rows[SkyLayer.flashRow].y, 0, "from under the horizon")
        XCTAssertGreaterThan(rows[SkyLayer.flashRow].z, 0.5, "to over the view's top")
        // A preview: whole at once, and again after a jump in the clock.
        SkyLayer.cellAtOnce = true
        let p = try XCTUnwrap(SkyOnlyRenderer(device: device))
        p.sky.viewAzimuth = 0
        p.update(cell, quality: .high, size: size, dt: 1.0 / 30, time: 0, surface: .none)
        _ = preview.capture(p)
        XCTAssertEqual(p.sky.cellWholeDraws, 1)
        XCTAssertGreaterThan(p.sky.uniforms[SkyLayer.flashRow].w, 0.5, "shown in its first frame")
        p.update(cell, quality: .high, size: size, dt: 1.0 / 30, time: 30, surface: .none)
        _ = preview.capture(p)
        XCTAssertEqual(p.sky.cellWholeDraws, 2)
    }

    /// Every library built on the shared sky reads its constant only through specialised functions: a sky-reading
    /// fragment has the constant, and `skyFunction` hands back a function for both programs.
    func testSkyLibrariesSpecialise() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let programs: [(String, String, String)] = [
            (SkyShaders.source, "sky_dome_vertex", "sky_dome_fragment"),
            (MoonlitLakeShaders.source, "lake_vertex", "lake_fragment"),
            (GoldenHourBeachShaders.source, "beach_vertex", "beach_fragment"),
            (NeonNightDriveShaders.source, "drive_vertex", "drive_scene_fragment"),
            (VolcanoRimShaders.source, "volcano_vertex", "volcano_scene_fragment"),
            (SupercellSkyShaders.source, "cell_vertex", "cell_scene_fragment"),
        ]
        for (source, v, f) in programs {
            let lib = try device.makeLibrary(source: source, options: nil)
            let raw = try XCTUnwrap(lib.makeFunction(name: f), f)
            XCTAssertFalse(raw.functionConstantsDictionary.isEmpty, "\(f) reads the sky's constant")
            for storms in [false, true] {
                XCTAssertNotNil(lib.skyFunction(f, storms: storms), "\(f) \(storms)")
                XCTAssertNotNil(lib.skyFunction(v, storms: storms), "\(v) \(storms)")
            }
        }
    }
}

/// The plain sky's program against the storm program in the same run (the runners' GPUs vary from run to run): the
/// Supercell Sky world, the drive and the lake at 1280 × 720 on High, drawn both ways over the same frame, printed as
/// TIMING lines, with the Lounge (no sky) for scale.
@MainActor
final class SkyProgramFrameTimeTests: XCTestCase {
    static func median(_ renderer: ThemeRenderer, stack: RenderStack, queue: MTLCommandQueue, frames: Int = 24) -> Double {
        var times: [Double] = []
        for i in 0..<(frames + 4) {
            guard let cb = queue.makeCommandBuffer() else { continue }
            renderer.render(stack: stack, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 4 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        times.sort()
        return times.isEmpty ? 0 : times[times.count / 2]
    }

    func testPlainAgainstStormProgram() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("No Metal device") }
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: 1280, height: 720)
        // Interleaved (plain, storm, plain, storm …), so the GPU's clocks settling favour neither.
        func both(_ label: String, _ renderer: ThemeRenderer, _ sky: SkyLayer) {
            var plain: [Double] = [], storm: [Double] = []
            for round in 0..<6 {
                for stormy in [false, true] {
                    sky.forceStormProgram = stormy
                    let m = Self.median(renderer, stack: stack, queue: queue, frames: 10)
                    if round > 0 { if stormy { storm.append(m) } else { plain.append(m) } }
                }
            }
            sky.forceStormProgram = false
            plain.sort(); storm.sort()
            let p = plain[plain.count / 2], s = storm[storm.count / 2]
            print(String(format: "TIMING sky-program %@ High 1280x720: plain %.2f ms, storm program %.2f ms (interleaved, median of 5×6)",
                         label, p, s))
            XCTAssertGreaterThan(p, 0)
        }
        let cell = try SupercellSkyRendererTests.renderCell(at: 2, quality: .high, notes: SupercellSkyRendererTests.playing,
                                                            width: 1280, height: 720, capture: false)
        both("supercell", cell.renderer, cell.renderer.sky)
        let drive = try NeonNightDriveRendererTests.renderDrive(at: 2, quality: .high, notes: NeonNightDriveRendererTests.playing,
                                                                width: 1280, height: 720, capture: false)
        both("drive", drive.renderer, drive.renderer.sky)
        let dome = try XCTUnwrap(SkyOnlyRenderer(device: device))
        dome.sky.viewAzimuth = 0
        for i in 0..<5 {
            dome.update(SkyExtrasRendererTests.night(), quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30,
                        time: Float(i) / 30, surface: .none)
        }
        both("dome-night", dome, dome.sky)
        let r = try XCTUnwrap(SpaceshipLoungeRenderer(device: device))
        let d = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        for i in 1...60 {
            if let f = d.step(dt: 1.0 / 60, t: Double(i) / 60, quality: .high) as? LoungeFrame {
                r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: CGSize(width: 1280, height: 720))
            }
        }
        print(String(format: "TIMING sky-program lounge-reference High 1280x720: %.2f ms (median of 24)",
                     Self.median(r, stack: stack, queue: queue)))
    }
}
