import XCTest
@testable import InStrumApp
@testable import InStrumCore

final class SkyControlsTests: XCTestCase {
    func testCitySearchKeepsTheSelectedCity() throws {
        let tokyo = try XCTUnwrap(Cities.all.first { $0.id == "tokyo" })
        let melbourne = try XCTUnwrap(Cities.all.first { $0.id == "melbourne" })
        let hits = SkyControls.filtered(Cities.all, query: "tok", keeping: melbourne.id)
        XCTAssertTrue(hits.contains(tokyo))
        XCTAssertTrue(hits.contains(melbourne), "the picker's selection must stay in its list while you search")
        XCTAssertFalse(hits.contains { $0.id == "paris" })
        XCTAssertEqual(SkyControls.filtered(Cities.all, query: "", keeping: nil).count, Cities.all.count)
        XCTAssertEqual(SkyControls.filtered(Cities.all, query: "zzzz", keeping: melbourne.id), [melbourne])
        // Sorted by name, with the search matched on the country too.
        let names = SkyControls.filtered(Cities.all, query: "australia", keeping: nil).map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertTrue(names.contains("Melbourne"))
    }

    func testWeatherNames() {
        let names = WeatherKind.allCases.map(SkyControls.weatherName)
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(SkyControls.weatherName(.blizzard), "Blizzard")
        XCTAssertEqual(SkyControls.weatherName(.sunShower), "Sun-shower")
        XCTAssertEqual(SkyControls.weatherName(.fogBank), "Fog bank")
        XCTAssertEqual(SkyControls.weatherName(.sleet), "Sleet")
        XCTAssertEqual(SkyControls.weatherName(.hail), "Hail")
        XCTAssertEqual(SkyControls.weatherName(.iceFog), "Ice fog")
        XCTAssertEqual(SkyControls.weatherName(.thunderheads), "Thunderheads")
        XCTAssertEqual(SkyControls.weatherName(.dustStorm), "Dust storm")
        XCTAssertEqual(SkyControls.weatherName(.flurries), "Snow flurries")
        XCTAssertEqual(SkyControls.weatherName(.freezingDrizzle), "Freezing drizzle")
        XCTAssertEqual(SkyControls.weatherName(.squall), "Squall")
        XCTAssertEqual(SkyControls.weatherName(.dryLightning), "Dry lightning")
        XCTAssertEqual(SkyControls.weatherName(.smokeHaze), "Smoke haze")
        XCTAssertEqual(SkyControls.weatherName(.monsoon), "Monsoon")
        XCTAssertEqual(SkyControls.weatherName(.afterRain), "After the rain")
        XCTAssertEqual(SkyControls.weatherName(.humid), "Humid night")
        XCTAssertEqual(SkyControls.weatherName(.diamondDust), "Diamond dust")
        XCTAssertEqual(SkyControls.weatherName(.rime), "Rime frost")
        XCTAssertEqual(SkyControls.weatherName(.seaSmoke), "Sea smoke")
        XCTAssertEqual(names.last, "Sea smoke")
    }

    /// The Living Sky panel's "Meteors tonight" line (spec §6.3): the strongest shower now, the whole days still to go to
    /// its peak, and when its radiant clears 10° on the sky's clock; nothing with no shower active.
    func testMeteorsTonightLine() throws {
        XCTAssertNil(SkyControls.meteorsTonight(nil))
        // The Leonids on 4 November 2026 at 12:00 UT: 13.76 days to go reads "13 days". They are not active yet (from λ⊙
        // 223.21°, on the 6th), so the shower is built here as a sky would show it, its radiant rising at 01:12.
        let leo = try XCTUnwrap(MeteorShowers.shower(code: "LEO"))
        let noon = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z"))
        let days = leo.daysToPeak(from: SolarLongitude.degrees(at: noon))
        XCTAssertEqual(days, 13.76, accuracy: 0.01)
        func line(days: Double, altitude: Double = -20, rises: Double? = 1.2, highest: Double = 50) -> String? {
            SkyControls.meteorsTonight(ShowerNow(code: leo.code, name: leo.name, zhr: 15, radiantAltitude: altitude,
                                                 radiantAzimuth: 60, daysToPeak: days, radiantRises: rises,
                                                 radiantHighest: highest))
        }
        XCTAssertEqual(line(days: days), "Meteors: the Leonids — peak in 13 days; the radiant rises at 01:12")
        // The peak in whole days: tonight within a day either side of it.
        XCTAssertEqual(line(days: 1.6), "Meteors: the Leonids — peak tomorrow; the radiant rises at 01:12")
        for d in [0.99, 0.2, 0, -0.4, -0.99] {
            XCTAssertEqual(line(days: d), "Meteors: the Leonids — at their peak tonight; the radiant rises at 01:12", "\(d)")
        }
        XCTAssertEqual(line(days: -1.5), "Meteors: the Leonids — peaked yesterday; the radiant rises at 01:12")
        XCTAssertEqual(line(days: -3.2), "Meteors: the Leonids — peaked 3 days ago; the radiant rises at 01:12")
        XCTAssertEqual(line(days: .nan), "Meteors: the Leonids — at their peak tonight; the radiant rises at 01:12")
        // The radiant: up now (10° or more), rising (24:00 reads 00:00), up all night, low, or never up at all.
        XCTAssertEqual(line(days: days, altitude: 25), "Meteors: the Leonids — peak in 13 days; the radiant is up now")
        XCTAssertEqual(line(days: days, rises: 23.999), "Meteors: the Leonids — peak in 13 days; the radiant rises at 00:00")
        XCTAssertEqual(line(days: days, rises: 21.75), "Meteors: the Leonids — peak in 13 days; the radiant rises at 21:45")
        XCTAssertEqual(line(days: days, rises: nil, highest: 70), "Meteors: the Leonids — peak in 13 days; the radiant is up all night")
        XCTAssertEqual(line(days: days, rises: nil, highest: 6), "Meteors: the Leonids — peak in 13 days; the radiant stays low")
        XCTAssertEqual(line(days: days, rises: nil, highest: -5.8),
                       "Meteors: the Leonids — peak in 13 days; the radiant stays below your horizon")
        // Always a shower.
        let steady = MeteorShowers.always
        XCTAssertEqual(SkyControls.meteorsTonight(ShowerNow(code: steady.code, name: steady.name, zhr: 60, radiantAltitude: 80,
                                                            radiantAzimuth: 0, daysToPeak: 0, radiantRises: nil, radiantHighest: 90)),
                       "Meteors: a steady shower all night")
        // The Perseids from a real Melbourne sky at their peak (22:00 on 12 August 2026): the radiant never rises there.
        var settings = SkySettings(); settings.timeMode = .realTime; settings.cityID = "melbourne"
        settings.weatherMode = .pick; settings.weather = .clear
        let sky = LivingSky(settings: settings)
        let night = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z"))
        let state = sky.step(now: night, dt: 0)
        XCTAssertEqual(state.shower?.code, "PER")
        XCTAssertEqual(SkyControls.meteorsTonight(state.shower),
                       "Meteors: the Perseids — at their peak tonight; the radiant stays below your horizon")
    }
}
