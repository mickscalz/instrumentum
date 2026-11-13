import Metal
import simd
import InStrumCore

/// A window between a room and its view (spec §7): panes in rows and columns, bars between them, a frame around.
struct WindowSpec: Equatable {
    enum Material: Equatable {
        case logWood, paintedSash, paperScreen
        /// The porthole's brass ring (with `Shape.round`): 12 bolts and a rubber gasket.
        case brass
        /// A car's cabin round a windscreen (with `Shape.windscreen`): the dashboard, the A-pillars, the roof lining.
        case carCabin
    }
    /// Panes in rows and columns, or one round pane inscribed in `rect` (a porthole: a circle when the rect is square
    /// on screen, as `WindowSpec.porthole` makes it; its columns, rows and bar are ignored), or a car's windscreen
    /// (`WindowSpec.windscreen`: its outline and wipers in `windscreen`; drawn by the `WindscreenLayer`).
    enum Shape: Equatable { case panes, round, windscreen }

    var columns: Int
    var rows: Int
    /// The bars' width as a fraction of the glass width.
    var bar: Float
    /// NDC x0, y0, x1, y1 of the glass.
    var rect: SIMD4<Float>
    var material: Material
    /// The outer frame's width in NDC x (its height on screen matches it).
    var frameWidth: Float
    /// `.panes` (the default) or `.round`, a porthole drawn in the brass ring whatever the material, or `.windscreen`.
    var shape: Shape = .panes
    /// A windscreen's outline and wipers (nil for every other window).
    var windscreen: Windscreen? = nil

    /// Columns and rows as the frost field lays them out (it caps them at 12 × 8).
    var layout: (columns: Int, rows: Int) { (min(max(columns, 1), 12), min(max(rows, 1), 8)) }

    /// Each pane in window coordinates (x0, y0, x1, y1: 0…1 across the glass, y up), laid out exactly as the
    /// frost field's panes, so frost never grows under a bar.
    func panes() -> [SIMD4<Float>] {
        let w = Float(FrostField.width), h = Float(FrostField.height)
        return FrostField.paneRects(columns: columns, rows: rows, bar: bar).map {
            SIMD4(Float($0.x0) / w, 1 - Float($0.y1 + 1) / h, Float($0.x1 + 1) / w, 1 - Float($0.y0) / h)
        }
    }

    /// The bars between panes: (lo, hi, kind, 0), where kind 0 is vertical (lo and hi are x) and 1 horizontal (y).
    func bars() -> [SIMD4<Float>] {
        let p = panes()
        let (cols, rws) = layout
        guard p.count == cols * rws else { return [] }
        var out: [SIMD4<Float>] = []
        for c in 0..<(cols - 1) { out.append(SIMD4(p[c].z, p[c + 1].x, 0, 0)) }
        for r in 0..<(rws - 1) { out.append(SIMD4(p[(r + 1) * cols].w, p[r * cols].y, 1, 0)) }
        return out
    }

    /// Window coordinates (0…1, y up) to NDC.
    func ndc(_ w: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(rect.x, rect.y) + w * SIMD2(rect.z - rect.x, rect.w - rect.y)
    }
}

/// The porthole's geometry (spec §7.4): one round pane in a thick brass ring with 12 bolts and a rubber gasket.
extension WindowSpec {
    /// The ring's bolts, evenly round it with the first at 12 o'clock.
    static let portholeBolts = 12
    static let boltPhase: Float = .pi / 2
    /// Across the ring (fractions of its width, 0 at the glass … 1 at its outside): the bolts' centres, their hex heads'
    /// radius and the rubber gasket against the glass.
    static let boltCircle: Float = 0.58, boltHead: Float = 0.16, gasket: Float = 0.1

