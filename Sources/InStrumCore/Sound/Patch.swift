/// The app's own instruments (made entirely in the app, no recordings).
public enum BuiltInEngine: String, Codable, CaseIterable {
    case feltGlass, orbitPad, honeyTape, hazeBells, cabinFelt, morningBox, polarChoir, planktonKeys, teaHouseKoto, zenShakuhachi
    case blueDepth
    case reefMarimba
    case magmaBass, replicantBrass
    case endlessRise

    /// Storms, Set 18 (engine 17).
    case singleNoteGrand

    public var displayName: String {
        switch self {
        case .feltGlass: return "Felt Glass"
        case .orbitPad: return "Orbit Pad"
        case .honeyTape: return "Honey Tape"
        case .hazeBells: return "Haze Bells"
        case .cabinFelt: return "Cabin Felt"
        case .morningBox: return "Morning Box"
        case .polarChoir: return "Polar Choir"
        case .planktonKeys: return "Plankton Keys"
        case .teaHouseKoto: return "Tea House Koto"
        case .zenShakuhachi: return "Zen Shakuhachi"
        case .reefMarimba: return "Reef Marimba"
        case .blueDepth: return "Blue Depth"
        case .magmaBass: return "Magma Bass"
        case .singleNoteGrand: return "Single Note Grand"
        case .replicantBrass: return "Replicant Brass"
        case .endlessRise: return "Endless Rise"
        }
    }

    /// The dials that run the instrument's arpeggiator, in the order the instrument panel's Arp row shows them (Fire & Neon
    /// spec §4.4): Blue Depth's own arp (Blink, how much the held chord blinks, and Tempo) and Replicant Brass's shared one,
    /// which plays Chrome Bass in the left hand (Arp, the mode; Rate; Tempo; Split, where the left hand ends). Empty for an
    /// engine with no arp: Magma Bass has none, nor do the others.
    public var arpDials: [String] {
        switch self {
        case .blueDepth: return ["blink", "tempo"]
        case .replicantBrass: return ["arp", "rate", "tempo", "split"]
        default: return []
        }
    }

    /// Whether the instrument has an arpeggiator, so its panel shows an Arp row.
    public var supportsArp: Bool { !arpDials.isEmpty }
}

/// A recipe for a built-in instrument: which engine, its dial values (keyed by parameter identifier) and its trim.
public struct Patch: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var engine: BuiltInEngine
    public var values: [String: Double]
    /// The song that inspired it (see `CreditLibrary`), if any.
    public var creditID: String?
    /// The preset's trim in decibels: a plain gain on the instrument's whole output where the preset is loaded
    /// (`BuiltInInstrumentAU.apply`), so that switching preset never jumps in volume. Each built-in preset's is set by
    /// measurement: its engine's demo phrase sits within 1 LU of the built-in presets' median loudness (ITU-R BS.1770-4),
    /// within ±9 dB, its true peak no higher than −1 dBTP. It is not a dial: never shown, never moved by the player, and
    /// the player's volume and every dial are as they were. A patch saved before trims existed decodes with 0.
    public var trimDB: Double

    public init(id: String, name: String, engine: BuiltInEngine, values: [String: Double], creditID: String? = nil,
                trimDB: Double = 0) {
        self.id = id; self.name = name; self.engine = engine; self.values = values; self.creditID = creditID
        self.trimDB = trimDB
    }

    enum CodingKeys: String, CodingKey { case id, name, engine, values, creditID, trimDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(BuiltInEngine.self, forKey: .engine)
        values = try c.decode([String: Double].self, forKey: .values)
        creditID = try c.decodeIfPresent(String.self, forKey: .creditID)
        trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
    }

    /// The built-in preset with this id on this engine, if there is one.
    public static func builtIn(id: String?, engine: BuiltInEngine) -> Patch? {
        guard let id else { return nil }
        return PatchLibrary.all.first { $0.id == id && $0.engine == engine }
    }
}

