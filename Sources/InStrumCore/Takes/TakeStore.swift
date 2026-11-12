import Foundation

/// Where kept takes go (Small Wins spec §2): `~/Music/In Strum Meants/Takes/YYYY-MM-DD HH.mm — <name>.mid`, with its
/// note beside it as `.json`. Nothing is written until a keep, the folder is made on the first, and a keep never
/// overwrites another (the second in a minute is "… 2").
public struct TakeStore {
    /// `~/Music/In Strum Meants/Takes`.
    public static var defaultDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("In Strum Meants", isDirectory: true).appendingPathComponent("Takes", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// "2026-11-04 21.07 — Moonlit Lake": the minute it was kept, in `timeZone`, and the name, with the characters a
    /// file name can't hold (/ and :) as hyphens.
    public static func fileStem(title: String, date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        var name = String(title.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        name = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return "\(stamp) — \(name.isEmpty ? "Take" : name)"
    }

    /// The note as it is saved: readable JSON with its keys in order.
    public static func encode(_ note: TakeNote) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(note)
    }

    /// Makes the folder if need be, then writes the `.mid` and the `.json` (each atomically) under the first free name.
    /// Returns the `.mid`'s URL.
    @discardableResult
    public func save(midi: Data, note: TakeNote, title: String, at date: Date, timeZone: TimeZone = .current) throws -> URL {
        let json = try Self.encode(note)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = Self.fileStem(title: title, date: date, timeZone: timeZone)
        var n = 1
        var name = stem
        while FileManager.default.fileExists(atPath: url(name, "mid").path) || FileManager.default.fileExists(atPath: url(name, "json").path) {
            n += 1
            name = "\(stem) \(n)"
        }
        let mid = url(name, "mid")
        try midi.write(to: mid, options: .atomic)
        try json.write(to: url(name, "json"), options: .atomic)
        return mid
    }

    private func url(_ name: String, _ ext: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false).appendingPathExtension(ext)
    }
}
