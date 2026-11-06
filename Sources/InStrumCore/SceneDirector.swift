import Foundation

/// A model that wants the set's mood (spec §6).
public protocol MoodAware { var mood: Mood { get set } }

/// A model that wants the Living Sky each frame.
public protocol SkyAware { mutating func setSky(_ s: SkyState) }

/// A model that wants the built-in instrument's pulse (spec §7.6): the director hands it `instrumentPulse` before every
/// step, nil while the instrument has none. Any model may want it, a world or not.
public protocol PulseAware { var pulse: InstrumentPulse? { get set } }

/// A model that plays along with the built-in grand (Storms spec §3, §9.2): the director hands it the instrument's
/// pressure and whether a key is being repeated before every step, and reads back the morph it forces on the
/// instrument's voice, which the app hands the engine after the step. Any model may want it, a world or not.
public protocol InstrumentAware {
    /// Single Note Grand's morph as the engine reads it back, 0…1; 0 for every other instrument.
    var instrumentPressure: Float { get set }
    /// True while the grand hears the same key struck four or more times at 2 a second or faster.
    var instrumentRepeat: Bool { get set }
    /// The morph the model forces on the voice, 0…1 (Morph .8 for the storm's arrival), or nil while it forces none.
    var forcedMorph: Float? { get }
}

/// How the mood shapes worlds, visuals and ambience. 0.5 everywhere is neutral (every scale 1).
public enum MoodLook {
    public static func exposure(_ m: Mood) -> Float { Float(0.8 + 0.4 * m.brightness) }
    /// Added to PostSettings.warmth.
    public static func warmthOffset(_ m: Mood) -> Float { Float((m.warmth - 0.5) * 0.6) }
    /// Mist and depth haze.
    public static func hazeScale(_ m: Mood) -> Float { Float(0.5 + m.space) }
    /// Cloud, water and star drift.
    public static func driftScale(_ m: Mood) -> Float { Float(0.5 + m.motion) }
    /// Ripple strength, streak speed: how far reactions travel.
    public static func reactionScale(_ m: Mood) -> Float { Float(0.7 + 0.6 * m.energy) }
    /// Ripple and streak lifetime: how long reactions linger.
    public static func lingerScale(_ m: Mood) -> Float { Float(0.7 + 0.6 * m.motion) }
    /// Spacious moods sound further away.
    public static func ambienceCloseness(base: Double, _ m: Mood) -> Double { min(1, max(0, base - (m.space - 0.5) * 0.4)) }
    /// Multiplies how often ambience events happen.
    public static func ambienceDensity(_ m: Mood) -> Double { 0.7 + 0.6 * m.energy }
}

/// The built-in instrument's own pulse (spec §7.6), for visuals that blink with it: an arp's tempo and its gate, or Endless
/// Rise's Pulse (Storms spec §3).
public struct InstrumentPulse: Equatable {
    /// The arp's tempo: it steps once a sixteenth (60 / bpm / 4 s), from a phrase's first note, as the arp does. Endless
    /// Rise's is its Pulse's Tempo: the pad ducks once a beat, every fourth sixteenth of the same grid.
    public var bpm: Double
    /// How hard it blinks, 0…1 (Blue Depth's Blink: its gate shortens as this rises; Endless Rise's Pulse: how deep the
    /// pad ducks).
    public var gate: Double

    public init(bpm: Double, gate: Double) {
        self.bpm = bpm
        self.gate = gate
    }

