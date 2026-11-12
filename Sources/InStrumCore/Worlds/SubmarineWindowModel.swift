import Foundation
import simd

/// A blip a note leaves on the cabin's small sonar screen (spec §8.1), tying the ping to your music.
public struct SonarBlip: Equatable {
    public var id: Int
    public var note: UInt8
    /// Its bearing (radians, clockwise from the top): its pitch class round the screen's 12-tick dial, C at the top, π/6
    /// a semitone (`SubmarineWindowModel.bearing(for:)`).
    public var angle: Float
    /// How far out it sits (0…1 of the screen's radius): 0.2 for A0 near the centre … 0.95 for C8 near the rim.
    public var range: Float
    /// 0…1 by velocity: 0.3 + 0.7 × velocity.
    public var strength: Float
    /// Seconds since its note: it fades out over one turn of the sweep (`SubmarineWindowModel.blipLife`).
    public var age: Float

    /// 0…1 now: `strength`, fading linearly to nothing over its life.
    public var brightness: Float { strength * max(0, 1 - age / SubmarineWindowModel.blipLife) }
}

/// Everything the Submarine Window renderer needs for a frame. Units: the porthole's view is x 0…1 across (left to
/// right), y 0…1 up; depths are metres below the surface; colours are linear RGB.
public struct SubFrame: AmbienceProviding {
    /// The Living Sky above, as the submarine has it (`SubmarineWindowModel.underwater`): its sun, moon, stars, meteors
    /// and weather as they are (for Snell's window and the light), but no frost or rime, nothing wet, no fireflies and no
    /// aurora.
    public var sky: SkyState
    /// The Depth dial (0…1) and the depth it dives to: 15 m at 0, 65 m at the default 0.35, 200 m at 0.62 (the twilight
    /// zone's top), 1,000 m at 1, logarithmically (`SubmarineWindowModel.depthMetres(dial:)`).
    public var depth: Float
    public var depthMetres: Float
    /// The light falling on the sea's surface (linear RGB, 1 = a noon sun and sky): the Underwater Kit's `light` for
    /// `waterLight`, `waterView`, `snellWindow` and the shafts (`SubmarineWindowModel.surfaceLight(_:)`).
    public var surfaceLight: SIMD3<Float>
    /// 0…1: the light from above that reaches the porthole, as a share of a noon surface's (Beer–Lambert through
    /// `depthMetres` of clear ocean, the three bands averaged): about 0.3 at 15 m by day, 0.045 at 65 m, nothing by
    /// 1,000 m, and far less at night.
    public var lightFromAbove: Float
    /// 0…1: how much of Snell's window shows: 1 down to 20 m, gone by 40 m (the kit's own fade).
    public var snellVisible: Float
    /// The surface's weather as seen from below, each 0 below the shallows (× `snellVisible`'s fade): how rough the
    /// surface is (0 glassy … 1 a storm churning it and flickering the shafts), how hard rain is pocking it with rings,
    /// and how milky sea smoke has turned the window (all 0…1).
    public var surfaceWaves: Float
    public var rainOnSurface: Float
    public var milky: Float
    /// Deep Lights (each brightness 0…1 for the `FlashLimiter`; all empty while Galaxy Warp plays): the creatures notes
    /// release, the lanternfish shoals runs send past, the siphonophores chords send drifting behind, and the bubble
    /// streams accents raise from the hull.
    public var creatures: [DeepCreature]
    public var shoals: [LanternShoal]
    public var siphonophores: [Siphonophore]
    public var bubbleStreams: [BubbleStream]
    /// The sonar screen: a fading blip for each note (whatever the visual), and the sweep line's bearing (radians,
    /// clockwise from the top, once round every `SubmarineWindowModel.sweepPeriod` seconds).
    public var sonarBlips: [SonarBlip]
    public var sonarSweep: Float
    /// The cabin's lighting by ship's time: 0 by day (a dim, cool white) … 1 at night (red night lighting).
    public var cabinNight: Float
    /// The settings, 0…1: the cabin's own light, the sonar screen's brightness, and the outside lamps (warm-white
    /// floodlights lighting a cone of marine snow and the nearest creatures).
    public var cabinLight: Float
    public var sonarScreen: Float
    public var lamps: Float
    /// Marine snow drifting past (`snow.live`: 150 / 300 / 400 flecks by quality), in the unit volume outside the glass.
    public var snow: MarineSnow
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp through the porthole, when it's the chosen visual (notes then streak instead of releasing creatures).
    public var warp: WarpFrame?
    /// Excitement (Fire & Neon spec §5.5): the whale passing the porthole (the moment), the dark gathering with tension
    /// (0…1: the lamps and the light from above dim), the far lights crossing with Energy (the creatures' traffic), the
    /// drawn Energy, and the surprises playing (0 an anglerfish's lure, 1 a squid's cloud of light, 2 a far sub's sonar).
    public var whale: SubWhale?
    public var dark: Float = 0
    public var passers: [SIMD4<Float>] = []
    public var energy: Float = 0
    public var surprises: [PlayingSurprise] = []
    public var reduceMotion = false
}

