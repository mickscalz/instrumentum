import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// Runs the Underwater Kit's helpers on the GPU through `UnderwaterProbe` (one pixel per probe, into a float target)
/// and reads the results back.
@MainActor
final class UnderwaterProbeRunner {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let probe, grid: MTLRenderPipelineState
    private let placeholder: MTLTexture

    init(device: MTLDevice) throws {
        self.device = device
        queue = try XCTUnwrap(device.makeCommandQueue())
        let lib = try device.makeLibrary(source: UnderwaterProbe.source, options: nil)
        func make(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction("underwater_view_vertex")
            d.fragmentFunction = lib.skyFunction(fragment)
            d.colorAttachments[0].pixelFormat = .rgba32Float
            return try device.makeRenderPipelineState(descriptor: d)
        }
        probe = try make("underwater_probe_fragment")
        grid = try make("underwater_grid_fragment")
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        pd.usage = [.shaderRead]
        placeholder = try XCTUnwrap(device.makeTexture(descriptor: pd))
    }

    /// A test sky: blue everywhere (zenith and horizon), the sun and moon 30° down, no stars, cloud, halo or aurora.
    /// Rows the sky adds later (meteor slots, the flash) stay zero: empty.
    nonisolated static func blueSky() -> [SIMD4<Float>] {
        var u = [SIMD4<Float>](repeating: .zero, count: SkyLayer.uniformCount)
        u[0] = SIMD4(1, 0, 0, 1); u[1] = SIMD4(0, 0, 1, 1); u[2] = SIMD4(0, 1, 0, 0)
        u[3] = SIMD4(0, 0, 1, 0); u[4] = SIMD4(0, 0, 1, 0)
        let down = SIMD3<Float>(0, cos(Float.pi / 6), -sin(Float.pi / 6))
        u[5] = SIMD4(down, -30); u[6] = SIMD4(down, 0); u[7] = SIMD4(0, 0, 0.02, 0.016)
        u[8] = SIMD4(1, 0, 0, 0); u[9] = SIMD4(0, 1, 0, 0); u[10] = SIMD4(0, 0, 1, 0)
        u[11] = SIMD4(0, 0, 2, 0.003)
        u[14] = SIMD4(0, -1, 20, -1)
        return u
    }

    /// Each probe's result: (kind, a, b, c) and (d0, d1, d2, d3) as `UnderwaterProbe` documents them (up to 64).
    func run(_ probes: [(SIMD4<Float>, SIMD4<Float>)], sky: [SIMD4<Float>] = UnderwaterProbeRunner.blueSky()) throws -> [SIMD4<Float>] {
        XCTAssertTrue((1...64).contains(probes.count))
        var data: [SIMD4<Float>] = []
        for (p, q) in probes { data.append(p); data.append(q) }
        return try render(width: probes.count, height: 1, pipeline: probe) { e in
            sky.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            data.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.setFragmentTexture(self.placeholder, index: 0)
        }
    }

    /// The caustics at a size × size grid of points `spacing` metres apart at `depth`, at time `t`.
    func caustics(size: Int, spacing: Float, depth: Float, t: Float) throws -> [Float] {
        var g = SIMD4<Float>(spacing, depth, t, 0)
        return try render(width: size, height: size, pipeline: grid) { e in
            e.setFragmentBytes(&g, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }.map(\.x)
    }

    private func render(width: Int, height: Int, pipeline: MTLRenderPipelineState,
                        bind: (MTLRenderCommandEncoder) -> Void) throws -> [SIMD4<Float>] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: d))
        let bytesPerRow = width * MemoryLayout<SIMD4<Float>>.stride
        let out = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let e = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
        e.setRenderPipelineState(pipeline)
        bind(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: width * height)
        return (0..<(width * height)).map { p[$0] }
    }
}

