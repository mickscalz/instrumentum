import XCTest
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

/// Every built-in preset's loudness (`LoudnessMeter`: BS.1770-4 integrated, and the true peak) on its engine's demo phrase,
/// as the app plays it: the preset's dials on the Sound Core, the phrase's MIDI at its sample offsets in 256-sample
/// renders, and a 6 s tail, as the demo audio is rendered (`DemoRenderTests.testWriteDemoAudio`). Endless Rise's demo is
/// played as the app plays it (`DemoRenderTests.renderPlayed`): its notes reach a scene director whose cue (Excitement's
/// tension and drop) reaches the engine every 1/60 s frame. The preset's trim is the Sound Core's, as the built-in
/// instrument sets it with the preset (`BuiltInInstrumentAU.apply`). What the engine renders is what the app's instrument
/// bus hears; the player's own volume comes after it and is left out.
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
        isd_synth_set_trim(synth, BuiltInCatalog.trimGain(dB: patch.trimDB))   // as the instrument applies it with the preset
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

    /// Each built-in preset's loudness on its demo phrase before presets had trims (LUFS; this meter, on CI, 13 Nov 2026).
    static let untrimmed: [String: Double] = [
        "felt-glass": -21.90, "bare-felt": -23.31, "glass-choir": -19.73, "lullaby": -24.59,
        "orbit-pad": -14.42, "earthrise": -15.16, "weightless": -13.79, "re-entry": -14.34,
        "honey-tape": -20.73, "sea-flute": -19.50, "velvet-strings": -24.40, "old-reel": -20.46,
        "haze-bells": -22.27, "church-keys": -23.20, "night-drive": -20.76, "lo-fi": -23.76,
        "cabin-felt": -24.95, "fireside": -28.79, "snow-horn": -16.84, "late-night": -29.46,
        "morning-box": -23.13, "music-box": -20.37, "wall-of-light": -15.95, "snooze": -21.12,
        "polar-choir": -19.03, "far-voices": -18.20, "bowed-glass": -19.55, "hush": -20.26,
        "plankton-keys": -25.40, "glow-wake": -25.19, "tide-tines": -26.55, "midnight-bay": -23.97,
        "tea-house-koto": -27.87, "winter-strings": -27.45, "near-the-bridge": -24.26, "night-tea": -27.61,
        "zen-shakuhachi": -29.68, "mountain-breath": -28.85, "hollow-bamboo": -29.41, "still-air": -28.39,
        "reef-marimba": -22.30, "soft-yarn": -26.00, "lagoon-steel": -20.29, "night-reef": -23.40,
        "blue-depth": -16.21, "ghost-signal": -10.86, "pressure-hull": -18.26, "surface-light": -16.49,
        "single-note-grand": -27.57, "marble-hall": -24.44, "broken-voice": -22.93, "dry-grand": -29.77,
        "magma-bass": -15.08, "basalt": -17.40, "fissure": -13.55, "ember-glide": -16.43,
        "replicant-brass": -15.01, "tears-in-rain": -13.16, "chrome-rush": -14.72, "night-brass": -14.09,
        "endless-rise": -13.74, "slow-front": -12.49, "siren": -14.59, "pad-only": -14.11,
    ]

    /// The middle of `values` (the mean of the middle two when there is an even number of them).
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The presets' one loudness: the median of their untrimmed loudness, so the app as a whole is no louder or quieter
    /// than it was. A preset added later is held to it too.
    static let target = PresetLoudnessTests.median(Array(PresetLoudnessTests.untrimmed.values))
    /// How far from the target a preset may sit (LU), and how high its true peak may reach (dBTP). (No preset's trim had to
    /// be held lower for its peak: Lullaby comes nearest, at −1.03 dBTP.)
    static let tolerance = 1.0, peakCeiling = -1.0

    /// One loudness: every built-in preset, trimmed, plays its engine's demo phrase within 1 LU of the presets' target, its
    /// true peak at or under −1 dBTP. Each is rendered once, and the report prints a line for each.
    func testEveryPresetPlaysAtOneLoudness() throws {
        let all = try Self.readings()
        for reading in all { print(reading.line + " (trim \(String(format: "%+.1f", reading.patch.trimDB)) dB)") }
        let sorted = all.map(\.lufs).sorted()
        print("LOUDNESS patches: \(all.count), target \(String(format: "%.2f", Self.target)) LUFS, from \(String(format: "%.1f", sorted.first ?? 0)) to \(String(format: "%.1f", sorted.last ?? 0)), median \(String(format: "%.2f", Self.median(sorted)))")
        print("LOUDNESS patch table: " + all.map { "\($0.patch.id)=\(String(format: "%.2f", $0.lufs))/\(String(format: "%.2f", $0.peak))" }.joined(separator: " "))
        XCTAssertEqual(all.count, PatchLibrary.all.count)
        for reading in all {
            XCTAssertLessThanOrEqual(abs(reading.lufs - Self.target), Self.tolerance, reading.line)
            XCTAssertLessThanOrEqual(reading.peak, Self.peakCeiling, reading.line)
        }
    }
}
