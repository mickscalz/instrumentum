import Foundation
import simd

// Neon Night Drive (Fire & Neon spec §9): Set 14's world. You sit in the passenger seat of a car on an elevated city
// expressway at night, in rain: the road runs ahead with taillights and oncoming headlights, towers with lit windows and
// wordless neon glyphs rise either side and crowd the far end of the road, and rain beads the windscreen while the wipers
// sweep at a rate set by the rain. Everything you play lands on the drive: Energy and the instrument's tempo set the
// speed, chords colour the neon (warm for major, cool for minor), each note pulses a sign, Chrome Bass's arp races a row of
// road studs towards you, and tension closes the towers in and brings a tunnel whose lights strobe gently. The signature
// moment is The Drop: you burst out of a tunnel (or out from between the towers) onto a bridge over the harbour, every
// sign fires in a wave along the skyline and the light trails streak; landed on a build, the city's lights breathe out
// and the rain hangs in slow motion. It runs on the coast road's driving model (speed and distance, Coast Lights' pitch
// palette and its chord colours), and its visual is Light Trails.

/// The neon's colours (spec §9.1): major is warm (magenta, amber, pink), minor is cool (cyan, blue, violet).
public enum NeonPalette {
    public static let warm: [SIMD3<Float>] = [SIMD3(1.0, 0.06, 0.52), SIMD3(1.0, 0.40, 0.04), SIMD3(1.0, 0.20, 0.40)]
    public static let cool: [SIMD3<Float>] = [SIMD3(0.03, 0.80, 1.0), SIMD3(0.10, 0.30, 1.0), SIMD3(0.50, 0.12, 1.0)]

    /// A sign's colour (linear rgb) for its slot and the neon's warmth (0 cool … 1 warm), mixed in rgb so a change of
    /// chord never sweeps through other hues.
    public static func colour(slot: Int, warmth: Float) -> SIMD3<Float> {
        let i = ((slot % 3) + 3) % 3
        let w: Float = warmth.isFinite ? min(1, max(0, warmth)) : 0.5
        return cool[i] + (warm[i] - cool[i]) * w
    }

    /// The warmth a chord asks for: major 1, minor 0, tense 0.45 (violet into magenta); nil for anything else (the neon
    /// keeps its colour).
    public static func warmth(for q: ChordQuality) -> Float? {
        switch q {
        case .major: return 1
        case .minor: return 0
        case .tense: return 0.45
        default: return nil
        }
    }
}

/// The road's layout across the view (m, x right of the camera's eye): the camera sits in the passenger seat of a car in
/// the second lane from the left; four lanes run your way, a median barrier, three lanes the other way.
public enum DriveRoad {
    public static let eyeHeight: Float = 1.15
    public static let laneWidth: Float = 3.6
    /// Your lane's centre (the car's centreline, 0.45 m right of the passenger's eye).
    public static let ourLane: Float = 0.45
    /// The centre of a lane: 0…3 your way (1 is yours), 4…6 the other way (4 next to the median).
    public static func laneCentre(_ lane: Int) -> Float {
        if lane < 4 { return ourLane + laneWidth * Float(lane - 1) }
        return medianFar + 0.6 + laneWidth * (Float(lane - 4) + 0.5)
    }
    /// The road's left edge, the left parapet's face and height; the median barrier's near and far faces and height; the
    /// far parapet.
    public static let leftEdge: Float = ourLane - 1.5 * laneWidth
    public static let leftParapet: Float = leftEdge - 1.4
    public static let parapetHeight: Float = 1.05
    public static let medianNear: Float = ourLane + 2.5 * laneWidth + 0.6
    public static let medianFar: Float = medianNear + 0.6
    public static let medianHeight: Float = 0.82
    public static let farParapet: Float = medianFar + 0.6 + 3 * laneWidth + 1.2
    /// Road studs lie along the lane lines this far apart (m), world-fixed.
    public static let studSpacing: Float = 12
    /// The tunnel's ceiling lights pass at most 3 a second (spec §9.1): spaced so even the fastest car (speed 1 with the
    /// drop's surge) passes them no faster.
    public static var tunnelLightSpacing: Float { NeonNightDriveModel.metresPerSecond(1.25) / 3 }
}

/// The wipers (Window Kit, spec §9.1): their rate follows the rain. Dry, they rest; in a drizzle they sweep now and then
/// (the rest shortening from 6 s to 1 s); from Low they sweep without rest, faster as the rain gets heavier.
public struct Wipers: Equatable {
    /// Below this rain they stay parked; from `lowAbove` they sweep without rest; by `highAbove` at their fastest.
    public static let dryBelow: Float = 0.04, lowAbove: Float = 0.3, highAbove: Float = 0.75
    /// One sweep (up and back) at Low and at High (s), and the longest rest in a drizzle (s).
    public static let slowSweep: Float = 1.45, fastSweep: Float = 0.9, longestRest: Float = 6

    static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    /// The rest between sweeps for a rain (s): 6 s → 1 s through a drizzle, none from Low up.
    public static func rest(rain: Float) -> Float {
        let r = unit(rain)
        guard r < lowAbove else { return 0 }
        let f: Float = min(1, max(0, (r - dryBelow) / (lowAbove - dryBelow)))
        return longestRest - (longestRest - 1) * f
    }

    /// One sweep's time for a rain (s): Low's until the rain passes `lowAbove`, quickening to High's by `highAbove`.
    public static func sweepTime(rain: Float) -> Float {
        let r = unit(rain)
        let f: Float = min(1, max(0, (r - lowAbove) / (highAbove - lowAbove)))
        return slowSweep + (fastSweep - slowSweep) * f
    }

    /// Sweeps a minute for a rain: 0 when dry, about 8 in the lightest drizzle, 41 at Low, 67 at High.
    public static func rate(rain: Float) -> Float {
        let r = unit(rain)
        guard r >= dryBelow else { return 0 }
        return 60 / (sweepTime(rain: r) + rest(rain: r))
    }

    /// 0…1 through the current sweep (up, then back), 0 at rest.
    public private(set) var phase: Float = 0
    public private(set) var sweeping = false
    /// This sweep's time and the last one's (s).
    public private(set) var sweepSeconds: Float = Wipers.slowSweep
    public private(set) var lastSweepSeconds: Float = Wipers.slowSweep
    /// The rest before this sweep began, or while resting, the rest so far (s).
    public private(set) var restBefore: Float = 1000
    /// Sweeps finished so far.
    public private(set) var sweeps = 0

