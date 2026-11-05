import SwiftUI
import AppKit
import InStrumCore

/// The living card. A song card ("Inspired by"): original art that breathes at the song's tempo, the song in the card's
/// own type, liner-note micro type (key · track · tempo) and a Listen link. A place card, for a set born from its place
/// rather than a song (no credit): the world's own art breathing at a slow fixed pulse of its own, the set's name and
/// mood instead of the song, artist and album, and no liner notes or Listen. Words and a link only — no artwork, no
/// logos, no lyrics.
struct InspiredByCard: View {
    /// What the card is about: the song that inspired a sound, or the place a set was born from.
    enum Subject: Equatable {
        case song(Credit)
        case place(InStrumSet)
    }

    /// What the card says.
    struct Words: Equatable {
        var kicker: String
        var title: String
        var subtitle: String
        /// What inspired us, in one line (shown on hover); song cards only.
        var line: String?
        /// Key · track · tempo (a key or track a credit doesn't state left out); song cards only.
        var linerNotes: String?
        /// The song the Listen button finds; nil: no Listen button.
        var listen: Credit?
        var accessibility: String
    }

    let subject: Subject
    /// A fixed moment (previews); nil animates while the card is on screen.
    var fixedTime: Double?
    @State private var visible = false
    @State private var showLine = false

    init(credit: Credit, fixedTime: Double? = nil) {
        subject = .song(credit)
        self.fixedTime = fixedTime
    }

    init(place set: InStrumSet, fixedTime: Double? = nil) {
        subject = .place(set)
        self.fixedTime = fixedTime
    }

    var art: CardArt? {
        switch subject {
        case .song(let credit): return CardArt.art(for: credit.id)
        case .place(let set): return CardArt.place(for: set.id)
        }
    }

    /// One breath of the card (seconds): the song's (see `CardArt.pulse(for:)`), or its place's slow fixed pulse (see
    /// `CardArt.placeBreath`).
    var pulse: Double {
        switch subject {
        case .song(let credit): return art?.pulse(for: credit) ?? credit.pulsePeriod
        case .place: return art?.placeBreath ?? CardArt.placePulse
        }
    }

    var words: Words {
        switch subject {
        case .song(let c):
            return Words(kicker: "INSPIRED BY", title: art?.titleCase == true ? c.song.uppercased() : c.song,
                         subtitle: "\(c.artist) · \(c.album) · \(String(c.year))", line: c.line,
                         linerNotes: Self.linerNotes(c), listen: c,
                         accessibility: "Inspired by \(c.song) by \(c.artist), \(c.album), \(String(c.year)). \(c.line)")
        case .place(let s):
            return Words(kicker: "BORN FROM A PLACE", title: s.name, subtitle: s.moodName, line: nil, linerNotes: nil, listen: nil,
                         accessibility: "\(s.name), born from a place. \(s.moodName).")
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            canvas
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(words.kicker).font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.white.opacity(0.7))
                Text(words.title)
                    .font(art?.titleFont ?? .title2).tracking(art?.titleTracking ?? 0)
                    .foregroundStyle(.white)
                Text(words.subtitle)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                if let line = words.line {
                    Text(line)
                        .font(.system(size: 12).italic()).foregroundStyle(.white.opacity(0.85))
                        .opacity(showLine || fixedTime != nil ? 1 : 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            if let notes = words.linerNotes {
                Text(notes)
                    .font(.system(size: 9, weight: .medium).monospacedDigit()).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let credit = words.listen {
                Button { Self.listen(to: credit) } label: {
                    Label("Listen", systemImage: "play.circle.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Find “\(credit.song)” on Spotify")
                .padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .aspectRatio(5.0 / 3.0, contentMode: .fit)
        .onHover { inside in withAnimation(.easeInOut(duration: 1.2)) { showLine = inside } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words.accessibility)
    }

    @ViewBuilder
    private var canvas: some View {
        let art = self.art
        let pulse = self.pulse
        if let t = fixedTime {
            Canvas { ctx, size in art?.draw(in: ctx, size: size, t: t, pulse: pulse) }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible)) { tl in
                Canvas { ctx, size in art?.draw(in: ctx, size: size, t: tl.date.timeIntervalSinceReferenceDate, pulse: pulse) }
            }
        }
    }

    /// Key · track · tempo, as the card's top corner sets them: `F♯ minor · TRACK 7 · 118 BPM`. A key or a track number
    /// the credit doesn't state (not yet heard, or not verified) is left out: "FADE" reads `124 BPM`.
    static func linerNotes(_ c: Credit) -> String {
        let track: String = c.trackNumber.map { "TRACK \($0)" } ?? ""
        let notes: [String] = [c.key, track, "\(Int(c.tempoBPM.rounded())) BPM"]
        return notes.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Opens the Spotify app's search, or the web search when the app isn't installed.
    static func listen(to credit: Credit) {
        let app = ListenLink.spotifyApp(for: credit)
        if NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(ListenLink.spotifyWeb(for: credit))
        }
    }
}
