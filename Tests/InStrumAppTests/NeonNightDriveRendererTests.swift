import XCTest
import Metal
@testable import InStrumApp
@testable import InStrumCore

/// Neon Night Drive's renderer, Light Trails and the windscreen (Fire & Neon spec §9, §12, §13; plan Task 14).
@MainActor
final class NeonNightDriveRendererTests: XCTestCase {
    // MARK: - Helpers

    /// Deep night over Melbourne on the previews' fixed date (the world holds deep night itself), with `weather`.
    nonisolated static func sky(hour: Double = 23, weather: WeatherKind = .clear) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = 0.3; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    /// Wired, the set's mood (spec §10).
    nonisolated static let wired = Mood(energy: 0.9, warmth: 0.3, brightness: 0.8, space: 0.55, motion: 0.95)

    nonisolated static func chord(_ strength: Float, drop: Bool = false) -> BigMoment {
        BigMoment(kind: .chord, strength: strength, low: false, isDrop: drop)
    }

    struct DriveShot {
        var image: CGImage?
        var renderer: NeonNightDriveRenderer
        var frame: DriveFrame
        var params: ParameterSet
    }

    /// Steps Neon Night Drive at 60 fps for `seconds` (or until `stop` says so) and renders the last frame. The director
    /// runs the Living Sky for the world; the world is stepped here so the tests choose its Excitement: `energy` and
    /// `tension` throughout, a big `moments[i]` on frame `i` (a drop's release then falls over 2.5 s), a surprise `surprises[i]`,
    /// the notes `notes(i)` struck on frame `i` (each let go 14 frames later, or `holds` held), the instrument's `pulse`.
    static func renderDrive(at seconds: Double, values: [String: ParamValue] = [:], hold: SkyHold = .deepNight,
                            weather: WeatherKind = .clear, quality: QualityLevel = .high, gentle: Bool = false,
                            reduceMotion: Bool = false, energy: Float = 0.4, tension: Float = 0,
                            moments: [Int: BigMoment] = [:], surprises: [Int: Int] = [:], pulse: InstrumentPulse? = nil,
                            notes: ((Int) -> [UInt8])? = nil, holds: Set<UInt8> = [], width: Int = 640, height: Int = 360,
                            capture: Bool = true, stop: ((Int, DriveFrame) -> Bool)? = nil,
                            edit: ((Int, inout DriveFrame) -> Void)? = nil,
                            each: ((Int, NeonNightDriveRenderer, DriveFrame) -> Void)? = nil) throws -> DriveShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(NeonNightDriveRenderer(device: device))
        var stateValues = values
        stateValues["light.hold"] = .choice(hold.rawValue)
        let state = ThemeState(values: stateValues)
        let d = SceneDirector(themeID: NeonNightDriveModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky(weather: weather))
        d.mood = wired
        var model = NeonNightDriveModel()
        model.mood = wired
        model.pulse = pulse
        let size = CGSize(width: width, height: height)
        let n = max(1, Int((seconds * 60).rounded()))
        var last: DriveFrame?
        var struck: [Int: [UInt8]] = [:]
        var dropAt: Int?
        for i in 1...n {
            let t = Double(i) / 60
            elapsed = t
            _ = d.step(dt: 1.0 / 60, t: t, quality: quality)
            if let s = d.lastSky { model.setSky(s) }
            var e = ExcitementFrame()
            e.energy = energy
            e.visualEnergy = reduceMotion ? min(energy, 0.5) : energy
            e.tension = tension
            e.reduceMotion = reduceMotion
            if let m = moments[i] {
                e.moment = m
                if m.isDrop { dropAt = i; e.tension = 0 }
            }
            if let at = dropAt {
                let since = Float(i - at) / 60
                e.drop = max(0, 1 - since / 2.5)
                e.tension = 0
            }
            if let k = surprises[i] { e.surprise = WorldSurprise(index: k, seed: UInt64(1000 + i)) }
            model.setExcitement(e)
            if i == 1 { for k in holds { model.handle(.noteOn(note: k, velocity: 0.85)) } }
            if let notes {
                let on = notes(i)
                for k in on { model.handle(.noteOn(note: k, velocity: 0.8)) }
                struck[i] = on
            }
            if let off = struck[i - 14] {
                for k in off where !holds.contains(k) { model.handle(.noteOff(note: k)) }
                struck[i - 14] = nil
            }
            var f = model.step(dt: 1.0 / 60, params: d.parameters, roles: RoleValues(), inputs: InputFrame(), quality: quality)
            edit?(i, &f)
            r.update(f, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
            each?(i, r, f)
            last = f
            if let stop, stop(i, f) { break }
        }
        let frame = try XCTUnwrap(last)
        var image: CGImage?
        if capture {
            let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
            image = preview.capture(r, exposureScale: d.exposureScale)
        }
        return DriveShot(image: image, renderer: r, frame: frame, params: d.parameters)
    }

