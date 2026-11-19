import Foundation

/// The Recorder's one timeline (Recorder plan part 2, "One timeline"): the play-along track and the recorded layers share
/// one position, one cue point and one loop, in the track's seconds. Pure: the app ticks it from the engine's position
/// and asks the engine to follow it.
public struct TransportState: Equatable, Sendable {
    public var position: Double
    public var duration: Double
    /// Where Cue returns to; it starts at 0.
    public var cue: Double
    public var loopIn: Double?
    public var loopOut: Double?
    public var looping: Bool
    public var playing: Bool
    /// The track's speed, 0.9…1.1, its pitch kept.
    public var rate: Double

    /// The shortest loop (50 ms) and the tempo's range (±10%).
    public static let minLoop = 0.05, minRate = 0.9, maxRate = 1.1

    public init(position: Double = 0, duration: Double = 0, cue: Double = 0, loopIn: Double? = nil, loopOut: Double? = nil,
                looping: Bool = false, playing: Bool = false, rate: Double = 1) {
        self.position = position
        self.duration = duration
        self.cue = cue
        self.loopIn = loopIn
        self.loopOut = loopOut
        self.looping = looping
        self.playing = playing
        self.rate = rate
    }

    /// As on a DJ deck. Paused: the cue point moves to the position, and nil comes back. Playing: back to the cue point,
    /// paused there, and the cue point comes back (where the engine must go).
    @discardableResult
    public mutating func pressCue() -> Double? {
        guard playing else {
            cue = position
            return nil
        }
        playing = false
        position = cue
        return cue
    }

    /// IN: the loop starts at the position; any end it had, and the looping, are cleared.
    public mutating func pressLoopIn() {
        loopIn = position
        loopOut = nil
        looping = false
    }

    /// OUT: not looping, it sets the loop's end at the position and starts looping, if there is a start at least
    /// `minLoop` before it (a shorter loop is not made). Looping, it leaves the loop.
    public mutating func pressLoopOut() {
        if looping {
            looping = false
            return
        }
        guard let start = loopIn, position - start >= Self.minLoop else { return }
        loopOut = position
        looping = true
    }

    /// Moves the position, held to 0…duration.
    public mutating func scrub(by seconds: Double) {
        guard seconds.isFinite else { return }
        position = min(max(position + seconds, 0), max(duration, 0))
    }

    /// While playing, moves the position on by `seconds` × the rate. Looping, crossing the loop's end wraps to its start
    /// by as much as went past (a position already past the end plays on). The end of the timeline stops it there. True
    /// when it wrapped or stopped.
    @discardableResult
    public mutating func advance(by seconds: Double) -> Bool {
        guard playing, seconds.isFinite, seconds > 0 else { return false }
        let before = position
        position += seconds * rate
        if looping, let start = loopIn, let end = loopOut, end > start, before < end, position >= end {
            position = start + (position - end).truncatingRemainder(dividingBy: end - start)
            return true
        }
        if position >= duration {
            position = max(duration, 0)
            playing = false
            return true
        }
        return false
    }

    /// A tempo slider at 0…1 as a speed, 1.1…0.9 (the top of a DJ tempo slider is slower); the centre is exactly 1.
    public static func rate(fromSlider x: Double) -> Double {
        guard x.isFinite else { return 1 }
        let held = min(max(x, 0), 1)
        return 1 + 0.2 * (0.5 - held)
    }

    /// A jog wheel's turn as seconds; `units` are eighths of a turn. Fine (the platter's top): 0.25 s a unit, 2 s a turn.
    /// Search (its edge): 2 s a unit, up to 8× faster the faster it spins (16 s a slow turn).
    public static func jogSeconds(units: Double, fine: Bool) -> Double {
        guard units.isFinite else { return 0 }
        if fine { return units * 0.25 }
        return units * 2 * min(8, 1 + 6.25 * abs(units))
    }
}
