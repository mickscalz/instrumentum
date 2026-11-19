import XCTest
import AVFoundation
@testable import InStrumAudio
@testable import InStrumCore

/// The one timeline in the engine (Recorder plan part 2): the track and the layers start, pause, seek and loop together,
/// and the track's tempo keeps its pitch. The track is a ramp that says which of its frames is playing.
@MainActor
final class TransportTests: XCTestCase {
    var dir: URL!
    let rate = 48_000.0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TransportTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// An engine with a 4 s ramp as the track (on the left only when `layer` is set, with a 4 s ramp layer on the right).
    private func engineWithRamp(layer: Bool = false) async throws -> AudioEngine {
        let e = try PlaybackAudio.engine()
        let ramp = PlaybackAudio.ramp(frames: 192_000)
        let silence = [Float](repeating: 0, count: 192_000)
        let track = dir.appendingPathComponent("Track.wav")
        try PlaybackAudio.writeWAV(track, left: ramp, right: layer ? silence : ramp, rate: rate)
        let seconds = try await e.loadTrack(track)
        XCTAssertEqual(seconds, 4, accuracy: 1e-9)
        if layer {
            let url = dir.appendingPathComponent("Layer 1 — Ramp.wav")
            try PlaybackAudio.writeWAV(url, left: silence, right: ramp, rate: rate)
            try await e.loadLayers([(url: url, gain: 1, offsetFrames: 0)])
        }
        return e
    }

    func testSeekWhilePlayingCarriesOn() async throws {
        let e = try await engineWithRamp(layer: true)
        let duration = e.transportDuration
        let t0 = e.engine.manualRenderingSampleTime
        let start = e.transportPlay(from: 0, rate: 1)
        let first = try PlaybackAudio.render(e, frames: 24_000)
        let before = e.transportPosition
        e.transportSeek(2)
        let second = try PlaybackAudio.render(e, frames: 24_000)
        let after = e.transportPosition

        let lead = Int(start - t0)
        let firstTrack = PlaybackAudio.frame(of: first.left[lead])
        let firstLayer = PlaybackAudio.frame(of: first.right[lead])
        let gap = PlaybackAudio.peak(second.left[0..<lead])
        let seekTrack = PlaybackAudio.frame(of: second.left[lead])
        let seekLayer = PlaybackAudio.frame(of: second.right[lead])
        let endTrack = PlaybackAudio.frame(of: second.left[23_999])
        let endLayer = PlaybackAudio.frame(of: second.right[23_999])
        _ = e.transportPause()

        XCTAssertEqual(duration, 4, accuracy: 1e-9)
        XCTAssertEqual(lead, 512, "two buffers from now")
        XCTAssertEqual(firstTrack, 0, accuracy: 0.5, "the track starts at its first frame")
        XCTAssertEqual(firstLayer, 0, accuracy: 0.5, "with the layer")
        XCTAssertEqual(before, Double(24_000 - 512) / rate, accuracy: 1e-9)
        XCTAssertEqual(gap, 0, "the old place stops at once")
        XCTAssertEqual(seekTrack, 96_000, accuracy: 0.5, "from 2 s, to the frame")
        XCTAssertEqual(seekLayer, 96_000, accuracy: 0.5, "the layer moved with it")
        XCTAssertEqual(endTrack, Double(96_000 + 23_999 - 512), accuracy: 0.5, "and it carries on")
        XCTAssertEqual(endLayer, Double(96_000 + 23_999 - 512), accuracy: 0.5)
        XCTAssertEqual(after, 2 + Double(24_000 - 512) / rate, accuracy: 1e-9)
    }

    /// The frames of the ramp heard from `from` on.
    private func frames(_ x: [Float], from: Int) -> [Double] {
        var f: [Double] = []
        f.reserveCapacity(x.count - from)
        for i in from..<x.count { f.append(PlaybackAudio.frame(of: x[i])) }
        return f
    }

    /// Where the ramp jumps back: (index, the frame before, the frame after).
    private func wraps(_ f: [Double]) -> [(index: Int, before: Double, after: Double)] {
        var w: [(index: Int, before: Double, after: Double)] = []
        for i in 1..<f.count where f[i] < f[i - 1] - 100 { w.append((i, f[i - 1], f[i])) }
        return w
    }

