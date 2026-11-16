import XCTest
@testable import InStrumCore

/// Staying in time (Recorder spec §4; plan Task 1, Review focus 1): he plays to what he hears, which is later than the
/// engine's clock by the output's latency, so an instrument stem moves earlier by the output's latency and a live input
/// by that plus the input's and the capture buffer's. The Timing nudge (−100…+100 ms) moves both further. The
/// play-along and the ambience never move.
final class RecordingLatencyTests: XCTestCase {
    /// Bluetooth headphones: 150 ms at 48 kHz.
    private let bluetooth = RecordingLatency.Device(latencyFrames: 6656, safetyFrames: 32, bufferFrames: 512)
    /// An audio interface's input: 376 frames.
    private let interface = RecordingLatency.Device(latencyFrames: 96, safetyFrames: 24, bufferFrames: 256)

    private func offset(_ kind: StemKind, input: RecordingLatency.Device? = nil, capture: Int = 0, nudgeMs: Double = 0,
                        sampleRate: Double = 48_000) -> Int {
        RecordingLatency.offsetFrames(kind: kind, output: bluetooth, input: input, captureBufferFrames: capture,
                                      nudgeMs: nudgeMs, sampleRate: sampleRate)
    }

    func testInstrumentStemMovesEarlierByOutputLatency() {
        let total = bluetooth.total
        XCTAssertEqual(total, 7200, "device latency + safety offset + buffer")
        let plain = offset(.instrument)
        XCTAssertEqual(plain, -7200)
        let nudged = offset(.instrument, nudgeMs: 10)
        XCTAssertEqual(nudged, -7680, "a +10 ms nudge moves it 480 frames earlier still")
        let back = offset(.instrument, nudgeMs: -10)
        XCTAssertEqual(back, -6720)
        let ignoresInput = offset(.instrument, input: interface, capture: 480)
        XCTAssertEqual(ignoresInput, -7200, "the instrument never waits on an input")
        let at44 = RecordingLatency.offsetFrames(kind: .instrument, output: RecordingLatency.Device(latencyFrames: 0, safetyFrames: 0, bufferFrames: 0),
                                                 input: nil, captureBufferFrames: 0, nudgeMs: 10, sampleRate: 44_100)
        XCTAssertEqual(at44, -441)
        let tooFar = offset(.instrument, nudgeMs: 250)
        XCTAssertEqual(tooFar, -12_000, "the nudge stops at 100 ms")
        let tooFarBack = offset(.instrument, nudgeMs: -250)
        XCTAssertEqual(tooFarBack, -2400)
    }

    func testLiveInputAddsInputAndCapture() {
        let inputTotal = interface.total
        XCTAssertEqual(inputTotal, 376)
        let live = offset(.liveInput, input: interface, capture: 480)
        XCTAssertEqual(live, -8056, "7200 out + 376 in + 480 capture")
        let nudged = offset(.liveInput, input: interface, capture: 480, nudgeMs: 5)
        XCTAssertEqual(nudged, -8296)
        let noInputLatency = offset(.liveInput, input: nil, capture: 480)
        XCTAssertEqual(noInputLatency, -7680, "an input that reports nothing adds only the capture buffer")
    }

    func testPlayAlongIsNeverMoved() {
        let kinds: [StemKind] = [.playAlong, .ambience]
        for kind in kinds {
            let moved = offset(kind, input: interface, capture: 480, nudgeMs: 10)
            XCTAssertEqual(moved, 0, "\(kind)")
        }
    }
}
