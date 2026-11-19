import Foundation

/// Lyrics in LRC form (Song Sheet spec §3): `[mm:ss.xx] text` lines; several time tags at the start of a line for a
/// line sung more than once; `<mm:ss.xx>` tags inside a line where the lyrics carry word timing. A line with a time and
/// no words (or only "♪") is an instrumental gap. Lines without a leading time tag (metadata such as `[ar:…]`, blank
/// lines, anything else) are skipped.
public enum LRCParser {
    /// Synced lyrics, in time order (lines with equal times keep their order in the file).
    public static func parse(_ lrc: String) -> [LyricLine] {
        var timed: [(time: Double, order: Int, line: LyricLine)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while true {
                let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { break }
                guard let t = time(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) else { break }
                times.append(t)
                rest = trimmed[trimmed.index(after: close)...]
            }
            guard let first = times.first else { continue }
            let words = self.words(rest)
            for t in times {
                // A repeated line's word tags are timed for its first showing: shift them to each later one.
                var shifted = words
                for k in shifted.indices {
                    if let wt = shifted[k].time { shifted[k].time = wt + (t - first) }
                }
                timed.append((time: t, order: timed.count, line: LyricLine(time: t, words: shifted)))
            }
        }
        timed.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.order < b.order
        }
        var lines: [LyricLine] = []
        for entry in timed { lines.append(entry.line) }
        return lines
    }

    /// Plain (unsynced) lyrics: one line per non-blank line of text, each with time -1.
    public static func plain(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var words: [LyricWord] = []
            for token in raw.split(whereSeparator: { $0.isWhitespace }) {
                words.append(LyricWord(text: String(token)))
            }
            if !words.isEmpty { lines.append(LyricLine(time: -1, words: words)) }
        }
        return lines
    }

    /// "01:02.5" → 62.5. Minutes are any run of digits; seconds one or two digits below 60; then an optional fraction
    /// of one to three digits after "." (or ":", which some files use).
    static func time(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = digits(parts[0]) else { return nil }
        var secondsPart = parts[1]
        var fractionPart: Substring? = parts.count == 3 ? parts[2] : nil
        if fractionPart == nil, let dot = secondsPart.firstIndex(of: ".") {
            fractionPart = secondsPart[secondsPart.index(after: dot)...]
            secondsPart = secondsPart[..<dot]
        }
        guard secondsPart.count <= 2, let seconds = digits(secondsPart), seconds < 60 else { return nil }
        var value = Double(minutes * 60 + seconds)
        if let f = fractionPart {
            guard f.count <= 3, let fraction = digits(f) else { return nil }
            value += Double(fraction) / pow(10, Double(f.count))
        }
        return value
    }

    /// A non-empty run of ASCII digits as a number.
    private static func digits(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 9, s.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(s)
    }

    /// The words of a line's text, each with the time of the `<mm:ss.xx>` tag just before it where there is one.
    /// A tag inside a word (syllable timing) times nothing until the next word that has no tag of its own.
    static func words(_ text: Substring) -> [LyricWord] {
        var words: [LyricWord] = []
        var current = ""
        var currentTime: Double?
        var pending: Double?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "<", let close = text[i...].firstIndex(of: ">"), let t = time(text[text.index(after: i)..<close]) {
                pending = t
                i = text.index(after: close)
                continue
            }
            if c.isWhitespace {
                if !current.isEmpty {
                    words.append(LyricWord(text: current, time: currentTime))
                    current = ""
                    currentTime = nil
                }
            } else {
                if current.isEmpty {
                    currentTime = pending
                    pending = nil
                }
                current.append(c)
            }
            i = text.index(after: i)
        }
        if !current.isEmpty { words.append(LyricWord(text: current, time: currentTime)) }
        // A line of only "♪" is a gap, the same as an empty one.
        if words.allSatisfy({ isMusicSign($0.text) }) { return [] }
        return words
    }

    private static func isMusicSign(_ word: String) -> Bool {
        word.allSatisfy { "♪♫♬♩🎵🎶".contains($0) }
    }
}
