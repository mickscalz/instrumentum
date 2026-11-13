import XCTest
import Metal
import QuartzCore
@testable import InStrumApp
@testable import InStrumCore

/// The main thread's time a frame, every world (real-Mac performance, 14 Nov): Michael's MacBook Pro ran Moonlit Lake at
/// a steady 32 ms a frame (Bioluminescent Bay 22 ms) with the GPU busy 4 ms, so the time went on the CPU. Each world plays
/// the demo performance for five seconds at Smooth, 1264 × 790 (his window), under a night sky and a day sky, as the
/// canvas runs it: the events and the step (world and sky) with the ambience it hands on, the renderer's update, and the
/// encoding of the scene and the finishing passes (committed, then waited on outside the timing, so the GPU never piles
/// up). One CPU TIME line a world and sky: medians of the last four seconds, and the slowest frame. Also the world switch
/// itself (a new model, as the canvas's `syncSettings` makes it) and its first step. CI's CPUs are not his, so this only
/// reports; compare a world against the untouched ones in the same run.
@MainActor
final class WorldCPUTimeSweepTests: XCTestCase {
    static let width = 1264, height = 790

    static func sky(hour: Double) -> SkySettings {
        var s = SkySettings()
        s.timeMode = .frozen
        s.frozenHour = hour
        s.cityID = "melbourne"
        return s
    }

    func testEveryWorldCPUTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        StarTextureCache.shared.request(device: device)
        StarTextureCache.shared.awaitTexture()
        let size = CGSize(width: Self.width, height: Self.height)
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: Self.width, height: Self.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height,
                                                          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let worlds = WorldRenderers(device: device)
        func ms(_ seconds: Double) -> Double { seconds * 1000 }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        var timed = 0
        for world in ThemeRegistry.all {
            guard let kind = WorldRenderers.kind(forTheme: world.id) else { continue }
            for (label, hour) in [("night", 22.0), ("day", 13.0)] {
                // The world switch, as the canvas makes it (from another world's director), and its first step.
                let director = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(),
                                             reaction: ReactionPresets.expressivePianist)
                director.sky.reset(settings: Self.sky(hour: hour))
                _ = director.step(dt: 1.0 / 60, t: 0, quality: .lite)
                let s0 = CACurrentMediaTime()
                director.switchTheme(to: world.id, state: ThemeState())
                let s1 = CACurrentMediaTime()
                _ = director.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .lite)
                let s2 = CACurrentMediaTime()
                // The renderer, made off the main thread (or at once for the two main-actor worlds), outside the timing.
                if !kind.mainThreadOnly, worlds.renderer(kind) == nil {
                    let frame = director.step(dt: 1.0 / 60, t: 2.0 / 60, quality: .lite)
                    _ = worlds.renderer(for: frame, params: director.parameters, quality: .lite, gentle: false, dt: 1.0 / 60,
                                        size: size)
                    XCTAssertTrue(worlds.awaitMade(kind, timeout: 600), world.id)
                }
                var perf = PerformanceState()
                let script = ScriptedPerformance.demo
                var next = 0
                var steps: [Double] = [], updates: [Double] = [], encodes: [Double] = [], frames: [Double] = []
                for i in 3...302 {
                    let time = Double(i) / 60
                    var events: [PerformanceEvent] = []
                    while next < script.count, script[next].time <= time - 3.0 / 60 {
                        events += perf.apply(script[next].message, at: script[next].time)
                        next += 1
                    }
                    let t0 = CACurrentMediaTime()
                    director.handle(events, at: time)
                    let frame = director.step(dt: 1.0 / 60, t: time, quality: .lite)
                    _ = director.ambience(for: frame, at: time)
                    let t1 = CACurrentMediaTime()
                    guard let r = worlds.renderer(for: frame, params: director.parameters, quality: .lite, gentle: false,
                                                  dt: director.visualDt, size: size) else { continue }
                    let t2 = CACurrentMediaTime()
                    guard let cb = queue.makeCommandBuffer() else { continue }
                    r.render(stack: stack, commandBuffer: cb)
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    stack.post(into: pass, commandBuffer: cb, settings: r.post)
                    cb.commit()
                    let t3 = CACurrentMediaTime()
                    cb.waitUntilCompleted()
                    if i > 62 {
                        steps.append(ms(t1 - t0))
                        updates.append(ms(t2 - t1))
                        encodes.append(ms(t3 - t2))
                        frames.append(ms(t3 - t0))
                    }
                }
                XCTAssertFalse(frames.isEmpty, "\(world.id) \(label): no frames")
                timed += frames.isEmpty ? 0 : 1
                print(String(format: "CPU TIME sweep %@ %@ Smooth %ldx%ld (medians of %ld, ms): step %.2f, update %.2f, encode %.2f, frame %.2f; slowest frame %.2f; switch %.2f, first step %.2f",
                             world.id, label, Self.width, Self.height, frames.count, median(steps), median(updates),
                             median(encodes), median(frames), frames.max() ?? 0, ms(s1 - s0), ms(s2 - s1)))
            }
        }
        XCTAssertEqual(timed, ThemeRegistry.all.count * 2)
    }
}
