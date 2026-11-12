import XCTest
import InStrumCore
import InStrumDSP

/// Ambience generators through the C API.
final class AmbienceTests: XCTestCase {
    static let sr = DSPTestKit.sampleRate
    typealias Action = (time: Double, apply: (OpaquePointer) -> Void)

    /// Renders `seconds` of ambience; `actions` run at the start of the block containing their time.
    static func render(seconds: Double, seed: UInt64 = 1, block: Int = 256, actions: [Action]) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(sr, Int32(block), seed) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        let total = Int(seconds * sr)
        var left = [Float](repeating: 0, count: total), right = [Float](repeating: 0, count: total)
        let pending = actions.sorted { $0.time < $1.time }
        var next = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while next < pending.count, Int(pending[next].time * sr) < i + n { pending[next].apply(a); next += 1 }
            left.withUnsafeMutableBufferPointer { lp in
                right.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (left, right)
    }

    /// Renders several ambiences side by side (each its own instance, so they share nothing), in the jobs' order: the
    /// long renders were most of the suite's time in series.
    static func renderAll(_ jobs: [(seconds: Double, actions: [Action])]) -> [(l: [Float], r: [Float])] {
        var out = [(l: [Float], r: [Float])](repeating: ([], []), count: jobs.count)
        out.withUnsafeMutableBufferPointer { slots in
            let base = slots.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                base[k] = render(seconds: jobs[k].seconds, actions: jobs[k].actions)
            }
        }
        return out
    }

    static func level(_ s: ISDAmbienceSource, _ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_level($0, s, v) }) }
    static func wave(_ strength: Float, at t: Double) -> Action { (t, { isd_ambience_trigger_wave($0, strength) }) }
    static func speed(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_speed($0, v) }) }
    static func surfDistance(_ d: Float) -> Action { (0, { isd_ambience_set_surf_distance($0, d) }) }
    static func density(_ d: Float) -> Action { (0, { isd_ambience_set_density($0, d) }) }

    /// Share of the energy between `lo` and `hi` (Welch average of 8192-sample segments).
    static func bandShare(_ x: [Float], _ lo: Double, _ hi: Double) -> Double {
        let n = 8192
        var power = [Double](repeating: 0, count: n / 2)
        var start = 0
        while start + n <= x.count {
            let p = DSPTestKit.powerSpectrum(Array(x[start..<(start + n)]), size: n)
            for i in 0..<min(power.count, p.count) { power[i] += p[i] }
            start += n / 2
        }
        let binHz = sr / Double(n)
        var inBand = 0.0, total = 0.0
        for i in 1..<power.count {
            total += power[i]
            let f = Double(i) * binHz
            if f >= lo && f <= hi { inBand += power[i] }
        }
        return total > 0 ? inBand / total : 0
    }

    /// RMS of each 0.5 s window, in dBFS.
    static func windows(_ x: [Float], seconds: Double = 0.5) -> [Double] {
        let n = Int(seconds * sr)
        return stride(from: 0, to: x.count - n + 1, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    func testEachSourceInItsBand() {
        let bands: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_WATER, "water", 150...1500, -30 ... -18),
            (ISD_AMB_CRICKETS, "crickets", 3500...6500, -36 ... -18),
            (ISD_AMB_BREEZE, "breeze", 200...2000, -30 ... -18),
            (ISD_AMB_RAIN_WATER, "rain on water", 800...4000, -30 ... -18),
            (ISD_AMB_RAIN_GLASS, "rain on glass", 1500...12000, -30 ... -18),
            (ISD_AMB_DAWN_CHORUS, "dawn chorus", 2000...6500, -36 ... -18),
            (ISD_AMB_SHIP_HUM, "ship hum", 20...250, -30 ... -18),
            (ISD_AMB_AIR_FLOW, "air flow", 300...3000, -30 ... -18),
            (ISD_AMB_WIND, "wind", 100...1500, -30 ... -18),
        ]
        for (source, name, band, loudness) in bands {
            let out = Self.render(seconds: 20, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 20)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
        }
    }

    /// The beach's and the road's sources, each in its own band (density up so rare ones happen).
    func testNewSourcesInTheirBands() {
        let table: [(ISDAmbienceSource, String, ClosedRange<Double>, Float, Bool, Double)] = [
            (ISD_AMB_SURF, "surf", 60...6000, 0, true, 30),
            (ISD_AMB_PALMS, "palms", 1500...9000, 0, false, 30),
            (ISD_AMB_GULLS, "gulls", 500...3500, 0, false, 60),
            (ISD_AMB_ROAD, "road", 30...1200, 0.6, false, 30),
            (ISD_AMB_ENGINE, "engine", 25...250, 0.6, false, 30),
            (ISD_AMB_WINDOW_WIND, "window wind", 300...4000, 0.8, false, 30),
            (ISD_AMB_PASSING_CAR, "passing car", 80...3000, 0, false, 120),
        ]
        var jobs: [(seconds: Double, actions: [Action])] = []
        for (source, _, _, speed, waves, seconds) in table {
            var actions: [Action] = [Self.level(source, 1), Self.density(1.5), Self.speed(speed)]
            if waves { for t in stride(from: 1.0, to: seconds, by: 9) { actions.append(Self.wave(0.7, at: t)) } }
            jobs.append((seconds: seconds, actions: actions))
        }
        let rendered = Self.renderAll(jobs)
        for (k, row) in table.enumerated() {
            let name = row.1, band = row.2, seconds = row.5
            let out = rendered[k]
            let body = SynthRender.slice(out.l, 3, seconds)
            XCTAssertGreaterThan(Self.bandShare(body, band.lowerBound, band.upperBound), 0.5, name)
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertGreaterThan(Self.windows(body).max() ?? -200, -60, "\(name) is heard")
        }
        // The night skies: a far waterfall and lapping water at their levels; the ice's creak bed stays faint.
        let skies: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_WATERFALL, "waterfall", 300...2500, -32 ... -18),
            (ISD_AMB_LAPPING, "lapping", 300...3000, -40 ... -22),
        ]
        for (source, name, band, loudness) in skies {
            let out = Self.render(seconds: 20, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 20)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
        }
        let ice = Self.render(seconds: 20, actions: [Self.level(ISD_AMB_ICE_GROAN, 1)])
        let bed = Self.windows(SynthRender.slice(ice.l, 3, 20)).sorted()
        XCTAssertLessThan(bed[bed.count / 2], -30, "the ice's creak bed")
        XCTAssertGreaterThan(bed[bed.count / 2], -60, "the ice's creak bed is heard")
        XCTAssertTrue(ice.l.allSatisfy(\.isFinite) && ice.r.allSatisfy(\.isFinite), "ice")
        XCTAssertLessThanOrEqual(max(ice.l.map(abs).max() ?? 0, ice.r.map(abs).max() ?? 0), 1, "ice")
        // The still places: the temple bell low, its strike's first 2 s near −30 dBFS; the water-knocker's trickle in
        // 2–4.5 kHz (its clack: testWaterKnockerCycle); the warbler in 2–4.5 kHz, peaking near −20 dBFS (the paper
        // screens: testPaperScreensRustle). Levels on both channels: these sources are panned.
        let bell = Self.render(seconds: 8, actions: [Self.level(ISD_AMB_TEMPLE_BELL, 1), Self.strikeBell(at: 3)])
        let bellCentroid = DSPTestKit.averageCentroid(SynthRender.slice(bell.l, 3, 8), sampleRate: Self.sr), bellDB = Self.stereoDB(bell, 3, 5)
        XCTAssertTrue((60...400).contains(bellCentroid), "temple bell: centroid \(Int(bellCentroid)) Hz")
        XCTAssertTrue((-34 ... -26).contains(bellDB), "temple bell: \(String(format: "%.1f", bellDB)) dBFS over the strike's first 2 s")
        let trickle = Self.render(seconds: 14, actions: [Self.level(ISD_AMB_WATER_KNOCKER, 1), Self.startKnocker(at: 3)])
        XCTAssertGreaterThan(Self.bandShare(SynthRender.slice(trickle.l, 4, 14), 2000, 4500), 0.6, "the knocker's trickle")
        XCTAssertGreaterThan(Self.windows(SynthRender.slice(trickle.l, 4, 14)).max() ?? -200, -65, "the trickle is heard")
        let call = Self.render(seconds: 5, actions: [Self.level(ISD_AMB_WARBLER, 1), Self.callWarbler(at: 3.2)])
        let callPeak = Self.peakDB(call, 0, 5)
        XCTAssertGreaterThan(Self.bandShare(SynthRender.slice(call.l, 3.2, 4.4), 2000, 4500), 0.9, "warbler")
        XCTAssertTrue((-26 ... -14).contains(callPeak), "warbler: peak \(String(format: "%.1f", callPeak)) dBFS")
        for (name, out) in [("temple bell", bell), ("water-knocker", trickle), ("warbler", call)] {
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
        // Deep water: the hull's groans low (its 60–250 Hz resonances) near −30 dBFS, its metal ticks rare; the sonar on
        // its tone; the whale, the bubbles, the shrimp and the fish each around their band (each has its own test too).
        let hull = Self.render(seconds: 30, actions: [Self.level(ISD_AMB_HULL_CREAK, 1), Self.density(1.5)])
        let hullBody = SynthRender.slice(Self.mid(hull), 3, 30)
        let hullCentroid = DSPTestKit.averageCentroid(hullBody, sampleRate: Self.sr)
        XCTAssertTrue((50...300).contains(hullCentroid), "hull creak: centroid \(Int(hullCentroid)) Hz")
        XCTAssertGreaterThan(Self.bandShare(hullBody, 40, 300), 0.8, "the hull's groans")
        let groan = Self.stereoFrames(hull, ms: 500, from: 3, to: 30).max() ?? -200
        XCTAssertTrue((-34 ... -22).contains(groan), "hull creak: its loudest half second at \(groan) dBFS")
        var deep: [(String, (l: [Float], r: [Float]))] = [("hull creak", hull)]
        let bands: [(ISDAmbienceSource, String, [Action], ClosedRange<Double>)] = [
            (ISD_AMB_SONAR, "sonar", [Self.pingSonar(at: 3)], 1200...1450),
            (ISD_AMB_WHALE, "whale", [Self.startWhale(at: 3)], 100...2000),
            (ISD_AMB_BUBBLES, "bubbles", [Self.bubbles(0.5, at: 3)], 1200...6000),
            (ISD_AMB_SHRIMP, "shrimp", [], 3000...12000),
            (ISD_AMB_FISH_CHORUS, "fish chorus", [], 150...600),
        ]
        for (source, name, extra, band) in bands {
            let out = Self.render(seconds: 8, actions: [Self.level(source, 1)] + extra)
            let centroid = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(out), 3, 8), sampleRate: Self.sr)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            deep.append((name, out))
        }
        for (name, out) in deep {
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
        // Storms: the storm and plains families.
        checkStormSourcesInTheirBands()
    }

    /// A wave breaks: a low crash first, then the bright wash sliding up the sand.
    func testWaveMakesACrashThenAWash() {
        let out = Self.render(seconds: 6.5, actions: [Self.level(ISD_AMB_SURF, 1), Self.wave(1, at: 3.0)])
        let before = DSPTestKit.dBFS(SynthRender.slice(out.l, 2.6, 2.95)), after = DSPTestKit.dBFS(SynthRender.slice(out.l, 3.0, 3.6))
        XCTAssertGreaterThan(after, before + 6)
        var lowPeak = (time: 0.0, e: -1.0), highPeak = (time: 0.0, e: -1.0)
        for t in stride(from: 3.0, to: 6.0, by: 0.05) {
            let seg = SynthRender.slice(out.l, t, t + 0.05)
            let lo = DSPTestKit.bandEnergy(seg, sampleRate: Self.sr, from: 20, to: 300)
            let hi = DSPTestKit.bandEnergy(seg, sampleRate: Self.sr, from: 3000, to: 20000)
            if lo > lowPeak.e { lowPeak = (t, lo) }
            if hi > highPeak.e { highPeak = (t, hi) }
        }
        XCTAssertLessThan(lowPeak.time, highPeak.time, "crash at \(lowPeak.time) s, wash at \(highPeak.time) s")
    }

    /// A wave that arrives while the surf is fading out (the world is changing) makes no crash.
    func testWaveIgnoredWhileSurfFadesOut() {
        let base: [Action] = [Self.level(ISD_AMB_SURF, 1), Self.level(ISD_AMB_SURF, 0, at: 3.0)]
        let quiet = Self.render(seconds: 4.5, actions: base)
        let late = Self.render(seconds: 4.5, actions: base + [Self.wave(1, at: 3.1)])
        let a = DSPTestKit.dBFS(SynthRender.slice(quiet.l, 3.1, 4.5)), b = DSPTestKit.dBFS(SynthRender.slice(late.l, 3.1, 4.5))
        XCTAssertLessThan(b - a, 0.5, "fading bed \(a) dBFS, with the late wave \(b) dBFS")
    }

    /// The engine's purr and a passing car's tone keep their pitch however long the drive: their oscillator
    /// (shared helper) runs at exactly the frequency asked, at every sample rate, after 30 s and after 10 minutes.
    func testToneOscillatorsHoldPitch() {
        for sr: Float in [44_100, 48_000, 96_000] {
            for hz: Float in [35, 42, 60, 70, 95] {
                for seconds: Float in [30, 600] {
                    let measured = Double(isd_ambience_debug_tone_hz(hz, sr, seconds))
                    XCTAssertEqual(DSPTestKit.cents(measured, Double(hz)), 0, accuracy: 0.5, "\(hz) Hz at \(Int(sr)) Hz over \(Int(seconds)) s")
                }
            }
        }
    }

    func testRoadFollowsSpeed() {
        let car: [Action] = [Self.level(ISD_AMB_ROAD, 1), Self.level(ISD_AMB_ENGINE, 1), Self.level(ISD_AMB_WINDOW_WIND, 1)]
        let slow = SynthRender.slice(Self.render(seconds: 10, actions: car + [Self.speed(0.2)]).l, 3, 10)
        let fast = SynthRender.slice(Self.render(seconds: 10, actions: car + [Self.speed(1)]).l, 3, 10)
        XCTAssertGreaterThan(DSPTestKit.dBFS(fast), DSPTestKit.dBFS(slow) + 6)
        XCTAssertGreaterThan(DSPTestKit.averageCentroid(fast, sampleRate: Self.sr), DSPTestKit.averageCentroid(slow, sampleRate: Self.sr))
    }

    func testFarSurfIsDarker() {
        func surf(_ d: Float) -> [Float] {
            var actions: [Action] = [Self.level(ISD_AMB_SURF, 1), Self.surfDistance(d)]
            for t in stride(from: 1.0, to: 20, by: 9) { actions.append(Self.wave(0.8, at: t)) }
            return SynthRender.slice(Self.render(seconds: 20, actions: actions).l, 3, 20)
        }
        let near = DSPTestKit.averageCentroid(surf(0), sampleRate: Self.sr), far = DSPTestKit.averageCentroid(surf(1), sampleRate: Self.sr)
        XCTAssertLessThan(far, 0.6 * near, "near \(Int(near)) Hz, far \(Int(far)) Hz")
    }

    /// Owl, chime and hull ticks are rare: at least one event in 300 s, silent most of the time.
    func testRareEventsHappen() {
        let rows = [(ISD_AMB_OWL, "owl"), (ISD_AMB_CHIME, "chime"), (ISD_AMB_HULL_TICKS, "hull ticks")]
        var jobs: [(seconds: Double, actions: [Action])] = []
        for row in rows { jobs.append((seconds: 300, actions: [Self.level(row.0, 1)])) }
        let rendered = Self.renderAll(jobs)
        for (k, row) in rows.enumerated() {
            let name = row.1
            let out = rendered[k]
            let w = Self.windows(out.l)
            let loud = w.filter { $0 > -60 }.count
            XCTAssertGreaterThanOrEqual(loud, 1, "\(name): no event in 300 s")
            XCTAssertLessThan(Double(loud) / Double(w.count), 0.25, "\(name) is not rare")
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }

    func testLevelsCrossFade() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_WATER, 1)])
        let early = DSPTestKit.dBFS(SynthRender.slice(out.l, 0.4, 0.5)), steady = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 12))
        XCTAssertLessThan(early, steady - 6, "early \(early) steady \(steady)")
        XCTAssertGreaterThan(steady, -40)
        // A level that stepped instead of gliding would click in the fade's first second. (Steady water at
        // −24 dBFS has natural sample steps up to about 0.06, so the whole render is checked for clicks only.)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.l, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(SynthRender.slice(out.r, 0, 1)), 0.05)
        XCTAssertLessThan(DSPTestKit.maxJump(out.l), 0.15)
    }

    func testDucking() {
        let out = Self.render(seconds: 12, actions: [Self.level(ISD_AMB_AIR_FLOW, 1),
                                                     (5, { isd_ambience_set_activity($0, 1) }),
                                                     (8, { isd_ambience_set_activity($0, 0) })])
        let before = DSPTestKit.dBFS(SynthRender.slice(out.l, 4, 5))
        let ducked = DSPTestKit.dBFS(SynthRender.slice(out.l, 5.5, 6))
        let back = DSPTestKit.dBFS(SynthRender.slice(out.l, 11, 12))
        XCTAssertGreaterThan(before - ducked, 3, "ducked \(before - ducked) dB")
        XCTAssertLessThan(before - ducked, 5, "ducked \(before - ducked) dB")
        XCTAssertEqual(back, before, accuracy: 1)
    }

    func testThunderFollowsLightning() {
        let bed: [Action] = [Self.level(ISD_AMB_RAIN_WATER, 0.5)]
        let quiet = Self.render(seconds: 12, actions: bed)
        let storm = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.5) })])
        let low = { (x: [Float]) in DSPTestKit.bandEnergy(SynthRender.slice(x, 4, 11), sampleRate: Self.sr, from: 20, to: 200) }
        XCTAssertGreaterThan(10 * log10(low(storm.l) / max(low(quiet.l), 1e-12)), 6)
        let beforeStrike = DSPTestKit.dBFS(SynthRender.slice(storm.l, 3, 3.4)) - DSPTestKit.dBFS(SynthRender.slice(quiet.l, 3, 3.4))
        XCTAssertEqual(beforeStrike, 0, accuracy: 1, "thunder waits for the distance delay")
        // A clap is a rumble under the beds, never a full-scale slab: peak well under the limiter, and the
        // first second of the roll between −32 and −12 dBFS (bed at this rain level ≈ −32 dBFS).
        let strike = 3 + 0.5 + 5.5 * 0.5
        XCTAssertLessThan(storm.l.map(abs).max() ?? 1, 0.7, "thunder must not pin the limiter")
        let roll = DSPTestKit.dBFS(SynthRender.slice(storm.l, strike, strike + 1))
        XCTAssertGreaterThan(roll, -32); XCTAssertLessThan(roll, -12)
        // Distance is audible: a near clap is clearly louder than a far one.
        let near = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.1) })])
        let far = Self.render(seconds: 12, actions: bed + [(3, { isd_ambience_trigger_thunder($0, 0.9) })])
        let nearDb = DSPTestKit.dBFS(SynthRender.slice(near.l, 3 + 0.5 + 0.55, 3 + 0.5 + 0.55 + 1))
        let farDb = DSPTestKit.dBFS(SynthRender.slice(far.l, 3 + 0.5 + 4.95, 3 + 0.5 + 4.95 + 1))
        XCTAssertGreaterThan(nearDb - farDb, 5, "near \(nearDb) dBFS vs far \(farDb) dBFS")
    }

    func testClosenessChangesTheRoom() {
        let near = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 1) })])
        let far = Self.render(seconds: 10, actions: [Self.level(ISD_AMB_WATER, 1), (0, { isd_ambience_set_closeness($0, 0) })])
        let c = { (x: [Float]) in DSPTestKit.averageCentroid(SynthRender.slice(x, 3, 10), sampleRate: Self.sr) }
        XCTAssertGreaterThan(c(near.l), c(far.l), "distant ambience loses its top")
        XCTAssertTrue(far.l.allSatisfy(\.isFinite))
    }

    func testSilentByDefault() {
        let out = Self.render(seconds: 1, actions: [])
        XCTAssertLessThan(DSPTestKit.dBFS(out.l), -150)
    }
}

