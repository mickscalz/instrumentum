import XCTest
import InStrumDSP

// MARK: - Small Wins: the Spaceship Lounge's chime in your key (spec §7, Task 10)

/// Measured first on the C++ mirror (this file's cases through the C API, g++ 13 and clang++, both -O2): every struck f0
/// within 2.0 cents of its tone (the chime's own ±2 cent detune), D major's five tones all heard in 60 strikes, a ring
/// struck at C6 in C major keeping 1045.910 Hz through a change to F♯ minor with its 600–1300 Hz peak at 1045.98 Hz
/// (99 cents from any F♯-minor tone), and the strike after it at F♯5 (740.24 Hz).
extension AmbienceTests {
    static func strikeChime(at t: Double) -> Action { (t, { isd_ambience_debug_strike_chime($0) }) }

    /// MIDI note `m` in Hz.
    static func midiHz(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

    /// A key's pentatonic in the chime's octave, MIDI 75–87 (E♭5–E♭6).
    static func chimeTones(root: Int, major: Bool) -> [Double] {
        let scale = major ? [0, 2, 4, 7, 9] : [0, 3, 5, 7, 10]
        return (75...87).filter { scale.contains((($0 - root) % 12 + 12) % 12) }.map(midiHz)
    }

    /// How far `f` is from the nearest of `tones`, in cents.
    static func centsAway(_ f: Double, _ tones: [Double]) -> Double {
        tones.map { abs(DSPTestKit.cents(f, $0)) }.min() ?? .infinity
    }

    /// Strikes the chime `count` times through the C API, a short render after each, and returns each struck f0.
    static func chimeStrikes(_ a: OpaquePointer, count: Int, every seconds: Double = 0.05) -> [Double] {
        var l = [Float](repeating: 0, count: 256), r = l
        var out: [Double] = []
        for _ in 0..<count {
            isd_ambience_debug_strike_chime(a)
            for _ in 0..<max(1, Int(seconds * sr / 256)) { isd_ambience_render(a, &l, &r, 256) }
            out.append(Double(isd_ambience_debug_chime_hz(a)))
        }
        return out
    }

    /// Key D major: every strike rings E5, F♯5, A5, B5 or D6 (within 3 cents), and all five are heard.
    func testChimeSitsInTheKey() throws {
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_CHIME, 1)
        isd_ambience_set_key(a, 2, 1)
        let tones = [659.26, 739.99, 880.00, 987.77, 1174.66]
        XCTAssertEqual(Self.chimeTones(root: 2, major: true).count, 5)
        for (t, expected) in zip(Self.chimeTones(root: 2, major: true), tones) { XCTAssertEqual(t, expected, accuracy: 0.01) }
        let struck = Self.chimeStrikes(a, count: 60)
        for f in struck { XCTAssertLessThanOrEqual(Self.centsAway(f, tones), 3, "\(f) Hz") }
        let heard = Set(struck.compactMap { f in tones.firstIndex { abs(DSPTestKit.cents(f, $0)) <= 3 } })
        XCTAssertEqual(heard.count, 5, "all five tones in 60 strikes")
    }

