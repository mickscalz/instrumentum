import Foundation

/// The keep gesture (Small Wins spec §2): the keyboard's top three black keys, F♯, G♯ and A♯ of its highest whole octave
/// (F♯7, G♯7 and A♯7 on an 88), tapped together twice within 1.5 s.
/// - **A tap** is the three keys alone: their note-ons within 80 ms of the first, with no other note-on from 80 ms before
///   it to its last. One of the three struck again, or late, spoils it.
/// - **Two taps** fire when the second starts within 1.5 s of the first, with nothing else played between them. A third
///   tap starts a new count.
///
/// Only note-ons matter: note-offs, pedals and the rest pass by. It never allocates once made.
public struct KeyGesture {
    /// How close together the three note-ons of a tap must be (seconds).
    public static let together = 0.08
    /// How soon after the first tap the second must start (seconds).
    public static let within = 1.5

    /// F♯, G♯ and A♯ of the highest octave wholly inside `low…high`, or nil when there is none.
    public static func triple(low: UInt8, high: UInt8) -> [UInt8]? {
        guard low <= high, high >= 10 else { return nil }
        let top = Int(high)
        let aSharp = top - (top - 10) % 12   // the highest A♯ (pitch class 10) at or below `high`
        guard aSharp - 4 >= Int(low) else { return nil }
        return [UInt8(aSharp - 4), UInt8(aSharp - 2), UInt8(aSharp)]
    }

    /// The three keys (none: the gesture never fires).
    public let notes: [UInt8]
    /// The open tap: its first note-on, which of the three it has (a bit each), and whether another note came too close.
    private var tapStart: Double?
    private var struck: UInt8 = 0
    private var spoiled = false
    /// The count's first tap, waiting for its pair.
    private var firstTap: Double?
    /// The last note-on of any other key.
    private var lastOther = -Double.infinity

    public init(notes: [UInt8]) { self.notes = notes.count == 3 ? notes : [] }

    /// Hands the gesture one message. Returns the first tap's start when this note-on completes the second tap.
    public mutating func feed(_ m: MIDIMessage, at t: Double) -> Double? {
        guard case let .noteOn(_, note, _) = m else { return nil }
        guard let index = notes.firstIndex(of: note) else {
            lastOther = t
            tapStart = nil
            firstTap = nil   // something else was played: the count starts again
            return nil
        }
        let bit = UInt8(1) << UInt8(index)
        if let start = tapStart, t - start <= Self.together + 1e-9, struck & bit == 0 {
            struck |= bit
        } else {
            if tapStart != nil { firstTap = nil }   // one of the three late, or struck twice: no tap, and no pair
            tapStart = t
            struck = bit
            spoiled = t - lastOther <= Self.together + 1e-9
        }
        guard struck == 0b111, let start = tapStart else { return nil }
        tapStart = nil
        struck = 0
        if spoiled {
            firstTap = nil
            return nil
        }
        if let first = firstTap, start - first <= Self.within + 1e-9 {
            firstTap = nil
            return first
        }
        firstTap = start
        return nil
    }
}
