import Foundation
import simd

// Strike Lines (Storms spec §9.2): Lightning Plains' visual. One repeated note is the whole idea: each strike of the same
// key lands a forked cloud-to-ground strike on the horizon at the storm's distance, and the storm walks 2% closer with
// every one. A chord forks a strike, a big moment forks three, a run is a crawler across the towers; tension raises the
// wind in the grass and spins the windmill; the drop is the storm's arrival (the rain curtain crosses you, a close strike
// shakes the camera once, the sky is sheet-lit for 2.5 s and the grand's voice is forced to Morph .8); resting lets the
// storm walk back out over a minute. Every other note flickers inside the towers over its pitch, so each one lands on the
// sky. Everything here is seeded and control-rate; the renderer draws the forks and crawlers as analytic segments.

/// A cloud-to-ground strike on the plain: a forked channel from the storm's cloud base to the ground.
public struct Fork: Equatable {
    public enum Kind: Equatable {
        /// A repeated note's strike on the horizon.
        case repeated
        /// A chord's.
        case chord
        /// One of a big moment's three.
        case moment
        /// The storm's arrival: the drop's close strike.
        case arrival
    }

    public var id: Int
    public var kind: Kind
    /// Where it lands (its origin): the azimuth (degrees from north, clockwise) and how far away (km).
    public var azimuth: Double
    public var km: Double
    /// The cloud base it falls from (km above the plain).
    public var baseKm: Float
    /// The channel and its branches, 4–7 polylines. Each point is (x across, y up) in units of the cloud base's height:
    /// y from 1 (the cloud base) down to 0 (the ground), x from the strike's own vertical. The first reaches the ground;
    /// the others fork off it and end in the air.
    public var branches: [[SIMD2<Float>]]
    /// Seconds since it landed.
    public var age: Double
    /// Its light now, 0…1: the return strokes' flicker and the channel's afterglow (before any flash limiter).
    public var brightness: Float
    /// It came under virga: no rain with it.
    public var dry: Bool
    /// Its return strokes: (seconds after it lands, strength 0…1), the first at once and the brightest.
    public var strokes: [SIMD2<Float>]

    /// Where it lands: (azimuth, km).
    public var origin: SIMD2<Double> { SIMD2(azimuth, km) }
    /// How many straight segments it is drawn with.
    public var segmentCount: Int { branches.reduce(0) { $0 + max(0, $1.count - 1) } }
}

/// A flash inside one of the storm's towers (heat lightning seen in the cloud, and every note's flicker).
public struct TowerFlash: Equatable {
    /// The tower (an index into `StrikeLines.towers`).
    public var tower: Int
    /// Where in the sky its light is centred (degrees: azimuth from north, altitude) and how far it spreads (degrees).
    public var azimuth: Double
    public var altitude: Double
    public var radius: Double
    /// When it began (seconds on the lines' clock), how long it lasts, how many times it flickers, its peak (≤ 0.2).
    public var born: Double
    public var duration: Double
    public var flickers: Int
    public var peak: Float
    /// Its light now (0…peak).
    public var level: Float
}

/// A lit fence post: the post for key `index` (0 = A0 … 87 = C8) and how brightly it glows (0…1).
public struct PostLight: Equatable {
    public var index: Int
    public var level: Float
}

/// Ball lightning rolling along the far ridge (a surprise, 10 s).
public struct BallLightning: Equatable {
    /// How far along the ridge (0 its left end … 1 its right), where it set out and where it is going.
    public var position: Float
    public var from: Float
    public var to: Float
    /// Its glow now (0…1) and its age (s).
    public var brightness: Float
    public var age: Double
}

/// A dust devil crossing the plain (a surprise): the wind field's vortex, seen as a column of dust.
public struct DustDevil: Equatable {
    /// Its eye on the ground (metres: x across the view, y away from you) and how strongly it is turning (0…1).
    public var centre: SIMD2<Float>
    public var level: Float
    public var age: Double
}

/// One of the storm's towers: where it stands in the storm's line and how big it is (km).
public struct StormTower: Equatable {
    /// Across the line from its middle (+ to the right as you face it), and how much further (+) or nearer (−) than the
    /// storm's distance when it is far (the line closes up as it comes).
    public var across: Double
    public var depth: Double
    /// The turret's top, its half-width, and the anvil's half-spread.
    public var heightKm: Double
    public var widthKm: Double
    public var anvilKm: Double

    public init(across: Double, depth: Double, heightKm: Double, widthKm: Double, anvilKm: Double) {
        self.across = across; self.depth = depth; self.heightKm = heightKm; self.widthKm = widthKm; self.anvilKm = anvilKm
    }
}

/// A tower as seen from the plain with the storm at some distance (degrees and km).
public struct TowerView: Equatable {
    /// Its middle's azimuth from the storm's bearing (+ right), its distance, the turret's top and the anvil's base
    /// (altitudes), the turret's half-width and the anvil's half-spread (azimuth).
    public var offset: Double
    public var km: Double
    public var top: Double
    public var anvilBase: Double
    public var halfWidth: Double
    public var anvilHalf: Double
}

public struct StrikeLines {
    // MARK: - The storm's distance (spec §9.1)

    /// The storm stands 40 km out (Distance 0) and comes no nearer than this (overhead).
    public static let farKm = 40.0
    public static let nearestKm = 0.3
    /// Each strike walks it this much closer (2%): 50 strikes bring it to 0.364 of where it was.
    public static let strikeStep = 0.98
    /// Energy, tension and the player's pressure walk it in continuously (a share of the distance a second, at the
    /// Storm pull dial's middle).
    public static let walkEnergy = 0.02, walkTension = 0.06, walkPressure = 0.04
    /// With no note for this long (and none held) you are resting, and it walks back out to 40 km over a minute.
    public static let restAfter = 3.0
    public static let retreatSeconds = 60.0

    // MARK: - The drop: the storm's arrival (spec §5, §9.2)

