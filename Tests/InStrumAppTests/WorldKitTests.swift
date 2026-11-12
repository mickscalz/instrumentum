import XCTest
import Metal
import simd
@testable import InStrumApp
@testable import InStrumCore

@MainActor
final class WorldKitTests: XCTestCase {
    func testSkyShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SkyShaders.source, options: nil)
        for name in ["sky_dome_vertex", "sky_dome_fragment", "weather_vertex", "weather_fragment", "ring_vertex", "ring_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        // The Swift rows match the MSL SkyU byte for byte, the flash row last (the pipeline's own reflection says so).
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sky_dome_vertex")
        d.fragmentFunction = lib.makeFunction(name: "sky_dome_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let skyU = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }.first { $0.index == 0 }
        XCTAssertEqual(skyU?.bufferDataSize, SkyLayer.uniformCount * MemoryLayout<SIMD4<Float>>.stride, "SkyU")
        // Sets 11 & 12 (spec §7.2): after `still`, the six meteor slots' A, B and C rows, then the flash: 44 rows, 704
        // bytes, still one setFragmentBytes (4 KB at most).
        XCTAssertEqual(SkyLayer.stillRow, 24)
        XCTAssertEqual(SkyLayer.meteorSlots, 6)
        XCTAssertEqual(SkyLayer.meteorARow, SkyLayer.stillRow + 1)
        XCTAssertEqual(SkyLayer.meteorBRow, SkyLayer.meteorARow + SkyLayer.meteorSlots)
        XCTAssertEqual(SkyLayer.meteorCRow, SkyLayer.meteorBRow + SkyLayer.meteorSlots)
        XCTAssertEqual(SkyLayer.flashRow, SkyLayer.meteorCRow + SkyLayer.meteorSlots)
        // Fire & Neon (spec §6–§7): after the flash, the far storm and its flicker, the sprites' A and B rows, the
        // satellites' A, B and C rows, the supercell's three and the ash last: 68 rows, 1088 bytes.
        XCTAssertEqual(SkyLayer.stormRow, SkyLayer.flashRow + 1)
        XCTAssertEqual(SkyLayer.stormFlickerRow, SkyLayer.stormRow + 1)
        XCTAssertEqual(SkyLayer.spriteARow, SkyLayer.stormFlickerRow + 1)
        XCTAssertEqual(SkyLayer.spriteBRow, SkyLayer.spriteARow + SkyLayer.spriteSlots)
        XCTAssertEqual(SkyLayer.satARow, SkyLayer.spriteBRow + SkyLayer.spriteSlots)
        XCTAssertEqual(SkyLayer.satBRow, SkyLayer.satARow + SkyLayer.satelliteSlots)
        XCTAssertEqual(SkyLayer.satCRow, SkyLayer.satBRow + SkyLayer.satelliteSlots)
        XCTAssertEqual(SkyLayer.cellARow, SkyLayer.satCRow + SkyLayer.satelliteSlots)
        XCTAssertEqual([SkyLayer.cellBRow, SkyLayer.cellCRow, SkyLayer.ashRow], [SkyLayer.cellARow + 1, SkyLayer.cellARow + 2, SkyLayer.cellARow + 3])
        XCTAssertEqual(SkyLayer.ashRow, SkyLayer.uniformCount - 1)
        XCTAssertEqual(SkyLayer.uniformCount * MemoryLayout<SIMD4<Float>>.stride, 1088)
        // WeatherU: the set's params, then sea smoke's tint and glow (48 bytes, bound for every weather set).
        let w = MTLRenderPipelineDescriptor()
        w.vertexFunction = lib.makeFunction(name: "weather_vertex")
        w.fragmentFunction = lib.makeFunction(name: "weather_fragment")
        w.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        w.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var weatherReflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: w, options: [.bindingInfo, .bufferTypeInfo], reflection: &weatherReflection)
        let weatherU = (weatherReflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }.first { $0.index == 0 }
        XCTAssertEqual(weatherU?.bufferDataSize, 3 * MemoryLayout<SIMD4<Float>>.stride, "WeatherU")
        XCTAssertEqual(MemoryLayout<(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)>.size, 48, "the rows the weather layer binds")
    }

    private func render(_ state: SkyState, quality: QualityLevel = .high, weather: WeatherSurface = .none, frames: Int = 1) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        for i in 0..<frames { r.update(state, quality: quality, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: Float(i) / 30, surface: weather) }
        return try XCTUnwrap(preview.capture(r))
    }

    private func frozen(_ hour: Double, weather: WeatherKind = .clear) -> SkyState {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = weather
        return LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!).step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
    }

    func testSkyRendersNightAndDay() throws {
        let night = PreviewRenderer.stats(try render(frozen(2))).meanLuminance
        let day = PreviewRenderer.stats(try render(frozen(13))).meanLuminance
        XCTAssertLessThan(night, 0.08)
        XCTAssertGreaterThan(day, 0.35)
        XCTAssertGreaterThan(PreviewRenderer.stats(try render(frozen(2))).variance, 0, "stars")
    }

    /// Night, clear, moon 30° up straight ahead: a full moon lights a bigger, brighter patch than a crescent.
    func testFullMoonBrighterThanCrescent() throws {
        func moonState(_ phase: Double) -> SkyState {
            var s = frozen(2)
            s.sun = SkyDirection(azimuth: 180, altitude: -40)
            s.moon = SkyDirection(azimuth: SkyLayer.defaultViewAzimuth(latitude: s.latitude), altitude: 30)
            s.moonPhase = phase
            s.moonLit = (1 - cos(2 * .pi * phase)) / 2
            return s
        }
        let full = PreviewRenderer.brightestPatch(try render(moonState(0.5)), radius: 12)
        let crescent = PreviewRenderer.brightestPatch(try render(moonState(0.1)), radius: 12)
        XCTAssertGreaterThan(full, crescent * 1.5, "full \(full) crescent \(crescent)")
    }

    // MARK: - Halos, the Belt of Venus, pastel dawns, blizzards

    /// The NDC point where an east-north-up direction lands on a 640×360 sky frame.
    private func screenPoint(_ dir: SkyDirection, sky: SkyLayer, latitude: Double) -> (x: Double, y: Double) {
        let cam = sky.camera(latitude: latitude, aspect: 640.0 / 360)
        let d = SkyLayer.enu(dir)
        let f = simd_dot(d, cam.forward)
        return (Double(simd_dot(d, cam.right) / f / cam.tanH), Double(simd_dot(d, cam.up) / f / cam.tanV))
    }

    /// Mean RGB (0…1) of a small square around an NDC point.
    private func rgb(_ image: CGImage, at p: (x: Double, y: Double), radius: Int = 3) -> SIMD3<Double> {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
        var sum = SIMD3<Double>(repeating: 0), n = 0.0
        for row in max(0, cy - radius)...min(h - 1, cy + radius) {
            for col in max(0, cx - radius)...min(w - 1, cx + radius) {
                let i = (row * w + col) * 4
                sum += SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255; n += 1
            }
        }
        return sum / max(1, n)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private func renderSky(_ state: SkyState, viewAzimuth: Double?) throws -> (image: CGImage, sky: SkyLayer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        r.sky.viewAzimuth = viewAzimuth
        r.update(state, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: 0, surface: .none)
        return (try XCTUnwrap(preview.capture(r)), r.sky)
    }

    /// A clear morning with the sun 10° up straight ahead: halos forced on brighten the sundog's spot (22°/cos 10° to
    /// the right) well above a point 15° from the sun; with halo 0 the two match.
    func testHalosAppearAroundTheSun() throws {
        var s = frozen(13)
        let view = SkyLayer.defaultViewAzimuth(latitude: s.latitude)
        s.sun = SkyDirection(azimuth: view, altitude: 10)
        func ratio(halo: Float) throws -> Double {
            var st = s; st.halo = halo
            let (image, sky) = try renderSky(st, viewAzimuth: view)
            let dog = screenPoint(SkyDirection(azimuth: view + HaloOptics.sundogOffset(sunAltitude: 10), altitude: 10), sky: sky, latitude: s.latitude)
            let near = screenPoint(SkyDirection(azimuth: view + 15, altitude: 10), sky: sky, latitude: s.latitude)
            return luma(rgb(image, at: dog)) / max(1e-6, luma(rgb(image, at: near)))
        }
        let on = try ratio(halo: 1), off = try ratio(halo: 0)
        XCTAssertGreaterThanOrEqual(on, 1.15, "sundog against 15°: \(on)")
        XCTAssertEqual(off, 1, accuracy: 0.05, "without halos: \(off)")
    }

    /// Dusk, the sun 3° down: looking away from it, a pink band sits about 10° up; looking 90° from the sun it doesn't.
    func testBeltOfVenusIsPink() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 90, altitude: -3)
        let c = SkyPalette.colours(sunAltitude: -3, cloud: 0, mist: s.mist, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon; s.starVisibility = 0
        // Red over green (a difference: ratios flatten under the tone curve).
        func pinkness(view: Double) throws -> Double {
            let (image, sky) = try renderSky(s, viewAzimuth: view)
            let p = rgb(image, at: screenPoint(SkyDirection(azimuth: view, altitude: 10), sky: sky, latitude: s.latitude))
            return p.x - p.y
        }
        let away = try pinkness(view: 270), side = try pinkness(view: 0)
        XCTAssertGreaterThan(away, 1.1 * side, "away \(away) side \(side)")
    }

    /// The same dawn frame, pastel against plain: a pinker, less orange horizon and a lavender zenith.
    func testPastelDawnTintsTheSky() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 90, altitude: -2)
        s.cloudCover = 0; s.starVisibility = 0
        func frame(pastel: Float) throws -> (horizon: SIMD3<Double>, zenith: SIMD3<Double>) {
            var st = s
            let c = SkyPalette.colours(sunAltitude: -2, cloud: 0, mist: s.mist, moonlight: 0, pastel: pastel)
            st.zenith = c.zenith; st.horizon = c.horizon; st.dawnPastel = pastel
            let (image, sky) = try renderSky(st, viewAzimuth: 0)
            return (rgb(image, at: screenPoint(SkyDirection(azimuth: 0, altitude: 2), sky: sky, latitude: s.latitude), radius: 5),
                    rgb(image, at: (0, 0.9), radius: 5))
        }
        let plain = try frame(pastel: 0), pastel = try frame(pastel: 1)
        let hPlain = plain.horizon.z / plain.horizon.x, hPastel = pastel.horizon.z / pastel.horizon.x
        XCTAssertGreaterThanOrEqual(hPastel, 1.15 * hPlain, "horizon b/r \(hPlain) → \(hPastel)")
        let zPlain = plain.zenith.x / plain.zenith.y, zPastel = pastel.zenith.x / pastel.zenith.y
        XCTAssertGreaterThanOrEqual(zPastel, 1.2 * zPlain, "zenith r/g \(zPlain) → \(zPastel)")
    }

    func testBlizzardDrivesTheSnowSideways() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var s = frozen(13, weather: .blizzard)
        s.snow = 1; s.wind = 1; s.rain = 0
        s.gust = 1
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertGreaterThan(w.tilt, 1.2)
        XCTAssertGreaterThan(w.streamerCount, 0)
        XCTAssertLessThanOrEqual(w.streamerCount, 150)
        s.gust = 0
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertEqual(w.tilt, 0.25, accuracy: 0.01)
        XCTAssertEqual(w.streamerCount, 0)
        s.gust = 1
        w.update(s, quality: .lite, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .ground(horizonY: -0.33))
        XCTAssertLessThanOrEqual(w.streamerCount, 60, "Smooth keeps streamers light")
    }

    func testWeatherLayerScalesWithQualityAndAmount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var s = frozen(13, weather: .rain)
        s.rain = 1
        w.update(s, quality: .lite, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .water(horizonY: -0.2))
        XCTAssertEqual(w.particleCount, 400)
        w.update(s, quality: .ultra, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .water(horizonY: -0.2))
        XCTAssertEqual(w.particleCount, 2500)
        s.rain = 0.5
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.particleCount, 600)
        s.rain = 0; s.snow = 0
        w.update(s, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, surface: .none)
        XCTAssertEqual(w.particleCount, 0)
    }

    // MARK: - The aurora, real stars and constellation lines, light pillars, fireflies and diamond dust

    /// An equatorial unit vector (RA, Dec in degrees) turned into east-north-up with the shader's own basis (the
    /// transpose of `eq`, whose columns are east, north and up in equatorial coordinates).
    private func enu(ra: Float, dec: Float, _ s: SkyState) -> SIMD3<Float> {
        let a = Double(ra) * .pi / 180, d = Double(dec) * .pi / 180
        let v = SIMD3<Float>(Float(cos(d) * cos(a)), Float(cos(d) * sin(a)), Float(sin(d)))
        let b = SkyLayer.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
        return SIMD3(simd_dot(v, b.east), simd_dot(v, b.north), simd_dot(v, b.up))
    }

    /// Points the sky's camera straight at an east-north-up direction (it lands at the frame's centre).
    private func aim(_ sky: SkyLayer, at e: SIMD3<Float>) {
        let alt = asin(Double(min(1, max(-1, e.z))))
        sky.viewAzimuth = atan2(Double(e.x), Double(e.y)) * 180 / .pi
        sky.horizonY = Float(-tan(alt) / tan(sky.verticalFOV * .pi / 360))
    }

    /// The NDC point of an east-north-up direction through the sky's camera.
    private func screenPoint(_ d: SIMD3<Float>, sky: SkyLayer, latitude: Double) -> (x: Double, y: Double) {
        let cam = sky.camera(latitude: latitude, aspect: 640.0 / 360)
        let f = simd_dot(d, cam.forward)
        return (Double(simd_dot(d, cam.right) / f / cam.tanH), Double(simd_dot(d, cam.up) / f / cam.tanV))
    }

    /// Renders a forced state with the sky's camera set up by `configure` (surface none, so the horizon stays put).
    private func renderConfigured(_ state: SkyState, time: Float = 0,
                                  _ configure: (SkyOnlyRenderer) -> Void) throws -> (image: CGImage, sky: SkyLayer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        configure(r)
        r.update(state, quality: .high, size: CGSize(width: 640, height: 360), dt: 1.0 / 30, time: time, surface: .none)
        return (try XCTUnwrap(preview.capture(r)), r.sky)
    }

    /// A clear, moonless night at Melbourne with every new sky value zeroed (tests switch on the one they need).
    private func darkNight() -> SkyState {
        var s = frozen(2)
        s.sun = SkyDirection(azimuth: 0, altitude: -40)
        s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
        let c = SkyPalette.colours(sunAltitude: -40, cloud: 0, mist: 0, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.starVisibility = 1; s.cloudCover = 0; s.mist = 0; s.halo = 0; s.rainbow = 0
        s.aurora = 0; s.auroraStorm = 0; s.auroraAltitude = 0; s.fireflies = 0; s.diamondDust = 0; s.pillar = 0
        s.constellationLines = 0
        return s
    }

    /// Tromsø-like: the band's base 45° up toward the pole. Looking pole-ward, the sky 30–60° up is far brighter with the
    /// aurora on; facing away it is unchanged.
    func testAuroraLightsThePoleSky() throws {
        var s = darkNight()
        s.latitude = 69.6; s.hemisphere = 1; s.auroraAltitude = 45; s.auroraStorm = 0.3
        func patch(aurora: Float, view: Double) throws -> Double {
            var st = s; st.aurora = aurora
            let (image, sky) = try renderConfigured(st) { r in
                r.sky.viewAzimuth = view
                r.sky.horizonY = Float(-tan(45 * Double.pi / 180) / tan(r.sky.verticalFOV * .pi / 360))   // looking 45° up
            }
            let lo = screenPoint(SkyDirection(azimuth: view, altitude: 32), sky: sky, latitude: st.latitude).y
            let hi = screenPoint(SkyDirection(azimuth: view, altitude: 58), sky: sky, latitude: st.latitude).y
            return luma(FramePatch.meanRGB(image, x: -0.3...0.3, y: lo...hi))
        }
        let poleOn = try patch(aurora: 1, view: 0), poleOff = try patch(aurora: 0, view: 0)
        XCTAssertGreaterThanOrEqual(poleOn, 1.4 * poleOff, "pole-ward \(poleOff) → \(poleOn)")
        let awayOn = try patch(aurora: 1, view: 180), awayOff = try patch(aurora: 0, view: 180)
        XCTAssertEqual(awayOn, awayOff, accuracy: max(0.1 * awayOff, 0.5 / 255), "facing away \(awayOff) → \(awayOn)")
        // In the south the band lies the other way.
        var south = s; south.latitude = -60; south.hemisphere = -1; south.aurora = 1
        let (image, sky) = try renderConfigured(south) { r in
            r.sky.viewAzimuth = 180
            r.sky.horizonY = Float(-tan(45 * Double.pi / 180) / tan(r.sky.verticalFOV * .pi / 360))
        }
        let lo = screenPoint(SkyDirection(azimuth: 180, altitude: 32), sky: sky, latitude: -60).y
        let hi = screenPoint(SkyDirection(azimuth: 180, altitude: 58), sky: sky, latitude: -60).y
        XCTAssertGreaterThanOrEqual(luma(FramePatch.meanRGB(image, x: -0.3...0.3, y: lo...hi)), 1.4 * poleOff, "australis")
    }

    /// Sirius from Melbourne, 37° up: its screen point (from its catalogue RA/Dec through the shader's basis and the
    /// sky's camera) is among the brightest 0.1% of the frame; with no stars it is just sky.
    func testRealStarsShow() throws {
        let sirius = try XCTUnwrap(StarCatalogue.star(hip: 32349))
        var s = darkNight()
        s.siderealDegrees = Double(sirius.ra) + 55   // 55° past the meridian
        let e = enu(ra: sirius.ra, dec: sirius.dec, s)
        XCTAssertGreaterThan(asin(Double(e.z)) * 180 / .pi, 30, "Sirius is well up")
        func peak(visibility: Float) throws -> (local: Double, top: Double) {
            var st = s; st.starVisibility = visibility
            let (image, sky) = try renderConfigured(st) { r in
                XCTAssertTrue(r.sky.awaitStars(), "the star texture arrives")
                aim(r.sky, at: e)
            }
            let p = screenPoint(e, sky: sky, latitude: st.latitude)
            let l = FramePatch.luminance(image)
            let w = image.width, h = image.height
            let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
            var local = 0.0
            for y in max(0, cy - 3)...min(h - 1, cy + 3) { for x in max(0, cx - 3)...min(w - 1, cx + 3) { local = max(local, l[y * w + x]) } }
            let sorted = l.sorted(by: >)
            return (local, sorted[max(0, sorted.count / 1000 - 1)])
        }
        let on = try peak(visibility: 1)
        XCTAssertGreaterThanOrEqual(on.local, on.top, "Sirius \(on.local) against the top 0.1% \(on.top)")
        XCTAssertGreaterThan(on.local, 0.5)
        let off = try peak(visibility: 0)
        XCTAssertLessThan(off.local, 0.2, "no stars: \(off.local)")
    }

    /// The Acrux–Gacrux line: its midpoint is brighter with the lines on; with them off the frame matches one drawn
    /// from a texture that has no lines at all.
    func testConstellationLinesCanBeTurnedOff() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let acrux = try XCTUnwrap(StarCatalogue.star(hip: 60718)), gacrux = try XCTUnwrap(StarCatalogue.star(hip: 61084))
        var s = darkNight()
        s.siderealDegrees = Double(acrux.ra + gacrux.ra) / 2 + 40
        let mid = simd_normalize(enu(ra: acrux.ra, dec: acrux.dec, s) + enu(ra: gacrux.ra, dec: gacrux.dec, s))
        XCTAssertGreaterThan(asin(Double(mid.z)) * 180 / .pi, 20, "Crux is up")
        let bare = try XCTUnwrap(StarTextureCache.makeTexture(device: device, bytes: StarTexture.build(lines: false)))
        let a = enu(ra: acrux.ra, dec: acrux.dec, s), b = enu(ra: gacrux.ra, dec: gacrux.dec, s)
        func frame(lines: Float, texture: MTLTexture? = nil) throws -> (image: CGImage, sky: SkyLayer) {
            var st = s; st.constellationLines = lines
            return try renderConfigured(st) { r in
                XCTAssertTrue(r.sky.awaitStars())
                r.sky.starTextureOverride = texture
                aim(r.sky, at: mid)
            }
        }
        let on = try frame(lines: 1), off = try frame(lines: 0), noLines = try frame(lines: 1, texture: bare)
        // The line's middle stretch (35–65% of the way from Acrux to Gacrux): at nine points along it, the brightest
        // pixel within 2 px (the line is a pixel or two wide); the median ignores any star that happens to sit there.
        func lineLight(_ f: (image: CGImage, sky: SkyLayer)) -> Double {
            let l = FramePatch.luminance(f.image), w = f.image.width, h = f.image.height
            var samples: [Double] = []
            for i in 0..<9 {
                let t = Float(0.35 + 0.3 * Double(i) / 8)
                let p = screenPoint(simd_normalize(a * (1 - t) + b * t), sky: f.sky, latitude: s.latitude)
                let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
                var best = 0.0
                for y in max(0, cy - 2)...min(h - 1, cy + 2) { for x in max(0, cx - 2)...min(w - 1, cx + 2) { best = max(best, l[y * w + x]) } }
                samples.append(best)
            }
            return samples.sorted()[4]
        }
        let lOn = lineLight(on), lOff = lineLight(off)
        XCTAssertGreaterThanOrEqual(lOn, 1.15 * lOff, "along the line \(lOff) → \(lOn)")
        let diff = FramePatch.difference(off.image, noLines.image, x: -1...1, y: -1...1)
        let mean = PreviewRenderer.stats(noLines.image).meanLuminance
        XCTAssertLessThanOrEqual(diff, max(0.02 * mean, 0.5 / 255), "lines 0 leaves no trace: \(diff)")
    }

    /// Diamond dust with the sun 4° up: a column stands 6° above it, brighter than the sky 6° beside the column.
    func testPillarsStandOverTheLowSun() throws {
        var s = frozen(13)
        let view = SkyLayer.defaultViewAzimuth(latitude: s.latitude)
        s.sun = SkyDirection(azimuth: view, altitude: 4)
        s.moon = SkyDirection(azimuth: view + 180, altitude: -30)
        let c = SkyPalette.colours(sunAltitude: 4, cloud: 0, mist: 0, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.starVisibility = 0; s.cloudCover = 0; s.mist = 0; s.halo = 0; s.rainbow = 0
        s.diamondDust = 0   // the pillar alone (the crystals are the weather layer's, tested below)
        func ratio(pillar: Float) throws -> Double {
            var st = s; st.pillar = pillar
            let (image, sky) = try renderSky(st, viewAzimuth: view)
            let above = screenPoint(SkyDirection(azimuth: view, altitude: 10), sky: sky, latitude: st.latitude)
            let beside = screenPoint(SkyDirection(azimuth: view + 6, altitude: 10), sky: sky, latitude: st.latitude)
            return luma(rgb(image, at: above, radius: 2)) / max(1e-6, luma(rgb(image, at: beside, radius: 2)))
        }
        let on = try ratio(pillar: 1), off = try ratio(pillar: 0)
        XCTAssertGreaterThanOrEqual(on, 1.2, "pillar against beside: \(on)")
        XCTAssertEqual(off, 1, accuracy: 0.1, "no pillar: \(off)")
    }

    // MARK: - Iridescent cloud and rime frost (Sets 9 & 10)

    /// Light cloud with the sun 20° up, 30° left of the view's centre, and iridescence forced to 1 (spec §6.3). A
    /// patch 15° from the sun holding a cloud's edge takes on colour across the sky's own hue (pastel pinks and
    /// greens; a plain blue sky over white cloud has almost none, its variance is the 8-bit floor) ≥ 1.5× the same
    /// frame with iridescence 0 (the CPU reference render measured about 35×). 60° from the sun nothing changes.
    func testIridescenceTintsThinCloudNearTheSun() throws {
        var s = frozen(13)
        s.sun = SkyDirection(azimuth: 0, altitude: 20)
        s.moon = SkyDirection(azimuth: 180, altitude: -30); s.moonLit = 0
        let c = SkyPalette.colours(sunAltitude: 20, cloud: 0.35, mist: 0.15, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.cloudCover = 0.35; s.mist = 0.15; s.wind = 0.2
        s.starVisibility = 0; s.halo = 0; s.rainbow = 0; s.dawnPastel = 0; s.gust = 0
        s.aurora = 0; s.fireflies = 0; s.diamondDust = 0; s.pillar = 0; s.rime = 0
        func frame(_ iridescence: Float) throws -> (image: CGImage, sky: SkyLayer) {
            var st = s; st.iridescence = iridescence
            return try renderConfigured(st) { r in r.sky.viewAzimuth = 30; r.sky.horizonY = -0.33 }
        }
        let on = try frame(1), off = try frame(0)
        XCTAssertEqual(on.sky.uniforms[SkyLayer.stillRow], SIMD4<Float>(1, 0, 0.2, 0), "iridescence, rime, the wind on screen")
        // A patch ±4° about the point at the sun's altitude `degrees` from it, toward the view's centre.
        let alt = 20.0 * Double.pi / 180
        func patch(_ degrees: Double, _ image: CGImage) -> [SIMD3<Double>] {
            let r = degrees * Double.pi / 180
            let dAz = acos(min(1, max(-1, (cos(r) - sin(alt) * sin(alt)) / (cos(alt) * cos(alt))))) * 180 / .pi
            let centre = screenPoint(SkyDirection(azimuth: dAz, altitude: 20), sky: on.sky, latitude: s.latitude)
            let side = screenPoint(SkyDirection(azimuth: dAz + 4 / cos(alt), altitude: 20), sky: on.sky, latitude: s.latitude)
            let above = screenPoint(SkyDirection(azimuth: dAz, altitude: 24), sky: on.sky, latitude: s.latitude)
            let hx = abs(side.x - centre.x), hy = abs(above.y - centre.y)
            return FramePatch.pixels(image, x: (centre.x - hx)...(centre.x + hx), y: (centre.y - hy)...(centre.y + hy))
        }
        let w = SIMD3<Double>(0.2126, 0.7152, 0.0722)
        func lum(_ p: SIMD3<Double>) -> Double { simd_dot(p, w) }
        // Each pixel's colour less its luminance, with the part along the reference patch's mean (the sky's hue) taken
        // out; the variance of what is left.
        func crossHueVariance(_ px: [SIMD3<Double>], reference: [SIMD3<Double>]) -> Double {
            func chroma(_ p: SIMD3<Double>) -> SIMD3<Double> { p - SIMD3(repeating: lum(p)) }
            let mean = reference.reduce(SIMD3<Double>(repeating: 0)) { $0 + chroma($1) } / Double(max(1, reference.count))
            let axis = simd_length(mean) > 1e-9 ? simd_normalize(mean) : SIMD3<Double>(0, 0, 1)
            let rest = px.map { p -> SIMD3<Double> in let q = chroma(p); return q - axis * simd_dot(q, axis) }
            let m = rest.reduce(SIMD3<Double>(repeating: 0), +) / Double(max(1, rest.count))
            return rest.reduce(0) { $0 + simd_length_squared($1 - m) } / Double(max(1, rest.count))
        }
        let near0 = patch(15, off.image), near1 = patch(15, on.image)
        let lumas = near0.map(lum)
        XCTAssertGreaterThan((lumas.max() ?? 0) - (lumas.min() ?? 0), 0.08, "the patch holds a cloud's edge")
        let v0 = crossHueVariance(near0, reference: near0), v1 = crossHueVariance(near1, reference: near0)
        XCTAssertGreaterThanOrEqual(v1, 1.5 * v0, "15° from the sun: \(v0) → \(v1)")
        // 60° away (iridescence is gone by 40°): the same light and the same colour.
        let far0 = patch(60, off.image), far1 = patch(60, on.image)
        func meanLuma(_ px: [SIMD3<Double>]) -> Double { px.reduce(0) { $0 + lum($1) } / Double(max(1, px.count)) }
        XCTAssertFalse(far0.isEmpty)
        XCTAssertEqual(meanLuma(far1), meanLuma(far0), accuracy: 0.05 * meanLuma(far0), "60° from the sun")
        let f0 = crossHueVariance(far0, reference: far0), f1 = crossHueVariance(far1, reference: far0)
        XCTAssertEqual(f1, f0, accuracy: max(0.05 * f0, 1e-6), "60° from the sun: colour")
    }

    func testFirefliesAndCrystalsFollowTheirWeathers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        let size = CGSize(width: 640, height: 360)
        var s = darkNight()
        s.rain = 0; s.snow = 0
        s.fireflies = 1
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, WeatherLayer.fireflyCap(.high))
        XCTAssertEqual(w.crystalCount, 0, "no dust, no crystals")
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .water(horizonY: -0.3))
        XCTAssertGreaterThan(w.fireflyCount, 0)
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.fireflyCount, 0, "none on glass")
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .none)
        XCTAssertEqual(w.fireflyCount, 0, "none without a surface")
        s.fireflies = 0.5
        w.update(s, quality: .ultra, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, WeatherLayer.fireflyCap(.ultra) / 2)
        s.fireflies = 0
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
        XCTAssertEqual(w.fireflyCount, 0)

        s.diamondDust = 1
        for q in QualityLevel.allCases {
            w.update(s, quality: q, size: size, dt: 1.0 / 30, surface: .glass)
            XCTAssertEqual(w.crystalCount, WeatherLayer.crystalCap(q), "\(q)")
            XCTAssertEqual(w.fireflyCount, 0)
        }
        XCTAssertLessThan(WeatherLayer.crystalCap(.lite), WeatherLayer.crystalCap(.high))
        XCTAssertLessThan(WeatherLayer.crystalCap(.high), WeatherLayer.crystalCap(.ultra))
        XCTAssertLessThan(WeatherLayer.fireflyCap(.lite), WeatherLayer.fireflyCap(.high))
        XCTAssertLessThan(WeatherLayer.fireflyCap(.high), WeatherLayer.fireflyCap(.ultra))
        XCTAssertLessThanOrEqual(WeatherLayer.fireflyCap(.lite), 60, "Smooth stays light")
        XCTAssertLessThanOrEqual(WeatherLayer.crystalCap(.lite), 150, "Smooth stays light")
        s.diamondDust = 0
        w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .glass)
        XCTAssertEqual(w.crystalCount, 0)

        // Rime frost's freezing fog: the same crystals as a fine ice-fog drift, sparse and settling slowly (spec §6.4).
        var fog = darkNight(); fog.weather = .rime; fog.nextWeather = .rime; fog.weatherBlend = 0
        for q in QualityLevel.allCases {
            w.update(fog, quality: q, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3))
            XCTAssertEqual(w.crystalCount, Int((Float(WeatherLayer.crystalCap(q)) * WeatherLayer.rimeFogDensity).rounded()), "\(q)")
        }
        XCTAssertLessThanOrEqual(WeatherLayer.rimeFogDensity, 0.35, "low density")
        XCTAssertEqual(WeatherLayer.crystalMix(fog).fogShare, 1, accuracy: 1e-6)
        XCTAssertLessThan(WeatherLayer.rimeFogFall, 0.5, "slower than diamond dust")
        fog.diamondDust = 1   // dust and fog together: the cap, mostly dust
        XCTAssertEqual(WeatherLayer.crystalMix(fog).amount, 1, accuracy: 1e-6)
        XCTAssertLessThan(WeatherLayer.crystalMix(fog).fogShare, 0.3)
        XCTAssertEqual(WeatherLayer.crystalMix(darkNight()).amount, 0, "no fog, no dust: none")

        // Both draw (a frame with them is brighter than one without) and live in the shared ring buffer.
        var both = darkNight(); both.fireflies = 1; both.diamondDust = 1
        let lit = PreviewRenderer.stats(try render(both, weather: .ground(horizonY: -0.33), frames: 10)).meanLuminance
        let dark = PreviewRenderer.stats(try render(darkNight(), weather: .ground(horizonY: -0.33), frames: 10)).meanLuminance
        XCTAssertGreaterThan(lit, dark)
    }

    /// Review focus 4: the star texture arrives late (a background build). Every sky and world renders without it
    /// (the procedural stars, a placeholder bound at texture 0) and with it, and no frame waits for it.
    func testSkyRendersBeforeAndAfterTheStarTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let cache = StarTextureCache.shared
        defer { cache.withheld = false }
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        XCTAssertEqual(r.sky.uniforms.count, SkyLayer.uniformCount)
        XCTAssertEqual(SkyLayer.uniformCount, 68)

        cache.withheld = true
        XCTAssertNil(r.sky.starTexture)
        XCTAssertEqual(r.sky.uniforms[8].w, 0, "the shader is told to use the procedural stars")
        let before = try render(darkNight())
        XCTAssertGreaterThan(PreviewRenderer.stats(before).variance, 0, "procedural stars before the texture")
        var lake = SkySettings(); lake.timeMode = .frozen; lake.frozenHour = 22; lake.cityID = "melbourne"
        lake.weatherMode = .pick; lake.weather = .clear
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for id in [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id, BedroomDawnModel.id,
                   AuroraFjordModel.id, BioluminescentBayModel.id] {
            let image = try XCTUnwrap(preview.render(themeID: id, at: [0.5], sky: lake).first, id)
            XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0, "\(id) without the stars")
        }

        cache.withheld = false
        XCTAssertTrue(r.sky.awaitStars(), "the texture arrives within seconds")
        XCTAssertNotNil(r.sky.starTexture)
        XCTAssertEqual(r.sky.uniforms[8].w, 1)
        XCTAssertEqual(r.sky.starTexture?.width, StarTexture.width)
        XCTAssertEqual(r.sky.starTexture?.height, StarTexture.height)
        XCTAssertEqual(r.sky.starTexture?.pixelFormat, MTLPixelFormat.rgba8Unorm)
        XCTAssertEqual(cache.builds, 1, "built once per process")
        let after = try render(darkNight())
        XCTAssertGreaterThan(PreviewRenderer.stats(after).variance, 0, "real stars after")
        XCTAssertGreaterThan(FramePatch.difference(before, after, x: -1...1, y: -1...1), 0, "the real stars change the sky")
        for id in [MoonlitLakeModel.id, GoldenHourBeachModel.id, CoastRoadModel.id, SnowboundCabinModel.id, BedroomDawnModel.id,
                   AuroraFjordModel.id, BioluminescentBayModel.id] {
            let image = try XCTUnwrap(preview.render(themeID: id, at: [0.5], sky: lake).first, id)
            XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0, "\(id) with the stars")
        }
        _ = SkyOnlyRenderer(device: device)
        XCTAssertEqual(cache.builds, 1, "a new sky shares the texture")
    }

    func testRainyNightRendersAndLightningIsLimited() throws {
        var s = frozen(2, weather: .storm)
        s.rain = 1; s.cloudCover = 1; s.lightning = 1
        let image = try render(s, weather: .water(horizonY: -0.2), frames: 20)
        XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var boosts: [Float] = []
        for i in 0..<60 {   // a flash request every frame for 2 s: the limiter allows at most 3 big jumps a second
            s.lightning = i % 2 == 0 ? 1 : 0
            w.update(s, quality: .lite, size: CGSize(width: 320, height: 180), dt: 1.0 / 30, surface: .none)
            boosts.append(w.exposureBoost)
        }
        var jumps = 0
        for i in 3..<boosts.count where boosts[i] - boosts[i - 3] > FlashLimiter.flashRise { jumps += 1 }
        XCTAssertLessThanOrEqual(jumps, 2 * 3 * 3, "limited")
        XCTAssertGreaterThan(boosts.max() ?? 1, 1, "lightning does brighten the scene")
    }

    /// A light pillar is a thin column, not a flare: in diamond dust (its halos and mist) with the sun 4° up, the column
    /// 10° above the sun is still a colour after the tone curve, not clipped white, and still brighter than the sky 6°
    /// beside it. (The crystals are left out: they're the weather layer's, twinkling at random.)
    func testPillarIsAColumnNotAFlare() throws {
        var s = frozen(13)
        let view = SkyLayer.defaultViewAzimuth(latitude: s.latitude)
        s.sun = SkyDirection(azimuth: view, altitude: 4)
        s.moon = SkyDirection(azimuth: view + 180, altitude: -30)
        let c = SkyPalette.colours(sunAltitude: 4, cloud: 0, mist: 0.2, moonlight: 0)
        s.zenith = c.zenith; s.horizon = c.horizon
        s.starVisibility = 0; s.cloudCover = 0; s.mist = 0.2; s.halo = 1; s.rainbow = 0
        s.pillar = 1; s.diamondDust = 0
        let (image, sky) = try renderSky(s, viewAzimuth: view)
        let column = rgb(image, at: screenPoint(SkyDirection(azimuth: view, altitude: 14), sky: sky, latitude: s.latitude), radius: 2)
        let beside = rgb(image, at: screenPoint(SkyDirection(azimuth: view + 6, altitude: 14), sky: sky, latitude: s.latitude), radius: 2)
        XCTAssertLessThan(luma(column), 0.95, "10° above the sun the column is a colour, not clipped white: \(column)")
        XCTAssertGreaterThanOrEqual(luma(column) / max(1e-6, luma(beside)), 1.2, "and still a column: \(column) beside \(beside)")
    }

    /// Spec §6.4: bound, the real stars replace the procedural field's brightest 30%, which stays only as the faint
    /// background. With a texture bound that has no stars in it, the night's brightest points are no brighter than a
    /// second-magnitude star; while the texture is still building, the procedural field's bright stars carry the sky.
    func testRealStarsReplaceTheBrightProceduralStars() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let blank = [UInt8](repeating: 0, count: StarTexture.width * StarTexture.height * 4)
        let empty = try XCTUnwrap(StarTextureCache.makeTexture(device: device, bytes: blank))
        let cache = StarTextureCache.shared
        defer { cache.withheld = false }
        func top(_ configure: (SkyOnlyRenderer) -> Void) throws -> Double {
            let l = FramePatch.luminance(try renderConfigured(darkNight(), configure).image).sorted(by: >)
            return l[l.count / 1000]   // the brightest 0.1%
        }
        let bound = try top { r in r.sky.starTextureOverride = empty }
        cache.withheld = true
        let alone = try top { _ in }
        cache.withheld = false
        XCTAssertLessThan(bound, 0.6, "under the real stars only faint procedural ones: \(bound)")
        XCTAssertGreaterThan(alone, 0.75, "on their own the procedural stars keep their bright ones: \(alone)")
    }

    /// Long sessions: the weather clock wraps at the hour, and every firefly's blink and crystal's twinkle is a whole
    /// number of cycles an hour, so a moment just short of the wrap draws as the same moment an hour earlier.
    func testWeatherClockWrapsWithoutAJump() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let late = try XCTUnwrap(WeatherLayer(device: device)), early = try XCTUnwrap(WeatherLayer(device: device))
        var s = darkNight(); s.fireflies = 1; s.diamondDust = 1
        let size = CGSize(width: 640, height: 360)
        // The same seed, so the same fireflies and crystals; then the same moment, an hour apart.
        for w in [late, early] { w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3)) }
        late.clock = WeatherLayer.clockWrap - 0.5
        early.clock = -0.5
        for w in [late, early] { w.update(s, quality: .high, size: size, dt: 1.0 / 30, surface: .ground(horizonY: -0.3)) }
        XCTAssertEqual(late.crystalInstances.count, WeatherLayer.crystalCap(.high))
        XCTAssertEqual(late.crystalInstances.count, early.crystalInstances.count)
        var gap: Float = 0
        for (a, b) in zip(late.crystalInstances, early.crystalInstances) { gap += abs(a.w - b.w) }
        gap /= Float(max(1, late.crystalInstances.count))
        XCTAssertLessThan(gap, 0.01, "each crystal twinkles alike an hour apart (mean alpha gap \(gap))")
        let lit = late.fireflyInstances.map(\.w).reduce(0, +), earlier = early.fireflyInstances.map(\.w).reduce(0, +)
        XCTAssertGreaterThan(earlier, 0, "some fireflies are lit")
        XCTAssertEqual(lit, earlier, accuracy: 0.05 + 0.002 * earlier, "and every firefly blinks alike (\(lit) against \(earlier))")
    }

    // MARK: - Shooting stars (Sets 11 & 12)

    /// A forced meteor across the north-facing view (darkNight's): from 24° left and 40° up to 20° right and 23° up, born
    /// at 0 on the meteors' clock and running 0.8 s.
    static func crossing(magnitude: Float = -1) -> Meteor {
        Meteor(start: SkyLayer.enu(SkyDirection(azimuth: -24, altitude: 40)), end: SkyLayer.enu(SkyDirection(azimuth: 20, altitude: 23)),
               born: 0, duration: 0.8, magnitude: magnitude)
    }

    /// A point on a meteor's great circle `s` of the way from its start to its end, `off` radians to one side of it.
    static func onPath(_ m: Meteor, _ s: Float, off: Float = 0) -> SIMD3<Float> {
        let pole = simd_normalize(simd_cross(m.start, m.end)), arc = acos(min(1, max(-1, simd_dot(m.start, m.end))))
        let d = m.start * cos(s * arc) + simd_cross(pole, m.start) * sin(s * arc)
        return simd_normalize(d + pole * off)
    }

    /// The brightest pixel within a pixel of each of nine points along a meteor's visible streak (its tail, 35–60% of
    /// the way, up to its head at 60%), summed; `off` moves the points that far to one side.
    private func streakLight(_ image: CGImage, sky: SkyLayer, _ m: Meteor, off: Float = 0) -> Double {
        let l = FramePatch.luminance(image), w = image.width, h = image.height
        var sum = 0.0
        for i in 0..<9 {
            let p = screenPoint(Self.onPath(m, 0.36 + 0.24 * Float(i) / 8, off: off), sky: sky, latitude: -37.8)
            let cx = Int((p.x + 1) / 2 * Double(w)), cy = Int((1 - p.y) / 2 * Double(h))
            var best = 0.0
            for y in max(0, cy - 1)...min(h - 1, cy + 1) { for x in max(0, cx - 1)...min(w - 1, cx + 1) { best = max(best, l[y * w + x]) } }
            sum += best
        }
        return sum
    }

    /// Spec §6.3 and §7.2: a forced meteor in a slot draws a thin streak across the sky. With its head 60% along (0.48 s
    /// of 0.8), the points along its tail and head are ≥ 30% brighter than the same points 3° off its path (the CPU
    /// reference render measured about 40×); the rest of the frame is the sky's own. With every slot empty (the meteor
    /// long gone, or none at all) the rows are zero and the frame is the sky's, unchanged.
    func testMeteorDrawsAStreakInTheSky() throws {
        let m = Self.crossing()
        func shot(_ meteors: [Meteor], at t: Double) throws -> (image: CGImage, sky: SkyLayer) {
            var s = darkNight(); s.meteors = meteors; s.meteorTime = t; s.meteorFlash = 0
            return try renderConfigured(s) { r in r.sky.viewAzimuth = 0; r.sky.horizonY = -0.33 }
        }
        let lit = try shot([m], at: 0.48)
        let rows = lit.sky.uniforms
        XCTAssertEqual(rows[SkyLayer.meteorARow].w, 0.6, accuracy: 1e-4, "the head's progress")
        XCTAssertEqual(rows[SkyLayer.meteorBRow].w, m.headBrightness(at: 0.48), accuracy: 1e-5, "its light from Core")
        XCTAssertEqual(rows[SkyLayer.meteorCRow].w, 0, "a head, not a train")
        let along = streakLight(lit.image, sky: lit.sky, m), beside = streakLight(lit.image, sky: lit.sky, m, off: 3 * .pi / 180)
        XCTAssertGreaterThanOrEqual(along, 1.3 * beside, "along the streak \(along), beside it \(beside)")
        let gone = try shot([m], at: 5), none = try shot([], at: 5)
        for i in 0..<SkyLayer.meteorSlots {
            for row in [SkyLayer.meteorARow, SkyLayer.meteorBRow, SkyLayer.meteorCRow] { XCTAssertEqual(gone.sky.uniforms[row + i], .zero) }
        }
        XCTAssertEqual(gone.sky.uniforms[SkyLayer.flashRow], .zero)
        XCTAssertEqual(FramePatch.difference(gone.image, none.image, x: -1...1, y: -1...1), 0, "every slot empty: the sky as it was")
        // Away from the streak (the lower half of the frame, well clear of its glow) the meteor changes nothing.
        XCTAssertLessThan(FramePatch.difference(lit.image, none.image, x: -1...1, y: -1...0), 0.0005)
    }

    /// Spec §6.3: clouds hide the meteors (they burn 80–100 km up). The same streak, of magnitude 0, keeps under 10% of its
    /// clear-sky contrast (the light it adds along its path) under overcast (the CPU reference render: 0.05%).
    func testCloudsHideMeteors() throws {
        let m = Self.crossing(magnitude: 0)
        var overcast = frozen(2, weather: .overcast)
        overcast.sun = SkyDirection(azimuth: 0, altitude: -40)
        overcast.moon = SkyDirection(azimuth: 0, altitude: -30); overcast.moonLit = 0
        let c = SkyPalette.colours(sunAltitude: -40, cloud: overcast.cloudCover, mist: overcast.mist, moonlight: 0)
        overcast.zenith = c.zenith; overcast.horizon = c.horizon
        overcast.aurora = 0; overcast.halo = 0; overcast.rainbow = 0
        XCTAssertGreaterThan(overcast.cloudCover, 0.8, "overcast")
        func contrast(_ sky: SkyState) throws -> Double {
            func shot(_ meteors: [Meteor]) throws -> (image: CGImage, sky: SkyLayer) {
                var s = sky; s.meteors = meteors; s.meteorTime = 0.48; s.meteorFlash = 0
                return try renderConfigured(s) { r in r.sky.viewAzimuth = 0; r.sky.horizonY = -0.33 }
            }
            let with = try shot([m]), without = try shot([])
            return streakLight(with.image, sky: with.sky, m) - streakLight(without.image, sky: without.sky, m)
        }
        let clear = try contrast(darkNight()), cloudy = try contrast(overcast)
        XCTAssertGreaterThan(clear, 0.5, "a clear sky shows it: \(clear)")
        XCTAssertLessThan(cloudy, 0.1 * clear, "overcast hides it: \(cloudy) of \(clear)")
    }

    /// Spec §6.4: every world with open water sets its band each frame from its own geometry, and under a sea-smoke sky
    /// its steam fills to the cap: the lake (the keys to the far shore's foot), the beach (the waterline, 11 m out from
    /// 2 m up, to the horizon), the road (the sea in the window, from the scrub to the horizon), the fjord (the keys to the
    /// sea end) and the bay (its waterline where its own camera puts it, to the horizon).
    func testEveryWaterWorldSetsItsBand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let size = CGSize(width: 640, height: 360)
        var smoke = SkySettings(); smoke.timeMode = .frozen; smoke.frozenHour = 7; smoke.cityID = "melbourne"
        smoke.weatherMode = .pick; smoke.weather = .seaSmoke
        func step(_ id: String) -> (frame: Any, params: ParameterSet) {
            let d = SceneDirector(themeID: id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            d.clock = { Date(timeIntervalSince1970: 1_793_000_000) }
            d.sky.reset(settings: smoke)
            return (d.step(dt: 1.0 / 60, t: 1.0 / 60, quality: .high), d.parameters)
        }
        func check(_ name: String, _ weather: WeatherLayer, horizon: Float) throws -> SIMD4<Float> {
            let band = try XCTUnwrap(weather.waterBand, name)
            XCTAssertTrue(WeatherLayer.usableBand(band), "\(name): \(band)")
            XCTAssertEqual(band.w, horizon, accuracy: 1e-5, "\(name): up to the horizon")
            XCTAssertTrue(band.x >= -1 && band.z <= 1 && band.y >= -1, "\(name): on screen \(band)")
            XCTAssertEqual(weather.steamCount, WeatherLayer.steamCap(.high), name)
            return band
        }
        let lakeStep = step(MoonlitLakeModel.id)
        let lake = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        lake.update(try XCTUnwrap(lakeStep.frame as? LakeFrame), params: lakeStep.params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        let lakeBand = try check("lake", lake.weather, horizon: lake.horizonY)
        XCTAssertEqual(lakeBand.y, -1 + 2 * Float(lakeStep.params.number("keys.height")), accuracy: 1e-5, "from the keys")

        let beachStep = step(GoldenHourBeachModel.id)
        let beach = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        beach.update(try XCTUnwrap(beachStep.frame as? BeachFrame), params: beachStep.params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        let beachKeys = -1 + 2 * Float(beachStep.params.number("keys.height"))
        let beachBand = try check("beach", beach.weather, horizon: beachKeys + (1 - beachKeys) * 0.4)
        XCTAssertGreaterThan(beachBand.y, beachKeys + 0.05, "the sand lies between the keys and the sea")

        let roadStep = step(CoastRoadModel.id)
        let road = try XCTUnwrap(CoastRoadRenderer(device: device))
        road.update(try XCTUnwrap(roadStep.frame as? RoadFrame), params: roadStep.params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        let roadBottom = -1 + 2 * Float(roadStep.params.number("keys.height")) + 0.1
        let roadBand = try check("road", road.weather, horizon: roadBottom + (0.9 - roadBottom) * 0.62)
        XCTAssertTrue(roadBand.x > -0.93 && roadBand.z < 0.93, "inside the window")
        XCTAssertGreaterThan(roadBand.y, roadBottom + 0.34 + 0.09, "above the scrub")
        XCTAssertLessThan(road.weather.steamDrift, 0, "the sea passes right to left as the car drives")

        let fjordStep = step(AuroraFjordModel.id)
        let fjord = try XCTUnwrap(AuroraFjordRenderer(device: device))
        fjord.update(try XCTUnwrap(fjordStep.frame as? FjordFrame), params: fjordStep.params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        _ = try check("fjord", fjord.weather, horizon: fjord.horizonY)

        let bayStep = step(BioluminescentBayModel.id)
        let bay = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        bay.update(try XCTUnwrap(bayStep.frame as? BayFrame), params: bayStep.params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        let bayBand = try check("bay", bay.weather, horizon: bay.horizonY)
        XCTAssertEqual(bayBand.y, bay.waterlineY, accuracy: 1e-4, "from the waterline, as the bay's own camera has it")
    }
}

/// Moonlit Lake (Set 1's world) with Lake Ripples.
@MainActor
final class MoonlitLakeRendererTests: XCTestCase {
    func testLakeShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: MoonlitLakeShaders.source, options: nil)
        for name in ["lake_vertex", "lake_fragment", "firefly_vertex", "firefly_fragment", "lake_keys_vertex", "lake_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    /// In Always the aurora is for the show, so it stands where a world looks: the lake at Melbourne faces north (the
    /// equator), its back to the pole, and an Always night there has a brighter sky than a Never one. (The lake itself
    /// doesn't offer the Aurora choice: the test's lake does.)
    func testAlwaysAuroraIsInView() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let lake = ThemeEntry.make(MoonlitLakeModel.self)
        let entry = ThemeEntry(id: lake.id, name: lake.name, parameters: lake.parameters + [AuroraMode.spec(default: .follow)],
                               macroTargets: lake.macroTargets, make: lake.make)
        var night = Self.night
        night.frozenPhase = 0.1   // a thin moon, set with the sun: the lake faces the equator
        let size = CGSize(width: 640, height: 360)
        func shot(_ mode: AuroraMode) throws -> (image: CGImage, sky: SkyState) {
            let r = try XCTUnwrap(MoonlitLakeRenderer(device: device))
            let d = SceneDirector(entry: entry, state: ThemeState(values: ["aurora.mode": .choice(mode.rawValue)]),
                                  reaction: ReactionPresets.expressivePianist)
            let start = Date(timeIntervalSince1970: 1_793_000_000)
            var elapsed = 0.0
            d.clock = { start.addingTimeInterval(elapsed) }
            d.sky.reset(settings: night)
            var sky = SkyState()
            for i in 1...30 {
                elapsed = Double(i) / 60
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: elapsed, quality: .high) as? LakeFrame)
                r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
                sky = f.sky
            }
            return (try XCTUnwrap(preview.capture(r)), sky)
        }
        let always = try shot(.always), never = try shot(.never)
        XCTAssertTrue(always.sky.auroraAlways)
        XCTAssertFalse(never.sky.auroraAlways)
        XCTAssertGreaterThan(always.sky.aurora, 0.5, "Always, on a clear night")
        XCTAssertLessThan(always.sky.moon.altitude, -5, "no moon to face")
        func light(_ image: CGImage) -> Double {
            let c = FramePatch.meanRGB(image, x: -1...1, y: 0.3...1)   // the sky, well above the hills
            return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        }
        XCTAssertGreaterThanOrEqual(light(always.image), 1.3 * light(never.image),
                                    "the aurora stands in the lake's sky: \(light(never.image)) → \(light(always.image))")
    }

    static var night: SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 22; s.frozenPhase = 0.55; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    func testLakePreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: q, sky: Self.night, mood: .serene).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
        // The demo's hard low note lands at 2.0 s: the lake answers it.
        let frames = preview.render(themeID: MoonlitLakeModel.id, at: [1.95, 2.35], quality: .high, sky: Self.night, mood: .serene)
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(PreviewRenderer.difference(frames[0], frames[1]), 0.005)
    }

    /// Steps the lake at 60 fps with each frame's sky edited (no notes) and captures the frame at `seconds`.
    private func renderLake(at seconds: Double, sky: SkySettings, quality: QualityLevel, width: Int, height: Int,
                            skyEdit: (inout SkyState) -> Void) throws -> (image: CGImage, renderer: MoonlitLakeRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .serene
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            guard var f = d.step(dt: 1.0 / 60, t: t, quality: quality) as? LakeFrame else { continue }
            skyEdit(&f.sky)
            r.update(f, params: d.parameters, quality: quality, gentle: false, dt: 1.0 / 60, size: size)
        }
        return (try XCTUnwrap(preview.capture(r)), r)
    }

    /// Rime frost at midday (clear, the sun high and out of view): the far shore's edge — silhouette pixels (darker
    /// than half the sky) within 3 px of brighter pixels beside or above them — is ≥ 15% brighter with the world fully
    /// rimed (the CPU reference render measured about 2× at every view azimuth). Smooth (no depth of field) at the
    /// previews' size, so the fringe spans a few pixels.
    func testRimeWhitensTheLakePines() throws {
        let w = 1280, h = 720
        let noon = GoldenHourBeachRendererTests.midday
        let bare = try renderLake(at: 1, sky: noon, quality: .lite, width: w, height: h) { $0.rime = 0 }
        let rimed = try renderLake(at: 1, sky: noon, quality: .lite, width: w, height: h) { $0.rime = 1 }
        let l0 = FramePatch.luminance(bare.image), l1 = FramePatch.luminance(rimed.image)
        // The band from the horizon up past the pines, clear of the reeds at the frame's edges.
        let horizon = Double(bare.renderer.horizonY)
        var region: [Int] = []
        for row in 0..<h {
            let y = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y >= horizon, y <= horizon + 0.25 else { continue }
            for col in 0..<w where abs(2 * (Double(col) + 0.5) / Double(w) - 1) <= 0.6 { region.append(row * w + col) }
        }
        let sorted = region.map { l0[$0] }.sorted()
        let sky = sorted[Int(Double(sorted.count - 1) * 0.9)]
        func bright(_ i: Int) -> Bool { l0[i] >= 0.5 * sky }
        var sum0 = 0.0, sum1 = 0.0, n = 0
        for i in region where !bright(i) {
            let row = i / w, col = i % w
            var edge = false
            for k in 1...3 where !edge {
                edge = (col - k >= 0 && bright(i - k)) || (col + k < w && bright(i + k)) || (row - k >= 0 && bright(i - k * w))
            }
            if edge { sum0 += l0[i]; sum1 += l1[i]; n += 1 }
        }
        XCTAssertGreaterThan(n, 500, "the far shore's edge is in view")
        let before = sum0 / Double(max(1, n)), after = sum1 / Double(max(1, n))
        XCTAssertGreaterThanOrEqual(after, 1.15 * before, "the pines' edge: \(before) → \(after)")
    }

    /// Spec §6.3: the meteors are in skyRadiance, so the lake mirrors them. A bright forced meteor low over the far shore
    /// on a moonless night (with no moon to face, the lake looks north): the brightest 1% of the water across the middle
    /// half of the view, from the keys to the far shore, is ≥ 1.5× as bright with it as without (the CPU render: 5×).
    func testMeteorsReflectInTheLake() throws {
        let m = Meteor(start: SkyLayer.enu(SkyDirection(azimuth: -14, altitude: 19)), end: SkyLayer.enu(SkyDirection(azimuth: 10, altitude: 9)),
                       born: 0, duration: 0.8, magnitude: -3)
        func shot(_ meteors: [Meteor]) throws -> (image: CGImage, renderer: MoonlitLakeRenderer) {
            try renderLake(at: 0.5, sky: Self.night, quality: .high, width: 640, height: 360) { s in
                s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
                s.meteors = meteors; s.meteorTime = 0.48; s.meteorFlash = 0
            }
        }
        let with = try shot([m]), without = try shot([])
        let water = try XCTUnwrap(with.renderer.weather.waterBand)
        let x = -0.5...0.5, y = Double(water.y + 0.02)...Double(with.renderer.horizonY - 0.01)
        let lit = FramePatch.brightest(with.image, x: x, y: y, share: 0.01), dark = FramePatch.brightest(without.image, x: x, y: y, share: 0.01)
        XCTAssertGreaterThanOrEqual(lit, 1.5 * dark, "the meteor's reflection: \(dark) → \(lit)")
    }

    /// Spec §6.4: sea smoke rises from the water band. The lake's band is its water, from the keys up to the far shore's
    /// foot. At dawn with the steam forced to 1, the frame changes inside the band (by 0.02 on average in the CPU render)
    /// and nowhere else: not above the steam's reach (`steamTop`, with 0.1 more for the bloom), nor over the keys below.
    /// The low sun ahead lights the steam gold-pink.
    func testSteamRisesFromTheWaterBand() throws {
        // Frozen skies keep the March equinox in the city's own zone: in Melbourne (AEDT) the sun rises at about 7:24,
        // so at 7:45 it stands about 4° up, low and ahead of the lake's view.
        var dawn = Self.night; dawn.frozenHour = 7.75
        func shot(_ steam: Float) throws -> (image: CGImage, renderer: MoonlitLakeRenderer) {
            try renderLake(at: 1, sky: dawn, quality: .high, width: 640, height: 360) { s in
                s.steam = steam; s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
            }
        }
        let smoke = try shot(1), still = try shot(0)
        let band = try XCTUnwrap(smoke.renderer.weather.waterBand)
        XCTAssertEqual(band.x, -1); XCTAssertEqual(band.z, 1)
        XCTAssertEqual(band.w, smoke.renderer.horizonY, accuracy: 1e-6, "up to the far shore's foot")
        XCTAssertLessThan(band.y, band.w)
        XCTAssertEqual(smoke.renderer.weather.steamCount, WeatherLayer.steamCap(.high))
        XCTAssertEqual(still.renderer.weather.steamCount, 0, "no steam in the sky, no wisps")
        XCTAssertGreaterThan(smoke.renderer.weather.steamGlow.x, 0.1, "the low sun ahead glows through it")
        let top = WeatherLayer.steamTop(band: band)
        let inside = FramePatch.difference(smoke.image, still.image, x: -1...1, y: Double(band.y)...Double(band.w))
        let above = FramePatch.difference(smoke.image, still.image, x: -1...1, y: Double(top + 0.1)...1)
        let below = FramePatch.difference(smoke.image, still.image, x: -1...1, y: -1...Double(band.y - 0.02))
        XCTAssertGreaterThan(inside, 0.005, "the band: \(inside)")
        XCTAssertLessThan(above, 0.0005, "the sky over the steam's reach: \(above)")
        XCTAssertLessThan(below, 0.0005, "the keys: \(below)")
    }
}

