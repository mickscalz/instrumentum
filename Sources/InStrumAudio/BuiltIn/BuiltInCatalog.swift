import AVFoundation
import AudioToolbox
import InStrumCore
import InStrumDSP

/// The app's own instruments, registered in-process so they load exactly like installed plugins.
public enum BuiltInCatalog {
    public static let manufacturer: OSType = fourCC("IsMt")
    public static let manufacturerName = "In Strum Meants"

    public static func description(for engine: BuiltInEngine) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                  componentSubType: fourCC(subType(engine)),
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    /// The ambience generator.
    public static let ambienceDescription = AudioComponentDescription(componentType: kAudioUnitType_Generator,
                                                                      componentSubType: fourCC("isAM"),
                                                                      componentManufacturer: manufacturer,
                                                                      componentFlags: 0, componentFlagsMask: 0)

    /// Safe to call any number of times.
    public static func registerAll() { _ = registration }

    private static let registration: Void = {
        for engine in available {
            AUAudioUnit.registerSubclass(BuiltInInstrumentAU.self, as: description(for: engine),
                                         name: "\(manufacturerName): \(engine.displayName)", version: 1)
        }
        AUAudioUnit.registerSubclass(AmbienceAU.self, as: ambienceDescription, name: "\(manufacturerName): Ambience", version: 1)
    }()

    /// Engines the Sound Core can make right now.
    static var available: [BuiltInEngine] {
        BuiltInEngine.allCases.filter { isd_synth_param_count(isdEngine($0)) > 0 }
    }

    /// Picker entries for the built-in instruments.
    public static var instruments: [PluginInfo] {
        available.map { engine in
            let d = description(for: engine)
            return PluginInfo(id: "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)",
                              name: engine.displayName, manufacturer: manufacturerName, description: d)
        }
    }

    public static func engine(for choice: InstrumentChoice) -> BuiltInEngine? {
        guard choice.componentManufacturer == manufacturer, choice.componentType == kAudioUnitType_MusicDevice else { return nil }
        return BuiltInEngine.allCases.first { description(for: $0).componentSubType == choice.componentSubType }
    }

    static func engine(forSubType subType: OSType) -> BuiltInEngine? {
        BuiltInEngine.allCases.first { description(for: $0).componentSubType == subType }
    }

    private static func subType(_ engine: BuiltInEngine) -> String {
        switch engine {
        case .feltGlass: return "isFG"
        case .orbitPad: return "isOP"
        case .honeyTape: return "isHT"
        case .hazeBells: return "isHB"
        case .cabinFelt: return "isCF"
        case .morningBox: return "isMB"
        case .polarChoir: return "isPC"
        case .planktonKeys: return "isPK"
        case .teaHouseKoto: return "isTK"
        case .zenShakuhachi: return "isZS"
        case .reefMarimba: return "isRM"
        case .blueDepth: return "isBD"
        case .magmaBass: return "isMG"   // not isMB: Morning Box has it
        case .singleNoteGrand: return "isSN"   // the plan's isSNG, cut to the four characters a subtype holds
        case .replicantBrass: return "isRB"
        case .endlessRise: return "isER"
        }
    }

    static func isdEngine(_ engine: BuiltInEngine) -> ISDEngine {
        switch engine {
        case .feltGlass: return ISD_ENGINE_FELT_GLASS
        case .orbitPad: return ISD_ENGINE_ORBIT_PAD
        case .honeyTape: return ISD_ENGINE_HONEY_TAPE
        case .hazeBells: return ISD_ENGINE_HAZE_BELLS
        case .cabinFelt: return ISD_ENGINE_CABIN_FELT
        case .morningBox: return ISD_ENGINE_MORNING_BOX
        case .polarChoir: return ISD_ENGINE_POLAR_CHOIR
        case .planktonKeys: return ISD_ENGINE_PLANKTON_KEYS
        case .teaHouseKoto: return ISD_ENGINE_TEA_HOUSE_KOTO
        case .zenShakuhachi: return ISD_ENGINE_ZEN_SHAKUHACHI
        case .reefMarimba: return ISD_ENGINE_REEF_MARIMBA
        case .blueDepth: return ISD_ENGINE_BLUE_DEPTH
        case .magmaBass: return ISD_ENGINE_MAGMA_BASS
        case .singleNoteGrand: return ISD_ENGINE_SINGLE_NOTE_GRAND
        case .replicantBrass: return ISD_ENGINE_REPLICANT_BRASS
        case .endlessRise: return ISD_ENGINE_ENDLESS_RISE
        }
    }

    static func fourCC(_ s: String) -> OSType {
        s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    /// A trim in decibels (a preset's, a world's ambience's) as the Sound Core's gain: 1 for a value that isn't finite.
    static func trimGain(dB: Double) -> Float {
        dB.isFinite ? Float(pow(10, dB / 20)) : 1
    }
}
