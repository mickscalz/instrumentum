import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// Lightning Plains (Set 18's world) with Strike Lines (Storms spec §9; plan Task 12). Assertions are plain statements over
/// named locals, so the type-checker finishes quickly in CI.
@MainActor
final class LightningPlainsRendererTests: XCTestCase {
    func testPlainsShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: LightningPlainsShaders.source, options: nil)
        for name in ["plains_vertex", "plains_scene_fragment", "plains_bolt_vertex", "plains_bolt_fragment",
                     "plains_prop_vertex", "plains_prop_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        // Built on the Sky, with no powers of its own.
        let kit = SkyShaders.common
        XCTAssertTrue(LightningPlainsShaders.source.hasPrefix(kit))
        let own = String(LightningPlainsShaders.source.dropFirst(kit.count))
        let hasPow = own.contains("pow(")
        let usesSky = own.contains("skyRadiance(")
        XCTAssertFalse(hasPow, "squares and powers are written out")
        XCTAssertTrue(usesSky, "the real sky, stars and all")
        // The Swift uniform array matches the MSL struct byte for byte (the pipelines' own reflection).
        let row = MemoryLayout<SIMD4<Float>>.stride
        for (vertex, fragment) in [("plains_vertex", "plains_scene_fragment"), ("plains_prop_vertex", "plains_prop_fragment")] {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vertex)
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            var reflection: MTLAutoreleasedRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
            let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
            let skySize = buffers.first { $0.index == 0 }?.bufferDataSize
            let plainsSize = buffers.first { $0.index == 1 }?.bufferDataSize
            XCTAssertEqual(skySize, SkyLayer.uniformCount * row, "\(fragment): SkyU")
            XCTAssertEqual(plainsSize, LightningPlainsRenderer.uniformCount * row, "\(fragment): PlainsU")
        }
        XCTAssertEqual(LightningPlainsRenderer.towerBRow, LightningPlainsRenderer.towerARow + 5)
        XCTAssertEqual(LightningPlainsRenderer.lightARow, LightningPlainsRenderer.towerBRow + 5)
        XCTAssertEqual(LightningPlainsRenderer.lightCRow, LightningPlainsRenderer.lightARow + LightningPlainsRenderer.lightSlots)
        XCTAssertEqual(LightningPlainsRenderer.rimRow, LightningPlainsRenderer.lightCRow + LightningPlainsRenderer.lightSlots)
        XCTAssertEqual(LightningPlainsRenderer.uniformCount, LightningPlainsRenderer.rimRow + LightningPlainsRenderer.rimSlots)
        let bytes = LightningPlainsRenderer.uniformCount * row
        XCTAssertLessThanOrEqual(bytes, 4096, "one setFragmentBytes call")
        let r = try XCTUnwrap(LightningPlainsRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, LightningPlainsRenderer.uniformCount)
        XCTAssertEqual(r.bufferAllocations, 3, "the instance buffers are made once, before the first frame")
        XCTAssertEqual(LightningPlainsRenderer.grassRows(.high), 48)
        XCTAssertEqual(LightningPlainsRenderer.grassRows(.lite), 24)
    }

    // MARK: - The rig

    /// Frozen skies over Melbourne (the frozen clock shows the equinox's sun: due west at sunset, about 19:27).
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.1) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    /// The light follows the frozen sky (not the default held blue hour), and no meteors move the frames.
    nonisolated static var following: ThemeState {
        ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue), "meteors.mode": .choice(MeteorMode.never.rawValue)])
    }

    struct PlainsShot {
        var image: CGImage
        var renderer: LightningPlainsRenderer
        var frame: PlainsFrame
    }

    /// What a step plays: its events and, to stage a moment, the Excitement frame to hand the world instead of the
    /// machine's own.
    typealias Script = (_ step: Int, _ t: Double) -> (events: [PerformanceEvent], excitement: ExcitementFrame?)

    /// Steps the plains at 60 fps for `seconds` as the director would (the Living Sky with the world's own sky choices,
    /// Excitement from the notes), playing `script`, and renders the last frame; `edit` changes each frame before the
    /// renderer sees it.
    static func renderPlains(seconds: Double, sky: SkySettings = LightningPlainsRendererTests.sky(hour: 19.75),
                             state: ThemeState = LightningPlainsRendererTests.following, quality: QualityLevel = .high,
                             gentle: Bool = false, width: Int = 640, height: Int = 360, script: Script? = nil,
                             edit: ((inout PlainsFrame) -> Void)? = nil,
                             each: ((LightningPlainsRenderer, PlainsFrame) -> Void)? = nil,
                             preview reuse: PreviewRenderer? = nil) throws -> PlainsShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview: PreviewRenderer
        if let reuse { preview = reuse } else { preview = try XCTUnwrap(PreviewRenderer(width: width, height: height)) }
        let r = try XCTUnwrap(LightningPlainsRenderer(device: device))
        let params = ThemeRegistry.parameterSet(for: LightningPlainsModel.id, state: state)
        let living = LivingSky(settings: sky)
        living.reset(settings: sky)
        let hold = SkyHold(rawValue: params.choice("light.hold")) ?? .follow
        let meteors = MeteorMode(rawValue: params.choice("meteors.mode")) ?? .follow
        let storm = StormInputs(crawlers: SkyExtraMode(rawValue: params.choice(SkyExtraMode.crawlersID)),
                                sheet: SkyExtraMode(rawValue: params.choice(SkyExtraMode.sheetID)),
                                randomExtras: WorldWeather.randomExtras(for: LightningPlainsModel.id))
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var model = LightningPlainsModel()
        model.mood = .plainsVast
        var excitement = Excitement()
        let size = CGSize(width: preview.width, height: preview.height)
        var last: PlainsFrame?
        let steps = max(1, Int((seconds * 60).rounded()))
        for i in 1...steps {
            let t = Double(i) / 60
            let played = script?(i, t) ?? (events: [], excitement: nil)
            for e in played.events {
                model.handle(e)
                switch e {
                case let .noteOn(note, velocity): excitement.noteOn(Int(note), velocity: velocity)
                case let .noteOff(note): excitement.noteOff(Int(note))
                default: break
                }
            }
            var ef = excitement.step(dt: 1.0 / 60)
            if let staged = played.excitement { ef = staged }
            model.setExcitement(ef)
            let s = living.step(now: start.addingTimeInterval(t), dt: 1.0 / 60, hold: hold, aurora: .follow, meteors: meteors,
                                storm: storm)
            model.setSky(s)
            var f = model.step(dt: 1.0 / 60, params: params, roles: RoleValues(), inputs: InputFrame(), quality: quality)
            edit?(&f)
            r.update(f, params: params, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
            each?(r, f)
            last = f
        }
        let frame = try XCTUnwrap(last)
        let image = try XCTUnwrap(preview.capture(r))
        return PlainsShot(image: image, renderer: r, frame: frame)
    }

    /// A key struck every `gap` seconds from `from` (held a tenth of a second each time).
    static func repeating(_ note: UInt8, every gap: Double, from: Double, until: Double = 1e9, velocity: Float = 0.75) -> Script {
        return { _, t in
            var events: [PerformanceEvent] = []
            let k = ((t - from) / gap).rounded()
            let at = from + k * gap
            if k >= 0, at <= until + 1e-9, abs(t - at) < 0.5 / 60 { events.append(.noteOn(note: note, velocity: velocity)) }
            let j = ((t - from - 0.1) / gap).rounded()
            let off = from + 0.1 + j * gap
            if j >= 0, abs(t - off) < 0.5 / 60 { events.append(.noteOff(note: note)) }
            return (events, nil)
        }
    }

    /// A chord at `at` seconds (and a big moment with it when `moment`; a drop when `drop`).
    static func chord(_ notes: [UInt8], at: Double, velocity: Float = 0.8, moment: Bool = false, drop: Bool = false) -> Script {
        return { _, t in
            guard abs(t - at) < 0.5 / 60 else { return ([], nil) }
            let events = notes.map { PerformanceEvent.noteOn(note: $0, velocity: velocity) }
            guard moment || drop else { return (events, nil) }
            var e = ExcitementFrame()
            e.energy = 0.85
            e.visualEnergy = 0.85
            e.drop = drop ? 1 : 0
            e.moment = BigMoment(kind: .chord, strength: 0.95, low: drop, isDrop: drop)
            return (events, e)
        }
    }

    static func both(_ a: @escaping Script, _ b: @escaping Script) -> Script {
        return { i, t in
            let x = a(i, t), y = b(i, t)
            return (x.events + y.events, y.excitement ?? x.excitement)
        }
    }

    // MARK: - The look

    private struct LightCase { let name: String; let hour: Double; let weather: WeatherKind; let mean: Double; let variance: Double }

    /// Dusk, night, virga and the drop, on High and Smooth: structured frames (a bright western rim under a darkening
    /// sky, the storm on it, the plain below), every grass row on the wind field and all 88 posts.
    func testPlainsPreviewIsStructured() throws {
        let cases = [
            LightCase(name: "dusk", hour: 19.75, weather: .clear, mean: 0.04, variance: 0.002),
            LightCase(name: "night", hour: 21.2, weather: .clear, mean: 0.006, variance: 0.0002),
            LightCase(name: "virga", hour: 19.85, weather: .virga, mean: 0.03, variance: 0.001),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try Self.renderPlains(seconds: 2.0, sky: Self.sky(hour: c.hour, weather: c.weather), quality: q,
                                                 script: Self.chord([52, 55, 59], at: 1.98))
                let stats = PreviewRenderer.stats(shot.image)
                let rows = shot.renderer.grassRowCount
                let posts = shot.renderer.postRects.count
                let forks = shot.renderer.forkSegmentCount
                XCTAssertGreaterThan(stats.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(stats.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(rows, LightningPlainsRenderer.grassRows(q), "\(q) \(c.name): grass rows by quality")
                XCTAssertEqual(posts, 88, "\(q) \(c.name)")
                XCTAssertGreaterThan(forks, 10, "\(q) \(c.name): the chord's fork is drawn")
            }
        }
        // The sky is nine-tenths of the frame; at dusk the last sun, behind you, lights the middle storm's head rose and
        // gold above Earth's shadow, brighter than the darkening zenith, while its foot stands in the shadow.
        let dusk = try Self.renderPlains(seconds: 1, sky: Self.sky(hour: 19.75))
        let hero = StrikeLines.view(StrikeLines.towers[2], stormKm: dusk.frame.distanceKm)
        let headAt = dusk.renderer.skyPoint(azimuth: dusk.frame.stormBearing + hero.offset + 0.2 * hero.halfWidth,
                                            altitude: hero.top * 0.85)
        let footAt = dusk.renderer.skyPoint(azimuth: dusk.frame.stormBearing + hero.offset + 0.2 * hero.halfWidth,
                                            altitude: hero.top * 0.3)
        let hx = Double(headAt?.x ?? 0), hy = Double(headAt?.y ?? 0)
        let fx = Double(footAt?.x ?? 0), fy = Double(footAt?.y ?? 0)
        let head = FramePatch.meanRGB(dusk.image, x: (hx - 0.02) ... (hx + 0.02), y: (hy - 0.02) ... (hy + 0.02))
        let foot = FramePatch.meanRGB(dusk.image, x: (fx - 0.02) ... (fx + 0.02), y: (fy - 0.02) ... (fy + 0.02))
        let high = FramePatch.meanRGB(dusk.image, x: -0.9 ... 0.9, y: 0.8 ... 0.95)
        let headLuma = 0.2126 * head.x + 0.7152 * head.y + 0.0722 * head.z
        let footLuma = 0.2126 * foot.x + 0.7152 * foot.y + 0.0722 * foot.z
        let highLuma = 0.2126 * high.x + 0.7152 * high.y + 0.0722 * high.z
        XCTAssertNotNil(headAt)
        XCTAssertGreaterThan(headLuma, highLuma, "the sunlit head over a darkening zenith: \(head) vs \(high)")
        XCTAssertGreaterThan(head.x, head.z * 1.2, "rose and gold: \(head)")
        XCTAssertGreaterThan(headLuma, footLuma, "the foot in Earth's shadow: \(head) vs \(foot)")
        XCTAssertEqual(dusk.renderer.horizonY, -0.72, accuracy: 1e-6)
    }

    /// A fork is drawn as its channel and its 4–7 branches: the channel runs from the cloud base down to the horizon and
    /// is brighter than the sky beside it; each branch leaves it.
    func testForkHasItsBranches() throws {
        let sky = Self.sky(hour: 21.2)
        // A strike 8 km off at night (the storm drawn there for this test), caught at its first stroke.
        let shot = try Self.renderPlains(seconds: 1.0 + 1.0 / 60, sky: sky,
                                         script: Self.chord([60, 64, 67], at: 1.0),
                                         edit: { f in
                                             f.distanceKm = 8
                                             for k in f.strikes.indices { f.strikes[k].km = 8 }
                                         })
        let quiet = try Self.renderPlains(seconds: 1.0 + 1.0 / 60, sky: sky, edit: { f in f.distanceKm = 8 })
        let r = shot.renderer
        let paths = r.lastFork
        XCTAssertGreaterThanOrEqual(paths.count, 4)
        XCTAssertLessThanOrEqual(paths.count, 7)
        let main = try XCTUnwrap(paths.first)
        let top = try XCTUnwrap(main.first)
        let foot = try XCTUnwrap(main.last)
        XCTAssertGreaterThan(top.y, foot.y, "from the cloud base down")
        XCTAssertLessThan(abs(foot.y - r.horizonY), 0.05, "to the horizon")
        // Along the channel the frame is brighter than without the strike.
        var brighter = 0
        for k in 1..<max(2, main.count - 1) {
            let pt = main[k]
            let box = (x: Double(pt.x - 0.012) ... Double(pt.x + 0.012), y: Double(pt.y - 0.012) ... Double(pt.y + 0.012))
            let on = FramePatch.brightest(shot.image, x: box.x, y: box.y, share: 0.2)
            let off = FramePatch.brightest(quiet.image, x: box.x, y: box.y, share: 0.2)
            if on > off + 0.08 { brighter += 1 }
        }
        XCTAssertGreaterThanOrEqual(brighter, (main.count - 2) / 2, "the channel is lit along its length")
        // Each branch starts on the channel (a node of it) and ends away from it.
        for b in paths.dropFirst() {
            guard let start = b.first, let end = b.last else { continue }
            var nearest: Float = 1e9
            for pt in main { nearest = min(nearest, simd_length(pt - start)) }
            let away = simd_length(end - start)
            XCTAssertLessThan(nearest, 1e-4, "a branch forks off the channel")
            XCTAssertGreaterThan(away, 0.002, "and reaches away from it")
        }
        let segments = r.forkSegmentCount
        XCTAssertGreaterThanOrEqual(segments, main.count - 1 + (paths.count - 1))
    }

    /// The repeated note lights the same post again and again, brighter each time.
    func testLitPostBrightensWithRepeats() throws {
        let sky = Self.sky(hour: 21.2)
        let note: UInt8 = 57
        let index = Int(note) - 21
        var glows: [Float] = []
        let script = Self.repeating(note, every: 0.4, from: 0.5, until: 3.3)
        let shot = try Self.renderPlains(seconds: 3.32, sky: sky, script: script, each: { r, _ in
            glows.append(r.postGlow[index])
        })
        let first = try Self.renderPlains(seconds: 0.52, sky: sky, script: script)
        let firstGlow = first.renderer.postGlow[index]
        let lastGlow = shot.renderer.postGlow[index]
        XCTAssertGreaterThan(firstGlow, 0.2, "the first note lights its post")
        XCTAssertGreaterThan(lastGlow, firstGlow * 1.6, "brighter with each repeat: \(firstGlow) → \(lastGlow)")
        // On screen: the post's top glows brighter after the repeats.
        let rect = shot.renderer.postRects[index]
        let box = (x: Double(rect.x - 0.02) ... Double(rect.z + 0.02), y: Double(rect.w - 0.03) ... Double(rect.w + 0.03))
        let afterRGB = FramePatch.meanRGB(shot.image, x: box.x, y: box.y)
        let onceRGB = FramePatch.meanRGB(first.image, x: box.x, y: box.y)
        let after = 0.2126 * afterRGB.x + 0.7152 * afterRGB.y + 0.0722 * afterRGB.z
        let once = 0.2126 * onceRGB.x + 0.7152 * onceRGB.y + 0.0722 * onceRGB.z
        XCTAssertGreaterThan(after, once + 0.02, "\(once) → \(after)")
        // Only that post is lit.
        var others: Float = 0
        for (i, g) in shot.renderer.postGlow.enumerated() where i != index { others = max(others, g) }
        XCTAssertEqual(others, 0)
        XCTAssertFalse(glows.isEmpty)
    }

    /// The drop's rain curtain crosses the view: its foot comes down the plain from the horizon toward you over 2.5 s,
    /// veiling the storm and the far plain as it comes.
    func testRainCurtainCrossesTheView() throws {
        let sky = Self.sky(hour: 20.45)
        var feet: [Float] = []
        let script = Self.chord([40, 44, 47], at: 0.5, velocity: 1, drop: true)
        let early = try Self.renderPlains(seconds: 0.45, sky: sky, script: script)
        let late = try Self.renderPlains(seconds: 2.98, sky: sky, script: script, each: { r, f in
            if f.rainCurtain > 0, f.rainCurtain < 1, let foot = r.curtainFootY { feet.append(foot) }
        })
        XCTAssertGreaterThan(feet.count, 60, "it crosses over 2.5 s")
        var upward = 0
        for k in 1..<feet.count where feet[k] > feet[k - 1] + 1e-5 { upward += 1 }
        XCTAssertEqual(upward, 0, "its foot only comes toward you")
        let firstFoot = feet.first ?? -1
        let lastFoot = feet.last ?? 0
        XCTAssertGreaterThan(firstFoot, -0.8, "it sets out on the far plain")
        XCTAssertLessThan(lastFoot, -0.95, "and reaches you")
        // The far plain and the storm's base are veiled by it.
        let band = (x: -0.9 ... 0.9, y: -0.7 ... -0.6)
        let before = FramePatch.meanRGB(early.image, x: band.x, y: band.y)
        let veiled = FramePatch.meanRGB(late.image, x: band.x, y: band.y)
        let change = abs(before.x - veiled.x) + abs(before.y - veiled.y) + abs(before.z - veiled.z)
        XCTAssertGreaterThan(change, 0.02, "\(before) → \(veiled)")
        XCTAssertGreaterThan(late.frame.sky.rain, 0.5, "and then it rains on you")
    }

    /// Gentle visuals: strikes become glows (soft, at under 55% of their light), the drop's sheet-lit sky halves.
    func testPlainsHonoursGentleVisuals() throws {
        let sky = Self.sky(hour: 21.2)
        let script = Self.both(Self.chord([60, 64, 67], at: 0.5), Self.chord([40, 44, 47], at: 2.0, velocity: 1, drop: true))
        var plain = (strike: Float(0), sheet: Float(0), core: Float(0))
        var gentle = plain
        _ = try Self.renderPlains(seconds: 2.4, sky: sky, script: script, each: { r, _ in
            plain.strike = max(plain.strike, r.strikeOut)
            plain.sheet = max(plain.sheet, r.sheetOut)
            plain.core = max(plain.core, r.firstCore)
        })
        _ = try Self.renderPlains(seconds: 2.4, sky: sky, gentle: true, script: script, each: { r, _ in
            gentle.strike = max(gentle.strike, r.strikeOut)
            gentle.sheet = max(gentle.sheet, r.sheetOut)
            gentle.core = max(gentle.core, r.firstCore)
        })
        XCTAssertGreaterThan(plain.strike, 0.5, "a strike lights the storm")
        XCTAssertGreaterThan(plain.sheet, 0.4, "the drop sheet-lights the sky")
        XCTAssertLessThanOrEqual(gentle.strike, plain.strike * 0.55, "gentle: a glow")
        XCTAssertLessThanOrEqual(gentle.sheet, plain.sheet * 0.55)
        XCTAssertGreaterThan(gentle.core, plain.core * 2, "soft, wide channels")
    }

    /// Reduce Motion (the app makes it Gentle visuals too): no camera shake, the windmill's turning capped, Excitement's
    /// energy for drawing capped at 0.5.
    func testPlainsHonoursReduceMotion() throws {
        var shook: Float = 0
        var still: Float = 0
        let shake: (inout PlainsFrame) -> Void = { f in f.cameraShake = SIMD2(5, -3); f.windmillRPM = 140 }
        _ = try Self.renderPlains(seconds: 0.5, edit: shake, each: { r, _ in shook = max(shook, simd_length(r.shakeOffset)) })
        var fastest: Float = 0
        _ = try Self.renderPlains(seconds: 0.5, gentle: true, edit: shake, each: { r, _ in
            still = max(still, simd_length(r.shakeOffset))
            fastest = max(fastest, r.wheelRPM)
        })
        XCTAssertGreaterThan(shook, 4, "a close strike shakes the camera")
        XCTAssertEqual(still, 0, "but not under Reduce Motion")
        XCTAssertLessThanOrEqual(fastest, LightningPlainsRenderer.calmRPM, "the windmill turns calmly")
        // Through the director: Reduce Motion caps Excitement's energy for drawing.
        let d = SceneDirector(themeID: LightningPlainsModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.controls = SceneControls(reduceMotion: true)
        for i in 0..<120 {
            let t = Double(i) / 60
            d.handle((0..<6).map { k in .noteOn(note: UInt8(48 + (i + k) % 24), velocity: 1) }, at: t)
            _ = d.step(dt: 1.0 / 60, t: t, quality: .high)
        }
        let energy = d.excitementFrame.energy
        let visual = d.excitementFrame.visualEnergy
        XCTAssertGreaterThan(energy, 0.5)
        XCTAssertLessThanOrEqual(visual, 0.5)
    }

    func testPlainsFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360), (640, 360)] {
            let shot = try Self.renderPlains(seconds: 0.6, width: w, height: h, script: Self.chord([30, 64, 100], at: 0.55))
            let r = shot.renderer
            XCTAssertEqual(r.keyRects.count, 88)
            var outside = 0
            var previous: Float = -2
            var backwards = 0
            for k in r.keyRects {
                if k.x < -1 || k.z > 1 || k.y > 1 || k.w < -1 { outside += 1 }
                let middle = 0.5 * (k.x + k.z)
                if middle < previous { backwards += 1 }
                previous = middle
            }
            XCTAssertEqual(outside, 0, "\(w)×\(h): every post in the frame")
            XCTAssertEqual(backwards, 0, "\(w)×\(h): bass to treble, left to right")
            let first = r.keyRects[0], last = r.keyRects[87]
            let nearHeight = first.w - first.y
            let farHeight = last.w - last.y
            XCTAssertGreaterThan(nearHeight, farHeight * 2, "\(w)×\(h): the fence runs away from you")
            // The storm stands on the horizon, inside the view.
            let tower = StrikeLines.view(StrikeLines.towers[2], stormKm: shot.frame.distanceKm)
            let topOfTower = r.skyPoint(azimuth: shot.frame.stormBearing + tower.offset, altitude: tower.top)
            let ty = topOfTower?.y ?? 2
            let tx = topOfTower?.x ?? 2
            XCTAssertTrue(ty > r.horizonY && ty < 1, "\(w)×\(h): the middle tower's top at \(ty)")
            XCTAssertLessThan(abs(tx), 0.5, "\(w)×\(h)")
            let variance = PreviewRenderer.stats(shot.image).variance
            XCTAssertGreaterThan(variance, 0.001, "\(w)×\(h)")
        }
    }

    func testPlainsBurstStaysInBudget() throws {
        let sky = Self.sky(hour: 21.2)
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            var most = 0, props = 0, allocations = 0
            let burst: Script = { i, _ in
                var events = (0..<34).map { k in PerformanceEvent.noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.9) }
                events.append(.noteOn(note: 57, velocity: 0.9))
                var e = ExcitementFrame()
                e.energy = 1
                e.visualEnergy = 1
                e.tension = 1
                e.moment = BigMoment(kind: .chord, strength: 1, low: i % 30 == 0, isDrop: i % 30 == 0)
                return (events, e)
            }
            let shot = try Self.renderPlains(seconds: 1, sky: sky, quality: q, script: burst, each: { r, _ in
                most = max(most, r.segmentCount)
                props = max(props, r.propCount)
                allocations = max(allocations, r.bufferAllocations)
            })
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThanOrEqual(most, LightningPlainsRenderer.segmentBudget, "\(q)")
            XCTAssertLessThanOrEqual(props, LightningPlainsRenderer.propCapacity, "\(q)")
            XCTAssertEqual(allocations, 3, "\(q): no buffer made per frame")
            XCTAssertLessThan(elapsed, 6, "\(q)")
            XCTAssertGreaterThan(most, 0, "\(q): the strikes are drawn")
            let crawlers = shot.frame.crawlers.count
            XCTAssertLessThanOrEqual(crawlers, StrikeLines.crawlerSlots(q))
        }
    }
}

