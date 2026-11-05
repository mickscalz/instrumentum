import XCTest
import InStrumDSP

/// A biquad (transposed direct form II, in Double) for the yuri test's pitch tracker.
private struct TrackFilter {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

    /// RBJ band-pass, 0 dB at its centre.
    init(bandpass hz: Double, q: Double) {
        let w = 2 * Double.pi * hz / DSPTestKit.sampleRate, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = al / a0; b1 = 0; b2 = -al / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Zen Shakuhachi: an end-blown bamboo flute on the breath-wind core (docs/superpowers/briefs/zen-shakuhachi.md).
final class ZenShakuhachiTests: XCTestCase {
    typealias R = SynthRender
    let flute = ISD_ENGINE_ZEN_SHAKUHACHI
    /// Dry: no reverb, no echo.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_ECHO): 0]
    /// The tone alone (test hook: no breath, muraiki, yuri or echo), for measuring pitch.
    var tone: [Int: Float] { var p = dry; p[Int(ISD_P_DEBUG_TONE_ONLY)] = 1; return p }

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// The pitch wheel at `semitones` (−2…+2, the ends of its travel).
    private func wheel(_ t: Double, _ semitones: Double) -> R.Event {
        let half: Double = semitones >= 0 ? 8191 : 8192
        let v = min(16383, max(0, Int((8192 + semitones / 2 * half).rounded())))
        return R.Event(time: t, bytes: [0xE0, UInt8(v & 0x7F), UInt8(v >> 7)])
    }

    private func pressure(_ t: Double, _ p: Double) -> R.Event { R.Event(time: t, bytes: [0xD0, UInt8((p * 127).rounded())]) }

    /// Renders like `SynthRender.render`, calling all-notes-off at `panicAt` and reading the voice count at `probe`.
    private func renderPanic(params: [Int: Float], events: [R.Event], seconds: Double, panicAt: Double?, probe: Double)
        -> (l: [Float], r: [Float], voices: Int32) {
        guard let s = isd_synth_create(flute, R.sr, 256) else { return ([], [], -1) }
        defer { isd_synth_destroy(s) }
        for (a, v) in params { isd_synth_set_param(s, Int32(a), v) }
        let total = Int(seconds * R.sr), sorted = events.sorted { $0.time < $1.time }
        var left = [Float](repeating: 0, count: total), right = left
        var e = 0, i = 0, panicked = false, voices: Int32 = -1
        while i < total {
            let n = min(256, total - i)
            if let p = panicAt, !panicked, Int(p * R.sr) < i + n { isd_synth_all_notes_off(s); panicked = true }
            while e < sorted.count, Int(sorted[e].time * R.sr) < i + n {
                let off = max(0, Int(sorted[e].time * R.sr) - i)
                sorted[e].bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), Int32(off)) }
                e += 1
            }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_synth_render(s, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
            if voices < 0, Double(i) / R.sr >= probe { voices = isd_synth_active_voices(s) }
        }
        return (left, right, voices)
    }

    /// When 5 ms RMS windows first come within 6 dB of the 1–1.5 s plateau (the window's centre, s), or -1.
    private func timeToPlateau(_ x: [Float]) -> Double {
        let plateau = DSPTestKit.dBFS(R.slice(x, 1.0, 1.5)), w = Int(0.005 * R.sr)
        var i = 0
        while i + w <= x.count {
            if DSPTestKit.dBFS(x[i..<(i + w)]) >= plateau - 6 { return (Double(i) + Double(w) / 2) / R.sr }
            i += w
        }
        return -1
    }

