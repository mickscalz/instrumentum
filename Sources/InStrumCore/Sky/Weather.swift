import Foundation

public enum WeatherKind: String, Codable, CaseIterable { case clear, lightCloud, overcast, mist, drizzle, rain, storm, snow, blizzard, afterRain, sunShower, fogBank, sleet, monsoon, hail, smokeHaze, iceFog, thunderheads, dustStorm, flurries, freezingDrizzle, squall, dryLightning, humid, diamondDust, rime, seaSmoke, gustFront, virga, ashfall, supercell }

/// Pick one yourself, or let the sky wander through beautiful weathers. (`.real` comes later.)
public enum WeatherMode: String, Codable, CaseIterable { case pick, randomBeautiful }

/// How much of each element a weather has, 0…1.
public struct WeatherValues: Equatable {
    public var cloud, rain, snow, mist, wind: Float
    /// Ice halos and sundogs; frost on glass (some kinds only at night, see `frostFormsOnlyAtNight`); gustiness.
    public var halo: Float = 0, frost: Float = 0, gust: Float = 0
    /// Fireflies on humid nights (scaled by darkness in the sky); diamond dust and the light pillars it throws.
    public var fireflies: Float = 0, pillar: Float = 0
    /// Freezing fog that rimes the world (how fast `SkyState.rime` builds).
    public var rime: Float = 0
    /// Sea smoke: steam fog rising off open water in bitter, still air (`SkyState.steam`).
    public var steam: Float = 0
    /// A gust front's outflow, the cold air out of a storm (`SkyState.outflow`), and virga's streaks of rain that never
    /// land (`SkyState.virga`), 0…1 (Storms spec §7). Every other weather has none.
    public var outflow: Float = 0, virga: Float = 0
    /// Fire & Neon (spec §7): ashfall's fine grey ash, and a supercell's rotation (how fast its wall cloud turns), 0…1.
    /// Every other weather has none.
    public var ash: Float = 0, rotation: Float = 0

    static func mix(_ a: WeatherValues, _ b: WeatherValues, _ t: Float) -> WeatherValues {
        func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return WeatherValues(cloud: m(a.cloud, b.cloud), rain: m(a.rain, b.rain), snow: m(a.snow, b.snow), mist: m(a.mist, b.mist),
                             wind: m(a.wind, b.wind), halo: m(a.halo, b.halo), frost: m(a.frost, b.frost), gust: m(a.gust, b.gust),
                             fireflies: m(a.fireflies, b.fireflies), pillar: m(a.pillar, b.pillar), rime: m(a.rime, b.rime),
                             steam: m(a.steam, b.steam), outflow: m(a.outflow, b.outflow), virga: m(a.virga, b.virga),
                             ash: m(a.ash, b.ash), rotation: m(a.rotation, b.rotation))
    }
}

