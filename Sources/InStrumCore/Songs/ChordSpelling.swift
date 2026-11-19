import Foundation

/// Chord names (Song Sheet spec §4): spelling with sharps or flats, reading a chord name typed or pasted from anywhere,
/// and transposing. Names use plain "#" and "b" ("F#m7", "Bbmaj7") so a name reads back as the same chord.
public enum ChordSpelling {
    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// "Am", "F#m7", "Bbmaj7", "C7", "G".
    public static func name(_ c: Chord, flats: Bool) -> String {
        let root = ((c.root % 12) + 12) % 12
        return (flats ? flatNames : sharpNames)[root] + suffix(c.quality)
    }

    /// The quality's part of a name: "" for major, "m", "7", "maj7", "m7".
    static func suffix(_ q: Chord.Quality) -> String {
        switch q {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        }
    }

    /// Reads a chord name: a root A–G (capital), an optional ♯ or ♭ ("#", "b", "♯", "♭"), a quality, then any
    /// extensions and a bass note, which come out as the nearest simple chord: "C/G" is C, "Dsus4" is D, "Am7b5" is Am7,
    /// "Cadd9" is C, "G13" is G7. Anything else (a word such as "Hello" or "Bed") is nil.
    public static func parse(_ s: String) -> Chord? {
        let chars = Array(s.trimmingCharacters(in: .whitespaces))
        guard let first = chars.first, let letter = letterValue(first) else { return nil }
        var root = letter
        var i = 1
        if i < chars.count, let shift = accidental(chars[i]) {
            root += shift
            i += 1
        }
        var rest = String(chars[i...])
        // A bass note after a slash is dropped (and "6/9" is a sixth).
        if let slash = rest.lastIndex(of: "/") {
            let bass = rest[rest.index(after: slash)...]
            guard isNote(bass) || isNumber(bass) else { return nil }
            rest = String(rest[..<slash])
        }
        var quality = Chord.Quality.major
        for (spelling, q) in qualities where rest.hasPrefix(spelling) {
            quality = q
            rest = String(rest.dropFirst(spelling.count))
            break
        }
        guard isExtension(rest) else { return nil }
        return Chord(root: root, quality: quality)
    }

    /// The same chord `semitones` higher (lower when negative).
    public static func transposed(_ c: Chord, by semitones: Int) -> Chord {
        Chord(root: c.root + semitones, quality: c.quality)
    }

    /// True in the keys usually written with flats: F, B♭, E♭, A♭ and D♭ major; D, G, C, F, B♭ and E♭ minor.
    public static func prefersFlats(keyRoot: Int, minor: Bool) -> Bool {
        let root = ((keyRoot % 12) + 12) % 12
        return minor ? [0, 2, 3, 5, 7, 10].contains(root) : [1, 3, 5, 8, 10].contains(root)
    }

    /// Qualities by how they are written, the longer spellings first where one starts another.
    private static let qualities: [(String, Chord.Quality)] = [
        ("mmaj7", .minor), ("mMaj7", .minor), ("mM7", .minor), ("m(maj7)", .minor), ("minmaj7", .minor),
        ("maj13", .major7), ("maj11", .major7), ("maj9", .major7), ("maj7", .major7), ("Maj7", .major7),
        ("ma7", .major7), ("M7", .major7), ("M9", .major7), ("Δ7", .major7), ("Δ", .major7),
        ("maj", .major), ("Maj", .major),
        ("min13", .minor7), ("min11", .minor7), ("min9", .minor7), ("min7", .minor7), ("mi7", .minor7),
        ("m13", .minor7), ("m11", .minor7), ("m9", .minor7), ("m7", .minor7), ("-7", .minor7), ("ø7", .minor7), ("ø", .minor7),
        ("min", .minor), ("mi", .minor), ("m", .minor), ("-", .minor),
        ("dim7", .minor), ("dim", .minor), ("°7", .minor), ("°", .minor),
        ("aug", .major), ("+", .major),
        ("13", .dominant7), ("11", .dominant7), ("9", .dominant7), ("7", .dominant7),
    ]

    private static func letterValue(_ c: Character) -> Int? {
        switch c {
        case "C": return 0
        case "D": return 2
        case "E": return 4
        case "F": return 5
        case "G": return 7
        case "A": return 9
        case "B": return 11
        default: return nil
        }
    }

    private static func accidental(_ c: Character) -> Int? {
        switch c {
        case "#", "♯": return 1
        case "b", "♭": return -1
        default: return nil
        }
    }

    /// "G", "F#", "Bb".
    private static func isNote(_ s: Substring) -> Bool {
        let chars = Array(s)
        guard let first = chars.first, letterValue(first) != nil else { return false }
        if chars.count == 1 { return true }
        return chars.count == 2 && accidental(chars[1]) != nil
    }

    private static func isNumber(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// What may follow a quality: numbers, "add9", "sus4", "no3", "alt", "b5", "#9", "+5", "-13", brackets and commas.
    private static func isExtension(_ s: String) -> Bool {
        let chars = Array(s)
        var i = 0
        func digitAt(_ k: Int) -> Bool { k < chars.count && chars[k] >= "0" && chars[k] <= "9" }
        func word(_ w: String) -> Bool {
            let letters = Array(w)
            guard i + letters.count <= chars.count else { return false }
            return Array(chars[i..<(i + letters.count)]) == letters
        }
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == ")" || c == "," || digitAt(i) {
                i += 1
            } else if word("add") && digitAt(i + 3) {
                i += 3
            } else if word("sus") {
                i += 3
            } else if word("alt") {
                i += 3
            } else if word("no") && digitAt(i + 2) {
                i += 2
            } else if "b#♭♯+-".contains(c) && digitAt(i + 1) {
                i += 1
            } else {
                return false
            }
        }
        return true
    }
}
