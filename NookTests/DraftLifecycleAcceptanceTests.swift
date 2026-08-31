import Foundation
import Testing
@testable import Nook

/// Exercises the actual editor/store boundaries with synthetic files. These do
/// not drive windows, microphone permissions, or the developer's real Trash.
@MainActor
struct DraftLifecycleAcceptanceTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookDraftLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func store(in directory: URL, fileManager: FileManager = .default) -> MarkdownStore {
        let store = MarkdownStore(fileManager: fileManager, noteLoader: { _, cache in
            MarkdownStore.loadNotes(in: directory, cache: cache)
        })
        store.storageURL = directory
        return store
    }

    /// Directory enumeration returns /private/var for temporary files whose
    /// constructed URL uses /var. The store standardizes both spellings too.
    private func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL == rhs?.standardizedFileURL
    }

    private func savedNote(in store: MarkdownStore, title: String = "Synthetic acceptance") throws -> MeetingNote {
        try store.save(MeetingNote(
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_060),
            sourceApp: "Manual",
            summary: "Original summary.",
            personalNotes: "Original personal notes."
        ))
    }

    private func reload(_ store: MarkdownStore) async throws {
        store.reload()
        for _ in 0..<100 where store.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isLoading)
    }

    private func recovered(after journal: DraftJournal) async -> [DraftCheckpoint] {
        await journal.flush()
        let restarted = DraftJournal(directoryURL: journal.directoryURL)
        await restarted.scan()
        return restarted.recoveredDrafts
    }

    @Test(arguments: [false, true])
    func ordinarySavesWorkWithoutRecoveryAndWhenRecoveryWritesFail(failingJournal: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let journal: DraftJournal? = failingJournal
            ? DraftJournal(directoryURL: root.appendingPathComponent("Drafts"), beforeFileOperation: { operation, _ in
                if case .write = operation { throw LifecycleFailure.unavailable }
            })
            : nil
        let personalNote = try savedNote(in: store, title: "Personal save")
        let rawNote = try savedNote(in: store, title: "Raw save")
        let personal = PersonalNotesDraftController(recovery: journal)
        let raw = MarkdownDraftController(recovery: journal)
        let quick = QuickNoteController(store: store, recovery: journal)
        personal.prepare(for: personalNote, store: store)
        raw.prepare(for: rawNote, store: store)
        personal.text = "Personal words saved on quit."
        raw.rawMarkdown += "\nRaw words saved explicitly.\n"
        quick.text = "Quick words saved on quit."

        #expect(personal.saveIfNeeded(store: store) == nil)
        try raw.save(note: rawNote, store: store)
        #expect(quick.saveForTermination() == nil)
        #expect(!personal.hasUnwrittenNotes)
        #expect(!raw.hasChanges)
        #expect(!quick.hasUnsavedFailure)
        #expect(try store.rawMarkdown(for: personalNote).contains("Personal words saved on quit."))
        #expect(try store.rawMarkdown(for: rawNote).contains("Raw words saved explicitly."))
        #expect(store.notes.contains { $0.summary == "Quick words saved on quit." })
        await journal?.flush()
    }

    @Test
    func changingARawNotesIdentityCannotReplaceAnotherLibraryEntry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let first = try savedNote(in: store, title: "First owner")
        let second = try savedNote(in: store, title: "Second owner")
        let firstFile = try #require(first.fileURL)
        let secondFile = try #require(second.fileURL)
        let firstBytes = try Data(contentsOf: firstFile)
        let secondBytes = try Data(contentsOf: secondFile)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let raw = MarkdownDraftController(recovery: journal)
        raw.prepare(for: first, store: store)
        raw.rawMarkdown = raw.rawMarkdown.replacingOccurrences(
            of: "id: \(first.id.uuidString)", with: "id: \(second.id.uuidString)"
        )
        let edited = raw.rawMarkdown

        #expect(throws: MarkdownStoreError.noteIdentityChanged) {
            try raw.save(note: first, store: store)
        }
        #expect(raw.hasChanges)
        #expect(raw.rawMarkdown == edited)
        #expect(try Data(contentsOf: firstFile) == firstBytes)
        #expect(try Data(contentsOf: secondFile) == secondBytes)
        #expect(sameFile(store.notes.first { $0.id == first.id }?.fileURL, firstFile))
        #expect(sameFile(store.notes.first { $0.id == second.id }?.fileURL, secondFile))
        let checkpoint = try #require(await recovered(after: journal).first)
        #expect(checkpoint.text == edited)
        #expect(checkpoint.noteID == first.id)
        #expect(checkpoint.originalFilePath == firstFile.resolvingSymlinksInPath().path)
        #expect(checkpoint.completion == nil)
    }

    @Test
    func rawSourceRecoveryAndSaveNoticeCanonicallyEquivalentByteChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try store.save(MeetingNote(
            title: "Unicode raw source", startedAt: Date(), endedAt: Date(),
            sourceApp: "Manual", summary: "Caf\u{e9}"
        ))
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let raw = MarkdownDraftController(recovery: journal)
        raw.prepare(for: note, store: store)
        let composed = raw.originalMarkdown
        let decomposed = composed.replacingOccurrences(of: "\u{e9}", with: "e\u{301}")
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        raw.rawMarkdown = decomposed

        #expect(raw.hasChanges)
        let checkpoint = try #require(await recovered(after: journal).first)
        #expect(checkpoint.text.utf8.elementsEqual(decomposed.utf8))
        #expect(checkpoint.baseline.utf8.elementsEqual(composed.utf8))
        try raw.save(note: note, store: store)
        #expect(try Data(contentsOf: #require(note.fileURL)) == Data(decomposed.utf8))
        #expect(!raw.hasChanges)
        #expect(await recovered(after: journal).isEmpty)
    }

    @Test
    func personalRecoveryKeepsCanonicalEncodingChangesUntilQuitSavesThem() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try store.save(MeetingNote(
            title: "Unicode personal draft", startedAt: Date(), endedAt: Date(),
            sourceApp: "Manual", summary: "Original summary.", personalNotes: "Caf\u{e9}"
        ))
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        let decomposed = "Cafe\u{301}"
        personal.text = decomposed

        // The familiar normalized indicator remains semantic, but recovery
        // and the quit boundary owe the user the exact encoding they typed.
        #expect(!personal.hasChanges)
        #expect(personal.hasUnwrittenNotes)
        let checkpoint = try #require(await recovered(after: journal).first)
        #expect(checkpoint.text.utf8.elementsEqual(decomposed.utf8))
        #expect(checkpoint.baseline.utf8.elementsEqual(note.personalNotes.utf8))
        #expect(personal.saveIfNeeded(store: store) == nil)
        let saved = try #require(store.notes.first { $0.id == note.id })
        #expect(saved.personalNotes.utf8.elementsEqual(decomposed.utf8))
        #expect(!personal.hasUnwrittenNotes)
        #expect(await recovered(after: journal).isEmpty)
    }

    @Test
    func ambiguousDuplicateUUIDsRefuseEditorSavesWithoutTouchingEitherFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let original = try savedNote(in: store)
        let originalFile = try #require(original.fileURL)
        let bytes = try Data(contentsOf: originalFile)
        let copyFile = root.appendingPathComponent("Copied identity.md")
        try bytes.write(to: copyFile)
        try await reload(store)
        #expect(store.notes.filter { $0.id == original.id }.count == 2)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let raw = MarkdownDraftController(recovery: journal)
        personal.prepare(for: original, store: store)
        raw.prepare(for: original, store: store)
        personal.text = "Keep the ambiguous personal draft."
        raw.rawMarkdown += "\nKeep the ambiguous raw draft.\n"

        #expect(personal.saveIfNeeded(store: store) != nil)
        #expect(throws: EditorDraftOwnershipError.self) {
            try raw.save(note: original, store: store)
        }
        #expect(try Data(contentsOf: originalFile) == bytes)
        #expect(try Data(contentsOf: copyFile) == bytes)
        #expect(await recovered(after: journal).count == 2)
    }

    @Test
    func returningToTheOriginalNamedLibrarySavesTheQuickDraftOnlyThere() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstLibrary = root.appendingPathComponent("Research notes", isDirectory: true)
        let secondLibrary = root.appendingPathComponent("Copied research notes", isDirectory: true)
        try FileManager.default.createDirectory(at: firstLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondLibrary, withIntermediateDirectories: true)
        let store = store(in: firstLibrary)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let quick = QuickNoteController(store: store, recovery: journal)
        store.onStorageDirectoryWillChange = { quick.libraryWillChange() }
        quick.text = "The first saved version."
        let saved = try #require(quick.saveIfNeeded())
        let file = try #require(saved.fileURL)
        let originalBytes = try Data(contentsOf: file)
        let copiedFile = secondLibrary.appendingPathComponent(file.lastPathComponent)
        try originalBytes.write(to: copiedFile)
        quick.text = "The later draft still belongs to Research notes."
        store.storageURL = secondLibrary
        #expect(quick.saveForTermination() != nil)
        #expect(try Data(contentsOf: copiedFile) == originalBytes)
        store.storageURL = firstLibrary

        #expect(quick.saveForTermination() == nil)
        #expect(!quick.hasUnsavedFailure)
        #expect(try store.rawMarkdown(for: saved).contains("The later draft still belongs to Research notes."))
        #expect(try Data(contentsOf: copiedFile) == originalBytes)
        #expect(await recovered(after: journal).isEmpty)
    }

    @Test
    func externallyRenamedSourcesNeverReceiveAnOldEditorsSave() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let note = try savedNote(in: store)
        let originalFile = try #require(note.fileURL)
        let bytes = try Data(contentsOf: originalFile)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let raw = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        raw.prepare(for: note, store: store)
        personal.text = "Words owned by the former path."
        raw.rawMarkdown += "\nRaw words owned by the former path.\n"
        let renamedFile = root.appendingPathComponent("Renamed outside Nook.md")
        try FileManager.default.moveItem(at: originalFile, to: renamedFile)
        try await reload(store)
        let renamed = try #require(store.notes.first { sameFile($0.fileURL, renamedFile) })
        personal.refresh(for: renamed)
        raw.refresh(for: renamed, store: store)

        #expect(personal.saveIfNeeded(store: store) != nil)
        #expect(throws: MarkdownDraftError.wrongNote) { try raw.save(note: renamed, store: store) }
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        #expect(try Data(contentsOf: renamedFile) == bytes)
        let checkpoints = await recovered(after: journal)
        #expect(checkpoints.count == 2)
        #expect(checkpoints.allSatisfy {
            $0.originalFilePath == originalFile.resolvingSymlinksInPath().path
        })
    }

    @Test
    func deletingOneDuplicateLeavesTheOtherFileAndItsDraftOwnedByThatFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root, fileManager: LifecycleTrashFileManager())
        let original = try savedNote(in: store)
        let originalFile = try #require(original.fileURL)
        let bytes = try Data(contentsOf: originalFile)
        let copyFile = root.appendingPathComponent("Delete only this copy.md")
        try bytes.write(to: copyFile)
        try await reload(store)
        let copied = try #require(store.notes.first { sameFile($0.fileURL, copyFile) })
        let personal = PersonalNotesDraftController()
        personal.prepare(for: original, store: store)
        personal.text = "The original still owns this edit."
        store.onNoteDeleted = { personal.noteWasDeleted($0) }

        #expect(store.delete(copied))
        #expect(!FileManager.default.fileExists(atPath: copyFile.path))
        #expect(store.notes.contains { $0.id == original.id && sameFile($0.fileURL, originalFile) })
        #expect(personal.text == "The original still owns this edit.")
        #expect(personal.saveIfNeeded(store: store) == nil)
        #expect(try store.rawMarkdown(for: original).contains("The original still owns this edit."))
    }

    @Test
    func anExplicitManagedRenameRepreparesBothEditorsAfterSavingTheirPendingWords() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        var note = try savedNote(in: store, title: "Original filename")
        let originalFile = try #require(note.fileURL)
        note.title = "Deliberately renamed file"
        note = try store.save(note)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"))
        let personal = PersonalNotesDraftController(recovery: journal)
        let raw = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        raw.prepare(for: note, store: store)
        personal.text = "Save these pending words before moving their original."

        // A managed rename is an explicit boundary. Saving first makes the
        // subsequent prepare a clean context change, never migration of an
        // unfinished edit onto a guessed path.
        let beforeRename = try personal.save(note: note, store: store)
        let renamed = try store.renameManagedFile(for: beforeRename)
        let renamedFile = try #require(renamed.fileURL)
        #expect(renamedFile != originalFile)
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        #expect(store.notes.filter { $0.id == renamed.id }.count == 1)
        #expect(sameFile(store.notes.first { $0.id == renamed.id }?.fileURL, renamedFile))
        personal.prepare(for: renamed, store: store)
        raw.prepare(for: renamed, store: store)
        #expect(personal.text == "Save these pending words before moving their original.")
        #expect(raw.rawMarkdown.contains(personal.text))
        #expect(!personal.hasUnwrittenNotes)
        #expect(!raw.hasChanges)

        personal.text = "The next personal edit belongs to the renamed file."
        let savedPersonal = try personal.save(note: renamed, store: store)
        raw.refresh(for: savedPersonal, store: store)
        raw.rawMarkdown += "\n## Additional context\n\nThe raw edit belongs here too.\n"
        try raw.save(note: savedPersonal, store: store)
        let source = try String(contentsOf: renamedFile, encoding: .utf8)
        #expect(source.contains("The next personal edit belongs to the renamed file."))
        #expect(source.contains("The raw edit belongs here too."))
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        #expect(await recovered(after: journal).isEmpty)
    }

    @Test(arguments: [false, true])
    func savingEitherDuplicateUUIDFileKeepsBothDistinctLibraryEntries(copyFirst: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let original = try savedNote(in: store, title: "Original duplicate identity")
        let originalFile = try #require(original.fileURL)
        let copyFile = root.appendingPathComponent("Separate duplicate identity.md")
        try Data(contentsOf: originalFile).write(to: copyFile)
        try await reload(store)
        let destinations = copyFirst ? [copyFile, originalFile] : [originalFile, copyFile]

        for destination in destinations {
            var target = try #require(store.notes.first { sameFile($0.fileURL, destination) })
            target.summary = destination == originalFile
                ? "Content belonging only to the original file."
                : "Content belonging only to the copied file."
            let saved = try store.save(target)
            #expect(sameFile(saved.fileURL, destination))
            #expect(store.notes.filter { $0.id == original.id }.count == 2)
            #expect(Set(store.notes.compactMap { $0.fileURL?.standardizedFileURL })
                == [originalFile.standardizedFileURL, copyFile.standardizedFileURL])
        }

        let originalEntry = try #require(store.notes.first { sameFile($0.fileURL, originalFile) })
        let copiedEntry = try #require(store.notes.first { sameFile($0.fileURL, copyFile) })
        #expect(originalEntry.summary == "Content belonging only to the original file.")
        #expect(copiedEntry.summary == "Content belonging only to the copied file.")
        #expect(try Data(contentsOf: originalFile) == Data(MarkdownCodec.encode(originalEntry).utf8))
        #expect(try Data(contentsOf: copyFile) == Data(MarkdownCodec.encode(copiedEntry).utf8))
        #expect(originalEntry.id == copiedEntry.id)
        #expect(!sameFile(originalEntry.fileURL, copiedEntry.fileURL))
    }

    @Test
    func anUnaddressedDuplicateUUIDSaveRefusesToGuessEitherDestination() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root)
        let original = try savedNote(in: store)
        let originalFile = try #require(original.fileURL)
        let originalBytes = try Data(contentsOf: originalFile)
        let copiedFile = root.appendingPathComponent("Other file with the same identity.md")
        try originalBytes.write(to: copiedFile)
        try await reload(store)
        var unaddressed = original
        unaddressed.fileURL = nil
        unaddressed.summary = "No destination was selected for these words."

        #expect(throws: MarkdownStoreError.ambiguousNoteIdentity) {
            try store.save(unaddressed)
        }
        #expect(store.notes.filter { $0.id == original.id }.count == 2)
        let visibleFiles = Set(store.notes.compactMap { $0.fileURL?.standardizedFileURL })
        #expect(visibleFiles == [originalFile.standardizedFileURL, copiedFile.standardizedFileURL])
        #expect(try Data(contentsOf: originalFile) == originalBytes)
        #expect(try Data(contentsOf: copiedFile) == originalBytes)
    }

    @Test
    func failedRecoveryCleanupAfterDeletionCannotRecreateTheOriginalOnQuit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store(in: root, fileManager: LifecycleTrashFileManager())
        let note = try savedNote(in: store)
        let file = try #require(note.fileURL)
        let journal = DraftJournal(directoryURL: root.appendingPathComponent("Drafts"), beforeFileOperation: { operation, _ in
            if case .remove = operation { throw LifecycleFailure.unavailable }
        })
        let personal = PersonalNotesDraftController(recovery: journal)
        let raw = MarkdownDraftController(recovery: journal)
        personal.prepare(for: note, store: store)
        raw.prepare(for: note, store: store)
        personal.text = "Personal recovery copy awaiting cleanup."
        raw.rawMarkdown += "\nRaw recovery copy awaiting cleanup.\n"
        journal.flushSynchronously()
        store.onNoteDeleted = { deleted in
            personal.noteWasDeleted(deleted)
            raw.noteWasDeleted(deleted)
        }

        #expect(store.delete(note))
        #expect(personal.noteID == nil)
        #expect(raw.noteID == nil)
        #expect(personal.saveIfNeeded(store: store) == nil)
        #expect(!raw.hasChanges)
        let checkpoints = await recovered(after: journal)
        #expect(checkpoints.count == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.notes.isEmpty)
    }
}

private enum LifecycleFailure: Error {
    case unavailable
}

private final class LifecycleTrashFileManager: FileManager {
    override func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try removeItem(at: url)
    }
}