    /// It walks in to this over 1.5 s; its close strike lands this far off.
    public static let arrivalKm = 1.2
    public static let arrivalSeconds = 1.5
    public static let closeKm = 0.8
    /// The drop lasts 2.5 s: the forced morph and the sheet-lit sky.
    public static let dropSeconds = 2.5
    public static let dropMorph: Float = 0.8
    /// The rain curtain crosses the view in 2.5 s (a passing shower's in 6), and the rain holds, then eases off by 45 s.
    public static let curtainSeconds = 2.5
    public static let showerSeconds = 6.0
    public static let rainSeconds = 45.0
    /// The curtain sets out at most this far off (km), so its crossing reads.
    public static let curtainFarthest = 8.0

    // MARK: - Strikes

    public static let forkLife = 0.6
    public static let cap = 8
    public static let maxForksPerStep = 3
    public static let branchCount = 4...7
    /// The channel's blue-white.
    public static let colour = SIMD3<Float>(0.78, 0.86, 1.0)
    /// A strike closer than 2 km shakes the camera once: at most 6 px, for 0.4 s.
    public static let shakeKm = CicadaHush.closeKm
    public static let shakePixels: Float = 6
    public static let shakeSeconds = 0.4

    // MARK: - Reading the playing

    /// The grand's own repeat rule: the same key again within half a second (and 5 ms of slack), four times.
    public static let repeatGap = 0.505
    public static let repeatStrikes = 4
    /// Three notes inside 45 ms are a chord (a frame's worth more than Excitement's 40 ms); one chord a 0.3 s.
    public static let chordWindow = 0.045
    public static let chordCooldown = 0.3
    /// A run: four notes in a row, each 40–250 ms after the last, none the same key twice running.
    public static let runGaps = 0.04...0.25
    public static let runNotes = 4
    public static let runCooldown = 1.2
    /// The keys span the storm's line this far either side of its bearing (degrees): A0 at the left end, C8 at the right.
    public static let keySpan = 24.0

    // MARK: - The towers' own light

    public static let flashCap = 6
    public static let flashPeak: Float = 0.2
    /// New flickers from notes in one step, at most.
    public static let noteFlashesPerStep = 2
    /// Crawler slots: four, two on Smooth.
    public static func crawlerSlots(_ q: QualityLevel) -> Int { q == .lite ? 2 : AnvilCrawlers.slots }

    // MARK: - Surprises (spec §5)

    /// Ball lightning, a dust devil, the windmill spinning up and stopping, the storm's smell before the rain.
    public static let surpriseCount = 4
    public static let ballSeconds = 10.0
    public static let devilSeconds = 24.0
    public static let petrichorLead = 20.0
    /// The windmill's surprise: a gust spins it up for 9 s, then the tail furls it to a stop until 19 s.
    public static let windmillSpin = 9.0, windmillFurled = 19.0

    /// The storm's line across 45 km of horizon: the mature storm in the middle (16.5 km, its anvil streaming 17 km
    /// downwind over the others), a younger storm on its left, and three towers still building (no anvil yet) at the ends.
    public static let towers: [StormTower] = [
        StormTower(across: -22, depth: 7, heightKm: 8.5, widthKm: 2.6, anvilKm: 0),
        StormTower(across: -11, depth: -2, heightKm: 12.5, widthKm: 3, anvilKm: 6.5),
        StormTower(across: 1, depth: 0, heightKm: 16.5, widthKm: 3.8, anvilKm: 17),
        StormTower(across: 13, depth: 5, heightKm: 10.5, widthKm: 2.8, anvilKm: 4.5),
        StormTower(across: 23, depth: 10, heightKm: 7.5, widthKm: 2.3, anvilKm: 0),
    ]

    /// A tower seen with the storm `stormKm` away: the line's depth offsets close up as it comes (they shrink with the
    /// distance), and the towers spread across the sky and grow up it as they near.
    public static func view(_ t: StormTower, stormKm: Double) -> TowerView {
        let k = stormKm.isFinite ? min(farKm, max(nearestKm, stormKm)) : farKm
        let d = max(0.6, k + t.depth * k / farKm)
        let deg = 180 / Double.pi
        return TowerView(offset: atan2(t.across, d) * deg, km: d, top: atan2(t.heightKm, d) * deg,
                         anvilBase: atan2(0.72 * t.heightKm, d) * deg, halfWidth: atan2(t.widthKm, d) * deg,
                         anvilHalf: atan2(t.anvilKm, d) * deg)
    }

    /// The tower nearest an azimuth offset (degrees from the storm's bearing) with the storm `stormKm` away.
    public static func nearestTower(offset: Double, stormKm: Double) -> Int {
        var best = 0, gap = Double.infinity
        for (i, t) in towers.enumerated() {
            let g = abs(view(t, stormKm: stormKm).offset - offset)
            if g < gap { gap = g; best = i }
        }
        return best
    }

    /// Where a pitch lands across the storm's line (degrees from its bearing): A0 at −24°, C8 at +24°.
    public static func offset(forPitch pitch: Double) -> Double {
        let p = pitch.isFinite ? min(108, max(21, pitch)) : 64
        return -keySpan + 2 * keySpan * (p - 21) / 87
    }

    /// What the world hands the lines each step.
    public struct Inputs {
        public var excitement: ExcitementFrame
        public var sky: SkyState
        /// The storm's bearing (degrees from north): the camera faces it.
        public var bearing: Double
        public var quality: QualityLevel
        /// The Storm pull dial (0…1, 0.5 neutral): how hard energy, tension and pressure walk the storm in.
        public var pull: Double
        /// The instrument's pressure (the grand's morph), 0…1.
        public var pressure: Float
        public var crawlers: SkyExtraMode
        public var sheet: SkyExtraMode
        /// The cicadas' level before any hush (a close strike waits for their silence only while they sing).
        public var cicadas: Double
        /// Strike Lines is the visual (Galaxy Warp streaks instead: no strikes, flickers or crawlers from notes).
        public var striking: Bool

