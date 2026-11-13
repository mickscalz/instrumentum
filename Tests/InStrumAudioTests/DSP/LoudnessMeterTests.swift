import XCTest

/// The loudness meter itself (`LoudnessMeter`): BS.1770-4's reference tone, silence, gating and the true peak.
final class LoudnessMeterTests: XCTestCase {
    static let rate = LoudnessMeter.sampleRate

    /// A sine of `amplitude` (full scale 1) at `hz`, `seconds` long, faded in and out over 10 ms (raised cosine), so its
    /// onset rings no overshoot into the true peak.
    static func sine(_ hz: Double, amplitude: Double, seconds: Double, phase: Double = 0) -> [Float] {
        let n = Int(seconds * rate), fade = Int(0.01 * rate)
        return (0..<n).map { (i: Int) -> Float in
            let edge = min(i, n - 1 - i)
            let gain: Double = edge >= fade ? 1 : 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade))
            return Float(amplitude * gain * sin(2 * Double.pi * hz * Double(i) / rate + phase))
        }
    }

    /// The standard's check: a 997 Hz sine at −23 dBFS in both channels reads −23.0 LUFS.
    func testReferenceToneReadsMinus23() {
        let tone = Self.sine(997, amplitude: pow(10, -23.0 / 20), seconds: 10)
        XCTAssertEqual(LoudnessMeter.integrated(tone, tone), -23, accuracy: 0.1)
        // In one channel only it is 3 dB quieter; 10 dB down, 10 LU quieter.
        let silent = [Float](repeating: 0, count: tone.count)
        XCTAssertEqual(LoudnessMeter.integrated(tone, silent), -26.01, accuracy: 0.1)
        let lower = tone.map { $0 * Float(pow(10, -10.0 / 20)) }
        XCTAssertEqual(LoudnessMeter.integrated(lower, lower), -33, accuracy: 0.1)
    }

    /// Silence reads −∞ (no block reaches the absolute gate), and so does a signal shorter than one 400 ms block.
    func testSilenceReadsMinusInfinity() {
        let silent = [Float](repeating: 0, count: Int(5 * Self.rate))
        XCTAssertEqual(LoudnessMeter.integrated(silent, silent), -Double.infinity)
        let faint = silent.map { _ in Float(1e-6) }
        XCTAssertEqual(LoudnessMeter.integrated(faint, faint), -Double.infinity, "under the absolute gate")
        let short = Self.sine(997, amplitude: 0.1, seconds: 0.3)
        XCTAssertEqual(LoudnessMeter.integrated(short, short), -Double.infinity)
        XCTAssertLessThan(LoudnessMeter.truePeak(silent, silent), -200)
    }

    /// The relative gate: a quiet stretch 20 dB under the rest is gated out, so it doesn't pull the reading down.
    func testTheRelativeGateLeavesOutTheQuietStretch() {
        let loud = Self.sine(997, amplitude: pow(10, -23.0 / 20), seconds: 10)
        let quiet = Self.sine(997, amplitude: pow(10, -43.0 / 20), seconds: 10)
        let both = loud + quiet
        XCTAssertEqual(LoudnessMeter.integrated(both, both), -23, accuracy: 0.1)
    }

    /// A sine's true peak is within 0.2 dB of its amplitude, low or high (the samples alone can miss a high one's crest
    /// by a decibel or more).
    func testTruePeakOfASine() {
        for (hz, phase) in [(997.0, 0.0), (5_000.0, 0.4), (11_025.0, 1.1), (15_000.0, 0.7)] {
            let tone = Self.sine(hz, amplitude: 0.5, seconds: 1, phase: phase)
            XCTAssertEqual(LoudnessMeter.truePeak(tone, tone), 20 * log10(0.5), accuracy: 0.2, "\(hz) Hz")
        }
        // The louder channel counts.
        let quiet = Self.sine(997, amplitude: 0.1, seconds: 1), loud = Self.sine(997, amplitude: 0.8, seconds: 1)
        XCTAssertEqual(LoudnessMeter.truePeak(quiet, loud), 20 * log10(0.8), accuracy: 0.2)
    }
}
