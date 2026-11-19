import AVFoundation
import Foundation
import InStrumCore

/// The mix of a recording (Recorder spec §3, §4, §8): every layer's stem at its volume (left out when muted) and its
/// offset, summed by `Mixdown.mix` with its one-gain headroom rule, written as `Mix.m4a` (AAC, 256 kbps, stereo) and,
/// if asked, `Mix.wav` (24-bit). At the session's rate (its first layer's; a stem at another rate is resampled). Each
/// file is written beside the stems under a hidden name and then put in place, so an old mix is replaced whole.
/// Synchronous: call it off the main thread and off the audio thread.
public enum MixRenderer {
    public static let fileName = "Mix.m4a"
    public static let wavFileName = "Mix.wav"
    public static let bitRate = 256_000

    public enum Failure: Error, Equatable {
        case unwritable(String)
    }

    /// Renders the mix into `folder` (where the stems are) and returns `Mix.m4a`'s URL. A stem that is missing is left
    /// out; one that can't be read is `AudioEngineError.loadFailed(<its name>)`.
    @discardableResult
    public static func render(session: RecordingSession, folder: URL, alsoWAV: Bool) throws -> URL {
        let rate = mixRate(session, folder: folder)
        var stems: [Mixdown.Stem] = []
        for layer in session.layers {
            let gain: Float = layer.muted || !layer.volume.isFinite ? 0 : Float(min(max(layer.volume, 0), 2))
            guard gain > 0 else { continue }
            let url = folder.appendingPathComponent(layer.fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let samples = try AudioFileReader.readStereo(url, rate: rate)
            stems.append(Mixdown.Stem(left: samples.left, right: samples.right, gain: gain, offsetFrames: layer.offsetFrames))
        }
        let mix = Mixdown.mix(stems)
        stems.removeAll()
        let m4a = folder.appendingPathComponent(fileName, isDirectory: false)
        try replace(m4a) { temporary in try writeAAC(mix.left, mix.right, rate: rate, to: temporary) }
        if alsoWAV {
            let wav = folder.appendingPathComponent(wavFileName, isDirectory: false)
            try replace(wav) { temporary in try writeFrames(mix.left, mix.right, settings: wavSettings(rate), to: temporary) }
        }
        return m4a
    }

    /// The session's rate; failing that, the first stem's; failing that, 48 kHz.
    private static func mixRate(_ session: RecordingSession, folder: URL) -> Double {
        if session.sampleRate > 0 && session.sampleRate.isFinite { return session.sampleRate }
        for layer in session.layers {
            let url = folder.appendingPathComponent(layer.fileName, isDirectory: false)
            if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 { return file.fileFormat.sampleRate }
        }
        return 48_000
    }

    /// Writes through a hidden file beside `url` (same extension, so the same file type), then puts it in place.
    private static func replace(_ url: URL, _ write: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)", isDirectory: false)
        do {
            try write(temporary)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: temporary, to: url)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private static func wavSettings(_ rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static func aacSettings(_ rate: Double, bitRate: Int?) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
        ]
        if let bitRate {
            settings[AVEncoderBitRateKey] = bitRate
            settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        }
        return settings
    }

    /// AAC at 256 kbps (the encoder's nearest if a rate can't carry it). AAC stops at 48 kHz: a mix at a higher rate goes
    /// through a temporary float file and is resampled to 48 kHz on the way.
    private static func writeAAC(_ left: [Float], _ right: [Float], rate: Double, to url: URL) throws {
        let aacRate = rate > 48_000 ? 48_000 : rate
        let file = try openAAC(url, rate: aacRate)
        if aacRate == rate {
            try appendFrames(left, right, to: file)
            return
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeFrames(left, right, settings: AudioFileReader.floatSettings(rate), to: temporary)
        let source = try AudioFileReader.open(temporary)
        let capacity = Int(AudioFileReader.chunk)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(capacity)),
              let channels = buffer.floatChannelData, file.processingFormat.channelCount == 2 else {
            throw Failure.unwritable(url.lastPathComponent)
        }
        try AudioFileReader.stream(source, rate: aacRate) { l, r, n in
            var done = 0
            while done < n {
                let count = min(n - done, capacity)
                channels[0].update(from: l + done, count: count)
                channels[1].update(from: r + done, count: count)
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                done += count
            }
        }
    }

    private static func openAAC(_ url: URL, rate: Double) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forWriting: url, settings: aacSettings(rate, bitRate: bitRate),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return try AVAudioFile(forWriting: url, settings: aacSettings(rate, bitRate: nil),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    private static func writeFrames(_ left: [Float], _ right: [Float], settings: [String: Any], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try appendFrames(left, right, to: file)
    }

    /// Writes both sides into `file` a chunk at a time (the file closes when the caller lets it go).
    private static func appendFrames(_ left: [Float], _ right: [Float], to file: AVAudioFile) throws {
        let capacity = Int(AudioFileReader.chunk)
        guard file.processingFormat.channelCount == 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(capacity)),
              let channels = buffer.floatChannelData else {
            throw Failure.unwritable(file.url.lastPathComponent)
        }
        let total = min(left.count, right.count)
        guard total > 0 else { return }
        try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                guard let lp = l.baseAddress, let rp = r.baseAddress else { return }
                var done = 0
                while done < total {
                    let count = min(total - done, capacity)
                    channels[0].update(from: lp + done, count: count)
                    channels[1].update(from: rp + done, count: count)
                    buffer.frameLength = AVAudioFrameCount(count)
                    try file.write(from: buffer)
                    done += count
                }
            }
        }
    }
}