    /// The pulse of a built-in instrument with these dials (by identifier, in their own units): Blue Depth's arp, at
    /// its Tempo with Blink as the gate, while Blink is up; Chrome Bass's arp; Endless Rise's Pulse, at its Tempo with the
    /// Pulse as the gate, while the Pulse is up. Nil for any other instrument (or none), for Blue Depth at Blink 0, which
    /// has no arp (the engine's own threshold, so the visuals and the arp agree), and for Endless Rise at Pulse 0 (or with
    /// no Pulse dial named), whose pad then doesn't duck.
    public init?(engine: BuiltInEngine?, values: [String: Double]) {
        if engine == .endlessRise {
            guard let pulse = values["pulse"], pulse > 1e-3 else { return nil }
            let tempo: Double = values["tempo"] ?? 124   // the dial's default, the card's felt pulse
            self.init(bpm: min(170, max(70, tempo)), gate: min(1, pulse))
            return
        }
        if engine == .replicantBrass {
            // Chrome Bass's arp: Rate's step expressed as the sixteenth of an equivalent tempo; no pulse with the arp
            // off or with no split (no left hand to play it).
            guard let arp = values["arp"], arp >= 0.5, (values["split"] ?? 48) >= 28 else { return nil }
            let beats: [Double] = [1, 0.5, 1.0 / 3, 0.25, 1.0 / 6, 0.125]
            let rate = beats[min(5, max(0, Int((values["rate"] ?? 3).rounded())))]
            let tempo = min(170, max(70, values["tempo"] ?? 120))
            self.init(bpm: tempo * 0.25 / rate, gate: 0.55)
            return
        }
        guard engine == .blueDepth, let blink = values["blink"], blink > 1e-3 else { return nil }
        let tempo: Double = values["tempo"] ?? 118   // the dial's default, the record's tempo
        self.init(bpm: min(160, max(70, tempo)), gate: min(1, blink))
    }
}

/// What the scene asks of the built-in instrument after each step (Storms spec §3, §4.1): the tension to hand the engine
/// (`isd_synth_set_tension`) and whether a drop landed on this step (`isd_synth_trigger_drop`, once). With build and
/// drop on, the tension is Excitement's, and the engine adds 0.3 × the player's pressure itself; with it off, it is
/// 0.7 × the pressure, so with the engine's 0.3 the riser climbs at the pressure itself (aftertouch = Tension).
/// Engines other than Endless Rise, and plugins, ignore both.
public struct InstrumentCue: Equatable {
    public var tension: Float
    public var drop: Bool

    public init(tension: Float = 0, drop: Bool = false) {
        self.tension = tension
        self.drop = drop
    }
}

/// One theme the app can show: its settings and how to make its model.
public struct ThemeEntry {
    public let id, name: String
    public let parameters: [ParamSpec]
    public let macroTargets: [Macro: [(id: String, weight: Double)]]
    let make: () -> AnyThemeBoxProtocol

    static func make<T: ThemeModel>(_ type: T.Type) -> ThemeEntry {
        ThemeEntry(id: T.id, name: T.displayName, parameters: T.parameters, macroTargets: T.macroTargets, make: { ThemeBox<T>() })
    }
}

/// The themes the app knows about, in menu order.
public enum ThemeRegistry {
    public static let entries: [ThemeEntry] = [
        .make(MidnightSteinwayModel.self),
        .make(ButterflyGardenModel.self),
        .make(MoonlitLakeModel.self),
        .make(SpaceshipLoungeModel.self),
        .make(GoldenHourBeachModel.self),
        .make(CoastRoadModel.self),
        .make(SnowboundCabinModel.self),
        .make(BedroomDawnModel.self),
        .make(AuroraFjordModel.self),
        .make(BioluminescentBayModel.self),
        .make(TeaHouseSnowModel.self),
        .make(ZenRockGardenModel.self),
        .make(SubmarineWindowModel.self),
        .make(GreatBarrierReefModel.self),
    ]

    public static var all: [(id: String, name: String)] { entries.map { ($0.id, $0.name) } }

    /// Unknown ids fall back to Midnight Steinway.
    public static func resolve(_ id: String) -> String {
        entries.contains { $0.id == id } ? id : MidnightSteinwayModel.id
    }

    static func entry(_ id: String) -> ThemeEntry {
        let resolved = resolve(id)
        return entries.first { $0.id == resolved } ?? entries[0]
    }

    public static func parameters(for id: String) -> [ParamSpec] { entry(id).parameters }

    /// Worlds live under the Living Sky and play an ambience.
    public static func isWorld(_ id: String) -> Bool { entry(id).make().wantsSky }

    public static func macroTargets(for id: String) -> [Macro: [(id: String, weight: Double)]] { entry(id).macroTargets }

    public static func parameterSet(for id: String, state: ThemeState) -> ParameterSet {
        ParameterSet(specs: parameters(for: id), saved: state.values, macros: state.macros, macroTargets: macroTargets(for: id))
    }
}

