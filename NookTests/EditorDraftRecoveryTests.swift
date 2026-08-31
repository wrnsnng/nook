import Foundation
import Testing
@testable import Nook

@MainActor
struct EditorDraftRecoveryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookEditorRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(in directory: URL) -> MarkdownStore {
        let store = MarkdownStore(noteLoader: { _, _ in
            .success((notes: [], issues: []))
        })
        store.storageURL = directory
        return store
    }

    private func savedNote(in store: MarkdownStore, title: String = "Synthetic review") throws -> MeetingNote {
        try store.save(MeetingNote(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Manual",
            summary: "The original summary.",
            personalNotes: "The original personal notes."
        ))
    }

    private func records(after journal: DraftJournal) async -> [DraftCheckpoint] {
        journal.flushSynchronously()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await Task.yield()
        await restarted.scan()
        return restarted.recoveredDrafts
    }

    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @Test(arguments: ["", "  Café 👩🏽‍💻\nA deliberately unfinished line\n\n"])
    func personalRecoveryKeepsExactReplacementAndOriginalBaseline(text: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = PersonalNotesDraftController(recovery: journal)
        draft.prepare(for: note, store: store)
        draft.text = text
        draft.libraryWillChange()

        let recovered = try #require(await records(after: journal).first)
        #expect(recovered.kind == .personalNotes)
        #expect(recovered.text == text)
        #expect(recovered.baseline == note.personalNotes)
        #expect(recovered.baselineRevision == note.fileRevision)
        #expect(recovered.libraryPath == canonical(root))
        #expect(recovered.originalFilePath == canonical(try #require(note.fileURL)))
        #expect(journal.recoveredDrafts.isEmpty)
    }

    @Test
    func restartingNeverReplaysPersonalOrRawRecoveryIntoAnOriginal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let file = try #require(note.fileURL)
        let originalBytes = try Data(contentsOf: file)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let markdown = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        markdown.prepare(for: note, store: store)
        personal.text = "Recovered words are not an automatic save."
        let raw = markdown.rawMarkdown.replacingOccurrences(
            of: "title:", with: "custom-metadata: untouched\ntitle:"
        ) + "\n## Unknown section\n\nPreserve  spaces\tand Unicode: 雪.\n"
        markdown.rawMarkdown = raw
        journal.flushSynchronously()

        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await Task.yield()
        await restarted.scan()
        #expect(restarted.recoveredDrafts.count == 2)
        let recoveredRaw = try #require(restarted.recoveredDrafts.first { $0.kind == .markdown })
        #expect(recoveredRaw.text == raw)
        #expect(recoveredRaw.baseline == String(data: originalBytes, encoding: .utf8))
        #expect(recoveredRaw.baselineRevision == MeetingNote.contentRevision(originalBytes))

        let newPersonal = PersonalNotesDraftController(recovery: restarted)
        let newMarkdown = MarkdownDraftController(recovery: restarted)
        newPersonal.prepare(for: note, store: store)
        newMarkdown.prepare(for: note, store: store)
        #expect(newPersonal.text == note.personalNotes)
        #expect(newPersonal.parkedDrafts.isEmpty)
        #expect(!newMarkdown.hasChanges)
        #expect(newPersonal.saveIfNeeded(store: store) == nil)
        restarted.flushSynchronously()
        #expect(try Data(contentsOf: file) == originalBytes)
        #expect(restarted.recoveredDrafts.count == 2)
    }

    @Test
    func parkedPersonalDraftsKeepTheirIdentityAndExactTextAcrossRestoration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let first = try savedNote(in: store, title: "First")
        let second = try savedNote(in: store, title: "Second")
        let third = try savedNote(in: store, title: "Third")
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = PersonalNotesDraftController(recovery: journal)
        draft.prepare(for: first, store: store)
        let exact = "\n  Keep every character in this draft.\n"
        draft.text = exact
        let initial = try #require(await records(after: journal).first)
        let firstFile = try #require(first.fileURL)
        let external = MarkdownCodec.encode(first) + "\nExternal first edit.\n"
        try external.write(to: firstFile, atomically: true, encoding: .utf8)
        draft.prepare(for: second, store: store)
        draft.text = "Second refused draft."
        let secondFile = try #require(second.fileURL)
        try (MarkdownCodec.encode(second) + "\nExternal second edit.\n")
            .write(to: secondFile, atomically: true, encoding: .utf8)
        draft.prepare(for: third, store: store)
        draft.text = "Third live draft."

        #expect(draft.parkedDrafts.count == 2)
        let checkpoints = await records(after: journal)
        #expect(checkpoints.count == 3)
        #expect(checkpoints.first { $0.noteID == first.id }?.id == initial.id)
        #expect(checkpoints.first { $0.noteID == first.id }?.text == exact)
        draft.prepare(for: first, store: store)
        #expect(draft.text == exact)
        #expect(draft.savedText == first.personalNotes)
        draft.text += "Still this draft."
        let restored = try #require(await records(after: journal).first { $0.noteID == first.id })
        #expect(restored.id == initial.id)
        #expect(restored.createdAt == initial.createdAt)
        #expect(restored.baseline == first.personalNotes)
        #expect(try String(contentsOf: firstFile, encoding: .utf8) == external)
    }

    @Test
    func copiedLibraryUUIDDoesNotRedirectAPersonalSaveOrParkedRetry() async throws {
        let root = try directory()
        let copiedRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: copiedRoot)
        }
        let originalStore = store(in: root)
        let original = try savedNote(in: originalStore)
        let file = try #require(original.fileURL)
        let bytes = try Data(contentsOf: file)
        let copiedFile = copiedRoot.appendingPathComponent(file.lastPathComponent)
        try bytes.write(to: copiedFile)
        let copiedStore = store(in: copiedRoot)
        let copied = try #require(MarkdownCodec.decode(
            String(decoding: bytes, as: UTF8.self), fileURL: copiedFile
        ))
        _ = try copiedStore.save(copied)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = PersonalNotesDraftController(recovery: journal)
        draft.prepare(for: original, store: originalStore)
        draft.text = "Only belongs to the original library."
        draft.libraryWillChange()
        #expect(throws: EditorDraftOwnershipError.self) {
            try draft.save(note: copied, store: copiedStore)
        }
        draft.prepare(for: copied, store: copiedStore)
        #expect(draft.text == copied.personalNotes)
        #expect(draft.parkedDrafts.count == 1)
        draft.text = "Only belongs to the copied library."
        let checkpoints = await records(after: journal)
        #expect(checkpoints.count == 2)
        #expect(Set(checkpoints.map(\.id)).count == 2)
        #expect(Set(checkpoints.map(\.libraryPath)) == [canonical(root), canonical(copiedRoot)])
        #expect(draft.saveIfNeeded(store: copiedStore) != nil)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try String(contentsOf: copiedFile, encoding: .utf8)
            .contains("Only belongs to the copied library."))
        #expect(!String(decoding: try Data(contentsOf: copiedFile), as: UTF8.self)
            .contains("Only belongs to the original library."))
    }

    @Test
    func copiedLibraryUUIDCannotTakeOwnershipOfAMarkdownDraft() async throws {
        let root = try directory()
        let copiedRoot = try directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: copiedRoot)
        }
        let originalStore = store(in: root)
        let original = try savedNote(in: originalStore)
        let originalFile = try #require(original.fileURL)
        let bytes = try Data(contentsOf: originalFile)
        let copiedFile = copiedRoot.appendingPathComponent(originalFile.lastPathComponent)
        try bytes.write(to: copiedFile)
        let copiedStore = store(in: copiedRoot)
        let copied = try #require(MarkdownCodec.decode(String(decoding: bytes, as: UTF8.self), fileURL: copiedFile))
        _ = try copiedStore.save(copied)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = MarkdownDraftController(recovery: journal)
        draft.prepare(for: original, store: originalStore)
        draft.rawMarkdown += "\nOriginal library only.\n"
        let edited = draft.rawMarkdown
        draft.libraryWillChange()
        draft.prepare(for: copied, store: copiedStore)
        draft.refresh(for: copied, store: copiedStore)
        #expect(draft.rawMarkdown == edited)
        #expect(throws: MarkdownDraftError.wrongNote) {
            try draft.save(note: copied, store: copiedStore)
        }
        #expect(throws: EditorDraftOwnershipError.self) {
            try draft.save(note: original, store: copiedStore)
        }
        #expect(try Data(contentsOf: originalFile) == bytes)
        #expect(try Data(contentsOf: copiedFile) == bytes)
        let recovered = try #require(await records(after: journal).first)
        #expect(recovered.libraryPath == canonical(root))
        #expect(recovered.text == edited)
    }

    @Test
    func externallyDeletedOriginalsStayDeletedWhileBothRecoveryCopiesSurvive() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let file = try #require(note.fileURL)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let markdown = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        markdown.prepare(for: note, store: store)
        personal.text = "Keep the personal edit."
        markdown.rawMarkdown += "\nKeep the raw edit.\n"
        try FileManager.default.removeItem(at: file)
        #expect(personal.saveIfNeeded(store: store) != nil)
        #expect(throws: (any Error).self) { try markdown.save(note: note, store: store) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await records(after: journal).count == 2)
    }

    @Test
    func savesAndDiscardsInvalidatePendingCheckpointsBeforeTheyCanReturn() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        var note = try savedNote(in: store)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let markdown = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        personal.text = "Save this personal edit."
        note = try personal.save(note: note, store: store)
        markdown.prepare(for: note, store: store)
        markdown.rawMarkdown += "\nSave this raw edit.\n"
        try markdown.save(note: note, store: store)
        #expect(await records(after: journal).isEmpty)
        personal.text = "Discard this personal edit."
        markdown.rawMarkdown += "\nDiscard this raw edit.\n"
        personal.discardChanges()
        markdown.discardChanges()
        #expect(await records(after: journal).isEmpty)
        #expect(!personal.hasChanges)
        #expect(!markdown.hasChanges)
    }

    @Test
    func anUnchangedPersonalSaveReconcilesItsOriginalBytesAfterCleanupFails() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        var note = try savedNote(in: store)
        let source = MarkdownCodec.encode(note) + "\n"
        try store.saveRawMarkdown(source, for: note)
        note = try #require(store.uniqueNote(id: note.id))
        let file = try #require(note.fileURL)
        let journal = DraftJournal(
            directoryURL: root.appendingPathComponent("Drafts"),
            beforeFileOperation: { operation, _ in
                if operation == .remove { throw CocoaError(.fileWriteNoPermission) }
            }
        )
        let personal = PersonalNotesDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        personal.text += "\n"
        #expect(personal.saveIfNeeded(store: store) == nil)
        journal.flushSynchronously()

        // Leave the intent on disk, as after a successful save whose cleanup
        // could not finish. A new session must not offer that settled draft
        // as another note just because its original file has a final newline.
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        #expect(recovered.completion?.revision == note.fileRevision)
        #expect(try Data(contentsOf: file) == Data(source.utf8))
        let controller = DraftRecoveryController(journal: restarted, store: store)
        await controller.reconcileCompletedDrafts()

        #expect(restarted.recoveredDrafts.isEmpty)
        #expect(try Data(contentsOf: file) == Data(source.utf8))
        #expect(store.notes.count == 1)
    }

    @Test
    func editingAgainAfterSaveUsesANewDraftAndTheSavedBaseline() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = PersonalNotesDraftController(recovery: journal)
        draft.prepare(for: note, store: store)
        draft.text = "First saved wording."
        let before = try #require(await records(after: journal).first)
        let saved = try draft.save(note: note, store: store)
        draft.text = "Next unfinished wording."
        let after = try #require(await records(after: journal).first)
        #expect(after.id != before.id)
        #expect(after.baseline == saved.personalNotes)
        #expect(after.baselineRevision == saved.fileRevision)
        #expect(after.text == "Next unfinished wording.")
    }

    @Test
    func successfulDeletionInvalidatesOnlyDraftsForThatOriginalFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let first = try savedNote(in: store, title: "Delete this one")
        let second = try savedNote(in: store, title: "Keep this one")
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let markdown = MarkdownDraftController(recovery: journal)
        personal.prepare(for: first, store: store)
        personal.text = "First parked edit."
        let firstFile = try #require(first.fileURL)
        try (MarkdownCodec.encode(first) + "\nExternal edit.\n")
            .write(to: firstFile, atomically: true, encoding: .utf8)
        personal.prepare(for: second, store: store)
        personal.text = "Second live edit."
        markdown.prepare(for: first, store: store)
        markdown.rawMarkdown += "\nFirst raw edit.\n"
        try FileManager.default.removeItem(at: firstFile)
        personal.noteWasDeleted(first)
        markdown.noteWasDeleted(first)
        #expect(personal.parkedDrafts.isEmpty)
        #expect(personal.text == "Second live edit.")
        #expect(markdown.noteID == nil)
        let recovered = await records(after: journal)
        #expect(recovered.count == 1)
        #expect(recovered.first?.noteID == second.id)
    }

    @Test
    func returningExactlyToTheBaselineInvalidatesOnlyThatEditingTransaction() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let draft = MarkdownDraftController(recovery: journal)
        draft.prepare(for: note, store: store)
        draft.rawMarkdown += "\nUndo this edit.\n"
        let old = try #require(await records(after: journal).first)
        draft.rawMarkdown = draft.originalMarkdown
        #expect(await records(after: journal).isEmpty)
        draft.rawMarkdown += "\nA new edit after undo.\n"
        let new = try #require(await records(after: journal).first)
        #expect(new.id != old.id)
        #expect(new.text.contains("A new edit after undo."))
    }
}