/// A whale passing the porthole (the Submarine Window's big moment): where it is in the porthole's disc (radius 1, y up;
/// its middle), its half-length (disc radii), which way it swims (±1), how much of it the gloom gives up (0…1), its
/// flukes' beat (turns), and how far off it is (0 close … 1 far, melting into the blue).
public struct SubWhale: Equatable {
    public var centre: SIMD2<Float>
    public var halfLength: Float
    public var heading: Float
    public var presence: Float
    public var beat: Float
    public var distance: Float
}

/// Set 11's world: inside a small research submarine at its big round viewport, the cabin in silhouette and soft light
/// (a padded bench, cables, a brass depth gauge, a small round sonar screen, a row of backlit console buttons), and
/// outside the sea at the depth you choose, from the sunlit shallows under Snell's window down to the midnight zone. The
/// sky is felt rather than seen: it drives the light, and its weather shows only in the shallows. Its visual, Deep
/// Lights, releases a glowing creature for each note.
public struct SubmarineWindowModel: ThemeModel, MoodAware, SkyAware, PulseAware, ExcitementAware, SurpriseListing {
    public typealias Frame = SubFrame
    public static let id = "submarine-window"
    public static let displayName = "Submarine Window"
    public static let visuals = ["Deep Lights", "Galaxy Warp"]
    /// The Depth dial's ends (metres).
    public static let shallowest = 15.0, deepest = 1000.0
    /// The sonar's sweep goes round once in this many seconds; a blip fades out over one turn; at most this many show.
    public static let sweepPeriod = 6.0
    public static let blipLife: Float = 6
    public static let blipCap = 24
    /// Everything outside comes through the hull a little muffled.
    public static let indoors = 0.85
    /// What reaches the submarine through the water and the hull: its own machinery, the hull, the sonar, the whales,
    /// the bubbles, a reef's shrimp and the rain's hiss on the surface. The air's own sounds (wind, drips, birds,
    /// insects) never do.
    static let heardAboard: Set<AmbienceSource> = [.shipHum, .airFlow, .hullTicks, .hullCreak, .sonar, .whaleSong, .bubbles,
                                                   .snappingShrimp, .rainOnWater]
    /// The moon's light on the surface at its full and overhead (a share of a noon's), and the night sky's own glow.
    static let moonlight = 0.03
    static let moonColour = SIMD3<Float>(0.75, 0.85, 1)
    static let starlight = SIMD3<Float>(0.002, 0.003, 0.005)
    /// The surprises (spec §5.5): an anglerfish's lure, a squid's cloud of light, a far sub's sonar.
    public static let surpriseCount = 3
    public static let surpriseSeconds: [Float] = [10, 7, 12]
    /// A whale passes the porthole (spec §5.5) over this long (a drop's, closer and slower, longer).
    public static let momentSeconds: Float = 13, dropSeconds: Float = 16
    /// The far lights crossing (Energy's traffic): at most this many at once.
    public static let passerCap = 8

    public var mood = Mood.neutral
    /// The instrument's pulse (spec §7.6), handed over by the director before every step: Deep Lights blinks on it.
    public var pulse: InstrumentPulse?
    private var sky = SkyState()
    private var deep = DeepLights()
    private var warp = GalaxyWarp()
    private var snow = MarineSnow(quality: .high, seed: 0x5AB_DEE9)
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var blips: [SonarBlip] = []
    var nextBlipID = 0
    private var lastVisual: String?
    private var time = 0.0
    private var excite = ExcitementFrame()
    private var play = ExcitementPlay()
    /// Which way the next whale swims (they take turns), and the far lights crossing (x, y in the view, brightness, speed).
    private var whaleHeading: Float = 1
    private var passers: [SIMD4<Float>] = []
    private var passerDebt: Float = 0
    private var trafficRng = SeededRandom(seed: 0x5AB_7AFF)

