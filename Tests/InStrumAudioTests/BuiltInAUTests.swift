import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

@MainActor
final class BuiltInAUTests: XCTestCase {
    private func choice(_ name: String = "Felt Glass") throws -> InstrumentChoice {
        try XCTUnwrap(BuiltInCatalog.instruments.first { $0.name == name }).choice()
    }

    private func makeEngine(rate: Double = 48_000, _ name: String = "Felt Glass") async throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true, manualSampleRate: rate)
        try e.start()
        let c = try choice(name)
        try await e.loadInstrument(c)
        return e
    }

    private func setParam(_ e: AudioEngine, _ address: Int, _ value: Float) {
        e.loadedBuiltIn?.parameterTree?.parameter(withAddress: AUParameterAddress(address))?.value = value
    }

    /// Reads a dial (synchronous helper: async tests assert on plain values, avoiding a Swift
    /// runtime bug with closures nested in XCTAssert autoclosures inside async functions).
    private func param(_ e: AudioEngine, _ address: Int) -> Float {
        e.loadedBuiltIn?.parameterTree?.parameter(withAddress: AUParameterAddress(address))?.value ?? .nan
    }

    private func level(_ e: AudioEngine, seconds: Double, block: Int = 256) throws -> Double {
        DSPTestKit.dBFS(try render(e, seconds: seconds, block: block))
    }

    /// Left channel of `seconds` of manual rendering in `block`-frame calls.
    private func render(_ e: AudioEngine, seconds: Double, block: Int = 256, rate: Double = 48_000) throws -> [Float] {
        var out: [Float] = []
        let total = Int(seconds * rate)
        out.reserveCapacity(total)
        while out.count < total {
            let n = min(block, total - out.count)
            let b = try e.renderOffline(frames: AVAudioFrameCount(n))
            out.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        }
        return out
    }

    func testLoadsAndPlaysFeltGlass() async throws {
        let e = try await makeEngine()
        let loaded = e.loadedBuiltIn != nil
        XCTAssertTrue(loaded)
        e.send([0x90, 60, 100])
        let db = try level(e, seconds: 0.5)
        XCTAssertGreaterThan(db, -40)
    }

    func testFullStateRoundTrip() async throws {
        let e = try await makeEngine()
        setParam(e, Int(ISD_P_GLASS), 0.8)
        setParam(e, Int(ISD_P_FINE_TUNE), 12)
        var saved = try choice()
        let state = e.currentInstrumentState()
        XCTAssertNotNil(state)
        saved.stateData = state
        let e2 = AudioEngine(manualRendering: true)
        try e2.start()
        try await e2.loadInstrument(saved)
        let glass = param(e2, Int(ISD_P_GLASS)), fine = param(e2, Int(ISD_P_FINE_TUNE))
        XCTAssertEqual(glass, 0.8, accuracy: 1e-5)
        XCTAssertEqual(fine, 12, accuracy: 1e-5)
    }

    func testDialReaderSeesDialsButNotMood() async throws {
        let e = try await makeEngine()
        guard let unit = e.loadedBuiltIn else { return XCTFail("no built-in loaded") }
        let names = DialReader(audioUnit: unit).dials.map(\.name)
        let addresses = DialReader(audioUnit: unit).dials.map(\.address)
        let hasGlass = names.contains("Glass")
        let moodCount = addresses.filter { $0 >= AUParameterAddress(ISD_P_MOOD_ENERGY) }.count
        XCTAssertTrue(hasGlass)
        XCTAssertEqual(moodCount, 0)
    }

    func testCatalogListsAvailableInstruments() throws {
        let all = BuiltInCatalog.instruments
        for engine in BuiltInEngine.allCases { XCTAssertTrue(all.contains { $0.name == engine.displayName }, engine.displayName) }
        XCTAssertTrue(all.allSatisfy { $0.manufacturer == "In Strum Meants" })
        for info in all {
            let engine = try XCTUnwrap(BuiltInCatalog.engine(for: info.choice()))
            XCTAssertEqual(BuiltInCatalog.description(for: engine).componentSubType, info.description.componentSubType)
        }
        XCTAssertNil(BuiltInCatalog.engine(for: InstrumentChoice(name: "x", componentType: kAudioUnitType_MusicDevice,
                                                                 componentSubType: kAudioUnitSubType_DLSSynth,
                                                                 componentManufacturer: kAudioUnitManufacturer_Apple)))
    }

    /// Dials that keep a single note's pitch still enough to measure (the pad's drift, the tape's wow and the unison
    /// strings move it; what's left is a symmetric unison, measured by its centre). Blue Depth's arp re-plucks a held
    /// note on every sixteenth and its echo wows, so both go off; mood motion 0 halves its analogue slop, leaving the
    /// detuned pair, centred on the note (+0.26 cents at 44.1, 48 and 96 kHz on the mirror; −7 with the arp running).
    private func steady(_ e: AudioEngine, _ engine: BuiltInEngine) {
        setParam(e, Int(ISD_P_SPACE), 0)
        if engine == .orbitPad { setParam(e, Int(ISD_P_DRIFT), 0); setParam(e, Int(ISD_P_MOTION), 0) }
        if engine == .honeyTape { setParam(e, Int(ISD_P_WOW), 0); setParam(e, Int(ISD_P_STRINGS), 0) }
        if engine == .hazeBells { setParam(e, Int(ISD_P_DRIFT), 0); setParam(e, Int(ISD_P_ECHO), 0) }
        if engine == .blueDepth { setParam(e, Int(ISD_P_BLINK), 0); setParam(e, Int(ISD_P_ECHO), 0); setParam(e, Int(ISD_P_MOOD_MOTION), 0) }
        // Magma Bass and Replicant Brass drift like Blue Depth (half at mood motion 0); the brass's stack narrows to
        // ±2 cents at Width 0, centred on the note.
        if engine == .magmaBass { setParam(e, Int(ISD_P_MOOD_MOTION), 0) }
        if engine == .replicantBrass { setParam(e, Int(ISD_P_MOOD_MOTION), 0); setParam(e, Int(ISD_P_UNISON_WIDTH), 0); setParam(e, Int(ISD_P_HALL), 0) }
        // Endless Rise's riser climbs through every pitch (Rise 0 switches it off) and its pulse ducks the pad, so both go;
        // the pad's pair is centred on the note and drifts like Blue Depth's (+0.12 cents at 44.1, 48 and 96 kHz on the
        // mirror).
        if engine == .endlessRise { setParam(e, Int(ISD_P_RISE), 0); setParam(e, Int(ISD_P_PULSE), 0); setParam(e, Int(ISD_P_MOOD_MOTION), 0) }
    }

    func testTuningHoldsAt44_1And96k() async throws {
        for engine in BuiltInEngine.allCases {
            for rate in [44_100.0, 96_000.0] {
                let e = try await makeEngine(rate: rate, engine.displayName)
                steady(e, engine)
                e.send([0x90, 69, 100])
                let out = try render(e, seconds: 1.4, block: 512, rate: rate)
                let slice = Array(out[Int(0.3 * rate)..<Int(1.3 * rate)])
                let cents = DSPTestKit.cents(DSPTestKit.clusterCentre(slice, sampleRate: rate, near: 440), 440)
                XCTAssertEqual(cents, 0, accuracy: 2, "\(engine.displayName) at \(rate) Hz")
            }
        }
    }

    func testRendersAnyBufferSize() async throws {
        for engine in BuiltInEngine.allCases {
            var levels: [Double] = []
            for block in [256, 4096, 1] {
                let e = try await makeEngine(engine.displayName)
                e.send([0x90, 60, 100])
                let db = try level(e, seconds: 0.5, block: block)
                levels.append(db)
            }
            XCTAssertEqual(levels[1], levels[0], accuracy: 0.5, engine.displayName)
            XCTAssertEqual(levels[2], levels[0], accuracy: 0.5, engine.displayName)
        }
    }

    func testSwitchingWhileHeldIsSafe() async throws {
        let e = try await makeEngine()
        e.send([0x90, 60, 110])
        _ = try render(e, seconds: 0.2)
        let next = try choice("Orbit Pad")
        try await e.loadInstrument(next)
        let after = try render(e, seconds: 0.25)
        let finite = after.allSatisfy { $0.isFinite }
        let tail = DSPTestKit.dBFS(after[Int(0.05 * 48_000)...])
        XCTAssertTrue(finite)
        XCTAssertLessThan(tail, -100)
    }

    func testOrbitPadPlaysThroughTheUnit() async throws {
        let e = try await makeEngine(rate: 44_100, "Orbit Pad")
        e.send([0x90, 63, 100])
        let out = try render(e, seconds: 1.5, block: 512, rate: 44_100)
        let finite = out.allSatisfy { $0.isFinite }
        let held = DSPTestKit.dBFS(out[Int(1.0 * 44_100)...])
        XCTAssertTrue(finite)
        XCTAssertGreaterThan(held, -45)
        XCTAssertLessThan(held, -6)
    }

    /// The sound-character tap listens to the instrument bus (it doesn't run in offline rendering), so this
    /// checks the routing: ambience reaches the speakers through its own bus and never the instrument's.
    func testSoundCharacterIgnoresAmbience() async throws {
        let e = try await makeEngine()
        await e.startAmbience()
        e.setAmbience(AmbienceScene(levels: [.water: 1, .airFlow: 1]))
        let ambient = try render(e, seconds: 4)
        let heard = DSPTestKit.dBFS(ambient[Int(3 * 48_000)...])
        let toMixer = e.ambienceFeedsMainMixer, toInstrument = e.ambienceFeedsInstrumentBus
        let loudness = e.soundReading.loudness
        XCTAssertGreaterThan(heard, -60, "the ambience is playing")
        XCTAssertTrue(toMixer)
        XCTAssertFalse(toInstrument)
        XCTAssertLessThan(loudness, 0.05)
    }

    func testPanicLeavesAmbience() async throws {
        let e = try await makeEngine()
        await e.startAmbience()
        e.setAmbience(AmbienceScene(levels: [.airFlow: 1]))
        let before = try render(e, seconds: 4)
        e.panic()
        let after = try render(e, seconds: 1)
        let a = DSPTestKit.dBFS(before[Int(3 * 48_000)...]), b = DSPTestKit.dBFS(after)
        XCTAssertGreaterThan(a, -60)
        XCTAssertEqual(b, a, accuracy: 1)
    }

    /// Storms Review focus 4, through the real unit: a panic leaves the beds but drops the thunder on its way (a strike's
    /// roll queued 1.5 s out never arrives), and a world switch does the same; without either, it rolls in.
    func testPanicAndASwitchClearTheThunderOnItsWay() async throws {
        var heard: [Double] = []
        for clear in [0, 1, 2] {
            let e = try await makeEngine()
            await e.startAmbience()
            var scene = AmbienceScene(levels: [.thunderRoll: 1, .airFlow: 0.3])
            e.setAmbience(scene)
            _ = try render(e, seconds: 3)   // the levels up
            scene.thunderQueue = [QueuedThunder(delay: 1.5, strength: 1)]
            e.setAmbience(scene)
            _ = try render(e, seconds: 0.5)
            if clear == 1 { e.panic() }
            if clear == 2 { e.clearAmbienceThunder() }
            let after = try render(e, seconds: 3)
            heard.append(DSPTestKit.dBFS(Array(after[Int(1.2 * 48_000)...])))
        }
        let rolled = heard[0], panicked = heard[1], switched = heard[2]
        // The roll stands about 10 dB over the beds; where it starts in a render block moves that a little (9.9 dB on a
        // busy CI runner on 13 Nov, 10 or more on others), so 8 dB is the line: a roll that was not cleared gives 0.
        XCTAssertGreaterThanOrEqual(rolled - panicked, 8, "panic: \(rolled) dBFS with the roll, \(panicked) without")
        XCTAssertGreaterThanOrEqual(rolled - switched, 8, "switch: \(rolled) dBFS with the roll, \(switched) without")
        XCTAssertGreaterThan(panicked, -90, "the beds carry on")
    }

    func testAmbienceVolumeAndSwitch() async throws {
        let e = try await makeEngine()
        await e.startAmbience()
        e.setAmbience(AmbienceScene(levels: [.airFlow: 1]))
        let full = DSPTestKit.dBFS(try render(e, seconds: 4)[Int(3 * 48_000)...])
        e.ambienceVolume = 0.125
        let half = DSPTestKit.dBFS(try render(e, seconds: 1))
        e.ambienceEnabled = false
        let off = DSPTestKit.dBFS(try render(e, seconds: 1)[Int(0.2 * 48_000)...])
        XCTAssertEqual(full - half, 6, accuracy: 1, "default volume is 0.25")
        XCTAssertLessThan(off, -100)
    }

    func testMoodReachesTheInstrument() async throws {
        let e = try await makeEngine()
        e.setMood(.serene)
        let space = param(e, Int(ISD_P_MOOD_SPACE))
        XCTAssertEqual(space, Float(Mood.serene.space), accuracy: 1e-5)
    }

    func testPatchesApply() async throws {
        let e = try await makeEngine()
        guard let lullaby = PatchLibrary.all.first(where: { $0.id == "lullaby" }) else { return XCTFail("no Lullaby") }
        e.loadedBuiltIn?.apply(lullaby)
        let felt = Double(param(e, Int(ISD_P_FELT))), expected = lullaby.values["felt"] ?? -1
        let id = e.loadedBuiltIn?.patchID
        XCTAssertEqual(felt, expected, accuracy: 1e-5)
        XCTAssertEqual(id, "lullaby")
    }
}