/// The built-in presets (values from docs/superpowers/briefs).
public enum PatchLibrary {
    public static let all: [Patch] = [
        Patch(id: "felt-glass", name: "Felt Glass", engine: .feltGlass, values: dials(felt: 0.55, glass: 0.35, warmth: 0.60, ring: 0.55, space: 0.45, width: 0.50), creditID: "come-back-to-earth"),
        Patch(id: "bare-felt", name: "Bare Felt", engine: .feltGlass, values: dials(felt: 0.70, glass: 0.00, warmth: 0.65, ring: 0.50, space: 0.35, width: 0.45), creditID: "come-back-to-earth"),
        Patch(id: "glass-choir", name: "Glass Choir", engine: .feltGlass, values: dials(felt: 0.40, glass: 0.75, warmth: 0.50, ring: 0.70, space: 0.60, width: 0.70), creditID: "come-back-to-earth"),
        Patch(id: "lullaby", name: "Lullaby", engine: .feltGlass, values: dials(felt: 0.85, glass: 0.20, warmth: 0.80, ring: 0.45, space: 0.30, width: 0.35), creditID: "come-back-to-earth"),
        Patch(id: "orbit-pad", name: "Orbit Pad", engine: .orbitPad, values: pad(bloom: 0.55, drift: 0.40, motion: 0.45, shimmer: 0.25, brightness: 0.50, space: 0.55), creditID: "innerbloom"),
        Patch(id: "earthrise", name: "Earthrise", engine: .orbitPad, values: pad(bloom: 0.75, drift: 0.30, motion: 0.30, shimmer: 0.15, brightness: 0.40, space: 0.50), creditID: "innerbloom"),
        Patch(id: "weightless", name: "Weightless", engine: .orbitPad, values: pad(bloom: 0.50, drift: 0.45, motion: 0.55, shimmer: 0.60, brightness: 0.55, space: 0.75), creditID: "innerbloom"),
        Patch(id: "re-entry", name: "Re-entry", engine: .orbitPad, values: pad(bloom: 0.25, drift: 0.35, motion: 0.50, shimmer: 0.20, brightness: 0.75, space: 0.45), creditID: "innerbloom"),
        Patch(id: "honey-tape", name: "Honey Tape", engine: .honeyTape, values: tape(breath: 0.45, strings: 0.30, wow: 0.35, age: 0.40, reel: 0, space: 0.50, width: 0.50), creditID: "music-to-watch-boys-to"),
        Patch(id: "sea-flute", name: "Sea Flute", engine: .honeyTape, values: tape(breath: 0.70, strings: 0, wow: 0.30, age: 0.35, reel: 0, space: 0.55, width: 0.45), creditID: "music-to-watch-boys-to"),
        Patch(id: "velvet-strings", name: "Velvet Strings", engine: .honeyTape, values: tape(breath: 0.20, strings: 1, wow: 0.25, age: 0.35, reel: 0, space: 0.50, width: 0.70), creditID: "music-to-watch-boys-to"),
        Patch(id: "old-reel", name: "Old Reel", engine: .honeyTape, values: tape(breath: 0.45, strings: 0.35, wow: 0.70, age: 0.75, reel: 1, space: 0.45, width: 0.50), creditID: "music-to-watch-boys-to"),
        Patch(id: "haze-bells", name: "Haze Bells", engine: .hazeBells, values: bells(bells: 0.80, organ: 0.25, echo: 0.35, crush: 0.15, drift: 0.30, space: 0.50), creditID: "high-by-the-beach"),
        Patch(id: "church-keys", name: "Church Keys", engine: .hazeBells, values: bells(bells: 0.45, organ: 0.80, echo: 0.25, crush: 0.10, drift: 0.20, space: 0.60), creditID: "high-by-the-beach"),
        Patch(id: "night-drive", name: "Night Drive", engine: .hazeBells, values: bells(bells: 0.80, organ: 0.30, echo: 0.65, crush: 0.15, drift: 0.35, space: 0.70), creditID: "high-by-the-beach"),
        Patch(id: "lo-fi", name: "Lo-Fi", engine: .hazeBells, values: bells(bells: 0.75, organ: 0.30, echo: 0.40, crush: 0.60, drift: 0.60, space: 0.45), creditID: "high-by-the-beach"),
        Patch(id: "cabin-felt", name: "Cabin Felt", engine: .cabinFelt, values: cabin(felt: 0.60, horn: 0.30, fire: 0.50, wood: 0.50, space: 0.35, width: 0.50), creditID: "stay"),
        Patch(id: "fireside", name: "Fireside", engine: .cabinFelt, values: cabin(felt: 0.55, horn: 0, fire: 0.70, wood: 0.60, space: 0.30, width: 0.45), creditID: "stay"),
        Patch(id: "snow-horn", name: "Snow Horn", engine: .cabinFelt, values: cabin(felt: 0.70, horn: 0.75, fire: 0.45, wood: 0.45, space: 0.50, width: 0.55), creditID: "stay"),
        Patch(id: "late-night", name: "Late Night", engine: .cabinFelt, values: cabin(felt: 0.85, horn: 0.20, fire: 0.60, wood: 0.35, space: 0.25, width: 0.40), creditID: "stay"),
        Patch(id: "morning-box", name: "Morning Box", engine: .morningBox, values: morning(bars: 0.60, box: 0.20, bloom: 0.40, build: 0.50, haze: 0.35, space: 0.50, width: 0.55), creditID: "dunno"),
        Patch(id: "music-box", name: "Music Box", engine: .morningBox, values: morning(bars: 0.50, box: 1, bloom: 0.10, build: 0.20, haze: 0.25, space: 0.40, width: 0.40), creditID: "dunno"),
        Patch(id: "wall-of-light", name: "Wall of Light", engine: .morningBox, values: morning(bars: 0.45, box: 0.15, bloom: 0.85, build: 0.90, haze: 0.45, space: 0.65, width: 0.80), creditID: "dunno"),
        Patch(id: "snooze", name: "Snooze", engine: .morningBox, values: morning(bars: 0.35, box: 0.30, bloom: 0.55, build: 0.40, haze: 0.70, space: 0.55, width: 0.50), creditID: "dunno"),
        Patch(id: "polar-choir", name: "Polar Choir", engine: .polarChoir, values: choir(vowel: 0.55, breath: 0.35, glass: 0.30, swell: 0.55, shimmer: 0.25, space: 0.60, width: 0.60), creditID: "wings"),
        Patch(id: "far-voices", name: "Far Voices", engine: .polarChoir, values: choir(vowel: 0.70, breath: 0.55, glass: 0.10, swell: 0.75, shimmer: 0.40, space: 0.80, width: 0.75), creditID: "wings"),
        Patch(id: "bowed-glass", name: "Bowed Glass", engine: .polarChoir, values: choir(vowel: 0.40, breath: 0.10, glass: 0.85, swell: 0.45, shimmer: 0.30, space: 0.55, width: 0.50), creditID: "wings"),
        Patch(id: "hush", name: "Hush", engine: .polarChoir, values: choir(vowel: 0.30, breath: 0.50, glass: 0.20, swell: 0.35, shimmer: 0.10, space: 0.45, width: 0.40), creditID: "wings"),
        Patch(id: "plankton-keys", name: "Plankton Keys", engine: .planktonKeys, values: keys(tine: 0.55, bark: 0.40, sparkle: 0.50, tremolo: 0.35, phase: 0.20, space: 0.50, width: 0.55), creditID: "happiness-is-a-butterfly"),
        Patch(id: "glow-wake", name: "Glow Wake", engine: .planktonKeys, values: keys(tine: 0.65, bark: 0.30, sparkle: 0.85, tremolo: 0.50, phase: 0.35, space: 0.65, width: 0.70), creditID: "happiness-is-a-butterfly"),
        Patch(id: "tide-tines", name: "Tide Tines", engine: .planktonKeys, values: keys(tine: 0.85, bark: 0.60, sparkle: 0.25, tremolo: 0.20, phase: 0.10, space: 0.40, width: 0.50), creditID: "happiness-is-a-butterfly"),
        Patch(id: "midnight-bay", name: "Midnight Bay", engine: .planktonKeys, values: keys(tine: 0.35, bark: 0.20, sparkle: 0.40, tremolo: 0.45, phase: 0.30, space: 0.70, width: 0.60), creditID: "happiness-is-a-butterfly"),
        // Tea House Koto is born from its place (Tea House Snow), not from a song: no credit, so the names stay plain.
        Patch(id: "tea-house-koto", name: "Tea House Koto", engine: .teaHouseKoto, values: koto(pick: 0.55, silk: 0.45, body: 0.50, bloom: 0.40, yuri: 0.30, space: 0.35, width: 0.50)),
        Patch(id: "winter-strings", name: "Winter Strings", engine: .teaHouseKoto, values: koto(pick: 0.35, silk: 0.70, body: 0.60, bloom: 0.55, yuri: 0.20, space: 0.45, width: 0.55)),
        Patch(id: "near-the-bridge", name: "Near the Bridge", engine: .teaHouseKoto, values: koto(pick: 0.15, silk: 0.25, body: 0.40, bloom: 0.25, yuri: 0.35, space: 0.25, width: 0.45)),
        Patch(id: "night-tea", name: "Night Tea", engine: .teaHouseKoto, values: koto(pick: 0.45, silk: 0.60, body: 0.55, bloom: 0.60, yuri: 0.40, space: 0.50, width: 0.50)),
        // Zen Shakuhachi is born from its place (Zen Rock Garden), not from a song: no credit, so the names stay plain.
        Patch(id: "zen-shakuhachi", name: "Zen Shakuhachi", engine: .zenShakuhachi, values: shakuhachi(breath: 0.45, air: 0.55, bend: 0.60, bamboo: 0.50, yuri: 0.40, echo: 0.30, space: 0.40, width: 0.45)),
        Patch(id: "mountain-breath", name: "Mountain Breath", engine: .zenShakuhachi, values: shakuhachi(breath: 0.60, air: 0.70, bend: 0.70, bamboo: 0.45, yuri: 0.50, echo: 0.70, space: 0.60, width: 0.55)),
        Patch(id: "hollow-bamboo", name: "Hollow Bamboo", engine: .zenShakuhachi, values: shakuhachi(breath: 0.30, air: 0.35, bend: 0.40, bamboo: 0.85, yuri: 0.30, echo: 0.15, space: 0.25, width: 0.40)),
        Patch(id: "still-air", name: "Still Air", engine: .zenShakuhachi, values: shakuhachi(breath: 0.75, air: 0.90, bend: 0.50, bamboo: 0.40, yuri: 0.25, echo: 0.40, space: 0.55, width: 0.50)),
        // Reef Marimba is born from its place (Great Barrier Reef), not from a song: no credit, so the names stay plain.
        Patch(id: "reef-marimba", name: "Reef Marimba", engine: .reefMarimba, values: reefMarimba(mallet: 0.45, strike: 0.40, tube: 0.70, roll: 0.35, steel: 0.20, space: 0.35, width: 0.55)),
        Patch(id: "soft-yarn", name: "Soft Yarn", engine: .reefMarimba, values: reefMarimba(mallet: 0.15, strike: 0.35, tube: 0.85, roll: 0.45, steel: 0.00, space: 0.40, width: 0.50)),
        Patch(id: "lagoon-steel", name: "Lagoon Steel", engine: .reefMarimba, values: reefMarimba(mallet: 0.60, strike: 0.45, tube: 0.55, roll: 0.25, steel: 0.70, space: 0.40, width: 0.60)),
        Patch(id: "night-reef", name: "Night Reef", engine: .reefMarimba, values: reefMarimba(mallet: 0.30, strike: 0.50, tube: 0.80, roll: 0.55, steel: 0.10, space: 0.55, width: 0.60)),
        // Blue Depth, after "Underwater" (spec §4.2): every preset at the record's 118 BPM.
        Patch(id: "blue-depth", name: "Blue Depth", engine: .blueDepth, values: blueDepth(blink: 0.60, murk: 0.55, ghosts: 0.40, echo: 0.50, bass: 0.55, tempo: 118, space: 0.55, width: 0.60), creditID: "underwater"),
        Patch(id: "ghost-signal", name: "Ghost Signal", engine: .blueDepth, values: blueDepth(blink: 0.35, murk: 0.45, ghosts: 0.75, echo: 0.65, bass: 0.30, tempo: 118, space: 0.70, width: 0.70), creditID: "underwater"),
        Patch(id: "pressure-hull", name: "Pressure Hull", engine: .blueDepth, values: blueDepth(blink: 0.75, murk: 0.80, ghosts: 0.25, echo: 0.40, bass: 0.80, tempo: 118, space: 0.45, width: 0.50), creditID: "underwater"),
        Patch(id: "surface-light", name: "Surface Light", engine: .blueDepth, values: blueDepth(blink: 0.50, murk: 0.25, ghosts: 0.35, echo: 0.55, bass: 0.40, tempo: 118, space: 0.50, width: 0.65), creditID: "underwater"),
        // Single Note Grand, after "Runaway" (Storms spec §4.2; brief single-note-grand.md): the brief's table, Runaway
        // first (the engine's defaults), Felt .2 in every one. The spec sets no Width or Space: Runaway keeps the engine's
        // (.50, .50); Marble Hall opens out with its room, Broken Voice comes closer so the voice stays in front, Dry Grand
        // is dry and close. Reasoned rather than heard, so check them by ear.
        Patch(id: "single-note-grand", name: "Runaway", engine: .singleNoteGrand, values: singleNoteGrand(hall: 0.70, felt: 0.20, morph: 0, octaveDown: 0.50, breakDrive: 0.50, width: 0.50, space: 0.50), creditID: "runaway"),
        Patch(id: "marble-hall", name: "Marble Hall", engine: .singleNoteGrand, values: singleNoteGrand(hall: 1.0, felt: 0.20, morph: 0, octaveDown: 0.50, breakDrive: 0.50, width: 0.70, space: 0.70), creditID: "runaway"),
        Patch(id: "broken-voice", name: "Broken Voice", engine: .singleNoteGrand, values: singleNoteGrand(hall: 0.70, felt: 0.20, morph: 0.60, octaveDown: 0.50, breakDrive: 0.90, width: 0.40, space: 0.40), creditID: "runaway"),
        Patch(id: "dry-grand", name: "Dry Grand", engine: .singleNoteGrand, values: singleNoteGrand(hall: 0.10, felt: 0.20, morph: 0, octaveDown: 0.50, breakDrive: 0.50, width: 0.45, space: 0.25), creditID: "runaway"),
        // Magma Bass (Fire & Neon spec §4.2; brief magma-bass.md), after "Hold My Liquor" (Volcano Rim's song, spec §11).
        // Mono is 0 or 1.
        Patch(id: "magma-bass", name: "Magma", engine: .magmaBass, values: magma(growl: 0.55, heat: 0.50, erupt: 0.70, rumble: 0.35, grit: 0.25, flow: 0.20, shape: 0.15, mono: 0, spark: 0.40, res: 0.35), creditID: "hold-my-liquor"),
        Patch(id: "basalt", name: "Basalt", engine: .magmaBass, values: magma(growl: 0.40, heat: 0.30, erupt: 0.55, rumble: 0.70, grit: 0.15, flow: 0.35, shape: 0.05, mono: 1, spark: 0.20, res: 0.25), creditID: "hold-my-liquor"),
        Patch(id: "fissure", name: "Fissure", engine: .magmaBass, values: magma(growl: 0.65, heat: 0.70, erupt: 0.80, rumble: 0.20, grit: 0.35, flow: 0.10, shape: 0.40, mono: 0, spark: 0.50, res: 0.60), creditID: "hold-my-liquor"),
        Patch(id: "ember-glide", name: "Ember Glide", engine: .magmaBass, values: magma(growl: 0.50, heat: 0.55, erupt: 0.60, rumble: 0.30, grit: 0.20, flow: 0.70, shape: 0.25, mono: 1, spark: 0.30, res: 0.40), creditID: "hold-my-liquor"),
        // Replicant Brass with Chrome Bass (spec §4.3; brief replicant-brass.md). Neon Night Drive is place-born, so no
        // credit. Arp: 0 off, 1 up, 2 down, 3 up-down, 4 played, 5 random. Rate: 0 1/4 … 3 1/16 … 5 1/32. Split: a
        // note number (below 28: no split). Tempo in BPM (70…170).
        Patch(id: "replicant-brass", name: "Replicant", engine: .replicantBrass, values: replicant(swell: 0.60, blaze: 0.50, width: 0.70, hall: 0.55, chrome: 0.60, punch: 0.50, arp: 4, rate: 3, split: 48, tempo: 120)),
        Patch(id: "tears-in-rain", name: "Tears in Rain", engine: .replicantBrass, values: replicant(swell: 0.85, blaze: 0.35, width: 0.80, hall: 0.80, chrome: 0.45, punch: 0.35, arp: 4, rate: 1, split: 48, tempo: 120)),
        Patch(id: "chrome-rush", name: "Chrome Rush", engine: .replicantBrass, values: replicant(swell: 0.35, blaze: 0.65, width: 0.60, hall: 0.40, chrome: 0.75, punch: 0.80, arp: 1, rate: 3, split: 48, tempo: 132)),
        Patch(id: "night-brass", name: "Night Brass", engine: .replicantBrass, values: replicant(swell: 0.70, blaze: 0.55, width: 0.75, hall: 0.65, chrome: 0.60, punch: 0.50, arp: 0, rate: 3, split: 0, tempo: 120)),
        // Endless Rise, after "FADE" (Storms spec §4.1; brief endless-rise.md): the brief's table, Supercell first (the
        // engine's defaults). The spec sets no Space or Width: Supercell keeps the engine's (.50, .60); the others lean
        // with their character (Slow Front far and wide, Siren close so its pulse stays tight, Pad Only with air round it),
        // reasoned rather than heard, so check them by ear.
        Patch(id: "endless-rise", name: "Supercell", engine: .endlessRise, values: endlessRise(rise: 0.08, pressure: 0.40, grit: 0.30, pulse: 0.50, tempo: 124, tail: 0.60, sub: 0.70, space: 0.50, width: 0.60), creditID: "fade"),
        Patch(id: "slow-front", name: "Slow Front", engine: .endlessRise, values: endlessRise(rise: 0.03, pressure: 0.40, grit: 0.30, pulse: 0, tempo: 124, tail: 1.0, sub: 0.70, space: 0.70, width: 0.75), creditID: "fade"),
        Patch(id: "siren", name: "Siren", engine: .endlessRise, values: endlessRise(rise: 0.30, pressure: 0.40, grit: 0.60, pulse: 0.80, tempo: 128, tail: 0.60, sub: 0.70, space: 0.35, width: 0.50), creditID: "fade"),
        Patch(id: "pad-only", name: "Pad Only", engine: .endlessRise, values: endlessRise(rise: 0, pressure: 0.40, grit: 0.30, pulse: 0.50, tempo: 124, tail: 0.60, sub: 0.70, space: 0.60, width: 0.70), creditID: "fade"),
    ]

