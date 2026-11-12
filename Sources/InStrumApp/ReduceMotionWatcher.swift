import AppKit

/// The Mac's Reduce Motion (System Settings › Accessibility › Display), as the app follows it (Small Wins spec §6).
@MainActor
public protocol ReduceMotionWatching: AnyObject {
    /// True while the Mac asks for less motion.
    var isOn: Bool { get }
    /// Called on the main thread whenever the Mac's display options change.
    var onChange: (() -> Void)? { get set }
}

/// The Mac's own flag: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, watched through
/// `accessibilityDisplayOptionsDidChangeNotification` on the workspace's notification centre.
@MainActor
public final class SystemReduceMotion: ReduceMotionWatching {
    public var onChange: (() -> Void)?
    private let center: NotificationCenter
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    public init() {
        center = NSWorkspace.shared.notificationCenter
        observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    public var isOn: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
