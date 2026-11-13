import XCTest
import InStrumDSP

/// The preset's and the world's trims in the Sound Core (`isd_synth_set_trim`, `isd_ambience_set_trim`): a plain gain on
/// the whole output, there from the first sample when it is set before the first render, gliding in a straight line when
/// it changes (over 30 ms for an instrument, 0.5 s for the ambience), and nothing at all at 1.
final class TrimTests: XCTestCase {
    static let rate = 48_000.0
    /// Where a trim changes in the renders below: the start of the 256-sample block that holds 1 s.
    static let changeAt = 188 * 256

    /// Two seconds of a held chord on Felt Glass, its trim set to `first` before the first render (nil: never set) and to
    /// `later` at `changeAt`.
    static func instrument(first: Float?, later: Float? = nil) -> (l: [Float], r: [Float]) {
        guard let s = isd_synth_create(ISD_ENGINE_FELT_GLASS, rate, 512) else { return ([], []) }
        defer { isd_synth_destroy(s) }
        if let first { isd_synth_set_trim(s, first) }
        for note: UInt8 in [48, 55, 60, 64] {
            let on: [UInt8] = [0x90, note, 100]
            on.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, 3, 0) }
        }
        let total = Int(2 * rate)
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0
        while i < total {
            if i == changeAt, let later { isd_synth_set_trim(s, later) }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, 256) }
            }
            i += 256
        }
        return (l, r)
    }

    /// Two seconds of the lake's water (level 0.8), its trim set to `first` before the first render (nil: never set) and
    /// to `later` at `changeAt`.
    static func ambience(first: Float?, later: Float? = nil) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(rate, 512, 7) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_WATER, 0.8)
        if let first { isd_ambience_set_trim(a, first) }
        let total = Int(2 * rate)
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0
        while i < total {
            if i == changeAt, let later { isd_ambience_set_trim(a, later) }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, 256) }
            }
            i += 256
        }
        return (l, r)
    }

    /// The gain `trimmed` carries over `plain`, sample by sample over `range`, where `plain` is loud enough to tell.
    static func gains(_ plain: [Float], _ trimmed: [Float], _ range: Range<Int>) -> [Double] {
        range.compactMap { (i: Int) -> Double? in abs(plain[i]) > 1e-4 ? Double(trimmed[i]) / Double(plain[i]) : nil }
    }

    /// Set before the first render, a trim is a plain gain from the first sample; at 1 (or never set) the output is the
    /// engine's to the bit.
    func testATrimIsAPlainGain() {
        let plain = Self.instrument(first: nil), unity = Self.instrument(first: 1), half = Self.instrument(first: 0.5)
        XCTAssertFalse(plain.l.isEmpty)
        XCTAssertTrue(plain.l == unity.l && plain.r == unity.r, "at 1 nothing changes")
        XCTAssertTrue(zip(plain.l, half.l).allSatisfy { $0.0 * 0.5 == $0.1 }, "the instrument at half from the first sample")
        XCTAssertTrue(zip(plain.r, half.r).allSatisfy { $0.0 * 0.5 == $0.1 })
        XCTAssertEqual(isd_synth_get_trim(nil), 1)

        let still = Self.ambience(first: nil), level = Self.ambience(first: 1), double = Self.ambience(first: 2)
        XCTAssertTrue(still.l == level.l && still.r == level.r, "the ambience at 1: nothing changes")
        XCTAssertTrue(zip(still.l, double.l).allSatisfy { $0.0 * 2 == $0.1 }, "the ambience doubled from the first sample")
        XCTAssertTrue(zip(still.r, double.r).allSatisfy { $0.0 * 2 == $0.1 })
        XCTAssertEqual(isd_ambience_get_trim(nil), 1)
    }

    /// A trim that changes while it plays glides there in a straight line: an instrument's over 30 ms, the ambience's over
    /// 0.5 s; untouched before, halfway at half the time, there after, and never a step on the way.
    func testATrimGlides() {
        let cases: [(name: String, plain: [Float], moved: [Float], glide: Int)] = [
            ("instrument", Self.instrument(first: nil).l, Self.instrument(first: 1, later: 0.25).l, Int(0.03 * Self.rate)),
            ("ambience", Self.ambience(first: nil).l, Self.ambience(first: 1, later: 0.25).l, Int(0.5 * Self.rate)),
        ]
        let at = Self.changeAt
        for c in cases {
            XCTAssertTrue(Array(c.plain[..<at]) == Array(c.moved[..<at]), "\(c.name): untouched before the change")
            let during = Self.gains(c.plain, c.moved, at..<(at + c.glide))
            XCTAssertGreaterThan(during.count, c.glide / 4, c.name)
            XCTAssertGreaterThan(during.first ?? 0, 0.99, c.name)
            XCTAssertTrue(zip(during, during.dropFirst()).allSatisfy { $0.1 <= $0.0 + 1e-5 }, "\(c.name): it only falls")
            let middle = Self.gains(c.plain, c.moved, (at + c.glide / 2 - 10)..<(at + c.glide / 2 + 10))
            XCTAssertFalse(middle.isEmpty, c.name)
            XCTAssertTrue(middle.allSatisfy { abs($0 - 0.625) < 0.01 }, "\(c.name): halfway at half the time, \(middle.first ?? 0)")
            let after = Self.gains(c.plain, c.moved, (at + c.glide)..<c.plain.count)
            XCTAssertFalse(after.isEmpty, c.name)
            XCTAssertTrue(after.allSatisfy { abs($0 - 0.25) < 1e-5 }, "\(c.name): there after the glide")
        }
    }
}
