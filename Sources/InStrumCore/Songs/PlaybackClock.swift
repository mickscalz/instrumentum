import Foundation

/// Where Spotify is in the song between its answers (Song Sheet spec §2). It runs on the Mac's clock (`now`, in
/// seconds, from any steady clock) from the last answer it took:
/// - the first answer, a pause or a play, and a jump of more than 1.5 s from where the clock is (a seek, a new song)
///   re-anchor it on the answer;
/// - a smaller difference moves it halfway to the answer, so it settles without jumping back and forth;
/// - while paused it stands still;
/// - an answer that repeats the last position while playing says nothing new: the clock runs on, and after two such
///   answers 2 s apart `looksStuck` (Spotify's position has stopped updating; time to ask the Web API instead).
public struct PlaybackClock: Equatable, Sendable {
    /// A difference larger than this (seconds) is a seek or a new song.
    public static let jump: Double = 1.5
    /// The same position for this long while playing is stuck.
    public static let stuckAfter: Double = 2

    private var anchorPosition: Double = 0
    private var anchorTime: Double = 0
    private var playing = false
    private var hasAnswer = false
    private var lastPosition: Double = 0
    /// When the current run of equal positions (while playing) began.
    private var samePositionSince: Double?
    public private(set) var looksStuck = false

    public init() {}

    /// An answer from Spotify: `position` seconds into the song, playing or not, read at `now`.
    public mutating func report(position: Double, playing: Bool, at now: Double) {
        if hasAnswer && self.playing && playing && position == lastPosition {
            if let since = samePositionSince, now - since >= Self.stuckAfter - 1e-9 { looksStuck = true }
            return
        }
        looksStuck = false
        samePositionSince = playing ? now : nil
        let predicted = self.position(at: now)
        if hasAnswer && playing && self.playing && abs(position - predicted) <= Self.jump {
            anchorPosition = predicted + (position - predicted) / 2
        } else {
            anchorPosition = position
        }
        anchorTime = now
        self.playing = playing
        lastPosition = position
        hasAnswer = true
    }

    /// Seconds into the song at `now`: 0 before the first answer.
    public func position(at now: Double) -> Double {
        playing ? anchorPosition + (now - anchorTime) : anchorPosition
    }
}