// MARK: - Window worlds: fire, kettle, street, drips, clock; through the glass; wet roads; snow ticks

extension AmbienceTests {
    static func indoors(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_indoors($0, v) }) }
    static func wetness(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_wetness($0, v) }) }
    static func snowOnGlass(_ v: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_snow_on_glass($0, v) }) }
    static func startKettle(at t: Double) -> Action { (t, { isd_ambience_debug_start_kettle($0) }) }

    static func mid(_ out: (l: [Float], r: [Float])) -> [Float] { zip(out.l, out.r).map { 0.5 * ($0 + $1) } }

    /// An RBJ band-pass, run twice (−24 dB/octave skirts).
    static func bandpass(_ x: [Float], _ lo: Double, _ hi: Double) -> [Float] {
        let f0 = (lo * hi).squareRoot(), bw = log2(hi / lo), w0 = 2 * Double.pi * f0 / sr
        let alpha = sin(w0) * sinh(log(2) / 2 * bw * w0 / sin(w0)), a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var y = x
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in y.indices {
                let xi = Double(y[i])
                let yi = b0 * xi + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi
                y[i] = Float(yi)
            }
        }
        return y
    }

    /// RMS (dBFS) of consecutive frames of `ms` milliseconds.
    static func frameDB(_ x: [Float], ms: Double) -> [Double] {
        let n = Int(ms / 1000 * sr)
        return stride(from: 0, to: x.count - n + 1, by: n).map { DSPTestKit.dBFS(x[$0..<($0 + n)]) }
    }

    /// How many times the frames rise `db` above the median of the `window` frames around them.
    static func events(_ frames: [Double], above db: Double, window: Int) -> Int {
        var count = 0, on = false
        for i in frames.indices {
            let lo = max(0, i - window / 2), hi = min(frames.count, i + window / 2)
            let sorted = frames[lo..<hi].sorted()
            let hit = frames[i] - sorted[sorted.count / 2] >= db
            if hit && !on { count += 1 }
            on = hit
        }
        return count
    }

    static func bandDB(_ x: [Float], _ lo: Double, _ hi: Double) -> Double { DSPTestKit.dBFS(bandpass(x, lo, hi)) }

    func testWindowSourcesInTheirBands() {
        let bands: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>)] = [
            (ISD_AMB_FIRE, "fire", 300...4000, -36 ... -18),
            (ISD_AMB_STREET, "street", 100...1500, -42 ... -22),
            (ISD_AMB_DRIPS, "drips", 800...4000, -45 ... -20),
        ]
        for (source, name, band, loudness) in bands {
            let out = Self.render(seconds: 23, actions: [Self.level(source, 1)])
            let steady = SynthRender.slice(out.l, 3, 23)
            let centroid = DSPTestKit.averageCentroid(steady, sampleRate: Self.sr), db = DSPTestKit.dBFS(steady)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }

    func testFireCracklesAndPops() {
        let fire = SynthRender.slice(Self.mid(Self.render(seconds: 33, actions: [Self.level(ISD_AMB_FIRE, 1)])), 3, 33)
        let crackles = Double(Self.events(Self.frameDB(fire, ms: 5), above: 12, window: 40)) / 30
        XCTAssertTrue((1...12).contains(crackles), "\(crackles) crackles a second")
        let thumps = Double(Self.events(Self.frameDB(Self.bandpass(fire, 60, 150), ms: 20), above: 10, window: 100)) / 30
        XCTAssertTrue((0.05...1).contains(thumps), "\(thumps) low thumps a second")
    }

    func testKettleCycle() {
        let out = Self.render(seconds: 150, actions: [Self.level(ISD_AMB_KETTLE, 1), Self.startKettle(at: 0)]).l
        let cold = Self.bandDB(SynthRender.slice(out, 0, 10), 60, 400), hot = Self.bandDB(SynthRender.slice(out, 80, 90), 60, 400)
        XCTAssertGreaterThanOrEqual(hot, cold + 6, "the rumble rises: \(cold) → \(hot) dB")
        // The click: a broadband transient (high band, 10 dB over the 200 ms before it) within 100–125 s.
        let high = Self.frameDB(Self.bandpass(SynthRender.slice(out, 99, 126), 2000, 16000), ms: 5)
        var click: Double?
        for i in 40..<high.count {
            let before = high[(i - 40)..<i].sorted()
            if high[i] - before[20] >= 10 { click = 99 + Double(i) * 0.005; break }
        }
        let clickAt = try? XCTUnwrap(click, "no click")
        XCTAssertTrue((100...125).contains(clickAt ?? 0), "click at \(clickAt ?? -1) s")
        // Then the clink: a 2.5–7 kHz ping more than 2 s later, far above that band before the click.
        let from = (clickAt ?? 100) + 2
        let ping = Self.frameDB(Self.bandpass(SynthRender.slice(out, from, 125), 2500, 7000), ms: 20)
        let peak = ping.max() ?? -200, quiet = Self.bandDB(SynthRender.slice(out, 99, 99.9), 2500, 7000)
        XCTAssertGreaterThanOrEqual(peak, quiet + 20, "clink \(peak) dB against \(quiet) dB")
        XCTAssertGreaterThan(peak, -60)
        // And back to quiet.
        XCTAssertLessThanOrEqual(DSPTestKit.dBFS(SynthRender.slice(out, 140, 150)), DSPTestKit.dBFS(SynthRender.slice(out, 0, 10)) + 3)
    }

    func testKettleComesEveryFewMinutes() {
        let out = Self.render(seconds: 600, actions: [Self.level(ISD_AMB_KETTLE, 1), Self.density(1.5)]).l
        let windows = stride(from: 0.0, to: 600, by: 10).map { Self.bandDB(SynthRender.slice(out, $0, $0 + 10), 60, 400) }
        let median = windows.sorted()[windows.count / 2]
        var cycles = 0, on = false
        for w in windows {
            let hit = w > median + 10
            if hit && !on { cycles += 1 }
            on = hit
        }
        XCTAssertTrue((2...4).contains(cycles), "\(cycles) kettle cycles in 10 minutes")
    }

    func testClockTicksAtOneHertz() {
        let out = SynthRender.slice(Self.render(seconds: 22, actions: [Self.level(ISD_AMB_CLOCK, 1)]).l, 2, 20)
        let env = Self.frameDB(out, ms: 10).map { pow(10, $0 / 20) }
        var best = -1.0, bestLag = 0
        for lag in 50...150 {
            var s = 0.0
            for i in 0..<(env.count - lag) { s += env[i] * env[i + lag] }
            if s > best { best = s; bestLag = lag }
        }
        XCTAssertEqual(Double(bestLag) * 0.01, 1.0, accuracy: 0.02)
    }

    func testIndoorsMufflesOnlyOutdoorSources() {
        let open = SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_STREET, 1)]).l, 4, 14)
        let closed = SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_STREET, 1), Self.indoors(1)]).l, 4, 14)
        XCTAssertGreaterThanOrEqual(Self.bandDB(open, 3000, 8000) - Self.bandDB(closed, 3000, 8000), 12)
        XCTAssertGreaterThanOrEqual(DSPTestKit.dBFS(open) - DSPTestKit.dBFS(closed), 6)
        let fire = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_FIRE, 1)]).l, 4, 14))
        let fireInside = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 14, actions: [Self.level(ISD_AMB_FIRE, 1), Self.indoors(1)]).l, 4, 14))
        XCTAssertEqual(fire, fireInside, accuracy: 0.5, "the fire is inside with you")
    }

    /// The waking street: the later the morning (the higher its level), the more often a car goes by (final review:
    /// only the loudness followed the level).
    func testStreetCarsComeMoreOftenLater() {
        func cars(_ level: Float) -> Int32 {
            guard let a = isd_ambience_create(Self.sr, 512, 7) else { return -1 }
            defer { isd_ambience_destroy(a) }
            isd_ambience_set_level(a, ISD_AMB_STREET, level)
            var l = [Float](repeating: 0, count: 512), r = l
            for _ in 0..<Int(300 * Self.sr / 512) {
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress!, rp.baseAddress!, 512) } }
            }
            return isd_ambience_debug_events(a, ISD_AMB_STREET)
        }
        let early = cars(0.15), late = cars(0.6)
        XCTAssertGreaterThanOrEqual(late, 2 * early, "\(early) cars early, \(late) later")
        XCTAssertGreaterThanOrEqual(late, 15)
    }

    /// The bedroom's old sash window (indoors 0.7) lets the dawn chorus through, softened (final review: behind the
    /// fully closed window the birds were 26 dB down).
    func testDawnChorusCarriesThroughTheSash() {
        let open = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 20, actions: [Self.level(ISD_AMB_DAWN_CHORUS, 0.6)]).l, 4, 20))
        let sash = DSPTestKit.dBFS(SynthRender.slice(Self.render(seconds: 20, actions: [Self.level(ISD_AMB_DAWN_CHORUS, 0.6), Self.indoors(0.7)]).l, 4, 20))
        XCTAssertGreaterThan(sash, open - 15)
        XCTAssertLessThan(sash, open - 4, "still through glass")
    }

    func testWetRoadHisses() {
        let dry = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_ROAD, 1), Self.speed(0.6)]).l, 3, 10)
        let wet = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_ROAD, 1), Self.speed(0.6), Self.wetness(1)]).l, 3, 10)
        XCTAssertGreaterThanOrEqual(Self.bandDB(wet, 4000, 10000) - Self.bandDB(dry, 4000, 10000), 6)
    }

    func testSnowTicksAreSofterThanRain() {
        let rain = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_RAIN_GLASS, 1)]).l, 3, 10)
        let snow = SynthRender.slice(Self.render(seconds: 10, actions: [Self.level(ISD_AMB_RAIN_GLASS, 1), Self.snowOnGlass(1)]).l, 3, 10)
        XCTAssertGreaterThanOrEqual(DSPTestKit.dBFS(rain) - DSPTestKit.dBFS(snow), 6)
        XCTAssertLessThan(DSPTestKit.averageCentroid(snow, sampleRate: Self.sr), DSPTestKit.averageCentroid(rain, sampleRate: Self.sr))
    }

    func testDripsFollowTheirLevel() {
        func drips(_ level: Float) -> Int {
            let x = SynthRender.slice(Self.mid(Self.render(seconds: 43, actions: [Self.level(ISD_AMB_DRIPS, level)])), 3, 43)
            return Self.events(Self.frameDB(x, ms: 5), above: 12, window: 40)
        }
        let few = drips(0.3), many = drips(1)
        XCTAssertGreaterThanOrEqual(Double(many), 2 * Double(few), "\(few) drips at 0.3, \(many) at 1")
        XCTAssertGreaterThan(few, 0)
    }
}

