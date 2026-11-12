import XCTest
@testable import InStrumCore

/// Breathing ambience (Small Wins spec §5, Task 8): the fifteen beds swell and recede on their own, seeded per bed, in
/// long slow arcs inside their bounds; one-shots and every other source are left alone; the director breathes the
/// frame's scene while asked, at the controls' depth. The bounds come from a Python mirror of the swell (python3 -I):
/// over seeds 1–8 and all fifteen beds at level 0.8, at least 11 mean crossings in 10 minutes and no flat run over 17 s;
/// at seed 0xB4EA7E no pair of beds correlates above 0.554.
final class AmbienceBreathTests: XCTestCase {
    static let director = UInt64(0xB4EA_7E)

    private func level(_ b: AmbienceBreath, _ source: AmbienceSource, _ l: Double, at t: Double) -> Double {
        var scene = AmbienceScene(levels: [source: l])
        b.apply(to: &scene, at: t)
        return scene.level(source)
    }

    func testTheFifteenBeds() {
        XCTAssertEqual(AmbienceBreath.beds.count, 15)
        let named = AmbienceBreath.beds.compactMap { AmbienceSource(rawValue: $0) }
        XCTAssertEqual(named.count, 15, "every bed is a source")
        XCTAssertEqual(AmbienceBreath.swing, 0.25)
        XCTAssertEqual(AmbienceBreath.floor, 0.6)
        XCTAssertEqual(AmbienceBreath.quantum, 0.01)
        XCTAssertEqual(AmbienceBreath(seed: 1).depth, 1)
    }

    func testDeterministicPerSeed() {
        let a = AmbienceBreath(seed: 7), b = AmbienceBreath(seed: 7), c = AmbienceBreath(seed: 8)
        var differs = false
        for i in 0...600 {
            let t = Double(i)
            for name in AmbienceBreath.beds {
                guard let s = AmbienceSource(rawValue: name) else { continue }
                XCTAssertEqual(a.factor(s, at: t), b.factor(s, at: t))
                if a.factor(s, at: t) != c.factor(s, at: t) { differs = true }
            }
        }
        XCTAssertTrue(differs, "another seed breathes otherwise")
    }

