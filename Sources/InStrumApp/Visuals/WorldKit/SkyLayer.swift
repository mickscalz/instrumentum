import Metal
import CoreGraphics
import simd
import InStrumCore

/// Where weather lands in a world.
enum WeatherSurface { case water(horizonY: Float), ground(horizonY: Float), glass, none }

/// The real-star texture (`StarTexture`, 2048 × 1024 RGBA8), built once per process on a background queue and
/// uploaded on the main actor; every SkyLayer shares it. Until it arrives the sky draws its procedural stars.
@MainActor
final class StarTextureCache {
    static let shared = StarTextureCache()
    /// The uploaded texture (nil until the build lands, or while `withheld`).
    var texture: MTLTexture? { withheld ? nil : built }
    /// Tests: draw every sky as if the texture had not arrived yet (the procedural fallback).
    var withheld = false
    private var built: MTLTexture?
    /// How many times the image has been built (one per process).
    private(set) var builds = 0
    private var device: MTLDevice?

    /// Starts the build the first time any sky asks (later calls do nothing).
    func request(device: MTLDevice) {
        guard self.device == nil else { return }
        self.device = device
        builds += 1
        DispatchQueue.global(qos: .utility).async {
            let bytes = StarTexture.build()
            DispatchQueue.main.async { MainActor.assumeIsolated { StarTextureCache.shared.upload(bytes) } }
        }
    }

    /// Waits (running the main run loop) until the texture has arrived; for previews and tests.
    @discardableResult
    func awaitTexture(timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while built == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return built != nil
    }

    private func upload(_ bytes: [UInt8]) {
        guard let device, built == nil else { return }
        built = Self.makeTexture(device: device, bytes: bytes)
    }

    /// An RGBA8 2048 × 1024 texture from `StarTexture.build(lines:)`'s bytes (nil if the size is wrong).
    static func makeTexture(device: MTLDevice, bytes: [UInt8]) -> MTLTexture? {
        let w = StarTexture.width, h = StarTexture.height
        guard bytes.count == w * h * 4 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
    }
}

/// Draws the Living Sky dome into a world's scene pass (writes depth 1.0, behind everything).
/// The camera looks at a chosen azimuth with the horizon at `horizonY` (NDC).
@MainActor
final class SkyLayer {
    /// Face the equator by default, where the sun and moon cross the sky.
    nonisolated static func defaultViewAzimuth(latitude: Double) -> Double { latitude < 0 ? 0 : 180 }

    var viewAzimuth: Double?
    var horizonY: Float = -0.33
    var verticalFOV: Double = 60
    /// The view's roll in degrees (a road's gentle curves); 0 keeps the horizon level.
    var roll: Double = 0
    /// Apparent sizes are enlarged for the screen (real: 0.26°), as a long lens would show them.
    var moonRadiusDegrees: Double = 1.25
    var sunRadiusDegrees: Double = 0.9

    /// Aurora ripples from a world's visual (Curtain Lights): position 0…1 along the band, age (s), strength, width.
    /// Up to 8; zero strength is no ripple.
    var ripples = [SIMD4<Float>](repeating: .zero, count: 8)
    /// The aurora's hue shift (−1 cool … +1 warm) and glow (0…1), from a world's visual; zero by default.
    var auroraTint = SIMD2<Float>(0, 0)
    /// Tests: a texture to use instead of the shared one.
    var starTextureOverride: MTLTexture?

    nonisolated static let rippleCount = 8
    /// SkyU's float4 count: 13 + night, aurora, dust, 8 ripples, still, the 6 meteor slots' three rows and the flash (44),
    /// then Fire & Neon's (spec §6–§7): the far storm and its flicker, the 3 sprites' two rows, the 4 satellites' three
    /// rows, the supercell's three and the ash (the MSL struct's size / 16: 1088 bytes, still one setFragmentBytes).
    nonisolated static let uniformCount = 68
    /// The `still` row's index: iridescence, rime, and the wind on screen.
    nonisolated static let stillRow = 24
    /// The shooting stars' slots (spec §7.2), after `still`: six of each row. A: start direction, head progress 0…1 (a
    /// train: its drift, degrees). B: end direction, light on the stars' scale (0: the slot is empty). C: colour, 0 for
    /// a head … the train's age 0.001…1.
    nonisolated static let meteorSlots = 6
    nonisolated static let meteorARow = 25, meteorBRow = 31, meteorCRow = 37
    /// A fireball's sky brightening (meteorFlash, 0, 0, 0).
    nonisolated static let flashRow = 43
    /// Fire & Neon (spec §6.1): the far storm (its bearing as a unit vector east and north, how much of it, its anvil's
    /// top in degrees) and its in-cloud lightning (level after the limiter, degrees across from its centre, how far up it
    /// 0…1, its width in degrees); the red sprites' slots, two rows each (A: azimuth°, base°, height°, brightness, 0 for
    /// an empty slot; B: columns with the streamers × 0.9 in the fraction, spread°, shape, seed).
    nonisolated static let stormRow = 44, stormFlickerRow = 45
    nonisolated static let spriteSlots = 3
    nonisolated static let spriteARow = 46, spriteBRow = 49
    /// Fire & Neon (spec §6.2): the satellites' slots, three rows each (A: the lead's direction and its light on the stars'
    /// scale, 0 for an empty slot; B: its motion across the sky as a unit vector × a train's spacing in radians, and its
    /// member count; C: the train's shadow edge as a member index (−1: none), +1 lit behind it / −1 before it, the real
    /// stars' footprint (radians), how red the sunlight on it is).
    nonisolated static let satelliteSlots = 4
    nonisolated static let satARow = 52, satBRow = 56, satCRow = 60
    /// Fire & Neon (spec §7): the supercell weather's three rows and the ash's (the last).
    nonisolated static let cellARow = 64, cellBRow = 65, cellCRow = 66, ashRow = 67

    /// Far storms (and the supercell weather) are staged where the world looks, as an "Always" aurora is: each one stands
    /// at the view's azimuth plus a seeded offset (±20°) from the moment it appears, and stays put there (the camera's
    /// drift never moves it); its sprites keep their places about it. Returns the shift (degrees) to add to the sky's
    /// bearings, and the anchor to keep.
    nonisolated static func stage(episode: Int, bearing: Float, viewAzimuth: Double,
                                  anchor: (episode: Int, azimuth: Double)?) -> (shift: Double, anchor: (episode: Int, azimuth: Double)) {
        var a: (episode: Int, azimuth: Double) = anchor ?? (episode: episode, azimuth: 0.0)
        if anchor == nil || anchor?.episode != episode {
            let b = Double(bearing.isFinite ? bearing : 0)
            let offset = (b - 40 * (b / 40).rounded(.down)) - 20   // −20…20°, seeded by the storm's own bearing
            a = (episode: episode, azimuth: (viewAzimuth.isFinite ? viewAzimuth : 0) + offset)
        }
        var shift = (a.azimuth - Double(bearing.isFinite ? bearing : 0)).truncatingRemainder(dividingBy: 360)
        if shift < 0 { shift += 360 }
        return (shift, a)
    }

    /// The sprite rows for a sprite shifted `shift` degrees (nil: unlit).
    nonisolated static func spriteRows(_ p: SpriteSlot, shift: Double) -> (a: SIMD4<Float>, b: SIMD4<Float>)? {
        guard p.brightness.isFinite, p.brightness > 0 else { return nil }
        var az = (Double(p.azimuth) + shift).truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        let columns = Float(min(3, max(1, p.columns)))
        let streamers = min(1, max(0, p.streamers.isFinite ? p.streamers : 0))
        return (SIMD4(Float(az), p.base, max(0.5, p.height), min(RedSprites.brightest, p.brightness)),
                SIMD4(columns + 0.9 * streamers, p.spread, min(1, max(0, p.shape)), min(1, max(0, p.seed))))
    }

    /// The satellite rows (nil: unlit or unusable).
    nonisolated static func satelliteRows(_ t: SatelliteSlot) -> (a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>)? {
        func usable(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite && abs(simd_length(v) - 1) < 0.01 }
        guard t.light.isFinite, t.light > 0, usable(t.direction) else { return nil }
        let count = t.kind == .train ? max(1, t.count) : 1
        let spacing = count > 1 && t.spacing.isFinite ? max(0, t.spacing) : 0
        let tangent = usable(t.tangent) ? t.tangent : SIMD3<Float>(0, 0, 0)
        return (SIMD4(t.direction, t.light), SIMD4(tangent * spacing, Float(count)),
                SIMD4(t.shadowMember.isFinite ? t.shadowMember : -1, t.litBehind ? 1 : -1,
                      Satellites.footprint(magnitude: t.magnitude.isFinite ? t.magnitude : 6), min(1, max(0, t.redden))))
    }

    /// The wind on screen for rime's windward side (x right, y up: the way it blows, × the sky's wind 0…1). Every
    /// world already draws its weather blowing to the right (the weather layer's tilt and streamers, the chimney
    /// smoke, the diamond dust's drift), so rime gathers on the left-facing edges.
    nonisolated static func screenWind(_ s: SkyState) -> SIMD2<Float> {
        SIMD2(s.wind.isFinite ? min(1, max(0, s.wind)) : 0, 0)
    }

