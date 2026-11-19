import Foundation

/// Puts a pasted chord sheet's chords on the synced lyrics (Song Sheet spec §4). Each sheet line is matched to a lyric
/// line by its words, ignoring case and punctuation: two lines match when their word sets are at least 60% alike
/// (twice the shared words over the two sets' sizes). Matching goes in order first (the best set of matches that keeps
/// the sheet's order); then every lyric line still without a match takes the most alike sheet line anywhere, so a
/// chorus written once is matched each time it is sung. Each chord goes on its word's time (`ChordPlacement.wordTimes`);
/// a sheet word missing from the lyric line goes by its neighbours. The times are the lyrics' own, before any sync
/// nudge. Unsynced lines (time -1) are matched but give no chords.
public enum ChordSheetAligner {
    /// How alike two lines' word sets must be, in thousandths.
    static let threshold = 600

    public static func align(_ sheet: [SheetLine], to lines: [LyricLine]) -> (chords: [ChordEvent], unmatched: [Int]) {
        var sheetTokens: [[String]] = []
        for s in sheet {
            var tokens: [String] = []
            for w in s.text.split(whereSeparator: { $0.isWhitespace }) { tokens.append(normalised(String(w))) }
            sheetTokens.append(tokens)
        }
        var lyricTokens: [[String]] = []
        for line in lines {
            var tokens: [String] = []
            for w in line.words { tokens.append(normalised(w.text)) }
            lyricTokens.append(tokens)
        }
        let n = sheet.count
        let m = lines.count
        var similar = Array(repeating: Array(repeating: 0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m { similar[i][j] = similarity(sheetTokens[i], lyricTokens[j]) }
        }

        // In order: the matches that keep the sheet's order with the most likeness in all, as early in the song as can be.
        var score = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                var best = max(score[i][j + 1], score[i + 1][j])
                if similar[i][j] >= threshold { best = max(best, score[i][j] + similar[i][j]) }
                score[i + 1][j + 1] = best
            }
        }
        var sheetFor = Array(repeating: -1, count: m)   // lyric line → sheet line
        var row = n
        var column = m
        while row > 0 && column > 0 {
            if score[row][column] == score[row][column - 1] {
                column -= 1
            } else if similar[row - 1][column - 1] >= threshold
                        && score[row][column] == score[row - 1][column - 1] + similar[row - 1][column - 1] {
                sheetFor[column - 1] = row - 1
                row -= 1
                column -= 1
            } else {
                row -= 1
            }
        }

        // Then repeats: a lyric line still without a match takes the most alike sheet line, wherever it is.
        for line in 0..<m where sheetFor[line] < 0 {
            var best = -1
            var bestScore = threshold - 1
            for s in 0..<n where similar[s][line] > bestScore {
                best = s
                bestScore = similar[s][line]
            }
            sheetFor[line] = best
        }

        var used = Array(repeating: false, count: n)
        var events: [(time: Double, order: Int, chord: Chord)] = []
        for line in 0..<m where sheetFor[line] >= 0 {
            let s = sheetFor[line]
            used[s] = true
            guard lines[line].time >= 0, !sheet[s].chords.isEmpty else { continue }
            let times = ChordPlacement.wordTimes(lines[line], nextStart: line + 1 < m ? lines[line + 1].time : nil)
            guard !times.isEmpty else { continue }
            let map = wordMap(sheetTokens[s], lyricTokens[line])
            for c in sheet[s].chords {
                let sheetWord = min(max(c.wordIndex, 0), max(sheetTokens[s].count - 1, 0))
                let word = sheetWord < map.count ? map[sheetWord] : times.count - 1
                let time = times[min(max(word, 0), times.count - 1)]
                events.append((time: time, order: events.count, chord: c.chord))
            }
        }
        events.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.order < b.order
        }
        // Chords landing on the same moment (a turnaround attached to a line's first word, under the line's own first
        // chord): the last one written is the one sung there.
        var chords: [ChordEvent] = []
        for e in events {
            if let last = chords.last, last.time == e.time { chords.removeLast() }
            chords.append(ChordEvent(time: e.time, chord: e.chord))
        }
        var unmatched: [Int] = []
        for s in 0..<n where !used[s] { unmatched.append(s) }
        return (chords: chords, unmatched: unmatched)
    }

    /// A word as it is compared: lower case, letters and digits only ("Don't," → "dont").
    static func normalised(_ word: String) -> String {
        var out = ""
        for c in word.lowercased() where c.isLetter || c.isNumber { out.append(c) }
        return out
    }

    /// How alike two lines' word sets are, in thousandths: twice the shared words over the two sets' sizes.
    static func similarity(_ a: [String], _ b: [String]) -> Int {
        var setA = Set(a)
        var setB = Set(b)
        setA.remove("")
        setB.remove("")
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let shared = setA.intersection(setB).count
        return 2 * shared * 1000 / (setA.count + setB.count)
    }

    /// For each sheet word, the lyric word it is: the same word where the two lines share it (in order), otherwise the
    /// word as far from its nearest shared neighbour as it is in the sheet.
    static func wordMap(_ sheet: [String], _ lyric: [String]) -> [Int] {
        let p = sheet.count
        let q = lyric.count
        guard p > 0, q > 0 else { return Array(repeating: 0, count: p) }
        // The longest run of shared words in order.
        var common = Array(repeating: Array(repeating: 0, count: q + 1), count: p + 1)
        for a in stride(from: p - 1, through: 0, by: -1) {
            for b in stride(from: q - 1, through: 0, by: -1) {
                if !sheet[a].isEmpty && sheet[a] == lyric[b] {
                    common[a][b] = common[a + 1][b + 1] + 1
                } else {
                    common[a][b] = max(common[a + 1][b], common[a][b + 1])
                }
            }
        }
        var matched = Array(repeating: -1, count: p)
        var x = 0
        var y = 0
        while x < p && y < q {
            if !sheet[x].isEmpty && sheet[x] == lyric[y] && common[x][y] == common[x + 1][y + 1] + 1 {
                matched[x] = y
                x += 1
                y += 1
            } else if common[x + 1][y] >= common[x][y + 1] {
                x += 1
            } else {
                y += 1
            }
        }
        var map = Array(repeating: 0, count: p)
        for k in 0..<p {
            if matched[k] >= 0 {
                map[k] = matched[k]
                continue
            }
            var guess: Int?
            if let before = (0..<k).last(where: { matched[$0] >= 0 }) {
                guess = matched[before] + (k - before)
            } else if let after = ((k + 1)..<p).first(where: { matched[$0] >= 0 }) {
                guess = matched[after] - (after - k)
            }
            let fallback = p > 1 ? Int((Double(k) * Double(q - 1) / Double(p - 1)).rounded()) : 0
            map[k] = min(max(guess ?? fallback, 0), q - 1)
        }
        return map
    }
}