// MARK: - Night skies: ice, a waterfall, lapping water, a boat

extension AmbienceTests {
    static func startBoat(at t: Double) -> Action { (t, { isd_ambience_debug_start_boat($0) }) }

    /// The runs of frames that rise `db` above the median of the `window` frames around them: (first frame, length).
    static func swells(_ frames: [Double], above db: Double, window: Int) -> [(start: Int, length: Int)] {
        var runs: [(start: Int, length: Int)] = [], start = -1
        for i in frames.indices {
            let lo = max(0, i - window / 2), hi = min(frames.count, i + window / 2)
            let sorted = frames[lo..<hi].sorted()
            let hit = frames[i] - sorted[sorted.count / 2] >= db
            if hit && start < 0 { start = i }
            if !hit && start >= 0 { runs.append((start: start, length: i - start)); start = -1 }
        }
        if start >= 0 { runs.append((start: start, length: frames.count - start)) }
        return runs
    }

    /// Every 8th-sample average (a cheap 6 kHz copy for the low bands).
    static func decimate8(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count / 8)
        for i in y.indices {
            var s: Float = 0
            for k in 0..<8 { s += x[i * 8 + k] }
            y[i] = s / 8
        }
        return y
    }

    /// Over two minutes at density 1.5 the ice groans (40–120 Hz swells of 1–4 s, 8 dB over their surroundings) and
    /// cracks (5 ms broadband transients, 12 dB over the 200 ms around them).
    func testIceGroansAndCracks() {
        guard let a = isd_ambience_create(Self.sr, 512, 1) else { return XCTFail("no ambience") }
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_density(a, 1.5)
        isd_ambience_set_level(a, ISD_AMB_ICE_GROAN, 1)
        let total = Int(120 * Self.sr)
        var l = [Float](repeating: 0, count: total), r = l
        for i in stride(from: 0, to: total, by: 512) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(min(512, total - i))) } }
        }
        let started = isd_ambience_debug_events(a, ISD_AMB_ICE_GROAN)
        XCTAssertGreaterThanOrEqual(started, 5, "\(started) groans and cracks started")
        let mid = Self.mid((l: l, r: r))
        // Cracks: the sample-to-sample difference keeps the click and drops the groans and the bed.
        var diff = [Float](repeating: 0, count: mid.count)
        for i in 1..<mid.count { diff[i] = mid[i] - mid[i - 1] }
        let cracks = Self.events(Self.frameDB(diff, ms: 5), above: 12, window: 40)
        XCTAssertGreaterThanOrEqual(cracks, 3, "\(cracks) cracks in 120 s")
        // Heard, but not the loudest thing in the room: the cracks once peaked at 0.75 here (0.997 over half an hour);
        // at half the strength they still stand 28–35 dB over the 200 ms around them (the g++ mirror: 0.38).
        let peak = max(DSPTestKit.peak(l), DSPTestKit.peak(r))
        XCTAssertLessThan(peak, 0.5, "the loudest crack peaks at \(peak)")
        // Groans: the 40–120 Hz band (on a 6 kHz copy) in 250 ms frames, against the 20 s around them.
        let low = Self.decimate8(mid), lowSR = Self.sr / 8
        let f0 = (40.0 * 120).squareRoot(), w0 = 2 * Double.pi * f0 / lowSR
        // Typed steps, so the type checker never has to solve one long expression.
        let bw: Double = log2(120.0 / 40), halfLn2: Double = log(2) / 2
        let alpha: Double = sin(w0) * sinh(halfLn2 * bw * w0 / sin(w0)), a0: Double = 1 + alpha
        let b0: Double = alpha / a0, b2: Double = -alpha / a0
        let a1: Double = -2 * cos(w0) / a0, a2: Double = (1 - alpha) / a0
        var band = low.map(Double.init)
        for _ in 0..<2 {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in band.indices {
                let xi = band[i]
                let yi: Double = b0 * xi + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = xi; y2 = y1; y1 = yi; band[i] = yi
            }
        }
        let n = Int(0.25 * lowSR)
        let frames = stride(from: 0, to: band.count - n + 1, by: n).map { s -> Double in
            let e = band[s..<(s + n)].reduce(0.0) { $0 + $1 * $1 } / Double(n)
            return e > 0 ? 10 * log10(e) : -200
        }
        let groans = Self.swells(frames, above: 8, window: 80).filter { (2...18).contains($0.length) }   // 0.5–4.5 s
        XCTAssertGreaterThanOrEqual(groans.count, 2, "\(groans.count) groans in 120 s: \(groans.map { Double($0.length) * 0.25 }) s")
    }

    /// A boat passes: the 60–120 Hz band swells by more than 10 dB over 12–20 s while it crosses from one side to the other.
    func testBoatPasses() {
        let out = Self.render(seconds: 26, actions: [Self.level(ISD_AMB_BOAT, 1), Self.startBoat(at: 2)])
        let left = Self.frameDB(Self.bandpass(out.l, 60, 120), ms: 500), right = Self.frameDB(Self.bandpass(out.r, 60, 120), ms: 500)
        let both: [Double] = zip(left, right).map { (a: Double, b: Double) -> Double in 10 * log10(0.5 * (pow(10, a / 10) + pow(10, b / 10))) }
        let peak = both.max() ?? -200
        XCTAssertGreaterThan(peak, -50, "the boat is heard (\(peak) dB)")
        XCTAssertGreaterThanOrEqual(peak - both[5], 10, "the engine swells in: \(both[5]) → \(peak) dB")
        let heard = both.indices.filter { both[$0] >= peak - 20 }
        let span = Double((heard.last ?? 0) - (heard.first ?? 0) + 1) * 0.5
        XCTAssertTrue((12...20).contains(span), "the pass lasts \(span) s")
        let loud = both.indices.filter { both[$0] >= peak - 10 }
        guard let first = loud.first, let last = loud.last else { return XCTFail("no swell") }
        let from = left[first] - right[first], to = left[last] - right[last]
        XCTAssertGreaterThanOrEqual(abs(from), 3, "starts to one side (\(from) dB)")
        XCTAssertGreaterThanOrEqual(abs(to), 3, "ends to the other (\(to) dB)")
        XCTAssertLessThan(from * to, 0, "the boat crosses: \(from) dB → \(to) dB")
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
    }

    /// Lapping water: soft 300–2000 Hz swells of 0.3–0.8 s, 6–40 a minute.
    func testLappingSloshes() {
        guard let a = isd_ambience_create(Self.sr, 512, 1) else { return XCTFail("no ambience") }
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_LAPPING, 1)
        let total = Int(63 * Self.sr)
        var l = [Float](repeating: 0, count: total), r = l
        for i in stride(from: 0, to: total, by: 512) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(min(512, total - i))) } }
        }
        let body = SynthRender.slice(Self.mid((l: l, r: r)), 3, 63)
        let runs = Self.swells(Self.frameDB(Self.bandpass(body, 300, 2000), ms: 50), above: 6, window: 60)
        let sloshes = runs.filter { (4...20).contains($0.length) }   // 0.2–1.0 s in 50 ms frames
        XCTAssertTrue((6...40).contains(sloshes.count), "\(sloshes.count) sloshes a minute (of \(runs.count) swells)")
        XCTAssertGreaterThanOrEqual(2 * sloshes.count, runs.count, "most swells are slosh-length")
        let started = isd_ambience_debug_events(a, ISD_AMB_LAPPING)
        XCTAssertTrue((6...45).contains(started), "\(started) sloshes started in 63 s")
    }
}

