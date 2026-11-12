import Foundation
import simd

/// Everything the Golden Hour Beach renderer needs for a frame.
public struct BeachFrame: AmbienceProviding {
    public var sky: SkyState
    public var lines: [TideLine]
    /// Golden foam on the latest break (from chords), 0…1.
    public var foam: Float
    /// The swell's four component phases (wrapped, for the shaders).
    public var swellPhases: SIMD4<Float>
    /// The next waves to break and the last few that did.
    public var upcoming: [Wave]
    public var recent: [Wave]
    /// How far up the sand the wash reaches now (0 waterline … 1 top of the wet sand).
    public var washFront: Float
    public var swellScale: Float
    public var swellTime: Double
    /// 0…1: how much the sun (or moon) path sparkles.
    public var glitter: Float
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the beach's sky, when it's the chosen visual (notes then streak instead of writing).
    public var warp: WarpFrame?

    // Excitement as the beach draws it (Fire & Neon spec §5.5).
    /// The fireworks in the air (climbing or bursting) and the gulls over the sea.
    public var fireworks: [FireworkShell] = []
    public var gulls: [Gull] = []
    /// The surprises: the dolphins of a pod breaking the surface now, a kite, a green flash on the sun's last sliver.
    public var dolphins: [Dolphin] = []
    public var kite: BeachKite? = nil
    public var greenFlash: Float = 0
    public var surprises: [BeachSurprise] = []
    /// The fireworks' light on the beach (0…1, before the renderer's flash limiter).
    public var flashRequest: Float = 0
    /// Tension: how much the swell has built (0…1).
    public var swellBuild: Float = 0
    public var energy: Float = 0
    public var tension: Float = 0
}

/// One firework shell (Fire & Neon spec §5.5): fired from a barge out on the open sea, it climbs on a faint spark trail
/// and bursts into stars that spread, droop and fall away as embers. Metres in the beach's own frame, from the camera's foot on the
/// sand: across (+ right), out to sea (+ away), up.
public struct FireworkShell: Equatable {
    public enum Kind: Int, CaseIterable { case peony, chrysanthemum, willow }
    public var kind: Kind
    public var launch: SIMD3<Float>
    public var burst: SIMD3<Float>
    /// Seconds since it was fired: it climbs for `rise` s, then its stars live `life` s.
    public var age: Float
    public var rise: Float
    public var life: Float
    /// How fast its stars leave the burst (m/s), how hard the air slows them (per second) and how many there are.
    public var speed: Float
    public var drag: Float
    public var stars: Int
    /// Its colour (a hue 0…1, or −1 for silver) and a second for the stars' ends (the same for one colour), and how
    /// bright it is (0…1).
    public var hue: Float
    public var hue2: Float
    public var brightness: Float
    public var seed: UInt32

    /// The most stars a shell has (the renderer's pool is sized by it).
    public static let mostStars = 48
    /// Seconds since it burst (negative while it climbs).
    public var sinceBurst: Float { age - rise }
    public var done: Bool { age >= rise + life }
}

/// A gull soaring over the sea (Energy brings them out by day): metres in the beach's frame, its heading (radians on the
/// sea, 0 out to sea), its wings (−1 down … 1 up; a glide is a little above level) and how much of it shows (0…1).
public struct Gull: Equatable {
    public var position: SIMD3<Float>
    public var heading: Float
    public var wing: Float
    public var alpha: Float
}

/// A dolphin of the pod breaking the surface (a surprise): where (metres in the beach's frame, at the water), which way
/// it swims along the shore (−1 left, +1 right), its length (m) and how far through the roll it is (0 its head breaks
/// the water … 1 its tail is under).
public struct Dolphin: Equatable {
    public var position: SIMD3<Float>
    public var heading: Float
    public var length: Float
    public var roll: Float
}

/// A kite flown from the sand off to the right (a surprise): where (metres in the beach's frame), its tilt (radians), its
/// tail's wave phase and how much of it shows (0…1).
public struct BeachKite: Equatable {
    public var position: SIMD3<Float>
    public var tilt: Float
    public var tail: Float
    public var alpha: Float
}