/// Spaceship Lounge (Set 2's world) with Galaxy Warp.
@MainActor
final class SpaceshipLoungeRendererTests: XCTestCase {
    func testLoungeShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SpaceshipLoungeShaders.source, options: nil)
        for name in ["lounge_vertex", "lounge_space_fragment", "lounge_frame_fragment", "lounge_keys_vertex", "lounge_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let warp = try device.makeLibrary(source: WarpShaders.source, options: nil)
        for name in ["warp_streak_vertex", "warp_streak_fragment", "warp_nebula_vertex", "warp_nebula_fragment"] {
            XCTAssertNotNil(warp.makeFunction(name: name), name)
        }
    }

    func testLoungeHasNoWeatherSurface() {
        if case .none = SpaceshipLoungeRenderer.weatherSurface {} else { XCTFail("the lounge is in space: no weather") }
    }

    func testLoungePreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: SpaceshipLoungeModel.id, at: [5], quality: q,
                                                     sky: MoonlitLakeRendererTests.night, mood: .dreamy).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
        // The demo's hard low note lands at 2.0 s: stars streak past the window.
        let frames = preview.render(themeID: SpaceshipLoungeModel.id, at: [1.95, 2.35], quality: .high,
                                    sky: MoonlitLakeRendererTests.night, mood: .dreamy)
        XCTAssertEqual(frames.count, 2)
        XCTAssertGreaterThan(PreviewRenderer.difference(frames[0], frames[1]), 0.005)
    }

    func testWorldsHonourGentleVisuals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        func lakeFrame() -> (LakeFrame, ParameterSet) {
            let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
            d.sky.reset(settings: MoonlitLakeRendererTests.night)
            d.handle([60, 64, 67, 72].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
            var f: LakeFrame?
            for i in 0..<90 { f = d.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? LakeFrame }   // glitter settles toward 1
            return (f!, d.parameters)
        }
        let (frame, params) = lakeFrame()
        XCTAssertGreaterThan(frame.glitter, 0.9)
        let size = CGSize(width: 640, height: 360)
        let plain = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        let gentle = try XCTUnwrap(MoonlitLakeRenderer(device: device))
        for _ in 0..<10 {
            plain.update(frame, params: params, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentle.update(frame, params: params, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plain.glitterOut, 0.5)
        XCTAssertEqual(gentle.glitterOut, plain.glitterOut * 0.5, accuracy: 1e-4, "gentle visuals halve the glints")
        XCTAssertEqual(gentle.fireflyScale, 0.5, accuracy: 1e-4)
        XCTAssertEqual(plain.fireflyScale, 1, accuracy: 1e-4)

        let ld = SceneDirector(themeID: SpaceshipLoungeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        ld.sky.reset(settings: MoonlitLakeRendererTests.night)
        ld.handle([.noteOn(note: 60, velocity: 1)], at: 0)
        let lf = try XCTUnwrap(ld.step(dt: 1.0 / 30, t: 0, quality: .high) as? LoungeFrame)
        let lounge = try XCTUnwrap(SpaceshipLoungeRenderer(device: device))
        lounge.update(lf, params: ld.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        XCTAssertEqual(lounge.streakScale, 0.5, accuracy: 1e-4, "gentle visuals halve the streaks")
        lounge.update(lf, params: ld.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
        XCTAssertEqual(lounge.streakScale, 1, accuracy: 1e-4)

        let bd = SceneDirector(themeID: GoldenHourBeachModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        bd.sky.reset(settings: MoonlitLakeRendererTests.night)
        bd.handle([60, 64, 67, 72].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
        var bf: BeachFrame?
        for i in 0..<90 { bf = bd.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? BeachFrame }
        let beachFrame = try XCTUnwrap(bf)
        let plainBeach = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let gentleBeach = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        for _ in 0..<10 {
            plainBeach.update(beachFrame, params: bd.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentleBeach.update(beachFrame, params: bd.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plainBeach.glitterOut, 0.3)
        XCTAssertLessThanOrEqual(gentleBeach.glitterOut, plainBeach.glitterOut * 0.55, "gentle visuals calm the sun's path")
        XCTAssertLessThanOrEqual(gentleBeach.sprayOut, plainBeach.sprayOut * 0.55, "and the spray glints on the foam")
        XCTAssertGreaterThan(plainBeach.sprayOut, 0.5)

        let rd = SceneDirector(themeID: CoastRoadModel.id, state: ThemeState(values: ["lamps": .number(1), "bloom": .number(1)]),
                               reaction: ReactionPresets.expressivePianist)
        rd.sky.reset(settings: MoonlitLakeRendererTests.night)
        rd.handle([60, 64, 67].map { .noteOn(note: $0, velocity: 0.9) }, at: 0)
        var rf: RoadFrame?
        for i in 0..<60 { rf = rd.step(dt: 1.0 / 30, t: Double(i) / 30, quality: .high) as? RoadFrame }
        let roadFrame = try XCTUnwrap(rf)
        XCTAssertGreaterThan(roadFrame.bloom, 0.5)
        let plainRoad = try XCTUnwrap(CoastRoadRenderer(device: device))
        let gentleRoad = try XCTUnwrap(CoastRoadRenderer(device: device))
        for _ in 0..<10 {
            plainRoad.update(roadFrame, params: rd.parameters, quality: .high, gentle: false, dt: 1.0 / 30, size: size)
            gentleRoad.update(roadFrame, params: rd.parameters, quality: .high, gentle: true, dt: 1.0 / 30, size: size)
        }
        XCTAssertGreaterThan(plainRoad.bloomOut, 0.3)
        XCTAssertGreaterThan(plainRoad.lampOut, 0.3)
        XCTAssertLessThanOrEqual(gentleRoad.bloomOut, plainRoad.bloomOut * 0.55, "gentle visuals calm the chord bloom")
        XCTAssertLessThanOrEqual(gentleRoad.lampOut, plainRoad.lampOut * 0.55, "and the lamps")
    }

    func testWarpFieldFollowsQuality() {
        XCTAssertLessThan(WarpLayer.fieldCount(.lite), WarpLayer.fieldCount(.high))
        XCTAssertLessThanOrEqual(WarpLayer.fieldCount(.lite) + GalaxyWarp.cap, 600, "Smooth stays light")
    }
}

/// Luminance helpers for comparing parts of rendered frames (NDC rectangles: x, y in −1…1, y up).
enum FramePatch {
    static func luminance(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r: Double = Double(px[i * 4]), g: Double = Double(px[i * 4 + 1]), b: Double = Double(px[i * 4 + 2])
            out[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return out
    }

    /// Mean RGB (0…1) inside an NDC rectangle.
    static func meanRGB(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> SIMD3<Double> {
        pixels(image, x: x, y: y).reduce(SIMD3<Double>(repeating: 0), +) / Double(max(1, pixels(image, x: x, y: y).count))
    }

    /// Mean luminance of the brightest `share` of the pixels inside an NDC rectangle.
    static func brightest(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>, share: Double = 0.05) -> Double {
        let l = pixels(image, x: x, y: y).map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }.sorted(by: >)
        let n = max(1, Int(Double(l.count) * share))
        return l.prefix(n).reduce(0, +) / Double(n)
    }

    static func pixels(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> [SIMD3<Double>] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [SIMD3<Double>] = []
        for row in 0..<h {
            let ny = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y.contains(ny) else { continue }
            for col in 0..<w {
                let nx = 2 * (Double(col) + 0.5) / Double(w) - 1
                guard x.contains(nx) else { continue }
                let i = (row * w + col) * 4
                out.append(SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255)
            }
        }
        return out
    }

    /// Mean absolute luminance difference between two frames inside an NDC rectangle.
    static func difference(_ a: CGImage, _ b: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let la = luminance(a), lb = luminance(b), w = a.width, h = a.height
        var sum = 0.0, n = 0
        for row in 0..<h {
            let ny = 1 - 2 * (Double(row) + 0.5) / Double(h)
            guard y.contains(ny) else { continue }
            for col in 0..<w {
                let nx = 2 * (Double(col) + 0.5) / Double(w) - 1
                guard x.contains(nx) else { continue }
                sum += abs(la[row * w + col] - lb[row * w + col]); n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }
}

/// Golden Hour Beach (Set 3's world) with Tide Lines and the shared Ocean layer.
@MainActor
final class GoldenHourBeachRendererTests: XCTestCase {
    func testBeachShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: GoldenHourBeachShaders.source, options: nil)
        for name in ["beach_vertex", "beach_fragment", "beach_keys_vertex", "beach_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    static var midday: SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.frozenPhase = 0.5; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = .clear
        return s
    }

    /// Steps the beach at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBeach(notes: [UInt8], at seconds: Double, state: ThemeState, width: Int = 640, height: Int = 360,
                             skyEdit: ((inout SkyState) -> Void)? = nil)
        throws -> (image: CGImage, renderer: GoldenHourBeachRenderer, frame: BeachFrame) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.midday)
        var frame: BeachFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 1) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: .high) as? BeachFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame { r.update(frame, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size) }
        }
        let f = try XCTUnwrap(frame)
        return (try XCTUnwrap(preview.capture(r)), r, f)
    }

    /// Steps the beach at 60 fps without notes and captures frames at the given times (seconds, ascending).
    private func beachShots(at times: [Double], state: ThemeState = ThemeState(values: ["keys.show": .bool(false)]))
        throws -> [CGImage] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
        let d = SceneDirector(themeID: GoldenHourBeachModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.midday)
        var shots: [CGImage] = []
        var pending = times
        var i = 0
        while let next = pending.first {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if let f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? BeachFrame {
                r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
            }
            if t >= next - 1e-9 { shots.append(try XCTUnwrap(preview.capture(r))); pending.removeFirst() }
        }
        return shots
    }

    func testWavesBreakWithoutAPop() throws {
        // The beach's own swell: find a break a few seconds in.
        var swell = OceanSwell(seed: 0xBEAC4)
        var breakAt = 0.0
        while breakAt < 4 { if let w = swell.step(dt: 1.0 / 60).first { breakAt = w.breakTime } }
        let frame = (breakAt * 60).rounded(.up) / 60
        let shots = try beachShots(at: [frame - 3.0 / 60, frame - 2.0 / 60, frame - 1.0 / 60, frame, frame + 1.0 / 60])
        let sea = (x: -0.5...0.5, y: -0.6...(-0.2))   // keys hidden: the horizon sits at −0.2, the surf below it
        let calm = (1...2).map { FramePatch.difference(shots[$0 - 1], shots[$0], x: sea.x, y: sea.y) }.max() ?? 0
        let across = FramePatch.difference(shots[2], shots[3], x: sea.x, y: sea.y)
        XCTAssertLessThan(across, 2.5 * calm + 0.002, "the break at \(breakAt) s: \(across) vs \(calm) frame to frame")
    }

    func testWashFollowsTheWhiteWater() {
        // The wash slides up the sand when the white water, rolling in from the break line, reaches the waterline.
        let travel = Double((GoldenHourBeachRenderer.breakLine - GoldenHourBeachRenderer.waterline) / GoldenHourBeachRenderer.boreSpeed)
        XCTAssertEqual(travel, OceanSwell.washDelay, accuracy: 0.05)
    }

    func testBeachPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [5], quality: q, sky: Self.midday).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.08, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.002, "\(q)")
        }
    }

    /// After the rain the whole beach is wet: the dry sand near the camera turns darker and mirrors the blue sky.
    func testBeachShinesAfterRain() throws {
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let dry = try renderBeach(notes: [], at: 2, state: state) { $0.wetness = 0 }
        let wet = try renderBeach(notes: [], at: 2, state: state) { $0.wetness = 0.9 }
        let x = -0.33...0.33, y = -0.97 ... -0.86
        let a = FramePatch.meanRGB(dry.image, x: x, y: y), b = FramePatch.meanRGB(wet.image, x: x, y: y)
        let la = 0.2126 * a.x + 0.7152 * a.y + 0.0722 * a.z, lb = 0.2126 * b.x + 0.7152 * b.y + 0.0722 * b.z
        XCTAssertGreaterThanOrEqual(abs(lb - la) / max(la, 1e-6), 0.08, "dry \(a) wet \(b)")
        XCTAssertGreaterThan(b.z / max(b.x, 1e-6), 1.05 * a.z / max(a.x, 1e-6), "the wet sand reflects the sky: dry \(a) wet \(b)")
    }

    func testLinesShowOnTheSand() throws {
        // Keys hidden, glitter and foam off: the lines are the only thing the notes change.
        let state = ThemeState(values: ["keys.show": .bool(false), "glitter": .number(0), "foam": .number(0)])
        let notes: [UInt8] = [36, 48, 55, 60, 64, 67, 72, 76, 84, 96]
        let played = try renderBeach(notes: notes, at: 1.5, state: state)
        let quiet = try renderBeach(notes: [], at: 1.5, state: state)
        XCTAssertGreaterThan(played.renderer.lineCount, 4)
        XCTAssertEqual(quiet.renderer.lineCount, 0)
        XCTAssertGreaterThan(PreviewRenderer.difference(played.image, quiet.image), 0.003)
    }

    func testSunAndMoonLightBlend() {
        var s = SkyState()
        s.moon = SkyDirection(azimuth: 20, altitude: 30); s.moonLit = 1
        var last: (sun: Float, moon: Float)?
        var alt = -10.0
        while alt <= 6 + 1e-9 {
            s.sun = SkyDirection(azimuth: 300, altitude: alt)
            let l = OceanLight.lights(s)
            if let last {
                XCTAssertLessThan(abs(l.sun.w - last.sun), 0.05, "sun at \(alt)°")
                XCTAssertLessThan(abs(l.moon.w - last.moon), 0.05, "moon at \(alt)°")
            }
            last = (l.sun.w, l.moon.w)
            alt += 0.1
        }
        s.sun = SkyDirection(azimuth: 300, altitude: -10)
        XCTAssertGreaterThan(OceanLight.lights(s).moon.w, 0.9, "the moon lights the sea at night")
        s.sun = SkyDirection(azimuth: 300, altitude: 6)
        XCTAssertGreaterThan(OceanLight.lights(s).sun.w, 0.9, "the sun lights it by day")
        XCTAssertLessThan(OceanLight.lights(s).moon.w, 0.01)
    }

    func testOceanStaysSmoothAfterHours() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let base = try renderBeach(notes: [], at: 2, state: state).frame
        let swell = OceanSwell(seed: 0xBEAC4)
        func at(_ t: Double) -> BeachFrame {
            var f = base
            let shift = t - base.swellTime
            f.time = t; f.swellTime = t
            f.swellPhases = swell.phases(at: t)
            f.upcoming = base.upcoming.map { var w = $0; w.breakTime += shift; return w }
            f.recent = base.recent.map { var w = $0; w.breakTime += shift; return w }
            return f
        }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let size = CGSize(width: 640, height: 360)
        func image(_ frames: [BeachFrame]) throws -> CGImage {
            let r = try XCTUnwrap(GoldenHourBeachRenderer(device: device))
            for f in frames { r.update(f, params: ThemeRegistry.parameterSet(for: GoldenHourBeachModel.id, state: state),
                                       quality: .high, gentle: false, dt: 1.0 / 60, size: size) }
            return try XCTUnwrap(preview.capture(r))
        }
        let late = 36_000.0
        let a = try image((0..<30).map { at(late - Double(30 - $0) / 60) })
        let b = try image((0..<31).map { at(late - Double(30 - $0) / 60) })
        XCTAssertLessThan(PreviewRenderer.difference(a, b), 0.01, "one frame apart, ten hours in")
        let early = try image((0..<30).map { at(60 - Double(30 - $0) / 60) })
        let ratio = PreviewRenderer.stats(a).variance / max(PreviewRenderer.stats(early).variance, 1e-9)
        XCTAssertGreaterThan(ratio, 0.5); XCTAssertLessThan(ratio, 2, "the sea keeps its detail after hours")
    }

    func testBeachFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBeach(notes: [60, 64, 67], at: 2, state: ThemeState(), width: w, height: h)
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.05, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
        }
    }
}

