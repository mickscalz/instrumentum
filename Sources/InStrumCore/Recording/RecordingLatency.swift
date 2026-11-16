import Foundation

/// Lining layers up with what was heard (Recorder spec §4). He plays to what he hears, which is later than the engine's
/// clock by the output's latency (a few ms on built-in speakers, 150 ms or more on Bluetooth), so a new stem is moved
/// earlier by it: an instrument stem by the output's latency, a live input by that plus the input's and the capture
/// buffer's. The Timing nudge (−100…+100 ms) moves both further, for a device that reports wrongly. The play-along and
/// the ambience are heard as they are recorded, so they never move.
public enum RecordingLatency {
    /// A device's latency as Core Audio reports it, in frames at the engine's rate.
    public struct Device: Equatable, Sendable {
        /// The device's latency plus its stream's.
        public var latencyFrames: Int
        /// The device's safety offset.
        public var safetyFrames: Int
        /// The I/O buffer.
        public var bufferFrames: Int

        /// All three.
        public var total: Int { latencyFrames + safetyFrames + bufferFrames }

        public init(latencyFrames: Int, safetyFrames: Int, bufferFrames: Int) {
            self.latencyFrames = latencyFrames
            self.safetyFrames = safetyFrames
            self.bufferFrames = bufferFrames
        }
    }

    /// The Timing nudge's range, in milliseconds.
    public static let nudgeRange: ClosedRange<Double> = -100...100

    /// The nudge in frames, held to its range and rounded (0 for a nonsense value or rate).
    public static func nudgeFrames(_ nudgeMs: Double, sampleRate: Double) -> Int {
        guard nudgeMs.isFinite, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let ms = min(max(nudgeMs, nudgeRange.lowerBound), nudgeRange.upperBound)
        return Int((ms / 1000 * sampleRate).rounded())
    }

    /// Where a new stem's first frame goes on the recording's clock: negative is earlier. A positive nudge moves a
    /// played stem earlier still. An input that reports nothing (`nil`) adds only the capture buffer.
    public static func offsetFrames(kind: StemKind, output: Device, input: Device?, captureBufferFrames: Int, nudgeMs: Double,
                                    sampleRate: Double) -> Int {
        let nudge = nudgeFrames(nudgeMs, sampleRate: sampleRate)
        switch kind {
        case .instrument:
            return -output.total - nudge
        case .liveInput:
            let inputTotal = input?.total ?? 0
            return -(output.total + inputTotal + captureBufferFrames) - nudge
        case .playAlong, .ambience:
            return 0
        }
    }
}