public extension WeatherKind {
    var values: WeatherValues {
        switch self {
        case .clear: return WeatherValues(cloud: 0, rain: 0, snow: 0, mist: 0.1, wind: 0.1, frost: 0.15)
        case .lightCloud: return WeatherValues(cloud: 0.35, rain: 0, snow: 0, mist: 0.15, wind: 0.2, halo: 0.7, frost: 0.1, gust: 0.1)
        case .overcast: return WeatherValues(cloud: 0.85, rain: 0, snow: 0, mist: 0.25, wind: 0.3, frost: 0.1, gust: 0.1)
        case .mist: return WeatherValues(cloud: 0.4, rain: 0, snow: 0, mist: 0.9, wind: 0.05, halo: 0.15, frost: 0.2)
        case .drizzle: return WeatherValues(cloud: 0.8, rain: 0.3, snow: 0, mist: 0.4, wind: 0.2, gust: 0.1)
        case .rain: return WeatherValues(cloud: 0.9, rain: 0.75, snow: 0, mist: 0.3, wind: 0.4, gust: 0.2)
        case .storm: return WeatherValues(cloud: 1, rain: 1, snow: 0, mist: 0.2, wind: 0.9, gust: 0.6)
        case .snow: return WeatherValues(cloud: 0.85, rain: 0, snow: 0.8, mist: 0.3, wind: 0.25, halo: 0.2, frost: 0.6, gust: 0.2)
        case .blizzard: return WeatherValues(cloud: 1, rain: 0, snow: 1, mist: 0.6, wind: 1, frost: 0.9, gust: 1)
        case .afterRain: return WeatherValues(cloud: 0.45, rain: 0, snow: 0, mist: 0.55, wind: 0.1)
        case .fogBank: return WeatherValues(cloud: 0.6, rain: 0, snow: 0, mist: 1, wind: 0.05, halo: 0, frost: 0.1)
        case .sleet: return WeatherValues(cloud: 0.95, rain: 0.5, snow: 0.5, mist: 0.4, wind: 0.35, frost: 0.2, gust: 0.2)
        case .monsoon: return WeatherValues(cloud: 1, rain: 1, snow: 0, mist: 0.45, wind: 0.6, gust: 0.4)
        case .hail: return WeatherValues(cloud: 1, rain: 0.7, snow: 0.25, mist: 0.2, wind: 0.5, gust: 0.4)
        case .smokeHaze: return WeatherValues(cloud: 0.3, rain: 0, snow: 0, mist: 0.8, wind: 0.1)
        case .iceFog: return WeatherValues(cloud: 0.2, rain: 0, snow: 0, mist: 0.7, wind: 0.02, halo: 0.8, frost: 0.8)
        case .thunderheads: return WeatherValues(cloud: 0.95, rain: 0, snow: 0, mist: 0.15, wind: 0.3, gust: 0.3)
        case .dustStorm: return WeatherValues(cloud: 0.5, rain: 0, snow: 0, mist: 0.9, wind: 0.9, gust: 0.7)
        case .flurries: return WeatherValues(cloud: 0.55, rain: 0, snow: 0.3, mist: 0.2, wind: 0.15, halo: 0.2, frost: 0.4, gust: 0.1)
        case .freezingDrizzle: return WeatherValues(cloud: 0.85, rain: 0.25, snow: 0, mist: 0.5, wind: 0.15, frost: 0.5)
        case .squall: return WeatherValues(cloud: 1, rain: 0.9, snow: 0, mist: 0.3, wind: 1, gust: 1)
        case .dryLightning: return WeatherValues(cloud: 0.85, rain: 0, snow: 0, mist: 0.1, wind: 0.5, gust: 0.4)
        case .sunShower: return WeatherValues(cloud: 0.5, rain: 0.3, snow: 0, mist: 0.25, wind: 0.2, gust: 0.1)
        case .humid: return WeatherValues(cloud: 0.15, rain: 0, snow: 0, mist: 0.35, wind: 0.05, fireflies: 1)
        case .diamondDust: return WeatherValues(cloud: 0.05, rain: 0, snow: 0, mist: 0.2, wind: 0.02, halo: 1, frost: 0.9, pillar: 1)
        case .rime: return WeatherValues(cloud: 0.3, rain: 0, snow: 0, mist: 0.85, wind: 0.08, halo: 0.2, frost: 1, rime: 1)
        case .seaSmoke: return WeatherValues(cloud: 0.1, rain: 0, snow: 0, mist: 0.35, wind: 0.06, halo: 0.3, frost: 0.9, steam: 1)
        // Storms (spec §7): a gust front's nominal values (staged over its Approach, Hit and Rain by `WorldWeather.gustFront`:
        // the 0.2 rain is its first big drops), and virga's (no rain at all).
        case .gustFront: return WeatherValues(cloud: 0.9, rain: 0.2, snow: 0, mist: 0.5, wind: 1, gust: 1, outflow: 1)
        case .virga: return WeatherValues(cloud: 0.7, rain: 0, snow: 0, mist: 0.6, wind: 0.4, gust: 0.3, virga: 1)
        // Fire & Neon (spec §7): ashfall's quiet grey fall (with a brown-grey haze, the sun and moon reddened); a
        // supercell's nominal values (staged over its Approach, Core and Clearing by `WorldWeather.supercell`).
        case .ashfall: return WeatherValues(cloud: 0.55, rain: 0, snow: 0, mist: 0.35, wind: 0.25, ash: 1)
        case .supercell: return WeatherValues(cloud: 0.85, rain: 0.6, snow: 0, mist: 0.15, wind: 0.6, gust: 0.8, rotation: 1)
        }
    }