        public init(excitement: ExcitementFrame = .calm, sky: SkyState = SkyState(), bearing: Double = 270,
                    quality: QualityLevel = .high, pull: Double = 0.5, pressure: Float = 0, crawlers: SkyExtraMode = .natural,
                    sheet: SkyExtraMode = .often, cicadas: Double = 0, striking: Bool = true) {
            self.excitement = excitement; self.sky = sky; self.bearing = bearing; self.quality = quality; self.pull = pull
            self.pressure = pressure; self.crawlers = crawlers; self.sheet = sheet; self.cicadas = cicadas
            self.striking = striking
        }
    }

    // MARK: - State

    /// The storm's distance now (km): 40 when it is far, walking in as you play, back out when you rest.
    public internal(set) var km: Double = StrikeLines.farKm
    /// 0 with the storm 40 km out … 1 overhead.
    public var distance: Float { Float(min(1, max(0, 1 - km / Self.farKm))) }
    public private(set) var forks: [Fork] = []
    public private(set) var towerFlash: [TowerFlash] = []
    /// Crawlers across the towers (runs' and the storm's own), lit for this instant, in the sky's (azimuth, altitude).
    public private(set) var crawlers: [CrawlerSlot] = []
    /// Heat lightning on the rim behind the storm (the sheet-lightning machine on the storm's bearing).
    public private(set) var heat: [SheetSlot] = []
    /// The wind over the plain (x across the view, y away from you, metres; m/s).
    public private(set) var wind = WindField(extent: 320, seed: 0x9_1A1E_5F1E)
    public private(set) var windmillRPM: Float = 0
    public private(set) var windmillAngle: Float = 0
    /// How hard the wind drives the windmill now (0…1; the soundscape's windmill level).
    public private(set) var windmillDrive = 0.0
    /// The camera's shake now (pixels).
    public private(set) var shake = SIMD2<Float>(0, 0)
    /// The drop's sheet-lit sky, 0…1 (before any flash limiter).
    public private(set) var sheetLit: Float = 0
    /// The rain curtain: how far it has come (0 none … 1 upon you, and 1 while its rain falls) and how far off it is.
    public private(set) var rainCurtain: Float = 0
    public private(set) var curtainKm: Double?
    /// The storm's rain on you (0…1; the world keeps it off the ground under virga).
    public private(set) var rain: Float = 0
    public private(set) var ball: BallLightning?
    public private(set) var dustDevil: DustDevil?
    /// The storm's smell before a shower (0…0.6; rain on dust).
    public private(set) var petrichor: Float = 0
    /// The outflow after the drop: the wind turned to blow out of the storm (0…1).
    public private(set) var outflow: Float = 0
    public private(set) var hush = CicadaHush()
    /// The thunder of the strikes that landed this step.
    public private(set) var thunder: [QueuedThunder] = []
    /// Forks made so far, and the lines' clock.
    public private(set) var spawned = 0
    public private(set) var time = 0.0
    var nextID = 0

    private var rng = SeededRandom(seed: 0x5717_1CE5_0A1A_1D5E)
    private var heatSky = SheetLightning(seed: 0x9EA7_1197)
    private var bearing = 270.0
    // The playing.
    private var held = Set<UInt8>()
    private var lastNote: UInt8?
    private var lastNoteTime = -1e9
    private var sameCount = 0
    private var lastOnset = -1e9
    private var recent: [(t: Double, note: UInt8)] = []
    private var lastChord = -1e9
    private var chordPitch: Double?
    private var trail: [(t: Double, note: UInt8)] = []
    private var lastRun = -1e9
    private var runPending: (rising: Bool, strength: Float)?
    private var noteFlashes = 0
    // Strikes on their way: due at `at`, or held by the cicadas' hush.
    private struct Request {
        var kind: Fork.Kind
        var at: Double
        var offset: Double
        var km: Double?
        var strength: Float
        var branches: Int?
    }
    private var requests: [Request] = []
    private var heldStrike: Request?
    // The distance's walks.
    private var restFrom: Double?
    private var restAge = 0.0
    private var arrivalFrom: Double?
    private var arrivalAge = 0.0
    // The drop and the curtain.
    private var dropAge: Double?
    private var curtainAge: Double?
    private var curtainSpan = StrikeLines.curtainSeconds
    private var curtainFrom = 8.0
    private var rainPeak: Float = 1
    private var outflowAge: Double?
    private var shakeAge: Double?
    private var shakeAmp: Float = 0
    // The storm's own light and wind.
    private var nextFlash = 1.5
    private var nextCrawler: Double?
    private var live: [CrawlerSlot] = []
    private var nextGust = 3.0
    // Surprises.
    private var windmillSurprise: Double?
    private var petrichorAge: Double?
    private var showered = false

    public init() {}

    /// The morph the storm forces on the grand's voice: .8 for the drop's 2.5 s, else nil.
    public var forcedMorph: Float? {
        if let a = dropAge, a < Self.dropSeconds { return Self.dropMorph }
        return nil
    }

    /// How brightly a key's post is lit by its latest note (0.45 … 0.99): brighter with each repeat of the same key, up
    /// to the sixth.
    public func postBrightness(_ note: UInt8) -> Float {
        guard note == lastNote, sameCount > 1 else { return 0.45 }
        return 0.45 + 0.09 * Float(min(6, sameCount - 1))
    }

    // MARK: - Notes

