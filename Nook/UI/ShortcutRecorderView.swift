import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Lets the user record a shortcut by pressing it.
///
/// While recording, a *local* event monitor takes key presses out of Nook's own
/// Settings window. A local monitor needs no permission and cannot see anything
/// typed in other apps, which is the right trade for a preferences control.
struct ShortcutRecorderView: View {
    let shortcut: DictationShortcut
    let onChange: (DictationShortcut) -> Void
    /// Dictation can watch modifiers by themselves. Nook's action shortcuts
    /// are menu or Carbon bindings and always need an actual key.
    var allowsModifierOnly = true
    /// Names the control for assistive tech, since "the dictation shortcut"
    /// would be wrong on every other row of the shortcuts pane.
    var accessibilityLabel = "Keyboard shortcut"

    @StateObject private var recorder = ShortcutRecorderSession()

    /// Keep the control column stable while the button changes from a short
    /// shortcut glyph to its recording prompt, and while a validation message
    /// appears below it.
    private static let controlWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .trailing, spacing: NookSpacing.xSmall) {
            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    recorder.startRecording(
                        allowsModifierOnly: allowsModifierOnly, onChange: onChange
                    )
                }
            } label: {
                Text(recorder.isRecording ? "Press or hold keys…" : shortcut.displayString)
                    .font(NookType.control.monospaced())
                    .foregroundStyle(recorder.isRecording ? .secondary : .primary)
                    .frame(width: Self.controlWidth)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .help(
                recorder.isRecording
                    ? recordingHelp
                    : "Click to record a new shortcut."
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(
                recorder.isRecording ? "Recording a new shortcut" : shortcut.displayString
            )
            .accessibilityHint(
                recorder.isRecording ? recordingHelp : "Click to record a new shortcut."
            )

            if let rejection = recorder.rejection {
                Text(rejection)
                    .font(NookType.micro)
                    .foregroundStyle(NookPalette.warning)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.controlWidth, alignment: .trailing)
        .background {
            ShortcutRecorderWindowAnchor(recorder: recorder)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onDisappear(perform: recorder.stopRecording)
    }

    private var recordingHelp: String {
        if allowsModifierOnly {
            return "Press a combination, or hold modifiers alone and release them. Escape cancels."
        }
        return "Press a key with one or more modifiers. Escape cancels."
    }
}

/// A local monitor sees every Nook window. The hosting view supplies the only
/// window allowed to consume keys, and losing that window ends the recording.
@MainActor
final class ShortcutRecorderSession: NSObject, ObservableObject {
    // Several shortcut controls share Settings. Weak keys and values neither
    // retain a closed window nor keep an abandoned control alive.
    private static let activeRecorders = NSMapTable<NSWindow, ShortcutRecorderSession>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )
    @Published private(set) var isRecording = false
    @Published private(set) var rejection: String?
    private weak var owningWindow: NSWindow?
    private var monitor: ShortcutRecorderMonitor?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var allowsModifierOnly = true
    private var onChange: ((DictationShortcut) -> Void)?

    func attach(to window: NSWindow?) {
        guard window !== owningWindow else { return }
        stopRecording()
        owningWindow = window
    }

    func startRecording(
        allowsModifierOnly: Bool,
        onChange: @escaping (DictationShortcut) -> Void
    ) {
        guard !isRecording, let owningWindow, owningWindow.isKeyWindow else { return }
        Self.activeRecorders.object(forKey: owningWindow)?.stopRecording()
        Self.activeRecorders.setObject(self, forKey: owningWindow)
        self.allowsModifierOnly = allowsModifierOnly
        self.onChange = onChange
        isRecording = true
        rejection = nil
        heldModifiers = []

        // AppKit invokes local monitors synchronously from sendEvent on the
        // main thread. State changes must finish before dispatch, not in a
        // queued Task that could consume a later window's input.
        let handler: @Sendable (NSEvent) -> NSEvent? = { [weak self] event in
            let snapshot = ShortcutRecorderEvent(event: event)
            let consume = MainActor.assumeIsolated {
                self?.consume(snapshot) ?? false
            }
            return consume ? nil : event
        }
        guard let token = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged], handler: handler
        ) else {
            stopRecording()
            return
        }
        monitor = ShortcutRecorderMonitor(token: token)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameUnavailable(_:)),
                name: name, object: owningWindow
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDeactivated(_:)),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    /// True means this exact window's key-down was handled. A missing or
    /// unrelated event window is never inferred from the application's key one.
    func consume(_ event: ShortcutRecorderEvent) -> Bool {
        guard isRecording else { return false }
        guard let owningWindow, owningWindow.isKeyWindow else {
            stopRecording()
            return false
        }
        guard event.windowIdentity == ObjectIdentifier(owningWindow) else { return false }
        switch event.kind {
        case .flagsChanged:
            handleFlags(event)
            return false
        case .keyDown:
            handleKey(event)
            // Recording Command-W must not also close its Settings window.
            return true
        default:
            return false
        }
    }

    func stopRecording() {
        if let owningWindow,
           Self.activeRecorders.object(forKey: owningWindow) === self {
            Self.activeRecorders.removeObject(forKey: owningWindow)
        }
        if isRecording { isRecording = false }
        if rejection != nil { rejection = nil }
        if let monitor { NSEvent.removeMonitor(monitor.token) }
        monitor = nil
        heldModifiers = []
        onChange = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowBecameUnavailable(_ notification: Notification) {
        guard (notification.object as? NSWindow) === owningWindow else { return }
        stopRecording()
    }

    @objc private func applicationDeactivated(_ notification: Notification) {
        stopRecording()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor.token) }
        NotificationCenter.default.removeObserver(self)
    }

    /// Modifiers pressed and then released with no key in between are a
    /// shortcut in their own right — "hold ⌃⌥ and speak". They only ever arrive
    /// as flag changes, which is why recording used to ignore them entirely.
    private func handleFlags(_ event: ShortcutRecorderEvent) {
        let active = NSEvent.ModifierFlags(rawValue: event.modifierFlags).intersection(
            DictationShortcut.supportedModifiers
        )
        guard active.isEmpty else {
            // Track the high-water mark so releasing one key at a time still
            // records the full combination.
            heldModifiers.formUnion(active)
            return
        }
        defer { heldModifiers = [] }
        guard let recorded = DictationShortcut(modifiers: heldModifiers) else {
            return
        }
        guard allowsModifierOnly else {
            rejection = "Add a key to those modifiers."
            return
        }
        finish(recorded)
    }

    private func handleKey(_ event: ShortcutRecorderEvent) {
        if event.isEscape {
            stopRecording()
            return
        }
        guard let recorded = event.shortcut else {
            rejection = "Add a modifier, such as ⌃ or ⌥."
            return
        }
        finish(recorded)
    }

    private func finish(_ recorded: DictationShortcut) {
        let completion = onChange
        stopRecording()
        rejection = nil
        completion?(recorded)
    }
}

