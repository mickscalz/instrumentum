import Darwin
import Foundation

/// The bridge from an input on its own clock to the engine (Recorder spec §5.2, §6). The input's I/O thread writes what
/// it captures; the engine's render thread reads, resampling by a ratio that converts the input's rate to the engine's
/// and, within ±0.5%, steers the ring's level toward `targetFrames` (10 ms). Two devices on separate clocks drift
/// apart by a few hundred parts per million at most, so the correction stays far too small to hear, and the ring never
/// runs dry or overflows however long it plays.
///
/// **One writer, one reader, no locks.** Each side owns its own state and publishes one word to the other:
/// - the writer copies a block into the ring, writes a record of it (frames written in all, the block's length, the
///   time), then publishes the record's sequence number;
/// - the reader reads the newest record, interpolates, then publishes the oldest frame it may still need.
/// A full memory barrier sits between each side's data and the word it publishes, and between reading the other side's
/// word and the data it covers, so neither side ever sees the other's word before the data behind it. Words are
/// machine-word sized and aligned, so each is read or written whole. Records are kept in a small ring of their own and
/// never rewritten while the reader can still be reading them (it reads the newest of 64, and checks).
///
/// **The level** is measured on a steady line through the blocks' arrival times: the frames written before the newest
/// block, plus as much of that block as its time since arrival covers. Measured that way the level doesn't jump as
/// blocks arrive, so a 512-frame input and a 512-frame output whose callbacks slide past each other hold a steady level
/// and a steady ratio. The ring itself always holds at least that much.
///
/// The writer (an input device's I/O thread) and the reader (the engine's render thread) allocate nothing, take no
/// lock and make no Objective-C call. Every getter here can be read from any thread.
public final class CaptureRing: @unchecked Sendable {
    /// Frames the ring holds (a power of two, at least what was asked for).
    public let capacityFrames: Int
    /// The level the reader steers toward, in input frames.
    public let targetFrames: Int
    /// The input's rate and the engine's, in Hz. Their ratio is the resampling ratio before any correction.
    let writeRate: Double
    let readRate: Double

    /// The steering: the largest correction to the ratio, the controller's gains (a critically damped loop with a
    /// time constant of about a second), the smoothing of the measured level, and the fade-in after a start or a skip.
    /// (Computed, not stored: a stored static is made on first use, which must never be on the render thread.)
    static var maxCorrection: Double { 0.005 }
    static var proportional: Double { 2.0 }
    static var integral: Double { 1.0 }
    static var smoothingSeconds: Double { 0.1 }
    static var fadeFrames: Int { 256 }
    static var recordCount: Int { 64 }

    private struct Record {
        var written = 0
        var frames = 0
        var time = 0.0
    }

    private struct WriterState {
        var written = 0
        var sequence = 0
        var overruns = 0
    }

    private struct ReaderState {
        /// The frame under the read head and how far past it: the interpolator reads one frame behind and two ahead.
        var index = 1
        var fraction = 0.0
        var running = false
        var smoothed = 0.0
        var integral = 0.0
        var correction = 0.0
        var fade: Float = 0
        var underruns = 0
        var skips = 0
        var fill = 0
    }

    /// The published words, a cache line apart: the writer's newest record, and the oldest frame the reader still needs.
    private static var sequenceSlot: Int { 0 }
    private static var consumedSlot: Int { 8 }

    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let records: UnsafeMutablePointer<Record>
    private let published: UnsafeMutablePointer<Int>
    private let writer: UnsafeMutablePointer<WriterState>
    private let reader: UnsafeMutablePointer<ReaderState>
    /// Input frames per output frame, before any correction.
    private let ratio: Double
    /// A level this far above the target (the engine stalled while the input played on) is skipped, not steered.
    private let resyncFrames: Double
    private let clockBase: UInt64
    private let secondsPerTick: Double

