import SwiftUI
import InStrumCore

/// Original living art for each "Inspired by" card, drawn in code from the song's feeling (never artwork,
/// photos or logos). The song's tempo is hidden in the motion: everything breathes at `pulsePeriod`.
/// A set born from its place rather than a song (no credit) has a place card instead, drawn from its world and
/// breathing at a slow fixed pulse of its own (`placeBreath`).
enum CardArt {
    case comeBackToEarth, innerbloom, musicToWatchBoysTo, highByTheBeach, stay, dunno, wings, happinessIsAButterfly
    case runaway
    case underwater
    case fade
    case holdMyLiquor
    /// Place cards (see `place(for:)`).
    case teaHouseSnow, zenRockGarden
    case greatBarrierReef
    case neonNightDrive

    /// The place cards breathe at one slow fixed pulse, 48 breaths a minute: with no song there is no tempo to hide.
    static let placePulse = 60.0 / 48
    /// The reef's place card breathes a little quicker, 52 breaths a minute: the reef is colourful and alive (spec §11).
    static let reefPulse = 60.0 / 52
    /// The drive's place card breathes at the drive's own default tempo, 120 (Replicant Brass's Tempo, Fire & Neon spec
    /// §4.3): with no song, the city keeps the car's time.
    static let drivePulse = 60.0 / 120

    /// The reef card's three coral heads, from the bass end to the treble as Coral Pulse lays out its groups (a brain
    /// coral, a plate coral and a staghorn): x and the base's y as fractions of the card, a size in points at 600 × 360,
    /// how many polyps each carries, and how many of them are lit: 1, 4 and 10, the bar's 1 : 4 : 10 tuning (the card's
    /// easter egg).
    static let reefCoralHeads: [(x: CGFloat, y: CGFloat, size: CGFloat, polyps: Int, lit: Int)] = [
        (0.565, 0.935, 64, 9, 1), (0.745, 0.885, 58, 12, 4), (0.905, 0.86, 50, 10, 10)]

    /// How long each coral head's lit polyps flare after a breath, in breaths: as long as the bar's partials ring, the
    /// double octave 4 and the third 10 times shorter than the note.
    private static let reefRing: [Double] = [0.8, 0.2, 0.08]

    /// Each coral head's fluorescence (reef corals fluoresce): green, orange and pink.
    private static let reefGlow: [(red: Double, green: Double, blue: Double)] = [(0.40, 1.0, 0.50), (1.0, 0.58, 0.18), (1.0, 0.36, 0.70)]

    /// The school's curve over the coral heads: a cubic Bézier's four points, as fractions of the card.
    private static let reefSchool: [CGPoint] = [CGPoint(x: 0.30, y: 0.70), CGPoint(x: 0.46, y: 0.46), CGPoint(x: 0.84, y: 0.44),
                                                CGPoint(x: 1.03, y: 0.66)]

    /// Soft corals swaying behind the heads: x and the base's y as fractions of the card, a height in points at 600 × 360,
    /// a phase for the sway and a seed for each frond's reach.
    private static let reefFans: [(x: CGFloat, y: CGFloat, height: CGFloat, phase: Double, seed: Int)] = [
        (0.47, 0.90, 40, 0, 23), (0.655, 0.86, 34, 1.7, 32), (0.985, 0.82, 42, 3.1, 49)]

    /// The Tea House Snow card's thirteen faint strings along the lower edge (the koto's thirteen: the card's easter
    /// egg): y as fractions of the card, from the far string down.
    static let teaHouseStrings: [CGFloat] = (0..<13).map { 0.872 + 0.0095 * CGFloat($0) }

    /// The tea's three steam wisps on the Tea House Snow card: where each leaves the bowl (x, a fraction of the width),
    /// how many curls it carries up its height (f), its sway at the bowl and how it grows as it climbs (a0, a1), its
    /// drift (fractions of the width), its phase, and how high it climbs (a fraction of the height).
    private static let steamWisps: [(x: Double, f: Double, a0: Double, a1: Double, drift: Double, phase: Double, top: Double)] = [
        (0.62, 1.3, 0.012, 0.055, -0.11, 0.0, 0.74), (0.655, 1.9, 0.008, 0.040, -0.05, 2.1, 0.62),
        (0.69, 1.1, 0.016, 0.065, -0.17, 4.0, 0.56)]

    /// The Zen Rock Garden card's five bamboo rings along the top (the shakuhachi's five holes: the card's easter egg): the
    /// nodes of the eave's bamboo pole, x as fractions of the card, left to right.
    static let rockGardenRings: [CGFloat] = [0.14, 0.32, 0.50, 0.68, 0.86]

    /// The eave's bamboo pole that carries them across the top of the Zen Rock Garden card: its top and bottom edges, as
    /// fractions of the card's height.
    static let rockGardenPole: ClosedRange<CGFloat> = 0.035...0.078

    /// The Zen Rock Garden card's five stones in three groups, each group on a moss island inside its raked rings: the
    /// group's centre (fractions of the card), its innermost ring's half-width and its moss island's (points at 600 wide),
    /// the rings' squash (height over width: the gravel seen from the veranda), and its stones (offset from the centre,
    /// half-width and height, in points).
    static let rockGardenGroups: [(x: CGFloat, y: CGFloat, ring: CGFloat, moss: CGFloat, squash: CGFloat,
                                   stones: [(dx: CGFloat, dy: CGFloat, half: CGFloat, tall: CGFloat)])] = [
        (0.225, 0.585, 56, 42, 0.27, [(-13, 2, 14, 44), (19, 6, 16, 19)]),
        (0.530, 0.465, 38, 28, 0.24, [(0, 1, 18, 14)]),
        (0.800, 0.625, 48, 36, 0.28, [(-10, 3, 14, 30), (17, 6, 9, 14)])]

    /// The Stay card's six-armed frost stars (x, y as fractions of the card, radius in points at 600 × 360): round the
    /// edges, clear of the liner notes (top right), the title block (bottom left) and the Listen button.
    static let stayFrost: [(CGFloat, CGFloat, CGFloat)] = [(0.05, 0.10, 16), (0.13, 0.05, 9), (0.03, 0.24, 8),
                                                         (0.955, 0.22, 13), (0.90, 0.15, 7), (0.04, 0.55, 10),
                                                         (0.10, 0.60, 6), (0.955, 0.70, 13), (0.88, 0.76, 7)]

    /// The Wings card's six brighter stars (the track number): x, y as fractions of the card, arm length in points at
    /// 600 × 360. High in the sky, above the curtains and clear of the liner notes (top right).
    static let wingsStars: [(CGFloat, CGFloat, CGFloat)] = [(0.07, 0.11, 7), (0.25, 0.06, 5), (0.43, 0.16, 6),
                                                          (0.64, 0.21, 5), (0.80, 0.17, 7), (0.94, 0.30, 5)]

    /// The Happiness Is a Butterfly card's thirteen glow motes (the track number): x, y as fractions of the card, the
    /// outer radius of each mote's glow in points at 600 × 360. Strung along the glowing waterline and in the water at the
    /// right, clear of the liner notes (top right), the title block (bottom left) and the Listen button.
    static let butterflyMotes: [(CGFloat, CGFloat, CGFloat)] = [(0.06, 0.58, 9), (0.15, 0.62, 7), (0.24, 0.56, 10),
                                                              (0.33, 0.63, 8), (0.41, 0.58, 7), (0.50, 0.61, 11),
                                                              (0.58, 0.56, 7), (0.66, 0.62, 9), (0.74, 0.57, 8),
                                                              (0.80, 0.66, 10), (0.88, 0.60, 8), (0.95, 0.70, 9),
                                                              (0.86, 0.77, 7)]

    /// The Underwater card's sonar: its centre (fractions of the card) and its dial's radius (a fraction of the height),
    /// right of the title block and below the liner notes.
    static let underwaterSonar: (x: CGFloat, y: CGFloat, radius: CGFloat) = (0.74, 0.44, 0.30)

    /// The Underwater card's faint dial: one tick per pitch class, C at the top and round clockwise, as on a clock.
    static let underwaterDialTicks = 12

    /// Where the Underwater card's sweep rests on its dial: F♯ (pitch class 6, opposite C), the song's key.
    static let underwaterSweep = 6

    /// The Underwater card's seven bubbles (the track number), rising on the left, clear of the words: x (a fraction of
    /// the width), radius in points at 600 × 360, how many beats one rise takes (the bigger, the quicker), and where in
    /// its rise each starts.
    static let underwaterBubbles: [(x: CGFloat, radius: CGFloat, beats: Double, phase: Double)] = [
        (0.14, 4.2, 14, 0.08), (0.20, 7.0, 10, 0.55), (0.27, 3.6, 16, 0.31), (0.33, 6.0, 11, 0.83),
        (0.39, 4.8, 13, 0.20), (0.24, 8.0, 9, 0.68), (0.44, 3.8, 15, 0.44)]

    /// A pitch class's place on the Underwater card's dial: radians from the +x axis, clockwise on screen (y down), so C
    /// (0) sits at the top and F♯ (6) at the bottom.
    static func dialAngle(_ pitchClass: Int) -> Double { (Double(pitchClass) / 12 - 0.25) * 2 * Double.pi }

    /// The Underwater card's sonar rings at `t`: one leaves the centre on every beat and spreads past the dial over three
    /// beats as it fades (radius a fraction of the dial's, opacity), so the picture pulses with the song and repeats
    /// exactly once a beat.
    static func sonarRings(at t: Double, pulse: Double) -> [(radius: Double, opacity: Double)] {
        let beat: Double = t / pulse
        let phase: Double = beat - floor(beat)
        return (0..<3).map { (j: Int) -> (radius: Double, opacity: Double) in
            let age: Double = (phase + Double(j)) / 3
            let fade: Double = 1 - age
            return (radius: 0.05 + 1.35 * age, opacity: 0.55 * fade * fade)
        }
    }

    /// The FADE card's wall cloud: its centre (fractions of the card), its radius (a fraction of the width) and how flat
    /// it lies (its height over its width, seen from beneath and afar), right of the words and under the liner notes.
    static let fadeRing: (x: CGFloat, y: CGFloat, radius: CGFloat, tilt: CGFloat) = (0.64, 0.40, 0.29, 0.42)

    /// The FADE card's core: the green a storm's core pulls the light to.
    static let fadeCore: (red: Double, green: Double, blue: Double) = (0.35, 0.55, 0.40)

    /// The FADE card's ring turns once a bar: four beats of the felt pulse.
    static let fadeBeatsPerTurn = 4.0

    /// The FADE card's inflow bands: eight, the riser's eight octaves, each this fraction of the radius of the one
    /// outside it.
    static let fadeBandCount = 8
    static let fadeBandRatio = 0.78

    /// How far round the FADE card's ring has turned at `t` (0…1): once a bar.
    static func fadeTurn(at t: Double, pulse: Double) -> Double {
        let turns: Double = t / (fadeBeatsPerTurn * pulse)
        return turns - floor(turns)
    }

    /// The FADE card's breath at `t` (0…1): the core swells in on the downbeat and settles by the half bar, once a bar.
    static func fadeBreath(at t: Double, pulse: Double) -> Double {
        let bars: Double = t / (fadeBeatsPerTurn * pulse)
        return 0.5 + 0.5 * cos(2 * Double.pi * bars)
    }

    /// The pad's pulse on the FADE card at `t` (0.55…1): the ring's lit edge dims straight down on every beat and comes
    /// back over 60% of it ((1 − s)², the engine's own duck), so the light pumps as the pad does.
    static func fadePump(at t: Double, pulse: Double) -> Double {
        let beats: Double = t / pulse
        let s: Double = min(1, (beats - floor(beats)) / 0.6)
        return 1 - 0.45 * (1 - s) * (1 - s)
    }

    /// The FADE card's eight inflow bands at `t`, outermost first: each one's radius (a fraction of the ring's), its
    /// opacity and how far round its two arms have turned. They close in on the core one band's place a bar, fading in at
    /// the ring and out at the core on the riser's own window (0.5 − 0.5·cos 2πx), turning as they go, so a bar later the
    /// eight are exactly where they were: the climb that never arrives.
    static func fadeBands(at t: Double, pulse: Double) -> [(radius: Double, opacity: Double, turn: Double)] {
        let bars: Double = t / (fadeBeatsPerTurn * pulse)
        let f: Double = bars - floor(bars)
        return (0..<fadeBandCount).map { (k: Int) -> (radius: Double, opacity: Double, turn: Double) in
            let place: Double = Double(k) + f
            let x: Double = place / Double(fadeBandCount)
            let turn: Double = 0.25 * place + bars
            return (radius: 0.96 * pow(fadeBandRatio, place), opacity: 0.5 - 0.5 * cos(2 * Double.pi * x), turn: turn - floor(turn))
        }
    }

    static func art(for creditID: String) -> CardArt? {
        switch creditID {
        case CreditLibrary.comeBackToEarth.id: return .comeBackToEarth
        case CreditLibrary.innerbloom.id: return .innerbloom
        case CreditLibrary.musicToWatchBoysTo.id: return .musicToWatchBoysTo
        case CreditLibrary.highByTheBeach.id: return .highByTheBeach
        case CreditLibrary.stay.id: return .stay
        case CreditLibrary.dunno.id: return .dunno
        case CreditLibrary.wings.id: return .wings
        case CreditLibrary.happinessIsAButterfly.id: return .happinessIsAButterfly
        case CreditLibrary.runaway.id: return .runaway
        case CreditLibrary.underwater.id: return .underwater
        case CreditLibrary.fade.id: return .fade
        case CreditLibrary.holdMyLiquor.id: return .holdMyLiquor
        default: return nil
        }
    }

    /// The place card of a set born from its place rather than a song (a set with no credit), by set id; nil for every
    /// other set. A new place-born set adds its case and its id here; the compiler then asks for its title font,
    /// tracking, pulse and drawing in the switches below.
    static func place(for setID: String) -> CardArt? {
        switch setID {
        case "tea-house-snow": return .teaHouseSnow   // Set 9 (spec §11)
        case "zen-rock-garden": return .zenRockGarden   // Set 10 (spec §11)
        case "great-barrier-reef": return .greatBarrierReef   // Set 12 (Sets 11 & 12 spec §11)
        case "neon-night-drive": return .neonNightDrive   // Set 14 (Fire & Neon spec §11)
        default: return nil
        }
    }

    /// A place card names its set and mood instead of a song (no liner notes, no Listen).
    var isPlace: Bool {
        switch self {
        case .comeBackToEarth, .innerbloom, .musicToWatchBoysTo, .highByTheBeach, .stay, .dunno, .wings, .happinessIsAButterfly:
            return false
        case .underwater, .fade:
            return false
        case .runaway, .holdMyLiquor:
            return false
        case .teaHouseSnow, .zenRockGarden:
            return true
        case .greatBarrierReef, .neonNightDrive:
            return true
        }
    }

    /// One breath of a place card (seconds): the reef's quicker `reefPulse`, the drive's `drivePulse` (its tempo), every
    /// other place's `placePulse`.
    var placeBreath: Double {
        switch self {
        case .greatBarrierReef: return Self.reefPulse
        case .neonNightDrive: return Self.drivePulse
        default: return Self.placePulse
        }
    }

    /// How the card sets its title: an airy serif under water, a clean wide-tracked sans at dusk, a lush
    /// high-contrast retro serif in the golden haze.
    var titleFont: Font {
        switch self {
        case .comeBackToEarth: return .system(size: 30, weight: .light, design: .serif)
        case .innerbloom: return .system(size: 24, weight: .medium, design: .default)
        case .musicToWatchBoysTo: return .custom("Didot", size: 30)
        case .highByTheBeach: return .custom("Futura-CondensedMedium", size: 28)
        case .stay: return .system(size: 30, weight: .regular, design: .serif)
        case .dunno: return .system(size: 26, weight: .light, design: .rounded)
        case .wings: return .system(size: 28, weight: .light, design: .rounded)
        case .happinessIsAButterfly: return .system(size: 26, weight: .regular, design: .serif)
        case .runaway: return .system(size: 28, weight: .thin, design: .serif)
        case .underwater: return .system(size: 27, weight: .light, design: .monospaced)
        case .fade: return .system(size: 30, weight: .ultraLight, design: .default)
        case .teaHouseSnow: return .system(size: 28, weight: .light, design: .serif)
        case .zenRockGarden: return .system(size: 27, weight: .light, design: .default)
        case .greatBarrierReef: return .system(size: 27, weight: .medium, design: .rounded)
        case .holdMyLiquor: return .system(size: 30, weight: .heavy, design: .serif)
        case .neonNightDrive: return .system(size: 28, weight: .thin, design: .rounded)
        }
    }

    var titleTracking: CGFloat {
        switch self {
        case .innerbloom: return 7
        case .musicToWatchBoysTo: return 1.5
        case .highByTheBeach: return 3
        case .comeBackToEarth: return 0.5
        case .stay: return 1
        case .dunno: return 2
        case .wings: return 2
        case .happinessIsAButterfly: return 1
        case .runaway: return 4
        case .underwater: return 2
        case .fade: return 12
        case .teaHouseSnow: return 2.5
        case .zenRockGarden: return 4
        case .greatBarrierReef: return 1.5
        case .holdMyLiquor: return 0.5
        case .neonNightDrive: return 3
        }
    }

    /// How long one breath of the card lasts: a beat of the song, except the two felt in half time: "Stay"
    /// (134 BPM played as 67), so its snow falls at 60/67 s, and "Wings" (119 BPM, felt as about 60), whose curtains
    /// ripple once a second (60/60 s, the half-time feel rounded, as its demo plays it). A place card follows no song.
    func pulse(for credit: Credit) -> Double {
        switch self {
        case .stay: return 2 * credit.pulsePeriod
        case .wings: return 60.0 / 60
        case .happinessIsAButterfly: return credit.pulsePeriod   // 68 BPM: the motes blink at 60/68 s
        case .underwater: return credit.pulsePeriod   // 118 BPM: a sonar ring leaves every 60/118 s
        case .fade: return credit.pulsePeriod   // 124 BPM, the felt pulse: the ring turns once a bar of four of these
        case .teaHouseSnow, .zenRockGarden: return Self.placePulse
        case .greatBarrierReef: return Self.reefPulse
        case .holdMyLiquor: return credit.pulsePeriod   // 104 BPM (machine-detected, to be checked by ear): the cracks throb on it
        case .neonNightDrive: return Self.drivePulse
        default: return credit.pulsePeriod
        }
    }
    var titleCase: Bool { self == .innerbloom }

    func draw(in ctx: GraphicsContext, size: CGSize, t: Double, pulse: Double) {
        switch self {
        case .comeBackToEarth: Self.lightUnderWater(ctx, size, t, pulse)
        case .innerbloom: Self.bloom(ctx, size, t, pulse)
        case .musicToWatchBoysTo: Self.goldenHaze(ctx, size, t, pulse)
        case .highByTheBeach: Self.coastLine(ctx, size, t, pulse)
        case .stay: Self.cabinWindow(ctx, size, t, pulse)
        case .dunno: Self.dawnBedroom(ctx, size, t, pulse)
        case .wings: Self.auroraWater(ctx, size, t, pulse)
        case .happinessIsAButterfly: Self.moonlitCove(ctx, size, t, pulse)
        case .runaway: Self.runawayPlain(ctx, size, t, pulse)
        case .underwater: Self.deepBlue(ctx, size, t, pulse)
        case .fade: Self.wallCloud(ctx, size, t, pulse)
        case .teaHouseSnow: Self.teaHouse(ctx, size, t, pulse)
        case .zenRockGarden: Self.rockGarden(ctx, size, t, pulse)
        case .greatBarrierReef: Self.reef(ctx, size, t, pulse)
        case .holdMyLiquor: Self.moltenRim(ctx, size, t, pulse)
        case .neonNightDrive: Self.neonExpressway(ctx, size, t, pulse)
        }
    }

    // MARK: - Come Back to Earth: light under water, a ring rising to the surface

