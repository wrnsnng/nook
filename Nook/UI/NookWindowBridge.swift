import AppKit
import SwiftUI

extension Notification.Name {
    static let nookCloseLiveNotesWindow = Notification.Name(
        "com.localfirst.nook.close-live-notes-window"
    )
}

struct NookWindowBridge: NSViewRepresentable {
    let role: NookWindowRole
    var floats = false

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.role = role
        view.floats = floats
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.role = role
        view.floats = floats
        view.configureWindowIfNeeded()
    }
}

final class WindowTrackingView: NSView {
    var role: NookWindowRole?
    var floats = false
    private weak var trackedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window, window !== trackedWindow, let role else { return }
        if let trackedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: trackedWindow
            )
        }
        trackedWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("nook.\(role.rawValue)")
        window.tabbingMode = .disallowed

        if floats {
            window.level = .floating
            window.collectionBehavior.formUnion([
                .canJoinAllSpaces,
                .fullScreenAuxiliary
            ])
        }

        Task { @MainActor in
            AppModel.shared.windowDidOpen(role, window: window)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window,
        )
        if role == .liveNotes {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(closeLiveNotesWindow(_:)),
                name: .nookCloseLiveNotesWindow,
                object: nil
            )
        }
    }

    @objc private func closeLiveNotesWindow(_ notification: Notification) {
        guard role == .liveNotes, let trackedWindow else { return }
        trackedWindow.orderOut(nil)
        trackedWindow.performClose(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let role else { return }
        Task { @MainActor in
            AppModel.shared.windowDidClose(role)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
