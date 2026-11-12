import XCTest
import AVFoundation
@testable import InStrumApp
@testable import InStrumAudio
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
            ("single-note-grand", ISD_ENGINE_SINGLE_NOTE_GRAND, DemoPhrases.singleNoteGrand),
            ("blue-depth", ISD_ENGINE_BLUE_DEPTH, DemoPhrases.blueDepth),
            ("endless-rise", ISD_ENGINE_ENDLESS_RISE, DemoPhrases.endlessRise),
        ]
        var written = 0
        for (name, engine, phrase) in demos {
            // Endless Rise's drop is Excitement's: its demo is played as the app plays it.
            let played: (l: [Float], r: [Float])? = engine == ISD_ENGINE_ENDLESS_RISE
                ? Self.renderPlayed(engine, phrase, tail: 6).map { (l: $0.l, r: $0.r) } : nil
            guard let audio = played ?? Self.render(engine, phrase, tail: 6) else { continue }   // engine not built yet
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

    /// Single Note Grand's demo, D minor at 86 (DemoPhrases.singleNoteGrand): one note, D5, struck alone on the eighths
    /// for two bars and on through two more as a low D and a low B♭ join it; then it opens into chords (G minor, an A
    /// suspended chord over which it is held and pressed into, falling to C♯ as the chord resolves to A under the
    /// pressure) and a D minor chord with the D on top rings out. Original material, nothing quoted from any record.
    /// Rendered as the release renders it: finite and well under full scale (0.30 on the g++ mirror); the grand hears the
    /// one note repeated from its fourth strike (within 3 ms on the mirror) all through the first two bars; the swell
    /// turns the piano into a voice: the morph it reads back rises from nothing to .85 or more (.898) and is back under .01
    /// a second into the last chord; rendered again as the piano alone (the test hook) it is the same to the sample until
    /// the swell begins, the voice is most of the sound at the swell's top (the difference within 6 dB of the whole; 1.4 on
    /// the mirror), and it is gone in the last chord (25 dB or more under; 47.5).
    func testSingleNoteGrandDemoRenders() throws {
        let phrase = DemoPhrases.singleNoteGrand
        let beat = 60.0 / 86
        let dMinor: Set<Int> = [2, 4, 5, 7, 9, 10, 0, 1]   // D E F G A B♭ C, and the A chord's C♯
        var held = Set<UInt8>(), pressure: UInt8 = 0, swell: UInt8 = 0
        var onsets: [(t: Double, n: UInt8)] = []
        for (time, m) in phrase {
            switch m {
            case let .noteOn(_, n, _):
                XCTAssertTrue(dMinor.contains(Int(n) % 12), "note \(n) is outside D minor")
                held.insert(n)
                onsets.append((t: time, n: n))
            case let .noteOff(_, n, _): held.remove(n)
            case let .channelPressure(_, p): swell = max(swell, p); pressure = p
            case .pitchBend: XCTFail("the wheel isn't used")
            default: break
            }
        }
        XCTAssertTrue(held.isEmpty, "everything let go")
        XCTAssertEqual(pressure, 0)
        XCTAssertGreaterThan(swell, 100, "a real pressure swell")
        XCTAssertGreaterThan(phrase.last?.time ?? 0, 20)
        func t(_ beats: Double) -> Double { (phrase.first?.time ?? 0) + beats * beat }
        // One repeated note: the first two bars are sixteen strikes of D5 alone, on the eighths at 86.
        let opening = onsets.filter { $0.t < t(8) - 1e-6 }
        XCTAssertEqual(opening.count, 16)
        XCTAssertTrue(opening.allSatisfy { $0.n == 74 }, "D5, and only D5")
        for (a, b) in zip(opening, opening.dropFirst()) { XCTAssertEqual(b.t - a.t, beat / 2, accuracy: 1e-9) }
        // It opens into chords: three or more keys struck together (each within 30 ms of the last), at least three times.
        var chords = 0, run = 1
        for (a, b) in zip(onsets, onsets.dropFirst()) {
            if b.t - a.t <= 0.030 { run += 1 } else { if run >= 3 { chords += 1 }; run = 1 }
        }
        if run >= 3 { chords += 1 }
        XCTAssertGreaterThanOrEqual(chords, 3, "it opens into chords")

        /// Renders the phrase as the release renders it (256-sample blocks), as played or as the piano alone, with after
        /// each block whether the grand hears a repeat and the morph it is using.
        func render(pianoOnly: Bool) -> (l: [Float], r: [Float], repeating: [Bool], morph: [Float])? {
            guard let synth = isd_synth_create(ISD_ENGINE_SINGLE_NOTE_GRAND, Self.rate, 512) else { return nil }
            defer { isd_synth_destroy(synth) }
            if pianoOnly { isd_synth_set_param(synth, Int32(ISD_P_DEBUG_SNG_PIANO_ONLY), 1) }
            let total = Int(((phrase.last?.time ?? 0) + 6) * Self.rate), block = 256
            var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
            var repeating: [Bool] = [], morph: [Float] = []
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
                repeating.append(isd_synth_debug_is_repeating(synth) != 0)
                morph.append(Float(isd_synth_debug_count(synth, ISD_DEBUG_MORPH_PERMILLE)) / 1000)
                i += n
            }
            return (l, r, repeating, morph)
        }
        let played = try XCTUnwrap(render(pianoOnly: false), "Single Note Grand is not in the Sound Core")
        let piano = try XCTUnwrap(render(pianoOnly: true))
        XCTAssertTrue(played.l.allSatisfy(\.isFinite) && played.r.allSatisfy(\.isFinite))
        let peak = max(played.l.map(abs).max() ?? 0, played.r.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.85, "well under full scale and the limiter's 0.9")
        XCTAssertGreaterThan(peak, 0.1)
        /// The block that holds the sample at `time`.
        func block(_ time: Double) -> Int { min(played.morph.count - 1, max(0, Int(time * Self.rate) / 256)) }

        // The grand hears the one note repeated from its fourth strike, all through the first two bars.
        let fourth = opening.count > 3 ? opening[3].t : 0
        XCTAssertFalse(played.repeating[block(fourth) - 1], "not before the fourth strike")
        XCTAssertTrue((block(fourth + 0.01)...block(t(8) - 0.01)).allSatisfy { played.repeating[$0] }, "from the fourth strike through bar 2")

        // The swell turns the piano into a voice, and lets it go.
        let calm = played.morph[..<block(t(20))].max() ?? 1
        XCTAssertLessThan(calm, 0.005, "no morph before the swell")
        XCTAssertGreaterThanOrEqual(played.morph.max() ?? 0, 0.85, "the voice")
        let after = played.morph[block(t(28) + 1)...].max() ?? 1
        XCTAssertLessThan(after, 0.01, "let go")
        /// Mean power of `x` from `a` to `b` seconds, both channels (dB).
        func power(_ x: (l: [Float], r: [Float]), _ a: Double, _ b: Double) -> Double {
            let i0 = max(0, Int(a * Self.rate)), i1 = min(x.l.count, Int(b * Self.rate))
            var sum = 0.0
            for k in i0..<max(i0, i1) { sum += Double(x.l[k]) * Double(x.l[k]) + Double(x.r[k]) * Double(x.r[k]) }
            return 10 * log10(max(sum / Double(max(1, 2 * (i1 - i0))), 1e-30))
        }
        let voice: (l: [Float], r: [Float]) = (l: zip(played.l, piano.l).map { $0.0 - $0.1 }, r: zip(played.r, piano.r).map { $0.0 - $0.1 })
        let swellAt = Int(t(20) * Self.rate)
        let untouched = max(voice.l[..<swellAt].map(abs).max() ?? 1, voice.r[..<swellAt].map(abs).max() ?? 1)
        XCTAssertLessThan(untouched, 1e-6, "the same as the piano alone until the swell")
        let whole: (l: [Float], r: [Float]) = (l: played.l, r: played.r)
        let top = power(voice, t(24.5), t(25.5)) - power(whole, t(24.5), t(25.5))
        XCTAssertGreaterThan(top, -6, "the voice is most of the sound at the swell's top")
        let gone = power(voice, t(30), t(35)) - power(whole, t(30), t(35))
        XCTAssertLessThan(gone, -25, "and gone in the last chord")
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

    /// Renders a phrase as the app plays it (Storms spec §3): frames of 1/60 s (800 samples). At each frame's start a
    /// SceneDirector hears what was played in the frame before (as the canvas drains the keys), steps, and its cue —
    /// Excitement's tension and drop — reaches the engine through the two calls the app makes; then the frame's MIDI
    /// reaches the engine at its offsets, in 256-sample renders. Nil for an engine not in the Sound Core.
    nonisolated static func renderPlayed(_ engine: ISDEngine, _ phrase: [(time: Double, message: MIDIMessage)],
                                         tail: Double = 4) -> PlayedDemo? {
        guard let synth = isd_synth_create(engine, rate, 512) else { return nil }
        defer { isd_synth_destroy(synth) }
        let director = SceneDirector(themeID: MidnightSteinwayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var state = PerformanceState()
        var heard: [PerformanceEvent] = []
        let total = Int(((phrase.last?.time ?? 0) + tail) * rate), frame = 800, block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var drops: [Double] = [], tensions: [Float] = []
        var e = 0, i = 0
        while i < total {
            let t0 = Double(i) / rate
            director.handle(heard, at: t0)
            heard.removeAll()
            _ = director.step(dt: 1.0 / 60, t: t0, quality: .lite)
            let cue = director.instrumentCue
            isd_synth_set_tension(synth, cue.tension)
            if cue.drop { isd_synth_trigger_drop(synth); drops.append(t0) }
            tensions.append(cue.tension)
            let end = min(total, i + frame)
            var j = i
            while j < end {
                let n = min(block, end - j)
                while e < phrase.count, Int(phrase[e].time * rate) < j + n {
                    let bytes = phrase[e].message.bytes
                    bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), Int32(max(0, Int(phrase[e].time * rate) - j))) }
                    heard += state.apply(phrase[e].message, at: phrase[e].time)
                    e += 1
                }
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in isd_synth_render(synth, lp.baseAddress! + j, rp.baseAddress! + j, Int32(n)) }
                }
                j += n
            }
            i = end
        }
        return PlayedDemo(l: l, r: r, drops: drops, tensions: tensions, engineDrops: Int(isd_synth_debug_count(synth, ISD_DEBUG_DROPS)))
    }

    /// Endless Rise's demo, F minor at 124 (DemoPhrases.endlessRise): a minor chord held for eight bars, a figure, a
    /// climbing line under a pressure swell, then a hard low chord, the drop, held for four bars. Played as the app plays
    /// it, the phrase is the instrument's whole story: the pad pulses at 124 under the riser (the envelope over bars 2–4
    /// is strongest at the beat, 124/60 Hz, between 1 and 4 Hz: 2.045 Hz on the g++ mirror); the climb gathers the
    /// tension (the cue reaches .9 or more; 1 on the mirror) and the riser brightens (the share above 1.5 kHz up 3 dB or
    /// more from bar 4 to bar 8; 6.1); the hard chord drops it exactly once (one cue, in the frame after the chord; the
    /// engine takes one drop, its own hard chord, and lets the cue that follows pass); the 48 Hz thump lands with it
    /// (25 dB or more over the half second before; 42); the riser resolves and goes (the high-passed level 2.6–3.6 s after
    /// the drop 15 dB or more below the second before it; 24.6); and the pad pulses on alone. It renders finite and well
    /// under full scale (0.75 on the mirror).
    func testEndlessRiseDemoRenders() throws {
        let phrase = DemoPhrases.endlessRise
        let fMinor: Set<Int> = [5, 7, 8, 10, 0, 1, 3]   // F G A♭ B♭ C D♭ E♭
        var held = Set<UInt8>(), pressure: UInt8 = 0, swell: UInt8 = 0, longest = 0.0, down: [UInt8: Double] = [:]
        var onsets: [(t: Double, n: UInt8, v: UInt8)] = []
        for (time, m) in phrase {
            switch m {
            case let .noteOn(_, n, v):
                XCTAssertTrue(fMinor.contains(Int(n) % 12), "note \(n) is outside F minor")
                held.insert(n); down[n] = time; onsets.append((t: time, n: n, v: v))
            case let .noteOff(_, n, _):
                held.remove(n)
                if let on = down[n] { longest = max(longest, time - on) }
            case let .channelPressure(_, p): swell = max(swell, p); pressure = p
            case .pitchBend: XCTFail("the wheel isn't used")
            default: break
            }
        }
        XCTAssertTrue(held.isEmpty, "everything let go")
        XCTAssertEqual(pressure, 0)
        XCTAssertGreaterThan(swell, 80, "a real pressure swell")
        let beat = 60.0 / 124
        XCTAssertGreaterThan(longest, 15 * beat, "a chord held for bars")
        XCTAssertGreaterThan(phrase.last?.time ?? 0, 20)
        // Exactly one hard chord (three or more note-ons within 40 ms at a mean velocity of 100 or more): the drop, after
        // the climb.
        var hard: [Double] = []
        for (k, o) in onsets.enumerated() {
            let chord = onsets[k...].prefix { $0.t - o.t <= 0.040 }
            let loud = chord.map { Double($0.v) }.reduce(0, +) / Double(chord.count)
            if chord.count >= 3, loud >= 100, !hard.contains(where: { abs($0 - o.t) <= 0.040 }) { hard.append(o.t) }
        }
        XCTAssertEqual(hard.count, 1, "one hard chord: \(hard)")
        let chordAt = hard.first ?? 0
        let climb = onsets.filter { $0.t < chordAt && $0.t > chordAt - 8 * beat - 0.01 }.map(\.n)
        XCTAssertGreaterThanOrEqual(Int(climb.max() ?? 0) - Int(climb.first ?? 0), 12, "a line that climbs into it")

        let played = try XCTUnwrap(Self.renderPlayed(ISD_ENGINE_ENDLESS_RISE, phrase, tail: 6))
        let l = played.l, r = played.r
        XCTAssertTrue(l.allSatisfy { $0.isFinite } && r.allSatisfy { $0.isFinite })
        let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.85, "well under full scale and the limiter's 0.9")
        XCTAssertGreaterThan(peak, 0.1)
        let mono = zip(l, r).map { $0.0 + $0.1 }
        func t(_ beats: Double) -> Double { (phrase.first?.time ?? 0) + beats * beat }
        /// Mean power (dB) of `x` between two times.
        func power(_ x: [Float], _ a: Double, _ b: Double) -> Double {
            let i0 = max(0, Int(a * Self.rate)), i1 = min(x.count, Int(b * Self.rate))
            var sum = 0.0
            for k in i0..<max(i0, i1) { sum += Double(x[k]) * Double(x[k]) }
            return 10 * log10(max(sum / Double(max(1, i1 - i0)), 1e-30))
        }

        // The pulse: the envelope (RMS every 10 ms) over bars 2–4 is strongest at the beat between 1 and 4 Hz.
        let hop = 480
        var envelope: [Double] = []
        var k = Int(t(4) * Self.rate)
        while k + hop <= Int(t(16) * Self.rate) {
            envelope.append((mono[k..<(k + hop)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(hop)).squareRoot())
            k += hop
        }
        let mean = envelope.reduce(0, +) / Double(max(1, envelope.count))
        func strength(_ hz: Double) -> Double {
            var re = 0.0, im = 0.0
            for (n, v) in envelope.enumerated() {
                let phase = 2 * Double.pi * hz * Double(n * hop) / Self.rate
                re += (v - mean) * cos(phase); im -= (v - mean) * sin(phase)
            }
            return (re * re + im * im).squareRoot()
        }
        let strongest = stride(from: 1.0, through: 4.0, by: 0.005).max { strength($0) < strength($1) } ?? 0
        XCTAssertEqual(strongest, 124.0 / 60, accuracy: 0.1, "the pad's pulse at 124")

        // The build: the cue's tension gathers to .9 or more before the drop, and the riser brightens with it.
        let cuedBefore = played.tensions.prefix(Int(chordAt * 60)).max() ?? 0
        XCTAssertGreaterThanOrEqual(cuedBefore, 0.9, "the climb gathers the tension")
        var a = DemoHighPass(1500), b = DemoHighPass(1500)
        let high = mono.map { Float(b.process(a.process(Double($0)))) }
        let brighter = (power(high, t(28), t(32)) - power(mono, t(28), t(32))) - (power(high, t(12), t(16)) - power(mono, t(12), t(16)))
        XCTAssertGreaterThanOrEqual(brighter, 3, "the gathering opens the pad and leans the riser up")

        // The drop, exactly once: one cue, in the frame after the chord, and one drop taken.
        XCTAssertEqual(played.drops.count, 1, "cued \(played.drops)")
        XCTAssertEqual(played.drops.first ?? 0, chordAt, accuracy: 2.0 / 60)
        XCTAssertGreaterThanOrEqual(played.drops.first ?? 0, chordAt)
        XCTAssertEqual(played.engineDrops, 1, "the riser drops once")
        // The thump lands with it; the riser resolves and goes; the pad pulses on.
        let thump = Self.toneDB(mono, hz: 48, from: chordAt, to: chordAt + 0.25) - Self.toneDB(mono, hz: 48, from: chordAt - 0.6, to: chordAt - 0.1)
        XCTAssertGreaterThanOrEqual(thump, 25, "the 48 Hz thump")
        let resolved = power(high, chordAt - 1, chordAt) - power(high, chordAt + 2.6, chordAt + 3.6)
        XCTAssertGreaterThanOrEqual(resolved, 15, "the riser resolves and fades")
        XCTAssertGreaterThan(power(mono, chordAt + 3, chordAt + 6), -30, "the pad plays on alone")
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

    /// Something a demo does to the ambience at `time` (seconds), at the start of the block that holds it: a level, a
    /// queued roll, a source's next event, or a look at its counters.
    typealias AmbienceAction = (time: Double, apply: (OpaquePointer) -> Void)

    /// Renders the ambience alone, doing `actions` as they fall due (levels glide in over 2.5 s, as in the app); actions
    /// due at or after the end happen once the render is done (a look then sees all of it).
    nonisolated static func renderTimedAmbience(seconds: Double, key: (root: Int32, major: Int32)? = nil,
                                                actions: [AmbienceAction]) -> (l: [Float], r: [Float]) {
        guard let a = isd_ambience_create(rate, 512, 7) else { return ([], []) }
        defer { isd_ambience_destroy(a) }
        if let key { isd_ambience_set_key(a, key.root, key.major) }
        let pending = actions.sorted { $0.time < $1.time }
        let total = Int(seconds * rate), block = 256
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var i = 0, next = 0
        while i < total {
            let n = min(block, total - i)
            while next < pending.count, Int(pending[next].time * rate) < i + n { pending[next].apply(a); next += 1 }
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in isd_ambience_render(a, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n)) }
            }
            i += n
        }
        while next < pending.count { pending[next].apply(a); next += 1 }
        return (l, r)
    }

    /// The storm demos (Storms spec §8.3, §9.3).
    nonisolated static let stormScenes = ["supercell-sky-ambience", "lightning-plains-ambience"]
    /// Supercell Sky's strike: 3 s in, 2 km off, so its thunder arrives 6 s late (3 s a kilometre), at 9 s.
    nonisolated static let supercellStrike: (at: Double, km: Double) = (3, 2)
    /// Lightning Plains' far fork: 2 s in, 20 km out on the horizon, so its thunder (capped at 12 s) arrives at 14 s.
    nonisolated static let plainsFork: (at: Double, km: Double) = (2, 20)

    /// The storm ambience demos, mixed as the worlds mix them (`SupercellSkyModel.levels` with the gust front's sound from
    /// `WeatherAmbience`, and `LightningPlainsModel.levels`), from the start, `seconds` long, with a look at the counters
    /// at each of `looks` (seconds).
    /// - `supercell-sky-ambience`: the field at the Core stage in the late afternoon, the storm 2 km off (closeness 1): the
    ///   grass in a wind of .5 (0.25 + 0.5 × .5), hail on the tin roof (.35), the thunder roll up (0.85), the inflow's
    ///   roar at Energy .6 and tension .4 (0.12 + 0.6 × .6 + 0.2 × .4, a fifth below F, Endless Rise's demo's key), the
    ///   storm's rain on its way (rain on dust 0.5 × .6), the breeze, and the gust front's Approach on the wind (0.2).
    ///   At 3 s a strike 2 km off (a big moment): its thunder queued 6 s late, the flock lifting and fleeing (0.6 × its
    ///   alarm). At 14 s the drop, the gust front's Hit: the grass flattens (to 1), the roar rises with Energy .9 and
    ///   tension .8, the hail shaft comes in, and the gust's roar on the wind climbs 12 dB (0.2 → 0.8) evenly in decibels
    ///   as the dust wall crosses over 10 s, the petrichor rising before the rain (to 0.7). At 30 s a close strike (1 km:
    ///   3 s late, a crack first); at 40 s the rain sets in (the roar on the wind eases to 0.5, the petrichor to 0.3, the
    ///   hail thins); at 44 s a strike 3 km off, behind the rain.
    /// - `lightning-plains-ambience`: the plain at civil dusk (the sun 3° down): the dusk chorus at its full 0.6, the
    ///   windmill at a light breeze's drive (0.35), the grass (0.12 + 4 m/s ÷ 18), grit on the wire (0.12 + 0.5 × .3), no
    ///   heat shimmer after sunset, the cattle grid and the far truck on their own schedules, no crickets yet, and the
    ///   thunder roll up so the queue plays. At 2 s a far fork on the horizon, 20 km out (a repeated note's strike, 0.85
    ///   × 0.75 beyond 5 km), its thunder capped at 12 s; a road train passes on the far highway from 20 s; at 34 s a
    ///   nearer fork, 8 km out, rolls in 12 s later.
    nonisolated static func stormAmbience(_ name: String, seconds: Double, looks: [Double] = []) -> StormDemo {
        var actions: [AmbienceAction] = []
        func level(_ source: ISDAmbienceSource, _ value: Double, at t: Double = 0) {
            let v = Float(value)
            actions.append((t, { isd_ambience_set_level($0, source, v) }))
        }
        func strike(at t: Double, km: Double, strength: Double) {
            let thunder = QueuedThunder.strike(km: km, strength: strength)
            let delay = Float(thunder.delay), power = Float(thunder.strength)
            actions.append((t, { isd_ambience_queue_thunder($0, delay, power) }))
        }
        func trigger(_ source: ISDAmbienceSource, at t: Double) {
            actions.append((t, { isd_ambience_debug_trigger($0, source) }))
        }
        var key: (root: Int32, major: Int32)?
        switch name {
        case "supercell-sky-ambience":
            key = (root: 5, major: 0)
            level(ISD_AMB_GRASS_WIND, 0.5)
            level(ISD_AMB_HAIL_TIN, 0.35)
            level(ISD_AMB_THUNDER_ROLL, 0.85)
            level(ISD_AMB_INFLOW_ROAR, 0.56)
            level(ISD_AMB_RAIN_ON_DUST, 0.3)
            level(ISD_AMB_BREEZE, 0.2)
            level(ISD_AMB_WIND, 0.2)
            strike(at: supercellStrike.at, km: supercellStrike.km, strength: 0.9)
            level(ISD_AMB_BIRDS_FLEE, 0.6, at: supercellStrike.at)
            level(ISD_AMB_GRASS_WIND, 1, at: 14)
            level(ISD_AMB_INFLOW_ROAR, 0.82, at: 14)
            level(ISD_AMB_HAIL_TIN, 0.7, at: 16)
            level(ISD_AMB_RAIN_ON_DUST, 0.7, at: 18)
            for k in 0...5 {
                let roar: Double = 0.2 * pow(4.0, Double(k) / 5)
                level(ISD_AMB_WIND, roar, at: 14 + 2 * Double(k))
            }
            strike(at: 30, km: 1, strength: 1)
            level(ISD_AMB_WIND, 0.5, at: 40)
            level(ISD_AMB_RAIN_ON_DUST, 0.3, at: 40)
            level(ISD_AMB_HAIL_TIN, 0.3, at: 40)
            level(ISD_AMB_GRASS_WIND, 0.75, at: 40)
            strike(at: 44, km: 3, strength: 0.7)
        case "lightning-plains-ambience":
            level(ISD_AMB_DRY_CICADAS, 0.6)
            level(ISD_AMB_WINDMILL, 0.35)
            level(ISD_AMB_GRASS_WIND, 0.12 + 4.0 / 18)
            level(ISD_AMB_DUST_TICKS, 0.12 + 0.5 * 0.3)
            level(ISD_AMB_CATTLE_GRID, 0.3)
            level(ISD_AMB_FAR_TRUCK, 0.25)
            level(ISD_AMB_THUNDER_ROLL, 1)
            strike(at: plainsFork.at, km: plainsFork.km, strength: 0.85 * 0.75)
            trigger(ISD_AMB_FAR_TRUCK, at: 20)
            strike(at: 34, km: 8, strength: 0.85 * 0.75)
        default:
            return StormDemo(l: [], r: [], rolls: [], cicadaPhrases: [])
        }
        var rolls = [Int32](repeating: -1, count: looks.count), phrases = [Int32](repeating: -1, count: looks.count)
        for (k, t) in looks.enumerated() {
            actions.append((t, { a in
                rolls[k] = isd_ambience_debug_events(a, ISD_AMB_THUNDER_ROLL)
                phrases[k] = isd_ambience_debug_events(a, ISD_AMB_DRY_CICADAS)
            }))
        }
        let audio = renderTimedAmbience(seconds: seconds, key: key, actions: actions)
        return StormDemo(l: audio.l, r: audio.r, rolls: rolls, cicadaPhrases: phrases)
    }

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

    /// The storm demos render as the release renders them (here their first 12 s): finite, under full scale and audible.
    /// Supercell Sky's strike, 3 s in and 2 km off, is heard late: no roll has started a moment before 9 s (6 s after
    /// it), and one has just after. On the plains the dusk chorus sings from the first seconds (each of its six singers
    /// starts within 1.7 s of waking), and the far fork's thunder, capped at 12 s, is still on its way at the end (it
    /// rolls in at 14 s).
    func testStormAmbienceDemosRender() {
        let strike = Self.supercellStrike
        let heard = strike.at + 3 * strike.km
        let fork = Self.plainsFork
        let forkHeard = fork.at + min(12, 3 * fork.km)
        for name in Self.stormScenes {
            let looks = name == "supercell-sky-ambience" ? [heard - 0.2, heard + 0.3] : [11.9]
            let demo = Self.stormAmbience(name, seconds: 12, looks: looks)
            let frames = demo.l.count
            XCTAssertEqual(frames, Int(12 * Self.rate), name)
            let finite = demo.l.allSatisfy(\.isFinite) && demo.r.allSatisfy(\.isFinite)
            XCTAssertTrue(finite, name)
            let peakLeft = demo.l.map(abs).max() ?? 0
            let peakRight = demo.r.map(abs).max() ?? 0
            let peak = max(peakLeft, peakRight)
            XCTAssertLessThan(peak, 1.0, name)
            let power = demo.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, frames))
            let rmsDB = 10 * log10(max(power, 1e-20))
            XCTAssertGreaterThan(rmsDB, -50, name)
            if name == "supercell-sky-ambience" {
                let before = demo.rolls[0]
                let after = demo.rolls[1]
                XCTAssertEqual(before, 0, "nothing arrives early")
                XCTAssertEqual(after, 1, "the strike's thunder arrives at \(heard) s")
            } else {
                let rolls = demo.rolls[0]
                let phrases = demo.cicadaPhrases[0]
                XCTAssertEqual(rolls, 0, "the far fork's thunder is still on its way (it arrives at \(forkHeard) s)")
                XCTAssertGreaterThanOrEqual(phrases, 6, "the dusk chorus sings")
            }
        }
        XCTAssertEqual(heard, 9, accuracy: 1e-9)
        XCTAssertEqual(forkHeard, 14, accuracy: 1e-9)
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
        // The storms: a strike on the field with its thunder late and the gust front's roar; the plain at dusk, its
        // cicadas and a far fork.
        for name in Self.stormScenes {
            let demo = Self.stormAmbience(name, seconds: 60)
            let peakLeft = demo.l.map(abs).max() ?? 0
            let peakRight = demo.r.map(abs).max() ?? 0
            let peak = max(peakLeft, peakRight)
            XCTAssertLessThanOrEqual(peak, 1.0, name)
            let power = demo.l.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, demo.l.count))
            let rmsDB = 10 * log10(max(power, 1e-20))
            XCTAssertGreaterThan(rmsDB, -60, name)
            try Self.writeWAV((l: demo.l, r: demo.r), to: url.appendingPathComponent("\(name).wav"))
            try PreviewRenderer.writePNG(Spectrogram.image(left: demo.l, sampleRate: Self.rate, width: 1400, height: 500),
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

    // MARK: - Fire & Neon (spec §8.3, §9.3; plan Task 10)

    /// Volcano Rim's eruption in its demo: 8 s in (its boom, from the lake 510 m off and below, arrives 1.49 s later).
    nonisolated static let volcanoEruptionAt = 8.0
    /// The drive's demo climbs from 66 km/h (speed 0.2) to 130 (speed 1) between these times (s), so the box shifts up.
    nonisolated static let driveClimb: ClosedRange<Double> = 9...17

    /// The Fire & Neon ambience demos, mixed as the worlds mix them (`VolcanoRimModel.levels` and `.lake`, and
    /// `NeonNightDriveModel.levels`, `.pass` and the wipers' timing), with the one-shots each world sends, from the start.
    /// - `volcano-rim-ambience`: the crater at night, a light wind (.3) over the rim: the vent rumble, the lava lake's hiss,
    ///   the steam vents and the rockfall up, the eruption's boom and the plume's thunder ready. The lake convects gently
    ///   (1 m/s at the margin, a little swell, Energy .5). At 3 s a steam blast from a vent at the left wall's foot (heard
    ///   2.2 s later, from the left, a quarter of the way to far). At 8 s an eruption (strength .8): the lake surges and
    ///   glows with its light, its boom arrives 1.49 s later, and three cracks of the plume's lightning follow it (0.4,
    ///   1.1 and 2.3 s after, each heard 1.4–1.5 s after its stroke). At 14 s a rockfall down the right wall (strength .9,
    ///   heard 2.2 s later).
    /// - `neon-night-drive-ambience`: the expressway at night in the rain (.5 on the glass, the road wet), from the passenger
    ///   seat (indoors .55), in D major: the wet tyres, the engine, the roof rain, the wind round the windscreen and the far
    ///   city. The wipers sweep without rest at the rain's rate (one sweep every 1.21 s, each sent a moment ahead, as the
    ///   drive sends them). From 9 s to 17 s the car climbs from 66 to 130 km/h (the box shifts up through the gears).
    ///   Four cars come alongside (each sent 3 s ahead): one oncoming across the median at 6.5 s, one overtaking you 4 m to
    ///   the right at 13 s, a truck oncoming at 18.5 s, and one you overtake 3 m to the left at 22.5 s. The far siren
    ///   calls from 6 s (it is rare: here it is set going).
    static func fireNeonAmbience(_ name: String, seconds: Double) -> FireNeonDemo {
        var actions: [AmbienceAction] = []
        var heard: [(source: AmbienceSource, at: Double)] = []
        func at(_ t: Double, _ apply: @escaping (OpaquePointer) -> Void) { actions.append((t, apply)) }
        func levels(_ map: [AmbienceSource: Double], at t: Double = 0) {
            for (source, value) in map {
                let c = AmbienceAU.cSource(source), v = Float(value)
                at(t) { isd_ambience_set_level($0, c, v) }
            }
        }
        func post(_ e: AmbienceEvent, at t: Double) {
            let c = AmbienceAU.cSource(e.source), delay = Float(e.delay), strength = Float(e.strength), pan = Float(e.pan)
            let speed = Float(e.speed), distance = Float(e.distance), kind = Int32(e.kind)
            at(t) { isd_ambience_post_event($0, c, delay, strength, pan, speed, distance, kind) }
            heard.append((e.source, t + e.delay))
        }
        var key: (root: Int32, major: Int32)?
        var engineHz: [Float] = []
        switch name {
        case "volcano-rim-ambience":
            var sky = SkyState()
            sky.wind = 0.3
            levels(VolcanoRimModel.levels(sky))
            at(0) { isd_ambience_set_closeness($0, 0.5) }
            for k in 0..<Int(seconds * 10) {
                let t = Double(k) / 10, since = Float(t - volcanoEruptionAt)
                let light: Float = since >= 0 ? Eruption(age: since, strength: 0.8).light : 0
                let lake = VolcanoRimModel.lake(convection: 1, swell: 0.2, burst: 0, cells: [], energy: 0.5, eruption: light, breach: 0)
                let surge = Float(lake.surge), glow = Float(lake.glow)
                at(t) { isd_ambience_set_lake($0, surge, glow) }
            }
            func wall(_ angle: Float, _ radius: Float, _ z: Float) -> SIMD3<Float> {
                let p = VolcanoCrater.wallPoint(angle: angle, radius: radius)
                return SIMD3(p.x, p.y, z)
            }
            func fromWall(_ source: AmbienceSource, _ p: SIMD3<Float>, strength: Double, at t: Double) {
                post(AmbienceEvent(source: source, delay: VolcanoRimModel.soundDelay(to: p), strength: strength,
                                   pan: VolcanoRimModel.pan(of: p), distance: VolcanoRimModel.farness(of: p)), at: t)
            }
            fromWall(.steamVent, wall(-0.75, VolcanoCrater.footRadius + 10, VolcanoCrater.benchHeight * 0.5), strength: 1, at: 3)
            post(AmbienceEvent(source: .eruptionBoom, delay: VolcanoRimModel.soundDelay(to: .zero)), at: volcanoEruptionAt)
            let strokes: [(after: Double, origin: SIMD3<Float>, strength: Double)] = [
                (0.4, SIMD3(20, 10, 120), 0.8), (1.1, SIMD3(-35, -15, 190), 0.6), (2.3, SIMD3(45, 20, 80), 0.9),
            ]
            for stroke in strokes {
                post(AmbienceEvent(source: .plumeThunder, delay: VolcanoRimModel.soundDelay(to: stroke.origin),
                                   strength: min(1, 0.35 + 0.5 * stroke.strength), pan: VolcanoRimModel.pan(of: stroke.origin)),
                     at: volcanoEruptionAt + stroke.after)
            }
            fromWall(.rockfall, wall(0.8, VolcanoCrater.benchRadius, VolcanoCrater.rimHeight * 0.8), strength: 0.9, at: 14)
        case "neon-night-drive-ambience":
            key = (root: 2, major: 1)
            var sky = SkyState()
            sky.rain = 0.5
            sky.wetness = 0.8
            let glass: Float = 0.5
            let climb = driveClimb
            func speed(at t: Double) -> Float {
                Float(0.2 + 0.8 * min(1, max(0, (t - climb.lowerBound) / (climb.upperBound - climb.lowerBound))))
            }
            at(0) { a in
                isd_ambience_set_indoors(a, 0.55)
                isd_ambience_set_wetness(a, 0.8)
                isd_ambience_set_closeness(a, 0.6)
            }
            for k in 0..<Int(seconds * 10) {
                let t = Double(k) / 10, v = speed(at: t)
                levels(NeonNightDriveModel.levels(sky, speed: v, glassRain: glass, inTunnel: false, gentle: false), at: t)
                at(t) { isd_ambience_set_speed($0, v) }
                at(t) { engineHz.append(isd_ambience_debug_hz($0, ISD_AMB_DRIVE_ENGINE)) }
            }
            // The wipers: back to back at the rain's rate, each sweep sent a moment before it begins.
            let sweep = Double(Wipers.sweepTime(rain: glass)), lead = Double(NeonNightDriveModel.sweepLead)
            var start = 1.0
            while start + sweep < seconds {
                post(.sweep(in: lead, seconds: sweep, wet: Double(glass)), at: start - lead)
                start += sweep
            }
            // The traffic: each car placed so it comes alongside 3 s on (`passLead`), as the drive sends it.
            let traffic: [(at: Double, lane: Int, seed: UInt64, mps: Float, ofYours: Bool)] = [
                (3.5, 4, 1, 25, false), (10, 2, 2, 1.2, true), (15.5, 5, 4, 22, false), (19.5, 0, 3, 0.85, true),
            ]
            for c in traffic {
                let you = NeonNightDriveModel.metresPerSecond(speed(at: c.at)), own = c.ofYours ? c.mps * you : c.mps
                var car = DriveCar(lane: c.lane, ahead: 0, speed: own, seed: c.seed, brake: 0, lightBar: false)
                let closing = car.oncoming ? own + you : abs(own - you)
                car.ahead = (car.oncoming || own < you ? 1 : -1) * closing * NeonNightDriveModel.passLead
                if let p = NeonNightDriveModel.pass(of: car, mps: you) {
                    post(.passingCar(in: Double(p.after), closing: Double(p.closing), lateral: Double(p.lateral), truck: car.truck), at: c.at)
                }
            }
            at(6) { isd_ambience_debug_trigger($0, ISD_AMB_FAR_SIREN) }
        default:
            return FireNeonDemo(l: [], r: [], heard: [], engineHz: [], counts: [:])
        }
        var counts: [AmbienceSource: Int32] = [:]
        let counted: [AmbienceSource] = [.steamVent, .eruptionBoom, .plumeThunder, .rockfall, .wipers, .drivePassingCar, .farSiren]
        at(seconds) { a in
            for source in counted { counts[source] = isd_ambience_debug_events(a, AmbienceAU.cSource(source)) }
        }
        let audio = renderTimedAmbience(seconds: seconds, key: key, actions: actions)
        return FireNeonDemo(l: audio.l, r: audio.r, heard: heard, engineHz: engineHz, counts: counts)
    }

    /// The power (dB) of `x` between `t0` and `t1` seconds through a band-pass from `lo` to `hi` Hz (an RBJ band-pass at
    /// their geometric middle, its bandwidth their octaves, run twice).
    nonisolated static func bandDB(_ x: [Float], _ lo: Double, _ hi: Double, from t0: Double, to t1: Double) -> Double {
        let f0 = (lo * hi).squareRoot(), bw = log2(hi / lo), w0 = 2 * Double.pi * f0 / rate
        let alpha = sin(w0) * sinh(log(2) / 2 * bw * w0 / sin(w0)), a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        let a = max(0, Int(t0 * rate)), b = min(x.count, Int(t1 * rate))
        guard a < b else { return -300 }
        // From a second before the window, so the filters have settled.
        var z = [0.0, 0.0, 0.0, 0.0], sum = 0.0
        for i in max(0, a - Int(rate))..<b {
            let v = Double(x[i])
            let y1 = b0 * v + z[0]
            z[0] = -a1 * y1 + z[1]; z[1] = b2 * v - a2 * y1
            let y2 = b0 * y1 + z[2]
            z[2] = -a1 * y2 + z[3]; z[3] = b2 * y1 - a2 * y2
            if i >= a { sum += y2 * y2 }
        }
        return 10 * log10(max(sum / Double(b - a), 1e-30))
    }

    /// A demo's common checks and its summary in the log (per second: the level, 20–200 Hz, 2–6 kHz and the balance),
    /// then the WAV and its spectrogram when DEMO_DIR is set.
    func checkAndWrite(_ demo: FireNeonDemo, name: String, seconds: Double) throws {
        XCTAssertEqual(demo.l.count, Int(seconds * Self.rate), name)
        XCTAssertTrue(demo.l.allSatisfy(\.isFinite) && demo.r.allSatisfy(\.isFinite), name)
        let peak = max(demo.l.map(abs).max() ?? 0, demo.r.map(abs).max() ?? 0)
        XCTAssertLessThan(peak, 0.6, "\(name) stays under the limiter")
        let mid = zip(demo.l, demo.r).map { 0.5 * ($0 + $1) }
        let rms = 10 * log10(max(mid.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, mid.count)), 1e-30))
        XCTAssertGreaterThan(rms, -50, name)
        print("\(name): peak \(String(format: "%.1f", 20 * log10(Double(max(peak, 1e-9))))) dBFS")
        for (source, t) in demo.heard { print("  \(source.rawValue) heard at \(String(format: "%.2f", t)) s") }
        print("  counted: " + demo.counts.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", "))
        print("   sec  level  20-200  2k-6k  R-L(300-3k)")
        for t in 0..<Int(seconds) {
            let a = Double(t), b = a + 1
            let level = 10 * log10(max(mid[Int(a * Self.rate)..<Int(b * Self.rate)].reduce(0) { $0 + Double($1) * Double($1) } / Self.rate, 1e-30))
            let balance = Self.bandDB(demo.r, 300, 3000, from: a, to: b) - Self.bandDB(demo.l, 300, 3000, from: a, to: b)
            print(String(format: "  %4ld %6.1f %7.1f %6.1f %+6.1f", t, level, Self.bandDB(mid, 20, 200, from: a, to: b),
                         Self.bandDB(mid, 2000, 6000, from: a, to: b), balance))
        }
        guard let dir = ProcessInfo.processInfo.environment["DEMO_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.writeWAV((l: demo.l, r: demo.r), to: url.appendingPathComponent("\(name).wav"))
        try PreviewRenderer.writePNG(Spectrogram.image(left: demo.l, sampleRate: Self.rate, width: 1400, height: 500),
                                     to: url.appendingPathComponent("\(name)-spectrogram.png"))
    }

    /// When the demo's one-shot from `source` is heard (its first).
    func heard(_ demo: FireNeonDemo, _ source: AmbienceSource) -> Double { demo.heard.first { $0.source == source }?.at ?? -1 }

    /// Volcano Rim's demo (plan Task 10): 24 s with a steam blast, an eruption's boom and the plume's cracks, and a
    /// rockfall, each heard when its sound arrives. The boom's first second lifts 20–200 Hz by 5 dB or more over the second
    /// before it (the lake already surging with the eruption's light); the steam lifts 2–6 kHz by 6 dB from 0.7 s after it
    /// arrives; the rockfall's first half-second stands 3 dB over the lake's bed at 800–3200 Hz; and every one-shot sounds.
    /// (The g++ mirror, eight seeds: the boom +7.0 to +10.0 dB, the steam +8.9 to +13.1, the rockfall +4.2 to +6.1; peaks
    /// −5.6 to −8.9 dBFS.)
    func testRenderVolcanoAmbience() throws {
        let name = "volcano-rim-ambience", seconds = 24.0
        let demo = Self.fireNeonAmbience(name, seconds: seconds)
        let mid = zip(demo.l, demo.r).map { 0.5 * ($0 + $1) }
        let boom = heard(demo, .eruptionBoom), steam = heard(demo, .steamVent), rock = heard(demo, .rockfall)
        XCTAssertEqual(boom, Self.volcanoEruptionAt + 1.49, accuracy: 0.01)
        let thump = Self.bandDB(mid, 20, 200, from: boom + 0.05, to: boom + 1) - Self.bandDB(mid, 20, 200, from: boom - 0.95, to: boom - 0.05)
        XCTAssertGreaterThanOrEqual(thump, 5, "the eruption's boom arrives at \(boom) s")
        let hiss = Self.bandDB(mid, 2000, 6000, from: steam + 0.7, to: steam + 1.8) - Self.bandDB(mid, 2000, 6000, from: steam - 1.2, to: steam - 0.1)
        XCTAssertGreaterThanOrEqual(hiss, 6, "the steam blast arrives at \(steam) s")
        let clatter = Self.bandDB(mid, 800, 3200, from: rock, to: rock + 0.5) - Self.bandDB(mid, 800, 3200, from: rock - 1.2, to: rock - 0.1)
        XCTAssertGreaterThanOrEqual(clatter, 3, "the rockfall arrives at \(rock) s")
        XCTAssertEqual(demo.counts[.eruptionBoom], 1)
        XCTAssertEqual(demo.counts[.plumeThunder], 3)
        XCTAssertGreaterThanOrEqual(demo.counts[.steamVent] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(demo.counts[.rockfall] ?? 0, 1)
        print("volcano: boom +\(String(format: "%.1f", thump)) dB, steam +\(String(format: "%.1f", hiss)) dB, rockfall +\(String(format: "%.1f", clatter)) dB")
        try checkAndWrite(demo, name: name, seconds: seconds)
    }

    /// Neon Night Drive's demo (plan Task 10): 24 s in the rain with the wipers, four cars passing and a climb to 130 km/h.
    /// Every sweep sent is heard (one each 1.21 s); all four cars come alongside, each pulling the balance (at 300–3000 Hz)
    /// to its side as it passes: the near ones (4 m right, 3 m left) by 3 dB or more against the first seconds, the
    /// oncoming one across the median by 1.5; the engine's pitch falls at least once by 8% within 0.4 s through the
    /// climb (an upshift) and ends near 8th's 64.7 Hz at 130 km/h. (The g++ mirror, eight seeds: 19 sweeps; the cars +3.0
    /// to +3.6, +7.6 to +8.6, the truck 16.7 m off +0.6 to +2.6, and −5.4 to −6.2 dB; shifts at 10.2, 13.0 and 15.9 s;
    /// peaks −9.9 to −12.1 dBFS.)
    func testRenderDriveAmbience() throws {
        let name = "neon-night-drive-ambience", seconds = 24.0
        let demo = Self.fireNeonAmbience(name, seconds: seconds)
        let sweeps = demo.heard.filter { $0.source == .wipers }.count
        XCTAssertGreaterThanOrEqual(sweeps, 18)
        XCTAssertEqual(demo.counts[.wipers], Int32(sweeps), "every sweep is heard")
        let cars = demo.heard.filter { $0.source == .drivePassingCar }.map { $0.at }
        XCTAssertEqual(cars.count, 4)
        XCTAssertEqual(demo.counts[.drivePassingCar], 4)
        func balance(_ t0: Double, _ t1: Double) -> Double {
            Self.bandDB(demo.r, 300, 3000, from: t0, to: t1) - Self.bandDB(demo.l, 300, 3000, from: t0, to: t1)
        }
        let base = balance(1, 5)
        let swings = cars.map { balance($0 - 0.1, $0 + 0.1) - base }
        if swings.count == 4 {
            XCTAssertGreaterThanOrEqual(swings[0], 1.5, "the oncoming car across the median passes on the right")
            XCTAssertGreaterThanOrEqual(swings[1], 3, "the car overtaking you passes on the right")
            XCTAssertLessThanOrEqual(swings[3], -3, "the car you overtake passes on the left")
        }
        // The upshifts: 0.1 s apart, the firing pitch dropping 8% or more within 0.4 s.
        var shifts: [Double] = []
        var k = 4
        while k < demo.engineHz.count {
            let before = demo.engineHz[(k - 4)..<k].max() ?? 0
            if before > 0, demo.engineHz[k] < 0.92 * before { shifts.append(Double(k) / 10); k += 8 } else { k += 1 }
        }
        let inClimb = shifts.filter { Self.driveClimb.lowerBound...(Self.driveClimb.upperBound + 2) ~= $0 }
        XCTAssertGreaterThanOrEqual(inClimb.count, 1, "the box shifts up as the car climbs (shifts at \(shifts))")
        let end = Double(demo.engineHz.suffix(20).reduce(0, +)) / 20
        XCTAssertEqual(end, 2 * 1000 * 130 / 67 / 60, accuracy: 1.5, "130 km/h in 8th")
        print("drive: \(sweeps) sweeps, cars swing " + swings.map { String(format: "%+.1f", $0) }.joined(separator: " ")
              + " dB, shifts at \(shifts), engine \(String(format: "%.1f", end)) Hz at the end")
        try checkAndWrite(demo, name: name, seconds: seconds)
    }

    func testSpectrogramShowsATone() {
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / Self.rate)) * 0.5 }
        let image = Spectrogram.image(left: tone, sampleRate: Self.rate, width: 200, height: 100)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertGreaterThan(PreviewRenderer.stats(image).variance, 0.0005)
    }
}

