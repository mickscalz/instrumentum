import CoreAudio
import Foundation

/// The Mac's default output ↔ BlackHole (Recorder spec §5.2, Review focus 3). Playing along with the Mac's sound sets the
/// Mac's output to BlackHole (so Spotify plays into it and the app listens there) and puts it back afterwards.
///
/// The output it replaced is written to the settings (`markerKey`) before the switch, so a crash can never lose it: the
/// next launch's `restoreAfterCrashIfNeeded()` puts it back. Putting it back happens only while the Mac is still on what
/// it was switched to (a choice he made meanwhile stands), and leaves the default alone if the old output is gone.
/// Devices are named by UID. `get` and `set` are injected so tests never touch the real device; `live` uses Core Audio.
public struct MacOutputSwitch {
    /// The output to put back (the marker a crash leaves behind).
    public static let markerKey = "recorder.restoreOutputUID"
    /// The output it was switched to.
    static let switchedKey = "recorder.switchedOutputUID"

    private let get: () -> String?
    private let set: (String) -> Bool
    private let marker: UserDefaults
    /// This launch switched the output and hasn't put it back.
    private var switched = false

    /// `get`: the Mac's default output's UID; `set`: makes the output with this UID the default (false if it can't).
    public init(get: @escaping () -> String?, set: @escaping (String) -> Bool, marker: UserDefaults = .standard) {
        self.get = get
        self.set = set
        self.marker = marker
    }

    /// The Mac's real default output (`kAudioHardwarePropertyDefaultOutputDevice`).
    public static var live: MacOutputSwitch {
        MacOutputSwitch(get: { CoreAudioDevices.defaultOutput().flatMap(CoreAudioDevices.uid(of:)) },
                        set: { uid in setDefaultOutput(uid: uid) })
    }

    /// Makes `uid` the Mac's output. Returns the output it replaced (remembered in the settings first), or nil if the
    /// Mac was already on it or the switch failed (then nothing changes and nothing is remembered).
    @discardableResult
    public mutating func switchTo(_ uid: String) -> String? {
        guard let previous = get(), previous != uid else { return nil }
        let oldMarker = marker.string(forKey: Self.markerKey), oldSwitched = marker.string(forKey: Self.switchedKey)
        marker.set(previous, forKey: Self.markerKey)
        marker.set(uid, forKey: Self.switchedKey)
        guard set(uid) else {
            put(oldMarker, Self.markerKey)
            put(oldSwitched, Self.switchedKey)
            return nil
        }
        switched = true
        return previous
    }

    /// Puts the remembered output back (if the Mac is still on what it was switched to, and the old output is still
    /// there) and clears the marker.
    public mutating func restore() {
        defer {
            clear()
            switched = false
        }
        guard let previous = marker.string(forKey: Self.markerKey) else { return }
        let target = marker.string(forKey: Self.switchedKey)
        guard target == nil || get() == target else { return }
        _ = set(previous)
    }

    /// At launch: a marker means the app died with the Mac's output switched. Puts it back as `restore()` does. True if
    /// it did; the marker is cleared either way.
    public mutating func restoreAfterCrashIfNeeded() -> Bool {
        guard !switched, let previous = marker.string(forKey: Self.markerKey) else { return false }
        let target = marker.string(forKey: Self.switchedKey)
        defer { clear() }
        guard target == nil || get() == target else { return false }
        return set(previous)
    }

    // MARK: - Private

    private func clear() {
        marker.removeObject(forKey: Self.markerKey)
        marker.removeObject(forKey: Self.switchedKey)
    }

    private func put(_ value: String?, _ key: String) {
        if let value { marker.set(value, forKey: key) } else { marker.removeObject(forKey: key) }
    }

    /// Makes the output with this UID the Mac's default output. False if it isn't there or refuses.
    static func setDefaultOutput(uid: String) -> Bool {
        guard let id = CoreAudioDevices.device(uid: uid), CoreAudioDevices.isAlive(id) else { return false }
        var addr = CoreAudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
    }
}