    private static func lightUnderWater(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.55, green: 0.74, blue: 0.86), Color(red: 0.10, green: 0.30, blue: 0.48),
                              Color(red: 0.02, green: 0.07, blue: 0.16)]),
            startPoint: CGPoint(x: size.width * 0.5, y: 0), endPoint: CGPoint(x: size.width * 0.5, y: size.height)))

        // Light shafts from the surface.
        var shafts = ctx
        shafts.blendMode = .plusLighter
        for i in 0..<5 {
            let x = size.width * (0.12 + 0.2 * Double(i)) + 18 * sin(t * 0.21 + Double(i) * 1.7)
            var p = Path()
            p.move(to: CGPoint(x: x - 10, y: 0)); p.addLine(to: CGPoint(x: x + 14, y: 0))
            p.addLine(to: CGPoint(x: x + 70 + 20 * Double(i % 2), y: size.height)); p.addLine(to: CGPoint(x: x + 10, y: size.height))
            p.closeSubpath()
            shafts.fill(p, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0)]),
                                                 startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + 40, y: size.height * 0.9)))
        }

        // Caustics: a net of bright lines where two octaves of noise cross a level.
        var caustic = ctx
        caustic.blendMode = .plusLighter
        caustic.addFilter(.blur(radius: 0.8))
        let rows = 16, steps = 72
        for r in 0..<rows {
            let depth = Double(r) / Double(rows - 1)
            var p = Path()
            for s in 0...steps {
                let x = size.width * Double(s) / Double(steps)
                let n = noise2(x * 0.012 + t * 0.12, depth * 3.1 + t * 0.05) * 0.65 + noise2(x * 0.03 - t * 0.2, depth * 7.3) * 0.35
                let y = size.height * (0.05 + 0.6 * depth) + (n - 0.5) * 34 * (1 - 0.6 * depth)
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            caustic.stroke(p, with: .color(Color(red: 0.8, green: 0.95, blue: 1.0).opacity(0.22 * (1 - depth) + 0.04)), lineWidth: 1.2)
        }

        // A slow ring rising and surfacing once every two beats.
        let cycle = 2 * pulse
        let k = (t.truncatingRemainder(dividingBy: cycle)) / cycle
        let cx = size.width * 0.72, cy = size.height * (0.92 - 0.8 * k)
        let radius = 14 + 40 * k
        var ring = ctx
        ring.blendMode = .plusLighter
        let ringRect = CGRect(x: cx - radius, y: cy - radius * 0.45, width: radius * 2, height: radius * 0.9)
        ring.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.7 * (1 - k) * min(1, k * 6))), lineWidth: 2)
        // Surfacing: a brief brightening at the top.
        let surface = max(0, 1 - abs(k - 0.95) / 0.05)
        ring.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color.white.opacity(0.12 * surface), .clear]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.3)))
    }

    // MARK: - Innerbloom: petals of light opening from one point at dusk

    private static func bloom(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.06, green: 0.03, blue: 0.14), Color(red: 0.24, green: 0.09, blue: 0.30),
                              Color(red: 0.62, green: 0.28, blue: 0.30)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        let centre = CGPoint(x: size.width * 0.68, y: size.height * 0.46)
        // The bloom opens over eight beats and closes over the next eight; each beat lifts its light.
        let phase = t / (16 * pulse) * 2 * .pi
        let open = 0.35 + 0.65 * (0.5 - 0.5 * cos(phase))
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let lift = 0.75 + 0.25 * exp(-beat * 4)

        var petals = ctx
        petals.blendMode = .plusLighter
        petals.addFilter(.blur(radius: 1.5))
        let count = 9
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi + t * 0.05
            let length = (36 + 70 * open) * (0.85 + 0.15 * sin(Double(i) * 2.3))
            let width = 10 + 16 * open
            var p = Path()
            p.move(to: .zero)
            p.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.5, y: -width))
            p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.5, y: width))
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: a)
            let hueShift = Double(i) / Double(count)
            let colour = Color(red: 0.95, green: 0.55 + 0.25 * hueShift, blue: 0.65 + 0.3 * (1 - hueShift))
            petals.fill(p.applying(transform), with: .color(colour.opacity(0.22 * lift)))
            petals.stroke(p.applying(transform), with: .color(colour.opacity(0.35 * lift)), lineWidth: 0.8)
        }
        var core = ctx
        core.blendMode = .plusLighter
        core.fill(Path(ellipseIn: CGRect(x: centre.x - 40, y: centre.y - 40, width: 80, height: 80)),
                  with: .radialGradient(Gradient(colors: [Color.white.opacity(0.7 * lift), Color(red: 1, green: 0.7, blue: 0.8).opacity(0)]),
                                        center: centre, startRadius: 0, endRadius: 40))
        // A low horizon of dusk light.
        core.fill(Path(CGRect(x: 0, y: size.height * 0.82, width: size.width, height: size.height * 0.18)),
                  with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.6, blue: 0.45).opacity(0), Color(red: 1, green: 0.6, blue: 0.45).opacity(0.18)]),
                                        startPoint: CGPoint(x: 0, y: size.height * 0.82), endPoint: CGPoint(x: 0, y: size.height)))
    }

    // MARK: - Music to Watch Boys To: a golden heat-shimmer over a soft horizon, wobbling like old tape

    private static func goldenHaze(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        // The whole picture sways a little, like a tape replaying slightly unevenly: once every two beats.
        let wobble = 2.2 * sin(2 * .pi * t / (2 * pulse)) + 0.8 * sin(2 * .pi * t / 7.3)
        let horizon = size.height * 0.6 + wobble
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.96, green: 0.78, blue: 0.74), location: 0),
                             .init(color: Color(red: 0.99, green: 0.74, blue: 0.47), location: 0.5),
                             .init(color: Color(red: 1.0, green: 0.83, blue: 0.52), location: 0.6),
                             .init(color: Color(red: 0.62, green: 0.34, blue: 0.33), location: 0.62),
                             .init(color: Color(red: 0.22, green: 0.10, blue: 0.15), location: 1)]),
            startPoint: CGPoint(x: 0, y: wobble), endPoint: CGPoint(x: 0, y: size.height + wobble)))

        // A low sun, softened by the haze.
        let sun = CGPoint(x: size.width * 0.3, y: horizon - size.height * 0.07)
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: CGRect(x: sun.x - 120, y: sun.y - 70, width: 240, height: 140)),
                  with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.55), .clear]),
                                        center: sun, startRadius: 0, endRadius: 120))
        glow.fill(Path(ellipseIn: CGRect(x: sun.x - 22, y: sun.y - 20, width: 44, height: 40)),
                  with: .color(Color(red: 1, green: 0.93, blue: 0.78).opacity(0.85)))

        // Heat shimmer: thin bands above the horizon whose edges ripple slowly.
        var shimmer = ctx
        shimmer.blendMode = .plusLighter
        for i in 0..<14 {
            let y0 = horizon - 6 - Double(i) * size.height * 0.035
            var p = Path()
            let steps = 60
            for s in 0...steps {
                let x = size.width * Double(s) / Double(steps)
                let n = noise2(x * 0.02 + t * 0.35, Double(i) * 1.7 + t * 0.15) - 0.5
                let y = y0 + 3.5 * n + 1.2 * sin(x * 0.05 + t * 1.3 + Double(i))
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            let fade = 1 - Double(i) / 14
            shimmer.stroke(p, with: .color(Color(red: 1, green: 0.9, blue: 0.75).opacity(0.10 * fade)), lineWidth: 1.4)
        }

        // Honey and rose bands drifting across the water.
        var bands = ctx
        bands.blendMode = .plusLighter
        bands.addFilter(.blur(radius: 2))
        for i in 0..<9 {
            let depth = Double(i) / 8
            let y = horizon + 6 + depth * depth * (size.height - horizon - 10)
            let speed = 6 + 18 * depth
            let span = size.width * (0.25 + 0.2 * noise2(Double(i) * 3.1, 0.5))
            let x = (Double(i) * 97 + t * speed).truncatingRemainder(dividingBy: size.width + span) - span
            let rose = i % 3 == 1
            let colour = rose ? Color(red: 1, green: 0.62, blue: 0.66) : Color(red: 1, green: 0.8, blue: 0.45)
            bands.fill(Path(roundedRect: CGRect(x: x, y: y, width: span, height: 2 + 5 * depth), cornerRadius: 3),
                       with: .color(colour.opacity(0.28 * (1 - 0.5 * depth))))
        }
        // The sun's path on the water, breaking up as it nears.
        var path = ctx
        path.blendMode = .plusLighter
        for k in 0..<22 {
            let d = Double(k) / 21
            let y = horizon + 3 + d * d * (size.height - horizon - 6)
            let w = 10 + 70 * d
            let jitter = 9 * (noise2(Double(k) * 0.7, t * 0.6) - 0.5) * (0.3 + d)
            path.fill(Path(CGRect(x: sun.x - w / 2 + jitter, y: y, width: w, height: 1.5 + 2.5 * d)),
                      with: .color(Color(red: 1, green: 0.9, blue: 0.7).opacity(0.35 * (1 - 0.6 * d))))
        }
    }

    // MARK: - High by the Beach: one road curving along a dark coast, one light travelling it at the pulse

    private static func coastLine(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.02, green: 0.03, blue: 0.10), location: 0),
                             .init(color: Color(red: 0.07, green: 0.12, blue: 0.27), location: 0.52),
                             .init(color: Color(red: 0.16, green: 0.20, blue: 0.36), location: 0.55),
                             .init(color: Color(red: 0.02, green: 0.05, blue: 0.12), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        // A few faint stars.
        for i in 0..<26 {
            let x = w * noise2(Double(i) * 7.1, 0.3), y = h * 0.48 * noise2(Double(i) * 3.3, 9.1)
            let twinkle = 0.5 + 0.5 * sin(t * 1.3 + Double(i))
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.15 + 0.25 * twinkle)))
        }
        // The coast: a dark headland sweeping in from the left and out to a point on the right.
        let a = CGPoint(x: -10, y: h * 0.98), c1 = CGPoint(x: w * 0.25, y: h * 0.55), c2 = CGPoint(x: w * 0.55, y: h * 0.82)
        let b = CGPoint(x: w * 0.98, y: h * 0.58)
        var land = Path()
        land.move(to: CGPoint(x: -10, y: h + 10)); land.addLine(to: CGPoint(x: -10, y: a.y - 40))
        land.addCurve(to: CGPoint(x: b.x + 20, y: b.y - 22), control1: CGPoint(x: c1.x, y: c1.y - 40), control2: CGPoint(x: c2.x, y: c2.y - 30))
        land.addLine(to: CGPoint(x: w + 10, y: h + 10)); land.closeSubpath()
        ctx.fill(land, with: .color(Color(red: 0.01, green: 0.02, blue: 0.05)))
        // The road along it.
        var road = Path()
        road.move(to: a); road.addCurve(to: b, control1: c1, control2: c2)
        ctx.stroke(road, with: .color(Color(red: 0.75, green: 0.82, blue: 1).opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, dash: [7, 6]))
        // One light travels the road every eight beats, brightening on each beat.
        let u = (t / (8 * pulse)).truncatingRemainder(dividingBy: 1)
        func bezier(_ s: Double) -> CGPoint {
            let m = 1 - s
            return CGPoint(x: m * m * m * a.x + 3 * m * m * s * c1.x + 3 * m * s * s * c2.x + s * s * s * b.x,
                           y: m * m * m * a.y + 3 * m * m * s * c1.y + 3 * m * s * s * c2.y + s * s * s * b.y)
        }
        let p = bezier(u)
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let glow = 0.6 + 0.4 * exp(-beat * 5)
        var light = ctx
        light.blendMode = .plusLighter
        light.fill(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)),
                   with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.85, blue: 0.6).opacity(0.5 * glow), .clear]),
                                         center: p, startRadius: 0, endRadius: 26))
        light.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(.white.opacity(glow)))
        // Its reflection, broken up on the sea.
        let q = CGPoint(x: p.x, y: h * 0.55 + (h * 0.55 - p.y) * -0.35 + 4)
        for k in 0..<5 {
            light.fill(Path(CGRect(x: q.x - 6 + 3 * sin(t * 2 + Double(k)), y: q.y + Double(k) * 5, width: 12 - Double(k) * 2, height: 1.2)),
                       with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity(0.25 * glow * (1 - Double(k) / 5))))
        }
        // Lo-fi grain and faint scan lines.
        let frame = Int(t * 12)
        for i in 0..<140 {
            let x = w * hash(i, frame), y = h * hash(frame, i + 999)
            ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.06)))
        }
        for row in stride(from: 0.0, to: h, by: 3) {
            ctx.fill(Path(CGRect(x: 0, y: row, width: w, height: 0.6)), with: .color(.black.opacity(0.12)))
        }
    }

    // MARK: - Stay: a warm window in the snow, one golden horn line curling across it

    private static func cabinWindow(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        let amber = Color(red: 1, green: 0.66, blue: 0.30)
        // Snowy night outside.
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.08, green: 0.09, blue: 0.17)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        let breath = 0.85 + 0.15 * exp(-beat * 3)
        // The window and its glow on the snow.
        let win = CGRect(x: w * 0.30, y: h * 0.17, width: w * 0.40, height: h * 0.56)
        var glow = ctx
        glow.blendMode = .plusLighter
        let centre = CGPoint(x: win.midX, y: win.midY)
        glow.fill(Path(rect), with: .radialGradient(Gradient(colors: [amber.opacity(0.32 * breath), amber.opacity(0.08), .clear]),
                                                    center: centre, startRadius: win.width * 0.3, endRadius: w * 0.62))
        ctx.fill(Path(win.insetBy(dx: -6, dy: -6)), with: .color(Color(red: 0.16, green: 0.09, blue: 0.05)))
        // Four panes: three lit, one dim.
        let gap: CGFloat = 5
        let pw = (win.width - gap) / 2, ph = (win.height - gap) / 2
        for row in 0..<2 {
            for col in 0..<2 {
                let pane = CGRect(x: win.minX + CGFloat(col) * (pw + gap), y: win.minY + CGFloat(row) * (ph + gap), width: pw, height: ph)
                let lit = !(row == 0 && col == 1)
                let top = lit ? Color(red: 1, green: 0.78, blue: 0.45) : Color(red: 0.30, green: 0.20, blue: 0.14)
                let bottom = lit ? Color(red: 0.88, green: 0.46, blue: 0.16) : Color(red: 0.18, green: 0.11, blue: 0.08)
                ctx.fill(Path(pane), with: .linearGradient(Gradient(colors: [top.opacity(lit ? breath : 1), bottom]),
                                                           startPoint: CGPoint(x: pane.midX, y: pane.minY),
                                                           endPoint: CGPoint(x: pane.midX, y: pane.maxY)))
            }
        }
        // Snow on the sill.
        var sill = Path()
        sill.move(to: CGPoint(x: win.minX - 14, y: win.maxY + 8))
        sill.addQuadCurve(to: CGPoint(x: win.maxX + 14, y: win.maxY + 8), control: CGPoint(x: win.midX, y: win.maxY - 2))
        sill.addLine(to: CGPoint(x: win.maxX + 14, y: win.maxY + 13)); sill.addLine(to: CGPoint(x: win.minX - 14, y: win.maxY + 13))
        sill.closeSubpath()
        ctx.fill(sill, with: .color(Color(red: 0.86, green: 0.88, blue: 0.95).opacity(0.85)))
        // One golden line curling across, like a horn phrase: it flows along at the pulse and glows on each beat.
        var line = Path()
        line.move(to: CGPoint(x: -10, y: h * 0.62))
        line.addCurve(to: CGPoint(x: w * 0.47, y: h * 0.40), control1: CGPoint(x: w * 0.18, y: h * 0.70), control2: CGPoint(x: w * 0.30, y: h * 0.30))
        line.addCurve(to: CGPoint(x: w * 0.56, y: h * 0.52), control1: CGPoint(x: w * 0.62, y: h * 0.48), control2: CGPoint(x: w * 0.60, y: h * 0.62))
        line.addCurve(to: CGPoint(x: w + 10, y: h * 0.34), control1: CGPoint(x: w * 0.50, y: h * 0.40), control2: CGPoint(x: w * 0.80, y: h * 0.26))
        let gold = Color(red: 1, green: 0.83, blue: 0.42)
        glow.stroke(line, with: .color(gold.opacity(0.18 * breath)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        ctx.stroke(line, with: .color(gold.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [26, 5], dashPhase: -t / pulse * 8))
        // Six-armed frost round the edges, clear of the words.
        for (fx, fy, r) in Self.stayFrost {
            let c = CGPoint(x: w * fx, y: h * fy)
            var star = Path()
            for k in 0..<6 {
                let a: CGFloat = CGFloat(k) * CGFloat.pi / 3 + 0.2
                let ca: CGFloat = cos(a), sa: CGFloat = sin(a)
                star.move(to: c); star.addLine(to: CGPoint(x: c.x + r * ca, y: c.y + r * sa))
                for s: CGFloat in [0.45, 0.7] {
                    let p = CGPoint(x: c.x + r * s * ca, y: c.y + r * s * sa)
                    let len: CGFloat = r * 0.28 * (1.1 - s)
                    for side: CGFloat in [-1, 1] {
                        let b: CGFloat = a + side * CGFloat.pi / 3
                        let cb: CGFloat = cos(b), sb: CGFloat = sin(b)
                        star.move(to: p)
                        star.addLine(to: CGPoint(x: p.x + len * cb, y: p.y + len * sb))
                    }
                }
            }
            ctx.stroke(star, with: .color(Color(red: 0.85, green: 0.92, blue: 1).opacity(0.45)), lineWidth: 0.8)
        }
        // Snow falling at the pulse: each flake crosses the card in eight beats.
        for i in 0..<70 {
            let speed = 0.8 + 0.4 * hash(i, 7)
            let u = (t / (8 * pulse) * speed + hash(i, 3)).truncatingRemainder(dividingBy: 1)
            let x = w * hash(i, 1) + 10 * sin(t * 0.9 + Double(i))
            let y = -6 + u * (h + 12)
            let r = 0.8 + 1.4 * hash(i, 5)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.35 + 0.4 * hash(i, 9))))
        }
    }

    // MARK: - Dunno: a pastel dawn through a ten-pane window, a sheer curtain, one beam full of motes

    private static func dawnBedroom(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let w = size.width, h = size.height
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.96, green: 0.74, blue: 0.80), location: 0),
                             .init(color: Color(red: 0.78, green: 0.72, blue: 0.93), location: 0.5),
                             .init(color: Color(red: 0.99, green: 0.82, blue: 0.68), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
        // The window: two columns of five panes, glowing with the dawn.
        let win = CGRect(x: w * 0.60, y: h * 0.10, width: w * 0.28, height: h * 0.62)
        ctx.fill(Path(win.insetBy(dx: -5, dy: -5)), with: .color(Color(red: 0.97, green: 0.93, blue: 0.95).opacity(0.9)))
        let gap: CGFloat = 4
        let pw = (win.width - gap) / 2, ph = (win.height - 4 * gap) / 5
        for row in 0..<5 {
            for col in 0..<2 {
                let pane = CGRect(x: win.minX + CGFloat(col) * (pw + gap), y: win.minY + CGFloat(row) * (ph + gap), width: pw, height: ph)
                let warmth = Double(row) / 4
                ctx.fill(Path(pane), with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.90 - 0.06 * warmth, blue: 0.86 - 0.12 * warmth),
                                      Color(red: 1, green: 0.84 - 0.05 * warmth, blue: 0.74 - 0.10 * warmth)]),
                    startPoint: CGPoint(x: pane.minX, y: pane.minY), endPoint: CGPoint(x: pane.maxX, y: pane.maxY)))
            }
        }
        // One diagonal beam from the window down across the room: warm light over the room, never clipped to white.
        var light = ctx
        var beam = Path()
        beam.move(to: CGPoint(x: win.minX, y: win.minY + 10))
        beam.addLine(to: CGPoint(x: win.minX + 4, y: win.maxY))
        beam.addLine(to: CGPoint(x: w * 0.12, y: h + 10))
        beam.addLine(to: CGPoint(x: -w * 0.12, y: h + 10))
        beam.closeSubpath()
        let beatNow = (t / pulse).truncatingRemainder(dividingBy: 1)
        let beamGlow = 0.80 + 0.20 * exp(-beatNow * 3)   // the light breathes on the beat
        light.fill(beam, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.70).opacity(0.3 * beamGlow), .clear]),
                                               startPoint: CGPoint(x: win.minX, y: win.midY), endPoint: CGPoint(x: 0, y: h)))
        // The sheer curtain over the left of the window: soft folds that sway.
        for k in 0..<6 {
            let x0 = win.minX - 10 + CGFloat(k) * win.width * 0.11
            let sway = CGFloat(7 * sin(t * 0.8 + Double(k) * 0.9))
            var fold = Path()
            fold.move(to: CGPoint(x: x0, y: win.minY - 8))
            fold.addCurve(to: CGPoint(x: x0 + sway, y: win.maxY + 10),
                          control1: CGPoint(x: x0 + 6 + sway * 0.5, y: win.minY + win.height * 0.35),
                          control2: CGPoint(x: x0 - 6 + sway, y: win.minY + win.height * 0.7))
            ctx.stroke(fold, with: .color(.white.opacity(0.22)), lineWidth: win.width * 0.09)
        }
        // Motes drifting in the beam; seven brighter ones twinkle on the beat.
        let beat = (t / pulse).truncatingRemainder(dividingBy: 1)
        for i in 0..<48 {
            let u = CGFloat((hash(i, 11) + t * 0.035 * (0.5 + hash(i, 12))).truncatingRemainder(dividingBy: 1))
            let v = CGFloat(hash(i, 13))
            // A point inside the beam: u runs from the window to the floor, v across it.
            let top = CGPoint(x: win.minX + 2, y: win.minY + 10 + v * win.height * 0.9)
            let bottom = CGPoint(x: -w * 0.12 + v * w * 0.24, y: h + 10)
            let wobbleX = CGFloat(3 * sin(t * 0.7 + Double(i))), wobbleY = CGFloat(2 * cos(t * 0.5 + Double(i) * 1.3))
            let x: CGFloat = top.x + (bottom.x - top.x) * u + wobbleX
            let y: CGFloat = top.y + (bottom.y - top.y) * u + wobbleY
            let bright = i < 7
            let phase: Double = (beat + Double(i) / 7).truncatingRemainder(dividingBy: 1)
            let flash: Double = bright ? 0.45 + 0.55 * exp(-phase * 5) : 0.35
            let r: CGFloat = bright ? 2.2 : 1.1
            light.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(flash)))
        }
    }

    // MARK: - Wings: two aurora curtains over black water that mirrors them, under six bright stars

    private static func auroraWater(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let horizon: CGFloat = h * 0.64
        let green = Color(red: 0.30, green: 0.95, blue: 0.62)
        let teal = Color(red: 0.18, green: 0.72, blue: 0.70)
        let violet = Color(red: 0.55, green: 0.35, blue: 0.85)
        // A deep teal-black sky, a little lighter towards the horizon, over still black water.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.01, green: 0.03, blue: 0.05), Color(red: 0.02, green: 0.09, blue: 0.11),
                              Color(red: 0.04, green: 0.15, blue: 0.16)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.01, green: 0.04, blue: 0.05), Color(red: 0, green: 0.01, blue: 0.02)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))

        // A field of faint stars, clear of the liner notes.
        for i in 0..<60 {
            let x: CGFloat = w * CGFloat(hash(i, 21)), y: CGFloat = horizon * 0.85 * CGFloat(hash(i, 22))
            if x > w * 0.6 && y < h * 0.1 { continue }
            let twinkle: Double = 0.5 + 0.5 * sin(t * (0.9 + hash(i, 23)) + Double(i))
            let r: CGFloat = 0.5 + 0.6 * CGFloat(hash(i, 24))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.12 + 0.3 * twinkle)))
        }
        // Six brighter six-pointed stars.
        for (k, star) in Self.wingsStars.enumerated() {
            let (fx, fy, arm) = star
            let c = CGPoint(x: w * fx, y: h * fy)
            let glint: Double = 0.7 + 0.3 * sin(t * 0.8 + Double(k) * 1.9)
            var spikes = Path()
            for j in 0..<3 {
                let a: CGFloat = CGFloat(j) * CGFloat.pi / 3 + 0.26
                let dx: CGFloat = arm * cos(a), dy: CGFloat = arm * sin(a)
                spikes.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                spikes.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
            ctx.stroke(spikes, with: .color(Color(red: 0.85, green: 0.95, blue: 1).opacity(0.55 * glint)), lineWidth: 0.8)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)), with: .color(.white.opacity(0.9 * glint)))
        }

        // Two curtains of rays, shaped by noise that drifts slowly; a fold travels along each once a pulse.
        let wave: Double = 2 * Double.pi * t / pulse
        let steps = 96
        let strip: CGFloat = w / CGFloat(steps) * 1.6
        let curtains: [(base: Double, sweep: Double, height: Double, glow: Double, seed: Double)] = [
            (0.50, 0.05, 0.30, 0.55, 0), (0.575, 0.035, 0.20, 0.40, 7.3)]
        var rays: [(x: CGFloat, base: CGFloat, tall: CGFloat, bright: Double, sway: CGFloat)] = []
        rays.reserveCapacity(curtains.count * steps)
        for c in curtains {
            for s in 0..<steps {
                let u: Double = Double(s) / Double(steps - 1)
                let fold: Double = sin(u * 9 - wave + c.seed)
                let n: Double = noise2(u * 6 + t * 0.06 + c.seed, c.seed + t * 0.03)
                let baseFraction: Double = c.base + c.sweep * sin(u * 3.4 + c.seed + t * 0.05) + 0.012 * fold
                let bright: Double = c.glow * (0.35 + 0.65 * n) * (0.8 + 0.2 * fold)
                let sway: CGFloat = CGFloat(3 * sin(Double(s) * 0.7 + t * 1.1))
                let x: CGFloat = w * CGFloat(u) - strip * 0.3
                let tall: CGFloat = h * CGFloat(c.height * (0.55 + 0.6 * n))
                rays.append((x: x, base: h * CGFloat(baseFraction), tall: tall, bright: bright, sway: sway))
            }
        }
        var sky = ctx
        sky.blendMode = .plusLighter
        sky.addFilter(.blur(radius: 2))
        sky.drawLayer { layer in
            for r in rays {
                let top: CGFloat = r.base - r.tall
                layer.fill(Path(CGRect(x: r.x, y: top, width: strip, height: r.tall)), with: .linearGradient(
                    Gradient(colors: [violet.opacity(0), teal.opacity(0.45 * r.bright), green.opacity(r.bright)]),
                    startPoint: CGPoint(x: r.x, y: top), endPoint: CGPoint(x: r.x, y: r.base)))
            }
        }
        // The water mirrors them: flipped about the horizon, dimmer, swaying a little.
        var mirror = ctx
        mirror.blendMode = .plusLighter
        mirror.clip(to: Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)))
        mirror.addFilter(.blur(radius: 3))
        mirror.drawLayer { layer in
            for r in rays {
                let top: CGFloat = 2 * horizon - r.base
                layer.fill(Path(CGRect(x: r.x + r.sway, y: top, width: strip, height: r.tall)), with: .linearGradient(
                    Gradient(colors: [green.opacity(0.35 * r.bright), teal.opacity(0.15 * r.bright), violet.opacity(0)]),
                    startPoint: CGPoint(x: r.x, y: top), endPoint: CGPoint(x: r.x, y: top + r.tall)))
            }
        }

        // A low dark shore along the horizon.
        var shore = Path()
        shore.move(to: CGPoint(x: 0, y: horizon))
        for s in 0...48 {
            let u: Double = Double(s) / 48
            let rise: CGFloat = h * CGFloat(0.012 + 0.05 * noise2(u * 5 + 3.1, 0.7) * (0.4 + 0.6 * abs(u - 0.55)))
            shore.addLine(to: CGPoint(x: w * CGFloat(u), y: horizon - rise))
        }
        shore.addLine(to: CGPoint(x: w, y: horizon + 1)); shore.addLine(to: CGPoint(x: 0, y: horizon + 1))
        shore.closeSubpath()
        ctx.fill(shore, with: .color(Color(red: 0.0, green: 0.02, blue: 0.03)))
        // Faint ripples breaking up the reflection.
        for k in 0..<14 {
            let d: Double = Double(k) / 13
            let y0: CGFloat = horizon + 4 + CGFloat(d * d) * (h - horizon - 6)
            var p = Path()
            for s in 0...40 {
                let x: CGFloat = w * CGFloat(s) / 40
                let y: CGFloat = y0 + CGFloat(1.2 * sin(Double(s) * 0.9 + t * 0.7 + Double(k) * 1.3))
                if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(.black.opacity(0.5)), lineWidth: CGFloat(1 + 2 * d))
        }
    }

    // MARK: - Happiness Is a Butterfly: a midnight cove, a glowing cyan waterline, thirteen motes and a pale moon

    private static func moonlitCove(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let waterline: CGFloat = h * 0.52
        let cyan = Color(red: 0.30, green: 0.95, blue: 0.95)
        // A midnight-blue sky, lighter towards the water, over dark water.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: waterline)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.03, green: 0.06, blue: 0.17), Color(red: 0.07, green: 0.13, blue: 0.30),
                              Color(red: 0.12, green: 0.22, blue: 0.40)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: waterline)))
        ctx.fill(Path(CGRect(x: 0, y: waterline, width: w, height: h - waterline)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.22), Color(red: 0.01, green: 0.04, blue: 0.10)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: h)))

        // Faint stars, clear of the liner notes and of the moon.
        let moon = CGPoint(x: w * 0.17, y: h * 0.20)
        for i in 0..<45 {
            let x: CGFloat = w * CGFloat(hash(i, 31)), y: CGFloat = waterline * 0.9 * CGFloat(hash(i, 32))
            if x > w * 0.6 && y < h * 0.12 { continue }
            let dx: CGFloat = x - moon.x, dy: CGFloat = y - moon.y
            if dx * dx + dy * dy < 900 { continue }
            let twinkle: Double = 0.5 + 0.5 * sin(t * (0.7 + hash(i, 33)) + Double(i) * 2.1)
            let r: CGFloat = 0.5 + 0.5 * CGFloat(hash(i, 34))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity(0.10 + 0.25 * twinkle)))
        }

        // The pale moon in a soft halo.
        var sky = ctx
        sky.blendMode = .plusLighter
        sky.fill(Path(ellipseIn: CGRect(x: moon.x - 64, y: moon.y - 64, width: 128, height: 128)),
                 with: .radialGradient(Gradient(colors: [Color(red: 0.75, green: 0.82, blue: 0.95).opacity(0.30), .clear]),
                                       center: moon, startRadius: 0, endRadius: 64))
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 15, y: moon.y - 15, width: 30, height: 30)),
                 with: .color(Color(red: 0.93, green: 0.95, blue: 0.98)))
        ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 9, y: moon.y - 7, width: 7, height: 6)),
                 with: .color(Color(red: 0.80, green: 0.84, blue: 0.90).opacity(0.6)))

        // The cove's two dark headlands, low against the sky.
        let rock = Color(red: 0.01, green: 0.02, blue: 0.06)
        var left = Path()
        left.move(to: CGPoint(x: 0, y: waterline + 1))
        for s in 0...20 {
            let u: Double = Double(s) / 20
            let rise: CGFloat = h * CGFloat(0.12 * (1 - u * u) + 0.015 * noise2(u * 6 + 1.3, 0.4))
            left.addLine(to: CGPoint(x: w * 0.16 * CGFloat(u), y: waterline - rise))
        }
        left.addLine(to: CGPoint(x: w * 0.16, y: waterline + 1)); left.closeSubpath()
        ctx.fill(left, with: .color(rock))
        var right = Path()
        right.move(to: CGPoint(x: w, y: waterline + 1))
        for s in 0...24 {
            let u: Double = Double(s) / 24
            let rise: CGFloat = h * CGFloat(0.09 * (1 - u * u) + 0.012 * noise2(u * 7 + 4.1, 0.9))
            right.addLine(to: CGPoint(x: w - w * 0.24 * CGFloat(u), y: waterline - rise))
        }
        right.addLine(to: CGPoint(x: w * 0.76, y: waterline + 1)); right.closeSubpath()
        ctx.fill(right, with: .color(rock))

        // The moon's broken path on the water, fading before the title.
        var glints = ctx
        glints.blendMode = .plusLighter
        for k in 0..<10 {
            let d: Double = Double(k) / 9
            let y: CGFloat = waterline + 4 + CGFloat(d) * h * 0.12
            let base: Double = 10 + 14 * d
            let shimmer: Double = 0.6 + 0.4 * noise2(Double(k) * 1.7, t * 0.4)
            let half = CGFloat(base * shimmer)
            let x: CGFloat = moon.x + CGFloat(3 * sin(t * 0.6 + Double(k) * 1.1))
            glints.fill(Path(CGRect(x: x - half, y: y, width: 2 * half, height: 1.2)),
                        with: .color(Color(red: 0.85, green: 0.90, blue: 1).opacity(0.30 * (1 - 0.7 * d))))
        }

        // The glowing cyan waterline, lapping slowly (once every four beats), with a sheen spilling into the water.
        let lap: Double = 0.85 + 0.15 * sin(2 * Double.pi * t / (4 * pulse))
        var line = Path()
        for s in 0...80 {
            let u: Double = Double(s) / 80
            let ripple: Double = 1.5 * sin(u * 23 + t * 0.9)
            let drift: Double = 1.2 * (noise2(u * 9 + t * 0.15, 2.7) - 0.5)
            let y: CGFloat = waterline + CGFloat(ripple + drift)
            if s == 0 { line.move(to: CGPoint(x: 0, y: y)) } else { line.addLine(to: CGPoint(x: w * CGFloat(u), y: y)) }
        }
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.fill(Path(CGRect(x: 0, y: waterline, width: w, height: h * 0.10)), with: .linearGradient(
            Gradient(colors: [cyan.opacity(0.28 * lap), cyan.opacity(0)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: waterline + h * 0.10)))
        var halo = glow
        halo.addFilter(.blur(radius: 4))
        halo.stroke(line, with: .color(cyan.opacity(0.55 * lap)), lineWidth: 5)
        glow.stroke(line, with: .color(Color(red: 0.75, green: 1, blue: 1).opacity(0.85 * lap)), lineWidth: 1.2)

        // Thirteen glow motes, each blinking on the beat (68 BPM), out of step with its neighbours.
        let beat: Double = t / pulse
        for (i, mote) in Self.butterflyMotes.enumerated() {
            let (fx, fy, r) = mote
            let bob: Double = 1.5 * sin(t * 0.8 + Double(i) * 1.3)
            let c = CGPoint(x: w * fx, y: h * fy + CGFloat(bob))
            let phase: Double = (beat + Double(i) * 0.382).truncatingRemainder(dividingBy: 1)
            let blink: Double = 0.25 + 0.75 * exp(-phase * 4)
            let glowR: CGFloat = r - 1.5   // the drift above stays inside the mote's radius
            glow.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: 2 * glowR, height: 2 * glowR)),
                      with: .radialGradient(Gradient(colors: [cyan.opacity(0.6 * blink), cyan.opacity(0)]),
                                            center: c, startRadius: 0, endRadius: glowR))
            let core: CGFloat = 1.2 + 0.8 * CGFloat(blink)
            glow.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)),
                      with: .color(Color(red: 0.85, green: 1, blue: 1).opacity(0.9 * blink)))
        }
    }

    // MARK: - Underwater: a deep-blue field, sonar rings pulsing on the beat, seven bubbles rising and a sweep resting
    // at F♯ on a faint twelve-tick dial

    private static func deepBlue(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let centre = CGPoint(x: w * Self.underwaterSonar.x, y: h * Self.underwaterSonar.y)
        let dial: CGFloat = h * Self.underwaterSonar.radius
        let beat: Double = t / pulse
        let ping: Double = exp(-(beat - floor(beat)) * 5)   // 1 as each ring leaves the centre, fading over the beat
        let cyan = Color(red: 0.45, green: 0.85, blue: 1.0)

        // The deep-blue field, a little light from far above, and the sonar's glow, a little brighter on each ping.
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.05, green: 0.19, blue: 0.33), location: 0),
                             .init(color: Color(red: 0.025, green: 0.10, blue: 0.22), location: 0.5),
                             .init(color: Color(red: 0.01, green: 0.035, blue: 0.10), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        var light = ctx
        light.blendMode = .plusLighter
        let above = CGPoint(x: w * 0.32, y: -h * 0.25)
        let reach: CGFloat = w * 0.8
        let surface = Color(red: 0.30, green: 0.60, blue: 0.80)
        light.fill(Path(ellipseIn: CGRect(x: above.x - reach, y: above.y - reach, width: 2 * reach, height: 2 * reach)),
                   with: .radialGradient(Gradient(colors: [surface.opacity(0.16), surface.opacity(0)]),
                                         center: above, startRadius: 0, endRadius: reach))
        let halo: CGFloat = 1.3 * dial
        light.fill(Path(ellipseIn: CGRect(x: centre.x - halo, y: centre.y - halo, width: 2 * halo, height: 2 * halo)),
                   with: .radialGradient(Gradient(colors: [cyan.opacity(0.10 + 0.06 * ping), cyan.opacity(0)]),
                                         center: centre, startRadius: 0, endRadius: halo))

        // Murk: faint flecks drifting down through the blue.
        for i in 0..<40 {
            let u: Double = (hash(i, 61) + t * 0.012 * (0.6 + 0.8 * hash(i, 62))).truncatingRemainder(dividingBy: 1)
            let x: CGFloat = w * CGFloat(hash(i, 63)) + 6 * k * CGFloat(sin(t * 0.3 + Double(i)))
            let y: CGFloat = h * CGFloat(u)
            let r: CGFloat = (0.5 + 0.7 * CGFloat(hash(i, 64))) * k
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Color(red: 0.70, green: 0.85, blue: 0.95).opacity(0.10 + 0.20 * hash(i, 65))))
        }

        // The range rings and the faint twelve-tick dial: C at the top with a longer tick, the key's tick a little brighter.
        for (j, opacity) in [0.10, 0.12, 0.16].enumerated() {
            let r: CGFloat = dial * CGFloat(j + 1) / 3
            ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(cyan.opacity(opacity)), lineWidth: 0.8 * k)
        }
        for p in 0..<Self.underwaterDialTicks {
            let a: Double = Self.dialAngle(p)
            let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
            let inner: CGFloat = dial + 3 * k
            let outer: CGFloat = dial + (p == 0 ? 11 : 7) * k
            var tick = Path()
            tick.move(to: CGPoint(x: centre.x + inner * ca, y: centre.y + inner * sa))
            tick.addLine(to: CGPoint(x: centre.x + outer * ca, y: centre.y + outer * sa))
            ctx.stroke(tick, with: .color(cyan.opacity(p == Self.underwaterSweep ? 0.55 : 0.30)),
                       style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round))
        }

        // The sweep, resting on the key's tick, with the fading wedge of where it has swept behind it.
        let rest: Double = Self.dialAngle(Self.underwaterSweep)
        let slice: Double = 5 * Double.pi / 180
        for s in 0..<10 {
            let from: Double = rest - Double(s) * slice
            var wedge = Path()
            wedge.move(to: centre)
            for q in 0...3 {
                let a: Double = from - slice * Double(q) / 3
                wedge.addLine(to: CGPoint(x: centre.x + dial * CGFloat(cos(a)), y: centre.y + dial * CGFloat(sin(a))))
            }
            wedge.closeSubpath()
            light.fill(wedge, with: .color(cyan.opacity((0.18 - 0.016 * Double(s)) * (0.8 + 0.2 * ping))))
        }
        var sweep = Path()
        sweep.move(to: centre)
        sweep.addLine(to: CGPoint(x: centre.x + dial * CGFloat(cos(rest)), y: centre.y + dial * CGFloat(sin(rest))))
        ctx.stroke(sweep, with: .color(Color(red: 0.75, green: 0.95, blue: 1.0).opacity(0.8)),
                   style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round))

        // The rings: one leaves the centre on every beat and spreads past the dial over three, fading, each in a soft
        // glow; the centre flashes as it leaves.
        for ring in Self.sonarRings(at: t, pulse: pulse) {
            let r: CGFloat = dial * CGFloat(ring.radius)
            let circle = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
            light.stroke(circle, with: .color(cyan.opacity(0.22 * ring.opacity)), lineWidth: 7 * k)
            light.stroke(circle, with: .color(cyan.opacity(ring.opacity)), lineWidth: 1.6 * k)
        }
        let core: CGFloat = 9 * k
        let flash = Color(red: 0.8, green: 0.97, blue: 1.0)
        light.fill(Path(ellipseIn: CGRect(x: centre.x - core, y: centre.y - core, width: 2 * core, height: 2 * core)),
                   with: .radialGradient(Gradient(colors: [flash.opacity(0.5 + 0.5 * ping), flash.opacity(0)]),
                                         center: centre, startRadius: 0, endRadius: core))

        // Seven bubbles rising on the left (the track number), each at its own pace, wobbling as they go and growing a
        // little as the pressure eases.
        for b in Self.underwaterBubbles {
            let rise: Double = t / (b.beats * pulse) + b.phase
            let u: Double = rise - floor(rise)   // 0 at the bottom of its rise, 1 at the top
            let x: CGFloat = w * b.x + 5 * k * CGFloat(sin(2 * Double.pi * (2.5 * u + b.phase)))
            let y: CGFloat = h * (0.64 - 0.58 * CGFloat(u))
            let r: CGFloat = k * b.radius * (0.85 + 0.3 * CGFloat(u))
            let a: Double = min(1, u / 0.12) * min(1, (1 - u) / 0.18)
            let body = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            ctx.fill(body, with: .color(Color(red: 0.55, green: 0.80, blue: 0.95).opacity(0.16 * a)))
            ctx.stroke(body, with: .color(Color(red: 0.78, green: 0.93, blue: 1.0).opacity(0.80 * a)), lineWidth: 1.2 * k)
            let glint: CGFloat = 0.32 * r
            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.38 * r - glint, y: y - 0.38 * r - glint, width: 2 * glint, height: 2 * glint)),
                     with: .color(.white.opacity(0.85 * a)))
        }
    }

    // MARK: - FADE: a ring of storm cloud turning round a green core over a dark plain, once a bar at 124; eight bands of
    // inflow closing in on the core for ever; the pad's pulse in its lit edge. Abstract, and nothing from the record.

    private static func wallCloud(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let bar: Double = fadeBeatsPerTurn * pulse
        let breath: Double = fadeBreath(at: t, pulse: pulse)
        let pump: Double = fadePump(at: t, pulse: pulse)
        let turn: Double = fadeTurn(at: t, pulse: pulse)
        let swell: CGFloat = 0.97 + 0.04 * CGFloat(breath)   // the ring breathes with the core
        let centre = CGPoint(x: w * fadeRing.x, y: h * fadeRing.y)
        let rx: CGFloat = w * fadeRing.radius * swell
        let ry: CGFloat = rx * fadeRing.tilt
        let horizon: CGFloat = h * 0.80
        let core = Color(red: fadeCore.red, green: fadeCore.green, blue: fadeCore.blue)
        let lit = Color(red: 0.58, green: 0.84, blue: 0.64)
        let warm = Color(red: 0.45, green: 0.36, blue: 0.20)

        // The sky under the storm: near black under its base, storm green-grey lower down, lighter at the far horizon.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: horizon)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.035, green: 0.045, blue: 0.045), location: 0),
                             .init(color: Color(red: 0.10, green: 0.13, blue: 0.12), location: 0.30),
                             .init(color: Color(red: 0.20, green: 0.25, blue: 0.22), location: 0.62),
                             .init(color: Color(red: 0.30, green: 0.33, blue: 0.25), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        var light = ctx
        light.blendMode = .plusLighter
        // The end of a hot afternoon, low on the left where the storm hasn't reached: a flat glow along the horizon.
        let reach: CGFloat = w * 0.45
        var afternoon = light
        afternoon.translateBy(x: w * 0.10, y: horizon)
        afternoon.scaleBy(x: 1, y: 0.22)
        afternoon.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                       with: .radialGradient(Gradient(colors: [warm.opacity(0.35), warm.opacity(0)]),
                                             center: .zero, startRadius: 0, endRadius: reach))
        // The core's light pulls the storm green round it, breathing once a bar.
        let cast: CGFloat = 1.5 * rx
        light.fill(Path(ellipseIn: CGRect(x: centre.x - cast, y: centre.y - cast, width: 2 * cast, height: 2 * cast)),
                   with: .radialGradient(Gradient(colors: [core.opacity(0.08 + 0.05 * breath), core.opacity(0)]),
                                         center: centre, startRadius: 0, endRadius: cast))

        // The shelf: the storm's dark base across the top, still, its lumps lit faintly green from beneath near the ring.
        let shelfLumps: [(x: CGFloat, y: CGFloat, r: CGFloat)] = (0..<15).map { (j: Int) -> (x: CGFloat, y: CGFloat, r: CGFloat) in
            let x: CGFloat = w * CGFloat(j) / 14 + 10 * k * CGFloat(hash(j, 301) - 0.5)
            let r: CGFloat = (20 + 16 * CGFloat(hash(j, 302))) * k
            return (x: x, y: h * (0.09 + 0.06 * CGFloat(hash(j, 303))), r: r)
        }
        var shelf = ctx
        shelf.addFilter(.blur(radius: 5 * k))
        shelf.drawLayer { layer in
            layer.fill(Path(CGRect(x: -20 * k, y: -20 * k, width: w + 40 * k, height: h * 0.07 + 20 * k)),
                       with: .color(Color(red: 0.035, green: 0.045, blue: 0.045)))
            for lump in shelfLumps {
                layer.fill(Path(ellipseIn: CGRect(x: lump.x - 1.3 * lump.r, y: lump.y - lump.r, width: 2.6 * lump.r, height: 2 * lump.r)),
                           with: .color(Color(red: 0.040, green: 0.050, blue: 0.050)))
            }
        }
        var underside = light
        underside.addFilter(.blur(radius: 4 * k))
        underside.drawLayer { layer in
            for lump in shelfLumps {
                let near: Double = max(0, 1 - Double(abs(lump.x - centre.x) / (1.4 * rx)))
                guard near > 0 else { continue }
                layer.fill(Path(ellipseIn: CGRect(x: lump.x - 0.9 * lump.r, y: lump.y + 0.40 * lump.r, width: 1.8 * lump.r, height: 0.7 * lump.r)),
                           with: .color(core.opacity(0.16 * near * (0.6 + 0.4 * breath))))
            }
        }

        // The ring, turning once a bar: forty dark puffs drawn far side first, each stretched along the ring and bigger
        // the nearer it is, and the lit inner edge, brightest on the far side where it faces us, dimmed on every beat.
        let puffs: [(a: Double, i: Int)] = (0..<40).map { (i: Int) -> (a: Double, i: Int) in
            let spread: Double = 0.4 * (hash(i, 311) - 0.5) / 40
            return (a: 2 * Double.pi * (Double(i) / 40 + spread + turn), i: i)
        }.sorted { sin($0.a) < sin($1.a) }
        func ring(_ layer: GraphicsContext, near: Bool) {
            for puff in puffs {
                let depth: Double = sin(puff.a)   // −1 at the far side … 1 at the near side
                if (depth >= 0) != near { continue }
                let out: CGFloat = 1 + 0.12 * CGFloat(hash(puff.i, 312) - 0.5)
                let p = CGPoint(x: centre.x + rx * out * CGFloat(cos(puff.a)), y: centre.y + ry * out * CGFloat(depth))
                let s: CGFloat = (15 + 13 * CGFloat(hash(puff.i, 313))) * k * (1 + 0.35 * CGFloat(depth))
                let along: Double = atan2(Double(ry) * cos(puff.a), -Double(rx) * sin(puff.a))
                let shade: Double = 0.085 + 0.04 * hash(puff.i, 314) - 0.02 * depth
                var body = layer
                body.translateBy(x: p.x, y: p.y)
                body.rotate(by: .radians(along))
                body.fill(Path(ellipseIn: CGRect(x: -1.6 * s, y: -s, width: 3.2 * s, height: 2 * s)),
                          with: .color(Color(red: 0.92 * shade, green: 1.12 * shade, blue: 1.05 * shade)))
            }
            var edge = layer
            edge.blendMode = .plusLighter
            let step: Double = 2 * Double.pi / 48
            for j in 0..<48 {
                let a0: Double = step * Double(j) + 2 * Double.pi * turn
                let depth: Double = sin(a0 + step / 2)
                if (depth >= 0) != near { continue }
                var arc = Path()
                for q in 0...4 {
                    let a: Double = a0 + 1.15 * step * Double(q) / 4
                    let pt = CGPoint(x: centre.x + 0.84 * rx * CGFloat(cos(a)), y: centre.y + 0.84 * ry * CGFloat(sin(a)))
                    if q == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
                }
                let glow: Double = 0.30 * pump * (0.5 + 0.5 * breath) * (0.65 - 0.35 * depth) * (0.35 + 0.65 * hash(j, 331))
                edge.stroke(arc, with: .color(lit.opacity(glow)),
                            style: StrokeStyle(lineWidth: (5 + 6 * CGFloat(hash(j, 332))) * k, lineCap: .round))
            }
        }
        var far = ctx
        far.addFilter(.blur(radius: 4 * k))
        far.drawLayer { layer in ring(layer, near: false) }

        // Eight bands of inflow closing in on the core, two arms each: the riser's eight octaves, climbing for ever.
        var bands = light
        bands.addFilter(.blur(radius: 2.5 * k))
        bands.drawLayer { layer in
            for band in fadeBands(at: t, pulse: pulse) where band.opacity > 0.01 {
                let r: CGFloat = CGFloat(band.radius)
                for arm in 0..<2 {
                    let from: Double = 2 * Double.pi * (band.turn + Double(arm) / 2)
                    var path = Path()
                    for q in 0...16 {
                        let a: Double = from + Double(q) / 16
                        let pt = CGPoint(x: centre.x + rx * r * CGFloat(cos(a)), y: centre.y + ry * r * CGFloat(sin(a)))
                        if q == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    layer.stroke(path, with: .color(Color(red: 0.55, green: 0.70, blue: 0.62).opacity(0.24 * band.opacity)),
                                 style: StrokeStyle(lineWidth: (1.2 + 4 * r) * k, lineCap: .round))
                }
            }
        }

        // The core: green, breathing once a bar, lying as flat as the ring a little less so.
        var heart = light
        heart.translateBy(x: centre.x, y: centre.y)
        heart.scaleBy(x: 1, y: 0.75)
        let glow: CGFloat = 0.62 * ry * CGFloat(0.85 + 0.3 * breath)
        heart.fill(Path(ellipseIn: CGRect(x: -glow, y: -glow, width: 2 * glow, height: 2 * glow)),
                   with: .radialGradient(Gradient(colors: [core.opacity(0.45 + 0.30 * breath), core.opacity(0)]),
                                         center: .zero, startRadius: 0, endRadius: glow))
        let inner: CGFloat = 0.20 * ry
        heart.fill(Path(ellipseIn: CGRect(x: -inner, y: -inner, width: 2 * inner, height: 2 * inner)),
                   with: .radialGradient(Gradient(colors: [lit.opacity(0.15 + 0.15 * breath), lit.opacity(0)]),
                                         center: .zero, startRadius: 0, endRadius: inner))

        // The hail shaft: a lit column falling from the core to the plain, leaning with the wind, its stones falling
        // once a bar.
        let top: CGFloat = centre.y + 0.15 * ry, span: CGFloat = 0.55 * rx
        let lean: CGFloat = 0.12 * (horizon - top)
        let stone = Color(red: 0.36, green: 0.50, blue: 0.42)
        var shaft = light
        shaft.addFilter(.blur(radius: 6 * k))
        shaft.drawLayer { layer in
            var column = Path()
            column.move(to: CGPoint(x: centre.x - 0.35 * span, y: top))
            column.addLine(to: CGPoint(x: centre.x + 0.35 * span, y: top))
            column.addLine(to: CGPoint(x: centre.x + 0.5 * span + lean, y: horizon))
            column.addLine(to: CGPoint(x: centre.x - 0.5 * span + lean, y: horizon))
            column.closeSubpath()
            layer.fill(column, with: .linearGradient(Gradient(colors: [stone.opacity(0.30), stone.opacity(0.08)]),
                                                     startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: horizon)))
        }
        for i in 0..<18 {
            let fall: Double = t / bar + hash(i, 321)
            let u: Double = fall - floor(fall)   // 0 at the core … 1 at the plain
            let y: CGFloat = top + (horizon - top) * CGFloat(u)
            let x: CGFloat = centre.x + span * (CGFloat(hash(i, 322)) - 0.5) * (0.7 + 0.3 * CGFloat(u)) + 0.12 * (y - top)
            let length: CGFloat = (8 + 8 * CGFloat(hash(i, 323))) * k
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: y))
            streak.addLine(to: CGPoint(x: x + 0.12 * length, y: y + length))
            ctx.stroke(streak, with: .color(Color(red: 0.70, green: 0.82, blue: 0.74).opacity(0.28 * sin(Double.pi * u))), lineWidth: k)
        }

        // The ring's near side, in front of the shaft and the core's lower half.
        var near = ctx
        near.addFilter(.blur(radius: 3 * k))
        near.drawLayer { layer in ring(layer, near: true) }

        // The plain, dark under the storm, and its horizon lit warm at the left and green under the core.
        ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.050, green: 0.056, blue: 0.044), Color(red: 0.018, green: 0.020, blue: 0.017)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))
        light.fill(Path(CGRect(x: 0, y: horizon - 0.6 * k, width: w, height: 1.2 * k)), with: .linearGradient(
            Gradient(colors: [warm.opacity(0.30), Color(red: 0.30, green: 0.42, blue: 0.34).opacity(0.30)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: w, y: horizon)))
    }

    // MARK: - Tea House Snow (a place card): a snow garden at dusk through a snow-viewing screen, the tea's steam
    // curling up over it, and thirteen faint strings along the lower edge

    private static func teaHouse(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let paperBottom: CGFloat = h * 0.30, floorTop: CGFloat = h * 0.86, horizon: CGFloat = h * 0.62
        let glassHeight: CGFloat = floorTop - paperBottom
        let breath: Double = 0.5 + 0.5 * cos(2 * Double.pi * t / pulse)   // 1 at the top of each breath
        let snow = Color(red: 0.88, green: 0.90, blue: 0.96)
        let bar = Color(red: 0.13, green: 0.10, blue: 0.09)

        // The garden at dusk, seen through the screen's glass: a lavender sky to a rosy horizon, a far rise under snow,
        // and snow in blue shadow, darker towards the sill.
        var garden = ctx
        garden.clip(to: Path(CGRect(x: 0, y: paperBottom, width: w, height: glassHeight)))
        garden.fill(Path(CGRect(x: 0, y: paperBottom, width: w, height: horizon - paperBottom)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.30, green: 0.31, blue: 0.46), location: 0),
                             .init(color: Color(red: 0.55, green: 0.51, blue: 0.63), location: 0.55),
                             .init(color: Color(red: 0.80, green: 0.67, blue: 0.70), location: 1)]),
            startPoint: CGPoint(x: 0, y: paperBottom), endPoint: CGPoint(x: 0, y: horizon)))
        var rise = Path()
        rise.move(to: CGPoint(x: 0, y: horizon + 2))
        for s in 0...48 {
            let u: Double = Double(s) / 48
            let up: Double = 0.035 + 0.03 * sin(u * 3.1 + 0.6) + 0.012 * noise2(u * 7 + 2.3, 0.5)
            rise.addLine(to: CGPoint(x: w * CGFloat(u), y: horizon - h * CGFloat(up)))
        }
        rise.addLine(to: CGPoint(x: w, y: horizon + 2))
        rise.closeSubpath()
        garden.fill(rise, with: .color(Color(red: 0.60, green: 0.62, blue: 0.73)))
        garden.fill(Path(CGRect(x: 0, y: horizon, width: w, height: floorTop - horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.74, green: 0.77, blue: 0.86), Color(red: 0.44, green: 0.48, blue: 0.61)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: floorTop)))

        // The stone lantern with its cap of snow; its candle glows a little brighter on each breath.
        let lx: CGFloat = w * 0.36, ground: CGFloat = h * 0.79
        let stone = Color(red: 0.19, green: 0.19, blue: 0.25)
        garden.fill(Path(ellipseIn: CGRect(x: lx - 46 * k, y: ground - 5 * k, width: 92 * k, height: 10 * k)),
                    with: .color(Color(red: 0.30, green: 0.33, blue: 0.45).opacity(0.5)))
        garden.fill(Path(CGRect(x: lx - 20 * k, y: ground - 14 * k, width: 40 * k, height: 14 * k)), with: .color(stone))   // base
        garden.fill(Path(CGRect(x: lx - 7 * k, y: ground - 56 * k, width: 14 * k, height: 42 * k)), with: .color(stone))    // shaft
        garden.fill(Path(CGRect(x: lx - 22 * k, y: ground - 63 * k, width: 44 * k, height: 7 * k)), with: .color(stone))    // platform
        garden.fill(Path(CGRect(x: lx - 15 * k, y: ground - 91 * k, width: 30 * k, height: 28 * k)), with: .color(stone))   // fire box
        let flicker: Double = 0.85 + 0.15 * breath + 0.05 * sin(t * 7.3)
        garden.fill(Path(CGRect(x: lx - 6 * k, y: ground - 84 * k, width: 12 * k, height: 13 * k)), with: .linearGradient(
            Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.58).opacity(0.95 * flicker),
                              Color(red: 0.95, green: 0.58, blue: 0.30).opacity(0.95 * flicker)]),
            startPoint: CGPoint(x: lx, y: ground - 84 * k), endPoint: CGPoint(x: lx, y: ground - 71 * k)))
        var candle = garden
        candle.blendMode = .plusLighter
        let flame = Color(red: 1, green: 0.70, blue: 0.40)
        candle.fill(Path(ellipseIn: CGRect(x: lx - 40 * k, y: ground - 118 * k, width: 80 * k, height: 80 * k)), with: .radialGradient(
            Gradient(colors: [flame.opacity(0.30 * flicker), flame.opacity(0)]),
            center: CGPoint(x: lx, y: ground - 78 * k), startRadius: 0, endRadius: 40 * k))
        var roof = Path()
        roof.move(to: CGPoint(x: lx - 36 * k, y: ground - 90 * k)); roof.addLine(to: CGPoint(x: lx + 36 * k, y: ground - 90 * k))
        roof.addLine(to: CGPoint(x: lx + 14 * k, y: ground - 104 * k)); roof.addLine(to: CGPoint(x: lx - 14 * k, y: ground - 104 * k))
        roof.closeSubpath()
        garden.fill(roof, with: .color(stone))
        garden.fill(Path(ellipseIn: CGRect(x: lx - 34 * k, y: ground - 112 * k, width: 68 * k, height: 20 * k)),
                    with: .color(Color(red: 0.90, green: 0.92, blue: 0.97)))                                           // snow on the roof
        garden.fill(Path(ellipseIn: CGRect(x: lx - 5 * k, y: ground - 121 * k, width: 10 * k, height: 10 * k)), with: .color(snow))   // the finial

        // A pine bough bent low with snow, reaching in over the right of the view: dark needle clumps along a drooping
        // branch, each with its cushion of snow.
        let b0 = CGPoint(x: w * 1.02, y: h * 0.335), bc = CGPoint(x: w * 0.86, y: h * 0.33), b1 = CGPoint(x: w * 0.70, y: h * 0.45)
        func bough(_ u: CGFloat) -> CGPoint {
            let m: CGFloat = 1 - u
            let a: CGFloat = m * m, b: CGFloat = 2 * m * u, c: CGFloat = u * u
            return CGPoint(x: a * b0.x + b * bc.x + c * b1.x, y: a * b0.y + b * bc.y + c * b1.y)
        }
        var limb = Path()
        limb.move(to: bough(0))
        for i in 1...16 { limb.addLine(to: bough(CGFloat(i) / 16)) }
        garden.stroke(limb, with: .color(Color(red: 0.10, green: 0.08, blue: 0.08)),
                      style: StrokeStyle(lineWidth: 3 * k, lineCap: .round, lineJoin: .round))
        for i in 0..<9 {
            let u: CGFloat = CGFloat(i) / 8
            let c = bough(u)
            let cy: CGFloat = c.y + (i % 2 == 1 ? 2.5 : -2.0) * k
            let rx: CGFloat = (21 - 9 * u) * k * (0.85 + 0.3 * CGFloat(hash(i, 51)))
            let ry: CGFloat = (8 - 2 * u) * k
            garden.fill(Path(ellipseIn: CGRect(x: c.x - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)),
                        with: .color(Color(red: 0.07, green: 0.12, blue: 0.11)))
            garden.fill(Path(ellipseIn: CGRect(x: c.x - rx * 0.85, y: cy - ry * 1.45, width: 1.7 * rx, height: ry * 1.15)), with: .color(snow))
        }

        // A plum branch over the left, with a few red blossoms.
        let plumWood = Color(red: 0.12, green: 0.09, blue: 0.10)
        var plum = Path()
        plum.move(to: CGPoint(x: -4, y: h * 0.44))
        plum.addLine(to: CGPoint(x: w * 0.08, y: h * 0.40)); plum.addLine(to: CGPoint(x: w * 0.15, y: h * 0.37))
        plum.addLine(to: CGPoint(x: w * 0.21, y: h * 0.33))
        garden.stroke(plum, with: .color(plumWood), style: StrokeStyle(lineWidth: 2.4 * k, lineCap: .round, lineJoin: .round))
        var twig = Path()
        twig.move(to: CGPoint(x: w * 0.11, y: h * 0.385)); twig.addLine(to: CGPoint(x: w * 0.14, y: h * 0.43))
        garden.stroke(twig, with: .color(plumWood), style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
        let blossoms: [(CGFloat, CGFloat)] = [(0.05, 0.415), (0.10, 0.385), (0.135, 0.425), (0.165, 0.36), (0.19, 0.345), (0.215, 0.325)]
        for (fx, fy) in blossoms {
            let r: CGFloat = 3.2 * k
            let c = CGPoint(x: w * fx, y: h * fy)
            garden.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(Color(red: 0.80, green: 0.24, blue: 0.32)))
            garden.fill(Path(ellipseIn: CGRect(x: c.x - 0.35 * r, y: c.y - 0.35 * r, width: 0.7 * r, height: 0.7 * r)),
                        with: .color(Color(red: 0.98, green: 0.85, blue: 0.70)))
        }

        // Snow falling beyond the glass: each flake crosses the view in eight breaths.
        for i in 0..<46 {
            let speed: Double = 0.8 + 0.4 * hash(i, 41)
            let u: Double = (t / (8 * pulse) * speed + hash(i, 42)).truncatingRemainder(dividingBy: 1)
            let x: CGFloat = w * CGFloat(hash(i, 43)) + 8 * k * CGFloat(sin(t * 0.7 + Double(i)))
            let y: CGFloat = paperBottom - 4 + CGFloat(u) * (glassHeight + 8)
            let r: CGFloat = (0.7 + 1.1 * CGFloat(hash(i, 44))) * k
            garden.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                        with: .color(.white.opacity(0.45 + 0.4 * hash(i, 45))))
        }

        // The paper panes above, glowing with the last of the light (a little brighter on each breath), a branch's
        // shadow on them, and their lattice.
        let glow: Double = 0.94 + 0.06 * breath
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: paperBottom)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.80 * glow, green: 0.74 * glow, blue: 0.66 * glow),
                              Color(red: 0.90 * glow, green: 0.84 * glow, blue: 0.74 * glow)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: paperBottom)))
        var shade = ctx
        shade.addFilter(.blur(radius: 2.5 * k))
        shade.drawLayer { layer in
            let ink = Color(red: 0.45, green: 0.40, blue: 0.38)
            var shadow = Path()
            shadow.move(to: CGPoint(x: w * 0.30, y: -4)); shadow.addLine(to: CGPoint(x: w * 0.38, y: h * 0.08))
            shadow.addLine(to: CGPoint(x: w * 0.47, y: h * 0.13)); shadow.addLine(to: CGPoint(x: w * 0.60, y: h * 0.15))
            layer.stroke(shadow, with: .color(ink.opacity(0.30)), style: StrokeStyle(lineWidth: 3 * k, lineCap: .round, lineJoin: .round))
            var sprig = Path()
            sprig.move(to: CGPoint(x: w * 0.43, y: h * 0.115)); sprig.addLine(to: CGPoint(x: w * 0.47, y: h * 0.21))
            layer.stroke(sprig, with: .color(ink.opacity(0.30)), style: StrokeStyle(lineWidth: 2 * k, lineCap: .round))
            let flowers: [(CGFloat, CGFloat)] = [(0.36, 0.06), (0.42, 0.11), (0.47, 0.20), (0.53, 0.14), (0.59, 0.155)]
            for (fx, fy) in flowers {
                let r: CGFloat = 4 * k
                layer.fill(Path(ellipseIn: CGRect(x: w * fx - r, y: h * fy - r, width: 2 * r, height: 2 * r)), with: .color(ink.opacity(0.22)))
            }
        }
        for c in 1..<8 {
            ctx.fill(Path(CGRect(x: w * CGFloat(c) / 8 - 0.6 * k, y: 0, width: 1.2 * k, height: paperBottom)), with: .color(bar))
        }
        for fy: CGFloat in [0.10, 0.20] {
            ctx.fill(Path(CGRect(x: 0, y: h * fy - 0.6 * k, width: w, height: 1.2 * k)), with: .color(bar))
        }
        // The screen's frame over the glass: two thin bars, the meeting stiles, the edges and the rail under the paper.
        for fx: CGFloat in [0.25, 0.75] {
            ctx.fill(Path(CGRect(x: w * fx - 1.1 * k, y: paperBottom, width: 2.2 * k, height: glassHeight)), with: .color(bar))
        }
        ctx.fill(Path(CGRect(x: w * 0.5 - 3.5 * k, y: 0, width: 7 * k, height: floorTop)), with: .color(bar))
        ctx.fill(Path(CGRect(x: 0, y: 0, width: 4 * k, height: floorTop)), with: .color(bar))
        ctx.fill(Path(CGRect(x: w - 4 * k, y: 0, width: 4 * k, height: floorTop)), with: .color(bar))
        ctx.fill(Path(CGRect(x: 0, y: paperBottom - 2.5 * k, width: w, height: 5 * k)), with: .color(bar))

        // The room's floor below the sill, the brazier's warmth at the right (breathing), and the koto's thirteen strings,
        // faint along the lower edge, a shimmer crossing them on each breath, their bridges standing in a slanting line.
        ctx.fill(Path(CGRect(x: 0, y: floorTop, width: w, height: h - floorTop)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.17, green: 0.12, blue: 0.11), Color(red: 0.07, green: 0.05, blue: 0.05)]),
            startPoint: CGPoint(x: 0, y: floorTop), endPoint: CGPoint(x: 0, y: h)))
        ctx.fill(Path(CGRect(x: 0, y: floorTop - 3.5 * k, width: w, height: 7 * k)), with: .color(Color(red: 0.10, green: 0.07, blue: 0.07)))
        var warmth = ctx
        warmth.blendMode = .plusLighter
        let ember: Double = 0.85 + 0.15 * breath
        let brazier = Color(red: 0.85, green: 0.42, blue: 0.18)
        warmth.fill(Path(ellipseIn: CGRect(x: w * 0.80, y: h * 0.80, width: w * 0.40, height: h * 0.40)), with: .radialGradient(
            Gradient(colors: [brazier.opacity(0.28 * ember), brazier.opacity(0)]),
            center: CGPoint(x: w, y: h), startRadius: 0, endRadius: w * 0.22))
        let silk = Color(red: 0.93, green: 0.88, blue: 0.78)
        for (i, fy) in Self.teaHouseStrings.enumerated() {
            let y: CGFloat = h * fy
            let wave: Double = 0.5 + 0.5 * cos(2 * Double.pi * (t / pulse - Double(i) / 13))
            ctx.fill(Path(CGRect(x: 0, y: y - 0.35 * k, width: w, height: 0.7 * k)), with: .color(silk.opacity(0.16 + 0.14 * wave)))
            let bx: CGFloat = w * (0.80 + 0.012 * CGFloat(i))
            var bridge = Path()
            bridge.move(to: CGPoint(x: bx - 2.2 * k, y: y + 0.4 * k)); bridge.addLine(to: CGPoint(x: bx, y: y - 2.2 * k))
            bridge.addLine(to: CGPoint(x: bx + 2.2 * k, y: y + 0.4 * k)); bridge.closeSubpath()
            ctx.fill(bridge, with: .color(silk.opacity(0.35)))
        }

        // The tea's steam: three wisps rising from the bowl just below the card, widening and curling as they climb
        // over the garden, each its own way; the curls rise a wavelength every two breaths.
        func wisp(_ layer: GraphicsContext, _ index: Int, width: (Double) -> Double, opacity: Double) {
            let p = Self.steamWisps[index]
            var previous: CGPoint?
            for s in 0...28 {
                let u: Double = Double(s) / 28
                let sway: Double = (p.a0 + p.a1 * u) * sin(2 * Double.pi * (p.f * u - t / (2 * pulse)) + p.phase)
                let drift: Double = p.drift * u * u + 0.025 * (noise2(u * 3 + Double(index) * 5.7, t * 0.35) - 0.5)
                let point = CGPoint(x: w * CGFloat(p.x + sway + drift), y: h - h * CGFloat(u * p.top))
                if let from = previous {
                    let a: Double = opacity * min(1, u / 0.15) * pow(max(0, 1 - u), 1.3) * (0.75 + 0.25 * breath)
                    var segment = Path()
                    segment.move(to: from); segment.addLine(to: point)
                    layer.stroke(segment, with: .color(.white.opacity(a)), style: StrokeStyle(lineWidth: k * CGFloat(width(u)), lineCap: .round))
                }
                previous = point
            }
        }
        var steam = ctx
        steam.blendMode = .plusLighter
        steam.addFilter(.blur(radius: 5 * k))
        steam.drawLayer { layer in for i in 0..<3 { wisp(layer, i, width: { 5 + 18 * $0 }, opacity: 0.30) } }
        var core = ctx
        core.blendMode = .plusLighter
        core.addFilter(.blur(radius: 1.2 * k))
        core.drawLayer { layer in for i in 0..<3 { wisp(layer, i, width: { 1.2 + 1.5 * $0 }, opacity: 0.28) } }
    }

    // MARK: - Zen Rock Garden (a place card): a dry garden at dawn seen from a temple hall's veranda, raked circles round
    // five stones, and the eave's bamboo pole along the top with its five rings

    private static func rockGarden(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let breath: Double = 0.5 + 0.5 * cos(2 * Double.pi * t / pulse)   // 1 at the top of each breath
        let poleTop: CGFloat = h * rockGardenPole.lowerBound, poleBottom: CGFloat = h * rockGardenPole.upperBound
        let cap: CGFloat = h * 0.235, wallBottom: CGFloat = h * 0.345, near: CGFloat = h * 0.715, veranda: CGFloat = h * 0.80
        var light = ctx
        light.blendMode = .plusLighter

        // The sky at dawn beyond the wall, blue-violet to rose to apricot, and the sun's glow low on the left behind the
        // woods, a little brighter on each breath.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: wallBottom)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.46, green: 0.50, blue: 0.68), location: 0),
                             .init(color: Color(red: 0.84, green: 0.72, blue: 0.76), location: 0.5),
                             .init(color: Color(red: 0.99, green: 0.82, blue: 0.64), location: 1)]),
            startPoint: CGPoint(x: 0, y: poleBottom), endPoint: CGPoint(x: 0, y: cap)))
        let dawn = Color(red: 1, green: 0.74, blue: 0.46)
        let sun = CGPoint(x: w * 0.06, y: cap - 2 * k)
        light.fill(Path(ellipseIn: CGRect(x: sun.x - 170 * k, y: sun.y - 120 * k, width: 340 * k, height: 240 * k)), with: .radialGradient(
            Gradient(colors: [dawn.opacity(0.22 + 0.05 * breath), dawn.opacity(0)]), center: sun, startRadius: 0, endRadius: 170 * k))

        // The temple's woods beyond the wall: rounded crowns in two layers, the far one hazy in the dawn.
        let woods: [(colour: Color, rise: CGFloat, small: CGFloat, large: CGFloat, seed: Int)] = [
            (Color(red: 0.62, green: 0.60, blue: 0.66), 26, 14, 22, 101), (Color(red: 0.30, green: 0.34, blue: 0.32), 14, 11, 19, 111)]
        for layer in woods {
            for i in 0..<26 {
                let x: CGFloat = w * (CGFloat(i) + CGFloat(hash(i, layer.seed))) / 25 - 10 * k
                let r: CGFloat = (layer.small + (layer.large - layer.small) * CGFloat(hash(i, layer.seed + 1))) * k
                let y: CGFloat = cap - layer.rise * k * (0.4 + 0.6 * CGFloat(hash(i, layer.seed + 2))) + r * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 1.3, y: y - r, width: r * 2.6, height: r * 2)), with: .color(layer.colour))
            }
        }
        // A tall cedar among them at the left, its crown lost above the eave: needle clumps drooping from a dark trunk.
        let cedarX: CGFloat = w * 0.16
        ctx.fill(Path(CGRect(x: cedarX - 2.2 * k, y: poleBottom, width: 4.4 * k, height: cap - poleBottom)),
                 with: .color(Color(red: 0.16, green: 0.12, blue: 0.11)))
        for i in 0..<80 {
            let u: CGFloat = CGFloat(hash(i, 121))
            let y: CGFloat = poleBottom + (cap - poleBottom) * u
            let half: CGFloat = (14 + 30 * u) * k
            let x: CGFloat = cedarX + half * (2 * CGFloat(hash(i, 122)) - 1)
            let r: CGFloat = (5 + 5 * CGFloat(hash(i, 123))) * k
            let shade: Double = 0.10 + 0.07 * hash(i, 124)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - 0.45 * r, width: 2 * r, height: 0.9 * r)),
                     with: .color(Color(red: shade, green: shade + 0.05, blue: shade + 0.04)))
        }
        // A maple beyond the wall at the right, red with autumn, reaching in over the cap.
        let bark = Color(red: 0.17, green: 0.12, blue: 0.11)
        let trunk: [CGPoint] = [CGPoint(x: w * 0.905, y: cap + 3 * k), CGPoint(x: w * 0.895, y: h * 0.17),
                                CGPoint(x: w * 0.86, y: h * 0.125), CGPoint(x: w * 0.80, y: h * 0.115)]
        let bough: [CGPoint] = [CGPoint(x: w * 0.893, y: h * 0.165), CGPoint(x: w * 0.95, y: h * 0.125), CGPoint(x: w * 1.01, y: h * 0.12)]
        let twig: [CGPoint] = [CGPoint(x: w * 0.86, y: h * 0.125), CGPoint(x: w * 0.84, y: h * 0.20)]
        let limbs: [([CGPoint], CGFloat)] = [(trunk, 3.6), (bough, 2.6), (twig, 1.6)]
        for (points, width) in limbs {
            var limb = Path()
            limb.addLines(points)
            ctx.stroke(limb, with: .color(bark), style: StrokeStyle(lineWidth: width * k, lineCap: .round, lineJoin: .round))
        }
        for i in 0..<90 {
            let a: Double = 2 * Double.pi * hash(i, 61), reach: Double = hash(i, 62).squareRoot()
            let x: CGFloat = w * 0.88 + 72 * k * CGFloat(reach * cos(a))
            let y: CGFloat = h * 0.150 + 26 * k * CGFloat(reach * sin(a))
            let r: CGFloat = (4 + 3 * CGFloat(hash(i, 63))) * k
            let shade: Double = hash(i, 64)
            let red = Color(red: 0.62 + 0.30 * shade, green: 0.12 + 0.30 * hash(i, 65) * shade, blue: 0.08 + 0.06 * hash(i, 66))
            ctx.fill(mapleLeaf(CGPoint(x: x, y: y), r, 2 * Double.pi * hash(i, 67)), with: .color(red.opacity(0.95)))
        }

        // The low earthen wall: the clay face with its old oil stains, a damp foot, and the tiled cap with its round ends.
        ctx.fill(Path(CGRect(x: 0, y: cap, width: w, height: wallBottom - cap)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.80, green: 0.66, blue: 0.48), Color(red: 0.66, green: 0.52, blue: 0.38)]),
            startPoint: CGPoint(x: 0, y: cap), endPoint: CGPoint(x: 0, y: wallBottom)))
        let stain = Color(red: 0.45, green: 0.33, blue: 0.24)
        for i in 0..<16 {
            let x: CGFloat = w * CGFloat(hash(i, 75)), width: CGFloat = (14 + 30 * CGFloat(hash(i, 76))) * k
            let top: CGFloat = cap + (6 + 14 * CGFloat(hash(i, 77))) * k
            ctx.fill(Path(CGRect(x: x, y: top, width: width, height: wallBottom - top)), with: .linearGradient(
                Gradient(colors: [stain.opacity(0), stain.opacity(0.22 + 0.12 * hash(i, 78))]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: wallBottom)))
        }
        ctx.fill(Path(CGRect(x: 0, y: wallBottom - 3.5 * k, width: w, height: 3.5 * k)), with: .color(Color(red: 0.50, green: 0.39, blue: 0.30)))
        ctx.fill(Path(CGRect(x: 0, y: cap - 7 * k, width: w, height: 9 * k)), with: .color(Color(red: 0.21, green: 0.21, blue: 0.24)))
        ctx.fill(Path(CGRect(x: 0, y: cap - 9 * k, width: w, height: 2.6 * k)), with: .color(Color(red: 0.36, green: 0.36, blue: 0.40)))
        for i in 0..<40 {
            let x: CGFloat = w * (CGFloat(i) + 0.5) / 40
            ctx.fill(Path(ellipseIn: CGRect(x: x - 3.9 * k, y: cap - 1.5 * k, width: 7.8 * k, height: 7 * k)),
                     with: .color(Color(red: 0.26, green: 0.26, blue: 0.29)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2 * k, y: cap + 0.2 * k, width: 4 * k, height: 3.4 * k)),
                     with: .color(Color(red: 0.33, green: 0.33, blue: 0.37)))
        }
        // Mist drifting along the foot of the wall.
        var mist = ctx
        mist.addFilter(.blur(radius: 8 * k))
        mist.drawLayer { layer in
            let span = Double(w + 160 * k)
            for i in 0..<9 {
                let travel: Double = Double(w) * hash(i, 71) + t * 10 * Double(k) * (0.6 + hash(i, 72))
                let x: CGFloat = CGFloat(travel.truncatingRemainder(dividingBy: span)) - 80 * k
                layer.fill(Path(ellipseIn: CGRect(x: x - 70 * k, y: wallBottom - 12 * k, width: 140 * k, height: 22 * k)),
                           with: .color(Color(red: 1, green: 0.97, blue: 0.93).opacity(0.20)))
            }
        }

        // The gravel: white and warm in the low sun (which breathes on it), hazier towards the wall, and the hall's shadow
        // over the near part.
        ctx.fill(Path(CGRect(x: 0, y: wallBottom, width: w, height: veranda - wallBottom)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.80, green: 0.79, blue: 0.78), Color(red: 0.92, green: 0.89, blue: 0.83)]),
            startPoint: CGPoint(x: 0, y: wallBottom), endPoint: CGPoint(x: 0, y: near)))
        let morning = Color(red: 1, green: 0.84, blue: 0.62)
        light.fill(Path(ellipseIn: CGRect(x: -w * 0.45, y: wallBottom - h * 0.25, width: w * 1.1, height: h * 0.9)), with: .radialGradient(
            Gradient(colors: [morning.opacity(0.09 + 0.08 * breath), morning.opacity(0)]),
            center: CGPoint(x: 0, y: wallBottom), startRadius: 0, endRadius: w * 0.62))
        let hallShadow = Color(red: 0.44, green: 0.47, blue: 0.56)
        ctx.fill(Path(CGRect(x: 0, y: near - 8 * k, width: w, height: veranda - near + 8 * k)), with: .linearGradient(
            Gradient(stops: [.init(color: hallShadow.opacity(0), location: 0), .init(color: hallShadow.opacity(0.55), location: 0.35),
                             .init(color: Color(red: 0.38, green: 0.41, blue: 0.50).opacity(0.75), location: 1)]),
            startPoint: CGPoint(x: 0, y: near - 8 * k), endPoint: CGPoint(x: 0, y: veranda)))

        // The straight rake lines between the groups: a lit ridge over its shadowed side, the grooves growing towards the
        // viewer, each line stopping a gravel-width short of a group's rings.
        let ringCount = 4, ringStep: CGFloat = 10, lines = 22
        func depth(_ y: CGFloat) -> CGFloat { 0.55 + 0.45 * (y - wallBottom) / (veranda - wallBottom) }
        let ridge = Color(red: 1, green: 0.98, blue: 0.93), furrow = Color(red: 0.50, green: 0.50, blue: 0.57)
        for i in 1..<lines {
            let y: CGFloat = wallBottom + (veranda - wallBottom) * CGFloat(pow(Double(i) / Double(lines), 1.3))
            let s: CGFloat = depth(y)
            var runs: [(CGFloat, CGFloat)] = [(0, w)]
            for g in Self.rockGardenGroups {
                let rx: CGFloat = (g.ring + ringStep * CGFloat(ringCount - 1) + 6) * k
                let dy: CGFloat = (y - h * g.y) / (rx * g.squash)
                guard abs(dy) < 1 else { continue }
                let half: CGFloat = rx * (1 - dy * dy).squareRoot()
                let lo: CGFloat = w * g.x - half, hi: CGFloat = w * g.x + half
                var next: [(CGFloat, CGFloat)] = []
                for (a, b) in runs {
                    if b <= lo || a >= hi { next.append((a, b)); continue }
                    if a < lo { next.append((a, lo)) }
                    if b > hi { next.append((hi, b)) }
                }
                runs = next
            }
            for (a, b) in runs {
                ctx.fill(Path(CGRect(x: a, y: y + 0.6 * k * s, width: b - a, height: 1.3 * k * s)), with: .color(furrow.opacity(0.42)))
                ctx.fill(Path(CGRect(x: a, y: y - 0.6 * k * s, width: b - a, height: k * s)), with: .color(ridge.opacity(0.60)))
            }
        }

        // The three groups: rings breathing outward on each breath as if just raked, a moss island, and five stones in all,
        // each lit from the low sun on the left and casting its long morning shadow to the right.
        for (gi, g) in Self.rockGardenGroups.enumerated() {
            let cx: CGFloat = w * g.x, cy: CGFloat = h * g.y
            let s: CGFloat = depth(cy)
            for j in (0..<ringCount).reversed() {
                let rx: CGFloat = (g.ring + ringStep * CGFloat(j)) * k
                let ry: CGFloat = rx * g.squash
                let phase: Double = frac(t / pulse - Double(j) / Double(ringCount) - Double(gi) * 0.21)
                let glint: Double = 0.5 + 0.5 * exp(-phase * 3.5)
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: cy + 0.8 * k * s - ry, width: 2 * rx, height: 2 * ry)),
                           with: .color(furrow.opacity(0.45)), lineWidth: 1.4 * k * s)
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: cy - 0.4 * k * s - ry, width: 2 * rx, height: 2 * ry)),
                           with: .color(ridge.opacity(0.70 * glint)), lineWidth: 1.1 * k * s)
            }
            let mx: CGFloat = g.moss * k, my: CGFloat = g.moss * k * g.squash * 1.25
            ctx.fill(Path(ellipseIn: CGRect(x: cx - mx * 1.05, y: cy - my * 0.95, width: mx * 2.1, height: my * 2)),
                     with: .color(Color(red: 0.15, green: 0.22, blue: 0.12)))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - mx, y: cy - my, width: mx * 2, height: my * 1.85)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.38, green: 0.48, blue: 0.23), Color(red: 0.20, green: 0.31, blue: 0.15)]),
                startPoint: CGPoint(x: cx, y: cy - my), endPoint: CGPoint(x: cx, y: cy + my)))
            for q in 0..<14 {
                let a: Double = 2 * Double.pi * hash(gi * 31 + q, 81)
                let reach: CGFloat = CGFloat(hash(gi * 31 + q, 82).squareRoot())
                let p = CGPoint(x: cx + mx * 0.85 * reach * CGFloat(cos(a)), y: cy + my * 0.75 * reach * CGFloat(sin(a)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.2 * k, y: p.y - k, width: 4.4 * k, height: 2 * k)),
                         with: .color(Color(red: 0.50, green: 0.60, blue: 0.29).opacity(0.6)))
            }
            for stone in g.stones {
                let bx: CGFloat = cx + stone.dx * k, by: CGFloat = cy + stone.dy * k
                let hw: CGFloat = stone.half * k, tall: CGFloat = stone.tall * k
                ctx.fill(Path(ellipseIn: CGRect(x: bx - 0.2 * hw, y: by - 3 * k, width: hw * 2.6 + tall * 0.8, height: 6 * k)),
                         with: .color(Color(red: 0.11, green: 0.16, blue: 0.11).opacity(0.55)))
                var body = Path()
                body.addLines([CGPoint(x: bx - hw, y: by), CGPoint(x: bx - hw * 0.95, y: by - tall * 0.55),
                               CGPoint(x: bx - hw * 0.55, y: by - tall * 0.92), CGPoint(x: bx - hw * 0.05, y: by - tall),
                               CGPoint(x: bx + hw * 0.6, y: by - tall * 0.8), CGPoint(x: bx + hw, y: by - tall * 0.35),
                               CGPoint(x: bx + hw * 1.05, y: by)])
                body.closeSubpath()
                ctx.fill(body, with: .color(Color(red: 0.26, green: 0.25, blue: 0.24)))
                var lit = Path()
                lit.addLines([CGPoint(x: bx - hw, y: by - k), CGPoint(x: bx - hw * 0.95, y: by - tall * 0.55),
                              CGPoint(x: bx - hw * 0.55, y: by - tall * 0.92), CGPoint(x: bx - hw * 0.05, y: by - tall),
                              CGPoint(x: bx + hw * 0.05, y: by - tall * 0.55), CGPoint(x: bx - hw * 0.35, y: by - k)])
                lit.closeSubpath()
                ctx.fill(lit, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.66, green: 0.60, blue: 0.52), Color(red: 0.40, green: 0.37, blue: 0.34)]),
                    startPoint: CGPoint(x: bx - hw, y: by - tall), endPoint: CGPoint(x: bx, y: by)))
            }
        }
        // Two maple leaves drifting down over the wall into the garden, each taking eight breaths.
        for leaf in 0..<2 {
            let u: Double = frac(t / (8 * pulse) + Double(leaf) * 0.5)
            let sway: Double = sin(2 * Double.pi * (u * 2.5 + Double(leaf) * 0.3))
            let x: CGFloat = w * CGFloat(0.84 - 0.24 * u) + 12 * k * CGFloat(sway)
            let y: CGFloat = h * CGFloat(0.16 + 0.52 * u)
            let fade: Double = min(1, (1 - u) / 0.15) * min(1, u / 0.05)
            ctx.fill(mapleLeaf(CGPoint(x: x, y: y), 4.6 * k, 2 * Double.pi * (u * 1.5 + Double(leaf) * 0.4)),
                     with: .color(Color(red: 0.86, green: 0.28, blue: 0.12).opacity(0.9 * fade)))
        }

        // The veranda's boards below the garden, their edge catching the dawn.
        ctx.fill(Path(CGRect(x: 0, y: veranda, width: w, height: h - veranda)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.24, green: 0.17, blue: 0.12), Color(red: 0.09, green: 0.06, blue: 0.05)]),
            startPoint: CGPoint(x: 0, y: veranda), endPoint: CGPoint(x: 0, y: h)))
        ctx.fill(Path(CGRect(x: 0, y: veranda, width: w, height: 2.2 * k)), with: .color(Color(red: 0.86, green: 0.66, blue: 0.44).opacity(0.75)))
        for fy: CGFloat in [0.865, 0.935] {
            ctx.fill(Path(CGRect(x: 0, y: h * fy, width: w, height: 0.8 * k)), with: .color(Color(red: 0.05, green: 0.03, blue: 0.02).opacity(0.6)))
        }

        // The eave above: its dark underside, and the bamboo pole along the top with its five rings (the shakuhachi's five
        // holes); a glint runs along the rings, one after another, on each breath.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: poleTop + k)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.07), Color(red: 0.19, green: 0.15, blue: 0.12)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: poleTop)))
        ctx.fill(Path(CGRect(x: 0, y: poleTop, width: w, height: poleBottom - poleTop)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.40, green: 0.38, blue: 0.20), location: 0),
                             .init(color: Color(red: 0.80, green: 0.75, blue: 0.47), location: 0.32),
                             .init(color: Color(red: 0.56, green: 0.52, blue: 0.29), location: 0.6),
                             .init(color: Color(red: 0.30, green: 0.28, blue: 0.14), location: 1)]),
            startPoint: CGPoint(x: 0, y: poleTop), endPoint: CGPoint(x: 0, y: poleBottom)))
        ctx.fill(Path(CGRect(x: 0, y: poleBottom, width: w, height: 2.5 * k)), with: .color(Color(red: 0.10, green: 0.08, blue: 0.06).opacity(0.40)))
        let glow = Color(red: 1, green: 0.92, blue: 0.66)
        let ringCountOnPole = Double(Self.rockGardenRings.count)
        for (i, fx) in Self.rockGardenRings.enumerated() {
            let x: CGFloat = w * fx
            let glint: Double = exp(-frac(t / pulse - Double(i) / ringCountOnPole) * 5)
            let node = CGRect(x: x - 2.6 * k, y: poleTop - 1.2 * k, width: 5.2 * k, height: poleBottom - poleTop + 2.4 * k)
            ctx.fill(Path(node), with: .linearGradient(
                Gradient(stops: [.init(color: Color(red: 0.34, green: 0.31, blue: 0.15), location: 0),
                                 .init(color: Color(red: 0.72, green: 0.67, blue: 0.40), location: 0.35),
                                 .init(color: Color(red: 0.25, green: 0.23, blue: 0.11), location: 1)]),
                startPoint: CGPoint(x: 0, y: poleTop), endPoint: CGPoint(x: 0, y: poleBottom)))
            ctx.fill(Path(CGRect(x: x - 0.6 * k, y: node.minY, width: 1.2 * k, height: node.height)),
                     with: .color(Color(red: 0.18, green: 0.16, blue: 0.08)))
            let middle = CGPoint(x: x, y: (poleTop + poleBottom) / 2)
            light.fill(Path(ellipseIn: CGRect(x: x - 14 * k, y: poleTop - 8 * k, width: 28 * k, height: poleBottom - poleTop + 16 * k)),
                       with: .radialGradient(Gradient(colors: [glow.opacity(0.55 * glint), glow.opacity(0)]),
                                             center: middle, startRadius: 0, endRadius: 14 * k))
        }
    }

    /// A maple leaf: five points, alternating between `r` and 0.45 `r` from its centre, turned by `a`.
    private static func mapleLeaf(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> Path {
        var p = Path()
        for q in 0..<10 {
            let reach: CGFloat = q % 2 == 0 ? r : r * 0.45
            let angle: Double = a + Double(q) * Double.pi / 5
            let point = CGPoint(x: c.x + reach * CGFloat(cos(angle)), y: c.y + reach * CGFloat(sin(angle)))
            if q == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    /// The fractional part, in 0..<1 for a negative x too (a phase that started before time zero).
    private static func frac(_ x: Double) -> Double { x - x.rounded(.down) }

    // MARK: - Great Barrier Reef (a place card): a coral cay's lagoon seen from the waterline, three coral heads with 1, 4
    // and 10 polyps lit (the bar's 1 : 4 : 10), and a school curving over them

    /// Where coral head `index`'s polyps sit, the lit ones first: in two rings over the brain coral's dome with the lit one
    /// at its crown, along the plate coral's rim with the lit ones spread evenly among the rest, at the staghorn's tips.
    private static func reefPolyps(_ index: Int, _ size: CGSize) -> [CGPoint] {
        let head = reefCoralHeads[index]
        let k: CGFloat = size.width / 600
        let cx: CGFloat = size.width * head.x, base: CGFloat = size.height * head.y, s: CGFloat = head.size * k
        let n = head.polyps
        var points: [CGPoint] = []
        switch index {
        case 0:
            let ry: CGFloat = 0.66 * s
            points.append(CGPoint(x: cx - 0.12 * s, y: base - 0.80 * ry))
            for j in 1..<max(1, n) {
                let a: CGFloat = .pi * (0.14 + 0.72 * CGFloat(j - 1) / CGFloat(max(1, n - 2)))
                let r: CGFloat = j % 2 == 1 ? 0.82 : 0.52
                points.append(CGPoint(x: cx - s * r * cos(a), y: base - ry * r * sin(a)))
            }
        case 1:
            let cy: CGFloat = base - 0.56 * s, ry: CGFloat = 0.15 * s
            let step = max(1, n / max(1, head.lit))
            let lit = (0..<head.lit).map { 1 + $0 * step }
            for slot in lit + (0..<n).filter({ !lit.contains($0) }) {
                let a: CGFloat = .pi * (0.06 + 0.88 * CGFloat(slot) / CGFloat(max(1, n - 1)))
                points.append(CGPoint(x: cx - 0.92 * s * cos(a), y: cy - 0.92 * ry * sin(a)))
            }
        default:
            for j in 0..<n {
                let a: CGFloat = .pi * (0.13 + 0.74 * CGFloat(j) / CGFloat(max(1, n - 1)))
                let reach: CGFloat = s * (0.78 + 0.22 * CGFloat(hash(j, 61)))
                points.append(CGPoint(x: cx - 1.05 * reach * cos(a), y: base - reach * sin(a)))
            }
        }
        return points
    }

    private static func reef(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let waterline: CGFloat = h * 0.42, sea: CGFloat = waterline - 9 * k
        let phase: Double = (t / pulse).truncatingRemainder(dividingBy: 1)   // 0 at the top of each breath
        let white = Color.white

        // The sky over the Coral Sea, deep blue overhead to a warm, pale horizon, with two small clouds and three terns
        // wheeling over the cay.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: waterline)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.20, green: 0.46, blue: 0.82), location: 0),
                             .init(color: Color(red: 0.50, green: 0.74, blue: 0.93), location: 0.6),
                             .init(color: Color(red: 0.93, green: 0.90, blue: 0.82), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: waterline)))
        let puffs: [(x: CGFloat, y: CGFloat, scale: CGFloat, seed: Int)] = [(0.50, 0.22, 1.0, 50), (0.80, 0.30, 0.7, 80)]
        var clouds = ctx
        clouds.addFilter(.blur(radius: 3 * k))
        clouds.drawLayer { layer in
            for p in puffs {
                let cx: CGFloat = w * p.x + 6 * k * CGFloat(sin(t * 0.05 + Double(p.x) * 9)), cy: CGFloat = h * p.y
                for j in 0..<5 {
                    let r: CGFloat = (10 + 7 * CGFloat(Self.hash(j, p.seed))) * p.scale * k
                    let x: CGFloat = cx + CGFloat(j - 2) * 11 * p.scale * k - r
                    let y: CGFloat = cy - r * (0.7 + 0.3 * CGFloat(j % 2))
                    layer.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2 * r, height: 1.4 * r)), with: .color(white.opacity(0.75)))
                }
            }
        }
        for i in 0..<3 {
            let bx: CGFloat = w * (0.12 + 0.08 * CGFloat(i)) + 10 * k * CGFloat(sin(t * 0.35 + Double(i) * 2.1))
            let by: CGFloat = h * (0.12 + 0.05 * CGFloat(i % 2)) + 5 * k * CGFloat(sin(t * 0.5 + Double(i) * 1.3))
            let lift: CGFloat = (1 + 2 * CGFloat(0.5 + 0.5 * sin(t * 3.1 + Double(i)))) * k
            var tern = Path()
            tern.move(to: CGPoint(x: bx - 6 * k, y: by - lift))
            tern.addLine(to: CGPoint(x: bx, y: by + 1.2 * k))
            tern.addLine(to: CGPoint(x: bx + 6 * k, y: by - lift))
            ctx.stroke(tern, with: .color(white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round, lineJoin: .round))
        }

        // The lagoon seen edge-on, a band of deep blue, with the far reef crest breaking white along it at the right.
        ctx.fill(Path(CGRect(x: 0, y: sea, width: w, height: waterline - sea)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.12, green: 0.42, blue: 0.68), Color(red: 0.22, green: 0.62, blue: 0.78)]),
            startPoint: CGPoint(x: 0, y: sea), endPoint: CGPoint(x: 0, y: waterline)))
        for i in 0..<30 {
            let u: Double = Double(i) / 29
            let x: CGFloat = w * CGFloat(0.40 + 0.62 * u)
            let surf: Double = 0.3 + 0.7 * noise2(u * 9 + t * 0.6, Double(i) * 0.3)
            ctx.fill(Path(ellipseIn: CGRect(x: x - 10 * k, y: sea - 1.4 * k, width: 20 * k, height: 3.4 * k)),
                     with: .color(white.opacity(0.75 * surf)))
        }

        // The low white cay on the left: its sand, the pisonia trees' dark canopy and a fringe of beach grass.
        var cay = Path()
        cay.move(to: CGPoint(x: -4, y: sea + 2 * k))
        for s in 0...40 {
            let u: Double = Double(s) / 40
            let up: Double = 0.040 * max(0, sin(Double.pi * u)).squareRoot()
            cay.addLine(to: CGPoint(x: -4 + (w * 0.38 + 4) * CGFloat(u), y: sea + 2 * k - h * CGFloat(up)))
        }
        cay.addLine(to: CGPoint(x: w * 0.38, y: sea + 2 * k))
        cay.closeSubpath()
        ctx.fill(cay, with: .linearGradient(Gradient(colors: [Color(red: 1.0, green: 0.98, blue: 0.92), Color(red: 0.92, green: 0.88, blue: 0.76)]),
                                            startPoint: CGPoint(x: 0, y: sea - h * 0.04), endPoint: CGPoint(x: 0, y: sea)))
        var canopy = Path()
        canopy.move(to: CGPoint(x: w * 0.05, y: sea - h * 0.026))
        for s in 0...32 {
            let u: Double = Double(s) / 32
            let lump: Double = 0.030 + 0.016 * abs(sin(u * 7.3 + 0.8)) + 0.008 * noise2(u * 11, 2.2)
            let rise: Double = 0.026 + lump * pow(max(0, sin(Double.pi * u)), 0.4)
            canopy.addLine(to: CGPoint(x: w * CGFloat(0.05 + 0.25 * u), y: sea - h * CGFloat(rise)))
        }
        canopy.addLine(to: CGPoint(x: w * 0.30, y: sea - h * 0.026))
        canopy.closeSubpath()
        ctx.fill(canopy, with: .linearGradient(Gradient(colors: [Color(red: 0.22, green: 0.48, blue: 0.30), Color(red: 0.12, green: 0.32, blue: 0.20)]),
                                               startPoint: CGPoint(x: 0, y: sea - h * 0.08), endPoint: CGPoint(x: 0, y: sea - h * 0.026)))
        for i in 0..<16 {
            let gx: CGFloat = w * (0.035 + 0.018 * CGFloat(i)) + 2 * k * CGFloat(hash(i, 71))
            let gy: CGFloat = sea - h * 0.024 - k * CGFloat(hash(i, 72))
            var blade = Path()
            blade.move(to: CGPoint(x: gx, y: gy))
            blade.addLine(to: CGPoint(x: gx + 2 * k * CGFloat(hash(i, 73) - 0.5), y: gy - (4 + 3 * CGFloat(hash(i, 74))) * k))
            ctx.stroke(blade, with: .color(Color(red: 0.58, green: 0.68, blue: 0.34)), style: StrokeStyle(lineWidth: k, lineCap: .round))
        }

        // Below the waterline: clear turquoise, deepening; the underside of the surface bright, and light shafts from it,
        // swaying.
        var water = ctx
        water.clip(to: Path(CGRect(x: 0, y: waterline, width: w, height: h - waterline)))
        water.fill(Path(CGRect(x: 0, y: waterline, width: w, height: h - waterline)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.26, green: 0.80, blue: 0.80), location: 0),
                             .init(color: Color(red: 0.07, green: 0.50, blue: 0.62), location: 0.45),
                             .init(color: Color(red: 0.02, green: 0.22, blue: 0.36), location: 1)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: h)))
        var light = water
        light.blendMode = .plusLighter
        let shine = Color(red: 0.60, green: 0.95, blue: 0.92)
        light.fill(Path(CGRect(x: 0, y: waterline, width: w, height: 22 * k)), with: .linearGradient(
            Gradient(colors: [shine.opacity(0.30), shine.opacity(0)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: waterline + 22 * k)))
        for i in 0..<5 {
            let x: CGFloat = w * (0.10 + 0.21 * CGFloat(i)) + 16 * k * CGFloat(sin(t * 0.21 + Double(i) * 1.9))
            let spread: CGFloat = (55 + 18 * CGFloat(i % 2)) * k
            var shaft = Path()
            shaft.move(to: CGPoint(x: x - 10 * k, y: waterline)); shaft.addLine(to: CGPoint(x: x + 14 * k, y: waterline))
            shaft.addLine(to: CGPoint(x: x + 14 * k + spread, y: h)); shaft.addLine(to: CGPoint(x: x - 6 * k + 0.55 * spread, y: h))
            shaft.closeSubpath()
            light.fill(shaft, with: .linearGradient(Gradient(colors: [white.opacity(0.13), white.opacity(0)]),
                                                    startPoint: CGPoint(x: x, y: waterline), endPoint: CGPoint(x: x + 0.5 * spread, y: h * 0.95)))
        }

        // Soft corals swaying behind, dim in the blue.
        let frond = Color(red: 0.10, green: 0.36, blue: 0.48).opacity(0.8)
        for fan in Self.reefFans {
            let bx: CGFloat = w * fan.x, by: CGFloat = h * fan.y, tall: CGFloat = fan.height * k
            for j in 0..<5 {
                let lean: Double = -0.5 + 0.25 * Double(j)
                let sway: Double = 0.12 * sin(t * 0.9 + fan.phase + Double(j) * 0.4)
                let reach: CGFloat = 0.8 + 0.2 * CGFloat(hash(j, fan.seed))
                var stem = Path()
                for s in 0...8 {
                    let u: Double = Double(s) / 8
                    let a: Double = lean * u + sway * u * u
                    let p = CGPoint(x: bx + tall * CGFloat(u * sin(a)), y: by - tall * CGFloat(u * cos(a)) * reach)
                    if s == 0 { stem.move(to: p) } else { stem.addLine(to: p) }
                }
                water.stroke(stem, with: .color(frond), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round, lineJoin: .round))
            }
        }

        // White sand banking up to the right, with caustics playing over it.
        func sandY(_ u: Double) -> CGFloat { h * CGFloat(0.92 - 0.07 * u + 0.012 * sin(u * 9 + 0.7)) }
        var bank = Path()
        bank.move(to: CGPoint(x: 0, y: h))
        for s in 0...40 { bank.addLine(to: CGPoint(x: w * CGFloat(s) / 40, y: sandY(Double(s) / 40))) }
        bank.addLine(to: CGPoint(x: w, y: h))
        bank.closeSubpath()
        water.fill(bank, with: .linearGradient(Gradient(colors: [Color(red: 0.70, green: 0.86, blue: 0.82), Color(red: 0.46, green: 0.64, blue: 0.64)]),
                                               startPoint: CGPoint(x: 0, y: h * 0.84), endPoint: CGPoint(x: 0, y: h)))
        var caustics = water
        caustics.blendMode = .plusLighter
        caustics.addFilter(.blur(radius: 0.8 * k))
        caustics.drawLayer { layer in
            for r in 0..<6 {
                let d: Double = Double(r) / 5
                var net = Path()
                for s in 0...60 {
                    let x: CGFloat = w * CGFloat(s) / 60
                    let along: Double = Double(x / k)
                    let n: Double = Self.noise2(along * 0.016 + t * 0.25, d * 4.1 + 3.3) * 0.65 + Self.noise2(along * 0.04 - t * 0.3, d * 7.7) * 0.35
                    let y: CGFloat = sandY(Double(s) / 60) + CGFloat(3 + 26 * d) * k + CGFloat(n - 0.5) * 14 * k
                    if s == 0 { net.move(to: CGPoint(x: x, y: y)) } else { net.addLine(to: CGPoint(x: x, y: y)) }
                }
                layer.stroke(net, with: .color(Color(red: 0.88, green: 1.0, blue: 0.96).opacity(0.34 * (1 - 0.6 * d))), lineWidth: 1.3 * k)
            }
        }

        // The three coral heads, bass to treble. A brain coral: a dome with meandering grooves.
        let brain = Self.reefCoralHeads[0]
        let bx: CGFloat = w * brain.x, bBase: CGFloat = h * brain.y, rx: CGFloat = brain.size * k, ry: CGFloat = 0.66 * brain.size * k
        var dome = Path()
        for s in 0...32 {
            let v: CGFloat = 2 * CGFloat(s) / 32 - 1
            let p = CGPoint(x: bx + rx * v, y: bBase - ry * max(0, 1 - v * v).squareRoot())
            if s == 0 { dome.move(to: p) } else { dome.addLine(to: p) }
        }
        dome.closeSubpath()
        water.fill(dome, with: .radialGradient(Gradient(colors: [Color(red: 0.66, green: 0.74, blue: 0.38), Color(red: 0.30, green: 0.40, blue: 0.22)]),
                                               center: CGPoint(x: bx - 0.25 * rx, y: bBase - 0.75 * ry), startRadius: 0, endRadius: 1.15 * rx))
        for g in 0..<4 {
            let gr: CGFloat = 0.22 + 0.19 * CGFloat(g)
            var groove = Path()
            for s in 0...24 {
                let a: CGFloat = .pi * (0.06 + 0.88 * CGFloat(s) / 24)
                let r: CGFloat = gr + 0.05 * sin(a * CGFloat(7 + 2 * g) + CGFloat(g))
                let p = CGPoint(x: bx - rx * r * cos(a), y: bBase - ry * r * sin(a))
                if s == 0 { groove.move(to: p) } else { groove.addLine(to: p) }
            }
            water.stroke(groove, with: .color(Color(red: 0.24, green: 0.32, blue: 0.16).opacity(0.6)), lineWidth: 1.3 * k)
        }
        // A plate coral: a table on a short stalk.
        let plate = Self.reefCoralHeads[1]
        let px: CGFloat = w * plate.x, pBase: CGFloat = h * plate.y, ps: CGFloat = plate.size * k
        var stalk = Path()
        stalk.move(to: CGPoint(x: px - 6 * k, y: pBase)); stalk.addLine(to: CGPoint(x: px - 3 * k, y: pBase - 0.56 * ps))
        stalk.addLine(to: CGPoint(x: px + 3 * k, y: pBase - 0.56 * ps)); stalk.addLine(to: CGPoint(x: px + 6 * k, y: pBase))
        stalk.closeSubpath()
        water.fill(stalk, with: .color(Color(red: 0.36, green: 0.30, blue: 0.52)))
        water.fill(Path(ellipseIn: CGRect(x: px - ps, y: pBase - 0.71 * ps, width: 2 * ps, height: 0.30 * ps)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.66, green: 0.56, blue: 0.92), Color(red: 0.36, green: 0.28, blue: 0.58)]),
            startPoint: CGPoint(x: 0, y: pBase - 0.71 * ps), endPoint: CGPoint(x: 0, y: pBase - 0.41 * ps)))
        // A staghorn: a branch out to each polyp.
        let stag = Self.reefCoralHeads[2]
        let sx: CGFloat = w * stag.x, sBase: CGFloat = h * stag.y
        for (j, tip) in reefPolyps(2, size).enumerated() {
            var branch = Path()
            branch.move(to: CGPoint(x: sx + 0.08 * (tip.x - sx), y: sBase))
            branch.addLine(to: CGPoint(x: sx + 0.42 * (tip.x - sx) + 5 * k * CGFloat(hash(j, 62) - 0.5), y: sBase + 0.58 * (tip.y - sBase)))
            branch.addLine(to: tip)
            water.stroke(branch, with: .color(Color(red: 0.90, green: 0.80, blue: 0.66)),
                         style: StrokeStyle(lineWidth: 3.6 * k, lineCap: .round, lineJoin: .round))
        }

        // The polyps: those still closed dark, the lit ones glowing in their coral's fluorescence, each head flaring on
        // every breath and ringing on for as long as its partial would (the note, then 4 and 10 times shorter).
        var glow = water
        glow.blendMode = .plusLighter
        let closed = Color(red: 0.16, green: 0.20, blue: 0.20).opacity(0.7)
        for (i, head) in Self.reefCoralHeads.enumerated() {
            let points = reefPolyps(i, size)
            let ring: Double = 0.6 + 0.4 * exp(-phase / Self.reefRing[i])
            let c = Self.reefGlow[i]
            let tint = Color(red: c.red, green: c.green, blue: c.blue)
            let pale = Color(red: 0.5 + 0.5 * c.red, green: 0.5 + 0.5 * c.green, blue: 0.5 + 0.5 * c.blue)
            for p in points.dropFirst(head.lit) {
                let r: CGFloat = 1.8 * k
                water.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(closed))
            }
            let haloSize: CGFloat = i == 0 ? 19 : (i == 1 ? 10 : 7)
            let halo: CGFloat = haloSize * k * CGFloat(0.8 + 0.2 * ring)
            for p in points.prefix(head.lit) {
                glow.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: 2 * halo, height: 2 * halo)), with: .radialGradient(
                    Gradient(stops: [.init(color: tint.opacity(ring), location: 0), .init(color: tint.opacity(0.55 * ring), location: 0.35),
                                     .init(color: tint.opacity(0), location: 1)]),
                    center: p, startRadius: 0, endRadius: halo))
            }
            let core: CGFloat = (i == 0 ? 4.2 : 2.6) * k
            for p in points.prefix(head.lit) {
                water.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: 2 * core, height: 2 * core)),
                           with: .color(pale.opacity(0.95 * ring)))
            }
        }

        // The school, curving over the heads and swimming along its curve, a silver flash running along it on each breath.
        func onCurve(_ u: Double) -> CGPoint {
            let q = Self.reefSchool
            let m: Double = 1 - u
            let a: Double = m * m * m, b: Double = 3 * m * m * u, c: Double = 3 * m * u * u, d: Double = u * u * u
            let x: Double = a * Double(q[0].x) + b * Double(q[1].x) + c * Double(q[2].x) + d * Double(q[3].x)
            let y: Double = a * Double(q[0].y) + b * Double(q[1].y) + c * Double(q[2].y) + d * Double(q[3].y)
            return CGPoint(x: w * CGFloat(x), y: h * CGFloat(y))
        }
        let outline: [(x: CGFloat, y: CGFloat)] = [(0.5, 0), (0.18, -0.19), (-0.22, -0.12), (-0.5, -0.26), (-0.38, 0), (-0.5, 0.26),
                                                   (-0.22, 0.12), (0.18, 0.19)]
        let back = Color(red: 0.07, green: 0.28, blue: 0.40), silver = Color(red: 0.78, green: 0.96, blue: 1.0)
        for i in 0..<56 {
            let u: Double = (Double(i) / 56 + t / (32 * pulse) + 0.008 * hash(i, 81)).truncatingRemainder(dividingBy: 1)
            let ahead = onCurve(min(1, u + 0.01)), behind = onCurve(max(0, u - 0.01))
            let ax: CGFloat = ahead.x - behind.x, ay: CGFloat = ahead.y - behind.y
            let norm: CGFloat = max(1e-6, (ax * ax + ay * ay).squareRoot())
            let dx: CGFloat = ax / norm, dy: CGFloat = ay / norm
            let spreadOut: CGFloat = CGFloat(hash(i, 82) - 0.5) * 34 * k * CGFloat(sin(Double.pi * u))
            let side: CGFloat = spreadOut + 1.5 * k * CGFloat(sin(t * 1.7 + Double(i)))
            let on = onCurve(u)
            let centre = CGPoint(x: on.x - dy * side, y: on.y + dx * side)
            let fade: Double = min(1, u / 0.1, (1 - u) / 0.1)
            let span: CGFloat = (8 + 3 * CGFloat(hash(i, 83))) * k
            var fish = Path(), flank = Path()
            for (n, o) in outline.enumerated() {
                let p = CGPoint(x: centre.x + span * (o.x * dx - o.y * dy), y: centre.y + span * (o.x * dy + o.y * dx))
                if n == 0 { fish.move(to: p); flank.move(to: p) } else { fish.addLine(to: p) }
                if n > 0 && n < 4 { flank.addLine(to: p) }
            }
            fish.closeSubpath()
            flank.addLine(to: centre)
            flank.closeSubpath()
            water.fill(fish, with: .color(back.opacity(0.9 * fade)))
            let since: Double = phase - u < 0 ? phase - u + 1 : phase - u
            light.fill(flank, with: .color(silver.opacity((0.30 + 0.65 * exp(-6 * since)) * fade)))
        }

        // The waterline: a gently rolling meniscus.
        var line = Path()
        for s in 0...80 {
            let u: Double = Double(s) / 80
            let y: CGFloat = waterline + 1.6 * k * CGFloat(sin(u * 19 + t * 1.2)) + k * CGFloat(noise2(u * 8 + t * 0.2, 1.7) - 0.5)
            if s == 0 { line.move(to: CGPoint(x: 0, y: y)) } else { line.addLine(to: CGPoint(x: w * CGFloat(u), y: y)) }
        }
        var meniscus = ctx
        meniscus.blendMode = .plusLighter
        meniscus.addFilter(.blur(radius: 2 * k))
        meniscus.stroke(line, with: .color(Color(red: 0.80, green: 1.0, blue: 1.0).opacity(0.5)), lineWidth: 4 * k)
        ctx.stroke(line, with: .color(white.opacity(0.85)), lineWidth: 1.3 * k)
    }

    // MARK: - Noise

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / Double(UInt32.max)
    }

    /// Smooth value noise, 0…1.
    static func noise2(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }
}

