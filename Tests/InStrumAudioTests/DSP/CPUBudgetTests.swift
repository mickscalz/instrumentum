import XCTest
import InStrumDSP

/// Real-time budgets (the DSP target is optimised even in debug builds).
final class CPUBudgetTests: XCTestCase {
    typealias R = SynthRender

    private func bestOfThree(_ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
        }
        return best
    }

    func testFeltGlassBudget() {
        var events = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79, 83, 84, 88, 91] { events.append(R.noteOn(0, n, 90)) }
        for i in 0..<32 { events.append(R.noteOn(0.5 + Double(i) / 16, UInt8(60 + i), 90)) }
        let seconds = bestOfThree { _ = R.render(seconds: 10, events: events) }
        XCTAssertLessThan(seconds / 10, 0.05, "Felt Glass used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testHoneyTapeBudget() {
        let chord = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79].map { R.noteOn(0, UInt8($0), 90) }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_HONEY_TAPE, seconds: 10, events: chord) }
        XCTAssertLessThan(seconds / 10, 0.05, "Honey Tape used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testHazeBellsBudget() {
        var run = [R.pedal(0, 127)]
        for i in 0..<24 { run.append(R.noteOn(0.05 + Double(i) * 0.2, UInt8(48 + i * 2 % 36), 100)) }
        let p: [Int: Float] = [Int(ISD_P_ECHO): 1, Int(ISD_P_ORGAN): 0.5]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_HAZE_BELLS, seconds: 10, params: p, events: run) }
        XCTAssertLessThan(seconds / 10, 0.04, "Haze Bells used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    func testCabinFeltBudget() {
        var events = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79] { events.append(R.noteOn(0, n, 90)) }
        for i in 0..<8 { events.append(R.noteOn(0.5 + Double(i), UInt8(72 + i % 5), 90)) }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_CABIN_FELT, seconds: 10, events: events) }
        XCTAssertLessThan(seconds / 10, 0.06, "Cabin Felt used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// The worst case: the wall fully built (30 s of chords at build 1 first, untimed), then a 12-note chord for 10 s.
    func testMorningBoxBudget() throws {
        var best = Double.infinity
        for _ in 0..<3 {
            let s = try XCTUnwrap(isd_synth_create(ISD_ENGINE_MORNING_BOX, R.sr, 256))
            defer { isd_synth_destroy(s) }
            isd_synth_set_param(s, Int32(ISD_P_BUILD), 1)
            var l = [Float](repeating: 0, count: 256), r = l
            func play(_ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { isd_synth_midi(s, $0.baseAddress, Int32($0.count), 0) } }
            func render(_ seconds: Double) { for _ in 0..<Int(seconds * R.sr / 256) { isd_synth_render(s, &l, &r, 256) } }
            let warm: [UInt8] = [61, 65, 68, 73]
            for _ in 0..<30 {
                for n in warm { play([0x90, n, 90]) }
                render(0.95)
                for n in warm { play([0x80, n, 0]) }
                render(0.05)
            }
            for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79] { play([0x90, n, 90]) }
            let start = CFAbsoluteTimeGetCurrent()
            render(10)
            best = min(best, CFAbsoluteTimeGetCurrent() - start)
            XCTAssertGreaterThanOrEqual(isd_synth_debug_count(s, ISD_DEBUG_WALL_UNISON), 5, "the wall should be built up")
        }
        XCTAssertLessThan(best / 10, 0.06, "Morning Box used \(String(format: "%.1f", best * 10))% of real time")
    }

    /// A 12-note chord held for 10 s at the default dials (breath, glass, chorus and shimmer all running).
    func testPolarChoirBudget() {
        let chord = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79].map { R.noteOn(0, UInt8($0), 90) }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_POLAR_CHOIR, seconds: 10, events: chord) }
        XCTAssertLessThan(seconds / 10, 0.06, "Polar Choir used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// A 12-note chord re-struck every 2 s for 10 s at Sparkle 1 (each strike throws a burst of sparks), the tremolo,
    /// phaser and reverb at their defaults.
    func testPlanktonKeysBudget() {
        var events: [R.Event] = []
        let chord: [UInt8] = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79]
        for k in 0..<5 {
            let t = Double(k) * 2
            for n in chord {
                if k > 0 { events.append(R.noteOff(t - 0.01, n)) }
                events.append(R.noteOn(t, n, 90))
            }
        }
        let p: [Int: Float] = [Int(ISD_P_SPARKLE): 1]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_PLANKTON_KEYS, seconds: 10, params: p, events: events) }
        XCTAssertLessThan(seconds / 10, 0.06, "Plankton Keys used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// A 12-note chord held for 10 s with the open strings at full Bloom (every string rings the sympathetic bank).
    func testTeaHouseKotoBudget() {
        let chord = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79].map { R.noteOn(0, UInt8($0), 90) }
        let p: [Int: Float] = [Int(ISD_P_BLOOM): 1]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_TEA_HOUSE_KOTO, seconds: 10, params: p, events: chord) }
        XCTAssertLessThan(seconds / 10, 0.06, "Tea House Koto used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Eight voices held for 10 s with the echo full up (the hard notes bursting with muraiki), breath, yuri, the
    /// bamboo and the open air at their defaults.
    func testZenShakuhachiBudget() {
        let held = [62, 65, 67, 69, 72, 74, 77, 79].map { R.noteOn(0, UInt8($0), $0 % 2 == 0 ? 110 : 120) }
        let p: [Int: Float] = [Int(ISD_P_ECHO): 1]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_ZEN_SHAKUHACHI, seconds: 10, params: p, events: held) }
        XCTAssertLessThan(seconds / 10, 0.06, "Zen Shakuhachi used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// A 12-note chord struck every second for 10 s over a 4-note roll held from the start (it rolls from 0.3 s), at
    /// the default dials (tube, steel and reverb all running).
    func testReefMarimbaBudget() {
        var events = [57, 62, 66, 69].map { R.noteOn(0, UInt8($0), 100) }
        let chord: [UInt8] = [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79]
        for k in 0..<10 { for n in chord { events.append(R.noteOn(0.5 + Double(k), n, 90)) } }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_REEF_MARIMBA, seconds: 10, events: events) }
        XCTAssertLessThan(seconds / 10, 0.06, "Reef Marimba used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Six held low notes for 10 s at Growl .8 (the fold, drive, driven ladder and rumble all running), with a hard
    /// low chord every 2 s setting off the swell (the g++ mirror: about 4–6% of a core on the build machine).
    func testMagmaBassBudget() {
        var events = [28, 35, 40, 47, 52, 59].map { R.noteOn(0, UInt8($0), 110) }
        for k in 1..<5 { for n: UInt8 in [28, 33, 40, 45] { events.append(R.noteOn(Double(k) * 2, n, 120)) } }
        let p: [Int: Float] = [Int(ISD_P_GROWL): 0.8]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_MAGMA_BASS, seconds: 10, params: p, events: events) }
        XCTAssertLessThan(seconds / 10, 0.06, "Magma Bass used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Six brass notes swelling under the hall, over a two-note Chrome arp in sixteenths at 120 BPM, for 10 s (the g++
    /// mirror: about 3% of a core on the build machine).
    func testReplicantBrassBudget() {
        let events = [36, 43, 60, 64, 67, 71, 74, 79].map { R.noteOn(0, UInt8($0), 100) }
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_REPLICANT_BRASS, seconds: 10, events: events) }
        XCTAssertLessThan(seconds / 10, 0.08, "Replicant Brass used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Eight held notes blinking on the arp (Blink .6, 118 BPM) for 10 s with Echo and Ghosts at 0.8: each step
    /// re-plucks a voice while all eight ghosts sing on under them.
    func testBlueDepthBudget() {
        let held = [48, 55, 60, 63, 67, 70, 72, 75].map { R.noteOn(0, UInt8($0), 90) }
        let p: [Int: Float] = [Int(ISD_P_ECHO): 0.8, Int(ISD_P_GHOSTS): 0.8]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_BLUE_DEPTH, seconds: 10, params: p, events: held) }
        XCTAssertLessThan(seconds / 10, 0.06, "Blue Depth used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Endless Rise at its worst (spec §4.3): eight held notes on eight pitch classes, so 64 riser saws over eight pad
    /// voices, for 10 s with Grit .6 and Space .5 (the mirror: 5.3–5.6% of a core on the build machine, where Blue Depth's
    /// budget takes 3.2–4.2%; that one runs at about 2% here in CI).
    func testEndlessRiseBudget() {
        let held = [36, 43, 50, 57, 64, 71, 78, 85].map { R.noteOn(0, UInt8($0), 90) }
        let p: [Int: Float] = [Int(ISD_P_GRIT_ER): 0.6, Int(ISD_P_SPACE): 0.5]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_ENDLESS_RISE, seconds: 10, params: p, events: held) }
        XCTAssertLessThan(seconds / 10, 0.07, "Endless Rise used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// Single Note Grand at the spec's worst (§4.3): a ten-note chord for 10 s with Hall 1 and Morph .5, so every string
    /// sings on and every voice runs its formants and clipper under the longest hall (the mirror: 3.8–3.9% of a core on
    /// the build machine, where Felt Glass's budget chord takes 3.2–3.5%).
    func testSingleNoteGrandBudget() {
        let chord = [36, 43, 48, 52, 55, 60, 64, 67, 71, 76].map { R.noteOn(0, UInt8($0), 90) }
        let p: [Int: Float] = [Int(ISD_P_HALL_SNG): 1, Int(ISD_P_MORPH): 0.5]
        let seconds = bestOfThree { _ = R.render(ISD_ENGINE_SINGLE_NOTE_GRAND, seconds: 10, params: p, events: chord) }
        XCTAssertLessThan(seconds / 10, 0.06, "Single Note Grand used \(String(format: "%.1f", seconds * 10))% of real time")
    }

    /// The cabin's and the bedroom's soundscapes, each heard through the window.
    func testWindowAmbienceBudget() {
        typealias A = AmbienceTests
        let cabin: [A.Action] = [A.level(ISD_AMB_FIRE, 0.7), A.level(ISD_AMB_WIND, 0.5), A.level(ISD_AMB_RAIN_GLASS, 0.4),
                                 A.snowOnGlass(1), A.indoors(1)]
        let bedroom: [A.Action] = [A.level(ISD_AMB_KETTLE, 0.5), A.startKettle(at: 0), A.level(ISD_AMB_STREET, 0.6),
                                   A.level(ISD_AMB_DAWN_CHORUS, 0.6), A.level(ISD_AMB_BREEZE, 0.4), A.level(ISD_AMB_DRIPS, 0.5),
                                   A.level(ISD_AMB_CLOCK, 0.15), A.indoors(1)]
        for (name, scene) in [("cabin", cabin), ("bedroom", bedroom)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: scene) }
            XCTAssertLessThan(seconds / 10, 0.025, "\(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    func testWorldAmbienceBudget() {
        typealias A = AmbienceTests
        var beach: [A.Action] = [ISD_AMB_SURF, ISD_AMB_PALMS, ISD_AMB_GULLS, ISD_AMB_CRICKETS, ISD_AMB_BREEZE, ISD_AMB_RAIN_WATER].map { A.level($0, 1) }
        for t in stride(from: 0.5, to: 10, by: 9) { beach.append(A.wave(0.9, at: t)) }
        var road: [A.Action] = [ISD_AMB_ROAD, ISD_AMB_ENGINE, ISD_AMB_WINDOW_WIND, ISD_AMB_SURF, ISD_AMB_PASSING_CAR, ISD_AMB_RAIN_GLASS].map { A.level($0, 1) }
        road += [A.speed(0.7), A.surfDistance(0.9), A.wave(0.8, at: 2)]
        for (name, actions) in [("beach", beach), ("road", road)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: actions) }
            XCTAssertLessThan(seconds / 10, 0.02, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    /// The fjord's and the bay's soundscapes (spec §4.4).
    func testNightSkyAmbienceBudget() {
        typealias A = AmbienceTests
        let fjord: [A.Action] = [A.level(ISD_AMB_ICE_GROAN, 0.6), A.level(ISD_AMB_WATERFALL, 0.4), A.level(ISD_AMB_WATER, 0.5),
                                 A.level(ISD_AMB_WIND, 0.4), A.level(ISD_AMB_LAPPING, 0.3)]
        let bay: [A.Action] = [A.level(ISD_AMB_LAPPING, 0.7), A.level(ISD_AMB_WATER, 0.3), A.level(ISD_AMB_CRICKETS, 0.5),
                               A.level(ISD_AMB_BOAT, 0.4), A.startBoat(at: 0), A.level(ISD_AMB_BREEZE, 0.4)]
        for (name, scene) in [("fjord", fjord), ("bay", bay)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: scene) }
            XCTAssertLessThan(seconds / 10, 0.025, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    /// The tea house's and the garden's soundscapes (spec §8.1, §9.1), with the bell struck, the kettle on, the
    /// knocker filling and the warbler calling.
    func testStillPlacesAmbienceBudget() {
        typealias A = AmbienceTests
        let teaHouse: [A.Action] = [A.level(ISD_AMB_KETTLE, 0.35), A.startKettle(at: 0), A.level(ISD_AMB_PAPER_SCREENS, 0.4),
                                    A.level(ISD_AMB_TEMPLE_BELL, 0.5), A.strikeBell(at: 0), A.level(ISD_AMB_WIND, 0.15),
                                    A.level(ISD_AMB_RAIN_GLASS, 0.3), A.snowOnGlass(1), A.indoors(0.55)]
        let garden: [A.Action] = [A.level(ISD_AMB_WATER_KNOCKER, 0.6), A.startKnocker(at: 0), A.level(ISD_AMB_WARBLER, 0.5),
                                  A.callWarbler(at: 1), A.level(ISD_AMB_BREEZE, 0.3), A.level(ISD_AMB_CRICKETS, 0.4),
                                  A.level(ISD_AMB_DAWN_CHORUS, 0.3), A.level(ISD_AMB_TEMPLE_BELL, 0.3), A.strikeBell(at: 0),
                                  A.level(ISD_AMB_RAIN_WATER, 0.2)]
        for (name, scene) in [("tea house", teaHouse), ("garden", garden)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: scene) }
            XCTAssertLessThan(seconds / 10, 0.025, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    /// The submarine's and the reef's soundscapes (spec §8.1, §9.1): the submarine at its default depth (0.35) in a storm,
    /// behind its hull, with the sonar pinging, the whale singing and a burst of bubbles; the reef at dusk in the whale
    /// season (the shrimp at the hour's height), with rain and the far surf breaking.
    func testDeepWaterAmbienceBudget() {
        typealias A = AmbienceTests
        let submarine: [A.Action] = [A.level(ISD_AMB_SHIP_HUM, 0.35), A.level(ISD_AMB_AIR_FLOW, 0.3), A.level(ISD_AMB_HULL_TICKS, 0.15),
                                     A.level(ISD_AMB_HULL_CREAK, 0.37), A.level(ISD_AMB_SONAR, 0.5), A.pingSonar(at: 0),
                                     A.level(ISD_AMB_WHALE, 0.3), A.startWhale(at: 0), A.level(ISD_AMB_BUBBLES, 0.15), A.bubbles(0.8, at: 1),
                                     A.level(ISD_AMB_SHRIMP, 0.13), A.level(ISD_AMB_RAIN_WATER, 0.2), A.indoors(0.85), A.closeness(0.7)]
        let reef: [A.Action] = [A.level(ISD_AMB_SHRIMP, 0.88), A.level(ISD_AMB_FISH_CHORUS, 0.4), A.level(ISD_AMB_SURF, 0.3),
                                A.surfDistance(0.9), A.wave(0.6, at: 1), A.level(ISD_AMB_LAPPING, 0.45), A.level(ISD_AMB_BREEZE, 0.4),
                                A.level(ISD_AMB_GULLS, 0.15), A.level(ISD_AMB_WHALE, 0.3), A.startWhale(at: 0), A.level(ISD_AMB_BUBBLES, 0.15),
                                A.bubbles(0.5, at: 2), A.level(ISD_AMB_RAIN_WATER, 0.3), A.closeness(0.55)]
        for (name, scene) in [("submarine", submarine), ("reef", reef)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: scene) }
            XCTAssertLessThan(seconds / 10, 0.025, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    /// Supercell Sky's and Lightning Plains' soundscapes (Storms spec §8.3, §9.3), each < 2.5%: the storm family in full
    /// cry with four strikes' thunder rolling, the gust front's wind and the rain; the plains at dusk with a truck crossing
    /// the grid, a far truck passing and two far rolls. (The g++ mirror: 3.3–3.7% and 3.6–4.1% of a core on the build
    /// machine, which runs these scenes 2.3–2.5 times slower than CI: about 1.5% each there.)
    func testStormAmbienceBudget() {
        typealias A = AmbienceTests
        let supercell: [A.Action] = [A.level(ISD_AMB_GRASS_WIND, 0.8), A.level(ISD_AMB_HAIL_TIN, 0.6), A.level(ISD_AMB_BIRDS_FLEE, 0.5),
                                     A.level(ISD_AMB_THUNDER_ROLL, 1), A.level(ISD_AMB_INFLOW_ROAR, 0.7), A.level(ISD_AMB_RAIN_ON_DUST, 0.5),
                                     A.level(ISD_AMB_WIND, 0.5), A.level(ISD_AMB_RAIN_WATER, 0.3), A.queueThunder(0.6, 1, at: 0),
                                     A.queueThunder(3, 0.8, at: 1), A.queueThunder(9, 0.6, at: 2), A.queueThunder(4.5, 0.9, at: 4), A.closeness(0.5)]
        let plains: [A.Action] = [A.level(ISD_AMB_DRY_CICADAS, 0.8), A.level(ISD_AMB_WINDMILL, 0.6), A.level(ISD_AMB_CATTLE_GRID, 0.5),
                                  A.trigger(ISD_AMB_CATTLE_GRID, at: 0.5), A.level(ISD_AMB_DUST_TICKS, 0.5), A.level(ISD_AMB_SHIMMER_HUM, 0.4),
                                  A.level(ISD_AMB_FAR_TRUCK, 0.5), A.trigger(ISD_AMB_FAR_TRUCK, at: 0), A.level(ISD_AMB_THUNDER_ROLL, 1),
                                  A.queueThunder(12, 0.6, at: 0), A.queueThunder(7, 0.7, at: 2), A.level(ISD_AMB_RAIN_ON_DUST, 0.4),
                                  A.level(ISD_AMB_BREEZE, 0.4), A.level(ISD_AMB_CRICKETS, 0.3), A.closeness(0.55)]
        for (name, scene) in [("supercell", supercell), ("plains", plains)] {
            let seconds = bestOfThree { _ = A.render(seconds: 10, actions: scene) }
            XCTAssertLessThan(seconds / 10, 0.025, "the \(name) ambience used \(String(format: "%.1f", seconds * 10))% of real time")
        }
    }

    /// Felt Glass and Orbit Pad with all 50 ambience sources at 0.6 (the sonar pinging, the whale singing, a burst of
    /// bubbles, the birds taking flight, a truck crossing the grid, a far truck passing and four rolls of thunder). (The g++
    /// mirror: 19.3–21.0% on the build machine against 15.3–17.2% for the 38 before, which CI ran in 6.9%: about 8–8.5%
    /// there.)
    func testCombinedBudget() {
        var felt = [R.pedal(0, 127)]
        for n: UInt8 in [36, 43, 48, 52, 55, 60, 64, 67, 71, 72, 76, 79, 83, 84, 88, 91] { felt.append(R.noteOn(0, n, 90)) }
        let pad = [48, 55, 60, 63, 67, 70, 72, 75].map { R.noteOn(0, UInt8($0), 90) }
        XCTAssertEqual(ISD_AMB_COUNT.rawValue, 50)
        let playing = Int(ISD_AMB_COUNT.rawValue)
        var ambience: [AmbienceTests.Action] = (0..<playing).map { AmbienceTests.level(ISDAmbienceSource(UInt32($0)), 0.6) }
        ambience += [AmbienceTests.pingSonar(at: 0), AmbienceTests.startWhale(at: 0), AmbienceTests.bubbles(0.8, at: 1)]
        ambience += [ISD_AMB_BIRDS_FLEE, ISD_AMB_CATTLE_GRID, ISD_AMB_FAR_TRUCK].map { AmbienceTests.trigger($0, at: 0.5) }
        ambience += (0..<4).map { AmbienceTests.queueThunder(0.5 + 2 * Float($0), 0.8, at: 0.2) }
        let seconds = bestOfThree {
            _ = R.render(seconds: 10, events: felt)
            _ = R.render(ISD_ENGINE_ORBIT_PAD, seconds: 10, events: pad)
            _ = AmbienceTests.render(seconds: 10, actions: ambience)
        }
        XCTAssertLessThan(seconds / 10, 0.11, "Felt Glass + Orbit Pad + ambience used \(String(format: "%.1f", seconds * 10))% of real time")
    }
}
