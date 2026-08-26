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

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?
    @State private var heldModifiers: NSEvent.ModifierFlags = []

    /// Keep the control column stable while the button changes from a short
    /// shortcut glyph to its recording prompt, and while a validation message
    /// appears below it.
    private static let controlWidth: CGFloat = 148

    var body: some View {
        VStack(alignment: .trailing, spacing: NookSpacing.xSmall) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Press or hold keys…" : shortcut.displayString)
                    .font(NookType.control.monospaced())
                    .foregroundStyle(isRecording ? .secondary : .primary)
                    .frame(width: Self.controlWidth)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .help(
                isRecording
                    ? recordingHelp
                    : "Click to record a new shortcut."
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(
                isRecording ? "Recording a new shortcut" : shortcut.displayString
            )
            .accessibilityHint(
                isRecording ? recordingHelp : "Click to record a new shortcut."
            )

            if let rejection {
                Text(rejection)
                    .font(NookType.micro)
                    .foregroundStyle(NookPalette.warning)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.controlWidth, alignment: .trailing)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        rejection = nil
        heldModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            guard event.type == .keyDown else {
                handleFlags(event)
                return event
            }
            handle(event)
            // Swallow the keystroke so recording ⌘W does not close the window.
            return nil
        }
    }

    /// Modifiers pressed and then released with no key in between are a
    /// shortcut in their own right — "hold ⌃⌥ and speak". They only ever arrive
    /// as flag changes, which is why recording used to ignore them entirely.
    private func handleFlags(_ event: NSEvent) {
        let active = event.modifierFlags.intersection(
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
        stopRecording()
        rejection = nil
        onChange(recorded)
    }

    private var recordingHelp: String {
        if allowsModifierOnly {
            return "Press a combination, or hold modifiers alone and release them. Escape cancels."
        }
        return "Press a key with one or more modifiers. Escape cancels."
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        guard let recorded = DictationShortcut(event: event) else {
            rejection = "Add a modifier, such as ⌃ or ⌥."
            return
        }
        stopRecording()
        rejection = nil
        onChange(recorded)
    }
}