// MARK: - Still places: a temple bell in your key, paper screens, a water-knocker, a bush warbler

extension AmbienceTests {
    static func key(_ root: Int32, major: Bool, at t: Double = 0) -> Action { (t, { isd_ambience_set_key($0, root, major ? 1 : 0) }) }
    static func strikeBell(at t: Double) -> Action { (t, { isd_ambience_debug_strike_bell($0) }) }
    static func startKnocker(at t: Double) -> Action { (t, { isd_ambience_debug_start_knocker($0) }) }
    static func callWarbler(at t: Double) -> Action { (t, { isd_ambience_debug_call_warbler($0) }) }

    /// The tonic of a key root (C = 0) in the bell's octave: A1 (MIDI 33) … G♯2 (MIDI 44).
    static func tonic(_ root: Int) -> Double { 440 * pow(2, Double(33 + (root + 3) % 12 - 69) / 12) }

    /// RMS over both channels (their power averaged) between two times, in dBFS: a panned source reads the same
    /// wherever it sits.
    static func stereoDB(_ out: (l: [Float], r: [Float]), _ a: Double, _ b: Double) -> Double {
        let l = SynthRender.slice(out.l, a, b), r = SynthRender.slice(out.r, a, b)
        guard !l.isEmpty else { return -200 }
        var sum = 0.0
        for i in l.indices { sum += 0.5 * (Double(l[i]) * Double(l[i]) + Double(r[i]) * Double(r[i])) }
        let meanSquare = sum / Double(l.count)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -200
    }

    /// RMS of consecutive `ms` frames over both channels between two times, in dBFS.
    static func stereoFrames(_ out: (l: [Float], r: [Float]), ms: Double, from a: Double, to b: Double) -> [Double] {
        let n = Int(ms / 1000 * sr), start = Int(a * sr), end = min(out.l.count, Int(b * sr))
        return stride(from: start, to: end - n + 1, by: n).map { s -> Double in
            var sum = 0.0
            for i in s..<(s + n) { sum += 0.5 * (Double(out.l[i]) * Double(out.l[i]) + Double(out.r[i]) * Double(out.r[i])) }
            return sum > 0 ? 10 * log10(sum / Double(n)) : -200
        }
    }

    /// The louder channel's peak between two times, in dBFS.
    static func peakDB(_ out: (l: [Float], r: [Float]), _ a: Double, _ b: Double) -> Double {
        let p = max(SynthRender.slice(out.l, a, b).map(abs).max() ?? 0, SynthRender.slice(out.r, a, b).map(abs).max() ?? 0)
        return p > 0 ? 20 * log10(Double(p)) : -200
    }

    /// The strongest bin between `lo` and `hi` Hz of a `DSPTestKit.powerSpectrum(_:size:)`: its frequency and power.
    static func strongest(_ spectrum: [Double], size: Int, _ lo: Double, _ hi: Double) -> (hz: Double, power: Double) {
        let binHz = sr / Double(size)
        var best = (hz: 0.0, power: -1.0)
        for i in 1..<spectrum.count {
            let f = Double(i) * binHz
            if f >= lo, f <= hi, spectrum[i] > best.power { best = (hz: f, power: spectrum[i]) }
        }
        return best
    }

    /// The power between `lo` and `hi` Hz of a `DSPTestKit.powerSpectrum(_:size:)`.
    static func bandPower(_ spectrum: [Double], size: Int, _ lo: Double, _ hi: Double) -> Double {
        let binHz = sr / Double(size)
        var sum = 0.0
        for i in 1..<spectrum.count where Double(i) * binHz >= lo && Double(i) * binHz <= hi { sum += spectrum[i] }
        return sum
    }

    /// Key D major: the bell sounds D2 (the D in its octave, A1–G♯2) within 3 cents, with its hum partials near 1.6, 2.3
    /// and 3.0 × the fundamental (within 3%). Every root lands in that octave, silent or struck; a key that can't be
    /// sensed (−1) or is out of range keeps the last one.
    func testTempleBellSitsOnTheKey() throws {
        XCTAssertEqual(Self.tonic(9), 55, accuracy: 1e-9, "A → A1")
        XCTAssertEqual(Self.tonic(8), 103.826, accuracy: 1e-3, "G♯ → G♯2")
        let d2 = Self.tonic(2)
        let out = Self.render(seconds: 9, actions: [Self.level(ISD_AMB_TEMPLE_BELL, 1), Self.key(2, major: true), Self.strikeBell(at: 3)])
        let ring = SynthRender.slice(Self.mid(out), 4, 9)
        let f0 = DSPTestKit.fundamental(ring, sampleRate: Self.sr, near: d2)
        XCTAssertEqual(DSPTestKit.cents(f0, d2), 0, accuracy: 3, "the bell rings at \(f0) Hz (D2 is \(d2) Hz)")
        let size = 1 << 18, spectrum = DSPTestKit.powerSpectrum(ring, size: size)
        let hum = Self.strongest(spectrum, size: size, 0.9 * f0, 1.1 * f0)
        for ratio in [1.6, 2.3, 3.0] {
            let partial = Self.strongest(spectrum, size: size, 0.9 * ratio * f0, 1.1 * ratio * f0)
            XCTAssertEqual(partial.hz / f0, ratio, accuracy: 0.03 * ratio, "the \(ratio) partial at \(partial.hz) Hz")
            XCTAssertGreaterThan(10 * log10(partial.power / hum.power), -30, "the \(ratio) partial is heard")
        }
        // Every root, straight through the API: the next strike's pitch while the bell is silent, then the strike's.
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        var l = [Float](repeating: 0, count: 256), r = l
        XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(4), accuracy: 1e-3, "E until a key is sensed")
        for root in 0..<12 {
            isd_ambience_set_key(a, Int32(root), Int32(root % 2))
            XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(root), accuracy: 1e-3, "root \(root), before a strike")
            XCTAssertTrue((55...104).contains(Self.tonic(root)), "root \(root) in A1–G♯2")
        }
        isd_ambience_set_level(a, ISD_AMB_TEMPLE_BELL, 1)
        for root in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 5] {
            isd_ambience_set_key(a, Int32(root), 1)
            isd_ambience_debug_strike_bell(a)
            isd_ambience_render(a, &l, &r, 256)
            XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(root), accuracy: 1e-3, "root \(root), struck")
        }
        isd_ambience_set_key(a, -1, 0)
        isd_ambience_set_key(a, 12, 0)
        isd_ambience_debug_strike_bell(a)
        isd_ambience_render(a, &l, &r, 256)
        XCTAssertEqual(Double(isd_ambience_debug_bell_hz(a)), Self.tonic(5), accuracy: 1e-3, "a key that can't be sensed keeps F")
        XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
    }

    /// Review focus 2: a key change while the bell rings waits for the next strike. Struck in C, the key moves to D a
    /// second later: the ring stays on C2 (within 3 cents, nothing at D2) as long as it rings, and the next strike is D2.
    func testTheBellNeverJumpsMidRing() {
        let c2 = Self.tonic(0), d2 = Self.tonic(2)
        var during: Float = 0, next: Float = 0
        let out = Self.render(seconds: 35, actions: [
            Self.level(ISD_AMB_TEMPLE_BELL, 1), Self.key(0, major: true), Self.strikeBell(at: 3), Self.key(2, major: true, at: 4),
            (6, { during = isd_ambience_debug_bell_hz($0) }),
            Self.strikeBell(at: 28), (30, { next = isd_ambience_debug_bell_hz($0) }),
        ])
        let m = Self.mid(out), size = 1 << 18
        for (from, to) in [(4.0, 9.0), (9.0, 14.0)] {
            let ring = SynthRender.slice(m, from, to)
            let f = DSPTestKit.fundamental(ring, sampleRate: Self.sr, near: c2)
            XCTAssertEqual(DSPTestKit.cents(f, c2), 0, accuracy: 3, "\(from)–\(to) s: \(f) Hz, still C2")
            let spectrum = DSPTestKit.powerSpectrum(ring, size: size)
            let atD = 10 * log10(Self.bandPower(spectrum, size: size, 0.99 * d2, 1.01 * d2) / Self.bandPower(spectrum, size: size, 0.99 * c2, 1.01 * c2))
            XCTAssertLessThan(atD, -40, "\(from)–\(to) s: nothing at D2 (\(atD) dB)")
        }
        XCTAssertEqual(Double(during), c2, accuracy: 1e-3, "the ringing strike keeps its pitch")
        let second = DSPTestKit.fundamental(SynthRender.slice(m, 29, 34), sampleRate: Self.sr, near: d2)
        XCTAssertEqual(DSPTestKit.cents(second, d2), 0, accuracy: 3, "the next strike: \(second) Hz, D2")
        XCTAssertEqual(Double(next), d2, accuracy: 1e-3)
    }

    /// After start_knocker: a trickle, then a clack (a 2 ms transient at least 15 dB above the trickle, peaking near
    /// −18 dBFS) with its ring near 1.8 kHz, then the trickle again. At density 1.5 the tube fills in 10–27 s.
    func testWaterKnockerCycle() throws {
        var clacks: [Int32] = []
        var actions: [Action] = [Self.level(ISD_AMB_WATER_KNOCKER, 1), Self.density(1.5), Self.startKnocker(at: 3)]
        for i in 0..<900 { actions.append((Double(i) * 0.05, { clacks.append(isd_ambience_debug_events($0, ISD_AMB_WATER_KNOCKER)) })) }
        let out = Self.render(seconds: 45, actions: actions)
        let first = try XCTUnwrap(clacks.firstIndex(where: { $0 > 0 }), "no clack in 45 s")
        let heard = Double(first) * 0.05
        guard (13...30.5).contains(heard) else { return XCTFail("the first clack by \(heard) s, not 13–30.5 s") }
        // The clack: the loudest 2 ms frame just before the count went up.
        let m = Self.mid(out), frames = Self.frameDB(m, ms: 2)
        let at = (Int((heard - 0.06) / 0.002)...Int((heard + 0.01) / 0.002)).max { frames[$0] < frames[$1] } ?? 0
        let clack = Double(at) * 0.002
        let trickleFrames = frames[Int((clack - 4) / 0.002)..<Int((clack - 1.5) / 0.002)].sorted()
        let rise = frames[at] - trickleFrames[trickleFrames.count / 2]
        XCTAssertGreaterThanOrEqual(rise, 15, "the clack stands \(rise) dB over the trickle")
        let peak = Self.peakDB(out, clack - 0.01, clack + 0.01)
        XCTAssertTrue((-24 ... -12).contains(peak), "the clack peaks at \(peak) dBFS")
        // Its ring: the 30 ms after the knock carry a component near 1.8 kHz, well above that band in the trickle.
        let size = 1 << 18
        let ring = SynthRender.slice(m, clack + 0.004, clack + 0.034), before = SynthRender.slice(m, clack - 4, clack - 1.5)
        let ringSpectrum = DSPTestKit.powerSpectrum(ring, size: size), beforeSpectrum = DSPTestKit.powerSpectrum(before, size: size)
        let ringHz = Self.strongest(ringSpectrum, size: size, 1200, 3000).hz
        XCTAssertEqual(ringHz, 1800, accuracy: 100, "the ring at \(ringHz) Hz")
        let lift = 10 * log10((Self.bandPower(ringSpectrum, size: size, 1600, 2000) / Double(ring.count))
                              / (Self.bandPower(beforeSpectrum, size: size, 1600, 2000) / Double(before.count)))
        XCTAssertGreaterThanOrEqual(lift, 10, "the ring is \(lift) dB over the trickle in its band")
        // The trickle before and after: in 2–4 kHz, heard, and back within 6 dB once the tube is up again.
        let fill = Self.bandDB(before, 2000, 4000), refill = Self.bandDB(SynthRender.slice(m, clack + 1.5, clack + 4), 2000, 4000)
        XCTAssertGreaterThan(fill, -65, "the trickle is heard (\(fill) dBFS)")
        XCTAssertEqual(refill, fill, accuracy: 6, "the trickle again: \(fill) → \(refill) dBFS")
        XCTAssertGreaterThan(Self.bandShare(before, 2000, 4500), 0.6, "the trickle sits in 2–4.5 kHz")
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
    }

    /// The call's long whistle rises from about 2.5 to 3.2 kHz over its first 0.6 s, step by step; then come the two
    /// quick notes, higher than the whistle ever goes.
    func testWarblerCallRises() {
        let out = Self.render(seconds: 5, actions: [Self.level(ISD_AMB_WARBLER, 1), Self.callWarbler(at: 3.2)])
        let m = Self.mid(out), size = 8192
        let track = stride(from: 3.225, to: 3.78, by: 0.05).map { t -> Double in
            Self.strongest(DSPTestKit.powerSpectrum(SynthRender.slice(m, t, t + 0.05), size: size), size: size, 2000, 4500).hz
        }
        XCTAssertEqual(track.count, 12)
        XCTAssertEqual(track.first ?? 0, 2550, accuracy: 200, "the whistle starts at \(track.first ?? 0) Hz")
        XCTAssertEqual(track[10], 3150, accuracy: 200, "and reaches \(track[10]) Hz by 0.55 s")
        for i in 1..<track.count { XCTAssertGreaterThan(track[i], track[i - 1] - 25, "it keeps rising: \(track)") }
        let big = 1 << 15
        let notes = SynthRender.slice(m, 3.88, 4.35), whistle = SynthRender.slice(m, 3.5, 3.8)
        let lift = 10 * log10((Self.bandPower(DSPTestKit.powerSpectrum(notes, size: big), size: big, 3450, 4600) / Double(notes.count))
                              / (Self.bandPower(DSPTestKit.powerSpectrum(whistle, size: big), size: big, 3450, 4600) / Double(whistle.count)))
        XCTAssertGreaterThan(lift, 20, "the quick notes, above the whistle: \(lift) dB")
    }

    /// Paper screens: soft 1–4 kHz rustles (each below −30 dBFS, near −38 typically), several a minute in a strong
    /// draught (level 1) and far fewer in a light one (0.15).
    func testPaperScreensRustle() {
        func screens(_ level: Float) -> (out: (l: [Float], r: [Float]), rustles: Int32) {
            var count: Int32 = 0
            let out = Self.render(seconds: 63, actions: [Self.level(ISD_AMB_PAPER_SCREENS, level),
                                                         (62.9, { count = isd_ambience_debug_events($0, ISD_AMB_PAPER_SCREENS) })])
            return (out, count)
        }
        let strong = screens(1), light = screens(0.15)
        XCTAssertTrue((4...15).contains(strong.rustles), "\(strong.rustles) rustles a minute in a strong draught")
        XCTAssertGreaterThanOrEqual(strong.rustles, 2 * light.rustles, "\(light.rustles) in a light one")
        XCTAssertGreaterThan(Self.bandShare(SynthRender.slice(Self.mid(strong.out), 3, 63), 1000, 4000), 0.6, "in 1–4 kHz")
        // Each rustle's level: its 50 ms frames within 15 dB of its loudest, on both channels.
        let frames = Self.stereoFrames(strong.out, ms: 50, from: 3, to: 63)
        var cores: [Double] = [], loudest = -200.0
        for run in Self.swells(frames, above: 10, window: 60) {
            let own = frames[run.start..<(run.start + run.length)]
            guard let top = own.max(), top > -80 else { continue }
            let core = own.filter { $0 >= top - 15 }
            cores.append(10 * log10(core.reduce(0) { $0 + pow(10, $1 / 10) } / Double(core.count)))
            loudest = max(loudest, top)
        }
        guard cores.count >= 3 else { return XCTFail("\(cores.count) rustles heard") }
        XCTAssertLessThan(loudest, -30, "the loudest rustle frame is \(loudest) dBFS")
        let median = cores.sorted()[cores.count / 2]
        XCTAssertTrue((-44 ... -33).contains(median), "a rustle sits near \(median) dBFS")
        XCTAssertTrue(strong.out.l.allSatisfy(\.isFinite) && strong.out.r.allSatisfy(\.isFinite))
    }
}