    /// The pitch (cents against `ref`) every 10 ms from `from` to `to` s: the signal through two band-passes at `ref`
    /// (Q 1.5), its rising zero crossings (linear interpolation), the frequency over each run of 8 periods placed at
    /// the run's middle, then linearly resampled.
    private func pitchTrack(_ x: [Float], ref: Double, from: Double, to: Double) -> [Double] {
        var f1 = TrackFilter(bandpass: ref, q: 1.5), f2 = TrackFilter(bandpass: ref, q: 1.5)
        var prev = 0.0, crossings: [Double] = []
        for i in 0..<x.count {
            let y = f2.run(f1.run(Double(x[i])))
            if i > 0, prev < 0, y >= 0 { crossings.append(Double(i - 1) + -prev / (y - prev)) }
            prev = y
        }
        var times: [Double] = [], cents: [Double] = []
        for k in 8..<max(8, crossings.count) {
            times.append((crossings[k] + crossings[k - 8]) / 2 / R.sr)
            cents.append(DSPTestKit.cents(8 * R.sr / (crossings[k] - crossings[k - 8]), ref))
        }
        var out: [Double] = []
        var j = 0, t = from
        while t <= to, times.count > 1 {
            while j + 2 < times.count, times[j + 1] < t { j += 1 }
            let u = max(0, min(1, (t - times[j]) / max(1e-9, times[j + 1] - times[j])))
            out.append(cents[j] + u * (cents[j + 1] - cents[j]))
            t += 0.01
        }
        return out
    }

    // MARK: - Tuning

