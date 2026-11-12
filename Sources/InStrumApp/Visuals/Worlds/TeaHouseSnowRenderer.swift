import Metal
import CoreGraphics
import simd
import InStrumCore

/// The two paper panels' frost fields (left, right), grown once per process on a background queue and shared by every
/// tea house renderer; until they land the paper draws the Window Kit's fallback frost.
@MainActor
final class PaperFrostFields {
    static let shared = PaperFrostFields()
    private(set) var fields: [FrostField] = []
    private var requested = false

    /// Starts the growth the first time a tea house asks (later calls do nothing).
    func request() {
        guard !requested else { return }
        requested = true
        DispatchQueue.global(qos: .userInitiated).async {
            let grown = TeaHouseSnowRenderer.fieldSeeds.map {
                FrostField(seed: $0, columns: TeaHouseSnowRenderer.kumikoColumns, rows: TeaHouseSnowRenderer.kumikoRows,
                           bar: TeaHouseSnowRenderer.kumikoBar)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { PaperFrostFields.shared.fields = grown } }
        }
    }
}

/// The tea room on screen: heights in NDC y, positions across in screen units (NDC x × aspect).
struct TeaHouseLayout: Equatable {
    var keyTop, aspect: Float
    /// The low table's far edge, the sill (the screens' foot), the lintel (their head) and the horizon (the eye's
    /// level: the garden's horizon and the room's vanishing point).
    var tableFar, sill, lintel, horizon: Float
    /// The alcove's right edge, the screens' span (left, right) and a panel's stile.
    var alcoveRight, spanLeft, spanRight, stile: Float
    /// The tea bowl: its centre across, its rim (NDC y), its half width; how high the steam rises above the rim.
    var bowlX, bowlRim, bowlHalfWidth, steamHeight: Float
    /// The brazier: its centre across and its rim (NDC y).
    var brazierX, brazierRim: Float
}

/// Draws Tea House Snow (spec §8.1, §8.2): kneeling at a low table in a small tea house, tatami with their dark borders
/// to the paper screens, the alcove with its hanging scroll and a camellia, the tea bowl steaming on the table and the
/// iron kettle on its brazier. The screens slide open into their walls on a snow garden under the Living Sky: a
/// snow-viewing lantern capped with snow, a pine bent under it, a stone basin with its bamboo ladle, a low bamboo
/// fence and a plum tree in a few red blossoms. The paper glows with the sky's light, its lattice shadows across the
/// floor; at night the lantern's candle and the brazier light the room. Steam Lines curls the tea's steam; Frost Grow
/// grows ice on the paper (the Window Kit's paper screen).
@MainActor
final class TeaHouseSnowRenderer: ThemeRenderer {
    /// Wisps sent to the GPU (fewer on Smooth), and the frost patches each panel may carry.
    static func wispBudget(_ q: QualityLevel) -> Int { q == .lite ? 12 : SteamLines.cap }
    static func patchBudget(_ q: QualityLevel) -> Int { WindowGlassLayer.patchCap(q) }

    /// A panel's kumiko: four columns of seven rows of panes (the frost field's layout too); the bars' width is a
    /// fraction of the paper's width.
    nonisolated static let kumikoColumns = 4
    nonisolated static let kumikoRows = 7
    nonisolated static let kumikoBar: Float = 0.008
    nonisolated static let fieldSeeds: [UInt64] = [0x7EA_5C2E, 0x7EA_5C2F]
    /// The vertical field of view (degrees): the room's scale at the screens' plane.
    nonisolated static let verticalFOV = 45.0

    /// The uniform block (MSL `TeaU`): 17 header rows, the ribbon's path (3), a panel's bars (12), the wisps (24 + 24).
    nonisolated static let pathBase = 17
    nonisolated static let barBase = 20
    nonisolated static let maxBars = 12
    nonisolated static let wispBase = 32
    nonisolated static let wispBBase = 32 + SteamLines.cap
    nonisolated static let uniformCount = 32 + 2 * SteamLines.cap