// MARK: - Deep water: a sonar in your key, hull creaks, humpback song, bubbles, snapping shrimp, a reef fish chorus

extension AmbienceTests {
    static func pingSonar(at t: Double) -> Action { (t, { isd_ambience_debug_ping_sonar($0) }) }
    static func startWhale(at t: Double) -> Action { (t, { isd_ambience_debug_start_whale($0) }) }
    static func bubbles(_ strength: Float, at t: Double) -> Action { (t, { isd_ambience_trigger_bubbles($0, strength) }) }
    static func closeness(_ c: Float, at t: Double = 0) -> Action { (t, { isd_ambience_set_closeness($0, c) }) }

    /// The tonic of a key root (C = 0) in the sonar's octave, A5 (MIDI 81) … G♯6 (MIDI 92): the bell's, four octaves up.
    static func sonarTonic(_ root: Int) -> Double { 16 * tonic(root) }

    /// Key F♯ minor: the sonar pings F♯6 (1480.0 Hz) within 3 cents as heard, in each ear and in both together, however
    /// close or far the room (its tail is its own: the room's modulated tail never reaches it); with no key sensed it
    /// pings E6 (1318.5 Hz), peaking near −26 dBFS. Every root lands in A5–G♯6, silent or pinged; a key that can't be
    /// sensed keeps the last one.
    func testSonarSitsOnTheKey() throws {
        XCTAssertEqual(Self.sonarTonic(6), 1480.0, accuracy: 0.05, "F♯ → F♯6")
        XCTAssertEqual(Self.sonarTonic(4), 1318.5, accuracy: 0.05, "E → E6")
        for closeness: Float in [0, 0.5, 1] {
            let out = Self.render(seconds: 8, actions: [Self.level(ISD_AMB_SONAR, 1), Self.key(6, major: false), Self.closeness(closeness),
                                                         Self.pingSonar(at: 3)])
            var heard: [(String, [Float])] = [("both ears", Self.mid(out))]
            if closeness == 0.5 { heard += [("left", out.l), ("right", out.r)] }
            for (ear, x) in heard {
                let f = DSPTestKit.fundamental(SynthRender.slice(x, 3, 8), sampleRate: Self.sr, near: 1480)
                XCTAssertEqual(DSPTestKit.cents(f, 1480), 0, accuracy: 3, "closeness \(closeness), \(ear): \(f) Hz (F♯6 is 1480.0 Hz)")
            }
        }
        let plain = Self.render(seconds: 8, actions: [Self.level(ISD_AMB_SONAR, 1), Self.pingSonar(at: 3)])
        let e6 = DSPTestKit.fundamental(SynthRender.slice(Self.mid(plain), 3, 8), sampleRate: Self.sr, near: 1318.5)
        XCTAssertEqual(DSPTestKit.cents(e6, 1318.5), 0, accuracy: 3, "no key: \(e6) Hz (E6 is 1318.5 Hz)")
        let peak = Self.peakDB(plain, 2.9, 3.5)
        XCTAssertTrue((-29 ... -23).contains(peak), "the ping peaks at \(peak) dBFS")
        XCTAssertTrue(plain.l.allSatisfy(\.isFinite) && plain.r.allSatisfy(\.isFinite))
        // Every root, straight through the API: the next ping's pitch while the sonar is silent, then the ping's.
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        var l = [Float](repeating: 0, count: 256), r = l
        XCTAssertEqual(Double(isd_ambience_debug_sonar_hz(a)), Self.sonarTonic(4), accuracy: 1e-2, "E6 until a key is sensed")
        for root in 0..<12 {
            isd_ambience_set_key(a, Int32(root), Int32(root % 2))
            XCTAssertEqual(Double(isd_ambience_debug_sonar_hz(a)), Self.sonarTonic(root), accuracy: 1e-2, "root \(root), before a ping")
            XCTAssertTrue((880...1760).contains(Self.sonarTonic(root)), "root \(root) in A5–G♯6")
        }
        isd_ambience_set_level(a, ISD_AMB_SONAR, 1)
        for root in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 5] {
            isd_ambience_set_key(a, Int32(root), 1)
            isd_ambience_debug_ping_sonar(a)
            isd_ambience_render(a, &l, &r, 256)
            XCTAssertEqual(Double(isd_ambience_debug_sonar_hz(a)), Self.sonarTonic(root), accuracy: 1e-2, "root \(root), pinged")
        }
        isd_ambience_set_key(a, -1, 0)
        isd_ambience_set_key(a, 12, 0)
        isd_ambience_debug_ping_sonar(a)
        isd_ambience_render(a, &l, &r, 256)
        XCTAssertEqual(Double(isd_ambience_debug_sonar_hz(a)), Self.sonarTonic(5), accuracy: 1e-2, "a key that can't be sensed keeps F")
        XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
    }

    /// The sonar never retunes a ping (spec §13): pinged in C, the key moves to D a second later, and the ping, its tail
    /// and its return stay on C6 (within 3 cents, nothing at D6) as long as they ring; the next ping is D6.
    func testSonarNeverJumpsMidPing() {
        let c6 = Self.sonarTonic(0), d6 = Self.sonarTonic(2)
        var during: Float = 0, next: Float = 0
        let out = Self.render(seconds: 19, actions: [
            Self.level(ISD_AMB_SONAR, 1), Self.key(0, major: true), Self.pingSonar(at: 3), Self.key(2, major: true, at: 4),
            (6, { during = isd_ambience_debug_sonar_hz($0) }),
            Self.pingSonar(at: 13), (14, { next = isd_ambience_debug_sonar_hz($0) }),
        ])
        let m = Self.mid(out), size = 1 << 18
        for (from, to) in [(3.4, 6.0), (4.5, 9.0)] {
            let ring = SynthRender.slice(m, from, to)
            let f = DSPTestKit.fundamental(ring, sampleRate: Self.sr, near: c6)
            XCTAssertEqual(DSPTestKit.cents(f, c6), 0, accuracy: 3, "\(from)–\(to) s: \(f) Hz, still C6")
            let spectrum = DSPTestKit.powerSpectrum(ring, size: size)
            let atD = 10 * log10(Self.bandPower(spectrum, size: size, 0.99 * d6, 1.01 * d6) / Self.bandPower(spectrum, size: size, 0.99 * c6, 1.01 * c6))
            XCTAssertLessThan(atD, -40, "\(from)–\(to) s: nothing at D6 (\(atD) dB)")
        }
        XCTAssertEqual(Double(during), c6, accuracy: 1e-2, "the ringing ping keeps its pitch")
        let second = DSPTestKit.fundamental(SynthRender.slice(m, 13, 18), sampleRate: Self.sr, near: d6)
        XCTAssertEqual(DSPTestKit.cents(second, d6), 0, accuracy: 3, "the next ping: \(second) Hz, D6")
        XCTAssertEqual(Double(next), d6, accuracy: 1e-2)
    }

    /// The seabed answers each ping: 1.4–2.6 s later a return at −20 ± 4 dB against the ping (20 ms frames on both
    /// channels), standing at least 6 dB clear of the tail before it.
    func testSonarReturnEcho() {
        let out = Self.render(seconds: 23, actions: [Self.level(ISD_AMB_SONAR, 1), Self.pingSonar(at: 3), Self.pingSonar(at: 10),
                                                     Self.pingSonar(at: 17)])
        for at in [3.0, 10.0, 17.0] {
            let frames = Self.stereoFrames(out, ms: 20, from: at, to: at + 4)
            guard frames.count >= 150, let ping = frames[0..<25].indices.max(by: { frames[$0] < frames[$1] }),
                  let back = frames[65..<150].indices.max(by: { frames[$0] < frames[$1] }) else { return XCTFail("no ping at \(at) s") }
            let delay = Double(back - ping) * 0.02, level = frames[back] - frames[ping]
            XCTAssertTrue((1.4...2.6).contains(delay), "the return \(delay) s after the ping at \(at) s")
            XCTAssertEqual(level, -20, accuracy: 4, "the return at \(level) dB against the ping")
            let tail = frames[(back - 20)..<(back - 10)].max() ?? 0
            XCTAssertGreaterThanOrEqual(frames[back] - tail, 6, "the return stands \(frames[back] - tail) dB clear of the tail")
        }
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
    }

    /// A far-off humpback: once it starts, ≥ 80% of the energy in 100–2000 Hz, unit after unit (moans, whoops, cries
    /// and grunts), near −30 dBFS while it sings (its songs vary by a few dB).
    func testWhaleUnitsInBand() {
        var units: Int32 = 0
        let out = Self.render(seconds: 23, actions: [Self.level(ISD_AMB_WHALE, 1), Self.startWhale(at: 3),
                                                     (22.9, { units = isd_ambience_debug_events($0, ISD_AMB_WHALE) })])
        let share = Self.bandShare(SynthRender.slice(Self.mid(out), 3, 23), 100, 2000)
        XCTAssertGreaterThanOrEqual(share, 0.8, "\(share) of the song in 100–2000 Hz")
        XCTAssertGreaterThanOrEqual(units, 6, "\(units) units in 20 s")
        let db = Self.stereoDB(out, 3, 23)
        XCTAssertTrue((-38 ... -22).contains(db), "the whale sings at \(db) dBFS")
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1)
    }

    /// Bubbles: a burst triggered at 3 s starts within 20 ms of the trigger; each bubble (its first 12 ms) rings
    /// strongest inside 1.1–8 kHz, the Minnaert band for radii of 0.4–3 mm; a middling burst peaks near −28 dBFS; and a
    /// trigger while the bubbles are silent is never heard (a burst never carries into the next world).
    func testBubblesRingAtMinnaert() {
        var bursts: [Int32] = []
        let out = Self.render(seconds: 5, actions: [Self.level(ISD_AMB_BUBBLES, 1), Self.bubbles(0.15, at: 3),
                                                    (2.99, { bursts.append(isd_ambience_debug_events($0, ISD_AMB_BUBBLES)) }),
                                                    (3.5, { bursts.append(isd_ambience_debug_events($0, ISD_AMB_BUBBLES)) })])
        XCTAssertEqual(bursts, [0, 1], "one burst, on the trigger")
        let m = Self.mid(out), frames = Self.stereoFrames(out, ms: 2, from: 2.98, to: 4.5)
        let top = frames.max() ?? -200
        guard let first = frames.firstIndex(where: { $0 >= top - 30 }) else { return XCTFail("no burst") }
        let onset = 2.98 + Double(first) * 0.002 - 3
        XCTAssertTrue((-0.006...0.02).contains(onset), "the burst starts \(onset * 1000) ms after the trigger")
        var rang = 0
        for i in 1..<frames.count where frames[i] >= top - 30 && frames[i] - frames[i - 1] >= 10 {
            rang += 1
            let at = 2.98 + Double(i) * 0.002, size = 4096
            let hz = Self.strongest(DSPTestKit.powerSpectrum(SynthRender.slice(m, at, at + 0.012), size: size), size: size, 300, 20000).hz
            XCTAssertTrue((1100...8000).contains(hz), "the bubble at \(at) s rings at \(hz) Hz")
        }
        XCTAssertGreaterThanOrEqual(rang, 4, "\(rang) bubbles heard")
        let middling = Self.render(seconds: 5, actions: [Self.level(ISD_AMB_BUBBLES, 1), Self.bubbles(0.5, at: 3)])
        let peak = Self.peakDB(middling, 2.9, 5)
        XCTAssertTrue((-32 ... -24).contains(peak), "a burst peaks at \(peak) dBFS")
        let silent = Self.render(seconds: 3, actions: [Self.bubbles(1, at: 1)])
        XCTAssertLessThan(DSPTestKit.dBFS(silent.l), -150, "no bubbles while they are silent")
        XCTAssertTrue(out.l.allSatisfy(\.isFinite) && middling.l.allSatisfy(\.isFinite))
    }

    /// Snapping shrimp at level 1: a crackle with ≥ 90% of its energy above 2 kHz, at 400–1,200 transients a second as
    /// heard (0.25 ms frames rising 6 dB over the bed's median) and as started, near −24 dBFS RMS and clear of the
    /// limiter; at level 0.5 (a lower hour) about half as many snap.
    func testShrimpCrackleAbove2kHz() {
        func shrimp(_ level: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 7, actions: [Self.level(ISD_AMB_SHRIMP, level),
                                                        (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_SHRIMP)) }),
                                                        (6.999, { counts.append(isd_ambience_debug_events($0, ISD_AMB_SHRIMP)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 4 : 0)
        }
        let full = shrimp(1), half = shrimp(0.5)
        let m = Self.mid(full.out)
        let share = Self.bandShare(SynthRender.slice(m, 3, 7), 2000, 24000)
        XCTAssertGreaterThanOrEqual(share, 0.9, "\(share) of the crackle above 2 kHz")
        XCTAssertTrue((400...1200).contains(full.perSecond), "\(full.perSecond) snaps started a second")
        let frames = Self.frameDB(SynthRender.slice(m, 3, 5), ms: 0.25)
        let median = frames.sorted()[frames.count / 2]
        var heard = 0, on = false
        for f in frames {
            let hit = f >= median + 6
            if hit && !on { heard += 1 }
            on = hit
        }
        XCTAssertTrue((400...1200).contains(heard / 2), "\(heard / 2) transients heard a second")
        let db = Self.stereoDB(full.out, 3, 7), peak = Self.peakDB(full.out, 3, 7)
        XCTAssertTrue((-27 ... -21).contains(db), "the bed at \(db) dBFS")
        XCTAssertLessThan(peak, -1, "its loudest snap at \(peak) dBFS")
        let ratio = half.perSecond / max(1, full.perSecond)
        XCTAssertTrue((0.35...0.65).contains(ratio), "at half the level \(half.perSecond) a second (\(ratio))")
        XCTAssertTrue(full.out.l.allSatisfy(\.isFinite) && full.out.r.allSatisfy(\.isFinite))
    }

    /// The reef's fish at level 1: pops, knocks, croaks and damselfish trains with ≥ 80% of their energy in 100–800 Hz,
    /// near −30 dBFS, a chorus of tens of calls a second that thins to a few at level 0.15 (the hours between).
    func testFishChorusInItsBand() {
        func fish(_ level: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 13, actions: [Self.level(ISD_AMB_FISH_CHORUS, level),
                                                         (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_FISH_CHORUS)) }),
                                                         (12.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_FISH_CHORUS)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 10 : 0)
        }
        let chorus = fish(1), few = fish(0.15)
        let share = Self.bandShare(SynthRender.slice(Self.mid(chorus.out), 3, 13), 100, 800)
        XCTAssertGreaterThanOrEqual(share, 0.8, "\(share) of the chorus in 100–800 Hz")
        let db = Self.stereoDB(chorus.out, 3, 13)
        XCTAssertTrue((-34 ... -26).contains(db), "the chorus at \(db) dBFS")
        XCTAssertGreaterThanOrEqual(chorus.perSecond, 20, "\(chorus.perSecond) calls a second at 1")
        XCTAssertGreaterThan(few.perSecond, 0, "a few still call at 0.15")
        XCTAssertLessThanOrEqual(few.perSecond, 0.25 * chorus.perSecond, "\(few.perSecond) calls a second at 0.15")
        XCTAssertTrue(chorus.out.l.allSatisfy(\.isFinite) && chorus.out.r.allSatisfy(\.isFinite))
    }
}

