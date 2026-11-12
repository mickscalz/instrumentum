import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

/// Fire & Neon Task 8 in the shared sky (spec §6, §12): the far storm and its sprites staged where the world looks, the
/// SkyU rows, and what the dome draws.
@MainActor
final class SkyExtrasRendererTests: XCTestCase {
    /// A moonless deep night over Melbourne, clear, with the real stars (the shared sky's state, hand-set like the sky
    /// previews' night).
    nonisolated static func night(sunAltitude: Double = -40) -> SkyState {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 23.5; s.frozenPhase = 0.05; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear; s.spritesMode = .off; s.satellitesMode = .off
        let sky = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
        var st = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
        st.sun = SkyDirection(azimuth: 260, altitude: sunAltitude)
        st.moon = SkyDirection(azimuth: 0, altitude: -30); st.moonLit = 0
        let colours = SkyPalette.colours(sunAltitude: sunAltitude, cloud: 0, mist: 0.05, moonlight: 0)
        st.zenith = colours.zenith; st.horizon = colours.horizon
        st.starVisibility = sunAltitude < -15 ? 1 : 0.55; st.cloudCover = 0; st.mist = 0.05
        return st
    }

    /// A far storm `bearing`° (the staging stands it `bearing mod 40 − 20`° right of the view) and a lit sprite cluster
    /// over it.
    nonisolated static func stormy(_ s: SkyState, bearing: Float = 32, sprites: Bool = true, flicker: Float = 0.7) -> SkyState {
        var s = s
        s.farStormNow = FarStormNow(bearing: bearing, distanceKm: 260, top: Float(FarStorms.anvilTop(km: 260)), width: 22,
                                    amount: 1, episode: 3, flicker: flicker, flickerAcross: -3, flickerUp: 0.6)
        s.stormBearing = bearing
        s.stormEpisode = 3
        s.farStorm = 1
        if sprites {
            s.sprites = [
                SpriteSlot(azimuth: bearing - 2.5, base: 5.2, height: 3.4, columns: 3, spread: 1.1, shape: 0.75, streamers: 0.5,
                           seed: 0.31, born: 0, lit: 0.12, peak: 0.04, level: 1, brightness: 0.04),
                SpriteSlot(azimuth: bearing + 3.5, base: 6.0, height: 2.6, columns: 1, spread: 0.8, shape: 0.1, streamers: 0,
                           seed: 0.77, born: 0, lit: 0.1, peak: 0.028, level: 0.9, brightness: 0.025),
            ]
        }
        return s
    }