// MARK: - Runaway (Storms, Set 18): an empty plain at dusk, a storm on the horizon, and a fence running away across it;
// one post lit under a forked line of five branches, struck again on every beat at 86. Abstract, and nothing from the
// record.

extension CardArt {
    /// The Runaway card's horizon (a fraction of the height): a little below the middle, so the sky over the plain is vast.
    static let runawayHorizon: CGFloat = 0.56

    /// The Runaway card's fence, nearest post first (the keys are fence posts on Lightning Plains, Storms spec §9.1):
    /// nine posts, the track number, running away across the plain from the near right towards a vanishing point low on
    /// the left, each a step further off (1 + 0.43 × its place). For each, its x and the y of its foot (fractions of the
    /// card), its height (a fraction of the height: the posts stand taller than the eye, which lies low in the grass) and
    /// its width (a fraction of the width).
    static let runawayPosts: [(x: CGFloat, foot: CGFloat, height: CGFloat, width: CGFloat)] = (0..<9).map {
        (i: Int) -> (x: CGFloat, foot: CGFloat, height: CGFloat, width: CGFloat) in
        let z: CGFloat = 1 + 0.43 * CGFloat(i)
        return (x: 0.20 + 0.80 / z, foot: CardArt.runawayHorizon + 0.343 / z, height: 0.55 / z, width: 0.032 / z)
    }

