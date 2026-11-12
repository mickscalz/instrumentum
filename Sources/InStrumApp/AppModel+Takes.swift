import Foundation
import InStrumCore

/// Keep that (Small Wins spec §2): the last take, or the last ten minutes, saved as a MIDI file in
/// `~/Music/In Strum Meants/Takes` with a note of the moment beside it, from the bookmark, ⌘K or the key gesture.
extension AppModel {
    /// Saves the last take ending at `t` (system uptime): "Kept · 0:12", or "Nothing to keep yet".
    public func keepThat(at t: Double = ProcessInfo.processInfo.systemUptime) {
        keep(live.withLockUnchecked { $0.keeper.lastTake(endingAt: t) })
    }

    /// Saves the last ten minutes ending at `t`, whatever silences they hold.
    public func keepLastTenMinutes(at t: Double = ProcessInfo.processInfo.systemUptime) {
        keep(live.withLockUnchecked { $0.keeper.lastMinutes(600, endingAt: t) })
    }

    /// The set while its world shows: its name and its song's tempo go into a kept take.
    var shownSet: InStrumSet? {
        guard let set = activeSetID.flatMap({ SetLibrary.set(id: $0) }), set.worldID == themeID else { return nil }
        return set
    }

    /// The kept file's name and its track's: the set's while its world shows, else the world's (or the theme's).
    func takeTitle() -> String {
        if let set = shownSet { return set.name }
        return ThemeRegistry.all.first { $0.id == themeID }?.name ?? themeID
    }

    /// The kept file's tempo: the shown set's song's (its credit), else 120.
    func takeTempo() -> Double {
        guard let id = shownSet?.creditID, let credit = CreditLibrary.credit(id: id) else { return 120 }
        return credit.tempoBPM
    }

    /// The note beside a kept take: the set and world, the instrument and its dials, the sky the world last drew, the
    /// key the player was in and the app's version.
    func takeNote(seconds: Double) -> TakeNote {
        var named: [String: Double] = [:]
        if let values = dialReader?.currentValues() {
            for dial in dials { if let v = values[dial.address] { named[dial.name] = v } }
        }
        let instrument = TakeNote.Instrument(patchID: builtInPatch?.id, name: settings.instrument?.name ?? "None", dials: named)
        var sky: TakeNote.Sky?
        if let s = sceneReport.sky {
            let city = settings.sky.cityID.flatMap { Cities.city(id: $0) } ?? Cities.defaultCity(for: .current)
            sky = TakeNote.Sky(city: city?.name ?? "", localTime: SkyControls.clock(s.hourOfDay), weather: s.weather.rawValue,
                               sunAltitude: s.sun.altitude, moonPhase: s.moonPhase)
        }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TakeNote(setID: shownSet?.id, worldID: themeID, instrument: instrument, sky: sky, key: sceneReport.key,
                        appVersion: version ?? "dev", seconds: seconds)
    }

    /// "0:12", "4:12": a kept take's length, to the second.
    static func keptLength(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// Writes a take (synchronously: one is well under a megabyte) and says so.
    private func keep(_ take: Take?) {
        guard let take, take.events.contains(where: { if case .noteOn = $0.message { return true }; return false }) else {
            showToast("Nothing to keep yet", symbol: "bookmark")
            return
        }
        let title = takeTitle()
        let midi = StandardMIDIFile.write(take, name: title, bpm: takeTempo())
        do {
            try takeStore.save(midi: midi, note: takeNote(seconds: take.duration), title: title, at: Date())
            showToast("Kept · \(Self.keptLength(take.duration))", symbol: "bookmark.fill")
        } catch {
            showToast("Couldn't save the take", symbol: "exclamationmark.triangle")
        }
    }
}
