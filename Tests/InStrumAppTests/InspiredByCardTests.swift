import XCTest
import SwiftUI
@testable import InStrumApp
@testable import InStrumCore

/// The living "Inspired by" cards.
@MainActor
final class InspiredByCardTests: XCTestCase {
    func testEveryCreditHasArt() {
        for c in CreditLibrary.all { XCTAssertNotNil(CardArt.art(for: c.id), c.id) }
        XCTAssertNil(CardArt.art(for: "not-a-credit"))
        XCTAssertNotEqual(CardArt.art(for: CreditLibrary.comeBackToEarth.id), CardArt.art(for: CreditLibrary.innerbloom.id))
    }

    func testEverySetHasItsOwnCardColours() {
        XCTAssertEqual(SetLibrary.all.count, 12)
        let fallback = SetsGallery.tint(for: "no-such-set")
        var seen: [[Color]] = []
        for set in SetLibrary.all {
            let tint = SetsGallery.tint(for: set.id)
            XCTAssertNotEqual(tint, fallback, "\(set.id) falls back to grey")
            XCTAssertFalse(seen.contains(tint), "\(set.id) shares another set's colours")
            seen.append(tint)
        }
        // The still places (spec §11): the tea room's shadow to its lit paper; the moss's shade to the raked gravel.
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.teaHouseSnow.id),
                       [Color(red: 0.10, green: 0.09, blue: 0.11), Color(red: 0.86, green: 0.80, blue: 0.70)])
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.zenRockGarden.id),
                       [Color(red: 0.08, green: 0.10, blue: 0.08), Color(red: 0.78, green: 0.76, blue: 0.66)])
        // The deep water (Sets 11 & 12 spec §11): the cabin's dark to the deep blue outside; the lagoon to the shallows.
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.submarineWindow.id),
                       [Color(red: 0.02, green: 0.05, blue: 0.10), Color(red: 0.10, green: 0.45, blue: 0.62)])
        XCTAssertEqual(SetsGallery.tint(for: SetLibrary.greatBarrierReef.id),
                       [Color(red: 0.05, green: 0.22, blue: 0.30), Color(red: 0.55, green: 0.90, blue: 0.85)])
    }

    /// No two cards look alike.
    func testCardsAreDistinct() throws {
        let images = try CreditLibrary.all.map { try XCTUnwrap(Self.render($0, at: 1.0), $0.id) }
        for i in 0..<images.count {
            for j in (i + 1)..<images.count {
                let d = PreviewRenderer.difference(images[i], images[j])
                if d <= 0.02 { XCTFail("\(CreditLibrary.all[i].id) and \(CreditLibrary.all[j].id) differ by only \(d)") }
            }
        }
    }

    /// Renders a card at a fixed moment (600×360, the card's 5:3).
    static func render(_ c: Credit, at t: Double) -> CGImage? {
        render(InspiredByCard(credit: c, fixedTime: t))
    }

    /// Renders a set's place card at a fixed moment.
    static func render(place set: InStrumSet, at t: Double) -> CGImage? {
        render(InspiredByCard(place: set, fixedTime: t))
    }

    private static func render(_ card: InspiredByCard) -> CGImage? {
        let renderer = ImageRenderer(content: card.frame(width: 600, height: 360))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Every set shows one card: its song's, or (born from its place, no credit) its place card. The submarine shows the
    /// "Underwater" card; the reef its place card.
    func testEverySetHasACardOrPlaceArt() {
        for set in SetLibrary.all {
            if let credit = set.creditID {
                XCTAssertNotNil(CardArt.art(for: credit), "\(set.id) has no song card")
                XCTAssertNil(CardArt.place(for: set.id), "\(set.id) has a song card and a place card")
            } else {
                XCTAssertNotNil(CardArt.place(for: set.id), "\(set.id) has no credit and no place card")
            }
        }
        XCTAssertEqual(SetLibrary.all.compactMap { CardArt.place(for: $0.id) }, [.teaHouseSnow, .zenRockGarden, .greatBarrierReef])
        XCTAssertEqual(SetLibrary.submarineWindow.creditID.flatMap { CardArt.art(for: $0) }, CardArt.underwater)
        XCTAssertNil(CardArt.place(for: SetLibrary.submarineWindow.id), "the submarine has its song's card")
        for c in CreditLibrary.all { XCTAssertFalse(CardArt.art(for: c.id)?.isPlace ?? true, c.id) }
    }

    /// The tea house is born from its place: its card (steam curling over a snow garden seen through a lattice, the koto's
    /// thirteen strings faint along the lower edge) breathes at a slow fixed 60/48 s whatever any song's tempo, names the
    /// set and its mood instead of a song, artist and album, has no liner notes or Listen button, and looks like none of
    /// the song cards.
    func testPlaceCardForTheTeaHouse() throws {
        let art = try XCTUnwrap(CardArt.place(for: "tea-house-snow"))
        XCTAssertTrue(art.isPlace)
        XCTAssertEqual(CardArt.placePulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 48, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(CardArt.teaHouseStrings.count, 13, "the koto's thirteen strings")
        XCTAssertTrue(CardArt.teaHouseStrings.allSatisfy { $0 > 0.85 && $0 < 1 }, "along the lower edge")
        XCTAssertNil(CardArt.place(for: SetLibrary.moonlitLake.id), "a song's set has no place card")
        XCTAssertNil(CardArt.place(for: "no-such-set"))
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        let card = InspiredByCard(place: SetLibrary.teaHouseSnow)
        XCTAssertEqual(card.subject, .place(SetLibrary.teaHouseSnow))
        XCTAssertEqual(card.art, .teaHouseSnow)
        XCTAssertEqual(card.pulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(card.words.title, "Tea House Snow")
        XCTAssertEqual(card.words.subtitle, "Delicate, hushed")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)
        // A song card still names its song and links to it.
        let song = InspiredByCard(credit: CreditLibrary.dunno)
        XCTAssertEqual(song.words.title, "Dunno")
        XCTAssertEqual(song.words.subtitle, "Mac Miller · Swimming · 2018")
        XCTAssertEqual(song.words.listen, CreditLibrary.dunno)
        XCTAssertEqual(song.words.linerNotes, "C♯ major · TRACK 10 · 82 BPM")
        XCTAssertEqual(song.pulse, 60.0 / 82, accuracy: 1e-12)

        // The picture: it draws, it breathes, and it looks like no song card.
        let a = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the tea house card moved only \(moved)") }
        let place = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(place, other)
            if d <= 0.02 { XCTFail("the tea house card and \(c.id) differ by only \(d)") }
        }
    }

    /// The garden is born from its place too: its card (raked circles round five stones in three groups on moss islands, and
    /// the eave's bamboo pole along the top with five rings, the shakuhachi's five holes) breathes at the same slow fixed
    /// 60/48 s, names the set and its mood instead of a song, artist and album, has no liner notes or Listen button, and
    /// looks like none of the song cards, nor like the tea house's.
    func testPlaceCardForTheGarden() throws {
        let art = try XCTUnwrap(CardArt.place(for: "zen-rock-garden"))
        XCTAssertTrue(art.isPlace)
        XCTAssertNotEqual(art, CardArt.place(for: "tea-house-snow"), "each place has its own card")
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 48, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(art.pulse(for: CreditLibrary.dunno), 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(CardArt.rockGardenRings.count, 5, "the shakuhachi's five holes")
        XCTAssertTrue(CardArt.rockGardenRings.allSatisfy { $0 > 0.05 && $0 < 0.95 }, "across the pole")
        XCTAssertLessThan(CardArt.rockGardenPole.upperBound, 0.1, "along the top")
        XCTAssertEqual(CardArt.rockGardenGroups.count, 3, "three groups")
        XCTAssertEqual(CardArt.rockGardenGroups.reduce(0) { $0 + $1.stones.count }, 5, "five stones")
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        let card = InspiredByCard(place: SetLibrary.zenRockGarden)
        XCTAssertEqual(card.subject, .place(SetLibrary.zenRockGarden))
        XCTAssertEqual(card.art, .zenRockGarden)
        XCTAssertEqual(card.pulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(card.words.kicker, "BORN FROM A PLACE")
        XCTAssertEqual(card.words.title, "Zen Rock Garden")
        XCTAssertEqual(card.words.subtitle, "Ordered calm")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)

        // The picture: it draws, it breathes, and it looks like no song card, nor like the tea house's.
        let a = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the garden card moved only \(moved)") }
        let place = try XCTUnwrap(Self.render(place: SetLibrary.zenRockGarden, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(place, other)
            if d <= 0.02 { XCTFail("the garden card and \(c.id) differ by only \(d)") }
        }
        let teaHouse = try XCTUnwrap(Self.render(place: SetLibrary.teaHouseSnow, at: 1.0))
        let fromTea = PreviewRenderer.difference(place, teaHouse)
        if fromTea <= 0.02 { XCTFail("the garden card and the tea house's differ by only \(fromTea)") }
    }

    /// The reef is born from its place: its card (a coral cay's lagoon from the waterline, three coral heads with 1, 4 and
    /// 10 polyps lit, the bar's 1 : 4 : 10 tuning, and a school curving over them) breathes at a fixed 60/52 s whatever any
    /// song's tempo, names the set and its mood with no liner notes or Listen button, draws and moves, and looks like
    /// none of the song cards and none of the other places' cards.
    func testReefPlaceCard() throws {
        let art = try XCTUnwrap(CardArt.place(for: "great-barrier-reef"))
        XCTAssertEqual(art, .greatBarrierReef)
        XCTAssertTrue(art.isPlace)
        XCTAssertNotEqual(art, CardArt.place(for: "tea-house-snow"))
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }
        XCTAssertEqual(CardArt.reefCoralHeads.map { $0.lit }, [1, 4, 10], "the bar's 1 : 4 : 10")
        for head in CardArt.reefCoralHeads { XCTAssertGreaterThanOrEqual(head.polyps, head.lit) }
        XCTAssertEqual(CardArt.reefPulse, 60.0 / 52, accuracy: 1e-12)
        XCTAssertEqual(art.placeBreath, 60.0 / 52, accuracy: 1e-12)
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 52, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(CardArt.teaHouseSnow.placeBreath, 60.0 / 48, accuracy: 1e-12, "the tea house keeps its own")

        let card = InspiredByCard(place: SetLibrary.greatBarrierReef)
        XCTAssertEqual(card.subject, .place(SetLibrary.greatBarrierReef))
        XCTAssertEqual(card.art, .greatBarrierReef)
        XCTAssertEqual(card.pulse, 60.0 / 52, accuracy: 1e-12)
        XCTAssertEqual(InspiredByCard(place: SetLibrary.teaHouseSnow).pulse, 60.0 / 48, accuracy: 1e-12)
        XCTAssertEqual(card.words.kicker, "BORN FROM A PLACE")
        XCTAssertEqual(card.words.title, "Great Barrier Reef")
        XCTAssertEqual(card.words.subtitle, "Colourful, alive")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)

        // The picture: it draws, it breathes, and it looks like no song card and no other place's card (the tea house's,
        // and any other place-born set the library holds).
        let a = try XCTUnwrap(Self.render(place: SetLibrary.greatBarrierReef, at: 0.2))
        let s = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(s.meanLuminance, 0.05)
        XCTAssertGreaterThan(s.variance, 0.001)
        let b = try XCTUnwrap(Self.render(place: SetLibrary.greatBarrierReef, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the reef card moved only \(moved)") }
        let picture = try XCTUnwrap(Self.render(place: SetLibrary.greatBarrierReef, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(picture, other)
            if d <= 0.02 { XCTFail("the reef card and \(c.id) differ by only \(d)") }
        }
        let places = SetLibrary.all.filter { $0.creditID == nil && $0.id != SetLibrary.greatBarrierReef.id }
        XCTAssertEqual(places.map(\.id), ["tea-house-snow", "zen-rock-garden"])
        for place in places {
            let other = try XCTUnwrap(Self.render(place: place, at: 1.0), place.id)
            let d = PreviewRenderer.difference(picture, other)
            if d <= 0.02 { XCTFail("the reef card and \(place.id)'s differ by only \(d)") }
        }
    }

    /// The credit for "Underwater" (spec §11), exactly: words and a link only.
    func testUnderwaterCredit() {
        let c = CreditLibrary.underwater
        XCTAssertEqual(c.id, "underwater")
        XCTAssertEqual(c.song, "Underwater")
        XCTAssertEqual(c.artist, "RÜFÜS DU SOL")
        XCTAssertEqual(c.album, "Solace")
        XCTAssertEqual(c.year, 2018)
        XCTAssertEqual(c.trackNumber, 7)
        XCTAssertEqual(c.key, "F♯ minor")
        XCTAssertEqual(c.tempoBPM, 118)
        XCTAssertEqual(c.line, "The blinking, echoing arp that starts it, murky as deep water.")
        XCTAssertEqual(CreditLibrary.credit(id: "underwater"), c)
        XCTAssertTrue(CreditLibrary.all.contains(c))
        XCTAssertEqual(c.artist, CreditLibrary.innerbloom.artist, "spelled as the band's other credit")
        // The card says it in words: the song, the band, the album and its year, and the liner notes.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "Underwater")
        XCTAssertEqual(card.words.subtitle, "RÜFÜS DU SOL · Solace · 2018")
        XCTAssertEqual(card.words.linerNotes, "F♯ minor · TRACK 7 · 118 BPM")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
    }

    /// The "Underwater" card is original abstract art (nothing from the album art, the lyrics or the short film): a
    /// deep-blue field with three easter eggs. Sonar rings pulse on the song's beat (one leaves the centre every 60/118 s
    /// and the picture repeats exactly once a beat), seven bubbles rise (the track number), and a sweep rests at F♯
    /// (pitch class 6 of 12, opposite C at the top) on a faint twelve-tick dial (the key). The bubbles keep off the
    /// words, and the card looks like no other song card.
    func testUnderwaterCardEasterEggs() throws {
        let credit = CreditLibrary.underwater
        let art = try XCTUnwrap(CardArt.art(for: credit.id))
        XCTAssertEqual(art, .underwater)
        XCTAssertFalse(art.isPlace)
        XCTAssertFalse(art.titleCase)
        // The rings' pulse: 60/118 s, the card's breath.
        let beat = 60.0 / 118
        XCTAssertEqual(art.pulse(for: credit), beat, accuracy: 1e-12)
        XCTAssertEqual(InspiredByCard(credit: credit).pulse, beat, accuracy: 1e-12)
        for t in [0.13, 1.0, 2.4, 7.77] {
            let now = CardArt.sonarRings(at: t, pulse: beat)
            let next = CardArt.sonarRings(at: t + beat, pulse: beat)
            let half = CardArt.sonarRings(at: t + beat / 2, pulse: beat)
            XCTAssertEqual(now.count, 3)
            XCTAssertEqual(next.count, 3)
            XCTAssertEqual(half.count, 3)
            guard now.count == 3, next.count == 3, half.count == 3 else { continue }
            for j in 0..<3 {
                XCTAssertEqual(now[j].radius, next[j].radius, accuracy: 1e-9, "a beat later the rings are where they were (t \(t))")
                XCTAssertEqual(now[j].opacity, next[j].opacity, accuracy: 1e-9)
            }
            XCTAssertGreaterThan(abs(now[0].radius - half[0].radius), 0.1, "half a beat later they have moved on (t \(t))")
        }
        let leaving = CardArt.sonarRings(at: 3 * beat + 1e-6, pulse: beat)   // just after a beat
        XCTAssertLessThan(leaving.first?.radius ?? 1, 0.06, "a ring leaves the centre on the beat")
        XCTAssertGreaterThan(leaving.first?.opacity ?? 0, 0.5)
        XCTAssertTrue(leaving.allSatisfy { $0.radius < 1.5 && $0.opacity >= 0 }, "and fades out as it spreads past the dial")
        // Seven bubbles: the track number.
        XCTAssertEqual(CardArt.underwaterBubbles.count, 7)
        XCTAssertEqual(CardArt.underwaterBubbles.count, credit.trackNumber)
        // The sweep rests at F♯: pitch class 6 of the dial's 12 ticks, C at the top and round clockwise, so it points
        // straight down.
        XCTAssertEqual(CardArt.underwaterDialTicks, 12)
        XCTAssertEqual(CardArt.underwaterSweep, 6)
        XCTAssertTrue(credit.key.hasPrefix("F♯"), "the key's tonic")
        XCTAssertEqual(CardArt.dialAngle(0), -Double.pi / 2, accuracy: 1e-12, "C at the top")
        XCTAssertEqual(CardArt.dialAngle(3), 0, accuracy: 1e-12, "D♯ at the right")
        XCTAssertEqual(CardArt.dialAngle(CardArt.underwaterSweep), Double.pi / 2, accuracy: 1e-12, "F♯ at the bottom")

        // The bubbles keep off the words (the liner notes, the title block and the Listen button), wherever they are in
        // their rise; and the sonar's sweep keeps off them too.
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // F♯ minor · TRACK 7 · 118 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for b in CardArt.underwaterBubbles {
            let r: CGFloat = 1.15 * b.radius   // at the top of its rise
            let span = CGRect(x: b.x * w - 5 - r, y: 0.06 * h - r, width: 10 + 2 * r, height: 0.58 * h + 2 * r)
            for rect in words { XCTAssertFalse(span.intersects(rect), "the bubble at x \(b.x) crosses \(rect)") }
        }
        let sonar = CardArt.underwaterSonar
        let sweep = CGRect(x: sonar.x * w - 1, y: sonar.y * h, width: 2, height: sonar.radius * h + 1)
        for rect in words { XCTAssertFalse(sweep.intersects(rect), "the sweep crosses \(rect)") }

        // The picture: it draws, it moves, and it looks like no other song card.
        let a = try XCTUnwrap(Self.render(credit, at: 0.2))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let b = try XCTUnwrap(Self.render(credit, at: 2.2))
        let moved = PreviewRenderer.difference(a, b)
        if moved <= 0.001 { XCTFail("the Underwater card moved only \(moved)") }
        let mine = try XCTUnwrap(Self.render(credit, at: 1.0))
        for c in CreditLibrary.all where c.id != credit.id {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the Underwater card and \(c.id) differ by only \(d)") }
        }
    }

    /// The credit for "FADE" (Storms spec §2, §12), exactly: words and a link only. Its tempo is the felt pulse, 124,
    /// until Michael taps it; it claims no key until one is heard, so the liner notes leave the key out.
    func testFadeCredit() {
        let c = CreditLibrary.fade
        XCTAssertEqual(c.id, "fade")
        XCTAssertEqual(c.song, "FADE")
        XCTAssertEqual(c.artist, "Kanye West")
        XCTAssertEqual(c.album, "The Life of Pablo")
        XCTAssertEqual(c.year, 2016)
        XCTAssertEqual(c.trackNumber, 18)
        XCTAssertEqual(c.key, "", "no key claimed until it is heard")
        XCTAssertEqual(c.tempoBPM, 124)
        XCTAssertEqual(c.line, "A relentless pulse under a rise that never resolves.")
        XCTAssertEqual(CreditLibrary.credit(id: "fade"), c)
        XCTAssertTrue(CreditLibrary.all.contains(c))
        XCTAssertEqual(c.pulsePeriod, 60.0 / 124, accuracy: 1e-12)
        // Words and a link only: a credit holds its words and nothing else (no artwork, no images, no lyrics).
        XCTAssertEqual(Mirror(reflecting: c).children.compactMap(\.label),
                       ["id", "song", "artist", "album", "year", "trackNumber", "key", "tempoBPM", "line"])
        // Listen finds it with a Spotify search: nothing of the record is hosted or shown here.
        XCTAssertEqual(ListenLink.spotifyApp(for: c).absoluteString, "spotify:search:Kanye%20West%20FADE")
        XCTAssertEqual(ListenLink.spotifyWeb(for: c).absoluteString, "https://open.spotify.com/search/Kanye%20West%20FADE")
        // Endless Rise's presets carry it.
        for p in PatchLibrary.patches(for: .endlessRise) { XCTAssertEqual(p.credit, c, p.id) }
        // The card says it in words: the song, the artist, the album and its year, and the liner notes without a key.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "FADE")
        XCTAssertEqual(card.words.subtitle, "Kanye West · The Life of Pablo · 2016")
        XCTAssertEqual(card.words.linerNotes, "TRACK 18 · 124 BPM")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
        XCTAssertEqual(card.words.accessibility,
                       "Inspired by FADE by Kanye West, The Life of Pablo, 2016. A relentless pulse under a rise that never resolves.")
        // Every other card keeps its key in its liner notes.
        XCTAssertEqual(InspiredByCard(credit: CreditLibrary.underwater).words.linerNotes, "F♯ minor · TRACK 7 · 118 BPM")
        for other in CreditLibrary.all where other.id != c.id {
            XCTAssertTrue(InspiredByCard(credit: other).words.linerNotes?.hasPrefix(other.key + " · TRACK") ?? false, other.id)
        }
    }

    /// The circular distance between two turns (0…0.5).
    private func turnDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// The "FADE" card is original abstract art (nothing from the record, its artwork or its video): a ring of storm cloud
    /// seen from beneath and afar, turning round a green core over a dark plain, a lit hail shaft falling from it. Its
    /// easter eggs: the ring turns once a bar at 124 (four beats of 60/124 s, the card's breath); the core is green,
    /// (0.35, 0.55, 0.40), and swells once a bar; the pad's pulse dims the ring's lit edge on every beat, as the engine
    /// ducks the pad; and eight bands of inflow (the riser's eight octaves) close in on the core for ever, one band's
    /// place a bar, fading in at the ring and out at the core on the riser's window, so they never arrive. The whole
    /// picture repeats exactly once a bar, and looks like no other card.
    func testFadeCardEasterEggs() throws {
        let credit = CreditLibrary.fade
        let art = try XCTUnwrap(CardArt.art(for: credit.id))
        XCTAssertEqual(art, .fade)
        XCTAssertFalse(art.isPlace)
        XCTAssertFalse(art.titleCase, "FADE is set in capitals already")
        let beat = 60.0 / 124, bar = 4 * beat
        XCTAssertEqual(art.pulse(for: credit), beat, accuracy: 1e-12)
        XCTAssertEqual(InspiredByCard(credit: credit).pulse, beat, accuracy: 1e-12)
        for c in CreditLibrary.all where c.id != credit.id { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        // The ring turns once a bar: a whole turn in four beats, half in two, a quarter in one.
        XCTAssertEqual(CardArt.fadeBeatsPerTurn, 4)
        for t in [0.0, 0.37, 1.9, 7.77] {
            let a = CardArt.fadeTurn(at: t, pulse: beat)
            XCTAssertTrue(a >= 0 && a < 1, "\(a)")
            XCTAssertEqual(turnDistance(a, CardArt.fadeTurn(at: t + bar, pulse: beat)), 0, accuracy: 1e-9, "a bar later it is where it was")
            XCTAssertEqual(turnDistance(a, CardArt.fadeTurn(at: t + bar / 2, pulse: beat)), 0.5, accuracy: 1e-9)
            XCTAssertEqual(turnDistance(a, CardArt.fadeTurn(at: t + beat, pulse: beat)), 0.25, accuracy: 1e-9)
        }

        // The core is green, and swells once a bar: full on the downbeat, settled at the half bar.
        XCTAssertEqual(CardArt.fadeCore.red, 0.35)
        XCTAssertEqual(CardArt.fadeCore.green, 0.55)
        XCTAssertEqual(CardArt.fadeCore.blue, 0.40)
        XCTAssertEqual(CardArt.fadeBreath(at: 0, pulse: beat), 1, accuracy: 1e-9)
        XCTAssertEqual(CardArt.fadeBreath(at: bar / 2, pulse: beat), 0, accuracy: 1e-9)
        for t in [0.2, 1.1, 5.0] {
            XCTAssertEqual(CardArt.fadeBreath(at: t, pulse: beat), CardArt.fadeBreath(at: t + bar, pulse: beat), accuracy: 1e-9)
        }

        // The pad's pulse: the lit edge dims straight down on every beat and is back by 60% of it.
        for b in 1...4 {
            let on = Double(b) * beat
            XCTAssertEqual(CardArt.fadePump(at: on + 1e-6, pulse: beat), 0.55, accuracy: 1e-3, "down on beat \(b)")
            XCTAssertEqual(CardArt.fadePump(at: on - 1e-6, pulse: beat), 1, accuracy: 1e-9, "full just before it")
            XCTAssertEqual(CardArt.fadePump(at: on + 0.6 * beat, pulse: beat), 1, accuracy: 1e-9, "back by 60% of the beat")
            XCTAssertEqual(CardArt.fadePump(at: on + 0.3 * beat, pulse: beat), 1 - 0.45 * 0.25, accuracy: 1e-9)
        }

        // Eight bands close in on the core for ever: a bar later the eight are where they were; a moment later each is
        // further in; they fade in at the ring and out at the core.
        XCTAssertEqual(CardArt.fadeBandCount, 8)
        for t in [0.1, 3.3] {
            let now = CardArt.fadeBands(at: t, pulse: beat)
            let later = CardArt.fadeBands(at: t + bar, pulse: beat)
            let soon = CardArt.fadeBands(at: t + bar / 8, pulse: beat)
            XCTAssertEqual(now.count, 8)
            XCTAssertEqual(later.count, 8)
            XCTAssertEqual(soon.count, 8)
            guard now.count == 8, later.count == 8, soon.count == 8 else { continue }
            for j in 0..<8 {
                XCTAssertEqual(now[j].radius, later[j].radius, accuracy: 1e-9)
                XCTAssertEqual(now[j].opacity, later[j].opacity, accuracy: 1e-9)
                XCTAssertEqual(turnDistance(now[j].turn, later[j].turn), 0, accuracy: 1e-9)
                XCTAssertLessThan(soon[j].radius, now[j].radius, "band \(j) closes in")
                XCTAssertTrue(now[j].radius > 0 && now[j].radius <= 1 && now[j].opacity >= 0 && now[j].opacity <= 1)
            }
            XCTAssertTrue(zip(now, now.dropFirst()).allSatisfy { $0.radius > $1.radius }, "outermost first")
        }
        let start = CardArt.fadeBands(at: 0, pulse: beat)
        XCTAssertEqual(start.first?.opacity ?? 1, 0, accuracy: 1e-9, "a band fades in at the ring")
        XCTAssertEqual(start[4].opacity, 1, accuracy: 1e-9, "full half way in")

        // The picture: it draws and moves; it repeats exactly once a bar; its core is green; it looks like no other card.
        let a = try XCTUnwrap(Self.render(credit, at: 0.4))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let barLater = try XCTUnwrap(Self.render(credit, at: 0.4 + bar))
        let again = PreviewRenderer.difference(a, barLater)
        XCTAssertLessThan(again, 0.002, "a bar later the card is as it was")
        let halfBar = try XCTUnwrap(Self.render(credit, at: 0.4 + bar / 2))
        let moved = PreviewRenderer.difference(a, halfBar)
        if moved <= 0.003 { XCTFail("half a bar later the FADE card moved only \(moved)") }
        let ring = CardArt.fadeRing
        let cx = 2 * Double(ring.x) - 1, cy = 1 - 2 * Double(ring.y)
        let core = FramePatch.meanRGB(a, x: (cx - 0.04)...(cx + 0.04), y: (cy - 0.04)...(cy + 0.04))
        XCTAssertGreaterThan(core.y - core.x, 0.08, "the core is green: \(core)")
        XCTAssertGreaterThan(core.y - core.z, 0.05, "the core is green: \(core)")
        XCTAssertGreaterThan(core.y, 0.4, "and lit: \(core)")
        let mine = try XCTUnwrap(Self.render(credit, at: 1.0))
        for c in CreditLibrary.all where c.id != credit.id {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the FADE card and \(c.id) differ by only \(d)") }
        }
    }

    /// "Stay" is felt in half time, so its card breathes at 67, not 134.
    func testStayCardBreathesAtHalfTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), 60.0 / 67, accuracy: 1e-9)
        XCTAssertEqual(CardArt.highByTheBeach.pulse(for: CreditLibrary.highByTheBeach), 60.0 / 132, accuracy: 1e-9)
    }

    /// "Dunno"'s motes twinkle on its beat, 82 BPM.
    func testDunnoCardTwinklesAtTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.dunno.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.dunno), 60.0 / 82, accuracy: 1e-9)
    }

    /// "Wings" is felt in half time (119 BPM, about 60), so its curtains ripple once a second.
    func testWingsCardRipplesAtHalfTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.wings.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.stay.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.dunno.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.wings), 60.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(CardArt.wingsStars.count, CreditLibrary.wings.trackNumber, "one bright star per track number")
    }

    /// The Wings card's bright stars keep off the liner notes (top right).
    func testWingsStarsKeepOffTheLinerNotes() {
        let w: CGFloat = 600, h: CGFloat = 360
        let notes = CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h)
        for (fx, fy, r) in CardArt.wingsStars {
            let star = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse(star.intersects(notes), "star at (\(fx), \(fy)) covers the liner notes")
        }
    }

    /// "Happiness Is a Butterfly"'s thirteen motes (the track number) blink on its beat, 68 BPM.
    func testButterflyCardBlinksAtTempo() throws {
        let art = try XCTUnwrap(CardArt.art(for: CreditLibrary.happinessIsAButterfly.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.wings.id))
        XCTAssertNotEqual(art, CardArt.art(for: CreditLibrary.highByTheBeach.id))
        XCTAssertEqual(art.pulse(for: CreditLibrary.happinessIsAButterfly), 60.0 / 68, accuracy: 1e-9)
        XCTAssertEqual(CardArt.butterflyMotes.count, CreditLibrary.happinessIsAButterfly.trackNumber, "one mote per track number")
    }

    /// The Butterfly card's motes keep off its words: the liner notes (top right), the title block (bottom left) and the
    /// Listen button, as the Stay card's frost does.
    func testButterflyMotesKeepOffTheWords() {
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // D major · TRACK 13 · 68 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for (fx, fy, r) in CardArt.butterflyMotes {
            let mote = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            for rect in words { XCTAssertFalse(mote.intersects(rect), "mote at (\(fx), \(fy)) covers \(rect)") }
        }
    }

    /// The Stay card's frost stars keep off its words: the liner notes (top right), the title block (bottom left) and
    /// the Listen button (final review: a star sat on "TRACK 3").
    func testStayFrostKeepsOffTheWords() {
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // F♯ major · TRACK 3 · 134 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        for (fx, fy, r) in CardArt.stayFrost {
            let star = CGRect(x: fx * w - r, y: fy * h - r, width: 2 * r, height: 2 * r)
            for rect in words { XCTAssertFalse(star.intersects(rect), "star at (\(fx), \(fy)) covers \(rect)") }
        }
    }

    /// The Dunno card's beam is light falling through the room, not a white wedge (final review: plus-lighter clipped it
    /// to white and swallowed the motes).
    func testDunnoBeamIsNotClippedToWhite() throws {
        let image = try XCTUnwrap(Self.render(CreditLibrary.dunno, at: 1.0))
        let beam = FramePatch.meanRGB(image, x: -0.1...0.1, y: -0.11...0)
        XCTAssertLessThan(min(beam.x, beam.y, beam.z), 0.9, "\(beam)")
    }

    func testCardsDrawTheirArtAndBreatheWithTheTempo() throws {
        for c in CreditLibrary.all {
            let a = try XCTUnwrap(Self.render(c, at: 0.2), c.id)
            let s = PreviewRenderer.stats(a)
            XCTAssertGreaterThan(s.meanLuminance, 0.05, c.id)
            XCTAssertGreaterThan(s.variance, 0.001, c.id)
            // Two seconds later the art has moved on (ring and caustics; the bloom opening).
            let b = try XCTUnwrap(Self.render(c, at: 2.2), c.id)
            let moved = PreviewRenderer.difference(a, b)
            if moved <= 0.001 { XCTFail("\(c.id) moved only \(moved)") }
        }
    }
}