    /// A round brass porthole centred at `centre` (NDC), `height` tall (NDC), square on a screen of `aspect` (w/h), its
    /// ring `frameWidth` wide (NDC x, as every Window Kit frame; on screen it is as wide all round).
    static func porthole(centre: SIMD2<Float>, height: Float, aspect: Float, frameWidth: Float) -> WindowSpec {
        let a: Float = aspect.isFinite && aspect > 0.1 ? min(aspect, 10) : 16.0 / 9
        let halfH = height / 2, halfW = height / 2 / a
        return WindowSpec(columns: 1, rows: 1, bar: 0,
                          rect: SIMD4(centre.x - halfW, centre.y - halfH, centre.x + halfW, centre.y + halfH),
                          material: .brass, frameWidth: frameWidth, shape: .round)
    }

    /// Round glass: its centre (NDC) and radius in NDC-y units (screen x × aspect, y).
    var circle: (centre: SIMD2<Float>, radius: Float) {
        (SIMD2((rect.x + rect.z) / 2, (rect.y + rect.w) / 2), (rect.w - rect.y) / 2)
    }

    /// The brass ring's bolt centres in NDC on a screen of `aspect` (none for pane windows): what the ring draws.
    func bolts(aspect: Float) -> [SIMD2<Float>] {
        guard shape == .round else { return [] }
        let (c, r) = circle
        let radius = r + Self.boltCircle * frameWidth * aspect
        return (0..<Self.portholeBolts).map { k in
            let a = Self.boltPhase + Float(k) * 2 * .pi / Float(Self.portholeBolts)
            return SIMD2(c.x + radius * cos(a) / aspect, c.y + radius * sin(a))
        }
    }

    /// Whether a window point (0…1, y up) is on the glass: inside the circle for round glass, anywhere for panes.
    func onGlass(_ w: SIMD2<Float>) -> Bool {
        shape == .panes || simd_length(w - SIMD2<Float>(0.5, 0.5)) <= 0.5
    }
}

/// A car's windscreen (Fire & Neon spec §9.1): seen from the passenger seat, between the dashboard, the A-pillars and the
/// roof lining, a rear-view mirror at the car's centre, and two wiper blades sweeping up from their rest along the bottom.
/// The blades' rate is the Core `Wipers`' (it follows the rain); the `WindscreenLayer` draws the rain on the glass, the
/// blades and the cabin.
extension WindowSpec {
    struct Windscreen: Equatable {
        /// The dashboard's line, y = dash + dashCurve·x², and the roof lining's, y = roof − roofCurve·x² (NDC).
        var dash: Float
        var dashCurve: Float
        var roof: Float
        var roofCurve: Float
        /// The A-pillars' inner edges: x at the dashboard and x at the roof (NDC), left and right.
        var leftPillar: SIMD2<Float>
        var rightPillar: SIMD2<Float>
        /// The rear-view mirror: centre (NDC) and half size (NDC).
        var mirror: SIMD4<Float>
        /// The blades: pivot (x in aspect units, y NDC; under the dashboard), the rubber's inner and outer radius (NDC y).
        var blades: [SIMD4<Float>]
        /// Where the blades rest (rad, from the pivot) and how far they sweep (rad; negative turns up and to the right).
        var restAngle: Float
        var sweep: Float

        /// Whether a point (NDC) is on the glass: over the dashboard, under the roof, between the pillars.
        func onGlass(_ p: SIMD2<Float>) -> Bool {
            let dy = dash + dashCurve * p.x * p.x, ry = roof - roofCurve * p.x * p.x
            guard p.y > dy, p.y < ry else { return false }
            let f = (p.y - dy) / max(ry - dy, 1e-3)
            let lx = leftPillar.x + (leftPillar.y - leftPillar.x) * f
            let rx = rightPillar.x + (rightPillar.y - rightPillar.x) * f
            return p.x > lx && p.x < rx
        }

        /// A blade's ends (NDC) at `angle` (0 parked … 1 the top of its sweep) on a screen of `aspect`.
        func blade(_ i: Int, at angle: Float, aspect: Float) -> (inner: SIMD2<Float>, outer: SIMD2<Float>) {
            let b = blades[min(max(i, 0), blades.count - 1)]
            let a = restAngle + sweep * min(1, max(0, angle))
            let dir = SIMD2<Float>(cos(a), sin(a))
            let inner = SIMD2<Float>(b.x, b.y) + dir * b.z
            let outer = SIMD2<Float>(b.x, b.y) + dir * b.w
            let k = max(aspect, 0.1)
            return (SIMD2(inner.x / k, inner.y), SIMD2(outer.x / k, outer.y))
        }
    }

