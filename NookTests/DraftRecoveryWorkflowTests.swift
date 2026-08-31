import Darwin
import Foundation
import Synchronization
import Testing
@testable import Nook

@MainActor
struct DraftRecoveryWorkflowTests {
    private struct Fixture {
        let root: URL
        let library: URL
        let journal: DraftJournal
        let store: MarkdownStore
        let controller: DraftRecoveryController
    }

    private func fixture(
        beforeFileOperation: @escaping @Sendable (DraftJournalFileOperation, URL) throws -> Void = { _, _ in },
        trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookDraftRecovery-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let library = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let journal = DraftJournal(
            directoryURL: root.appendingPathComponent("Drafts", isDirectory: true),
            beforeFileOperation: beforeFileOperation,
            trashItem: trashItem
        )
        let store = MarkdownStore(noteLoader: { _, _ in .success((notes: [], issues: [])) })
        store.storageURL = library
        let controller = DraftRecoveryController(journal: journal, store: store)
        return Fixture(root: root, library: library, journal: journal, store: store, controller: controller)
    }

    private func checkpoint(in fixture: Fixture, kind: DraftEditorKind = .personalNotes, text: String) -> DraftCheckpoint {
        DraftCheckpoint(
            kind: kind,
            libraryPath: fixture.library.path,
            originalFilePath: fixture.library.appendingPathComponent("Original.md").path,
            noteID: UUID(),
            title: "Synthetic recovery",
            text: text,
            baseline: "Original words",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            checkpointedAt: Date(timeIntervalSince1970: 1_800_000_060)
        )
    }

    private func note(id: UUID = UUID()) -> MeetingNote {
        MeetingNote(
            id: id,
            kind: .spoken,
            title: "Synthetic source",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            sourceApp: "Synthetic",
            summary: "Original writing"
        )
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    @Test
    func savingRecoveredWritingUsesANewIdentityAndKeepsExactSourceWhitespace() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = " \n\tUnicode café 👩🏽‍💻\n## My custom heading\n  last line\t\n\n"
        let draft = checkpoint(in: f, text: source)
        let original = URL(fileURLWithPath: try #require(draft.originalFilePath))
        let originalBytes = Data("Externally changed original, including same timestamp.".utf8)
        try originalBytes.write(to: original)
        try await f.journal.persistNow(draft)

        let destination = try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

        let bytes = try Data(contentsOf: destination)
        let saved = try #require(MarkdownCodec.decode(String(decoding: bytes, as: UTF8.self)))
        #expect(saved.id != draft.noteID)
        #expect(destination != original)
        #expect(bytes.suffix(Data(source.utf8).count) == Data(source.utf8))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func anIntentionallyEmptyReplacementCanBeRecoveredAsANewNote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "")
        try await f.journal.persistNow(draft)

        let destination = try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

        let saved = try #require(MarkdownCodec.decode(String(contentsOf: destination, encoding: .utf8)))
        #expect(saved.summary.isEmpty)
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func rawMarkdownCloningChangesOnlyItsSingleIdentityToken() throws {
        let originalID = UUID()
        let newID = UUID()
        let source = MarkdownCodec.encode(note(id: originalID))
            .replacingOccurrences(of: "title:", with: "private-field: {keep: this}\ntitle:")
            + "\n\n## Unknown section\n  \(originalID.uuidString)  \n\t"

        let cloned = try DraftRecoveryController.cloneMarkdown(source, id: newID)
        let expected = source.replacingOccurrences(of: "id: \(originalID.uuidString)\n", with: "id: \(newID.uuidString)\n")

        #expect(Data(cloned.utf8) == Data(expected.utf8))
        #expect(cloned.hasSuffix("\n\n## Unknown section\n  \(originalID.uuidString)  \n\t"))
    }

    @Test
    func malformedOrAmbiguousMarkdownStaysAvailableForExactExport() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let valid = MarkdownCodec.encode(note())
        let sources = [
            "## Unfinished source without frontmatter\n",
            valid.replacingOccurrences(of: "kind: spoken", with: "id: \(UUID().uuidString)\nkind: spoken"),
            valid.replacingOccurrences(of: "\nid: ", with: "\n  id: "),
            valid.replacingOccurrences(of: "\n", with: "\r\n"),
            "---\n" + valid
        ]
        for source in sources {
            let draft = checkpoint(in: f, kind: .markdown, text: source)
            try await f.journal.persistNow(draft)
            #expect(!DraftRecoveryController.canSaveAsNewNote(draft))
            await #expect(throws: DraftRecoveryError.markdownIdentityAmbiguous) {
                try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
            }
            let exported = f.root.appendingPathComponent("\(draft.id.uuidString).txt")
            try await f.controller.exportSource(draftID: draft.id, to: exported)
            #expect(try Data(contentsOf: exported) == Data(source.utf8))
            #expect(f.journal.recoveredDrafts.contains { $0.id == draft.id })
        }
        #expect(try markdownFiles(in: f.library).isEmpty)
    }