/// The Underwater Kit's test view (open water, Snell's window, sand with caustics, shafts, from a depth) and a cabin
/// wall around a porthole: the outside for porthole previews.
@MainActor
final class UnderwaterTestView {
    let sky: SkyLayer
    var depth: Float = 25, pitch: Float = 15, waves: Float = 0.3, time: Float = 4, below: Float = 12
    var verticalFOV: Float = 70
    /// The light falling on the surface, and the shafts' strength.
    var light = SIMD3<Float>(1, 0.98, 0.95), shafts: Float = 0.8
    var cabin = SIMD3<Float>(1, 0.85, 0.72)
    private let view, wall: MTLRenderPipelineState
    private var viewU = [SIMD4<Float>](repeating: .zero, count: 4)
    private var aspect: Float = 16.0 / 9

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device),
              let lib = try? device.makeLibrary(source: UnderwaterProbe.source, options: nil) else { return nil }
        func make(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction("underwater_view_vertex")
            d.fragmentFunction = lib.skyFunction(fragment)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let v = make("underwater_view_fragment"), let w = make("cabin_wall_fragment") else { return nil }
        sky = s; view = v; wall = w
    }

    /// Looks 30° to the left of the sun's bearing, so the shafts slant in from the right.
    func update(_ s: SkyState, size: CGSize, quality: QualityLevel) {
        aspect = Float(max(1, size.width) / max(1, size.height))
        sky.update(s, quality: quality, size: size, time: time)
        let azimuth = Float(s.sun.azimuth - 30) * .pi / 180
        let tanV = tan(verticalFOV * .pi / 360)
        let rel = Float(30.0 * Double.pi / 180)
        viewU[0] = SIMD4(azimuth, pitch * .pi / 180, tanV, aspect)
        viewU[1] = SIMD4(depth, time, waves, below)
        let day = Float(min(1, max(0, (s.sun.altitude + 3) / 13)))
        viewU[2] = SIMD4(light * (0.25 + 0.75 * day), shafts * day)
        viewU[3] = SIMD4(-sin(rel) * 0.45, -1, 2 * tanV / Float(max(1, size.height)), 0)
    }

    func drawOutside(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(view)
        sky.uniforms.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        viewU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        sky.bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The cabin's painted wall, around the porthole's ring.
    func drawWall(_ e: MTLRenderCommandEncoder, around spec: WindowSpec) {
        let (c, r) = spec.circle
        let w = [SIMD4<Float>(c.x, c.y, r + spec.frameWidth * aspect, aspect), SIMD4<Float>(cabin, 0)]
        e.setRenderPipelineState(wall)
        w.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// The Underwater Kit (spec §7.3), on the GPU.
@MainActor
extension WorldKitTests {
    private func probeRunner() throws -> UnderwaterProbeRunner {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        return try UnderwaterProbeRunner(device: device)
    }

    func testUnderwaterShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: UnderwaterProbe.source, options: nil)
        for name in ["underwater_view_vertex", "underwater_probe_fragment", "underwater_grid_fragment", "underwater_view_fragment",
                     "cabin_wall_fragment"] {
            XCTAssertNotNil(lib.skyFunction(name), name)
        }
        // The kit is a helper string for a world's program: it opens none of its own, and follows SkyShaders.common.
        XCTAssertFalse(UnderwaterShaders.common.contains("#include"))
        XCTAssertTrue(UnderwaterProbe.source.hasPrefix(SkyShaders.common + UnderwaterShaders.common))
    }

    /// Looking up from 1 m under a blue sky, with a green "mirror" (the water below): 40° from the zenith is inside the
    /// 48.6° critical angle, so the sky shows; 55° is outside it, so the surface mirrors the water. The same at every
    /// azimuth; straight up is all sky; from 45 m down the window is gone.
    func testSnellWindowShowsTheSkyOnlyWithinTheCriticalAngle() throws {
        let r = try probeRunner()
        func dir(_ zenith: Float, _ azimuth: Float) -> SIMD4<Float> {
            let t = zenith * .pi / 180, a = azimuth * .pi / 180
            return SIMD4(sin(t) * sin(a), sin(t) * cos(a), cos(t), 0)
        }
        let azimuths: [Float] = [0, 90, 200, 315]
        var probes: [(SIMD4<Float>, SIMD4<Float>)] = []
        for az in azimuths {
            for zenith: Float in [0, 40, 55] { probes.append((SIMD4(3, 1, 0, 0), dir(zenith, az))) }
        }
        probes.append((SIMD4(3, 45, 0, 0), dir(20, 0)))
        let out = try r.run(probes)
        for (i, az) in azimuths.enumerated() {
            let up = out[i * 3], at40 = out[i * 3 + 1], at55 = out[i * 3 + 2]
            XCTAssertGreaterThan(at40.w, 0.9, "40° at \(az)°: inside the window")
            XCTAssertGreaterThan(at40.z, 0.5, "the sky shows at 40° (\(az)°): \(at40)")
            XCTAssertGreaterThan(at40.z, 10 * at40.y, "sky, not the mirror, at 40° (\(az)°): \(at40)")
            XCTAssertLessThan(at55.w, 0.001, "55° at \(az)°: outside the window")
            XCTAssertGreaterThan(at55.y, 0.5, "the surface mirrors the water at 55° (\(az)°): \(at55)")
            XCTAssertLessThan(at55.z, 0.001, "and no sky (\(az)°): \(at55)")
            XCTAssertGreaterThan(up.w, 0.95, "straight up (\(az)°)")
            XCTAssertGreaterThan(up.z, at40.z, "brightest straight up (\(az)°)")
        }
        let deep = try XCTUnwrap(out.last)
        XCTAssertEqual(deep.w, 0)
        XCTAssertEqual(deep.x + deep.y + deep.z, 0, "gone by 40 m")
    }

    /// Beer–Lambert per channel (red 0.35, green 0.07, blue 0.03 per metre): at 10 m red is under 5% of blue,
    /// relative to the surface's balance; the light from above at 100 m is ≤ 2% of the surface's (its three bands'
    /// mean: 1.7%). The eye's tone curve keeps a deep blue readable at 400 m (≥ 5% of what it sees at 15 m) and gone
    /// by 550 m.
    func testWaterColourLosesRedFirst() throws {
        let r = try probeRunner()
        let out = try r.run([
            (SIMD4(2, 0, 30, 0), .zero), (SIMD4(2, 10, 30, 0), .zero),        // waterColour at the surface and 10 m
            (SIMD4(1, 0, 0, 0), .zero), (SIMD4(1, 100, 0, 0), .zero),         // waterLight at the surface and 100 m
            (SIMD4(2, 15, 1000, 0), .zero), (SIMD4(4, 15, 0, 0), .zero),      // open water and the eye's gain: 15 m
            (SIMD4(2, 400, 1000, 0), .zero), (SIMD4(4, 400, 0, 0), .zero),    // 400 m
            (SIMD4(2, 550, 1000, 0), .zero), (SIMD4(4, 550, 0, 0), .zero),    // 550 m
            (SIMD4(4, 0, 0, 0), .zero),                                       // the gain at the surface
        ])
        let surface = out[0], ten = out[1]
        XCTAssertLessThan((ten.x / ten.z) / (surface.x / surface.z), 0.05, "red under 5% of blue at 10 m: \(ten) vs \(surface)")
        XCTAssertGreaterThan(ten.z, 0.6 * surface.z, "while blue carries on")
        func mean(_ c: SIMD4<Float>) -> Float { (c.x + c.y + c.z) / 3 }
        XCTAssertLessThanOrEqual(mean(out[3]) / mean(out[2]), 0.02, "1% of the light at 100 m: \(out[3])")
        XCTAssertEqual(out[10].x, 1, accuracy: 1e-6, "no adapting at the surface")
        let seen15 = out[4].z * out[5].x, seen400 = out[6].z * out[7].x, seen550 = out[8].z * out[9].x
        XCTAssertGreaterThan(seen400, 0.05 * seen15, "a deep blue still reads at 400 m: \(seen400) vs \(seen15)")
        XCTAssertLessThan(seen550, 0.002 * seen15, "and is gone below: \(seen550)")
    }

    /// The caustic net dances on shallow sand (strong contrast at 4 m, its mean about 1: light moved about, not made),
    /// fades by 12 m and is exactly 1 from 15 m down.
    func testCausticsOnlyInTheShallows() throws {
        let r = try probeRunner()
        func stats(_ v: [Float]) -> (mean: Float, sd: Float, lo: Float, hi: Float) {
            let m = v.reduce(0, +) / Float(v.count)
            let sd = (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(v.count)).squareRoot()
            return (m, sd, v.min() ?? 0, v.max() ?? 0)
        }
        let shallow = stats(try r.caustics(size: 48, spacing: 0.09, depth: 4, t: 2.5))
        XCTAssertGreaterThan(shallow.sd, 0.5, "a strong net at 4 m: \(shallow)")
        XCTAssertGreaterThan(shallow.hi, 3)
        XCTAssertLessThan(shallow.lo, 0.5)
        XCTAssertEqual(shallow.mean, 1, accuracy: 0.25)
        let fading = stats(try r.caustics(size: 48, spacing: 0.09, depth: 12, t: 2.5))
        XCTAssertLessThan(fading.sd, 0.5 * shallow.sd, "fading by 12 m: \(fading)")
        for depth: Float in [15, 20, 60] {
            let flat = try r.caustics(size: 16, spacing: 0.13, depth: depth, t: 2.5)
            XCTAssertTrue(flat.allSatisfy { $0 == 1 }, "none at \(depth) m")
        }
    }

    /// The shafts: there by day near the surface, fainter at 60 m, gone by 200 m; rough water flickers them harder.
    func testLightShaftsFadeWithDepth() throws {
        let r = try probeRunner()
        var probes: [(SIMD4<Float>, SIMD4<Float>)] = []
        for depth: Float in [5, 60, 200] {
            for i in 0..<20 { probes.append((SIMD4(6, -0.9 + 0.09 * Float(i), 0.5, 2), SIMD4(0.3, -1, depth, 0.3))) }
        }
        let out = try r.run(Array(probes.prefix(60)))
        func peak(_ k: Int) -> Float { out[(k * 20)..<(k * 20 + 20)].map(\.x).max() ?? 0 }
        XCTAssertGreaterThan(peak(0), 0.2, "bands across the view at 5 m")
        XCTAssertLessThan(peak(1), 0.5 * peak(0), "fainter at 60 m")
        XCTAssertEqual(peak(2), 0, "none at 200 m")
    }
}