    typealias Layout = TeaHouseLayout

    /// The tea room laid out for a frame of this shape: the keys along the table's edge, the table, the tatami, the
    /// screens from the sill to the lintel with the alcove at their left, the bowl in the middle and the brazier to the
    /// right; the horizon (and the eye) 40% up the screens.
    nonisolated static func roomLayout(aspect: Float, keyTop: Float) -> Layout {
        let a = aspect.isFinite ? min(max(aspect, 0.3), 6) : 16.0 / 9
        let top = keyTop.isFinite ? min(max(keyTop, -1), -0.3) : -0.76
        let h = 1 - top
        let sill = top + 0.255 * h, lintel = min(0.9, top + 0.86 * h)
        let alcove = min(0.92, 0.44 * a)
        let alcoveRight = -a + alcove
        let spanLeft = alcoveRight + 0.07, spanRight = a - 0.05
        let bowlHalf: Float = min(0.15, 0.13 * a)
        let rim = top + 0.045 * h + 0.13
        return Layout(keyTop: top, aspect: a, tableFar: top + 0.1 * h, sill: sill, lintel: lintel,
                      horizon: sill + 0.4 * (lintel - sill), alcoveRight: alcoveRight, spanLeft: spanLeft, spanRight: spanRight,
                      stile: 0.04, bowlX: 0, bowlRim: rim, bowlHalfWidth: bowlHalf, steamHeight: 0.62 * (lintel - rim),
                      brazierX: min(0.62 * a, spanRight - 0.3), brazierRim: top + 0.2 * h)
    }

    /// The two paper panels (left, right) at how far the screens are open, as Window Kit windows: each slides out into
    /// its wall (pocket screens), the left one left and the right one right; the paper is the window's glass, the
    /// kumiko its bars and the stiles its frame.
    nonisolated static func panels(_ l: Layout, open: Float) -> [WindowSpec] {
        let s = open.isFinite ? min(max(open, 0), 1) : 0.5
        let p = (l.spanRight - l.spanLeft) / 2
        return [l.spanLeft - s * p, l.spanRight - p + s * p].map { x0 in
            WindowSpec(columns: kumikoColumns, rows: kumikoRows, bar: kumikoBar,
                       rect: SIMD4((x0 + l.stile) / l.aspect, l.sill + l.stile, (x0 + p - l.stile) / l.aspect, l.lintel - l.stile),
                       material: .paperScreen, frameWidth: l.stile / l.aspect)
        }
    }

    /// The opening between the panels (NDC x0, y0, x1, y1): centred on the span, as wide as the screens are open.
    nonisolated static func opening(_ l: Layout, open: Float) -> SIMD4<Float> {
        let s = open.isFinite ? min(max(open, 0), 1) : 0.5
        let m = (l.spanLeft + l.spanRight) / 2, p = (l.spanRight - l.spanLeft) / 2
        return SIMD4((m - s * p) / l.aspect, l.sill, (m + s * p) / l.aspect, l.lintel)
    }

