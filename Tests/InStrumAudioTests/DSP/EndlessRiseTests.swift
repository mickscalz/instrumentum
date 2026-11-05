import XCTest
import InStrumDSP

/// Endless Rise (Storms, Task 2; spec 2026-11-05-storms-design.md §4.1, brief endless-rise.md): a pressure pad with a
/// Shepard–Risset riser that climbs while you hold it and never arrives, until the drop resolves it. Every bound below
/// was measured first with a C++ mirror of these renders and measurements (the values are in the doc comments and in
/// the commit that brought the engine in).
final class EndlessRiseTests: XCTestCase {
    typealias R = SynthRender
    typealias K = DSPTestKit
    let rise = ISD_ENGINE_ENDLESS_RISE
    let sr = DSPTestKit.sampleRate
    /// Test hooks, which combine: the pad alone (no riser or thump); the riser alone (with the drop's thump); dry (no
    /// pulse, drive, reverb or slop).
    let padOnly = Int(ISD_P_DEBUG_ER_PAD_ONLY), riseOnly = Int(ISD_P_DEBUG_ER_RISE_ONLY), dry = Int(ISD_P_DEBUG_ER_DRY)
    /// The riser alone, dry.
    var riser: [Int: Float] { [riseOnly: 1, dry: 1] }
    let a3: UInt8 = 57

    struct Take {
        var l: [Float], r: [Float]
        /// Drops taken, and the tension the engine was using × 1000, at the end.
        var drops: Int, tension: Int
        var mono: [Float] { zip(l, r).map { $0.0 + $0.1 } }
    }

    /// Renders through the C API: MIDI at sample offsets within 256-sample renders, and isd_synth_set_tension /
    /// isd_synth_trigger_drop called between renders exactly at their times (a render is split there; the engine takes
    /// them at its next control block, which is that render's start).
    private func play(_ seconds: Double, params: [Int: Float] = [:], events: [R.Event] = [], tension: [(Double, Float)] = [],
                      drops: [Double] = [], sampleRate: Double = DSPTestKit.sampleRate) -> Take {
        guard let s = isd_synth_create(rise, sampleRate, 256) else { return Take(l: [], r: [], drops: -1, tension: -1) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        var calls: [(at: Int, value: Float?)] = []
        for (t, v) in tension { calls.append((at: Int(t * sampleRate), value: v)) }
        for t in drops { calls.append((at: Int(t * sampleRate), value: nil)) }
        calls.sort { $0.at < $1.at }
        let sorted = events.sorted { $0.time < $1.time }
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total), right = left
        var e = 0, c = 0, i = 0
        while i < total {
            while c < calls.count, calls[c].at <= i {
                if let v = calls[c].value { isd_synth_set_tension(s, v) } else { isd_synth_trigger_drop(s) }
                c += 1
            }
            var n = min(256, total - i)
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
        }
        return Take(l: left, r: right, drops: Int(isd_synth_debug_count(s, ISD_DEBUG_DROPS)),
                    tension: Int(isd_synth_debug_count(s, ISD_DEBUG_TENSION_PERMILLE)))
    }

    // MARK: - Measurements

    private func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func db(_ ratio: Double) -> Double { 10 * log10(max(ratio, 1e-300)) }

    /// The power between two frequencies (Blackman–Harris, zero-padded to `size`), so a strong low line doesn't leak up.
    private func band(_ x: [Float], _ lo: Double, _ hi: Double, size: Int = 1 << 16) -> Double {
        let p = K.powerSpectrum(x, size: size), bin = sr / Double(2 * p.count)
        var e = 0.0
        for (i, v) in p.enumerated() where i > 0 {
            let f = Double(i) * bin
            if f >= lo && f <= hi { e += v }
        }
        return e
    }

    /// The linear spectral centroid (Hz), Blackman–Harris, 2^14 points.
    private func centroid(_ x: [Float]) -> Double {
        let p = K.powerSpectrum(x, size: 1 << 14), bin = sr / Double(2 * p.count)
        var num = 0.0, den = 0.0
        for (i, v) in p.enumerated() where i > 0 { num += Double(i) * bin * v; den += v }
        return den > 0 ? num / den : 0
    }