    public init() {}

    /// Where the blades stand: 0 parked … 1 at the top of the sweep.
    public var angle: Float { sweeping ? 0.5 - 0.5 * cos(2 * Float.pi * phase) : 0 }

    /// Seconds since a blade last passed `a` (0 parked … 1 the top of the sweep): how long the drops there have been
    /// gathering (1000 for glass never wiped).
    public func sinceWiped(_ a: Float) -> Float {
        let x: Float = min(1, max(0, a.isFinite ? a : 0))
        let up: Float = acos(min(1, max(-1, 1 - 2 * x))) / (2 * Float.pi)
        let down: Float = 1 - up
        if sweeps == 0 && !sweeping { return 1000 }
        if sweeping {
            if phase >= down { return (phase - down) * sweepSeconds }
            if phase >= up { return (phase - up) * sweepSeconds }
            if sweeps == 0 { return 1000 }
            return phase * sweepSeconds + restBefore + up * lastSweepSeconds
        }
        return restBefore + up * lastSweepSeconds
    }

    /// Seconds until the next sweep begins in `rain` (0…1), as `step` would run it: the rest of this sweep and the rest
    /// after it, or what is left of the rest; nil while it is too dry for one.
    public func nextSweep(rain: Float) -> Float? {
        let r = Self.unit(rain)
        if sweeping {
            let left: Float = (1 - phase) * max(0.1, sweepSeconds)
            return r >= Self.dryBelow ? left + Self.rest(rain: r) : nil
        }
        guard r >= Self.dryBelow else { return nil }
        return max(0, Self.rest(rain: r) - restBefore)
    }

    /// Advances by `dt` (s) in `rain` (0…1). Time left over when a sweep ends or a rest runs out carries on into the next,
    /// so the blades keep their rate whatever the frame rate.
    public mutating func step(dt: Float, rain: Float) {
        guard dt.isFinite, dt > 0 else { return }
        let r = Self.unit(rain)
        var left: Float = dt
        for _ in 0..<4 {
            if sweeping {
                let length: Float = max(0.1, sweepSeconds)
                let need: Float = (1 - phase) * length
                if left < need {
                    phase += left / length
                    return
                }
                left -= need
                sweeping = false
                phase = 0
                lastSweepSeconds = sweepSeconds
                restBefore = 0
                sweeps += 1
            } else {
                guard r >= Self.dryBelow else {
                    restBefore += left
                    return
                }
                let wait: Float = Self.rest(rain: r) - restBefore
                if left < wait {
                    restBefore += left
                    return
                }
                if wait > 0 {
                    restBefore += wait
                    left -= wait
                }
                sweeping = true
                phase = 0
                sweepSeconds = Self.sweepTime(rain: r)
            }
        }
    }
}

/// A pulse racing down the road studs towards you: one for each of the arp's steps (spec §9.1).
public struct StudPulse: Equatable {
    /// How far ahead it is now (m).
    public var ahead: Float
    public var brightness: Float
}

/// A car sharing the road.
public struct DriveCar: Equatable {
    /// 0…3 your way (1 is yours), 4…6 the other way.
    public var lane: Int
    /// How far ahead (m) its tail (your way) or its front (the other way) is.
    public var ahead: Float
    /// Its own speed (m/s).
    public var speed: Float
    /// Its look: body, lights.
    public var seed: UInt64
    /// Its brake lights (0…1).
    public var brake: Float
    /// The surprise's abstract light bar on its roof (a slow ribbon of colour, never a beacon).
    public var lightBar: Bool
    public var oncoming: Bool { lane >= 4 }
    /// About one in nine is a truck (the soundscape hears it lower and longer as it passes).
    public var truck: Bool { !lightBar && seed % 9 == 4 }
}

/// A bridge over the expressway (a surprise): a railway with a train crossing, or a road (under it, the rain on the glass
/// stops for a moment).
public struct DriveOverpass: Equatable {
    /// Metres ahead to its near face, and its width along the road (m).
    public var ahead: Float
    public var depth: Float
    public var rail: Bool
    /// The train's head across the view (m, right of your eye) and its length (m), while one crosses.
    public var trainX: Float?
    public var trainLength: Float
}

/// Far lightning behind the towers (a surprise): its age, seed and where it stands across the skyline.
public struct DriveLightning: Equatable {
    public var age: Float
    public var seed: UInt64
    /// Across the view (−1 left … 1 right of the road ahead, in the skyline's own spread).
    public var across: Float
    public var strength: Float
    public static let life: Float = 0.9
    /// Its light now (0…1, before any flash limiter): two or three stroke spikes and a short afterglow.
    public var light: Float {
        guard age >= 0, age < Self.life else { return 0 }
        let times: [Float] = [0, 0.11, 0.27]
        let strokes = 2 + Int(seed % 2)
        var l: Float = 0
        for k in 0..<strokes {
            let since: Float = age - times[k]
            if since >= 0 { l = max(l, (k == 0 ? 1 : 0.7) * exp(-since / 0.05)) }
        }
        let glow: Float = 0.3 * exp(-age / 0.3)
        return min(1, max(l, glow) * strength)
    }
}

/// The Drop's neon wave (spec §9.1): every sign fires in turn, running out from the road's end along the skyline.
public struct NeonWave: Equatable {
    public var age: Float
    public var strength: Float
    public static let life: Float = 2.4
    /// How fast it runs along the skyline (screen widths a second).
    public static let speed: Float = 1.1
    /// The light it gives a sign `distance` (screen widths) from where it starts (0…1, before any flash limiter): a sharp
    /// rise as the wave reaches it, a 0.35 s fall.
    public func light(at distance: Float) -> Float {
        let since: Float = age - abs(distance) / Self.speed
        guard since > 0, age < Self.life else { return 0 }
        return strength * (1 - exp(-since / 0.05)) * exp(-since / 0.35)
    }
}

/// A stretch of road ahead (m from the camera): a tunnel or a bridge. `start` < 0 means you're in it.
public struct DriveSpan: Equatable {
    public var start: Float
    public var end: Float
    public func contains(_ z: Float) -> Bool { z >= start && z < end }
}