    /// The one post the note lights, again and again: the nearest whole one.
    static let runawayLitPost = 1

    /// The Runaway card's fork (the strike that lands for the repeated note, Storms spec §9.2), as fractions of the card:
    /// five branches. The first is the main channel, from the storm down to a tip just above the lit post's cap; the
    /// other four leave it on the way down, one below the other, and fork out into the air, each fainter than the last.
    static let runawayFork: [[CGPoint]] = [
        [CGPoint(x: 0.688, y: 0.175), CGPoint(x: 0.695, y: 0.193), CGPoint(x: 0.689, y: 0.210), CGPoint(x: 0.701, y: 0.228),
         CGPoint(x: 0.712, y: 0.243), CGPoint(x: 0.706, y: 0.262), CGPoint(x: 0.719, y: 0.281), CGPoint(x: 0.731, y: 0.296),
         CGPoint(x: 0.727, y: 0.316), CGPoint(x: 0.741, y: 0.334), CGPoint(x: 0.750, y: 0.351), CGPoint(x: 0.757, y: 0.372)],
        [CGPoint(x: 0.689, y: 0.210), CGPoint(x: 0.676, y: 0.222), CGPoint(x: 0.670, y: 0.238), CGPoint(x: 0.657, y: 0.248),
         CGPoint(x: 0.651, y: 0.266), CGPoint(x: 0.639, y: 0.275)],
        [CGPoint(x: 0.712, y: 0.243), CGPoint(x: 0.727, y: 0.252), CGPoint(x: 0.738, y: 0.249), CGPoint(x: 0.751, y: 0.263),
         CGPoint(x: 0.763, y: 0.272), CGPoint(x: 0.776, y: 0.291)],
        [CGPoint(x: 0.719, y: 0.281), CGPoint(x: 0.707, y: 0.295), CGPoint(x: 0.700, y: 0.310), CGPoint(x: 0.688, y: 0.320),
         CGPoint(x: 0.682, y: 0.336)],
        [CGPoint(x: 0.727, y: 0.316), CGPoint(x: 0.740, y: 0.323), CGPoint(x: 0.751, y: 0.321), CGPoint(x: 0.760, y: 0.335),
         CGPoint(x: 0.767, y: 0.346)],
    ]

