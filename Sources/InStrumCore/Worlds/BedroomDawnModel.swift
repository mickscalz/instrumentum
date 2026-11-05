import Foundation
import simd

/// Everything the Bedroom at Dawn renderer needs for a frame.
public struct BedroomFrame: AmbienceProviding {
    public var sky: SkyState
    /// The two sheer curtain panels (window coordinates: x across, y up, z into the room), 24 × 32 points each.
    public var curtains: (left: [SIMD3<Float>], right: [SIMD3<Float>])
    /// Curtain Light: the morning glow (0…1), its tint, the dust motes and the fairy lights (0…1 each).
    public var glow: Float
    public var tint: SIMD3<Float>
    public var motes: [CurtainLight.Mote]
    public var fairy: [Float]
    /// Frost on the glass (cold days), and the warm patches when Frost Grow is the visual.
    public var frostLevel: Float
    public var patches: [FrostPatch]
    /// The street lamp (0…1), flickering as it warms up.
    public var streetLamp: Float
    /// Houses across the road with their lights on (0…8).
    public var litWindows: Int
    public var windowOpen: Bool
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp in the sky over the street, when it's the chosen visual.
    public var warp: WarpFrame?
}

/// Set 6's world: a bedroom window at dawn behind sheer curtains, rooftops and a street waking up outside.
/// Its visual, Curtain Light, lets your playing breathe into the curtains and the morning light.
public struct BedroomDawnModel: ThemeModel, MoodAware, SkyAware {
    public typealias Frame = BedroomFrame
    public static let id = "bedroom-dawn"
    public static let displayName = "Bedroom Window at Dawn"
    public static let visuals = ["Curtain Light", "Frost Grow", "Galaxy Warp"]
    /// The lamp switches on below −3° and off above −2°, warming up over 3 s.
    static let lampOn = -3.0, lampOff = -2.0, lampWarmUp: Float = 3

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var light = CurtainLight(moteCount: 400)
    private var frost = FrostGrow()
    private var warp = GalaxyWarp()
    private var left: Cloth
    private var right: Cloth
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var time = 0.0
    private var lampLit = false
    private var lampAge: Float = 0
    private var lastVisual = ""

    private static let layout = KeyboardLayout.keys()

