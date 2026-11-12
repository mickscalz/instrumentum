import Foundation

/// What the weather adds to any outdoor world's soundscape: drips while things are wet after the rain, and a
/// howling wind in a blizzard's gusts, and birdsong when a rainbow stands; and the hush of rime frost and sea smoke; a
/// gust front's roar and the smell of rain on dust before it rains; virga's dry wind; ashfall's dry hiss, and a supercell's
/// roar and hail (Fire & Neon spec §7). And for the plains (Storms spec
/// §9.3): the windmill turning with the wind, and the cicadas' hush before a close strike (`CicadaHush`).
public enum WeatherAmbience {
    public static func levels(_ sky: SkyState, base levels: inout [AmbienceSource: Double]) {
        if sky.rain < 0.05, sky.wetness > 0 { levels[.drips] = Double(sky.wetness) }
        // Birds sing up as the sun comes out through a shower, while the rainbow stands.
        if sky.rainbow > 0.05, sky.rain < 0.5 { levels[.dawnChorus] = max(levels[.dawnChorus] ?? 0, 0.4 * Double(sky.rainbow)) }
        // Rime frost is still, freezing fog, and sea smoke needs still, bitter air: the wind drops (a blizzard's howl,
        // below, still comes through).
        if inRime(sky) || inSeaSmoke(sky), let wind = levels[.wind] { levels[.wind] = min(wind, 0.15) }
        // A humid night is loud with insects; diamond dust is still, cold air (and silent itself).
        if sky.fireflies > 0.3 { levels[.crickets] = max(levels[.crickets] ?? 0, 0.6 * Double(sky.fireflies)) }
        if sky.diamondDust > 0.3, let wind = levels[.wind] { levels[.wind] = min(wind, 0.2) }
        if sky.snow >= 0.9 { levels[.wind] = max(levels[.wind] ?? 0, 0.3 + 0.7 * Double(sky.gust)) }
        // Storms (spec §7): a gust front's roar on the wind, virga's dry wind, and the smell of rain on dust before the
        // rain (or, under virga, with none at all): the petrichor hiss, whose first drops fall only past 0.6 (so near the
        // end of the gust front's Hit, and never under virga's 0.5).
        if let roar = gustRoar(sky), roar > 0 { levels[.wind] = max(levels[.wind] ?? 0, roar) }
        if let dry = virgaWind(sky), dry > 0 { levels[.wind] = max(levels[.wind] ?? 0, dry) }
        if let dust = rainOnDust(sky), dust > 0 { levels[.rainOnDust] = max(levels[.rainOnDust] ?? 0, dust) }
        // Fire & Neon (spec §7): ashfall's faint dry hiss (ash settling on leaves, roofs and glass: the soft hiss of the
        // rain-on-dust source, low); a supercell's roar on the wind and its hail on whatever is near.
        if let hiss = ashHiss(sky), hiss > 0 { levels[.rainOnDust] = max(levels[.rainOnDust] ?? 0, hiss) }
        if let roar = supercellRoar(sky), roar > 0 { levels[.wind] = max(levels[.wind] ?? 0, roar) }
        if sky.hail.isFinite, sky.hail > 0.02 { levels[.hailOnTin] = max(levels[.hailOnTin] ?? 0, 0.8 * Double(sky.hail)) }
    }

    /// Ashfall's hiss (spec §7.1): 0.22 × the ash, faint and dry. Nil without ash.
    public static func ashHiss(_ sky: SkyState) -> Double? {
        guard sky.ash.isFinite, sky.ash > 0.02 else { return nil }
        return 0.22 * Double(min(1, sky.ash))
    }

    /// A supercell's roar on the wind (spec §7.2), × its share of the sky: the inflow rising 0.25 → 0.5 through its
    /// Approach, 0.85 in its Core, easing from 0.5 to 0.1 as it clears. Nil without one.
    public static func supercellRoar(_ sky: SkyState) -> Double? {
        guard let c = sky.supercellWeather, c.amount > 0 else { return nil }
        let p = Double(min(1, max(0, c.stageProgress)))
        let roar: Double
        switch c.stage {
        case .approach: roar = 0.25 + 0.25 * p
        case .core: roar = 0.5 + 0.35 * min(1, 5 * p)
        default: roar = 0.5 - 0.4 * p
        }
        return roar * Double(c.amount)
    }

