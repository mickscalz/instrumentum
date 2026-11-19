import Foundation

/// One lyric line of a pasted chord sheet with its chords. `wordIndex` counts the words of `text`, which are separated
/// by single spaces.
public struct SheetLine: Equatable, Sendable {
    public var text: String
    public var chords: [(chord: Chord, wordIndex: Int)]

    public init(text: String, chords: [(chord: Chord, wordIndex: Int)] = []) {
        self.text = text
        self.chords = chords
    }

    /// Written out because an array of tuples is not Equatable.
    public static func == (a: SheetLine, b: SheetLine) -> Bool {
        guard a.text == b.text, a.chords.count == b.chords.count else { return false }
        for k in a.chords.indices {
            if a.chords[k].chord != b.chords[k].chord || a.chords[k].wordIndex != b.chords[k].wordIndex { return false }
        }
        return true
    }
}

/// Reads a chord sheet pasted from anywhere (Song Sheet spec §4) in either form:
/// - chords over lyrics: a line of chord names above each lyric line, each chord over the word its column sits on
///   (a chord past the end of the line goes on the last word);
/// - ChordPro: `[Am]` inside the words, on the word the bracket sits in or before.
/// A chord line with no lyric line under it (an intro or a turnaround) is attached to the next lyric line's first word.
/// Headings ("[Chorus]", "Verse 1:", "(Bridge)", "Capo 2", ChordPro's `{…}`) are skipped; "Intro: Am F" keeps its
/// chords. Tabs count to the next multiple of 8 columns.
public enum ChordSheetParser {
    public static func parse(_ text: String) -> [SheetLine] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [SheetLine] = []
        var pending: [Chord] = []
        var above: [(chord: Chord, column: Int)] = []
        for raw in normalised.components(separatedBy: "\n") {
            let row = Array(expandTabs(raw))
            switch classify(row) {
            case .skip:
                pending += chordsOf(above)
                above = []
            case .chordOnly(let chords):
                pending += chordsOf(above)
                above = []
                pending += chords
            case .chordLine(let chords):
                pending += chordsOf(above)
                above = chords
            case .chordPro(let words, let chords):
                pending += chordsOf(above)
                above = []
                lines.append(sheetLine(words, first: pending, chords: chords))
                pending = []
            case .lyric(let words):
                var chords: [(chord: Chord, wordIndex: Int)] = []
                for c in above {
                    chords.append((chord: c.chord, wordIndex: wordIndex(atColumn: c.column, in: words)))
                }
                above = []
                lines.append(sheetLine(words, first: pending, chords: chords))
                pending = []
            }
        }
        return lines
    }

    // MARK: - Rows

    private struct Word {
        var text: String
        /// Columns: the first character, and one past the last.
        var start: Int
        var end: Int
    }

    private enum Row {
        case skip
        case chordOnly([Chord])
        case chordLine([(chord: Chord, column: Int)])
        case lyric([Word])
        case chordPro([Word], [(chord: Chord, wordIndex: Int)])
    }

    private static func classify(_ row: [Character]) -> Row {
        let words = tokens(row)
        guard !words.isEmpty else { return .skip }
        let line = String(row).trimmingCharacters(in: .whitespaces)
        // ChordPro directives: {title: …}, {soc}, {c: Chorus}.
        if line.hasPrefix("{") && line.hasSuffix("}") { return .skip }
        if isHeading(line) { return .skip }
        // "Intro: Am F C G" or "Chorus: the words": the heading goes, the rest of the row stays in its columns.
        if let colon = row.firstIndex(of: ":"), isSection(String(row[..<colon])) {
            var rest = row
            for k in 0...colon { rest[k] = " " }
            return classify(rest)
        }
        if let pro = chordPro(row) { return pro }
        // A chord line: every word a chord, a bar line, "N.C." or a repeat mark, and at least one chord.
        var chords: [(chord: Chord, column: Int)] = []
        for w in words {
            if let c = chordToken(w.text) {
                chords.append((chord: c, column: w.start))
            } else if !isFiller(w.text) {
                return .lyric(words)
            }
        }
        return chords.isEmpty ? .skip : .chordLine(chords)
    }

    /// Chords in brackets inside the words; nil when the row has none.
    private static func chordPro(_ row: [Character]) -> Row? {
        var text: [Character] = []
        var marks: [(chord: Chord, at: Int)] = []
        var found = false
        var k = 0
        while k < row.count {
            if row[k] == "[", let close = row[k...].firstIndex(of: "]") {
                let inner = String(row[(k + 1)..<close]).trimmingCharacters(in: .whitespaces)
                if let chord = ChordSpelling.parse(inner) {
                    marks.append((chord: chord, at: text.count))
                    found = true
                    k = close + 1
                    continue
                }
                if isNoChord(inner) {
                    found = true
                    k = close + 1
                    continue
                }
            }
            text.append(row[k])
            k += 1
        }
        guard found else { return nil }
        let words = tokens(text)
        var chords: [(chord: Chord, wordIndex: Int)] = []
        var bare: [Chord] = []
        for m in marks {
            bare.append(m.chord)
            chords.append((chord: m.chord, wordIndex: wordIndex(atColumn: m.at, in: words)))
        }
        return words.isEmpty ? .chordOnly(bare) : .chordPro(words, chords)
    }

    private static func sheetLine(_ words: [Word], first: [Chord], chords: [(chord: Chord, wordIndex: Int)]) -> SheetLine {
        var all: [(chord: Chord, wordIndex: Int)] = []
        for c in first { all.append((chord: c, wordIndex: 0)) }
        all += chords
        var texts: [String] = []
        for w in words { texts.append(w.text) }
        return SheetLine(text: texts.joined(separator: " "), chords: all)
    }

    private static func chordsOf(_ line: [(chord: Chord, column: Int)]) -> [Chord] {
        var chords: [Chord] = []
        for c in line { chords.append(c.chord) }
        return chords
    }

    /// The words of a row with their columns.
    private static func tokens(_ row: [Character]) -> [Word] {
        var words: [Word] = []
        var start: Int?
        for (k, c) in row.enumerated() {
            if c.isWhitespace {
                if let s = start {
                    words.append(Word(text: String(row[s..<k]), start: s, end: k))
                    start = nil
                }
            } else if start == nil {
                start = k
            }
        }
        if let s = start { words.append(Word(text: String(row[s..<row.count]), start: s, end: row.count)) }
        return words
    }

    /// The word under a column, or the next one to its right; past the end of the line, the last word.
    private static func wordIndex(atColumn column: Int, in words: [Word]) -> Int {
        for (k, w) in words.enumerated() where column < w.end { return k }
        return max(0, words.count - 1)
    }

    private static func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        var column = 0
        for c in s {
            if c == "\t" {
                let spaces = 8 - column % 8
                out += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                out.append(c)
                column += 1
            }
        }
        return out
    }

    // MARK: - Words that are not lyrics

    /// "Am", or "(Am)".
    private static func chordToken(_ s: String) -> Chord? {
        if let c = ChordSpelling.parse(s) { return c }
        if s.count > 2, s.hasPrefix("("), s.hasSuffix(")") { return ChordSpelling.parse(String(s.dropFirst().dropLast())) }
        return nil
    }

    /// Bar lines and the like, "N.C." and repeat marks: allowed in a chord line, but not chords.
    private static func isFiller(_ s: String) -> Bool {
        if s.allSatisfy({ "|/:-–—%.*~".contains($0) }) { return true }
        return isNoChord(s) || isRepeat(s)
    }

    /// "N.C.", "NC", "(N.C.)": no chord.
    private static func isNoChord(_ s: String) -> Bool {
        let letters = s.uppercased().filter { $0 != "." && $0 != "(" && $0 != ")" }
        return letters == "NC"
    }

    /// "x2", "2x", "(x4)", "×3".
    private static func isRepeat(_ s: String) -> Bool {
        let t = s.lowercased().filter { $0 != "(" && $0 != ")" }.replacingOccurrences(of: "×", with: "x")
        let digits = t.filter { $0 >= "0" && $0 <= "9" }
        guard !digits.isEmpty, digits.count == t.count - 1 else { return false }
        return t.hasPrefix("x") || t.hasSuffix("x")
    }

    private static let sectionWords: Set<String> = [
        "verse", "chorus", "prechorus", "pre-chorus", "pre", "postchorus", "post-chorus", "post", "bridge", "intro",
        "outro", "interlude", "instrumental", "solo", "refrain", "hook", "coda", "tag", "ending", "end", "break",
        "breakdown", "riff", "repeat", "guitar", "piano", "middle",
    ]
    private static let headerWords: Set<String> = ["capo", "tuning", "key", "tempo", "bpm"]

    /// "Verse 1", "Pre-Chorus", "Chorus x2", "Repeat chorus", "Middle 8", optionally with a colon.
    private static func isSection(_ s: String) -> Bool {
        let cleaned = s.lowercased().map { "()[]:".contains($0) ? " " : $0 }
        var named = false
        var count = 0
        for token in String(cleaned).split(separator: " ") {
            let t = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            count += 1
            if sectionWords.contains(t) {
                named = true
            } else if !(isRepeat(t) || isOrdinal(t)) {
                return false
            }
        }
        return named && count <= 5
    }

    /// "1", "2", "ii".
    private static func isOrdinal(_ s: String) -> Bool {
        if !s.isEmpty && s.allSatisfy({ $0 >= "0" && $0 <= "9" }) { return true }
        return ["i", "ii", "iii", "iv", "v", "vi"].contains(s)
    }

    /// A line to skip: "[Chorus]", "Verse 1:", "(Bridge)", "(x2)", "Capo 2", "Tuning: standard", "Key: G".
    private static func isHeading(_ line: String) -> Bool {
        if line.hasPrefix("["), line.hasSuffix("]") {
            let inner = String(line.dropFirst().dropLast())
            if !inner.contains("[") && !inner.contains("]") {
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                return ChordSpelling.parse(trimmed) == nil && !isNoChord(trimmed)
            }
        }
        if line.hasPrefix("("), line.hasSuffix(")") {
            let inner = String(line.dropFirst().dropLast())
            if isSection(inner) || isRepeat(inner.trimmingCharacters(in: .whitespaces)) { return true }
        }
        if isSection(line) { return true }
        let lower = line.lowercased()
        if let first = lower.split(whereSeparator: { !$0.isLetter }).first, first == "capo" { return true }
        if let colon = lower.firstIndex(of: ":") {
            return headerWords.contains(lower[..<colon].trimmingCharacters(in: .whitespaces))
        }
        return false
    }
}
