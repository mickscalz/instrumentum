import Foundation

// Excitement: variables for every world (Fire & Neon spec §5, docs/superpowers/specs/2026-11-05-fire-and-neon-design.md).
// One machine reads how you play and hands every world four things: Energy (how hard and fast you're playing, rising
// fast and settling slowly), Big moments (a hard chord or a crescendo sets off the world's signature event), Surprises
// (rare, seeded, never twice running) and Build and drop (climbing or swelling playing builds tension; a big moment on
// top of it is a drop). Its numbers were tuned on a Python mirror (Scripts/excitement-mirror.py), run on the same
// performances as ExcitementTests.

/// The Excitement controls (the scene panel and All settings). Every field decodes with its default, so older saves load.
public struct ExcitementSettings: Codable, Equatable {
    public enum Moments: String, Codable, CaseIterable { case off, some, lots }
    public enum Surprises: String, Codable, CaseIterable { case off, rare, often }

    /// Energy read from your playing (true) or set by hand (`manualEnergy`).
    public var autoEnergy: Bool
    public var manualEnergy: Float
    public var moments: Moments
    public var surprises: Surprises
    public var buildAndDrop: Bool

    public init(autoEnergy: Bool = true, manualEnergy: Float = 0.5, moments: Moments = .some, surprises: Surprises = .rare,
                buildAndDrop: Bool = true) {
        self.autoEnergy = autoEnergy; self.manualEnergy = manualEnergy; self.moments = moments
        self.surprises = surprises; self.buildAndDrop = buildAndDrop
    }

    private enum CodingKeys: String, CodingKey { case autoEnergy, manualEnergy, moments, surprises, buildAndDrop }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExcitementSettings()
        autoEnergy = try c.decodeIfPresent(Bool.self, forKey: .autoEnergy) ?? d.autoEnergy
        manualEnergy = try c.decodeIfPresent(Float.self, forKey: .manualEnergy) ?? d.manualEnergy
        moments = (try? c.decodeIfPresent(Moments.self, forKey: .moments)) ?? d.moments
        surprises = (try? c.decodeIfPresent(Surprises.self, forKey: .surprises)) ?? d.surprises
        buildAndDrop = try c.decodeIfPresent(Bool.self, forKey: .buildAndDrop) ?? d.buildAndDrop
    }
}

/// A world's signature event is due: a hard chord or a crescendo, at a strength (0.3…1).
public struct BigMoment: Equatable {
    public enum Kind: Equatable { case chord, crescendo }
    public var kind: Kind
    public var strength: Float
    /// The chord's mean pitch was below C3 (48): the volcano erupts on these.
    public var low: Bool
    /// It landed on built-up tension: the world plays its release.
    public var isDrop: Bool
}

/// One of a world's own surprises is due: `index` into its list, with a seed for its details.
public struct WorldSurprise: Equatable {
    public var index: Int
    public var seed: UInt64
}

/// What a world reads each step.
public struct ExcitementFrame: Equatable {
    public var energy: Float = 0
    /// Energy for drawing: capped at 0.5 under Reduce Motion.
    public var visualEnergy: Float = 0
    public var tension: Float = 0
    /// 1 at a drop, falling to 0 over 2.5 s: the release.
    public var drop: Float = 0
    /// Set for exactly one step when a moment fires.
    public var moment: BigMoment?
    /// Set for exactly one step when a surprise is due.
    public var surprise: WorldSurprise?
    /// The Mac's Reduce Motion is on: worlds shake no camera and cap their fastest motion (Storms spec §5).
    public var reduceMotion = false
    public init() {}
    public static let calm = ExcitementFrame()
}

/// A world that answers Excitement.
public protocol ExcitementAware {
    mutating func setExcitement(_ e: ExcitementFrame)
}

/// A world's own surprises (how many it has; the index in a `WorldSurprise` picks one).
public protocol SurpriseListing {
    static var surpriseCount: Int { get }
}

