/// Keeps sudden bright flashes below safe limits: at most 3 large jumps per second.
/// A large jump is exposure rising more than 0.25 within 0.1 s. Falls are never limited.
public struct FlashLimiter {
    public static let maxFlashesPerSecond = 3
    public static let flashRise: Float = 0.25
    public static let window = 0.1
    public static let limitedRiseRate: Float = 0.25   // per second, once the limit is reached

    public var gentle: Bool
    private var output: Float = 0
    private var time = 0.0
    private var history: [(t: Double, v: Float)] = []
    private var flashes: [Double] = []
    /// What it has counted: every large jump since it began, and those within the last second (as of the last step).
    public private(set) var total = 0
    public var recent: Int { flashes.count }

    public init(gentle: Bool = false) { self.gentle = gentle }

    /// Gentle visuals halve sparkle: glints, fireflies, streaks and the like.
    public static func sparkleScale(gentle: Bool) -> Float { gentle ? 0.5 : 1 }

    public mutating func limit(exposure: Float, sparkle: Float, dt: Double) -> (exposure: Float, sparkle: Float) {
        time += dt
        flashes.removeAll { time - $0 >= 1 }
        var target = exposure
        if gentle && target > output { target = output + (target - output) * 0.5 }
        if target <= output || flashes.count < Self.maxFlashesPerSecond {
            output = target
        } else {
            output = min(target, output + Self.limitedRiseRate * Float(dt))
        }
        history.append((time, output))
        history.removeAll { time - $0.t > Self.window }
        if let oldest = history.first, output - oldest.v > Self.flashRise,
           flashes.last.map({ time - $0 > Self.window }) ?? true {
            flashes.append(time)
            total += 1
        }
        return (output, sparkle * Self.sparkleScale(gentle: gentle))
    }
}