    private let sky: SkyLayer
    let weather: WeatherLayer
    /// The Window Kit's paper for Frost Grow: one glass layer per panel (left, right).
    let glass: [WindowGlassLayer]
    private let garden, paper, room, steam, keys: MTLRenderPipelineState
    private var teaU = [SIMD4<Float>](repeating: .zero, count: 32 + 2 * SteamLines.cap)
    private var keyInstances: [KeyInstance] = []
    private var limiter = FlashLimiter()
    private var quality: QualityLevel = .high
    private var specs: [WindowSpec] = []
    private var candleLevel: Float = 0
    private var candlePrimed = false
    private var showFrost = false
    private(set) var post = PostSettings()
    private(set) var layout = TeaHouseSnowRenderer.roomLayout(aspect: 16.0 / 9, keyTop: -0.76)
    /// The steam's brightening from held notes after the flash limiter, and a chord's puff × the sparkle scale (gentle
    /// visuals halve both).
    private(set) var glowOut: Float = 0
    private(set) var puffOut: Float = 0
    /// The stone lantern's candle (lit from dusk, gliding on and off, with a flicker) and the brazier's coals.
    private(set) var candleOut: Float = 0
    private(set) var fireOut: Float = 0
    /// How direct the sun is through the screens (0 none … 1 a clear sun straight in).
    private(set) var sunThrough: Float = 0
    /// The paper's glow (linear rgb): the sky's light through it.
    private(set) var paperGlow = SIMD3<Float>(repeating: 0)
    /// Wisps drawn this frame, and frost patches sent to the panels.
    private(set) var wispCount = 0, patchCount = 0
    /// The horizon (NDC y), the screens' span and the opening between the panels (NDC x0, y0, x1, y1).
    private(set) var horizonY: Float = 0
    private(set) var spanRect = SIMD4<Float>(-0.5, -0.3, 1, 0.75)
    private(set) var openingRect = SIMD4<Float>(0, -0.3, 0.5, 0.75)
    /// Whether this frame draws the garden through the opening (and its sky and weather): not with the screens closed.
    private(set) var drawsGarden = true
    /// The bowl (NDC x0, y0, x1, y1) and the steam's patch above it, where wisps curl off.
    private(set) var bowlRect = SIMD4<Float>(-0.1, -0.7, 0.1, -0.55)
    private(set) var steamRect = SIMD4<Float>(-0.15, -0.5, 0.15, 0.1)
    /// The shader's uniforms (tests read them).
    var uniforms: [SIMD4<Float>] { teaU }
    /// The panels as the Window Kit draws them (left, right).
    var panelSpecs: [WindowSpec] { specs }
    /// The share of the paper frosted (the panels' estimates averaged; 0 unless Frost Grow is the visual).
    var frostCoverage: Float { showFrost ? glass.map(\.frostCoverage).reduce(0, +) / Float(max(1, glass.count)) : 0 }
    /// The keys' rectangles in NDC (x0, y0, x1, y1) (tests check they stay inside the frame).
    var keyRects: [SIMD4<Float>] { keyInstances.map(\.rect) }

