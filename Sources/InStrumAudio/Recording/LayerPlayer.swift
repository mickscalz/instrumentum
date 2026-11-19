import AVFoundation
import Foundation
import InStrumCore

/// Reading audio files for playback and for the mix (Recorder spec §5.1, §8): anything `AVAudioFile` opens (MP3,
/// M4A/AAC, WAV, AIFF, FLAC, ALAC), as left and right at a given rate. Off the main thread and off the audio thread.
enum AudioFileReader {
    static let chunk: AVAudioFrameCount = 16_384

    /// Opens `url` for reading. A missing, protected or unreadable file is `AudioEngineError.loadFailed(<its name>)`.
    static func open(_ url: URL) throws -> AVAudioFile {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioEngineError.loadFailed(url.lastPathComponent)
        }
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, file.length >= 0 else {
            throw AudioEngineError.loadFailed(url.lastPathComponent)
        }
        return file
    }

    /// Hands `sink` the whole of `file`, from its start, as left and right at `rate` (a mono file on both sides; past
    /// two channels, the first two), a chunk at a time. Throws what reading or converting throws.
    static func stream(_ file: AVAudioFile, rate: Double,
                       _ sink: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws {
        let source = file.processingFormat
        let channels = Int(source.channelCount)
        guard channels > 0, source.sampleRate > 0, rate > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else {
            throw AudioEngineError.loadFailed(file.url.lastPathComponent)
        }
        let length = file.length
        let step = Int64(chunk)
        file.framePosition = 0
        if source.sampleRate == rate {
            while file.framePosition < length {
                let want = AVAudioFrameCount(min(step, length - file.framePosition))
                try file.read(into: input, frameCount: want)
                let n = Int(input.frameLength)
                guard n > 0, let d = input.floatChannelData else { break }
                try sink(d[0], d[channels > 1 ? 1 : 0], n)
            }
            return
        }
        var description = source.streamDescription.pointee
        description.mSampleRate = rate
        let capacity = AVAudioFrameCount(Double(chunk) * rate / source.sampleRate) + 4096
        guard let target = AVAudioFormat(streamDescription: &description, channelLayout: source.channelLayout),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioEngineError.loadFailed(file.url.lastPathComponent)
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var finished = false
        var readError: Error?
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if finished || file.framePosition >= length {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    let want = AVAudioFrameCount(min(step, length - file.framePosition))
                    try file.read(into: input, frameCount: want)
                } catch {
                    readError = error
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if status == .error {
                if let conversionError { throw conversionError }
                throw AudioEngineError.loadFailed(file.url.lastPathComponent)
            }
            let n = Int(output.frameLength)
            if n > 0, let d = output.floatChannelData { try sink(d[0], d[channels > 1 ? 1 : 0], n) }
            if status == .endOfStream || (n == 0 && finished) { break }
        }
    }

    /// The whole file as left and right at `rate`.
    static func readStereo(_ url: URL, rate: Double) throws -> (left: [Float], right: [Float]) {
        let file = try open(url)
        var left: [Float] = [], right: [Float] = []
        let expected = Int(Double(file.length) * rate / file.processingFormat.sampleRate) + 16
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)
        do {
            try stream(file, rate: rate) { l, r, n in
                left.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: r, count: n))
            }
        } catch {
            throw AudioEngineError.loadFailed(url.lastPathComponent)
        }
        return (left, right)
    }

    /// Settings for a stereo float file (a temporary file at a given rate).
    static func floatSettings(_ rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

/// A file ready for a player: stereo at the engine's rate (Recorder plan Task 3: "resamples on load if the file's rate
/// differs"). A file already at that rate in stereo plays as it is; any other is converted once, on load, into a
/// temporary file that goes when this does.
final class PlaybackFile: @unchecked Sendable {
    let file: AVAudioFile
    let frames: Int
    let sampleRate: Double
    private let temporary: URL?

    private init(file: AVAudioFile, sampleRate: Double, temporary: URL?) {
        self.file = file
        self.frames = Int(max(0, file.length))
        self.sampleRate = sampleRate
        self.temporary = temporary
    }

    deinit {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    /// Opens (and if need be converts) `url` for playing at `rate`. Off the main thread: a conversion reads the whole
    /// file. A missing, protected or unreadable file is `AudioEngineError.loadFailed(<its name>)`.
    static func prepare(_ url: URL, sampleRate rate: Double) throws -> PlaybackFile {
        let name = url.lastPathComponent
        let source = try AudioFileReader.open(url)
        let format = source.processingFormat
        if format.sampleRate == rate && format.channelCount == 2 {
            guard readable(source) else { throw AudioEngineError.loadFailed(name) }
            return PlaybackFile(file: source, sampleRate: rate, temporary: nil)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("In Strum Meants playback", isDirectory: true)
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".caf", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try convert(source, to: temporary, rate: rate)
            let converted = try AVAudioFile(forReading: temporary)
            return PlaybackFile(file: converted, sampleRate: rate, temporary: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AudioEngineError.loadFailed(name)
        }
    }

    /// The first few thousand frames read (a protected file opens but won't read).
    private static func readable(_ file: AVAudioFile) -> Bool {
        guard file.length > 0 else { return true }
        guard let probe = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return false }
        defer { file.framePosition = 0 }
        do {
            try file.read(into: probe, frameCount: AVAudioFrameCount(min(Int64(4096), file.length)))
            return true
        } catch {
            return false
        }
    }

    private static func convert(_ source: AVAudioFile, to url: URL, rate: Double) throws {
        let out = try AVAudioFile(forWriting: url, settings: AudioFileReader.floatSettings(rate),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let capacity = Int(AudioFileReader.chunk)
        guard out.processingFormat.channelCount == 2,
              let scratch = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(capacity)),
              let channels = scratch.floatChannelData else {
            throw AudioEngineError.loadFailed(url.lastPathComponent)
        }
        try AudioFileReader.stream(source, rate: rate) { l, r, n in
            var done = 0
            while done < n {
                let count = min(n - done, capacity)
                channels[0].update(from: l + done, count: count)
                channels[1].update(from: r + done, count: count)
                scratch.frameLength = AVAudioFrameCount(count)
                try out.write(from: scratch)
                done += count
            }
        }
    }
}

/// Plays files on a bus (Recorder spec §4, §5.1, §7): one `AVAudioPlayerNode` per file, all started at one sample time,
/// each with its gain (0…2) and its offset (where its first frame sits on the recording's clock; negative is earlier).
/// A file at another rate is resampled on load. The players are attached on the first load and stay attached (a rebuild
/// of the output reconnects the bus, not them) until the player goes. Main thread, except `load`'s reading.
public final class LayerPlayer {
    let engine: AVAudioEngine
    let bus: AVAudioMixerNode
    /// The rate the files are prepared at and the players are connected at.
    let sampleRate: Double
    let format: AVAudioFormat
    private(set) var nodes: [AVAudioPlayerNode] = []
    /// The bus input each player is connected to.
    private(set) var inputBuses: [AVAudioNodeBus] = []
    private var files: [PlaybackFile] = []
    private var offsets: [Int] = []
    private var gains: [Float] = []
    /// Each file's part of the loop, as a buffer the loop's length, and the loop it was read for.
    private var loopBuffers: [AVAudioPCMBuffer?] = []
    private var loopBuffersFor: Range<Int>?
    private var playing = false
    private var startSample: Int64 = 0
    private var startFrame = 0
    private var loop: Range<Int>?
    private var stoppedFrame = 0

    /// Plays on `bus`, at the rate the bus plays into the main mixer.
    public convenience init(engine: AVAudioEngine, bus: AVAudioMixerNode) {
        let rate = bus.outputFormat(forBus: 0).sampleRate
        self.init(engine: engine, bus: bus, sampleRate: rate > 0 ? rate : 44_100)
    }

    init(engine: AVAudioEngine, bus: AVAudioMixerNode, sampleRate: Double) {
        self.engine = engine
        self.bus = bus
        self.sampleRate = sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    deinit {
        for node in nodes {
            node.stop()
            engine.detach(node)
        }
    }

    /// Loads these files in place of any before (stopping first): each resampled to the engine's rate if it differs.
    /// Nothing changes when one of them can't be read (`AudioEngineError.loadFailed`).
    public func load(_ items: [(url: URL, gain: Float, offsetFrames: Int)]) throws {
        let rate = sampleRate
        var prepared: [(file: PlaybackFile, gain: Float, offsetFrames: Int)] = []
        for item in items {
            let file = try PlaybackFile.prepare(item.url, sampleRate: rate)
            prepared.append((file: file, gain: item.gain, offsetFrames: item.offsetFrames))
        }
        install(prepared)
    }

    /// Puts prepared files on the players: a player per file, reusing those there are, each on a bus input of its own.
    func install(_ items: [(file: PlaybackFile, gain: Float, offsetFrames: Int)]) {
        stop()
        while nodes.count > items.count {
            let node = nodes.removeLast()
            inputBuses.removeLast()
            engine.detach(node)
        }
        var taken = Set(inputBuses)
        while nodes.count < items.count {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            var input = bus.nextAvailableInputBus
            while taken.contains(input) { input += 1 }
            taken.insert(input)
            engine.connect(node, to: bus, fromBus: 0, toBus: input, format: format)
            nodes.append(node)
            inputBuses.append(input)
        }
        files = items.map { $0.file }
        offsets = items.map { $0.offsetFrames }
        gains = items.map { Self.held($0.gain) }
        for i in nodes.indices { nodes[i].volume = gains[i] }
        loopBuffers = []
        loopBuffersFor = nil
        stoppedFrame = 0
    }

    /// Starts every file at sample time `t` of the engine's clock, from `fromSeconds` into the recording.
    public func start(atSampleTime t: Int64, fromSeconds: Double = 0) {
        let from = fromSeconds.isFinite ? max(0, Int((fromSeconds * sampleRate).rounded())) : 0
        cue(from: from, loop: nil)
        play(at: t)
    }

    public func stop() {
        stoppedFrame = currentFrame
        for node in nodes { node.stop() }
        playing = false
    }

    public func setGain(_ g: Float, index: Int) {
        guard nodes.indices.contains(index) else { return }
        gains[index] = Self.held(g)
        nodes[index].volume = gains[index]
    }

    public var isPlaying: Bool { playing && (loop != nil || currentFrame < durationFrames) }
    public var positionSeconds: Double { Double(currentFrame) / sampleRate }
    public var durationSeconds: Double { Double(durationFrames) / sampleRate }

    /// Where the last file ends, in frames on the recording's clock.
    var durationFrames: Int {
        var end = 0
        for i in files.indices { end = max(end, offsets[i] + files[i].frames) }
        return end
    }

    /// The engine's sample clock now (the clock players are started on).
    var now: Int64 {
        if engine.isInManualRenderingMode { return engine.manualRenderingSampleTime }
        if let t = bus.lastRenderTime, t.isSampleTimeValid { return t.sampleTime }
        return startSample
    }

    /// The frame on the recording's clock that is playing.
    var currentFrame: Int {
        guard playing else { return stoppedFrame }
        var frame = startFrame + Int(max(0, now - startSample))
        if let loop, startFrame < loop.upperBound, frame >= loop.upperBound {
            frame = loop.lowerBound + (frame - loop.upperBound) % loop.count
        }
        return min(frame, max(durationFrames, loop?.upperBound ?? 0))
    }

    // MARK: - Scheduling (the transport's too)

    /// Stops, then schedules every file as heard from frame `from` of the recording's clock on, at player times counted
    /// from the start plus `delay`. With `loop` (if `from` is before its end): up to the loop's end as a file segment,
    /// then the loop's part of the file as one buffer that loops on the sample until the player stops (no rescheduling).
    /// Then reads ahead.
    func cue(from: Int, loop requested: Range<Int>?, delay: Int = 0) {
        stop()
        var active: Range<Int>?
        if let requested, requested.count > 0, from < requested.upperBound { active = requested }
        if let active, loopBuffersFor != active || loopBuffers.count != files.count {
            var buffers: [AVAudioPCMBuffer?] = []
            for i in files.indices { buffers.append(Self.loopBuffer(files[i], offset: offsets[i], loop: active, format: format)) }
            loopBuffers = buffers
            loopBuffersFor = active
        }
        for i in nodes.indices {
            let node = nodes[i]
            let headEnd = active?.upperBound ?? Int.max
            Self.schedule(node, files[i], offset: offsets[i], span: from..<headEnd, at: delay, rate: sampleRate)
            if let active, let buffer = loopBuffers[i] {
                let when = AVAudioTime(sampleTime: AVAudioFramePosition(delay + active.upperBound - from), atRate: sampleRate)
                node.scheduleBuffer(buffer, at: when, options: .loops, completionHandler: nil)
            }
        }
        if engine.isRunning {
            for node in nodes { node.prepare(withFrameCount: 4096) }
        }
        loop = active
        startFrame = from
        stoppedFrame = from
    }

    /// Plays what `cue` scheduled, from node sample time `t` (nil: at once). Nothing plays while the engine can't run.
    func play(at t: Int64?) {
        guard !nodes.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        let when = t.map { AVAudioTime(sampleTime: $0, atRate: sampleRate) }
        startSample = t ?? now
        for node in nodes { node.play(at: when) }
        playing = true
    }

    /// Schedules the part of `file` heard while frames `span` of the recording's clock play, the first of them at player
    /// time `at`. False when none of the file falls in the span.
    @discardableResult
    static func schedule(_ node: AVAudioPlayerNode, _ file: PlaybackFile, offset: Int, span: Range<Int>, at time: Int,
                         rate: Double) -> Bool {
        let first = max(span.lowerBound, offset)
        let end = min(span.upperBound, offset + file.frames)
        guard end > first else { return false }
        let when = AVAudioTime(sampleTime: AVAudioFramePosition(time + (first - span.lowerBound)), atRate: rate)
        node.scheduleSegment(file.file, startingFrame: AVAudioFramePosition(first - offset), frameCount: AVAudioFrameCount(end - first),
                             at: when, completionHandler: nil)
        return true
    }

    /// The part of `file` that falls in `loop` (frames on the recording's clock), in a buffer the loop's length with
    /// silence where the file has nothing; nil when none of it falls there or it can't be read. Read through a handle of
    /// its own, so a player reading the same file is never disturbed.
    static func loopBuffer(_ file: PlaybackFile, offset: Int, loop: Range<Int>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let first = max(loop.lowerBound, offset)
        let end = min(loop.upperBound, offset + file.frames)
        guard end > first,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(loop.count)),
              let channels = buffer.floatChannelData,
              let reader = try? AVAudioFile(forReading: file.file.url),
              reader.processingFormat.channelCount == 2,
              let part = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(end - first)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(loop.count)
        channels[0].update(repeating: 0, count: loop.count)
        channels[1].update(repeating: 0, count: loop.count)
        reader.framePosition = AVAudioFramePosition(first - offset)
        do {
            try reader.read(into: part, frameCount: AVAudioFrameCount(end - first))
        } catch {
            return nil
        }
        guard let source = part.floatChannelData else { return nil }
        let count = min(Int(part.frameLength), end - first)
        let at = first - loop.lowerBound
        (channels[0] + at).update(from: source[0], count: count)
        (channels[1] + at).update(from: source[1], count: count)
        return buffer
    }

    private static func held(_ g: Float) -> Float { g.isFinite ? min(max(g, 0), 2) : 0 }
}