    /// The storm is staged at the view's azimuth plus an offset (±20°) seeded by its own bearing, from the moment it
    /// appears, and stays put as the view drifts; a new storm is staged afresh; its sprites keep their places about it.
    func testStagingStandsTheStormWhereTheWorldLooks() {
        var r = SkyLayer.stage(episode: 1, bearing: 32, viewAzimuth: 100, anchor: nil)
        XCTAssertEqual(r.anchor.azimuth, 100 + (32 - 40 * (32.0 / 40).rounded(.down)) - 20, accuracy: 1e-9)
        XCTAssertEqual(r.anchor.azimuth, 112, accuracy: 1e-9)
        XCTAssertEqual((32 + r.shift).truncatingRemainder(dividingBy: 360), 112, accuracy: 1e-9)
        let first = r.anchor
        r = SkyLayer.stage(episode: 1, bearing: 32, viewAzimuth: 160, anchor: first)
        XCTAssertEqual(r.anchor.azimuth, first.azimuth, "the camera's drift never moves it")
        r = SkyLayer.stage(episode: 2, bearing: 250, viewAzimuth: 160, anchor: first)
        XCTAssertEqual(r.anchor.azimuth, 160 + 10 - 20, accuracy: 1e-9, "a new storm, staged afresh")
        for b in stride(from: Float(0), to: 360, by: 7) {
            let x = SkyLayer.stage(episode: Int(b), bearing: b, viewAzimuth: 30, anchor: nil)
            XCTAssertLessThanOrEqual(abs(x.anchor.azimuth - 30), 20 + 1e-9)
            XCTAssertTrue((0..<360).contains(x.shift))
        }
        // Through the layer: the storm row's bearing and the sprites' azimuths shift together.
        guard let device = MTLCreateSystemDefaultDevice(), let layer = SkyLayer(device: device) else { return }
        layer.viewAzimuth = 0
        let s = Self.stormy(Self.night())
        layer.update(s, quality: .high, size: CGSize(width: 640, height: 360), time: 0)
        let u = layer.uniforms
        let stormAz = atan2(Double(u[SkyLayer.stormRow].x), Double(u[SkyLayer.stormRow].y)) * 180 / .pi
        XCTAssertEqual(stormAz, 12, accuracy: 1e-3, "32 mod 40 − 20 = 12° right of the view")
        XCTAssertEqual(Double(u[SkyLayer.spriteARow].x), 12 - 2.5, accuracy: 1e-3, "and its sprite 2.5° left of it")
        XCTAssertEqual(u[SkyLayer.spriteARow].w, 0.04, accuracy: 1e-6)
        XCTAssertEqual(u[SkyLayer.spriteBRow].x, 3 + 0.45, accuracy: 1e-5, "three columns, half the streamers")
        XCTAssertEqual(u[SkyLayer.spriteARow + 2].w, 0, "the third slot empty")
        XCTAssertEqual(SkyLayer.uniformCount, SkyLayer.ashRow + 1)
        XCTAssertLessThanOrEqual(SkyLayer.uniformCount * 16, 4096, "one setFragmentBytes call")
    }

    /// The satellite rows: the lead's direction and its light; its motion × a train's spacing and its count; the shadow
    /// edge, which side is lit, the star footprint of its magnitude, and its reddening; unlit or broken ones dropped.
    func testSatelliteRows() {
        let dir = simd_normalize(SIMD3<Float>(0.2, 0.6, 0.77))
        let tan = simd_normalize(simd_cross(dir, SIMD3<Float>(0, 0, 1)))
        let one = SatelliteSlot(kind: .satellite, id: 3, direction: dir, tangent: tan, angularSpeed: 0.01, magnitude: 1,
                                light: SatelliteSlot.light(magnitude: 1), redden: 0.4)
        let rows = try? XCTUnwrap(SkyLayer.satelliteRows(one))
        XCTAssertEqual(rows?.a.w ?? 0, SatelliteSlot.light(magnitude: 1), accuracy: 1e-6)
        XCTAssertEqual(rows?.b.w, 1)
        XCTAssertEqual(simd_length(SIMD3(rows?.b.x ?? 1, rows?.b.y ?? 1, rows?.b.z ?? 1)), 0, accuracy: 1e-6, "one point")
        XCTAssertEqual(rows?.c.z ?? 0, Satellites.footprint(magnitude: 1), accuracy: 1e-7)
        XCTAssertEqual(rows?.c.w ?? 0, 0.4, accuracy: 1e-6)
        let train = SatelliteSlot(kind: .train, id: 4, direction: dir, tangent: tan, angularSpeed: 0.01, count: 12, spacing: 0.02,
                                  magnitude: 2.5, light: SatelliteSlot.light(magnitude: 2.5), shadowMember: 4.5, litBehind: true)
        let t = SkyLayer.satelliteRows(train)
        XCTAssertEqual(t?.b.w, 12)
        XCTAssertEqual(simd_length(SIMD3(t?.b.x ?? 0, t?.b.y ?? 0, t?.b.z ?? 0)), 0.02, accuracy: 1e-6)
        XCTAssertEqual(t?.c.x, 4.5)
        XCTAssertEqual(t?.c.y, 1)
        var dark = one; dark.light = 0
        XCTAssertNil(SkyLayer.satelliteRows(dark))
        var broken = one; broken.direction = SIMD3(1, 1, 1)
        XCTAssertNil(SkyLayer.satelliteRows(broken))
        XCTAssertEqual(Satellites.footprint(magnitude: 4), 2 * Float.pi / 2048, accuracy: 1e-9, "a faint one: a texel")
        XCTAssertGreaterThan(Satellites.footprint(magnitude: -4), Satellites.footprint(magnitude: 1))
    }