    /// `writeRate`: the input's rate; `readRate`: the engine's (the same if nil). Both in Hz.
    public init(capacityFrames: Int, targetFrames: Int, writeRate: Double = 48_000, readRate: Double? = nil) {
        let target = max(4, targetFrames)
        var capacity = 1024
        while capacity < max(capacityFrames, 8 * target) { capacity *= 2 }
        let inRate = writeRate > 0 ? writeRate : 48_000
        let outRate = (readRate ?? inRate) > 0 ? (readRate ?? inRate) : inRate
        self.capacityFrames = capacity
        self.targetFrames = target
        self.writeRate = inRate
        self.readRate = outRate
        ratio = inRate / outRate
        mask = capacity - 1
        resyncFrames = max(4 * Double(target), Double(capacity) / 4)
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        records = .allocate(capacity: Self.recordCount)
        records.initialize(repeating: Record(), count: Self.recordCount)
        published = .allocate(capacity: 16)
        published.initialize(repeating: 0, count: 16)
        writer = .allocate(capacity: 1)
        writer.initialize(to: WriterState())
        reader = .allocate(capacity: 1)
        reader.initialize(to: ReaderState())
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = timebase.denom > 0 ? Double(timebase.numer) / Double(timebase.denom) / 1e9 : 1e-9
        clockBase = mach_absolute_time()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        records.deallocate()
        published.deallocate()
        writer.deallocate()
        reader.deallocate()
    }

    // MARK: - What it reports (any thread)

    /// The level after the last read, in input frames (on the steady line: see the type's notes).
    public var fillFrames: Int { reader.pointee.fill }
    /// Times the reader ran dry (each gave silence until the input was 10 ms ahead again).
    public var underruns: Int { reader.pointee.underruns }
    /// Blocks dropped because the ring was full, and skips forward after the engine fell far behind.
    public var overruns: Int { writer.pointee.overruns + reader.pointee.skips }
    /// Frames written in all (tests).
    var framesWritten: Int { writer.pointee.written }
    /// The correction to the ratio in use, −0.005…+0.005 (tests).
    var correction: Double { reader.pointee.correction }

    // MARK: - The writer (the input's I/O thread)