    private static let layout = KeyboardLayout.keys()

    public init() { passers.reserveCapacity(Self.passerCap) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// The whale `age` seconds into its pass of `life` seconds at `strength` (a drop's is closest): it emerges from the
    /// gloom already across part of the glass, swims on across it, and fades back into the dark beyond the other side.
    public static func whale(age: Float, life: Float, strength: Float, heading: Float, drop: Bool) -> SubWhale {
        let s = min(1, max(0.15, strength.isFinite ? strength : 0.3))
        let p = life > 0 ? min(1, max(0, age / life)) : 1
        let near: Float = drop ? 1 : s
        let half: Float = 0.62 + 0.38 * near
        let x: Float = heading * (-0.55 + 2.2 * p)
        let y: Float = -0.05 + 0.04 * sin(age * 0.35)
        let presence = ExcitementPlay.envelope(age: age, life: life, rise: 0.7, fall: 1.6)
        return SubWhale(centre: SIMD2(x, y), halfLength: half, heading: heading, presence: presence, beat: age * 0.33,
                        distance: 1 - near)
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// The sky under the water's rule (`underwater`).
    public mutating func setSky(_ s: SkyState) { sky = Self.underwater(s) }

    static func clamp01(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }

    // MARK: - The sea and the sky above it

    /// The sky as the submarine has it (spec §8.1): its sun, moon, stars, meteors and weather as they are (Snell's
    /// window shows them, and they drive the light); but no frost forms on the porthole and nothing is rimed under
    /// water, nothing in the cabin drips, there are no fireflies over the open sea, and no aurora (an aurora seen from
    /// under water is out of scope, spec §16).
    public static func underwater(_ s: SkyState) -> SkyState {
        var s = s
        s.frost = 0
        s.rime = 0
        s.wetness = 0
        s.fireflies = 0
        s.aurora = 0
        s.auroraStorm = 0
        return s
    }

    /// The Depth dial made safe: 0…1, the default where it isn't a number.
    static func dial(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0.35 }

    /// The depth (metres) for the Depth dial (0…1): logarithmic from 15 m at 0 to 1,000 m at 1, so equal turns of the
    /// dial multiply the depth alike: 65 m at the default 0.35, 122 m half way, the twilight zone's 200 m at 0.62.
    public static func depthMetres(dial: Double) -> Float {
        let d = Self.dial(dial)
        return Float(shallowest * exp(d * log(deepest / shallowest)))
    }

    /// The shallows: 1 down to 20 m, easing out to nothing by 40 m. Snell's window fades so (the Underwater Kit's own
    /// fade), and the surface's weather shows, and a reef's shrimp and the rain's hiss are heard, only within it.
    public static func shallow(metres: Float) -> Float {
        guard metres.isFinite else { return 0 }
        let t = min(1, max(0, (metres - 20) / 20))
        return 1 - t * t * (3 - 2 * t)
    }

    /// The light falling on the sea's surface (linear RGB, 1 = a noon sun and sky): daylight by the sun's height (a
    /// quarter of noon's as it sets, dimming through dusk to nothing by 12° below, warmer while the sun is low), the
    /// moon's faint cool light by its phase and height (a full moon overhead gives 3% of noon's), the night sky's own
    /// faint glow; cloud dims the sun's by up to 60% and the moon's by 80%.
    public static func surfaceLight(_ s: SkyState) -> SIMD3<Float> {
        let alt: Double = s.sun.altitude.isFinite ? s.sun.altitude : -30
        let up: Double = sin(max(0, alt) * .pi / 180)
        let day: Double = alt >= 0 ? 0.25 + 0.75 * up.squareRoot() : 0.25 * MoonlitLakeModel.smooth(-12, 0, alt)
        let cloud = Double(clamp01(s.cloudCover))
        let warm: Double = 1 - MoonlitLakeModel.smooth(0, 20, alt)
        let sunColour = SIMD3<Float>(1, Float(0.97 - 0.12 * warm), Float(0.93 - 0.3 * warm))
        let moonAlt: Double = s.moon.altitude.isFinite ? s.moon.altitude : -30
        let moonUp: Double = sin(max(0, moonAlt) * .pi / 180)
        let lit: Double = s.moonLit.isFinite ? min(1, max(0, s.moonLit)) : 0
        let moon: Double = moonlight * lit * moonUp * (1 - 0.8 * cloud)
        let sunLight = sunColour * Float(day * (1 - 0.6 * cloud))
        return sunLight + moonColour * Float(moon) + starlight
    }

    /// The share of a noon surface's light that reaches `metres` down (0…1): `surface` through clear ocean, Beer–Lambert
    /// per band (red 0.35, green 0.07, blue 0.03 per metre, the Underwater Kit's), the three averaged; 1.7% of white
    /// light at 100 m (the euphotic zone's "1% at 100 m").
    public static func lightFromAbove(_ surface: SIMD3<Float>, metres: Float) -> Float {
        let m: Float = metres.isFinite ? max(0, metres) : 0
        let through = SIMD3<Float>(exp(-0.35 * m), exp(-0.07 * m), exp(-0.03 * m))
        let l = surface * through
        let mean: Float = (l.x + l.y + l.z) / 3
        return mean.isFinite ? min(1, max(0, mean)) : 0
    }

    /// How rough the surface is from below (0 glassy … 1 a storm): the swell's weather (`OceanSwell.weatherScale`: a
    /// calm 0.25, rain 0.4, a storm with its gusts 1, sea smoke's still air 0.1) and the gusts.
    public static func roughness(_ s: SkyState) -> Float {
        let w = OceanSwell.weatherScale(s)
        let gust = clamp01(s.gust)
        let r: Float = 0.25 * w + 0.5 * max(0, w - 1) + 0.25 * gust
        return r.isFinite ? min(1, max(0, r)) : 0
    }

    /// The cabin's night lighting by ship's time: 0 with the sun above 2° below the horizon … 1 from 8° below.
    public static func cabinNight(_ s: SkyState) -> Float { Float(MoonlitLakeModel.smooth(-2, -8, s.sun.altitude)) }

    /// The sea's current for the marine snow (volume units a second): a slow drift across with the mood's motion, and
    /// in rough shallows the surge rocking it to and fro.
    static func current(mood: Mood, waves: Float, time: Double) -> SIMD3<Float> {
        let drift: Float = 0.012 * MoodLook.driftScale(mood)
        let w = clamp01(waves)
        let surge = Float(sin(2 * Double.pi * time / 7.3))
        let heave = Float(sin(2 * Double.pi * time / 5.1 + 1.3))
        return SIMD3<Float>(drift + 0.03 * w * surge, 0.01 * w * heave, 0)
    }

    // MARK: - The sonar screen

    /// A note's bearing on the sonar screen (radians, clockwise from the top): its pitch class round a 12-tick dial.
    public static func bearing(for note: UInt8) -> Float { 2 * Float.pi * Float(note % 12) / 12 }

    /// How far out a note's blip sits (0…1 of the screen's radius): low notes near the centre, high ones near the rim.
    public static func range(for note: UInt8) -> Float {
        let n = Float(min(108, max(21, note)))
        return 0.2 + 0.75 * (n - 21) / 87
    }

    /// The sweep line's bearing at `t` (radians, clockwise from the top): once round every `sweepPeriod` seconds.
    public static func sweep(at t: Double) -> Float {
        guard t.isFinite else { return 0 }
        var turn = (t / sweepPeriod).truncatingRemainder(dividingBy: 1)
        if turn < 0 { turn += 1 }
        return Float(2 * Double.pi * turn)
    }

    private mutating func leaveBlip(_ note: UInt8, velocity: Float) {
        let v: Float = velocity.isFinite ? min(max(velocity, 0), 1) : 0.7
        if blips.count >= Self.blipCap { blips.removeFirst(blips.count - Self.blipCap + 1) }
        blips.append(SonarBlip(id: nextBlipID, note: note, angle: Self.bearing(for: note), range: Self.range(for: note),
                               strength: 0.3 + 0.7 * v, age: 0))
        nextBlipID = nextBlipID &+ 1
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> SubFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        // Switching visuals lets held notes go: no creature stays lit, no streak waits for a release.
        if let lastVisual, lastVisual != visual { deep.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        deep.pulse = pulse
        deep.reactionScale = MoodLook.reactionScale(mood)
        deep.lingerScale = MoodLook.lingerScale(mood)
        // The sonar's blips age first, so this step's new ones start fresh.
        for i in blips.indices { blips[i].age += Float(fdt) }
        blips.removeAll { $0.age >= Self.blipLife }
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                leaveBlip(note, velocity: velocity)
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (velocity * 127).rounded()))), at: time)
                } else {
                    deep.noteOn(note, velocity: velocity, at: time)
                }
            case let .noteOff(note):
                held[note] = nil
                deep.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                deep.setPedal(down)
            case .allNotesOff:
                // A panic (or an unplugged keyboard) lets the pedal go too: no pedal-up will ever come for it.
                held.removeAll()
                deep.allNotesOff(); deep.setPedal(false)
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        deep.step(dt: fdt, roles: roles)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // Excitement (spec §5.5): Energy brings more far lights crossing and quickens the drift; a moment is a whale
        // passing the porthole; tension gathers the dark (the lamps and the light from above dim); a drop is the whale
        // closest of all. The surprises are drawn by the renderer from their seeds.
        let e = excite
        excite.moment = nil
        excite.surprise = nil
        play.step(dt: fdt, frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        if play.momentBegan != nil { whaleHeading = -whaleHeading }
        var whale: SubWhale?
        if let m = play.moment {
            whale = Self.whale(age: m.age, life: m.duration, strength: m.strength, heading: whaleHeading, drop: m.isDrop)
        }
        stepTraffic(dt: Float(fdt), energy: play.energy)

        // Keys: backlit console buttons, glowing while held, then fading (longer when lingering).
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.2 : 0.35)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        // The sea at the chosen depth, and the sky felt through it.
        let dial = Self.dial(p.number("depth"))
        let metres = Self.depthMetres(dial: dial)
        let shallow = Self.shallow(metres: metres)
        let surface = Self.surfaceLight(sky)
        let waves = Self.roughness(sky) * shallow
        snow.setQuality(quality)
        snow.current = Self.current(mood: mood, waves: waves, time: time) * (1 + 1.2 * play.energy)
        snow.step(dt: fdt)

        // Deep Lights shows nothing (and raises no bubbles) while Galaxy Warp plays.
        let creatures: [DeepCreature] = warping ? [] : deep.creatures
        let shoals: [LanternShoal] = warping ? [] : deep.shoals
        let siphonophores: [Siphonophore] = warping ? [] : deep.siphonophores
        let streams: [BubbleStream] = warping ? [] : deep.bubbleStreams
        let burst: Double? = warping ? nil : deep.burst
        let song = Double(whale?.presence ?? 0)
        let contact: Double = play.surprise(2) != nil ? 1 : 0
        let scene = ambience(roles: roles, dial: dial, shallow: Double(shallow), burst: burst, song: song, contact: contact)
        let cabin = Self.clamp01(Float(p.number("cabin")))
        let screen = Self.clamp01(Float(p.number("sonar")))
        let lamps = Self.clamp01(Float(p.number("lamps")))
        let rain: Float = Self.clamp01(sky.rain) * shallow
        let milky: Float = Self.clamp01(sky.steam) * shallow
        var frame = SubFrame(sky: sky, depth: Float(dial), depthMetres: metres, surfaceLight: surface,
                             lightFromAbove: Self.lightFromAbove(surface, metres: metres), snellVisible: shallow,
                             surfaceWaves: waves, rainOnSurface: rain, milky: milky,
                             creatures: creatures, shoals: shoals, siphonophores: siphonophores, bubbleStreams: streams,
                             sonarBlips: blips, sonarSweep: Self.sweep(at: time), cabinNight: Self.cabinNight(sky),
                             cabinLight: cabin, sonarScreen: screen, lamps: lamps, snow: snow, keys: keys,
                             ambience: scene, mood: mood, time: time, warp: warping ? warpFrame : nil)
        frame.whale = whale
        frame.dark = play.tension
        frame.passers = passers
        frame.energy = play.energy
        frame.surprises = play.surprises
        frame.reduceMotion = play.reduceMotion
        return frame
    }

    /// The far lights crossing the porthole (Energy's traffic): a lanternfish or two far off, each a small light drifting
    /// across the dark, more of them the harder you play (none when nobody is). A fixed pool.
    private mutating func stepTraffic(dt: Float, energy: Float) {
        for i in passers.indices {
            passers[i].x += passers[i].w * dt
            passers[i].z = max(0, passers[i].z - 0.02 * dt)
        }
        passers.removeAll { $0.x < -0.1 || $0.x > 1.1 || $0.z <= 0 }
        passerDebt += (energy > 0.05 ? 0.1 + 0.9 * energy : 0) * dt
        while passerDebt >= 1, passers.count < Self.passerCap {
            passerDebt -= 1
            let right = trafficRng.unit() < 0.5
            let speed = trafficRng.range(0.05, 0.12) * (right ? 1 : -1)
            passers.append(SIMD4(right ? -0.05 : 1.05, trafficRng.range(0.25, 0.8), trafficRng.range(0.25, 0.55), speed))
        }
        if passerDebt > 1 { passerDebt = 1 }
    }

    /// What the submarine hears (spec §5, §8.1): its machinery (the hum, the scrubbers' air, the hull's ticks); the hull
    /// settling under the pressure, creaking more the deeper it dives; the sonar's ping (in your key: the canvas hands
    /// every scene the key); a humpback far off all year, strongest at mid-depth (through the hull, quieter than on the
    /// reef); a low bed of bubbles, so an accent's burst can sound; and only in the shallows, a reef's snapping shrimp
    /// and the rain's soft hiss on the surface above (`rainOnWater`, muffled by the hull). Then `WeatherAmbience`, as
    /// every world has it, though none of the air's sounds it may add reach the submarine; nor does thunder. Everything
    /// outside comes through the hull a little muffled (indoors 0.85).
    private func ambience(roles: RoleValues, dial d: Double, shallow: Double, burst: Double?, song: Double = 0,
                          contact: Double = 0) -> AmbienceScene {
        let rain = Double(Self.clamp01(sky.rain))
        let rise = 1 - d
        let midDepth = 1 - abs(d - 0.5) * 2
        var levels: [AmbienceSource: Double] = [
            .shipHum: 0.35,
            .airFlow: 0.3,
            .hullTicks: 0.15,
            .hullCreak: 0.25 + 0.35 * d,
            .sonar: 0.5 + 0.25 * contact,
            .whaleSong: min(1, 0.2 + 0.15 * midDepth + 0.45 * song),
            .bubbles: 0.5,   // a burst near −36 dBFS through the hull (at 0.15 it was −50: lost)
            .snappingShrimp: 0.3 * rise * rise * shallow,
            .rainOnWater: rain * rise * 0.5 * shallow,
        ]
        WeatherAmbience.levels(sky, base: &levels)
        var heard: [AmbienceSource: Double] = [:]
        for (source, level) in levels where Self.heardAboard.contains(source) {
            heard[source] = level.isFinite ? min(1, max(0, level)) : 0
        }
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: heard, nightCool: 0, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.7, mood), density: MoodLook.ambienceDensity(mood),
                             indoors: Self.indoors, wetness: 0, bubbleBurst: burst)
    }
}

