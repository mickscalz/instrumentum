import SwiftUI

/// The Play menu (Small Wins spec §2, §4): Keep That (⌘K), Keep the Last 10 Minutes, Record (⌘R), Show Recordings in
/// Finder, and Hold the Moment (⌘⇧H).
struct PlayMenu: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Play") {
            KeepMenuItems(model: model)
            Divider()
            RecordMenuItems(model: model)
            Divider()
            HoldMenuItems(model: model)
        }
    }
}
