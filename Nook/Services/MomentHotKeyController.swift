import AppKit
import Carbon.HIToolbox

/// A system-wide meeting hotkey (flag this moment, take a note), active only
/// while recording.
///
/// Carbon's `RegisterEventHotKey` for the same reasons dictation uses it: the
/// keystroke is consumed globally, works in any app, and needs no
/// Accessibility permission. The combination comes from `ShortcutStore`, so a
/// rebind in Settings takes effect here without restarting anything.
@MainActor
final class MomentHotKeyController {
    var onPress: (() -> Void)?
    /// Which of Nook's hotkeys this is. Every handler on the application
    /// target sees every hotkey press, so each one answers only its own.
    nonisolated let identifier: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x6E6B666C // 'nkfl'
    private var shortcut: RecordedShortcut
    /// Activity is meeting lifecycle state, not registration success. Carbon
    /// can refuse one combination; a later valid rebind must still retry.
    private var isActive = false

    init(shortcut: RecordedShortcut, identifier: UInt32 = 1) {
        self.shortcut = shortcut
        self.identifier = identifier
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
            id: identifier
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
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else {
                return OSStatus(eventNotHandledErr)
            }
            let controller = Unmanaged<MomentHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            // Every handler installed on the application target sees every
            // hotkey. Before a second one existed this answered all of them;
            // a note shortcut would also have flagged a moment.
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressed
            )
            guard
                status == noErr,
                pressed.signature == 0x6E6B666C,
                pressed.id == controller.identifier
            else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                controller.onPress?()
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
