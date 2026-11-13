import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Excitement drawn in Bioluminescent Bay (Fire & Neon spec §5.5, §12, §13), as in the four worlds before it: a big moment
/// (the wave of light) changes the frame, every surprise draws and ends within its time, the glow gathers and breaks, a
/// hammered minute stays inside the flash limiter (and under gentle visuals never flashes); the sand darkens under heavy
/// cloud. And Coast Road's day moment drawn.
@MainActor
final class ExcitementBayRendererTests: XCTestCase {
    typealias T = ExcitementWorldsRendererTests

    /// The bay's previews' night (17:00 on the frozen date: Crux over the left headland; the world holds Deep night).
    nonisolated static func night() -> SkySettings { T.sky(hour: 17, phase: 0.1) }

    static func bay(_ seconds: Double, _ plan: T.Plan = T.Plan(), sky: SkySettings = ExcitementBayRendererTests.night(),
                    each: ((Int, BioluminescentBayRenderer, BayFrame) -> Void)? = nil) throws -> T.Shot<BayFrame, BioluminescentBayRenderer> {
        try T.shoot(BioluminescentBayModel.self, seconds: seconds, sky: sky, plan: plan, make: { BioluminescentBayRenderer(device: $0) },
                    update: { r, f, p, q, g, size in r.update(f, params: p, quality: q, gentle: g, dt: 1.0 / 60, size: size) }, each: each)
    }