    /// Every key, major and minor: each strike is a tone of its pentatonic inside E♭5–E♭6; E♭ major is the six it
    /// always rang.
    func testEveryKeyStaysInTheChimesOctave() throws {
        XCTAssertEqual(Self.chimeTones(root: 3, major: true).map { ($0 * 100).rounded() / 100 }, [622.25, 698.46, 783.99, 932.33, 1046.5, 1244.51])
        for root in 0..<12 {
            for major in [true, false] {
                let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, UInt64(7 + root * 2 + (major ? 1 : 0))))
                defer { isd_ambience_destroy(a) }
                isd_ambience_set_level(a, ISD_AMB_CHIME, 1)
                isd_ambience_set_key(a, Int32(root), major ? 1 : 0)
                let tones = Self.chimeTones(root: root, major: major)
                XCTAssertTrue((5...6).contains(tones.count), "\(root) \(major)")
                for f in Self.chimeStrikes(a, count: 40, every: 0.02) {
                    XCTAssertLessThanOrEqual(Self.centsAway(f, tones), 3, "root \(root) \(major ? "major" : "minor"): \(f) Hz")
                    XCTAssertTrue((620...1247).contains(f), "\(f) Hz in E♭5–E♭6")
                }
            }
        }
    }

    /// Before a key is sensed the chime rings its own six (E♭ major pentatonic), and a key that can't be sensed (−1)
    /// changes nothing, before or after one is.
    func testChimeKeepsItsNotesUntilAKeyIsSensed() throws {
        let today = [622.25, 698.46, 783.99, 932.33, 1046.50, 1244.51]
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 3))
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_CHIME, 1)
        isd_ambience_set_key(a, -1, 0)
        let before = Self.chimeStrikes(a, count: 60)
        for f in before { XCTAssertLessThanOrEqual(Self.centsAway(f, today), 3, "\(f) Hz") }
        XCTAssertEqual(Set(before.compactMap { f in today.firstIndex { abs(DSPTestKit.cents(f, $0)) <= 3 } }).count, 6)
        isd_ambience_set_key(a, 2, 1)
        isd_ambience_set_key(a, -1, 0)
        isd_ambience_set_key(a, 12, 1)
        for f in Self.chimeStrikes(a, count: 30) {
            XCTAssertLessThanOrEqual(Self.centsAway(f, Self.chimeTones(root: 2, major: true)), 3, "still D major: \(f) Hz")
        }
    }

    /// Review focus: a new key waits for the next strike. Struck in C major at 3 s (C6, with this seed), the key moves to
    /// F♯ minor at 3.5 s: the ring keeps its pitch, and its strongest 600–1300 Hz peak stays on C6, nowhere near an
    /// F♯-minor tone; the strike at 12 s is one of F♯ minor's.
    func testChimeNeverChangesMidRing() {
        var struck: Float = 0
        var readings: [Float] = []
        var next: Float = 0
        let out = Self.render(seconds: 12.5, seed: 2, actions: [
            Self.level(ISD_AMB_CHIME, 1), Self.key(0, major: true), Self.strikeChime(at: 3),
            (3.2, { struck = isd_ambience_debug_chime_hz($0) }), Self.key(6, major: false, at: 3.5),
            (4, { readings.append(isd_ambience_debug_chime_hz($0)) }), (6, { readings.append(isd_ambience_debug_chime_hz($0)) }),
            (8, { readings.append(isd_ambience_debug_chime_hz($0)) }),
            Self.strikeChime(at: 12), (12.2, { next = isd_ambience_debug_chime_hz($0) }),
        ])
        let c = Self.chimeTones(root: 0, major: true), fSharpMinor = Self.chimeTones(root: 6, major: false)
        XCTAssertLessThanOrEqual(Self.centsAway(Double(struck), c), 3, "struck in C major: \(struck) Hz")
        XCTAssertEqual(Double(struck), 1046.50, accuracy: 2, "C6 with seed 2")
        XCTAssertEqual(readings, [struck, struck, struck], "unchanged at 4, 6 and 8 s")
        let size = 1 << 18
        let spectrum = DSPTestKit.powerSpectrum(SynthRender.slice(Self.mid(out), 3.6, 6), size: size)
        let peak = Self.strongest(spectrum, size: size, 600, 1300).hz
        XCTAssertLessThanOrEqual(abs(DSPTestKit.cents(peak, Double(struck))), 5, "the ring's peak at \(peak) Hz")
        XCTAssertGreaterThan(Self.centsAway(peak, fSharpMinor), 50, "nowhere near F♯ minor")
        XCTAssertTrue(fSharpMinor.contains { abs($0 - 1108.73) < 0.01 }, "C♯6 is among F♯ minor's")
        XCTAssertLessThanOrEqual(Self.centsAway(Double(next), fSharpMinor), 3, "the next strike: \(next) Hz")
    }

    /// The bell keeps reading the key's root and mode alongside the chime's sensed bit: E before any key, D after D major.
    func testTheBellStillReadsTheKey() throws {
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(4), accuracy: 1e-3, "E before any key")
        isd_ambience_set_key(a, 2, 1)
        XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(2), accuracy: 1e-3, "D after D major")
        var l = [Float](repeating: 0, count: 256), r = l
        isd_ambience_set_level(a, ISD_AMB_TEMPLE_BELL, 1)
        isd_ambience_debug_strike_bell(a)
        isd_ambience_render(a, &l, &r, 256)
        XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(2), accuracy: 1e-3, "and strikes D")
    }

    /// 0 until the chime is up and struck, and 0 again once its ring has died or its level has gone.
    func testChimeHzIsZeroWhileSilent() throws {
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        var l = [Float](repeating: 0, count: 256), r = l
        func run(_ seconds: Double) { for _ in 0..<Int(seconds * Self.sr / 256) { isd_ambience_render(a, &l, &r, 256) } }
        XCTAssertEqual(isd_ambience_debug_chime_hz(a), 0)
        isd_ambience_debug_strike_chime(a)
        run(0.1)
        XCTAssertEqual(isd_ambience_debug_chime_hz(a), 0, "struck with its level at 0: nothing rings")
        isd_ambience_set_level(a, ISD_AMB_CHIME, 1)
        run(1)
        XCTAssertEqual(isd_ambience_debug_chime_hz(a), 0, "up, but not struck (and nothing from before)")
        isd_ambience_debug_strike_chime(a)
        run(0.1)
        XCTAssertGreaterThan(isd_ambience_debug_chime_hz(a), 600, "ringing")
        run(14)
        XCTAssertEqual(isd_ambience_debug_chime_hz(a), 0, "rung out (about 10 s)")
        isd_ambience_debug_strike_chime(a)
        run(0.1)
        isd_ambience_set_level(a, ISD_AMB_CHIME, 0)
        run(3)
        XCTAssertEqual(isd_ambience_debug_chime_hz(a), 0, "faded out with its level")
        XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
    }
}
