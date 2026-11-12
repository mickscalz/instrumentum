import Foundation

/// The instrument plugin the user chose, plus its saved state (e.g. which preset).
public struct InstrumentChoice: Codable, Equatable {
    public var name: String
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32
    /// The plugin's full state as a binary property list.
    public var stateData: Data?

    public init(name: String, componentType: UInt32, componentSubType: UInt32,
                componentManufacturer: UInt32, stateData: Data? = nil) {
        self.name = name
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.stateData = stateData
    }
}

public struct AppSettings: Codable, Equatable {
    public var instrument: InstrumentChoice?
    public var themeID: String = "midnight-steinway"
    public var masterVolume: Float = 0.8
    public var touchCurve: TouchCurve = .normal
    /// Audio output buffer in frames: 128 (fastest), 256 (balanced), 512 (safe), 1024 (safest).
    public var bufferFrames: UInt32 = 256
    /// The chosen output device's unique ID; nil follows the Mac's default output.
    public var outputDeviceUID: String?
    /// 1…16 to listen to one MIDI channel only; nil for all channels.
    public var midiChannel: Int?
    /// MIDI inputs switched off (by name).
    public var disabledMIDISources: [String] = []
    public var themeStates: [String: ThemeState] = [:]
    /// Smooth (lite) by default: fastest and lowest latency; raise it in Display → Quality.
    public var quality: QualitySetting = .lite
    /// 2 = saved after the performance fix (older files start on Smooth once).
    public var qualityVersion: Int = 2
    public var gentleVisuals: Bool = false
    /// The active reaction style; nil means the built-in named by `reactionName`.
    public var reaction: ReactionMap?
    public var reactionName: String = "Expressive Pianist"
    public var sky = SkySettings()
    public var ambience = AmbienceSettings()
    /// The Set (world + visual + instrument + ambience) last chosen, if any.
    public var activeSetID: String?
    /// The pedal that holds the moment (Small Wins spec §4).
    public var holdPedal: HoldPedal = .soft
    /// The MIDI keyboard's range, where the keep gesture's three black keys are (spec §2).
    public var keyboardRange: KeyboardRange = .keys88
    /// Breathing ambience (spec §5): here rather than in `ambience`, which a set overwrites.
    public var breath = AmbienceBreathSettings()
    /// Follow the Mac's Reduce Motion (spec §6).
    public var followReduceMotion = true
    /// Excitement's controls (Fire & Neon spec §5): Energy, Big moments, Surprises, Build and drop. The app's, not a
    /// set's, so applying a set leaves them alone; saved before Excitement existed, they load as the defaults.
    public var excitement = ExcitementSettings()
    /// The gallery the last launch saw ("opens on what's new", the owner's standing rule): its newest set and how many
    /// sets it held. A build with a newer newest set, or more sets, opens on its newest once (`opensOnWhatsNew`). Settings
    /// saved before the rule have neither (nil), so they open on it once too; a first install starts with this build's
    /// own, as it has nothing it hasn't seen.
    public var lastNewestSetID: String? = SetLibrary.newest.id
    public var lastSetCount: Int? = SetLibrary.all.count

    public static let `default` = AppSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case instrument, themeID, masterVolume, touchCurve, bufferFrames, themeStates, quality, gentleVisuals, reaction, reactionName,
             qualityVersion, sky, ambience, activeSetID, outputDeviceUID, midiChannel, disabledMIDISources
        case holdPedal, keyboardRange, breath, followReduceMotion, excitement
        case lastNewestSetID, lastSetCount
    }

    /// True when this build's gallery holds something the last launch didn't see: a newer newest set, or more sets than
    /// it counted; and, once, for settings saved before the rule (no `lastNewestSetID`).
    public var opensOnWhatsNew: Bool {
        let seenNewest = lastNewestSetID == SetLibrary.newest.id
        let seenCount = lastSetCount ?? 0
        return !seenNewest || seenCount < SetLibrary.all.count
    }

    /// Records this build's gallery as seen, so later launches restore the player's last set as before.
    public mutating func markSetsSeen() {
        lastNewestSetID = SetLibrary.newest.id
        lastSetCount = SetLibrary.all.count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        instrument = try c.decodeIfPresent(InstrumentChoice.self, forKey: .instrument)
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        masterVolume = try c.decodeIfPresent(Float.self, forKey: .masterVolume) ?? d.masterVolume
        touchCurve = (try? c.decodeIfPresent(TouchCurve.self, forKey: .touchCurve)) ?? d.touchCurve
        bufferFrames = try c.decodeIfPresent(UInt32.self, forKey: .bufferFrames) ?? d.bufferFrames
        themeStates = (try? c.decodeIfPresent([String: ThemeState].self, forKey: .themeStates)) ?? d.themeStates
        quality = (try? c.decodeIfPresent(QualitySetting.self, forKey: .quality)) ?? d.quality
        qualityVersion = (try? c.decodeIfPresent(Int.self, forKey: .qualityVersion)) ?? 1
        if qualityVersion < 2 { quality = .lite; qualityVersion = 2 }
        gentleVisuals = (try? c.decodeIfPresent(Bool.self, forKey: .gentleVisuals)) ?? d.gentleVisuals
        reaction = try? c.decodeIfPresent(ReactionMap.self, forKey: .reaction)
        reactionName = (try? c.decodeIfPresent(String.self, forKey: .reactionName)) ?? d.reactionName
        sky = (try? c.decodeIfPresent(SkySettings.self, forKey: .sky)) ?? d.sky
        ambience = (try? c.decodeIfPresent(AmbienceSettings.self, forKey: .ambience)) ?? d.ambience
        activeSetID = (try? c.decodeIfPresent(String.self, forKey: .activeSetID)) ?? nil
        outputDeviceUID = (try? c.decodeIfPresent(String.self, forKey: .outputDeviceUID)) ?? nil
        midiChannel = ((try? c.decodeIfPresent(Int.self, forKey: .midiChannel)) ?? nil).flatMap { (1...16).contains($0) ? $0 : nil }
        disabledMIDISources = (try? c.decodeIfPresent([String].self, forKey: .disabledMIDISources)) ?? d.disabledMIDISources
        holdPedal = (try? c.decodeIfPresent(HoldPedal.self, forKey: .holdPedal)) ?? d.holdPedal
        keyboardRange = (try? c.decodeIfPresent(KeyboardRange.self, forKey: .keyboardRange)) ?? d.keyboardRange
        breath = (try? c.decodeIfPresent(AmbienceBreathSettings.self, forKey: .breath)) ?? d.breath
        followReduceMotion = (try? c.decodeIfPresent(Bool.self, forKey: .followReduceMotion)) ?? d.followReduceMotion
        excitement = (try? c.decodeIfPresent(ExcitementSettings.self, forKey: .excitement)) ?? d.excitement
        // Absent (saved before "opens on what's new"): nil, not this build's, so the next launch opens on the newest once.
        lastNewestSetID = (try? c.decodeIfPresent(String.self, forKey: .lastNewestSetID)) ?? nil
        lastSetCount = (try? c.decodeIfPresent(Int.self, forKey: .lastSetCount)) ?? nil
    }
}

/// Reads and writes settings.json. Never throws on load.
public final class SettingsStore {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private var corruptURL: URL { directory.appendingPathComponent("settings.corrupt.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .default }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) { return settings }
        let fm = FileManager.default
        try? fm.removeItem(at: corruptURL)
        try? fm.moveItem(at: fileURL, to: corruptURL)
        return .default
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
