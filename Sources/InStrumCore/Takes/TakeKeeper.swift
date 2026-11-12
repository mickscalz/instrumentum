import Foundation

/// One thing played, `time` seconds from its take's start (in the keeper's ring: system uptime).
public struct TakeEvent: Equatable {
    public var time: Double
    public var message: MIDIMessage

    public init(time: Double, message: MIDIMessage) {
        self.time = time
        self.message = message
    }
}

/// A take, ready to keep: its events from 0 in time order, and how long it runs (its last 2 s let the sound ring).
public struct Take: Equatable {
    public var events: [TakeEvent]
    public var duration: Double

    public init(events: [TakeEvent], duration: Double) {
        self.events = events
        self.duration = duration
    }
}

/// Keep that (Small Wins spec §2): what the instrument heard over the last two hours, in memory only, and the take it
/// hands back when asked.
/// - **Kept:** note on and off with their velocities, the sustain, sostenuto and soft pedals (CC 64, 66, 67), pitch bend
///   and both pressures, as the instrument heard them (after the touch curve). Nothing else.
/// - **The ring** is preallocated: 250,000 events at most, never older than two hours, the oldest dropped first.
/// - **A take** runs from the first note after the last silence of 8 s or more (no key down and no note struck; the
///   pedals alone are silence), to 2 s after its last event, or to now if a key is still down or that is later. It is
///   at most 30 minutes long, and there is none if the newest note was more than 10 minutes ago. The pedals, the bend
///   and the pressure stand at its start as they stood then; a key down before its start is left out, and one down at
///   its end is let go there.
/// - **The gesture** (`KeyGesture`): tapping the top three black keys twice returns its start from `record`, and it is
///   cut from the ring, its late note-offs too.
public struct TakeKeeper {
    public static let horizon = 7200.0, cap = 250_000, silence = 8.0, longest = 1800.0, stale = 600.0, tail = 2.0

    private var ring: [TakeEvent]
    private var head = 0
    /// Events in the ring.
    public private(set) var count = 0
    private var gesture: KeyGesture
    /// Keys down now, by channel × 128 + note, and how many.
    private var held: [Bool]
    private var heldCount = 0
    /// The gesture's keys still down after it fired: their note-offs are never kept.
    private var muted: [Bool]
    private var latest = -Double.infinity

    public init(low: UInt8 = KeyboardLayout.lowestNote, high: UInt8 = KeyboardLayout.highestNote) {
        ring = [TakeEvent](repeating: TakeEvent(time: 0, message: .other), count: Self.cap)
        held = [Bool](repeating: false, count: 16 * 128)
        muted = [Bool](repeating: false, count: 16 * 128)
        gesture = KeyGesture(notes: KeyGesture.triple(low: low, high: high) ?? [])
    }

    /// The keyboard's range, where the gesture's keys are.
    public mutating func setRange(low: UInt8, high: UInt8) {
        gesture = KeyGesture(notes: KeyGesture.triple(low: low, high: high) ?? [])
    }

    /// Keeps a message the instrument heard at `time` (system uptime; never earlier than the last). Returns the start of
    /// the gesture when this note-on completes it.
    @discardableResult
    public mutating func record(_ m: MIDIMessage, at time: Double) -> Double? {
        let t = max(time, latest)
        let fired = gesture.feed(m, at: t)
        switch m {
        case let .noteOn(c, n, _):
            let k = Self.slot(c, n)
            muted[k] = false
            if !held[k] { held[k] = true; heldCount += 1 }
        case let .noteOff(c, n, _):
            let k = Self.slot(c, n)
            if muted[k] { muted[k] = false; return fired }   // the gesture's key let go
            if held[k] { held[k] = false; heldCount -= 1 }
        case let .controlChange(c, controller, _) where controller == 120 || controller == 123:
            letGo(channel: c, at: t)   // all sound off, all notes off: every key on the channel is let go
            return fired
        default:
            guard Self.isKept(m) else { return fired }
        }
        append(TakeEvent(time: t, message: m))
        if let start = fired { cut(from: start) }
        return fired
    }

    /// A panic: every key down is let go now.
    public mutating func releaseAll(at time: Double) {
        for c in 0..<16 { letGo(channel: UInt8(c), at: max(time, latest)) }
    }