    /// Clear, light-cloud, overcast and misty frost forms only at night (scaled by darkness); snow's any time
    /// (and diamond dust's: still, bitter air; rime frost's, whenever it is cold and foggy; and sea smoke's, bitter all
    /// day). A humid night has none at all.
    var frostFormsOnlyAtNight: Bool {
        switch self {
        case .clear, .lightCloud, .overcast, .mist, .fogBank, .humid: return true
        default: return false
        }
    }

    /// Drizzle, rain and storms: what "after the rain" follows (a gust front ends in rain, and a supercell clears after its
    /// rain; virga never lands, and ash isn't rain).
    var isWet: Bool { self == .drizzle || self == .rain || self == .storm || self == .sleet || self == .monsoon || self == .hail || self == .squall || self == .freezingDrizzle || self == .gustFront || self == .supercell }

    /// Left out of random weather when "Calm random weather" is on (a supercell is rough; ashfall is quiet).
    var isRough: Bool { [.storm, .blizzard, .monsoon, .hail, .squall, .dustStorm, .dryLightning, .gustFront, .supercell].contains(self) }

    /// Weathers that throw lightning (a supercell's is staged: only its Core flashes, `LivingSky` times it).
    var flashes: Bool { self == .storm || self == .squall || self == .monsoon || self == .dryLightning }

    /// How often "random beautiful" picks it (overcast only when chosen; a gust front, virga, ashfall and the supercell only
    /// in the worlds whose tables add them, `WorldWeather.randomExtras`).
    var beautyWeight: Float {
        switch self {
        case .clear, .lightCloud: return 3
        case .mist: return 2
        case .drizzle, .rain: return 1
        case .storm, .snow: return 0.5
        case .blizzard: return 0.3
        case .afterRain: return 1.5
        case .sunShower: return 1
        case .dryLightning: return 0.3
        case .flurries: return 1
        case .freezingDrizzle: return 0.4
        case .squall: return 0.3
        case .thunderheads: return 0.4
        case .dustStorm: return 0.2
        case .iceFog: return 0.3
        case .hail: return 0.3
        case .smokeHaze: return 0.5
        case .fogBank: return 1
        case .sleet: return 0.6
        case .monsoon: return 0.4
        case .overcast: return 0
        case .humid: return 1.2
        case .diamondDust: return 0.5
        case .rime: return 0.5
        case .seaSmoke: return 0.5
        case .gustFront, .virga, .ashfall, .supercell: return 0
        }
    }
}

/// Weather over time: every change blends over 60 s; random spells last 5–20 minutes and never repeat a kind back to back.
struct WeatherMachine {
    static let transitionSeconds = 60.0
    private var length = WeatherMachine.transitionSeconds

