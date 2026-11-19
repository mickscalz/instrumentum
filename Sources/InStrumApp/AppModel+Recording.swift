import AppKit
import Foundation
import InStrumCore

/// The Record button (the first piece of the Recorder): one click records the instrument, at full quality and whatever
/// the volume slider says, to a WAV file in `~/Music/In Strum Meants/Recordings`; a second click stops and saves it.
/// It stops and saves by itself after an hour and when the app quits. Nothing is written, and no folder made, until
/// Record is pressed. A panic leaves a recording running.
extension AppModel {
    /// The longest a recording runs before it stops and saves by itself.
    nonisolated static let maxRecordingSeconds: Double = 3600
    /// How often the running time is read while recording.
    nonisolated static let recordingTickSeconds: Double = 0.5

    /// Record, or stop and save. `date` names the file.
    public func toggleRecording(at date: Date = Date()) {
        if isRecording { stopRecording() } else { startRecording(at: date) }
    }

    /// Opens the recordings folder in the Finder (making it first if need be).
    public func showRecordingsInFinder() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    /// Makes the folder, picks the first free name ("2026-11-16 21.07 — Moonlit Lake.wav", then "… 2") and starts the
    /// engine writing to it.
    func startRecording(at date: Date) {
        guard !isRecording else { return }
        let url: URL
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            url = freeRecordingURL(TakeStore.fileStem(title: takeTitle(), date: date, timeZone: .current))
            try engine.beginInstrumentRecording(to: url)
        } catch {
            showToast("Couldn't start recording", symbol: "exclamationmark.triangle")
            return
        }
        recordingURL = url
        recordingSeconds = 0
        isRecording = true
        startRecordingTicker()
        recordingQuitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        showToast("Recording", symbol: "record.circle.fill")
    }

    /// Closes the file and says how long it is; a recording that holds nothing is deleted.
    func stopRecording() {
        guard isRecording else { return }
        let frames = engine.endInstrumentRecording()
        let rate = engine.outputSampleRate
        let seconds = rate > 0 ? Double(frames) / rate : recordingSeconds
        let url = recordingURL
        recordingURL = nil
        stopRecordingTicker()
        if let observer = recordingQuitObserver { NotificationCenter.default.removeObserver(observer) }
        recordingQuitObserver = nil
        isRecording = false
        recordingSeconds = 0
        guard frames > 0 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            showToast("Nothing recorded", symbol: "record.circle")
            return
        }
        showToast("Saved · \(Self.keptLength(seconds))", symbol: "checkmark.circle.fill")
    }

    /// Each tick: the running time (published once a second, for the button), and the stop at an hour.
    func recordingTick(seconds: Double) {
        guard isRecording else { return }
        let whole = max(0, seconds.rounded(.down))
        if whole != recordingSeconds { recordingSeconds = whole }
        if seconds >= Self.maxRecordingSeconds { stopRecording() }
    }

    /// The first name in the folder that no file has: the stem, then "… 2", "… 3".
    private func freeRecordingURL(_ stem: String) -> URL {
        var n = 1
        var url = recordingsDirectory.appendingPathComponent(stem + ".wav", isDirectory: false)
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = recordingsDirectory.appendingPathComponent("\(stem) \(n).wav", isDirectory: false)
        }
        return url
    }

    private func startRecordingTicker() {
        stopRecordingTicker()
        // On the main run loop in its common modes, so it keeps time while a menu is open or a slider is dragged.
        let ticker = Timer(timeInterval: Self.recordingTickSeconds, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.recordingTick(seconds: self.engine.recordingSeconds)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        recordingTicker = ticker
    }

    private func stopRecordingTicker() {
        recordingTicker?.invalidate()
        recordingTicker = nil
    }
}
