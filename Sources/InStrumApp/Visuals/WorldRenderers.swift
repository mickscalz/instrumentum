import Foundation
import Metal
import CoreGraphics
import InStrumCore

/// The canvas's renderers, one per theme, made off the main thread (real-Mac performance, 14 Nov 2026).
///
/// A renderer used to be made inside the first frame that showed its world: its shaders compiled and its pipelines built
/// on the main thread, which held that frame up for most of a second (two to ten on a cold shader cache) on Michael's
/// MacBook Pro. Now the warm-up makes them on `ShaderWork.queue`, one at a time, the world on screen first and then the
/// rest in menu order; once every world is made, it makes their skies' storm programs and the supercell's kernel there
/// too (the heavy extras, left until then). A frame whose world isn't made yet asks for it at the front of the line and
/// draws nothing new (the canvas keeps the last frame on screen, or a plain dark one at launch): nothing waits.
///
/// Tea House Snow and Zen Rock Garden are the exception: their renderers are main-actor classes and their files are left
/// as they are, so they are made on the main thread the first time they are shown, as before (counted in
/// `ShaderWork.drawPathBuilds`). Their sky, weather, warp and window layers come from the shared caches, so that build is
/// their own library and pipelines only.
@MainActor
final class WorldRenderers {
    enum Kind: Int, CaseIterable {
        case garden, steinway, lake, lounge, beach, road, cabin, bedroom, fjord, bay, teaHouse, zenGarden, submarine, reef,
             plains, supercell, volcano, drive

        /// Made on the main thread, when first shown (see the type's notes).
        var mainThreadOnly: Bool { self == .teaHouse || self == .zenGarden }
    }

    /// The kind that draws theme `id` (nil for an id no renderer draws).
    static func kind(forTheme id: String) -> Kind? {
        switch ThemeRegistry.resolve(id) {
        case ButterflyGardenModel.id: return .garden
        case MidnightSteinwayModel.id: return .steinway
        case MoonlitLakeModel.id: return .lake
        case SpaceshipLoungeModel.id: return .lounge
        case GoldenHourBeachModel.id: return .beach
        case CoastRoadModel.id: return .road
        case SnowboundCabinModel.id: return .cabin
        case BedroomDawnModel.id: return .bedroom
        case AuroraFjordModel.id: return .fjord
        case BioluminescentBayModel.id: return .bay
        case TeaHouseSnowModel.id: return .teaHouse
        case ZenRockGardenModel.id: return .zenGarden
        case SubmarineWindowModel.id: return .submarine
        case GreatBarrierReefModel.id: return .reef
        case LightningPlainsModel.id: return .plains
        case SupercellSkyModel.id: return .supercell
        case VolcanoRimModel.id: return .volcano
        case NeonNightDriveModel.id: return .drive
        default: return nil
        }
    }

    /// Makes a renderer, on whichever thread calls (nil for the main-thread-only kinds, and when it can't be made).
    nonisolated static func make(_ kind: Kind, device: MTLDevice) -> AnyObject? {
        switch kind {
        case .garden: return ButterflyRenderer(device: device)
        case .steinway: return SteinwayRenderer(device: device)
        case .lake: return MoonlitLakeRenderer(device: device)
        case .lounge: return SpaceshipLoungeRenderer(device: device)
        case .beach: return GoldenHourBeachRenderer(device: device)
        case .road: return CoastRoadRenderer(device: device)
        case .cabin: return SnowboundCabinRenderer(device: device)
        case .bedroom: return BedroomDawnRenderer(device: device)
        case .fjord: return AuroraFjordRenderer(device: device)
        case .bay: return BioluminescentBayRenderer(device: device)
        case .submarine: return SubmarineWindowRenderer(device: device)
        case .reef: return GreatBarrierReefRenderer(device: device)
        case .plains: return LightningPlainsRenderer(device: device)
        case .supercell: return SupercellSkyRenderer(device: device)
        case .volcano: return VolcanoRimRenderer(device: device)
        case .drive: return NeonNightDriveRenderer(device: device)
        case .teaHouse, .zenGarden: return nil
        }
    }