/// A beach surprise playing now (Fire & Neon spec §5.5): a dolphin pod, a kite, a green flash as the sun's last sliver
/// sets or first rises (the pod instead while the sun is anywhere else).
public struct BeachSurprise: Equatable {
    public enum Kind: Int, CaseIterable { case dolphins, kite, greenFlash }
    public var kind: Kind
    public var age: Float
    public var duration: Float
    public var seed: UInt64

    public static func duration(_ k: Kind) -> Float {
        switch k {
        case .dolphins: return 15
        case .kite: return 24
        case .greenFlash: return 2.8
        }
    }
    public var progress: Float { min(1, max(0, age / max(duration, 1e-3))) }
}

/// Set 3's world: a wide beach at the waterline facing a low sun, long swells breaking softly, the wash sliding
/// up the sand. Its visual, Tide Lines, writes your notes into the wet sand for the tide to erase.
public struct GoldenHourBeachModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, SurpriseListing {
    public typealias Frame = BeachFrame
    public static let id = "golden-hour-beach"
    public static let displayName = "Golden Hour Beach"
    public static let visuals = ["Tide Lines", "Galaxy Warp"]
    /// A dolphin pod, a kite, a green flash at sunset (Fire & Neon spec §5.5).
    public static let surpriseCount = BeachSurprise.Kind.allCases.count
    /// The fixed pools: the shells in the air at once (a moment fires 3–9), the gulls, a pod's dolphins.
    public static let shellCount = 9, gullCount = 5, podMost = 5
    /// The sun's drawn radius (degrees, before the sky's sun size): its last sliver is what turns green.
    public static let sunRadius: Float = 0.9

    public var mood = Mood.neutral
    private var sky = SkyState()
    private var swell = OceanSwell(seed: 0xBEAC4)
    private var tide = TideLines()
    private var warp = GalaxyWarp()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var pedal = false
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var glitter: Float = 0
    private var time = 0.0
    private var lastLightning: Float = 0
    private var thunderRng = SeededRandom(seed: 0xBEAC)

    // Excitement (Fire & Neon spec §5.5): fixed pools throughout.
    private var excite = ExcitementFrame()
    private var rng = SeededRandom(seed: 0xF1_2E_B0)
    private var shells = [FireworkShell?](repeating: nil, count: GoldenHourBeachModel.shellCount)
    private var gullStates = [GullState](repeating: GullState(), count: GoldenHourBeachModel.gullCount)
    private var pod = [PodMember?](repeating: nil, count: GoldenHourBeachModel.podMost)
    private var podHeading: Float = 1
    private var surprises: [BeachSurprise?] = [nil, nil, nil]
    private var energyEased: Float = 0
    private var gather: Float = 0
    /// The drop's big wave: when it breaks, its calm strength before and after, and how far its crest has grown.
    private var surge: (breakTime: Double, from: Float, to: Float)?
    private var surgeShown: Float = 0

    private struct GullState {
        var centre = SIMD3<Float>(0, 90, 25)
        var radius: Float = 30
        var spin: Float = 0.12
        var angle: Float = 0
        var flapClock: Float = 3
        var flapping: Float = 0
        var alpha: Float = 0
    }
    private struct PodMember {
        var lane: Float
        var offset: Float
        var phase: Float
        var length: Float
    }

    private static let layout = KeyboardLayout.keys()