protocol AnyThemeBoxProtocol {
    var wantsSky: Bool { get }
    mutating func handle(_ e: PerformanceEvent)
    mutating func setMood(_ m: Mood)
    mutating func setSky(_ s: SkyState)
    mutating func setPulse(_ p: InstrumentPulse?)
    mutating func setExcitement(_ e: ExcitementFrame)
    /// The world's own surprises (`SurpriseListing`), 0 when it has none.
    var surpriseCount: Int { get }
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Any
    mutating func setInstrument(pressure: Float, repeating: Bool)
    /// An instrument-aware model's forced morph; nil for every other model.
    var forcedMorph: Float? { get }
}

struct ThemeBox<T: ThemeModel>: AnyThemeBoxProtocol {
    var model = T()
    var wantsSky: Bool { T.self is SkyAware.Type }
    mutating func handle(_ e: PerformanceEvent) { model.handle(e) }
    mutating func setMood(_ m: Mood) {
        guard var aware = model as? MoodAware, aware.mood != m else { return }
        aware.mood = m
        if let back = aware as? T { model = back }
    }
    mutating func setSky(_ s: SkyState) {
        guard var aware = model as? SkyAware else { return }
        aware.setSky(s)
        if let back = aware as? T { model = back }
    }
    mutating func setPulse(_ p: InstrumentPulse?) {
        guard var aware = model as? PulseAware, aware.pulse != p else { return }
        aware.pulse = p
        if let back = aware as? T { model = back }
    }
    mutating func setExcitement(_ e: ExcitementFrame) {
        guard T.self is ExcitementAware.Type, var aware = model as? ExcitementAware else { return }
        aware.setExcitement(e)
        if let back = aware as? T { model = back }
    }
    var surpriseCount: Int { (T.self as? SurpriseListing.Type)?.surpriseCount ?? 0 }
    mutating func step(dt: Double, params: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> Any {
        model.step(dt: dt, params: params, roles: roles, inputs: inputs, quality: quality)
    }
    mutating func setInstrument(pressure: Float, repeating: Bool) {
        guard T.self is InstrumentAware.Type, var aware = model as? InstrumentAware,
              aware.instrumentPressure != pressure || aware.instrumentRepeat != repeating else { return }
        aware.instrumentPressure = pressure
        aware.instrumentRepeat = repeating
        if let back = aware as? T { model = back }
    }
    var forcedMorph: Float? {
        guard T.self is InstrumentAware.Type else { return nil }
        return (model as? InstrumentAware)?.forcedMorph
    }
}

/// Ties playing, inputs, reactions, settings and the active theme together each frame.
/// Use from one thread (the render loop).
public final class SceneDirector {
    public private(set) var themeID: String
    public var parameters: ParameterSet
    public var reaction: ReactionMap
    public var listenStrength: Double = 0.6
    public let hub = InputHub()
    public private(set) var lastRoles = RoleValues()

    /// The set's mood, pushed into mood-aware models every step.
    public var mood = Mood.neutral
    /// The built-in instrument's pulse (Blue Depth's arp grid, Chrome Bass's arp, Endless Rise's Pulse), which the app
    /// sets from the current patch and its dials; nil for every other instrument. It is about the instrument, so it
    /// carries over a world switch. Every step hands it to a pulse-aware model (`PulseAware`) first.
    public var instrumentPulse: InstrumentPulse?