    /// The passenger's view of a windscreen on a screen of `aspect` (w/h): the dashboard low across the bottom (it holds
    /// the keys' strip), the near pillar leaning in on the left, the far one a sliver on the right, the mirror right of
    /// centre (the car's centreline), the blades resting along the bottom and sweeping to about upright.
    static func windscreen(aspect: Float) -> WindowSpec {
        let a: Float = aspect.isFinite && aspect > 0.1 ? min(aspect, 10) : 16.0 / 9
        let shape = Windscreen(dash: -0.7, dashCurve: 0.06, roof: 0.93, roofCurve: 0.05,
                               leftPillar: SIMD2(-0.99, -0.7), rightPillar: SIMD2(1.03, 0.88),
                               mirror: SIMD4(0.22, 0.78, 0.15, 0.055),
                               blades: [SIMD4(-0.31 * a, -0.86, 0.2, 1.0), SIMD4(0.45 * a, -0.86, 0.2, 1.08)],
                               restAngle: Float.pi - 0.2, sweep: -1.5)
        return WindowSpec(columns: 1, rows: 1, bar: 0, rect: SIMD4(-0.99, -0.7, 1.0, 0.93), material: .carCabin,
                          frameWidth: 0.05, shape: .windscreen, windscreen: shape)
    }
}

/// A warm clear patch on the glass, in window coordinates (0…1, y up); the radius is a fraction of the width.
struct GlassPatch: Equatable { var x, y, radius, warmth: Float }

/// The Window Kit's glass and frame (spec §7.2, §7.3): frost thresholded from a grown field (with warm patches,
/// glints and, on High and Ultra, the blurred view it scatters), condensation, drips, stuck flakes and the room's
/// reflection; then the frame and bars in log wood or a painted sash. Made on any thread (the warm-up makes the worlds off
/// the main thread), then used on one.
final class WindowGlassLayer {
    static let maxFlakes = 40, maxDrips = 12, maxBars = 19, maxPatches = 48
    static func patchCap(_ q: QualityLevel) -> Int { q == .lite ? 24 : 48 }
    /// Round glass: the thick acrylic's barrel warp, as a share of the radius at the rim.
    static let portholeWarp: Float = 0.04

    /// The share of the glass frosted (an estimate from the field, for tests).
    private(set) var frostCoverage: Float = 0
    private(set) var stuckFlakeCount = 0
    private(set) var dripCount = 0
    private(set) var patchCount = 0
    /// Round glass: how cold the sea outside is (0…1; the submarine's depth). The colder, the wider the rim's fog.
    private(set) var cold: Float = 0
    /// Round glass: the view copy's region and the glass's centre (pixels), the warp, the cold and the bolts (count,
    /// first angle, circle, head, gasket) the ring draws.
    private(set) var portU = [SIMD4<Float>](repeating: .zero, count: 4)
    /// View copies made for round glass so far: kept, and grown only when the porthole needs a bigger one.
    private(set) var viewAllocations = 0
    /// Instance buffers made so far: a ring of three, grown only when too small (never one per frame).
    private(set) var bufferAllocations = 0
    var hasField: Bool { fieldTexture != nil }

    private struct Flake { var x, y, size, life, age, rot: Float }
    private struct Drip { var x, y, bottom, speed, phase, trail, size: Float }

    private let device: MTLDevice
    private let glassPipeline, dropPipeline, framePipeline, blurPipeline: MTLRenderPipelineState
    private let portGlassPipeline, portFramePipeline: MTLRenderPipelineState
    private let placeholder: MTLTexture
    private var fieldTexture: MTLTexture?
    /// Field cells inside panes, every sixth each way, for the coverage estimate.
    private var samples: [(x: Float, y: Float, arrival: Float)] = []
    private var blurTexture: MTLTexture?
    private var viewTexture: MTLTexture?
    private var quality: QualityLevel = .high
    private var spec = WindowSpec(columns: 1, rows: 1, bar: 0, rect: SIMD4(-1, -1, 1, 1), material: .logWood, frameWidth: 0.05)
    private var u = [SIMD4<Float>](repeating: .zero, count: 7 + 19 + 48)
    private var time: Double = 0
    private var rng = SeededRandom(seed: 0x6A55_F205)
    private var flakes: [Flake] = []
    private var drips: [Drip] = []
    private var instances: [SIMD4<Float>] = []
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    private var instanceCount = 0
    private var aspect: Float = 16.0 / 9