    /// A key goes down at `t` (the world's clock). `repeating`: the grand hears this key repeated (`instrumentRepeat`);
    /// `striking`: Strike Lines is the visual.
    public mutating func noteOn(_ note: UInt8, velocity: Float, at t: Double, repeating hint: Bool, striking: Bool) {
        let v: Float = velocity.isFinite ? min(1, max(0, velocity)) : 0
        held.insert(note)
        if note == lastNote, t - lastNoteTime <= Self.repeatGap { sameCount += 1 } else { sameCount = 1 }
        lastNote = note
        lastNoteTime = t
        lastOnset = t
        let repeating = sameCount >= Self.repeatStrikes || (hint && sameCount >= 2)

        // A chord: three notes inside 45 ms.
        recent.append((t, note))
        recent.removeAll { t - $0.t > Self.chordWindow + 1e-9 }
        var chord = false
        if recent.count >= 3, t - lastChord >= Self.chordCooldown {
            chord = true
            lastChord = t
            let sum = recent.reduce(0.0) { $0 + Double($1.note) }
            chordPitch = sum / Double(recent.count)
        }
        // A run: four notes in a row, 40–250 ms apart, no key twice running.
        if let previous = trail.last, Self.runGaps.contains(t - previous.t), previous.note != note {
            trail.append((t, note))
        } else {
            trail = [(t, note)]
        }
        if trail.count > 8 { trail.removeFirst(trail.count - 8) }
        if trail.count >= Self.runNotes, t - lastRun >= Self.runCooldown, let first = trail.first {
            lastRun = t
            runPending = (note > first.note, 0.4 + 0.6 * v)
        }

        guard striking else { return }
        if repeating && !chord {
            km = max(Self.nearestKm, km * Self.strikeStep)
            request(.repeated, at: t, offset: Self.offset(forPitch: Double(note)) + Double(rng.range(-1.2, 1.2)),
                    strength: 0.6 + 0.4 * v)
        } else if !chord {
            addNoteFlash(note, velocity: v, at: t)
        }
    }

    public mutating func noteOff(_ note: UInt8) { held.remove(note) }

    public mutating func allNotesOff() {
        held.removeAll()
        sameCount = 0
        lastNote = nil
        trail.removeAll()
        recent.removeAll()
    }

    private mutating func request(_ kind: Fork.Kind, at t: Double, offset: Double, km: Double? = nil, strength: Float,
                                  branches: Int? = nil) {
        requests.append(Request(kind: kind, at: t, offset: offset, km: km, strength: strength, branches: branches))
        if requests.count > 8 { requests.removeFirst(requests.count - 8) }
    }

    /// A note's flicker in the tower over its pitch.
    private mutating func addNoteFlash(_ note: UInt8, velocity v: Float, at t: Double) {
        guard noteFlashes < Self.noteFlashesPerStep else { return }
        noteFlashes += 1
        let offset = Self.offset(forPitch: Double(note))
        let i = Self.nearestTower(offset: offset, stormKm: km)
        let view = Self.view(Self.towers[i], stormKm: km)
        let inside = min(view.offset + 0.8 * view.halfWidth, max(view.offset - 0.8 * view.halfWidth, offset))
        let peak = min(Self.flashPeak, 0.07 + 0.13 * v)
        addFlash(tower: i, view: view, offset: inside, height: Double(rng.range(0.3, 0.7)), radius: Double(rng.range(0.5, 0.85)),
                 duration: Double(0.18 + 0.12 * v), flickers: 1, peak: peak, at: t)
    }

    private mutating func addFlash(tower i: Int, view: TowerView, offset: Double, height: Double, radius: Double,
                                   duration: Double, flickers: Int, peak: Float, at t: Double) {
        let flash = TowerFlash(tower: i, azimuth: bearing + offset, altitude: view.top * height, radius: view.halfWidth * radius,
                               born: t, duration: duration, flickers: max(1, flickers), peak: min(Self.flashPeak, peak), level: 0)
        towerFlash.append(flash)
        if towerFlash.count > Self.flashCap { towerFlash.removeFirst(towerFlash.count - Self.flashCap) }
    }

    // MARK: - Step

    public mutating func step(dt rawDt: Double, now: Double, _ input: Inputs) {
        let dt = rawDt.isFinite ? min(max(rawDt, 0), 0.25) : 0
        time = now.isFinite ? now : time + dt
        bearing = input.bearing.isFinite ? input.bearing : bearing
        thunder.removeAll(keepingCapacity: true)
        noteFlashes = 0
        let e = input.excitement
        let s = input.sky
        let dry = Self.isDry(s)

        // A big moment forks three (a drop is the storm's arrival instead); otherwise this step's chord forks one.
        if input.striking, let m = e.moment {
            lastOnset = time
            if m.isDrop {
                startDrop()
            } else {
                let middle: Double
                if let pitch = chordPitch { middle = Self.offset(forPitch: pitch) } else { middle = Double(rng.range(-12, 12)) }
                for k in 0..<3 {
                    let spread = Double(k - 1) * 13 + Double(rng.range(-3, 3))
                    let at = time + [0, 0.06, 0.13][k]
                    km = max(Self.nearestKm, km * Self.strikeStep)
                    request(.moment, at: at, offset: min(Self.keySpan + 6, max(-Self.keySpan - 6, middle + spread)),
                            strength: 0.7 + 0.3 * m.strength)
                }
            }
        } else if input.striking, let pitch = chordPitch {
            km = max(Self.nearestKm, km * Self.strikeStep)
            request(.chord, at: time, offset: Self.offset(forPitch: pitch) + Double(rng.range(-2, 2)), strength: 0.85)
        }
        chordPitch = nil
        if let surprise = e.surprise { startSurprise(surprise.index, seed: surprise.seed) }

        stepDistance(dt: dt, e, input)

        // Forks age; then those due land (at most three a step; a close one waits for the cicadas' silence).
        forks = forks.compactMap { f -> Fork? in
            var f = f
            f.age += dt
            guard f.age < Self.forkLife else { return nil }
            f.brightness = Self.light(f)
            return f
        }
        var landed = 0
        if let k = hush.step(dt: dt), let r = heldStrike {
            land(r, km: k, dry: dry)
            landed += 1
            heldStrike = nil
        }
        var waiting: [Request] = []
        for r in requests {
            guard r.at <= time + 1e-9, landed < Self.maxForksPerStep else { waiting.append(r); continue }
            var k = 0.0
            if let fixed = r.km { k = fixed } else { k = strikeKm(offset: r.offset) }
            if k < CicadaHush.closeKm, input.cicadas > 0.05 || hush.hushed {
                if hush.strike(atKm: k) {
                    land(r, km: k, dry: dry)
                    landed += 1
                } else if heldStrike == nil {
                    heldStrike = r
                }
            } else {
                land(r, km: k, dry: dry)
                landed += 1
            }
        }
        requests = waiting

        stepTowerFlashes(dt: dt, e)
        stepCrawlers(e, input)
        heat = heatSky.step(dt: dt, mode: input.sheet, eligible: s.sun.altitude < SheetLightning.darkBelow, cloud: s.cloudCover,
                            bearing: bearing, call: input.striking ? e.moment.map { $0.strength } : nil)
        stepDrop(dt: dt)
        stepWind(dt: dt, e, s)
        stepWindmill(dt: dt, e, s)
        stepShake(dt: dt)
        stepSurprises(dt: dt)
    }

