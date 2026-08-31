import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Nook

/// Native sheet focus and editor selection require a live keyboard check.
/// These tests protect the dismissal handoff that keeps a newly opened
/// window from competing with the palette's return to its parent.
@MainActor
struct CommandPaletteInteractionTests {
    private func command(
        _ id: String = "synthetic-command",
        perform: @escaping () -> Void = {}
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id, symbol: "doc", title: id, subtitle: nil,
            destination: .verb, perform: perform
        )
    }

    @Test
    func aChosenCommandWaitsForDismissalBeforeOpeningItsDestination() {
        var openedWindows: [String] = []
        var presentation = CommandPalettePresentation()
        presentation.present()
        presentation.select(command("quick-note") {
            openedWindows.append("Quick Note")
        })

        #expect(!presentation.isPresented)
        #expect(!presentation.canPresent)
        #expect(openedWindows.isEmpty)

        presentation.takeDismissedCommand()?.perform()

        #expect(openedWindows == ["Quick Note"])
        #expect(presentation.canPresent)
        presentation.takeDismissedCommand()?.perform()
        #expect(openedWindows == ["Quick Note"])
    }

    @Test
    func cancellingTheSheetNeverRunsACommandOrReplaysOneOnReopening() {
        var runs = 0
        var presentation = CommandPalettePresentation()
        presentation.present()
        presentation.select(command { runs += 1 })
        presentation.takeDismissedCommand()?.perform()
        #expect(runs == 1)

        presentation.present()
        // The sheet binding takes this path for Escape, Close, and native
        // dismissal. It must leave no command for the completion callback.
        presentation.isPresented = false
        #expect(!presentation.canPresent)
        #expect(presentation.takeDismissedCommand() == nil)
        #expect(presentation.canPresent)
        #expect(runs == 1)
    }

    @Test
    func repeatedActivationDuringDismissalCannotReplaceTheChosenCommand() {
        var runs: [String] = []
        var presentation = CommandPalettePresentation()
        presentation.present()
        presentation.select(command("first") { runs.append("first") })

        presentation.select(command("second") { runs.append("second") })
        presentation.present()
        presentation.isPresented = true
        #expect(!presentation.isPresented)
        #expect(!presentation.canPresent)

        presentation.takeDismissedCommand()?.perform()
        #expect(runs == ["first"])
        presentation.present()
        #expect(presentation.isPresented)
    }

    @Test
    func anUnrelatedDismissalCallbackDoesNotCloseAnOpenPalette() {
        var presentation = CommandPalettePresentation()
        #expect(presentation.takeDismissedCommand() == nil)
        presentation.present()

        #expect(presentation.takeDismissedCommand() == nil)
        #expect(presentation.isPresented)
        #expect(!presentation.canPresent)
    }

    @Test(arguments: [false, true])
    func externalInvalidationDropsQueuedCommandsUntilDismissalCompletes(
        commandWasChosen: Bool
    ) {
        var runs = 0
        var presentation = CommandPalettePresentation()
        presentation.present()
        if commandWasChosen { presentation.select(command { runs += 1 }) }

        // A folder change or parent close can arrive after selection has
        // already started the native dismissal animation.
        presentation.cancel()
        presentation.cancel()
        #expect(!presentation.isPresented)
        #expect(!presentation.canPresent)
        presentation.present()
        #expect(!presentation.isPresented)
        presentation.takeDismissedCommand()?.perform()
        #expect(runs == 0)
        #expect(presentation.canPresent)

        presentation.present()
        presentation.select(command { runs += 1 })
        presentation.takeDismissedCommand()?.perform()
        #expect(runs == 1)
        #expect(presentation.takeDismissedCommand() == nil)
    }

    @Test
    func cancellingBeforePresentationLeavesTheLauncherAvailable() {
        var presentation = CommandPalettePresentation()
        presentation.cancel()
        #expect(presentation.canPresent)
        #expect(presentation.takeDismissedCommand() == nil)
        presentation.present()
        #expect(presentation.isPresented)
    }

    @Test
    func anInPlaceDestinationIgnoresOldPaletteActionsAndDefersItsCitationUntilClose() {
        var runs: [String] = []
        var presentation = CommandPalettePresentation()
        presentation.present()
        let changed = presentation.showDestination()
        #expect(changed)
        #expect(!presentation.isPresented)
        #expect(!presentation.canPresent)

        // A detached palette may still finish a binding update or action.
        presentation.isPresented = false
        presentation.select(command("old-palette") { runs.append("old") })
        presentation.present()
        #expect(presentation.isShowingDestination)
        #expect(presentation.takeDismissedCommand() == nil)

        presentation.finishDestination(with: command("citation") { runs.append("citation") })
        // The citation button invokes onSelectNote then onClose. A second
        // close must not erase the destination selected by the first callback.
        presentation.finishDestination()
        #expect(runs.isEmpty)
        #expect(!presentation.canPresent)
        presentation.takeDismissedCommand()?.perform()
        presentation.takeDismissedCommand()?.perform()
        #expect(runs == ["citation"])
        #expect(presentation.canPresent)
    }

    @Test(arguments: [false, true])
    func externalInvalidationCancelsAnInPlaceAskAndItsQueuedCitation(citationWasSelected: Bool) {
        var runs = 0
        var presentation = CommandPalettePresentation()
        presentation.present()
        let changed = presentation.showDestination()
        #expect(changed)
        if citationWasSelected {
            presentation.finishDestination(with: command { runs += 1 })
        }
        presentation.cancel()
        presentation.takeDismissedCommand()?.perform()
        #expect(runs == 0)
        #expect(presentation.canPresent)
    }

    @Test
    func aPresenterWithoutItsOwnParentRefusesToOpenOrRunCallbacks() {
        let presenter = CommandPaletteSheetPresenter()
        let id = UUID()
        var dismissals = 0
        var invalidations = 0

        let didPresent = presenter.present(
            id: id, content: AnyView(EmptyView()),
            onDismiss: { dismissals += 1 },
            onInvalidation: { invalidations += 1 }
        )
        presenter.dismiss(id: id)
        presenter.invalidate()

        #expect(!didPresent)
        #expect(!presenter.canPresent)
        #expect(!presenter.isCurrent(id))
        #expect(dismissals == 0)
        #expect(invalidations == 0)
    }

    @Test
    func anExistingSheetRefusesPalettePresentationWithoutTouchingParentTextOrSelection() throws {
        let parent = hiddenWindow()
        let occupiedSheet = hiddenWindow()
        let presenter = CommandPaletteSheetPresenter()
        defer {
            presenter.attach(to: nil)
            parent.reservedSheet = nil
            occupiedSheet.close()
            parent.close()
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.isRichText = false
        let original = "Synthetic Cafe\u{0301} validation review."
        editor.string = original
        let selection = NSRange(location: 4, length: 6)
        editor.setSelectedRange(selection)
        parent.contentView = editor
        try #require(parent.makeFirstResponder(editor))
        parent.reservedSheet = occupiedSheet
        presenter.attach(to: parent)
        let id = UUID()
        var callbacks = 0

        let didPresent = presenter.present(
            id: id, content: AnyView(EmptyView()),
            onDismiss: { callbacks += 1 },
            onInvalidation: { callbacks += 1 }
        )

        #expect(!didPresent)
        #expect(!presenter.isCurrent(id))
        #expect(callbacks == 0)
        #expect(parent.attachedSheet === occupiedSheet)
        #expect(parent.firstResponder === editor)
        #expect(editor.selectedRange() == selection)
        #expect(Data(editor.string.utf8) == Data(original.utf8))
        #expect(!parent.isVisible)
        #expect(!occupiedSheet.isVisible)
    }

    @Test
    func replacingThePaletteWithAskKeepsItsSheetAndAcceptsTextBeforeReturningToTheRunLoop() throws {
        let parent = hiddenWindow()
        let presenter = CommandPaletteSheetPresenter()
        presenter.attach(to: parent)
        let state = PaletteAskTestState()
        let session = LibraryAskSession { _, _ in
            state.answererCalls += 1
            return LibraryAskSession.Response(answer: LibraryAnswer(
                text: "Unexpected synthetic answer", citations: [], refusedReason: nil
            ))
        }
        defer {
            presenter.attach(to: nil)
            parent.completeSheet()
            parent.close()
        }
        let parentEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        parentEditor.isRichText = false
        let original = "Synthetic source Cafe\u{0301}."
        parentEditor.string = original
        let selection = NSRange(location: 4, length: 6)
        parentEditor.setSelectedRange(selection)
        parent.contentView = parentEditor
        try #require(parent.makeFirstResponder(parentEditor))

        let id = UUID()
        let didPresent = presenter.present(
            id: id,
            content: AnyView(TextField("Synthetic palette query", text: Binding(
                get: { state.query }, set: { state.query = $0 }
            )).frame(width: 560).padding()),
            onDismiss: { session.cancel() }, onInvalidation: { session.cancel() }
        )
        try #require(didPresent)
        let sheet = try #require(parent.reservedSheet)
        let paletteField = try #require(editableTextField(in: sheet.contentView))
        try #require(sheet.makeFirstResponder(paletteField))
        let outgoingHost = try #require(sheet.contentView)

        let replaced = presenter.replaceContent(
            id: id,
            content: AnyView(LibraryAskView(
                notes: [], onSelectNote: { _ in }, onClose: {}, session: session
            )),
            title: "Ask your library"
        )

        try #require(replaced)
        #expect(parent.attachedSheet === sheet)
        #expect(parent.begunSheets.count == 1)
        #expect(parent.endedSheets.isEmpty)
        #expect(presenter.isCurrent(id))
        #expect(sheet.title == "Ask your library")
        #expect(outgoingHost.window == nil)
        let questionField = try #require(editableTextField(in: sheet.contentView))
        let fieldEditor = try #require(questionField.currentEditor() as? NSTextView)
        #expect(fieldEditor.isFieldEditor)
        #expect(sheet.firstResponder === fieldEditor)
        // No await, timer, render retry or focus call occurs after replacement.
        let question = "Synthetic Cafe\u{0301} immediate handoff."
        fieldEditor.insertText(question, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Data(session.question.utf8) == Data(question.utf8))
        #expect(Data(fieldEditor.string.utf8) == Data(question.utf8))
        #expect(state.query == "ask")
        #expect(state.answererCalls == 0)
        #expect(parent.firstResponder === parentEditor)
        #expect(parentEditor.selectedRange() == selection)
        #expect(Data(parentEditor.string.utf8) == Data(original.utf8))
        #expect(!parent.isVisible)
        #expect(!sheet.isVisible)
    }

    @Test
    func staleOrClosingPresentationsCannotReplaceCurrentContent() throws {
        let parent = hiddenWindow()
        let presenter = CommandPaletteSheetPresenter()
        presenter.attach(to: parent)
        var invalidations = 0
        var dismissals = 0
        defer {
            presenter.attach(to: nil)
            parent.completeSheet()
            parent.close()
        }
        let id = UUID()
        let didPresent = presenter.present(
            id: id, content: AnyView(Text("Current content").frame(width: 300, height: 80)),
            onDismiss: { dismissals += 1 }, onInvalidation: { invalidations += 1 }
        )
        try #require(didPresent)
        let sheet = try #require(parent.reservedSheet)
        let currentHost = try #require(sheet.contentView)
        let staleReplacement = presenter.replaceContent(
            id: UUID(), content: AnyView(Text("Stale content")), title: "Stale destination"
        )
        #expect(!staleReplacement)
        #expect(sheet.contentView === currentHost)

        presenter.invalidate()
        let closingReplacement = presenter.replaceContent(
            id: id, content: AnyView(Text("Canceled content")), title: "Canceled destination"
        )
        #expect(!closingReplacement)
        #expect(sheet.contentView === currentHost)
        #expect(parent.begunSheets.count == 1)
        #expect(parent.endedSheets.count == 1)
        #expect(invalidations == 1)
        #expect(dismissals == 0)
        parent.completeSheet()
        #expect(dismissals == 1)
        #expect(sheet.contentView == nil)
        #expect(!parent.isVisible)
        #expect(!sheet.isVisible)
    }

    @Test
    func windowAnchorFollowsItsActualParentAndReleasesItWhenRemoved() {
        let first = hiddenWindow()
        let second = hiddenWindow()
        let occupiedSheet = hiddenWindow()
        let presenter = CommandPaletteSheetPresenter()
        let anchor = CommandPaletteWindowTrackingView()
        anchor.presenter = presenter
        defer {
            anchor.removeFromSuperview()
            first.reservedSheet = nil
            second.reservedSheet = nil
            first.close()
            second.close()
            occupiedSheet.close()
        }
        #expect(!presenter.canPresent)
        first.contentView?.addSubview(anchor)
        #expect(presenter.canPresent)
        first.reservedSheet = occupiedSheet
        #expect(!presenter.canPresent)

        anchor.removeFromSuperview()
        #expect(!presenter.canPresent)
        second.contentView?.addSubview(anchor)
        #expect(presenter.canPresent)
        second.reservedSheet = occupiedSheet
        #expect(!presenter.canPresent)
        // Changing the previous window cannot make the occupied new parent
        // available or cause a lookup of some other key window.
        first.reservedSheet = nil
        #expect(!presenter.canPresent)
        second.reservedSheet = nil
        #expect(presenter.canPresent)
        #expect(!first.isVisible)
        #expect(!second.isVisible)
    }

    @Test(arguments: ["close-parent", "remove-anchor"], [false, true])
    func activeParentTeardownCancelsCommandsAndOldCompletionsCannotCloseTheNextPalette(
        teardown: String, commandWasChosen: Bool
    ) throws {
        let first = hiddenWindow()
        let second = hiddenWindow()
        let presenter = CommandPaletteSheetPresenter()
        let anchor = CommandPaletteWindowTrackingView()
        anchor.presenter = presenter
        first.contentView?.addSubview(anchor)
        var presentation = CommandPalettePresentation()
        var runs = 0
        var dismissals = 0
        var invalidations = 0
        defer {
            presenter.attach(to: nil)
            first.completeSheet()
            second.completeSheet()
            anchor.removeFromSuperview()
            first.close()
            second.close()
        }

        let firstID = UUID()
        presentation.present()
        let didPresent = presenter.present(
            id: firstID,
            content: AnyView(Text("Synthetic palette content").frame(width: 200, height: 80)),
            onDismiss: {
                dismissals += 1
                presentation.takeDismissedCommand()?.perform()
            },
            onInvalidation: {
                invalidations += 1
                presentation.cancel()
            }
        )
        try #require(didPresent)
        let firstSheet = try #require(first.reservedSheet)
        let oldCompletion = try #require(first.sheetCompletion)
        #expect(presenter.isCurrent(firstID))
        #expect(firstSheet.contentView != nil)
        #expect(!firstSheet.isVisible)
        #expect(!first.isVisible)

        if commandWasChosen {
            presentation.select(command { runs += 1 })
            presenter.dismiss(id: firstID)
        }
        // Exercise the real notification selector or viewDidMoveToWindow,
        // including teardown after selection has requested dismissal.
        if teardown == "close-parent" {
            first.close()
        } else {
            anchor.removeFromSuperview()
        }

        #expect(invalidations > 0)
        #expect(first.endedSheets.count == 1)
        #expect(first.endedSheets.first === firstSheet)
        #expect(dismissals == 0)
        #expect(runs == 0)
        #expect(!presentation.canPresent)
        #expect(presenter.isCurrent(firstID))

        first.completeSheet()
        #expect(dismissals == 1)
        #expect(runs == 0)
        #expect(presentation.canPresent)
        #expect(!presenter.isCurrent(firstID))
        #expect(firstSheet.contentView == nil)
        #expect(!firstSheet.isVisible)

        anchor.removeFromSuperview()
        second.contentView?.addSubview(anchor)
        let secondID = UUID()
        presentation.present()
        let didReopen = presenter.present(
            id: secondID,
            content: AnyView(Text("Synthetic reopened palette").frame(width: 200, height: 80)),
            onDismiss: {
                dismissals += 1
                presentation.takeDismissedCommand()?.perform()
            },
            onInvalidation: {
                invalidations += 1
                presentation.cancel()
            }
        )
        try #require(didReopen)
        let secondSheet = try #require(second.reservedSheet)
        let invalidationsBeforeOldCompletion = invalidations

        oldCompletion(.cancel)

        #expect(presenter.isCurrent(secondID))
        #expect(presentation.isPresented)
        #expect(dismissals == 1)
        #expect(invalidations == invalidationsBeforeOldCompletion)
        #expect(secondSheet.contentView != nil)
        #expect(second.endedSheets.isEmpty)

        // AppKit may finish a sheet without the binding requesting dismissal.
        // That callback must invalidate it before completing the handoff too.
        second.completeSheet()
        #expect(invalidations == invalidationsBeforeOldCompletion + 1)
        #expect(dismissals == 2)
        #expect(runs == 0)
        #expect(presentation.canPresent)
        #expect(!presenter.isCurrent(secondID))
        #expect(secondSheet.contentView == nil)
        #expect(!first.isVisible)
        #expect(!second.isVisible)
        #expect(!secondSheet.isVisible)
    }

    @Test(arguments: [false, true])
    func recordingCommandsShowTheActualShortcutAndKeepTheCorrectAction(
        isRecording: Bool
    ) throws {
        let suite = "NookPaletteInteractionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutStore(defaults: defaults)
        let action: NookShortcutID = isRecording ? .finishMeeting : .startRecording
        let custom = DictationShortcut(
            keyCode: UInt32(kVK_ANSI_Y),
            modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue,
            displayCharacter: "Y"
        )
        shortcuts.set(custom, for: action)
        var started = 0
        var finished = 0
        let item = CommandPaletteCommands.recording(
            isRecording: isRecording, shortcuts: shortcuts,
            start: { started += 1 }, finish: { finished += 1 }
        )

        #expect(item.shortcut == "⌃⌥Y")
        #expect(item.title == (isRecording ? "Finish meeting" : "Start recording"))
        item.perform()
        #expect(started == (isRecording ? 0 : 1))
        #expect(finished == (isRecording ? 1 : 0))

        shortcuts.set(nil, for: action)
        let reset = CommandPaletteCommands.recording(
            isRecording: isRecording, shortcuts: shortcuts, start: {}, finish: {}
        )
        #expect(reset.shortcut == action.defaultShortcut.displayString)
    }

    @Test
    func refreshedRowsRetainTheChosenIdentityButUseTheCurrentAction() {
        var invoked: [String] = []
        var selection = CommandPaletteSelection()
        let previous = command("action-note#0") { invoked.append("previous") }
        selection.select(previous)
        let refreshed = command("action-note#0") { invoked.append("current") }

        selection.refresh(in: [refreshed])
        selection.selectedItem(in: [refreshed])?.perform()
        #expect(invoked == ["current"])

        selection.refresh(in: [])
        selection.selectedItem(in: [refreshed])?.perform()
        #expect(invoked == ["current"])
    }

    private func hiddenWindow() -> PaletteParentTestWindow {
        let window = PaletteParentTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        return window
    }

    private func editableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { editableTextField(in: $0) }.first
    }
}

@MainActor
private final class PaletteAskTestState {
    var query = "ask"
    var answererCalls = 0
}

/// Holds AppKit's completion boundary without presenting a window or taking
/// keyboard focus. The production presenter still creates and releases its
/// actual hosting view; only the native begin/end transition is controlled.
@MainActor
private final class PaletteParentTestWindow: NSWindow {
    var reservedSheet: NSWindow?
    var sheetCompletion: ((NSApplication.ModalResponse) -> Void)?
    private(set) var begunSheets: [NSWindow] = []
    private(set) var endedSheets: [NSWindow] = []

    override var attachedSheet: NSWindow? { reservedSheet ?? super.attachedSheet }

    override func beginSheet(
        _ sheetWindow: NSWindow,
        completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        begunSheets.append(sheetWindow)
        reservedSheet = sheetWindow
        sheetCompletion = handler
    }

    override func endSheet(_ sheetWindow: NSWindow) {
        endedSheets.append(sheetWindow)
    }

    func completeSheet() {
        let completion = sheetCompletion
        sheetCompletion = nil
        reservedSheet = nil
        completion?(.cancel)
    }
}
