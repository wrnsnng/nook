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

    private func externallyChangeSummary(at file: URL) throws -> String {
        let original = try String(contentsOf: file, encoding: .utf8)
        let changed = original.replacingOccurrences(
            of: "The team agreed on the launch scope.",
            with: "Another editor changed the launch scope."
        )
        #expect(changed != original)
        try changed.write(to: file, atomically: true, encoding: .utf8)
        return original
    }

    /// Keep even the initializer's load inside the synthetic fixture directory.
    private func reloadableStore(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, cache in
            MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = directory
        return store
    }

    private func waitForReload(_ store: MarkdownStore) async throws {
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isLoading)
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

    @Test(arguments: ["\n", "\n\n", "\r\n"])
    func savingOnlySurroundingWhitespaceKeepsEveryOriginalMarkdownByte(
        terminalLineBreak: String
    ) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var commits = 0
        let store = MarkdownStore(
            noteLoader: { _, _ in .success((notes: [], issues: [])) },
            beforeWriteCommit: { _ in commits += 1 }
        )
        store.storageURL = directory
        var note = try savedNote(title: "Synthetic whitespace review", in: store)
        note.personalNotes = "My own cafe\u{0301} preparation."
        note = try store.save(note)
        let file = try #require(note.fileURL)
        let source = MarkdownCodec.encode(note) + terminalLineBreak
        try store.saveRawMarkdown(source, for: note)
        note = try #require(store.uniqueNote(id: note.id))
        let revision = note.fileRevision
        let writesBefore = commits

        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = " \n" + note.personalNotes + "\n "
        #expect(draft.hasExactChanges)
        #expect(!draft.hasChanges)
        // Regeneration preflight and leaving the library both settle exact
        // draft changes, even when trimming leaves the existing field intact.
        #expect(draft.saveIfNeeded(store: store) == nil)

        #expect(try Data(contentsOf: file) == Data(source.utf8))
        #expect(commits == writesBefore)
        #expect(store.uniqueNote(id: note.id)?.fileRevision == revision)
        #expect(draft.text.utf8.elementsEqual(note.personalNotes.utf8))
        #expect(!draft.hasExactChanges)
        #expect(draft.statusMessage == "Saved")
    }

    @Test(arguments: [false, true])
    func anUnchangedPersonalFieldStillRefusesAnExternallyChangedOrMissingFile(
        fileIsMissing: Bool
    ) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Synthetic source conflict", in: store)
        let file = try #require(note.fileURL)
        let original = try Data(contentsOf: file)
        let external = original + Data("\n".utf8)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = " \n"
        if fileIsMissing {
            try FileManager.default.removeItem(at: file)
        } else {
            try external.write(to: file)
        }

        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(draft.hasExactChanges)
        #expect(draft.text == " \n")
        if fileIsMissing {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } else {
            #expect(try Data(contentsOf: file) == external)
        }
    }

    @Test
    func anUnchangedPersonalFieldDoesNotAcceptAReplacementSymbolicLink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let note = try savedNote(title: "Synthetic replacement link", in: store)
        let file = try #require(note.fileURL)
        let original = try Data(contentsOf: file)
        let target = directory.appendingPathComponent("linked-copy.md")
        try original.write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        #expect(throws: MarkdownStoreError.unsafeSaveDestination) {
            try store.updatePersonalNotes(note.personalNotes, for: note)
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
    }

    @Test
    func aCanonicallyEquivalentPersonalEditStillWritesTheChosenUnicode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        var note = try savedNote(title: "Synthetic exact Unicode", in: store)
        note.personalNotes = "Review caf\u{00E9} decisions."
        note = try store.save(note)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        let proposed = "Review cafe\u{0301} decisions."
        #expect(note.personalNotes == proposed)
        #expect(!note.personalNotes.utf8.elementsEqual(proposed.utf8))
        draft.text = proposed

        #expect(draft.saveIfNeeded(store: store) == nil)
        let current = try #require(store.uniqueNote(id: note.id))
        #expect(current.personalNotes.utf8.elementsEqual(proposed.utf8))
        let file = try #require(note.fileURL)
        let markdown = try String(contentsOf: file, encoding: .utf8)
        let persisted = try #require(MarkdownCodec.decode(
            markdown
        ))
        #expect(persisted.personalNotes.utf8.elementsEqual(proposed.utf8))
        #expect(!draft.hasExactChanges)
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
    func wordsARefusedSaveCouldNotWriteNeverLandInAnotherNotesFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let first = try savedNote(title: "Launch review", in: store)
        let second = try savedNote(title: "Design sync", in: store)
        let third = try savedNote(title: "Hiring loop", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: first, store: store)
        draft.text = "Belongs to the launch review."

        // Something else wrote the file, so the store refuses this save.
        let firstFile = try #require(first.fileURL)
        let untouched = try externallyChangeSummary(at: firstFile)

        draft.prepare(for: second, store: store)

        // The field belongs to what is on screen, whatever the refusal did,
        // and the refusal is visible rather than silent.
        #expect(draft.noteID == second.id)
        #expect(draft.text.isEmpty)
        #expect(draft.statusMessage != nil)

        draft.text = "Belongs to the design sync."

        // Whatever the other writer was doing has settled, so a retry can go
        // through. It must go through against the note it was typed in.
        try untouched.write(to: firstFile, atomically: true, encoding: .utf8)
        draft.prepare(for: third, store: store)

        let launchReview = try String(contentsOf: firstFile, encoding: .utf8)
        #expect(launchReview.contains("Belongs to the launch review."))
        #expect(!launchReview.contains("Belongs to the design sync."))

        let designSync = try String(
            contentsOf: try #require(second.fileURL),
            encoding: .utf8
        )
        #expect(designSync.contains("Belongs to the design sync."))
        #expect(!designSync.contains("Belongs to the launch review."))
    }

    @Test
    func wordsARefusedSaveKeptComeBackWhenThatNoteIsOpenedAgain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let first = try savedNote(title: "Launch review", in: store)
        let second = try savedNote(title: "Design sync", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: first, store: store)
        draft.text = "The one line that matters."

        let firstFile = try #require(first.fileURL)
        _ = try externallyChangeSummary(at: firstFile)

        draft.prepare(for: second, store: store)
        #expect(draft.noteID == second.id)

        // Back where they were typed: the words are in the field again, not
        // quietly replaced by the older copy on disk.
        draft.prepare(for: first, store: store)
        #expect(draft.noteID == first.id)
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
        _ = try externallyChangeSummary(at: fileURL)

        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(draft.text == "Typed in Nook.")
    }

    @Test
    func hasUnwrittenNotesCountsAParkedDraftEvenWhenTheFieldOnScreenIsClean() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(in: directory)
        let first = try savedNote(title: "Launch review", in: store)
        let second = try savedNote(title: "Design sync", in: store)

        let draft = PersonalNotesDraftController()
        draft.prepare(for: first, store: store)
        draft.text = "Belongs to the launch review."

        // Something else wrote the file, so the store refuses this save and
        // the words are parked against `first` instead of lost.
        let firstFile = try #require(first.fileURL)
        let untouched = try externallyChangeSummary(at: firstFile)
        draft.prepare(for: second, store: store)

        // The field on screen is clean: it now belongs to `second`, and
        // nothing has been typed into it. `hasChanges` alone would say there
        // is nothing to do, but the parked words are still unwritten, which
        // is exactly what a leave-guard has to know about.
        #expect(!draft.hasChanges)
        #expect(draft.hasUnwrittenNotes)

        // Once the write can go through again, the parked draft stops
        // counting.
        try untouched.write(to: firstFile, atomically: true, encoding: .utf8)
        #expect(draft.saveIfNeeded(store: store) == nil)
        #expect(!draft.hasUnwrittenNotes)
    }

    @Test(arguments: [0.0, 0.25])
    func reloadingAnExternalEditNeverAuthorizesOverwritingItsPersonalNotes(
        timestampOffset: TimeInterval
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = reloadableStore(in: directory)
        let note = try savedNote(title: "External personal edit", in: store)
        store.reload()
        try await waitForReload(store)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "The words typed in Nook."
        let file = try #require(note.fileURL)
        let modified = try #require(note.fileModified)
        var external = note
        external.personalNotes = "The words written by another editor."
        let externalMarkdown = MarkdownCodec.encode(external)
        try externalMarkdown.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified.addingTimeInterval(timestampOffset)],
            ofItemAtPath: file.path
        )
        #expect(draft.saveIfNeeded(store: store) != nil)
        try await waitForReload(store)
        let refreshed = try #require(store.notes.first { $0.id == note.id })
        #expect(refreshed.personalNotes == external.personalNotes)
        draft.refresh(for: refreshed)
        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(draft.text == "The words typed in Nook.")
        #expect(draft.savedText == note.personalNotes)
        #expect(draft.hasChanges)
        #expect(try String(contentsOf: file, encoding: .utf8) == externalMarkdown)
    }

    @Test
    func parkedRetriesKeepTheirOriginalPersonalNotesBaselineAfterReload() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = reloadableStore(in: directory)
        let first = try savedNote(title: "First note", in: store)
        let second = try savedNote(title: "Second note", in: store)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: first, store: store)
        draft.text = "Keep this refused draft."
        let file = try #require(first.fileURL)
        var external = first
        external.personalNotes = "Keep this external edit too."
        let externalMarkdown = MarkdownCodec.encode(external)
        try externalMarkdown.write(to: file, atomically: true, encoding: .utf8)
        draft.prepare(for: second, store: store)
        try await waitForReload(store)
        #expect(draft.parkedDrafts.count == 1)
        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(draft.parkedDrafts.first?.text == "Keep this refused draft.")
        #expect(draft.parkedDrafts.first?.savedText == first.personalNotes)
        let refreshed = try #require(store.notes.first { $0.id == first.id })
        draft.prepare(for: refreshed, store: store)
        #expect(draft.text == "Keep this refused draft.")
        #expect(draft.savedText == first.personalNotes)
        #expect(draft.saveIfNeeded(store: store) != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == externalMarkdown)
        #expect(store.notes.first { $0.id == second.id }?.personalNotes == "")
    }

    @Test
    func refreshedUnrelatedFieldsSurviveSavingTheOriginalPersonalDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = reloadableStore(in: directory)
        let note = try savedNote(title: "Unrelated edit", in: store)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "The personal addition."
        let file = try #require(note.fileURL)
        _ = try externallyChangeSummary(at: file)
        #expect(draft.saveIfNeeded(store: store) != nil)
        try await waitForReload(store)
        #expect(draft.saveIfNeeded(store: store) == nil)
        let saved = try #require(store.notes.first { $0.id == note.id })
        #expect(saved.summary == "Another editor changed the launch scope.")
        #expect(saved.personalNotes == "The personal addition.")
        #expect(!draft.hasChanges)
    }

    @Test
    func explicitlyMatchingTheExternalPersonalNotesResolvesTheDraft() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = reloadableStore(in: directory)
        let note = try savedNote(title: "Resolved edit", in: store)
        let draft = PersonalNotesDraftController()
        draft.prepare(for: note, store: store)
        draft.text = "The draft before comparison."
        let file = try #require(note.fileURL)
        var external = note
        external.personalNotes = "The wording chosen after comparison."
        try MarkdownCodec.encode(external).write(to: file, atomically: true, encoding: .utf8)
        #expect(draft.saveIfNeeded(store: store) != nil)
        try await waitForReload(store)
        draft.text = external.personalNotes
        #expect(draft.saveIfNeeded(store: store) == nil)
        #expect(!draft.hasChanges)
        #expect(draft.text == external.personalNotes)
    }
}