    /// Copies a block in. A block that doesn't fit is dropped whole and counted.
    public func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames: Int) {
        write(left: l, right: r, frames: frames, at: now())
    }

    /// As `write`, at `time` seconds on the ring's clock (tests simulate clocks with it).
    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, frames n: Int, at time: Double) {
        guard n > 0 else { return }
        let consumed = published[Self.consumedSlot]
        Self.barrier()   // the reader is done with everything before `consumed` before it is written over
        var w = writer.pointee
        guard n <= capacityFrames - (w.written - consumed) else {
            writer.pointee.overruns = w.overruns + 1
            return
        }
        let at = w.written & mask, first = min(n, capacityFrames - at)
        (left + at).update(from: l, count: first)
        (right + at).update(from: r, count: first)
        if first < n {
            left.update(from: l + first, count: n - first)
            right.update(from: r + first, count: n - first)
        }
        w.written += n
        w.sequence += 1
        records[w.sequence & (Self.recordCount - 1)] = Record(written: w.written, frames: n, time: time)
        Self.barrier()   // the frames and their record before the word that publishes them
        published[Self.sequenceSlot] = w.sequence
        writer.pointee = w
    }

    // MARK: - The reader (the engine's render thread)

    /// Fills `frames` frames at the engine's rate. Silence, never stale data, while the input is not yet (or no longer)
    /// far enough ahead.
    public func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames: Int) {
        read(left: l, right: r, frames: frames, at: now())
    }

    /// As `read`, at `time` seconds on the ring's clock (tests simulate clocks with it).
    func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames n: Int, at time: Double) {
        guard n > 0 else { return }
        var s = reader.pointee
        defer { reader.pointee = s }

        // The newest block the writer has published, and the steady line through the blocks' arrivals.
        var sequence = published[Self.sequenceSlot]
        Self.barrier()
        var record = records[sequence & (Self.recordCount - 1)]
        Self.barrier()
        let newest = published[Self.sequenceSlot]
        if newest &- sequence >= Self.recordCount - 1 {   // rewritten while it was read: take the newest
            sequence = newest
            Self.barrier()
            record = records[sequence & (Self.recordCount - 1)]
        }
        let written = record.written
        let arrived = min(Double(record.frames), max(0, time - record.time) * writeRate)
        let line = Double(written - record.frames) + arrived
        let nominal = Double(n) * ratio
        let target = Double(targetFrames)
        var level = line - (Double(s.index) + s.fraction)

        // Start (or start again) once the input is a block and the target ahead; skip forward if it is far too far.
        if !s.running || level - nominal - target > resyncFrames {
            guard level >= nominal + target else {
                Self.silence(l, r, n)
                s.fill = max(0, written - s.index)
                return
            }
            if s.running { s.skips += 1 }
            let start = line - nominal - target
            s.index = Int(start.rounded(.down))
            s.fraction = start - Double(s.index)
            s.running = true
            s.fade = 0
            s.smoothed = target
            level = nominal + target
        }

        // Steer: the level this block would leave at the nominal ratio, smoothed, against the target.
        let dt = Double(n) / readRate
        s.smoothed += dt / (Self.smoothingSeconds + dt) * (level - nominal - s.smoothed)
        let error = (s.smoothed - target) / writeRate
        let limit = Self.maxCorrection / Self.integral
        s.integral = min(limit, max(-limit, s.integral + error * dt))
        s.correction = min(Self.maxCorrection, max(-Self.maxCorrection, Self.proportional * error + Self.integral * s.integral))
        let step = ratio * (1 + s.correction)

        // Every frame this block reads must be there: run dry, give silence and wait for the target again.
        let reach = s.fraction + Double(n - 1) * step
        guard s.index + Int(reach) + 3 <= written else {
            s.underruns += 1
            s.running = false
            Self.silence(l, r, n)
            s.fill = max(0, written - s.index)
            return
        }

        let mask = self.mask, ringLeft = left, ringRight = right
        let fadeStep = 1 / Float(Self.fadeFrames)
        var i = s.index, f = s.fraction, fade = s.fade
        for j in 0..<n {
            let t = Float(f)
            let a = (i &- 1) & mask, b = i & mask, c = (i &+ 1) & mask, d = (i &+ 2) & mask
            var yl = Self.hermite(ringLeft[a], ringLeft[b], ringLeft[c], ringLeft[d], t)
            var yr = Self.hermite(ringRight[a], ringRight[b], ringRight[c], ringRight[d], t)
            if fade < 1 {
                yl *= fade
                yr *= fade
                fade = min(1, fade + fadeStep)
            }
            l[j] = yl
            r[j] = yr
            f += step
            let whole = Int(f)
            i &+= whole
            f -= Double(whole)
        }
        s.index = i
        s.fraction = f
        s.fade = fade
        s.fill = Int((line - (Double(i) + f)).rounded())
        Self.barrier()   // done reading before the writer may write over it
        published[Self.consumedSlot] = i - 1
    }

    // MARK: - Private

    /// The ring's clock in seconds (the host clock, which every thread shares).
    @inline(__always) private func now() -> Double {
        Double(mach_absolute_time() &- clockBase) * secondsPerTick
    }

    /// A full memory barrier. `OSMemoryBarrier` is deprecated in favour of C11's `atomic_thread_fence`, which Swift
    /// can't call; it is still the system's full barrier (`mfence` on Intel) and never blocks.
    @inline(__always) private static func barrier() { OSMemoryBarrier() }

    @inline(__always) private static func silence(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        l.update(repeating: 0, count: n)
        r.update(repeating: 0, count: n)
    }

    /// 4-point, 3rd-order Hermite interpolation between `x0` and `x1`, `t` of the way (0…1).
    @inline(__always) static func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
        let c1: Float = 0.5 * (x1 - xm1)
        let c2: Float = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3: Float = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }
}
