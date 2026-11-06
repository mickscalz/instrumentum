import XCTest
import InStrumDSP

/// Single Note Grand (Storms, Task 4; spec 2026-11-05-storms-design.md §4.2, brief single-note-grand.md): a cavernous
/// concert grand on Felt Glass's strings that becomes a voice under pressure, never changing its pitch. Every bound
/// below was measured first with a C++ mirror of these renders and measurements (the values are in the doc comments
/// and in the commit that brought the engine in).
final class SingleNoteGrandTests: XCTestCase {
    typealias R = SynthRender
    typealias K = DSPTestKit
    let grand = ISD_ENGINE_SINGLE_NOTE_GRAND
    let sr = DSPTestKit.sampleRate
    /// Test hooks: the piano alone and the voice alone (each at full weight, whatever the morph); dry (no hall).
    let pianoOnly = Int(ISD_P_DEBUG_SNG_PIANO_ONLY), voiceOnly = Int(ISD_P_DEBUG_SNG_VOICE_ONLY), dry = Int(ISD_P_DEBUG_SNG_DRY)
    let morph = Int(ISD_P_MORPH), breakDial = Int(ISD_P_BREAK), octave = Int(ISD_P_OCTAVE_DOWN)
    let a1: UInt8 = 33, a3: UInt8 = 57

    struct Take {
        var l: [Float], r: [Float]
        /// After each render: the morph the engine is using × 1000, and the repeat detector's flag.
        var morph: [Int], repeating: [Bool]
        let chunk: Int
        var mono: [Float] { zip(l, r).map { $0.0 + $0.1 } }
        /// The flag after the render that holds time `t`.
        func flag(at t: Double, sampleRate: Double = DSPTestKit.sampleRate) -> Bool {
            repeating[min(repeating.count - 1, Int(t * sampleRate) / chunk)]
        }
    }

    /// Renders through the C API in renders of `chunk` samples: MIDI at sample offsets within them, and
    /// isd_synth_set_forced_morph called between renders exactly at its times (a render is split there; the engine takes
    /// it at its next control block, which is that render's start). The read-backs are taken after every render.
    private func play(_ seconds: Double, params: [Int: Float] = [:], events: [R.Event] = [], forced: [(Double, Float)] = [],
                      chunk: Int = 256, sampleRate: Double = DSPTestKit.sampleRate) -> Take {
        guard let s = isd_synth_create(grand, sampleRate, Int32(chunk)) else { return Take(l: [], r: [], morph: [], repeating: [], chunk: chunk) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let calls = forced.map { (at: Int($0.0 * sampleRate), value: $0.1) }.sorted { $0.at < $1.at }
        let sorted = events.sorted { $0.time < $1.time }
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total), right = left
        var morphs: [Int] = [], flags: [Bool] = []
        var e = 0, c = 0, i = 0
        while i < total {
            while c < calls.count, calls[c].at <= i {
                isd_synth_set_forced_morph(s, calls[c].value)
                c += 1
            }
            var n = min(chunk, total - i)
            if c < calls.count { n = min(n, calls[c].at - i) }
            while e < sorted.count, Int(sorted[e].time * sampleRate) < i + n {
                let offset = max(0, Int(sorted[e].time * sampleRate) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(offset)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
            morphs.append(Int(isd_synth_debug_count(s, ISD_DEBUG_MORPH_PERMILLE)))
            flags.append(isd_synth_debug_is_repeating(s) != 0)
        }
        return Take(l: left, r: right, morph: morphs, repeating: flags, chunk: chunk)
    }

    // MARK: - Measurements

    private func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func db(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-300)) }

