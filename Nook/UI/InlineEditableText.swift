import AppKit
import SwiftUI

/// A request to put the keyboard in one row of an inline list, applied once.
///
/// A token rather than a Boolean for the reason `NookNotesEditor` gives: a
/// polled flag can be re-applied by an unrelated render and steal focus back.
struct InlineFocusRequest: Equatable {
    let rowID: UUID
    /// Caret position in UTF-16 units.
    let caret: Int
    let token: Int
}

/// One paragraph of generated text that reads like the static text it
/// replaced and edits like a line in Notes.
///
/// There is no Edit mode. The text is always the editor: clicking places the
/// caret, Return starts a new row, Delete at the start of a row joins it to
/// the one above, and the arrow keys walk between rows. The owner of the rows
/// decides what those keys mean; this view only reports them.
struct InlineEditableText: View {
    @Binding var text: String
    /// What to show while the field does not have the keyboard, when that
    /// differs from the words being edited. An action item shows its task
    /// without the owner prefix, which is displayed separately.
    var displayText: String?
    var placeholder: String
    var font: NSFont
    var lineSpacing: CGFloat
    var textColor: NSColor = .labelColor
    var strikethrough = false
    var isEditable = true
    var accessibilityLabel: String
    var accessibilityHelp: String?
    var focusRequest: InlineFocusRequest?
    var onFocusChange: (Bool) -> Void = { _ in }
    var onReturn: ((Int) -> Bool)?
    var onDeleteAtStart: (() -> Bool)?
    var onMoveUp: (() -> Bool)?
    var onMoveDown: (() -> Bool)?

    @State private var isFocused = false

    var body: some View {
        InlineTextRepresentable(
            text: $text,
            displayText: displayText,
            font: font,
            lineSpacing: lineSpacing,
            textColor: textColor,
            strikethrough: strikethrough,
            isEditable: isEditable,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: accessibilityHelp,
            focusRequest: focusRequest,
            onFocusChange: { focused in
                isFocused = focused
                onFocusChange(focused)
            },
            onReturn: onReturn,
            onDeleteAtStart: onDeleteAtStart,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty && (displayText ?? "").isEmpty {
                Text(placeholder)
                    .font(Font(font))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // The only sign of editing besides the caret: the same field surface
        // My notes shows, behind the row with the keyboard and drawn outside
        // the text so nothing moves.
        .background {
            NookFieldSurface(isFocused: isFocused && isEditable)
                .padding(.horizontal, -7)
                .padding(.vertical, -4)
        }
    }
}

/// Tracks the keyboard itself rather than the delegate's editing
/// notifications, which only begin at the first keystroke. A click into the
/// row is the moment its full wording has to appear.
final class InlineTextView: NSTextView {
    var onFirstResponderChange: ((Bool) -> Void)?
    fileprivate var pendingCaret: Int?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFirstResponderChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFirstResponderChange?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let caret = pendingCaret, window != nil {
            pendingCaret = nil
            focus(caret: caret)
        }
    }

    /// Takes the keyboard with the caret at a UTF-16 offset. Deferred to the
    /// next turn because a row inserted by Return has no window yet while
    /// SwiftUI is still updating.
    func focus(caret: Int) {
        guard window != nil else {
            pendingCaret = caret
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, self.isEditable else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
            let length = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: min(max(0, caret), length), length: 0))
            self.scrollRangeToVisible(self.selectedRange())
        }
    }

    var caretIsOnFirstLine: Bool {
        guard let layoutManager, let textContainer else { return true }
        let caret = selectedRange().location
        guard caret > 0, layoutManager.numberOfGlyphs > 0 else { return true }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, (string as NSString).length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY <= 0.5
    }

    var caretIsOnLastLine: Bool {
        guard let layoutManager, let textContainer else { return true }
        let length = (string as NSString).length
        let caret = selectedRange().location
        guard caret < length, layoutManager.numberOfGlyphs > 0 else { return true }
        layoutManager.ensureLayout(for: textContainer)
        let caretLine = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: caret), effectiveRange: nil
        )
        let lastLine = layoutManager.lineFragmentRect(
            forGlyphAt: max(0, layoutManager.numberOfGlyphs - 1), effectiveRange: nil
        )
        return caretLine.minY >= lastLine.minY - 0.5
    }
}