    /// The glass's six pipelines, the same in every world with a window: made once and shared.
    private struct Pipelines {
        let glass, drop, frame, blur, portGlass, portFrame: MTLRenderPipelineState
    }

    private static func makePipelines(_ device: MTLDevice) -> Pipelines? {
        guard let lib = ShaderCache.library(device, source: WindowKitShaders.source) else { return nil }
        func make(_ v: String, _ f: String, blend: Bool, depth: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if depth {
                d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
                if blend { d.colorAttachments[1].writeMask = [] }
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let g = make("glass_vertex", "glass_fragment", blend: true, depth: true),
              let dr = make("glassdrop_vertex", "glassdrop_fragment", blend: true, depth: true),
              let fr = make("frame_vertex", "frame_fragment", blend: false, depth: true),
              let bl = make("glass_fullscreen_vertex", "blur_down_fragment", blend: false, depth: false) else { return nil }
        guard let pg = make("glass_vertex", "port_glass_fragment", blend: true, depth: true),
              let pf = make("frame_vertex", "port_frame_fragment", blend: false, depth: true) else { return nil }
        return Pipelines(glass: g, drop: dr, frame: fr, blur: bl, portGlass: pg, portFrame: pf)
    }

    init?(device: MTLDevice) {
        guard let made = ShaderCache.shared.memo("WindowGlassLayer", device: device, { () -> Pipelines? in
            WindowGlassLayer.makePipelines(device)
        }) else { return nil }
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        pd.usage = [.shaderRead]
        guard let ph = device.makeTexture(descriptor: pd) else { return nil }
        var zero = [UInt16](repeating: 0, count: 4)
        ph.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 8)
        self.device = device
        glassPipeline = made.glass; dropPipeline = made.drop; framePipeline = made.frame; blurPipeline = made.blur
        placeholder = ph
        portGlassPipeline = made.portGlass; portFramePipeline = made.portFrame
    }

    /// Uploads the grown field once (16-bit, 0…1). Until then the glass draws a plain radial fallback.
    func setField(_ f: FrostField) {
        let w = FrostField.width, h = FrostField.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d), f.arrival.count == w * h else { return }
        var bits = f.arrival.map { UInt16((min(max($0.isFinite ? $0 : 1, 0), 1) * 65535).rounded()) }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &bits, bytesPerRow: w * 2)
        fieldTexture = tex
        samples.removeAll()
        for y in stride(from: 3, to: h, by: 6) {
            for x in stride(from: 3, to: w, by: 6) {
                let a = f.arrival[y * w + x]
                // Bars hold 0; corner nuclei are 0 too but lie at pane corners, never on a sample this far in.
                if a > 0 { samples.append(((Float(x) + 0.5) / Float(w), 1 - (Float(y) + 0.5) / Float(h), a)) }
            }
        }
    }

    // MARK: - Update

    func update(spec: WindowSpec, frost: Float, patches: [GlassPatch], condensation: Float, wetDrips: Float, snow: Float,
                reflection: SIMD4<Float>, glint: SIMD4<Float>, quality: QualityLevel, dt: Double,
                outsideLight: SIMD3<Float> = SIMD3(0.75, 0.8, 0.86), aspect: Float = 16.0 / 9, sparkle: Float = 1) {
        func clean(_ v: Float, _ hi: Float = 1) -> Float { v.isFinite ? min(max(v, 0), hi) : 0 }
        func clean3(_ v: SIMD3<Float>, _ hi: Float) -> SIMD3<Float> { SIMD3(clean(v.x, hi), clean(v.y, hi), clean(v.z, hi)) }
        let step = dt.isFinite ? min(max(dt, 0), 0.1) : 0
        let fstep = Float(step)
        self.spec = spec
        self.quality = quality
        self.aspect = aspect.isFinite && aspect > 0.1 ? min(aspect, 10) : 16.0 / 9
        time += step
        let level = clean(frost), cond = clean(condensation), wet = clean(wetDrips), snowing = clean(snow)
        let shown = Array(patches.lazy.filter {
            $0.x.isFinite && $0.y.isFinite && $0.radius.isFinite && $0.radius > 0 && $0.warmth.isFinite
        }.prefix(Self.patchCap(quality)))
        patchCount = shown.count
        let panes = spec.panes(), bars = spec.bars()
        let inside = clean3(SIMD3(glint.x, glint.y, glint.z), 4), outside = clean3(outsideLight, 8)

        u[0] = spec.rect
        u[1] = SIMD4(level, cond, Float(time.truncatingRemainder(dividingBy: 3600)), 0)
        u[2] = SIMD4(inside, clean(glint.w, 2))
        u[3] = SIMD4(clean3(SIMD3(reflection.x, reflection.y, reflection.z), 4), clean(reflection.w, 0.3))
        u[4] = SIMD4(outside, hasField ? 1 : 0)
        let material: Float = spec.material == .logWood ? 0 : 1
        let qualityCode: Float = quality == .lite ? 0 : 1
        u[5] = SIMD4(Float(shown.count), Float(min(bars.count, Self.maxBars)), material, clean(spec.frameWidth, 0.5))
        if spec.material == .paperScreen { u[5].z = 3 }   // paper is material 3 in the shader (its branches stand alone)
        u[6] = SIMD4(self.aspect, qualityCode, clean(sparkle, 2), 0)
        for i in 0..<Self.maxBars { u[7 + i] = i < bars.count ? bars[i] : .zero }
        for i in 0..<Self.maxPatches {
            u[26 + i] = i < shown.count ? SIMD4(shown[i].x, shown[i].y, shown[i].radius, clean(shown[i].warmth)) : .zero
        }
        frostCoverage = coverage(level: level, patches: shown)
        updatePortU()

        // Stuck flakes: snow landing on the glass as tiny stars that melt in 5–10 s.
        if snowing > 0.2, !panes.isEmpty {
            var expected = 6 * snowing * fstep
            while expected > 0 {
                if rng.unit() < expected, flakes.count < Self.maxFlakes {
                    let p = panes[min(Int(rng.unit() * Float(panes.count)), panes.count - 1)]
                    flakes.append(Flake(x: rng.range(p.x, p.z), y: rng.range(p.y, p.w), size: rng.range(0.004, 0.009),
                                        life: rng.range(5, 10), age: 0, rot: rng.range(0, 1.05)))
                    if spec.shape == .round {
                        let c = Self.onCircle(flakes[flakes.count - 1].x, flakes[flakes.count - 1].y)
                        flakes[flakes.count - 1].x = c.x; flakes[flakes.count - 1].y = c.y
                    }
                }
                expected -= 1
            }
        }
        for i in flakes.indices { flakes[i].age += fstep }
        flakes.removeAll { $0.age >= $0.life }
        stuckFlakeCount = flakes.count

        // Drips: from the top of the frame while wet (after rain), and now and then from the condensation band.
        if !panes.isEmpty {
            let fromTop = wet > 0.3 ? wet * 0.8 * fstep : 0
            let fromFog = 0.02 * cond * Float(panes.count) * fstep
            if rng.unit() < fromTop + fromFog, drips.count < Self.maxDrips {
                let p = panes[min(Int(rng.unit() * Float(panes.count)), panes.count - 1)]
                let top = rng.unit() * (fromTop + fromFog) < fromTop
                let y = top ? p.w - 0.01 : p.y + cond * 0.22 * (p.w - p.y) * 0.6
                drips.append(Drip(x: rng.range(p.x + 0.01, p.z - 0.01), y: y, bottom: p.y, speed: rng.range(0.08, 0.2),
                                  phase: rng.range(0, 6), trail: 0, size: rng.range(0.0035, 0.006)))
                if spec.shape == .round {
                    let c = roundDrip(x: drips[drips.count - 1].x, phase: drips[drips.count - 1].phase, fromTop: top, condensation: cond)
                    drips[drips.count - 1].x = c.x; drips[drips.count - 1].y = c.y; drips[drips.count - 1].bottom = c.bottom
                }
            }
        }
        for i in drips.indices {
            var d = drips[i]
            d.phase += fstep * 1.7
            // Drops cling, then slide in short runs.
            let run = 0.25 + 0.75 * max(0, sin(d.phase))
            let moved = d.speed * run * fstep
            d.y -= moved
            d.trail = min(d.trail + moved, 0.2)
            drips[i] = d
        }
        drips.removeAll { $0.y < $0.bottom - 0.02 }
        dripCount = drips.count

        // This frame's instances, in the next slot of the ring.
        let outsideLuma: Float = simd_dot(outside, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        let insideLuma: Float = simd_dot(inside, SIMD3<Float>(repeating: 0.33))
        let light: Float = 0.35 + 0.65 * min(1, outsideLuma + 0.3 * insideLuma)
        instances.removeAll(keepingCapacity: true)
        let width = spec.rect.z - spec.rect.x, height = spec.rect.w - spec.rect.y
        for f in flakes {
            let p = spec.ndc(SIMD2(f.x, f.y))
            let melt: Float = 1 - max(0, (f.age / f.life - 0.6) / 0.4)
            let size: Float = f.size * width * (0.6 + 0.4 * melt)
            instances.append(SIMD4(p.x, p.y, size, 0.9 * melt))
            instances.append(SIMD4(f.rot, 0, 0, light))
        }
        for d in drips {
            let p = spec.ndc(SIMD2(d.x, d.y))
            instances.append(SIMD4(p.x, p.y, d.size * width, 0.8))
            instances.append(SIMD4(0, 1, d.trail * height, light))
        }
        instanceCount = instances.count / 2
        slot = (slot + 1) % ring.count
        let bytes = instances.count * MemoryLayout<SIMD4<Float>>.stride
        if bytes > 0 {
            if (ring[slot]?.length ?? 0) < bytes {
                ring[slot] = device.makeBuffer(length: max(bytes, 16 * 1024), options: .storageModeShared)
                bufferAllocations += 1
            }
            if let buf = ring[slot] {
                instances.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
            }
        }
    }

    private func coverage(level: Float, patches: [GlassPatch]) -> Float {
        guard !samples.isEmpty else { return level }
        let squash = Float(FrostField.height) / Float(FrostField.width)
        var frosted = 0
        for s in samples {
            var clearing: Float = 0
            for p in patches {
                let dx = s.x - p.x, dy = (s.y - p.y) * squash
                let d: Float = (dx * dx + dy * dy).squareRoot()
                let c: Float = min(max((d / p.radius - 0.55) / 0.45, 0), 1)
                let m: Float = 1 - c * c * (3 - 2 * c)
                let warmth: Float = min(max(p.warmth, 0), 1)
                clearing = max(clearing, warmth * m)
            }
            if s.arrival < level * (1 - clearing) { frosted += 1 }
        }
        return Float(frosted) / Float(samples.count)
    }

    // MARK: - Drawing

    /// The glass, after the outside (and its weather) is drawn. `blur` is `makeBlur`'s copy of the view (High, Ultra).
    func drawGlass(_ e: MTLRenderCommandEncoder, blur: MTLTexture?) {
        if spec.shape == .round { drawPorthole(e, view: nil); return }
        var uu = u
        let useBlur = blur != nil && quality != .lite
        uu[1].w = useBlur ? 1 : 0
        e.setRenderPipelineState(glassPipeline)
        uu.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        e.setFragmentTexture(fieldTexture ?? placeholder, index: 0)
        e.setFragmentTexture(useBlur ? blur : placeholder, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if instanceCount > 0, let buf = ring[slot] {
            e.setRenderPipelineState(dropPipeline)
            uu.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.setVertexBuffer(buf, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }
    }

    /// The frame and bars, over the glass.
    func drawFrame(_ e: MTLRenderCommandEncoder) {
        if spec.shape == .round { drawPortholeRing(e); return }
        e.setRenderPipelineState(framePipeline)
        u.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// High and Ultra: a half-resolution copy of the view with a 4-level mip chain (kept and reused), for frosted
    /// glass to scatter. Encode it between the outside's pass and the glass's (`RenderStack.scenePassContinuing`).
    func makeBlur(from source: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        guard quality != .lite else { return nil }
        let w = max(1, source.width / 2), h = max(1, source.height / 2)
        if blurTexture?.width != w || blurTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderStack.sceneFormat, width: w, height: h, mipmapped: true)
            d.mipmapLevelCount = min(4, d.mipmapLevelCount)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            blurTexture = device.makeTexture(descriptor: d)
        }
        guard let blur = blurTexture else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = blur
        p.colorAttachments[0].level = 0
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return nil }
        e.setRenderPipelineState(blurPipeline)
        e.setFragmentTexture(source, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
        if blur.mipmapLevelCount > 1, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: blur)
            blit.endEncoding()
        }
        return blur
    }
}

