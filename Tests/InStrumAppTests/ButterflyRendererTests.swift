import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

@MainActor
final class ButterflyRendererTests: XCTestCase {
    func testButterflyShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: ButterflyShaders.source, options: nil)
        for name in ["sky_vertex", "sky_fragment", "sprite_vertex", "butterfly_fragment", "bloom_fragment",
                     "particle_vertex", "particle_fragment", "keys_vertex", "keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    func testRendersNonBlackStructuredFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let image = try XCTUnwrap(preview.renderButterflyGarden(at: [3]).first)
        let s = PreviewRenderer.stats(image)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.002)
    }

    func testButterfliesChangeTheImage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        let quiet = try XCTUnwrap(preview.renderButterflyGarden(at: [0.01]).first)
        let busy = try XCTUnwrap(preview.renderButterflyGarden(at: [5]).first)
        XCTAssertGreaterThan(PreviewRenderer.difference(quiet, busy), 0.01)
    }

    func testSmoothQualityStillLooksLikeTheGarden() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let lite = try XCTUnwrap(preview.render(themeID: ButterflyGardenModel.id, at: [5], quality: .lite).first)
        let s = PreviewRenderer.stats(lite)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.002)
    }

    func testSmoothSkipsTheExpensiveLightShafts() {
        // The sun-shaft march was the cost that froze an Intel Mac: none on Smooth, cheap on High.
        XCTAssertEqual(ButterflyRenderer.shaftSteps[.lite], 0)
        XCTAssertLessThanOrEqual(ButterflyRenderer.shaftSteps[.high] ?? 99, 12)
        XCTAssertLessThanOrEqual(ButterflyRenderer.noiseOctaves[.lite] ?? 99, 3)
    }
}

@MainActor
final class PreviewRenderTests: XCTestCase {
    /// Writes preview frames when PREVIEW_DIR is set (CI previews job).
    func testWritePreviewFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let times: [Double] = [1, 3, 5, 7, 17]
        let images = preview.renderButterflyGarden(at: times)
        XCTAssertEqual(images.count, times.count)
        for (t, image) in zip(times, images) {
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("butterfly-t\(Int(t)).png"))
        }
        if let image = preview.render(themeID: ButterflyGardenModel.id, at: [5], quality: .lite).first {
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("butterfly-smooth-t5.png"))
        }
        if let image = preview.render(themeID: MidnightSteinwayModel.id, at: [5]).first {
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("steinway-t5.png"))
        }
        for tod in ["Dawn", "Moonlight"] {
            var p = ParameterSet(specs: ButterflyGardenModel.parameters, macroTargets: ButterflyGardenModel.macroTargets)
            p.set("time", .choice(tod))
            if let image = preview.renderButterflyGarden(at: [5], params: p).first {
                try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("butterfly-\(tod.lowercased())-t5.png"))
            }
        }
    }

    /// The "Inspired by" cards (PREVIEW_DIR).
    func testWriteCardPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for c in CreditLibrary.all {
            let image = try XCTUnwrap(InspiredByCardTests.render(c, at: 2.4))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("card-\(c.id).png"))
        }
        // Every song card, the "Underwater" card (Set 11) among them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("card-underwater.png").path))
        // The place cards (sets born from their place, no song): card-place-tea-house-snow, card-place-zen-rock-garden,
        // card-place-great-barrier-reef.
        for set in SetLibrary.all where set.creditID == nil {
            let image = try XCTUnwrap(InspiredByCardTests.render(place: set, at: 2.4), set.id)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("card-place-\(set.id).png"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("card-place-great-barrier-reef.png").path))
    }
}