/// Coast Road (Set 4's world) with Coast Lights.
@MainActor
final class CoastRoadRendererTests: XCTestCase {
    func testRoadShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: CoastRoadShaders.source, options: nil)
        for name in ["road_vertex", "road_fragment", "road_lights_vertex", "road_lights_fragment", "road_frame_fragment",
                     "road_keys_vertex", "road_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
    }

    /// Steps the road at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderRoad(notes: [UInt8], at seconds: Double, state: ThemeState, sky: SkySettings? = nil,
                            width: Int = 640, height: Int = 360) throws -> (image: CGImage, renderer: CoastRoadRenderer) {
        let shots = try roadShots(notes: notes, at: [seconds], state: state, sky: sky, width: width, height: height)
        return (shots.images[0], shots.renderer)
    }

    struct RoadShot { var image: CGImage; var frame: RoadFrame; var lampPosts: [SIMD2<Float>] }

    /// Steps the road at 60 fps (notes go down at 0.5 s and stay held) and captures frames at the given times.
    private func roadShots(notes: [UInt8], at times: [Double], state: ThemeState, sky: SkySettings? = nil,
                           width: Int = 640, height: Int = 360, skyEdit: ((inout SkyState) -> Void)? = nil)
        throws -> (images: [CGImage], shots: [RoadShot], renderer: CoastRoadRenderer) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(CoastRoadRenderer(device: device))
        let d = SceneDirector(themeID: CoastRoadModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky ?? GoldenHourBeachRendererTests.midday)
        let size = CGSize(width: width, height: height)
        var shots: [RoadShot] = []
        var pending = times
        var i = 0
        while let next = pending.first {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if i == 30 { d.handle(notes.map { .noteOn(note: $0, velocity: 1) }, at: t) }
            guard var f = d.step(dt: 1.0 / 60, t: t, quality: .high) as? RoadFrame else { continue }
            skyEdit?(&f.sky)
            r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            if t >= next - 1e-9 {
                shots.append(RoadShot(image: try XCTUnwrap(preview.capture(r)), frame: f, lampPosts: r.lampPosts))
                pending.removeFirst()
            }
        }
        return (shots.map(\.image), shots, r)
    }

    func testNoRainInsideTheCar() throws {
        var rain = GoldenHourBeachRendererTests.midday; rain.weather = .rain
        let shots = try roadShots(notes: [], at: [3, 3.5], state: ThemeState(values: ["keys.show": .bool(false)]), sky: rain)
        let a = shots.images[0], b = shots.images[1]
        // The headliner above the glass and the door trim below it don't change from moment to moment.
        XCTAssertLessThan(FramePatch.difference(a, b, x: -0.99...(-0.6), y: 0.93...0.99), 0.002, "headliner")
        XCTAssertLessThan(FramePatch.difference(a, b, x: -0.9...0.9, y: -0.99...(-0.92)), 0.002, "door trim")
        XCTAssertGreaterThan(FramePatch.difference(a, b, x: -0.6...0.6, y: -0.3...0.6), 0.002, "while the view outside moves")
    }

    func testHighNotesLightLampsThatPassWithTheRoad() throws {
        let state = ThemeState(values: ["keys.show": .bool(false)])
        let run = try roadShots(notes: [84, 96], at: [1.0, 1.5], state: state)
        for shot in run.shots {
            let lamps = shot.frame.lights.filter { $0.lane == .lamp }
            XCTAssertEqual(lamps.count, 2)
            XCTAssertEqual(shot.lampPosts.count, lamps.count, "every lamp light stands on a post")
        }
        // They pass at the lamps' own pace: each moves left by the distance travelled × the lamp layer's rate.
        let moved = zip(run.shots[0].lampPosts, run.shots[1].lampPosts).map { $0.x - $1.x }
        let travelled = Float(run.shots[1].frame.distance - run.shots[0].frame.distance)
        for m in moved { XCTAssertEqual(m, travelled * CoastRoadRenderer.lampLayerRate, accuracy: 0.002) }
        XCTAssertEqual(Double(CoastRoadRenderer.lampLayerRate), 3.3 / CoastRoadRenderer.lampSpacing, accuracy: 1e-6)
    }

    func testFarSeaDoesNotFizz() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "sway": .number(0)])
        let shots = try roadShots(notes: [], at: [3, 3 + 1.0 / 60], state: state).images
        // Keys hidden: the window runs from −0.9 to 0.9 and the horizon sits 62% of the way up it.
        let horizon = -0.9 + 1.8 * 0.62
        let far = FramePatch.difference(shots[0], shots[1], x: -0.8...0.8, y: (horizon - 0.12)...(horizon - 0.02))
        let near = FramePatch.difference(shots[0], shots[1], x: -0.8...0.8, y: -0.45...(-0.3))
        XCTAssertLessThanOrEqual(far, near + 0.002, "far \(far), near \(near)")
    }

    func testRoadPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        for q in [QualityLevel.lite, .high] {
            let image = try XCTUnwrap(preview.render(themeID: CoastRoadModel.id, at: [5], quality: q,
                                                     sky: GoldenHourBeachRendererTests.midday).first)
            let s = PreviewRenderer.stats(image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(q)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(q)")
        }
    }

    /// Wet tarmac at night: the lights above the road shine back from it as streaks in the road strip.
    func testWetRoadReflectsTheLights() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "lamps": .number(1)])
        let notes: [UInt8] = [36, 40, 43, 48, 52, 55, 60, 64, 67, 72]
        let dry = try roadShots(notes: notes, at: [3], state: state, sky: MoonlitLakeRendererTests.night) { $0.wetness = 0 }
        let wet = try roadShots(notes: notes, at: [3], state: state, sky: MoonlitLakeRendererTests.night) { $0.wetness = 0.9 }
        // Keys hidden: the window's bottom is at −0.9 and the road strip runs to −0.84; the lights on the road sit
        // from −0.87 up, so the strip below them only shines by reflection.
        let x = -0.85...0.85, y = -0.895 ... -0.872
        let a = FramePatch.brightest(dry.images[0], x: x, y: y), b = FramePatch.brightest(wet.images[0], x: x, y: y)
        XCTAssertGreaterThanOrEqual(b, 1.3 * a, "dry \(a) wet \(b)")
    }

    func testLampsLightAtBlueHour() throws {
        // No notes, keys hidden: the lamps are the only change.
        func patch(lamps: Double) throws -> Double {
            let shot = try renderRoad(notes: [], at: 3, state: ThemeState(values: ["lamps": .number(lamps), "keys.show": .bool(false)]))
            return PreviewRenderer.brightestPatch(shot.image, radius: 4)
        }
        let lit = try patch(lamps: 1), dark = try patch(lamps: 0)
        XCTAssertGreaterThan(lit, 1.3 * dark, "lamps light up at blue hour")
    }

    func testCoastLightsShowWhilePlaying() throws {
        let state = ThemeState(values: ["keys.show": .bool(false), "bloom": .number(0)])
        let played = try renderRoad(notes: [36, 43, 52, 60, 64, 67, 76, 84, 91], at: 1.2, state: state)
        let quiet = try renderRoad(notes: [], at: 1.2, state: state)
        XCTAssertGreaterThan(played.renderer.lightCount, 4)
        XCTAssertEqual(quiet.renderer.lightCount, 0)
        XCTAssertGreaterThan(PreviewRenderer.difference(played.image, quiet.image), 0.002)
    }

    func testRoadFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderRoad(notes: [60, 64, 67], at: 2, state: ThemeState(), width: w, height: h)
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.03, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
        }
    }

    func testShadersSquareWithoutPow() throws {
        // pow() of a negative base is undefined under fast math (NaN on some GPUs): squares are written x * x.
        let pattern = try NSRegularExpression(pattern: #"pow\([^;]*?,\s*2\.0\)"#)
        let shared = SkyShaders.common.count + OceanShaders.common.count
        for (name, full) in [("road", CoastRoadShaders.source), ("beach", GoldenHourBeachShaders.source), ("ocean", OceanShaders.common),
                             ("sky", SkyShaders.source), ("bay", BioluminescentBayShaders.source)] {
            let source = name == "ocean" || name == "sky" ? full : String(full.dropFirst(shared))
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, name)
        }
        // The worlds built on the sky alone (their reflections call skyRadiance, with the aurora, stars and pillars).
        for (name, full) in [("lake", MoonlitLakeShaders.source), ("cabin", SnowboundCabinShaders.source),
                             ("bedroom", BedroomDawnShaders.source), ("fjord", AuroraFjordShaders.source),
                             ("teahouse", TeaHouseSnowShaders.source), ("garden", ZenRockGardenShaders.source)] {
            let source = String(full.dropFirst(SkyShaders.common.count))
            let hits = pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(hits, 0, name)
        }
        // The Underwater Kit, its probe and the porthole: no pow() at all (Beer–Lambert is exp, squares are written out).
        XCTAssertFalse(UnderwaterShaders.common.contains("pow("), "the Underwater Kit")
        XCTAssertFalse(String(UnderwaterProbe.source.dropFirst(SkyShaders.common.count)).contains("pow("), "the Underwater Kit's probe")
        for fn in ["float3 portView(", "fragment float4 port_glass_fragment(", "fragment ColorDepth port_frame_fragment("] {
            let start = try XCTUnwrap(WindowKitShaders.source.range(of: fn), fn)
            let tail = WindowKitShaders.source[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
        }
        // Any pow() in the new sky code takes a base that cannot be negative: none at all in the aurora, the real stars,
        // the pillars, iridescent cloud, the rime helpers every world calls and the shooting stars (Core computes their
        // light curves).
        for fn in ["float3 realStars(", "float3 auroraLight(", "float lightPillar(", "float fbm3c(", "float3 iridescentCloud(",
                   "bool rimeNear(", "float rimeFringe(", "void rimeKeepDeepest(", "float rimeFeather(", "float rimeEdge(",
                   "float3 rimeColor(", "float3 rimed(", "float3 meteorLight("] {
            let start = try XCTUnwrap(SkyShaders.common.range(of: fn), fn)
            let tail = SkyShaders.common[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex   // the function's closing brace (column 0)
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
        }
        // And none in the worlds' own rime code (the silhouettes that call it).
        for (source, fn) in [(MoonlitLakeShaders.source, "float3 ridgeColor("), (MoonlitLakeShaders.source, "float reeds("),
                             (SnowboundCabinShaders.source, "float pine("), (GoldenHourBeachShaders.source, "float palmTree("),
                             (TeaHouseSnowShaders.source, "float teaPine("), (TeaHouseSnowShaders.source, "float teaFence("),
                             (GoldenHourBeachShaders.source, "float shoreSilhouettes("), (CoastRoadShaders.source, "float lampPostRime(")] {
            let start = try XCTUnwrap(source.range(of: fn), fn)
            let tail = source[start.lowerBound...]
            let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex
            XCTAssertFalse(tail[..<end].contains("pow("), fn)
        }
    }

    func testLightBudgetFollowsQuality() {
        XCTAssertEqual(CoastRoadRenderer.lightBudget(.lite), 64)
        XCTAssertEqual(CoastRoadRenderer.lightBudget(.high), CoastLights.cap)
    }

    func testWeatherLayerReusesItsBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 160, height: 90))
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = 13; s.cityID = "melbourne"; s.weatherMode = .pick; s.weather = .rain
        let rain = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
            .step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
        for i in 0..<120 {
            r.update(rain, quality: .high, size: CGSize(width: 160, height: 90), dt: 1.0 / 60, time: Float(i) / 60, surface: .water(horizonY: -0.3))
            _ = preview.capture(r)
        }
        XCTAssertGreaterThan(r.weather.particleCount, 300, "heavy enough to need a buffer")
        XCTAssertLessThanOrEqual(r.weather.bufferAllocations, 4, "instance buffers are kept and grown, not made every frame")
    }
}