    /// Excitement (Fire & Neon spec §5), owned here: every note reaches it as it reaches the theme, and each step steps it
    /// before the theme and hands its frame to an excitement-aware model (`ExcitementAware`). It is about the playing,
    /// so it carries over a world switch.
    public private(set) var excitement = Excitement()
    /// Excitement's controls (energy, moments, surprises, build and drop).
    public var excitementSettings: ExcitementSettings {
        get { excitement.settings }
        set { excitement.settings = newValue }
    }
    /// What Excitement handed out on the latest step.
    public private(set) var excitementFrame = ExcitementFrame()
    /// The player's pressure (aftertouch, channel or a key's), 0…1: the latest, 0 after all notes off.
    public private(set) var pressure: Float = 0
    /// The tension the instrument and the world climb on together (Storms spec §3): with build and drop on, Excitement's
    /// tension plus 0.3 × the pressure (at most 1); with it off, the pressure itself. It is the number Endless Rise's
    /// riser climbs at, so a world that turns with it (the wall cloud) turns with the sound.
    public private(set) var instrumentTension: Float = 0
    /// What the app hands the built-in instrument after this step: the tension and, on the one step a drop lands, the drop.
    public private(set) var instrumentCue = InstrumentCue()
    /// Stepped each frame for sky-aware models (worlds).
    public let sky = LivingSky(settings: SkySettings())
    /// The latest sky state, when the active theme uses one.
    public private(set) var lastSky: SkyState?
    /// Wall clock for the sky (previews and tests freeze it).
    public var clock: () -> Date = { Date() }
    /// The instrument's pressure (Storms spec §3): Single Note Grand's morph as the engine reads it back, 0…1 (the
    /// player's pressure over the Morph floor, or the world's forced morph, smoothed), which the app sets before each
    /// step; 0 for every other instrument. The strike distance and the voice's distortion are one number. It is about
    /// the instrument, so it carries over a world switch; every step hands it to an instrument-aware model first.
    public var instrumentPressure: Float = 0
    /// True while the grand hears the same key struck four or more times at 2 a second or faster (Storms spec §4.2,
    /// §9.2), which the app sets before each step from the engine; handed on with the pressure. Strike Lines lands a
    /// strike on the horizon for each of those notes.
    public var instrumentRepeat = false
    /// The morph the world forces on the grand's voice (Storms spec §9.2: Morph .8 for the drop's 2.5 s), 0…1, or nil
    /// while it forces none: an instrument-aware model's, as it stands after its latest step. The app hands it to the
    /// engine after each step (`isd_synth_set_forced_morph`; nil goes as a negative value and lets it go, and the morph
    /// returns to the player's pressure over 250 ms). A world switch takes it with the world.
    public var forcedMorph: Float? { box.forcedMorph }

    /// How far the key estimate must lead the best one on any other root before it is published.
    public static let keyMargin = 0.05

    /// The key the player is in (spec §7.1), once the analyzer is sure of it (8 notes or more, and a lead of at least
    /// `keyMargin`); nil while it can't tell. It carries over a world switch: it is about the playing, not the world.
    public var key: AmbienceKey? {
        guard let root = analyzer.keyRoot, analyzer.keyConfidence >= Self.keyMargin else { return nil }
        return AmbienceKey(root: root, major: !analyzer.keyIsMinor)
    }

    /// What the app asks of the clock (Small Wins: hold the moment, the sleep dim, Reduce Motion, breathing), set before
    /// each frame's events.
    public var controls = SceneControls()
    /// True while time is held.
    public private(set) var holding = false
    /// How far the renderers step this frame: the step's dt, which held time, the sleep dim and Reduce Motion shape.
    public private(set) var visualDt = 0.0
    /// The post exposure's multiplier (the sleep dim lowers it by up to a stop): 1 while nothing dims the world.
    public var exposureScale: Float { 1 }
    /// What the app reads back after each step.
    public var report: SceneReport { SceneReport(holding: holding, sky: lastSky, key: key) }

    /// What the ambience should play for a frame: a world's own soundscape (silence for the other themes), with the key
    /// the player is in (spec §7.1). Every theme carries the key, so a bell heard after a switch to a world already sits
    /// in your key. `t` is the frame's time.
    public func ambience(for frame: Any, at t: Double) -> AmbienceScene {
        var scene = (frame as? AmbienceProviding)?.ambience ?? .silent
        scene.key = key
        return scene
    }

    private var box: AnyThemeBoxProtocol
    private var analyzer = PlayingAnalyzer()
    private var held: Set<UInt8> = []

    public init(themeID: String, state: ThemeState, reaction: ReactionMap) {
        let id = ThemeRegistry.resolve(themeID)
        self.themeID = id
        self.parameters = ThemeRegistry.parameterSet(for: id, state: state)
        self.reaction = reaction
        self.box = ThemeRegistry.entry(id).make()
    }

    /// A director for any entry (tests).
    init(entry: ThemeEntry, state: ThemeState, reaction: ReactionMap) {
        themeID = entry.id
        parameters = ParameterSet(specs: entry.parameters, saved: state.values, macros: state.macros, macroTargets: entry.macroTargets)
        self.reaction = reaction
        box = entry.make()
    }