/// Everything the Neon Night Drive renderer needs for a frame.
public struct DriveFrame: AmbienceProviding {
    /// The Living Sky over the city, with the drive's rain (none in a tunnel).
    public var sky: SkyState
    /// The road's gentle curves: the view's yaw and roll (degrees; none under Reduce Motion).
    public var yaw: Float
    public var roll: Float
    /// The lens (vertical, degrees): a little wider as you go faster (not under Reduce Motion).
    public var fov: Float
    /// The car's speed (0…1, up to 1.25 in the drop's surge), in km/h, and the metres travelled.
    public var speed: Float
    public var kmh: Float
    public var distance: Double
    /// The neon's warmth (0 cool … 1 warm), easing to the chord; how much of the city's neon is lit (the Neon dial).
    public var neonWarmth: Float
    public var neon: Float
    /// Each of the 48 signs' pulse from its notes (0…1.6).
    public var signs: [Float]
    /// A sign that flickers and dies (a surprise): its slot and its light (0 dark … 1 as normal).
    public var deadSign: Int?
    public var deadLight: Float
    /// The Drop's wave along the skyline.
    public var wave: NeonWave?
    /// The arp's pulses racing down the studs.
    public var studs: [StudPulse]
    /// Light Trails: the streaks and the interchange bloom (none while Galaxy Warp is the visual).
    public var trails: [LightStreak]
    public var bloom: InterchangeBloom?
    public var cars: [DriveCar]
    public var overpass: DriveOverpass?
    public var lightning: DriveLightning?
    /// The tunnel and the bridge ahead or around you (m), and how far the towers along the bridge have parted (0…1).
    public var tunnel: DriveSpan?
    public var bridge: DriveSpan?
    public var parting: Float
    /// The tunnel's ceiling lights' spacing (m): at most 3 a second pass even at the fastest.
    public var tunnelLightSpacing: Float
    /// How far the towers have closed in with tension (0…1).
    public var closeIn: Float
    public var energy: Float
    public var tension: Float
    public var drop: Float
    /// The release's breath: the city's lights (1, dipping to 0.65 in a drop's release) and the rain's slow motion (0…1).
    public var cityLight: Float
    public var rainSlow: Float
    /// The rain falling outside (0…1; none in a tunnel) and landing on the windscreen (none under a bridge).
    public var rain: Float
    public var glassRain: Float
    public var wipers: Wipers
    public var reduceMotion: Bool
    /// The keys: a strip of light along the dashboard's edge, each lit in the neon's colour by its note.
    public var keys: [KeyVisual]
    public var ambience: AmbienceScene
    public var mood: Mood
    public var time: Double
    /// Galaxy Warp over the city, when it's the chosen visual (notes then streak through the sky instead).
    public var warp: WarpFrame?
}

/// Set 14's world (spec §9).
public struct NeonNightDriveModel: ThemeModel, MoodAware, SkyAware, ExcitementAware, PulseAware, SurpriseListing {
    public typealias Frame = DriveFrame
    public static let id = "neon-night-drive"
    public static let displayName = "Neon Night Drive"
    public static let visuals = ["Light Trails", "Galaxy Warp"]
    /// The world's surprises (spec §9.1): a train crossing an overpass, far lightning behind the towers, a sign that
    /// flickers and dies, an abstract light bar passing (never a beacon or any service's livery), the rain stopping under a
    /// bridge.
    public static let surpriseCount = 5
    public static let signCount = 48
    public static let studCap = 16
    public static let carCap = 12

    /// Speed (spec §9.1): 0.25 + 0.55·Energy, plus up to 0.2 more from the instrument's tempo (none at 90 BPM or slower,
    /// all of it from 140); a moment surges it by up to 0.25 for 2 s.
    public static let cruise: Float = 0.25, energySpeed: Float = 0.55, tempoSpeed: Float = 0.2
    public static let surgeSpeed: Float = 0.25, surgeSeconds: Float = 2
    static let speedUpTau = 0.5, speedDownTau = 2.5
    /// The neon eases to a new chord's colour over 0.4 s (95% of the way).
    public static let hueSeconds: Float = 0.4
    /// The studs' pulses start this far ahead (m) and race towards you this fast (m/s).
    public static let studStart: Float = 72
    public static let studSpeed: Float = 45
    /// Tension above this brings a tunnel `tunnelAhead` m on; below `tunnelLeaves` (after `tunnelLingers` s in it) you
    /// leave it again without a drop.
    public static let tunnelAt: Float = 0.55, tunnelLeaves: Float = 0.2, tunnelLingers: Float = 4
    public static let tunnelAhead: Float = 200
    /// A moment in the tunnel brings its mouth this close (m); the bridge runs this long (s at the speed then).
    public static let exitAhead: Float = 40
    public static let bridgeSeconds: Float = 11
    /// A moment on the street parts the towers this far ahead (m), over `partSeconds`.
    public static let partAhead: Float = 30
    public static let partSeconds: Float = 0.9
    /// The longest a tunnel lasts without a drop (s), and how long after leaving one before tension brings another.
    public static let longestTunnel: Float = 25, tunnelCooldown: Float = 15
    /// The surprise's train crosses at this speed (m/s).
    public static let trainSpeed: Float = 30

    public var mood = Mood.neutral
    public var pulse: InstrumentPulse?

