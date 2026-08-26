import AppKit
import Carbon.HIToolbox

/// The system-wide "flag this moment" hotkey, active only while recording.
///
/// Carbon's `RegisterEventHotKey` for the same reasons dictation uses it: the
/// keystroke is consumed globally, works in any app, and needs no
/// Accessibility permission. The combination comes from `ShortcutStore`, so a
/// rebind in Settings takes effect here without restarting anything.
@MainActor
final class MomentHotKeyController {
    var onFlag: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x6E6B666C // 'nkfl'
    private var shortcut: RecordedShortcut
    /// Activity is meeting lifecycle state, not registration success. Carbon
    /// can refuse one combination; a later valid rebind must still retry.
    private var isActive = false

    init(shortcut: RecordedShortcut) {
        self.shortcut = shortcut
    }

    /// Swaps the registered combination, keeping the registration alive when
    /// one already exists so mid-meeting rebinds work.
    func apply(_ newShortcut: RecordedShortcut) {
        guard newShortcut != shortcut else { return }
        unregister()
        shortcut = newShortcut
        if isActive { register() }
    }

    func start() {
        isActive = true
        register()
    }

    func stop() {
        isActive = false
        unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        guard shortcut.isValid, !shortcut.isModifierOnly else { return }
        installHandlerIfNeeded()

        let eventID = EventHotKeyID(
            signature: Self.signature,
            id: 1
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            eventID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            return
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// Installs the application-level handler once and keeps it for the
    /// process lifetime; registering and unregistering handlers per meeting
    /// risks ordering bugs for no benefit.
    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<MomentHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.onFlag?()
            }
            return noErr
        }
        let selfPointer = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }
}
