import XCTest
@testable import InStrumCore

final class DeckControllerTests: XCTestCase {
    private func cc(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> MIDIMessage {
        .controlChange(channel: channel, controller: controller, value: value)
    }

    func testRecognisesTheControllerByName() {
        XCTAssertTrue(DDJErgoDecoder.isController(sourceName: "PIONEER DDJ-ERGO"))
        XCTAssertTrue(DDJErgoDecoder.isController(sourceName: "DDJ-ERGO"))
        XCTAssertFalse(DDJErgoDecoder.isController(sourceName: "Keystation 88"))
    }

    func testMixerKnobsBySide() {
        var d = DDJErgoDecoder()
        // Deck A's HI is controller 7 on the mixer's channel; fully right is 127 coarse and 127 fine.
        XCTAssertEqual(d.decode(cc(6, 7, 127)), .knob(DeckControl(.left, .hi), Double(127 << 7) / 16383))
        XCTAssertEqual(d.decode(cc(6, 39, 127)), .knob(DeckControl(.left, .hi), 1))
        XCTAssertEqual(d.decode(cc(6, 8, 0)), .knob(DeckControl(.right, .hi), 0))
        XCTAssertEqual(d.decode(cc(6, 12, 0)), .knob(DeckControl(.right, .mid), 0))
        XCTAssertEqual(d.decode(cc(6, 15, 0)), .knob(DeckControl(.left, .low), 0))
        XCTAssertEqual(d.decode(cc(6, 28, 0)), .knob(DeckControl(.right, .filter), 0))
        // Decks C and D are the same sides (a fresh decoder: the left HI's fine half above is remembered).
        d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(cc(6, 9, 0)), .knob(DeckControl(.left, .hi), 0))
        XCTAssertEqual(d.decode(cc(6, 18, 0)), .knob(DeckControl(.right, .low), 0))
    }

