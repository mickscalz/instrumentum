import XCTest
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

/// Every built-in preset's loudness (`LoudnessMeter`: BS.1770-4 integrated, and the true peak) on its engine's demo phrase,
/// as the app plays it: the preset's dials on the Sound Core, the phrase's MIDI at its sample offsets in 256-sample
/// renders, and a 6 s tail, as the demo audio is rendered (`DemoRenderTests.testWriteDemoAudio`). Endless Rise's demo is
/// played as the app plays it (`DemoRenderTests.renderPlayed`): its notes reach a scene director whose cue (Excitement's
/// tension and drop) reaches the engine every 1/60 s frame. What the engine renders is what the app's instrument bus
/// hears; the player's own volume comes after it and is left out.
final class PresetLoudnessTests: XCTestCase {
    static let rate = LoudnessMeter.sampleRate

    /// The demo phrase of each engine (the one its demo audio plays).
    static func phrase(_ engine: BuiltInEngine) -> DemoPhrases.Phrase {
        switch engine {
        case .feltGlass: return DemoPhrases.feltGlass
        case .orbitPad: return DemoPhrases.orbitPad
        case .honeyTape: return DemoPhrases.honeyTape
        case .hazeBells: return DemoPhrases.hazeBells
        case .cabinFelt: return DemoPhrases.cabinFelt
        case .morningBox: return DemoPhrases.morningBox
        case .polarChoir: return DemoPhrases.polarChoir
        case .planktonKeys: return DemoPhrases.planktonKeys
        case .teaHouseKoto: return DemoPhrases.teaHouseKoto
        case .zenShakuhachi: return DemoPhrases.zenShakuhachi
        case .blueDepth: return DemoPhrases.blueDepth
        case .reefMarimba: return DemoPhrases.reefMarimba
        case .magmaBass: return DemoPhrases.magmaBass
        case .replicantBrass: return DemoPhrases.replicantBrass
        case .endlessRise: return DemoPhrases.endlessRise
        case .singleNoteGrand: return DemoPhrases.singleNoteGrand
        }
    }

    /// The preset's dials, by their addresses on `engine`.
    static func dials(_ patch: Patch, on engine: ISDEngine) -> [(address: Int32, value: Float)] {
        var out: [(address: Int32, value: Float)] = []
        for i in 0..<isd_synth_param_count(engine) {
            guard let info = isd_synth_param_info(engine, i)?.pointee,
                  let value = patch.values[String(cString: info.identifier)] else { continue }
            out.append((address: info.address, value: Float(value)))
        }
        return out
    }

    /// `patch` playing its engine's demo phrase, then `tail` seconds: nil for an engine not in the Sound Core.
    static func render(_ patch: Patch, tail: Double = 6) -> (l: [Float], r: [Float])? {
        let engine = BuiltInCatalog.isdEngine(patch.engine)
        let phrase = Self.phrase(patch.engine)
        guard let synth = isd_synth_create(engine, rate, 512) else { return nil }
        defer { isd_synth_destroy(synth) }
        for dial in dials(patch, on: engine) { isd_synth_set_param(synth, dial.address, dial.value) }
        // Endless Rise is played as the app plays it, in frames of 1/60 s (800 samples) each starting with the director's
        // cue; every other engine renders straight through in 256-sample blocks.
        let played = patch.engine == .endlessRise
        let director = SceneDirector(themeID: MidnightSteinwayModel.id, state: ThemeState(), reaction: ReactionPresets.expressivePianist)
        var state = PerformanceState()
        var heard: [PerformanceEvent] = []
        let total = Int(((phrase.last?.time ?? 0) + tail) * rate), block = 256
        let frame = played ? 800 : block
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        var e = 0, i = 0
        while i < total {
            if played {
                let t0 = Double(i) / rate
                director.handle(heard, at: t0)
                heard.removeAll()
                _ = director.step(dt: 1.0 / 60, t: t0, quality: .lite)
                let cue = director.instrumentCue
                isd_synth_set_tension(synth, cue.tension)
                if cue.drop { isd_synth_trigger_drop(synth) }
            }
            let end = min(total, i + frame)
            var j = i
            while j < end {
                let n = min(block, end - j)
                while e < phrase.count, Int(phrase[e].time * rate) < j + n {
                    let offset = Int32(max(0, Int(phrase[e].time * rate) - j))
                    phrase[e].message.bytes.withUnsafeBufferPointer { isd_synth_midi(synth, $0.baseAddress, Int32($0.count), offset) }
                    if played { heard += state.apply(phrase[e].message, at: phrase[e].time) }
                    e += 1
                }
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in isd_synth_render(synth, lp.baseAddress! + j, rp.baseAddress! + j, Int32(n)) }
                }
                j += n
            }
            i = end
        }
        return (l, r)
    }

    /// One built-in preset's measure on its demo phrase.
    struct Reading {
        let patch: Patch
        let lufs: Double
        let peak: Double
        var line: String {
            "LOUDNESS patch \(patch.engine.displayName) / \(patch.name): \(String(format: "%.1f", lufs)) LUFS, peak \(String(format: "%.1f", peak)) dBTP"
        }
    }

    /// Every built-in preset, measured once.
    static func readings() throws -> [Reading] {
        try PatchLibrary.all.map { (patch: Patch) -> Reading in
            let audio = try XCTUnwrap(render(patch), "\(patch.engine.displayName) is not in the Sound Core")
            return Reading(patch: patch, lufs: LoudnessMeter.integrated(audio.l, audio.r), peak: LoudnessMeter.truePeak(audio.l, audio.r))
        }
    }

    /// The report: one line each, every preset, with the median.
    func testReportPresetLoudness() throws {
        let all = try Self.readings()
        for reading in all { print(reading.line) }
        let sorted = all.map(\.lufs).sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        print("LOUDNESS patches: \(all.count), median \(String(format: "%.2f", median)) LUFS, from \(String(format: "%.1f", sorted.first ?? 0)) to \(String(format: "%.1f", sorted.last ?? 0))")
        print("LOUDNESS patch table: " + all.map { "\($0.patch.id)=\(String(format: "%.2f", $0.lufs))/\(String(format: "%.2f", $0.peak))" }.joined(separator: " "))
        XCTAssertEqual(all.count, PatchLibrary.all.count)
        XCTAssertTrue(all.allSatisfy { $0.lufs.isFinite }, "every preset is heard")
    }
}