    /// Under virga (or with virga gathering): strikes come dry.
    public static func isDry(_ s: SkyState) -> Bool { s.virga.isFinite && s.virga > 0.05 }

    /// How far a strike over `offset` lands (km): from the tower nearest it, give or take 3%.
    private mutating func strikeKm(offset: Double) -> Double {
        let i = Self.nearestTower(offset: offset, stormKm: km)
        let d = Self.view(Self.towers[i], stormKm: km).km
        return max(Self.nearestKm, d * (1 + Double(rng.range(-0.03, 0.03))))
    }

    private mutating func land(_ r: Request, km k: Double, dry: Bool) {
        let span = Self.branchCount.count
        let drawn = Self.branchCount.lowerBound + min(span - 1, Int(rng.unit() * Float(span)))
        let count = r.branches ?? drawn
        let shape = Self.shape(&rng, branches: count)
        let strokes = Self.strokes(&rng, strong: r.kind == .arrival)
        let base = rng.range(1.4, 1.9)
        var fork = Fork(id: nextID, kind: r.kind, azimuth: bearing + r.offset, km: k, baseKm: base, branches: shape, age: 0,
                        brightness: 0, dry: dry, strokes: strokes)
        fork.brightness = Self.light(fork)
        nextID = nextID &+ 1
        spawned += 1
        forks.append(fork)
        if forks.count > Self.cap { forks.removeFirst(forks.count - Self.cap) }
        thunder.append(QueuedThunder.strike(km: k, strength: Double(min(1, max(0.2, r.strength))) * (k < 5 ? 1 : 0.75)))
        if k < Self.shakeKm {
            shakeAge = 0
            shakeAmp = Self.shakePixels * Float(min(1, 0.55 + 0.45 * (1 - k / Self.shakeKm)))
        }
    }

    // MARK: - The fork's shape and light

    /// A fork's channel and branches: the main channel from the cloud base to the ground in 10–14 jagged steps, then the
    /// branches off its upper part, 3–6 segments each, down and outward, ending in the air.
    static func shape(_ r: inout SeededRandom, branches count: Int) -> [[SIMD2<Float>]] {
        let steps = 10 + min(4, Int(r.unit() * 5))
        let drift = r.range(-0.035, 0.035)
        var x = r.range(-0.06, 0.06)
        var main: [SIMD2<Float>] = [SIMD2(x, 1)]
        for k in 1...steps {
            x += drift + r.range(-0.075, 0.075)
            let jitter: Float = k < steps ? r.range(-0.3, 0.3) : 0
            let y: Float = k == steps ? 0 : max(0, 1 - (Float(k) + jitter) / Float(steps))
            main.append(SIMD2(x, y))
        }
        var all = [main]
        let wanted = min(branchCount.upperBound, max(branchCount.lowerBound, count))
        for _ in 1..<wanted {
            let node = 1 + min(steps - 4, Int(r.unit() * Float(steps - 3)))
            var p = main[node]
            let side: Float = r.unit() < 0.5 ? -1 : 1
            let segments = 3 + min(3, Int(r.unit() * 4))
            var branch = [p]
            for _ in 0..<segments {
                p.x += side * r.range(0.03, 0.09)
                p.y -= r.range(0.04, 0.09)
                if p.y < 0.08 { break }
                branch.append(p)
            }
            if branch.count < 2 { branch.append(SIMD2(p.x + side * 0.03, max(0.1, main[node].y - 0.04))) }
            all.append(branch)
        }
        return all
    }

    /// A fork's return strokes: the first at once and the brightest; usually a second 60–100 ms later; sometimes a third.
    /// The arrival always has all three. Four draws whatever happens, so the stream keeps its step.
    static func strokes(_ r: inout SeededRandom, strong: Bool) -> [SIMD2<Float>] {
        let u1 = r.unit(), u2 = r.unit(), u3 = r.unit(), u4 = r.unit()
        var s: [SIMD2<Float>] = [SIMD2(0, 1)]
        if strong || u1 < 0.8 { s.append(SIMD2(0.06 + 0.04 * u2, 0.55 + 0.25 * u3)) }
        if strong || u4 < 0.45 { s.append(SIMD2(0.15 + 0.1 * u2, 0.35 + 0.25 * u4)) }
        return s
    }

    /// A fork's light at its age: each stroke falls away fast (e⁻¹ in 45 ms: the first is all but gone by 120 ms), over
    /// the channel's afterglow (0.12, fading out over its life).
    static func light(_ f: Fork) -> Float {
        let a = Float(f.age)
        var level: Float = 0
        for s in f.strokes {
            let x = a - s.x
            guard x >= 0 else { continue }
            level = max(level, s.y * exp(-x / 0.045))
        }
        let after: Float = 0.12 * max(0, 1 - a / Float(forkLife))
        return min(1, max(level, after))
    }

    // MARK: - The distance