    /// The dome draws them: the sprites over the far storm redden their patch of the sky (red over blue, faintly); the far
    /// storm darkens the horizon under them and its flash lights it; a satellite is a bright point where it stands; with
    /// nothing in their rows the night is as it was.
    func testTheDomeDrawsSpritesStormAndSatellites() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        func render(_ s: SkyState) throws -> CGImage {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = 0
            r.sky.verticalFOV = 20
            r.sky.horizonY = -0.7
            for i in 0..<4 { r.update(s, quality: .high, size: CGSize(width: 320, height: 180), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            return try XCTUnwrap(preview.capture(r))
        }
        let plain = try render(Self.night())
        let stormOnly = try render(Self.stormy(Self.night(), sprites: false, flicker: 0))
        let flash = try render(Self.stormy(Self.night(), sprites: false, flicker: 1))
        let sprites = try render(Self.stormy(Self.night(), flicker: 0))
        XCTAssertGreaterThan(PreviewRenderer.difference(plain, stormOnly), 0, "the storm stands on the horizon")
        XCTAssertGreaterThan(PreviewRenderer.stats(flash).meanLuminance, PreviewRenderer.stats(stormOnly).meanLuminance, "its flash")
        XCTAssertGreaterThan(PreviewRenderer.difference(stormOnly, sprites), 0.0002, "the sprites show")
        XCTAssertLessThan(PreviewRenderer.stats(sprites).meanLuminance - PreviewRenderer.stats(stormOnly).meanLuminance, 0.05,
                          "faintly")
        var withSat = Self.night()
        let ahead = SIMD3<Float>(0, cos(0.17), sin(0.17))   // 10° up, straight ahead
        withSat.satellites = [SatelliteSlot(kind: .station, id: 1, direction: ahead, tangent: SIMD3(1, 0, 0), angularSpeed: 0.01,
                                            magnitude: -2.5, light: SatelliteSlot.light(magnitude: -2.5))]
        let sat = try render(withSat)
        XCTAssertGreaterThan(PreviewRenderer.brightestPatch(sat, radius: 1), PreviewRenderer.brightestPatch(plain, radius: 1) + 0.05)
    }
}

/// The previews (spec §14): a sprite cluster mid-flash over a far storm at deep night, satellites at dusk with one fading
/// into the shadow and a train running into it, and a flare rising and at its peak.
extension WorldPreviewTests {
    func testWriteSkyExtraPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let size = CGSize(width: 1280, height: 720)
        typealias T = SkyExtrasRendererTests
        func sky(_ name: String, _ s: SkyState, view: Double = 0, fov: Double = 60, horizon: Float = -0.33,
                 surface: WeatherSurface = .none) throws {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            XCTAssertTrue(r.sky.awaitStars())
            r.sky.viewAzimuth = view; r.sky.verticalFOV = fov; r.sky.horizonY = horizon
            for i in 0..<20 { r.update(s, quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: surface) }
            try PreviewRenderer.writePNG(try XCTUnwrap(preview.capture(r)), to: url.appendingPathComponent("\(name).png"))
        }
        // Red sprites: a cluster mid-flash over the far storm, close up (a 16° lens) and as a world sees it (the lake).
        // (A bearing of 20° stages the storm dead ahead: 20 mod 40 − 20 = 0.)
        try sky("sky-sprites-closeup", T.stormy(T.night(), bearing: 20), fov: 16, horizon: -0.8)
        try sky("sky-far-storm-flicker", T.stormy(T.night(), bearing: 20, sprites: false, flicker: 0.9), fov: 16, horizon: -0.8)
        try sky("sky-far-storm-dark", T.stormy(T.night(), bearing: 20, sprites: false, flicker: 0), fov: 16, horizon: -0.8)
        try sky("sky-sprites-wide", T.stormy(T.night()))
        var lakeSky = SkySettings(); lakeSky.timeMode = .frozen; lakeSky.frozenHour = 23.5; lakeSky.frozenPhase = 0.05
        lakeSky.cityID = "melbourne"; lakeSky.weatherMode = .pick; lakeSky.weather = .clear
        let lake = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: .high, sky: lakeSky, mood: .serene,
                                                skyEdit: { s in s = T.stormy(s) }).first)
        try PreviewRenderer.writePNG(lake, to: url.appendingPathComponent("lake-sprites.png"))
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let beach = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [5], state: follow, quality: .high,
                                                 sky: lakeSky, skyEdit: { s in s = T.stormy(s) }).first)
        try PreviewRenderer.writePNG(beach, to: url.appendingPathComponent("beach-sprites.png"))

        // Satellites at dusk (the sun 11° down): a station high, one fading into the shadow (reddened), a train running
        // into it (its first five members gone), a faint one, among the first stars.
        var dusk = T.night(sunAltitude: -11)
        func at(_ az: Double, _ alt: Double) -> SIMD3<Float> { SkyLayer.enu(SkyDirection(azimuth: az, altitude: alt)) }
        func across(_ d: SIMD3<Float>, _ heading: Double) -> SIMD3<Float> {
            let flat = SIMD3<Float>(Float(sin(heading * .pi / 180)), Float(cos(heading * .pi / 180)), 0)
            return simd_normalize(flat - simd_dot(flat, d) * d)
        }
        let station = at(-8, 34), fading = at(8, 19), trainLead = at(-24, 16), faint = at(10, 40)
        dusk.satellites = [
            SatelliteSlot(kind: .station, id: 1, direction: station, tangent: across(station, 60), angularSpeed: 0.012,
                          magnitude: -2.8, light: SatelliteSlot.light(magnitude: -2.8)),
            SatelliteSlot(kind: .satellite, id: 2, direction: fading, tangent: across(fading, 100), angularSpeed: 0.01,
                          magnitude: 1.2, light: SatelliteSlot.light(magnitude: 1.2) * 0.35, sunlit: 0.35, redden: 0.75),
            SatelliteSlot(kind: .train, id: 3, direction: trainLead, tangent: across(trainLead, 75), angularSpeed: 0.008,
                          count: 16, spacing: 0.012, magnitude: 2.4, light: SatelliteSlot.light(magnitude: 2.4),
                          shadowMember: 4.5, litBehind: true),
            SatelliteSlot(kind: .satellite, id: 4, direction: faint, tangent: across(faint, 200), angularSpeed: 0.009,
                          magnitude: 4.2, light: SatelliteSlot.light(magnitude: 4.2)),
        ]
        try sky("sky-satellites-dusk", dusk)
        try sky("sky-satellites-dusk-closeup", dusk, view: -8, fov: 30, horizon: -0.9)
        // A flare: 2 s before its peak, and at it (Venus's brightness), among the stars of a dark sky.
        var flare = T.night(sunAltitude: -14)
        let glint = at(4, 30)
        func flaring(_ m: Float, _ f: Float) -> [SatelliteSlot] {
            [SatelliteSlot(kind: .satellite, id: 9, direction: glint, tangent: across(glint, 90), angularSpeed: 0.01,
                           magnitude: m, light: SatelliteSlot.light(magnitude: m), flare: f)]
        }
        flare.satellites = flaring(0.2, 0.25)
        try sky("sky-flare-rising", flare)
        flare.satellites = flaring(Satellites.venus, 1)
        try sky("sky-flare-peak", flare)
        // In a world: the lake at dusk with the station crossing over it.
        var duskLake = lakeSky; duskLake.frozenHour = 20.0
        let crossing = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: .high, sky: duskLake, mood: .serene,
                                                    skyEdit: { s in
            let ahead = MoonlitLakeRenderer.targetAzimuth(s)
            let d = SkyLayer.enu(SkyDirection(azimuth: ahead + 6, altitude: 26))
            s.satellites = [SatelliteSlot(kind: .station, id: 1, direction: d, tangent: across(d, 40), angularSpeed: 0.012,
                                          magnitude: -2.6, light: SatelliteSlot.light(magnitude: -2.6))]
        }).first)
        try PreviewRenderer.writePNG(crossing, to: url.appendingPathComponent("lake-station.png"))
    }
}

