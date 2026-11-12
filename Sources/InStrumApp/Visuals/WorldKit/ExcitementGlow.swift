import Foundation

/// A world's excitement light (a moment's glow, a surprise's) through the scene's own `FlashLimiter` (Fire & Neon spec
/// §5.2, §13): the light asks the exposure for a lift, the limiter decides how much of it passes, and what is drawn is
/// the light × that share. Under gentle visuals the lift is at most a glow (≤ 0.1, which the limiter's own halving keeps
/// far under a flash's 0.25), and the drawn light eases in over 0.8 s at 0.6 of its strength: never a flash.
struct ExcitementGlow {
    /// The light drawn now (0…1).
    private(set) var shown: Float = 0

    static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// The exposure's lift a light of `request` (0…1) asks for: `scale` × it; under gentle visuals at most 0.1.
    static func ask(_ request: Float, gentle: Bool, scale: Float) -> Float {
        let r = unit(request)
        return gentle ? min(0.1, 0.35 * r) : max(0, scale) * r
    }

    /// The share of the lift `asked` that the limiter let through (`limited` from `base`), 0…1 (1 when nothing was asked).
    static func passed(limited: Float, base: Float, asked: Float) -> Float {
        guard asked > 1e-4, base > 1e-6, limited.isFinite else { return 1 }
        return unit((limited / base - 1) / asked)
    }

    /// The light drawn this frame for `request` with the limiter's share `passed`: at once (falls never wait), or under
    /// gentle visuals eased toward 0.6 of it (τ 0.8 s; at once while time is held).
    mutating func update(request: Float, passed: Float, gentle: Bool, dt: Double) -> Float {
        let r = Self.unit(request)
        if gentle {
            let target = 0.6 * r
            let fdt = Float(dt.isFinite ? min(max(dt, 0), 0.25) : 0)
            let k: Float = dt == 0 ? 1 : 1 - exp(-fdt / 0.8)
            shown += (target - shown) * k
        } else {
            shown = r * Self.unit(passed)
        }
        shown = Self.unit(shown)
        return shown
    }
}
