import Foundation
import InStrumCore

/// Follow the Mac's Reduce Motion (Small Wins spec §6): while the setting is on and the Mac asks for less motion, the
/// visuals move as if Gentle visuals were on (your own Gentle visuals setting never changes), and the director hears it.
extension AppModel {
    /// Starts following the Mac's flag (the app does this once, at launch; tests hand it a fake), and reads it now. Nil
    /// follows the Mac's own (`SystemReduceMotion`).
    public func startWatchingReduceMotion(_ given: ReduceMotionWatching? = nil) {
        let watcher: ReduceMotionWatching
        if let given { watcher = given } else { watcher = SystemReduceMotion() }
        reduceMotionWatcher?.onChange = nil
        reduceMotionWatcher = watcher
        watcher.onChange = { [weak self] in self?.updateReduceMotion() }
        updateReduceMotion()
    }

    /// The setting and the Mac's flag together: the director's controls follow at once, and a change reaches the canvas.
    func updateReduceMotion() {
        let on = followReduceMotion && (reduceMotionWatcher?.isOn ?? false)
        sceneControls.reduceMotion = on
        guard on != reduceMotionActive else { return }
        reduceMotionActive = on
        visualsVersion += 1
    }
}
