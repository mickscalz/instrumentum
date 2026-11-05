import SwiftUI
import InStrumCore

/// ✦ Visuals → World: the Living Sky's time, place and weather, and the world's ambience.
struct SkyControls: View {
    @ObservedObject var model: AppModel
    @State private var citySearch = ""

    private var sky: SkySettings { model.skySettings }
    private var ambience: AmbienceSettings { model.ambienceSettings }
    /// The lounge is in space: no weather to choose.
    private var hasWeather: Bool { model.themeID != SpaceshipLoungeModel.id }

    private func update(_ change: (inout SkySettings) -> Void) {
        var s = sky
        change(&s)
        model.setSky(s)
    }

    private var cities: [City] { Self.filtered(Cities.all, query: citySearch, keeping: sky.cityID) }

    /// The picker's cities for a search, by name; the selected city always stays in the list so the picker
    /// never loses its selection while you type.
    static func filtered(_ all: [City], query: String, keeping selected: String?) -> [City] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = all.sorted { $0.name < $1.name }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.id == selected || $0.name.lowercased().contains(q) || $0.country.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Time", selection: Binding(get: { sky.timeMode }, set: { m in update { $0.timeMode = m } })) {
                Text("Quick day").tag(TimeMode.quick)
                Text("Real time").tag(TimeMode.realTime)
                Text("Frozen").tag(TimeMode.frozen)
            }
            .pickerStyle(.segmented)

            switch sky.timeMode {
            case .quick:
                labelled("A day lasts \(Int(sky.dayMinutes.rounded())) min") {
                    Slider(value: Binding(get: { sky.dayMinutes }, set: { v in update { $0.dayMinutes = v } }), in: 2...60, step: 1)
                }
            case .frozen:
                labelled("Time \(Self.clock(sky.frozenHour))") {
                    Slider(value: Binding(get: { sky.frozenHour }, set: { v in update { $0.frozenHour = v } }), in: 0...23.99)
                }
                labelled("Moon: \(Self.phaseName(sky.frozenPhase))") {
                    Slider(value: Binding(get: { sky.frozenPhase }, set: { v in update { $0.frozenPhase = v } }), in: 0...1)
                }
            case .realTime:
                Text("The sun, moon and stars as they are right now over your city.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            labelled("City") {
                TextField("Search cities", text: $citySearch).textFieldStyle(.roundedBorder)
                Picker("", selection: Binding(get: { sky.cityID ?? "" }, set: { id in update { $0.cityID = id.isEmpty ? nil : id } })) {
                    Text("Follow my Mac's time zone").tag("")
                    ForEach(cities) { c in Text("\(c.name), \(c.country)").tag(c.id) }
                }
                .labelsHidden()
            }

            if let meteors = model.meteorsTonight {
                Text(meteors).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if hasWeather {
                Picker("Weather", selection: Binding(get: { sky.weatherMode }, set: { m in update { $0.weatherMode = m } })) {
                    Text("Random, beautiful").tag(WeatherMode.randomBeautiful)
                    Text("Pick").tag(WeatherMode.pick)
                }
                .pickerStyle(.segmented)
                if sky.weatherMode == .pick {
                    Picker("", selection: Binding(get: { sky.weather }, set: { w in update { $0.weather = w } })) {
                        ForEach(WeatherKind.allCases, id: \.self) { Text(Self.weatherName($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                DisclosureGroup("Advanced weather") {
                    HStack {
                        Button("Gentle") { update { $0.applyAdvanced(.gentle) } }
                        Button("Dramatic") { update { $0.applyAdvanced(.dramatic) } }
                        Button("Dreamy") { update { $0.applyAdvanced(.dreamy) } }
                    }
                    Button("Reset Advanced to defaults") { update { $0.resetAdvanced() } }
                    DisclosureGroup("Weathers in random") {
                        ForEach(WeatherKind.allCases, id: \.self) { kind in
                            Toggle(Self.weatherName(kind), isOn: Binding(
                                get: { !sky.randomExcluded.contains(kind) },
                                set: { on in update { s in
                                    s.randomExcluded.removeAll { $0 == kind }
                                    if !on { s.randomExcluded.append(kind) }
                                } }))
                        }
                    }
                    Toggle("Calm random weather (no storms, blizzards, hail…)", isOn: Binding(get: { sky.calmRandom }, set: { v in update { $0.calmRandom = v } }))
                    labelled("A picked weather takes \(Int(sky.pickBlendSeconds.rounded())) s to arrive") {
                        Slider(value: Binding(get: { sky.pickBlendSeconds }, set: { v in update { $0.pickBlendSeconds = v } }), in: 1...120, step: 1)
                    }
                    labelled("Random weather blends over \(Int(sky.randomBlendSeconds.rounded())) s") {
                        Slider(value: Binding(get: { sky.randomBlendSeconds }, set: { v in update { $0.randomBlendSeconds = v } }), in: 10...300, step: 5)
                    }
                    labelled("The ground dries over \(Int(sky.dryingMinutes.rounded())) min") {
                        Slider(value: Binding(get: { sky.dryingMinutes }, set: { v in update { $0.dryingMinutes = v } }), in: 2...60, step: 1)
                    }
                    labelled("Wind \(Int((sky.windScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.windScale }, set: { v in update { $0.windScale = v } }), in: 0...2)
                    }
                    labelled("Mist and haze \(Int((sky.mistScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.mistScale }, set: { v in update { $0.mistScale = v } }), in: 0...2)
                    }
                    labelled("Storm flashes \(String(format: "%.1f", sky.lightningFrequency))× as often") {
                        Slider(value: Binding(get: { sky.lightningFrequency }, set: { v in update { $0.lightningFrequency = v } }), in: 0.25...3)
                    }
                    labelled("Moon size \(String(format: "%.1f", sky.moonSize))×") {
                        Slider(value: Binding(get: { sky.moonSize }, set: { v in update { $0.moonSize = v } }), in: 0.5...3)
                    }
                    labelled("Moon's dark side glows \(Int((sky.earthshine * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.earthshine }, set: { v in update { $0.earthshine = v } }), in: 0...0.3)
                    }
                    labelled("Sun size \(String(format: "%.1f", sky.sunSize))×") {
                        Slider(value: Binding(get: { sky.sunSize }, set: { v in update { $0.sunSize = v } }), in: 0.5...3)
                    }
                    labelled("Cloud \(Int((sky.cloudScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.cloudScale }, set: { v in update { $0.cloudScale = v } }), in: 0...1.5)
                    }
                    labelled("Stars \(Int((sky.starScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.starScale }, set: { v in update { $0.starScale = v } }), in: 0...1.5)
                    }
                    labelled("Rain \(Int((sky.rainScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.rainScale }, set: { v in update { $0.rainScale = v } }), in: 0...2)
                    }
                    labelled("Snow \(Int((sky.snowScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.snowScale }, set: { v in update { $0.snowScale = v } }), in: 0...2)
                    }
                    labelled("Gusts \(Int((sky.gustScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.gustScale }, set: { v in update { $0.gustScale = v } }), in: 0...2)
                    }
                    labelled("Halos \(Int((sky.haloScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.haloScale }, set: { v in update { $0.haloScale = v } }), in: 0...1.5)
                    }
                    labelled("Frost \(Int((sky.frostScale * 100).rounded()))%") {
                        Slider(value: Binding(get: { sky.frostScale }, set: { v in update { $0.frostScale = v } }), in: 0...1.5)
                    }
                    labelled("Rainbows \(Int((sky.rainbowStrength * 100).rounded()))% bright") {
                        Slider(value: Binding(get: { sky.rainbowStrength }, set: { v in update { $0.rainbowStrength = v } }), in: 0...1)
                    }
                    labelled("A random spell lasts about \(Int(sky.spellMinutes.rounded())) min") {
                        Slider(value: Binding(get: { sky.spellMinutes }, set: { v in update { $0.spellMinutes = v } }), in: 2...60, step: 1)
                    }
                }
            }

            Divider()
            Toggle("Ambience", isOn: Binding(get: { ambience.enabled }, set: { model.setAmbienceEnabled($0) }))
            if ambience.enabled {
                labelled("Volume \(Int((ambience.volume * 100).rounded()))%") {
                    Slider(value: Binding(get: { ambience.volume }, set: { model.setAmbienceVolume($0) }), in: 0...1)
                }
                labelled(ambience.closeness < 0.35 ? "Distant" : (ambience.closeness > 0.65 ? "All around you" : "Closeness")) {
                    Slider(value: Binding(get: { ambience.closeness }, set: { model.setAmbienceCloseness($0) }), in: 0...1)
                }
            }
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            content()
        }
    }

    static func clock(_ hour: Double) -> String {
        let minutes = Int((hour * 60).rounded()) % (24 * 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The Living Sky panel's "Meteors tonight" line (spec §6.3) for the strongest shower now, or nil with none active:
    /// "Meteors: the Leonids — peak in 13 days; the radiant rises at 01:12".
    /// - The days to the peak count whole days still to go (truncated, so 13.76 reads "13 days": the Leonids show it
    ///   from about 06:30 UT on 4 November). Within a day either side of it they are "at their peak tonight"; then "peak
    ///   tomorrow" or "peaked yesterday", and "peaked N days ago" after that.
    /// - The radiant "stays below your horizon" (it never rises here: the Perseids from Melbourne), "is up now" (10° or
    ///   more), "rises at HH:MM" (on the sky's clock, when it next climbs through 10°), "is up all night" (it never sinks
    ///   below 10°) or "stays low" (it rises, but never clears 10°).
    /// - "Always a shower" is "a steady shower all night".
    nonisolated static func meteorsTonight(_ shower: ShowerNow?) -> String? {
        guard let s = shower else { return nil }
        if s.code == MeteorShowers.always.code { return "Meteors: a steady shower all night" }
        let days = s.daysToPeak.isFinite ? Int(max(-9999, min(9999, s.daysToPeak))) : 0
        let peak: String
        switch days {
        case 2...: peak = "peak in \(days) days"
        case 1: peak = "peak tomorrow"
        case 0: peak = "at their peak tonight"
        case -1: peak = "peaked yesterday"
        default: peak = "peaked \(-days) days ago"
        }
        let radiant: String
        if s.radiantHighest < 0 {
            radiant = "the radiant stays below your horizon"
        } else if s.radiantAltitude >= 10 {
            radiant = "the radiant is up now"
        } else if let rises = s.radiantRises, rises.isFinite {
            let day = 24 * 60
            let minutes = (Int((min(max(rises, -48), 48) * 60).rounded()) % day + day) % day   // 24:00 reads 00:00
            radiant = "the radiant rises at " + String(format: "%02d:%02d", minutes / 60, minutes % 60)
        } else if s.radiantHighest >= 10 {
            radiant = "the radiant is up all night"
        } else {
            radiant = "the radiant stays low"
        }
        return "Meteors: the \(s.name) — \(peak); \(radiant)"
    }

    static func phaseName(_ p: Double) -> String {
        switch p {
        case ..<0.03, 0.97...: return "new"
        case ..<0.22: return "waxing crescent"
        case ..<0.28: return "first quarter"
        case ..<0.47: return "waxing gibbous"
        case ..<0.53: return "full"
        case ..<0.72: return "waning gibbous"
        case ..<0.78: return "last quarter"
        default: return "waning crescent"
        }
    }

    static func weatherName(_ w: WeatherKind) -> String {
        switch w {
        case .clear: return "Clear"
        case .lightCloud: return "Light cloud"
        case .overcast: return "Overcast"
        case .mist: return "Mist"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .storm: return "Storm"
        case .snow: return "Snow"
        case .blizzard: return "Blizzard"
        case .afterRain: return "After the rain"
        case .sunShower: return "Sun-shower"
        case .fogBank: return "Fog bank"
        case .sleet: return "Sleet"
        case .hail: return "Hail"
        case .iceFog: return "Ice fog"
        case .thunderheads: return "Thunderheads"
        case .dustStorm: return "Dust storm"
        case .flurries: return "Snow flurries"
        case .freezingDrizzle: return "Freezing drizzle"
        case .squall: return "Squall"
        case .dryLightning: return "Dry lightning"
        case .smokeHaze: return "Smoke haze"
        case .monsoon: return "Monsoon"
        case .humid: return "Humid night"
        case .diamondDust: return "Diamond dust"
        case .rime: return "Rime frost"
        case .seaSmoke: return "Sea smoke"
        }
    }
}

/// A world's frame, with the sky it draws (its own rules applied: the lounge's has no weather and no meteors), so the
/// canvas can read "Meteors tonight" from whichever world is showing.
protocol SkyBearing { var sky: SkyState { get } }
extension LakeFrame: SkyBearing {}
extension LoungeFrame: SkyBearing {}
extension BeachFrame: SkyBearing {}
extension RoadFrame: SkyBearing {}
extension CabinFrame: SkyBearing {}
extension BedroomFrame: SkyBearing {}
extension FjordFrame: SkyBearing {}
extension BayFrame: SkyBearing {}
extension TeaHouseFrame: SkyBearing {}
extension ZenGardenFrame: SkyBearing {}
extension SubFrame: SkyBearing {}   // Snell's window shows the sky's own meteors
