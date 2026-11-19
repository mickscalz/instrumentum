import XCTest
import AVFoundation
import AudioToolbox
@testable import InStrumAudio
@testable import InStrumCore

/// The mix (Recorder spec §3, §4; plan Task 3): the stems at their volumes and offsets, summed by `Mixdown.mix`, written
/// as `Mix.m4a` (AAC, 256 kbps, stereo) and, if asked, `Mix.wav` (24-bit).
final class MixRendererTests: XCTestCase {
    var dir: URL!
    let rate = 48_000.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MixRendererTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The audio data's size (without the file's headers), its declared bit rate and its packets, as Core Audio reads them.
    private func audioData(_ url: URL) -> (bytes: UInt64, bitRate: UInt32, packets: UInt64) {
        var id: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &id) == noErr, let file = id else { return (0, 0, 0) }
        defer { AudioFileClose(file) }
        var bytes: UInt64 = 0, packets: UInt64 = 0
        var bitRate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &size, &bytes)
        size = UInt32(MemoryLayout<UInt64>.size)
        AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate)
        return (bytes, bitRate, packets)
    }

    private func rms(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return (sum / Double(x.count)).squareRoot()
    }

    func testMixFileMatchesMixdown() throws {
        var session = RecordingSession(title: "Mix", sampleRate: rate, appVersion: "test")
        _ = session.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        _ = session.addLayer(kind: .liveInput, name: "Microphone", note: nil)
        _ = session.addLayer(kind: .playAlong, name: "Play-along", note: nil)
        let sines = [PlaybackAudio.sine(hz: 440, seconds: 2, rate: rate, amplitude: 0.5),
                     PlaybackAudio.sine(hz: 660, seconds: 1.5, rate: rate, amplitude: 0.4),
                     PlaybackAudio.sine(hz: 220, seconds: 2.5, rate: rate, amplitude: 0.6)]
        for i in 0..<3 {
            try PlaybackAudio.writeWAV(dir.appendingPathComponent(session.layers[i].fileName), left: sines[i], rate: rate)
            session.layers[i].frames = sines[i].count
        }
        session.layers[0].offsetFrames = -480
        session.layers[1].offsetFrames = -7200
        session.layers[1].volume = 0.5
        session.layers[2].volume = 1.5

        let url = try MixRenderer.render(session: session, folder: dir, alsoWAV: true)

        // What the mix must be: the stems as they read back, through Mixdown.
        var stems: [Mixdown.Stem] = []
        for layer in session.layers {
            let stem = try RecordedStem(dir.appendingPathComponent(layer.fileName))
            stems.append(Mixdown.Stem(left: stem.left, right: stem.right, gain: Float(layer.volume), offsetFrames: layer.offsetFrames))
        }
        let expected = Mixdown.mix(stems)
        let wav = try RecordedStem(dir.appendingPathComponent("Mix.wav"))
        let lengthMatches = wav.left.count == expected.left.count
        var worst: Float = 0
        if lengthMatches {
            for i in 0..<wav.left.count {
                worst = max(worst, abs(wav.left[i] - expected.left[i]))
                worst = max(worst, abs(wav.right[i] - expected.right[i]))
            }
        }

        let m4a = try AVAudioFile(forReading: url)
        let format = m4a.fileFormat.streamDescription.pointee
        let m4aSeconds = Double(m4a.length) / m4a.fileFormat.sampleRate
        let wavSeconds = Double(wav.left.count) / rate
        let decoded = AVAudioPCMBuffer(pcmFormat: m4a.processingFormat, frameCapacity: AVAudioFrameCount(m4a.length))!
        try m4a.read(into: decoded)
        let m4aLeft = Array(UnsafeBufferPointer(start: decoded.floatChannelData![0], count: Int(decoded.frameLength)))
        let levelDifference = 20 * log10(rms(m4aLeft) / rms(wav.left))
        let fileBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let audio = audioData(url)
        let kbps = Double(audio.bytes) * 8 / m4aSeconds / 1000
        let declaredKbps = Double(audio.bitRate) / 1000
        let numbers = "audio data \(audio.bytes) bytes = \(kbps) kbps; declared \(declaredKbps) kbps; file \(fileBytes) bytes; "
            + "\(audio.packets) packets; \(m4aSeconds) s; settings \(m4a.fileFormat.settings)"
        let headroom = expected.gain

        XCTAssertEqual(url.lastPathComponent, "Mix.m4a")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, dir.lastPathComponent, "in the recording's folder")
        XCTAssertTrue(lengthMatches, "\(wav.left.count) frames, not \(expected.left.count)")
        XCTAssertLessThanOrEqual(worst, 1e-4)
        XCTAssertLessThan(headroom, 1, "the sum passed −1 dBFS and was turned down by one gain")
        XCTAssertEqual(wav.bitDepth, 24)
        XCTAssertEqual(wav.channels, 2)
        XCTAssertEqual(wav.sampleRate, rate)
        XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(format.mChannelsPerFrame, 2)
        XCTAssertEqual(m4aSeconds, wavSeconds, accuracy: 0.05)
        XCTAssertEqual(levelDifference, 0, accuracy: 1, "within 1 dB")
        XCTAssertEqual(kbps, 256, accuracy: 40, "AAC at 256 kbps: " + numbers)
        XCTAssertEqual(declaredKbps, 256, accuracy: 40, "AAC at 256 kbps: " + numbers)
    }

    func testMutedLayersAreLeftOut() throws {
        var session = RecordingSession(title: "Mute", sampleRate: rate, appVersion: "test")
        _ = session.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        _ = session.addLayer(kind: .instrument, name: "Magma Bass", note: nil)
        let kept = PlaybackAudio.sine(hz: 440, seconds: 1, rate: rate, amplitude: 0.5)
        let muted = PlaybackAudio.sine(hz: 110, seconds: 2, rate: rate, amplitude: 0.5)
        try PlaybackAudio.writeWAV(dir.appendingPathComponent(session.layers[0].fileName), left: kept, rate: rate)
        try PlaybackAudio.writeWAV(dir.appendingPathComponent(session.layers[1].fileName), left: muted, rate: rate)
        session.layers[1].muted = true

        _ = try MixRenderer.render(session: session, folder: dir, alsoWAV: true)
        let wav = try RecordedStem(dir.appendingPathComponent("Mix.wav"))
        let alone = try RecordedStem(dir.appendingPathComponent(session.layers[0].fileName))
        let length = wav.left.count
        var worst: Float = 0
        if length == alone.left.count {
            for i in 0..<length { worst = max(worst, abs(wav.left[i] - alone.left[i])) }
        }
        let m4aExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("Mix.m4a").path)

        // Rendering again (after a change) replaces the mix.
        session.layers[1].muted = false
        _ = try MixRenderer.render(session: session, folder: dir, alsoWAV: false)
        let again = try RecordedStem(dir.appendingPathComponent("Mix.m4a"))
        let againSeconds = Double(again.length) / again.sampleRate
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }

        XCTAssertEqual(length, 48_000, "as long as the layer that is heard")
        XCTAssertLessThanOrEqual(worst, 1e-6, "the muted layer adds nothing")
        XCTAssertTrue(m4aExists)
        XCTAssertEqual(againSeconds, 2, accuracy: 0.05, "the unmuted layer is in the new mix")
        XCTAssertTrue(leftovers.isEmpty, "no half-written files left behind")
    }
}
