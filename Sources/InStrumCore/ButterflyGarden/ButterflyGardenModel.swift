import Foundation
import simd

public struct Butterfly: Equatable {
    /// Stable identity for the butterfly's lifetime (used for trails).
    public var id: Int
    /// x 0...1 across, y 0...1 up, z depth 0 near ... 1 far.
    public var position: SIMD3<Float>
    public var size: Float
    public var hue: Float
    public var flapPhase: Float
    /// Wing beats per second (after pedal/linger).
    public var flapRate: Float
    public var style: Int
    public var glow: Float
    public var landed: Bool
    public var homeNote: UInt8?
    /// 0...1 fade in/out.
    public var opacity: Float
}

public struct Bloom: Equatable {
    public var x: Float
    public var openness: Float
    public var hue: Float
    public var age: Float
    public var kind: Int
}

public struct GardenFrame {
    public var butterflies: [Butterfly]
    public var blooms: [Bloom]
    public var keys: [KeyVisual]
    public var sunHeight: Float
    public var rays: Float
    public var mist: Float
    public var breeze: SIMD2<Float>
    public var pollen: Float
    public var petals: Float
    public var fireflies: Float
    /// -1 cool ... +1 warm.
    public var warmth: Float
    public var exposure: Float
    public var spiral: Float
    public var cameraZoom: Float
    public var cameraOffset: SIMD2<Float>
    public var timeOfDay: String
    public var time: Double
    /// Excitement (Fire & Neon spec §5.5): the swarm taking off (0…1 as it rises and spirals), the bloom of light with it
    /// (0…1 × the moment's strength, before the flash limiter), the light gathering with tension (0…1), and the surprises:
    /// a hummingbird (where it is: x, y, depth, and its heading ±1; and its wings' phase) and rain on the glasshouse's glass
    /// (0…1).
    public var swarm: Float = 0
    public var momentLight: Float = 0
    public var gather: Float = 0
    public var hummingbird: SIMD4<Float>? = nil
    public var hummingbirdWing: Float = 0
    public var rainOnGlass: Float = 0
    public var surprises: [PlayingSurprise] = []
    public var reduceMotion = false
}

/// Butterflies born from your notes, hovering on held keys, spiralling on chords,
/// landing on flowers in silence.
public struct ButterflyGardenModel: ThemeModel, ExcitementAware, SurpriseListing {
    public typealias Frame = GardenFrame
    public static let id = "butterfly-garden"
    public static let displayName = "Butterfly Garden"
    /// The surprises (spec §5.5): a hummingbird, rain on the glass.
    public static let surpriseCount = 2
    public static let surpriseSeconds: [Float] = [9, 14]
    /// A swarm takes off (spec §5.5): it rises and spirals for this long (a drop's, the bloom, longer).
    public static let momentSeconds: Float = 4, dropSeconds: Float = 5
    /// The most butterflies a swarm adds (at full strength), within the quality's cap.
    public static let swarmCap = 36

    static let qualityCap: [QualityLevel: Int] = [.lite: 200, .high: 600, .ultra: 1200]
    static let silenceToLand = 4.0
    static let maxBlooms = 120
    /// While time is held (a step of dt 0) a butterfly born since the last step starts this old, faded in (it fades in
    /// over 0.25 s), and a flower planted since then this open, at full opacity (from a third open): else neither would
    /// show.
    public static let bloomAge: Float = 0.25
    public static let flowerBloomOpenness: Float = 1.0 / 3

    private static let layout = KeyboardLayout.keys()
    private static let centres: [Float] = (21...108).map { n in
        let k = KeyboardLayout.key(for: UInt8(n))!; return k.x + k.width / 2
    }

