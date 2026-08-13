import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts dictated text into whatever text field currently has focus.
///
/// Two mechanisms, because no single one works everywhere:
///
/// - The Accessibility API writes straight into the focused element. It is
///   precise, leaves the pasteboard alone, and is the only way to stream text
///   in while the user is still speaking. Native Cocoa apps support it well.
/// - Synthesising ⌘V works in anything that accepts a paste, including the
///   Chromium and Electron apps that advertise `AXSelectedText` and then ignore
///   writes to it. It costs the pasteboard temporarily and can only be done
///   once per dictation.
///
/// Which one is available is decided at the start of each run, so the caller
/// knows up front whether it can stream.
@MainActor
final class TextInsertionService {
    enum Capability: Equatable {
        /// Text can be appended repeatedly, live.
        case streaming
        /// One insertion at the end, via the pasteboard.
        case pasteOnly
        /// Focus is somewhere that cannot take text — a list, a button, the
        /// desktop. Pasting here would fire ⌘V at whatever happens to be in
        /// front, so the words go to a note instead.
        case noTextField
        /// Nook has not been granted Accessibility access.
        case unavailable
    }

    /// Whether macOS has granted Nook Accessibility access.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the Accessibility prompt. Returns the status as it
    /// stands now — granting is asynchronous and needs a later re-check.
    @discardableResult
    static func requestTrust() -> Bool {
        // Spelled out rather than read from `kAXTrustedCheckOptionPrompt`,
        // which Swift 6 rejects as shared mutable state because the framework
        // exposes it as a `var`. The key name is API and does not change.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var element: AXUIElement?
    private var insertedText = ""
    private var verifiedDirectWriting = false

    #if DEBUG
    /// What the focused element reported, so a run that goes the wrong way can
    /// be explained from the log instead of guessed at.
    private(set) var lastInspection = "none"
    #endif

    /// Characters written so far this run, in the units AX ranges use.
    private var insertedLength: Int { insertedText.utf16.count }

    // MARK: - Run lifecycle

    func beginRun() -> Capability {
        element = nil
        insertedText = ""
        verifiedDirectWriting = false

        guard Self.isTrusted else { return .unavailable }
        guard let focused = focusedElement() else {
            #if DEBUG
            lastInspection = "no focused element"
            #endif
            return .noTextField
        }
        #if DEBUG
        lastInspection = describe(focused)
        #endif

        if supportsDirectWriting(focused) {
            element = focused
            return .streaming
        }
        // Not directly writable. Pasting is worth trying only where the focus
        // could plausibly accept text — otherwise ⌘V lands somewhere arbitrary
        // and may trigger whatever that app binds paste to.
        guard acceptsText(focused) else { return .noTextField }
        element = focused
        return .pasteOnly
    }

    /// Appends finalized text at the caret. Streaming runs only.
    @discardableResult
    func append(_ text: String) -> Bool {
        guard !text.isEmpty, let element else { return false }

        let before = selectedRange(of: element)
        guard setValue(text as CFString, for: kAXSelectedTextAttribute, on: element) else {
            return false
        }

        // `IsAttributeSettable` is a claim, not a promise. Several toolkits —
        // Electron among them — advertise the attribute, accept the write,
        // return success, and drop it. Without checking, streaming would report
        // that it typed a sentence that never appeared anywhere, and the paste
        // fallback would never be reached.
        //
        // Verified once: if the caret moved, this element really does accept
        // writes. An unreadable range is treated as success, because assuming
        // failure there would paste text that had in fact been inserted.
        if !verifiedDirectWriting {
            if let before, let after = selectedRange(of: element) {
                guard after.location > before.location else { return false }
            }
            verifiedDirectWriting = true
        }

        insertedText += text
        return true
    }

    /// Swaps everything written this run for `text`.
    ///
    /// Used when a rewrite lands after the verbatim words are already on
    /// screen. Refuses if the document no longer reads the way Nook left it —
    /// the user may have typed, clicked elsewhere, or hit undo — because a
    /// misaligned replacement would eat their own writing.
    @discardableResult
    func replaceRun(with text: String) -> Bool {
        guard !insertedText.isEmpty, let element else { return false }

        // A rewrite can take seconds, and the user is free to click into
        // something else meanwhile. Confirming focus has not moved is a
        // positional check; the content check below is a corroborating one.
        // Neither is sufficient alone.
        guard let focused = focusedElement(), CFEqual(focused, element) else {
            return false
        }
        guard let caret = selectedRange(of: element) else { return false }
        let start = caret.location + caret.length - insertedLength
        guard start >= 0 else { return false }

        let runRange = CFRange(location: start, length: insertedLength)
        let previousSelection = caret
        guard setRange(runRange, on: element) else { return false }

        // Read back what is actually selected before overwriting it.
        guard selectedText(of: element) == insertedText else {
            setRange(previousSelection, on: element)
            return false
        }
        guard setValue(text as CFString, for: kAXSelectedTextAttribute, on: element) else {
            setRange(previousSelection, on: element)
            return false
        }
        insertedText = text
        return true
    }

    /// Inserts `text` in one shot through the pasteboard.
    ///
    /// The previous pasteboard contents are restored afterwards. The delay is
    /// unavoidable: the paste is delivered asynchronously to another process,
    /// and restoring too early gives that process Nook's old clipboard.
    @discardableResult
    func pasteOnce(_ text: String) async -> Bool {
        guard !text.isEmpty, Self.isTrusted else { return false }

        // The shortcut that triggered this is very likely still held down —
        // hold-to-talk ends on key-up, and the modifiers usually outlast it.
        // A ⌘V posted while ⌃⌥ is physically down arrives as ⌃⌥⌘V, which is
        // not paste in any app. This is invisible on the Accessibility path,
        // which is why direct-write apps worked and paste-only ones did not.
        await waitForModifiersToClear()

        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)
        let ours = pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard postCommandV() else {
            restore(saved, to: pasteboard, ifUnchangedFrom: ours)
            return false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.pasteSettlingMilliseconds))
            self.restore(saved, to: pasteboard, ifUnchangedFrom: ours)
        }
        insertedText = text
        return true
    }

    /// How long the dictated text is left on the pasteboard before the previous
    /// contents go back.
    ///
    /// The paste is delivered to another process asynchronously and there is no
    /// completion to wait on, so this is a judgement rather than a guarantee.
    /// Restoring too early is the worse failure — a slow app would then paste
    /// the user's old clipboard instead of what they just said — so this errs
    /// long. The window is bounded by the change-count check in `restore`.
    private static let pasteSettlingMilliseconds = 500

    func endRun() {
        element = nil
        insertedText = ""
        verifiedDirectWriting = false
    }

    // MARK: - Accessibility

    private func focusedElement() -> AXUIElement? {
        if let element = focusedElement(of: AXUIElementCreateSystemWide()) {
            return element
        }
        // Chromium and WebKit do not build an accessibility tree until a client
        // asks for one, so a web view reports no focused element at all. That
        // covers Electron apps and every text field on a web page, which is
        // most of the places someone wants to dictate. `AXManualAccessibility`
        // is the request to build it; native apps neither need nor notice it.
        return focusedElementAfterEnablingWebAccessibility()
    }

    private func focusedElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success, let value else { return nil }
        // `CFGetTypeID` keeps a non-element attribute value from being force
        // cast into one.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func focusedElementAfterEnablingWebAccessibility() -> AXUIElement? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontmost.processIdentifier
        let application = AXUIElementCreateApplication(pid)

        if !activatedApplications.contains(pid) {
            requestAccessibilityTree(from: application, pid: pid)
            activatedApplications.insert(pid)
        }

        // Asked for, but very likely not built yet. Nothing is waited on here:
        // the words have not been spoken at this point, and the decision about
        // where they go is taken again once they have been, which gives the
        // tree the length of a sentence to appear rather than a few
        // milliseconds of a blocked main thread.
        return focusedElement(of: AXUIElementCreateSystemWide())
            ?? focusedElement(of: application)
    }

    /// Asks an application to build the accessibility tree it has not built.
    ///
    /// Web content is not described until something asks. Two mechanisms exist
    /// and neither covers everything:
    ///
    /// - `AXManualAccessibility` is Electron's own, added precisely so an app
    ///   could opt in without the side effects of the one below. Chromium and
    ///   WebKit do not implement it, and some Electron versions advertise it so
    ///   poorly that setting it fails outright, which is why the result is
    ///   checked rather than assumed.
    /// - `AXEnhancedUserInterface` is the long-standing signal that an
    ///   assistive client is present, and it is what Chromium documents as the
    ///   trigger for building its tree. It is also reported to interfere with
    ///   window management in the app it is set on, so it is used only when the
    ///   first mechanism is unavailable, rather than on everything.
    private func requestAccessibilityTree(
        from application: AXUIElement,
        pid: pid_t
    ) {
        let manual = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        guard manual != .success else {
            #if DEBUG
            DictationDebugLog.write(
                "[dictation] AXManualAccessibility accepted by pid \(pid)"
            )
            #endif
            return
        }

        let enhanced = AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        #if DEBUG
        DictationDebugLog.write(
            "[dictation] pid \(pid): AXManualAccessibility \(manual.rawValue), "
                + "AXEnhancedUserInterface \(enhanced.rawValue)"
        )
        #endif
    }

    /// Applications already asked this launch. The request is per process and
    /// does not need repeating, and `AXEnhancedUserInterface` in particular is
    /// worth setting as few times as possible.
    ///
    /// Forgotten when a process exits, because macOS reuses process
    /// identifiers: a remembered one would otherwise make a completely
    /// different application look as though it had already been asked, and it
    /// would never build its tree.
    private var activatedApplications: Set<pid_t> = [] {
        didSet { observeTerminationIfNeeded() }
    }

    private var terminationObserver: (any NSObjectProtocol)?

    private func observeTerminationIfNeeded() {
        guard terminationObserver == nil else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                MainActor.assumeIsolated {
                    self?.activatedApplications.remove(app.processIdentifier)
                }
            }
    }

    /// Whether the element will actually accept a write to its selected text.
    ///
    /// Asking rather than trying matters: several toolkits report the attribute
    /// as present, accept the write, and silently discard it. `IsAttributeSettable`
    /// is the only signal available before text has been committed anywhere.
    private func supportsDirectWriting(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard status == .success, settable.boolValue else { return false }
        // A settable selection is meaningless without a readable range, which
        // is what the end-of-run replacement depends on.
        return selectedRange(of: element) != nil
    }

    #if DEBUG
    /// Everything the routing decision is based on, in one line.
    private func describe(_ element: AXUIElement) -> String {
        func string(_ attribute: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success else {
                return "unreadable"
            }
            guard let value else { return "nil" }
            if let text = value as? String {
                return attribute == kAXRoleAttribute
                    ? text
                    : "String(\(text.count) chars)"
            }
            return String(describing: CFCopyTypeIDDescription(CFGetTypeID(value)))
        }

        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        var valueSettable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &valueSettable
        )

        return "role=\(string(kAXRoleAttribute)) "
            + "value=\(string(kAXValueAttribute)) "
            + "selectedTextSettable=\(settable.boolValue) "
            + "valueSettable=\(valueSettable.boolValue)"
    }
    #endif

    /// Whether the focused element looks like somewhere text can go.
    ///
    /// Role is the only signal available before committing an insertion. It is
    /// generous on purpose: the cost of guessing wrong here is a note the user
    /// did not want, while guessing wrong the other way sends a ⌘V into an app
    /// that may have bound it to something else entirely.
    private func acceptsText(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success, let role = value as? String else {
            return false
        }
        if Self.textRoles.contains(role) { return true }

        // Chromium and Electron present editable areas as generic web roles,
        // so an editable marker is used as a second signal. Settability alone
        // is not enough: checkboxes, sliders, and steppers all expose a
        // settable value too, and synthesising ⌘V into one would trigger
        // whatever that app binds paste to. The value has to actually be text.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValue
        ) == .success else {
            return false
        }

        // Judged by what the value is *not*. The controls this guards against
        // report numbers: a checkbox, a slider, a stepper. Requiring a String
        // instead would reject an empty field, which some implementations
        // report as no value at all, and an empty field is the ordinary
        // starting point for dictation. Rejecting it would send someone
        // talking into a blank message box to a note instead.
        if currentValue == nil { return true }
        return currentValue is String
    }

    /// Roles that are a place to type, rather than a place that contains them.
    ///
    /// `AXWebArea` is deliberately absent. A focused web area means the page
    /// has focus, not that a field does, so treating it as editable sent
    /// dictation into any web page the user happened to be reading and stopped
    /// a note from ever opening there. Chromium and WebKit describe genuine
    /// fields with the roles below once their tree exists, and anything else
    /// editable is caught by the settable-value test.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole
    ]

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard status == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    @discardableResult
    private func setRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return false }
        return setValue(value, for: kAXSelectedTextRangeAttribute, on: element)
    }

    private func setValue(
        _ value: CFTypeRef,
        for attribute: String,
        on element: AXUIElement
    ) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value
        ) == .success
    }

    // MARK: - Pasteboard

    /// Waits for the user to actually let go of the shortcut.
    ///
    /// Bounded rather than indefinite: in toggle mode the user may legitimately
    /// be resting on a modifier, and a paste that never arrives is worse than
    /// one that arrives with a stray flag.
    private func waitForModifiersToClear() async {
        let interesting: CGEventFlags = [
            .maskCommand, .maskAlternate, .maskControl, .maskShift
        ]
        for _ in 0..<Self.modifierWaitAttempts {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interesting).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 20 ms apart, so roughly half a second in total.
    private static let modifierWaitAttempts = 25

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
              )
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// A snapshot of the pasteboard, plus whether it was actually empty.
    ///
    /// The distinction matters. A read can fail — promised and lazily-provided
    /// items, or Universal Clipboard content still in flight — and an empty
    /// result would then be indistinguishable from a genuinely empty clipboard.
    /// Treating the two the same is how a restore permanently discards whatever
    /// the user really had.
    private struct PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]]
        var wasEmpty: Bool
    }

    private func snapshotPasteboard(
        _ pasteboard: NSPasteboard
    ) -> PasteboardSnapshot {
        let existing = pasteboard.pasteboardItems
        let captured = (existing ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
        .filter { !$0.isEmpty }

        return PasteboardSnapshot(
            items: captured,
            wasEmpty: existing?.isEmpty ?? false
        )
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        ifUnchangedFrom changeCount: Int
    ) {
        // Somebody copied something after Nook did. Their clipboard wins; the
        // alternative is silently replacing what they just put there.
        guard pasteboard.changeCount == changeCount else { return }

        guard !snapshot.items.isEmpty else {
            // Nothing safe to write back. If the clipboard really was empty,
            // clear the dictated text; if the read merely failed, leaving the
            // dictated text is recoverable and wiping it is not.
            if snapshot.wasEmpty {
                pasteboard.clearContents()
            }
            return
        }

        pasteboard.clearContents()
        pasteboard.writeObjects(
            snapshot.items.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: type)
                }
                return item
            }
        )
    }
}