    /// The repeated note on the Runaway card at `t` (0…1): it strikes the lit post on every beat of the felt pulse (86,
    /// the card's breath), rising over the first 6% of the beat, then dying away until the next strike, never quite out.
    static func runawayStrike(at t: Double, pulse: Double) -> Double {
        let beats: Double = t / pulse
        let phase: Double = beats - floor(beats)
        let rise = 0.06, fall = 2.4
        guard phase < rise else { return exp(-fall * (phase - rise)) }
        let low: Double = exp(-fall * (1 - rise))
        let u: Double = phase / rise
        return low + (1 - low) * u * u * (3 - 2 * u)
    }

    /// Draws the Runaway card: the sky, the storm, the plain, the fence, the lit post and the fork. Everything moves once a
    /// bar or once a beat, so the picture repeats exactly once a bar.
    private static func runawayPlain(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let horizon: CGFloat = h * runawayHorizon
        let bars: Double = t / (4 * pulse)
        let strike: Double = runawayStrike(at: t, pulse: pulse)
        let glow: Double = 0.35 + 0.65 * strike   // the lit post's light
        let sway: Double = sin(2 * Double.pi * bars)   // the grass, once a bar
        let amber = Color(red: 0.96, green: 0.60, blue: 0.30)
        let warm = Color(red: 1.0, green: 0.92, blue: 0.78)
        let ink = Color(red: 0.035, green: 0.030, blue: 0.040)

        // The sky at dusk: deep blue overhead, through violet and rose, to amber along the horizon.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: horizon)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.045, green: 0.055, blue: 0.14), location: 0),
                             .init(color: Color(red: 0.12, green: 0.10, blue: 0.23), location: 0.40),
                             .init(color: Color(red: 0.36, green: 0.22, blue: 0.28), location: 0.76),
                             .init(color: Color(red: 0.74, green: 0.45, blue: 0.25), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        var light = ctx
        light.blendMode = .plusLighter
        // The afterglow, low on the left where the sun has gone.
        let reach: CGFloat = w * 0.55
        var afterglow = light
        afterglow.translateBy(x: w * 0.12, y: horizon)
        afterglow.scaleBy(x: 1, y: 0.40)
        afterglow.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                       with: .radialGradient(Gradient(colors: [amber.opacity(0.30), amber.opacity(0)]),
                                             center: .zero, startRadius: 0, endRadius: reach))
        // The first stars, in the clear sky over the left, twinkling once a bar; fainter lower down, where it is lighter.
        for i in 0..<28 {
            let x: CGFloat = w * 0.44 * CGFloat(hash(i, 401))
            let y: CGFloat = h * 0.32 * CGFloat(hash(i, 402))
            let twinkle: Double = 0.6 + 0.4 * sin(2 * Double.pi * (bars + hash(i, 403)))
            let r: CGFloat = (0.5 + 0.6 * CGFloat(hash(i, 404))) * k
            let fade: Double = 1 - 0.6 * Double(y / (h * 0.32))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(.white.opacity((0.12 + 0.30 * twinkle) * fade)))
        }