    private mutating func stepDistance(dt: Double, _ e: ExcitementFrame, _ input: Inputs) {
        if let from = arrivalFrom {
            arrivalAge += dt
            let k = Self.smooth(0, Self.arrivalSeconds, arrivalAge)
            km = from * pow(Self.arrivalKm / from, k)
            if arrivalAge >= Self.arrivalSeconds { arrivalFrom = nil; km = Self.arrivalKm }
            restFrom = nil
            return
        }
        let pressure = input.pressure.isFinite ? Double(min(1, max(0, input.pressure))) : 0
        let resting = time - lastOnset >= Self.restAfter && held.isEmpty && pressure < 0.05
        if resting {
            if restFrom == nil { restFrom = km; restAge = 0 }
            restAge += dt
            let from = restFrom ?? km
            km = from * pow(Self.farKm / from, Self.smooth(0, Self.retreatSeconds, restAge))
        } else {
            restFrom = nil
            let pull = 2 * (input.pull.isFinite ? min(1, max(0, input.pull)) : 0.5)
            let energy = Double(e.energy.isFinite ? min(1, max(0, e.energy)) : 0)
            let tension = Double(e.tension.isFinite ? min(1, max(0, e.tension)) : 0)
            let rate = (Self.walkEnergy * energy + Self.walkTension * tension + Self.walkPressure * pressure) * pull
            if rate > 0 { km *= exp(-rate * dt) }
        }
        km = min(Self.farKm, max(Self.nearestKm, km))
    }

    // MARK: - The drop

    private mutating func startDrop() {
        dropAge = 0
        arrivalFrom = km > Self.arrivalKm ? km : nil
        arrivalAge = 0
        startCurtain(seconds: Self.curtainSeconds, peak: 1, from: min(km, Self.curtainFarthest))
        request(.arrival, at: time, offset: Double(rng.range(-14, 14)), km: Self.closeKm, strength: 1, branches: 7)
        // The outflow: a gust front rolls out of the storm through the grass toward you, and the wind turns.
        wind.addGust(from: SIMD2<Float>(0, 130), direction: SIMD2<Float>(0, -1), speed: 24, width: 70, strength: 13)
        outflowAge = 0
    }

    private mutating func startCurtain(seconds: Double, peak: Float, from: Double) {
        curtainAge = 0
        curtainSpan = seconds
        rainPeak = peak
        curtainFrom = max(1, from)
        rainCurtain = 0
        curtainKm = curtainFrom
    }

    /// The drop's sheet-lit sky at `age` seconds: a held glow (0.4) and three surges (at 0, 0.8 and 1.6 s; 15 ms up, e⁻¹
    /// in 0.3 s), over by 2.5 s.
    static func sheetLight(age a: Double) -> Float {
        guard a >= 0, a < dropSeconds else { return 0 }
        let hold = 0.4 * min(1, a / 0.015) * (1 - smooth(2.0, dropSeconds, a))
        var surge = 0.0
        for (at, amp) in [(0.0, 0.6), (0.8, 0.45), (1.6, 0.35)] {
            let x = a - at
            guard x >= 0 else { continue }
            surge = max(surge, amp * min(1, x / 0.015) * exp(-x / 0.3))
        }
        return Float(min(1, hold + surge))
    }

    private mutating func stepDrop(dt: Double) {
        if let a = dropAge {
            let age = a + dt
            dropAge = age < Self.dropSeconds + 1 ? age : nil
            sheetLit = Self.sheetLight(age: age)
        } else {
            sheetLit = 0
        }
        if let a = curtainAge {
            let age = a + dt
            curtainAge = age
            let p = min(1, age / curtainSpan)
            rainCurtain = Float(p)
            // At one pace it would sit on the horizon until the last instant; eased (cubic), it climbs the sky over the
            // first half and sweeps the plain toward you over the second, as a crossing reads.
            let left = 1 - p
            curtainKm = curtainFrom * left * left * left
            if p < 1 {
                rain = rainPeak * Float(Self.smooth(0.85, 1, p))
            } else {
                let r = age - curtainSpan
                rain = rainPeak * Float(1 - Self.smooth(0.4 * Self.rainSeconds, Self.rainSeconds, r))
                if r >= Self.rainSeconds {
                    curtainAge = nil
                    rainCurtain = 0
                    curtainKm = nil
                    rain = 0
                }
            }
        }
        if let a = outflowAge {
            let age = a + dt
            outflow = Float(1 - Self.smooth(10, 40, age))
            outflowAge = age < 40 ? age : nil
        } else {
            outflow = 0
        }
    }

    // MARK: - The towers' flashes and crawlers

    private mutating func stepTowerFlashes(dt: Double, _ e: ExcitementFrame) {
        // Heat lightning inside the towers, quickening with tension and energy.
        let tension = Double(e.tension.isFinite ? min(1, max(0, e.tension)) : 0)
        let energy = Double(e.energy.isFinite ? min(1, max(0, e.energy)) : 0)
        if time >= nextFlash {
            let i = min(Self.towers.count - 1, Int(rng.unit() * Float(Self.towers.count)))
            let view = Self.view(Self.towers[i], stormKm: km)
            let across = view.offset + 0.6 * view.halfWidth * Double(rng.range(-1, 1))
            addFlash(tower: i, view: view, offset: across, height: Double(rng.range(0.25, 0.8)),
                     radius: Double(rng.range(0.4, 0.9)), duration: Double(rng.range(0.15, 0.45)),
                     flickers: 1 + min(2, Int(rng.unit() * 3)), peak: rng.range(0.05, 0.18), at: time)
            let rate = 0.12 + 0.5 * tension + 0.3 * energy
            let u = max(1e-4, Double(rng.unit()))
            nextFlash = time + min(12, -log(u) / rate)
        }
        let now = time
        towerFlash = towerFlash.compactMap { f -> TowerFlash? in
            var f = f
            guard now - f.born <= f.duration else { return nil }
            f.level = Self.flicker(f, at: now)
            return f
        }
    }

    /// A tower flash's light at `t`: its flickers, each a sin² bump, each a little fainter.
    static func flicker(_ f: TowerFlash, at t: Double) -> Float {
        let age = t - f.born
        guard age >= 0, age <= f.duration, f.duration > 0 else { return 0 }
        let n = Double(max(1, f.flickers))
        let x = age / f.duration * n
        let k = x - x.rounded(.down)
        let b = sin(Double.pi * k)
        let fade = 1 - 0.35 * x.rounded(.down) / n
        return f.peak * Float(b * b * fade)
    }