/// A Fire & Neon demo (`DemoRenderTests.fireNeonAmbience`): its audio, when each one-shot sent is heard, the drive
/// engine's firing pitch every 0.1 s (Hz; empty for the volcano), and how many one-shots each source had begun by the end.
struct FireNeonDemo {
    var l: [Float], r: [Float]
    var heard: [(source: AmbienceSource, at: Double)]
    var engineHz: [Float]
    var counts: [AmbienceSource: Int32]
}

/// A storm demo (`DemoRenderTests.stormAmbience`): its audio, and at each look how many thunder rolls had started and how
/// many phrases the cicadas had begun.
struct StormDemo {
    var l: [Float], r: [Float]
    var rolls: [Int32]
    var cicadaPhrases: [Int32]
}

/// What `renderPlayed` hands back: the audio, when the director cued a drop (seconds), the tension it cued every
/// frame, and how many drops the engine took.
struct PlayedDemo {
    var l: [Float], r: [Float]
    var drops: [Double]
    var tensions: [Float]
    var engineDrops: Int
}

/// An RBJ high-pass biquad (Q 0.7071), for the demo tests' brightness.
struct DemoHighPass {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    init(_ hz: Double, q: Double = 0.7071) {
        let w: Double = 2 * Double.pi * hz / DemoRenderTests.rate
        let al: Double = sin(w) / (2 * q), c: Double = cos(w), a0: Double = 1 + al
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
