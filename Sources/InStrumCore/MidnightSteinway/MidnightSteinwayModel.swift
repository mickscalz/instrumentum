/// Everything the Midnight Steinway renderer needs for one frame.
public struct SteinwayFrame {
    public var scene: SceneFrame
    public var exposure: Float
    public var bloom: Float
    public var haze: Float
    public var spotWidth: Float
    /// -1 cool ... +1 warm.
    public var warmth: Float
    public var sheen: Float
    public var finish: Int
    public var glowColor: RGBA
    public var time: Double
    /// Excitement (Fire & Neon spec §5.5): the spotlight blooming overhead (0…1 × the moment's strength, before the flash
    /// limiter), the light gathering with tension (0…1), the surprises (a dust motes' shimmer in the light, the curtain
    /// stirring at the stage's sides: each 0…1 as it plays) and the seconds the curtain has been stirring.
    public var spot: Float = 0
    public var gather: Float = 0
    public var motes: Float = 0
    public var curtain: Float = 0
    public var curtainAge: Float = 0
    public var surprises: [PlayingSurprise] = []
    public var reduceMotion = false
}

/// Glossy black stage with warm spotlights, on the new engine (settings + roles).
public struct MidnightSteinwayModel: ThemeModel, ExcitementAware, SurpriseListing {
    public typealias Frame = SteinwayFrame
    public static let id = MidnightSteinwayScene.id
    public static let displayName = MidnightSteinwayScene.displayName
    public static let finishes = ["Lacquer", "Satin", "Ivory", "Brushed metal", "Gold", "Pearl"]
    /// The surprises (spec §5.5): a dust motes' shimmer, the curtain stirring.
    public static let surpriseCount = 2
    public static let surpriseSeconds: [Float] = [8, 9]
    /// The spotlight blooms (spec §5.5): open over 0.6 s, held, closing over 2.5 s; a drop's bloom is longer.
    public static let momentSeconds: Float = 5, dropSeconds: Float = 6

    /// The spotlight's bloom `age` seconds into a moment `life` long (0…1).
    public static func bloom(age: Float, life: Float) -> Float {
        ExcitementPlay.envelope(age: age, life: life, rise: 0.6, fall: 2.5)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "glow", name: "Key glow", group: "Light", help: "How brightly keys light up",
                  kind: .slider(0...1.5), defaultValue: .number(1), hero: true, surprise: 0.6...1.4),
        ParamSpec(id: "bloom", name: "Golden bloom", group: "Light", help: "Glow across the stage on chords",
                  kind: .slider(0...1), defaultValue: .number(0.6), hero: true, surprise: 0.2...1),
        ParamSpec(id: "haze", name: "Haze", group: "Light", help: "Warm haze in the air",
                  kind: .slider(0...1), defaultValue: .number(0.35), hero: true, surprise: 0...0.8),
        ParamSpec(id: "spot.width", name: "Spotlight width", group: "Light", help: "",
                  kind: .slider(0.5...2), defaultValue: .number(1), surprise: 0.7...1.6),
        ParamSpec(id: "spot.warmth", name: "Spotlight warmth", group: "Light", help: "Cool white ↔ warm amber",
                  kind: .slider(0...1), defaultValue: .number(0.7), surprise: 0.3...1),
        ParamSpec(id: "lacquer.sheen", name: "Lacquer sheen", group: "Stage", help: "Gloss of the black stage",
                  kind: .slider(0...1), defaultValue: .number(0.5), surprise: 0.2...0.9),
        ParamSpec(id: "keys.finish", name: "Key finish", group: "Keys", help: "",
                  kind: .choice(finishes), defaultValue: .choice("Lacquer"), surprise: 0...1),
        ParamSpec(id: "keys.glowColor", name: "Key glow colour", group: "Keys", help: "",
                  kind: .color, defaultValue: .color(RGBA(1, 0.706, 0.353)), surprise: 0...1),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("glow", 0.6), ("bloom", 0.6)],
        .glow: [("glow", 0.8), ("bloom", 0.5)],
        .density: [("haze", 0.6)],
        .temperature: [("spot.warmth", 1)],
        .speed: [], .chaos: [],
    ]

    private var scene = MidnightSteinwayScene()
    private var time = 0.0
    private var excite = ExcitementFrame()
    private var play = ExcitementPlay()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { scene.handle(e) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SteinwayFrame {
        time += dt
        let energy = Float(roles[.energy]), brightness = Float(roles[.brightness])
        var frame = scene.step(dt: dt, intensity: Float(roles[.density]) * 0.5 + energy * 0.5, audioLevel: Float(inputs[.loudness]))
        let glow = Float(p.number("glow"))
        for i in frame.keys.indices { frame.keys[i].glow = min(1, frame.keys[i].glow * glow) }
        for i in frame.spotlights.indices { frame.spotlights[i].intensity *= glow }
        frame.bloom *= Float(p.number("bloom")) / 0.6

        // Excitement (spec §5.5): Energy plays through the existing reactions; a moment blooms the spotlight overhead;
        // tension gathers the light toward the middle; a drop's bloom is golden and full.
        let e = excite
        excite.moment = nil
        excite.surprise = nil
        play.step(dt: dt, frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        var spot: Float = 0
        if let m = play.moment {
            spot = Self.bloom(age: m.age, life: m.duration) * m.strength
            if m.isDrop { frame.bloom = max(frame.bloom, play.drop) }
        }
        var motes: Float = 0, curtain: Float = 0, curtainAge: Float = 0
        if let s = play.surprise(0) { motes = ExcitementPlay.envelope(age: s.age, life: s.duration, rise: 1.5, fall: 2.5) }
        if let s = play.surprise(1) {
            curtain = ExcitementPlay.envelope(age: s.age, life: s.duration, rise: 1.2, fall: 3.5)
            curtainAge = s.age
        }
        var out = SteinwayFrame(
            scene: frame,
            exposure: 1 + 0.25 * energy + 0.15 * brightness,
            bloom: Float(p.number("bloom")),
            haze: min(1, Float(p.number("haze")) + 0.5 * Float(roles[.atmosphere])),
            spotWidth: Float(p.number("spot.width")) * (1 + 0.3 * Float(roles[.size])),
            warmth: max(-1, min(1, Float(p.number("spot.warmth")) * 2 - 1 + Float(roles[.warmth]))),
            sheen: Float(p.number("lacquer.sheen")),
            finish: Self.finishes.firstIndex(of: p.choice("keys.finish")) ?? 0,
            glowColor: p.color("keys.glowColor"),
            time: time)
        out.spot = spot
        out.gather = play.tension
        out.motes = motes
        out.curtain = curtain
        out.curtainAge = curtainAge
        out.surprises = play.surprises
        out.reduceMotion = play.reduceMotion
        return out
    }
}
