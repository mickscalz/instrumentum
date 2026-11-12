import Foundation
import InStrumCore

/// The sleep timer (Small Wins spec §3): choose 15–90 minutes on the moon, and over its last ten (or all of a shorter
/// one) the sound fades to silence and the world drifts toward night. Any key, pedal or click during the fade wakes it:
/// sound and light come back over 3 s, and the timer is Off. Your saved volumes are never touched (the fade is the
/// engine's run-time `sleepGain`), and nothing about the timer is saved.
extension AppModel {
    /// How often the ticker runs while the timer has something to do.
    nonisolated static let sleepTickSeconds = 0.1
    /// The toast a wake shows.
    nonisolated static let awakeText = "You're awake."

    /// Starts the timer at `minutes`, or turns it Off (nil). A fading or resting world wakes first, gliding back.
    public func setSleepTimer(minutes: Int?) {
        let now = sleepClock()
        if let minutes, minutes > 0 {
            sleepFade.start(minutes: minutes, at: now)
        } else {
            sleepFade.turnOff(at: now)
        }
        sleepTick(at: now)
        if !sleepFade.isOff(at: now) { startSleepTicker() }
    }

    /// True while a timer counts down (the moon fills).
    public var sleepTimerRunning: Bool { sleepRemaining != nil }

    /// The director's controls for the frame being drawn now: the sleep dim read from the fade itself while the timer
    /// has anything to do, so the light moves on every frame rather than in the ticker's tenths of a second (a wake
    /// brightens smoothly).
    public var frameSceneControls: SceneControls {
        guard sleepTicker != nil else { return sceneControls }
        var controls = sceneControls
        controls.sleepDim = sleepFade.dim(at: sleepClock())
        return controls
    }

    /// The ticker's body (tests call it directly): a key, pedal or click newer than the fade's start wakes the world, as
    /// of when it happened ("You're awake."); then the engine's sleep gain, the director's dim and the time left follow
    /// the fade, and the ticker stops once there is nothing left to do.
    func sleepTick(at now: Double) {
        if sleepFade.wake(at: lastActivityTime) { showToast(Self.awakeText, symbol: "sunrise") }
        let gain = sleepFade.gain(at: now)
        if engine.sleepGain != gain { engine.sleepGain = gain }
        sceneControls.sleepDim = sleepFade.dim(at: now)
        let remaining = sleepFade.remaining(at: now).map { $0.rounded(.up) }
        if remaining != sleepRemaining { sleepRemaining = remaining }
        if sleepFade.isOff(at: now) { stopSleepTicker() }
    }

    private func startSleepTicker() {
        guard sleepTicker == nil else { return }
        // On the main run loop in its common modes, so it keeps time while a menu is open or a slider is dragged.
        let ticker = Timer(timeInterval: Self.sleepTickSeconds, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.sleepTick(at: self.sleepClock())
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        sleepTicker = ticker
    }

    private func stopSleepTicker() {
        sleepTicker?.invalidate()
        sleepTicker = nil
    }
}