// MARK: - Storms: the storm and plains families, and thunder that arrives late

extension AmbienceTests {
    static func queueThunder(_ delay: Float, _ strength: Float, at t: Double) -> Action { (t, { isd_ambience_queue_thunder($0, delay, strength) }) }
    static func allSoundOff(at t: Double) -> Action { (t, { isd_ambience_all_sound_off($0) }) }
    static func clearThunder(at t: Double) -> Action { (t, { isd_ambience_clear_thunder($0) }) }
    static func trigger(_ source: ISDAmbienceSource, at t: Double) -> Action { (t, { isd_ambience_debug_trigger($0, source) }) }

    /// The inflow roar's resonance for a key root (C = 0): a fifth (equal-tempered) below its tonic in A2–G♯3.
    static func roarTonic(_ root: Int) -> Double { 2 * tonic(root) * pow(2, -7.0 / 12) }

    /// The strongest peak within ±60 cents of `hz` in a Welch average of Blackman–Harris power spectra (`size`-sample
    /// segments, hop size/2; parabolic on log power), and how far it stands over the spectrum 1.5–2.5 semitones either
    /// side of `hz` (dB). A noise resonance's peak wanders inside its own width in any one segment; the average holds it.
    static func welchPeak(_ x: [Float], near hz: Double, size: Int = 1 << 17) -> (hz: Double, prominence: Double) {
        var power = [Double](repeating: 0, count: size / 2)
        var start = 0
        while start + size <= x.count {
            let p = DSPTestKit.powerSpectrum(Array(x[start..<(start + size)]), size: size)
            for i in 0..<min(power.count, p.count) { power[i] += p[i] }
            start += size / 2
        }
        let binHz = sr / Double(size)
        let lo = Int(hz * pow(2, -60.0 / 1200) / binHz), hi = Int(hz * pow(2, 60.0 / 1200) / binHz) + 1
        guard lo > 1, hi < power.count - 1 else { return (0, 0) }
        var best = lo
        for i in lo...hi where power[i] > power[best] { best = i }
        let a = log(power[best - 1] + 1e-300), b = log(power[best] + 1e-300), c = log(power[best + 1] + 1e-300)
        let d = a - 2 * b + c, offset = d != 0 ? 0.5 * (a - c) / d : 0
        var side = 0.0, n = 0
        for i in 1..<power.count {
            let semitones = abs(12 * log2(Double(i) * binHz / hz))
            if semitones >= 1.5, semitones <= 2.5 { side += power[i]; n += 1 }
        }
        return ((Double(best) + offset) * binHz, 10 * log10(power[best] / max(1e-300, side / Double(max(1, n)))))
    }

    /// The calls of a flight as heard: a 10 ms frame (both ears, 1.5–6 kHz) within 20 dB of the loudest that rises 8 dB or
    /// more over the frame before it (a call's attack; the room's tail between calls never rises so); each call's pan
    /// (L − R)/(L + R) by energy over that frame and the three after.
    static func callPans(_ out: (l: [Float], r: [Float])) -> [Double] {
        let left = frameDB(bandpass(out.l, 1500, 6000), ms: 10), right = frameDB(bandpass(out.r, 1500, 6000), ms: 10)
        let both: [Double] = zip(left, right).map { (a: Double, b: Double) -> Double in 10 * log10(0.5 * (pow(10, a / 10) + pow(10, b / 10)) + 1e-30) }
        let top = both.max() ?? -200
        var pans: [Double] = [], i = 1
        while i + 4 <= both.count {
            if both[i] >= top - 20, both[i] - both[i - 1] >= 8 {
                var l = 0.0, r = 0.0
                for k in i..<(i + 4) { l += pow(10, left[k] / 10); r += pow(10, right[k] / 10) }
                pans.append((l - r) / (l + r))
                i += 4
            } else {
                i += 1
            }
        }
        return pans
    }

