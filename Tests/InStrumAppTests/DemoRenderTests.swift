import XCTest
import AVFoundation
@testable import InStrumApp
@testable import InStrumCore
import InStrumDSP

/// Writes demo audio and spectrograms when DEMO_DIR is set (CI previews and releases).
@MainActor
final class DemoRenderTests: XCTestCase {
    nonisolated static let rate = 48_000.0

    /// Renders a phrase through the Sound Core (stereo, interleaving left then right).
    nonisolated static func render(_ engine: ISDEngine, _ phrase: [(time: Double, message: MIDIMessage)], tail: Double = 4) -> (l: [Float], r: [Float])? {
        guard let synth = isd_synth_create(engine, rate, 512) else { return nil }
        defer { isd_synth_destroy(synth) }
        let total = Int(((phrase.last?.time ?? 0) + tail) * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var e = 0, i = 0
        while i < total {
            let n = min(block, total - i)
            while e < phrase.count, Int(phrase[e].time * rate) < i + n {
                let bytes = phrase[e].message.bytes
                bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), Int32(max(0, Int(phrase[e].time * rate) - i))) }
                e += 1
            }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_synth_render(synth, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (l, r)
    }

    nonisolated static func writeWAV(_ audio: (l: [Float], r: [Float]), to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.l.count))!
        buffer.frameLength = AVAudioFrameCount(audio.l.count)
        audio.l.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.l.count) }
        audio.r.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: audio.r.count) }
        try file.write(from: buffer)
    }

    func testWriteDemoAudio() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] else { throw XCTSkip("DEMO_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let demos: [(String, ISDEngine, [(time: Double, message: MIDIMessage)])] = [
            ("felt-glass", ISD_ENGINE_FELT_GLASS, DemoPhrases.feltGlass),
            ("orbit-pad", ISD_ENGINE_ORBIT_PAD, DemoPhrases.orbitPad),
            ("honey-tape", ISD_ENGINE_HONEY_TAPE, DemoPhrases.honeyTape),
            ("haze-bells", ISD_ENGINE_HAZE_BELLS, DemoPhrases.hazeBells),
            ("cabin-felt", ISD_ENGINE_CABIN_FELT, DemoPhrases.cabinFelt),
            ("morning-box", ISD_ENGINE_MORNING_BOX, DemoPhrases.morningBox),
            ("polar-choir", ISD_ENGINE_POLAR_CHOIR, DemoPhrases.polarChoir),
            ("plankton-keys", ISD_ENGINE_PLANKTON_KEYS, DemoPhrases.planktonKeys),
            ("tea-house-koto", ISD_ENGINE_TEA_HOUSE_KOTO, DemoPhrases.teaHouseKoto),
            ("zen-shakuhachi", ISD_ENGINE_ZEN_SHAKUHACHI, DemoPhrases.zenShakuhachi),
            ("reef-marimba", ISD_ENGINE_REEF_MARIMBA, DemoPhrases.reefMarimba),
            ("blue-depth", ISD_ENGINE_BLUE_DEPTH, DemoPhrases.blueDepth),
        ]
        var written = 0
        for (name, engine, phrase) in demos {
            guard let audio = Self.render(engine, phrase, tail: 6) else { continue }   // engine not built yet
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let wav = url.appendingPathComponent("\(name)-demo.wav")
            try Self.writeWAV(audio, to: wav)
            let png = url.appendingPathComponent("\(name)-spectrogram.png")
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500), to: png)
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
            written += 1
        }
        XCTAssertGreaterThanOrEqual(written, 1)
    }

    /// Reef Marimba's demo (spec §11) renders finite and well under full scale (under the limiter's 0.9 too, so nothing is
    /// squashed), and rolls only where it means to. Rendered again with the rolls off (the test hook), it is the same
    /// sample for sample until its one long note has been held 0.3 s; the roll then adds strokes, which swell as the
    /// pressure rises; and once the long note is let go and its strokes have rung out, the two are the same again, so no
    /// other note rolled. (The g++ mirror: peak 0.285; the strokes 12.5 dB louder over the roll's last half second than
    /// its first; from 3 s after the release the two differ by at most −139 dB.)
    func testReefMarimbaDemoRenders() throws {
        let phrase = DemoPhrases.reefMarimba
        func render(rolls: Bool) -> (l: [Float], r: [Float]) {
            guard let synth = isd_synth_create(ISD_ENGINE_REEF_MARIMBA, Self.rate, 512) else { return ([], []) }
            defer { isd_synth_destroy(synth) }
            if !rolls { isd_synth_set_param(synth, Int32(ISD_P_DEBUG_NO_ROLL), 1) }
            let total = Int(((phrase.last?.time ?? 0) + 6) * Self.rate), block = 256
            var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
            var e = 0, i = 0
            while i < total {
                let n = min(block, total - i)
                while e < phrase.count, Int(phrase[e].time * Self.rate) < i + n {
                    let offset = Int32(max(0, Int(phrase[e].time * Self.rate) - i))
                    phrase[e].message.bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), offset) }
                    e += 1
                }
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in isd_synth_render(synth, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
                }
                i += n
            }
            return (l, r)
        }
        let rolled = render(rolls: true), still = render(rolls: false)
        XCTAssertFalse(rolled.l.isEmpty, "Reef Marimba is not in the Sound Core")
        guard !rolled.l.isEmpty, rolled.l.count == still.l.count else { return }
        XCTAssertTrue(rolled.l.allSatisfy(\.isFinite) && rolled.r.allSatisfy(\.isFinite))
        let peak = max(rolled.l.map(abs).max() ?? 0, rolled.r.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.6, "well under full scale")
        // The long note: the one held longest.
        var down: [UInt8: Double] = [:], long: (on: Double, off: Double) = (0, 0)
        for (t, m) in phrase {
            if case let .noteOn(_, n, _) = m { down[n] = t }
            if case let .noteOff(_, n, _) = m, let on = down[n], t - on > long.off - long.on { long = (on, t) }
        }
        // Until its first stroke, sample for sample the same.
        let due = Int(long.on * Self.rate) + Int((0.3 * Self.rate).rounded())
        var before: Float = 0
        for k in 0..<min(due, rolled.l.count) {
            before = max(before, abs(rolled.l[k] - still.l[k]), abs(rolled.r[k] - still.r[k]))
        }
        XCTAssertLessThan(before, 1e-6, "nothing rolls before the long note")
        /// The strokes the rolls add between `a` and `b` seconds (dB RMS, both channels).
        func strokes(_ a: Double, _ b: Double) -> Double {
            let i0 = min(rolled.l.count, Int(a * Self.rate)), i1 = min(rolled.l.count, Int(b * Self.rate))
            var sum = 0.0
            for k in i0..<max(i0, i1) {
                let dl = Double(rolled.l[k]) - Double(still.l[k]), dr = Double(rolled.r[k]) - Double(still.r[k])
                sum += dl * dl + dr * dr
            }
            return 10 * log10(max(sum / Double(max(1, 2 * (i1 - i0))), 1e-30))
        }
        let early = strokes(long.on + 0.35, long.on + 0.85), late = strokes(long.off - 0.5, long.off)
        XCTAssertGreaterThan(early, -60, "the long note rolls")
        XCTAssertGreaterThan(late - early, 6, "and the pressure swells the roll")
        XCTAssertLessThan(strokes(long.off + 3, Double(rolled.l.count) / Self.rate), -100, "no other note rolls")
    }

    /// For each sixteenth `k` of an arp grid that starts at `start` (seconds), the power of the 15 ms after the step
    /// against the 15 ms before it (dB): a blinking arp re-plucks a note on every step.
    nonisolated static func stepRises(_ x: [Float], start: Double, step: Double, steps: ClosedRange<Int>) -> [Double] {
        let w = Int((0.015 * rate).rounded())
        func power(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(b, x.count)
            guard lo < hi else { return 0 }
            var sum = 0.0
            for i in lo..<hi { sum += Double(x[i]) * Double(x[i]) }
            return sum / Double(hi - lo)
        }
        return steps.map { (k: Int) -> Double in
            let at = Int(((start + Double(k) * step) * rate).rounded(.down))
            return 10 * log10(max(power(at, at + w), 1e-30) / max(power(at - w, at), 1e-30))
        }
    }

    /// Blue Depth's demo, F♯ minor at 118 (DemoPhrases.blueDepth): a chord from C3 up held for the arp to blink, big
    /// bass hits below C3, a pressure swell, and everything let go at the end. Rendered as the release renders it, it
    /// stays finite and well under full scale, and the arp blinks: through the held chord at least 60% of the sixteenths
    /// re-attack by 1.5 dB or more (77% on the mirror, against 13% for the same phrase at Blink 0).
    func testBlueDepthDemoRenders() throws {
        let phrase = DemoPhrases.blueDepth
        let fSharpMinor: Set<Int> = [6, 8, 9, 11, 1, 2, 4, 5]   // F♯ G♯ A B C♯ D E, and the C♯ chord's E♯
        var held = Set<UInt8>(), bass = 0, chord = 0, swell: UInt8 = 0, pressure: UInt8 = 0, wheel: UInt16 = 8192
        for (_, m) in phrase {
            switch m {
            case let .noteOn(_, n, _):
                XCTAssertTrue(fSharpMinor.contains(Int(n) % 12), "note \(n) is outside F♯ minor")
                if n < 48 { bass += 1 } else { chord += 1 }
                held.insert(n)
            case let .noteOff(_, n, _): held.remove(n)
            case let .channelPressure(_, p): swell = max(swell, p); pressure = p
            case let .pitchBend(_, v): wheel = v
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(bass, 4, "a left-hand bass below C3")
        XCTAssertGreaterThanOrEqual(chord, 3, "a chord from C3 up for the arp")
        XCTAssertGreaterThan(swell, 90, "a real pressure swell")
        XCTAssertTrue(held.isEmpty, "everything let go")
        XCTAssertEqual(pressure, 0)
        XCTAssertEqual(wheel, 8192)
        XCTAssertGreaterThan(phrase.last?.time ?? 0, 18)

        let audio = try XCTUnwrap(Self.render(ISD_ENGINE_BLUE_DEPTH, phrase, tail: 6))
        XCTAssertTrue(audio.l.allSatisfy { $0.isFinite } && audio.r.allSatisfy { $0.isFinite })
        let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.85, "well under full scale and the limiter's 0.9 (0.74 on the mirror)")
        XCTAssertGreaterThan(peak, 0.1)
        // The arp's grid starts on the phrase's first note; the chord is held for 144 sixteenths.
        let mono = zip(audio.l, audio.r).map { $0.0 + $0.1 }
        let rises = Self.stepRises(mono, start: phrase.first?.time ?? 0, step: 15.0 / 118, steps: 1...143)
        let blinking = rises.filter { $0 >= 1.5 }.count
        XCTAssertGreaterThanOrEqual(Double(blinking), 0.6 * Double(rises.count), "only \(blinking) of \(rises.count) sixteenths re-attack")
        let median = rises.sorted()[rises.count / 2]
        XCTAssertGreaterThanOrEqual(median, 1.5, "the median sixteenth rises \(median) dB")
    }

    /// Renders the ambience alone (levels glide in over 2.5 s, as in the app).
    nonisolated static func renderAmbience(_ levels: [(ISDAmbienceSource, Float)], seconds: Double, nightCool: Float = 0,
                                           waves: [Wave] = [], speed: Float = 0, surfDistance: Float = 0, indoors: Float = 0,
                                           snowOnGlass: Float = 0, kettleAt: Double? = nil,
                                           boatAt: Double? = nil, bellAt: Double? = nil,
                                           knockerAt: Double? = nil, key: (root: Int32, major: Int32)? = nil,
                                           sonarAt: Double? = nil,
                                           bubbles: (at: Double, strength: Float)? = nil) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(rate, 512, 7) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        for (source, level) in levels { isd_ambience_set_level(a, source, level) }
        isd_ambience_set_night_cool(a, nightCool)
        isd_ambience_set_speed(a, speed)
        isd_ambience_set_surf_distance(a, surfDistance)
        isd_ambience_set_indoors(a, indoors)
        isd_ambience_set_snow_on_glass(a, snowOnGlass)
        if let key { isd_ambience_set_key(a, key.root, key.major) }
        var kettlePending = kettleAt, boatPending = boatAt, bellPending = bellAt, knockerPending = knockerAt
        var sonarPending = sonarAt, bubblesPending = bubbles
        let total = Int(seconds * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0, nextWave = 0
        while i < total {
            let n = min(block, total - i)
            while nextWave < waves.count, Int(waves[nextWave].breakTime * rate) < i + n {
                isd_ambience_trigger_wave(a, waves[nextWave].strength); nextWave += 1
            }
            if let k = kettlePending, Int(k * rate) < i + n { isd_ambience_debug_start_kettle(a); kettlePending = nil }
            if let b = boatPending, Int(b * rate) < i + n { isd_ambience_debug_start_boat(a); boatPending = nil }
            if let b = bellPending, Int(b * rate) < i + n { isd_ambience_debug_strike_bell(a); bellPending = nil }
            if let k = knockerPending, Int(k * rate) < i + n { isd_ambience_debug_start_knocker(a); knockerPending = nil }
            if let p = sonarPending, Int(p * rate) < i + n { isd_ambience_debug_ping_sonar(a); sonarPending = nil }
            if let b = bubblesPending, Int(b.at * rate) < i + n { isd_ambience_trigger_bubbles(a, b.strength); bubblesPending = nil }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        return (l, r)
    }

    /// The deep-water ambience demos (Sets 11 & 12 spec §11), mixed as the worlds mix them (`SubmarineWindowModel`'s
    /// ambience and `GreatBarrierReefModel.levels`), from the start, `seconds` long.
    /// - `submarine-window-ambience`: aboard at the default depth (0.35, 65 m: too deep for the shallows' shrimp and
    ///   rain), heard through the hull (indoors 0.85): the machinery's hum, the scrubbers' air and the hull's ticks, the
    ///   hull settling (0.25 + 0.35 × depth), a humpback far off (0.2 + 0.15 × 0.7, near its mid-depth best) and the
    ///   bubbles' bed; the sonar in F♯ minor (Blue Depth's demo's key, and "Underwater"'s), pinged at 3 s once its level
    ///   has glided in, so it rings F♯6; and an accent's burst of bubbles at 8 s (strength 0.8, a hard note's).
    /// - `great-barrier-reef-ambience`: the reef at dusk (the sun 4° down, in November, so no humpbacks) from the
    ///   waterline, outdoors: the snapping shrimp at their twilight rate (0.55 × 1.6), the fish chorus's dusk drumming at
    ///   its peak (0.4), the far reef crest's surf with the swell breaking on it, the lapping at the waterline, the
    ///   breeze and the bubbles' bed.
    nonisolated static func deepWaterAmbience(_ name: String, seconds: Double) -> (l: [Float], r: [Float]) {
        switch name {
        case "submarine-window-ambience":
            let depth = 0.35, midDepth = 1 - abs(depth - 0.5) * 2
            return renderAmbience([(ISD_AMB_SHIP_HUM, 0.35), (ISD_AMB_AIR_FLOW, 0.3), (ISD_AMB_HULL_TICKS, 0.15),
                                   (ISD_AMB_HULL_CREAK, Float(0.25 + 0.35 * depth)), (ISD_AMB_SONAR, 0.5),
                                   (ISD_AMB_WHALE, Float(0.2 + 0.15 * midDepth)), (ISD_AMB_BUBBLES, 0.15)],
                                  seconds: seconds, indoors: Float(SubmarineWindowModel.indoors), key: (root: 6, major: 0),
                                  sonarAt: 3, bubbles: (at: 8, strength: 0.8))
        case "great-barrier-reef-ambience":
            var swell = OceanSwell(seed: 5)
            var waves: [Wave] = []
            for _ in 0..<Int(seconds * 60) { waves += swell.step(dt: 1.0 / 60) }
            return renderAmbience([(ISD_AMB_SHRIMP, Float(GreatBarrierReefModel.shrimpLevel * 1.6)),
                                   (ISD_AMB_FISH_CHORUS, Float(GreatBarrierReefModel.fishPeak)), (ISD_AMB_SURF, 0.3),
                                   (ISD_AMB_LAPPING, 0.45), (ISD_AMB_BREEZE, 0.25), (ISD_AMB_BUBBLES, 0.15)],
                                  seconds: seconds, waves: waves, surfDistance: 0.9)
        default:
            return ([], [])
        }
    }
    nonisolated static let deepWaterScenes = ["submarine-window-ambience", "great-barrier-reef-ambience"]

    /// The power (dB) of `x` at `hz` between `t0` and `t1` seconds (a Goertzel bin).
    nonisolated static func toneDB(_ x: [Float], hz: Double, from t0: Double, to t1: Double) -> Double {
        let a = max(0, Int(t0 * rate)), b = min(x.count, Int(t1 * rate))
        guard a < b else { return -300 }
        let c = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b {
            let v = Double(x[i]) + c * s1 - s2
            s2 = s1; s1 = v
        }
        let n = Double(b - a)
        return 10 * log10(max((s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n), 1e-30))
    }

    /// The deep-water demos render as the release renders them (here their first 12 s): finite, under full scale and
    /// audible, and the submarine's sonar, pinged at 3 s, rings in the demo's key, F♯6 (1480 Hz), not its default E6,
    /// well above the moment before. (On the mirror, g++ and clang++ with FMA contraction, over the whole minute: the
    /// submarine peaks at 0.14–0.15 (about −17 dBFS) with an RMS of −30.8 dBFS, and the ping's first 0.3 s sit 19.5 dB
    /// over E6 and 17 dB over the same bin just before it; the reef at dusk peaks at 0.70 (−3.1 dBFS, a snapping shrimp's
    /// loudest snap) with an RMS of −24.8 dBFS.)
    func testDeepWaterAmbienceDemosRender() {
        for name in Self.deepWaterScenes {
            let audio = Self.deepWaterAmbience(name, seconds: 12)
            XCTAssertEqual(audio.l.count, Int(12 * Self.rate), name)
            XCTAssertTrue(audio.l.allSatisfy(\.isFinite) && audio.r.allSatisfy(\.isFinite), name)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThan(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -50, name)
        }
        let sub = Self.deepWaterAmbience("submarine-window-ambience", seconds: 4)
        let fSharp6 = 1479.98, e6 = 1318.51
        let ping = Self.toneDB(sub.l, hz: fSharp6, from: 3.0, to: 3.3)
        XCTAssertGreaterThan(ping - Self.toneDB(sub.l, hz: e6, from: 3.0, to: 3.3), 10, "the ping is in F♯, not E")
        XCTAssertGreaterThan(ping - Self.toneDB(sub.l, hz: fSharp6, from: 2.5, to: 2.8), 10, "the ping lands at 3 s")
    }

    func testWriteAmbienceDemos() throws {
        guard let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] else { throw XCTSkip("DEMO_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var swell = OceanSwell(seed: 5)
        var waves: [Wave] = []
        for _ in 0..<(60 * 60) { waves += swell.step(dt: 1.0 / 60) }
        let scenes: [(String, [(ISDAmbienceSource, Float)], Float, [Wave], Float, Float)] = [
            ("moonlit-lake-ambience", [(ISD_AMB_WATER, 0.8), (ISD_AMB_CRICKETS, 0.7), (ISD_AMB_BREEZE, 0.4), (ISD_AMB_OWL, 0.3)], 0.3, [], 0, 0),
            ("spaceship-lounge-ambience", [(ISD_AMB_SHIP_HUM, 0.8), (ISD_AMB_AIR_FLOW, 0.5), (ISD_AMB_CHIME, 0.3), (ISD_AMB_HULL_TICKS, 0.3)], 0, [], 0, 0),
            ("golden-hour-beach-ambience", [(ISD_AMB_SURF, 0.9), (ISD_AMB_PALMS, 0.45), (ISD_AMB_BREEZE, 0.35), (ISD_AMB_CRICKETS, 0.25)], 0.1, waves, 0, 0.15),
            ("coast-road-ambience", [(ISD_AMB_ROAD, 0.8), (ISD_AMB_ENGINE, 0.6), (ISD_AMB_WINDOW_WIND, 0.5), (ISD_AMB_SURF, 0.5), (ISD_AMB_PASSING_CAR, 0.3)], 0, waves, 0.5, 0.9),
        ]
        // The window worlds: heard indoors through the glass.
        let indoorScenes: [(String, [(ISDAmbienceSource, Float)], Float, Double?)] = [
            ("snowbound-cabin-ambience", [(ISD_AMB_FIRE, 0.7), (ISD_AMB_WIND, 0.4), (ISD_AMB_RAIN_GLASS, 0.3)], 1, nil),
            ("bedroom-dawn-ambience", [(ISD_AMB_DAWN_CHORUS, 0.6), (ISD_AMB_KETTLE, 0.5), (ISD_AMB_STREET, 0.5), (ISD_AMB_BREEZE, 0.35),
                                       (ISD_AMB_DRIPS, 0.4), (ISD_AMB_CLOCK, 0.15)], 0, 2),
        ]
        for (name, levels, snow, kettle) in indoorScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: 1, snowOnGlass: snow, kettleAt: kettle)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        // The night waters (outdoors): the fjord's ice and far waterfall; the bay's lapping, with a boat passing at 2 s.
        let nightScenes: [(String, [(ISDAmbienceSource, Float)], Double?)] = [
            ("aurora-fjord-ambience", [(ISD_AMB_ICE_GROAN, 0.6), (ISD_AMB_WATERFALL, 0.35), (ISD_AMB_WATER, 0.5), (ISD_AMB_WIND, 0.3),
                                       (ISD_AMB_LAPPING, 0.3)], nil),
            ("bioluminescent-bay-ambience", [(ISD_AMB_LAPPING, 0.7), (ISD_AMB_WATER, 0.3), (ISD_AMB_CRICKETS, 0.5), (ISD_AMB_BOAT, 0.4),
                                             (ISD_AMB_BREEZE, 0.3), (ISD_AMB_OWL, 0.15)], 2),
        ]
        for (name, levels, boat) in nightScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: 0, boatAt: boat)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        // The still places. The tea house at a snowy dusk (the Snow weather) with its screens half open, heard through the
        // paper (indoors 0.8 − 0.5 × 0.5): the draught's rustle (0.4 × (0.4 + wind 0.25)), snow ticking on the paper
        // (0.8 × the paper's 0.55), the iron kettle warming from 2 s, and the temple bell struck at 3 s, once its level has
        // glided in, on E (the ambience's key until one is played, and the koto demo's). The garden on a spring morning,
        // outdoors: the water-knocker, starting empty at 2 s, fills, tips and clacks on its stone, then fills again (one
        // whole cycle inside the minute); the warbler calls on its own.
        let stillScenes: [(String, [(ISDAmbienceSource, Float)], Float, Float, Double?, Double?, Double?)] = [
            ("tea-house-snow-ambience", [(ISD_AMB_KETTLE, 0.35), (ISD_AMB_PAPER_SCREENS, 0.26), (ISD_AMB_TEMPLE_BELL, 0.5),
                                         (ISD_AMB_WIND, 0.3), (ISD_AMB_RAIN_GLASS, 0.44)], 0.55, 0.8, 2, 3, nil),
            ("zen-rock-garden-ambience", [(ISD_AMB_WATER_KNOCKER, 0.6), (ISD_AMB_WARBLER, 0.5), (ISD_AMB_BREEZE, 0.35),
                                          (ISD_AMB_DAWN_CHORUS, 0.3), (ISD_AMB_TEMPLE_BELL, 0.3)], 0, 0, nil, nil, 2),
        ]
        for (name, levels, indoors, snow, kettle, bell, knocker) in stillScenes {
            let audio = Self.renderAmbience(levels, seconds: 60, indoors: indoors, snowOnGlass: snow, kettleAt: kettle,
                                            bellAt: bell, knockerAt: knocker)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        // The deep water: the submarine aboard with a sonar ping and a burst of bubbles, the reef at dusk.
        for name in Self.deepWaterScenes {
            let audio = Self.deepWaterAmbience(name, seconds: 60)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
        for (name, levels, cool, waves, speed, distance) in scenes {
            let audio = Self.renderAmbience(levels, seconds: 60, nightCool: cool, waves: waves, speed: speed, surfDistance: distance)
            let peak = max(audio.l.map(abs).max() ?? 0, audio.r.map(abs).max() ?? 0)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let rms = (audio.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.l.count))).squareRoot()
            XCTAssertGreaterThan(20 * log10(max(rms, 1e-10)), -60, name)
            try Self.writeWAV(audio, to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: audio.l, sampleRate: Self.rate, width: 1400, height: 500),
                                         to: url.appendingPathComponent("\(name)-spectrogram.png"))
        }
    }

    func testSpectrogramShowsATone() {
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / Self.rate)) * 0.5 }
        let image = Spectrogram.image(left: tone, sampleRate: Self.rate, width: 200, height: 100)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0.0005)
    }
}