    private var rawSky = SkyState()
    private var excite = ExcitementFrame()
    private var trails = LightTrails()
    private var warp = GalaxyWarp()
    private var wipers = Wipers()
    private var pending: [PerformanceEvent] = []
    private var held: [UInt8: Float] = [:]
    private var keyGlow = [Float](repeating: 0, count: 88)
    private var lastVisual: String?
    private var time = 0.0
    private var distance = 0.0
    private var speed: Float = NeonNightDriveModel.cruise
    private var surge: Float = 0
    private var warmth: Float = 1
    private var signPeak = [Float](repeating: 0, count: NeonNightDriveModel.signCount)
    private var signAge = [Float](repeating: 10, count: NeonNightDriveModel.signCount)
    private var signs = [Float](repeating: 0, count: NeonNightDriveModel.signCount)
    private var studs: [StudPulse] = []
    private var grid: Double?
    private var lastStep = -1e9
    private var cars: [DriveCar] = []
    private var carActive = [Bool](repeating: false, count: NeonNightDriveModel.carCap)
    private var overpass: DriveOverpass?
    private var lightning: DriveLightning?
    private var deadSign: (slot: Int, age: Float)?
    private var wave: NeonWave?
    /// A moment in the tunnel saves its wave for the moment you burst out of it.
    private var waveDue: Float?
    private var tunnelStart: Double?
    private var tunnelEnd: Double?
    private var inTunnelFor: Float = 0
    private var sinceTunnel: Float = 1000
    private var bridgeStart: Double?
    private var bridgeEnd: Double?
    private var parting: Float = 0
    private var closeIn: Float = 0
    private var shelter: Float = 0
    private var wiperRain: Float = 0
    /// The soundscape's one-shots this step (wipers' sweeps, cars passing), the last sweep sent, and each car slot's pass
    /// sent (by the car's seed).
    private var events: [AmbienceEvent] = []
    private var sweepSent = -1
    private var passSent = [UInt64](repeating: 0, count: NeonNightDriveModel.carCap)
    private var rng = SeededRandom(seed: 0xD21_7E0_4E0)
    private var trafficRng = SeededRandom(seed: 0x7AF_F1C)

    private static let layout = KeyboardLayout.keys()

    public init() {
        studs.reserveCapacity(Self.studCap)
        cars.reserveCapacity(Self.carCap)
        for i in 0..<Self.carCap {
            cars.append(DriveCar(lane: i % 7, ahead: 0, speed: 25, seed: UInt64(i) &* 0x9E37_79B9 &+ 17, brake: 0, lightBar: false))
        }
    }

    public mutating func handle(_ e: PerformanceEvent) { pending.append(e) }

    /// The city's night: warm or cold as the sky has it (snow falls as snow), its own rain added in `step`.
    public mutating func setSky(_ s: SkyState) { rawSky = s }

    /// Excitement's frame for the next step; its moment and surprise are taken once.
    public mutating func setExcitement(_ e: ExcitementFrame) { excite = e }

    // MARK: - The laws

    /// The car's speed for an Energy and the instrument's pulse (spec §9.1): 0.25 + 0.55·Energy, plus the tempo's share.
    public static func targetSpeed(energy: Float, pulse: InstrumentPulse?) -> Float {
        let e: Float = energy.isFinite ? min(1, max(0, energy)) : 0
        return min(1, cruise + energySpeed * e + tempoBoost(pulse))
    }

    /// The tempo's share of the speed: none at 90 BPM or slower, rising to 0.2 at 140 and above.
    public static func tempoBoost(_ p: InstrumentPulse?) -> Float {
        guard let p, p.bpm.isFinite else { return 0 }
        let f: Float = Float(min(1, max(0, (p.bpm - 90) / 50)))
        return tempoSpeed * f
    }

    /// Metres a second for a speed (0…1 is 50…130 km/h; the surge goes past it).
    public static func metresPerSecond(_ speed: Float) -> Float {
        let s: Float = speed.isFinite ? max(0, speed) : cruise
        return (50 + 80 * s) / 3.6
    }

    /// The arp's sixteenth (s) at the pulse's tempo.
    public static func stepLength(_ p: InstrumentPulse) -> Double {
        let bpm: Double = p.bpm.isFinite ? min(240, max(40, p.bpm)) : 120
        return 60 / bpm / 4
    }

    /// The sign a note pulses (one of 48; neighbouring keys light signs far apart in the city).
    public static func sign(for note: UInt8) -> Int { Int(note) % signCount }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Step