    /// The power between two frequencies (Blackman–Harris, 2^16 points), so a strong low line doesn't leak up.
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let p = K.powerSpectrum(x, size: 1 << 16), bin = sr / Double(2 * p.count)
        var e = 0.0
        for (i, v) in p.enumerated() where i > 0 {
            let f = Double(i) * bin
            if f >= lo && f <= hi { e += v }
        }
        return e
    }

    /// (l² + r²)/2 in dB over a span.
    private func power(_ o: Take, _ a: Double, _ b: Double) -> Double {
        let i0 = Int(a * sr), i1 = min(o.l.count, Int(b * sr))
        var s = 0.0
        for i in i0..<i1 { s += 0.5 * (Double(o.l[i]) * Double(o.l[i]) + Double(o.r[i]) * Double(o.r[i])) }
        return 10 * log10(s / Double(max(1, i1 - i0)) + 1e-30)
    }

    /// The string's partials: the peaks of the piano-alone power spectrum `p` from `lo` to `hi`, each the strongest bin
    /// within ±0.3·f0 (so a partial's skirt is never taken for another) and no more than 40 dB under the strongest there.
    private func partials(_ p: [Double], f0: Double, from lo: Double, to hi: Double) -> [Int] {
        let bin = sr / Double(2 * p.count)
        var top = 0.0
        for i in 1..<p.count where Double(i) * bin >= lo && Double(i) * bin <= hi { top = max(top, p[i]) }
        let w = max(2, Int(0.3 * f0 / bin))
        var out: [Int] = []
        for i in 1..<(p.count - 1) {
            let f = Double(i) * bin
            guard f >= lo, f <= hi, p[i] >= top * 1e-4 else { continue }
            var best = true
            for k in max(1, i - w)...min(p.count - 1, i + w) where p[k] > p[i] {
                best = false
                break
            }
            if best { out.append(i) }
        }
        return out
    }

    /// The output against the string at each of the string's partials from 100 Hz to 4 kHz over 0.3–1.3 s (dB): the
    /// same strike rendered with the piano alone is the string's own envelope, so this is what the voice did to it.
    private func ratio(_ out: [Float], against piano: [Float], f0: Double) -> [(hz: Double, db: Double)] {
        let po = K.powerSpectrum(R.slice(out, 0.3, 1.3), size: 1 << 16), pp = K.powerSpectrum(R.slice(piano, 0.3, 1.3), size: 1 << 16)
        let bin = sr / Double(2 * pp.count)
        func at(_ p: [Double], _ i: Int) -> Double { (max(1, i - 3)...min(p.count - 1, i + 3)).reduce(0) { $0 + p[$1] } }
        return partials(pp, f0: f0, from: 100, to: 4000).map { (hz: Double($0) * bin, db: db(at(po, $0) / at(pp, $0))) }
    }

    /// The formant's prominence: the ratio's peak among the partials at 350–800 Hz (F1's range, 400 → 700 Hz, and its
    /// skirts) over the ratio's median across all of them.
    private func prominence(_ r: [(hz: Double, db: Double)]) -> Double {
        let peak = r.filter { $0.hz >= 350 && $0.hz <= 800 }.map { $0.db }.max() ?? -999
        let all = r.map { $0.db }.sorted()
        guard !all.isEmpty else { return -999 }
        let median = all.count % 2 == 1 ? all[all.count / 2] : 0.5 * (all[all.count / 2 - 1] + all[all.count / 2])
        return peak - median
    }

    /// F1: the vertex of the parabola in (log2 f, dB) through the strongest partial at 250–1000 Hz and its neighbours.
    private func formant1(_ r: [(hz: Double, db: Double)]) -> Double {
        var best = -1
        for (i, p) in r.enumerated() where p.hz >= 250 && p.hz <= 1000 && (best < 0 || p.db > r[best].db) { best = i }
        guard best > 0, best + 1 < r.count else { return 0 }
        let x0 = log2(r[best - 1].hz), x1 = log2(r[best].hz), x2 = log2(r[best + 1].hz)
        let y0 = r[best - 1].db, y1 = r[best].db, y2 = r[best + 1].db
        let d1 = (y1 - y0) / (x1 - x0), d2 = (y2 - y1) / (x2 - x1), a = (d2 - d1) / (x2 - x0)
        return pow(2, 0.5 * (x0 + x1) - d1 / (2 * a))
    }

    // MARK: - The grand

    /// The piano alone, dry, at Morph 0: A0–C8 within 2 cents (the strongest line within ±60 cents of the note over
    /// 0.3–1.3 s; mirror: worst 0.29 cents, at A7), and fine tune and transpose exact (mirror: 0.05 cents off).
    func testGrandTuning() {
        let p: [Int: Float] = [pianoOnly: 1, dry: 1]
        for m: UInt8 in [21, 33, 45, 57, 69, 81, 93, 105, 108] {
            let out = play(1.4, params: p, events: [R.noteOn(0, m, 100)])
            let ref = hz(Double(m)), f = K.fundamental(R.slice(out.l, 0.3, 1.3), sampleRate: sr, near: ref)
            XCTAssertEqual(K.cents(f, ref), 0, accuracy: 2, "MIDI \(m) measured \(f) Hz")
        }
        var shifted = p
        shifted[Int(ISD_P_FINE_TUNE)] = 37
        shifted[Int(ISD_P_TRANSPOSE)] = 5
        let out = play(1.4, params: shifted, events: [R.noteOn(0, a3, 100)])
        let ref = hz(62), f = K.fundamental(R.slice(out.l, 0.3, 1.3), sampleRate: sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(K.cents(f, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The voice

    /// The voice alone, dry, at Morph 1, A3: its fundamental within 5 cents of the note and of the string's own (the
    /// piano alone; mirror: −0.01 cents), clean or broken, with or without the octave below (the strongest line within
    /// ±60 cents over 0.4–2.4 s; mirror: −0.07, −0.04, −0.02 and +0.06 cents). The formants and the clipper never move it.
    func testVoiceKeepsThePitch() {
        let ref = hz(57)
        let string = K.fundamental(R.slice(play(2.5, params: [pianoOnly: 1, dry: 1], events: [R.noteOn(0, a3, 100)]).l, 0.4, 2.4),
                                   sampleRate: sr, near: ref)
        let settings: [(Float, Float)] = [(0, 0), (0.5, 0.5), (1, 1), (1, 0)]
        for (b, od) in settings {
            let o = play(2.5, params: [voiceOnly: 1, dry: 1, morph: 1, breakDial: b, octave: od], events: [R.noteOn(0, a3, 100)])
            let f = K.fundamental(R.slice(o.l, 0.4, 2.4), sampleRate: sr, near: ref)
            XCTAssertEqual(K.cents(f, ref), 0, accuracy: 5, "Break \(b), Octave Down \(od)")
            XCTAssertEqual(K.cents(f, string), 0, accuracy: 5, "against the string: Break \(b), Octave Down \(od)")
        }
    }

    /// A1 (its partials 55 Hz apart, so they sample the formants finely), dry, Break 0, Octave Down 0: the output against
    /// the string's envelope (the piano alone, the same strike) at each partial. At Morph 0 the formant peak is absent
    /// (its prominence under 3 dB; mirror: 0.00); at Morph 1 it stands at least 12 dB above (mirror: 18.9 dB); at .5 it
    /// is between (mirror: 6.6 dB). And nothing cancels on the way: the formants are in phase with the string, so at .5
    /// no partial falls more than 6 dB under the string's own (half its weight is −6 dB; mirror: the lowest −4.2 dB).
    func testMorphCrossfades() {
        var prominences: [Double] = []
        for m: Float in [0, 0.5, 1] {
            let p: [Int: Float] = [dry: 1, morph: m, breakDial: 0, octave: 0]
            var piano = p
            piano[pianoOnly] = 1
            let out = play(1.4, params: p, events: [R.noteOn(0, a1, 100)]), string = play(1.4, params: piano, events: [R.noteOn(0, a1, 100)])
            let r = ratio(out.l, against: string.l, f0: hz(33))
            XCTAssertGreaterThanOrEqual(r.count, 25, "A1's partials, 100 Hz–4 kHz")
            prominences.append(prominence(r))
            if m == 0.5 { XCTAssertGreaterThanOrEqual(r.map { $0.db }.min() ?? -999, -6, "nothing cancels at .5: \(r.map { $0.db })") }
        }
        XCTAssertLessThan(prominences[0], 3, "Morph 0")
        XCTAssertGreaterThanOrEqual(prominences[2], 12, "Morph 1")
        XCTAssertGreaterThan(prominences[1], prominences[0], "Morph .5 above Morph 0")
        XCTAssertLessThan(prominences[1], prominences[2], "Morph .5 under Morph 1")
    }

    /// The voice alone against the string (A1, dry, Break 0, Octave Down 0): F1, the parabola's vertex through its
    /// strongest partial at 250–1000 Hz and the two beside it, at 400 ± 40 Hz at Morph .1 (mirror: 415 Hz) and 700 ± 60
    /// at Morph 1 (mirror: 698 Hz): an "ah" opening to an "aw".
    func testFormantsOpenWithMorph() {
        let bounds: [(Float, Double, Double)] = [(0.1, 400, 40), (1, 700, 60)]
        for (m, f1, tolerance) in bounds {
            let p: [Int: Float] = [dry: 1, morph: m, breakDial: 0, octave: 0]
            var v = p, s = p
            v[voiceOnly] = 1
            s[pianoOnly] = 1
            let voice = play(1.4, params: v, events: [R.noteOn(0, a1, 100)]), string = play(1.4, params: s, events: [R.noteOn(0, a1, 100)])
            XCTAssertEqual(formant1(ratio(voice.l, against: string.l, f0: hz(33))), f1, accuracy: tolerance, "Morph \(m)")
        }
    }

    /// C5 at Morph 1, dry, Octave Down 0: Break 1 against Break 0. C5's 3rd harmonic (1.57 kHz) falls between the
    /// formants, where the clean voice leaves it 28 dB under the fundamental; the broken one gives it back. It rises at
    /// least 10 dB (mirror: +18.7 dB) and at least 10 dB against the fundamental too (mirror: −28.0 → −12.2 dB, near a
    /// square's −9.5), while the level moves less than 4.5 dB (mirror: +3.5 dB). (On a note with a harmonic on a formant,
    /// A3's 3rd or A4's 4th, the clean voice already leads with it, and a clipper can't lift a harmonic past a square's.)
    func testBreakAddsOddHarmonics() {
        let f = hz(72)
        var third: [Double] = [], first: [Double] = [], level: [Double] = []
        for b: Float in [0, 1] {
            let o = play(2, params: [dry: 1, morph: 1, breakDial: b, octave: 0], events: [R.noteOn(0, 72, 100)])
            let x = R.slice(o.mono, 0.8, 1.8)
            third.append(band(x, 3 * f * 0.98, 3 * f * 1.02))
            first.append(band(x, f * 0.98, f * 1.02))
            level.append(power(o, 0.8, 1.8))
        }
        XCTAssertGreaterThanOrEqual(db(third[1] / third[0]), 10, "the 3rd harmonic")
        XCTAssertGreaterThanOrEqual(db(third[1] / first[1]) - db(third[0] / first[0]), 10, "the 3rd harmonic against the fundamental")
        XCTAssertEqual(level[1], level[0], accuracy: 4.5, "Break changes the tone, not the loudness")
    }

    /// A3 at Morph 1, dry, Break 0: Octave Down 1 adds a line at f0/2 within 3 dB of f0 (mirror: +1.4 dB); at 0 there is
    /// none (mirror: −92 dB). (Octave Down .5: −5.5 dB.)
    func testOctaveDown() {
        let f = hz(57)
        for od: Float in [0, 1] {
            let o = play(2, params: [dry: 1, morph: 1, breakDial: 0, octave: od], events: [R.noteOn(0, a3, 100)])
            let x = R.slice(o.mono, 0.5, 1.5)
            let below = db(band(x, f / 2 * 0.98, f / 2 * 1.02) / band(x, f * 0.98, f * 1.02))
            if od == 1 { XCTAssertEqual(below, 0, accuracy: 3, "Octave Down 1") } else { XCTAssertLessThanOrEqual(below, -30, "Octave Down 0") }
        }
    }

    // MARK: - The morph

    /// Channel pressure 0 → 1 at 1 s and 1 → 0 at 3 s, A3 held, read back every millisecond: the morph reaches .63 at
    /// 80 ± 10 ms (mirror: 80 ms) and falls to .37 at 250 ± 25 ms (mirror: 249 ms).
    func testPressureMorphsSmoothly() {
        let o = play(5, params: [dry: 1], events: [R.noteOn(0, a3, 100), R.Event(time: 1, bytes: [0xD0, 127]), R.Event(time: 3, bytes: [0xD0, 0])],
                     chunk: 48)
        func crossing(after t: Double, _ level: Int, rising: Bool) -> Double {
            for i in Int(t * 1000)..<o.morph.count where (rising ? o.morph[i] >= level : o.morph[i] <= level) { return Double(i + 1) / 1000 - t }
            return -1
        }
        XCTAssertEqual(o.morph[999], 0)
        XCTAssertEqual(crossing(after: 1, 630, rising: true), 0.080, accuracy: 0.010, "up")
        XCTAssertEqual(o.morph[2999], 1000)
        XCTAssertEqual(crossing(after: 3, 370, rising: false), 0.250, accuracy: 0.025, "down")
    }

    /// Review focus 3. A3 held with channel pressure 25/127 (≈ .2); the world forces .8 at 1 s and releases it at 3.5 s.
    /// Forced, the morph sits at .8 (800 ± 1 from 1.7 s; mirror: 800). Released, it returns to the player's pressure
    /// over 250 ± 25 ms (63% of the way back, the same law as letting go of the key; mirror: 251 ms) with no step larger
    /// than .05 per ms anywhere (mirror: .008), and settles there (mirror: 197). And with full pressure under it the world
    /// still wins (800), and the release rises to the player's 1 without a step (mirror: the largest .013 per ms).
    func testForcedMorphOverridesThenReleases() {
        let target = 25.0 / 127
        let o = play(6, params: [dry: 1], events: [R.noteOn(0, a3, 100), R.Event(time: 0, bytes: [0xD0, 25])],
                     forced: [(1, 0.8), (3.5, -1)], chunk: 48)
        XCTAssertEqual(Double(o.morph[999]), 1000 * target, accuracy: 2, "the player's pressure before")
        let held: ArraySlice<Int> = o.morph[1700..<3500]
        let heldMin: Int = held.min() ?? 0
        let heldMax: Int = held.max() ?? 9999
        XCTAssertGreaterThanOrEqual(heldMin, 799, "forced from 1.7 s")
        XCTAssertLessThanOrEqual(heldMax, 801, "forced from 1.7 s")
        let level: Double = 1000 * (target + (0.8 - target) / M_E)
        var backIndex: Int = -1
        for i in 3500..<o.morph.count where Double(o.morph[i]) <= level { backIndex = i; break }
        let back: Double = backIndex < 0 ? -1 : Double(backIndex + 1) / 1000 - 3.5
        XCTAssertEqual(back, 0.25, accuracy: 0.025, "back to the player over 250 ms")
        XCTAssertLessThanOrEqual(largestStep(o.morph), 50, "no step above .05 per ms")
        XCTAssertEqual(Double(o.morph[o.morph.count - 1]), 1000 * target, accuracy: 3, "settled on the player's pressure")
        let full = play(4.5, params: [dry: 1], events: [R.noteOn(0, a3, 100), R.Event(time: 0, bytes: [0xD0, 127])],
                        forced: [(0.5, 0.8), (3, -1)], chunk: 48)
        let over = full.morph[2000..<3000]
        let overMin: Int = over.min() ?? 0
        let overMax: Int = over.max() ?? 9999
        XCTAssertGreaterThanOrEqual(overMin, 799, "forced over full pressure")
        XCTAssertLessThanOrEqual(overMax, 801, "forced over full pressure")
        XCTAssertLessThanOrEqual(largestStep(full.morph), 50, "no step, up or down")
        XCTAssertEqual(full.morph[full.morph.count - 1], 1000, "back to full pressure")
    }

    /// The largest change between neighbouring samples of a read-back, in permille.
    private func largestStep(_ values: [Int]) -> Int {
        var largest = 0
        var i = 1
        while i < values.count { largest = max(largest, abs(values[i] - values[i - 1])); i += 1 }
        return largest
    }

    // MARK: - Repeats

    /// Strikes of A3 (each let go after 150 ms), the flag read after the render holding each moment. Four at 2.5 a second:
    /// false after the third, true after the fourth. Three strikes, or four at 1.5 a second: false. A different key
    /// resets it. It holds while the strikes go on and lets go 0.5 s after the last; exactly 2 a second counts.
    func testRepeatDetection() {
        func strikes(_ times: [Double], tail: Double = 0.3, extra: [R.Event] = []) -> Take {
            var events = extra
            for t in times { events += [R.noteOn(t, a3, 90), R.noteOff(t + 0.15, a3)] }
            return play(times[times.count - 1] + tail, params: [dry: 1], events: events)
        }
        let four = strikes([0, 0.4, 0.8, 1.2])
        XCTAssertFalse(four.flag(at: 0.801), "after the third")
        XCTAssertTrue(four.flag(at: 1.201), "after the fourth")
        let three = strikes([0, 0.4, 0.8])
        XCTAssertFalse(three.flag(at: 0.801) || three.flag(at: 1.0), "three strikes")
        let slow = strikes([0, 2.0 / 3, 4.0 / 3, 2])
        XCTAssertFalse(slow.flag(at: 2.001), "four at 1.5 a second")
        let other = strikes([0, 0.4, 0.8, 1.2], extra: [R.noteOn(1.4, 60, 90)])
        XCTAssertTrue(other.flag(at: 1.3))
        XCTAssertFalse(other.flag(at: 1.401), "a different key resets it")
        let run = strikes([0, 0.4, 0.8, 1.2, 1.6, 2], tail: 1)
        XCTAssertTrue(run.flag(at: 2.4), "it holds while the strikes go on")
        XCTAssertFalse(run.flag(at: 2.6), "and lets go 0.5 s after the last")
        XCTAssertTrue(strikes([0, 0.5, 1, 1.5]).flag(at: 1.501), "exactly 2 a second")
    }

    // MARK: - Hygiene

    /// Every dial and mood at each end (fine tune and transpose too), the pedal, full channel pressure and then none, a
    /// key's poly pressure, the forced morph at 1, 0, released, .8 and released, twelve fortissimo notes from A0 up, a
    /// hard six-note chord and a repeated C4, at 22.05, 44.1, 48, 96 and 192 kHz: only finite samples within ±1 (mirror:
    /// all finite, peaks at the limiter's 0.9).
    func testSingleNoteGrandRendersFinite() {
        let dials = [ISD_P_HALL_SNG, ISD_P_FELT_SNG, ISD_P_MORPH, ISD_P_OCTAVE_DOWN, ISD_P_BREAK, ISD_P_WIDTH, ISD_P_SPACE, ISD_P_MOOD_ENERGY,
                     ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION].map { Int($0) }
        for rate in [22_050.0, 44_100, 48_000, 96_000, 192_000] {
            for v: Float in [0, 1] {
                var p = Dictionary(uniqueKeysWithValues: dials.map { ($0, v) })
                p[Int(ISD_P_FINE_TUNE)] = v > 0 ? 50 : -50
                p[Int(ISD_P_TRANSPOSE)] = v > 0 ? 12 : -12
                var events: [R.Event] = [R.pedal(0.05, 127), R.Event(time: 0.2, bytes: [0xD0, 127]), R.Event(time: 1, bytes: [0xD0, 0]),
                                         R.Event(time: 1.4, bytes: [0xA0, 60, 127])]
                for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.03, UInt8(21 + i * 9), 127)) }
                for i in 0..<6 { events.append(R.noteOn(1.8 + Double(i) * 0.01, UInt8(24 + i * 12), 127)) }
                for i in 0..<5 { events.append(R.noteOn(2.2 + Double(i) * 0.12, 60, 127)) }
                let o = play(3, params: p, events: events, forced: [(0.5, 1), (1.2, 0), (1.6, -1), (2, 0.8), (2.5, -1)], sampleRate: rate)
                XCTAssertEqual(o.l.count, Int(3 * rate))
                XCTAssertTrue(o.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && o.r.allSatisfy { $0.isFinite && abs($0) <= 1 },
                              "\(rate) Hz, dials at \(v)")
            }
        }
    }
}
