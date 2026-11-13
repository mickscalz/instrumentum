import XCTest
import Metal
import CoreGraphics
@testable import InStrumApp
@testable import InStrumCore

/// Real-Mac performance (14 Nov): nothing is compiled on the draw path. The warm-up makes every world's renderer off the
/// main thread (the world on screen first) and then their storm programs; a world entered after it gets a frame at once
/// with nothing built; a world entered before it is ready draws nothing new and is made off the main thread at the front
/// of the line; libraries and the shared layers' pipelines are made once and shared. Tea House Snow and Zen Rock Garden
/// (main-actor renderers, files left as they are) are still made on the main thread when first shown, and counted.
@MainActor
final class WorldRenderersTests: XCTestCase {
    static let size = CGSize(width: 640, height: 400)

    /// One step of `id`'s world, as the canvas takes it, and its renderer from `worlds` (drawn inside a frame).
    private func enter(_ id: String, _ worlds: WorldRenderers, stack: RenderStack, queue: MTLCommandQueue) -> ThemeRenderer? {
        let director = SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        ShaderWork.drawing = true
        defer { ShaderWork.drawing = false }
        let frame = director.step(dt: 1.0 / 60, t: 1, quality: .lite)
        guard let r = worlds.renderer(for: frame, params: director.parameters, quality: .lite, gentle: false,
                                      dt: director.visualDt, size: Self.size) else { return nil }
        if let cb = queue.makeCommandBuffer() {
            r.render(stack: stack, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }
        return r
    }

    func testTheWarmUpMakesEveryWorldOffTheMainThreadThenNothingIsBuiltOnTheDrawPath() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: Int(Self.size.width), height: Int(Self.size.height))
        let worlds = WorldRenderers(device: device)
        let started = Date()
        worlds.warmUp(first: VolcanoRimModel.id)
        XCTAssertEqual(worlds.building, .volcano, "the world on screen is made first")
        XCTAssertTrue(worlds.awaitWarmUp(timeout: 1500), "the warm-up finishes")
        print(String(format: "TIMING warm-up: every world and its storm programs made in %.1f s", Date().timeIntervalSince(started)))
        let offMain = Set(WorldRenderers.Kind.allCases.filter { !$0.mainThreadOnly })
        XCTAssertEqual(worlds.madeOffMain, offMain, "every world but the two main-actor ones, made off the main thread")
        for kind in offMain { XCTAssertNotNil(worlds.renderer(kind), "\(kind) made") }
        XCTAssertNil(SkyPipeline.nextUnwarmed(), "every storm program the warm-up's worlds have, made")

        // Every world entered after the warm-up draws at once, as the app draws it (storm programs made off the main
        // thread when a frame finds one missing), and nothing is built while drawing.
        ShaderWork.defersDrawPathBuilds = true
        defer { ShaderWork.defersDrawPathBuilds = false }
        ShaderWork.resetCounts()
        for world in ThemeRegistry.all {
            guard let kind = WorldRenderers.kind(forTheme: world.id), !kind.mainThreadOnly else { continue }
            XCTAssertNotNil(enter(world.id, worlds, stack: stack, queue: queue), "\(world.id) draws at once")
        }
        XCTAssertEqual(ShaderWork.drawPathBuilds, 0, "built while drawing: \(ShaderWork.lastDrawPathBuild)")