    public mutating func step(dt: Double, params p: ParameterSet, roles: RoleValues, inputs: InputFrame, quality: QualityLevel) -> DriveFrame {
        let fdt = dt.isFinite ? min(max(dt, 0), 0.25) : 0
        let fd = Float(fdt)
        time += fdt
        let visual = p.choice("visual")
        let warping = visual == "Galaxy Warp"
        if let lastVisual, lastVisual != visual { trails.allNotesOff(); warp.allNotesOff() }
        lastVisual = visual
        trails.trails = Float(p.number("trails"))
        let holdBloom = fdt == 0
        // The studs' pulses race on (those the arp sends this step start where its step left them).
        for i in studs.indices { studs[i].ahead -= Self.studSpeed * fd }
        studs.removeAll { $0.ahead < 2 }

        // Notes: a sign pulses, a streak fires down its lane (or the warp streaks), the arp's notes race the studs.
        for e in pending {
            switch e {
            case let .noteOn(note, velocity):
                let v: Float = velocity.isFinite ? min(1, max(0, velocity)) : 0.7
                held[note] = v
                let slot = Self.sign(for: note)
                signPeak[slot] = max(signPeak[slot], 0.45 + 0.75 * v)
                signAge[slot] = 0
                if warping {
                    warp.noteOn(note, velocity: UInt8(min(127, max(0, (v * 127).rounded()))), at: time)
                } else {
                    trails.noteOn(note, velocity: v, colour: NeonPalette.colour(slot: Int(note), warmth: warmth),
                                  bloomNow: holdBloom)
                }
                if note < LightTrails.split {
                    if pulse == nil {
                        addStud(brightness: 0.5 + 0.5 * v, late: 0)
                    } else if grid == nil, let pl = pulse {
                        addStud(brightness: 0.5 + 0.5 * v, late: 0)
                        lastStep = time
                        grid = time + Self.stepLength(pl)
                    }
                }
                if (21...108).contains(note) { keyGlow[Int(note) - 21] = max(keyGlow[Int(note) - 21], 0.4 + 0.6 * v) }
            case let .noteOff(note):
                held[note] = nil
                trails.noteOff(note)
                warp.noteOff(note)
            case .allNotesOff:
                held.removeAll()
                trails.allNotesOff()
                warp.allNotesOff()
                keyGlow = .init(repeating: 0, count: 88)
            default:
                break
            }
        }
        pending.removeAll(keepingCapacity: true)
        let warpFrame = warp.step(dt: fdt, roles: roles, inputs: inputs)

        // Excitement as drawn: Reduce Motion caps Energy's look at 0.5 and halves a moment.
        let reduce = excite.reduceMotion
        let energy: Float = min(1, max(0, excite.visualEnergy.isFinite ? excite.visualEnergy : 0))
        let tension: Float = min(1, max(0, excite.tension.isFinite ? excite.tension : 0))
        let drop: Float = min(1, max(0, excite.drop.isFinite ? excite.drop : 0))
        let moment = excite.moment
        let surprise = excite.surprise
        excite.moment = nil
        excite.surprise = nil
        events.removeAll(keepingCapacity: true)

        // The neon follows the chord, easing over 0.4 s.
        let quality3 = held.count >= 3 ? PlayingAnalyzer.classify(Set(held.keys)) : .none
        if let target = NeonPalette.warmth(for: quality3), fd > 0 {
            let k: Float = 1 - exp(-3 * fd / Self.hueSeconds)
            warmth += (target - warmth) * k
        }

        // Speed: Energy and the tempo, the surge on top.
        surge = max(0, surge - fd / Self.surgeSeconds)
        let surgeNow: Float = Self.surgeSpeed * surge
        let target = Self.targetSpeed(energy: energy, pulse: pulse) + surgeNow
        let tau = target > speed ? Self.speedUpTau : Self.speedDownTau
        speed += (target - speed) * Float(1 - exp(-fdt / tau))
        let mps = Self.metresPerSecond(speed)
        distance += Double(mps * fd)

        // The arp's grid races a stud pulse down the road on every step (none without a low note held).
        let lowHeld = held.keys.contains { $0 < LightTrails.split }
        if let pl = pulse, lowHeld {
            let len = Self.stepLength(pl)
            if grid == nil { grid = time + len; lastStep = time }
            while let g = grid, time >= g {
                addStud(brightness: 0.9, late: Float(time - g))
                lastStep = g
                grid = g + len
            }
        } else {
            grid = nil
        }

        // Signs: lit while their notes sound (blinking on the arp's steps, when there is a pulse), fading once let go.
        var heldSlot = [Bool](repeating: false, count: Self.signCount)
        for n in held.keys { heldSlot[Self.sign(for: n)] = true }
        let blink: Float
        if let pl = pulse, grid != nil {
            let since = Float(time - lastStep)
            blink = 0.55 + 0.45 * exp(-since / Float(0.35 * Self.stepLength(pl)))
        } else {
            blink = 1
        }
        for i in 0..<Self.signCount {
            signAge[i] += fd
            let attack: Float = 1 + 0.6 * exp(-signAge[i] / 0.08)
            if heldSlot[i] {
                signs[i] = signPeak[i] * attack * blink
            } else {
                signPeak[i] *= exp(-fd / 0.5)
                if signPeak[i] < 0.01 { signPeak[i] = 0 }
                signs[i] = signPeak[i] * attack
            }
        }

        // Light Trails.
        trails.step(dt: fdt, metresPerSecond: mps)

        // A big moment: the surge, the neon wave, the interchange bloom, and the road opens onto the bridge.
        if let m = moment {
            let power: Float = min(1, max(0.3, m.strength.isFinite ? m.strength : 0.3)) * (reduce ? 0.5 : 1)
            surge = reduce ? 0.5 : 1
            let tunnelled = tunnelSpan().map { $0.end > 0 && $0.start < 60 } ?? false
            if tunnelled { waveDue = max(waveDue ?? 0, power) } else { wave = NeonWave(age: 0, strength: power) }
            if !warping { trails.fireBloom(strength: power, seed: rng.next()) }
            openRoad(mps: Self.metresPerSecond(min(1.25, target + Self.surgeSpeed)))
        }
        // Out of the tunnel: the city opens up and every sign fires.
        if let due = waveDue, tunnelSpan().map({ $0.end <= 0 }) ?? true {
            wave = NeonWave(age: 0, strength: due)
            waveDue = nil
        }
        if var w = wave {
            w.age += fd
            wave = w.age >= NeonWave.life ? nil : w
        }

        // Tension: the towers close in, a tunnel comes, and with no drop you leave it again.
        let closeTarget: Float = Self.smooth(0.2, 0.9, tension)
        closeIn += (closeTarget - closeIn) * (1 - exp(-fd / 1.5))
        stepRoute(tension: tension, dt: fd)

        // Surprises.
        if let s = surprise { surprised(s, mps: mps) }
        stepSurprises(dt: fd, mps: mps)

        // Traffic.
        stepTraffic(dt: fd, mps: mps, density: Float(p.number("traffic")))

        // The rain: the dial's and the sky's, heavier with tension; none falls in the tunnel; none lands on the glass
        // under a bridge (and for a moment after).
        let inTunnel = tunnelSpan().map { $0.start <= 0 && $0.end > 0 } ?? false
        let dial: Float = Float(min(1, max(0, p.number("rain"))))
        let skyRain: Float = max(rawSky.rain.isFinite ? rawSky.rain : 0, rawSky.snow.isFinite ? rawSky.snow : 0)
        let rainAll: Float = min(1, max(dial, skyRain) + 0.3 * tension)
        let rainOut: Float = inTunnel ? 0 : rainAll
        var sheltered: Float = inTunnel ? 1 : 0
        if let o = overpass, o.ahead < 2, o.ahead > -o.depth - 3 { sheltered = 1 }
        shelter = sheltered > shelter ? sheltered : max(sheltered, shelter - fd / 1.2)
        let glassRain: Float = rainAll * (1 - shelter)
        wiperRain += (rainAll - wiperRain) * (1 - exp(-fd / 3))
        wipers.step(dt: fd, rain: wiperRain)
        sendSweeps(glassRain: glassRain)
        sendPasses(mps: mps)

        // The release: the city's lights breathe out, and the rain hangs.
        let breath: Float = drop > 0 ? sin(Float.pi * (1 - drop)) : 0
        let cityLight: Float = 1 - 0.35 * breath
        let rainSlow: Float = min(1, drop / 0.6)

        // The road's gentle curves, and the lens widening with speed (neither under Reduce Motion).
        let yaw: Float = reduce ? 0 : Float(1.1 * sin(2 * .pi * time / 23) + 0.5 * sin(2 * .pi * time / 9.7 + 1.3))
        let roll: Float = reduce ? 0 : Float(0.45 * sin(2 * .pi * time / 23 + 0.4))
        let fov: Float = reduce ? 48 : 46 + 5 * min(1.25, speed) / 1.25

        // Keys: lit while held, then fading.
        let fall = Float(pow(0.5, fdt / (roles[.linger] > 0.5 ? 1.0 : 0.3)))
        for i in 0..<88 where held[UInt8(i + 21)] == nil { keyGlow[i] *= fall }
        let keys = Self.layout.map { k in KeyVisual(key: k, pressed: held[k.note] != nil, glow: keyGlow[Int(k.note) - 21]) }

        // The sky the city shows: rain (none in the tunnel), a wet night, low cloud lit by the city.
        var s = rawSky
        if rawSky.snow > rawSky.rain {
            s.snow = inTunnel ? 0 : max(rawSky.snow, rainAll)
            s.rain = 0
        } else {
            s.rain = rainOut
        }
        s.wetness = max(s.wetness.isFinite ? s.wetness : 0, 0.9)
        s.cloudCover = max(s.cloudCover.isFinite ? s.cloudCover : 0, 0.55 + 0.35 * rainAll)
        s.mist = min(1, max(s.mist.isFinite ? s.mist : 0, 0.15 + 0.25 * rainAll))
        s.lightning = 0
        s.rainbow = 0
        s.fireflies = 0

        let neonDial: Float = Float(min(1, max(0, p.number("neon"))))
        var shownCars: [DriveCar] = []
        shownCars.reserveCapacity(Self.carCap)
        for i in cars.indices where carActive[i] { shownCars.append(cars[i]) }
        let dead: Float = deadLight()
        let ambience = scene(sky: s, glassRain: glassRain, inTunnel: inTunnel, roles: roles, gentle: excite.gentle)
        return DriveFrame(sky: s, yaw: yaw, roll: roll, fov: fov, speed: speed, kmh: mps * 3.6, distance: distance,
                          neonWarmth: warmth, neon: neonDial, signs: signs, deadSign: deadSign?.slot, deadLight: dead,
                          wave: wave, studs: studs, trails: warping ? [] : trails.streaks,
                          bloom: warping ? nil : trails.bloom, cars: shownCars, overpass: overpass, lightning: lightning,
                          tunnel: tunnelSpan(), bridge: bridgeSpan(), parting: parting,
                          tunnelLightSpacing: DriveRoad.tunnelLightSpacing, closeIn: closeIn, energy: energy,
                          tension: tension, drop: drop, cityLight: cityLight, rainSlow: rainSlow, rain: rainOut,
                          glassRain: glassRain, wipers: wipers, reduceMotion: reduce, keys: keys, ambience: ambience,
                          mood: mood, time: time, warp: warping ? warpFrame : nil)
    }

