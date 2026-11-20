import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

public enum InputCaptureError: Error, Equatable {
    /// The input couldn't be opened (it went away, it is busy, or its rate changed as it opened).
    case cannotOpen(String)
}

/// One input, captured (Recorder spec §5.2, §6, §7): a second, input-only `AVAudioEngine` on the chosen device writes
/// the chosen channels into a `CaptureRing`; `sourceNode`, attached in the app's engine, reads them at the engine's rate,
/// applies the input gain and meters them. The two engines run on their own clocks; the ring follows the drift.
///
/// Nothing opens the device until `start()`. If the device is unplugged (or changes so that the capture can't follow),
/// the capture stops by itself and calls `onStopped`, once, on the main thread. The source node then plays silence.
public final class InputCapture {
    public let device: InputDevice
    public let channels: ChannelChoice
    /// The app's engine's rate, which `sourceNode` plays at.
    public let engineRate: Double
    /// The input's own rate (the engine's if the device doesn't report one).
    public let deviceRate: Double
    public let targetMs: Double
    /// `sourceNode`'s format: stereo at the engine's rate.
    public let format: AVAudioFormat
    /// Attach this in the app's engine.
    public let sourceNode: AVAudioSourceNode
    /// Called on the main thread when the device goes away mid-capture (or can't be followed after a change).
    public var onStopped: (() -> Void)?

    let ring: CaptureRing
    let input: CaptureInput
    let output: CaptureOutput
    private var engine: AVAudioEngine?
    private var sink: AVAudioSinkNode?
    private var configObserver: NSObjectProtocol?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var hasStopped = false
    private var gain: Float = 0

    public init(device: InputDevice, channels: ChannelChoice, engineRate: Double, targetMs: Double = 10) {
        let rate = engineRate > 0 ? engineRate : 44_100
        let inputRate = InputDevices.sampleRate(device.id) ?? rate
        let ms = min(100, max(1, targetMs))
        let choice = channels.fits(channels: device.channels) ? channels : ChannelChoice.defaultChoice(channels: device.channels)
        let ring = CaptureRing(capacityFrames: Int(inputRate / 2), targetFrames: Int((ms / 1000 * inputRate).rounded()),
                               writeRate: inputRate, readRate: rate)
        let output = CaptureOutput(ring: ring, rate: rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        self.device = device
        self.channels = choice
        self.engineRate = rate
        self.deviceRate = inputRate
        self.targetMs = ms
        self.format = format
        self.ring = ring
        self.input = CaptureInput(ring: ring, channels: choice)
        self.output = output
        // The engine's render thread: read, gain, meter. No allocation, lock or Objective-C call.
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count > 0, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            output.render(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
    }

    deinit { stop() }

    /// Opens the device and starts capturing. Throws `InputCaptureError.cannotOpen` if it can't.
    public func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard let unit = node.audioUnit, Self.select(device.id, on: unit) else { throw InputCaptureError.cannotOpen(device.name) }
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0, abs(hardware.sampleRate - deviceRate) < 1 else {
            throw InputCaptureError.cannotOpen(device.name)
        }
        // The input's I/O thread: copy the chosen channels into the ring. No allocation, lock or Objective-C call.
        let writer = input
        let sink = AVAudioSinkNode { _, frameCount, list -> OSStatus in
            writer.write(list, frames: Int(frameCount))
            return noErr
        }
        engine.attach(sink)
        engine.connect(node, to: sink, format: hardware)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw InputCaptureError.cannotOpen(device.name)
        }
        self.engine = engine
        self.sink = sink
        hasStopped = false
        watch(engine)
    }

    /// Stops capturing and lets the device go. The source node plays silence from here on.
    public func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let block = aliveListener {
            var addr = CoreAudioDevices.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(device.id, &addr, DispatchQueue.main, block)
            aliveListener = nil
        }
        engine?.stop()
        engine = nil
        sink = nil
    }

    public var isRunning: Bool { engine?.isRunning ?? false }

    /// The input gain in dB, −24…+24 (spec §6).
    public var gainDB: Float {
        get { gain }
        set {
            gain = newValue.isFinite ? min(24, max(-24, newValue)) : 0
            output.setGain(powf(10, gain / 20))
        }
    }

    /// The meter: the loudest sample lately (after the gain), falling back over about a second.
    public var peak: Float { output.peak }
    /// A sample reached full scale in the last 1.5 s (the meter turns red).
    public var clipped: Bool { output.clipped }
    /// The capture buffer's target in the engine's frames (`RecordingLatency.offsetFrames`'s `captureBufferFrames`).
    public var bufferFrames: Int { Int((targetMs / 1000 * engineRate).rounded()) }

    /// The device went away (its listener or the engine's configuration change said so; tests call it directly):
    /// stop, and tell the owner once.
    func deviceLost() {
        guard !hasStopped else { return }
        hasStopped = true
        stop()
        onStopped?()
    }

    // MARK: - Private

    private static func select(_ id: AudioDeviceID, on unit: AudioUnit) -> Bool {
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// Watches for the device going away, and for the input engine's configuration changing under it.
    private func watch(_ engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.configurationChanged() }
        var addr = CoreAudioDevices.address(kAudioDevicePropertyDeviceIsAlive)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !CoreAudioDevices.isAlive(self.device.id) else { return }
            self.deviceLost()
        }
        if AudioObjectAddPropertyListenerBlock(device.id, &addr, DispatchQueue.main, block) == noErr { aliveListener = block }
    }

    /// The input engine stopped because something changed (its device, its format). Starts it again on the same device
    /// at the same rate if it can; otherwise the capture is over.
    private func configurationChanged() {
        guard let engine, let sink else { return }
        guard CoreAudioDevices.isAlive(device.id) else { return deviceLost() }
        engine.stop()
        let node = engine.inputNode
        guard let unit = node.audioUnit, Self.select(device.id, on: unit) else { return deviceLost() }
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0, abs(hardware.sampleRate - deviceRate) < 1 else {
            return deviceLost()
        }
        engine.disconnectNodeInput(sink)
        engine.connect(node, to: sink, format: hardware)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            deviceLost()
        }
    }
}