    /// Settings read once per frame (not per note).
    private struct Cfg {
        var sizeMin: Float, sizeMax: Float, colorSource: String, wingStyle: String, wingMix: Float
        var landOnHeld: Bool, flutter: Float, lifespan: Float, minVelocity: Float, spawnRate: Double
        var chordSpiral: Float, flowerKind: Int
        init(_ p: ParameterSet) {
            sizeMin = Float(p.number("size.min")); sizeMax = Float(p.number("size.max"))
            colorSource = p.choice("color.source"); wingStyle = p.choice("wings.style"); wingMix = Float(p.number("wings.mix"))
            landOnHeld = p.number("land.onHeld") > 0.5; flutter = Float(p.number("flutter.speed"))
            lifespan = Float(p.number("lifespan")); minVelocity = Float(p.number("spawn.minVelocity"))
            spawnRate = p.number("spawn.rate"); chordSpiral = Float(p.number("chord.spiral"))
            flowerKind = ["Mixed", "Roses", "Poppies", "Lotus", "Wildflowers", "Cherry Blossom"].firstIndex(of: p.choice("flowers.types")) ?? 0
        }
    }

    private struct Flyer {
        var b: Butterfly
        var velocity: SIMD3<Float>
        var baseFlap: Float
        var age: Float = 0
        var lifespan: Float
        var hoverHeight: Float
        var seed: Float
        var serial: Int
    }

    private var flyers: [Flyer] = []
    private var blooms: [Bloom] = []
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var spiral: Float = 0
    private var spiralCentre: Float = 0.5
    private var chordHue: Float = 0.1
    private var sinceNote: Double = 1000
    private var spawnBudget: Double = 1
    private var rng = SeededRandom(seed: 42)
    private var time: Double = 0
    private var serial = 0
    private var melodyX: Float = 0.5
    /// note → index of the butterfly hovering over it.
    private var hovering: [UInt8: Int] = [:]
    private var lastCap = 600
    private var excite = ExcitementFrame()
    private var play = ExcitementPlay()

    public init() {}

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    /// The hummingbird `age` seconds into its visit `life` long (seed numbers `a`, `b`): darting in from a side, hovering
    /// at a flower with small bobs, darting away; x, y (scene units), depth, and its heading ±1.
    public static func hummingbird(age: Float, life: Float, a: Float, b: Float) -> SIMD4<Float> {
        let side: Float = a < 0.5 ? -1 : 1
        let hoverX: Float = 0.3 + 0.4 * b
        let hoverY: Float = 0.42 + 0.12 * a
        let arrive = ExcitementPlay.smooth(0, 1.1, age)
        let leave = ExcitementPlay.smooth(life - 1.4, life, age)
        let startX: Float = side < 0 ? -0.1 : 1.1
        let endX: Float = side < 0 ? 1.15 : -0.15
        var x = startX + (hoverX - startX) * arrive
        x += (endX - hoverX) * leave
        let bob: Float = 0.012 * sin(age * 5.3) + 0.006 * sin(age * 11.7 + 1.1)
        let dart: Float = 0.03 * ExcitementPlay.smooth(3, 3.3, age) * (1 - ExcitementPlay.smooth(5, 5.3, age))
        let y = hoverY + bob + dart + 0.15 * leave
        let heading: Float = leave > 0.05 ? -side : side
        return SIMD4(x, y, 0.35, heading)
    }