    private mutating func stepCrawlers(_ e: ExcitementFrame, _ input: Inputs) {
        let dc = max(km, 4)
        let deg = 180 / Double.pi
        let band = (atan2(8, dc) * deg)...(atan2(13, dc) * deg)
        // A run sends a crawler across the towers the way it went.
        if let run = runPending {
            runPending = nil
            if input.striking, input.crawlers != .off {
                addCrawler(band: band, rising: run.rising, peak: AnvilCrawlers.dimmest + (AnvilCrawlers.brightest - AnvilCrawlers.dimmest) * run.strength,
                           called: true)
            }
        }
        // And the storm makes its own now and then (Natural: every 60–120 s; 15–45 s under tension; Often: a third).
        let tense = e.tension > 0.5
        func gap(_ u: Float) -> Double {
            let r = tense ? AnvilCrawlers.coreGaps : AnvilCrawlers.gaps
            let g = r.lowerBound + Double(u) * (r.upperBound - r.lowerBound)
            return g / (input.crawlers == .often ? AnvilCrawlers.oftenFactor : 1)
        }
        if input.crawlers == .off {
            nextCrawler = nil
        } else if let next = nextCrawler {
            if time >= next {
                addCrawler(band: band, rising: rng.unit() < 0.5, peak: rng.range(AnvilCrawlers.dimmest, AnvilCrawlers.brightest),
                           called: false)
                nextCrawler = time + gap(rng.unit())
            }
        } else {
            nextCrawler = time + gap(rng.unit())
        }
        let now = time
        live.removeAll { now - $0.born > Double($0.duration) + AnvilCrawlers.fadeSeconds }
        let slots = Self.crawlerSlots(input.quality)
        if live.count > slots { live.removeFirst(live.count - slots) }
        crawlers = live.map { AnvilCrawlers.light($0, at: now) }
    }

    private mutating func addCrawler(band: ClosedRange<Double>, rising: Bool, peak: Float, called: Bool) {
        let segments = Self.crawlerWalk(&rng, bearing: bearing, band: band, rising: rising)
        let size = Double(segments.count - AnvilCrawlers.segmentCount.lowerBound)
            / Double(AnvilCrawlers.segmentCount.upperBound - AnvilCrawlers.segmentCount.lowerBound)
        let r = AnvilCrawlers.durations
        let duration = r.lowerBound + (0.6 * Double(rng.unit()) + 0.4 * min(1, max(0, size))) * (r.upperBound - r.lowerBound)
        live.append(CrawlerSlot(segments: segments, born: time, duration: Float(duration),
                                peak: min(AnvilCrawlers.brightest, max(0, peak)), called: called))
        if live.count > AnvilCrawlers.slots { live.removeFirst(live.count - AnvilCrawlers.slots) }
    }

    /// A crawler across the towers (the Set 17 feature, walked along the storm's line): 6–14 segments of 2–6° each,
    /// creeping along the line in the anvil's band (altitudes, degrees) from one end toward the other (`rising`: left to
    /// right), forking now and then (up to three leaders). The segments' times are their ends' distances along the channel
    /// over the longest, as `AnvilCrawlers` has them.
    static func crawlerWalk(_ r: inout SeededRandom, bearing: Double, band: ClosedRange<Double>, rising: Bool) -> [CrawlerSegment] {
        let span = AnvilCrawlers.segmentCount
        let n = span.lowerBound + min(span.count - 1, Int(r.unit() * Float(span.count)))
        let dir: Double = rising ? 1 : -1
        let startAz = bearing - dir * Double(r.range(14, 24))
        let startAlt = band.lowerBound + Double(r.range(0.2, 0.6)) * (band.upperBound - band.lowerBound)
        var points: [SIMD2<Double>] = [SIMD2(startAz, startAlt)]
        var paths: [Double] = [0]
        var tips: [(node: Int, heading: Double)] = [(0, Double(r.range(-0.3, 0.3)))]
        var links: [(from: Int, to: Int)] = []
        for k in 0..<n {
            let uFork = r.unit(), uNode = r.unit(), uSide = r.unit(), uTip = r.unit()
            let turn = Double(r.range(-0.35, 0.35))
            let length = Double(r.range(Float(AnvilCrawlers.segmentDegrees.lowerBound), Float(AnvilCrawlers.segmentDegrees.upperBound)))
            var which = 0
            if k >= 2, uFork < 0.25, tips.count < 3 {
                let parent = min(points.count - 1, Int(uNode * Float(points.count)))
                tips.append((parent, tips[0].heading + (uSide < 0.5 ? -0.7 : 0.7)))
                which = tips.count - 1
            } else if tips.count > 1, uTip > 0.6 {
                which = 1 + min(tips.count - 2, Int((uTip - 0.6) / 0.4 * Float(tips.count - 1)))
            }
            var h = tips[which].heading + turn
            let from = points[tips[which].node]
            var alt = from.y + length * sin(h)
            if !band.contains(alt) {
                h = -h
                alt = min(band.upperBound, max(band.lowerBound, from.y + length * sin(h)))
            }
            let az = from.x + dir * length * cos(h)
            points.append(SIMD2(az, alt))
            paths.append(paths[tips[which].node] + length)
            links.append((tips[which].node, points.count - 1))
            tips[which] = (points.count - 1, h)
        }
        let longest = max(1e-9, paths.max() ?? 1)
        return links.map { l -> CrawlerSegment in
            let a = points[l.from], b = points[l.to]
            return CrawlerSegment(from: SIMD2(Float(a.x), Float(a.y)), to: SIMD2(Float(b.x), Float(b.y)),
                                  start: Float(paths[l.from] / longest), end: Float(paths[l.to] / longest))
        }
    }

    // MARK: - Wind, windmill, shake