    // MARK: - Studs

    private mutating func addStud(brightness: Float, late: Float) {
        let p = StudPulse(ahead: Self.studStart - Self.studSpeed * max(0, late), brightness: min(1, brightness))
        if studs.count >= Self.studCap { studs.removeFirst() }
        studs.append(p)
    }

    // MARK: - The route: the tunnel and the bridge

    private func relative(_ world: Double?) -> Float? { world.map { Float($0 - distance) } }

    private func tunnelSpan() -> DriveSpan? {
        guard let a = relative(tunnelStart), let b = relative(tunnelEnd) else { return nil }
        return DriveSpan(start: a, end: b)
    }

    private func bridgeSpan() -> DriveSpan? {
        guard let a = relative(bridgeStart), let b = relative(bridgeEnd) else { return nil }
        return DriveSpan(start: a, end: b)
    }

    /// The moment opens the road onto the bridge: out of the tunnel when in one (its mouth `exitAhead` on), through a
    /// short underpass when one is coming, the bridge stretched when already on it, else the towers part ahead.
    private mutating func openRoad(mps: Float) {
        let length = Double(mps * Self.bridgeSeconds)
        if let t = tunnelSpan() {
            if t.start <= 0 {
                let exit = distance + Double(Self.exitAhead)
                tunnelEnd = min(tunnelEnd ?? exit, exit)
            } else {
                tunnelEnd = (tunnelStart ?? distance) + 35
            }
            let from = tunnelEnd ?? distance
            bridgeStart = from
            bridgeEnd = from + length
            parting = 1
            return
        }
        if let b = bridgeSpan(), b.end > 0 {
            bridgeEnd = max(bridgeEnd ?? distance, distance + length)
            return
        }
        bridgeStart = distance + Double(Self.partAhead)
        bridgeEnd = distance + Double(Self.partAhead) + length
        parting = 0
    }

    private mutating func stepRoute(tension: Float, dt: Float) {
        // The towers along a new bridge part over `partSeconds`.
        if bridgeStart != nil { parting = min(1, parting + dt / Self.partSeconds) }
        if let b = bridgeSpan(), b.end < -60 { bridgeStart = nil; bridgeEnd = nil; parting = 0 }
        if let t = tunnelSpan() {
            if t.end < -40 { tunnelStart = nil; tunnelEnd = nil; inTunnelFor = 0; sinceTunnel = 0; return }
            if t.start <= 0, t.end > 0 { inTunnelFor += dt }
            // No drop: tension fades and the tunnel lets you out again; one not yet reached is never built.
            let open = tunnelEnd.map { $0 - distance > 1e5 } ?? true
            if open, tension < Self.tunnelLeaves {
                if t.start > 120 {
                    tunnelStart = nil; tunnelEnd = nil
                } else if t.start > 0 {
                    tunnelEnd = (tunnelStart ?? distance) + 160
                } else if inTunnelFor >= Self.tunnelLingers {
                    tunnelEnd = distance + 160
                }
            } else if open, inTunnelFor >= Self.longestTunnel {
                tunnelEnd = distance + 160
            }
            return
        }
        sinceTunnel += dt
        // Tension brings a tunnel, unless you are on (or about to cross) a bridge.
        let bridging = bridgeSpan().map { $0.end > -20 } ?? false
        if tension >= Self.tunnelAt, !bridging, sinceTunnel >= Self.tunnelCooldown {
            tunnelStart = distance + Double(Self.tunnelAhead)
            tunnelEnd = distance + 1e6
            inTunnelFor = 0
        }
    }

    // MARK: - Surprises