    func testTuningWithin5CentsOnceLocked() {
        for m: UInt8 in [62, 69, 74, 81, 86] {
            let out = R.render(flute, seconds: 1.6, params: tone, events: [R.noteOn(0, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.6, 1.6), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 5, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = tone; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(flute, seconds: 1.6, params: p, events: [R.noteOn(0, 64, 100)])
        let ref = midiHz(69)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.6, 1.6), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 2)
    }

    /// MIDI 50 sounds an octave up (MIDI 62, nothing left at 50); with the fold off (test hook), at MIDI 50.
    func testLowNotesFoldUp() {
        let folded = R.slice(R.render(flute, seconds: 1.6, params: tone, events: [R.noteOn(0, 50, 100)]).l, 0.6, 1.6)
        let up = DSPTestKit.fundamental(folded, sampleRate: R.sr, near: midiHz(62))
        XCTAssertEqual(DSPTestKit.cents(up, midiHz(62)), 0, accuracy: 5, "MIDI 50 folds up to MIDI 62")
        let at50 = db(band(folded, midiHz(50) * 0.97, midiHz(50) * 1.03)), at62 = db(band(folded, midiHz(62) * 0.97, midiHz(62) * 1.03))
        XCTAssertLessThan(at50, at62 - 30, "nothing sounds at MIDI 50 itself")
        var p = tone; p[Int(ISD_P_DEBUG_NO_FOLD)] = 1
        let unfolded = R.slice(R.render(flute, seconds: 1.6, params: p, events: [R.noteOn(0, 50, 100)]).l, 0.6, 1.6)
        let low = DSPTestKit.fundamental(unfolded, sampleRate: R.sr, near: midiHz(50))
        XCTAssertEqual(DSPTestKit.cents(low, midiHz(50)), 0, accuracy: 5, "without the fold, MIDI 50")
    }

    // MARK: - Breath

    /// Air 1: the note begins as air and the level reaches 6 dB under its plateau no sooner than 200 ms; Air 0 within 80 ms.
    func testAirSlowsTheAttack() {
        func attack(_ air: Float) -> Double {
            var p = dry; p[Int(ISD_P_AIR)] = air
            return timeToPlateau(R.render(flute, seconds: 1.5, params: p, events: [R.noteOn(0, 69, 100)]).l)
        }
        let slow = attack(1), quick = attack(0)
        XCTAssertGreaterThanOrEqual(slow, 0.2, "Air 1 came within 6 dB of its plateau at \(slow) s")
        XCTAssertGreaterThan(quick, 0)
        XCTAssertLessThanOrEqual(quick, 0.08, "Air 0 came within 6 dB of its plateau at \(quick) s")
    }

    /// A hard note (velocity 120) against a soft one (60): its 2–6 kHz energy over the first 150 ms, each against
    /// its own level over 0.5–1 s, at least 6 dB higher (muraiki, the burst of breath on a hard note).
    func testMuraikiBurst() {
        func burst(_ velocity: UInt8) -> Double {
            let x = R.render(flute, seconds: 1.0, params: dry, events: [R.noteOn(0, 69, velocity)]).l
            return db(band(R.slice(x, 0, 0.15), 2000, 6000)) - DSPTestKit.dBFS(R.slice(x, 0.5, 1.0))
        }
        let soft = burst(60), hard = burst(120)
        XCTAssertGreaterThan(hard, soft + 6, "velocity 60: \(soft) dB, 120: \(hard) dB")
    }

    // MARK: - Meri, kari, yuri

    /// Bend 1 and full channel pressure from 0.3 s on a held A4, against the same note untouched, over 0.8–1.2 s:
    /// 150 cents flat (±15, the tone alone so the pitch reads cleanly) and darker, the sound as heard (tone and
    /// breath, dry) with its centroid at least 25% lower, and the tone by itself at least 20% lower.
    func testMeriBendsDownAndDarkens() {
        func held(_ params: [Int: Float], meri: Bool) -> [Float] {
            var p = params; p[Int(ISD_P_BEND)] = 1
            var events = [R.noteOn(0, 69, 100)]
            if meri { events.append(pressure(0.3, 1)) }
            return R.slice(R.render(flute, seconds: 1.2, params: p, events: events).l, 0.8, 1.2)
        }
        let plainTone = held(tone, meri: false), meriTone = held(tone, meri: true)
        let ref = midiHz(69)
        let f = DSPTestKit.fundamental(meriTone, sampleRate: R.sr, near: ref * pow(2, -150.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref), -150, accuracy: 15)
        let a = DSPTestKit.centroid(held(dry, meri: false), sampleRate: R.sr), b = DSPTestKit.centroid(held(dry, meri: true), sampleRate: R.sr)
        XCTAssertLessThan(b, 0.75 * a, "untouched \(a) Hz, meri \(b) Hz")
        let ta = DSPTestKit.centroid(plainTone, sampleRate: R.sr), tb = DSPTestKit.centroid(meriTone, sampleRate: R.sr)
        XCTAssertLessThan(tb, 0.8 * ta, "the tone alone: untouched \(ta) Hz, meri \(tb) Hz")
    }

    /// The wheel up one semitone (half its travel) is kari, 100 cents sharp (±10); all the way up it stays at +100
    /// (kari's most) and only brightens; the wheel's lower half is a plain bend (−200 cents at the bottom).
    func testKariBendsUp() {
        func cents(_ semitones: Double, near: Double) -> Double {
            let out = R.render(flute, seconds: 1.2, params: tone, events: [R.noteOn(0, 69, 100), wheel(0.3, semitones)]).l
            let f = DSPTestKit.fundamental(R.slice(out, 0.8, 1.2), sampleRate: R.sr, near: 440 * pow(2, near / 1200))
            return DSPTestKit.cents(f, 440)
        }
        XCTAssertEqual(cents(1, near: 100), 100, accuracy: 10, "kari")
        XCTAssertEqual(cents(2, near: 100), 100, accuracy: 10, "kari stops at +100 cents")
        XCTAssertEqual(cents(-2, near: -200), -200, accuracy: 10, "the wheel down is a plain bend")
    }

    /// Yuri 1 (Breath 0, so the pitch reads cleanly): after 0.6 s the pitch wobbles with its strongest rate in
    /// 3–5 Hz, by 8–25 cents at its peaks, and its period varies by at least 10% from cycle to cycle; Yuri 0 holds still.
    func testYuriIsSlowAndIrregular() {
        func track(_ yuri: Float) -> [Double] {
            var p = dry; p[Int(ISD_P_YURI)] = yuri; p[Int(ISD_P_BREATH)] = 0
            let out = R.render(flute, seconds: 3.6, params: p, events: [R.noteOn(0, 69, 100)]).l
            let raw = pitchTrack(out, ref: 440, from: 0.6, to: 3.4)
            let mean = raw.reduce(0, +) / Double(max(1, raw.count))
            return raw.map { $0 - mean }
        }
        let wobble = track(1)
        guard wobble.count > 200 else { return XCTFail("the pitch track has \(wobble.count) points") }
        // The strongest rate between 1 and 12 Hz (a Hann-windowed DFT of the track, 0.05 Hz steps).
        var best = 0.0, bestRate = 0.0
        for k in 20...240 {
            let rate = Double(k) * 0.05
            var re = 0.0, im = 0.0
            for (i, v) in wobble.enumerated() {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(wobble.count - 1)), a = 2 * Double.pi * rate * Double(i) * 0.01
                re += w * v * cos(a); im -= w * v * sin(a)
            }
            if re * re + im * im > best { best = re * re + im * im; bestRate = rate }
        }
        XCTAssertGreaterThanOrEqual(bestRate, 3, "strongest rate \(bestRate) Hz")
        XCTAssertLessThanOrEqual(bestRate, 5, "strongest rate \(bestRate) Hz")
        let peak = wobble.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 8, "peak \(peak) cents")
        XCTAssertLessThan(peak, 25, "peak \(peak) cents")
        // Its period, cycle by cycle (rising zero crossings of the track smoothed over 50 ms).
        var smooth: [Double] = []
        for i in 0..<wobble.count { let lo = max(0, i - 2), hi = min(wobble.count - 1, i + 2); smooth.append(wobble[lo...hi].reduce(0, +) / Double(hi - lo + 1)) }
        var ups: [Double] = []
        for i in 1..<smooth.count where smooth[i - 1] < 0 && smooth[i] >= 0 { ups.append(Double(i - 1) + -smooth[i - 1] / (smooth[i] - smooth[i - 1])) }
        let periods = zip(ups.dropFirst(), ups).map { ($0 - $1) * 0.01 }
        XCTAssertGreaterThanOrEqual(periods.count, 5, "cycles \(periods)")
        let mean = periods.reduce(0, +) / Double(max(1, periods.count))
        let spread = ((periods.max() ?? 0) - (periods.min() ?? 0)) / max(mean, 1e-9)
        XCTAssertGreaterThanOrEqual(spread, 0.1, "periods \(periods)")
        let still = track(0).map { abs($0) }.max() ?? 99
        XCTAssertLessThan(still, 4, "Yuri 0 wobbles \(still) cents")
    }

    /// Review focus 1: a note held under full pressure (Bend 1) with the wheel all the way up, then all-notes-off (an
    /// instrument, world or preset switch); a new note sounds at its own pitch, neither flat nor sharp.
    func testSwitchClearsThePressure() {
        var p = tone; p[Int(ISD_P_BEND)] = 1
        let events = [R.noteOn(0, 69, 100), pressure(0.1, 1), wheel(0.1, 2), R.noteOn(0.5, 74, 100)]
        let out = renderPanic(params: p, events: events, seconds: 2.1, panicAt: 0.45, probe: 0.49)
        XCTAssertEqual(out.voices, 0, "the held note is gone")
        let ref = midiHz(74)
        let f = DSPTestKit.fundamental(R.slice(out.l, 1.1, 2.1), sampleRate: R.sr, near: ref)
        XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 5)
    }

    /// Final review (Review focus 1's family): a note sunk into meri by its own key's (poly) pressure at Bend 1, then
    /// reset all controllers (CC 121): it comes back up to pitch, as it does when channel pressure is reset.
    func testResetAllControllersLetsPolyPressureGo() {
        var p = tone; p[Int(ISD_P_BEND)] = 1
        let held = [R.noteOn(0, 74, 100), R.Event(time: 0.4, bytes: [0xA0, 74, 127])]
        let ref = midiHz(74)
        let pressed = R.render(flute, seconds: 1.2, params: p, events: held).l
        let sunk = DSPTestKit.fundamental(R.slice(pressed, 0.8, 1.2), sampleRate: R.sr, near: ref * pow(2, -150.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(sunk, ref), -150, accuracy: 15, "poly pressure is meri")
        let reset = R.render(flute, seconds: 2.0, params: p, events: held + [R.Event(time: 1.0, bytes: [0xB0, 121, 0])]).l
        let f = DSPTestKit.fundamental(R.slice(reset, 1.5, 2.0), sampleRate: R.sr, near: ref)
        XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 5, "reset all controllers lets it go")
    }

    // MARK: - Endings

    func testReleaseDecays() {
        let out = R.render(flute, seconds: 3.0, params: dry, events: [R.noteOn(0, 69, 100), R.noteOff(1, 69)]).l
        let held = DSPTestKit.dBFS(R.slice(out, 0.6, 1.0))
        XCTAssertGreaterThan(DSPTestKit.dBFS(R.slice(out, 1.0, 1.05)), held - 10, "the breath eases off rather than stopping")
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(out, 2.8, 3.0)), -90)
    }

    /// A hard chord (muraiki bursting) with the echo full up and the open air at its default: all-sound-off (CC 120)
    /// silences everything within 50 ms, both of the echo's repeats included, and leaves no voices; all-notes-off ends
    /// the voices too (their echo may ring on, as a reverb's tail does).
    func testPanicStopsTheBreathAndTheEcho() {
        let p: [Int: Float] = [Int(ISD_P_ECHO): 1]
        let chord = [62, 69, 74, 81].map { R.noteOn(0, UInt8($0), 120) }
        let cc = renderPanic(params: p, events: chord + [R.Event(time: 0.5, bytes: [0xB0, 120, 0])], seconds: 1.8, panicAt: nil, probe: 0.6)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.l, 0.55, 1.8)), -70)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.r, 0.55, 1.8)), -70)
        XCTAssertEqual(cc.voices, 0)
        let api = renderPanic(params: p, events: chord, seconds: 0.7, panicAt: 0.5, probe: 0.6)
        XCTAssertEqual(api.voices, 0)
    }

    // MARK: - Hygiene

    func testStealingIsClickFree() {
        let events = (0..<24).map { R.noteOn(Double($0) * 0.125, UInt8(50 + ($0 * 5) % 40), 100) }
        let out = R.render(flute, seconds: 4, params: dry, events: events)
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.2)
        XCTAssertLessThan(DSPTestKit.maxJump(out.r), 0.2)
        XCTAssertLessThanOrEqual(max(out.l.map { abs($0) }.max() ?? 2, out.r.map { abs($0) }.max() ?? 2), 1.0)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_BREATH, ISD_P_AIR, ISD_P_BEND, ISD_P_BAMBOO, ISD_P_YURI, ISD_P_ECHO, ISD_P_WIDTH].map { Int($0) }
        var start: [Int: Float] = [Int(ISD_P_SPACE): 0]
        for d in dials { start[d] = 0 }
        let changes = (dials + [Int(ISD_P_SPACE)]).map { SynthRender.ParamChange(time: 1.5, address: $0, value: 1) }
        let out = R.render(flute, seconds: 1.75, params: start, events: [R.noteOn(0, 69, 100), R.noteOn(0, 76, 100), pressure(0.2, 0.5)],
                           changes: changes)
        // Breath and the echo legitimately add detail, so the change is compared with the sound it settles into.
        let before = DSPTestKit.maxJump(R.slice(out.l, 1.3, 1.45)), after = DSPTestKit.maxJump(R.slice(out.l, 1.45, 1.6))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 1.6, 1.75))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(flute))
        let infos = (0..<count).compactMap { isd_synth_param_info(flute, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "breath", "air", "bend", "bamboo", "yuri", "echo", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugToneOnly", "debugNoFold"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["breath"], 0.45); XCTAssertEqual(defaults["air"], 0.55); XCTAssertEqual(defaults["bend"], 0.60)
        XCTAssertEqual(defaults["bamboo"], 0.50); XCTAssertEqual(defaults["yuri"], 0.40); XCTAssertEqual(defaults["echo"], 0.30)
        XCTAssertEqual(defaults["space"], 0.40); XCTAssertEqual(defaults["width"], 0.45)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_TONE_ONLY), Int32(ISD_P_DEBUG_NO_FOLD)],
                       "the test hooks are internal")
    }

    /// Every dial and mood at each end, across the whole keyboard at full velocity, with the wheel and the pressure
    /// pushed to their ends too.
    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_BREATH, ISD_P_AIR, ISD_P_BEND, ISD_P_BAMBOO, ISD_P_YURI, ISD_P_ECHO, ISD_P_SPACE, ISD_P_WIDTH,
                      ISD_P_MOOD_ENERGY, ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127), pressure(1.5, 1), wheel(2, 2), wheel(3, -2), pressure(3.5, 0)]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            let out = R.render(flute, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
