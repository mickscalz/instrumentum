import Foundation

/// Where recordings go (Recorder spec §3): `~/Music/In Strum Meants/Recordings/YYYY-MM-DD HH.mm — <name>/`, holding the
/// stems, `session.json` and the mix. An unsaved recording lives in a working folder of its own under `temporary`, and
/// Save moves it into `directory` under the first free name (the second in a minute is "… 2"). Nothing is written until
/// a working folder is asked for, which is when Record is pressed.
public struct RecordingStore {
    /// `~/Music/In Strum Meants/Recordings`.
    public static var defaultDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("In Strum Meants", isDirectory: true).appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Recording refuses to start with less than this free (2 GB, as the Finder counts).
    public static let minimumFreeBytesToStart: Int64 = 2_000_000_000
    /// Recording stops, and keeps what it has, with less than this free (500 MB).
    public static let minimumFreeBytesToKeepGoing: Int64 = 500_000_000
    /// The session's file in its folder.
    public static let sessionFileName = "session.json"

    public let directory: URL
    public let temporary: URL

    public init(directory: URL, temporary: URL) {
        self.directory = directory
        self.temporary = temporary
    }

    /// "2026-11-16 21.07 — Moonlit Lake": the minute it was saved, in `timeZone`, and the name, with the characters a
    /// file name can't hold (/ and :) as hyphens, exactly as Keep That names a take; "Recording" for a blank name.
    public static func folderName(title: String, date: Date, timeZone: TimeZone) -> String {
        let blank = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return TakeStore.fileStem(title: blank ? "Recording" : title, date: date, timeZone: timeZone)
    }

    /// Makes a new, empty working folder of its own under `temporary` (and `temporary` itself if need be).
    public func newWorkingFolder() throws -> URL {
        let folder = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The session as it is saved: readable JSON with its keys in order.
    public static func encode(_ session: RecordingSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }

    /// Writes `session.json` into the folder, atomically.
    public func writeSession(_ s: RecordingSession, in folder: URL) throws {
        let data = try Self.encode(s)
        try data.write(to: folder.appendingPathComponent(Self.sessionFileName, isDirectory: false), options: .atomic)
    }

    /// Reads the folder's `session.json`. Keys this build doesn't know are ignored; a missing optional key reads as its
    /// default.
    public func readSession(in folder: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.sessionFileName, isDirectory: false))
        return try JSONDecoder().decode(RecordingSession.self, from: data)
    }

    /// Moves the working folder into `directory` (made if need be) under the first free name, and returns where it is
    /// now. A folder already in `directory` (a saved recording reopened) stays where it is.
    @discardableResult
    public func save(workingFolder: URL, title: String, at date: Date, timeZone: TimeZone = .current) throws -> URL {
        if Self.isDirectlyInside(workingFolder, directory) { return workingFolder }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = Self.folderName(title: title, date: date, timeZone: timeZone)
        var n = 1
        var name = stem
        while fm.fileExists(atPath: directory.appendingPathComponent(name, isDirectory: true).path) {
            n += 1
            name = "\(stem) \(n)"
        }
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        try fm.moveItem(at: workingFolder, to: destination)
        return destination
    }

    /// Deletes a working folder and everything in it. Only ever one under `temporary`: a saved recording is left alone.
    public func discard(workingFolder: URL) {
        guard Self.isDirectlyInside(workingFolder, temporary) else { return }
        try? FileManager.default.removeItem(at: workingFolder)
    }

    /// True with at least 2 GB free.
    public static func diskAllows(start freeBytes: Int64) -> Bool { freeBytes >= minimumFreeBytesToStart }

    /// True with less than 500 MB free.
    public static func diskMustStop(_ freeBytes: Int64) -> Bool { freeBytes < minimumFreeBytesToKeepGoing }

    /// True when `item`'s parent is `folder`, comparing real paths (so `/var` and `/private/var` agree).
    private static func isDirectlyInside(_ item: URL, _ folder: URL) -> Bool {
        let parent = item.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return parent == target
    }
}