extension WorldPreviewTests {
    /// Lightning Plains' previews (plan Task 12) and the frame time at 1 MP (Review focus 7), printed as PLAINS_TIMING.
    func testWritePlainsPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        typealias T = LightningPlainsRendererTests
        // A slow figure under the storm: notes over two octaves, a chord now and then.
        let figure: T.Script = { i, t in
            var events: [PerformanceEvent] = []
            let notes: [UInt8] = [45, 52, 57, 60, 64, 57, 52, 48]
            let k = Int((t / 0.45).rounded())
            if abs(t - Double(k) * 0.45) < 0.5 / 60, k > 0 { events.append(.noteOn(note: notes[k % notes.count], velocity: 0.6)) }
            let j = Int(((t - 0.3) / 0.45).rounded())
            if abs(t - Double(j) * 0.45 - 0.3) < 0.5 / 60, j > 0 { events.append(.noteOff(note: notes[j % notes.count])) }
            return (events, nil)
        }
        let walk = T.repeating(57, every: 0.4, from: 0.5)
        let dropBuild = T.both(T.repeating(57, every: 0.36, from: 0.5, until: 6.0), T.chord([33, 40, 45, 52], at: 6.4, velocity: 1, drop: true))
        let cases: [(String, SkySettings, QualityLevel, Double, T.Script)] = [
            ("plains-dusk", T.sky(hour: 19.75), .high, 4.62, T.both(figure, T.chord([48, 52, 55], at: 4.6))),
            ("plains-night-stars", T.sky(hour: 21.2, phase: 0.05), .high, 6.03, T.both(figure, T.chord([55, 59, 62], at: 6.0))),
            ("plains-virga", T.sky(hour: 19.85, weather: .virga), .high, 4.62, T.both(figure, T.chord([50, 53, 57], at: 4.6))),
            ("plains-walk-t20", T.sky(hour: 20.1), .high, 19.72, walk),
            ("plains-drop", T.sky(hour: 20.45), .high, 6.58, dropBuild),
            ("plains-smooth", T.sky(hour: 19.75), .lite, 4.62, T.both(figure, T.chord([48, 52, 55], at: 4.6))),
        ]
        for (name, s, q, t, script) in cases {
            let shot = try T.renderPlains(seconds: t, sky: s, quality: q, script: script, preview: preview)
            try PreviewRenderer.writePNG(shot.image, to: url.appendingPathComponent("\(name).png"))
            let sunAlt = String(format: "%.1f", shot.frame.sky.sun.altitude)
            let km = String(format: "%.1f", shot.frame.distanceKm)
            print("PLAINS_PREVIEW \(name): sun \(sunAlt)°, camera \(Int(shot.frame.cameraAzimuth))°, storm \(km) km, \(shot.frame.strikes.count) forks, \(shot.renderer.segmentCount) segments")
        }

