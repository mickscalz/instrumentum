import XCTest
import Metal
import CoreGraphics
@testable import InStrumApp
@testable import InStrumCore

/// What each layer of the heaviest worlds costs on CI's GPU (GitHub's Intel Macs): the sweep's frame (the demo
/// performance run three seconds) drawn with every layer, then with each layer skipped in turn (the renderers' timing
/// mask), interleaved frame by frame so the runner's drift falls on every variant alike; and the whole frame at a quarter
/// of the pixels, which splits the per-pixel cost from the fixed. One `FRAME TIME layers` line a world and quality for
/// the looks job's report. CI's GPUs are not the target Mac's, so this only reports.
@MainActor
final class HeavyWorldLayerCostTests: XCTestCase {
    struct Variant { let name: String; let mask: UInt32; let quarter: Bool }

    /// Medians (ms, scene + finish) of each variant, drawn round-robin.
    private func price(world: String, quality: QualityLevel, variants: [Variant],
                       apply: (ThemeRenderer, UInt32) -> Void) throws -> [Double] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        StarTextureCache.shared.request(device: device)
        StarTextureCache.shared.awaitTexture()
        let size = CGSize(width: 1280, height: 720)
        let r = try XCTUnwrap(WorldFrameTimeSweepTests.renderer(themeID: world, seconds: 3, quality: quality, device: device,
                                                                size: size))
        // (The quarter-size frames have a renderer of their own: one that keeps targets at the view's size would remake
        // them at every switch between sizes, and the first frame after it, every round "all", would pay for that.)
        let rq = try XCTUnwrap(WorldFrameTimeSweepTests.renderer(themeID: world, seconds: 3, quality: quality, device: device,
                                                                 size: size))
        func stack(_ w: Int, _ h: Int) throws -> (RenderStack, MTLTexture) {
            let s = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
            s.resize(width: w, height: h)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .private
            return (s, try XCTUnwrap(device.makeTexture(descriptor: td)))
        }
        let full = try stack(1280, 720), quarter = try stack(640, 360)
        var times = [[Double]](repeating: [], count: variants.count)
        for rep in 0..<14 {
            for (i, v) in variants.enumerated() {
                let rv = v.quarter ? rq : r
                apply(rv, v.mask)
                let (s, target) = v.quarter ? quarter : full
                guard let cb = queue.makeCommandBuffer() else { continue }
                rv.render(stack: s, commandBuffer: cb)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                s.post(into: pass, commandBuffer: cb, settings: rv.post)
                cb.commit()
                cb.waitUntilCompleted()
                if rep >= 2 { times[i].append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
            }
        }
        apply(r, 0)
        return times.map { t in
            let s = t.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
    }

    private func report(_ label: String, _ variants: [Variant], _ ms: [Double]) {
        let all = ms[0]
        var parts = [String(format: "all %.2f", all)]
        for (v, m) in zip(variants, ms).dropFirst() {
            parts.append(String(format: "%@ %.2f (%+.2f)", v.name, m, m - all))
        }
        print("FRAME TIME layers \(label) 1280x720 (scene+finish, medians of 12, interleaved): " + parts.joined(separator: "; "))
    }

    private static func variants(_ list: [(String, UInt32)], allOff: UInt32) -> [Variant] {
        [Variant(name: "all", mask: 0, quarter: false)] + list.map { Variant(name: "-" + $0.0, mask: $0.1, quarter: false) }
            + [Variant(name: "scene-off", mask: allOff, quarter: false), Variant(name: "quarter-pixels", mask: 0, quarter: true)]
    }

    func testSupercellLayerCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let v = Self.variants([("tower", 1), ("flank", 2), ("anvil", 4), ("wall", 8), ("base", 16), ("rain", 32),
                               ("inflow+dust", 64), ("sky", 128), ("field", 256), ("wheat", 8192), ("horizon+after", 512),
                               ("lightning", 1024), ("weather", 2048), ("birds+posts", 4096),
                               ("+full-res-storm", 16384)], allOff: 0x3FFF)
        for q in [QualityLevel.lite, .high] {
            let ms = try price(world: SupercellSkyModel.id, quality: q, variants: v) { r, m in
                (r as? SupercellSkyRenderer)?.skipLayers = m
            }
            report("supercell \(q == .lite ? "Smooth" : "High")", v, ms)
        }
    }

    func testVolcanoLayerCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let v = Self.variants([("lake", 1), ("plates", 512), ("fine-cracks", 1024), ("floor", 2), ("walls", 4), ("sky", 8),
                               ("fountains", 16), ("column", 32), ("plume", 64), ("fume", 128), ("rocks", 256),
                               ("embers+bolts", 2048), ("weather", 4096), ("keys", 8192)], allOff: 0x3FFF)
        for q in [QualityLevel.lite, .high] {
            let ms = try price(world: VolcanoRimModel.id, quality: q, variants: v) { r, m in
                (r as? VolcanoRimRenderer)?.skipLayers = m
            }
            report("volcano \(q == .lite ? "Smooth" : "High")", v, ms)
        }
    }

    func testPlainsLayerCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let v = Self.variants([("scene", 1), ("storm", 2), ("bolts", 4), ("props", 8), ("weather", 16)], allOff: 31)
        for q in [QualityLevel.lite, .high] {
            let ms = try price(world: LightningPlainsModel.id, quality: q, variants: v) { r, m in
                (r as? LightningPlainsRenderer)?.skipLayers = m
            }
            report("plains \(q == .lite ? "Smooth" : "High")", v, ms)
        }
    }

    func testDriveLayerCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let v = Self.variants([("road", 1), ("rows", 2), ("downtown", 4), ("street", 8), ("cars", 16), ("lamp-glow", 32),
                               ("car-glow", 64), ("sky", 128), ("mirror", 256), ("trails", 512), ("glass", 1024),
                               ("cabin", 2048), ("weather", 4096), ("after-scene", 8192), ("facades", 65536),
                               ("signs", 131072), ("parapets", 262144), ("haze", 524288)], allOff: 0x30FF)
        for q in [QualityLevel.lite, .high] {
            let ms = try price(world: NeonNightDriveModel.id, quality: q, variants: v) { r, m in
                (r as? NeonNightDriveRenderer)?.skipLayers = m
            }
            report("drive \(q == .lite ? "Smooth" : "High")", v, ms)
        }
    }
}