public struct Excitement {
    public var settings = ExcitementSettings()
    /// Gentle visuals: big moments no more than Some, surprises no more than Rare.
    public var gentle = false
    /// Reduce Motion: `visualEnergy` capped at 0.5.
    public var reduceMotion = false
    /// Hold the Moment: nothing changes and nothing fires.
    public var holding = false
    /// Sleep Fade: no moments and no surprises.
    public var sleeping = false
    public private(set) var frame = ExcitementFrame()

    // Tuned values (spec §5.1–§5.4).
    public static let rateTau = 0.5, riseTau = 0.25, fallTau = 4.0, silence = 3.0, window = 2.0
    public static let chordWindow = 0.040, lowPitch = 48.0
    public static func threshold(_ m: ExcitementSettings.Moments) -> Double { m == .lots ? 0.65 : 0.78 }
    public static func cooldown(_ m: ExcitementSettings.Moments) -> Double { m == .lots ? 2.5 : 6.0 }
    public static let crescendoRise = 0.35, crescendoLevel = 0.75, crescendoWindow = 3.0
    public static let tensionRise = 0.35, tensionFall = 0.08, dropAt = 0.6, dropSeconds = 2.5
    public static let climbSemitones = 4.0, climbWindow = 2.0, swellSlope = 0.05
    public static func surpriseMean(_ s: ExcitementSettings.Surprises) -> Double { s == .often ? 75 : 240 }
    public static func surpriseGap(_ s: ExcitementSettings.Surprises) -> Double { s == .often ? 30 : 90 }
    public static let playedWithin = 20.0

    private var time = 0.0
    private var onsets: [(t: Double, note: Int, velocity: Double)] = []
    private var held = Set<Int>()
    private var rate = 0.0
    private var energy = 0.0
    private var lastNoteOn = -1e9, lastMoment = -1e9, lastPlayed = -1e9
    private var energyHistory: [(t: Double, e: Double)] = []
    private var recentPitches: [Int] = []
    private var pitchHistory: [(t: Double, mean: Double)] = []
    private var tension = 0.0, drop = 0.0
    private var pending: BigMoment?
    private var rng: SeededRandom
    private var nextSurprise: Double
    private var lastSurprise = -1

    public init(seed: UInt64 = 0xE7C1_7E5E_ED00_0001) {
        rng = SeededRandom(seed: seed)
        nextSurprise = 0
        nextSurprise = scheduleAfter(0)
    }

    private var momentsNow: ExcitementSettings.Moments {
        if sleeping { return .off }
        return gentle && settings.moments == .lots ? .some : settings.moments
    }
    private var surprisesNow: ExcitementSettings.Surprises {
        if sleeping { return .off }
        return gentle && settings.surprises == .often ? .rare : settings.surprises
    }

    // ---------- Notes ----------

    /// A key goes down (velocity 0…1).
    public mutating func noteOn(_ note: Int, velocity: Float) {
        held.insert(note)
        if holding { return }
        let v = Double(min(max(velocity, 0), 1))
        onsets.append((time, note, v))
        if onsets.count > 128 { onsets.removeFirst(onsets.count - 128) }
        rate += 1 / Self.rateTau
        lastNoteOn = time
        recentPitches.append(note)
        if recentPitches.count > 8 { recentPitches.removeFirst() }
        let m = momentsNow
        guard m != .off else { return }
        let chord = onsets.filter { time - $0.t <= Self.chordWindow + 1e-9 }
        guard chord.count >= 3 else { return }
        let mean = chord.map(\.velocity).reduce(0, +) / Double(chord.count)
        let th = Self.threshold(m)
        guard mean >= th, time - lastMoment >= Self.cooldown(m) else { return }
        let pitch = Double(chord.map(\.note).reduce(0, +)) / Double(chord.count)
        fire(.chord, strength: max(0.3, (mean - th) / (1 - th)), low: pitch < Self.lowPitch)
    }

    /// A key comes up.
    public mutating func noteOff(_ note: Int) { held.remove(note) }

    private mutating func fire(_ kind: BigMoment.Kind, strength: Double, low: Bool) {
        let isDrop = settings.buildAndDrop && tension > Self.dropAt
        if isDrop { tension = 0; drop = 1 }
        pending = BigMoment(kind: kind, strength: Float(min(1, strength)), low: low, isDrop: isDrop)
        lastMoment = time
    }