/// Round glass (spec §7.4): the porthole's update, its view through the acrylic and its brass ring. A world draws:
///
///     glass.updatePorthole(spec: .porthole(...), condensation:, cold:, cabinLight:, reflection:, outsideLight:, ...)
///     // the outside (over the ring too: the warp looks 4% past the glass's edge), then:
///     e.endEncoding()
///     let view = glass.makeView(from: stack.hdrTarget!, commandBuffer: cb)    // every quality
///     e = cb.makeRenderCommandEncoder(descriptor: stack.scenePassContinuing()!)
///     glass.drawPorthole(e, view: view)
///     glass.drawFrame(e)                                                      // the ring
extension WindowGlassLayer {
    /// A porthole's update: one pane in the brass ring, its condensation and drips masked to the circle, and never any
    /// frost. It passes the glass no frost, warm patches or snow (and round glass never draws frost): this is how a
    /// world under water turns frost off.
    /// - cold: how cold the sea outside is (0…1; the submarine's depth). The colder, the wider and denser the rim's fog.
    /// - cabinLight: the cabin's light (rgb): warm highlights on the brass and the fog it lights (red at night).
    /// - reflection: the cabin faintly mirrored in the acrylic (rgb, strength ≤ 0.3).
    /// - outsideLight: the sea's average light (rgb): the ring's bevel, and the fog when no view is bound.
    func updatePorthole(spec: WindowSpec, condensation: Float, cold: Float, wetDrips: Float = 0, cabinLight: SIMD3<Float>,
                        reflection: SIMD4<Float>, outsideLight: SIMD3<Float>, quality: QualityLevel, dt: Double,
                        aspect: Float, sparkle: Float = 1) {
        self.cold = cold.isFinite ? min(max(cold, 0), 1) : 0
        var round = spec
        round.shape = .round
        round.columns = 1; round.rows = 1; round.bar = 0
        update(spec: round, frost: 0, patches: [], condensation: condensation, wetDrips: wetDrips, snow: 0,
               reflection: reflection, glint: SIMD4(cabinLight, 0), quality: quality, dt: dt,
               outsideLight: outsideLight, aspect: aspect, sparkle: sparkle)
    }

