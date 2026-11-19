import Foundation

/// A chord as the sheet shows it: over the word `wordIndex` of its line, at `time` in the song.
public struct PlacedChord: Equatable, Sendable {
    public var chord: Chord
    public var wordIndex: Int
    public var time: Double

    public init(chord: Chord, wordIndex: Int, time: Double) {
        self.chord = chord
        self.wordIndex = wordIndex
        self.time = time
    }
}

/// Where a chord sits (Song Sheet spec §5).
/// - With word timing, a chord sits over the word being sung at its time. With line timing only, the words of a line are
///   spread across the line's span (to the next line's start, at most 8 s) in proportion to their length in letters.
/// - A chord within 0.3 s before a line starts sits on that line's first word. Any other chord between lines (in an
///   instrumental gap, or after a line's 8 s) sits at the end of the line before. Chords before the first line, and
///   chords on unsynced lyrics, are not placed.
/// - Two chords on one word are both kept, in time order: the panel moves the later one right until it clears, and
///   spreads the words below to keep each chord over its word.
public enum ChordPlacement {
    /// The longest a line's words are spread over, in seconds.
    public static let maxSpan: Double = 8
    /// How far before a line's start a chord still belongs to that line's first word, in seconds.
    public static let leadIn: Double = 0.3

    /// When each word of a line is sung. Words with their own time keep it; the others are spread between the
    /// neighbouring known times (the line's start, and the end of its span) in proportion to their letters.
    /// Unsynced lines (time -1) give -1 for every word.
    public static func wordTimes(_ line: LyricLine, nextStart: Double?) -> [Double] {
        let n = line.words.count
        guard n > 0 else { return [] }
        guard line.time >= 0 else { return Array(repeating: line.time, count: n) }
        let end = spanEnd(line, nextStart: nextStart)
        var anchors: [(index: Int, time: Double)] = []
        for (i, word) in line.words.enumerated() {
            if let t = word.time { anchors.append((index: i, time: t)) }
        }
        if anchors.first?.index != 0 { anchors.insert((index: 0, time: line.time), at: 0) }
        let lastTime = anchors[anchors.count - 1].time
        anchors.append((index: n, time: max(end, lastTime)))
        var times = Array(repeating: line.time, count: n)
        for a in 0..<(anchors.count - 1) {
            let from = anchors[a]
            let to = anchors[a + 1]
            var total = 0
            for k in from.index..<to.index { total += letters(line.words[k].text) }
            var before = 0
            for k in from.index..<to.index {
                times[k] = from.time + (to.time - from.time) * Double(before) / Double(total)
                before += letters(line.words[k].text)
            }
        }
        return times
    }

    /// The chords sorted onto the lines: one array per line (empty for gaps and unsynced lines), each in time order.
    public static func place(_ chords: [ChordEvent], on lines: [LyricLine]) -> [[PlacedChord]] {
        var placed = Array(repeating: [PlacedChord](), count: lines.count)
        // The lines that can hold a chord: synced, with words.
        var holders: [Int] = []
        for i in lines.indices where lines[i].time >= 0 && !lines[i].words.isEmpty { holders.append(i) }
        guard !holders.isEmpty else { return placed }
        var times: [Int: [Double]] = [:]
        for i in holders { times[i] = wordTimes(lines[i], nextStart: i + 1 < lines.count ? lines[i + 1].time : nil) }
        var order: [Int] = Array(chords.indices)
        order.sort { a, b in
            if chords[a].time != chords[b].time { return chords[a].time < chords[b].time }
            return a < b
        }
        for c in order {
            let event = chords[c]
            var line: Int?
            var word = 0
            if let next = holders.first(where: { lines[$0].time > event.time }), lines[next].time - event.time <= leadIn {
                line = next
            } else if let earlier = holders.last(where: { lines[$0].time <= event.time }) {
                line = earlier
                word = wordAt(event.time, in: times[earlier] ?? [])
            }
            if let i = line { placed[i].append(PlacedChord(chord: event.chord, wordIndex: word, time: event.time)) }
        }
        return placed
    }

    /// The line being sung at `t`: the last synced line that has started. Nil before the first line, and for
    /// unsynced lyrics.
    public static func currentLine(_ lines: [LyricLine], at t: Double) -> Int? {
        var current: Int?
        for i in lines.indices where lines[i].time >= 0 && lines[i].time <= t { current = i }
        return current
    }

    /// The word being sung at `t`: nil before the line's first word, after its span ends (an instrumental gap after
    /// it), and for gaps and unsynced lines.
    public static func currentWord(_ line: LyricLine, nextStart: Double?, at t: Double) -> Int? {
        guard line.time >= 0 else { return nil }
        let times = wordTimes(line, nextStart: nextStart)
        guard let first = times.first, let last = times.last, t >= first else { return nil }
        if t >= spanEnd(line, nextStart: nextStart) && t > last { return nil }
        return wordAt(t, in: times)
    }

    // MARK: -

    /// Where a line's words end: the next line's start, at most 8 s after its own.
    private static func spanEnd(_ line: LyricLine, nextStart: Double?) -> Double {
        let cap = line.time + maxSpan
        return max(line.time, min(nextStart ?? cap, cap))
    }

    /// The last word that has started by `t` (the first word if none has).
    private static func wordAt(_ t: Double, in times: [Double]) -> Int {
        var word = 0
        for (k, wt) in times.enumerated() where wt <= t { word = k }
        return word
    }

    /// A word's length in letters (and digits), at least 1 so a dash or "&" still takes a moment.
    private static func letters(_ word: String) -> Int {
        var count = 0
        for c in word where c.isLetter || c.isNumber { count += 1 }
        return max(1, count)
    }
}
