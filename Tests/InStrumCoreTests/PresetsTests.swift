import XCTest
@testable import InStrumCore

final class PresetsTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let specs = ButterflyGardenModel.parameters

    func testLookRoundTrip() throws {
        let store = PresetStore(directory: dir)
        let p = LookPreset(name: "My Dawn", themeID: ButterflyGardenModel.id,
                           state: ThemeState(values: ["time": .choice("Dawn")], macros: [.glow: 0.3]), favourite: true)
        try store.save(p)
        XCTAssertEqual(store.looks(for: ButterflyGardenModel.id).first { $0.name == "My Dawn" }, p)
        XCTAssertTrue(store.looks(for: MidnightSteinwayModel.id).allSatisfy { $0.name != "My Dawn" })
    }
    func testReactionRoundTripAndDelete() throws {
        let store = PresetStore(directory: dir)
        let p = ReactionPreset(name: "Mine", map: ReactionPresets.wild, favourite: false)
        try store.save(p)
        XCTAssertEqual(store.reactions().first { $0.name == "Mine" }, p)
        try store.delete(reaction: "Mine")
        XCTAssertNil(store.reactions().first { $0.name == "Mine" })
    }
    func testNamesWithSlashesAreSafe() throws {
        let store = PresetStore(directory: dir)
        try store.save(ReactionPreset(name: "a/b: c", map: ReactionPresets.minimal, favourite: false))
        XCTAssertNotNil(store.reactions().first { $0.name == "a/b: c" })
    }
    func testDamagedFileListedAndOthersLoad() throws {
        let store = PresetStore(directory: dir)
        try store.save(ReactionPreset(name: "Good", map: ReactionPresets.minimal, favourite: false))
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("reaction/bad.json"))
        let all = store.reactions()
        XCTAssertNotNil(all.first { $0.name == "Good" })
        XCTAssertTrue(store.unreadable.contains("bad.json"))
    }
    func testSurpriseStaysInTastefulRanges() {
        for seed in 0..<100 {
            let state = Surprise.look(specs: specs, seed: UInt64(seed))
            for s in specs {
                guard let v = state.values[s.id] else { continue }
                XCTAssertNotNil(s.surprise, "\(s.id) changed but is not surprisable")
                if case let .number(x) = v, let r = s.surprise, s.range != nil {
                    XCTAssertTrue(r.contains(x) || abs(x - r.upperBound) < 1, "\(s.id)=\(x)")
                }
                XCTAssertEqual(s.validated(v), v, "\(s.id) invalid")
            }
        }
    }
    func testSurpriseVariesWithSeed() {
        XCTAssertNotEqual(Surprise.look(specs: specs, seed: 1), Surprise.look(specs: specs, seed: 2))
    }
    func testMorphEndsMidpointAndChoices() {
        let a = ThemeState(values: ["rays": .number(0.2), "time": .choice("Dawn")])
        let b = ThemeState(values: ["rays": .number(0.8), "time": .choice("Moonlight")])
        XCTAssertEqual(morph(a, b, specs: specs, t: 0).values["rays"], .number(0.2))
        XCTAssertEqual(morph(a, b, specs: specs, t: 1).values["rays"], .number(0.8))
        guard case let .number(mid)? = morph(a, b, specs: specs, t: 0.5).values["rays"] else { return XCTFail() }
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
        XCTAssertEqual(morph(a, b, specs: specs, t: 0.49).values["time"], .choice("Dawn"))
        XCTAssertEqual(morph(a, b, specs: specs, t: 0.5).values["time"], .choice("Moonlight"))
    }
    func testMorphUsesDefaultsForMissingValues() {
        let a = ThemeState(), b = ThemeState(values: ["rays": .number(0.95)])
        guard case let .number(mid)? = morph(a, b, specs: specs, t: 0.5).values["rays"] else { return XCTFail() }
        XCTAssertEqual(mid, (0.55 + 0.95) / 2, accuracy: 1e-9)
    }
    func testBuiltInReactionsAreSixAndStayInRange() {
        let all = ReactionPresets.all
        XCTAssertEqual(all.map(\.name), ["Expressive Pianist", "Calm Ambient", "Synth Explorer", "Music Party", "Minimal", "Wild"])
        var full = InputFrame()
        for l in all.flatMap(\.map.links) { full.values[l.input] = 1 }
        for p in all {
            let roles = p.map.evaluate(full).roles
            for r in Role.allCases {
                XCTAssertTrue((r.isSigned ? -1.0...1.0 : 0.0...1.0).contains(roles[r]), "\(p.name) \(r)")
            }
        }
    }
    func testBuiltInLooksAreValid() {
        XCTAssertEqual(ButterflyGardenModel.builtInLooks.map(\.name),
                       ["Monarch Morning", "Morpho Dream", "Golden Hour Meadow", "Moonlit Moths", "Crystal Garden", "Neon Night"])
        for look in ButterflyGardenModel.builtInLooks {
            for (id, value) in look.state.values {
                let spec = specs.first { $0.id == id }
                XCTAssertNotNil(spec, "\(look.name): unknown setting \(id)")
                XCTAssertEqual(spec?.validated(value), value, "\(look.name): invalid \(id)")
            }
            XCTAssertEqual(look.themeID, ButterflyGardenModel.id)
        }
    }

    /// Reef Marimba's four presets (spec §4.4), each dial in the instrument's order: Mallet, Strike, Tube, Roll, Steel,
    /// Space, Width. The first is the default.
    func testReefMarimbaPresets() {
        let presets = PatchLibrary.patches(for: .reefMarimba)
        XCTAssertEqual(presets.map(\.id), ["reef-marimba", "soft-yarn", "lagoon-steel", "night-reef"])
        XCTAssertEqual(presets.map(\.name), ["Reef Marimba", "Soft Yarn", "Lagoon Steel", "Night Reef"])
        let dials = ["mallet", "strike", "tube", "roll", "steel", "space", "width"]
        for p in presets { XCTAssertEqual(Set(p.values.keys), Set(dials), p.id) }
        let expected: [[Double]] = [[0.45, 0.40, 0.70, 0.35, 0.20, 0.35, 0.55],
                                    [0.15, 0.35, 0.85, 0.45, 0.00, 0.40, 0.50],
                                    [0.60, 0.45, 0.55, 0.25, 0.70, 0.40, 0.60],
                                    [0.30, 0.50, 0.80, 0.55, 0.10, 0.55, 0.60]]
        XCTAssertEqual(presets.map { p in dials.map { p.values[$0] ?? -1 } }, expected)
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .reefMarimba).id, "reef-marimba")
    }

    /// Single Note Grand's four presets (Storms spec §4.2; brief single-note-grand.md), each after "Runaway": the dials in
    /// the instrument's order (Hall, Felt, Morph, Octave Down, Break, Width, Space), Runaway first and the default (the
    /// engine's own defaults). The spec lists only what differs from Runaway: Marble Hall (Hall 1), Broken Voice (Morph
    /// .6, Break .9) and Dry Grand (Hall .1); Felt is .2 in every one; every other dial is Runaway's, but Width and Space,
    /// which the spec leaves to the ear.
    func testSingleNoteGrandPresets() {
        let presets = PatchLibrary.patches(for: .singleNoteGrand)
        XCTAssertEqual(presets.map(\.id), ["single-note-grand", "marble-hall", "broken-voice", "dry-grand"])
        XCTAssertEqual(presets.map(\.name), ["Runaway", "Marble Hall", "Broken Voice", "Dry Grand"])
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .singleNoteGrand).id, "single-note-grand")
        XCTAssertEqual(BuiltInEngine.singleNoteGrand.displayName, "Single Note Grand")
        XCTAssertEqual(BuiltInEngine(rawValue: "singleNoteGrand"), .singleNoteGrand)
        let dials = ["hall", "felt", "morph", "octaveDown", "break", "width", "space"]
        let expected: [String: [Double]] = ["single-note-grand": [0.70, 0.20, 0.00, 0.50, 0.50, 0.50, 0.50],
                                            "marble-hall": [1.00, 0.20, 0.00, 0.50, 0.50, 0.70, 0.70],
                                            "broken-voice": [0.70, 0.20, 0.60, 0.50, 0.90, 0.40, 0.40],
                                            "dry-grand": [0.10, 0.20, 0.00, 0.50, 0.50, 0.45, 0.25]]
        for p in presets {
            XCTAssertEqual(p.engine, .singleNoteGrand, p.id)
            XCTAssertEqual(Set(p.values.keys), Set(dials), p.id)
            XCTAssertEqual(dials.map { p.values[$0] ?? -1 }, expected[p.id], p.id)
            XCTAssertEqual(p.values["felt"], 0.20, "Felt is .2 in every preset (\(p.id))")
            XCTAssertEqual(p.creditID, "runaway", p.id)
            XCTAssertEqual(p.credit, CreditLibrary.runaway, p.id)
            XCTAssertEqual(p.displayName, "\(p.name) · after \"Runaway\"", p.id)
        }
        // What each differs from Runaway in, and nothing else but the room's width and space.
        let runaway = PatchLibrary.defaultPatch(for: .singleNoteGrand).values
        let differs: [String: Set<String>] = ["marble-hall": ["hall"], "broken-voice": ["morph", "break"], "dry-grand": ["hall"]]
        for p in presets.dropFirst() {
            let changed = Set(dials.filter { p.values[$0] != runaway[$0] }).subtracting(["width", "space"])
            XCTAssertEqual(changed, differs[p.id], p.id)
        }
    }

    /// Blue Depth's four presets (spec §4.2), each after "Underwater": the dials in their order (Blink, Murk, Ghosts,
    /// Echo, Bass, Tempo, Space, Width) with the spec table's values, every one at the record's 118 BPM.
    func testBlueDepthPresets() {
        let presets = PatchLibrary.patches(for: .blueDepth)
        XCTAssertEqual(presets.map(\.id), ["blue-depth", "ghost-signal", "pressure-hull", "surface-light"])
        XCTAssertEqual(presets.map(\.name), ["Blue Depth", "Ghost Signal", "Pressure Hull", "Surface Light"])
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .blueDepth).id, "blue-depth")
        XCTAssertEqual(BuiltInEngine.blueDepth.displayName, "Blue Depth")
        XCTAssertEqual(BuiltInEngine(rawValue: "blueDepth"), .blueDepth)
        let dials = ["blink", "murk", "ghosts", "echo", "bass", "tempo", "space", "width"]
        let expected: [String: [Double]] = ["blue-depth": [0.60, 0.55, 0.40, 0.50, 0.55, 118, 0.55, 0.60],
                                            "ghost-signal": [0.35, 0.45, 0.75, 0.65, 0.30, 118, 0.70, 0.70],
                                            "pressure-hull": [0.75, 0.80, 0.25, 0.40, 0.80, 118, 0.45, 0.50],
                                            "surface-light": [0.50, 0.25, 0.35, 0.55, 0.40, 118, 0.50, 0.65]]
        for p in presets {
            XCTAssertEqual(p.engine, .blueDepth, p.id)
            XCTAssertEqual(Set(p.values.keys), Set(dials), p.id)
            XCTAssertEqual(dials.map { p.values[$0] ?? -1 }, expected[p.id], p.id)
            XCTAssertEqual(p.creditID, "underwater", p.id)
            XCTAssertEqual(p.credit, CreditLibrary.underwater, p.id)
            XCTAssertEqual(p.displayName, "\(p.name) · after \"Underwater\"", p.id)
        }
    }

    /// Endless Rise's four presets (Storms spec §4.1; brief endless-rise.md), each after "FADE": the dials in the
    /// instrument's order (Rise, Pressure, Grit, Pulse, Tempo, Tail, Sub, Space, Width), Supercell first and the default
    /// (the engine's own defaults). The spec lists only what differs from Supercell: Slow Front (Rise .03, Pulse 0, Tail 1),
    /// Siren (Rise .3, Grit .6, Pulse .8 at 128) and Pad Only (Rise 0, the riser off); every other dial is Supercell's, but
    /// Space and Width, which the spec leaves to the ear.
    func testEndlessRisePresets() {
        let presets = PatchLibrary.patches(for: .endlessRise)
        XCTAssertEqual(presets.map(\.id), ["endless-rise", "slow-front", "siren", "pad-only"])
        XCTAssertEqual(presets.map(\.name), ["Supercell", "Slow Front", "Siren", "Pad Only"])
        XCTAssertEqual(PatchLibrary.defaultPatch(for: .endlessRise).id, "endless-rise")
        XCTAssertEqual(BuiltInEngine.endlessRise.displayName, "Endless Rise")
        XCTAssertEqual(BuiltInEngine(rawValue: "endlessRise"), .endlessRise)
        let dials = ["rise", "pressure", "grit", "pulse", "tempo", "tail", "sub", "space", "width"]
        let expected: [String: [Double]] = ["endless-rise": [0.08, 0.40, 0.30, 0.50, 124, 0.60, 0.70, 0.50, 0.60],
                                            "slow-front": [0.03, 0.40, 0.30, 0.00, 124, 1.00, 0.70, 0.70, 0.75],
                                            "siren": [0.30, 0.40, 0.60, 0.80, 128, 0.60, 0.70, 0.35, 0.50],
                                            "pad-only": [0.00, 0.40, 0.30, 0.50, 124, 0.60, 0.70, 0.60, 0.70]]
        for p in presets {
            XCTAssertEqual(p.engine, .endlessRise, p.id)
            XCTAssertEqual(Set(p.values.keys), Set(dials), p.id)
            XCTAssertEqual(dials.map { p.values[$0] ?? -1 }, expected[p.id], p.id)
            XCTAssertEqual(p.creditID, "fade", p.id)
            XCTAssertEqual(p.credit, CreditLibrary.fade, p.id)
            XCTAssertEqual(p.displayName, "\(p.name) · after \"FADE\"", p.id)
        }
        // What each differs from Supercell in, and nothing else but the room.
        let supercell = PatchLibrary.defaultPatch(for: .endlessRise).values
        let differs: [String: Set<String>] = ["slow-front": ["rise", "pulse", "tail"], "siren": ["rise", "grit", "pulse", "tempo"],
                                              "pad-only": ["rise"]]
        for p in presets.dropFirst() {
            let changed = Set(dials.filter { p.values[$0] != supercell[$0] }).subtracting(["space", "width"])
            XCTAssertEqual(changed, differs[p.id], p.id)
        }
    }
}