    /// Starts the theme fresh (no held notes carried over).
    public func switchTheme(to id: String, state: ThemeState) {
        let resolved = ThemeRegistry.resolve(id)
        themeID = resolved
        parameters = ThemeRegistry.parameterSet(for: resolved, state: state)
        box = ThemeRegistry.entry(resolved).make()
        lastSky = nil
    }

    public func handle(_ events: [PerformanceEvent], at t: Double) {
        for e in events {
            switch e {
            case let .noteOn(note, velocity):
                held.insert(note)
                excitement.noteOn(Int(note), velocity: velocity)
            case let .noteOff(note):
                held.remove(note)
                excitement.noteOff(Int(note))
            case .allNotesOff:
                for note in held { excitement.noteOff(Int(note)) }
                held.removeAll()
                pressure = 0
            case let .pressure(p): pressure = min(1, max(0, p))
            default: break
            }
            box.handle(e)
            analyzer.handle(e, at: t)
            InputRouting.route(e, into: hub, at: t)
        }
    }

    /// Returns the theme's frame (GardenFrame, SteinwayFrame or a world's frame).
    public func step(dt: Double, t: Double, quality: QualityLevel) -> Any {
        visualDt = dt
        hub.set(.held, held.isEmpty ? 0 : 1, at: t)
        analyzer.publish(to: hub, at: t)
        let frame = hub.frame(at: t, listenStrength: listenStrength)
        let (roles, offsets) = reaction.evaluate(frame)
        lastRoles = roles
        box.setInstrument(pressure: instrumentPressure, repeating: instrumentRepeat)
        box.setMood(mood)
        box.setPulse(instrumentPulse)
        stepExcitement(dt: dt)
        if box.wantsSky {
            // All three are world parameters, read every step: a world without them (choice "") follows the sky and the
            // calendar, so leaving a world whose aurora or meteors are "Always" leaves them behind.
            let hold = SkyHold(rawValue: parameters.choice("light.hold")) ?? .follow
            let aurora = AuroraMode(rawValue: parameters.choice("aurora.mode")) ?? .follow
            let meteors = MeteorMode(rawValue: parameters.choice("meteors.mode")) ?? .follow
            // Storms (spec §6–§8): a world may choose its own anvil crawlers and sheet lightning (nil: the Sky extras
            // settings) and hold a supercell's stage (Supercell Sky's picker; nil: no supercell), and its Random Beautiful
            // adds a gust front where storms appear and virga in dry worlds. All are read every step, so they leave with
            // the world.
            let storm = StormInputs(crawlers: SkyExtraMode(rawValue: parameters.choice(SkyExtraMode.crawlersID)),
                                    sheet: SkyExtraMode(rawValue: parameters.choice(SkyExtraMode.sheetID)),
                                    supercell: SupercellStage(rawValue: parameters.choice(SupercellStage.id)),
                                    randomExtras: WorldWeather.randomExtras(for: themeID))
            let s = sky.step(now: clock(), dt: dt, hold: hold, aurora: aurora, meteors: meteors, storm: storm)
            lastSky = s
            box.setSky(s)
        }
        return box.step(dt: dt, params: parameters.withOffsets(offsets), roles: roles, inputs: frame, quality: quality)
    }

    /// Steps Excitement by the step's dt, hands its frame to the theme, and works out the instrument's tension and cue
    /// (Storms spec §3, §4.1). A drop is cued only on the step its moment arrives, so it reaches the engine once.
    private func stepExcitement(dt: Double) {
        excitement.holding = holding
        excitement.reduceMotion = controls.reduceMotion
        let e = excitement.step(dt: dt, surpriseCount: box.surpriseCount)
        excitementFrame = e
        box.setExcitement(e)
        let p = pressure
        if excitement.settings.buildAndDrop {
            instrumentTension = min(1, e.tension + 0.3 * p)
            instrumentCue = InstrumentCue(tension: e.tension, drop: dt > 0 && e.moment?.isDrop == true)
        } else {
            instrumentTension = p
            instrumentCue = InstrumentCue(tension: 0.7 * p, drop: false)
        }
    }
}
