import Foundation

/// Breathing ambience (Small Wins spec §5): each continuous bed swells and recedes on its own, in long slow arcs, so a
/// world never sounds like a loop.
///
/// Each bed's swell is the sum of two sines: the first's period 40–90 s, the second's 1.35–1.75 times that (so they
/// never line up), with phases of their own. Both are drawn from the seed and the bed's name, so the beds don't move
/// together. The level the world asks for, L, becomes min(1, L × max(0.6, f)) with f = 1 ± 0.25 × depth, quantised to
/// 0.01 so the app only sends real changes. One-shots (the owl, the chime, gulls, thunder, waves, the bell, the sonar)
/// and every other source are left as they are. It runs on real time, so it breathes through a held moment.
public struct AmbienceBreath {
    /// Exactly the spec's fifteen beds, by raw value.
    public static let beds: Set<String> = [
        "rainOnWater", "rainOnGlass", "wind", "breeze", "surf", "waterfall", "water", "crickets", "shipHum", "airFlow",
        "kettle", "fire", "street", "snappingShrimp", "lapping",
    ]
    /// ±25% at depth 1; never below 60% of the world's level; levels in steps of 0.01.
    public static let swing = 0.25, floor = 0.6, quantum = 0.01

    /// How far the beds swing, × `swing` (the setting's 0…1.5).
    public var depth = 1.0

    /// One bed's two sines: their periods (seconds) and phases (cycles).
    struct Swell: Equatable {
        var p1, p2, phi1, phi2: Double
    }

    let swells: [AmbienceSource: Swell]

    public init(seed: UInt64) {
        var swells: [AmbienceSource: Swell] = [:]
        for name in Self.beds {
            guard let source = AmbienceSource(rawValue: name) else { continue }
            var h: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a, as LivingSky.dawnIsPastel: stable across launches
            for b in name.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
            var r = SeededRandom(seed: (seed &* 0x9E37_79B9_7F4A_7C15) ^ h)
            let u = Double(r.unit()), u2 = Double(r.unit()), phi1 = Double(r.unit()), phi2 = Double(r.unit())
            let p1 = 40 + 50 * u
            swells[source] = Swell(p1: p1, p2: p1 * (1.35 + 0.4 * u2), phi1: phi1, phi2: phi2)
        }
        self.swells = swells
    }

    /// What a source's level is multiplied by at `t` (seconds): 1 for anything but a bed, else max(0.6, f).
    public func factor(_ source: AmbienceSource, at t: Double) -> Double {
        guard let s = swells[source] else { return 1 }
        return Self.factor(s, depth: depth, at: t)
    }

    static func factor(_ s: Swell, depth: Double, at t: Double) -> Double {
        let time = t.isFinite ? t : 0
        let d = depth.isFinite ? min(1.5, max(0, depth)) : 1
        let a = sin(2 * Double.pi * (time / s.p1 + s.phi1))
        let b = sin(2 * Double.pi * (time / s.p2 + s.phi2))
        return max(Self.floor, 1 + Self.swing * d * (a + b) / 2)
    }

    /// Breathes the scene's beds at `t`; every other source, and everything else in the scene, is left alone.
    public func apply(to scene: inout AmbienceScene, at t: Double) {
        let steps = 1 / Self.quantum
        for (source, level) in scene.levels where level > 0 {
            guard let s = swells[source] else { continue }
            let breathed = min(1, level * Self.factor(s, depth: depth, at: t))
            scene.levels[source] = (breathed * steps).rounded() / steps
        }
    }
}