    public init() {
        var r = SeededRandom(seed: 0x6011_5EA)
        for i in gullStates.indices {
            gullStates[i].centre = SIMD3(r.range(-70, 70), r.range(55, 160), r.range(12, 38))
            gullStates[i].radius = r.range(15, 40)
            gullStates[i].spin = (r.unit() < 0.5 ? -1 : 1) * r.range(0.08, 0.16)
            gullStates[i].angle = r.range(0, 2 * .pi)
            gullStates[i].flapClock = r.range(1, 7)
        }
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    public mutating func setSky(_ s: SkyState) { sky = s }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> BeachFrame {
        time += dt
        tide.glow = Float(p.number("lines.glow"))
        tide.linger = Float(p.number("lines.linger"))
        tide.foamAmount = Float(p.number("foam"))
        tide.reactionScale = MoodLook.reactionScale(mood)
        tide.lingerScale = MoodLook.lingerScale(mood)
        let warping = p.choice("visual") == "Galaxy Warp"
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                held[note] = velocity
                let v = UInt8(min(127, max(0, (velocity * 127).rounded())))
                if warping { warp.noteOn(note, velocity: v, at: time) } else { tide.noteOn(note, velocity: v, pedal: pedal, at: time) }
            case let .noteOff(note):
                held[note] = nil
                tide.noteOff(note)
                warp.noteOff(note)
            case let .pedal(down, _):
                pedal = down
            case .allNotesOff:
                held.removeAll()
                tide.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)

        // Excitement (Fire & Neon spec §5.5): Energy raises the surf and brings the gulls out; tension builds the swell.
        let x = ExcitementStep.take(&excite)
        let fd = Float(max(0, dt.isFinite ? dt : 0))
        energyEased = ExcitementStep.ease(energyEased, to: x.energy, tau: x.energy > energyEased ? 1.5 : 5, dt: fd)
        gather = ExcitementStep.ease(gather, to: x.tension, tau: x.tension > gather ? 2 : 4, dt: fd)
        swell.scale = OceanSwell.weatherScale(sky) * (1 + 0.35 * energyEased) * (1 + 0.6 * gather)
        stepExcitement(x, dt: fd)
        let breaks = swell.step(dt: dt)
        if let s = surge, swell.time > s.breakTime + 1 { surge = nil; surgeShown = 0 }
        let front = swell.washFront(at: swell.time)
        tide.step(dt: dt, washFront: front, breaks: breaks, roles: roles)
        let warpFrame = warp.step(dt: dt, roles: roles, inputs: inputs)
        let target = min(1, Float(held.count) / 4)
        glitter += (target - glitter) * (1 - exp(-Float(dt) / 0.35))

        // Keys glow golden amber while held, then fade (longer when lingering).
        let fall = Float(pow(0.5, dt / (roles[.linger] > 0.5 ? 1.2 : 0.3)))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.7) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        // The drop's big wave grows as its crest rolls in (never popping up).
        var upcoming = swell.upcoming(3)
        if let s = surge, let i = upcoming.firstIndex(where: { $0.breakTime == s.breakTime }) {
            let calm = s.from + (s.to - s.from) * surgeShown
            upcoming[i].strength = min(1, calm * swell.scale)
        }
        var frame = BeachFrame(sky: sky, lines: tide.lines, foam: tide.foam, swellPhases: swell.phases(at: swell.time),
                               upcoming: upcoming, recent: swell.recent, washFront: front, swellScale: swell.scale,
                               swellTime: swell.time, glitter: glitter, keys: keys,
                               ambience: ambience(roles: roles, params: p, breaks: breaks), mood: mood, time: time,
                               warp: warping ? warpFrame : nil)
        var flying: [FireworkShell] = []
        for case let sh? in shells where sh.age >= 0 && !sh.done { flying.append(sh) }
        frame.fireworks = flying
        frame.gulls = gulls()
        frame.dolphins = dolphins()
        frame.kite = kite()
        frame.greenFlash = greenFlash()
        frame.surprises = surprises.compactMap { $0 }
        frame.flashRequest = fireworkLight()
        frame.swellBuild = gather
        frame.energy = x.energy
        frame.tension = x.tension
        return frame
    }

    // MARK: - Excitement (Fire & Neon spec §5.5)

    private mutating func stepExcitement(_ x: ExcitementStep, dt fd: Float) {
        // A big moment: fireworks down the beach. The drop: the next wave rolls in big.
        if let m = x.moment {
            fireworks(strength: ExcitementStep.strength(m), gentle: x.gentle)
            if m.isDrop, surge == nil, let was = swell.surge(strength: 1.2, after: 2) {
                surge = (was.breakTime, was.strength, max(was.strength, 1.2))
                surgeShown = 0
            }
        }
        if surge != nil { surgeShown = ExcitementStep.ease(surgeShown, to: 1, tau: 0.9, dt: fd) }
        for i in shells.indices {
            guard var sh = shells[i] else { continue }
            sh.age += fd
            shells[i] = sh.done ? nil : sh
        }

        // The gulls: as many as Energy asks for by day (none at night), each soaring its own slow loop.
        let day = sky.sun.altitude > -2
        let wanted = day ? Int((Float(Self.gullCount) * energyEased).rounded()) : 0
        for i in gullStates.indices {
            var g = gullStates[i]
            g.alpha = ExcitementStep.ease(g.alpha, to: i < wanted ? 1 : 0, tau: 2, dt: fd)
            g.angle += g.spin * fd
            if g.angle > 2 * .pi { g.angle -= 2 * .pi } else if g.angle < 0 { g.angle += 2 * .pi }
            g.flapClock -= fd
            if g.flapClock <= 0 {
                g.flapping = rng.range(0.8, 1.6)
                g.flapClock = g.flapping + rng.range(3, 8)
            }
            g.flapping = max(0, g.flapping - fd)
            gullStates[i] = g
        }

        // Surprises.
        if let sp = x.surprise { surprised(sp) }
        for i in surprises.indices {
            guard var sp = surprises[i] else { continue }
            sp.age += fd
            if sp.age >= sp.duration {
                surprises[i] = nil
                if sp.kind == .dolphins { for k in pod.indices { pod[k] = nil } }
            } else {
                surprises[i] = sp
            }
        }
    }

    /// 3–9 shells by the moment's strength, fired in a quick run from barges 600–800 m out over the open sea, clear of
    /// the palms and the headland (across the middle of the view, in the camera's frame: from a quarter of the
    /// view's half width left of centre to a third right of it): the first a low one that bursts at once, the rest higher, a third of a second or
    /// so apart, in a few colours. Big shells: their stars spread 100–130 m before the air stops them (gentle visuals:
    /// the same shells, their light only a glow in the renderer).
    private mutating func fireworks(strength s: Float, gentle: Bool) {
        let count = min(Self.shellCount, 3 + Int(((s - 0.15) / 0.85 * 6).rounded()))
        let palette: [Float] = [0.0, 0.09, 0.14, 0.33, 0.58, 0.76, -1]
        var delay: Float = 0
        var fired = 0
        for i in shells.indices where shells[i] == nil && fired < count {
            let first = fired == 0
            let kind: FireworkShell.Kind = first ? .peony : (rng.unit() < 0.25 ? .willow : (rng.unit() < 0.5 ? .chrysanthemum : .peony))
            let up: Float = first ? 115 : rng.range(140, 220)
            let out = rng.range(600, 800)
            let burst = SIMD3<Float>(out * rng.range(-0.24, 0.34), out, up)
            let launch = SIMD3<Float>(burst.x + rng.range(-12, 12), out - rng.range(0, 25), 1)
            let rise: Float = first ? 0.32 : 1.0 + (up - 140) / 80 * 0.5
            let hue = palette[Int(rng.unit() * Float(palette.count)) % palette.count]
            let two = rng.unit() < 0.35 ? palette[Int(rng.unit() * Float(palette.count)) % palette.count] : hue
            let life: Float, speed: Float, drag: Float, stars: Int
            switch kind {
            case .peony: life = 2.3; speed = rng.range(150, 185); drag = 1.45; stars = 36
            case .chrysanthemum: life = 2.7; speed = rng.range(160, 195); drag = 1.5; stars = 46
            case .willow: life = 3.6; speed = 120; drag = 2.0; stars = 34
            }
            shells[i] = FireworkShell(kind: kind, launch: launch, burst: burst, age: -delay, rise: rise, life: life,
                                      speed: speed, drag: drag, stars: min(stars, FireworkShell.mostStars),
                                      hue: kind == .willow ? 0.1 : hue, hue2: kind == .willow ? 0.1 : two,
                                      brightness: (0.65 + 0.35 * s) * (gentle ? 0.8 : 1), seed: UInt32(truncatingIfNeeded: rng.next()))
            fired += 1
            delay += first ? 0.15 : rng.range(0.2, 0.45)
        }
    }

    /// The bursts' light on the beach: each a quick bright onset fading over a quarter of a second.
    private func fireworkLight() -> Float {
        var light: Float = 0
        for case let sh? in shells where sh.age >= 0 {
            let since = sh.sinceBurst
            guard since >= 0, since < 1 else { continue }
            light = max(light, 0.28 * sh.brightness * exp(-since / 0.25))
        }
        return min(1, light)
    }

    private func gulls() -> [Gull] {
        var out: [Gull] = []
        for g in gullStates where g.alpha > 0.01 {
            let p = g.centre + SIMD3<Float>(g.radius * cos(g.angle), 0.6 * g.radius * sin(g.angle), 2 * sin(g.angle * 2.3))
            let heading = g.angle + (g.spin > 0 ? 1 : -1) * .pi / 2
            let wing: Float = g.flapping > 0 ? sin(g.flapping * 2 * .pi * 3) : 0.22
            out.append(Gull(position: p, heading: heading, wing: wing, alpha: g.alpha))
        }
        return out
    }

    private func dolphins() -> [Dolphin] {
        guard let sp = surprises.first(where: { $0?.kind == .dolphins }) ?? nil else { return [] }
        var out: [Dolphin] = []
        let start: Float = -podHeading * 78
        for case let m? in pod {
            let along = start + podHeading * (7 * sp.age + m.offset)
            let cycle = (sp.age + m.phase).truncatingRemainder(dividingBy: 3.0)
            let roll = cycle / 1.1
            guard roll < 1, sp.age + m.phase > 0.4, sp.age < sp.duration - 0.6 else { continue }
            out.append(Dolphin(position: SIMD3(along, m.lane, 0), heading: podHeading, length: m.length, roll: roll))
        }
        return out
    }

    private func kite() -> BeachKite? {
        guard let sp = surprises.first(where: { $0?.kind == .kite }) ?? nil else { return nil }
        let t = sp.age, end = sp.duration
        func s(_ x: Float) -> Float { let u = min(1, max(0, x)); return u * u * (3 - 2 * u) }
        let enter = s(t / 4), leave = s((t - (end - 4)) / 4)
        let hover = SIMD3<Float>(16 + 7 * sin(0.45 * t), 34 + 3 * sin(0.2 * t), 20 + 5 * sin(0.6 * t + 1) + 2.5 * sin(1.7 * t))
        let from = SIMD3<Float>(75, 40, 28), away = SIMD3<Float>(95, 45, 42)
        var p = from + (hover - from) * enter
        p += (away - hover) * leave
        let alpha = min(1, t / 0.6) * min(1, (end - t) / 0.6)
        return BeachKite(position: p, tilt: 0.22 * sin(0.9 * t) + 0.05 * sin(5.3 * t), tail: t * 6, alpha: max(0, alpha))
    }

    private func greenFlash() -> Float {
        guard let sp = surprises.first(where: { $0?.kind == .greenFlash }) ?? nil else { return 0 }
        return ExcitementStep.envelope(age: sp.age, life: sp.duration, rise: 0.35, fall: 0.9)
    }

    /// The sun's upper limb sits on the horizon (setting or rising): the only time a green flash is seen.
    public static func sunOnTheHorizon(_ s: SkyState) -> Bool {
        let r = Double(sunRadius * (s.sunSize.isFinite ? min(3, max(0.5, s.sunSize)) : 1))
        let top = s.sun.altitude + r
        return top > -0.05 && top < 0.6 * r
    }

    private mutating func surprised(_ s: WorldSurprise) {
        guard var kind = BeachSurprise.Kind(rawValue: s.index) else { return }
        if kind == .greenFlash, !Self.sunOnTheHorizon(sky) { kind = .dolphins }
        guard !surprises.contains(where: { $0?.kind == kind }) else { return }
        var r = SeededRandom(seed: s.seed)
        if kind == .dolphins {
            podHeading = r.unit() < 0.5 ? -1 : 1
            let n = 3 + Int(r.unit() * 2.99)
            for k in pod.indices {
                pod[k] = k < n ? PodMember(lane: r.range(70, 110), offset: -Float(k) * r.range(4, 9), phase: r.range(-1.5, 1.5),
                                           length: r.range(2.1, 2.7)) : nil
            }
        }
        let record = BeachSurprise(kind: kind, age: 0, duration: BeachSurprise.duration(kind), seed: s.seed)
        if let free = surprises.firstIndex(where: { $0 == nil }) { surprises[free] = record }
    }

    /// The beach's soundscape: surf in step with the waves, fronds in the wind, gulls by day, crickets at dusk.
    private mutating func ambience(roles: RoleValues, params p: ParameterSet, breaks: [Wave]) -> AmbienceScene {
        let sunAlt = sky.sun.altitude
        let night = MoonlitLakeModel.smooth(-3, -9, sunAlt)
        let day = MoonlitLakeModel.smooth(-4, 2, sunAlt)
        let wind = Double(sky.wind)
        var levels: [AmbienceSource: Double] = [
            .surf: 0.9,
            .palms: min(1, 0.25 + wind) * p.number("palms"),
            .gulls: p.number("gulls") * day * Double(0.5 + energyEased),   // Energy brings them out (still off by default)
            .crickets: 0.6 * night,
            .breeze: min(1, 0.3 + wind),
            .rainOnWater: Double(sky.rain),
        ]
        if sky.wind > 0.6 { levels[.wind] = Double(sky.wind - 0.6) * 2 }
        WeatherAmbience.levels(sky, base: &levels)
        let sinceDusk = (sky.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        var thunder: Double?
        if sky.lightning > 0.9, lastLightning <= 0.9 { thunder = Double(thunderRng.range(0.15, 0.9)) }
        lastLightning = sky.lightning
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        let wave = breaks.map { Double($0.strength) }.max()
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: thunder,
                             closeness: MoodLook.ambienceCloseness(base: 0.5, mood), density: MoodLook.ambienceDensity(mood),
                             wave: wave, speed: 0, surfDistance: 0.15, indoors: WeatherAmbience.indoorsLift(sky), wetness: Double(sky.wetness))
    }
}