    /// The gust front's roar on the wind source (spec §7.1), × its share of the sky: 0.2 through the Approach's inflow
    /// gusts, rising 12 dB (×4, to 0.8) as the dust wall crosses at the Hit (evenly in decibels over the crossing), held
    /// through the Hit, then easing to 0.5 as the rain sets in. Nil without a gust front.
    public static func gustRoar(_ sky: SkyState) -> Double? {
        guard let g = sky.gustFront, g.amount > 0 else { return nil }
        let quiet = 0.2, rise = log(4.0)   // ×4 is 12.04 dB
        let roar: Double
        switch g.stage {
        case .approach: roar = quiet
        case .hit: roar = quiet * exp(rise * Double(min(1, max(0, g.dustFront))))
        case .rain: roar = 0.8 - 0.3 * Double(g.rainRamp)
        }
        return roar * Double(g.amount)
    }

    /// Rain on dust, the petrichor (spec §7): under a gust front it rises through the Hit before a drop has fallen (0 → 0.7
    /// over the stage) and eases to 0.3 once the rain has set in; under virga it is there with no rain at all (0.5 ×
    /// virga). Nil with neither.
    public static func rainOnDust(_ sky: SkyState) -> Double? {
        var level: Double?
        if let g = sky.gustFront, g.amount > 0 {
            let p = Double(min(1, max(0, g.stageProgress)))
            switch g.stage {
            case .approach: level = 0
            case .hit: level = 0.7 * p * p * (3 - 2 * p)
            case .rain: level = 0.7 - 0.4 * Double(g.rainRamp)
            }
            level = (level ?? 0) * Double(g.amount)
        }
        if sky.virga.isFinite, sky.virga > 0.05 { level = max(level ?? 0, 0.5 * Double(sky.virga)) }
        return level
    }

    /// Virga's dry wind (spec §7.2): a steady 0.25 with its gusts on top (+0.35 × gust), × virga. Nil without virga.
    public static func virgaWind(_ sky: SkyState) -> Double? {
        guard sky.virga.isFinite, sky.virga > 0.05 else { return nil }
        let gust = sky.gust.isFinite ? Double(min(1, max(0, sky.gust))) : 0
        return (0.25 + 0.35 * gust) * Double(sky.virga)
    }

    /// The windmill's cut-in (spec §9.3): below this drive it stands still.
    public static let windmillCutIn = 0.08
    /// Pump strokes a second in a gale (a drive of 1): 45 a minute.
    public static let windmillMostStrokes = 0.75
    /// The wheel turns this many times a stroke (back-geared, as the steel water pumps are).
    public static let windmillGear = 3.29

    /// How hard the wind drives the windmill (spec §9.3), 0…1: the wind with its gusts on top (+0.3 × gust). A world sets
    /// it as the windmill's level in its soundscape (the engine's pump follows it with the wheel's weight: 2.5 s to spin
    /// up, 5 s to run down) and turns the wheel at `windmillRate(_:)` × `windmillGear` turns a second.
    public static func windmillDrive(_ sky: SkyState) -> Double {
        let wind = sky.wind.isFinite ? Double(sky.wind) : 0, gust = sky.gust.isFinite ? Double(sky.gust) : 0
        return min(1, max(0, wind + 0.3 * gust))
    }

    /// The windmill's pump strokes a second at a drive 0…1, the engine's own law: still below the cut-in (0.08), then
    /// rising evenly to 0.75 (45 a minute) in a gale. In no key: each clank is pitched afresh.
    public static func windmillRate(_ drive: Double) -> Double {
        guard drive.isFinite else { return 0 }
        return windmillMostStrokes * max(0, min(1, drive) - windmillCutIn) / (1 - windmillCutIn)
    }

    /// The windmill's strokes a second under this sky (`windmillRate(windmillDrive(sky))`).
    public static func windmillRate(_ sky: SkyState) -> Double { windmillRate(windmillDrive(sky)) }

    /// In rime: the world is rimed past 0.3, or rime-frost weather is more than 0.3 of the sky.
    public static func inRime(_ sky: SkyState) -> Bool { sky.rime > 0.3 || rimeWeather(sky) > 0.3 }