private struct InlineTextRepresentable: NSViewRepresentable {
    @Binding var text: String
    let displayText: String?
    let font: NSFont
    let lineSpacing: CGFloat
    let textColor: NSColor
    let strikethrough: Bool
    let isEditable: Bool
    let accessibilityLabel: String
    let accessibilityHelp: String?
    let focusRequest: InlineFocusRequest?
    let onFocusChange: (Bool) -> Void
    let onReturn: ((Int) -> Bool)?
    let onDeleteAtStart: (() -> Bool)?
    let onMoveUp: (() -> Bool)?
    let onMoveDown: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> InlineTextView {
        // TextKit 1, as for the My notes editor: chosen when the text system
        // is created, never by switching a live view.
        let textView = InlineTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.insertionPointColor = .controlAccentColor
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.onFirstResponderChange = { [weak coordinator = context.coordinator, weak textView] focused in
            guard let coordinator, let textView else { return }
            coordinator.isEditing = focused
            coordinator.synchronize(textView)
            coordinator.parent.onFocusChange(focused)
        }
        context.coordinator.synchronize(textView, forceStyle: true)
        return textView
    }

    func updateNSView(_ textView: InlineTextView, context: Context) {
        let styleChanged = context.coordinator.parent.font != font
            || context.coordinator.parent.lineSpacing != lineSpacing
            || context.coordinator.parent.textColor != textColor
            || context.coordinator.parent.strikethrough != strikethrough
        context.coordinator.parent = self
        textView.isEditable = isEditable
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        context.coordinator.synchronize(textView, forceStyle: styleChanged)
        if !isEditable, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        if let focusRequest, focusRequest.token != context.coordinator.appliedFocusToken {
            context.coordinator.appliedFocusToken = focusRequest.token
            if isEditable { textView.focus(caret: focusRequest.caret) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: InlineTextView, context: Context) -> CGSize? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return nil
        }
        let proposed = proposal.width ?? 10_000
        let width = proposed.isFinite && proposed > 0 ? proposed : 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        // TextKit 1 leaves line spacing off the last line, as SwiftUI's Text
        // does, so the used height matches the static text these rows
        // replaced once rounded up to a whole point. A test holds this.
        let height = max(
            layoutManager.usedRect(for: container).height,
            layoutManager.defaultLineHeight(for: font)
        )
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextRepresentable
        var isEditing = false
        var appliedFocusToken = 0

        init(parent: InlineTextRepresentable) {
            self.parent = parent
        }

        /// Shows the words being edited while the row has the keyboard and
        /// its display form otherwise. Never rewrites the buffer while an
        /// input method is composing: that would throw the composition away.
        func synchronize(_ textView: NSTextView, forceStyle: Bool = false) {
            guard !textView.hasMarkedText() else { return }
            let wanted = isEditing ? parent.text : (parent.displayText ?? parent.text)
            let replacing = !textView.string.utf16.elementsEqual(wanted.utf16)
            if replacing {
                let selection = textView.selectedRange()
                textView.string = wanted
                let length = (wanted as NSString).length
                let location = min(selection.location, length)
                textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            }
            if replacing || forceStyle {
                applyStyle(to: textView)
            }
        }

        private func applyStyle(to textView: NSTextView) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.lineSpacing
            // SwiftUI's Text breaks lines with the standard strategy, which
            // pushes a lone last word down with its neighbour. Without it the
            // rows wrapped differently from the text they replaced.
            paragraph.lineBreakStrategy = .standard
            var attributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: parent.textColor,
                .paragraphStyle: paragraph,
            ]
            if parent.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            textView.font = parent.font
            textView.textColor = parent.textColor
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = attributes
            if let storage = textView.textStorage, storage.length > 0 {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard isEditing, let textView = notification.object as? NSTextView else { return }
            var snapshot = textView.string
            snapshot.makeContiguousUTF8()
            parent.text = snapshot
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let textView = textView as? InlineTextView else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let onReturn = parent.onReturn else { return false }
                if textView.selectedRange().length > 0 { textView.delete(nil) }
                return onReturn(textView.selectedRange().location)
            case #selector(NSResponder.deleteBackward(_:)):
                let selection = textView.selectedRange()
                guard selection.location == 0, selection.length == 0,
                      let onDeleteAtStart = parent.onDeleteAtStart else { return false }
                return onDeleteAtStart()
            case #selector(NSResponder.moveUp(_:)):
                guard textView.caretIsOnFirstLine, let onMoveUp = parent.onMoveUp else { return false }
                return onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                guard textView.caretIsOnLastLine, let onMoveDown = parent.onMoveDown else { return false }
                return onMoveDown()
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape leaves the text, which saves it, as clicking away does.
                textView.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}