    /// The last take ending at `now`, or nil when there is nothing to keep.
    public func lastTake(endingAt now: Double) -> Take? {
        guard var reading = Reading(self, now: now) else { return nil }
        let last = reading.last
        // The newest note: now while a key is down, else the newest note-on or note-off.
        var newest = reading.sounding ? now : -Double.infinity
        if !reading.sounding {
            var j = last
            while j >= 0 { if Self.isNote(event(j).message) { newest = event(j).time; break }; j -= 1 }
        }
        guard newest > -Double.infinity, now - newest <= Self.stale else { return nil }
        let end = reading.end
        // Back to the last silence of 8 s or more: a gap between two notes with no key down.
        var later: Double?
        var j = last
        while j >= 0 {
            let e = event(j)
            if Self.isNote(e.message) {
                if let l = later, reading.heldCount == 0, l - e.time >= Self.silence { break }
                reading.undo(e.message)
                later = e.time
            }
            j -= 1
        }
        // From the first note-on after it, and no more than 30 minutes before the end.
        let earliest = end - Self.longest
        var first = j + 1
        while first <= last, !(Self.isNoteOn(event(first).message) && event(first).time >= earliest) { first += 1 }
        guard first <= last else { return nil }
        return take(from: first, through: last, end: end)
    }

    /// The last `seconds` (at most 30 minutes) ending at `now`, whatever silences they hold: from their first note-on.
    public func lastMinutes(_ seconds: Double = 600, endingAt now: Double) -> Take? {
        guard let reading = Reading(self, now: now) else { return nil }
        let last = reading.last
        let from = now - min(max(0, seconds), Self.longest)
        var first: Int?
        var j = last
        while j >= 0, event(j).time >= from {
            if Self.isNoteOn(event(j).message) { first = j }
            j -= 1
        }
        guard let first else { return nil }
        return take(from: first, through: last, end: reading.end)
    }

    // MARK: - The ring

    /// The `i`th event, oldest first.
    private func event(_ i: Int) -> TakeEvent { ring[(head + i) % Self.cap] }

    private mutating func append(_ e: TakeEvent) {
        latest = e.time
        if count == Self.cap {   // full: the oldest gives way
            head = (head + 1) % Self.cap
            count -= 1
        }
        ring[(head + count) % Self.cap] = e
        count += 1
        while count > 0, ring[head].time < e.time - Self.horizon {
            head = (head + 1) % Self.cap
            count -= 1
        }
    }

    private mutating func letGo(channel c: UInt8, at t: Double) {
        for n in 0..<128 {
            let k = Self.slot(c, UInt8(n))
            if muted[k] { muted[k] = false }
            guard held[k] else { continue }
            held[k] = false
            heldCount -= 1
            append(TakeEvent(time: t, message: .noteOff(channel: c, note: UInt8(n))))
        }
    }

    /// Cuts the gesture from the ring: the three keys' note-ons from its start, and the note-offs that let them go.
    /// Those still down are muted, so their note-offs are never kept.
    private mutating func cut(from start: Double) {
        var i = count - 1
        while i > 0, event(i - 1).time >= start { i -= 1 }
        var open = [Bool](repeating: false, count: 16 * 128)
        var write = i
        for read in i..<count {
            let e = event(read)
            var drop = false
            switch e.message {
            case let .noteOn(c, n, _) where gesture.notes.contains(n):
                open[Self.slot(c, n)] = true
                drop = true
            case let .noteOff(c, n, _) where open[Self.slot(c, n)]:
                open[Self.slot(c, n)] = false
                drop = true
            default: break
            }
            guard !drop else { continue }
            ring[(head + write) % Self.cap] = e
            write += 1
        }
        count = write
        for k in open.indices where open[k] {
            if held[k] { held[k] = false; heldCount -= 1 }
            muted[k] = true
        }
    }

    // MARK: - Reading a take

    /// The ring as it stood at `now`: the newest event no later than it, which keys were down then, and where a take
    /// ending then ends.
    private struct Reading {
        var held: [Bool]
        var heldCount: Int
        let last: Int
        let sounding: Bool
        let end: Double