    public init() {
        // Sheer panels hang from the rod just above the window, drawn back toward the sides (each over a fifth of
        // the glass and the wall beside it).
        left = Cloth(width: 0.5, height: 1.24, origin: SIMD3(-0.3, 1.08, 0.03), seed: 0x1EF7)
        right = Cloth(width: 0.5, height: 1.24, origin: SIMD3(0.8, 1.08, 0.03), seed: 0x816A7)
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// Houses with their lights on across the road: none before 05:00, all eight by 07:30, going dark after 22:00.
    static func litWindows(hour: Double) -> Int {
        let h = hour.isFinite ? (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24) : 12
        if h < 5 { return 0 }
        if h < 7.5 { return Int((8 * (h - 5) / 2.5).rounded(.down)) }
        if h < 22 { return 8 }
        return max(0, Int((8 * (1 - (h - 22) / 2)).rounded(.down)))
    }

    /// The street lamp's light: off, or warming up with a flicker for 3 s, then steady.
    static func lampLevel(age: Float) -> Float {
        guard age < lampWarmUp else { return 1 }
        let ramp = age / lampWarmUp
        let flicker = 0.7 + 0.3 * sin(age * 37) * sin(age * 13 + 1)
        return min(1, ramp * ramp * flicker)
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> BedroomFrame {
        time += dt
        let visual = p.choice("visual")
        let frostVisual = visual == "Frost Grow", warping = visual == "Galaxy Warp", curtainVisual = !frostVisual && !warping
        if visual != lastVisual {
            light.allNotesOff(); frost.allNotesOff(); warp.allNotesOff()
            lastVisual = visual
        }
        frost.frost = Float(p.number("frost"))
        frost.reactionScale = MoodLook.reactionScale(mood)
        frost.lingerScale = MoodLook.lingerScale(mood)
        light.reactionScale = MoodLook.reactionScale(mood) * Float(0.5 + p.number("light"))
        light.lingerScale = MoodLook.lingerScale(mood)
        light.glintLimit = CurtainLight.moteBudget(quality)   // glint only motes the renderer draws
        // Pastel dawn (the set's default hold) keeps it morning whatever the clock says.
        let heldDawn = Self.heldDawn(p)
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                if warping { warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time) }
                else if frostVisual { frost.noteOn(note, velocity: velocity, at: time) }
                else { light.noteOn(note, velocity: velocity, at: time) }
            case let .noteOff(note):
                held[note] = nil
                light.noteOff(note); frost.noteOff(note); warp.noteOff(note)
            case let .pedal(down, _):
                light.setPedal(down); frost.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                light.allNotesOff(); frost.allNotesOff(); warp.allNotesOff()
                light.setPedal(false); frost.setPedal(false)
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        light.step(dt: dt, sunAltitude: sky.sun.altitude, roles: roles)
        frost.step(dt: dt, baseFrost: sky.frost * frost.frost, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)

        // The curtains: the sky's breeze (twice as much with the window open) times the sway, and Curtain Light's puffs.
        let open = p.number("window.open") > 0.5
        let breeze = sky.wind * (open ? 2 : 1) * Float(2 * p.number("sway"))
        let puffs = curtainVisual ? light.puffs : []
        left.step(dt: dt, wind: breeze, puffs: puffs)
        right.step(dt: dt, wind: breeze, puffs: puffs)

        // The street lamp, with hysteresis and a warm-up flicker.
        let sunAlt = sky.sun.altitude
        if lampLit, sunAlt > Self.lampOff { lampLit = false; lampAge = 0 }
        else if !lampLit, sunAlt < Self.lampOn { lampLit = true; lampAge = 0 }
        if lampLit { lampAge += Float(max(0, min(dt, 0.25))) }
        let lamp: Float = lampLit ? Self.lampLevel(age: lampAge) : 0

        // Keys glow a soft peach while held, then fade.
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        return BedroomFrame(sky: sky, curtains: (left.positions, right.positions),
                            glow: curtainVisual ? light.glow : 0, tint: light.tint, motes: light.motes, fairy: light.fairy,
                            frostLevel: frost.level, patches: frostVisual ? frost.patches : [],
                            streetLamp: lamp, litWindows: Self.litWindows(hour: heldDawn ? Self.heldDawnHour : sky.hourOfDay),
                            windowOpen: open, keys: keys,
                            ambience: ambience(roles: roles, open: open, heldDawn: heldDawn), mood: mood, time: time,
                            warp: warping ? warpFrame : nil)
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The hour a held pastel dawn stands for (the houses, the condensation).
    static let heldDawnHour = 6.5

    /// Whether the light is held at a pastel dawn: then it's morning, whatever the clock says.
    public static func heldDawn(_ p: ParameterSet) -> Bool { SkyHold(rawValue: p.choice("light.hold")) == .pastelDawn }

    /// How far into the window's glass the outdoors comes: an old sash lets the birds through, softly; open a crack,
    /// the street comes closer.
    static let indoorsClosed = 0.7, indoorsOpen = 0.35

    /// The bedroom's soundscape: the dawn chorus, the kettle and the clock, the street waking up, the breeze, drips
    /// after the rain and rain on the glass; all through the window. A held dawn is always morning.
    private func ambience(roles: RoleValues, open: Bool, heldDawn: Bool) -> AmbienceScene {
        let hour = sky.hourOfDay, sunAlt = sky.sun.altitude
        let morning = heldDawn ? Self.smooth(-8, -5, sunAlt)
            : Self.smooth(4.5, 5.5, hour) * (1 - Self.smooth(9, 10.5, hour)) * Self.smooth(-8, -5, sunAlt)
        let night = !heldDawn && sunAlt < -6
        let progress = heldDawn || hour < 12 ? Self.smooth(-10, 25, sunAlt) : 1
        var levels: [AmbienceSource: Double] = [
            .dawnChorus: 0.6 * morning,
            .kettle: 0.5,
            .clock: 0.15,
            .street: (0.15 + 0.45 * progress) * (night ? 0.5 : 1),
            .breeze: min(1, 0.3 + Double(sky.wind)),
            .rainOnGlass: Double(sky.rain),
        ]
        WeatherAmbience.levels(sky, base: &levels)
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        // The window's own hush, and rime's on top of it (rimed trees and roofs soak up the street; spec §5 of Sets 9 & 10).
        let window: Double = open ? Self.indoorsOpen : Self.indoorsClosed
        return AmbienceScene(levels: levels, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: min(1, window + WeatherAmbience.indoorsLift(sky)), wetness: Double(sky.wetness),
                             snowOnGlass: Double(sky.snow))
    }
}

extension BedroomDawnModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing does to the room",
                  kind: .choice(visuals), defaultValue: .choice("Curtain Light")),
        SkyHold.spec(default: .pastelDawn),
        MeteorMode.spec(default: .follow),
        slider("light", "Morning light", "Curtain Light", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How much the light through the curtains swells while you hold notes"),
        slider("sway", "Curtain sway", "Curtain Light", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How much the curtains move in the breeze and your notes' puffs"),
        slider("motes", "Dust motes", "Room", 0...1, 0.6, surprise: 0.2...1, help: "Dust drifting in the light shafts"),
        slider("fairy", "Fairy lights", "Room", 0...1, 0.5, surprise: 0...1, help: "Fairy lights on the curtain rod, from dusk"),
        ParamSpec(id: "window.open", name: "Window open", group: "Room", help: "Open the window a crack: the curtains move more and the street comes closer",
                  kind: .toggle, defaultValue: .bool(false)),
        slider("frost", "Frost", "Frost Grow", 0...1, 0.5, surprise: 0.2...0.8,
               help: "Frost on the glass on cold mornings, and how far Frost Grow lets it creep"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard below the window",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("light", 0.7), ("sway", 0.5)],
        .speed: [("sway", 0.4)],
        .density: [("motes", 0.8), ("fairy", 0.4)],
        .glow: [("light", 1), ("fairy", 0.6)],
        .chaos: [("sway", 0.5)],
        .temperature: [("light", 0.4)],
    ]
}