/// World preview frames for the CI previews branch (PREVIEW_DIR).
@MainActor
final class WorldPreviewTests: XCTestCase {
    private func sky(hour: Double, phase: Double, weather: WeatherKind = .clear) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    func testWriteLakePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, SkySettings, QualityLevel, Double)] = [
            ("lake-night-t5", sky(hour: 22, phase: 0.55), .high, 5),
            ("lake-dusk-t5", sky(hour: 19.9, phase: 0.3), .high, 5),
            ("lake-moonrise-t5", sky(hour: 20.1, phase: 0.5), .high, 5),
            ("lake-rain-t5", sky(hour: 22, phase: 0.55, weather: .rain), .high, 5),
            ("lake-smooth-t5", sky(hour: 22, phase: 0.55), .lite, 5),
            ("lake-ripples-t2.5", sky(hour: 22, phase: 0.55), .high, 2.5),
            ("lake-after-rain", sky(hour: 22, phase: 0.55, weather: .afterRain), .high, 5),
            ("lake-sea-smoke", sky(hour: 7.75, phase: 0.3, weather: .seaSmoke), .high, 5),   // the sun 4° up: steam lit gold-pink
        ]
        for (name, s, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [t], quality: q, sky: s, mood: .serene).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // A morning in rime frost's freezing fog with the world fully rimed (the sky takes 10–20 minutes to get there).
        let rime = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [5], quality: .high,
                                                sky: sky(hour: 8.5, phase: 0.55, weather: .rime), mood: .serene,
                                                skyEdit: { $0.rime = 1 }).first)
        try PreviewRenderer.writePNG(rime, to: url.appendingPathComponent("lake-rime.png"))
    }

    func testWriteBeachPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let held = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("beach-golden", sky(hour: 13, phase: 0.5), held, .high, 5),
            ("beach-blue", sky(hour: 20.5, phase: 0.5), follow, .high, 5),
            ("beach-night", sky(hour: 1, phase: 0.5), follow, .high, 5),
            ("beach-rain", sky(hour: 13, phase: 0.5, weather: .rain), held, .high, 5),
            ("beach-storm", sky(hour: 13, phase: 0.5, weather: .storm), held, .high, 5),
            ("beach-fog", sky(hour: 13, phase: 0.5, weather: .mist), held, .high, 5),
            ("beach-smooth", sky(hour: 13, phase: 0.5), held, .lite, 5),
            ("beach-lines-t6", sky(hour: 13, phase: 0.5), held, .high, 6),
            ("beach-warp-t7", sky(hour: 13, phase: 0.5), warp, .high, 7),
            ("beach-after-rain", sky(hour: 13, phase: 0.5, weather: .afterRain), held, .high, 5),
            ("beach-blizzard", sky(hour: 13, phase: 0.5, weather: .blizzard), held, .high, 5),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [t], state: state, quality: q, sky: s).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Shooting stars over the sea on a moonless night, mirrored in the water (forced: a bright green-white one with
        // a train to come, two fainter ones), placed about the way the beach faces.
        let meteors: (inout SkyState) -> Void = { s in
            s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
            let ahead = GoldenHourBeachRenderer.targetAzimuth(s)
            func at(_ az: Double, _ alt: Double) -> SIMD3<Float> { SkyLayer.enu(SkyDirection(azimuth: ahead + az, altitude: alt)) }
            s.meteors = [
                Meteor(start: at(-14, 25), end: at(8, 12), born: 9.5, duration: 0.9, magnitude: -4,
                       colour: SIMD3(0.85, 1.0, 0.9), train: 0.8),
                Meteor(start: at(22, 21), end: at(30, 14), born: 9.7, duration: 0.5, magnitude: 0.5),
                Meteor(start: at(-34, 15), end: at(-40, 9), born: 9.8, duration: 0.4, magnitude: 1.5),
            ]
            s.meteorTime = 10; s.meteorFlash = 0.03
        }
        let image = try XCTUnwrap(preview.render(themeID: GoldenHourBeachModel.id, at: [5], state: follow, quality: .high,
                                                 sky: sky(hour: 1, phase: 0.05), skyEdit: meteors).first)
        try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("beach-meteors.png"))
    }

    func testWriteRoadPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let held = ThemeState()
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("road-blue", sky(hour: 13, phase: 0.5), held, .high, 5),
            ("road-golden", sky(hour: 13, phase: 0.5), golden, .high, 5),
            ("road-night", sky(hour: 1, phase: 0.5), follow, .high, 5),
            ("road-rain", sky(hour: 13, phase: 0.5, weather: .rain), held, .high, 5),
            ("road-fog", sky(hour: 13, phase: 0.5, weather: .mist), held, .high, 5),
            ("road-smooth", sky(hour: 13, phase: 0.5), held, .lite, 5),
            ("road-lights-t6", sky(hour: 13, phase: 0.5), held, .high, 6),
            ("road-warp-t7", sky(hour: 13, phase: 0.5), warp, .high, 7),
            ("road-after-rain-night", sky(hour: 1, phase: 0.5, weather: .afterRain), follow, .high, 5),
            ("road-blizzard", sky(hour: 13, phase: 0.5, weather: .blizzard), held, .high, 5),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: CoastRoadModel.id, at: [t], state: state, quality: q, sky: s).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }

    func testWriteLoungePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, SkySettings, QualityLevel, Double)] = [
            ("lounge-t5", sky(hour: 22, phase: 0.55), .high, 5),
            ("lounge-warp-t7", sky(hour: 22, phase: 0.55), .high, 7),
            ("lounge-smooth-t5", sky(hour: 22, phase: 0.55), .lite, 5),
            ("lounge-sunrise-t5", sky(hour: 5.9, phase: 0.3), .high, 5),
            ("lounge-day-t5", sky(hour: 13, phase: 0.7), .high, 5),
        ]
        for (name, s, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: SpaceshipLoungeModel.id, at: [t], quality: q, sky: s, mood: .dreamy).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        let warpLake = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let image = try XCTUnwrap(preview.render(themeID: MoonlitLakeModel.id, at: [7], state: warpLake, quality: .high,
                                                 sky: sky(hour: 22, phase: 0.55), mood: .serene).first)
        try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("lake-warp-t7.png"))
    }
}