/// The writer's side (the input's I/O thread): finds the chosen channels in what the device delivers (one buffer per
/// channel, or interleaved) and writes them to the ring. A single channel goes to both sides (mono, centred); a channel
/// the device doesn't have is silence. Its scratch memory is made here, once.
final class CaptureInput: @unchecked Sendable {
    let ring: CaptureRing
    let channels: ChannelChoice
    static var scratchFrames: Int { 4096 }
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>

    init(ring: CaptureRing, channels: ChannelChoice) {
        self.ring = ring
        self.channels = channels
        scratchLeft = .allocate(capacity: Self.scratchFrames)
        scratchLeft.initialize(repeating: 0, count: Self.scratchFrames)
        scratchRight = .allocate(capacity: Self.scratchFrames)
        scratchRight.initialize(repeating: 0, count: Self.scratchFrames)
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func write(_ list: UnsafePointer<AudioBufferList>, frames n: Int) {
        guard n > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let left = Self.find(channels.left, in: buffers, frames: n)
        var right = left
        if let r = channels.right { right = Self.find(r, in: buffers, frames: n) }
        if let left, let right, left.stride == 1, right.stride == 1 {
            ring.write(left: left.samples, right: right.samples, frames: n)
            return
        }
        // Interleaved, or a channel that isn't there: gathered into the scratch buffers, a chunk at a time.
        var done = 0
        while done < n {
            let count = min(n - done, Self.scratchFrames)
            Self.gather(left, from: done, count: count, into: scratchLeft)
            Self.gather(right, from: done, count: count, into: scratchRight)
            ring.write(left: scratchLeft, right: scratchRight, frames: count)
            done += count
        }
    }

    /// Where channel `c` is: its first sample and the distance between its samples. nil if the device doesn't have it.
    static func find(_ c: Int, in buffers: UnsafeMutableAudioBufferListPointer,
                     frames: Int) -> (samples: UnsafePointer<Float>, stride: Int)? {
        var first = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            if c >= first && c < first + count {
                guard let data = buffer.mData, Int(buffer.mDataByteSize) >= frames * count * MemoryLayout<Float>.size else { return nil }
                return (UnsafePointer(data.assumingMemoryBound(to: Float.self)) + (c - first), count)
            }
            first += count
        }
        return nil
    }

    private static func gather(_ source: (samples: UnsafePointer<Float>, stride: Int)?, from start: Int, count: Int,
                               into out: UnsafeMutablePointer<Float>) {
        guard let source else {
            out.update(repeating: 0, count: count)
            return
        }
        var p = source.samples + start * source.stride
        for i in 0..<count {
            out[i] = p.pointee
            p += source.stride
        }
    }
}

/// The reader's side (the engine's render thread): reads the ring, applies the input gain (gliding to a new value over
/// one block, so a change never clicks) and keeps the meter. The main thread only reads the meter and asks for a gain.
final class CaptureOutput: @unchecked Sendable {
    let ring: CaptureRing
    let rate: Double

    private struct State {
        var gain: Float = 1
        var meter: Float = 0
        var rendered = 0
        var clippedAt = Int.min / 2
    }
    /// Written by the render thread only.
    private let state: UnsafeMutablePointer<State>
    /// Written by the main thread only: the gain asked for.
    private let wanted: UnsafeMutablePointer<Float>

    init(ring: CaptureRing, rate: Double) {
        self.ring = ring
        self.rate = rate > 0 ? rate : 44_100
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        wanted = .allocate(capacity: 1)
        wanted.initialize(to: 1)
    }

    deinit {
        state.deallocate()
        wanted.deallocate()
    }

    func setGain(_ linear: Float) { wanted.pointee = linear }

    var peak: Float { state.pointee.meter }
    var clipped: Bool { state.pointee.rendered - state.pointee.clippedAt < Int(rate * 1.5) }

    func render(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames n: Int) {
        guard n > 0 else { return }
        ring.read(left: l, right: r, frames: n)
        var s = state.pointee
        let goal = wanted.pointee
        var g = s.gain
        let step = (goal - g) / Float(n)
        var loudest: Float = 0
        for i in 0..<n {
            if step != 0 { g = i == n - 1 ? goal : g + step }
            let a = l[i] * g, b = r[i] * g
            l[i] = a
            r[i] = b
            loudest = max(loudest, max(abs(a), abs(b)))
        }
        s.gain = goal
        s.meter = max(loudest, s.meter * expf(-Float(n) / (0.3 * Float(rate))))
        s.rendered += n
        if loudest >= 1 { s.clippedAt = s.rendered }
        state.pointee = s
    }
}
