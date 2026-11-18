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

    func testEverythingElseIsIgnored() {
        var d = DDJErgoDecoder()
        XCTAssertNil(d.decode(cc(6, 0, 100)))     // master volume
        XCTAssertNil(d.decode(cc(6, 31, 100)))    // crossfader
        XCTAssertNil(d.decode(cc(0, 0, 100)))     // deck A's tempo slider
        XCTAssertNil(d.decode(cc(6, 64, 1)))      // the browser's rotary selector
        XCTAssertNil(d.decode(.noteOn(channel: 0, note: 11, velocity: 127)))   // deck A's play button
        XCTAssertNil(d.decode(.noteOff(channel: 4, note: 67)))                 // a button coming up
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
    }

    func testDefaultLayoutLeftEffectsRightDials() {
        let layout = ControlLayout()
        XCTAssertTrue(layout.isDefault)
        XCTAssertEqual(layout[DeckControl(.left, .hi)], .fx(.eqHigh))
        XCTAssertEqual(layout[DeckControl(.left, .fx1)], .fx(.echo))
        XCTAssertEqual(layout[DeckControl(.left, .filter)], .fx(.filter))
        XCTAssertEqual(layout[DeckControl(.right, .fx1)], .dial(0))
        XCTAssertEqual(layout[DeckControl(.right, .filter)], .dial(7))
    }

    func testLayoutRoundTripAndTolerance() throws {
        var layout = ControlLayout()
        layout[DeckControl(.right, .hi)] = .fx(.crush)
        layout[DeckControl(.left, .fx3)] = .volume
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(ControlLayout.self, from: data), layout)
        let odd = Data(#"{"right.hi":"fx.nothing","nowhere.knob":"volume","left.low":"dial.2"}"#.utf8)
        let loaded = try JSONDecoder().decode(ControlLayout.self, from: odd)
        XCTAssertEqual(loaded[DeckControl(.right, .hi)], .dial(4))    // unreadable: the default
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
