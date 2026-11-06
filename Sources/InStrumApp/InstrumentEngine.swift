import AVFoundation
import Foundation
import InStrumCore
import InStrumAudio

/// What the app model needs from the sound engine (lets tests use a fake).
public protocol InstrumentEngine: AnyObject {
    func start() throws
    @MainActor func loadInstrument(_ choice: InstrumentChoice) async throws
    @MainActor func currentInstrumentState() -> Data?
    func send(_ bytes: [UInt8])
    func panic()
    var audioLevel: Float { get }
    var masterVolume: Float { get set }
    /// A run-time gain on the instrument and the ambience, 0…1 (the sleep fade): never saved, and the saved volumes
    /// never see it.
    var sleepGain: Float { get set }
    var bufferFrames: UInt32 { get set }
    var soundReading: SoundReading { get }
    var loadedAudioUnit: AUAudioUnit? { get }
    func setMood(_ mood: Mood)
    /// Built-in instruments only.
    func applyPatch(_ patch: Patch)
    var builtInPatchID: String? { get }
    /// Puts the ambience generator on its own bus (after `start`).
    func startAmbience() async
    func setAmbience(_ scene: AmbienceScene)
    /// A world switch: thunder still on its way from the last world never arrives.
    func clearAmbienceThunder()
    var ambienceVolume: Float { get set }
    var ambienceEnabled: Bool { get set }
    // Output (Sound & MIDI settings)
    var isRunning: Bool { get }
    var outputDevices: [OutputDevice] { get }
    var outputSampleRate: Double { get }
    /// Plays to the output with this unique ID (nil = the Mac's default output); false if it isn't there.
    @discardableResult func selectOutputDevice(uid: String?) -> Bool
    func restartAudio()
    /// Puts the sound back if it stopped or its output disappeared; a note for the user when it acted.
    func checkHealth() -> String?
}

public extension InstrumentEngine {
    var soundReading: SoundReading { SoundReading() }
    var loadedAudioUnit: AUAudioUnit? { nil }
    func setMood(_ mood: Mood) {}
    func applyPatch(_ patch: Patch) {}
    var builtInPatchID: String? { nil }
    func startAmbience() async {}
    func setAmbience(_ scene: AmbienceScene) {}
    func clearAmbienceThunder() {}
    var isRunning: Bool { true }
    var outputDevices: [OutputDevice] { [] }
    var outputSampleRate: Double { 0 }
    @discardableResult func selectOutputDevice(uid: String?) -> Bool { false }
    func restartAudio() {}
    func checkHealth() -> String? { nil }
}

/// What the app model needs from the MIDI input (lets tests use a fake).
public protocol MIDIControlling: AnyObject {
    /// Stops listening to the inputs with these names.
    func setDisabled(_ names: Set<String>)
    func rescan()
    /// When the input with this name last sent a note or controller (system uptime).
    func lastActivity(_ name: String) -> Double?
}

extension MIDIInput: MIDIControlling {}

extension AudioEngine: InstrumentEngine {
    public func applyPatch(_ patch: Patch) { loadedBuiltIn?.apply(patch) }
    public var builtInPatchID: String? { loadedBuiltIn?.patchID }
}