/// The shared sky's cost (spec §12): the dome at 1280 × 720 (0.92 MP) plain, and with a far storm, three lit sprite
/// clusters and four satellites (a train among them), printed as TIMING lines.
@MainActor
final class SkyExtrasFrameTimeTests: XCTestCase {
    static func median(_ renderer: ThemeRenderer, stack: RenderStack, queue: MTLCommandQueue) -> Double {
        var times: [Double] = []
        for i in 0..<28 {
            guard let cb = queue.makeCommandBuffer() else { continue }
            renderer.render(stack: stack, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 4 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        times.sort()
        return times.isEmpty ? 0 : times[times.count / 2]
    }

    func testSkyExtrasFrameTime() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("No Metal device") }
        let stack = try XCTUnwrap(RenderStack(device: device, pixelFormat: .bgra8Unorm))
        stack.resize(width: 1280, height: 720)
        let size = CGSize(width: 1280, height: 720)
        typealias T = SkyExtrasRendererTests
        var busy = T.stormy(T.night())
        busy.sprites.append(SpriteSlot(azimuth: 20, base: 5, height: 3, columns: 3, spread: 1, shape: 0.5, streamers: 0.6,
                                       seed: 0.5, born: 0, lit: 0.1, peak: 0.04, level: 1, brightness: 0.04))
        let d = simd_normalize(SIMD3<Float>(0.1, 0.8, 0.5))
        let tan = simd_normalize(simd_cross(d, SIMD3<Float>(0, 0, 1)))
        busy.satellites = (0..<4).map { k in
            let dk = simd_normalize(d + SIMD3<Float>(Float(k) * 0.08, 0, 0))
            return SatelliteSlot(kind: k == 0 ? .train : .satellite, id: k, direction: dk, tangent: tan, angularSpeed: 0.01,
                                 count: k == 0 ? 20 : 1, spacing: 0.01, magnitude: 1, light: 2, shadowMember: k == 0 ? 5 : -1)
        }
        typealias R = FireNeonWeatherRendererTests
        var ash = T.night(); ash.ash = 1
        let cases: [(String, SkyState)] = [
            ("plain-night", T.night()), ("storm-sprites-satellites", busy),
            ("plain-golden", R.golden()), ("supercell-approach", R.supercell(R.golden(), phase: 0.2, glow: 0.5)),
            ("supercell-core", R.supercell(R.golden(), phase: 0.45, glow: 0.8)),
            ("supercell-clearing", R.supercell(R.golden(), phase: WorldWeather.supercellHeld)),
            ("ashfall-night", ash),
        ]
        for (label, s) in cases {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = 0
            for i in 0..<5 { r.update(s, quality: .high, size: size, dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            let ms = Self.median(r, stack: stack, queue: queue)
            print(String(format: "TIMING sky-extras %@ 1280x720: dome %.3f ms (median of 24)", label, ms))
            XCTAssertGreaterThan(ms, 0)
        }
    }
}

/// Fire & Neon Task 9 in the shared layers (spec §7, §12; Review focus 5): ash through the snow's path, embers only at an
/// ember source, the supercell's hail, its lightning flashing through the limiter and only glowing under gentle visuals,
/// and the storm drawn in the sky.
@MainActor
final class FireNeonWeatherRendererTests: XCTestCase {
    /// A sky with the supercell staged at `phase` (its own weather values standing in), as the Living Sky has it.
    nonisolated static func supercell(_ s: SkyState, phase: Double, bearing: Float = 28, glow: Float = 0) -> SkyState {
        var s = s
        var c = WorldWeather.supercell(phase: phase)
        c.amount = 1; c.bearing = bearing; c.episode = 1; c.turn = 0.7; c.glow = glow; c.spot = 0.42
        s.supercellWeather = c
        s.supercell = 1; s.supercellPhase = min(Float(phase), 0.9999)
        s.cloudCover = c.cloud; s.rain = c.rain; s.mist = c.mist; s.wind = c.wind; s.hail = c.hail
        s.weather = .supercell; s.nextWeather = .supercell; s.weatherBlend = 0
        let colours = SkyPalette.colours(sunAltitude: s.sun.altitude, cloud: c.cloud, mist: c.mist, moonlight: 0)
        s.zenith = colours.zenith; s.horizon = colours.horizon
        s.starVisibility = max(0, s.starVisibility * (1 - 0.9 * c.cloud))
        return s
    }

    /// A day sky with the sun 5° up (golden hour).
    nonisolated static func golden() -> SkyState {
        var s = SkyExtrasRendererTests.night(sunAltitude: 5)
        s.sun = SkyDirection(azimuth: 280, altitude: 5)
        let colours = SkyPalette.colours(sunAltitude: 5, cloud: 0, mist: 0.1, moonlight: 0)
        s.zenith = colours.zenith; s.horizon = colours.horizon; s.starVisibility = 0
        return s
    }

    /// Ash falls through the snow's path as kind 9 (grey flakes), 0.6× the snow's speed; embers only where the sky says
    /// so (an ember source); the supercell's hail as its own pellets; none of them without their weather.
    func testAshEmbersAndHailInTheWeatherLayer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let size = CGSize(width: 640, height: 360)
        var ash = SkyExtrasRendererTests.night(); ash.ash = 1
        let w = try XCTUnwrap(WeatherLayer(device: device))
        for _ in 0..<5 { w.update(ash, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.33)) }
        XCTAssertEqual(w.kind, 9)
        XCTAssertGreaterThan(w.particleCount, 500)
        XCTAssertEqual(w.emberCount, 0, "no embers without a source")
        XCTAssertEqual(w.hailCount, 0)
        var embers = ash; embers.embers = 1
        w.update(embers, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertGreaterThan(w.emberCount, 100)
        XCTAssertFalse(w.emberInstances.isEmpty)
        var hail = SkyExtrasRendererTests.night(); hail.hail = 1; hail.rain = 0.9
        for _ in 0..<30 { w.update(hail, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.33)) }
        XCTAssertGreaterThan(w.hailCount, 200)
        XCTAssertEqual(w.kind, 0, "it rains with the hail")
        XCTAssertEqual(w.emberCount, 0)
        // Ash falls at 0.6× the snow's pace: the same flakes' mean fall over a second.
        func meanFall(_ s: SkyState) throws -> Float {
            let layer = try XCTUnwrap(WeatherLayer(device: device))
            layer.update(s, quality: .lite, size: size, dt: 0, surface: .none)
            let before = layer.particleYs
            layer.update(s, quality: .lite, size: size, dt: 0.05, surface: .none)
            let after = layer.particleYs
            let falls = zip(before, after).map { $0 - $1 }.filter { $0 > 0 && $0 < 0.5 }
            return falls.reduce(0, +) / Float(max(1, falls.count))
        }
        var snow = SkyExtrasRendererTests.night(); snow.snow = WeatherLayer.ashDensity
        var still = ash; still.wind = 0; still.gust = 0; snow.wind = 0; snow.gust = 0
        XCTAssertEqual(try meanFall(still) / meanFall(snow), WeatherLayer.ashSpeed, accuracy: 0.05)
    }

