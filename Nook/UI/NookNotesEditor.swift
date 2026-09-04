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

    enum ReplacementResult { case applied, unavailable, refused }

    /// An explicit reviewed correction is one native undo group. An input
    /// method or a stale rendered buffer must never lose its text to it.
    func replaceText(expected: String, with replacement: String, actionName: String) -> ReplacementResult {
        guard let textView else { return .unavailable }
        guard textView.isEditable, !textView.hasMarkedText(),
              textView.string.utf16.elementsEqual(expected.utf16) else { return .refused }
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        textView.insertText(replacement, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        textView.undoManager?.setActionName(actionName)
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        return textView.string.utf16.elementsEqual(replacement.utf16) ? .applied : .refused
    }

    func announce(_ message: String) {
        guard let textView else { return }
        NSAccessibility.post(element: textView, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

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
    private let textInput: ExactNotesText
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

    init(
        text: Binding<String>,
        placeholder: String,
        isFocused: Binding<Bool>? = nil,
        focusToken: Int = 0,
        contentInsets: EdgeInsets = EdgeInsets(top: 10, leading: 11, bottom: 10, trailing: 11),
        fontSize: CGFloat = NSFont.systemFontSize,
        lineSpacing: CGFloat = 4,
        accessibilityLabel: String = "Personal meeting notes",
        insertionPort: TextViewInsertionPort? = nil
    ) {
        _text = text
        // A Binding<String> can compare equal after an NFC/NFD-only change,
        // before updateNSView ever runs. Capture an exact value as a separate
        // SwiftUI input, without allocating a byte array or recreating the view.
        textInput = ExactNotesText(value: text.wrappedValue)
        self.placeholder = placeholder
        self.isFocused = isFocused
        self.focusToken = focusToken
        self.contentInsets = contentInsets
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.accessibilityLabel = accessibilityLabel
        self.insertionPort = insertionPort
    }

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
                textInput: textInput,
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

    /// AppKit can vend foreign UTF-16 String storage. Convert once at the
    /// editor boundary so revision and recovery checks reuse contiguous UTF-8
    /// instead of traversing that bridge repeatedly. This changes storage,
    /// never normalization or text, and does not write into the text view.
    static func textSnapshot(from textView: NSTextView) -> String {
        var snapshot = textView.string
        snapshot.makeContiguousUTF8()
        return snapshot
    }

    /// Swift String equality treats composed and decomposed text as equal.
    /// The binding owns exact text, so an explicit replacement must reach the
    /// editor even when it only changes that encoding. Compare UTF-16 units
    /// at AppKit's boundary without normalizing or converting the whole buffer.
    static func synchronizeText(_ text: String, in textView: NSTextView) {
        // The input method owns this temporary range until it commits or
        // cancels. An unrelated SwiftUI update still carries committed text;
        // replacing the buffer here would discard the user's composition.
        guard !textView.hasMarkedText() else { return }
        guard !textView.string.utf16.elementsEqual(text.utf16) else { return }
        let selection = textView.selectedRange()
        textView.string = text
        let textLength = (text as NSString).length
        let location = min(selection.location, textLength)
        textView.setSelectedRange(NSRange(
            location: location,
            length: min(selection.length, textLength - location)
        ))
    }

    /// Apply an explicit request once, after the representable update has
    /// attached the editor. Returning the scheduled work lets native tests
    /// verify actual first-responder behavior without showing a window.
    @discardableResult
    static func requestFocus(
        _ token: Int,
        appliedToken: inout Int,
        in textView: NSTextView
    ) -> Task<Void, Never>? {
        guard token != appliedToken, textView.isEditable else { return nil }
        appliedToken = token
        return Task { @MainActor [weak textView] in
            guard let textView, textView.isEditable, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
    }
}

private struct ExactNotesText: Equatable {
    let value: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value.utf8.elementsEqual(rhs.value.utf8)
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
    let textInput: ExactNotesText
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

        // An isolated native probe showed substantially more typing work for
        // very long paragraphs with TextKit 2. Choose TextKit 1 when creating
        // the text system, never by switching a live editor or changing its text.
        let textView = KeyActivatingTextView(usingTextLayoutManager: false)
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
        textView.string = textInput.value
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
        NookNotesEditor.synchronizeText(textInput.value, in: textView)

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
        NookNotesEditor.requestFocus(
            focusToken,
            appliedToken: &context.coordinator.appliedFocusToken,
            in: textView
        )
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
            parent.text = NookNotesEditor.textSnapshot(from: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = false
        }
    }
}