        // The storm: a line of towers on the horizon to the right, dark, their sunward edges catching the last light, the
        // tallest with its anvil.
        let towers: [(x: CGFloat, half: CGFloat, top: CGFloat, seed: Int)] = [
            (0.47, 0.065, 0.40, 1), (0.585, 0.085, 0.29, 2), (0.70, 0.12, 0.13, 3), (0.86, 0.10, 0.22, 4), (0.985, 0.075, 0.31, 5)]
        let cloud = Color(red: 0.105, green: 0.092, blue: 0.150)
        let rim = Color(red: 0.50, green: 0.34, blue: 0.36)
        /// A tower's puffs, centre and radius in points: a column narrow at its foot on the horizon and broad aloft, a
        /// crown of small puffs boiling along its top, and on the tallest, its anvil sheared off to the right.
        func puffs(_ index: Int, _ tower: (x: CGFloat, half: CGFloat, top: CGFloat, seed: Int)) -> [(c: CGPoint, r: CGFloat)] {
            var out: [(c: CGPoint, r: CGFloat)] = []
            let span: CGFloat = w * tower.half
            for j in 0..<12 {
                let u: CGFloat = CGFloat(j) / 11   // 0 on the horizon, 1 at the top
                let r: CGFloat = span * (0.34 + 0.62 * u * u.squareRoot()) * (0.80 + 0.30 * CGFloat(hash(tower.seed * 32 + j, 411)))
                let x: CGFloat = w * tower.x + span * 0.45 * CGFloat(hash(tower.seed * 32 + j, 412) - 0.5) * (0.4 + 0.6 * u)
                let y: CGFloat = horizon * (1 - u) + (h * tower.top + 0.8 * r) * u
                out.append((c: CGPoint(x: x, y: y), r: r))
            }
            for j in 0..<7 {
                let v: CGFloat = CGFloat(j) / 3 - 1   // −1 … 1 across the top
                let r: CGFloat = span * (0.30 + 0.12 * CGFloat(hash(tower.seed * 32 + j, 413)))
                let dip: CGFloat = h * 0.035 * v * v + h * 0.012 * CGFloat(hash(tower.seed * 32 + j, 414) - 0.5)
                out.append((c: CGPoint(x: w * tower.x + v * span * 0.82, y: h * tower.top + 0.8 * r + dip), r: r))
            }
            if index == 2 {
                for j in 0..<8 {
                    let v: CGFloat = CGFloat(j) / 7
                    let r: CGFloat = span * (0.42 - 0.18 * v)
                    out.append((c: CGPoint(x: w * tower.x + w * (0.02 + 0.20 * v), y: h * tower.top + 0.55 * r + h * 0.012 * v), r: r))
                }
            }
            return out
        }
        var storm = ctx
        storm.addFilter(.blur(radius: 1.6 * k))
        storm.drawLayer { layer in
            for (index, tower) in towers.enumerated() {
                let body = puffs(index, tower)
                // The lit edge first, then the body over it, a little down and right of the light.
                for puff in body {
                    layer.fill(Path(ellipseIn: CGRect(x: puff.c.x - puff.r, y: puff.c.y - 0.8 * puff.r, width: 2 * puff.r, height: 1.6 * puff.r)),
                               with: .color(rim))
                }
                for puff in body {
                    let dx: CGFloat = 0.05 * puff.r, dy: CGFloat = 0.035 * puff.r
                    let shade = CGRect(x: puff.c.x - puff.r + dx, y: puff.c.y - 0.8 * puff.r + dy, width: 2 * puff.r, height: 1.6 * puff.r)
                    layer.fill(Path(ellipseIn: shade), with: .color(cloud))
                }
            }
        }
        // Sheet lightning inside the towers, each in its turn once a bar: a soft warm swell, there and gone.
        let sheet = Color(red: 1.0, green: 0.86, blue: 0.74)
        var inside = light
        inside.addFilter(.blur(radius: 6 * k))
        inside.drawLayer { layer in
            for (j, tower) in towers.enumerated() {
                let cycle: Double = bars + 0.37 * Double(j)
                let u: Double = min(1, (cycle - floor(cycle)) / 0.3)
                let s: Double = sin(Double.pi * u)
                let swell: Double = s * s
                guard swell > 0.01 else { continue }
                let c = CGPoint(x: w * tower.x, y: horizon - 0.45 * (horizon - h * tower.top))
                let r: CGFloat = w * tower.half * 1.1
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - 0.8 * r, width: 2 * r, height: 1.6 * r)),
                           with: .radialGradient(Gradient(colors: [sheet.opacity(0.26 * swell), sheet.opacity(0)]),
                                                 center: c, startRadius: 0, endRadius: r))
            }
        }

        // The plain: dry grass going dark, the sky's amber on it towards the horizon, and a haze along the horizon.
        ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.23, green: 0.15, blue: 0.10), location: 0),
                             .init(color: Color(red: 0.10, green: 0.07, blue: 0.055), location: 0.35),
                             .init(color: Color(red: 0.035, green: 0.028, blue: 0.025), location: 1)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))
        light.fill(Path(CGRect(x: 0, y: horizon - 2 * k, width: w, height: 4 * k)), with: .linearGradient(
            Gradient(colors: [amber.opacity(0.35), amber.opacity(0.06)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: w, y: horizon)))

        // A windmill far off on the left against the afterglow, its wheel turning a blade's width a bar.
        let hub = CGPoint(x: w * 0.13, y: horizon - h * 0.095)
        var frame = Path()
        frame.move(to: CGPoint(x: hub.x - 5 * k, y: horizon + k)); frame.addLine(to: hub)
        frame.move(to: CGPoint(x: hub.x + 5 * k, y: horizon + k)); frame.addLine(to: hub)
        for q in 1...3 {
            let f: CGFloat = CGFloat(q) / 4
            let y: CGFloat = horizon - (horizon - hub.y) * f
            let half: CGFloat = 5 * k * (1 - f)
            frame.move(to: CGPoint(x: hub.x - half, y: y)); frame.addLine(to: CGPoint(x: hub.x + half, y: y))
        }
        ctx.stroke(frame, with: .color(ink), lineWidth: 0.9 * k)
        let wheel: CGFloat = 9 * k
        let turn: Double = 2 * Double.pi * bars / 12
        var blades = Path()
        for b in 0..<12 {
            let a: Double = turn + Double(b) * Double.pi / 6
            let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
            blades.move(to: CGPoint(x: hub.x + 0.25 * wheel * ca, y: hub.y + 0.25 * wheel * sa))
            blades.addLine(to: CGPoint(x: hub.x + wheel * ca, y: hub.y + wheel * sa))
        }
        ctx.stroke(blades, with: .color(ink), lineWidth: 1.6 * k)
        var vane = Path()
        vane.move(to: hub)
        vane.addLine(to: CGPoint(x: hub.x + 13 * k, y: hub.y - 0.5 * k))
        vane.addLine(to: CGPoint(x: hub.x + 14 * k, y: hub.y - 5 * k))
        vane.addLine(to: CGPoint(x: hub.x + 9 * k, y: hub.y - 1.5 * k))
        vane.closeSubpath()
        ctx.fill(vane, with: .color(ink))

        // The fork, brightening with each strike: a wide violet glow, then the white channel and its branches.
        let flash: Double = 0.72 + 0.28 * strike
        let bolt = Color(red: 0.88, green: 0.92, blue: 1.0)
        let boltGlow = Color(red: 0.52, green: 0.58, blue: 1.0)
        let forkPaths: [Path] = runawayFork.map { (branch: [CGPoint]) -> Path in
            var path = Path()
            for (q, pt) in branch.enumerated() {
                let at = CGPoint(x: w * pt.x, y: h * pt.y)
                if q == 0 { path.move(to: at) } else { path.addLine(to: at) }
            }
            return path
        }
        var aura = light
        aura.addFilter(.blur(radius: 5 * k))
        aura.drawLayer { layer in
            for (j, path) in forkPaths.enumerated() {
                let fade: Double = j == 0 ? 1 : 0.75 - 0.1 * Double(j)
                let width: CGFloat = (j == 0 ? 9 : 6) * k
                layer.stroke(path, with: .color(boltGlow.opacity(0.50 * flash * fade)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        for (j, path) in forkPaths.enumerated() {
            let fade: Double = j == 0 ? 1 : 0.85 - 0.1 * Double(j)
            let width: CGFloat = (j == 0 ? 2.2 : 1.5 - 0.15 * CGFloat(j)) * k
            light.stroke(path, with: .color(bolt.opacity(flash * fade)),
                         style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }

        // The fence's three wires, running from post to post to the vanishing point, catching the last light; either
        // side of the lit post they catch its light too.
        let posts = runawayPosts
        let lit = runawayLitPost
        /// A point on post `i`, `f` of its height up from its foot.
        func point(_ i: Int, _ f: CGFloat) -> CGPoint {
            CGPoint(x: w * posts[i].x, y: h * (posts[i].foot - f * posts[i].height))
        }
        let vanishing = CGPoint(x: w * 0.20, y: horizon)
        let wireColour = Color(red: 0.55, green: 0.42, blue: 0.34)
        for f: CGFloat in [0.30, 0.58, 0.86] {
            let a = point(0, f), b = point(1, f)
            var wire = Path()
            wire.move(to: CGPoint(x: a.x + 0.5 * (a.x - b.x), y: a.y + 0.5 * (a.y - b.y)))   // on past the card's edge
            for i in posts.indices { wire.addLine(to: point(i, f)) }
            ctx.stroke(wire, with: .color(wireColour.opacity(0.40)), lineWidth: 0.7 * k)
            let last = point(posts.count - 1, f)
            var away = Path()
            away.move(to: last)
            away.addLine(to: vanishing)
            ctx.stroke(away, with: .linearGradient(Gradient(colors: [wireColour.opacity(0.40), wireColour.opacity(0)]),
                                                   startPoint: last, endPoint: vanishing), lineWidth: 0.6 * k)
            let from = point(lit, f)
            for j in [lit - 1, lit + 1] where posts.indices.contains(j) {
                let to = point(j, f)
                var span = Path()
                span.move(to: from)
                span.addLine(to: to)
                light.stroke(span, with: .linearGradient(Gradient(colors: [warm.opacity(0.55 * glow), warm.opacity(0)]),
                                                         startPoint: from, endPoint: to), lineWidth: 1.0 * k)
            }
        }

        // The posts, dark against the sky, each with a peaked cap; one lit white by its note, brightest at the top, in a
        // halo that swells with each strike, its light pooling on the grass at its foot.
        var litPath = Path()
        for (i, p) in posts.enumerated() {
            let foot: CGFloat = h * p.foot, top: CGFloat = h * (p.foot - p.height)
            let half: CGFloat = 0.5 * w * p.width, x: CGFloat = w * p.x
            var post = Path()
            post.move(to: CGPoint(x: x - half, y: foot))
            post.addLine(to: CGPoint(x: x - 0.86 * half, y: top + 0.6 * half))
            post.addLine(to: CGPoint(x: x, y: top))
            post.addLine(to: CGPoint(x: x + 0.86 * half, y: top + 0.6 * half))
            post.addLine(to: CGPoint(x: x + half, y: foot))
            post.closeSubpath()
            ctx.fill(post, with: .color(ink))
            if i == lit { litPath = post }
        }
        let p = posts[lit]
        let x: CGFloat = w * p.x, top: CGFloat = h * (p.foot - p.height), foot: CGFloat = h * p.foot
        let poolR: CGFloat = h * 0.09
        var pool = light
        pool.translateBy(x: x, y: foot)
        pool.scaleBy(x: 1, y: 0.28)
        pool.fill(Path(ellipseIn: CGRect(x: -poolR, y: -poolR, width: 2 * poolR, height: 2 * poolR)),
                  with: .radialGradient(Gradient(colors: [warm.opacity(0.22 * glow), warm.opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: poolR))
        ctx.fill(litPath, with: .linearGradient(Gradient(colors: [warm.opacity(0.70 + 0.30 * glow), warm.opacity(0.40 + 0.35 * glow)]),
                                                startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: foot)))
        let haloR: CGFloat = h * (0.10 + 0.03 * CGFloat(strike))
        let haloC = CGPoint(x: x, y: top + 0.18 * (foot - top))
        light.fill(Path(ellipseIn: CGRect(x: haloC.x - haloR, y: haloC.y - haloR, width: 2 * haloR, height: 2 * haloR)),
                   with: .radialGradient(Gradient(colors: [warm.opacity(0.38 * glow), warm.opacity(0)]),
                                         center: haloC, startRadius: 0, endRadius: haloR))
        let cap: CGFloat = (2.2 + 1.6 * CGFloat(strike)) * k
        let capC = CGPoint(x: x, y: top + 0.4 * cap)
        light.fill(Path(ellipseIn: CGRect(x: capC.x - cap, y: capC.y - cap, width: 2 * cap, height: 2 * cap)),
                   with: .radialGradient(Gradient(colors: [Color.white.opacity(0.9 * glow), Color.white.opacity(0)]),
                                         center: capC, startRadius: 0, endRadius: cap))

        // Dry grass across the near plain, leaning with the breeze once a bar.
        let straw = Color(red: 0.22, green: 0.16, blue: 0.10)
        for i in 0..<160 {
            let depth: CGFloat = CGFloat(hash(i, 422))   // 0 far … 1 near
            let x0: CGFloat = w * CGFloat(hash(i, 421))
            let base: CGFloat = horizon + (h - horizon) * (0.30 + 0.75 * depth)
            let tall: CGFloat = (4 + 16 * depth) * k * (0.6 + 0.4 * CGFloat(hash(i, 423)))
            let lean: CGFloat = tall * (0.25 * CGFloat(sway) + 0.35 * CGFloat(hash(i, 424) - 0.5))
            var blade = Path()
            blade.move(to: CGPoint(x: x0, y: base))
            blade.addQuadCurve(to: CGPoint(x: x0 + lean, y: base - tall), control: CGPoint(x: x0 + 0.2 * lean, y: base - 0.6 * tall))
            ctx.stroke(blade, with: .color(straw.opacity(0.75)), lineWidth: (0.6 + 0.8 * depth) * k)
        }
    }
}

// MARK: - Hold My Liquor (Fire & Neon, Set 13): a lava lake in a crater at night, its black crust broken into plates
// whose cracks glow; a fountain throws spatter and an ember up on every beat of the felt pulse (104), the cracks throb
// with it, a plume of smoke leans away lit from beneath, and on the far rim stands a tiny lava tree. Original, from the
// set's world (the volcano's molten crack-light): nothing from the record, its packaging or its words.

extension CardArt {
    /// The lava lake: its centre across the card, its far and near shores' heights and its half-width at the near shore
    /// (fractions of the card), seen in perspective from the rim.
    static let liquorLake: (x: Double, far: Double, near: Double, halfWidth: Double) = (0.58, 0.555, 0.99, 0.66)

    /// The fountain, in lake coordinates (u across, −1…1; v from the far shore, −1, to the near, +1).
    static let liquorFountain: (u: Double, v: Double) = (0.10, -0.30)

    /// The card's easter egg: a tiny lava tree (a pillar of lava left standing when a flow drained away round a trunk)
    /// on the far rim: where it stands across the card and its height (fractions).
    static let liquorLavaTree: (x: Double, height: Double) = (0.795, 0.06)

    /// A point on the lake on the card (fractions), in perspective: the far crust small and squashed, the near large.
    static func liquorLakePoint(u: Double, v: Double) -> CGPoint {
        let s: Double = min(1, max(0, (v + 1) / 2))
        let g: Double = pow(s, 1.6)
        let lake = liquorLake
        let x: Double = lake.x + lake.halfWidth * u * (0.55 + 0.45 * g)
        return CGPoint(x: x, y: lake.far + (lake.near - lake.far) * g)
    }

    /// The far rim's skyline at `x` (fractions of the card).
    static func liquorRimTop(_ x: Double) -> Double {
        let dip: Double = 0.030 * exp(-pow((x - 0.55) / 0.30, 2))
        let rough: Double = 0.010 * sin(x * 9.3 + 0.6) + 0.006 * sin(x * 23.0 + 1.1) + 0.004 * sin(x * 51.0)
        return 0.300 - dip + rough
    }

    /// Where the far wall meets the crater floor at `x` (fractions).
    static func liquorWallFoot(_ x: Double) -> Double { 0.535 + 0.006 * sin(x * 13.0 + 0.4) }

    /// The lake's crust plates, in lake coordinates, computed once: the cells round a jittered grid of seeds over the lake
    /// (some missing, so some plates are big) and fourteen more round the fountain, where the young crust breaks small.
    /// Each cell is the square clipped to every other seed's half-plane: the Voronoi diagram.
    static let liquorPlates: [(seed: CGPoint, cell: [CGPoint])] = {
        var seeds: [CGPoint] = []
        let n = 13
        for gy in 0..<n {
            for gx in 0..<n {
                let i = gy * n + gx
                let jx: Double = (CardArt.hash(i, 501) - 0.5) + 0.35 * sin(Double(gy) * 1.7)
                let jy: Double = CardArt.hash(i, 502) - 0.5
                let u: Double = -1.15 + 2.3 * (Double(gx) + 0.5 + jx) / Double(n)
                let v: Double = -1.15 + 2.3 * (Double(gy) + 0.5 + jy) / Double(n)
                if CardArt.hash(i, 505) < 0.18 { continue }
                if u * u + v * v < 1.35 { seeds.append(CGPoint(x: u, y: v)) }
            }
        }
        let fountain = CardArt.liquorFountain
        for i in 0..<14 {
            let a: Double = 2 * Double.pi * CardArt.hash(i, 503)
            let r: Double = 0.32 * CardArt.hash(i, 504).squareRoot()
            seeds.append(CGPoint(x: fountain.u + r * cos(a), y: fountain.v + 0.8 * r * sin(a)))
        }
        return seeds.indices.map { (i: Int) -> (seed: CGPoint, cell: [CGPoint]) in
            var poly: [CGPoint] = [CGPoint(x: -1.6, y: -1.6), CGPoint(x: 1.6, y: -1.6), CGPoint(x: 1.6, y: 1.6), CGPoint(x: -1.6, y: 1.6)]
            for j in seeds.indices where j != i {
                poly = CardArt.clip(poly, nearer: seeds[i], than: seeds[j])
                if poly.count < 3 { break }
            }
            return (seed: seeds[i], cell: CardArt.liquorJagged(poly))
        }
    }()

    /// A cell's edges broken into three, each kink shared with the neighbour across the edge: the edge is taken from its
    /// lower endpoint, so both cells see the same two kinks, keyed by its midpoint; they stand off the edge by up to 11%
    /// of its length, so the cracks run jagged rather than straight.
    static func liquorJagged(_ cell: [CGPoint]) -> [CGPoint] {
        func key(_ p: CGPoint) -> (Int, Int) { (Int((p.x * 4000).rounded()), Int((p.y * 4000).rounded())) }
        var out: [CGPoint] = []
        for i in cell.indices {
            let a = cell[i], b = cell[(i + 1) % cell.count]
            let ka = key(a), kb = key(b)
            let forward: Bool = ka.0 < kb.0 || (ka.0 == kb.0 && ka.1 <= kb.1)
            let p = forward ? a : b, q = forward ? b : a
            let mid = key(CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2))
            let dx: CGFloat = q.x - p.x, dy: CGFloat = q.y - p.y
            let length: CGFloat = max(1e-9, (dx * dx + dy * dy).squareRoot())
            let nx: CGFloat = -dy / length, ny: CGFloat = dx / length
            var kinks: [CGPoint] = []
            for (f, salt) in [(CGFloat(1) / 3, 1), (CGFloat(2) / 3, 2)] {
                let o: CGFloat = CGFloat(CardArt.hash(mid.0 + salt * 7919, mid.1) - 0.5) * 0.22 * length
                kinks.append(CGPoint(x: p.x + dx * f + nx * o, y: p.y + dy * f + ny * o))
            }
            out.append(a)
            out.append(contentsOf: forward ? kinks : kinks.reversed())
        }
        return out
    }

    /// The part of a convex polygon nearer `s` than `o`.
    static func clip(_ poly: [CGPoint], nearer s: CGPoint, than o: CGPoint) -> [CGPoint] {
        let mx: CGFloat = (s.x + o.x) / 2, my: CGFloat = (s.y + o.y) / 2
        let nx: CGFloat = o.x - s.x, ny: CGFloat = o.y - s.y
        var out: [CGPoint] = []
        for k in poly.indices {
            let a = poly[k], b = poly[(k + 1) % poly.count]
            let da: CGFloat = (a.x - mx) * nx + (a.y - my) * ny
            let db: CGFloat = (b.x - mx) * nx + (b.y - my) * ny
            if da <= 0 { out.append(a) }
            if (da <= 0) != (db <= 0) {
                let f: CGFloat = da / (da - db)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        return out
    }

    /// The card's embers at `t`: one leaves the fountain on every beat of the felt pulse and rises for four, drifting left
    /// with the plume and cooling (heat 1 → 0), so four are always in the air and the picture repeats once a bar. Each:
    /// where it is (fractions of the card), its heat and its light (0…1).
    static func liquorEmbers(at t: Double, pulse: Double) -> [(x: Double, y: Double, heat: Double, light: Double)] {
        let beats: Double = t / pulse
        let start = liquorLakePoint(u: liquorFountain.u, v: liquorFountain.v)
        return (0..<4).map { (j: Int) -> (x: Double, y: Double, heat: Double, light: Double) in
            let cycle: Double = (beats - Double(j)) / 4
            let u: Double = cycle - floor(cycle)   // 0 as it leaves … 1 four beats later
            let age: Double = 4 * u               // beats since it left
            let drift: Double = 0.10 + 0.05 * hash(j, 611)
            let x: Double = Double(start.x) - drift * u * u - 0.02 * u * sin(2 * Double.pi * (1.5 * u + hash(j, 612)))
            let rise: Double = (0.02 + 0.43 * u) * (0.9 + 0.2 * hash(j, 613)) * min(1, 0.5 + u)
            let light: Double = min(1, age / 0.15) * (1 - max(0, (u - 0.7) / 0.3))
            return (x: x, y: Double(start.y) - rise, heat: 1 - u, light: light)
        }
    }

    /// An ember's colour as it cools: yellow-white, orange, deep red.
    static func liquorEmberColour(_ heat: Double) -> (red: Double, green: Double, blue: Double) {
        if heat > 0.5 {
            let f: Double = (heat - 0.5) / 0.5
            return (red: 1.0, green: 0.55 + 0.37 * f, blue: 0.18 + 0.45 * f)
        }
        let f: Double = heat / 0.5
        return (red: 0.75 + 0.25 * f, green: 0.12 + 0.43 * f, blue: 0.03 + 0.15 * f)
    }

    /// The cracks' heartbeat at `t` (0…1): up on every beat of the felt pulse, easing off through it.
    static func liquorThrob(at t: Double, pulse: Double) -> Double {
        let beats: Double = t / pulse
        return exp(-3.2 * (beats - floor(beats)))
    }

    /// A ragged line across the card through `count + 1` points, `y(x)` in fractions.
    private static func profile(_ size: CGSize, count: Int, _ y: (Double) -> Double) -> [CGPoint] {
        (0...count).map { (i: Int) -> CGPoint in
            let x: Double = Double(i) / Double(count)
            return CGPoint(x: size.width * x, y: size.height * y(x))
        }
    }

    /// Draws the card: the sky, the plume, the far wall and the floor, the lava tree, the lake and its crust, the fountain,
    /// the embers and the near rim. Everything moves once a beat or once a bar, so the picture repeats once a bar.
    static func moltenRim(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let beats: Double = t / pulse
        let bars: Double = beats / 4
        let phase: Double = beats - floor(beats)
        let throb: Double = liquorThrob(at: t, pulse: pulse)
        let heat: Double = 0.80 + 0.20 * throb
        let lake = liquorLake
        let yFar: CGFloat = h * lake.far, yNear: CGFloat = h * lake.near
        /// A lake point in points.
        func onLake(_ u: Double, _ v: Double) -> CGPoint {
            let p = liquorLakePoint(u: u, v: v)
            return CGPoint(x: w * p.x, y: h * p.y)
        }
        let hot: CGPoint = onLake(liquorFountain.u, liquorFountain.v)
        var light = ctx
        light.blendMode = .plusLighter

        // The sky: night, warmed low over the crater where the lake lights the haze.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.6)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.016, green: 0.014, blue: 0.030), location: 0),
                             .init(color: Color(red: 0.035, green: 0.020, blue: 0.034), location: 0.40),
                             .init(color: Color(red: 0.15, green: 0.045, blue: 0.034), location: 0.60),
                             .init(color: Color(red: 0.30, green: 0.085, blue: 0.038), location: 0.74),
                             .init(color: Color(red: 0.34, green: 0.10, blue: 0.045), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.6)))
        // Stars over the left, twinkling once a bar, fainter down towards the glow.
        for i in 0..<36 {
            let x: CGFloat = w * 0.60 * CGFloat(hash(i, 401))
            let y: CGFloat = h * 0.28 * CGFloat(pow(hash(i, 402), 1.3))
            let twinkle: Double = 0.6 + 0.4 * sin(2 * Double.pi * (bars + hash(i, 403)))
            let r: CGFloat = (0.45 + 0.6 * CGFloat(hash(i, 404))) * k
            let fade: Double = 1 - 0.8 * Double(y / (h * 0.28))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Color(red: 1, green: 0.94, blue: 0.88).opacity((0.10 + 0.32 * twinkle) * fade)))
        }

        // The far wall: the rim's black skyline, steep inner cliffs lit orange only near the floor, old flows in bands.
        let rim: [CGPoint] = profile(size, count: 120) { liquorRimTop($0) }
        var wall = Path()
        wall.move(to: CGPoint(x: 0, y: h))
        for p in rim { wall.addLine(to: p) }
        wall.addLine(to: CGPoint(x: w, y: h))
        wall.closeSubpath()
        ctx.fill(wall, with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.035, green: 0.016, blue: 0.016), location: 0),
                             .init(color: Color(red: 0.055, green: 0.022, blue: 0.020), location: 0.40),
                             .init(color: Color(red: 0.17, green: 0.05, blue: 0.024), location: 0.75),
                             .init(color: Color(red: 0.40, green: 0.12, blue: 0.04), location: 1)]),
            startPoint: CGPoint(x: 0, y: h * 0.29), endPoint: CGPoint(x: 0, y: h * 0.54)))
        // The cliffs: gullies running down the wall, their hollows dark and every other rib catching the glow from below;
        // two ledges of old flows across it.
        let hollow = Color(red: 0.02, green: 0.008, blue: 0.008)
        let glowRib = Color(red: 0.9, green: 0.32, blue: 0.08)
        for g in 0..<34 {
            let x0: Double = hash(g, 461)
            let top: Double = liquorRimTop(x0) + 0.006 + 0.03 * hash(g, 462)
            let bottom: Double = top + (liquorWallFoot(x0) - 0.004 - top) * (0.55 + 0.45 * hash(g, 465))
            let lean: Double = 0.016 * (hash(g, 463) - 0.5)
            let wide: CGFloat = CGFloat(1.0 + 2.2 * hash(g, 464)) * k
            let a = CGPoint(x: w * CGFloat(x0), y: h * CGFloat(top))
            let m = CGPoint(x: w * CGFloat(x0 + 0.5 * lean), y: h * CGFloat((top + bottom) / 2))
            let b = CGPoint(x: w * CGFloat(x0 + lean), y: h * CGFloat(bottom))
            var gully = Path()
            gully.addLines([a, m, b])
            ctx.stroke(gully, with: .linearGradient(
                Gradient(stops: [.init(color: hollow.opacity(0), location: 0), .init(color: hollow.opacity(0.65), location: 0.6),
                                 .init(color: hollow.opacity(0.25), location: 1)]),
                startPoint: a, endPoint: b), lineWidth: wide)
            guard g % 2 == 0 else { continue }
            var rib = Path()
            rib.addLines([CGPoint(x: a.x + 0.9 * wide, y: a.y + 0.02 * h), CGPoint(x: m.x + 0.9 * wide, y: m.y), CGPoint(x: b.x + 0.9 * wide, y: b.y)])
            light.stroke(rib, with: .linearGradient(Gradient(colors: [glowRib.opacity(0), glowRib.opacity(0.2)]), startPoint: a, endPoint: b),
                         lineWidth: 0.6 * k)
        }
        for (band, f) in [0.42, 0.74].enumerated() {
            let line: [CGPoint] = profile(size, count: 120) { (x: Double) -> Double in
                let top: Double = liquorRimTop(x)
                let wobble: Double = 0.005 * sin(19 * x + 2.1 * Double(band)) + 0.002 * sin(67 * x + Double(band))
                return top + (liquorWallFoot(x) - top) * f + wobble
            }
            var path = Path()
            path.addLines(line)
            ctx.stroke(path, with: .color(Color(red: 0.80, green: 0.28, blue: 0.07).opacity(0.10 + 0.12 * f)), lineWidth: 0.8 * k)
        }
        var lip = Path()
        lip.addLines(rim.map { CGPoint(x: $0.x, y: $0.y + 0.5 * k) })
        ctx.stroke(lip, with: .color(Color(red: 0.60, green: 0.20, blue: 0.06).opacity(0.30)), lineWidth: 0.7 * k)

        // The crater floor: old black flows from the wall's foot to the lake, warmed by it; the heat glow over the lake.
        var craterFloor = Path()
        craterFloor.move(to: CGPoint(x: 0, y: h))
        for p in profile(size, count: 120, { liquorWallFoot($0) }) { craterFloor.addLine(to: p) }
        craterFloor.addLine(to: CGPoint(x: w, y: h))
        craterFloor.closeSubpath()
        ctx.fill(craterFloor, with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.20, green: 0.06, blue: 0.025), location: 0),
                             .init(color: Color(red: 0.07, green: 0.025, blue: 0.018), location: 0.35),
                             .init(color: Color(red: 0.03, green: 0.014, blue: 0.012), location: 1)]),
            startPoint: CGPoint(x: 0, y: h * 0.535), endPoint: CGPoint(x: 0, y: h)))
        let reach: CGFloat = w * 0.50
        var haze = light
        haze.translateBy(x: hot.x, y: yFar + 0.02 * h)
        haze.scaleBy(x: 1, y: 0.42)
        haze.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                  with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.40, blue: 0.10).opacity(0.36 * heat),
                                                          Color(red: 1.0, green: 0.30, blue: 0.06).opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: reach))

        // The plume: smoke climbing out of the lake and leaning left, billowing once a bar, then its underside lit.
        var smoke = ctx
        smoke.addFilter(.blur(radius: 5 * k))
        smoke.drawLayer { layer in
            for i in 0..<18 {
                let u: Double = Double(i) / 17
                let sway: Double = 0.010 * sin(2 * Double.pi * (bars + 0.35 * u)) + 0.02 * sin(5 * u)
                let x: CGFloat = w * CGFloat(0.625 - 0.34 * pow(u, 1.4) + sway)
                let y: CGFloat = h * CGFloat(0.53 - 0.58 * u)
                let r: CGFloat = w * CGFloat(0.022 + 0.085 * u)
                let tone: Double = 0.8 + 0.4 * hash(i, 451)
                let a: Double = 0.62 - 0.32 * u
                layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - 0.75 * r, width: 2 * r, height: 1.5 * r)),
                           with: .color(Color(red: 0.10 * tone, green: 0.058 * tone, blue: 0.058 * tone).opacity(a)))
                for j in 0..<3 {
                    let q = 3 * i + j
                    let ox: CGFloat = CGFloat(hash(q, 452) - 0.5) * 1.5 * r
                    let oy: CGFloat = CGFloat(hash(q, 453) - 0.5) * 0.9 * r
                    let rr: CGFloat = r * CGFloat(0.45 + 0.30 * hash(q, 454))
                    layer.fill(Path(ellipseIn: CGRect(x: x + ox - rr, y: y + oy - 0.8 * rr, width: 2 * rr, height: 1.6 * rr)),
                               with: .color(Color(red: 0.12, green: 0.07, blue: 0.065).opacity(0.8 * a)))
                }
            }
        }
        var underside = light
        underside.addFilter(.blur(radius: 7 * k))
        underside.drawLayer { layer in
            for i in 0..<12 {
                let u: Double = Double(i) / 11
                let sway: Double = 0.010 * sin(2 * Double.pi * (bars + 0.35 * u)) + 0.02 * sin(3 * u)
                let x: CGFloat = w * CGFloat(0.629 - 0.34 * pow(0.6 * u, 1.4) + sway)
                let y: CGFloat = h * CGFloat(0.542 - 0.348 * u)
                let r: CGFloat = w * CGFloat(0.020 + 0.06 * u)
                let a: Double = 0.50 * pow(1 - u, 1.2) * heat
                layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - 0.55 * r, width: 2 * r, height: 1.1 * r)),
                           with: .color(Color(red: 1.0, green: 0.38, blue: 0.09).opacity(a)))
            }
        }

        // The lava tree on the far rim: a hollow pillar left standing, two stubs of branches, warm inside (the easter egg).
        let tx: CGFloat = w * liquorLavaTree.x
        let ty: CGFloat = h * liquorRimTop(liquorLavaTree.x)
        let th: CGFloat = h * liquorLavaTree.height
        let outline: [(CGFloat, CGFloat)] = [(-2.6, -0.02), (-1.9, 0.50), (-5.0, 0.74), (-4.6, 0.84), (-1.7, 0.64), (-1.5, 0.97),
                                             (-0.3, 1.03), (1.3, 0.95), (1.5, 0.58), (4.2, 0.88), (4.8, 0.80), (1.9, 0.40), (2.8, -0.02)]
        var tree = Path()
        tree.addLines(outline.map { CGPoint(x: tx + $0.0 * k, y: ty - $0.1 * th) })
        tree.closeSubpath()
        ctx.fill(tree, with: .color(Color(red: 0.030, green: 0.014, blue: 0.014)))
        var seam = Path()
        seam.move(to: CGPoint(x: tx - 0.4 * k, y: ty - 0.92 * th))
        seam.addLine(to: CGPoint(x: tx - 0.5 * k, y: ty - 0.35 * th))
        light.stroke(seam, with: .color(Color(red: 1.0, green: 0.42, blue: 0.10).opacity(0.45 + 0.30 * throb)), lineWidth: 0.8 * k)

        // The lava lake: molten rock under a black crust broken into plates; the cracks between them glow, hottest round
        // the fountain, and throb on the beat.
        var lakePath = Path()
        lakePath.addLines((0..<120).map { (i: Int) -> CGPoint in
            let a: Double = 2 * Double.pi * Double(i) / 120
            return onLake(cos(a), sin(a))
        })
        lakePath.closeSubpath()
        ctx.fill(lakePath, with: .radialGradient(
            Gradient(stops: [.init(color: Color(red: 1.0, green: 0.90 * heat, blue: 0.56 * heat), location: 0),
                             .init(color: Color(red: 1.0, green: 0.62 * heat, blue: 0.12), location: 0.14),
                             .init(color: Color(red: 0.92, green: 0.30 * heat, blue: 0.05), location: 0.40),
                             .init(color: Color(red: 0.58, green: 0.10, blue: 0.03), location: 0.72),
                             .init(color: Color(red: 0.32, green: 0.05, blue: 0.02), location: 1)]),
            center: hot, startRadius: 0, endRadius: w * 0.58))
        var crust = ctx
        crust.clip(to: lakePath)
        let fountain = liquorFountain
        var cracks = Path()
        for (index, plate) in liquorPlates.enumerated() {
            let corners: [CGPoint] = plate.cell.map { onLake(Double($0.x), Double($0.y)) }
            guard corners.count >= 3 else { continue }
            var outlinePath = Path()
            outlinePath.addLines(corners)
            outlinePath.closeSubpath()
            cracks.addPath(outlinePath)
            let n = CGFloat(corners.count)
            let mx: CGFloat = corners.reduce(CGFloat(0)) { $0 + $1.x } / n
            let my: CGFloat = corners.reduce(CGFloat(0)) { $0 + $1.y } / n
            let depth: CGFloat = min(1, max(0, (my - yFar) / (yNear - yFar)))
            let spread: CGFloat = corners.reduce(CGFloat(0)) { (sum: CGFloat, c: CGPoint) -> CGFloat in
                let dx: CGFloat = c.x - mx, dy: CGFloat = c.y - my
                return sum + (dx * dx + dy * dy).squareRoot()
            }
            let radius: CGFloat = max(1e-3, spread / n)
            let fromHot: Double = hypot(Double(plate.seed.x) - fountain.u, Double(plate.seed.y) - fountain.v)
            let young: Double = max(0, 1 - fromHot / 0.45)
            let gap: CGFloat = (0.30 + CGFloat(0.35 + 0.65 * hash(index, 522)) * depth + CGFloat(1.6 * young)) * k
            let s: CGFloat = max(0.2, 1 - gap / radius)
            let q: [CGPoint] = corners.map { CGPoint(x: mx + ($0.x - mx) * s, y: my + ($0.y - my) * s) }
            /// The point `f` of the way from `a` to `b`.
            func along(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
            var crustPlate = Path()
            crustPlate.move(to: along(q[0], q[1], 0.15))
            for j in 1...q.count {
                let previous = q[j - 1], corner = q[j % q.count], next = q[(j + 1) % q.count]
                crustPlate.addLine(to: along(previous, corner, 0.85))
                crustPlate.addQuadCurve(to: along(corner, next, 0.15), control: corner)
            }
            crustPlate.closeSubpath()
            let v: Double = hash(index, 521)
            let r: Double = 0.045 + 0.030 * v + 0.26 * young * young
            let g: Double = 0.022 + 0.010 * v + 0.045 * young * young
            let b: Double = 0.020 + 0.008 * v
            crust.fill(crustPlate, with: .linearGradient(
                Gradient(stops: [.init(color: Color(red: 1.5 * r + 0.02, green: 1.3 * g, blue: b), location: 0),
                                 .init(color: Color(red: r, green: g, blue: b), location: 0.5),
                                 .init(color: Color(red: 0.8 * r, green: 0.8 * g, blue: 0.9 * b), location: 1)]),
                startPoint: CGPoint(x: mx, y: my - radius), endPoint: CGPoint(x: mx, y: my + radius)))
            crust.stroke(crustPlate, with: .color(Color(red: 1.0, green: 0.40, blue: 0.08).opacity(0.05 + 0.14 * young)), lineWidth: 0.6 * k)
        }
        // The cracks' light blooming over the crust, strongest round the fountain.
        var bloom = light
        bloom.clip(to: lakePath)
        bloom.addFilter(.blur(radius: 3 * k))
        bloom.drawLayer { layer in
            layer.stroke(cracks, with: .radialGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.10).opacity(0.27 * heat),
                                  Color(red: 1.0, green: 0.45, blue: 0.10).opacity(0.10 * heat),
                                  Color(red: 1.0, green: 0.45, blue: 0.10).opacity(0.03 * heat)]),
                center: hot, startRadius: 0, endRadius: w * 0.42), lineWidth: 2.4 * k)
        }
        // The lake's margin: a bright seam where it meets the floor.
        light.stroke(lakePath, with: .color(Color(red: 1.0, green: 0.50, blue: 0.10).opacity(0.35 * heat)), lineWidth: 1.1 * k)
        var seamGlow = light
        seamGlow.addFilter(.blur(radius: 5 * k))
        seamGlow.stroke(lakePath, with: .color(Color(red: 1.0, green: 0.35, blue: 0.06).opacity(0.30 * heat)), lineWidth: 5 * k)

        // The fountain: a dome of bright lava and spatter thrown up on every beat, arcing and falling back within it.
        let pool: CGFloat = 22 * k
        light.fill(Path(ellipseIn: CGRect(x: hot.x - pool, y: hot.y - 0.5 * pool, width: 2 * pool, height: pool)),
                   with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.65).opacity(0.65 * heat),
                                                           Color(red: 1.0, green: 0.55, blue: 0.10).opacity(0)]),
                                         center: hot, startRadius: 0, endRadius: pool))
        light.fill(Path(ellipseIn: CGRect(x: hot.x - 6 * k, y: hot.y - 4.5 * k, width: 12 * k, height: 6 * k)),
                   with: .color(Color(red: 1.0, green: 0.90, blue: 0.62).opacity(0.55 + 0.35 * throb)))
        let s: CGFloat = CGFloat(phase)
        for j in 0..<8 {
            let vx: CGFloat = CGFloat(hash(j, 631) - 0.5) * 40 * k
            let up: CGFloat = CGFloat(0.50 + 0.50 * hash(j, 632)) * 46 * k
            let x: CGFloat = hot.x + vx * s
            let y: CGFloat = hot.y - up * 4 * s * (1 - s)
            let r: CGFloat = CGFloat(0.9 + 0.8 * hash(j, 633)) * k * (1 - 0.4 * s)
            light.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Color(red: 1.0, green: Double(0.86 - 0.4 * s), blue: Double(0.48 - 0.38 * s)).opacity(Double(0.9 * (1 - s * s)))))
        }

        // The embers: one leaves the fountain on every beat and rises past the rim, cooling.
        for ember in liquorEmbers(at: t, pulse: pulse) where ember.light > 0 {
            let c = liquorEmberColour(ember.heat)
            let colour = Color(red: c.red, green: c.green, blue: c.blue)
            let at = CGPoint(x: w * ember.x, y: h * ember.y)
            let halo: CGFloat = 6 * k
            let r: CGFloat = CGFloat(1.1 + 0.6 * ember.heat) * k
            light.fill(Path(ellipseIn: CGRect(x: at.x - halo, y: at.y - halo, width: 2 * halo, height: 2 * halo)),
                       with: .radialGradient(Gradient(colors: [colour.opacity(0.35 * ember.light), colour.opacity(0)]),
                                             center: at, startRadius: 0, endRadius: halo))
            light.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(colour.opacity(0.95 * ember.light)))
        }

        // The near rim: black basalt along the bottom, its edge catching the lake's light.
        let edge: [CGPoint] = profile(size, count: 60) { (x: Double) -> Double in
            let rise: Double = 0.06 * exp(-pow((x - 0.98) / 0.09, 2))
            return 0.915 - rise + 0.010 * sin(17 * x + 0.3) + 0.006 * sin(41 * x)
        }
        var near = Path()
        near.move(to: CGPoint(x: 0, y: h))
        for p in edge { near.addLine(to: p) }
        near.addLine(to: CGPoint(x: w, y: h))
        near.closeSubpath()
        ctx.fill(near, with: .color(Color(red: 0.022, green: 0.011, blue: 0.010)))
        var edgeLine = Path()
        edgeLine.addLines(edge)
        light.stroke(edgeLine, with: .color(Color(red: 0.85, green: 0.28, blue: 0.06).opacity(0.40)), lineWidth: 0.9 * k)
    }
}