    /// The supercell's lightning through the weather layer: a flash lifts the scene a little (its cloud carries the
    /// flash, never a pale wash over everything), the limiter keeping it to three large jumps a second at most; under
    /// gentle visuals not one large jump, only a glow. Its light in the cloud goes through the sky layer's limiter: three
    /// jumps a second at most, and under gentle visuals a glow no brighter than `gentleCellGlow`.
    func testSupercellLightningFlashesAndOnlyGlowsUnderGentle() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick
        s.weather = .supercell; s.spritesMode = .off; s.satellitesMode = .off
        let sky = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
        sky.reset(settings: s)
        let plain = try XCTUnwrap(WeatherLayer(device: device)), gentle = try XCTUnwrap(WeatherLayer(device: device))
        gentle.gentle = true
        let plainSky = try XCTUnwrap(SkyLayer(device: device)), gentleSky = try XCTUnwrap(SkyLayer(device: device))
        gentleSky.gentle = true
        var plainBoost: [Float] = [], gentleBoost: [Float] = []
        var plainGlow: [Float] = [], gentleGlow: [Float] = [], asked: [Float] = []
        let dt = 1.0 / 30
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        for i in 1...(480 * 30) {
            let st = sky.step(now: start.addingTimeInterval(Double(i) * dt), dt: dt, meteors: .never)
            // Both layers run from the start (their limiters settled at the scene's exposure); the Core is recorded.
            plain.update(st, quality: .lite, size: CGSize(width: 320, height: 180), dt: dt, surface: .none)
            gentle.update(st, quality: .lite, size: CGSize(width: 320, height: 180), dt: dt, surface: .none)
            let clock = Float((Double(i) * dt).truncatingRemainder(dividingBy: 3600))
            plainSky.update(st, quality: .lite, size: CGSize(width: 320, height: 180), time: clock)
            gentleSky.update(st, quality: .lite, size: CGSize(width: 320, height: 180), time: clock)
            guard i > 150 * 30, i < 330 * 30 else { continue }   // the Core
            plainBoost.append(plain.exposureBoost); gentleBoost.append(gentle.exposureBoost)
            plainGlow.append(1 + plainSky.cellGlowOut); gentleGlow.append(1 + gentleSky.cellGlowOut)
            asked.append(st.supercellWeather?.glow ?? 0)
        }
        func jumps(_ b: [Float]) -> (count: Int, worstSecond: Int) {
            var times: [Int] = []
            for i in 3..<b.count where b[i] - (b[(i - 3)...i].min() ?? 1) > FlashLimiter.flashRise {
                if times.last.map({ i - $0 > 3 }) ?? true { times.append(i) }
            }
            var worst = 0
            for t in times { worst = max(worst, times.filter { $0 >= t && $0 < t + 30 }.count) }
            return (times.count, worst)
        }
        XCTAssertGreaterThan(plainBoost.max() ?? 1, 1 + 0.8 * WeatherLayer.cellLightning, "its lightning lifts the scene")
        XCTAssertLessThanOrEqual(plainBoost.max() ?? 1, 1 + WeatherLayer.cellLightning + 1e-4, "a little: the cloud flashes")
        XCTAssertGreaterThan(jumps(plainBoost).count, 5)
        XCTAssertLessThanOrEqual(jumps(plainBoost).worstSecond, FlashLimiter.maxFlashesPerSecond)
        XCTAssertEqual(jumps(gentleBoost).count, 0, "gentle: no flash")
        XCTAssertGreaterThan(gentleBoost.max() ?? 1, 1.02, "only a glow")
        XCTAssertLessThanOrEqual(gentleBoost.max() ?? 1, 1 + WeatherLayer.gentleLightning + 1e-4)
        // In the cloud: it flashes, within the limiter; under gentle visuals it only glows.
        XCTAssertGreaterThan(asked.max() ?? 0, 0.5)
        XCTAssertGreaterThan(plainGlow.max() ?? 1, 1.5, "the cloud lights up")
        XCTAssertGreaterThan(jumps(plainGlow).count, 3)
        XCTAssertLessThanOrEqual(jumps(plainGlow).worstSecond, FlashLimiter.maxFlashesPerSecond)
        XCTAssertEqual(jumps(gentleGlow).count, 0, "gentle: the cloud never flashes")
        XCTAssertGreaterThan(gentleGlow.max() ?? 1, 1.02, "it glows")
        XCTAssertLessThanOrEqual(gentleGlow.max() ?? 1, 1 + SkyLayer.gentleCellGlow + 1e-4)
    }

    /// The dome draws the storm: its Approach stands on the horizon where the world looks (darker there than the clear
    /// golden sky), its Core darkens the whole sky, its Clearing leaves the low sky clear under the anvil; the generic
    /// cloud gives way to it; with nothing in its rows the sky is as it was.
    func testTheDomeDrawsTheSupercell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 320, height: 180))
        func render(_ s: SkyState) throws -> CGImage {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = 0
            for i in 0..<3 { r.update(s, quality: .high, size: CGSize(width: 320, height: 180), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            return try XCTUnwrap(preview.capture(r))
        }
        let clear = try render(Self.golden())
        let approach = try render(Self.supercell(Self.golden(), phase: 0.2))
        let core = try render(Self.supercell(Self.golden(), phase: 0.45))
        let clearing = try render(Self.supercell(Self.golden(), phase: WorldWeather.supercellHeld))
        let lum = { (i: CGImage) in PreviewRenderer.stats(i).meanLuminance }
        XCTAssertGreaterThan(PreviewRenderer.difference(clear, approach), 0.02, "the storm stands there")
        XCTAssertLessThan(lum(core), lum(approach), "the Core darkens it all")
        XCTAssertGreaterThan(lum(clearing), lum(core), "and it clears")
        XCTAssertGreaterThan(PreviewRenderer.difference(core, clearing), 0.02)
    }
}

