import AppKit
import SwiftUI

/// A plain-text notes editor with explicit text-container geometry. SwiftUI's
/// TextEditor inherits private AppKit insets, which made independently padded
/// placeholders drift away from the insertion point across Nook's three notes
/// surfaces.
struct NookNotesEditor: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    var isFocused: Binding<Bool>?
    var contentInsets = EdgeInsets(
        top: 10,
        leading: 11,
        bottom: 10,
        trailing: 11
    )
    var fontSize = NSFont.systemFontSize
    var lineSpacing: CGFloat = 4
    var accessibilityLabel = "Personal meeting notes"

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
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                accessibilityLabel: accessibilityLabel,
                isEditable: isEnabled
            )
            .padding(contentInsets)
        }
    }
}

private struct PlainNotesTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>?
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let accessibilityLabel: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
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

        configure(textView)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        configure(textView)
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

        guard let isFocused else { return }
        if isFocused.wrappedValue,
           textView.window?.firstResponder !== textView {
            Task { @MainActor in
                guard isFocused.wrappedValue else { return }
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused.wrappedValue,
                  textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
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
