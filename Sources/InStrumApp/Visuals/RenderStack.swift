import Metal
import InStrumCore

/// Values the finishing stage needs from a theme each frame.
struct PostSettings {
    var bloom: Float = 0.5
    var bloomThreshold: Float = 0.8
    var dof: Float = 0
    var focusDepth: Float = 0.4
    /// 0 Natural, 1 Warm Film, 2 Cool Film, 3 Dreamy, 4 Vivid.
    var grade: Int = 0
    var grain: Float = 0
    var vignette: Float = 0.3
    var exposure: Float = 1
    /// -1 cool ... +1 warm.
    var warmth: Float = 0
    var time: Float = 0
    var quality: QualityLevel = .high
}

/// A theme draws its scene into the stack's HDR targets; the stack finishes it.
@MainActor
protocol ThemeRenderer: AnyObject {
    func render(stack: RenderStack, commandBuffer: MTLCommandBuffer)
    var post: PostSettings { get }
}

/// HDR scene targets (colour + depth) and the shared finishing passes. Its library and pipelines are compiled once per
/// process and shared by every stack (the app's, the previews', the tests').
final class RenderStack {
    static let sceneFormat: MTLPixelFormat = .rgba16Float
    static let depthFormat: MTLPixelFormat = .r16Float
    static let bloomLevels = 5

    let device: MTLDevice
    let outputFormat: MTLPixelFormat
    private(set) var hdrTarget: MTLTexture?
    private(set) var depthTarget: MTLTexture?
    private var dofTarget: MTLTexture?
    private var bloom: [MTLTexture] = []
    private var size = (0, 0)

    private let bright, down, up, dof, composite: MTLRenderPipelineState

    /// The finishing passes' pipelines, for an output format.
    private struct Pipelines {
        let bright, down, up, dof, composite: MTLRenderPipelineState
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let made = ShaderCache.shared.memo("RenderStack.\(pixelFormat.rawValue)", device: device, { () -> Pipelines? in
            RenderStack.makePipelines(device, pixelFormat)
        }) else { return nil }
        self.device = device
        self.outputFormat = pixelFormat
        bright = made.bright; down = made.down; up = made.up; dof = made.dof; composite = made.composite
    }

    private static func makePipelines(_ device: MTLDevice, _ pixelFormat: MTLPixelFormat) -> Pipelines? {
        guard let lib = ShaderCache.library(device, source: PostShaders.source),
              let vertex = lib.makeFunction(name: "fullscreen_vertex") else { return nil }
        func make(_ fragment: String, _ format: MTLPixelFormat, additive: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let b = make("bright_pass", Self.sceneFormat), let dn = make("downsample", Self.sceneFormat),
              let u = make("upsample", Self.sceneFormat, additive: true), let df = make("dof_gather", Self.sceneFormat),
              let c = make("composite", pixelFormat) else { return nil }
        return Pipelines(bright: b, down: dn, up: u, dof: df, composite: c)
    }

    /// Reallocates targets for a new drawable size. Zero sizes are ignored.
    func resize(width: Int, height: Int) {
        guard width > 0, height > 0, (width, height) != size else { return }
        size = (width, height)
        hdrTarget = texture(width, height, Self.sceneFormat)
        depthTarget = texture(width, height, Self.depthFormat)
        dofTarget = texture(width, height, Self.sceneFormat)
        bloom = (0..<Self.bloomLevels).compactMap { i in
            texture(max(1, width >> (i + 1)), max(1, height >> (i + 1)), Self.sceneFormat)
        }
    }

    private func texture(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// A pass that draws into the HDR colour (attachment 0) and depth (attachment 1) targets.
    func scenePass(clear: MTLClearColor) -> MTLRenderPassDescriptor? {
        guard let hdr = hdrTarget, let depth = depthTarget else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = hdr
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].clearColor = clear
        p.colorAttachments[0].storeAction = .store
        p.colorAttachments[1].texture = depth
        p.colorAttachments[1].loadAction = .clear
        p.colorAttachments[1].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        p.colorAttachments[1].storeAction = .store
        return p
    }

    /// Like `scenePass`, for a scene whose first draw writes every pixel's colour and depth (a full-view triangle whose
    /// fragment never discards): nothing of a clear would ever be seen, so the targets aren't cleared first.
    func scenePassOverwritten() -> MTLRenderPassDescriptor? {
        guard let p = scenePass(clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) else { return nil }
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[1].loadAction = .dontCare
        return p
    }

    /// Like `scenePass`, but keeps what is already drawn (to continue a scene after a mid-frame copy, e.g. glass blur).
    func scenePassContinuing() -> MTLRenderPassDescriptor? {
        guard let hdr = hdrTarget, let depth = depthTarget else { return nil }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = hdr
        p.colorAttachments[0].loadAction = .load
        p.colorAttachments[0].storeAction = .store
        p.colorAttachments[1].texture = depth
        p.colorAttachments[1].loadAction = .load
        p.colorAttachments[1].storeAction = .store
        return p
    }

    private func fullscreen(_ cb: MTLCommandBuffer, into target: MTLTexture, load: MTLLoadAction = .dontCare,
                            pipeline: MTLRenderPipelineState, _ setup: (MTLRenderCommandEncoder) -> Void) {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = target
        p.colorAttachments[0].loadAction = load
        p.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return }
        e.setRenderPipelineState(pipeline)
        setup(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    /// Glow, depth of field and grading into the final pass (e.g. the drawable).
    func post(into pass: MTLRenderPassDescriptor, commandBuffer cb: MTLCommandBuffer, settings s: PostSettings) {
        guard let hdr = hdrTarget, let depth = depthTarget, let dofTex = dofTarget, !bloom.isEmpty else { return }
        let levels = s.quality == .lite ? min(3, bloom.count) : bloom.count
        var threshold = s.bloomThreshold
        fullscreen(cb, into: bloom[0], pipeline: bright) { e in
            e.setFragmentTexture(hdr, index: 0)
            e.setFragmentBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        }
        for i in 1..<levels {
            fullscreen(cb, into: bloom[i], pipeline: down) { $0.setFragmentTexture(self.bloom[i - 1], index: 0) }
        }
        for i in stride(from: levels - 1, to: 0, by: -1) {
            fullscreen(cb, into: bloom[i - 1], load: .load, pipeline: up) { $0.setFragmentTexture(self.bloom[i], index: 0) }
        }
        let useDof = s.quality != .lite && s.dof > 0.01
        if useDof {
            var u = SIMD2<Float>(s.dof, s.focusDepth)
            fullscreen(cb, into: dofTex, pipeline: dof) { e in
                e.setFragmentTexture(hdr, index: 0)
                e.setFragmentTexture(depth, index: 1)
                e.setFragmentBytes(&u, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            }
        }
        var c: [Float] = [s.exposure, s.bloom, s.grain, s.vignette, s.warmth, s.time, Float(s.grade), useDof ? 1 : 0]
        guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.setRenderPipelineState(composite)
        e.setFragmentTexture(hdr, index: 0)
        e.setFragmentTexture(useDof ? dofTex : hdr, index: 1)
        e.setFragmentTexture(bloom[0], index: 2)
        e.setFragmentBytes(&c, length: c.count * MemoryLayout<Float>.size, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}