        // The two main-actor worlds: made on the main thread when first shown (their shared layers come from the caches,
        // so each counts once), and never again.
        for id in [TeaHouseSnowModel.id, ZenRockGardenModel.id] {
            XCTAssertNotNil(enter(id, worlds, stack: stack, queue: queue), id)
        }
        XCTAssertEqual(ShaderWork.drawPathBuilds, 2, "one build each: \(ShaderWork.lastDrawPathBuild)")
        for id in [TeaHouseSnowModel.id, ZenRockGardenModel.id] { _ = enter(id, worlds, stack: stack, queue: queue) }
        XCTAssertEqual(ShaderWork.drawPathBuilds, 2, "and not again")
        XCTAssertTrue(ShaderWork.reportLine().hasPrefix("Shaders: "), ShaderWork.reportLine())
    }

    func testAWorldNotYetMadeDrawsNothingNewAndIsMadeOffTheMainThread() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: Int(Self.size.width), height: Int(Self.size.height))
        let worlds = WorldRenderers(device: device)
        ShaderWork.resetCounts()
        XCTAssertNil(enter(SpaceshipLoungeModel.id, worlds, stack: stack, queue: queue), "nothing waits: no renderer yet")
        XCTAssertEqual(worlds.building, .lounge, "asked for at once")
        XCTAssertNil(enter(SpaceshipLoungeModel.id, worlds, stack: stack, queue: queue), "still on its way")
        XCTAssertTrue(worlds.awaitMade(.lounge, timeout: 300))
        XCTAssertTrue(worlds.madeOffMain.contains(.lounge), "made off the main thread")
        XCTAssertNotNil(enter(SpaceshipLoungeModel.id, worlds, stack: stack, queue: queue), "then drawn")
        XCTAssertEqual(ShaderWork.drawPathBuilds, 0, "nothing built while drawing: \(ShaderWork.lastDrawPathBuild)")
        XCTAssertFalse(worlds.warmedUp, "no warm-up was asked for, so no extras ran")
    }

    func testLibrariesAndTheSharedLayersPipelinesAreMadeOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let a = ShaderCache.library(device, source: SkyShaders.source)
        let before = ShaderCache.shared.libraryCompiles
        let b = ShaderCache.library(device, source: SkyShaders.source)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "one library per source")
        XCTAssertEqual(ShaderCache.shared.libraryCompiles, before, "not compiled again")
        let made = ShaderCache.shared.madeCount
        for _ in 0..<2 {
            XCTAssertNotNil(SkyLayer(device: device))
            XCTAssertNotNil(WeatherLayer(device: device))
            XCTAssertNotNil(WarpLayer(device: device))
            XCTAssertNotNil(WindowGlassLayer(device: device))
            XCTAssertNotNil(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        }
        XCTAssertLessThanOrEqual(ShaderCache.shared.madeCount - made, 5, "each layer's pipelines made at most once")
        let twice = ShaderCache.shared.madeCount
        XCTAssertNotNil(SkyLayer(device: device))
        XCTAssertNotNil(WeatherLayer(device: device))
        XCTAssertEqual(ShaderCache.shared.madeCount, twice, "and never again")
    }

    /// A storm program a frame finds missing: in the app it is made off the main thread and the plain program stands in
    /// meanwhile (nothing built while drawing); in previews and tests it is made at once (and the counter sees it).
    func testAMissingStormProgramIsMadeOffTheMainThreadInTheApp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try XCTUnwrap(ShaderCache.library(device, source: SkyShaders.source))
        func pipeline() throws -> SkyPipeline {
            try XCTUnwrap(SkyPipeline(program: { program in
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.skyFunction("sky_dome_vertex", program: program)
                d.fragmentFunction = lib.skyFunction("sky_dome_fragment", program: program)
                d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
                d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
                return try? device.makeRenderPipelineState(descriptor: d)
            }))
        }
        ShaderWork.resetCounts()
        ShaderWork.defersDrawPathBuilds = true
        let app = try pipeline()
        ShaderWork.drawing = true
        let first = app.state(.storms)
        ShaderWork.drawing = false
        ShaderWork.defersDrawPathBuilds = false
        XCTAssertTrue(first === app.state(.plain), "the plain program stands in")
        XCTAssertEqual(ShaderWork.drawPathBuilds, 0)
        let end = Date().addingTimeInterval(120)
        while !app.hasStormProgram, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(app.hasStormProgram, "made off the main thread")
        XCTAssertFalse(app.state(.storms) === app.state(.plain), "then drawn with")
        XCTAssertEqual(app.stormBuilds, 1)

        let preview = try pipeline()
        ShaderWork.drawing = true
        let made = preview.state(.storms)
        ShaderWork.drawing = false
        XCTAssertFalse(made === preview.state(.plain), "previews make it at once")
        XCTAssertEqual(ShaderWork.drawPathBuilds, 1, "and the counter sees a build inside a frame")
    }

    func testEveryThemeHasItsKind() {
        for world in ThemeRegistry.all {
            XCTAssertNotNil(WorldRenderers.kind(forTheme: world.id), world.id)
        }
        XCTAssertEqual(Set(ThemeRegistry.all.compactMap { WorldRenderers.kind(forTheme: $0.id) }).count,
                       WorldRenderers.Kind.allCases.count, "one kind each")
        XCTAssertEqual(WorldRenderers.Kind.allCases.filter(\.mainThreadOnly), [.teaHouse, .zenGarden])
    }
}