// MARK: - Neon Night Drive (a place card; Fire & Neon, Set 14): an elevated expressway through the city at night, in rain,
// seen through the windscreen. Long-exposure light trails run down the wet road to its end between the towers, red going
// away and white coming on; wordless neon glyphs glow on the towers and stretch down the road in reflections, one of them
// blinking up on each beat at the drive's tempo (120); beyond the wiper's arc the glass is beaded with rain. One sign's
// glyph is the app's own icon (the easter egg). No words, brands, logos or emergency lights.

extension CardArt {
    /// The drive card's horizon and the road's vanishing point (fractions of the card).
    static let driveHorizon: Double = 0.50
    static let driveVanishing = CGPoint(x: 0.60, y: 0.50)

    /// A sign's glyph: abstract shapes, and the app's own icon.
    enum DriveGlyph: Equatable { case diamond, ring, chevrons, arrows, icon }

    /// The drive card's neon signs: each glyph, its centre and size (fractions of the card; the size of the height), its
    /// colour and the beat of the bar it blinks up on. The amber one on the right tower is the app's icon.
    static let driveSigns: [(glyph: DriveGlyph, x: Double, y: Double, size: Double, colour: (red: Double, green: Double, blue: Double), beat: Int)] = [
        (glyph: .diamond, x: 0.085, y: 0.215, size: 0.105, colour: (red: 1.0, green: 0.16, blue: 0.58), beat: 0),
        (glyph: .ring, x: 0.315, y: 0.30, size: 0.060, colour: (red: 0.12, green: 0.86, blue: 1.0), beat: 1),
        (glyph: .chevrons, x: 0.715, y: 0.355, size: 0.040, colour: (red: 1.0, green: 0.64, blue: 0.20), beat: 2),
        (glyph: .icon, x: 0.905, y: 0.235, size: 0.100, colour: (red: 1.0, green: 0.64, blue: 0.20), beat: 3),
        (glyph: .arrows, x: 0.475, y: 0.395, size: 0.032, colour: (red: 0.66, green: 0.34, blue: 1.0), beat: 1),
    ]

    /// The app's icon (Packaging/AppIcon.svg) as a glyph: its right upper and lower wings as the icon draws them, each a
    /// start and three cubic Béziers (control, control, end) in the icon's 1024 units, mirrored about x = 512 for the left.
    static let driveIconWings: [(start: CGPoint, curves: [(CGPoint, CGPoint, CGPoint)])] = [
        (start: CGPoint(x: 520, y: 486), curves: [(CGPoint(x: 560, y: 370), CGPoint(x: 690, y: 250), CGPoint(x: 812, y: 286)),
                                                  (CGPoint(x: 884, y: 308), CGPoint(x: 878, y: 432), CGPoint(x: 778, y: 490)),
                                                  (CGPoint(x: 700, y: 534), CGPoint(x: 590, y: 520), CGPoint(x: 520, y: 500))]),
        (start: CGPoint(x: 520, y: 520), curves: [(CGPoint(x: 594, y: 534), CGPoint(x: 712, y: 562), CGPoint(x: 752, y: 640)),
                                                  (CGPoint(x: 784, y: 708), CGPoint(x: 704, y: 772), CGPoint(x: 632, y: 742)),
                                                  (CGPoint(x: 572, y: 716), CGPoint(x: 534, y: 626), CGPoint(x: 520, y: 548))]),
    ]

    /// The icon glyph centred on `c`, its wings `span` points across: the four wings, the body, the antennae, the head and
    /// the antennae's tips, as neon tubes (one path to stroke).
    static func driveIconPath(at c: CGPoint, span: CGFloat) -> Path {
        let s: CGFloat = span / 560
        func p(_ q: CGPoint, _ side: CGFloat) -> CGPoint { CGPoint(x: c.x + side * (q.x - 512) * s, y: c.y + (q.y - 500) * s) }
        var path = Path()
        for side: CGFloat in [1, -1] {
            for wing in driveIconWings {
                path.move(to: p(wing.start, side))
                for curve in wing.curves { path.addCurve(to: p(curve.2, side), control1: p(curve.0, side), control2: p(curve.1, side)) }
                path.closeSubpath()
            }
            path.move(to: p(CGPoint(x: 512 - side * 6, y: 404), 1))
            path.addCurve(to: p(CGPoint(x: 512 - side * 74, y: 300), 1), control1: p(CGPoint(x: 512 - side * 18, y: 360), 1),
                          control2: p(CGPoint(x: 512 - side * 42, y: 320), 1))
            let tip = p(CGPoint(x: 512 - side * 76, y: 298), 1)
            path.addEllipse(in: CGRect(x: tip.x - 10 * s, y: tip.y - 10 * s, width: 20 * s, height: 20 * s))
        }
        path.move(to: p(CGPoint(x: 512, y: 432), 1))
        path.addLine(to: p(CGPoint(x: 512, y: 652), 1))
        let head = p(CGPoint(x: 512, y: 418), 1)
        path.addEllipse(in: CGRect(x: head.x - 20 * s, y: head.y - 20 * s, width: 40 * s, height: 40 * s))
        return path
    }