    func testDepthAndFloor() {
        var shallow = AmbienceBreath(seed: 3)
        shallow.depth = 0
        var deep = AmbienceBreath(seed: 3)
        deep.depth = 1.5
        let normal = AmbienceBreath(seed: 3)
        for i in 0...1200 {
            let t = Double(i) * 0.5
            for name in AmbienceBreath.beds {
                guard let s = AmbienceSource(rawValue: name) else { continue }
                let l1 = level(normal, s, 0.8, at: t)
                let l15 = level(deep, s, 0.8, at: t)
                let l0 = level(shallow, s, 0.8, at: t)
                XCTAssertGreaterThanOrEqual(l1, 0.6 - 1e-9)
                XCTAssertLessThanOrEqual(l1, 1.0 + 1e-9)
                XCTAssertGreaterThanOrEqual(l15, 0.48 - 1e-9)
                XCTAssertLessThanOrEqual(l15, 1.0 + 1e-9)
                XCTAssertEqual(l0, 0.8, "depth 0 leaves it be")
                for l in [l1, l15] {
                    let steps = l * 100
                    XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9, "a multiple of 0.01")
                }
            }
        }
    }

    func testOneShotsUntouched() {
        let b = AmbienceBreath(seed: Self.director)
        var scene = AmbienceScene(levels: [.owl: 0.37, .chime: 0.41, .gulls: 0.53, .templeBell: 0.29, .sonar: 0.61,
                                           .thunderRoll: 0.7, .road: 0.333, .dawnChorus: 0.45, .wind: 0.8],
                                  thunder: 0.4, wave: 0.9, key: AmbienceKey(root: 2, major: true),
                                  thunderQueue: [QueuedThunder(delay: 3, strength: 0.5)])
        let before = scene
        b.apply(to: &scene, at: 123)
        for source in [AmbienceSource.owl, .chime, .gulls, .templeBell, .sonar, .thunderRoll, .road, .dawnChorus] {
            XCTAssertEqual(scene.level(source), before.level(source), "\(source)")
        }
        XCTAssertNotEqual(scene.level(.wind), 0.8, "a bed breathes")
        XCTAssertEqual(scene.thunder, 0.4)
        XCTAssertEqual(scene.wave, 0.9)
        XCTAssertEqual(scene.key, before.key)
        XCTAssertEqual(scene.thunderQueue, before.thunderQueue)
        XCTAssertEqual(scene.nightCool, before.nightCool)
        for source in AmbienceSource.allCases where !AmbienceBreath.beds.contains(source.rawValue) {
            XCTAssertEqual(b.factor(source, at: 77), 1, "\(source)")
        }
        var silent = AmbienceScene.silent
        b.apply(to: &silent, at: 50)
        XCTAssertEqual(silent, .silent)
    }

    func testBedsMoveOnTheirOwn() {
        let b = AmbienceBreath(seed: Self.director)
        let sources = AmbienceBreath.beds.sorted().compactMap { AmbienceSource(rawValue: $0) }
        let at300 = sources.map { b.factor($0, at: 300) }
        XCTAssertEqual(Set(at300).count, sources.count, "all different at 300 s")
        var series: [[Double]] = []
        for s in sources { series.append((0...1200).map { b.factor(s, at: Double($0) * 0.5) }) }
        var worst = -1.0
        for i in 0..<series.count {
            for j in (i + 1)..<series.count {
                worst = max(worst, Self.correlation(series[i], series[j]))
            }
        }
        XCTAssertLessThan(worst, 0.9, "no two beds move together (\(worst))")
    }

    func testTheBreathKeepsMoving() {
        var fewest = Int.max
        var flattest = 0.0
        for seed in UInt64(1)...8 {
            let b = AmbienceBreath(seed: seed)
            for name in AmbienceBreath.beds {
                guard let s = AmbienceSource(rawValue: name) else { continue }
                let xs = (0...1200).map { level(b, s, 0.8, at: Double($0) * 0.5) }
                let mean = xs.reduce(0, +) / Double(xs.count)
                var crossings = 0
                var above: Bool?
                for x in xs where x != mean {
                    let now = x > mean
                    if let was = above, was != now { crossings += 1 }
                    above = now
                }
                var run = 0, longest = 0
                for i in 1..<xs.count {
                    run = xs[i] == xs[i - 1] ? run + 1 : 0
                    longest = max(longest, run)
                }
                fewest = min(fewest, crossings)
                flattest = max(flattest, Double(longest) * 0.5)
            }
        }
        XCTAssertGreaterThanOrEqual(fewest, 4, "it keeps crossing its mean (\(fewest))")
        XCTAssertLessThan(flattest, 30, "never flat for 30 s (\(flattest))")
    }

    func testDeepWaterBedsByName() throws {
        guard let shrimp = AmbienceSource(rawValue: "snappingShrimp") else { throw XCTSkip("Deep Water's ambience isn't here") }
        let b = AmbienceBreath(seed: Self.director)
        var moved = false
        for i in 0...240 where b.factor(shrimp, at: Double(i)) != 1 { moved = true }
        XCTAssertTrue(moved, "the shrimp breathe")
        let sonar = try XCTUnwrap(AmbienceSource(rawValue: "sonar"))
        XCTAssertEqual(b.factor(sonar, at: 60), 1, "the sonar doesn't")
    }

    /// The director breathes the frame's scene while asked: the lake's water moves off the frame's own level within
    /// 120 s; off, the two are equal; the depth follows the controls.
    func testTheDirectorBreathesWhenAsked() throws {
        let d = SceneDirector(themeID: MoonlitLakeModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        d.clock = { Date(timeIntervalSince1970: 1_793_000_000) }
        XCTAssertTrue(d.controls.breath.enabled, "on by default")
        var moved = false
        var t = 0.0
        for _ in 0..<240 {
            t += 0.5
            let frame = d.step(dt: 0.5, t: t, quality: .lite)
            let own = try XCTUnwrap((frame as? AmbienceProviding)?.ambience).level(.water)
            let heard = d.ambience(for: frame, at: t).level(.water)
            if abs(heard - own) > 0.005 { moved = true }
        }
        XCTAssertTrue(moved, "the water breathes")

        d.controls.breath.enabled = false
        for _ in 0..<20 {
            t += 0.5
            let frame = d.step(dt: 0.5, t: t, quality: .lite)
            let own = try XCTUnwrap((frame as? AmbienceProviding)?.ambience)
            var expected = own
            expected.key = d.key
            XCTAssertEqual(d.ambience(for: frame, at: t), expected, "off: the frame's own")
        }

        d.controls.breath = AmbienceBreathSettings(enabled: true, depth: 0.5)
        var half = AmbienceBreath(seed: Self.director)
        half.depth = 0.5
        t += 0.5
        let frame = d.step(dt: 0.5, t: t, quality: .lite)
        var expected = try XCTUnwrap((frame as? AmbienceProviding)?.ambience)
        expected.key = d.key
        half.apply(to: &expected, at: t)
        XCTAssertEqual(d.ambience(for: frame, at: t), expected, "at the controls' depth")
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            sab += x * y
            saa += x * x
            sbb += y * y
        }
        return sab / (saa * sbb).squareRoot()
    }
}
