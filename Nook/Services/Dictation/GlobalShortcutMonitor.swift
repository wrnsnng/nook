import AppKit
import Carbon.HIToolbox

/// Listens for one system-wide keyboard shortcut.
///
/// This uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global
/// monitor or a `CGEventTap` for two reasons. It reports key release as well as
/// key press, which is what "hold to talk" needs, and it requires no
/// Accessibility permission — so the shortcut works the moment dictation is
/// switched on, before the user has granted anything. It also consumes the
/// keystroke, so the shortcut never leaks into the app underneath.
///
/// The API is old but it is the only one on macOS that offers this combination,
/// and it remains the mechanism behind most shortcut UIs on the platform.
@MainActor
final class GlobalShortcutMonitor {
    enum RegistrationError: LocalizedError {
        case shortcutInvalid
        case shortcutUnavailable
        case accessibilityRequired

        var errorDescription: String? {
            switch self {
            case .shortcutInvalid:
                "Add at least one modifier key, such as Control or Option."
            case .shortcutUnavailable:
                "Another app is already using that shortcut. Try a different one."
            case .accessibilityRequired:
                "A modifier-only shortcut needs Accessibility access. Allow it below, then set the shortcut again."
            }
        }
    }

    /// How long modifiers must be held before dictation engages.
    ///
    /// Modifier combinations are also the opening of ordinary shortcuts, and
    /// they get pressed in passing constantly. Waiting distinguishes "held to
    /// speak" from "on the way to ⌃⌥C", and costs nothing: the user is about to
    /// start talking anyway.
    private static let modifierHoldDelay = Duration.milliseconds(250)

    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?

    private(set) var shortcut: DictationShortcut?

    private var registration: HotKeyRegistration?
    private var flagMonitors: [Any] = []
    private var engageTask: Task<Void, Never>?
    private var isEngaged = false
    private let identifier: UInt32

    init() {
        identifier = GlobalShortcutRegistry.nextIdentifier()
    }

    func register(_ shortcut: DictationShortcut) throws {
        guard shortcut.isValid else { throw RegistrationError.shortcutInvalid }
        unregister()

        if shortcut.isModifierOnly {
            try registerModifiersOnly(shortcut)
            return
        }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            globalShortcutEventHandler,
            eventTypes.count,
            &eventTypes,
            nil,
            &handlerRef
        )
        guard handlerStatus == noErr, let handlerRef else {
            throw RegistrationError.shortcutUnavailable
        }

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            RemoveEventHandler(handlerRef)
            throw RegistrationError.shortcutUnavailable
        }

        registration = HotKeyRegistration(
            hotKey: hotKeyRef,
            handler: handlerRef
        )
        self.shortcut = shortcut
        GlobalShortcutRegistry.store(self, for: identifier)
    }

    func unregister() {
        // Releasing the registration is what tears down the Carbon handles.
        registration = nil
        GlobalShortcutRegistry.remove(identifier)
        for monitor in flagMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagMonitors = []
        engageTask?.cancel()
        engageTask = nil
        isEngaged = false
        shortcut = nil
    }

    // MARK: - Modifier-only shortcuts

    private func registerModifiersOnly(_ shortcut: DictationShortcut) throws {
        // A global monitor for modifier and key events is exactly the
        // capability macOS gates behind Accessibility, so it silently receives
        // nothing until that is granted.
        guard AXIsProcessTrusted() else {
            throw RegistrationError.accessibilityRequired
        }

        let handle: @MainActor (NSEvent) -> Void = { [weak self] event in
            self?.receive(event, for: shortcut)
        }
        // Global monitors do not see events while Nook itself is frontmost, so
        // a local one covers Settings and the library window.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { event in
                MainActor.assumeIsolated { handle(event) }
            }
        ) {
            flagMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown],
            handler: { event in
                handle(event)
                return event
            }
        ) {
            flagMonitors.append(local)
        }

        guard !flagMonitors.isEmpty else {
            throw RegistrationError.shortcutUnavailable
        }
        self.shortcut = shortcut
    }

    private func receive(_ event: NSEvent, for shortcut: DictationShortcut) {
        if event.type == .keyDown {
            // The modifiers were the start of an ordinary shortcut after all.
            // Whatever this is, it belongs to the app in front, not to Nook.
            engageTask?.cancel()
            engageTask = nil
            if isEngaged {
                isEngaged = false
                onRelease?()
            }
            return
        }

        let active = event.modifierFlags.intersection(
            DictationShortcut.supportedModifiers
        )
        // Exact match, so ⌃⌥⌘ does not fire a ⌃⌥ shortcut.
        guard active == shortcut.flags else {
            engageTask?.cancel()
            engageTask = nil
            if isEngaged {
                isEngaged = false
                onRelease?()
            }
            return
        }

        guard !isEngaged, engageTask == nil else { return }
        engageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.modifierHoldDelay)
            guard !Task.isCancelled, let self, !self.isEngaged else { return }
            self.engageTask = nil
            self.isEngaged = true
            self.onPress?()
        }
    }

    fileprivate func handle(_ kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed: onPress?()
        case kEventHotKeyReleased: onRelease?()
        default: break
        }
    }

    /// `FourCharCode` for "nook".
    private static let signature: OSType = 0x6E6F6F6B
}

/// Owns the pair of Carbon handles for one registration.
///
/// Keeping them here rather than on the monitor gives them a `deinit` that is
/// not actor-isolated, which is the only place Swift 6 allows these non-Sendable
/// pointers to be released. Both handles are created and released solely by
/// this object.
private final class HotKeyRegistration: @unchecked Sendable {
    private let hotKey: EventHotKeyRef
    private let handler: EventHandlerRef

    init(hotKey: EventHotKeyRef, handler: EventHandlerRef) {
        self.hotKey = hotKey
        self.handler = handler
    }

    deinit {
        UnregisterEventHotKey(hotKey)
        RemoveEventHandler(handler)
    }
}

/// Carbon hands the event handler a C function pointer, which cannot capture
/// context, so live monitors are looked up by the identifier carried in the
/// event itself.
private enum GlobalShortcutRegistry {
    /// Deliberately weak. A strong entry would keep every monitor alive for the
    /// life of the process, and its registration along with it, so the Carbon
    /// hot key would never be released.
    private struct WeakMonitor {
        weak var value: GlobalShortcutMonitor?
    }

    // Carbon delivers hot key events on the main run loop, and every access
    // below happens either from that callback or from the main-actor monitor,
    // so this is single-threaded in practice.
    nonisolated(unsafe) private static var monitors: [UInt32: WeakMonitor] = [:]
    nonisolated(unsafe) private static var lastIdentifier: UInt32 = 0

    static func nextIdentifier() -> UInt32 {
        lastIdentifier += 1
        return lastIdentifier
    }

    static func store(_ monitor: GlobalShortcutMonitor, for id: UInt32) {
        monitors[id] = WeakMonitor(value: monitor)
    }

    static func remove(_ id: UInt32) {
        monitors.removeValue(forKey: id)
    }

    static func monitor(for id: UInt32) -> GlobalShortcutMonitor? {
        monitors[id]?.value
    }
}

private func globalShortcutEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let kind = GetEventKind(event)
    // Carbon dispatches this on the main run loop, so the main actor's
    // executor is already the current one.
    MainActor.assumeIsolated {
        GlobalShortcutRegistry.monitor(for: hotKeyID.id)?.handle(kind)
    }
    return noErr
}