    public static func defaultPatch(for engine: BuiltInEngine) -> Patch {
        all.first { $0.engine == engine }!
    }

    public static func patches(for engine: BuiltInEngine) -> [Patch] { all.filter { $0.engine == engine } }

    private static func dials(felt: Double, glass: Double, warmth: Double, ring: Double, space: Double, width: Double) -> [String: Double] {
        ["felt": felt, "glass": glass, "warmth": warmth, "ring": ring, "space": space, "width": width]
    }

    private static func bells(bells: Double, organ: Double, echo: Double, crush: Double, drift: Double, space: Double) -> [String: Double] {
        ["bells": bells, "organ": organ, "echo": echo, "crush": crush, "drift": drift, "space": space]
    }

    private static func tape(breath: Double, strings: Double, wow: Double, age: Double, reel: Double, space: Double, width: Double) -> [String: Double] {
        ["breath": breath, "strings": strings, "wow": wow, "age": age, "reel": reel, "space": space, "width": width]
    }

    private static func cabin(felt: Double, horn: Double, fire: Double, wood: Double, space: Double, width: Double) -> [String: Double] {
        ["felt": felt, "horn": horn, "fire": fire, "wood": wood, "space": space, "width": width]
    }

    private static func morning(bars: Double, box: Double, bloom: Double, build: Double, haze: Double, space: Double, width: Double) -> [String: Double] {
        ["bars": bars, "box": box, "bloom": bloom, "build": build, "haze": haze, "space": space, "width": width]
    }

