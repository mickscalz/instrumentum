import XCTest
import InStrumCore
import InStrumDSP

// MARK: - Fire & Neon: the volcano and drive families (spec §8.3, §9.3; plan Task 10)

extension AmbienceTests {
    static let fireNeon: [ISDAmbienceSource] = [ISD_AMB_VENT_RUMBLE, ISD_AMB_LAVA_HISS, ISD_AMB_STEAM_VENT, ISD_AMB_ROCKFALL,
                                                ISD_AMB_ERUPTION_BOOM, ISD_AMB_PLUME_THUNDER, ISD_AMB_WET_TYRES, ISD_AMB_WIPERS,
                                                ISD_AMB_DRIVE_ENGINE, ISD_AMB_DRIVE_PASSING_CAR, ISD_AMB_ROOF_RAIN, ISD_AMB_FAR_SIREN]

    static func post(_ source: ISDAmbienceSource, at t: Double, delay: Float = 0, strength: Float = 1, pan: Float = 0,
                     speed: Float = 0, distance: Float = 0, kind: Int32 = 0) -> Action {
        (t, { isd_ambience_post_event($0, source, delay, strength, pan, speed, distance, kind) })
    }
    static func lake(surge: Float, glow: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_lake($0, surge, glow) }) }

    /// Renders as `render` does, and reads `probe` (a source's pitch, isd_ambience_debug_hz) after every block of 256.
    static func renderProbed(seconds: Double, probe: ISDAmbienceSource, actions: [Action]) -> (out: (l: [Float], r: [Float]), hz: [Float]) {
        guard let a = isd_ambience_create(sr, 256, 1) else { return (([], []), []) }
        defer { isd_ambience_destroy(a) }
        let total = Int(seconds * sr)
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total), hz: [Float] = []
        let pending = actions.sorted { $0.time < $1.time }
        var next = 0, i = 0
        while i < total {
            let n = min(256, total - i)
            while next < pending.count, Int(pending[next].time * sr) < i + n { pending[next].apply(a); next += 1 }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            hz.append(isd_ambience_debug_hz(a, probe))
            i += n
        }
        return ((left, right), hz)
    }

    /// The pitch probe's time (s) for block `k` (the end of it).
    static func probeTime(_ k: Int) -> Double { Double((k + 1) * 256) / sr }

    /// Each Fire & Neon source alone at level 1, with its events (spec §14: finite and bounded at 1.0), around its band
    /// and at its level: the continuous ones by their RMS, the events by their peaks. (g++/clang mirror, 11 seeds: vent
    /// −32.7 to −30.4 RMS; lava hiss −28.0 to −26.7 RMS; steam −10.4 to −8.7 peak; rockfall −10.4 to −5.1 peak; boom −12.2
    /// to −7.4 peak; plume −16.7 to −11.6 peak; tyres −25.5 to −25.1 RMS; wipers −25.0 to −24.5 peak; engine −31.0 RMS;
    /// car −8.0 to −6.2 peak; roof rain −26.6 RMS; siren −25.1 to −21.4 peak dBFS; every centroid well inside.)
    func testFireNeonSourcesFiniteAndBounded() {
        let table: [(ISDAmbienceSource, String, Double, [Action], ClosedRange<Double>, ClosedRange<Double>, Bool)] = [
            (ISD_AMB_VENT_RUMBLE, "vent rumble", 13, [Self.lake(surge: 1, glow: 0.3)], 20...80, -36 ... -28, false),
            (ISD_AMB_LAVA_HISS, "lava hiss", 13, [Self.lake(surge: 0.3, glow: 0.5)], 300...1500, -31 ... -23, false),
            (ISD_AMB_STEAM_VENT, "steam vent", 12, [Self.post(ISD_AMB_STEAM_VENT, at: 3, pan: 0.3, distance: 0.2)], 1200...5000, -15 ... -6, true),
            (ISD_AMB_ROCKFALL, "rockfall", 10, [Self.post(ISD_AMB_ROCKFALL, at: 3, pan: -0.3, distance: 0.2)], 200...2500, -14 ... -3, true),
            (ISD_AMB_ERUPTION_BOOM, "eruption boom", 16, [Self.post(ISD_AMB_ERUPTION_BOOM, at: 3)], 30...200, -15 ... -5, true),
            (ISD_AMB_PLUME_THUNDER, "plume thunder", 8, [Self.post(ISD_AMB_PLUME_THUNDER, at: 3, strength: 0.8, pan: 0.2)], 150...2000, -19 ... -9, true),
            (ISD_AMB_WET_TYRES, "wet tyres", 13, [Self.speed(1), Self.wetness(0.8)], 400...2500, -30 ... -22, false),
            (ISD_AMB_WIPERS, "wipers", 7, [Self.post(ISD_AMB_WIPERS, at: 3, strength: 0.8, speed: 1.2),
                                          Self.post(ISD_AMB_WIPERS, at: 4.2, strength: 0.8, speed: 1.2)], 1000...4000, -29 ... -20, true),
            (ISD_AMB_DRIVE_ENGINE, "drive engine", 13, [Self.speed(0.5)], 40...200, -35 ... -27, false),
            (ISD_AMB_DRIVE_PASSING_CAR, "passing car", 10, [Self.wetness(0.8), Self.post(ISD_AMB_DRIVE_PASSING_CAR, at: 3, delay: 3, pan: -1,
                                                                                         speed: 8, distance: 3.6)], 400...3500, -13 ... -4, true),
            (ISD_AMB_ROOF_RAIN, "roof rain", 13, [], 200...1200, -30 ... -22, false),
            (ISD_AMB_FAR_SIREN, "far siren", 30, [Self.key(2, major: true), Self.trigger(ISD_AMB_FAR_SIREN, at: 2)], 250...1500, -28 ... -18, true),
        ]
        let rendered = Self.renderAll(table.map { (seconds: $0.2, actions: [Self.level($0.0, 1)] + $0.3) })
        for (k, row) in table.enumerated() {
            let (_, name, seconds, _, band, loudness, byPeak) = row
            let out = rendered[k]
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), "\(name) is finite")
            XCTAssertLessThanOrEqual(max(DSPTestKit.peak(out.l), DSPTestKit.peak(out.r)), 1, "\(name) is bounded at 1.0")
            let centroid = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(out), 3, seconds), sampleRate: Self.sr)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            let db = byPeak ? Self.peakDB(out, 3, seconds) : Self.stereoDB(out, 3, seconds)
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS\(byPeak ? " peak" : "")")
        }
    }

    /// The vent rumble is felt more than heard (spec §8.3): at level 1 and the lake surging (its loudest) at least 80% of
    /// it at 20–80 Hz, and at least 10 dB under Magma Bass at its defaults, a held E1 or A1 at velocity 100, both overall
    /// and at 20–80 Hz (before the ambience's own volume, which takes 12 dB more by default). (Mirror: −32.0 dBFS against
    /// −18.4 and −16.0; at 20–80 Hz −32.1 against −20.8 and −17.4; 98% in the band.)
    func testVentRumbleSitsUnderMagmaBass() {
        let vent = Self.render(seconds: 13, actions: [Self.level(ISD_AMB_VENT_RUMBLE, 1), Self.lake(surge: 1, glow: 0)])
        let ventBody = SynthRender.slice(Self.mid(vent), 3, 13)
        XCTAssertGreaterThanOrEqual(Self.bandShare(ventBody, 20, 80), 0.8, "felt more than heard")
        let ventDB = Self.stereoDB(vent, 3, 13), ventSub = Self.bandDB(ventBody, 20, 80)
        for note: UInt8 in [28, 33] {
            let bass = SynthRender.render(ISD_ENGINE_MAGMA_BASS, seconds: 3, events: [SynthRender.noteOn(0, note, 100)])
            let bassDB = Self.stereoDB(bass, 0.5, 2.5), bassSub = Self.bandDB(SynthRender.slice(Self.mid(bass), 0.5, 2.5), 20, 80)
            XCTAssertGreaterThanOrEqual(bassDB - ventDB, 10, "note \(note): the bass at \(bassDB), the rumble at \(ventDB) dBFS")
            XCTAssertGreaterThanOrEqual(bassSub - ventSub, 10, "note \(note) at 20–80 Hz: the bass at \(bassSub), the rumble at \(ventSub) dBFS")
        }
        XCTAssertTrue(vent.l.allSatisfy(\.isFinite) && vent.r.allSatisfy(\.isFinite))
    }

    /// The drive's engine (spec §9.3; plan Task 10): climbing from 50 to 130 km/h over 16 s its firing note rises with the
    /// speed and drops at each automatic shift, three of them (fifth to eighth), each by at least 15% within 0.4 s; held
    /// at 130 km/h it sits in eighth at 64.7 Hz (1940 revs) and the sound's own fundamental is that note within 1%.
    func testDriveEngineFollowsSpeedAndShifts() {
        var actions: [Action] = [Self.level(ISD_AMB_DRIVE_ENGINE, 1), Self.speed(0)]
        for k in 1...64 { actions.append(Self.speed(Float(k) / 64, at: 3 + Double(k) * 0.25)) }
        let run = Self.renderProbed(seconds: 26, probe: ISD_AMB_DRIVE_ENGINE, actions: actions)
        let hz = run.hz.map(Double.init)
        XCTAssertEqual(hz[Int(2.5 * Self.sr / 256)], 1000 * 50 / 34.5 / 30, accuracy: 0.6, "50 km/h in fifth: 1449 revs")
        // Shifts: falls of more than 3% inside 0.4 s, counted once each.
        var drops: [(t: Double, depth: Double)] = []
        let window = Int(0.4 * Self.sr / 256)
        var k = window
        while k < Int(21 * Self.sr / 256) {
            let before = hz[(k - window)..<k].max() ?? 0
            if hz[k] < 0.97 * before {
                let bottom = hz[k..<min(hz.count, k + window)].min() ?? hz[k]
                drops.append((Self.probeTime(k), 1 - bottom / before))
                k += 2 * window
            } else {
                k += 1
            }
        }
        XCTAssertEqual(drops.count, 3, "three shifts on the climb: \(drops)")
        for d in drops { XCTAssertGreaterThanOrEqual(d.depth, 0.15, "a shift drops the note: \(d)") }
        // Between the shifts it climbs with the speed.
        let edges = [3.5] + drops.map { $0.t } + [19.0]
        for i in 0..<(edges.count - 1) {
            let a = Int((edges[i] + 0.6) * Self.sr / 256), b = Int((edges[i + 1] - 0.1) * Self.sr / 256)
            guard a < b else { continue }
            XCTAssertGreaterThan(hz[b], hz[a] * 1.05, "in gear from \(edges[i]) s it rises with the speed")
        }
        let held = Array(hz[Int(21 * Self.sr / 256)..<Int(25.9 * Self.sr / 256)])
        let note = held.reduce(0, +) / Double(held.count)
        XCTAssertEqual(note, 2 * 1000 * 130 / 67 / 60, accuracy: 0.5, "130 km/h in eighth")
        let f0 = DSPTestKit.fundamental(SynthRender.slice(Self.mid(run.out), 21, 25.9), sampleRate: Self.sr, near: note)
        XCTAssertEqual(f0 / note, 1, accuracy: 0.01, "the sound's own note \(f0) Hz against \(note) Hz")
    }

    /// Passing cars Doppler down (spec §9.3; plan Task 10). An oncoming car 13 m to your right closing at 56 m/s: its
    /// engine's note as heard falls all through the pass, a second either side of its closest approach by the geometry's
    /// own ratio ((343 − 54.5)/(343 + 54.5) = 0.726, within 2%), the sound's own peaks agreeing within 1%; it swings out
    /// to its side alongside (the right at least 8 dB up) from nearer the middle a second and a half before. A car
    /// overtaking you 4 m off at 6 m/s barely falls (between 0.96 and 1); a truck is lower, and longer alongside (passing
    /// at 10 m/s, 4 m off, within 3 dB of its loudest at least half as long again as a car). (Mirror: 0.7256 against
    /// 0.7258; the audio within 0.4%; 14.5 and 3.3 dB; 0.9713.)
    func testPassingCarsDopplerDown() {
        func pass(closing: Float, lateral: Float, side: Float, truck: Bool) -> (out: (l: [Float], r: [Float]), hz: [Double]) {
            let run = Self.renderProbed(seconds: 8, probe: ISD_AMB_DRIVE_PASSING_CAR, actions: [
                Self.level(ISD_AMB_DRIVE_PASSING_CAR, 1), Self.wetness(0.8),
                Self.post(ISD_AMB_DRIVE_PASSING_CAR, at: 1, delay: 3, pan: side, speed: closing, distance: lateral, kind: truck ? 1 : 0),
            ])
            return (run.out, run.hz.map(Double.init))
        }
        func at(_ hz: [Double], _ t: Double) -> Double { hz[Int(t * Self.sr / 256)] }
        let car = pass(closing: 56, lateral: 13, side: 1, truck: false)
        let closest = 4.0
        XCTAssertGreaterThan(at(car.hz, closest - 2), at(car.hz, closest - 1))
        XCTAssertGreaterThan(at(car.hz, closest - 1), at(car.hz, closest))
        XCTAssertGreaterThan(at(car.hz, closest), at(car.hz, closest + 1))
        XCTAssertGreaterThan(at(car.hz, closest + 1), at(car.hz, closest + 2))
        let ratio = at(car.hz, closest + 1) / at(car.hz, closest - 1)
        XCTAssertEqual(ratio, (343 - 54.5) / (343 + 54.5), accuracy: 0.02, "Doppler down by \(ratio)")
        let m = Self.mid(car.out)
        for (a, b) in [(closest - 1, closest - 0.4), (closest + 0.4, closest + 1)] {
            let i = Int(a * Self.sr / 256), j = Int(b * Self.sr / 256)
            let heard = car.hz[i..<j].reduce(0, +) / Double(j - i)
            let f = DSPTestKit.fundamental(SynthRender.slice(m, a, b), sampleRate: Self.sr, near: heard)
            XCTAssertEqual(f / heard, 1, accuracy: 0.01, "\(a)–\(b) s: the sound at \(f) Hz, the engine as heard \(heard) Hz")
        }
        let alongside = DSPTestKit.dBFS(SynthRender.slice(car.out.r, closest - 0.1, closest + 0.1)) - DSPTestKit.dBFS(SynthRender.slice(car.out.l, closest - 0.1, closest + 0.1))
        let coming = DSPTestKit.dBFS(SynthRender.slice(car.out.r, closest - 1.6, closest - 1.4)) - DSPTestKit.dBFS(SynthRender.slice(car.out.l, closest - 1.6, closest - 1.4))
        XCTAssertGreaterThanOrEqual(alongside, 8, "alongside, on its side: \(alongside) dB")
        XCTAssertLessThan(coming, alongside - 2, "nearer the middle as it comes: \(coming) dB")
        let overtaking = pass(closing: 6, lateral: 4, side: -1, truck: false)
        let slow = at(overtaking.hz, closest + 1) / at(overtaking.hz, closest - 1)
        XCTAssertTrue((0.96..<1).contains(slow), "overtaking: \(slow)")
        let truck = pass(closing: 50, lateral: 13, side: 1, truck: true)
        XCTAssertLessThan(at(truck.hz, closest - 1), 0.8 * at(car.hz, closest - 1), "a truck is lower")
        // Longer: overtaking you at 10 m/s, 4 m off, a truck is alongside for its 20 m; a car only passes.
        func alongside(_ x: (l: [Float], r: [Float])) -> Double {
            let frames = Self.stereoFrames(x, ms: 50, from: 0, to: 8)
            var smooth: [Double] = []
            for i in frames.indices {
                let window = frames[max(0, i - 2)...min(frames.count - 1, i + 2)].map { pow(10, $0 / 10) }
                smooth.append(10 * log10(window.reduce(0, +) / Double(window.count)))
            }
            let top = smooth.max() ?? -200
            return Double(smooth.filter { $0 >= top - 3 }.count) * 0.05
        }
        let carBeside = pass(closing: 10, lateral: 4, side: 1, truck: false), truckBeside = pass(closing: 10, lateral: 4, side: 1, truck: true)
        XCTAssertGreaterThanOrEqual(alongside(truckBeside.out), 1.5 * alongside(carBeside.out), "and longer alongside")
        for x in [car.out, overtaking.out, truck.out, carBeside.out, truckBeside.out] { XCTAssertTrue(x.l.allSatisfy(\.isFinite) && x.r.allSatisfy(\.isFinite)) }
    }

    /// The far siren (spec §9.3; plan Task 10): in D major and in F♯ minor, every tone it rests on (0.4 s or more) is one
    /// of the key's pentatonic tones (A3–G♯4 up an octave and a step) within 10 cents, and, heard close (closeness 1, the
    /// room at its least), the sound's own fundamental agrees within 10 cents; it glides between them slowly (at least
    /// 0.7 s from one rest to the next) and never goes back to the tone before last, so it is never a two-tone siren; the
    /// call comes and goes within 14–28 s. (Mirror, 12 seeds × both keys: every rest on its tone; the sound within 4.3
    /// cents on all 129 rests of a second or more, at least four a call.)
    func testFarSirenLandsOnTheKeysTones() {
        for (root, major) in [(2, true), (6, false)] {
            let run = Self.renderProbed(seconds: 32, probe: ISD_AMB_FAR_SIREN, actions: [
                Self.level(ISD_AMB_FAR_SIREN, 1), Self.key(Int32(root), major: major), Self.closeness(1), Self.trigger(ISD_AMB_FAR_SIREN, at: 2),
            ])
            let hz = run.hz.map(Double.init)
            let tonic = 4 * Self.tonic(root), steps = major ? [0, 2, 4, 7, 9] : [0, 3, 5, 7, 10]
            let tones = (0...7).map { tonic * pow(2, Double(12 * ($0 / 5) + steps[$0 % 5]) / 12) }
            var rests: [(start: Double, length: Double, hz: Double)] = []
            var i = 0
            while i < hz.count {
                guard hz[i] > 0 else { i += 1; continue }
                var j = i
                while j + 1 < hz.count, hz[j + 1] > 0, abs(1200 * log2(hz[j + 1] / hz[i])) < 1 { j += 1 }
                let length = Double(j - i) * 256 / Self.sr
                if length >= 0.4 { rests.append((Self.probeTime(i), length, hz[(i + j) / 2])) }
                i = j + 1
            }
            XCTAssertGreaterThanOrEqual(rests.count, 4, "root \(root): it rests on \(rests.count) tones")
            let m = Self.mid(run.out)
            let sounding = hz.indices.filter { hz[$0] > 0 }
            let callEnd = Self.probeTime(sounding.last ?? 0)
            for r in rests {
                let off = tones.map { abs(1200 * log2(r.hz / $0)) }.min() ?? 99
                XCTAssertLessThanOrEqual(off, 10, "root \(root): a rest at \(r.hz) Hz is \(off) cents off the key's tones")
                // The sound itself, on rests of a second or more while the call is up (not in its last 4 s, as it fades into
                // the room), over each one's second half (the room's tail of the glide in has died away).
                if r.length >= 1, r.start + r.length <= callEnd - 4 {
                    let f = DSPTestKit.fundamental(SynthRender.slice(m, r.start + 0.5 * r.length, r.start + r.length - 0.05), sampleRate: Self.sr, near: r.hz)
                    XCTAssertEqual(DSPTestKit.cents(f, r.hz), 0, accuracy: 10, "root \(root): heard at \(f) Hz on \(r.hz) Hz")
                }
            }
            for k in 1..<rests.count {
                XCTAssertGreaterThanOrEqual(rests[k].start - (rests[k - 1].start + rests[k - 1].length), 0.7, "root \(root): a slow glide")
                if k >= 2 { XCTAssertGreaterThan(abs(1200 * log2(rests[k].hz / rests[k - 2].hz)), 10, "root \(root): never back to the tone before last") }
            }
            let call = Double((sounding.last ?? 0) - (sounding.first ?? 0)) * 256 / Self.sr
            XCTAssertTrue((13.9...28.1).contains(call), "root \(root): the call lasts \(call) s")
            XCTAssertTrue(run.out.l.allSatisfy(\.isFinite) && run.out.r.allSatisfy(\.isFinite))
        }
    }

    /// The eruption's boom (spec §8.3): posted 1.5 s late it arrives 1.5 s later (within 0.05 s), silent before; most of
    /// its first two seconds is below 200 Hz; its echoes come back off the crater walls 92, 147, 213 and 288 ms after the
    /// blast, each standing over the median of the bed between them at 300–3000 Hz (the first by 3 dB, the rest by 1.5);
    /// its crackling tail is still there 3–6 s on; and it stays well under the limiter. (Mirror, 16 seeds: on time; 83–93%
    /// deep; the echoes at least 5.1, 3.6, 2.8, 2.9 dB over the bed; peaks −7.4 to −12.2 dBFS.)
    func testEruptionBoomArrivesLateWithEchoes() {
        let out = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_ERUPTION_BOOM, 1), Self.post(ISD_AMB_ERUPTION_BOOM, at: 1, delay: 1.5)])
        let m = Self.mid(out)
        let frames = Self.frameDB(m, ms: 5), top = frames.max() ?? -200
        let onset = Double(frames.firstIndex { $0 >= top - 40 } ?? 0) * 0.005
        XCTAssertEqual(onset, 2.5, accuracy: 0.05, "the boom arrives at \(onset) s")
        XCTAssertLessThan(DSPTestKit.dBFS(SynthRender.slice(m, 1, 2.45)), -100, "nothing early")
        XCTAssertGreaterThanOrEqual(Self.bandShare(SynthRender.slice(m, 2.5, 4.5), 20, 200), 0.5, "deep")
        let band = Self.bandpass(m, 300, 3000), taps = [0.092, 0.147, 0.213, 0.288]
        func db(_ a: Double, _ b: Double) -> Double { DSPTestKit.dBFS(SynthRender.slice(band, 2.5 + a, 2.5 + b)) }
        var bed: [Double] = []
        for t in stride(from: 0.03, through: 0.318, by: 0.006) where taps.allSatisfy({ abs(t - $0) > 0.02 }) { bed.append(db(t, t + 0.012)) }
        bed.sort()
        let floor = bed[bed.count / 2]
        for (k, tap) in taps.enumerated() {
            let rise = db(tap, tap + 0.012) - floor
            XCTAssertGreaterThanOrEqual(rise, k == 0 ? 3 : 1.5, "the wall's echo at \(Int(tap * 1000)) ms stands \(rise) dB over the bed between them")
        }
        XCTAssertGreaterThan(DSPTestKit.dBFS(SynthRender.slice(Self.bandpass(m, 600, 4000), 5.5, 8.5)), -70, "its crackling tail")
        XCTAssertLessThan(max(DSPTestKit.peak(out.l), DSPTestKit.peak(out.r)), 0.6, "under the limiter")
    }

    /// The plume's thunder (spec §8.3): short, dry and close: posted 1.6 s late, 90% of its energy within 0.6 s of its
    /// arrival (storm thunder rolls for 2–8 s), and a real crack in it (at least 15% of its first 0.3 s at 600–4000 Hz, where
    /// the ear is keenest; the rest is its low knock). (Mirror, 24 seeds: within 0.27 s; 22–70%, median 50%.)
    func testPlumeThunderIsShortAndDry() {
        let out = Self.render(seconds: 6, actions: [Self.level(ISD_AMB_PLUME_THUNDER, 1), Self.post(ISD_AMB_PLUME_THUNDER, at: 1, delay: 1.6, strength: 0.8)])
        let m = Self.mid(out)
        let frames = Self.frameDB(m, ms: 5), top = frames.max() ?? -200
        let onset = Double(frames.firstIndex { $0 >= top - 40 } ?? 0) * 0.005
        XCTAssertEqual(onset, 2.6, accuracy: 0.05)
        let after = SynthRender.slice(m, onset, 6)
        var sum = 0.0, total = after.reduce(0.0) { $0 + Double($1) * Double($1) }, end = 0.0
        for (i, v) in after.enumerated() {
            sum += Double(v) * Double(v)
            if sum >= 0.9 * total { end = Double(i) / Self.sr; break }
        }
        XCTAssertLessThan(end, 0.6, "90% of it within \(end) s: no roll")
        // From 0.1 s before it, so the crack sits mid-window and is not lost under the window's edge.
        XCTAssertGreaterThanOrEqual(Self.bandShare(SynthRender.slice(m, onset - 0.1, onset + 0.3), 600, 4000), 0.15, "a crack")
    }

    /// A rockfall (spec §8.3): a big fall makes thirty impacts or more, thinning out as it goes (more in its first second
    /// than its third) and darkening as it goes farther down the wall (its centroid down by 15% from the first 0.8 s to
    /// 1.6–2.6 s on) and quieter (3 dB), with a dusty trickle after; a small one by itself every 45–150 s. (Mirror, 12
    /// seeds: 154–171 impacts, at least 116 in the first second and at most 19 in the third; the centroid down to 0.43–0.76
    /// of its start; 10.9 dB quieter or more.)
    func testRockfallSlowsAndDarkens() {
        var counts: [Int32] = []
        var actions: [Action] = [Self.level(ISD_AMB_ROCKFALL, 1), Self.post(ISD_AMB_ROCKFALL, at: 1, pan: -0.4, distance: 0.2)]
        for k in 0...8 { actions.append((1 + Double(k) * 0.5, { counts.append(isd_ambience_debug_events($0, ISD_AMB_ROCKFALL)) })) }
        let out = Self.render(seconds: 7, actions: actions)
        XCTAssertGreaterThanOrEqual(counts.last ?? 0, 30, "a big fall")
        let first = (counts[2] - counts[0]), third = (counts[6] - counts[4])
        XCTAssertGreaterThan(first, third, "slowing: \(first) impacts in its first second, \(third) in its third")
        let m = Self.mid(out)
        let early = DSPTestKit.averageCentroid(SynthRender.slice(m, 1, 1.8), sampleRate: Self.sr)
        let late = DSPTestKit.averageCentroid(SynthRender.slice(m, 2.6, 3.6), sampleRate: Self.sr)
        XCTAssertLessThan(late, 0.85 * early, "farther down, darker: \(Int(early)) → \(Int(late)) Hz")
        XCTAssertLessThan(DSPTestKit.dBFS(SynthRender.slice(m, 2.6, 3.6)), DSPTestKit.dBFS(SynthRender.slice(m, 1, 1.8)) - 3, "and quieter")
        var small: Int32 = -1
        _ = Self.render(seconds: 300, actions: [Self.level(ISD_AMB_ROCKFALL, 1), (299.9, { small = isd_ambience_debug_events($0, ISD_AMB_ROCKFALL) })])
        XCTAssertGreaterThan(small, 0, "small falls by themselves")
    }

    /// A steam blast (spec §8.3): a jet that builds (from nothing to its roar over 0.3–1.2 s, its band climbing), holds and
    /// fades out within 9 s, at least 75% of it at 800–9000 Hz. (Mirror: the roar 0.7 s in; 2614 → 3247 Hz.)
    func testSteamVentBuildsAndFades() {
        let out = Self.render(seconds: 11, actions: [Self.level(ISD_AMB_STEAM_VENT, 1), Self.post(ISD_AMB_STEAM_VENT, at: 1, pan: 0.3, distance: 0.2)])
        let m = Self.mid(out)
        let frames = Self.frameDB(m, ms: 100)
        let hold = frames[25...45].max() ?? -200   // 2.5–4.5 s
        let reached = Double((frames.firstIndex { $0 >= hold - 3 } ?? 0)) * 0.1 - 1
        XCTAssertTrue((0.3...1.2).contains(reached), "it builds: its roar \(reached) s in")
        let building = DSPTestKit.averageCentroid(SynthRender.slice(m, 1.05, 1.35), sampleRate: Self.sr)
        let roaring = DSPTestKit.averageCentroid(SynthRender.slice(m, 2.5, 4.5), sampleRate: Self.sr)
        XCTAssertGreaterThan(roaring, building, "the jet climbs with the pressure: \(Int(building)) → \(Int(roaring)) Hz")
        XCTAssertLessThan(DSPTestKit.dBFS(SynthRender.slice(m, 10, 11)), hold - 40, "and fades")
        XCTAssertGreaterThanOrEqual(Self.bandShare(SynthRender.slice(m, 1.5, 7), 800, 9000), 0.75)
    }

    /// The lava hiss (spec §8.3): never a frying hiss: its crackles are sparse (2–9 a second at the glow's middle, fewer
    /// when it is dark, more when it is bright), its roar sits low (the top octave at least 15 dB under 320–640 Hz), and the
    /// lake's glow brightens it (its centroid up by a third or more from dark to bright). (Mirror: 2.3, 6.8, 11.5 a second;
    /// 372 → 866 Hz.)
    func testLavaHissCracklesSparselyAndBrightensWithTheGlow() {
        func hiss(_ glow: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 23, actions: [Self.level(ISD_AMB_LAVA_HISS, 1), Self.lake(surge: 0.3, glow: glow),
                                                         (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_LAVA_HISS)) }),
                                                         (22.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_LAVA_HISS)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 20 : -1)
        }
        let dark = hiss(0), middle = hiss(0.5), bright = hiss(1)
        XCTAssertTrue((2...9).contains(middle.perSecond), "\(middle.perSecond) crackles a second")
        XCTAssertLessThan(dark.perSecond, middle.perSecond)
        XCTAssertGreaterThan(bright.perSecond, middle.perSecond)
        XCTAssertLessThanOrEqual(bright.perSecond, 16, "still sparse when bright")
        let m = SynthRender.slice(Self.mid(middle.out), 3, 23)
        XCTAssertGreaterThanOrEqual(Self.bandDB(m, 320, 640) - Self.bandDB(m, 5000, 10000), 15, "a roar, not white noise")
        let cDark = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(dark.out), 3, 23), sampleRate: Self.sr)
        let cBright = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(bright.out), 3, 23), sampleRate: Self.sr)
        XCTAssertGreaterThan(cBright, 1.33 * cDark, "the glow brightens it: \(Int(cDark)) → \(Int(cBright)) Hz")
    }

    /// Wet tyres (spec §9.3): at 130 km/h at least 6 dB louder and brighter than at 66; the spray (3–8 kHz) at least 6 dB
    /// up on a wet road over a dry one; the deck joints at the speed's rate over their 36–60 m (within 15%). (Mirror: 0.750,
    /// 0.500, 0.283 a second against 0.752, 0.521, 0.289.)
    func testWetTyresFollowTheSpeed() {
        let jobs: [(seconds: Double, actions: [Action])] = [
            (13, [Self.level(ISD_AMB_WET_TYRES, 1), Self.speed(0.2), Self.wetness(0.8)]),
            (13, [Self.level(ISD_AMB_WET_TYRES, 1), Self.speed(1), Self.wetness(0.8)]),
            (13, [Self.level(ISD_AMB_WET_TYRES, 1), Self.speed(1), Self.wetness(0)]),
        ]
        let r = Self.renderAll(jobs)
        let slow = SynthRender.slice(Self.mid(r[0]), 3, 13), fast = SynthRender.slice(Self.mid(r[1]), 3, 13), dry = SynthRender.slice(Self.mid(r[2]), 3, 13)
        XCTAssertGreaterThanOrEqual(DSPTestKit.dBFS(fast) - DSPTestKit.dBFS(slow), 6)
        XCTAssertGreaterThan(DSPTestKit.averageCentroid(fast, sampleRate: Self.sr), DSPTestKit.averageCentroid(slow, sampleRate: Self.sr))
        XCTAssertGreaterThanOrEqual(Self.bandDB(fast, 3000, 8000) - Self.bandDB(dry, 3000, 8000), 6, "the spray")
        for speed: Float in [0, 1] {
            var counts: [Int32] = []
            _ = Self.render(seconds: 63, actions: [Self.level(ISD_AMB_WET_TYRES, 1), Self.speed(speed),
                                                   (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_WET_TYRES)) }),
                                                   (62.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_WET_TYRES)) })])
            let perSecond = counts.count == 2 ? Double(counts[1] - counts[0]) / 60 : -1
            let law = Double(50 + 80 * speed) / 3.6 / 48
            XCTAssertEqual(perSecond, law, accuracy: 0.15 * law, "speed \(speed): \(perSecond) joints a second")
        }
    }

    /// The wipers (spec §9.3): a sweep of 1.2 s thunks at its top (0.6 s) and at rest (1.2 s), within 30 ms each; the
    /// swish follows the blade (mid-stroke at least 6 dB over its ends); on a drying screen the rubber squeaks (the
    /// blade's resonance, 1.2–1.5 kHz, stands at least 3 dB further over the swish than on a wet one); subtle (peaks under
    /// −15 dBFS at level 1). (Mirror, 16 seeds: the thunks within 10 ms; the squeak 3.7–8 dB further over; peaks −24 to
    /// −17.6 dBFS.)
    func testWipersSweepSqueakAndThunk() {
        func sweep(_ wet: Float) -> [Float] {
            Self.mid(Self.render(seconds: 3.5, actions: [Self.level(ISD_AMB_WIPERS, 1), Self.post(ISD_AMB_WIPERS, at: 1, strength: wet, speed: 1.2)]))
        }
        let wet = sweep(0.9), dry = sweep(0.1)
        let low = Self.frameDB(Self.bandpass(wet, 60, 250), ms: 10)
        for at in [1.6, 2.2] {
            let i = Int(at * 100)
            let peak = (i - 6...i + 6).max { low[$0] < low[$1] } ?? 0
            XCTAssertEqual(Double(peak) * 0.01, at, accuracy: 0.03, "a thunk at \(at) s")
        }
        let swish = Self.bandpass(wet, 1500, 4000)
        let middle = DSPTestKit.dBFS(SynthRender.slice(swish, 1.25, 1.35)), end = DSPTestKit.dBFS(SynthRender.slice(swish, 1.57, 1.63))
        XCTAssertGreaterThanOrEqual(middle - end, 6, "the swish follows the blade")
        func squeak(_ x: [Float]) -> Double { Self.bandDB(SynthRender.slice(x, 1, 2.2), 1200, 1500) - Self.bandDB(SynthRender.slice(x, 1, 2.2), 2500, 4000) }
        XCTAssertGreaterThanOrEqual(squeak(dry) - squeak(wet), 3, "the rubber squeaks as the glass dries")
        XCTAssertLessThan(20 * log10(Double(max(DSPTestKit.peak(wet), DSPTestKit.peak(dry)))), -15, "subtle")
    }

    /// Roof rain (spec §9.3): the rain synthesis through a car's cabin: muffled (its centroid under half the rain on the
    /// glass's), heavier rain more drops (at 0.3 under half the drops of a downpour), and when the rain stops (under a
    /// bridge, its level to nothing) the drops stop within half a second.
    func testRoofRainIsTheRainThroughTheCabin() {
        func drops(_ level: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 13, actions: [Self.level(ISD_AMB_ROOF_RAIN, level),
                                                         (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_ROOF_RAIN)) }),
                                                         (12.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_ROOF_RAIN)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 10 : -1)
        }
        let heavy = drops(1), light = drops(0.3)
        let glass = Self.render(seconds: 13, actions: [Self.level(ISD_AMB_RAIN_GLASS, 1)])
        let roof = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(heavy.out), 3, 13), sampleRate: Self.sr)
        let onGlass = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(glass), 3, 13), sampleRate: Self.sr)
        XCTAssertLessThan(roof, 0.5 * onGlass, "muffled: \(Int(roof)) Hz against the glass's \(Int(onGlass)) Hz")
        XCTAssertGreaterThan(light.perSecond, 0)
        XCTAssertLessThan(light.perSecond, 0.5 * heavy.perSecond, "\(light.perSecond) against \(heavy.perSecond) drops a second")
        var counts: [Int32] = []
        var actions: [Action] = [Self.level(ISD_AMB_ROOF_RAIN, 1), Self.level(ISD_AMB_ROOF_RAIN, 0, at: 5)]
        for k in 0..<20 { actions.append((5 + Double(k) * 0.1, { counts.append(isd_ambience_debug_events($0, ISD_AMB_ROOF_RAIN)) })) }
        _ = Self.render(seconds: 7.1, actions: actions)
        XCTAssertEqual(counts[19], counts[5], "under the bridge the drops stop within half a second (\(counts))")
    }

    /// One-shots and a world switch or a panic (plan Task 10, Storms Review focus 4): one waiting is dropped by a switch
    /// (isd_ambience_clear_thunder) and by a panic, and never heard while its source is silent; a panic fades a sounding
    /// boom, its echoes too (at least 8 dB down in the half second after and 16 dB in the second after that, the shared
    /// room's tail ringing out) but the drive's car passing carries on; a clear drops only what was posted before it.
    /// (Mirror: 1 0 0 0 0 1; 10.9 and 20.9 dB down; the car within 0.01 dB.)
    func testOneShotsAreDroppedBySwitchAndPanic() {
        func booms(_ actions: [Action], seconds: Double) -> Int32 {
            var n: Int32 = -1
            _ = Self.render(seconds: seconds, actions: actions + [(seconds - 0.01, { n = isd_ambience_debug_events($0, ISD_AMB_ERUPTION_BOOM) })])
            return n
        }
        let up = Self.level(ISD_AMB_ERUPTION_BOOM, 1)
        XCTAssertEqual(booms([up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5, delay: 2)], seconds: 4), 1)
        XCTAssertEqual(booms([up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5, delay: 2), Self.clearThunder(at: 1)], seconds: 4), 0, "a world switch")
        XCTAssertEqual(booms([up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5, delay: 2), Self.allSoundOff(at: 1)], seconds: 4), 0, "a panic")
        XCTAssertEqual(booms([Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5)], seconds: 3), 0, "silent: never heard")
        XCTAssertEqual(booms([up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5, delay: 2), Self.level(ISD_AMB_ERUPTION_BOOM, 0, at: 1)], seconds: 4), 0,
                       "the world's boom going: nothing on its way arrives")
        XCTAssertEqual(booms([up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5, delay: 2), Self.clearThunder(at: 1),
                              Self.post(ISD_AMB_ERUPTION_BOOM, at: 1.001, delay: 0.5)], seconds: 4), 1, "a clear drops only what came before it")
        let boom: [Action] = [up, Self.post(ISD_AMB_ERUPTION_BOOM, at: 0.5)]
        let kept = Self.mid(Self.render(seconds: 3, actions: boom)), cut = Self.mid(Self.render(seconds: 3, actions: boom + [Self.allSoundOff(at: 1.5)]))
        let soon = DSPTestKit.dBFS(SynthRender.slice(kept, 1.55, 2)) - DSPTestKit.dBFS(SynthRender.slice(cut, 1.55, 2))
        let later = DSPTestKit.dBFS(SynthRender.slice(kept, 2, 3)) - DSPTestKit.dBFS(SynthRender.slice(cut, 2, 3))
        XCTAssertGreaterThanOrEqual(soon, 8, "a panic fades the boom: \(soon) dB down in the half second after")
        XCTAssertGreaterThanOrEqual(later, 16, "and \(later) dB down after that (the room's tail ringing out)")
        let car: [Action] = [Self.level(ISD_AMB_DRIVE_PASSING_CAR, 1), Self.post(ISD_AMB_DRIVE_PASSING_CAR, at: 0.5, delay: 2, pan: 1, speed: 30, distance: 4)]
        let driving = Self.mid(Self.render(seconds: 4, actions: car)), panicked = Self.mid(Self.render(seconds: 4, actions: car + [Self.allSoundOff(at: 2)]))
        XCTAssertEqual(DSPTestKit.dBFS(SynthRender.slice(panicked, 2.3, 3)), DSPTestKit.dBFS(SynthRender.slice(driving, 2.3, 3)), accuracy: 0.5,
                       "the car passing carries on")
    }
}