/// The weather previews (spec §14): ash over Moonlit Lake (the moon reddened), the supercell's Approach and Core over
/// Golden Hour Beach, its Clearing with mammatus, and the Approach over the lake by night, lit by its own flicker.
extension WorldPreviewTests {
    func testWriteWeatherPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        func settings(hour: Double, phase: Double, weather: WeatherKind) -> SkySettings {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather; s.spritesMode = .off; s.satellitesMode = .off
            return s
        }
        // Ash over the lake: by moonlight, and at dusk.
        let lakeAsh = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [6], quality: .high,
                                                   sky: settings(hour: 22, phase: 0.55, weather: .ashfall), mood: .serene).first)
        try PreviewRenderer.writePNG(lakeAsh, to: url.appendingPathComponent("lake-ashfall-moon.png"))
        let lakeAshDusk = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [6], quality: .high,
                                                       sky: settings(hour: 19.2, phase: 0.3, weather: .ashfall), mood: .serene).first)
        try PreviewRenderer.writePNG(lakeAshDusk, to: url.appendingPathComponent("lake-ashfall-sunset.png"))
        // The supercell over the beach at golden hour (the beach holds it), at its stages.
        typealias R = FireNeonWeatherRendererTests
        let held = ThemeState()
        let beach = settings(hour: 13, phase: 0.5, weather: .clear)
        for (name, phase, glow) in [("beach-supercell-approach", 0.12, Float(0)), ("beach-supercell-core", 0.45, Float(0)),
                                    ("beach-supercell-core-flash", 0.47, Float(0.9)),
                                    ("beach-supercell-clearing", WorldWeather.supercellHeld, Float(0))] {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [5], state: held, quality: .high,
                                                     sky: beach, skyEdit: { s in s = R.supercell(s, phase: phase, glow: glow) }).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // The Approach over the lake by night, flickering; and the Clearing with the stars coming out.
        let lakeNight = settings(hour: 23, phase: 0.1, weather: .clear)
        for (name, phase, glow) in [("lake-supercell-approach-night", 0.12, Float(0.8)), ("lake-supercell-clearing-night", 0.85, Float(0))] {
            let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: .high, sky: lakeNight, mood: .serene,
                                                     skyEdit: { s in s = R.supercell(s, phase: phase, glow: glow) }).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // The real thing, staged by the sky: the beach 3 minutes into a picked supercell (its Approach becoming its Core).
        var live = beach; live.weather = .supercell
        let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [150], state: held, quality: .high, sky: live).first)
        try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("beach-supercell-live-t150.png"))
    }
}
