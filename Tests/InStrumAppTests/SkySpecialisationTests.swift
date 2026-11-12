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
