import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore
import InStrumDSP

/// What a Set switch costs the main thread on the sound's side (real-Mac performance, 14 Nov): `AppModel.applySet` loads
/// the set's built-in instrument on the main actor, whose Audio Unit makes its Sound Core at 48 kHz as it is made, and
/// again at the output's rate when the engine allocates it (44.1 kHz on many Macs). One SYNTH TIME line per engine:
/// the Sound Core's creation, the Audio Unit's init, and its allocation at 44.1 kHz (medians of three, ms). Reports only.
final class InstrumentSwitchTimingTests: XCTestCase {
    private func ms(_ start: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }
    private func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }

    func testEveryEngineSwitchTime() throws {
        var lines = 0
        for engine in BuiltInEngine.allCases {
            var create: [Double] = [], initTimes: [Double] = [], allocate: [Double] = []
            for _ in 0..<3 {
                let c0 = CFAbsoluteTimeGetCurrent()
                guard let synth = isd_synth_create(BuiltInCatalog.isdEngine(engine), 48_000, 4096) else {
                    XCTFail("\(engine) Sound Core")
                    continue
                }
                create.append(ms(c0))
                isd_synth_destroy(synth)
                let i0 = CFAbsoluteTimeGetCurrent()
                let au = try BuiltInInstrumentAU(componentDescription: BuiltInCatalog.description(for: engine), options: [])
                initTimes.append(ms(i0))
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
                try au.outputBusses[0].setFormat(format)
                let a0 = CFAbsoluteTimeGetCurrent()
                try au.allocateRenderResources()
                allocate.append(ms(a0))
                au.deallocateRenderResources()
            }
            guard !create.isEmpty, !initTimes.isEmpty, !allocate.isEmpty else { continue }
            print(String(format: "SYNTH TIME %@: Sound Core %.2f ms, Audio Unit init %.2f ms, allocate at 44.1 kHz %.2f ms",
                         engine.rawValue, median(create), median(initTimes), median(allocate)))
            lines += 1
        }
        XCTAssertEqual(lines, BuiltInEngine.allCases.count)
    }
}