    /// Round glass: copies the view behind the porthole (the glass's square and a margin for the warp) into a kept
    /// texture, on every quality (nil for pane windows). Encode it between the outside's pass and the glass's.
    func makeView(from source: MTLTexture, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        guard spec.shape == .round, source.width > 0, source.height > 0 else { return nil }
        let w = Float(source.width), h = Float(source.height)
        let r = spec.rect
        let px = ((r.x + r.z) / 2 + 1) * 0.5 * w, py = (1 - (r.y + r.w) / 2) * 0.5 * h
        let reach = (r.w - r.y) * 0.25 * h * (1 + Self.portholeWarp) + 3
        guard px.isFinite, py.isFinite, reach.isFinite, reach > 3, reach < 4 * max(w, h) else { return nil }
        let x0 = max(0, Int((px - reach).rounded(.down))), y0 = max(0, Int((py - reach).rounded(.down)))
        let x1 = min(source.width, Int((px + reach).rounded(.up))), y1 = min(source.height, Int((py + reach).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let rw = x1 - x0, rh = y1 - y0
        if (viewTexture?.width ?? 0) < rw || (viewTexture?.height ?? 0) < rh || viewTexture?.pixelFormat != source.pixelFormat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: max(rw, viewTexture?.width ?? 0),
                                                             height: max(rh, viewTexture?.height ?? 0), mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .private
            viewTexture = device.makeTexture(descriptor: d)
            viewAllocations += 1
        }
        guard let view = viewTexture, let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: rw, height: rh, depth: 1), to: view, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        portU[0] = SIMD4(Float(x0), Float(y0), Float(rw), Float(rh))
        portU[1] = SIMD4(px, py, Self.portholeWarp, 0)
        return view
    }