    /// The road by day: following the sky at 18:36 on the frozen date (the sun about 10° up, low over the sea in view).
    nonisolated static func roadDay() -> T.Plan {
        T.Plan(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
    }

    func testBayShadersCompileWithTheirRows() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, BioluminescentBayRenderer.uniformCount)
        XCTAssertEqual(BioluminescentBayRenderer.patchBase, BioluminescentBayRenderer.headerCount)
        XCTAssertEqual(BioluminescentBayRenderer.waveFrontOut(0), BioluminescentBayRenderer.mouthOut, accuracy: 0.5)
        XCTAssertLessThan(BioluminescentBayRenderer.waveFrontOut(1), BioluminescentBayRenderer.waterline)
    }

    func testBayMomentChangesTheFrame() throws {
        let calm = try Self.bay(2.5)
        let wave = try Self.bay(2.5, T.Plan(moments: [60: T.chord(1)]))
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(wave.image)
        XCTAssertGreaterThan(T.changed(a, b), 0.02, "the wave of light across the bay")
        XCTAssertGreaterThan(wave.renderer.waveOut, 0.5)
        XCTAssertEqual(calm.renderer.waveOut, 0)
        // By day the plankton can't be seen: no wave.
        var noon = T.sky(hour: 13, phase: 0.5); noon.weather = .clear
        let day = try Self.bay(2.5, T.Plan(moments: [60: T.chord(1)], values: ["light.hold": .choice(SkyHold.follow.rawValue)],
                                           capture: false), sky: noon)
        XCTAssertEqual(day.renderer.waveOut, 0)
    }

    func testBaySurprisesAllPlay() throws {
        for i in 0..<3 {
            let seconds = Double(BioluminescentBayModel.surpriseSeconds[i]) + 0.6
            var drew = false
            let shot = try Self.bay(seconds, T.Plan(surprises: [10: WorldSurprise(index: i, seed: 11)], width: 160, height: 90,
                                                    capture: false)) { k, r, _ in
                guard k > 10 else { return }
                switch i {
                case 0: if r.mantaDrawn { drew = true }
                case 1: if r.turtleDrawn { drew = true }
                default: if r.worldMeteorsShown > 0 { drew = true }
                }
            }
            XCTAssertTrue(drew, "surprise \(i)")
            XCTAssertTrue(shot.frame.surprises.isEmpty, "surprise \(i) ends within its time")
            XCTAssertFalse(shot.renderer.mantaDrawn)
            XCTAssertFalse(shot.renderer.turtleDrawn)
        }
    }

    func testBayGathersThenBreaks() throws {
        var gathered: Float = 0, calm: Float = 9, after: Float = 9, wave: Float = 0, sparkle: Float = 0
        _ = try Self.bay(5, T.Plan(tension: { $0 < 180 ? 0.8 : 0 }, moments: [180: T.chord(1, drop: true)], width: 160, height: 90,
                                   capture: false)) { i, r, _ in
            if i == 2 { calm = r.gatherOut }
            if i == 178 { gathered = r.gatherOut }
            if i == 260 { after = r.gatherOut }
            if i > 180 { wave = max(wave, r.waveOut); sparkle = max(sparkle, r.sparkleOut) }
        }
        XCTAssertGreaterThan(gathered, calm + 0.5, "the glow gathers under the surface")
        XCTAssertLessThan(after, 0.1, "then breaks")
        XCTAssertGreaterThan(wave, 0.8, "into the wave")
        XCTAssertGreaterThan(sparkle, 0.4, "with sparkles scattering")
    }

    func testBayHammeredMinuteStaysInsideTheFlashLimiter() throws {
        var worst = 0, total = 0
        _ = try Self.bay(60, T.Plan(energy: 1, tension: { _ in 1 }, moments: T.hammer(), width: 160, height: 90, capture: false)) { _, r, _ in
            worst = max(worst, r.flashesInLastSecond)
            total = r.flashTotal
        }
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
        XCTAssertLessThanOrEqual(total, 60 * FlashLimiter.maxFlashesPerSecond)
        var gentle = T.Plan(energy: 1, tension: { _ in 1 }, moments: T.hammer(), width: 160, height: 90, capture: false)
        gentle.gentle = true
        var gentleTotal = 0, glow: Float = 0
        var surprises: [Int: WorldSurprise] = [:]
        for k in stride(from: 30, to: 1200, by: 240) { surprises[k] = WorldSurprise(index: 2, seed: UInt64(k)) }
        gentle.surprises = surprises
        _ = try Self.bay(20, gentle) { _, r, _ in
            gentleTotal = r.flashTotal
            glow = max(glow, r.waveOut)
        }
        XCTAssertEqual(gentleTotal, 0, "gentle visuals glow, never flash")
        XCTAssertGreaterThan(glow, 0.2, "the wave still shows, as a slow glow")
        XCTAssertLessThanOrEqual(glow, 0.61)
    }

    /// Heavy cloud hides the sun and the moon: their direct light on the sand falls with it (a clear sky's is untouched).
    func testTheSandDarkensUnderHeavyCloud() throws {
        var moon = T.sky(hour: 23, phase: 0.55)
        let clear = try Self.bay(1, T.Plan(width: 160, height: 90, capture: false), sky: moon)
        XCTAssertEqual(clear.renderer.sandDirectOut, 1)
        moon.weather = .storm
        let storm = try Self.bay(1, T.Plan(width: 160, height: 90, capture: false), sky: moon)
        XCTAssertLessThan(storm.renderer.sandDirectOut, 0.1)
    }

    // MARK: - Coast Road by day

    func testRoadDayMomentChangesTheFrame() throws {
        let sky = T.sky(hour: 18.6)
        let calm = try T.road(2.5, Self.roadDay(), sky: sky)
        var plan = Self.roadDay()
        plan.moments = [60: T.chord(1)]
        let moment = try T.road(2.5, plan, sky: sky)
        let a = try XCTUnwrap(calm.image), b = try XCTUnwrap(moment.image)
        XCTAssertGreaterThan(T.changed(a, b), 0.02, "the sun breaking out, its glitter racing in, the gulls")
        XCTAssertGreaterThan(moment.renderer.dayOut, 0.5)
        XCTAssertGreaterThan(moment.renderer.birdsDrawn, 3)
        XCTAssertLessThan(moment.renderer.beamOut, 0.05, "the lighthouse dark by day")
        XCTAssertEqual(calm.renderer.dayOut, 0)
        // Gentle visuals: a slow swell, never a flash.
        var gentle = plan
        gentle.gentle = true
        gentle.moments = T.hammer()
        gentle.capture = false
        var flashes = 0, swell: Float = 0
        _ = try T.road(12, gentle, sky: sky) { _, r, _ in
            flashes = r.flashTotal
            swell = max(swell, r.dayOut)
        }
        XCTAssertEqual(flashes, 0)
        XCTAssertGreaterThan(swell, 0.2)
        XCTAssertLessThanOrEqual(swell, 0.61)
        // The hammered day stays inside the limiter.
        var hammered = plan
        hammered.moments = T.hammer()
        hammered.capture = false
        hammered.width = 160; hammered.height = 90
        var worst = 0
        _ = try T.road(30, hammered, sky: sky) { _, r, _ in worst = max(worst, r.flashesInLastSecond) }
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
    }
}