/// Living Sky preview frames for the CI previews branch (PREVIEW_DIR).
@MainActor
final class SkyPreviewTests: XCTestCase {
    func testWriteSkyPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let cases: [(String, Double, Double, WeatherKind, WeatherSurface)] = [
            ("sky-night-full-moon", 23.5, 0.5, .clear, .none),
            ("sky-night-crescent-milky-way", 3.0, 0.15, .clear, .none),
            ("sky-dawn", 6.6, 0.3, .lightCloud, .none),
            ("sky-golden-hour", 18.9, 0.6, .lightCloud, .none),
            ("sky-day-clouds", 12.5, 0.6, .lightCloud, .none),
            ("sky-rain-night-water", 22.0, 0.5, .rain, .water(horizonY: -0.33)),
            ("sky-snow-dusk", 19.6, 0.4, .snow, .ground(horizonY: -0.33)),
            ("sky-storm-glass", 15.0, 0.5, .storm, .glass),
            ("sky-blizzard-ground", 13.0, 0.5, .blizzard, .ground(horizonY: -0.33)),
            ("sky-after-rain-ground", 9.5, 0.5, .afterRain, .ground(horizonY: -0.33)),
            ("sky-sun-shower-rainbow", 16.6, 0.5, .sunShower, .ground(horizonY: -0.33)),
        ]
        for (name, hour, phase, weather, surface) in cases {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather
            let sky = LivingSky(settings: s, homeZone: TimeZone(identifier: "Australia/Melbourne")!)
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            var state = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0)
            for i in 0..<45 {
                state = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000 + Double(i) / 30), dt: 1.0 / 30)
                r.update(state, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: surface)
            }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Optics: halos, sundogs, a moon halo, a pastel dawn and the Belt of Venus (held or placed to show them).
        let zone = TimeZone(identifier: "Australia/Melbourne")!
        func state(hour: Double, phase: Double, weather: WeatherKind, hold: SkyHold = .follow) -> SkyState {
            var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
            s.weatherMode = .pick; s.weather = weather
            let sky = LivingSky(settings: s, homeZone: zone)
            var st = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000), dt: 0, hold: hold)
            for i in 1...120 { st = sky.step(now: Date(timeIntervalSince1970: 1_793_000_000 + Double(i)), dt: 1, hold: hold) }
            return st
        }
        var haloDay = state(hour: 13, phase: 0.5, weather: .lightCloud); haloDay.halo = 1
        var lowSun = state(hour: 13, phase: 0.5, weather: .clear); lowSun.halo = 1
        let ahead = SkyLayer.defaultViewAzimuth(latitude: lowSun.latitude)
        lowSun.sun = SkyDirection(azimuth: ahead, altitude: 8)
        let lowColours = SkyPalette.colours(sunAltitude: 8, cloud: 0, mist: lowSun.mist, moonlight: 0)
        lowSun.zenith = lowColours.zenith; lowSun.horizon = lowColours.horizon
        var moonHalo = state(hour: 23.5, phase: 0.5, weather: .lightCloud); moonHalo.halo = 1
        moonHalo.moon = SkyDirection(azimuth: ahead, altitude: 30); moonHalo.moonLit = 1
        let pastel = state(hour: 13, phase: 0.5, weather: .lightCloud, hold: .pastelDawn)
        var belt = state(hour: 13, phase: 0.5, weather: .clear)
        belt.sun = SkyDirection(azimuth: ahead + 180, altitude: -3)
        let beltColours = SkyPalette.colours(sunAltitude: -3, cloud: 0, mist: belt.mist, moonlight: 0)
        belt.zenith = beltColours.zenith; belt.horizon = beltColours.horizon; belt.starVisibility = 0.1
        let optics: [(String, SkyState, Double?)] = [
            ("sky-halo-day", haloDay, nil), ("sky-sundogs-low", lowSun, ahead), ("sky-moon-halo", moonHalo, ahead),
            ("sky-pastel-dawn", pastel, pastel.sun.azimuth), ("sky-belt-of-venus", belt, ahead),
        ]
        for (name, st, view) in optics {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            r.sky.viewAzimuth = view
            for i in 0..<10 { r.update(st, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }

        // Night-sky additions: the aurora (south from Melbourne, overhead in the north), the real stars and their lines,
        // diamond dust's pillars, a humid night's fireflies (forced states, so each shows its feature).
        var night = state(hour: 23.5, phase: 0.05, weather: .clear)
        night.sun = SkyDirection(azimuth: 0, altitude: -40); night.moon = SkyDirection(azimuth: 0, altitude: -30); night.moonLit = 0
        let nightColours = SkyPalette.colours(sunAltitude: -40, cloud: 0, mist: 0, moonlight: 0)
        night.zenith = nightColours.zenith; night.horizon = nightColours.horizon
        night.starVisibility = 1; night.cloudCover = 0; night.mist = 0; night.constellationLines = 0.35
        /// A star's east-north-up direction with the shader's basis.
        func enu(ra: Float, dec: Float, _ s: SkyState) -> SIMD3<Float> {
            let a = Double(ra) * .pi / 180, d = Double(dec) * .pi / 180
            let v = SIMD3<Float>(Float(cos(d) * cos(a)), Float(cos(d) * sin(a)), Float(sin(d)))
            let b = SkyLayer.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
            return SIMD3(simd_dot(v, b.east), simd_dot(v, b.north), simd_dot(v, b.up))
        }
        /// (view azimuth, horizon y) that centre the camera on a direction.
        func aim(_ e: SIMD3<Float>, fov: Double = 60) -> (Double, Float) {
            let alt = asin(Double(min(1, max(-1, e.z))))
            return (atan2(Double(e.x), Double(e.y)) * 180 / .pi, Float(-tan(alt) / tan(fov * .pi / 360)))
        }
        var australis = night
        australis.aurora = 0.85; australis.auroraAltitude = 14; australis.auroraStorm = 0.55; australis.hemisphere = -1
        var borealis = night
        borealis.latitude = 69.6; borealis.hemisphere = 1
        borealis.aurora = 1; borealis.auroraAltitude = 78; borealis.auroraStorm = 0.9
        let acrux = try XCTUnwrap(StarCatalogue.star(hip: 60718)), gacrux = try XCTUnwrap(StarCatalogue.star(hip: 61084))
        var crux = night
        crux.siderealDegrees = Double(acrux.ra + gacrux.ra) / 2 + 30
        let cruxDir = simd_normalize(enu(ra: acrux.ra, dec: acrux.dec, crux) + enu(ra: gacrux.ra, dec: gacrux.dec, crux))
        let betelgeuse = try XCTUnwrap(StarCatalogue.star(hip: 27989))
        var orion = night
        orion.siderealDegrees = Double(betelgeuse.ra) + 10; orion.constellationLines = 1
        let orionDir = enu(ra: betelgeuse.ra - 4, dec: betelgeuse.dec - 8, orion)
        var pillars = state(hour: 13, phase: 0.5, weather: .diamondDust)
        pillars.sun = SkyDirection(azimuth: ahead, altitude: 4)
        let pillarColours = SkyPalette.colours(sunAltitude: 4, cloud: 0.05, mist: 0.2, moonlight: 0)
        pillars.zenith = pillarColours.zenith; pillars.horizon = pillarColours.horizon
        pillars.halo = 1; pillars.diamondDust = 1; pillars.pillar = 1; pillars.starVisibility = 0
        var humid = state(hour: 23.5, phase: 0.3, weather: .humid)
        humid.fireflies = 1
        let ground = WeatherSurface.ground(horizonY: -0.33)
        let nightCases: [(String, SkyState, (Double, Float)?, WeatherSurface)] = [
            ("sky-aurora-australis", australis, (180, -0.33), .none),
            ("sky-aurora-borealis-overhead", borealis, (5, -1.6), .none),
            ("sky-real-stars-crux", crux, aim(cruxDir), .none),
            ("sky-constellation-lines", orion, aim(orionDir), .none),
            ("sky-diamond-dust-pillars", pillars, (ahead, -0.33), ground),
            ("sky-humid-fireflies", humid, nil, ground),
        ]
        for (name, st, view, surface) in nightCases {
            let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
            XCTAssertTrue(r.sky.awaitStars())
            if let view { r.sky.viewAzimuth = view.0; r.sky.horizonY = view.1 }   // a ground surface sets its own horizon
            for i in 0..<45 {
                r.update(st, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: surface)
            }
            let image = try XCTUnwrap(preview.capture(r))
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }

        // A meteor shower, forced (six at once, far more than a real one shows), radiating from a point above the view:
        // heads on their way, a green fireball in its terminal flare brightening the whole sky, a train drifting.
        var shower = night
        let radiant = SkyLayer.enu(SkyDirection(azimuth: 18, altitude: 62))
        /// A meteor from (azimuth, altitude), running `length` degrees straight away from the radiant.
        func streak(_ az: Double, _ alt: Double, length: Float, born: Double, duration: Float, magnitude: Float,
                    colour: SIMD3<Float> = SIMD3(1.0, 0.97, 0.9), train: Float = 0, flare: Bool = false) -> Meteor {
            let start = SkyLayer.enu(SkyDirection(azimuth: az, altitude: alt))
            let axis = simd_normalize(simd_cross(radiant, start)), l = length * .pi / 180
            let end = simd_normalize(start * cos(l) + simd_cross(axis, start) * sin(l))
            return Meteor(start: start, end: end, born: born, duration: duration, magnitude: magnitude, colour: colour,
                          train: train, flare: flare, radiant: radiant)
        }
        let now = 20.0
        shower.meteors = [
            streak(-22, 32, length: 18, born: now - 0.4, duration: 0.7, magnitude: -2),
            streak(34, 27, length: 12, born: now - 0.2, duration: 0.5, magnitude: 1),
            streak(4, 33, length: 24, born: now - 0.62, duration: 0.7, magnitude: -5, colour: SIMD3(0.8, 1.0, 0.9), train: 0.9,
                   flare: true),
            streak(-38, 20, length: 10, born: now - 0.1, duration: 0.3, magnitude: 0, colour: SIMD3(0.75, 1.0, 0.85)),
            streak(24, 18, length: 14, born: now - 3.4, duration: 0.6, magnitude: -3, train: 0.6),
            streak(-6, 16, length: 8, born: now - 0.25, duration: 0.4, magnitude: 2.5),
        ]
        shower.meteorTime = now; shower.meteorFlash = 0.05
        let showerSky = try XCTUnwrap(SkyOnlyRenderer(device: device))
        XCTAssertTrue(showerSky.sky.awaitStars())
        for i in 0..<10 {
            showerSky.update(shower, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: .none)
        }
        try PreviewRenderer.writePNG(try XCTUnwrap(preview.capture(showerSky)), to: url.appendingPathComponent("sky-meteor-shower.png"))

        // Iridescent cloud: a light-cloud spell's pastel bands with the sun 14° up ahead (low enough for a cap over the
        // cells), iridescence forced to 1.
        var iridescent = state(hour: 13, phase: 0.5, weather: .lightCloud)
        iridescent.sun = SkyDirection(azimuth: ahead, altitude: 14)
        let iriColours = SkyPalette.colours(sunAltitude: 14, cloud: iridescent.cloudCover, mist: iridescent.mist, moonlight: 0)
        iridescent.zenith = iriColours.zenith; iridescent.horizon = iriColours.horizon
        iridescent.iridescence = 1; iridescent.starVisibility = 0
        let r = try XCTUnwrap(SkyOnlyRenderer(device: device))
        r.sky.viewAzimuth = ahead + 12; r.sky.horizonY = -0.45
        for i in 0..<10 { r.update(iridescent, quality: .high, size: CGSize(width: 1280, height: 720), dt: 1.0 / 30, time: Float(i) / 30, surface: .none) }
        try PreviewRenderer.writePNG(try XCTUnwrap(preview.capture(r)), to: url.appendingPathComponent("sky-iridescent-cloud.png"))
    }
}

/// Snowbound Cabin Window (Set 5's world) with Frost Grow and the Window Kit.
@MainActor
final class SnowboundCabinRendererTests: XCTestCase {
    func testCabinShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: SnowboundCabinShaders.source, options: nil)
        for name in ["cabin_glass_vertex", "cabin_full_vertex", "cabin_scene_fragment", "cabin_spark_vertex", "cabin_spark_fragment",
                     "cabin_room_fragment", "cabin_keys_vertex", "cabin_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(SnowboundCabinShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct CabinShot { var image: CGImage; var renderer: SnowboundCabinRenderer; var frame: CabinFrame }

    /// Steps the cabin at 60 fps (notes go down at `noteTime` and stay held) and renders the frame at `seconds`.
    private func renderCabin(notes: [UInt8], velocity: Float = 1, noteTime: Double = 0.5, at seconds: Double,
                             state: ThemeState = ThemeState(), sky: SkySettings = SnowboundCabinRendererTests.sky(hour: 22),
                             quality: QualityLevel = .high,
                             gentle: Bool = false, width: Int = 640, height: Int = 360,
                             each: ((SnowboundCabinRenderer, CabinFrame) -> Void)? = nil) throws -> CabinShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(SnowboundCabinRenderer(device: device))
        XCTAssertTrue(r.awaitField(), "the frost field grows")
        let d = SceneDirector(themeID: SnowboundCabinModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        var frame: CabinFrame?
        let size = CGSize(width: width, height: height)
        let noteStep = Int((noteTime * 60).rounded())
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == max(1, noteStep), !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? CabinFrame
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return CabinShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    func testCabinPreviewIsStructured() throws {
        for q in [QualityLevel.lite, .high] {
            for hour in [22.0, 18.9, 13.0] {
                let shot = try renderCabin(notes: [], at: 1, sky: Self.sky(hour: hour), quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(hour)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(hour)")
            }
        }
    }

    func testFrostGrowsOnTheCabinGlass() throws {
        let held = try renderCabin(notes: [48, 52, 55, 59], velocity: 0.5, at: 30)
        let silent = try renderCabin(notes: [], at: 30)
        XCTAssertGreaterThanOrEqual(held.renderer.glass.frostCoverage - silent.renderer.glass.frostCoverage, 0.15)
        XCTAssertGreaterThan(held.frame.frostLevel, silent.frame.frostLevel)
    }

    /// The share of pixels in an NDC box whose luminance differs from the frost-free render by more than 0.05.
    private func frosted(_ a: CGImage, _ bare: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let pa = FramePatch.pixels(a, x: x, y: y), pb = FramePatch.pixels(bare, x: x, y: y)
        func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var n = 0
        for i in 0..<min(pa.count, pb.count) where abs(luma(pa[i]) - luma(pb[i])) > 0.05 { n += 1 }
        return pa.isEmpty ? 0 : Double(n) / Double(pa.count)
    }

    func testNotesMeltPatches() throws {
        // A snowy night (plenty of frost); one note held from 0.5 s melts a clear patch where its key sits.
        let night = Self.sky(hour: 22, weather: .snow)
        let shot = try renderCabin(notes: [60], velocity: 0.6, at: 5, sky: night)
        let bare = try renderCabin(notes: [60], velocity: 0.6, at: 5, state: ThemeState(values: ["frost": .number(0)]), sky: night)
        let patch = try XCTUnwrap(shot.frame.patches.first)
        let rect = shot.renderer.windowRect
        let cx = Double(rect.x + (rect.z - rect.x) * patch.x), cy = Double(rect.y + (rect.w - rect.y) * patch.y)
        let ry = Double(patch.radius * (rect.w - rect.y)), rx = ry * 360 / 640
        let inside = frosted(shot.image, bare.image, x: (cx - 0.5 * rx)...(cx + 0.5 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))
        let around = (frosted(shot.image, bare.image, x: (cx - 2.6 * rx)...(cx - 1.6 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))
                      + frosted(shot.image, bare.image, x: (cx + 1.6 * rx)...(cx + 2.6 * rx), y: (cy - 0.5 * ry)...(cy + 0.5 * ry))) / 2
        XCTAssertLessThan(inside, around - 0.2, "inside \(inside), around \(around)")
    }

    func testCabinHonoursGentleVisuals() throws {
        var plain: (flare: Float, glint: Float) = (0, 0), gentle: (flare: Float, glint: Float) = (0, 0)
        _ = try renderCabin(notes: [60, 64, 67], at: 0.8) { r, _ in plain = (max(plain.flare, r.flareOut), max(plain.glint, r.glintOut)) }
        _ = try renderCabin(notes: [60, 64, 67], at: 0.8, gentle: true) { r, _ in
            gentle = (max(gentle.flare, r.flareOut), max(gentle.glint, r.glintOut))
        }
        XCTAssertGreaterThan(plain.flare, 0.3, "a chord flares the fire")
        XCTAssertLessThanOrEqual(gentle.flare, plain.flare * 0.55)
        XCTAssertLessThanOrEqual(gentle.glint, plain.glint * 0.55)
    }

    func testNoRainInsideTheCabin() throws {
        let shot = try renderCabin(notes: [], at: 5, sky: Self.sky(hour: 22, weather: .rain))
        XCTAssertEqual(shot.frame.sky.rain, 0)
        XCTAssertGreaterThan(shot.frame.sky.snow, 0.5)
        XCTAssertEqual(shot.renderer.weather.kind, 1, "snow, never rain streaks")
        XCTAssertGreaterThan(shot.renderer.weather.particleCount, 0)
        XCTAssertGreaterThan(shot.renderer.glass.stuckFlakeCount, 0, "flakes land on the glass")
    }

    func testCabinFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderCabin(notes: [60, 64, 67], at: 1, width: w, height: h)
            let r = shot.renderer.windowRect
            let aspect = Float(w) / Float(h)
            XCTAssertGreaterThanOrEqual(r.x - 0.05, -1, "\(w)×\(h)"); XCTAssertLessThanOrEqual(r.z + 0.05, 1, "\(w)×\(h)")
            XCTAssertGreaterThanOrEqual(r.y, -1, "\(w)×\(h)"); XCTAssertLessThanOrEqual(r.w + 0.05 * aspect, 1, "\(w)×\(h)")
            XCTAssertEqual(shot.renderer.keyRects.count, 88)
            for k in shot.renderer.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
        }
    }

    func testCabinBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(SnowboundCabinRenderer(device: device))
        let d = SceneDirector(themeID: SnowboundCabinModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                if i < 60 { d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t) }
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? CabinFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.patchCount, SnowboundCabinRenderer.patchBudget(q))
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
    }

    /// Spec §6.4: steam rises only from a world's water band. A weather layer with none draws no steam however thick the
    /// sky's sea smoke, and its steam goes when the band does; given one it fills to its cap (40 / 90 / 150), every blob
    /// under `steamTop`. The cabin, under a sea-smoke sky, has no open water: it never sets a band.
    func testNoSteamWithoutAWaterBand() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let w = try XCTUnwrap(WeatherLayer(device: device))
        var s = SkyState(); s.steam = 1; s.sun = SkyDirection(azimuth: 90, altitude: 2); s.horizon = SIMD3(0.85, 0.48, 0.3)
        let size = CGSize(width: 640, height: 360)
        w.update(s, quality: .high, size: size, dt: 1.0 / 60, surface: .ground(horizonY: -0.3))
        XCTAssertNil(w.waterBand)
        XCTAssertEqual(w.steamCount, 0); XCTAssertEqual(w.steamBlobCount, 0)
        let band = SIMD4<Float>(-1, -0.8, 1, -0.3)
        w.waterBand = band
        for _ in 0..<30 { w.update(s, quality: .high, size: size, dt: 1.0 / 60, surface: .water(horizonY: -0.3)) }
        XCTAssertEqual(w.steamCount, WeatherLayer.steamCap(.high))
        XCTAssertGreaterThan(w.steamBlobCount, 0)
        let top = WeatherLayer.steamTop(band: band)
        for p in w.steamInstances { XCTAssertLessThanOrEqual(p.y + p.z, top, "a blob reaching \(p.y + p.z)") }
        w.waterBand = nil
        w.update(s, quality: .high, size: size, dt: 1.0 / 60, surface: .water(horizonY: -0.3))
        XCTAssertEqual(w.steamCount, 0, "the band gone, the steam goes")
        XCTAssertEqual([QualityLevel.lite, .high, .ultra].map { WeatherLayer.steamCap($0) }, [40, 90, 150])

        let shot = try renderCabin(notes: [], at: 0.5, sky: Self.sky(hour: 7, weather: .seaSmoke))
        XCTAssertGreaterThan(shot.frame.sky.steam, 0.9, "sea smoke in the sky")
        XCTAssertNil(shot.renderer.weather.waterBand, "the cabin has no open water")
        XCTAssertEqual(shot.renderer.weather.steamCount, 0)
    }
}

extension WorldPreviewTests {
    func testWriteCabinPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let follow = ThemeState()
        let pastel = ThemeState(values: ["light.hold": .choice(SkyHold.pastelDawn.rawValue)])
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = SnowboundCabinRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("cabin-night", sky(22, .clear, 0.5), follow, .high, 5),
            ("cabin-golden", sky(13, .clear, 0.5), golden, .high, 5),
            ("cabin-noon-halo", sky(13, .lightCloud, 0.5), follow, .high, 5),
            ("cabin-pastel-dawn", sky(13, .lightCloud, 0.5), pastel, .high, 5),
            ("cabin-blizzard", sky(15, .blizzard, 0.5), follow, .high, 5),
            ("cabin-snow", sky(21, .snow, 0.5), follow, .high, 5),
            ("cabin-smooth", sky(22, .clear, 0.5), follow, .lite, 5),
            ("cabin-frost-t30", sky(22, .clear, 0.5), follow, .high, 30),
            ("cabin-warp-t7", sky(22, .clear, 0.5), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: SnowboundCabinModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .hushedWarm).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Rime frost: the pines feathered white on their windward side (the world held fully rimed).
        let rime = try XCTUnwrap(preview.render(themeID: SnowboundCabinModel.id, at: [5], state: follow, quality: .high,
                                                sky: sky(9, .rime, 0.5), mood: .hushedWarm, skyEdit: { $0.rime = 1 }).first)
        try PreviewRenderer.writePNG(rime, to: url.appendingPathComponent("cabin-rime.png"))
    }
}