    /// A sign's glyph centred on `c`, `r` points from its centre to its top: one path to stroke as neon tubes.
    static func driveGlyphPath(_ glyph: DriveGlyph, at c: CGPoint, radius r: CGFloat) -> Path {
        var path = Path()
        switch glyph {
        case .diamond:
            for f: CGFloat in [1, 0.55] {
                path.move(to: CGPoint(x: c.x, y: c.y - f * r))
                path.addLine(to: CGPoint(x: c.x + 0.55 * f * r, y: c.y))
                path.addLine(to: CGPoint(x: c.x, y: c.y + f * r))
                path.addLine(to: CGPoint(x: c.x - 0.55 * f * r, y: c.y))
                path.closeSubpath()
            }
        case .ring:
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            path.addEllipse(in: CGRect(x: c.x - 0.28 * r, y: c.y - 0.28 * r, width: 0.56 * r, height: 0.56 * r))
        case .chevrons:
            for i in 0..<3 {
                let o: CGFloat = CGFloat(i - 1) * 0.75 * r
                path.move(to: CGPoint(x: c.x + o - 0.4 * r, y: c.y - 0.7 * r))
                path.addLine(to: CGPoint(x: c.x + o + 0.25 * r, y: c.y))
                path.addLine(to: CGPoint(x: c.x + o - 0.4 * r, y: c.y + 0.7 * r))
            }
        case .arrows:
            for i in 0..<3 {
                let y: CGFloat = c.y - 1.3 * r + CGFloat(i) * 1.3 * r
                path.move(to: CGPoint(x: c.x - 0.5 * r, y: y - 0.45 * r))
                path.addLine(to: CGPoint(x: c.x + 0.5 * r, y: y - 0.45 * r))
                path.addLine(to: CGPoint(x: c.x, y: y + 0.45 * r))
                path.closeSubpath()
            }
        case .icon:
            path = driveIconPath(at: c, span: 2 * r)
        }
        return path
    }

    /// A point along a lane (fractions of the card): `lane` is where it meets the card's bottom edge, `s` how far along it,
    /// 0 at the bottom … 1 at the road's end; the road bends gently left on its way.
    static func driveRoadPoint(lane: Double, _ s: Double) -> CGPoint {
        let hz: Double = driveHorizon
        let y: Double = 1 - (1 - hz) * (1 - pow(1 - min(1, max(0, s)), 2.2))
        let f: Double = (y - hz) / (1 - hz)
        let vx: Double = Double(driveVanishing.x)
        return CGPoint(x: vx + (lane - vx) * f - 0.10 * f * (1 - f), y: y)
    }

    /// The light trails: each one's lane, colour, and where and which way its car is on the beat (1 going away, −1 coming
    /// on): red tail-lights up the left lanes, white headlights down the right.
    static let driveTrails: [(lane: Double, colour: (red: Double, green: Double, blue: Double), offset: Double, way: Double)] = [
        (lane: 0.18, colour: (red: 1.0, green: 0.10, blue: 0.10), offset: 0.0, way: 1),
        (lane: 0.27, colour: (red: 1.0, green: 0.16, blue: 0.12), offset: 0.5, way: 1),
        (lane: 0.53, colour: (red: 1.0, green: 0.12, blue: 0.10), offset: 0.25, way: 1),
        (lane: 0.70, colour: (red: 1.0, green: 0.93, blue: 0.80), offset: 0.75, way: -1),
        (lane: 0.96, colour: (red: 1.0, green: 0.86, blue: 0.66), offset: 0.4, way: -1),
        (lane: 1.10, colour: (red: 1.0, green: 0.95, blue: 0.85), offset: 0.1, way: -1),
    ]

    /// The wiper's arc on the drive card: its pivot below the card and its reach (fractions of the height, x of the width)
    /// and the angle either side of upright it sweeps (radians).
    static let driveWiper: (x: Double, y: Double, reach: Double, sweep: Double) = (0.30, 1.30, 1.12, 1.15)

    /// Whether a point (in points, on a card `size`) is inside the arc the wiper keeps clear.
    static func driveWiped(_ p: CGPoint, _ size: CGSize) -> Bool {
        let wiper = driveWiper
        let dx: Double = Double(p.x) - Double(size.width) * wiper.x
        let dy: Double = Double(size.height) * wiper.y - Double(p.y)
        return (dx * dx + dy * dy).squareRoot() < Double(size.height) * wiper.reach && abs(atan2(dx, dy)) < wiper.sweep
    }

    /// A sign's light at `t` (0…1): steady, blinking up on its beat of the bar at the drive's tempo and fading through it.
    static func driveSignLight(beat: Int, at t: Double, pulse: Double) -> Double {
        let beats: Double = t / pulse
        let now = Int(floor(beats)) % 4
        guard now == beat else { return 0.75 }
        return 0.75 + 0.25 * exp(-4 * (beats - floor(beats)))
    }

    /// Draws the card: the sky, the towers and their windows, the road, the signs' reflections, the lanes, the light
    /// trails, the signs, the rain and the windscreen. Everything moves once a beat or once a bar, so the picture repeats
    /// once a bar.
    static func neonExpressway(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ pulse: Double) {
        let w = size.width, h = size.height
        let k: CGFloat = w / 600
        let beats: Double = t / pulse
        let bars: Double = beats / 4
        let hz: CGFloat = h * driveHorizon
        let vp = CGPoint(x: w * driveVanishing.x, y: h * driveVanishing.y)
        var light = ctx
        light.blendMode = .plusLighter
        func colour(_ c: (red: Double, green: Double, blue: Double)) -> Color { Color(red: c.red, green: c.green, blue: c.blue) }

        // The sky: a wet night, the city's glow low under the cloud.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: hz)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.020, green: 0.016, blue: 0.050), location: 0),
                             .init(color: Color(red: 0.060, green: 0.030, blue: 0.105), location: 0.45),
                             .init(color: Color(red: 0.20, green: 0.06, blue: 0.20), location: 0.82),
                             .init(color: Color(red: 0.34, green: 0.11, blue: 0.28), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: hz)))
        let reach: CGFloat = w * 0.45
        var cityGlow = light
        cityGlow.translateBy(x: vp.x, y: hz)
        cityGlow.scaleBy(x: 1, y: 0.35)
        cityGlow.fill(Path(ellipseIn: CGRect(x: -reach, y: -reach, width: 2 * reach, height: 2 * reach)),
                      with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.35, blue: 0.55).opacity(0.30),
                                                              Color(red: 1.0, green: 0.25, blue: 0.50).opacity(0)]),
                                            center: .zero, startRadius: 0, endRadius: reach))
        // Low cloud over the city, its underside lit by the neon and the streets, more as it nears the horizon.
        var clouds = ctx
        clouds.addFilter(.blur(radius: 9 * k))
        clouds.drawLayer { layer in
            for i in 0..<16 {
                let x: CGFloat = w * CGFloat(1.2 * hash(i, 681) - 0.1)
                let y: CGFloat = h * CGFloat(0.08 + 0.30 * hash(i, 682))
                let r: CGFloat = w * CGFloat(0.10 + 0.14 * hash(i, 683))
                let low: Double = Double(y / hz)
                layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - 0.18 * r, width: 2 * r, height: 0.36 * r)),
                           with: .color(Color(red: 0.22 + 0.25 * low, green: 0.07 + 0.06 * low, blue: 0.20 + 0.14 * low).opacity(0.10 + 0.20 * low)))
            }
        }

        // Lit windows, gathered by colour and brightness so each lot is one path: warm and cool, three levels each.
        var windows: [Path] = Array(repeating: Path(), count: 6)
        let levels: [Double] = [0.28, 0.42, 0.58]
        func window(_ p: Path, warm: Bool, _ v: Double) {
            let level = min(2, Int(v * 3))
            windows[(warm ? 0 : 3) + level].addPath(p)
        }
        func flush() {
            for (i, p) in windows.enumerated() {
                let c: Color = i < 3 ? Color(red: 1.0, green: 0.78, blue: 0.46) : Color(red: 0.62, green: 0.86, blue: 1.0)
                ctx.fill(p, with: .color(c.opacity(levels[i % 3])))
            }
            windows = Array(repeating: Path(), count: 6)
        }

        // Two rows of towers along the skyline: far in the haze, then nearer and darker; lower towards the road's end.
        let rows: [(count: Int, from: Double, to: Double, low: Double, high: Double, shade: (red: Double, green: Double, blue: Double), lit: Double)] = [
            (count: 22, from: -0.02, to: 1.02, low: 0.06, high: 0.17, shade: (red: 0.12, green: 0.065, blue: 0.17), lit: 0.10),
            (count: 11, from: -0.04, to: 1.04, low: 0.12, high: 0.30, shade: (red: 0.055, green: 0.035, blue: 0.095), lit: 0.16)]
        for (row, line) in rows.enumerated() {
            for i in 0..<line.count {
                let span: Double = (line.to - line.from) / Double(line.count)
                let left: Double = line.from + span * (Double(i) + 0.08 * hash(i, 700 + row))
                let wide: Double = span * (0.55 + 0.4 * hash(i, 710 + row))
                let tall: Double = line.low + (line.high - line.low) * hash(i, 720 + row)
                let away: Double = min(1, abs(left + wide / 2 - Double(driveVanishing.x)) / 0.45)
                let top: CGFloat = h * CGFloat(driveHorizon - tall * (0.45 + 0.55 * away))
                // Lit from below by the streets; some with a narrower storey on top.
                var body = Path(CGRect(x: w * left, y: top, width: w * wide, height: hz - top + 1))
                if hash(i, 725 + row) < 0.4 {
                    body.addRect(CGRect(x: w * (left + 0.2 * wide), y: top - 0.03 * h, width: 0.6 * w * wide, height: 0.03 * h + 1))
                }
                let shade = line.shade
                ctx.fill(body, with: .linearGradient(
                    Gradient(colors: [colour(shade), Color(red: shade.red + 0.07, green: shade.green + 0.02, blue: shade.blue + 0.06)]),
                    startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: hz)))
                let cols: Int = max(2, Int(Double(w) * wide / Double(3.4 * k)))
                let storeys: Int = max(2, Int(Double(hz - top) / Double(4.2 * k)))
                for a in 0..<cols {
                    for b in 0..<storeys {
                        let q = i * 977 + a * 31 + b
                        guard hash(q, 730 + row) <= line.lit else { continue }
                        let x: CGFloat = w * CGFloat(left) + (CGFloat(a) + 0.3) * w * CGFloat(wide) / CGFloat(cols)
                        let y: CGFloat = top + (CGFloat(b) + 0.35) * (hz - top) / CGFloat(storeys)
                        window(Path(CGRect(x: x, y: y, width: 1.3 * k, height: 1.6 * k)), warm: hash(q, 740 + row) < 0.7, hash(b, a + 750 + row))
                    }
                }
            }
            flush()
        }

        // The nearest towers: a facade either side of the expressway, running away to the road's end, its windows in
        // rows and in columns spaced as they recede.
        for (side, face) in [(near: -0.01, far: 0.25, top: -0.02), (near: 1.01, far: 0.79, top: -0.04)].enumerated() {
            let x0: CGFloat = w * CGFloat(face.near), x1: CGFloat = w * CGFloat(face.far)
            let top0: CGFloat = h * CGFloat(face.top), foot0: CGFloat = h * 0.60
            /// The facade's edge at `x`, on the line from its near edge at `y0` towards the vanishing point.
            func at(_ x: CGFloat, _ y0: CGFloat) -> CGFloat { vp.y + (y0 - vp.y) * (x - vp.x) / (x0 - vp.x) }
            var facade = Path()
            facade.addLines([CGPoint(x: x0, y: top0), CGPoint(x: x1, y: at(x1, top0)), CGPoint(x: x1, y: at(x1, foot0)), CGPoint(x: x0, y: foot0)])
            facade.closeSubpath()
            ctx.fill(facade, with: .linearGradient(Gradient(colors: [Color(red: 0.030, green: 0.022, blue: 0.055), Color(red: 0.050, green: 0.032, blue: 0.080)]),
                                                   startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
            var mullions = Path()
            for j in 0..<60 {
                let z: CGFloat = 1 + 0.12 * CGFloat(j) * (1 + 0.05 * CGFloat(j))
                let xa: CGFloat = vp.x + (x0 - vp.x) / z
                let xb: CGFloat = vp.x + (x0 - vp.x) / (z + 0.05 * (1 + 0.05 * CGFloat(j)))
                if (xa - x1) * (x0 - x1) < 0 { break }
                let ta: CGFloat = at(xa, top0), fa: CGFloat = at(xa, foot0), tb: CGFloat = at(xb, top0), fb: CGFloat = at(xb, foot0)
                for r in 0..<15 {
                    let q = j * 41 + r + side * 991
                    guard hash(q, 760) <= 0.22 else { continue }
                    let f0: CGFloat = (CGFloat(r) + 0.25) / 15, f1: CGFloat = (CGFloat(r) + 0.62) / 15
                    var pane = Path()
                    pane.addLines([CGPoint(x: xa, y: ta + (fa - ta) * f0), CGPoint(x: xb, y: tb + (fb - tb) * f0),
                                   CGPoint(x: xb, y: tb + (fb - tb) * f1), CGPoint(x: xa, y: ta + (fa - ta) * f1)])
                    pane.closeSubpath()
                    window(pane, warm: hash(q, 761) < 0.75, hash(j, r + 770 + side))
                }
                if j % 6 == 0 {
                    mullions.move(to: CGPoint(x: xa, y: ta))
                    mullions.addLine(to: CGPoint(x: xa, y: fa))
                }
            }
            flush()
            ctx.stroke(mullions, with: .color(Color(red: 0.12, green: 0.08, blue: 0.18).opacity(0.7)), lineWidth: 0.6 * k)
        }

        // The road: wet asphalt running to the city's end, lighter where it mirrors the glow.
        ctx.fill(Path(CGRect(x: 0, y: hz, width: w, height: h - hz)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.07, green: 0.035, blue: 0.09), location: 0),
                             .init(color: Color(red: 0.030, green: 0.022, blue: 0.045), location: 0.4),
                             .init(color: Color(red: 0.020, green: 0.016, blue: 0.030), location: 1)]),
            startPoint: CGPoint(x: 0, y: hz), endPoint: CGPoint(x: 0, y: h)))
        var road = Path()
        road.addLines([CGPoint(x: vp.x - 0.012 * w, y: hz), CGPoint(x: vp.x + 0.012 * w, y: hz), CGPoint(x: 1.35 * w, y: h), CGPoint(x: -0.35 * w, y: h)])
        road.closeSubpath()
        ctx.fill(road, with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.16, green: 0.07, blue: 0.17), location: 0),
                             .init(color: Color(red: 0.05, green: 0.035, blue: 0.07), location: 0.35),
                             .init(color: Color(red: 0.03, green: 0.025, blue: 0.045), location: 1)]),
            startPoint: CGPoint(x: 0, y: hz), endPoint: CGPoint(x: 0, y: h)))

        // The signs' reflections: long streaks of their colour down the wet road.
        var mirror = light
        mirror.addFilter(.blur(radius: 2.5 * k))
        mirror.drawLayer { layer in
            for sign in driveSigns {
                let x: CGFloat = w * CGFloat(sign.x)
                let length: CGFloat = 1.6 * (hz - h * CGFloat(sign.y))
                let on: Double = 0.7 + 0.3 * (driveSignLight(beat: sign.beat, at: t, pulse: pulse) - 0.75) / 0.25
                let c = colour(sign.colour)
                layer.fill(Path(CGRect(x: x - 4 * k, y: hz + 2 * k, width: 8 * k, height: length)),
                           with: .linearGradient(Gradient(colors: [c.opacity(0.30 * on), c.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: hz), endPoint: CGPoint(x: 0, y: hz + length)))
            }
        }

        /// A lane's point in points.
        func onRoad(_ lane: Double, _ s: Double) -> CGPoint {
            let p = driveRoadPoint(lane: lane, s)
            return CGPoint(x: w * p.x, y: h * p.y)
        }
        /// How near a point on the road is: 0 at its end … 1 at the card's bottom edge.
        func nearness(_ p: CGPoint) -> CGFloat { (p.y - hz) / (h - hz) }

        // The lanes: dashed lines running to the road's end, a dash passing on every beat.
        for lane in [0.08, 0.40, 0.84] {
            for d in 0..<14 {
                let cycle: Double = (Double(d) - beats) / 14
                let s0: Double = cycle - floor(cycle)
                guard s0 + 0.035 <= 0.98 else { continue }
                let a = onRoad(lane, s0), b = onRoad(lane, s0 + 0.035)
                let f: CGFloat = nearness(a)
                var dash = Path()
                dash.move(to: a)
                dash.addLine(to: b)
                ctx.stroke(dash, with: .color(Color(red: 0.85, green: 0.82, blue: 0.90).opacity(Double(0.35 * f + 0.05))),
                           style: StrokeStyle(lineWidth: (0.6 + 2.2 * f) * k, lineCap: .round))
            }
        }

        // Street lamps along both parapets, running away to the road's end, each mirrored down the wet road.
        var lampGlow = light
        lampGlow.addFilter(.blur(radius: 2 * k))
        var poles = Path()
        for lane in [-0.10, 1.32] {
            for j in 0..<9 {
                let f: Double = 1 / (1 + 0.55 * Double(j))
                let foot = onRoad(lane, 1 - pow(f, 1 / 2.2))
                let tall: CGFloat = 95 * k * CGFloat(f)
                let head = CGPoint(x: foot.x, y: foot.y - tall)
                poles.move(to: foot)
                poles.addLine(to: head)
                let r: CGFloat = CGFloat(2 + 10 * f) * k
                light.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)),
                           with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.66).opacity(0.55),
                                                                   Color(red: 1.0, green: 0.70, blue: 0.45).opacity(0)]),
                                                 center: head, startRadius: 0, endRadius: r))
                light.fill(Path(ellipseIn: CGRect(x: head.x - 0.25 * r, y: head.y - 0.18 * r, width: 0.5 * r, height: 0.36 * r)),
                           with: .color(Color(red: 1.0, green: 0.95, blue: 0.85).opacity(0.9)))
                let length: CGFloat = 1.5 * tall
                lampGlow.fill(Path(CGRect(x: head.x - 0.22 * r, y: foot.y, width: 0.44 * r, height: length)),
                              with: .linearGradient(Gradient(colors: [Color(red: 1.0, green: 0.8, blue: 0.55).opacity(0.22),
                                                                      Color(red: 1.0, green: 0.8, blue: 0.55).opacity(0)]),
                                                    startPoint: CGPoint(x: 0, y: foot.y), endPoint: CGPoint(x: 0, y: foot.y + length)))
            }
        }
        ctx.stroke(poles, with: .color(Color(red: 0.03, green: 0.025, blue: 0.05)), lineWidth: 1.2 * k)

        // The light trails: long exposures of the traffic, as ribbons narrowing to the road's end; a car's lights travel
        // each one once a beat.
        /// A trail as a ribbon `scale` times its width, from the card's bottom edge to the road's end.
        func ribbon(_ lane: Double, scale: CGFloat) -> Path {
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...40 {
                let s: Double = Double(i) / 40
                let p = onRoad(lane, s), q = onRoad(lane, min(1, s + 0.01))
                var dx: CGFloat = q.x - p.x, dy: CGFloat = q.y - p.y
                let length: CGFloat = max(1e-6, (dx * dx + dy * dy).squareRoot())
                dx /= length; dy /= length
                let half: CGFloat = 0.5 * scale * (0.5 + 5.0 * nearness(p)) * k
                left.append(CGPoint(x: p.x - dy * half, y: p.y + dx * half))
                right.append(CGPoint(x: p.x + dy * half, y: p.y - dx * half))
            }
            var path = Path()
            path.addLines(left + right.reversed())
            path.closeSubpath()
            return path
        }
        var trailGlow = light
        trailGlow.addFilter(.blur(radius: 4 * k))
        trailGlow.drawLayer { layer in
            for trail in driveTrails {
                layer.fill(ribbon(trail.lane, scale: 3), with: .color(colour(trail.colour).opacity(0.35)))
            }
        }
        for trail in driveTrails {
            let c = colour(trail.colour)
            light.fill(ribbon(trail.lane, scale: 0.6), with: .linearGradient(Gradient(colors: [c.opacity(0.85), c.opacity(0.55)]),
                                                                             startPoint: CGPoint(x: vp.x, y: h), endPoint: vp))
            let cycle: Double = trail.offset + trail.way * beats
            let s: Double = cycle - floor(cycle)
            let at = onRoad(trail.lane, 1 - pow(1 - s, 1.5))
            let r: CGFloat = (1 + 7 * nearness(at)) * k
            light.fill(Path(ellipseIn: CGRect(x: at.x - 2.5 * r, y: at.y - r, width: 5 * r, height: 2 * r)),
                       with: .radialGradient(Gradient(colors: [c.opacity(0.6), c.opacity(0)]), center: at, startRadius: 0, endRadius: 2.5 * r))
        }

        // The neon signs: wordless glyphs as glowing tubes; one blinks up on each beat of the bar.
        let glyphs: [(path: Path, colour: Color, light: Double)] = driveSigns.map { sign in
            let c = CGPoint(x: w * CGFloat(sign.x), y: h * CGFloat(sign.y))
            let path = driveGlyphPath(sign.glyph, at: c, radius: h * CGFloat(sign.size) / 2)
            return (path: path, colour: colour(sign.colour), light: driveSignLight(beat: sign.beat, at: t, pulse: pulse))
        }
        var neon = light
        neon.addFilter(.blur(radius: 5 * k))
        neon.drawLayer { layer in
            for g in glyphs {
                layer.stroke(g.path, with: .color(g.colour.opacity(0.55 * g.light)),
                             style: StrokeStyle(lineWidth: 5 * k, lineCap: .round, lineJoin: .round))
            }
        }
        for g in glyphs {
            light.stroke(g.path, with: .color(g.colour.opacity(0.85 * g.light)), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round))
            light.stroke(g.path, with: .color(Color(red: 1, green: 0.95, blue: 0.95).opacity(0.45 * g.light)),
                         style: StrokeStyle(lineWidth: 0.6 * k, lineCap: .round, lineJoin: .round))
        }

        // Rain: fine streaks falling through the light, three times down the card a bar.
        var rain = Path()
        for i in 0..<110 {
            let x: CGFloat = w * CGFloat(hash(i, 801))
            let fall: Double = hash(i, 802) + 3 * bars
            let y: CGFloat = h * CGFloat(fall - floor(fall))
            let length: CGFloat = CGFloat(6 + 8 * hash(i, 803)) * k
            rain.move(to: CGPoint(x: x, y: y))
            rain.addLine(to: CGPoint(x: x - 0.25 * length, y: y + length))
        }
        ctx.stroke(rain, with: .color(Color(red: 0.75, green: 0.75, blue: 0.95).opacity(0.10)), lineWidth: 0.5 * k)

        // The windscreen: the wiper's arc swept clear; beyond it a film of water beaded with rain, and the blade parked
        // along its right edge.
        let wiper = driveWiper
        let pivot = CGPoint(x: w * CGFloat(wiper.x), y: h * CGFloat(wiper.y))
        let reachW: CGFloat = h * CGFloat(wiper.reach)
        func onArc(_ a: Double) -> CGPoint { CGPoint(x: pivot.x + reachW * CGFloat(sin(a)), y: pivot.y - reachW * CGFloat(cos(a))) }
        let tipRight = onArc(wiper.sweep)
        let downTo: CGFloat = (pivot.y - h) / (pivot.y - tipRight.y)
        let bladeFoot = CGPoint(x: pivot.x + (tipRight.x - pivot.x) * downTo, y: h)
        let leftmost: Double = -asin(min(1, Double(pivot.x / reachW)))
        var wet = Path()
        wet.addLines([.zero, CGPoint(x: w, y: 0), CGPoint(x: w, y: h), bladeFoot, tipRight])
        for i in 1...60 { wet.addLine(to: onArc(wiper.sweep + (leftmost - wiper.sweep) * Double(i) / 60)) }
        wet.closeSubpath()
        var film = ctx
        film.clip(to: wet)
        film.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Color(red: 0.40, green: 0.30, blue: 0.55).opacity(0.12)))
        var beads = Path(), glints = Path()
        for i in 0..<140 {
            let p = CGPoint(x: w * CGFloat(hash(i, 811)), y: h * CGFloat(hash(i, 812)))
            guard !driveWiped(p, size) else { continue }
            let r: CGFloat = CGFloat(0.7 + 2.2 * pow(hash(i, 813), 2)) * k
            beads.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            glints.addEllipse(in: CGRect(x: p.x - 0.55 * r, y: p.y - 0.75 * r, width: 0.9 * r, height: 0.65 * r))
        }
        film.fill(beads, with: .color(Color(red: 0.05, green: 0.04, blue: 0.09).opacity(0.45)))
        var filmLight = film
        filmLight.blendMode = .plusLighter
        filmLight.fill(glints, with: .color(Color(red: 0.95, green: 0.80, blue: 1.0).opacity(0.40)))
        var arc = Path()
        arc.addLines((0...60).map { onArc(leftmost + (wiper.sweep - leftmost) * Double($0) / 60) })
        var arcGlow = light
        arcGlow.addFilter(.blur(radius: 2 * k))
        arcGlow.stroke(arc, with: .color(Color(red: 0.75, green: 0.65, blue: 1.0).opacity(0.05)), lineWidth: 2.5 * k)
        var blade = Path()
        blade.move(to: bladeFoot)
        blade.addLine(to: tipRight)
        ctx.stroke(blade, with: .color(Color(red: 0.010, green: 0.008, blue: 0.016)), style: StrokeStyle(lineWidth: 4.6 * k, lineCap: .round))
        var bladeEdge = Path()
        bladeEdge.move(to: CGPoint(x: bladeFoot.x - 1.6 * k, y: bladeFoot.y))
        bladeEdge.addLine(to: CGPoint(x: tipRight.x - 1.6 * k, y: tipRight.y))
        light.stroke(bladeEdge, with: .color(Color(red: 0.75, green: 0.55, blue: 0.95).opacity(0.28)), lineWidth: 0.7 * k)
    }
}