/// The looks run's previews for the bay's Excitement and Coast Road's day moment (PREVIEW_DIR), at 1280×720.
@MainActor
final class ExcitementBayPreviewTests: XCTestCase {
    typealias T = ExcitementWorldsRendererTests
    typealias B = ExcitementBayRendererTests

    private func folder() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ image: CGImage?, _ name: String, to url: URL) throws {
        try PreviewRenderer.writePNG(try XCTUnwrap(image), to: url.appendingPathComponent("\(name).png"))
    }

    private func big(_ plan: T.Plan = T.Plan()) -> T.Plan {
        var p = plan
        p.width = 1280
        p.height = 720
        return p
    }

    func testWriteBayExcitementPreviews() throws {
        let url = try folder()
        try write(try B.bay(3, big(T.Plan(energy: 0.3))).image, "excite-bay-calm", to: url)
        try write(try B.bay(6, big(T.Plan(energy: 1))).image, "excite-bay-energy", to: url)
        try write(try B.bay(4.5, big(T.Plan(energy: 0.6, tension: { _ in 0.9 }))).image, "excite-bay-gathered", to: url)
        // Mid-moment: 1.3 s after it, the wave half way in.
        let moment = T.Plan(energy: 0.6, moments: [120: T.chord(1)])
        try write(try B.bay(3.3, big(moment)).image, "excite-bay-moment", to: url)
        var gentle = moment
        gentle.gentle = true
        try write(try B.bay(3.3, big(gentle)).image, "excite-bay-moment-gentle", to: url)
        var smooth = moment
        smooth.quality = .lite
        try write(try B.bay(3.3, big(smooth)).image, "excite-bay-moment-smooth", to: url)
        // The arrival on the shore, 3.1 s in.
        try write(try B.bay(5.1, big(moment)).image, "excite-bay-moment-shore", to: url)
        // Build and drop: 4 s gathered, then 0.6 s after the drop.
        try write(try B.bay(4.6, big(T.Plan(energy: 0.6, tension: { $0 < 240 ? 0.9 : 0 }, moments: [240: T.chord(1, drop: true)]))).image,
                  "excite-bay-drop", to: url)
        try write(try B.bay(5.6, big(T.Plan(surprises: [10: WorldSurprise(index: 0, seed: 11)]))).image, "excite-bay-surprise-manta", to: url)
        try write(try B.bay(3.0, big(T.Plan(surprises: [10: WorldSurprise(index: 1, seed: 11)]))).image, "excite-bay-surprise-turtle", to: url)
        try write(try B.bay(1.7, big(T.Plan(surprises: [10: WorldSurprise(index: 2, seed: 11)]))).image, "excite-bay-surprise-fireball", to: url)
    }

    /// The reef's spawning burst four seconds in (its third puff), beside the PartB set's frame 0.6 s in.
    func testWriteReefBurstLatePreview() throws {
        let url = try folder()
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let rig = try PartBRig(.reef, width: 1280, height: 720)
        rig.run(120, PartBRig.excitement(energy: 0.6))
        rig.run(240, PartBRig.excitement(energy: 0.6, moment: PartBRig.chord(1)))
        try write(rig.capture(preview), "excite-reef-moment-4s", to: url)
    }

    func testWriteRoadDayExcitementPreviews() throws {
        let url = try folder()
        let day = T.sky(hour: 18.6), dusk = T.sky(hour: 19.45)
        try write(try T.road(3, big(B.roadDay()), sky: day).image, "excite-road-day-calm", to: url)
        var moment = B.roadDay()
        moment.moments = [90: T.chord(1)]
        try write(try T.road(3.3, big(moment), sky: day).image, "excite-road-day-moment", to: url)
        var gentle = moment
        gentle.gentle = true
        try write(try T.road(3.3, big(gentle), sky: day).image, "excite-road-day-moment-gentle", to: url)
        try write(try T.road(3.3, big(moment), sky: dusk).image, "excite-road-dusk-moment", to: url)
    }
}