    func testEffectBoxKnobsWithDeckAndShift() {
        var d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(cc(4, 0, 0)), .knob(DeckControl(.left, .fxControl), 0))
        XCTAssertEqual(d.decode(cc(4, 2, 0)), .knob(DeckControl(.left, .fx1), 0))
        XCTAssertEqual(d.decode(cc(5, 4, 0)), .knob(DeckControl(.right, .fx2), 0))
        XCTAssertEqual(d.decode(cc(5, 6, 0)), .knob(DeckControl(.right, .fx3), 0))
        XCTAssertEqual(d.decode(cc(4, 10, 0)), .knob(DeckControl(.left, .fx1), 0))    // deck C
        XCTAssertEqual(d.decode(cc(5, 22, 0)), .knob(DeckControl(.right, .fx3), 0))   // SHIFT
        XCTAssertEqual(d.decode(cc(4, 24, 0)), .knob(DeckControl(.left, .fxControl), 0))   // deck C with SHIFT
    }

    func testCentreIsHalf() {
        var d = DDJErgoDecoder()
        _ = d.decode(cc(6, 11, 64))
        let event = d.decode(cc(6, 43, 0))
        guard case let .knob(control, value)? = event else { return XCTFail("no knob") }
        XCTAssertEqual(control, DeckControl(.left, .mid))
        XCTAssertEqual(value, 0.5, accuracy: 0.001)
    }

    func testFineHalfAloneSaysNothing() {
        var d = DDJErgoDecoder()
        XCTAssertNil(d.decode(cc(6, 39, 50)))
    }

    func testWhatMeansNothingIsIgnoredAndTheUnmappedIsReported() {
        var d = DDJErgoDecoder()
        XCTAssertNil(d.decode(.noteOff(channel: 4, note: 67)))                  // a button coming up
        XCTAssertNil(d.decode(.noteOn(channel: 0, note: 54, velocity: 127)))    // a hand on the left jog wheel
        XCTAssertNil(d.decode(.noteOn(channel: 3, note: 114, velocity: 127)))   // the DECK button
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 1, velocity: 127)), .unknown("button 1 on channel 7"))
        XCTAssertEqual(d.decode(cc(6, 90, 1)), .unknown("controller 90 on channel 7"))
    }

    func testFadersSlidersAndCentreKnobs() {
        var d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(cc(6, 0, 0)), .knob(DeckControl(.centre, .master), 0))
        XCTAssertEqual(d.decode(cc(6, 1, 0)), .knob(DeckControl(.centre, .headphonesMix), 0))
        XCTAssertEqual(d.decode(cc(6, 2, 0)), .knob(DeckControl(.centre, .headphonesVolume), 0))
        XCTAssertEqual(d.decode(cc(6, 3, 0)), .knob(DeckControl(.left, .gain), 0))
        XCTAssertEqual(d.decode(cc(6, 4, 0)), .knob(DeckControl(.right, .gain), 0))
        XCTAssertEqual(d.decode(cc(6, 19, 0)), .knob(DeckControl(.left, .fader), 0))
        XCTAssertEqual(d.decode(cc(6, 21, 0)), .knob(DeckControl(.right, .fader), 0))
        XCTAssertEqual(d.decode(cc(6, 20, 0)), .knob(DeckControl(.centre, .auxVolume), 0))
        XCTAssertEqual(d.decode(cc(6, 31, 127)), .knob(DeckControl(.centre, .crossfader), Double(127 << 7) / 16383))
        XCTAssertEqual(d.decode(cc(6, 63, 127)), .knob(DeckControl(.centre, .crossfader), 1))
        // The TEMPO sliders are on the decks' own channels (with SHIFT: controller 5).
        XCTAssertEqual(d.decode(cc(0, 0, 0)), .knob(DeckControl(.left, .tempo), 0))
        XCTAssertEqual(d.decode(cc(1, 5, 0)), .knob(DeckControl(.right, .tempo), 0))
        XCTAssertEqual(d.decode(cc(2, 0, 0)), .knob(DeckControl(.left, .tempo), 0))   // deck C
    }

    func testRotariesCountClicks() {
        var d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(cc(6, 64, 1)), .turn(DeckWheel(.centre, .browse), 1))
        XCTAssertEqual(d.decode(cc(6, 64, 127)), .turn(DeckWheel(.centre, .browse), -1))
        XCTAssertEqual(d.decode(cc(6, 100, 3)), .turn(DeckWheel(.centre, .browse), 3))     // SHIFT
        XCTAssertEqual(d.decode(cc(0, 19, 2)), .turn(DeckWheel(.left, .loop), 2))
        XCTAssertEqual(d.decode(cc(1, 19, 126)), .turn(DeckWheel(.right, .loop), -2))
    }

    func testJogWheelsCountTurns() {
        var d = DDJErgoDecoder()
        // Clockwise: coarse 0, fine the count. 2430 counts are one turn, worth eight units.
        XCTAssertNil(d.decode(cc(0, 2, 0)))
        guard case let .turn(wheel, units)? = d.decode(cc(0, 34, 10)) else { return XCTFail("no turn") }
        XCTAssertEqual(wheel, DeckWheel(.left, .jog), "controller 2 is the top of the wheel")
        XCTAssertEqual(units, 10.0 / 2430 * 8, accuracy: 1e-9)
        // Counter-clockwise counts down from 16383.
        XCTAssertNil(d.decode(cc(1, 1, 127)))
        guard case let .turn(other, back)? = d.decode(cc(1, 33, 125)) else { return XCTFail("no turn") }
        XCTAssertEqual(other, DeckWheel(.right, .search), "controller 1 is its outer edge")
        XCTAssertEqual(back, -3.0 / 2430 * 8, accuracy: 1e-9)
    }

    func testDeckAndMixerButtons() {
        var d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 11, velocity: 127)), .press(.left, .play))
        XCTAssertEqual(d.decode(.noteOn(channel: 1, note: 12, velocity: 127)), .press(.right, .cue))
        XCTAssertEqual(d.decode(.noteOn(channel: 2, note: 88, velocity: 127)), .press(.left, .sync))      // deck C
        XCTAssertEqual(d.decode(.noteOn(channel: 3, note: 16, velocity: 127)), .press(.right, .loopIn))   // deck D
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 17, velocity: 127)), .press(.left, .loopOut))
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 20, velocity: 127)), .press(.left, .loopPress))
        XCTAssertEqual(d.decode(.noteOn(channel: 1, note: 46, velocity: 127)), .press(.right, .hotCue1))
        XCTAssertEqual(d.decode(.noteOn(channel: 1, note: 98, velocity: 127)), .press(.right, .hotCue4))  // SHIFT
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 62, velocity: 127)), .press(.left, .sampler2))
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 26, velocity: 127)), .press(.left, .keylock))
        XCTAssertEqual(d.decode(.noteOn(channel: 0, note: 21, velocity: 127)), .press(.left, .vinyl))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 65, velocity: 127)), .press(.centre, .browsePress))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 70, velocity: 127)), .press(.left, .load))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 71, velocity: 127)), .press(.right, .load))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 85, velocity: 127)), .press(.right, .headphoneCue))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 76, velocity: 127)), .press(.left, .assignFX1))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 81, velocity: 127)), .press(.right, .assignFX2))
        XCTAssertEqual(d.decode(.noteOn(channel: 6, note: 101, velocity: 127)), .press(.centre, .function))
    }

    func testEffectBoxButtons() {
        var d = DDJErgoDecoder()
        XCTAssertEqual(d.decode(.noteOn(channel: 4, note: 67, velocity: 127)), .press(.left, .on))
        XCTAssertEqual(d.decode(.noteOn(channel: 5, note: 71, velocity: 127)), .press(.right, .one))
        XCTAssertEqual(d.decode(.noteOn(channel: 4, note: 76, velocity: 127)), .press(.left, .two))     // deck C
        XCTAssertEqual(d.decode(.noteOn(channel: 5, note: 101, velocity: 127)), .press(.right, .three)) // SHIFT
    }

    func testLights() {
        XCTAssertEqual(DDJErgoDecoder.light(.left, .on, on: true), [[0x94, 67, 127], [0x94, 74, 127]])
        XCTAssertEqual(DDJErgoDecoder.light(.right, .two, on: false), [[0x95, 72, 0], [0x95, 76, 0]])
        XCTAssertEqual(DDJErgoDecoder.light(.left, .play, on: true), [[0x90, 11, 127], [0x92, 11, 127]])
        XCTAssertEqual(DDJErgoDecoder.light(.right, .headphoneCue, on: true), [[0x96, 85, 127], [0x96, 87, 127]])
        XCTAssertEqual(DDJErgoDecoder.light(.centre, .function, on: false), [[0x96, 101, 0]])
    }

    func testDefaultLayoutEffectBoxKnobsAreTheDialsInOrder() {
        let layout = ControlLayout()
        XCTAssertTrue(layout.isDefault)
        // Left to right across the controller: FX1 CONTROL, 1, 2, 3, then FX2 CONTROL, 1, 2, 3.
        let acrossTheController = [
            DeckControl(.left, .fxControl), DeckControl(.left, .fx1), DeckControl(.left, .fx2), DeckControl(.left, .fx3),
            DeckControl(.right, .fxControl), DeckControl(.right, .fx1), DeckControl(.right, .fx2), DeckControl(.right, .fx3),
        ]
        for (index, knob) in acrossTheController.enumerated() {
            XCTAssertEqual(layout[knob], .dial(index), knob.id)
        }
        // The six HI / MID / LOW knobs are the Feel sliders, top to bottom: left side, then right.
        XCTAssertEqual(layout[DeckControl(.left, .hi)], .world(.intensity))
        XCTAssertEqual(layout[DeckControl(.left, .mid)], .world(.speed))
        XCTAssertEqual(layout[DeckControl(.left, .low)], .world(.density))
        XCTAssertEqual(layout[DeckControl(.right, .hi)], .world(.glow))
        XCTAssertEqual(layout[DeckControl(.right, .mid)], .world(.chaos))
        XCTAssertEqual(layout[DeckControl(.right, .low)], .world(.temperature))
        // The crossfader is the time of day; the channel faders are the ambience's volume and closeness.
        XCTAssertEqual(layout[DeckControl(.centre, .crossfader)], .world(.timeOfDay))
        XCTAssertEqual(layout[DeckControl(.left, .fader)], .ambience)
        XCTAssertEqual(layout[DeckControl(.right, .fader)], .world(.closeness))
        // The effects are on what is left.
        XCTAssertEqual(layout[DeckControl(.left, .gain)], .fx(.echo))
        XCTAssertEqual(layout[DeckControl(.right, .gain)], .fx(.reverb))
        XCTAssertEqual(layout[DeckControl(.left, .filter)], .fx(.filter))
        XCTAssertEqual(layout[DeckControl(.right, .filter)], .fx(.drive))
        // The faders, sliders and centre knobs are the world.
        XCTAssertEqual(layout[DeckControl(.centre, .master)], .volume)
        XCTAssertEqual(layout[DeckControl(.centre, .headphonesVolume)], .world(.moodEnergy))
        XCTAssertEqual(DeckControl.all.count, 27)
        XCTAssertNil(DeckControl(id: "centre.hi"))
        XCTAssertNil(DeckControl(id: "left.crossfader"))
    }

    // MARK: - Buttons, wheels and the world

    func testDefaultButtonsLeftInstrumentRightWorld() {
        let layout = ButtonLayout()
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout[DeckKey(.left, .on)], .fxAll)
        XCTAssertEqual(layout[DeckKey(.left, .play)], .hold)
        XCTAssertEqual(layout[DeckKey(.left, .cue)], .panic)
        XCTAssertEqual(layout[DeckKey(.left, .hotCue1)], .sound1)
        // The eight SAMPLER buttons across the controller: set, world, instrument, transpose.
        let samplers = [DeckKey(.left, .sampler1), DeckKey(.left, .sampler2), DeckKey(.left, .sampler3), DeckKey(.left, .sampler4),
                        DeckKey(.right, .sampler1), DeckKey(.right, .sampler2), DeckKey(.right, .sampler3), DeckKey(.right, .sampler4)]
        let actions: [DeckAction] = [.setPrevious, .setNext, .worldPrevious, .worldNext,
                                     .instrumentPrevious, .instrumentNext, .transposeDown, .transposeUp]
        for index in 0..<8 {
            XCTAssertEqual(layout[samplers[index]], actions[index], samplers[index].id)
        }
        XCTAssertEqual(layout[DeckKey(.right, .hotCue1)], .timeMorning)
        XCTAssertEqual(layout[DeckKey(.centre, .function)], .fullScreen)
        XCTAssertEqual(layout[DeckWheel(.right, .jog)], .timeOfDay)
        XCTAssertEqual(layout[DeckWheel(.right, .search)], .timeOfDay)
        XCTAssertEqual(layout[DeckWheel(.left, .search)], .moonPhase)
        XCTAssertEqual(layout[DeckWheel(.left, .jog)], .moonPhase)
        XCTAssertEqual(layout[DeckWheel(.centre, .browse)], .worlds)
        XCTAssertEqual(DeckKey.all.count, 50)
    }

    func testEveryButtonHasAnActionOutOfTheBox() {
        for key in DeckKey.all {
            XCTAssertNotEqual(ButtonLayout.defaultAction(key), .none, key.id)
        }
        for wheel in DeckWheel.all {
            XCTAssertNotEqual(ButtonLayout.defaultTarget(wheel), .none, wheel.id)
        }
        for control in DeckControl.all {
            XCTAssertNotEqual(ControlLayout.defaultTarget(control), .none, control.id)
        }
    }

    func testButtonLayoutRoundTripAndTolerance() throws {
        var layout = ButtonLayout()
        layout[DeckKey(.left, .play)] = .mute
        layout[DeckWheel(.right, .jog)] = .volume
        XCTAssertFalse(layout.isDefault)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(ButtonLayout.self, from: data), layout)
        let odd = Data(#"{"actions":{"left.cue":"explode","nowhere.play":"mute","right.sync":"panic"},"wheels":{"left.jog":"sideways"}}"#.utf8)
        let loaded = try JSONDecoder().decode(ButtonLayout.self, from: odd)
        XCTAssertEqual(loaded[DeckKey(.left, .cue)], .panic)          // unreadable: the default
        XCTAssertEqual(loaded[DeckKey(.right, .sync)], .panic)
        XCTAssertEqual(loaded[DeckWheel(.left, .jog)], .moonPhase)
        XCTAssertEqual(try JSONDecoder().decode(ButtonLayout.self, from: Data("{}".utf8)), ButtonLayout())
    }

    func testEveryActionHasANameAndAGroup() {
        for action in DeckAction.allCases where action != .none {
            XCTAssertFalse(action.displayName.isEmpty)
            XCTAssertNotNil(action.group, action.rawValue)
        }
        XCTAssertEqual(DeckAction.sound3.soundSlot, 2)
        XCTAssertEqual(DeckAction.timeMidday.hour, 12.5)
        XCTAssertEqual(DeckAction.weatherStorm.weather, .storm)
    }

    func testWorldKnobsKeepTheDesignedValueAtTheCentre() {
        XCTAssertEqual(WorldParam.wind.value(knob: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.wind.value(knob: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.wind.value(knob: 1), 2, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.clouds.value(knob: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.clouds.value(knob: 1), 1.5, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.moonSize.value(knob: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.glow.value(knob: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.glow.value(knob: 0), -1, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.moodWarmth.value(knob: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(WorldParam.timeOfDay.value(knob: 0.5), 11.995, accuracy: 1e-9)
    }

    func testWorldKnobAndValueAreInverses() {
        for param in WorldParam.allCases {
            for step in 0...20 {
                let knob = Double(step) / 20
                let back = param.knob(value: param.value(knob: knob))
                XCTAssertEqual(back, knob, accuracy: 1e-9, param.rawValue)
            }
        }
    }

    func testWorldTargetsRoundTrip() throws {
        var layout = ControlLayout()
        layout[DeckControl(.centre, .auxVolume)] = .world(.stars)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data)[DeckControl(.centre, .auxVolume)], .world(.stars))
        XCTAssertEqual(ControlTarget(id: "world.moonPhase"), .world(.moonPhase))
        XCTAssertNil(ControlTarget(id: "world.gravity"))
    }

    func testWheelsScrubRoundTheClockAndStepThroughLists() {
        XCTAssertEqual(WheelTarget.hour(23.5, turnedBy: 2), 0.5, accuracy: 1e-9)      // past midnight
        XCTAssertEqual(WheelTarget.hour(0.25, turnedBy: -1), 23.75, accuracy: 1e-9)   // back past midnight
        XCTAssertEqual(WheelTarget.phase(0.99, turnedBy: 1), 0.99 + 1.0 / 32 - 1, accuracy: 1e-9)
        XCTAssertEqual(WheelTarget.phase(0, turnedBy: -16), 0.5, accuracy: 1e-9)
        let some = WheelTarget.steps(from: 2.6)
        XCTAssertEqual(some.steps, 2)
        XCTAssertEqual(some.left, 0.6, accuracy: 1e-9)
        let back = WheelTarget.steps(from: -1.25)
        XCTAssertEqual(back.steps, -1)
        XCTAssertEqual(back.left, -0.25, accuracy: 1e-9)
        XCTAssertEqual(WheelTarget.steps(from: 0.4).steps, 0)
        XCTAssertEqual(WheelTarget.index(after: 2, by: 1, count: 3), 0)
        XCTAssertEqual(WheelTarget.index(after: 0, by: -1, count: 3), 2)
        XCTAssertEqual(WheelTarget.index(after: nil, by: 1, count: 3), 0)
        XCTAssertEqual(WheelTarget.index(after: nil, by: -1, count: 3), 2)
        XCTAssertEqual(WheelTarget.index(after: 1, by: 7, count: 3), 2)
        XCTAssertNil(WheelTarget.index(after: 0, by: 1, count: 0))
    }

    func testTheJogWheelOnTheClockIsFineWhenSlowAndFarWhenSpun() {
        // A slow turn: an eighth of a turn spread over a second (twenty looks) is about an eighth of an hour.
        // The top, turned slowly: a full turn (eight units) spread over eight seconds is about ten minutes.
        var top = 0.0
        for _ in 0..<160 { top += WheelTarget.jogHours(units: 8.0 / 160, search: false) }
        XCTAssertEqual(top * 60, 10 * (1 + 6.25 / 20), accuracy: 1e-6)
        // The edge, the same slow turn: about half an hour.
        var edge = 0.0
        for _ in 0..<160 { edge += WheelTarget.jogHours(units: 8.0 / 160, search: true) }
        XCTAssertEqual(edge * 60, 30 * (1 + 6.25 / 20), accuracy: 1e-6)
        // Spun: the edge never more than six times its slow rate (three hours a turn), the top never more than three.
        XCTAssertEqual(WheelTarget.jogHours(units: 4, search: true), 4 * (0.5 / 8) * 6, accuracy: 1e-9)
        XCTAssertEqual(WheelTarget.jogHours(units: 4, search: false), 4 * (1.0 / 48) * 3, accuracy: 1e-9)
        // Backwards is the mirror image.
        XCTAssertEqual(WheelTarget.jogHours(units: -0.8, search: true), -WheelTarget.jogHours(units: 0.8, search: true), accuracy: 1e-12)
        XCTAssertEqual(WheelTarget.hour(23.9, movedBy: 0.3), 0.2, accuracy: 1e-9)
        XCTAssertEqual(WheelTarget.hour(0.1, movedBy: -0.3), 23.8, accuracy: 1e-9)
    }

    func testKeyboardVolumeIsControllerSeven() {
        XCTAssertEqual(KeyboardVolume.volume(in: [0xB0, 7, 127]), 1)
        XCTAssertEqual(KeyboardVolume.volume(in: [0xB3, 7, 0]), 0)
        XCTAssertNil(KeyboardVolume.volume(in: [0xB0, 1, 64]))      // the mod wheel
        XCTAssertNil(KeyboardVolume.volume(in: [0x90, 7, 64]))      // a note
        XCTAssertNil(KeyboardVolume.volume(in: [0xB0, 7]))
    }

    func testLayoutRoundTripAndTolerance() throws {
        var layout = ControlLayout()
        layout[DeckControl(.right, .hi)] = .fx(.crush)
        layout[DeckControl(.left, .fx3)] = .volume
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), layout)
        let odd = Data(#"{"right.hi":"fx.nothing","nowhere.knob":"volume","left.low":"dial.2"}"#.utf8)
        let loaded = try JSONDecoder().decode(ControlLayout.self, from: odd)
        XCTAssertEqual(loaded[DeckControl(.right, .hi)], .world(.glow))  // unreadable: the default
        XCTAssertEqual(loaded[DeckControl(.left, .low)], .dial(2))
    }

    // MARK: - Effects

    func testNewEffectsAreNeutral() {
        let fx = SoundFX()
        XCTAssertTrue(fx.isNeutral)
        XCTAssertEqual(fx[.eqMid], 0.5)
        XCTAssertEqual(fx[.echo], 0)
        XCTAssertTrue(fx.isOn(.all))
    }

    func testSwitchesSilenceWithoutLosingTheKnob() {
        var fx = SoundFX()
        fx[.echo] = 0.6
        XCTAssertFalse(fx.isNeutral)
        fx.toggle(.echo)
        XCTAssertEqual(fx[.echo], 0.6)
        XCTAssertEqual(fx.effective(.echo), 0)
        XCTAssertTrue(fx.isNeutral)
        fx.toggle(.echo)
        fx[.eqLow] = 0.1
        fx.set(.all, on: false)
        XCTAssertTrue(fx.isNeutral)
        XCTAssertEqual(fx.effective(.eqLow), 0.5)
    }

    func testEffectsRoundTripAndTolerance() throws {
        var fx = SoundFX()
        fx[.reverb] = 0.4
        fx[.filter] = 0.2
        fx.set(.drive, on: false)
        let data = try JSONEncoder().encode(fx)
        XCTAssertEqual(try JSONDecoder().decode(SoundFX.self, from: data), fx)
        let odd = Data(#"{"values":{"reverb":7,"wobble":0.3},"off":["all","sideways"]}"#.utf8)
        let loaded = try JSONDecoder().decode(SoundFX.self, from: odd)
        XCTAssertEqual(loaded[.reverb], 1)
        XCTAssertFalse(loaded.isOn(.all))
        XCTAssertEqual(try JSONDecoder().decode(SoundFX.self, from: Data("{}".utf8)), SoundFX())
    }

    func testEQGain() {
        XCTAssertEqual(FXMath.eqGainDB(0.5), 0)
        XCTAssertEqual(FXMath.eqGainDB(0.51), 0)     // inside the detent
        XCTAssertEqual(FXMath.eqGainDB(0), -26, accuracy: 0.001)
        XCTAssertEqual(FXMath.eqGainDB(1), 6, accuracy: 0.001)
        XCTAssertLessThan(FXMath.eqGainDB(0.3), 0)
        XCTAssertGreaterThan(FXMath.eqGainDB(0.8), 0)
    }

    func testFilterSweep() {
        XCTAssertEqual(FXMath.filter(0.5), .off)
        XCTAssertEqual(FXMath.filter(0.52), .off)
        guard case let .lowPass(closed) = FXMath.filter(0) else { return XCTFail("not a low-pass") }
        XCTAssertEqual(closed, 90, accuracy: 0.01)
        guard case let .lowPass(open) = FXMath.filter(0.46) else { return XCTFail("not a low-pass") }
        XCTAssertGreaterThan(open, 15_000)
        guard case let .highPass(top) = FXMath.filter(1) else { return XCTFail("not a high-pass") }
        XCTAssertEqual(top, 6_000, accuracy: 0.01)
    }

    func testEchoRanges() {
        XCTAssertEqual(FXMath.echoSeconds(0), 0.06, accuracy: 0.0001)
        XCTAssertEqual(FXMath.echoSeconds(1), 1.2, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(FXMath.echoFeedbackPercent(1), 80)
    }

    // MARK: - Saved sounds

    func testNextSoundWrapsRound() {
        let choice = InstrumentChoice(name: "Felt Glass", componentType: 1, componentSubType: 2, componentManufacturer: 3)
        let list = ["A", "B", "C"].map { SoundPreset(name: $0, instrument: choice) }
        XCTAssertEqual(SoundPreset.next(after: nil, in: list)?.name, "A")
        XCTAssertEqual(SoundPreset.next(after: "A", in: list)?.name, "B")
        XCTAssertEqual(SoundPreset.next(after: "C", in: list)?.name, "A")
        XCTAssertEqual(SoundPreset.next(after: "gone", in: list)?.name, "A")
        XCTAssertNil(SoundPreset.next(after: "A", in: []))
        XCTAssertEqual(SoundPreset.freeName(among: ["Sound 1", "Sound 3"]), "Sound 4")
    }

    func testSoundPresetRoundTrip() throws {
        let choice = InstrumentChoice(name: "Felt Glass", componentType: 1, componentSubType: 2, componentManufacturer: 3)
        var fx = SoundFX()
        fx[.echo] = 0.3
        let preset = SoundPreset(name: "Glass echo", instrument: choice, patchID: "felt-glass", dials: ["felt": 0.7], fx: fx)
        let data = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(SoundPreset.self, from: data), preset)
    }
}
