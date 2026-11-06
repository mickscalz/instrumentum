/// Short original demo phrases for the built-in instruments (rendered into the demo audio on each release).
/// Original material: no melodies from the inspiring songs.
public enum DemoPhrases {
    public typealias Phrase = [(time: Double, message: MIDIMessage)]

    /// Soft single notes, a pedalled Fmaj9 → Em7 → Dm9 → Cmaj9, a hard low note, a high glassy run, then silence.
    public static let feltGlass: Phrase = {
        var m = Builder()
        for (i, n) in [74, 78, 81, 76, 71, 74].enumerated() { m.note(0.2 + Double(i) * 0.5, UInt8(n), UInt8(38 + i * 3), 0.45) }
        let chords: [[UInt8]] = [[53, 57, 60, 64, 67], [52, 55, 59, 62, 67], [50, 53, 57, 60, 64], [48, 52, 55, 59, 62]]
        for (c, chord) in chords.enumerated() {
            let t = 3.5 + Double(c) * 2.2
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.06, down: true)
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.02, n, UInt8(62 + k * 2), 2.0) }
        }
        m.pedal(12.4, down: false)
        m.note(12.6, 33, 118, 2.0)
        m.pedal(15.0, down: true)
        for (i, n) in [84, 86, 88, 91, 93, 96, 98, 100].enumerated() { m.note(15.1 + Double(i) * 0.11, UInt8(n), 56, 0.3) }
        m.pedal(19.5, down: false)
        return m.sorted
    }()

    /// Long, overlapping E♭ / B♭ / Cm / A♭maj7 chords, then one short chord to show the response.
    public static let orbitPad: Phrase = {
        var m = Builder()
        let chords: [[UInt8]] = [[51, 58, 63, 67, 70], [46, 58, 62, 65, 70], [48, 55, 60, 63, 67], [44, 56, 60, 63, 67]]
        for (c, chord) in chords.enumerated() {
            let t = 0.2 + Double(c) * 5.0
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.03, n, UInt8(78 + k * 4), 6.0) }
        }
        for (k, n) in [55, 58, 62].enumerated() { m.note(21.5 + Double(k) * 0.01, UInt8(n), 100, 0.4) }
        return m.sorted
    }()

    /// Slow C♯-minor colours (C♯m9, Amaj7, F♯m9, G♯sus) held under a drifting line of long flute notes,
    /// then a soft high phrase and a last held note running into the tape's haze.
    public static let honeyTape: Phrase = {
        var m = Builder()
        let chords: [[UInt8]] = [[49, 56, 61, 63, 64], [45, 52, 56, 61, 64], [42, 54, 57, 61, 64], [44, 51, 56, 61, 63]]
        for (c, chord) in chords.enumerated() {
            let t = 0.2 + Double(c) * 4.0
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.04, n, UInt8(58 + k * 3), 3.85) }
        }
        let line: [(Double, UInt8, Double)] = [(1.0, 76, 1.4), (2.6, 75, 0.9), (3.6, 73, 1.8), (5.8, 71, 1.0), (7.0, 73, 1.6),
                                               (9.0, 76, 0.8), (10.0, 78, 1.8), (12.2, 80, 1.2), (13.6, 76, 1.9)]
        for (t, n, length) in line { m.note(t, n, 84, length) }
        for (i, n) in [80, 83, 85, 83, 80].enumerated() { m.note(16.4 + Double(i) * 0.35, UInt8(n), UInt8(50 + i * 4), 0.4) }
        m.note(18.3, 73, 70, 3.0)
        return m.sorted
    }()

    /// B-minor colours (Bm, Gmaj7, Em9, F♯) at 132 BPM: low chords held under the pedal while eighth-note bell
    /// arpeggios ring and echo above them, then one soft chord left to drift.
    public static let hazeBells: Phrase = {
        var m = Builder()
        let eighth = 60.0 / 132 / 2
        let sections: [(low: [UInt8], arp: [UInt8])] = [
            ([47, 54, 62], [71, 74, 78, 85, 83, 78, 74, 69]),
            ([43, 50, 59], [67, 71, 74, 78, 81, 78, 74, 71]),
            ([40, 47, 55], [76, 79, 83, 86, 83, 79, 78, 76]),
            ([42, 49, 58], [78, 82, 85, 88, 85, 82, 78, 73]),
        ]
        for (i, section) in sections.enumerated() {
            let t = 0.2 + Double(i) * 4.5
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.02, down: true)
            for (k, n) in section.low.enumerated() { m.note(t + Double(k) * 0.03, n, 70, 4.2) }
            for (k, n) in section.arp.enumerated() { m.note(t + 0.4 + Double(k) * eighth, n, UInt8(72 + (k % 3) * 10), eighth * 0.8) }
        }
        m.pedal(18.17, down: false); m.pedal(18.22, down: true)
        for (k, n) in [71, 74, 78].enumerated() { m.note(18.3 + Double(k) * 0.05, UInt8(n), 64, 2.5) }
        m.pedal(21.5, down: false)
        return m.sorted
    }()

    /// F♯-major colours at the half-time pocket of 134 (67): F♯maj9, Bmaj9, D♯m9, C♯sus4 to C♯7, F♯6/9. Chords
    /// held under the pedal with a melody on top, so the horn takes the top line: it scoops into fresh phrases and
    /// slurs where the melody is legato (and is held over the chord changes so the chords never steal it).
    public static let cabinFelt: Phrase = {
        var m = Builder()
        let beat = 60.0 / 67
        func at(_ b: Double) -> Double { 0.2 + b * beat }
        /// Chord tones listed top first and pressed top first, a few ms apart.
        func chord(_ b: Double, _ notes: [UInt8], _ v: UInt8, _ beats: Double) {
            m.pedal(at(b) - 0.03, down: false); m.pedal(at(b) + 0.02, down: true)
            for (k, n) in notes.enumerated() { m.note(at(b) + Double(k) * 0.008, n, v, beats * beat) }
        }
        func tune(_ notes: [(b: Double, n: UInt8, beats: Double, v: UInt8)]) {
            for x in notes { m.note(at(x.b), x.n, x.v, x.beats * beat) }
        }
        chord(0, [68, 65, 61, 54, 42], 62, 3.95)                  // F♯maj9
        tune([(1.0, 70, 1.05, 76), (2.0, 73, 1.6, 84), (3.5, 75, 0.9, 80)])
        chord(4, [70, 66, 63, 59, 47], 60, 3.95)                  // Bmaj9, under the held D♯
        tune([(4.35, 78, 1.2, 88), (5.5, 77, 0.55, 78), (6.0, 75, 1.4, 80), (7.6, 73, 0.6, 72)])
        chord(8, [66, 65, 61, 58, 51, 39], 58, 3.95)              // D♯m9, under the held C♯
        tune([(8.15, 75, 0.9, 80), (9.0, 73, 1.05, 76), (10.0, 70, 1.6, 74), (11.75, 68, 0.4, 70)])
        chord(12, [66, 59, 56, 49, 37], 60, 1.95)                 // C♯sus4
        tune([(12.1, 73, 1.0, 84), (13.0, 75, 0.55, 86), (13.5, 77, 1.6, 90), (15.0, 78, 0.6, 80)])
        chord(14, [65, 59, 56, 49, 37], 60, 1.95)                 // C♯7, under the held E♯
        chord(16, [70, 68, 63, 61, 54, 42], 58, 4.5)              // F♯6/9: its top note starts a fresh horn phrase
        tune([(16.6, 73, 0.9, 70), (17.4, 78, 2.8, 66)])
        m.pedal(at(20.6), down: false)
        return m.sorted
    }()

    /// C♯-major colours at 82 BPM for 40 s, long enough to hear the wall build: held chords (C♯maj9, F♯maj9,
    /// A♯m9, G♯sus, C♯maj9, F♯maj9, then C♯6/9) under a ticking eighth-note celesta figure that keeps playing.
    public static let morningBox: Phrase = {
        var m = Builder()
        let eighth = 60.0 / 82 / 2
        let sections: [(chord: [UInt8], figure: [UInt8])] = [
            ([37, 49, 56, 60, 63], [73, 80, 75, 77, 84, 80, 75, 72]),
            ([42, 54, 58, 61, 65], [78, 82, 85, 77, 82, 78, 73, 77]),
            ([46, 58, 61, 65, 68], [77, 80, 84, 82, 77, 80, 73, 75]),
            ([44, 56, 61, 63], [75, 80, 85, 80, 73, 75, 80, 78]),
            ([37, 49, 56, 60, 63], [73, 77, 80, 84, 85, 84, 80, 77]),
            ([42, 54, 58, 61, 65], [82, 85, 89, 85, 82, 78, 77, 73]),
        ]
        let length = 16 * eighth
        for (i, section) in sections.enumerated() {
            let t = 0.2 + Double(i) * length
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.02, down: true)
            for (k, n) in section.chord.enumerated() { m.note(t + Double(k) * 0.02, n, 64, length - 0.08) }
            for k in 0..<16 {
                let n = section.figure[k % 8]
                m.note(t + Double(k) * eighth, n, UInt8(k % 2 == 0 ? 80 : 64), eighth * 0.8)
            }
        }
        let end = 0.2 + 6 * length
        m.pedal(end - 0.03, down: false); m.pedal(end + 0.02, down: true)
        for (k, n) in [37, 49, 56, 63, 70].enumerated() { m.note(end + Double(k) * 0.02, UInt8(n), 60, 5) }
        for (k, n) in [73, 77, 80, 84, 85].enumerated() { m.note(end + 0.5 + Double(k) * 0.45, UInt8(n), 66, 3.5) }
        m.pedal(end + 5.4, down: false)
        return m.sorted
    }()

    /// A♭-major colours at a half-time 60 for about 24 s: one long chord to the bar (A♭maj9, D♭maj7, Fm9, E♭sus4,
    /// D♭maj9, then A♭maj9 left to hang) under a slow top line, so the swell and the breath are heard. Each chord lets go
    /// just before the next comes in (a shared note would otherwise be released by the old chord's note-off).
    public static let polarChoir: Phrase = {
        var m = Builder()
        let bar = 4.0   // four beats at 60
        let chords: [[UInt8]] = [[44, 51, 55, 58, 60],   // A♭maj9
                                 [49, 56, 60, 65],       // D♭maj7
                                 [41, 51, 55, 56, 60],   // Fm9
                                 [39, 46, 56, 58, 63],   // E♭sus4
                                 [49, 56, 60, 63, 65]]   // D♭maj9
        for (c, chord) in chords.enumerated() {
            let t = 0.2 + Double(c) * bar
            for (k, n) in chord.enumerated() { m.note(t + Double(k) * 0.04, n, UInt8(58 + k * 3), bar - 0.1 - Double(k) * 0.04) }
        }
        let end = 0.2 + 5 * bar
        for (k, n) in [44, 51, 55, 58, 60].enumerated() { m.note(end + Double(k) * 0.04, UInt8(n), 60, 5.0) }
        // The top line, half a beat behind each chord: (beat from the start, note, beats held).
        let line: [(Double, UInt8, Double)] = [(0.5, 72, 1.9), (2.5, 70, 1.4), (4.5, 68, 2.4), (7.0, 72, 1.1),
                                               (8.5, 75, 1.9), (10.5, 72, 1.4), (12.5, 68, 1.9), (14.5, 70, 1.4),
                                               (16.5, 77, 1.9), (18.5, 75, 1.4), (20.5, 72, 4.3)]
        for (b, n, beats) in line { m.note(0.2 + b, n, 78, beats) }
        return m.sorted
    }()

    /// D-major colours at 68 for about 22 s: one pedalled bar each of D, F♯m7, Bm, G and Asus4, the bass on the bar and
    /// the chord rolled over it, struck again softly on beat three, with a few short right-hand runs (so the sparks and the
    /// wakes show), then a soft D chord left to ring.
    public static let planktonKeys: Phrase = {
        var m = Builder()
        let beat = 60.0 / 68, bar = 4 * beat
        let bars: [(bass: UInt8, chord: [UInt8])] = [(38, [50, 57, 62, 66]),   // D
                                                     (42, [54, 57, 61, 64]),   // F♯m7
                                                     (47, [54, 59, 62, 66]),   // Bm
                                                     (43, [50, 59, 62, 67]),   // G
                                                     (45, [52, 57, 62, 64])]   // Asus4
        // The right hand over each bar: (seconds into the bar, note, velocity).
        let tops: [[(Double, UInt8, UInt8)]] = [
            [(beat, 74, 58)],
            [(2.21, 73, 60), (2.38, 76, 62), (2.55, 78, 64), (2.72, 81, 66)],
            [(beat, 78, 58), (2 * beat, 74, 54)],
            [(2.30, 86, 66), (2.45, 83, 64), (2.60, 79, 62), (2.75, 78, 60), (2.90, 74, 58)],
            [(beat, 76, 56), (2.43, 74, 58), (2.58, 76, 60), (2.73, 78, 62), (2.88, 81, 64), (3.03, 85, 66)],
        ]
        for (b, section) in bars.enumerated() {
            let t = 0.2 + Double(b) * bar
            m.pedal(t - 0.03, down: false); m.pedal(t + 0.06, down: true)
            m.note(t, section.bass, 70, 2 * beat)
            for (k, n) in section.chord.enumerated() { m.note(t + 0.03 * Double(k + 1), n, UInt8(54 + 2 * k), 1.4 * beat) }
            for (k, n) in section.chord.enumerated() { m.note(t + 2 * beat + 0.02 * Double(k), n, 46, 0.9 * beat) }
            for (dt, n, v) in tops[b] { m.note(t + dt, n, v, 0.3) }
        }
        let end = 0.2 + 5 * bar
        m.pedal(end - 0.03, down: false); m.pedal(end + 0.06, down: true)
        for (k, n) in [38, 50, 57, 62, 66, 69].enumerated() { m.note(end + 0.04 * Double(k), UInt8(n), UInt8(50 + 2 * k), 4.0) }
        m.note(end + 1.0, 81, 52, 0.6)
        m.pedal(end + 4.4, down: false)
        return m.sorted
    }()

    /// Hirajōshi on E (E, F, A, B, C and their octaves) for about 20 s, slow and with space, each phrase falling to an E:
    /// three presses on the wheel, each a moment after the pluck and then let go (A up a whole tone to B, B up a semitone
    /// to C, E up a semitone to F), pressure on two long notes for yuri, and a last open fifth, E and B, left to ring.
    /// The wheel and pressure reach every sounding string, so each press and each swell falls on a string sounding
    /// alone; and no rest is long enough (1.5 s) to re-root the open strings off the opening E.
    public static let teaHouseKoto: Phrase = {
        var m = Builder()
        // A low E and its octave together: the phrase's root, so the open strings ring in E.
        m.note(0.20, 52, 84, 1.60); m.note(0.23, 64, 70, 1.57)
        m.note(2.00, 71, 70, 0.75)                                                        // B
        m.note(2.85, 69, 74, 1.75)                                                        // A, pressed up to B and back
        m.press(3.30, from: 0, to: 2, over: 0.18); m.press(3.90, from: 2, to: 0, over: 0.25)
        m.note(4.75, 65, 66, 0.45)                                                        // F
        m.note(5.30, 64, 76, 2.25)                                                        // E, with yuri
        m.pressure(5.42, from: 0, to: 1, over: 0.30); m.pressure(6.90, from: 1, to: 0, over: 0.30)
        // A run up the scale that turns at B and falls again.
        for (i, n) in [57, 59, 60, 64, 65, 69].enumerated() { m.note(8.0 + 0.4 * Double(i), UInt8(n), UInt8(64 + 2 * i), i == 5 ? 0.4 : 0.36) }
        m.note(10.55, 71, 80, 1.45)                                                       // B, pressed up to C and back
        m.press(11.05, from: 0, to: 1, over: 0.16); m.press(11.55, from: 1, to: 0, over: 0.22)
        m.note(12.10, 69, 70, 0.38); m.note(12.55, 65, 66, 0.35)                          // A, F
        m.note(13.05, 64, 70, 1.20)                                                       // E, pressed up to F and back
        m.press(13.45, from: 0, to: 1, over: 0.15); m.press(13.85, from: 1, to: 0, over: 0.20)
        // Down to the low E.
        m.note(14.40, 60, 66, 0.40)                                                       // C
        m.note(14.90, 59, 72, 1.95)                                                       // B, with yuri
        m.pressure(15.02, from: 0, to: 1, over: 0.30); m.pressure(16.40, from: 1, to: 0, over: 0.30)
        m.note(17.30, 52, 88, 3.20); m.note(17.33, 59, 78, 3.17)                          // the open fifth, rung together
        return m.sorted
    }()

    /// The five notes D, F, G, A, C for about 22 s, in three long breaths with silence between them (where the mountain
    /// echo answers), all inside D4–D6 so nothing folds: a low D rising out of air, F, and a G pressed into meri; a hard D
    /// an octave up bursting with breath (muraiki, the demo's one accent), C, and a long A sunk a full meri and let back
    /// up; then up to the high C and down to a D that sinks once more before the breath runs out. Each meri press is
    /// channel pressure eased in and out while one note sounds alone (the pressure reaches every sounding note), and is
    /// let go before the next note starts (a new note hears the pressure as it is). The wheel is never moved.
    public static let zenShakuhachi: Phrase = {
        var m = Builder()
        // The first breath.
        m.note(0.30, 62, 72, 2.45)                                                        // D4 (ro)
        m.note(2.95, 65, 64, 0.80)                                                        // F4
        m.note(3.85, 67, 70, 2.70)                                                        // G4, meri
        m.pressure(4.40, from: 0, to: 0.75, over: 0.45); m.pressure(5.45, from: 0.75, to: 0, over: 0.45)
        // The second, after a silence.
        m.note(8.25, 74, 122, 1.70)                                                       // D5, muraiki
        m.note(10.05, 72, 74, 0.70)                                                       // C5
        m.note(10.85, 69, 80, 2.70)                                                       // A4, a full meri
        m.pressure(11.60, from: 0, to: 1, over: 0.50); m.pressure(12.70, from: 1, to: 0, over: 0.50)
        // The third, after another.
        m.note(15.60, 79, 70, 0.75)                                                       // G5
        m.note(16.45, 81, 76, 0.75)                                                       // A5
        m.note(17.30, 84, 82, 1.30)                                                       // C6
        m.note(18.70, 81, 70, 0.55)                                                       // A5
        m.note(19.30, 74, 74, 3.30)                                                       // D5, meri
        m.pressure(19.90, from: 0, to: 0.70, over: 0.55); m.pressure(21.00, from: 0.70, to: 0, over: 0.60)
        return m.sorted
    }()

    /// G major at 120 for about 20 s, bright and busy as the reef: sixteenth-note runs over a bass below C3 (where the
    /// mallets soften by themselves), and one long F♯ over D and then C, rolled under a pressure crescendo (a note held
    /// 0.3 s rolls, and leaning in quickens the roll and swells its strokes) until it resolves up to G; then the runs again,
    /// and a last G chord struck and left to ring. Every other key lets go well inside 0.3 s, so only the long note rolls,
    /// and each bar rings on after its key is up (a marimba has no dampers).
    public static let reefMarimba: Phrase = {
        var m = Builder()
        let s = 60.0 / 120 / 4   // a sixteenth
        /// Sixteenths from `t`, each let go before the next, leaning on each beat and a little on each half beat.
        func run(_ t: Double, _ notes: [UInt8], _ v: UInt8) {
            for (k, n) in notes.enumerated() {
                let accent: UInt8 = k % 4 == 0 ? 12 : (k % 2 == 0 ? 5 : 0)
                m.note(t + Double(k) * s, n, v + accent, 0.8 * s)
            }
        }
        /// A bass bar, struck and let go at once: it rings on.
        func bass(_ t: Double, _ n: UInt8) { m.note(t, n, 78, 0.2) }
        bass(0.2, 43)                                                                     // G
        run(0.2, [67, 69, 71, 74, 76, 74, 71, 74, 79, 81, 83, 81, 79, 76, 74, 71], 70)
        bass(2.2, 40)                                                                     // Em
        run(2.2, [76, 79, 83, 79, 76, 71, 67, 71, 76, 78, 79, 83, 88, 83, 79, 76], 70)
        bass(4.2, 36)                                                                     // C
        run(4.2, [72, 76, 79, 84, 83, 79, 76, 72, 71, 74, 79, 81, 79, 76, 74, 76], 70)
        // The long F♯ over D, then C: it rolls from 6.5 s, and the pressure swells the roll until it resolves up to G.
        bass(6.2, 38); m.note(6.2, 78, 96, 3.95)
        m.pressure(6.7, from: 0, to: 1, over: 2.6)
        bass(8.2, 36)
        m.pressure(10.05, from: 1, to: 0, over: 0.12)
        bass(10.2, 43)                                                                    // G
        run(10.2, [79, 83, 86, 91, 90, 86, 83, 79, 81, 83, 86, 88, 86, 83, 81, 79], 72)
        bass(12.2, 40)                                                                    // Em
        run(12.2, [88, 86, 83, 79, 76, 79, 83, 79, 76, 74, 71, 67, 64, 67, 71, 74], 70)
        bass(14.2, 45); bass(15.2, 38)                                                    // Am, D
        run(14.2, [72, 76, 81, 84, 83, 81, 76, 72, 74, 78, 81, 84, 83, 81, 78, 74], 70)
        bass(16.2, 43)                                                                    // G
        run(16.2, [71, 74, 79, 83, 86, 83, 79, 74], 68)
        for (k, n) in [79, 83, 86, 91].enumerated() { m.note(17.2 + 0.25 * Double(k), UInt8(n), UInt8(64 + 4 * k), 0.2) }
        // The last chord, four mallets and the bass together, left to ring.
        for (k, n) in [43, 67, 71, 74, 79].enumerated() { m.note(18.2 + 0.012 * Double(k), UInt8(n), 74, 0.2) }
        return m.sorted
    }()

    /// D minor at 86 BPM for about 25 s, the way Single Note Grand plays (Storms spec §4.2): one note, D5, struck alone on
    /// the eighths for two bars, a little louder on each beat and as it goes (the grand hears it repeated from the fourth
    /// strike), and on through two more as a low D and then a low B♭ join it. Then it opens into chords: G minor, the
    /// note slowing to the beat; an A suspended chord, over which the note is held and pressed into (a swell of pressure:
    /// the piano becomes a voice); the note falls to C♯ as the chord resolves to A, under the pressure, before the
    /// pressure lets go and a D minor chord with the D on top rings out. Original material, nothing quoted from any record.
    public static let singleNoteGrand: Phrase = {
        var m = Builder()
        let beat = 60.0 / 86
        func t(_ beats: Double) -> Double { 0.3 + beats * beat }
        // The one note, D5, on the eighths for four bars.
        for k in 0..<32 {
            let accent = k % 2 == 0 ? 4 : 0
            let rise = Int((14 * Double(k) / 31).rounded())
            m.note(t(0.5 * Double(k)), 74, UInt8(50 + rise + accent), 0.4 * beat)
        }
        // Bars 3 and 4: a low D, then a low B♭, under it.
        m.note(t(8), 38, 56, 4 * beat - 0.05); m.note(t(8) + 0.02, 45, 50, 4 * beat - 0.07)
        m.note(t(12), 34, 58, 4 * beat - 0.05); m.note(t(12) + 0.02, 41, 52, 4 * beat - 0.07)
        // Bar 5: G minor, rolled up softly, and the note on the beat.
        for (k, n) in [(43, 60), (50, 56), (67, 62), (70, 64)].enumerated() {
            let start = t(16) + 0.025 * Double(k)
            m.note(start, UInt8(n.0), UInt8(n.1), t(20) - 0.05 - start)
        }
        for (k, v) in [68, 62, 64, 60].enumerated() { m.note(t(16 + Double(k)), 74, UInt8(v), 0.8 * beat) }
        // Bars 6 and 7: an A suspended chord held under the note, pressed into until the piano sings; the note falls to C♯
        // as the chord resolves to A, and the pressure lets go.
        for (k, n) in [(45, 58), (52, 54), (64, 58), (69, 60)].enumerated() {
            let start = t(20) + 0.025 * Double(k)
            m.note(start, UInt8(n.0), UInt8(n.1), t(28) - 0.05 - start)
        }
        m.note(t(20), 74, 70, t(24) - 0.05 - t(20))
        m.note(t(24), 73, 66, t(28) - 0.05 - t(24))
        m.pressure(t(20.25), from: 0, to: 0.9, over: 3.25 * beat)
        m.pressure(t(25.5), from: 0.9, to: 0, over: 2 * beat)
        // Bars 8 and 9: D minor, rolled up to the D on top, left to ring.
        for (k, n) in [(38, 58), (45, 54), (53, 56), (62, 60), (65, 62), (69, 64), (74, 70)].enumerated() {
            let start = t(28) + 0.025 * Double(k)
            m.note(start, UInt8(n.0), UInt8(n.1), t(35.6) - start)
        }
        return m.sorted
    }()

    /// F♯ minor at 118 BPM for about 20 s, the way Blue Depth plays: the right hand holds a chord from C3 up and the arp
    /// blinks it on the sixteenths in the order it was pressed (C♯, A, F♯, falling), through the dotted-eighth echo,
    /// while the left hand strikes a big bass note below C3 once a bar (F♯, D, D, B, B, C♯, F♯), so the same blinking
    /// chord turns from F♯m to Dmaj7 to Bm9. An E joins it for a bar; pressure swells over the B (the filter opens and
    /// the ghosts come forward); then a bar of C♯, home to F♯m, and everything lets go to ring out through the echo.
    public static let blueDepth: Phrase = {
        var m = Builder()
        let beat = 60.0 / 118
        func t(_ beats: Double) -> Double { 0.3 + beats * beat }
        // The chord the arp blinks, pressed C♯5, A4, F♯4 (40 ms apart, so it keeps that order).
        m.note(t(0), 73, 80, t(36) - t(0))                                // C♯5 rings on through every chord
        m.note(t(0) + 0.04, 69, 76, t(24) - 0.03 - (t(0) + 0.04))         // A4
        m.note(t(0) + 0.08, 66, 74, t(24) - 0.03 - (t(0) + 0.08))         // F♯4
        m.note(t(12), 76, 76, t(16) - 0.03 - t(12))                       // E5 joins for a bar
        // The left hand's big bass hits, below C3.
        for (b, n) in [42, 38, 38, 35, 35, 37, 42].enumerated() { m.note(t(4 + 4 * Double(b)), UInt8(n), 96, 1.5 * beat) }
        m.note(t(32), 42, 96, t(37.5) - t(32))                            // F♯2, the last, held as everything lets go
        // Lean in over the B.
        m.pressure(t(17), from: 0, to: 0.8, over: 1.6); m.pressure(t(21.5), from: 0.8, to: 0, over: 1.2)
        // A bar of C♯ (E♯4 and G♯4 join the C♯5 that rings on), then home to F♯m.
        m.note(t(24), 65, 76, t(28) - 0.03 - t(24)); m.note(t(24) + 0.012, 68, 78, t(28) - 0.03 - (t(24) + 0.012))
        m.note(t(28), 66, 76, t(36) - t(28)); m.note(t(28) + 0.012, 69, 78, t(36) - (t(28) + 0.012))
        return m.sorted
    }()

    /// F minor at 124 BPM for about 23.5 s, the way Endless Rise plays (Storms spec §4.1): a minor chord (F2 C3 F3 A♭3
    /// C4) rolled softly and held for eight bars while the pad ducks on every beat and the riser climbs over it; bars 5
    /// and 6 add an eighth-note figure inside the chord (C3 F3 A♭3 F3), bars 7 and 8 a line that climbs from A♭4 to C6,
    /// up a third and back a step on every beat and louder as it goes, under a swell of pressure, so the tension gathers;
    /// then, on the downbeat of bar 9, a hard low F minor chord (F2 C3 F3 A♭3, at 118 and more within 15 ms): the drop.
    /// The riser resolves into it and fades, and the pad pulses on alone for four bars before everything lets go.
    /// Original material, nothing quoted from any record. The drop is Excitement's (the riser takes the hard chord
    /// only once tension has gathered), so the demo is rendered as the app plays it: its notes reach a scene director
    /// whose cue reaches the engine every frame (`DemoRenderTests.renderPlayed`).
    public static let endlessRise: Phrase = {
        var m = Builder()
        let beat = 60.0 / 124
        func t(_ beats: Double) -> Double { 0.3 + beats * beat }
        // The held chord, rolled up softly (30 ms apart, so it's no hard chord), let go just before the drop.
        for (k, n) in [41, 48, 53, 56, 60].enumerated() {
            let start = t(0) + 0.03 * Double(k)
            m.note(start, UInt8(n), UInt8(64 + 2 * k), t(32) - 0.08 - start)
        }
        // Bars 5 and 6: an eighth-note figure inside the chord, the pulse made a part.
        let figure: [UInt8] = [48, 53, 56, 53]   // C3 F3 A♭3 F3
        for k in 0..<16 { m.note(t(16 + 0.5 * Double(k)), figure[k % 4], UInt8(60 + k), 0.4 * beat) }
        // Bars 7 and 8: the climb, up the F minor scale a third and back a step on every beat, from A♭4 to C6.
        let scale: [UInt8] = [60, 61, 63, 65, 67, 68, 70, 72, 73, 75, 77, 79, 80, 82, 84, 85, 87, 89]   // C4 … F6
        let steps = [0, 2, 1, 3, 2, 4, 3, 5, 4, 6, 5, 7, 6, 8, 7, 9]
        for (k, d) in steps.enumerated() {
            let velocity = 64 + Int((2.4 * Double(k)).rounded())
            m.note(t(24 + 0.5 * Double(k)), scale[5 + d], UInt8(velocity), 0.4 * beat)
        }
        m.pressure(t(24), from: 0, to: 0.75, over: 7.5 * beat)
        m.pressure(t(31.6), from: 0.75, to: 0, over: 0.15)
        // Bar 9: the drop, held for four bars.
        for (k, n) in [41, 48, 53, 56].enumerated() {
            let start = t(32) + 0.005 * Double(k)
            m.note(start, UInt8(n), UInt8(124 - 2 * k), t(48) - start)
        }
        return m.sorted
    }()

    private struct Builder {
        var events: Phrase = []
        mutating func note(_ t: Double, _ n: UInt8, _ v: UInt8, _ length: Double) {
            events.append((t, .noteOn(channel: 0, note: n, velocity: v)))
            events.append((t + length, .noteOff(channel: 0, note: n, velocity: 64)))
        }
        mutating func pedal(_ t: Double, down: Bool) {
            events.append((t, .controlChange(channel: 0, controller: 64, value: down ? 127 : 0)))
        }
        /// The pitch wheel moved as a hand moves it: eased from `from` to `to` semitones (of its ±2) in 10 ms steps over
        /// `length` seconds, landing exactly on `to` (at rest, 8192, for 0).
        mutating func press(_ t: Double, from: Double, to: Double, over length: Double) {
            let steps = max(1, Int((length / 0.01).rounded()))
            for k in 1...steps {
                let s: Double = from + (to - from) * Self.ease(Double(k) / Double(steps))
                events.append((t + length * Double(k) / Double(steps), .pitchBend(channel: 0, value: Self.wheel(s))))
            }
        }
        /// Channel pressure eased from `from` to `to` (0…1) in 20 ms steps over `length` seconds.
        mutating func pressure(_ t: Double, from: Double, to: Double, over length: Double) {
            let steps = max(1, Int((length / 0.02).rounded()))
            for k in 1...steps {
                let p: Double = min(1, max(0, from + (to - from) * Self.ease(Double(k) / Double(steps))))
                events.append((t + length * Double(k) / Double(steps), .channelPressure(channel: 0, value: UInt8((p * 127).rounded()))))
            }
        }
        /// The wheel's 14 bits for `semitones` of its ±2: 8192 at rest, 16383 full up, 0 full down (as the Sound Core reads it).
        static func wheel(_ semitones: Double) -> UInt16 {
            let s: Double = min(2, max(-2, semitones))
            let span: Double = s >= 0 ? 8191 : 8192
            return UInt16((8192 + s / 2 * span).rounded())
        }
        /// Smoothstep: a hand's ease in and out.
        static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        var sorted: Phrase { events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element) }
    }
}