    /// The riser's pitch class: the power-weighted circular mean of log2(f / 440 Hz), mod 1, over 100 Hz–8 kHz
    /// (Blackman–Harris, 2^14 points). A stack's octaves share one pitch class and its harmonics keep a fixed share, so
    /// this is the spectral centroid on the pitch-class circle, and it climbs exactly with the riser.
    private func chroma(_ x: [Float]) -> Double {
        let p = K.powerSpectrum(x, size: 1 << 14), bin = sr / Double(2 * p.count)
        var re = 0.0, im = 0.0
        for (i, v) in p.enumerated() where i > 0 {
            let f = Double(i) * bin
            guard f >= 100, f <= 8000 else { continue }
            let a = 2 * Double.pi * log2(f / 440)
            re += v * cos(a)
            im += v * sin(a)
        }
        let c = atan2(im, re) / (2 * Double.pi)
        return c - floor(c)
    }

    /// The pitch class of 0.25 s slices every 0.125 s from `a` to `b`: the slices' centres and the values.
    private func chromaTrack(_ x: [Float], from a: Double, to b: Double) -> (t: [Double], c: [Double]) {
        var t: [Double] = [], c: [Double] = []
        var s = a
        while s + 0.25 <= b + 1e-9 {
            t.append(s + 0.125)
            c.append(chroma(R.slice(x, s, s + 0.25)))
            s += 0.125
        }
        return (t, c)
    }

    /// The climb in octaves a second: the pitch class unwrapped and fitted with a line.
    private func climbRate(_ track: (t: [Double], c: [Double])) -> Double {
        var u: [Double] = [], offset = 0.0
        for (i, c) in track.c.enumerated() {
            if i > 0 {
                let d = c - track.c[i - 1]
                if d < -0.5 { offset += 1 } else if d > 0.5 { offset -= 1 }
            }
            u.append(c + offset)
        }
        let n = Double(u.count)
        let mt = track.t.reduce(0, +) / n, mu = u.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<u.count {
            num += (track.t[i] - mt) * (u[i] - mu)
            den += (track.t[i] - mt) * (track.t[i] - mt)
        }
        return num / den
    }

    /// (l² + r²)/2 in dB over a span.
    private func power(_ o: Take, _ a: Double, _ b: Double) -> Double {
        let i0 = Int(a * sr), i1 = min(o.l.count, Int(b * sr))
        var s = 0.0
        for i in i0..<i1 { s += 0.5 * (Double(o.l[i]) * Double(o.l[i]) + Double(o.r[i]) * Double(o.r[i])) }
        return 10 * log10(s / Double(max(1, i1 - i0)) + 1e-30)
    }

    /// The envelope of a 48 Hz sinusoid: √(x² + (x′/ω)²), x′ by central difference.
    private func envelope48(_ x: [Float]) -> [Double] {
        let w = 2 * Double.pi * 48
        var e = [Double](repeating: 0, count: x.count)
        guard x.count > 2 else { return e }
        for i in 1..<(x.count - 1) {
            let d = Double(x[i + 1] - x[i - 1]) * sr / 2 / w
            e[i] = (Double(x[i]) * Double(x[i]) + d * d).squareRoot()
        }
        return e
    }

    // MARK: - Tuning

