import AppKit
import Carbon.HIToolbox

/// The system-wide "flag this moment" hotkey, active only while recording.
///
/// Carbon's `RegisterEventHotKey` for the same reasons dictation uses it: the
/// keystroke is consumed globally, works in any app, and needs no
/// Accessibility permission. The default is Option-Command-F, which does not
/// collide with dictation's hold-to-talk modifiers.
@MainActor
final class MomentHotKeyController {
    var onFlag: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x6E6B666C // 'nkfl'

    private static let keyCode: UInt32 = UInt32(kVK_ANSI_F)
    private static let modifiers: UInt32 = UInt32(cmdKey | optionKey)

    func start() {
        guard hotKeyRef == nil else { return }
        installHandlerIfNeeded()

        let eventID = EventHotKeyID(
            signature: Self.signature,
            id: 1
        )
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
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

    func stop() {
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
