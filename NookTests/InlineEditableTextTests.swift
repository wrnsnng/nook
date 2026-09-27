import AppKit
import SwiftUI
import Testing
@testable import Nook

/// The rows of the generated sections are real AppKit text views. These drive
/// them through AppKit's own command path, in a hidden window, to show that
/// the keys a person presses reach the row model the way the notes tab uses it.
@MainActor
struct InlineEditableTextTests {
    @Test
    func typingReturnAndDeleteEditTheRowsAndMoveTheCaret() async throws {
        let model = InlineRowsFixtureModel(rows: SummaryListRow.rows(from: ["Scope is final"]))
        let fixture = try await hosted(model)
        defer { fixture.window.close() }

        let first = try #require(textViews(in: fixture.host).first)
        try #require(fixture.window.makeFirstResponder(first))
        first.setSelectedRange(NSRange(location: 14, length: 0))
        first.insertText(" for 1.0", replacementRange: first.selectedRange())
        #expect(model.rows.map(\.text) == ["Scope is final for 1.0"])

        first.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(model.rows.map(\.text) == ["Scope is final for 1.0", ""])
        try await settle(fixture.host) {
            textViews(in: fixture.host).count == 2
                && fixture.window.firstResponder === textViews(in: fixture.host).last
        }

        let second = try #require(textViews(in: fixture.host).last)
        second.insertText("Beta starts in March", replacementRange: second.selectedRange())
        #expect(model.rows.map(\.text) == ["Scope is final for 1.0", "Beta starts in March"])

        // Clear the new row, then Delete in the empty row removes it and the
        // caret returns to the end of the row above.
        second.selectAll(nil)
        second.deleteBackward(nil)
        second.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(model.rows.map(\.text) == ["Scope is final for 1.0"])
        try await settle(fixture.host) {
            textViews(in: fixture.host).count == 1
                && fixture.window.firstResponder === textViews(in: fixture.host).first
        }
        let remaining = try #require(textViews(in: fixture.host).first)
        #expect(remaining.selectedRange().location == ("Scope is final for 1.0" as NSString).length)
    }

    @Test
    func aRowShowsItsDisplayFormUntilItHasTheKeyboard() async throws {
        let model = InlineRowsFixtureModel(
            rows: [SummaryListRow(text: "Maya: send the brief")],
            display: "Send the brief"
        )
        let fixture = try await hosted(model)
        defer { fixture.window.close() }
        let row = try #require(textViews(in: fixture.host).first)
        #expect(row.string == "Send the brief")

        try #require(fixture.window.makeFirstResponder(row))
        #expect(row.string == "Maya: send the brief")

        fixture.window.makeFirstResponder(nil)
        #expect(row.string == "Send the brief")
        #expect(model.rows.map(\.text) == ["Maya: send the brief"])
    }

    /// The gist uses 7 points of line spacing, list items 4 and questions 0.
    @Test(arguments: [0.0, 4.0, 7.0])
    func aRowMeasuresTheSameHeightAsTheTextItReplaced(lineSpacing: Double) async throws {
        let sentence = String(repeating: "A synthetic sentence that wraps across lines. ", count: 6)
        let model = InlineRowsFixtureModel(rows: [SummaryListRow(text: sentence)], lineSpacing: lineSpacing)
        let fixture = try await hosted(model, width: 320)
        defer { fixture.window.close() }
        let row = try #require(textViews(in: fixture.host).first)

        let text = NSHostingView(rootView:
            Text(sentence).font(NookType.transcript).lineSpacing(lineSpacing)
                .frame(width: row.frame.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        )
        text.frame.size = text.fittingSize
        #expect(abs(text.fittingSize.height - row.frame.height) <= 1,
                "Text \(text.fittingSize) row \(row.frame.size)")
    }

    // MARK: Fixture

    private struct Hosted {
        let host: NSView
        let window: NSWindow
    }

    private func hosted(_ model: InlineRowsFixtureModel, width: Double = 460) async throws -> Hosted {
        let host = NSHostingView(rootView: InlineRowsFixture(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle(host) { !textViews(in: host).isEmpty && (textViews(in: host).first?.bounds.width ?? 0) > 0 }
        return Hosted(host: host, window: window)
    }

    private func settle(_ host: NSView, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The hidden rows did not reach the expected state.")
    }
}

@MainActor
private func textViews(in view: NSView) -> [InlineTextView] {
    if let row = view as? InlineTextView { return [row] }
    return view.subviews.flatMap { textViews(in: $0) }
}

@MainActor
private final class InlineRowsFixtureModel: ObservableObject {
    @Published var rows: [SummaryListRow]
    @Published var focus: InlineFocusRequest?
    let display: String?
    let lineSpacing: CGFloat
    private var token = 0

    init(rows: [SummaryListRow], display: String? = nil, lineSpacing: CGFloat = 4) {
        self.rows = rows
        self.display = display
        self.lineSpacing = lineSpacing
    }

    func apply(_ edit: (inout [SummaryListRow]) -> SummaryRowEditing.Focus?) -> Bool {
        var edited = rows
        let target = edit(&edited)
        guard edited != rows else { return false }
        rows = edited
        if let target {
            token += 1
            focus = InlineFocusRequest(rowID: target.rowID, caret: target.caret, token: token)
        }
        return true
    }
}

private struct InlineRowsFixture: View {
    @ObservedObject var model: InlineRowsFixtureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                InlineEditableText(
                    text: Binding(
                        get: { model.rows.first { $0.id == row.id }?.text ?? "" },
                        set: { value in
                            guard let index = model.rows.firstIndex(where: { $0.id == row.id }) else { return }
                            model.rows[index].text = value
                        }
                    ),
                    displayText: model.display,
                    placeholder: "Key point",
                    font: NookInlineFont.body,
                    lineSpacing: model.lineSpacing,
                    accessibilityLabel: "Key point",
                    focusRequest: model.focus?.rowID == row.id ? model.focus : nil,
                    onReturn: { caret in model.apply { SummaryRowEditing.split(&$0, at: row.id, caret: caret) } },
                    onDeleteAtStart: { model.apply { SummaryRowEditing.deleteBackward(&$0, at: row.id) } }
                )
            }
            Spacer(minLength: 0)
        }
    }
}