    /// A melody over a bass line, with chords now and then.
    /// Six notes a frame across the keyboard (a hammering).
    nonisolated static func crowd(_ i: Int) -> [UInt8] {
        var notes: [UInt8] = []
        for k in 0..<6 {
            let n: Int = 21 + (i * 6 + k * 11) % 88
            notes.append(UInt8(n))
        }
        return notes
    }

    nonisolated static func playing(_ i: Int) -> [UInt8] {
        if i % 90 == 0 { return [48, 60, 64, 67] }
        if i % 20 == 0 { return [UInt8(62 + (i / 20 * 5) % 19)] }
        if i % 30 == 15 { return [UInt8(33 + (i / 30) % 12)] }
        return []
    }

    // MARK: - The shaders

    func testDriveShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: NeonNightDriveShaders.source, options: nil)
        for name in ["drive_vertex", "drive_scene_fragment", "drive_reflect_fragment"] {
            let function = lib.skyFunction(name)
            XCTAssertNotNil(function, name)
        }
        let trailsLib = try device.makeLibrary(source: LightTrailsShaders.source, options: nil)
        let trailsFn = trailsLib.skyFunction("trails_fragment")
        XCTAssertNotNil(trailsFn)
        let screenLib = try device.makeLibrary(source: WindscreenShaders.source, options: nil)
        for name in ["screen_vertex", "screen_glass_fragment", "screen_frame_fragment", "screen_copy_fragment"] {
            let function = screenLib.skyFunction(name)
            XCTAssertNotNil(function, name)
        }
        // Built on the Sky kit, with no powers of their own.
        let kit = SkyShaders.common
        let own = String(NeonNightDriveShaders.source.dropFirst(kit.count))
        let powers = own.contains("pow(")
        XCTAssertFalse(powers, "squares and powers are written out")
        let trailPowers = LightTrailsShaders.source.dropFirst(kit.count).contains("pow(")
        XCTAssertFalse(trailPowers)
        let screenPowers = WindscreenShaders.source.contains("pow(")
        XCTAssertFalse(screenPowers)
        let usesSky = own.contains("skyRadiance(")
        XCTAssertTrue(usesSky)
        // The Swift rows match the MSL structs byte for byte (the pipelines' own reflection).
        let row = MemoryLayout<SIMD4<Float>>.stride
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.skyFunction("drive_vertex")
        d.fragmentFunction = lib.skyFunction("drive_scene_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        let skyBytes = buffers.first { $0.index == 0 }?.bufferDataSize
        let driveBytes = buffers.first { $0.index == 1 }?.bufferDataSize
        XCTAssertEqual(skyBytes, SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(driveBytes, NeonNightDriveRenderer.uniformCount * row, "DriveU")
        XCTAssertLessThanOrEqual(NeonNightDriveRenderer.uniformCount * row, 4096, "one setFragmentBytes call")
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = screenLib.skyFunction("screen_vertex")
        sd.fragmentFunction = screenLib.skyFunction("screen_glass_fragment")
        sd.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        var screenReflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: sd, options: [.bindingInfo, .bufferTypeInfo], reflection: &screenReflection)
        let screenBuffers = (screenReflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        let screenBytes = screenBuffers.first { $0.index == 0 }?.bufferDataSize
        XCTAssertEqual(screenBytes, WindscreenLayer.uniformCount * row, "ScreenU")
        let td = MTLRenderPipelineDescriptor()
        td.vertexFunction = trailsLib.skyFunction("drive_vertex")
        td.fragmentFunction = trailsLib.skyFunction("trails_fragment")
        td.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        var trailsReflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: td, options: [.bindingInfo, .bufferTypeInfo], reflection: &trailsReflection)
        let trailBuffers = (trailsReflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        let trailsBytes = trailBuffers.first { $0.index == 2 }?.bufferDataSize
        XCTAssertEqual(trailsBytes, LightTrailsLayer.uniformCount * row, "TrailsU")
        // The rows' layout, end to end.
        typealias R = NeonNightDriveRenderer
        XCTAssertEqual(R.signBase, R.rowRoad3 + 1)
        XCTAssertEqual(R.studBase, R.signBase + R.signRows)
        XCTAssertEqual(R.carBase, R.studBase + R.studSlots)
        XCTAssertEqual(R.palBase, R.carBase + 2 * R.carSlots)
        XCTAssertEqual(R.rowMoon, R.palBase + R.palRows)
        XCTAssertEqual(R.rowCabin, R.rowMoon + 1)
        XCTAssertEqual(R.rowPillars, R.rowCabin + 1)
        XCTAssertEqual(R.uniformCount, R.rowPillars + 1)
        XCTAssertEqual(R.signRows * 4, NeonNightDriveModel.signCount)
        XCTAssertEqual(R.studSlots, NeonNightDriveModel.studCap)
        XCTAssertEqual(R.carSlots, NeonNightDriveModel.carCap)
        XCTAssertEqual(WindscreenLayer.keyRows * 4, 88)
        XCTAssertEqual(WindscreenLayer.uniformCount, WindscreenLayer.keyBase + WindscreenLayer.keyRows)
        // The world wraps seamlessly: every building cell, lamp, dash and post spacing divides it.
        for period in [64.0, 80.0, 60.0, 96.0, 40.0, 12.0, 2.4, 0.6] {
            let turns = R.worldWrap / period
            XCTAssertEqual(turns, turns.rounded(), accuracy: 1e-6, "\(period)")
        }
    }

    // MARK: - The look

    func testDrivePreviewIsStructured() throws {
        for q in [QualityLevel.lite, .high] {
            let shot = try Self.renderDrive(at: 3, values: ["rain": .number(0.4)], quality: q, notes: Self.playing)
            let image = try XCTUnwrap(shot.image)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q): a lit city at night")
            XCTAssertLessThan(s.meanLuminance, 0.5, "\(q): still night")
            XCTAssertGreaterThan(s.variance, 0.002, "\(q): structured, not a flat wash")
            // The cabin's dark frame round the glass and the city's light through it.
            let top = PreviewRenderer.brightestPatch(image, radius: 3)
            XCTAssertGreaterThan(top, 0.3, "\(q): bright neon and lamps")
        }
    }

    func testDriveFramesAnyAspect() throws {
        let sizes: [(Int, Int)] = [(640, 360), (360, 640), (500, 500), (1280, 540)]
        for (w, h) in sizes {
            let shot = try Self.renderDrive(at: 1, notes: Self.playing, width: w, height: h)
            let image = try XCTUnwrap(shot.image)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.01, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
            let a = shot.renderer.uniforms[NeonNightDriveRenderer.rowA].x
            XCTAssertEqual(a, Float(w) / Float(h), accuracy: 1e-4, "\(w)×\(h)")
        }
    }

    // MARK: - Flashes (Review focus 1, 5)

    func testTheDropsWaveStaysInsideTheFlashLimiter() throws {
        // A hammered minute: a moment every quarter second (every fourth a drop), tension high, a strike of far lightning
        // every two seconds. The view never flashes more than three times a second.
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 15, to: 3600, by: 15) { moments[i] = Self.chord(1, drop: i % 60 == 0) }
        var surprises: [Int: Int] = [:]
        for i in stride(from: 30, to: 3600, by: 120) { surprises[i] = 1 }
        var worst = 0, total = 0
        var lit = false
        _ = try Self.renderDrive(at: 60, energy: 1, tension: 0.9, moments: moments, surprises: surprises, capture: false,
                                 edit: { i, f in
            if i % 120 == 31 { f.lightning = DriveLightning(age: 0, seed: UInt64(i), across: 0.2, strength: 1) }
        }, each: { _, r, _ in
            worst = max(worst, r.flashesInLastSecond)
            total = r.flashTotal
            if r.waveLight > 0.3 { lit = true }
        })
        XCTAssertLessThanOrEqual(worst, FlashLimiter.maxFlashesPerSecond)
        XCTAssertLessThanOrEqual(total, 60 * FlashLimiter.maxFlashesPerSecond)
        XCTAssertTrue(lit, "the signs still fire")
    }

    func testGentleHasNoStrobeAndNoNeonFlash() throws {
        // In the tunnel, hammered with drops and lightning: under gentle visuals nothing flashes, the tunnel's lights don't
        // strobe the view, and the wave and the lightning are glows.
        var moments: [Int: BigMoment] = [:]
        for i in stride(from: 600, to: 1500, by: 30) { moments[i] = Self.chord(1, drop: i % 90 == 0) }
        var flashes = 0, strobe: Float = 0, sawTunnel = false, wave: Float = 0
        _ = try Self.renderDrive(at: 25, gentle: true, energy: 1, tension: 0.9, moments: moments, capture: false,
                                 edit: { i, f in
            if i % 60 == 7 { f.lightning = DriveLightning(age: 0.05, seed: UInt64(i), across: 0, strength: 1) }
        }, each: { _, r, _ in
            flashes = max(flashes, r.flashTotal)
            strobe = max(strobe, r.strobeLight)
            if r.inTunnel { sawTunnel = true }
            wave = max(wave, r.waveLight)
        })
        XCTAssertTrue(sawTunnel)
        XCTAssertEqual(flashes, 0, "no flash under gentle visuals")
        XCTAssertEqual(strobe, 0, "no strobe")
        XCTAssertLessThanOrEqual(wave, 0.41, "a glow, not a flash")
        // Without gentle the same tunnel strobes (gently, through the limiter).
        var strobed: Float = 0
        _ = try Self.renderDrive(at: 14, energy: 1, tension: 0.9, capture: false, each: { _, r, _ in
            strobed = max(strobed, r.strobeLight)
        })
        XCTAssertGreaterThan(strobed, 0.2)
    }

    func testTheTunnelStrobesAtMostThreeTimesASecond() throws {
        var fastest: Float = 0, inside = 0
        _ = try Self.renderDrive(at: 16, energy: 1, tension: 1, moments: [600: Self.chord(1)],
                                 pulse: InstrumentPulse(bpm: 170, gate: 0.5), capture: false, each: { _, r, _ in
            if r.inTunnel { inside += 1 }
            fastest = max(fastest, r.strobeHz)
        })
        XCTAssertGreaterThan(inside, 60, "it drove into the tunnel")
        XCTAssertGreaterThan(fastest, 1)
        XCTAssertLessThanOrEqual(fastest, 3.0001)
        // Even at the drop's surge on top of full speed.
        let surge = NeonNightDriveModel.metresPerSecond(1.25) / DriveRoad.tunnelLightSpacing
        XCTAssertLessThanOrEqual(surge, 3.0001)
    }

    // MARK: - Settings

    func testDriveHonoursReduceMotion() throws {
        var swayed = false
        _ = try Self.renderDrive(at: 6, energy: 1, capture: false, each: { _, r, _ in
            if r.sky.roll != 0 { swayed = true }
        })
        XCTAssertTrue(swayed, "the road's curves sway the view")
        var still = true, fastest: Float = 0, wave: Float = 0
        _ = try Self.renderDrive(at: 6, reduceMotion: true, energy: 1, moments: [120: Self.chord(1)], capture: false,
                                 each: { _, r, f in
            if r.sky.roll != 0 || abs(r.sky.viewAzimuth! - NeonNightDriveRenderer.heading) > 1e-9 { still = false }
            fastest = max(fastest, f.speed)
            wave = max(wave, f.wave?.strength ?? 0)
        })
        XCTAssertTrue(still, "no sway under Reduce Motion")
        XCTAssertLessThan(fastest, 0.25 + 0.55 * 0.5 + 0.13, "Energy's look capped at 0.5 (and a half-strength surge)")
        XCTAssertLessThanOrEqual(wave, 0.5, "moments at half strength")
    }

    // MARK: - The windscreen

    func testTheWipersFollowTheRainOnTheGlass() throws {
        // The glass's rows carry the Core wipers' state, so the blades and the cleared arcs are the model's.
        let heavy = try Self.renderDrive(at: 8, values: ["rain": .number(0.95)], capture: false)
        let rows = heavy.renderer.screen.uniforms
        let w = heavy.frame.wipers
        XCTAssertEqual(rows[WindscreenLayer.rowWiper].x, w.phase, accuracy: 1e-6)
        XCTAssertEqual(rows[WindscreenLayer.rowWiper].y, w.sweepSeconds, accuracy: 1e-6)
        XCTAssertEqual(rows[WindscreenLayer.rowSweep].z, w.angle, accuracy: 1e-6)
        XCTAssertGreaterThan(heavy.frame.wipers.sweeps, 3)
        let light = try Self.renderDrive(at: 8, values: ["rain": .number(0.1)], capture: false)
        XCTAssertLessThan(light.frame.wipers.sweeps, heavy.frame.wipers.sweeps)
        XCTAssertGreaterThan(heavy.renderer.screen.dropDensity, light.renderer.screen.dropDensity)
        // The windscreen's outline: the glass over the dashboard and under the roof, the blades resting along the bottom.
        let spec = WindowSpec.windscreen(aspect: 16.0 / 9)
        let shape = try XCTUnwrap(spec.windscreen)
        XCTAssertEqual(spec.shape, .windscreen)
        XCTAssertTrue(shape.onGlass(SIMD2(0, 0)))
        XCTAssertFalse(shape.onGlass(SIMD2(0, -0.9)), "the dashboard")
        XCTAssertFalse(shape.onGlass(SIMD2(0, 0.97)), "the roof")
        XCTAssertFalse(shape.onGlass(SIMD2(-0.95, 0.8)), "the near pillar")
        let rest = shape.blade(0, at: 0, aspect: 16.0 / 9)
        let up = shape.blade(0, at: 1, aspect: 16.0 / 9)
        XCTAssertLessThan(rest.outer.y, -0.5, "resting low")
        XCTAssertGreaterThan(up.outer.y, 0.0, "sweeping up")
        // Under a bridge the glass is sheltered: no drop lands.
        var sheltered = false
        _ = try Self.renderDrive(at: 12, surprises: [60: 4], capture: false, each: { _, r, _ in
            if r.screen.sheltered { sheltered = true }
        })
        XCTAssertTrue(sheltered)
    }

    // MARK: - Light Trails

    func testLightTrailsArePackedByLane() throws {
        // A low note and a high one every tenth of a second.
        let sparse: (Int) -> [UInt8] = { i in i % 6 == 0 ? [UInt8(30 + (i / 6) % 15), UInt8(66 + (i / 6) % 20)] : [] }
        let shot = try Self.renderDrive(at: 1.5, notes: sparse, capture: false)
        let layer = shot.renderer.trails
        let rows = layer.uniforms
        var total = 0
        for lane in 0..<4 {
            let first = Int(rows[lane].x), count = Int(rows[lane].y)
            XCTAssertEqual(first, total, "lane \(lane) follows the one before")
            total += count
            XCTAssertEqual(rows[lane].z, DriveRoad.laneCentre(lane), accuracy: 1e-5)
        }
        XCTAssertEqual(total, layer.drawn)
        XCTAssertEqual(total, shot.frame.trails.count)
        XCTAssertGreaterThan(total, 5)
        // The arp's (low) notes run in the left lanes, the brass's in the right.
        let left = Int(rows[0].y + rows[1].y), right = Int(rows[2].y + rows[3].y)
        XCTAssertGreaterThan(left, 0)
        XCTAssertGreaterThan(right, 0)
        // Smooth sends at most 64, the brightest.
        let pairs: (Int) -> [UInt8] = { i in [UInt8(21 + i % 88), UInt8(21 + (i * 7) % 88)] }
        let lite = try Self.renderDrive(at: 2, quality: .lite, notes: pairs, capture: false)
        XCTAssertLessThanOrEqual(lite.renderer.trails.drawn, LightTrailsLayer.budget(.lite))
        XCTAssertGreaterThan(lite.frame.trails.count, LightTrailsLayer.budget(.lite))
        // Galaxy Warp takes the notes instead.
        let warp = try Self.renderDrive(at: 1, values: ["visual": .choice("Galaxy Warp")], notes: Self.playing, capture: false)
        XCTAssertEqual(warp.renderer.trails.drawn, 0)
    }

    // MARK: - Budgets (spec §12)

    func testNothingIsAllocatedAFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        var captured = 0
        let values: [String: ParamValue] = ["rain": .number(0.9), "traffic": .number(1)]
        let moments: [Int: BigMoment] = [30: Self.chord(1)]
        let surprises: [Int: Int] = [40: 0, 50: 3]
        let pulse = InstrumentPulse(bpm: 150, gate: 0.5)
        let each: (Int, NeonNightDriveRenderer, DriveFrame) -> Void = { _, r, _ in
            if preview.capture(r) != nil { captured += 1 }
        }
        let shot = try Self.renderDrive(at: 2, values: values, energy: 1, tension: 0.8, moments: moments, surprises: surprises,
                                        pulse: pulse, notes: Self.crowd, capture: false, each: each)
        let r = shot.renderer
        XCTAssertEqual(captured, 120)
        XCTAssertEqual(r.trails.bufferAllocations, 3, "the streaks' ring of buffers, made once")
        XCTAssertEqual(r.reflectCopy.allocations, 1, "the reflection's copy, made once at its size")
        XCTAssertEqual(r.screen.copy.allocations, 1, "the windscreen's copy, made once at its size")
        XCTAssertLessThanOrEqual(r.weather.bufferAllocations, 4)
        XCTAssertEqual(r.uniforms.count, NeonNightDriveRenderer.uniformCount)
        XCTAssertLessThanOrEqual(shot.frame.trails.count, LightTrails.capacity)
    }
}