    private static func choir(vowel: Double, breath: Double, glass: Double, swell: Double, shimmer: Double, space: Double, width: Double) -> [String: Double] {
        ["vowel": vowel, "breath": breath, "glass": glass, "swell": swell, "shimmer": shimmer, "space": space, "width": width]
    }

    private static func keys(tine: Double, bark: Double, sparkle: Double, tremolo: Double, phase: Double, space: Double, width: Double) -> [String: Double] {
        ["tine": tine, "bark": bark, "sparkle": sparkle, "tremolo": tremolo, "phase": phase, "space": space, "width": width]
    }

    private static func koto(pick: Double, silk: Double, body: Double, bloom: Double, yuri: Double, space: Double, width: Double) -> [String: Double] {
        ["pick": pick, "silk": silk, "body": body, "bloom": bloom, "yuri": yuri, "space": space, "width": width]
    }

    private static func shakuhachi(breath: Double, air: Double, bend: Double, bamboo: Double, yuri: Double, echo: Double, space: Double,
                                   width: Double) -> [String: Double] {
        ["breath": breath, "air": air, "bend": bend, "bamboo": bamboo, "yuri": yuri, "echo": echo, "space": space, "width": width]
    }

    private static func reefMarimba(mallet: Double, strike: Double, tube: Double, roll: Double, steel: Double, space: Double, width: Double) -> [String: Double] {
        ["mallet": mallet, "strike": strike, "tube": tube, "roll": roll, "steel": steel, "space": space, "width": width]
    }

