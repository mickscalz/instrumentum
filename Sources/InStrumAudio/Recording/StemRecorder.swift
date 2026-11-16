import AVFoundation
import Foundation
import InStrumCore
import os

/// Writes the Recorder's stems (Recorder spec §3, §7). A pass opens one WAV per stem (linear PCM, 24-bit, stereo, at the
/// engine's rate). `feed` runs on the tap's thread: it copies the buffer into that stem's ring, made when the pass
/// begins, and touches no file, allocates nothing and holds a lock only to read or publish the ring's counters. One
/// writer thread (QoS utility) drains the rings into the files every 20 ms. `end()`, or letting the recorder go,
/// writes what is left and closes every file.
public final class StemRecorder: @unchecked Sendable {
    public enum RecorderError: Error, Equatable {
        case alreadyRecording
    }

    public let sampleRate: Double
    private let capacityFrames: Int
    private struct State {
        var pass: StemPass?
        /// The current or last pass: its clock, meters and overrun count stay readable after it ends, and it is let go
        /// here on the main thread, never by a tap that still holds it.
        var last: StemPass?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// `capacitySeconds`: how much each stem's ring holds before the writer must have drained it.
    public init(sampleRate: Double, capacitySeconds: Double = 2) {
        let rate = sampleRate > 0 ? sampleRate : 44_100
        self.sampleRate = rate
        capacityFrames = max(4096, Int((rate * max(0.1, capacitySeconds)).rounded()))
    }

    deinit { end() }

    /// Opens the stems' files and starts the writer. Frame 0 of every stem is sample time `start`. One file per kind:
    /// a second entry of the same kind is ignored.
    public func begin(_ stems: [(kind: StemKind, url: URL)], atSampleTime start: Int64) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let pass = try StemPass(stems: stems, start: start, sampleRate: sampleRate, capacityFrames: capacityFrames)
        state.withLockUnchecked { s in
            s.pass = pass
            s.last = pass
        }
    }

    /// Tap thread. Frames before `start` are dropped; a gap in sample time is filled with silence. Never allocates.
    public func feed(_ kind: StemKind, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleTime: Int64) {
        guard frames > 0, let pass = state.withLockUnchecked({ $0.pass }), let ring = pass.rings[Self.slot(kind)] else { return }
        var skip = 0
        if sampleTime < pass.start {
            let early = pass.start - sampleTime
            guard early < Int64(frames) else { return }
            skip = Int(early)
        }
        ring.push(left: left + skip, right: right + skip, frames: frames - skip, sampleTime: sampleTime + Int64(skip))
    }

    /// Frames written per stem. Every file is closed and readable when this returns. Empty when no pass is running.
    @discardableResult
    public func end() -> [StemKind: Int] {
        let pass = state.withLockUnchecked { s -> StemPass? in
            let p = s.pass
            s.pass = nil
            return p
        }
        return pass?.finish() ?? [:]
    }

    public var isRecording: Bool { state.withLockUnchecked { $0.pass != nil } }

    /// How long the current (or last) pass has run, by the sample times fed to it.
    public var seconds: Double {
        guard let pass = state.withLockUnchecked({ $0.last }) else { return 0 }
        return Double(pass.framesFed) / sampleRate
    }

    /// Buffers dropped because a ring was full, in the current (or last) pass.
    public var overruns: Int { state.withLockUnchecked { $0.last }?.overruns ?? 0 }

    /// The loudest sample fed to this stem since the last reading, for meters.
    public func peak(_ kind: StemKind) -> Float {
        state.withLockUnchecked { $0.last }?.rings[Self.slot(kind)]?.takePeak() ?? 0
    }

    static func slot(_ kind: StemKind) -> Int {
        switch kind {
        case .instrument: return 0
        case .liveInput: return 1
        case .playAlong: return 2
        case .ambience: return 3
        }
    }
}