extension GoldenHourBeachModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws on the beach",
                  kind: .choice(visuals), defaultValue: .choice("Tide Lines")),
        SkyHold.spec(default: .goldenHour),
        MeteorMode.spec(default: .follow),
        slider("lines.glow", "Line glow", "Tide Lines", 0...1, 0.6, hero: true, surprise: 0.2...1,
               help: "How brightly each note's line glows in the wet sand"),
        slider("lines.linger", "Lines linger", "Tide Lines", 0...1, 0.5, hero: true, surprise: 0.2...0.9,
               help: "How long a released note's line keeps glowing before it fades"),
        slider("foam", "Foam from chords", "Tide Lines", 0...1, 0.6, surprise: 0.2...1,
               help: "Chords make the next wave break in golden foam"),
        slider("glitter", "Sun path glitter", "Beach", 0...1, 0.7, hero: true, surprise: 0.3...1,
               help: "How much the sun's (or moon's) path sparkles while you hold notes"),
        slider("haze", "Haze", "Beach", 0...1, 0.4, surprise: 0...0.8, help: "Warm haze over the sea"),
        slider("palms", "Palms", "Beach", 0...1, 0.7, surprise: 0...1, help: "Palms swaying at the edges"),
        slider("gulls", "Gulls", "Beach", 0...1, 0, help: "Distant gulls by day (off until they pass your ear test)"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A keyboard along the sand",
                  kind: .toggle, defaultValue: .bool(true)),
        slider("keys.height", "Keyboard height", "Keys", 0.06...0.3, 0.12, help: "How tall the keyboard is"),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("lines.glow", 0.8), ("glitter", 0.6)],
        .speed: [],
        .density: [("foam", 0.8), ("palms", 0.5)],
        .glow: [("glitter", 1), ("lines.glow", 0.5)],
        .chaos: [("foam", 0.4)],
        .temperature: [],
    ]
}