    /// Tempo is in BPM (70…160); every other dial 0…1.
    private static func blueDepth(blink: Double, murk: Double, ghosts: Double, echo: Double, bass: Double, tempo: Double, space: Double, width: Double) -> [String: Double] {
        ["blink": blink, "murk": murk, "ghosts": ghosts, "echo": echo, "bass": bass, "tempo": tempo, "space": space, "width": width]
    }

    private static func magma(growl: Double, heat: Double, erupt: Double, rumble: Double, grit: Double, flow: Double, shape: Double, mono: Double, spark: Double, res: Double) -> [String: Double] {
        ["growl": growl, "heat": heat, "erupt": erupt, "rumble": rumble, "grit": grit, "flow": flow, "shape": shape, "mono": mono, "spark": spark, "res": res]
    }

    private static func replicant(swell: Double, blaze: Double, width: Double, hall: Double, chrome: Double, punch: Double, arp: Double, rate: Double, split: Double, tempo: Double) -> [String: Double] {
        ["swell": swell, "blaze": blaze, "width": width, "hall": hall, "chrome": chrome, "punch": punch, "arp": arp, "rate": rate, "split": split, "tempo": tempo]
    }

    /// The dials in the instrument's order. Rise is octaves a second (0 switches the riser off); Tempo is the Pulse's, in
    /// BPM (70…170); every other dial 0…1.
    private static func endlessRise(rise: Double, pressure: Double, grit: Double, pulse: Double, tempo: Double, tail: Double, sub: Double,
                                    space: Double, width: Double) -> [String: Double] {
        ["rise": rise, "pressure": pressure, "grit": grit, "pulse": pulse, "tempo": tempo, "tail": tail, "sub": sub, "space": space, "width": width]
    }

    private static func pad(bloom: Double, drift: Double, motion: Double, shimmer: Double, brightness: Double, space: Double) -> [String: Double] {
        ["bloom": bloom, "drift": drift, "motion": motion, "shimmer": shimmer, "brightness": brightness, "space": space]
    }

    /// The dials in the instrument's order (Hall, Felt, Morph, Octave Down, Break, Width, Space), each 0…1.
    private static func singleNoteGrand(hall: Double, felt: Double, morph: Double, octaveDown: Double, breakDrive: Double, width: Double,
                                        space: Double) -> [String: Double] {
        ["hall": hall, "felt": felt, "morph": morph, "octaveDown": octaveDown, "break": breakDrive, "width": width, "space": space]
    }
}
