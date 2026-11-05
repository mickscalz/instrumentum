import XCTest
import InStrumDSP

/// Tea House Koto: thirteen plucked strings on the plucked-string core, a press on the wheel (oshi), yuri on pressure
/// and the open strings ringing in sympathy (docs/superpowers/briefs/tea-house-koto.md).
final class TeaHouseKotoTests: XCTestCase {
    typealias R = SynthRender
    let koto = ISD_ENGINE_TEA_HOUSE_KOTO
    /// Dry: no room, no open strings ringing.
    let dry: [Int: Float] = [Int(ISD_P_SPACE): 0, Int(ISD_P_BLOOM): 0]

    private func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
    private func band(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.bandEnergy(x, sampleRate: R.sr, from: lo, to: hi) }
    private func db(_ x: Double) -> Double { 10 * log10(max(x, 1e-30)) }

    /// The pitch wheel (14 bits: 0x2000 at rest, 0x3FFF full up, 0 full down).
    private func wheel(_ t: Double, _ value: Int) -> R.Event { R.Event(time: t, bytes: [0xE0, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)]) }
    private func pressure(_ t: Double, _ value: UInt8) -> R.Event { R.Event(time: t, bytes: [0xD0, value]) }
    private func polyPressure(_ t: Double, _ note: UInt8, _ value: UInt8) -> R.Event { R.Event(time: t, bytes: [0xA0, note, value]) }

    /// Energy within ±1% of `hz` in the Blackman–Harris spectrum (2^16 points). Its sidelobes stay about 90 dB down, so an
    /// open string's faint ring shows beside the plucked string's own partials (a plain FFT leaks them right across it).
    private func narrow(_ x: [Float], _ hz: Double) -> Double {
        let n = 1 << 16, bin = R.sr / Double(n)
        var e = 0.0
        for (k, p) in DSPTestKit.powerSpectrum(x, size: n).enumerated() where k > 0 {
            let f = Double(k) * bin
            if f >= hz * 0.99 && f <= hz * 1.01 { e += p }
        }
        return e
    }

    /// The pitch (cents against `ref`) of 40 ms windows every 20 ms from `a` to `b`: the strongest peak within ±60 cents.
    private func track(_ x: [Float], ref: Double, from a: Double, to b: Double) -> [Double] {
        var cents: [Double] = []
        var t = a
        while t + 0.04 <= b + 1e-9 {
            cents.append(DSPTestKit.cents(DSPTestKit.fundamental(R.slice(x, t, t + 0.04), sampleRate: R.sr, near: ref), ref))
            t += 0.02
        }
        return cents
    }

    /// A pitch track's wobble: its size (√2 × the RMS about the mean, a sine's amplitude) and rate (mean crossings / 2 a second).
    private func wobble(_ c: [Double]) -> (cents: Double, hz: Double) {
        guard c.count > 1 else { return (0, 0) }
        let mean = c.reduce(0, +) / Double(c.count)
        var sq = 0.0, crossings = 0
        for i in 0..<c.count {
            sq += (c[i] - mean) * (c[i] - mean)
            if i > 0, (c[i - 1] - mean < 0) != (c[i] - mean < 0) { crossings += 1 }
        }
        return ((2 * sq / Double(c.count)).squareRoot(), Double(crossings) / 2 / (Double(c.count - 1) * 0.02))
    }

    /// The time (s) at which the 50 ms RMS first falls 40 dB under its loudest so far, or -1.
    private func timeToMinus40(_ x: [Float]) -> Double {
        let w = Int(0.05 * R.sr)
        var peak = -200.0, i = 0
        while i + w <= x.count {
            let d = DSPTestKit.dBFS(x[i..<(i + w)])
            peak = max(peak, d)
            if d < peak - 40 { return Double(i) / R.sr }
            i += w
        }
        return -1
    }

    /// Renders like `SynthRender.render`, calling all-notes-off at `panicAt` and reading the voice count at `probe`.
    private func renderPanic(params: [Int: Float], events: [R.Event], seconds: Double, panicAt: Double?, probe: Double)
        -> (l: [Float], r: [Float], voices: Int32) {
        guard let s = isd_synth_create(koto, R.sr, 256) else { return ([], [], -1) }
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

    // MARK: - Tuning

    func testTuningWithin2Cents() {
        for m: UInt8 in [45, 57, 69, 81] {
            let out = R.render(koto, seconds: 2, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, m, 100)])
            let ref = midiHz(Double(m))
            let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.9), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, "MIDI \(m)")
        }
    }

    func testFineTuneAndTransposeExact() {
        var p = dry; p[Int(ISD_P_FINE_TUNE)] = 37; p[Int(ISD_P_TRANSPOSE)] = 5
        let out = R.render(koto, seconds: 2, params: p, events: [R.pedal(0, 127), R.noteOn(0.01, 57, 100)])
        let ref = midiHz(62)
        let f = DSPTestKit.fundamental(R.slice(out.l, 0.3, 1.9), sampleRate: R.sr, near: ref * pow(2, 37.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref) - 37, 0, accuracy: 1)
    }

    // MARK: - The string

    /// Pick 0.15 (the Near the Bridge preset's) against 0.5 on A3: the 2–6 kHz energy of the first 100 ms.
    func testPickNearTheBridgeIsBrighter() {
        func treble(_ pick: Float) -> Double {
            var p = dry; p[Int(ISD_P_PICK)] = pick
            return db(band(R.slice(R.render(koto, seconds: 0.2, params: p, events: [R.noteOn(0, 57, 100)]).l, 0, 0.1), 2000, 6000))
        }
        let bridge = treble(0.15), gentle = treble(0.5)
        XCTAssertGreaterThan(bridge, gentle + 6, "pick 0.15: \(bridge) dB, 0.5: \(gentle) dB")
    }

    /// Silk 1 (a soft silk string) against 0 (crisp tetron) on A3: the spectral centroid over 0.3–0.6 s.
    func testSilkIsSofter() {
        func centroid(_ silk: Float) -> Double {
            var p = dry; p[Int(ISD_P_SILK)] = silk
            return DSPTestKit.centroid(R.slice(R.render(koto, seconds: 0.7, params: p, events: [R.noteOn(0, 57, 100)]).l, 0.3, 0.6), sampleRate: R.sr)
        }
        let tetron = centroid(0), silk = centroid(1)
        XCTAssertLessThan(silk, 0.75 * tetron, "silk 0: \(tetron) Hz, silk 1: \(silk) Hz")
    }

    /// A3 falls 40 dB in 2–4 s (the brief's measure); an octave up it takes 0.6× as long.
    func testDecayTime() {
        let a3 = timeToMinus40(R.render(koto, seconds: 6, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, 57, 100)]).l)
        XCTAssertGreaterThanOrEqual(a3, 2, "A3 reached −40 dB at \(a3) s")
        XCTAssertLessThanOrEqual(a3, 4, "A3 reached −40 dB at \(a3) s")
        let a4 = timeToMinus40(R.render(koto, seconds: 3.5, params: dry, events: [R.pedal(0, 127), R.noteOn(0.01, 69, 100)]).l)
        XCTAssertGreaterThan(a4, 0)
        XCTAssertEqual(a4 / a3, 0.6, accuracy: 0.1, "A4 \(a4) s, A3 \(a3) s")
    }

    // MARK: - The left hand

    /// Oshi: the wheel to +2 semitones at 0.5 s on a held A3 reads +200 cents by 0.56 s, and the string is never
    /// plucked again (no 10 ms window more than 6 dB under the one before it).
    func testPressBendsWithoutReattack() {
        let out = R.render(koto, seconds: 0.8, params: dry, events: [R.noteOn(0, 57, 100), wheel(0.5, 0x3FFF)]).l
        let ref = midiHz(57)
        let f = DSPTestKit.fundamental(R.slice(out, 0.56, 0.66), sampleRate: R.sr, near: ref * pow(2, 200.0 / 1200))
        XCTAssertEqual(DSPTestKit.cents(f, ref), 200, accuracy: 5)
        var before = DSPTestKit.dBFS(R.slice(out, 0.45, 0.46))
        for k in 1..<15 {
            let t = 0.45 + 0.01 * Double(k), level = DSPTestKit.dBFS(R.slice(out, t, t + 0.01))
            XCTAssertGreaterThan(level, before - 6, "a dip at \(t) s")
            before = level
        }
    }

    /// Yuri (Yuri 1): channel pressure from 0.3 s wobbles a held A3 by 10–20 cents at 4–6 Hz over 0.6–1.6 s; without
    /// pressure it stays still; pressure already on waits until 150 ms after the pluck; poly pressure moves its own note.
    func testPressureGivesYuri() {
        var p = dry; p[Int(ISD_P_YURI)] = 1
        let a3 = midiHz(57)
        let pressed = wobble(track(R.render(koto, seconds: 1.7, params: p, events: [R.noteOn(0, 57, 100), pressure(0.3, 127)]).l,
                                   ref: a3, from: 0.6, to: 1.6))
        XCTAssertTrue((10...20).contains(pressed.cents), "\(pressed.cents) cents")
        XCTAssertTrue((4...6).contains(pressed.hz), "\(pressed.hz) Hz")
        let still = wobble(track(R.render(koto, seconds: 1.7, params: p, events: [R.noteOn(0, 57, 100)]).l, ref: a3, from: 0.6, to: 1.6))
        XCTAssertLessThan(still.cents, 2, "no pressure")
        let early = track(R.render(koto, seconds: 0.5, params: p, events: [pressure(0, 127), R.noteOn(0.001, 57, 100)]).l,
                          ref: a3, from: 0.02, to: 0.14)
        XCTAssertLessThan(early.map { abs($0) }.max() ?? 99, 3, "the yuri waits until the pluck has spoken")
        let both = R.render(koto, seconds: 1.7, params: p,
                            events: [R.noteOn(0, 57, 100), R.noteOn(0.001, 64, 100), polyPressure(0.3, 64, 127)]).l
        let e4 = wobble(track(both, ref: midiHz(64), from: 0.6, to: 1.6)), beside = wobble(track(both, ref: a3, from: 0.6, to: 1.6))
        XCTAssertTrue((10...20).contains(e4.cents), "E4 under poly pressure: \(e4.cents) cents")
        XCTAssertLessThan(beside.cents, 2, "A3 beside it: \(beside.cents) cents")
    }

    /// Review focus 1: the wheel up and pressure held, then all-notes-off (the app's switch; and CC 123): a new note
    /// sounds at pitch, with no yuri.
    func testSwitchClearsTheBend() {
        var p = dry; p[Int(ISD_P_YURI)] = 1
        let events = [R.noteOn(0, 57, 100), wheel(0.2, 0x3FFF), pressure(0.2, 127), R.noteOn(0.6, 57, 100)]
        let api = renderPanic(params: p, events: events, seconds: 2, panicAt: 0.5, probe: 1).l
        let cc = R.render(koto, seconds: 2, params: p, events: events + [R.Event(time: 0.5, bytes: [0xB0, 123, 0])]).l
        let ref = midiHz(57)
        for (name, out) in [("all-notes-off", api), ("CC 123", cc)] {
            let f = DSPTestKit.fundamental(R.slice(out, 0.8, 1.9), sampleRate: R.sr, near: ref)
            XCTAssertEqual(DSPTestKit.cents(f, ref), 0, accuracy: 2, name)
            XCTAssertLessThan(wobble(track(out, ref: ref, from: 0.9, to: 1.9)).cents, 1, name)
        }
    }

    /// Final review (Review focus 1's family): reset all controllers (CC 121) lets a key's own (poly) pressure go as well
    /// as channel pressure, so the yuri it started stops and the string rings on at pitch.
    func testResetAllControllersStopsTheYuri() {
        var p = dry; p[Int(ISD_P_YURI)] = 1
        let e4 = midiHz(64)
        let events = [R.noteOn(0, 64, 100), polyPressure(0.2, 64, 127), R.Event(time: 1.15, bytes: [0xB0, 121, 0])]
        let out = R.render(koto, seconds: 2.2, params: p, events: events).l
        let before = wobble(track(out, ref: e4, from: 0.5, to: 1.1))
        XCTAssertGreaterThan(before.cents, 8, "poly pressure gives yuri: \(before.cents) cents")
        let after = wobble(track(out, ref: e4, from: 1.35, to: 2.15))
        XCTAssertLessThan(after.cents, 2, "reset all controllers stops it: \(after.cents) cents")
    }

    // MARK: - The open strings

    /// Bloom 1, E4 plucked: the open B4 string (hirajōshi on E) rings over 1–2 s at least 10 dB above the same with the
    /// open strings off (B4 shares no partial with E4: only the pluck rings it, faintly); and once E4 is damped, the open
    /// strings carry it on within 45 dB of the note.
    func testOpenStringsRingInSympathy() {
        var p = dry; p[Int(ISD_P_BLOOM)] = 1
        var bankOff = p; bankOff[Int(ISD_P_DEBUG_NO_SYMPATHY)] = 1
        let b4 = midiHz(71)
        let ringing = narrow(R.slice(R.render(koto, seconds: 2, params: p, events: [R.noteOn(0, 64, 100)]).l, 1, 2), b4)
        let still = narrow(R.slice(R.render(koto, seconds: 2, params: bankOff, events: [R.noteOn(0, 64, 100)]).l, 1, 2), b4)
        XCTAssertGreaterThan(db(ringing), db(still) + 10, "B4 with the open strings \(db(ringing)) dB, without \(db(still)) dB")
        let out = R.render(koto, seconds: 2.5, params: p, events: [R.noteOn(0, 64, 100), R.noteOff(0.5, 64)]).l
        let note = DSPTestKit.dBFS(R.slice(out, 0, 0.5)), bloom = DSPTestKit.dBFS(R.slice(out, 1.5, 2.5))
        XCTAssertGreaterThan(bloom, note - 45, "the note \(note) dB, the open strings 1–2 s after its release \(bloom) dB")
    }

    /// The open strings take hirajōshi on a phrase's lowest note: a phrase on D rings the open G4 (E's tuning has no G);
    /// a D inside a phrase on E leaves it unrung; after a silence a D starts a new phrase and rings it.
    func testOpenStringsFollowThePhrase() {
        var p = dry; p[Int(ISD_P_BLOOM)] = 1
        var bankOff = p; bankOff[Int(ISD_P_DEBUG_NO_SYMPATHY)] = 1
        let g4 = midiHz(67)
        func gain(_ events: [R.Event], _ seconds: Double, from t: Double) -> Double {
            let on = narrow(R.slice(R.render(koto, seconds: seconds, params: p, events: events).l, t, t + 1), g4)
            let off = narrow(R.slice(R.render(koto, seconds: seconds, params: bankOff, events: events).l, t, t + 1), g4)
            return db(on) - db(off)
        }
        XCTAssertGreaterThan(gain([R.noteOn(0, 62, 100)], 2, from: 1), 10, "a phrase on D")
        XCTAssertLessThan(gain([R.noteOn(0, 64, 100), R.noteOff(0.2, 64), R.noteOn(0.3, 62, 100)], 2.3, from: 1.3), 3, "a D inside a phrase on E")
        XCTAssertGreaterThan(gain([R.noteOn(0, 64, 100), R.noteOff(0.5, 64), R.noteOn(2.5, 62, 100)], 4.5, from: 3.5), 10, "a D after a silence")
    }

    // MARK: - The plectrum

    /// A hard note's plectrum scrape: velocity 120 against 100, the 3–8 kHz energy of the first 5 ms (velocity alone
    /// gives about 2 dB of it); the scrape starts at 118.
    func testHardPluckScrapes() {
        func edge(_ velocity: UInt8) -> Double {
            db(band(R.slice(R.render(koto, seconds: 0.1, params: dry, events: [R.noteOn(0, 57, velocity)]).l, 0, 0.005), 3000, 8000))
        }
        XCTAssertGreaterThan(edge(120), edge(100) + 4)
        XCTAssertGreaterThan(edge(118), edge(117) + 2, "the scrape starts at 118")
    }

    // MARK: - Endings

    /// A released string settles under the hand: 40 dB down within 0.5 s.
    func testReleaseDecays() {
        let out = R.render(koto, seconds: 1.6, params: dry, events: [R.noteOn(0, 57, 100), R.noteOff(1.0, 57)]).l
        let held = DSPTestKit.dBFS(R.slice(out, 0.9, 1.0)), after = DSPTestKit.dBFS(R.slice(out, 1.5, 1.55))
        XCTAssertLessThan(after, held - 40, "held \(held) dB, 0.5 s after the release \(after) dB")
    }

    /// A hard chord with the open strings ringing (Bloom 1): all-notes-off, and CC 120 in the room, each silence the
    /// strings, the open strings and the board within 50 ms.
    func testPanicStopsTheStrings() {
        let chord = [52, 57, 64, 69, 71, 76].map { R.noteOn(0, UInt8($0), 110) }
        var p = dry; p[Int(ISD_P_BLOOM)] = 1
        let api = renderPanic(params: p, events: chord, seconds: 1.25, panicAt: 1.0, probe: 1.1)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.l, 1.05, 1.2)), -70)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(api.r, 1.05, 1.2)), -70)
        XCTAssertEqual(api.voices, 0)
        let cc = renderPanic(params: [Int(ISD_P_BLOOM): 1], events: chord + [R.Event(time: 1.0, bytes: [0xB0, 120, 0])],
                             seconds: 1.25, panicAt: nil, probe: 1.1)
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.l, 1.05, 1.2)), -70, "the room too")
        XCTAssertLessThan(DSPTestKit.dBFS(R.slice(cc.r, 1.05, 1.2)), -70, "the room too")
        XCTAssertEqual(cc.voices, 0)
    }

    // MARK: - Hygiene

    /// 40 notes under the pedal (16 stolen, quietest first, with 20 ms fades) against the same notes let go after 0.1 s
    /// (never more than 21 sounding, so none stolen): the steals add no jump of their own.
    func testStealingIsClickFree() {
        var stealing = [R.pedal(0, 127)], short: [R.Event] = []
        for i in 0..<40 {
            let t = Double(i) * 0.05, n = UInt8(40 + i)
            stealing.append(R.noteOn(t, n, 90))
            short.append(R.noteOn(t, n, 90)); short.append(R.noteOff(t + 0.1, n))
        }
        let a = R.render(koto, seconds: 3, params: dry, events: stealing)
        let b = R.render(koto, seconds: 3, params: dry, events: short)
        XCTAssertTrue(a.l.allSatisfy(\.isFinite) && a.r.allSatisfy(\.isFinite))
        let stolen = max(DSPTestKit.maxJump(a.l), DSPTestKit.maxJump(a.r))
        let attacks = max(DSPTestKit.maxJump(b.l), DSPTestKit.maxJump(b.r))
        XCTAssertLessThan(stolen, 1.25 * attacks + 0.01, "stealing \(stolen) against the attacks alone \(attacks)")
        XCTAssertLessThan(stolen, 0.4, "an attack jump this big would be a click")
        XCTAssertLessThanOrEqual(max(a.l.map { abs($0) }.max() ?? 2, a.r.map { abs($0) }.max() ?? 2), 1.0)
    }

    func testDialSweepIsSmooth() {
        let dials = [ISD_P_PICK, ISD_P_SILK, ISD_P_BODY, ISD_P_BLOOM, ISD_P_YURI, ISD_P_WIDTH].map { Int($0) }
        var start: [Int: Float] = [Int(ISD_P_SPACE): 0]
        for d in dials { start[d] = 0 }
        let changes = (dials + [Int(ISD_P_SPACE)]).map { SynthRender.ParamChange(time: 1.5, address: $0, value: 1) }
        let out = R.render(koto, seconds: 1.75, params: start,
                           events: [R.pedal(0, 127), R.noteOn(0, 57, 100), R.noteOn(0, 64, 100), pressure(0.2, 127)], changes: changes)
        // Pressure is on, so turning Yuri up sets the strings wobbling: the change is compared with the sound it settles into.
        let before = DSPTestKit.maxJump(R.slice(out.l, 1.3, 1.45)), after = DSPTestKit.maxJump(R.slice(out.l, 1.45, 1.6))
        let settled = DSPTestKit.maxJump(R.slice(out.l, 1.6, 1.75))
        XCTAssertLessThan(after, 2 * max(before, settled) + 1e-4, "before \(before), after \(after), settled \(settled)")
    }

    func testParameterTable() {
        let count = Int(isd_synth_param_count(koto))
        let infos = (0..<count).compactMap { isd_synth_param_info(koto, Int32($0)) }.map { $0.pointee }
        XCTAssertEqual(infos.map { String(cString: $0.identifier) },
                       ["fineTune", "transpose", "pick", "silk", "body", "bloom", "yuri", "space", "width",
                        "moodEnergy", "moodWarmth", "moodBrightness", "moodSpace", "moodMotion", "debugNoSympathy", "debugNoBody"])
        let defaults = Dictionary(uniqueKeysWithValues: infos.map { (String(cString: $0.identifier), $0.defaultValue) })
        XCTAssertEqual(defaults["pick"], 0.55); XCTAssertEqual(defaults["silk"], 0.45); XCTAssertEqual(defaults["body"], 0.50)
        XCTAssertEqual(defaults["bloom"], 0.40); XCTAssertEqual(defaults["yuri"], 0.30); XCTAssertEqual(defaults["space"], 0.35)
        XCTAssertEqual(defaults["width"], 0.50)
        XCTAssertEqual(infos.filter { $0.unit == 3 }.map(\.address), [Int32(ISD_P_DEBUG_NO_SYMPATHY), Int32(ISD_P_DEBUG_NO_BODY)],
                       "the test hooks are internal")
    }

    /// Every dial at 0 and at 1, the wheel thrown both ways and full pressure, over hard notes across the range.
    func testExtremesStayFinite() {
        for v: Float in [0, 1] {
            var p: [Int: Float] = [:]
            for a in [ISD_P_PICK, ISD_P_SILK, ISD_P_BODY, ISD_P_BLOOM, ISD_P_YURI, ISD_P_SPACE, ISD_P_WIDTH,
                      ISD_P_MOOD_ENERGY, ISD_P_MOOD_WARMTH, ISD_P_MOOD_BRIGHTNESS, ISD_P_MOOD_SPACE, ISD_P_MOOD_MOTION] { p[Int(a)] = v }
            var events: [R.Event] = [R.pedal(0.5, 127), pressure(0.2, 127), wheel(0.3, 0x3FFF), wheel(1.0, 0), wheel(2.0, 0x2000)]
            for i in 0..<12 { events.append(R.noteOn(0.01 + Double(i) * 0.05, UInt8(24 + i * 8), 127)) }
            let out = R.render(koto, seconds: 5, params: p, events: events)
            XCTAssertTrue(out.l.allSatisfy { $0.isFinite && abs($0) <= 1 } && out.r.allSatisfy { $0.isFinite && abs($0) <= 1 }, "dials at \(v)")
        }
    }
}
