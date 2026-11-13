import AppKit
import MetalKit
import QuartzCore
import InStrumCore
import InStrumAudio

/// The graphics chip's side of frame pacing: how many frames are still on the GPU, and how long the slowest finished one
/// kept it busy since the last look. Written from Metal's completion handlers, read on the main thread.
final class GPUClock: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightCount = 0
    private var slowest = 0.0

    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return inFlightCount }
    func committed() { lock.lock(); inFlightCount += 1; lock.unlock() }
    func finished(gpuSeconds: Double) {
        lock.lock()
        inFlightCount = max(0, inFlightCount - 1)
        if gpuSeconds.isFinite, gpuSeconds > slowest { slowest = gpuSeconds }
        lock.unlock()
    }
    /// The slowest finished frame's GPU time since the last call (0 when none finished).
    func take() -> Double {
        lock.lock(); defer { slowest = 0; lock.unlock() }
        return slowest
    }
}

/// Runs the active theme every frame: events → director → theme renderer → finishing → screen.
///
/// Frame pacing keeps the graphics chip from ever being swamped (an Intel Mac's GPU kept saturated can freeze the whole
/// machine): at most two frames are on the GPU at once (one while the safety net is in), a frame is skipped rather than
/// queued behind them, every frame's GPU time feeds `AutoQuality`, and on an Intel or AMD GPU every quality draws a
/// capped number of pixels and Ultra is High.
///
/// Nothing is compiled on the draw path (real-Mac performance, 14 Nov): the worlds' renderers are made off the main thread
/// by `WorldRenderers`, all of them warmed up from launch (the world on screen first), and a frame whose world isn't made
/// yet leaves the last frame on screen (a plain dark one at launch) rather than waiting. Each frame's main-thread time and
/// the world's step within it go to the performance log, with whether the frame is in a world's first seconds and, for a
/// stall, whether the window was hidden or the app in the background during it.
final class ThemeCanvas: NSObject, MTKViewDelegate {
    private let model: AppModel
    private let queue: MTLCommandQueue
    private let device: MTLDevice
    private let director: SceneDirector
    private var stack: RenderStack?
    private let worlds: WorldRenderers
    private var autoQuality: AutoQuality
    private var lastTime: CFTimeInterval = 0
    private var seenVersion = -1
    /// When the "Meteors tonight" line was last read from the sky (once a second is plenty).
    private var meteorLineTime: CFTimeInterval = -.infinity
    private var level: QualityLevel = .lite
    private let gpuClock = GPUClock()
    /// An Apple GPU (Apple silicon); false on an Intel or AMD graphics chip.
    private let appleGPU: Bool
    /// True once a world's frame has been shown (until then, a frame whose world isn't made yet is a plain dark one).
    private var shownAFrame = false
    /// The world on screen and when it was entered (its first frame), for the report's entry frames.
    private var visitWorld = ""
    private var visitStart: CFTimeInterval = 0
    /// What happened since the last drawn frame: the window was hidden, or the app went to the background.
    private var hiddenSinceFrame = false, backgroundSinceFrame = false
    private weak var view: MTKView?
    private var observers: [NSObjectProtocol] = []