    private mutating func surprised(_ s: WorldSurprise, mps: Float) {
        var r = SeededRandom(seed: s.seed)
        let inTunnel = tunnelSpan().map { $0.start < 60 && $0.end > 0 } ?? false
        switch s.index {
        case 0:
            // A train of lit carriages crossing a railway bridge ahead, timed to cross as you come to it.
            guard overpass == nil, !inTunnel else { return }
            let ahead: Float = 260
            let arrive: Float = ahead / max(10, mps)
            let head: Float = -10 - Self.trainSpeed * max(0, arrive - 5.5)
            overpass = DriveOverpass(ahead: ahead, depth: 11, rail: true, trainX: head, trainLength: 160)
        case 1:
            lightning = DriveLightning(age: 0, seed: s.seed, across: r.range(-0.7, 0.7), strength: r.range(0.6, 1))
        case 2:
            deadSign = (slot: Int(s.seed % UInt64(Self.signCount)), age: 0)
        case 3:
            // An abstract light bar on a car overtaking in the next lane: a slow ribbon of colour, never a beacon.
            let slot = Self.carCap - 1
            guard !(carActive[slot] && cars[slot].lightBar) else { return }
            cars[slot] = DriveCar(lane: 2, ahead: -14, speed: mps + 9, seed: s.seed, brake: 0, lightBar: true)
            carActive[slot] = true
        default:
            // A road bridge ahead: under it the rain on the glass stops for a moment.
            guard overpass == nil, !inTunnel else { return }
            overpass = DriveOverpass(ahead: 170, depth: 22, rail: false, trainX: nil, trainLength: 0)
        }
    }

    private mutating func stepSurprises(dt: Float, mps: Float) {
        if var o = overpass {
            o.ahead -= mps * dt
            if let x = o.trainX {
                let moved = x + Self.trainSpeed * dt
                o.trainX = moved - o.trainLength > 320 ? nil : moved
            }
            overpass = o.ahead < -o.depth - 30 ? nil : o
        }
        if var l = lightning {
            l.age += dt
            lightning = l.age >= DriveLightning.life ? nil : l
        }
        if var d = deadSign {
            d.age += dt
            deadSign = d.age >= 30 ? nil : d
        }
    }

    /// The dying sign's light: flickering for 2.5 s, dark for 25, flickering back over its last 2.5 s.
    private func deadLight() -> Float {
        guard let d = deadSign else { return 1 }
        let a = d.age
        if a < 2.5 || a > 27.5 {
            let bucket = UInt64(max(0, a) * 14)
            var r = SeededRandom(seed: bucket &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(d.slot))
            let dying: Float = a < 2.5 ? a / 2.5 : (30 - a) / 2.5
            return r.unit() > dying ? 1 : 0.08
        }
        return 0
    }

    // MARK: - Traffic

    private mutating func stepTraffic(dt: Float, mps: Float, density: Float) {
        let d: Float = density.isFinite ? min(1, max(0, density)) : 0.5
        let ours = 2 + Int((4 * d).rounded())      // 2…6 your way
        let theirs = 1 + Int((4 * d).rounded())    // 1…5 the other way
        for i in 0..<(Self.carCap - 1) {
            let wantOurs = i < 6
            let want = wantOurs ? i < ours : (i - 6) < theirs
            if want && !carActive[i] {
                cars[i] = spawnCar(oncoming: !wantOurs, index: i, mps: mps, anywhere: true)
                carActive[i] = true
            } else if !want && carActive[i] {
                carActive[i] = false
            }
        }
        for i in cars.indices where carActive[i] {
            var c = cars[i]
            if c.oncoming {
                c.ahead -= (c.speed + mps) * dt
                if c.ahead < -25 { c = spawnCar(oncoming: true, index: i, mps: mps, anywhere: false) }
            } else if c.lane == 1 && !c.lightBar {
                // The car ahead in your lane keeps its distance, drifting between 38 and 70 m.
                let want: Float = 54 + 16 * sin(Float(time) * 0.21 + Float(c.seed % 7))
                c.speed = mps + 0.5 * (want - c.ahead)
                c.ahead += (c.speed - mps) * dt
            } else {
                c.ahead += (c.speed - mps) * dt
                if c.lightBar, c.ahead > 360 { carActive[i] = false; continue }
                if c.ahead < -18 || c.ahead > 470 { c = spawnCar(oncoming: false, index: i, mps: mps, anywhere: false) }
            }
            // Now and then a car brakes for a few seconds.
            let phase = Float(time) * 0.13 + Float(c.seed % 97) * 0.37
            c.brake = max(0, sin(phase) - 0.86) / 0.14
            cars[i] = c
        }
    }

    private mutating func spawnCar(oncoming: Bool, index: Int, mps: Float, anywhere: Bool) -> DriveCar {
        let seed = trafficRng.next()
        if oncoming {
            let lane = 4 + Int(seed % 3)
            let ahead: Float = anywhere ? trafficRng.range(40, 600) : trafficRng.range(520, 680)
            return DriveCar(lane: lane, ahead: ahead, speed: trafficRng.range(22, 32), seed: seed, brake: 0, lightBar: false)
        }
        // Your way: lane 1 holds one car ahead of you; the rest spread over the other lanes.
        let lanes = [0, 2, 3, 0, 2, 3]
        let lane = index == 0 ? 1 : lanes[index % 6]
        let faster = trafficRng.unit() < 0.5
        let speed: Float = mps * (faster ? trafficRng.range(1.05, 1.25) : trafficRng.range(0.8, 0.95))
        var ahead: Float
        if index == 0 {
            ahead = 54
        } else if anywhere {
            ahead = trafficRng.range(30, 420)
        } else {
            ahead = faster ? -16 : trafficRng.range(380, 460)
        }
        // Keep clear of a car already in that lane.
        for (j, c) in cars.enumerated() where j != index && carActive[j] && c.lane == lane && abs(c.ahead - ahead) < 24 {
            ahead = c.ahead + (faster ? -26 : 26)
        }
        return DriveCar(lane: lane, ahead: ahead, speed: speed, seed: seed, brake: 0, lightBar: false)
    }

    // MARK: - Ambience

    /// The wipers' sweeps for the soundscape (spec §9.3): each sent a moment before it begins, so its squeak and its thunks
    /// land with the blades however the throttle holds it (and one already under way at once); `glassRain` says how wet
    /// the glass is (dry under a bridge, so the rubber squeaks).
    static let sweepLead: Float = 0.25