    /// A renderer made off the main thread, on its way to it.
    private struct Handoff: @unchecked Sendable {
        let object: AnyObject?
        let onMain: Bool
    }

    let device: MTLDevice
    private var shelf: [Kind: AnyObject] = [:]
    /// Kinds whose build has finished (made, or failed: not tried again).
    private(set) var made: Set<Kind> = []
    /// Kinds made off the main thread (tests).
    private(set) var madeOffMain: Set<Kind> = []
    /// Waiting to be made, the next first.
    private var order: [Kind] = []
    /// The kind on `ShaderWork.queue` now, and whether any job (a kind or an extra) is.
    private(set) var building: Kind?
    private var busy = false
    private var warming = false
    private var cellKernelWarmed = false, sourcesWarmed = false
    /// True once the warm-up has made every world and every extra.
    private(set) var warmedUp = false

    init(device: MTLDevice) {
        self.device = device
    }

    /// The warm-up: every world's renderer, `themeID`'s first, then the extras. Calling it again does nothing new.
    func warmUp(first themeID: String) {
        var kinds = Kind.allCases.filter { !$0.mainThreadOnly }
        if let first = Self.kind(forTheme: themeID), let i = kinds.firstIndex(of: first) {
            kinds.remove(at: i)
            kinds.insert(first, at: 0)
        }
        for k in kinds where !made.contains(k) && building != k && !order.contains(k) { order.append(k) }
        if !warming {
            warming = true
            ShaderWork.warmStarted = ProcessInfo.processInfo.systemUptime
            ShaderWork.worldsToWarm = kinds.count
            ShaderWork.worldsReady = made.filter { !$0.mainThreadOnly }.count
        }
        pump()
    }

    /// The renderer for `kind` if it is made (tests).
    func renderer(_ kind: Kind) -> AnyObject? { shelf[kind] }