/// The GPU time of a Neon Night Drive frame at 1280×720 (the passes and the finishing), printed for the look job's report
/// (spec §12: ≤ 7 ms at 1 MP on the target Mac; CI's virtual GPU is far slower, so this only reports).
@MainActor
final class DriveFrameTimeTests: XCTestCase {
    func testDriveFrameTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device")
        }
        let width = 1280, height = 720
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: width, height: height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        for q in [QualityLevel.lite, .high] {
            let shot = try NeonNightDriveRendererTests.renderDrive(at: 2, quality: q, notes: NeonNightDriveRendererTests.playing,
                                                                   width: width, height: height, capture: false)
            var scene: [Double] = [], whole: [Double] = []
            for i in 0..<24 {
                guard let cb = queue.makeCommandBuffer() else { continue }
                shot.renderer.render(stack: stack, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                let sceneMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                guard let cb2 = queue.makeCommandBuffer() else { continue }
                shot.renderer.render(stack: stack, commandBuffer: cb2)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                stack.post(into: pass, commandBuffer: cb2, settings: shot.renderer.post)
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
            let label = q == .lite ? "Smooth" : "High"
            print(String(format: "FRAME TIME drive %@ 1280x720: passes %.2f ms, passes+finish %.2f ms (median of %d)",
                         label, sceneMedian, wholeMedian, scene.count))
            XCTAssertGreaterThan(wholeMedian, 0)
        }
    }
}