/// Bedroom Window at Dawn (Set 6's world) with Curtain Light and the Window Kit.
@MainActor
final class BedroomDawnRendererTests: XCTestCase {
    func testBedroomShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: BedroomDawnShaders.source, options: nil)
        for name in ["bed_glass_vertex", "bed_full_vertex", "bed_scene_fragment", "bed_room_fragment", "bed_shaft_fragment",
                     "bed_curtain_vertex", "bed_curtain_fragment", "bed_sprite_vertex", "bed_sprite_fragment",
                     "bed_keys_vertex", "bed_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(BedroomDawnShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct BedroomShot { var image: CGImage; var renderer: BedroomDawnRenderer; var frame: BedroomFrame }

    /// Steps the bedroom at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBedroom(notes: [UInt8], at seconds: Double, state: ThemeState = ThemeState(),
                               sky: SkySettings = BedroomDawnRendererTests.sky(hour: 13), quality: QualityLevel = .high,
                               gentle: Bool = false, width: Int = 640, height: Int = 360,
                               skyEdit: ((inout SkyState) -> Void)? = nil,
                               each: ((BedroomDawnRenderer, BedroomFrame) -> Void)? = nil) throws -> BedroomShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(BedroomDawnRenderer(device: device))
        XCTAssertTrue(r.awaitField())
        let d = SceneDirector(themeID: BedroomDawnModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        var frame: BedroomFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: 0.8) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? BedroomFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return BedroomShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    func testBedroomPreviewIsStructured() throws {
        let pastel = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        for q in [QualityLevel.lite, .high] {
            for (state, hour) in [(pastel, 13.0), (follow, 13.0), (follow, 20.3), (follow, 23.0)] {
                let shot = try renderBedroom(notes: [], at: 1, state: state, sky: Self.sky(hour: hour), quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(hour)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(hour)")
            }
        }
    }

    /// The floor below the window, in NDC.
    private func floorBox(_ r: BedroomDawnRenderer) -> (ClosedRange<Double>, ClosedRange<Double>) {
        let rect = r.windowRect
        return (Double(rect.x - 0.3)...Double(rect.z + 0.3), Double(r.floorLine - 0.16)...Double(r.floorLine - 0.02))
    }

    func testHoldingNotesBrightensTheRoom() throws {
        let held = try renderBedroom(notes: [60, 64, 67, 71], at: 4.5)
        let silent = try renderBedroom(notes: [], at: 4.5)
        let (x, y) = floorBox(held.renderer)
        let a = luma(FramePatch.meanRGB(held.image, x: x, y: y)), b = luma(FramePatch.meanRGB(silent.image, x: x, y: y))
        XCTAssertGreaterThanOrEqual(a, 1.15 * b, "held \(a), silent \(b)")
    }

    func testShaftsFallThroughThePanes() throws {
        // The same dawn with and without Morning light: the difference is the shafts (and the floor patch).
        let shot = try renderBedroom(notes: [], at: 1, state: ThemeState(values: ["light": .number(1)]))
        let dark = try renderBedroom(notes: [], at: 1, state: ThemeState(values: ["light": .number(0)]))
        XCTAssertGreaterThan(shot.renderer.shaftOut, 0.05, "the dawn sun shines in")
        XCTAssertEqual(dark.renderer.shaftOut, 0)
        let r = shot.renderer
        let pane = try XCTUnwrap(r.glassPanesNDC().min { ($0.y, -$0.x) < ($1.y, -$1.x) })   // the bottom-right pane
        let centre = SIMD2<Float>((pane.x + pane.z) / 2, (pane.y + pane.w) / 2)
        let dir = r.beamDirection
        var perp = SIMD2<Float>(-dir.y, dir.x)
        if perp.x < 0 { perp = -perp }
        let along = centre + dir * 0.25
        let side = along + perp * 0.3
        func gain(_ p: SIMD2<Float>) -> Double {
            let x = Double(p.x - 0.015)...Double(p.x + 0.015), y = Double(p.y - 0.015)...Double(p.y + 0.015)
            return luma(FramePatch.meanRGB(shot.image, x: x, y: y)) - luma(FramePatch.meanRGB(dark.image, x: x, y: y))
        }
        XCTAssertGreaterThan(gain(along), gain(side) + 0.01, "a beam below the pane, not beside it")
    }

    func testBedroomHonoursGentleVisuals() throws {
        var plain: (glint: Float, glow: Float) = (0, 0), gentle: (glint: Float, glow: Float) = (0, 0)
        _ = try renderBedroom(notes: [72, 84, 96], at: 3) { r, _ in plain = (max(plain.glint, r.glintOut), max(plain.glow, r.glowOut)) }
        _ = try renderBedroom(notes: [72, 84, 96], at: 3, gentle: true) { r, _ in gentle = (max(gentle.glint, r.glintOut), max(gentle.glow, r.glowOut)) }
        XCTAssertGreaterThan(plain.glow, 0.3)
        XCTAssertLessThanOrEqual(gentle.glint, plain.glint * 0.55)
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55)
    }

    func testStreetShinesAfterRain() throws {
        let night = BedroomDawnRendererTests.sky(hour: 22)
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let wet = try renderBedroom(notes: [], at: 1, state: follow, sky: night) { $0.wetness = 0.9 }
        let dry = try renderBedroom(notes: [], at: 1, state: follow, sky: night) { $0.wetness = 0 }
        let rect = wet.renderer.windowRect
        let h = Double(rect.w - rect.y)
        let x = Double(rect.x + 0.02)...Double(rect.z - 0.02)
        let y = (Double(rect.y) + 0.12 * h)...(Double(rect.y) + 0.3 * h)
        let pw = FramePatch.pixels(wet.image, x: x, y: y).map(luma), pd = FramePatch.pixels(dry.image, x: x, y: y).map(luma)
        func variance(_ v: [Double]) -> Double { let m = v.reduce(0, +) / Double(max(1, v.count)); return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, v.count)) }
        let mw = pw.reduce(0, +) / Double(max(1, pw.count)), md = pd.reduce(0, +) / Double(max(1, pd.count))
        XCTAssertGreaterThan(mw + variance(pw) * 10, md + variance(pd) * 10, "wet \(mw) dry \(md)")
    }

    func testBedroomFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBedroom(notes: [60, 64, 67], at: 1.5, width: w, height: h)
            let r = shot.renderer
            let aspect = Float(w) / Float(h)
            XCTAssertGreaterThanOrEqual(r.windowRect.x - 0.045, -1, "\(w)×\(h)")
            XCTAssertLessThanOrEqual(r.windowRect.z + 0.045, 1, "\(w)×\(h)")
            XCTAssertLessThanOrEqual(r.windowRect.w + 0.045 * aspect, 1, "\(w)×\(h)")
            XCTAssertEqual(r.curtainPoints.count, 2 * 24 * 32)
            for p in r.curtainPoints { XCTAssertTrue((-1...1).contains(p.x) && (-1...1).contains(p.y)) }
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            XCTAssertGreaterThan(r.shaftOut, 0.05, "\(w)×\(h): the shafts still fall")
            XCTAssertGreaterThan(r.floorLine, -1, "\(w)×\(h): the floor is in view")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.001)
        }
    }

    /// Following the sky on a summer afternoon, the sun sinking through 25° in the west doesn't swing the view round
    /// from east (final review: it turned about 170° whenever the sun crossed 25° or −12°).
    func testBedroomViewNeverSwingsRound() throws {
        var frameIndex = 0
        var azimuths: [Double] = []
        _ = try renderBedroom(notes: [], at: 4, state: ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)]),
                              skyEdit: { s in
                                  frameIndex += 1
                                  s.sun = SkyDirection(azimuth: 280, altitude: 26 - 2 * Double(frameIndex) / 240)
                              },
                              each: { r, _ in if let az = r.viewAzimuth { azimuths.append(az) } })
        let first = try XCTUnwrap(azimuths.first), last = try XCTUnwrap(azimuths.last)
        let turn = abs((last - first + 540).truncatingRemainder(dividingBy: 360) - 180)
        XCTAssertLessThan(turn, 45, "turned \(turn)°")
    }

    /// The shafts and the panes stop at the window's real bars instead of walking all 19 slots for every sample of
    /// every pixel (final review: about 133 loop steps per pixel on Smooth).
    func testBarLoopsStopAtTheBars() {
        for (name, source) in [("bedroom", BedroomDawnShaders.source), ("cabin", SnowboundCabinShaders.source)] {
            XCTAssertTrue(source.contains("if (i >= nBars) break;"), name)
        }
        XCTAssertTrue(BedroomDawnShaders.source.contains("discard_fragment();   // outside every beam"), "the shaft pass skips pixels no beam can reach")
    }

    func testBedroomBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(BedroomDawnRenderer(device: device))
        let d = SceneDirector(themeID: BedroomDawnModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 13))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? BedroomFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertEqual(r.curtainVertexCount, 2 * 24 * 32)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertLessThanOrEqual(r.bufferAllocations, 3, "curtain vertices and sprites reuse a ring of three")
    }
}

extension WorldPreviewTests {
    func testWriteBedroomPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let pastel = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let golden = ThemeState(values: ["light.hold": .choice(SkyHold.goldenHour.rawValue)])
        let frost = ThemeState(values: ["visual": .choice("Frost Grow"), "light.hold": .choice(SkyHold.follow.rawValue)])
        let open = ThemeState(values: ["window.open": .bool(true)])
        let sky = BedroomDawnRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("bedroom-pastel-dawn", sky(13, .clear, 0.5), pastel, .high, 5),
            ("bedroom-golden", sky(13, .clear, 0.5), golden, .high, 5),
            ("bedroom-noon", sky(12.5, .lightCloud, 0.5), follow, .high, 5),
            ("bedroom-night-fairy", sky(22.5, .clear, 0.5), follow, .high, 5),
            ("bedroom-after-rain", sky(8.5, .afterRain, 0.5), follow, .high, 5),
            ("bedroom-rain", sky(9, .rain, 0.5), follow, .high, 5),
            ("bedroom-snow", sky(7.5, .snow, 0.5), follow, .high, 5),
            ("bedroom-smooth", sky(13, .clear, 0.5), pastel, .lite, 5),
            ("bedroom-light-t4", sky(13, .clear, 0.5), pastel, .high, 4),
            ("bedroom-frost-t20", sky(6.5, .snow, 0.5), frost, .high, 20),
            ("bedroom-window-open", sky(13, .clear, 0.5), open, .high, 5),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: BedroomDawnModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .softWaking).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Aurora Fjord (Set 7's world) with Curtain Lights.
@MainActor
final class AuroraFjordRendererTests: XCTestCase {
    func testFjordShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: AuroraFjordShaders.source, options: nil)
        for name in ["fjord_vertex", "fjord_scene_fragment", "fjord_village_vertex", "fjord_village_fragment", "fjord_floe_vertex",
                     "fjord_floe_fragment", "fjord_rail_vertex", "fjord_rail_fragment", "fjord_keys_vertex", "fjord_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(AuroraFjordShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
    }

    /// Melbourne, frozen: a dark moon (a thin crescent set with the sun) unless asked.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.1) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct FjordShot { var image: CGImage; var renderer: AuroraFjordRenderer; var frame: FjordFrame }

    /// Steps the fjord at 60 fps in its own mood (notes go down at `noteTime` and stay held) and captures frames at the
    /// given times (seconds, ascending). The world's defaults hold Deep night with the aurora Always.
    private func fjordShots(notes: [UInt8] = [], velocity: Float = 1, noteTime: Double = 0.5, at times: [Double],
                            state: ThemeState = ThemeState(), sky: SkySettings = AuroraFjordRendererTests.sky(hour: 22),
                            quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                            skyEdit: ((inout SkyState) -> Void)? = nil) throws -> [FjordShot] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .electricAwe
        let size = CGSize(width: width, height: height)
        let noteStep = max(1, Int((noteTime * 60).rounded()))
        var shots: [FjordShot] = []
        var pending = times
        var i = 0
        while let next = pending.first, i < 60 * 120 {
            i += 1
            let t = Double(i) / 60
            elapsed = t
            if i == noteStep, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            var f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: quality) as? FjordFrame)
            skyEdit?(&f.sky)
            r.update(f, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
            if t >= next - 1e-9 {
                shots.append(FjordShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f))
                pending.removeFirst()
            }
        }
        XCTAssertEqual(shots.count, times.count)
        return shots
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    private func luma(_ image: CGImage, _ box: (x: ClosedRange<Double>, y: ClosedRange<Double>)) -> Double {
        luma(FramePatch.meanRGB(image, x: box.x, y: box.y))
    }

    /// The NDC y of an altitude (degrees) straight ahead, through the fjord's camera at this aspect.
    private func ndcY(altitude: Double, renderer r: AuroraFjordRenderer, aspect: Float = 640.0 / 360) -> Double {
        let tanV = tan(AuroraFjordRenderer.verticalFOV(aspect: aspect) * .pi / 360)
        let pitch = atan(-Double(r.horizonY) * tanV)
        return tan(altitude * .pi / 180 - pitch) / tanV
    }

    func testFjordPreviewIsStructured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        for q in [QualityLevel.lite, .high] {
            for (name, state, hour) in [("night", ThemeState(), 22.0), ("dawn", follow, 7.6), ("noon", follow, 13.0)] {
                let image = try XCTUnwrap(preview.render(themeID: AuroraFjordModel.id, at: [1], state: state, quality: q,
                                                         sky: Self.sky(hour: hour), mood: .electricAwe).first)
                let s = PreviewRenderer.stats(image)
                XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(q) \(name)")
                XCTAssertGreaterThan(s.variance, 0.002, "\(q) \(name)")
            }
        }
    }

    /// A held MIDI 60 from 1 s: a second later the curtain's foot where the ripple's right-hand front has travelled
    /// along the band is ≥ 1.25× as bright as before the note (the ripple dips the curtain's foot and brightens it); a
    /// patch far along the band stays within 10% (the held note's glow eases in). Stars and the moon are off, so the
    /// patches measure the curtain alone.
    func testNotesRippleTheCurtain() throws {
        let dark: (inout SkyState) -> Void = { s in
            s.starVisibility = 0; s.moon = SkyDirection(azimuth: 0, altitude: -30); s.moonLit = 0
        }
        let shots = try fjordShots(notes: [60], noteTime: 1, at: [59.0 / 60, 2], skyEdit: dark)
        let before = shots[0], after = shots[1]
        XCTAssertGreaterThan(after.frame.sky.aurora, 0.5, "Always, at deep night")
        XCTAssertEqual(after.renderer.rippleCount, 1)
        let ripple = try XCTUnwrap(after.frame.ripples.first)
        XCTAssertEqual(Double(ripple.age), 1, accuracy: 0.02)
        let sent = after.renderer.shaderRipples[0]
        XCTAssertEqual(sent, AuroraFjordRenderer.shaderRipple(ripple, sparkle: 1))
        let front = AuroraFjordRenderer.fronts(sent).right
        func box(_ p0: Float, _ p1: Float, _ a0: Float, _ a1: Float) throws -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
            var lo = SIMD2<Float>(repeating: 9), hi = SIMD2<Float>(repeating: -9)
            for p in [p0, (p0 + p1) / 2, p1] {
                for a in [a0, (a0 + a1) / 2, a1] {
                    let q = try XCTUnwrap(after.renderer.bandPoint(position: p, above: a))
                    lo = simd_min(lo, q); hi = simd_max(hi, q)
                }
            }
            return (Double(lo.x)...Double(hi.x), Double(lo.y)...Double(hi.y))
        }
        // The curtain's foot (4.5° under its base to 1° over it), 1.5° either side of the front.
        let near = try box(front - 1.5 / 180, front + 1.5 / 180, -4.5, 1)
        // 24–30° along the band to the left, 10–16° up the curtain: clear of both fronts and over the left wall.
        let far = try box(0.5 - 30.0 / 180, 0.5 - 24.0 / 180, 10, 16)
        let nearBefore = luma(before.image, near), nearAfter = luma(after.image, near)
        XCTAssertGreaterThanOrEqual(nearAfter, 1.25 * nearBefore, "at the ripple: \(nearBefore) → \(nearAfter)")
        let farBefore = luma(before.image, far), farAfter = luma(after.image, far)
        XCTAssertEqual(farAfter, farBefore, accuracy: 0.1 * farBefore, "far along the band: \(farBefore) → \(farAfter)")
    }

    func testFjordHonoursGentleVisuals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: Self.sky(hour: 22))
        d.mood = .electricAwe
        let plain = try XCTUnwrap(AuroraFjordRenderer(device: device)), gentle = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let size = CGSize(width: 640, height: 360)
        var glow: (plain: Float, gentle: Float) = (0, 0), ripple: (plain: Float, gentle: Float) = (0, 0)
        for i in 1...150 {
            let t = Double(i) / 60
            elapsed = t
            if i == 10 { d.handle([60, 64, 67].map { .noteOn(note: $0, velocity: 0.9) }, at: t) }
            let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: .high) as? FjordFrame)
            plain.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            gentle.update(f, params: d.parameters, quality: .high, gentle: true, dt: 1.0 / 60, size: size)
            glow = (max(glow.plain, plain.glowOut), max(glow.gentle, gentle.glowOut))
            ripple = (max(ripple.plain, plain.shaderRipples.map(\.z).max() ?? 0), max(ripple.gentle, gentle.shaderRipples.map(\.z).max() ?? 0))
        }
        XCTAssertGreaterThan(glow.plain, 0.2, "a held chord swells the curtain")
        XCTAssertLessThanOrEqual(glow.gentle, glow.plain * 0.55, "gentle visuals halve the swell")
        XCTAssertGreaterThan(ripple.plain, 0.5)
        XCTAssertLessThanOrEqual(ripple.gentle, ripple.plain * 0.55, "and the ripples")
    }

    /// Diamond dust at night: the column over a village light (2.5–6° above it) is ≥ 1.2× as bright as on a clear night.
    /// The crystals are left out (they're the weather layer's), so the column measures the pillar alone.
    func testVillageLightsPillarInDiamondDust() throws {
        let clear = try XCTUnwrap(fjordShots(at: [1.5]).last)
        let dust = try XCTUnwrap(fjordShots(at: [1.5], sky: Self.sky(hour: 22, weather: .diamondDust)) { $0.diamondDust = 0 }.last)
        XCTAssertEqual(clear.frame.sky.pillar, 0)
        XCTAssertGreaterThan(dust.frame.sky.pillar, 0.9)
        XCTAssertTrue(clear.frame.villageLit && dust.frame.villageLit)
        XCTAssertGreaterThanOrEqual(clear.renderer.villageLightCount, 6)
        XCTAssertLessThanOrEqual(clear.renderer.villageLightCount, AuroraFjordRenderer.maxVillageLights)
        XCTAssertEqual(dust.renderer.villagePoints, clear.renderer.villagePoints, "the village stays put")
        // The leftmost light: the column above it lies on the wall's face, below the skyline.
        let light = try XCTUnwrap(clear.renderer.villagePoints.min { $0.x < $1.x })
        let tanV = Float(tan(AuroraFjordRenderer.verticalFOV(aspect: 640.0 / 360) * .pi / 360))
        func above(_ degrees: Float) -> Double { Double(tan(atan(light.y * tanV) + degrees * .pi / 180) / tanV) }
        let column = (x: Double(light.x - 0.006)...Double(light.x + 0.006), y: above(2.5)...above(6))
        let a = luma(clear.image, column), b = luma(dust.image, column)
        XCTAssertGreaterThanOrEqual(b, 1.2 * a, "clear \(a), diamond dust \(b)")
    }

    /// The water below the band mirrors the aurora: ≥ 1.3× as bright with the aurora Always (at deep night) as Never.
    func testFjordReflectsTheAurora() throws {
        let always = try XCTUnwrap(fjordShots(at: [1.5], state: ThemeState(values: ["aurora.mode": .choice(AuroraMode.always.rawValue)])).last)
        let never = try XCTUnwrap(fjordShots(at: [1.5], state: ThemeState(values: ["aurora.mode": .choice(AuroraMode.never.rawValue)])).last)
        XCTAssertGreaterThan(always.frame.sky.aurora, 0.5)
        XCTAssertEqual(never.frame.sky.aurora, 0)
        // A flat mirror shows the sky as far below the horizon as it stands above it: the curtain's lowest 1–7°.
        let base = Double(AuroraFjordRenderer.framedAltitude(always.frame.sky.auroraAltitude))
        let y = ndcY(altitude: -(base + 7), renderer: always.renderer)...ndcY(altitude: -(base + 1), renderer: always.renderer)
        XCTAssertGreaterThan(y.lowerBound, -0.76, "above the keys")
        let water = (x: -0.12...0.12, y: y)
        let a = luma(always.image, water), b = luma(never.image, water)
        XCTAssertGreaterThanOrEqual(a, 1.3 * b, "aurora \(a), none \(b)")
    }

    func testFjordFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try XCTUnwrap(fjordShots(notes: [60, 64, 67], at: [1.5], width: w, height: h).last)
            let r = shot.renderer
            XCTAssertGreaterThan(r.horizonY, -1, "\(w)×\(h)"); XCTAssertLessThan(r.horizonY, 1, "\(w)×\(h)")
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
                XCTAssertLessThan(k.w, r.horizonY, "the keys sit below the horizon")
            }
            XCTAssertGreaterThanOrEqual(r.villageLightCount, 6, "\(w)×\(h)")
            for p in r.villagePoints { XCTAssertTrue((-1...1).contains(p.x) && (-1...1).contains(p.y), "\(w)×\(h) village \(p)") }
            XCTAssertEqual(r.jettyPosts.count, 2, "\(w)×\(h)")
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            for p in r.jettyPosts {
                XCTAssertTrue((-1...1).contains(p.x) && p.y > keyTop && p.y < r.horizonY, "\(w)×\(h) jetty \(p)")
            }
            let s = PreviewRenderer.stats(shot.image)
            XCTAssertGreaterThan(s.meanLuminance, 0.02, "\(w)×\(h)")
            XCTAssertGreaterThan(s.variance, 0.001, "\(w)×\(h)")
        }
    }

    /// 2,000 notes in a second: never more than 8 ripples on the curtain, and 60 frames update and render in under 4 s.
    func testFjordBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(AuroraFjordRenderer(device: device))
        let d = SceneDirector(themeID: AuroraFjordModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? FjordFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(f.ripples.count, CurtainLights.cap)
                XCTAssertLessThanOrEqual(r.rippleCount, SkyLayer.rippleCount)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.rippleCount, 0)
        XCTAssertEqual(r.floeCount, AuroraFjordModel.floeCount(0.6))
    }

    /// Every village light's quad holds its whole reflection: from the light past the horizon to its mirror point (the
    /// light's height plus the eye's below the horizon) and on by 5 × the streak's length (the shader's `len`), where the
    /// streak has faded to e^−5. A calm, clear night with Village lights at 1, so all ten are lit, the 130 m one too.
    func testVillageReflectionsAreWhole() throws {
        let state = ThemeState(values: ["village": .number(1), "swell": .number(0.4)])
        let shot = try XCTUnwrap(fjordShots(at: [1.5], state: state) { $0.wind = 0 }.last)
        let r = shot.renderer
        XCTAssertEqual(shot.frame.sky.pillar, 0, "no diamond dust: the quads end at the reflections")
        XCTAssertEqual(r.villageRects.count, AuroraFjordRenderer.maxVillageLights)
        let tanV = Float(tan(AuroraFjordRenderer.verticalFOV(aspect: 640.0 / 360) * .pi / 360))
        let pitch: Float = -atan(r.horizonY * tanV)
        let streak: Float = 0.006 + 0.02 * 0.4   // the shader's len: no wind, swell 0.4
        for (i, l) in AuroraFjordRenderer.villageLayout.enumerated() {
            let distance = AuroraFjordRenderer.wallDistance(l.phi) * 1.03
            let end = -(atan((l.height + AuroraFjordRenderer.eyeHeight) / distance) + 5 * streak)
            // Where (φ, end) lands on screen: the view's frame is level ahead and across, pitched up by `pitch`.
            let flat: Float = cos(end) * cos(l.phi)
            let up: Float = sin(end) * cos(pitch) - flat * sin(pitch)
            let ahead: Float = flat * cos(pitch) + sin(end) * sin(pitch)
            let y = up / (ahead * tanV)
            XCTAssertLessThanOrEqual(r.villageRects[i].y, max(y, -1.05) + 1e-4,
                                     "light \(i) (\(l.height) m): its quad stops at \(r.villageRects[i].y), its reflection runs to \(y)")
        }
    }

    /// Long sessions: the shader's clock is the world's wrapped to the hour (so its floats stay fine), and the wrap
    /// doesn't show: across it the water changes no more than between two ordinary frames (noon, so the cat's paws and
    /// glints move bright reflections).
    func testFjordClockWrapsWithoutAJump() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue), "swell": .number(0)])
        let base = try XCTUnwrap(fjordShots(at: [0.5], state: follow, sky: Self.sky(hour: 13)) { $0.wind = 0.6 }.last).frame
        let params = ThemeRegistry.parameterSet(for: AuroraFjordModel.id, state: follow)
        let size = CGSize(width: 640, height: 360)
        // Two frames 1/60 s apart, the second at `t`; returns the water's change between them and the shader's clock.
        func step(to t: Double) throws -> (change: Double, clock: Float) {
            let r = try XCTUnwrap(AuroraFjordRenderer(device: device))
            var f = base
            f.time = t - 1.0 / 60
            r.update(f, params: params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            let a = try XCTUnwrap(preview.capture(r))
            f.time = t
            r.update(f, params: params, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            let b = try XCTUnwrap(preview.capture(r))
            let keyTop = Double(r.keyRects.map(\.w).max() ?? -1)
            let water: ClosedRange<Double> = (keyTop + 0.02)...(Double(r.horizonY) - 0.02)
            return (FramePatch.difference(a, b, x: -1...1, y: water), r.uniforms[0].y)
        }
        let day = try step(to: 86_400.5)
        XCTAssertEqual(day.clock, 0.5, accuracy: 1e-3, "a day in, the shader's clock reads half a second into the hour")
        let ordinary = try step(to: 1_800), wrap = try step(to: AuroraFjordRenderer.clockWrap)
        XCTAssertLessThan(wrap.clock, 1e-3, "it wraps on the hour")
        XCTAssertLessThanOrEqual(wrap.change, 2 * ordinary.change + 0.002,
                                 "the water across the wrap \(wrap.change) against an ordinary frame \(ordinary.change)")
    }
}

