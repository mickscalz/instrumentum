import Foundation

/// Where each song's sheet is kept (Song Sheet spec §3): `~/Library/Application Support/In Strum Meants/Songs/<id>.json`,
/// one readable JSON file per song with its lyrics as fetched, the sync nudge, the chords and the player's fixes.
/// Nothing is written until a save, and the folder is made on the first.
public struct SongStore {
    /// `~/Library/Application Support/In Strum Meants/Songs`.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return support.appendingPathComponent("In Strum Meants", isDirectory: true).appendingPathComponent("Songs", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// A song's file name. Spotify's "spotify:track:<id>" and the bare "<id>" (AppleScript and the Web API give one each)
    /// name the same file. Anything but letters, digits, "-", "_" and "." (and a leading ".") is written as %XX, so ids
    /// with ":" or "/" make safe names and two ids never share one.
    public static func fileName(for id: String) -> String {
        let prefix = "spotify:track:"
        let key = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        let hex = Array("0123456789ABCDEF")
        var name = ""
        for byte in key.utf8 {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isMark = byte == 0x2D || byte == 0x5F || (byte == 0x2E && !name.isEmpty)
            if isLetter || isDigit || isMark {
                name.append(Character(Unicode.Scalar(byte)))
            } else {
                name.append("%")
                name.append(hex[Int(byte >> 4)])
                name.append(hex[Int(byte & 0x0F)])
            }
        }
        if name.isEmpty { name = "%" }
        // Very long ids keep a readable start and a checksum of the whole, inside the file system's 255 bytes.
        if name.utf8.count > 200 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            name = String(name.prefix(150)) + "-" + String(hash, radix: 16)
        }
        return name + ".json"
    }

    /// The song's file, or nil when there is none or it can't be read.
    public func load(_ id: String) -> SongFile? {
        guard let data = try? Data(contentsOf: url(for: id)),
              var file = try? JSONDecoder().decode(SongFile.self, from: data) else { return nil }
        if file.id.isEmpty { file.id = id }
        return file
    }

    /// Makes the folder if need be and writes the song's file (atomically) under `fileName(for: file.id)`.
    public func save(_ file: SongFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: file.id), options: .atomic)
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: id), isDirectory: false)
    }
}

extension SongFile {
    private enum StoredKeys: String, CodingKey {
        case id, title, artist, lines, offset, listened, pasted, fixes, prefersFlats
    }

    /// Older or partly unreadable song files load: each field missing or unreadable takes the initialiser's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StoredKeys.self)
        self.init(id: (try? c.decodeIfPresent(String.self, forKey: .id)) ?? "",
                  title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
                  artist: (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? "")
        lines = (try? c.decodeIfPresent([LyricLine].self, forKey: .lines)) ?? []
        offset = (try? c.decodeIfPresent(Double.self, forKey: .offset)) ?? 0
        listened = (try? c.decodeIfPresent([ChordEvent].self, forKey: .listened)) ?? []
        pasted = (try? c.decodeIfPresent([ChordEvent].self, forKey: .pasted)) ?? []
        fixes = (try? c.decodeIfPresent([SongFix].self, forKey: .fixes)) ?? []
        prefersFlats = (try? c.decodeIfPresent(Bool.self, forKey: .prefersFlats)) ?? nil
    }
}