    @MainActor
    init?(view: MTKView, model: AppModel) {
        guard let device = view.device, let queue = device.makeCommandQueue(),
              let stack = RenderStack(device: device, pixelFormat: view.colorPixelFormat) else { return nil }
        self.model = model
        self.device = device
        self.queue = queue
        self.stack = stack
        self.worlds = WorldRenderers(device: device)
        self.director = SceneDirector(themeID: model.themeID, state: model.themeState(for: model.themeID),
                                      reaction: model.reaction)
        self.autoQuality = AutoQuality(setting: model.quality)
        self.appleGPU = device.supportsFamily(.apple7)
        self.view = view
        super.init()
        director.sky.reset(settings: model.skySettings.holdingBack())   // launch with the chosen weather, not a blend into it
        // The app never builds a pipeline inside a frame: what a frame finds missing is made off the main thread.
        ShaderWork.defersDrawPathBuilds = true
        worlds.warmUp(first: model.themeID)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                            queue: .main) { [weak self] note in
            MainActor.assumeIsolated { () -> Void in
                guard let self, let window = note.object as? NSWindow, window === self.view?.window,
                      !window.occlusionState.contains(.visible) else { return }
                self.hiddenSinceFrame = true
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in self?.backgroundSinceFrame = true }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { stack?.resize(width: Int(size.width), height: Int(size.height)) }
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(view) }
    }

    @MainActor
    private func syncSettings() {
        guard model.visualsVersion != seenVersion else { return }
        seenVersion = model.visualsVersion
        if model.themeID != director.themeID {
            director.switchTheme(to: model.themeID, state: model.themeState(for: model.themeID))
        } else {
            director.parameters = ThemeRegistry.parameterSet(for: director.themeID, state: model.themeState(for: director.themeID))
        }
        autoQuality.setting = model.quality
        director.reaction = model.reaction
        director.sky.settings = model.skySettings.holdingBack()   // held-back weathers never run
        director.mood = model.mood
        director.excitementSettings = model.excitementSettings   // Energy, big moments, surprises, build and drop
    }

    /// What the app was doing in the gap before this frame, for a stall's line in the report: its window hidden at some
    /// point (the Mac stops asking for frames: a pause, not a freeze), in the background with its window showing, or in
    /// front. Clears the marks for the next gap.
    @MainActor
    private func gapCause(_ view: MTKView) -> PerformanceLog.StallCause {
        let visible = view.window.map { $0.occlusionState.contains(.visible) } ?? true
        let active = NSApp?.isActive ?? true
        let cause: PerformanceLog.StallCause
        if hiddenSinceFrame || !visible {
            cause = .hidden
        } else if backgroundSinceFrame || !active {
            cause = .background
        } else {
            cause = .active
        }
        hiddenSinceFrame = false
        backgroundSinceFrame = false
        return cause
    }

    /// A plain dark frame (the view's clear colour), for a launch whose world isn't made yet.
    @MainActor
    private func presentDark(_ view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        e.endEncoding()
        cb.present(drawable)
        let clock = gpuClock
        cb.addCompletedHandler { _ in clock.finished(gpuSeconds: 0) }
        clock.committed()
        cb.commit()
    }

    @MainActor
    private func drawFrame(_ view: MTKView) {
        // Never queue a frame behind work the GPU hasn't finished: skip this one instead (the clock below carries the
        // gap). Two may be in flight normally, one once the safety net has stepped in.
        if gpuClock.inFlight >= (autoQuality.rescued || autoQuality.pixelScale < 1 ? 1 : 2) { return }
        let start = CACurrentMediaTime()
        ShaderWork.drawing = true
        defer { ShaderWork.drawing = false }
        syncSettings()
        guard let stack else { return }
        let now = CACurrentMediaTime()
        let frameTime = lastTime == 0 ? 0 : max(0, now - lastTime)
        let frameDt = min(0.1, frameTime)
        lastTime = now
        let gpuTime = gpuClock.take()   // read once: the safety net and the performance log both see this frame's number
        level = autoQuality.record(frameTime: frameTime, gpuTime: gpuTime)
        if !appleGPU && level == .ultra { level = .high }
        let backing = view.window?.backingScaleFactor ?? 2
        let px = RenderScale.pixels(points: (Double(view.bounds.width), Double(view.bounds.height)),
                                    backingScale: Double(backing), quality: level,
                                    pixelScale: autoQuality.pixelScale, appleGPU: appleGPU)
        let wanted = CGSize(width: px.width, height: px.height)
        if view.drawableSize != wanted { view.drawableSize = wanted }
        let size = view.drawableSize
        // Help > Copy Performance Report: this frame, by world and quality (no allocation after a key's first frame),
        // recorded as the frame ends, whichever way it ends, with its main-thread time and the world's step.
        let world = director.themeID
        let entered = world != visitWorld
        if entered {
            visitWorld = world
            visitStart = now
        }
        let cause = gapCause(view)
        let recordQuality = level, pixelScale = autoQuality.pixelScale, rescued = autoQuality.rescued
        var stepSeconds = 0.0
        defer {
            model.performanceLog.record(world: world, quality: recordQuality, frameTime: frameTime, gpuTime: gpuTime,
                                        pixelScale: pixelScale, rescued: rescued, pixels: (Int(size.width), Int(size.height)),
                                        cpuTime: CACurrentMediaTime() - start, stepTime: stepSeconds,
                                        entering: now - visitStart < PerformanceLog.entrySeconds, entered: entered,
                                        stallCause: cause)
        }
        stack.resize(width: Int(size.width), height: Int(size.height))
        var controls = model.frameSceneControls   // hold, the sleep dim, Reduce Motion and breathing, before the events
        controls.gentle = model.effectiveGentleVisuals   // and gentle visuals: the drive's far siren rests
        director.controls = controls
        director.handle(model.drainEvents(), at: now)
        let sound = model.soundReading
        let hub = director.hub
        hub.set(.attack, sound.attack, at: now)
        hub.set(.brightness, sound.brightness, at: now)
        hub.set(.ring, sound.ring, at: now)
        hub.set(.texture, sound.texture, at: now)
        hub.set(.loudness, sound.loudness, at: now)
        hub.set(.width, sound.width, at: now)
        for (address, value) in model.drainDialChanges() { hub.set(.dial(address), value, at: now) }
        director.instrumentPulse = model.instrumentPulse   // Blue Depth's arp grid, for the visuals that blink with it
        director.instrumentPressure = model.instrumentPressure   // the grand's morph and its repeats, for the worlds
        director.instrumentRepeat = model.instrumentRepeat
        let stepStart = CACurrentMediaTime()
        let frame = director.step(dt: frameDt, t: now, quality: level)
        stepSeconds = CACurrentMediaTime() - stepStart
        model.cueInstrument(director.instrumentCue)   // Excitement's tension and drop (or the pressure) to the instrument
        let dt = director.visualDt   // the renderers' clock, as the director's controls shape it
        model.forceMorph(director.forcedMorph)   // the world's forced morph (the storm's arrival) to the grand
        model.updateAmbience(director.ambience(for: frame, at: now), at: now)
        model.noteSceneReport(director.report)
        let gentle = model.effectiveGentleVisuals
        // The Living Sky panel's "Meteors tonight" line, from the sky this world draws (its own rules applied: the lounge
        // has none), once a second.
        if now - meteorLineTime >= 1 || now < meteorLineTime {
            meteorLineTime = now
            model.setMeteorsTonight(SkyControls.meteorsTonight((frame as? SkyBearing)?.sky.shower))
        }

        // The world's renderer, if it is made: else the last frame stays on screen (a dark one at launch) while it is
        // made off the main thread, at the front of the line.
        guard let renderer = worlds.renderer(for: frame, params: director.parameters, quality: level, gentle: gentle,
                                             dt: dt, size: size) else {
            if !shownAFrame { presentDark(view) }
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        renderer.render(stack: stack, commandBuffer: cb)
        var post = renderer.post
        post.exposure *= director.exposureScale   // the sleep dim, up to a stop
        stack.post(into: pass, commandBuffer: cb, settings: post)
        cb.present(drawable)
        let clock = gpuClock
        cb.addCompletedHandler { cb in clock.finished(gpuSeconds: cb.gpuEndTime - cb.gpuStartTime) }
        clock.committed()
        cb.commit()
        shownAFrame = true
    }
}