    /// Picture first, sound late (Storms spec §3, §8.3): thunder queued 3 s out starts 3 s later to the frame (3.0 ±
    /// 0.05 s, with silence before it), rolls for 2–8 s with at least 80% of its energy at 20–150 Hz, under the limiter. A
    /// strike 0.3 km off (0.9 s) and one 4 km off (12 s, the cap) each arrive on their own delay; the far one rolls at
    /// least 2 s longer, lower, and at least 6 dB softer at its loudest. (g++ mirror, seed 1: 2.99 s, 3.70 s long, 95.4%,
    /// peak 0.22; near 0.89 s, 2.95 s, −16.7 dBFS, 65 Hz; far 11.99 s, 7.15 s, −29.8 dBFS, 53 Hz.)
    func testThunderArrivesLate() {
        func roll(_ delay: Float) -> (out: (l: [Float], r: [Float]), onset: Double, length: Double, loudest: Double, centroid: Double) {
            let d = Double(delay)
            let out = Self.render(seconds: 1 + d + 9, actions: [Self.level(ISD_AMB_THUNDER_ROLL, 1), Self.queueThunder(delay, 0.8, at: 1)])
            let frames = Self.frameDB(Self.mid(out), ms: 10), top = frames.max() ?? -200
            let onset = Double(frames.firstIndex { $0 >= top - 40 } ?? 0) * 0.01 - 1
            let slow = Self.stereoFrames(out, ms: 50, from: 0, to: 1 + d + 9), loudest = slow.max() ?? -200
            let heard = slow.indices.filter { slow[$0] >= loudest - 30 }
            let length = Double((heard.last ?? 0) - (heard.first ?? 0) + 1) * 0.05
            let centroid = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(out), 1 + d, 1 + d + 8), sampleRate: Self.sr)
            return (out, onset, length, loudest, centroid)
        }
        let middle = roll(3), near = roll(0.9), far = roll(12)
        XCTAssertEqual(middle.onset, 3, accuracy: 0.05, "the roll starts \(middle.onset) s after the strike")
        XCTAssertLessThan(DSPTestKit.dBFS(SynthRender.slice(Self.mid(middle.out), 1, 3.95)), -100, "nothing arrives early")
        XCTAssertTrue((2...8).contains(middle.length), "it rolls for \(middle.length) s")
        let low = Self.bandShare(SynthRender.slice(Self.mid(middle.out), 4, 12), 20, 150)
        XCTAssertGreaterThanOrEqual(low, 0.8, "\(low) of its energy at 20–150 Hz")
        XCTAssertLessThan(max(DSPTestKit.peak(middle.out.l), DSPTestKit.peak(middle.out.r)), 0.5, "under the limiter")
        XCTAssertEqual(near.onset, 0.9, accuracy: 0.05, "a strike 0.3 km off: \(near.onset) s")
        XCTAssertEqual(far.onset, 12, accuracy: 0.05, "a strike 4 km off: \(far.onset) s")
        XCTAssertGreaterThanOrEqual(far.length, near.length + 2, "far \(far.length) s, near \(near.length) s")
        XCTAssertGreaterThanOrEqual(near.loudest - far.loudest, 6, "near \(near.loudest) dBFS, far \(far.loudest) dBFS")
        XCTAssertLessThan(far.centroid, near.centroid, "far \(Int(far.centroid)) Hz, near \(Int(near.centroid)) Hz")
        for out in [middle.out, near.out, far.out] { XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite)) }
    }

    /// Review focus 4: the queue holds 16 (20 queued at once: the four oldest give way, so the first roll is the fifth's, at
    /// 3 s, and 16 roll); all-sound-off drops what is on its way and stops a roll (at least 10 dB down in the half second
    /// after, 20 dB in the 1.5 s after that, the room's tail ringing out); a world switch (the roll's level to nothing, or
    /// clear) drops what is on its way and a queue while the roll fades is never heard, while the next world's thunder
    /// still comes; a clear drops only what was queued before it; a silent roll ignores the queue. (g++ mirror: 0 then 16,
    /// the first at 2.99 s; 12.8 and 25.2 dB down; 0, 0, 0 then 1, 1, 0.)
    func testThunderQueueIsBoundedAndCleared() {
        func rolls(_ actions: [Action], seconds: Double, by t: Double) -> (count: Int32, out: (l: [Float], r: [Float])) {
            var count: Int32 = -1
            var all = actions
            all.append((t, { count = isd_ambience_debug_events($0, ISD_AMB_THUNDER_ROLL) }))
            let out = Self.render(seconds: seconds, actions: all)
            return (count, out)
        }
        var twenty: [Action] = [Self.level(ISD_AMB_THUNDER_ROLL, 1)]
        for i in 1...20 { twenty.append(Self.queueThunder(0.5 * Float(i), 0.5, at: 0.5)) }
        XCTAssertEqual(rolls(twenty, seconds: 3, by: 2.9).count, 0, "the four oldest gave way")
        let all = rolls(twenty, seconds: 11.5, by: 11.4)
        XCTAssertEqual(all.count, 16, "16 roll")
        let first = Self.frameDB(Self.mid(all.out), ms: 10).firstIndex { $0 > -100 }.map { Double($0) * 0.01 } ?? -1
        XCTAssertEqual(first, 3, accuracy: 0.05, "the first roll is the fifth's: \(first) s")

        var four: [Action] = [Self.level(ISD_AMB_THUNDER_ROLL, 1)]
        for d in 2...5 { four.append(Self.queueThunder(Float(d), 0.8, at: 1)) }
        let panic = rolls(four + [Self.allSoundOff(at: 1.5)], seconds: 9, by: 8.9)
        XCTAssertEqual(panic.count, 0, "all sound off: nothing arrives")
        XCTAssertLessThan(DSPTestKit.dBFS(SynthRender.slice(Self.mid(panic.out), 1.5, 9)), -150)
        let rolling: [Action] = [Self.level(ISD_AMB_THUNDER_ROLL, 1), Self.queueThunder(0.5, 1, at: 1)]
        let kept = Self.mid(Self.render(seconds: 5, actions: rolling)), cut = Self.mid(Self.render(seconds: 5, actions: rolling + [Self.allSoundOff(at: 2)]))
        let soon = DSPTestKit.dBFS(SynthRender.slice(kept, 2.05, 2.5)) - DSPTestKit.dBFS(SynthRender.slice(cut, 2.05, 2.5))
        let later = DSPTestKit.dBFS(SynthRender.slice(kept, 2.5, 4)) - DSPTestKit.dBFS(SynthRender.slice(cut, 2.5, 4))
        XCTAssertGreaterThanOrEqual(soon, 10, "a roll stops: \(soon) dB down in the half second after")
        XCTAssertGreaterThanOrEqual(later, 20, "and \(later) dB down after that")

        let gone = rolls(four + [Self.level(ISD_AMB_THUNDER_ROLL, 0, at: 1.5), Self.queueThunder(1, 1, at: 2)], seconds: 9, by: 8.9)
        XCTAssertEqual(gone.count, 0, "the world's thunder going: nothing arrives, and nothing queued as it fades")
        let cleared = four + [Self.clearThunder(at: 1.5), Self.queueThunder(1, 1, at: 2)]
        XCTAssertEqual(rolls(cleared, seconds: 3, by: 2.9).count, 0, "cleared: nothing arrives")
        XCTAssertEqual(rolls(cleared, seconds: 9, by: 8.9).count, 1, "the next world's thunder still does")
        // In one render (2.0 s and 2.001 s fall in the same block): the clear, then a new strike's thunder, which stays.
        let same: [Action] = [Self.level(ISD_AMB_THUNDER_ROLL, 1), Self.queueThunder(3, 1, at: 1), Self.clearThunder(at: 2), Self.queueThunder(0.5, 1, at: 2.001)]
        XCTAssertEqual(rolls(same, seconds: 4.5, by: 4.4).count, 1, "a clear drops only what came before it")
        let silent = rolls([Self.queueThunder(0.5, 1, at: 0.5)], seconds: 3, by: 2.9)
        XCTAssertEqual(silent.count, 0)
        XCTAssertLessThan(DSPTestKit.dBFS(silent.out.l), -150, "no thunder while the roll is silent")
    }

    /// Hail on a far shed's tin roof (spec §8.3): at level 1 a dense rain of 600–800 stones a second with at least 85% of
    /// the sound at 1.5–4 kHz (the roof's own panel modes), near −26 dBFS, the shed off to the right; the rate follows the
    /// hail (the level): at 0.3 fewer than a quarter as many. (g++ mirror: 696.9 and 115.8 a second, 92.7%, −26.7 dBFS,
    /// the right 3.0 dB up.)
    func testHailOnTinBand() {
        func hail(_ level: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 13, actions: [Self.level(ISD_AMB_HAIL_TIN, level),
                                                         (3, { counts.append(isd_ambience_debug_events($0, ISD_AMB_HAIL_TIN)) }),
                                                         (12.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_HAIL_TIN)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 10 : 0)
        }
        let full = hail(1), light = hail(0.3)
        XCTAssertTrue((600...800).contains(full.perSecond), "\(full.perSecond) stones a second at 1")
        XCTAssertGreaterThan(light.perSecond, 0)
        XCTAssertLessThanOrEqual(light.perSecond, 0.25 * full.perSecond, "\(light.perSecond) a second at 0.3")
        let share = Self.bandShare(SynthRender.slice(Self.mid(full.out), 3, 13), 1500, 4000)
        XCTAssertGreaterThanOrEqual(share, 0.85, "\(share) at 1.5–4 kHz")
        let db = Self.stereoDB(full.out, 3, 13)
        XCTAssertTrue((-30 ... -22).contains(db), "\(db) dBFS")
        let side = DSPTestKit.dBFS(SynthRender.slice(full.out.r, 3, 13)) - DSPTestKit.dBFS(SynthRender.slice(full.out.l, 3, 13))
        XCTAssertGreaterThanOrEqual(side, 1.5, "the shed off to the right: \(side) dB")
        XCTAssertTrue(full.out.l.allSatisfy(\.isFinite) && full.out.r.allSatisfy(\.isFinite))
    }

    /// The flock flees the storm (spec §8.3): as the birds' level comes up a flight starts, and each call is heard farther
    /// round to one side than the last (the storm is ahead): over four seeds, at least six calls heard, all on one side,
    /// their azimuth never stepping back toward the storm (by more than 0.03 of the pan), from near ahead (|pan| ≤ 0.4) to
    /// well round (≥ 0.8). (g++ mirror, seed 1: 9 calls, +0.22 +0.41 +0.54 +0.65 +0.75 +0.83 +0.88 +0.93 +0.97; seeds
    /// 1–12 at closeness 0, 0.5 and 1 never step back more than 0.045.)
    func testBirdsFleeSweepAway() {
        for seed: UInt64 in 1...4 {
            let out = Self.render(seconds: 8, seed: seed, actions: [Self.level(ISD_AMB_BIRDS_FLEE, 1)])
            let pans = Self.callPans(out)
            XCTAssertGreaterThanOrEqual(pans.count, 6, "seed \(seed): \(pans.count) calls heard")
            guard let first = pans.first, let last = pans.last else { continue }
            XCTAssertTrue(pans.allSatisfy { $0 * last > 0 }, "seed \(seed): all to one side: \(pans)")
            for i in 1..<pans.count {
                XCTAssertGreaterThanOrEqual(abs(pans[i]), abs(pans[i - 1]) - 0.03, "seed \(seed): call \(i) steps back toward the storm: \(pans)")
            }
            XCTAssertLessThanOrEqual(abs(first), 0.4, "seed \(seed): the first call near ahead: \(first)")
            XCTAssertGreaterThanOrEqual(abs(last), 0.8, "seed \(seed): the last well round: \(last)")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        }
    }

    /// The inflow roar's resonance sits a fifth below the key's tonic (in A2–G♯3) within 5 cents, in each ear and both
    /// together, standing at least 10 dB over the wind around it: D major G2 (98.0 Hz), F♯ minor B2 (123.5 Hz), and with
    /// no key yet E's, A2 (110.0 Hz); a new key glides in (D, then A at 10 s: on G2 until then, on D2, 73.4 Hz, by 18 s). It
    /// is all dry, so the shared room's modulated tail never pulls it off. (g++ mirror: +0.28, −0.36, −0.08 cents, ears
    /// within 1.6, prominence 16.3–18.0 dB; 12 seeds × 4 keys within 2.1 cents.)
    func testInflowRoarTunedBelowTheKey() {
        for (root, major) in [(2, true), (6, false), (-1, true)] {
            var actions: [Action] = [Self.level(ISD_AMB_INFLOW_ROAR, 1)]
            if root >= 0 { actions.append(Self.key(Int32(root), major: major)) }
            let out = Self.render(seconds: 25, actions: actions)
            let want = Self.roarTonic(root >= 0 ? root : 4)
            let both = Self.welchPeak(SynthRender.slice(Self.mid(out), 3, 25), near: want)
            XCTAssertEqual(DSPTestKit.cents(both.hz, want), 0, accuracy: 5, "root \(root): \(both.hz) Hz against \(want) Hz")
            XCTAssertGreaterThanOrEqual(both.prominence, 10, "root \(root): the resonance stands \(both.prominence) dB clear")
            for (ear, x) in [("left", out.l), ("right", out.r)] {
                let f = Self.welchPeak(SynthRender.slice(x, 3, 25), near: want).hz
                XCTAssertEqual(DSPTestKit.cents(f, want), 0, accuracy: 5, "root \(root), \(ear): \(f) Hz")
            }
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite))
        }
        let glide = Self.mid(Self.render(seconds: 32, actions: [Self.level(ISD_AMB_INFLOW_ROAR, 1), Self.key(2, major: true), Self.key(9, major: false, at: 10)]))
        let before = Self.welchPeak(SynthRender.slice(glide, 3, 10), near: Self.roarTonic(2)).hz
        let after = Self.welchPeak(SynthRender.slice(glide, 18, 32), near: Self.roarTonic(9)).hz
        XCTAssertEqual(DSPTestKit.cents(before, Self.roarTonic(2)), 0, accuracy: 5, "on D's: \(before) Hz")
        XCTAssertEqual(DSPTestKit.cents(after, Self.roarTonic(9)), 0, accuracy: 5, "then on A's: \(after) Hz")
    }

    /// The smell of rain before the rain (spec §8.3): at 0.35 (early in a gust front's Hit) a soft hiss with at least 80%
    /// of it at 1–8 kHz and not one drop, and at virga's 0.5 not one drop in a minute either; at 1 the first fat drops
    /// patter (200 or more in 20 s) over a hiss 6 dB louder or more; as the level rises from nothing the hiss is heard (a
    /// 50 ms frame over −60 dBFS) at least half a second before the first drop falls. (g++ mirror: 0 drops, −37.7 dBFS,
    /// 90.7%; virga 0 drops in a minute; 363 drops, −27.8 dBFS; heard at 0.25 s, the first drop by 1.65 s.)
    func testRainOnDustRisesBeforeRain() {
        func dust(_ level: Float, seconds: Double = 23) -> (out: (l: [Float], r: [Float]), drops: Int32) {
            var drops: Int32 = -1
            let out = Self.render(seconds: seconds, actions: [Self.level(ISD_AMB_RAIN_ON_DUST, level),
                                                              (seconds - 0.01, { drops = isd_ambience_debug_events($0, ISD_AMB_RAIN_ON_DUST) })])
            return (out, drops)
        }
        let before = dust(0.35), virga = dust(0.5, seconds: 63), rain = dust(1)
        XCTAssertEqual(before.drops, 0, "the smell of rain, no rain")
        XCTAssertEqual(virga.drops, 0, "virga's rain never reaches the ground")
        let hiss = Self.stereoDB(before.out, 3, 23)
        XCTAssertGreaterThan(hiss, -50, "the hiss is heard: \(hiss) dBFS")
        XCTAssertGreaterThanOrEqual(Self.bandShare(SynthRender.slice(Self.mid(before.out), 3, 23), 1000, 8000), 0.8)
        XCTAssertGreaterThanOrEqual(rain.drops, 200, "\(rain.drops) drops in 20 s")
        XCTAssertGreaterThanOrEqual(Self.stereoDB(rain.out, 3, 23) - hiss, 6)
        var counts: [Int32] = []
        var actions: [Action] = [Self.level(ISD_AMB_RAIN_ON_DUST, 1)]
        for i in 0..<80 { actions.append((Double(i) * 0.05, { counts.append(isd_ambience_debug_events($0, ISD_AMB_RAIN_ON_DUST)) })) }
        let rising = Self.render(seconds: 4, actions: actions)
        let frames = Self.stereoFrames(rising, ms: 50, from: 0, to: 4)
        let heard = frames.firstIndex { $0 > -60 }.map { Double($0) * 0.05 } ?? 99
        let firstDrop = counts.firstIndex { $0 > 0 }.map { Double($0) * 0.05 } ?? -1
        XCTAssertGreaterThanOrEqual(firstDrop - heard, 0.5, "the hiss at \(heard) s, the first drop by \(firstDrop) s")
        XCTAssertTrue(rain.out.l.allSatisfy(\.isFinite) && rain.out.r.allSatisfy(\.isFinite))
    }

    /// Dry cicadas stop dead 2 s before a close strike (spec §9.3), end to end: the world (`CicadaHush`) is asked for a strike
    /// 5 km off at 4 s (it lands at once and the cicadas sing on) and one 1.2 km off at 6 s (held): the cicadas' level goes to
    /// nothing, the chorus stops dead (15 dB down within 0.1–0.2 s, 40 dB from half a second on) and the strike lands 2 s
    /// after the hush, its thunder rolling in 3.6 s later into the silence (60 dB down). (g++ mirror, seed 1: 20.8, 50.4 and
    /// 116.0 dB down; the far strike's 2 s within 0.1 dB of the chorus before it.)
    func testCicadasStopBeforeACloseStrike() throws {
        let a = try XCTUnwrap(isd_ambience_create(Self.sr, 256, 1))
        defer { isd_ambience_destroy(a) }
        isd_ambience_set_level(a, ISD_AMB_DRY_CICADAS, 1)
        isd_ambience_set_level(a, ISD_AMB_THUNDER_ROLL, 1)
        var hush = CicadaHush()
        let total = Int(16 * Self.sr), dt = 256 / Self.sr
        var l = [Float](repeating: 0, count: total), r = l
        var asked = -1.0, landed = -1.0, farLanded = false
        for i in stride(from: 0, to: total, by: 256) {
            let t = Double(i) / Self.sr
            if i > 0, let km = hush.step(dt: dt) {   // the elapsed block first, then this block's asks
                landed = t
                let roll = QueuedThunder.strike(km: km, strength: 0.8)
                isd_ambience_queue_thunder(a, Float(roll.delay), Float(roll.strength))
            }
            if t >= 4, !farLanded {
                farLanded = hush.strike(atKm: 5)
                let roll = QueuedThunder.strike(km: 5, strength: 0.5)   // capped at 12 s: it arrives at 16 s, after the test
                isd_ambience_queue_thunder(a, Float(roll.delay), Float(roll.strength))
            }
            if t >= 6, asked < 0 {
                asked = t
                let landsNow = hush.strike(atKm: 1.2)
                XCTAssertFalse(landsNow, "a close strike waits for the silence")
            }
            isd_ambience_set_level(a, ISD_AMB_DRY_CICADAS, Float(hush.level(1)))
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(min(256, total - i))) } }
        }
        XCTAssertTrue(farLanded, "a far strike lands at once")
        XCTAssertEqual(landed - asked, 2, accuracy: 0.01, "the close strike lands \(landed - asked) s after the hush")
        let m = Self.mid((l: l, r: r)), band = Self.bandpass(m, 3000, 9000)
        let singing = DSPTestKit.dBFS(SynthRender.slice(band, 3, 4))
        XCTAssertGreaterThan(singing, -40, "the chorus is heard: \(singing) dBFS")
        XCTAssertEqual(DSPTestKit.dBFS(SynthRender.slice(band, 4.1, 6)), singing, accuracy: 1.5, "the far strike leaves them singing")
        let dead = singing - DSPTestKit.dBFS(SynthRender.slice(band, asked + 0.1, asked + 0.2))
        let silent = singing - DSPTestKit.dBFS(SynthRender.slice(band, asked + 0.5, landed))
        let through = singing - DSPTestKit.dBFS(SynthRender.slice(band, landed, landed + 3.6))
        XCTAssertGreaterThanOrEqual(dead, 15, "stopped dead: \(dead) dB down 0.1–0.2 s after the hush")
        XCTAssertGreaterThanOrEqual(silent, 40, "silent before the strike: \(silent) dB down")
        XCTAssertGreaterThanOrEqual(through, 60, "and through to its thunder: \(through) dB down")
        let low = { (from: Double, to: Double) -> Double in DSPTestKit.dBFS(Self.bandpass(SynthRender.slice(m, from, to), 30, 150)) }
        XCTAssertGreaterThanOrEqual(low(landed + 3.6, landed + 4.6) - low(landed + 2.4, landed + 3.4), 20, "the close strike's thunder rolls in")
        XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
    }

    /// The windmill turns with the wind (spec §9.3): from 15 to 45 s, the wheel spun up, it pumps at the Core's law
    /// (`WeatherAmbience.windmillRate`, within 5%: 0.75 strokes a second in a gale, 0.30 at 0.45) and is heard doing so
    /// (its envelope repeats at the stroke's period within 5%), louder in the stronger wind, off to the left by the tank;
    /// below the cut-in it stands still and silent. (g++ mirror: 0.767 and 0.300 a second, periods 1.33 and 3.32 s on
    /// seeds 1–4, −37.2 and −51.1 dBFS, the left 4.9 dB up.)
    func testWindmillFollowsWind() {
        func mill(_ level: Float) -> (out: (l: [Float], r: [Float]), perSecond: Double) {
            var counts: [Int32] = []
            let out = Self.render(seconds: 45, actions: [Self.level(ISD_AMB_WINDMILL, level),
                                                         (15, { counts.append(isd_ambience_debug_events($0, ISD_AMB_WINDMILL)) }),
                                                         (44.99, { counts.append(isd_ambience_debug_events($0, ISD_AMB_WINDMILL)) })])
            return (out, counts.count == 2 ? Double(counts[1] - counts[0]) / 30 : -1)
        }
        var loudness: [Double] = []
        for wind in [1.0, 0.45] {
            let run = mill(Float(wind)), law = WeatherAmbience.windmillRate(wind)
            XCTAssertEqual(run.perSecond, law, accuracy: 0.05 * law, "wind \(wind): \(run.perSecond) strokes a second against \(law)")
            let m = SynthRender.slice(Self.mid(run.out), 15, 45)
            let env = Self.frameDB(m, ms: 10).map { pow(10, $0 / 20) }
            let period = 1 / law
            var best = -1.0, bestLag = 0
            for lag in Int(0.7 * period * 100)...Int(1.3 * period * 100) {
                var s = 0.0
                for i in 0..<(env.count - lag) { s += env[i] * env[i + lag] }
                if s > best { best = s; bestLag = lag }
            }
            XCTAssertEqual(Double(bestLag) * 0.01, period, accuracy: 0.05 * period, "wind \(wind): heard every \(Double(bestLag) * 0.01) s")
            loudness.append(Self.stereoDB(run.out, 15, 45))
            let side = DSPTestKit.dBFS(SynthRender.slice(run.out.l, 15, 45)) - DSPTestKit.dBFS(SynthRender.slice(run.out.r, 15, 45))
            XCTAssertGreaterThanOrEqual(side, 3, "off to the left: \(side) dB")
            XCTAssertTrue(run.out.l.allSatisfy(\.isFinite) && run.out.r.allSatisfy(\.isFinite))
        }
        XCTAssertGreaterThanOrEqual(loudness[0] - loudness[1], 6, "louder in the gale: \(loudness)")
        let still = mill(0.06)
        XCTAssertEqual(still.perSecond, 0, "below the cut-in it stands still")
        XCTAssertLessThan(DSPTestKit.dBFS(still.out.l), -150)
        XCTAssertEqual(WeatherAmbience.windmillRate(0.06), 0)
    }

    /// testNewSourcesInTheirBands, Storms: the storm and plains families, each around its band at level 1 (the thunder
    /// rolling a queued strike; the birds, the grid and the far truck set going at 3 s): continuous beds by their RMS, events
    /// by their peaks; all finite and under full scale. (g++ mirror, seed 1: centroids 2460, 2500, 3215, 64, 99, 3149, 5222,
    /// 367, 213, 5531, 1449, 93 Hz; levels −24.1, −26.7, peak −17.2, peak −8.2, −24.9, −28.4, −25.0, peak −14.3, peak
    /// −24.9, −40.8, −42.0, −38.0 dBFS; the rain on dust −27.6.)
    func checkStormSourcesInTheirBands() {
        let table: [(ISDAmbienceSource, String, ClosedRange<Double>, ClosedRange<Double>, Bool)] = [
            (ISD_AMB_GRASS_WIND, "grass wind", 1500...4500, -30 ... -18, false),
            (ISD_AMB_HAIL_TIN, "hail on tin", 1500...4000, -32 ... -20, false),
            (ISD_AMB_BIRDS_FLEE, "birds fleeing", 2000...5000, -26 ... -12, true),
            (ISD_AMB_THUNDER_ROLL, "thunder roll", 30...150, -20 ... -4, true),
            (ISD_AMB_INFLOW_ROAR, "inflow roar", 60...200, -30 ... -18, false),
            (ISD_AMB_RAIN_ON_DUST, "rain on dust", 1500...6000, -34 ... -22, false),
            (ISD_AMB_DRY_CICADAS, "dry cicadas", 3500...8000, -31 ... -19, false),
            (ISD_AMB_WINDMILL, "windmill", 150...1500, -22 ... -8, true),
            (ISD_AMB_CATTLE_GRID, "cattle grid", 80...1000, -32 ... -14, true),
            (ISD_AMB_DUST_TICKS, "dust ticks", 3000...9000, -48 ... -34, false),
            (ISD_AMB_SHIMMER_HUM, "shimmer hum", 900...2500, -48 ... -36, false),
            (ISD_AMB_FAR_TRUCK, "far truck", 50...400, -46 ... -32, false),
        ]
        for (source, name, band, loudness, byPeak) in table {
            var actions: [Action] = [Self.level(source, 1)]
            if source == ISD_AMB_THUNDER_ROLL { actions.append(Self.queueThunder(1.5, 0.8, at: 3)) }
            if [ISD_AMB_BIRDS_FLEE, ISD_AMB_CATTLE_GRID, ISD_AMB_FAR_TRUCK].contains(source) { actions.append(Self.trigger(source, at: 3)) }
            let seconds = source == ISD_AMB_CATTLE_GRID || source == ISD_AMB_FAR_TRUCK ? 25.0 : 13.0
            let out = Self.render(seconds: seconds, actions: actions)
            let centroid = DSPTestKit.averageCentroid(SynthRender.slice(Self.mid(out), 3, seconds), sampleRate: Self.sr)
            let db = byPeak ? Self.peakDB(out, 3, seconds) : Self.stereoDB(out, 3, seconds)
            XCTAssertTrue(band.contains(centroid), "\(name): centroid \(Int(centroid)) Hz")
            XCTAssertTrue(loudness.contains(db), "\(name): \(String(format: "%.1f", db)) dBFS\(byPeak ? " peak" : "")")
            XCTAssertTrue(out.l.allSatisfy(\.isFinite) && out.r.allSatisfy(\.isFinite), name)
            XCTAssertLessThanOrEqual(max(out.l.map(abs).max() ?? 0, out.r.map(abs).max() ?? 0), 1, name)
        }
    }
}
