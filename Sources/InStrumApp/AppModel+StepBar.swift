import AVFoundation
import Foundation
import InStrumAudio
import InStrumCore

/// What the row under the top bar shows and does: the names of the set, the world and the instrument, and transpose.
extension AppModel {
    public var currentSetName: String {
        activeSetID.flatMap { SetLibrary.set(id: $0) }?.name ?? "None chosen"
    }

    public var currentWorldName: String {
        ThemeRegistry.all.first { $0.id == themeID }?.name ?? themeID
    }

    public var currentInstrumentName: String {
        settings.instrument?.name ?? "None chosen"
    }

    static let transposeRange = -12...12

    /// The built-in instrument's transpose dial (a plugin has none here).
    private var transposeParameter: AUParameter? {
        guard isBuiltIn else { return nil }
        return engine.loadedAudioUnit?.parameterTree?.allParameters.first { $0.identifier == "transpose" }
    }

    /// Semitones up or down; nil when the instrument is a plugin (or none is loaded).
    public var transpose: Int? {
        transposeParameter.map { Int(Double($0.value).rounded()) }
    }

    /// Sets the transpose, kept within an octave either way. It is saved with the instrument, as when set in its window.
    public func setTranspose(_ semitones: Int) {
        guard let parameter = transposeParameter else { return }
        let clamped = max(Self.transposeRange.lowerBound, min(Self.transposeRange.upperBound, semitones))
        objectWillChange.send()
        parameter.value = AUValue(clamped)
        scheduleSave()
    }

    public func stepTranspose(by step: Int) {
        guard let now = transpose else { return }
        setTranspose(now + step)
    }
}
