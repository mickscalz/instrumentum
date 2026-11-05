/// The song that inspired a sound. Words and a link only: never artwork or lyrics.
public struct Credit: Codable, Equatable, Identifiable {
    public let id: String
    public let song, artist, album: String
    public let year: Int
    public let trackNumber: Int
    public let key: String
    public let tempoBPM: Double
    /// What inspired us, in one line.
    public let line: String

    public init(id: String, song: String, artist: String, album: String, year: Int, trackNumber: Int, key: String, tempoBPM: Double, line: String) {
        self.id = id; self.song = song; self.artist = artist; self.album = album; self.year = year
        self.trackNumber = trackNumber; self.key = key; self.tempoBPM = tempoBPM; self.line = line
    }
}

/// Facts from docs/superpowers/briefs (with sources there).
public enum CreditLibrary {
    public static let comeBackToEarth = Credit(id: "come-back-to-earth", song: "Come Back to Earth", artist: "Mac Miller",
                                               album: "Swimming", year: 2018, trackNumber: 1, key: "D", tempoBPM: 84,
                                               line: "The soft, floating keys that open Swimming.")
    public static let innerbloom = Credit(id: "innerbloom", song: "Innerbloom", artist: "RÜFÜS DU SOL",
                                          album: "Bloom", year: 2016, trackNumber: 11, key: "E♭ major", tempoBPM: 122,
                                          line: "The slow-blooming, hypnotic synth that opens Innerbloom.")
    public static let musicToWatchBoysTo = Credit(id: "music-to-watch-boys-to", song: "Music to Watch Boys To", artist: "Lana Del Rey",
                                                  album: "Honeymoon", year: 2015, trackNumber: 2, key: "C♯ minor", tempoBPM: 132,
                                                  line: "The hazy, flute-like synths that drift through it.")
    public static let highByTheBeach = Credit(id: "high-by-the-beach", song: "High by the Beach", artist: "Lana Del Rey",
                                              album: "Honeymoon", year: 2015, trackNumber: 5, key: "B minor", tempoBPM: 132,
                                              line: "Its dreamy synth bells and airy organ, from a song born on drives along the coast.")
    public static let stay = Credit(id: "stay", song: "Stay", artist: "Mac Miller",
                                    album: "The Divine Feminine", year: 2016, trackNumber: 3, key: "F♯ major", tempoBPM: 134,
                                    line: "The warm, slow glow of its keys and Keyon Harrold's mellow trumpet.")
    public static let dunno = Credit(id: "dunno", song: "Dunno", artist: "Mac Miller",
                                     album: "Swimming", year: 2018, trackNumber: 10, key: "C♯ major", tempoBPM: 82,
                                     line: "Its beautiful synths that slowly build into a wall of calm.")
    public static let wings = Credit(id: "wings", song: "Wings", artist: "Mac Miller",
                                     album: "Swimming", year: 2018, trackNumber: 6, key: "A♭ major", tempoBPM: 119,
                                     line: "The airy synth pads that lift and keep lifting.")
    public static let happinessIsAButterfly = Credit(id: "happiness-is-a-butterfly", song: "Happiness Is a Butterfly",
                                                     artist: "Lana Del Rey", album: "Norman Fucking Rockwell!", year: 2019,
                                                     trackNumber: 13, key: "D major", tempoBPM: 68,
                                                     line: "Its soft, bell-like keys and the slow haze they drift in.")
    /// "Runaway" (Storms spec §2, §12; brief single-note-grand.md). Credits carry only verified facts: its place on the
    /// album, track 9, is one; its key is disputed, so it states none (the card's liner notes read "TRACK 9 · 86 BPM").
    /// The card breathes at the felt pulse, 86.
    public static let runaway = Credit(id: "runaway", song: "Runaway", artist: "Kanye West",
                                       album: "My Beautiful Dark Twisted Fantasy", year: 2010, trackNumber: 9, key: "",
                                       tempoBPM: 86, line: "One piano note, repeated, and a voice that arrives distorted.")
    public static let underwater = Credit(id: "underwater", song: "Underwater", artist: "RÜFÜS DU SOL",
                                          album: "Solace", year: 2018, trackNumber: 7, key: "F♯ minor", tempoBPM: 118,
                                          line: "The blinking, echoing arp that starts it, murky as deep water.")
    public static let all: [Credit] = [comeBackToEarth, innerbloom, musicToWatchBoysTo, highByTheBeach, stay, dunno, wings,
                                       happinessIsAButterfly, underwater, runaway]

    public static func credit(id: String) -> Credit? { all.first { $0.id == id } }
}

public extension Patch {
    /// The preset name, carrying its credit: `Felt Glass · after "Come Back to Earth"`.
    var displayName: String {
        guard let id = creditID, let credit = CreditLibrary.credit(id: id) else { return name }
        return "\(name) · after \"\(credit.song)\""
    }

    var credit: Credit? { creditID.flatMap { CreditLibrary.credit(id: $0) } }
}
