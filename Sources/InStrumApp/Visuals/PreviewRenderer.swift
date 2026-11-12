import Metal
import CoreGraphics
import ImageIO
import Foundation
import InStrumCore

/// Renders themes off-screen from the scripted demo performance, so frames can be
/// checked (and saved as PNGs) without a window.
@MainActor
final class PreviewRenderer {
    let width: Int, height: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stack: RenderStack
    private let target: MTLTexture

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let stack = RenderStack(device: device, pixelFormat: .bgra8Unorm) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        stack.resize(width: width, height: height)
        self.width = width; self.height = height
        self.device = device; self.queue = queue; self.stack = stack; self.target = target
        // Previews show the real stars: wait for the shared background build (once per process), so no frame
        // changes halfway through a comparison when it lands.
        StarTextureCache.shared.request(device: device)
        StarTextureCache.shared.awaitTexture()
    }

    /// Simulates the demo performance at 60 fps through the app's SceneDirector and captures
    /// a frame of `themeID` at each time (seconds).
    /// `sky` overrides the Living Sky for worlds (frozen settings give repeatable frames); `mood` sets the set's mood.
    /// `skyEdit` holds each frame's sky in a state the Living Sky only reaches over minutes (a world fully rimed).
    /// `controls` gives the director's controls at each time (hold the moment, the sleep dim, Reduce Motion); the
    /// renderers then step by the director's `visualDt`, and each capture takes its `exposureScale`.
    func render(themeID: String, at times: [Double], state: ThemeState = ThemeState(), quality: QualityLevel = .high,
                sky: SkySettings? = nil, mood: Mood = .neutral, gentle: Bool = false,
                skyEdit: ((inout SkyState) -> Void)? = nil, controls: ((Double) -> SceneControls)? = nil) -> [CGImage] {
        let director = SceneDirector(themeID: themeID, state: state, reaction: ReactionPresets.expressivePianist)
        let start = Date(timeIntervalSince1970: 1_793_000_000)   // a fixed wall clock, so previews repeat
        var elapsed = 0.0
        director.clock = { start.addingTimeInterval(elapsed) }
        if let sky { director.sky.reset(settings: sky) }   // settled weather from the first frame
        director.mood = mood
        var perf = PerformanceState()
        let script = ScriptedPerformance.demo
        var next = 0, time = 0.0
        let frameStep = 1.0 / 60
        var garden: ButterflyRenderer?, steinway: SteinwayRenderer?, moonlitLake: MoonlitLakeRenderer?
        var lounge: SpaceshipLoungeRenderer?, beach: GoldenHourBeachRenderer?, road: CoastRoadRenderer?
        var cabin: SnowboundCabinRenderer?
        var bedroom: BedroomDawnRenderer?
        var fjord: AuroraFjordRenderer?
        var bay: BioluminescentBayRenderer?
        var teaHouse: TeaHouseSnowRenderer?
        var zenGarden: ZenRockGardenRenderer?
        var submarine: SubmarineWindowRenderer?
        var reef: GreatBarrierReefRenderer?
        var plains: LightningPlainsRenderer?
        var supercell: SupercellSkyRenderer?
        var volcano: VolcanoRimRenderer?
        var drive: NeonNightDriveRenderer?
        var images: [CGImage] = []
        for t in times.sorted() {
            var current: ThemeRenderer?
            while time + frameStep <= t || current == nil {
                time += frameStep
                var events: [PerformanceEvent] = []
                while next < script.count, script[next].time <= time {
                    events += perf.apply(script[next].message, at: script[next].time)
                    next += 1
                }
                if let controls { director.controls = controls(time) }
                director.handle(events, at: time)
                elapsed = time
                var frame = director.step(dt: frameStep, t: time, quality: quality)
                let dt = director.visualDt
                if let skyEdit { frame = Self.editingSky(frame, skyEdit) }
                let size = CGSize(width: width, height: height)
                if let g = frame as? GardenFrame {
                    if garden == nil { garden = ButterflyRenderer(device: device) }
                    garden?.update(g, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = garden
                } else if let f = frame as? SteinwayFrame {
                    if steinway == nil { steinway = SteinwayRenderer(device: device) }
                    steinway?.update(f, quality: quality, gentle: gentle, dt: dt)
                    current = steinway
                } else if let l = frame as? LakeFrame {
                    if moonlitLake == nil { moonlitLake = MoonlitLakeRenderer(device: device) }
                    moonlitLake?.update(l, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = moonlitLake
                } else if let l = frame as? LoungeFrame {
                    if lounge == nil { lounge = SpaceshipLoungeRenderer(device: device) }
                    lounge?.update(l, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = lounge
                } else if let b = frame as? BeachFrame {
                    if beach == nil { beach = GoldenHourBeachRenderer(device: device) }
                    beach?.update(b, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = beach
                } else if let r = frame as? RoadFrame {
                    if road == nil { road = CoastRoadRenderer(device: device) }
                    road?.update(r, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = road
                } else if let c = frame as? CabinFrame {
                    if cabin == nil {
                        cabin = SnowboundCabinRenderer(device: device)
                        cabin?.awaitField()   // previews show the grown frost, not the fallback
                    }
                    cabin?.update(c, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = cabin
                } else if let b = frame as? BedroomFrame {
                    if bedroom == nil {
                        bedroom = BedroomDawnRenderer(device: device)
                        bedroom?.awaitField()
                    }
                    bedroom?.update(b, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = bedroom
                } else if let f = frame as? FjordFrame {
                    if fjord == nil { fjord = AuroraFjordRenderer(device: device) }
                    fjord?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = fjord
                } else if let y = frame as? BayFrame {
                    if bay == nil { bay = BioluminescentBayRenderer(device: device) }
                    bay?.update(y, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = bay
                } else if let h = frame as? TeaHouseFrame {
                    if teaHouse == nil {
                        teaHouse = TeaHouseSnowRenderer(device: device)
                        teaHouse?.awaitField()   // Frost Grow shows the grown frost, not the fallback
                    }
                    teaHouse?.update(h, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = teaHouse
                } else if let z = frame as? ZenGardenFrame {
                    if zenGarden == nil { zenGarden = ZenRockGardenRenderer(device: device) }
                    zenGarden?.update(z, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = zenGarden
                } else if let w = frame as? SubFrame {
                    if submarine == nil { submarine = SubmarineWindowRenderer(device: device) }
                    submarine?.update(w, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = submarine
                } else if let f = frame as? ReefFrame {
                    if reef == nil { reef = GreatBarrierReefRenderer(device: device) }
                    reef?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = reef
                } else if let f = frame as? PlainsFrame {
                    if plains == nil { plains = LightningPlainsRenderer(device: device) }
                    plains?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = plains
                } else if let f = frame as? SupercellFrame {
                    if supercell == nil { supercell = SupercellSkyRenderer(device: device) }
                    supercell?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = supercell
                } else if let f = frame as? VolcanoFrame {
                    if volcano == nil { volcano = VolcanoRimRenderer(device: device) }
                    volcano?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = volcano
                } else if let f = frame as? DriveFrame {
                    if drive == nil { drive = NeonNightDriveRenderer(device: device) }
                    drive?.update(f, params: director.parameters, quality: quality, gentle: gentle, dt: dt, size: size)
                    current = drive
                }
                if time + frameStep > t { break }
            }
            if let r = current, let image = capture(r, exposureScale: director.exposureScale) { images.append(image) }
        }
        return images
    }

    /// A world's frame with its sky edited (frames without a sky pass through unchanged).
    static func editingSky(_ frame: Any, _ edit: (inout SkyState) -> Void) -> Any {
        switch frame {
        case var f as LakeFrame: edit(&f.sky); return f
        case var f as LoungeFrame: edit(&f.sky); return f
        case var f as BeachFrame: edit(&f.sky); return f
        case var f as RoadFrame: edit(&f.sky); return f
        case var f as CabinFrame: edit(&f.sky); return f
        case var f as BedroomFrame: edit(&f.sky); return f
        case var f as FjordFrame: edit(&f.sky); return f
        case var f as BayFrame: edit(&f.sky); return f
        case var f as TeaHouseFrame: edit(&f.sky); return f
        case var f as ZenGardenFrame: edit(&f.sky); return f
        case var f as SubFrame: edit(&f.sky); return f
        case var f as ReefFrame: edit(&f.sky); return f
        case var f as PlainsFrame: edit(&f.sky); return f
        case var f as SupercellFrame: edit(&f.sky); return f
        case var f as VolcanoFrame: edit(&f.sky); return f
        case var f as DriveFrame: edit(&f.sky); return f
        default: return frame
        }
    }

    func renderButterflyGarden(at times: [Double], params: ParameterSet? = nil) -> [CGImage] {
        render(themeID: ButterflyGardenModel.id, at: times, state: ThemeState(values: params?.saved ?? [:]))
    }

    /// `exposureScale` multiplies the renderer's post exposure, as the canvas does with the director's.
    func capture(_ renderer: ThemeRenderer, exposureScale: Float = 1) -> CGImage? {
        guard let cb = queue.makeCommandBuffer() else { return nil }
        renderer.render(stack: stack, commandBuffer: cb)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        var post = renderer.post
        post.exposure *= exposureScale
        stack.post(into: pass, commandBuffer: cb, settings: post)
        let bytesPerRow = width * 4
        guard let out = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: out, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let data = Data(bytes: out.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func luminances(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let y: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i] = y / 255
        }
        return out
    }

    static func stats(_ image: CGImage) -> (meanLuminance: Double, variance: Double) {
        let l = luminances(image)
        let mean = l.reduce(0, +) / Double(l.count)
        let variance = l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count)
        return (mean, variance)
    }

    /// The brightest region: the highest mean luminance of any (2r+1)² patch (summed-area table), so a large
    /// lit disc beats a single bright star.
    static func brightestPatch(_ image: CGImage, radius: Int) -> Double {
        let l = luminances(image), w = image.width, h = image.height, k = 2 * radius + 1
        guard w >= k, h >= k else { return 0 }
        var sat = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += l[y * w + x]
                sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row
            }
        }
        var best = 0.0
        for y in 0...(h - k) {
            for x in 0...(w - k) {
                let a = sat[y * (w + 1) + x], b = sat[y * (w + 1) + x + k], c = sat[(y + k) * (w + 1) + x], d = sat[(y + k) * (w + 1) + x + k]
                best = max(best, d - b - c + a)
            }
        }
        return best / Double(k * k)
    }

    /// Mean absolute luminance difference (images must be the same size).
    static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let la = luminances(a), lb = luminances(b)
        return zip(la, lb).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(la.count)
    }
}

