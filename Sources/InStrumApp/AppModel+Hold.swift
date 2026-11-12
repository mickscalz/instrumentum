import Foundation
import InStrumCore

/// Hold the moment in the app (Small Wins spec §4): the hourglass held down holds it while pressed; a double-click on it
/// or ⌘⇧H latches it until asked again. The soft pedal (or the sostenuto, by the setting) holds it from the keyboard;
/// the director reads that from the playing itself, and a panic lets it go. The hourglass lights while time is held,
/// however it was asked for (`holdShown`).
extension AppModel {
    /// Latches the hold, or lets a latched hold go (the hourglass's double-click and ⌘⇧H).
    public func toggleHold() {
        holdLatched.toggle()
        sceneControls.holdRequested = holdLatched || holdPressed
    }

    /// The hourglass pressed (true) or let go.
    public func setHoldPressed(_ down: Bool) {
        guard holdPressed != down else { return }
        holdPressed = down
        sceneControls.holdRequested = holdLatched || holdPressed
    }
}