extension WorldPreviewTests {
    func testWriteFjordPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let night = ThemeState()
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = AuroraFjordRendererTests.sky
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("fjord-night-aurora", sky(22, .clear, 0.1), night, .high, 5),
            ("fjord-dawn", sky(7.6, .clear, 0.1), follow, .high, 5),
            ("fjord-noon", sky(13, .clear, 0.1), follow, .high, 5),
            ("fjord-diamond-dust", sky(22, .diamondDust, 0.1), night, .high, 5),
            ("fjord-blizzard", sky(13, .blizzard, 0.1), follow, .high, 5),
            ("fjord-smooth", sky(22, .clear, 0.1), night, .lite, 5),
            ("fjord-ripples-t2", sky(22, .clear, 0.1), night, .high, 2),
            ("fjord-warp-t7", sky(22, .clear, 0.1), warp, .high, 7),
            ("fjord-sea-smoke", sky(22, .seaSmoke, 0.5), night, .high, 5),   // steam off the fjord, moonlit blue-grey
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: AuroraFjordModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .electricAwe).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Bioluminescent Bay (Set 8's world) with Glow Wake.
@MainActor
final class BioluminescentBayRendererTests: XCTestCase {
    func testBayShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: BioluminescentBayShaders.source, options: nil)
        for name in ["bay_vertex", "bay_fragment", "bay_keys_vertex", "bay_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(BioluminescentBayShaders.source.dropFirst(SkyShaders.common.count + OceanShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        // The Swift uniform arrays match the MSL structs byte for byte (the pipeline's own reflection says so).
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "bay_vertex")
        d.fragmentFunction = lib.makeFunction(name: "bay_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        func size(_ index: Int) -> Int? { buffers.first { $0.index == index }?.bufferDataSize }
        let row = MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(size(0), SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(size(1), BioluminescentBayRenderer.uniformCount * row, "BayU")
        XCTAssertEqual(size(2), 7 * row, "OceanU")
        XCTAssertEqual(BioluminescentBayRenderer.wakeBase, BioluminescentBayRenderer.patchBase + GlowWake.cap)
        XCTAssertEqual(BioluminescentBayRenderer.dartBase, BioluminescentBayRenderer.wakeBBase + GlowWake.wakeCap)
        XCTAssertEqual(BioluminescentBayRenderer.uniformCount, BioluminescentBayRenderer.dartBBase + GlowWake.dartCap)
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, BioluminescentBayRenderer.uniformCount)
        XCTAssertEqual(r.oceanUniforms.count, 7)
    }

    /// Frozen Melbourne skies (the world holds Deep night unless a test follows the sky); a thin moon by default.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.1) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct BayShot { var image: CGImage; var renderer: BioluminescentBayRenderer; var frame: BayFrame }

    /// Steps the bay at 60 fps (notes go down at 0.5 s and stay held) and renders the frame at `seconds`.
    private func renderBay(notes: [UInt8], velocity: Float = 1, at seconds: Double, state: ThemeState = ThemeState(),
                           sky: SkySettings = BioluminescentBayRendererTests.sky(hour: 22), quality: QualityLevel = .high,
                           gentle: Bool = false, width: Int = 640, height: Int = 360,
                           skyEdit: ((inout SkyState) -> Void)? = nil,
                           each: ((BioluminescentBayRenderer, BayFrame) -> Void)? = nil) throws -> BayShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .secretGlow
        var frame: BayFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? BayFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return BayShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The median luminance inside an NDC rectangle (a reflected star in it can't move it).
    private func medianLuma(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
        let l = FramePatch.pixels(image, x: x, y: y).map(luma).sorted()
        return l.isEmpty ? 0 : l[l.count / 2]
    }

    private struct LightCase { let name: String; let state: ThemeState; let sky: SkySettings; let mean: Double; let variance: Double }

    func testBayPreviewIsStructured() throws {
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let cases = [
            LightCase(name: "night", state: ThemeState(), sky: Self.sky(hour: 22), mean: 0.012, variance: 0.0008),
            LightCase(name: "dawn", state: follow, sky: Self.sky(hour: 7.1, phase: 0.3), mean: 0.05, variance: 0.002),
            LightCase(name: "noon", state: follow, sky: Self.sky(hour: 13, phase: 0.5), mean: 0.2, variance: 0.004),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try renderBay(notes: [60, 64, 67], at: 1.5, state: c.state, sky: c.sky, quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(shot.renderer.patchCount, 3, "\(q) \(c.name): the notes land in any light")
                if c.name == "night" {
                    XCTAssertGreaterThan(shot.renderer.glowOut, 0.5, "\(q): the plankton glows in the dark")
                    XCTAssertGreaterThan(shot.renderer.lanternOut, 0.4, "\(q): the lantern is lit")
                }
                if c.name == "noon" {
                    XCTAssertEqual(shot.renderer.glowOut, 0, "\(q): no glow by day")
                    XCTAssertEqual(shot.renderer.lanternOut, 0, "\(q): the lantern is out by day")
                    XCTAssertEqual(shot.renderer.lighthouseOut, 0, "\(q): nor the lighthouse")
                }
            }
        }
    }

    /// A held note at night lights its patch of water: the patch is far brighter than the water beside it.
    func testNotesLightTheWater() throws {
        let quiet = ThemeState(values: ["lantern": .number(0), "lighthouse": .number(0)])
        let shot = try renderBay(notes: [60], at: 1.5, state: quiet)
        let patch = try XCTUnwrap(shot.frame.patches.first)
        XCTAssertGreaterThan(patch.brightness, 0.5, "lit in the dark")
        XCTAssertEqual(shot.renderer.patchCount, 1)
        let box = try XCTUnwrap(shot.renderer.screenBox(of: patch))
        let cx = Double(box.centre.x), cy = Double(box.centre.y), hx = Double(box.half.x), hy = Double(box.half.y)
        XCTAssertLessThan(cy, Double(shot.renderer.horizonY), "on the water")
        XCTAssertGreaterThan(cy, Double(shot.renderer.waterlineY), "beyond the waterline")
        let y = (cy - 0.6 * hy)...(cy + 0.6 * hy)
        let inside = luma(FramePatch.meanRGB(shot.image, x: (cx - 0.4 * hx)...(cx + 0.4 * hx), y: y))
        let beside = max(medianLuma(shot.image, x: (cx - 3.4 * hx)...(cx - 2.6 * hx), y: y),
                         medianLuma(shot.image, x: (cx + 2.6 * hx)...(cx + 3.4 * hx), y: y))
        XCTAssertGreaterThanOrEqual(inside, 1.4 * beside, "patch \(inside), beside \(beside)")
    }

    /// The still bay mirrors the real stars: at 17:00 the Pointers and Crux stand low over the bay's mouth, and the same
    /// night with the star texture swapped for an empty one (still bound, so the procedural field is the same faint
    /// background in both) holds far fainter points on the water (clear, no moon; glow, lantern, lighthouse, keys off).
    func testBayMirrorsTheRealStars() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let blank = [UInt8](repeating: 0, count: StarTexture.width * StarTexture.height * 4)
        let empty = try XCTUnwrap(StarTextureCache.makeTexture(device: device, bytes: blank))
        let still = ThemeState(values: ["glow": .number(0), "lantern": .number(0), "lighthouse": .number(0), "keys.show": .bool(false)])
        func water(_ texture: MTLTexture?) throws -> (bright: Double, mean: Double) {
            let shot = try renderBay(notes: [], at: 1, state: still, sky: Self.sky(hour: 17, phase: 0),
                                     each: { r, _ in r.sky.starTextureOverride = texture })
            XCTAssertNotNil(shot.renderer.sky.starTexture, "a star texture is bound")
            let r = shot.renderer
            let x = -0.7...0.7, y = Double(r.waterlineY + 0.05)...Double(r.horizonY - 0.03)
            return (bright: FramePatch.brightest(shot.image, x: x, y: y, share: 0.001),
                    mean: luma(FramePatch.meanRGB(shot.image, x: x, y: y)))
        }
        let real = try water(nil)
        XCTAssertNotNil(StarTextureCache.shared.texture, "the real stars are built (the preview waits for them)")
        let none = try water(empty)
        XCTAssertGreaterThanOrEqual(real.bright, 1.15 * none.bright, "reflected real stars: \(none.bright) → \(real.bright)")
        XCTAssertGreaterThan(real.mean, none.mean, "the mirror carries their light")
    }

    /// The bay frames the aurora low over its mouth, as the fjord does: forced on with its base anywhere from 25° (the
    /// lowest "Always") to overhead, it stands in the bay's sky, which is far brighter than the same night without it.
    func testBayShowsTheAuroraAtAnyHeight() throws {
        let still = ThemeState(values: ["glow": .number(0), "lantern": .number(0), "lighthouse": .number(0), "keys.show": .bool(false)])
        func skyLight(_ aurora: Float, base: Float) throws -> Double {
            let shot = try renderBay(notes: [], at: 0.5, state: still, sky: Self.sky(hour: 22, phase: 0),
                                     skyEdit: { s in s.aurora = aurora; s.auroraAltitude = base; s.auroraStorm = 0 })
            return luma(FramePatch.meanRGB(shot.image, x: -1...1, y: Double(shot.renderer.horizonY + 0.02)...1))
        }
        let off = try skyLight(0, base: 42.5)
        for base: Float in [25, 42.5, 60, 90] {
            let on = try skyLight(1, base: base)
            XCTAssertGreaterThanOrEqual(on, 1.3 * off, "base \(base)°: the bay's sky \(off) → \(on)")
        }
    }

    func testBayHonoursGentleVisuals() throws {
        var plain: (glow: Float, flash: Float) = (glow: 0, flash: 0), gentle: (glow: Float, flash: Float) = (glow: 0, flash: 0)
        _ = try renderBay(notes: [60, 64, 67], at: 1, each: { r, _ in
            plain = (glow: max(plain.glow, r.glowOut), flash: max(plain.flash, r.lighthouseOut))
        })
        _ = try renderBay(notes: [60, 64, 67], at: 1, gentle: true, each: { r, _ in
            gentle = (glow: max(gentle.glow, r.glowOut), flash: max(gentle.flash, r.lighthouseOut))
        })
        XCTAssertGreaterThan(plain.glow, 0.3, "the plankton glows at night")
        XCTAssertGreaterThan(plain.flash, 0.2, "the lighthouse flashes in the first second")
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55, "gentle visuals calm the glow")
        XCTAssertLessThanOrEqual(gentle.flash, plain.flash * 0.55, "and the lighthouse")
    }

    func testFirefliesOnTheHeadlandsOnHumidNights() throws {
        let humid = try renderBay(notes: [], at: 1, sky: Self.sky(hour: 22, weather: .humid))
        XCTAssertGreaterThan(humid.frame.sky.fireflies, 0.5, "a humid night")
        XCTAssertGreaterThan(humid.renderer.weather.fireflyCount, 0, "fireflies over the shore")
        let clear = try renderBay(notes: [], at: 1)
        XCTAssertEqual(clear.renderer.weather.fireflyCount, 0, "none on a clear night")
    }

    func testBayFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderBay(notes: [21, 60, 64, 67, 108], at: 1.5, width: w, height: h)
            let r = shot.renderer
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            XCTAssertTrue(r.waterlineY > keyTop && r.waterlineY < r.horizonY && r.horizonY < 1, "\(w)×\(h): sand, water, sky in order")
            for (name, p) in [("lantern", r.lanternScreen), ("lighthouse", r.lighthouseScreen)] {
                XCTAssertTrue(abs(p.x) < 0.95 && p.y > r.waterlineY && p.y < 0.95, "\(w)×\(h): the \(name) at \(p)")
            }
            XCTAssertEqual(r.patchCount, 5)
            for patch in shot.frame.patches {
                let box = try XCTUnwrap(r.screenBox(of: patch))
                XCTAssertTrue(abs(box.centre.x) + box.half.x < 1, "\(w)×\(h): note \(patch.note)'s glow is in view")
            }
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.0008, "\(w)×\(h)")
        }
    }

    func testBayBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(BioluminescentBayRenderer(device: device))
        let d = SceneDirector(themeID: BioluminescentBayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? BayFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.patchCount, BioluminescentBayRenderer.patchBudget(q))
                XCTAssertLessThanOrEqual(r.patchCount, GlowWake.cap)
                XCTAssertLessThanOrEqual(r.wakeCount, BioluminescentBayRenderer.wakeBudget(q))
                XCTAssertLessThanOrEqual(r.dartCount, BioluminescentBayRenderer.dartBudget(q))
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.patchCount, 0)
    }
}

extension WorldPreviewTests {
    func testWriteBayPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let night = ThemeState()   // the world's default: held at Deep night
        let follow = ThemeState(values: ["light.hold": .choice(SkyHold.follow.rawValue)])
        let warp = ThemeState(values: ["visual": .choice("Galaxy Warp")])
        let sky = BioluminescentBayRendererTests.sky
        // At 17:00 on the frozen date the star clock puts Crux 12–17° up over the left headland and the Pointers over
        // the bay's mouth (the light is held at Deep night).
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("bay-night", sky(17, .clear, 0.1), night, .high, 5),
            ("bay-night-glow-t3", sky(17, .clear, 0.1), night, .high, 3),
            ("bay-humid-fireflies", sky(17, .humid, 0.1), night, .high, 5),
            ("bay-dawn", sky(7.1, .clear, 0.3), follow, .high, 5),
            ("bay-noon", sky(13, .clear, 0.5), follow, .high, 5),
            ("bay-rain", sky(17, .rain, 0.1), night, .high, 5),
            ("bay-smooth", sky(17, .clear, 0.1), night, .lite, 5),
            ("bay-warp-t7", sky(17, .clear, 0.1), warp, .high, 7),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: BioluminescentBayModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .secretGlow).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
    }
}

/// Tea House Snow (Set 9's world) with Steam Lines, the paper screens and Frost Grow on them.
@MainActor
final class TeaHouseSnowRendererTests: XCTestCase {
    func testTeaHouseShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: TeaHouseSnowShaders.source, options: nil)
        for name in ["tea_full_vertex", "tea_rect_vertex", "tea_garden_fragment", "tea_paper_fragment", "tea_room_fragment",
                     "tea_steam_fragment", "tea_keys_vertex", "tea_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(TeaHouseSnowShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        // The Swift uniform array matches the MSL struct byte for byte (the pipeline's own reflection says so).
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "tea_full_vertex")
        d.fragmentFunction = lib.makeFunction(name: "tea_room_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let buffers = (reflection?.fragmentBindings ?? []).compactMap { $0 as? MTLBufferBinding }
        func size(_ index: Int) -> Int? { buffers.first { $0.index == index }?.bufferDataSize }
        let row = MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(size(0), SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(size(1), TeaHouseSnowRenderer.uniformCount * row, "TeaU")
        XCTAssertEqual(TeaHouseSnowRenderer.barBase, TeaHouseSnowRenderer.pathBase + 3)
        XCTAssertEqual(TeaHouseSnowRenderer.wispBase, TeaHouseSnowRenderer.barBase + TeaHouseSnowRenderer.maxBars)
        XCTAssertEqual(TeaHouseSnowRenderer.wispBBase, TeaHouseSnowRenderer.wispBase + SteamLines.cap)
        XCTAssertEqual(TeaHouseSnowRenderer.uniformCount, TeaHouseSnowRenderer.wispBBase + SteamLines.cap)
        let r = try XCTUnwrap(TeaHouseSnowRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, TeaHouseSnowRenderer.uniformCount)
        // The panels are the Window Kit's paper screens, and their kumiko fit the uniform block.
        let panels = TeaHouseSnowRenderer.panels(TeaHouseSnowRenderer.roomLayout(aspect: 16.0 / 9, keyTop: -0.76), open: 0.5)
        XCTAssertEqual(panels.map(\.material), [.paperScreen, .paperScreen])
        XCTAssertLessThanOrEqual(panels[0].bars().count, TeaHouseSnowRenderer.maxBars)
    }

    /// Frozen Melbourne skies (26 October 2026 on the preview clock).
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.5) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct TeaShot { var image: CGImage; var renderer: TeaHouseSnowRenderer; var frame: TeaHouseFrame }

    /// Steps the tea house at 60 fps (notes go down at `noteTime` and stay held) and renders the frame at `seconds`.
    private func renderTea(notes: [UInt8], velocity: Float = 0.9, noteTime: Double = 0.5, at seconds: Double,
                           state: ThemeState = ThemeState(), sky: SkySettings = TeaHouseSnowRendererTests.sky(hour: 13),
                           quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                           field: Bool = false, skyEdit: ((inout SkyState) -> Void)? = nil,
                           each: ((TeaHouseSnowRenderer, TeaHouseFrame) -> Void)? = nil) throws -> TeaShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(TeaHouseSnowRenderer(device: device))
        if field { XCTAssertTrue(r.awaitField(), "the paper's frost fields grow") }
        let d = SceneDirector(themeID: TeaHouseSnowModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .delicate
        var frame: TeaHouseFrame?
        let size = CGSize(width: width, height: height)
        let noteStep = Int((noteTime * 60).rounded())
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == max(1, noteStep), !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? TeaHouseFrame
            if let edit = skyEdit, frame != nil { edit(&frame!.sky) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return TeaShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private struct LightCase { let name: String; let state: ThemeState; let sky: SkySettings; let mean: Double; let variance: Double }

    /// Dawn (held at a pastel dawn), noon, dusk and night, on Smooth and High: lit, structured frames; the lantern's
    /// candle and the brazier light the night, the candle is out by day, and the paper glows with the day's light.
    func testTeaHousePreviewIsStructured() throws {
        let pastel = ThemeState(values: ["light.hold": .choice(SkyHold.pastelDawn.rawValue)])
        // The CPU reference of these frames measured mean / variance: dawn 0.24 / 0.047, noon 0.36 / 0.069,
        // dusk 0.13 / 0.017, night 0.10 / 0.0075 (thresholds about half that).
        let cases = [
            LightCase(name: "dawn", state: pastel, sky: Self.sky(hour: 6.5, weather: .lightCloud), mean: 0.12, variance: 0.015),
            LightCase(name: "noon", state: ThemeState(), sky: Self.sky(hour: 13), mean: 0.18, variance: 0.025),
            LightCase(name: "dusk", state: ThemeState(), sky: Self.sky(hour: 20.2), mean: 0.06, variance: 0.006),
            LightCase(name: "night", state: ThemeState(), sky: Self.sky(hour: 22, phase: 0.25), mean: 0.045, variance: 0.0035),
        ]
        for q in [QualityLevel.lite, .high] {
            var paper: [String: Float] = [:]
            for c in cases {
                let shot = try renderTea(notes: [60, 64, 67], at: 1, state: c.state, sky: c.sky, quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertTrue(shot.renderer.drawsGarden, "\(q) \(c.name): the screens stand half open on the garden")
                XCTAssertGreaterThan(shot.renderer.wispCount, 0, "\(q) \(c.name): the notes curl the steam")
                paper[c.name] = simd_reduce_add(shot.renderer.paperGlow) / 3
                if c.name == "night" || c.name == "dusk" {
                    XCTAssertGreaterThan(shot.renderer.candleOut, 0.5, "\(q) \(c.name): the lantern's candle is lit")
                }
                if c.name == "night" { XCTAssertGreaterThan(shot.renderer.fireOut, 0.5, "\(q): the brazier lights the room") }
                if c.name == "noon" { XCTAssertEqual(shot.renderer.candleOut, 0, "\(q): no candle by day") }
            }
            XCTAssertGreaterThan(paper["noon"] ?? 0, 5 * (paper["night"] ?? 1), "\(q): the paper glows by day, blue-grey at night")
        }
    }

    /// A note sends a wisp curling off the steam (and, held, brightens it): the steam's patch above the bowl changes by
    /// at least 10% (night: the room's dark behind it; the CPU reference measured 74%, and 11% at noon).
    func testNotesSendWispsOffTheSteam() throws {
        let night = Self.sky(hour: 22, phase: 0.25)
        let quiet = try renderTea(notes: [], at: 1.2, sky: night)
        let played = try renderTea(notes: [64], at: 1.2, sky: night)
        XCTAssertEqual(quiet.renderer.wispCount, 0)
        XCTAssertEqual(played.renderer.wispCount, 1, "one note, one wisp")
        XCTAssertGreaterThan(played.renderer.glowOut, 0.2, "the held note brightens the steam")
        let r = played.renderer.steamRect
        let x = Double(r.x)...Double(r.z), y = Double(r.y)...Double(r.w)
        let base = luma(FramePatch.meanRGB(quiet.image, x: x, y: y))
        let change = FramePatch.difference(quiet.image, played.image, x: x, y: y)
        XCTAssertGreaterThanOrEqual(change, 0.1 * base, "steam patch \(base) changed by \(change)")
    }

    /// Screens closed: no garden, sky or snow beyond them; the paper fills the span (where the opening was, the light is
    /// the paper's, not the sky's), and it lights the room.
    func testScreensClosedLightTheRoomWithPaper() throws {
        let closed = try renderTea(notes: [], at: 1, state: ThemeState(values: ["screens": .number(0)]))
        let open = try renderTea(notes: [], at: 1, state: ThemeState(values: ["screens": .number(0.7)]))
        XCTAssertFalse(closed.renderer.drawsGarden, "nothing is drawn beyond closed screens")
        XCTAssertTrue(open.renderer.drawsGarden)
        XCTAssertEqual(closed.renderer.openingRect.z - closed.renderer.openingRect.x, 0, accuracy: 1e-6)
        let panels = closed.renderer.panelSpecs
        XCTAssertEqual(panels[0].rect.z + panels[0].frameWidth, panels[1].rect.x - panels[1].frameWidth, accuracy: 1e-5,
                       "the panels meet in the middle")
        // Where the opening would be, the closed screens show paper like the side panel's; open, the sky shows there.
        let centre = (x: 0.30...0.50, y: 0.10...0.55), side = (x: -0.50 ... -0.33, y: 0.10...0.55)
        func rgb(_ s: TeaShot, _ b: (x: ClosedRange<Double>, y: ClosedRange<Double>)) -> SIMD3<Double> { FramePatch.meanRGB(s.image, x: b.x, y: b.y) }
        let cc = rgb(closed, centre), cs = rgb(closed, side), oc = rgb(open, centre), os = rgb(open, side)
        XCTAssertLessThan(simd_reduce_max(simd_abs(cc - cs)), 0.04, "closed: paper all across (\(cc) vs \(cs))")
        XCTAssertGreaterThan(luma(cc), 0.4, "the paper glows by day")
        XCTAssertGreaterThan((oc.z - oc.x) - (os.z - os.x), 0.05, "open: the blue sky beyond (\(oc) vs \(os))")
        // And the paper lights the room: the tatami in front of it glows.
        XCTAssertGreaterThan(luma(FramePatch.meanRGB(closed.image, x: -0.3...0.3, y: -0.58 ... -0.40)), 0.08)
    }

    func testTeaHouseHonoursGentleVisuals() throws {
        var plain: (glow: Float, puff: Float, wisp: Float) = (0, 0, 0), gentle: (glow: Float, puff: Float, wisp: Float) = (0, 0, 0)
        func brightestWisp(_ r: TeaHouseSnowRenderer) -> Float {
            (0..<SteamLines.cap).map { r.uniforms[TeaHouseSnowRenderer.wispBase + $0].w }.max() ?? 0
        }
        _ = try renderTea(notes: [60, 64, 67], at: 1, each: { r, _ in
            plain = (max(plain.glow, r.glowOut), max(plain.puff, r.puffOut), max(plain.wisp, brightestWisp(r)))
        })
        _ = try renderTea(notes: [60, 64, 67], at: 1, gentle: true, each: { r, _ in
            gentle = (max(gentle.glow, r.glowOut), max(gentle.puff, r.puffOut), max(gentle.wisp, brightestWisp(r)))
        })
        XCTAssertGreaterThan(plain.glow, 0.3, "held notes brighten the steam")
        XCTAssertGreaterThan(plain.puff, 0.3, "a chord puffs")
        XCTAssertGreaterThan(plain.wisp, 0.3, "the notes send wisps")
        XCTAssertLessThanOrEqual(gentle.glow, plain.glow * 0.55, "gentle visuals calm the steam's glow")
        XCTAssertLessThanOrEqual(gentle.puff, plain.puff * 0.55, "and the puff")
        XCTAssertLessThanOrEqual(gentle.wisp, plain.wisp * 0.55, "and the wisps")
    }

    func testTeaHouseFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try renderTea(notes: [21, 60, 64, 67, 108], velocity: 0.95, at: 1.5, width: w, height: h)
            let r = shot.renderer, l = r.layout
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            XCTAssertTrue(keyTop <= l.tableFar && l.tableFar < l.sill && l.sill < r.horizonY && r.horizonY < l.lintel && l.lintel < 1,
                          "\(w)×\(h): keys, table, floor, screens and the horizon in order")
            XCTAssertGreaterThan(l.alcoveRight / l.aspect, -0.9, "\(w)×\(h): the alcove shows")
            XCTAssertGreaterThanOrEqual(r.spanRect.x, -1); XCTAssertLessThanOrEqual(r.spanRect.z, 1)
            XCTAssertTrue(r.openingRect.x >= r.spanRect.x && r.openingRect.z <= r.spanRect.z && r.openingRect.z > r.openingRect.x,
                          "\(w)×\(h): the opening is inside the screens' span")
            for (name, b) in [("bowl", r.bowlRect), ("steam", r.steamRect)] {
                XCTAssertTrue(b.x > -1 && b.z < 1 && b.y > keyTop && b.w < 1, "\(w)×\(h): the \(name) at \(b)")
            }
            XCTAssertLessThan((l.brazierX + 0.26) / l.aspect, 1, "\(w)×\(h): the brazier is in view")
            XCTAssertEqual(shot.frame.wisps.count, 5)
            XCTAssertNotNil(shot.frame.lanternFlake, "\(w)×\(h): a hard note knocks a flake off the lantern")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.001, "\(w)×\(h)")
        }
    }

    func testTeaHouseBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(TeaHouseSnowRenderer(device: device))
        let d = SceneDirector(themeID: TeaHouseSnowModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 22))
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)   // 2,040 notes in 1 s
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? TeaHouseFrame)
                XCTAssertLessThanOrEqual(f.wisps.count, SteamLines.cap)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                XCTAssertLessThanOrEqual(r.wispCount, TeaHouseSnowRenderer.wispBudget(q))
                XCTAssertLessThanOrEqual(r.wispCount, SteamLines.cap)
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.wispCount, 0)
    }

    /// Frost Grow on the screens' paper (the Window Kit's paper material): holding notes lets the frost creep over the
    /// panels, the notes melt warm patches in it, and it shows on the paper; Steam Lines sends nothing meanwhile.
    func testFrostGrowWorksOnThePaper() throws {
        let frost = ThemeState(values: ["visual": .choice("Frost Grow"), "screens": .number(0.3)])
        let night = Self.sky(hour: 22, weather: .snow)
        let held = try renderTea(notes: [48, 52, 55, 59], velocity: 0.5, at: 20, state: frost, sky: night, field: true)
        let silent = try renderTea(notes: [], at: 20, state: frost, sky: night, field: true)
        let bare = try renderTea(notes: [48, 52, 55, 59], velocity: 0.5, at: 20, state: ThemeState(values: ["screens": .number(0.3)]),
                                 sky: night)
        XCTAssertTrue(held.renderer.glass.allSatisfy(\.hasField), "the paper's frost fields have grown")
        XCTAssertEqual(held.renderer.panelSpecs.map(\.material), [.paperScreen, .paperScreen])
        XCTAssertGreaterThan(held.frame.frostLevel, silent.frame.frostLevel)
        XCTAssertGreaterThanOrEqual(held.renderer.frostCoverage - silent.renderer.frostCoverage, 0.1,
                                    "held notes grow the frost: \(silent.renderer.frostCoverage) → \(held.renderer.frostCoverage)")
        XCTAssertGreaterThan(held.renderer.patchCount, 0, "the held notes melt patches in the paper's frost")
        XCTAssertEqual(held.renderer.wispCount, 0, "Steam Lines rests while Frost Grow plays")
        XCTAssertEqual(bare.renderer.frostCoverage, 0, "no frost on the paper with Steam Lines")
        // The frost shows on the paper: much of the left panel's paper (left of the steam) differs from the bare paper.
        let paper = held.renderer.panelSpecs[0].rect, span = held.renderer.spanRect
        let x = Double(max(paper.x, span.x) + 0.03)...Double(min(paper.z, -0.25)), y = Double(paper.y + 0.05)...Double(paper.w - 0.05)
        let a = FramePatch.pixels(held.image, x: x, y: y).map(luma), b = FramePatch.pixels(bare.image, x: x, y: y).map(luma)
        let frosted = zip(a, b).filter { abs($0 - $1) > 0.04 }.count
        XCTAssertGreaterThan(Double(frosted) / Double(max(1, a.count)), 0.2, "the paper's panes carry ice")
    }
}