    private mutating func stepWind(dt: Double, _ e: ExcitementFrame, _ s: SkyState) {
        let wind01 = s.wind.isFinite ? min(1, max(0, s.wind)) : 0
        let tension = e.tension.isFinite ? min(1, max(0, e.tension)) : 0
        let energy = e.visualEnergy.isFinite ? min(1, max(0, e.visualEnergy)) : 0
        // Before the storm the inflow blows toward it (away from you, a little to the right); after the drop the outflow
        // blows out of it at you. Tension raises it.
        let inflow = simd_normalize(SIMD2<Float>(0.3, 1)) * (2 + 9 * wind01 + 7 * tension)
        let out = simd_normalize(SIMD2<Float>(-0.15, -1)) * (6 + 9 * wind01)
        wind.set(steady: inflow * (1 - outflow) + out * outflow)
        // Cat's paws roll across the grass with tension, energy and the weather's gusts.
        let gustiness = Double(max(tension, 0.6 * energy, s.gust.isFinite ? min(1, max(0, s.gust)) : 0))
        if gustiness > 0.15, time >= nextGust {
            let fromLeft = rng.unit() < 0.5
            let y = rng.range(15, 140)
            let origin = SIMD2<Float>(fromLeft ? -160 : 160, y)
            let heading = SIMD2<Float>(fromLeft ? 1 : -1, 0.35)
            wind.addGust(from: origin, direction: heading,
                         speed: Float(6 + 8 * gustiness), width: 30, strength: Float(3 + 9 * gustiness), span: 45)
            nextGust = time + max(1.2, 7 - 5 * gustiness) * Double(rng.range(0.7, 1.3))
        }
        wind.step(dt: dt)
    }

    private mutating func stepWindmill(dt: Double, _ e: ExcitementFrame, _ s: SkyState) {
        let tension = Double(e.tension.isFinite ? min(1, max(0, e.tension)) : 0)
        var drive = WeatherAmbience.windmillDrive(s) + 0.55 * tension + 0.5 * Double(outflow)
        if let w = windmillSurprise {
            if w < Self.windmillSpin { drive = 1 } else if w < Self.windmillFurled { drive = 0 }
        }
        drive = min(1, max(0, drive))
        windmillDrive = drive
        let target = Float(60 * WeatherAmbience.windmillGear * WeatherAmbience.windmillRate(drive))
        let tau: Float = target > windmillRPM ? 1 : 2
        if dt > 0 { windmillRPM += (target - windmillRPM) * (1 - exp(-Float(dt) / tau)) }
        if windmillRPM < 1e-4 { windmillRPM = 0 }
        let turn = windmillRPM / 60 * 2 * Float.pi * Float(dt)
        windmillAngle = (windmillAngle + turn).truncatingRemainder(dividingBy: 2 * Float.pi)
    }

    private mutating func stepShake(dt: Double) {
        guard let a = shakeAge else { shake = .zero; return }
        let age = a + dt
        guard age < Self.shakeSeconds else { shakeAge = nil; shake = .zero; return }
        shakeAge = age
        let k = Float(1 - age / Self.shakeSeconds)
        let t = Float(age)
        let swing = shakeAmp * k * k * sin(2 * Float.pi * 19 * t + 0.5)
        let turn = 2 * Float.pi * 3 * t + 1
        shake = SIMD2(cos(turn), sin(turn)) * swing
    }

    // MARK: - Surprises

    private mutating func startSurprise(_ index: Int, seed: UInt64) {
        var r = SeededRandom(seed: seed)
        switch ((index % Self.surpriseCount) + Self.surpriseCount) % Self.surpriseCount {
        case 0:
            let rightward = r.unit() < 0.5
            let a: Float = rightward ? 0.1 : 0.9, b: Float = rightward ? 0.9 : 0.1
            ball = BallLightning(position: a, from: a, to: b, brightness: 0, age: 0)
        case 1:
            let fromLeft = r.unit() < 0.5
            let start = SIMD2<Float>(fromLeft ? -70 : 70, r.range(45, 90))
            let drift = SIMD2<Float>(fromLeft ? 5.5 : -5.5, -0.8)
            wind.addVortex(at: start, radius: 2.5, strength: 11, drift: drift, inflow: 0.3,
                           lifetime: Float(Self.devilSeconds))
            dustDevil = DustDevil(centre: start, level: 0, age: 0)
        case 2:
            windmillSurprise = 0
        default:
            if petrichorAge == nil {
                petrichorAge = 0
                showered = false
            }
        }
    }

    private mutating func stepSurprises(dt: Double) {
        if var b = ball {
            b.age += dt
            if b.age >= Self.ballSeconds {
                ball = nil
            } else {
                let p = Float(b.age / Self.ballSeconds)
                b.position = b.from + (b.to - b.from) * p
                let fade = Self.smooth(0, 0.6, b.age) * (1 - Self.smooth(Self.ballSeconds - 1, Self.ballSeconds, b.age))
                b.brightness = Float(0.75 * fade) * (0.85 + 0.15 * sin(Float(b.age) * 11))
                ball = b
            }
        }
        if var d = dustDevil {
            d.age += dt
            var found: WindField.Vortex?
            for slot in 0..<WindField.maxVortices { if let v = wind.vortex(at: slot) { found = v } }
            if d.age >= Self.devilSeconds || found == nil {
                dustDevil = nil
            } else if let v = found {
                d.centre = v.centre
                d.level = v.level
                dustDevil = d
            }
        }
        if let w = windmillSurprise {
            let age = w + dt
            windmillSurprise = age < Self.windmillFurled ? age : nil
        }
        if let a = petrichorAge {
            let age = a + dt
            petrichorAge = age
            petrichor = Float(0.6 * Self.smooth(0, Self.petrichorLead, age) * (1 - Self.smooth(Self.petrichorLead + 30, Self.petrichorLead + 45, age)))
            if age >= Self.petrichorLead, !showered {
                showered = true
                if curtainAge == nil { startCurtain(seconds: Self.showerSeconds, peak: 0.45, from: 6) }
            }
            if age >= Self.petrichorLead + 45 { petrichorAge = nil; petrichor = 0 }
        }
    }

    // MARK: - Helpers

    /// Smoothstep of `x` from `a` to `b` (either way round), clamped; 0 for NaN.
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard x.isFinite, b != a else { return x >= b ? 1 : 0 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
