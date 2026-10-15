import AppKit

/// Decides whether Nook belongs in the Dock and the ⌘-Tab switcher.
///
/// Nook is a menu bar app that becomes an ordinary app while one of its
/// windows is open. That used to be decided from a list of window roles kept
/// by hand: a role was added when its window appeared and removed when it
/// closed, and the app returned to the menu bar when the list emptied. The
/// list could disagree with the screen. Settings was never on it, so closing
/// the library behind an open Settings window dropped Nook from ⌘-Tab while
/// Settings was still showing, and any close the list missed left Nook in
/// ⌘-Tab with nothing open. The decision is now made from the windows that
/// actually exist, every time one opens or closes.
enum DockPresence {
    /// What the rule needs to know about one window.
    struct Window: Equatable {
        var isVisible: Bool
        var isMiniaturized: Bool
        var isTitled: Bool
        /// The notch, the dictation indicator and the quick-note pad are
        /// panels. They float over other apps and never warrant a Dock icon.
        var isPanel: Bool
        /// A sheet belongs to the window it is attached to.
        var isSheet: Bool
    }

    /// True while any ordinary window is open, including a minimized one,
    /// which the Dock is the only way back to.
    static func wantsDock(_ windows: [Window]) -> Bool {
        windows.contains { window in
            window.isTitled && !window.isPanel && !window.isSheet
                && (window.isVisible || window.isMiniaturized)
        }
    }
}

extension DockPresence.Window {
    @MainActor
    init(_ window: NSWindow) {
        self.init(
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel,
            isSheet: window.sheetParent != nil
        )
    }
}

/// Keeps the activation policy in step with Nook's windows.
@MainActor
final class DockPresenceController {
    private var observers: [NSObjectProtocol] = []

    /// Watches every window Nook shows, including ones it did not create
    /// itself, such as the Settings window SwiftUI owns.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // `queue: .main` delivers on the main thread, so the window
                // is only ever touched there; the compiler cannot see that
                // through `Notification`, which is not Sendable.
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let window = object as? NSWindow, !(window is NSPanel) else { return }
                    self?.reconcile()
                }
            })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow, !(window is NSPanel) else { return }
                // The closing window still reports itself visible here.
                self?.reconcile(closing: window)
            }
        })
        // A window macOS restored at launch may already be open, and becomes
        // key before these observers exist.
        reconcile()
    }

    func reconcile(closing: NSWindow? = nil) {
        let windows = NSApp.windows.filter { $0 !== closing }.map(DockPresence.Window.init)
        let wantsDock = DockPresence.wantsDock(windows)
        switch (wantsDock, NSApp.activationPolicy()) {
        case (true, .accessory), (true, .prohibited):
            NSApp.setActivationPolicy(.regular)
        case (false, .regular):
            NSApp.setActivationPolicy(.accessory)
        default:
            break
        }
    }
}
