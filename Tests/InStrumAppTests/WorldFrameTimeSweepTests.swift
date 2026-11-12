import XCTest
import Metal
import CoreGraphics
@testable import InStrumApp
@testable import InStrumCore

/// Every world's GPU time at 1280×720 on Smooth and on High (its scene's passes, and with the finishing passes), one
/// FRAME TIME line a world for the looks job's report: run on GitHub's Intel Macs, it shows which world an Intel or AMD
/// graphics chip finds slow (Supercell Sky's frame took 221 ms there, 13 on Apple silicon). Each world first runs the
/// demo performance for three seconds, as the previews do, on their fixed wall clock and with the real stars; then the
/// same frame is drawn 16 times and the last 12 timed. CI's GPUs are not the target Mac's, so this only reports.
@MainActor
final class WorldFrameTimeSweepTests: XCTestCase {
    /// The world's renderer once the demo performance has run `seconds` (the previews' dispatch, without a capture).
    static func renderer(themeID: String, seconds: Double, quality: QualityLevel, device: MTLDevice,
                         size: CGSize) -> ThemeRenderer? {
        let director = SceneDirector(themeID: themeID, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)   // the previews' fixed wall clock
        var elapsed = 0.0
        director.clock = { start.addingTimeInterval(elapsed) }
        var perf = PerformanceState()
        let script = ScriptedPerformance.demo
        var next = 0, time = 0.0
        let frameStep = 1.0 / 60
        let gentle = false
        var garden: ButterflyRenderer?, steinway: SteinwayRenderer?, moonlitLake: MoonlitLakeRenderer?
        var lounge: SpaceshipLoungeRenderer?, beach: GoldenHourBeachRenderer?, road: CoastRoadRenderer?
        var cabin: SnowboundCabinRenderer?
        var bedroom: BedroomDawnRenderer?
        var fjord: AuroraFjordRenderer?
        var bay: BioluminescentBayRenderer?
        var teaHouse: TeaHouseSnowRenderer?
        var zenGarden: ZenRockGardenRenderer?
        var submarine: SubmarineWindowRenderer?
        var reef: GreatBarrierReefRenderer?
        var plains: LightningPlainsRenderer?
        var supercell: SupercellSkyRenderer?
        var volcano: VolcanoRimRenderer?
        var drive: NeonNightDriveRenderer?
        var current: ThemeRenderer?
        while time + frameStep <= seconds || current == nil {
            time += frameStep
            var events: [PerformanceEvent] = []
            while next < script.count, script[next].time <= time {
                events += perf.apply(script[next].message, at: script[next].time)
                next += 1
            }
            director.handle(events, at: time)
            elapsed = time
            let frame = director.step(dt: frameStep, t: time, quality: quality)
            let dt = director.visualDt
            if let g = frame as? GardenFrame {
                if garden == nil { garden = ButterflyRenderer(device: device) }
                garden?.update(g, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = garden
            } else if let f = frame as? SteinwayFrame {
                if steinway == nil { steinway = SteinwayRenderer(device: device) }
                steinway?.update(f, quality: quality, gentle: gentle, dt: dt)
                current = steinway
            } else if let l = frame as? LakeFrame {
                if moonlitLake == nil { moonlitLake = MoonlitLakeRenderer(device: device) }
                moonlitLake?.update(l, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = moonlitLake
            } else if let l = frame as? LoungeFrame {
                if lounge == nil { lounge = SpaceshipLoungeRenderer(device: device) }
                lounge?.update(l, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = lounge
            } else if let b = frame as? BeachFrame {
                if beach == nil { beach = GoldenHourBeachRenderer(device: device) }
                beach?.update(b, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = beach
            } else if let r = frame as? RoadFrame {
                if road == nil { road = CoastRoadRenderer(device: device) }
                road?.update(r, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = road
            } else if let c = frame as? CabinFrame {
                if cabin == nil {
                    cabin = SnowboundCabinRenderer(device: device)
                    _ = cabin?.awaitField()   // the grown frost, as the app shows it once it has grown
                }
                cabin?.update(c, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = cabin
            } else if let b = frame as? BedroomFrame {
                if bedroom == nil {
                    bedroom = BedroomDawnRenderer(device: device)
                    _ = bedroom?.awaitField()
                }
                bedroom?.update(b, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = bedroom
            } else if let f = frame as? FjordFrame {
                if fjord == nil { fjord = AuroraFjordRenderer(device: device) }
                fjord?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = fjord
            } else if let y = frame as? BayFrame {
                if bay == nil { bay = BioluminescentBayRenderer(device: device) }
                bay?.update(y, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = bay
            } else if let h = frame as? TeaHouseFrame {
                if teaHouse == nil {
                    teaHouse = TeaHouseSnowRenderer(device: device)
                    _ = teaHouse?.awaitField()
                }
                teaHouse?.update(h, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = teaHouse
            } else if let z = frame as? ZenGardenFrame {
                if zenGarden == nil { zenGarden = ZenRockGardenRenderer(device: device) }
                zenGarden?.update(z, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = zenGarden
            } else if let w = frame as? SubFrame {
                if submarine == nil { submarine = SubmarineWindowRenderer(device: device) }
                submarine?.update(w, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = submarine
            } else if let f = frame as? ReefFrame {
                if reef == nil { reef = GreatBarrierReefRenderer(device: device) }
                reef?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = reef
            } else if let f = frame as? PlainsFrame {
                if plains == nil { plains = LightningPlainsRenderer(device: device) }
                plains?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = plains
            } else if let f = frame as? SupercellFrame {
                if supercell == nil { supercell = SupercellSkyRenderer(device: device) }
                supercell?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = supercell
            } else if let f = frame as? VolcanoFrame {
                if volcano == nil { volcano = VolcanoRimRenderer(device: device) }
                volcano?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = volcano
            } else if let f = frame as? DriveFrame {
                if drive == nil { drive = NeonNightDriveRenderer(device: device) }
                drive?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                current = drive
            }
            if time > seconds + 1 { break }   // (a world whose renderer can't be made: don't run on)
        }
        return current
    }

    func testEveryWorldFrameTime() throws {
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
        var timed = 0
        for world in ThemeRegistry.all {
            var parts: [String] = []
            for q in [QualityLevel.lite, .high] {
                let label = q == .lite ? "Smooth" : "High"
                guard let r = Self.renderer(themeID: world.id, seconds: 3, quality: q, device: device, size: size) else {
                    XCTFail("\(world.id) \(label): no renderer")
                    parts.append("\(label) none")
                    continue
                }
                var scene: [Double] = [], whole: [Double] = []
                for i in 0..<16 {
                    guard let cb = queue.makeCommandBuffer() else { continue }
                    r.render(stack: stack, commandBuffer: cb)
                    cb.commit()
                    cb.waitUntilCompleted()
                    let sceneMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                    guard let cb2 = queue.makeCommandBuffer() else { continue }
                    r.render(stack: stack, commandBuffer: cb2)
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = target
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    stack.post(into: pass, commandBuffer: cb2, settings: r.post)
                    cb2.commit()
                    cb2.waitUntilCompleted()
                    let wholeMs = (cb2.gpuEndTime - cb2.gpuStartTime) * 1000
                    if i >= 4 {
                        scene.append(sceneMs)
                        whole.append(wholeMs)
                    }
                }
                scene.sort()
                whole.sort()
                let sceneMedian = scene.isEmpty ? 0 : scene[scene.count / 2]
                let wholeMedian = whole.isEmpty ? 0 : whole[whole.count / 2]
                let slowest = whole.last ?? 0
                parts.append(String(format: "%@ scene %.2f ms, scene+finish %.2f ms (slowest %.2f)", label, sceneMedian,
                                    wholeMedian, slowest))
                XCTAssertGreaterThan(wholeMedian, 0, "\(world.id) \(label)")
                timed += 1
            }
            // One line a world (both qualities), so the looks job's report (its last 60 lines) keeps every world.
            print("FRAME TIME sweep \(world.id) 1280x720 (medians of 12): " + parts.joined(separator: "; "))
        }
        let expected = ThemeRegistry.all.count * 2
        XCTAssertEqual(timed, expected)
    }
}