    private static func keyCentre(_ note: UInt8) -> Float? {
        (21...108).contains(note) ? centres[Int(note) - 21] : nil
    }

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> GardenFrame {
        let fdt = Float(dt)
        time += dt
        if !pending.isEmpty {
            let cfg = Cfg(p)
            lastCap = min(Int(p.number("butterflies.max")), Self.qualityCap[quality] ?? 600)
            for e in pending { apply(e, cfg: cfg, roles: roles) }
        }
        pending.removeAll(keepingCapacity: true)
        sinceNote += dt

        // Excitement (spec §5.5): a moment is a swarm taking off (every free butterfly lifts and spirals up, and more rise
        // from the flowers) with a bloom of light; tension gathers the light and draws the butterflies in; a drop opens
        // every flower at once. Energy plays through the existing reactions.
        let e = excite
        excite.moment = nil
        excite.surprise = nil
        play.step(dt: dt, frame: e, momentSeconds: Self.momentSeconds, dropSeconds: Self.dropSeconds,
                  surpriseSeconds: Self.surpriseSeconds)
        var swarm: Float = 0, momentLight: Float = 0
        var dropping = false
        if let m = play.moment {
            swarm = (1 - ExcitementPlay.smooth(0.55 * m.duration, m.duration, m.age)) * m.strength
            momentLight = ExcitementPlay.envelope(age: m.age, life: m.duration, rise: 0.25, fall: 2.5) * m.strength
                * (m.isDrop ? 1 : 0.6)
            dropping = m.isDrop
        }
        if let m = play.momentBegan { takeOff(strength: m.strength, cfg: Cfg(p)) }
        let gather = play.tension

        let linger = Float(roles[.linger]), motion = Float(roles[.motion]), chaos = Float(roles[.chaos])
        let direction = Float(roles[.direction]), energy = Float(roles[.energy])
        let flocking = Float(p.number("flocking")), breezeStrength = Float(p.number("breeze.strength"))
        let breeze = SIMD2<Float>(Float(p.number("breeze.direction")) * breezeStrength + 0.3 * direction, 0.02 * breezeStrength)
        let landing = sinceNote >= Self.silenceToLand && held.isEmpty && swarm < 0.02
        let lifespan = Float(p.number("lifespan"))

        // Butterflies
        lastCap = min(Int(p.number("butterflies.max")), Self.qualityCap[quality] ?? 600)
        trim(to: lastCap)
        spiral *= Float(pow(0.5, dt / 0.8))
        let flapScale = (1 - 0.6 * linger) * (0.85 + 0.3 * motion)
        for i in flyers.indices {
            var f = flyers[i]
            f.age += fdt
            if fdt == 0, f.age == 0 { f.age = Self.bloomAge }
            f.b.flapRate = f.baseFlap * flapScale * (f.b.landed ? 0.1 : 1)
            f.b.flapPhase = (f.b.flapPhase + f.b.flapRate * fdt).truncatingRemainder(dividingBy: 1)
            if let note = f.b.homeNote, held[note] != nil, let x = Self.keyCentre(note) {
                f.b.landed = false
                let target = SIMD3<Float>(x + 0.004 * sin(Float(time) * 2 + f.seed * 6), f.hoverHeight, f.b.position.z)
                f.b.position += (target - f.b.position) * min(1, fdt * 4)
                f.velocity = .zero
            } else if landing {
                f.b.landed = true
                let groundY: Float = 0.1 + 0.03 * f.seed
                let tx = blooms.isEmpty ? f.b.position.x : blooms[Int(f.seed * Float(blooms.count)) % blooms.count].x
                f.b.position += (SIMD3<Float>(tx, groundY, f.b.position.z) - f.b.position) * min(1, fdt * 0.8)
                f.velocity *= 0.9
            } else {
                f.b.landed = false
                let wander = 0.15 + 0.6 * flocking + 0.5 * chaos
                let t = Float(time) + f.seed * 37
                var accel = SIMD3<Float>(sin(t * 1.3) * wander, cos(t * 0.9) * wander * 0.7, sin(t * 0.5) * 0.05)
                let flockY = 0.5 + 0.25 * direction
                accel.y += (flockY - f.b.position.y) * 0.6
                accel.x += breeze.x * 0.5
                if spiral > 0.05 {
                    let c = SIMD2<Float>(spiralCentre, 0.48)
                    let d = SIMD2<Float>(f.b.position.x, f.b.position.y) - c
                    let tangent = SIMD2<Float>(-d.y, d.x)
                    let pull = (0.16 - simd_length(d)) * 2
                    accel.x += (tangent.x * 3 + d.x * pull) * spiral
                    accel.y += (tangent.y * 3 + d.y * pull) * spiral
                }
                if swarm > 0.01 {
                    // The swarm: a wide rising spiral round the middle of the garden.
                    let d = SIMD2<Float>(f.b.position.x - 0.5, f.b.position.y - 0.55)
                    accel.x += -d.y * 2.2 * swarm
                    accel.y += (d.x * 2.2 + 0.9) * swarm
                }
                if gather > 0.01 {
                    // Tension draws them in toward the light gathering in the middle.
                    accel.x += (0.5 - f.b.position.x) * 0.9 * gather
                    accel.y += (0.55 - f.b.position.y) * 0.6 * gather
                }
                f.velocity += accel * fdt
                f.velocity *= max(0, 1 - fdt * 1.2)
                let speedCap: Float = 0.35 + 0.4 * motion + 0.3 * energy + 0.5 * swarm
                let s = simd_length(f.velocity)
                if s > speedCap { f.velocity *= speedCap / s }
                f.b.position += f.velocity * fdt
                // keep in view
                if f.b.position.x < 0.02 { f.velocity.x = abs(f.velocity.x) }
                if f.b.position.x > 0.98 { f.velocity.x = -abs(f.velocity.x) }
                f.b.position.y = min(max(f.b.position.y, 0.1), 0.95)
            }
            let fadeIn = min(1, f.age * 4)
            let fadeOut = min(1, max(0, (f.lifespan - f.age) / 1.5))
            f.b.opacity = fadeIn * fadeOut
            f.b.glow = max(f.b.glow * Float(pow(0.5, dt / 1.2)), 0.25)
            flyers[i] = f
        }
        let before = flyers.count
        flyers.removeAll { $0.age >= $0.lifespan && $0.b.homeNote == nil }
        if flyers.count != before { rebuildIndex() }
        _ = lifespan

        // Blooms
        let bloomSpeed = Float(p.number("bloom.speed")), bloomLife = Float(p.number("bloom.lifetime"))
        for i in blooms.indices {
            blooms[i].age += fdt
            let opening = blooms[i].age < bloomLife - 2 ? 1 : -1
            blooms[i].openness = min(1, max(0, blooms[i].openness + Float(opening) * bloomSpeed * 0.6 * fdt * (landing ? 1.5 : 1)))
            if fdt == 0, blooms[i].age == 0 { blooms[i].openness = max(blooms[i].openness, Self.flowerBloomOpenness) }
            // A drop: every flower opens at once (the bloom).
            if dropping, opening > 0 { blooms[i].openness = min(1, blooms[i].openness + 1.5 * fdt) }
        }
        blooms.removeAll { $0.age > bloomLife && $0.openness <= 0 }

        // Keys
        let keyHalf = linger > 0.5 ? 1.5 : 0.25
        let fall = Float(pow(0.5, dt / keyHalf))
        for i in 0..<88 {
            let note = UInt8(i + 21)
            if let v = held[note] { keyGlow[i] = max(keyGlow[i] * fall, v * 0.6) } else { keyGlow[i] *= fall }
        }
        let keys = Self.layout.map { k in
            KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21])
        }

        // Environment
        let tod = p.choice("time")
        let sunBase: [String: Float] = ["Dawn": 0.18, "Morning": 0.55, "Golden Hour": 0.3, "Dusk": 0.1, "Moonlight": 0.6]
        let night = tod == "Moonlight" || tod == "Dusk"
        let brightness = Float(roles[.brightness])
        let exposure = 0.9 + 0.4 * energy + 0.2 * brightness - (night ? 0.2 : 0)
        let warmthMacro = Float(p.macros[.temperature] ?? 0)
        let melodyFollow = p.choice("camera.motion") == "Follow melody"
        let drift = p.choice("camera.motion") == "Still" ? 0 : Float(0.01)
        var bird: SIMD4<Float>?
        var wing: Float = 0
        if let h = play.surprise(0) {
            bird = Self.hummingbird(age: h.age, life: h.duration, a: h.unit(0), b: h.unit(1))
            wing = (h.age * 48).truncatingRemainder(dividingBy: 1)
        }
        var rain: Float = 0
        if let r = play.surprise(1) { rain = ExcitementPlay.envelope(age: r.age, life: r.duration, rise: 1.5, fall: 3.5) }
        var frame = GardenFrame(
            butterflies: flyers.map(\.b),
            blooms: blooms,
            keys: keys,
            sunHeight: (sunBase[tod] ?? 0.3) + 0.1 * direction + 0.05 * Float(p.number("sun.angle")),
            rays: min(1.5, Float(p.number("rays")) * (0.6 + 0.6 * brightness + 0.4 * energy)),
            mist: min(1, Float(p.number("mist")) + 0.6 * Float(roles[.atmosphere])),
            breeze: breeze,
            pollen: Float(p.number("pollen.sparkle")) * (0.5 + Float(roles[.density])),
            petals: Float(p.number("petals")) * (0.5 + 0.5 * chaos + 0.3 * energy),
            fireflies: p.number("fireflies") > 0.5 && night ? (landing ? 1 : 0.5) : 0,
            warmth: max(-1, min(1, Float(roles[.warmth]) + warmthMacro)),
            exposure: exposure,
            spiral: spiral,
            cameraZoom: Float(p.number("camera.zoom")) - 0.08 * Float(roles[.size]),
            cameraOffset: SIMD2<Float>(
                drift * sin(Float(time) * 0.13) + (melodyFollow ? (melodyX - 0.5) * 0.1 : 0),
                drift * cos(Float(time) * 0.11)),
            timeOfDay: tod,
            time: time)
        frame.rays *= 1 + 0.8 * gather
        frame.swarm = swarm
        frame.momentLight = momentLight
        frame.gather = gather
        frame.hummingbird = bird
        frame.hummingbirdWing = wing
        frame.rainOnGlass = rain
        frame.surprises = play.surprises
        frame.reduceMotion = play.reduceMotion
        return frame
    }

    /// A swarm takes off: every free butterfly lifts (none that hovers over a held key), and up to `swarmCap` more rise
    /// from the flowers (or across the meadow), within the cap.
    private mutating func takeOff(strength: Float, cfg c: Cfg) {
        let s = min(1, max(0, strength))
        for i in flyers.indices where flyers[i].b.homeNote == nil {
            flyers[i].b.landed = false
            flyers[i].velocity.y = max(flyers[i].velocity.y, 0.35 + 0.5 * s)
            flyers[i].velocity.x += rng.range(-0.15, 0.15)
        }
        let count = min(Self.swarmCap, Int((10 + 26 * s).rounded()))
        for k in 0..<count {
            guard flyers.count < lastCap else { break }
            let x: Float = blooms.isEmpty ? rng.range(0.08, 0.92) : blooms[(k * 7) % blooms.count].x + rng.range(-0.03, 0.03)
            let pitch = rng.unit()
            let size = (c.sizeMax + (c.sizeMin - c.sizeMax) * pitch) * (0.7 + 0.5 * s)
            let hue: Float = c.colorSource == "Palette" ? 0.08 + rng.range(-0.04, 0.04) : rng.unit()
            let style: Int
            if c.wingStyle == "Mix" {
                style = rng.unit() < c.wingMix ? 1 + Int(rng.unit() * 8) % 8 : 1
            } else {
                style = Self.wingStyles.firstIndex(of: c.wingStyle) ?? 1
            }
            serial += 1
            let b = Butterfly(id: serial, position: SIMD3<Float>(min(0.98, max(0.02, x)), 0.08 + rng.range(0, 0.06), rng.range(0.2, 0.8)),
                              size: size, hue: hue, flapPhase: rng.unit(), flapRate: 0, style: style, glow: 0.5 + 0.5 * s,
                              landed: false, homeNote: nil, opacity: 0)
            flyers.append(Flyer(b: b, velocity: SIMD3<Float>(rng.range(-0.15, 0.15), 0.45 + 0.5 * s, 0),
                                baseFlap: c.flutter * (5 + 4 * pitch), lifespan: rng.range(5, 8),
                                hoverHeight: 0.2, seed: rng.unit(), serial: serial))
        }
    }

    private mutating func apply(_ e: PerformanceEvent, cfg c: Cfg, roles: RoleValues) {
        switch e {
        case let .noteOn(note, velocity):
            held[note] = velocity
            sinceNote = 0
            guard let x = Self.keyCentre(note) else { return }
            melodyX = x
            if let i = hovering.removeValue(forKey: note) { flyers[i].b.homeNote = nil }
            addBloom(at: x, note: note, kind: c.flowerKind)
            guard velocity >= c.minVelocity else { return }
            spawnBudget = min(spawnBudget + c.spawnRate, 2)
            guard spawnBudget >= 1 else { return }
            spawnBudget -= 1
            spawn(note: note, x: x, velocity: velocity, cfg: c, roles: roles)
        case let .noteOff(note):
            held[note] = nil
            if let i = hovering.removeValue(forKey: note) {
                flyers[i].b.homeNote = nil
                flyers[i].velocity = SIMD3<Float>(rng.range(-0.15, 0.15), 0.3, 0)
            }
        case let .release(note, speed):
            for i in flyers.indices.suffix(64) where flyers[i].b.homeNote == nil {
                guard let x = Self.keyCentre(note), abs(flyers[i].b.position.x - x) < 0.01 else { continue }
                flyers[i].velocity.y = 0.2 + 0.6 * speed
                flyers[i].velocity.x *= 1 + 2 * speed
            }
        case let .chord(notes):
            spiral = c.chordSpiral
            let xs = notes.compactMap(Self.keyCentre)
            if !xs.isEmpty { spiralCentre = xs.reduce(0, +) / Float(xs.count) }
            chordHue = Float((notes.min() ?? 0) % 12) / 12
        case .allNotesOff:
            held.removeAll()
            for i in flyers.indices { flyers[i].b.homeNote = nil }
            hovering.removeAll()
            spiral = 0
            keyGlow = .init(repeating: 0, count: 88)
        case let .pressure(v):
            for i in hovering.values { flyers[i].b.glow = max(flyers[i].b.glow, 0.5 + 0.5 * v) }
        case .pedal, .control, .pitchBend:
            break
        }
    }

    private mutating func spawn(note: UInt8, x: Float, velocity v: Float, cfg c: Cfg, roles: RoleValues) {
        let pitch = (Float(note) - 21) / 87
        let size = (c.sizeMax + (c.sizeMin - c.sizeMax) * pitch) * (0.6 + 0.8 * v) * (1 + 0.5 * Float(roles[.size]))
        let hue: Float
        switch c.colorSource {
        case "Chord": hue = chordHue
        case "Velocity": hue = 0.75 - 0.7 * v
        case "Palette": hue = 0.08 + rng.range(-0.04, 0.04)
        default: hue = Float(note % 12) / 12
        }
        let style: Int
        if c.wingStyle == "Mix" {
            style = rng.unit() < c.wingMix ? 1 + Int(rng.unit() * 8) % 8 : 1
        } else {
            style = Self.wingStyles.firstIndex(of: c.wingStyle) ?? 1
        }
        serial += 1
        let b = Butterfly(id: serial, position: SIMD3<Float>(x, 0.08, rng.range(0.2, 0.8)), size: size, hue: hue,
                          flapPhase: rng.unit(), flapRate: 0, style: style, glow: v, landed: false,
                          homeNote: c.landOnHeld ? note : nil, opacity: 0)
        flyers.append(Flyer(b: b, velocity: SIMD3<Float>(rng.range(-0.1, 0.1), 0.3 + 0.4 * v, 0),
                            baseFlap: c.flutter * (4 + 6 * pitch),
                            lifespan: c.lifespan * rng.range(0.8, 1.2),
                            hoverHeight: 0.15 + 0.15 * v, seed: rng.unit(), serial: serial))
        if b.homeNote != nil { hovering[note] = flyers.count - 1 }
        if flyers.count > lastCap * 2 { trim(to: lastCap) }
    }

    /// Keeps hovering butterflies first, then the newest, up to `cap`.
    private mutating func trim(to cap: Int) {
        guard flyers.count > cap else { return }
        var hover: [Flyer] = [], free: [Flyer] = []
        for f in flyers { if f.b.homeNote != nil { hover.append(f) } else { free.append(f) } }
        let room = max(0, cap - hover.count)
        flyers = (Array(hover.suffix(cap)) + Array(free.suffix(room))).sorted { $0.serial < $1.serial }
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        hovering.removeAll(keepingCapacity: true)
        for (i, f) in flyers.enumerated() { if let n = f.b.homeNote { hovering[n] = i } }
    }

    private mutating func addBloom(at x: Float, note: UInt8, kind chosen: Int) {
        let kind = chosen == 0 ? 1 + Int(rng.unit() * 5) % 5 : chosen
        blooms.append(Bloom(x: x, openness: 0.05, hue: Float(note % 12) / 12, age: 0, kind: kind))
        if blooms.count > Self.maxBlooms { blooms.removeFirst(blooms.count - Self.maxBlooms) }
    }
}
