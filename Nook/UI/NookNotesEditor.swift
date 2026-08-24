import AppKit
import SwiftUI

/// A handle for editing an editor's text at the insertion point from outside
/// SwiftUI.
///
/// SwiftUI's `TextEditor` binding cannot see the cursor, so a toolbar button
/// that should type at it ("insert a checklist line") has nowhere to aim.
/// The representable wires this port to its text view once created; callers
/// keep the port and invoke commands through it.
@MainActor
final class TextViewInsertionPort {
    fileprivate weak var textView: NSTextView?

    /// Inserts text at the cursor, starting a fresh line first when the
    /// cursor sits mid-line so prefixes like `- [ ] ` always begin a line.
    func insertLineStarting(with prefix: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let nsText = textView.string as NSString
        let lineStart = nsText.lineRange(for: NSRange(location: range.location, length: 0)).location
        let atLineStart = range.location == lineStart
        let insertion = atLineStart ? prefix : "\n" + prefix
        textView.insertText(
            insertion,
            replacementRange: NSRange(location: range.location, length: 0)
        )
    }
}

/// A plain-text notes editor with explicit text-container geometry. SwiftUI's
/// TextEditor inherits private AppKit insets, which made independently padded
/// placeholders drift away from the insertion point across Nook's three notes
/// surfaces.
struct NookNotesEditor: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    /// Observed editing state, written by the text view's delegate as the
    /// user moves between fields. Never drives focus back into the view;
    /// see `focusToken`.
    var isFocused: Binding<Bool>?
    /// Bump to give the field the keyboard.
    ///
    /// Focus used to be a polled boolean here, read back through a
    /// `@FocusState` bridge on every SwiftUI update. That bridge propagates
    /// asynchronously, and during a meeting these views re-render at the
    /// audio meter's rate, so a stale read kept blurring a field the user
    /// was typing in: the moment Nook picked up audio, the notes went dead.
    /// A monotonic token is applied exactly once per change, so render
    /// pressure cannot undo a focus request, and nothing here ever removes
    /// focus from an editable field on its own.
    var focusToken = 0
    var contentInsets = EdgeInsets(
        top: 10,
        leading: 11,
        bottom: 10,
        trailing: 11
    )
    var fontSize = NSFont.systemFontSize
    var lineSpacing: CGFloat = 4
    var accessibilityLabel = "Personal meeting notes"
    var insertionPort: TextViewInsertionPort?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .padding(contentInsets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            PlainNotesTextView(
                text: $text,
                isFocused: isFocused,
                focusToken: focusToken,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                accessibilityLabel: accessibilityLabel,
                isEditable: isEnabled,
                insertionPort: insertionPort
            )
            .padding(contentInsets)
        }
    }
}

/// A text view that brings Nook forward when clicked.
///
/// The notch panel is a `.nonactivatingPanel`, so a click into the editor
/// embedded there leaves Nook in the background with the meeting application
/// still frontmost, and the window server keeps delivering every keystroke to
/// that application: the caret sat in the field while the typing went
/// somewhere else. Opening the floating-notes window already activated Nook
/// through the ordinary window path; an editor that lives in the panel needs
/// it at the mouse instead. For editors in ordinary windows this only
/// restates what the click already did.
private final class KeyActivatingTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PlainNotesTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var focusToken: Int
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let accessibilityLabel: String
    let isEditable: Bool
    var insertionPort: TextViewInsertionPort?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = KeyActivatingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        insertionPort?.textView = textView

        configure(textView)
        context.coordinator.appliedFontSize = fontSize
        context.coordinator.appliedLineSpacing = lineSpacing
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        // SwiftUI calls this on every update to the view, including ones
        // that have nothing to do with styling: a keystroke elsewhere in the
        // window, or (for the editors bound to `MeetingCoordinator`) an
        // audio-level or elapsed-time tick while a meeting records. Font size
        // and line spacing are fixed per call site, so re-applying them to
        // the whole text storage on every one of those updates was an
        // O(document length) rewrite for nothing; only redo it when one of
        // the two inputs that actually changes the styling has changed.
        if context.coordinator.appliedFontSize != fontSize
            || context.coordinator.appliedLineSpacing != lineSpacing {
            configure(textView)
            context.coordinator.appliedFontSize = fontSize
            context.coordinator.appliedLineSpacing = lineSpacing
        }
        textView.isEditable = isEditable
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let textLength = (text as NSString).length
            let location = min(selection.location, textLength)
            textView.setSelectedRange(
                NSRange(
                    location: location,
                    length: min(selection.length, textLength - location)
                )
            )
        }

        if !isEditable {
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            return
        }

        // A changed token is the only thing that focuses the field. There is
        // deliberately no blur path here: clicking elsewhere resigns the
        // text view through AppKit, and a render-time blur is what broke
        // typing during meetings.
        if focusToken != context.coordinator.appliedFocusToken {
            context.coordinator.appliedFocusToken = focusToken
            Task { @MainActor in
                guard textView.window != nil else { return }
                if textView.window?.firstResponder !== textView {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func configure(_ textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(
                [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ],
                range: NSRange(location: 0, length: storage.length)
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainNotesTextView
        weak var textView: NSTextView?
        /// The font size and line spacing last written into the text view,
        /// so `updateNSView` can tell a styling change from an unrelated one
        /// without re-applying attributes to find out. See `updateNSView`.
        var appliedFontSize: CGFloat?
        var appliedLineSpacing: CGFloat?
        /// The focus token already honoured, so each request fires once.
        var appliedFocusToken = 0

        init(parent: PlainNotesTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = false
        }
    }
}