/// One pass: the rings the taps fill, the files the writer fills, and the writer thread.
final class StemPass: @unchecked Sendable {
    let start: Int64
    /// Indexed by `StemRecorder.slot`; nil for a kind this pass doesn't record.
    let rings: [StemRing?]
    /// Used by the writer thread only, and by `finish` once that thread has stopped.
    private let writers: [StemWriter?]
    private let stopping = OSAllocatedUnfairLock(uncheckedState: false)
    private let wake = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)

    init(stems: [(kind: StemKind, url: URL)], start: Int64, sampleRate: Double, capacityFrames: Int) throws {
        var rings = [StemRing?](repeating: nil, count: 4)
        var writers = [StemWriter?](repeating: nil, count: 4)
        var opened: [URL] = []
        do {
            for stem in stems {
                let slot = StemRecorder.slot(stem.kind)
                guard writers[slot] == nil else { continue }
                writers[slot] = try StemWriter(kind: stem.kind, url: stem.url, sampleRate: sampleRate, start: start)
                opened.append(stem.url)
                rings[slot] = StemRing(capacityFrames: capacityFrames)
            }
        } catch {
            writers.removeAll()   // closes the files opened so far
            for url in opened { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        self.start = start
        self.rings = rings
        self.writers = writers
        // The thread holds the pass, never the recorder, so a recorder that is let go still ends its pass.
        let thread = Thread { [self] in
            while !stopping.withLockUnchecked({ $0 }) {
                autoreleasepool { drain() }
                _ = wake.wait(timeout: .now() + .milliseconds(20))
            }
            stopped.signal()
        }
        thread.name = "In Strum Meants stem writer"
        thread.qualityOfService = .utility
        thread.start()
    }

    var framesFed: Int64 {
        var most: Int64 = 0
        for ring in rings { if let end = ring?.end, end > start { most = max(most, end - start) } }
        return most
    }

    var overruns: Int {
        var sum = 0
        for ring in rings { sum += ring?.overruns ?? 0 }
        return sum
    }

    /// Stops the writer, writes what the rings still hold and closes the files.
    func finish() -> [StemKind: Int] {
        stopping.withLockUnchecked { $0 = true }
        wake.signal()
        stopped.wait()
        var frames: [StemKind: Int] = [:]
        autoreleasepool {
            drain()
            for writer in writers { if let w = writer { frames[w.kind] = w.close() } }
        }
        return frames
    }

    private func drain() {
        for slot in 0..<rings.count {
            if let ring = rings[slot], let writer = writers[slot] { ring.drain(into: writer) }
        }
    }
}

/// A stem's single-producer, single-consumer ring: the samples (left and right) and, for each buffer pushed, its sample
/// time and length. Memory is allocated and touched when the pass begins; the lock guards only the counters.
final class StemRing: @unchecked Sendable {
    struct Segment {
        var sampleTime: Int64
        var frames: Int
    }
    private struct Counters {
        var framesWritten = 0
        var framesRead = 0
        var segmentsWritten = 0
        var segmentsRead = 0
        var overruns = 0
        var peak: Float = 0
        var end = Int64.min
    }
    let capacity: Int
    let segmentCapacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let segments: UnsafeMutablePointer<Segment>
    private let counters = OSAllocatedUnfairLock(uncheckedState: Counters())

    init(capacityFrames: Int) {
        capacity = capacityFrames
        segmentCapacity = capacityFrames / 32 + 16
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        segments = .allocate(capacity: segmentCapacity)
        segments.initialize(repeating: Segment(sampleTime: 0, frames: 0), count: segmentCapacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        segments.deallocate()
    }

    /// Producer (the tap). A buffer that doesn't fit is dropped whole and counted; the writer fills its time with
    /// silence, so the stem stays in time.
    func push(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames n: Int, sampleTime t: Int64) {
        var loudest: Float = 0
        for i in 0..<n { loudest = max(loudest, max(abs(l[i]), abs(r[i]))) }
        let (written, read, segmentsWritten, segmentsRead) = counters.withLockUnchecked { c in
            (c.framesWritten, c.framesRead, c.segmentsWritten, c.segmentsRead)
        }
        let fits = n <= capacity - (written - read) && segmentsWritten - segmentsRead < segmentCapacity
        if fits {
            let at = written % capacity, first = min(n, capacity - at)
            (left + at).update(from: l, count: first)
            (right + at).update(from: r, count: first)
            if first < n {
                left.update(from: l + first, count: n - first)
                right.update(from: r + first, count: n - first)
            }
            segments[segmentsWritten % segmentCapacity] = Segment(sampleTime: t, frames: n)
        }
        let end = t + Int64(n)
        counters.withLockUnchecked { c in
            if fits {
                c.framesWritten = written + n
                c.segmentsWritten = segmentsWritten + 1
            } else {
                c.overruns += 1
            }
            c.peak = max(c.peak, loudest)
            c.end = max(c.end, end)
        }
    }

    /// Consumer (the writer thread): hands every waiting buffer to `writer`, freeing its room as it goes.
    func drain(into writer: StemWriter) {
        let (segmentsWritten, segmentsRead, framesRead) = counters.withLockUnchecked { c in
            (c.segmentsWritten, c.segmentsRead, c.framesRead)
        }
        var s = segmentsRead, position = framesRead
        while s < segmentsWritten {
            let segment = segments[s % segmentCapacity]
            writer.take(segment, from: self, at: position)
            position += segment.frames
            s += 1
            let (doneSegments, doneFrames) = (s, position)
            counters.withLockUnchecked { c in
                c.segmentsRead = doneSegments
                c.framesRead = doneFrames
            }
        }
    }

    /// Copies `count` frames from ring position `position` (consumer side).
    func copy(from position: Int, count: Int, left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>) {
        let at = position % capacity, first = min(count, capacity - at)
        l.update(from: left + at, count: first)
        r.update(from: right + at, count: first)
        if first < count {
            (l + first).update(from: left, count: count - first)
            (r + first).update(from: right, count: count - first)
        }
    }

    func takePeak() -> Float {
        counters.withLockUnchecked { c -> Float in
            let p = c.peak
            c.peak = 0
            return p
        }
    }

    var overruns: Int { counters.withLockUnchecked { $0.overruns } }
    /// The sample time just after the last buffer fed (`Int64.min` before the first).
    var end: Int64 { counters.withLockUnchecked { $0.end } }
}

/// One stem's file, on the writer thread. Frame `i` of the file is sample time `start + i`: a gap is written as
/// silence, frames already written over are dropped, and a jump of more than a minute (a clock that restarted) is
/// joined on without filling it.
final class StemWriter {
    static let chunk: AVAudioFrameCount = 8192
    let kind: StemKind
    private var file: AVAudioFile?
    private let scratch: AVAudioPCMBuffer
    private let maxGap: Int64
    private var next: Int64
    private(set) var written = 0
    /// A write failed (the disk is full): the file keeps what it has and takes nothing more.
    private(set) var failed = false

    init(kind: StemKind, url: URL, sampleRate: Double, start: Int64) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunk),
              scratch.floatChannelData != nil, file.processingFormat.channelCount == 2 else {
            throw AudioEngineError.loadFailed(url.lastPathComponent)
        }
        self.kind = kind
        self.file = file
        self.scratch = scratch
        maxGap = Int64(sampleRate * 60)
        next = start
    }

    func take(_ segment: StemRing.Segment, from ring: StemRing, at position: Int) {
        var t = segment.sampleTime, n = segment.frames, p = position
        if t > next {
            if t - next <= maxGap { writeSilence(Int(t - next)) }
            next = t
        }
        if t < next {
            let overlap = Int(min(Int64(n), next - t))
            t += Int64(overlap)
            n -= overlap
            p += overlap
        }
        guard n > 0 else { return }
        var done = 0
        while done < n {
            let c = min(n - done, Int(Self.chunk))
            ring.copy(from: p + done, count: c, left: scratch.floatChannelData![0], right: scratch.floatChannelData![1])
            write(c)
            done += c
        }
        next = t + Int64(n)
    }

    private func writeSilence(_ count: Int) {
        let channels = scratch.floatChannelData!
        channels[0].update(repeating: 0, count: Int(Self.chunk))
        channels[1].update(repeating: 0, count: Int(Self.chunk))
        var done = 0
        while done < count {
            let c = min(count - done, Int(Self.chunk))
            write(c)
            done += c
        }
    }

    /// Writes the first `count` frames of the scratch buffer.
    private func write(_ count: Int) {
        guard let file, !failed else { return }
        scratch.frameLength = AVAudioFrameCount(count)
        do {
            try file.write(from: scratch)
            written += count
        } catch {
            failed = true
        }
    }

    /// Closes the file (its header is written as it goes) and returns the frames in it.
    func close() -> Int {
        file = nil
        return written
    }
}
