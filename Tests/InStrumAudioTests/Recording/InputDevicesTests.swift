import XCTest
import AVFoundation
import CoreAudio
@testable import InStrumAudio

/// The Mac's inputs (Recorder spec §5.2, §6; plan Task 4): the list, BlackHole, and the channel choices. CI's Macs have
/// no audio inputs, so the list may be empty; a test that needs a real input is skipped there.
final class InputDevicesTests: XCTestCase {

    /// An audio buffer list of `channels` channels, `frames` long, channel `c` holding `(c + 1) / 8` throughout: one
    /// buffer per channel, or (interleaved) one buffer holding them all.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var memory: [UnsafeMutablePointer<Float>] = []

        init(channels: Int, frames: Int, interleaved: Bool) {
            list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channels)
            if interleaved {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
                for i in 0..<frames {
                    for c in 0..<channels { p[i * channels + c] = Float(c + 1) / 8 }
                }
                memory.append(p)
                list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(channels * frames * 4), mData: p)
            } else {
                for c in 0..<channels {
                    let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                    p.initialize(repeating: Float(c + 1) / 8, count: frames)
                    memory.append(p)
                    list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: p)
                }
            }
        }

        deinit {
            for p in memory { p.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    /// What a capture's writer makes of a 4-channel input with `choice`: the left and right the ring then plays.
    private func through(_ choice: ChannelChoice, interleaved: Bool) -> (left: Float, right: Float) {
        let ring = CaptureRing(capacityFrames: 8192, targetFrames: 480, writeRate: 48_000)
        let writer = CaptureInput(ring: ring, channels: choice)
        let buffers = Buffers(channels: 4, frames: 256, interleaved: interleaved)
        for _ in 0..<16 { writer.write(UnsafePointer(buffers.list.unsafeMutablePointer), frames: 256) }
        var left = [Float](repeating: 0, count: 512), right = left
        ring.read(left: &left, right: &right, frames: 512)
        return (left[511], right[511])
    }

    func testChannelPairsAndMonoCentre() {
        let one = ChannelChoice.choices(channels: 1)
        let two = ChannelChoice.choices(channels: 2)
        let twoLabels = two.map(\.label)
        let three = ChannelChoice.choices(channels: 3)
        let sixteen = ChannelChoice.choices(channels: 16)
        let lastLabel = sixteen.last?.label
        let defaultTwo = ChannelChoice.defaultChoice(channels: 2)
        let defaultOne = ChannelChoice.defaultChoice(channels: 1)
        let defaultSixteen = ChannelChoice.defaultChoice(channels: 16)
        let none = ChannelChoice.choices(channels: 0)
        XCTAssertEqual(one, [ChannelChoice(left: 0)])
        XCTAssertEqual(twoLabels, ["1", "2", "1+2"])
        XCTAssertEqual(two, [ChannelChoice(left: 0), ChannelChoice(left: 1), ChannelChoice(left: 0, right: 1)])
        XCTAssertEqual(three.count, 4, "1, 2, 1+2, 3")
        XCTAssertEqual(sixteen.count, 24)
        XCTAssertEqual(sixteen.last, ChannelChoice(left: 14, right: 15))
        XCTAssertEqual(lastLabel, "15+16")
        XCTAssertEqual(defaultTwo, ChannelChoice(left: 0, right: 1))
        XCTAssertEqual(defaultOne, ChannelChoice(left: 0))
        XCTAssertEqual(defaultSixteen, ChannelChoice(left: 0, right: 1))
        XCTAssertTrue(none.isEmpty)

        // A single channel is centred: the same on both sides. A pair keeps its sides. Separate buffers or interleaved.
        let mono = through(ChannelChoice(left: 2), interleaved: false)
        let pair = through(ChannelChoice(left: 2, right: 3), interleaved: false)
        let monoInterleaved = through(ChannelChoice(left: 2), interleaved: true)
        let pairInterleaved = through(ChannelChoice(left: 2, right: 3), interleaved: true)
        let missing = through(ChannelChoice(left: 6, right: 7), interleaved: false)
        XCTAssertEqual(mono.left, 3.0 / 8)
        XCTAssertEqual(mono.right, 3.0 / 8, "mono feeds both outputs equally")
        XCTAssertEqual(pair.left, 3.0 / 8)
        XCTAssertEqual(pair.right, 4.0 / 8)
        XCTAssertEqual(monoInterleaved.left, 3.0 / 8)
        XCTAssertEqual(monoInterleaved.right, 3.0 / 8)
        XCTAssertEqual(pairInterleaved.left, 3.0 / 8)
        XCTAssertEqual(pairInterleaved.right, 4.0 / 8)
        XCTAssertEqual(missing.left, 0, "a channel the input doesn't have is silence")
        XCTAssertEqual(missing.right, 0)
    }

    func testBlackHoleIsRecognisedByName() {
        let two = InputDevices.isBlackHole(name: "BlackHole 2ch")
        let sixteen = InputDevices.isBlackHole(name: "BlackHole 16ch")
        let reverb = InputDevices.isBlackHole(name: "Black Hole Reverb")
        let joined = InputDevices.isBlackHole(name: "BlackHoleVerb")
        let mic = InputDevices.isBlackHole(name: "MacBook Pro Microphone")
        let device = InputDevice(id: 0, uid: "BlackHole16ch_UID", name: "BlackHole 16ch", channels: 16)
        let scarlett = InputDevice(id: 0, uid: "AppleUSBAudioEngine:Focusrite:Scarlett 2i2", name: "Scarlett 2i2 USB", channels: 2)
        let devices = [scarlett, device, InputDevice(id: 0, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", channels: 2)]
        let chosen = InputDevices.blackHole(in: devices)
        let noneAmong = InputDevices.blackHole(in: [scarlett])
        XCTAssertTrue(two)
        XCTAssertTrue(sixteen)
        XCTAssertFalse(reverb)
        XCTAssertFalse(joined)
        XCTAssertFalse(mic)
        XCTAssertTrue(device.isBlackHole)
        XCTAssertFalse(scarlett.isBlackHole)
        XCTAssertEqual(chosen?.name, "BlackHole 2ch", "the stereo one is the Mac's sound")
        XCTAssertNil(noneAmong)
    }

    func testInputListNeverCrashesWithoutDevices() {
        let devices = InputDevices.all()
        let blackHole = InputDevices.blackHole()
        var bad = 0
        for d in devices {
            if d.channels <= 0 || d.uid.isEmpty || d.name.isEmpty { bad += 1 }
            let latency = InputDevices.latency(d.id)
            if latency.latencyFrames < 0 || latency.safetyFrames < 0 || latency.bufferFrames < 0 { bad += 1 }
        }
        let uids = Set(devices.map(\.uid))
        let distinct = uids.count == devices.count
        let blackHoleIsOne = blackHole?.isBlackHole ?? true
        let nothing = InputDevices.latency(0)
        XCTAssertEqual(bad, 0)
        XCTAssertTrue(distinct)
        XCTAssertTrue(blackHoleIsOne)
        XCTAssertEqual(nothing.total, 0, "a device that isn't there reports nothing")
    }

    /// A real input opens, delivers frames and stops. Skipped where there is none (CI), or where macOS can't be asked
    /// for microphone permission.
    func testALiveInputCapturesAndStops() throws {
        let devices = InputDevices.all()
        guard let device = devices.first else { throw XCTSkip("this Mac has no audio inputs") }
        if ProcessInfo.processInfo.environment["CI"] != nil { throw XCTSkip("CI's Macs can't be asked for microphone permission") }
        let capture = InputCapture(device: device, channels: ChannelChoice.defaultChoice(channels: device.channels), engineRate: 48_000)
        do { try capture.start() } catch { throw XCTSkip("\(device.name) can't be opened here: \(error)") }
        let running = capture.isRunning
        Thread.sleep(forTimeInterval: 0.5)
        let written = capture.ring.framesWritten
        capture.stop()
        let stopped = !capture.isRunning
        XCTAssertTrue(running)
        XCTAssertGreaterThan(written, 0)
        XCTAssertTrue(stopped)
    }
}