    func testLoopWrapsWithinTenMilliseconds() async throws {
        let e = try await engineWithRamp()

        // A loop from 1.0 to 1.5 s, played from 0.9 s: on to 1.5, then back to 1.0 every half second.
        e.setTransportLoop(in: 1, out: 1.5)
        let start = e.transportPlay(from: 0.9, rate: 1)
        let out = try PlaybackAudio.render(e, frames: 512 + 120_000)
        let lead = Int(start - out.start)
        let f = frames(out.left, from: lead)
        let w = wraps(f)
        let count = w.count
        let firstHeard = f.first ?? -1
        let firstWrap = w.first ?? (index: -1, before: -1, after: -1)
        var worstPeriod = 0
        for k in 1..<max(1, w.count) { worstPeriod = max(worstPeriod, abs(w[k].index - w[k - 1].index - 24_000)) }
        let position = e.transportPosition

        XCTAssertEqual(firstHeard, 43_200, accuracy: 0.5, "from 0.9 s")
        XCTAssertEqual(count, 4, "0.6 s to the first wrap, then every 0.5 s of 2.5 s")
        XCTAssertEqual(Double(firstWrap.index), 28_800, accuracy: 480, "at 1.5 s, within 10 ms")
        XCTAssertEqual(firstWrap.before, 71_999, accuracy: 480)
        XCTAssertEqual(firstWrap.after, 48_000, accuracy: 480, "back to 1.0 s")
        XCTAssertLessThanOrEqual(worstPeriod, 480)
        XCTAssertGreaterThanOrEqual(position, 1)
        XCTAssertLessThan(position, 1.5)

        // Playing on without a loop, then OUT pressed at 1.3 s: back to IN at once, and a loop of 0.3 s.
        e.setTransportLoop(in: nil, out: nil)
        let again = e.transportPlay(from: 1, rate: 1)
        let run = try PlaybackAudio.render(e, frames: 512 + 14_400)
        let pressed = e.transportPosition
        e.setTransportLoop(in: 1, out: pressed)
        let looped = try PlaybackAudio.render(e, frames: 512 + 48_000)
        let loopFrames = frames(looped.left, from: 512)
        let loopWraps = wraps(loopFrames)
        let loopStart = loopFrames.first ?? -1
        var worstShort = 0
        for k in 1..<max(1, loopWraps.count) { worstShort = max(worstShort, abs(loopWraps[k].index - loopWraps[k - 1].index - 14_400)) }
        let shortCount = loopWraps.count

        // OUT again leaves the loop: it plays on past 1.3 s.
        e.setTransportLoop(in: 1, out: nil)
        let unlooped = try PlaybackAudio.render(e, frames: 512 + 24_000)
        let freeFrames = frames(unlooped.left, from: 512)
        let freeWraps = wraps(freeFrames).count
        let furthest = freeFrames.max() ?? 0
        let ranOn = Int(again - run.start)

        XCTAssertEqual(ranOn, 512)
        XCTAssertEqual(pressed, 1.3, accuracy: 1e-9)
        XCTAssertEqual(loopStart, 48_000, accuracy: 0.5, "back to IN")
        XCTAssertEqual(shortCount, 3, "every 0.3 s for 1 s")
        XCTAssertLessThanOrEqual(worstShort, 480)
        XCTAssertEqual(freeWraps, 0)
        XCTAssertGreaterThan(furthest, 62_400 + 4_800, "on past the old loop's end")
    }

    /// A 1 kHz sine at 0.9 of its speed: still 1 kHz, and it lasts 1/0.9 as long.
    func testRateKeepsPitch() async throws {
        let e = try PlaybackAudio.engine()
        let url = dir.appendingPathComponent("Sine.wav")
        try PlaybackAudio.writeWAV(url, left: PlaybackAudio.sine(hz: 1000, seconds: 2, rate: rate, amplitude: 0.5), rate: rate)
        _ = try await e.loadTrack(url)
        _ = e.transportPlay(from: 0, rate: 0.9)
        let out = try PlaybackAudio.render(e, frames: Int(3.6 * rate))
        let position = e.transportPosition

        // The level of each millisecond; the sound is where it is above half the loudest.
        var envelope: [Float] = []
        var i = 0
        while i + 48 <= out.left.count {
            envelope.append(PlaybackAudio.peak(out.left[i..<(i + 48)]))
            i += 48
        }
        let loudest = envelope.max() ?? 0
        var first = -1, last = -1
        for (k, v) in envelope.enumerated() where v > loudest / 2 {
            if first < 0 { first = k }
            last = k
        }
        let heard = Double(last - first + 1) / 1000
        let from = max(0, first) * 48 + 14_400
        let middle = Array(out.left[from..<min(out.left.count, from + 48_000)])
        let pitch = DSPTestKit.fundamental(middle, sampleRate: rate, near: 1000)

        XCTAssertGreaterThan(loudest, 0.3)
        XCTAssertEqual(heard, 2 / 0.9, accuracy: 0.02, "1/0.9 as long, within 20 ms")
        XCTAssertEqual(pitch, 1000, accuracy: 3, "the pitch is kept")
        XCTAssertEqual(position, 2, accuracy: 1e-9, "the timeline is the track's: it stops at its end")
    }

    func testPauseReportsThePosition() async throws {
        let e = try await engineWithRamp()
        let start = e.transportPlay(from: 1, rate: 1)
        let out = try PlaybackAudio.render(e, frames: 512 + 24_000)
        let paused = e.transportPause()
        let lastHeard = PlaybackAudio.frame(of: out.left[512 + 23_999])
        let quiet = try PlaybackAudio.render(e, frames: 4_800)
        let silence = PlaybackAudio.peak(quiet.left[...])
        let still = e.transportPosition
        let resumed = e.transportPlay(from: paused, rate: 1)
        let more = try PlaybackAudio.render(e, frames: 1_024)
        let resumedLead = Int(resumed - more.start)
        let resumedAt = PlaybackAudio.frame(of: more.left[resumedLead])
        let lead = Int(start - out.start)
        _ = e.transportPause()

        XCTAssertEqual(lead, 512)
        XCTAssertEqual(paused, 1.5, accuracy: 1e-9, "1 s + 0.5 s played")
        XCTAssertEqual(lastHeard, 71_999, accuracy: 0.5)
        XCTAssertEqual(silence, 0, "paused is silent")
        XCTAssertEqual(still, 1.5, accuracy: 1e-9, "and stays where it stopped")
        XCTAssertEqual(resumedAt, 72_000, accuracy: 0.5, "and plays on from there, to the frame")
    }
}