extension WorldPreviewTests {
    func testWriteDrivePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        typealias T = NeonNightDriveRendererTests
        func write(_ shot: T.DriveShot, _ name: String) throws {
            let image = try XCTUnwrap(shot.image)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        let w = 1280, h = 720
        // Deep night, Energy 0, a light rain: a slow melody, the wipers on their intermittent beat.
        let sparse: (Int) -> [UInt8] = { i in i % 40 == 0 ? [UInt8(60 + (i / 40 * 7) % 17)] : (i % 80 == 20 ? [36] : []) }
        try write(try T.renderDrive(at: 6, values: ["rain": .number(0.25)], energy: 0, notes: sparse, width: w, height: h),
                  "drive-night")
        // Energy 1, a C major chord held (the neon warm), Chrome Bass's arp at 140 racing the studs, the melody over it.
        let melody: (Int) -> [UInt8] = { i in i % 12 == 0 ? [UInt8(72 + (i / 12 * 5) % 14)] : [] }
        let held: Set<UInt8> = [36, 60, 64, 67]
        try write(try T.renderDrive(at: 6, energy: 1, tension: 0.3, pulse: InstrumentPulse(bpm: 140, gate: 0.55),
                                    notes: melody, holds: held, width: w, height: h), "drive-energy")
        // Mid-Drop: tension in the tunnel, the drop, and just out onto the bridge with the wave running along the skyline.
        var outAt: Int?
        let drop: [Int: BigMoment] = [660: T.chord(1, drop: true)]
        let out: (Int, DriveFrame) -> Bool = { i, f in
            let clear: Bool = f.tunnel.map({ $0.end <= 0 }) ?? true
            if i > 660, outAt == nil, clear { outAt = i }
            if let o = outAt { return i >= o + 24 }
            return false
        }
        try write(try T.renderDrive(at: 30, energy: 0.9, tension: 0.9, moments: drop, notes: T.playing, width: w, height: h,
                                    stop: out), "drive-drop")
        // Tension high, deep in the tunnel: its lights strobing gently overhead, the rain gone from the glass.
        try write(try T.renderDrive(at: 13, energy: 0.8, tension: 0.95, notes: T.playing, width: w, height: h), "drive-tunnel")
        // Smooth.
        try write(try T.renderDrive(at: 6, values: ["rain": .number(0.45)], quality: .lite, energy: 0.5, notes: T.playing,
                                    width: w, height: h), "drive-smooth")
        // Light Trails: the arp's notes racing down the left lanes, the brass's chords streaking the right, a moment's
        // interchange bloom fanning out ahead.
        let moment: [Int: BigMoment] = [270: T.chord(0.9)]
        let racing: (Int) -> [UInt8] = { i in
            if i % 45 == 0 { return [55, 60, 64, 67, 72] }
            if i % 8 == 0 { return [UInt8(28 + (i / 8 * 3) % 18)] }
            return []
        }
        try write(try T.renderDrive(at: 5.4, energy: 0.8, moments: moment, pulse: InstrumentPulse(bpm: 128, gate: 0.55),
                                    notes: racing, width: w, height: h), "light-trails")
        // A surprise: the train crossing its bridge as you come to it.
        try write(try T.renderDrive(at: 9, energy: 0.5, surprises: [60: 0], notes: T.playing, width: w, height: h),
                  "drive-train")
    }
}