    private struct KeyInstance { var rect: SIMD4<Float>; var info: SIMD4<Float> }

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device),
              let gl = WindowGlassLayer(device: device), let gr = WindowGlassLayer(device: device),
              let lib = try? device.makeLibrary(source: TeaHouseSnowShaders.source, options: nil) else { return nil }
        enum Blend { case opaque, premultiplied }
        func make(_ v: String, _ f: String, _ blend: Blend, writesDepth: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            if blend == .premultiplied {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if !writesDepth { d.colorAttachments[1].writeMask = [] }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let ga = make("tea_rect_vertex", "tea_garden_fragment", .premultiplied),
              let pa = make("tea_rect_vertex", "tea_paper_fragment", .opaque),
              let rm = make("tea_full_vertex", "tea_room_fragment", .premultiplied),
              let st = make("tea_rect_vertex", "tea_steam_fragment", .premultiplied, writesDepth: false),
              let k = make("tea_keys_vertex", "tea_keys_fragment", .opaque) else { return nil }
        sky = s; weather = w; glass = [gl, gr]
        garden = ga; paper = pa; room = rm; steam = st; keys = k
        sky.verticalFOV = Self.verticalFOV
        PaperFrostFields.shared.request()
        takeFields()
    }

    /// Hands the shared frost fields to the panels once they have grown.
    private func takeFields() {
        let fields = PaperFrostFields.shared.fields
        guard fields.count == glass.count else { return }
        for (g, f) in zip(glass, fields) where !g.hasField { g.setField(f) }
    }

    /// Waits (running the main run loop) until the paper's frost fields have grown; for previews and tests.
    @discardableResult
    func awaitField(timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while PaperFrostFields.shared.fields.count < glass.count, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        takeFields()
        return glass.allSatisfy(\.hasField)
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { OceanLight.smooth(a, b, x) }
    private static func smoothF(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    private static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    func update(_ frame: TeaHouseFrame, params p: ParameterSet, quality: QualityLevel, gentle: Bool, dt: Double, size: CGSize) {
        self.quality = quality
        takeFields()
        let s = frame.sky
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let time = Float(frame.time.truncatingRemainder(dividingBy: 3600))
        let fdt = Float(min(max(dt, 0), 0.1))
        let keysShow = p.number("keys.show") > 0.5
        let keyTop: Float = keysShow ? -1 + 2 * Float(p.number("keys.height")) : -1
        let l = Self.roomLayout(aspect: aspect, keyTop: keyTop)
        layout = l
        horizonY = l.horizon
        let open = Self.unit(frame.screensOpen.isFinite ? frame.screensOpen : 0.5)
        specs = Self.panels(l, open: open)
        spanRect = SIMD4(l.spanLeft / l.aspect, l.sill, l.spanRight / l.aspect, l.lintel)
        openingRect = Self.opening(l, open: open)
        drawsGarden = (openingRect.z - openingRect.x) / 2 * Float(max(1, size.width)) >= 1

        sky.horizonY = l.horizon
        sky.viewAzimuth = nil   // face the equator: the sun crosses the screens at midday
        sky.gentle = gentle
        sky.update(s, quality: quality, size: size, time: Float(frame.time))
        weather.gentle = gentle
        weather.update(s, quality: quality, size: size, dt: dt, surface: .ground(horizonY: l.horizon))
        let cam = sky.camera(latitude: s.latitude, aspect: aspect)

        // Light: day and night, the sun through the screens (room space: x right, y up, z out to the garden), the sky's
        // light through the paper (pink on a pastel dawn, blue-grey at night), the opening's light, the brazier's coals
        // and, from dusk, the stone lantern's candle.
        let night = Float(1 - Self.smooth(-8, -2, s.sun.altitude))
        let day = Float(Self.smooth(-4, 8, s.sun.altitude))
        let lights = OceanLight.lights(s)
        let level = SIMD3<Float>(cam.right.x, cam.right.y, 0)
        let ahead = simd_normalize(SIMD3<Float>(cam.forward.x, cam.forward.y, 0))
        let sunENU = SkyLayer.enu(s.sun)
        var ls = SIMD3<Float>(simd_dot(sunENU, level), sunENU.z, simd_dot(sunENU, ahead))
        let mist = Self.unit(s.mist)
        let facing = Self.smoothF(0.05, 0.3, ls.z)
        let lowSun = Self.smoothF(0.5, 4, Float(s.sun.altitude))
        let veil: Float = (1 - 0.75 * mist) * (1 - 0.6 * Self.unit(s.snow))
        sunThrough = Self.unit(lights.sun.w * facing * lowSun * veil)
        // Without a direct sun, the light falls through the screens from the bright sky, 35° up, straight in.
        let diffuseDir = SIMD3<Float>(0, 0.57, 0.82)
        ls = sunThrough > 0.02 ? simd_normalize(SIMD3(ls.x, max(ls.y, 0.02), max(ls.z, 0.05))) : diffuseDir
        let skyLight = s.zenith * 0.45 + s.horizon * 0.55
        let washi = SIMD3<Float>(1.04, 0.98, 0.88)   // the paper warms the light through it a little
        let sunColour = lights.sunColor * 1.6   // its strength is in sunThrough (and lights.sun.w for the paper)
        let moonLight = lights.moonColor * (0.05 * lights.moon.w)
        let slow: Float = sin(time * 2.3) * sin(time * 0.7 + 1)
        let fireFlicker: Float = 0.82 + 0.1 * slow + 0.08 * sin(time * 7.9 + 0.5)
        let fire = SIMD3<Float>(1.0, 0.42, 0.13) * ((0.2 + 0.8 * night) * fireFlicker * 1.9)   // the coals' own glow
        let fireLight = SIMD3<Float>(1.0, 0.74, 0.54) * fire.x                                // and the light they throw
        fireOut = (0.2 + 0.8 * night) * fireFlicker
        let candleTarget: Float = Float(Self.smooth(1, -2, s.sun.altitude))
        if candlePrimed {
            candleLevel += (candleTarget - candleLevel) * (1 - exp(-fdt / 1.2))
        } else {
            candleLevel = candleTarget
            candlePrimed = true
        }
        let candleFlicker: Float = 0.86 + 0.08 * sin(time * 5.7) + 0.06 * sin(time * 11.3 + 2.1)
        candleOut = candleLevel * candleFlicker
        let candle = SIMD3<Float>(1.0, 0.64, 0.30) * (2.6 * candleOut)
        let openLight = skyLight * 1.25 + sunColour * (0.25 * sunThrough)
        // The paper: the sky's light and the snow garden's thrown up onto it, the sun on it when it shines on the screens.
        let sunOnPaper: Float = 0.28 * lights.sun.w * facing * (1 - 0.6 * mist)
        let outside: SIMD3<Float> = skyLight * 0.55 + sunColour * sunOnPaper + moonLight
        let paperFromOutside = outside * washi
        // The room: the paper's light (all of it with the screens shut), the opening's, the coals', the candle's.
        let paperShare: Float = 0.32 * (1 - open), openShare: Float = 0.24 * open, candleShare: Float = 0.012 * open
        let screensLight: SIMD3<Float> = paperFromOutside * paperShare + openLight * openShare
        let roomLight: SIMD3<Float> = screensLight + fireLight * 0.045 + candle * candleShare
        paperGlow = paperFromOutside + roomLight * 0.12 + fireLight * 0.012
        let frostVisual = TeaHouseSnowModel.visuals.count > 1 && p.choice("visual") == TeaHouseSnowModel.visuals[1]
        showFrost = frostVisual

        // The steam's glow through the flash limiter (gentle halves it); the puff and the wisps × the sparkle scale.
        limiter.gentle = gentle
        let sparkleScale = FlashLimiter.sparkleScale(gentle: gentle)
        let mood = frame.mood
        let nightLift: Float = 1 + 0.85 * night, glowLift: Float = 1 + 0.06 * Self.unit(frame.steamGlow)
        let exposure = MoodLook.exposure(mood) * nightLift * weather.exposureBoost * glowLift
        let limited = limiter.limit(exposure: exposure, sparkle: Self.unit(frame.steamGlow), dt: dt)
        glowOut = limited.sparkle
        puffOut = Self.unit(frame.puff.strength) * sparkleScale

        // Frost Grow: the paper's panels carry the frost (the cold sky's, with the notes' warm patches); each patch
        // lands on the paper still showing, the low half of the keyboard on the left panel and the high half on the
        // right. Nothing lands on paper indoors: no flakes, drips or condensation.
        let patches = frostVisual ? FrostGrow.visible(frame.patches, limit: Self.patchBudget(quality)) : []
        let width = (l.spanRight - l.spanLeft) / 2
        let showing = (1 - open) * width
        var perPanel: [[GlassPatch]] = [[], []]
        for pt in patches where pt.x.isFinite && pt.y.isFinite && pt.radius.isFinite {
            let k = min(1, max(0, (pt.x - 0.08) / 0.84))
            let side = k < 0.5 ? 0 : 1
            let along = side == 0 ? k * 2 : (k - 0.5) * 2
            let x = side == 0 ? l.spanLeft + along * showing : l.spanRight - showing + along * showing
            let r = specs[side].rect
            let glassW = (r.z - r.x) * l.aspect, glassH = r.w - r.y
            guard glassW > 1e-3 else { continue }
            perPanel[side].append(GlassPatch(x: (x / l.aspect - r.x) / (r.z - r.x), y: pt.y, radius: pt.radius * glassH / glassW,
                                             warmth: pt.warmth))
        }
        patchCount = perPanel.reduce(0) { $0 + $1.count }
        let inside = roomLight * 0.9 + fireLight * 0.04
        for (i, g) in glass.enumerated() {
            g.update(spec: specs[i], frost: frostVisual ? frame.frostLevel : 0, patches: perPanel[i], condensation: 0, wetDrips: 0,
                     snow: 0, reflection: .zero, glint: SIMD4(inside, 0.35 + 0.4 * sunThrough), quality: quality, dt: dt,
                     outsideLight: paperGlow, aspect: aspect, sparkle: limited.sparkle)
        }

        // Steam Lines: the wisps (the brightest within the budget), the ribbon's path, the puff, the lantern's flake.
        let wisps = SteamLines.visible(frame.wisps, limit: Self.wispBudget(quality))
        wispCount = wisps.count
        for i in 0..<SteamLines.cap {
            if i < wisps.count {
                let w = wisps[i]
                let baseX = l.bowlX + (Self.unit(w.x) - 0.5) * 2 * l.bowlHalfWidth
                teaU[Self.wispBase + i] = SIMD4(baseX, Self.unit(w.rise), min(1, max(-1, w.curl)), Self.unit(w.brightness) * sparkleScale)
                let seed = Float(w.id & 1023) * 0.618_034
                teaU[Self.wispBBase + i] = SIMD4(min(60, max(0, w.age)), Self.unit(w.height), w.held ? 1 : 0, seed - seed.rounded(.down))
            } else {
                teaU[Self.wispBase + i] = .zero
                teaU[Self.wispBBase + i] = .zero
            }
        }
        var path = frame.ribbonPath
        if path.count != SteamLines.pathPoints { path = SteamLines.straight }
        for r in 0..<3 {
            func v(_ k: Int) -> Float { let x = path[r * 4 + k]; return x.isFinite ? min(1, max(-1, x)) : 0 }
            teaU[Self.pathBase + r] = SIMD4(v(0), v(1), v(2), v(3))
        }
        let bars = specs[0].bars()
        for i in 0..<Self.maxBars { teaU[Self.barBase + i] = i < bars.count ? bars[i] : .zero }

        let wrap: (Float) -> Float = { $0.isFinite ? min(max($0, 0), 600) : 0 }
        teaU[0] = SIMD4(l.keyTop, l.aspect, l.horizon, time)
        teaU[1] = SIMD4(l.sill, l.lintel, l.tableFar, l.alcoveRight)
        teaU[2] = SIMD4(l.spanLeft, l.spanRight, l.stile, open)
        teaU[3] = SIMD4(night, day, quality == .lite ? 2 : 3, limited.sparkle)
        teaU[4] = SIMD4(paperGlow, frostVisual ? 1 : 0)
        teaU[5] = SIMD4(roomLight, 0)
        teaU[6] = SIMD4(openLight, 0)
        teaU[7] = SIMD4(ls, sunThrough)
        teaU[8] = SIMD4(sunColour, 0)
        teaU[9] = SIMD4(fire, fireFlicker)
        teaU[10] = SIMD4(candle, candleFlicker)
        teaU[11] = SIMD4(mist, Self.unit(s.wind), Self.unit(s.snow), Self.unit(s.cloudCover))
        teaU[12] = SIMD4(Self.unit(frame.blossom), glowOut, puffOut, Float(wisps.count))
        teaU[13] = SIMD4(l.bowlX, l.bowlRim, l.bowlHalfWidth, l.steamHeight)
        let puff = frame.puff
        teaU[14] = SIMD4(l.bowlX + (Self.unit(puff.x) - 0.5) * 2 * l.bowlHalfWidth, Self.unit(puff.warmth), puffOut, wrap(puff.age))
        if let f = frame.lanternFlake {
            teaU[15] = SIMD4(Self.unit(f.x), min(SteamLines.flakeLife, max(0, f.age)), Self.unit(f.velocity), 1)
        } else {
            teaU[15] = .zero
        }
        teaU[16] = SIMD4(Float(min(4, max(2, frame.ribbons))), Float(min(bars.count, Self.maxBars)), l.brazierX, l.brazierRim)

        let bw = l.bowlHalfWidth
        bowlRect = SIMD4((l.bowlX - bw) / l.aspect, l.bowlRim - 0.15, (l.bowlX + bw) / l.aspect, l.bowlRim + 0.03)
        steamRect = SIMD4((l.bowlX - 0.8 * bw) / l.aspect, l.bowlRim + 0.03, (l.bowlX + 0.8 * bw) / l.aspect,
                          l.bowlRim + 0.03 + 0.35 * l.steamHeight)

        // Keys: pale hinoki naturals and black lacquer sharps along the table's edge, lantern amber where you play.
        keyInstances.removeAll(keepingCapacity: true)
        if keysShow {
            let bottomY: Float = -0.995, gap: Float = 0.0015
            let light = min(1, simd_reduce_add(roomLight) / 3 * 2.2 + 0.05)
            for k in frame.keys {
                let x0 = -0.995 + k.key.x * 1.99 + gap, x1 = -0.995 + (k.key.x + k.key.width) * 1.99 - gap
                let y0 = k.key.isBlack ? keyTop - (keyTop - bottomY) * 0.62 : bottomY
                keyInstances.append(KeyInstance(rect: SIMD4(x0, y0, x1, keyTop),
                                                info: SIMD4(k.key.isBlack ? 1 : 0, k.glow, k.pressed ? 1 : 0, light)))
            }
        }

        post = PostSettings(
            bloom: 0.45, bloomThreshold: 0.95,
            dof: 0, focusDepth: 0.1,
            grade: 0, grain: 0.02, vignette: 0.32,
            exposure: limited.exposure,
            warmth: MoodLook.warmthOffset(mood) + 0.05 * night - 0.03 * day * (1 - sunThrough),
            time: time, quality: quality)
    }

    /// The opening in the render target's pixels (nil while it is shut or under a pixel wide).
    private func openingPixels(width: Int, height: Int) -> MTLScissorRect? {
        guard drawsGarden, width > 0, height > 0 else { return nil }
        let r = openingRect
        let x0 = max(0, min(width, Int(((r.x + 1) / 2 * Float(width)).rounded(.down))))
        let x1 = max(0, min(width, Int(((r.z + 1) / 2 * Float(width)).rounded(.up))))
        let y0 = max(0, min(height, Int(((1 - r.w) / 2 * Float(height)).rounded(.down))))
        let y1 = max(0, min(height, Int(((1 - r.y) / 2 * Float(height)).rounded(.up))))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)   // the supercell's impostor, before the frame's passes
        guard let target = stack.hdrTarget, let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let skyU = sky.uniforms
        func bind(_ vertexRect: SIMD4<Float>?) {
            skyU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            teaU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            if var r = vertexRect { e.setVertexBytes(&r, length: MemoryLayout<SIMD4<Float>>.size, index: 2) }
        }
        // Through the opening only: the sky, the garden, then the snow falling beyond the screens.
        if let clip = openingPixels(width: target.width, height: target.height) {
            e.setScissorRect(clip)
            sky.draw(e)
            e.setRenderPipelineState(garden)
            bind(openingRect)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            weather.draw(e)
            e.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
        }
        // The paper, its frost (Frost Grow) and the kumiko and stiles, then the room around and in front of the screens.
        e.setRenderPipelineState(paper)
        bind(spanRect)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        for g in glass {
            if showFrost { g.drawGlass(e, blur: nil) }
            g.drawFrame(e)
        }
        e.setRenderPipelineState(room)
        bind(nil)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // The tea's steam over everything behind it, then the keys.
        let l = layout
        let reach = 1.6 * l.bowlHalfWidth + 0.22
        e.setRenderPipelineState(steam)
        bind(SIMD4((l.bowlX - reach) / l.aspect, l.bowlRim - 0.04, (l.bowlX + reach) / l.aspect, min(1, l.bowlRim + 1.2 * l.steamHeight)))
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if !keyInstances.isEmpty {
            e.setRenderPipelineState(keys)
            keyInstances.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            teaU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: keyInstances.count)
        }
        e.endEncoding()
    }
}