    /// A shooting star's three SkyU rows at `t` on the meteors' clock (`SkyState.meteorTime`), from Core's own light
    /// curves: a head (start, progress; end, its light now; colour, 0) or a train (start, its drift in degrees; end, its
    /// light now; the train's colour, its age, at least 0.001); nil when it is neither (not yet born, or gone), unlit, or
    /// not a pair of unit directions.
    nonisolated static func meteorRows(_ m: Meteor, at t: Double) -> (a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>)? {
        func usable(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite && abs(simd_length(v) - 1) < 0.01 }
        guard t.isFinite, usable(m.start), usable(m.end) else { return nil }
        if m.isHead(at: t) {
            let light = m.headBrightness(at: t)
            guard light.isFinite, light > 0 else { return nil }
            return (SIMD4(m.start, m.progress(at: t)), SIMD4(m.end, light), SIMD4(m.colour, 0))
        }
        guard let age = m.trainAge(at: t) else { return nil }
        let light = m.trainBrightness(at: t)
        guard light.isFinite, light > 0 else { return nil }
        return (SIMD4(m.start, m.trainDrift), SIMD4(m.end, light), SIMD4(Meteor.trainColour, max(1e-3, age)))
    }

    /// The NDC y where flat water `out` metres ahead lies, seen from `height` metres above it by a level camera (no roll)
    /// with the horizon at `horizonY` and a lens `verticalFOV` degrees tall: how a world finds its water's near edge.
    nonisolated static func waterY(out: Float, height: Float, horizonY: Float, verticalFOV: Double) -> Float {
        let tanV = Float(tan(verticalFOV * .pi / 360))
        let pitch = -atan(horizonY * tanV)
        let depression = atan(height / max(out, 1e-3))
        return -tan(depression + pitch) / tanV
    }

    /// Where the current far storm is staged (its episode and azimuth), and the shift last applied (tests read it).
    private var stormAnchor: (episode: Int, azimuth: Double)?
    private(set) var stormShift: Double = 0
    private var cellAnchor: (episode: Int, azimuth: Double)?

    private let pipeline: SkyPipeline
    /// The dome's library (its supercell impostor's kernel is made from it the first time a supercell shows).
    private let library: MTLLibrary
    /// Whether this frame's sky needs the storm program (`SkySpecialisation`): a supercell, ash, a far storm or a sprite
    /// in its rows. Every world drawing the sky in its own pass picks its pipeline by it.
    private(set) var storms = false
    /// Which program this frame's sky needs: the supercell's alone when it is the only storm weather (`SkySpecialisation`).
    /// Worlds that read the supercell's impostor pick their pipeline by it; the rest by `storms`.
    private(set) var program: SkyProgram = .plain
    /// Tests: draw with the storm program whatever the sky (a plain sky must look the same either way).
    var forceStormProgram = false {
        didSet { chooseProgram() }
    }
    private func chooseProgram() {
        program = forceStormProgram ? .storms : SkySpecialisation.program(u)
        storms = program != .plain
    }
    /// Gentle visuals: the supercell's lightning only glows in its cloud, never flashes.
    var gentle = false
    /// The supercell's lightning in its cloud (its light 0…1) goes through its own flash limiter: at most three large
    /// jumps a second; under gentle visuals never more than a glow (`gentleCellGlow`, under the limiter's flash rise,
    /// and its rise halved). `cellGlowOut` is what drew (tests).
    nonisolated static let gentleCellGlow: Float = 0.2
    private var glowLimiter = FlashLimiter()
    private var lastTime: Float?
    private(set) var cellGlowOut: Float = 0
    /// A 1×1 black texture bound while the real stars build, so no pass ever lacks texture 0.
    private let placeholder: MTLTexture
    private var u = [SIMD4<Float>](repeating: .zero, count: SkyLayer.uniformCount)

    /// The real stars (nil until the shared background build arrives).
    var starTexture: MTLTexture? {
        if StarTextureCache.shared.withheld { return nil }
        return starTextureOverride ?? StarTextureCache.shared.texture
    }