    /// The renderer for this frame's theme, updated for it: nil while it is still being made (it is then asked for at the
    /// front of the line), or when it can't be made.
    func renderer(for frame: Any, params p: ParameterSet, quality q: QualityLevel, gentle g: Bool, dt: Double,
                  size: CGSize) -> ThemeRenderer? {
        if let f = frame as? GardenFrame {
            guard let r = ready(.garden, as: ButterflyRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? SteinwayFrame {
            guard let r = ready(.steinway, as: SteinwayRenderer.self) else { return nil }
            r.update(f, quality: q, gentle: g, dt: dt)
            return r
        } else if let f = frame as? LakeFrame {
            guard let r = ready(.lake, as: MoonlitLakeRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? LoungeFrame {
            guard let r = ready(.lounge, as: SpaceshipLoungeRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? BeachFrame {
            guard let r = ready(.beach, as: GoldenHourBeachRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? RoadFrame {
            guard let r = ready(.road, as: CoastRoadRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? CabinFrame {
            guard let r = ready(.cabin, as: SnowboundCabinRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? BedroomFrame {
            guard let r = ready(.bedroom, as: BedroomDawnRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? FjordFrame {
            guard let r = ready(.fjord, as: AuroraFjordRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? BayFrame {
            guard let r = ready(.bay, as: BioluminescentBayRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? TeaHouseFrame {
            guard let r = ready(.teaHouse, as: TeaHouseSnowRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? ZenGardenFrame {
            guard let r = ready(.zenGarden, as: ZenRockGardenRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? SubFrame {
            guard let r = ready(.submarine, as: SubmarineWindowRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? ReefFrame {
            guard let r = ready(.reef, as: GreatBarrierReefRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? PlainsFrame {
            guard let r = ready(.plains, as: LightningPlainsRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? SupercellFrame {
            guard let r = ready(.supercell, as: SupercellSkyRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? VolcanoFrame {
            guard let r = ready(.volcano, as: VolcanoRimRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        } else if let f = frame as? DriveFrame {
            guard let r = ready(.drive, as: NeonNightDriveRenderer.self) else { return nil }
            r.update(f, params: p, quality: q, gentle: g, dt: dt, size: size)
            return r
        }
        return nil
    }

    /// `kind`'s renderer if it is made. If not: a main-thread-only kind is made now (once); any other is asked for at
    /// the front of the line, and nil comes back.
    private func ready<R: AnyObject>(_ kind: Kind, as type: R.Type) -> R? {
        if let r = shelf[kind] { return r as? R }
        guard !made.contains(kind) else { return nil }   // it couldn't be made
        if kind.mainThreadOnly {
            made.insert(kind)
            ShaderWork.noteBuild("the \(kind) renderer")
            let r: AnyObject?
            switch kind {
            case .teaHouse: r = TeaHouseSnowRenderer(device: device)
            case .zenGarden: r = ZenRockGardenRenderer(device: device)
            default: r = Self.make(kind, device: device)
            }
            if let r { shelf[kind] = r }
            return r as? R
        }
        need(kind)
        return nil
    }

    /// Asks for `kind` next (a world being entered).
    private func need(_ kind: Kind) {
        guard !made.contains(kind), building != kind else { return }
        order.removeAll { $0 == kind }
        order.insert(kind, at: 0)
        pump()
    }

    /// Starts the next job if none is running: a world first, then (once the warm-up has made every world) one extra.
    private func pump() {
        guard !busy else { return }
        if !order.isEmpty {
            let kind = order.removeFirst()
            busy = true
            building = kind
            let device = self.device
            ShaderWork.queue.async {
                let handoff = Handoff(object: Self.make(kind, device: device), onMain: Thread.isMainThread)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(kind, handoff) } }
            }
            return
        }
        guard warming, !warmedUp else { return }
        if let next = SkyPipeline.nextUnwarmed() {
            let pipeline = next.pipeline, program = next.program
            runExtra { pipeline.warm(program) }
            return
        }
        if !cellKernelWarmed {
            cellKernelWarmed = true
            let device = self.device
            runExtra { SkyLayer.warmCellKernel(device: device) }
            return
        }
        if !sourcesWarmed {
            // The two worlds made on the main thread: their own libraries compiled once here, so the system's shader
            // cache has them when they are first shown.
            sourcesWarmed = true
            let device = self.device
            runExtra {
                for source in [TeaHouseSnowShaders.source, ZenRockGardenShaders.source] {
                    _ = try? device.makeLibrary(source: source, options: nil)
                }
            }
            return
        }
        warmedUp = true
        ShaderWork.warmFinished = ProcessInfo.processInfo.systemUptime
    }

    private func runExtra(_ job: @escaping @Sendable () -> Void) {
        busy = true
        ShaderWork.queue.async {
            job()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.extraFinished() } }
        }
    }

    private func finished(_ kind: Kind, _ handoff: Handoff) {
        busy = false
        building = nil
        made.insert(kind)
        if let object = handoff.object { shelf[kind] = object }
        if !handoff.onMain { madeOffMain.insert(kind) }
        if warming { ShaderWork.worldsReady = made.filter { !$0.mainThreadOnly }.count }
        pump()
    }

    private func extraFinished() {
        busy = false
        pump()
    }

    // MARK: - Tests

    /// Runs the main run loop until `kind` is made (or `timeout` seconds pass); true when it is.
    @discardableResult
    func awaitMade(_ kind: Kind, timeout: TimeInterval = 120) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !made.contains(kind), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return made.contains(kind)
    }

    /// Runs the main run loop until the warm-up has made everything (or `timeout` seconds pass); true when it has.
    @discardableResult
    func awaitWarmUp(timeout: TimeInterval = 900) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !warmedUp, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return warmedUp
    }
}