        // The frame time at 1 MP (1334 × 750), the world's own passes on the GPU, Smooth and High.
        guard let queue = device.makeCommandQueue(), let stack = RenderStack(device: device, pixelFormat: .bgra8Unorm) else { return }
        stack.resize(width: 1334, height: 750)
        for q in [QualityLevel.lite, .high] {
            var times: [Double] = []
            var renderer: LightningPlainsRenderer?
            _ = try T.renderPlains(seconds: 3, sky: T.sky(hour: 19.9), quality: q, width: 1334, height: 750, script: walk,
                                   each: { r, _ in renderer = r })
            guard let r = renderer else { continue }
            for _ in 0..<40 {
                guard let cb = queue.makeCommandBuffer() else { continue }
                r.render(stack: stack, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                let gpu = cb.gpuEndTime - cb.gpuStartTime
                if gpu > 0 { times.append(gpu * 1000) }
            }
            times.sort()
            let median = times.isEmpty ? -1 : times[times.count / 2]
            let best = times.first ?? -1
            print("PLAINS_TIMING \(q.rawValue) 1334x750: median \(String(format: "%.2f", median)) ms, best \(String(format: "%.2f", best)) ms over \(times.count) frames")
        }

        // The same measure for the Spaceship Lounge on the same machine, for reference (the runner's GPU is virtual).
        let director = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var loungeFrame: LoungeFrame?
        for k in 0..<120 {
            let t = Double(k) / 60
            if let f = director.step(dt: 1.0 / 60, t: t, quality: .high) as? LoungeFrame { loungeFrame = f }
        }
        if let f = loungeFrame, let lounge = SpaceshipLoungeRenderer(device: device) {
            for q in [QualityLevel.lite, .high] {
                lounge.update(f, params: director.parameters, quality: q, gentle: false, dt: 1.0 / 60,
                              size: CGSize(width: 1334, height: 750))
                var times: [Double] = []
                for _ in 0..<40 {
                    guard let cb = queue.makeCommandBuffer() else { continue }
                    lounge.render(stack: stack, commandBuffer: cb)
                    cb.commit()
                    cb.waitUntilCompleted()
                    let gpu = cb.gpuEndTime - cb.gpuStartTime
                    if gpu > 0 { times.append(gpu * 1000) }
                }
                times.sort()
                let median = times.isEmpty ? -1 : times[times.count / 2]
                print("PLAINS_TIMING lounge-reference \(q.rawValue) 1334x750: median \(String(format: "%.2f", median)) ms over \(times.count) frames")
            }
        }
    }
}
