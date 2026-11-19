import Foundation

/// The Song Sheet's shared types (docs/superpowers/specs/2026-11-19-lyrics-and-chords.md). Stored properties are fixed:
/// the tasks that build on them add behaviour in extensions.

/// A chord as the sheet shows it: a root (0 = C … 11 = B) and a quality.
public struct Chord: Codable, Hashable, Sendable {
    public enum Quality: String, Codable, CaseIterable, Sendable { case major, minor, dominant7, major7, minor7 }
    public var root: Int
    public var quality: Quality
    public init(root: Int, quality: Quality) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
    }
}

/// A chord at a time in the song, in seconds from its start.
public struct ChordEvent: Codable, Equatable, Sendable {
    public var time: Double
    public var chord: Chord
    public init(time: Double, chord: Chord) {
        self.time = time
        self.chord = chord
    }
}

/// One word of a lyric line; `time` is nil unless the lyrics carry word timing.
public struct LyricWord: Codable, Equatable, Sendable {
    public var text: String
    public var time: Double?
    public init(text: String, time: Double? = nil) {
        self.text = text
        self.time = time
    }
}

/// One line of lyrics. `time` is its start in seconds, or -1 when the lyrics are not synced.
public struct LyricLine: Codable, Equatable, Sendable {
    public var time: Double
    public var words: [LyricWord]
    public init(time: Double, words: [LyricWord]) {
        self.time = time
        self.words = words
    }
    /// The line as text.
    public var text: String { words.map(\.text).joined(separator: " ") }
    /// True for an instrumental gap (shown as "♪").
    public var isGap: Bool { words.isEmpty }
}

/// What is playing, as Spotify reports it.
public struct NowPlaying: Codable, Equatable, Sendable {
    /// Spotify's track id ("spotify:track:…" or the bare id); nil for a local file or a podcast.
    public var id: String?
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds.
    public var duration: Double
    /// Seconds into the song when this was read.
    public var position: Double
    public var isPlaying: Bool
    public init(id: String?, title: String, artist: String, album: String, duration: Double, position: Double, isPlaying: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.isPlaying = isPlaying
    }
}

/// Where a song's chords came from.
public enum ChordSource: String, Codable, Sendable { case listened, pasted }

/// Everything kept for one song on this Mac: its lyrics as fetched, the sync nudge, chords and the player's own fixes.
public struct SongFile: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var lines: [LyricLine]
    /// Seconds added to the lyrics' times (−5…+5).
    public var offset: Double
    public var listened: [ChordEvent]
    public var pasted: [ChordEvent]
    /// The player's fixes: a chord at a time replaces any other within 0.25 s; a nil chord removes one.
    public var fixes: [SongFix]
    public var prefersFlats: Bool?
    public init(id: String, title: String, artist: String, lines: [LyricLine] = [], offset: Double = 0,
                listened: [ChordEvent] = [], pasted: [ChordEvent] = [], fixes: [SongFix] = [], prefersFlats: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.lines = lines
        self.offset = offset
        self.listened = listened
        self.pasted = pasted
        self.fixes = fixes
        self.prefersFlats = prefersFlats
    }
}

/// One fix by the player: put `chord` at `time`, or remove whatever is there when `chord` is nil.
public struct SongFix: Codable, Equatable, Sendable {
    public var time: Double
    public var chord: Chord?
    public init(time: Double, chord: Chord?) {
        self.time = time
        self.chord = chord
    }
}
