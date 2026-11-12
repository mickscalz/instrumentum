/// Picks the render quality.
/// - Auto starts at Smooth (lite), steps up to High after 10 s at 58 fps or better, and back
///   down after 1 s below 50 fps. It never goes above High.
/// - Safety net, for every setting: two frames in a row taking 0.25 s or more drop to Smooth
///   for the rest of the session (or until a quality is chosen again), so a slow Mac never locks up.
/// - The graphics chip's own clock, for every setting (`record(frameTime:gpuTime:)`): one frame that keeps the GPU busy
///   for `gpuStall` or more drops to Smooth at once and halves the picture. An Intel Mac's GPU kept saturated can freeze
///   the whole machine (12 Nov: Supercell Sky on Michael's Intel MacBook Pro), so the app never waits for a second one.
///   At Smooth, frames still heavier than `gpuHeavy` shrink the picture further (to `minPixelScale` of its pixels at
///   least), and `growFor` seconds of easy frames let it grow back.
/// Pass the real time between frames (not a clamped value).
public struct AutoQuality {
    public static let slowFPS = 50.0, goodFPS = 58.0
    public static let slowFor = 1.0, goodFor = 10.0
    public static let stallFrame = 0.25
    public static let gpuStall = 0.1, gpuHeavy = 0.045, gpuEasy = 0.022
    public static let growFor = 5.0, resizeEvery = 0.3
    public static let minPixelScale = 0.25

    /// The share of the quality's pixels to draw (by area): 1 normally, less while even Smooth is too heavy.
    public private(set) var pixelScale = 1.0
    private var easyTime = 0.0, sinceResize = 0.0

    public var setting: QualitySetting {
        didSet { if setting != oldValue { rescued = false; stalls = 0 } }
    }
    /// True once the safety net has stepped in.
    public private(set) var rescued = false
    private var level: QualityLevel = .lite
    private var slowTime = 0.0, goodTime = 0.0
    private var stalls = 0

    public init(setting: QualitySetting) { self.setting = setting }

    /// One frame, with the GPU time of the slowest frame the graphics chip finished since the last call (0 if none).
    public mutating func record(frameTime: Double, gpuTime: Double) -> QualityLevel {
        let ft = frameTime.isFinite ? max(0, frameTime) : 0
        let gpu = gpuTime.isFinite ? max(0, gpuTime) : 0
        sinceResize += ft
        if gpu >= Self.gpuStall {
            // One frame this heavy is enough: Smooth now, and half the pixels (Smooth itself may be too much).
            if !rescued || sinceResize >= Self.resizeEvery {
                pixelScale = max(Self.minPixelScale, pixelScale * 0.5)
                sinceResize = 0
            }
            rescued = true
            level = .lite
            easyTime = 0
        } else if gpu >= Self.gpuHeavy, isSmooth {
            if sinceResize >= Self.resizeEvery {
                pixelScale = max(Self.minPixelScale, pixelScale * 0.8)
                sinceResize = 0
            }
            easyTime = 0
        } else if gpu > 0, gpu < Self.gpuEasy, pixelScale < 1 {
            easyTime += ft
            if easyTime >= Self.growFor {
                pixelScale = min(1, pixelScale * 1.25)
                easyTime = 0
            }
        } else if gpu > 0 {
            easyTime = 0
        }
        return record(frameTime: frameTime)
    }

    /// True while drawing at Smooth (chosen, Auto's start, or the safety net).
    private var isSmooth: Bool { rescued || setting == .lite || (setting == .auto && level == .lite) }

    public mutating func record(frameTime: Double) -> QualityLevel {
        if frameTime >= Self.stallFrame { stalls += 1 } else { stalls = 0 }
        if stalls >= 2 { rescued = true; level = .lite }
        if rescued { return .lite }
        switch setting {
        case .lite: return .lite
        case .high: return .high
        case .ultra: return .ultra
        case .auto: break
        }
        guard frameTime > 0 else { return level }
        let fps = 1 / frameTime
        if fps < Self.slowFPS { slowTime += frameTime; goodTime = 0 } else { slowTime = 0 }
        if fps >= Self.goodFPS { goodTime += frameTime }
        if slowTime >= Self.slowFor, level != .lite {
            level = .lite
            slowTime = 0; goodTime = 0
        } else if goodTime >= Self.goodFor, level == .lite {
            level = .high
            goodTime = 0
        }
        return level
    }
}

/// How many pixels to draw for a window: Smooth draws far fewer and lets the screen scale up.
public enum RenderScale {
    /// Fraction of the screen's native pixels per side.
    public static let factor: [QualityLevel: Double] = [.lite: 0.5, .high: 0.75, .ultra: 1.0]
    /// Smooth never draws more than this many pixels, however big the window.
    public static let liteMaxPixels = 1_000_000.0

    /// The most pixels each quality draws on an Intel or AMD graphics chip, however big the window (Apple's GPUs draw
    /// the full factor at High and Ultra).
    public static let otherGPUMaxPixels: [QualityLevel: Double] = [.lite: 1_000_000, .high: 1_600_000, .ultra: 2_400_000]

    /// - `pixelScale`: the share of those pixels to draw (by area), from `AutoQuality.pixelScale`.
    /// - `appleGPU`: false on an Intel or AMD graphics chip, which caps every quality (`otherGPUMaxPixels`).
    public static func pixels(points: (Double, Double), backingScale: Double, quality: QualityLevel,
                              pixelScale: Double = 1, appleGPU: Bool = true) -> (width: Int, height: Int) {
        let w = max(1, points.0), h = max(1, points.1)
        var s = max(1, backingScale) * (factor[quality] ?? 1)
        var cap = quality == .lite ? liteMaxPixels : Double.infinity
        if !appleGPU { cap = min(cap, otherGPUMaxPixels[quality] ?? liteMaxPixels) }
        let share = pixelScale.isFinite ? min(1, max(0.01, pixelScale)) : 1
        let full = w * h * s * s
        let budget = min(cap, full) * share
        var capped = false
        if budget < full { s = min(s, (budget / (w * h)).squareRoot()); capped = true }
        let round: (Double) -> Int = capped ? { Int($0.rounded(.down)) } : { Int($0.rounded()) }
        return (max(1, round(w * s)), max(1, round(h * s)))
    }
}