    /// The SkyU uniforms, for worlds whose shaders reflect the sky (bind at the same index as the dome: 0, and the
    /// stars with `bindStars`). eq0.w says whether the real stars are bound.
    var uniforms: [SIMD4<Float>] {
        var c = u
        c[8].w = starTexture == nil ? 0 : 1
        return c
    }

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: SkyShaders.source, options: nil),
              let p = SkyPipeline(program: { program in
                  let d = MTLRenderPipelineDescriptor()
                  d.vertexFunction = lib.skyFunction("sky_dome_vertex", program: program)
                  d.fragmentFunction = lib.skyFunction("sky_dome_fragment", program: program)
                  d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
                  d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
                  return try? device.makeRenderPipelineState(descriptor: d)
              }) else { return nil }
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        pd.usage = [.shaderRead]
        guard let ph = device.makeTexture(descriptor: pd) else { return nil }
        var black: [UInt8] = [0, 0, 0, 0]
        ph.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
        pipeline = p
        placeholder = ph
        library = lib
        // The limiter starts from black: settle it on no light first, so the first frame is never a flash.
        for _ in 0..<16 { _ = glowLimiter.limit(exposure: 1, sparkle: 0, dt: 1) }
        StarTextureCache.shared.request(device: device)
    }

    /// Binds the real stars (or the placeholder) at fragment texture 0, for any pass whose shader calls skyRadiance, and
    /// the supercell's impostor (or the placeholder) at `cellTextureIndex`, for those that read it.
    func bindStars(_ e: MTLRenderCommandEncoder) {
        e.setFragmentTexture(starTexture ?? placeholder, index: 0)
        e.setFragmentTexture(cellTexture ?? placeholder, index: Self.cellTextureIndex)
    }

    // ---------------------------------------------------------------- the supercell's impostor (Fire & Neon fix pass)
    // The supercell weather changes over minutes, so it is drawn into a texture the sky samples (at the world's own
    // quality, for the cost of a lookup a pixel): a window in azimuth and altitude round the view. No frame ever draws
    // more than a 32nd of it (every 32nd row), so none spikes, even on a slow graphics chip. The texture holds
    // three snapshots: while one is filled a strip a frame, the sky shows the other two cross-fading from the older to the
    // newer as the fill goes on (so the storm moves smoothly, a fill behind, never in torn rows); when the fill is whole it
    // becomes the newer. A new window (the view swung past the one shown) is filled the same way and shown alone once
    // whole. Each snapshot's upper half is the storm's light (premultiplied) and how much of the sky shows through; its
    // lower half how its cloud takes the lightning's light, which the sky adds each frame round the strike (so a flash
    // never waits). Allocated once, kept. Previews and tests (`cellAtOnce`) draw a snapshot whole when they need one.

    /// The fragment texture index the impostor is bound at (beside the stars at 0, clear of every world's own).
    nonisolated static let cellTextureIndex = 9
    /// Its size: columns, and rows in each half of a snapshot (three snapshots, six halves, one texture).
    nonisolated static let cellColumns = 1280, cellRows = 448, cellSlots = 3
    /// How many frames one snapshot is drawn over.
    nonisolated static let cellStrips = 32
    /// Previews and tests: a snapshot drawn whole when one is needed (a still frame has no frames after it).
    static var cellAtOnce = false
    private var cellKernel: MTLComputePipelineState?
    private var cellKernelTried = false
    private(set) var cellTexture: MTLTexture?
    /// Each snapshot's window: its centre's azimuth, its half-width, its bottom and top altitudes (radians, east-north-up).
    private var cellWindows = [SIMD4<Float>](repeating: .zero, count: 3)
    private var cellWhole = [false, false, false]
    /// The snapshot being filled, the newer and the older shown (−1: none).
    private var cellFill = 0, cellNewer = -1, cellOlder = -1
    private var cellFillStrip = 0
    /// The window the fills draw now.
    private(set) var cellWindow = SIMD4<Float>(0, 0, 0, 0)
    private var cellClock: Float = .nan
    private var cellPhase: Float = -1
    /// Tests: how many snapshots were drawn whole in one frame, and how many single strips were drawn.
    private(set) var cellWholeDraws = 0, cellStripDraws = 0

    /// The window a view needs (its frame's edges in azimuth and altitude, with no margin), from the camera rows.
    nonisolated static func cellWindowNeeded(_ u: [SIMD4<Float>]) -> SIMD4<Float> {
        let right = SIMD3(u[0].x, u[0].y, u[0].z), up = SIMD3(u[1].x, u[1].y, u[1].z), fwd = SIMD3(u[2].x, u[2].y, u[2].z)
        let tanH = u[0].w, tanV = u[1].w
        let centre = atan2(fwd.x, fwd.y)
        var half: Float = 0, top: Float = -1
        // (Round the frame's edges and across its middle, nine points each: no arrays, nothing allocated a frame.)
        for i in 0..<45 {
            let s = Float(i % 9) / 4 - 1
            let side = i / 9
            let x: Float = side == 2 ? 1 : (side == 3 ? -1 : s)
            let y: Float = side == 0 ? 1 : (side == 1 ? -1 : (side == 4 ? 0 : s))
            let d = simd_normalize(fwd + right * (x * tanH) + up * (y * tanV))
            var da = atan2(d.x, d.y) - centre
            da -= 2 * .pi * (da / (2 * .pi)).rounded()
            if d.z > -0.05 { half = max(half, abs(da)) }
            top = max(top, asin(min(1, max(-1, d.z))))
        }
        return SIMD4(centre, half, -0.05, top)
    }

    /// Whether `window` holds everything `need` asks for.
    nonisolated static func cellWindow(_ window: SIMD4<Float>, covers need: SIMD4<Float>) -> Bool {
        guard window.y > 0 else { return false }
        var dc = need.x - window.x
        dc -= 2 * .pi * (dc / (2 * .pi)).rounded()
        return abs(dc) + need.y <= window.y + 1e-4 && need.w <= window.w + 1e-4
    }

    /// The window for a view: what it needs with room to turn (10° each side, 6° over its top), at most all round.
    nonisolated static func cellWindowFor(_ need: SIMD4<Float>) -> SIMD4<Float> {
        let deg: Float = .pi / 180
        return SIMD4(need.x, min(.pi, need.y + 10 * deg), -3 * deg, min(.pi / 2, max(20 * deg, need.w + 6 * deg)))
    }

    private func cellPipeline() -> MTLComputePipelineState? {
        if let k = cellKernel { return k }
        guard !cellKernelTried else { return nil }
        cellKernelTried = true
        guard let f = library.skyFunction("sky_cell_impostor", storms: true) else { return nil }
        cellKernel = try? library.device.makeComputePipelineState(function: f)
        return cellKernel
    }

    private func cellImpostor() -> MTLTexture? {
        if let t = cellTexture { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.cellColumns,
                                                         height: 2 * Self.cellSlots * Self.cellRows, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        cellTexture = library.device.makeTexture(descriptor: d)
        return cellTexture
    }

    /// Encodes rows `first`, `first + strips`, … of snapshot `slot`, drawn in the window `cellWindow`.
    private func encodeCell(_ cb: MTLCommandBuffer, kernel: MTLComputePipelineState, texture: MTLTexture, slot: Int,
                            first: Int, strips: Int) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        u[9].w = cellWindow.x; u[10].w = cellWindow.y
        u[Self.flashRow].y = cellWindow.z; u[Self.flashRow].z = cellWindow.w
        var job = SIMD4<UInt32>(UInt32(first), UInt32(strips), UInt32(Self.cellRows), UInt32(2 * slot * Self.cellRows))
        enc.setComputePipelineState(kernel)
        u.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setBytes(&job, length: MemoryLayout<SIMD4<UInt32>>.size, index: 1)
        enc.setTexture(texture, index: 0)
        let tw = max(1, kernel.threadExecutionWidth)
        let th = max(1, min(8, kernel.maxTotalThreadsPerThreadgroup / tw))
        let rows = (Self.cellRows - first + strips - 1) / strips
        enc.dispatchThreadgroups(MTLSize(width: (Self.cellColumns + tw - 1) / tw, height: (rows + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        if strips == 1 { cellWholeDraws += 1 } else { cellStripDraws += 1 }
    }

    /// Draws this frame's share of the supercell's impostor into `cb` (before the frame's own passes: one strip, never
    /// more, outside previews) and marks the sky's rows to read it: the window shown in eq1.w, eq2.w and the flash row's
    /// y and z; its w 1 + (3 × the older snapshot + the newer) + 0.9 × how far from the older to the newer (0 when there
    /// is none to show). Every renderer that draws the sky calls it first in `render`; without it (or with no supercell)
    /// the rows say no impostor, and the sky draws the supercell itself (`skyRadiance` without the texture) or none.
    func prepare(_ cb: MTLCommandBuffer) {
        u[9].w = 0; u[10].w = 0
        u[Self.flashRow].y = 0; u[Self.flashRow].z = 0; u[Self.flashRow].w = 0
        guard u[Self.cellARow].w > 0, storms else {
            cellWhole = [false, false, false]; cellNewer = -1; cellOlder = -1; cellFillStrip = 0
            return
        }
        guard let kernel = cellPipeline(), let texture = cellImpostor() else { return }
        let need = Self.cellWindowNeeded(u)
        if !Self.cellWindow(cellWindow, covers: need) {
            // A new window: the fill starts again in it (what is shown stays until it is whole).
            cellWindow = Self.cellWindowFor(need)
            cellFillStrip = 0
        }
        let clock = u[2].w, phase = u[Self.cellARow].z
        // (Previews: the clock or the storm jumped between still frames, so what is shown is stale.)
        let jumped = !cellClock.isFinite || abs(clock - cellClock) > 0.5 || abs(phase - cellPhase) > 0.01
        cellClock = clock; cellPhase = phase
        let whole = Self.cellAtOnce && (jumped || cellNewer < 0 || cellWindows[cellNewer] != cellWindow)
        if whole {
            encodeCell(cb, kernel: kernel, texture: texture, slot: cellFill, first: 0, strips: 1)
            cellFillStrip = Self.cellStrips
        } else {
            encodeCell(cb, kernel: kernel, texture: texture, slot: cellFill, first: cellFillStrip, strips: Self.cellStrips)
            cellFillStrip += 1
        }
        if cellFillStrip >= Self.cellStrips {
            // Whole: it becomes the newer, the newer the older; the fill goes on in the oldest.
            cellWindows[cellFill] = cellWindow
            cellWhole[cellFill] = true
            cellOlder = cellNewer
            cellNewer = cellFill
            cellFill = (0..<Self.cellSlots).first { $0 != cellNewer && $0 != cellOlder } ?? 0
            cellWhole[cellFill] = false
            cellFillStrip = 0
            if whole { cellOlder = -1 }   // (a still frame shows the snapshot it drew)
        }
        guard cellNewer >= 0 else { u[9].w = 0; u[10].w = 0; u[Self.flashRow].y = 0; u[Self.flashRow].z = 0; return }
        // The older cross-fades into the newer as the next fill goes on; one drawn in another window is not shown.
        let w = cellWindows[cellNewer]
        let older = cellOlder >= 0 && cellWindows[cellOlder] == w ? cellOlder : cellNewer
        let blend = older == cellNewer ? 1 : Float(cellFillStrip) / Float(Self.cellStrips)
        u[9].w = w.x; u[10].w = w.y
        u[Self.flashRow].y = w.z; u[Self.flashRow].z = w.w
        u[Self.flashRow].w = 1 + Float(3 * older + cellNewer) + 0.9 * min(blend, 1)
    }

    /// Waits (running the main run loop) until the shared star texture has arrived; for previews and tests.
    @discardableResult
    func awaitStars(timeout: TimeInterval = 5) -> Bool { StarTextureCache.shared.awaitTexture(timeout: timeout) }

    /// The aurora's pole-ward azimuth (degrees): north (0°) in the northern hemisphere, south (180°) in the southern,
    /// wandering ±20° over tens of minutes.
    nonisolated static func auroraAzimuth(hemisphere: Float, time: Float) -> Double {
        let t = Double(time)
        let wander = 20 * (0.6 * sin(t * 2 * .pi / 1500) + 0.4 * sin(t * 2 * .pi / 640 + 1.3))
        return (hemisphere >= 0 ? 0 : 180) + wander
    }

    nonisolated static func enu(_ dir: SkyDirection) -> SIMD3<Float> {
        let az = dir.azimuth * .pi / 180, alt = dir.altitude * .pi / 180
        return SIMD3<Float>(Float(sin(az) * cos(alt)), Float(cos(az) * cos(alt)), Float(sin(alt)))
    }

    /// East, north and up as equatorial unit vectors (x toward RA 0, z the north celestial pole): the columns of the
    /// shader's `eq` matrix (equatorial = eq · east-north-up; its transpose turns a star back into east-north-up).
    nonisolated static func equatorialBasis(siderealDegrees: Double, latitude: Double) -> (east: SIMD3<Float>, north: SIMD3<Float>, up: SIMD3<Float>) {
        let lst = siderealDegrees * .pi / 180, lat = latitude * .pi / 180
        let east = SIMD3<Float>(Float(-sin(lst)), Float(cos(lst)), 0)
        let north = SIMD3<Float>(Float(-sin(lat) * cos(lst)), Float(-sin(lat) * sin(lst)), Float(cos(lat)))
        let up = SIMD3<Float>(Float(cos(lat) * cos(lst)), Float(cos(lat) * sin(lst)), Float(sin(lat)))
        return (east, north, up)
    }

    /// The camera `camera(latitude:aspect:)` gives (its basis in east-north-up and the half-view tangents).
    typealias Camera = (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, tanH: Float, tanV: Float)

    /// Camera basis in east-north-up.
    func camera(latitude: Double, aspect: Float) -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>, tanH: Float, tanV: Float) {
        let az = (viewAzimuth ?? Self.defaultViewAzimuth(latitude: latitude)) * .pi / 180
        let tanV = Float(tan(verticalFOV * .pi / 360))
        let pitch = -atan(horizonY * tanV)
        let f0 = SIMD3<Float>(Float(sin(az)), Float(cos(az)), 0), up0 = SIMD3<Float>(0, 0, 1)
        let right = SIMD3<Float>(Float(cos(az)), Float(-sin(az)), 0)
        let forward = f0 * cos(pitch) + up0 * sin(pitch)
        let up = -f0 * sin(pitch) + up0 * cos(pitch)
        guard roll != 0 else { return (right, up, forward, tanV * aspect, tanV) }
        let r = Float(roll * .pi / 180)
        return (right * cos(r) + up * sin(r), up * cos(r) - right * sin(r), forward, tanV * aspect, tanV)
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, time: Float) {
        let aspect = Float(max(1, size.width) / max(1, size.height))
        let cam = camera(latitude: s.latitude, aspect: aspect)
        let (east, north, upEq) = Self.equatorialBasis(siderealDegrees: s.siderealDegrees, latitude: s.latitude)
        let pixelAngle = 2 * cam.tanV / Float(max(1, size.height))
        u[0] = SIMD4(cam.right, cam.tanH)
        u[1] = SIMD4(cam.up, cam.tanV)
        u[2] = SIMD4(cam.forward, time)
        u[3] = SIMD4(s.zenith, s.starVisibility)
        u[4] = SIMD4(s.horizon, s.cloudCover)
        u[5] = SIMD4(Self.enu(s.sun), Float(s.sun.altitude))
        u[6] = SIMD4(Self.enu(s.moon), Float(s.moonPhase))
        u[7] = SIMD4(Float(s.moonLit), s.earthshine, Float(moonRadiusDegrees * .pi / 180) * s.moonSize, Float(sunRadiusDegrees * .pi / 180) * s.sunSize)
        u[8] = SIMD4(east, 0); u[9] = SIMD4(north, 0); u[10] = SIMD4(upEq, 0)
        // z carries the octave count in its whole part and the rainbow (×0.45) in its fraction; the shader rounds it back.
        u[11] = SIMD4(s.mist, s.wind, (quality == .lite ? 2 : 3) + 0.45 * min(1, max(0, s.rainbow)), pixelAngle)
        u[12] = SIMD4(s.halo, s.dawnPastel, s.gust, s.wetness)
        u[13] = SIMD4(s.aurora, s.auroraStorm, s.constellationLines, s.fireflies)
        // Follow the sky keeps the real aurora toward the pole; Always is for the show, so it stands where the world looks,
        // its base at most 12° under the view's top (the fjord and the bay frame theirs lower still).
        let bandAz: Double = s.auroraAlways ? (viewAzimuth ?? Self.defaultViewAzimuth(latitude: s.latitude))
                                            : Self.auroraAzimuth(hemisphere: s.hemisphere, time: time)
        let poleAz = bandAz * .pi / 180
        let pitchDegrees: Float = -atan(horizonY * cam.tanV) * 180 / .pi
        let viewTop: Float = Float(verticalFOV / 2) + pitchDegrees
        let bandAlt: Float = s.auroraAlways ? min(s.auroraAltitude, viewTop - 12) : s.auroraAltitude
        u[14] = SIMD4(Float(sin(poleAz)), Float(cos(poleAz)), bandAlt, s.hemisphere)
        u[15] = SIMD4(s.diamondDust, s.pillar, min(1, max(-1, auroraTint.x)), min(1, max(0, auroraTint.y)))
        for i in 0..<Self.rippleCount { u[16 + i] = i < ripples.count ? ripples[i] : .zero }
        // Still places: iridescent cloud and rime frost (0 leaves the sky and every silhouette as before).
        func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
        let wind = Self.screenWind(s)
        u[Self.stillRow] = SIMD4(unit(s.iridescence), unit(s.rime), wind.x, wind.y)
        // Shooting stars (spec §7.2): the sky's meteors at this frame's moment on their own clock, into the six slots in
        // turn; the slots left over are emptied (B.w 0), and the fireball's brightening rides in the last row.
        var slot = 0
        for m in s.meteors where slot < Self.meteorSlots {
            guard let rows = Self.meteorRows(m, at: s.meteorTime) else { continue }
            u[Self.meteorARow + slot] = rows.a; u[Self.meteorBRow + slot] = rows.b; u[Self.meteorCRow + slot] = rows.c
            slot += 1
        }
        for i in slot..<Self.meteorSlots { u[Self.meteorARow + i] = .zero; u[Self.meteorBRow + i] = .zero; u[Self.meteorCRow + i] = .zero }
        let flash = s.meteorFlash.isFinite ? min(0.08, max(0, s.meteorFlash)) : 0
        u[Self.flashRow] = SIMD4(flash, 0, 0, 0)

        // Fire & Neon (spec §6.1): the far storm and its sprites, staged where the world looks.
        let view = viewAzimuth ?? Self.defaultViewAzimuth(latitude: s.latitude)
        let staged = Self.stage(episode: s.stormEpisode, bearing: s.stormBearing, viewAzimuth: view, anchor: stormAnchor)
        stormAnchor = staged.anchor
        stormShift = staged.shift
        if let f = s.farStormNow, f.amount.isFinite, f.amount > 0 {
            let az = (Double(f.bearing) + staged.shift) * .pi / 180
            u[Self.stormRow] = SIMD4(Float(sin(az)), Float(cos(az)), min(1, f.amount), f.top.isFinite ? f.top : 2)
            u[Self.stormFlickerRow] = SIMD4(unit(f.flicker), f.flickerAcross.isFinite ? f.flickerAcross : 0,
                                            unit(f.flickerUp), max(4, f.width.isFinite ? f.width : 20))
        } else {
            u[Self.stormRow] = .zero; u[Self.stormFlickerRow] = .zero
        }
        var sprite = 0
        for p in s.sprites where sprite < Self.spriteSlots {
            guard let rows = Self.spriteRows(p, shift: staged.shift) else { continue }
            u[Self.spriteARow + sprite] = rows.a; u[Self.spriteBRow + sprite] = rows.b
            sprite += 1
        }
        for i in sprite..<Self.spriteSlots { u[Self.spriteARow + i] = .zero; u[Self.spriteBRow + i] = .zero }
        // Fire & Neon (spec §6.2): the satellites, among the real stars.
        var sat = 0
        for t in s.satellites where sat < Self.satelliteSlots {
            guard let rows = Self.satelliteRows(t) else { continue }
            u[Self.satARow + sat] = rows.a; u[Self.satBRow + sat] = rows.b; u[Self.satCRow + sat] = rows.c
            sat += 1
        }
        for i in sat..<Self.satelliteSlots { u[Self.satARow + i] = .zero; u[Self.satBRow + i] = .zero; u[Self.satCRow + i] = .zero }
        // Fire & Neon (spec §7.2): the supercell weather, staged where the world looks as its far storms are.
        let step: Double = {
            guard let last = lastTime else { return 1.0 / 60 }
            let d = Double(time - last)
            return d >= 0 && d < 0.5 ? d : 1.0 / 60
        }()
        lastTime = time
        glowLimiter.gentle = gentle
        let glowAsked = s.supercellWeather.map { unit($0.glow) * (($0.amount.isFinite && $0.amount > 0) ? 1 : 0) } ?? 0
        let glowPassed = max(0, glowLimiter.limit(exposure: 1 + glowAsked, sparkle: 0, dt: step).exposure - 1)
        cellGlowOut = gentle ? min(Self.gentleCellGlow, glowPassed) : min(glowAsked, glowPassed)
        if let c = s.supercellWeather, c.amount.isFinite, c.amount > 0 {
            let cs = Self.stage(episode: c.episode, bearing: c.bearing, viewAzimuth: view, anchor: cellAnchor)
            cellAnchor = cs.anchor
            let az = (Double(c.bearing) + cs.shift) * .pi / 180
            u[Self.cellARow] = SIMD4(Float(sin(az)), Float(cos(az)), unit(c.phase), unit(c.amount))
            u[Self.cellBRow] = SIMD4(min(SupercellNow.greenest, max(0, c.green.isFinite ? c.green : 0)),
                                     c.turn.isFinite ? c.turn : 0, cellGlowOut, unit(c.hail))
            u[Self.cellCRow] = SIMD4(c.distanceKm.isFinite ? c.distanceKm : 30, c.anvilEdgeKm.isFinite ? c.anvilEdgeKm : 38,
                                     unit(c.mammatus), unit(c.spot))
        } else {
            u[Self.cellARow] = .zero; u[Self.cellBRow] = .zero; u[Self.cellCRow] = .zero
        }
        // Fire & Neon (spec §7.1): the ash, and the sun's light through it.
        func tint(_ t: SIMD3<Float>) -> SIMD3<Float> {
            t.x.isFinite && t.y.isFinite && t.z.isFinite ? SIMD3(unit(t.x), unit(t.y), unit(t.z)) : SIMD3(1, 1, 1)
        }
        let sunTint = tint(s.sunTint)
        u[Self.ashRow] = SIMD4(unit(s.ash), sunTint.x, sunTint.y, sunTint.z)
        chooseProgram()
    }

    /// How many times the dome's storm program was built, and whether it has been (tests).
    var domeStormBuilds: Int { pipeline.stormBuilds }
    var domeHasStormProgram: Bool { pipeline.hasStormProgram }

    func draw(_ e: MTLRenderCommandEncoder) {
        e.setRenderPipelineState(pipeline.state(program))
        uniforms.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        bindStars(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// Rain streaks or snow flakes (instanced), splash rings on water, drops on glass, blowing-snow streamers, a humid
/// night's fireflies, diamond dust's crystals, and lightning exposure requests that go through the flash limiter.
@MainActor
final class WeatherLayer {
    static func baseCount(_ q: QualityLevel) -> Int { q == .lite ? 400 : (q == .high ? 1200 : 2500) }
    static func streamerCap(_ q: QualityLevel) -> Int { q == .lite ? 60 : 150 }
    static func fireflyCap(_ q: QualityLevel) -> Int { q == .lite ? 60 : (q == .high ? 150 : 250) }
    static func crystalCap(_ q: QualityLevel) -> Int { q == .lite ? 150 : (q == .high ? 400 : 800) }
    /// Fireflies keep to the lower 55% of the view (NDC y below this).
    static let fireflyTop: Float = 0.1
    /// The weather clock wraps every hour (its floats stay fine in a long session), and every blink and twinkle rate is
    /// rounded to a whole number of cycles an hour, so the wrap never shows.
    static let clockWrap: Float = 3600
    static func wholeCycles(_ rate: Float) -> Float { max(1, (rate * clockWrap).rounded()) / clockWrap }
    /// Sea smoke's wisps at most (spec §6.4): 40 on Smooth, 90, 150.
    static func steamCap(_ q: QualityLevel) -> Int { q == .lite ? 40 : (q == .high ? 90 : 150) }
    /// Sea smoke's flat mist: its half height (NDC y) about the band's far edge.
    static let steamMistHalfHeight: Float = 0.05

    var gentle = false
    private(set) var particleCount = 0
    /// Ground streamers drawn this frame (blizzard gusts only).
    private(set) var streamerCount = 0
    /// Fireflies (humid nights, over ground or water) and diamond-dust crystals drawn this frame.
    private(set) var fireflyCount = 0
    private(set) var crystalCount = 0
    /// Instance buffers made so far: a ring of three, grown only when too small (never one per frame).
    private(set) var bufferAllocations = 0
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    /// Multiply into the world's exposure (1 = no lightning).
    private(set) var exposureBoost: Float = 1

    private struct Drop { var x, y, depth, speed, landY: Float }
    private struct Ring { var x, y, age, size: Float }
    private struct Bead { var x, y, size, speed, wobble: Float }
    private struct Streamer { var x, y, length, speed, alpha: Float }
    /// A firefly: position, heading (radians), speed (NDC/s), blink rate (Hz), on-time (s), blink phase (s), size (px).
    private struct Firefly { var x, y, heading, speed, rate, onTime, phase, size: Float }
    /// A crystal: position, fall speed (NDC/s), twinkle rate (Hz) and phase, size (px).
    private struct Crystal { var x, y, speed, rate, phase, size: Float }

    private let particlePipeline, ringPipeline: MTLRenderPipelineState
    private var drops: [Drop] = []
    private var rings: [Ring] = []
    private var beads: [Bead] = []
    private var instances: [SIMD4<Float>] = []
    private var ringInstances: [SIMD4<Float>] = []
    private var beadInstances: [SIMD4<Float>] = []
    private var streamers: [Streamer] = []
    private var streamerInstances: [SIMD4<Float>] = []
    private var fireflies: [Firefly] = []
    private(set) var fireflyInstances: [SIMD4<Float>] = []
    private var crystals: [Crystal] = []
    private(set) var crystalInstances: [SIMD4<Float>] = []
    /// Embers (where the world is their source) and hail (a supercell's), each with its own stream.
    private struct Ember { var x, y, vx, vy, age, life, flicker, size: Float }
    private struct Stone { var x, y, vy, depth, landY: Float; var bounced: Bool }
    private var embers: [Ember] = []
    private(set) var emberInstances: [SIMD4<Float>] = []
    private var hail: [Stone] = []
    private(set) var hailInstances: [SIMD4<Float>] = []
    private(set) var emberCount = 0
    private(set) var hailCount = 0
    private var emberRng = SeededRandom(seed: 0xE3BE_2500)
    private var hailRng = SeededRandom(seed: 0x4A11_5702)
    /// Seconds, wrapped at `clockWrap` (tests set it).
    var clock: Float = 0
    private var pixelNDC: Float = 2.0 / 360
    private var rng = SeededRandom(seed: 0xD20F5)
    private var limiter = FlashLimiter()
    /// 0 rain streaks, 1 snow flakes (tests check a cold world never rains).
    private(set) var kind: Float = 0
    /// Sideways drift per unit of fall: snow leans harder in gusts.
    private(set) var tilt: Float = 0
    private var aspect: Float = 16.0 / 9
    private var brightness: Float = 1

    // Sea smoke (spec §6.4): wisps rising off the world's open water.
    /// The world's open water on screen (NDC x0, y0, x1, y1: across, and from its near edge up to its far one). Each world
    /// with water sets it every frame from its own geometry; nil (the default) is no open water, so no steam.
    var waterBand: SIMD4<Float>?
    /// The view the steam is seen through (the world's sky camera), for the low sun's glow ahead; nil: no glow.
    var steamCamera: SkyLayer.Camera?
    /// How fast the water passes across the view (NDC x per second at the band's middle, nearer wisps faster): the
    /// road's sea as the car drives; 0 for still water.
    var steamDrift: Float = 0
    /// Sea smoke's wisps alive, and the blobs they drew this frame.
    private(set) var steamCount = 0
    private(set) var steamBlobCount = 0
    /// A wisp: across and up the band (0…1; up is farther), its age and life (s), how far its column climbs (NDC y), its
    /// first blob radius (NDC y), how much it widens, its turn round its axis (rad/s) and phase, its lean downwind (dx per
    /// dy), and its blobs.
    private struct Wisp { var u, v, age, life, rise, size, widen, spin, phase, lean: Float; var blobs: Int }
    private var wisps: [Wisp] = []
    private(set) var steamInstances: [SIMD4<Float>] = []
    private var mistInstances: [SIMD4<Float>] = []
    /// The steam's own stream, so it never shifts the rain's, the fireflies' or the crystals'.
    private var steamRng = SeededRandom(seed: 0x57EA_5A0C)
    /// The steam's light this frame (`steamLight`): tint (rgb, the sun's screen x) and the low sun's glow (rgb, width).
    private(set) var steamTint = SIMD4<Float>(0, 0, 0, 0)
    private(set) var steamGlow = SIMD4<Float>(0, 0, 0, 1)

    init?(device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: SkyShaders.source, options: nil) else { return nil }
        func make(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.skyFunction(v)
            d.fragmentFunction = lib.skyFunction(f)
            d.colorAttachments[0].pixelFormat = RenderStack.sceneFormat
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[1].pixelFormat = RenderStack.depthFormat
            d.colorAttachments[1].writeMask = []
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let p = make("weather_vertex", "weather_fragment"), let r = make("ring_vertex", "ring_fragment") else { return nil }
        particlePipeline = p; ringPipeline = r
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, surface: WeatherSurface) {
        let fdt = Float(min(dt, 0.1))
        aspect = Float(max(1, size.width) / max(1, size.height))
        // Ashfall (Fire & Neon §7.1) falls through the snow's path: grey, at 0.6× its speed, tumbling more.
        let ash = s.ash.isFinite ? min(1, max(0, s.ash)) * Self.ashDensity : 0
        let ashing = ash > max(s.rain, s.snow)
        let snowing = ashing || s.snow > s.rain
        let amount = max(s.rain, s.snow, ash)
        kind = ashing ? 9 : (snowing ? 1 : 0)
        let wanted = Int((Float(Self.baseCount(quality)) * amount).rounded())
        tilt = (snowing ? 0.25 + 1.2 * s.gust : 0.6) * s.wind
        let gustSpeed: Float = (snowing ? 1 + s.gust : 1) * (ashing ? Self.ashSpeed : 1)
        // Night light is dim: weather glints less.
        brightness = 0.25 + 0.75 * min(1, max(0, Float((s.sun.altitude + 6) / 18))) + 0.15 * Float(s.moonLit)
        let horizon: Float? = { if case let .water(y) = surface { return y }; if case let .ground(y) = surface { return y }; return nil }()
        while drops.count < wanted { drops.append(spawn(top: drops.isEmpty, snowing: snowing, horizon: horizon)) }
        if drops.count > wanted { drops.removeLast(drops.count - wanted) }
        particleCount = drops.count

        instances.removeAll(keepingCapacity: true)
        for i in drops.indices {
            var d = drops[i]
            if snowing {
                d.y -= d.speed * gustSpeed * fdt
                let wobble: Float = ashing ? 0.07 * sin(d.y * 6 + d.depth * 20 + clock * (0.9 + d.depth)) : 0.03 * sin(d.y * 9 + d.depth * 20)
                d.x += (tilt * d.speed * gustSpeed + wobble) * fdt
            } else {
                d.y -= d.speed * fdt
                d.x += tilt * d.speed * fdt / aspect
            }
            if d.y < d.landY {
                if !snowing, case .water = surface, rings.count < (quality == .lite ? 64 : 200) {
                    rings.append(Ring(x: d.x, y: d.landY, age: 0, size: 0.012 + 0.03 * d.depth))
                }
                d = spawn(top: true, snowing: snowing, horizon: horizon)
            }
            if d.x > 1.1 { d.x -= 2.2 } else if d.x < -1.1 { d.x += 2.2 }
            drops[i] = d
            let alpha = (ashing ? 0.7 : (snowing ? 0.85 : 0.22)) * (0.35 + 0.65 * d.depth)
            let sizeOrLength = snowing ? (0.003 + 0.009 * d.depth) * (ashing ? 0.8 : 1) : (0.03 + 0.06 * d.depth)
            instances.append(SIMD4(d.x, d.y, sizeOrLength, alpha))
        }

        ringInstances.removeAll(keepingCapacity: true)
        rings = rings.compactMap { r in
            var r = r
            r.age += fdt
            guard r.age < 0.6 else { return nil }
            let k = r.age / 0.6
            ringInstances.append(SIMD4(r.x, r.y, r.size * (0.2 + k), 0.6 * (1 - k)))
            return r
        }

        beadInstances.removeAll(keepingCapacity: true)
        if case .glass = surface, s.rain > 0.02 {
            let wantedBeads = Int(Float(quality == .lite ? 40 : 90) * s.rain)
            while beads.count < wantedBeads { beads.append(newBead(anywhere: beads.isEmpty)) }
            if beads.count > wantedBeads { beads.removeLast(beads.count - wantedBeads) }
            for i in beads.indices {
                var b = beads[i]
                b.wobble += fdt
                // Drops cling, then slide in short runs.
                let run = max(0, sin(b.wobble * 1.3 + b.size * 300))
                b.y -= b.speed * run * run * fdt
                if b.y < -1.1 { b = newBead(anywhere: false) }
                beads[i] = b
                beadInstances.append(SIMD4(b.x, b.y, b.size, 0.55))
                beadInstances.append(SIMD4(b.x, b.y + b.size * 3, b.size * 0.35, 0.12))   // the trail it left
            }
        } else {
            beads.removeAll()
        }

        // Blowing snow: long thin wisps racing across the lower third of the view in blizzard gusts.
        streamerInstances.removeAll(keepingCapacity: true)
        if s.snow > 0.9 && s.gust > 0.2 {
            let wantedStreamers = Int(Float(Self.streamerCap(quality)) * min(1, (s.gust - 0.2) / 0.6))
            while streamers.count < wantedStreamers { streamers.append(newStreamer(anywhere: streamers.isEmpty)) }
            if streamers.count > wantedStreamers { streamers.removeLast(streamers.count - wantedStreamers) }
            let dir: Float = tilt >= 0 ? 1 : -1
            for i in streamers.indices {
                var st = streamers[i]
                st.x += dir * st.speed * (0.6 + 0.8 * s.gust) * fdt
                if st.x > 1.3 || st.x < -1.3 { st = newStreamer(anywhere: false); st.x = -1.25 * dir }
                streamers[i] = st
                streamerInstances.append(SIMD4(st.x, st.y, st.length, st.alpha * s.gust))
            }
        } else {
            streamers.removeAll()
        }
        streamerCount = streamerInstances.count

        clock += fdt
        if clock >= Self.clockWrap { clock -= Self.clockWrap }   // seamless: every blink and twinkle is whole cycles an hour
        pixelNDC = 2 / Float(max(1, size.height))
        updateFireflies(s, quality: quality, dt: fdt, ground: horizon != nil)
        updateCrystals(s, quality: quality, dt: fdt)
        updateSteam(s, quality: quality, dt: fdt)

        updateEmbers(s, quality: quality, dt: fdt)
        updateHail(s, quality: quality, dt: fdt, surface: surface)

        // Lightning brightens the scene through the flash limiter; under gentle visuals it is only a glow (Fire & Neon
        // Review focus 5: no flash, a rise far under the limiter's). Under a supercell the flash is its cloud's own light
        // (the sky layer's), so the scene only lifts a little with it, never a pale wash.
        limiter.gentle = gentle
        let gain: Float = gentle ? Self.gentleLightning : (s.supercellWeather.map { $0.amount > 0 } == true ? Self.cellLightning : 1.2)
        exposureBoost = limiter.limit(exposure: 1 + gain * s.lightning, sparkle: 0, dt: dt).exposure
    }

    /// The main drops' heights this frame (tests: ash falls at 0.6× the snow's pace).
    var particleYs: [Float] { instances.map(\.y) }

    /// Ashfall's density (its share of the snow's cap at full ash) and its fall (× the snow's speed).
    static let ashDensity: Float = 0.75, ashSpeed: Float = 0.6
    /// Lightning's brightening under gentle visuals (a glow; 1.2 otherwise), and under a supercell (its cloud carries
    /// the flash; the scene lifts a little).
    static let gentleLightning: Float = 0.2
    static let cellLightning: Float = 0.35
    static func emberCap(_ q: QualityLevel) -> Int { q == .lite ? 150 : 300 }
    static func hailCap(_ q: QualityLevel) -> Int { q == .lite ? 150 : 320 }

    /// Embers (spec §7.1), where the world is their source: sparks rising from below the view, slowing, cooling from
    /// orange to a dull red as they drift on the wind, then falling, each flickering on its own beat.
    private func updateEmbers(_ s: SkyState, quality: QualityLevel, dt: Float) {
        emberInstances.removeAll(keepingCapacity: true)
        let amount = s.embers.isFinite ? min(1, max(0, s.embers)) : 0
        let wanted = Int((Float(Self.emberCap(quality)) * amount).rounded())
        while embers.count < wanted { embers.append(newEmber(anywhere: embers.isEmpty)) }
        if embers.count > wanted { embers.removeLast(embers.count - wanted) }
        emberCount = embers.count
        let wind = s.wind.isFinite ? s.wind : 0
        for i in embers.indices {
            var e = embers[i]
            e.age += dt
            e.vy -= 0.16 * dt
            e.x += (e.vx + 0.12 * wind) * dt / aspect
            e.y += e.vy * dt
            if e.age > e.life || e.y < -1.15 || e.x > 1.2 || e.x < -1.2 { e = newEmber(anywhere: false) }
            embers[i] = e
            let k = e.age / e.life
            let heat = (1 - k) * (0.75 + 0.25 * sin(clock * e.flicker + e.x * 40))
            let alpha = heat * smoothstep01(0, 0.08, k) * (gentle ? 0.55 : 0.9)
            guard alpha > 0.01 else { continue }
            emberInstances.append(SIMD4(e.x, e.y, e.size * pixelNDC * (0.6 + 0.4 * (1 - k)), alpha))
        }
    }

    private func smoothstep01(_ a: Float, _ b: Float, _ x: Float) -> Float { Self.smooth(a, b, x) }

    private func newEmber(anywhere: Bool) -> Ember {
        Ember(x: emberRng.range(-1, 1), y: anywhere ? emberRng.range(-1.05, 0.2) : emberRng.range(-1.1, -0.85),
              vx: emberRng.range(-0.05, 0.05), vy: emberRng.range(0.22, 0.55), age: anywhere ? emberRng.range(0, 2) : 0,
              life: emberRng.range(3, 7), flicker: emberRng.range(9, 23), size: emberRng.range(2, 4))
    }

    /// Hail (spec §7.2): hard pellets falling fast and nearly straight, each bouncing once off the ground (a few
    /// hundredths of the view) before it rolls away; on water they splash, on glass they strike and are gone.
    private func updateHail(_ s: SkyState, quality: QualityLevel, dt: Float, surface: WeatherSurface) {
        hailInstances.removeAll(keepingCapacity: true)
        let amount = s.hail.isFinite ? min(1, max(0, s.hail)) : 0
        let wanted = Int((Float(Self.hailCap(quality)) * amount).rounded())
        let ground: Float? = { if case let .ground(y) = surface { return y }; return nil }()
        let water: Float? = { if case let .water(y) = surface { return y }; return nil }()
        while hail.count < wanted { hail.append(newStone(anywhere: hail.isEmpty, horizon: ground ?? water)) }
        if hail.count > wanted { hail.removeLast(hail.count - wanted) }
        hailCount = hail.count
        let lean = 0.25 * (s.wind.isFinite ? s.wind : 0)
        for i in hail.indices {
            var h = hail[i]
            h.vy -= 6 * dt * (h.bounced ? 1 : 0)
            h.y += h.vy * dt
            h.x += lean * abs(h.vy) * dt / aspect
            if !h.bounced, h.y < h.landY {
                if ground != nil {
                    h.bounced = true
                    h.y = h.landY
                    h.vy = 0.25 + 0.45 * h.depth
                } else {
                    if water != nil, rings.count < (quality == .lite ? 64 : 200) {
                        rings.append(Ring(x: h.x, y: h.landY, age: 0, size: 0.01 + 0.02 * h.depth))
                    }
                    h = newStone(anywhere: false, horizon: ground ?? water)
                }
            } else if h.bounced, h.y < h.landY - 0.002 {
                h = newStone(anywhere: false, horizon: ground ?? water)
            }
            hail[i] = h
            let length: Float = h.bounced ? 0.006 : 0.012 + 0.03 * h.depth
            hailInstances.append(SIMD4(h.x, h.y, length, 0.7 * (0.4 + 0.6 * h.depth)))
        }
    }

    private func newStone(anywhere: Bool, horizon: Float?) -> Stone {
        let depth = hailRng.unit()
        let landY: Float
        if let hz = horizon { landY = hz - (hz + 1) * (0.05 + 0.95 * depth) } else { landY = -1.1 }
        return Stone(x: hailRng.range(-1.1, 1.1), y: anywhere ? hailRng.range(-1, 1.2) : 1.05 + 0.2 * hailRng.unit(),
                     vy: -(2.2 + 1.4 * depth), depth: depth, landY: landY, bounced: false)
    }

    /// A humid night's fireflies: a slow random walk low in the view, each blinking on its own beat.
    private func updateFireflies(_ s: SkyState, quality: QualityLevel, dt: Float, ground: Bool) {
        fireflyInstances.removeAll(keepingCapacity: true)
        let amount = min(1, max(0, s.fireflies))
        let wanted = ground ? Int((Float(Self.fireflyCap(quality)) * amount).rounded()) : 0
        while fireflies.count < wanted { fireflies.append(newFirefly()) }
        if fireflies.count > wanted { fireflies.removeLast(fireflies.count - wanted) }
        fireflyCount = fireflies.count
        let top = Self.fireflyTop
        for i in fireflies.indices {
            var f = fireflies[i]
            f.heading = (f.heading + rng.range(-2.5, 2.5) * dt).remainder(dividingBy: 2 * .pi)   // −π…π
            f.x += cos(f.heading) * f.speed * dt / aspect
            f.y += sin(f.heading) * f.speed * dt
            // Turn back softly at the edges of the low band.
            if f.y > top { f.y = top; f.heading = -abs(f.heading) }
            if f.y < -0.98 { f.y = -0.98; f.heading = abs(f.heading) }
            if f.x > 1.05 { f.x -= 2.1 } else if f.x < -1.05 { f.x += 2.1 }
            fireflies[i] = f
            // A square-ish blink: on for `onTime` once per period, with soft 80 ms edges.
            let period = 1 / f.rate
            var t = (clock + f.phase).truncatingRemainder(dividingBy: period)
            if t < 0 { t += period }
            let edge: Float = 0.08
            let rise: Float = min(1, max(0, t / edge))
            let fall: Float = min(1, max(0, (f.onTime - t) / edge))
            let on = rise * fall
            guard on > 0.001 else { continue }
            let alpha = on * (gentle ? 0.55 : 0.9)
            fireflyInstances.append(SIMD4(f.x, f.y, f.size * pixelNDC, alpha))
        }
    }

    /// Rime frost's ice-fog drift: the crystals at this share of their cap, falling at `rimeFogFall` of their speed.
    static let rimeFogDensity: Float = 0.3, rimeFogFall: Float = 0.35

    /// Diamond dust: tiny crystals over the whole view, falling very slowly, drifting with the wind, twinkling. In
    /// rime frost the same crystals are its fine ice-fog drift (spec §6.4): fewer, slower, fainter.
    private func updateCrystals(_ s: SkyState, quality: QualityLevel, dt: Float) {
        crystalInstances.removeAll(keepingCapacity: true)
        let (amount, fogShare) = Self.crystalMix(s)
        let wanted = Int((Float(Self.crystalCap(quality)) * amount).rounded())
        while crystals.count < wanted { crystals.append(newCrystal(anywhere: true)) }
        if crystals.count > wanted { crystals.removeLast(crystals.count - wanted) }
        crystalCount = crystals.count
        // The more of the drift is fog rather than dust, the slower it settles and twinkles, and the less it glints.
        let fall = 1 - (1 - Self.rimeFogFall) * fogShare
        let drift = 0.04 * s.wind + 0.01
        for i in crystals.indices {
            var c = crystals[i]
            c.y -= c.speed * fall * dt
            c.x += drift * (0.6 + 0.8 * c.speed / 0.03) * dt / aspect
            if c.y < -1.05 { c = newCrystal(anywhere: false) }
            if c.x > 1.05 { c.x -= 2.1 } else if c.x < -1.05 { c.x += 2.1 }
            // A running phase (0…1): fog slows the twinkle smoothly as it thickens, and no clock wrap ever jumps it.
            c.phase += c.rate * (1 - 0.5 * fogShare) * dt
            if c.phase >= 1 { c.phase -= c.phase.rounded(.down) }
            crystals[i] = c
            let tw = 0.5 + 0.5 * sin(c.phase * 2 * .pi)
            let glint = tw * tw * tw   // mostly faint, now and then a bright glint
            let alpha = (0.15 + 0.85 * glint) * (gentle ? 0.5 : 0.9) * (1 - 0.45 * fogShare)
            crystalInstances.append(SIMD4(c.x, c.y, c.size * pixelNDC, alpha))
        }
    }

    /// The crystals' share of their cap (diamond dust's, or rime fog's thinner drift, whichever is more) and how much
    /// of it is fog (0 dust alone … 1 fog alone).
    static func crystalMix(_ s: SkyState) -> (amount: Float, fogShare: Float) {
        let dust = min(1, max(0, s.diamondDust))
        let rimeFog = WeatherAmbience.rimeWeather(s)
        let fog = rimeFogDensity * (rimeFog.isFinite ? min(1, max(0, rimeFog)) : 0)
        return (max(dust, fog), fog / max(dust + fog, 1e-6))
    }

    /// Sea smoke's shapes: a wisp's column climbs 3% of the view's height far off … 12% near (NDC × 2), and its first blob
    /// is 0.010 far … 0.048 near (NDC y, ± 20%), widening up to 3×, its top blob 1.3× its first.
    private static let steamRiseFar: Float = 0.06, steamRiseNear: Float = 0.24
    private static let steamSizeFar: Float = 0.010, steamSizeNear: Float = 0.048

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// A band with a little width and height, in order (left of right, its near edge below its far one).
    static func usableBand(_ b: SIMD4<Float>) -> Bool {
        b.x.isFinite && b.y.isFinite && b.z.isFinite && b.w.isFinite && b.z - b.x > 1e-3 && b.w - b.y > 1e-3
    }

    /// The highest NDC y any of this band's steam can reach: its far edge, plus the most a wisp's column (its climb and its
    /// top blob, fully widened) can stand over it, or the flat mist's half height. Nothing of the steam draws higher.
    static func steamTop(band: SIMD4<Float>) -> Float {
        let height = max(0, band.w - band.y)
        // A wisp n of the way down the band (0 far … 1 near) stands at most −n·height + its climb + its top blob over the
        // far edge: piecewise linear in n, so the greatest is at an end or at the climb's knee (n · 1.15 = 1).
        func over(_ n: Float) -> Float {
            let climb = Self.steamRiseFar + (Self.steamRiseNear - Self.steamRiseFar) * min(1, n * 1.15)
            let blob = (Self.steamSizeFar + (Self.steamSizeNear - Self.steamSizeFar) * n) * 1.2 * 3 * 1.3
            return -n * height + climb + blob
        }
        return band.w + max(Self.steamMistHalfHeight, over(0), over(1 / 1.15), over(1))
    }

    /// Sea smoke (spec §6.4): up to `steamCap` wisps rising from the world's water band (none without one). Each is a soft
    /// column of 4–6 blobs climbing 3–12% of the view over 6–14 s while widening 2–3×; its blobs turn slowly round its
    /// axis, it leans downwind, it fades in over 1 s and out over its last 40%, and those low in the band (near) are
    /// larger. Their number follows the sky's steam, and a wisp that dies is replaced only while there are fewer, so
    /// thinning steam lets its wisps live out their lives. A thin flat mist lies along the band's far edge (0.25 × steam).
    private func updateSteam(_ s: SkyState, quality: QualityLevel, dt: Float) {
        steamInstances.removeAll(keepingCapacity: true)
        mistInstances.removeAll(keepingCapacity: true)
        guard let band = waterBand, Self.usableBand(band) else {
            wisps.removeAll()
            steamCount = 0; steamBlobCount = 0
            return
        }
        let steam = s.steam.isFinite ? min(1, max(0, s.steam)) : 0
        let wind = s.wind.isFinite ? min(1, max(0, s.wind)) : 0
        let drift = steamDrift.isFinite ? steamDrift : 0
        let wanted = Int((Float(Self.steamCap(quality)) * steam).rounded())
        let width = band.z - band.x, height = band.w - band.y
        for i in wisps.indices {
            wisps[i].age += dt
            let n = 1 - wisps[i].v
            wisps[i].u += (drift * (0.5 + n) + (0.01 + 0.04 * wind) * (0.4 + 0.6 * n)) * dt / width
        }
        wisps.removeAll { $0.age >= $0.life || $0.u < -0.1 || $0.u > 1.1 }
        // A fresh band (or a sudden thickening) starts mid-flow rather than with every wisp fading in at once.
        let fill = wisps.count * 2 < wanted
        while wisps.count < wanted { wisps.append(newWisp(midLife: fill, wind: wind)) }
        steamCount = wisps.count
        wisps.sort { $0.v > $1.v }   // far ones first, so the near ones lie over them
        for w in wisps {
            let k = min(1, w.age / w.life)
            let fade = Self.smooth(0, 1, w.age) * (1 - Self.smooth(0.6, 1, k))
            let climb = w.rise * (0.15 + 0.85 * (1 - (1 - k) * (1 - k)))
            let grow = 1 + (w.widen - 1) * k
            let baseX = band.x + w.u * width, baseY = band.y + w.v * height
            for j in 0..<w.blobs {
                let f = Float(j) / Float(w.blobs - 1)
                let h = climb * f, r = w.size * grow * (0.7 + 0.6 * f)
                let phi = w.phase + w.spin * w.age + 2.4 * Float(j)
                let side = w.lean * h + 0.5 * r * sin(phi)   // NDC y units, so ÷ the aspect on screen
                let shade = 0.85 + 0.15 * cos(phi)           // the far side of its turn a little dimmer
                let y = baseY + h
                let edge = Self.smooth(band.y - 0.3 * r, band.y + 0.6 * r, y)   // no spilling over the near shore
                let alpha = 0.16 * fade * (1 - 0.45 * f) * shade * edge
                guard alpha >= 0.002 else { continue }
                steamInstances.append(SIMD4(baseX + side / aspect, y, r, alpha))
            }
        }
        steamBlobCount = steamInstances.count
        if steam > 0.001 { mistInstances.append(SIMD4((band.x + band.z) / 2, band.w, 0.55 * width, 0.25 * steam)) }
        let light = Self.steamLight(s, camera: steamCamera)
        steamTint = light.tint; steamGlow = light.glow
    }

    private func newWisp(midLife: Bool, wind: Float) -> Wisp {
        let u = steamRng.unit()
        let v = steamRng.unit().squareRoot()   // far wisps (small) outnumber near ones
        let n = 1 - v
        let life = steamRng.range(6, 14)
        let age: Float = midLife ? steamRng.range(0, life) : 0
        let rise = Self.steamRiseFar + (Self.steamRiseNear - Self.steamRiseFar) * min(1, n * steamRng.range(0.8, 1.15))
        let size = (Self.steamSizeFar + (Self.steamSizeNear - Self.steamSizeFar) * n) * steamRng.range(0.8, 1.2)
        let widen = steamRng.range(2, 3)
        let sign: Float = steamRng.unit() < 0.5 ? -1 : 1
        let spin = sign * steamRng.range(0.25, 0.7)
        let phase = steamRng.range(0, 2 * .pi)
        let lean = (0.25 + 2 * wind) * steamRng.range(0.7, 1.3)
        let blobs = 4 + min(2, Int(steamRng.unit() * 3))
        return Wisp(u: u, v: v, age: age, life: life, rise: rise, size: size, widen: widen, spin: spin, phase: phase,
                    lean: lean, blobs: blobs)
    }

    /// Sea smoke's light (spec §6.4): the sky's horizon colour × 1.25, a moonlit blue-grey at night (and the aurora's faint
    /// green under it), and the low sun's glow when it stands ahead of the view, gold-pink at sunrise. Returns the tint
    /// (rgb, the sun's screen x in NDC) and the glow (rgb, its width in NDC x; zero without a camera or with the sun high,
    /// down or behind).
    static func steamLight(_ s: SkyState, camera: SkyLayer.Camera?) -> (tint: SIMD4<Float>, glow: SIMD4<Float>) {
        func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
        let sunAlt = Float(s.sun.altitude.isFinite ? s.sun.altitude : -90)
        let moonAlt = Float(s.moon.altitude.isFinite ? s.moon.altitude : -90)
        let night = 1 - smooth(-6, 2, sunAlt)
        let moon = unit(Float(s.moonLit)) * smooth(-3, 8, moonAlt) * night
        let horizon = s.horizon.x.isFinite && s.horizon.y.isFinite && s.horizon.z.isFinite ? s.horizon : SIMD3<Float>(repeating: 0)
        let rgb = horizon * 1.25 + SIMD3<Float>(0.16, 0.18, 0.22) * moon + SIMD3<Float>(0.25, 1.0, 0.45) * (0.06 * unit(s.aurora))
        var glow = SIMD3<Float>(repeating: 0), sunX: Float = 0
        if let cam = camera {
            let sun = SkyLayer.enu(s.sun)
            let low = smooth(-7, -1, sunAlt) * (1 - smooth(6, 16, sunAlt))
            let flat = SIMD2(sun.x, sun.y), view = SIMD2(cam.forward.x, cam.forward.y)
            let lf = simd_length(flat), lv = simd_length(view)
            let ahead = lf > 1e-4 && lv > 1e-4 ? simd_dot(flat, view) / (lf * lv) : 0
            let g = low * smooth(0.25, 0.9, ahead) * (1 - 0.7 * unit(s.cloudCover))
            let depth = simd_dot(sun, cam.forward)
            if depth > 0.05, cam.tanH > 0 { sunX = min(4, max(-4, simd_dot(sun, cam.right) / (depth * cam.tanH))) }
            if g.isFinite { glow = SIMD3<Float>(1.0, 0.66, 0.5) * (0.9 * g) }
        }
        return (SIMD4(rgb, sunX.isFinite ? sunX : 0), SIMD4(glow, 0.9))
    }

    private func newFirefly() -> Firefly {
        Firefly(x: rng.range(-1, 1), y: rng.range(-0.95, Self.fireflyTop), heading: rng.range(0, 2 * .pi),
                speed: rng.range(0.02, 0.06), rate: Self.wholeCycles(rng.range(0.4, 1.1)), onTime: rng.range(0.25, 0.5),
                phase: rng.range(0, 3), size: rng.range(3, 6))
    }

    private func newCrystal(anywhere: Bool) -> Crystal {
        Crystal(x: rng.range(-1.05, 1.05), y: anywhere ? rng.range(-1, 1.05) : rng.range(1.0, 1.05), speed: rng.range(0.01, 0.03),
                rate: Self.wholeCycles(rng.range(2, 6)), phase: rng.range(0, 1), size: rng.range(1, 3))
    }

    private func spawn(top: Bool, snowing: Bool, horizon: Float?) -> Drop {
        let depth = rng.unit()
        let y = top ? 1.05 + 0.2 * rng.unit() : rng.range(-1, 1.2)
        let landY: Float
        if let h = horizon { landY = h - (h + 1) * (0.05 + 0.95 * depth) } else { landY = -1.1 }
        let speed = snowing ? 0.12 + 0.25 * depth : 1.6 + 1.6 * depth
        return Drop(x: rng.range(-1.1, 1.1), y: y, depth: depth, speed: speed, landY: landY)
    }

    private func newBead(anywhere: Bool) -> Bead {
        Bead(x: rng.range(-1, 1), y: anywhere ? rng.range(-1, 1) : rng.range(0.7, 1.1), size: 0.006 + 0.012 * rng.unit(),
             speed: 0.05 + 0.25 * rng.unit(), wobble: rng.range(0, 6))
    }

    private func newStreamer(anywhere: Bool) -> Streamer {
        Streamer(x: anywhere ? rng.range(-1.2, 1.2) : rng.range(-1.3, 1.3), y: rng.range(-0.98, -0.36),
                 length: rng.range(0.15, 0.45), speed: rng.range(0.8, 1.6), alpha: rng.range(0.10, 0.28))
    }

    func draw(_ e: MTLRenderCommandEncoder) {
        // Fireflies make their own light; crystals catch what there is (a little even on a dark night). Sea smoke goes
        // first, lowest over the water (its flat mist, then its wisps), and carries its own light (`steamTint`).
        let sets: [(MTLRenderPipelineState, [SIMD4<Float>], Float, Float)] = [
            (particlePipeline, mistInstances, 7, 1), (particlePipeline, steamInstances, 6, 1),
            (particlePipeline, instances, kind, brightness), (ringPipeline, ringInstances, 0, brightness),
            (particlePipeline, beadInstances, 2, brightness), (particlePipeline, streamerInstances, 3, brightness),
            (particlePipeline, fireflyInstances, 4, 2.2), (particlePipeline, crystalInstances, 5, max(0.7, brightness) * 1.6),
            (particlePipeline, hailInstances, 10, max(0.45, brightness) * 1.3), (particlePipeline, emberInstances, 8, 2.4),
        ]
        // This frame's slot in the ring holds all ten sets (256-byte aligned); it grows only when too small.
        func aligned(_ n: Int) -> Int { (n + 255) / 256 * 256 }
        let total = sets.reduce(0) { $0 + aligned($1.1.count * MemoryLayout<SIMD4<Float>>.stride) }
        guard total > 0 else { return }
        slot = (slot + 1) % ring.count
        if (ring[slot]?.length ?? 0) < total {
            ring[slot] = e.device.makeBuffer(length: max(total, 64 * 1024), options: .storageModeShared)
            bufferAllocations += 1
        }
        guard let buf = ring[slot] else { return }
        var offset = 0
        for (pipeline, items, kind, light) in sets where !items.isEmpty {
            let bytes = items.count * MemoryLayout<SIMD4<Float>>.stride
            items.withUnsafeBytes { raw in (buf.contents() + offset).copyMemory(from: raw.baseAddress!, byteCount: bytes) }
            // WeatherU (48 bytes): the set's params (kind 7's z is the mist's half height), then the steam's light.
            // Kinds 8 to 10 (embers, ash, hail) carry the weather clock in the tint's x (the ash flakes tumble on it).
            let tint = kind > 7.5 ? SIMD4<Float>(clock, 0, 0, 0) : steamTint
            let along: Float = kind > 6.5 && kind < 7.5 ? Self.steamMistHalfHeight : (kind > 9.5 ? 0.25 * tilt : tilt)
            var u = (SIMD4<Float>(aspect, kind, along, light), tint, steamGlow)
            e.setRenderPipelineState(pipeline)
            e.setVertexBuffer(buf, offset: offset, index: 0)
            withUnsafeBytes(of: &u) { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
            withUnsafeBytes(of: &u) { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: items.count)
            offset += aligned(bytes)
        }
    }
}

/// The sky and its weather on their own (tests and sky previews).
@MainActor
final class SkyOnlyRenderer: ThemeRenderer {
    let sky: SkyLayer
    let weather: WeatherLayer
    private(set) var post = PostSettings()

    init?(device: MTLDevice) {
        guard let s = SkyLayer(device: device), let w = WeatherLayer(device: device) else { return nil }
        sky = s; weather = w
    }

    func update(_ s: SkyState, quality: QualityLevel, size: CGSize, dt: Double, time: Float, surface: WeatherSurface) {
        sky.horizonY = { if case let .water(y) = surface { return y }; if case let .ground(y) = surface { return y }; return sky.horizonY }()
        sky.update(s, quality: quality, size: size, time: time)
        weather.update(s, quality: quality, size: size, dt: dt, surface: surface)
        post = PostSettings(bloom: 0.35, bloomThreshold: 1.0, dof: 0, focusDepth: 1, grade: 0, grain: 0.02, vignette: 0.25,
                            exposure: weather.exposureBoost, warmth: 0, time: time, quality: quality)
    }

    func render(stack: RenderStack, commandBuffer cb: MTLCommandBuffer) {
        sky.prepare(cb)
        guard let pass = stack.scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)),
              let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        sky.draw(e)
        weather.draw(e)
        e.endEncoding()
    }
}