/// NSEvent stays in the monitor callback. Only these immutable values cross
/// into the main actor; object identity avoids treating a reused window number
/// as the original Settings window. Unowned events always pass through.
struct ShortcutRecorderEvent: Sendable {
    enum Kind: Sendable {
        case keyDown
        case flagsChanged
        case other
    }

    let windowIdentity: ObjectIdentifier?
    let kind: Kind
    let modifierFlags: UInt
    let isEscape: Bool
    let shortcut: DictationShortcut?

    init(event: NSEvent) {
        windowIdentity = event.windowNumber > 0
            ? event.window.map(ObjectIdentifier.init) : nil
        modifierFlags = event.modifierFlags.rawValue
        switch event.type {
        case .keyDown:
            kind = .keyDown
            isEscape = Int(event.keyCode) == kVK_Escape
            shortcut = DictationShortcut(event: event)
        case .flagsChanged:
            kind = .flagsChanged
            isEscape = false
            shortcut = nil
        default:
            kind = .other
            isEscape = false
            shortcut = nil
        }
    }
}

/// Immutable opaque registration handle. It is never used to deliver events;
/// Sendable permits synchronous cleanup from the owner's nonisolated deinit.
private struct ShortcutRecorderMonitor: @unchecked Sendable {
    let token: Any
}

struct ShortcutRecorderWindowAnchor: NSViewRepresentable {
    let recorder: ShortcutRecorderSession

    func makeNSView(context: Context) -> ShortcutRecorderWindowTrackingView {
        let view = ShortcutRecorderWindowTrackingView()
        view.recorder = recorder
        return view
    }

    func updateNSView(_ view: ShortcutRecorderWindowTrackingView, context: Context) {
        view.recorder = recorder
        recorder.attach(to: view.window)
    }

    static func dismantleNSView(_ view: ShortcutRecorderWindowTrackingView, coordinator: ()) {
        view.recorder?.attach(to: nil)
        view.recorder = nil
    }
}

final class ShortcutRecorderWindowTrackingView: NSView {
    weak var recorder: ShortcutRecorderSession?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recorder?.attach(to: window)
    }
}
