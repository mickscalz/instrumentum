import XCTest
import AVFoundation
import AudioToolbox
@testable import InStrumAudio
@testable import InStrumCore

@MainActor
final class FXChainTests: XCTestCase {
    let dls = InstrumentChoice(name: "Apple DLS Synth",
                               componentType: kAudioUnitType_MusicDevice,
                               componentSubType: kAudioUnitSubType_DLSSynth,
                               componentManufacturer: kAudioUnitManufacturer_Apple)

    private func peak(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        var m: Float = 0
        for ch in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![ch]
            for i in 0..<n { m = max(m, abs(d[i])) }
        }
        return m
    }

    private func makeEngine() async throws -> AudioEngine {
        let e = AudioEngine(manualRendering: true)
        try e.start()
        try await e.loadInstrument(dls)
        return e
    }

    func testEffectsStayOutOfThePathUntilAsked() async throws {
        let e = try await makeEngine()
        XCTAssertFalse(e.fxInPath)
        var fx = SoundFX()
        fx[.echo] = 0.5
        e.setFX(fx)
        XCTAssertEqual(e.fxInUse, fx)
        XCTAssertFalse(e.fxInPath, "setting them never changes the graph")
    }

    func testTheInstrumentStillSoundsThroughNeutralEffects() async throws {
        let e = try await makeEngine()
        e.insertFX()
        XCTAssertTrue(e.fxInPath)
        e.send([0x90, 60, 110])
        let heard = peak(try e.renderOffline(frames: 4096))
        XCTAssertGreaterThan(heard, 0.01)
    }

    func testTheInstrumentSoundsThroughEveryEffect() async throws {
        let e = try await makeEngine()
        e.insertFX()
        var fx = SoundFX()
        for param in FXParam.allCases { fx[param] = 0.7 }
        e.setFX(fx)
        e.send([0x90, 60, 110])
        var loudest: Float = 0
        for _ in 0..<8 {
            let block = peak(try e.renderOffline(frames: 4096))
            loudest = max(loudest, block)
        }
        XCTAssertGreaterThan(loudest, 0.005)
        XCTAssertLessThan(loudest, 4, "no effect runs away")
    }

    func testEffectsAskedForBeforeTheEngineStartsGoInWhenItDoes() async throws {
        let e = AudioEngine(manualRendering: true)
        e.insertFX()
        XCTAssertFalse(e.fxInPath)
        try e.start()
        XCTAssertTrue(e.fxInPath)
        try await e.loadInstrument(dls)
        e.send([0x90, 60, 110])
        let heard = peak(try e.renderOffline(frames: 4096))
        XCTAssertGreaterThan(heard, 0.01)
    }

    func testANewInstrumentPlaysThroughTheEffects() async throws {
        let e = try await makeEngine()
        e.insertFX()
        try await e.loadInstrument(dls)
        e.send([0x90, 64, 110])
        let heard = peak(try e.renderOffline(frames: 4096))
        XCTAssertGreaterThan(heard, 0.01)
    }
}