extension WorldPreviewTests {
    func testWriteTeaHousePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let follow = ThemeState()
        let pastel = ThemeState(values: ["light.hold": .choice(SkyHold.pastelDawn.rawValue)])
        let closed = ThemeState(values: ["screens": .number(0)])
        let frost = ThemeState(values: ["visual": .choice("Frost Grow")])
        let sky = TeaHouseSnowRendererTests.sky
        // At 3 s the demo's hard notes have just sent their wisps up and knocked flakes off the lantern's cap; at 5 s
        // its held chord has puffed; Frost Grow has had 20 s on a snowy night.
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double)] = [
            ("teahouse-dawn", sky(6.5, .lightCloud, 0.5), pastel, .high, 5),
            ("teahouse-snow", sky(14, .snow, 0.5), follow, .high, 5),
            ("teahouse-night", sky(22, .clear, 0.25), follow, .high, 5),
            ("teahouse-closed", sky(13, .clear, 0.5), closed, .high, 5),
            ("teahouse-smooth", sky(13, .clear, 0.5), follow, .lite, 5),
            ("teahouse-steam-t3", sky(13, .clear, 0.5), follow, .high, 3),
            ("teahouse-frost-t20", sky(22, .snow, 0.25), frost, .high, 20),
        ]
        for (name, s, state, q, t) in cases {
            let image = try XCTUnwrap(preview.render(themeID: TeaHouseSnowModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .delicate).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Rime frost: the pine and the fence feathered white (the world held fully rimed).
        let rime = try XCTUnwrap(preview.render(themeID: TeaHouseSnowModel.id, at: [5], state: follow, quality: .high,
                                                sky: sky(9, .rime, 0.5), mood: .delicate, skyEdit: { $0.rime = 1 }).first)
        try PreviewRenderer.writePNG(rime, to: url.appendingPathComponent("teahouse-rime.png"))
    }
}

/// Zen Rock Garden (Set 10's world) with Rake Lines: the raked gravel's height field lit by the sun or the moon.
@MainActor
final class ZenRockGardenRendererTests: XCTestCase {
    func testGardenShadersCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let lib = try device.makeLibrary(source: ZenRockGardenShaders.source, options: nil)
        for name in ["garden_vertex", "garden_fragment", "garden_keys_vertex", "garden_keys_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), name)
        }
        let own = String(ZenRockGardenShaders.source.dropFirst(SkyShaders.common.count))
        XCTAssertFalse(own.contains("pow("), "squares and powers are written out")
        // The Swift uniform array matches the MSL struct byte for byte (the pipeline's own reflection says so), and the
        // rake field is bound at texture 1 beside the stars.
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "garden_vertex")
        d.fragmentFunction = lib.makeFunction(name: "garden_fragment")
        d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
        d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let bindings = reflection?.fragmentBindings ?? []
        let buffers = bindings.compactMap { $0 as? MTLBufferBinding }
        func size(_ index: Int) -> Int? { buffers.first { $0.index == index }?.bufferDataSize }
        let row = MemoryLayout<SIMD4<Float>>.stride
        XCTAssertEqual(size(0), SkyLayer.uniformCount * row, "SkyU")
        XCTAssertEqual(size(1), ZenRockGardenRenderer.uniformCount * row, "GardenU")
        XCTAssertTrue(bindings.contains { $0.type == .texture && $0.index == 1 }, "the rake field at texture 1")
        XCTAssertEqual(ZenRockGardenRenderer.stoneBase, ZenRockGardenRenderer.headerCount)
        XCTAssertEqual(ZenRockGardenRenderer.frameBase, ZenRockGardenRenderer.stoneBase + 5)
        XCTAssertEqual(ZenRockGardenRenderer.cutBase, ZenRockGardenRenderer.frameBase + 4 * 5)
        XCTAssertEqual(ZenRockGardenRenderer.rakeBase, ZenRockGardenRenderer.cutBase + 2 * 5)
        XCTAssertEqual(ZenRockGardenRenderer.uniformCount, ZenRockGardenRenderer.rakeBase + ZenRockGardenRenderer.rakeCap)
        // The shader's moss islands are the field's: five stones in three groups (0 and 1, 2, 3 and 4).
        XCTAssertEqual(RakeLines.stones.map(\.island), [0, 0, 1, 2, 2])
        XCTAssertEqual(ZenRockGardenRenderer.stoneRows.count, 5)
        XCTAssertEqual(ZenRockGardenRenderer.frameRows.count, 20)
        XCTAssertEqual(ZenRockGardenRenderer.cutRows.count, 10)
        let r = try XCTUnwrap(ZenRockGardenRenderer(device: device))
        XCTAssertEqual(r.uniforms.count, ZenRockGardenRenderer.uniformCount)
        XCTAssertEqual(r.fieldUploads, 0, "nothing uploaded before the first frame")
    }

    /// Frozen Melbourne skies (the garden follows the sky): the equinox's sun at the hour, a bright moon by default.
    nonisolated static func sky(hour: Double, weather: WeatherKind = .clear, phase: Double = 0.45) -> SkySettings {
        var s = SkySettings(); s.timeMode = .frozen; s.frozenHour = hour; s.frozenPhase = phase; s.cityID = "melbourne"
        s.weatherMode = .pick; s.weather = weather
        return s
    }

    struct GardenShot {
        var image: CGImage
        var renderer: ZenRockGardenRenderer
        var frame: ZenGardenFrame
        var params: ParameterSet
        var preview: PreviewRenderer
    }

    /// Steps the garden at 60 fps (notes go down at 0.5 s and stay held, unless `release`) and renders the frame at
    /// `seconds`; `edit` changes each frame before the renderer sees it.
    static func renderGarden(notes: [UInt8], velocity: Float = 0.8, release: Bool = false, at seconds: Double,
                             state: ThemeState = ThemeState(), sky: SkySettings = ZenRockGardenRendererTests.sky(hour: 8.1),
                             quality: QualityLevel = .high, gentle: Bool = false, width: Int = 640, height: Int = 360,
                             edit: ((inout ZenGardenFrame) -> Void)? = nil,
                             each: ((ZenRockGardenRenderer, ZenGardenFrame) -> Void)? = nil) throws -> GardenShot {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: width, height: height))
        let r = try XCTUnwrap(ZenRockGardenRenderer(device: device))
        let d = SceneDirector(themeID: ZenRockGardenModel.id, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var elapsed = 0.0
        d.clock = { start.addingTimeInterval(elapsed) }
        d.sky.reset(settings: sky)
        d.mood = .orderedCalm
        var frame: ZenGardenFrame?
        let size = CGSize(width: width, height: height)
        for i in 1...Int(seconds * 60) {
            let t = Double(i) / 60
            elapsed = t
            if i == 30, !notes.isEmpty { d.handle(notes.map { .noteOn(note: $0, velocity: velocity) }, at: t) }
            if i == 33, release, !notes.isEmpty { d.handle(notes.map { .noteOff(note: $0) }, at: t) }
            frame = d.step(dt: 1.0 / 60, t: t, quality: quality) as? ZenGardenFrame
            if let edit, frame != nil { edit(&frame!) }
            if let frame {
                r.update(frame, params: d.parameters, quality: quality, gentle: gentle, dt: 1.0 / 60, size: size)
                each?(r, frame)
            }
        }
        let f = try XCTUnwrap(frame)
        return GardenShot(image: try XCTUnwrap(preview.capture(r)), renderer: r, frame: f, params: d.parameters, preview: preview)
    }

    private func luma(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The mean and variance of the luminance inside an NDC rectangle (x0, y0, x1, y1).
    private func patchStats(_ image: CGImage, _ rect: SIMD4<Float>) -> (mean: Double, variance: Double) {
        let l = FramePatch.pixels(image, x: Double(rect.x)...Double(rect.z), y: Double(rect.y)...Double(rect.w)).map(luma)
        guard !l.isEmpty else { return (0, 0) }
        let mean = l.reduce(0, +) / Double(l.count)
        return (mean, l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count))
    }

    private struct LightCase { let name: String; let sky: SkySettings; let mean: Double; let variance: Double }

    func testGardenPreviewIsStructured() throws {
        // CPU reference renders of these frames (the shader through the MSL shim) measured means 0.32, 0.41, 0.34, 0.12
        // and variances 0.049, 0.080, 0.057, 0.013: the floors leave room for the bloom, the keys and the real sky.
        let cases = [
            LightCase(name: "dawn", sky: Self.sky(hour: 8.1), mean: 0.12, variance: 0.012),
            LightCase(name: "noon", sky: Self.sky(hour: 13.2), mean: 0.2, variance: 0.02),
            LightCase(name: "dusk", sky: Self.sky(hour: 18.3), mean: 0.12, variance: 0.012),
            LightCase(name: "night", sky: Self.sky(hour: 22), mean: 0.04, variance: 0.003),
        ]
        for q in [QualityLevel.lite, .high] {
            for c in cases {
                let shot = try Self.renderGarden(notes: [60, 64, 67], at: 1.2, sky: c.sky, quality: q)
                let s = PreviewRenderer.stats(shot.image)
                XCTAssertGreaterThan(s.meanLuminance, c.mean, "\(q) \(c.name)")
                XCTAssertGreaterThan(s.variance, c.variance, "\(q) \(c.name)")
                XCTAssertEqual(shot.renderer.fieldVersion, shot.frame.field.version, "\(q) \(c.name): the shader reads this frame's field")
                XCTAssertEqual(shot.frame.rings.count, 3, "\(q) \(c.name): the notes rake their rings in any light")
                let key = shot.renderer.uniforms[6]
                if c.name == "night" {
                    XCTAssertEqual(key.w, 0, "\(q): the moon lights the gravel at night")
                    XCTAssertGreaterThan(key.z, key.x, "\(q): silver-blue moonlight")
                } else {
                    XCTAssertEqual(key.w, 1, "\(q) \(c.name): the sun lights it by day")
                }
            }
        }
    }

    /// A low sun rakes across a fresh ring's grooves: the gravel patch on its flank varies far more than the same patch
    /// with the field flat.
    func testRakeLinesShowInTheLight() throws {
        let shot = try Self.renderGarden(notes: [60], release: true, at: 1.0)
        let sun = shot.frame.sky.sun.altitude
        XCTAssertTrue(sun > 2 && sun < 15, "a low morning sun (\(sun)°)")
        let ring = try XCTUnwrap(shot.frame.rings.first)
        XCTAssertEqual(ring.stone, 2, "middle C rakes round the tall stone")
        XCTAssertEqual(ring.radius, RakeLines.firstRingRadius(2), accuracy: 1e-4)
        let patch = try XCTUnwrap(shot.renderer.gravelPatch())
        let raked = patchStats(shot.image, patch)
        var flat = shot.frame
        flat.field = RakeField(heights: [Float](repeating: 0, count: RakeField.width * RakeField.height))
        flat.field.version = shot.frame.field.version &+ 1
        shot.renderer.update(flat, params: shot.params, quality: .high, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
        let level = patchStats(try XCTUnwrap(shot.preview.capture(shot.renderer)), patch)
        XCTAssertGreaterThanOrEqual(raked.variance, 1.3 * level.variance, "ring \(raked.variance), flat \(level.variance)")
        XCTAssertGreaterThan(raked.variance, 0.002, "the ridges and their shadows show")
    }

    /// Snow fills the grooves (the gravel patch goes flat and white) and caps the stones (the tall stone's head whitens).
    func testSnowFillsTheGrooves() throws {
        let bare = try Self.renderGarden(notes: [], at: 1.0)
        let snowy = try Self.renderGarden(notes: [], at: 1.0, edit: { $0.snowCover = 1 })
        let patch = try XCTUnwrap(bare.renderer.gravelPatch())
        let b = patchStats(bare.image, patch), s = patchStats(snowy.image, patch)
        XCTAssertGreaterThan(b.variance, 0.002, "the morning's lines show bare")
        XCTAssertLessThanOrEqual(s.variance, 0.4 * b.variance, "the grooves fill: \(b.variance) → \(s.variance)")
        XCTAssertGreaterThan(s.mean, b.mean, "and whiten")
        let top = bare.renderer.stoneTopScreen[2]
        let head = SIMD4<Float>(top.x - 0.02, top.y - 0.055, top.x + 0.02, top.y - 0.012)
        let bareHead = patchStats(bare.image, head).mean, snowyHead = patchStats(snowy.image, head).mean
        XCTAssertGreaterThan(snowyHead, 1.15 * bareHead, "the tall stone is capped: \(bareHead) → \(snowyHead)")
    }

    func testGardenHonoursGentleVisuals() throws {
        var plain: Float = 0, gentle: Float = 0
        var plainWeather = false, gentleWeather = false
        _ = try Self.renderGarden(notes: [60, 64, 67], at: 1.5, each: { r, _ in
            plain = max(plain, r.waveOut); plainWeather = r.weather.gentle
        })
        _ = try Self.renderGarden(notes: [60, 64, 67], at: 1.5, gentle: true, each: { r, _ in
            gentle = max(gentle, r.waveOut); gentleWeather = r.weather.gentle
        })
        XCTAssertGreaterThan(plain, 0.2, "a chord's wave brightens the gravel")
        XCTAssertLessThanOrEqual(gentle, plain * 0.55, "gentle visuals calm it")
        XCTAssertFalse(plainWeather)
        XCTAssertTrue(gentleWeather, "and the fireflies and crystals")
    }

    func testGardenFramesAnyAspect() throws {
        for (w, h) in [(864, 360), (360, 360)] {
            let shot = try Self.renderGarden(notes: [21, 60, 64, 67, 108], at: 1.2, width: w, height: h)
            let r = shot.renderer
            XCTAssertEqual(r.keyRects.count, 88)
            for k in r.keyRects {
                XCTAssertGreaterThanOrEqual(k.x, -1); XCTAssertLessThanOrEqual(k.z, 1)
                XCTAssertGreaterThanOrEqual(k.y, -1); XCTAssertLessThanOrEqual(k.w, 1)
            }
            let keyTop = r.keyRects.map(\.w).max() ?? -1
            XCTAssertTrue(keyTop < r.wallFootY && r.wallFootY < r.wallTopY && r.wallTopY < r.horizonY && r.horizonY < 1,
                          "\(w)×\(h): gravel, wall, horizon in order")
            XCTAssertEqual(r.stoneScreen.count, 5)
            for (i, p) in r.stoneScreen.enumerated() {
                XCTAssertTrue(abs(p.x) < 0.95 && p.y > keyTop && p.y < r.wallFootY, "\(w)×\(h): stone \(i) at \(p)")
                XCTAssertLessThan(r.stoneTopScreen[i].y, 0.95, "\(w)×\(h): stone \(i) stands in view")
            }
            let patch = try XCTUnwrap(r.gravelPatch())
            XCTAssertTrue(patch.x > -1 && patch.z < 1 && patch.y > keyTop && patch.w < r.wallFootY, "\(w)×\(h): the gravel patch \(patch)")
            XCTAssertEqual(Set(shot.frame.rings.map(\.stone)).count, 3, "\(w)×\(h): low, middle and high notes rake three stones")
            XCTAssertGreaterThan(PreviewRenderer.stats(shot.image).variance, 0.008, "\(w)×\(h)")
        }
    }

    func testGardenBurstStaysInBudget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let preview = try XCTUnwrap(PreviewRenderer(width: 640, height: 360))
        let r = try XCTUnwrap(ZenRockGardenRenderer(device: device))
        let d = SceneDirector(themeID: ZenRockGardenModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 8.1))
        var frames = 0
        for q in [QualityLevel.lite, .high] {
            let start = Date()
            for i in 0..<60 {
                let t = Double(i) / 60
                d.handle((0..<34).map { k in .noteOn(note: UInt8(21 + (i * 34 + k) % 88), velocity: 0.8) }, at: t)
                let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: t, quality: q) as? ZenGardenFrame)
                r.update(f, params: d.parameters, quality: q, gentle: false, dt: 1.0 / 60, size: CGSize(width: 640, height: 360))
                frames += 1
                XCTAssertLessThanOrEqual(r.rakeCount, ZenRockGardenRenderer.rakeBudget(q))
                XCTAssertLessThanOrEqual(f.rings.count, RakeLines.ringCap)
                XCTAssertLessThanOrEqual(f.strokes.count, RakeLines.strokeCap)
                XCTAssertLessThanOrEqual(r.fieldUploads, frames, "at most one upload a frame")
                XCTAssertNotNil(preview.capture(r))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 4, "\(q)")
        }
        XCTAssertGreaterThan(r.rakeCount, 0, "the held notes' rakes go round")
    }

    /// The field goes up as a texture only when its version moves on: once for a quiet garden, never twice in a frame,
    /// and exactly once for each new version while you play.
    func testFieldUploadsOnlyWhenChanged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let r = try XCTUnwrap(ZenRockGardenRenderer(device: device))
        let d = SceneDirector(themeID: ZenRockGardenModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.sky.reset(settings: Self.sky(hour: 8.1))
        let size = CGSize(width: 320, height: 180)
        func step(_ i: Int) throws -> ZenGardenFrame {
            let f = try XCTUnwrap(d.step(dt: 1.0 / 60, t: Double(i) / 60, quality: .high) as? ZenGardenFrame)
            r.update(f, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
            return f
        }
        var last = try step(0)
        XCTAssertEqual(r.fieldUploads, 1, "the first frame uploads the morning's field")
        for i in 1...30 { last = try step(i) }
        XCTAssertFalse(last.field.dirty)
        XCTAssertEqual(r.fieldUploads, 1, "a quiet garden's field never changes: nothing more goes up")
        r.update(last, params: d.parameters, quality: .high, gentle: false, dt: 1.0 / 60, size: size)
        XCTAssertEqual(r.fieldUploads, 1, "the same frame again: still nothing")
        d.handle([.noteOn(note: 60, velocity: 0.9)], at: 31.0 / 60)
        var versions: Set<Int> = [last.field.version]
        for i in 31...150 {
            if i == 90 { d.handle([.noteOff(note: 60)], at: Double(i) / 60) }
            let before = r.fieldUploads
            let f = try step(i)
            XCTAssertEqual(r.fieldUploads - before, f.field.dirty ? 1 : 0, "frame \(i): an upload exactly when the field moved on")
            XCTAssertEqual(r.fieldVersion, f.field.version, "frame \(i): the shader reads this frame's field")
            versions.insert(f.field.version)
        }
        XCTAssertGreaterThan(versions.count, 2, "the note and its held rake changed the field")
        XCTAssertEqual(r.fieldUploads, versions.count, "one upload per version")
    }
}

extension WorldPreviewTests {
    func testWriteGardenPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] else { throw XCTSkip("PREVIEW_DIR not set") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let preview = try XCTUnwrap(PreviewRenderer(width: 1280, height: 720))
        let sky = ZenRockGardenRendererTests.sky
        let autumn = ThemeState(values: ["season": .choice(GardenSeason.autumn.rawValue)])
        // The frozen sky is the equinox's: at Melbourne the sun is 8° up at 8:06 and 14° up at 18:18.
        let cases: [(String, SkySettings, ThemeState, QualityLevel, Double, ((inout SkyState) -> Void)?)] = [
            ("garden-dawn", sky(8.1, .clear, 0.45), ThemeState(), .high, 5, nil),
            ("garden-noon", sky(13.2, .clear, 0.45), ThemeState(), .high, 5, nil),
            ("garden-dusk", sky(18.3, .clear, 0.45), ThemeState(), .high, 5, nil),
            ("garden-night", sky(22, .clear, 0.45), ThemeState(), .high, 5, nil),
            ("garden-rime", sky(9, .rime, 0.45), ThemeState(), .high, 5, { $0.rime = 1 }),
            ("garden-autumn", sky(9.5, .clear, 0.45), autumn, .high, 5, nil),
            ("garden-smooth", sky(8.1, .clear, 0.45), ThemeState(), .lite, 5, nil),
            ("garden-rings-t3", sky(8.6, .clear, 0.45), ThemeState(), .high, 3, nil),
        ]
        for (name, s, state, q, t, edit) in cases {
            let image = try XCTUnwrap(preview.render(themeID: ZenRockGardenModel.id, at: [t], state: state, quality: q, sky: s,
                                                     mood: .orderedCalm, skyEdit: edit).first)
            try PreviewRenderer.writePNG(image, to: url.appendingPathComponent("\(name).png"))
        }
        // Snow takes minutes to fill the grooves: the snow preview holds the garden's cover full under falling snow.
        let snow = try ZenRockGardenRendererTests.renderGarden(notes: [], at: 5, sky: sky(11, .snow, 0.45), width: 1280, height: 720,
                                                               edit: { $0.snowCover = 1 })
        try PreviewRenderer.writePNG(snow.image, to: url.appendingPathComponent("garden-snow.png"))
    }
}
