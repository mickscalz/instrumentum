import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// The looks of Excitement's part B (plan Task 7, as Task 6): for each of the seven worlds, PNGs at rest, mid-moment,
/// mid-way through each surprise, gathered with tension, and just after the drop, at 1280×720 into `PREVIEW_DIR`.
/// The morning's looks run renders these (`.github/look-filter`).
@MainActor
final class ExcitementPartBPreviewTests: XCTestCase {
    typealias Rig = PartBRig

    private func write(_ rig: Rig, _ preview: PreviewRenderer, _ name: String, into url: URL) throws {
        let image = try XCTUnwrap(rig.capture(preview), name)
        try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
    }

    func testWriteExcitementPartBPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        for w in PartBWorld.allCases {
            let base = "excite-\(w.rawValue)"
            // At rest (a little Energy), then mid-moment: 0.6 s after a full-strength one.
            let rest = try Rig(w, width: 1280, height: 720)
            rest.run(120, Rig.excitement(energy: 0.3))
            try write(rest, preview, "\(base)-calm", into: url)
            let moment = try Rig(w, width: 1280, height: 720)
            moment.run(120, Rig.excitement(energy: 0.6))
            moment.run(36, Rig.excitement(energy: 0.6, moment: Rig.chord(1)))
            try write(moment, preview, "\(base)-moment", into: url)
            // Each surprise, a little before half way through.
            for i in 0..<w.surpriseCount {
                let rig = try Rig(w, width: 1280, height: 720)
                rig.run(30, Rig.excitement(energy: 0.4))
                let mid = max(30, Int(w.surpriseSeconds[i] * 0.42 * 60))
                rig.run(mid, Rig.excitement(energy: 0.4, surprise: WorldSurprise(index: i, seed: 77)))
                try write(rig, preview, "\(base)-surprise-\(w.surpriseNames[i])", into: url)
            }
            // Build and drop: 2.5 s of tension 0.8 (gathered), then 0.8 s after the drop.
            let drop = try Rig(w, width: 1280, height: 720)
            drop.run(150, Rig.excitement(energy: 0.6, tension: 0.8))
            try write(drop, preview, "\(base)-gathered", into: url)
            for k in 0..<48 {
                let release: Float = max(0, 1 - Float(k) / 150)
                drop.step(Rig.excitement(energy: 0.6, tension: 0, drop: release,
                                         moment: k == 0 ? Rig.chord(1, drop: true) : nil))
            }
            try write(drop, preview, "\(base)-drop", into: url)
        }
    }

    /// Smooth and gentle visuals, mid-moment, for the floor (the Spaceship Lounge) and the brightest moments.
    func testWriteExcitementPartBQualityPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        for w in [PartBWorld.lounge, .cabin, .steinway, .reef] {
            let smooth = try Rig(w, quality: .lite, width: 1280, height: 720)
            smooth.run(120, Rig.excitement(energy: 0.6))
            smooth.run(36, Rig.excitement(energy: 0.6, moment: Rig.chord(1)))
            try write(smooth, preview, "excite-\(w.rawValue)-moment-smooth", into: url)
            let gentle = try Rig(w, gentle: true, width: 1280, height: 720)
            gentle.run(120, Rig.excitement(energy: 0.6, gentle: true))
            gentle.run(36, Rig.excitement(energy: 0.6, moment: Rig.chord(1), gentle: true))
            try write(gentle, preview, "excite-\(w.rawValue)-moment-gentle", into: url)
        }
    }
}