    private(set) var current: WeatherKind
    private(set) var next: WeatherKind
    private(set) var blend = 0.0
    private(set) var transitioning = false
    private var from: WeatherValues
    private var spellLeft: Double
    private var rng: SeededRandom
    private var mode: WeatherMode
    /// The weathers this world's "Random, beautiful" adds, with their weights (`WorldWeather.randomExtras`): set each
    /// step, read only when a spell ends, so a world without any picks exactly as before.
    var extras: [WeatherKind: Float] = [:]
    /// Separate streams, so ice, iridescence and "after the rain" never shift the weather sequence itself.
    private var iceRng: SeededRandom
    private var afterRng: SeededRandom
    private var iridRng: SeededRandom
    /// How icy this light-cloud spell is (its halo): 0.5–1 in "Random, beautiful" (rolled per spell), 0.7 when picked.
    private(set) var ice: Float = WeatherKind.lightCloud.values.halo
    /// How iridescent this light-cloud spell's thin edges are near the sun (spec §6.3): in "Random, beautiful" about
    /// one spell in two shows it (0.3–1, rolled per spell like the ice), the rest none; 0.6 when picked.
    private(set) var iridescence: Float = WeatherMachine.pickedIridescence
    static let pickedIridescence: Float = 0.6

    init(settings: SkySettings, seed: UInt64) {
        rng = SeededRandom(seed: seed &* 0x2545_F491_4F6C_DD1D &+ 0xA5)
        iceRng = SeededRandom(seed: seed &* 0x9E37_79B9 &+ 0x1CE)
        afterRng = SeededRandom(seed: seed &* 0xBF58_476D &+ 0xAF7E)
        iridRng = SeededRandom(seed: seed &* 0x94D0_49BB &+ 0x1215)
        mode = settings.weatherMode
        let first: WeatherKind
        if settings.weatherMode == .pick { first = settings.weather }
        else { var r = rng; first = Self.pick(excluding: nil, calm: settings.calmRandom, excluded: settings.randomExcluded, &r); rng = r }
        current = first; next = first; from = first.values
        var r = rng
        spellLeft = Self.spell(&r, minutes: min(60, max(2, settings.spellMinutes)))
        rng = r
        if mode == .randomBeautiful && first == .supercell { spellLeft = Self.supercellSpell(settings) }
        if mode == .randomBeautiful && first == .lightCloud {
            ice = iceRng.range(0.5, 1)
            iridescence = Self.rollIridescence(&iridRng)
        }
    }

    /// How much of `kind` is in the sky right now (1 when settled on it; shared while blending).
    func weight(of kind: WeatherKind) -> Float {
        guard transitioning else { return current == kind ? 1 : 0 }
        let t = Float(blend), s = t * t * (3 - 2 * t)
        return (current == kind ? 1 - s : 0) + (next == kind ? s : 0)
    }

    var values: WeatherValues {
        guard transitioning else { return current.values }
        let t = Float(blend), s = t * t * (3 - 2 * t)
        return WeatherValues.mix(from, next.values, s)
    }

    mutating func step(dt: Double, settings: SkySettings) {
        let rs = min(300, max(10, settings.randomBlendSeconds)), sm = min(60, max(2, settings.spellMinutes))
        if settings.weatherMode != mode {
            mode = settings.weatherMode
            if mode == .pick { ice = WeatherKind.lightCloud.values.halo; iridescence = Self.pickedIridescence }
            spellLeft = Self.spell(&rng, minutes: sm)
            if mode == .randomBeautiful {
                begin(Self.pick(excluding: transitioning ? next : current, calm: settings.calmRandom, excluded: settings.randomExcluded, extras: extras, &rng), seconds: rs)
                if next == .supercell { spellLeft = Self.supercellSpell(settings) }
            }
        }
        switch mode {
        case .pick:
            if settings.weather != (transitioning ? next : current) { begin(settings.weather, seconds: min(120, max(1, settings.pickBlendSeconds))) }
        case .randomBeautiful:
            spellLeft -= dt
            if spellLeft <= 0, !transitioning {
                // After a wet spell, "after the rain" comes next 6 times in 10; otherwise the usual pick (without it).
                if current.isWet && afterRng.unit() < 0.6 { begin(.afterRain, seconds: rs) }
                else { begin(Self.pick(excluding: current, also: current.isWet ? .afterRain : nil, calm: settings.calmRandom, excluded: settings.randomExcluded, extras: extras, &rng), seconds: rs) }
                spellLeft += Self.spell(&rng, minutes: sm)
                // A supercell plays its event once and moves on (Fire & Neon spec §7.2): its spell is the event's length.
                if next == .supercell { spellLeft = Self.supercellSpell(settings) }
            }
        }
        if transitioning {
            blend += dt / length
            if blend >= 1 { current = next; blend = 0; transitioning = false }
        }
    }

