import AppKit
import SwiftUI
import Testing
@testable import Nook

@MainActor
struct CopyNoticeStateTests {
    @Test
    func failuresStayAvailableUntilExplicitlyDismissed() {
        var state = CopyNoticeState()
        let message = "Synthetic save failure. Review the current file before applying your changes."
        let id = state.show(message, severity: .failure)

        #expect(state.current?.expirationDelay == nil)
        state.expire(id: id)
        #expect(state.current?.id == id)
        #expect(state.current?.message == message)

        state.dismiss(id: id)
        #expect(state.current == nil)
    }

    @Test
    func repeatingTheSameNoticeGetsItsOwnFullDisplayLifetime() {
        var state = CopyNoticeState()
        let first = state.show("Markdown copied", severity: .success)
        let repeated = state.show("Markdown copied", severity: .success)
        #expect(first != repeated)

        state.expire(id: first)
        #expect(state.current?.id == repeated)
        #expect(state.current?.message == "Markdown copied")

        state.expire(id: repeated)
        #expect(state.current == nil)
    }

    @Test
    func anOldTimerOrDismissButtonCannotRemoveANewerFailure() {
        var state = CopyNoticeState()
        let previous = state.show("Review this note", severity: .info)
        let failure = state.show("Review this note", severity: .failure)

        state.expire(id: previous)
        state.dismiss(id: previous)
        #expect(state.current?.id == failure)
        #expect(state.current?.severity == .failure)
        #expect(state.current?.expirationDelay == nil)
    }

    @Test
    func aNewOutcomeMayReplaceADismissableFailure() {
        var state = CopyNoticeState()
        let failure = state.show("Synthetic save failed", severity: .failure)
        let saved = state.show("Title saved", severity: .success)

        state.dismiss(id: failure)
        #expect(state.current?.id == saved)
        #expect(state.current?.message == "Title saved")
        state.expire(id: saved)
        #expect(state.current == nil)
    }

    @Test
    func successAndInformationKeepTheirExistingDwellTimes() {
        var state = CopyNoticeState()
        state.show("Copied", severity: .success)
        #expect(state.current?.expirationDelay == 1.8)
        state.show("Review this note", severity: .info)
        #expect(state.current?.expirationDelay == 4)
    }

    @Test(arguments: [340.0, 595.0])
    func noticesLeaveTheHeadingVisibleAndKeepTheSameEditorAndSelection(width: Double) async throws {
        let model = NoticeLayoutFixtureModel()
        let host = NSHostingView(rootView: NoticeLayoutFixture(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled],
            backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settleLayout(in: host) { model.headingFrame.height > 0 }
        let headingWithoutNotice = model.headingFrame
        let editor = try #require(editors(in: host).first)
        let original = model.text
        let selection = NSRange(location: 10, length: 7)
        try #require(window.makeFirstResponder(editor))
        editor.setSelectedRange(selection)

        let short = model.notice.show("Your existing note is unchanged.", severity: .failure)
        try await settleLayout(in: host) {
            model.headingFrame.minY > headingWithoutNotice.maxY
        }
        let headingWithShortNotice = model.headingFrame
        let long = model.notice.show(
            String(repeating: "Synthetic save error. Review the local file before trying again.\n", count: 60),
            severity: .failure
        )
        try await settleLayout(in: host) {
            model.headingFrame.minY > headingWithShortNotice.minY
        }
        // Even an unusually long explanation must leave the document heading
        // and a usable portion of its editor inside the window.
        #expect(model.headingFrame.maxY < 240)
        #expect(editors(in: host).first === editor)
        #expect(editor.visibleRect.height > 80)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string.utf8.elementsEqual(original.utf8))

        model.notice.dismiss(id: short)
        #expect(model.notice.current?.id == long)
        model.notice.dismiss(id: long)
        try await settleLayout(in: host) {
            model.headingFrame == headingWithoutNotice
        }
        #expect(editors(in: host).first === editor)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)
        #expect(editor.string.utf8.elementsEqual(original.utf8))
        #expect(model.text.utf8.elementsEqual(original.utf8))
        #expect(!window.isVisible)
    }

    private func editors(in view: NSView) -> [NSTextView] {
        if let editor = view as? NSTextView { return [editor] }
        return view.subviews.flatMap { editors(in: $0) }
    }

    private func settleLayout(
        in host: NSView,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The hidden native fixture did not reach the expected layout.")
    }
}

@MainActor
private final class NoticeLayoutFixtureModel: ObservableObject {
    @Published var notice = CopyNoticeState()
    @Published var text = "Synthetic Cafe\u{0301} preparation. Keep my exact words and selection."
    var headingFrame: CGRect = .zero
}

@MainActor
private struct NoticeLayoutFixture: View {
    @ObservedObject var model: NoticeLayoutFixtureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthetic meeting")
                .font(.title2)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("notice-layout-fixture"))
                } action: { model.headingFrame = $0 }
            NookNotesEditor(text: $model.text, placeholder: "My notes")
        }
        .padding(20)
        .nookNotice(model.notice.current) { model.notice.dismiss(id: $0) }
        .coordinateSpace(name: "notice-layout-fixture")
        .transaction { $0.disablesAnimations = true }
    }
}
