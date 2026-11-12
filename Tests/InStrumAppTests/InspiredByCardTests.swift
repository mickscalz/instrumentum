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
        let count = SetLibrary.all.count
        XCTAssertEqual(count, 16)
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
        // The storms (Storms spec §12): the dark under the base to the storm's green-grey; the plain's dusk to its amber.
        let supercell = SetsGallery.tint(for: SetLibrary.supercellSky.id)
        let stormGreenGrey = [Color(red: 0.06, green: 0.08, blue: 0.07), Color(red: 0.35, green: 0.42, blue: 0.38)]
        XCTAssertEqual(supercell, stormGreenGrey)
        let plains = SetsGallery.tint(for: SetLibrary.lightningPlains.id)
        let duskAmber = [Color(red: 0.10, green: 0.09, blue: 0.18), Color(red: 0.55, green: 0.40, blue: 0.25)]
        XCTAssertEqual(plains, duskAmber)
        XCTAssertNotEqual(supercell, plains)
        // Fire & Neon (spec §11): the crater's black basalt to the lake's molten orange; the wet night to the neon's magenta.
        let volcano = SetsGallery.tint(for: SetLibrary.volcanoRim.id)
        XCTAssertEqual(volcano, [Color(red: 0.08, green: 0.03, blue: 0.02), Color(red: 0.78, green: 0.28, blue: 0.06)])
        let drive = SetsGallery.tint(for: SetLibrary.neonNightDrive.id)
        XCTAssertEqual(drive, [Color(red: 0.05, green: 0.03, blue: 0.11), Color(red: 0.62, green: 0.10, blue: 0.48)])
        XCTAssertNotEqual(volcano, drive)
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
        XCTAssertEqual(SetLibrary.all.compactMap { CardArt.place(for: $0.id) }, [.teaHouseSnow, .zenRockGarden, .greatBarrierReef, .neonNightDrive])
        XCTAssertEqual(SetLibrary.volcanoRim.creditID.flatMap { CardArt.art(for: $0) }, CardArt.holdMyLiquor)
        XCTAssertNil(CardArt.place(for: SetLibrary.volcanoRim.id), "the volcano has its song's card")
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
        XCTAssertEqual(places.map(\.id), ["tea-house-snow", "zen-rock-garden", "neon-night-drive"])
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
    /// until Michael taps it. Credits carry only verified facts: it states no key (still to be heard) and no track number
    /// (not verified), so the liner notes read "124 BPM" alone.
    func testFadeCredit() {
        let c = CreditLibrary.fade
        XCTAssertEqual(c.id, "fade")
        XCTAssertEqual(c.song, "FADE")
        XCTAssertEqual(c.artist, "Kanye West")
        XCTAssertEqual(c.album, "The Life of Pablo")
        XCTAssertEqual(c.year, 2016)
        XCTAssertNil(c.trackNumber, "no track number stated: it isn't verified")
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
        // The card says it in words: the song, the artist, the album and its year, and the liner notes with neither a key
        // nor a track number.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "FADE")
        XCTAssertEqual(card.words.subtitle, "Kanye West · The Life of Pablo · 2016")
        XCTAssertEqual(card.words.linerNotes, "124 BPM")
        XCTAssertFalse(card.words.linerNotes?.contains("TRACK") ?? true, "no track number on the card")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
        XCTAssertEqual(card.words.accessibility,
                       "Inspired by FADE by Kanye West, The Life of Pablo, 2016. A relentless pulse under a rise that never resolves.")
        // Every other card keeps its key and its track number in its liner notes.
        XCTAssertEqual(InspiredByCard(credit: CreditLibrary.underwater).words.linerNotes, "F♯ minor · TRACK 7 · 118 BPM")
        // "Runaway" states a track number but no key (disputed), so its notes start at the track.
        for other in CreditLibrary.all where other.id != c.id {
            XCTAssertNotNil(other.trackNumber, other.id)
            let notes: String = InspiredByCard(credit: other).words.linerNotes ?? ""
            let parts: [String] = [other.key, "TRACK \(other.trackNumber ?? 0)", "\(Int(other.tempoBPM.rounded())) BPM"]
            XCTAssertEqual(notes, parts.filter { !$0.isEmpty }.joined(separator: " · "), other.id)
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

    /// The credit for "Runaway" (Storms spec §2, §12; brief single-note-grand.md), exactly: words and a link only. Its
    /// track number, 9, is a verified fact, so the card states it; its key is disputed, so it states none, and the liner
    /// notes leave it out: "TRACK 9 · 86 BPM". The felt pulse is 86.
    func testRunawayCredit() {
        let c = CreditLibrary.runaway
        XCTAssertEqual(c.id, "runaway")
        XCTAssertEqual(c.song, "Runaway")
        XCTAssertEqual(c.artist, "Kanye West")
        XCTAssertEqual(c.album, "My Beautiful Dark Twisted Fantasy")
        XCTAssertEqual(c.year, 2010)
        XCTAssertEqual(c.trackNumber, 9)
        XCTAssertEqual(c.key, "", "no key claimed: it is disputed")
        XCTAssertEqual(c.tempoBPM, 86)
        XCTAssertEqual(c.line, "One piano note, repeated, and a voice that arrives distorted.")
        XCTAssertEqual(CreditLibrary.credit(id: "runaway"), c)
        XCTAssertTrue(CreditLibrary.all.contains(c))
        XCTAssertEqual(c.pulsePeriod, 60.0 / 86, accuracy: 1e-12)
        // Words and a link only: a credit holds its words and nothing else (no artwork, no images, no lyrics).
        XCTAssertEqual(Mirror(reflecting: c).children.compactMap { $0.label },
                       ["id", "song", "artist", "album", "year", "trackNumber", "key", "tempoBPM", "line"])
        // Listen finds it with a Spotify search: nothing of the record is hosted or shown here.
        XCTAssertEqual(ListenLink.spotifyApp(for: c).absoluteString, "spotify:search:Kanye%20West%20Runaway")
        XCTAssertEqual(ListenLink.spotifyWeb(for: c).absoluteString, "https://open.spotify.com/search/Kanye%20West%20Runaway")
        // Single Note Grand's presets carry it.
        XCTAssertEqual(PatchLibrary.patches(for: .singleNoteGrand).count, 4)
        for p in PatchLibrary.patches(for: .singleNoteGrand) { XCTAssertEqual(p.credit, c, p.id) }
        // The card says it in words: the song, the artist, the album and its year, and the liner notes with its track and
        // its tempo but no key.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "Runaway")
        XCTAssertEqual(card.words.subtitle, "Kanye West · My Beautiful Dark Twisted Fantasy · 2010")
        XCTAssertEqual(card.words.linerNotes, "TRACK 9 · 86 BPM")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
        XCTAssertEqual(card.words.accessibility,
                       "Inspired by Runaway by Kanye West, My Beautiful Dark Twisted Fantasy, 2010. One piano note, repeated, and a voice that arrives distorted.")
        // A card whose credit states its key still shows it.
        XCTAssertEqual(InspiredByCard(credit: CreditLibrary.underwater).words.linerNotes, "F♯ minor · TRACK 7 · 118 BPM")
        XCTAssertEqual(InspiredByCard(credit: CreditLibrary.dunno).words.linerNotes, "C♯ major · TRACK 10 · 82 BPM")
    }

    /// The "Runaway" card is original abstract art (nothing from the record, its artwork or its film): an empty plain at
    /// dusk, a line of storm towers on the horizon, and a fence running away across the plain. Its easter eggs: nine posts
    /// (the track number), one of them lit, the note's post (the keys are fence posts on Lightning Plains), struck again on
    /// every beat at 86 (the card's breath) and never quite dark between; and above it a forked line of five branches, its
    /// main channel pointing down at the lit post's cap, brightening with each strike. The lit post and the fork keep off
    /// the words; the whole picture repeats exactly once a bar, and looks like no other card.
    func testRunawayCardEasterEggs() throws {
        let credit = CreditLibrary.runaway
        let art = try XCTUnwrap(CardArt.art(for: credit.id))
        XCTAssertEqual(art, .runaway)
        XCTAssertFalse(art.isPlace)
        XCTAssertFalse(art.titleCase)
        let beat = 60.0 / 86, bar = 4 * beat
        XCTAssertEqual(art.pulse(for: credit), beat, accuracy: 1e-12, "it breathes at 86")
        XCTAssertEqual(InspiredByCard(credit: credit).pulse, beat, accuracy: 1e-12)
        for c in CreditLibrary.all where c.id != credit.id { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        // Nine posts, the track number, running away across the plain: each further one smaller, nearer the vanishing
        // point and its foot nearer the horizon, every one standing on the plain against the sky; one of them lit.
        let posts = CardArt.runawayPosts
        let horizon = CardArt.runawayHorizon
        XCTAssertEqual(posts.count, 9)
        XCTAssertEqual(posts.count, credit.trackNumber)
        for (a, b) in zip(posts, posts.dropFirst()) {
            XCTAssertLessThan(b.x, a.x)
            XCTAssertLessThan(b.foot, a.foot)
            XCTAssertLessThan(b.height, a.height)
            XCTAssertLessThan(b.width, a.width)
        }
        for p in posts {
            XCTAssertGreaterThan(p.foot, horizon, "on the plain")
            XCTAssertLessThan(p.foot - p.height, horizon, "against the sky")
        }
        let lit = CardArt.runawayLitPost
        XCTAssertTrue(posts.indices.contains(lit))
        let post = posts[lit]
        let postTop: CGFloat = post.foot - post.height

        // A forked line of five branches: the main channel from the storm down to a tip just above the lit post's cap;
        // the other four leave it on the way down, one below the other, and fork out into the air, each ending lower than
        // it starts and shorter than the channel. The post stands under all of it.
        let fork = CardArt.runawayFork
        XCTAssertEqual(fork.count, 5, "five branches")
        let channel = try XCTUnwrap(fork.first)
        let top = try XCTUnwrap(channel.first), tip = try XCTUnwrap(channel.last)
        XCTAssertLessThan(abs(tip.x - post.x), post.width / 2, "the channel points down at the lit post")
        /// A branch's length in points on a 600 × 360 card.
        func length(_ branch: [CGPoint]) -> CGFloat {
            zip(branch, branch.dropFirst()).reduce(0) { sum, s in
                let dx: CGFloat = 600 * (s.1.x - s.0.x), dy: CGFloat = 360 * (s.1.y - s.0.y)
                return sum + (dx * dx + dy * dy).squareRoot()
            }
        }
        let points: [CGPoint] = fork.flatMap { $0 }
        for p in points {
            XCTAssertLessThan(p.y, postTop, "the post stands under the fork")
            XCTAssertGreaterThanOrEqual(p.y, top.y, "the channel starts highest")
            XCTAssertLessThanOrEqual(p.y, tip.y, "and its tip is the lowest point")
        }
        var leaves: [Int] = []
        for branch in fork.dropFirst() {
            let start = try XCTUnwrap(branch.first), end = try XCTUnwrap(branch.last)
            let at = try XCTUnwrap(channel.firstIndex(of: start), "each branch leaves the main channel")
            leaves.append(at)
            XCTAssertGreaterThan(end.y, start.y, "and goes down")
            XCTAssertLessThan(length(branch), length(channel))
        }
        XCTAssertEqual(leaves, leaves.sorted(), "one below the other")
        XCTAssertEqual(Set(leaves).count, 4)
        XCTAssertFalse(leaves.contains(0), "below the storm")

        // The lit post and the fork keep off the words: the liner notes (top right), the title block (bottom left) and the
        // Listen button.
        let w: CGFloat = 600, h: CGFloat = 360
        let words = [CGRect(x: 0.6 * w, y: 0, width: 0.4 * w, height: 0.1 * h),          // TRACK 9 · 86 BPM
                     CGRect(x: 0, y: 0.68 * h, width: 0.72 * w, height: 0.32 * h),        // Inspired by, title, credit, line
                     CGRect(x: 0.82 * w, y: 0.86 * h, width: 0.18 * w, height: 0.14 * h)] // Listen
        let body = CGRect(x: (post.x - post.width / 2) * w, y: postTop * h, width: post.width * w, height: post.height * h)
        let xs: [CGFloat] = points.map { $0.x }, ys: [CGFloat] = points.map { $0.y }
        let left: CGFloat = xs.min() ?? 0, right: CGFloat = xs.max() ?? 1, high: CGFloat = ys.min() ?? 0, low: CGFloat = ys.max() ?? 1
        let span = CGRect(x: left * w, y: high * h, width: (right - left) * w, height: (low - high) * h)
        for rect in words {
            XCTAssertFalse(body.intersects(rect), "the lit post covers \(rect)")
            XCTAssertFalse(span.intersects(rect), "the fork covers \(rect)")
        }

        // The note strikes the post on every beat: full just after the beat, lowest just before the next but never dark,
        // and the same a beat later.
        for b in 1...4 {
            let on = Double(b) * beat
            XCTAssertEqual(CardArt.runawayStrike(at: on + 0.06 * beat, pulse: beat), 1, accuracy: 1e-9, "struck on beat \(b)")
            let before = CardArt.runawayStrike(at: on - 1e-6, pulse: beat)
            XCTAssertLessThan(before, 0.15, "dying away before beat \(b)")
            XCTAssertGreaterThan(before, 0.05, "never quite dark")
        }
        for t in [0.13, 1.0, 2.4, 7.77] {
            let now = CardArt.runawayStrike(at: t, pulse: beat)
            XCTAssertEqual(now, CardArt.runawayStrike(at: t + beat, pulse: beat), accuracy: 1e-9, "a beat later it is as it was")
            XCTAssertTrue(now > 0.05 && now <= 1, "\(now)")
        }

        // The picture: it draws and moves, and repeats exactly once a bar.
        let a = try XCTUnwrap(Self.render(credit, at: 0.4))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let barLater = try XCTUnwrap(Self.render(credit, at: 0.4 + bar))
        let again = PreviewRenderer.difference(a, barLater)
        XCTAssertLessThan(again, 0.002, "a bar later the card is as it was")
        let later = try XCTUnwrap(Self.render(credit, at: 0.4 + 1.5 * beat))
        let moved = PreviewRenderer.difference(a, later)
        if moved <= 0.002 { XCTFail("a beat and a half later the Runaway card moved only \(moved)") }

        // One post lit, warm white, and the others dark, just after a strike and just before the next; the fork is lit.
        /// A post's upper body (5–30% down from its top, the middle 60% of its width), in the card's NDC.
        func upper(_ i: Int) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
            let p = posts[i]
            let x0 = Double(p.x - 0.3 * p.width), x1 = Double(p.x + 0.3 * p.width)
            let y0 = Double(p.foot - 0.95 * p.height), y1 = Double(p.foot - 0.70 * p.height)
            return (x: (2 * x0 - 1)...(2 * x1 - 1), y: (1 - 2 * y1)...(1 - 2 * y0))
        }
        func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        let struck = try XCTUnwrap(Self.render(credit, at: 2.07 * beat)), waiting = try XCTUnwrap(Self.render(credit, at: 3 * beat - 0.01))
        for (moment, frame) in [("just struck", struck), ("before the next", waiting)] {
            let litRGB = FramePatch.meanRGB(frame, x: upper(lit).x, y: upper(lit).y)
            let litLuminance = luminance(litRGB)
            XCTAssertGreaterThan(litLuminance, 0.45, "the lit post is lit \(moment): \(litRGB)")
            XCTAssertGreaterThanOrEqual(litRGB.x, litRGB.z, "warm white \(moment): \(litRGB)")
            for i in posts.indices where i != lit {
                let other = FramePatch.meanRGB(frame, x: upper(i).x, y: upper(i).y)
                XCTAssertLessThan(luminance(other), litLuminance - 0.25, "post \(i) is dark \(moment): \(other)")
            }
        }
        let litStruck = luminance(FramePatch.meanRGB(struck, x: upper(lit).x, y: upper(lit).y))
        let litWaiting = luminance(FramePatch.meanRGB(waiting, x: upper(lit).x, y: upper(lit).y))
        XCTAssertGreaterThan(litStruck, litWaiting + 0.03, "brighter just after the strike")
        let mid = channel[channel.count / 2]
        let mx = 2 * Double(mid.x) - 1, my = 1 - 2 * Double(mid.y)
        let bolt = FramePatch.brightest(struck, x: (mx - 0.02)...(mx + 0.02), y: (my - 0.03)...(my + 0.03), share: 0.1)
        XCTAssertGreaterThan(bolt, 0.6, "the fork is lit")

        // It looks like no other card.
        let mine = try XCTUnwrap(Self.render(credit, at: 1.0))
        for c in CreditLibrary.all where c.id != credit.id {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the Runaway card and \(c.id) differ by only \(d)") }
        }
    }

    // MARK: - Fire & Neon (Sets 13 & 14)

    /// The card's words, as the song cards set them: the liner notes (top right), the title block (bottom left) and the
    /// Listen button, on a 600 × 360 card.
    private static let songWords: [CGRect] = [CGRect(x: 360, y: 0, width: 240, height: 36),
                                              CGRect(x: 0, y: 244.8, width: 432, height: 115.2),
                                              CGRect(x: 492, y: 309.6, width: 108, height: 50.4)]

    /// The credit for "Hold My Liquor" (Fire & Neon spec §2, §11), exactly: words and a Spotify search link only. Its place
    /// on *Yeezus*, track 5, is a verified fact; its key and tempo come only from key-detection sites (A♭ major at 104),
    /// so it claims no key and the card breathes at 104 until it is checked by ear: the liner notes read
    /// "TRACK 5 · 104 BPM". Magma Bass's presets carry it.
    func testHoldMyLiquorCredit() {
        let c = CreditLibrary.holdMyLiquor
        XCTAssertEqual(c.id, "hold-my-liquor")
        XCTAssertEqual(c.song, "Hold My Liquor")
        XCTAssertEqual(c.artist, "Kanye West")
        XCTAssertEqual(c.album, "Yeezus")
        XCTAssertEqual(c.year, 2013)
        XCTAssertEqual(c.trackNumber, 5)
        XCTAssertEqual(c.key, "", "no key claimed: it is machine-detected, to be checked by ear")
        XCTAssertEqual(c.tempoBPM, 104)
        XCTAssertEqual(c.line, "A heavy, slow-burning pulse with distortion glowing under it like heat.")
        XCTAssertEqual(CreditLibrary.credit(id: "hold-my-liquor"), c)
        XCTAssertTrue(CreditLibrary.all.contains(c))
        XCTAssertEqual(c.pulsePeriod, 60.0 / 104, accuracy: 1e-12)
        // Words and a link only: a credit holds its words and nothing else (no artwork, no images, no lyrics).
        XCTAssertEqual(Mirror(reflecting: c).children.compactMap(\.label),
                       ["id", "song", "artist", "album", "year", "trackNumber", "key", "tempoBPM", "line"])
        // Listen finds it with a Spotify search: nothing of the record is hosted or shown here.
        XCTAssertEqual(ListenLink.spotifyApp(for: c).absoluteString, "spotify:search:Kanye%20West%20Hold%20My%20Liquor")
        XCTAssertEqual(ListenLink.spotifyWeb(for: c).absoluteString, "https://open.spotify.com/search/Kanye%20West%20Hold%20My%20Liquor")
        // Magma Bass's presets carry it.
        XCTAssertEqual(PatchLibrary.patches(for: .magmaBass).count, 4)
        for p in PatchLibrary.patches(for: .magmaBass) { XCTAssertEqual(p.credit, c, p.id) }
        // The card says it in words: the song, the artist, the album and its year, and the liner notes with its track and
        // tempo but no key; a Listen button finds it.
        let card = InspiredByCard(credit: c)
        XCTAssertEqual(card.subject, .song(c))
        XCTAssertEqual(card.art, .holdMyLiquor)
        XCTAssertEqual(card.words.kicker, "INSPIRED BY")
        XCTAssertEqual(card.words.title, "Hold My Liquor")
        XCTAssertEqual(card.words.subtitle, "Kanye West · Yeezus · 2013")
        XCTAssertEqual(card.words.linerNotes, "TRACK 5 · 104 BPM")
        XCTAssertEqual(card.words.line, c.line)
        XCTAssertEqual(card.words.listen, c)
        XCTAssertEqual(card.words.accessibility,
                       "Inspired by Hold My Liquor by Kanye West, Yeezus, 2013. A heavy, slow-burning pulse with distortion glowing under it like heat.")
    }

    /// The "Hold My Liquor" card is original art from the set's world (nothing from the record, its packaging or its
    /// words): a lava lake in a crater at night, its black crust broken into plates whose cracks glow, a fountain, a
    /// leaning plume, the far rim. It breathes at the felt pulse, 104: the cracks throb on every beat, the fountain throws
    /// its spatter and one ember rises from it on every beat, four in the air at once; and on the far rim stands a tiny
    /// lava tree (the easter egg), clear of the words. The picture repeats exactly once a bar, its fountain glows warm, and
    /// it looks like no other card.
    func testHoldMyLiquorCardEasterEggs() throws {
        let credit = CreditLibrary.holdMyLiquor
        let art = try XCTUnwrap(CardArt.art(for: credit.id))
        XCTAssertEqual(art, .holdMyLiquor)
        XCTAssertFalse(art.isPlace)
        XCTAssertFalse(art.titleCase)
        let beat = 60.0 / 104, bar = 4 * beat
        XCTAssertEqual(art.pulse(for: credit), beat, accuracy: 1e-12, "it breathes at 104")
        XCTAssertEqual(InspiredByCard(credit: credit).pulse, beat, accuracy: 1e-12)
        for c in CreditLibrary.all where c.id != credit.id { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }

        // The cracks throb on the beat: full on it, easing off through it, the same a beat later.
        for b in 1...4 {
            XCTAssertEqual(CardArt.liquorThrob(at: Double(b) * beat + 1e-9, pulse: beat), 1, accuracy: 1e-6, "on beat \(b)")
            XCTAssertLessThan(CardArt.liquorThrob(at: (Double(b) + 0.95) * beat, pulse: beat), 0.1)
        }
        // One ember leaves the fountain on every beat and rises for four: four in the air, the newest at the fountain.
        let fountain = CardArt.liquorLakePoint(u: CardArt.liquorFountain.u, v: CardArt.liquorFountain.v)
        for b in [1, 2, 7] {
            let embers = CardArt.liquorEmbers(at: Double(b) * beat + 1e-6, pulse: beat)
            XCTAssertEqual(embers.count, 4)
            let newest = try XCTUnwrap(embers.max { $0.heat < $1.heat })
            XCTAssertGreaterThan(newest.heat, 0.99, "one just left on beat \(b)")
            XCTAssertEqual(newest.x, Double(fountain.x), accuracy: 0.01)
            XCTAssertEqual(newest.y, Double(fountain.y), accuracy: 0.03)
            let heats = embers.map { $0.heat }.sorted()
            for (lower, higher) in zip(heats, heats.dropFirst()) { XCTAssertEqual(higher - lower, 0.25, accuracy: 1e-6, "a beat apart") }
            for e in embers {
                XCTAssertLessThanOrEqual(e.y, Double(fountain.y) + 1e-9, "they rise")
                XCTAssertTrue(e.light >= 0 && e.light <= 1)
            }
        }
        for t in [0.3, 1.7, 5.2] {
            let now = CardArt.liquorEmbers(at: t, pulse: beat), later = CardArt.liquorEmbers(at: t + bar, pulse: beat)
            for (then, again) in zip(now, later) {
                XCTAssertEqual(then.x, again.x, accuracy: 1e-9, "a bar later the embers are where they were")
                XCTAssertEqual(then.y, again.y, accuracy: 1e-9)
            }
        }
        // The crust: well over a hundred plates, each a closed cell.
        XCTAssertGreaterThan(CardArt.liquorPlates.count, 100)
        for plate in CardArt.liquorPlates { XCTAssertGreaterThanOrEqual(plate.cell.count, 3) }

        // The lava tree: tiny, standing on the far rim, clear of the words.
        let tree = CardArt.liquorLavaTree
        XCTAssertLessThan(tree.height, 0.06, "tiny")
        let foot = CardArt.liquorRimTop(tree.x)
        XCTAssertTrue(foot > 0.25 && foot < 0.45, "on the far rim, below the sky: \(foot)")
        XCTAssertLessThan(foot, Double(fountain.y), "beyond the lake")
        let body = CGRect(x: 600 * tree.x - 6, y: 360 * (foot - tree.height), width: 12, height: 360 * tree.height)
        for rect in Self.songWords { XCTAssertFalse(body.intersects(rect), "the lava tree covers \(rect)") }

        // The picture: it draws and moves, repeats exactly once a bar, and its fountain glows warm.
        let a = try XCTUnwrap(Self.render(credit, at: 0.4))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let barLater = try XCTUnwrap(Self.render(credit, at: 0.4 + bar))
        let again = PreviewRenderer.difference(a, barLater)
        XCTAssertLessThan(again, 0.002, "a bar later the card is as it was")
        let later = try XCTUnwrap(Self.render(credit, at: 0.4 + 1.5 * beat))
        let moved = PreviewRenderer.difference(a, later)
        if moved <= 0.001 { XCTFail("a beat and a half later the Hold My Liquor card moved only \(moved)") }
        let fx = 2 * Double(fountain.x) - 1, fy = 1 - 2 * Double(fountain.y)
        let glow = FramePatch.meanRGB(a, x: (fx - 0.04)...(fx + 0.04), y: (fy - 0.04)...(fy + 0.04))
        XCTAssertGreaterThan(glow.x, 0.45, "the fountain is lit: \(glow)")
        XCTAssertGreaterThan(glow.x, glow.y, "and warm: \(glow)")
        XCTAssertGreaterThan(glow.y, glow.z, "and warm: \(glow)")

        // It looks like no other card, song or place.
        let mine = try XCTUnwrap(Self.render(credit, at: 1.0))
        for c in CreditLibrary.all where c.id != credit.id {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the Hold My Liquor card and \(c.id) differ by only \(d)") }
        }
        for place in SetLibrary.all where place.creditID == nil {
            let other = try XCTUnwrap(Self.render(place: place, at: 1.0), place.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the Hold My Liquor card and \(place.id)'s differ by only \(d)") }
        }
    }

    /// Neon Night Drive is born from its place: its card (an elevated expressway at night in rain, light trails running
    /// down the wet road between the towers, wordless neon glyphs and their reflections, a wiper's arc swept clear of the
    /// beaded glass) breathes at the drive's own tempo, 120 (one breath every 60/120 s), whatever any song's; names the
    /// set and its mood with no liner notes or Listen button; and one sign's glyph is the app's own icon (the easter egg).
    /// Its signs blink up in turn, one on each beat of the bar, and keep off the title block; the picture repeats exactly
    /// once a bar, and looks like no song card and no other place's card.
    func testNeonNightDrivePlaceCard() throws {
        let set = SetLibrary.neonNightDrive
        let art = try XCTUnwrap(CardArt.place(for: "neon-night-drive"))
        XCTAssertEqual(art, .neonNightDrive)
        XCTAssertTrue(art.isPlace)
        for c in CreditLibrary.all { XCTAssertNotEqual(CardArt.art(for: c.id), art, c.id) }
        let beat = 60.0 / 120, bar = 4 * beat
        XCTAssertEqual(CardArt.drivePulse, beat, accuracy: 1e-12)
        XCTAssertEqual(art.placeBreath, beat, accuracy: 1e-12, "the drive's tempo, 120")
        XCTAssertEqual(art.pulse(for: CreditLibrary.stay), beat, accuracy: 1e-12, "a place card follows no song")
        XCTAssertEqual(CardArt.greatBarrierReef.placeBreath, 60.0 / 52, accuracy: 1e-12, "the reef keeps its own")
        XCTAssertEqual(CardArt.zenRockGarden.placeBreath, 60.0 / 48, accuracy: 1e-12)

        let card = InspiredByCard(place: set)
        XCTAssertEqual(card.subject, .place(set))
        XCTAssertEqual(card.art, .neonNightDrive)
        XCTAssertEqual(card.pulse, beat, accuracy: 1e-12)
        XCTAssertEqual(card.words.kicker, "BORN FROM A PLACE")
        XCTAssertEqual(card.words.title, "Neon Night Drive")
        XCTAssertEqual(card.words.subtitle, "Wired")
        XCTAssertNil(card.words.listen, "no Listen button")
        XCTAssertNil(card.words.linerNotes)
        XCTAssertNil(card.words.line)
        XCTAssertEqual(card.words.accessibility, "Neon Night Drive, born from a place. Wired.")

        // The signs: wordless glyphs, one of them the app's icon; each blinks up on its beat, every beat has one.
        let signs = CardArt.driveSigns
        XCTAssertEqual(signs.filter { $0.glyph == .icon }.count, 1, "one sign is the app's icon")
        XCTAssertEqual(Set(signs.map { $0.beat }), [0, 1, 2, 3])
        for sign in signs {
            XCTAssertEqual(CardArt.driveSignLight(beat: sign.beat, at: (Double(sign.beat) + 0.002) * beat, pulse: beat), 1, accuracy: 0.01)
            XCTAssertEqual(CardArt.driveSignLight(beat: sign.beat, at: (Double(sign.beat + 4) + 0.002) * beat, pulse: beat), 1, accuracy: 0.01, "a bar later")
            XCTAssertEqual(CardArt.driveSignLight(beat: sign.beat, at: (Double(sign.beat) + 1.5) * beat, pulse: beat), 0.75, accuracy: 1e-9)
            let half: Double = sign.size / 2
            let box = CGRect(x: 600 * (sign.x - 0.6 * half * 360 / 600 * 2), y: 360 * (sign.y - 1.8 * half),
                             width: 600 * (2.4 * half * 360 / 600), height: 360 * 3.6 * half)
            XCTAssertFalse(box.intersects(CGRect(x: 0, y: 244.8, width: 432, height: 115.2)), "\(sign.glyph) covers the title block")
        }
        // The icon glyph: the app's butterfly, its wings mirrored about its body.
        let icon = CardArt.driveIconPath(at: CGPoint(x: 100, y: 100), span: 56).boundingRect
        XCTAssertEqual(icon.midX, 100, accuracy: 0.5, "mirrored about its body")
        XCTAssertGreaterThan(icon.width, 50)
        XCTAssertGreaterThan(icon.height, 30)
        // The wiper keeps an arc of the glass clear: the road ahead is swept, the top corners are not.
        let size = CGSize(width: 600, height: 360)
        XCTAssertTrue(CardArt.driveWiped(CGPoint(x: 360, y: 270), size))
        XCTAssertTrue(CardArt.driveWiped(CGPoint(x: 360, y: 180), size), "the road's end")
        XCTAssertFalse(CardArt.driveWiped(CGPoint(x: 10, y: 10), size))
        XCTAssertFalse(CardArt.driveWiped(CGPoint(x: 590, y: 10), size))
        // The road runs from the card's bottom edge to its end at the vanishing point.
        let end = CardArt.driveRoadPoint(lane: 0.18, 1)
        XCTAssertEqual(end.x, CardArt.driveVanishing.x, accuracy: 1e-9)
        XCTAssertEqual(end.y, CardArt.driveVanishing.y, accuracy: 1e-9)
        XCTAssertEqual(CardArt.driveRoadPoint(lane: 0.18, 0).y, 1, accuracy: 1e-9)

        // The picture: it draws and moves, and repeats exactly once a bar.
        let a = try XCTUnwrap(Self.render(place: set, at: 0.3))
        let stats = PreviewRenderer.stats(a)
        XCTAssertGreaterThan(stats.meanLuminance, 0.05)
        XCTAssertGreaterThan(stats.variance, 0.001)
        let barLater = try XCTUnwrap(Self.render(place: set, at: 0.3 + bar))
        let again = PreviewRenderer.difference(a, barLater)
        XCTAssertLessThan(again, 0.002, "a bar later the card is as it was")
        let later = try XCTUnwrap(Self.render(place: set, at: 0.3 + 1.5 * beat))
        let moved = PreviewRenderer.difference(a, later)
        if moved <= 0.001 { XCTFail("a beat and a half later the drive card moved only \(moved)") }

        // It looks like no song card and no other place's card.
        let mine = try XCTUnwrap(Self.render(place: set, at: 1.0))
        for c in CreditLibrary.all {
            let other = try XCTUnwrap(Self.render(c, at: 1.0), c.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the drive card and \(c.id) differ by only \(d)") }
        }
        for place in SetLibrary.all where place.creditID == nil && place.id != set.id {
            let other = try XCTUnwrap(Self.render(place: place, at: 1.0), place.id)
            let d = PreviewRenderer.difference(mine, other)
            if d <= 0.02 { XCTFail("the drive card and \(place.id)'s differ by only \(d)") }
        }
    }
}