    /// The pad alone (no riser or thump): the detuned pair's power-weighted centre over 3.5 s (longer than A2's pair
    /// takes to beat once) within 2 cents dry, A2–A5, and within 6 with slop (each oscillator wanders up to ±3 cents).
    /// Fine tune and transpose are exact. (Mirror: worst 0.39 cents dry, 0.89 with slop; fine tune and transpose 0.05.)
    func testEndlessRiseTuning() {
        let pad: [Int: Float] = [padOnly: 1, dry: 1]
        let slop: [Int: Float] = [padOnly: 1, Int(ISD_P_SPACE): 0, Int(ISD_P_PULSE): 0, Int(ISD_P_GRIT_ER): 0]
        for m: UInt8 in [45, 57, 69, 81] {
            let ref = hz(Double(m))
            for (params, bound) in [(pad, 2.0), (slop, 6.0)] {
                let out = play(4, params: params, events: [R.noteOn(0, m, 100)])
                let centre = K.clusterCentre(R.slice(out.l, 0.4, 3.9), sampleRate: sr, near: ref)
                XCTAssertEqual(K.cents(centre, ref), 0, accuracy: bound, "MIDI \(m), within \(bound) cents")
            }
        }
        var p = pad
        p[Int(ISD_P_FINE_TUNE)] = 37
        p[Int(ISD_P_TRANSPOSE)] = 5
        let out = play(4, params: p, events: [R.noteOn(0, 57, 100)])
        let ref = hz(62)
        let centre = K.clusterCentre(R.slice(out.l, 0.4, 3.9), sampleRate: sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(K.cents(centre, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The riser

    /// The riser alone, dry, Rise .08, A3 held 30 s. Its pitch class climbs at 0.08 octaves a second: a period of
    /// 12.5 ± 0.5 s (mirror: 12.500 s). It never rises for longer than one period before it wraps (mirror: 12.4 s), so
    /// it is never monotone beyond one period; it never arrives (the linear centroid's mean over each period within 5%;
    /// mirror: 1458 Hz both times, 1458–1460 Hz throughout); and the octave bands at 1 s and 13.5 s match within 1 dB
    /// (mirror: 0.000 dB).
    func testRiserClimbsAndNeverArrives() {
        var p = riser
        p[Int(ISD_P_RISE)] = 0.08
        let x = play(30, params: p, events: [R.noteOn(0, a3, 100)]).mono
        let track = chromaTrack(x, from: 1, to: 29)
        XCTAssertEqual(1 / climbRate(track), 12.5, accuracy: 0.5, "the climb's period")
        var longest = 0.0, start = track.t[0]
        for i in 1..<track.c.count where track.c[i] < track.c[i - 1] {
            longest = max(longest, track.t[i - 1] - start)
            start = track.t[i]
        }
        longest = max(longest, track.t[track.t.count - 1] - start)
        XCTAssertLessThanOrEqual(longest, 13, "never monotone beyond one period")
        func meanCentroid(_ a: Double, _ b: Double) -> Double {
            var sum = 0.0, n = 0, t = a
            while t < b {
                sum += centroid(R.slice(x, t, t + 0.25))
                n += 1
                t += 0.25
            }
            return sum / Double(n)
        }
        let first = meanCentroid(1, 13.5), second = meanCentroid(13.5, 26)
        XCTAssertLessThan(abs(second / first - 1), 0.05, "it never arrives: \(first) Hz, then \(second) Hz")
        var f = 62.5
        while f < 10_000 {
            let early = band(R.slice(x, 1, 1.5), f, 2 * f), late = band(R.slice(x, 13.5, 14), f, 2 * f)
            XCTAssertEqual(db(late / early), 0, accuracy: 1, "\(f)–\(2 * f) Hz")
            f *= 2
        }
    }

    /// Review focus 1, the seam. The riser alone, dry, A3 held 30 s at Rise .08: the power of every 1 s window (every
    /// 50 ms) within ±0.5 dB of the mean over 1–30 s (mirror: ±0.005 dB). The window spans exactly eight octaves from
    /// 43.30 Hz, so A3's stack wraps (its bottom voice reaching twice that) after climbing 1 − frac(log2(220 / 43.30))
    /// octaves, at 8.19 s, and every 12.5 s from there. At each wrap: no sample-to-sample step above 0.05 within 10 ms
    /// (mirror: 0.040, the saws' own edges, as anywhere else), and nothing above 10 kHz more than 3 dB over the second
    /// around it (mirror: within 0.4 dB).
    func testRiserLoudnessIsConstant() {
        var p = riser
        p[Int(ISD_P_RISE)] = 0.08
        let o = play(30, params: p, events: [R.noteOn(0, a3, 100)])
        let sr = self.sr
        var sum = [Double](repeating: 0, count: o.l.count + 1)
        for i in 0..<o.l.count { sum[i + 1] = sum[i] + 0.5 * (Double(o.l[i]) * Double(o.l[i]) + Double(o.r[i]) * Double(o.r[i])) }
        func level(_ a: Double, _ b: Double) -> Double {
            let i0 = Int(a * sr), i1 = Int(b * sr)
            return 10 * log10((sum[i1] - sum[i0]) / Double(i1 - i0) + 1e-30)
        }
        let mean = level(1, 30)
        var t = 1.0
        while t + 1 <= 30 {
            XCTAssertEqual(level(t, t + 1), mean, accuracy: 0.5, "the second from \(t) s")
            t += 0.05
        }
        let c = log2(220 / 43.301270189221932)
        var w = (1 - (c - floor(c))) / 0.08
        while w < 29.5 {
            let i = Int(w * sr)
            var step: Float = 0
            for k in (i - 480)..<(i + 480) { step = max(step, abs(o.l[k] - o.l[k - 1]), abs(o.r[k] - o.r[k - 1])) }
            XCTAssertLessThanOrEqual(step, 0.05, "the largest step within 10 ms of the wrap at \(w) s")
            let click = K.loudestHigh(o.l, o.r, from: w - 0.003, to: w + 0.003)
            var around = 0.0, n = 0, u = w - 0.5
            while u < w + 0.5 {
                if abs(u - w) >= 0.01 {
                    around += K.loudestHigh(o.l, o.r, from: u, to: u + 0.006)
                    n += 1
                }
                u += 0.05
            }
            XCTAssertLessThanOrEqual(click - around / Double(n), 3, "no click at the wrap at \(w) s")
            w += 12.5
        }
    }

    /// isd_synth_set_tension(1): the climb runs ×4, a period of 3.1 ± 0.3 s (mirror: 3.125 s), and the instrument's
    /// 2–6 kHz energy (dry) rises by at least 6 dB (mirror: +8.7 dB; the pad alone +52 dB as its filter opens from
    /// 600 Hz to 6 kHz, the riser +2.9 dB and leaning brighter).
    func testTensionSpeedsTheRise() {
        let fast = play(14, params: riser, events: [R.noteOn(0, a3, 100)], tension: [(0, 1)]).mono
        XCTAssertEqual(1 / climbRate(chromaTrack(fast, from: 1, to: 13)), 3.1, accuracy: 0.3, "the climb's period at tension 1")
        let d: [Int: Float] = [dry: 1]
        let open = play(3, params: d, events: [R.noteOn(0, a3, 100)], tension: [(0, 1)]).mono
        let shut = play(3, params: d, events: [R.noteOn(0, a3, 100)]).mono
        XCTAssertGreaterThanOrEqual(db(band(R.slice(open, 1, 2.5), 2000, 6000) / band(R.slice(shut, 1, 2.5), 2000, 6000)), 6)
    }

    // MARK: - The drop

    /// Tension .8, A3 held, and the drop at 4 s.
    /// - The riser alone, dry: its energy above the fundamental octave (440 Hz up) over 120–170 ms after the drop at least
    ///   20 dB below the 50 ms before it (mirror: −108.5 dB: it has collapsed into A3 itself).
    /// - The thump (the riser at Sub .7 less the same at Sub 0): its 48 Hz envelope reaches half its peak within 10 ms
    ///   (mirror: at once, a sine from phase 0) and falls 60 dB from its peak in 400 ± 50 ms (mirror: 398.4 ms).
    /// - The riser is gone by 2.5 s (40 dB below the 0.4 s before the drop; mirror: silent), and one drop is taken.
    /// - The pad alone, dry, continues: within 3 dB of the 1.5 s before the drop over 2.5–4 s after it, and over its
    ///   first 0.5 s, when the filter snaps open (mirror: −0.5 and 0.0 dB).
    func testDropResolves() {
        let td = 4.0, sub = Int(ISD_P_SUB)
        var thumping = riser
        thumping[sub] = 0.7
        var quiet = riser
        quiet[sub] = 0
        let a = play(7, params: thumping, events: [R.noteOn(0, a3, 100)], tension: [(0, 0.8)], drops: [td])
        let b = play(7, params: quiet, events: [R.noteOn(0, a3, 100)], tension: [(0, 0.8)], drops: [td])
        let x = b.mono
        let before = band(R.slice(x, td - 0.05, td), 440, 20_000), after = band(R.slice(x, td + 0.12, td + 0.17), 440, 20_000)
        XCTAssertLessThanOrEqual(db(after / before), -20, "the riser above the fundamental octave, within 120 ms")
        let env = envelope48(zip(a.mono, x).map { $0.0 - $0.1 })
        let i0 = Int(td * sr)
        var peak = 0.0, at = i0
        for i in i0..<(i0 + Int(0.1 * sr)) where env[i] > peak {
            peak = env[i]
            at = i
        }
        XCTAssertGreaterThan(peak, 0.01, "a thump")
        let half = (i0..<(i0 + Int(0.05 * sr))).first { env[$0] >= 0.5 * peak } ?? i0 + Int(sr)
        XCTAssertLessThanOrEqual(Double(half - i0) / sr, 0.010, "the 48 Hz thump appears within 10 ms")
        let down = (at..<env.count).first { env[$0] < 1e-3 * peak } ?? env.count
        XCTAssertEqual(Double(down - at) / sr, 0.4, accuracy: 0.05, "the thump falls 60 dB in 400 ms")
        XCTAssertLessThanOrEqual(power(b, td + 2.5, td + 2.9) - power(b, td - 0.4, td), -40, "the riser is gone by 2.5 s")
        XCTAssertEqual(a.drops, 1)
        let pad = play(8.5, params: [padOnly: 1, dry: 1], events: [R.noteOn(0, a3, 100)], tension: [(0, 0.8)], drops: [td])
        let held = power(pad, td - 1.5, td)
        XCTAssertGreaterThanOrEqual(power(pad, td + 2.5, td + 4) - held, -3, "the pad continues")
        XCTAssertGreaterThanOrEqual(power(pad, td, td + 0.5) - held, -3, "the pad stands through the drop")
    }

    /// Review focus 2. Drops at 4 s, 4.5 s and 6.7 s (tension .8, A3 held, the riser alone, dry). The one at 4.5 s does
    /// nothing: no second thump (the 48 Hz envelope over 0.5–0.9 s after the first below −30 dB of the first's peak;
    /// mirror: −75 dB) and no second collapse (the riser above 440 Hz stays 40 dB down; mirror: −113 dB). The one at
    /// 6.7 s, past the first's 2.5 s and its release envelope, is taken (two drops in all) and thumps.
    func testSecondDropIsIgnored() {
        let td = 4.0, drops = [td, td + 0.5, td + 2.7], sub = Int(ISD_P_SUB)
        var thumping = riser
        thumping[sub] = 0.7
        var quiet = riser
        quiet[sub] = 0
        let a = play(8, params: thumping, events: [R.noteOn(0, a3, 100)], tension: [(0, 0.8)], drops: drops)
        let b = play(8, params: quiet, events: [R.noteOn(0, a3, 100)], tension: [(0, 0.8)], drops: drops)
        let env = envelope48(zip(a.mono, b.mono).map { $0.0 - $0.1 })
        let sr = self.sr, i0 = Int(td * sr)
        func loudest(_ from: Double, _ to: Double) -> Double { env[(i0 + Int(from * sr))..<(i0 + Int(to * sr))].max() ?? 0 }
        let first = loudest(0, 0.1)
        XCTAssertGreaterThan(first, 0.01, "the first thump")
        XCTAssertLessThan(20 * log10(loudest(0.5, 0.9) / first + 1e-30), -30, "no second thump")
        XCTAssertEqual(a.drops, 2, "the second drop is ignored; the third, 2.7 s after the first, is taken")
        XCTAssertGreaterThan(20 * log10(loudest(2.7, 2.8) / first + 1e-30), -3, "the third thumps")
        let x = b.mono
        XCTAssertLessThanOrEqual(db(band(R.slice(x, td + 0.55, td + 0.75), 440, 20_000) / band(R.slice(x, td - 0.05, td), 440, 20_000)), -40,
                                 "the collapse isn't restarted")
    }

    // MARK: - The pad

    /// Pulse .5 at 124 BPM (the pad alone, no reverb or Grit, A3). Against the same note at Pulse 0 (the engine is seeded,
    /// so the oscillators match to the sample) the ratio of 2 ms windows every 0.25 ms is the pulse's own gain: it dips
    /// (3 dB or more, the lowest within ±100 ms) every 483.9 ± 2 ms from 1 s on (mirror: 12 dips, every 483.864 ms,
    /// the worst 0.37 ms off, 5.1 dB deep, 12 ms after each beat).
    func testPulseLocksToTempo() {
        let base: [Int: Float] = [padOnly: 1, Int(ISD_P_SPACE): 0, Int(ISD_P_GRIT_ER): 0, Int(ISD_P_TEMPO_ER): 124]
        var pulsed = base
        pulsed[Int(ISD_P_PULSE)] = 0.5
        var still = base
        still[Int(ISD_P_PULSE)] = 0
        let x = play(7, params: pulsed, events: [R.noteOn(0, a3, 100)]).mono
        let y = play(7, params: still, events: [R.noteOn(0, a3, 100)]).mono
        var cx = [Double](repeating: 0, count: x.count + 1), cy = cx
        for i in 0..<x.count {
            cx[i + 1] = cx[i] + Double(x[i]) * Double(x[i])
            cy[i + 1] = cy[i] + Double(y[i]) * Double(y[i])
        }
        var g: [Double] = []
        var i = 0
        while i + 96 <= x.count {
            g.append(10 * log10((cx[i + 96] - cx[i] + 1e-30) / (cy[i + 96] - cy[i] + 1e-30)))
            i += 12
        }
        var dips: [Double] = []
        for j in 4000..<(g.count - 400) where g[j] <= -3 {
            if g[(j - 400)...(j + 400)].contains(where: { $0 < g[j] }) { continue }
            let t = Double(j) * 0.00025
            if dips.isEmpty || t - dips[dips.count - 1] > 0.2 { dips.append(t) }
        }
        XCTAssertGreaterThanOrEqual(dips.count, 10, "dips at \(dips)")
        for k in 1..<max(1, dips.count) {
            XCTAssertEqual(dips[k] - dips[k - 1], 60.0 / 124, accuracy: 0.002, "dip \(k) at \(dips[k]) s")
        }
    }

    /// The riser runs only while a key or the pedal holds it (alone, dry, A3). Keys up, no pedal: silent from 250 ms on
    /// (mirror: −114 dBFS; it goes in 200 ms). Pedal down and the key up: it carries on (within 1.5 dB; mirror: +0.00 dB),
    /// and goes when the pedal lifts. The pedal alone, with no key, is silent.
    func testHoldRule() {
        let keys = play(3, params: riser, events: [R.noteOn(0, a3, 100), R.noteOff(2, a3)]).mono
        XCTAssertGreaterThan(K.dBFS(R.slice(keys, 1, 2)), -40, "it sounds while held")
        XCTAssertLessThan(K.dBFS(R.slice(keys, 2.25, 3)), -60, "silent once let go")
        let pedal = play(5.5, params: riser, events: [R.pedal(0, 127), R.noteOn(0.1, a3, 100), R.noteOff(2, a3), R.pedal(4, 0)])
        XCTAssertEqual(power(pedal, 2.5, 4), power(pedal, 1, 2), accuracy: 1.5, "the pedal holds it")
        XCTAssertLessThan(power(pedal, 4.25, 5.5), -60, "the pedal lifts: gone")
        let none = play(1, params: riser, events: [R.pedal(0, 127)])
        XCTAssertLessThan(K.dBFS(none.l), -100, "the pedal alone")
    }

    /// Grit 1 against 0 (the pad alone, no reverb or pulse): A4's 3rd harmonic (1.32 kHz, above the pad's filter at
    /// tension 0) at least 10 dB louder (mirror: +25.9 dB, the level within 1 dB). Grit drives the ladder's input and, as
    /// a hard-driven analogue ladder does, its output stage: a drive before a linear filter alone can't add harmonics
    /// above the cutoff (measured: A2's 3rd harmonic, inside the passband, moved less than 1 dB that way).
    func testGritAddsHarmonics() {
        let f = hz(69)
        func third(_ grit: Float) -> Double {
            let params: [Int: Float] = [padOnly: 1, Int(ISD_P_SPACE): 0, Int(ISD_P_PULSE): 0, Int(ISD_P_GRIT_ER): grit]
            let o = play(2, params: params, events: [R.noteOn(0, 69, 100)])
            return band(R.slice(o.mono, 0.8, 1.8), 3 * f * 0.98, 3 * f * 1.02)
        }
        XCTAssertGreaterThanOrEqual(db(third(1) / third(0)), 10)
    }

    /// The wheel full up: the pad's centre reads +200 cents (within 5; mirror: +200.33), and the riser's pitch class
    /// moves 2/12 of an octave with it (mirror: 0.1668).
    func testWheelBendsTwoSemitones() {
        let up: [UInt8] = [0xE0, 0x7F, 0x7F]
        let out = play(2.5, params: [padOnly: 1, dry: 1], events: [R.noteOn(0, a3, 100), R.Event(time: 0.5, bytes: up)])
        let centre = K.clusterCentre(R.slice(out.l, 0.6, 2.4), sampleRate: sr, near: hz(59))
        XCTAssertEqual(K.cents(centre, hz(57)), 200, accuracy: 5)
        let bent = play(2.5, params: riser, events: [R.noteOn(0, a3, 100), R.Event(time: 0, bytes: up)]).mono
        let plain = play(2.5, params: riser, events: [R.noteOn(0, a3, 100)]).mono
        var d = chroma(R.slice(bent, 2, 2.25)) - chroma(R.slice(plain, 2, 2.25))
        d -= d.rounded()
        XCTAssertEqual(d, 2.0 / 12, accuracy: 0.01, "the riser bends too")
    }

    /// Channel pressure 1 with nothing from the world (Excitement off): tension 0.3, so the climb runs 1.9× and its
    /// period is 12.5 / 1.9 = 6.58 s, within 20% of the law (mirror: 6.578 s; the engine's tension read-back 300).
    func testPressureAddsTension() {
        let o = play(14, params: riser, events: [R.noteOn(0, a3, 100), R.Event(time: 0, bytes: [0xD0, 127])])
        let law = 12.5 / 1.9
        XCTAssertEqual(1 / climbRate(chromaTrack(o.mono, from: 1, to: 13)), law, accuracy: 0.2 * law)
        XCTAssertEqual(Double(o.tension), 300, accuracy: 5)
    }

    // MARK: - Hygiene

    /// All sound off (CC 120) 50 ms into a drop (an A-minor triad, tension .8, the defaults: reverb, pulse and Grit on),
    /// and again while it climbs: below −60 dBFS on both sides from 50 ms after it, riser, thump and reverb included
    /// (mirror: silent).
    func testAllSoundOffKillsRiserAndThump() {
        let chord = [57, 60, 64].map { R.noteOn(0, UInt8($0), 110) }
        let dropped = play(3.6, events: chord + [R.Event(time: 3.05, bytes: [0xB0, 120, 0])], tension: [(0, 0.8)], drops: [3.0])
        let climbing = play(3, events: chord + [R.Event(time: 2, bytes: [0xB0, 120, 0])], tension: [(0, 0.5)])
        for (o, at) in [(dropped, 3.05), (climbing, 2.0)] {
            let end = Double(o.l.count) / sr
            XCTAssertLessThan(K.dBFS(R.slice(o.l, at + 0.05, end)), -60, "left, after all sound off at \(at) s")
            XCTAssertLessThan(K.dBFS(R.slice(o.r, at + 0.05, end)), -60, "right, after all sound off at \(at) s")
        }
    }

    /// Every dial and mood at each end (Rise 0.5 and 0, Tempo 170 and 70, fine tune and transpose at their ends),
    /// tension 1, 0 and 1 again, two drops (the second ignored), full pressure, the wheel at both ends, the pedal, twelve
    /// fortissimo notes from A0 up and a hard low chord, at 22.05, 44.1, 48, 96 and 192 kHz: only finite samples within
    /// ±1 (mirror: all finite, peaks at the limiter's 0.9).
    func testEndlessRiseRendersFinite() {
        let dials = [ISD_P_PRESSURE, ISD_P_GRIT_ER, ISD_P_PULSE, ISD_P_TAIL, ISD_P_SUB, ISD_P_SPACE, ISD_P_WIDTH, ISD_P_MOOD_ENERGY,
                     ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION].map { Int($0) }
        for rate in [22_050.0, 44_100, 48_000, 96_000, 192_000] {
            for v: Float in [0, 1] {
                var p = Dictionary(uniqueKeysWithValues: dials.map { ($0, v) })
                p[Int(ISD_P_RISE)] = v > 0 ? 0.5 : 0
                p[Int(ISD_P_TEMPO_ER)] = v > 0 ? 170 : 70
                p[Int(ISD_P_FINE_TUNE)] = v > 0 ? 50 : -50
                p[Int(ISD_P_TRANSPOSE)] = v > 0 ? 12 : -12
                var events: [R.Event] = [R.pedal(0.05, 127), R.Event(time: 0.2, bytes: [0xD0, 127]),
                                         R.Event(time: 0.3, bytes: [0xE0, 0x7F, 0x7F]), R.Event(time: 1.5, bytes: [0xE0, 0, 0])]
                for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.03, UInt8(21 + i * 9), 127)) }
                for i in 0..<4 { events.append(R.noteOn(1.8 + Double(i) * 0.01, UInt8(24 + i * 12), 127)) }
                let o = play(3, params: p, events: events, tension: [(0, 1), (2.0, 0), (2.3, 1)], drops: [1.0, 1.2], sampleRate: rate)
                XCTAssertEqual(o.l.count, Int(3 * rate))
                XCTAssertTrue(o.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && o.r.allSatisfy { $0.isFinite && abs($0) <= 1 },
                              "\(rate) Hz, dials at \(v)")
            }
        }
    }
}