    private mutating func sendSweeps(glassRain: Float) {
        let wet = Double(min(1, max(0, glassRain.isFinite ? glassRain : 0)))
        if wipers.sweeping, wipers.sweeps > sweepSent {
            events.append(.sweep(in: 0, seconds: Double((1 - wipers.phase) * wipers.sweepSeconds), wet: wet))
            sweepSent = wipers.sweeps
        }
        let next = wipers.sweeps + (wipers.sweeping ? 1 : 0)
        if next > sweepSent, let t = wipers.nextSweep(rain: wiperRain), t <= Self.sweepLead {
            events.append(.sweep(in: Double(t), seconds: Double(Wipers.sweepTime(rain: wiperRain)), wet: wet))
            sweepSent = next
        }
    }

    /// When a car in another lane comes alongside you (s from now), how fast it closes (m/s) and how far to the side it
    /// passes (m, < 0 on your left); nil once it has passed or never will.
    public static func pass(of c: DriveCar, mps: Float) -> (after: Float, closing: Float, lateral: Float)? {
        guard c.lane != 1, c.ahead.isFinite, c.speed.isFinite else { return nil }
        let closing: Float
        if c.oncoming {
            guard c.ahead > 0 else { return nil }
            closing = c.speed + mps
        } else if c.ahead > 0 {
            closing = mps - c.speed    // you are catching it
        } else {
            closing = c.speed - mps    // it is catching you
        }
        guard closing > 0.5 else { return nil }
        return (abs(c.ahead) / closing, closing, DriveRoad.laneCentre(c.lane))
    }

    /// How long before a car comes alongside its sound is sent (the engine plays its approach from then).
    static let passLead: Float = 3

    private mutating func sendPasses(mps: Float) {
        for i in cars.indices where carActive[i] {
            let c = cars[i]
            guard passSent[i] != c.seed, let p = Self.pass(of: c, mps: mps), p.after <= Self.passLead else { continue }
            passSent[i] = c.seed
            events.append(.passingCar(in: Double(p.after), closing: Double(p.closing), lateral: Double(p.lateral), truck: c.truck))
        }
    }

    /// The drive's soundscape (spec §9.3): the drive family and a little of the city. Wet tyres and the engine follow the
    /// speed in the engine (the scene's `speed`), the roof rain is the rain on the glass (none under a bridge or in the
    /// tunnel), the wipers and the passing cars sound on the world's events, and the far siren calls now and then, rare,
    /// far and in key, off under gentle visuals and in the tunnel. The wind round the windscreen rises with the speed; the
    /// city's far street hum is gone in the tunnel; the weather's own on top.
    public static func levels(_ s: SkyState, speed: Float, glassRain: Float, inTunnel: Bool, gentle: Bool) -> [AmbienceSource: Double] {
        let v = Double(min(1.25, max(0, speed.isFinite ? speed : 0)) / 1.25)
        let rain = Double(min(1, max(0, glassRain.isFinite ? glassRain : 0)))
        var levels: [AmbienceSource: Double] = [
            .wetTyres: 0.8,
            .driveEngine: 0.65,
            .drivePassingCar: 0.8,
            .wipers: 0.75,
            .windowWind: 0.12 + 0.18 * v,
            .street: inTunnel ? 0 : 0.22,
        ]
        if rain > 0.01 { levels[.roofRain] = rain }
        if !gentle, !inTunnel { levels[.farSiren] = 0.6 }
        var weather = s
        if inTunnel { weather.rain = 0; weather.snow = 0 }
        WeatherAmbience.levels(weather, base: &levels)
        return levels
    }

    private func scene(sky s: SkyState, glassRain: Float, inTunnel: Bool, roles: RoleValues, gentle: Bool) -> AmbienceScene {
        let levels = Self.levels(s, speed: speed, glassRain: glassRain, inTunnel: inTunnel, gentle: gentle)
        let night = MoonlitLakeModel.smooth(-3, -9, s.sun.altitude)
        let sinceDusk = (s.hourOfDay - 19 + 24).truncatingRemainder(dividingBy: 24)
        let nightCool = night > 0 ? min(1, sinceDusk / 8) : 0
        let activity = min(1, 0.6 * roles[.energy] + 0.4 * roles[.density])
        return AmbienceScene(levels: levels, nightCool: nightCool, activity: activity, thunder: nil,
                             closeness: MoodLook.ambienceCloseness(base: 0.6, mood), density: MoodLook.ambienceDensity(mood),
                             speed: Double(min(1, speed)), indoors: 0.55, wetness: Double(max(0.6, s.wetness)), events: events)
    }
}

extension NeonNightDriveModel {
    private static func slider(_ id: String, _ name: String, _ group: String, _ range: ClosedRange<Double>, _ def: Double,
                               hero: Bool = false, surprise: ClosedRange<Double>? = nil, help: String) -> ParamSpec {
        ParamSpec(id: id, name: name, group: group, help: help, kind: .slider(range), defaultValue: .number(def), hero: hero, surprise: surprise)
    }

    public static let parameters: [ParamSpec] = [
        ParamSpec(id: "visual", name: "Visual", group: "Visual", help: "What your playing draws down the expressway",
                  kind: .choice(visuals), defaultValue: .choice("Light Trails")),
        SkyHold.spec(default: .deepNight),
        MeteorMode.spec(default: .follow),
        slider("neon", "Neon", "City", 0...1, 0.7, hero: true, surprise: 0.4...1,
               help: "How much of the city's neon is lit and how brightly it burns"),
        slider("rain", "Rain", "City", 0...1, 0.45, hero: true, surprise: 0.2...0.9,
               help: "How hard it rains on the drive (the sky's own rain adds to it); the wipers follow it"),
        slider("traffic", "Traffic", "City", 0...1, 0.5, surprise: 0.2...0.9,
               help: "How many cars share the expressway with you"),
        slider("trails", "Light trails", "Light Trails", 0...1, 0.6, hero: true, surprise: 0.3...1,
               help: "How long and bright the streaks your notes fire down the lanes are"),
        ParamSpec(id: "keys.show", name: "Show keys", group: "Keys", help: "A strip of light along the dashboard, lit in the neon's colour where you play",
                  kind: .toggle, defaultValue: .bool(true)),
    ]

    public static let macroTargets: [Macro: [(id: String, weight: Double)]] = [
        .intensity: [("neon", 0.5), ("trails", 0.6)],
        .speed: [],
        .density: [("traffic", 0.8)],
        .glow: [("neon", 1)],
        .chaos: [("rain", 0.5)],
        .temperature: [],
    ]
}