extension SubmarineWindowModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    /// No aurora or meteor mode here (spec §8.1): Snell's window shows the sky's own meteors.
    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing brings to the porthole",
                  kind: .choice(visuals), defaultValue: .choice("Deep Lights")),
        SkyHold.spec(default: .follow),
        slider("depth", "Depth", "Submarine", 0...1, 0.35, hero: true, surprise: 0...0.85,
               help: "How deep the submarine dives: from the sunlit shallows (15 m) through the twilight zone (from 200 m) to the midnight zone (1,000 m)"),
        slider("lamps", "Outside lamps", "Submarine", 0...1, 0.35, surprise: 0.1...0.8,
               help: "Warm-white floodlights outside the hull, lighting a cone of marine snow and the nearest creatures"),
        slider("cabin", "Cabin light", "Cabin", 0...1, 0.5, surprise: 0.2...0.8,
               help: "The cabin's own light: a dim, cool white by day and red night lighting after dark"),
        slider("sonar", "Sonar screen", "Cabin", 0...1, 0.6, surprise: 0.2...1,
               help: "The small round sonar screen: its sweep, and the blips your notes leave on it"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A row of backlit console buttons along the bottom",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("lamps", 0.6)],
        .speed: [],
        .density: [],
        .glow: [("lamps", 0.8), ("cabin", 0.5), ("sonar", 0.5)],
        .chaos: [],
        .temperature: [("cabin", 0.4)],
    ]
}