    @Test
    func completedRecoveryIsRecognizedAfterRestartWithoutDuplicatingTheNote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "Recovered words")
        let id = UUID()
        let destination = f.library.appendingPathComponent("Saved-before-crash.md")
        let bytes = Data(try DraftRecoveryController.newNoteSource(from: draft, id: id).utf8)
        draft.completion = DraftCompletion(targetPath: destination.path, noteID: id, revision: MeetingNote.contentRevision(bytes))
        try await f.journal.persistNow(draft)
        try bytes.write(to: destination)
        let restarted = DraftJournal(directoryURL: f.journal.directoryURL)
        await restarted.scan()
        let controller = DraftRecoveryController(journal: restarted, store: f.store)

        await controller.reconcileCompletedDrafts()

        #expect(restarted.recoveredDrafts.isEmpty)
        #expect(try markdownFiles(in: f.library).map(\.lastPathComponent) == [destination.lastPathComponent])
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test
    func completionForAnExistingQuickNoteIsAlsoReconciledWithoutRewritingIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, kind: .quickNote, text: "Saved pad writing")
        let id = try #require(draft.noteID)
        let destination = URL(fileURLWithPath: try #require(draft.originalFilePath))
        let bytes = Data(try DraftRecoveryController.newNoteSource(from: draft, id: id).utf8)
        draft.completion = DraftCompletion(targetPath: destination.path, noteID: id, revision: MeetingNote.contentRevision(bytes))
        try bytes.write(to: destination)
        try await f.journal.persistNow(draft)

        await f.controller.reconcileCompletedDrafts()

        #expect(f.journal.recoveredDrafts.isEmpty)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try markdownFiles(in: f.library).count == 1)
    }

    @Test
    func anOriginalSaveConflictStillAllowsRecoveryIntoASeparateNewNote() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for kind in DraftEditorKind.allCases {
            var draft = checkpoint(in: f, kind: kind, text: "Recovered words")
            let originalID = try #require(draft.noteID)
            if kind == .markdown { draft.text = MarkdownCodec.encode(note(id: originalID)) }
            let original = f.library.appendingPathComponent("Original-\(kind.rawValue).md")
            draft.originalFilePath = original.path
            let intended = Data(try DraftRecoveryController.newNoteSource(from: draft, id: originalID).utf8)
            draft.completion = DraftCompletion(targetPath: original.path, noteID: originalID, revision: MeetingNote.contentRevision(intended))
            let external = Data("Original changed elsewhere".utf8)
            try external.write(to: original)
            try await f.journal.persistNow(draft)

            let saved = try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

            #expect(saved != original)
            #expect(try Data(contentsOf: original) == external)
            #expect(MarkdownCodec.decode(try String(contentsOf: saved, encoding: .utf8))?.id != originalID)
            #expect(!f.journal.recoveredDrafts.contains { $0.id == draft.id })
        }
    }

    @Test
    func anUnreadableOriginalDoesNotPreventSavingItsDraftElsewhere() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "The original volume became unavailable")
        let original = URL(fileURLWithPath: try #require(draft.originalFilePath))
        try Data("Existing original".utf8).write(to: original)
        draft.completion = DraftCompletion(targetPath: original.path, noteID: try #require(draft.noteID), revision: Data(repeating: 0, count: 32))
        try await f.journal.persistNow(draft)
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, readFile: { url in
            if url == original { throw POSIXError(.EACCES) }
            return try DraftRecoveryFiles.readRegularFile(at: url)
        })

        let destination = try await controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

        #expect(destination != original)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Existing original")
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func aChangedPreviewCannotCopyExportSaveOrDiscardUnseenWriting() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = checkpoint(in: f, text: "Reviewed writing")
        try await f.journal.persistNow(preview)
        var changed = preview
        changed.text = "Different writing discovered by a rescan"
        try await f.journal.persistNow(changed)
        let exported = f.root.appendingPathComponent("Unseen.txt")

        #expect(throws: DraftRecoveryError.previewChanged) {
            try f.controller.copy(draftID: preview.id, expectedCheckpoint: preview)
        }
        await #expect(throws: DraftRecoveryError.previewChanged) {
            try await f.controller.exportSource(draftID: preview.id, to: exported, expectedCheckpoint: preview)
        }
        await #expect(throws: DraftRecoveryError.previewChanged) {
            try await f.controller.saveAsNewNote(draftID: preview.id, destinationDirectory: f.library, expectedCheckpoint: preview)
        }
        await #expect(throws: DraftRecoveryError.previewChanged) {
            try await f.controller.discard(draftID: preview.id, expectedCheckpoint: preview)
        }

        #expect(f.journal.recoveredDrafts.first?.text == changed.text)
        #expect(!FileManager.default.fileExists(atPath: exported.path))
        #expect(try markdownFiles(in: f.library).isEmpty)
    }

    @Test
    func previewIdentityIgnoresOnlyCompletionBookkeepingAndChecksExactTextBytes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = checkpoint(in: f, text: "caf\u{00E9}")
        var current = preview
        current.checkpointedAt = .now
        current.completion = DraftCompletion(targetPath: "/synthetic/Notes/New.md", noteID: UUID(), revision: Data(repeating: 0, count: 32))
        #expect(DraftRecoveryController.matchesPreview(current, preview))
        current.text = "cafe\u{0301}"
        #expect(current.text == preview.text)
        #expect(!DraftRecoveryController.matchesPreview(current, preview))
        current = preview
        current.libraryPath = "/synthetic/Other library"
        #expect(!DraftRecoveryController.matchesPreview(current, preview))
        current = preview
        current.baseline = "Different baseline"
        #expect(!DraftRecoveryController.matchesPreview(current, preview))
    }

    @Test
    func asyncSnapshotIdentityKeepsCompletionAndTimestampAsWellAsExactTextBytes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var previous = checkpoint(in: f, text: "caf\u{00E9}")
        previous.baseline = "caf\u{00E9}"
        #expect(DraftRecoveryController.matchesSnapshot(previous, previous))
        #expect(!DraftRecoveryController.matchesSnapshot(nil, previous))
        var changed = previous
        changed.checkpointedAt = previous.checkpointedAt.addingTimeInterval(1)
        #expect(!DraftRecoveryController.matchesSnapshot(changed, previous))
        changed = previous
        changed.completion = DraftCompletion(targetPath: "/synthetic/Notes/New.md", noteID: UUID(), revision: Data(repeating: 0, count: 32))
        #expect(!DraftRecoveryController.matchesSnapshot(changed, previous))
        changed = previous
        changed.text = "cafe\u{0301}"
        #expect(changed == previous)
        #expect(!DraftRecoveryController.matchesSnapshot(changed, previous))
        changed = previous
        changed.baseline = "cafe\u{0301}"
        #expect(changed == previous)
        #expect(!DraftRecoveryController.matchesSnapshot(changed, previous))
    }

    /// Simulates another process changing only normalization while preserving
    /// every identity, completion, and timestamp field. A normal journal write
    /// would stamp a new time and conceal the String-equality regression.
    private func replaceCanonicalBytes(
        in fixture: Fixture, checkpoint: DraftCheckpoint, field: String
    ) async throws -> DraftCheckpoint {
        var changed = checkpoint
        if field == "text" { changed.text = "cafe\u{0301}" }
        else { changed.baseline = "cafe\u{0301}" }
        #expect(changed == checkpoint)
        #expect(!Data(changed.text.utf8).elementsEqual(Data(checkpoint.text.utf8))
            || !Data(changed.baseline.utf8).elementsEqual(Data(checkpoint.baseline.utf8)))
        let file = fixture.journal.directoryURL.appendingPathComponent("\(changed.id.uuidString).json")
        try JSONEncoder().encode(changed).write(to: file)
        await fixture.journal.scan()
        let rescanned = try #require(fixture.journal.recoveredDrafts.first { $0.id == changed.id })
        #expect(Data(rescanned.text.utf8) == Data(changed.text.utf8))
        #expect(Data(rescanned.baseline.utf8) == Data(changed.baseline.utf8))
        return changed
    }

    @Test(arguments: ["text", "baseline"])
    func aUnicodeByteChangeDuringCompletionVerificationKeepsTheNewerCheckpoint(field: String) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "caf\u{00E9}")
        draft.baseline = "caf\u{00E9}"
        let noteID = UUID()
        let destination = f.library.appendingPathComponent("Completed-before-restart.md")
        let bytes = Data(try DraftRecoveryController.newNoteSource(from: draft, id: noteID).utf8)
        draft.completion = DraftCompletion(targetPath: destination.path, noteID: noteID, revision: MeetingNote.contentRevision(bytes))
        try bytes.write(to: destination)
        try await f.journal.persistNow(draft)
        let previous = try #require(f.journal.recoveredDrafts.first)
        let gate = DraftRecoveryWriteGate()
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, readFile: { url in
            let data = try DraftRecoveryFiles.readRegularFile(at: url)
            await gate.wait()
            return data
        })
        let task = Task { await controller.reconcileCompletedDrafts() }
        await gate.waitUntilStarted()
        let changed = try await replaceCanonicalBytes(in: f, checkpoint: previous, field: field)
        await gate.release()
        await task.value

        let retained = try #require(f.journal.recoveredDrafts.first)
        #expect(DraftRecoveryController.matchesSnapshot(retained, changed))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try markdownFiles(in: f.library).count == 1)
    }

    @Test(arguments: ["text", "baseline"])
    func aUnicodeByteChangeDuringNewNoteReadbackCannotDeleteTheNewerRecovery(field: String) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "caf\u{00E9}")
        draft.baseline = "caf\u{00E9}"
        let original = URL(fileURLWithPath: try #require(draft.originalFilePath))
        let originalBytes = Data("Unchanged original source".utf8)
        try originalBytes.write(to: original)
        try await f.journal.persistNow(draft)
        let gate = DraftRecoveryWriteGate()
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, readFile: { url in
            let data = try DraftRecoveryFiles.readRegularFile(at: url)
            await gate.wait()
            return data
        })
        let task = Task { try await controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library) }
        await gate.waitUntilStarted()
        let previous = try #require(f.journal.recoveredDrafts.first)
        let changed = try await replaceCanonicalBytes(in: f, checkpoint: previous, field: field)
        await gate.release()
        await #expect(throws: DraftRecoveryError.noLongerAvailable) { try await task.value }

        let retained = try #require(f.journal.recoveredDrafts.first)
        #expect(DraftRecoveryController.matchesSnapshot(retained, changed))
        let saved = URL(fileURLWithPath: try #require(previous.completion?.targetPath))
        #expect(try Data(contentsOf: saved).suffix(Data(previous.text.utf8).count) == Data(previous.text.utf8))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try markdownFiles(in: f.library).count == 2)
    }

    @Test
    func changedSavedResultCannotResolveItsCheckpointOrCreateADuplicate() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "Recovered words")
        let id = UUID()
        let destination = f.library.appendingPathComponent("Previously-saved.md")
        let bytes = Data(try DraftRecoveryController.newNoteSource(from: draft, id: id).utf8)
        draft.completion = DraftCompletion(targetPath: destination.path, noteID: id, revision: MeetingNote.contentRevision(bytes))
        try await f.journal.persistNow(draft)
        let changed = bytes + Data("\nChanged externally".utf8)
        try changed.write(to: destination)

        await f.controller.reconcileCompletedDrafts()
        await #expect(throws: DraftRecoveryError.previousSaveChanged) {
            try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        #expect(f.journal.recoveredDrafts.count == 1)
        #expect(try markdownFiles(in: f.library).count == 1)
        #expect(try Data(contentsOf: destination) == changed)
    }

    @Test
    func missingIntendedSaveNeverWritesToTheStoredPathOnRetry() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var draft = checkpoint(in: f, text: "Still unfinished")
        let neverWritten = f.root.appendingPathComponent("Never-trust-this-destination.md")
        draft.completion = DraftCompletion(targetPath: neverWritten.path, noteID: UUID(), revision: Data(repeating: 0, count: 32))
        try await f.journal.persistNow(draft)

        let saved = try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

        #expect(saved.deletingLastPathComponent() == f.library)
        #expect(!FileManager.default.fileExists(atPath: neverWritten.path))
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func aFailedCompletionCheckpointPreventsAnyNoteWrite() async throws {
        let failing = Mutex(false)
        let f = try fixture(beforeFileOperation: { operation, _ in
            if case .write = operation, failing.withLock({ $0 }) { throw POSIXError(.ENOSPC) }
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Only surviving text")
        try await f.journal.persistNow(draft)
        failing.withLock { $0 = true }

        await #expect(throws: (any Error).self) {
            try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        #expect(try markdownFiles(in: f.library).isEmpty)
        #expect(f.journal.recoveredDrafts.first?.text == draft.text)
    }

    @Test
    func failureToCleanUpLeavesTheSavedNoteAndRetryDoesNotDuplicateIt() async throws {
        let failing = Mutex(true)
        let f = try fixture(beforeFileOperation: { operation, _ in
            if case .remove = operation, failing.withLock({ $0 }) { throw POSIXError(.EACCES) }
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Saved but recovery remains")
        try await f.journal.persistNow(draft)

        await #expect(throws: DraftRecoveryError.cleanupFailed) {
            try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }
        let firstFiles = try markdownFiles(in: f.library)
        #expect(firstFiles.count == 1)
        #expect(f.journal.recoveredDrafts.count == 1)
        #expect(f.controller.message?.contains("new note was saved") == true)
        failing.withLock { $0 = false }

        let saved = try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)

        #expect(firstFiles.map(\.lastPathComponent) == [saved.lastPathComponent])
        #expect(try markdownFiles(in: f.library) == firstFiles)
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func aFailedReadBackKeepsTheCheckpointAndTheWrittenFile() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Original recovered text")
        try await f.journal.persistNow(draft)
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, readFile: { _ in
            Data("Unexpected bytes".utf8)
        })

        await #expect(throws: DraftRecoveryError.readBackFailed) {
            try await controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        #expect(f.journal.recoveredDrafts.first?.text == draft.text)
        #expect(try markdownFiles(in: f.library).count == 1)
    }

    @Test
    func exclusiveCreationNeverReplacesAnExistingFileOrSymlink() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = f.library.appendingPathComponent("Already-here.md")
        let original = Data("Unrelated precious writing".utf8)
        try original.write(to: destination)
        #expect(throws: (any Error).self) {
            try DraftRecoveryFiles.writeNew(Data("Replacement".utf8), to: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
        let symlink = f.library.appendingPathComponent("Link.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        #expect(throws: (any Error).self) {
            try DraftRecoveryFiles.writeNew(Data("Replacement".utf8), to: symlink)
        }
        #expect(try Data(contentsOf: destination) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.library.path)
        #expect(!names.contains { $0.hasPrefix(".nook-recovery-") })
    }

    @Test(arguments: [POSIXErrorCode.ENOTSUP, .EOPNOTSUPP])
    func anUnsupportedExclusiveRenameExplainsTheLimitationAndKeepsTheRecovery(code: POSIXErrorCode) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Only surviving recovered words")
        try await f.journal.persistNow(draft)
        let original = f.library.appendingPathComponent("Unrelated.md")
        let originalBytes = Data("Keep the existing destination".utf8)
        try originalBytes.write(to: original)
        let attempts = Mutex(0)
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, writeNew: { url, bytes in
            try DraftRecoveryFiles.writeNew(bytes, to: url, renameExclusive: { _, _, _, _ in
                attempts.withLock { $0 += 1 }
                throw POSIXError(code)
            })
        })

        await #expect(throws: DraftRecoveryError.safeCreationUnsupported) {
            try await controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        #expect(attempts.withLock { $0 } == 1)
        #expect(f.journal.recoveredDrafts.first?.text == draft.text)
        #expect(try Data(contentsOf: original) == originalBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: f.library.path)
        #expect(files == ["Unrelated.md"])
        #expect(DraftRecoveryError.safeCreationUnsupported.localizedDescription.contains("Choose a folder on your Mac"))
    }

    @Test
    func exportedSourceCannotOverwriteAnExistingFileAndRetainsRecovery() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Recovered source")
        try await f.journal.persistNow(draft)
        let export = f.root.appendingPathComponent("Existing.txt")
        let original = Data("Original export".utf8)
        try original.write(to: export)

        await #expect(throws: (any Error).self) {
            try await f.controller.exportSource(draftID: draft.id, to: export)
        }

        #expect(try Data(contentsOf: export) == original)
        #expect(f.journal.recoveredDrafts.count == 1)
    }

    @Test
    func aLibraryChangeRefusesThePreviouslyDisplayedDestination() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Still owned by the first library")
        try await f.journal.persistNow(draft)
        let other = f.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        f.store.storageURL = other

        await #expect(throws: DraftRecoveryError.libraryChanged) {
            try await f.controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        #expect(try markdownFiles(in: f.library).isEmpty)
        #expect(try markdownFiles(in: other).isEmpty)
        #expect(f.journal.recoveredDrafts.first?.libraryPath == draft.libraryPath)
    }

    @Test
    func aLibraryChangeDuringTheWriteNeverRedirectsItsCapturedDestination() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "The destination is explicit")
        try await f.journal.persistNow(draft)
        let other = f.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let gate = DraftRecoveryWriteGate()
        let controller = DraftRecoveryController(journal: f.journal, store: f.store, writeNew: { url, bytes in
            await gate.wait()
            try DraftRecoveryFiles.writeNew(bytes, to: url)
        })
        let task = Task { try await controller.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library) }
        await gate.waitUntilStarted()
        f.store.storageURL = other
        await gate.release()

        let saved = try await task.value

        #expect(saved.deletingLastPathComponent() == f.library)
        #expect(try markdownFiles(in: other).isEmpty)
        #expect(f.journal.recoveredDrafts.isEmpty)
    }

    @Test
    func discardUsesTrashAndFailurePreservesTheVisibleRecovery() async throws {
        let f = try fixture(trashItem: { _ in throw POSIXError(.EACCES) })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "The only recovery")
        try await f.journal.persistNow(draft)

        await #expect(throws: (any Error).self) {
            try await f.controller.discard(draftID: draft.id)
        }

        #expect(f.journal.recoveredDrafts.first?.text == draft.text)
        #expect(f.journal.statusMessage != nil)
    }

    @Test
    func successfulDiscardDoesNotTouchTheOriginalNote() async throws {
        let trashed = Mutex<[URL]>([])
        let f = try fixture(trashItem: { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "Discarded recovery")
        let original = URL(fileURLWithPath: try #require(draft.originalFilePath))
        try Data("Keep this original".utf8).write(to: original)
        try await f.journal.persistNow(draft)

        try await f.controller.discard(draftID: draft.id)

        #expect(trashed.withLock { $0.count } == 1)
        #expect(f.journal.recoveredDrafts.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "Keep this original")
    }

    @Test
    func recoveryFilesArePrivateAndUnsafeReadTargetsAreRejected() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let output = f.library.appendingPathComponent("Private.md")
        try DraftRecoveryFiles.writeNew(Data("Private source".utf8), to: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let link = f.root.appendingPathComponent("Link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        #expect(throws: (any Error).self) { try DraftRecoveryFiles.readRegularFile(at: link) }
        #expect(throws: DraftRecoveryError.unsafeFile) { try DraftRecoveryFiles.readRegularFile(at: f.library) }
        let fifo = f.root.appendingPathComponent("Pipe.md")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: DraftRecoveryError.unsafeFile) { try DraftRecoveryFiles.readRegularFile(at: fifo) }
    }

    @Test(arguments: [false, true])
    func interruptionAroundPublicationRetainsIntentAndRestartCannotDuplicateTheSavedNote(
        afterPublication: Bool
    ) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let draft = checkpoint(in: f, text: "  Exact surviving café source\r\n")
        try await f.journal.persistNow(draft)
        let initialCheckpoint = try #require(f.journal.recoveredDrafts.first)
        let interrupted = DraftRecoveryController(journal: f.journal, store: f.store, writeNew: { url, bytes in
            if afterPublication { try DraftRecoveryFiles.writeNew(bytes, to: url) }
            // Model the caller stopping before read-back or cleanup. This
            // exercises persisted boundaries, not OS process or power loss.
            throw CancellationError()
        })

        await #expect(throws: CancellationError.self) {
            try await interrupted.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
        }

        let restarted = DraftJournal(directoryURL: f.journal.directoryURL)
        await restarted.scan()
        let recovered = try #require(restarted.recoveredDrafts.first)
        let completion = try #require(recovered.completion)
        let planned = URL(fileURLWithPath: completion.targetPath)
        #expect(Data(recovered.text.utf8) == Data(draft.text.utf8))
        #expect(FileManager.default.fileExists(atPath: planned.path) == afterPublication)
        let resumed = DraftRecoveryController(journal: restarted, store: f.store)
        await resumed.reconcileCompletedDrafts()
        let saved: URL
        let savedID: UUID
        let expectedBytes: Data
        if afterPublication {
            saved = planned
            savedID = completion.noteID
            expectedBytes = Data(try DraftRecoveryController.newNoteSource(from: initialCheckpoint, id: savedID).utf8)
            #expect(MeetingNote.contentRevision(expectedBytes) == completion.revision)
        } else {
            #expect(restarted.recoveredDrafts.count == 1)
            saved = try await resumed.saveAsNewNote(draftID: draft.id, destinationDirectory: f.library)
            #expect(saved != planned)
            #expect(!FileManager.default.fileExists(atPath: planned.path))
            savedID = try #require(MarkdownCodec.decode(String(contentsOf: saved, encoding: .utf8))?.id)
            #expect(savedID != completion.noteID)
            expectedBytes = Data(try DraftRecoveryController.newNoteSource(from: recovered, id: savedID).utf8)
        }
        // Foundation enumerates /var temporary files through /private/var.
        // Compare the complete canonical paths, retaining the one-file proof
        // as well as the intended identity and exact complete source bytes.
        let files = try markdownFiles(in: f.library)
        let savedPath = saved.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(files.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } == [savedPath])
        let bytes = try Data(contentsOf: #require(files.first))
        #expect(bytes == expectedBytes)
        #expect(bytes.suffix(Data(draft.text.utf8).count) == Data(draft.text.utf8))
        #expect(MarkdownCodec.decode(String(decoding: bytes, as: UTF8.self))?.id == savedID)
        #expect(savedID != draft.noteID)
        #expect(restarted.recoveredDrafts.isEmpty)

        // Repeating reconciliation has no draft left to replay or duplicate.
        await resumed.reconcileCompletedDrafts()
        #expect(try markdownFiles(in: f.library).map { $0.standardizedFileURL.resolvingSymlinksInPath().path } == [savedPath])
        #expect(try Data(contentsOf: saved) == expectedBytes)
    }
}

private actor DraftRecoveryWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func wait() async {
        hasStarted = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters = []
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
