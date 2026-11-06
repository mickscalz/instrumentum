import Foundation

/// What the weather adds to any outdoor world's soundscape: drips while things are wet after the rain, and a
/// howling wind in a blizzard's gusts, and birdsong when a rainbow stands; and the hush of rime frost and sea smoke; a
/// gust front's roar and the smell of rain on dust before it rains; virga's dry wind.
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
        // rain (or, under virga, with none at all). The storm family's own sources come with Task 8; until then the rain
        // on dust is set on its reserved source, which the engine ignores.
        if let roar = gustRoar(sky), roar > 0 { levels[.wind] = max(levels[.wind] ?? 0, roar) }
        if let dry = virgaWind(sky), dry > 0 { levels[.wind] = max(levels[.wind] ?? 0, dry) }
        if let dust = rainOnDust(sky), dust > 0 { levels[.rainOnDust] = max(levels[.rainOnDust] ?? 0, dust) }
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
        return 0.15 * min(1, max(rime, steam) / 0.6)
    }
}
