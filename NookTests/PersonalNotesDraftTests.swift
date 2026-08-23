import Foundation
import Testing
@testable import Nook

/// The My notes field used to live in the detail view's own state, which meant
/// it lived exactly as long as that view did. The library rebuilds the view on
/// every selection change, and a meeting starting by itself changes the
/// selection, so anything typed and not explicitly saved was destroyed with no
/// warning and nothing to undo. These cover what now stands between a
/// half-typed follow-up and that.
@MainActor
struct PersonalNotesDraftTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NookPersonalNotes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    @discardableResult
    private func savedNote(
        title: String,
        in store: MarkdownStore
    ) throws -> MeetingNote {
        try store.save(
            MeetingNote(
                title: title,
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: Date(timeIntervalSince1970: 1_780_003_600),
                sourceApp: "Zoom",
                summary: "The team agreed on the launch scope."
            )
        )
    }

    // MARK: What leaving a note owes

    @Test
    func leavingANoteWithNothingPendingJustLeaves() {
        #expect(
            LibraryLeaveGuard.decide(
                hasMarkdownChanges: false,
                hasPersonalNotesChanges: false
            ) == .leave
        )
    }

    @Test
    func leavingANoteWithTypedNotesWritesThemFirst() {
        #expect(
            LibraryLeaveGuard.decide(
                hasMarkdownChanges: false,
                hasPersonalNotesChanges: true
            ) == .saveFirst
        )
    }

    @Test
    func theMarkdownEditorIsStillTheOneThatAsks() {
        // It is the only editor with a Save and a Discard of its own, so it
        // is the only one holding a decision the user has to make.
        #expect(
            LibraryLeaveGuard.decide(
                hasMarkdownChanges: true,
                hasPersonalNotesChanges: false
            ) == .askAboutMarkdown
        )
        #expect(
            LibraryLeaveGuard.decide(
                hasMarkdownChanges: true,
                hasPersonalNotesChanges: true
            ) == .askAboutMarkdown
        )
    }

    // MARK: The draft itself

    @Test
    func typedNotesReachTheMarkdownFileWithoutTheWindowThatTypedThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "Ask Ana whether the beta list is final."

        #expect(draft.hasChanges)
        #expect(draft.saveIfNeeded(store: store) == nil)
        #expect(!draft.hasChanges)

        let onDisk = store.notes.first { $0.id == note.id }
        #expect(onDisk?.personalNotes == "Ask Ana whether the beta list is final.")
    }

    @Test
    func whitespaceAloneIsNotAnEditWorthSaving() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "\n  \n"

        #expect(!draft.hasChanges)
    }

    @Test
    func aSelectionChangeCannotTakeUnsavedNotesWithIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let first = try savedNote(title: "Launch review", in: store)
        let second = try savedNote(title: "Design sync", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: first, store: store)
        draft.text = "Chase the pricing page copy."
        // What a meeting starting by itself does: the selection moves before
        // anybody has pressed anything.
        draft.prepare(for: second, store: store)

        #expect(draft.noteID == second.id)
        #expect(draft.text.isEmpty)
        #expect(
            store.notes.first { $0.id == first.id }?.personalNotes
                == "Chase the pricing page copy."
        )
    }

    @Test
    func aReloadFromDiskDoesNotOverwriteWordsStillBeingTyped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        var note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "Half a sentence"

        note.personalNotes = "Something the library loaded"
        draft.refresh(for: note)

        #expect(draft.text == "Half a sentence")
    }

    @Test
    func theSavedConfirmationDoesNotStandOverWordsTypedSince() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "Ask Ana about the beta list."
        #expect(draft.saveIfNeeded(store: store) == nil)
        #expect(draft.statusMessage == "Saved")

        draft.text = "Ask Ana about the beta list. And the pricing copy."
        #expect(draft.statusMessage == nil)
    }

    @Test
    func quittingReportsNotesItCouldNotWriteRatherThanDroppingThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "The one line that matters."

        // The note leaves the folder between the edit and the quit.
        #expect(store.delete(note))

        let failure = draft.saveIfNeeded(store: store)
        #expect(failure != nil)
        // Still in hand, so the words are recoverable rather than gone.
        #expect(draft.text == "The one line that matters.")
        #expect(draft.hasChanges)
    }

    @Test
    func aFileChangedOutsideNookRefusesTheSaveInsteadOfOverwritingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Launch review", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "Typed in Nook."

        // Something else wrote the file while the field was open.
        let fileURL = try #require(note.fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: fileURL.path
        )

        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(draft.text == "Typed in Nook.")
    }
}