        init?(_ keeper: TakeKeeper, now: Double) {
            var down = keeper.held, downCount = keeper.heldCount
            var i = keeper.count - 1
            while i >= 0, keeper.event(i).time > now {
                Self.undo(keeper.event(i).message, &down, &downCount)
                i -= 1
            }
            guard i >= 0 else { return nil }
            held = down
            heldCount = downCount
            last = i
            sounding = downCount > 0
            end = sounding ? now : min(now, keeper.event(i).time + TakeKeeper.tail)
        }

        /// Steps back over a message: the keys down before it.
        mutating func undo(_ m: MIDIMessage) { Self.undo(m, &held, &heldCount) }

        static func undo(_ m: MIDIMessage, _ held: inout [Bool], _ count: inout Int) {
            switch m {
            case let .noteOn(c, n, _):
                let k = TakeKeeper.slot(c, n)
                if held[k] { held[k] = false; count -= 1 }
            case let .noteOff(c, n, _):
                let k = TakeKeeper.slot(c, n)
                if !held[k] { held[k] = true; count += 1 }
            default: break
            }
        }
    }

    /// The take from the `first` event (a note-on) through the `last`, ending at `end`.
    private func take(from first: Int, through last: Int, end: Double) -> Take {
        let start = event(first).time
        var events: [TakeEvent] = []
        events.reserveCapacity(last - first + 32)
        // The pedals, the bend and the pressure as they stood when it began.
        var pedalValues = [UInt8](repeating: 0, count: 16 * 3)
        var bend = [UInt16](repeating: 8192, count: 16)
        var pressure = [UInt8](repeating: 0, count: 16)
        for i in 0..<first {
            switch event(i).message {
            case let .controlChange(c, controller, value):
                if let p = Self.pedals.firstIndex(of: controller) { pedalValues[Int(c & 15) * 3 + p] = value }
            case let .pitchBend(c, value): bend[Int(c & 15)] = value
            case let .channelPressure(c, value): pressure[Int(c & 15)] = value
            default: break
            }
        }
        for c in 0..<16 {
            let channel = UInt8(c)
            for (p, controller) in Self.pedals.enumerated() where pedalValues[c * 3 + p] != 0 {
                let value = pedalValues[c * 3 + p]
                events.append(TakeEvent(time: 0, message: .controlChange(channel: channel, controller: controller, value: value)))
            }
            if bend[c] != 8192 { events.append(TakeEvent(time: 0, message: .pitchBend(channel: channel, value: bend[c]))) }
            if pressure[c] != 0 { events.append(TakeEvent(time: 0, message: .channelPressure(channel: channel, value: pressure[c]))) }
        }
        // What was played, with every note-on paired: a key down before the start is left out, one down at the end
        // let go there.
        var open = [Bool](repeating: false, count: 16 * 128)
        for i in first...last {
            let e = event(i)
            let t = e.time - start
            switch e.message {
            case let .noteOn(c, n, _):
                let k = Self.slot(c, n)
                if open[k] { events.append(TakeEvent(time: t, message: .noteOff(channel: c, note: n))) }
                open[k] = true
            case let .noteOff(c, n, _):
                let k = Self.slot(c, n)
                guard open[k] else { continue }
                open[k] = false
            case let .polyPressure(c, n, _):
                guard open[Self.slot(c, n)] else { continue }
            default: break
            }
            events.append(TakeEvent(time: t, message: e.message))
        }
        let duration = max(0, end - start)
        for k in open.indices where open[k] {
            events.append(TakeEvent(time: duration, message: .noteOff(channel: UInt8(k / 128), note: UInt8(k % 128))))
        }
        return Take(events: events, duration: duration)
    }

    // MARK: - Kinds

    static let pedals: [UInt8] = [64, 66, 67]

    static func slot(_ channel: UInt8, _ note: UInt8) -> Int { Int(channel & 15) * 128 + Int(note & 127) }

    /// What a take keeps: note on and off, the three pedals, the bend and both pressures.
    static func isKept(_ m: MIDIMessage) -> Bool {
        switch m {
        case .noteOn, .noteOff, .pitchBend, .channelPressure, .polyPressure: return true
        case let .controlChange(_, controller, _): return pedals.contains(controller)
        case .other: return false
        }
    }

    static func isNote(_ m: MIDIMessage) -> Bool {
        switch m {
        case .noteOn, .noteOff: return true
        default: return false
        }
    }

    static func isNoteOn(_ m: MIDIMessage) -> Bool {
        if case .noteOn = m { return true }
        return false
    }
}
