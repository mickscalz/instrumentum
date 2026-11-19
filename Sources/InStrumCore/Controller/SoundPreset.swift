import Foundation

/// A sound you saved: the instrument, where its dials were, and the effects and tone on top. Small JSON files in
/// `Presets/sound/`, so they can be backed up or shared.
public struct SoundPreset: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// The instrument it was saved with. A plugin's carries the plugin's whole state; a built-in instrument's carries
    /// none (its dials are in `dials`).
    public var instrument: InstrumentChoice
    /// A built-in instrument's preset the sound started from (its name shows in the panel, and its trim keeps the
    /// loudness level), and every dial's value by identifier, in the dial's own units. Empty for a plugin.
    public var patchID: String?
    public var dials: [String: Double]
    public var fx: SoundFX
    public var version: Int = 1

    public init(name: String, instrument: InstrumentChoice, patchID: String? = nil, dials: [String: Double] = [:],
                fx: SoundFX = SoundFX()) {
        self.name = name; self.instrument = instrument; self.patchID = patchID; self.dials = dials; self.fx = fx
    }

    enum CodingKeys: String, CodingKey { case name, instrument, patchID, dials, fx, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        instrument = try c.decode(InstrumentChoice.self, forKey: .instrument)
        patchID = (try? c.decodeIfPresent(String.self, forKey: .patchID)) ?? nil
        let raw = (try? c.decodeIfPresent([String: Double].self, forKey: .dials)) ?? [:]
        dials = raw.filter { $0.value.isFinite }
        fx = (try? c.decodeIfPresent(SoundFX.self, forKey: .fx)) ?? SoundFX()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
    }

    /// A name that isn't taken: "Sound 1", "Sound 2", …
    public static func freeName(among taken: [String]) -> String {
        var n = taken.count + 1
        while taken.contains("Sound \(n)") { n += 1 }
        return "Sound \(n)"
    }

    /// The saved sound after this one in the list (wrapping round); the first when `current` isn't in it.
    public static func next(after current: String?, in list: [SoundPreset]) -> SoundPreset? {
        guard !list.isEmpty else { return nil }
        guard let current, let i = list.firstIndex(where: { $0.name == current }) else { return list.first }
        return list[(i + 1) % list.count]
    }
}