    // ---------- Time ----------

    /// Advances by `dt` seconds (the scene's visual time) and returns the frame for this step. `surpriseCount` is the
    /// world's own list (0: none).
    @discardableResult
    public mutating func step(dt: Double, surpriseCount: Int = 0) -> ExcitementFrame {
        if holding {
            frame.moment = nil
            frame.surprise = nil
            return frame
        }
        guard dt > 0 else { return frame }
        time += dt
        rate *= exp(-dt / Self.rateTau)
        onsets.removeAll { time - $0.t > Self.window }
        // Energy (spec §5.1).
        let vbar = onsets.isEmpty ? 0 : onsets.map(\.velocity).reduce(0, +) / Double(onsets.count)
        let size = min(1, max(0, Double(held.count - 1) / 7))
        var raw = 0.45 * vbar + 0.35 * min(1, rate / 8) + 0.20 * size
        if time - lastNoteOn >= Self.silence { raw = 0 }
        let tau = raw > energy ? Self.riseTau : Self.fallTau
        energy += (1 - exp(-dt / tau)) * (raw - energy)
        if energy < 1e-4 { energy = 0 }
        if energy > 0.1 { lastPlayed = time }
        energyHistory.append((time, energy))
        energyHistory.removeAll { time - $0.t > Self.crescendoWindow }
        // A crescendo (spec §5.2).
        let m = momentsNow
        if m != .off, energy >= Self.crescendoLevel, time - lastMoment >= Self.cooldown(m),
           let low = energyHistory.map(\.e).min(), energy - low >= Self.crescendoRise {
            fire(.crescendo, strength: energy, low: false)
        }
        // Tension (spec §5.4): climbing pitch, or a swell in energy.
        let mean = recentPitches.isEmpty ? 0 : Double(recentPitches.reduce(0, +)) / Double(recentPitches.count)
        pitchHistory.append((time, mean))
        pitchHistory.removeAll { time - $0.t > Self.climbWindow }
        let climbing = pitchHistory.count > 1 && time - pitchHistory[0].t >= 1.0 && time - lastNoteOn < 0.5
            && mean - pitchHistory[0].mean > Self.climbSemitones
        let secondAgo = energyHistory.last { time - $0.t >= 0.9 }
        let swelling = secondAgo.map { energy - $0.e > Self.swellSlope } ?? false
        if settings.buildAndDrop, climbing || swelling { tension = min(1, tension + Self.tensionRise * dt) }
        else { tension = max(0, tension - Self.tensionFall * dt) }
        drop = max(0, drop - dt / Self.dropSeconds)
        // Surprises (spec §5.3).
        var surprise: WorldSurprise?
        let s = surprisesNow
        if s != .off, surpriseCount > 0, time >= nextSurprise {
            if time - lastPlayed <= Self.playedWithin {
                var index = Int(rng.next() % UInt64(surpriseCount))
                if surpriseCount > 1, index == lastSurprise { index = (index + 1 + Int(rng.next() % UInt64(surpriseCount - 1))) % surpriseCount }
                lastSurprise = index
                surprise = WorldSurprise(index: index, seed: rng.next())
                nextSurprise = scheduleAfter(time)
            } else {
                nextSurprise = time + 5   // a parked world stays calm: look again in a moment
            }
        }
        // The frame.
        let e = settings.autoEnergy ? Float(energy) : min(max(settings.manualEnergy, 0), 1)
        frame.energy = e
        frame.visualEnergy = reduceMotion ? min(e, 0.5) : e
        frame.reduceMotion = reduceMotion
        frame.tension = Float(tension)
        frame.drop = Float(drop)
        frame.moment = pending
        frame.surprise = surprise
        pending = nil
        return frame
    }

    private mutating func scheduleAfter(_ t: Double) -> Double {
        let s = surprisesNow == .off ? ExcitementSettings.Surprises.rare : surprisesNow
        let gap = Self.surpriseGap(s), mean = Self.surpriseMean(s)
        let u = max(1e-6, Double(rng.unit()))
        return t + gap + -log(u) * (mean - gap)
    }
}