    /// In sea smoke (spec §5): the steam off the water is past 0.3.
    public static func inSeaSmoke(_ sky: SkyState) -> Bool { sky.steam.isFinite && sky.steam > 0.3 }

    /// How much rime-frost weather is in the sky, 0…1 (the weather machine's smoothstep glide between the kinds).
    public static func rimeWeather(_ sky: SkyState) -> Float {
        let t = sky.weatherBlend.isFinite ? min(max(sky.weatherBlend, 0), 1) : 0, glide = t * t * (3 - 2 * t)
        return sky.weather.values.rime * (1 - glide) + sky.nextWeather.values.rime * glide
    }

    /// Rimed trees and stones soak up sound, and sea smoke lies like a mist over the water, so a world's outdoor
    /// sources come through a little muffled: worlds may add this to their `indoors` (0.15 × min(1, rime / 0.6), or
    /// as much for the steam, whichever is more: the full hush once the world is 0.6 rimed or the sea smoke 0.6 thick).
    public static func indoorsLift(_ sky: SkyState) -> Double {
        let rime = sky.rime.isFinite ? min(max(Double(sky.rime), 0), 1) : 0
        let steam = sky.steam.isFinite ? min(max(Double(sky.steam), 0), 1) : 0
        let ash = sky.ash.isFinite ? min(max(Double(sky.ash), 0), 1) : 0
        // Ash muffles the highs a little (spec §7.1: about 2 dB up top): 0.1 × the ash, through the same window.
        return max(0.15 * min(1, max(rime, steam) / 0.6), 0.1 * ash)
    }
}

/// The dry cicadas stop dead 2 s before a close strike (Storms spec §9.3). A world asks before it lands a strike: a far one
/// (2 km or more) lands at once and leaves them singing; a close one stills them at once and is held until they have been
/// silent for 2 s (the silence before the crack), then lands, and while they are still, close strikes land at once. They
/// sing again 8 s after the last close strike. The engine stops the chorus dead when its level drops to nothing (and
/// brings it back singer by singer), so a world sets the cicadas' level through `level(_:)`.
public struct CicadaHush: Equatable {
    /// Closer than this (km) is a close strike.
    public static let closeKm = 2.0
    /// How long the cicadas are silent before a close strike lands (s).
    public static let lead = 2.0
    /// How long after the last close strike they sing again (s).
    public static let after = 8.0

    /// Seconds the cicadas have been silent; nil while they sing.
    public private(set) var silentFor: Double?
    /// The close strike held for the silence (its distance, km); nil when none is.
    public private(set) var held: Double?
    /// Seconds since the last close strike landed; nil before one has.
    public private(set) var sinceStrike: Double?

    public init() {}

    /// True while the cicadas are silent.
    public var hushed: Bool { silentFor != nil }

    /// A strike `km` off is wanted now. True: it lands now. False: it is close and held, and `step` lands it once the
    /// cicadas have been silent for `lead` seconds (a second close strike asked for meanwhile joins it: the nearer is kept).
    public mutating func strike(atKm km: Double) -> Bool {
        guard km.isFinite, km < Self.closeKm else { return true }
        if let silent = silentFor, silent >= Self.lead - 1e-9, held == nil {
            sinceStrike = 0
            return true
        }
        if silentFor == nil { silentFor = 0 }
        held = min(held ?? km, km)
        return false
    }

    /// Advances by `dt` seconds: the held strike's distance (km) when it lands in this step, else nil.
    public mutating func step(dt: Double) -> Double? {
        guard dt.isFinite, dt > 0, let silent = silentFor else { return nil }
        silentFor = silent + dt
        if let km = held, silent + dt >= Self.lead - 1e-9 {
            held = nil
            sinceStrike = 0
            return km
        }
        if held == nil, let since = sinceStrike {
            if since + dt >= Self.after { silentFor = nil; sinceStrike = nil } else { sinceStrike = since + dt }
        }
        return nil
    }

    /// The cicadas' level for the soundscape: the world's own while they sing, nothing while they are hushed.
    public func level(_ base: Double) -> Double { hushed ? 0 : base }
}