    /// Round glass: the outside through the acrylic's barrel warp (from `makeView`'s copy; nil leaves the view unwarped
    /// under the glass), the rim's condensation, drips and the cabin's reflection.
    func drawPorthole(_ e: MTLRenderCommandEncoder, view: MTLTexture?) {
        var pu = portU
        pu[1].w = view == nil ? 0 : 1
        e.setRenderPipelineState(portGlassPipeline)
        u.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        pu.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        e.setFragmentTexture(view ?? placeholder, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if instanceCount > 0, let buf = ring[slot] {
            e.setRenderPipelineState(dropPipeline)
            u.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.setVertexBuffer(buf, offset: 0, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }
    }

    /// The drips' positions on the glass (window coordinates), for tests.
    var dripPositions: [SIMD2<Float>] { drips.map { SIMD2($0.x, $0.y) } }

    /// The brass ring, over the glass (`drawFrame` draws it for round glass).
    private func drawPortholeRing(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(portFramePipeline)
        u.withUnsafeBytes {
            e.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        portU.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// The ring's and the round glass's rows that don't depend on the target (`makeView` sets the view's region).
    private func updatePortU() {
        let round = spec.shape == .round
        if round { frostCoverage = 0 }   // round glass never frosts, whatever it was passed
        portU[1].z = Self.portholeWarp
        portU[2] = SIMD4(cold, round ? Float(WindowSpec.portholeBolts) : 0, WindowSpec.boltPhase, WindowSpec.boltCircle)
        portU[3] = SIMD4(WindowSpec.boltHead, WindowSpec.gasket, 0, 0)
    }

    /// Round glass: where a new drip goes on the circle (window coordinates, radius 0.5), given where it was drawn
    /// across the pane and its phase (0…6): across the circle's middle 84%, starting just under the top edge (after
    /// rain) or in the fog at the upper rim, and running off at the circle's bottom edge.
    private func roundDrip(x: Float, phase: Float, fromTop: Bool, condensation: Float) -> (x: Float, y: Float, bottom: Float) {
        let across: Float = 0.5 + (min(max(x, 0), 1) - 0.5) * 0.84
        let half: Float = max(0, 0.25 - (across - 0.5) * (across - 0.5)).squareRoot()
        let band: Float = 0.5 * condensation * (0.1 + 0.16 * cold)
        let into: Float = band * (0.3 + 0.7 * min(max(phase / 6, 0), 1))
        // Drips run off 0.02 below their bottom: this one goes as it reaches the gasket, still on the glass.
        return (across, fromTop ? 0.5 + half - 0.01 : 0.5 + half - into, 0.5 - half + 0.025)
    }

    /// Round glass: a new flake pulled inside the circle, clear of the rim (window coordinates).
    private static func onCircle(_ x: Float, _ y: Float) -> SIMD2<Float> {
        let c = SIMD2<Float>(x - 0.5, y - 0.5)
        let r = simd_length(c)
        return r > 0.46 ? SIMD2<Float>(0.5, 0.5) + c * (0.46 / r) : SIMD2(x, y)
    }
}