    private mutating func begin(_ kind: WeatherKind, seconds: Double) {
        length = seconds
        if kind == .lightCloud {
            ice = mode == .randomBeautiful ? iceRng.range(0.5, 1) : WeatherKind.lightCloud.values.halo
            iridescence = mode == .randomBeautiful ? Self.rollIridescence(&iridRng) : Self.pickedIridescence
        }
        from = values
        next = kind
        blend = 0
        transitioning = kind != current || transitioning
        if !transitioning { next = current }
    }

    private static func spell(_ rng: inout SeededRandom, minutes: Double) -> Double { (300 + 900 * Double(rng.unit())) * minutes / 12.5 }

    /// A random supercell's spell: its event's length (the Advanced setting, 3–20 minutes).
    static func supercellSpell(_ settings: SkySettings) -> Double { min(1200, max(180, settings.supercellSeconds)) }

    /// One light-cloud spell in two iridesces, 0.3–1 (both draws are always taken, so the stream keeps its step).
    private static func rollIridescence(_ rng: inout SeededRandom) -> Float {
        let shows = rng.unit() < 0.5
        let amount = rng.range(0.3, 1)
        return shows ? amount : 0
    }

    /// A weight from a world's extras stands in for the kind's own (Storms: a gust front where storms appear, virga in dry
    /// worlds); without extras every weight, and so every pick, is as it always was.
    static func pick(excluding: WeatherKind?, also: WeatherKind? = nil, calm: Bool = false, excluded: [WeatherKind] = [],
                     extras: [WeatherKind: Float] = [:], _ rng: inout SeededRandom) -> WeatherKind {
        func weight(_ k: WeatherKind) -> Float {
            guard let w = extras[k], w.isFinite else { return k.beautyWeight }
            return max(0, w)
        }
        let choices = WeatherKind.allCases.filter { $0 != excluding && $0 != also && weight($0) > 0 && !(calm && $0.isRough) && !excluded.contains($0) }
        let total = choices.reduce(0) { $0 + weight($1) }
        var x = rng.unit() * total
        for k in choices {
            x -= weight(k)
            if x < 0 { return k }
        }
        return choices.last ?? .clear
    }
}

// MARK: - Held back from a release

public extension WeatherKind {
    /// Weathers that are built but held back from this release: not in the picker or the random list, and never chosen
    /// at random. Empty now: the Supercell (Fire & Neon §7.2) was held back from 12 Nov (Fire & Neon went out without
    /// it) until 13 Nov, when its shared-sky drawing was rebuilt within budget and its storm overhead and its glow by
    /// night passed by eye. Put a weather here to hold it back.
    static let heldBack: Set<WeatherKind> = []
    /// The weathers the app offers, in order.
    static var offered: [WeatherKind] { allCases.filter { !heldBack.contains($0) } }
}

public extension SkySettings {
    /// These settings as the app's sky runs them: a held-back weather is never picked (a pick of one is clear sky) and
    /// never chosen at random, even where a world's Random Beautiful table offers it. The saved settings are untouched.
    func holdingBack() -> SkySettings {
        var s = self
        for k in WeatherKind.allCases where WeatherKind.heldBack.contains(k) && !s.randomExcluded.contains(k) {
            s.randomExcluded.append(k)
        }
        if WeatherKind.heldBack.contains(s.weather) { s.weather = .clear }
        return s
    }
}
